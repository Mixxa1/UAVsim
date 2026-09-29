// Assemblies through STEP, both ways: what goes out as a product structure must come back as the
// same structure — distinct parts stored once, subassemblies defined once, every occurrence where it
// was — and the file itself must say so.
//
// Model: part «Корпус» (a box 10 × 20 × 30 mm) and part «Вал» (a cylinder r = 5, h = 40 mm, green);
// subassembly «Узел» = { Корпус at the origin, Вал turned 90° about X and moved 50 mm along Y };
// root «Изделие» = { Узел, Узел again turned 30° about Z and moved 100 mm along X, Корпус alone
// 200 mm up }. Five occurrences of two parts.
//
// Criteria, fixed before the first run:
//   1. Read back, the structure has 2 parts and 2 assemblies — reuse survived; it did not come back
//      as five loose bodies.
//   2. The five leaf occurrences sit where they were sent, to 1e-9 m and 1e-12 in the rotation
//      matrix, compared as world placements composed along the path with quaternion arithmetic of
//      this file (not with the gp_Trsf the implementation uses).
//   3. Each part's volume matches to 1e-9 relative, names match exactly (Cyrillic included), and the
//      shaft's colour matches to 1e-6.
//   4. The file itself holds exactly 4 PRODUCT_DEFINITION entities (2 parts + 2 assemblies) and 5
//      NEXT_ASSEMBLY_USAGE_OCCURRENCE: the reuse is written, not reconstructed by our own reader.
//   5. The same for AP214 and AP242, and the schema line of each file names the schema asked for.
//   6. A cycle, an instance pointing past the list, a non-unit rotation and an empty structure are
//      refused before anything is written.

#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <Interface_Static.hxx>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <string>
#include <vector>

using namespace cadnext::kernel;

namespace {

int checks = 0, failures = 0;

void check(bool ok, const std::string& what, const std::string& detail = {}) {
    ++checks;
    if (!ok) ++failures;
    std::printf("  %s  %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.empty() ? "" : " — ", detail.c_str());
}

// Quaternions (w, x, y, z), independent of OCCT.
using Quat = std::array<double, 4>;
using Vec = std::array<double, 3>;

Quat multiply(const Quat& a, const Quat& b) {
    return {a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
            a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
            a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
            a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]};
}

Vec rotate(const Quat& q, const Vec& v) {
    const Quat p{0.0, v[0], v[1], v[2]};
    const Quat conjugate{q[0], -q[1], -q[2], -q[3]};
    const Quat r = multiply(multiply(q, p), conjugate);
    return {r[1], r[2], r[3]};
}

Quat aboutAxis(const Vec& axis, double radians) {
    const double s = std::sin(radians / 2.0);
    return {std::cos(radians / 2.0), axis[0] * s, axis[1] * s, axis[2] * s};
}

// The rotation matrix of a quaternion, to compare placements without the q / −q ambiguity.
std::array<double, 9> matrix(const Quat& q) {
    const Vec x = rotate(q, {1, 0, 0}), y = rotate(q, {0, 1, 0}), z = rotate(q, {0, 0, 1});
    return {x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2]};
}

struct World {
    std::string part;
    Quat rotation;
    Vec translation;
};

// Every leaf occurrence with its placement in the root's frame: parent ∘ child along the path.
void flatten(const ProductStructure& s, int assembly, const Quat& q, const Vec& t, std::vector<World>& out, int depth = 0) {
    if (depth > 32) return;
    for (const auto& instance : s.assemblies[assembly].instances) {
        const Quat childQ{instance.placement.rotation[0], instance.placement.rotation[1], instance.placement.rotation[2],
                          instance.placement.rotation[3]};
        const Vec childT{instance.placement.translation[0], instance.placement.translation[1], instance.placement.translation[2]};
        const Vec moved = rotate(q, childT);
        const Quat worldQ = multiply(q, childQ);
        const Vec worldT{t[0] + moved[0], t[1] + moved[1], t[2] + moved[2]};
        if (instance.isAssembly) {
            flatten(s, instance.definition, worldQ, worldT, out, depth + 1);
        } else {
            out.push_back({s.parts[instance.definition].name, worldQ, worldT});
        }
    }
}

int countMatches(const std::string& text, const std::string& entity) {
    const std::regex pattern("=\\s*" + entity + "\\s*\\(");
    return static_cast<int>(std::distance(std::sregex_iterator(text.begin(), text.end(), pattern), std::sregex_iterator()));
}

std::string readText(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

} // namespace

int main() {
    OcctKernel kernel;
    if (!kernel.isAvailable()) {
        std::printf("OCCT unavailable\n");
        return 1;
    }
    const auto box = kernel.makeBox({0.010, 0.020, 0.030});
    const auto cylinder = kernel.makeCylinder({0.005, 0.040});
    if (!box.isOk() || !cylinder.isOk()) {
        std::printf("primitives failed\n");
        return 1;
    }

    ProductStructure sent;
    sent.parts.push_back({"Корпус", box.value(), std::nullopt});
    sent.parts.push_back({"Вал", cylinder.value(), std::array<double, 3>{0.1, 0.6, 0.2}});
    ProductAssembly unit{"Узел", {}};
    unit.instances.push_back({"Корпус-1", {}, false, 0});
    {
        ProductInstance shaft{"Вал-1", {}, false, 1};
        const Quat q = aboutAxis({1, 0, 0}, M_PI / 2.0);
        shaft.placement.rotation = {q[0], q[1], q[2], q[3]};
        shaft.placement.translation = {0.0, 0.050, 0.0};
        unit.instances.push_back(shaft);
    }
    ProductAssembly root{"Изделие", {}};
    root.instances.push_back({"Узел-1", {}, true, 1});
    {
        ProductInstance second{"Узел-2", {}, true, 1};
        const Quat q = aboutAxis({0, 0, 1}, M_PI / 6.0);
        second.placement.rotation = {q[0], q[1], q[2], q[3]};
        second.placement.translation = {0.100, 0.0, 0.0};
        root.instances.push_back(second);
    }
    {
        ProductInstance loose{"Корпус-2", {}, false, 0};
        loose.placement.translation = {0.0, 0.0, 0.200};
        root.instances.push_back(loose);
    }
    sent.assemblies = {root, unit};
    sent.root = 0;

    std::vector<World> expected;
    flatten(sent, sent.root, {1, 0, 0, 0}, {0, 0, 0}, expected);
    const double boxVolume = kernel.volumeProperties(box.value()).value().volumeM3;
    const double shaftVolume = kernel.volumeProperties(cylinder.value()).value().volumeM3;

    const auto directory = std::filesystem::temp_directory_path() / "cadnext_step_product_structure";
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);

    for (const auto& [schema, schemaName, fileTag] :
         {std::tuple{StepSchema::AP214, "AP214", "AUTOMOTIVE_DESIGN"}, std::tuple{StepSchema::AP242, "AP242", "AP242"}}) {
        std::printf("%s\n", schemaName);
        const auto path = directory / (std::string("assembly-") + schemaName + ".step");
        const auto written = writeStepProductStructure(kernel, sent, path.string(), schema);
        check(written.isOk(), std::string(schemaName) + ": the structure is written", written.isOk() ? "" : written.error().message);
        if (!written.isOk()) continue;

        // --- 4, 5. The file itself.
        const std::string text = readText(path);
        const int definitions = countMatches(text, "PRODUCT_DEFINITION");
        const int usages = countMatches(text, "NEXT_ASSEMBLY_USAGE_OCCURRENCE");
        std::printf("  file: %d PRODUCT_DEFINITION, %d NEXT_ASSEMBLY_USAGE_OCCURRENCE\n", definitions, usages);
        check(definitions == 4 && usages == 5,
              std::string(schemaName) + ": the file stores 2 parts + 2 assemblies once each, and 5 occurrences",
              std::to_string(definitions) + " / " + std::to_string(usages));
        const auto schemaLine = text.find("FILE_SCHEMA");
        check(schemaLine != std::string::npos && text.substr(schemaLine, 200).find(fileTag) != std::string::npos,
              std::string(schemaName) + ": the file declares the schema asked for",
              schemaLine == std::string::npos ? "нет FILE_SCHEMA" : text.substr(schemaLine, 90));

        // --- 1. The structure read back.
        const auto read = readStepProductStructure(kernel, path.string());
        check(read.isOk(), std::string(schemaName) + ": the file is read back", read.isOk() ? "" : read.error().message);
        if (!read.isOk()) continue;
        const auto& back = read.value();
        check(back.parts.size() == 2 && back.assemblies.size() == 2,
              std::string(schemaName) + ": 2 parts and 2 assemblies came back, not five loose bodies",
              std::to_string(back.parts.size()) + " деталей, " + std::to_string(back.assemblies.size()) + " сборок");

        // --- 2. Placements, in the root's frame.
        std::vector<World> got;
        flatten(back, back.root, {1, 0, 0, 0}, {0, 0, 0}, got);
        bool placed = got.size() == expected.size();
        double worstT = 0.0, worstR = 0.0;
        std::vector<bool> used(got.size(), false);
        for (const auto& want : expected) {
            int match = -1;
            double bestT = 1e9;
            for (std::size_t i = 0; i < got.size(); ++i) {
                if (used[i] || got[i].part != want.part) continue;
                const double d = std::hypot(got[i].translation[0] - want.translation[0], got[i].translation[1] - want.translation[1],
                                            got[i].translation[2] - want.translation[2]);
                if (d < bestT) bestT = d, match = static_cast<int>(i);
            }
            if (match < 0) {
                placed = false;
                continue;
            }
            used[match] = true;
            const auto a = matrix(got[match].rotation), b = matrix(want.rotation);
            double r = 0.0;
            for (int k = 0; k < 9; ++k) r = std::max(r, std::fabs(a[k] - b[k]));
            worstT = std::max(worstT, bestT);
            worstR = std::max(worstR, r);
        }
        std::printf("  placements: %zu of %zu, worst %.3g m and %.3g in the rotation matrix\n", got.size(), expected.size(), worstT, worstR);
        check(placed && worstT <= 1e-9 && worstR <= 1e-12,
              std::string(schemaName) + ": all five occurrences sit where they were sent");

        // --- 3. Parts: volume, names, colour.
        const auto partNamed = [&](const std::string& name) -> const ProductPart* {
            for (const auto& part : back.parts)
                if (part.name == name) return &part;
            return nullptr;
        };
        const ProductPart* housing = partNamed("Корпус");
        const ProductPart* shaft = partNamed("Вал");
        const double housingVolume = housing ? kernel.volumeProperties(housing->shape).value().volumeM3 : 0.0;
        const double backShaftVolume = shaft ? kernel.volumeProperties(shaft->shape).value().volumeM3 : 0.0;
        check(housing && shaft && std::fabs(housingVolume / boxVolume - 1.0) <= 1e-9 && std::fabs(backShaftVolume / shaftVolume - 1.0) <= 1e-9,
              std::string(schemaName) + ": both parts keep their names and their volumes",
              housing && shaft ? "" : "имена деталей не сохранились");
        bool namesKept = back.assemblies[back.root].name == "Изделие";
        for (const auto& assembly : back.assemblies)
            for (const auto& instance : assembly.instances)
                namesKept = namesKept && (instance.name == "Корпус-1" || instance.name == "Вал-1" || instance.name == "Узел-1"
                                          || instance.name == "Узел-2" || instance.name == "Корпус-2");
        check(namesKept, std::string(schemaName) + ": the assembly and every occurrence keep their Cyrillic names");
        check(shaft && shaft->colour && std::fabs((*shaft->colour)[0] - 0.1) <= 1e-6 && std::fabs((*shaft->colour)[1] - 0.6) <= 1e-6
                  && std::fabs((*shaft->colour)[2] - 0.2) <= 1e-6,
              std::string(schemaName) + ": the shaft is still green");
    }

    // --- Units. Many SOLIDWORKS files, especially American ones, are in inches. A file whose
    // declared unit is the inch must read back to the same metres.
    std::printf("a file in inches\n");
    {
        const auto inches = directory / "assembly-inches.step";
        const char* previous = Interface_Static::CVal("write.step.unit");
        const std::string restore = previous ? previous : "MM";
        Interface_Static::SetCVal("write.step.unit", "INCH");
        const auto written = writeStepProductStructure(kernel, sent, inches.string());
        Interface_Static::SetCVal("write.step.unit", restore.c_str());
        const std::string text = readText(inches);
        const auto read = written.isOk() ? readStepProductStructure(kernel, inches.string()) : cadnext::Result<ProductStructure>::fail({});
        std::vector<World> got;
        if (read.isOk()) flatten(read.value(), read.value().root, {1, 0, 0, 0}, {0, 0, 0}, got);
        double worst = got.size() == expected.size() ? 0.0 : 1.0;
        for (const auto& want : expected) {
            double best = 1e9;
            for (const auto& g : got)
                if (g.part == want.part)
                    best = std::min(best, std::hypot(g.translation[0] - want.translation[0], g.translation[1] - want.translation[1],
                                                     g.translation[2] - want.translation[2]));
            worst = std::max(worst, best);
        }
        const bool declaresInch = text.find(".INCH.") != std::string::npos || text.find("'INCH'") != std::string::npos;
        const double volume = read.isOk() ? kernel.volumeProperties(read.value().parts[0].shape).value().volumeM3 : 0.0;
        const double want = read.isOk() && read.value().parts[0].name == "Вал" ? shaftVolume : boxVolume;
        std::printf("  declares inches: %s, worst placement %.3g m, part volume off by %.3g\n", declaresInch ? "yes" : "no", worst,
                    std::fabs(volume / want - 1.0));
        check(declaresInch && worst <= 1e-9 && std::fabs(volume / want - 1.0) <= 1e-9,
              "a file written in inches comes back in the same metres, placements and volumes alike");
    }

    // --- 6. Refusals.
    std::printf("refusals\n");
    ProductStructure cycle = sent;
    cycle.assemblies[1].instances.push_back({"сама в себе", {}, true, 1});
    ProductStructure past = sent;
    past.assemblies[0].instances.push_back({"в никуда", {}, false, 7});
    ProductStructure skewed = sent;
    skewed.assemblies[0].instances[2].placement.rotation = {2.0, 0.0, 0.0, 0.0};
    ProductStructure empty;
    const auto path = (directory / "refused.step").string();
    const auto a = writeStepProductStructure(kernel, cycle, path);
    const auto b = writeStepProductStructure(kernel, past, path);
    const auto c = writeStepProductStructure(kernel, skewed, path);
    const auto d = writeStepProductStructure(kernel, empty, path);
    check(!a.isOk() && a.error().message.find("сама себя") != std::string::npos && !b.isOk()
              && b.error().message.find("несуществующее") != std::string::npos && !c.isOk()
              && c.error().message.find("кватернион") != std::string::npos && !d.isOk() && !std::filesystem::exists(path),
          "a cycle, a dangling instance, a non-rigid rotation and an empty structure are refused, and nothing is written");

    // --- 7. Real files written by other systems: the NIST CAx reference models (set
    // CADNEXT_TEST_NIST_DIR to the folder with their .stp files). The structure reader and the
    // existing flat importer walk the same file independently; the total placed volume must agree.
    if (const char* nist = std::getenv("CADNEXT_TEST_NIST_DIR")) {
        std::printf("NIST reference STEP files\n");
        int files = 0;
        for (const auto& entry : std::filesystem::directory_iterator(nist)) {
            const std::string extension = entry.path().extension().string();
            if (extension != ".stp" && extension != ".step") continue;
            ++files;
            const std::string name = entry.path().filename().string();
            const auto structure = readStepProductStructure(kernel, entry.path().string());
            const auto flat = kernel.importStepAssembly(entry.path().string());
            if (!structure.isOk() || !flat.isOk()) {
                check(false, name + ": both readers accept the file",
                      structure.isOk() ? flat.error().message : structure.error().message);
                continue;
            }
            // Placed volume from the structure: each occurrence's part volume (placement is rigid).
            std::function<double(int)> placed = [&](int a) {
                double v = 0.0;
                for (const auto& instance : structure.value().assemblies[a].instances) {
                    v += instance.isAssembly ? placed(instance.definition)
                                             : kernel.volumeProperties(structure.value().parts[instance.definition].shape).value().volumeM3;
                }
                return v;
            };
            const double fromStructure = placed(structure.value().root);
            double fromFlat = 0.0;
            for (const auto& body : flat.value()) fromFlat += kernel.volumeProperties(body.shape).value().volumeM3;
            std::printf("  %s: %zu parts, %zu assemblies, %.9g m³ (flat importer %.9g m³)\n", name.c_str(),
                        structure.value().parts.size(), structure.value().assemblies.size(), fromStructure, fromFlat);
            check(fromFlat > 0.0 && std::fabs(fromStructure / fromFlat - 1.0) <= 1e-9,
                  name + ": the structure reader and the flat importer see the same solid");
        }
        check(files > 0, "the NIST folder holds reference STEP files");
    }

    std::printf("%d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
