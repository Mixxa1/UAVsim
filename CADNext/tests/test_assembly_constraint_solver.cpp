// ConstraintSolver + DOFAnalyzer over the recompute engine: the DOF table
// from assembly spec §8 (plane-plane → 3 DOF, concentric → 2, plane +
// concentric + lock → 0), a distance mate, a closed chain, and an
// over-/conflicting-constraint case.
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"
#include "cadnext/assembly/ConstraintSolver.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::assembly;
namespace kernel = cadnext::kernel;

namespace {

constexpr double kTol = 1.0e-6;

// A cube part: top/bottom planar faces + a coaxial cylindrical bore (its
// axis along Z) + the bore's top circular edge — enough to exercise every
// mate the DOF table cares about.
PartTopology cubeWithBore() {
    PartTopology topology;

    kernel::FaceReference top;
    top.bodyId = "b";
    top.faceId = "face-top";
    top.kind = kernel::FaceKind::Planar;
    top.origin = {0.0, 0.0, 0.5};
    top.normal = {0.0, 0.0, 1.0};
    top.uAxis = {1.0, 0.0, 0.0};
    top.vAxis = {0.0, 1.0, 0.0};
    top.area = 1.0;
    topology.faces.push_back(top);

    kernel::FaceReference bottom = top;
    bottom.faceId = "face-bottom";
    bottom.origin = {0.0, 0.0, -0.5};
    bottom.normal = {0.0, 0.0, -1.0};
    bottom.vAxis = {0.0, -1.0, 0.0};
    topology.faces.push_back(bottom);

    kernel::FaceReference bore;
    bore.bodyId = "b";
    bore.faceId = "face-bore";
    bore.kind = kernel::FaceKind::Cylindrical;
    bore.axisOrigin = {0.0, 0.0, 0.0};
    bore.axisDirection = {0.0, 0.0, 1.0};
    bore.radius = 0.1;
    bore.area = 0.6;
    topology.faces.push_back(bore);

    kernel::EdgeReference boreEdge;
    boreEdge.bodyId = "b";
    boreEdge.edgeId = "edge-bore-top";
    boreEdge.kind = kernel::EdgeKind::Circle;
    boreEdge.center = {0.0, 0.0, 0.5};
    boreEdge.axisDirection = {0.0, 0.0, 1.0};
    boreEdge.radius = 0.1;
    boreEdge.length = 2.0 * M_PI * 0.1;
    topology.edges.push_back(boreEdge);

    return topology;
}

AssemblyComponent makeComponent(const std::string& id, bool grounded,
                                cadnext::Vector3 position) {
    AssemblyComponent component;
    component.id = id;
    component.name = id;
    component.source.kind = PartSourceKind::UavPart;
    component.source.filePath = "/tmp/" + id + ".uavpart";
    component.isGrounded = grounded;
    component.placement.translation = position;
    return component;
}

GeometryReference faceRef(const PartTopology& topology, const std::string& componentId,
                          size_t index) {
    return GeometryReferenceResolver::makeFaceReference({componentId},
                                                        topology.faces[index]);
}

GeometryReference edgeRef(const PartTopology& topology, const std::string& componentId,
                          size_t index) {
    return GeometryReferenceResolver::makeEdgeReference({componentId},
                                                        topology.edges[index]);
}

int dof(const AssemblyRecomputeEngine::RecomputeResult& result, const std::string& id) {
    return result.dofByComponent.at(id).remainingDof;
}

} // namespace

int main() {
    const PartTopology topology = cubeWithBore();
    const auto provider = [&topology](const AssemblyComponent&) { return &topology; };
    AssemblyRecomputeEngine engine;

    // --- Plane-plane coincident: leaves 3 DOF -------------------------------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
        document.addComponent(makeComponent("b", false, {3.0, 1.0, 2.0}));
        AssemblyJoint joint;
        joint.id = "joint-1";
        joint.name = "Coincident001";
        joint.type = JointType::Coincident;
        joint.alignment = JointAlignment::Opposed;
        joint.first = faceRef(topology, "a", 0);  // top of A
        joint.second = faceRef(topology, "b", 1); // bottom of B
        document.addJoint(joint);

        const auto result = engine.recompute(document, provider);
        assert(document.jointById("joint-1").value().solveState.status ==
               JointSolveStatus::Solved);
        assert(dof(result, "b") == 3);
        // Bottom face of B mated onto the top face of A: contact plane z=0.5.
        const Placement placementB = document.componentById("b").value().placement;
        // The face-on-face residual keeps B's bottom on A's top (z ≈ 1.0
        // center → bottom face at 0.5). Отдельно проверяем плоскостность:
        const Frame bottomWorld =
            GeometryReferenceResolver::resolve(faceRef(topology, "b", 1), topology)
                .localFrame.transformedBy(placementB);
        assert(nearlyEqual(bottomWorld.origin.z, 0.5, kTol));
    }

    // --- Concentric of the two bores: leaves 2 DOF --------------------------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
        document.addComponent(makeComponent("b", false, {2.5, 0.7, 1.3}));
        AssemblyJoint joint;
        joint.id = "joint-1";
        joint.name = "Concentric001";
        joint.type = JointType::Concentric;
        joint.first = faceRef(topology, "a", 2);  // bore of A
        joint.second = faceRef(topology, "b", 2); // bore of B
        document.addJoint(joint);

        const auto result = engine.recompute(document, provider);
        assert(document.jointById("joint-1").value().solveState.status ==
               JointSolveStatus::Solved);
        assert(dof(result, "b") == 2);
        // Axes coincident: B's bore axis passes through the world Z axis.
        const Placement placementB = document.componentById("b").value().placement;
        const Frame axisWorld =
            GeometryReferenceResolver::resolve(faceRef(topology, "b", 2), topology)
                .localFrame.transformedBy(placementB);
        // A point on B's axis projected to XY must be at the origin.
        assert(nearlyEqual(axisWorld.origin.x, 0.0, 1.0e-4));
        assert(nearlyEqual(axisWorld.origin.y, 0.0, 1.0e-4));
    }

    // --- Plane + concentric + lockRotation: fully constrained (0 DOF) -------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
        document.addComponent(makeComponent("b", false, {2.0, 0.5, 1.0}));

        AssemblyJoint plane;
        plane.id = "joint-1";
        plane.name = "Coincident001";
        plane.type = JointType::Coincident;
        plane.alignment = JointAlignment::Opposed;
        plane.first = faceRef(topology, "a", 0);
        plane.second = faceRef(topology, "b", 1);
        document.addJoint(plane);

        AssemblyJoint concentric;
        concentric.id = "joint-2";
        concentric.name = "Concentric001";
        concentric.type = JointType::Concentric;
        concentric.lockRotation = true;
        concentric.first = faceRef(topology, "a", 2);
        concentric.second = faceRef(topology, "b", 2);
        document.addJoint(concentric);

        const auto result = engine.recompute(document, provider);
        assert(document.jointById("joint-1").value().solveState.status ==
               JointSolveStatus::Solved);
        assert(document.jointById("joint-2").value().solveState.status ==
               JointSolveStatus::Solved);
        assert(dof(result, "b") == 0);
    }

    // --- Distance mate: still leaves 3 DOF (parallel planes at offset) ------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
        document.addComponent(makeComponent("b", false, {0.0, 0.0, 3.0}));
        AssemblyJoint joint;
        joint.id = "joint-1";
        joint.name = "Distance001";
        joint.type = JointType::Distance;
        joint.alignment = JointAlignment::Aligned;
        joint.offsetMeters = 0.25;
        joint.first = faceRef(topology, "a", 0);
        joint.second = faceRef(topology, "b", 1);
        document.addJoint(joint);

        const auto result = engine.recompute(document, provider);
        assert(document.jointById("joint-1").value().solveState.status ==
               JointSolveStatus::Solved);
        assert(dof(result, "b") == 3);
        // Separation along the shared normal equals the offset.
        const Placement placementB = document.componentById("b").value().placement;
        const Frame bottomWorld =
            GeometryReferenceResolver::resolve(faceRef(topology, "b", 1), topology)
                .localFrame.transformedBy(placementB);
        // A top face at z=0.5, aligned distance 0.25 → B's bottom face at 0.75.
        assert(nearlyEqual(bottomWorld.origin.z, 0.75, 1.0e-4));
    }

    // --- Closed chain: three cubes, concentric ring — all solved ------------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
        document.addComponent(makeComponent("b", false, {1.0, 0.0, 0.0}));
        document.addComponent(makeComponent("c", false, {0.5, 1.0, 0.0}));

        // Three coincident planes forming a cycle a-b, b-c, c-a. Concentric
        // не берём (это создало бы конфликт), только совпадения плоскостей,
        // совместимые между собой (все на z=0.5 aligned).
        auto addPlane = [&](const std::string& id, const std::string& first,
                            const std::string& second) {
            AssemblyJoint joint;
            joint.id = id;
            joint.name = id;
            joint.type = JointType::Coincident;
            joint.alignment = JointAlignment::Aligned;
            joint.first = faceRef(topology, first, 0);
            joint.second = faceRef(topology, second, 0);
            document.addJoint(joint);
        };
        addPlane("joint-ab", "a", "b");
        addPlane("joint-bc", "b", "c");
        addPlane("joint-ca", "c", "a");

        const auto result = engine.recompute(document, provider);
        // Consistent cycle: solver converges, no conflict.
        for (const AssemblyJoint& joint : document.joints()) {
            assert(joint.solveState.status == JointSolveStatus::Solved ||
                   joint.solveState.status == JointSolveStatus::SolvedHeuristic);
        }
        // All three top faces share a common plane; b and c constrained to it.
        const Placement placementB = document.componentById("b").value().placement;
        const Frame topB =
            GeometryReferenceResolver::resolve(faceRef(topology, "b", 0), topology)
                .localFrame.transformedBy(placementB);
        assert(nearlyEqual(topB.origin.z, 0.5, 1.0e-4));
    }

    // --- Over-constrained / conflicting: contradictory distances ------------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
        document.addComponent(makeComponent("b", false, {0.0, 0.0, 2.0}));

        AssemblyJoint near;
        near.id = "joint-near";
        near.name = "Distance001";
        near.type = JointType::Distance;
        near.alignment = JointAlignment::Aligned;
        near.offsetMeters = 0.2;
        near.first = faceRef(topology, "a", 0);
        near.second = faceRef(topology, "b", 1);
        document.addJoint(near);

        // Contradictory: same faces, different distance.
        AssemblyJoint far;
        far.id = "joint-far";
        far.name = "Distance002";
        far.type = JointType::Distance;
        far.alignment = JointAlignment::Aligned;
        far.offsetMeters = 0.9;
        far.first = faceRef(topology, "a", 0);
        far.second = faceRef(topology, "b", 1);
        document.addJoint(far);

        const auto result = engine.recompute(document, provider);
        // The solver cannot satisfy both → at least one joint is a conflict
        // and the free component is flagged.
        bool conflict = false;
        for (const AssemblyJoint& joint : document.joints()) {
            conflict = conflict || joint.solveState.status == JointSolveStatus::Conflict;
        }
        assert(conflict);
        assert(result.dofByComponent.at("b").conflict);
        // Placement stayed finite (nothing flew away).
        const Placement placementB = document.componentById("b").value().placement;
        assert(std::isfinite(placementB.translation.z));
    }

    // --- Signed direction residual: recovers from a badly-oriented start ----
    // The free part begins with its mated normal ~150° away from the
    // opposed target; the solver must rotate onto the requested hemisphere
    // (an unsigned formulation would settle on the wrong side).
    {
        ConstraintSolver::ComponentState fixed;
        fixed.id = "a";
        fixed.fixed = true;

        ConstraintSolver::ComponentState free;
        free.id = "b";
        free.placement.translation = {0.3, -0.2, 2.0};
        free.placement.rotation =
            Quaternion::fromAxisAngle({1.0, 0.0, 0.0}, 150.0 * M_PI / 180.0);

        ConstraintSolver::JointEquation equation;
        equation.type = JointType::Coincident;
        equation.alignment = JointAlignment::Opposed;
        equation.firstKind = GeometryReferenceKind::PlanarFace;
        equation.secondKind = GeometryReferenceKind::PlanarFace;
        equation.firstComponentId = "a";
        equation.secondComponentId = "b";
        // A's top face frame; B's bottom face frame.
        equation.firstLocalFrame =
            Frame::fromOriginZX({0.0, 0.0, 0.5}, {0.0, 0.0, 1.0}, {1.0, 0.0, 0.0});
        equation.secondLocalFrame =
            Frame::fromOriginZX({0.0, 0.0, -0.5}, {0.0, 0.0, -1.0}, {1.0, 0.0, 0.0});

        const ConstraintSolver::SolveResult solved =
            ConstraintSolver::solve({fixed, free}, {equation});
        assert(solved.converged);
        const Placement placementB = solved.placements.at("b");
        const Frame bottomWorld = equation.secondLocalFrame.transformedBy(placementB);
        // Opposed: B's bottom normal must end up exactly −Z (not +Z).
        assert(nearlyEqual(dot(bottomWorld.zAxis, {0.0, 0.0, 1.0}), -1.0, 1.0e-6));
        assert(nearlyEqual(bottomWorld.origin.z, 0.5, 1.0e-5));
    }

    // --- Two fixed parts + contradictory mate: no variables, must conflict --
    {
        ConstraintSolver::ComponentState first;
        first.id = "a";
        first.fixed = true;
        ConstraintSolver::ComponentState second;
        second.id = "b";
        second.fixed = true;
        second.placement.translation = {0.0, 0.0, 5.0}; // far from the mate

        ConstraintSolver::JointEquation equation;
        equation.type = JointType::Coincident;
        equation.alignment = JointAlignment::Opposed;
        equation.firstKind = GeometryReferenceKind::PlanarFace;
        equation.secondKind = GeometryReferenceKind::PlanarFace;
        equation.firstComponentId = "a";
        equation.secondComponentId = "b";
        equation.firstLocalFrame =
            Frame::fromOriginZX({0.0, 0.0, 0.5}, {0.0, 0.0, 1.0}, {1.0, 0.0, 0.0});
        equation.secondLocalFrame =
            Frame::fromOriginZX({0.0, 0.0, -0.5}, {0.0, 0.0, -1.0}, {1.0, 0.0, 0.0});

        const ConstraintSolver::SolveResult solved =
            ConstraintSolver::solve({first, second}, {equation});
        assert(!solved.converged);
    }

    // --- A lone unmated component stays genuinely free (6 DOF, no anchor) ---
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("solo", false, {1.0, 2.0, 3.0}));
        const auto result = engine.recompute(document, provider);
        assert(result.dofByComponent.at("solo").remainingDof == 6);
        assert(!result.dofByComponent.at("solo").conflict);
        // Placement untouched.
        const Placement placement = document.componentById("solo").value().placement;
        assert(nearlyEqual(placement.translation, {1.0, 2.0, 3.0}, kTol));
    }

    return 0;
}
