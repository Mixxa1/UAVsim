#include "cadnext/SketchInput.hpp"

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

} // namespace cadnext
