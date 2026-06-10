#include "cadnext/kernel/GeometryEvaluator.hpp"

namespace cadnext::kernel {

namespace {

cadnext::Result<EvaluatedGeometry> usageError(std::string message) {
    return cadnext::Result<EvaluatedGeometry>::fail(
        {cadnext::ErrorCode::InvalidArgument, std::move(message)});
}

EvaluatedGeometry helperResult(const cadnext::Object& object, std::string message) {
    EvaluatedGeometry geometry;
    geometry.objectId = object.id;
    geometry.isValid = false;
    geometry.message = std::move(message);
    return geometry;
}

} // namespace

GeometryEvaluator::GeometryEvaluator(Kernel& kernel)
    : kernel_(kernel), meshExtractor_(makeMeshExtractor()) {}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateObject(
    const cadnext::Object& object) {
    using cadnext::PrimitiveKind;

    if (object.type == cadnext::ObjectType::ReferencePlane) {
        return cadnext::Result<EvaluatedGeometry>::ok(helperResult(
            object, "Reference Plane is a viewer-only helper in CADNext 0.4"));
    }

    cadnext::Result<ShapeHandle> shape =
        cadnext::Result<ShapeHandle>::fail({cadnext::ErrorCode::InvalidArgument, ""});
    switch (object.primitive.kind) {
    case PrimitiveKind::Box: {
        BoxParameters params;
        params.width = object.primitive.width;
        params.height = object.primitive.height;
        params.depth = object.primitive.depth;
        shape = kernel_.makeBox(params);
        break;
    }
    case PrimitiveKind::Cylinder: {
        CylinderParameters params;
        params.radius = object.primitive.radius;
        params.height = object.primitive.height;
        shape = kernel_.makeCylinder(params);
        break;
    }
    case PrimitiveKind::Sphere: {
        SphereParameters params;
        params.radius = object.primitive.radius;
        shape = kernel_.makeSphere(params);
        break;
    }
    case PrimitiveKind::Cone:
        return usageError("Cone evaluation is not implemented in CADNext 0.4");
    case PrimitiveKind::None:
        return usageError("Object \"" + object.name + "\" has no primitive descriptor");
    }

    if (!shape.isOk()) {
        if (shape.error().code == cadnext::ErrorCode::KernelUnavailable) {
            // Not an error at the document level: the build simply has no
            // BRep backend. The caller falls back to procedural display.
            return cadnext::Result<EvaluatedGeometry>::ok(
                helperResult(object, shape.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(shape.error());
    }

    EvaluatedGeometry geometry;
    geometry.objectId = object.id;
    geometry.shape = shape.value();

    if (!kernel_.isShapeValid(geometry.shape)) {
        geometry.isValid = false;
        geometry.message = "Kernel reports the evaluated shape as invalid";
        return cadnext::Result<EvaluatedGeometry>::ok(geometry);
    }

    const cadnext::Result<TriangleMesh> mesh =
        meshExtractor_->extract(kernel_, geometry.shape);
    if (!mesh.isOk()) {
        geometry.isValid = false;
        geometry.message = mesh.error().message;
        return cadnext::Result<EvaluatedGeometry>::ok(geometry);
    }

    geometry.previewMesh = mesh.value();
    geometry.isValid = !geometry.previewMesh.isEmpty();
    if (!geometry.isValid) {
        geometry.message = "Mesh extraction returned an empty mesh";
    }
    return cadnext::Result<EvaluatedGeometry>::ok(geometry);
}

} // namespace cadnext::kernel
