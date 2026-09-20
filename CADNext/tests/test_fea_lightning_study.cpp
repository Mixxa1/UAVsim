// A lightning strike on a CAD part, in process.
//
// Criteria, fixed before the first run:
//   1. Spread over a whole face: an aluminium 6061-T6 plate 100 × 100 × 2 mm, the arc over its whole top
//      face, the bottom bonded, component C (400 A, 200 C). The current density is then uniform, so the
//      plate's mean temperature is the lumped problem  m c(θ) Ṫ = U i + R i² − A [4 (T − T_lab) +
//      ε σ (T⁴ − T_lab⁴)]  with the study's own resistance (RK4 at 0.1 ms), and its hottest point is the
//      heated surface, which a slab under a steady flux holds q·t/(3λ) above that mean. The peak within
//      1 % of the rise of that sum, and the arc's energy must dominate the Joule energy (it does in
//      aluminium). (The surface term is not a fudge: comparing the surface with the mean alone left 3.4 %,
//      exactly the 1.4 K the profile accounts for.)
//   2. A coupon the size of an arc root: 10 × 10 mm, 1 mm thick, the arc over its whole top face (an
//      equivalent radius of 5.6 mm, which is what measurements give for components A and D). It burns
//      through, and when it does is again the lumped answer plus the surface profile — within 5 % of the
//      time. (The first try here, a 10 mm rib on the big plate, spread the heat too widely to melt at all:
//      an attachment ten times the arc's own root is not a strike.) The current is uniform, so the
//      reported peak current density is the current over the area.
//   4. Through the contract (`cadnext_structural`, when its path and the schema folder are given): the
//      coupon as a job file burns through at the in-process time (1e-9 s), the result keys match
//      schema/lightning-result.example.json, the job example parses and round-trips, bad jobs are refused
//      for their reason, and a material without resistivity ends as ERROR.
//   3. Refusals: a material with no resistivity in the database, no attachment face, no emissivity, a
//      component C current outside the standard's 200–800 A.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/LightningStudy.hpp"
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

} // namespace

int main(int argc, char** argv) {
    kernel::OcctKernel kernel;
    const double side = 0.1, thickness = 0.002;
    const auto plate = kernel.makeExtrudedPolygon({{{0, 0, 0}, {side, 0, 0}, {side, side, 0}, {0, side, 0}}, {0, 0, thickness}});
    if (!plate.isOk()) return 1;
    const auto& flat = plate.value();
    const std::string top = faceWhere(kernel, flat, [&](const auto& f) { return std::fabs(f.origin.z - thickness) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
    const std::string bottom = faceWhere(kernel, flat, [&](const auto& f) { return std::fabs(f.origin.z) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
    const auto aluminium = *findMaterial("al_6061_t6");

    LightningStudySettings settings;
    settings.coarseElementSizeM = 0.02;
    settings.refinementFactor = 1.5;
    settings.components = {LightningComponent::C};
    settings.attachmentFaces = {top};
    settings.groundFaces = {bottom};
    settings.surfaceEmissivity = 0.3;
    settings.continuingCurrentA = 400.0;
    settings.stepsPerComponent = 200;

    // --- 1. The whole face: against the lumped problem.
    {
        const auto run = runLightningStudy(kernel, flat, aluminium, "C, whole face", settings);
        check(run.isOk(), "the lightning study runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            const auto hot = *hotMaterial("al_6061_t6");
            const double current = 400.0, duration = 200.0 / current;
            const double volume = side * side * thickness, mass = hot.densityKgM3 * volume;
            const double cooled = side * side + 4 * side * thickness; // everything but the arc face
            auto rate = [&](double T) {
                const double heat = r.arcVoltsPerAmp * current + r.resistanceOhm * current * current;
                const double loss = cooled * (kUnexposedConvectionWm2K * (T - kLaboratoryK) + 0.3 * kStefanBoltzmann * (std::pow(T, 4) - std::pow(kLaboratoryK, 4)));
                return (heat - loss) / (mass * hot.specificHeatJkgK(T));
            };
            double T = kLaboratoryK;
            const double h = 1e-4;
            for (double t = 0.0; t < duration - 1e-12; t += h) {
                const double k1 = rate(T), k2 = rate(T + h / 2 * k1), k3 = rate(T + h / 2 * k2), k4 = rate(T + h * k3);
                T += h / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
            }
            const double rise = T - kLaboratoryK;
            // The heated surface of a slab under a steady flux sits q t / (3 λ) above its mean.
            const double flux = (r.arcVoltsPerAmp * current) / (side * side);
            const double surface = flux * thickness / (3.0 * hot.conductivityWmK(T));
            std::printf("  C over the whole face: peak %.2f K (lumped %.2f + surface %.2f = %.2f K, rise %.2f K, %+.2f %%), R %.3f мкОм, arc %.0f J vs Joule %.4f J\n",
                        r.peakK, T, surface, T + surface, rise, 100.0 * (r.peakK - T - surface) / rise, r.resistanceOhm * 1e6, r.arcEnergyJ, r.jouleEnergyJ);
            check(std::fabs(r.peakK - T - surface) <= 0.01 * rise, "the plate's hottest point is the lumped answer plus the slab's own profile (1 % of the rise)");
            check(r.arcEnergyJ > 1000.0 * r.jouleEnergyJ, "in aluminium the arc's energy dwarfs the Joule energy");
            check(!r.burnedThrough && r.verdict != StrengthVerdict::Fail, "spread over the whole face, the plate survives component C");
        }
    }

    // --- 2. A coupon the size of the arc's own root.
    double couponBurnThrough = -1.0;
    std::string couponTopFace, couponBottomFace;
    {
        const double coupon = 0.01, foil = 0.001;
        const auto small = kernel.makeExtrudedPolygon({{{0, 0, 0}, {coupon, 0, 0}, {coupon, coupon, 0}, {0, coupon, 0}}, {0, 0, foil}});
        check(small.isOk(), "the coupon is built", small.isOk() ? "" : small.error().message);
        if (!small.isOk()) return fea_test::finish("test_fea_lightning_study");
        const auto& shape = small.value();
        const std::string couponTop = faceWhere(kernel, shape, [&](const auto& f) { return std::fabs(f.origin.z - foil) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
        const std::string couponBottom = faceWhere(kernel, shape, [&](const auto& f) { return std::fabs(f.origin.z) < 1e-9 && std::fabs(f.normal.z) > 0.99; });
        couponTopFace = couponTop, couponBottomFace = couponBottom;
        LightningStudySettings s = settings;
        s.coarseElementSizeM = 0.004;
        s.refinementFactor = 1.4;
        s.attachmentFaces = {couponTop};
        s.groundFaces = {couponBottom};
        s.stepsPerComponent = 400;
        const auto run = runLightningStudy(kernel, shape, aluminium, "C on a coupon", s);
        check(run.isOk(), "the strike on the coupon runs", run.isOk() ? "" : run.error().message);
        if (run.isOk()) {
            const auto& r = run.value();
            couponBurnThrough = r.burnThroughTimeS;
            const auto hot = *hotMaterial("al_6061_t6");
            const double current = 400.0, area = coupon * coupon;
            const double mass = hot.densityKgM3 * area * foil, cooled = area + 4 * coupon * foil;
            const double flux = r.arcVoltsPerAmp * current / area;
            auto rate = [&](double T) {
                const double heat = r.arcVoltsPerAmp * current + r.resistanceOhm * current * current;
                const double loss = cooled * (kUnexposedConvectionWm2K * (T - kLaboratoryK) + 0.3 * kStefanBoltzmann * (std::pow(T, 4) - std::pow(kLaboratoryK, 4)));
                return (heat - loss) / (mass * hot.specificHeatJkgK(T));
            };
            // The hottest point is the heated surface: the mean plus the slab's own q t / (3 λ).
            double T = kLaboratoryK, time = 0.0, reference = -1.0;
            const double h = 1e-5;
            while (time < 1.0) {
                const double k1 = rate(T), k2 = rate(T + h / 2 * k1), k3 = rate(T + h / 2 * k2), k4 = rate(T + h * k3);
                const double next = T + h / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
                const double surface = next + flux * foil / (3.0 * hot.conductivityWmK(next));
                if (surface >= *hot.noStrengthK) {
                    reference = time + h;
                    break;
                }
                T = next;
                time += h;
            }
            std::printf("  C on a 10 × 10 mm coupon: arc root radius %.1f mm, burn-through at %.2f ± %.2f ms (lumped %.2f ms, %+.1f %%), J peak %.3e A/m² (I/A %.3e)\n",
                        r.arcRootRadiusM * 1e3, r.burnThroughTimeS * 1e3, r.burnThroughUncertaintyS * 1e3, reference * 1e3,
                        100.0 * (r.burnThroughTimeS - reference) / reference, r.peakCurrentDensityAm2, current / area);
            std::printf("  verdict %s: failed%s; warning%s\n", verdictName(r.verdict), joined(r.failureReasons).c_str(), joined(r.reasons).c_str());
            check(r.burnedThrough && r.verdict == StrengthVerdict::Fail && anyContains(r.failureReasons, "прожог"),
                  "the coupon burns through, and the verdict says when");
            check(reference > 0.0 && std::fabs(r.burnThroughTimeS - reference) <= 0.05 * reference, "the time of the burn-through is the lumped answer's (5 %)");
            check(std::fabs(r.peakCurrentDensityAm2 / (current / area) - 1.0) <= 0.05, "the current density is the current over the attachment area");
        }
    }

    // --- 3. Refusals.
    {
        check(!runLightningStudy(kernel, flat, *findMaterial("steel_4130"), "x", settings).isOk(), "a material without resistivity in the database is refused");
        LightningStudySettings s = settings;
        s.attachmentFaces.clear();
        check(!runLightningStudy(kernel, flat, aluminium, "x", s).isOk(), "no attachment face: refused");
        s = settings;
        s.surfaceEmissivity = 0.0;
        check(!runLightningStudy(kernel, flat, aluminium, "x", s).isOk(), "no emissivity: refused");
        s = settings;
        s.continuingCurrentA = 1200.0;
        check(!runLightningStudy(kernel, flat, aluminium, "x", s).isOk(), "a component C current outside 200–800 A is refused");
    }
    // --- 4. Through the contract.
    if (argc == 3 && couponBurnThrough > 0.0) {
        const std::string cli = argv[1];
        const std::filesystem::path schema = argv[2];
        const auto work = std::filesystem::temp_directory_path() / "cadnext_lightning_study_test";
        std::filesystem::remove_all(work);
        std::filesystem::create_directories(work);
        const double coupon = 0.01, foil = 0.001;
        const auto small = kernel.makeExtrudedPolygon({{{0, 0, 0}, {coupon, 0, 0}, {coupon, coupon, 0}, {0, coupon, 0}}, {0, 0, foil}});
        const auto brep = kernel.exportBRep(small.value());
        std::ofstream(work / "coupon.brep", std::ios::binary).write(reinterpret_cast<const char*>(brep.value().data()), static_cast<std::streamsize>(brep.value().size()));
        auto job = [&](const std::string& name, const std::string& material, const std::string& lightning) {
            return R"({"schema": "cadnext-structural-job/1", "analysis": "lightning", "geometry": {"format": "brep", "path": "coupon.brep"},
                       "material": ")" + material + R"(", "mesh": {"coarseElementSizeM": 0.004, "refinementFactor": 1.4},
                       "loadCase": {"name": ")" + name + R"(", "supports": []}, "lightning": {)" + lightning + R"(},
                       "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json"}})";
        };
        auto run = [&](const std::string& name, const std::string& text) {
            std::ofstream(work / (name + ".job.json"), std::ios::binary | std::ios::trunc) << text;
            const std::string command = "\"" + cli + "\" \"" + (work / (name + ".job.json")).string() + "\" > /dev/null 2>&1";
            const int status = std::system(command.c_str());
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        };
        const std::string lightning = R"("components": ["C"], "attachmentFaces": [")" + couponTopFace + R"("], "groundFaces": [")" + couponBottomFace
                                      + R"("], "polarity": "anode", "continuingCurrentA": 400, "surfaceEmissivity": 0.3, "stepsPerComponent": 400)";
        const int status = run("coupon", job("coupon", "al_6061_t6", lightning));
        const JsonValue result = parseOrEmpty(readText(work / "coupon.result.json"));
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* burn = metrics ? metrics->member("burnThroughTimeS") : nullptr;
        const double timeS = burn ? burn->numberOr("value", NAN) : NAN;
        std::printf("  CLI: exit %d, outcome %s, burn-through at %.6f ms (in process %.6f ms)\n", status, result.stringOr("outcome", "?").c_str(), timeS * 1e3,
                    couponBurnThrough * 1e3);
        check(status == 0 && result.stringOr("schema", "") == kLightningResultSchema && result.stringOr("testType", "") == "lightningDirect"
                  && result.stringOr("outcome", "") == "fail" && std::fabs(timeS - couponBurnThrough) <= 1e-9,
              "the job through cadnext_structural gives the in-process burn-through and the outcome");
        const JsonValue field = parseOrEmpty(readText(work / "coupon.field.json"));
        const JsonValue* block = field.member("lightning");
        check(block && block->member("temperatureK") && block->member("potentialV")
                  && block->member("temperatureK")->arrayItems.size() * 3 == field.member("nodes")->arrayItems.size(),
              "the field carries a temperature and a potential per surface node");
        const JsonValue fixture = parseOrEmpty(readText(schema / "lightning-result.example.json"));
        const bool sameKeys = !keys(&fixture).empty() && keys(&result) == keys(&fixture) && keys(result.member("metrics")) == keys(fixture.member("metrics"))
                              && keys(result.member("strike")) == keys(fixture.member("strike")) && keys(result.member("integrity")) == keys(fixture.member("integrity"))
                              && keys(result.member("series")) == keys(fixture.member("series"));
        check(sameKeys, "lightning result keys match schema/lightning-result.example.json");
        if (!sameKeys) {
            std::ofstream(work / "lightning-result.produced.json") << readText(work / "coupon.result.json");
            std::printf("  produced result kept at %s\n", (work / "lightning-result.produced.json").c_str());
        }
        const auto example = parseStructuralJob(readText(schema / "lightning-job.example.json"), schema.string());
        check(example.isOk() && example.value().analysis == StructuralAnalysis::Lightning, "schema/lightning-job.example.json parses",
              example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(example.value()), schema.string());
            bool same = back.isOk();
            if (same) {
                const auto& a = example.value().lightning;
                const auto& b = back.value().lightning;
                same = a.components == b.components && a.attachmentFaces == b.attachmentFaces && a.groundFaces == b.groundFaces && a.polarity == b.polarity
                       && a.continuingCurrentA == b.continuingCurrentA && a.surfaceEmissivity == b.surfaceEmissivity && a.stepsPerComponent == b.stepsPerComponent
                       && a.equipment.size() == b.equipment.size() && a.equipment[0].maximumK == b.equipment[0].maximumK;
            }
            check(same, "a lightning job round-trips through the serializer");
        }
        auto refused = [&](const std::string& text, const std::string& reason) {
            const auto parsed = parseStructuralJob(text, work.string());
            return !parsed.isOk() && parsed.error().message.find(reason) != std::string::npos;
        };
        check(parseStructuralJob(job("x", "al_6061_t6", lightning), work.string()).isOk(), "the unmodified lightning job parses (control for the refusals below)");
        auto without = [&](const std::string& from, const std::string& to) {
            std::string text = lightning;
            text.replace(text.find(from), from.size(), to);
            return job("x", "al_6061_t6", text);
        };
        check(refused(without("\"attachmentFaces\"", "\"attachmentFacesX\""), "attachmentFaces") && refused(without("\"C\"", "\"E\""), "components")
                  && refused(without("\"continuingCurrentA\": 400", "\"continuingCurrentA\": 1500"), "continuingCurrentA"),
              "bad lightning jobs are refused for their reason: no attachment face, an unknown component, a current outside the standard");
        const int steel = run("steel", job("steel", "steel_4130", lightning));
        const JsonValue steelResult = parseOrEmpty(readText(work / "steel.result.json"));
        bool reason = false;
        if (const JsonValue* reasons = steelResult.member("failureReasons"))
            for (const auto& item : reasons->arrayItems) reason = reason || item.stringValue.find("нет данных") != std::string::npos;
        check(steel == 2 && steelResult.stringOr("outcome", "") == "error" && steelResult.stringOr("schema", "") == kLightningResultSchema && reason,
              "a material without resistivity: ERROR, exit 2, \"нет данных\"");
    }

    return fea_test::finish("test_fea_lightning_study");
}
