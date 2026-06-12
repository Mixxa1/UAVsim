#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace cadnext::kernel {

// Preview triangulation derived from an evaluated BRep shape. The mesh is
// display data only — it is never the geometric source of truth and is
// never serialized into .cadnext files.

struct MeshVertex {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

struct MeshTriangle {
    std::uint32_t a = 0;
    std::uint32_t b = 0;
    std::uint32_t c = 0;

    // Optional topological/display ownership. When present, viewport
    // picking can resolve a clicked rendered triangle back to the body
    // face it came from. Empty means "body-only fallback".
    std::string faceId;
};

struct TriangleMesh {
    std::vector<MeshVertex> vertices;
    std::vector<MeshTriangle> triangles;

    bool isEmpty() const {
        return vertices.empty() || triangles.empty();
    }
};

} // namespace cadnext::kernel
