#include "cadnext/kernel/MeshExtractor.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <cmath>

namespace {

void verifyMesh(const cadnext::kernel::TriangleMesh& mesh) {
    assert(!mesh.isEmpty());
    assert(mesh.vertices.size() >= 3);
    assert(!mesh.triangles.empty());

    const auto vertexCount = static_cast<std::uint32_t>(mesh.vertices.size());
    for (const auto& triangle : mesh.triangles) {
        assert(triangle.a < vertexCount);
        assert(triangle.b < vertexCount);
        assert(triangle.c < vertexCount);
    }
    for (const auto& vertex : mesh.vertices) {
        assert(std::isfinite(vertex.x));
        assert(std::isfinite(vertex.y));
        assert(std::isfinite(vertex.z));
    }
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    const auto extractor = cadnext::kernel::makeMeshExtractor();
    assert(extractor);

    const auto box = kernel.makeBox({2.0, 1.0, 1.5});
    assert(box.isOk());
    const auto boxMesh = extractor->extract(kernel, box.value());
    assert(boxMesh.isOk());
    verifyMesh(boxMesh.value());
    // A box meshes into at least two triangles per face.
    assert(boxMesh.value().triangles.size() >= 12);

    const auto cylinder = kernel.makeCylinder({0.5, 1.2});
    assert(cylinder.isOk());
    const auto cylinderMesh = extractor->extract(kernel, cylinder.value());
    assert(cylinderMesh.isOk());
    verifyMesh(cylinderMesh.value());

    const auto sphere = kernel.makeSphere({0.6});
    assert(sphere.isOk());
    const auto sphereMesh = extractor->extract(kernel, sphere.value());
    assert(sphereMesh.isOk());
    verifyMesh(sphereMesh.value());

    // Unknown handles fail cleanly.
    const auto unknown = extractor->extract(kernel, cadnext::kernel::ShapeHandle("missing"));
    assert(!unknown.isOk());
    assert(unknown.error().code == cadnext::ErrorCode::NotFound);

    return 0;
}
