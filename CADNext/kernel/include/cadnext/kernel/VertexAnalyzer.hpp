#pragma once

#include <string>
#include <vector>

#include "cadnext/Vector3.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

namespace cadnext::kernel {

// Vertex extraction for OCCT-backed bodies (Assembly workbench: vertex
// mates and coincident-point references). Like FaceReference/EdgeReference,
// VertexReference is transient derived data re-extracted from the body's
// current BRep shape; it is never serialized.
struct VertexReference {
    std::string bodyId;
    std::string vertexId;

    cadnext::Vector3 position;
};

// Stable-ish vertex id v1: "vertex-<index>-<positionHash>" from the
// quantized position, mirroring makeFaceId/makeEdgeId. Full topological
// naming stays out of scope; assembly references keep a geometric
// signature fallback for re-resolution.
std::string makeVertexId(int index, const cadnext::Vector3& position);

class VertexAnalyzer {
public:
    explicit VertexAnalyzer(Kernel& kernel);

    // All unique vertices of the body's current shape (shared vertices of
    // adjacent edges are reported once). Returns an empty list without an
    // OCCT backend or for unknown handles.
    std::vector<VertexReference> verticesForBody(const std::string& bodyId,
                                                 const ShapeHandle& shape);

private:
    Kernel& kernel_;
};

} // namespace cadnext::kernel
