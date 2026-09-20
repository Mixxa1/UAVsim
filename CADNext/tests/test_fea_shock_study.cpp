// Mechanical shock as the Workbench will call it: "analysis": "shock", the `cadnext_structural`
// process, a shock result with its histories and the field at the worst instant.
//
//   cadnext_test_fea_shock_study <path to cadnext_structural> <CADNext/fea/schema>
//
// Part: the beam of test_fea_shock as a CAD solid (L = 1 m, 30 × 20 mm, steel), Netgen at 20, 12.5,
// 7.8 mm, root fully fixed, stresses excluded within 30 mm of it; 20 g × 11 ms half-sine along z,
// ζ = 2 %, 10 modes, probe on the tip.
//
// Criteria, fixed before the first run (as for the sine test on the same part):
//  - peak relative tip displacement within 2 % of the Euler–Bernoulli series (modes by Runge–Kutta);
//  - peak von Mises at the reported critical point and instant within 3 % + its mesh uncertainty
//    (when known) of E·(h/2)·|w″(x, t)| of the series;
//  - the verdict is not FAIL and carries no fatigue reason (a shock is one event), the modes carry
//    ≥ 90 % of the mass, the result keys match schema/shock-result.example.json;
//  - parsing refuses static loads, a missing ζ and an overlapping trapezoid; no supports → ERROR.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Shock.hpp"
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


std::string beamJob(const std::string& name, const std::string& supports, const std::string& exclusions, const std::string& shock) {
    return std::string(R"({"schema": "cadnext-structural-job/1", "analysis": "shock",
        "geometry": {"format": "brep", "path": "beam.brep"}, "material": "steel_4130", "factorOfSafety": 1.5,
        "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
        "loadCase": {"name": ")") + name + R"(", "supports": [)" + supports + R"(], "stressExclusions": [)" + exclusions + R"(]},
        "shock": {)" + shock + R"(},
        "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
}

// Fourth-order Runge–Kutta for q̈ + 2ζωq̇ + ω²q = f(t) from rest, sampled every `every` steps.
std::vector<double> rungeKutta(double omega, double zeta, const std::function<double(double)>& f, double end, double h, int every) {
    std::vector<double> out;
    double q = 0.0, v = 0.0, t = 0.0;
    auto acc = [&](double tt, double qq, double vv) { return f(tt) - 2.0 * zeta * omega * vv - omega * omega * qq; };
    const long steps = static_cast<long>(std::ceil(end / h));
    for (long i = 0; i <= steps; ++i) {
        if (i % every == 0) out.push_back(q);
        const double k1q = v, k1v = acc(t, q, v);
        const double k2q = v + 0.5 * h * k1v, k2v = acc(t + 0.5 * h, q + 0.5 * h * k1q, v + 0.5 * h * k1v);
        const double k3q = v + 0.5 * h * k2v, k3v = acc(t + 0.5 * h, q + 0.5 * h * k2q, v + 0.5 * h * k2v);
        const double k4q = v + h * k3v, k4v = acc(t + h, q + h * k3q, v + h * k3v);
        q += h / 6.0 * (k1q + 2 * k2q + 2 * k3q + k4q);
        v += h / 6.0 * (k1v + 2 * k2v + 2 * k3v + k4v);
        t += h;
    }
    return out;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::printf("usage: %s <cadnext_structural> <schema directory>\n", argv[0]);
        return 64;
    }
    cli = argv[1];
    const std::filesystem::path schemaDirectory = argv[2];
    workDirectory = std::filesystem::temp_directory_path() / "cadnext_shock_study_test";
    std::filesystem::remove_all(workDirectory);
    std::filesystem::create_directories(workDirectory);
    const auto steel = *findMaterial("steel_4130");
    const BeamSeries series(steel.youngsModulusPa, steel.densityKgPerM3, 30);

    // --- Parsing.
    {
        const std::string base = R"({"schema": "cadnext-structural-job/1", "analysis": "shock",
            "geometry": {"format": "brep", "path": "p.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": "x", "supports": [{"face": "face-0", "fix": ["x", "y", "z"]}]LOADS},
            "shock": {"modeCount": 3DAMPING, "direction": [0, 0, 1], "pulse": PULSE},
            "output": {"result": "r.json"}})";
        auto job = [&](const std::string& loads, const std::string& damping, const std::string& pulse) {
            std::string text = base;
            text.replace(text.find("LOADS"), 5, loads);
            text.replace(text.find("DAMPING"), 7, damping);
            text.replace(text.find("PULSE"), 5, pulse);
            return parseStructuralJob(text, "/base");
        };
        const std::string halfSine = R"({"shape": "halfSine", "peakMps2": 196, "durationS": 0.011})";
        const auto good = job("", ", \"dampingRatio\": 0.02", halfSine);
        check(good.isOk(), "a complete shock job parses", good.isOk() ? "" : good.error().message);
        if (good.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(good.value()), "/elsewhere");
            check(back.isOk() && back.value().analysis == StructuralAnalysis::Shock && back.value().shock.pulse.durationS == 0.011
                      && back.value().shock.pulse.peakMs2 == 196.0,
                  "shock job round-trips through the serializer");
        }
        check(!job(R"(, "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}])", ", \"dampingRatio\": 0.02", halfSine).isOk(),
              "a shock job carrying static loads is refused");
        check(!job("", "", halfSine).isOk(), "damping has no default in a shock job");
        check(!job("", ", \"dampingRatio\": 0.02", R"({"shape": "trapezoid", "peakMps2": 100, "durationS": 0.01, "riseS": 0.006, "fallS": 0.006})").isOk(),
              "an overlapping trapezoid is refused");
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
    const std::string clamp = R"({"face": ")" + root + R"(", "fix": ["x", "y", "z"]})";

    const ShockPulse pulse{PulseShape::HalfSine, 20.0 * kG, 0.011};
    const std::string job = beamJob("drop", clamp, R"({"face": ")" + root + R"(", "distanceM": 0.03})",
                                    R"("modeCount": 10, "dampingRatio": 0.02, "direction": [0, 0, 1],
                                        "pulse": {"shape": "halfSine", "peakMps2": )" + std::to_string(20.0 * kG) + R"(, "durationS": 0.011},
                                        "probeFace": ")" + tip + R"(")");
    const int status = runJob("drop", job);
    check(status == 0, "drop: cadnext_structural completes (exit " + std::to_string(status) + ")");
    const JsonValue result = parseOrEmpty(readText(workDirectory / "drop.result.json"));
    std::printf("  drop: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
    check(result.stringOr("schema", "") == "cadnext-shock-result/1" && result.stringOr("testType", "") == "mechanicalShock",
          "drop: shock result schema and test type");

    // Series: modes by RK4 over the result's window, tip displacement and curvature histories.
    std::vector<double> times;
    if (const JsonValue* history = result.member("history"); history && history->member("timeS"))
        for (const auto& v : history->member("timeS")->arrayItems) times.push_back(v.numberValue);
    const double window = times.empty() ? 0.2 : times.back();
    const double h = 2e-6;
    const int every = 5;
    std::vector<std::vector<double>> modal;
    for (const auto& mode : series.modes)
        modal.push_back(rungeKutta(mode.omega, kZeta, [&](double t) { return -mode.gamma * pulse.at(t) / kG; }, window, h, every));
    // (BeamSeries carries the 1 g factor in `sum`; the RK4 force above is per unit g, scaled back below.)
    auto seriesAt = [&](double x, bool curvature, std::size_t i) {
        double total = 0.0;
        for (std::size_t m = 0; m < series.modes.size(); ++m)
            if (i < modal[m].size()) total += series.modes[m].scale * (curvature ? series.modes[m].curvature(x) : series.modes[m].shape(x)) * modal[m][i] * kG;
        return total;
    };
    double tipPeak = 0.0;
    for (std::size_t i = 0; i < modal[0].size(); ++i) tipPeak = std::max(tipPeak, std::fabs(seriesAt(kLength, false, i)));
    const double fePeak = metric(result, "peakProbeDisplacementM");
    std::printf("  drop: tip peak %.5e m (series %.5e, %+.3f %%)\n", fePeak, tipPeak, 100 * (fePeak / tipPeak - 1));
    check(std::fabs(fePeak / tipPeak - 1) <= 0.02, "drop: peak tip displacement within 2 % of the beam series");

    const JsonValue* critical = result.member("criticalRegion");
    const JsonValue* point = critical ? critical->member("point") : nullptr;
    const double x = point && point->arrayItems.size() == 3 ? point->arrayItems[0].numberValue : NAN;
    const double t = critical ? critical->numberOr("timeS", NAN) : NAN;
    const std::size_t index = static_cast<std::size_t>(std::lround(t / (every * h)));
    const double reference = steel.youngsModulusPa * 0.5 * kHeight * std::fabs(seriesAt(x, true, index));
    const double stress = metric(result, "peakStressPa");
    const double uncertainty = metric(result, "peakStressPa", "numericalUncertainty");
    std::printf("  drop: peak stress %.3f MPa ± %.3f at x = %.4f m, t = %.3f ms (series %.3f MPa, %+.3f %%)\n", stress / 1e6, uncertainty / 1e6, x,
                1e3 * t, reference / 1e6, 100 * (stress / reference - 1));
    check(std::fabs(stress - reference) <= 0.03 * reference + (std::isfinite(uncertainty) ? uncertainty : 0.0),
          "drop: peak stress within 3 % + mesh uncertainty of beam theory at the critical point and instant");
    check(result.stringOr("outcome", "") != "fail" && !contains(result, "warnings", "усталость"), "drop: not FAIL, no fatigue reason (one event)");
    check(metric(result, "effectiveMassFraction") >= 0.9, "drop: modes carry ≥ 90 % of the mass");
    const JsonValue field = parseOrEmpty(readText(workDirectory / "drop.field.json"));
    check(field.member("shock") && std::fabs(field.member("shock")->numberOr("timeS", -1) - t) < 1e-12, "drop: the field is the worst instant's");

    const JsonValue fixture = parseOrEmpty(readText(schemaDirectory / "shock-result.example.json"));
    const bool sameKeys = keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                          && keys(result.member("history")) == keys(fixture.member("history"));
    check(sameKeys, "shock result keys (top level, metrics, history) match schema/shock-result.example.json");
    if (!sameKeys) {
        writeText(workDirectory / "shock-result.produced.json", readText(workDirectory / "drop.result.json"));
        std::printf("  produced result kept at %s\n", (workDirectory / "shock-result.produced.json").c_str());
    }

    const int loose = runJob("loose", beamJob("loose", "", "", R"("modeCount": 3, "dampingRatio": 0.02, "direction": [0, 0, 1],
                                                            "pulse": {"shape": "halfSine", "peakMps2": 100, "durationS": 0.01})"));
    const JsonValue looseResult = parseOrEmpty(readText(workDirectory / "loose.result.json"));
    check(loose == 2 && contains(looseResult, "failureReasons", "опор"), "no supports → ERROR with the reason, exit 2");
    return fea_test::finish("test_fea_shock_study");
}
