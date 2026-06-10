#include "cadnext/kernel/OcctKernel.hpp"

#include <cassert>
#include <limits>

int main() {
    cadnext::kernel::OcctKernel kernel;
    assert(kernel.isAvailable());

    // Valid primitives.
    const auto box = kernel.makeBox({2.0, 1.0, 1.5});
    assert(box.isOk());
    assert(!box.value().isNull());
    assert(kernel.isShapeValid(box.value()));

    const auto cylinder = kernel.makeCylinder({0.5, 1.2});
    assert(cylinder.isOk());
    assert(!cylinder.value().isNull());
    assert(kernel.isShapeValid(cylinder.value()));

    const auto sphere = kernel.makeSphere({0.6});
    assert(sphere.isOk());
    assert(!sphere.value().isNull());
    assert(kernel.isShapeValid(sphere.value()));

    // Each created shape gets its own handle.
    assert(box.value().id() != cylinder.value().id());
    assert(cylinder.value().id() != sphere.value().id());

    // Invalid dimensions are rejected with InvalidArgument.
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();

    for (const auto& bad : {
             kernel.makeBox({0.0, 1.0, 1.0}),
             kernel.makeBox({1.0, -2.0, 1.0}),
             kernel.makeBox({1.0, 1.0, nan}),
             kernel.makeBox({inf, 1.0, 1.0}),
         }) {
        assert(!bad.isOk());
        assert(bad.error().code == cadnext::ErrorCode::InvalidArgument);
    }

    for (const auto& bad : {
             kernel.makeCylinder({0.0, 1.0}),
             kernel.makeCylinder({0.5, -1.0}),
             kernel.makeCylinder({nan, 1.0}),
         }) {
        assert(!bad.isOk());
        assert(bad.error().code == cadnext::ErrorCode::InvalidArgument);
    }

    for (const auto& bad : {
             kernel.makeSphere({0.0}),
             kernel.makeSphere({-0.5}),
             kernel.makeSphere({inf}),
         }) {
        assert(!bad.isOk());
        assert(bad.error().code == cadnext::ErrorCode::InvalidArgument);
    }

    // Unknown and null handles are not valid.
    assert(!kernel.isShapeValid(cadnext::kernel::ShapeHandle("no-such-shape")));
    assert(!kernel.isShapeValid(cadnext::kernel::ShapeHandle()));
    assert(kernel.findShape(cadnext::kernel::ShapeHandle("no-such-shape")) == nullptr);

    // Booleans are intentionally not implemented in CADNext 0.4.
    const auto fuse = kernel.booleanFuse(box.value(), sphere.value());
    assert(!fuse.isOk());
    assert(fuse.error().code == cadnext::ErrorCode::UnsupportedOperation);

    return 0;
}
