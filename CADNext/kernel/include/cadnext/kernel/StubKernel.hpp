#pragma once

#include <cstdint>
#include <string>

#include "cadnext/kernel/Kernel.hpp"

namespace cadnext::kernel {

// StubKernel exists only for architecture tests and default builds.
// It is not a CAD geometry kernel and does not create real BRep topology.
class StubKernel final : public Kernel {
public:
    cadnext::Result<ShapeHandle> makeBox(const BoxParameters& params) override;
    cadnext::Result<ShapeHandle> makeCylinder(const CylinderParameters& params) override;
    cadnext::Result<ShapeHandle> makeSphere(const SphereParameters& params) override;
    cadnext::Result<ShapeHandle> makeExtrudedPolygon(
        const ExtrudedPolygonParameters& params) override;
    cadnext::Result<ShapeHandle> makeExtrudedCircle(
        const ExtrudedCircleParameters& params) override;
    cadnext::Result<ShapeHandle> booleanFuse(const ShapeHandle& a, const ShapeHandle& b) override;
    cadnext::Result<ShapeHandle> booleanCut(const ShapeHandle& target, const ShapeHandle& tool) override;
    cadnext::Result<ShapeHandle> booleanCommon(const ShapeHandle& a, const ShapeHandle& b) override;
    cadnext::Result<ShapeHandle> chamferEdges(const ShapeHandle& target,
                                              const std::vector<std::string>& edgeIds,
                                              double distance,
                                              cadnext::ChamferMode mode,
                                              double angleDeg) override;
    cadnext::Result<ShapeHandle> filletEdges(const ShapeHandle& target,
                                             const std::vector<std::string>& edgeIds,
                                             double radius) override;
    cadnext::Result<ShapeBounds> boundingBox(const ShapeHandle& shape) override;
    cadnext::Result<ShapeMassProperties> volumeProperties(const ShapeHandle& shape) override;
    cadnext::Result<std::vector<std::uint8_t>> exportBRep(const ShapeHandle& shape) override;
    cadnext::Result<ShapeHandle> importBRep(const std::vector<std::uint8_t>& brepData) override;
    bool isShapeValid(const ShapeHandle& shape) const override;

private:
    cadnext::Result<ShapeHandle> makeGeneratedHandle(const std::string& prefix);
    cadnext::Result<ShapeHandle> makeBooleanHandle(
        const std::string& operation,
        const ShapeHandle& a,
        const ShapeHandle& b
    );

    std::uint64_t nextId_ = 1;
};

} // namespace cadnext::kernel
