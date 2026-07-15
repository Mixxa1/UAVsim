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

// Rank of a rowCount x colCount matrix via Gaussian elimination with
// partial pivoting (colCount is always 6 here).
int matrixRank(std::vector<std::vector<double>> matrix, size_t colCount) {
    int rank = 0;
    const size_t rowCount = matrix.size();
    std::vector<bool> usedRow(rowCount, false);
    for (size_t col = 0; col < colCount; ++col) {
        int pivotRow = -1;
        double best = kRankTolerance;
        for (size_t row = 0; row < rowCount; ++row) {
            if (usedRow[row]) {
                continue;
            }
            if (std::fabs(matrix[row][col]) > best) {
                best = std::fabs(matrix[row][col]);
                pivotRow = static_cast<int>(row);
            }
        }
        if (pivotRow < 0) {
            continue;
        }
        usedRow[pivotRow] = true;
        ++rank;
        const double pivot = matrix[pivotRow][col];
        for (size_t row = 0; row < rowCount; ++row) {
            if (row == static_cast<size_t>(pivotRow) || usedRow[row]) {
                continue;
            }
            const double factor = matrix[row][col] / pivot;
            if (factor == 0.0) {
                continue;
            }
            for (size_t c = col; c < colCount; ++c) {
                matrix[row][c] -= factor * matrix[pivotRow][c];
            }
        }
    }
    return rank;
}

} // namespace

std::map<std::string, DOFAnalyzer::ComponentDof> DOFAnalyzer::analyze(
    const std::vector<ConstraintSolver::ComponentState>& components,
    const std::vector<ConstraintSolver::JointEquation>& equations) {
    std::map<std::string, ComponentDof> result;

    for (const ConstraintSolver::ComponentState& component : components) {
        if (component.fixed) {
            result[component.id] = {0, false};
            continue;
        }

        // Equations touching this component.
        std::vector<ConstraintSolver::JointEquation> touching;
        for (const ConstraintSolver::JointEquation& equation : equations) {
            if (equation.firstComponentId == component.id ||
                equation.secondComponentId == component.id) {
                touching.push_back(equation);
            }
        }
        if (touching.empty()) {
            result[component.id] = {6, false};
            continue;
        }

        // Base residuals + numeric Jacobian w.r.t. this component's 6
        // variables, the rest of the assembly held at its solved pose.
        const std::vector<double> base =
            ConstraintSolver::residuals(components, touching);
        const size_t rowCount = base.size();
        std::vector<std::vector<double>> jacobian(rowCount, std::vector<double>(6, 0.0));

        for (int variable = 0; variable < 6; ++variable) {
            double delta[6] = {0, 0, 0, 0, 0, 0};
            delta[variable] = kJacobianEpsilon;
            std::vector<ConstraintSolver::ComponentState> perturbed = components;
            for (ConstraintSolver::ComponentState& candidate : perturbed) {
                if (candidate.id == component.id) {
                    candidate.placement = applyDelta(candidate.placement, delta);
                    break;
                }
            }
            const std::vector<double> perturbedResidual =
                ConstraintSolver::residuals(perturbed, touching);
            for (size_t row = 0; row < rowCount && row < perturbedResidual.size(); ++row) {
                jacobian[row][static_cast<size_t>(variable)] =
                    (perturbedResidual[row] - base[row]) / kJacobianEpsilon;
            }
        }

        const int rank = matrixRank(jacobian, 6);
        ComponentDof dof;
        dof.remainingDof = std::max(0, 6 - rank);
        // Redundant rows (more constraint equations than independent
        // directions) → over-constrained.
        dof.overconstrained = static_cast<int>(rowCount) > rank;
        result[component.id] = dof;
    }

    return result;
}

} // namespace cadnext::assembly
