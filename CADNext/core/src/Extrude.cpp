#include "cadnext/Extrude.hpp"

#include <cmath>

namespace cadnext {

namespace {

Vector3 normalizedOrFallback(const Vector3& v, const Vector3& fallback) {
    const double length = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (!std::isfinite(length) || length <= 1.0e-12) {
        return fallback;
    }
    return {v.x / length, v.y / length, v.z / length};
}

} // namespace

bool extrudeParametersValid(const ExtrudeParameters& parameters) {
    if (parameters.sketchId.empty() || parameters.profileId.empty()) {
        return false;
    }
    return std::isfinite(parameters.distance) && parameters.distance > 0.0;
}

Vector3 extrudeDirectionVector(const SketchReference& reference, ExtrudeDirection direction) {
    const Vector3 normal = normalizedOrFallback(reference.normal, {0.0, 0.0, 1.0});
    if (direction == ExtrudeDirection::Negative) {
        return {-normal.x, -normal.y, -normal.z};
    }
    return normal;
}

void extrudeSpan(const ExtrudeParameters& parameters, double& startOffset, double& endOffset) {
    const double distance = std::isfinite(parameters.distance) ? parameters.distance : 0.0;
    switch (parameters.direction) {
    case ExtrudeDirection::Positive:
        startOffset = 0.0;
        endOffset = distance;
        return;
    case ExtrudeDirection::Negative:
        startOffset = -distance;
        endOffset = 0.0;
        return;
    case ExtrudeDirection::Symmetric:
        startOffset = -distance * 0.5;
        endOffset = distance * 0.5;
        return;
    }
    startOffset = 0.0;
    endOffset = distance;
}

const char* extrudeOperationName(ExtrudeOperation operation) {
    switch (operation) {
    case ExtrudeOperation::NewBody:
        return "NewBody";
    }
    return "NewBody";
}

ExtrudeOperation extrudeOperationFromName(const std::string& name) {
    (void)name; // only NewBody exists in v1
    return ExtrudeOperation::NewBody;
}

const char* extrudeDirectionName(ExtrudeDirection direction) {
    switch (direction) {
    case ExtrudeDirection::Positive: return "Positive";
    case ExtrudeDirection::Negative: return "Negative";
    case ExtrudeDirection::Symmetric: return "Symmetric";
    }
    return "Positive";
}

ExtrudeDirection extrudeDirectionFromName(const std::string& name) {
    if (name == "Negative") return ExtrudeDirection::Negative;
    if (name == "Symmetric") return ExtrudeDirection::Symmetric;
    return ExtrudeDirection::Positive;
}

const char* extrudeDepthModeName(ExtrudeDepthMode mode) {
    switch (mode) {
    case ExtrudeDepthMode::Distance:
        return "Distance";
    }
    return "Distance";
}

ExtrudeDepthMode extrudeDepthModeFromName(const std::string& name) {
    (void)name; // only Distance exists in v1
    return ExtrudeDepthMode::Distance;
}

} // namespace cadnext
