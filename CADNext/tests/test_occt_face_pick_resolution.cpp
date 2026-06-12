// CADNext 0.8A (OCCT only): a picked mesh triangle faceId resolves to a
// FaceReference; body fallback is only needed for triangles without ids.

#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/MeshExtractor.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <string>
#include <vector>

namespace {

const cadnext::kernel::FaceReference* findFace(
    const std::vector<cadnext::kernel::FaceReference>& faces,
    const std::string& faceId) {
    for (const cadnext::kernel::FaceReference& face : faces) {
        if (face.faceId == faceId) {
            return &face;
        }
    }
    return nullptr;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    auto extractor = cadnext::kernel::makeMeshExtractor();
    const cadnext::Result<cadnext::kernel::TriangleMesh> mesh =
        extractor->extract(kernel, box.value());
    assert(mesh.isOk());
    assert(!mesh.value().triangles.empty());

    cadnext::kernel::FaceAnalyzer analyzer(kernel);
    const std::vector<cadnext::kernel::FaceReference> faces =
        analyzer.planarFacesForBody("body-box", box.value());

    const int pickedTriangle = 0;
    const std::string pickedFaceId = mesh.value().triangles[pickedTriangle].faceId;
    assert(!pickedFaceId.empty());

    const cadnext::kernel::FaceReference* face = findFace(faces, pickedFaceId);
    assert(face);
    assert(face->isSketchable);
    assert(face->bodyId == "body-box");

    cadnext::kernel::MeshTriangle missingOwnership = mesh.value().triangles[pickedTriangle];
    missingOwnership.faceId.clear();
    assert(missingOwnership.faceId.empty());

    return 0;
}
