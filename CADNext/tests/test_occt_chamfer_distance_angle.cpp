#include "cadnext/Chamfer.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>

int main() {
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);

    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    cadnext::kernel::EdgeAnalyzer analyzer(kernel);
    const auto edges = analyzer.edgesForBody("body-1", box.value());
    assert(edges.size() == 12);

    cadnext::ChamferParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {edges.front().edgeId};
    parameters.mode = cadnext::ChamferMode::DistanceAngle;
    parameters.distanceMm = 50.0;
    parameters.angleDeg = 45.0;
    assert(cadnext::chamferParametersValid(parameters));

    const auto evaluated = evaluator.evaluateChamfer(box.value(), parameters);
    assert(evaluated.isOk());
    assert(evaluated.value().isValid);
    assert(!evaluated.value().shape.isNull());
    assert(!evaluated.value().previewMesh.isEmpty());
    assert(kernel.isShapeValid(evaluated.value().shape));

    const auto rebuiltEdges =
        analyzer.edgesForBody("body-1", evaluated.value().shape);
    assert(!rebuiltEdges.empty());

    parameters.angleDeg = 0.0;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.angleDeg = 90.0;
    assert(!cadnext::chamferParametersValid(parameters));

    return 0;
}
