#include "cadnext/ExtrudeCut.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext {

namespace {

Result<CutSpan> spanError(std::string message) {
    return Result<CutSpan>::fail({ErrorCode::InvalidArgument, std::move(message)});
}

} // namespace

bool extrudeCutParametersValid(const ExtrudeCutParameters& parameters) {
    if (parameters.targetBodyId.empty() || parameters.sketchId.empty() ||
        parameters.profileId.empty()) {
        return false;
    }
    switch (parameters.depthMode) {
    case CutDepthMode::Distance:
        return std::isfinite(parameters.distance) && parameters.distance > 0.0;
    case CutDepthMode::ThroughAll:
        return true;
    case CutDepthMode::ToObject:
        return !parameters.limitObjectId.empty() &&
               parameters.direction != CutDirection::Symmetric;
    }
    return false;
}

Result<CutSpan> computeCutSpan(const ExtrudeCutParameters& parameters,
                               const CutExtents& extents) {
    if (!extrudeCutParametersValid(parameters)) {
        return spanError("Cut parameters are invalid");
    }

    CutSpan span;
    switch (parameters.depthMode) {
    case CutDepthMode::Distance: {
        const double distance = parameters.distance;
        switch (parameters.direction) {
        case CutDirection::Positive:
            span = {0.0, distance};
            break;
        case CutDirection::Negative:
            span = {-distance, 0.0};
            break;
        case CutDirection::Symmetric:
            span = {-distance * 0.5, distance * 0.5};
            break;
        }
        return Result<CutSpan>::ok(span);
    }

    case CutDepthMode::ThroughAll: {
        // Guaranteed past the target on the cut side(s): margin grows with
        // the body diagonal so the cutter can never end inside the body.
        const double margin = std::max(extents.targetDiagonal, 0.0) + 1.0;
        switch (parameters.direction) {
        case CutDirection::Positive:
            span = {0.0, std::max(extents.targetMax, 0.0) + margin};
            break;
        case CutDirection::Negative:
            span = {std::min(extents.targetMin, 0.0) - margin, 0.0};
            break;
        case CutDirection::Symmetric:
            span = {std::min(extents.targetMin, 0.0) - margin,
                    std::max(extents.targetMax, 0.0) + margin};
            break;
        }
        return Result<CutSpan>::ok(span);
    }

    case CutDepthMode::ToObject: {
        if (!extents.hasLimit) {
            return spanError("Limit object bounds are not available");
        }
        // Up to the near face of the limit object's AABB along the cut
        // direction (v1 contract).
        if (parameters.direction == CutDirection::Positive) {
            if (extents.limitMin <= 0.0) {
                return spanError("Selected limit object is not in cut direction.");
            }
            span = {0.0, extents.limitMin};
        } else {
            if (extents.limitMax >= 0.0) {
                return spanError("Selected limit object is not in cut direction.");
            }
            span = {extents.limitMax, 0.0};
        }
        return Result<CutSpan>::ok(span);
    }
    }
    return spanError("Unsupported cut depth mode");
}

const char* cutDepthModeName(CutDepthMode mode) {
    switch (mode) {
    case CutDepthMode::Distance: return "Distance";
    case CutDepthMode::ThroughAll: return "ThroughAll";
    case CutDepthMode::ToObject: return "ToObject";
    }
    return "Distance";
}

CutDepthMode cutDepthModeFromName(const std::string& name) {
    if (name == "ThroughAll") return CutDepthMode::ThroughAll;
    if (name == "ToObject") return CutDepthMode::ToObject;
    return CutDepthMode::Distance;
}

const char* cutDirectionName(CutDirection direction) {
    switch (direction) {
    case CutDirection::Positive: return "Positive";
    case CutDirection::Negative: return "Negative";
    case CutDirection::Symmetric: return "Symmetric";
    }
    return "Positive";
}

CutDirection cutDirectionFromName(const std::string& name) {
    if (name == "Negative") return CutDirection::Negative;
    if (name == "Symmetric") return CutDirection::Symmetric;
    return CutDirection::Positive;
}

} // namespace cadnext
