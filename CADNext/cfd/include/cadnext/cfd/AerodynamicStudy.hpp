#pragma once

#include "cadnext/cfd/Su2Case.hpp"
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
    std::string model = "sst"; // euler, laminar, sst; steady incompressible, clean airframe
    std::vector<double> alphaDeg{0}, betaDeg{0}; // Cartesian product; ascending, no duplicates
    double speedMps = 20, densityKgM3 = 1.225, viscosityPaS = 1.7894e-5;
    AeroReference reference;
    int iterations = 2000, convergenceWindow = 100, threads = 2;
    double residualTarget = -6, coefficientAbsoluteTolerance = 1e-4, coefficientRelativeTolerance = 1e-3;
    double timeoutSeconds = 3600;
    double farfieldLengths = 10, wallSizeM = 0, farfieldSizeM = 0, grading = 0.3;
    std::vector<double> layerHeightsM;
};
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
};

std::string validateAeroSettings(const AeroSettings& settings);
Result<AeroJob> parseAeroJob(const std::string& text, const std::string& baseDirectory);
Json aeroSettingsJson(const AeroSettings& settings);
Result<Point3> cadToSolver(const std::string& forward, const std::string& up, const Point3& point);
Point3 flowDirection(double alphaDeg, double betaDeg);
Su2Config aeroConfig(const AeroSettings& settings, double alphaDeg, double betaDeg, const std::vector<std::string>& walls);
Result<AeroSample> collectAeroSample(const Su2RunResult& run, const AeroSettings& settings, double alphaDeg, double betaDeg);
Json aeroSampleJson(const AeroSample& sample);
Json aeroResultJson(const AeroJob& job, const std::vector<AeroSample>& samples, const std::string& solverVersion,
                    const std::string& mesherVersion, const std::string& error = "");
std::string aeroCapabilitiesJson();

} // namespace cadnext::cfd
