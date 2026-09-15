#include "SystemAssembly.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace cadnext::fea::detail {

namespace {

// Smallest eigenvalue and its eigenvector of a symmetric 6×6 matrix (cyclic Jacobi).
std::pair<double, std::array<double, 6>> smallestEigen(std::array<std::array<double, 6>, 6> a) {
    std::array<std::array<double, 6>, 6> v{};
    for (int i = 0; i < 6; ++i) v[i][i] = 1.0;
    for (int sweep = 0; sweep < 100; ++sweep) {
        double off = 0.0;
        for (int p = 0; p < 6; ++p)
            for (int q = p + 1; q < 6; ++q) off += a[p][q] * a[p][q];
        if (off < 1e-30) break;
        for (int p = 0; p < 6; ++p) {
            for (int q = p + 1; q < 6; ++q) {
                if (std::fabs(a[p][q]) < 1e-300) continue;
                const double theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
                const double t = (theta >= 0 ? 1.0 : -1.0) / (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
                const double c = 1.0 / std::sqrt(t * t + 1.0);
                const double s = t * c;
                for (int k = 0; k < 6; ++k) {
                    const double akp = a[k][p], akq = a[k][q];
                    a[k][p] = c * akp - s * akq;
                    a[k][q] = s * akp + c * akq;
                }
                for (int k = 0; k < 6; ++k) {
                    const double apk = a[p][k], aqk = a[q][k];
                    a[p][k] = c * apk - s * aqk;
                    a[q][k] = s * apk + c * aqk;
                }
                for (int k = 0; k < 6; ++k) {
                    const double vkp = v[k][p], vkq = v[k][q];
                    v[k][p] = c * vkp - s * vkq;
                    v[k][q] = s * vkp + c * vkq;
                }
            }
        }
    }
    int best = 0;
    for (int i = 1; i < 6; ++i)
        if (a[i][i] < a[best][best]) best = i;
    std::array<double, 6> vector{};
    for (int k = 0; k < 6; ++k) vector[k] = v[k][best];
    return {a[best][best], vector};
}

void scatter(const TetMesh& mesh, int element, const std::vector<double>& local, const DofMap& map, SymmetricCsc& matrix,
             std::vector<double>* rhs) {
    const int elementDofs = 3 * mesh.nodesPerElement();
    const auto& nodes = mesh.elements[element];
    for (int a = 0; a < elementDofs; ++a) {
        const int ra = map.reduced[3 * nodes[a / 3] + a % 3];
        if (ra < 0) continue;
        for (int b = 0; b < elementDofs; ++b) {
            const int gb = 3 * nodes[b / 3] + b % 3;
            const double value = local[static_cast<std::size_t>(a) * elementDofs + b];
            const int rb = map.reduced[gb];
            if (rb < 0) {
                if (rhs != nullptr) (*rhs)[ra] -= value * *map.prescribed[gb];
            } else if (ra <= rb) {
                matrix.at(ra, rb) += value;
            }
        }
    }
}

} // namespace

double& SymmetricCsc::at(int row, int column) {
    const auto begin = rowIndices.begin() + columnStarts[column];
    const auto end = rowIndices.begin() + columnStarts[column + 1];
    const auto found = std::lower_bound(begin, end, row);
    return values[static_cast<std::size_t>(found - rowIndices.begin())];
}

double SymmetricCsc::at(int row, int column) const {
    const auto begin = rowIndices.begin() + columnStarts[column];
    const auto end = rowIndices.begin() + columnStarts[column + 1];
    const auto found = std::lower_bound(begin, end, row);
    return values[static_cast<std::size_t>(found - rowIndices.begin())];
}

void SymmetricCsc::multiply(const double* x, double* y) const {
    std::fill(y, y + size, 0.0);
    for (int column = 0; column < size; ++column) {
        for (long k = columnStarts[column]; k < columnStarts[column + 1]; ++k) {
            const int row = rowIndices[k];
            const double a = values[k];
            y[row] += a * x[column];
            if (row != column) y[column] += a * x[row];
        }
    }
}

void SymmetricCsc::multiply(const std::vector<double>& x, std::vector<double>& y) const {
    y.resize(size);
    multiply(x.data(), y.data());
}

std::optional<std::string> checkElementNodes(const TetMesh& mesh) {
    const int nodeCount = static_cast<int>(mesh.nodes.size());
    for (const auto& element : mesh.elements) {
        for (int n = 0; n < mesh.nodesPerElement(); ++n) {
            if (element[n] < 0 || element[n] >= nodeCount) return "элемент ссылается на несуществующий узел";
        }
    }
    return std::nullopt;
}

std::optional<std::string> buildDofMap(const TetMesh& mesh, const std::vector<DisplacementConstraint>& constraints,
                                       DofMap& map) {
    const int nodeCount = static_cast<int>(mesh.nodes.size());
    const int dofs = 3 * nodeCount;
    map.prescribed.assign(dofs, std::nullopt);
    for (const auto& constraint : constraints) {
        for (int node : constraint.nodes) {
            if (node < 0 || node >= nodeCount) return "закрепление ссылается на несуществующий узел";
            for (int c = 0; c < 3; ++c) {
                if (!constraint.value[c]) continue;
                auto& slot = map.prescribed[3 * node + c];
                if (slot && std::fabs(*slot - *constraint.value[c]) > 0.0) {
                    return "противоречивые закрепления одного узла";
                }
                slot = constraint.value[c];
            }
        }
    }
    map.reduced.assign(dofs, -1);
    map.freeCount = 0;
    for (int g = 0; g < dofs; ++g) {
        if (!map.prescribed[g]) map.reduced[g] = map.freeCount++;
    }
    return std::nullopt;
}

std::optional<std::string> freeRigidBodyMotion(const TetMesh& mesh, const DofMap& map) {
    // Checked before factorisation: a nearly singular Cholesky does not always fail, it can
    // return a large wrong answer.
    Vec3 low{std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(),
             std::numeric_limits<double>::infinity()};
    Vec3 high{-low.x, -low.y, -low.z};
    for (const auto& p : mesh.nodes) {
        low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
        high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
    }
    const Vec3 centre = (low + high) * 0.5;
    const double scale = std::max(length(high - low), 1e-12);
    std::array<std::array<double, 6>, 6> gram{};
    for (int node = 0; node < static_cast<int>(mesh.nodes.size()); ++node) {
        const Vec3 r = (mesh.nodes[node] - centre) * (1.0 / scale);
        for (int c = 0; c < 3; ++c) {
            if (!map.prescribed[3 * node + c]) continue;
            // Rigid mode columns: translations e_c; rotations ω_k × r, component c.
            std::array<double, 6> row{};
            row[c] = 1.0;
            const std::array<Vec3, 3> rotation = {cross({1, 0, 0}, r), cross({0, 1, 0}, r), cross({0, 0, 1}, r)};
            for (int k = 0; k < 3; ++k) row[3 + k] = rotation[k][c];
            for (int i = 0; i < 6; ++i)
                for (int j = 0; j < 6; ++j) gram[i][j] += row[i] * row[j];
        }
    }
    double largest = 0.0;
    for (int i = 0; i < 6; ++i) largest = std::max(largest, gram[i][i]);
    const auto [smallest, mode] = smallestEigen(gram);
    if (largest > 0.0 && smallest > 1e-10 * largest) return std::nullopt;
    static const char* names[6] = {"сдвиг X", "сдвиг Y", "сдвиг Z", "поворот X", "поворот Y", "поворот Z"};
    int dominant = 0;
    for (int i = 1; i < 6; ++i)
        if (std::fabs(mode[i]) > std::fabs(mode[dominant])) dominant = i;
    return std::string(names[dominant]);
}

std::optional<std::pair<int, double>> firstInvalidElement(const TetMesh& mesh) {
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        const double minimum = tetMinimumJacobian(mesh, e);
        if (!(minimum > 0.0)) return std::make_pair(e, minimum);
    }
    return std::nullopt;
}

SymmetricCsc reducedSparsity(const TetMesh& mesh, const DofMap& map) {
    const int nodeCount = static_cast<int>(mesh.nodes.size());
    const int perElement = mesh.nodesPerElement();
    std::vector<std::vector<int>> neighbours(nodeCount);
    for (const auto& element : mesh.elements) {
        for (int a = 0; a < perElement; ++a)
            for (int b = 0; b < perElement; ++b) neighbours[element[a]].push_back(element[b]);
    }
    for (auto& list : neighbours) {
        std::sort(list.begin(), list.end());
        list.erase(std::unique(list.begin(), list.end()), list.end());
    }
    SymmetricCsc matrix;
    matrix.size = map.freeCount;
    matrix.columnStarts.assign(static_cast<std::size_t>(map.freeCount) + 1, 0);
    for (int g = 0; g < 3 * nodeCount; ++g) {
        const int column = map.reduced[g];
        if (column < 0) continue;
        for (int m : neighbours[g / 3]) {
            for (int c = 0; c < 3; ++c) {
                const int row = map.reduced[3 * m + c];
                if (row >= 0 && row <= column) matrix.rowIndices.push_back(row);
            }
        }
        matrix.columnStarts[column + 1] = static_cast<long>(matrix.rowIndices.size());
    }
    matrix.values.assign(matrix.rowIndices.size(), 0.0);
    return matrix;
}

void assembleStiffness(const TetMesh& mesh, const std::array<std::array<double, 6>, 6>& elasticity, const DofMap& map,
                       SymmetricCsc& K, std::vector<double>* rhs) {
    std::vector<double> local;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        tetStiffness(mesh, e, elasticity, local);
        scatter(mesh, e, local, map, K, rhs);
    }
}

void assembleMass(const TetMesh& mesh, double density, const DofMap& map, SymmetricCsc& M) {
    std::vector<double> local;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        tetMass(mesh, e, density, local);
        scatter(mesh, e, local, map, M, nullptr);
    }
}

bool addFaceNodeWeights(const TetMesh& mesh, const std::string& group, std::vector<double>& weights) {
    const auto found = mesh.faceGroups.find(group);
    if (found == mesh.faceGroups.end()) return false;
    const int faceNodeCount = mesh.order == ElementOrder::Quadratic ? 6 : 3;
    for (const auto& face : found->second) {
        const auto nodes = mesh.faceNodes(face);
        for (const auto& q : triangleQuadratureDegree4()) {
            double N[6], dS[6], dT[6];
            triangleShapeFunctions(mesh.order, q.s, q.t, N, dS, dT);
            Vec3 xs, xt;
            for (int n = 0; n < faceNodeCount; ++n) {
                xs += mesh.nodes[nodes[n]] * dS[n];
                xt += mesh.nodes[nodes[n]] * dT[n];
            }
            const double dA = length(cross(xs, xt)) * q.weight;
            for (int n = 0; n < faceNodeCount; ++n) weights[nodes[n]] += N[n] * dA;
        }
    }
    return true;
}

SparseCholesky::~SparseCholesky() {
    if (valid_) SparseCleanup(factor_);
}

bool SparseCholesky::factor(SymmetricCsc& matrix) {
    if (valid_) {
        SparseCleanup(factor_);
        valid_ = false;
    }
    SparseMatrixStructure structure{};
    structure.rowCount = matrix.size;
    structure.columnCount = matrix.size;
    structure.columnStarts = matrix.columnStarts.data();
    structure.rowIndices = matrix.rowIndices.data();
    structure.attributes.kind = SparseSymmetric;
    structure.attributes.triangle = SparseUpperTriangle;
    structure.blockSize = 1;
    SparseMatrix_Double A{};
    A.structure = structure;
    A.data = matrix.values.data();
    factor_ = SparseFactor(SparseFactorizationCholesky, A);
    if (factor_.status != SparseStatusOK) {
        SparseCleanup(factor_);
        return false;
    }
    valid_ = true;
    size_ = matrix.size;
    return true;
}

void SparseCholesky::solve(std::vector<double>& rhs, std::vector<double>& solution) const {
    solution.resize(size_);
    DenseVector_Double b{size_, rhs.data()};
    DenseVector_Double x{size_, solution.data()};
    SparseSolve(factor_, b, x);
}

void SparseCholesky::solveColumns(std::vector<double>& rhs, std::vector<double>& solution, int columns) const {
    solution.resize(static_cast<std::size_t>(size_) * columns);
    DenseMatrix_Double b{size_, columns, size_, SparseAttributes_t{}, rhs.data()};
    DenseMatrix_Double x{size_, columns, size_, SparseAttributes_t{}, solution.data()};
    SparseSolve(factor_, b, x);
}

} // namespace cadnext::fea::detail
