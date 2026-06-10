#pragma once

#include "cadnext/Result.hpp"
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

class Kernel {
public:
    virtual ~Kernel() = default;

    virtual cadnext::Result<ShapeHandle> makeBox(const BoxParameters& params) = 0;
    virtual cadnext::Result<ShapeHandle> makeCylinder(const CylinderParameters& params) = 0;
    virtual cadnext::Result<ShapeHandle> makeSphere(const SphereParameters& params) = 0;

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

    virtual bool isShapeValid(const ShapeHandle& shape) const = 0;
};

} // namespace cadnext::kernel
