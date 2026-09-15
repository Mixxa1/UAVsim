#include "cadnext/fea/StructuralFieldFile.hpp"

#include "cadnext/fea/FeaJson.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

using json::JsonValue;

Result<StructuralFieldFile> invalid(const std::string& message) {
    return Result<StructuralFieldFile>::fail({ErrorCode::SerializationFailed, "файл поля: " + message});
}

bool readNumbers(const JsonValue* value, std::vector<double>& out) {
    if (value == nullptr || !value->isArray()) return false;
    out.clear();
    out.reserve(value->arrayItems.size());
    for (const auto& item : value->arrayItems) {
        if (item.type != JsonValue::Type::Number) return false;
        out.push_back(item.numberValue);
    }
    return true;
}

bool parseHex(const std::string& hex, ColorStop& stop) {
    if (hex.size() != 7 || hex[0] != '#') return false;
    for (int c = 0; c < 3; ++c) {
        const std::string byte = hex.substr(1 + 2 * c, 2);
        char* end = nullptr;
        const long value = std::strtol(byte.c_str(), &end, 16);
        if (end != byte.c_str() + 2) return false;
        stop.rgb[c] = static_cast<float>(value) / 255.0f;
    }
    stop.hex = hex;
    return true;
}

bool readStops(const JsonValue& presentation, std::vector<ColorStop>& out) {
    const JsonValue* stops = presentation.member("colorStops");
    if (stops == nullptr || !stops->isArray() || stops->arrayItems.size() < 2) return false;
    for (const auto& pair : stops->arrayItems) {
        ColorStop stop;
        if (!pair.isArray() || pair.arrayItems.size() != 2 || pair.arrayItems[0].type != JsonValue::Type::Number
            || !parseHex(pair.arrayItems[1].stringValue, stop)) {
            return false;
        }
        stop.position = pair.arrayItems[0].numberValue;
        out.push_back(stop);
    }
    return true;
}

bool readTriangles(const std::vector<double>& flat, std::size_t nodeCount, std::vector<std::array<int, 3>>& out) {
    if (flat.size() % 3 != 0) return false;
    for (std::size_t t = 0; t < flat.size(); t += 3) {
        std::array<int, 3> triangle{};
        for (int k = 0; k < 3; ++k) {
            const double index = flat[t + k];
            if (!(index >= 0.0) || index >= static_cast<double>(nodeCount) || index != std::floor(index)) return false;
            triangle[k] = static_cast<int>(index);
        }
        out.push_back(triangle);
    }
    return true;
}

} // namespace

std::array<float, 3> rampColor(const std::vector<ColorStop>& stops, double t) {
    if (stops.empty()) return {0.5f, 0.5f, 0.5f};
    if (!(t > 0.0)) return stops.front().rgb;
    for (std::size_t i = 1; i < stops.size(); ++i) {
        if (t <= stops[i].position) {
            const double k = (t - stops[i - 1].position) / (stops[i].position - stops[i - 1].position);
            std::array<float, 3> color{};
            for (int c = 0; c < 3; ++c) color[c] = static_cast<float>(stops[i - 1].rgb[c] + (stops[i].rgb[c] - stops[i - 1].rgb[c]) * k);
            return color;
        }
    }
    return stops.back().rgb;
}

std::array<float, 3> StructuralFieldFile::rampColor(double t) const {
    return fea::rampColor(colorStops, t);
}

std::array<float, 3> StructuralFieldFile::utilizationColor(int node) const {
    const double u = vonMisesPa[node] / allowableStressPa;
    return u > 1.0 ? overflowColor.rgb : rampColor(u);
}

double StructuralFieldFile::maxVonMisesPa() const {
    return vonMisesPa.empty() ? 0.0 : *std::max_element(vonMisesPa.begin(), vonMisesPa.end());
}

Result<StructuralFieldFile> parseStructuralField(const std::string& text) {
    JsonValue root;
    std::string error;
    if (!json::parseJson(text, root, error)) return invalid("не JSON: " + error);
    if (root.stringOr("schema", "") != "cadnext-structural-field/1") return invalid("неизвестная схема");

    StructuralFieldFile field;
    std::vector<double> nodes, displacement, triangles;
    if (!readNumbers(root.member("nodes"), nodes) || !readNumbers(root.member("displacement"), displacement)
        || !readNumbers(root.member("vonMisesPa"), field.vonMisesPa) || !readNumbers(root.member("triangles"), triangles)) {
        return invalid("нет nodes / displacement / vonMisesPa / triangles");
    }
    const std::size_t count = field.vonMisesPa.size();
    if (nodes.size() != 3 * count || displacement.size() != 3 * count || triangles.size() % 3 != 0) {
        return invalid("размеры массивов не согласованы");
    }
    for (std::size_t n = 0; n < count; ++n) {
        field.nodes.push_back({nodes[3 * n], nodes[3 * n + 1], nodes[3 * n + 2]});
        field.displacement.push_back({displacement[3 * n], displacement[3 * n + 1], displacement[3 * n + 2]});
    }
    if (!readTriangles(triangles, count, field.triangles)) return invalid("треугольник ссылается на несуществующий узел");

    field.allowableStressPa = root.numberOr("allowableStressPa", 0.0);
    if (!(field.allowableStressPa > 0.0)) return invalid("нет допускаемого напряжения");
    field.allowableBasis = root.stringOr("allowableBasis", "");
    field.factorOfSafety = root.numberOr("factorOfSafety", 1.5);
    field.boundingDiagonalM = root.numberOr("boundingDiagonalM", 0.0);
    field.maxDisplacementM = root.numberOr("maxDisplacementM", 0.0);
    std::vector<double> critical;
    if (readNumbers(root.member("criticalPoint"), critical) && critical.size() == 3) {
        field.criticalPoint = {critical[0], critical[1], critical[2]};
    }

    const JsonValue* presentation = root.member("presentation");
    if (presentation == nullptr || !presentation->isObject()) return invalid("нет presentation");
    if (!readStops(*presentation, field.colorStops)) return invalid("нет цветовой шкалы");
    if (!parseHex(presentation->stringOr("overflowColor", ""), field.overflowColor)) return invalid("нет цвета превышения");
    field.deformationAutoScale = presentation->numberOr("deformationAutoScale", 1.0);
    return Result<StructuralFieldFile>::ok(std::move(field));
}

Result<ModalFieldFile> parseModalField(const std::string& text) {
    auto bad = [](const std::string& message) {
        return Result<ModalFieldFile>::fail({ErrorCode::SerializationFailed, "файл форм мод: " + message});
    };
    JsonValue root;
    std::string error;
    if (!json::parseJson(text, root, error)) return bad("не JSON: " + error);
    if (root.stringOr("schema", "") != "cadnext-modal-field/1") return bad("неизвестная схема");

    ModalFieldFile field;
    std::vector<double> nodes, triangles;
    if (!readNumbers(root.member("nodes"), nodes) || !readNumbers(root.member("triangles"), triangles) || nodes.size() % 3 != 0) {
        return bad("нет nodes / triangles");
    }
    const std::size_t count = nodes.size() / 3;
    for (std::size_t n = 0; n < count; ++n) field.nodes.push_back({nodes[3 * n], nodes[3 * n + 1], nodes[3 * n + 2]});
    if (!readTriangles(triangles, count, field.triangles)) return bad("треугольник ссылается на несуществующий узел");

    const JsonValue* modes = root.member("modes");
    if (modes == nullptr || !modes->isArray() || modes->arrayItems.empty()) return bad("нет мод");
    for (const auto& item : modes->arrayItems) {
        ModalFieldMode mode;
        mode.frequencyHz = item.numberOr("frequencyHz", NAN);
        std::vector<double> shape;
        if (!std::isfinite(mode.frequencyHz) || !readNumbers(item.member("shape"), shape) || shape.size() != nodes.size()) {
            return bad("мода без частоты или с формой не того размера");
        }
        for (std::size_t n = 0; n < count; ++n) mode.shape.push_back({shape[3 * n], shape[3 * n + 1], shape[3 * n + 2]});
        field.modes.push_back(std::move(mode));
    }
    field.boundingDiagonalM = root.numberOr("boundingDiagonalM", 0.0);
    const JsonValue* presentation = root.member("presentation");
    if (presentation == nullptr || !presentation->isObject()) return bad("нет presentation");
    if (!readStops(*presentation, field.colorStops)) return bad("нет цветовой шкалы");
    field.displayAmplitudeM = presentation->numberOr("displayAmplitudeM", 0.0);
    if (!(field.displayAmplitudeM > 0.0)) return bad("нет экранной амплитуды");
    return Result<ModalFieldFile>::ok(std::move(field));
}

} // namespace cadnext::fea
