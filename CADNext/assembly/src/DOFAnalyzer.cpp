#include "cadnext/assembly/DOFAnalyzer.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::assembly {

namespace {

constexpr double kJacobianEpsilon = 1.0e-7;
constexpr double kRankTolerance = 1.0e-6;

Placement applyDelta(const Placement& placement, const double* delta) {
    Placement result = placement;
    result.translation.x += delta[0];
    result.translation.y += delta[1];
    result.translation.z += delta[2];
    const Vector3 rotationVector{delta[3], delta[4], delta[5]};
    const double angle = length(rotationVector);
    if (angle > 1.0e-15) {
        const Quaternion increment = Quaternion::fromAxisAngle(rotationVector, angle);
        result.rotation = increment.multiply(placement.rotation).normalized();
    }
    return result;
}

// Independent motions a constraint removes when non-redundant — the §8
// table. Used only for the redundancy count (rank comes from the actual
// Jacobian).
int theoreticalRank(const ConstraintSolver::JointEquation& equation) {
    const auto directional = [](GeometryReferenceKind kind) {
        return kind != GeometryReferenceKind::Vertex;
    };
    switch (equation.type) {
    case JointType::Coincident: {
        const bool first = directional(equation.firstKind);
        const bool second = directional(equation.secondKind);
        if (!first && !second) {
            return 3; // point-point
        }
        if (!first || !second) {
            return 1; // point-on-plane
        }
        if (equation.firstKind == GeometryReferenceKind::LinearEdge &&
            equation.secondKind == GeometryReferenceKind::LinearEdge) {
            return 4; // colinear
        }
        return 3; // plane-plane
    }
    case JointType::Parallel:
        return 2;
    case JointType::Perpendicular:
        return 1;
    case JointType::Concentric:
        return equation.lockRotation ? 5 : 4;
    case JointType::Distance:
        return 3;
    case JointType::Angle:
        return 1;
    case JointType::Rigid:
        return 6;
    }
    return 0;
}

// Row-echelon reduction with partial pivoting. Returns the pivot column
// per eliminated row; the matrix is reduced in place to (unnormalized)
// upper-echelon form.
std::vector<size_t> rowEchelon(std::vector<std::vector<double>>& matrix, size_t colCount,
                               double tolerance) {
    std::vector<size_t> pivotColumns;
    size_t row = 0;
    for (size_t col = 0; col < colCount && row < matrix.size(); ++col) {
        size_t pivotRow = row;
        double best = std::fabs(matrix[row][col]);
        for (size_t r = row + 1; r < matrix.size(); ++r) {
            if (std::fabs(matrix[r][col]) > best) {
                best = std::fabs(matrix[r][col]);
                pivotRow = r;
            }
        }
        if (best <= tolerance) {
            continue;
        }
        std::swap(matrix[row], matrix[pivotRow]);
        for (size_t r = 0; r < matrix.size(); ++r) {
            if (r == row) {
                continue;
            }
            const double factor = matrix[r][col] / matrix[row][col];
            if (factor == 0.0) {
                continue;
            }
            for (size_t c = col; c < colCount; ++c) {
                matrix[r][c] -= factor * matrix[row][c];
            }
        }
        pivotColumns.push_back(col);
        ++row;
    }
    return pivotColumns;
}

} // namespace

DOFAnalyzer::GroupAnalysis DOFAnalyzer::analyze(
    const std::vector<ConstraintSolver::ComponentState>& components,
    const std::vector<ConstraintSolver::JointEquation>& equations) {
    GroupAnalysis analysis;

    // Variable layout: 6 per free component, in `components` order.
    std::vector<size_t> freeIndices;
    for (size_t i = 0; i < components.size(); ++i) {
        if (components[i].fixed) {
            analysis.dofByComponent[components[i].id] = {0};
        } else {
            freeIndices.push_back(i);
        }
    }
    const size_t variableCount = freeIndices.size() * 6;
    if (variableCount == 0) {
        return analysis;
    }

    // Base residuals + full numeric Jacobian of the group.
    const std::vector<double> base = ConstraintSolver::residuals(components, equations);
    const size_t rowCount = base.size();

    std::vector<std::vector<double>> jacobian(rowCount,
                                              std::vector<double>(variableCount, 0.0));
    for (size_t f = 0; f < freeIndices.size(); ++f) {
        for (int variable = 0; variable < 6; ++variable) {
            double delta[6] = {0, 0, 0, 0, 0, 0};
            delta[variable] = kJacobianEpsilon;
            std::vector<ConstraintSolver::ComponentState> perturbed = components;
            perturbed[freeIndices[f]].placement =
                applyDelta(perturbed[freeIndices[f]].placement, delta);
            const std::vector<double> perturbedResidual =
                ConstraintSolver::residuals(perturbed, equations);
            const size_t column = f * 6 + static_cast<size_t>(variable);
            for (size_t r = 0; r < rowCount && r < perturbedResidual.size(); ++r) {
                jacobian[r][column] =
                    (perturbedResidual[r] - base[r]) / kJacobianEpsilon;
            }
        }
    }

    // Rank + nullspace of J. Free (non-pivot) columns generate the basis:
    // x[freeCol] = 1, pivot variables back-substituted from the reduced
    // rows (rows are fully eliminated above and below → direct read-off).
    std::vector<std::vector<double>> reduced = jacobian;
    const std::vector<size_t> pivotColumns =
        rowEchelon(reduced, variableCount, kRankTolerance);
    const int rank = static_cast<int>(pivotColumns.size());
    analysis.groupDof = static_cast<int>(variableCount) - rank;

    int theoreticalTotal = 0;
    for (const ConstraintSolver::JointEquation& equation : equations) {
        theoreticalTotal += theoreticalRank(equation);
    }
    analysis.redundantConstraints = std::max(0, theoreticalTotal - rank);

    // Nullspace basis vectors, unit-normalized so the per-component rank
    // threshold below is meaningful.
    std::vector<std::vector<double>> nullspace;
    std::vector<bool> isPivot(variableCount, false);
    for (const size_t col : pivotColumns) {
        isPivot[col] = true;
    }
    for (size_t freeCol = 0; freeCol < variableCount; ++freeCol) {
        if (isPivot[freeCol]) {
            continue;
        }
        std::vector<double> vector(variableCount, 0.0);
        vector[freeCol] = 1.0;
        for (size_t pivotRow = 0; pivotRow < pivotColumns.size(); ++pivotRow) {
            const size_t pivotCol = pivotColumns[pivotRow];
            const double pivotValue = reduced[pivotRow][pivotCol];
            if (std::fabs(pivotValue) > 1.0e-15) {
                vector[pivotCol] = -reduced[pivotRow][freeCol] / pivotValue;
            }
        }
        double norm = 0.0;
        for (const double value : vector) {
            norm += value * value;
        }
        norm = std::sqrt(norm);
        if (norm > 1.0e-15) {
            for (double& value : vector) {
                value /= norm;
            }
        }
        nullspace.push_back(std::move(vector));
    }

    // Component DOF = rank of the nullspace restricted to its 6 rows
    // (how many independent group motions actually move this component).
    for (size_t f = 0; f < freeIndices.size(); ++f) {
        const std::string& componentId = components[freeIndices[f]].id;
        if (nullspace.empty()) {
            analysis.dofByComponent[componentId] = {0};
            continue;
        }
        std::vector<std::vector<double>> block(6,
                                               std::vector<double>(nullspace.size(), 0.0));
        for (size_t k = 0; k < nullspace.size(); ++k) {
            for (int variable = 0; variable < 6; ++variable) {
                block[static_cast<size_t>(variable)][k] =
                    nullspace[k][f * 6 + static_cast<size_t>(variable)];
            }
        }
        const std::vector<size_t> blockPivots =
            rowEchelon(block, nullspace.size(), kRankTolerance);
        analysis.dofByComponent[componentId] = {
            static_cast<int>(blockPivots.size())};
    }

    return analysis;
}

} // namespace cadnext::assembly
