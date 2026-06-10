#include "cadnext/DocumentSerializer.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <vector>

namespace cadnext {

namespace {

// ---------------------------------------------------------------------------
// Minimal JSON value model + recursive-descent parser. Only what the
// .cadnext format needs: objects, arrays, strings, numbers, bools, null.
// ---------------------------------------------------------------------------

struct JsonValue {
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolValue = false;
    double numberValue = 0.0;
    std::string stringValue;
    std::vector<JsonValue> arrayItems;
    std::map<std::string, JsonValue> objectMembers;

    bool isObject() const { return type == Type::Object; }
    bool isArray() const { return type == Type::Array; }

    const JsonValue* member(const std::string& key) const {
        auto it = objectMembers.find(key);
        return it == objectMembers.end() ? nullptr : &it->second;
    }

    std::string stringOr(const std::string& key, const std::string& fallback) const {
        const JsonValue* value = member(key);
        return (value && value->type == Type::String) ? value->stringValue : fallback;
    }

    double numberOr(const std::string& key, double fallback) const {
        const JsonValue* value = member(key);
        return (value && value->type == Type::Number) ? value->numberValue : fallback;
    }
};

class JsonParser {
public:
    explicit JsonParser(const std::string& text) : text_(text) {}

    bool parse(JsonValue& out, std::string& error) {
        if (!parseValue(out, error)) {
            return false;
        }
        skipWhitespace();
        if (pos_ != text_.size()) {
            error = "Trailing characters after JSON document";
            return false;
        }
        return true;
    }

private:
    void skipWhitespace() {
        while (pos_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[pos_]))) {
            ++pos_;
        }
    }

    bool fail(std::string& error, const std::string& message) {
        error = message + " (offset " + std::to_string(pos_) + ")";
        return false;
    }

    bool consume(char expected, std::string& error) {
        skipWhitespace();
        if (pos_ >= text_.size() || text_[pos_] != expected) {
            return fail(error, std::string("Expected '") + expected + "'");
        }
        ++pos_;
        return true;
    }

    bool parseValue(JsonValue& out, std::string& error) {
        skipWhitespace();
        if (pos_ >= text_.size()) {
            return fail(error, "Unexpected end of input");
        }
        const char c = text_[pos_];
        if (c == '{') return parseObject(out, error);
        if (c == '[') return parseArray(out, error);
        if (c == '"') return parseString(out, error);
        if (c == 't' || c == 'f') return parseBool(out, error);
        if (c == 'n') return parseNull(out, error);
        return parseNumber(out, error);
    }

    bool parseObject(JsonValue& out, std::string& error) {
        if (!consume('{', error)) return false;
        out.type = JsonValue::Type::Object;
        skipWhitespace();
        if (pos_ < text_.size() && text_[pos_] == '}') {
            ++pos_;
            return true;
        }
        while (true) {
            JsonValue key;
            skipWhitespace();
            if (!parseString(key, error)) return false;
            if (!consume(':', error)) return false;
            JsonValue value;
            if (!parseValue(value, error)) return false;
            out.objectMembers[key.stringValue] = std::move(value);
            skipWhitespace();
            if (pos_ >= text_.size()) return fail(error, "Unterminated object");
            if (text_[pos_] == ',') {
                ++pos_;
                continue;
            }
            if (text_[pos_] == '}') {
                ++pos_;
                return true;
            }
            return fail(error, "Expected ',' or '}' in object");
        }
    }

    bool parseArray(JsonValue& out, std::string& error) {
        if (!consume('[', error)) return false;
        out.type = JsonValue::Type::Array;
        skipWhitespace();
        if (pos_ < text_.size() && text_[pos_] == ']') {
            ++pos_;
            return true;
        }
        while (true) {
            JsonValue item;
            if (!parseValue(item, error)) return false;
            out.arrayItems.push_back(std::move(item));
            skipWhitespace();
            if (pos_ >= text_.size()) return fail(error, "Unterminated array");
            if (text_[pos_] == ',') {
                ++pos_;
                continue;
            }
            if (text_[pos_] == ']') {
                ++pos_;
                return true;
            }
            return fail(error, "Expected ',' or ']' in array");
        }
    }

    bool parseString(JsonValue& out, std::string& error) {
        if (pos_ >= text_.size() || text_[pos_] != '"') {
            return fail(error, "Expected string");
        }
        ++pos_;
        out.type = JsonValue::Type::String;
        out.stringValue.clear();
        while (pos_ < text_.size()) {
            const char c = text_[pos_++];
            if (c == '"') {
                return true;
            }
            if (c == '\\') {
                if (pos_ >= text_.size()) break;
                const char esc = text_[pos_++];
                switch (esc) {
                case '"': out.stringValue += '"'; break;
                case '\\': out.stringValue += '\\'; break;
                case '/': out.stringValue += '/'; break;
                case 'b': out.stringValue += '\b'; break;
                case 'f': out.stringValue += '\f'; break;
                case 'n': out.stringValue += '\n'; break;
                case 'r': out.stringValue += '\r'; break;
                case 't': out.stringValue += '\t'; break;
                case 'u': {
                    if (pos_ + 4 > text_.size()) {
                        return fail(error, "Truncated \\u escape");
                    }
                    const std::string hex = text_.substr(pos_, 4);
                    pos_ += 4;
                    const long code = std::strtol(hex.c_str(), nullptr, 16);
                    // Document names are expected to be UTF-8 already; only
                    // BMP escapes below 0x80 are mapped, others use '?'.
                    out.stringValue += (code > 0 && code < 0x80)
                                           ? static_cast<char>(code)
                                           : '?';
                    break;
                }
                default:
                    return fail(error, "Invalid escape sequence");
                }
                continue;
            }
            out.stringValue += c;
        }
        return fail(error, "Unterminated string");
    }

    bool parseBool(JsonValue& out, std::string& error) {
        if (text_.compare(pos_, 4, "true") == 0) {
            out.type = JsonValue::Type::Bool;
            out.boolValue = true;
            pos_ += 4;
            return true;
        }
        if (text_.compare(pos_, 5, "false") == 0) {
            out.type = JsonValue::Type::Bool;
            out.boolValue = false;
            pos_ += 5;
            return true;
        }
        return fail(error, "Invalid literal");
    }

    bool parseNull(JsonValue& out, std::string& error) {
        if (text_.compare(pos_, 4, "null") == 0) {
            out.type = JsonValue::Type::Null;
            pos_ += 4;
            return true;
        }
        return fail(error, "Invalid literal");
    }

    bool parseNumber(JsonValue& out, std::string& error) {
        const size_t start = pos_;
        if (pos_ < text_.size() && (text_[pos_] == '-' || text_[pos_] == '+')) {
            ++pos_;
        }
        while (pos_ < text_.size() &&
               (std::isdigit(static_cast<unsigned char>(text_[pos_])) || text_[pos_] == '.' ||
                text_[pos_] == 'e' || text_[pos_] == 'E' || text_[pos_] == '-' ||
                text_[pos_] == '+')) {
            ++pos_;
        }
        if (pos_ == start) {
            return fail(error, "Expected number");
        }
        const std::string token = text_.substr(start, pos_ - start);
        char* end = nullptr;
        const double value = std::strtod(token.c_str(), &end);
        if (end != token.c_str() + token.size()) {
            return fail(error, "Invalid number: " + token);
        }
        out.type = JsonValue::Type::Number;
        out.numberValue = value;
        return true;
    }

    const std::string& text_;
    size_t pos_ = 0;
};

// ---------------------------------------------------------------------------
// Writing helpers
// ---------------------------------------------------------------------------

std::string escapeString(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 2);
    for (const char c : value) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                out += buffer;
            } else {
                out += c;
            }
        }
    }
    return out;
}

std::string numberText(double value) {
    if (!std::isfinite(value)) {
        value = 0.0;
    }
    std::ostringstream stream;
    stream.precision(17);
    stream << value;
    return stream.str();
}

std::string vectorJson(const Vector3& v) {
    return "{ \"x\": " + numberText(v.x) + ", \"y\": " + numberText(v.y) +
           ", \"z\": " + numberText(v.z) + " }";
}

const char* objectTypeName(ObjectType type) {
    switch (type) {
    case ObjectType::Body: return "Body";
    case ObjectType::Sketch: return "Sketch";
    case ObjectType::Assembly: return "Assembly";
    case ObjectType::ReferencePlane: return "ReferencePlane";
    case ObjectType::Unknown: break;
    }
    return "Unknown";
}

ObjectType objectTypeFromName(const std::string& name) {
    if (name == "Body") return ObjectType::Body;
    if (name == "Sketch") return ObjectType::Sketch;
    if (name == "Assembly") return ObjectType::Assembly;
    if (name == "ReferencePlane") return ObjectType::ReferencePlane;
    return ObjectType::Unknown;
}

const char* featureTypeName(FeatureType type) {
    switch (type) {
    case FeatureType::Sketch: return "Sketch";
    case FeatureType::Extrude: return "Extrude";
    case FeatureType::Cut: return "Cut";
    case FeatureType::Fillet: return "Fillet";
    case FeatureType::Chamfer: return "Chamfer";
    case FeatureType::BooleanFuse: return "BooleanFuse";
    case FeatureType::BooleanCut: return "BooleanCut";
    case FeatureType::BooleanCommon: return "BooleanCommon";
    }
    return "Sketch";
}

FeatureType featureTypeFromName(const std::string& name) {
    if (name == "Extrude") return FeatureType::Extrude;
    if (name == "Cut") return FeatureType::Cut;
    if (name == "Fillet") return FeatureType::Fillet;
    if (name == "Chamfer") return FeatureType::Chamfer;
    if (name == "BooleanFuse") return FeatureType::BooleanFuse;
    if (name == "BooleanCut") return FeatureType::BooleanCut;
    if (name == "BooleanCommon") return FeatureType::BooleanCommon;
    return FeatureType::Sketch;
}

Vector3 vectorFromJson(const JsonValue* value) {
    Vector3 out;
    if (value && value->isObject()) {
        out.x = value->numberOr("x", 0.0);
        out.y = value->numberOr("y", 0.0);
        out.z = value->numberOr("z", 0.0);
    }
    return out;
}

SketchPoint2D pointFromJson(const JsonValue* value) {
    SketchPoint2D out;
    if (value && value->isObject()) {
        out.u = value->numberOr("u", 0.0);
        out.v = value->numberOr("v", 0.0);
    }
    return out;
}

Result<Document> parseError(const std::string& message) {
    return Result<Document>::fail({ErrorCode::SerializationFailed, message});
}

} // namespace

std::string DocumentSerializer::toJson(const Document& document) {
    std::ostringstream out;
    out << "{\n";
    out << "  \"format\": \"cadnext\",\n";
    out << "  \"version\": " << kFormatVersion << ",\n";
    out << "  \"document\": {\n";
    out << "    \"id\": \"" << escapeString(document.id()) << "\",\n";
    out << "    \"name\": \"" << escapeString(document.name()) << "\",\n";
    out << "    \"unitSystem\": \""
        << (document.unitSystem() == UnitSystem::Imperial ? "Imperial" : "Metric") << "\",\n";

    out << "    \"objects\": [";
    const auto& objects = document.objects();
    for (size_t i = 0; i < objects.size(); ++i) {
        const Object& object = objects[i];
        out << (i == 0 ? "\n" : ",\n");
        out << "      {\n";
        out << "        \"id\": \"" << escapeString(object.id) << "\",\n";
        out << "        \"name\": \"" << escapeString(object.name) << "\",\n";
        out << "        \"type\": \"" << objectTypeName(object.type) << "\",\n";
        out << "        \"primitive\": {\n";
        out << "          \"kind\": \"" << primitiveKindName(object.primitive.kind) << "\",\n";
        out << "          \"width\": " << numberText(object.primitive.width) << ",\n";
        out << "          \"height\": " << numberText(object.primitive.height) << ",\n";
        out << "          \"depth\": " << numberText(object.primitive.depth) << ",\n";
        out << "          \"radius\": " << numberText(object.primitive.radius) << "\n";
        out << "        },\n";
        out << "        \"transform\": {\n";
        out << "          \"position\": " << vectorJson(object.transform.position) << ",\n";
        out << "          \"rotationEuler\": " << vectorJson(object.transform.rotationEuler)
            << ",\n";
        out << "          \"scale\": " << vectorJson(object.transform.scale) << "\n";
        out << "        }\n";
        out << "      }";
    }
    out << (objects.empty() ? "],\n" : "\n    ],\n");

    out << "    \"sketches\": [";
    const auto& sketches = document.sketches();
    for (size_t i = 0; i < sketches.size(); ++i) {
        const Sketch& sketch = sketches[i];
        out << (i == 0 ? "\n" : ",\n");
        out << "      {\n";
        out << "        \"id\": \"" << escapeString(sketch.id) << "\",\n";
        out << "        \"name\": \"" << escapeString(sketch.name) << "\",\n";
        out << "        \"plane\": \"" << sketchPlaneName(sketch.plane) << "\",\n";
        out << "        \"entities\": [";
        for (size_t j = 0; j < sketch.entities.size(); ++j) {
            const SketchEntity& entity = sketch.entities[j];
            out << (j == 0 ? "\n" : ",\n");
            out << "          {\n";
            out << "            \"id\": \"" << escapeString(entity.id) << "\",\n";
            out << "            \"name\": \"" << escapeString(entity.name) << "\",\n";
            out << "            \"type\": \"" << sketchEntityTypeName(entity.type) << "\",\n";
            switch (entity.type) {
            case SketchEntityType::Line:
                out << "            \"line\": {\n";
                out << "              \"start\": { \"u\": " << numberText(entity.line.start.u)
                    << ", \"v\": " << numberText(entity.line.start.v) << " },\n";
                out << "              \"end\": { \"u\": " << numberText(entity.line.end.u)
                    << ", \"v\": " << numberText(entity.line.end.v) << " }\n";
                out << "            }\n";
                break;
            case SketchEntityType::Rectangle:
                out << "            \"rectangle\": {\n";
                out << "              \"origin\": { \"u\": "
                    << numberText(entity.rectangle.origin.u)
                    << ", \"v\": " << numberText(entity.rectangle.origin.v) << " },\n";
                out << "              \"width\": " << numberText(entity.rectangle.width)
                    << ",\n";
                out << "              \"height\": " << numberText(entity.rectangle.height)
                    << "\n";
                out << "            }\n";
                break;
            case SketchEntityType::Circle:
                out << "            \"circle\": {\n";
                out << "              \"center\": { \"u\": " << numberText(entity.circle.center.u)
                    << ", \"v\": " << numberText(entity.circle.center.v) << " },\n";
                out << "              \"radius\": " << numberText(entity.circle.radius) << "\n";
                out << "            }\n";
                break;
            }
            out << "          }";
        }
        out << (sketch.entities.empty() ? "]\n" : "\n        ]\n");
        out << "      }";
    }
    out << (sketches.empty() ? "],\n" : "\n    ],\n");

    out << "    \"features\": [";
    const auto& features = document.features();
    for (size_t i = 0; i < features.size(); ++i) {
        const Feature& feature = features[i];
        out << (i == 0 ? "\n" : ",\n");
        out << "      {\n";
        out << "        \"id\": \"" << escapeString(feature.id) << "\",\n";
        out << "        \"name\": \"" << escapeString(feature.name) << "\",\n";
        out << "        \"type\": \"" << featureTypeName(feature.type) << "\",\n";
        out << "        \"targetObjectId\": \"" << escapeString(feature.targetObjectId)
            << "\",\n";
        out << "        \"suppressed\": " << (feature.suppressed ? "true" : "false") << "\n";
        out << "      }";
    }
    out << (features.empty() ? "]\n" : "\n    ]\n");

    out << "  }\n";
    out << "}\n";
    return out.str();
}

Result<Document> DocumentSerializer::fromJson(const std::string& json) {
    JsonValue root;
    std::string error;
    JsonParser parser(json);
    if (!parser.parse(root, error)) {
        return parseError("JSON parse error: " + error);
    }
    if (!root.isObject()) {
        return parseError("Top-level JSON value must be an object");
    }
    if (root.stringOr("format", "") != "cadnext") {
        return parseError("Not a cadnext document (missing format marker)");
    }
    const int version = static_cast<int>(root.numberOr("version", 0));
    if (version != kFormatVersion) {
        return parseError("Unsupported cadnext format version: " + std::to_string(version));
    }
    const JsonValue* documentValue = root.member("document");
    if (!documentValue || !documentValue->isObject()) {
        return parseError("Missing \"document\" object");
    }

    Document document;
    const std::string id = documentValue->stringOr("id", "");
    if (!id.empty()) {
        document.setId(id);
    }
    document.setName(documentValue->stringOr("name", "Untitled CADNext Document"));
    document.setUnitSystem(documentValue->stringOr("unitSystem", "Metric") == "Imperial"
                               ? UnitSystem::Imperial
                               : UnitSystem::Metric);

    const JsonValue* objectsValue = documentValue->member("objects");
    if (objectsValue) {
        if (!objectsValue->isArray()) {
            return parseError("\"objects\" must be an array");
        }
        for (const JsonValue& objectValue : objectsValue->arrayItems) {
            if (!objectValue.isObject()) {
                return parseError("Object entries must be JSON objects");
            }
            Object object;
            object.id = objectValue.stringOr("id", "");
            object.name = objectValue.stringOr("name", "Object");
            object.type = objectTypeFromName(objectValue.stringOr("type", "Unknown"));
            if (object.id.empty()) {
                return parseError("Object entry missing id");
            }

            if (const JsonValue* primitive = objectValue.member("primitive");
                primitive && primitive->isObject()) {
                object.primitive.kind = primitiveKindFromName(primitive->stringOr("kind", "None"));
                object.primitive.width = primitive->numberOr("width", 1.0);
                object.primitive.height = primitive->numberOr("height", 1.0);
                object.primitive.depth = primitive->numberOr("depth", 1.0);
                object.primitive.radius = primitive->numberOr("radius", 0.5);
            }

            if (const JsonValue* transform = objectValue.member("transform");
                transform && transform->isObject()) {
                object.transform.position = vectorFromJson(transform->member("position"));
                object.transform.rotationEuler =
                    vectorFromJson(transform->member("rotationEuler"));
                const JsonValue* scale = transform->member("scale");
                object.transform.scale =
                    scale ? vectorFromJson(scale) : Vector3{1.0, 1.0, 1.0};
            }

            document.addObject(std::move(object));
        }
    }

    // "sketches" is optional: CADNext 0.3/0.4 files predate the sketch
    // model and must keep loading. Malformed sketch entries are skipped
    // instead of failing the whole document.
    const JsonValue* sketchesValue = documentValue->member("sketches");
    if (sketchesValue && sketchesValue->isArray()) {
        for (const JsonValue& sketchValue : sketchesValue->arrayItems) {
            if (!sketchValue.isObject()) {
                continue;
            }
            Sketch sketch;
            sketch.id = sketchValue.stringOr("id", "");
            if (sketch.id.empty()) {
                continue;
            }
            sketch.name = sketchValue.stringOr("name", "Sketch");
            sketch.plane = sketchPlaneFromName(sketchValue.stringOr("plane", "XY"));

            if (const JsonValue* entities = sketchValue.member("entities");
                entities && entities->isArray()) {
                for (const JsonValue& entityValue : entities->arrayItems) {
                    if (!entityValue.isObject()) {
                        continue;
                    }
                    SketchEntity entity;
                    entity.id = entityValue.stringOr("id", "");
                    if (entity.id.empty()) {
                        continue;
                    }
                    entity.name = entityValue.stringOr("name", "Entity");
                    entity.type =
                        sketchEntityTypeFromName(entityValue.stringOr("type", "Line"));

                    switch (entity.type) {
                    case SketchEntityType::Line: {
                        const JsonValue* line = entityValue.member("line");
                        if (!line || !line->isObject()) {
                            continue;
                        }
                        entity.line.start = pointFromJson(line->member("start"));
                        entity.line.end = pointFromJson(line->member("end"));
                        break;
                    }
                    case SketchEntityType::Rectangle: {
                        const JsonValue* rectangle = entityValue.member("rectangle");
                        if (!rectangle || !rectangle->isObject()) {
                            continue;
                        }
                        entity.rectangle.origin = pointFromJson(rectangle->member("origin"));
                        entity.rectangle.width = rectangle->numberOr("width", 1.0);
                        entity.rectangle.height = rectangle->numberOr("height", 1.0);
                        break;
                    }
                    case SketchEntityType::Circle: {
                        const JsonValue* circle = entityValue.member("circle");
                        if (!circle || !circle->isObject()) {
                            continue;
                        }
                        entity.circle.center = pointFromJson(circle->member("center"));
                        entity.circle.radius = circle->numberOr("radius", 0.5);
                        break;
                    }
                    }
                    sketch.entities.push_back(std::move(entity));
                }
            }

            document.addSketch(std::move(sketch));
        }
    }

    const JsonValue* featuresValue = documentValue->member("features");
    if (featuresValue) {
        if (!featuresValue->isArray()) {
            return parseError("\"features\" must be an array");
        }
        for (const JsonValue& featureValue : featuresValue->arrayItems) {
            if (!featureValue.isObject()) {
                return parseError("Feature entries must be JSON objects");
            }
            Feature feature;
            feature.id = featureValue.stringOr("id", "");
            feature.name = featureValue.stringOr("name", "");
            feature.type = featureTypeFromName(featureValue.stringOr("type", "Sketch"));
            feature.targetObjectId = featureValue.stringOr("targetObjectId", "");
            const JsonValue* suppressed = featureValue.member("suppressed");
            feature.suppressed =
                suppressed && suppressed->type == JsonValue::Type::Bool && suppressed->boolValue;
            document.addFeature(std::move(feature));
        }
    }

    return Result<Document>::ok(std::move(document));
}

Result<bool> DocumentSerializer::saveToFile(const Document& document, const std::string& path) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream.is_open()) {
        return Result<bool>::fail(
            {ErrorCode::SerializationFailed, "Cannot open file for writing: " + path});
    }
    stream << toJson(document);
    stream.flush();
    if (!stream.good()) {
        return Result<bool>::fail({ErrorCode::SerializationFailed, "Write failed: " + path});
    }
    return Result<bool>::ok(true);
}

Result<Document> DocumentSerializer::loadFromFile(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream.is_open()) {
        return parseError("Cannot open file for reading: " + path);
    }
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    return fromJson(buffer.str());
}

} // namespace cadnext
