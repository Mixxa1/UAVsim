#include "cadnext/kernel/ShapeValidation.hpp"

namespace cadnext::kernel {

ShapeValidation::ShapeValidation(const Kernel& kernel) : kernel_(kernel) {}

ShapeValidationResult ShapeValidation::validate(const ShapeHandle& shape) const {
    ShapeValidationResult result;
    if (!kernel_.isShapeValid(shape)) {
        result.valid = false;
        result.issues.push_back({"invalid_shape", "Shape handle is null or rejected by kernel"});
    }
    return result;
}

} // namespace cadnext::kernel
