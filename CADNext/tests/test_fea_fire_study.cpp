// Fire resistance of a CAD part (ISO 2685 / AC 20-135), in process.
//
// Part: an aluminium 6061-T6 plate 100 × 100 × 5 mm, Netgen at 20, 13.3, 8.9 mm; the ISO 2685 flame on its
// top face, the other faces to the laboratory (4 W/(m² K), ε = 0.7), free to expand; 15 minutes asked.
//
// Criteria, fixed before the first run:
//   1. The plate is nearly isothermal (5 mm of aluminium under ~100 kW/m²: ~1 K through the thickness), so
//      the time its hottest point reaches 550 °C — where EN 1999-1-2 leaves 6061-T6 no strength — is the
//      lumped ODE's  ρ c(θ) V Ṫ = q_flame(T) A_top − A_rest [4 (T − T_lab) + ε σ (T⁴ − T_lab⁴)]  crossing,
//      for each flame model, within 1 % (the hottest point runs ~0.2 % ahead of the mean). The radiative
//      limit is the worse one for a hot surface and must be chosen; the verdict is FAIL on integrity, the
//      time with its uncertainty in the reason; a unit on the bottom face rated to 85 °C fails too.
//   2. 7075-T6 has thermal data but no strength data in EN 1999-1-2: over 5 minutes the verdict cannot be
//      PASS and says "нет данных"; the temperatures beyond 500 °C are reported as extrapolated.
//   3. Refusals: a material with no high-temperature data set ("нет данных"), no flame face, no emissivity.
//   5. Through the contract (`cadnext_structural`, when its path and the schema folder are given): the
//      plate as a job file loses its integrity at the in-process time (1e-6 s), the result keys match
//      schema/fire-result.example.json, the job example parses and round-trips, bad jobs are refused for
//      their reason (no flame face, an unknown standard, no step), a material without data ends as ERROR.
//   4. Behaviour of the strength-in-fire branch (not a verification — its parts are verified exactly in
//      test_fea_fire_core): a 40 mm block under the flame for 5 minutes on rollers, pressed on its top;
//      at 1 MPa no strength reason, at 200 MPa FAIL on strength with the utilisation above 1.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/FireStudy.hpp"
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

// Time the lumped plate reaches `target`, RK4 at 1 ms.
double lumpedCrossing(const HotMaterial& m, const StandardFlame& flame, FlameModel model, double side, double thickness, double emissivity, double target) {
    const double top = side * side, rest = side * side + 4.0 * side * thickness, volume = side * side * thickness;
    auto rate = [&](double T) {
        const double gain = flameHeatFlux(flame, model, T) * top;
        const double loss = rest * (kUnexposedConvectionWm2K * (T - kLaboratoryK) + emissivity * kStefanBoltzmann * (std::pow(T, 4) - std::pow(kLaboratoryK, 4)));
        return (gain - loss) / (m.densityKgM3 * m.specificHeatJkgK(T) * volume);
    };
    double T = kLaboratoryK, t = 0.0;
    const double h = 1e-3;
    while (t < 3600.0) {
        const double k1 = rate(T), k2 = rate(T + h / 2 * k1), k3 = rate(T + h / 2 * k2), k4 = rate(T + h * k3);
        const double next = T + h / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
        if (next >= target) return t + h * (target - T) / (next - T);
        T = next;
        t += h;
    }
    return -1.0;
}

} // namespace

using json::JsonValue;

std::string readText(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

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

int main(int argc, char** argv) {
    kernel::OcctKernel kernel;
    const double side = 0.1, thickness = 0.005;
    const auto plate = kernel.makeExtrudedPolygon({{{0, 0, 0}, {side, 0, 0}, {side, side, 0}, {0, side, 0}}, {0, 0, thickness}});
    if (!plate.isOk()) return 1;
    const auto& shape = plate.value();
    const std::string top = faceWhere(kernel, shape, [&](const auto& f) { return std::fabs(f.origin.z - thickness) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
    const std::string bottom = faceWhere(kernel, shape, [&](const auto& f) { return std::fabs(f.origin.z) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
    const auto aluminium = *findMaterial("al_6061_t6");

    FireStudySettings settings;
    settings.coarseElementSizeM = 0.02;
    settings.refinementFactor = 1.5;
    settings.standard = FireStandard::Iso2685;
    settings.durationS = kFireproofS;
    settings.flameFaces = {top};
    settings.surfaceEmissivity = 0.7;
    settings.stepS = 1.0;

    double inProcessFailure = -1.0;
    // --- 1. 6061-T6 loses its integrity; when, against the lumped ODE.
    {
        FireStudySettings s = settings;
        s.components = {{"avionics", bottom, 0.0, std::nullopt, 358.15}};
        const auto run = runFireStudy(kernel, shape, aluminium, "ISO 2685", {}, s);
        check(run.isOk(), "the fire study runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            inProcessFailure = r.failureTimeS;
            const auto hot = *hotMaterial("al_6061_t6");
            const auto flame = standardFlame(FireStandard::Iso2685);
            // The ODE's exposed area excludes the covered bottom face.
            const double odeRadiative = lumpedCrossing(hot, flame, FlameModel::Radiative, side, thickness, 0.7, *hot.noStrengthK);
            const double odeConvective = lumpedCrossing(hot, flame, FlameModel::Convective, side, thickness, 0.7, *hot.noStrengthK);
            (void)odeConvective;
            double feRadiative = -1, feConvective = -1;
            for (const auto& model : r.finestModels) (model.model == FlameModel::Radiative ? feRadiative : feConvective) = model.failureTimeS;
            std::printf("  6061-T6, ISO flame: 550 °C at %.2f s (radiative), %.2f s (convective); ODE %.2f / %.2f s (bottom face covered in FE)\n", feRadiative,
                        feConvective, odeRadiative, odeConvective);
            std::printf("  governing %s, failure %.2f ± %.2f s, levels %.2f / %.2f / %.2f s, time-step error %.4f s\n",
                        r.governingModel == FlameModel::Radiative ? "radiative" : "convective", r.failureTimeS, r.failureUncertaintyS, r.levels[0].failureTimeS,
                        r.levels[1].failureTimeS, r.levels[2].failureTimeS, r.timeStepErrorS);
            std::printf("  verdict %s: failed%s; warning%s\n", verdictName(r.verdict), joined(r.failureReasons).c_str(), joined(r.reasons).c_str());
            check(r.governingModel == FlameModel::Radiative && r.integrityLost, "the radiative limit is chosen and the plate loses its integrity");
            // Reference: the ODE with the bottom face covered (as the unit covers it in the study).
            auto covered = [&](FlameModel model) {
                const double topArea = side * side, restArea = 4.0 * side * thickness, volume = side * side * thickness;
                auto rate = [&](double T) {
                    const double gain = flameHeatFlux(flame, model, T) * topArea;
                    const double loss = restArea * (kUnexposedConvectionWm2K * (T - kLaboratoryK) + 0.7 * kStefanBoltzmann * (std::pow(T, 4) - std::pow(kLaboratoryK, 4)));
                    return (gain - loss) / (hot.densityKgM3 * hot.specificHeatJkgK(T) * volume);
                };
                double T = kLaboratoryK, t = 0.0;
                const double h = 1e-3;
                while (t < 3600.0) {
                    const double k1 = rate(T), k2 = rate(T + h / 2 * k1), k3 = rate(T + h / 2 * k2), k4 = rate(T + h * k3);
                    const double next = T + h / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
                    if (next >= *hot.noStrengthK) return t + h * (*hot.noStrengthK - T) / (next - T);
                    T = next;
                    t += h;
                }
                return -1.0;
            };
            const double refR = covered(FlameModel::Radiative), refC = covered(FlameModel::Convective);
            std::printf("  ODE with the bottom covered: %.2f s (radiative), %.2f s (convective)\n", refR, refC);
            check(std::fabs(feRadiative - refR) <= 0.01 * refR && std::fabs(feConvective - refC) <= 0.01 * refC,
                  "time to 550 °C for both flame models within 1 % of the lumped ODE");
            check(r.verdict == StrengthVerdict::Fail && anyContains(r.failureReasons, "целостность"), "FAIL on integrity, with the time in the reason");
            check(r.components.size() == 1 && r.components[0].verdict == StrengthVerdict::Fail, "the unit rated to 85 °C behind the plate fails as well");
        }
    }

    // --- 2. 7075-T6: no strength data.
    {
        FireStudySettings s = settings;
        s.durationS = kFireResistantS;
        s.stepS = 2.0;
        const auto run = runFireStudy(kernel, shape, *findMaterial("al_7075_t6"), "ISO 2685", {}, s);
        check(run.isOk(), "7075: the study runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            std::printf("  7075-T6, 5 min: peak %.1f °C, verdict %s:%s\n", r.peakK - 273.15, verdictName(r.verdict), joined(r.reasons).c_str());
            check(r.verdict != StrengthVerdict::Pass && anyContains(r.reasons, "нет данных") && anyContains(r.reasons, "экстраполированы"),
                  "7075: not PASS — no strength data, and the temperatures beyond 500 °C are extrapolated");
        }
    }

    // --- 3. Refusals.
    {
        const auto pla = runFireStudy(kernel, shape, *findMaterial("pla_fdm"), "x", {}, settings);
        check(!pla.isOk() && pla.error().message.find("нет данных") != std::string::npos, "a material with no high-temperature data: refused, \"нет данных\"",
              pla.isOk() ? "ran" : pla.error().message);
        FireStudySettings s = settings;
        s.flameFaces.clear();
        check(!runFireStudy(kernel, shape, aluminium, "x", {}, s).isOk(), "no flame face: refused");
        s = settings;
        s.surfaceEmissivity = 0.0;
        check(!runFireStudy(kernel, shape, aluminium, "x", {}, s).isOk(), "no emissivity: refused");
    }
    // --- 4. Strength in the fire.
    {
        const double block = 0.04;
        const auto thick = kernel.makeExtrudedPolygon({{{0, 0, 0}, {side, 0, 0}, {side, side, 0}, {0, side, 0}}, {0, 0, block}});
        const auto& b = thick.value();
        const std::string blockTop = faceWhere(kernel, b, [&](const auto& f) { return std::fabs(f.origin.z - block) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
        const std::string blockBottom = faceWhere(kernel, b, [&](const auto& f) { return std::fabs(f.origin.z) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
        const std::string x0 = faceWhere(kernel, b, [&](const auto& f) { return std::fabs(f.origin.x) < 1e-9 && std::fabs(f.normal.x) > 0.99; });
        const std::string y0 = faceWhere(kernel, b, [&](const auto& f) { return std::fabs(f.origin.y) < 1e-9 && std::fabs(f.normal.y) > 0.99; });
        const std::vector<FaceSupport> rollers = {{blockBottom, {false, false, true}}, {x0, {true, false, false}}, {y0, {false, true, false}}};
        FireStudySettings s = settings;
        s.durationS = kFireResistantS;
        s.stepS = 2.0;
        s.flameFaces = {blockTop};
        double utilizations[2] = {0.0, 0.0};
        int index = 0;
        for (double pressure : {1.0e6, 200.0e6}) {
            s.pressures = {{blockTop, pressure}};
            const auto run = runFireStudy(kernel, b, aluminium, "block", rollers, s);
            check(run.isOk(), "the loaded block runs", run.isOk() ? "" : run.error().message);
            if (!run.isOk()) return fea_test::finish("test_fea_fire_study");
            const auto& r = run.value();
            utilizations[index++] = r.utilization;
            std::printf("  block, %.0f MPa: peak %.1f °C, integrity %s, utilisation %.3f ± %.3f at %.0f s, verdict %s:%s%s\n", pressure / 1e6, r.peakK - 273.15,
                        r.integrityLost ? "lost" : "kept", r.utilization, r.utilizationUncertainty, r.utilizationTimeS, verdictName(r.verdict),
                        joined(r.failureReasons).c_str(), joined(r.reasons).c_str());
        }
        check(!std::isnan(utilizations[0]) && utilizations[0] < 1.0 && utilizations[1] > 1.0, "the strength branch answers the load: 1 MPa holds, 200 MPa does not");
    }

    // --- 5. Through the contract.
    if (argc == 3) {
        const std::string cli = argv[1];
        const std::filesystem::path schema = argv[2];
        const auto work = std::filesystem::temp_directory_path() / "cadnext_fire_study_test";
        std::filesystem::remove_all(work);
        std::filesystem::create_directories(work);
        const auto brep = kernel.exportBRep(shape);
        std::ofstream(work / "plate.brep", std::ios::binary).write(reinterpret_cast<const char*>(brep.value().data()), static_cast<std::streamsize>(brep.value().size()));
        auto job = [&](const std::string& name, const std::string& material, const std::string& fire) {
            return R"({"schema": "cadnext-structural-job/1", "analysis": "fire", "geometry": {"format": "brep", "path": "plate.brep"},
                       "material": ")" + material + R"(", "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.5},
                       "loadCase": {"name": ")" + name + R"(", "supports": []}, "fire": {)" + fire + R"(},
                       "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
        };
        auto run = [&](const std::string& name, const std::string& text) {
            std::ofstream(work / (name + ".job.json"), std::ios::binary | std::ios::trunc) << text;
            const std::string command = "\"" + cli + "\" \"" + (work / (name + ".job.json")).string() + "\" > /dev/null 2>&1";
            const int status = std::system(command.c_str());
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        };
        const std::string fire = R"("standard": "iso2685", "durationS": 900, "flameFaces": [")" + top + R"("], "surfaceEmissivity": 0.7, "stepS": 1,
                                    "components": [{"name": "avionics", "face": ")" + bottom + R"(", "powerW": 0, "maximumK": 358.15}])";
        const int status = run("plate", job("plate", "al_6061_t6", fire));
        const JsonValue result = parseOrEmpty(readText(work / "plate.result.json"));
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* loss = metrics ? metrics->member("integrityLossTimeS") : nullptr;
        const double failureS = loss ? loss->numberOr("value", NAN) : NAN;
        std::printf("  CLI: exit %d, outcome %s, integrity lost at %.6f s (in process %.6f s)\n", status, result.stringOr("outcome", "?").c_str(), failureS, inProcessFailure);
        check(status == 0 && result.stringOr("schema", "") == kFireResultSchema && result.stringOr("testType", "") == "fireResistance"
                  && result.stringOr("outcome", "") == "fail" && std::fabs(failureS - inProcessFailure) <= 1e-6,
              "the job through cadnext_structural gives the in-process time of failure and the outcome");
        const JsonValue field = parseOrEmpty(readText(work / "plate.field.json"));
        const JsonValue* block = field.member("fire");
        check(block && block->member("temperatureK") && field.member("nodes") && block->member("temperatureK")->arrayItems.size() * 3 == field.member("nodes")->arrayItems.size(),
              "the field carries a temperature per surface node");
        const JsonValue fixture = parseOrEmpty(readText(schema / "fire-result.example.json"));
        const bool sameKeys = !keys(&fixture).empty() && keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("integrity")) == keys(fixture.member("integrity")) && keys(result.member("flame")) == keys(fixture.member("flame"))
                              && keys(result.member("series")) == keys(fixture.member("series"));
        check(sameKeys, "fire result keys match schema/fire-result.example.json");
        if (!sameKeys) {
            std::ofstream(work / "fire-result.produced.json") << readText(work / "plate.result.json");
            std::printf("  produced result kept at %s\n", (work / "fire-result.produced.json").c_str());
        }
        const auto example = parseStructuralJob(readText(schema / "fire-job.example.json"), schema.string());
        check(example.isOk() && example.value().analysis == StructuralAnalysis::Fire, "schema/fire-job.example.json parses", example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(example.value()), schema.string());
            bool same = back.isOk();
            if (same) {
                const auto& a = example.value().fire;
                const auto& b = back.value().fire;
                same = a.standard == b.standard && a.durationS == b.durationS && a.flameFaces == b.flameFaces && a.surfaceEmissivity == b.surfaceEmissivity
                       && a.stepS == b.stepS && a.operating == b.operating && a.components.size() == b.components.size()
                       && a.components[0].maximumK == b.components[0].maximumK && a.components[0].powerW == b.components[0].powerW;
            }
            check(same, "a fire job round-trips through the serializer");
        }
        auto refused = [&](const std::string& text, const std::string& reason) {
            const auto parsed = parseStructuralJob(text, work.string());
            return !parsed.isOk() && parsed.error().message.find(reason) != std::string::npos;
        };
        check(parseStructuralJob(job("x", "al_6061_t6", fire), work.string()).isOk(), "the unmodified fire job parses (control for the refusals below)");
        auto without = [&](const std::string& from, const std::string& to) {
            std::string text = fire;
            text.replace(text.find(from), from.size(), to);
            return job("x", "al_6061_t6", text);
        };
        check(refused(without("\"flameFaces\"", "\"flameFacesX\""), "flameFaces") && refused(without("\"iso2685\"", "\"iso9999\""), "standard")
                  && refused(without("\"stepS\"", "\"stepX\""), "stepS"),
              "bad fire jobs are refused for their reason: no flame face, an unknown standard, no step");
        const int plastic = run("pla", job("pla", "pla_fdm", fire));
        const JsonValue plaResult = parseOrEmpty(readText(work / "pla.result.json"));
        bool reason = false;
        if (const JsonValue* reasons = plaResult.member("failureReasons"))
            for (const auto& item : reasons->arrayItems) reason = reason || item.stringValue.find("нет данных") != std::string::npos;
        check(plastic == 2 && plaResult.stringOr("outcome", "") == "error" && plaResult.stringOr("schema", "") == kFireResultSchema && reason,
              "a material without high-temperature data: ERROR, exit 2, \"нет данных\"");
    }

    return fea_test::finish("test_fea_fire_study");
}
