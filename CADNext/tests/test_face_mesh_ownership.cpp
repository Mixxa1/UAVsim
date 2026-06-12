// CADNext 0.8A: mesh triangles can carry face ownership, and mesh-only
// face references can be derived from that ownership for procedural bodies.

#include "cadnext/kernel/FaceAnalyzer.hpp"

#include <cassert>
#include <set>
#include <string>

int main() {
    cadnext::kernel::TriangleMesh mesh;
    mesh.vertices = {{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0},
                     {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}, {1.0, 0.0, 1.0},
                     {1.0, 1.0, 1.0}, {0.0, 1.0, 1.0}};
    mesh.triangles = {
        {0, 1, 2, "face-bottom"},
        {0, 2, 3, "face-bottom"},
        {4, 6, 5, "face-top"},
        {4, 7, 6, "face-top"},
    };

    for (const cadnext::kernel::MeshTriangle& triangle : mesh.triangles) {
        assert(!triangle.faceId.empty());
    }

    const std::vector<cadnext::kernel::FaceReference> faces =
        cadnext::kernel::planarFacesForMesh("body-1", mesh);
    assert(faces.size() == 2);

    std::set<std::string> ids;
    for (const cadnext::kernel::FaceReference& face : faces) {
        assert(face.bodyId == "body-1");
        assert(face.kind == cadnext::kernel::FaceKind::Planar);
        assert(face.isSketchable);
        assert(face.area > 0.0);
        assert(!face.previewMesh.isEmpty());
        ids.insert(face.faceId);
        for (const cadnext::kernel::MeshTriangle& triangle : face.previewMesh.triangles) {
            assert(triangle.faceId == face.faceId);
        }
    }
    assert(ids.count("face-bottom") == 1);
    assert(ids.count("face-top") == 1);

    return 0;
}
