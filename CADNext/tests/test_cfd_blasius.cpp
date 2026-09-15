// Flow solver code verification, viscous: laminar incompressible flat plate against Blasius,
// cf·√Re_x = 0.66412.
//
//   cadnext_test_cfd_blasius <SU2_CFD> <work directory>
//
// SU2 INC_NAVIER_STOKES, Re_L = 1e5 (U = 1, ρ = 1, μ = 1e-5, L = 1), plate from the leading edge to
// the outlet (no trailing edge), 2 L of slip wall upstream, freestream 4 L above. Three meshes refined
// as a whole (plate 48/72/96, upstream 36/54/72, normal 48/72/96 cells), one mapping family.
// Station x/L = 0.5 (Re_x = 5·10⁴), interpolated between wall nodes.
//
// Criterion, fixed before the run:
//   |cf√Re_x extrapolated / 0.66412 − 1| ≤ GCI + 0.5 % + measured domain effect.
// 0.5 %: Imai's second-order correction to the whole plate's drag at Re_L = 1e5 is 0.55 %, and it is
// the singular leading-edge region that carries it — less at mid-plate. The domain effect is not
// assumed: the middle mesh is run again in a domain twice as long upstream and twice as tall, and the
// difference is added.
// History of this test: the first domain, with the inlet 0.25 L upstream of the leading edge, gave
// +1.6 %; 1 L gave +0.2 %. A fixed-velocity inlet that close blocks the leading edge's upstream
// influence and sets up a favourable pressure gradient along the plate. That was the setup, not the
// solver, and it is why the domain is measured here rather than trusted.

#include "fea_test_support.hpp"

#include "cadnext/cfd/FlatPlate.hpp"
#include "cadnext/cfd/Su2Case.hpp"
#include "cadnext/fea/Convergence.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>

using namespace cadnext::cfd;
using fea_test::check;

namespace {

constexpr double kBlasius = 0.66412;
constexpr double kReynoldsPerLength = 1.0e5;

Su2Config laminarPlate() {
    Su2Config c;
    for (const auto& [key, value] : std::vector<std::pair<std::string, std::string>>{
             {"SOLVER", "INC_NAVIER_STOKES"}, {"KIND_TURB_MODEL", "NONE"}, {"MATH_PROBLEM", "DIRECT"},
             {"INC_DENSITY_MODEL", "CONSTANT"}, {"INC_DENSITY_INIT", "1.0"}, {"INC_VELOCITY_INIT", "( 1.0, 0.0, 0.0 )"},
             {"VISCOSITY_MODEL", "CONSTANT_VISCOSITY"}, {"MU_CONSTANT", "1.0E-5"},
             {"INC_INLET_TYPE", "VELOCITY_INLET"}, {"MARKER_INLET", "( inlet, 0.0, 1.0, 1.0, 0.0, 0.0 )"},
             {"INC_OUTLET_TYPE", "PRESSURE_OUTLET"}, {"MARKER_OUTLET", "( outlet, 0.0 )"},
             {"MARKER_HEATFLUX", "( wall, 0.0 )"}, {"MARKER_SYM", "( symmetry )"}, {"MARKER_FAR", "( farfield )"},
             {"MARKER_PLOTTING", "( wall )"}, {"MARKER_MONITORING", "( wall )"}, {"REF_LENGTH", "1.0"}, {"REF_AREA", "1.0"},
             {"NUM_METHOD_GRAD", "GREEN_GAUSS"}, {"CONV_NUM_METHOD_FLOW", "FDS"}, {"MUSCL_FLOW", "YES"}, {"SLOPE_LIMITER_FLOW", "NONE"},
             {"TIME_DISCRE_FLOW", "EULER_IMPLICIT"}, {"CFL_NUMBER", "10"}, {"CFL_ADAPT", "YES"}, {"CFL_ADAPT_PARAM", "( 0.5, 1.5, 10.0, 1e4 )"},
             {"LINEAR_SOLVER", "FGMRES"}, {"LINEAR_SOLVER_PREC", "ILU"}, {"LINEAR_SOLVER_ERROR", "1E-4"}, {"LINEAR_SOLVER_ITER", "20"},
             {"ITER", "8000"}, {"CONV_FIELD", "RMS_PRESSURE"}, {"CONV_RESIDUAL_MINVAL", "-12"},
             {"HISTORY_OUTPUT", "( ITER, RMS_RES, AERO_COEFF )"}, {"OUTPUT_FILES", "( SURFACE_CSV )"},
             // Compact output keeps only the restart fields; skin friction is not one of them.
             {"VOLUME_OUTPUT", "( COORDINATES, SOLUTION, PRIMITIVE )"}, {"WRT_RESTART_COMPACT", "NO"},
             {"MESH_FILENAME", "mesh.su2"}, {"MESH_FORMAT", "SU2"}, {"TABULAR_FORMAT", "CSV"},
             {"CONV_FILENAME", "history"}, {"SURFACE_FILENAME", "surface"}}) {
        c.set(key, value);
    }
    return c;
}

// cf·√Re_x at x, linear between the two wall nodes around it.
double scaledSkinFriction(const std::filesystem::path& directory, double x) {
    std::ifstream file(directory / "surface.csv");
    const std::string text{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
    const auto parsed = parseSu2History(text);
    if (!parsed.isOk()) return NAN;
    const auto& table = parsed.value();
    const int cx = table.column("x"), cy = table.column("y"), cf = table.column("Skin_Friction_Coefficient_x");
    if (cx < 0 || cf < 0) return NAN;
    std::vector<std::pair<double, double>> wall;
    for (const auto& row : table.rows)
        if (std::fabs(row[cy]) < 1e-12 && row[cx] > 0.0) wall.emplace_back(row[cx], row[cf]);
    std::sort(wall.begin(), wall.end());
    for (std::size_t i = 1; i < wall.size(); ++i) {
        if (wall[i].first >= x) {
            const double t = (x - wall[i - 1].first) / (wall[i].first - wall[i - 1].first);
            return (wall[i - 1].second + t * (wall[i].second - wall[i - 1].second)) * std::sqrt(x * kReynoldsPerLength);
        }
    }
    return NAN;
}

struct Level {
    FlatPlateMeshSpec spec;
    std::string name;
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

    auto level = [](int k, double upstream, double height) {
        FlatPlateMeshSpec spec;
        spec.length = 1.0;
        spec.upstream = upstream;
        spec.height = height;
        spec.plateCells = 24 * k;
        spec.normalCells = 24 * k;
        spec.upstreamCells = static_cast<int>(std::lround(9 * k * upstream));
        spec.leadingEdgeStretch = 40.0;
        // Leading-edge spacing on both sides about equal, wall spacing independent of the height.
        spec.upstreamStretch = upstream <= 2.0 ? 140.0 : 150.0;
        spec.wallStretch = 400.0 * height;
        return spec;
    };
    std::vector<Level> levels = {{level(2, 2.0, 4.0), "k2"}, {level(3, 2.0, 4.0), "k3"}, {level(4, 2.0, 4.0), "k4"}, {level(3, 4.0, 8.0), "k3-large"}};

    std::vector<double> values;
    std::vector<std::size_t> plateNodes;
    bool converged = true;
    for (const auto& [spec, name] : levels) {
        const auto directory = work / name;
        std::filesystem::create_directories(directory);
        const auto mesh = flatPlateMesh(spec);
        check(mesh.write((directory / "mesh.su2").string()), name + ": mesh written");
        const auto run = runSu2(solver, directory.string(), laminarPlate(), 10);
        if (!run.isOk()) {
            check(false, name + ": SU2 run", run.error().message);
            return fea_test::finish("test_cfd_blasius");
        }
        const double residual = run.value().history.last("rms[P]");
        const double value = scaledSkinFriction(directory, 0.5);
        std::printf("  %s: %zu cells, cf√Re_x(0.5) %.6f, rms[P] %.2f after %zu iterations\n", name.c_str(), mesh.elements.size(), value,
                    residual, run.value().history.rows.size());
        converged = converged && run.value().exitStatus == 0 && residual <= -12.0 + 1e-6;
        values.push_back(value);
        plateNodes.push_back(static_cast<std::size_t>(spec.plateCells) * spec.normalCells);
    }
    check(converged, "every run converged to a pressure residual of 1e-12");

    const double r21 = std::sqrt(static_cast<double>(plateNodes[2]) / plateNodes[1]);
    const double r32 = std::sqrt(static_cast<double>(plateNodes[1]) / plateNodes[0]);
    const auto study = cadnext::fea::estimateConvergence(values[2], values[1], values[0], r21, r32, 1.25, 2.0);
    std::printf("  cf√Re_x: %s\n", study.describe().c_str());
    check(study.isUsable(), "skin friction converges monotonically");
    const double domain = std::fabs(values[3] - values[1]);
    const double best = study.isUsable() ? study.extrapolated : values[2];
    const double band = (study.isUsable() ? study.uncertaintyAbsolute : std::fabs(values[2] - values[1])) + 0.005 * kBlasius + domain;
    std::printf("  extrapolated %.6f vs Blasius %.5f: %.3f %%; allowed %.3f %% (mesh %.3f %%, higher-order 0.5 %%, domain %.3f %%)\n", best,
                kBlasius, 100.0 * (best / kBlasius - 1.0), 100.0 * band / kBlasius, 100.0 * study.uncertaintyAbsolute / kBlasius,
                100.0 * domain / kBlasius);
    check(std::fabs(best - kBlasius) <= band, "laminar skin friction at mid-plate matches Blasius within the stated bands");
    return fea_test::finish("test_cfd_blasius");
}
