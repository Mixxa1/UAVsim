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

    // Endpoint snapping stays active with the grid off, and it takes
    // precedence over a nearby grid intersection when the grid is on.
    cadnext::Sketch sketch;
    cadnext::SketchEntity line;
    line.type = cadnext::SketchEntityType::Line;
    line.line = {{0.137, 0.263}, {0.8, 0.9}};
    sketch.entities.push_back(line);
    assertPoint(cadnext::applySketchSnap({0.14, 0.26}, options, sketch, 0.02),
                0.137, 0.263);
    options.snapToGrid = true;
    assertPoint(cadnext::applySketchSnap({0.14, 0.26}, options, sketch, 0.02),
                0.137, 0.263);
    assertPoint(cadnext::applySketchSnap({0.14, 0.26}, options, sketch, 0.001),
                0.1, 0.3);

    cadnext::SketchEntity arc;
    arc.type = cadnext::SketchEntityType::Arc;
    arc.arc.center = {2.0, 3.0};
    arc.arc.radius = 1.0;
    arc.arc.startAngleDegrees = 0.0;
    arc.arc.sweepDegrees = 90.0;
    sketch.entities.push_back(arc);
    options.snapToGrid = false;
    assertPoint(cadnext::applySketchSnap({3.01, 3.01}, options, sketch, 0.03),
                3.0, 3.0);
    assertPoint(cadnext::applySketchSnap({2.01, 4.01}, options, sketch, 0.03),
                2.0, 4.0);

    // Input state pending reset.
    cadnext::SketchInputState state;
    state.activeTool = cadnext::SketchTool::Line;
    state.phase = cadnext::SketchInputPhase::WaitingSecondPoint;
    state.firstPoint = cadnext::SketchPoint2D{1.0, 2.0};
    state.currentPoint = cadnext::SketchPoint2D{3.0, 4.0};
    state.lineChainStart = cadnext::SketchPoint2D{1.0, 2.0};
    state.lineChainSegments = 2;
    state.resetPending();
    assert(state.phase == cadnext::SketchInputPhase::Idle);
    assert(!state.firstPoint.has_value());
    assert(!state.currentPoint.has_value());
    assert(!state.lineChainStart.has_value());
    assert(state.lineChainSegments == 0);
    assert(state.activeTool == cadnext::SketchTool::Line);

    // A committed line starts the next one at exactly its endpoint, and
    // the third edge closes the chain at the stored starting coordinate.
    state.phase = cadnext::SketchInputPhase::WaitingSecondPoint;
    state.firstPoint = cadnext::SketchPoint2D{0, 0};
    state.lineChainStart = cadnext::SketchPoint2D{0, 0};
    assert(!state.completeLineSegment({1, 0}));
    assertPoint(*state.firstPoint, 1, 0);
    assert(!state.completeLineSegment({1, 1}));
    assertPoint(*state.firstPoint, 1, 1);
    assert(state.completeLineSegment({0, 0}));
    assert(state.phase == cadnext::SketchInputPhase::Idle);
    assert(!state.firstPoint.has_value());

    return 0;
}
