#pragma once

#include <cstdint>
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
};

struct TriangleMesh {
    std::vector<MeshVertex> vertices;
    std::vector<MeshTriangle> triangles;

    bool isEmpty() const {
        return vertices.empty() || triangles.empty();
    }
};

} // namespace cadnext::kernel
