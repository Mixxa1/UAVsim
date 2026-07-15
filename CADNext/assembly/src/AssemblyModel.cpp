#include "cadnext/assembly/AssemblyModel.hpp"

#include <algorithm>

namespace cadnext::assembly {

AssemblyDocument::AssemblyDocument() = default;

const std::string& AssemblyDocument::id() const {
    return id_;
}

void AssemblyDocument::setId(std::string id) {
    id_ = std::move(id);
}

const std::string& AssemblyDocument::name() const {
    return name_;
}

void AssemblyDocument::setName(std::string name) {
    name_ = std::move(name);
}

int AssemblyDocument::revision() const {
    return revision_;
}

void AssemblyDocument::setRevision(int revision) {
    revision_ = revision;
}

void AssemblyDocument::bumpRevision() {
    ++revision_;
}

void AssemblyDocument::addComponent(AssemblyComponent component) {
    components_.push_back(std::move(component));
}

bool AssemblyDocument::removeComponent(const std::string& componentId) {
    const auto it = std::find_if(components_.begin(), components_.end(),
                                 [&componentId](const AssemblyComponent& component) {
                                     return component.id == componentId;
                                 });
    if (it == components_.end()) {
        return false;
    }
    components_.erase(it);
    joints_.erase(std::remove_if(joints_.begin(), joints_.end(),
                                 [&componentId](const AssemblyJoint& joint) {
                                     return referenceTargetsComponent(joint.first,
                                                                      componentId) ||
                                            referenceTargetsComponent(joint.second,
                                                                      componentId);
                                 }),
                  joints_.end());
    if (selectedComponentId_ == componentId) {
        selectedComponentId_.clear();
    }
    return true;
}

Result<AssemblyComponent> AssemblyDocument::componentById(const std::string& componentId) const {
    for (const AssemblyComponent& component : components_) {
        if (component.id == componentId) {
            return Result<AssemblyComponent>::ok(component);
        }
    }
    return Result<AssemblyComponent>::fail(
        {ErrorCode::NotFound, "Component not found: " + componentId});
}

AssemblyComponent* AssemblyDocument::mutableComponentById(const std::string& componentId) {
    for (AssemblyComponent& component : components_) {
        if (component.id == componentId) {
            return &component;
        }
    }
    return nullptr;
}

const std::vector<AssemblyComponent>& AssemblyDocument::components() const {
    return components_;
}

void AssemblyDocument::addJoint(AssemblyJoint joint) {
    joints_.push_back(std::move(joint));
}

bool AssemblyDocument::removeJoint(const std::string& jointId) {
    const auto it = std::find_if(joints_.begin(), joints_.end(),
                                 [&jointId](const AssemblyJoint& joint) {
                                     return joint.id == jointId;
                                 });
    if (it == joints_.end()) {
        return false;
    }
    joints_.erase(it);
    if (selectedJointId_ == jointId) {
        selectedJointId_.clear();
    }
    return true;
}

Result<AssemblyJoint> AssemblyDocument::jointById(const std::string& jointId) const {
    for (const AssemblyJoint& joint : joints_) {
        if (joint.id == jointId) {
            return Result<AssemblyJoint>::ok(joint);
        }
    }
    return Result<AssemblyJoint>::fail({ErrorCode::NotFound, "Joint not found: " + jointId});
}

AssemblyJoint* AssemblyDocument::mutableJointById(const std::string& jointId) {
    for (AssemblyJoint& joint : joints_) {
        if (joint.id == jointId) {
            return &joint;
        }
    }
    return nullptr;
}

const std::vector<AssemblyJoint>& AssemblyDocument::joints() const {
    return joints_;
}

std::vector<const AssemblyJoint*> AssemblyDocument::jointsForComponent(
    const std::string& componentId) const {
    std::vector<const AssemblyJoint*> result;
    for (const AssemblyJoint& joint : joints_) {
        if (referenceTargetsComponent(joint.first, componentId) ||
            referenceTargetsComponent(joint.second, componentId)) {
            result.push_back(&joint);
        }
    }
    return result;
}

const std::string& AssemblyDocument::selectedComponentId() const {
    return selectedComponentId_;
}

void AssemblyDocument::setSelectedComponentId(std::string componentId) {
    selectedComponentId_ = std::move(componentId);
}

const std::string& AssemblyDocument::selectedJointId() const {
    return selectedJointId_;
}

void AssemblyDocument::setSelectedJointId(std::string jointId) {
    selectedJointId_ = std::move(jointId);
}

const std::vector<AssemblyDiagnostic>& AssemblyDocument::diagnostics() const {
    return diagnostics_;
}

void AssemblyDocument::setDiagnostics(std::vector<AssemblyDiagnostic> diagnostics) {
    diagnostics_ = std::move(diagnostics);
}

const char* partSourceKindName(PartSourceKind kind) {
    switch (kind) {
    case PartSourceKind::CadnextDocument: return "cadnext";
    case PartSourceKind::UavPart: return "uavpart";
    case PartSourceKind::Assembly: return "assembly";
    }
    return "uavpart";
}

PartSourceKind partSourceKindFromName(const std::string& name) {
    if (name == "cadnext") {
        return PartSourceKind::CadnextDocument;
    }
    if (name == "assembly") {
        return PartSourceKind::Assembly;
    }
    return PartSourceKind::UavPart;
}

const char* geometryReferenceKindName(GeometryReferenceKind kind) {
    switch (kind) {
    case GeometryReferenceKind::PlanarFace: return "planarFace";
    case GeometryReferenceKind::CylindricalFace: return "cylindricalFace";
    case GeometryReferenceKind::LinearEdge: return "linearEdge";
    case GeometryReferenceKind::CircularEdge: return "circularEdge";
    case GeometryReferenceKind::Vertex: return "vertex";
    case GeometryReferenceKind::LocalCoordinateSystem: return "lcs";
    }
    return "planarFace";
}

GeometryReferenceKind geometryReferenceKindFromName(const std::string& name) {
    if (name == "cylindricalFace") {
        return GeometryReferenceKind::CylindricalFace;
    }
    if (name == "linearEdge") {
        return GeometryReferenceKind::LinearEdge;
    }
    if (name == "circularEdge") {
        return GeometryReferenceKind::CircularEdge;
    }
    if (name == "vertex") {
        return GeometryReferenceKind::Vertex;
    }
    if (name == "lcs") {
        return GeometryReferenceKind::LocalCoordinateSystem;
    }
    return GeometryReferenceKind::PlanarFace;
}

const char* jointTypeName(JointType type) {
    switch (type) {
    case JointType::Coincident: return "coincident";
    case JointType::Parallel: return "parallel";
    case JointType::Perpendicular: return "perpendicular";
    case JointType::Concentric: return "concentric";
    case JointType::Distance: return "distance";
    case JointType::Angle: return "angle";
    case JointType::Rigid: return "rigid";
    }
    return "coincident";
}

JointType jointTypeFromName(const std::string& name) {
    if (name == "parallel") {
        return JointType::Parallel;
    }
    if (name == "perpendicular") {
        return JointType::Perpendicular;
    }
    if (name == "concentric") {
        return JointType::Concentric;
    }
    if (name == "distance") {
        return JointType::Distance;
    }
    if (name == "angle") {
        return JointType::Angle;
    }
    if (name == "rigid") {
        return JointType::Rigid;
    }
    return JointType::Coincident;
}

const char* jointAlignmentName(JointAlignment alignment) {
    return alignment == JointAlignment::Opposed ? "opposed" : "aligned";
}

JointAlignment jointAlignmentFromName(const std::string& name) {
    return name == "opposed" ? JointAlignment::Opposed : JointAlignment::Aligned;
}

const char* jointSolveStatusName(JointSolveStatus status) {
    switch (status) {
    case JointSolveStatus::Unsolved: return "unsolved";
    case JointSolveStatus::Solved: return "solved";
    case JointSolveStatus::SolvedHeuristic: return "solvedHeuristic";
    case JointSolveStatus::Broken: return "broken";
    case JointSolveStatus::Conflict: return "conflict";
    }
    return "unsolved";
}

JointSolveStatus jointSolveStatusFromName(const std::string& name) {
    if (name == "solved") {
        return JointSolveStatus::Solved;
    }
    if (name == "solvedHeuristic") {
        return JointSolveStatus::SolvedHeuristic;
    }
    if (name == "broken") {
        return JointSolveStatus::Broken;
    }
    if (name == "conflict") {
        return JointSolveStatus::Conflict;
    }
    return JointSolveStatus::Unsolved;
}

bool referenceTargetsComponent(const GeometryReference& reference,
                               const std::string& componentId) {
    return !reference.componentPath.empty() && reference.componentPath.front() == componentId;
}

} // namespace cadnext::assembly
