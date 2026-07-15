// Source-part revision handling (spec §14): when the part topology changes
// between recomputes (a part was edited) references re-resolve — exact id
// → geometric-signature heuristic (with the stored id refreshed) → broken
// (joint flagged, placements preserved, никогда не привязывается к
// случайной грани). Headless: the topology provider swaps "revisions".
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::assembly;
namespace kernel = cadnext::kernel;

namespace {

constexpr double kTol = 1.0e-6;

// Cube top/bottom faces with a per-revision id suffix; a revision may drop
// the bottom face (simulating an edit that removed it).
PartTopology cubeTopology(const std::string& suffix, bool includeBottom) {
    PartTopology topology;

    kernel::FaceReference top;
    top.bodyId = "b";
    top.faceId = "face-top" + suffix;
    top.kind = kernel::FaceKind::Planar;
    top.origin = {0.0, 0.0, 0.5};
    top.normal = {0.0, 0.0, 1.0};
    top.uAxis = {1.0, 0.0, 0.0};
    top.vAxis = {0.0, 1.0, 0.0};
    top.area = 1.0;
    topology.faces.push_back(top);

    if (includeBottom) {
        kernel::FaceReference bottom = top;
        bottom.faceId = "face-bottom" + suffix;
        bottom.origin = {0.0, 0.0, -0.5};
        bottom.normal = {0.0, 0.0, -1.0};
        bottom.vAxis = {0.0, -1.0, 0.0};
        topology.faces.push_back(bottom);
    }
    return topology;
}

AssemblyComponent makeComponent(const std::string& id, bool grounded,
                                cadnext::Vector3 position) {
    AssemblyComponent component;
    component.id = id;
    component.name = id;
    component.source.kind = PartSourceKind::CadnextDocument;
    component.source.filePath = "/tmp/" + id + ".cadnext";
    component.isGrounded = grounded;
    component.placement.translation = position;
    return component;
}

void checkVector(const cadnext::Vector3& v, double x, double y, double z) {
    assert(nearlyEqual(v.x, x, kTol));
    assert(nearlyEqual(v.y, y, kTol));
    assert(nearlyEqual(v.z, z, kTol));
}

} // namespace

int main() {
    AssemblyDocument document;
    document.addComponent(makeComponent("a", true, {0.0, 0.0, 0.0}));
    document.addComponent(makeComponent("b", false, {5.0, 5.0, 5.0}));

    // Joint built against revision 1 topology (ids without suffix).
    PartTopology current = cubeTopology("", true);
    AssemblyJoint joint;
    joint.id = "joint-1";
    joint.name = "Coincident001";
    joint.type = JointType::Coincident;
    joint.alignment = JointAlignment::Opposed;
    joint.first = GeometryReferenceResolver::makeFaceReference({"a"}, current.faces[0]);
    joint.second = GeometryReferenceResolver::makeFaceReference({"b"}, current.faces[1]);
    document.addJoint(joint);

    const auto provider = [&current](const AssemblyComponent&) { return &current; };
    AssemblyRecomputeEngine engine;

    // --- Revision 1: exact resolve ------------------------------------------
    {
        const auto result = engine.recompute(document, provider);
        const AssemblyJoint solved = document.jointById("joint-1").value();
        assert(solved.solveState.status == JointSolveStatus::Solved);
        assert(solved.first.persistentTopologyId == "face-top");
        assert(solved.second.persistentTopologyId == "face-bottom");
        checkVector(document.componentById("b").value().placement.translation, 0.0, 0.0,
                    1.0);
        (void)result;
    }

    // --- Revision 2: part edited, ids changed but geometry preserved --------
    // Both references re-bind by signature → SolvedHeuristic; the stored
    // ids refresh to the new topology ids.
    current = cubeTopology("-v2", true);
    {
        const auto result = engine.recompute(document, provider);
        const AssemblyJoint solved = document.jointById("joint-1").value();
        assert(solved.solveState.status == JointSolveStatus::SolvedHeuristic);
        assert(solved.first.persistentTopologyId == "face-top-v2");
        assert(solved.second.persistentTopologyId == "face-bottom-v2");
        // Geometry unchanged → placement stays the same.
        checkVector(document.componentById("b").value().placement.translation, 0.0, 0.0,
                    1.0);
        (void)result;
    }

    // --- Revision 3: after re-bind, an exact match again --------------------
    // The stored id is now "-v2"; feeding the same topology resolves exact.
    {
        const auto result = engine.recompute(document, provider);
        const AssemblyJoint solved = document.jointById("joint-1").value();
        assert(solved.solveState.status == JointSolveStatus::Solved);
        (void)result;
    }

    // --- Revision 4: the mated face was deleted → broken --------------------
    current = cubeTopology("-v4", false); // no bottom face
    {
        const cadnext::Vector3 before =
            document.componentById("b").value().placement.translation;
        const auto result = engine.recompute(document, provider);
        const AssemblyJoint solved = document.jointById("joint-1").value();
        assert(solved.solveState.status == JointSolveStatus::Broken);
        // Broken joint never re-binds to another arbitrary face and never
        // moves the component: last correct placement is preserved.
        const cadnext::Vector3 after =
            document.componentById("b").value().placement.translation;
        checkVector(after, before.x, before.y, before.z);
        bool errored = false;
        for (const AssemblyDiagnostic& diagnostic : result.diagnostics) {
            errored = errored || diagnostic.severity == DiagnosticSeverity::Error;
        }
        assert(errored);
    }

    // --- Revision 5: the face reappears (part reverted) → recovers ----------
    current = cubeTopology("-v4", true);
    {
        const auto result = engine.recompute(document, provider);
        const AssemblyJoint solved = document.jointById("joint-1").value();
        // Re-bound heuristically to the restored face; joint recovers.
        assert(solved.solveState.status == JointSolveStatus::SolvedHeuristic ||
               solved.solveState.status == JointSolveStatus::Solved);
        assert(solved.second.persistentTopologyId == "face-bottom-v4");
        checkVector(document.componentById("b").value().placement.translation, 0.0, 0.0,
                    1.0);
        (void)result;
    }

    return 0;
}
