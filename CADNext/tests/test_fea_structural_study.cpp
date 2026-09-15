// The structural solver as the Workbench will call it: a job file, the `cadnext_structural`
// process, a result file and a field file.
//
//   cadnext_test_fea_structural_study <path to cadnext_structural> <CADNext/fea/schema>
//
// Parts are exported from the kernel as BRep files; loads are placed on faces found with the
// kernel's FaceAnalyzer on the *re-imported* part — what a user picking faces in CADNext does.
//
// Scenarios and what each one proves:
//  1. Lamé quarter pipe — the verdict path on a case with an exact answer (von Mises at the bore
//     under plane strain, radial displacement); rollers on symmetry planes must NOT trigger the
//     clamp-singularity warning. Tolerances: stress 1 %, displacement 0.5 % (as on the meshed-CAD
//     test).
//  2. Cantilever with a fully clamped root — the maximum sits at the clamp; the result must say
//     so and must not PASS.
//  3. The same with a 0.1 m stress exclusion at the root — the maximum then lies just past the
//     exclusion, bounded by beam theory between x = d (upper) and x = d + one finest element
//     (lower), with 1 % for discretisation. No tuned tolerance: the band is the geometry.
//  4. A load on a face that does not exist — ERROR with the reason, exit status 2, never FAIL.
// Also: the produced result has exactly the keys of schema/structural-result.example.json,
// which the Swift side decodes in its own probe.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralFieldFile.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/fea/StructuralPresentation.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>
#include <sys/wait.h>

using namespace cadnext;
using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;
using json::JsonValue;

namespace {

std::string cli;
std::filesystem::path workDirectory;

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

std::string exportPart(kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const std::string& name) {
    const auto brep = kernel.exportBRep(shape);
    const auto path = workDirectory / (name + ".brep");
    std::ofstream(path, std::ios::binary).write(reinterpret_cast<const char*>(brep.value().data()),
                                                static_cast<std::streamsize>(brep.value().size()));
    return path.string();
}

std::vector<kernel::FaceReference> facesOfExportedPart(kernel::OcctKernel& kernel, const std::string& path) {
    const std::string bytes = readText(path);
    const auto shape = kernel.importBRep(std::vector<std::uint8_t>(bytes.begin(), bytes.end()));
    return kernel::FaceAnalyzer(kernel).planarFacesForBody("part", shape.value());
}

std::string faceIdPrefix(const kernel::FaceReference& face) {
    // "face-<index>-<hashes>" → "face-<index>"
    const auto second = face.faceId.find('-', 5);
    return face.faceId.substr(0, second);
}

std::string findFace(const std::vector<kernel::FaceReference>& faces,
                     const std::function<bool(const kernel::FaceReference&)>& predicate) {
    for (const auto& face : faces)
        if (predicate(face)) return faceIdPrefix(face);
    return "face-not-found";
}

std::string num(double value) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.17g", value);
    return buffer;
}

std::set<std::string> keys(const JsonValue* object) {
    std::set<std::string> result;
    if (object != nullptr)
        for (const auto& [key, value] : object->objectMembers) result.insert(key);
    return result;
}

double metric(const JsonValue& result, const std::string& name) {
    const JsonValue* metrics = result.member("metrics");
    const JsonValue* entry = metrics ? metrics->member(name) : nullptr;
    return entry ? entry->numberOr("value", NAN) : NAN;
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

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::printf("usage: %s <cadnext_structural> <schema directory>\n", argv[0]);
        return 64;
    }
    cli = argv[1];
    const std::filesystem::path schemaDirectory = argv[2];
    workDirectory = std::filesystem::temp_directory_path() / "cadnext_structural_study_test";
    std::filesystem::remove_all(workDirectory);
    std::filesystem::create_directories(workDirectory);

    kernel::OcctKernel kernel;
    const auto steel = *findMaterial("steel_4130");

    // The published job example must stay parseable.
    const auto example = parseStructuralJob(readText(schemaDirectory / "structural-job.example.json"), schemaDirectory.string());
    check(example.isOk(), "schema/structural-job.example.json parses", example.isOk() ? "" : example.error().message);

    // A job written by the serializer reads back to the same job (the CADNext panel writes jobs
    // this way; the command line tool reads them).
    if (example.isOk()) {
        StructuralJob relative = example.value();
        relative.geometryPath = "wing_spar.uavpart";
        relative.resultPath = "wing_spar.result.json";
        relative.fieldPath = "wing_spar.field.json";
        relative.reportPath = "wing_spar.report.html";
        const auto back = parseStructuralJob(structuralJobJson(relative), "/base");
        bool same = back.isOk();
        if (same) {
            const auto& j = back.value();
            same = j.geometryPath == "/base/wing_spar.uavpart" && j.geometryFormat == relative.geometryFormat
                   && j.materialId == relative.materialId && j.resultPath == "/base/wing_spar.result.json"
                   && j.reportPath == "/base/wing_spar.report.html"
                   && j.settings.coarseElementSizeM == relative.settings.coarseElementSizeM
                   && j.settings.refinementFactor == relative.settings.refinementFactor
                   && j.settings.criteria.factorOfSafety == relative.settings.criteria.factorOfSafety
                   && j.loadCase.name == relative.loadCase.name
                   && j.loadCase.supports.size() == relative.loadCase.supports.size()
                   && j.loadCase.supports[0].fixed == relative.loadCase.supports[0].fixed
                   && j.loadCase.forces.size() == relative.loadCase.forces.size()
                   && length(j.loadCase.forces[0].totalForceN - relative.loadCase.forces[0].totalForceN) == 0.0
                   && length(j.loadCase.bodyAccelerationMps2 - relative.loadCase.bodyAccelerationMps2) == 0.0
                   && j.loadCase.stressExclusions.size() == relative.loadCase.stressExclusions.size()
                   && j.loadCase.stressExclusions[0].distanceM == relative.loadCase.stressExclusions[0].distanceM;
        }
        check(same, "job serializer round-trips through the parser");
    }

    // --- 1. Lamé quarter pipe.
    const double a = 0.10, b = 0.20, t = 0.02, p = 10.0e6;
    {
        const auto outer = kernel.makeExtrudedCircle({{0, 0, 0}, {0, 0, 1}, b, {0, 0, t}});
        const auto inner = kernel.makeExtrudedCircle({{0, 0, 0}, {0, 0, 1}, a, {0, 0, t}});
        const auto cutX = kernel.makeExtrudedPolygon({{{-0.3, -0.3, -0.01}, {0, -0.3, -0.01}, {0, 0.3, -0.01}, {-0.3, 0.3, -0.01}}, {0, 0, t + 0.02}});
        const auto cutY = kernel.makeExtrudedPolygon({{{0, -0.3, -0.01}, {0.3, -0.3, -0.01}, {0.3, 0, -0.01}, {0, 0, -0.01}}, {0, 0, t + 0.02}});
        const auto ring = kernel.booleanCut(outer.value(), inner.value());
        const auto quarter = kernel.booleanCut(kernel.booleanCut(ring.value(), cutX.value()).value(), cutY.value());
        const std::string part = exportPart(kernel, quarter.value(), "pipe");
        const auto faces = facesOfExportedPart(kernel, part);
        using kernel::FaceKind;
        const std::string bore = findFace(faces, [&](const auto& f) { return f.kind == FaceKind::Cylindrical && std::fabs(f.radius - a) < 1e-9; });
        const std::string symX = findFace(faces, [](const auto& f) { return f.kind == FaceKind::Planar && std::fabs(std::fabs(f.normal.x) - 1) < 1e-9 && std::fabs(f.origin.x) < 1e-9; });
        const std::string symY = findFace(faces, [](const auto& f) { return f.kind == FaceKind::Planar && std::fabs(std::fabs(f.normal.y) - 1) < 1e-9 && std::fabs(f.origin.y) < 1e-9; });
        const std::string end0 = findFace(faces, [](const auto& f) { return f.kind == FaceKind::Planar && std::fabs(f.origin.z) < 1e-9; });
        const std::string end1 = findFace(faces, [&](const auto& f) { return f.kind == FaceKind::Planar && std::fabs(f.origin.z - t) < 1e-9; });

        const std::string job = std::string(R"({"schema": "cadnext-structural-job/1",
            "geometry": {"format": "brep", "path": "pipe.brep"},
            "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.03, "refinementFactor": 1.6},
            "loadCase": {"name": "internal pressure 10 MPa",
              "supports": [{"face": ")") + symX + R"(", "fix": ["x"]}, {"face": ")" + symY + R"(", "fix": ["y"]},
                           {"face": ")" + end0 + R"(", "fix": ["z"]}, {"face": ")" + end1 + R"(", "fix": ["z"]}],
              "pressures": [{"face": ")" + bore + R"(", "pressurePa": )" + num(p) + R"(}]},
            "output": {"result": "pipe.result.json", "field": "pipe.field.json", "report": "pipe.report.html"}})";
        const int status = runJob("pipe", job);
        check(status == 0, "pipe: cadnext_structural completes (exit " + std::to_string(status) + ")");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "pipe.result.json"));

        const double factor = p * a * a / (b * b - a * a);
        const double sr = -p, st = factor * (1.0 + b * b / (a * a)), sz = steel.poissonRatio * (sr + st);
        const double vmExact = std::sqrt(0.5 * ((sr - st) * (sr - st) + (st - sz) * (st - sz) + (sz - sr) * (sz - sr)));
        const double urExact = (1.0 + steel.poissonRatio) * factor / steel.youngsModulusPa * ((1.0 - 2.0 * steel.poissonRatio) * a + b * b / a);
        std::printf("  pipe: outcome %s, σvM %.6g Pa (exact %.6g), u %.6g m (exact %.6g)%s\n",
                    result.stringOr("outcome", "?").c_str(), metric(result, "maxVonMisesPa"), vmExact,
                    metric(result, "maxDisplacementM"), urExact, joined(result, "warnings").c_str());
        checkRelative(metric(result, "maxVonMisesPa"), vmExact, 0.01, "pipe: max von Mises vs Lamé (plane strain)");
        checkRelative(metric(result, "maxDisplacementM"), urExact, 0.005, "pipe: max displacement vs Lamé");
        check(!contains(result, "warnings", "заделк"), "pipe: symmetry rollers do not raise the clamp-singularity warning");
        check(result.stringOr("outcome", "") == "pass", "pipe: converged, well within the steel's strength → PASS",
              result.stringOr("outcome", "?") + joined(result, "warnings"));
        const double reserve = metric(result, "reserveFactor");
        checkRelative(reserve, std::min(*steel.yieldStrengthPa / metric(result, "maxVonMisesPa"),
                                        steel.ultimateStrengthPa / (1.5 * metric(result, "maxVonMisesPa"))),
                      1e-9, "pipe: reserve factor = governing allowable / applied");

        const JsonValue field = parseOrEmpty(readText(workDirectory / "pipe.field.json"));
        const auto* nodes = field.member("nodes");
        const auto* triangles = field.member("triangles");
        const auto* vm = field.member("vonMisesPa");
        check(nodes && triangles && vm && nodes->arrayItems.size() % 3 == 0 && triangles->arrayItems.size() % 3 == 0
                  && vm->arrayItems.size() * 3 == nodes->arrayItems.size() && !triangles->arrayItems.empty(),
              "pipe: field file has surface nodes, triangles and a stress per node");
        check(result.stringOr("fieldRef", "") == "pipe.field.json", "pipe: result points at its field file");
        const std::string report = readText(workDirectory / "pipe.report.html");
        check(report.find("__CADNEXT_RESULT_JSON__") == std::string::npos && report.find("__CADNEXT_FIELD_JSON__") == std::string::npos
                  && report.find("\"cadnext-structural-field/1\"") != std::string::npos && report.find("</html>") != std::string::npos,
              "pipe: HTML report embeds both files");
        // Viewers read the colours from the file; they must be the ones the presentation contract defines.
        const auto parsedField = parseStructuralField(readText(workDirectory / "pipe.field.json"));
        bool sameColors = parsedField.isOk() && !parsedField.value().nodes.empty();
        if (sameColors) {
            const auto& f = parsedField.value();
            const auto allowable = presentation::allowableStress(steel, 1.5);
            sameColors = std::fabs(f.allowableStressPa - allowable.stressPa) < 1e-6;
            for (int n = 0; sameColors && n < static_cast<int>(f.nodes.size()); n += 7) {
                const auto fromFile = f.utilizationColor(n);
                const auto fromContract = presentation::utilizationColor(f.vonMisesPa[n] / allowable.stressPa);
                for (int c = 0; c < 3; ++c) sameColors = sameColors && std::fabs(fromFile[c] - fromContract[c]) < 1e-6f;
            }
        }
        check(sameColors, "pipe: colours decoded from the field file equal the presentation contract",
              parsedField.isOk() ? "" : parsedField.error().message);
        const auto* presentation = field.member("presentation");
        check(presentation && field.numberOr("allowableStressPa", 0) > 0 && presentation->member("colorStops")
                  && std::fabs(metric(result, "maxVonMisesPa") / field.numberOr("allowableStressPa", 1) - 1.0 / reserve) < 1e-9,
              "pipe: field carries the allowable, and peak utilisation is 1 / reserve factor");

        // Contract with the Swift side.
        const JsonValue fixture = parseOrEmpty(readText(schemaDirectory / "structural-result.example.json"));
        check(keys(&result) == keys(&fixture), "result top-level keys match schema/structural-result.example.json");
        check(keys(result.member("metrics")) == keys(fixture.member("metrics")), "result metric names match the example");
        const auto* metricEntry = result.member("metrics") ? result.member("metrics")->member("maxVonMisesPa") : nullptr;
        const auto* fixtureEntry = fixture.member("metrics") ? fixture.member("metrics")->member("maxVonMisesPa") : nullptr;
        check(keys(metricEntry) == keys(fixtureEntry), "metric entry keys match the example (value, unit, numericalUncertainty)");
        if (keys(&result) != keys(&fixture) || !std::filesystem::exists(schemaDirectory / "structural-result.example.json")) {
            writeText(workDirectory / "structural-result.produced.json", readText(workDirectory / "pipe.result.json"));
            std::printf("  produced result kept at %s\n", (workDirectory / "structural-result.produced.json").c_str());
        }
    }

    // --- 2 & 3. Cantilever.
    const double L = 1.0, w = 0.05, h = 0.05, P = 1000.0;
    const auto bar = kernel.makeExtrudedPolygon({{{0, 0, 0}, {0, w, 0}, {0, w, h}, {0, 0, h}}, {L, 0, 0}});
    const std::string barPath = exportPart(kernel, bar.value(), "bar");
    const auto barFaces = facesOfExportedPart(kernel, barPath);
    const std::string root = findFace(barFaces, [](const auto& f) { return f.kind == kernel::FaceKind::Planar && std::fabs(f.origin.x) < 1e-9; });
    const std::string tip = findFace(barFaces, [&](const auto& f) { return f.kind == kernel::FaceKind::Planar && std::fabs(f.origin.x - L) < 1e-9; });
    auto cantileverJob = [&](const std::string& name, const std::string& extra) {
        return std::string(R"({"schema": "cadnext-structural-job/1",
            "geometry": {"format": "brep", "path": "bar.brep"}, "material": "steel_4130",
            "mesh": {"coarseElementSizeM": 0.02, "refinementFactor": 1.6},
            "loadCase": {"name": ")") + name + R"(",
              "supports": [{"face": ")" + root + R"(", "fix": ["x", "y", "z"]}],
              "forces": [{"face": ")" + tip + R"(", "totalForceN": [0, 0, )" + num(-P) + R"(]}])" + extra + R"(},
            "output": {"result": ")" + name + R"(.result.json", "field": ")" + name + R"(.field.json", "report": ")" + name + R"(.report.html"}})";
    };
    {
        check(runJob("clamped", cantileverJob("clamped", "")) == 0, "clamped cantilever: completes");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "clamped.result.json"));
        std::printf("  clamped: outcome %s, σvM %.6g Pa%s\n", result.stringOr("outcome", "?").c_str(),
                    metric(result, "maxVonMisesPa"), joined(result, "warnings").c_str());
        check(result.stringOr("outcome", "") == "warning" && contains(result, "warnings", "заделк"),
              "clamped cantilever: maximum at the clamp is reported and does not PASS");
    }
    {
        const double d = 0.1;
        const std::string exclusion = R"(, "stressExclusions": [{"face": ")" + root + R"(", "distanceM": )" + num(d) + "}]";
        check(runJob("excluded", cantileverJob("excluded", exclusion)) == 0, "cantilever with exclusion: completes");
        const JsonValue result = parseOrEmpty(readText(workDirectory / "excluded.result.json"));
        const double I = w * h * h * h / 12.0;
        const double finest = 0.02 / (1.6 * 1.6);
        const double upper = P * (L - d) * (h / 2) / I * 1.01;
        const double lower = P * (L - d - finest) * (h / 2) / I * 0.99;
        const double measured = metric(result, "maxVonMisesPa");
        std::printf("  excluded: outcome %s, σvM %.6g Pa in [%.6g, %.6g]%s\n", result.stringOr("outcome", "?").c_str(),
                    measured, lower, upper, joined(result, "warnings").c_str());
        check(measured >= lower && measured <= upper, "cantilever with exclusion: maximum is the beam stress just past the zone");
        check(contains(result, "warnings", "зон исключения") && !contains(result, "warnings", "заделк"),
              "cantilever with exclusion: the exclusion is stated, the clamp warning is gone");
        const JsonValue* critical = result.member("criticalRegion");
        const JsonValue* point = critical ? critical->member("point") : nullptr;
        check(point && point->arrayItems.size() == 3 && point->arrayItems[0].numberValue >= d - 1e-9
                  && point->arrayItems[0].numberValue <= d + finest,
              "cantilever with exclusion: critical point lies at the edge of the zone");
    }

    // --- 4. Error path.
    {
        std::string job = cantileverJob("broken", "");
        const auto at = job.find(tip);
        job.replace(at, tip.size(), "face-99");
        const int status = runJob("broken", job);
        const JsonValue result = parseOrEmpty(readText(workDirectory / "broken.result.json"));
        check(status == 2 && result.stringOr("outcome", "") == "error" && contains(result, "failureReasons", "face-99"),
              "a load on a missing face is ERROR with the reason, exit 2 (got " + std::to_string(status) + ", "
                  + result.stringOr("outcome", "?") + ")");
    }

    return fea_test::finish("test_fea_structural_study");
}
