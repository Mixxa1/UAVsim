#pragma once

#include <string>
#include <vector>

#include "cadnext/Sketch.hpp"

namespace cadnext {

// Profile detection v2 (CADNext 0.7). Profiles are closed regions found in
// a sketch; they are the input of the Extrude / Cut Extrude workflows.
// Detection is stateless: every call rebuilds profiles from the committed
// sketch entities only — no cache, no transient/preview geometry, never a
// stale entity id.
enum class SketchProfileKind {
    Rectangle,
    Circle,
    Polygon,
    Unsupported
};

enum class SketchProfileInvalidReason {
    None,
    SelfIntersecting
};

// Endpoint clustering tolerance for line-loop detection: two endpoints
// closer than this are the same loop vertex.
inline constexpr double kSketchEndpointTolerance = 1.0e-5;

struct SketchProfile {
    // Deterministic, content-derived id: "profile-<entityId>" for
    // rectangle/circle profiles, "profile-poly-<fnv1a of sorted entity
    // ids>" for line loops. Deleting a source line therefore removes the
    // old profile id on the next rebuild.
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
    SketchProfileInvalidReason invalidReason = SketchProfileInvalidReason::None;
};

class SketchProfileDetector {
public:
    // Rectangle/Circle entities each yield one profile. Line entities are
    // clustered by endpoints (kSketchEndpointTolerance) into a graph;
    // every connected component whose vertices all have degree 2 forms a
    // simple loop, independent of the order the lines were drawn in, and
    // multiple separate loops are all reported. Open chains and branching
    // components yield nothing; a closed but self-intersecting loop
    // (bow-tie) is reported with isValid=false /
    // SketchProfileInvalidReason::SelfIntersecting so the GUI can explain
    // why it cannot be extruded.
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
