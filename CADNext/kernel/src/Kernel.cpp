#include "cadnext/kernel/Kernel.hpp"

#include <utility>

namespace cadnext::kernel {

ShapeHandle::ShapeHandle() = default;

ShapeHandle::ShapeHandle(std::string id) : id_(std::move(id)) {}

const std::string& ShapeHandle::id() const {
    return id_;
}

bool ShapeHandle::isNull() const {
    return id_.empty();
}

} // namespace cadnext::kernel
