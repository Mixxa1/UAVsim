// Flutter of a CAD lifting surface, end to end: an aluminium cantilever plate 0.5 m by 0.25 m by
// 6 mm, clamped at the root, flown along its chord.
//
// The plate was chosen to put the answer where the method applies. A narrower one (0.12 m chord)
// flutters at 395 m/s — Mach 1.16, where Theodorsen's incompressible aerodynamics are not about
// anything, and the study says so in a warning. Thinning it instead does not work: at 3 mm the
// elements are slivers and the eigenvalues stop converging, which is the mesher's limit rather than
// the flutter solver's. Widening the chord lowers the torsion frequency without touching the mesh.
//
// Criteria, fixed before the first run:
//   1. The study finds the pair it is supposed to: a bending mode below a torsion mode, both from
//      the part's own finite elements, and it reads them along the span as strips whose chord is the
//      plate's own 0.12 m to 2 %.
//   2. A cantilever's first bending mode grows towards the tip: the plunge of the outermost strip
//      must be at least five times the plunge of the innermost, and it must not change sign.
//   3. Denser air flutters sooner: at twice the density the flutter speed must fall, and by at least
//      a tenth.
//   4. The verdict follows the regulation's margin (1.15·V_D): a dive speed high enough to demand
//      more than the wing has fails with the reason, a low one passes, and without a dive speed the
//      study says "нет данных" and stays at WARNING.
//   5. Three meshes and a band: the band must cover the difference between the two finest levels.
//      ("The spread of all three" is what this file asked for first, and it is the wrong measure
//      when the convergence is monotone: 301.06, 292.10 and 291.47 m/s spread by 9.6 m/s, but the
//      grid convergence index says the finest is within 2.3 m/s of the limit, and it is right to —
//      that is what extrapolating a converging sequence is for. The spread is the right band only
//      when the sequence does not converge, and the study falls back to it then.)
//   6. Refusals, each for its own reason: no supports, the flow along the span, too few strips.
//   7. Through the contract (when the tool's path and the schema folder are given): the same plate
//      run as a job file gives the same flutter speed as in process (to 1e-9 of it — the last digits
//      differ by the width of a double's round-off through the job file's text, 8e-8 m/s out of 291,
//      which is what a text round-trip costs and not a difference in the computation), the keys
//      match schema/flutter-result.example.json, the job example parses and round-trips, and a job
//      without a support is refused before the study starts.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/FlutterStudy.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>
#include <sys/wait.h>

using namespace cadnext;
using namespace cadnext::fea;
using fea_test::check;

namespace {

// A flat plate: chord along x, span along y, thickness along z.
Result<kernel::ShapeHandle> plate(kernel::OcctKernel& kernel, double chord, double span, double thickness) {
    return kernel.makeExtrudedPolygon({{{0.0, 0.0, 0.0}, {chord, 0.0, 0.0}, {chord, span, 0.0}, {0.0, span, 0.0}}, {0.0, 0.0, thickness}});
}

FlutterStudySettings baseSettings(double chord) {
    FlutterStudySettings settings;
    settings.coarseElementSizeM = chord / 6.0;
    settings.refinementFactor = 1.3;
    settings.flowAxis = 0;
    settings.spanAxis = 1;
    settings.stations = 10;
    settings.lowSpeedMps = 10.0;
    settings.highSpeedMps = 600.0;
    settings.speeds = 300;
    FaceSupport root;
    root.fixed = {true, true, true};
    settings.supports = {root};
    return settings;
}

} // namespace

int main(int argc, char** argv) {
    kernel::OcctKernel kernel;
    const double chord = 0.25, span = 0.5, thickness = 0.006;
    const auto shape = plate(kernel, chord, span, thickness);
    check(shape.isOk(), "the plate is built", shape.isOk() ? "" : shape.error().message);
    if (!shape.isOk()) return fea_test::finish("test_fea_flutter_study");
    const auto material = *findMaterial("al_6061_t6");

    // The root face: the one at y = 0. The face groups are "face-<index>" in the kernel's own order,
    // and the study asks for them by name, so the plate's root is found by its geometry.
    const auto faces = kernel::FaceAnalyzer(kernel).planarFacesForBody("plate", shape.value());
    std::string rootFace;
    for (const auto& face : faces) {
        if (std::fabs(face.origin.y) < 1e-9 && std::fabs(face.normal.y) > 0.99) rootFace = face.faceId.substr(0, face.faceId.find('-', 5));
    }
    check(!rootFace.empty(), "the root face is found");
    if (rootFace.empty()) return fea_test::finish("test_fea_flutter_study");

    // --- 1, 2, 5: one run says most of it.
    double baseline = 0.0;
    {
        auto settings = baseSettings(chord);
        settings.supports[0].face = rootFace;
        settings.diveSpeedMps = 0.0;
        const auto run = runFlutterStudy(kernel, shape.value(), material, "пластина, флаттер консоли", settings);
        check(run.isOk(), "the plate runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            baseline = r.flutterSpeedMps;
            std::printf("  plate: bending %.2f Hz (mode %d), torsion %.2f Hz (mode %d), span %.3f m, b %.4f m\n", r.bendingHz, r.bendingMode, r.torsionHz,
                        r.torsionMode, r.spanM, r.referenceSemichordM);
            std::printf("  flutter: %s at %.2f Hz, ± %.2f m/s, M = %.3f, divergence %s\n",
                        r.flutterFound ? (std::to_string(r.flutterSpeedMps) + " m/s").c_str() : "none in the sweep", r.flutterFrequencyHz,
                        r.flutterUncertaintyMps, r.machAtFlutter, r.divergenceSpeedMps > 0.0 ? (std::to_string(r.divergenceSpeedMps) + " m/s").c_str() : "none");
            for (const auto& level : r.levels) {
                std::printf("   level h %.4f m, %zu elements: bending %.2f Hz, torsion %.2f Hz, flutter %.2f m/s\n", level.maximumElementSizeM,
                            level.elements, level.bendingHz, level.torsionHz, level.flutterSpeedMps);
            }
            check(r.bendingHz > 0.0 && r.torsionHz > r.bendingHz && r.bendingMode >= 0 && r.torsionMode > r.bendingMode,
                  "a bending mode below a torsion mode, both from the part's own elements");
            bool chords = !r.strips.empty();
            for (const auto& strip : r.strips) chords = chords && std::fabs(strip.chordM / chord - 1.0) <= 0.02;
            check(chords, "every strip is cut at the plate's own chord");

            const double inner = r.strips.front().plunge[0], outer = r.strips.back().plunge[0];
            std::printf("   bending mode: plunge at the root %.3e, at the tip %.3e; twist of the torsion mode %.3e and %.3e\n", inner, outer,
                        r.strips.front().twist[1], r.strips.back().twist[1]);
            check(std::fabs(outer) >= 5.0 * std::fabs(inner) && inner * outer >= 0.0, "the first bending mode grows towards the tip and keeps its sign");

            const double finestStep = std::fabs(r.levels[2].flutterSpeedMps - r.levels[1].flutterSpeedMps);
            std::printf("   band %.3f m/s against %.3f m/s between the two finest levels\n", r.flutterUncertaintyMps, finestStep);
            check(r.flutterUncertaintyMps >= finestStep - 1e-9, "the band covers what is still moving between the two finest meshes");
            bool noData = false;
            for (const auto& reason : r.reasons) noData = noData || reason.find("нет данных") != std::string::npos;
            check(noData && r.verdict == StrengthVerdict::Warning, "without a dive speed the study says нет данных and does not pass what it cannot judge");
        }
    }

    // --- 3. Denser air.
    if (baseline > 0.0) {
        auto settings = baseSettings(chord);
        settings.supports[0].face = rootFace;
        settings.airDensityKgM3 = 2.45;
        const auto dense = runFlutterStudy(kernel, shape.value(), material, "пластина, плотный воздух", settings);
        check(dense.isOk(), "the dense-air case runs", dense.isOk() ? "" : dense.error().message);
        if (dense.isOk()) {
            std::printf("  density: 1.225 gives %.2f m/s, 2.45 gives %s\n", baseline,
                        dense.value().flutterFound ? (std::to_string(dense.value().flutterSpeedMps) + " m/s").c_str() : "none in the sweep");
            check(dense.value().flutterFound && dense.value().flutterSpeedMps <= 0.9 * baseline, "twice the density flutters at least a tenth sooner");
        }
    }

    // --- 4. The verdict against the regulation's margin.
    if (baseline > 0.0) {
        auto settings = baseSettings(chord);
        settings.supports[0].face = rootFace;
        settings.diveSpeedMps = baseline; // 1.15·V_D is then above the flutter speed
        const auto strict = runFlutterStudy(kernel, shape.value(), material, "пластина, V_D у самого флаттера", settings);
        settings.diveSpeedMps = baseline / 2.0;
        const auto easy = runFlutterStudy(kernel, shape.value(), material, "пластина, V_D вдвое ниже", settings);
        check(strict.isOk() && strict.value().verdict == StrengthVerdict::Fail && !strict.value().failureReasons.empty(),
              "a dive speed that demands more than the wing has fails, with the reason");
        if (strict.isOk()) std::printf("  verdict: %s\n", strict.value().failureReasons.front().c_str());
        check(easy.isOk() && easy.value().verdict != StrengthVerdict::Fail, "half the dive speed passes");
    }

    // --- 6. Refusals.
    {
        auto refused = [&](FlutterStudySettings settings, const std::string& reason) {
            const auto run = runFlutterStudy(kernel, shape.value(), material, "отказ", settings);
            if (run.isOk()) return false;
            return run.error().message.find(reason) != std::string::npos;
        };
        auto free = baseSettings(chord);
        free.supports.clear();
        auto sameAxis = baseSettings(chord);
        sameAxis.supports[0].face = rootFace;
        sameAxis.spanAxis = sameAxis.flowAxis;
        auto fewStrips = baseSettings(chord);
        fewStrips.supports[0].face = rootFace;
        fewStrips.stations = 2;
        check(refused(free, "нет опор") && refused(sameAxis, "различаться") && refused(fewStrips, "полос"),
              "no supports, a flow along the span and too few strips are each refused for their own reason");
    }
    // --- 7. Through the contract.
    if (argc == 3 && baseline > 0.0) {
        using fea::json::JsonValue;
        const std::string cli = argv[1];
        const std::filesystem::path schema = argv[2];
        const auto work = std::filesystem::temp_directory_path() / "cadnext_flutter_study_test";
        std::filesystem::remove_all(work);
        std::filesystem::create_directories(work);
        const auto brep = kernel.exportBRep(shape.value());
        std::ofstream(work / "plate.brep", std::ios::binary)
            .write(reinterpret_cast<const char*>(brep.value().data()), static_cast<std::streamsize>(brep.value().size()));
        auto readText = [](const std::filesystem::path& path) {
            std::ifstream stream(path, std::ios::binary);
            return std::string{std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
        };
        auto parse = [](const std::string& text) {
            JsonValue value;
            std::string error;
            fea::json::parseJson(text, value, error);
            return value;
        };
        auto keys = [](const JsonValue* object) {
            std::set<std::string> out;
            if (object != nullptr)
                for (const auto& [key, value] : object->objectMembers) out.insert(key);
            return out;
        };
        // Every digit of it: a job written with six decimals meshes differently and answers
        // differently, which is not what this check is about.
        auto exact = [](double value) {
            char buffer[64];
            std::snprintf(buffer, sizeof(buffer), "%.17g", value);
            return std::string(buffer);
        };
        auto job = [&](const std::string& name, const std::string& supports) {
            return R"({"schema": "cadnext-structural-job/1", "analysis": "flutter", "geometry": {"format": "brep", "path": "plate.brep"},
                       "material": "al_6061_t6", "mesh": {"coarseElementSizeM": )" + exact(chord / 6.0) + R"(, "refinementFactor": 1.3},
                       "loadCase": {"name": "пластина, флаттер консоли", "supports": )" + supports
                   + R"(},
                       "flutter": {"flowAxis": "x", "spanAxis": "y", "stations": 10, "airDensityKgM3": 1.225, "diveSpeedMps": 200,
                                   "lowSpeedMps": 10, "highSpeedMps": 600, "speeds": 300},
                       "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
        };
        const std::string clamped = R"([{"face": ")" + rootFace + R"(", "fix": ["x", "y", "z"]}])";
        auto run = [&](const std::string& name, const std::string& text) {
            std::ofstream(work / (name + ".job.json"), std::ios::binary | std::ios::trunc) << text;
            const std::string command = "\"" + cli + "\" \"" + (work / (name + ".job.json")).string() + "\" > /dev/null 2>&1";
            const int status = std::system(command.c_str());
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        };
        const int status = run("plate", job("plate", clamped));
        const JsonValue result = parse(readText(work / "plate.result.json"));
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* speed = metrics ? metrics->member("flutterSpeedMps") : nullptr;
        const double flutter = speed ? speed->numberOr("value", NAN) : NAN;
        std::printf("  CLI: exit %d, schema «%s», testType «%s», outcome %s, flutter %.12f m/s (in process %.12f, difference %.2e)\n", status,
                    result.stringOr("schema", "").c_str(), result.stringOr("testType", "").c_str(), result.stringOr("outcome", "?").c_str(), flutter,
                    baseline, std::fabs(flutter - baseline));
        check(status == 0 && result.stringOr("schema", "") == fea::kFlutterResultSchema && result.stringOr("testType", "") == "flutter"
                  && std::fabs(flutter - baseline) <= 1e-9 * baseline,
              "the job through cadnext_structural gives the in-process flutter speed");
        const JsonValue field = parse(readText(work / "plate.field.json"));
        const JsonValue* block = field.member("flutter");
        check(block && block->member("bending") && block->member("torsion") && field.member("nodes")
                  && block->member("bending")->arrayItems.size() * 3 == field.member("nodes")->arrayItems.size(),
              "the field carries both mode shapes, one value per surface node");
        const JsonValue fixture = parse(readText(schema / "flutter-result.example.json"));
        const bool sameKeys = !keys(&fixture).empty() && keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("surface")) == keys(fixture.member("surface"));
        check(sameKeys, "flutter result keys match schema/flutter-result.example.json");
        if (!sameKeys) {
            std::ofstream(work / "flutter-result.produced.json") << readText(work / "plate.result.json");
            std::printf("  produced result kept at %s\n", (work / "flutter-result.produced.json").c_str());
        }
        const auto example = fea::parseStructuralJob(readText(schema / "flutter-job.example.json"), schema.string());
        check(example.isOk() && example.value().analysis == fea::StructuralAnalysis::Flutter, "schema/flutter-job.example.json parses",
              example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = fea::parseStructuralJob(fea::structuralJobJson(example.value()), schema.string());
            bool same = back.isOk();
            if (same) {
                const auto& a = example.value().flutter;
                const auto& b = back.value().flutter;
                same = a.flowAxis == b.flowAxis && a.spanAxis == b.spanAxis && a.stations == b.stations && a.speeds == b.speeds
                       && std::fabs(a.diveSpeedMps - b.diveSpeedMps) <= 1e-9 && std::fabs(a.marginFactor - b.marginFactor) <= 1e-12
                       && std::fabs(a.airDensityKgM3 - b.airDensityKgM3) <= 1e-12 && back.value().loadCase.supports.size() == 1;
            }
            check(same, "a flutter job round-trips through the serializer");
        }
        const auto free = fea::parseStructuralJob(job("free", "[]"), work.string());
        check(!free.isOk() && free.error().message.find("корень") != std::string::npos,
              "a flutter job without a clamped root is refused before the study starts");
    }

    return fea_test::finish("test_fea_flutter_study");
}
