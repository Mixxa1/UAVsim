#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/StubKernel.hpp"

#include <cassert>

// Runs in every build configuration: with the stub kernel the evaluator
// must degrade gracefully (ok result, isValid=false, explanatory message)
// so the GUI can fall back to procedural primitives.
int main() {
    cadnext::kernel::StubKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);

    cadnext::Object box;
    box.id = "obj-box";
    box.name = "Box 1";
    box.type = cadnext::ObjectType::Body;
    box.primitive.kind = cadnext::PrimitiveKind::Box;

    const auto result = evaluator.evaluateObject(box);
    assert(result.isOk());
    assert(!result.value().isValid);
    assert(!result.value().message.empty());

    // Reference plane stays a viewer-only helper in every configuration.
    cadnext::Object plane;
    plane.id = "obj-plane";
    plane.type = cadnext::ObjectType::ReferencePlane;
    const auto planeResult = evaluator.evaluateObject(plane);
    assert(planeResult.isOk());
    assert(!planeResult.value().isValid);

    // No primitive descriptor is still a usage error.
    cadnext::Object none;
    none.id = "obj-none";
    none.type = cadnext::ObjectType::Body;
    const auto noneResult = evaluator.evaluateObject(none);
    assert(!noneResult.isOk());

    return 0;
}
