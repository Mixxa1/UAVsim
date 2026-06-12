#pragma once

#include <optional>

#include "cadnext/Sketch.hpp"

namespace cadnext {

// Sketch input UX model (cursor, snap-to-grid, live preview). This is pure
// state/math shared by the GUI and the tests; all viewer visuals derived
// from it are transient and never serialized.

// Snap steps below this are treated as "too fine to be useful" and are
// clamped up; non-finite or non-positive steps disable snapping entirely.
inline constexpr double kMinSketchGridStep = 0.001;

struct SketchInputOptions {
    bool snapToGrid = true;
    double gridStep = 0.1;
    bool showSketchGrid = true;
    bool showSketchCursor = true;
    bool showLivePreview = true;
};

// Rounds `raw` to the nearest grid intersection. Invalid input is returned
// unchanged: non-finite coordinates, and non-finite or non-positive grid
// steps (steps in (0, kMinSketchGridStep) are clamped to the minimum).
SketchPoint2D snapPointToGrid(SketchPoint2D raw, double gridStep);

// Applies options: returns the snapped point when snapToGrid is enabled,
// the raw point otherwise.
SketchPoint2D applySketchSnap(SketchPoint2D raw, const SketchInputOptions& options);

enum class SketchTool {
    Select,
    Line,
    Rectangle,
    Circle
};

enum class SketchInputPhase {
    Idle,
    WaitingSecondPoint
};

// Two-click tool input state. firstPoint/currentPoint are already snapped;
// the state resets on tool change, Esc and Exit Sketch.
struct SketchInputState {
    SketchTool activeTool = SketchTool::Select;
    SketchInputPhase phase = SketchInputPhase::Idle;

    std::optional<SketchPoint2D> firstPoint;
    std::optional<SketchPoint2D> currentPoint;

    SketchInputOptions options;

    void resetPending() {
        phase = SketchInputPhase::Idle;
        firstPoint.reset();
        currentPoint.reset();
    }
};

} // namespace cadnext
