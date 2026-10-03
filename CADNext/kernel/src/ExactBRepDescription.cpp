#include "cadnext/kernel/ExactBRepDescription.hpp"

#include <algorithm>
#include <cmath>
#include <string>

#ifdef CADNEXT_WITH_OCCT
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepClass3d.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <Geom2d_Curve.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_Line.hxx>
#include <Geom2d_Hyperbola.hxx>
#include <Geom2d_Parabola.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <gp_Pnt2d.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Tool.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <GeomConvert.hxx>
#include <GeomLib_IsPlanarSurface.hxx>
#include <GeomLProp_SLProps.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Ellipse.hxx>
#include <Geom_Line.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_OffsetCurve.hxx>
#include <Geom_OffsetSurface.hxx>
#include <Geom_Plane.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <Geom_SphericalSurface.hxx>
#include <Geom_ToroidalSurface.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <Standard_Failure.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#endif

namespace cadnext::kernel {

#ifndef CADNEXT_WITH_OCCT

cadnext::Result<ExactBRepDescription> describeExactBRep(
    const OcctKernel&, const ShapeHandle&, ConeParameterization) {
    return cadnext::Result<ExactBRepDescription>::fail(
        {cadnext::ErrorCode::UnsupportedOperation, "описание точного BRep требует сборки с OCCT"});
}

#else

namespace {

using R = cadnext::Result<ExactBRepDescription>;

cadnext::Vector3 vec(const gp_XYZ& p) { return {p.X(), p.Y(), p.Z()}; }
gp_Pnt pnt(const cadnext::Vector3& v) { return gp_Pnt(v.x, v.y, v.z); }
gp_Dir dir(const cadnext::Vector3& v) { return gp_Dir(v.x, v.y, v.z); }

Handle(Geom2d_Curve) pcurveBasis(Handle(Geom2d_Curve) curve) {
    while (const auto trimmed = Handle(Geom2d_TrimmedCurve)::DownCast(curve))
        curve = trimmed->BasisCurve();
    return curve;
}

Handle(Geom_BSplineSurface) bsplineSurfaceOf(const BSplineSurfaceDefinition& d) {
    TColgp_Array2OfPnt poles(1, d.uPoleCount, 1, d.vPoleCount);
    TColStd_Array2OfReal weights(1, d.uPoleCount, 1, d.vPoleCount);
    for (int u = 0; u < d.uPoleCount; ++u) {
        for (int v = 0; v < d.vPoleCount; ++v) {
            poles.SetValue(u + 1, v + 1, pnt(d.poles[std::size_t(u * d.vPoleCount + v)]));
            weights.SetValue(u + 1, v + 1, d.weights[std::size_t(u * d.vPoleCount + v)]);
        }
    }
    TColStd_Array1OfReal uKnots(1, int(d.uKnots.size())), vKnots(1, int(d.vKnots.size()));
    TColStd_Array1OfInteger uMult(1, int(d.uKnots.size())), vMult(1, int(d.vKnots.size()));
    for (int i = 0; i < int(d.uKnots.size()); ++i) {
        uKnots.SetValue(i + 1, d.uKnots[std::size_t(i)]);
        uMult.SetValue(i + 1, d.uMultiplicities[std::size_t(i)]);
    }
    for (int i = 0; i < int(d.vKnots.size()); ++i) {
        vKnots.SetValue(i + 1, d.vKnots[std::size_t(i)]);
        vMult.SetValue(i + 1, d.vMultiplicities[std::size_t(i)]);
    }
    return new Geom_BSplineSurface(poles, weights, uKnots, vKnots, uMult, vMult, d.uDegree, d.vDegree, false, false);
}

// The surface as a reader of the description rebuilds it: a right-handed frame from origin, axis
// and x axis, the cone angle from its sine and cosine.
Handle(Geom_Curve) curveOf(const DescribedCurve& c);

Handle(Geom_Surface) asRead(const DescribedSurface& s) {
    if (s.kind == DescribedSurface::Kind::BSpline) return bsplineSurfaceOf(s.bspline);
    if (s.kind == DescribedSurface::Kind::Swept) {
        const Handle(Geom_Curve) section = curveOf(s.section);
        return section.IsNull() ? Handle(Geom_Surface)() : new Geom_SurfaceOfLinearExtrusion(section, dir(s.axis));
    }
    const gp_Ax3 frame(pnt(s.origin), dir(s.axis), dir(s.xAxis));
    switch (s.kind) {
    case DescribedSurface::Kind::Plane: return new Geom_Plane(frame);
    case DescribedSurface::Kind::Cylinder: return new Geom_CylindricalSurface(frame, s.radius);
    case DescribedSurface::Kind::Cone:
        return new Geom_ConicalSurface(frame, std::atan2(s.sinHalfAngle, s.cosHalfAngle), s.radius);
    case DescribedSurface::Kind::Sphere: return new Geom_SphericalSurface(frame, s.radius);
    case DescribedSurface::Kind::Torus: return new Geom_ToroidalSurface(frame, s.majorRadius, s.minorRadius);
    default: return {};
    }
}

// One periodic direction of an OCCT B-spline (N poles, knots K_0..K_k of one period with K_0's
// multiplicity m equal to K_k's) in XT's unwrapped form: the period's flat knots continued both ways
// so that flat index `degree` is K_0's last copy, n = N + (degree + 1 − m) poles, pole i being OCCT's
// pole i mod N. The CADNext reader (wrapPeriodic) turns it back into the same OCCT spline.
bool unwrapPeriodic(const std::vector<double>& knots, const std::vector<int>& multiplicities, int degree, int count,
                    std::vector<double>& flatKnots, int& unwrappedCount) {
    const int k = int(knots.size()) - 1;
    if (k < 1 || multiplicities.front() != multiplicities.back()) return false;
    const int m = multiplicities.front();
    const double period = knots.back() - knots.front();
    std::vector<double> one; // K_0 .. K_{k-1} at their multiplicities
    for (int i = 0; i < k; ++i)
        for (int c = 0; c < multiplicities[std::size_t(i)]; ++c) one.push_back(knots[std::size_t(i)]);
    const int overlap = degree + 1 - m;
    if (int(one.size()) != count || overlap < 1 || !(period > 0.0)) return false;
    unwrappedCount = count + overlap;
    const auto at = [&](int j) {
        const int turns = int(std::floor(double(j) / count));
        return one[std::size_t(j - turns * count)] + turns * period;
    };
    flatKnots.clear();
    for (int i = 0; i <= unwrappedCount + degree; ++i) flatKnots.push_back(at(i - degree + m - 1));
    return true;
}

void uniqueKnots(const std::vector<double>& flat, std::vector<double>& knots, std::vector<int>& multiplicities) {
    knots.clear();
    multiplicities.clear();
    for (const double t : flat) {
        if (!knots.empty() && t == knots.back()) ++multiplicities.back();
        else {
            knots.push_back(t);
            multiplicities.push_back(1);
        }
    }
}

BSplineCurveDefinition definitionOf(const Handle(Geom_BSplineCurve)& b) {
    BSplineCurveDefinition d;
    d.degree = b->Degree();
    d.periodic = false;
    for (int i = 1; i <= b->NbPoles(); ++i) {
        d.poles.push_back(vec(b->Pole(i).XYZ()));
        d.weights.push_back(b->Weight(i));
    }
    for (int i = 1; i <= b->NbKnots(); ++i) {
        d.knots.push_back(b->Knot(i));
        d.multiplicities.push_back(b->Multiplicity(i));
    }
    return d;
}

// All poles in one plane imply a planar rational spline too. Work with differences
// from a pole so that translation and rotation do not affect the planarity test.
bool splinePlane(const Handle(Geom_BSplineSurface)& spline, gp_Ax3& frame) {
    const gp_Pnt origin = spline->Pole(1, 1);
    gp_Vec x, normal;
    for (int u = 1; u <= spline->NbUPoles(); ++u)
        for (int v = 1; v <= spline->NbVPoles(); ++v) {
            const gp_Vec offset(origin, spline->Pole(u, v));
            if (offset.SquareMagnitude() > x.SquareMagnitude()) x = offset;
        }
    if (x.Magnitude() <= 1e-12) return false;
    x.Normalize();
    for (int u = 1; u <= spline->NbUPoles(); ++u)
        for (int v = 1; v <= spline->NbVPoles(); ++v) {
            const gp_Vec cross = x.Crossed(gp_Vec(origin, spline->Pole(u, v)));
            if (cross.SquareMagnitude() > normal.SquareMagnitude()) normal = cross;
        }
    if (normal.Magnitude() <= 1e-12) return false;
    normal.Normalize();
    for (int u = 1; u <= spline->NbUPoles(); ++u)
        for (int v = 1; v <= spline->NbVPoles(); ++v)
            if (std::fabs(gp_Vec(origin, spline->Pole(u, v)).Dot(normal)) > 1e-12) return false;
    frame = gp_Ax3(origin, gp_Dir(normal), gp_Dir(x));
    return true;
}

std::string what(const char* entity, int index) { return std::string(entity) + " " + std::to_string(index); }

// A free curve (the section of a swept surface) in the description's terms; false when it has no
// exact form here.
bool describeCurveGeometry(Handle(Geom_Curve) curve, DescribedCurve& out) {
    while (const Handle(Geom_TrimmedCurve) trimmed = Handle(Geom_TrimmedCurve)::DownCast(curve)) curve = trimmed->BasisCurve();
    if (const Handle(Geom_Circle) circle = Handle(Geom_Circle)::DownCast(curve)) {
        const gp_Ax2 axes = circle->Position();
        out.kind = DescribedCurve::Kind::Circle;
        out.origin = vec(axes.Location().XYZ());
        out.direction = vec(axes.Direction().XYZ());
        out.xAxis = vec(axes.XDirection().XYZ());
        out.radius = circle->Radius();
        return true;
    }
    if (const Handle(Geom_Ellipse) ellipse = Handle(Geom_Ellipse)::DownCast(curve)) {
        const gp_Ax2 axes = ellipse->Position();
        out.kind = DescribedCurve::Kind::Ellipse;
        out.origin = vec(axes.Location().XYZ());
        out.direction = vec(axes.Direction().XYZ());
        out.xAxis = vec(axes.XDirection().XYZ());
        out.majorRadius = ellipse->MajorRadius();
        out.minorRadius = ellipse->MinorRadius();
        return true;
    }
    Handle(Geom_BSplineCurve) spline = Handle(Geom_BSplineCurve)::DownCast(curve);
    if (spline.IsNull() && !Handle(Geom_BezierCurve)::DownCast(curve).IsNull())
        spline = GeomConvert::CurveToBSplineCurve(curve);
    if (spline.IsNull()) return false;
    spline = Handle(Geom_BSplineCurve)::DownCast(spline->Copy());
    if (spline->IsPeriodic()) spline->SetNotPeriodic();
    out.kind = DescribedCurve::Kind::BSpline;
    out.bspline = definitionOf(spline);
    return true;
}

Handle(Geom_Curve) curveOf(const DescribedCurve& c) {
    switch (c.kind) {
    case DescribedCurve::Kind::Line: return new Geom_Line(pnt(c.origin), dir(c.direction));
    case DescribedCurve::Kind::Circle: return new Geom_Circle(gp_Ax2(pnt(c.origin), dir(c.direction), dir(c.xAxis)), c.radius);
    case DescribedCurve::Kind::Ellipse:
        return new Geom_Ellipse(gp_Ax2(pnt(c.origin), dir(c.direction), dir(c.xAxis)), c.majorRadius, c.minorRadius);
    case DescribedCurve::Kind::BSpline: {
        const auto& d = c.bspline;
        TColgp_Array1OfPnt poles(1, int(d.poles.size()));
        TColStd_Array1OfReal weights(1, int(d.poles.size())), knots(1, int(d.knots.size()));
        TColStd_Array1OfInteger multiplicities(1, int(d.knots.size()));
        for (int i = 0; i < int(d.poles.size()); ++i) {
            poles.SetValue(i + 1, pnt(d.poles[std::size_t(i)]));
            weights.SetValue(i + 1, d.weights[std::size_t(i)]);
        }
        for (int i = 0; i < int(d.knots.size()); ++i) {
            knots.SetValue(i + 1, d.knots[std::size_t(i)]);
            multiplicities.SetValue(i + 1, d.multiplicities[std::size_t(i)]);
        }
        return new Geom_BSplineCurve(poles, weights, knots, multiplicities, d.degree, false);
    }
    }
    return {};
}

} // namespace

cadnext::Result<ExactBRepDescription> describeExactBRep(
    const OcctKernel& kernel, const ShapeHandle& handle,
    ConeParameterization coneParameterization) {
    const TopoDS_Shape* shape = kernel.findShape(handle);
    if (!shape || shape->IsNull()) return R::fail({cadnext::ErrorCode::ShapeInvalid, "нет такой формы"});
    try {
        ExactBRepDescription out;
        TopTools_IndexedMapOfShape vertexMap, edgeMap, faceMap;
        std::vector<int> vertexIndex, edgeIndex; // map index (1-based) -> description index, -1 unset
        const auto vertexOf = [&](const TopoDS_Vertex& v) {
            const int key = vertexMap.Add(v);
            if (key > int(vertexIndex.size())) vertexIndex.resize(std::size_t(key), -1);
            if (vertexIndex[std::size_t(key - 1)] < 0) {
                vertexIndex[std::size_t(key - 1)] = int(out.vertices.size());
                out.vertices.push_back(vec(BRep_Tool::Pnt(v).XYZ()));
            }
            return vertexIndex[std::size_t(key - 1)];
        };
        std::string failure;
        const auto edgeOf = [&](const TopoDS_Edge& edge) -> int {
            const TopoDS_Edge forward = TopoDS::Edge(edge.Oriented(TopAbs_FORWARD));
            const int key = edgeMap.Add(forward);
            if (key > int(edgeIndex.size())) edgeIndex.resize(std::size_t(key), -1);
            if (edgeIndex[std::size_t(key - 1)] >= 0) return edgeIndex[std::size_t(key - 1)];
            double first = 0.0, last = 0.0;
            Handle(Geom_Curve) curve = BRep_Tool::Curve(forward, first, last);
            if (curve.IsNull()) {
                failure = "у ребра нет трёхмерной кривой";
                return -1;
            }
            DescribedEdge described;
            described.tolerance = BRep_Tool::Tolerance(edge);
            for (TopExp_Explorer vertex(edge, TopAbs_VERTEX); vertex.More(); vertex.Next())
                described.tolerance = std::max(described.tolerance, BRep_Tool::Tolerance(TopoDS::Vertex(vertex.Current())));
            described.start = vertexOf(TopExp::FirstVertex(forward));
            described.end = vertexOf(TopExp::LastVertex(forward));
            DescribedCurve c;
            const BRepAdaptor_Curve adaptor(forward);
            switch (adaptor.GetType()) {
            case GeomAbs_Line: {
                const gp_Lin line = adaptor.Line();
                c.kind = DescribedCurve::Kind::Line;
                c.origin = vec(line.Location().XYZ());
                c.direction = vec(line.Direction().XYZ());
                if (described.start == described.end) {
                    failure = "прямое ребро начинается и кончается в одной вершине";
                    return -1;
                }
                break;
            }
            case GeomAbs_Circle: {
                const gp_Circ circle = adaptor.Circle();
                c.kind = DescribedCurve::Kind::Circle;
                c.origin = vec(circle.Location().XYZ());
                c.direction = vec(circle.Axis().Direction().XYZ());
                c.xAxis = vec(circle.XAxis().Direction().XYZ());
                c.radius = circle.Radius();
                break;
            }
            case GeomAbs_Ellipse: {
                const gp_Elips ellipse = adaptor.Ellipse();
                c.kind = DescribedCurve::Kind::Ellipse;
                c.origin = vec(ellipse.Location().XYZ());
                c.direction = vec(ellipse.Axis().Direction().XYZ());
                c.xAxis = vec(ellipse.XAxis().Direction().XYZ());
                c.majorRadius = ellipse.MajorRadius();
                c.minorRadius = ellipse.MinorRadius();
                break;
            }
            default: {
                // Everything else as a B-spline, cut to exactly the edge: an XT curve attached to
                // an edge may not be closed without being periodic, and a curve that ends at the
                // edge's vertices leaves no doubt which part of it the edge is.
                if (described.start == described.end) {
                    // A closed edge: its curve periodic, as XT requires of a closed curve on an edge
                    // (a ring below when nothing else meets its vertex).
                    Handle(Geom_Curve) basis = curve;
                    while (const Handle(Geom_TrimmedCurve) trimmed = Handle(Geom_TrimmedCurve)::DownCast(basis))
                        basis = trimmed->BasisCurve();
                    Handle(Geom_BSplineCurve) spline = Handle(Geom_BSplineCurve)::DownCast(basis);
                    if (spline.IsNull() || std::fabs((last - first) - (spline->LastParameter() - spline->FirstParameter())) > 1e-12 *
                                               std::max(1.0, std::fabs(last - first))) {
                        failure = "замкнутое ребро на кривой, которая не является одной замкнутой B-сплайн кривой";
                        return -1;
                    }
                    spline = Handle(Geom_BSplineCurve)::DownCast(spline->Copy());
                    if (!spline->IsPeriodic()) {
                        // Closed to within the builder's precision; closed exactly, then periodic.
                        if (spline->StartPoint().Distance(spline->EndPoint()) > 1e-7) {
                            failure = "ребро с одной вершиной на незамкнутой B-сплайн кривой";
                            return -1;
                        }
                        spline->SetPole(spline->NbPoles(), spline->Pole(1), spline->Weight(1));
                        spline->SetPeriodic();
                    }
                    std::vector<double> knots, flat;
                    std::vector<int> multiplicities;
                    for (int i = 1; i <= spline->NbKnots(); ++i) {
                        knots.push_back(spline->Knot(i));
                        multiplicities.push_back(spline->Multiplicity(i));
                    }
                    int count = 0;
                    if (!unwrapPeriodic(knots, multiplicities, spline->Degree(), spline->NbPoles(), flat, count)) {
                        failure = "замкнутая B-сплайн кривая ребра с кратным узлом на шве";
                        return -1;
                    }
                    c.kind = DescribedCurve::Kind::BSpline;
                    c.periodic = true;
                    c.bspline.degree = spline->Degree();
                    for (int i = 0; i < count; ++i) {
                        c.bspline.poles.push_back(vec(spline->Pole(1 + i % spline->NbPoles()).XYZ()));
                        c.bspline.weights.push_back(spline->Weight(1 + i % spline->NbPoles()));
                    }
                    uniqueKnots(flat, c.bspline.knots, c.bspline.multiplicities);
                    curve = spline;
                    first = spline->FirstParameter();
                    last = spline->LastParameter();
                    break;
                }
                Handle(Geom_Curve) basis = curve;
                while (const Handle(Geom_TrimmedCurve) trimmed = Handle(Geom_TrimmedCurve)::DownCast(basis))
                    basis = trimmed->BasisCurve();
                if (!Handle(Geom_OffsetCurve)::DownCast(basis).IsNull()) {
                    failure = "ребро на кривой смещения (точного представления в XT нет)";
                    return -1;
                }
                Handle(Geom_BSplineCurve) spline = Handle(Geom_BSplineCurve)::DownCast(basis);
                if (!spline.IsNull()) {
                    spline = Handle(Geom_BSplineCurve)::DownCast(spline->Copy());
                    // Cut while periodic: an open edge may cross the curve's seam and end
                    // beyond LastParameter(). Unwrapping first loses that part of the curve.
                    if (spline->IsPeriodic() || first > spline->FirstParameter() + 1e-12 ||
                        last < spline->LastParameter() - 1e-12)
                        spline->Segment(first, last);
                    if (spline->IsPeriodic()) spline->SetNotPeriodic();
                } else {
                    spline = GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(basis, first, last));
                }
                if (spline.IsNull()) {
                    failure = "кривую ребра не удалось представить B-сплайном";
                    return -1;
                }
                c.kind = DescribedCurve::Kind::BSpline;
                c.bspline = definitionOf(spline);
                curve = spline;
                first = spline->FirstParameter();
                last = spline->LastParameter();
                break;
            }
            }
            described.curve = int(out.curves.size());
            described.firstParameter = first;
            described.lastParameter = last;
            out.curves.push_back(std::move(c));
            const gp_Pnt a = curve->Value(first), b = curve->Value(last);
            out.largestVertexGap = std::max({out.largestVertexGap, a.Distance(pnt(out.vertices[std::size_t(described.start)])),
                                             b.Distance(pnt(out.vertices[std::size_t(described.end)]))});
            edgeIndex[std::size_t(key - 1)] = int(out.edges.size());
            out.edges.push_back(described);
            return edgeIndex[std::size_t(key - 1)];
        };

        const auto describeSurface = [&](const TopoDS_Face& face, DescribedSurface& s) -> bool {
            const BRepAdaptor_Surface adaptor(face);
            switch (adaptor.GetType()) {
            case GeomAbs_Plane: {
                const gp_Ax3 p = adaptor.Plane().Position();
                s.kind = DescribedSurface::Kind::Plane;
                s.origin = vec(p.Location().XYZ());
                s.axis = vec(p.XDirection().Crossed(p.YDirection()).XYZ());
                s.xAxis = vec(p.XDirection().XYZ());
                return true;
            }
            case GeomAbs_Cylinder: {
                const gp_Cylinder c = adaptor.Cylinder();
                const gp_Ax3 p = c.Position();
                s.kind = DescribedSurface::Kind::Cylinder;
                s.origin = vec(p.Location().XYZ());
                s.axis = vec(p.XDirection().Crossed(p.YDirection()).XYZ());
                s.xAxis = vec(p.XDirection().XYZ());
                s.radius = c.Radius();
                return true;
            }
            case GeomAbs_Cone: {
                // Radius grows along the axis with a positive half angle, as XT files hold cones;
                // the axis point is moved onto the face so that its radius there is positive.
                const gp_Cone c = adaptor.Cone();
                const gp_Ax3 p = c.Position();
                const double angle = c.SemiAngle();
                if (coneParameterization == ConeParameterization::SourceFrame) {
                    // C3D can retain the signed angle. Keeping the reference
                    // circle avoids translating UV knots/poles and rebuilding
                    // periodic seams on an already trimmed tolerant support.
                    const gp_Dir axis = p.XDirection().Crossed(p.YDirection());
                    const double signedAngle = p.Direction().Dot(axis) < 0 ? -angle : angle;
                    s.kind = DescribedSurface::Kind::Cone;
                    s.origin = vec(p.Location().XYZ());
                    s.axis = vec(axis.XYZ());
                    s.xAxis = vec(p.XDirection().XYZ());
                    s.radius = c.RefRadius();
                    s.sinHalfAngle = std::sin(signedAngle);
                    s.cosHalfAngle = std::cos(signedAngle);
                    return true;
                }
                const gp_Dir axis = angle > 0.0 ? p.Direction() : p.Direction().Reversed();
                const double half = std::fabs(angle);
                double u1, u2, v1, v2;
                BRepTools::UVBounds(face, u1, u2, v1, v2);
                const gp_Pnt middle = adaptor.Value(0.5 * (u1 + u2), 0.5 * (v1 + v2));
                const double along = gp_Vec(p.Location(), middle).Dot(gp_Vec(axis));
                s.kind = DescribedSurface::Kind::Cone;
                s.origin = vec(p.Location().XYZ() + gp_Vec(axis).XYZ() * along);
                s.axis = vec(axis.XYZ());
                s.xAxis = vec(p.XDirection().XYZ());
                s.radius = c.RefRadius() + along * std::tan(half);
                s.sinHalfAngle = std::sin(half);
                s.cosHalfAngle = std::cos(half);
                if (!(s.radius > 0.0)) {
                    failure = "конус без положительного радиуса на грани";
                    return false;
                }
                return true;
            }
            case GeomAbs_Sphere: {
                const gp_Sphere sphere = adaptor.Sphere();
                const gp_Ax3 p = sphere.Position();
                s.kind = DescribedSurface::Kind::Sphere;
                s.origin = vec(p.Location().XYZ());
                s.axis = vec(p.XDirection().Crossed(p.YDirection()).XYZ());
                s.xAxis = vec(p.XDirection().XYZ());
                s.radius = sphere.Radius();
                return true;
            }
            case GeomAbs_Torus: {
                const gp_Torus torus = adaptor.Torus();
                const gp_Ax3 p = torus.Position();
                if (!(torus.MajorRadius() > 0.0)) {
                    failure = "тор без положительного большого радиуса";
                    return false;
                }
                if (!(torus.MajorRadius() > torus.MinorRadius())) {
                    // A self-intersecting torus: XT's TORUS with 0 < major < minor is an apple, the
                    // outer part only, where R + r·cos v >= 0 (XT Format Reference, TORUS); the
                    // inner part, a lemon, XT gives a negative major radius, which the reader does
                    // not take. So the face goes out as an apple when all of it — its edges and its
                    // inside — is on the outer part (within the builder's 1e-7).
                    const double major = torus.MajorRadius(), minor = torus.MinorRadius();
                    const auto outer = [&](double v) { return major + minor * std::cos(v) >= -1e-7; };
                    bool apple = true;
                    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More() && apple; e.Next()) {
                        double a = 0, b = 0;
                        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(TopoDS::Edge(e.Current()), face, a, b);
                        for (int k = 0; k <= 16 && apple && !pcurve.IsNull(); ++k)
                            apple = outer(pcurve->Value(a + (b - a) * k / 16.0).Y());
                    }
                    double u1, u2, v1, v2;
                    BRepTools::UVBounds(face, u1, u2, v1, v2);
                    for (int i = 0; i <= 16 && apple; ++i)
                        for (int j = 0; j <= 16 && apple; ++j) {
                            const gp_Pnt2d uv(u1 + (u2 - u1) * i / 16.0, v1 + (v2 - v1) * j / 16.0);
                            if (BRepClass_FaceClassifier(face, uv, 1e-9).State() == TopAbs_IN) apple = outer(uv.Y());
                        }
                    if (!apple) {
                        failure = "грань на внутренней части самопересекающегося тора (лимон) пока не выводится";
                        return false;
                    }
                }
                s.kind = DescribedSurface::Kind::Torus;
                s.origin = vec(p.Location().XYZ());
                s.axis = vec(p.XDirection().Crossed(p.YDirection()).XYZ());
                s.xAxis = vec(p.XDirection().XYZ());
                s.majorRadius = torus.MajorRadius();
                s.minorRadius = torus.MinorRadius();
                return true;
            }
            default: {
                Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
                while (const Handle(Geom_RectangularTrimmedSurface) trimmed =
                           Handle(Geom_RectangularTrimmedSurface)::DownCast(surface))
                    surface = trimmed->BasisSurface();
                if (!Handle(Geom_OffsetSurface)::DownCast(surface).IsNull()) {
                    failure = "грань на поверхности смещения (точного представления в XT без базы нет)";
                    return false;
                }
                // NurbsConvert also turns planar caps into bilinear splines. Keep their exact
                // plane: projecting a closed rational edge onto a spline plane otherwise creates
                // an approximated pcurve and changes the enclosed area on readback.
                gp_Ax3 planeFrame;
                const Handle(Geom_BSplineSurface) planeSpline = Handle(Geom_BSplineSurface)::DownCast(surface);
                bool isPlane = false;
                if (!planeSpline.IsNull()) isPlane = splinePlane(planeSpline, planeFrame);
                else {
                    const GeomLib_IsPlanarSurface planar(surface, 1e-12);
                    isPlane = planar.IsPlanar();
                    if (isPlane) planeFrame = planar.Plan().Position();
                }
                if (isPlane && !planeSpline.IsNull()) {
                    // Preserve the original UV and its integration when every boundary can be
                    // transferred exactly. Otherwise use the exact plane (e.g. a rational cap
                    // whose circular 2D boundary has a different parameter from the 3D curve).
                    bool boundaries = true;
                    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More() && boundaries; it.Next()) {
                        const auto edge = TopoDS::Edge(it.Current());
                        if (BRep_Tool::Degenerated(edge) || BRep_Tool::IsClosed(edge, face)) continue;
                        double a, b;
                        const auto pcurve = pcurveBasis(BRep_Tool::CurveOnSurface(edge, face, a, b));
                        boundaries = !Handle(Geom2d_BSplineCurve)::DownCast(pcurve).IsNull() ||
                                     !Handle(Geom2d_Line)::DownCast(pcurve).IsNull();
                    }
                    if (boundaries) isPlane = false;
                }
                if (isPlane) {
                    s.kind = DescribedSurface::Kind::Plane;
                    s.origin = vec(planeFrame.Location().XYZ());
                    s.axis = vec(planeFrame.XDirection().Crossed(planeFrame.YDirection()).XYZ());
                    s.xAxis = vec(planeFrame.XDirection().XYZ());
                    return true;
                }
                // An extrusion keeps its own form (XT SWEPT_SURF: the section and the direction);
                // a straight section is a plane in disguise and goes the B-spline way below.
                if (const Handle(Geom_SurfaceOfLinearExtrusion) extrusion =
                        Handle(Geom_SurfaceOfLinearExtrusion)::DownCast(surface)) {
                    DescribedCurve section;
                    if (describeCurveGeometry(extrusion->BasisCurve(), section) &&
                        section.kind != DescribedCurve::Kind::Line) {
                        s.kind = DescribedSurface::Kind::Swept;
                        s.axis = vec(extrusion->Direction().XYZ());
                        s.section = std::move(section);
                        return true;
                    }
                }
                Handle(Geom_BSplineSurface) spline = Handle(Geom_BSplineSurface)::DownCast(surface);
                if (spline.IsNull()) spline = GeomConvert::SurfaceToBSplineSurface(surface);
                if (spline.IsNull()) {
                    failure = "поверхность грани не удалось представить B-сплайном";
                    return false;
                }
                BSplineSurfaceDefinition& d = s.bspline;
                s.kind = DescribedSurface::Kind::BSpline;
                d.uDegree = spline->UDegree();
                d.vDegree = spline->VDegree();
                d.uPoleCount = spline->NbUPoles();
                d.vPoleCount = spline->NbVPoles();
                for (int i = 1; i <= spline->NbUKnots(); ++i) {
                    d.uKnots.push_back(spline->UKnot(i));
                    d.uMultiplicities.push_back(spline->UMultiplicity(i));
                }
                for (int i = 1; i <= spline->NbVKnots(); ++i) {
                    d.vKnots.push_back(spline->VKnot(i));
                    d.vMultiplicities.push_back(spline->VMultiplicity(i));
                }
                // A periodic direction as XT keeps it (unwrapped, see the header).
                int uCount = d.uPoleCount, vCount = d.vPoleCount;
                const auto unwrap = [&](bool periodic, std::vector<double>& knots, std::vector<int>& multiplicities,
                                        int degree, int& count) {
                    if (!periodic) return true;
                    std::vector<double> flat;
                    if (!unwrapPeriodic(knots, multiplicities, degree, count, flat, count)) return false;
                    uniqueKnots(flat, knots, multiplicities);
                    return true;
                };
                if (!unwrap(spline->IsUPeriodic(), d.uKnots, d.uMultiplicities, d.uDegree, uCount) ||
                    !unwrap(spline->IsVPeriodic(), d.vKnots, d.vMultiplicities, d.vDegree, vCount)) {
                    failure = "периодическая B-сплайн поверхность с кратным узлом на шве";
                    return false;
                }
                s.uPeriodic = spline->IsUPeriodic();
                s.vPeriodic = spline->IsVPeriodic();
                for (int u = 0; u < uCount; ++u) {
                    for (int v = 0; v < vCount; ++v) {
                        const int pu = 1 + u % d.uPoleCount, pv = 1 + v % d.vPoleCount;
                        d.poles.push_back(vec(spline->Pole(pu, pv).XYZ()));
                        d.weights.push_back(spline->Weight(pu, pv));
                    }
                }
                d.uPoleCount = uCount;
                d.vPoleCount = vCount;
                return true;
            }
            }
        };

        // The face normal against the natural normal of the surface as it will be read back:
        // compared at a point of the face, where both are defined.
        const auto facesAgainst = [&](const TopoDS_Face& face, const DescribedSurface& s, bool& reversed) -> bool {
            const BRepAdaptor_Surface adaptor(face);
            const Handle(Geom_Surface) read = asRead(s);
            if (read.IsNull()) return false;
            double u1, u2, v1, v2;
            BRepTools::UVBounds(face, u1, u2, v1, v2);
            for (const double f : {0.5, 0.37, 0.61, 0.23, 0.77}) {
                const double u = u1 + (u2 - u1) * f, v = v1 + (v2 - v1) * (1.0 - f);
                gp_Pnt at;
                gp_Vec du, dv;
                adaptor.D1(u, v, at, du, dv);
                gp_Vec natural = du.Crossed(dv);
                if (natural.Magnitude() < 1e-12) continue;
                if (face.Orientation() == TopAbs_REVERSED) natural.Reverse();
                double pu = u, pv = v;
                // Exact spline data keep their parameters, including periodic unwrapping.
                // A global closest-point search can miss a long helical surface even at a
                // point on it. Use the preserved parameters when they reproduce the point.
                const bool sameParameters =
                    (s.kind == DescribedSurface::Kind::BSpline || s.kind == DescribedSurface::Kind::Swept) &&
                    read->Value(u, v).Distance(at) <= 1e-12;
                if (!sameParameters) {
                    GeomAPI_ProjectPointOnSurf projection(at, read);
                    if (projection.NbPoints() == 0 || projection.LowerDistance() > 1e-6) continue;
                    projection.LowerDistanceParameters(pu, pv);
                }
                GeomLProp_SLProps props(read, pu, pv, 1, 1e-9);
                if (!props.IsNormalDefined()) continue;
                const double cosine = gp_Vec(props.Normal()).Dot(natural.Normalized());
                if (std::fabs(cosine) < 0.9) continue; // not the same point of the same surface
                reversed = cosine < 0.0;
                return true;
            }
            return false;
        };

        // Loops of a face without seams and pole edges, re-chained by their vertices.
        const auto describeLoops = [&](const TopoDS_Face& face, const DescribedSurface& surface,
                                       std::vector<std::vector<DescribedCoedge>>& loops) -> bool {
            struct Piece {
                DescribedCoedge coedge;
                int from = -1, to = -1;
                int wire = -1;
                bool used = false;
            };
            std::vector<Piece> pieces;
            TopTools_IndexedMapOfShape faceEdges;
            std::vector<int> edgeUses;
            for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
                const int key=faceEdges.Add(it.Current());
                if(edgeUses.size()<std::size_t(key))edgeUses.resize(std::size_t(key),0);
                ++edgeUses[std::size_t(key-1)];
            }
            int wireIndex = 0;
            for (TopExp_Explorer wires(face, TopAbs_WIRE); wires.More(); wires.Next(), ++wireIndex) {
                for (BRepTools_WireExplorer it(TopoDS::Wire(wires.Current()), face); it.More(); it.Next()) {
                    const TopoDS_Edge& edge = it.Current();
                    // Two pcurves on a common support can belong to two
                    // different faces. Only an edge used twice by this face
                    // is its seam; dropping a shared boundary opens the wire.
                    const bool seam=BRep_Tool::IsClosed(edge,face) &&
                        edgeUses.at(std::size_t(faceEdges.FindIndex(edge)-1))>1;
                    if (BRep_Tool::Degenerated(edge) || seam) continue;
                    if (edge.Orientation() != TopAbs_FORWARD && edge.Orientation() != TopAbs_REVERSED) {
                        failure = "внутреннее или внешнее ребро в контуре грани";
                        return false;
                    }
                    Piece piece;
                    piece.wire = wireIndex;
                    piece.coedge.edge = edgeOf(edge);
                    if (piece.coedge.edge < 0) return false;
                    piece.coedge.forward = edge.Orientation() == TopAbs_FORWARD;
                    const DescribedEdge& e = out.edges[std::size_t(piece.coedge.edge)];
                    const BRepAdaptor_Surface original(face);
                    const bool unchangedUv = (surface.kind == DescribedSurface::Kind::BSpline && original.GetType() == GeomAbs_BSplineSurface) ||
                        (surface.kind == DescribedSurface::Kind::Plane && original.GetType() == GeomAbs_Plane) ||
                        (surface.kind == DescribedSurface::Kind::Cylinder && original.GetType() == GeomAbs_Cylinder) ||
                        (surface.kind == DescribedSurface::Kind::Cone && original.GetType() == GeomAbs_Cone) ||
                        (surface.kind == DescribedSurface::Kind::Sphere && original.GetType() == GeomAbs_Sphere) ||
                        (surface.kind == DescribedSurface::Kind::Torus && original.GetType() == GeomAbs_Torus);
                    if (unchangedUv) {
                        double first = 0, last = 0;
                        const auto pcurve = pcurveBasis(BRep_Tool::CurveOnSurface(edge, face, first, last));
                        if (const auto original = Handle(Geom2d_BSplineCurve)::DownCast(pcurve)) {
                            const auto spline = Handle(Geom2d_BSplineCurve)::DownCast(original->Copy());
                            spline->Segment(first, last);
                            if (spline->IsPeriodic()) spline->SetNotPeriodic();
                            BSplineCurveDefinition d;
                            d.degree = spline->Degree();
                            for (int k = 1; k <= spline->NbKnots(); ++k) {
                                d.knots.push_back(spline->Knot(k));
                                d.multiplicities.push_back(spline->Multiplicity(k));
                            }
                            for (int p = 1; p <= spline->NbPoles(); ++p) {
                                const auto uv = spline->Pole(p);
                                d.poles.push_back({uv.X(), uv.Y(), 0});
                                d.weights.push_back(spline->Weight(p));
                            }
                            piece.coedge.pcurve = std::move(d);
                        } else if (!Handle(Geom2d_Line)::DownCast(pcurve).IsNull()) {
                            const auto a = pcurve->Value(first), b = pcurve->Value(last);
                            BSplineCurveDefinition d;
                            d.degree = 1;
                            d.knots = {first, last}; d.multiplicities = {2, 2};
                            d.poles = {{a.X(), a.Y(), 0}, {b.X(), b.Y(), 0}}; d.weights = {1, 1};
                            piece.coedge.pcurve = std::move(d);
                        }
                        if (!piece.coedge.pcurve && surface.kind==DescribedSurface::Kind::Plane) {
                            AnalyticPcurveDefinition d;bool conic=false;
                            gp_Ax22d frame;
                            if(const auto hyperbola=Handle(Geom2d_Hyperbola)::DownCast(pcurve)) {
                                d.kind=AnalyticPcurveDefinition::Kind::Hyperbola;
                                d.a=hyperbola->MajorRadius();d.b=hyperbola->MinorRadius();
                                frame=hyperbola->Position();conic=true;
                            } else if(const auto parabola=Handle(Geom2d_Parabola)::DownCast(pcurve)) {
                                d.kind=AnalyticPcurveDefinition::Kind::Parabola;
                                d.a=parabola->Focal();frame=parabola->Position();conic=true;
                            }
                            if(conic) {
                                d.origin={frame.Location().X(),frame.Location().Y(),0};
                                d.xAxis={frame.XDirection().X(),frame.XDirection().Y(),0};
                                d.yAxis={frame.YDirection().X(),frame.YDirection().Y(),0};
                                d.first=first;d.last=last;piece.coedge.analyticPcurve=d;
                            }
                        }
                        if (piece.coedge.pcurve && surface.kind != DescribedSurface::Kind::BSpline &&
                            surface.kind != DescribedSurface::Kind::Plane) {
                            gp_Ax3 frame;
                            switch (original.GetType()) {
                            case GeomAbs_Cylinder: frame = original.Cylinder().Position(); break;
                            case GeomAbs_Cone: frame = original.Cone().Position(); break;
                            case GeomAbs_Sphere: frame = original.Sphere().Position(); break;
                            case GeomAbs_Torus: frame = original.Torus().Position(); break;
                            default: break;
                            }
                            // OCCT can keep an indirect Ax3 on an analytic support. The
                            // description rebuilds a direct frame, so its UV signs must follow
                            // the actual Y and Z axes rather than the surface type alone.
                            const gp_Dir y = dir(surface.axis).Crossed(dir(surface.xAxis));
                            const double uSense = frame.YDirection().Dot(y) < 0 ? -1.0 : 1.0;
                            const double vSense = frame.Direction().Dot(dir(surface.axis)) < 0 ? -1.0 : 1.0;
                            const double shift = surface.kind == DescribedSurface::Kind::Cone
                                ? gp_Vec(frame.Location(), pnt(surface.origin)).Dot(gp_Vec(dir(surface.axis))) /
                                  surface.cosHalfAngle : 0.0;
                            for (auto& uv : piece.coedge.pcurve->poles) {
                                uv.x *= uSense;
                                uv.y = vSense * uv.y - shift;
                            }
                        }
                    }
                    piece.from = piece.coedge.forward ? e.start : e.end;
                    piece.to = piece.coedge.forward ? e.end : e.start;
                    pieces.push_back(piece);
                }
            }
            std::vector<int> loopWires;
            for (std::size_t first = 0; first < pieces.size(); ++first) {
                if (pieces[first].used) continue;
                std::vector<DescribedCoedge> loop;
                std::size_t at = first;
                for (std::size_t guard = 0; guard <= pieces.size(); ++guard) {
                    pieces[at].used = true;
                    loop.push_back(pieces[at].coedge);
                    if (pieces[at].to == pieces[first].from) break;
                    // The next piece from this vertex, preferring the one that followed in the wire.
                    std::size_t next = pieces.size();
                    for (std::size_t k = 1; k <= pieces.size() && next == pieces.size(); ++k) {
                        const std::size_t candidate = (at + k) % pieces.size();
                        if (!pieces[candidate].used && pieces[candidate].wire == pieces[first].wire &&
                            pieces[candidate].from == pieces[at].to) next = candidate;
                    }
                    if (next == pieces.size()) {
                        failure = "контур грани не замыкается после удаления шва";
                        return false;
                    }
                    at = next;
                }
                if (pieces[at].to != pieces[first].from) {
                    failure = "контур грани не замыкается после удаления шва";
                    return false;
                }
                loops.push_back(std::move(loop));
                loopWires.push_back(pieces[first].wire);
            }
            // A contour can visit a shared vertex twice (a hole touching the outer boundary
            // at one point). Re-chaining after removing seams can split that wire into two
            // loops. Rejoin only pieces of the same source wire. Distinct source
            // wires touching at one vertex must retain their original topology.
            for (bool joined = true; joined;) {
                joined = false;
                for (std::size_t a = 0; a < loops.size() && !joined; ++a)
                    for (std::size_t b = a + 1; b < loops.size() && !joined; ++b)
                        for (std::size_t i = 0; i < loops[a].size() && !joined; ++i) {
                            if (loopWires[a] != loopWires[b]) continue;
                            const auto& use = loops[a][i];
                            const auto& edge = out.edges[std::size_t(use.edge)];
                            const int vertex = use.forward ? edge.start : edge.end;
                            for (std::size_t j = 0; j < loops[b].size(); ++j) {
                                const auto& other = loops[b][j];
                                const auto& boundary = out.edges[std::size_t(other.edge)];
                                if ((other.forward ? boundary.start : boundary.end) != vertex) continue;
                                std::vector<DescribedCoedge> insertion;
                                for (std::size_t k = 0; k < loops[b].size(); ++k)
                                    insertion.push_back(loops[b][(j + k) % loops[b].size()]);
                                loops[a].insert(loops[a].begin() + std::ptrdiff_t(i), insertion.begin(), insertion.end());
                                loops.erase(loops.begin() + std::ptrdiff_t(b));
                                loopWires.erase(loopWires.begin() + std::ptrdiff_t(b));
                                joined = true;
                                break;
                            }
                        }
            }
            return true;
        };

        for (TopExp_Explorer solids(*shape, TopAbs_SOLID); solids.More(); solids.Next()) {
            const TopoDS_Solid& solid = TopoDS::Solid(solids.Current());
            const TopoDS_Shell outer = BRepClass3d::OuterShell(solid);
            if (outer.IsNull()) return R::fail({cadnext::ErrorCode::ShapeInvalid, "у тела нет внешней оболочки"});
            std::vector<TopoDS_Shell> shells{outer};
            for (TopExp_Explorer it(solid, TopAbs_SHELL); it.More(); it.Next())
                if (!it.Current().IsSame(outer)) shells.push_back(TopoDS::Shell(it.Current()));
            DescribedLump lump;
            for (const TopoDS_Shell& shell : shells) {
                std::vector<int> faces;
                for (TopExp_Explorer it(shell, TopAbs_FACE); it.More(); it.Next()) {
                    const TopoDS_Face& face = TopoDS::Face(it.Current());
                    if (faceMap.Contains(face))
                        return R::fail({cadnext::ErrorCode::ShapeInvalid, "грань входит в две оболочки (неманифолдное тело)"});
                    faceMap.Add(face);
                    DescribedSurface surface;
                    if (!describeSurface(face, surface))
                        return R::fail({cadnext::ErrorCode::UnsupportedOperation, what("грань", faceMap.Extent()) + ": " + failure});
                    DescribedFace described;
                    if (!facesAgainst(face, surface, described.reversed))
                        return R::fail({cadnext::ErrorCode::ShapeInvalid, what("грань", faceMap.Extent()) + ": не удалось сравнить нормали"});
                    if (!describeLoops(face, surface, described.loops))
                        return R::fail({cadnext::ErrorCode::UnsupportedOperation, what("грань", faceMap.Extent()) + ": " + failure});
                    if (described.loops.empty()) {
                        if(surface.kind==DescribedSurface::Kind::BSpline) {
                            const Handle(Geom_Surface) support=asRead(surface);
                            double ua,uz,va,vz;BRepTools::UVBounds(face,ua,uz,va,vz);
                            if(!support.IsNull() && support->IsUClosed() && support->IsVClosed() &&
                               std::isfinite(ua) && std::isfinite(uz) && std::isfinite(va) && std::isfinite(vz) &&
                               uz>ua && vz>va) {
                                // A boundaryless doubly closed support has toroidal
                                // topology. Four exact parameter rectangles have
                                // genuine shared edges, with no self-used seams.
                                const double u[3]={ua,(ua+uz)/2,uz},v[3]={va,(va+vz)/2,vz};
                                int vertices[2][2],horizontal[2][2],vertical[2][2];
                                for(int i=0;i<2;++i)for(int j=0;j<2;++j) {
                                    vertices[i][j]=int(out.vertices.size());
                                    out.vertices.push_back(vec(support->Value(u[i],v[j]).XYZ()));
                                }
                                const auto addIso=[&](bool alongU,int i,int j) {
                                    const Handle(Geom_Curve) iso=alongU ? support->VIso(v[j]) : support->UIso(u[i]);
                                    const double a=alongU ? u[i] : v[j],z=alongU ? u[i+1] : v[j+1];
                                    Handle(Geom_BSplineCurve) spline=Handle(Geom_BSplineCurve)::DownCast(iso);
                                    if(!spline.IsNull())spline=Handle(Geom_BSplineCurve)::DownCast(spline->Copy());
                                    else spline=GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(iso,a,z));
                                    if(spline.IsNull())throw Standard_Failure("Closed surface iso curve is not a spline");
                                    spline->Segment(a,z);
                                    if(spline->IsPeriodic())spline->SetNotPeriodic();
                                    DescribedCurve curve;curve.kind=DescribedCurve::Kind::BSpline;
                                    curve.bspline=definitionOf(spline);
                                    DescribedEdge edge;edge.curve=int(out.curves.size());
                                    edge.start=vertices[i][j];
                                    edge.end=alongU ? vertices[(i+1)%2][j] : vertices[i][(j+1)%2];
                                    edge.firstParameter=a;edge.lastParameter=z;
                                    edge.tolerance=std::max(1e-12,BRep_Tool::Tolerance(face));
                                    const int id=int(out.edges.size());
                                    out.curves.push_back(std::move(curve));out.edges.push_back(edge);return id;
                                };
                                for(int i=0;i<2;++i)for(int j=0;j<2;++j) {
                                    horizontal[i][j]=addIso(true,i,j);
                                    vertical[i][j]=addIso(false,i,j);
                                }
                                const auto use=[&](int edge,bool forward,double u0,double v0,double u1,double v1) {
                                    DescribedCoedge coedge;coedge.edge=edge;coedge.forward=forward;
                                    BSplineCurveDefinition pc;pc.degree=1;
                                    pc.poles={{u0,v0,0},{u1,v1,0}};pc.weights={1,1};pc.multiplicities={2,2};
                                    pc.knots={out.edges[std::size_t(edge)].firstParameter,out.edges[std::size_t(edge)].lastParameter};
                                    coedge.pcurve=std::move(pc);return coedge;
                                };
                                for(int i=0;i<2;++i)for(int j=0;j<2;++j) {
                                    DescribedFace patch=described;patch.surface=int(out.surfaces.size());
                                    patch.loops={{
                                        use(horizontal[i][j],true,u[i],v[j],u[i+1],v[j]),
                                        use(vertical[(i+1)%2][j],true,u[i+1],v[j],u[i+1],v[j+1]),
                                        use(horizontal[i][(j+1)%2],false,u[i],v[j+1],u[i+1],v[j+1]),
                                        use(vertical[i][j],false,u[i],v[j],u[i],v[j+1])}};
                                    if(patch.reversed) {
                                        std::reverse(patch.loops[0].begin(),patch.loops[0].end());
                                        for(auto& coedge:patch.loops[0])coedge.forward=!coedge.forward;
                                    }
                                    out.surfaces.push_back(surface);faces.push_back(int(out.faces.size()));
                                    out.faces.push_back(std::move(patch));
                                }
                                continue;
                            }
                        }
                        if (surface.kind == DescribedSurface::Kind::Torus && surface.majorRadius > surface.minorRadius) {
                            // Split a closed torus at two opposite meridians. The two analytic
                            // bands share their exact circles and retain the entire periodic surface.
                            const gp_Dir axis = dir(surface.axis), x = dir(surface.xAxis);
                            int boundary[2];
                            for (int side = 0; side < 2; ++side) {
                                const gp_Vec radial = gp_Vec(x) * (side ? -1.0 : 1.0);
                                DescribedCurve circle;
                                circle.kind = DescribedCurve::Kind::Circle;
                                circle.origin = vec(pnt(surface.origin).XYZ() + radial.XYZ() * surface.majorRadius);
                                circle.xAxis = vec(radial.XYZ());
                                circle.direction = vec(radial.Crossed(gp_Vec(axis)).XYZ());
                                circle.radius = surface.minorRadius;
                                const int vertex = int(out.vertices.size());
                                out.vertices.push_back(vec(pnt(circle.origin).XYZ() + radial.XYZ() * circle.radius));
                                boundary[side] = int(out.edges.size());
                                out.edges.push_back({int(out.curves.size()), vertex, vertex});
                                out.curves.push_back(std::move(circle));
                            }
                            for (int side = 0; side < 2; ++side) {
                                DescribedFace band = described;
                                band.surface = int(out.surfaces.size());
                                band.loops = {{{boundary[side], described.reversed}},
                                              {{boundary[1 - side], !described.reversed}}};
                                out.surfaces.push_back(surface);
                                faces.push_back(int(out.faces.size()));
                                out.faces.push_back(std::move(band));
                            }
                            continue;
                        }
                        if (surface.kind != DescribedSurface::Kind::Sphere)
                            return R::fail({cadnext::ErrorCode::UnsupportedOperation,
                                            what("грань", faceMap.Extent()) + ": замкнутая поверхность без поддержанного разбиения"});
                        // A whole sphere: two hemispheres on the equator of its frame.
                        const gp_Dir axis = dir(surface.axis), x = dir(surface.xAxis);
                        const gp_Pnt centre = pnt(surface.origin);
                        // A vertex on the equator for the loop chaining; the ring pass below takes
                        // it off again, as it meets no other edge.
                        const int vertex = int(out.vertices.size());
                        out.vertices.push_back(vec(centre.XYZ() + gp_Vec(x).XYZ() * surface.radius));
                        DescribedCurve equator;
                        equator.kind = DescribedCurve::Kind::Circle;
                        equator.origin = surface.origin;
                        equator.direction = surface.axis;
                        equator.xAxis = surface.xAxis;
                        equator.radius = surface.radius;
                        const int edge = int(out.edges.size());
                        out.edges.push_back({int(out.curves.size()), vertex, vertex});
                        out.curves.push_back(equator);
                        // At the vertex the circle runs along axis × x; the face on its left,
                        // looking against the face normal, is the upper one for an outward normal.
                        const gp_Vec normal = gp_Vec(x) * (described.reversed ? -1.0 : 1.0);
                        const bool upperForward = normal.Crossed(gp_Vec(axis.Crossed(x))).Dot(gp_Vec(axis)) > 0.0;
                        DescribedFace upper = described, lower = described;
                        upper.surface = int(out.surfaces.size());
                        upper.loops = {{{edge, upperForward}}};
                        lower.surface = int(out.surfaces.size()) + 1;
                        lower.loops = {{{edge, !upperForward}}};
                        out.surfaces.push_back(surface);
                        out.surfaces.push_back(surface);
                        faces.push_back(int(out.faces.size()));
                        out.faces.push_back(std::move(upper));
                        faces.push_back(int(out.faces.size()));
                        out.faces.push_back(std::move(lower));
                        continue;
                    }
                    described.surface = int(out.surfaces.size());
                    out.surfaces.push_back(std::move(surface));
                    faces.push_back(int(out.faces.size()));
                    out.faces.push_back(std::move(described));
                }
                lump.shells.push_back(std::move(faces));
            }
            out.lumps.push_back(std::move(lump));
        }
        if (out.lumps.empty())
            return R::fail({cadnext::ErrorCode::UnsupportedOperation, "в форме нет твёрдого тела (листовые и каркасные тела пока не выводятся)"});
        std::size_t loose = 0;
        for (TopExp_Explorer it(*shape, TopAbs_FACE, TopAbs_SOLID); it.More(); it.Next()) ++loose;
        if (loose) return R::fail({cadnext::ErrorCode::UnsupportedOperation, "в форме есть грани вне твёрдых тел"});

        // A solid's edge separates exactly two faces, once in each direction.
        std::vector<int> forwardUses(out.edges.size(), 0), backwardUses(out.edges.size(), 0);
        for (const DescribedFace& face : out.faces)
            for (const auto& loop : face.loops)
                for (const DescribedCoedge& coedge : loop) ++(coedge.forward ? forwardUses : backwardUses)[std::size_t(coedge.edge)];
        for (std::size_t e = 0; e < out.edges.size(); ++e)
            if (forwardUses[e] != 1 || backwardUses[e] != 1)
                return R::fail({cadnext::ErrorCode::ShapeInvalid, what("ребро", int(e) + 1) + " не разделяет ровно две грани"});

        // Arcs of one circle or ellipse that meet at a vertex nothing else uses, with the same two
        // faces on either side, are one edge: OCCT keeps a full circle as two halves, Parasolid as
        // one ring. Such a vertex has no corner and no crease; merging keeps every face and every
        // point of the boundary.
        const auto sameConic = [&](const DescribedCurve& a, const DescribedCurve& b) {
            if (a.kind != b.kind || (a.kind != DescribedCurve::Kind::Circle && a.kind != DescribedCurve::Kind::Ellipse)) return false;
            const auto near = [](const cadnext::Vector3& p, const cadnext::Vector3& q, double tolerance) {
                return std::fabs(p.x - q.x) <= tolerance && std::fabs(p.y - q.y) <= tolerance && std::fabs(p.z - q.z) <= tolerance;
            };
            const double size = std::max({a.radius, a.majorRadius, 1e-3});
            if (!near(a.origin, b.origin, 1e-12 * size + 1e-15) || !near(a.direction, b.direction, 1e-12)) return false;
            if (a.kind == DescribedCurve::Kind::Circle) return std::fabs(a.radius - b.radius) <= 1e-12 * size;
            return near(a.xAxis, b.xAxis, 1e-12) && std::fabs(a.majorRadius - b.majorRadius) <= 1e-12 * size &&
                   std::fabs(a.minorRadius - b.minorRadius) <= 1e-12 * size;
        };
        for (bool merged = true; merged;) {
            merged = false;
            std::vector<std::vector<int>> atVertex(out.vertices.size());
            for (std::size_t e = 0; e < out.edges.size(); ++e) {
                const DescribedEdge& edge = out.edges[e];
                if (edge.curve < 0 || edge.start == edge.end) continue;
                atVertex[std::size_t(edge.start)].push_back(int(e));
                atVertex[std::size_t(edge.end)].push_back(int(e));
            }
            std::vector<bool> closedHere(out.vertices.size(), false);
            for (const DescribedEdge& edge : out.edges)
                if (edge.curve >= 0 && edge.start == edge.end) closedHere[std::size_t(edge.start)] = true;
            for (std::size_t v = 0; v < out.vertices.size() && !merged; ++v) {
                if (atVertex[v].size() != 2 || closedHere[v]) continue;
                int first = atVertex[v][0], second = atVertex[v][1];
                if (out.edges[std::size_t(first)].end != int(v)) std::swap(first, second);
                DescribedEdge& a = out.edges[std::size_t(first)];
                const DescribedEdge& b = out.edges[std::size_t(second)];
                if (a.end != int(v) || b.start != int(v) || !sameConic(out.curves[std::size_t(a.curve)], out.curves[std::size_t(b.curve)]))
                    continue;
                // Both faces must run a then b (or b back then a back) consecutively in one loop.
                int consecutive = 0;
                for (DescribedFace& face : out.faces) {
                    for (auto& loop : face.loops) {
                        for (std::size_t i = 0; i < loop.size(); ++i) {
                            const DescribedCoedge& here = loop[i];
                            const DescribedCoedge& next = loop[(i + 1) % loop.size()];
                            if (here.pcurve || next.pcurve) continue;
                            if ((here.edge == first && here.forward && next.edge == second && next.forward) ||
                                (here.edge == second && !here.forward && next.edge == first && !next.forward))
                                ++consecutive;
                        }
                    }
                }
                if (consecutive != 2) continue;
                a.end = b.end;
                // Merged circles can have different zero-angle axes. Their new interval
                // is recovered from vertices; no transferred UV boundary uses these arcs.
                a.firstParameter = a.lastParameter = 0.0;
                for (DescribedFace& face : out.faces)
                    for (auto& loop : face.loops)
                        loop.erase(std::remove_if(loop.begin(), loop.end(), [&](const DescribedCoedge& c) { return c.edge == second; }),
                                   loop.end());
                out.edges[std::size_t(second)].curve = -1; // retired below
                merged = true;
            }
        }
        {
            // Drop retired edges and renumber the rest.
            std::vector<int> edgeRenumbered(out.edges.size(), -1);
            std::vector<DescribedEdge> keptEdges;
            for (std::size_t e = 0; e < out.edges.size(); ++e) {
                if (out.edges[e].curve < 0) continue;
                edgeRenumbered[e] = int(keptEdges.size());
                keptEdges.push_back(out.edges[e]);
            }
            for (DescribedFace& face : out.faces)
                for (auto& loop : face.loops)
                    for (DescribedCoedge& c : loop) c.edge = edgeRenumbered[std::size_t(c.edge)];
            out.edges = std::move(keptEdges);
        }

        // Ring edges: a closed circle, ellipse or periodic B-spline whose vertex no open edge needs
        // loses the vertex.
        std::vector<bool> needed(out.vertices.size(), false);
        for (const DescribedEdge& e : out.edges) {
            const auto& curve = out.curves[std::size_t(e.curve)];
            const bool ring = e.start == e.end &&
                              (curve.kind == DescribedCurve::Kind::Circle || curve.kind == DescribedCurve::Kind::Ellipse ||
                               (curve.kind == DescribedCurve::Kind::BSpline && curve.periodic));
            if (!ring) needed[std::size_t(e.start)] = needed[std::size_t(e.end)] = true;
        }
        std::vector<int> renumbered(out.vertices.size(), -1);
        std::vector<cadnext::Vector3> kept;
        for (std::size_t v = 0; v < out.vertices.size(); ++v) {
            if (!needed[v]) continue;
            renumbered[v] = int(kept.size());
            kept.push_back(out.vertices[v]);
        }
        for (DescribedEdge& e : out.edges) {
            e.start = renumbered[std::size_t(e.start)];
            e.end = renumbered[std::size_t(e.end)];
        }
        out.vertices = std::move(kept);
        return R::ok(std::move(out));
    } catch (const Standard_Failure& failure) {
        return R::fail({cadnext::ErrorCode::KernelOperationFailed, std::string("описание BRep: ") + failure.GetMessageString()});
    }
}

#endif

} // namespace cadnext::kernel
