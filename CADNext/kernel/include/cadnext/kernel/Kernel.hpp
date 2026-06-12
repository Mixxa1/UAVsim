#pragma once

#include <vector>

#include "cadnext/Result.hpp"
#include "cadnext/Vector3.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

namespace cadnext::kernel {

// Primitive bodies are built centered on the local origin; world placement
// always comes from Object.transform. Axis semantics match the core
// PrimitiveParameters: width = X, depth = Y, height = Z (Z-up).
struct BoxParameters {
    double width = 1.0;
    double height = 1.0;
    double depth = 1.0;
};

// Cylinder axis is local Z, centered: the body spans [-height/2, +height/2].
struct CylinderParameters {
    double radius = 0.5;
    double height = 1.0;
};

// Sphere is centered on the local origin.
struct SphereParameters {
    double radius = 0.5;
};

enum class BooleanOperation {
    Fuse,
    Cut,
    Common
};

// Axis-aligned bounding box of a BRep shape in world coordinates
// (Cut Extrude uses it for Through All / To Object cutter sizing).
struct ShapeBounds {
    cadnext::Vector3 min;
    cadnext::Vector3 max;
};

// Extruded sketch profiles (CADNext 0.6). The loop is the closed planar
// outer boundary in world coordinates (last point != first point);
// `extrusion` is the world vector from the base face to the top face.
struct ExtrudedPolygonParameters {
    std::vector<cadnext::Vector3> loop;
    cadnext::Vector3 extrusion;
};

// Exact circle profile (no polygonal approximation in the BRep path).
struct ExtrudedCircleParameters {
    cadnext::Vector3 center;
    cadnext::Vector3 normal; // unit sketch plane normal
    double radius = 0.5;
    cadnext::Vector3 extrusion;
};

class Kernel {
public:
    virtual ~Kernel() = default;

    virtual cadnext::Result<ShapeHandle> makeBox(const BoxParameters& params) = 0;
    virtual cadnext::Result<ShapeHandle> makeCylinder(const CylinderParameters& params) = 0;
    virtual cadnext::Result<ShapeHandle> makeSphere(const SphereParameters& params) = 0;

    // Sketch profile → wire → face → prism (CADNext 0.6 Extrude).
    virtual cadnext::Result<ShapeHandle> makeExtrudedPolygon(
        const ExtrudedPolygonParameters& params) = 0;
    virtual cadnext::Result<ShapeHandle> makeExtrudedCircle(
        const ExtrudedCircleParameters& params) = 0;

    virtual cadnext::Result<ShapeHandle> booleanFuse(
        const ShapeHandle& a,
        const ShapeHandle& b
    ) = 0;

    virtual cadnext::Result<ShapeHandle> booleanCut(
        const ShapeHandle& target,
        const ShapeHandle& tool
    ) = 0;

    virtual cadnext::Result<ShapeHandle> booleanCommon(
        const ShapeHandle& a,
        const ShapeHandle& b
    ) = 0;

    virtual cadnext::Result<ShapeBounds> boundingBox(const ShapeHandle& shape) = 0;

    virtual bool isShapeValid(const ShapeHandle& shape) const = 0;
};

} // namespace cadnext::kernel
