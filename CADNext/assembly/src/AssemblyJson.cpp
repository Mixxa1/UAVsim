#include "AssemblyJson.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <locale>
#include <sstream>

namespace cadnext::assembly::json {

JsonValue JsonValue::makeBool(bool value) {
    JsonValue v;
    v.type = Type::Bool;
    v.boolValue = value;
    return v;
}

JsonValue JsonValue::makeNumber(double value) {
    JsonValue v;
    v.type = Type::Number;
    v.numberValue = value;
    return v;
}

JsonValue JsonValue::makeString(std::string value) {
    JsonValue v;
    v.type = Type::String;
    v.stringValue = std::move(value);
    return v;
}

JsonValue JsonValue::makeArray() {
    JsonValue v;
    v.type = Type::Array;
    return v;
}

JsonValue JsonValue::makeObject() {
    JsonValue v;
    v.type = Type::Object;
    return v;
}

void JsonValue::set(const std::string& key, JsonValue value) {
    for (auto& member : objectMembers) {
        if (member.first == key) {
            member.second = std::move(value);
            return;
        }
    }
    objectMembers.emplace_back(key, std::move(value));
}

const JsonValue* JsonValue::member(const std::string& key) const {
    for (const auto& member : objectMembers) {
        if (member.first == key) {
            return &member.second;
        }
    }
    return nullptr;
}

std::string JsonValue::stringOr(const std::string& key, const std::string& fallback) const {
    const JsonValue* value = member(key);
    return (value && value->type == Type::String) ? value->stringValue : fallback;
}

double JsonValue::numberOr(const std::string& key, double fallback) const {
    const JsonValue* value = member(key);
    return (value && value->type == Type::Number) ? value->numberValue : fallback;
}

bool JsonValue::boolOr(const std::string& key, bool fallback) const {
    const JsonValue* value = member(key);
    return (value && value->type == Type::Bool) ? value->boolValue : fallback;
}

namespace {

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
    stream.imbue(std::locale::classic());
    stream.precision(17);
    stream << value;
    return stream.str();
}

void serializeValue(const JsonValue& value, std::string& out) {
    switch (value.type) {
    case JsonValue::Type::Null:
        out += "null";
        break;
    case JsonValue::Type::Bool:
        out += value.boolValue ? "true" : "false";
        break;
    case JsonValue::Type::Number:
        out += numberText(value.numberValue);
        break;
    case JsonValue::Type::String:
        out += '"';
        out += escapeString(value.stringValue);
        out += '"';
        break;
    case JsonValue::Type::Array: {
        out += '[';
        bool first = true;
        for (const JsonValue& item : value.arrayItems) {
            if (!first) {
                out += ',';
            }
            first = false;
            serializeValue(item, out);
        }
        out += ']';
        break;
    }
    case JsonValue::Type::Object: {
        out += '{';
        bool first = true;
        for (const auto& member : value.objectMembers) {
            if (!first) {
                out += ',';
            }
            first = false;
            out += '"';
            out += escapeString(member.first);
            out += "\":";
            serializeValue(member.second, out);
        }
        out += '}';
        break;
    }
    }
}

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
            out.objectMembers.emplace_back(key.stringValue, std::move(value));
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
                    // Names are stored as UTF-8 already; only BMP escapes
                    // below 0x80 map to characters, others become '?'.
                    out.stringValue +=
                        (code > 0 && code < 0x80) ? static_cast<char>(code) : '?';
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

} // namespace

std::string JsonValue::serialize() const {
    std::string out;
    serializeValue(*this, out);
    return out;
}

bool parseJson(const std::string& text, JsonValue& out, std::string& error) {
    JsonParser parser(text);
    return parser.parse(out, error);
}

} // namespace cadnext::assembly::json
