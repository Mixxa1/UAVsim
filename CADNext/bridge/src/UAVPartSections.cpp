#include "UAVPartSections.hpp"

namespace cadnext::bridge::sections {

namespace {

using json::JsonValue;

JsonValue vectorToJson(const Vector3& vector) {
    JsonValue object = JsonValue::makeObject();
    object.set("x", JsonValue::makeNumber(vector.x));
    object.set("y", JsonValue::makeNumber(vector.y));
    object.set("z", JsonValue::makeNumber(vector.z));
    return object;
}

Vector3 vectorFromJson(const JsonValue* value) {
    Vector3 result;
    if (value && value->isObject()) {
        result.x = value->numberOr("x", 0.0);
        result.y = value->numberOr("y", 0.0);
        result.z = value->numberOr("z", 0.0);
    }
    return result;
}

JsonValue stringListToJson(const std::vector<std::string>& values) {
    JsonValue array = JsonValue::makeArray();
    for (const std::string& value : values) {
        array.arrayItems.push_back(JsonValue::makeString(value));
    }
    return array;
}

std::vector<std::string> stringListFromJson(const JsonValue* value) {
    std::vector<std::string> result;
    if (value && value->isArray()) {
        for (const JsonValue& item : value->arrayItems) {
            if (item.type == JsonValue::Type::String) {
                result.push_back(item.stringValue);
            }
        }
    }
    return result;
}

bool parseObjectPayload(const std::string& payload, JsonValue& out, std::string& error) {
    if (!json::parseJson(payload, out, error)) {
        return false;
    }
    if (!out.isObject()) {
        error = "Section payload is not a JSON object";
        return false;
    }
    return true;
}

} // namespace

std::string encodeManifest(const UAVPartManifest& manifest) {
    JsonValue object = JsonValue::makeObject();
    object.set("id", JsonValue::makeString(manifest.id));
    object.set("name", JsonValue::makeString(manifest.name));
    object.set("displayName", JsonValue::makeString(manifest.displayName));
    object.set("formatVersion", JsonValue::makeNumber(manifest.formatVersion));
    object.set("source", JsonValue::makeString(manifest.source));
    object.set("units", JsonValue::makeString(manifest.units));
    object.set("partKind", JsonValue::makeString(manifest.partKind));
    object.set("createdAt", JsonValue::makeString(manifest.createdAt));
    object.set("modifiedAt", JsonValue::makeString(manifest.modifiedAt));
    object.set("simulationReady", JsonValue::makeBool(manifest.simulationReady));
    object.set("massComputed", JsonValue::makeBool(manifest.massComputed));
    object.set("attachmentPointsDefined", JsonValue::makeBool(manifest.attachmentPointsDefined));
    object.set("geometryStored", JsonValue::makeBool(manifest.geometryStored));
    object.set("visualMeshStored", JsonValue::makeBool(manifest.visualMeshStored));
    object.set("readinessIssues", stringListToJson(manifest.readinessIssues));
    return object.serialize();
}

bool decodeManifest(const std::string& payload, UAVPartManifest& out, std::string& error) {
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.id = root.stringOr("id", "");
    out.name = root.stringOr("name", "");
    out.displayName = root.stringOr("displayName", out.name);
    out.formatVersion = static_cast<std::uint32_t>(root.numberOr("formatVersion", 0.0));
    out.source = root.stringOr("source", "");
    out.units = root.stringOr("units", "");
    out.partKind = root.stringOr("partKind", "");
    out.createdAt = root.stringOr("createdAt", "");
    out.modifiedAt = root.stringOr("modifiedAt", "");
    out.simulationReady = root.boolOr("simulationReady", false);
    out.massComputed = root.boolOr("massComputed", false);
    out.attachmentPointsDefined = root.boolOr("attachmentPointsDefined", false);
    out.geometryStored = root.boolOr("geometryStored", false);
    out.visualMeshStored = root.boolOr("visualMeshStored", false);
    out.readinessIssues = stringListFromJson(root.member("readinessIssues"));
    return true;
}

std::string encodeMaterial(const UAVPartMaterial& material) {
    JsonValue object = JsonValue::makeObject();
    object.set("materialId", JsonValue::makeString(material.materialId));
    object.set("displayName", JsonValue::makeString(material.displayName));
    object.set("densityKgPerM3", JsonValue::makeNumber(material.densityKgPerM3));
    object.set("previewColor", JsonValue::makeString(material.previewColor));
    object.set("source", JsonValue::makeString(material.source));
    return object.serialize();
}

bool decodeMaterial(const std::string& payload, UAVPartMaterial& out, std::string& error) {
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.materialId = root.stringOr("materialId", "");
    out.displayName = root.stringOr("displayName", "");
    out.densityKgPerM3 = root.numberOr("densityKgPerM3", 0.0);
    out.previewColor = root.stringOr("previewColor", "");
    out.source = root.stringOr("source", "");
    return true;
}

std::string encodeMassProperties(const UAVPartMassProperties& mass) {
    JsonValue object = JsonValue::makeObject();
    object.set("volumeM3", JsonValue::makeNumber(mass.volumeM3));
    object.set("massKg", JsonValue::makeNumber(mass.massKg));
    object.set("centerOfMassX", JsonValue::makeNumber(mass.centerOfMass.x));
    object.set("centerOfMassY", JsonValue::makeNumber(mass.centerOfMass.y));
    object.set("centerOfMassZ", JsonValue::makeNumber(mass.centerOfMass.z));
    object.set("boundingBoxMin", vectorToJson(mass.boundingBoxMin));
    object.set("boundingBoxMax", vectorToJson(mass.boundingBoxMax));
    object.set("boundingWidth", JsonValue::makeNumber(mass.boundingWidth));
    object.set("boundingDepth", JsonValue::makeNumber(mass.boundingDepth));
    object.set("boundingHeight", JsonValue::makeNumber(mass.boundingHeight));
    object.set("dragPenalty", JsonValue::makeNumber(mass.dragPenalty));
    object.set("structuralRating", JsonValue::makeNumber(mass.structuralRating));
    object.set("densityKgPerM3", JsonValue::makeNumber(mass.densityKgPerM3));
    object.set("calculationMethod", JsonValue::makeString(mass.calculationMethod));
    object.set("valid", JsonValue::makeBool(mass.valid));
    return object.serialize();
}

bool decodeMassProperties(const std::string& payload, UAVPartMassProperties& out,
                          std::string& error) {
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.volumeM3 = root.numberOr("volumeM3", 0.0);
    out.massKg = root.numberOr("massKg", 0.0);
    out.centerOfMass.x = root.numberOr("centerOfMassX", 0.0);
    out.centerOfMass.y = root.numberOr("centerOfMassY", 0.0);
    out.centerOfMass.z = root.numberOr("centerOfMassZ", 0.0);
    out.boundingBoxMin = vectorFromJson(root.member("boundingBoxMin"));
    out.boundingBoxMax = vectorFromJson(root.member("boundingBoxMax"));
    out.boundingWidth = root.numberOr("boundingWidth", 0.0);
    out.boundingDepth = root.numberOr("boundingDepth", 0.0);
    out.boundingHeight = root.numberOr("boundingHeight", 0.0);
    out.dragPenalty = root.numberOr("dragPenalty", 0.0);
    out.structuralRating = root.numberOr("structuralRating", 1.0);
    out.densityKgPerM3 = root.numberOr("densityKgPerM3", 0.0);
    out.calculationMethod = root.stringOr("calculationMethod", "");
    out.valid = root.boolOr("valid", false);
    return true;
}

std::string encodeAttachmentPoints(const std::vector<UAVPartAttachmentPoint>& points) {
    JsonValue array = JsonValue::makeArray();
    for (const UAVPartAttachmentPoint& point : points) {
        JsonValue object = JsonValue::makeObject();
        object.set("id", JsonValue::makeString(point.id));
        object.set("name", JsonValue::makeString(point.name));
        object.set("role", JsonValue::makeString(point.role));
        object.set("localPosition", vectorToJson(point.localPosition));
        object.set("localRotation", vectorToJson(point.localRotation));
        object.set("isSystem", JsonValue::makeBool(point.isSystem));
        object.set("isEnabled", JsonValue::makeBool(point.isEnabled));
        array.arrayItems.push_back(std::move(object));
    }
    JsonValue root = JsonValue::makeObject();
    root.set("points", std::move(array));
    return root.serialize();
}

bool decodeAttachmentPoints(const std::string& payload,
                            std::vector<UAVPartAttachmentPoint>& out, std::string& error) {
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.clear();
    const JsonValue* points = root.member("points");
    if (!points || !points->isArray()) {
        error = "AttachmentPoints section has no points array";
        return false;
    }
    for (const JsonValue& item : points->arrayItems) {
        if (!item.isObject()) {
            continue;
        }
        UAVPartAttachmentPoint point;
        point.id = item.stringOr("id", "");
        point.name = item.stringOr("name", "");
        point.role = item.stringOr("role", "generic");
        point.localPosition = vectorFromJson(item.member("localPosition"));
        point.localRotation = vectorFromJson(item.member("localRotation"));
        point.isSystem = item.boolOr("isSystem", true);
        point.isEnabled = item.boolOr("isEnabled", true);
        out.push_back(std::move(point));
    }
    return true;
}

std::string encodeSimulationProxy(const UAVPartSimulationProxy& proxy) {
    JsonValue object = JsonValue::makeObject();
    object.set("type", JsonValue::makeString(proxy.type));
    object.set("center", vectorToJson(proxy.center));
    object.set("size", vectorToJson(proxy.size));
    object.set("source", JsonValue::makeString(proxy.source));
    object.set("valid", JsonValue::makeBool(proxy.valid));
    return object.serialize();
}

bool decodeSimulationProxy(const std::string& payload, UAVPartSimulationProxy& out,
                           std::string& error) {
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.type = root.stringOr("type", "box");
    out.center = vectorFromJson(root.member("center"));
    out.size = vectorFromJson(root.member("size"));
    out.source = root.stringOr("source", "");
    out.valid = root.boolOr("valid", false);
    return true;
}

std::string encodeCompatibility(const UAVPartCompatibility& compatibility) {
    JsonValue object = JsonValue::makeObject();
    object.set("allowedUAVTypes", stringListToJson(compatibility.allowedUAVTypes));
    object.set("preferredMountRoles", stringListToJson(compatibility.preferredMountRoles));
    object.set("maxRecommendedSpeedMps",
               compatibility.maxRecommendedSpeedMps
                   ? JsonValue::makeNumber(*compatibility.maxRecommendedSpeedMps)
                   : JsonValue::makeNull());
    object.set("warnings", stringListToJson(compatibility.warnings));
    return object.serialize();
}

bool decodeCompatibility(const std::string& payload, UAVPartCompatibility& out,
                         std::string& error) {
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.allowedUAVTypes = stringListFromJson(root.member("allowedUAVTypes"));
    out.preferredMountRoles = stringListFromJson(root.member("preferredMountRoles"));
    const JsonValue* speed = root.member("maxRecommendedSpeedMps");
    if (speed && speed->type == json::JsonValue::Type::Number) {
        out.maxRecommendedSpeedMps = speed->numberValue;
    } else {
        out.maxRecommendedSpeedMps.reset();
    }
    out.warnings = stringListFromJson(root.member("warnings"));
    return true;
}

std::string encodeVisualMesh(const UAVPartVisualMesh& mesh) {
    using json::JsonValue;
    JsonValue object = JsonValue::makeObject();
    object.set("source", JsonValue::makeString(mesh.source));
    object.set("bbMin", vectorToJson(mesh.boundingBoxMin));
    object.set("bbMax", vectorToJson(mesh.boundingBoxMax));
    object.set("valid", JsonValue::makeBool(mesh.valid));

    JsonValue verts = JsonValue::makeArray();
    verts.arrayItems.reserve(mesh.vertices.size());
    for (float v : mesh.vertices) {
        verts.arrayItems.push_back(JsonValue::makeNumber(static_cast<double>(v)));
    }
    object.set("verts", std::move(verts));

    JsonValue idx = JsonValue::makeArray();
    idx.arrayItems.reserve(mesh.indices.size());
    for (std::uint32_t i : mesh.indices) {
        idx.arrayItems.push_back(JsonValue::makeNumber(static_cast<double>(i)));
    }
    object.set("idx", std::move(idx));

    return object.serialize();
}

bool decodeVisualMesh(const std::string& payload, UAVPartVisualMesh& out, std::string& error) {
    using json::JsonValue;
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.source = root.stringOr("source", "");
    out.valid = root.boolOr("valid", false);
    out.boundingBoxMin = vectorFromJson(root.member("bbMin"));
    out.boundingBoxMax = vectorFromJson(root.member("bbMax"));

    const JsonValue* verts = root.member("verts");
    if (!verts || !verts->isArray()) {
        error = "VisualMesh: missing vertices array";
        return false;
    }
    out.vertices.reserve(verts->arrayItems.size());
    for (const JsonValue& v : verts->arrayItems) {
        if (v.type == JsonValue::Type::Number) {
            out.vertices.push_back(static_cast<float>(v.numberValue));
        }
    }

    const JsonValue* idx = root.member("idx");
    if (!idx || !idx->isArray()) {
        error = "VisualMesh: missing indices array";
        return false;
    }
    out.indices.reserve(idx->arrayItems.size());
    for (const JsonValue& i : idx->arrayItems) {
        if (i.type == JsonValue::Type::Number) {
            out.indices.push_back(static_cast<std::uint32_t>(i.numberValue));
        }
    }
    return true;
}

std::string encodeExactGeometry(const UAVPartExactGeometry& geo) {
    using json::JsonValue;
    JsonValue object = JsonValue::makeObject();
    object.set("geometryKernel", JsonValue::makeString(geo.geometryKernel));
    object.set("representation", JsonValue::makeString(geo.representation));
    object.set("valid", JsonValue::makeBool(geo.valid));
    object.set("brepData",
               JsonValue::makeString(std::string(geo.payload.begin(), geo.payload.end())));
    return object.serialize();
}

bool decodeExactGeometry(const std::string& payload, UAVPartExactGeometry& out,
                         std::string& error) {
    using json::JsonValue;
    JsonValue root;
    if (!parseObjectPayload(payload, root, error)) {
        return false;
    }
    out.geometryKernel = root.stringOr("geometryKernel", "");
    out.representation = root.stringOr("representation", "");
    out.valid = root.boolOr("valid", false);
    const std::string brepData = root.stringOr("brepData", "");
    if (brepData.empty() && out.valid) {
        error = "ExactGeometry: brepData is empty";
        return false;
    }
    out.payload = std::vector<std::uint8_t>(brepData.begin(), brepData.end());
    return true;
}

} // namespace cadnext::bridge::sections
