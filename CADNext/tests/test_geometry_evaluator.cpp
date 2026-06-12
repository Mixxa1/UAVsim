#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>

namespace {

cadnext::Object makeObject(const char* id, cadnext::PrimitiveKind kind) {
    cadnext::Object object;
    object.id = id;
    object.name = id;
    object.type = cadnext::ObjectType::Body;
    object.primitive.kind = kind;
    return object;
}

} // namespace

int main() {
    cadnext::kernel::OcctKernel kernel;
    cadnext::kernel::GeometryEvaluator evaluator(kernel);

    // Box.
    cadnext::Object box = makeObject("obj-box", cadnext::PrimitiveKind::Box);
    box.primitive.width = 2.0;
    box.primitive.depth = 1.0;
    box.primitive.height = 0.5;
    const auto boxResult = evaluator.evaluateObject(box);
    assert(boxResult.isOk());
    assert(boxResult.value().isValid);
    assert(boxResult.value().objectId == "obj-box");
    assert(!boxResult.value().shape.isNull());
    assert(!boxResult.value().previewMesh.isEmpty());

    // Cylinder.
    cadnext::Object cylinder = makeObject("obj-cyl", cadnext::PrimitiveKind::Cylinder);
    cylinder.primitive.radius = 0.5;
    cylinder.primitive.height = 1.2;
    const auto cylinderResult = evaluator.evaluateObject(cylinder);
    assert(cylinderResult.isOk());
    assert(cylinderResult.value().isValid);
    assert(!cylinderResult.value().previewMesh.isEmpty());

    // Sphere.
    cadnext::Object sphere = makeObject("obj-sphere", cadnext::PrimitiveKind::Sphere);
    sphere.primitive.radius = 0.6;
    const auto sphereResult = evaluator.evaluateObject(sphere);
    assert(sphereResult.isOk());
    assert(sphereResult.value().isValid);
    assert(!sphereResult.value().previewMesh.isEmpty());

    // Dimension change → fresh evaluated geometry, also valid.
    box.primitive.width = 4.0;
    const auto resized = evaluator.evaluateObject(box);
    assert(resized.isOk());
    assert(resized.value().isValid);
    assert(resized.value().shape.id() != boxResult.value().shape.id());
    assert(!resized.value().previewMesh.isEmpty());

    // Reference plane: viewer-only helper, no crash, clear message.
    cadnext::Object plane;
    plane.id = "obj-plane";
    plane.name = "Plane 1";
    plane.type = cadnext::ObjectType::ReferencePlane;
    const auto planeResult = evaluator.evaluateObject(plane);
    assert(planeResult.isOk());
    assert(!planeResult.value().isValid);
    assert(!planeResult.value().message.empty());

    // Invalid dimensions surface as a failed Result.
    cadnext::Object badBox = makeObject("obj-bad", cadnext::PrimitiveKind::Box);
    badBox.primitive.width = -1.0;
    const auto badResult = evaluator.evaluateObject(badBox);
    assert(!badResult.isOk());
    assert(badResult.error().code == cadnext::ErrorCode::InvalidArgument);

    // Objects without a primitive descriptor are usage errors.
    const auto none = evaluator.evaluateObject(makeObject("obj-none", cadnext::PrimitiveKind::None));
    assert(!none.isOk());

    return 0;
}
