#include "cadnext/Fillet.hpp"
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

    parameters.radiusMm = 0.0;
    assert(!cadnext::filletParametersValid(parameters));

    return 0;
}
