#pragma once

#include <string>

namespace cadnext::kernel {

class ShapeHandle {
public:
    ShapeHandle();
    explicit ShapeHandle(std::string id);

    const std::string& id() const;
    bool isNull() const;

private:
    std::string id_;
};

} // namespace cadnext::kernel
