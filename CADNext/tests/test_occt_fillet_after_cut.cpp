#include "cadnext/Fillet.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>

namespace {

cadnext::SketchProfile cutterProfile() {
    cadnext::SketchProfile profile;
    profile.id = "profile-cut-square";
    profile.sketchId = "sketch-cut";
    profile.kind = cadnext::SketchProfileKind::Polygon;
    profile.outerLoop = {{-0.2, -0.2}, {0.2, -0.2}, {0.2, 0.2}, {-0.2, 0.2}};
    profile.area = 0.16;
    profile.isClosed = true;
    profile.isValid = true;
    return profile;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);
    cadnext::kernel::EdgeAnalyzer analyzer(kernel);

    const auto box = kernel.makeBox({1.0, 1.0, 1.0});
    assert(box.isOk());

    cadnext::CutSpan span;
    span.start = -1.0;
    span.end = 1.0;
    const auto cut = evaluator.evaluateExtrudeCut(
        box.value(), cadnext::canonicalSketchReference(cadnext::SketchPlane::XY),
        cutterProfile(), span);
    assert(cut.isOk());
    assert(cut.value().isValid);

    const auto edgesAfterCut = analyzer.edgesForBody("body-1", cut.value().shape);
    assert(edgesAfterCut.size() > 12);

    cadnext::FilletParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {edgesAfterCut.front().edgeId};
    parameters.radiusMm = 20.0;

    const auto fillet = evaluator.evaluateFillet(cut.value().shape, parameters);
    assert(fillet.isOk());
    assert(fillet.value().isValid);
    assert(!fillet.value().previewMesh.isEmpty());
    assert(kernel.isShapeValid(fillet.value().shape));

    return 0;
}
