#include "cadnext/Fillet.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <cmath>
#include <limits>

namespace {

double meshArea(const cadnext::kernel::TriangleMesh& mesh) {
    double area = 0.0;
    for (const cadnext::kernel::MeshTriangle& triangle : mesh.triangles) {
        const cadnext::kernel::MeshVertex& a = mesh.vertices[triangle.a];
        const cadnext::kernel::MeshVertex& b = mesh.vertices[triangle.b];
        const cadnext::kernel::MeshVertex& c = mesh.vertices[triangle.c];
        const double ux = b.x - a.x;
        const double uy = b.y - a.y;
        const double uz = b.z - a.z;
        const double vx = c.x - a.x;
        const double vy = c.y - a.y;
        const double vz = c.z - a.z;
        const double cx = uy * vz - uz * vy;
        const double cy = uz * vx - ux * vz;
        const double cz = ux * vy - uy * vx;
        area += 0.5 * std::sqrt(cx * cx + cy * cy + cz * cz);
    }
    return area;
}

const cadnext::kernel::EdgeReference* nearestEdge(
    const std::vector<cadnext::kernel::EdgeReference>& edges,
    cadnext::Vector3 targetCenter) {
    const cadnext::kernel::EdgeReference* best = nullptr;
    double bestDistance2 = std::numeric_limits<double>::infinity();
    for (const cadnext::kernel::EdgeReference& edge : edges) {
        const double dx = edge.center.x - targetCenter.x;
        const double dy = edge.center.y - targetCenter.y;
        const double dz = edge.center.z - targetCenter.z;
        const double d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestDistance2) {
            best = &edge;
            bestDistance2 = d2;
        }
    }
    return best;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    cadnext::kernel::EdgeAnalyzer analyzer(kernel);
    const auto edges = analyzer.edgesForBody("body-1", box.value());
    assert(edges.size() == 12);

    cadnext::FilletParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {edges.front().edgeId};
    parameters.radiusMm = 100.0;
    assert(cadnext::filletParametersValid(parameters));

    const auto direct = kernel.filletEdges(box.value(), parameters.edgeIds, 0.1);
    assert(direct.isOk());
    assert(!direct.value().isNull());
    assert(kernel.isShapeValid(direct.value()));

    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    const auto evaluated = evaluator.evaluateFillet(box.value(), parameters);
    assert(evaluated.isOk());
    assert(evaluated.value().isValid);
    assert(!evaluated.value().shape.isNull());
    assert(!evaluated.value().previewMesh.isEmpty());

    cadnext::FilletParameters larger = parameters;
    larger.radiusMm = 200.0;
    const auto evaluatedLarger = evaluator.evaluateFillet(box.value(), larger);
    assert(evaluatedLarger.isOk());
    assert(evaluatedLarger.value().isValid);
    assert(!evaluatedLarger.value().previewMesh.isEmpty());
    assert(std::fabs(meshArea(evaluated.value().previewMesh) -
                     meshArea(evaluatedLarger.value().previewMesh)) > 1.0e-4);

    cadnext::FilletParameters tiny;
    tiny.targetBodyId = "body-1";
    const cadnext::kernel::EdgeReference* leftVertical =
        nearestEdge(edges, {-0.5, -0.5, 0.0});
    assert(leftVertical);
    tiny.edgeIds = {leftVertical->edgeId};
    tiny.radiusMm = 1.0;
    const auto tinyFillet = evaluator.evaluateFillet(box.value(), tiny);
    assert(tinyFillet.isOk());
    assert(tinyFillet.value().isValid);

    const auto afterTinyEdges =
        analyzer.edgesForBody("body-1", tinyFillet.value().shape);
    const cadnext::kernel::EdgeReference* rightVertical =
        nearestEdge(afterTinyEdges, {0.5, -0.5, 0.0});
    assert(rightVertical);
    cadnext::FilletParameters huge;
    huge.targetBodyId = "body-1";
    huge.edgeIds = {rightVertical->edgeId};
    huge.radiusMm = 480.0;
    const auto asymmetric = evaluator.evaluateFillet(tinyFillet.value().shape, huge);
    assert(asymmetric.isOk());
    assert(asymmetric.value().isValid);
    assert(!asymmetric.value().previewMesh.isEmpty());
    assert(std::fabs(meshArea(tinyFillet.value().previewMesh) -
                     meshArea(asymmetric.value().previewMesh)) > 0.1);

    parameters.radiusMm = 0.0;
    assert(!cadnext::filletParametersValid(parameters));

    return 0;
}
