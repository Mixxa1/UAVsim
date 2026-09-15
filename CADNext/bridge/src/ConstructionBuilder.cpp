#include "cadnext/bridge/ConstructionBuilder.hpp"

#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/Kernel.hpp"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>

namespace cadnext::bridge {

namespace {

bool parseAxis(const std::string& text, Vector3& out) {
    if (text.size() != 2 || (text[0] != '+' && text[0] != '-')) return false;
    const double sign = text[0] == '+' ? 1.0 : -1.0;
    switch (text[1]) {
    case 'x': out = {sign, 0.0, 0.0}; return true;
    case 'y': out = {0.0, sign, 0.0}; return true;
    case 'z': out = {0.0, 0.0, sign}; return true;
    default: return false;
    }
}

double dot(const Vector3& a, const Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vector3 cross(const Vector3& a, const Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

struct Basis {
    Vector3 forward, up, left;
};

Result<Basis> basis(const ConstructionAxes& axes) {
    Basis b;
    if (!parseAxis(axes.forward, b.forward) || !parseAxis(axes.up, b.up)) {
        return Result<Basis>::fail({ErrorCode::InvalidArgument, "оси CAD: нужны «+x», «-x», «+y», «-y», «+z» или «-z»"});
    }
    if (dot(b.forward, b.up) != 0.0) {
        return Result<Basis>::fail({ErrorCode::InvalidArgument, "оси CAD: «вперёд» и «вверх» должны быть перпендикулярны"});
    }
    // Model +X is left: up × forward = Y × Z = X.
    b.left = cross(b.up, b.forward);
    return Result<Basis>::ok(b);
}

Vector3 toModel(const Basis& b, const Vector3& p) {
    return {dot(p, b.left), dot(p, b.up), dot(p, b.forward)};
}

Vector3 toExport(const Basis& b, const Vector3& p) {
    return {dot(p, b.left), -dot(p, b.forward), dot(p, b.up)};
}

// "face-12-9a1c…" → "face-12", the solver's face group.
std::string faceIndexId(const std::string& faceId) {
    const auto second = faceId.find('-', 5);
    return second == std::string::npos ? faceId : faceId.substr(0, second);
}

} // namespace

std::string sha256Hex(const std::string& bytes) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest);
    std::string hex;
    hex.reserve(2 * CC_SHA256_DIGEST_LENGTH);
    char buffer[3];
    for (unsigned char byte : digest) {
        std::snprintf(buffer, sizeof(buffer), "%02x", byte);
        hex += buffer;
    }
    return hex;
}

Result<Vector3> cadToModel(const ConstructionAxes& axes, const Vector3& cad) {
    const auto b = basis(axes);
    if (!b.isOk()) return Result<Vector3>::fail(b.error());
    return Result<Vector3>::ok(toModel(b.value(), cad));
}

Result<Vector3> cadToExport(const ConstructionAxes& axes, const Vector3& cad) {
    const auto b = basis(axes);
    if (!b.isOk()) return Result<Vector3>::fail(b.error());
    return Result<Vector3>::ok(toExport(b.value(), cad));
}

Result<Vector3> modelToCad(const ConstructionAxes& axes, const Vector3& model) {
    const auto b = basis(axes);
    if (!b.isOk()) return Result<Vector3>::fail(b.error());
    const Basis& v = b.value();
    // The basis is orthonormal: the inverse is the transpose.
    return Result<Vector3>::ok({v.left.x * model.x + v.up.x * model.y + v.forward.x * model.z,
                                v.left.y * model.x + v.up.y * model.y + v.forward.y * model.z,
                                v.left.z * model.x + v.up.z * model.y + v.forward.z * model.z});
}

Result<ConstructionDescriptor> buildConstruction(kernel::Kernel& kernel, const ConstructionBuildRequest& request) {
    auto fail = [](const std::string& message) {
        return Result<ConstructionDescriptor>::fail({ErrorCode::InvalidArgument, message});
    };
    const auto axes = basis(request.cadAxes);
    if (!axes.isOk()) return Result<ConstructionDescriptor>::fail(axes.error());
    if (request.bodies.empty()) return fail("в раме нет тел");

    ConstructionDescriptor descriptor;
    descriptor.id = request.id;
    descriptor.name = request.name;
    descriptor.cadAxes = request.cadAxes;

    const double inf = std::numeric_limits<double>::infinity();
    Vector3 low{inf, inf, inf};
    Vector3 high{-inf, -inf, -inf};
    Vector3 weighted;
    kernel::FaceAnalyzer analyzer(kernel);

    for (const auto& input : request.bodies) {
        const std::string label = "«" + (input.name.empty() ? input.id : input.name) + "»";
        if (input.materialId.empty() || !(input.densityKgPerM3 > 0.0)) {
            return fail("у тела " + label + " не задан материал: без него нельзя честно посчитать ни массу, ни прочность");
        }
        const auto properties = kernel.volumeProperties(input.shape);
        if (!properties.isOk()) return fail("тело " + label + ": " + properties.error().message);
        if (!(properties.value().volumeM3 > 0.0)) return fail("тело " + label + " не является замкнутым телом (нулевой объём)");
        const auto brep = kernel.exportBRepGeometry(input.shape);
        if (!brep.isOk()) return fail("тело " + label + ": " + brep.error().message);

        ConstructionBody body;
        body.id = input.id;
        body.name = input.name;
        body.materialId = input.materialId;
        body.densityKgPerM3 = input.densityKgPerM3;
        body.volumeM3 = properties.value().volumeM3;
        body.massKg = body.volumeM3 * body.densityKgPerM3;
        body.centerOfMass = toExport(axes.value(), properties.value().centerOfMass);
        body.brep.assign(brep.value().begin(), brep.value().end());
        body.brepSha256 = sha256Hex(body.brep);
        body.firstTriangle = static_cast<std::uint32_t>(descriptor.mesh.indices.size() / 3);

        // Faces in the kernel's order, which is the order the solver's "face-<index>" groups follow.
        auto faces = analyzer.planarFacesForBody(input.id, input.shape);
        std::stable_sort(faces.begin(), faces.end(), [](const auto& a, const auto& b) {
            return std::stoi(faceIndexId(a.faceId).substr(5)) < std::stoi(faceIndexId(b.faceId).substr(5));
        });
        if (faces.empty()) return fail("тело " + label + ": ядро не отдало ни одной грани");
        for (const auto& face : faces) {
            ConstructionFaceRange range;
            range.faceId = faceIndexId(face.faceId);
            range.firstTriangle = static_cast<std::uint32_t>(descriptor.mesh.indices.size() / 3);
            const auto base = static_cast<std::uint32_t>(descriptor.mesh.vertices.size() / 3);
            for (const auto& vertex : face.previewMesh.vertices) {
                const Vector3 p = toExport(axes.value(), {vertex.x, vertex.y, vertex.z});
                descriptor.mesh.vertices.push_back(static_cast<float>(p.x));
                descriptor.mesh.vertices.push_back(static_cast<float>(p.y));
                descriptor.mesh.vertices.push_back(static_cast<float>(p.z));
                low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
                high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
            }
            for (const auto& triangle : face.previewMesh.triangles) {
                descriptor.mesh.indices.push_back(base + triangle.a);
                descriptor.mesh.indices.push_back(base + triangle.b);
                descriptor.mesh.indices.push_back(base + triangle.c);
            }
            range.triangleCount = static_cast<std::uint32_t>(descriptor.mesh.indices.size() / 3) - range.firstTriangle;
            body.faces.push_back(range);
        }
        body.triangleCount = static_cast<std::uint32_t>(descriptor.mesh.indices.size() / 3) - body.firstTriangle;
        if (body.triangleCount == 0) return fail("тело " + label + ": нет треугольников отображения");

        descriptor.massKg += body.massKg;
        weighted.x += body.centerOfMass.x * body.massKg;
        weighted.y += body.centerOfMass.y * body.massKg;
        weighted.z += body.centerOfMass.z * body.massKg;
        descriptor.bodies.push_back(std::move(body));
    }

    descriptor.centerOfMass = {weighted.x / descriptor.massKg, weighted.y / descriptor.massKg, weighted.z / descriptor.massKg};
    descriptor.boundingBoxMin = low;
    descriptor.boundingBoxMax = high;
    descriptor.collisionCenter = {(low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2};
    descriptor.collisionSize = {high.x - low.x, high.y - low.y, high.z - low.z};
    return Result<ConstructionDescriptor>::ok(std::move(descriptor));
}

} // namespace cadnext::bridge
