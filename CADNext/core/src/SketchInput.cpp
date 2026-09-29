#include "cadnext/SketchInput.hpp"
#include "cadnext/SketchProfile.hpp"

#include <cmath>

namespace cadnext {

SketchPoint2D snapPointToGrid(SketchPoint2D raw, double gridStep) {
    if (!std::isfinite(raw.u) || !std::isfinite(raw.v)) {
        return raw;
    }
    if (!std::isfinite(gridStep) || gridStep <= 0.0) {
        return raw;
    }
    const double step = std::max(gridStep, kMinSketchGridStep);
    return {std::round(raw.u / step) * step, std::round(raw.v / step) * step};
}

SketchPoint2D applySketchSnap(SketchPoint2D raw, const SketchInputOptions& options) {
    if (!options.snapToGrid) {
        return raw;
    }
    return snapPointToGrid(raw, options.gridStep);
}

std::optional<SketchPoint2D> nearestSketchLineEndpoint(
    SketchPoint2D raw, const Sketch& sketch, double radius) {
    if (!std::isfinite(raw.u) || !std::isfinite(raw.v) ||
        !std::isfinite(radius) || radius <= 0.0) {
        return std::nullopt;
    }
    std::optional<SketchPoint2D> nearest;
    double bestSquared = radius * radius;
    for (const SketchEntity& entity : sketch.entities) {
        if (entity.type != SketchEntityType::Line && entity.type != SketchEntityType::Arc)
            continue;
        const SketchPoint2D start = entity.type == SketchEntityType::Arc
            ? sketchArcStart(entity.arc) : entity.line.start;
        const SketchPoint2D end = entity.type == SketchEntityType::Arc
            ? sketchArcEnd(entity.arc) : entity.line.end;
        for (const SketchPoint2D point : {start, end}) {
            if (!std::isfinite(point.u) || !std::isfinite(point.v)) {
                continue;
            }
            const double du = raw.u - point.u;
            const double dv = raw.v - point.v;
            const double squared = du * du + dv * dv;
            if (squared <= bestSquared) {
                bestSquared = squared;
                nearest = point;
            }
        }
    }
    return nearest;
}

SketchPoint2D applySketchSnap(SketchPoint2D raw, const SketchInputOptions& options,
                              const Sketch& sketch, double endpointRadius) {
    if (const auto endpoint = nearestSketchLineEndpoint(raw, sketch, endpointRadius)) {
        return *endpoint;
    }
    return applySketchSnap(raw, options);
}

bool SketchInputState::completeLineSegment(SketchPoint2D endpoint) {
    const bool closed = lineChainStart && lineChainSegments >= 2 &&
        std::hypot(endpoint.u - lineChainStart->u,
                   endpoint.v - lineChainStart->v) <= kSketchEndpointTolerance;
    ++lineChainSegments;
    if (closed) {
        resetPending();
    } else {
        phase = SketchInputPhase::WaitingSecondPoint;
        firstPoint = endpoint;
        currentPoint = endpoint;
    }
    return closed;
}

} // namespace cadnext
