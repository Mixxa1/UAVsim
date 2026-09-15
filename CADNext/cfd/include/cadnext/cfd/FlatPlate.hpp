#pragma once

#include "cadnext/cfd/Su2Mesh.hpp"

// Zero-pressure-gradient flat plate for viscous verification: a rectangle, the plate from x = 0 to the
// outlet (no trailing edge, so no trailing-edge interaction), a slip region upstream of the leading
// edge, freestream above. Cells cluster geometrically toward the wall and toward the leading edge
// with the same mapping on every level, so a refinement study samples one family of meshes.
//
// Markers: "inlet" (x = −upstream), "outlet" (x = length), "symmetry" (y = 0 upstream), "wall"
// (y = 0 on the plate), "farfield" (y = height).

namespace cadnext::cfd {

struct FlatPlateMeshSpec {
    double length = 1.0;
    double upstream = 0.25;
    double height = 1.0;
    int plateCells = 48;
    int upstreamCells = 12;
    int normalCells = 48;
    // Ratio of the largest to the smallest cell along each clustered direction (exponential map).
    double wallStretch = 400.0;
    double leadingEdgeStretch = 40.0;  // along the plate, finest at x = 0
    double upstreamStretch = 40.0;     // upstream of the leading edge, finest at x = 0
};

Su2Mesh flatPlateMesh(const FlatPlateMeshSpec& spec);

} // namespace cadnext::cfd
