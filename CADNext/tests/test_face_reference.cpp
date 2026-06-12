// CADNext 0.8: FaceReference model + makeFaceId stability. Runs in every
// build: with the stub kernel the analyzer must simply return no faces
// (face workflows stay unavailable without a BRep backend).

#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/StubKernel.hpp"

#include <cassert>
#include <cmath>
#include <string>

int main() {
    using cadnext::Vector3;
    using cadnext::kernel::FaceKind;
    using cadnext::kernel::FaceReference;
    using cadnext::kernel::makeFaceId;

    // Defaults: a fresh reference is not sketchable and carries an
    // orthonormal default frame.
    FaceReference reference;
    assert(reference.kind == FaceKind::Other);
    assert(!reference.isSketchable);
    assert(reference.previewMesh.isEmpty());

    // Identical quantized inputs reproduce the identical id (the save/load
    // re-resolution contract for simple bodies).
    const Vector3 normal{0.0, 0.0, 1.0};
    const Vector3 center{1.0, 2.0, 3.0};
    const std::string id = makeFaceId(4, normal, center, 6.0);
    assert(id == makeFaceId(4, normal, center, 6.0));
    assert(id.rfind("face-4-", 0) == 0);

    // Sub-quantum noise (1e-3 grid) keeps the id stable.
    assert(id == makeFaceId(4, {1.0e-5, -1.0e-5, 1.0}, {1.0 + 1.0e-5, 2.0, 3.0},
                            6.0 + 1.0e-5));

    // Index, normal, center and area each separate the id.
    assert(id != makeFaceId(5, normal, center, 6.0));
    assert(id != makeFaceId(4, {0.0, 0.0, -1.0}, center, 6.0));
    assert(id != makeFaceId(4, normal, {1.0, 2.0, 3.5}, 6.0));
    assert(id != makeFaceId(4, normal, center, 7.0));

    // The id is never the bare "face-<index>" form.
    assert(id.size() > std::string("face-4").size());

    // Non-finite input must not crash and still yields a deterministic id.
    const std::string nanId =
        makeFaceId(0, {std::nan(""), 0.0, 0.0}, {0.0, 0.0, 0.0}, 0.0);
    assert(nanId == makeFaceId(0, {std::nan(""), 0.0, 0.0}, {0.0, 0.0, 0.0}, 0.0));

    // Stub backend: no faces, no crash.
    cadnext::kernel::StubKernel kernel;
    cadnext::kernel::FaceAnalyzer analyzer(kernel);
    const auto boxResult = kernel.makeBox({1.0, 1.0, 1.0});
    assert(boxResult.isOk());
    assert(analyzer.planarFacesForBody("body-1", boxResult.value()).empty());

    return 0;
}
