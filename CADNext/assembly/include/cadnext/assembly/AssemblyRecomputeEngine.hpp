#pragma once

#include <functional>
#include <map>
#include <string>
#include <vector>

#include "cadnext/assembly/AssemblyGraph.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/assembly/GeometryReferenceResolver.hpp"

namespace cadnext::assembly {

// The single recompute pipeline (assembly spec §10):
//
//   dirty document
//     → resolve geometry references (exact id → signature → broken)
//     → build the component graph from usable joints
//     → check grounded anchors per connected group
//     → direct transform for unambiguous branches
//     → constraint solver for the remaining groups (numeric stage)
//     → DOF analysis
//     → validation / diagnostics
//     → atomic placement write
//
// Geometry is never rebuilt here: only placements move. Solve failures
// keep the last correct placements (components never «fly away»).
class AssemblyRecomputeEngine {
public:
    // Loaded topology of a component's part body (part-local space), or
    // nullptr when the source failed to load — every joint touching that
    // component is then marked broken.
    using TopologyProvider =
        std::function<const PartTopology*(const AssemblyComponent&)>;

    struct ComponentDofInfo {
        // Remaining degrees of freedom; -1 = unknown (not analyzed).
        int remainingDof = -1;
        bool isGrounded = false;
        bool inGroundedGroup = false;
        bool conflict = false;
    };

    struct RecomputeResult {
        bool placementsChanged = false;
        std::vector<AssemblyDiagnostic> diagnostics;
        std::map<std::string, ComponentDofInfo> dofByComponent;
    };

    RecomputeResult recompute(AssemblyDocument& document,
                              const TopologyProvider& topologyProvider);
};

} // namespace cadnext::assembly
