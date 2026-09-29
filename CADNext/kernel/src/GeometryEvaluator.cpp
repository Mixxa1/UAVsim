#include "cadnext/kernel/GeometryEvaluator.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

#include "cadnext/Units.hpp"

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

std::pair<cadnext::SketchPoint2D, double> circleParameters(
    const cadnext::SketchProfile& profile) {
    if (profile.circleRadius > 0.0 && std::isfinite(profile.circleRadius))
        return {profile.circleCenter, profile.circleRadius};
    // Compatibility with callers constructing a circle profile directly
    // from an outline rather than through SketchProfileDetector.
    cadnext::SketchPoint2D center{};
    for (const auto& point : profile.outerLoop) {
        center.u += point.u;
        center.v += point.v;
    }
    center.u /= profile.outerLoop.size();
    center.v /= profile.outerLoop.size();
    return {center, std::hypot(profile.outerLoop.front().u - center.u,
                               profile.outerLoop.front().v - center.v)};
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
    if (!cadnext::extrudeParametersValid(parameters)) {
        return usageError("Extrude parameters are invalid (distance must be > 0)");
    }

    double startOffset = 0.0;
    double endOffset = 0.0;
    cadnext::extrudeSpan(parameters, startOffset, endOffset);
    const cadnext::Result<ShapeHandle> shape =
        buildProfilePrism(reference, profile, startOffset, endOffset);
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
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateRevolve(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    const cadnext::RevolveParameters& parameters) {
    if (!profile.isValid || !profile.isClosed || profile.outerLoop.size() < 3 ||
        !std::isfinite(parameters.axisOffset) ||
        !std::isfinite(parameters.angleDegrees) ||
        parameters.angleDegrees <= 0.0 || parameters.angleDegrees > 360.0) {
        return usageError("Revolve requires a closed profile and an angle in (0, 360]");
    }
    RevolvedProfileParameters request;
    request.angleDegrees = parameters.angleDegrees;
    const cadnext::SketchPoint2D origin = parameters.axis == cadnext::RevolveAxis::U
        ? cadnext::SketchPoint2D{0.0, parameters.axisOffset}
        : cadnext::SketchPoint2D{parameters.axisOffset, 0.0};
    request.axisOrigin = cadnext::sketchPointToWorld(origin, reference);
    request.axisDirection = parameters.axis == cadnext::RevolveAxis::U
        ? reference.uAxis : reference.vAxis;

    double minimum = std::numeric_limits<double>::infinity();
    double maximum = -std::numeric_limits<double>::infinity();
    for (const auto& point : profile.outerLoop) {
        const double distance = parameters.axis == cadnext::RevolveAxis::U
            ? point.v - parameters.axisOffset : point.u - parameters.axisOffset;
        minimum = std::min(minimum, distance);
        maximum = std::max(maximum, distance);
        request.loop.push_back(cadnext::sketchPointToWorld(point, reference));
    }
    if (minimum < -1.0e-8 && maximum > 1.0e-8) {
        return usageError("Revolve axis crosses the profile");
    }
    if (profile.kind == cadnext::SketchProfileKind::Circle) {
        const auto [center, radius] = circleParameters(profile);
        const double distance = std::fabs(parameters.axis == cadnext::RevolveAxis::U
            ? center.v - parameters.axisOffset : center.u - parameters.axisOffset);
        if (distance + 1.0e-8 < radius) {
            return usageError("Revolve axis crosses the circular profile");
        }
        request.isCircle = true;
        request.circleCenter = cadnext::sketchPointToWorld(center, reference);
        request.circleNormal = reference.normal;
        request.circleRadius = radius;
    } else if (profile.kind == cadnext::SketchProfileKind::Curved) {
        for (const auto& segment : profile.segments) {
            request.edges.push_back({
                cadnext::sketchPointToWorld(segment.start, reference),
                cadnext::sketchPointToWorld(segment.middle, reference),
                cadnext::sketchPointToWorld(segment.end, reference),
                segment.isArc});
        }
    }
    const auto shape = kernel_.makeRevolvedProfile(request);
    if (!shape.isOk()) {
        return cadnext::Result<EvaluatedGeometry>::fail(shape.error());
    }
    EvaluatedGeometry geometry;
    geometry.shape = shape.value();
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<ShapeHandle> GeometryEvaluator::buildProfilePrism(
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    double startOffset, double endOffset) {
    if (!profile.isValid || !profile.isClosed || profile.outerLoop.size() < 3) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument,
             "Profile \"" + profile.id + "\" is not a valid closed loop"});
    }
    const double span = endOffset - startOffset;
    if (!std::isfinite(span) || span <= 0.0) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::InvalidArgument, "Prism span must be positive"});
    }

    // The base face sits at the span start so the prism covers exactly
    // [startOffset, endOffset] along the plane normal.
    const cadnext::Vector3 normal =
        cadnext::extrudeDirectionVector(reference, cadnext::ExtrudeDirection::Positive);
    const cadnext::Vector3 extrusion{normal.x * span, normal.y * span, normal.z * span};

    if (profile.kind == cadnext::SketchProfileKind::Circle) {
        const auto [center, radius] = circleParameters(profile);

        ExtrudedCircleParameters params;
        const cadnext::Vector3 worldCenter = cadnext::sketchPointToWorld(center, reference);
        params.center = {worldCenter.x + normal.x * startOffset,
                         worldCenter.y + normal.y * startOffset,
                         worldCenter.z + normal.z * startOffset};
        params.normal = normal;
        params.radius = radius;
        params.extrusion = extrusion;
        return kernel_.makeExtrudedCircle(params);
    }

    if (profile.kind == cadnext::SketchProfileKind::Curved) {
        ExtrudedCurvedProfileParameters params;
        params.extrusion = extrusion;
        const auto atBase = [&](const cadnext::SketchPoint2D& point) {
            const cadnext::Vector3 world = cadnext::sketchPointToWorld(point, reference);
            return cadnext::Vector3{world.x + normal.x * startOffset,
                                    world.y + normal.y * startOffset,
                                    world.z + normal.z * startOffset};
        };
        for (const auto& segment : profile.segments)
            params.edges.push_back({atBase(segment.start), atBase(segment.middle),
                                    atBase(segment.end), segment.isArc});
        return kernel_.makeExtrudedCurvedProfile(params);
    }

    ExtrudedPolygonParameters params;
    params.loop.reserve(profile.outerLoop.size());
    for (const cadnext::SketchPoint2D& point : profile.outerLoop) {
        const cadnext::Vector3 world = cadnext::sketchPointToWorld(point, reference);
        params.loop.push_back({world.x + normal.x * startOffset,
                               world.y + normal.y * startOffset,
                               world.z + normal.z * startOffset});
    }
    params.extrusion = extrusion;
    return kernel_.makeExtrudedPolygon(params);
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateExtrudeCut(
    const ShapeHandle& targetShape,
    const cadnext::SketchReference& reference,
    const cadnext::SketchProfile& profile,
    const cadnext::CutSpan& span) {
    if (targetShape.isNull()) {
        return usageError("Cut target shape handle is null");
    }

    const cadnext::Result<ShapeHandle> cutter =
        buildProfilePrism(reference, profile, span.start, span.end);
    if (!cutter.isOk()) {
        if (cutter.error().code == cadnext::ErrorCode::KernelUnavailable) {
            return cadnext::Result<EvaluatedGeometry>::ok(
                backendlessResult(cutter.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(cutter.error());
    }

    const cadnext::Result<ShapeHandle> result =
        kernel_.booleanCut(targetShape, cutter.value());
    if (!result.isOk()) {
        if (result.error().code == cadnext::ErrorCode::KernelUnavailable) {
            return cadnext::Result<EvaluatedGeometry>::ok(
                backendlessResult(result.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(result.error());
    }

    EvaluatedGeometry geometry;
    geometry.shape = result.value();
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateChamfer(
    const ShapeHandle& targetShape,
    const cadnext::ChamferParameters& parameters) {
    if (targetShape.isNull()) {
        return usageError("Chamfer target shape handle is null");
    }
    if (!cadnext::chamferParametersValid(parameters)) {
        return usageError("Chamfer parameters are invalid");
    }
    // Parameters carry user units (mm / degrees); the kernel works in
    // model units. This is the single conversion point.
    const cadnext::Result<ShapeHandle> result =
        kernel_.chamferEdges(targetShape, parameters.edgeIds,
                             cadnext::fromMillimeters(parameters.distanceMm),
                             parameters.mode, parameters.angleDeg);
    if (!result.isOk()) {
        if (result.error().code == cadnext::ErrorCode::KernelUnavailable) {
            return cadnext::Result<EvaluatedGeometry>::ok(
                backendlessResult(result.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(result.error());
    }
    EvaluatedGeometry geometry;
    geometry.shape = result.value();
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateFillet(
    const ShapeHandle& targetShape,
    const cadnext::FilletParameters& parameters) {
    if (targetShape.isNull()) {
        return usageError("Fillet target shape handle is null");
    }
    if (!cadnext::filletParametersValid(parameters)) {
        return usageError("Fillet parameters are invalid");
    }
    const cadnext::Result<ShapeHandle> result =
        kernel_.filletEdges(targetShape, parameters.edgeIds,
                            cadnext::fromMillimeters(parameters.radiusMm));
    if (!result.isOk()) {
        if (result.error().code == cadnext::ErrorCode::KernelUnavailable) {
            return cadnext::Result<EvaluatedGeometry>::ok(
                backendlessResult(result.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(result.error());
    }
    EvaluatedGeometry geometry;
    geometry.shape = result.value();
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<ThreadCutParameters> threadCutFor(const cadnext::ThreadParameters& parameters) {
    using R = cadnext::Result<ThreadCutParameters>;
    if (!cadnext::threadParametersValid(parameters)) {
        return R::fail({cadnext::ErrorCode::InvalidArgument, "параметры резьбы неверны"});
    }
    const cadnext::ThreadSurface& surface = parameters.surface;
    const cadnext::Vector3& d = surface.axisDirection;
    const double norm = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    const cadnext::Vector3 axis{d.x / norm, d.y / norm, d.z / norm};
    const double taper = cadnext::threadTaper(parameters.standard);
    ThreadCutParameters cut;
    cut.axisOrigin = surface.axisOrigin;
    cut.pitch = cadnext::fromMillimeters(parameters.pitchMm);
    switch (cadnext::threadForm(parameters.standard)) {
    case cadnext::ThreadForm::Metric60: cut.profile = ThreadProfileKind::Metric60; break;
    case cadnext::ThreadForm::Whitworth55: cut.profile = ThreadProfileKind::Whitworth55; break;
    case cadnext::ThreadForm::Npt60: cut.profile = ThreadProfileKind::Npt60; break;
    }
    cut.internal = surface.holeWall;
    cut.rightHanded = parameters.rightHanded;
    cut.taper = taper;
    cut.runOutWhereFree = true;
    double length = cadnext::fromMillimeters(parameters.lengthMm);
    if (taper > 0.0) {
        // On a cone of the thread's own taper, to 1e-6 on the diameter per unit of length: over a 20 mm
        // thread 0.01 µm off its cone, well inside the 1 µm a rounded crest is kept under the face.
        if (std::fabs(2.0 * std::fabs(surface.slope) - taper) > 1e-6) {
            return R::fail({cadnext::ErrorCode::InvalidArgument,
                            "коническая резьба режется на конусе своей конусности 1:16, а эта грань — не такой конус"});
        }
        // From the small end toward the large: positions along that way, the radius growing |slope|.
        const double sign = surface.slope > 0.0 ? 1.0 : -1.0;
        cut.axisDirection = {axis.x * sign, axis.y * sign, axis.z * sign};
        const double small = std::min(sign * surface.axialStart, sign * surface.axialEnd);
        const double large = std::max(sign * surface.axialStart, sign * surface.axialEnd);
        length = std::min(length, large - small);
        const double gaugeMajor = cadnext::fromMillimeters(parameters.majorDiameterMm);
        if (!cut.internal) {
            // External: from the pipe's end, the gauge plane the gauge length on.
            cut.start = small;
            cut.majorDiameter = gaugeMajor - cadnext::fromMillimeters(parameters.gaugeLengthMm) * taper;
        } else {
            // Internal: the gauge plane at the hole's mouth, the thread running in from there.
            cut.start = large - length;
            cut.majorDiameter = gaugeMajor - length * taper;
        }
        cut.surfaceDiameter = 2.0 * (surface.radius + std::fabs(surface.slope) * cut.start);
    } else {
        if (std::fabs(surface.slope) > 1e-9) {
            return R::fail({cadnext::ErrorCode::InvalidArgument, "цилиндрическая резьба режется на цилиндрической грани"});
        }
        length = std::min(length, surface.length());
        if (!parameters.fromFarEnd) {
            cut.axisDirection = axis;
            cut.start = surface.axialStart;
        } else {
            cut.axisDirection = {-axis.x, -axis.y, -axis.z};
            cut.start = -surface.axialEnd;
        }
        cut.majorDiameter = cadnext::fromMillimeters(parameters.majorDiameterMm);
        cut.surfaceDiameter = 2.0 * surface.radius;
    }
    cut.length = length;
    return R::ok(cut);
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateThread(
    const ShapeHandle& targetShape,
    const cadnext::ThreadParameters& parameters,
    ThreadCutReport* report) {
    if (targetShape.isNull()) {
        return usageError("Thread target shape handle is null");
    }
    const cadnext::Result<ThreadCutParameters> cut = threadCutFor(parameters);
    if (!cut.isOk()) {
        return cadnext::Result<EvaluatedGeometry>::fail(cut.error());
    }
    const cadnext::Result<ShapeHandle> result = kernel_.cutThread(targetShape, cut.value(), report);
    if (!result.isOk()) {
        if (result.error().code == cadnext::ErrorCode::KernelUnavailable) {
            return cadnext::Result<EvaluatedGeometry>::ok(
                backendlessResult(result.error().message));
        }
        return cadnext::Result<EvaluatedGeometry>::fail(result.error());
    }
    EvaluatedGeometry geometry;
    geometry.shape = result.value();
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::evaluateShape(const ShapeHandle& shape) {
    EvaluatedGeometry geometry;
    geometry.shape = shape;
    return finishShapeEvaluation(std::move(geometry));
}

cadnext::Result<EvaluatedGeometry> GeometryEvaluator::finishShapeEvaluation(
    EvaluatedGeometry geometry) {
    if (!kernel_.isShapeValid(geometry.shape)) {
        geometry.isValid = false;
        geometry.message = "Kernel reports the evaluated shape as invalid";
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
