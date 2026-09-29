// Screw threads with real turns (OcctKernel::cutThread) against their definition.
//
// Criteria, fixed before the first run:
//   - The kernel's own measure: every sampled point of the swept faces, carried back by the thread's
//     motion to the first profile plane, within 1e-8 m of the profile — the build target.
//   - Volume, independently of the kernel's code. A planar region in an axial half-plane moved by the
//     screw motion through Θ, and out by k per unit of axial advance (a taper thread), fills exactly
//     Θ·M + A·k·(P/2π)·Θ²/2 — M its ∫ρ dA and A its area where it starts; the axial and radial parts
//     of the motion lie in its plane, the turns stay apart (Pappus, extended; k = 0 for a parallel
//     thread). The region is the groove's part inside the body, built here from each standard's rules —
//     ISO 68-1, ASME B1.1, ISO 228-1, ASME B1.20.1, ISO 7-1: flanks at their fixed angle to the
//     perpendicular of the axis, crossing the pitch line (cone) a quarter pitch either side of the
//     groove's centre; flats, or arcs tangent to the flanks — the arcs cut into 20 000 chords (within
//     1e-12 m), clipped by the body's surface, integrated by Green. The removed volume may differ from
//     it by at most the build target × the area of the new thread faces: no more than a surface within
//     1e-8 m of its definition can account for.
//   - The Whitworth crest is left flat within 1e-8 m of the major line (the kernel's stated
//     approximation, the build target); the exact rounded profile is used here. By Green that trim
//     accounts for 1e-14 m3 on G1/2, inside the bound. (At 1e-7 m it was not: the cut kept a layer that
//     thick along the crest arcs, 4e-11 m3 — found by this check.)
//   - A body not at the thread's crest: standing proud of a flat crest by more than 1 µm, or within 1 µm
//     of a rounded one, the zone is turned (bored) first, which adds the band between the two surfaces,
//     π(a² - b²) along the thread; lying under a rounded crest (1 µm, 10 µm), the thread must be right all
//     the same — a crest crossing or touching its blank at a glancing angle is a case OCCT's cut got wrong
//     while its result passed BRepCheck (R1/2, 1 µm under: a chunk left in the groove, 0.2 % of it; at
//     the major cone: nothing of the groove at all). Two cases are cut without telling the kernel the face.
//   - A parallel thread right through its body, run out at both ends (a stud, a nut): the groove inside is
//     a slab of the endless helical groove, L·2πM/P exactly; same bound. (Run out at the end, the groove
//     as one face per piece of profile took nothing at any angle — found here.)
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/ThreadCut.hpp"

#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepGProp.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <GProp_GProps.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Ax2.hxx>

#include <cmath>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

using namespace cadnext;
using namespace cadnext::kernel;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

constexpr double kPi = 3.14159265358979323846;
constexpr double kInch = 25.4e-3;

// A closed region in (ρ, z) as a polygon; arcs cut into chords.
struct Region {
    std::vector<std::pair<double, double>> points;
    void to(double r, double z) { points.emplace_back(r, z); }
    // From angle a to angle b round (cr, cz).
    void arc(double cr, double cz, double radius, double a, double b) {
        const int n = 20000;
        for (int i = 0; i <= n; ++i) {
            const double phi = a + (b - a) * i / n;
            to(cr + radius * std::cos(phi), cz + radius * std::sin(phi));
        }
    }
};

// Keeps the part of `region` where side·(ρ - k z - c) <= 0 (Sutherland–Hodgman, one edge).
Region clip(const Region& region, double k, double c, double side) {
    Region out;
    const auto f = [&](const std::pair<double, double>& p) { return side * (p.first - k * p.second - c); };
    const std::size_t n = region.points.size();
    for (std::size_t i = 0; i < n; ++i) {
        const auto& a = region.points[i];
        const auto& b = region.points[(i + 1) % n];
        const double fa = f(a), fb = f(b);
        if (fa <= 0) out.points.push_back(a);
        if ((fa < 0 && fb > 0) || (fa > 0 && fb < 0)) {
            const double t = fa / (fa - fb);
            out.points.emplace_back(a.first + t * (b.first - a.first), a.second + t * (b.second - a.second));
        }
    }
    return out;
}

// ∫ρ dA and the area of a polygon, by Green (∮ ρ²/2 dz, ∮ ρ dz).
void green(const Region& region, double& moment, double& area) {
    moment = area = 0;
    const std::size_t n = region.points.size();
    for (std::size_t i = 0; i < n; ++i) {
        const auto [r1, z1] = region.points[i];
        const auto [r2, z2] = region.points[(i + 1) % n];
        moment += (z2 - z1) / 6.0 * (r1 * r1 + r1 * r2 + r2 * r2);
        area += (z2 - z1) * (r1 + r2) / 2;
    }
    moment = std::fabs(moment);
    area = std::fabs(area);
}

// A line through (r, z) along (dr, dz).
struct Line2 {
    double r, z, dr, dz;
};

std::pair<double, double> meet(const Line2& a, const Line2& b) {
    const double det = -a.dr * b.dz + a.dz * b.dr;
    const double s = (-(b.r - a.r) * b.dz + (b.z - a.z) * b.dr) / det;
    return {a.r + s * a.dr, a.z + s * a.dz};
}

// Centre of the circle of `radius` tangent to a and b on the side of (qr, qz).
std::pair<double, double> tangentCentre(Line2 a, Line2 b, double radius, double qr, double qz) {
    for (Line2* l : {&a, &b}) {
        const double n = std::hypot(l->dr, l->dz);
        double nr = -l->dz / n, nz = l->dr / n;
        if ((qr - l->r) * nr + (qz - l->z) * nz < 0) nr = -nr, nz = -nz;
        l->r += radius * nr;
        l->z += radius * nz;
    }
    return meet(a, b);
}

// Where the circle round (cr, cz) touches l, as an angle round its centre.
double angleTo(double cr, double cz, const Line2& l) {
    const double t = ((cr - l.r) * l.dr + (cz - l.z) * l.dz) / (l.dr * l.dr + l.dz * l.dz);
    return std::atan2(l.z + t * l.dz - cz, l.r + t * l.dr - cr);
}

enum class Form { Metric, Npt, Whitworth };

// The groove of a thread in its first profile plane, its centre at z = 0; R the major radius there, k
// the radius's growth per unit of axial length. Open far outside (external) or far inside (internal)
// the body, which the caller clips it by. An internal thread's groove is the mating screw's tooth.
Region groove(Form form, bool internal, double R, double P, double k) {
    const double H = std::sqrt(3.0) / 2 * P;
    const double h = form == Form::Metric ? 5 * H / 8 : form == Form::Npt ? 0.8 * P : 0.640327 * P;
    const double t = std::tan(form == Form::Whitworth ? 27.5 * kPi / 180 : kPi / 6);
    // The pitch line: 3H/8 under the major line in ISO 68-1; midway between crest and root in the
    // others, their truncations (or arcs) being equal.
    const double pitch = form == Form::Metric ? R - 3 * H / 8 : R - h / 2;
    const double far = 5 * P;
    // The flanks cross the pitch cone at z = ∓P/4; the groove widens outward (external), the screw's
    // tooth inward (internal).
    const double s = internal ? 1.0 : -1.0;
    const Line2 left{pitch - k * P / 4, -P / 4, 1, s * t}, right{pitch + k * P / 4, P / 4, 1, -s * t};
    const auto cone = [&](double base) { return Line2{base, 0, k, 1}; };
    Region g;
    if (form != Form::Whitworth) {
        // Flats on cones parallel to the pitch cone: the external root h under the major line (ISO 68-1:
        // P/4 wide), the internal at the major line (ISO 68-1: P/8 wide).
        const Line2 floor = cone(internal ? R : R - h), open = cone(internal ? R - h - far : R + far);
        for (const auto& p : {meet(left, floor), meet(right, floor), meet(right, open), meet(left, open)}) g.to(p.first, p.second);
        return g;
    }
    // ISO 228-1 / ISO 7-1: arcs r = 0.137329P (parallel) or 0.137278P (taper) tangent to the flanks;
    // the neighbouring turns' flanks shifted by (±kP, ±P).
    const double r = (k == 0 ? 0.137329 : 0.137278) * P;
    const Line2 nextLeft{left.r + k * P, left.z + P, left.dr, left.dz};
    const Line2 lastRight{right.r - k * P, right.z - P, right.dr, right.dz};
    const auto [c0r, c0z] = tangentCentre(left, right, r, pitch, 0);
    const auto [cRr, cRz] = tangentCentre(right, nextLeft, r, pitch + k * P / 2, P / 2);
    const auto [cLr, cLz] = tangentCentre(left, lastRight, r, pitch - k * P / 2, -P / 2);
    const double a0L = angleTo(c0r, c0z, left), a0R = angleTo(c0r, c0z, right);
    const double aR = angleTo(cRr, cRz, right), aL = angleTo(cLr, cLz, left);
    const auto sweep = [](double from, double to) { return from + std::remainder(to - from, 2 * kPi); };
    // From the neighbouring arc at z = P/2, at its point farthest into the open side, along the right
    // flank, round the arc at z = 0, along the left flank to the neighbouring arc at -P/2 and its
    // farthest point; closed far into the open side.
    const double open = internal ? kPi : 0.0, reach = internal ? -r - far : r + far;
    g.arc(cRr, cRz, r, open, sweep(open, aR));
    g.arc(c0r, c0z, r, a0R, sweep(a0R, a0L));
    g.arc(cLr, cLz, r, aL, sweep(aL, open));
    g.to(cLr + reach, cLz);
    g.to(cRr + reach, cRz);
    return g;
}

double sweptFaceArea(const TopoDS_Shape& shape) {
    double area = 0.0;
    for (TopExp_Explorer f(shape, TopAbs_FACE); f.More(); f.Next()) {
        const BRepAdaptor_Surface surface(TopoDS::Face(f.Current()));
        if (surface.GetType() != GeomAbs_BSplineSurface) continue;
        GProp_GProps props;
        BRepGProp::SurfaceProperties(f.Current(), props);
        area += props.Mass();
    }
    return area;
}

double volumeOf(const TopoDS_Shape& shape) {
    GProp_GProps props;
    BRepGProp::VolumeProperties(shape, props, 1e-12, true);
    return props.Mass();
}

struct Case {
    std::string name;
    Form form;
    bool internal, rightHanded;
    double major, pitch, taper; // the major diameter at the thread's start
    // The body's surface at the thread's start: the blank's radius (external) or the hole's (internal).
    double bodyRadius;
    bool mayRefuse = false;
    bool surfaceKnown = true; // the kernel told the face's diameter (ThreadCutParameters::surfaceDiameter)
};

void run(const Case& c) {
    OcctKernel kernel;
    const double length = 30e-3, start = 5e-3, threadLength = 20e-3, k = c.taper / 2;
    // The body along +z from the origin, its surface a cylinder or a cone of slope k.
    const double atZero = c.bodyRadius - k * start, atEnd = atZero + k * length;
    TopoDS_Shape solid;
    if (!c.internal) {
        solid = k == 0 ? BRepPrimAPI_MakeCylinder(gp_Ax2(gp::Origin(), gp::DZ()), atZero, length).Shape()
                       : BRepPrimAPI_MakeCone(gp_Ax2(gp::Origin(), gp::DZ()), atZero, atEnd, length).Shape();
    } else {
        const double side = 4 * c.major, extra = 1e-3;
        const TopoDS_Shape block = BRepPrimAPI_MakeBox(gp_Pnt(-side / 2, -side / 2, 0), side, side, length).Shape();
        const gp_Ax2 axis(gp_Pnt(0, 0, -extra), gp::DZ());
        const TopoDS_Shape hole =
            k == 0 ? BRepPrimAPI_MakeCylinder(axis, atZero, length + 2 * extra).Shape()
                   : BRepPrimAPI_MakeCone(axis, atZero - k * extra, atEnd + k * extra, length + 2 * extra).Shape();
        solid = BRepAlgoAPI_Cut(block, hole).Shape();
    }
    const ShapeHandle body = kernel.adoptShape(solid, "test-body");
    ThreadCutParameters p;
    p.axisOrigin = {0, 0, 0};
    p.axisDirection = {0, 0, 1};
    p.start = start;
    p.length = threadLength;
    p.majorDiameter = c.major;
    p.pitch = c.pitch;
    p.profile = c.form == Form::Metric ? ThreadProfileKind::Metric60
              : c.form == Form::Npt    ? ThreadProfileKind::Npt60
                                       : ThreadProfileKind::Whitworth55;
    p.internal = c.internal;
    p.rightHanded = c.rightHanded;
    p.taper = c.taper;
    if (c.surfaceKnown) p.surfaceDiameter = 2 * c.bodyRadius;
    ThreadCutReport report;
    const auto threaded = kernel.cutThread(body, p, &report);
    if (c.mayRefuse && !threaded.isOk()) {
        check(true, c.name + ": отказ — " + threaded.error().message);
        return;
    }
    check(threaded.isOk() && kernel.isShapeValid(threaded.value()),
          c.name + ": резьба построена, тело верно" + (threaded.isOk() ? "" : " — " + threaded.error().message));
    if (!threaded.isOk()) return;
    const TopoDS_Shape& b = *kernel.findShape(threaded.value());
    const double removed = volumeOf(solid) - volumeOf(b);
    const double P = c.pitch, theta = 2 * kPi * (threadLength - P) / P;
    // A face standing proud of the crest (the major, or an internal thread's minor) by more than 1 µm is
    // turned (bored) to it over the thread's length first: the band between the two, π(a² - b²) summed
    // along it.
    const double depth = c.form == Form::Metric ? 5.0 / 8 * std::sqrt(3.0) / 2 * P : c.form == Form::Npt ? 0.8 * P : 0.640327 * P;
    // A rounded crest (G, R, Rc) keeps the face 1 µm inside it: turned (bored) there if higher, by 1 µm
    // at least (ThreadCut.hpp).
    const double crest = c.internal ? c.major / 2 - depth : c.major / 2;
    const bool rounded = c.form == Form::Whitworth;
    const double seat = !rounded ? crest : c.internal ? crest + 1e-6 : crest - 1e-6;
    const double above = c.internal ? seat - c.bodyRadius : c.bodyRadius - seat;
    double surface = c.bodyRadius;
    if (c.surfaceKnown && (rounded ? above > 1e-9 : above > 1e-6))
        surface = !rounded ? seat : c.internal ? std::max(seat, c.bodyRadius + 1e-6) : std::min(seat, c.bodyRadius - 1e-6);
    const double proud = std::fabs(c.bodyRadius - surface);
    const bool turned = proud > 0.0;
    const double band = kPi * proud * ((surface + c.bodyRadius) * threadLength + k * threadLength * threadLength);
    // The groove's centre runs from start + P/2 to start + length - P/2 (ThreadCut.hpp).
    const Region inside =
        clip(groove(c.form, c.internal, c.major / 2 + k * P / 2, P, k), k, surface + k * P / 2, c.internal ? -1.0 : 1.0);
    double moment = 0, area = 0;
    green(inside, moment, area);
    const double expected = band + theta * moment + area * k * P / (2 * kPi) * theta * theta / 2;
    check(std::fabs(report.trimmed - (turned ? proud : 0.0)) <= 1e-12,
          c.name + (turned ? ": зона проточена (расточена) на свой припуск" : ": зона не протачивалась"));
    const double bound = 1e-8 * sweptFaceArea(b);
    std::printf("  %s: отклонение витков %.3g м, попыток %d; снято %.12g м3, по формуле %.12g, разница %.3g м3 (граница %.3g)\n",
                c.name.c_str(), report.deviation, report.attempts, removed, expected, removed - expected, bound);
    check(report.deviation <= 1e-8, c.name + ": витки в 1e-8 м от профиля (самопроверка ядра)");
    check(std::fabs(removed - expected) <= bound, c.name + ": снятый объём по формуле — в пределах 1e-8 м × площадь витков");
}

// A parallel thread right through its body, run out at both ends (a fully threaded stud, a nut): the
// groove's part inside is a slab of the endless helical groove, which the screw motion carries onto
// itself — L·2πM/P for a slab L thick, M the ∫ρ dA of the groove inside the body.
void runThrough(const Case& c) {
    OcctKernel kernel;
    const double length = 12e-3, P = c.pitch;
    TopoDS_Shape solid;
    if (!c.internal) {
        solid = BRepPrimAPI_MakeCylinder(gp_Ax2(gp::Origin(), gp::DZ()), c.bodyRadius, length).Shape();
    } else {
        const double side = 4 * c.major;
        solid = BRepAlgoAPI_Cut(BRepPrimAPI_MakeBox(gp_Pnt(-side / 2, -side / 2, 0), side, side, length).Shape(),
                                BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, -1e-3), gp::DZ()), c.bodyRadius, length + 2e-3).Shape())
                    .Shape();
    }
    const ShapeHandle body = kernel.adoptShape(solid, "through");
    ThreadCutParameters p;
    p.axisOrigin = {0, 0, 0};
    p.axisDirection = {0, 0, 1};
    p.start = 0;
    p.length = length;
    p.majorDiameter = c.major;
    p.pitch = P;
    p.profile = c.form == Form::Metric ? ThreadProfileKind::Metric60 : ThreadProfileKind::Whitworth55;
    p.internal = c.internal;
    p.rightHanded = c.rightHanded;
    p.surfaceDiameter = 2 * c.bodyRadius;
    p.runOutWhereFree = true; // both ends are air
    ThreadCutReport report;
    const auto threaded = kernel.cutThread(body, p, &report);
    check(threaded.isOk() && kernel.isShapeValid(threaded.value()),
          c.name + ": резьба построена, тело верно" + (threaded.isOk() ? "" : " — " + threaded.error().message));
    if (!threaded.isOk()) return;
    const TopoDS_Shape& b = *kernel.findShape(threaded.value());
    const double removed = volumeOf(solid) - volumeOf(b);
    // The face as the kernel keeps it: a rounded crest 1 µm inside it (ThreadCut.hpp); these bodies sit at
    // the crest, so turned by that.
    const double depth = c.form == Form::Metric ? 5.0 / 8 * std::sqrt(3.0) / 2 * P : 0.640327 * P;
    const double crest = c.internal ? c.major / 2 - depth : c.major / 2;
    const bool rounded = c.form == Form::Whitworth;
    const double surface = !rounded ? c.bodyRadius : c.internal ? std::max(crest + 1e-6, c.bodyRadius) : std::min(crest - 1e-6, c.bodyRadius);
    const double band = kPi * std::fabs(c.bodyRadius - surface) * (surface + c.bodyRadius) * length;
    double moment = 0, area = 0;
    green(clip(groove(c.form, c.internal, c.major / 2, P, 0), 0, surface, c.internal ? -1.0 : 1.0), moment, area);
    const double expected = band + length * 2 * kPi * moment / P;
    const double bound = 1e-8 * sweptFaceArea(b);
    std::printf("  %s: отклонение витков %.3g м, попыток %d; снято %.12g м3, по формуле %.12g, разница %.3g м3 (граница %.3g)\n",
                c.name.c_str(), report.deviation, report.attempts, removed, expected, removed - expected, bound);
    check(report.deviation <= 1e-8, c.name + ": витки в 1e-8 м от профиля (самопроверка ядра)");
    check(std::fabs(removed - expected) <= bound, c.name + ": снятый объём по формуле — в пределах 1e-8 м × площадь витков");
}

} // namespace

int main(int argc, char** argv) {
    const double H8 = std::sqrt(3.0) / 2 * 1.25e-3;
    // 1/2 NPT (ASME B1.20.1): E0 = D - (0.05D + 1.1)p at the small end, the major line 0.4p above it.
    const double nptD = 0.840, nptP = kInch / 14, e0 = (nptD - (0.05 * nptD + 1.1) / 14) * kInch;
    const double nptMajor = e0 + 0.8 * nptP;
    // R1/2 (ISO 7-1): the major diameter 20.955 mm at the gauge plane, 8.2 mm from the small end.
    const double rMajor = 20.955e-3 - 8.2e-3 / 16, rP = kInch / 14, rH = 0.640327 * rP;
    const std::vector<Case> cases{
        {"M8×1,25 наружная", Form::Metric, false, true, 8e-3, 1.25e-3, 0, 4e-3},
        {"M8×1,25 наружная левая, поверхность не задана", Form::Metric, false, false, 8e-3, 1.25e-3, 0, 4e-3, false, false},
        {"M8×1,25 внутренняя", Form::Metric, true, true, 8e-3, 1.25e-3, 0, 4e-3 - 5 * H8 / 8},
        {"1/4-20 UNC наружная", Form::Metric, false, true, 0.25 * kInch, kInch / 20, 0, 0.125 * kInch},
        {"G1/2 наружная", Form::Whitworth, false, true, 20.955e-3, kInch / 14, 0, 20.955e-3 / 2},
        {"G1/8 наружная, поверхность не задана", Form::Whitworth, false, true, 9.728e-3, kInch / 28, 0, 9.728e-3 / 2, false, false},
        {"G1 внутренняя", Form::Whitworth, true, true, 33.249e-3, kInch / 11, 0, 33.249e-3 / 2 - 0.640327 * kInch / 11},
        {"1/2 NPT наружная", Form::Npt, false, true, nptMajor, nptP, 1.0 / 16, nptMajor / 2},
        {"1/2 NPT внутренняя", Form::Npt, true, true, nptMajor, nptP, 1.0 / 16, nptMajor / 2 - 0.8 * nptP},
        {"R1/2 наружная, заготовка на 1 мкм ниже вершин", Form::Whitworth, false, true, rMajor, rP, 1.0 / 16, rMajor / 2 - 1e-6},
        {"Rc1/2 внутренняя, отверстие на 1 мкм шире", Form::Whitworth, true, true, rMajor, rP, 1.0 / 16, rMajor / 2 - rH + 1e-6},
        {"R1/2 наружная, заготовка точно по вершинам", Form::Whitworth, false, true, rMajor, rP, 1.0 / 16, rMajor / 2},
        {"M8×1,25 наружная, заготовка Ø8,2: проточка", Form::Metric, false, true, 8e-3, 1.25e-3, 0, 4.1e-3},
        {"G1/2 наружная, заготовка на 0,2 мм больше: проточка", Form::Whitworth, false, true, 20.955e-3, kInch / 14, 0,
         20.955e-3 / 2 + 0.1e-3},
        {"G1/2 наружная, заготовка на 10 мкм меньше", Form::Whitworth, false, true, 20.955e-3, kInch / 14, 0, 20.955e-3 / 2 - 10e-6},
        {"G1/2 наружная, заготовка на 1 мкм ниже вершин", Form::Whitworth, false, true, 20.955e-3, kInch / 14, 0, 20.955e-3 / 2 - 1e-6},
        {"G1 внутренняя, отверстие на 0,2 мм меньше: расточка", Form::Whitworth, true, true, 33.249e-3, kInch / 11, 0,
         33.249e-3 / 2 - 0.640327 * kInch / 11 - 0.1e-3},
        {"R1/2 наружная, заготовка на 0,1 мм больше: проточка", Form::Whitworth, false, true, rMajor, rP, 1.0 / 16, rMajor / 2 + 0.1e-3},
    };
    for (const Case& c : cases)
        if (argc < 2 || c.name.find(argv[1]) != std::string::npos) run(c);
    const std::vector<Case> through{
        {"M8 насквозь по валу 12 мм, выход через оба торца", Form::Metric, false, true, 8e-3, 1.25e-3, 0, 4e-3},
        {"M8 гайка: насквозь, выход через оба торца", Form::Metric, true, true, 8e-3, 1.25e-3, 0, 4e-3 - 5 * H8 / 8},
        {"G1 гайка: насквозь, выход через оба торца", Form::Whitworth, true, true, 33.249e-3, kInch / 11, 0,
         33.249e-3 / 2 - 0.640327 * kInch / 11},
    };
    for (const Case& c : through)
        if (argc < 2 || c.name.find(argv[1]) != std::string::npos) runThrough(c);
    if (argc > 1) return failures ? 1 : 0;

    // A thread leaving the body through its end face: valid, on its profile.
    {
        OcctKernel kernel;
        const ShapeHandle body =
            kernel.adoptShape(BRepPrimAPI_MakeCylinder(gp_Ax2(gp::Origin(), gp::DZ()), 4e-3, 20e-3).Shape(), "shaft");
        ThreadCutParameters p;
        p.axisOrigin = {0, 0, 0};
        p.axisDirection = {0, 0, 1};
        p.start = 0;
        p.length = 12e-3;
        p.majorDiameter = 8e-3;
        p.pitch = 1.25e-3;
        p.runOutAtStart = true;
        ThreadCutReport report;
        const auto threaded = kernel.cutThread(body, p, &report);
        check(threaded.isOk() && kernel.isShapeValid(threaded.value()) && report.deviation <= 1e-8,
              "M8 с выходом через торец: тело верно, витки в 1e-8 м" + (threaded.isOk() ? "" : " — " + threaded.error().message));
    }
    std::printf("%s: %d failures\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
