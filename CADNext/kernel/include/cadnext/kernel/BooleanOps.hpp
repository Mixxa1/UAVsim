#pragma once

#include <string>

#include "cadnext/Result.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

namespace cadnext::kernel {

class BooleanOps {
public:
    explicit BooleanOps(Kernel& kernel);

    cadnext::Result<ShapeHandle> apply(
        BooleanOperation operation,
        const ShapeHandle& lhs,
        const ShapeHandle& rhs
    );

private:
    Kernel& kernel_;
};

} // namespace cadnext::kernel
