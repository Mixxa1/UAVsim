#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"

#include <algorithm>
#include <set>

#include "cadnext/assembly/ConstraintSolver.hpp"
#include "cadnext/assembly/DOFAnalyzer.hpp"
#include "cadnext/assembly/DirectPlacementSolver.hpp"

namespace cadnext::assembly {

namespace {

struct ResolvedJoint {
    AssemblyJoint* joint = nullptr;
    Frame firstLocalFrame;
    Frame secondLocalFrame;
    bool usable = false;
    bool heuristic = false;
};

// Writes the refreshed resolution back into a stored reference so the
// document keeps up-to-date ids/signatures after part edits.
void refreshReference(GeometryReference& reference, const ResolvedReference& resolved) {
    if (resolved.status == ReferenceResolutionStatus::Broken) {
        return;
    }
    reference.persistentTopologyId = resolved.resolvedTopologyId;
    reference.signature = resolved.refreshedSignature;
    reference.fallbackFrame = resolved.localFrame;
}

} // namespace

AssemblyRecomputeEngine::RecomputeResult AssemblyRecomputeEngine::recompute(
    AssemblyDocument& document, const TopologyProvider& topologyProvider) {
    RecomputeResult result;

    // --- 1. Resolve geometry references --------------------------------------
    std::vector<ResolvedJoint> resolvedJoints;
    std::vector<const AssemblyJoint*> usableJoints;

    for (const AssemblyJoint& constJoint : document.joints()) {
        AssemblyJoint* joint = document.mutableJointById(constJoint.id);
        if (!joint) {
            continue;
        }
        ResolvedJoint resolved;
        resolved.joint = joint;

        if (!joint->isEnabled) {
            joint->solveState = {JointSolveStatus::Unsolved, "Joint disabled"};
            resolvedJoints.push_back(resolved);
            continue;
        }

        const auto resolveSide = [&](GeometryReference& reference, Frame& frameOut,
                                     std::string& failureOut) -> bool {
            if (reference.componentPath.empty()) {
                failureOut = "Reference has no component";
                return false;
            }
            const auto component = document.componentById(reference.componentPath.front());
            if (!component.isOk()) {
                failureOut = "Component missing: " + reference.componentPath.front();
                return false;
            }
            if (component.value().isSuppressed) {
                failureOut = "Component suppressed: " + component.value().name;
                return false;
            }
            const PartTopology* topology = topologyProvider
                                               ? topologyProvider(component.value())
                                               : nullptr;
            if (!topology) {
                failureOut = "Part geometry unavailable: " + component.value().name;
                return false;
            }
            const ResolvedReference resolvedRef =
                GeometryReferenceResolver::resolve(reference, *topology);
            if (resolvedRef.status == ReferenceResolutionStatus::Broken) {
                failureOut = resolvedRef.message;
                return false;
            }
            if (resolvedRef.status == ReferenceResolutionStatus::Heuristic) {
                resolved.heuristic = true;
            }
            refreshReference(reference, resolvedRef);
            frameOut = resolvedRef.localFrame;
            return true;
        };

        std::string failure;
        if (!resolveSide(joint->first, resolved.firstLocalFrame, failure) ||
            !resolveSide(joint->second, resolved.secondLocalFrame, failure)) {
            joint->solveState = {JointSolveStatus::Broken, failure};
            AssemblyDiagnostic diagnostic;
            diagnostic.severity = DiagnosticSeverity::Error;
            diagnostic.message = "Joint '" + joint->name + "' broken: " + failure;
            diagnostic.jointId = joint->id;
            result.diagnostics.push_back(diagnostic);
            resolvedJoints.push_back(resolved);
            continue;
        }

        resolved.usable = true;
        resolvedJoints.push_back(resolved);
        usableJoints.push_back(joint);
    }

    // --- 2. Component graph ---------------------------------------------------
    const AssemblyGraph graph = AssemblyGraph::build(document, usableJoints);

    // --- 3. Grounded anchors + 4. direct solve per group ----------------------
    std::map<std::string, Placement> newPlacements;

    for (const AssemblyGraph::Group& group : graph.groups()) {
        const bool groundedGroup = !group.groundedComponentIds.empty();

        // Fixed set: grounded components, or a single temporary anchor so
        // nothing flies away when no base is grounded (spec §5).
        std::set<std::string> fixedSet(group.groundedComponentIds.begin(),
                                       group.groundedComponentIds.end());
        std::string anchor;
        if (!groundedGroup && !group.jointIds.empty()) {
            // Only groups with mates need a temporary anchor; a lone
            // unmated component stays genuinely free (6 DOF), not
            // «полностью определена» by anchoring itself.
            size_t bestJointCount = 0;
            for (const std::string& componentId : group.componentIds) {
                const size_t jointCount = graph.jointIdsForComponent(componentId).size();
                if (anchor.empty() || jointCount > bestJointCount) {
                    anchor = componentId;
                    bestJointCount = jointCount;
                }
            }
            if (!anchor.empty()) {
                fixedSet.insert(anchor);
            }
            if (!group.jointIds.empty()) {
                AssemblyDiagnostic diagnostic;
                diagnostic.severity = DiagnosticSeverity::Warning;
                diagnostic.componentId = anchor;
                diagnostic.message =
                    "Assembly group has no grounded base; the solve result "
                    "may be under-determined";
                result.diagnostics.push_back(diagnostic);
            }
        }

        const auto placementOf = [&](const std::string& componentId) {
            const auto it = newPlacements.find(componentId);
            if (it != newPlacements.end()) {
                return it->second;
            }
            const auto component = document.componentById(componentId);
            return component.isOk() ? component.value().placement : Placement::identity();
        };

        // --- 4a. Direct pass: analytic initial guess through BFS ------------
        // The first joint reaching an unplaced component positions it
        // analytically; joints between two placed components fall to the
        // numeric stage below.
        std::set<std::string> placed = fixedSet;
        std::set<std::string> appliedJoints;
        bool progressed = true;
        while (progressed) {
            progressed = false;
            for (ResolvedJoint& resolved : resolvedJoints) {
                if (!resolved.usable || !resolved.joint) {
                    continue;
                }
                AssemblyJoint& joint = *resolved.joint;
                if (appliedJoints.count(joint.id) ||
                    !std::count(group.jointIds.begin(), group.jointIds.end(), joint.id)) {
                    continue;
                }
                const std::string& firstId = joint.first.componentPath.front();
                const std::string& secondId = joint.second.componentPath.front();
                const bool firstPlaced = placed.count(firstId) > 0;
                const bool secondPlaced = placed.count(secondId) > 0;
                if (firstPlaced == secondPlaced) {
                    continue;
                }

                const std::string& parentId = firstPlaced ? firstId : secondId;
                const std::string& childId = firstPlaced ? secondId : firstId;
                AssemblyComponent* child = document.mutableComponentById(childId);
                if (!child) {
                    continue;
                }
                if (fixedSet.count(childId)) {
                    placed.insert(childId);
                    progressed = true;
                    continue;
                }

                DirectPlacementSolver::Input input;
                input.type = joint.type;
                input.alignment = joint.alignment;
                input.offsetMeters = joint.offsetMeters;
                input.angleRadians = joint.angleRadians;
                input.hasCapturedRelativePlacement = joint.hasCapturedRelativePlacement;
                input.capturedRelativePlacement = joint.capturedRelativePlacement;
                input.parentPlacement = placementOf(parentId);
                input.childPlacement = placementOf(childId);
                if (firstPlaced) {
                    input.parentLocalFrame = resolved.firstLocalFrame;
                    input.childLocalFrame = resolved.secondLocalFrame;
                } else {
                    input.parentLocalFrame = resolved.secondLocalFrame;
                    input.childLocalFrame = resolved.firstLocalFrame;
                    if (joint.hasCapturedRelativePlacement) {
                        input.capturedRelativePlacement =
                            joint.capturedRelativePlacement.inverse();
                    }
                }

                newPlacements[childId] = DirectPlacementSolver::solveChildPlacement(input);
                placed.insert(childId);
                appliedJoints.insert(joint.id);
                progressed = true;
            }
        }

        // --- 4b. Numeric constraint solver over the whole group ------------
        // The direct pass is the initial guess; the solver satisfies every
        // mate simultaneously (multiple mates, closed chains, distances,
        // angles) and detects conflicts.
        std::vector<ConstraintSolver::ComponentState> states;
        for (const std::string& componentId : group.componentIds) {
            ConstraintSolver::ComponentState state;
            state.id = componentId;
            state.placement = placementOf(componentId);
            state.fixed = fixedSet.count(componentId) > 0;
            states.push_back(state);
        }

        std::vector<ConstraintSolver::JointEquation> equations;
        std::vector<ResolvedJoint*> groupResolved;
        for (ResolvedJoint& resolved : resolvedJoints) {
            if (!resolved.usable || !resolved.joint) {
                continue;
            }
            if (!std::count(group.jointIds.begin(), group.jointIds.end(),
                            resolved.joint->id)) {
                continue;
            }
            groupResolved.push_back(&resolved);
            const AssemblyJoint& joint = *resolved.joint;
            ConstraintSolver::JointEquation equation;
            equation.type = joint.type;
            equation.alignment = joint.alignment;
            equation.offsetMeters = joint.offsetMeters;
            equation.angleRadians = joint.angleRadians;
            equation.lockRotation = joint.lockRotation;
            equation.firstKind = joint.first.kind;
            equation.secondKind = joint.second.kind;
            equation.firstComponentId = joint.first.componentPath.front();
            equation.secondComponentId = joint.second.componentPath.front();
            equation.firstLocalFrame = resolved.firstLocalFrame;
            equation.secondLocalFrame = resolved.secondLocalFrame;
            equation.hasCapturedRelativePlacement = joint.hasCapturedRelativePlacement;
            equation.capturedRelativePlacement = joint.capturedRelativePlacement;
            equation.jointId = joint.id;
            equations.push_back(equation);
        }

        const ConstraintSolver::SolveResult solveResult =
            ConstraintSolver::solve(states, equations);

        if (solveResult.converged) {
            for (const auto& entry : solveResult.placements) {
                newPlacements[entry.first] = entry.second;
                for (ConstraintSolver::ComponentState& state : states) {
                    if (state.id == entry.first) {
                        state.placement = entry.second;
                    }
                }
            }
            for (ResolvedJoint* resolved : groupResolved) {
                resolved->joint->solveState = {
                    resolved->heuristic ? JointSolveStatus::SolvedHeuristic
                                        : JointSolveStatus::Solved,
                    resolved->heuristic ? "Reference re-bound by signature"
                                        : std::string()};
            }
        } else {
            // Keep the direct-pass placements (nothing flies away). Joints
            // the direct pass could satisfy stay Solved; the leftover mates
            // are the conflicting/over-constraining ones.
            for (ResolvedJoint* resolved : groupResolved) {
                const bool applied = appliedJoints.count(resolved->joint->id) > 0;
                resolved->joint->solveState = {
                    applied ? (resolved->heuristic ? JointSolveStatus::SolvedHeuristic
                                                   : JointSolveStatus::Solved)
                            : JointSolveStatus::Conflict,
                    applied ? std::string()
                            : "Constraint system could not be satisfied"};
            }
            if (!group.jointIds.empty()) {
                AssemblyDiagnostic diagnostic;
                diagnostic.severity = DiagnosticSeverity::Error;
                diagnostic.message =
                    "Constraint solver did not converge; last correct "
                    "placements kept";
                result.diagnostics.push_back(diagnostic);
            }
        }

        // --- 5. DOF analysis over the group -------------------------------
        const DOFAnalyzer::GroupAnalysis dof = DOFAnalyzer::analyze(states, equations);
        if (dof.redundantConstraints > 0 && solveResult.converged &&
            !group.jointIds.empty()) {
            // Redundant-but-consistent mates (например плоскость + соосность
            // с перпендикулярной осью) — информация, не ошибка: конфликтом
            // управляет сходимость решателя.
            AssemblyDiagnostic diagnostic;
            diagnostic.severity = DiagnosticSeverity::Info;
            diagnostic.message =
                "Assembly group is over-determined: " +
                std::to_string(dof.redundantConstraints) +
                " redundant constraint(s), system consistent";
            result.diagnostics.push_back(diagnostic);
        }
        for (const std::string& componentId : group.componentIds) {
            ComponentDofInfo info;
            const auto component = document.componentById(componentId);
            info.isGrounded = component.isOk() && component.value().isGrounded;
            info.inGroundedGroup = groundedGroup;
            if (info.isGrounded) {
                info.remainingDof = 0;
            } else {
                const auto it = dof.dofByComponent.find(componentId);
                info.remainingDof =
                    it != dof.dofByComponent.end() ? it->second.remainingDof : 6;
                info.conflict = !solveResult.converged;
            }
            result.dofByComponent[componentId] = info;
        }
    }

    // --- 6. Atomic placement write --------------------------------------------
    for (const auto& entry : newPlacements) {
        AssemblyComponent* component = document.mutableComponentById(entry.first);
        if (!component || component->isGrounded) {
            continue;
        }
        const Placement& target = entry.second;
        if (!nearlyEqual(component->placement.translation, target.translation, 1.0e-12) ||
            !nearlyEqual(component->placement.rotation.x, target.rotation.x, 1.0e-12) ||
            !nearlyEqual(component->placement.rotation.y, target.rotation.y, 1.0e-12) ||
            !nearlyEqual(component->placement.rotation.z, target.rotation.z, 1.0e-12) ||
            !nearlyEqual(component->placement.rotation.w, target.rotation.w, 1.0e-12)) {
            result.placementsChanged = true;
        }
        component->placement = target;
    }

    document.setDiagnostics(result.diagnostics);
    return result;
}

} // namespace cadnext::assembly
