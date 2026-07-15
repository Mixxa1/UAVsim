#include "cadnext/assembly/AssemblySerializer.hpp"

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "AssemblyJson.hpp"

namespace cadnext::assembly {

namespace {

using json::JsonValue;

JsonValue vectorToJson(const Vector3& v) {
    JsonValue object = JsonValue::makeObject();
    object.set("x", JsonValue::makeNumber(v.x));
    object.set("y", JsonValue::makeNumber(v.y));
    object.set("z", JsonValue::makeNumber(v.z));
    return object;
}

Vector3 vectorFromJson(const JsonValue* value) {
    Vector3 v;
    if (value && value->isObject()) {
        v.x = value->numberOr("x", 0.0);
        v.y = value->numberOr("y", 0.0);
        v.z = value->numberOr("z", 0.0);
    }
    return v;
}

JsonValue placementToJson(const Placement& placement) {
    JsonValue object = JsonValue::makeObject();
    object.set("tx", JsonValue::makeNumber(placement.translation.x));
    object.set("ty", JsonValue::makeNumber(placement.translation.y));
    object.set("tz", JsonValue::makeNumber(placement.translation.z));
    object.set("qx", JsonValue::makeNumber(placement.rotation.x));
    object.set("qy", JsonValue::makeNumber(placement.rotation.y));
    object.set("qz", JsonValue::makeNumber(placement.rotation.z));
    object.set("qw", JsonValue::makeNumber(placement.rotation.w));
    return object;
}

Placement placementFromJson(const JsonValue* value) {
    Placement placement;
    if (value && value->isObject()) {
        placement.translation = {value->numberOr("tx", 0.0), value->numberOr("ty", 0.0),
                                 value->numberOr("tz", 0.0)};
        placement.rotation = {value->numberOr("qx", 0.0), value->numberOr("qy", 0.0),
                              value->numberOr("qz", 0.0), value->numberOr("qw", 1.0)};
        placement.rotation = placement.rotation.normalized();
    }
    return placement;
}

JsonValue frameToJson(const Frame& frame) {
    JsonValue object = JsonValue::makeObject();
    object.set("origin", vectorToJson(frame.origin));
    object.set("xAxis", vectorToJson(frame.xAxis));
    object.set("yAxis", vectorToJson(frame.yAxis));
    object.set("zAxis", vectorToJson(frame.zAxis));
    return object;
}

Frame frameFromJson(const JsonValue* value) {
    Frame frame = Frame::identity();
    if (value && value->isObject()) {
        frame.origin = vectorFromJson(value->member("origin"));
        frame.xAxis = vectorFromJson(value->member("xAxis"));
        frame.yAxis = vectorFromJson(value->member("yAxis"));
        frame.zAxis = vectorFromJson(value->member("zAxis"));
    }
    return frame;
}

JsonValue signatureToJson(const GeometrySignature& signature) {
    JsonValue object = JsonValue::makeObject();
    object.set("origin", vectorToJson(signature.origin));
    object.set("direction", vectorToJson(signature.direction));
    object.set("area", JsonValue::makeNumber(signature.area));
    object.set("radius", JsonValue::makeNumber(signature.radius));
    object.set("length", JsonValue::makeNumber(signature.length));
    return object;
}

GeometrySignature signatureFromJson(const JsonValue* value) {
    GeometrySignature signature;
    if (value && value->isObject()) {
        signature.origin = vectorFromJson(value->member("origin"));
        signature.direction = vectorFromJson(value->member("direction"));
        signature.area = value->numberOr("area", 0.0);
        signature.radius = value->numberOr("radius", 0.0);
        signature.length = value->numberOr("length", 0.0);
    }
    return signature;
}

JsonValue referenceToJson(const GeometryReference& reference) {
    JsonValue object = JsonValue::makeObject();
    object.set("kind", JsonValue::makeString(geometryReferenceKindName(reference.kind)));
    JsonValue path = JsonValue::makeArray();
    for (const std::string& componentId : reference.componentPath) {
        path.arrayItems.push_back(JsonValue::makeString(componentId));
    }
    object.set("componentPath", std::move(path));
    object.set("bodyId", JsonValue::makeString(reference.bodyId));
    object.set("topologyId", JsonValue::makeString(reference.persistentTopologyId));
    object.set("signature", signatureToJson(reference.signature));
    object.set("fallbackFrame", frameToJson(reference.fallbackFrame));
    return object;
}

GeometryReference referenceFromJson(const JsonValue* value) {
    GeometryReference reference;
    if (!value || !value->isObject()) {
        return reference;
    }
    reference.kind = geometryReferenceKindFromName(value->stringOr("kind", "planarFace"));
    if (const JsonValue* path = value->member("componentPath"); path && path->isArray()) {
        for (const JsonValue& item : path->arrayItems) {
            if (item.type == JsonValue::Type::String) {
                reference.componentPath.push_back(item.stringValue);
            }
        }
    }
    reference.bodyId = value->stringOr("bodyId", "");
    reference.persistentTopologyId = value->stringOr("topologyId", "");
    reference.signature = signatureFromJson(value->member("signature"));
    reference.fallbackFrame = frameFromJson(value->member("fallbackFrame"));
    return reference;
}

std::string relativeSourcePath(const std::string& sourcePath,
                               const std::string& assemblyFilePath) {
    if (assemblyFilePath.empty() || sourcePath.empty()) {
        return std::string();
    }
    std::error_code ec;
    const std::filesystem::path base =
        std::filesystem::path(assemblyFilePath).parent_path();
    const std::filesystem::path relative =
        std::filesystem::relative(sourcePath, base, ec);
    if (ec || relative.empty()) {
        return std::string();
    }
    return relative.generic_string();
}

std::string resolveSourcePath(const std::string& relativePath,
                              const std::string& absolutePath,
                              const std::string& assemblyFilePath) {
    if (!relativePath.empty() && !assemblyFilePath.empty()) {
        const std::filesystem::path resolved =
            std::filesystem::path(assemblyFilePath).parent_path() / relativePath;
        std::error_code ec;
        if (std::filesystem::exists(resolved, ec)) {
            return std::filesystem::weakly_canonical(resolved, ec).string();
        }
    }
    return absolutePath;
}

JsonValue componentToJson(const AssemblyComponent& component,
                          const std::string& assemblyFilePath) {
    JsonValue object = JsonValue::makeObject();
    object.set("id", JsonValue::makeString(component.id));
    object.set("name", JsonValue::makeString(component.name));

    JsonValue source = JsonValue::makeObject();
    source.set("kind", JsonValue::makeString(partSourceKindName(component.source.kind)));
    source.set("relativePath", JsonValue::makeString(relativeSourcePath(
                                   component.source.filePath, assemblyFilePath)));
    source.set("absolutePath", JsonValue::makeString(component.source.filePath));
    source.set("bodyId", JsonValue::makeString(component.source.bodyId));
    source.set("contentHash", JsonValue::makeString(component.source.contentHash));
    source.set("expectedRevision",
               JsonValue::makeNumber(component.source.expectedRevision));
    object.set("source", std::move(source));

    object.set("placement", placementToJson(component.placement));
    object.set("grounded", JsonValue::makeBool(component.isGrounded));
    object.set("visible", JsonValue::makeBool(component.isVisible));
    object.set("suppressed", JsonValue::makeBool(component.isSuppressed));
    return object;
}

AssemblyComponent componentFromJson(const JsonValue& value,
                                    const std::string& assemblyFilePath) {
    AssemblyComponent component;
    component.id = value.stringOr("id", "");
    component.name = value.stringOr("name", "");
    if (const JsonValue* source = value.member("source"); source && source->isObject()) {
        component.source.kind =
            partSourceKindFromName(source->stringOr("kind", "uavpart"));
        component.source.filePath =
            resolveSourcePath(source->stringOr("relativePath", ""),
                              source->stringOr("absolutePath", ""), assemblyFilePath);
        component.source.bodyId = source->stringOr("bodyId", "");
        component.source.contentHash = source->stringOr("contentHash", "");
        component.source.expectedRevision =
            static_cast<int>(source->numberOr("expectedRevision", 0.0));
    }
    component.placement = placementFromJson(value.member("placement"));
    component.isGrounded = value.boolOr("grounded", false);
    component.isVisible = value.boolOr("visible", true);
    component.isSuppressed = value.boolOr("suppressed", false);
    return component;
}

JsonValue jointToJson(const AssemblyJoint& joint) {
    JsonValue object = JsonValue::makeObject();
    object.set("id", JsonValue::makeString(joint.id));
    object.set("name", JsonValue::makeString(joint.name));
    object.set("type", JsonValue::makeString(jointTypeName(joint.type)));
    object.set("first", referenceToJson(joint.first));
    object.set("second", referenceToJson(joint.second));
    object.set("alignment", JsonValue::makeString(jointAlignmentName(joint.alignment)));
    object.set("offsetMeters", JsonValue::makeNumber(joint.offsetMeters));
    object.set("angleRadians", JsonValue::makeNumber(joint.angleRadians));
    object.set("lockRotation", JsonValue::makeBool(joint.lockRotation));
    object.set("enabled", JsonValue::makeBool(joint.isEnabled));
    if (joint.hasCapturedRelativePlacement) {
        object.set("capturedRelativePlacement",
                   placementToJson(joint.capturedRelativePlacement));
    }

    JsonValue solveState = JsonValue::makeObject();
    solveState.set("status",
                   JsonValue::makeString(jointSolveStatusName(joint.solveState.status)));
    solveState.set("message", JsonValue::makeString(joint.solveState.message));
    object.set("solveState", std::move(solveState));
    return object;
}

AssemblyJoint jointFromJson(const JsonValue& value) {
    AssemblyJoint joint;
    joint.id = value.stringOr("id", "");
    joint.name = value.stringOr("name", "");
    joint.type = jointTypeFromName(value.stringOr("type", "coincident"));
    joint.first = referenceFromJson(value.member("first"));
    joint.second = referenceFromJson(value.member("second"));
    joint.alignment = jointAlignmentFromName(value.stringOr("alignment", "aligned"));
    joint.offsetMeters = value.numberOr("offsetMeters", 0.0);
    joint.angleRadians = value.numberOr("angleRadians", 0.0);
    joint.lockRotation = value.boolOr("lockRotation", false);
    joint.isEnabled = value.boolOr("enabled", true);
    if (const JsonValue* captured = value.member("capturedRelativePlacement")) {
        joint.hasCapturedRelativePlacement = true;
        joint.capturedRelativePlacement = placementFromJson(captured);
    }
    if (const JsonValue* solveState = value.member("solveState");
        solveState && solveState->isObject()) {
        joint.solveState.status =
            jointSolveStatusFromName(solveState->stringOr("status", "unsolved"));
        joint.solveState.message = solveState->stringOr("message", "");
    }
    return joint;
}

} // namespace

std::string AssemblySerializer::toJson(const AssemblyDocument& document,
                                       const std::string& assemblyFilePath) {
    JsonValue root = JsonValue::makeObject();
    root.set("format", JsonValue::makeString("cadasm"));
    root.set("version", JsonValue::makeNumber(kFormatVersion));
    root.set("id", JsonValue::makeString(document.id()));
    root.set("name", JsonValue::makeString(document.name()));
    root.set("revision", JsonValue::makeNumber(document.revision()));

    JsonValue components = JsonValue::makeArray();
    for (const AssemblyComponent& component : document.components()) {
        components.arrayItems.push_back(componentToJson(component, assemblyFilePath));
    }
    root.set("components", std::move(components));

    JsonValue joints = JsonValue::makeArray();
    for (const AssemblyJoint& joint : document.joints()) {
        joints.arrayItems.push_back(jointToJson(joint));
    }
    root.set("joints", std::move(joints));

    root.set("selectedComponentId", JsonValue::makeString(document.selectedComponentId()));
    root.set("selectedJointId", JsonValue::makeString(document.selectedJointId()));
    return root.serialize();
}

Result<AssemblyDocument> AssemblySerializer::fromJson(const std::string& jsonText,
                                                      const std::string& assemblyFilePath) {
    JsonValue root;
    std::string error;
    if (!json::parseJson(jsonText, root, error)) {
        return Result<AssemblyDocument>::fail(
            {ErrorCode::SerializationFailed, "Invalid .cadasm JSON: " + error});
    }
    if (!root.isObject() || root.stringOr("format", "") != "cadasm") {
        return Result<AssemblyDocument>::fail(
            {ErrorCode::SerializationFailed, "Not a .cadasm document"});
    }
    const int version = static_cast<int>(root.numberOr("version", 0.0));
    if (version <= 0 || version > kFormatVersion) {
        return Result<AssemblyDocument>::fail(
            {ErrorCode::SerializationFailed,
             "Unsupported .cadasm version: " + std::to_string(version)});
    }

    AssemblyDocument document;
    document.setId(root.stringOr("id", ""));
    document.setName(root.stringOr("name", ""));
    document.setRevision(static_cast<int>(root.numberOr("revision", 0.0)));

    if (const JsonValue* components = root.member("components");
        components && components->isArray()) {
        for (const JsonValue& item : components->arrayItems) {
            if (item.isObject()) {
                document.addComponent(componentFromJson(item, assemblyFilePath));
            }
        }
    }
    if (const JsonValue* joints = root.member("joints"); joints && joints->isArray()) {
        for (const JsonValue& item : joints->arrayItems) {
            if (item.isObject()) {
                document.addJoint(jointFromJson(item));
            }
        }
    }
    document.setSelectedComponentId(root.stringOr("selectedComponentId", ""));
    document.setSelectedJointId(root.stringOr("selectedJointId", ""));
    return Result<AssemblyDocument>::ok(std::move(document));
}

Result<bool> AssemblySerializer::saveToFile(const AssemblyDocument& document,
                                            const std::string& path) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream.is_open()) {
        return Result<bool>::fail(
            {ErrorCode::SerializationFailed, "Cannot open file for writing: " + path});
    }
    const std::string jsonText = toJson(document, path);
    stream << jsonText;
    if (!stream.good()) {
        return Result<bool>::fail(
            {ErrorCode::SerializationFailed, "Write failed: " + path});
    }
    return Result<bool>::ok(true);
}

Result<AssemblyDocument> AssemblySerializer::loadFromFile(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream.is_open()) {
        return Result<AssemblyDocument>::fail(
            {ErrorCode::SerializationFailed, "Cannot open file: " + path});
    }
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    return fromJson(buffer.str(), path);
}

std::string AssemblySerializer::contentHashForFile(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream.is_open()) {
        return std::string();
    }
    std::uint64_t hash = 1469598103934665603ull; // FNV-1a64 offset basis
    char chunk[4096];
    while (stream.read(chunk, sizeof(chunk)) || stream.gcount() > 0) {
        const std::streamsize count = stream.gcount();
        for (std::streamsize i = 0; i < count; ++i) {
            hash ^= static_cast<unsigned char>(chunk[i]);
            hash *= 1099511628211ull; // FNV-1a64 prime
        }
        if (count < static_cast<std::streamsize>(sizeof(chunk))) {
            break;
        }
    }
    char buffer[24];
    std::snprintf(buffer, sizeof(buffer), "%016llx",
                  static_cast<unsigned long long>(hash));
    return buffer;
}

} // namespace cadnext::assembly
