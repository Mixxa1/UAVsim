#include "cadnext/assembly/ConstraintSolver.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::assembly {

namespace {

constexpr int kMaxIterations = 60;
constexpr double kResidualTolerance = 1.0e-10;
constexpr double kStepTolerance = 1.0e-13;
constexpr double kJacobianEpsilon = 1.0e-7;

struct WorldPair {
    Vector3 o1, o2; // element origins (world)
    Vector3 z1, z2; // element Z directions (world)
    Vector3 x1, x2; // element X directions (world)
};

WorldPair worldPair(const Placement& first, const Frame& firstFrame,
                    const Placement& second, const Frame& secondFrame) {
    const Frame f1 = firstFrame.transformedBy(first);
    const Frame f2 = secondFrame.transformedBy(second);
    return {f1.origin, f2.origin, f1.zAxis, f2.zAxis, f1.xAxis, f2.xAxis};
}

bool isDirectional(GeometryReferenceKind kind) {
    return kind != GeometryReferenceKind::Vertex;
}

// Appends the equation's residuals for the given component placements.
// Signed direction constraints (planes) use the differentiable
// three-component difference z2 − sign·z1 (rank 2 at the solution, the
// sign built in). Axis constraints (concentric, line-line) are
// direction-agnostic by design — a shaft in a bore is valid either way —
// so they use projections onto two stable perpendiculars and the initial
// guess (direct pass / ghost preview) picks the hemisphere.
void appendResiduals(const ConstraintSolver::JointEquation& equation,
                     const Placement& first, const Placement& second,
                     std::vector<double>& out) {
    const WorldPair world =
        worldPair(first, equation.firstLocalFrame, second, equation.secondLocalFrame);
    const double sign = equation.alignment == JointAlignment::Opposed ? -1.0 : 1.0;
    const Vector3 a = stablePerpendicular(world.z1);
    const Vector3 b = cross(world.z1, a);
    const Vector3 delta = subtract(world.o2, world.o1);
    // Signed direction difference for plane-type mates.
    const Vector3 directionError = subtract(world.z2, scale(world.z1, sign));

    switch (equation.type) {
    case JointType::Coincident: {
        const bool firstDirectional = isDirectional(equation.firstKind);
        const bool secondDirectional = isDirectional(equation.secondKind);
        if (!firstDirectional && !secondDirectional) {
            // Point-point.
            out.push_back(delta.x);
            out.push_back(delta.y);
            out.push_back(delta.z);
            break;
        }
        if (!firstDirectional || !secondDirectional) {
            // Point-on-plane along the directional element's normal.
            const Vector3 normal = firstDirectional ? world.z1 : world.z2;
            out.push_back(dot(delta, normal));
            break;
        }
        if (equation.firstKind == GeometryReferenceKind::LinearEdge &&
            equation.secondKind == GeometryReferenceKind::LinearEdge) {
            // Line-line coincidence: colinear (like concentric).
            out.push_back(dot(world.z2, a) - 0.0);
            out.push_back(dot(world.z2, b) - 0.0);
            out.push_back(dot(delta, a));
            out.push_back(dot(delta, b));
            break;
        }
        // Plane-plane: normals aligned/opposed + point on plane. Остаётся
        // 3 DOF: два перемещения в плоскости и вращение вокруг нормали.
        // Three direction rows have rank 2 at the solution and encode the
        // requested sign; the point row removes the normal translation.
        out.push_back(directionError.x);
        out.push_back(directionError.y);
        out.push_back(directionError.z);
        out.push_back(dot(delta, world.z1) - equation.offsetMeters);
        break;
    }
    case JointType::Parallel:
        out.push_back(directionError.x);
        out.push_back(directionError.y);
        out.push_back(directionError.z);
        break;
    case JointType::Perpendicular:
        out.push_back(dot(world.z2, world.z1));
        break;
    case JointType::Concentric: {
        // Axis-axis: направления + два поперечных смещения. Остаются
        // перемещение вдоль оси и вращение вокруг неё (2 DOF).
        out.push_back(dot(world.z2, a));
        out.push_back(dot(world.z2, b));
        out.push_back(dot(delta, a));
        out.push_back(dot(delta, b));
        if (equation.lockRotation) {
            // Lock the in-plane angle between the X axes about the axis.
            out.push_back(dot(world.x2, cross(world.z1, world.x1)));
        }
        break;
    }
    case JointType::Distance:
        out.push_back(directionError.x);
        out.push_back(directionError.y);
        out.push_back(directionError.z);
        out.push_back(dot(delta, world.z1) - equation.offsetMeters);
        break;
    case JointType::Angle:
        out.push_back(dot(world.z2, world.z1) - std::cos(equation.angleRadians));
        break;
    case JointType::Rigid: {
        // Full 6-DOF lock of the mutual placement.
        Placement target;
        if (equation.hasCapturedRelativePlacement) {
            target = first.compose(equation.capturedRelativePlacement);
        } else {
            // Frame alignment fallback (same formula as the direct path).
            Placement jointOffset = Placement::identity();
            jointOffset.translation = {0.0, 0.0, equation.offsetMeters};
            jointOffset.rotation =
                Quaternion::fromAxisAngle({0.0, 0.0, 1.0}, equation.angleRadians);
            if (equation.alignment == JointAlignment::Opposed) {
                jointOffset.rotation =
                    jointOffset.rotation
                        .multiply(Quaternion::fromAxisAngle({1.0, 0.0, 0.0}, M_PI))
                        .normalized();
            }
            target = first.compose(equation.firstLocalFrame.toPlacement())
                         .compose(jointOffset)
                         .compose(equation.secondLocalFrame.toPlacement().inverse());
        }
        out.push_back(second.translation.x - target.translation.x);
        out.push_back(second.translation.y - target.translation.y);
        out.push_back(second.translation.z - target.translation.z);
        // Quaternion error vector (small-angle rotation residual).
        Quaternion error = second.rotation.multiply(target.rotation.conjugate());
        if (error.w < 0.0) {
            error = {-error.x, -error.y, -error.z, -error.w};
        }
        out.push_back(2.0 * error.x);
        out.push_back(2.0 * error.y);
        out.push_back(2.0 * error.z);
        break;
    }
    }
}

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

// Solves (A + lambda*diag(A)) x = rhs for a symmetric positive
// semi-definite A via LDLT without pivoting (small dense systems).
bool solveDamped(std::vector<std::vector<double>> a, std::vector<double> rhs,
                 double lambda, std::vector<double>& solution) {
    const size_t n = a.size();
    for (size_t i = 0; i < n; ++i) {
        a[i][i] += lambda * std::max(a[i][i], 1.0e-9);
    }
    // LDLT decomposition in place.
    for (size_t j = 0; j < n; ++j) {
        for (size_t k = 0; k < j; ++k) {
            a[j][j] -= a[j][k] * a[j][k] * a[k][k];
        }
        if (!(std::fabs(a[j][j]) > 1.0e-14)) {
            return false;
        }
        for (size_t i = j + 1; i < n; ++i) {
            double value = a[i][j];
            for (size_t k = 0; k < j; ++k) {
                value -= a[i][k] * a[j][k] * a[k][k];
            }
            a[i][j] = value / a[j][j];
        }
    }
    // Forward: L y = rhs.
    for (size_t i = 0; i < n; ++i) {
        for (size_t k = 0; k < i; ++k) {
            rhs[i] -= a[i][k] * rhs[k];
        }
    }
    // Diagonal + backward: Lᵀ x = D⁻¹ y.
    for (size_t i = 0; i < n; ++i) {
        rhs[i] /= a[i][i];
    }
    for (size_t i = n; i-- > 0;) {
        for (size_t k = i + 1; k < n; ++k) {
            rhs[i] -= a[k][i] * rhs[k];
        }
    }
    solution = std::move(rhs);
    return true;
}

double maxAbs(const std::vector<double>& values) {
    double result = 0.0;
    for (const double value : values) {
        result = std::max(result, std::fabs(value));
    }
    return result;
}

double squaredNorm(const std::vector<double>& values) {
    double result = 0.0;
    for (const double value : values) {
        result += value * value;
    }
    return result;
}

} // namespace

int ConstraintSolver::residualCount(const JointEquation& equation) {
    switch (equation.type) {
    case JointType::Coincident: {
        const bool firstDirectional = isDirectional(equation.firstKind);
        const bool secondDirectional = isDirectional(equation.secondKind);
        if (!firstDirectional && !secondDirectional) {
            return 3;
        }
        if (!firstDirectional || !secondDirectional) {
            return 1;
        }
        if (equation.firstKind == GeometryReferenceKind::LinearEdge &&
            equation.secondKind == GeometryReferenceKind::LinearEdge) {
            return 4;
        }
        return 4;
    }
    case JointType::Parallel:
        return 3;
    case JointType::Perpendicular:
        return 1;
    case JointType::Concentric:
        return equation.lockRotation ? 5 : 4;
    case JointType::Distance:
        return 4;
    case JointType::Angle:
        return 1;
    case JointType::Rigid:
        return 6;
    }
    return 0;
}

std::vector<double> ConstraintSolver::residuals(
    const std::vector<ComponentState>& components,
    const std::vector<JointEquation>& equations) {
    std::map<std::string, const Placement*> placements;
    for (const ComponentState& component : components) {
        placements[component.id] = &component.placement;
    }
    std::vector<double> result;
    for (const JointEquation& equation : equations) {
        const auto first = placements.find(equation.firstComponentId);
        const auto second = placements.find(equation.secondComponentId);
        if (first == placements.end() || second == placements.end()) {
            continue;
        }
        appendResiduals(equation, *first->second, *second->second, result);
    }
    return result;
}

ConstraintSolver::SolveResult ConstraintSolver::solve(
    const std::vector<ComponentState>& components,
    const std::vector<JointEquation>& equations) {
    SolveResult result;

    // Working copy + variable layout: 6 variables per free component.
    std::vector<ComponentState> state = components;
    std::vector<size_t> freeIndices;
    for (size_t i = 0; i < state.size(); ++i) {
        if (!state[i].fixed) {
            freeIndices.push_back(i);
        }
    }
    const size_t variableCount = freeIndices.size() * 6;
    if (variableCount == 0 || equations.empty()) {
        // Nothing to move: the system is satisfied only if the residuals
        // already are (two grounded parts with a contradictory mate must
        // report a conflict, not silently pass).
        const std::vector<double> residual = residuals(state, equations);
        result.residualNorm = std::sqrt(squaredNorm(residual));
        result.converged = maxAbs(residual) < 1.0e-6;
        return result;
    }

    const auto evaluate = [&](const std::vector<double>& delta) {
        std::vector<ComponentState> candidate = state;
        for (size_t f = 0; f < freeIndices.size(); ++f) {
            candidate[freeIndices[f]].placement =
                applyDelta(state[freeIndices[f]].placement, delta.data() + f * 6);
        }
        return residuals(candidate, equations);
    };

    double lambda = 1.0e-6;
    std::vector<double> zeroDelta(variableCount, 0.0);
    std::vector<double> residual = evaluate(zeroDelta);
    double residualSquared = squaredNorm(residual);

    for (int iteration = 0; iteration < kMaxIterations; ++iteration) {
        result.iterations = iteration + 1;
        if (maxAbs(residual) < kResidualTolerance) {
            break;
        }

        // Numeric Jacobian around the current state.
        const size_t rowCount = residual.size();
        std::vector<std::vector<double>> jacobian(rowCount,
                                                  std::vector<double>(variableCount));
        for (size_t j = 0; j < variableCount; ++j) {
            std::vector<double> delta(variableCount, 0.0);
            delta[j] = kJacobianEpsilon;
            const std::vector<double> perturbed = evaluate(delta);
            for (size_t i = 0; i < rowCount && i < perturbed.size(); ++i) {
                jacobian[i][j] = (perturbed[i] - residual[i]) / kJacobianEpsilon;
            }
        }

        // Normal equations JᵀJ Δ = -Jᵀ r.
        std::vector<std::vector<double>> normal(variableCount,
                                                std::vector<double>(variableCount, 0.0));
        std::vector<double> gradient(variableCount, 0.0);
        for (size_t i = 0; i < rowCount; ++i) {
            for (size_t j = 0; j < variableCount; ++j) {
                gradient[j] -= jacobian[i][j] * residual[i];
                for (size_t k = j; k < variableCount; ++k) {
                    normal[j][k] += jacobian[i][j] * jacobian[i][k];
                }
            }
        }
        for (size_t j = 0; j < variableCount; ++j) {
            for (size_t k = 0; k < j; ++k) {
                normal[j][k] = normal[k][j];
            }
        }

        // Levenberg–Marquardt: retry with stronger damping until the step
        // reduces the residual.
        bool stepped = false;
        for (int attempt = 0; attempt < 8; ++attempt) {
            std::vector<double> step;
            if (!solveDamped(normal, gradient, lambda, step)) {
                lambda *= 10.0;
                continue;
            }
            if (maxAbs(step) < kStepTolerance) {
                stepped = false;
                break;
            }
            const std::vector<double> candidateResidual = evaluate(step);
            const double candidateSquared = squaredNorm(candidateResidual);
            if (candidateSquared <= residualSquared) {
                for (size_t f = 0; f < freeIndices.size(); ++f) {
                    state[freeIndices[f]].placement = applyDelta(
                        state[freeIndices[f]].placement, step.data() + f * 6);
                }
                residual = candidateResidual;
                residualSquared = candidateSquared;
                lambda = std::max(lambda * 0.5, 1.0e-9);
                stepped = true;
                break;
            }
            lambda *= 10.0;
        }
        if (!stepped) {
            break;
        }
    }

    result.residualNorm = std::sqrt(residualSquared);
    // Success criterion: every residual satisfied to an engineering
    // tolerance (1 µm / µrad-scale residual units).
    result.converged = maxAbs(residual) < 1.0e-6;
    if (result.converged) {
        for (const size_t index : freeIndices) {
            result.placements[state[index].id] = state[index].placement;
        }
    }
    return result;
}

} // namespace cadnext::assembly
