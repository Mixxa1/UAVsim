// AssemblyRecomputeEngine, direct path: reference resolution feeding the
// analytic solver, BFS from grounded anchors over a chain, no-ground
// warning, broken references and grounded immobility.
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"

#include <cassert>
#include <cmath>
#include <map>

using namespace cadnext::assembly;
namespace kernel = cadnext::kernel;

namespace {

constexpr double kTol = 1.0e-9;

// Unit cube topology: top and bottom faces only (enough for stacking).
PartTopology cubeTopology() {
    PartTopology topology;

    kernel::FaceReference top;
    top.bodyId = "body-1";
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

    return topology;
}

AssemblyComponent makeComponent(const std::string& id, const std::string& name) {
    AssemblyComponent component;
    component.id = id;
    component.name = name;
    component.source.kind = PartSourceKind::UavPart;
    component.source.filePath = "/tmp/" + id + ".uavpart";
    return component;
}

AssemblyJoint stackJoint(const std::string& id, const PartTopology& topology,
                         const std::string& lowerId, const std::string& upperId) {
    AssemblyJoint joint;
    joint.id = id;
    joint.name = id;
    joint.type = JointType::Coincident;
    joint.alignment = JointAlignment::Opposed;
    joint.first =
        GeometryReferenceResolver::makeFaceReference({lowerId}, topology.faces[0]);
    joint.second =
        GeometryReferenceResolver::makeFaceReference({upperId}, topology.faces[1]);
    return joint;
}

void checkVector(const cadnext::Vector3& v, double x, double y, double z,
                 double tolerance = kTol) {
    assert(nearlyEqual(v.x, x, tolerance));
    assert(nearlyEqual(v.y, y, tolerance));
    assert(nearlyEqual(v.z, z, tolerance));
}

} // namespace

int main() {
    const PartTopology topology = cubeTopology();
    const auto provider = [&topology](const AssemblyComponent&) { return &topology; };

    // --- Chain: grounded base + two stacked cubes solved through BFS ---------
    {
        AssemblyDocument document;
        AssemblyComponent base = makeComponent("comp-a", "Base");
        base.isGrounded = true;
        document.addComponent(base);
        AssemblyComponent middle = makeComponent("comp-b", "Middle");
        middle.placement.translation = {7.0, 7.0, 7.0};
        document.addComponent(middle);
        AssemblyComponent top = makeComponent("comp-c", "Top");
        top.placement.translation = {-3.0, 0.0, 2.0};
        document.addComponent(top);

        document.addJoint(stackJoint("joint-ab", topology, "comp-a", "comp-b"));
        document.addJoint(stackJoint("joint-bc", topology, "comp-b", "comp-c"));

        AssemblyRecomputeEngine engine;
        const auto result = engine.recompute(document, provider);

        assert(result.placementsChanged);
        checkVector(document.componentById("comp-a").value().placement.translation, 0.0,
                    0.0, 0.0);
        checkVector(document.componentById("comp-b").value().placement.translation, 0.0,
                    0.0, 1.0);
        checkVector(document.componentById("comp-c").value().placement.translation, 0.0,
                    0.0, 2.0);
        assert(document.jointById("joint-ab").value().solveState.status ==
               JointSolveStatus::Solved);
        assert(document.jointById("joint-bc").value().solveState.status ==
               JointSolveStatus::Solved);
        // Grounded group → no "no grounded base" warning.
        for (const AssemblyDiagnostic& diagnostic : result.diagnostics) {
            assert(diagnostic.severity != DiagnosticSeverity::Warning);
        }
        // DOF info: grounded component reports 0, group is anchored.
        assert(result.dofByComponent.at("comp-a").remainingDof == 0);
        assert(result.dofByComponent.at("comp-b").inGroundedGroup);
    }

    // --- No grounded base: warning, components still solve relative ----------
    {
        AssemblyDocument document;
        document.addComponent(makeComponent("comp-a", "Base"));
        AssemblyComponent second = makeComponent("comp-b", "Second");
        second.placement.translation = {4.0, 4.0, 4.0};
        document.addComponent(second);
        document.addJoint(stackJoint("joint-ab", topology, "comp-a", "comp-b"));

        AssemblyRecomputeEngine engine;
        const auto result = engine.recompute(document, provider);

        bool warned = false;
        for (const AssemblyDiagnostic& diagnostic : result.diagnostics) {
            warned = warned || diagnostic.severity == DiagnosticSeverity::Warning;
        }
        assert(warned);
        // The anchor keeps its placement; the other component mates to it.
        checkVector(document.componentById("comp-b").value().placement.translation, 0.0,
                    0.0, 1.0);
    }

    // --- Broken reference: joint marked broken, placements untouched ----------
    {
        AssemblyDocument document;
        AssemblyComponent base = makeComponent("comp-a", "Base");
        base.isGrounded = true;
        document.addComponent(base);
        AssemblyComponent floating = makeComponent("comp-b", "Floating");
        floating.placement.translation = {4.0, 4.0, 4.0};
        document.addComponent(floating);

        AssemblyJoint joint = stackJoint("joint-ab", topology, "comp-a", "comp-b");
        joint.first.persistentTopologyId = "face-DELETED";
        joint.first.signature.origin = {9.0, 9.0, 9.0}; // far from any candidate
        document.addJoint(joint);

        AssemblyRecomputeEngine engine;
        const auto result = engine.recompute(document, provider);

        assert(document.jointById("joint-ab").value().solveState.status ==
               JointSolveStatus::Broken);
        checkVector(document.componentById("comp-b").value().placement.translation, 4.0,
                    4.0, 4.0);
        bool errored = false;
        for (const AssemblyDiagnostic& diagnostic : result.diagnostics) {
            errored = errored || diagnostic.severity == DiagnosticSeverity::Error;
        }
        assert(errored);
    }

    // --- Grounded components never move, even as the joint child --------------
    {
        AssemblyDocument document;
        AssemblyComponent base = makeComponent("comp-a", "Base");
        base.isGrounded = true;
        document.addComponent(base);
        AssemblyComponent alsoGrounded = makeComponent("comp-b", "AlsoGrounded");
        alsoGrounded.isGrounded = true;
        alsoGrounded.placement.translation = {4.0, 4.0, 4.0};
        document.addComponent(alsoGrounded);
        document.addJoint(stackJoint("joint-ab", topology, "comp-a", "comp-b"));

        AssemblyRecomputeEngine engine;
        engine.recompute(document, provider);
        checkVector(document.componentById("comp-b").value().placement.translation, 4.0,
                    4.0, 4.0);
    }

    // --- Heuristic re-bind survives into the solve state ----------------------
    {
        AssemblyDocument document;
        AssemblyComponent base = makeComponent("comp-a", "Base");
        base.isGrounded = true;
        document.addComponent(base);
        AssemblyComponent second = makeComponent("comp-b", "Second");
        document.addComponent(second);

        AssemblyJoint joint = stackJoint("joint-ab", topology, "comp-a", "comp-b");
        joint.first.persistentTopologyId = "face-top-STALE"; // геометрия совпадает
        document.addJoint(joint);

        AssemblyRecomputeEngine engine;
        engine.recompute(document, provider);
        const AssemblyJoint restored = document.jointById("joint-ab").value();
        assert(restored.solveState.status == JointSolveStatus::SolvedHeuristic);
        // The reference id was refreshed to the re-bound element.
        assert(restored.first.persistentTopologyId == "face-top");
    }

    return 0;
}
