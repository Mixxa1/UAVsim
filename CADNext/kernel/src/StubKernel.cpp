#include "cadnext/kernel/StubKernel.hpp"

#include <sstream>

namespace cadnext::kernel {

cadnext::Result<ShapeHandle> StubKernel::makeBox(const BoxParameters& params) {
    if (params.width <= 0.0 || params.height <= 0.0 || params.depth <= 0.0) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Box dimensions must be positive"
        });
    }
    return makeGeneratedHandle("stub-box");
}

cadnext::Result<ShapeHandle> StubKernel::makeCylinder(const CylinderParameters& params) {
    if (params.radius <= 0.0 || params.height <= 0.0) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Cylinder radius and height must be positive"
        });
    }
    return makeGeneratedHandle("stub-cylinder");
}

cadnext::Result<ShapeHandle> StubKernel::makeSphere(const SphereParameters& params) {
    if (params.radius <= 0.0) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Sphere radius must be positive"
        });
    }
    return makeGeneratedHandle("stub-sphere");
}

cadnext::Result<ShapeHandle> StubKernel::makeExtrudedPolygon(
    const ExtrudedPolygonParameters& params) {
    if (params.loop.size() < 3) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extruded polygon needs at least 3 loop points"
        });
    }
    return makeGeneratedHandle("stub-extrude-polygon");
}

cadnext::Result<ShapeHandle> StubKernel::makeExtrudedCircle(
    const ExtrudedCircleParameters& params) {
    if (params.radius <= 0.0) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extruded circle radius must be positive"
        });
    }
    return makeGeneratedHandle("stub-extrude-circle");
}

cadnext::Result<ShapeHandle> StubKernel::booleanFuse(const ShapeHandle& a, const ShapeHandle& b) {
    return makeBooleanHandle("fuse", a, b);
}

cadnext::Result<ShapeHandle> StubKernel::booleanCut(const ShapeHandle& target, const ShapeHandle& tool) {
    return makeBooleanHandle("cut", target, tool);
}

cadnext::Result<ShapeHandle> StubKernel::booleanCommon(const ShapeHandle& a, const ShapeHandle& b) {
    return makeBooleanHandle("common", a, b);
}

bool StubKernel::isShapeValid(const ShapeHandle& shape) const {
    return !shape.isNull();
}

cadnext::Result<ShapeHandle> StubKernel::makeGeneratedHandle(const std::string& prefix) {
    std::ostringstream stream;
    stream << prefix << "-" << nextId_++;
    return cadnext::Result<ShapeHandle>::ok(ShapeHandle(stream.str()));
}

cadnext::Result<ShapeHandle> StubKernel::makeBooleanHandle(
    const std::string& operation,
    const ShapeHandle& a,
    const ShapeHandle& b
) {
    if (a.isNull() || b.isNull()) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::ShapeInvalid,
            "Boolean " + operation + " requires non-null shape handles"
        });
    }
    return makeGeneratedHandle("stub-boolean-" + operation);
}

} // namespace cadnext::kernel
