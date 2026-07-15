#pragma once

#include <string>
#include <vector>

#include "cadnext/Result.hpp"
#include "cadnext/assembly/AssemblyMath.hpp"

namespace cadnext::assembly {

// ---------------------------------------------------------------------------
// Part reference — a component links to its source file, never copies the
// geometry (App::Link semantics: one wing file → Left Wing placement A +
// Right Wing placement B).
// ---------------------------------------------------------------------------

enum class PartSourceKind {
    CadnextDocument, // .cadnext (parametric part document)
    UavPart,         // .uavpart (exact BRep payload)
    Assembly         // .cadasm (subassembly, treated as one rigid component)
};

struct PartReference {
    PartSourceKind kind = PartSourceKind::UavPart;

    // Absolute path at runtime. The serializer stores the path relative
    // to the assembly file next to this absolute fallback.
    std::string filePath;

    // Body inside the part document; empty means "the only/first body".
    std::string bodyId;

    // FNV-1a64 of the source file bytes when the geometry was last
    // bound — drives the "source part changed, re-resolve references"
    // detection (assembly spec §14).
    std::string contentHash;

    int expectedRevision = 0;
};

// ---------------------------------------------------------------------------
// Geometry references — joints reference CAD topology (faces / edges /
// vertices / LCS), never attachment points, SCNNode names or triangle
// indices.
// ---------------------------------------------------------------------------

enum class GeometryReferenceKind {
    PlanarFace,
    CylindricalFace,
    LinearEdge,
    CircularEdge,
    Vertex,
    LocalCoordinateSystem
};

// Local-space (part frame) geometric signature used to re-resolve a
// reference heuristically when the persistent topology id no longer
// exists after a part edit.
struct GeometrySignature {
    Vector3 origin;    // center point of the element
    Vector3 direction; // unit normal (faces) or axis (edges/cylinders); zero for vertices
    double area = 0.0;   // planar faces
    double radius = 0.0; // circles / cylinders
    double length = 0.0; // edges
};

struct GeometryReference {
    GeometryReferenceKind kind = GeometryReferenceKind::PlanarFace;

    // Component the element belongs to. One entry for a direct component;
    // subassemblies prepend their component id (outer → inner).
    std::vector<std::string> componentPath;

    std::string bodyId;

    // faceId / edgeId / vertexId from the kernel analyzers; empty for
    // LocalCoordinateSystem (the component's own origin frame).
    std::string persistentTopologyId;

    GeometrySignature signature;

    // Last successfully resolved local frame (part space). Kept as the
    // display/solve fallback when the id cannot be re-resolved.
    Frame fallbackFrame;
};

// ---------------------------------------------------------------------------
// Joints
// ---------------------------------------------------------------------------

enum class JointType {
    Coincident,
    Parallel,
    Perpendicular,
    Concentric,
    Distance,
    Angle,
    Rigid
};

enum class JointAlignment {
    Aligned,
    Opposed
};

enum class JointSolveStatus {
    Unsolved,
    Solved,
    SolvedHeuristic, // solved, but a reference was re-bound by signature
    Broken,          // a reference could not be resolved; joint skipped
    Conflict         // solver could not satisfy the constraint system
};

struct JointSolveState {
    JointSolveStatus status = JointSolveStatus::Unsolved;
    std::string message;
};

struct AssemblyJoint {
    std::string id;
    std::string name;

    JointType type = JointType::Coincident;

    GeometryReference first;
    GeometryReference second;

    JointAlignment alignment = JointAlignment::Aligned;
    double offsetMeters = 0.0;
    double angleRadians = 0.0;
    bool lockRotation = false;
    bool isEnabled = true;

    // Rigid joints only: the relative placement of the second component in
    // the first component's frame, captured when the joint was created —
    // "fix the mutual position as currently placed". Without a capture a
    // rigid joint aligns the two reference frames instead.
    bool hasCapturedRelativePlacement = false;
    Placement capturedRelativePlacement;

    JointSolveState solveState;
};

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

struct AssemblyComponent {
    std::string id;
    std::string name;

    PartReference source;
    Placement placement;

    // Grounded means translation/rotation are solver constants (DOF = 0)
    // and the component anchors its connectivity group.
    bool isGrounded = false;
    bool isVisible = true;
    bool isSuppressed = false;
};

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

enum class DiagnosticSeverity {
    Info,
    Warning,
    Error
};

struct AssemblyDiagnostic {
    DiagnosticSeverity severity = DiagnosticSeverity::Info;
    std::string message;
    // Optional anchors for the UI.
    std::string componentId;
    std::string jointId;
};

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

class AssemblyDocument {
public:
    AssemblyDocument();

    const std::string& id() const;
    void setId(std::string id);
    const std::string& name() const;
    void setName(std::string name);

    int revision() const;
    void setRevision(int revision);
    void bumpRevision();

    void addComponent(AssemblyComponent component);
    bool removeComponent(const std::string& componentId);
    Result<AssemblyComponent> componentById(const std::string& componentId) const;
    AssemblyComponent* mutableComponentById(const std::string& componentId);
    const std::vector<AssemblyComponent>& components() const;

    // Removing a component also removes every joint referencing it.
    void addJoint(AssemblyJoint joint);
    bool removeJoint(const std::string& jointId);
    Result<AssemblyJoint> jointById(const std::string& jointId) const;
    AssemblyJoint* mutableJointById(const std::string& jointId);
    const std::vector<AssemblyJoint>& joints() const;

    // Joints whose either side belongs to the component.
    std::vector<const AssemblyJoint*> jointsForComponent(const std::string& componentId) const;

    const std::string& selectedComponentId() const;
    void setSelectedComponentId(std::string componentId);
    const std::string& selectedJointId() const;
    void setSelectedJointId(std::string jointId);

    // Transient recompute output; regenerated by every recompute, never
    // serialized.
    const std::vector<AssemblyDiagnostic>& diagnostics() const;
    void setDiagnostics(std::vector<AssemblyDiagnostic> diagnostics);

private:
    std::string id_;
    std::string name_;
    int revision_ = 0;
    std::vector<AssemblyComponent> components_;
    std::vector<AssemblyJoint> joints_;
    std::string selectedComponentId_;
    std::string selectedJointId_;
    std::vector<AssemblyDiagnostic> diagnostics_;
};

// Serialization names (stable .cadasm strings).
const char* partSourceKindName(PartSourceKind kind);
PartSourceKind partSourceKindFromName(const std::string& name);
const char* geometryReferenceKindName(GeometryReferenceKind kind);
GeometryReferenceKind geometryReferenceKindFromName(const std::string& name);
const char* jointTypeName(JointType type);
JointType jointTypeFromName(const std::string& name);
const char* jointAlignmentName(JointAlignment alignment);
JointAlignment jointAlignmentFromName(const std::string& name);
const char* jointSolveStatusName(JointSolveStatus status);
JointSolveStatus jointSolveStatusFromName(const std::string& name);

// True when the reference's outermost component is `componentId`.
bool referenceTargetsComponent(const GeometryReference& reference,
                               const std::string& componentId);

} // namespace cadnext::assembly
