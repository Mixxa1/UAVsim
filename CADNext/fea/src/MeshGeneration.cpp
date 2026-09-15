#include "cadnext/fea/MeshGeneration.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <unordered_map>

namespace cadnext::fea {

namespace {

// Kuhn subdivision: one tetrahedron per ordering of the three axes, each a monotone path
// from the (0,0,0) corner of the hex to its (1,1,1) corner.
constexpr std::array<std::array<int, 3>, 6> kAxisPermutations = {{
    {0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0},
}};

struct GridIndex {
    int i = 0;
    int j = 0;
    int k = 0;
};

} // namespace

Distribution geometricGrading(int cells, double ratio) {
    if (cells <= 0 || ratio <= 0.0) {
        throw std::invalid_argument("geometricGrading: cells and ratio must be positive");
    }
    if (std::fabs(ratio - 1.0) < 1e-12) {
        return [](double s) { return s; };
    }
    const double total = std::pow(ratio, cells) - 1.0;
    return [cells, ratio, total](double s) {
        return (std::pow(ratio, cells * s) - 1.0) / total;
    };
}

TetMesh generateMappedBlock(const MappedBlockSpec& spec) {
    if (spec.cellsU < 1 || spec.cellsV < 1 || spec.cellsW < 1 || !spec.mapping) {
        throw std::invalid_argument("generateMappedBlock: invalid block specification");
    }
    const bool quadratic = spec.order == ElementOrder::Quadratic;
    const int step = quadratic ? 2 : 1; // grid points per cell along an axis
    const std::array<int, 3> cells = {spec.cellsU, spec.cellsV, spec.cellsW};
    const std::array<Distribution, 3> distribution = {spec.distributeU, spec.distributeV, spec.distributeW};

    // Parametric coordinate of grid index `index` along `axis`. Odd indices (midsides) take
    // the midpoint of their graded neighbours rather than the graded midpoint.
    auto parameter = [&](int axis, int index) {
        auto graded = [&](double s) {
            return distribution[axis] ? distribution[axis](s) : s;
        };
        if (!quadratic || index % 2 == 0) {
            return graded(static_cast<double>(index / step) / cells[axis]);
        }
        const int lower = (index - 1) / 2;
        return 0.5 * (graded(static_cast<double>(lower) / cells[axis])
                      + graded(static_cast<double>(lower + 1) / cells[axis]));
    };

    TetMesh mesh;
    mesh.order = spec.order;
    const long long sizeU = static_cast<long long>(cells[0]) * step + 1;
    const long long sizeV = static_cast<long long>(cells[1]) * step + 1;
    std::unordered_map<long long, int> nodeIds;
    auto nodeAt = [&](GridIndex g) {
        const long long key = g.i + sizeU * (g.j + sizeV * g.k);
        const auto found = nodeIds.find(key);
        if (found != nodeIds.end()) {
            return found->second;
        }
        const int id = static_cast<int>(mesh.nodes.size());
        mesh.nodes.push_back(spec.mapping(parameter(0, g.i), parameter(1, g.j), parameter(2, g.k)));
        nodeIds.emplace(key, id);
        return id;
    };

    for (int c = 0; c < cells[2]; ++c) {
        for (int b = 0; b < cells[1]; ++b) {
            for (int a = 0; a < cells[0]; ++a) {
                for (const auto& permutation : kAxisPermutations) {
                    // Corner offsets along the monotone path.
                    std::array<std::array<int, 3>, 4> offset{};
                    for (int n = 1; n < 4; ++n) {
                        offset[n] = offset[n - 1];
                        if (n < 3) {
                            offset[n][permutation[n - 1]] = 1;
                        } else {
                            offset[n] = {1, 1, 1};
                        }
                    }
                    auto corner = [&](int n) {
                        return GridIndex{(a + offset[n][0]) * step, (b + offset[n][1]) * step,
                                         (c + offset[n][2]) * step};
                    };
                    std::array<GridIndex, 4> corners = {corner(0), corner(1), corner(2), corner(3)};
                    std::array<int, 4> ids = {nodeAt(corners[0]), nodeAt(corners[1]),
                                              nodeAt(corners[2]), nodeAt(corners[3])};
                    const Vec3 e1 = mesh.nodes[ids[1]] - mesh.nodes[ids[0]];
                    const Vec3 e2 = mesh.nodes[ids[2]] - mesh.nodes[ids[0]];
                    const Vec3 e3 = mesh.nodes[ids[3]] - mesh.nodes[ids[0]];
                    if (dot(e1, cross(e2, e3)) < 0.0) {
                        std::swap(corners[1], corners[2]);
                        std::swap(ids[1], ids[2]);
                    }

                    std::array<int, 10> element{};
                    element.fill(-1);
                    for (int n = 0; n < 4; ++n) {
                        element[n] = ids[n];
                    }
                    if (quadratic) {
                        for (int e = 0; e < 6; ++e) {
                            const auto& p = corners[kTetEdges[e][0]];
                            const auto& q = corners[kTetEdges[e][1]];
                            element[4 + e] = nodeAt({(p.i + q.i) / 2, (p.j + q.j) / 2, (p.k + q.k) / 2});
                        }
                    }
                    const int elementIndex = static_cast<int>(mesh.elements.size());
                    mesh.elements.push_back(element);

                    for (int f = 0; f < 4; ++f) {
                        const auto& faceCorners = kTetFaces[f];
                        const std::array<int, 3> lastIndex = {cells[0] * step, cells[1] * step, cells[2] * step};
                        for (int axis = 0; axis < 3; ++axis) {
                            auto coordinate = [&](int local) {
                                const auto& g = corners[faceCorners[local]];
                                return axis == 0 ? g.i : (axis == 1 ? g.j : g.k);
                            };
                            for (int side = 0; side < 2; ++side) {
                                const int target = side == 0 ? 0 : lastIndex[axis];
                                if (coordinate(0) == target && coordinate(1) == target && coordinate(2) == target) {
                                    const auto& name = spec.faceNames[axis * 2 + side];
                                    if (!name.empty()) {
                                        mesh.faceGroups[name].push_back({elementIndex, f});
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return mesh;
}

TetMesh mergeMeshes(const std::vector<TetMesh>& meshes, double tolerance) {
    if (meshes.empty()) {
        return {};
    }
    TetMesh merged;
    merged.order = meshes.front().order;
    std::unordered_map<long long, std::vector<int>> buckets;
    auto cellOf = [tolerance](double value) {
        return static_cast<long long>(std::floor(value / tolerance));
    };
    auto key = [](long long x, long long y, long long z) {
        return (x * 73856093LL) ^ (y * 19349663LL) ^ (z * 83492791LL);
    };
    auto fuse = [&](const Vec3& point) {
        const long long cx = cellOf(point.x), cy = cellOf(point.y), cz = cellOf(point.z);
        for (long long dx = -1; dx <= 1; ++dx) {
            for (long long dy = -1; dy <= 1; ++dy) {
                for (long long dz = -1; dz <= 1; ++dz) {
                    const auto found = buckets.find(key(cx + dx, cy + dy, cz + dz));
                    if (found == buckets.end()) {
                        continue;
                    }
                    for (int candidate : found->second) {
                        if (length(merged.nodes[candidate] - point) <= tolerance) {
                            return candidate;
                        }
                    }
                }
            }
        }
        const int id = static_cast<int>(merged.nodes.size());
        merged.nodes.push_back(point);
        buckets[key(cx, cy, cz)].push_back(id);
        return id;
    };

    for (const auto& mesh : meshes) {
        if (mesh.order != merged.order) {
            throw std::invalid_argument("mergeMeshes: element orders differ");
        }
        std::vector<int> remap(mesh.nodes.size());
        for (std::size_t n = 0; n < mesh.nodes.size(); ++n) {
            remap[n] = fuse(mesh.nodes[n]);
        }
        const int elementOffset = static_cast<int>(merged.elements.size());
        for (auto element : mesh.elements) {
            for (int n = 0; n < mesh.nodesPerElement(); ++n) {
                element[n] = remap[element[n]];
            }
            merged.elements.push_back(element);
        }
        for (const auto& [name, faces] : mesh.faceGroups) {
            auto& target = merged.faceGroups[name];
            for (const auto& face : faces) {
                target.push_back({face.element + elementOffset, face.localFace});
            }
        }
    }
    return merged;
}

} // namespace cadnext::fea
