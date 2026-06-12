#include "cadnext/Chamfer.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>

int main() {
    cadnext::kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    cadnext::kernel::EdgeAnalyzer analyzer(kernel);
    const auto edges = analyzer.edgesForBody("body-1", box.value());
    assert(edges.size() == 12);

    cadnext::ChamferParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {edges.front().edgeId};
    parameters.mode = cadnext::ChamferMode::EqualDistance;
    parameters.distanceMm = 100.0;
    assert(cadnext::chamferParametersValid(parameters));

    const auto direct =
        kernel.chamferEdges(box.value(), parameters.edgeIds, 0.1,
                            parameters.mode, parameters.angleDeg);
    assert(direct.isOk());
    assert(!direct.value().isNull());
    assert(kernel.isShapeValid(direct.value()));

    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    const auto evaluated = evaluator.evaluateChamfer(box.value(), parameters);
    assert(evaluated.isOk());
    assert(evaluated.value().isValid);
    assert(!evaluated.value().shape.isNull());
    assert(!evaluated.value().previewMesh.isEmpty());

    parameters.distanceMm = 0.0;
    assert(!cadnext::chamferParametersValid(parameters));

    return 0;
}
