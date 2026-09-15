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

    if (!descriptor.bodies.empty()) {
        JsonValue axes = JsonValue::makeObject();
        axes.set("forward", JsonValue::makeString(descriptor.cadAxes.forward));
        axes.set("up", JsonValue::makeString(descriptor.cadAxes.up));
        axes.set("lengthUnit", JsonValue::makeString("m"));
        root.set("cadAxes", std::move(axes));
        JsonValue bodies = JsonValue::makeArray();
        for (const ConstructionBody& body : descriptor.bodies) {
            JsonValue entry = JsonValue::makeObject();
            entry.set("id", JsonValue::makeString(body.id));
            entry.set("name", JsonValue::makeString(body.name));
            entry.set("materialId", JsonValue::makeString(body.materialId));
            entry.set("densityKgPerM3", JsonValue::makeNumber(body.densityKgPerM3));
            entry.set("volumeM3", JsonValue::makeNumber(body.volumeM3));
            entry.set("massKg", JsonValue::makeNumber(body.massKg));
            entry.set("centerOfMass", vectorToJson(body.centerOfMass));
            JsonValue geometry = JsonValue::makeObject();
            geometry.set("format", JsonValue::makeString("brep-ascii"));
            geometry.set("sha256", JsonValue::makeString(body.brepSha256));
            geometry.set("text", JsonValue::makeString(body.brep));
            entry.set("geometry", std::move(geometry));
            entry.set("firstTriangle", JsonValue::makeNumber(body.firstTriangle));
            entry.set("triangleCount", JsonValue::makeNumber(body.triangleCount));
            JsonValue faces = JsonValue::makeArray();
            for (const ConstructionFaceRange& face : body.faces) {
                JsonValue range = JsonValue::makeObject();
                range.set("id", JsonValue::makeString(face.faceId));
                range.set("firstTriangle", JsonValue::makeNumber(face.firstTriangle));
                range.set("triangleCount", JsonValue::makeNumber(face.triangleCount));
                faces.arrayItems.push_back(std::move(range));
            }
            entry.set("faces", std::move(faces));
            bodies.arrayItems.push_back(std::move(entry));
        }
        root.set("bodies", std::move(bodies));
    }

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

    if (const JsonValue* axes = root.member("cadAxes"); axes && axes->isObject()) {
        descriptor.cadAxes.forward = axes->stringOr("forward", "");
        descriptor.cadAxes.up = axes->stringOr("up", "");
    }
    if (const JsonValue* bodies = root.member("bodies"); bodies && bodies->isArray()) {
        for (const JsonValue& entry : bodies->arrayItems) {
            if (!entry.isObject()) continue;
            ConstructionBody body;
            body.id = entry.stringOr("id", "");
            body.name = entry.stringOr("name", "");
            body.materialId = entry.stringOr("materialId", "");
            body.densityKgPerM3 = entry.numberOr("densityKgPerM3", 0.0);
            body.volumeM3 = entry.numberOr("volumeM3", 0.0);
            body.massKg = entry.numberOr("massKg", 0.0);
            body.centerOfMass = vectorFromJson(entry.member("centerOfMass"));
            if (const JsonValue* geometry = entry.member("geometry"); geometry && geometry->isObject()) {
                body.brep = geometry->stringOr("text", "");
                body.brepSha256 = geometry->stringOr("sha256", "");
            }
            body.firstTriangle = static_cast<std::uint32_t>(entry.numberOr("firstTriangle", 0.0));
            body.triangleCount = static_cast<std::uint32_t>(entry.numberOr("triangleCount", 0.0));
            if (const JsonValue* faces = entry.member("faces"); faces && faces->isArray()) {
                for (const JsonValue& range : faces->arrayItems) {
                    body.faces.push_back({range.stringOr("id", ""),
                                          static_cast<std::uint32_t>(range.numberOr("firstTriangle", 0.0)),
                                          static_cast<std::uint32_t>(range.numberOr("triangleCount", 0.0))});
                }
            }
            descriptor.bodies.push_back(std::move(body));
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
