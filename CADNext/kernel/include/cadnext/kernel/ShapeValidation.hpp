#pragma once

#include <string>
#include <vector>

#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

namespace cadnext::kernel {

struct ShapeValidationIssue {
    std::string code;
    std::string message;
};

struct ShapeValidationResult {
    bool valid = true;
    std::vector<ShapeValidationIssue> issues;
};

class ShapeValidation {
public:
    explicit ShapeValidation(const Kernel& kernel);

    ShapeValidationResult validate(const ShapeHandle& shape) const;

private:
    const Kernel& kernel_;
};

} // namespace cadnext::kernel
