#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
#include <cstdint>
#include <string>

#ifdef CADNEXT_WITH_OCCT
#include <unordered_map>

#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <Standard_Failure.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>
#endif

namespace cadnext::kernel {

namespace {

cadnext::Result<ShapeHandle> unavailable(const char* what) {
    return cadnext::Result<ShapeHandle>::fail({
        cadnext::ErrorCode::KernelUnavailable,
        std::string(what) + " requires an OCCT-enabled build (CADNEXT_WITH_OCCT=ON)"
    });
}

cadnext::Result<ShapeHandle> notImplemented(const char* what) {
    return cadnext::Result<ShapeHandle>::fail({
        cadnext::ErrorCode::UnsupportedOperation,
        std::string(what) + " is intentionally not implemented in CADNext 0.4"
    });
}

bool isPositiveFinite(double value) {
    return std::isfinite(value) && value > 0.0;
}

} // namespace

#ifdef CADNEXT_WITH_OCCT

struct OcctKernel::Impl {
    std::unordered_map<std::string, TopoDS_Shape> shapes;
    std::uint64_t nextId = 1;

    ShapeHandle store(const TopoDS_Shape& shape, const char* prefix) {
        const std::string id = std::string(prefix) + "-" + std::to_string(nextId++);
        shapes.emplace(id, shape);
        return ShapeHandle(id);
    }
};

OcctKernel::OcctKernel() : impl_(std::make_unique<Impl>()) {}

OcctKernel::~OcctKernel() = default;

cadnext::Result<ShapeHandle> OcctKernel::makeBox(const BoxParameters& params) {
    if (!isPositiveFinite(params.width) || !isPositiveFinite(params.height) ||
        !isPositiveFinite(params.depth)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Box dimensions must be finite and positive"
        });
    }
    try {
        // Centered on the local origin; width=X, depth=Y, height=Z.
        const gp_Pnt corner(-params.width / 2.0, -params.depth / 2.0, -params.height / 2.0);
        BRepPrimAPI_MakeBox builder(corner, params.width, params.depth, params.height);
        builder.Build();
        if (!builder.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT box construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(builder.Shape(), "occt-box"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT box construction failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeCylinder(const CylinderParameters& params) {
    if (!isPositiveFinite(params.radius) || !isPositiveFinite(params.height)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Cylinder radius and height must be finite and positive"
        });
    }
    try {
        // Axis along local Z, centered: spans [-height/2, +height/2].
        const gp_Ax2 axis(gp_Pnt(0.0, 0.0, -params.height / 2.0), gp_Dir(0.0, 0.0, 1.0));
        BRepPrimAPI_MakeCylinder builder(axis, params.radius, params.height);
        builder.Build();
        if (!builder.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT cylinder construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(builder.Shape(), "occt-cylinder"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT cylinder construction failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeSphere(const SphereParameters& params) {
    if (!isPositiveFinite(params.radius)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Sphere radius must be finite and positive"
        });
    }
    try {
        // Centered on the local origin.
        BRepPrimAPI_MakeSphere builder(params.radius);
        builder.Build();
        if (!builder.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT sphere construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(builder.Shape(), "occt-sphere"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT sphere construction failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedPolygon(
    const ExtrudedPolygonParameters& params) {
    if (params.loop.size() < 3) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extruded polygon needs at least 3 loop points"
        });
    }
    const gp_Vec extrusion(params.extrusion.x, params.extrusion.y, params.extrusion.z);
    if (extrusion.Magnitude() <= 1.0e-12) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extrusion vector must be non-zero"
        });
    }
    try {
        // Closed planar loop → wire → face → prism along the world vector.
        BRepBuilderAPI_MakePolygon polygon;
        for (const cadnext::Vector3& point : params.loop) {
            polygon.Add(gp_Pnt(point.x, point.y, point.z));
        }
        polygon.Close();
        if (!polygon.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT polygon wire construction failed"});
        }
        BRepBuilderAPI_MakeFace face(polygon.Wire());
        if (!face.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT profile face construction failed (loop not planar/closed?)"});
        }
        BRepPrimAPI_MakePrism prism(face.Face(), extrusion);
        prism.Build();
        if (!prism.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT prism construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(impl_->store(prism.Shape(), "occt-extrude"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT polygon extrude failed: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCircle(
    const ExtrudedCircleParameters& params) {
    if (!isPositiveFinite(params.radius)) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extruded circle radius must be finite and positive"
        });
    }
    const gp_Vec extrusion(params.extrusion.x, params.extrusion.y, params.extrusion.z);
    if (extrusion.Magnitude() <= 1.0e-12) {
        return cadnext::Result<ShapeHandle>::fail({
            cadnext::ErrorCode::InvalidArgument,
            "Extrusion vector must be non-zero"
        });
    }
    try {
        // Exact circular wire (no polygon approximation in the BRep path).
        const gp_Ax2 axis(gp_Pnt(params.center.x, params.center.y, params.center.z),
                          gp_Dir(params.normal.x, params.normal.y, params.normal.z));
        const gp_Circ circle(axis, params.radius);
        BRepBuilderAPI_MakeEdge edge(circle);
        BRepBuilderAPI_MakeWire wire(edge.Edge());
        BRepBuilderAPI_MakeFace face(wire.Wire());
        if (!face.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed,
                 "OCCT circle face construction failed"});
        }
        BRepPrimAPI_MakePrism prism(face.Face(), extrusion);
        prism.Build();
        if (!prism.IsDone()) {
            return cadnext::Result<ShapeHandle>::fail(
                {cadnext::ErrorCode::KernelOperationFailed, "OCCT prism construction failed"});
        }
        return cadnext::Result<ShapeHandle>::ok(
            impl_->store(prism.Shape(), "occt-extrude-circle"));
    } catch (const Standard_Failure& failure) {
        return cadnext::Result<ShapeHandle>::fail(
            {cadnext::ErrorCode::KernelOperationFailed,
             std::string("OCCT circle extrude failed: ") + failure.GetMessageString()});
    }
}

bool OcctKernel::isShapeValid(const ShapeHandle& shape) const {
    const TopoDS_Shape* topoShape = findShape(shape);
    if (!topoShape || topoShape->IsNull()) {
        return false;
    }
    try {
        const BRepCheck_Analyzer analyzer(*topoShape);
        return analyzer.IsValid() == Standard_True;
    } catch (const Standard_Failure&) {
        return false;
    }
}

const TopoDS_Shape* OcctKernel::findShape(const ShapeHandle& handle) const {
    if (handle.isNull()) {
        return nullptr;
    }
    const auto it = impl_->shapes.find(handle.id());
    return it == impl_->shapes.end() ? nullptr : &it->second;
}

#else // !CADNEXT_WITH_OCCT

struct OcctKernel::Impl {};

OcctKernel::OcctKernel() : impl_(std::make_unique<Impl>()) {}

OcctKernel::~OcctKernel() = default;

cadnext::Result<ShapeHandle> OcctKernel::makeBox(const BoxParameters&) {
    return unavailable("OCCT box");
}

cadnext::Result<ShapeHandle> OcctKernel::makeCylinder(const CylinderParameters&) {
    return unavailable("OCCT cylinder");
}

cadnext::Result<ShapeHandle> OcctKernel::makeSphere(const SphereParameters&) {
    return unavailable("OCCT sphere");
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedPolygon(const ExtrudedPolygonParameters&) {
    return unavailable("OCCT polygon extrude");
}

cadnext::Result<ShapeHandle> OcctKernel::makeExtrudedCircle(const ExtrudedCircleParameters&) {
    return unavailable("OCCT circle extrude");
}

bool OcctKernel::isShapeValid(const ShapeHandle&) const {
    return false;
}

#endif // CADNEXT_WITH_OCCT

cadnext::Result<ShapeHandle> OcctKernel::booleanFuse(const ShapeHandle&, const ShapeHandle&) {
    return notImplemented("OCCT boolean fuse");
}

cadnext::Result<ShapeHandle> OcctKernel::booleanCut(const ShapeHandle&, const ShapeHandle&) {
    return notImplemented("OCCT boolean cut");
}

cadnext::Result<ShapeHandle> OcctKernel::booleanCommon(const ShapeHandle&, const ShapeHandle&) {
    return notImplemented("OCCT boolean common");
}

bool OcctKernel::isAvailable() const {
#ifdef CADNEXT_WITH_OCCT
    return true;
#else
    return false;
#endif
}

} // namespace cadnext::kernel
