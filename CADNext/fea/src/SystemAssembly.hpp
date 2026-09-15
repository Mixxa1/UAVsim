#pragma once

// Internal: the global system shared by the static and the modal solver — DOF numbering with
// prescribed values, the rigid-body check, the sparsity of the reduced system, assembly of the
// stiffness and the consistent mass, and a sparse Cholesky. Not part of the public fea API.

#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/TetElement.hpp"

#include <Accelerate/Accelerate.h>

#include <array>
#include <optional>
#include <string>
#include <vector>

namespace cadnext::fea::detail {

// Upper triangle of a symmetric matrix, compressed by column (Accelerate's layout).
struct SymmetricCsc {
    int size = 0;
    std::vector<long> columnStarts;
    std::vector<int> rowIndices;
    std::vector<double> values;

    double& at(int row, int column);
    double at(int row, int column) const;
    void multiply(const std::vector<double>& x, std::vector<double>& y) const;
    void multiply(const double* x, double* y) const;
};

struct DofMap {
    std::vector<std::optional<double>> prescribed; // per global DOF (3 per node)
    std::vector<int> reduced;                      // global DOF → free index, −1 when prescribed
    int freeCount = 0;
};

// Element node indices in range; empty when fine.
std::optional<std::string> checkElementNodes(const TetMesh& mesh);

// Constraints into a DOF map; the message when they are inconsistent.
std::optional<std::string> buildDofMap(const TetMesh& mesh, const std::vector<DisplacementConstraint>& constraints,
                                       DofMap& map);

// Name of a rigid-body motion the prescribed DOFs leave free ("поворот X"…), none when all six are
// removed.
std::optional<std::string> freeRigidBodyMotion(const TetMesh& mesh, const DofMap& map);

// First element with a non-positive Jacobian anywhere, with that minimum.
std::optional<std::pair<int, double>> firstInvalidElement(const TetMesh& mesh);

SymmetricCsc reducedSparsity(const TetMesh& mesh, const DofMap& map);

// Adds element stiffness into K (same sparsity as reducedSparsity). With `rhs`, the columns of
// prescribed DOFs move to the right-hand side as −K·u_prescribed.
void assembleStiffness(const TetMesh& mesh, const std::array<std::array<double, 6>, 6>& elasticity, const DofMap& map,
                       SymmetricCsc& K, std::vector<double>* rhs);

// Consistent mass ∫ρ NᵀN dV into M (same sparsity).
void assembleMass(const TetMesh& mesh, double density, const DofMap& map, SymmetricCsc& M);

// Adds ∫ N_n dA over a face group to `weights[n]` (sized to the node count): the nodal shares of a
// uniform areal quantity. They sum to the group's area. False when the group does not exist.
bool addFaceNodeWeights(const TetMesh& mesh, const std::string& group, std::vector<double>& weights);

// Accelerate's sparse Cholesky of a SymmetricCsc (which must outlive the factor).
class SparseCholesky {
public:
    SparseCholesky() = default;
    ~SparseCholesky();
    SparseCholesky(const SparseCholesky&) = delete;
    SparseCholesky& operator=(const SparseCholesky&) = delete;

    // False when the matrix is not positive definite.
    bool factor(SymmetricCsc& matrix);
    void solve(std::vector<double>& rhs, std::vector<double>& solution) const;
    // Column-major block of `columns` right-hand sides.
    void solveColumns(std::vector<double>& rhs, std::vector<double>& solution, int columns) const;

private:
    SparseOpaqueFactorization_Double factor_{};
    bool valid_ = false;
    int size_ = 0;
};

} // namespace cadnext::fea::detail
