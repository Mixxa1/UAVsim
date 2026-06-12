// CADNext 0.8 (OCCT only): planar face extraction from real BRep bodies —
// face count and classification, orthonormal frames, outward normals,
// id stability across re-analysis, and curved faces being unsketchable.

#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <cmath>
#include <set>
#include <string>
#include <vector>

namespace {

using cadnext::Vector3;
using cadnext::kernel::FaceKind;
using cadnext::kernel::FaceReference;

double dot(const Vector3& a, const Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vector3 cross(const Vector3& a, const Vector3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

double length(const Vector3& v) {
    return std::sqrt(dot(v, v));
}

bool finite(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

void assertPlanarFrame(const FaceReference& face) {
    assert(face.kind == FaceKind::Planar);
    assert(face.isSketchable);
    assert(finite(face.origin) && finite(face.uAxis) && finite(face.vAxis) &&
           finite(face.normal));
    // Unit axes, mutually orthogonal, right-handed (u x v == normal).
    assert(std::fabs(length(face.uAxis) - 1.0) < 1.0e-6);
    assert(std::fabs(length(face.vAxis) - 1.0) < 1.0e-6);
    assert(std::fabs(length(face.normal) - 1.0) < 1.0e-6);
    assert(std::fabs(dot(face.uAxis, face.vAxis)) < 1.0e-6);
    assert(std::fabs(dot(face.uAxis, face.normal)) < 1.0e-6);
    assert(std::fabs(dot(face.vAxis, face.normal)) < 1.0e-6);
    const Vector3 handed = cross(face.uAxis, face.vAxis);
    assert(std::fabs(handed.x - face.normal.x) < 1.0e-6);
    assert(std::fabs(handed.y - face.normal.y) < 1.0e-6);
    assert(std::fabs(handed.z - face.normal.z) < 1.0e-6);
    assert(face.width > 0.0 && face.height > 0.0);
    assert(!face.previewMesh.isEmpty());
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());
    cadnext::kernel::FaceAnalyzer analyzer(kernel);

    // --- Box 2 x 3 x 1 (width=X, depth=Y, height=Z) ----------------------
    const auto box = kernel.makeBox({2.0, 1.0, 3.0});
    assert(box.isOk());
    const std::vector<FaceReference> boxFaces =
        analyzer.planarFacesForBody("body-box", box.value());
    assert(boxFaces.size() == 6);

    std::set<std::string> ids;
    int outwardNormals = 0;
    for (const FaceReference& face : boxFaces) {
        assert(face.bodyId == "body-box");
        assertPlanarFrame(face);
        assert(!face.faceId.empty());
        assert(face.faceId.rfind("face-", 0) == 0);
        ids.insert(face.faceId);
        // Box is centered on the origin: every outward normal points away
        // from the center, so dot(origin, normal) > 0 for all six faces.
        if (dot(face.origin, face.normal) > 1.0e-9) {
            ++outwardNormals;
        }
        // Expected face areas: 2x3 (Y faces), 2x1 (Z faces), 3x1 (X faces).
        const bool knownArea = std::fabs(face.area - 6.0) < 1.0e-3 ||
                               std::fabs(face.area - 2.0) < 1.0e-3 ||
                               std::fabs(face.area - 3.0) < 1.0e-3;
        assert(knownArea);
    }
    assert(ids.size() == 6);
    assert(outwardNormals == 6);

    // Re-analysis of the same shape reproduces the same ids in the same
    // order (stable within the evaluated body state).
    const std::vector<FaceReference> boxFacesAgain =
        analyzer.planarFacesForBody("body-box", box.value());
    assert(boxFacesAgain.size() == boxFaces.size());
    for (size_t i = 0; i < boxFaces.size(); ++i) {
        assert(boxFaces[i].faceId == boxFacesAgain[i].faceId);
    }

    // A re-evaluated identical recipe (fresh shape, same parameters) also
    // reproduces the ids — the save/load contract for simple bodies.
    const auto boxRebuilt = kernel.makeBox({2.0, 1.0, 3.0});
    assert(boxRebuilt.isOk());
    const std::vector<FaceReference> rebuiltFaces =
        analyzer.planarFacesForBody("body-box", boxRebuilt.value());
    assert(rebuiltFaces.size() == boxFaces.size());
    for (size_t i = 0; i < boxFaces.size(); ++i) {
        assert(rebuiltFaces[i].faceId == boxFaces[i].faceId);
    }

    // --- Extruded rectangle profile --------------------------------------
    cadnext::kernel::ExtrudedPolygonParameters prism;
    prism.loop = {{0.0, 0.0, 0.0}, {2.0, 0.0, 0.0}, {2.0, 1.0, 0.0}, {0.0, 1.0, 0.0}};
    prism.extrusion = {0.0, 0.0, 0.75};
    const auto extruded = kernel.makeExtrudedPolygon(prism);
    assert(extruded.isOk());
    const std::vector<FaceReference> prismFaces =
        analyzer.planarFacesForBody("body-extrude", extruded.value());
    assert(prismFaces.size() == 6);
    bool hasTopFace = false;
    for (const FaceReference& face : prismFaces) {
        assertPlanarFrame(face);
        if (std::fabs(face.normal.z - 1.0) < 1.0e-6 &&
            std::fabs(face.origin.z - 0.75) < 1.0e-6) {
            hasTopFace = true;
        }
    }
    assert(hasTopFace);

    // --- Cylinder: planar caps sketchable, lateral face not --------------
    const auto cylinder = kernel.makeCylinder({0.5, 1.0});
    assert(cylinder.isOk());
    const std::vector<FaceReference> cylinderFaces =
        analyzer.planarFacesForBody("body-cylinder", cylinder.value());
    assert(cylinderFaces.size() == 3);
    int planarCount = 0;
    int curvedCount = 0;
    for (const FaceReference& face : cylinderFaces) {
        if (face.kind == FaceKind::Planar) {
            assertPlanarFrame(face);
            ++planarCount;
        } else {
            assert(face.kind == FaceKind::Cylindrical);
            assert(!face.isSketchable);
            ++curvedCount;
        }
    }
    assert(planarCount == 2);
    assert(curvedCount == 1);

    // Unknown handles yield no faces instead of crashing.
    assert(analyzer.planarFacesForBody("body-x", cadnext::kernel::ShapeHandle("nope"))
               .empty());

    return 0;
}
