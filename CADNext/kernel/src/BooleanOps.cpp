#include "cadnext/kernel/BooleanOps.hpp"

namespace cadnext::kernel {

BooleanOps::BooleanOps(Kernel& kernel) : kernel_(kernel) {}

cadnext::Result<ShapeHandle> BooleanOps::apply(
    BooleanOperation operation,
    const ShapeHandle& lhs,
    const ShapeHandle& rhs
) {
    switch (operation) {
    case BooleanOperation::Fuse:
        return kernel_.booleanFuse(lhs, rhs);
    case BooleanOperation::Cut:
        return kernel_.booleanCut(lhs, rhs);
    case BooleanOperation::Common:
        return kernel_.booleanCommon(lhs, rhs);
    }
    return cadnext::Result<ShapeHandle>::fail({
        cadnext::ErrorCode::UnsupportedOperation,
        "Unknown boolean operation"
    });
}

} // namespace cadnext::kernel
