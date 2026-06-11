#pragma once

#include <string>
#include <vector>

#include "cadnext/Sketch.hpp"

namespace cadnext {

// Profile detection v1 (CADNext 0.6). Profiles are closed regions found in
// a sketch; they are the input of the Sketch → Profile → Extrude workflow.
// No nesting, holes or multi-loop graph solving yet.
enum class SketchProfileKind {
    Rectangle,
    Circle,
    Polygon,
    Unsupported
};

struct SketchProfile {
    std::string id;
    std::string sketchId;
    SketchProfileKind kind = SketchProfileKind::Unsupported;
    // Closed outer boundary in sketch u/v (last point != first point;
    // circles are stored as a polygonal approximation).
    std::vector<SketchPoint2D> outerLoop;
    // Rectangle/Circle: the single source entity. Polygon: empty.
    std::string sourceEntityId;
    // Polygon: the line entities forming the loop, in chain order.
    std::vector<std::string> sourceEntityIds;
    double area = 0.0;
    bool isClosed = false;
    bool isValid = false;
};

class SketchProfileDetector {
public:
    // Rectangle/Circle entities each yield one profile. Line entities are
    // checked for one sequential closed chain (entity order, endpoints
    // matched with a small tolerance) — no graph solving in v1. Open
    // chains and self-intersecting loops yield no valid profile.
    std::vector<SketchProfile> detect(const Sketch& sketch) const;
};

// --- Simple-polygon helpers ------------------------------------------------
// Shared by the detector (validity), the prism mesh builder (caps) and the
// viewer (profile fill / click-inside-profile picking).

// True when any two non-adjacent edges of the closed loop intersect.
bool polygonIsSelfIntersecting(const std::vector<SketchPoint2D>& loop);

// Ear-clipping triangulation of a simple polygon (either winding).
// Returns flat index triples into `loop`; empty for degenerate or
// self-intersecting input.
std::vector<unsigned int> triangulatePolygon(const std::vector<SketchPoint2D>& loop);

// Ray-casting point-in-polygon test (boundary counts as inside).
bool polygonContainsPoint(const std::vector<SketchPoint2D>& loop, const SketchPoint2D& point);

} // namespace cadnext
