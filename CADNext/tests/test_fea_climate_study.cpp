// Climatic test of a CAD solid, in process (the job contract and the command line come on top of this).
//
// Part: an aluminium 6061-T6 plate 100 × 100 × 10 mm, meshed by Netgen at 20, 13.3, 8.9 mm.
//
// Criteria, fixed before the first run:
//   1. Hot, MIL-STD-810H A1 with sun (Method 505.7 Procedure I), chamber air 1.5 m/s, α = 0.6, ε = 0.8, a
//      5 W unit on the bottom face (covered), free mount. The plate is nearly isothermal (Bi ≈ 7e-4), so
//      its periodic day is the lumped ODE  m c Ṫ = α E(t) A_top + P − h A_ex (T − T_air) − εσ A_ex (T⁴ − T_air⁴)
//      with the study's own h (its low band edge) and the exposed area A_ex; integrated by RK4 at 2 s for
//      ten days. The study's peak on the finest mesh and the unit's maximum within 1 % of the peak rise
//      over the air's peak (the physical non-lumpedness is ~0.2 % of it — test_fea_climate_core measured
//      0.03 K on a thinner plate). The cycle becomes periodic (0.01 K) within the standard's seven days.
//      Without a material temperature limit the verdict is not PASS and says "нет данных". (The expectation
//      written first — "the unit stays inside 85 °C" — was a guess, not a calculation; the lumped ODE puts
//      it at 91.5 °C, so the check is now that the study fails it, as the reference does.)
//   2. Cold, C2 (−46 °C), unpowered: the part is at the air temperature exactly (to 1e-9 K), a unit
//      rated down to −20 °C fails, with no uncertainty to argue about. Held rigidly by its bottom face,
//      the cooled plate is stressed at the clamp and the verdict says the clamp idealises it; held on
//      kinematic supports it expands freely: zero thermal stress.
//   3. Refusals: a material without thermal data ("нет данных"), a 505.7 chamber faster than 3 m/s.
//   4. checkTemperature: inside with its band → PASS, band across the limit → WARNING, outside even at
//      the band's best → FAIL, for upper and lower limits.
//   5. Through the contract (`cadnext_structural`, when its path and the schema folder are given): the
//      same hot case as a job file gives the same peak (1e-6 K: the tool runs one vecLib thread) and
//      outcome, the result keys match schema/climate-result.example.json, the job example parses and
//      round-trips, bad jobs are refused (no ε, a static force, no time step, a cold category for heat),
//      and a material without thermal data ends as ERROR (exit 2) with the reason.

//   cadnext_test_fea_climate_study [<cadnext_structural> <CADNext/fea/schema>]

#include "fea_test_support.hpp"

#include "cadnext/fea/ClimateStudy.hpp"
#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/fea/Thermal.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
#include <cstdio>
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

namespace {

std::string faceWhere(kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const std::function<bool(const kernel::FaceReference&)>& predicate) {
    for (const auto& face : kernel::FaceAnalyzer(kernel).planarFacesForBody("part", shape))
        if (predicate(face)) return face.faceId.substr(0, face.faceId.find('-', 5));
    return "face-not-found";
}

bool anyContains(const std::vector<std::string>& lines, const std::string& fragment) {
    for (const auto& line : lines)
        if (line.find(fragment) != std::string::npos) return true;
    return false;
}

std::string joined(const std::vector<std::string>& lines) {
    std::string text;
    for (const auto& line : lines) text += " [" + line + "]";
    return text;
}

using json::JsonValue;

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

std::set<std::string> keys(const JsonValue* object) {
    std::set<std::string> result;
    if (object != nullptr)
        for (const auto& [key, value] : object->objectMembers) result.insert(key);
    return result;
}

bool listContains(const JsonValue& result, const std::string& list, const std::string& fragment) {
    const JsonValue* items = result.member(list);
    if (items == nullptr) return false;
    for (const auto& item : items->arrayItems)
        if (item.stringValue.find(fragment) != std::string::npos) return true;
    return false;
}

} // namespace

int main(int argc, char** argv) {
    kernel::OcctKernel kernel;
    const double side = 0.1, thickness = 0.01;
    const auto plate = kernel.makeExtrudedPolygon({{{0, 0, 0}, {side, 0, 0}, {side, side, 0}, {0, side, 0}}, {0, 0, thickness}});
    if (!plate.isOk()) {
        std::printf("cannot build the plate: %s\n", plate.error().message.c_str());
        return 1;
    }
    const auto& shape = plate.value();
    const std::string top = faceWhere(kernel, shape, [&](const auto& f) { return std::fabs(f.origin.z - thickness) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
    const std::string bottom = faceWhere(kernel, shape, [&](const auto& f) { return std::fabs(f.origin.z) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
    const auto aluminium = *findMaterial("al_6061_t6");
    double inProcessPeak = 0.0;
    StrengthVerdict inProcessOutcome = StrengthVerdict::Pass;

    // --- 1. Hot with sun.
    {
        ClimateStudySettings settings;
        settings.coarseElementSizeM = 0.02;
        settings.refinementFactor = 1.5;
        settings.environment = ClimateEnvironment::Hot;
        settings.hotCategory = HotCategory::A1HotDry;
        settings.hotExposure = HotExposure::Sun;
        settings.airSpeedMps = 1.5;
        settings.upDirection = {0, 0, 1};
        settings.flowDirection = {1, 0, 0};
        settings.solarAbsorptance = 0.6;
        settings.emissivity = 0.8;
        settings.stressFreeK = 293.15;
        settings.stepS = 300.0;
        settings.components = {{"avionics", bottom, 5.0, 233.15, 358.15}};
        const auto run = runClimateStudy(kernel, shape, aluminium, "A1", {}, settings);
        check(run.isOk(), "the hot study runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) inProcessPeak = run.value().peakK, inProcessOutcome = run.value().verdict;
        if (run.isOk()) {
            const auto& r = run.value();
            // Lumped reference.
            const auto cycle = hotCycle(HotCategory::A1HotDry, HotExposure::Sun);
            const double h = r.convectionLowWm2K, eps = 0.8, alpha = 0.6, power = 5.0;
            const double areaTop = side * side, areaExposed = areaTop + 4 * side * thickness;
            const double capacity = aluminium.densityKgPerM3 * side * side * thickness * *aluminium.specificHeatJkgK;
            auto rate = [&](double t, double T) {
                const double air = cycle.airK(t);
                return (alpha * cycle.irradianceWm2(t) * areaTop + power - h * areaExposed * (T - air)
                        - eps * kStefanBoltzmann * areaExposed * (std::pow(T, 4) - std::pow(air, 4)))
                       / capacity;
            };
            double T = cycle.meanAirK(), peak = 0.0;
            const double dt = 2.0;
            for (long step = 0; step < static_cast<long>(10 * kDaySeconds / dt); ++step) {
                const double t = step * dt;
                const double k1 = rate(t, T), k2 = rate(t + dt / 2, T + dt / 2 * k1), k3 = rate(t + dt / 2, T + dt / 2 * k2), k4 = rate(t + dt, T + dt * k3);
                T += dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
                if (t >= 9 * kDaySeconds) peak = std::max(peak, T);
            }
            const double rise = peak - cycle.peakAirK();
            const double finestPeak = r.levels[2].peakK;
            std::printf("  A1 sun: h %.2f (%.2f…%.2f) W/(m² K), Re %.0f; peaks %.3f / %.3f / %.3f K; lumped ODE %.3f K (rise %.2f K over the air's peak)\n",
                        r.convectionWm2K, r.convectionLowWm2K, r.convectionHighWm2K, r.reynolds, r.levels[0].peakK, r.levels[1].peakK, finestPeak, peak, rise);
            std::printf("  cycles %d, last change %.4f K, time-step error %.4f K, peak ± %.4f K, other edge %.3f K; unit max %.3f K; stress %.3f MPa\n",
                        r.cycles, r.lastCycleChangeK, r.timeStepErrorK, r.peakUncertaintyK, r.peakOtherEdgeK, r.components[0].maximumK, r.peakStressPa / 1e6);
            std::printf("  sunlit %.5f m², shaded %.5f m², absorbed at peak %.2f W; natural convection (not used) %.2f W/(m² K)\n", r.sunlitProjectedAreaM2,
                        r.shadedAreaM2, r.absorbedSolarPeakW, r.naturalConvectionWm2K);
            std::printf("  verdict %s: failed%s; warning%s\n", verdictName(r.verdict), joined(r.failureReasons).c_str(), joined(r.reasons).c_str());
            check(std::fabs(finestPeak - peak) <= 0.01 * rise, "the plate's periodic peak is the lumped ODE's (1 % of the rise)");
            check(std::fabs(r.components[0].maximumK - peak) <= 0.01 * rise, "the unit's maximum is the lumped ODE's (1 % of the rise)");
            check(r.periodic && r.cycles >= 3 && r.cycles <= 7 && r.lastCycleChangeK <= 0.01, "the cycle repeats itself within the standard's seven days");
            check(std::fabs(r.sunlitProjectedAreaM2 - areaTop) <= 1e-9 && r.shadedAreaM2 == 0.0, "the sun falls on the top face, unshaded");
            check(r.verdict != StrengthVerdict::Pass && anyContains(r.reasons, "нет данных о допустимой температуре материала"),
                  "without a material temperature limit the verdict says there is no data", joined(r.reasons));
            // 5 W under the plate plus 6.7 W of sun on 1 dm² exceeds the unit's 85 °C; the lumped ODE says so
            // independently of the finite elements, so the FAIL has to be there.
            check(peak - 358.15 > 0.01 * rise && r.components[0].verdict == StrengthVerdict::Fail && r.verdict == StrengthVerdict::Fail,
                  "the unit exceeds its 85 °C, as the lumped ODE does too: FAIL");
        }
    }

    // --- 2. Cold soak.
    {
        ClimateStudySettings settings;
        settings.coarseElementSizeM = 0.02;
        settings.refinementFactor = 1.5;
        settings.environment = ClimateEnvironment::Cold;
        settings.coldCategory = ColdCategory::C2Cold;
        settings.airSpeedMps = 1.0;
        settings.emissivity = 0.8;
        settings.stressFreeK = 293.15;
        settings.operating = false;
        settings.materialMinimumK = 200.0;
        settings.components = {{"battery", top, 10.0, 253.15, 333.15}};
        const auto clamped = runClimateStudy(kernel, shape, aluminium, "C2", {{bottom, {true, true, true}}}, settings);
        check(clamped.isOk(), "the cold study runs", clamped.isOk() ? "" : clamped.error().message);
        if (clamped.isOk()) {
            const auto& r = clamped.value();
            std::printf("  C2 clamped: low %.6f K, battery min %.6f K, stress %.2f MPa, verdict %s: failed%s; warning%s\n", r.lowK, r.components[0].minimumK,
                        r.peakStressPa / 1e6, verdictName(r.verdict), joined(r.failureReasons).c_str(), joined(r.reasons).c_str());
            check(std::fabs(r.lowK - 227.15) <= 1e-9 && std::fabs(r.components[0].minimumK - 227.15) <= 1e-9 && r.lowUncertaintyK == 0.0,
                  "cold-soaked: the part is at the air temperature exactly");
            check(r.components[0].verdict == StrengthVerdict::Fail && r.verdict == StrengthVerdict::Fail, "a unit rated to −20 °C fails a −46 °C soak");
            check(r.peakStressPa > 0.0 && anyContains(r.reasons, "жёсткой заделки"), "held rigidly, the cooled plate is stressed at the clamp, and the verdict says so");
        }
        const auto free = runClimateStudy(kernel, shape, aluminium, "C2", {}, settings);
        check(free.isOk() && free.value().peakStressPa == 0.0 && anyContains(free.value().warnings, "термонапряжений нет"),
              "on kinematic supports the uniformly cooled plate has no thermal stress", free.isOk() ? joined(free.value().warnings) : free.error().message);
    }

    // --- 3. Refusals.
    {
        ClimateStudySettings settings;
        settings.coarseElementSizeM = 0.02;
        settings.refinementFactor = 1.5;
        settings.airSpeedMps = 1.5;
        settings.solarAbsorptance = 0.6;
        settings.emissivity = 0.8;
        settings.stressFreeK = 293.15;
        settings.stepS = 300.0;
        const auto pla = runClimateStudy(kernel, shape, *findMaterial("pla_fdm"), "A1", {}, settings);
        check(!pla.isOk() && pla.error().message.find("нет данных") != std::string::npos, "a material without thermal data is refused with \"нет данных\"",
              pla.isOk() ? "ran" : pla.error().message);
        settings.airSpeedMps = 5.0;
        check(!runClimateStudy(kernel, shape, aluminium, "A1", {}, settings).isOk(), "a 505.7 chamber faster than 3 m/s is refused");
        settings.airSpeedMps = 1.5;
        settings.stepS = 7.0;
        check(!runClimateStudy(kernel, shape, aluminium, "A1", {}, settings).isOk(), "a time step that does not divide half an hour is refused");
    }

    // --- 4. Temperature verdicts.
    check(checkTemperature(350.0, 1.0, 360.0, true).verdict == StrengthVerdict::Pass && checkTemperature(359.5, 1.0, 360.0, true).verdict == StrengthVerdict::Warning
              && checkTemperature(362.0, 1.0, 360.0, true).verdict == StrengthVerdict::Fail && checkTemperature(250.0, 0.5, 240.0, false).verdict == StrengthVerdict::Pass
              && checkTemperature(240.3, 0.5, 240.0, false).verdict == StrengthVerdict::Warning && checkTemperature(230.0, 0.0, 253.15, false).verdict == StrengthVerdict::Fail,
          "a temperature against a limit: PASS inside its band, WARNING across, FAIL outside");
    // --- 5. Through the job contract and the command line tool.
    if (argc == 3) {
        const std::string cli = argv[1];
        const std::filesystem::path schema = argv[2];
        const auto work = std::filesystem::temp_directory_path() / "cadnext_climate_study_test";
        std::filesystem::remove_all(work);
        std::filesystem::create_directories(work);
        const auto brep = kernel.exportBRep(shape);
        std::ofstream(work / "plate.brep", std::ios::binary).write(reinterpret_cast<const char*>(brep.value().data()), static_cast<std::streamsize>(brep.value().size()));
        auto job = [&](const std::string& name, const std::string& material, const std::string& loadCase, const std::string& climate) {
            return R"({"schema": "cadnext-structural-job/1", "analysis": "climate", "geometry": {"format": "brep", "path": "plate.brep"},
                       "material": ")" + material + R"(", "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.5},
                       "loadCase": {"name": ")" + name + R"(", "supports": [)" + loadCase + R"(]}, "climate": {)" + climate + R"(},
                       "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
        };
        auto run = [&](const std::string& name, const std::string& text) {
            writeText(work / (name + ".job.json"), text);
            const std::string command = "\"" + cli + "\" \"" + (work / (name + ".job.json")).string() + "\" > /dev/null 2>&1";
            const int status = std::system(command.c_str());
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        };
        const std::string hot = R"("environment": "hot", "category": "A1", "exposure": "sun", "airflow": "chamber", "airSpeedMps": 1.5,
                                   "upDirection": [0, 0, 1], "flowDirection": [1, 0, 0], "solarAbsorptance": 0.6, "emissivity": 0.8,
                                   "stressFreeK": 293.15, "components": [{"name": "avionics", "face": ")" + bottom + R"(", "powerW": 5,
                                   "minimumK": 233.15, "maximumK": 358.15}], "stepS": 300)";
        const int status = run("sun", job("sun", "al_6061_t6", "", hot));
        const JsonValue result = parseOrEmpty(readText(work / "sun.result.json"));
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* peak = metrics ? metrics->member("peakTemperatureK") : nullptr;
        const double peakK = peak ? peak->numberOr("value", NAN) : NAN;
        std::printf("  CLI: exit %d, outcome %s, peak %.6f K (in process %.6f K)\n", status, result.stringOr("outcome", "?").c_str(), peakK, inProcessPeak);
        check(status == 0 && result.stringOr("schema", "") == kClimateResultSchema && result.stringOr("testType", "") == "climatic"
                  && std::fabs(peakK - inProcessPeak) <= 1e-6 && result.stringOr("outcome", "") == (inProcessOutcome == StrengthVerdict::Fail ? "fail" : "?"),
              "the job through cadnext_structural gives the in-process peak and outcome");
        const JsonValue field = parseOrEmpty(readText(work / "sun.field.json"));
        const JsonValue* climate = field.member("climate");
        const JsonValue* nodes = field.member("nodes");
        check(climate && nodes && climate->member("temperatureK") && climate->member("temperatureK")->arrayItems.size() * 3 == nodes->arrayItems.size(),
              "the field carries a temperature per surface node");
        const JsonValue fixture = parseOrEmpty(readText(schema / "climate-result.example.json"));
        const bool sameKeys = !keys(&fixture).empty() && keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("temperature")) == keys(fixture.member("temperature"))
                              && keys(result.member("heatExchange")) == keys(fixture.member("heatExchange"))
                              && keys(result.member("time")) == keys(fixture.member("time")) && keys(result.member("series")) == keys(fixture.member("series"));
        check(sameKeys, "climate result keys match schema/climate-result.example.json");
        if (!sameKeys) {
            writeText(work / "climate-result.produced.json", readText(work / "sun.result.json"));
            std::printf("  produced result kept at %s\n", (work / "climate-result.produced.json").c_str());
        }

        const auto example = parseStructuralJob(readText(schema / "climate-job.example.json"), schema.string());
        check(example.isOk() && example.value().analysis == StructuralAnalysis::Climate, "schema/climate-job.example.json parses",
              example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(example.value()), schema.string());
            bool same = back.isOk();
            if (same) {
                const auto& a = example.value().climate;
                const auto& b = back.value().climate;
                same = a.environment == b.environment && a.hotCategory == b.hotCategory && a.hotExposure == b.hotExposure && a.airflow == b.airflow
                       && a.airSpeedMps == b.airSpeedMps && length(a.upDirection - b.upDirection) == 0.0 && a.solarAbsorptance == b.solarAbsorptance
                       && a.emissivity == b.emissivity && a.stressFreeK == b.stressFreeK && a.operating == b.operating && a.stepS == b.stepS
                       && a.convectionBand == b.convectionBand && a.components.size() == b.components.size() && a.components[0].face == b.components[0].face
                       && a.components[0].powerW == b.components[0].powerW && a.components[0].maximumK == b.components[0].maximumK
                       && a.materialMaximumK == b.materialMaximumK;
            }
            check(same, "a climate job round-trips through the serializer");
        }
        // Refused for the stated reason, not for anything else wrong with the text.
        auto refused = [&](const std::string& text, const std::string& reason) {
            const auto parsed = parseStructuralJob(text, work.string());
            return !parsed.isOk() && parsed.error().message.find(reason) != std::string::npos;
        };
        check(parseStructuralJob(job("x", "al_6061_t6", "", hot), work.string()).isOk(), "the unmodified climate job parses (control for the refusals below)");
        std::string noEmissivity = hot;
        noEmissivity.replace(noEmissivity.find(R"("emissivity": 0.8)"), 17, R"("emissivityX": 0.8)");
        std::string noStep = hot;
        noStep.replace(noStep.find(R"("stepS": 300)"), 12, R"("stepX": 300)");
        std::string coldCategory = hot;
        coldCategory.replace(coldCategory.find(R"("category": "A1")"), 16, R"("category": "C2")");
        check(refused(job("x", "al_6061_t6", "", noEmissivity), "emissivity") && refused(job("x", "al_6061_t6", "", noStep), "stepS")
                  && refused(job("x", "al_6061_t6", "", coldCategory), "category")
                  && refused(R"({"schema": "cadnext-structural-job/1", "analysis": "climate", "geometry": {"format": "brep", "path": "plate.brep"},
                               "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.5}, "loadCase": {"name": "x", "supports": [],
                               "forces": [{"face": "face-0", "totalForceN": [0, 0, 1]}]}, "climate": {)" + hot + R"(}, "output": {"result": "x.json"}})",
                             "статические нагрузки"),
              "bad climate jobs are refused: no ε, no time step, a cold category for heat, a static force");
        const int plastic = run("pla", job("pla", "pla_fdm", "", hot));
        const JsonValue plaResult = parseOrEmpty(readText(work / "pla.result.json"));
        check(plastic == 2 && plaResult.stringOr("outcome", "") == "error" && plaResult.stringOr("schema", "") == kClimateResultSchema
                  && listContains(plaResult, "failureReasons", "нет данных"),
              "a material without thermal data: ERROR, exit 2, \"нет данных\"");
    }
    return fea_test::finish("test_fea_climate_study");
}
