#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>

namespace {

cadnext::SketchProfile cutterProfile(bool valid = true) {
    cadnext::SketchProfile profile;
    profile.id = "profile-cut-square";
    profile.sketchId = "sketch-cut";
    profile.kind = cadnext::SketchProfileKind::Polygon;
    profile.outerLoop = {
        {-0.2, -0.2},
        {0.2, -0.2},
        {0.2, 0.2},
        {-0.2, 0.2},
    };
    profile.area = 0.16;
    profile.isClosed = valid;
    profile.isValid = valid;
    profile.sourceEntityIds = {"l1", "l2", "l3", "l4"};
    return profile;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);

    cadnext::kernel::BoxParameters box;
    box.width = 1.0;
    box.depth = 1.0;
    box.height = 1.0;
    const cadnext::Result<cadnext::kernel::ShapeHandle> target = kernel.makeBox(box);
    assert(target.isOk());
    assert(kernel.isShapeValid(target.value()));

    const cadnext::SketchReference reference =
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY);
    cadnext::CutSpan span;
    span.start = -1.0;
    span.end = 1.0;

    const cadnext::Result<cadnext::kernel::EvaluatedGeometry> cut =
        evaluator.evaluateExtrudeCut(target.value(), reference, cutterProfile(), span);
    assert(cut.isOk());
    assert(cut.value().isValid);
    assert(!cut.value().shape.isNull());
    assert(cut.value().shape.id() != target.value().id());
    assert(!cut.value().previewMesh.isEmpty());
    assert(kernel.isShapeValid(cut.value().shape));
    assert(kernel.boundingBox(cut.value().shape).isOk());

    cadnext::SketchProfile openProfile = cutterProfile(false);
    const cadnext::Result<cadnext::kernel::EvaluatedGeometry> invalidCut =
        evaluator.evaluateExtrudeCut(target.value(), reference, openProfile, span);
    assert(!invalidCut.isOk());

    return 0;
}
