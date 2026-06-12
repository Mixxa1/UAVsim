#pragma once

#include <string>
#include <utility>
#include <vector>

// Внутренний минимальный JSON для payload секций .uavpart: объекты,
// массивы, строки, числа, bool, null. Не входит в публичный API моста;
// сериализация и разбор не зависят от локали процесса.

namespace cadnext::bridge::json {

struct JsonValue {
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolValue = false;
    double numberValue = 0.0;
    std::string stringValue;
    std::vector<JsonValue> arrayItems;
    // Упорядоченные члены объекта — файл получается стабильным и
    // диффабельным.
    std::vector<std::pair<std::string, JsonValue>> objectMembers;

    static JsonValue makeNull();
    static JsonValue makeBool(bool value);
    static JsonValue makeNumber(double value);
    static JsonValue makeString(std::string value);
    static JsonValue makeArray();
    static JsonValue makeObject();

    bool isObject() const { return type == Type::Object; }
    bool isArray() const { return type == Type::Array; }

    void set(const std::string& key, JsonValue value);

    const JsonValue* member(const std::string& key) const;
    std::string stringOr(const std::string& key, const std::string& fallback) const;
    double numberOr(const std::string& key, double fallback) const;
    bool boolOr(const std::string& key, bool fallback) const;

    // Компактная сериализация (без пробелов/переводов строк).
    std::string serialize() const;
};

// true при успехе; иначе error заполнен (технический текст).
bool parseJson(const std::string& text, JsonValue& out, std::string& error);

} // namespace cadnext::bridge::json
