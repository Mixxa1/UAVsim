#ifdef CADNEXT_WITH_OCCT
#include "OcctRollingBall.hpp"

#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BSplCLib.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Circle.hxx>
#include <Geom_Curve.hxx>
#include <Geom_Ellipse.hxx>
#include <Geom_Line.hxx>
#include <Geom_OffsetSurface.hxx>
#include <Geom_Surface.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <Standard_Failure.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <TColStd_HArray1OfReal.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <gp_Pnt2d.hxx>

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <map>
#include <vector>
#include <cstdio>

namespace cadnext::kernel::rolling_ball {
namespace {

constexpr double kPi = 3.14159265358979323846;
// What the approximation aims for, and the bound beyond which a blend is refused (the user's
// choice). The aim sits below the builder's 1e-7 checks of an edge against its surfaces, so that
// an edge through a blend is not refused for the blend's error alone.
constexpr double kTarget = 1e-8;
constexpr double kLimit = 1e-6;
constexpr int kFirstSections = 16;
constexpr int kMaxSections = 2048;
// Each cross-section's arc runs this far past both contact points, so that the face's contact edges
// lie inside the surface rather than on its border.
constexpr double kArcOvershoot = 0.02;

gp_Pnt toPnt(const cadnext::Vector3& v) { return {v.x, v.y, v.z}; }
gp_Vec toVec(const cadnext::Vector3& v) { return {v.x, v.y, v.z}; }

bool normalized(const gp_Vec& v, gp_Vec& out) {
    const double m = v.Magnitude();
    if (!(m > 1e-300) || !std::isfinite(m)) return false;
    out = v / m;
    return true;
}

bool positiveFinite(double v) { return std::isfinite(v) && v > 0.0; }

Handle(Geom_BSplineSurface) bsplineSurface(const BSplineSurfaceDefinition& d, int ordering) {
    const int nu = d.uPoleCount, nv = d.vPoleCount;
    if (nu < 2 || nv < 2 || nu > 100'000 / nv || d.poles.size() != std::size_t(nu * nv) ||
        d.weights.size() != std::size_t(nu * nv) || d.uKnots.size() != d.uMultiplicities.size() ||
        d.vKnots.size() != d.vMultiplicities.size() || d.uKnots.size() < 2 || d.vKnots.size() < 2)
        return {};
    TColStd_Array1OfReal uKnots(1, int(d.uKnots.size())), vKnots(1, int(d.vKnots.size()));
    TColStd_Array1OfInteger uMult(1, int(d.uKnots.size())), vMult(1, int(d.vKnots.size()));
    for (int i = 0; i < uKnots.Length(); ++i) {
        uKnots.SetValue(i + 1, d.uKnots[i]);
        uMult.SetValue(i + 1, d.uMultiplicities[i]);
    }
    for (int i = 0; i < vKnots.Length(); ++i) {
        vKnots.SetValue(i + 1, d.vKnots[i]);
        vMult.SetValue(i + 1, d.vMultiplicities[i]);
    }
    TColgp_Array2OfPnt poles(1, nu, 1, nv);
    TColStd_Array2OfReal weights(1, nu, 1, nv);
    for (int u = 0; u < nu; ++u) {
        for (int v = 0; v < nv; ++v) {
            const int i = ordering == 0 ? u * nv + v : v * nu + u;
            poles.SetValue(u + 1, v + 1, toPnt(d.poles[i]));
            weights.SetValue(u + 1, v + 1, d.weights[i]);
        }
    }
    try {
        return new Geom_BSplineSurface(poles, weights, uKnots, vKnots, uMult, vMult, d.uDegree, d.vDegree,
                                       d.uPeriodic, d.vPeriodic);
    } catch (const Standard_Failure&) {
        return {};
    }
}

// A support of the blend, or one of the surfaces whose intersection is its spine: the nearest point
// to a given one, the natural normal there (as XT's), and the signed distance along it.
class Surface {
public:
    bool init(const AnalyticSurfaceSupport& s, int ordering) {
        kind_ = s.kind;
        hasLast_ = false;
        blendPosition_=blendAngle_=std::numeric_limits<double>::quiet_NaN();
        blend_.reset();
        if (kind_ == AnalyticSurfaceSupport::Kind::Edge) return initEdge(s);
        origin_ = toPnt(s.origin);
        if (!normalized(toVec(s.normal), axis_) || !normalized(toVec(s.xAxis), x_)) {
            if (kind_ != AnalyticSurfaceSupport::Kind::BSpline && kind_ != AnalyticSurfaceSupport::Kind::BSplineOffset &&
                kind_ != AnalyticSurfaceSupport::Kind::Blend)
                return false;
        }
        radius_ = s.radius;
        semiAngle_ = s.semiAngle;
        major_ = s.majorRadius;
        minor_ = s.minorRadius;
        normalSign_ = ordering == 0 ? 1.0 : -1.0; // transposing a grid turns its normal over
        switch (kind_) {
        case AnalyticSurfaceSupport::Kind::Plane: return true;
        case AnalyticSurfaceSupport::Kind::Cylinder:
        case AnalyticSurfaceSupport::Kind::Sphere: return positiveFinite(radius_);
        case AnalyticSurfaceSupport::Kind::Cone:
            return positiveFinite(radius_) && std::isfinite(semiAngle_) && std::fabs(semiAngle_) < kPi / 2 - 1e-10;
        case AnalyticSurfaceSupport::Kind::Torus: return positiveFinite(major_) && positiveFinite(minor_);
        case AnalyticSurfaceSupport::Kind::BSpline:
        case AnalyticSurfaceSupport::Kind::BSplineOffset: {
            // An offset's foot is its basis's foot (the same normals), moved along the normal: so
            // only the basis is evaluated, which needs no more continuity than the B-spline has
            // (OCCT refuses an offset of a surface with C0 knots).
            const Handle(Geom_BSplineSurface) basis = bsplineSurface(s.bspline, ordering);
            if (basis.IsNull()) return false;
            offset_ = 0.0;
            if (kind_ == AnalyticSurfaceSupport::Kind::BSplineOffset) {
                if (!std::isfinite(s.offsetDistance) || std::fabs(s.offsetDistance) < 1e-12) return false;
                offset_ = s.offsetDistance;
            }
            geometry_ = basis;
            try {
                analysis_ = new ShapeAnalysis_Surface(geometry_);
            } catch (const Standard_Failure&) {
                return false;
            }
            return true;
        }
        case AnalyticSurfaceSupport::Kind::Blend: {
            // Another blend: project onto its original procedural sections. The B-spline is only
            // the bounded approximation used for the resulting BRep.
            thread_local int depth = 0;
            if (!s.blend || depth > 2) return false;
            ++depth;
            const auto other=buildBlend(s.blend);
            --depth;
            if (!other || other->surface().IsNull()) return false;
            geometry_ = other->surface();
            blend_=other;
            offset_ = s.offsetDistance;
            try {
                analysis_ = new ShapeAnalysis_Surface(geometry_);
            } catch (const Standard_Failure&) {
                return false;
            }
            return true;
        }
        case AnalyticSurfaceSupport::Kind::Edge: return false;
        case AnalyticSurfaceSupport::Kind::Swept: return false;
        }
        return false;
    }

    bool numeric() const { return !geometry_.IsNull(); }
    // The next foot searched for afresh, not from the last one: before a new run of points.
    void restart() const {
        hasLast_ = false;
        blendPosition_=blendAngle_=std::numeric_limits<double>::quiet_NaN();
    }

    // A sharp edge as a support: its curve; a line and a circle by closed form, others by projection.
    bool initEdge(const AnalyticSurfaceSupport& s) {
        if (!s.edge) return false;
        const AnalyticEdgeSegment& e = *s.edge;
        edgeKind_ = e.kind;
        origin_ = toPnt(e.center);
        try {
            switch (e.kind) {
            case AnalyticEdgeKind::Line:
                return normalized(toVec(e.normal), axis_);
            case AnalyticEdgeKind::Circle:
                radius_ = e.radius;
                return positiveFinite(radius_) && normalized(toVec(e.normal), axis_) && normalized(toVec(e.xAxis), x_);
            case AnalyticEdgeKind::Ellipse: {
                gp_Vec n, x;
                if (!normalized(toVec(e.normal), n) || !normalized(toVec(e.xAxis), x) || !positiveFinite(e.minorRadius) ||
                    e.minorRadius > e.majorRadius)
                    return false;
                edgeCurve_ = new Geom_Ellipse(gp_Ax2(origin_, gp_Dir(n), gp_Dir(x)), e.majorRadius, e.minorRadius);
                return true;
            }
            case AnalyticEdgeKind::BSpline: {
                const auto& b = e.bspline;
                const int count = int(b.poles.size()), knots = int(b.knots.size());
                if (count < 2 || count != int(b.weights.size()) || knots < 2 || knots != int(b.multiplicities.size()) ||
                    b.degree < 1 || b.degree >= count)
                    return false;
                TColgp_Array1OfPnt poles(1, count);
                TColStd_Array1OfReal weights(1, count), knotValues(1, knots);
                TColStd_Array1OfInteger multiplicities(1, knots);
                for (int i = 0; i < count; ++i) {
                    poles.SetValue(i + 1, toPnt(b.poles[i]));
                    weights.SetValue(i + 1, b.weights[i]);
                }
                for (int i = 0; i < knots; ++i) {
                    knotValues.SetValue(i + 1, b.knots[i]);
                    multiplicities.SetValue(i + 1, b.multiplicities[i]);
                }
                edgeCurve_ = new Geom_BSplineCurve(poles, weights, knotValues, multiplicities, b.degree, b.periodic);
                return true;
            }
            default:
                return false;
            }
        } catch (const Standard_Failure&) {
            return false;
        }
    }

    // `f` the nearest point of the surface to `p`, `n` the unit natural normal at `f`, `distance`
    // the signed distance of `p` along it.
    bool foot(const gp_Pnt& p, gp_Pnt& f, gp_Vec& n, double& distance) const {
        const gp_Vec w(origin_, p);
        const auto radial = [&](double& along, gp_Vec& e) {
            along = w.Dot(axis_);
            const gp_Vec r = w - axis_ * along;
            if (!normalized(r, e)) e = x_;
            return r.Magnitude();
        };
        switch (kind_) {
        case AnalyticSurfaceSupport::Kind::Plane: {
            distance = w.Dot(axis_);
            n = axis_;
            f = p.Translated(-axis_ * distance);
            return true;
        }
        case AnalyticSurfaceSupport::Kind::Cylinder: {
            double along;
            gp_Vec e;
            const double rho = radial(along, e);
            n = e;
            distance = rho - radius_;
            f = origin_.Translated(axis_ * along + e * radius_);
            return true;
        }
        case AnalyticSurfaceSupport::Kind::Sphere: {
            gp_Vec e;
            if (!normalized(w, e)) return false;
            n = e;
            distance = w.Magnitude() - radius_;
            f = origin_.Translated(e * radius_);
            return true;
        }
        case AnalyticSurfaceSupport::Kind::Cone: {
            // In the half-plane through the axis: radius R + h·tan(α) at height h, so the generator
            // through (R, 0) runs along (sin α, cos α) and the outward normal is (cos α, −sin α).
            double along;
            gp_Vec e;
            const double rho = radial(along, e);
            const double s = std::sin(semiAngle_), c = std::cos(semiAngle_);
            const double t = (rho - radius_) * s + along * c;
            const double footRho = radius_ + t * s, footAlong = t * c;
            if (footRho < 0.0) return false; // past the apex
            n = e * c - axis_ * s;
            distance = (rho - radius_) * c - along * s;
            f = origin_.Translated(axis_ * footAlong + e * footRho);
            return true;
        }
        case AnalyticSurfaceSupport::Kind::Torus: {
            double along;
            gp_Vec e;
            radial(along, e);
            const gp_Pnt centre = origin_.Translated(e * major_);
            gp_Vec d(centre, p), e2;
            if (!normalized(d, e2)) return false;
            n = e2;
            distance = d.Magnitude() - minor_;
            f = centre.Translated(e2 * minor_);
            return true;
        }
        case AnalyticSurfaceSupport::Kind::BSpline:
        case AnalyticSurfaceSupport::Kind::BSplineOffset:
            return numericFoot(p, f, n, distance);
        case AnalyticSurfaceSupport::Kind::Edge: {
            // The nearest point of the edge's curve; the "normal" points from it to p, so the
            // distance is never negative (a ball touches an edge from one side only).
            if (edgeKind_ == AnalyticEdgeKind::Line) {
                f = origin_.Translated(axis_ * w.Dot(axis_));
            } else if (edgeKind_ == AnalyticEdgeKind::Circle) {
                double along;
                gp_Vec e;
                radial(along, e);
                f = origin_.Translated(e * radius_);
            } else {
                try {
                    const GeomAPI_ProjectPointOnCurve projection(p, edgeCurve_);
                    if (!projection.NbPoints()) return false;
                    f = projection.NearestPoint();
                } catch (const Standard_Failure&) {
                    return false;
                }
            }
            const gp_Vec away(f, p);
            distance = away.Magnitude();
            return normalized(away, n);
        }
        case AnalyticSurfaceSupport::Kind::Blend:
            if (!blend_) return false;
            if (!blend_->foot(p,f,n,distance,blendPosition_,blendAngle_)) {
                // A new Newton run can start far from the preceding contact. Recover its own
                // section instead of carrying a different contact branch into the new run.
                blendPosition_=blendAngle_=std::numeric_limits<double>::quiet_NaN();
                if (!blend_->foot(p,f,n,distance,blendPosition_,blendAngle_)) return false;
            }
            f.Translate(n*offset_);
            n*=normalSign_;
            distance=gp_Vec(f,p).Dot(n);
            return true;
        case AnalyticSurfaceSupport::Kind::Swept: return false;
        }
        return false;
    }

private:
    bool numericFoot(const gp_Pnt& p, gp_Pnt& f, gp_Vec& n, double& distance) const {
        const auto evaluate = [&](const gp_Pnt2d& uv, gp_Pnt& at, gp_Vec& du, gp_Vec& dv) {
            geometry_->D1(uv.X(), uv.Y(), at, du, dv);
        };
        // A foot is where p − S(u, v) is square to both tangents; a stored neighbour's foot is the
        // guess, the global searches the fallback (both kept, the nearer taken).
        const auto orthogonal = [&](const gp_Pnt2d& uv) {
            gp_Pnt at;
            gp_Vec du, dv;
            evaluate(uv, at, du, dv);
            const gp_Vec e(at, p);
            return std::fabs(e.Dot(du)) <= 1e-9 * du.Magnitude() && std::fabs(e.Dot(dv)) <= 1e-9 * dv.Magnitude();
        };
        // Newton on (S − p)·Su = (S − p)·Sv = 0 from the previous foot: the calls come in order along
        // the spine, so it is close.
        const auto newton = [&](gp_Pnt2d& at) {
            double u = at.X(), v = at.Y();
            for (int i = 0; i < 30; ++i) {
                gp_Pnt s;
                gp_Vec su, sv, suu, svv, suv;
                geometry_->D2(u, v, s, su, sv, suu, svv, suv);
                const gp_Vec e(p, s);
                const double f1 = e.Dot(su), f2 = e.Dot(sv);
                const double a = su.Dot(su) + e.Dot(suu), b = su.Dot(sv) + e.Dot(suv), c = sv.Dot(sv) + e.Dot(svv);
                const double det = a * c - b * b;
                if (!(std::fabs(det) > 1e-300)) return false;
                const double du = -(c * f1 - b * f2) / det, dv = -(a * f2 - b * f1) / det;
                u += du;
                v += dv;
                if ((su * du + sv * dv).Magnitude() < 1e-15) {
                    at.SetCoord(u, v);
                    return true;
                }
            }
            return false;
        };
        // Beyond its domain a B-spline is continued here as its end polynomials, but by Parasolid
        // otherwise: a foot there is not a point of the source's surface (NIST ftc_07: 1 mm apart).
        const auto inDomain = [&](gp_Pnt2d& at) {
            double u0, u1, v0, v1;
            geometry_->Bounds(u0, u1, v0, v1);
            double u = at.X(), v = at.Y();
            if (geometry_->IsUPeriodic()) u = u0 + std::fmod(std::fmod(u - u0, u1 - u0) + (u1 - u0), u1 - u0);
            if (geometry_->IsVPeriodic()) v = v0 + std::fmod(std::fmod(v - v0, v1 - v0) + (v1 - v0), v1 - v0);
            const double su = 1e-9 * (u1 - u0), sv = 1e-9 * (v1 - v0);
            if (u < u0 - su || u > u1 + su || v < v0 - sv || v > v1 + sv) return false;
            at.SetCoord(u, v);
            return true;
        };
        // Newton finds any stationary point — on a closed surface also the far side's: a foot must be
        // no farther than where the search started.
        const auto nearer = [&](const gp_Pnt2d& from, const gp_Pnt2d& to) {
            return geometry_->Value(to.X(), to.Y()).Distance(p) <=
                   geometry_->Value(from.X(), from.Y()).Distance(p) + 1e-12;
        };
        gp_Pnt2d uv;
        bool found = false;
        try {
            if (hasLast_) {
                uv = last_;
                found = newton(uv) && orthogonal(uv) && nearer(last_, uv) && inDomain(uv);
            }
            if (!found) {
                // A far guess can lead Newton to another stationary point, or past the domain: then
                // the global searches.
                uv = analysis_->ValueOfUV(p, 1e-12);
                gp_Pnt2d polished = uv;
                if (newton(polished) && orthogonal(polished) && nearer(uv, polished) && inDomain(polished)) uv = polished;
                double best = geometry_->Value(uv.X(), uv.Y()).Distance(p);
                // Both searches, the nearer kept: on a helical thread either may stop on the next turn,
                // a pitch away (0.6 mm on a McMaster nut).
                const GeomAPI_ProjectPointOnSurf projection(p, geometry_);
                if (projection.NbPoints() && projection.LowerDistance() < best - 1e-12) {
                    double u, v;
                    projection.LowerDistanceParameters(u, v);
                    uv.SetCoord(u, v);
                    best = projection.LowerDistance();
                }
                // Not square to the surface: the nearest point is past the domain's edge.
                found = std::isfinite(best) && orthogonal(uv) && inDomain(uv);
            }
        } catch (const Standard_Failure&) {
            return false;
        }
        if (!found) return false;
        gp_Vec du, dv;
        evaluate(uv, f, du, dv);
        if (!normalized(du.Crossed(dv), n)) return false;
        f.Translate(n * offset_); // OCCT's offset: along the basis's Su × Sv
        n *= normalSign_;
        distance = gp_Vec(f, p).Dot(n);
        last_ = uv;
        hasLast_ = true;
        return true;
    }

    AnalyticSurfaceSupport::Kind kind_ = AnalyticSurfaceSupport::Kind::Plane;
    gp_Pnt origin_;
    gp_Vec axis_{0, 0, 1}, x_{1, 0, 0};
    double radius_ = 0, semiAngle_ = 0, major_ = 0, minor_ = 0, normalSign_ = 1, offset_ = 0;
    Handle(Geom_Surface) geometry_;
    Handle(ShapeAnalysis_Surface) analysis_;
    AnalyticEdgeKind edgeKind_ = AnalyticEdgeKind::Line;
    Handle(Geom_Curve) edgeCurve_;
    mutable gp_Pnt2d last_;
    std::shared_ptr<const Blend> blend_;
    mutable double blendPosition_=std::numeric_limits<double>::quiet_NaN();
    mutable double blendAngle_=std::numeric_limits<double>::quiet_NaN();
    mutable bool hasLast_ = false;
};

// The spine: an exact curve, or the intersection of two surfaces evaluated exactly (Newton) from
// its chart. Positions along it are cumulative chords of a dense exact sampling: a parameter close
// to arc length, the same for every use of the blend.
class Spine {
public:
    bool init(const RollingBallBlend& d, std::string& error) {
        const AnalyticEdgeSegment& s = d.spine;
        closed_ = false;
        if (s.kind == AnalyticEdgeKind::SurfaceIntersection) return initIntersection(d, error);
        try {
            if (s.kind == AnalyticEdgeKind::Line) {
                gp_Vec direction;
                if (!normalized(toVec(s.normal), direction)) { error = "spine line has no direction"; return false; }
                curve_ = new Geom_Line(toPnt(s.center), gp_Dir(direction));
                // A line spine is unbounded: sampled over the blend's faces and a margin.
                double low = std::numeric_limits<double>::infinity(), high = -low;
                for (const auto& edge : d.faceEdges)
                    for (const auto& p : edge) {
                        const double t = gp_Vec(toPnt(s.center), toPnt(p)).Dot(direction);
                        low = std::min(low, t);
                        high = std::max(high, t);
                    }
                if (!(high >= low)) { error = "a straight spine needs the blend's face"; return false; }
                sampleCurve(low - 4 * d.radius, high + 4 * d.radius, 64);
                return true;
            }
            if (s.kind == AnalyticEdgeKind::Circle || s.kind == AnalyticEdgeKind::Ellipse) {
                gp_Vec normal, x;
                if (!normalized(toVec(s.normal), normal) || !normalized(toVec(s.xAxis), x)) {
                    error = "spine conic has no frame";
                    return false;
                }
                const gp_Ax2 frame(toPnt(s.center), gp_Dir(normal), gp_Dir(x));
                if (s.kind == AnalyticEdgeKind::Circle) {
                    if (!positiveFinite(s.radius)) { error = "spine circle radius"; return false; }
                    curve_ = new Geom_Circle(frame, s.radius);
                } else {
                    if (!positiveFinite(s.majorRadius) || !positiveFinite(s.minorRadius) || s.minorRadius > s.majorRadius) {
                        error = "spine ellipse radii";
                        return false;
                    }
                    curve_ = new Geom_Ellipse(frame, s.majorRadius, s.minorRadius);
                }
                closed_ = true;
                sampleCurve(0.0, 2 * kPi, 1024);
                return true;
            }
            if (s.kind == AnalyticEdgeKind::BSpline) {
                const auto& b = s.bspline;
                const int count = int(b.poles.size()), knots = int(b.knots.size());
                if (count < 2 || count != int(b.weights.size()) || knots < 2 || knots != int(b.multiplicities.size()) ||
                    b.degree < 1 || b.degree >= count) {
                    error = "spine B-spline is invalid";
                    return false;
                }
                TColgp_Array1OfPnt poles(1, count);
                TColStd_Array1OfReal weights(1, count), knotValues(1, knots);
                TColStd_Array1OfInteger multiplicities(1, knots);
                for (int i = 0; i < count; ++i) {
                    poles.SetValue(i + 1, toPnt(b.poles[i]));
                    weights.SetValue(i + 1, b.weights[i]);
                }
                for (int i = 0; i < knots; ++i) {
                    knotValues.SetValue(i + 1, b.knots[i]);
                    multiplicities.SetValue(i + 1, b.multiplicities[i]);
                }
                const Handle(Geom_BSplineCurve) spline =
                    new Geom_BSplineCurve(poles, weights, knotValues, multiplicities, b.degree, b.periodic);
                curve_ = spline;
                double first = spline->FirstParameter(), last = spline->LastParameter();
                closed_ = b.periodic || spline->Value(first).Distance(spline->Value(last)) < 1e-9;
                if (limited_) {
                    if (!(limitHigh_ > limitLow_) || limitHigh_ < first || limitLow_ > last) {
                        error = "the spine's limits are outside its domain";
                        return false;
                    }
                    first = std::max(first, limitLow_);
                    last = std::min(last, limitHigh_);
                    closed_ = false;
                }
                sampleCurve(first, last, std::max(256, 32 * knots));
                return true;
            }
        } catch (const Standard_Failure& failure) {
            error = std::string("spine: ") + failure.GetMessageString();
            return false;
        }
        error = "spine curve kind is not supported";
        return false;
    }

    bool closed() const { return closed_; }
    double length() const { return positions_.back(); }
    double wrap(double s) const {
        if (!closed_) return s;
        const double l = length();
        s = std::fmod(s, l);
        return s < 0 ? s + l : s;
    }

    // The exact spine point at position `s` (outside the sampled range of an open spine: continued),
    // and its unit tangent in the direction of increasing position.
    bool at(double s, gp_Pnt& c, gp_Vec& tangent) const {
        s = wrap(s);
        const std::size_t count = points_.size();
        const std::size_t segments = closed_ ? count : count - 1;
        std::size_t j = std::size_t(std::upper_bound(positions_.begin(), positions_.begin() + segments + 1, s) -
                                    positions_.begin());
        j = j == 0 ? 0 : j - 1;
        j = std::min(j, segments - 1);
        const double span = positions_[j + 1] - positions_[j];
        const double fraction = (s - positions_[j]) / span;
        try {
            if (!curve_.IsNull()) {
                gp_Vec d1;
                curve_->D1(params_[j] + fraction * (params_[j + 1] - params_[j]), c, d1);
                return normalized(d1, tangent);
            }
            const gp_Pnt& a = points_[j];
            const gp_Pnt& b = points_[(j + 1) % count];
            gp_Vec chord;
            if (!normalized(gp_Vec(a, b), chord)) return false;
            const gp_Pnt guess = a.Translated(gp_Vec(a, b) * fraction);
            c = guess;
            const bool nearTerminator = terminatorSegment(j / 16); // 16 dense pieces per chart step
            if (!refine(c, chord, guess)) {
                if (!nearTerminator) return false;
                c = guess;
            }
            // At a terminator the two normals are parallel and give no tangent: the chord's then.
            gp_Pnt f;
            gp_Vec n1, n2;
            double distance;
            const bool normals = surfaces_[0].foot(c, f, n1, distance) && surfaces_[1].foot(c, f, n2, distance);
            if (!normals && !nearTerminator) return false;
            const gp_Vec across = normals ? n1.Crossed(n2) : gp_Vec();
            if ((nearTerminator && across.Magnitude() < 1e-9) || !normalized(across, tangent)) {
                if (!nearTerminator) return false;
                tangent = chord;
            }
            if (tangent.Dot(chord) < 0) tangent.Reverse();
            return true;
        } catch (const Standard_Failure&) {
            return false;
        }
    }

    // The position of the spine point nearest to `q`: from the nearest dense sample, or from `guess`.
    bool foot(const gp_Pnt& q, double& s) const {
        std::size_t best = 0;
        double nearest = std::numeric_limits<double>::infinity();
        for (std::size_t j = 0; j < points_.size(); ++j) {
            const double d = points_[j].SquareDistance(q);
            if (d < nearest) { nearest = d; best = j; }
        }
        return footNear(q, positions_[best], s);
    }

    bool footNear(const gp_Pnt& q, double guess, double& s) const {
        // Secant on g(s) = (C(s) − q)·T(s), whose slope is 1 − κ·(q − C)·N: near 1 for a ball
        // smaller than the spine's radius of curvature.
        const auto g = [&](double at, double& value) {
            gp_Pnt c;
            gp_Vec t;
            if (!this->at(at, c, t)) return false;
            value = gp_Vec(q, c).Dot(t);
            return std::isfinite(value);
        };
        double s0 = guess, g0;
        if (!g(s0, g0)) return false;
        double s1 = s0 - g0, g1;
        for (int i = 0; i < 60; ++i) {
            if (!g(s1, g1)) return false;
            if (std::fabs(g1) < 1e-14 || std::fabs(s1 - s0) < 1e-15) break;
            const double slope = (g1 - g0) / (s1 - s0);
            double next = s1 - g1 / (std::fabs(slope) > 1e-3 ? slope : 1.0);
            s0 = s1;
            g0 = g1;
            s1 = next;
        }
        // Past a terminator there is no spine: the nearest point is the end itself (a minimum on the
        // boundary, where the foot's condition need not hold).
        const double length = positions_.back();
        if (!closed_ && terminatorEnd_ && s1 > length) { s = length; return true; }
        if (!closed_ && terminatorStart_ && s1 < 0.0) { s = 0.0; return true; }
        // Nested procedural supports are solved numerically. Their unit tangent carries roundoff
        // from those solves; a sub-nanometre stationarity residual already makes the distance error
        // quadratic and well below the surface approximation target.
        if (!(std::fabs(g1) < 1e-9)) {
            if (closed_ || (!terminatorStart_ && !terminatorEnd_)) return false;
            // Next to a terminator the nearest point may be the end itself: the least distance over a
            // window round the guess, kept on the spine.
            const double reach = 0.05 * length;
            double a = std::max(0.0, guess - reach), b = std::min(length, guess + reach);
            const auto distance = [&](double at) {
                gp_Pnt c;
                gp_Vec t;
                return this->at(at, c, t) ? c.SquareDistance(q) : std::numeric_limits<double>::infinity();
            };
            constexpr double golden = 0.6180339887498949;
            double x1 = b - golden * (b - a), x2 = a + golden * (b - a);
            double f1 = distance(x1), f2 = distance(x2);
            for (int i = 0; i < 200 && b - a > 1e-15; ++i) {
                if (f1 < f2) {
                    b = x2;
                    x2 = x1;
                    f2 = f1;
                    x1 = b - golden * (b - a);
                    f1 = distance(x1);
                } else {
                    a = x1;
                    x1 = x2;
                    f1 = f2;
                    x2 = a + golden * (b - a);
                    f2 = distance(x2);
                }
            }
            s = 0.5 * (a + b);
            return std::isfinite(distance(s));
        }
        s = wrap(s1);
        return true;
    }

    const std::vector<gp_Pnt>& samples() const { return points_; }
    const std::vector<double>& positions() const { return positions_; }

    // A B-spline spine sampled over [low, high] of its domain only (a variable blend's: where its
    // radius law is defined). Before init().
    void limit(double low, double high) {
        limited_ = true;
        limitLow_ = low;
        limitHigh_ = high;
    }
    // The curve's own parameter at position `s` — the one at(s) evaluates the curve at. False for a
    // spine without a curve (an intersection's).
    bool parameterAt(double s, double& t) const {
        if (curve_.IsNull() || params_.size() < 2) return false;
        s = wrap(s);
        const std::size_t count = points_.size();
        const std::size_t segments = closed_ ? count : count - 1;
        std::size_t j = std::size_t(std::upper_bound(positions_.begin(), positions_.begin() + segments + 1, s) -
                                    positions_.begin());
        j = j == 0 ? 0 : j - 1;
        j = std::min(j, segments - 1);
        const double fraction = (s - positions_[j]) / (positions_[j + 1] - positions_[j]);
        t = params_[j] + fraction * (params_[j + 1] - params_[j]);
        return true;
    }
    bool terminatorAtStart() const { return terminatorStart_; }
    bool terminatorAtEnd() const { return terminatorEnd_; }
    // A spine with ends of its own (an intersection's chart limits, a B-spline's domain), which the
    // blend does not run past; a line has none.
    bool bounded() const { return !closed_ && (curve_.IsNull() || Handle(Geom_Line)::DownCast(curve_).IsNull()); }

private:
    void sampleCurve(double first, double last, int count) {
        params_.clear();
        points_.clear();
        const int n = closed_ ? count : count + 1;
        for (int i = 0; i < n; ++i) {
            const double t = first + (last - first) * double(i) / double(count);
            params_.push_back(t);
            points_.push_back(curve_->Value(t));
        }
        if (closed_) params_.push_back(last);
        finishPositions();
    }

    void finishPositions() {
        positions_.assign(1, 0.0);
        for (std::size_t j = 1; j < points_.size(); ++j)
            positions_.push_back(positions_.back() + points_[j - 1].Distance(points_[j]));
        if (closed_) positions_.push_back(positions_.back() + points_.back().Distance(points_.front()));
    }

    bool initIntersection(const RollingBallBlend& d, std::string& error) {
        auto chart = d.spineChart;
        if (chart.size() < 2) { error = "intersection spine has no chart"; return false; }
        if (d.spineChartApproximate) {
            for (int i=0;i<2;++i)
                if (!surfaces_[i].init(d.spine.intersectionSurfaces[i],0)) {
                    error="an offset support of the approximate spine is invalid";return false;
                }
            const auto original=chart;
            for (std::size_t j=0;j<chart.size();++j) {
                const auto& before=original[j==0?(d.spineClosed?chart.size()-1:0):j-1];
                const auto& after=original[j+1==chart.size()?(d.spineClosed?0:chart.size()-1):j+1];
                gp_Vec along;
                if (!normalized(gp_Vec(toPnt(before),toPnt(after)),along)) {
                    error="an approximate spine chart repeats a point";return false;
                }
                const gp_Pnt guess=toPnt(original[j]);
                gp_Pnt p=guess;
                if (!refine(p,along,guess)) {
                    error="an approximate spine point does not converge to both supports: "+refineError_;return false;
                }
                chart[j]={p.X(),p.Y(),p.Z()};
            }
        }
        // Which chart points lie on a surface (within 1e-6 m). The grid layout of a B-spline spine
        // surface is the one most of them lie on; and a chart can run past a B-spline's domain, where
        // Parasolid continues the surface in its own way, so the spine is kept over the longest run
        // of points on both surfaces.
        std::vector<char> valid(chart.size(), 1);
        for (int i = 0; i < 2; ++i) {
            const auto kind = d.spine.intersectionSurfaces[i].kind;
            const bool numeric = kind == AnalyticSurfaceSupport::Kind::BSpline || kind == AnalyticSurfaceSupport::Kind::BSplineOffset;
            int bestCount = -1, bestOrdering = 0;
            std::vector<char> bestValid;
            for (int ordering = 0; ordering < (numeric ? 2 : 1); ++ordering) {
                if (!surfaces_[i].init(d.spine.intersectionSurfaces[i], ordering)) continue;
                std::vector<char> on(chart.size(), 0);
                int count = 0;
                for (std::size_t j = 0; j < chart.size(); ++j) {
                    gp_Pnt f;
                    gp_Vec n;
                    double distance;
                    on[j] = surfaces_[i].foot(toPnt(chart[j]), f, n, distance) && std::fabs(distance) < 1e-6;
                    count += on[j];
                }
                if (count > bestCount) {
                    bestCount = count;
                    bestOrdering = ordering;
                    bestValid = on;
                }
            }
            if (bestCount < 2 || !surfaces_[i].init(d.spine.intersectionSurfaces[i], bestOrdering)) {
                error = "the chart of the intersection spine is not on its surface " + std::to_string(i + 1);
                return false;
            }
            for (std::size_t j = 0; j < chart.size(); ++j) valid[j] = valid[j] && bestValid[j];
        }
        closed_ = d.spineClosed;
        std::vector<gp_Pnt> knots;
        if (std::find(valid.begin(), valid.end(), 0) == valid.end()) {
            for (const auto& p : chart) knots.push_back(toPnt(p));
        } else {
            const std::size_t n = chart.size();
            std::size_t bestStart = 0, bestLength = 0;
            for (std::size_t start = 0; start < n; ++start) {
                if (!valid[start] || (valid[(start + n - 1) % n] && (closed_ || start > 0))) continue;
                std::size_t length = 0;
                while (length < n && valid[(start + length) % n] && (closed_ || start + length < n)) ++length;
                if (length > bestLength) { bestLength = length; bestStart = start; }
            }
            if (bestLength < 2) { error = "fewer than two chart points of the intersection spine are on both surfaces"; return false; }
            for (std::size_t k = 0; k < bestLength; ++k) knots.push_back(toPnt(chart[(bestStart + k) % n]));
            closed_ = false;
        }
        if (closed_ && knots.size() > 2 && knots.front().Distance(knots.back()) < 1e-9) knots.pop_back();
        const std::size_t n = knots.size();
        // A terminator end kept as it is: exact, where the surfaces touch and Newton cannot step.
        terminatorStart_ = !closed_ && d.spineTerminators[0] && knots.front().Distance(toPnt(chart.front())) == 0.0;
        terminatorEnd_ = !closed_ && d.spineTerminators[1] && knots.back().Distance(toPnt(chart.back())) == 0.0;
        for (std::size_t j = 0; j < n; ++j) {
            if ((j == 0 && terminatorStart_) || (j + 1 == n && terminatorEnd_)) continue;
            const gp_Pnt& before = knots[j == 0 ? (closed_ ? n - 1 : 0) : j - 1];
            const gp_Pnt& after = knots[j + 1 == n ? (closed_ ? 0 : n - 1) : j + 1];
            gp_Vec along;
            if (!normalized(gp_Vec(before, after), along)) { error = "intersection spine chart repeats a point"; return false; }
            const gp_Pnt on = knots[j];
            if (!refine(knots[j], along, on)) { error = "intersection spine chart point does not converge"; return false; }
        }
        const std::size_t segments = closed_ ? n : n - 1;
        segments_ = segments;
        constexpr int kPieces = 16;
        // Exact points between the chart's; where one does not converge (the spine running over the
        // edge of a B-spline's domain) the spine is the longest converged run.
        std::vector<gp_Pnt> dense;
        std::vector<char> converged;
        std::string why;
        for (std::size_t j = 0; j < segments; ++j) {
            const gp_Pnt& a = knots[j];
            const gp_Pnt& b = knots[(j + 1) % n];
            gp_Vec along;
            if (!normalized(gp_Vec(a, b), along)) { error = "intersection spine chart repeats a point"; return false; }
            dense.push_back(a);
            converged.push_back(1);
            for (int k = 1; k < kPieces; ++k) {
                const gp_Pnt guess = a.Translated(gp_Vec(a, b) * (double(k) / kPieces));
                gp_Pnt p = guess;
                bool ok = refine(p, along, guess);
                // Next to a terminator (the chart's branch point is within about 1e-5 m of it) the
                // chord stands for the curve.
                if (!ok && terminatorSegment(j)) {
                    p = guess;
                    ok = true;
                }
                if (!ok && why.empty())
                    why = "between chart points " + std::to_string(j) + " and " + std::to_string(j + 1) + " of " +
                          std::to_string(n) + ": " + refineError_;
                dense.push_back(p);
                converged.push_back(ok);
            }
        }
        if (!closed_) {
            dense.push_back(knots.back());
            converged.push_back(1);
        }
        points_.clear();
        if (std::find(converged.begin(), converged.end(), 0) == converged.end()) {
            points_ = dense;
        } else {
            std::size_t bestStart = 0, bestLength = 0;
            for (std::size_t start = 0; start < dense.size(); ++start) {
                if (!converged[start] || (start > 0 && converged[start - 1])) continue;
                std::size_t length = 0;
                while (start + length < dense.size() && converged[start + length]) ++length;
                if (length > bestLength) { bestLength = length; bestStart = start; }
            }
            if (bestLength < 2) { error = "the intersection spine does not converge (" + why + ")"; return false; }
            points_.assign(dense.begin() + std::ptrdiff_t(bestStart), dense.begin() + std::ptrdiff_t(bestStart + bestLength));
            closed_ = false;
            trimmed_ = why;
            terminatorStart_ = terminatorEnd_ = false; // the dense points no longer start at chart steps
        }
        finishPositions();
        return true;
    }

    // Newton on the two surfaces and the plane through `on` square to `normal`.
    bool refine(gp_Pnt& p, const gp_Vec& normal, const gp_Pnt& on) const {
        for (int i = 0; i < 50; ++i) {
            gp_Pnt f1, f2;
            gp_Vec n1, n2;
            double d1, d2;
            if (!surfaces_[0].foot(p, f1, n1, d1) || !surfaces_[1].foot(p, f2, n2, d2)) {
                refineError_ = "no foot on surface " + std::string(surfaces_[0].foot(p, f1, n1, d1) ? "2" : "1");
                return false;
            }
            const double d3 = gp_Vec(on, p).Dot(normal);
            const double det = n1.Dot(n2.Crossed(normal));
            if (!(std::fabs(det) > 1e-12)) { refineError_ = "surfaces tangent"; return false; }
            const gp_Vec step = -(n2.Crossed(normal) * d1 + normal.Crossed(n1) * d2 + n1.Crossed(n2) * d3) / det;
            p.Translate(step);
            if (step.Magnitude() < 1e-15) break;
        }
        gp_Pnt f;
        gp_Vec n;
        double d1 = 1, d2 = 1;
        const bool ok = surfaces_[0].foot(p, f, n, d1) && surfaces_[1].foot(p, f, n, d2) && std::fabs(d1) < 1e-10 &&
                        std::fabs(d2) < 1e-10;
        if (!ok) refineError_ = "residuals " + std::to_string(d1) + ", " + std::to_string(d2);
        return ok;
    }
    mutable std::string refineError_;
    bool terminatorStart_ = false, terminatorEnd_ = false;
    std::size_t segments_ = 0; // chart steps of an intersection spine
    bool terminatorSegment(std::size_t chartStep) const {
        return (terminatorStart_ && chartStep == 0) || (terminatorEnd_ && chartStep + 1 == segments_);
    }

public:
    // Why the spine was cut short of its chart, if it was.
    const std::string& trimmed() const { return trimmed_; }

private:
    std::string trimmed_;

    bool intersectionTangent(const gp_Pnt& p, gp_Vec& tangent) const {
        gp_Pnt f;
        gp_Vec n1, n2;
        double d;
        if (!surfaces_[0].foot(p, f, n1, d) || !surfaces_[1].foot(p, f, n2, d)) return false;
        return normalized(n1.Crossed(n2), tangent);
    }

    Handle(Geom_Curve) curve_;
    Surface surfaces_[2];
    bool closed_ = false;
    bool limited_ = false;
    double limitLow_ = 0, limitHigh_ = 0;
    std::vector<gp_Pnt> points_;
    std::vector<double> params_;
    std::vector<double> positions_;
};

struct Section {
    double s = 0;
    gp_Pnt c;
    gp_Vec t, x, y;
    double angle = 0;
    double r = 0; // the ball's radius
    gp_Pnt contact[2];
};

// The point of a surface nearest to p, by Newton from (u, v): the parameters and the distance.
bool nearestOnSurface(const Handle(Geom_Surface)& surface, const gp_Pnt& p, double& u, double& v, double& distance) {
    try {
        for (int i = 0; i < 30; ++i) {
            gp_Pnt at;
            gp_Vec su, sv, suu, svv, suv;
            surface->D2(u, v, at, su, sv, suu, svv, suv);
            const gp_Vec e(p, at);
            const double f1 = e.Dot(su), f2 = e.Dot(sv);
            const double a = su.Dot(su) + e.Dot(suu), b = su.Dot(sv) + e.Dot(suv), c = sv.Dot(sv) + e.Dot(svv);
            const double det = a * c - b * b;
            if (!(std::fabs(det) > 1e-300)) return false;
            const double du = -(c * f1 - b * f2) / det, dv = -(a * f2 - b * f1) / det;
            u += du;
            v += dv;
            if ((su * du + sv * dv).Magnitude() < 1e-15) break;
        }
        distance = surface->Value(u, v).Distance(p);
        return std::isfinite(distance);
    } catch (const Standard_Failure&) {
        return false;
    }
}

} // namespace

struct Blend::Impl {
    RollingBallBlend definition;
    Surface supports[2];
    Spine spine;
    double radius = 0;
    // A variable radius (RollingBallBlend::radiusLaw): the law as a curve whose x is the radius, and
    // the side of each support the centre keeps to (+1 along its natural normal, -1 against).
    bool variable = false;
    Handle(Geom_BSplineCurve) law;
    double side[2] = {1.0, 1.0};
    double from = 0, to = 0; // the surface's extent along the spine
    bool ring = false;       // all the way round a closed spine
    // A terminator at that end: the arc's angle grows as the square root of the distance from it,
    // so sections are spaced quadratically towards it and the surface parametrised evenly in
    // their index, in which the angle is then smooth.
    bool gradeStart = false, gradeEnd = false;
    bool fixedStart = false, fixedEnd = false; // held at a bounded spine's end
    double position(double t) const {
        double g = t;
        if (gradeStart && gradeEnd) g = t * t * (3.0 - 2.0 * t);
        else if (gradeStart) g = t * t;
        else if (gradeEnd) g = 1.0 - (1.0 - t) * (1.0 - t);
        return from + (to - from) * g;
    }
    std::vector<Section> sections;
    std::vector<double> parameters; // along the surface: cumulative chords of the section centres
    int arcs = 1;
    Handle(Geom_BSplineSurface) surface;
    double deviation = 0, contactGap = 0;
    int faceSense = 0;
    std::string error;
    mutable std::string edgeError;
    mutable std::string measureError;
    std::string history; // section counts tried and the deviation each gave
    mutable std::string worstAt;
    mutable double lastContactFit = 0;

    mutable std::string sectionError;

    // A variable blend's ball at spine position s: its centre in the plane square to the spine at the
    // spine's point, at the law's radius from both supports (Newton in that plane from the spine's
    // point), and how far it stays off either (`residual`).
    bool centre(double s, gp_Pnt& c, gp_Vec& t, double& r, double& residual) const {
        gp_Pnt guide;
        double parameter;
        if (!spine.at(s, guide, t) || !spine.parameterAt(s, parameter)) { sectionError = "no spine point"; return false; }
        try {
            r = law->Value(parameter).X();
        } catch (const Standard_Failure&) {
            sectionError = "no radius";
            return false;
        }
        if (!positiveFinite(r)) { sectionError = "radius " + std::to_string(r); return false; }
        gp_Vec e1, e2;
        if (!normalized(t.Crossed(std::fabs(t.X()) < 0.9 ? gp_Vec(1, 0, 0) : gp_Vec(0, 1, 0)), e1)) return false;
        e2 = t.Crossed(e1);
        double a = 0, b = 0;
        residual = std::numeric_limits<double>::infinity();
        for (int i = 0; i < 60; ++i) {
            c = guide.Translated(e1 * a + e2 * b);
            double f[2];
            gp_Vec n[2];
            for (int k = 0; k < 2; ++k) {
                gp_Pnt foot;
                double distance;
                if (!supports[k].foot(c, foot, n[k], distance)) {
                    sectionError = "no foot on support " + std::to_string(k + 1);
                    return false;
                }
                f[k] = side[k] * distance - r;
                n[k] *= side[k];
            }
            residual = std::max(std::fabs(f[0]), std::fabs(f[1]));
            const double j11 = n[0].Dot(e1), j12 = n[0].Dot(e2), j21 = n[1].Dot(e1), j22 = n[1].Dot(e2);
            const double det = j11 * j22 - j12 * j21;
            if (!(std::fabs(det) > 1e-12)) { sectionError = "supports parallel in the section plane"; return false; }
            const double da = -(j22 * f[0] - j12 * f[1]) / det, db = -(j11 * f[1] - j21 * f[0]) / det;
            a += da;
            b += db;
            if (std::hypot(da, db) < 1e-15 * (1.0 + r)) {
                c = guide.Translated(e1 * a + e2 * b);
                break;
            }
        }
        if (!(residual < 1e-9 * (1.0 + r))) { sectionError = "the ball's centre does not converge (" + std::to_string(residual) + ")"; return false; }
        return true;
    }

    bool section(double s, Section& out, double& gap) const {
        out.s = s;
        if (variable) {
            double residual;
            if (!centre(s, out.c, out.t, out.r, residual)) return false;
            gap = std::max(gap, residual);
            gp_Vec toContact[2];
            for (int i = 0; i < 2; ++i) {
                gp_Vec n;
                double distance;
                if (!supports[i].foot(out.c, out.contact[i], n, distance) || !normalized(gp_Vec(out.c, out.contact[i]), toContact[i])) {
                    sectionError = "no contact with support " + std::to_string(i + 1);
                    return false;
                }
            }
            // The ball's great circle through both contacts.
            out.x = toContact[0];
            out.angle = std::atan2(out.x.Crossed(toContact[1]).Magnitude(), out.x.Dot(toContact[1]));
            if (!(out.angle > 1e-4 && out.angle < kPi - 1e-3)) {
                sectionError = "arc of " + std::to_string(out.angle) + " rad between the contacts";
                return false;
            }
            return normalized(toContact[1] - out.x * toContact[1].Dot(out.x), out.y);
        }
        out.r = radius;
        if (!spine.at(s, out.c, out.t)) { sectionError = "no spine point"; return false; }
        gp_Vec toContact[2];
        for (int i = 0; i < 2; ++i) {
            gp_Vec n;
            double distance;
            if (!supports[i].foot(out.c, out.contact[i], n, distance)) {
                sectionError = "no foot on support " + std::to_string(i + 1);
                return false;
            }
            // The spine lies at the signed offset from each support: its size is the radius, its
            // sign the side (XT range × the support's sense).
            gap = std::max(gap, std::fabs(distance - definition.offsets[i]));
            const gp_Vec radial(out.c, out.contact[i]);
            if (!normalized(radial - out.t * radial.Dot(out.t), toContact[i])) {
                sectionError = "contact " + std::to_string(i + 1) + " on the spine";
                return false;
            }
        }
        out.x = toContact[0];
        out.angle = std::atan2(out.x.Crossed(toContact[1]).Magnitude(), out.x.Dot(toContact[1]));
        if (!(out.angle < kPi - 1e-3)) {
            sectionError = "arc of " + std::to_string(out.angle) + " rad between the contacts";
            return false;
        }
        if (out.angle > 1e-4) return normalized(toContact[1] - out.x * toContact[1].Dot(out.x), out.y);
        // A terminator: the ball touches both supports at one point and the arc shrinks to nothing.
        // Its second axis square to the spine, turned the way it turns a little inside the blend.
        if (!normalized(out.t.Crossed(out.x), out.y)) return false;
        const double inward = (to - from) * 1e-2 * (s - from < to - s ? 1.0 : -1.0);
        gp_Pnt c;
        gp_Vec t;
        if (spine.at(s + inward, c, t)) {
            gp_Vec directions[2];
            bool ok = true;
            for (int i = 0; i < 2 && ok; ++i) {
                gp_Pnt f;
                gp_Vec n;
                double distance;
                ok = supports[i].foot(c, f, n, distance);
                const gp_Vec radial(c, f);
                ok = ok && normalized(radial - t * radial.Dot(t), directions[i]);
            }
            gp_Vec y;
            if (ok && normalized(directions[1] - directions[0] * directions[1].Dot(directions[0]), y) && y.Dot(out.y) < 0)
                out.y.Reverse();
        }
        return true;
    }

    gp_Pnt onArc(const Section& q, double angle, double scale = 1.0) const {
        return q.c.Translated((q.x * std::cos(angle) + q.y * std::sin(angle)) * (q.r * scale));
    }

    // A variable blend's spine position whose cross-section's arc lies in a plane through q: by the
    // secant method from `guess`; the section there in `found`.
    bool sectionOf(const gp_Pnt& q, double guess, double& s, Section& found) const {
        const auto g = [&](double at, double& value, Section& q2) {
            double gap = 0;
            if (!section(at, q2, gap)) return false;
            value = gp_Vec(q2.c, q).Dot(q2.x.Crossed(q2.y));
            return std::isfinite(value);
        };
        double s0 = guess, g0;
        Section here;
        if (!g(s0, g0, here)) return false;
        // Moving along the spine carries the plane past q at about unit rate, the plane's normal
        // about along (or against) the spine.
        const double rate = -here.x.Crossed(here.y).Dot(here.t);
        double s1 = s0 - g0 / (std::fabs(rate) > 0.1 ? rate : (rate < 0 ? -0.1 : 0.1)), g1 = g0;
        for (int i = 0; i < 60; ++i) {
            if (!g(s1, g1, here)) return false;
            if (std::fabs(g1) < 1e-14 || std::fabs(s1 - s0) < 1e-15) break;
            const double slope = (g1 - g0) / (s1 - s0);
            const double next = s1 - g1 / (std::fabs(slope) > 1e-3 ? slope : rate);
            s0 = s1;
            g0 = g1;
            s1 = next;
        }
        if (!(std::fabs(g1) < 1e-11)) return false;
        s = s1;
        found = here;
        return true;
    }

    // The spine position of a point of the blend — for a constant radius the nearest spine point; for
    // a variable one, the cross-section through it (from the nearest point of the guide).
    bool positionOf(const gp_Pnt& q, double& s) const {
        if (!spine.foot(q, s)) return false;
        if (!variable) return true;
        Section found;
        return sectionOf(q, s, s, found);
    }

    bool build(int count, std::string& why) {
        sections.assign(count + 1, {});
        double gap = 0;
        for (int k = 0; k <= count; ++k) {
            if (ring && k == count) {
                sections[k] = sections[0];
                sections[k].s = to;
                continue;
            }
            const double s = position(double(k) / double(count));
            if (!section(s, sections[k], gap)) {
                why = "no cross-section at spine position " + std::to_string(s) + " m of " +
                      std::to_string(from) + ".." + std::to_string(to) + " (" + sectionError + ")";
                return false;
            }
        }
        contactGap = gap;
        parameters.assign(1, 0.0);
        double widest = 0;
        for (int k = 1; k <= count; ++k) {
            const double chord = sections[k - 1].c.Distance(sections[k].c);
            if (!(chord > 1e-12)) { why = "cross-sections coincide"; return false; }
            // Graded sections: even in their index (see gradeStart); otherwise the centres' chords.
            parameters.push_back(gradeStart || gradeEnd ? (to - from) * double(k) / double(count)
                                                        : parameters.back() + chord);
        }
        for (const auto& q : sections) widest = std::max(widest, q.angle + 2 * kArcOvershoot);
        arcs = widest > 2.0 ? 2 : 1; // a quadratic arc's middle weight is cos(half its angle)
        const int across = 2 * arcs + 1;
        const int dimension = 4 * across;
        std::vector<double> data(std::size_t(count + 1) * dimension);
        for (int k = 0; k <= count; ++k) {
            const Section& q = sections[k];
            const double span = q.angle + 2 * kArcOvershoot;
            for (int a = 0; a < arcs; ++a) {
                const double start = -kArcOvershoot + span * a / arcs;
                const double half = span / (2 * arcs);
                const gp_Pnt ends[2] = {onArc(q, start), onArc(q, start + 2 * half)};
                const gp_Pnt middle = onArc(q, start + half, 1.0 / std::cos(half));
                const std::pair<gp_Pnt, double> poles[3] = {{ends[0], 1.0}, {middle, std::cos(half)}, {ends[1], 1.0}};
                for (int j = 0; j < 3; ++j) {
                    if (a > 0 && j == 0) continue;
                    const int column = 2 * a + j;
                    double* h = &data[std::size_t(k) * dimension + 4 * column];
                    const double w = poles[j].second;
                    h[0] = poles[j].first.X() * w;
                    h[1] = poles[j].first.Y() * w;
                    h[2] = poles[j].first.Z() * w;
                    h[3] = w;
                }
            }
        }
        TColStd_Array1OfReal vKnots(1, arcs + 1);
        TColStd_Array1OfInteger vMults(1, arcs + 1);
        for (int a = 0; a <= arcs; ++a) {
            vKnots.SetValue(a + 1, double(a) / arcs);
            vMults.SetValue(a + 1, a == 0 || a == arcs ? 3 : 2);
        }
        if (ring) {
            // Round a closed spine: periodic cubic interpolation, C2 across the seam too, so that a
            // face on it is a ring OCCT trims as it does a cylinder's. Each homogeneous column as a 3D
            // curve (w·P) with its weight alongside as the x of (w, u, 0) — the u only keeps those
            // points apart; the knots depend on the parameters alone, so the columns share them.
            try {
                Handle(TColStd_HArray1OfReal) at = new TColStd_HArray1OfReal(1, count + 1);
                for (int k = 0; k <= count; ++k) at->SetValue(k + 1, parameters[k]);
                std::vector<Handle(Geom_BSplineCurve)> homogeneous(across), weight(across);
                for (int j = 0; j < across; ++j) {
                    Handle(TColgp_HArray1OfPnt) hp = new TColgp_HArray1OfPnt(1, count);
                    Handle(TColgp_HArray1OfPnt) wp = new TColgp_HArray1OfPnt(1, count);
                    for (int k = 0; k < count; ++k) {
                        const double* h = &data[std::size_t(k) * dimension + 4 * j];
                        hp->SetValue(k + 1, gp_Pnt(h[0], h[1], h[2]));
                        wp->SetValue(k + 1, gp_Pnt(h[3], parameters[k], 0.0));
                    }
                    GeomAPI_Interpolate first(hp, at, true, 1e-15), second(wp, at, true, 1e-15);
                    first.Perform();
                    second.Perform();
                    if (!first.IsDone() || !second.IsDone()) { why = "periodic interpolation along the spine failed"; return false; }
                    homogeneous[j] = first.Curve();
                    weight[j] = second.Curve();
                    if (homogeneous[j]->NbPoles() != homogeneous[0]->NbPoles() ||
                        weight[j]->NbPoles() != homogeneous[0]->NbPoles() ||
                        homogeneous[j]->NbKnots() != homogeneous[0]->NbKnots()) {
                        why = "periodic interpolation along the spine gave different knots";
                        return false;
                    }
                }
                const int n = homogeneous[0]->NbPoles();
                TColgp_Array2OfPnt poles(1, n, 1, across);
                TColStd_Array2OfReal weights(1, n, 1, across);
                for (int i = 1; i <= n; ++i) {
                    for (int j = 0; j < across; ++j) {
                        const double w = weight[j]->Pole(i).X();
                        if (!(w > 0.0)) { why = "a weight of the interpolated arcs is not positive"; return false; }
                        const gp_Pnt h = homogeneous[j]->Pole(i);
                        poles.SetValue(i, j + 1, gp_Pnt(h.X() / w, h.Y() / w, h.Z() / w));
                        weights.SetValue(i, j + 1, w);
                    }
                }
                surface = new Geom_BSplineSurface(poles, weights, homogeneous[0]->Knots(), vKnots,
                                                  homogeneous[0]->Multiplicities(), vMults, 3, 2, true, false);
            } catch (const Standard_Failure& failure) {
                why = std::string("ring blend surface: ") + failure.GetMessageString();
                return false;
            }
            return true;
        }
        // Cubic interpolation of the homogeneous poles along the spine at the section centres' chords,
        // knots by averaging (de Boor): the interpolated arcs pass through every section exactly.
        const int points = count + 1;
        TColStd_Array1OfReal flat(1, points + 4), at(1, points);
        TColStd_Array1OfInteger contact(1, points);
        for (int k = 0; k < points; ++k) {
            at.SetValue(k + 1, parameters[k]);
            contact.SetValue(k + 1, 0);
        }
        for (int i = 1; i <= 4; ++i) {
            flat.SetValue(i, parameters.front());
            flat.SetValue(points + i, parameters.back());
        }
        for (int i = 1; i <= points - 4; ++i)
            flat.SetValue(4 + i, (parameters[i] + parameters[i + 1] + parameters[i + 2]) / 3.0);
        int problem = 0;
        BSplCLib::Interpolate(3, flat, at, contact, dimension, data[0], problem);
        if (problem != 0) { why = "interpolation along the spine failed"; return false; }
        TColgp_Array2OfPnt poles(1, points, 1, across);
        TColStd_Array2OfReal weights(1, points, 1, across);
        for (int k = 0; k < points; ++k) {
            const int source = ring && k == count ? 0 : k; // a ring closes exactly on its first row
            for (int j = 0; j < across; ++j) {
                const double* h = &data[std::size_t(source) * dimension + 4 * j];
                if (!(h[3] > 0.0)) { why = "a weight of the interpolated arcs is not positive"; return false; }
                poles.SetValue(k + 1, j + 1, gp_Pnt(h[0] / h[3], h[1] / h[3], h[2] / h[3]));
                weights.SetValue(k + 1, j + 1, h[3]);
            }
        }
        const int knotCount = BSplCLib::KnotsLength(flat);
        TColStd_Array1OfReal uKnots(1, knotCount);
        TColStd_Array1OfInteger uMults(1, knotCount);
        BSplCLib::Knots(flat, uKnots, uMults);
        try {
            surface = new Geom_BSplineSurface(poles, weights, uKnots, vKnots, uMults, vMults, 3, 2);
        } catch (const Standard_Failure& failure) {
            why = std::string("blend surface: ") + failure.GetMessageString();
            return false;
        }
        return true;
    }

    // Largest distance of the surface from the canal of balls round the spine, between the sections
    // (at them the arcs are exact): | |Q − C(Q)| − r | with C(Q) the spine point nearest to Q.
    // `thorough`: three points along each interval and 17 across; otherwise the middle and 9 across,
    // where interpolation between exact sections errs most — enough to choose the section count.
    double measure(bool thorough) const {
        if (variable) return measureVariable(thorough);
        double worst = 0;
        const int count = int(sections.size()) - 1;
        const int across = thorough ? 16 : 8;
        for (int k = 0; k < count; ++k) {
            for (int i = thorough ? 1 : 2; i <= (thorough ? 3 : 2); ++i) {
                const double f = i / 4.0;
                const double u = parameters[k] + f * (parameters[k + 1] - parameters[k]);
                const double guess = sections[k].s + f * (sections[k + 1].s - sections[k].s);
                for (int j = 0; j <= across; ++j) {
                    const gp_Pnt q = surface->Value(u, double(j) / across);
                    double s;
                    gp_Pnt c;
                    gp_Vec t;
                    if (!spine.footNear(q, guess, s) || !spine.at(s, c, t)) {
                        measureError = "no spine point for the surface at section " + std::to_string(k) + " of " +
                                       std::to_string(count) + " (spine position " + std::to_string(guess) + " of " +
                                       std::to_string(spine.length()) + ")";
                        return std::numeric_limits<double>::infinity();
                    }
                    const double off = std::fabs(q.Distance(c) - radius);
                    if (off > worst) {
                        worst = off;
                        worstAt = "section " + std::to_string(k) + " of " + std::to_string(count) + " at " +
                                  std::to_string(f) + ", across " + std::to_string(double(j) / across);
                    }
                }
            }
        }
        return worst;
    }

    // A variable blend's: the distance from the surface of the exact arcs between the contacts of
    // cross-sections between those it was built through (a point's nearest point on the surface, by
    // Newton from where it lies in the surface's parameters about) — its parameter along is not the
    // spine position, so a point cannot be compared with the surface's at the same parameters.
    double measureVariable(bool thorough) const {
        double worst = 0;
        const int count = int(sections.size()) - 1;
        const int across = thorough ? 16 : 8;
        for (int k = 0; k < count; ++k) {
            for (int i = thorough ? 1 : 2; i <= (thorough ? 3 : 2); ++i) {
                const double f = i / 4.0;
                Section q;
                double gap = 0;
                if (!section(sections[k].s + f * (sections[k + 1].s - sections[k].s), q, gap)) {
                    measureError = "no cross-section between sections " + std::to_string(k) + " and " + std::to_string(k + 1) + " (" +
                                   sectionError + ")";
                    return std::numeric_limits<double>::infinity();
                }
                const double span = q.angle + 2 * kArcOvershoot;
                double u = parameters[k] + f * (parameters[k + 1] - parameters[k]);
                for (int j = 0; j <= across; ++j) {
                    const double angle = q.angle * j / across;
                    const gp_Pnt exact = onArc(q, angle);
                    double v = (kArcOvershoot + angle) / span, distance;
                    double uu = u;
                    if (!nearestOnSurface(surface, exact, uu, v, distance)) {
                        measureError = "no nearest point on the surface at section " + std::to_string(k);
                        return std::numeric_limits<double>::infinity();
                    }
                    if (distance > worst) {
                        worst = distance;
                        worstAt = "section " + std::to_string(k) + " of " + std::to_string(count) + " at " + std::to_string(f) +
                                  ", across " + std::to_string(double(j) / across);
                    }
                }
            }
        }
        return worst;
    }

    // The contact curve with support `b` over [low, high] along the spine; its ends replaced by the
    // given vertices when they are known.
    Handle(Geom_BSplineCurve) contactCurve(int b, double low, double high, const gp_Pnt* first, const gp_Pnt* last,
                                           bool closedCurve) const {
        const int base = std::max(8, int(std::ceil((high - low) / std::max(to - from, 1e-12) * 4 * (sections.size() - 1))));
        for (int count = base; count <= 32 * base; count *= 2) {
            const int points = closedCurve ? count : count + 1;
            Handle(TColgp_HArray1OfPnt) values = new TColgp_HArray1OfPnt(1, points);
            Handle(TColStd_HArray1OfReal) at = new TColStd_HArray1OfReal(1, closedCurve ? points + 1 : points);
            bool ok = true;
            const auto contactAt = [&](double s, gp_Pnt& p) {
                if (variable) {
                    Section q;
                    double gap = 0;
                    if (!section(s, q, gap)) return false;
                    p = q.contact[b];
                    return true;
                }
                gp_Pnt c, f;
                gp_Vec t, n;
                double distance;
                return spine.at(s, c, t) && supports[b].foot(c, p, n, distance);
            };
            for (int m = 0; m < points && ok; ++m) {
                const double s = low + (high - low) * double(m) / double(count);
                gp_Pnt p;
                ok = contactAt(s, p);
                if (m == 0 && first) p = *first;
                if (m == count && last) p = *last;
                values->SetValue(m + 1, p);
                at->SetValue(m + 1, s);
            }
            if (!ok) return {};
            if (closedCurve) at->SetValue(points + 1, high);
            try {
                GeomAPI_Interpolate interpolation(values, at, closedCurve, 1e-12);
                interpolation.Perform();
                if (!interpolation.IsDone()) return {};
                const Handle(Geom_BSplineCurve) curve = interpolation.Curve();
                double worst = 0;
                for (int m = 0; m < count; ++m) {
                    const double s = low + (high - low) * (m + 0.5) / double(count);
                    gp_Pnt exact;
                    if (!contactAt(s, exact)) return {};
                    worst = std::max(worst, curve->Value(s).Distance(exact));
                }
                lastContactFit = worst;
                if (worst <= kTarget) return curve;
            } catch (const Standard_Failure&) {
                return {};
            }
        }
        return {};
    }
};

Blend::Blend(const RollingBallBlend& definition) : impl_(std::make_unique<Impl>()) {
    Impl& d = *impl_;
    d.definition = definition;
    d.radius = definition.radius;
    auto& error = d.error;
    if (!positiveFinite(d.radius)) { error = "blend radius is not positive"; return; }
    d.variable = !definition.radiusLaw.poles.empty();
    if (d.variable) {
        // The law as a curve in the plane z = 0, its x the radius; the spine used over its domain only.
        const auto& b = definition.radiusLaw;
        const int count = int(b.poles.size()), knots = int(b.knots.size());
        if (definition.spine.kind != AnalyticEdgeKind::BSpline) { error = "a variable radius needs a B-spline spine"; return; }
        if (count < 2 || knots < 2 || knots != int(b.multiplicities.size()) || b.degree < 1 || b.degree >= count ||
            (!b.weights.empty() && int(b.weights.size()) != count)) {
            error = "the radius law is invalid";
            return;
        }
        try {
            TColgp_Array1OfPnt poles(1, count);
            TColStd_Array1OfReal weights(1, count);
            TColStd_Array1OfReal knotValues(1, knots);
            TColStd_Array1OfInteger multiplicities(1, knots);
            for (int i = 0; i < count; ++i) {
                poles.SetValue(i + 1, gp_Pnt(b.poles[i].x, b.poles[i].y, 0.0));
                weights.SetValue(i + 1, b.weights.empty()?1.0:b.weights[i]);
            }
            for (int i = 0; i < knots; ++i) {
                knotValues.SetValue(i + 1, b.knots[i]);
                multiplicities.SetValue(i + 1, b.multiplicities[i]);
            }
            d.law = new Geom_BSplineCurve(poles, weights, knotValues, multiplicities, b.degree, b.periodic);
        } catch (const Standard_Failure& failure) {
            error = std::string("radius law: ") + failure.GetMessageString();
            return;
        }
        d.spine.limit(d.law->FirstParameter(), d.law->LastParameter());
    }
    if (!d.spine.init(definition, error)) return;
    const auto& samples = d.spine.samples();
    if (d.variable) {
        // The source's guide may extend past the surviving blend faces and cross a support there.
        // Determine the branch beside the faces' vertices, where this blend actually exists.
        std::vector<double> visible;
        for (const auto& edge:definition.faceEdges) for (const auto& p:edge) {
            double position;
            if (d.spine.foot(toPnt(p),position)) visible.push_back(position);
        }
        // The supports as they are; the side of each the one the spine keeps to where the offsets do
        // not say (the spine runs near the centres, well inside the radius).
        for (int i = 0; i < 2; ++i) {
            if (!d.supports[i].init(definition.supports[i], 0)) {
                error = "support " + std::to_string(i + 1) + " of the variable blend is not supported";
                return;
            }
            if (definition.offsets[i] != 0.0) {
                d.side[i] = definition.offsets[i] > 0.0 ? 1.0 : -1.0;
                continue;
            }
            int above = 0, below = 0;
            for (int k = 0; k <= 8; ++k) {
                gp_Pnt c=samples[std::size_t(double(samples.size() - 1) * k / 8.0)];
                if (!visible.empty()) {
                    const auto [low,high]=std::minmax_element(visible.begin(),visible.end());
                    gp_Vec tangent;
                    if (!d.spine.at(*low+(*high-*low)*k/8.0,c,tangent)) continue;
                }
                gp_Pnt f;
                gp_Vec n;
                double distance;
                if (!d.supports[i].foot(c, f, n, distance)) continue;
                (distance > 0 ? above : below) += 1;
            }
            if (above + below == 0 || (above > 0 && below > 0)) {
                error = "the spine of the variable blend crosses support " + std::to_string(i + 1);
                return;
            }
            d.side[i] = above > 0 ? 1.0 : -1.0;
            d.supports[i].restart();
        }
    }
    // Supports: a B-spline grid's layout is the one the spine lies at the radius from.
    for (int i = 0; i < 2 && !d.variable; ++i) {
        bool ready = false;
        const auto kind = definition.supports[i].kind;
        const bool numeric = kind == AnalyticSurfaceSupport::Kind::BSpline || kind == AnalyticSurfaceSupport::Kind::BSplineOffset;
        for (int ordering = 0; ordering < (numeric ? 2 : 1) && !ready; ++ordering) {
            if (!d.supports[i].init(definition.supports[i], ordering)) continue;
            ready = true;
            for (int k = 0; k <= 8 && ready; ++k) {
                const gp_Pnt& c = samples[std::size_t(double(samples.size() - 1) * k / 8.0)];
                gp_Pnt f;
                gp_Vec n;
                double distance;
                ready = d.supports[i].foot(c, f, n, distance) && std::fabs(std::fabs(distance) - d.radius) < kLimit;
            }
        }
        if (!ready) {
            error = "the spine is not at the blend radius from support " + std::to_string(i + 1);
            return;
        }
    }
    // Extent along the spine: where the faces' edges are, and a margin of one radius beyond (a cut
    // across the blend can reach past its vertices by about that much).
    const double length = d.spine.length();
    double margin = d.radius;
    if (definition.faceEdges.empty()) {
        if (!d.spine.closed()) { error = "a blend without vertices needs a closed spine"; return; }
        d.ring = true;
        d.from = 0;
        d.to = length;
    } else if (!d.spine.closed()) {
        double low = std::numeric_limits<double>::infinity(), high = -low;
        for (const auto& edge : definition.faceEdges)
            for (const auto& p : edge) {
                double s;
                if (!d.positionOf(toPnt(p), s)) {
                    double nearest = std::numeric_limits<double>::infinity();
                    for (const auto& q : d.spine.samples()) nearest = std::min(nearest, q.Distance(toPnt(p)));
                    error = "a vertex of the blend at (" + std::to_string(p.x) + ", " + std::to_string(p.y) + ", " +
                            std::to_string(p.z) + ") has no point on its spine (" + std::to_string(nearest) +
                            " m from its nearest sample, spine " + std::to_string(d.spine.length()) + " m long)" +
                            (d.spine.trimmed().empty() ? std::string() : " (spine cut short " + d.spine.trimmed() + ")");
                    return;
                }
                low = std::min(low, s);
                high = std::max(high, s);
            }
        d.from = low - margin;
        d.to = high + margin;
        // Nothing beyond the ends of a bounded spine; at a terminator the sections are graded
        // towards it besides.
        if (d.spine.bounded()) {
            if (d.from < 0.0) {
                d.from = 0.0;
                d.fixedStart = true;
                d.gradeStart = d.spine.terminatorAtStart();
            }
            if (d.to > length) {
                d.to = length;
                d.fixedEnd = true;
                d.gradeEnd = d.spine.terminatorAtEnd();
            }
        }
    } else {
        // On a closed spine the face covers, for each edge, the way from its start to its end that
        // passes its middle (or the shorter way); the surface spans all but the largest gap left.
        constexpr int kBins = 4096;
        std::vector<char> covered(kBins, 0);
        const auto bin = [&](double s) { return std::min(kBins - 1, int(d.spine.wrap(s) / length * kBins)); };
        const auto mark = [&](double start, double span) {
            const int steps = int(std::ceil(span / length * kBins)) + 1;
            for (int i = 0; i <= steps; ++i) covered[bin(start + span * i / steps)] = 1;
        };
        for (const auto& edge : definition.faceEdges) {
            // Along the edge from start through its middle to its end, each step the shorter way
            // round (an arc of one cross-section has the same position at all three points).
            double at = 0, low = 0, high = 0, previous = 0;
            for (std::size_t i = 0; i < edge.size(); ++i) {
                double s;
                if (!d.spine.foot(toPnt(edge[i]), s)) { error = "a vertex of the blend has no point on its spine"; return; }
                at = i == 0 ? s : at + std::remainder(s - previous, length);
                previous = s;
                low = i == 0 ? at : std::min(low, at);
                high = i == 0 ? at : std::max(high, at);
            }
            mark(low, high - low);
        }
        int bestStart = -1, bestLength = 0;
        for (int i = 0; i < kBins; ++i) {
            if (covered[i] || covered[(i + kBins - 1) % kBins] == 0) continue; // a gap starts at i
            int n = 0;
            while (n < kBins && !covered[(i + n) % kBins]) ++n;
            if (n > bestLength) { bestLength = n; bestStart = i; }
        }
        if (bestStart < 0) {
            d.ring = true;
            d.from = 0;
            d.to = length;
        } else {
            const double gap = bestLength * length / kBins;
            margin = std::min(margin, gap / 4) + 2 * length / kBins;
            d.from = (bestStart + bestLength) * length / kBins - margin;
            d.to = d.from + (length - gap) + 2 * margin;
        }
    }
    // Sections doubled until the surface is within the aim; a margin the spine cannot be continued
    // over is given up (a spine ending at a singular point).
    std::string why;
    double best = std::numeric_limits<double>::infinity(), previous = 0;
    int count = kFirstSections, previousCount = 0;
    for (;;) {
        bool built = d.build(count, why);
        for (int shrink = 0; !built && !d.ring && shrink < 2; ++shrink) {
            const double cut = (shrink == 0 ? 0.75 : 1.0) * margin;
            if (!d.fixedStart) d.from += cut; // an end held at the spine's own end has no margin
            if (!d.fixedEnd) d.to -= cut;
            margin -= cut;
            built = d.build(count, why);
        }
        if (!built) { error = why; d.surface.Nullify(); return; }
        d.measureError.clear();
        best = d.measure(false);
        {
            char step[48];
            std::snprintf(step, sizeof step, "%s%d: %.2g", d.history.empty() ? "" : ", ", count, best);
            d.history += step;
        }
        if (best <= kTarget || count >= kMaxSections) break;
        // The error falls as a power of the spacing — the 4th for a smooth spine, less across the
        // knots of a B-spline support's offset; the order seen over the last two builds sets the next
        // count, with a quarter to spare.
        double order = 4.0;
        if (previousCount > 0 && previous > best && best > 0)
            order = std::clamp(std::log(previous / best) / std::log(double(count) / previousCount), 1.0, 4.0);
        const double factor = std::clamp(1.25 * std::pow(best / kTarget, 1.0 / order), 1.5, 8.0);
        previousCount = count;
        previous = best;
        count = std::min(kMaxSections, int(std::ceil(count * factor)));
    }
    best = d.measure(true);
    d.deviation = best;
    if (!(best <= kLimit)) {
        char figures[96];
        std::snprintf(figures, sizeof figures, "%.3g m with %d sections", best, int(d.sections.size()) - 1);
        error = std::string("blend surface departs from its definition by ") + figures + " at " + d.worstAt +
                " (sections: " + d.history + ")" + (d.measureError.empty() ? std::string() : " (" + d.measureError + ")");
        d.surface.Nullify();
        return;
    }
    if (!(d.contactGap <= kLimit)) {
        error = "the source's spine is off its supports by " + std::to_string(d.contactGap) + " m";
        d.surface.Nullify();
        return;
    }
    // Orientation: along a contact line the blend continues its support's face, so it turns the way
    // that face does.
    const Section& middle = d.sections[d.sections.size() / 2];
    const double u = d.parameters[d.sections.size() / 2];
    for (int b = 0; b < 2; ++b) {
        const int sense = definition.supportFaceSense[b];
        if (sense == 0) continue;
        gp_Pnt f, at;
        gp_Vec n, du, dv;
        double distance;
        if (!d.supports[b].foot(middle.c, f, n, distance)) continue;
        d.surface->D1(u, b == 0 ? 0.0 : 1.0, at, du, dv);
        const int turn = du.Crossed(dv).Dot(n * sense) > 0 ? 1 : -1;
        if (d.faceSense != 0 && d.faceSense != turn) {
            error = "the blend's two support faces disagree about its orientation";
            d.surface.Nullify();
            return;
        }
        d.faceSense = turn;
    }
}

Blend::~Blend() = default;

Handle(Geom_BSplineSurface) Blend::surface() const { return impl_->surface; }
const std::string& Blend::error() const { return impl_->error; }
double Blend::deviation() const { return impl_->deviation; }
double Blend::contactGap() const { return impl_->contactGap; }
double Blend::tolerance() const { return impl_->deviation + impl_->contactGap; }
int Blend::sections() const { return int(impl_->sections.size()) - 1; }
int Blend::faceSense() const { return impl_->faceSense; }

bool Blend::foot(const gp_Pnt& point, gp_Pnt& nearest, gp_Vec& normal, double& distance,
                 double& position, double& angle) const {
    const Impl& d=*impl_;
    if (d.surface.IsNull()) return false;
    double s=position, theta=angle;
    Section section;
    double gap=0;
    if (!std::isfinite(s) || !std::isfinite(theta)) {
        if (!d.positionOf(point,s) || !d.section(s,section,gap)) return false;
        const gp_Vec radial(section.c,point);
        theta=std::atan2(radial.Dot(section.y),radial.Dot(section.x));
    }
    const double length=d.spine.length();
    // Five-point derivatives of the definition. Its sections are solved on the original supports;
    // no derivatives of the fitted B-spline enter the offset or its intersections.
    const double h=std::max(1e-6,length*1e-4);
    const auto derivatives=[&](double at, double turn, gp_Pnt& p, gp_Vec& du, gp_Vec& dv,
                               gp_Vec& duu, gp_Vec& duv, gp_Vec& dvv)->bool {
        std::array<Section,5> q;
        std::array<gp_Pnt,5> points;
        std::array<gp_Vec,5> across;
        for (int i=0;i<5;++i) {
            double residual=0;
            if (!d.section(at+(i-2)*h,q[i],residual)) return false;
            points[i]=d.onArc(q[i],turn);
            across[i]=(q[i].x*(-std::sin(turn))+q[i].y*std::cos(turn))*q[i].r;
        }
        p=points[2];
        const gp_Vec a(p,points[0]),b(p,points[1]),c(p,points[3]),e(p,points[4]);
        du=(a-b*8+c*8-e)/(12*h);
        duu=(-a+b*16+c*16-e)/(12*h*h);
        dv=across[2];
        duv=(across[0]-across[1]*8+across[3]*8-across[4])/(12*h);
        dvv=gp_Vec(p,q[2].c);
        return true;
    };
    try {
        for (int iteration=0;iteration<40;++iteration) {
            gp_Pnt p;gp_Vec du,dv,duu,duv,dvv;
            if (!derivatives(s,theta,p,du,dv,duu,duv,dvv)) return false;
            const gp_Vec e(point,p);
            const double f1=e.Dot(du),f2=e.Dot(dv);
            if (std::fabs(f1)<=1e-10*du.Magnitude() && std::fabs(f2)<=1e-10*dv.Magnitude()) break;
            const double a=du.SquareMagnitude()+e.Dot(duu),b=du.Dot(dv)+e.Dot(duv),c=dv.SquareMagnitude()+e.Dot(dvv);
            const double determinant=a*c-b*b;
            if (!(std::fabs(determinant)>1e-300)) return false;
            double ds=-(c*f1-b*f2)/determinant,dt=-(a*f2-b*f1)/determinant;
            const double factor=std::min({1.0,length*.25/std::max(std::fabs(ds),1e-300),.5/std::max(std::fabs(dt),1e-300)});
            ds*=factor;dt*=factor;
            bool improved=false;
            for (int search=0;search<10;++search) {
                double residual=0;
                Section next;
                if (d.section(s+ds,next,residual) &&
                    d.onArc(next,theta+dt).SquareDistance(point)<=p.SquareDistance(point)+
                        1e-15*(1+p.SquareDistance(point))) {
                    s+=ds;theta+=dt;improved=true;break;
                }
                ds*=.5;dt*=.5;
            }
            if (!improved) {
                if (std::fabs(f1)<=1e-9*du.Magnitude() && std::fabs(f2)<=1e-9*dv.Magnitude()) break;
                return false;
            }
            if ((du*ds+dv*dt).Magnitude()<1e-12) break;
        }
        gp_Pnt p;gp_Vec du,dv,duu,duv,dvv;
        if (!derivatives(s,theta,p,du,dv,duu,duv,dvv) || !d.section(s,section,gap)) return false;
        const gp_Vec e(p,point);
        // A support is untrimmed: another blend can touch its regular continuation beyond a
        // surviving face or the fitted surface's margin. The original sections and radius law
        // still define that continuation; their evaluators reject singular or invalid sections.
        if (std::fabs(e.Dot(du))>1e-9*du.Magnitude() || std::fabs(e.Dot(dv))>1e-9*dv.Magnitude() ||
            !normalized(du.Crossed(dv),normal)) return false;
        nearest=p;distance=e.Dot(normal);position=s;angle=theta;
        return true;
    } catch (const Standard_Failure&) { return false; }
}

const std::string& Blend::edgeError() const { return impl_->edgeError; }

namespace {

// A surface as a level function: at p, the unit normal `n` and the signed distance `value` along it.
using Level = std::function<bool(const gp_Pnt& p, gp_Vec& n, double& value)>;

// Interpolate a complete analytic branch, checking the curve against its definition
// between every pair of samples. A partial chart selects a branch, not its extent.
TopoDS_Edge angularIntersectionEdge(const AnalyticEdgeSegment& segment,
                                     const std::function<double(const gp_Pnt&)>& angleOf,
                                     const std::function<gp_Pnt(double)>& value) {
    const gp_Pnt guide = toPnt(segment.hasBranchPoint ? segment.branchPoint : segment.chart.front());
    const gp_Pnt start = toPnt(segment.start), end = toPnt(segment.end);
    const bool ring = !segment.hasEndpoints;
    double from = ring ? angleOf(guide) : angleOf(start), span = 2.0 * kPi;
    if (!ring) {
        const double reach = std::max(1e-7, segment.tolerance);
        if (value(from).Distance(start) > reach || value(angleOf(end)).Distance(end) > reach) return {};
        const auto positiveAngle = [](double angle) {
            angle = std::fmod(angle, 2.0 * kPi);
            return angle < 0 ? angle + 2.0 * kPi : angle;
        };
        span = positiveAngle(angleOf(end) - from);
        if (span < 1e-12 || 2.0 * kPi - span < 1e-12) return {};
        double startGap = std::numeric_limits<double>::infinity(), endGap = startGap;
        for (const auto& p : segment.chart) {
            startGap = std::min(startGap, toPnt(p).Distance(start));
            endGap = std::min(endGap, toPnt(p).Distance(end));
        }
        if (std::max(startGap, endGap) > reach) {
            // A chart not reaching an endpoint can be wholly beyond the other endpoint.
            // Its middle then cannot select the long arc. Continue locally between the
            // vertices; the face builder still verifies the complete source boundary.
            if (span > kPi) span -= 2.0 * kPi;
        } else if (positiveAngle(angleOf(guide) - from) > span) {
            span -= 2.0 * kPi;
        }
    }
    try {
        for (int pieces = 32; pieces <= 2048; pieces *= 2) {
            const int count = ring ? pieces : pieces + 1;
            Handle(TColgp_HArray1OfPnt) points = new TColgp_HArray1OfPnt(1, count);
            Handle(TColStd_HArray1OfReal) parameters = new TColStd_HArray1OfReal(1, pieces + 1);
            for (int i = 0; i <= pieces; ++i) {
                const double t = std::fabs(span) * i / pieces;
                parameters->SetValue(i + 1, t);
                if (i < count) points->SetValue(i + 1, value(from + span * i / pieces));
            }
            GeomAPI_Interpolate interpolation(points, parameters, ring, 1e-12);
            interpolation.Perform();
            if (!interpolation.IsDone()) return {};
            const Handle(Geom_BSplineCurve) curve = interpolation.Curve();
            double worst = 0.0;
            for (int i = 0; i < pieces; ++i)
                for (double fraction : {0.25, 0.5, 0.75}) {
                    const double part = (i + fraction) / pieces;
                    worst = std::max(worst, curve->Value(std::fabs(span) * part).Distance(value(from + span * part)));
                }
            if (worst > 1e-9) continue;
            BRepBuilderAPI_MakeEdge maker(curve);
            if (!maker.IsDone()) return {};
            TopoDS_Edge edge = maker.Edge();
            if (ring && !segment.forward) edge.Reverse();
            return edge;
        }
    } catch (const Standard_Failure&) {
    }
    return {};
}

// If the smaller perpendicular cylinder lies inside the larger one's projection, each
// intersection branch is a single-valued function of the smaller cylinder's angle. Near
// internal tangency an SS intersection can return disconnected pieces, and an old ACIS
// chart may cover only one of them. Evaluate the complete branch from the two cylinders;
// the chart selects the arc, rather than limiting how far the intersection can continue.
TopoDS_Edge perpendicularCylinderEdge(const AnalyticEdgeSegment& segment) {
    using K = AnalyticSurfaceSupport::Kind;
    const auto& supports = segment.intersectionSurfaces;
    if (supports[0].kind != K::Cylinder || supports[1].kind != K::Cylinder) return {};
    const auto& small = supports[supports[0].radius <= supports[1].radius ? 0 : 1];
    const auto& large = supports[supports[0].radius <= supports[1].radius ? 1 : 0];
    gp_Vec a, b, x, y;
    if (!positiveFinite(small.radius) || !positiveFinite(large.radius) ||
        !normalized(toVec(small.normal), a) || !normalized(toVec(large.normal), b) ||
        std::fabs(a.Dot(b)) > 1e-12 || !normalized(a.Crossed(b), x)) return {};
    y = a.Crossed(x);
    const gp_Pnt origin = toPnt(small.origin);
    const gp_Vec offset(toPnt(large.origin), origin);
    const double axial = offset.Dot(a), radial = offset.Dot(x);
    if (large.radius - std::fabs(radial) - small.radius < -1e-12) return {};
    const auto angleOf = [&](const gp_Pnt& p) {
        const gp_Vec d(origin, p);
        return std::atan2(d.Dot(y), d.Dot(x));
    };
    const gp_Pnt guide = toPnt(segment.hasBranchPoint ? segment.branchPoint : segment.chart.front());
    const gp_Pnt start = toPnt(segment.start), end = toPnt(segment.end);
    double branch = gp_Vec(toPnt(large.origin), segment.hasEndpoints ? start : guide).Dot(a);
    if (std::fabs(branch) < 1e-10 && segment.hasEndpoints)
        branch = gp_Vec(toPnt(large.origin), end).Dot(a);
    if (std::fabs(branch) < 1e-10) branch = gp_Vec(toPnt(large.origin), guide).Dot(a);
    const double sign = branch >= 0 ? 1.0 : -1.0;
    const auto value = [&](double u) {
        const double r = radial + small.radius * std::cos(u);
        const double along = -axial + sign * std::sqrt(std::max(0.0, large.radius * large.radius - r * r));
        return origin.Translated(a * along + x * (small.radius * std::cos(u)) + y * (small.radius * std::sin(u)));
    };
    return angularIntersectionEdge(segment, angleOf, value);
}

// A plane parallel to a torus's axis cuts two branches parametrised by the tube
// angle. This remains evaluable at the inner tangency, where SS continuation stops.
TopoDS_Edge torusPlaneEdge(const AnalyticEdgeSegment& segment) {
    using K = AnalyticSurfaceSupport::Kind;
    const auto& supports = segment.intersectionSurfaces;
    const int side = supports[0].kind == K::Torus ? 0 : 1;
    const auto& torus = supports[side];
    const auto& plane = supports[1 - side];
    if (torus.kind != K::Torus || plane.kind != K::Plane ||
        !positiveFinite(torus.minorRadius) || !(torus.majorRadius > torus.minorRadius)) return {};
    gp_Vec axis, normal, across;
    if (!normalized(toVec(torus.normal), axis) || !normalized(toVec(plane.normal), normal) ||
        std::fabs(axis.Dot(normal)) > 1e-12 || !normalized(normal.Crossed(axis), across)) return {};
    const gp_Pnt origin = toPnt(torus.origin);
    const double height = gp_Vec(origin, toPnt(plane.origin)).Dot(normal);
    if (std::fabs(height) > torus.majorRadius - torus.minorRadius + 1e-12) return {};
    const auto angleOf = [&](const gp_Pnt& p) {
        const gp_Vec d(origin, p);
        const double along = d.Dot(axis);
        return std::atan2(along, (d - axis * along).Magnitude() - torus.majorRadius);
    };
    const gp_Pnt guide = toPnt(segment.hasBranchPoint ? segment.branchPoint : segment.chart.front());
    double branch = gp_Vec(origin, segment.hasEndpoints ? toPnt(segment.start) : guide).Dot(across);
    if (std::fabs(branch) < 1e-10 && segment.hasEndpoints)
        branch = gp_Vec(origin, toPnt(segment.end)).Dot(across);
    if (std::fabs(branch) < 1e-10) branch = gp_Vec(origin, guide).Dot(across);
    const double sign = branch >= 0 ? 1.0 : -1.0;
    const auto value = [&](double v) {
        const double radius = torus.majorRadius + torus.minorRadius * std::cos(v);
        const double acrossValue = sign * std::sqrt(std::max(0.0, (radius - std::fabs(height)) * (radius + std::fabs(height))));
        return origin.Translated(normal * height + across * acrossValue + axis * (torus.minorRadius * std::sin(v)));
    };
    return angularIntersectionEdge(segment, angleOf, value);
}

// With parallel axes the torus/cylinder intersection is the intersection of two
// circles in each plane normal to the axis. The tube angle supplies the height.
TopoDS_Edge torusCylinderEdge(const AnalyticEdgeSegment& segment) {
    using K = AnalyticSurfaceSupport::Kind;
    const auto& supports = segment.intersectionSurfaces;
    const int side = supports[0].kind == K::Torus ? 0 : 1;
    const auto& torus = supports[side];
    const auto& cylinder = supports[1 - side];
    if (torus.kind != K::Torus || cylinder.kind != K::Cylinder ||
        !positiveFinite(torus.minorRadius) || !(torus.majorRadius > torus.minorRadius) ||
        !positiveFinite(cylinder.radius)) return {};
    gp_Vec axis, cylinderAxis, along, across;
    if (!normalized(toVec(torus.normal), axis) || !normalized(toVec(cylinder.normal), cylinderAxis) ||
        std::fabs(axis.Dot(cylinderAxis)) < 1.0 - 1e-12) return {};
    const gp_Pnt origin = toPnt(torus.origin);
    const gp_Vec offset(origin, toPnt(cylinder.origin));
    const gp_Vec inPlane = offset - axis * offset.Dot(axis);
    const double distance = inPlane.Magnitude();
    if (!(distance > 1e-12) || !normalized(inPlane, along)) return {};
    across = axis.Crossed(along);
    const double lower = std::fabs(distance - cylinder.radius), upper = distance + cylinder.radius;
    if (torus.majorRadius - torus.minorRadius < lower - 1e-12 ||
        torus.majorRadius + torus.minorRadius > upper + 1e-12) return {};
    const auto angleOf = [&](const gp_Pnt& p) {
        const gp_Vec d(origin, p);
        const double height = d.Dot(axis);
        return std::atan2(height, (d - axis * height).Magnitude() - torus.majorRadius);
    };
    const gp_Pnt guide = toPnt(segment.hasBranchPoint ? segment.branchPoint : segment.chart.front());
    double branch = gp_Vec(origin, segment.hasEndpoints ? toPnt(segment.start) : guide).Dot(across);
    if (std::fabs(branch) < 1e-10 && segment.hasEndpoints)
        branch = gp_Vec(origin, toPnt(segment.end)).Dot(across);
    if (std::fabs(branch) < 1e-10) branch = gp_Vec(origin, guide).Dot(across);
    const double sign = branch >= 0 ? 1.0 : -1.0;
    const auto value = [&](double v) {
        const double radius = torus.majorRadius + torus.minorRadius * std::cos(v);
        const double projected = (radius * radius + distance * distance - cylinder.radius * cylinder.radius) / (2.0 * distance);
        const double area = (radius - lower) * (radius + lower) * (upper - radius) * (upper + radius);
        const double transverse = sign * std::sqrt(std::max(0.0, area)) / (2.0 * distance);
        return origin.Translated(along * projected + across * transverse + axis * (torus.minorRadius * std::sin(v)));
    };
    return angularIntersectionEdge(segment, angleOf, value);
}

// An edge where two surfaces meet, from its XT chart: points put on both by Newton (on the plane
// through the chart's guess square to the chart), interpolated, and checked between them — more points
// until the curve is within kTarget of both, refused beyond kLimit. `what` names the edge in reasons.
// The levels may start each search from the last one's result; `restart` makes the next search fresh,
// before each run of points along the chart (from a far point a search can settle a thread's turn away).
TopoDS_Edge chartEdge(const AnalyticEdgeSegment& segment, const Level& first, const Level& second,
                      const std::function<void()>& restart, const std::string& what, std::string& why) {
    const auto refine = [&](gp_Pnt& p, const gp_Vec& normal, const gp_Pnt& on) {
        for (int i = 0; i < 50; ++i) {
            gp_Vec n1, n2;
            double d1, d2;
            if (!first(p, n1, d1) || !second(p, n2, d2)) return false;
            const double d3 = gp_Vec(on, p).Dot(normal);
            const double det = n1.Dot(n2.Crossed(normal));
            if (!(std::fabs(det) > 1e-10)) return false; // the two nearly tangent: no sharp point
            const gp_Vec step = -(n2.Crossed(normal) * d1 + normal.Crossed(n1) * d2 + n1.Crossed(n2) * d3) / det;
            p.Translate(step);
            if (step.Magnitude() < 1e-15) break;
        }
        gp_Vec n;
        double d1 = 1, d2 = 1;
        return first(p, n, d1) && second(p, n, d2) && std::fabs(d1) < 1e-10 && std::fabs(d2) < 1e-10;
    };
    std::vector<gp_Pnt> chart;
    for (const auto& q : segment.chart) chart.push_back(toPnt(q));
    const bool closed = segment.chartClosed && chart.size() > 2;
    if (closed && chart.front().Distance(chart.back()) < 1e-9) chart.pop_back();
    const std::size_t n = chart.size();
    if (n < 2) { why = what + " has no chart"; return {}; }
    const bool ring = !segment.hasEndpoints;
    if (ring && !closed) { why = "a ring (" + what + ") whose chart is not closed"; return {}; }
    const gp_Pnt start = toPnt(segment.start), end = toPnt(segment.end);
    const auto nearestOf = [](const std::vector<gp_Pnt>& points, const gp_Pnt& q, std::size_t from) {
        std::size_t best = from;
        for (std::size_t j = from + 1; j < points.size(); ++j)
            if (points[j].SquareDistance(q) < points[best].SquareDistance(q)) best = j;
        return best;
    };
    // The chart steps to put points on (step j from point j to the next, round a closed chart): a
    // ring's all; round a closed chart, from a step before the vertex met first — the start, or the
    // end when the edge runs against the curve — once round and a step more; along an open one, from
    // a step before the nearer vertex to the farther.
    std::vector<std::size_t> steps;
    if (ring) {
        for (std::size_t j = 0; j < n; ++j) steps.push_back(j);
    } else if (closed) {
        const std::size_t a = nearestOf(chart, segment.forward ? start : end, 0);
        for (std::size_t k = 0; k <= n; ++k) steps.push_back((a + n - 1 + k) % n);
    } else {
        std::size_t a = nearestOf(chart, start, 0), b = nearestOf(chart, end, 0);
        if (a > b) std::swap(a, b);
        for (std::size_t j = a > 0 ? a - 1 : 0; j <= std::min(b, n - 2); ++j) steps.push_back(j);
    }
    try {
        for (int pieces = 8; pieces <= 128; pieces *= 2) {
            // Points along the chart; where the two surfaces meet tangentially (a blend running into
            // another of its radius, a thread running out) one may not converge — tolerated only
            // next to the ends.
            std::vector<gp_Pnt> dense;
            std::vector<char> converged;
            restart();
            for (const std::size_t j : steps) {
                const gp_Pnt a = chart[j], b = chart[(j + 1) % n];
                gp_Vec along;
                if (!normalized(gp_Vec(a, b), along)) continue;
                for (int k = 0; k < pieces; ++k) {
                    const gp_Pnt guess = a.Translated(gp_Vec(a, b) * (double(k) / pieces));
                    gp_Pnt p = guess;
                    const bool ok = refine(p, along, guess);
                    dense.push_back(p);
                    converged.push_back(ok);
                }
            }
            if (!ring) {
                const std::size_t j = steps.back();
                const gp_Pnt last = chart[(j + 1) % n];
                gp_Pnt p = last;
                gp_Vec along;
                const bool ok = normalized(gp_Vec(chart[j], last), along) && refine(p, along, last);
                dense.push_back(p);
                converged.push_back(ok);
            }
            std::vector<gp_Pnt> points;
            if (ring) {
                for (std::size_t j = 0; j < dense.size(); ++j) {
                    if (!converged[j]) { why = "a point of " + what + " (a ring) does not converge"; return {}; }
                    if (points.empty() || dense[j].Distance(points.back()) >= 1e-9) points.push_back(dense[j]);
                }
                if (points.size() > 2 && points.front().Distance(points.back()) < 1e-9) points.pop_back();
                if (points.size() < 3) { why = what + " (a ring) has too few points"; return {}; }
            } else {
                // From the dense point nearest the vertex met first to that nearest the other (after it,
                // round a closed chart), the vertices themselves at the ends.
                std::size_t from, to;
                bool startFirst;
                if (closed) {
                    startFirst = segment.forward;
                    from = nearestOf(dense, startFirst ? start : end, 0);
                    to = from + 1 < dense.size() ? nearestOf(dense, startFirst ? end : start, from + 1) : from;
                } else {
                    from = nearestOf(dense, start, 0);
                    to = nearestOf(dense, end, 0);
                    startFirst = from <= to;
                    if (!startFirst) std::swap(from, to);
                }
                const gp_Pnt head = startFirst ? start : end, tail = startFirst ? end : start;
                points.push_back(head);
                for (std::size_t j = from + 1; j < to; ++j) {
                    if (!converged[j]) {
                        if (j > from + std::size_t(pieces) && j + std::size_t(pieces) < to) {
                            why = "an interior point of " + what + " does not converge";
                            return {};
                        }
                        continue;
                    }
                    if (dense[j].Distance(points.back()) < 1e-9) continue;
                    points.push_back(dense[j]);
                }
                if (points.back().Distance(tail) < 1e-9 && points.size() > 1) points.pop_back();
                points.push_back(tail);
                if (!startFirst) std::reverse(points.begin(), points.end());
                if (points.size() < 2) { why = what + " has no points"; return {}; }
            }
            Handle(TColgp_HArray1OfPnt) values = new TColgp_HArray1OfPnt(1, int(points.size()));
            for (std::size_t j = 0; j < points.size(); ++j) values->SetValue(int(j) + 1, points[j]);
            GeomAPI_Interpolate interpolation(values, ring, 1e-12);
            interpolation.Perform();
            if (!interpolation.IsDone()) { why = what + " does not interpolate"; return {}; }
            const Handle(Geom_BSplineCurve) curve = interpolation.Curve();
            // Between the points: on both surfaces?
            double worst = 0;
            const double t0 = curve->FirstParameter(), t1 = curve->LastParameter();
            const int samples = 4 * int(points.size());
            restart();
            for (int m = 0; m <= samples; ++m) {
                const gp_Pnt q = curve->Value(t0 + (t1 - t0) * m / samples);
                gp_Vec normal;
                double d1, d2;
                if (!first(q, normal, d1) || !second(q, normal, d2)) {
                    worst = std::numeric_limits<double>::infinity();
                    break;
                }
                worst = std::max({worst, std::fabs(d1), std::fabs(d2)});
            }
            if (worst <= kTarget || pieces == 128) {
                if (!(worst <= kLimit)) {
                    why = what + " is " + std::to_string(worst) + " m off its surfaces";
                    return {};
                }
                BRepBuilderAPI_MakeEdge maker(curve);
                if (!maker.IsDone()) { why = what + ": no edge"; return {}; }
                TopoDS_Edge edge = maker.Edge();
                if (ring && !segment.forward) edge.Reverse();
                return edge;
            }
        }
    } catch (const Standard_Failure& failure) {
        why = what + ": " + failure.GetMessageString();
        return {};
    }
    why = what + ": no edge";
    return {};
}

} // namespace

TopoDS_Edge Blend::crossingEdge(const AnalyticEdgeSegment& segment, int side) const {
    const Impl& d = *impl_;
    auto& why = d.edgeError;
    if (d.surface.IsNull() || side < 0 || side > 1) { why = "no blend surface"; return {}; }
    if (!segment.hasEndpoints) { why = "a ring across a blend is not supported"; return {}; }
    const auto& chart = segment.chart;
    if (chart.size() < 2) { why = "the edge across the blend has no chart"; return {}; }
    const AnalyticSurfaceSupport& otherDefinition = segment.intersectionSurfaces[1 - side];
    if (otherDefinition.kind == AnalyticSurfaceSupport::Kind::Blend) { why = "two blends crossing is not supported"; return {}; }
    // The other surface; a B-spline's grid layout the one the chart lies on.
    Surface other;
    {
        const bool numeric = otherDefinition.kind == AnalyticSurfaceSupport::Kind::BSpline ||
                             otherDefinition.kind == AnalyticSurfaceSupport::Kind::BSplineOffset;
        int bestCount = -1, bestOrdering = 0;
        for (int ordering = 0; ordering < (numeric ? 2 : 1); ++ordering) {
            if (!other.init(otherDefinition, ordering)) continue;
            int count = 0;
            for (const auto& p : chart) {
                gp_Pnt f;
                gp_Vec n;
                double distance;
                count += other.foot(toPnt(p), f, n, distance) && std::fabs(distance) < 1e-6;
            }
            if (count > bestCount) { bestCount = count; bestOrdering = ordering; }
        }
        if (bestCount < 2 || !other.init(otherDefinition, bestOrdering)) {
            why = "the chart of the edge across the blend is not on its other surface";
            return {};
        }
    }
    // The blend as its definition: distance from the spine less the radius, whose gradient is the unit
    // vector from the spine's nearest point.
    double spineGuess = 0;
    bool haveGuess = false;
    const auto ball = [&](const gp_Pnt& p, gp_Vec& n, double& value) {
        double s;
        if (d.variable) {
            // The ball of the cross-section through p.
            Section q;
            if (!haveGuess && !d.spine.foot(p, spineGuess)) return false;
            if (!d.sectionOf(p, spineGuess, s, q)) return false;
            const gp_Vec e(q.c, p);
            const double m = e.Magnitude();
            if (!(m > 1e-12)) return false;
            n = e / m;
            value = m - q.r;
            spineGuess = s;
            haveGuess = true;
            return true;
        }
        if (!(haveGuess ? d.spine.footNear(p, spineGuess, s) : d.spine.foot(p, s))) return false;
        gp_Pnt c;
        gp_Vec t;
        if (!d.spine.at(s, c, t)) return false;
        const gp_Vec e(c, p);
        const double m = e.Magnitude();
        if (!(m > 1e-12)) return false;
        n = e / m;
        value = m - d.radius;
        spineGuess = s;
        haveGuess = true;
        return true;
    };
    const Level onOther = [&](const gp_Pnt& p, gp_Vec& n, double& value) {
        gp_Pnt f;
        return other.foot(p, f, n, value);
    };
    const auto restart = [&] {
        haveGuess = false;
        other.restart();
    };
    return chartEdge(segment, ball, onOther, restart, "the edge across the blend", why);
}

TopoDS_Edge intersectionEdge(const AnalyticEdgeSegment& segment, std::string& why) {
    const auto& chart = segment.chart;
    if (chart.size() < 2) { why = "the intersection edge has no chart"; return {}; }
    if (const TopoDS_Edge edge = perpendicularCylinderEdge(segment); !edge.IsNull()) return edge;
    if (const TopoDS_Edge edge = torusPlaneEdge(segment); !edge.IsNull()) return edge;
    if (const TopoDS_Edge edge = torusCylinderEdge(segment); !edge.IsNull()) return edge;
    // Each surface; a B-spline's grid layout the one the chart lies on.
    Surface surfaces[2];
    for (int i = 0; i < 2; ++i) {
        const AnalyticSurfaceSupport& definition = segment.intersectionSurfaces[i];
        const bool numeric = definition.kind == AnalyticSurfaceSupport::Kind::BSpline ||
                             definition.kind == AnalyticSurfaceSupport::Kind::BSplineOffset;
        int bestCount = -1, bestOrdering = 0;
        for (int ordering = 0; ordering < (numeric ? 2 : 1); ++ordering) {
            if (!surfaces[i].init(definition, ordering)) continue;
            int count = 0;
            for (const auto& p : chart) {
                gp_Pnt f;
                gp_Vec n;
                double distance;
                count += surfaces[i].foot(toPnt(p), f, n, distance) && std::fabs(distance) < 1e-6;
            }
            if (count > bestCount) { bestCount = count; bestOrdering = ordering; }
        }
        if (bestCount < 0) {
            why = "surface " + std::to_string(i + 1) + " of the intersection is of a kind (" +
                  std::to_string(int(definition.kind)) + ") not evaluated from a chart";
            return {};
        }
        if (bestCount < 2 || !surfaces[i].init(definition, bestOrdering)) {
            why = "the chart of the intersection edge is not on its surface " + std::to_string(i + 1);
            return {};
        }
    }
    const auto level = [&](int i) -> Level {
        return [&, i](const gp_Pnt& p, gp_Vec& n, double& value) {
            gp_Pnt f;
            return surfaces[i].foot(p, f, n, value);
        };
    };
    const auto restart = [&] {
        surfaces[0].restart();
        surfaces[1].restart();
    };
    return chartEdge(segment, level(0), level(1), restart, "the intersection edge", why);
}

TopoDS_Edge Blend::boundaryEdge(int boundary, const AnalyticEdgeSegment& segment) const {
    const Impl& d = *impl_;
    auto& why = d.edgeError;
    if (d.surface.IsNull() || boundary < 0 || boundary > 1) { why = "no blend surface"; return {}; }
    const bool full = !segment.hasEndpoints || toPnt(segment.start).Distance(toPnt(segment.end)) < 1e-10;
    try {
        if (full) {
            if (!d.ring) { why = "a contact ring on a blend that is not a ring"; return {}; }
            const Handle(Geom_BSplineCurve) curve = d.contactCurve(boundary, d.from, d.to, nullptr, nullptr, true);
            if (curve.IsNull()) { why = "contact ring does not fit its support"; return {}; }
            BRepBuilderAPI_MakeEdge maker(curve);
            if (!maker.IsDone()) { why = "contact ring edge"; return {}; }
            TopoDS_Edge edge = maker.Edge();
            if (!segment.forward) edge.Reverse();
            return edge;
        }
        const gp_Pnt start = toPnt(segment.start), end = toPnt(segment.end);
        double a, b;
        if (!d.positionOf(start, a) || !d.positionOf(end, b)) { why = "a contact edge's end has no spine point"; return {}; }
        // Each end must be where the ball touches that support.
        for (const gp_Pnt* vertex : {&start, &end}) {
            double s;
            gp_Pnt c, f;
            gp_Vec t, n;
            double distance;
            if (d.variable) {
                Section q;
                double gap = 0;
                f = d.positionOf(*vertex, s) && d.section(s, q, gap) ? q.contact[boundary] : gp_Pnt(1e300, 0, 0);
                if (!(f.Distance(*vertex) <= kLimit)) {
                    why = "a contact edge's end is " + std::to_string(f.Distance(*vertex)) + " m from the contact point";
                    return {};
                }
                continue;
            }
            if (!d.spine.foot(*vertex, s) || !d.spine.at(s, c, t) || !d.supports[boundary].foot(c, f, n, distance) ||
                !(f.Distance(*vertex) <= kLimit)) {
                why = "a contact edge's end is " + std::to_string(f.Distance(*vertex)) + " m from the contact point";
                return {};
            }
        }
        // Into the surface's extent, whose positions on a closed spine may run past its length.
        const auto inside = [&](double s) {
            if (!d.spine.closed()) return s;
            const double length = d.spine.length();
            while (s < d.from - 1e-9) s += length;
            while (s > d.to + 1e-9) s -= length;
            return s;
        };
        a = inside(a);
        b = inside(b);
        if (d.spine.closed() && segment.hasBranchPoint) {
            double middle;
            if (d.spine.foot(toPnt(segment.branchPoint),middle)) {
                middle=inside(middle);
                if (middle<std::min(a,b)-1e-9 || middle>std::max(a,b)+1e-9) {
                    if (a<b) a+=d.spine.length(); else b+=d.spine.length();
                }
            }
        }
        const bool increasing = a < b;
        const Handle(Geom_BSplineCurve) curve = increasing ? d.contactCurve(boundary, a, b, &start, &end, false)
                                                           : d.contactCurve(boundary, b, a, &end, &start, false);
        if (curve.IsNull()) {
            why = "contact curve does not fit its support (" + std::to_string(d.lastContactFit) + " m off at best, " +
                  std::to_string(d.sections.size() - 1) + " sections, deviation " + std::to_string(d.deviation) + ")";
            return {};
        }
        BRepBuilderAPI_MakeEdge maker(curve);
        if (!maker.IsDone()) { why = "contact edge"; return {}; }
        TopoDS_Edge edge = maker.Edge();
        if (!increasing) edge.Reverse();
        return edge;
    } catch (const Standard_Failure& failure) {
        why = std::string("contact edge: ") + failure.GetMessageString();
        return {};
    }
}

namespace {
thread_local int buildScopeDepth=0;
thread_local std::map<const RollingBallBlend*,std::shared_ptr<const Blend>> builtBlends;
}

BuildScope::BuildScope() { if (buildScopeDepth++==0) builtBlends.clear(); }
BuildScope::~BuildScope() { if (--buildScopeDepth==0) builtBlends.clear(); }

std::shared_ptr<const Blend> buildBlend(const std::shared_ptr<const RollingBallBlend>& definition) {
    if (!definition) return {};
    if (buildScopeDepth==0) return std::make_shared<Blend>(*definition);
    auto& value=builtBlends[definition.get()];
    if (!value) value=std::make_shared<Blend>(*definition);
    return value;
}

} // namespace cadnext::kernel::rolling_ball

#endif // CADNEXT_WITH_OCCT
