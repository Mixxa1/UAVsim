// Random vibration as the Workbench will call it: a job with "analysis": "random", the
// `cadnext_structural` process, a random result and its 3σ stress field.
//
//   cadnext_test_fea_random_study <path to cadnext_structural> <CADNext/fea/schema>
//
// Part: the beam of test_fea_random as a CAD solid (L = 1 m, 30 × 20 mm, steel), Netgen at 20, 12.5,
// 7.8 mm, root fully fixed, stresses excluded within 30 mm of it.
//
// Criteria, fixed before the first run:
//  1. Flat 0.01 g²/Hz over 5–150 Hz along z, ζ = 2 %, 10 modes, probe on the tip:
//     - RMS absolute tip acceleration within 2 % of the damped beam series (structured mesh: 0.05 %);
//     - RMS von Mises at the reported critical point within 3 % + its mesh uncertainty (when known) of
//       E·(h/2)·√∫|w″(x)|²S df;
//     - the 3σ metric is exactly three times the RMS, the verdict WARNING with the fatigue reason, the
//       modes carry ≥ 90 % of the mass;
//     - result keys match schema/random-result.example.json.
//  2. Parsing: static loads, a missing ζ and a one-point spectrum are refused; the example job
//     round-trips.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/RandomVibration.hpp"
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

std::string beamJob(const std::string& name, const std::string& supports, const std::string& exclusions, const std::string& random) {
    return std::string(R"({"schema": "cadnext-structural-job/1", "analysis": "random",
        "geometry": {"format": "brep", "path": "beam.brep"}, "material": "steel_4130", "factorOfSafety": 1.5,
        "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
        "loadCase": {"name": ")") + name + R"(", "supports": [)" + supports + R"(], "stressExclusions": [)" + exclusions + R"(]},
        "random": {)" + random + R"(},
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
    workDirectory = std::filesystem::temp_directory_path() / "cadnext_random_study_test";
    std::filesystem::remove_all(workDirectory);
    std::filesystem::create_directories(workDirectory);
    const auto steel = *findMaterial("steel_4130");
    const BeamSeries series(steel.youngsModulusPa, steel.densityKgPerM3, 40);

    // --- 2. Parsing.
    {
        const std::string base = R"({"schema": "cadnext-structural-job/1", "analysis": "random",
            "geometry": {"format": "brep", "path": "p.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": "x", "supports": [{"face": "face-0", "fix": ["x", "y", "z"]}]LOADS},
            "random": {"modeCount": 3DAMPING, "direction": [0, 0, 1], "accelerationPsd": PSD},
            "output": {"result": "r.json"}})";
        auto job = [&](const std::string& loads, const std::string& damping, const std::string& psd) {
            std::string text = base;
            text.replace(text.find("LOADS"), 5, loads);
            text.replace(text.find("DAMPING"), 7, damping);
            text.replace(text.find("PSD"), 3, psd);
            return parseStructuralJob(text, "/base");
        };
        check(job("", ", \"dampingRatio\": 0.02", "[[5, 1], [50, 1]]").isOk(), "a complete random job parses");
        check(!job(R"(, "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}])", ", \"dampingRatio\": 0.02", "[[5, 1], [50, 1]]").isOk(),
              "a random job carrying static loads is refused");
        check(!job("", "", "[[5, 1], [50, 1]]").isOk(), "damping has no default in a random job");
        check(!job("", ", \"dampingRatio\": 0.02", "[[5, 1]]").isOk(), "a one-point spectrum is refused");
        const auto example = parseStructuralJob(readText(schemaDirectory / "random-job.example.json"), schemaDirectory.string());
        check(example.isOk(), "schema/random-job.example.json parses", example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(example.value()), "/elsewhere");
            const bool same = back.isOk() && back.value().analysis == StructuralAnalysis::Random
                              && back.value().random.accelerationPsd.size() == example.value().random.accelerationPsd.size()
                              && back.value().random.accelerationPsd.back().amplitude == example.value().random.accelerationPsd.back().amplitude
                              && back.value().random.dampingRatio == example.value().random.dampingRatio
                              && back.value().random.probeFace == example.value().random.probeFace
                              && back.value().random.attachedMasses.size() == example.value().random.attachedMasses.size();
            check(same, "random job round-trips through the serializer");
        }
    }

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

    // --- 1. Flat spectrum against beam theory.
    const double level = 0.01 * kG * kG;
    char psd[128];
    std::snprintf(psd, sizeof psd, "[[5, %.10g], [150, %.10g]]", level, level);
    const std::string job = beamJob("table", R"({"face": ")" + root + R"(", "fix": ["x", "y", "z"]})", R"({"face": ")" + root + R"(", "distanceM": 0.03})",
                                    std::string(R"("modeCount": 10, "dampingRatio": 0.02, "direction": [0, 0, 1], "accelerationPsd": )") + psd
                                        + R"(, "probeFace": ")" + tip + R"(")");
    const int status = runJob("table", job);
    check(status == 0, "table: cadnext_structural completes (exit " + std::to_string(status) + ")");
    const JsonValue result = parseOrEmpty(readText(workDirectory / "table.result.json"));
    std::printf("  table: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
    check(result.stringOr("schema", "") == "cadnext-random-result/1" && result.stringOr("testType", "") == "modalVibration",
          "table: random result schema and test type");

    // Series mean squares, as in test_fea_random.
    auto meanSquare = [&](const std::function<double(double)>& integrand) {
        const int points = 200000;
        double total = 0.0, previous = 0.0, previousF = 0.0;
        for (int i = 0; i < points; ++i) {
            const double f = 5.0 * std::pow(150.0 / 5.0, static_cast<double>(i) / (points - 1));
            const double value = integrand(f) * level;
            if (i > 0) total += 0.5 * (value + previous) * (f - previousF);
            previous = value, previousF = f;
        }
        return total;
    };
    // BeamSeries::sum carries the 1 g amplitude; per unit base acceleration divide by g.
    const double tipReference = std::sqrt(meanSquare([&](double f) {
        const double w2 = std::pow(2 * M_PI * f, 2.0);
        return std::norm(1.0 - w2 * series.sum(kLength, f, false) / kG);
    }));
    const double tipRms = metric(result, "probeRmsAccelerationMps2");
    std::printf("  table: tip RMS acceleration %.4f g (series %.4f g, %+.3f %%)\n", tipRms / kG, tipReference / kG, 100 * (tipRms / tipReference - 1));
    check(std::fabs(tipRms / tipReference - 1) <= 0.02, "table: RMS tip acceleration within 2 % of the damped beam series");

    const JsonValue* critical = result.member("criticalRegion");
    const JsonValue* point = critical ? critical->member("point") : nullptr;
    const double x = point && point->arrayItems.size() == 3 ? point->arrayItems[0].numberValue : NAN;
    const double stressReference = steel.youngsModulusPa * 0.5 * kHeight
                                   * std::sqrt(meanSquare([&](double f) { return std::norm(series.sum(x, f, true) / kG); }));
    const double stress = metric(result, "rmsVonMisesPa");
    const double uncertainty = metric(result, "rmsVonMisesPa", "numericalUncertainty");
    std::printf("  table: RMS von Mises %.3f MPa ± %.3f at x = %.4f m (series %.3f MPa, %+.3f %%); 3σ %.3f MPa\n", stress / 1e6, uncertainty / 1e6, x,
                stressReference / 1e6, 100 * (stress / stressReference - 1), metric(result, "threeSigmaStressPa") / 1e6);
    check(std::fabs(stress - stressReference) <= 0.03 * stressReference + (std::isfinite(uncertainty) ? uncertainty : 0.0),
          "table: RMS von Mises within 3 % + mesh uncertainty of beam theory at the critical point");
    check(std::fabs(metric(result, "threeSigmaStressPa") - 3.0 * stress) <= 1e-9 * stress, "table: the 3σ metric is three times the RMS");
    check(result.stringOr("outcome", "") == "warning" && contains(result, "warnings", "усталость не оценена"),
          "table: WARNING, fatigue named");
    check(metric(result, "effectiveMassFraction") >= 0.9, "table: modes carry ≥ 90 % of the mass");
    const JsonValue field = parseOrEmpty(readText(workDirectory / "table.field.json"));
    const JsonValue* vibration = field.member("vibration");
    check(vibration && vibration->stringOr("stress", "") == "threeSigmaRmsVonMises", "table: the field says its stress is 3σ");

    const JsonValue fixture = parseOrEmpty(readText(schemaDirectory / "random-result.example.json"));
    const bool sameKeys = keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                          && keys(result.member("spectra")) == keys(fixture.member("spectra"));
    check(sameKeys, "random result keys (top level, metrics, spectra) match schema/random-result.example.json");
    if (!sameKeys) {
        writeText(workDirectory / "random-result.produced.json", readText(workDirectory / "table.result.json"));
        std::printf("  produced result kept at %s\n", (workDirectory / "random-result.produced.json").c_str());
    }
    return fea_test::finish("test_fea_random_study");
}
