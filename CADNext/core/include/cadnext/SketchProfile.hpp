#pragma once

#include <string>
#include <vector>

#include "cadnext/Sketch.hpp"

namespace cadnext {

// Profile detection v1 (CADNext 0.5). Profiles are closed regions found in
// a sketch; they exist for display and as the input for the future
// Sketch → Face → Extrude workflow (CADNext 0.6). No nesting, holes or
// intersection handling yet.
enum class SketchProfileKind {
    Rectangle,
    Circle,
    ClosedLoop,
    Unsupported
};

struct SketchProfile {
    std::string id;
    SketchProfileKind kind = SketchProfileKind::Unsupported;
    std::vector<SketchPoint2D> outerLoop;
    double area = 0.0;
};

class SketchProfileDetector {
public:
    // Rectangle/Circle entities each yield one profile. Line entities are
    // checked for one sequential closed chain (entity order, endpoints
    // matched with a small tolerance) — no graph solving in v1.
    std::vector<SketchProfile> detect(const Sketch& sketch) const;
};

} // namespace cadnext
