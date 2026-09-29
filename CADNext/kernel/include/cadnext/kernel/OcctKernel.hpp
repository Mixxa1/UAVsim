#pragma once

#include <memory>
#include <optional>
#include <array>
#include <limits>
#include <string>

#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/Transform.hpp"

#ifdef CADNEXT_WITH_OCCT
class TopoDS_Shape;
#endif

namespace cadnext::kernel {

struct ExchangeBody {
    ShapeHandle shape;
    cadnext::Transform placement;
};

struct NamedExchangeBody {
    std::string name;
    ExchangeBody body;
};

struct ImportedExchangeBody {
    std::string name;
    ShapeHandle shape;
};

// Exact planar patches with polygonal boundaries, in the kernel's model units.
// A collection of patches is a surface compound, not a closed solid.
struct PlanarFacePatch {
    std::vector<cadnext::Vector3> outline;
    cadnext::Vector3 planeOrigin;
    cadnext::Vector3 planeNormal;
};

// BlendBoundary: where a rolling-ball blend touches one of its supports (XT: the intersection of the
// support with a BLEND_BOUND) — `blend` and `blendBoundary` (0 or 1, the support) say which.
// SurfaceCurve: a curve in a surface's parameters (XT SP_CURVE) — `bspline` in (u, v) with z = 0,
// on intersectionSurfaces[0], from parameter curveFirst to curveLast.
enum class AnalyticEdgeKind { Line, Circle, Ellipse, SurfaceIntersection, BSpline, BlendBoundary, SurfaceCurve };

struct RollingBallBlend;
struct AnalyticEdgeSegment;

struct BSplineCurveDefinition {
    int degree = 0;
    bool periodic = false;
    std::vector<cadnext::Vector3> poles;
    std::vector<double> weights;
    std::vector<double> knots;
    std::vector<int> multiplicities;
};

struct BSplineSurfaceDefinition {
    int uDegree = 0;
    int vDegree = 0;
    int uPoleCount = 0;
    int vPoleCount = 0;
    bool uPeriodic = false;
    bool vPeriodic = false;
    std::vector<cadnext::Vector3> poles;
    std::vector<double> weights;
    std::vector<double> uKnots;
    std::vector<double> vKnots;
    std::vector<int> uMultiplicities;
    std::vector<int> vMultiplicities;
};

struct AnalyticSurfaceSupport {
    // BSpline: `bspline` itself, its grid as XT stores it. Blend: the surface of `blend`. Edge: a
    // sharp edge a blend's ball touches instead of a surface (XT blend type 'E', the edge given as
    // a zero-radius blend) — `edge`, a line, circle, ellipse or B-spline. Swept: `edge` (the
    // section) moved along `normal`, R(u, v) = C(u) + v·D as XT's SWEPT_SURF.
    enum class Kind { Plane, Cylinder, Cone, Sphere, Torus, BSplineOffset, BSpline, Blend, Edge, Swept } kind = Kind::Plane;
    std::shared_ptr<const RollingBallBlend> blend;
    std::shared_ptr<const AnalyticEdgeSegment> edge;
    cadnext::Vector3 origin;
    cadnext::Vector3 normal;
    cadnext::Vector3 xAxis;
    double radius = 0.0;
    double semiAngle = 0.0;
    double majorRadius = 0.0;
    double minorRadius = 0.0;
    BSplineSurfaceDefinition bspline;
    double offsetDistance = 0.0;
};

struct AnalyticEdgeSegment {
    // Shared source topology within one makeAnalyticSolid call (0 where an importer has none).
    // Coedges of this id use one 3D edge; their traversal direction may differ.
    std::uint64_t sourceId = 0;
    AnalyticEdgeKind kind = AnalyticEdgeKind::Line;
    cadnext::Vector3 start;
    cadnext::Vector3 end;
    bool hasEndpoints = true;
    bool forward = true;
    cadnext::Vector3 center;
    cadnext::Vector3 normal;
    cadnext::Vector3 xAxis;
    double radius = 0.0;
    double majorRadius = 0.0;
    double minorRadius = 0.0;
    std::array<AnalyticSurfaceSupport, 2> intersectionSurfaces{};
    // A point of an intersection edge (its XT chart's first point): which branch it is when the two
    // surfaces meet in several, as two crossing cylinders do.
    bool hasBranchPoint = false;
    cadnext::Vector3 branchPoint;
    // The intersection's XT chart, in the curve's order: an edge across a blend is built from it, and
    // any intersection edge whose surfaces OCCT's intersection does not follow through its vertices.
    // Closed: it goes all round (its start LIMIT of type 'H'). A terminator end (LIMIT 'T', where the
    // surfaces touch) is the chart's first or last point.
    std::vector<cadnext::Vector3> chart;
    bool chartClosed = false;
    std::array<bool, 2> chartTerminators{};
    // A SurfaceCurve's 2D range or an exact BSpline's prescribed 3D range; equal means unset.
    double curveFirst = 0.0;
    double curveLast = 0.0;
    // A tolerant edge's own tolerance (XT EDGE.tolerance), 0 for an exact edge: how far the curves
    // its faces hold for it may be apart.
    double tolerance = 0.0;
    BSplineCurveDefinition bspline;
    // Optional explicit boundary on this face in its native UV frame, poles (u,v,0). Kept along
    // the 3D curve's parameter; it prevents reprojection from changing a tolerant boundary.
    std::optional<BSplineCurveDefinition> pcurve;
    // XT SP curves can use independent parameters on the same EDGE. In that case
    // verify their geometric locus before reparameterising against the shared 3D curve.
    bool pcurveIndependentParameter = false;
    std::shared_ptr<const RollingBallBlend> blend;
    int blendBoundary = 0;
};

// A constant-radius rolling-ball blend (XT BLENDED_EDGE, type 'R'): a ball of `radius` rolls along
// the spine touching both supports; the blend is the arc of each cross-section between the two
// contact points. Its surface is not a closed form, so the kernel builds a rational B-spline from
// this definition and measures how far it departs from it (AnalyticSolidReport).
struct RollingBallBlend {
    std::array<AnalyticSurfaceSupport, 2> supports{};
    // The spine's signed distance from each support, along the support's natural normal.
    std::array<double, 2> offsets{};
    double radius = 0.0;
    // Line (center = a point, normal = direction), Circle, Ellipse, BSpline, or SurfaceIntersection
    // of the two offset supports with `spineChart`, the intersection's chart points in order.
    AnalyticEdgeSegment spine;
    std::vector<cadnext::Vector3> spineChart;
    // A source curve supplied only as an approximate chart (ACIS offintcur). The kernel projects
    // it onto both offset supports before using it; the source chart alone is never the spine.
    bool spineChartApproximate = false;
    bool spineClosed = false; // an intersection spine that closes on itself (XT: a 'help' limit)
    // The chart's first / last point is a terminator (XT limit 'T'): a singular point where the two
    // surfaces touch and the blend narrows to nothing — exact, but no Newton step converges there.
    std::array<bool, 2> spineTerminators{false, false};
    // Where the blend's faces lie along the spine: each boundary edge of those faces as its start,
    // a point inside it when one is known exactly (nothing otherwise), and its end. Empty for a
    // ring blend all the way round a closed spine.
    std::vector<std::vector<cadnext::Vector3>> faceEdges;
    // The side each support's own face turns to: +1 along the support's natural normal, -1 against
    // it, 0 when no face of the body lies on that support next to the blend.
    std::array<int, 2> supportFaceSense{0, 0};
    // A variable radius (ACIS srfsrfblndsur, "single_radius functional"): the radius the x of this
    // 2D B-spline over the spine's own parameter (a BSpline spine's). The spine is then a guide, not
    // the ball's centre: the centre lies in the plane square to the spine at the spine's point, at
    // the law's radius from both supports, on the sides the offsets' signs say (both 0: the sides
    // the spine itself lies on); `radius` is the largest. The cross-section is the ball's arc
    // between its two contact points. Empty: the constant `radius`, the spine the centre.
    BSplineCurveDefinition radiusLaw;
};

struct AnalyticFacePatch {
    // Swept: a section curve moved along a direction (XT SWEPT_SURF, R(u, v) = C(u) + v·D) —
    // `section` holds the curve (its start/end unused), `sweep` the unit direction D.
    // Blend: the surface of `blend` (built approximately, see RollingBallBlend).
    enum class Kind { Plane, Cylinder, Cone, Sphere, Torus, BSpline, BSplineOffset, Swept, Blend } kind = Kind::Plane;
    AnalyticEdgeSegment section;
    cadnext::Vector3 sweep;
    std::shared_ptr<const RollingBallBlend> blend;
    cadnext::Vector3 origin;
    cadnext::Vector3 normal; // Plane normal or cylinder axis.
    cadnext::Vector3 xAxis;
    double radius = 0.0;
    double semiAngle = 0.0;
    double majorRadius = 0.0;
    double minorRadius = 0.0;
    bool reversed = false;
    BSplineSurfaceDefinition bspline;
    double offsetDistance = 0.0;
    std::vector<std::vector<AnalyticEdgeSegment>> loops;
    // A procedural surface converted to a B-spline by an importer: measured deviation from its
    // source definition, m. The builder includes this in trimming, sewing and its approximation report.
    double approximationDeviation = 0.0;
    // A cone's face running up to its apex (ACIS: a loop of one curveless edge there), bounded only by a
    // ring round the axis: its support is split up to the apex itself and the apex's side kept.
    bool holdsApex = false;
};

// Faces of an analytic solid that are not exact: what was built instead and how far it may be off.
struct ApproximatedAnalyticFace {
    std::size_t patchIndex = 0;
    // Largest distance of the built surface from its definition, over a sampling of it, m.
    double deviation = 0.0;
    // Largest | distance of the source's spine from a support − radius |, m: how exactly the source
    // file itself satisfies the blend's definition. The face is accepted at deviation + contactGap.
    double contactGap = 0.0;
    int sections = 0;
};

struct AnalyticSolidReport {
    std::vector<ApproximatedAnalyticFace> approximated;
    // The largest tolerance of a tolerant edge or vertex met (each face on its own curve, within that
    // of each other), m; the faces are sewn within twice it.
    double largestEdgeTolerance = 0.0;
    // Faces winding round a periodic surface more than once (a thread's root), which OCCT holds
    // only as one face per turn: the patch, and how many faces it became.
    struct SplitFace {
        std::size_t patchIndex = 0;
        int faces = 0;
    };
    std::vector<SplitFace> split;
    // Where a build failed: the patch being built then, or none (max) when it failed after them all.
    std::size_t failedPatch = std::numeric_limits<std::size_t>::max();
};

// OCCT-backed kernel. The BRep shapes live in an internal registry keyed
// by the ShapeHandle id; OCCT types never appear in the public core model,
// in Object, in the GUI, or in serialized .cadnext files.
//
// booleanCut runs the topological BRepAlgoAPI_Cut (CADNext 0.7 Cut
// Extrude); fuse/common remain unimplemented until they are needed.
class OcctKernel final : public Kernel {
public:
    OcctKernel();
    ~OcctKernel() override;

    OcctKernel(const OcctKernel&) = delete;
    OcctKernel& operator=(const OcctKernel&) = delete;

    cadnext::Result<ShapeHandle> makeBox(const BoxParameters& params) override;
    cadnext::Result<ShapeHandle> makeCylinder(const CylinderParameters& params) override;
    cadnext::Result<ShapeHandle> makeSphere(const SphereParameters& params) override;
    cadnext::Result<ShapeHandle> makeExtrudedPolygon(
        const ExtrudedPolygonParameters& params) override;
    cadnext::Result<ShapeHandle> makeExtrudedCircle(
        const ExtrudedCircleParameters& params) override;
    cadnext::Result<ShapeHandle> makeExtrudedCurvedProfile(
        const ExtrudedCurvedProfileParameters& params) override;
    cadnext::Result<ShapeHandle> makeRevolvedProfile(
        const RevolvedProfileParameters& params) override;
    cadnext::Result<ShapeHandle> cutThread(const ShapeHandle& body, const ThreadCutParameters& params,
                                           ThreadCutReport* report = nullptr) override;
    // Whether there is air just past each end of a cylindrical or conical face (past axialStart, past
    // axialEnd): a free end a thread can run out through, rather than a shoulder or a blind hole's bottom.
    // Probed half a millimetre (a tenth of the face, if shorter) past the end, a twentieth of the radius
    // into where the material would be, at four angles.
    std::array<bool, 2> faceEndsFree(const ShapeHandle& body, const cadnext::Vector3& axisOrigin,
                                     const cadnext::Vector3& axisDirection, double radius, double slope,
                                     double axialStart, double axialEnd, bool holeWall) const;
    cadnext::Result<ShapeHandle> booleanFuse(const ShapeHandle& a, const ShapeHandle& b) override;
    cadnext::Result<ShapeHandle> booleanCut(const ShapeHandle& target, const ShapeHandle& tool) override;
    cadnext::Result<ShapeHandle> booleanCommon(const ShapeHandle& a, const ShapeHandle& b) override;
    cadnext::Result<ShapeHandle> chamferEdges(const ShapeHandle& target,
                                              const std::vector<std::string>& edgeIds,
                                              double distance,
                                              cadnext::ChamferMode mode,
                                              double angleDeg) override;
    cadnext::Result<ShapeHandle> filletEdges(const ShapeHandle& target,
                                             const std::vector<std::string>& edgeIds,
                                             double radius) override;
    cadnext::Result<ShapeBounds> boundingBox(const ShapeHandle& shape) override;
    cadnext::Result<ShapeMassProperties> volumeProperties(const ShapeHandle& shape) override;
    cadnext::Result<std::vector<std::uint8_t>> exportBRep(const ShapeHandle& shape) override;
    cadnext::Result<std::vector<std::uint8_t>> exportBRepGeometry(const ShapeHandle& shape) override;
    cadnext::Result<ShapeHandle> importBRep(const std::vector<std::uint8_t>& brepData) override;
    cadnext::Result<ShapeHandle> importFreeCadBRep(
        const std::vector<std::uint8_t>& brepData, bool binary = false);
    cadnext::Result<ShapeHandle> makePlanarFaceCompound(
        const std::vector<PlanarFacePatch>& patches);
    // Sew a complete set of exact polygonal planar faces into one closed
    // solid. Open, disconnected, and non-manifold surfaces are rejected.
    cadnext::Result<ShapeHandle> makePlanarSolid(
        const std::vector<PlanarFacePatch>& patches);
    // Rebuild native BRep from exact analytic surfaces and their supported
    // line/circle/ellipse boundaries. Rejects any open or invalid shell. Blend faces are built to
    // within 1e-6 m of their definition or refused; `report` lists them with their deviation.
    cadnext::Result<ShapeHandle> makeAnalyticSolid(
        const std::vector<AnalyticFacePatch>& patches, AnalyticSolidReport* report = nullptr);
    cadnext::Result<ShapeHandle> transformShape(
        const ShapeHandle& shape, const std::array<double, 16>& columnMajorMatrix);
    // Apply a document body's scale, Euler rotation and translation, in metres. Shared by writers
    // so every exchange format uses the same placement order as STEP and FreeCAD.
    cadnext::Result<ShapeHandle> placeExchangeBody(const ExchangeBody& body);
    // FreeCAD stores OCCT BRep coordinates in millimetres. Apply the CADNext
    // object placement and convert the kernel's metres before serialization.
    cadnext::Result<std::vector<std::uint8_t>> exportFreeCadBRep(
        const ExchangeBody& body);
    // Neutral CAD exchange. STEP/IGES files use millimetres; the kernel
    // registry and CADNext document use metres.
    cadnext::Result<ShapeHandle> importExchangeFile(const std::string& path);
    cadnext::Result<bool> exportExchangeFile(const std::vector<ExchangeBody>& shapes,
                                             const std::string& path);
    // STEP assembly exchange preserves individual body names and placements.
    cadnext::Result<std::vector<ImportedExchangeBody>> importStepAssembly(
        const std::string& path);
    cadnext::Result<bool> exportStepAssembly(
        const std::vector<NamedExchangeBody>& bodies, const std::string& path);
    bool isShapeValid(const ShapeHandle& shape) const override;

    bool isAvailable() const;

#ifdef CADNEXT_WITH_OCCT
    // Internal accessor for the OCCT mesh extractor. Returns nullptr for
    // unknown handles. Never exposed beyond OCCT-enabled kernel code.
    const TopoDS_Shape* findShape(const ShapeHandle& handle) const;
    // Registers a shape built by OCCT-enabled code outside the kernel (the flow domain's boolean with
    // face history). The prefix names the handle, like the kernel's own "occt-cut-<n>".
    ShapeHandle adoptShape(const TopoDS_Shape& shape, const char* prefix);
#endif

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace cadnext::kernel
