// Sine vibration as the Workbench will call it: a job file with "analysis": "harmonic", the
// `cadnext_structural` process, a harmonic result and a stress field.
//
//   cadnext_test_fea_harmonic_study <path to cadnext_structural> <CADNext/fea/schema>
//
// Part: the beam of test_fea_harmonic as a CAD solid, L = 1 m, b = 30 mm (y) × h = 20 mm (z), steel,
// meshed by Netgen at 20 mm, 12.5 mm, 7.8 mm, root face fully fixed (the shaker fixture).
//
// Criteria, fixed before the first run:
//  1. Base excitation 1 g along z, ζ = 2 %, 10 modes, 5…60 Hz, probe on the tip face, stresses
//     excluded within 30 mm of the root (the clamp's singular edge):
//     - absolute tip acceleration at the resonance within 2 % of the damped Euler–Bernoulli series
//       (the structured mesh of test_fea_harmonic gave 0.33 %; unstructured CAD meshes get more room);
//     - peak dynamic stress within 3 % + the reported mesh uncertainty of E·(h/2)·|w″(x)| of the series
//       at the reported critical point and frequency — 1.5 h from the clamp its 3D stiffening has not
//       fully decayed;
//     - verdict WARNING with the fatigue reason (never PASS in this version), not FAIL (the stress is
//       well under yield), and no modal-mass warning (10 modes carry more than 90 % along z).
//  2. The same with 3 modes and 5…120 Hz: the range passes the last computed mode (103 Hz) and the
//     modes carry about 80 % of the mass → WARNING naming both.
//  3. A rotor imbalance U on the tip face: the excitation column is U·(2πf)² exactly (one run, no
//     solver repeatability involved) and no modal-mass metric is invented for a force.
//  4. No supports → ERROR, exit 2, with the reason.
//  5. In-process: parsing refuses static loads and a missing ζ in a harmonic job, the example job
//     round-trips, result keys match schema/harmonic-result.example.json (the Swift side's fixture).

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
#include <complex>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <set>
#include <sys/wait.h>

using namespace cadnext;
using namespace cadnext::fea;
using fea_test::check;
using json::JsonValue;

namespace {

std::string cli;
std::filesystem::path workDirectory;

constexpr double kLength = 1.0;
constexpr double kWidth = 0.03;
constexpr double kHeight = 0.02;
constexpr double kZeta = 0.02;
constexpr double kG = 9.80665;

std::string readText(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

void writeText(const std::filesystem::path& path, const std::string& text) { std::ofstream(path, std::ios::binary | std::ios::trunc) << text; }

JsonValue parseOrEmpty(const std::string& text) {
    JsonValue value;
    std::string error;
    json::parseJson(text, value, error);
    return value;
}

int runJob(const std::string& name, const std::string& jobJson) {
    const auto jobPath = workDirectory / (name + ".job.json");
    writeText(jobPath, jobJson);
    const std::string command = "\"" + cli + "\" \"" + jobPath.string() + "\" > /dev/null";
    const int status = std::system(command.c_str());
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

std::set<std::string> keys(const JsonValue* object) {
    std::set<std::string> result;
    if (object != nullptr)
        for (const auto& [key, value] : object->objectMembers) result.insert(key);
    return result;
}

bool contains(const JsonValue& result, const std::string& list, const std::string& fragment) {
    const JsonValue* items = result.member(list);
    if (items == nullptr) return false;
    for (const auto& item : items->arrayItems)
        if (item.stringValue.find(fragment) != std::string::npos) return true;
    return false;
}

std::string joined(const JsonValue& result, const std::string& list) {
    std::string text;
    if (const JsonValue* items = result.member(list))
        for (const auto& item : items->arrayItems) text += " [" + item.stringValue + "]";
    return text;
}

double metric(const JsonValue& result, const std::string& name, const char* field = "value") {
    const JsonValue* metrics = result.member("metrics");
    const JsonValue* m = metrics ? metrics->member(name) : nullptr;
    return m ? m->numberOr(field, NAN) : NAN;
}

std::vector<double> column(const JsonValue& result, const std::string& name) {
    std::vector<double> out;
    const JsonValue* response = result.member("response");
    const JsonValue* values = response ? response->member(name) : nullptr;
    if (values)
        for (const auto& v : values->arrayItems) out.push_back(v.numberValue);
    return out;
}

// The damped Euler–Bernoulli cantilever of test_fea_harmonic, evaluated without cancellation.
struct BeamSeries {
    struct Mode {
        double beta, sigma, omega, scale, gamma;
        double g(double z) const {
            const double bl = beta * kLength, e = std::exp(-bl);
            return 0.5 * std::exp(-z) * (1.0 + sigma) + std::exp(z - bl) * (std::sin(bl) - std::cos(bl) - e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
        }
        double shape(double x) const { return g(beta * x) - std::cos(beta * x) + sigma * std::sin(beta * x); }
        double curvature(double x) const { return beta * beta * (g(beta * x) + std::cos(beta * x) - sigma * std::sin(beta * x)); }
    };
    std::vector<Mode> modes;
    BeamSeries(double E, double rho, int count) {
        const double A = kWidth * kHeight, I = kWidth * kHeight * kHeight * kHeight / 12.0;
        for (int n = 1; n <= count; ++n) {
            double bl = n == 1 ? 1.875 : (2 * n - 1) * M_PI / 2.0;
            for (int i = 0; i < 50; ++i) bl -= (std::cos(bl) + 1.0 / std::cosh(bl)) / (-std::sin(bl) - std::tanh(bl) / std::cosh(bl));
            Mode mode{bl / kLength, 0, 0, 0, 0};
            const double e = std::exp(-bl);
            mode.sigma = (1.0 + e * e + 2.0 * std::cos(bl) * e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
            const int intervals = 20000;
            double squared = 0.0, plain = 0.0;
            for (int i = 0; i <= intervals; ++i) {
                const double x = kLength * i / intervals, w = (i == 0 || i == intervals) ? 1.0 : (i % 2 ? 4.0 : 2.0);
                squared += w * mode.shape(x) * mode.shape(x);
                plain += w * mode.shape(x);
            }
            squared *= kLength / (3.0 * intervals);
            plain *= kLength / (3.0 * intervals);
            mode.scale = 1.0 / std::sqrt(rho * A * squared);
            mode.omega = bl * bl / (kLength * kLength) * std::sqrt(E * I / (rho * A));
            mode.gamma = rho * A * mode.scale * plain;
            modes.push_back(mode);
        }
    }
    std::complex<double> sum(double x, double f, bool curvature) const {
        std::complex<double> total = 0.0;
        const double w = 2.0 * M_PI * f;
        for (const auto& m : modes)
            total += -kG * m.scale * (curvature ? m.curvature(x) : m.shape(x)) * m.gamma
                     / std::complex<double>(m.omega * m.omega - w * w, 2 * kZeta * m.omega * w);
        return total;
    }
    double tipAcceleration(double f) const {
        const double w = 2.0 * M_PI * f;
        return std::abs(kG - w * w * sum(kLength, f, false));
    }
};

std::string faceWhere(const std::vector<kernel::FaceReference>& faces, const std::function<bool(const kernel::FaceReference&)>& predicate) {
    for (const auto& face : faces)
        if (predicate(face)) return face.faceId.substr(0, face.faceId.find('-', 5));
    return "face-not-found";
}

std::string beamJob(const std::string& name, const std::string& supports, const std::string& exclusions, const std::string& harmonic) {
    return std::string(R"({"schema": "cadnext-structural-job/1", "analysis": "harmonic",
        "geometry": {"format": "brep", "path": "beam.brep"}, "material": "steel_4130", "factorOfSafety": 1.5,
        "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
        "loadCase": {"name": ")") + name + R"(", "supports": [)" + supports + R"(], "stressExclusions": [)" + exclusions + R"(]},
        "harmonic": {)" + harmonic + R"(},
        "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::printf("usage: %s <cadnext_structural> <schema directory>\n", argv[0]);
        return 64;
    }
    cli = argv[1];
    const std::filesystem::path schemaDirectory = argv[2];
    workDirectory = std::filesystem::temp_directory_path() / "cadnext_harmonic_study_test";
    std::filesystem::remove_all(workDirectory);
    std::filesystem::create_directories(workDirectory);
    const auto steel = *findMaterial("steel_4130");
    const BeamSeries series(steel.youngsModulusPa, steel.densityKgPerM3, 40);

    // --- 5. Parsing and the job serializer.
    {
        const std::string loaded = R"({"schema": "cadnext-structural-job/1", "analysis": "harmonic",
            "geometry": {"format": "brep", "path": "p.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": "x", "supports": [{"face": "face-0", "fix": ["x", "y", "z"]}], "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}]},
            "harmonic": {"modeCount": 3, "dampingRatio": 0.02, "frequencyRangeHz": [5, 50],
                         "excitation": {"kind": "base", "direction": [0, 0, 1], "amplitude": [[1, 9.8]]}},
            "output": {"result": "r.json"}})";
        const auto refused = parseStructuralJob(loaded, "/base");
        check(!refused.isOk() && refused.error().message.find("статические нагрузки") != std::string::npos,
              "a harmonic job carrying static loads is refused", refused.isOk() ? "accepted" : refused.error().message);
        std::string noDamping = loaded;
        noDamping.replace(noDamping.find(R"(, "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}])"),
                          std::string(R"(, "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}])").size(), "");
        noDamping.replace(noDamping.find(R"("dampingRatio": 0.02, )"), std::string(R"("dampingRatio": 0.02, )").size(), "");
        const auto undamped = parseStructuralJob(noDamping, "/base");
        check(!undamped.isOk() && undamped.error().message.find("dampingRatio") != std::string::npos,
              "damping has no default in a job either", undamped.isOk() ? "accepted" : undamped.error().message);

        const auto example = parseStructuralJob(readText(schemaDirectory / "harmonic-job.example.json"), schemaDirectory.string());
        check(example.isOk(), "schema/harmonic-job.example.json parses", example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(example.value()), "/elsewhere");
            bool same = back.isOk() && back.value().analysis == StructuralAnalysis::Harmonic;
            if (same) {
                const auto& a = example.value().harmonic;
                const auto& b = back.value().harmonic;
                same = a.modeCount == b.modeCount && a.dampingRatio == b.dampingRatio && a.minimumHz == b.minimumHz
                       && a.maximumHz == b.maximumHz && a.sweepPoints == b.sweepPoints && a.probeFace == b.probeFace
                       && a.excitation.kind == b.excitation.kind && a.excitation.amplitude.size() == b.excitation.amplitude.size()
                       && a.excitation.amplitude.back().amplitude == b.excitation.amplitude.back().amplitude
                       && a.attachedMasses.size() == b.attachedMasses.size()
                       && back.value().loadCase.stressExclusions.size() == example.value().loadCase.stressExclusions.size();
            }
            check(same, "harmonic job round-trips through the serializer");
        }
    }

    // The beam as a CAD part; faces found on the re-imported file, as a user picking them would.
    kernel::OcctKernel kernel;
    const auto bar = kernel.makeExtrudedPolygon({{{0, 0, 0}, {0, kWidth, 0}, {0, kWidth, kHeight}, {0, 0, kHeight}}, {kLength, 0, 0}});
    {
        const auto brep = kernel.exportBRep(bar.value());
        std::ofstream(workDirectory / "beam.brep", std::ios::binary)
            .write(reinterpret_cast<const char*>(brep.value().data()), static_cast<std::streamsize>(brep.value().size()));
    }
    const std::string bytes = readText(workDirectory / "beam.brep");
    const auto reimported = kernel.importBRep(std::vector<std::uint8_t>(bytes.begin(), bytes.end()));
    const auto faces = kernel::FaceAnalyzer(kernel).planarFacesForBody("part", reimported.value());
    const std::string root = faceWhere(faces, [](const auto& f) { return std::fabs(f.origin.x) < 1e-9 && std::fabs(std::fabs(f.normal.x) - 1) < 1e-9; });
    const std::string tip = faceWhere(faces, [](const auto& f) { return std::fabs(f.origin.x - kLength) < 1e-9 && std::fabs(std::fabs(f.normal.x) - 1) < 1e-9; });
    const std::string clamp = R"({"face": ")" + root + R"(", "fix": ["x", "y", "z"]})";
    const std::string exclusion = R"({"face": ")" + root + R"(", "distanceM": 0.03})";

    // --- 1. Base excitation against beam theory.
    {
        const std::string job = beamJob("shaker", clamp, exclusion,
                                        R"("modeCount": 10, "dampingRatio": 0.02, "frequencyRangeHz": [5, 60], "sweepPoints": 60,
                                            "excitation": {"kind": "base", "direction": [0, 0, 1], "amplitude": [[1, 9.80665]]},
                                            "probeFace": ")" + tip + R"(")");
        const int status = runJob("shaker", job);
        check(status == 0, "shaker: cadnext_structural completes (exit " + std::to_string(status) + ")");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "shaker.result.json"));
        std::printf("  shaker: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
        check(result.stringOr("schema", "") == "cadnext-harmonic-result/1" && result.stringOr("testType", "") == "modalVibration",
              "shaker: harmonic result schema and test type");

        double beamPeak = 0.0;
        for (int k = -2000; k <= 2000; ++k) beamPeak = std::max(beamPeak, series.tipAcceleration(series.modes[0].omega / (2 * M_PI) * (1 + k * kZeta / 1000.0)));
        const double fePeak = metric(result, "peakProbeAccelerationMps2");
        std::printf("  shaker: tip acceleration at resonance %.4f m/s² (beam %.4f, %+.3f %%), transmissibility %.2f\n", fePeak, beamPeak,
                    100 * (fePeak / beamPeak - 1), fePeak / kG);
        check(std::fabs(fePeak / beamPeak - 1) <= 0.02, "shaker: tip acceleration at resonance within 2 % of the damped beam series");

        const JsonValue* critical = result.member("criticalRegion");
        const JsonValue* point = critical ? critical->member("point") : nullptr;
        const double x = point && point->arrayItems.size() == 3 ? point->arrayItems[0].numberValue : NAN;
        const double f = critical ? critical->numberOr("frequencyHz", NAN) : NAN;
        const double stress = metric(result, "peakDynamicStressPa");
        const double uncertainty = metric(result, "peakDynamicStressPa", "numericalUncertainty");
        const double reference = steel.youngsModulusPa * 0.5 * kHeight * std::abs(series.sum(x, f, true));
        std::printf("  shaker: peak dynamic stress %.3f MPa ± %.3f at x = %.4f m, %.3f Hz; beam %.3f MPa (%+.3f %%)\n", stress / 1e6,
                    uncertainty / 1e6, x, f, reference / 1e6, 100 * (stress / reference - 1));
        // The maximum sits at the first node past the exclusion zone, whose x differs from mesh to mesh,
        // so its convergence is not monotonic and the study reports no uncertainty — and says so.
        const double band = std::isfinite(uncertainty) ? uncertainty : 0.0;
        check(std::fabs(stress - reference) <= 0.03 * reference + band,
              "shaker: peak dynamic stress within 3 % + mesh uncertainty (when known) of beam theory at the critical point");
        check(std::isfinite(uncertainty) || contains(result, "warnings", "немонотонна"),
              "shaker: an unknown mesh uncertainty is named in the warnings, not left silent");
        check(x >= 0.03, "shaker: the maximum lies outside the exclusion zone");
        check(result.stringOr("outcome", "") == "warning" && contains(result, "warnings", "усталость не оценена")
                  && !contains(result, "warnings", "массы вдоль возбуждения"),
              "shaker: WARNING for unassessed fatigue only; 10 modes carry enough mass");
        check(metric(result, "effectiveMassFraction") >= 0.9, "shaker: effective mass fraction reported and ≥ 90 %");
        check(column(result, "frequencyHz").size() == column(result, "maxVonMisesPa").size() && column(result, "probeAccelerationMps2").size() > 60,
              "shaker: response columns present, the sweep refined through the resonance");

        const JsonValue field = parseOrEmpty(readText(workDirectory / "shaker.field.json"));
        const JsonValue* vibration = field.member("vibration");
        check(field.stringOr("schema", "") == "cadnext-structural-field/1" && vibration && std::fabs(vibration->numberOr("frequencyHz", 0) - f) < 1e-9,
              "shaker: stress field at the worst frequency, in the structural field format, naming that frequency");

        const JsonValue fixture = parseOrEmpty(readText(schemaDirectory / "harmonic-result.example.json"));
        const bool sameKeys = keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("response")) == keys(fixture.member("response"));
        check(sameKeys, "harmonic result keys (top level, metrics, response) match schema/harmonic-result.example.json");
        if (!sameKeys) {
            writeText(workDirectory / "harmonic-result.produced.json", readText(workDirectory / "shaker.result.json"));
            std::printf("  produced result kept at %s\n", (workDirectory / "harmonic-result.produced.json").c_str());
        }
    }

    // --- 2. Too few modes for the range.
    {
        const std::string job = beamJob("short", clamp, exclusion,
                                        R"("modeCount": 3, "dampingRatio": 0.02, "frequencyRangeHz": [5, 120], "sweepPoints": 40,
                                            "excitation": {"kind": "base", "direction": [0, 0, 1], "amplitude": [[1, 9.80665]]})");
        check(runJob("short", job) == 0, "short: completes");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "short.result.json"));
        std::printf("  short: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
        check(result.stringOr("outcome", "") == "warning" && contains(result, "warnings", "выше последней рассчитанной моды")
                  && contains(result, "warnings", "массы вдоль возбуждения"),
              "short: range above the last mode and too little modal mass are both named");
    }

    // --- 3. Rotor imbalance on the tip.
    {
        const double U = 2e-5;
        const std::string job = beamJob("imbalance", clamp, exclusion,
                                        R"("modeCount": 6, "dampingRatio": 0.02, "frequencyRangeHz": [5, 60], "sweepPoints": 30,
                                            "excitation": {"kind": "force", "face": ")" + tip + R"(", "direction": [0, 0, 1], "imbalanceKgM": 2e-5})");
        check(runJob("imbalance", job) == 0, "imbalance: completes");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "imbalance.result.json"));
        const auto f = column(result, "frequencyHz"), a = column(result, "excitation");
        bool law = !f.empty() && f.size() == a.size();
        for (std::size_t i = 0; law && i < f.size(); ++i) law = std::fabs(a[i] / (U * std::pow(2 * M_PI * f[i], 2)) - 1) < 1e-12;
        check(law, "imbalance: the force at every frequency is U·(2πf)²");
        check(std::isnan(metric(result, "effectiveMassFraction")), "imbalance: no modal-mass metric is invented for a force");
    }

    // --- 4. No fixture.
    {
        const int status = runJob("loose", beamJob("loose", "", "",
                                                    R"("modeCount": 3, "dampingRatio": 0.02, "frequencyRangeHz": [5, 60],
                                                        "excitation": {"kind": "base", "direction": [0, 0, 1], "amplitude": [[1, 9.8]]})"));
        const JsonValue result = parseOrEmpty(readText(workDirectory / "loose.result.json"));
        check(status == 2 && contains(result, "failureReasons", "опор"), "no supports → ERROR with the reason, exit 2");
    }
    return fea_test::finish("test_fea_harmonic_study");
}
