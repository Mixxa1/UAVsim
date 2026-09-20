// The radiated-susceptibility study on a CAD enclosure, end to end.
//
//   cadnext_test_fea_emc_study [cadnext_structural schema-dir]
//
// Criteria, fixed before the first run:
//   1. A sealed aluminium box, 96 mm across with 8 mm walls, under MIL-STD-461G RS103 at 200 V/m:
//      nothing gets in. The study must report shielding of at least 60 dB at the probe inside, say
//      in as many words that the number is a lower bound (the grid has a floor and the empty box has
//      no losses), and pass equipment qualified to 20 V/m.
//   2. The same box with a 16 mm hole in the wall the wave arrives at: the shielding drops by at
//      least 20 dB, and the field inside is what the verdict is made of — equipment qualified to
//      0.05 V/m fails, equipment qualified to 200 V/m passes.
//   3. The study refuses what it cannot answer, each with its own reason: a probe that falls inside
//      the metal rather than the cavity, a level that is not in the standard's tables, a sweep that
//      runs outside that level, no probe at all, and a polarisation along the direction of travel.
//   4. Three grids and a convergence band: the coarse and fine answers must lie within the band the
//      study reports, and the band must be reported even when the convergence is not usable.
//   5. Through the contract (when the tool's path and the schema folder are given): the same box run
//      as a job file gives the same shielding as in process (1e-9 dB), the result's keys match
//      schema/emc-result.example.json, the job example parses and round-trips, and a job with an
//      unknown level ends as ERROR with exit 2.

#include "fea_test_support.hpp"

#include "cadnext/fea/EmcStudy.hpp"
#include "cadnext/fea/FeaJson.hpp"
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

// An axis-aligned block, from a corner and three sides.
Result<kernel::ShapeHandle> block(kernel::OcctKernel& kernel, double x, double y, double z, double dx, double dy, double dz) {
    return kernel.makeExtrudedPolygon({{{x, y, z}, {x + dx, y, z}, {x + dx, y + dy, z}, {x, y + dy, z}}, {0, 0, dz}});
}

// A hollow box, optionally with a square hole through the wall at x = 0.
Result<kernel::ShapeHandle> enclosure(kernel::OcctKernel& kernel, double outer, double wall, double hole) {
    const auto solid = block(kernel, 0, 0, 0, outer, outer, outer);
    if (!solid.isOk()) return solid;
    const auto cavity = block(kernel, wall, wall, wall, outer - 2 * wall, outer - 2 * wall, outer - 2 * wall);
    if (!cavity.isOk()) return cavity;
    auto shell = kernel.booleanCut(solid.value(), cavity.value());
    if (!shell.isOk() || !(hole > 0.0)) return shell;
    const auto tool = block(kernel, -0.5 * wall, 0.5 * (outer - hole), 0.5 * (outer - hole), 2.0 * wall, hole, hole);
    if (!tool.isOk()) return tool;
    return kernel.booleanCut(shell.value(), tool.value());
}

EmcStudySettings baseSettings(double outer) {
    EmcStudySettings settings;
    settings.coarseCellM = 0.004;
    settings.refinementFactor = 1.25;
    settings.incidence = em::Axis::X;
    settings.polarization = em::Axis::Z;
    settings.levelId = "mil461g-rs103-200";
    settings.lowHz = 0.5e9;
    settings.highHz = 2.0e9;
    settings.points = 8;
    EmcProbe probe;
    probe.name = "блок авионики";
    probe.x = probe.y = probe.z = 0.5 * outer;
    probe.immunityVm = 20.0;
    settings.probes = {probe};
    return settings;
}

} // namespace

int main(int argc, char** argv) {
    kernel::OcctKernel kernel;
    const double outer = 0.096, wall = 0.008;
    const auto material = *findMaterial("al_6061_t6");

    // --- 1. A sealed box.
    double sealedShielding = 0.0;
    {
        const auto shape = enclosure(kernel, outer, wall, 0.0);
        check(shape.isOk(), "the sealed enclosure is built", shape.isOk() ? "" : shape.error().message);
        if (!shape.isOk()) return fea_test::finish("test_fea_emc_study");
        const auto run = runEmcStudy(kernel, shape.value(), material, "корпус авионики, RS103, глухой", baseSettings(outer));
        check(run.isOk(), "the sealed box runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            sealedShielding = r.worstShieldingDb;
            bool lowerBound = false;
            for (const auto& warning : r.warnings) lowerBound = lowerBound || warning.find("нижняя оценка") != std::string::npos;
            for (const auto& reason : r.reasons) lowerBound = lowerBound || reason.find("оценка снизу") != std::string::npos;
            std::printf("  sealed: %.1f dB at %.0f MHz (± %.1f dB), inside %.3e V/m of 200 V/m, %zu × %d × %d × %d cells, %d steps\n", r.worstShieldingDb,
                        r.worstFrequencyHz / 1e6, r.shieldingUncertaintyDb, r.probes[0].fieldVm, r.levels[2].cells, r.levels[2].nx, r.levels[2].ny,
                        r.levels[2].nz, r.steps);
            check(r.worstShieldingDb >= 60.0 && lowerBound && r.probes[0].outcome == "pass" && r.verdict != StrengthVerdict::Fail,
                  "a sealed box keeps the standard's field out, and the study says the number is a lower bound");
        }
    }

    // --- 2. The same box with a hole in it.
    {
        const auto shape = enclosure(kernel, outer, wall, 0.016);
        check(shape.isOk(), "the enclosure with a hole is built", shape.isOk() ? "" : shape.error().message);
        if (!shape.isOk()) return fea_test::finish("test_fea_emc_study");
        auto settings = baseSettings(outer);
        settings.probes[0].immunityVm = 0.05;
        const auto run = runEmcStudy(kernel, shape.value(), material, "корпус авионики, RS103, отверстие 16 мм", settings);
        check(run.isOk(), "the box with a hole runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            std::printf("  hole 16 mm: %.1f dB at %.0f MHz (± %.1f dB), inside %.3f V/m of 200 V/m, verdict %s\n", r.worstShieldingDb,
                        r.worstFrequencyHz / 1e6, r.shieldingUncertaintyDb, r.probes[0].fieldVm,
                        r.verdict == StrengthVerdict::Fail ? "FAIL" : r.verdict == StrengthVerdict::Warning ? "WARNING" : "PASS");
            std::printf("  levels: %.2f mm %.1f dB, %.2f mm %.1f dB, %.2f mm %.1f dB\n", r.levels[0].cellM * 1e3, r.levels[0].worstShieldingDb,
                        r.levels[1].cellM * 1e3, r.levels[1].worstShieldingDb, r.levels[2].cellM * 1e3, r.levels[2].worstShieldingDb);
            for (const auto& reason : r.failureReasons) std::printf("  FAIL: %s\n", reason.c_str());
            check(sealedShielding - r.worstShieldingDb >= 20.0, "a hole costs at least 20 dB of shielding");
            check(r.verdict == StrengthVerdict::Fail && r.probes[0].outcome == "fail" && !r.failureReasons.empty(),
                  "equipment qualified to 0.05 V/m does not survive what comes through the hole");
            const double band = std::max(r.shieldingUncertaintyDb, 1e-9);
            const double spread = std::max({r.levels[0].worstShieldingDb, r.levels[1].worstShieldingDb, r.levels[2].worstShieldingDb})
                                  - std::min({r.levels[0].worstShieldingDb, r.levels[1].worstShieldingDb, r.levels[2].worstShieldingDb});
            std::printf("  the three grids spread %.2f dB, the reported band is %.2f dB\n", spread, band);
            check(band >= spread - 1e-9, "the band the study reports covers the spread of its own grids");
            const auto fieldMaximum = std::max_element(r.fieldEVm.begin(), r.fieldEVm.end());
            check(r.fieldEVm.size() == r.field.nodes.size() && fieldMaximum != r.fieldEVm.end() && *fieldMaximum > 0.0,
                  "the surface of the part carries a field for the viewer");
        }
        // The same run, with equipment that is qualified for the outside world.
        settings.probes[0].immunityVm = 200.0;
        const auto tough = runEmcStudy(kernel, shape.value(), material, "корпус авионики, стойкое оборудование", settings);
        check(tough.isOk() && tough.value().probes[0].outcome == "pass" && tough.value().verdict != StrengthVerdict::Fail,
              "equipment qualified to the level itself passes behind the same hole");
    }

    // --- 3. What the study refuses.
    {
        const auto shape = enclosure(kernel, outer, wall, 0.016);
        auto refused = [&](EmcStudySettings settings, const std::string& reason) {
            const auto run = runEmcStudy(kernel, shape.value(), material, "отказ", settings);
            if (run.isOk()) {
                std::printf("  not refused at all (expected «%s»)\n", reason.c_str());
                return false;
            }
            if (run.error().message.find(reason) == std::string::npos) {
                std::printf("  refused for «%s», expected «%s»\n", run.error().message.c_str(), reason.c_str());
                return false;
            }
            return true;
        };
        auto inMetal = baseSettings(outer);
        // In the wall, and away from the hole — the middle of that wall is air, not metal.
        inMetal.probes[0].x = 0.5 * wall;
        inMetal.probes[0].y = inMetal.probes[0].z = 0.25 * outer;
        auto unknownLevel = baseSettings(outer);
        unknownLevel.levelId = "do160g-category-r";
        auto outsideLevel = baseSettings(outer);
        outsideLevel.highHz = 30e9;
        auto noProbes = baseSettings(outer);
        noProbes.probes.clear();
        auto alongTravel = baseSettings(outer);
        alongTravel.polarization = em::Axis::X;
        check(refused(inMetal, "в металл") && refused(unknownLevel, "нет данных") && refused(outsideLevel, "за диапазон")
                  && refused(noProbes, "оборудования") && refused(alongTravel, "поперечной"),
              "a probe in the metal, a level that is not in the tables, a sweep outside it, no equipment and a lengthwise polarisation are each refused "
              "for their own reason");
    }
    // --- 5. Through the contract.
    if (argc == 3) {
        using fea::json::JsonValue;
        const std::string cli = argv[1];
        const std::filesystem::path schema = argv[2];
        const auto work = std::filesystem::temp_directory_path() / "cadnext_emc_study_test";
        std::filesystem::remove_all(work);
        std::filesystem::create_directories(work);
        const auto shape = enclosure(kernel, outer, wall, 0.016);
        const auto brep = kernel.exportBRep(shape.value());
        std::ofstream(work / "box.brep", std::ios::binary).write(reinterpret_cast<const char*>(brep.value().data()), static_cast<std::streamsize>(brep.value().size()));
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
        auto job = [&](const std::string& name, const std::string& level, double probeX = 0.048, double probeOther = 0.048) {
            return R"({"schema": "cadnext-structural-job/1", "analysis": "emc", "geometry": {"format": "brep", "path": "box.brep"},
                       "material": "al_6061_t6", "mesh": {"coarseElementSizeM": 0.004, "refinementFactor": 1.25},
                       "loadCase": {"name": "корпус авионики, RS103, отверстие 16 мм", "supports": []},
                       "emc": {"incidence": "+x", "polarization": "z", "level": ")" + level + R"(", "lowHz": 5e8, "highHz": 2e9, "points": 8,
                               "equipment": [{"name": "блок авионики", "x": )" + std::to_string(probeX) + R"(, "y": )" + std::to_string(probeOther)
                   + R"(, "z": )" + std::to_string(probeOther) + R"(, "immunityVm": 0.05}]},
                       "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
        };
        auto run = [&](const std::string& name, const std::string& text) {
            std::ofstream(work / (name + ".job.json"), std::ios::binary | std::ios::trunc) << text;
            const std::string command = "\"" + cli + "\" \"" + (work / (name + ".job.json")).string() + "\" > /dev/null 2>&1";
            const int status = std::system(command.c_str());
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        };
        const int status = run("box", job("box", "mil461g-rs103-200"));
        const JsonValue result = parse(readText(work / "box.result.json"));
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* shielding = metrics ? metrics->member("shieldingEffectivenessDb") : nullptr;
        const double db = shielding ? shielding->numberOr("value", NAN) : NAN;
        std::printf("  CLI: exit %d, outcome %s, %.4f dB\n", status, result.stringOr("outcome", "?").c_str(), db);
        check(status == 0 && result.stringOr("schema", "") == fea::kEmcResultSchema && result.stringOr("testType", "") == "radiatedSusceptibility"
                  && result.stringOr("outcome", "") == "fail" && std::isfinite(db),
              "the job through cadnext_structural gives a radiated-susceptibility result");
        const JsonValue field = parse(readText(work / "box.field.json"));
        const JsonValue* block = field.member("emc");
        check(block && block->member("fieldVm") && field.member("nodes")
                  && block->member("fieldVm")->arrayItems.size() * 3 == field.member("nodes")->arrayItems.size(),
              "the field carries |E| for every surface node");
        const JsonValue fixture = parse(readText(schema / "emc-result.example.json"));
        const bool sameKeys = !keys(&fixture).empty() && keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("environment")) == keys(fixture.member("environment"));
        check(sameKeys, "emc result keys match schema/emc-result.example.json");
        if (!sameKeys) {
            std::ofstream(work / "emc-result.produced.json") << readText(work / "box.result.json");
            std::printf("  produced result kept at %s\n", (work / "emc-result.produced.json").c_str());
        }
        const auto example = fea::parseStructuralJob(readText(schema / "emc-job.example.json"), schema.string());
        check(example.isOk() && example.value().analysis == fea::StructuralAnalysis::Emc, "schema/emc-job.example.json parses",
              example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = fea::parseStructuralJob(fea::structuralJobJson(example.value()), schema.string());
            bool same = back.isOk();
            if (same) {
                const auto& a = example.value().emc;
                const auto& b = back.value().emc;
                same = a.incidence == b.incidence && a.forward == b.forward && a.polarization == b.polarization && a.levelId == b.levelId
                       && a.lowHz == b.lowHz && a.highHz == b.highHz && a.points == b.points && a.equipment.size() == b.equipment.size()
                       && a.equipment[0].immunityVm == b.equipment[0].immunityVm && a.equipment[0].name == b.equipment[0].name;
            }
            check(same, "an emc job round-trips through the serializer");
        }
        // A level that is not in the tables is refused while the job is still being read, before any
        // result file exists: exit 2 and the reason on the console.
        check(run("unknown", job("unknown", "do160g-category-r")) == 2 && !std::filesystem::exists(work / "unknown.result.json"),
              "a level that is not in the tables is refused before the study starts, with exit 2 and no result file");
        // A job that reads correctly but cannot be answered ends as a result file that says ERROR.
        // In the wall and away from the hole: the middle of that wall is the hole itself.
        const int inMetal = run("inmetal", job("inmetal", "mil461g-rs103-200", 0.004, 0.024));
        const JsonValue metalResult = parse(readText(work / "inmetal.result.json"));
        bool saysMetal = false;
        if (const JsonValue* reasons = metalResult.member("failureReasons"))
            for (const auto& item : reasons->arrayItems) saysMetal = saysMetal || item.stringValue.find("в металл") != std::string::npos;
        check(inMetal == 2 && metalResult.stringOr("outcome", "") == "error" && metalResult.stringOr("schema", "") == fea::kEmcResultSchema && saysMetal,
              "equipment placed in the metal: ERROR, exit 2, and the reason in the result file");
    }

    return fea_test::finish("test_fea_emc_study");
}
