#pragma once

#include <memory>

#include "cadnext/kernel/Kernel.hpp"

namespace cadnext::kernel {

enum class KernelBackend {
    Stub,
    Occt
};

std::unique_ptr<Kernel> makeKernel(KernelBackend backend = KernelBackend::Stub);

} // namespace cadnext::kernel
