#include "cadnext/fea/TetMesh.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace cadnext::fea {

int tetMidsideIndex(int a, int b) {
    for (int e = 0; e < 6; ++e) {
        const auto& edge = kTetEdges[e];
        if ((edge[0] == a && edge[1] == b) || (edge[0] == b && edge[1] == a)) {
            return 4 + e;
        }
    }
    throw std::invalid_argument("not a tetrahedron edge");
}

std::vector<int> TetMesh::faceNodes(const BoundaryFace& face) const {
    const auto& element = elements.at(face.element);
    const auto& corners = kTetFaces.at(face.localFace);
    std::vector<int> result = {element[corners[0]], element[corners[1]], element[corners[2]]};
    if (order == ElementOrder::Quadratic) {
        result.push_back(element[tetMidsideIndex(corners[0], corners[1])]);
        result.push_back(element[tetMidsideIndex(corners[1], corners[2])]);
        result.push_back(element[tetMidsideIndex(corners[2], corners[0])]);
    }
    return result;
}

std::vector<int> TetMesh::nodesOnGroup(const std::string& group) const {
    std::vector<int> result;
    const auto found = faceGroups.find(group);
    if (found == faceGroups.end()) {
        return result;
    }
    for (const auto& face : found->second) {
        const auto nodesOfFace = faceNodes(face);
        result.insert(result.end(), nodesOfFace.begin(), nodesOfFace.end());
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

std::vector<int> TetMesh::nodesWhere(const std::function<bool(const Vec3&)>& predicate) const {
    std::vector<int> result;
    for (int i = 0; i < static_cast<int>(nodes.size()); ++i) {
        if (predicate(nodes[i])) {
            result.push_back(i);
        }
    }
    return result;
}

int TetMesh::nearestNode(const Vec3& point) const {
    int best = -1;
    double bestDistance = std::numeric_limits<double>::infinity();
    for (int i = 0; i < static_cast<int>(nodes.size()); ++i) {
        const double d = length(nodes[i] - point);
        if (d < bestDistance) {
            bestDistance = d;
            best = i;
        }
    }
    return best;
}

double TetMesh::volume() const {
    // Straight-sided volume from the corners; exact for linear meshes and for quadratic
    // meshes whose midsides are centred.
    double total = 0.0;
    for (const auto& element : elements) {
        const Vec3 a = nodes[element[1]] - nodes[element[0]];
        const Vec3 b = nodes[element[2]] - nodes[element[0]];
        const Vec3 c = nodes[element[3]] - nodes[element[0]];
        total += dot(a, cross(b, c)) / 6.0;
    }
    return total;
}

} // namespace cadnext::fea
