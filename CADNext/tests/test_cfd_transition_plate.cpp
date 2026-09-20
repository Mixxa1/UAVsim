// Transition model verification: incompressible flat plate with k-ω SST + Langtry–Menter γ-Reθ, the
// configuration the aerodynamic study writes for transition = "lm" (sustaining terms included).
//
//   cadnext_test_cfd_transition_plate <SU2_CFD> <work directory>
//
// U = 1, ρ = 1, plate from the leading edge to the outlet, 1 L of slip wall upstream (the Blasius
// test measured that 0.25 L upstream already bends the laminar layer by 1.6 %), freestream 0.2 L
// above. Two free-stream turbulence levels, each at the Reynolds number that puts the predicted onset
// near 0.3 L:
//   Tu = 1 %: Re_L = 2.5·10⁶ — the level of a quiet wind tunnel, the case the study is for;
//   Tu = 3 %: Re_L = 2.5·10⁵ — the level of the ERCOFTAC T3A plate the model was calibrated on.
// Each runs on two meshes of one family, the second 1.5 times finer in both directions.
//
// What the model is supposed to do, from its own correlations (read from SU2's source, not from
// memory: trans_sources.hpp and trans_correlations.hpp): the free stream carries
//   Re_θt(Tu) = 1173.51 − 589.428 Tu + 0.2196/Tu²      Tu ≤ 1.3 %
//             = 331.5 (Tu − 0.5658)^−0.671             Tu > 1.3 %
// — the empirical momentum-thickness Reynolds number at which a zero-pressure-gradient layer starts
// transition — and intermittency begins to grow once the layer passes Re_θc(Re_θt), a smaller value
// (MENTER_LANGTRY correlation). So the laminar layer must stay Blasius until Re_θc, and friction must
// start rising (its minimum) between Re_θc and about Re_θt.
//
// Criteria, stated before the runs:
//   1. Tu at the leading edge, outside the layer, within 5 % of the value set. Without sustaining
//      terms k decays on its way from the inlet and the layer would transition on a different Tu.
//   2. Laminar part: at the station where the measured Re_θ is about half of Re_θc, cf√Re_x within
//      5 % of Blasius (0.66412). The solver itself is verified to 0.5 % on laminar Blasius; the rest
//      allows for free-stream turbulence reaching into a laminar layer, which is physical.
//   3. Onset: Re_θ at the friction minimum between Re_θc and 1.15 Re_θt, widened by the difference
//      between the two meshes. 15 %: the length over which γ has to rise before friction turns.
// Changed 2026-09-19 by the user's decision to judge transition against experiment instead of the
// model's own correlation: criterion 3 is printed, not judged — cadnext_test_cfd_t3a compares where the
// layer transitions with the ERCOFTAC T3A/T3A− measurements — and criterion 2 is judged at Tu = 1 %
// only (that the model keeps a quiet layer laminar at all); at Tu = 3 % the laminar friction is judged
// against the T3A measurement there. Both findings stay recorded: the model's friction minimum sat at
// 1.25–1.31 Re_θt here, and T3A shows transition earlier than measured and laminar friction 10–15 %
// high.
//   4. Turbulent part at x = 0.9 L, Tu = 1 % only: cf inside the band of the Coles–Fernholz and
//      Kármán–Schoenherr laws at the measured Re_θ, widened by 5 % for the relaxation of a layer that
//      transitioned recently. At Tu = 3 % the plate ends near Re_θ ≈ 600, below where those laws were
//      fitted, so there it is printed only.

#include "fea_test_support.hpp"

#include "cadnext/cfd/FlatPlate.hpp"
#include "cadnext/cfd/Su2Case.hpp"
#include "cadnext/cfd/WallResolution.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>

using namespace cadnext;
using namespace cadnext::cfd;
using fea_test::check;

namespace {

constexpr double kBlasius = 0.66412;

// SU2's correlations, as the model evaluates them (Tu in per cent, zero pressure gradient: f_λ = 1).
double reThetaT(double tuPercent) {
    const double tu = std::max(tuPercent, 0.027);
    return tu <= 1.3 ? 1173.51 - 589.428 * tu + 0.2196 / (tu * tu) : 331.5 * std::pow(tu - 0.5658, -0.671);
}
double reThetaC(double reThetaTValue) {
    const double r = reThetaTValue;
    if (r <= 1870.0)
        return -396.035e-2 + 10120.656e-4 * r - 868.230e-6 * r * r + 696.506e-9 * r * r * r - 174.105e-12 * r * r * r * r;
    return r - (593.11 + 0.482 * (r - 1870.0));
}

double colesFernholzSkinFriction(double reynoldsTheta) { return 2.0 / std::pow(std::log(reynoldsTheta) / 0.384 + 4.127, 2.0); }
double karmanSchoenherrSkinFriction(double reynoldsTheta) {
    const double l = std::log10(reynoldsTheta);
    return 1.0 / (17.08 * l * l + 25.11 * l + 6.012);
}
double outsideCorrelationBand(double skinFriction, double reynoldsTheta) {
    const double low = std::min(colesFernholzSkinFriction(reynoldsTheta), karmanSchoenherrSkinFriction(reynoldsTheta));
    const double high = std::max(colesFernholzSkinFriction(reynoldsTheta), karmanSchoenherrSkinFriction(reynoldsTheta));
    const double middle = 0.5 * (low + high);
    if (skinFriction < low) return (skinFriction - low) / middle;
    if (skinFriction > high) return (skinFriction - high) / middle;
    return 0.0;
}

Su2History tableOf(const std::filesystem::path& file) {
    std::ifstream stream(file);
    const auto parsed = parseSu2History({std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()});
    return parsed.isOk() ? parsed.value() : Su2History{};
}

Su2Config transitionPlate(double viscosity, double turbulenceIntensity) {
    Su2Config c;
    char mu[32], tu[32];
    std::snprintf(mu, sizeof mu, "%.6g", viscosity);
    std::snprintf(tu, sizeof tu, "%.6g", turbulenceIntensity);
    for (const auto& [key, value] : std::vector<std::pair<std::string, std::string>>{
             {"SOLVER", "INC_RANS"}, {"KIND_TURB_MODEL", "SST"}, {"SST_OPTIONS", "( V2003m, SUSTAINING )"},
             {"KIND_TRANS_MODEL", "LM"}, {"LM_OPTIONS", "( MENTER_LANGTRY )"}, {"MATH_PROBLEM", "DIRECT"},
             {"INC_DENSITY_MODEL", "CONSTANT"}, {"INC_DENSITY_INIT", "1.0"}, {"INC_VELOCITY_INIT", "( 1.0, 0.0, 0.0 )"},
             {"INC_ENERGY_EQUATION", "NO"}, {"VISCOSITY_MODEL", "CONSTANT_VISCOSITY"}, {"MU_CONSTANT", mu},
             {"FREESTREAM_TURBULENCEINTENSITY", tu}, {"FREESTREAM_TURB2LAMVISCRATIO", "10"},
             {"INC_INLET_TYPE", "VELOCITY_INLET"}, {"MARKER_INLET", "( inlet, 0.0, 1.0, 1.0, 0.0, 0.0 )"},
             {"INC_OUTLET_TYPE", "PRESSURE_OUTLET"}, {"MARKER_OUTLET", "( outlet, 0.0 )"},
             {"MARKER_HEATFLUX", "( wall, 0.0 )"}, {"MARKER_SYM", "( symmetry )"}, {"MARKER_FAR", "( farfield )"},
             {"MARKER_PLOTTING", "( wall )"}, {"MARKER_MONITORING", "( wall )"}, {"REF_LENGTH", "1.0"}, {"REF_AREA", "1.0"},
             {"NUM_METHOD_GRAD", "GREEN_GAUSS"}, {"CONV_NUM_METHOD_FLOW", "FDS"}, {"MUSCL_FLOW", "YES"}, {"SLOPE_LIMITER_FLOW", "NONE"},
             {"TIME_DISCRE_FLOW", "EULER_IMPLICIT"}, {"CFL_NUMBER", "10"}, {"CFL_ADAPT", "YES"}, {"CFL_ADAPT_PARAM", "( 0.5, 1.5, 10.0, 1e3 )"},
             {"LINEAR_SOLVER", "FGMRES"}, {"LINEAR_SOLVER_PREC", "ILU"}, {"LINEAR_SOLVER_ERROR", "1E-4"}, {"LINEAR_SOLVER_ITER", "20"},
             {"ITER", "30000"}, {"CONV_FIELD", "RMS_PRESSURE"}, {"CONV_RESIDUAL_MINVAL", "-10"},
             {"HISTORY_OUTPUT", "( ITER, RMS_RES, AERO_COEFF )"}, {"OUTPUT_FILES", "( SURFACE_CSV, RESTART_ASCII )"},
             {"VOLUME_OUTPUT", "( COORDINATES, SOLUTION, PRIMITIVE )"}, {"WRT_RESTART_COMPACT", "NO"}, {"RESTART_FILENAME", "volume"},
             {"MESH_FILENAME", "mesh.su2"}, {"MESH_FORMAT", "SU2"}, {"TABULAR_FORMAT", "CSV"},
             {"CONV_FILENAME", "history"}, {"SURFACE_FILENAME", "surface"}}) {
        c.set(key, value);
    }
    return c;
}

// Wall friction along the plate, sorted by x.
std::vector<std::pair<double, double>> wallFriction(const Su2History& surface) {
    const int cx = surface.column("x"), cy = surface.column("y"), cf = surface.column("Skin_Friction_Coefficient_x");
    std::vector<std::pair<double, double>> wall;
    if (cx < 0 || cy < 0 || cf < 0) return wall;
    for (const auto& row : surface.rows)
        if (std::fabs(row[cy]) < 1e-12 && row[cx] > 0.0) wall.emplace_back(row[cx], row[cf]);
    std::sort(wall.begin(), wall.end());
    return wall;
}

double frictionAt(const std::vector<std::pair<double, double>>& wall, double x) {
    for (std::size_t i = 1; i < wall.size(); ++i)
        if (wall[i].first >= x) {
            const double t = (x - wall[i - 1].first) / (wall[i].first - wall[i - 1].first);
            return wall[i - 1].second + t * (wall[i].second - wall[i - 1].second);
        }
    return NAN;
}

// The column of mesh nodes nearest x (the mesh is structured, so a column shares one x), by height.
struct Column {
    std::vector<double> y, u, k;
};
Column columnAt(const Su2History& volume, double x) {
    const int cx = volume.column("x"), cy = volume.column("y"), cu = volume.column("Velocity_x"), ck = volume.column("Turb_Kin_Energy");
    Column out;
    if (cx < 0 || cy < 0 || cu < 0) return out;
    double nearest = std::numeric_limits<double>::infinity();
    for (const auto& row : volume.rows) nearest = std::min(nearest, std::fabs(row[cx] - x));
    std::vector<std::array<double, 3>> nodes;
    for (const auto& row : volume.rows)
        if (std::fabs(std::fabs(row[cx] - x) - nearest) < 1e-12) nodes.push_back({row[cy], row[cu], ck >= 0 ? row[ck] : NAN});
    std::sort(nodes.begin(), nodes.end());
    for (const auto& n : nodes) {
        out.y.push_back(n[0]);
        out.u.push_back(n[1]);
        out.k.push_back(n[2]);
    }
    return out;
}

// Against the local edge velocity (the plateau of the profile, below the top quarter of the domain)
// and only up to u = 0.999 U_e. Integrating u(1 − u) with U = 1 to the top of the domain — the first
// version, shared with the turbulent test — picked up the outer flow's 0.1–0.2 % deficit over 0.2 m
// and reported Re_θ 1064 for a laminar layer of 197.
double reynoldsTheta(const Column& column, double viscosity) {
    if (column.y.size() < 3) return NAN;
    double edge = 0.0;
    for (std::size_t i = 0; i < column.y.size(); ++i)
        if (column.y[i] <= 0.75 * column.y.back()) edge = std::max(edge, column.u[i]);
    double theta = 0.0;
    auto integrand = [edge](double u) { return u / edge * (1.0 - u / edge); };
    for (std::size_t i = 1; i < column.y.size(); ++i) {
        theta += 0.5 * (integrand(column.u[i - 1]) + integrand(column.u[i])) * (column.y[i] - column.y[i - 1]);
        if (column.u[i] >= 0.999 * edge) break;
    }
    return edge * theta / viscosity;
}

// Turbulence intensity outside the layer: at the node nearest y = 0.1 L.
double freeStreamIntensity(const Column& column) {
    std::size_t best = 0;
    for (std::size_t i = 0; i < column.y.size(); ++i)
        if (std::fabs(column.y[i] - 0.1) < std::fabs(column.y[best] - 0.1)) best = i;
    if (column.y.empty() || !std::isfinite(column.k[best])) return NAN;
    return std::sqrt(2.0 * column.k[best] / 3.0) / std::fabs(column.u[best]);
}

struct Outcome {
    bool complete = false;
    double tuLeadingEdge = NAN;              // fraction
    double laminarRatio = NAN;               // cf√Re_x / Blasius
    double laminarX = NAN;
    double laminarReThetaRatio = NAN;        // measured Re_θ / Blasius 0.664√Re_x: checks the instrument
    double onsetX = NAN, onsetReTheta = NAN; // friction minimum
    bool transitioned = false;
    double endSkinFriction = NAN, endReTheta = NAN;
    double dragCoefficient = NAN;            // friction drag of the whole plate, per unit span / (½ρU²L)
};

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::printf("usage: %s <SU2_CFD> <work directory>\n", argv[0]);
        return 64;
    }
    const std::string solver = argv[1];
    const std::filesystem::path work = argv[2];
    std::filesystem::remove_all(work);

    auto run = [&](const std::string& name, double reynolds, double tu, int plateCells, int normalCells) {
        Outcome out;
        const double viscosity = 1.0 / reynolds;
        const auto directory = work / name;
        std::filesystem::create_directories(directory);
        FlatPlateMeshSpec spec;
        spec.length = 1.0;
        spec.upstream = 1.0;
        spec.height = 0.2;
        spec.plateCells = plateCells;
        spec.upstreamCells = plateCells / 3;
        spec.normalCells = normalCells;
        spec.leadingEdgeStretch = 40.0;
        spec.upstreamStretch = 40.0;
        spec.wallStretch = 10000.0;
        const auto mesh = flatPlateMesh(spec);
        if (!mesh.write((directory / "mesh.su2").string())) {
            check(false, name + ": сетка записана");
            return out;
        }
        Su2RunControl control;
        control.timeoutSeconds = 3600;
        const auto result = runSu2(solver, directory.string(), transitionPlate(viscosity, tu), 4, control);
        if (!result.isOk()) {
            check(false, name + ": SU2 run", result.error().message);
            return out;
        }
        const auto& history = result.value().history;
        const bool reached = !history.rows.empty() && history.last("rms[P]") <= -10.0 + 1e-9;
        if (result.value().timedOut || result.value().exitStatus != 0) {
            check(false, name + ": SU2 отработал", result.value().timedOut ? "прервано по таймауту"
                                                                           : "код выхода " + std::to_string(result.value().exitStatus));
            return out;
        }
        check(reached, name + ": невязка давления дошла до 1e-10", "rms[P] = " + std::to_string(history.last("rms[P]")));

        const auto surface = tableOf(directory / "surface.csv");
        const auto volume = tableOf(directory / "volume.csv");
        const auto wall = wallFriction(surface);
        if (wall.size() < 10 || volume.rows.empty()) {
            check(false, name + ": поля содержат трение и профиль скорости");
            return out;
        }
        out.tuLeadingEdge = freeStreamIntensity(columnAt(volume, 0.0));
        const double rtt = reThetaT(100.0 * out.tuLeadingEdge), rtc = reThetaC(rtt);

        // Laminar station: Blasius Re_θ = 0.664 √Re_x at half of Re_θc.
        out.laminarX = std::pow(0.5 * rtc / kBlasius, 2.0) * viscosity;
        out.laminarRatio = frictionAt(wall, out.laminarX) * std::sqrt(out.laminarX / viscosity) / kBlasius;
        out.laminarReThetaRatio = reynoldsTheta(columnAt(volume, out.laminarX), viscosity) / (kBlasius * std::sqrt(out.laminarX / viscosity));

        // Onset: the friction minimum after the laminar station, and the rise after it. (The first
        // version took the peak first and the minimum before it; where friction is already creeping up
        // at the station, as under 3 % turbulence, the largest value was the station itself and a
        // transition to 2.8 times laminar friction went unseen.)
        std::size_t first = 0;
        while (first < wall.size() && wall[first].first < out.laminarX) ++first;
        std::size_t minimum = first;
        for (std::size_t i = first; i < wall.size() && wall[i].first <= 0.95; ++i)
            if (wall[i].second < wall[minimum].second) minimum = i;
        std::size_t peak = minimum;
        for (std::size_t i = minimum; i < wall.size(); ++i)
            if (wall[i].second > wall[peak].second) peak = i;
        out.transitioned = peak > minimum && wall[peak].second > 1.5 * wall[minimum].second;
        out.onsetX = wall[minimum].first;
        out.onsetReTheta = reynoldsTheta(columnAt(volume, out.onsetX), viscosity);

        out.endSkinFriction = frictionAt(wall, 0.9);
        out.endReTheta = reynoldsTheta(columnAt(volume, 0.9), viscosity);
        double drag = 0.0;
        for (std::size_t i = 1; i < wall.size(); ++i)
            drag += 0.5 * (wall[i - 1].second + wall[i].second) * (wall[i].first - wall[i - 1].first);
        out.dragCoefficient = drag;
        out.complete = true;

        std::printf("  %s: %zu ячеек, %zu итераций, rms[P] %.2f; Tu у кромки %.3f %% (Re_θt %.0f, Re_θc %.0f)\n"
                    "      ламинарный участок x = %.4f: cf√Re_x / Блазиус = %.4f, Re_θ / Блазиус = %.4f\n"
                    "      минимум трения x = %.3f, Re_θ = %.0f (%.2f Re_θt)%s\n"
                    "      x = 0.9: cf %.5f при Re_θ %.0f; трение всей пластины Cf %.5f (ламинар 1.328/√Re %.5f, турбулентный 0.074 Re^-0.2 %.5f)\n",
                    name.c_str(), mesh.elements.size(), history.rows.size(), history.last("rms[P]"), 100.0 * out.tuLeadingEdge, rtt, rtc,
                    out.laminarX, out.laminarRatio, out.laminarReThetaRatio, out.onsetX, out.onsetReTheta, out.onsetReTheta / rtt,
                    out.transitioned ? "" : " — роста трения за ним нет, перехода нет", out.endSkinFriction, out.endReTheta,
                    out.dragCoefficient, 1.328 / std::sqrt(reynolds), 0.074 * std::pow(reynolds, -0.2));
        return out;
    };

    struct Case {
        std::string name;
        double tu, reynolds;
        bool judgeTurbulentEnd;
    };
    for (const auto& c : std::vector<Case>{{"tu1", 0.01, 2.5e6, true}, {"tu3", 0.03, 2.5e5, false}}) {
        const auto coarse = run(c.name + "-1", c.reynolds, c.tu, 160, 120);
        if (!coarse.complete) continue;
        const auto fine = run(c.name + "-2", c.reynolds, c.tu, 240, 180);
        if (!fine.complete) continue;
        const std::string label = "Tu " + std::to_string(static_cast<int>(std::lround(c.tu * 100))) + " %: ";

        check(std::fabs(fine.tuLeadingEdge / c.tu - 1.0) <= 0.05, label + "турбулентность набегающего потока доходит до кромки",
              "Tu у кромки " + std::to_string(100.0 * fine.tuLeadingEdge) + " %");
        // The instrument first: a laminar layer's measured Re_θ must be Blasius' 0.664√Re_x (3 %:
        // trapezoids over the mesh line and the 0.999 cut-off), or the onset below means nothing.
        check(std::fabs(fine.laminarReThetaRatio - 1.0) <= 0.03, label + "измерение Re_θ верно на ламинарном участке (Блазиус ±3 %)",
              "Re_θ / Блазиус = " + std::to_string(fine.laminarReThetaRatio));
        if (c.judgeTurbulentEnd) check(std::fabs(fine.laminarRatio - 1.0) <= 0.05, label + "до перехода слой ламинарный (Блазиус ±5 %)",
              "cf√Re_x / Блазиус = " + std::to_string(fine.laminarRatio));
        check(fine.transitioned, label + "слой переходит в турбулентный на пластине");

        const double rtt = reThetaT(100.0 * fine.tuLeadingEdge), rtc = reThetaC(rtt);
        const double meshShift = std::fabs(fine.onsetReTheta - coarse.onsetReTheta);
        const double low = rtc - meshShift, high = 1.15 * rtt + meshShift;
        std::printf("  %s начало перехода Re_θ %.0f (грубая сетка %.0f), допустимо %.0f…%.0f\n", label.c_str(), fine.onsetReTheta,
                    coarse.onsetReTheta, low, high);
        std::printf("  %s начало перехода %s коридора корреляции модели (справочно; положение судится по T3A)\n", label.c_str(),
                    fine.onsetReTheta >= low && fine.onsetReTheta <= high ? "внутри" : "вне");

        const double outside = outsideCorrelationBand(fine.endSkinFriction, fine.endReTheta);
        std::printf("  %s x = 0.9: вне полосы турбулентных законов %+.2f %%\n", label.c_str(), 100.0 * outside);
        if (c.judgeTurbulentEnd) check(std::fabs(outside) <= 0.05, label + "после перехода слой турбулентный канонический (полоса ±5 %)");
    }
    return fea_test::finish("test_cfd_transition_plate");
}
