#pragma once

#include "cadnext/fea/TetMesh.hpp"

#include <array>
#include <functional>
#include <string>

// Structured tetrahedral meshes of mapped hexahedral blocks.
//
// Not the production mesher — CAD solids will be meshed by Netgen. These exist so the
// solver can be verified on geometry whose exact answer is known *without* depending on a
// mesher: a cantilever, a thick cylinder, a plate with a hole, the NAFEMS membranes. Every
// node, midside ones included, is placed through the mapping, so a curved boundary is
// represented by quadratic elements that actually follow it.

namespace cadnext::fea {

// Maps the unit cube (u, v, w) ∈ [0,1]³ onto the block.
using BlockMapping = std::function<Vec3(double u, double v, double w)>;
// Monotone [0,1] → [0,1] redistribution of one parametric direction (mesh grading).
using Distribution = std::function<double(double)>;

struct MappedBlockSpec {
    int cellsU = 1;
    int cellsV = 1;
    int cellsW = 1;
    BlockMapping mapping;
    ElementOrder order = ElementOrder::Quadratic;
    Distribution distributeU;
    Distribution distributeV;
    Distribution distributeW;
    // Face groups for u=0, u=1, v=0, v=1, w=0, w=1. Empty names are not recorded.
    std::array<std::string, 6> faceNames;
};

// Each hex is split into six tetrahedra around its main diagonal (Kuhn subdivision), which
// is conforming between neighbours. Midside nodes sit at the parametric midpoint of their
// edge *after* grading, so graded meshes keep straight-edge midpoints centred.
TetMesh generateMappedBlock(const MappedBlockSpec& spec);

// Joins meshes of the same order, fusing nodes closer than `tolerance`. Face groups with
// the same name are concatenated. Used to build multi-block domains with a conforming
// interface (the interface node distributions must match).
TetMesh mergeMeshes(const std::vector<TetMesh>& meshes, double tolerance);

// Geometric grading towards u = 0: cell sizes grow by `ratio` from one cell to the next.
Distribution geometricGrading(int cells, double ratio);

} // namespace cadnext::fea
