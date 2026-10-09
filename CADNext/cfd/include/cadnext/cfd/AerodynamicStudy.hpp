#pragma once

#include "cadnext/cfd/Su2Case.hpp"
#include "cadnext/cfd/WallResolution.hpp"
#include "cadnext/fea/FeaJson.hpp"
#include <array>

namespace cadnext::cfd {

using Point3 = std::array<double, 3>;
using Json = fea::json::JsonValue;

// Geometry is rotated into an orthonormal, right-handed solver frame: X aft, Y right,
// Z up. Runtime moments are about aft (roll), right (pitch), up (yaw), positive by
// the right-hand rule, matching UAVsim. Coefficients refer to the declared point,
// not the current CG. All geometry and references are in metres.
struct AeroReference {
    double areaM2 = 0, spanM = 0, chordM = 0;
    Point3 momentCenterModelM{}; // Workbench: X left, Y up, Z forward
};
struct AeroSettings {
    std::string model = "urans_sst"; // euler, laminar, sst (steady), urans_sst (time-accurate)
    // How the wall is treated in a turbulent run: "resolved" meshes the viscous sublayer (y+ ≈ 1),
    // "functions" puts the first node in the logarithmic layer (y+ 30…300) and lets SU2's standard
    // wall function carry the stress and the turbulence variables. See WallResolution.hpp.
    std::string wallTreatment = "resolved";
    // Laminar–turbulent transition: "none" (SST alone: the boundary layer is turbulent from the
    // leading edge) or "lm" (Langtry–Menter γ-Reθ on top of SST: the layer starts laminar and
    // transitions where the model predicts, which below Re ≈ 10⁶ changes friction drag by tens of
    // per cent). Needs a resolved wall.
    std::string transition = "none";
    // Free-stream turbulence intensity, a fraction (0.01 = 1 %). With transition it decides where the
    // layer turns turbulent: a quiet atmosphere is ~0.05–0.1 %, a wind tunnel 0.05–1 %.
    double turbulenceIntensity = 0.01;
    std::vector<double> alphaDeg{0}, betaDeg{0}; // Cartesian product; ascending, no duplicates
    double speedMps = 20, densityKgM3 = 1.225, viscosityPaS = 1.7894e-5;
    AeroReference reference;
    int iterations = 2000, convergenceWindow = 100, threads = 2;
    // URANS: physical time is advanced with second-order dual-time stepping.
    // innerIterations converges every physical step; the final averagingSteps
    // are used for mean aerodynamic coefficients and stationarity checks.
    int timeSteps = 240, innerIterations = 25, averagingSteps = 80;
    double timeStepSeconds = 0.001;
    double residualTarget = -6, coefficientAbsoluteTolerance = 1e-4, coefficientRelativeTolerance = 1e-3;
    double timeoutSeconds = 3600;
    double farfieldLengths = 10, wallSizeM = 0, farfieldSizeM = 0, grading = 0.3;
    std::vector<double> layerHeightsM;
};
inline bool isUnsteady(const AeroSettings& settings) { return settings.model == "urans_sst"; }
inline bool isTurbulent(const AeroSettings& settings) { return settings.model == "sst" || settings.model == "urans_sst"; }
inline int aeroProgressTotal(const AeroSettings& settings) { return isUnsteady(settings) ? settings.timeSteps : settings.iterations; }
// The wall-clock limit one point starts with. A steady point is one march; a URANS point is
// timeSteps × innerIterations of them. Measured on four performance cores: 0.64 s per inner
// iteration on a 0.4 M-cell wing mesh, 27 % above a steady iteration there, which puts a 1.7 M-cell
// airframe mesh near 2.9 s and the default 240 × 30 near six hours. The steady hour would stop that
// run a sixth of the way in. The Workbench panel carries the same two numbers.
inline double defaultTimeoutSeconds(const std::string& model) { return model == "urans_sst" ? 28800 : 3600; }
// Changing the model moves the limit from one default to the other; a limit the analyst set stays.
inline double timeoutAfterModelChange(double current, const std::string& from, const std::string& to) {
    return current == defaultTimeoutSeconds(from) ? defaultTimeoutSeconds(to) : current;
}
struct AeroGeometry {
    std::string id, path, sha256;
};
struct AeroProxy {
    std::string id;
    Point3 centerModelM{}, sizeModelM{};
};
struct AeroJob {
    std::string solverPath, resultPath, workDirectory;
    std::string cadForward, cadUp;
    std::vector<AeroGeometry> geometry;
    std::vector<AeroProxy> proxies;
    AeroSettings settings;
};
struct AeroSample {
    double alphaDeg = 0, betaDeg = 0;
    double cl = 0, cd = 0, cm = 0, cy = 0, cRoll = 0, cYaw = 0;
    int iterations = 0;
    double residual = 0, coefficientSpread = 0;
    std::string directory;
    // Everything that makes these coefficients unusable: convergence, near-wall resolution, a model
    // that does not match the Reynolds number. A point with problems keeps its fields — they are
    // worth looking at — but never reaches the runtime table.
    std::vector<std::string> problems;
    WallResolution wall;
    bool usable() const { return problems.empty(); }
};

std::string validateAeroSettings(const AeroSettings& settings);
// Reynolds number of the reference chord.
double aeroReynolds(const AeroSettings& settings);
// Problems with the physical setup that no amount of iterations can fix (model against Reynolds
// number, first layer against the wall treatment). Empty when the setup is sound; the estimate uses
// flat-plate correlations, so it warns rather than refuses.
std::vector<std::string> aeroSetupProblems(const AeroSettings& settings, bool wallMeasured = false);
Result<AeroJob> parseAeroJob(const std::string& text, const std::string& baseDirectory);
Json aeroSettingsJson(const AeroSettings& settings);
Result<Point3> cadToSolver(const std::string& forward, const std::string& up, const Point3& point);
Point3 flowDirection(double alphaDeg, double betaDeg);
Su2Config aeroConfig(const AeroSettings& settings, double alphaDeg, double betaDeg, const std::vector<std::string>& walls);
// Hard failures (crash, timeout, cancellation, unusable history) fail; a converged-but-flawed point
// comes back with `problems` filled in. `surface` is the point's surface field, for y+.
Result<AeroSample> collectAeroSample(const Su2RunResult& run, const AeroSettings& settings, double alphaDeg, double betaDeg,
                                     const Su2History& surface = {});
Json aeroSampleJson(const AeroSample& sample);
Json aeroResultJson(const AeroJob& job, const std::vector<AeroSample>& samples, const std::string& solverVersion,
                    const std::string& mesherVersion, const std::string& error = "");
std::string aeroCapabilitiesJson();

} // namespace cadnext::cfd
