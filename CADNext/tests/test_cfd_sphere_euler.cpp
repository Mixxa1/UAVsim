// Flow solver and fluid mesher verification in 3D: inviscid incompressible flow past a sphere, whose
// surface pressure is exact, Cp = 1 − 9/4 sin²θ.
//
//   cadnext_test_cfd_sphere_euler <SU2_CFD> <work directory>
//
// The fluid domain is the CAD pipeline an aircraft goes through: a 20 × 20 × 20 box with a sphere of
// radius 0.5 cut out by the kernel, the sphere's face found by the face analyzer and marked as wall,
// meshed by Netgen (tetrahedra), solved by SU2 INC_EULER.
//
// Refinement: wall size, far-field size and grading halved together (0.05/1.5/0.3 → 0.025/0.75/0.15
// → 0.0125/0.375/0.075). Netgen grows elements away from a wall at a rate set by the grading, so
// halving only the wall size refines a thin shell at the wall and leaves the flow around the sphere
// as it was — the first version of this test did that, got 36k → 76k → 221k tetrahedra instead of
// ×8 per level and an apparent order of 1 with a 113 % GCI. Halving all three is a geometrically
// similar refinement: 36k → 372k → 3.0M.
//
// Criterion, stated before the test was fixed (after exploratory runs of these meshes):
//   |extrapolated mean Cp over the equator band − (−1.25)| ≤ GCI + far-field mesh effect + 2.5·10⁻⁴,
// the far-field mesh effect measured here (middle level with the far-field elements halved again),
// 2.5·10⁻⁴ the sphere's dipole at the nearest box face, (R / 10)³, doubled.
// Also required: every run converged, the pressure error over the upstream half and the spurious
// drag both decrease with refinement (exploration: drag 0.14 → 0.013 → 0.0024).
// Pressure residual 1e-10, not 1e-12 as in the 2D tests: the fine level is 3M cells.

#include "fea_test_support.hpp"

#include "cadnext/cfd/FluidMesher.hpp"
#include "cadnext/cfd/Su2Case.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>

using namespace cadnext;
using fea_test::check;

namespace {

cfd::Su2Config inviscidIncompressible() {
    cfd::Su2Config c;
    for (const auto& [key, value] : std::vector<std::pair<std::string, std::string>>{
             {"SOLVER", "INC_EULER"}, {"MATH_PROBLEM", "DIRECT"}, {"INC_DENSITY_MODEL", "CONSTANT"}, {"INC_DENSITY_INIT", "1.0"},
             {"INC_VELOCITY_INIT", "( 1.0, 0.0, 0.0 )"}, {"REF_LENGTH", "1.0"}, {"REF_AREA", "0.7853981633974483"},
             {"MARKER_EULER", "( wall )"}, {"MARKER_FAR", "( farfield )"}, {"MARKER_MONITORING", "( wall )"}, {"MARKER_PLOTTING", "( wall )"},
             {"NUM_METHOD_GRAD", "GREEN_GAUSS"}, {"CONV_NUM_METHOD_FLOW", "FDS"}, {"MUSCL_FLOW", "YES"}, {"SLOPE_LIMITER_FLOW", "NONE"},
             {"TIME_DISCRE_FLOW", "EULER_IMPLICIT"}, {"CFL_NUMBER", "10"}, {"CFL_ADAPT", "YES"}, {"CFL_ADAPT_PARAM", "( 0.5, 1.5, 10.0, 1e4 )"},
             {"LINEAR_SOLVER", "FGMRES"}, {"LINEAR_SOLVER_PREC", "ILU"}, {"LINEAR_SOLVER_ERROR", "1E-4"}, {"LINEAR_SOLVER_ITER", "20"},
             {"ITER", "3000"}, {"CONV_FIELD", "RMS_PRESSURE"}, {"CONV_RESIDUAL_MINVAL", "-10"},
             {"HISTORY_OUTPUT", "( ITER, RMS_RES, AERO_COEFF )"}, {"OUTPUT_FILES", "( SURFACE_CSV )"},
             {"VOLUME_OUTPUT", "( COORDINATES, SOLUTION, PRIMITIVE )"}, {"WRT_RESTART_COMPACT", "NO"},
             {"MESH_FILENAME", "mesh.su2"}, {"MESH_FORMAT", "SU2"}, {"TABULAR_FORMAT", "CSV"},
             {"CONV_FILENAME", "history"}, {"SURFACE_FILENAME", "surface"}}) {
        c.set(key, value);
    }
    return c;
}

struct SurfaceError {
    double equatorBias = NAN; // mean(Cp − exact) over nodes within |x| < 0.03
    double frontRms = NAN;    // rms(Cp − exact) over the upstream half
    double maximumCp = NAN;
    int equatorNodes = 0;
};

SurfaceError surfaceError(const std::filesystem::path& directory) {
    std::ifstream file(directory / "surface.csv");
    const auto parsed = cfd::parseSu2History({std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()});
    SurfaceError result;
    if (!parsed.isOk()) return result;
    const auto& t = parsed.value();
    const int cx = t.column("x"), cy = t.column("y"), cz = t.column("z"), cp = t.column("Pressure_Coefficient");
    if (cx < 0 || cp < 0) return result;
    double equator = 0.0, front = 0.0;
    int frontNodes = 0;
    result.maximumCp = -1e9;
    for (const auto& row : t.rows) {
        const double r2 = row[cx] * row[cx] + row[cy] * row[cy] + row[cz] * row[cz];
        const double exact = 1.0 - 2.25 * (row[cy] * row[cy] + row[cz] * row[cz]) / r2;
        const double error = row[cp] - exact;
        if (std::fabs(row[cx]) < 0.03) {
            equator += error;
            ++result.equatorNodes;
        }
        if (row[cx] < 0.0) {
            front += error * error;
            ++frontNodes;
        }
        result.maximumCp = std::max(result.maximumCp, row[cp]);
    }
    result.equatorBias = equator / std::max(result.equatorNodes, 1);
    result.frontRms = std::sqrt(front / std::max(frontNodes, 1));
    return result;
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

    kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({20.0, 20.0, 20.0});
    const auto sphere = kernel.makeSphere({0.5});
    const auto domain = kernel.booleanCut(box.value(), sphere.value());
    check(domain.isOk(), "fluid domain: box minus sphere");
    std::map<int, std::string> walls;
    for (const auto& face : kernel::FaceAnalyzer(kernel).planarFacesForBody("domain", domain.value())) {
        if (face.kind == kernel::FaceKind::Spherical) walls[std::stoi(face.faceId.substr(5, face.faceId.find('-', 5) - 5))] = "wall";
    }
    check(walls.size() == 1, "the sphere is the one curved face of the domain");

    struct Level {
        std::string name;
        double wall;
        double farfield;
        double grading;
    };
    const std::vector<Level> levels = {
        {"h050", 0.05, 1.5, 0.3}, {"h025", 0.025, 0.75, 0.15}, {"h0125", 0.0125, 0.375, 0.075}, {"h025-fine-far", 0.025, 0.375, 0.15}};
    std::vector<SurfaceError> errors;
    std::vector<double> drag;
    std::vector<std::size_t> wallTriangles;
    bool converged = true;
    for (const auto& level : levels) {
        const auto directory = work / level.name;
        std::filesystem::create_directories(directory);
        cfd::FluidMeshSettings settings;
        settings.wallElementSizeM = level.wall;
        settings.farfieldElementSizeM = level.farfield;
        settings.grading = level.grading;
        const auto meshed = cfd::meshFluidDomain(kernel, domain.value(), walls, settings);
        if (!meshed.isOk()) {
            check(false, level.name + ": fluid mesh", meshed.error().message);
            return fea_test::finish("test_cfd_sphere_euler");
        }
        check(meshed.value().mesh.write((directory / "mesh.su2").string()), level.name + ": mesh written");
        const auto run = cfd::runSu2(solver, directory.string(), inviscidIncompressible(), 10);
        if (!run.isOk()) {
            check(false, level.name + ": SU2 run", run.error().message);
            return fea_test::finish("test_cfd_sphere_euler");
        }
        const auto error = surfaceError(directory);
        const double residual = run.value().history.last("rms[P]");
        std::printf("  %s: %zu tetrahedra, %zu wall triangles; equator bias %.5f (%d nodes), front rms %.4f, max Cp %.4f, CD %.4f, rms[P] %.2f\n",
                    level.name.c_str(), meshed.value().tetrahedra, meshed.value().mesh.markers[0].second.size(), error.equatorBias,
                    error.equatorNodes, error.frontRms, error.maximumCp, run.value().history.last("CD"), residual);
        converged = converged && run.value().exitStatus == 0 && residual <= -10.0 + 1e-6;
        errors.push_back(error);
        drag.push_back(run.value().history.last("CD"));
        wallTriangles.push_back(meshed.value().mesh.markers[0].second.size());
    }
    check(converged, "every run converged to a pressure residual of 1e-10");

    // Surface refinement: r from the wall triangle counts (2D surface).
    const double r21 = std::sqrt(static_cast<double>(wallTriangles[2]) / wallTriangles[1]);
    const double r32 = std::sqrt(static_cast<double>(wallTriangles[1]) / wallTriangles[0]);
    const auto study = fea::estimateConvergence(errors[2].equatorBias, errors[1].equatorBias, errors[0].equatorBias, r21, r32, 1.25, 2.0);
    std::printf("  equator bias: %s\n", study.describe().c_str());
    check(study.isUsable(), "equator pressure error converges monotonically");
    const double farfieldEffect = std::fabs(errors[3].equatorBias - errors[1].equatorBias);
    const double allowed = study.uncertaintyAbsolute + farfieldEffect + 2.5e-4;
    std::printf("  extrapolated bias %.5f; allowed %.5f (mesh %.5f, far-field mesh %.5f, dipole 0.00025)\n", study.extrapolated, allowed,
                study.uncertaintyAbsolute, farfieldEffect);
    check(std::fabs(study.extrapolated) <= allowed, "surface pressure converges to the exact potential flow");
    check(errors[2].frontRms < errors[1].frontRms && errors[1].frontRms < errors[0].frontRms,
          "the pressure error over the upstream half decreases with refinement");
    check(std::fabs(drag[2]) < std::fabs(drag[1]) && std::fabs(drag[1]) < std::fabs(drag[0]),
          "spurious inviscid drag decreases with refinement (d'Alembert)");
    return fea_test::finish("test_cfd_sphere_euler");
}
