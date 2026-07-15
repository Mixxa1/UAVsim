// .cadasm round-trip: components (links + placements + flags), joints
// (references with signatures and fallback frames, solve states) and
// document metadata survive toJson/fromJson unchanged.
#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/assembly/AssemblySerializer.hpp"

#include <cassert>
#include <cmath>

using namespace cadnext::assembly;

namespace {

constexpr double kTol = 1.0e-12;

GeometryReference sampleReference() {
    GeometryReference reference;
    reference.kind = GeometryReferenceKind::CircularEdge;
    reference.componentPath = {"component-1", "inner-2"};
    reference.bodyId = "body-9";
    reference.persistentTopologyId = "edge-4-sabc-edef-l123";
    reference.signature.origin = {0.1, -0.2, 0.3};
    reference.signature.direction = {0.0, 0.0, 1.0};
    reference.signature.radius = 0.05;
    reference.signature.length = 0.314;
    reference.fallbackFrame = Frame::fromOriginZX({0.1, -0.2, 0.3}, {0.0, 0.0, 1.0},
                                                  {1.0, 0.0, 0.0});
    return reference;
}

void checkVector(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    assert(nearlyEqual(a, b, kTol));
}

} // namespace

int main() {
    AssemblyDocument document;
    document.setId("assembly-42");
    document.setName("Recon Airframe");
    document.setRevision(7);

    AssemblyComponent fuselage;
    fuselage.id = "component-1";
    fuselage.name = "Fuselage";
    fuselage.source.kind = PartSourceKind::UavPart;
    fuselage.source.filePath = "/tmp/parts/fuselage.uavpart";
    fuselage.source.bodyId = "body-1";
    fuselage.source.contentHash = "00ff00ff00ff00ff";
    fuselage.source.expectedRevision = 3;
    fuselage.isGrounded = true;
    document.addComponent(fuselage);

    AssemblyComponent wing;
    wing.id = "component-2";
    wing.name = "Left Wing";
    wing.source.kind = PartSourceKind::CadnextDocument;
    wing.source.filePath = "/tmp/parts/wing.cadnext";
    wing.placement.translation = {1.5, -0.25, 0.75};
    wing.placement.rotation =
        Quaternion::fromAxisAngle({0.0, 1.0, 0.0}, 0.3).normalized();
    wing.isVisible = false;
    wing.isSuppressed = true;
    document.addComponent(wing);

    AssemblyJoint joint;
    joint.id = "joint-1";
    joint.name = "Concentric001";
    joint.type = JointType::Concentric;
    joint.first = sampleReference();
    joint.second = sampleReference();
    joint.second.componentPath = {"component-2"};
    joint.alignment = JointAlignment::Opposed;
    joint.offsetMeters = 0.01;
    joint.angleRadians = 0.5;
    joint.lockRotation = true;
    joint.isEnabled = false;
    joint.solveState.status = JointSolveStatus::SolvedHeuristic;
    joint.solveState.message = "re-bound";
    document.addJoint(joint);

    document.setSelectedComponentId("component-2");
    document.setSelectedJointId("joint-1");

    const std::string jsonText = AssemblySerializer::toJson(document);
    const auto loaded = AssemblySerializer::fromJson(jsonText);
    assert(loaded.isOk());
    const AssemblyDocument& restored = loaded.value();

    assert(restored.id() == "assembly-42");
    assert(restored.name() == "Recon Airframe");
    assert(restored.revision() == 7);
    assert(restored.components().size() == 2);
    assert(restored.joints().size() == 1);
    assert(restored.selectedComponentId() == "component-2");
    assert(restored.selectedJointId() == "joint-1");

    const AssemblyComponent& restoredFuselage = restored.components()[0];
    assert(restoredFuselage.id == "component-1");
    assert(restoredFuselage.name == "Fuselage");
    assert(restoredFuselage.source.kind == PartSourceKind::UavPart);
    assert(restoredFuselage.source.filePath == "/tmp/parts/fuselage.uavpart");
    assert(restoredFuselage.source.bodyId == "body-1");
    assert(restoredFuselage.source.contentHash == "00ff00ff00ff00ff");
    assert(restoredFuselage.source.expectedRevision == 3);
    assert(restoredFuselage.isGrounded);
    assert(restoredFuselage.isVisible);
    assert(!restoredFuselage.isSuppressed);

    const AssemblyComponent& restoredWing = restored.components()[1];
    assert(restoredWing.source.kind == PartSourceKind::CadnextDocument);
    checkVector(restoredWing.placement.translation, wing.placement.translation);
    assert(nearlyEqual(restoredWing.placement.rotation.x, wing.placement.rotation.x, kTol));
    assert(nearlyEqual(restoredWing.placement.rotation.w, wing.placement.rotation.w, kTol));
    assert(!restoredWing.isVisible);
    assert(restoredWing.isSuppressed);

    const AssemblyJoint& restoredJoint = restored.joints()[0];
    assert(restoredJoint.type == JointType::Concentric);
    assert(restoredJoint.alignment == JointAlignment::Opposed);
    assert(nearlyEqual(restoredJoint.offsetMeters, 0.01, kTol));
    assert(nearlyEqual(restoredJoint.angleRadians, 0.5, kTol));
    assert(restoredJoint.lockRotation);
    assert(!restoredJoint.isEnabled);
    assert(restoredJoint.solveState.status == JointSolveStatus::SolvedHeuristic);
    assert(restoredJoint.solveState.message == "re-bound");

    const GeometryReference& restoredRef = restoredJoint.first;
    assert(restoredRef.kind == GeometryReferenceKind::CircularEdge);
    assert(restoredRef.componentPath.size() == 2);
    assert(restoredRef.componentPath[0] == "component-1");
    assert(restoredRef.componentPath[1] == "inner-2");
    assert(restoredRef.bodyId == "body-9");
    assert(restoredRef.persistentTopologyId == "edge-4-sabc-edef-l123");
    checkVector(restoredRef.signature.origin, {0.1, -0.2, 0.3});
    assert(nearlyEqual(restoredRef.signature.radius, 0.05, kTol));
    assert(nearlyEqual(restoredRef.signature.length, 0.314, kTol));
    checkVector(restoredRef.fallbackFrame.origin, {0.1, -0.2, 0.3});
    assert(nearlyEqual(length(restoredRef.fallbackFrame.xAxis), 1.0, 1.0e-9));

    // Component removal drops dependent joints.
    AssemblyDocument mutating = restored;
    assert(mutating.removeComponent("component-2"));
    assert(mutating.components().size() == 1);
    assert(mutating.joints().empty());

    // Unknown format / newer version fail cleanly.
    assert(!AssemblySerializer::fromJson("{}").isOk());
    assert(!AssemblySerializer::fromJson(
                "{\"format\":\"cadasm\",\"version\":99}")
                .isOk());

    return 0;
}
