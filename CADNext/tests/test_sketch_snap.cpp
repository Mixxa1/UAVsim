#include "cadnext/SketchInput.hpp"

#include <cassert>
#include <cmath>
#include <limits>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

void assertPoint(cadnext::SketchPoint2D point, double u, double v) {
    assert(nearlyEqual(point.u, u));
    assert(nearlyEqual(point.v, v));
}

} // namespace

int main() {
    constexpr double kNan = std::numeric_limits<double>::quiet_NaN();
    constexpr double kInf = std::numeric_limits<double>::infinity();

    // Basic rounding to the nearest grid intersection.
    assertPoint(cadnext::snapPointToGrid({0.03, 0.07}, 0.1), 0.0, 0.1);
    assertPoint(cadnext::snapPointToGrid({0.14, 0.26}, 0.1), 0.1, 0.3);
    assertPoint(cadnext::snapPointToGrid({1.0, 2.0}, 0.1), 1.0, 2.0);
    assertPoint(cadnext::snapPointToGrid({0.75, 1.25}, 0.5), 1.0, 1.5);

    // Negative coordinates round toward the nearest intersection too.
    assertPoint(cadnext::snapPointToGrid({-0.03, -0.07}, 0.1), 0.0, -0.1);
    assertPoint(cadnext::snapPointToGrid({-0.14, -0.26}, 0.1), -0.1, -0.3);

    // Invalid grid steps fall back to the raw point.
    assertPoint(cadnext::snapPointToGrid({0.14, 0.26}, 0.0), 0.14, 0.26);
    assertPoint(cadnext::snapPointToGrid({0.14, 0.26}, -1.0), 0.14, 0.26);
    assertPoint(cadnext::snapPointToGrid({0.14, 0.26}, kNan), 0.14, 0.26);
    assertPoint(cadnext::snapPointToGrid({0.14, 0.26}, kInf), 0.14, 0.26);

    // Steps below the minimum are clamped to kMinSketchGridStep.
    assertPoint(cadnext::snapPointToGrid({0.01234, 0.0}, 0.0001),
                std::round(0.01234 / cadnext::kMinSketchGridStep) * cadnext::kMinSketchGridStep,
                0.0);

    // Non-finite coordinates are passed through untouched (the GUI layer
    // discards them before they reach any entity).
    {
        const cadnext::SketchPoint2D snapped = cadnext::snapPointToGrid({kNan, 1.0}, 0.1);
        assert(std::isnan(snapped.u));
        assert(nearlyEqual(snapped.v, 1.0));
    }

    // applySketchSnap honors the snapToGrid toggle.
    cadnext::SketchInputOptions options;
    options.snapToGrid = true;
    options.gridStep = 0.1;
    assertPoint(cadnext::applySketchSnap({0.14, 0.26}, options), 0.1, 0.3);
    options.snapToGrid = false;
    assertPoint(cadnext::applySketchSnap({0.14, 0.26}, options), 0.14, 0.26);

    // Input state pending reset.
    cadnext::SketchInputState state;
    state.activeTool = cadnext::SketchTool::Line;
    state.phase = cadnext::SketchInputPhase::WaitingSecondPoint;
    state.firstPoint = cadnext::SketchPoint2D{1.0, 2.0};
    state.currentPoint = cadnext::SketchPoint2D{3.0, 4.0};
    state.resetPending();
    assert(state.phase == cadnext::SketchInputPhase::Idle);
    assert(!state.firstPoint.has_value());
    assert(!state.currentPoint.has_value());
    assert(state.activeTool == cadnext::SketchTool::Line);

    return 0;
}
