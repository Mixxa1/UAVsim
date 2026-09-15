// Modal analysis as the Workbench will call it: a job file with "analysis": "modal", the
// `cadnext_structural` process, a modal result and a mode-shape field.
//
//   cadnext_test_fea_modal_study <path to cadnext_structural> <CADNext/fea/schema>
//
// Part: the beam of test_fea_modal as a CAD solid, L = 1 m, b = 30 mm (y) × h = 20 mm (z), steel,
// meshed by Netgen at 20 mm, 12.5 mm, 7.8 mm.
//
// References and tolerances.
//  - Free–free beam: Euler–Bernoulli (Blevins) with the Timoshenko correction (shear, rotary
//    inertia; derived in test_fea_modal): weak/strong 1st 0.15 %/0.33 %. A frequency passes when
//      |f − f_Blevins| ≤ 2 × Timoshenko correction · f + reported mesh uncertainty.
//  - Clamped cantilever: NOT beam theory. A solid clamped over its whole root face cannot contract
//    laterally there, which stiffens it by ≈ 0.1 % — the first run found Netgen at +0.12 % over
//    Euler–Bernoulli where Timoshenko predicts −0.02 %, and the structured meshes of
//    test_fea_modal extrapolate to the same +0.1 %. The reference is therefore the same 3D problem
//    on those structured meshes (50×1×1, 100×2×2, 200×4×4), extrapolated, and a frequency passes
//    when the two uncertainty bands overlap:  |f − f_ref| ≤ U + U_ref. Nothing tuned: this checks
//    that the band the study reports on unstructured CAD meshes is honest.
//  - Every reported band must be below 1 % of f: at 2.5+ quadratic elements over the thickness a
//    low bending mode is not that uncertain, and a wide band would let any frequency pass.
//  - Effective-mass fractions: 0.5 percentage point, as in test_fea_modal.
//
// Scenarios:
//  1. Clamped cantilever (with its HTML report), 4 modes, a two-blade rotor at 900–1080 rpm (1P 15–18 Hz, 2P 30–36 Hz).
//     Mode 1 (16.5 Hz) lies in 1P → WARNING naming the mode and band; mode 2 (24.8 Hz) is clear
//     of 2P by ≈ 20 %. An explicit band at 300–400 Hz lies above mode 4 (155 Hz) and must be
//     reported as unchecked; the rotor bands below mode 4 must not.
//  2. Free–free beam, 2 modes, a band below both (40–60 Hz) → six rigid modes skipped, PASS.
//     (A band above the last computed mode would be WARNING: modes above it are not checked.)
//  3. The root supported in z only — the part can still slide → ERROR with the reason, exit 2.
//  4. In-process: job parsing refuses loads in a modal job, the modal job round-trips, the
//     outcome rules (overlap, no band, unknown uncertainty → WARNING), and the result keys match
//     schema/modal-result.example.json, which the Swift probe decodes.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/MeshGeneration.hpp"
#include "cadnext/fea/Modal.hpp"
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

std::string readText(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

void writeText(const std::filesystem::path& path, const std::string& text) {
    std::ofstream(path, std::ios::binary | std::ios::trunc) << text;
}

JsonValue parseOrEmpty(const std::string& text) {
    JsonValue value;
    std::string error;
    json::parseJson(text, value, error);
    return value;
}

int runJob(const std::string& name, const std::string& jobJson) {
    const auto jobPath = workDirectory / (name + ".job.json");
    writeText(jobPath, jobJson);
    const std::string command = "\"" + cli + "\" \"" + jobPath.string() + "\"";
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

const JsonValue* item(const JsonValue& result, const std::string& list, std::size_t index) {
    const JsonValue* items = result.member(list);
    return items && index < items->arrayItems.size() ? &items->arrayItems[index] : nullptr;
}

double beamFrequency(double betaL, double E, double rho, double I, double A) {
    return betaL * betaL / (2.0 * M_PI * kLength * kLength) * std::sqrt(E * I / (rho * A));
}

struct Reference {
    double frequencyHz = 0.0;
    double uncertaintyHz = 0.0;
};

// Frequency of a mode against a reference with its own band (0 for theory plus an allowance).
void checkMode(const JsonValue& result, std::size_t index, const Reference& reference, const std::string& label) {
    const JsonValue* mode = item(result, "modes", index);
    const double f = mode ? mode->numberOr("frequencyHz", NAN) : NAN;
    const double u = mode ? mode->numberOr("numericalUncertaintyHz", NAN) : NAN;
    const double allowed = reference.uncertaintyHz + u;
    std::printf("  %s: %.5f Hz ± %.2e (reference %.5f ± %.2e, deviation %.2e)\n", label.c_str(), f, u, reference.frequencyHz,
                reference.uncertaintyHz, f - reference.frequencyHz);
    check(std::isfinite(u) && u < 0.01 * reference.frequencyHz, label + ": mesh uncertainty known and below 1 %");
    check(std::fabs(f - reference.frequencyHz) <= allowed, label + ": frequency within the reference band + mesh uncertainty");
}

// The clamped beam on structured meshes, three levels, extrapolated (see the header).
std::vector<Reference> structuredCantilever(const IsotropicMaterial& material, int modeCount) {
    std::vector<std::vector<double>> levels;
    for (int k : {1, 2, 4}) {
        MappedBlockSpec spec;
        spec.cellsU = 50 * k;
        spec.cellsV = k;
        spec.cellsW = k;
        spec.mapping = [](double u, double v, double w) { return Vec3{u * kLength, v * kWidth, w * kHeight}; };
        spec.faceNames = {"root", "", "", "", "", ""};
        const TetMesh mesh = generateMappedBlock(spec);
        ModalProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
        problem.modeCount = modeCount;
        const auto solved = solveModal(problem);
        std::vector<double> frequencies;
        if (solved.isOk())
            for (const auto& mode : solved.value().modes) frequencies.push_back(mode.frequencyHz);
        levels.push_back(frequencies);
    }
    std::vector<Reference> references;
    for (int i = 0; i < modeCount; ++i) {
        if (static_cast<int>(levels[0].size()) <= i || static_cast<int>(levels[1].size()) <= i || static_cast<int>(levels[2].size()) <= i) {
            references.push_back({NAN, NAN});
            continue;
        }
        const auto study = estimateConvergence(levels[2][i], levels[1][i], levels[0][i], 2.0, 2.0, 1.25, kTet10EigenvalueOrder);
        references.push_back(study.isUsable() ? Reference{study.extrapolated, study.uncertaintyAbsolute} : Reference{NAN, NAN});
    }
    return references;
}

void checkMassFraction(const JsonValue& result, std::size_t index, int direction, double expected, const std::string& label) {
    const JsonValue* mode = item(result, "modes", index);
    const JsonValue* fractions = mode ? mode->member("effectiveMassFraction") : nullptr;
    const double value = fractions && fractions->arrayItems.size() == 3 ? fractions->arrayItems[direction].numberValue : NAN;
    std::printf("  %s: effective mass %.4f (theory %.4f)\n", label.c_str(), value, expected);
    check(std::fabs(value - expected) <= 0.005, label + ": effective-mass fraction");
}

std::string faceWhere(const std::vector<kernel::FaceReference>& faces, const std::function<bool(const kernel::FaceReference&)>& predicate) {
    for (const auto& face : faces)
        if (predicate(face)) return face.faceId.substr(0, face.faceId.find('-', 5));
    return "face-not-found";
}

std::string beamJob(const std::string& name, const std::string& supports, int modeCount, const std::string& excitation) {
    return std::string(R"({"schema": "cadnext-structural-job/1", "analysis": "modal",
        "geometry": {"format": "brep", "path": "beam.brep"}, "material": "steel_4130",
        "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
        "loadCase": {"name": ")") + name + R"(", "supports": [)" + supports + R"(]},
        "modal": {"modeCount": )" + std::to_string(modeCount) + ", " + excitation + R"(},
        "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json", "report": ")" + name + R"(.report.html"}})";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::printf("usage: %s <cadnext_structural> <schema directory>\n", argv[0]);
        return 64;
    }
    cli = argv[1];
    const std::filesystem::path schemaDirectory = argv[2];
    workDirectory = std::filesystem::temp_directory_path() / "cadnext_modal_study_test";
    std::filesystem::remove_all(workDirectory);
    std::filesystem::create_directories(workDirectory);

    const auto steel = *findMaterial("steel_4130");
    const double E = steel.youngsModulusPa, rho = steel.densityKgPerM3;
    const double area = kWidth * kHeight;
    const double Iweak = kWidth * kHeight * kHeight * kHeight / 12.0;   // bending in z
    const double Istrong = kHeight * kWidth * kWidth * kWidth / 12.0;   // bending in y

    // --- 4a. Parsing and the job serializer (no process).
    {
        const std::string loaded = R"({"schema": "cadnext-structural-job/1", "analysis": "modal",
            "geometry": {"format": "brep", "path": "p.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": "x", "supports": [], "forces": [{"face": "face-1", "totalForceN": [0, 0, 1]}]},
            "modal": {"modeCount": 3}, "output": {"result": "r.json"}})";
        const auto refused = parseStructuralJob(loaded, "/base");
        check(!refused.isOk() && refused.error().message.find("нагрузки") != std::string::npos,
              "a modal job carrying loads is refused", refused.isOk() ? "accepted" : refused.error().message);

        const auto example = parseStructuralJob(readText(schemaDirectory / "modal-job.example.json"), schemaDirectory.string());
        check(example.isOk(), "schema/modal-job.example.json parses", example.isOk() ? "" : example.error().message);
        if (example.isOk()) {
            const auto back = parseStructuralJob(structuralJobJson(example.value()), "/elsewhere");
            bool same = back.isOk() && back.value().analysis == StructuralAnalysis::Modal;
            if (same) {
                const auto& a = example.value().modal;
                const auto& b = back.value().modal;
                same = a.modeCount == b.modeCount && a.separationMargin == b.separationMargin && a.rotors.size() == b.rotors.size()
                       && a.bands.size() == b.bands.size() && !a.rotors.empty() && a.rotors[0].name == b.rotors[0].name
                       && a.rotors[0].minimumRpm == b.rotors[0].minimumRpm && a.rotors[0].maximumRpm == b.rotors[0].maximumRpm
                       && a.rotors[0].bladeCount == b.rotors[0].bladeCount && !a.bands.empty()
                       && a.bands[0].maximumHz == b.bands[0].maximumHz && back.value().loadCase.supports.size() == example.value().loadCase.supports.size()
                       && a.attachedMasses.size() == 1 && b.attachedMasses.size() == 1 && a.attachedMasses[0].faceGroup == b.attachedMasses[0].faceGroup
                       && a.attachedMasses[0].massKg == b.attachedMasses[0].massKg;
            }
            check(same, "modal job round-trips through the serializer (attached masses included)");
            const auto bands = example.value().modal.allBands();
            check(bands.size() == 2 * example.value().modal.rotors.size() + example.value().modal.bands.size(),
                  "every rotor contributes its 1P and NP band, explicit bands follow");
        }
    }

    // --- 4b. Outcome rules on a hand-made result (no process).
    {
        StructuralJob job;
        job.analysis = StructuralAnalysis::Modal;
        ModalStudyResult base;
        base.material = steel;
        base.mesherVersion = "netgen test";
        base.modes.resize(1);
        base.modes[0].frequencyHz = 100.0;
        base.modes[0].convergence.behaviour = ConvergenceBehaviour::Monotonic;
        base.modes[0].convergence.uncertaintyAbsolute = 0.5;
        base.bands = {{"far", 300.0, 400.0}};
        base.resonance = assessResonance({100.0}, {0.5}, base.bands, 0.0);
        auto outcome = [&](const ModalStudyResult& r) { return parseOrEmpty(modalResultJson(r, job, "")).stringOr("outcome", "?"); };
        check(outcome(base) == "pass", "clear of every band, converged → PASS");
        ModalStudyResult overlap = base;
        overlap.resonanceOverlap = true;
        check(outcome(overlap) == "warning", "resonance overlap → WARNING");
        ModalStudyResult unbanded = base;
        unbanded.bands.clear();
        unbanded.resonance.clear();
        const JsonValue unbandedJson = parseOrEmpty(modalResultJson(unbanded, job, ""));
        check(unbandedJson.stringOr("outcome", "") == "warning" && unbandedJson.member("metrics")->member("minimumBandSeparation") == nullptr,
              "no excitation band → WARNING, and no separation metric is invented");
        ModalStudyResult short_ = base;
        short_.uncheckedBands = {"far"};
        check(outcome(short_) == "warning", "a band above the last computed mode → WARNING (modes above it unchecked)");
        ModalStudyResult unknown = base;
        unknown.uncertaintyUnknown = true;
        unknown.modes[0].convergence.behaviour = ConvergenceBehaviour::Oscillatory;
        const JsonValue unknownJson = parseOrEmpty(modalResultJson(unknown, job, ""));
        const JsonValue* first = unknownJson.member("metrics")->member("firstFrequencyHz");
        check(unknownJson.stringOr("outcome", "") == "warning" && first && first->member("numericalUncertainty") == nullptr,
              "frequency without a usable mesh estimate → WARNING, uncertainty left out (unknown, not zero)");
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

    // --- 1. Clamped cantilever against a rotor.
    {
        const std::string job = beamJob("cantilever", R"({"face": ")" + root + R"(", "fix": ["x", "y", "z"]})", 4,
                                        R"("rotors": [{"name": "rotor", "minimumRpm": 900, "maximumRpm": 1080, "bladeCount": 2}],
                                            "bands": [{"name": "high", "minimumHz": 300, "maximumHz": 400}])");
        const int status = runJob("cantilever", job);
        check(status == 0, "cantilever: cadnext_structural completes (exit " + std::to_string(status) + ")");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "cantilever.result.json"));
        std::printf("  cantilever: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
        check(result.stringOr("schema", "") == "cadnext-modal-result/1" && result.stringOr("testType", "") == "modalVibration",
              "cantilever: modal result schema and test type");
        check(result.stringOr("boundary", "") == "supported", "cantilever: reported as supported");
        const auto reference = structuredCantilever(steel, 4);
        checkMode(result, 0, reference[0], "cantilever mode 1 (weak)");
        checkMode(result, 1, reference[1], "cantilever mode 2 (strong)");
        checkMode(result, 2, reference[2], "cantilever mode 3 (weak 2nd)");
        checkMode(result, 3, reference[3], "cantilever mode 4 (strong 2nd)");
        checkMassFraction(result, 0, 2, 0.6131, "cantilever mode 1");
        checkMassFraction(result, 1, 1, 0.6131, "cantilever mode 2");
        checkMassFraction(result, 2, 2, 0.1882, "cantilever mode 3");

        const JsonValue* first = item(result, "resonance", 0);
        const JsonValue* second = item(result, "resonance", 1);
        check(first && first->boolOr("overlaps", false) && first->stringOr("nearestBand", "") == "rotor 1P",
              "cantilever: mode 1 overlaps the 1P band");
        check(second && !second->boolOr("overlaps", true) && second->stringOr("nearestBand", "") == "rotor 2P"
                  && second->numberOr("separation", 0) > 0.15,
              "cantilever: mode 2 is clear of 2P by more than 15 %");
        check(result.stringOr("outcome", "") == "warning" && contains(result, "warnings", "резонанс: мода 1")
                  && contains(result, "warnings", "rotor 1P"),
              "cantilever: overlap → WARNING naming the mode and band");
        check(contains(result, "warnings", "полоса «high»") && !contains(result, "warnings", "полоса «rotor"),
              "cantilever: the band above mode 4 is reported unchecked, the rotor bands below it are not");
        const JsonValue* metrics = result.member("metrics");
        const JsonValue* separation = metrics ? metrics->member("minimumBandSeparation") : nullptr;
        check(separation && separation->numberOr("value", 1) < 0, "cantilever: smallest separation is negative (inside a band)");

        const JsonValue field = parseOrEmpty(readText(workDirectory / "cantilever.field.json"));
        const auto* nodes = field.member("nodes");
        const auto* modes = field.member("modes");
        bool shapesOk = nodes && modes && modes->arrayItems.size() == 4 && nodes->arrayItems.size() % 3 == 0 && !nodes->arrayItems.empty();
        for (std::size_t m = 0; shapesOk && m < modes->arrayItems.size(); ++m) {
            const auto* shape = modes->arrayItems[m].member("shape");
            shapesOk = shape && shape->arrayItems.size() == nodes->arrayItems.size();
            double largest = 0.0;
            for (std::size_t n = 0; shapesOk && n + 2 < shape->arrayItems.size(); n += 3) {
                largest = std::max(largest, std::hypot(shape->arrayItems[n].numberValue, shape->arrayItems[n + 1].numberValue,
                                                       shape->arrayItems[n + 2].numberValue));
            }
            shapesOk = shapesOk && std::fabs(largest - 1.0) < 1e-9;
        }
        check(shapesOk, "cantilever: field carries one shape per mode on the surface nodes, largest displacement 1");
        check(field.stringOr("schema", "") == "cadnext-modal-field/1" && result.stringOr("fieldRef", "") == "cantilever.field.json",
              "cantilever: field schema, and the result points at it");

        const std::string report = readText(workDirectory / "cantilever.report.html");
        check(report.find("__CADNEXT_RESULT_JSON__") == std::string::npos && report.find("__CADNEXT_FIELD_JSON__") == std::string::npos
                  && report.find("\"cadnext-modal-field/1\"") != std::string::npos && report.find("\"cadnext-modal-result/1\"") != std::string::npos
                  && report.find("</html>") != std::string::npos,
              "cantilever: modal HTML report embeds both files");

        // Contract with the Swift side.
        const JsonValue fixture = parseOrEmpty(readText(schemaDirectory / "modal-result.example.json"));
        check(keys(&result) == keys(&fixture), "modal result top-level keys match schema/modal-result.example.json");
        check(keys(result.member("metrics")) == keys(fixture.member("metrics")), "modal metric names match the example");
        check(keys(item(result, "modes", 0)) == keys(item(fixture, "modes", 0)), "mode entry keys match the example");
        if (keys(&result) != keys(&fixture)) {
            writeText(workDirectory / "modal-result.produced.json", readText(workDirectory / "cantilever.result.json"));
            std::printf("  produced result kept at %s\n", (workDirectory / "modal-result.produced.json").c_str());
        }
    }

    // --- 2. Free–free.
    {
        const std::string job = beamJob("free", "", 2, R"("bands": [{"name": "low", "minimumHz": 40, "maximumHz": 60}])");
        check(runJob("free", job) == 0, "free–free: completes");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "free.result.json"));
        std::printf("  free: outcome %s%s\n", result.stringOr("outcome", "?").c_str(), joined(result, "warnings").c_str());
        check(result.stringOr("boundary", "") == "free", "free–free: reported as free");
        const double weak = beamFrequency(4.730041, E, rho, Iweak, area);
        const double strong = beamFrequency(4.730041, E, rho, Istrong, area);
        checkMode(result, 0, {weak, 2.0 * 0.0015 * weak}, "free mode 1 (weak, rigid modes skipped)");
        checkMode(result, 1, {strong, 2.0 * 0.0033 * strong}, "free mode 2 (strong)");
        check(result.stringOr("outcome", "") == "pass", "free–free: clear of the band, band below the last mode, converged → PASS",
              result.stringOr("outcome", "?") + joined(result, "warnings"));
    }

    // --- 3. A support that leaves the part free to slide.
    {
        const std::string job = beamJob("roller", R"({"face": ")" + root + R"(", "fix": ["z"]})", 2, R"("bands": [])");
        const int status = runJob("roller", job);
        const JsonValue result = parseOrEmpty(readText(workDirectory / "roller.result.json"));
        check(status == 2 && result.stringOr("outcome", "") == "error" && result.stringOr("testType", "") == "modalVibration"
                  && contains(result, "failureReasons", "опоры не исключают"),
              "partial support → ERROR with the reason, exit 2 (got " + std::to_string(status) + ", " + result.stringOr("outcome", "?") + ")");
    }

    return fea_test::finish("test_fea_modal_study");
}
