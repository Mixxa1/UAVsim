#include "cadnext/kernel/ExtrudeMesh.hpp"

#include <cmath>
#include <cstdint>
#include <string>
#include <utility>

namespace cadnext::kernel {

namespace {

cadnext::Result<TriangleMesh> meshError(cadnext::ErrorCode code, std::string message) {
    return cadnext::Result<TriangleMesh>::fail({code, std::move(message)});
}

cadnext::Vector3 normalizedOrFallback(const cadnext::Vector3& v,
                                      const cadnext::Vector3& fallback) {
    const double length = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (!std::isfinite(length) || length <= 1.0e-12) {
        return fallback;
    }
    return {v.x / length, v.y / length, v.z / length};
}

double signedDoubledArea(const std::vector<cadnext::SketchPoint2D>& loop) {
    double doubled = 0.0;
    for (size_t i = 0; i < loop.size(); ++i) {
        const cadnext::SketchPoint2D& a = loop[i];
        const cadnext::SketchPoint2D& b = loop[(i + 1) % loop.size()];
        doubled += a.u * b.v - b.u * a.v;
    }
    return doubled;
}

void pushTriangle(TriangleMesh& mesh, std::uint32_t a, std::uint32_t b, std::uint32_t c,
                  bool flip, std::string faceId) {
    MeshTriangle triangle;
    if (flip) {
        triangle = {a, c, b, std::move(faceId)};
    } else {
        triangle = {a, b, c, std::move(faceId)};
    }
    mesh.triangles.push_back(std::move(triangle));
}

} // namespace

cadnext::Result<TriangleMesh> buildExtrudedProfileMesh(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    const cadnext::ExtrudeParameters& parameters) {
    if (!cadnext::extrudeParametersValid(parameters)) {
        return meshError(cadnext::ErrorCode::InvalidArgument,
                         "Extrude parameters are invalid (distance must be > 0)");
    }
    double startOffset = 0.0;
    double endOffset = 0.0;
    cadnext::extrudeSpan(parameters, startOffset, endOffset);
    return buildProfilePrismMesh(reference, profile, startOffset, endOffset);
}

cadnext::Result<TriangleMesh> buildProfilePrismMesh(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    double startOffset, double endOffset) {
    if (!profile.isValid || !profile.isClosed || profile.outerLoop.size() < 3) {
        return meshError(cadnext::ErrorCode::InvalidArgument,
                         "Profile is not a valid closed loop");
    }
    if (!std::isfinite(endOffset - startOffset) || endOffset - startOffset <= 0.0) {
        return meshError(cadnext::ErrorCode::InvalidArgument,
                         "Prism span must be positive");
    }

    const std::vector<unsigned int> capTriangles =
        cadnext::triangulatePolygon(profile.outerLoop);
    if (capTriangles.empty()) {
        return meshError(cadnext::ErrorCode::KernelOperationFailed,
                         "Profile loop could not be triangulated");
    }

    const cadnext::Vector3 normal =
        normalizedOrFallback(reference.normal, {0.0, 0.0, 1.0});

    // Plane basis handedness: cross(u, v) points along +normal for a
    // right-handed UV basis and along -normal for the canonical XZ plane.
    // All cap/wall windings below flip with it so the prism surface always
    // faces outward.
    const cadnext::Vector3 uAxis = reference.uAxis;
    const cadnext::Vector3 vAxis = reference.vAxis;
    const cadnext::Vector3 handedVector{uAxis.y * vAxis.z - uAxis.z * vAxis.y,
                                        uAxis.z * vAxis.x - uAxis.x * vAxis.z,
                                        uAxis.x * vAxis.y - uAxis.y * vAxis.x};
    const double handedDot = handedVector.x * normal.x + handedVector.y * normal.y +
                             handedVector.z * normal.z;
    const bool leftHanded = handedDot < 0.0;

    const size_t n = profile.outerLoop.size();
    TriangleMesh mesh;
    mesh.vertices.reserve(n * 2);

    // Base ring [0, n) at startOffset, top ring [n, 2n) at endOffset.
    for (const cadnext::SketchPoint2D& point : profile.outerLoop) {
        const cadnext::Vector3 world = cadnext::sketchPointToWorld(point, reference);
        mesh.vertices.push_back({world.x + normal.x * startOffset,
                                 world.y + normal.y * startOffset,
                                 world.z + normal.z * startOffset});
    }
    for (const cadnext::SketchPoint2D& point : profile.outerLoop) {
        const cadnext::Vector3 world = cadnext::sketchPointToWorld(point, reference);
        mesh.vertices.push_back({world.x + normal.x * endOffset,
                                 world.y + normal.y * endOffset,
                                 world.z + normal.z * endOffset});
    }

    // Caps. triangulatePolygon returns CCW-in-UV triangles, whose world
    // normal is +plane-normal for a right-handed basis. The top cap must
    // face +normal, the base cap -normal.
    for (size_t t = 0; t + 2 < capTriangles.size(); t += 3) {
        const auto a = static_cast<std::uint32_t>(capTriangles[t]);
        const auto b = static_cast<std::uint32_t>(capTriangles[t + 1]);
        const auto c = static_cast<std::uint32_t>(capTriangles[t + 2]);
        const auto topOffset = static_cast<std::uint32_t>(n);
        pushTriangle(mesh, a + topOffset, b + topOffset, c + topOffset, leftHanded,
                     "face-cap-end");
        pushTriangle(mesh, a, b, c, !leftHanded, "face-cap-start");
    }

    // Side walls along the CCW-in-UV boundary (a CW loop is walked in
    // reverse so the wall winding matches the caps).
    const bool loopIsCcw = signedDoubledArea(profile.outerLoop) > 0.0;
    for (size_t k = 0; k < n; ++k) {
        const size_t i = loopIsCcw ? k : (n - 1 - k);
        const size_t jRaw = loopIsCcw ? (k + 1) % n : (n - 1 - ((k + 1) % n));
        const auto bi = static_cast<std::uint32_t>(i);
        const auto bj = static_cast<std::uint32_t>(jRaw);
        const auto ti = static_cast<std::uint32_t>(i + n);
        const auto tj = static_cast<std::uint32_t>(jRaw + n);
        const std::string faceId = "face-side-" + std::to_string(k);
        pushTriangle(mesh, bi, bj, tj, leftHanded, faceId);
        pushTriangle(mesh, bi, tj, ti, leftHanded, faceId);
    }

    return cadnext::Result<TriangleMesh>::ok(std::move(mesh));
}

} // namespace cadnext::kernel
