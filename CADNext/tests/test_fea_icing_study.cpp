// The icing study on a CAD part, end to end: a straight NACA 0012 wing section of 0.3 m chord and
// 0.6 m span, flown at 60 m/s through the takeoff maximum icing condition of the regulation.
//
// Criteria, fixed before the first run:
//   1. The part is cut where it is asked to be: every station's chord must be the wing's own 0.3 m
//      to 1 %, and the section must close (a slice that does not is a refusal, not a result).
//   2. Ice lands where it must: the thickest ice is within the first 10 % of the chord of the
//      leading edge, and the rear half of the chord carries none at all.
//   3. Cold enough, the answer is arithmetic: at −20 °C what lands freezes where it lands, less what
//      sublimates, so the ice must be (β·LWC·V − ṁ_evap)·t/ρ_rime to 1 % — with β, the evaporation
//      and the density the study's own — and it must be under β·LWC·V·t/ρ, which sublimation can
//      only take from. (The first draft of this file left the sublimation out and expected the bare
//      β·LWC·V·t/ρ: at −20 °C with a film coefficient of a leading edge that is 14 % too much.)
//   4. The verdict follows the limit it is given: a limit under the thickness fails with the reason,
//      a generous one passes, and without any limit the study says "нет данных" and stays at
//      WARNING rather than passing something it cannot judge.
//   5. Three levels and a band: the band the study reports must cover the spread of its own levels,
//      and the band for the heat transfer must be reported as a range, not hidden.
//   6. Refusals, each for its own reason: air above freezing, no duration, the flow along the span.
//   7. Through the contract (when the tool's path and the schema folder are given): the same wing
//      run as a job file gives the same ice as in process (1e-9 m), the result's keys match
//      schema/icing-result.example.json, the job example parses and round-trips, and a condition
//      named after a figure of the regulation is refused with "нет данных".

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/IcingStudy.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralJob.hpp"
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

// A straight wing: the NACA 0012 profile in the x–z plane, extruded along y.
Result<kernel::ShapeHandle> wing(kernel::OcctKernel& kernel, double chord, double span, int points) {
    std::vector<cadnext::Vector3> profile;
    auto thickness = [&](double t) {
        return 5.0 * 0.12 * chord
               * (0.2969 * std::sqrt(t) - 0.1260 * t - 0.3516 * t * t + 0.2843 * t * t * t - 0.1015 * t * t * t * t);
    };
    // Upper surface from the nose to the tail, then back along the lower one; cosine spacing puts
    // the points where the curvature is.
    for (int i = 0; i <= points; ++i) {
        const double t = 0.5 * (1.0 - std::cos(M_PI * i / points));
        profile.push_back({t * chord, 0.0, thickness(t)});
    }
    for (int i = points - 1; i >= 1; --i) {
        const double t = 0.5 * (1.0 - std::cos(M_PI * i / points));
        profile.push_back({t * chord, 0.0, -thickness(t)});
    }
    return kernel.makeExtrudedPolygon({profile, {0.0, span, 0.0}});
}

IcingStudySettings baseSettings(double chord) {
    IcingStudySettings settings;
    settings.flowAxis = 0;
    settings.spanAxis = 1;
    settings.stations = 2;
    settings.panels = 120;
    settings.trajectories = 121;
    settings.refinementFactor = 1.3;
    settings.surfaceElementSizeM = chord / 12.0;
    settings.condition = takeoffMaximumIcing(60.0, 600.0);
    return settings;
}

} // namespace

int main(int argc, char** argv) {
    kernel::OcctKernel kernel;
    const double chord = 0.3, span = 0.6;
    const auto shape = wing(kernel, chord, span, 60);
    check(shape.isOk(), "the wing is built", shape.isOk() ? "" : shape.error().message);
    if (!shape.isOk()) return fea_test::finish("test_fea_icing_study");
    const auto material = *findMaterial("al_6061_t6");

    // --- 1, 2, 3, 5: one run says most of it.
    {
        auto settings = baseSettings(chord);
        settings.condition.temperatureK = kMeltingPointK - 20.0;
        settings.maximumIceThicknessM = 0.05; // generous
        const auto run = runIcingStudy(kernel, shape.value(), material, "крыло, взлётное обледенение, −20 °C", settings);
        check(run.isOk(), "the wing runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            std::printf("  wing: span %.3f m, K = %.3f, E %.4f, ice %.3f mm ± %.3f over %.0f min, mass %.4f kg, verdict %s\n", r.spanM,
                        r.inertiaParameter, r.collectionEfficiency, r.maximumIceThicknessM * 1e3, r.thicknessUncertaintyM * 1e3,
                        settings.condition.durationS / 60.0, r.iceMassKg,
                        r.verdict == StrengthVerdict::Fail ? "FAIL" : r.verdict == StrengthVerdict::Warning ? "WARNING" : "PASS");
            for (const auto& station : r.stations) {
                std::printf("   station %.3f m: chord %.4f m, β max %.3f, E %.4f, ice %.3f mm, %s at %.2f °C, impingement %.1f mm of surface\n",
                            station.spanPositionM, station.chordM, station.maximumBeta, station.collectionEfficiency, station.maximumIceThicknessM * 1e3,
                            station.glaze ? "glaze" : "rime", station.surfaceTemperatureK - kMeltingPointK, station.impingementLengthM * 1e3);
            }
            bool chords = !r.stations.empty();
            for (const auto& station : r.stations) chords = chords && std::fabs(station.chordM / chord - 1.0) <= 0.01;
            check(chords, "every station is cut at the wing's own chord");

            // Where the ice is, by the panels' own coordinates.
            const auto& station = r.stations.front();
            const double nose = station.panelXM.empty() ? 0.0 : *std::min_element(station.panelXM.begin(), station.panelXM.end());
            double thickest = 0.0, thickestX = 0.0, farthestX = nose;
            for (std::size_t i = 0; i < station.iceThicknessM.size() && i < station.panelXM.size(); ++i) {
                if (station.iceThicknessM[i] > thickest) thickest = station.iceThicknessM[i], thickestX = station.panelXM[i];
                if (station.iceThicknessM[i] > 0.0) farthestX = std::max(farthestX, station.panelXM[i]);
            }
            std::printf("   ice: thickest %.3f mm at %.1f %% of the chord, last ice at %.1f %%; leading edge radius %.2f mm, film there %.0f W/(m²·K)\n",
                        thickest * 1e3, 100.0 * (thickestX - nose) / chord, 100.0 * (farthestX - nose) / chord, station.leadingEdgeRadiusM * 1e3,
                        station.stagnationFilmWm2K);
            check(thickest > 0.0 && (thickestX - nose) <= 0.10 * chord && (farthestX - nose) <= 0.5 * chord,
                  "the thickest ice is at the leading edge and the rear half of the chord stays clean");

            // Rime, by hand, with the study's own numbers: what lands, less what sublimates.
            const double bare = station.maximumBeta * settings.condition.lwcKgM3 * settings.condition.airspeedMps * settings.condition.durationS
                                / kRimeIceDensityKgM3;
            const double exact = (station.impingingKgSm2 - station.evaporatedKgSm2) * settings.condition.durationS / kRimeIceDensityKgM3;
            std::printf("   rime by hand: β·LWC·V·t/ρ = %.3f mm, less %.3f mm sublimated gives %.3f mm against the study's %.3f mm (%+.3f %%)\n",
                        bare * 1e3, (station.evaporatedKgSm2 * settings.condition.durationS / kRimeIceDensityKgM3) * 1e3, exact * 1e3,
                        station.maximumIceThicknessM * 1e3, 100.0 * (station.maximumIceThicknessM / exact - 1.0));
            check(!station.glaze && std::fabs(station.maximumIceThicknessM / exact - 1.0) <= 0.01 && station.maximumIceThicknessM < bare,
                  "cold enough, the ice is what landed less what sublimated");

            const double spread = std::max({r.levels[0].maximumIceThicknessM, r.levels[1].maximumIceThicknessM, r.levels[2].maximumIceThicknessM})
                                  - std::min({r.levels[0].maximumIceThicknessM, r.levels[1].maximumIceThicknessM, r.levels[2].maximumIceThicknessM});
            std::printf("   levels: %.4f, %.4f, %.4f mm (%d, %d, %d panels); band %.4f mm; heat transfer halved/doubled gives %.3f…%.3f mm\n",
                        r.levels[0].maximumIceThicknessM * 1e3, r.levels[1].maximumIceThicknessM * 1e3, r.levels[2].maximumIceThicknessM * 1e3,
                        r.levels[0].panels, r.levels[1].panels, r.levels[2].panels, r.thicknessUncertaintyM * 1e3, r.heatTransferBandLow * 1e3,
                        r.heatTransferBandHigh * 1e3);
            check(r.thicknessUncertaintyM >= spread - 1e-12, "the band the study reports covers the spread of its own levels");
            check(r.heatTransferBandLow > 0.0 && r.heatTransferBandHigh >= r.heatTransferBandLow, "the heat-transfer band is reported as a range");
            check(r.verdict != StrengthVerdict::Fail, "a generous limit passes");
        }
    }

    // --- 4. The verdict follows its limit.
    {
        auto settings = baseSettings(chord);
        settings.condition.temperatureK = kMeltingPointK - 20.0;
        settings.maximumIceThicknessM = 1e-4; // 0.1 mm: the wing will pass that in a minute
        const auto strict = runIcingStudy(kernel, shape.value(), material, "крыло, жёсткий предел", settings);
        settings.maximumIceThicknessM = 0.0; // none at all
        const auto silent = runIcingStudy(kernel, shape.value(), material, "крыло, без предела", settings);
        bool noData = false;
        if (silent.isOk())
            for (const auto& reason : silent.value().reasons) noData = noData || reason.find("нет данных") != std::string::npos;
        check(strict.isOk() && strict.value().verdict == StrengthVerdict::Fail && !strict.value().failureReasons.empty(),
              "ice past the limit fails, with the reason");
        check(silent.isOk() && silent.value().verdict == StrengthVerdict::Warning && noData,
              "without a limit the study says нет данных and does not pass what it cannot judge");
    }

    // --- 6. Refusals.
    {
        auto refused = [&](IcingStudySettings settings, const std::string& reason) {
            const auto run = runIcingStudy(kernel, shape.value(), material, "отказ", settings);
            if (run.isOk()) return false;
            return run.error().message.find(reason) != std::string::npos;
        };
        auto warm = baseSettings(chord);
        warm.condition.temperatureK = kMeltingPointK + 1.0;
        auto noTime = baseSettings(chord);
        noTime.condition.durationS = 0.0;
        auto sameAxis = baseSettings(chord);
        sameAxis.spanAxis = sameAxis.flowAxis;
        check(refused(warm, "не ниже нуля") && refused(noTime, "длительность") && refused(sameAxis, "различаться"),
              "air above freezing, no duration and a flow along the span are each refused for their own reason");
    }
    // --- 7. Through the contract.
    if (argc == 3) {
        using fea::json::JsonValue;
        const std::string cli = argv[1];
        const std::filesystem::path schema = argv[2];
        const auto work = std::filesystem::temp_directory_path() / "cadnext_icing_study_test";
        std::filesystem::remove_all(work);
        std::filesystem::create_directories(work);
        const auto brep = kernel.exportBRep(shape.value());
        std::ofstream(work / "wing.brep", std::ios::binary)
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
        auto job = [&](const std::string& name, const std::string& condition) {
            return R"({"schema": "cadnext-structural-job/1", "analysis": "icing", "geometry": {"format": "brep", "path": "wing.brep"},
                       "material": "al_6061_t6", "mesh": {"coarseElementSizeM": 0.025, "refinementFactor": 1.5},
                       "loadCase": {"name": "крыло, взлётное обледенение", "supports": []},
                       "icing": {"flowAxis": "x", "spanAxis": "y", "angleOfAttackDeg": 0, "stations": 2, "panels": 120, "trajectories": 121,
                                 "refinementFactor": 1.3, "surfaceElementSizeM": 0.025, "condition": )" + condition
                   + R"(, "maximumIceThicknessMm": 50},
                       "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
        };
        auto run = [&](const std::string& name, const std::string& text) {
            std::ofstream(work / (name + ".job.json"), std::ios::binary | std::ios::trunc) << text;
            const std::string command = "\"" + cli + "\" \"" + (work / (name + ".job.json")).string() + "\" > /dev/null 2>&1";
            const int status = std::system(command.c_str());
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        };
        const std::string numbers = R"({"temperatureC": -20, "lwcGm3": 0.35, "dropletMicrons": 20, "altitudeM": 0, "airspeedMps": 60, "durationS": 600})";
        const int status = run("wing", job("wing", numbers));
        const JsonValue result = parse(readText(work / "wing.result.json"));
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* ice = metrics ? metrics->member("iceThicknessM") : nullptr;
        const double thickness = ice ? ice->numberOr("value", NAN) : NAN;
        // The same case in process.
        auto settings = baseSettings(chord);
        settings.condition.temperatureK = kMeltingPointK - 20.0;
        settings.surfaceElementSizeM = 0.025;
        settings.maximumIceThicknessM = 0.05;
        const auto inProcess = runIcingStudy(kernel, shape.value(), material, "крыло, взлётное обледенение", settings);
        std::printf("  CLI: exit %d, outcome %s, ice %.6f mm (in process %.6f mm)\n", status, result.stringOr("outcome", "?").c_str(), thickness * 1e3,
                    inProcess.isOk() ? inProcess.value().maximumIceThicknessM * 1e3 : NAN);
        check(status == 0 && result.stringOr("schema", "") == fea::kIcingResultSchema && result.stringOr("testType", "") == "icing"
                  && inProcess.isOk() && std::fabs(thickness - inProcess.value().maximumIceThicknessM) <= 1e-9,
              "the job through cadnext_structural gives the in-process ice");
        const JsonValue field = parse(readText(work / "wing.field.json"));
        const JsonValue* block = field.member("icing");
        check(block && block->member("iceThicknessM") && field.member("nodes")
                  && block->member("iceThicknessM")->arrayItems.size() * 3 == field.member("nodes")->arrayItems.size(),
              "the field carries the ice at every surface node");
        const JsonValue fixture = parse(readText(schema / "icing-result.example.json"));
        const bool sameKeys = !keys(&fixture).empty() && keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("cloud")) == keys(fixture.member("cloud"));
        check(sameKeys, "icing result keys match schema/icing-result.example.json");
        if (!sameKeys) {
            std::ofstream(work / "icing-result.produced.json") << readText(work / "wing.result.json");
            std::printf("  produced result kept at %s\n", (work / "icing-result.produced.json").c_str());
        }
        const auto example = fea::parseStructuralJob(readText(schema / "icing-job.example.json"), schema.string());
        check(example.isOk() && example.value().analysis == fea::StructuralAnalysis::Icing, "schema/icing-job.example.json parses",
              example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = fea::parseStructuralJob(fea::structuralJobJson(example.value()), schema.string());
            bool same = back.isOk();
            if (same) {
                const auto& a = example.value().icing;
                const auto& b = back.value().icing;
                same = a.flowAxis == b.flowAxis && a.spanAxis == b.spanAxis && a.stations == b.stations && a.panels == b.panels
                       && a.trajectories == b.trajectories && a.conditionId == b.conditionId
                       && std::fabs(a.condition.lwcKgM3 - b.condition.lwcKgM3) <= 1e-12
                       && std::fabs(a.condition.durationS - b.condition.durationS) <= 1e-9
                       && std::fabs(a.maximumIceThicknessM - b.maximumIceThicknessM) <= 1e-12;
            }
            check(same, "an icing job round-trips through the serializer");
        }
        const auto figure = fea::parseStructuralJob(job("figure", "\"continuousMaximum\""), work.string());
        check(!figure.isOk() && figure.error().message.find("нет данных") != std::string::npos,
              "a condition that lives in a figure of the regulation is refused with нет данных");
    }

    return fea_test::finish("test_fea_icing_study");
}
