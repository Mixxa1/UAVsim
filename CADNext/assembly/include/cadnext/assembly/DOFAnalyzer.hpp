#pragma once

#include <map>
#include <string>
#include <vector>

#include "cadnext/assembly/ConstraintSolver.hpp"

namespace cadnext::assembly {

// Degree-of-freedom analysis (assembly spec §8). For each free component
// it numerically differentiates the residuals of the joints touching it
// (with the rest of the assembly held at the solved placements) and reads
// the constraint rank: removedDof = rank, remainingDof = 6 - rank.
// Redundant rows (rowCount > rank) mark an over-constrained component.
class DOFAnalyzer {
public:
    struct ComponentDof {
        int remainingDof = 6;
        bool overconstrained = false;
    };

    // components/equations как в ConstraintSolver::solve (placements —
    // решённые). conflict помечается вызывающим (recompute engine), когда
    // солвер не сошёлся.
    static std::map<std::string, ComponentDof> analyze(
        const std::vector<ConstraintSolver::ComponentState>& components,
        const std::vector<ConstraintSolver::JointEquation>& equations);
};

} // namespace cadnext::assembly
