#include "cadnext/bridge/ConstructionExport.hpp"

#include <fstream>
#include <sstream>

#include "UAVPartJson.hpp"

namespace cadnext::bridge {

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

} // namespace

std::string ConstructionExport::toJson(const ConstructionDescriptor& descriptor) {
    JsonValue root = JsonValue::makeObject();
    root.set("format", JsonValue::makeString("uavframe"));
    root.set("version", JsonValue::makeNumber(kFormatVersion));
    root.set("id", JsonValue::makeString(descriptor.id));
    root.set("name", JsonValue::makeString(descriptor.name));
    root.set("massKg", JsonValue::makeNumber(descriptor.massKg));
    root.set("centerOfMass", vectorToJson(descriptor.centerOfMass));
    root.set("boundsMin", vectorToJson(descriptor.boundingBoxMin));
    root.set("boundsMax", vectorToJson(descriptor.boundingBoxMax));

    JsonValue collision = JsonValue::makeObject();
    collision.set("type", JsonValue::makeString("box"));
    collision.set("center", vectorToJson(descriptor.collisionCenter));
    collision.set("size", vectorToJson(descriptor.collisionSize));
    root.set("collisionProxy", std::move(collision));

    JsonValue mesh = JsonValue::makeObject();
    JsonValue vertices = JsonValue::makeArray();
    vertices.arrayItems.reserve(descriptor.mesh.vertices.size());
    for (const float value : descriptor.mesh.vertices) {
        vertices.arrayItems.push_back(JsonValue::makeNumber(static_cast<double>(value)));
    }
    JsonValue indices = JsonValue::makeArray();
    indices.arrayItems.reserve(descriptor.mesh.indices.size());
    for (const std::uint32_t index : descriptor.mesh.indices) {
        indices.arrayItems.push_back(JsonValue::makeNumber(static_cast<double>(index)));
    }
    mesh.set("vertices", std::move(vertices));
    mesh.set("indices", std::move(indices));
    root.set("mesh", std::move(mesh));

    JsonValue attachments = JsonValue::makeArray();
    for (const ConstructionAttachmentPoint& point : descriptor.attachmentPoints) {
        JsonValue entry = JsonValue::makeObject();
        entry.set("id", JsonValue::makeString(point.id));
        entry.set("name", JsonValue::makeString(point.name));
        entry.set("role", JsonValue::makeString(point.role));
        entry.set("position", vectorToJson(point.position));
        entry.set("rotation", vectorToJson(point.rotation));
        attachments.arrayItems.push_back(std::move(entry));
    }
    root.set("attachmentPoints", std::move(attachments));

    return root.serialize();
}

Result<ConstructionDescriptor> ConstructionExport::fromJson(const std::string& jsonText) {
    JsonValue root;
    std::string error;
    if (!json::parseJson(jsonText, root, error)) {
        return Result<ConstructionDescriptor>::fail(
            {ErrorCode::SerializationFailed, "Invalid .uavframe JSON: " + error});
    }
    if (!root.isObject() || root.stringOr("format", "") != "uavframe") {
        return Result<ConstructionDescriptor>::fail(
            {ErrorCode::SerializationFailed, "Not a .uavframe construction"});
    }

    ConstructionDescriptor descriptor;
    descriptor.id = root.stringOr("id", "");
    descriptor.name = root.stringOr("name", "");
    descriptor.massKg = root.numberOr("massKg", 0.0);
    descriptor.centerOfMass = vectorFromJson(root.member("centerOfMass"));
    descriptor.boundingBoxMin = vectorFromJson(root.member("boundsMin"));
    descriptor.boundingBoxMax = vectorFromJson(root.member("boundsMax"));

    if (const JsonValue* collision = root.member("collisionProxy");
        collision && collision->isObject()) {
        descriptor.collisionCenter = vectorFromJson(collision->member("center"));
        descriptor.collisionSize = vectorFromJson(collision->member("size"));
    }

    if (const JsonValue* mesh = root.member("mesh"); mesh && mesh->isObject()) {
        if (const JsonValue* vertices = mesh->member("vertices");
            vertices && vertices->isArray()) {
            descriptor.mesh.vertices.reserve(vertices->arrayItems.size());
            for (const JsonValue& value : vertices->arrayItems) {
                descriptor.mesh.vertices.push_back(
                    static_cast<float>(value.numberValue));
            }
        }
        if (const JsonValue* indices = mesh->member("indices");
            indices && indices->isArray()) {
            descriptor.mesh.indices.reserve(indices->arrayItems.size());
            for (const JsonValue& value : indices->arrayItems) {
                descriptor.mesh.indices.push_back(
                    static_cast<std::uint32_t>(value.numberValue));
            }
        }
    }

    if (const JsonValue* attachments = root.member("attachmentPoints");
        attachments && attachments->isArray()) {
        for (const JsonValue& entry : attachments->arrayItems) {
            if (!entry.isObject()) {
                continue;
            }
            ConstructionAttachmentPoint point;
            point.id = entry.stringOr("id", "");
            point.name = entry.stringOr("name", "");
            point.role = entry.stringOr("role", "");
            point.position = vectorFromJson(entry.member("position"));
            point.rotation = vectorFromJson(entry.member("rotation"));
            descriptor.attachmentPoints.push_back(std::move(point));
        }
    }

    return Result<ConstructionDescriptor>::ok(std::move(descriptor));
}

Result<bool> ConstructionExport::saveToFile(const ConstructionDescriptor& descriptor,
                                            const std::string& path) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream.is_open()) {
        return Result<bool>::fail(
            {ErrorCode::SerializationFailed, "Cannot open file for writing: " + path});
    }
    stream << toJson(descriptor);
    if (!stream.good()) {
        return Result<bool>::fail({ErrorCode::SerializationFailed, "Write failed: " + path});
    }
    return Result<bool>::ok(true);
}

Result<ConstructionDescriptor> ConstructionExport::loadFromFile(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream.is_open()) {
        return Result<ConstructionDescriptor>::fail(
            {ErrorCode::SerializationFailed, "Cannot open file: " + path});
    }
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    return fromJson(buffer.str());
}

} // namespace cadnext::bridge
