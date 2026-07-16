#pragma once

#include <map>
#include <string>
#include <vector>

#include "cadnext/assembly/ConstraintSolver.hpp"

namespace cadnext::assembly {

// Degree-of-freedom analysis (assembly spec §8), exact joint variant: the
// full numeric Jacobian of every equation in the group is built over the
// stacked 6-variable blocks of the free components, its nullspace gives
// the group's remaining motions, and a component's remaining DOF is the
// rank of the nullspace basis restricted to that component's block. This
// captures coupled chains correctly (a part welded through neighbours to
// ground reports 0 even when none of its own mates fully constrain it).
class DOFAnalyzer {
public:
    struct ComponentDof {
        int remainingDof = 6;
    };

    struct GroupAnalysis {
        std::map<std::string, ComponentDof> dofByComponent;
        // Total remaining motions of the group (nullspace dimension).
        int groupDof = 0;
        // Σ theoretical constraint ranks − rank(J): the number of
        // linearly dependent constraint rows. > 0 means the group carries
        // redundant mates (переопределена); whether that is a conflict is
        // decided by the solver's convergence, not here.
        int redundantConstraints = 0;
    };

    // components/equations как в ConstraintSolver::solve; placements —
    // решённые (анализ линеаризуется в текущей позе).
    static GroupAnalysis analyze(
        const std::vector<ConstraintSolver::ComponentState>& components,
        const std::vector<ConstraintSolver::JointEquation>& equations);
};

} // namespace cadnext::assembly
