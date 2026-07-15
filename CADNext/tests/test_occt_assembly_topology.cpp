// Assembly topology extraction: cylindrical face axis/radius, circular
// edge axis/radius and vertex references on OCCT primitives.
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/VertexAnalyzer.hpp"

#include <cassert>
#include <cmath>

namespace {

bool nearlyEqual(double a, double b, double tolerance = 1.0e-6) {
    return std::fabs(a - b) <= tolerance;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());

    // Cylinder r=0.5 h=2: one cylindrical side face + two planar caps,
    // two circular edges, no isolated vertices expected beyond the seam.
    const auto cylinder = kernel.makeCylinder({0.5, 2.0});
    assert(cylinder.isOk());

    cadnext::kernel::FaceAnalyzer faceAnalyzer(kernel);
    const auto faces = faceAnalyzer.planarFacesForBody("body-1", cylinder.value());
    assert(faces.size() == 3);

    int cylindricalCount = 0;
    int planarCount = 0;
    for (const cadnext::kernel::FaceReference& face : faces) {
        if (face.kind == cadnext::kernel::FaceKind::Cylindrical) {
            ++cylindricalCount;
            assert(nearlyEqual(face.radius, 0.5, 1.0e-9));
            // Kernel cylinders are extruded along local Z.
            assert(nearlyEqual(std::fabs(face.axisDirection.z), 1.0));
            assert(nearlyEqual(face.axisDirection.x, 0.0));
            assert(nearlyEqual(face.axisDirection.y, 0.0));
            assert(nearlyEqual(face.axisOrigin.x, 0.0));
            assert(nearlyEqual(face.axisOrigin.y, 0.0));
        } else if (face.kind == cadnext::kernel::FaceKind::Planar) {
            ++planarCount;
            // Planar faces never carry axis data.
            assert(face.radius == 0.0);
        }
    }
    assert(cylindricalCount == 1);
    assert(planarCount == 2);

    cadnext::kernel::EdgeAnalyzer edgeAnalyzer(kernel);
    const auto edges = edgeAnalyzer.edgesForBody("body-1", cylinder.value());
    int circleCount = 0;
    for (const cadnext::kernel::EdgeReference& edge : edges) {
        if (edge.kind != cadnext::kernel::EdgeKind::Circle) {
            continue;
        }
        ++circleCount;
        assert(nearlyEqual(edge.radius, 0.5, 1.0e-9));
        assert(nearlyEqual(std::fabs(edge.axisDirection.z), 1.0));
        assert(nearlyEqual(edge.center.x, 0.0));
        assert(nearlyEqual(edge.center.y, 0.0));
        assert(nearlyEqual(std::fabs(edge.center.z), 1.0));
    }
    assert(circleCount == 2);

    // Box 1x1x1: 8 unique corner vertices with reproducible ids.
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    cadnext::kernel::VertexAnalyzer vertexAnalyzer(kernel);
    const auto vertices = vertexAnalyzer.verticesForBody("body-2", box.value());
    assert(vertices.size() == 8);
    for (const cadnext::kernel::VertexReference& vertex : vertices) {
        assert(vertex.bodyId == "body-2");
        assert(vertex.vertexId.rfind("vertex-", 0) == 0);
        assert(nearlyEqual(std::fabs(vertex.position.x), 0.5));
        assert(nearlyEqual(std::fabs(vertex.position.y), 0.5));
        assert(nearlyEqual(std::fabs(vertex.position.z), 0.5));
    }

    // Re-analysis of the same shape reproduces identical vertex ids.
    const auto verticesAgain = vertexAnalyzer.verticesForBody("body-2", box.value());
    assert(verticesAgain.size() == vertices.size());
    for (size_t i = 0; i < vertices.size(); ++i) {
        assert(vertices[i].vertexId == verticesAgain[i].vertexId);
    }

    const auto missing = vertexAnalyzer.verticesForBody(
        "body-2", cadnext::kernel::ShapeHandle("missing"));
    assert(missing.empty());

    return 0;
}
