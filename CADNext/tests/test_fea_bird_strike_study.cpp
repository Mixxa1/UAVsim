// A bird into a part as the Workbench will call it: "analysis": "bird", the `cadnext_structural`
// process, a bird result with its load, its histories and the field at the worst instant.
//
//   cadnext_test_fea_bird_strike_study <path to cadnext_structural> <CADNext/fea/schema>
//
// Part: the beam of test_fea_shock_study as a CAD solid (L = 1 m, 30 × 20 mm, steel 4130), Netgen at
// 20, 12.5, 7.8 mm, root fully fixed, stresses excluded within 30 mm of it. A 50 g bird — a starling,
// not the 4-lb one of 25.571(e), which would take this bar off its root — at 90 m/s into the tip face
// along −z, ζ = 2 %, 10 modes.
//
// The reference is the Euler–Bernoulli cantilever under the same force history, its modal equations
// integrated by Runge–Kutta. Two decisions about that reference, both made before the first run:
//
//   - It keeps the modes the solver kept, not all it has. A 3D bar bends in both directions and
//     twists, so the solver's ten modes hold only the five or so that bend the way the bird pushes;
//     the series is given exactly those, identified by frequency. A series with thirty would measure
//     the truncation, not the solver, and the number printed alongside says how much that truncation
//     is worth.
//   - It carries the same static correction. The solver adds the static answer for the missing
//     modes; the series adds the closed-form one, w″ = (L − x)/EI for a unit tip force, minus what
//     the kept modes already provide. Without it the two models would not be the same model.
//
// Criteria, fixed before the first run:
//   1. Peak von Mises at the reported critical point and instant within 3 % + its mesh uncertainty
//      (when known) of E·(h/2)·|w″| of that series — the same bar as the shock study asks of itself.
//   2. The whole stress history, not just its peak: at every reported instant where the series is
//      above a quarter of its own peak, the two agree to 5 %. Below that the maximum wanders over
//      the part and comparing it means nothing.
//   3. The load the part actually received carries the bird's normal momentum to 0.1 % — end to end,
//      through the solver's time grid and the result file, not in the solver's own arithmetic.
//   4. The patch: the result reports the ratio of the struck face to the bird's own midsection, it
//      matches the geometry to 1e-6, and — the face here being smaller than the bird — the result
//      says so and does not use it to demote.
//   5. The result keys match schema/bird-result.example.json, schema/bird-job.example.json parses,
//      and the field is the worst instant's.
//   6. Parsing refuses static loads, a missing ζ, a missing face and a bird with no speed; a job
//      without supports ends in ERROR with the reason, exit 2.

#include "fea_test_support.hpp"

#include "cadnext/fea/BirdStrike.hpp"
#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
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
constexpr double kExclusion = 0.03;

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

std::vector<double> history(const JsonValue& result, const std::string& name) {
    std::vector<double> out;
    const JsonValue* block = result.member("history");
    const JsonValue* values = block ? block->member(name) : nullptr;
    if (values)
        for (const auto& v : values->arrayItems) out.push_back(v.numberValue);
    return out;
}

// The mass-normalised Euler–Bernoulli cantilever, evaluated without cancellation (as in the shock
// and harmonic tests), with what a unit tip force does to it.
struct BeamSeries {
    struct Mode {
        double beta, sigma, omega, scale;
        double g(double z) const {
            const double bl = beta * kLength, e = std::exp(-bl);
            return 0.5 * std::exp(-z) * (1.0 + sigma) + std::exp(z - bl) * (std::sin(bl) - std::cos(bl) - e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
        }
        double shape(double x) const { return g(beta * x) - std::cos(beta * x) + sigma * std::sin(beta * x); }
        double curvature(double x) const { return beta * beta * (g(beta * x) + std::cos(beta * x) - sigma * std::sin(beta * x)); }
    };
    std::vector<Mode> modes;
    double stiffness = 0.0; // EI
    BeamSeries(double E, double rho, int count) {
        const double A = kWidth * kHeight, I = kWidth * kHeight * kHeight * kHeight / 12.0;
        stiffness = E * I;
        for (int n = 1; n <= count; ++n) {
            double bl = n == 1 ? 1.875 : (2 * n - 1) * M_PI / 2.0;
            for (int i = 0; i < 50; ++i) bl -= (std::cos(bl) + 1.0 / std::cosh(bl)) / (-std::sin(bl) - std::tanh(bl) / std::cosh(bl));
            Mode mode{bl / kLength, 0, 0, 0};
            const double e = std::exp(-bl);
            mode.sigma = (1.0 + e * e + 2.0 * std::cos(bl) * e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
            const int intervals = 20000;
            double squared = 0.0;
            for (int i = 0; i <= intervals; ++i) {
                const double x = kLength * i / intervals, w = (i == 0 || i == intervals) ? 1.0 : (i % 2 ? 4.0 : 2.0);
                squared += w * mode.shape(x) * mode.shape(x);
            }
            squared *= kLength / (3.0 * intervals);
            mode.scale = 1.0 / std::sqrt(rho * A * squared);
            mode.omega = bl * bl / (kLength * kLength) * std::sqrt(E * I / (rho * A));
            modes.push_back(mode);
        }
    }
    // A unit tip force, statically: M(x) = L − x, so w″ = (L − x)/EI.
    double staticCurvature(double x) const { return (kLength - x) / stiffness; }
};

std::string faceWhere(const std::vector<kernel::FaceReference>& faces, const std::function<bool(const kernel::FaceReference&)>& predicate) {
    for (const auto& face : faces)
        if (predicate(face)) return face.faceId.substr(0, face.faceId.find('-', 5));
    return "face-not-found";
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
    workDirectory = std::filesystem::temp_directory_path() / "cadnext_bird_study_test";
    std::filesystem::remove_all(workDirectory);
    std::filesystem::create_directories(workDirectory);
    const auto steel = *findMaterial("steel_4130");

    // --- 6a. Parsing.
    {
        const std::string base = R"({"schema": "cadnext-structural-job/1", "analysis": "bird",
            "geometry": {"format": "brep", "path": "p.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": "x", "supports": [{"face": "face-0", "fix": ["x", "y", "z"]}]LOADS},
            "bird": {"modeCount": 10DAMPINGFACE, "direction": [0, 0, -1], "bird": BIRD},
            "output": {"result": "r.json"}})";
        auto job = [&](const std::string& loads, const std::string& damping, const std::string& face, const std::string& bird) {
            std::string text = base;
            text.replace(text.find("LOADS"), 5, loads);
            text.replace(text.find("DAMPING"), 7, damping);
            text.replace(text.find("FACE"), 4, face);
            text.replace(text.find("BIRD"), 4, bird);
            return parseStructuralJob(text, "/base");
        };
        const std::string damping = R"(, "dampingRatio": 0.02)";
        const std::string face = R"(, "impactFace": "face-3")";
        const std::string bird = R"({"massKg": 0.05, "speedMps": 90, "obliquityDeg": 90})";
        const auto good = job("", damping, face, bird);
        check(good.isOk(), "a complete bird job parses", good.isOk() ? "" : good.error().message);
        if (good.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(good.value()), "/elsewhere");
            check(back.isOk() && back.value().analysis == StructuralAnalysis::Bird && back.value().bird.bird.massKg == 0.05
                      && back.value().bird.bird.speedMps == 90.0 && back.value().bird.impactFace == "face-3"
                      && std::fabs(back.value().bird.bird.obliquityRad - M_PI_2) < 1e-12,
                  "bird job round-trips through the serializer");
        }
        check(!job(R"(, "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}])", damping, face, bird).isOk(),
              "a bird job carrying static loads is refused");
        check(!job("", "", face, bird).isOk(), "damping has no default in a bird job");
        check(!job("", damping, "", bird).isOk(), "the struck face has no default");
        check(!job("", damping, face, R"({"massKg": 0.05})").isOk(), "a bird with no speed is refused");
        check(!job("", damping, face, R"({"massKg": 0.05, "speedMps": 90, "obliquityDeg": 120})").isOk(), "an impossible angle of attack is refused");
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

    BirdModel model;
    model.massKg = 0.05;
    model.speedMps = 90.0;
    const auto impact = birdImpact(model);
    check(impact.isOk(), "the bird's load is built", impact.isOk() ? "" : impact.error().message);
    if (!impact.isOk()) return fea_test::finish("test_fea_bird_strike_study");

    const std::string job = std::string(R"({"schema": "cadnext-structural-job/1", "analysis": "bird",
        "geometry": {"format": "brep", "path": "beam.brep"}, "material": "steel_4130", "factorOfSafety": 1.5,
        "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
        "loadCase": {"name": "strike", "supports": [{"face": ")")
                            + root + R"(", "fix": ["x", "y", "z"]}],
                     "stressExclusions": [{"face": ")" + root + R"(", "distanceM": 0.03}]},
        "bird": {"modeCount": 10, "dampingRatio": 0.02, "impactFace": ")" + tip + R"(", "direction": [0, 0, -1],
                 "bird": {"massKg": 0.05, "speedMps": 90, "obliquityDeg": 90}},
        "output": {"result": "strike.result.json", "field": "strike.field.json"}})";
    const int status = runJob("strike", job);
    check(status == 0, "strike: cadnext_structural completes (exit " + std::to_string(status) + ")");
    const JsonValue result = parseOrEmpty(readText(workDirectory / "strike.result.json"));
    std::printf("  strike: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
    check(result.stringOr("schema", "") == "cadnext-bird-result/1" && result.stringOr("testType", "") == "birdStrike",
          "strike: bird result schema and test type");

    // --- 3. The load that reached the part.
    const JsonValue* load = result.member("load");
    const double delivered = load ? load->numberOr("deliveredImpulseNs", NAN) : NAN;
    const double momentum = load ? load->numberOr("normalMomentumNs", NAN) : NAN;
    std::printf("  strike: bird %.1f mm × %.1f mm, %.2f cm², %.2f N·s in %.0f µs (delivered %.4f N·s, %+.4f %%)\n", impact.value().diameterM * 1e3,
                impact.value().lengthM * 1e3, impact.value().areaM2 * 1e4, momentum, impact.value().totalDurationS * 1e6, delivered,
                100.0 * (delivered / momentum - 1.0));
    check(std::fabs(delivered / momentum - 1.0) <= 1e-3, "strike: the load the part received carries the bird's momentum to 0.1 %");
    check(std::fabs(momentum / (model.massKg * model.speedMps) - 1.0) <= 1e-12, "strike: that momentum is the bird's own m·u");

    // --- 4. The patch.
    const double patchRatio = metric(result, "patchRatio");
    const double faceArea = metric(result, "impactFaceAreaM2");
    const double geometric = kWidth * kHeight / impact.value().areaM2;
    std::printf("  strike: struck face %.2f cm² against the bird's %.2f cm² → ratio %.4f (geometry says %.4f)\n", faceArea * 1e4,
                impact.value().areaM2 * 1e4, patchRatio, geometric);
    check(std::fabs(patchRatio / geometric - 1.0) <= 1e-6 && std::fabs(faceArea / (kWidth * kHeight) - 1.0) <= 1e-6,
          "strike: the reported patch ratio is the geometry's");
    check(contains(result, "warnings", "меньше миделя птицы"), "strike: a face smaller than the bird is said to be conservative");

    // --- The reference: the same modes, the same static correction, the same force.
    const std::vector<double> feFrequencies = [&] {
        std::vector<double> out;
        if (const JsonValue* list = result.member("modeFrequenciesHz"))
            for (const auto& v : list->arrayItems) out.push_back(v.numberValue);
        return out;
    }();
    const BeamSeries series(steel.youngsModulusPa, steel.densityKgPerM3, 40);
    std::vector<int> kept;
    std::string keptText;
    for (std::size_t m = 0; m < series.modes.size(); ++m) {
        const double f = series.modes[m].omega / (2.0 * M_PI);
        for (double fe : feFrequencies) {
            if (std::fabs(f / fe - 1.0) <= 0.05) {
                kept.push_back(static_cast<int>(m));
                keptText += " " + std::to_string(static_cast<int>(std::lround(f))) + "/" + std::to_string(static_cast<int>(std::lround(fe)));
                break;
            }
        }
    }
    std::printf("  strike: the solver kept %zu modes, %zu of them bend the way the bird pushes (series/FE, Hz):%s\n", feFrequencies.size(), kept.size(),
                keptText.c_str());
    check(!kept.empty(), "strike: the series finds the bending modes the solver kept");
    if (kept.empty()) return fea_test::finish("test_fea_bird_strike_study");

    const std::vector<double> times = history(result, "timeS");
    const std::vector<double> stresses = history(result, "maxVonMisesPa");
    const double window = times.empty() ? 0.2 : times.back();
    const double h = 5e-7;
    const int every = 20;
    auto force = [&](double t) { return -impact.value().forceAt(t); }; // −z, as the job asks
    std::vector<std::vector<double>> modal;
    for (int m : kept) modal.push_back(rungeKutta(series.modes[m].omega, kZeta, [&](double t) {
                                           return series.modes[m].scale * series.modes[m].shape(kLength) * force(t);
                                       }, window + 2 * every * h, h, every));
    // Curvature at x and instant i: the kept modes, plus the static answer for everything else.
    auto curvature = [&](double x, std::size_t i, double t) {
        double total = series.staticCurvature(x) * force(t);
        for (std::size_t k = 0; k < kept.size(); ++k) {
            const auto& mode = series.modes[kept[k]];
            const double omega = mode.omega;
            const double q = i < modal[k].size() ? modal[k][i] : 0.0;
            const double quasiStatic = mode.scale * mode.shape(kLength) * force(t) / (omega * omega);
            total += mode.scale * mode.curvature(x) * (q - quasiStatic);
        }
        return total;
    };
    auto seriesStress = [&](double x, std::size_t i, double t) { return steel.youngsModulusPa * 0.5 * kHeight * std::fabs(curvature(x, i, t)); };

    // --- 1. The peak, at the point and instant the solver reports.
    const JsonValue* critical = result.member("criticalRegion");
    const JsonValue* point = critical ? critical->member("point") : nullptr;
    const double x = point && point->arrayItems.size() == 3 ? point->arrayItems[0].numberValue : NAN;
    const double t = critical ? critical->numberOr("timeS", NAN) : NAN;
    const std::size_t index = static_cast<std::size_t>(std::lround(t / (every * h)));
    const double reference = seriesStress(x, index, t);
    const double stress = metric(result, "peakStressPa");
    const double uncertainty = metric(result, "peakStressPa", "numericalUncertainty");
    std::printf("  strike: peak stress %.3f MPa ± %.3f at x = %.4f m, t = %.3f ms (series %.3f MPa, %+.3f %%)\n", stress / 1e6, uncertainty / 1e6, x,
                1e3 * t, reference / 1e6, 100 * (stress / reference - 1));
    check(std::fabs(stress - reference) <= 0.03 * reference + (std::isfinite(uncertainty) ? uncertainty : 0.0),
          "strike: peak stress within 3 % + mesh uncertainty of beam theory at the critical point and instant");

    // --- 2. The whole history: the largest stress the part carries at each reported instant, which
    // for a bending answer is the extreme fibre somewhere outside the excluded root.
    {
        double seriesPeak = 0.0;
        std::vector<double> referenceHistory(times.size(), 0.0);
        for (std::size_t i = 0; i < times.size(); ++i) {
            const std::size_t sample = static_cast<std::size_t>(std::lround(times[i] / (every * h)));
            double worst = 0.0;
            for (int s = 0; s <= 200; ++s) {
                const double xs = kExclusion + (kLength - kExclusion) * s / 200.0;
                worst = std::max(worst, seriesStress(xs, sample, times[i]));
            }
            referenceHistory[i] = worst;
            seriesPeak = std::max(seriesPeak, worst);
        }
        double worstDeviation = 0.0, worstAt = 0.0;
        std::size_t compared = 0;
        for (std::size_t i = 0; i < times.size() && i < stresses.size(); ++i) {
            if (referenceHistory[i] < 0.25 * seriesPeak) continue;
            ++compared;
            const double deviation = std::fabs(stresses[i] / referenceHistory[i] - 1.0);
            if (deviation > worstDeviation) worstDeviation = deviation, worstAt = times[i];
        }
        std::printf("  strike: history compared at %zu of %zu instants, worst deviation %.3f %% at %.3f ms\n", compared, times.size(),
                    100.0 * worstDeviation, 1e3 * worstAt);
        check(compared > 10 && worstDeviation <= 0.05, "strike: the stress history follows the series to 5 % wherever the maximum means anything");
    }

    // --- 5. The contract.
    const JsonValue field = parseOrEmpty(readText(workDirectory / "strike.field.json"));
    check(field.member("bird") && std::fabs(field.member("bird")->numberOr("timeS", -1) - t) < 1e-12, "strike: the field is the worst instant's");
    {
        const auto example = parseStructuralJob(readText(schemaDirectory / "bird-job.example.json"), schemaDirectory.string());
        check(example.isOk() && example.value().analysis == StructuralAnalysis::Bird, "schema/bird-job.example.json parses",
              example.isOk() ? "" : example.error().message);
    }
    const JsonValue fixture = parseOrEmpty(readText(schemaDirectory / "bird-result.example.json"));
    const bool sameKeys = keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                          && keys(result.member("history")) == keys(fixture.member("history")) && keys(result.member("load")) == keys(fixture.member("load"));
    check(sameKeys, "bird result keys (top level, metrics, history, load) match schema/bird-result.example.json");
    if (!sameKeys) {
        writeText(workDirectory / "bird-result.produced.json", readText(workDirectory / "strike.result.json"));
        std::printf("  produced result kept at %s\n", (workDirectory / "bird-result.produced.json").c_str());
    }

    // --- 6b. No supports.
    {
        const std::string loose = std::string(R"({"schema": "cadnext-structural-job/1", "analysis": "bird",
            "geometry": {"format": "brep", "path": "beam.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": "loose", "supports": []},
            "bird": {"modeCount": 6, "dampingRatio": 0.02, "impactFace": ")")
                                   + tip + R"(", "direction": [0, 0, -1], "bird": {"massKg": 0.05, "speedMps": 90}},
            "output": {"result": "loose.result.json"}})";
        const int code = runJob("loose", loose);
        const JsonValue looseResult = parseOrEmpty(readText(workDirectory / "loose.result.json"));
        check(code == 2 && contains(looseResult, "failureReasons", "опор"), "no supports → ERROR with the reason, exit 2");
    }
    return fea_test::finish("test_fea_bird_strike_study");
}
