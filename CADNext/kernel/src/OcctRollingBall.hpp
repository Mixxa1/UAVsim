#pragma once

// Internal to the kernel: the OCCT construction of a constant-radius rolling-ball blend
// (RollingBallBlend in OcctKernel.hpp). No OCCT type leaves the kernel through this header.

#include "cadnext/kernel/OcctKernel.hpp"

#include <Geom_BSplineSurface.hxx>
#include <TopoDS_Edge.hxx>

#include <memory>
#include <string>

namespace cadnext::kernel::rolling_ball {

// The surface a blend face lies on, built once from its definition: a rational B-spline, quadratic
// across (each cross-section's arc exactly, at the sections), cubic along the spine.
class Blend {
public:
    explicit Blend(const RollingBallBlend& definition);
    ~Blend();
    Blend(const Blend&) = delete;
    Blend& operator=(const Blend&) = delete;

    // Null, with error() saying why, when the blend could not be built within 1e-6 m.
    Handle(Geom_BSplineSurface) surface() const;
    const std::string& error() const;
    // Largest distance of surface() from the rolling-ball definition over its check samples, m.
    double deviation() const;
    // Largest | distance of the source's spine from a support − radius |, m.
    double contactGap() const;
    // How far a point of the definition may be from surface(): deviation() + contactGap().
    double tolerance() const;
    int sections() const;
    // +1 when the blend's face turns along the surface's natural normal, -1 against it, 0 when no
    // support face tells (RollingBallBlend::supportFaceSense).
    int faceSense() const;
    // Nearest point on the procedural definition, with its natural loft normal. Used when another
    // blend takes this one as a support: differentiating an approximating loft would amplify its
    // small positional error in the support's offset. The two parameters carry the next search's seed.
    bool foot(const gp_Pnt& point, gp_Pnt& nearest, gp_Vec& normal, double& distance,
              double& position, double& angle) const;
    // The contact curve with support `boundary` (0 or 1) from segment.start to segment.end, or all
    // round a ring blend when the segment has no ends. Null when it cannot be built.
    TopoDS_Edge boundaryEdge(int boundary, const AnalyticEdgeSegment& segment) const;
    // An edge where the blend meets another surface, segment.intersectionSurfaces[1 − side] (the
    // blend being [side]): from the edge's XT chart, each point put exactly on both — the blend as
    // its definition, the ball's surface round the spine. Null when it cannot be built.
    TopoDS_Edge crossingEdge(const AnalyticEdgeSegment& segment, int side) const;
    // Why the last boundaryEdge() or crossingEdge() came back null.
    const std::string& edgeError() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// One solid may use a blend both as a face and as another blend's support. Share its construction
// for the duration of that solid, including nested supports. Each importing thread has its own cache.
class BuildScope {
public:
    BuildScope();
    ~BuildScope();
    BuildScope(const BuildScope&)=delete;
    BuildScope& operator=(const BuildScope&)=delete;
};
std::shared_ptr<const Blend> buildBlend(const std::shared_ptr<const RollingBallBlend>& definition);

// An edge where two surfaces meet (segment.intersectionSurfaces, neither a blend nor an edge), built
// as crossingEdge builds one across a blend: from the edge's XT chart, each point put on both surfaces
// by Newton, interpolated, and checked between the points to 1e-6 m (aiming at 1e-8). For the
// intersections OCCT's own does not follow through the edge's vertices (threads on helical B-spline
// surfaces). Null, with `why`, when it cannot be built.
TopoDS_Edge intersectionEdge(const AnalyticEdgeSegment& segment, std::string& why);

} // namespace cadnext::kernel::rolling_ball
