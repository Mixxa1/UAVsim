#ifdef CADNEXT_WITH_OCCT
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/ThreadCut.hpp"

#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepCheck_Result.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <gp_Lin.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepLib.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepTools.hxx>
#include <Geom_Plane.hxx>
#include <ShapeExtend.hxx>
#include <ShapeUpgrade_FaceDivide.hxx>
#include <ShapeUpgrade_ShapeDivide.hxx>
#include <ShapeUpgrade_SplitSurface.hxx>
#include <TColStd_HSequenceOfReal.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom2d_Line.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Standard_Failure.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <gp_Circ.hxx>

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

namespace cadnext::kernel {

namespace {

constexpr double kPi = 3.14159265358979323846;
// What the sweep is built to, and the bound beyond which a thread is refused (as for blends).
constexpr double kTarget = 1e-8;
constexpr double kLimit = 1e-6;
// A face standing proud of the thread's crest by more than this is turned (bored) to it first: a skin
// thinner would be cut under OCCT's own precision (1e-7 m), and within it the face is the crest to far
// better than any tolerance class (6g on M8: 28 µm).
constexpr double kProud = 1e-6;
// How far inside a rounded crest (Whitworth: G, R, Rc) the body's face is kept, the crest there cut flat.
// At 1 µm the crest crosses the face at 4.5–7° (11 to 28 threads per inch) — cut right on every G and R
// tried; touching it (0) it did not. The profile is off by as much at the crest only: G's major diameter
// is toleranced in tenths of a millimetre (ISO 228-1).
constexpr double kSeat = 1e-6;

// One piece of a groove profile in the axial half-plane: rho (from the axis) and z (along it, from the
// groove's centre). An arc runs from a to b round its centre the short way.
struct Piece {
    double ar, az, br, bz;
    bool arc = false;
    double cr = 0, cz = 0, radius = 0;
};

double distanceTo(const Piece& p, double r, double z) {
    if (!p.arc) {
        const double vr = p.br - p.ar, vz = p.bz - p.az;
        const double t = std::clamp(((r - p.ar) * vr + (z - p.az) * vz) / (vr * vr + vz * vz), 0.0, 1.0);
        return std::hypot(r - p.ar - t * vr, z - p.az - t * vz);
    }
    // Within the arc's angular span: |distance to centre - radius|; otherwise the nearer end.
    const auto angle = [&](double rr, double zz) { return std::atan2(zz - p.cz, rr - p.cr); };
    const double a = angle(p.ar, p.az), b = angle(p.br, p.bz), q = angle(r, z);
    double span = std::remainder(b - a, 2 * kPi), at = std::remainder(q - a, 2 * kPi);
    const bool inside = span >= 0 ? (at >= 0 && at <= span) : (at <= 0 && at >= span);
    if (inside) return std::fabs(std::hypot(r - p.cr, z - p.cz) - p.radius);
    return std::min(std::hypot(r - p.ar, z - p.az), std::hypot(r - p.br, z - p.bz));
}

// Foot of the perpendicular from (r, z) to the line through (r0, z0) along (dr, dz).
void foot(double r, double z, double r0, double z0, double dr, double dz, double& fr, double& fz) {
    const double n = std::hypot(dr, dz);
    const double t = ((r - r0) * dr + (z - z0) * dz) / (n * n);
    fr = r0 + t * dr;
    fz = z0 + t * dz;
}

// The groove of an external thread of major radius R, closed above the major radius (by `outside`);
// its turns stay clear of each other.
// `surface`: the body's surface there (0: unknown); a rounded crest stops kEdge inside it where it lies
// below the crest, see ThreadCutParameters::surfaceDiameter.
std::vector<Piece> externalGroove(ThreadProfileKind kind, double R, double P, double outside, double surface,
                                  double& innerRadius) {
    std::vector<Piece> pieces;
    const auto line = [&](double ar, double az, double br, double bz) { pieces.push_back({ar, az, br, bz}); };
    switch (kind) {
    case ThreadProfileKind::Metric60: {
        // ISO 68-1: depth 5H/8 from the major radius, groove width 7P/8 there and P/4 at the root.
        const double H = std::sqrt(3.0) / 2 * P, t = std::tan(kPi / 6), rb = R - 5 * H / 8;
        const double top = 7 * P / 16 + outside * t;
        line(R + outside, -top, R + outside, top);
        line(R + outside, top, rb, P / 8);
        line(rb, P / 8, rb, -P / 8);
        line(rb, -P / 8, R + outside, -top);
        innerRadius = rb;
        break;
    }
    case ThreadProfileKind::Npt60: {
        // ASME B1.20.1: h = 0.8P, the fundamental triangle truncated equally at crest and root.
        const double H = std::sqrt(3.0) / 2 * P, t = std::tan(kPi / 6), h = 0.8 * P, f = (H - h) / 2;
        const double atMajor = P / 2 - f * t, atRoot = P / 2 - (f + h) * t, top = atMajor + outside * t;
        line(R + outside, -top, R + outside, top);
        line(R + outside, top, R - h, atRoot);
        line(R - h, atRoot, R - h, -atRoot);
        line(R - h, -atRoot, R + outside, -top);
        innerRadius = R - h;
        break;
    }
    case ThreadProfileKind::Whitworth55: {
        // ISO 228-1: H = 0.960491P truncated by H/6 at both ends, rounded r = 0.137329P tangent to the
        // flanks. The rounded crests touch the major radius, so the groove stops kEdge below it: the next
        // turn stays clear (by 2·sqrt(2 r kEdge), 3–5 µm), the crest left flat there off the profile by
        // at most kEdge. kEdge is the build target: at 1e-7 m, OCCT's own tolerance, the cut merged the
        // walls that short and left a layer that thick along the crest arcs (G1/2: 4e-11 m3 kept).
        constexpr double kEdge = kTarget;
        const double H = 0.960491 * P, h = 0.640327 * P, r = 0.137329 * P, t = std::tan(27.5 * kPi / 180);
        const double apex = R - 5 * H / 6; // the sharp groove's bottom
        // Flanks through the apex: z = +/-(rho - apex) t.
        double trR, trZ, crR, crZ;
        foot(R - h + r, 0, apex, 0, 1, t, trR, trZ);   // root arc meets the right flank
        foot(R - r, P / 2, apex, 0, 1, t, crR, crZ);   // right crest arc meets it
        // Where the crest is left: kEdge under the major radius, or under the body's surface where that
        // crosses the crest arc.
        double level = R - kEdge;
        if (surface - kEdge < level && surface - kEdge > crR + kEdge) level = surface - kEdge;
        const double zEdge = P / 2 - std::sqrt(r * r - (r - (R - level)) * (r - (R - level)));
        const double top = zEdge;
        line(R + outside, -top, R + outside, top);
        line(R + outside, top, level, zEdge);
        pieces.push_back({level, zEdge, crR, crZ, true, R - r, P / 2, r});
        line(crR, crZ, trR, trZ);
        pieces.push_back({trR, trZ, trR, -trZ, true, R - h + r, 0, r});
        line(trR, -trZ, crR, -crZ);
        pieces.push_back({crR, -crZ, level, -zEdge, true, R - r, -P / 2, r});
        line(level, -zEdge, R + outside, -top);
        innerRadius = R - h;
        break;
    }
    }
    return pieces;
}

// The groove of an internal thread (in a hole's wall) of major radius R, closed inside the hole.
// A line in the axial half-plane: a point (r, z) and a direction.
struct Line2 {
    double r, z, dr, dz;
    Line2 shifted(double sr, double sz) const { return {r + sr, z + sz, dr, dz}; }
};

bool intersect(const Line2& a, const Line2& b, double& r, double& z) {
    const double det = a.dr * (-b.dz) - a.dz * (-b.dr);
    if (std::fabs(det) < 1e-300) return false;
    const double s = ((b.r - a.r) * (-b.dz) - (b.z - a.z) * (-b.dr)) / det;
    r = a.r + s * a.dr;
    z = a.z + s * a.dz;
    return true;
}

// The arc of radius `radius` tangent to lines a and b on the side of (qr, qz): its centre and where it
// touches each (the lines offset by the radius toward that side meet at the centre).
bool tangentArc(const Line2& a, const Line2& b, double radius, double qr, double qz, double& cr, double& cz,
                double& ar, double& az, double& br, double& bz) {
    const auto offset = [&](const Line2& l) {
        const double n = std::hypot(l.dr, l.dz);
        double nr = -l.dz / n, nz = l.dr / n;
        if ((qr - l.r) * nr + (qz - l.z) * nz < 0) nr = -nr, nz = -nz;
        return Line2{l.r + radius * nr, l.z + radius * nz, l.dr, l.dz};
    };
    if (!intersect(offset(a), offset(b), cr, cz)) return false;
    foot(cr, cz, a.r, a.z, a.dr, a.dz, ar, az);
    foot(cr, cz, b.r, b.z, b.dr, b.dz, br, bz);
    return true;
}

// Where a circle (centre, radius) is `gap` off the cone line rho = base + k z, measured along rho
// (gap < 0: on the axis's side of it), the solution nearer the given side: the one of smaller z when
// `lowerZ`, else of larger z. A circle that does not reach that far is taken |gap| short of its own
// farthest point instead: a taper profile's rounded crest, tangent to its flanks, stops short of its
// cone (by 0.1 µm on R1/2), and at the farthest point itself the groove's neighbouring turns would meet —
// a groove touching itself along a helix, which OCCT's cut takes and returns wrong (Rc1/2: 12 % short).
void coneGapPoint(double cr, double cz, double radius, double base, double k, double gap, bool lowerZ, double& pr,
                  double& pz) {
    // r (cos φ - k sin φ) = base + k cz - cr + gap, i.e. cos(φ + β) = v with tan β = k.
    const double beta = std::atan(k), scale = radius * std::sqrt(1 + k * k), shy = std::fabs(gap) / scale;
    const double v = std::clamp((base + k * cz - cr + gap) / scale, -1.0 + shy, 1.0 - shy), a = std::acos(v);
    double best = 0;
    bool found = false;
    for (const double phi : {-beta + a, -beta - a}) {
        const double z = cz + radius * std::sin(phi);
        if (!found || (lowerZ ? z < pz : z > pz)) {
            pr = cr + radius * std::cos(phi);
            pz = z;
            best = phi;
            found = true;
        }
    }
    (void)best;
}

// The groove of a taper thread (ASME B1.20.1, ISO 7-1): the profile's bisector square to the axis, its
// flanks at the fixed angle, each crossing the pitch cone where it should — a quarter pitch either side
// of the groove's centre, so the right flank lies kP/2 further out than the left; flats (NPT) along the
// root and crest cones, rounded crests and roots (Whitworth) tangent to their two flanks, a neighbouring
// turn's shifted by (±kP, ±P). R is the major radius at the groove's centre, k the radius's growth per
// unit of axial length. A rigid parallel profile moved out as it turns would distort each tooth by
// ±kP/4 (14 µm on 1/2 NPT).
std::vector<Piece> taperGroove(ThreadProfileKind kind, bool internal, double R, double P, double k, double outside,
                               double surface, double& innerRadius) {
    std::vector<Piece> pieces;
    const auto line = [&](double ar, double az, double br, double bz) { pieces.push_back({ar, az, br, bz}); };
    const auto arc = [&](double ar, double az, double br, double bz, double cr, double cz, double radius) {
        pieces.push_back({ar, az, br, bz, true, cr, cz, radius});
    };
    const bool npt = kind == ThreadProfileKind::Npt60;
    const double h = npt ? 0.8 * P : 0.640327 * P, t = std::tan(npt ? kPi / 6 : 27.5 * kPi / 180);
    const double pitch = R - h / 2;   // the pitch cone at the groove's centre
    const double minor = pitch - h / 2;
    innerRadius = minor;
    // The flanks of the groove (external) or of the tooth the nut's groove is (internal).
    const double sign = internal ? 1.0 : -1.0;
    const Line2 left{pitch - k * P / 4, -P / 4, 1, sign * t};
    const Line2 right{pitch + k * P / 4, P / 4, 1, -sign * t};
    const auto cone = [&](double base) { return Line2{base, 0, k, 1}; };
    double ar, az, br, bz, cr, cz, dr, dz;
    if (npt) {
        // External: from the root cone up past the crest cone; internal: from the nut's root cone
        // (the major) down past the hole's wall.
        const Line2 low = internal ? cone(R) : cone(minor), high = internal ? cone(minor - outside) : cone(R + outside);
        if (!intersect(left, low, ar, az) || !intersect(right, low, br, bz) || !intersect(right, high, cr, cz) ||
            !intersect(left, high, dr, dz))
            return {};
        line(ar, az, br, bz);
        line(br, bz, cr, cz);
        line(cr, cz, dr, dz);
        line(dr, dz, ar, az);
        return pieces;
    }
    // Whitworth, radius r everywhere; the groove stops kTarget short of where a rounded crest touches
    // its cone, as for the parallel form. ISO 7-1's radius, not ISO 228-1's 0.137329P: with the flanks
    // at a fixed angle to the axis the taper narrows the tooth, and at the parallel form's radius the
    // arcs fall 0.1 µm short of the cones (R1/2) — a crest passing that close under its blank without
    // touching it, which OCCT's cut took and got wrong (2.5 times the build target in volume).
    const double r = 0.137278 * P, edge = kTarget;
    if (!internal) {
        double c0r, c0z, l0r, l0z, r0r, r0z;       // root arc, between the flanks
        double cRr, cRz, rTr, rTz, x1, x2;         // right crest: right flank and the next turn's left
        double cLr, cLz, lTr, lTz, y1, y2;         // left crest: left flank and the last turn's right
        if (!tangentArc(left, right, r, pitch, 0, c0r, c0z, l0r, l0z, r0r, r0z) ||
            !tangentArc(right, left.shifted(k * P, P), r, pitch + k * P / 2, P / 2, cRr, cRz, rTr, rTz, x1, x2) ||
            !tangentArc(left, right.shifted(-k * P, -P), r, pitch - k * P / 2, -P / 2, cLr, cLz, lTr, lTz, y1, y2))
            return {};
        // The crest left edge under the major cone, or under the body's surface where that crosses the arc.
        double baseR = R, baseL = R;
        if (surface > 0.0 && surface < R) {
            if (surface - edge > rTr - k * rTz) baseR = surface;
            if (surface - edge > lTr - k * lTz) baseL = surface;
        }
        double eRr, eRz, eLr, eLz;
        coneGapPoint(cRr, cRz, r, baseR, k, -edge, true, eRr, eRz);
        coneGapPoint(cLr, cLz, r, baseL, k, -edge, false, eLr, eLz);
        const double top = R + outside;
        line(top + k * eLz, eLz, top + k * eRz, eRz);
        line(top + k * eRz, eRz, eRr, eRz);
        arc(eRr, eRz, rTr, rTz, cRr, cRz, r);
        line(rTr, rTz, r0r, r0z);
        arc(r0r, r0z, l0r, l0z, c0r, c0z, r);
        line(l0r, l0z, lTr, lTz);
        arc(lTr, lTz, eLr, eLz, cLr, cLz, r);
        line(eLr, eLz, top + k * eLz, eLz);
        return pieces;
    }
    // Internal: the groove is the screw's tooth — its crest (the nut's root) between the flanks, the
    // screw's roots on either side (the nut's crests) stopping kTarget short of the hole's wall.
    double ccr, ccz, lcr, lcz, rcr, rcz;
    double cRr, cRz, rRr, rRz, x1, x2;
    double cLr, cLz, lRr, lRz, y1, y2;
    if (!tangentArc(left, right, r, pitch, 0, ccr, ccz, lcr, lcz, rcr, rcz) ||
        !tangentArc(right, left.shifted(k * P, P), r, pitch + k * P / 2, P / 2, cRr, cRz, rRr, rRz, x1, x2) ||
        !tangentArc(left, right.shifted(-k * P, -P), r, pitch - k * P / 2, -P / 2, cLr, cLz, lRr, lRz, y1, y2))
        return {};
    double baseR = minor, baseL = minor;
    if (surface > minor) {
        if (surface + edge < rRr - k * rRz) baseR = surface;
        if (surface + edge < lRr - k * lRz) baseL = surface;
    }
    double eRr, eRz, eLr, eLz;
    coneGapPoint(cRr, cRz, r, baseR, k, edge, true, eRr, eRz);
    coneGapPoint(cLr, cLz, r, baseL, k, edge, false, eLr, eLz);
    const double bottom = minor - outside;
    arc(lcr, lcz, rcr, rcz, ccr, ccz, r);
    line(rcr, rcz, rRr, rRz);
    arc(rRr, rRz, eRr, eRz, cRr, cRz, r);
    line(eRr, eRz, bottom + k * eRz, eRz);
    line(bottom + k * eRz, eRz, bottom + k * eLz, eLz);
    line(bottom + k * eLz, eLz, eLr, eLz);
    arc(eLr, eLz, lRr, lRz, cLr, cLz, r);
    line(lRr, lRz, lcr, lcz);
    return pieces;
}

std::vector<Piece> internalGroove(ThreadProfileKind kind, double R, double P, double outside, double surface,
                                  double& innerRadius) {
    if (kind == ThreadProfileKind::Metric60) {
        // ISO 68-1 nut: from the minor radius R - 5H/8 (crest flat P/4, so the groove is 3P/4 wide there)
        // out to the major radius (root flat P/8).
        const double H = std::sqrt(3.0) / 2 * P, t = std::tan(kPi / 6), rm = R - 5 * H / 8;
        const double bottom = 3 * P / 8 + outside * t;
        innerRadius = rm;
        return {{R, -P / 16, R, P / 16},
                {R, P / 16, rm - outside, bottom},
                {rm - outside, bottom, rm - outside, -bottom},
                {rm - outside, -bottom, R, -P / 16}};
    }
    // Whitworth and NPT are symmetric about the pitch line: the internal groove is where the external
    // thread's tooth is — the external groove mirrored about it.
    const double mid = R - (kind == ThreadProfileKind::Npt60 ? 0.8 : 0.640327) * P / 2;
    double inner = 0;
    std::vector<Piece> pieces = externalGroove(kind, R, P, outside, surface > 0.0 ? 2 * mid - surface : 0.0, inner);
    for (Piece& p : pieces) {
        p.ar = 2 * mid - p.ar;
        p.br = 2 * mid - p.br;
        if (p.arc) p.cr = 2 * mid - p.cr;
    }
    innerRadius = inner;
    return pieces;
}

// Splits a swept surface along the sweep at the given values of v (those inside its range); a plane (a
// groove's end) is left whole. ShapeUpgrade_FaceDivide initialises its tool afresh for every face, so the
// values go in here, after that.
class AlongSweep : public ShapeUpgrade_SplitSurface {
public:
    explicit AlongSweep(Handle(TColStd_HSequenceOfReal) values) : values_(std::move(values)) {}

    void Compute(const Standard_Boolean segment) override {
        ShapeUpgrade_SplitSurface::Compute(segment);
        if (mySurface.IsNull() || mySurface->IsKind(STANDARD_TYPE(Geom_Plane))) return;
        const double first = myVSplitValues->First(), last = myVSplitValues->Last(), margin = 1e-9 * (last - first);
        Handle(TColStd_HSequenceOfReal) v = new TColStd_HSequenceOfReal;
        v->Append(first);
        for (int i = 1; i <= values_->Length(); ++i)
            if (values_->Value(i) > first + margin && values_->Value(i) < last - margin) v->Append(values_->Value(i));
        v->Append(last);
        myVSplitValues = v;
        myNbResultingRow = myUSplitValues->Length() - 1;
        myNbResultingCol = myVSplitValues->Length() - 1;
        if (myNbResultingCol > 1) myStatus = ShapeExtend::EncodeStatus(ShapeExtend_DONE1);
    }

private:
    Handle(TColStd_HSequenceOfReal) values_;
};

// The cut against its definition, point by point: in the body before it and in a turn of the groove (by
// the profile, exactly) — taken; in the body and clear of the groove — left. OCCT's cut can come out
// valid and wrong (a groove that took nothing, a chunk left in one), which neither BRepCheck nor the
// volume taken catches in general. Sampled on a grid across groove and tooth at eight angles along the
// thread, points within 2 µm of the groove's surface or the body's skipped. The number wrong, the first
// described in `first`.
struct ThreadFrame {
    gp_Pnt origin;
    gp_Vec axis, x, y;
    bool rightHanded;
    double start, pitch, k, sweep; // groove centre's first position, the pitch, radial growth, angle swept
};

int wrongSamples(const TopoDS_Shape& before, const TopoDS_Shape& after, const std::vector<Piece>& profile,
                 const ThreadFrame& f, double major, double depth, int& checked, std::string& first) {
    // The profile as a polygon: arcs in 64 chords, within 1e-8 m of them at these radii.
    std::vector<std::pair<double, double>> poly;
    for (const Piece& piece : profile) {
        if (!piece.arc) {
            poly.emplace_back(piece.ar, piece.az);
            continue;
        }
        const double a = std::atan2(piece.az - piece.cz, piece.ar - piece.cr);
        const double span = std::remainder(std::atan2(piece.bz - piece.cz, piece.br - piece.cr) - a, 2 * kPi);
        for (int i = 0; i < 64; ++i)
            poly.emplace_back(piece.cr + piece.radius * std::cos(a + span * i / 64), piece.cz + piece.radius * std::sin(a + span * i / 64));
    }
    const auto inside = [&](double r, double z) {
        bool in = false;
        for (std::size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) {
            const auto [ri, zi] = poly[i];
            const auto [rj, zj] = poly[j];
            if ((zi > z) != (zj > z) && r < (rj - ri) * (z - zi) / (zj - zi) + ri) in = !in;
        }
        return in;
    };
    const auto clearance = [&](double r, double z) {
        double best = std::numeric_limits<double>::infinity();
        for (std::size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) {
            const double ar = poly[j].first, az = poly[j].second, dr = poly[i].first - ar, dz = poly[i].second - az;
            const double s = std::clamp(((r - ar) * dr + (z - az) * dz) / (dr * dr + dz * dz), 0.0, 1.0);
            best = std::min(best, std::hypot(r - ar - s * dr, z - az - s * dz));
        }
        return best;
    };
    constexpr double kClear = 2e-6;
    BRepClass3d_SolidClassifier was, now;
    was.Load(before);
    now.Load(after);
    // A point the classifier puts on the wrong side is asked again by the parity of rays cast from it in
    // three directions: BRepClass3d slips now and then (M8 internal: a point 0.2 mm inside a valid result
    // called outside, every ray crossing its boundary an odd number of times).
    IntCurvesFace_ShapeIntersector rays;
    bool raysLoaded = false;
    const auto insideByRays = [&](const gp_Pnt& q) {
        if (!raysLoaded) rays.Load(after, 1e-9), raysLoaded = true;
        int votes = 0;
        for (const gp_Dir& d : {gp_Dir(0.8, 0.36, 0.48), gp_Dir(-0.28, 0.96, 0.0), gp_Dir(0.0, -0.6, 0.8)}) {
            rays.Perform(gp_Lin(q, d), 0.0, 1e6);
            votes += rays.NbPnt() % 2;
        }
        return votes >= 2;
    };
    int wrong = 0;
    checked = 0;
    for (int i = 0; i < 8; ++i) {
        const double swept = f.sweep * (i + 0.5) / 8, advance = f.pitch * swept / (2 * kPi);
        const double psi = f.rightHanded ? swept : -swept;
        const gp_Vec out = f.x * std::cos(psi) + f.y * std::sin(psi);
        for (int a = 0; a < 5; ++a)
            for (int b = 0; b <= 5; ++b) {
                // Across a pitch (off the profile's symmetry) and from under the root to over the crest.
                const double zr = f.pitch * (-0.43 + 0.2 * a), rr = major - depth * (1.1 - 0.24 * b);
                bool groove = false, near = false;
                for (int m = -1; m <= 1; ++m) {
                    if (swept + 2 * kPi * m < 0 || swept + 2 * kPi * m > f.sweep) continue; // no such turn
                    const double r = rr - f.k * m * f.pitch, z = zr - m * f.pitch;
                    groove = groove || inside(r, z);
                    near = near || clearance(r, z) < kClear;
                }
                if (near) continue;
                const gp_Pnt q = f.origin.Translated(f.axis * (f.start + advance + zr) + out * (rr + f.k * advance));
                was.Perform(q, 1e-9);
                if (was.State() != TopAbs_IN) continue; // outside the body, or within its tolerance of the skin
                now.Perform(q, 1e-9);
                ++checked;
                if ((now.State() == TopAbs_IN) == groove && insideByRays(q) == groove) {
                    if (wrong++ == 0)
                        first = std::string(groove ? "металл в канавке" : "снят зуб") + " на витке " +
                                std::to_string(int(swept / (2 * kPi)) + 1);
                }
            }
    }
    return wrong;
}

} // namespace

cadnext::Result<ShapeHandle> OcctKernel::cutThread(const ShapeHandle& body, const ThreadCutParameters& p,
                                                   ThreadCutReport* report) {
    using R = cadnext::Result<ShapeHandle>;
    const TopoDS_Shape* target = findShape(body);
    if (!target) return R::fail({ErrorCode::NotFound, "тело для резьбы не найдено"});
    const double axisLength = std::hypot(p.axisDirection.x, p.axisDirection.y, p.axisDirection.z);
    if (!(p.pitch > 0) || !(p.majorDiameter > 2 * p.pitch) || !(p.length > 0) || !(axisLength > 0))
        return R::fail({ErrorCode::InvalidArgument, "резьба: неверные диаметр, шаг, длина или ось"});
    try {
        const double P = p.pitch, Rmaj = p.majorDiameter / 2;
        const gp_Dir axis(p.axisDirection.x, p.axisDirection.y, p.axisDirection.z);
        const gp_Pnt origin(p.axisOrigin.x, p.axisOrigin.y, p.axisOrigin.z);
        const gp_Ax3 frame(origin, axis);
        const gp_Vec A(axis);
        // The groove closed this far beyond the thread's diameter (into air), its turns staying clear.
        const double outside = (p.profile == ThreadProfileKind::Metric60 ? 0.05 : 0.02) * P;
        double inner = 0;
        const double k = p.taper / 2;
        const double depth = p.profile == ThreadProfileKind::Metric60 ? 5.0 / 8.0 * std::sqrt(3.0) / 2.0 * P
                             : p.profile == ThreadProfileKind::Npt60  ? 0.8 * P
                                                                      : 0.640327 * P;
        bool runOutAtStart = p.runOutAtStart, runOutAtEnd = p.runOutAtEnd;
        if (p.runOutWhereFree) {
            BRepClass3d_SolidClassifier classifier;
            classifier.Load(*target);
            const gp_Vec X0(frame.XDirection()), Y0(frame.YDirection());
            const auto airBeyond = [&](double s) {
                const double radius = Rmaj + k * (s - p.start) - depth / 2;
                for (int i = 0; i < 4; ++i) {
                    const double angle = kPi / 4 + i * kPi / 2;
                    classifier.Perform(origin.Translated(A * s + (X0 * std::cos(angle) + Y0 * std::sin(angle)) * radius), 1e-9);
                    if (classifier.State() != TopAbs_OUT) return false;
                }
                return true;
            };
            runOutAtStart = runOutAtStart || airBeyond(p.start - P / 2);
            runOutAtEnd = runOutAtEnd || airBeyond(p.start + p.length + P / 2);
        }
        // Where the groove's centre runs: within [start, start + length], or a pitch past an open end.
        const double first = p.start + (runOutAtStart ? -P : P / 2);
        const double last = p.start + p.length + (runOutAtEnd ? P : -P / 2);
        if (!(last > first)) return R::fail({ErrorCode::InvalidArgument, "резьба короче шага"});
        const double turns = (last - first) / P;
        // A taper thread: the profile moves out by k per unit of axial advance as it turns (screw motion
        // and a radial shift); drawn at the groove's first position, its radius there.
        const double Rfirst = Rmaj + k * (first - p.start);
        if (!(Rfirst > 2 * P) || !(Rmaj + k * (last - p.start) > 2 * P))
            return R::fail({ErrorCode::InvalidArgument, "резьба: конус сходится в точку на длине резьбы"});
        // The face the thread is cut on (ThreadCutParameters::surfaceDiameter), and where it is left in the
        // zone. A flat crest (metric, NPT) meets it square: it stays unless proud of the crest by more than
        // kProud, then is turned (bored) to the crest. A rounded crest (G, R, Rc) would touch it along the
        // whole thread, a contact OCCT's cut gets wrong (R1/2 on a blank at its major cone: valid, and
        // nothing of the groove in it): the face is kept kSeat inside the crest, turned (bored) there when
        // it stands higher — by kProud at least, never a thinner skin.
        const double crestAtStart = p.internal ? Rmaj - depth : Rmaj;
        const bool rounded = p.profile == ThreadProfileKind::Whitworth55;
        const double seat = !rounded ? crestAtStart : p.internal ? crestAtStart + kSeat : crestAtStart - kSeat;
        TopoDS_Shape work = *target;
        double surface = 0.0, trimmed = 0.0; // the face's radius at the groove's first position, after turning
        if (p.surfaceDiameter > 0.0) {
            const double Rs = p.surfaceDiameter / 2;
            const double above = p.internal ? seat - Rs : Rs - seat; // how far the face stands beyond its seat
            double level = Rs;
            if (rounded ? above > 1e-9 : above > kProud)
                level = !rounded ? seat : p.internal ? std::max(seat, Rs + kProud) : std::min(seat, Rs - kProud);
            if (level != Rs) {
                const double a0 = p.start - (runOutAtStart ? P : 0.0), a1 = p.start + p.length + (runOutAtEnd ? P : 0.0);
                const auto kept = [&](double s) { return level + k * (s - p.start); };
                const auto face = [&](double s) { return Rs + k * (s - p.start); };
                // External: from the level out a thread's depth past the face; internal: from a thread's depth
                // inside the face (half its radius at most) out to the level.
                const auto low = [&](double s) { return p.internal ? std::max(0.5 * face(s), face(s) - depth) : kept(s); };
                const auto high = [&](double s) { return p.internal ? kept(s) : face(s) + depth; };
                const gp_Vec X0(frame.XDirection());
                const auto at = [&](double r, double s) { return origin.Translated(X0 * r + A * s); };
                BRepBuilderAPI_MakePolygon section(at(low(a0), a0), at(high(a0), a0), at(high(a1), a1), at(low(a1), a1), true);
                const TopoDS_Shape band =
                    BRepPrimAPI_MakeRevol(BRepBuilderAPI_MakeFace(section.Wire(), true).Face(), gp_Ax1(origin, axis), 2 * kPi).Shape();
                BRepAlgoAPI_Cut turned(work, band);
                if (!turned.IsDone() || !BRepCheck_Analyzer(turned.Shape()).IsValid())
                    return R::fail({ErrorCode::KernelOperationFailed, std::string("резьба: не удалось ") +
                                                                          (p.internal ? "расточить" : "проточить") +
                                                                          " зону резьбы до её диаметра"});
                work = turned.Shape();
                trimmed = std::fabs(Rs - level);
            }
            surface = level + k * (first - p.start);
        }

        std::vector<Piece> profile;
        if (k == 0.0) {
            profile = p.internal ? internalGroove(p.profile, Rfirst, P, outside, surface, inner)
                                 : externalGroove(p.profile, Rfirst, P, outside, surface, inner);
        } else {
            if (p.profile == ThreadProfileKind::Metric60)
                return R::fail({ErrorCode::UnsupportedOperation, "коническая резьба метрического профиля не строится (конические — NPT и R)"});
            profile = taperGroove(p.profile, p.internal, Rfirst, P, k, outside, surface, inner);
            if (profile.empty()) return R::fail({ErrorCode::KernelOperationFailed, "резьба: профиль конической резьбы не построен"});
        }
        // The groove's neighbouring turns, a pitch apart, must stay clear of each other: a groove touching
        // itself is a solid OCCT's cut takes without complaint and gets wrong. The narrowest designed gap
        // is 3.2 µm (a Whitworth crest stopped 1e-8 m short, 28 threads per inch); under 1 µm the profile
        // has degenerated.
        {
            double lowest = std::numeric_limits<double>::infinity(), highest = -lowest;
            for (const Piece& piece : profile)
                for (int i = 0; i <= 64; ++i) {
                    double z = piece.az + (piece.bz - piece.az) * i / 64.0;
                    if (piece.arc) {
                        const double a = std::atan2(piece.az - piece.cz, piece.ar - piece.cr);
                        const double span = std::remainder(std::atan2(piece.bz - piece.cz, piece.br - piece.cr) - a, 2 * kPi);
                        z = piece.cz + piece.radius * std::sin(a + span * i / 64.0);
                    }
                    lowest = std::min(lowest, z);
                    highest = std::max(highest, z);
                }
            if (!(highest - lowest <= P - 1e-6))
                return R::fail({ErrorCode::KernelOperationFailed, "резьба: соседние витки канавки сходятся (профиль шире шага)"});
        }

        // OCCT's cut of a groove winding round a cylinder is fragile: for some angles at which the groove
        // begins it leaves faces it cannot orient (the NIST-like case of a thread leaving through an end
        // face worked at 137° and failed at 0°, 30° and 90°). The angle a cut thread begins at is not the
        // standard's: any is the same thread. So another is tried, a golden angle on each time.
        std::string failure;
        for (int attempt = 0; attempt < 8; ++attempt) {
            const double phase = attempt * 137.50776405 * kPi / 180;
            const gp_Vec X0(frame.XDirection()), Y0(frame.YDirection());
            const gp_Vec X = X0 * std::cos(phase) + Y0 * std::sin(phase), Y = A.Crossed(X);

            // The profile in the axial half-plane through X, at the groove centre's first position.
            const auto at = [&](double r, double z) { return origin.Translated(X * r + A * (first + z)); };
            BRepBuilderAPI_MakeWire wire;
            for (const Piece& piece : profile) {
                if (!piece.arc) {
                    wire.Add(BRepBuilderAPI_MakeEdge(at(piece.ar, piece.az), at(piece.br, piece.bz)).Edge());
                } else {
                    const double mr = (piece.ar + piece.br) / 2, mz = (piece.az + piece.bz) / 2;
                    const double n = std::hypot(mr - piece.cr, mz - piece.cz);
                    const gp_Pnt middle = at(piece.cr + (mr - piece.cr) / n * piece.radius, piece.cz + (mz - piece.cz) / n * piece.radius);
                    const GC_MakeArcOfCircle arc(at(piece.ar, piece.az), middle, at(piece.br, piece.bz));
                    wire.Add(BRepBuilderAPI_MakeEdge(arc.Value()).Edge());
                }
                if (!wire.IsDone()) return R::fail({ErrorCode::KernelOperationFailed, "резьба: профиль не замкнут"});
            }

            // The helix the groove follows: angle and axial position on a cylinder about the axis; its
            // sense gives the hand (right: advancing along the axis while turning counter-clockwise about it).
            // A taper thread's helix lies on a cone: its generatrix v (the radius growing by sin α, the axial
            // position by cos α along it, tan α = k) advances P / cos α a turn.
            TopoDS_Edge helix;
            if (k == 0.0) {
                Handle(Geom_CylindricalSurface) cylinder = new Geom_CylindricalSurface(gp_Ax3(origin, axis, gp_Dir(X)), Rmaj);
                const gp_Dir2d direction(p.rightHanded ? 2 * kPi : -2 * kPi, P);
                Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, first), direction);
                helix = BRepBuilderAPI_MakeEdge(line, cylinder, 0.0, turns * std::hypot(2 * kPi, P));
            } else {
                const double alpha = std::atan(k), advance = P / std::cos(alpha);
                Handle(Geom_ConicalSurface) cone =
                    new Geom_ConicalSurface(gp_Ax3(origin.Translated(A * first), axis, gp_Dir(X)), alpha, Rfirst);
                const gp_Dir2d direction(p.rightHanded ? 2 * kPi : -2 * kPi, advance);
                Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, 0), direction);
                helix = BRepBuilderAPI_MakeEdge(line, cone, 0.0, turns * std::hypot(2 * kPi, advance));
            }
            BRepLib::BuildCurves3d(helix, kTarget, GeomAbs_C2, 14, 1000);
            BRepOffsetAPI_MakePipeShell pipe(BRepBuilderAPI_MakeWire(helix).Wire());
            pipe.SetMode(axis); // fixed binormal: the frames along a helix differ by the screw motion alone
            pipe.SetTolerance(kTarget, kTarget, 1e-4);
            pipe.Add(wire.Wire(), false, false);
            pipe.Build();
            if (!pipe.IsDone() || !pipe.MakeSolid()) {
                failure = "резьба: канавка не построена";
                continue;
            }
            const TopoDS_Shape groove = pipe.Shape();

            // The built groove against its definition: sampled points of its swept faces, carried back by
            // the screw motion to the first profile plane, must lie on the profile.
            double worst = 0.0;
            for (TopExp_Explorer f(groove, TopAbs_FACE); f.More(); f.Next()) {
                const TopoDS_Face face = TopoDS::Face(f.Current());
                const BRepAdaptor_Surface surface(face);
                if (surface.GetType() == GeomAbs_Plane) continue; // the end caps: the profile itself
                double u0, u1, v0, v1;
                BRepTools::UVBounds(face, u0, u1, v0, v1);
                for (int i = 0; i <= 24; ++i)
                    for (int j = 0; j <= 24; ++j) {
                        const gp_Pnt2d uv(u0 + (u1 - u0) * i / 24.0, v0 + (v1 - v0) * j / 24.0);
                        if (BRepClass_FaceClassifier(face, uv, 1e-9).State() == TopAbs_OUT) continue;
                        const gp_Vec q(origin, surface.Value(uv.X(), uv.Y()));
                        const double s = q.Dot(A), x = q.Dot(X), y = q.Dot(Y);
                        double theta = std::atan2(y, x);
                        if (!p.rightHanded) theta = -theta;
                        if (theta < 0) theta += 2 * kPi;
                        // Back by the whole advance, turns included: a taper thread's radius depends on it.
                        double advance = P * theta / (2 * kPi);
                        advance += P * std::round((s - first - advance) / P);
                        const double z = s - first - advance;
                        const double rho = std::hypot(x, y) - k * advance;
                        double d = std::numeric_limits<double>::infinity();
                        for (const Piece& piece : profile) d = std::min(d, distanceTo(piece, rho, z));
                        worst = std::max(worst, d);
                    }
            }
            if (!(worst <= kLimit))
                return R::fail({ErrorCode::KernelOperationFailed,
                                "резьба: витки отходят от профиля на " + std::to_string(worst) + " м"});

            // A swept face winding the whole thread meets the body along helices as long, which OCCT's cut
            // gets wrong while the result passes BRepCheck (M8 on 20 mm run out at the end, 16.5 turns:
            // nothing taken at any of eight angles; the same groove in a body 5 mm longer: 0.4 % of it). Cut
            // along the sweep at every turn — the surfaces themselves unchanged — it came out right each time,
            // in 0.5 s instead of 22.
            TopoDS_Shape tool = groove;
            if (const int pieces = int(std::ceil(turns)); pieces > 1) {
                double v0 = std::numeric_limits<double>::infinity(), v1 = -v0;
                int swept = 0;
                for (TopExp_Explorer f(groove, TopAbs_FACE); f.More(); f.Next()) {
                    const TopoDS_Face face = TopoDS::Face(f.Current());
                    if (BRepAdaptor_Surface(face).GetType() == GeomAbs_Plane) continue;
                    double u0, u1, a, b;
                    BRepTools::UVBounds(face, u0, u1, a, b); // v runs along the sweep
                    v0 = std::min(v0, a);
                    v1 = std::max(v1, b);
                    ++swept;
                }
                Handle(TColStd_HSequenceOfReal) values = new TColStd_HSequenceOfReal;
                for (int i = 1; i < pieces; ++i) values->Append(v0 + (v1 - v0) * i / pieces);
                Handle(ShapeUpgrade_FaceDivide) faceTool = new ShapeUpgrade_FaceDivide;
                faceTool->SetSplitSurfaceTool(new AlongSweep(values));
                ShapeUpgrade_ShapeDivide divide(groove);
                divide.SetSplitFaceTool(faceTool);
                divide.Perform();
                int split = 0;
                for (TopExp_Explorer f(divide.Result(), TopAbs_FACE); f.More(); f.Next())
                    if (BRepAdaptor_Surface(TopoDS::Face(f.Current())).GetType() != GeomAbs_Plane) ++split;
                if (split < swept * pieces) {
                    failure = "резьба: грани канавки не разрезались по виткам";
                    continue;
                }
                tool = divide.Result();
            }
            BRepAlgoAPI_Cut cut(work, tool);
            if (!cut.IsDone()) {
                failure = "резьба: вырез не удался";
                continue;
            }
            const TopoDS_Shape threaded = cut.Shape();
            if (const BRepCheck_Analyzer check(threaded); !check.IsValid()) {
                // Which sub-shapes and why, for the reason if no angle works.
                std::string detail;
                for (const TopAbs_ShapeEnum kind : {TopAbs_SOLID, TopAbs_SHELL, TopAbs_FACE, TopAbs_WIRE, TopAbs_EDGE, TopAbs_VERTEX})
                    for (TopExp_Explorer it(threaded, kind); it.More() && detail.size() < 300; it.Next()) {
                        const Handle(BRepCheck_Result)& result = check.Result(it.Current());
                        if (result.IsNull()) continue;
                        for (const BRepCheck_Status status : result->Status())
                            if (status != BRepCheck_NoError) detail += " " + std::to_string(int(kind)) + ":" + std::to_string(int(status));
                    }
                failure = "резьба: тело после выреза неверно (" + detail + ")";
                continue;
            }
            // A sanity net for what BRepCheck passes but is wrong (a rounded crest tangent to a taper body
            // all along: valid, yet 2.4 times the groove taken away): the cut can take no more than the
            // groove, and must take something. 0.1 % plus the body's own integration noise, for gross
            // failures only — the thread's accuracy is the profile check above.
            {
                GProp_GProps before, after, tool;
                BRepGProp::VolumeProperties(work, before, true);
                BRepGProp::VolumeProperties(threaded, after, true);
                BRepGProp::VolumeProperties(groove, tool, true);
                const double removed = before.Mass() - after.Mass();
                if (!(removed > 0.0) || removed > 1.001 * tool.Mass() + 1e-7 * std::fabs(before.Mass())) {
                    failure = removed > 0.0 ? "резьба: вырез снял больше самой канавки (" + std::to_string(removed) + " против " +
                                                  std::to_string(tool.Mass()) + " м3)"
                                            : "резьба не пересекает тело";
                    continue;
                }
            }
            {
                const ThreadFrame f{origin, A, X, Y, p.rightHanded, first, P, k, 2 * kPi * turns};
                int checked = 0;
                std::string where;
                const int wrong = wrongSamples(work, threaded, profile, f, Rfirst, depth, checked, where);
                if (wrong > 0 || checked == 0) {
                    failure = checked == 0 ? "резьба: проверить вырез не по чему (ни одной точки в теле)"
                                           : "резьба: вырез неверен в " + std::to_string(wrong) + " точках из " +
                                                 std::to_string(checked) + " (" + where + ")";
                    continue;
                }
            }
            if (report) {
                report->deviation = worst;
                report->turns = int(std::ceil(turns));
                report->attempts = attempt + 1;
                report->trimmed = trimmed;
            }
            return R::ok(adoptShape(threaded, "occt-thread"));
        }
        return R::fail({ErrorCode::ShapeInvalid, failure + ", при восьми углах начала витков"});
    } catch (const Standard_Failure& failure) {
        return R::fail({ErrorCode::KernelOperationFailed, std::string("резьба: ") + failure.GetMessageString()});
    }
}

std::array<bool, 2> OcctKernel::faceEndsFree(const ShapeHandle& body, const cadnext::Vector3& axisOrigin,
                                             const cadnext::Vector3& axisDirection, double radius, double slope,
                                             double axialStart, double axialEnd, bool holeWall) const {
    std::array<bool, 2> free{false, false};
    const TopoDS_Shape* shape = const_cast<OcctKernel*>(this)->findShape(body);
    const double norm = std::hypot(axisDirection.x, axisDirection.y, axisDirection.z);
    if (!shape || !(norm > 0.0) || !(radius > 0.0)) return free;
    try {
        const gp_Ax3 frame(gp_Pnt(axisOrigin.x, axisOrigin.y, axisOrigin.z),
                           gp_Dir(axisDirection.x / norm, axisDirection.y / norm, axisDirection.z / norm));
        const gp_Vec A(frame.Direction()), X(frame.XDirection()), Y(frame.YDirection());
        const double past = std::min(5e-4, 0.1 * (axialEnd - axialStart));
        BRepClass3d_SolidClassifier classifier;
        classifier.Load(*shape);
        for (int end = 0; end < 2; ++end) {
            const double s = end == 0 ? axialStart - past : axialEnd + past;
            const double at = (radius + slope * s) * (holeWall ? 1.05 : 0.95);
            bool air = true;
            for (int i = 0; i < 4 && air; ++i) {
                const double angle = kPi / 4 + i * kPi / 2;
                classifier.Perform(frame.Location().Translated(A * s + (X * std::cos(angle) + Y * std::sin(angle)) * at), 1e-9);
                air = classifier.State() == TopAbs_OUT;
            }
            free[end] = air;
        }
    } catch (const Standard_Failure&) {
    }
    return free;
}

} // namespace cadnext::kernel
#endif
