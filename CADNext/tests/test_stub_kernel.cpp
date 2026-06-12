#include "cadnext/kernel/BooleanOps.hpp"
#include "cadnext/kernel/StubKernel.hpp"

#include <cassert>

int main() {
    cadnext::kernel::StubKernel kernel;

    const auto box = kernel.makeBox({1.0, 2.0, 3.0});
    assert(box.isOk());
    assert(!box.value().isNull());

    const auto cylinder = kernel.makeCylinder({0.5, 1.5});
    assert(cylinder.isOk());
    assert(!cylinder.value().isNull());

    cadnext::kernel::BooleanOps booleans(kernel);
    const auto cut = booleans.apply(
        cadnext::kernel::BooleanOperation::Cut,
        box.value(),
        cylinder.value()
    );

    assert(cut.isOk());
    assert(!cut.value().isNull());
    assert(kernel.isShapeValid(cut.value()));

    return 0;
}
