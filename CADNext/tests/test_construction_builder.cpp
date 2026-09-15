// Version-2 .uavframe from kernel bodies — the geometry the Workbench will run the structural
// solver on, so everything here is about the Workbench getting exactly the part CADNext has.
//
//   cadnext_test_construction_builder <CADNext/bridge/schema>
//
// Checked:
//  - SHA-256 itself against the FIPS 180-2 "abc" vector;
//  - the exported BRep is the geometry alone: identical before and after the viewer's
//    triangulation, and it re-imports to the same volume;
//  - mass = exact volume × density, centre of mass mass-weighted;
//  - display triangles are partitioned per body and per CAD face, and the face ids are the ones the
//    kernel gives the re-imported shape — the ids the solver's face groups carry;
//  - axes: display data is written in the export frame the Workbench importer has always used
//    (Z up, nose −Y), which with the importer's (x, z, −y) puts the declared CAD forward/up on model
//    +Z/+Y; the triangle normals of a face follow (outward stays outward); model→CAD inverts
//    CAD→model;
//  - refusals: a body without material, parallel or malformed axes;
//  - the JSON round-trips byte for byte, and its keys match schema/uavframe-v2.example.json, which
//    the Swift probe decodes.

#include "cadnext/bridge/ConstructionBuilder.hpp"
#include "cadnext/bridge/ConstructionExport.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include "fea_test_support.hpp"
#include "../bridge/src/UAVPartJson.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>

using namespace cadnext;
using namespace cadnext::bridge;
using fea_test::check;

namespace {

std::string readText(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

std::string text(const std::vector<std::uint8_t>& bytes) {
    return {bytes.begin(), bytes.end()};
}

std::set<std::string> keys(const json::JsonValue* object) {
    std::set<std::string> result;
    if (object != nullptr)
        for (const auto& [key, value] : object->objectMembers) result.insert(key);
    return result;
}

std::string faceIndex(const std::string& faceId) {
    const auto second = faceId.find('-', 5);
    return second == std::string::npos ? faceId : faceId.substr(0, second);
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::printf("usage: %s <bridge schema directory>\n", argv[0]);
        return 64;
    }
    const std::filesystem::path schemaDirectory = argv[1];

    check(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of \"abc\" (FIPS 180-2)");

    kernel::OcctKernel kernel;
    // A centre plate and an arm along CAD +X (forward), 10 mm plate, 20×20 mm arm.
    const auto plate = kernel.makeExtrudedPolygon({{{-0.1, -0.1, 0}, {0.1, -0.1, 0}, {0.1, 0.1, 0}, {-0.1, 0.1, 0}}, {0, 0, 0.01}});
    const auto arm = kernel.makeExtrudedPolygon({{{0.1, -0.01, 0}, {0.4, -0.01, 0}, {0.4, 0.01, 0}, {0.1, 0.01, 0}}, {0, 0, 0.02}});
    check(plate.isOk() && arm.isOk(), "test bodies built");
    const double aluminium = 2810.0, carbon = 1600.0;

    // The viewer's triangulation must not reach the exported geometry.
    const std::string before = text(kernel.exportBRepGeometry(plate.value()).value());
    const std::string withTrianglesBefore = text(kernel.exportBRep(plate.value()).value());
    (void)kernel::FaceAnalyzer(kernel).planarFacesForBody("plate", plate.value());
    const std::string after = text(kernel.exportBRepGeometry(plate.value()).value());
    const std::string withTrianglesAfter = text(kernel.exportBRep(plate.value()).value());
    check(before == after, "geometry-only BRep is unchanged by display triangulation");
    std::printf("  full BRep %s by triangulation (%zu → %zu bytes); geometry-only %zu bytes\n",
                withTrianglesBefore == withTrianglesAfter ? "unchanged" : "changed", withTrianglesBefore.size(),
                withTrianglesAfter.size(), after.size());

    ConstructionBuildRequest request;
    request.id = "test-frame";
    request.name = "Тестовая рама";
    request.cadAxes = {"+x", "+z"};
    request.bodies = {{"plate", "Центральная плита", plate.value(), "al_7075_t6", aluminium},
                      {"arm", "Луч", arm.value(), "cfrp_quasi_isotropic", carbon}};
    const auto built = buildConstruction(kernel, request);
    check(built.isOk(), "construction builds", built.isOk() ? "" : built.error().message);
    if (!built.isOk()) return fea_test::finish("test_construction_builder");
    const ConstructionDescriptor& frame = built.value();

    const double plateVolume = 0.2 * 0.2 * 0.01, armVolume = 0.3 * 0.02 * 0.02;
    fea_test::checkRelative(frame.bodies[0].volumeM3, plateVolume, 1e-9, "plate volume from the exact BRep");
    fea_test::checkRelative(frame.massKg, plateVolume * aluminium + armVolume * carbon, 1e-9, "mass = Σ volume × density");
    // Declared forward +X, up +Z. CAD CoM: plate (0,0,0.005), arm (0.25,0,0.01).
    // Export frame: x = left (CAD +Y here), y = −forward (−CAD x), z = up (CAD z).
    const double mPlate = plateVolume * aluminium, mArm = armVolume * carbon;
    const double comForward = (0.25 * mArm) / (mPlate + mArm);
    const double comUp = (0.005 * mPlate + 0.01 * mArm) / (mPlate + mArm);
    check(std::fabs(frame.centerOfMass.y + comForward) < 1e-9 && std::fabs(frame.centerOfMass.z - comUp) < 1e-9
              && std::fabs(frame.centerOfMass.x) < 1e-9,
          "centre of mass mass-weighted, in the export frame (nose −Y, Z up)");
    check(std::fabs(frame.boundingBoxMin.y + 0.4) < 1e-6 && std::fabs(frame.boundingBoxMax.y - 0.1) < 1e-6
              && std::fabs(frame.boundingBoxMax.z - 0.02) < 1e-6,
          "export bounds: the nose (CAD +X = 0.4) at export −Y, up span along Z");

    std::uint32_t expectedFirst = 0;
    for (const auto& body : frame.bodies) {
        check(body.brepSha256 == sha256Hex(body.brep), body.name + ": fingerprint is the SHA-256 of the embedded BRep");
        const auto reimported = kernel.importBRep(std::vector<std::uint8_t>(body.brep.begin(), body.brep.end()));
        check(reimported.isOk(), body.name + ": embedded BRep re-imports");
        if (!reimported.isOk()) continue;
        fea_test::checkRelative(kernel.volumeProperties(reimported.value()).value().volumeM3, body.volumeM3, 1e-9,
                                body.name + ": re-imported volume");
        check(body.firstTriangle == expectedFirst, body.name + ": triangles follow the previous body");
        std::uint32_t cursor = body.firstTriangle;
        bool contiguous = true;
        std::set<std::string> exported;
        for (const auto& face : body.faces) {
            contiguous = contiguous && face.firstTriangle == cursor && face.triangleCount > 0;
            cursor += face.triangleCount;
            exported.insert(face.faceId);
        }
        check(contiguous && cursor == body.firstTriangle + body.triangleCount, body.name + ": face ranges partition the body's triangles");
        std::set<std::string> kernelIds;
        for (const auto& face : kernel::FaceAnalyzer(kernel).planarFacesForBody(body.id, reimported.value())) kernelIds.insert(faceIndex(face.faceId));
        check(exported == kernelIds, body.name + ": face ids are the kernel's ids of the re-imported shape (the solver's groups)");
        expectedFirst = cursor;
    }
    check(expectedFirst * 3 == frame.mesh.indices.size(), "every display triangle belongs to a body");

    // The plate's top face (CAD normal +Z): its triangles must face export +Z, outward — and
    // model +Y once the Workbench importer has applied its mapping.
    {
        const auto faces = kernel::FaceAnalyzer(kernel).planarFacesForBody("plate", plate.value());
        std::string top;
        for (const auto& face : faces)
            if (face.kind == kernel::FaceKind::Planar && face.normal.z > 0.99 && std::fabs(face.origin.z - 0.01) < 1e-9) top = faceIndex(face.faceId);
        bool upward = !top.empty();
        int triangles = 0;
        for (const auto& range : frame.bodies[0].faces) {
            if (range.faceId != top) continue;
            for (std::uint32_t t = range.firstTriangle; t < range.firstTriangle + range.triangleCount; ++t) {
                auto vertex = [&](int k) {
                    const std::uint32_t i = frame.mesh.indices[3 * t + k];
                    return Vector3{frame.mesh.vertices[3 * i], frame.mesh.vertices[3 * i + 1], frame.mesh.vertices[3 * i + 2]};
                };
                const Vector3 a = vertex(0), b = vertex(1), c = vertex(2);
                const Vector3 e1{b.x - a.x, b.y - a.y, b.z - a.z}, e2{c.x - a.x, c.y - a.y, c.z - a.z};
                const double normalZ = e1.x * e2.y - e1.y * e2.x;
                upward = upward && normalZ > 0.0;
                ++triangles;
            }
        }
        check(upward && triangles > 0, "plate top face: export triangles face +Z (axes and winding carried over)");
    }

    // Axes.
    const auto forward = cadToModel({"+x", "+z"}, {1, 0, 0});
    const auto left = cadToModel({"+x", "+z"}, {0, 1, 0});
    check(forward.isOk() && std::fabs(forward.value().z - 1) < 1e-15 && left.isOk() && std::fabs(left.value().x - 1) < 1e-15,
          "CAD forward → model +Z; CAD +Y with up +Z, forward +X is the aircraft's left → model +X");
    bool inverse = true;
    for (const ConstructionAxes axes : {ConstructionAxes{"+x", "+z"}, ConstructionAxes{"-y", "+z"}, ConstructionAxes{"+z", "+y"}, ConstructionAxes{"-x", "-y"}}) {
        const Vector3 p{0.3, -1.7, 2.9};
        const auto back = modelToCad(axes, cadToModel(axes, p).value()).value();
        inverse = inverse && std::fabs(back.x - p.x) < 1e-12 && std::fabs(back.y - p.y) < 1e-12 && std::fabs(back.z - p.z) < 1e-12;
    }
    check(inverse, "model → CAD inverts CAD → model for several axis choices");
    // The export frame is exactly what the Workbench importer maps onto the model the way cadToModel does.
    bool importerAgrees = true;
    for (const ConstructionAxes axes : {ConstructionAxes{"+x", "+z"}, ConstructionAxes{"-y", "+z"}, ConstructionAxes{"+z", "+y"}, ConstructionAxes{"-x", "-y"}}) {
        const Vector3 p{0.3, -1.7, 2.9};
        const Vector3 viaImporter = exportToModel(cadToExport(axes, p).value());
        const Vector3 direct = cadToModel(axes, p).value();
        importerAgrees = importerAgrees && std::fabs(viaImporter.x - direct.x) < 1e-12 && std::fabs(viaImporter.y - direct.y) < 1e-12
                         && std::fabs(viaImporter.z - direct.z) < 1e-12;
    }
    check(importerAgrees, "export frame + the Workbench importer's (x, z, −y) = the declared model axes");
    const auto identity = cadToExport({"-y", "+z"}, {0.3, -1.7, 2.9});
    check(identity.isOk() && std::fabs(identity.value().x - 0.3) < 1e-15 && std::fabs(identity.value().y + 1.7) < 1e-15
              && std::fabs(identity.value().z - 2.9) < 1e-15,
          "with the Workbench's own convention (nose −Y, Z up) the export frame is the CAD frame");
    check(!cadToModel({"+x", "-x"}, {1, 0, 0}).isOk() && !cadToModel({"+x", "+x"}, {1, 0, 0}).isOk() && !cadToModel({"x", "+z"}, {1, 0, 0}).isOk(),
          "parallel or malformed axes are refused");

    // Refusals.
    {
        ConstructionBuildRequest bare = request;
        bare.bodies[1].materialId.clear();
        const auto refused = buildConstruction(kernel, bare);
        check(!refused.isOk() && refused.error().message.find("Луч") != std::string::npos && refused.error().message.find("материал") != std::string::npos,
              "a body without material is refused by name", refused.isOk() ? "accepted" : refused.error().message);
    }

    // JSON round-trip and the contract with Swift.
    const std::string jsonText = ConstructionExport::toJson(frame);
    const auto loaded = ConstructionExport::fromJson(jsonText);
    check(loaded.isOk() && loaded.value().bodies.size() == 2 && loaded.value().bodies[1].brep == frame.bodies[1].brep
              && loaded.value().bodies[0].faces.size() == frame.bodies[0].faces.size() && loaded.value().cadAxes.forward == "+x"
              && ConstructionExport::toJson(loaded.value()) == jsonText,
          "JSON round-trips (BRep text byte for byte, faces, axes)");
    json::JsonValue produced, fixture;
    std::string error;
    json::parseJson(jsonText, produced, error);
    const std::filesystem::path fixturePath = schemaDirectory / "uavframe-v2.example.json";
    const bool haveFixture = json::parseJson(readText(fixturePath), fixture, error);
    const auto* producedBodies = produced.member("bodies");
    const auto* fixtureBodies = fixture.member("bodies");
    const bool sameKeys = haveFixture && keys(&produced) == keys(&fixture) && producedBodies && fixtureBodies
                          && !fixtureBodies->arrayItems.empty() && keys(&producedBodies->arrayItems[0]) == keys(&fixtureBodies->arrayItems[0])
                          && keys(producedBodies->arrayItems[0].member("geometry")) == keys(fixtureBodies->arrayItems[0].member("geometry"));
    check(sameKeys, "keys match schema/uavframe-v2.example.json");
    if (!sameKeys) {
        const auto kept = std::filesystem::temp_directory_path() / "uavframe-v2.produced.json";
        std::ofstream(kept, std::ios::binary) << jsonText;
        std::printf("  produced file kept at %s\n", kept.c_str());
    }
    return fea_test::finish("test_construction_builder");
}
