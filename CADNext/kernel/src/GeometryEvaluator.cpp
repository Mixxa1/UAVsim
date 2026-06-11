#include "cadnext/kernel/GeometryEvaluator.hpp"

#include <cmath>

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

EvaluatedGeometry backendlessResult(std::string message) {
    EvaluatedGeometry geometry;
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

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateExtrude(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    const cadnext::ExtrudeParameters& parameters) {
    if (!profile.isValid || !profile.isClosed || profile.outerLoop.size() < 3) {
        return usageError("Profile \"" + profile.id + "\" is not a valid closed loop");
    }
    if (!cadnext::extrudeParametersValid(parameters)) {
        return usageError("Extrude parameters are invalid (distance must be > 0)");
    }

    // The base face sits at the span start so Negative/Symmetric extrusions
    // end up on the correct side(s) of the sketch plane; the prism vector
    // then covers the whole span.
    double startOffset = 0.0;
    double endOffset = 0.0;
    cadnext::extrudeSpan(parameters, startOffset, endOffset);
    const cadnext::Vector3 normal =
        cadnext::extrudeDirectionVector(reference, cadnext::ExtrudeDirection::Positive);
    const double span = endOffset - startOffset;
    const cadnext::Vector3 extrusion{normal.x * span, normal.y * span, normal.z * span};

    cadnext::Result<ShapeHandle> shape =
        cadnext::Result<ShapeHandle>::fail({cadnext::ErrorCode::InvalidArgument, ""});
    if (profile.kind == cadnext::SketchProfileKind::Circle) {
        // Recover the exact circle from the polygonal approximation: the
        // loop is generated from the entity center/radius, so centroid +
        // first-point distance reproduce them.
        cadnext::SketchPoint2D center{0.0, 0.0};
        for (const cadnext::SketchPoint2D& point : profile.outerLoop) {
            center.u += point.u;
            center.v += point.v;
        }
        center.u /= static_cast<double>(profile.outerLoop.size());
        center.v /= static_cast<double>(profile.outerLoop.size());
        const double radius = std::hypot(profile.outerLoop.front().u - center.u,
                                         profile.outerLoop.front().v - center.v);

        ExtrudedCircleParameters params;
        const cadnext::Vector3 worldCenter = cadnext::sketchPointToWorld(center, reference);
        params.center = {worldCenter.x + normal.x * startOffset,
                         worldCenter.y + normal.y * startOffset,
                         worldCenter.z + normal.z * startOffset};
        params.normal = normal;
        params.radius = radius;
        params.extrusion = extrusion;
        shape = kernel_.makeExtrudedCircle(params);
    } else {
        ExtrudedPolygonParameters params;
        params.loop.reserve(profile.outerLoop.size());
        for (const cadnext::SketchPoint2D& point : profile.outerLoop) {
            const cadnext::Vector3 world = cadnext::sketchPointToWorld(point, reference);
            params.loop.push_back({world.x + normal.x * startOffset,
                                   world.y + normal.y * startOffset,
                                   world.z + normal.z * startOffset});
        }
        params.extrusion = extrusion;
        shape = kernel_.makeExtrudedPolygon(params);
    }

    if (!shape.isOk()) {
        if (shape.error().code == cadnext::ErrorCode::KernelUnavailable) {
            // No BRep backend in this build — the caller falls back to the
            // procedural prism mesh.
            return cadnext::Result<EvaluatedGeometry>::ok(
                backendlessResult(shape.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(shape.error());
    }

    EvaluatedGeometry geometry;
    geometry.shape = shape.value();
    if (!kernel_.isShapeValid(geometry.shape)) {
        geometry.isValid = false;
        geometry.message = "Kernel reports the extruded shape as invalid";
        return cadnext::Result<EvaluatedGeometry>::ok(geometry);
    }

    const cadnext::Result<TriangleMesh> mesh = meshExtractor_->extract(kernel_, geometry.shape);
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
