// Flow solver code verification: inviscid incompressible flow over a Joukowski airfoil, which has an
// exact potential-flow lift.
//
//   cadnext_test_cfd_joukowski_euler <SU2_CFD> <work directory>
//
// Airfoil μx = 0.1, μy = 0.05 (about 12 % thick, cambered), α = 4°, SU2 INC_EULER (FDS, MUSCL, no
// limiter), O-meshes from the conformal map with 96, 144, 216 cells around and 1.21× that radially,
// outer boundary 1000 chords away. Angle of attack by rotating the mesh, so lift is the y-force.
//
// Criterion, fixed before the first run:
//   |CL extrapolated − CL exact| ≤ GCI(CL fine) + 2 × farfield bias,
// farfield bias = the circulation the freestream boundary ignores, Γ / (2π R_far U), as a lift change:
// ≈ 0.05 %. Nothing else: the geometry is exact (conformal map), and inviscid flow reaches the Kutta
// condition at a cusp by itself.
// Exploration before this test was fixed showed an observed order near 1.2, below the scheme's formal
// 2 — the cusped trailing edge is a singular point, and the spurious entropy it produces decays at
// the same rate (drag 0.011 → 0.004 over four meshes). The GCI band is correspondingly wide (a few %),
// which is the honest statement about these meshes, not a loosened tolerance.
// Also required: every run converged (pressure residual down to 1e-12) and spurious drag decreasing
// with refinement.

#include "fea_test_support.hpp"

#include "cadnext/cfd/Joukowski.hpp"
#include "cadnext/cfd/Su2Case.hpp"
#include "cadnext/fea/Convergence.hpp"

#include <cmath>
#include <filesystem>

using namespace cadnext::cfd;
using fea_test::check;

namespace {

Su2Config inviscidIncompressible() {
    Su2Config c;
    for (const auto& [key, value] : std::vector<std::pair<std::string, std::string>>{
             {"SOLVER", "INC_EULER"}, {"MATH_PROBLEM", "DIRECT"},
             {"INC_DENSITY_MODEL", "CONSTANT"}, {"INC_DENSITY_INIT", "1.0"}, {"INC_VELOCITY_INIT", "( 1.0, 0.0, 0.0 )"},
             {"REF_ORIGIN_MOMENT_X", "0.25"}, {"REF_ORIGIN_MOMENT_Y", "0.0"}, {"REF_ORIGIN_MOMENT_Z", "0.0"},
             {"REF_LENGTH", "1.0"}, {"REF_AREA", "1.0"},
             {"MARKER_EULER", "( airfoil )"}, {"MARKER_FAR", "( farfield )"},
             {"MARKER_MONITORING", "( airfoil )"}, {"MARKER_PLOTTING", "( airfoil )"},
             // Green–Gauss: least-squares gradients diverged on the stretched cells at the cusp.
             {"NUM_METHOD_GRAD", "GREEN_GAUSS"},
             {"CONV_NUM_METHOD_FLOW", "FDS"}, {"MUSCL_FLOW", "YES"}, {"SLOPE_LIMITER_FLOW", "NONE"},
             {"TIME_DISCRE_FLOW", "EULER_IMPLICIT"}, {"CFL_NUMBER", "10"}, {"CFL_ADAPT", "YES"},
             {"CFL_ADAPT_PARAM", "( 0.5, 1.5, 10.0, 1e4 )"},
             {"LINEAR_SOLVER", "FGMRES"}, {"LINEAR_SOLVER_PREC", "ILU"}, {"LINEAR_SOLVER_ERROR", "1E-4"}, {"LINEAR_SOLVER_ITER", "20"},
             {"ITER", "4000"}, {"CONV_FIELD", "RMS_PRESSURE"}, {"CONV_RESIDUAL_MINVAL", "-12"},
             {"HISTORY_OUTPUT", "( ITER, RMS_RES, AERO_COEFF )"}, {"OUTPUT_FILES", "( SURFACE_CSV )"},
             {"MESH_FILENAME", "mesh.su2"}, {"MESH_FORMAT", "SU2"}, {"TABULAR_FORMAT", "CSV"}, {"CONV_FILENAME", "history"}}) {
        c.set(key, value);
    }
    return c;
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

    const JoukowskiAirfoil airfoil{0.1, 0.05};
    const double alpha = 4.0 * M_PI / 180.0;
    const double exact = airfoil.exactLiftCoefficient(alpha);
    const double farfieldChords = 1000.0;
    // Γ = CL·U·c/2; the boundary imposes U where the vortex induces Γ/(2πR): an angle change of that
    // over U, i.e. a lift change ΔCL/CL = Δα / tan(α + β).
    const double farfieldBias = (exact / 2.0) / (2.0 * M_PI * farfieldChords) / std::tan(alpha + airfoil.beta());
    std::printf("  exact CL %.8f, farfield bias %.4f %%\n", exact, 100.0 * farfieldBias);

    std::vector<double> lift, drag;
    std::vector<std::size_t> cells;
    bool converged = true;
    for (int n : {96, 144, 216}) {
        const auto directory = work / ("n" + std::to_string(n));
        std::filesystem::create_directories(directory);
        auto mesh = airfoil.oMesh(n, static_cast<int>(std::lround(1.21 * n)), farfieldChords);
        for (auto& p : mesh.points) {
            const double x = p[0], y = p[1];
            p[0] = x * std::cos(alpha) + y * std::sin(alpha);
            p[1] = -x * std::sin(alpha) + y * std::cos(alpha);
        }
        check(mesh.write((directory / "mesh.su2").string()), "mesh " + std::to_string(n) + " written");
        const auto run = runSu2(solver, directory.string(), inviscidIncompressible(), 10);
        if (!run.isOk()) {
            check(false, "SU2 run on mesh " + std::to_string(n), run.error().message);
            return fea_test::finish("test_cfd_joukowski_euler");
        }
        const auto& history = run.value().history;
        const double residual = history.last("rms[P]");
        std::printf("  mesh %d: %zu cells, CL %.8f, CD %.3e, rms[P] %.2f after %zu iterations\n", n, mesh.elements.size(),
                    history.last("CFy"), history.last("CFx"), residual, history.rows.size());
        converged = converged && run.value().exitStatus == 0 && residual <= -12.0 + 1e-6;
        lift.push_back(history.last("CFy"));
        drag.push_back(history.last("CFx"));
        cells.push_back(mesh.elements.size());
    }
    check(converged, "every run converged to a pressure residual of 1e-12");

    // 2D: r from the cell counts.
    const double r21 = std::sqrt(static_cast<double>(cells[2]) / cells[1]);
    const double r32 = std::sqrt(static_cast<double>(cells[1]) / cells[0]);
    const auto study = cadnext::fea::estimateConvergence(lift[2], lift[1], lift[0], r21, r32, 1.25, 2.0);
    std::printf("  CL: %s\n", study.describe().c_str());
    check(study.isUsable(), "lift converges monotonically");
    const double allowed = study.uncertaintyAbsolute + 2.0 * farfieldBias * exact;
    std::printf("  CL extrapolated %.8f, exact %.8f, difference %.4f %%, allowed %.4f %%\n", study.extrapolated, exact,
                100.0 * (study.extrapolated - exact) / exact, 100.0 * allowed / exact);
    check(std::fabs(study.extrapolated - exact) <= allowed, "extrapolated lift within the mesh band and the farfield bias of the exact value");
    check(std::fabs(drag[2]) < std::fabs(drag[1]) && std::fabs(drag[1]) < std::fabs(drag[0]),
          "spurious inviscid drag decreases with refinement (d'Alembert)");
    return fea_test::finish("test_cfd_joukowski_euler");
}
