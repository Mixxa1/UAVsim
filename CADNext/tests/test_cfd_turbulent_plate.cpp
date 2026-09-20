// Turbulence model verification: incompressible flat plate at Re_L = 5·10⁶ with k-ω SST, in both wall
// treatments the study offers.
//
//   cadnext_test_cfd_turbulent_plate <SU2_CFD> <work directory>
//
// U = 1, ρ = 1, μ = 2·10⁻⁷, plate from the leading edge to the outlet, 0.5 L of slip wall upstream,
// freestream 0.2 L above (≈ 12 δ₉₉ at the outlet). At x = 0.5 the test reads the local skin friction
// and integrates the momentum thickness from the volume field, θ = ∫ u/U (1 − u/U) dy.
//
// What is compared, and why it is not cf(Re_x): the correlations in x (White, the 1/5-power law)
// describe a layer that has been turbulent since the leading edge. A computed layer has its own
// history — SST has no transition model and its layer thickens differently over the first cells — so
// at the same Re_x the two are not the same boundary layer. Measured here: cf sits 7–12 % below the
// x-correlations while the same runs sit inside the band of the momentum-thickness laws, which carry
// no origin. Those are the reference; the x-correlation value is printed as information.
//
// Reference band at the measured Re_θ, between two accepted laws that differ by about 4 % here:
//   Coles–Fernholz    cf = 2 [ln(Re_θ)/0.384 + 4.127]⁻²
//   Kármán–Schoenherr cf = [17.08 (log₁₀ Re_θ)² + 25.11 log₁₀ Re_θ + 6.012]⁻¹
//
// Criterion, stated before the runs:
//   resolved wall   — cf inside that band, allowing the mesh uncertainty (GCI) on top. With the
//                     viscous sublayer meshed, the model is being asked for its own answer and has
//                     no excuse beyond discretisation.
//   wall functions  — the same band widened by 3 %, because there the wall stress is not computed
//                     but taken from the log law with the wall model's own constants (κ = 0.41,
//                     B = 5.0), which are not the constants either correlation was fitted with. The
//                     3 % is the price of the model, and this test measures it rather than assuming
//                     it: the measured value is printed and must stay inside that allowance.
//
// Both wall treatments must also be in their own y⁺ regime as measured. The wall-function levels run
// multithreaded on purpose: stock SU2 8.5 calls its wall model from a master-only region although the
// routine contains an `omp for`, so with more than one thread libomp asserts here and a 3D run stalls
// (measured: four threads, no iteration in forty minutes). CADNext/tools/su2-patches carries the fix,
// and these levels are its regression test — they also reproduce the same cf as a single thread.

#include "fea_test_support.hpp"

#include "cadnext/cfd/FlatPlate.hpp"
#include "cadnext/cfd/Su2Case.hpp"
#include "cadnext/cfd/WallResolution.hpp"
#include "cadnext/fea/Convergence.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <algorithm>
#include <limits>

using namespace cadnext;
using namespace cadnext::cfd;
using fea_test::check;

namespace {

constexpr double kSpeed = 1.0, kDensity = 1.0, kViscosity = 2.0e-7, kLength = 1.0;

double whiteSkinFriction(double reynoldsX) { return 0.455 / std::pow(std::log(0.06 * reynoldsX), 2.0); }
double powerLawSkinFriction(double reynoldsX) { return 0.0592 * std::pow(reynoldsX, -0.2); }

Su2Config sstPlate(WallTreatment treatment) {
    Su2Config c;
    for (const auto& [key, value] : std::vector<std::pair<std::string, std::string>>{
             {"SOLVER", "INC_RANS"}, {"KIND_TURB_MODEL", "SST"}, {"MATH_PROBLEM", "DIRECT"},
             {"INC_DENSITY_MODEL", "CONSTANT"}, {"INC_DENSITY_INIT", "1.0"}, {"INC_VELOCITY_INIT", "( 1.0, 0.0, 0.0 )"},
             {"INC_ENERGY_EQUATION", "NO"}, {"VISCOSITY_MODEL", "CONSTANT_VISCOSITY"}, {"MU_CONSTANT", "2.0E-7"},
             {"FREESTREAM_TURBULENCEINTENSITY", "0.01"}, {"FREESTREAM_TURB2LAMVISCRATIO", "10"},
             {"INC_INLET_TYPE", "VELOCITY_INLET"}, {"MARKER_INLET", "( inlet, 0.0, 1.0, 1.0, 0.0, 0.0 )"},
             {"INC_OUTLET_TYPE", "PRESSURE_OUTLET"}, {"MARKER_OUTLET", "( outlet, 0.0 )"},
             {"MARKER_HEATFLUX", "( wall, 0.0 )"}, {"MARKER_SYM", "( symmetry )"}, {"MARKER_FAR", "( farfield )"},
             {"MARKER_PLOTTING", "( wall )"}, {"MARKER_MONITORING", "( wall )"}, {"REF_LENGTH", "1.0"}, {"REF_AREA", "1.0"},
             {"NUM_METHOD_GRAD", "GREEN_GAUSS"}, {"CONV_NUM_METHOD_FLOW", "FDS"}, {"MUSCL_FLOW", "YES"}, {"SLOPE_LIMITER_FLOW", "NONE"},
             {"TIME_DISCRE_FLOW", "EULER_IMPLICIT"}, {"CFL_NUMBER", "10"}, {"CFL_ADAPT", "YES"}, {"CFL_ADAPT_PARAM", "( 0.5, 1.5, 10.0, 1e4 )"},
             {"LINEAR_SOLVER", "FGMRES"}, {"LINEAR_SOLVER_PREC", "ILU"}, {"LINEAR_SOLVER_ERROR", "1E-4"}, {"LINEAR_SOLVER_ITER", "20"},
             {"ITER", "6000"}, {"CONV_FIELD", "RMS_PRESSURE"}, {"CONV_RESIDUAL_MINVAL", "-11"},
             {"HISTORY_OUTPUT", "( ITER, RMS_RES, AERO_COEFF )"}, {"OUTPUT_FILES", "( SURFACE_CSV, RESTART_ASCII )"},
             {"VOLUME_OUTPUT", "( COORDINATES, SOLUTION, PRIMITIVE )"}, {"WRT_RESTART_COMPACT", "NO"}, {"RESTART_FILENAME", "volume"},
             {"MESH_FILENAME", "mesh.su2"}, {"MESH_FORMAT", "SU2"}, {"TABULAR_FORMAT", "CSV"},
             {"CONV_FILENAME", "history"}, {"SURFACE_FILENAME", "surface"}}) {
        c.set(key, value);
    }
    if (treatment == WallTreatment::Functions) c.set("MARKER_WALL_FUNCTIONS", "( wall, STANDARD_WALL_FUNCTION )");
    return c;
}

// Two accepted skin-friction laws for a zero-pressure-gradient turbulent boundary layer, written in
// the layer's own momentum thickness. They differ by about 4 % at Re_θ ≈ 5·10³ — that spread is what
// "the canonical layer" is known to within, and it is the band this test judges by.
double colesFernholzSkinFriction(double reynoldsTheta) {
    return 2.0 / std::pow(std::log(reynoldsTheta) / 0.384 + 4.127, 2.0);
}
double karmanSchoenherrSkinFriction(double reynoldsTheta) {
    const double l = std::log10(reynoldsTheta);
    return 1.0 / (17.08 * l * l + 25.11 * l + 6.012);
}
// Distance from cf to the band spanned by the two laws, relative to the band's middle; zero inside.
double outsideCorrelationBand(double skinFriction, double reynoldsTheta) {
    const double low = std::min(colesFernholzSkinFriction(reynoldsTheta), karmanSchoenherrSkinFriction(reynoldsTheta));
    const double high = std::max(colesFernholzSkinFriction(reynoldsTheta), karmanSchoenherrSkinFriction(reynoldsTheta));
    const double middle = 0.5 * (low + high);
    if (skinFriction < low) return (skinFriction - low) / middle;
    if (skinFriction > high) return (skinFriction - high) / middle;
    return 0.0;
}

struct Station {
    double skinFriction = NAN;
    double yPlus = NAN;
    double reynoldsTheta = NAN;
};

Su2History tableOf(const std::filesystem::path& file) {
    std::ifstream stream(file);
    const auto parsed = parseSu2History({std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()});
    return parsed.isOk() ? parsed.value() : Su2History{};
}

// cf and y+ at x, linear between the two wall nodes around it.
Station stationAt(const Su2History& surface, double x) {
    const int cx = surface.column("x"), cy = surface.column("y");
    const int cf = surface.column("Skin_Friction_Coefficient_x"), cyPlus = surface.column("Y_Plus");
    Station out;
    if (cx < 0 || cf < 0) return out;
    std::vector<std::array<double, 3>> wall;
    for (const auto& row : surface.rows)
        if (std::fabs(row[cy]) < 1e-12 && row[cx] > 0.0) wall.push_back({row[cx], row[cf], cyPlus >= 0 ? row[cyPlus] : NAN});
    std::sort(wall.begin(), wall.end(), [](const auto& a, const auto& b) { return a[0] < b[0]; });
    for (std::size_t i = 1; i < wall.size(); ++i) {
        if (wall[i][0] >= x) {
            const double t = (x - wall[i - 1][0]) / (wall[i][0] - wall[i - 1][0]);
            out.skinFriction = wall[i - 1][1] + t * (wall[i][1] - wall[i - 1][1]);
            out.yPlus = wall[i - 1][2] + t * (wall[i][2] - wall[i - 1][2]);
            return out;
        }
    }
    return out;
}

// Re_θ of the profile nearest x, trapezoidal over the mesh line (the mesh is structured, so a line of
// nodes shares one x). Against the local edge velocity U_e — the plateau of the profile — and only up
// to where u reaches 0.999 U_e. The first version integrated u(1 − u) with U = 1 up to the top of the
// domain; the outer flow there runs at 0.998–0.9995 (displacement of the layer, far-field boundary),
// and 0.2 m of that small deficit added about as much as θ itself: Re_θ came out 5300 for a layer of
// 4350, which pushed the band down and passed the wall-function levels at −2.7 % that are −5.4 %.
double reynoldsTheta(const Su2History& volume, double x) {
    const int cx = volume.column("x"), cy = volume.column("y"), cu = volume.column("Velocity_x");
    if (cx < 0 || cy < 0 || cu < 0) return NAN;
    double nearest = std::numeric_limits<double>::infinity();
    for (const auto& row : volume.rows) nearest = std::min(nearest, std::fabs(row[cx] - x));
    std::vector<std::pair<double, double>> profile;
    for (const auto& row : volume.rows)
        if (std::fabs(std::fabs(row[cx] - x) - nearest) < 1e-12) profile.emplace_back(row[cy], row[cu]);
    std::sort(profile.begin(), profile.end());
    if (profile.size() < 3) return NAN;
    double edge = 0.0;
    for (const auto& [y, u] : profile)
        if (y <= 0.75 * profile.back().first) edge = std::max(edge, u);
    double theta = 0.0;
    auto integrand = [edge](double u) { return u / edge * (1.0 - u / edge); };
    for (std::size_t i = 1; i < profile.size(); ++i) {
        theta += 0.5 * (integrand(profile[i - 1].second) + integrand(profile[i].second)) * (profile[i].first - profile[i - 1].first);
        if (profile[i].second >= 0.999 * edge) break;
    }
    return kDensity * edge * theta / kViscosity;
}

FlatPlateMeshSpec plateMesh(int plateCells, int normalCells, double wallStretch) {
    FlatPlateMeshSpec spec;
    spec.length = kLength;
    spec.upstream = 0.5;
    spec.height = 0.2;
    spec.plateCells = plateCells;
    spec.normalCells = normalCells;
    spec.upstreamCells = plateCells / 3;
    spec.leadingEdgeStretch = 40.0;
    spec.upstreamStretch = 40.0;
    spec.wallStretch = wallStretch;
    return spec;
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

    const double reynoldsHalf = reynoldsNumber(kSpeed, 0.5 * kLength, kDensity, kViscosity);
    std::printf("  x = 0.5: Re_x = %.3g; корреляции по x: White %.5f, степенная %.5f\n", reynoldsHalf,
                whiteSkinFriction(reynoldsHalf), powerLawSkinFriction(reynoldsHalf));

    auto runLevel = [&](const std::string& name, const FlatPlateMeshSpec& spec, WallTreatment treatment, int threads, double timeout,
                        Station& station, WallResolution& wall) {
        const auto directory = work / name;
        std::filesystem::create_directories(directory);
        const auto mesh = flatPlateMesh(spec);
        if (!mesh.write((directory / "mesh.su2").string())) return false;
        Su2RunControl control;
        control.timeoutSeconds = timeout;
        const auto run = runSu2(solver, directory.string(), sstPlate(treatment), threads, control);
        if (!run.isOk()) {
            check(false, name + ": SU2 run", run.error().message);
            return false;
        }
        if (run.value().timedOut || run.value().exitStatus != 0) {
            check(false, name + ": SU2 отработал до сходимости",
                  run.value().timedOut ? "прервано по таймауту" : "код выхода " + std::to_string(run.value().exitStatus));
            return false;
        }
        const auto surface = tableOf(directory / "surface.csv");
        station = stationAt(surface, 0.5);
        station.reynoldsTheta = reynoldsTheta(tableOf(directory / "volume.csv"), 0.5);
        wall = assessWallResolution(surface, treatment);
        if (!std::isfinite(station.skinFriction) || !std::isfinite(station.reynoldsTheta)) {
            check(false, name + ": поля содержат трение и профиль скорости");
            return false;
        }
        std::printf("  %s: %zu ячеек, %zu итераций, rms[P] %.2f; y+ %.2f (%s); Re_theta %.0f; cf %.5f — полоса %.5f…%.5f, вне неё %+.2f %% (к White(Re_x) %+.1f %%)\n",
                    name.c_str(), mesh.elements.size(), run.value().history.rows.size(), run.value().history.last("rms[P]"), station.yPlus,
                    wall.valid ? "режим соблюдён" : "режим нарушен", station.reynoldsTheta, station.skinFriction,
                    std::min(colesFernholzSkinFriction(station.reynoldsTheta), karmanSchoenherrSkinFriction(station.reynoldsTheta)),
                    std::max(colesFernholzSkinFriction(station.reynoldsTheta), karmanSchoenherrSkinFriction(station.reynoldsTheta)),
                    100.0 * outsideCorrelationBand(station.skinFriction, station.reynoldsTheta),
                    100.0 * (station.skinFriction / whiteSkinFriction(reynoldsHalf) - 1.0));
        return true;
    };

    // Resolved wall: three meshes of one family. The clustering map depends only on the stretch ratio,
    // not on the cell count, so holding the stretch fixed and raising the counts scales every spacing —
    // including the first cell — by the same factor, which is what a grid-convergence study needs.
    std::vector<double> errors;
    std::vector<std::size_t> cells;
    bool complete = true;
    for (const auto& [name, plateCells, normalCells] :
         std::vector<std::tuple<std::string, int, int>>{{"resolved-1", 96, 64}, {"resolved-2", 144, 96}, {"resolved-3", 216, 144}}) {
        Station station;
        WallResolution wall;
        if (!runLevel(name, plateMesh(plateCells, normalCells, 30000.0), WallTreatment::Resolved, 4, 1800, station, wall)) {
            complete = false;
            break;
        }
        check(wall.valid, name + ": первый узел в вязком подслое", wall.problem);
        errors.push_back(outsideCorrelationBand(station.skinFriction, station.reynoldsTheta));
        cells.push_back(static_cast<std::size_t>(plateCells) * normalCells);
    }
    if (complete) {
        const double r21 = std::sqrt(static_cast<double>(cells[2]) / cells[1]);
        const double r32 = std::sqrt(static_cast<double>(cells[1]) / cells[0]);
        const auto study = fea::estimateConvergence(errors[2], errors[1], errors[0], r21, r32, 1.25, 2.0);
        // Every level inside the band gives a zero series, which no extrapolation can improve on and
        // for which GCI is meaningless; then the finest level decides.
        const bool allInside = std::all_of(errors.begin(), errors.end(), [](double e) { return e == 0.0; });
        const double best = allInside ? 0.0 : (study.isUsable() ? study.extrapolated : errors[2]);
        const double mesh = allInside ? 0.0 : (study.isUsable() ? study.uncertaintyAbsolute : std::fabs(errors[2] - errors[1]));
        std::printf("  разрешённый слой: выход за полосу %+.2f %% (уровни %+.2f / %+.2f / %+.2f %%), допуск по сетке %.2f %%\n", 100.0 * best,
                    100.0 * errors[0], 100.0 * errors[1], 100.0 * errors[2], 100.0 * mesh);
        check(std::fabs(best) <= mesh, "SST с разрешённым слоем воспроизводит канонический слой в пределах полосы корреляций");
    }

    // Wall functions: two meshes, first node in the log layer. No family refinement — refining the
    // wall spacing here changes the regime itself — so the mesh term is the difference between them.
    {
        std::vector<double> functionErrors;
        for (const auto& [name, plateCells, normalCells] :
             std::vector<std::tuple<std::string, int, int>>{{"functions-1", 96, 40}, {"functions-2", 144, 60}}) {
            Station station;
            WallResolution wall;
            if (!runLevel(name, plateMesh(plateCells, normalCells, 81.0), WallTreatment::Functions, 4, 1800, station, wall)) break;
            check(wall.valid, name + ": первый узел в логарифмическом слое", wall.problem);
            functionErrors.push_back(outsideCorrelationBand(station.skinFriction, station.reynoldsTheta));
        }
        if (functionErrors.size() == 2) {
            const double allowance = 0.03 + std::fabs(functionErrors[1] - functionErrors[0]);
            std::printf("  пристеночные функции: выход за полосу %+.2f %% и %+.2f %%, допуск %.2f %% (модель стенки 3 %% + сетка %.2f %%)\n",
                        100.0 * functionErrors[0], 100.0 * functionErrors[1], 100.0 * allowance,
                        100.0 * std::fabs(functionErrors[1] - functionErrors[0]));
            check(std::fabs(functionErrors[1]) <= allowance, "пристеночные функции воспроизводят канонический слой в пределах допуска модели стенки");
        }
    }
    return fea_test::finish("test_cfd_turbulent_plate");
}
