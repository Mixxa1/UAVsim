#pragma once

#include <memory>

#include "cadnext/kernel/Kernel.hpp"

#ifdef CADNEXT_WITH_OCCT
class TopoDS_Shape;
#endif

namespace cadnext::kernel {

// OCCT-backed kernel. The BRep shapes live in an internal registry keyed
// by the ShapeHandle id; OCCT types never appear in the public core model,
// in Object, in the GUI, or in serialized .cadnext files.
//
// Boolean operations are intentionally not implemented in CADNext 0.4.
class OcctKernel final : public Kernel {
public:
    OcctKernel();
    ~OcctKernel() override;

    OcctKernel(const OcctKernel&) = delete;
    OcctKernel& operator=(const OcctKernel&) = delete;

    cadnext::Result<ShapeHandle> makeBox(const BoxParameters& params) override;
    cadnext::Result<ShapeHandle> makeCylinder(const CylinderParameters& params) override;
    cadnext::Result<ShapeHandle> makeSphere(const SphereParameters& params) override;
    cadnext::Result<ShapeHandle> booleanFuse(const ShapeHandle& a, const ShapeHandle& b) override;
    cadnext::Result<ShapeHandle> booleanCut(const ShapeHandle& target, const ShapeHandle& tool) override;
    cadnext::Result<ShapeHandle> booleanCommon(const ShapeHandle& a, const ShapeHandle& b) override;
    bool isShapeValid(const ShapeHandle& shape) const override;

    bool isAvailable() const;

#ifdef CADNEXT_WITH_OCCT
    // Internal accessor for the OCCT mesh extractor. Returns nullptr for
    // unknown handles. Never exposed beyond OCCT-enabled kernel code.
    const TopoDS_Shape* findShape(const ShapeHandle& handle) const;
#endif

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace cadnext::kernel
