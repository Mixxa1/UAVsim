#pragma once

#include <map>
#include <string>
#include <vector>

#include "cadnext/assembly/AssemblyMath.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"

namespace cadnext::assembly {

// Numeric constraint solver (assembly spec §9, второй механизм): damped
// Gauss–Newton over 6 variables (translation + local rotation increment)
// per free component. Handles groups the direct path cannot: several
// mates on one component, closed chains, distances/angles, redundant
// systems. Solve failures keep the caller's placements untouched — the
// recompute engine preserves the last correct state.
class ConstraintSolver {
public:
    struct ComponentState {
        std::string id;
        Placement placement;
        // Grounded components (and the temporary group anchor) are solver
        // constants: DOF = 0.
        bool fixed = false;
    };

    // One joint prepared for solving: resolved part-local frames of both
    // referenced elements.
    struct JointEquation {
        JointType type = JointType::Coincident;
        JointAlignment alignment = JointAlignment::Aligned;
        double offsetMeters = 0.0;
        double angleRadians = 0.0;
        bool lockRotation = false;

        GeometryReferenceKind firstKind = GeometryReferenceKind::PlanarFace;
        GeometryReferenceKind secondKind = GeometryReferenceKind::PlanarFace;

        std::string firstComponentId;
        std::string secondComponentId;
        Frame firstLocalFrame;
        Frame secondLocalFrame;

        bool hasCapturedRelativePlacement = false;
        Placement capturedRelativePlacement;

        // Recompute-engine bookkeeping (which document joint this is).
        std::string jointId;
    };

    struct SolveResult {
        bool converged = false;
        int iterations = 0;
        double residualNorm = 0.0;
        // New placements for the free components (empty until converged).
        std::map<std::string, Placement> placements;
    };

    static SolveResult solve(const std::vector<ComponentState>& components,
                             const std::vector<JointEquation>& equations);

    // Residual vector for the given placements (shared with DOFAnalyzer).
    static std::vector<double> residuals(const std::vector<ComponentState>& components,
                                         const std::vector<JointEquation>& equations);

    // Residual row count of one equation (constraint rank bookkeeping).
    static int residualCount(const JointEquation& equation);
};

} // namespace cadnext::assembly
