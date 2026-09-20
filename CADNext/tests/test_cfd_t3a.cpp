// Transition model validation against experiment: the ERCOFTAC T3A and T3A− flat plates.
//
//   cadnext_test_cfd_t3a <SU2_CFD> <work directory>
//
// Data: ERCOFTAC Classic Collection, case 020 "Flat Plate Transitional Boundary Layers" (Rolls-Royce
// Applied Science Laboratory, J. Coupland; ERCOFTAC SIG on transition, M. Savill), summary tables
// t3ay.dat and t3amy.dat: at every hot-wire station x, Re_x, the local free-stream velocity U₀, the
// skin friction Cf, Re_θ and the free-stream turbulence intensity. Air: ν = 1.5·10⁻⁵ m²/s (ρ 1.2,
// μ 1.8·10⁻⁵ — the values that reproduce the tables' Re_x from x and U₀, and SU2's own T3A setup).
//
// What is validated: the SU2 γ-Reθ model (SST + LM, MENTER_LANGTRY) — where a real boundary layer
// transitions. The model reads the LOCAL turbulence intensity, and in the tunnel it decays along the
// plate (T3A: 3.0 % → 1.3 %), so the comparison is only fair with the same decay: no sustaining terms
// here, and inlet values of k and ω chosen so that SST's free-stream decay law
//   ω(t) = ω₀ / (1 + β ω₀ t),  k(t) = k₀ (1 + β ω₀ t)^(−β*/β),  β = 0.0828, β* = 0.09 (F₁ = 0 away from
// walls), t = x / U,
// reproduces the measured Tu(x): Tu_LE and ω_LE are fitted to all stations, then carried back to the
// inlet 0.1 m upstream of the leading edge.
//
// Criteria, stated before the runs:
//   1. The conditions: the computed free-stream Tu at the stations within ±10 % of the measured.
//   2. Where transition starts: the computed friction minimum lies between the stations that bracket
//      the measured minimum (T3A 295…495 mm, T3A− 995…1195 mm) — the station spacing is the
//      experiment's own resolution of that position.
//   3. Friction away from the transition: at the stations before the bracket (laminar) and, for T3A,
//      from 895 mm on (turbulent), the computed Cf at the station's Re_x within ±10 % of the measured
//      (Cf there comes from hot-wire profiles).
// Numerics, fixed after the first two runs stopped too early (a numerical gate, not a comparison):
// converged when the drag's range over the last 1000 iterations is below 1 % of its mean — a tenth of
// the comparison tolerance; two meshes (the second 1.5 times finer both ways), the finer one judged,
// the coarser printed for the mesh's share.

#include "fea_test_support.hpp"

#include "cadnext/cfd/FlatPlate.hpp"
#include "cadnext/cfd/Su2Case.hpp"

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

constexpr double kDensity = 1.2, kViscosity = 1.8e-5, kNu = kViscosity / kDensity;
constexpr double kBeta = 0.0828, kBetaStar = 0.09;
constexpr double kLength = 1.3, kUpstream = 0.1, kHeight = 0.2;

struct Station {
    double xMm, reX, u0, cf, reTheta, tuPercent;
};

// t3ay.dat
const std::vector<Station> kT3A = {
    {45.0, 1.520e4, 5.05, 0.005203, 79.7, 3.043},   {95.0, 3.240e4, 5.11, 0.003723, 117.4, 2.793},
    {195.0, 6.700e4, 5.15, 0.002645, 176.5, 2.434}, {295.0, 1.006e5, 5.19, 0.002272, 224.9, 2.197},
    {395.0, 1.348e5, 5.20, 0.002098, 272.3, 2.001}, {495.0, 1.692e5, 5.20, 0.002209, 322.8, 1.882},
    {595.0, 2.035e5, 5.21, 0.002703, 384.5, 1.760}, {695.0, 2.384e5, 5.22, 0.003801, 456.3, 1.647},
    {795.0, 2.735e5, 5.23, 0.004849, 538.9, 1.538}, {895.0, 3.093e5, 5.25, 0.004861, 627.5, 1.451},
    {995.0, 3.447e5, 5.26, 0.004722, 710.5, 1.361}, {1095.0, 3.822e5, 5.27, 0.004553, 796.5, 1.295},
};
// t3amy.dat
const std::vector<Station> kT3AMinus = {
    {95.0, 1.225e5, 19.53, 0.001880, 219.4, 0.874},  {195.0, 2.541e5, 19.74, 0.001250, 326.9, 0.793},
    {295.0, 3.855e5, 19.81, 0.001027, 401.5, 0.738}, {395.0, 5.078e5, 19.81, 0.000901, 466.6, 0.685},
    {495.0, 6.422e5, 19.93, 0.000780, 539.2, 0.651}, {595.0, 7.720e5, 19.88, 0.000733, 579.4, 0.610},
    {695.0, 9.003e5, 19.83, 0.000661, 630.9, 0.585}, {795.0, 1.038e6, 19.82, 0.000624, 684.8, 0.564},
    {895.0, 1.173e6, 19.87, 0.000603, 734.3, 0.545}, {995.0, 1.306e6, 19.88, 0.000565, 784.8, 0.525},
    {1095.0, 1.443e6, 19.83, 0.000535, 818.8, 0.512}, {1195.0, 1.561e6, 19.67, 0.000557, 861.5, 0.498},
};

Su2History tableOf(const std::filesystem::path& file) {
    std::ifstream stream(file);
    const auto parsed = parseSu2History({std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()});
    return parsed.isOk() ? parsed.value() : Su2History{};
}

std::string number(double v) {
    char buffer[40];
    std::snprintf(buffer, sizeof buffer, "%.8g", v);
    return buffer;
}

// Inlet values that make SST's free-stream decay pass through the measured Tu(x): fit Tu_LE and
// c = β ω_LE / U to log Tu = log Tu_LE − (β*/2β) log(1 + c x) by least squares over c (the slope is fixed
// by the model), then carry k, ω back over the upstream length.
struct InletTurbulence {
    double tuLE = 0.0, omegaLE = 0.0, tuInlet = 0.0, viscosityRatioInlet = 0.0;
};
InletTurbulence calibrate(const std::vector<Station>& data, double speed) {
    const double exponent = kBetaStar / (2.0 * kBeta);
    double bestError = std::numeric_limits<double>::infinity(), bestC = 0.0, bestLog = 0.0;
    for (double c = 0.01; c < 100.0; c *= 1.002) {
        // For a given c the best log Tu_LE is the mean residual.
        double mean = 0.0;
        for (const auto& s : data) mean += std::log(s.tuPercent) + exponent * std::log(1.0 + c * s.xMm / 1000.0);
        mean /= data.size();
        double error = 0.0;
        for (const auto& s : data) {
            const double r = std::log(s.tuPercent) - (mean - exponent * std::log(1.0 + c * s.xMm / 1000.0));
            error += r * r;
        }
        if (error < bestError) bestError = error, bestC = c, bestLog = mean;
    }
    InletTurbulence out;
    out.tuLE = std::exp(bestLog) / 100.0;
    out.omegaLE = bestC * speed / kBeta;
    const double kLE = 1.5 * std::pow(out.tuLE * speed, 2.0);
    const double t = kUpstream / speed;
    const double omegaInlet = out.omegaLE / (1.0 - kBeta * out.omegaLE * t);
    const double kInlet = kLE * std::pow(omegaInlet / out.omegaLE, kBetaStar / kBeta);
    out.tuInlet = std::sqrt(kInlet / 1.5) / speed;
    out.viscosityRatioInlet = kDensity * kInlet / (kViscosity * omegaInlet);
    return out;
}

Su2Config config(double speed, const InletTurbulence& inlet) {
    Su2Config c;
    for (const auto& [key, value] : std::vector<std::pair<std::string, std::string>>{
             {"SOLVER", "INC_RANS"}, {"KIND_TURB_MODEL", "SST"}, {"KIND_TRANS_MODEL", "LM"}, {"LM_OPTIONS", "( MENTER_LANGTRY )"},
             {"MATH_PROBLEM", "DIRECT"}, {"INC_DENSITY_MODEL", "CONSTANT"}, {"INC_DENSITY_INIT", number(kDensity)},
             {"INC_VELOCITY_INIT", "( " + number(speed) + ", 0.0, 0.0 )"}, {"INC_ENERGY_EQUATION", "NO"},
             {"VISCOSITY_MODEL", "CONSTANT_VISCOSITY"}, {"MU_CONSTANT", number(kViscosity)},
             {"FREESTREAM_TURBULENCEINTENSITY", number(inlet.tuInlet)}, {"FREESTREAM_TURB2LAMVISCRATIO", number(inlet.viscosityRatioInlet)},
             {"INC_INLET_TYPE", "VELOCITY_INLET"}, {"MARKER_INLET", "( inlet, 0.0, " + number(speed) + ", 1.0, 0.0, 0.0 )"},
             {"INC_OUTLET_TYPE", "PRESSURE_OUTLET"}, {"MARKER_OUTLET", "( outlet, 0.0 )"},
             {"MARKER_HEATFLUX", "( wall, 0.0 )"}, {"MARKER_SYM", "( symmetry )"}, {"MARKER_FAR", "( farfield )"},
             {"MARKER_PLOTTING", "( wall )"}, {"MARKER_MONITORING", "( wall )"}, {"REF_LENGTH", "1.0"}, {"REF_AREA", "1.0"},
             {"NUM_METHOD_GRAD", "GREEN_GAUSS"}, {"CONV_NUM_METHOD_FLOW", "FDS"}, {"MUSCL_FLOW", "YES"}, {"SLOPE_LIMITER_FLOW", "NONE"},
             {"TIME_DISCRE_FLOW", "EULER_IMPLICIT"}, {"CFL_NUMBER", "10"}, {"CFL_ADAPT", "YES"}, {"CFL_ADAPT_PARAM", "( 0.5, 1.5, 10.0, 1e3 )"},
             {"LINEAR_SOLVER", "FGMRES"}, {"LINEAR_SOLVER_PREC", "ILU"}, {"LINEAR_SOLVER_ERROR", "1E-4"}, {"LINEAR_SOLVER_ITER", "20"},
             // Stop on the physics: the first version stopped on rms[P] = −9, which these runs (scaled by
             // U = 5.2 and 19.8 m/s) reach after 100–330 iterations while the drag is still moving by
             // 20 % — a boundary layer that had not formed yet.
             // The second version stopped at ~1500 iterations on a drag plateau that still breathes by
             // ±0.2 % — normal for γ-Reθ — so the window is longer and the start later.
             {"ITER", "12000"}, {"CONV_FIELD", "DRAG"}, {"CONV_STARTITER", "3000"}, {"CONV_CAUCHY_ELEMS", "1000"},
             {"CONV_CAUCHY_EPS", "1E-7"},
             {"HISTORY_OUTPUT", "( ITER, RMS_RES, AERO_COEFF )"}, {"OUTPUT_FILES", "( SURFACE_CSV, RESTART_ASCII )"},
             {"VOLUME_OUTPUT", "( COORDINATES, SOLUTION, PRIMITIVE )"}, {"WRT_RESTART_COMPACT", "NO"}, {"RESTART_FILENAME", "volume"},
             {"MESH_FILENAME", "mesh.su2"}, {"MESH_FORMAT", "SU2"}, {"TABULAR_FORMAT", "CSV"},
             {"CONV_FILENAME", "history"}, {"SURFACE_FILENAME", "surface"}}) {
        c.set(key, value);
    }
    return c;
}

// The column of nodes nearest x: edge velocity (the profile's plateau, as u/U) and Tu at y = 0.05 m.
struct Column {
    double x = NAN, edge = NAN, tu = NAN;
};
Column columnAt(const Su2History& volume, double x) {
    const int cx = volume.column("x"), cy = volume.column("y"), cu = volume.column("Velocity_x"), ck = volume.column("Turb_Kin_Energy");
    Column out;
    double nearest = std::numeric_limits<double>::infinity();
    for (const auto& row : volume.rows) nearest = std::min(nearest, std::fabs(row[cx] - x));
    double edge = 0.0, bestY = std::numeric_limits<double>::infinity(), k = NAN, uAtK = NAN;
    for (const auto& row : volume.rows) {
        if (std::fabs(std::fabs(row[cx] - x) - nearest) > 1e-12) continue;
        out.x = row[cx];
        if (row[cy] <= 0.75 * kHeight) edge = std::max(edge, row[cu]);
        if (std::fabs(row[cy] - 0.05) < bestY) bestY = std::fabs(row[cy] - 0.05), k = row[ck], uAtK = row[cu];
    }
    out.edge = edge;
    out.tu = std::sqrt(2.0 * k / 3.0) / uAtK;
    return out;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::printf("usage: %s <SU2_CFD> <work directory>\n", argv[0]);
        return 64;
    }
    const std::string solver = argv[1];
    const std::filesystem::path work = argv[2];
    std::filesystem::remove_all(work);

    struct Case {
        std::string name;
        const std::vector<Station>* data;
        double speed;
        double bracketLowMm, bracketHighMm; // stations around the measured friction minimum
        double laminarUpToMm, turbulentFromMm;
    };
    for (const auto& c : std::vector<Case>{{"T3A", &kT3A, 5.2, 295.0, 495.0, 295.0, 895.0},
                                          {"T3A-", &kT3AMinus, 19.8, 995.0, 1195.0, 895.0, INFINITY}}) {
        const auto inlet = calibrate(*c.data, c.speed);
        std::printf("  %s: U %.2f m/s; fitted Tu at the leading edge %.3f %%, ω %.1f 1/s → inlet (0.1 m upstream) Tu %.3f %%, μt/μ %.2f\n",
                    c.name.c_str(), c.speed, 100 * inlet.tuLE, inlet.omegaLE, 100 * inlet.tuInlet, inlet.viscosityRatioInlet);
      for (const int level : {1, 2}) {
        const bool judged = level == 2;
        const auto directory = work / (c.name + "-" + std::to_string(level));
        std::filesystem::create_directories(directory);
        FlatPlateMeshSpec spec;
        spec.length = kLength;
        spec.upstream = kUpstream;
        spec.height = kHeight;
        spec.plateCells = level == 1 ? 260 : 390;
        spec.upstreamCells = level == 1 ? 40 : 60;
        spec.normalCells = level == 1 ? 160 : 240;
        spec.leadingEdgeStretch = 40.0;
        spec.upstreamStretch = 20.0;
        spec.wallStretch = 10000.0;
        const auto mesh = flatPlateMesh(spec);
        if (!mesh.write((directory / "mesh.su2").string())) {
            check(false, c.name + ": mesh written");
            continue;
        }
        Su2RunControl control;
        control.timeoutSeconds = 5400;
        const auto run = runSu2(solver, directory.string(), config(c.speed, inlet), 4, control);
        if (!run.isOk() || run.value().timedOut || run.value().exitStatus != 0) {
            check(false, c.name + ": SU2 run", run.isOk() ? (run.value().timedOut ? "timeout" : "exit " + std::to_string(run.value().exitStatus))
                                                          : run.error().message);
            continue;
        }
        std::printf("  %s: %zu cells, %zu iterations, rms[P] %.2f\n", c.name.c_str(), mesh.elements.size(), run.value().history.rows.size(),
                    run.value().history.last("rms[P]"));
        {
            const auto& history = run.value().history;
            const int cd = history.column("CD");
            const std::size_t n = history.rows.size();
            double low = INFINITY, high = -INFINITY, mean = 0.0;
            for (std::size_t i = n > 1000 ? n - 1000 : 0; i < n; ++i) {
                low = std::min(low, history.rows[i][cd]);
                high = std::max(high, history.rows[i][cd]);
                mean += history.rows[i][cd];
            }
            mean /= std::min<std::size_t>(n, 1000);
            const double range = n > 1000 && cd >= 0 ? (high - low) / mean : 1.0;
            check(range < 0.01, c.name + " mesh " + std::to_string(level) + ": converged — drag range over the last 1000 iterations below 1 %",
                  "range " + std::to_string(range));
        }

        const auto surface = tableOf(directory / "surface.csv");
        const auto volume = tableOf(directory / "volume.csv");
        // Wall friction, re-referenced to the local edge velocity, against the local Re_x — the way the
        // tables are written.
        const int sx = surface.column("x"), sy = surface.column("y"), scf = surface.column("Skin_Friction_Coefficient_x");
        std::vector<std::pair<double, double>> wall;
        for (const auto& row : surface.rows)
            if (std::fabs(row[sy]) < 1e-12 && row[sx] > 0.0) wall.emplace_back(row[sx], row[scf]);
        std::sort(wall.begin(), wall.end());
        std::vector<std::array<double, 3>> local; // x, Re_x, Cf (edge-referenced)
        for (std::size_t i = 0; i < wall.size(); i += std::max<std::size_t>(1, wall.size() / 400)) {
            // SU2's incompressible output is scaled by the initial values (INC_NONDIM = INITIAL_VALUES):
            // velocities are u/U, and Cf is referred to ½ρU². The first version read u as m/s and put
            // Re_x five times too low.
            const auto column = columnAt(volume, wall[i].first);
            local.push_back({wall[i].first, wall[i].first * column.edge * c.speed / kNu, wall[i].second / (column.edge * column.edge)});
        }
        auto cfAtReX = [&](double reX) -> double {
            for (std::size_t i = 1; i < local.size(); ++i)
                if (local[i][1] >= reX) {
                    const double t = (reX - local[i - 1][1]) / (local[i][1] - local[i - 1][1]);
                    return local[i - 1][2] + t * (local[i][2] - local[i - 1][2]);
                }
            return NAN;
        };

        // 1. Free-stream Tu at the stations.
        double worstTu = 0.0;
        for (const auto& s : *c.data) {
            const auto column = columnAt(volume, s.xMm / 1000.0);
            worstTu = std::max(worstTu, std::fabs(100.0 * column.tu / s.tuPercent - 1.0));
            std::printf("    x %6.0f mm  Tu %.3f %% (measured %.3f)   Cf %.6f (measured %.6f, %+.1f %%)\n", s.xMm, 100 * column.tu, s.tuPercent,
                        cfAtReX(s.reX), s.cf, 100 * (cfAtReX(s.reX) / s.cf - 1));
        }
        if (judged) check(worstTu <= 0.10, c.name + ": computed free-stream Tu within ±10 % of the measured decay",
              "largest deviation " + std::to_string(100 * worstTu) + " %");

        // 2. Friction minimum.
        std::size_t minimum = 0;
        for (std::size_t i = 0; i < local.size(); ++i)
            if (local[i][0] > 0.03 && local[i][0] < kLength - 0.05 && (minimum == 0 || local[i][2] < local[minimum][2])) minimum = i;
        std::printf("  %s mesh %d: computed friction minimum at x %.0f mm (Re_x %.3g); measured between %.0f and %.0f mm\n", c.name.c_str(),
                    level, 1000 * local[minimum][0], local[minimum][1], c.bracketLowMm, c.bracketHighMm);
        if (judged) check(1000 * local[minimum][0] >= c.bracketLowMm && 1000 * local[minimum][0] <= c.bracketHighMm,
              c.name + ": transition starts where the experiment has it (between the bracketing stations)");

        // 3. Friction before and after transition.
        double worstLaminar = 0.0, worstTurbulent = 0.0;
        for (const auto& s : *c.data) {
            const double deviation = std::fabs(cfAtReX(s.reX) / s.cf - 1.0);
            if (s.xMm <= c.laminarUpToMm) worstLaminar = std::max(worstLaminar, deviation);
            if (s.xMm >= c.turbulentFromMm) worstTurbulent = std::max(worstTurbulent, deviation);
        }
        std::printf("  %s mesh %d: largest deviation before transition %.1f %%, after %.1f %%\n", c.name.c_str(), level, 100 * worstLaminar,
                    std::isfinite(c.turbulentFromMm) ? 100 * worstTurbulent : NAN);
        if (judged) check(worstLaminar <= 0.10, c.name + ": friction before transition within ±10 % of the measured",
              "largest deviation " + std::to_string(100 * worstLaminar) + " %");
        if (judged && std::isfinite(c.turbulentFromMm)) {
            check(worstTurbulent <= 0.10, c.name + ": friction after transition within ±10 % of the measured",
                  "largest deviation " + std::to_string(100 * worstTurbulent) + " %");
        }
      }
    }
    return fea_test::finish("test_cfd_t3a");
}
