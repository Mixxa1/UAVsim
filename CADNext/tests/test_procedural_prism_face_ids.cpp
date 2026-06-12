// CADNext 0.8A: procedural prism/extrude meshes assign a non-empty faceId
// to every rendered triangle, including shared cap ids and per-side ids.

#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/ExtrudeMesh.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"

#include <cassert>
#include <map>
#include <string>

int main() {
    cadnext::SketchProfile profile;
    profile.id = "profile-rect";
    profile.kind = cadnext::SketchProfileKind::Rectangle;
    profile.outerLoop = {{-0.5, -0.25}, {0.5, -0.25}, {0.5, 0.25}, {-0.5, 0.25}};
    profile.area = 0.5;
    profile.isClosed = true;
    profile.isValid = true;

    const cadnext::SketchReference reference =
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY);
    const cadnext::Result<cadnext::kernel::TriangleMesh> mesh =
        cadnext::kernel::buildProfilePrismMesh(reference, profile, 0.0, 1.0);
    assert(mesh.isOk());
    assert(!mesh.value().isEmpty());

    std::map<std::string, int> counts;
    for (const cadnext::kernel::MeshTriangle& triangle : mesh.value().triangles) {
        assert(!triangle.faceId.empty());
        ++counts[triangle.faceId];
    }
    assert(counts["face-cap-start"] == 2);
    assert(counts["face-cap-end"] == 2);
    assert(counts["face-side-0"] == 2);
    assert(counts["face-side-1"] == 2);
    assert(counts["face-side-2"] == 2);
    assert(counts["face-side-3"] == 2);

    const std::vector<cadnext::kernel::FaceReference> faces =
        cadnext::kernel::planarFacesForMesh("body-prism", mesh.value());
    assert(faces.size() == 6);
    for (const cadnext::kernel::FaceReference& face : faces) {
        assert(face.isSketchable);
        assert(face.area > 0.0);
    }

    return 0;
}
