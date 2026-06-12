#pragma once

#include <memory>

#include "cadnext/Result.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

namespace cadnext::kernel {

class MeshExtractor {
public:
    virtual ~MeshExtractor() = default;

    virtual cadnext::Result<TriangleMesh> extract(
        Kernel& kernel,
        const ShapeHandle& shape
    ) = 0;
};

// Returns the OCCT-backed extractor in CADNEXT_WITH_OCCT builds, otherwise
// a stub that fails with KernelUnavailable (the viewer then falls back to
// procedural Coin3D primitives).
std::unique_ptr<MeshExtractor> makeMeshExtractor();

} // namespace cadnext::kernel
