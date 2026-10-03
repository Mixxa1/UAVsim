#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <vector>
#include <optional>

// An exact solid as boundary topology with shared edges and vertices, in plain types: what a writer
// of a neutral BRep format (Parasolid XT) needs, without any OCCT type crossing the kernel boundary.
//
// It is the kernel's BRep in the form such formats hold it, which differs from OCCT's in two ways:
//   - no seam edges and no degenerate pole edges: a periodic surface closes on itself, a face on a
//     cylinder is bounded by its two circles alone, and the seam's remnants are re-chained into
//     loops by their vertices;
//   - every face knows which way it faces the material through `reversed` against the natural
//     normal of the surface as described (not as OCCT parametrised it).
// A full sphere, which has no boundary at all once its seam and poles are gone, is written as two
// hemispheres on an equator: a face without loops is something the XT reader of CADNext does not
// accept, so it is not produced either.
//
// Surfaces and curves are described the way readers of XT interpret them (and the CADNext reader,
// checked against real files, rebuilds them): a cone by its radius at the axis point and a positive
// half angle with the radius growing along the axis; B-spline poles u-major (v varying fastest);
// every open B-spline edge curve cut to exactly its edge, non-periodic. A periodic B-spline — a
// surface, or the curve of a closed edge — is given as XT keeps it: unwrapped, the knots continued
// periodically so that t_degree starts the period and t_n ends it, and the first poles repeated at
// the end (as many as degree + 1 − the seam knot's multiplicity); `bspline` then evaluates, as a
// non-periodic spline, to the same points over the same domain, and `periodic` marks it.
//
// A full torus is similarly split into two exact bands at opposite meridians.
// A boundaryless doubly closed NURBS surface is split into four exact parameter
// rectangles, with shared iso curves and their original linear UV laws.
// Refused, with the reason: sheet and wire bodies, offset and other procedural surfaces,
// non-manifold edges.

namespace cadnext::kernel {

struct DescribedCurve {
    enum class Kind { Line, Circle, Ellipse, BSpline } kind = Kind::Line;
    cadnext::Vector3 origin;    // point on a line; centre of a circle or ellipse
    cadnext::Vector3 direction; // line direction; circle or ellipse normal
    cadnext::Vector3 xAxis;     // circle zero angle; ellipse major axis
    double radius = 0.0;
    double majorRadius = 0.0;
    double minorRadius = 0.0;
    BSplineCurveDefinition bspline;
    bool periodic = false; // `bspline` unwrapped from a periodic curve, see above
};

struct DescribedSurface {
    // Swept: a section curve moved along `axis` (a unit vector), R(u, v) = C(u) + v·D — what OCCT
    // calls a surface of linear extrusion and XT a SWEPT_SURF.
    enum class Kind { Plane, Cylinder, Cone, Sphere, Torus, BSpline, Swept } kind = Kind::Plane;
    cadnext::Vector3 origin; // point on a plane / on an axis; centre of a sphere or torus
    cadnext::Vector3 axis;   // plane normal, or axis; sweep direction
    cadnext::Vector3 xAxis;
    double radius = 0.0;
    double sinHalfAngle = 0.0;
    double cosHalfAngle = 1.0;
    double majorRadius = 0.0;
    double minorRadius = 0.0;
    BSplineSurfaceDefinition bspline; // poles u-major: index u * vPoleCount + v
    bool uPeriodic = false;           // `bspline` unwrapped in that direction, see above
    bool vPeriodic = false;
    DescribedCurve section;           // of a swept surface
};

// An edge runs along its curve's natural direction, from `start` to `end` (equal for a closed edge).
// A full circle or ellipse that meets no other edge is a ring edge with no vertex at all (start and
// end -1), as Parasolid transmits one: OCCT's vertex on it is only an artefact of its parametrisation.
struct DescribedEdge {
    int curve = -1;
    int start = -1;
    int end = -1;
    double tolerance = 0.0; // the source edge and its endpoint vertices, metres
    double firstParameter = 0.0, lastParameter = 0.0; // retain the phase of closed conics
};

// Analytic boundary law on a plane, before rational spatial conversion.
// Hyperbola: O + a*cosh(t)*X + b*sinh(t)*Y.
// Parabola: O + t*t/(4*a)*X + t*Y, where a is the focal length.
// UV coordinates are metres; the two axes retain the source frame's handedness.
struct AnalyticPcurveDefinition {
    enum class Kind { Hyperbola, Parabola } kind = Kind::Hyperbola;
    cadnext::Vector3 origin, xAxis, yAxis;
    double a = 0, b = 0;
    double first = 0, last = 0;
};

struct DescribedCoedge {
    int edge = -1;
    bool forward = true; // traversed along the edge
    // The source boundary in the support's UV frame, in metres for length coordinates. Its
    // parameter runs along the 3D edge, independently of this coedge's traversal direction.
    std::optional<BSplineCurveDefinition> pcurve;
    std::optional<AnalyticPcurveDefinition> analyticPcurve;
};

// Loops run with the face on their left, looking against the face normal.
struct DescribedFace {
    int surface = -1;
    bool reversed = false; // face normal opposite the surface's natural normal
    std::vector<std::vector<DescribedCoedge>> loops;
};

// One connected piece of material: its outer boundary first, then the boundary of each cavity.
struct DescribedLump {
    std::vector<std::vector<int>> shells;
};

struct ExactBRepDescription {
    std::vector<cadnext::Vector3> vertices;
    std::vector<DescribedCurve> curves;
    std::vector<DescribedEdge> edges;
    std::vector<DescribedSurface> surfaces;
    std::vector<DescribedFace> faces;
    std::vector<DescribedLump> lumps;
    // Largest distance between a vertex and the end of a curve that meets it, metres: how far the
    // BRep is from being accurate in the sense of a modeller with a linear precision of 1e-8 m.
    double largestVertexGap = 0.0;
};

enum class ConeParameterization {
    PositiveAngle, // XT convention: radius grows along the axis.
    SourceFrame    // Preserve the reference circle and signed angle for C3D UV.
};

cadnext::Result<ExactBRepDescription> describeExactBRep(
    const OcctKernel& kernel, const ShapeHandle& shape,
    ConeParameterization coneParameterization = ConeParameterization::PositiveAngle);

} // namespace cadnext::kernel
