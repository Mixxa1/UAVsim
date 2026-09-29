// A CADNext assembly through STEP and back, at the level of files a user keeps: .cadasm documents
// that link .cadnext parts.
//
// The same model as test_step_product_structure: «Корпус» (box) and «Вал» (cylinder, green) in a
// subassembly «Узел» inserted twice, plus a loose «Корпус». Five occurrences of two parts.
//
// Criteria, fixed before the first run:
//   1. STEP → CADNext writes exactly 2 .cadnext and 2 .cadasm; the top assembly has 3 components (two
//      links to the subassembly, one to a part) and the subassembly 2; the first component is
//      grounded and the rest are free.
//   2. Those files → STEP again → the same structure: 2 parts, 2 assemblies, the five occurrences to
//      1e-9 m and 1e-12 in the rotation matrix, each part's volume to 1e-9. Nothing is lost on the way
//      STEP → CADNext documents → STEP.
//   3. With the source STEP deleted, every written .cadnext still opens and its body has the part's
//      volume: the exact BRep lives in the file, not a reference to the STEP.
//   4. A defect found while building this: the assembly loader cached parts by path alone, so two
//      components linking to different bodies of one .cadnext got the same geometry. Two such links
//      must now export as two distinct parts with their own volumes.
//   5. A component linking to a missing file is refused with its name and no STEP is written; the
//      colour the STEP carried but the .cadnext cannot hold is named in the warnings.

#include "cadnext/Document.hpp"
#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/assembly/AssemblySerializer.hpp"
#include "cadnext/gui/AssemblyStepExchange.hpp"
#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

using namespace cadnext;
using namespace cadnext::kernel;
namespace fs = std::filesystem;

namespace {

int checks = 0, failures = 0;

void check(bool ok, const std::string& what, const std::string& detail = {}) {
    ++checks;
    if (!ok) ++failures;
    std::printf("  %s  %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.empty() ? "" : " — ", detail.c_str());
}

using Quat = std::array<double, 4>;
using Vec = std::array<double, 3>;

Quat multiply(const Quat& a, const Quat& b) {
    return {a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3], a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
            a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1], a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]};
}
Vec rotate(const Quat& q, const Vec& v) {
    const Quat r = multiply(multiply(q, {0.0, v[0], v[1], v[2]}), {q[0], -q[1], -q[2], -q[3]});
    return {r[1], r[2], r[3]};
}
Quat aboutAxis(const Vec& axis, double radians) {
    const double s = std::sin(radians / 2.0);
    return {std::cos(radians / 2.0), axis[0] * s, axis[1] * s, axis[2] * s};
}
std::array<double, 9> matrix(const Quat& q) {
    const Vec x = rotate(q, {1, 0, 0}), y = rotate(q, {0, 1, 0}), z = rotate(q, {0, 0, 1});
    return {x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2]};
}

struct World {
    std::string part;
    Quat rotation;
    Vec translation;
};

void flatten(const ProductStructure& s, int assembly, const Quat& q, const Vec& t, std::vector<World>& out, int depth = 0) {
    if (depth > 32) return;
    for (const auto& instance : s.assemblies[assembly].instances) {
        const auto& r = instance.placement.rotation;
        const auto& d = instance.placement.translation;
        const Vec moved = rotate(q, {d[0], d[1], d[2]});
        const Quat worldQ = multiply(q, {r[0], r[1], r[2], r[3]});
        const Vec worldT{t[0] + moved[0], t[1] + moved[1], t[2] + moved[2]};
        if (instance.isAssembly) {
            flatten(s, instance.definition, worldQ, worldT, out, depth + 1);
        } else {
            out.push_back({s.parts[instance.definition].name, worldQ, worldT});
        }
    }
}

// Worst translation and rotation-matrix deviation between two sets of occurrences, matched part by
// part; negative when the sets cannot be matched at all.
std::pair<double, double> compare(const std::vector<World>& want, const std::vector<World>& got) {
    if (want.size() != got.size()) return {-1.0, -1.0};
    std::vector<bool> used(got.size(), false);
    double worstT = 0.0, worstR = 0.0;
    for (const auto& w : want) {
        int match = -1;
        double best = 1e9;
        for (std::size_t i = 0; i < got.size(); ++i) {
            if (used[i] || got[i].part != w.part) continue;
            const double d = std::hypot(got[i].translation[0] - w.translation[0], got[i].translation[1] - w.translation[1],
                                        got[i].translation[2] - w.translation[2]);
            if (d < best) best = d, match = static_cast<int>(i);
        }
        if (match < 0) return {-1.0, -1.0};
        used[match] = true;
        const auto a = matrix(got[match].rotation), b = matrix(w.rotation);
        for (int k = 0; k < 9; ++k) worstR = std::max(worstR, std::fabs(a[k] - b[k]));
        worstT = std::max(worstT, best);
    }
    return {worstT, worstR};
}

std::vector<fs::path> filesWith(const fs::path& folder, const std::string& extension) {
    std::vector<fs::path> out;
    for (const auto& entry : fs::directory_iterator(folder))
        if (entry.path().extension() == extension) out.push_back(entry.path());
    std::sort(out.begin(), out.end());
    return out;
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
    const double boxVolume = kernel.volumeProperties(box.value()).value().volumeM3;
    const double shaftVolume = kernel.volumeProperties(cylinder.value()).value().volumeM3;

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
    std::vector<World> expected;
    flatten(sent, 0, {1, 0, 0, 0}, {0, 0, 0}, expected);

    const fs::path directory = fs::temp_directory_path() / "cadnext_assembly_step_exchange";
    fs::remove_all(directory);
    fs::create_directories(directory);
    const fs::path source = directory / "source.step";
    check(writeStepProductStructure(kernel, sent, source.string()).isOk(), "the source STEP is written");

    // --- 1. STEP → CADNext files.
    std::printf("STEP → CADNext\n");
    gui::AssemblyExchangeReport imported;
    const fs::path folder = directory / "imported";
    const auto top = gui::importStepAsAssembly(source.string(), folder.string(), imported);
    check(top.isOk(), "the STEP is written out as CADNext documents", top.isOk() ? "" : top.error().message);
    if (!top.isOk()) return 1;
    const auto parts = filesWith(folder, ".cadnext");
    const auto assemblies = filesWith(folder, ".cadasm");
    std::printf("  files: %zu .cadnext, %zu .cadasm; report %d parts, %d assemblies, %d occurrences\n", parts.size(), assemblies.size(),
                imported.parts, imported.assemblies, imported.occurrences);
    check(parts.size() == 2 && assemblies.size() == 2 && imported.occurrences == 5,
          "one .cadnext per distinct part and one .cadasm per distinct assembly, not one per occurrence");
    const auto topDocument = assembly::AssemblySerializer::loadFromFile(top.value());
    bool shape = topDocument.isOk() && topDocument.value().components().size() == 3;
    int subLinks = 0, partLinks = 0;
    if (topDocument.isOk()) {
        for (const auto& component : topDocument.value().components()) {
            (component.source.kind == assembly::PartSourceKind::Assembly ? subLinks : partLinks)++;
        }
        const auto& components = topDocument.value().components();
        shape = shape && subLinks == 2 && partLinks == 1 && components.front().isGrounded
                && std::none_of(components.begin() + 1, components.end(), [](const auto& c) { return c.isGrounded; });
    }
    check(shape, "the top assembly links the subassembly twice and a part once; only its first component is grounded",
          std::to_string(subLinks) + " подсборки, " + std::to_string(partLinks) + " деталь");
    check(std::any_of(imported.warnings.begin(), imported.warnings.end(), [](const std::string& w) { return w.find("цвет") != std::string::npos; }),
          "the colour the .cadnext cannot hold is named, not dropped silently");

    // --- 3. The parts stand on their own.
    fs::remove(source);
    bool standalone = parts.size() == 2;
    for (const auto& path : parts) {
        const auto document = DocumentSerializer::loadFromFile(path.string());
        if (!document.isOk() || document.value().objects().empty()) {
            standalone = false;
            continue;
        }
        const auto shapeBack = kernel.importBRep(document.value().objects().front().importedBRep);
        const double volume = shapeBack.isOk() ? kernel.volumeProperties(shapeBack.value()).value().volumeM3 : 0.0;
        standalone = standalone && (std::fabs(volume / boxVolume - 1.0) <= 1e-9 || std::fabs(volume / shaftVolume - 1.0) <= 1e-9);
    }
    check(standalone, "with the STEP deleted, each .cadnext opens with its exact body and volume");

    // --- 2. CADNext files → STEP → the same structure.
    std::printf("CADNext → STEP\n");
    const fs::path again = directory / "again.step";
    const auto exported = gui::exportAssemblyToStep(top.value(), again.string());
    check(exported.isOk(), "the imported assembly is exported again", exported.isOk() ? "" : exported.error().message);
    if (exported.isOk()) {
        const auto back = readStepProductStructure(kernel, again.string());
        check(back.isOk() && back.value().parts.size() == 2 && back.value().assemblies.size() == 2,
              "2 parts and 2 assemblies, as sent",
              back.isOk() ? std::to_string(back.value().parts.size()) + " / " + std::to_string(back.value().assemblies.size()) : back.error().message);
        if (back.isOk()) {
            std::vector<World> got;
            flatten(back.value(), back.value().root, {1, 0, 0, 0}, {0, 0, 0}, got);
            const auto [t, r] = compare(expected, got);
            std::printf("  placements: worst %.3g m, %.3g in the rotation matrix\n", t, r);
            check(t >= 0 && t <= 1e-9 && r <= 1e-12, "all five occurrences are where they were in the source STEP");
            bool volumes = true;
            for (const auto& part : back.value().parts) {
                const double v = kernel.volumeProperties(part.shape).value().volumeM3;
                const double want = part.name == "Вал" ? shaftVolume : boxVolume;
                volumes = volumes && std::fabs(v / want - 1.0) <= 1e-9;
            }
            check(volumes, "each part keeps its volume and its name through STEP → CADNext → STEP");
        }
    }

    // --- 2b. CADNext files → Parasolid XT (text and binary) → the same structure. Same criteria as
    // STEP: XT carries the doubles exactly; names are not written to XT yet, so parts are matched by
    // volume.
    for (const auto encoding : {gui::ParasolidXtEncoding::Text, gui::ParasolidXtEncoding::Binary}) {
        const bool text = encoding == gui::ParasolidXtEncoding::Text;
        std::printf("CADNext → Parasolid %s\n", text ? "x_t" : "x_b");
        const fs::path xt = directory / (text ? "again.x_t" : "again.x_b");
        const auto written = gui::exportAssemblyToParasolid(top.value(), xt.string(), encoding);
        check(written.isOk(), "the imported assembly is exported to Parasolid", written.isOk() ? "" : written.error().message);
        if (!written.isOk()) continue;
        const auto back = gui::readParasolidXtProduct(kernel, xt.string());
        check(back.isOk() && back.value().parts.size() == 2 && back.value().assemblies.size() == 2,
              "2 parts and 2 assemblies in the Parasolid file",
              back.isOk() ? std::to_string(back.value().parts.size()) + " / " + std::to_string(back.value().assemblies.size()) : back.error().message);
        if (!back.isOk()) continue;
        ProductStructure named = back.value();
        for (auto& part : named.parts) {
            const double v = kernel.volumeProperties(part.shape).value().volumeM3;
            part.name = std::fabs(v / shaftVolume - 1.0) <= 1e-9 ? "Вал" : "Корпус";
        }
        std::vector<World> got;
        flatten(named, named.root, {1, 0, 0, 0}, {0, 0, 0}, got);
        const auto [t, r] = compare(expected, got);
        std::printf("  placements: worst %.3g m, %.3g in the rotation matrix\n", t, r);
        check(t >= 0 && t <= 1e-9 && r <= 1e-12, "all five occurrences are where they were in the source STEP");
        std::vector<double> volumes, want{shaftVolume, boxVolume};
        for (const auto& part : back.value().parts) volumes.push_back(kernel.volumeProperties(part.shape).value().volumeM3);
        std::sort(volumes.begin(), volumes.end());
        std::sort(want.begin(), want.end());
        check(volumes.size() == 2 && std::fabs(volumes[0] / want[0] - 1.0) <= 1e-9 && std::fabs(volumes[1] / want[1] - 1.0) <= 1e-9,
              "each part keeps its volume through CADNext → Parasolid → CADNext");
    }

    // --- 4. Two bodies of one .cadnext, two different parts.
    std::printf("two bodies of one part file\n");
    {
        Document twoBodies;
        twoBodies.setName("Две детали");
        for (const auto& [id, name, handle] : {std::tuple{"body-box", "Брусок", box.value()}, std::tuple{"body-shaft", "Стержень", cylinder.value()}}) {
            Object body;
            body.id = id;
            body.name = name;
            body.type = ObjectType::Body;
            body.primitive.kind = PrimitiveKind::None;
            body.importedBRep = kernel.exportBRepGeometry(handle).value();
            twoBodies.addObject(body);
        }
        const fs::path partPath = directory / "two-bodies.cadnext";
        DocumentSerializer::saveToFile(twoBodies, partPath.string());
        assembly::AssemblyDocument document;
        document.setName("Две ссылки");
        for (const auto& [id, bodyId] : {std::pair{"c1", "body-box"}, std::pair{"c2", "body-shaft"}}) {
            assembly::AssemblyComponent component;
            component.id = id;
            component.name = bodyId;
            component.source.kind = assembly::PartSourceKind::CadnextDocument;
            component.source.filePath = partPath.string();
            component.source.bodyId = bodyId;
            component.isGrounded = std::string(id) == "c1";
            document.addComponent(component);
        }
        const fs::path assemblyPath = directory / "two-links.cadasm";
        assembly::AssemblySerializer::saveToFile(document, assemblyPath.string());
        const fs::path stepPath = directory / "two-links.step";
        const auto written = gui::exportAssemblyToStep(assemblyPath.string(), stepPath.string());
        const auto back = written.isOk() ? readStepProductStructure(kernel, stepPath.string()) : Result<ProductStructure>::fail({});
        std::vector<double> volumes;
        if (back.isOk())
            for (const auto& part : back.value().parts) volumes.push_back(kernel.volumeProperties(part.shape).value().volumeM3);
        std::sort(volumes.begin(), volumes.end());
        const std::vector<double> want = [&] {
            std::vector<double> v{boxVolume, shaftVolume};
            std::sort(v.begin(), v.end());
            return v;
        }();
        check(volumes.size() == 2 && std::fabs(volumes[0] / want[0] - 1.0) <= 1e-9 && std::fabs(volumes[1] / want[1] - 1.0) <= 1e-9,
              "two links to different bodies of one file export as two parts with their own volumes",
              written.isOk() ? std::to_string(volumes.size()) + " деталей" : written.error().message);
    }

    // --- 5. A missing part is refused, and nothing is written.
    std::printf("refusals\n");
    {
        assembly::AssemblyDocument document;
        document.setName("Без детали");
        assembly::AssemblyComponent component;
        component.id = "c1";
        component.name = "Потерянный кронштейн";
        component.source.kind = assembly::PartSourceKind::CadnextDocument;
        component.source.filePath = (directory / "нет такого файла.cadnext").string();
        component.isGrounded = true;
        document.addComponent(component);
        const fs::path assemblyPath = directory / "missing.cadasm";
        assembly::AssemblySerializer::saveToFile(document, assemblyPath.string());
        const fs::path stepPath = directory / "missing.step";
        const auto written = gui::exportAssemblyToStep(assemblyPath.string(), stepPath.string());
        check(!written.isOk() && written.error().message.find("Потерянный кронштейн") != std::string::npos && !fs::exists(stepPath),
              "a component whose part file is missing is refused by name, and no STEP appears",
              written.isOk() ? "приняли" : written.error().message);
    }

    std::printf("%d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
