#pragma once

#include "cadnext/fea/FeaTypes.hpp"

#include <array>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace cadnext::fea {

enum class ElementOrder {
    // 4-node tetrahedron. Kept for comparison only: a constant-strain element locks in
    // bending and is unusable for thin UAV structure at practical mesh sizes — the
    // cantilever benchmark shows by how much.
    Linear = 1,
    // 10-node tetrahedron, the production element.
    Quadratic = 2,
};

// Corner nodes 0..3, then midside nodes on edges (0,1) (1,2) (0,2) (0,3) (1,3) (2,3).
inline constexpr std::array<std::array<int, 2>, 6> kTetEdges = {{
    {0, 1}, {1, 2}, {0, 2}, {0, 3}, {1, 3}, {2, 3},
}};

// Local face k is opposite corner k, listed counter-clockwise seen from outside, so the
// right-hand normal of (c0, c1, c2) points out of a positively oriented tetrahedron.
inline constexpr std::array<std::array<int, 3>, 4> kTetFaces = {{
    {1, 2, 3}, {0, 3, 2}, {0, 1, 3}, {0, 2, 1},
}};

struct BoundaryFace {
    int element = 0;
    int localFace = 0;
};

struct TetMesh {
    ElementOrder order = ElementOrder::Quadratic;
    std::vector<Vec3> nodes;
    // Always ten slots; a linear mesh fills the first four.
    std::vector<std::array<int, 10>> elements;
    std::map<std::string, std::vector<BoundaryFace>> faceGroups;

    int nodesPerElement() const { return order == ElementOrder::Quadratic ? 10 : 4; }

    // Corners (c0, c1, c2) followed, for quadratic meshes, by the midsides of
    // (c0,c1) (c1,c2) (c2,c0).
    std::vector<int> faceNodes(const BoundaryFace& face) const;

    // Unique, ascending.
    std::vector<int> nodesOnGroup(const std::string& group) const;
    std::vector<int> nodesWhere(const std::function<bool(const Vec3&)>& predicate) const;
    int nearestNode(const Vec3& point) const;

    double volume() const;
};

// Local index of the midside node on the edge between corners a and b.
int tetMidsideIndex(int a, int b);

} // namespace cadnext::fea
