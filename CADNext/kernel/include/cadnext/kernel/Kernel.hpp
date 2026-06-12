#pragma once

#include <string>
#include <vector>

#include "cadnext/Chamfer.hpp"
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

// Exact volume properties of a solid BRep shape. Volume is in model
// units cubed (1 unit = 1 m, so m³); the center of mass is in the
// shape's own modeling frame. The UAVPart exporter multiplies the
// volume by the material density — never a preview-mesh estimate.
struct ShapeMassProperties {
    double volumeM3 = 0.0;
    cadnext::Vector3 centerOfMass;
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

    // `distance` is in model units; `angleDeg` is only used in
    // ChamferMode::DistanceAngle (measured from the reference face).
    virtual cadnext::Result<ShapeHandle> chamferEdges(
        const ShapeHandle& target,
        const std::vector<std::string>& edgeIds,
        double distance,
        cadnext::ChamferMode mode,
        double angleDeg
    ) = 0;

    virtual cadnext::Result<ShapeHandle> filletEdges(
        const ShapeHandle& target,
        const std::vector<std::string>& edgeIds,
        double radius
    ) = 0;

    virtual cadnext::Result<ShapeBounds> boundingBox(const ShapeHandle& shape) = 0;

    // Exact volume + center of mass via the BRep kernel (BRepGProp in
    // OCCT builds). Fails with KernelUnavailable when no exact geometry
    // backend exists — callers must not substitute a mesh estimate.
    virtual cadnext::Result<ShapeMassProperties> volumeProperties(const ShapeHandle& shape) = 0;

    virtual bool isShapeValid(const ShapeHandle& shape) const = 0;
};

} // namespace cadnext::kernel
