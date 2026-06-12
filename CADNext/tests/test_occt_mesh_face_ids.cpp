// CADNext 0.8A (OCCT only): mesh extraction preserves TopoDS_Face
// ownership by assigning face ids that match FaceAnalyzer ids.

#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/MeshExtractor.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <set>
#include <string>

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());

    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    auto extractor = cadnext::kernel::makeMeshExtractor();
    const cadnext::Result<cadnext::kernel::TriangleMesh> mesh =
        extractor->extract(kernel, box.value());
    assert(mesh.isOk());
    assert(!mesh.value().isEmpty());

    std::set<std::string> meshFaceIds;
    for (const cadnext::kernel::MeshTriangle& triangle : mesh.value().triangles) {
        assert(!triangle.faceId.empty());
        meshFaceIds.insert(triangle.faceId);
    }
    assert(meshFaceIds.size() == 6);

    cadnext::kernel::FaceAnalyzer analyzer(kernel);
    const std::vector<cadnext::kernel::FaceReference> faces =
        analyzer.planarFacesForBody("body-box", box.value());
    assert(faces.size() == 6);
    std::set<std::string> analyzerFaceIds;
    for (const cadnext::kernel::FaceReference& face : faces) {
        analyzerFaceIds.insert(face.faceId);
    }
    assert(meshFaceIds == analyzerFaceIds);

    return 0;
}
