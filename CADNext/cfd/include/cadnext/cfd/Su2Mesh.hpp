#pragma once

#include <array>
#include <string>
#include <utility>
#include <vector>

// Meshes for SU2 in its native ASCII format (NDIME / NELEM / NPOIN / NMARK), which takes mixed
// element types — tetrahedra, prisms and pyramids in the boundary layer of a 3D airframe, quads in
// 2D — and named boundary markers the configuration refers to.

namespace cadnext::cfd {

// VTK cell type numbers, which is what the SU2 format uses.
enum class Su2ElementType : int {
    Line = 3,
    Triangle = 5,
    Quadrilateral = 9,
    Tetrahedron = 10,
    Hexahedron = 12,
    Prism = 13,
    Pyramid = 14,
};

struct Su2Element {
    Su2ElementType type = Su2ElementType::Triangle;
    std::vector<int> nodes;
};

struct Su2Mesh {
    int dimension = 2;
    std::vector<std::array<double, 3>> points;
    std::vector<Su2Element> elements;
    // Marker name → boundary elements (lines in 2D, triangles/quads in 3D).
    std::vector<std::pair<std::string, std::vector<Su2Element>>> markers;

    std::string text() const;
    bool write(const std::string& path) const;
};

} // namespace cadnext::cfd
