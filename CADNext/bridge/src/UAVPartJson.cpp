#include "UAVPartJson.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <iomanip>
#include <locale>
#include <sstream>

namespace cadnext::bridge::json {

namespace {

std::string escapeString(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 2);
    for (const char c : value) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
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

// Числа форматируются/разбираются через потоки с классической локалью —
// QApplication на Unix меняет C-локаль процесса, и printf/strtod могут
// начать использовать запятую как десятичный разделитель.
std::string formatNumber(double value) {
    if (!std::isfinite(value)) {
        // Валидатор не пропускает NaN/Infinity; это страховка формата.
        return "0";
    }
    std::ostringstream stream;
    stream.imbue(std::locale::classic());
    stream << std::setprecision(17) << value;
    return stream.str();
}

bool parseNumberToken(const std::string& token, double& out) {
    std::istringstream stream(token);
    stream.imbue(std::locale::classic());
    stream >> out;
    return !stream.fail() && stream.eof();
}

class Parser {
public:
    explicit Parser(const std::string& text) : text_(text) {}

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
        out = JsonValue::makeObject();
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
            if (pos_ < text_.size() && text_[pos_] == ',') {
                ++pos_;
                continue;
            }
            return consume('}', error);
        }
    }

    bool parseArray(JsonValue& out, std::string& error) {
        if (!consume('[', error)) return false;
        out = JsonValue::makeArray();
        skipWhitespace();
        if (pos_ < text_.size() && text_[pos_] == ']') {
            ++pos_;
            return true;
        }
        while (true) {
            JsonValue value;
            if (!parseValue(value, error)) return false;
            out.arrayItems.push_back(std::move(value));
            skipWhitespace();
            if (pos_ < text_.size() && text_[pos_] == ',') {
                ++pos_;
                continue;
            }
            return consume(']', error);
        }
    }

    bool parseString(JsonValue& out, std::string& error) {
        if (!consume('"', error)) return false;
        out.type = JsonValue::Type::String;
        out.stringValue.clear();
        while (pos_ < text_.size()) {
            const char c = text_[pos_++];
            if (c == '"') {
                return true;
            }
            if (c == '\\') {
                if (pos_ >= text_.size()) {
                    return fail(error, "Truncated escape sequence");
                }
                const char escaped = text_[pos_++];
                switch (escaped) {
                case '"': out.stringValue += '"'; break;
                case '\\': out.stringValue += '\\'; break;
                case '/': out.stringValue += '/'; break;
                case 'n': out.stringValue += '\n'; break;
                case 'r': out.stringValue += '\r'; break;
                case 't': out.stringValue += '\t'; break;
                case 'b': out.stringValue += '\b'; break;
                case 'f': out.stringValue += '\f'; break;
                case 'u': {
                    if (pos_ + 4 > text_.size()) {
                        return fail(error, "Truncated \\u escape");
                    }
                    const std::string hex = text_.substr(pos_, 4);
                    pos_ += 4;
                    const long code = std::strtol(hex.c_str(), nullptr, 16);
                    // Writer экранирует только управляющие символы < 0x20;
                    // всё остальное хранится как UTF-8.
                    out.stringValue += (code < 0x80) ? static_cast<char>(code) : '?';
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
            out = JsonValue::makeBool(true);
            pos_ += 4;
            return true;
        }
        if (text_.compare(pos_, 5, "false") == 0) {
            out = JsonValue::makeBool(false);
            pos_ += 5;
            return true;
        }
        return fail(error, "Invalid literal");
    }

    bool parseNull(JsonValue& out, std::string& error) {
        if (text_.compare(pos_, 4, "null") == 0) {
            out = JsonValue::makeNull();
            pos_ += 4;
            return true;
        }
        return fail(error, "Invalid literal");
    }

    bool parseNumber(JsonValue& out, std::string& error) {
        const std::size_t start = pos_;
        if (pos_ < text_.size() && (text_[pos_] == '-' || text_[pos_] == '+')) {
            ++pos_;
        }
        while (pos_ < text_.size() &&
               (std::isdigit(static_cast<unsigned char>(text_[pos_])) || text_[pos_] == '.' ||
                text_[pos_] == 'e' || text_[pos_] == 'E' || text_[pos_] == '-' ||
                text_[pos_] == '+')) {
            ++pos_;
        }
        double value = 0.0;
        if (pos_ == start || !parseNumberToken(text_.substr(start, pos_ - start), value)) {
            pos_ = start;
            return fail(error, "Invalid number");
        }
        out = JsonValue::makeNumber(value);
        return true;
    }

    const std::string& text_;
    std::size_t pos_ = 0;
};

void serializeValue(const JsonValue& value, std::string& out) {
    switch (value.type) {
    case JsonValue::Type::Null:
        out += "null";
        break;
    case JsonValue::Type::Bool:
        out += value.boolValue ? "true" : "false";
        break;
    case JsonValue::Type::Number:
        out += formatNumber(value.numberValue);
        break;
    case JsonValue::Type::String:
        out += '"';
        out += escapeString(value.stringValue);
        out += '"';
        break;
    case JsonValue::Type::Array: {
        out += '[';
        for (std::size_t i = 0; i < value.arrayItems.size(); ++i) {
            if (i > 0) out += ',';
            serializeValue(value.arrayItems[i], out);
        }
        out += ']';
        break;
    }
    case JsonValue::Type::Object: {
        out += '{';
        for (std::size_t i = 0; i < value.objectMembers.size(); ++i) {
            if (i > 0) out += ',';
            out += '"';
            out += escapeString(value.objectMembers[i].first);
            out += "\":";
            serializeValue(value.objectMembers[i].second, out);
        }
        out += '}';
        break;
    }
    }
}

} // namespace

JsonValue JsonValue::makeNull() {
    return JsonValue{};
}

JsonValue JsonValue::makeBool(bool value) {
    JsonValue result;
    result.type = Type::Bool;
    result.boolValue = value;
    return result;
}

JsonValue JsonValue::makeNumber(double value) {
    JsonValue result;
    result.type = Type::Number;
    result.numberValue = value;
    return result;
}

JsonValue JsonValue::makeString(std::string value) {
    JsonValue result;
    result.type = Type::String;
    result.stringValue = std::move(value);
    return result;
}

JsonValue JsonValue::makeArray() {
    JsonValue result;
    result.type = Type::Array;
    return result;
}

JsonValue JsonValue::makeObject() {
    JsonValue result;
    result.type = Type::Object;
    return result;
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
    for (const auto& entry : objectMembers) {
        if (entry.first == key) {
            return &entry.second;
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

std::string JsonValue::serialize() const {
    std::string out;
    serializeValue(*this, out);
    return out;
}

bool parseJson(const std::string& text, JsonValue& out, std::string& error) {
    Parser parser(text);
    return parser.parse(out, error);
}

} // namespace cadnext::bridge::json
