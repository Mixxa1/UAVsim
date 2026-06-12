#include "cadnext/kernel/KernelFactory.hpp"

#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StubKernel.hpp"

namespace cadnext::kernel {

std::unique_ptr<Kernel> makeKernel(KernelBackend backend) {
    switch (backend) {
    case KernelBackend::Occt: {
        auto kernel = std::make_unique<OcctKernel>();
        if (kernel->isAvailable()) {
            return kernel;
        }
        return std::make_unique<StubKernel>();
    }
    case KernelBackend::Stub:
        return std::make_unique<StubKernel>();
    }
    return std::make_unique<StubKernel>();
}

} // namespace cadnext::kernel
