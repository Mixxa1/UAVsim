// CADNext against a real, independent CAD system: FreeCAD, run headless through FreeCADCmd. The
// other tests read our files back with our own reader; this one lets someone else read them, and
// reads what someone else wrote.
//
//   CADNEXT_TEST_FREECADCMD=/Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd
//
// Without it the test reports itself as skipped (exit 77), never as passed.
//
// The model is the one of test_step_product_structure: «Корпус» (box 10 × 20 × 30 mm) and «Вал»
// (cylinder r = 5, h = 40 mm) in a subassembly «Узел» inserted twice, plus a loose «Корпус».
//
// Criteria, fixed before the first run:
//   1. Our STEP (AP214 and AP242) read by FreeCAD: 5 solids, total volume 2·(box + shaft) + box to
//      1e-6 relative, bounding box to 1e-6 m (1e-3 mm), and the Cyrillic part names among FreeCAD's
//      labels. 1e-6 rather than 1e-9 because FreeCAD may heal shapes on reading and computes volume
//      with its own settings — still six orders below a real mistake: a millimetre/metre slip is a
//      factor 10⁹ in volume, a misplaced occurrence moves the box by centimetres.
//   2. Our .FCStd (the existing writer) opened by FreeCAD itself: both bodies there, with their
//      names and their volumes to 1e-6.
//   3. FreeCAD's own assembly (App::Part «Узел» linked twice, a loose link to «Корпус») exported by
//      FreeCAD and read by us: 2 distinct parts, 5 leaf occurrences, and the same total volume and
//      bounding box FreeCAD reports for the file, to 1e-6.

#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <QByteArray>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QString>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
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

std::string freecad;
fs::path scriptPath;

QJsonObject runFreeCad(const std::string& task, const fs::path& input, const fs::path& output, const fs::path& report) {
    fs::remove(report);
    const std::string command = "CADNEXT_FREECAD_TASK=" + task + " CADNEXT_FREECAD_INPUT=\"" + input.string() + "\" CADNEXT_FREECAD_OUTPUT=\""
                                + output.string() + "\" CADNEXT_FREECAD_REPORT=\"" + report.string() + "\" \"" + freecad + "\" \""
                                + scriptPath.string() + "\" > /dev/null 2>&1";
    std::system(command.c_str());
    std::ifstream stream(report, std::ios::binary);
    const std::string text{std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    return QJsonDocument::fromJson(QByteArray::fromStdString(text)).object();
}

using Quat = std::array<double, 4>;
Quat multiply(const Quat& a, const Quat& b) {
    return {a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3], a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
            a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1], a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]};
}
std::array<double, 3> rotate(const Quat& q, const std::array<double, 3>& v) {
    const Quat r = multiply(multiply(q, {0.0, v[0], v[1], v[2]}), {q[0], -q[1], -q[2], -q[3]});
    return {r[1], r[2], r[3]};
}
Quat aboutAxis(const std::array<double, 3>& axis, double radians) {
    const double s = std::sin(radians / 2.0);
    return {std::cos(radians / 2.0), axis[0] * s, axis[1] * s, axis[2] * s};
}

// Every leaf occurrence placed in the root frame; its total volume and bounding box, in metres.
struct Placed {
    int solids = 0;
    double volume = 0.0;
    std::array<double, 6> box{1e300, 1e300, 1e300, -1e300, -1e300, -1e300};
    int occurrences = 0;
};

void place(OcctKernel& kernel, const ProductStructure& s, int assembly, const Quat& q, const std::array<double, 3>& t, Placed& out) {
    for (const auto& instance : s.assemblies[assembly].instances) {
        const auto& r = instance.placement.rotation;
        const auto moved = rotate(q, instance.placement.translation);
        const Quat worldQ = multiply(q, {r[0], r[1], r[2], r[3]});
        const std::array<double, 3> worldT{t[0] + moved[0], t[1] + moved[1], t[2] + moved[2]};
        if (instance.isAssembly) {
            place(kernel, s, instance.definition, worldQ, worldT, out);
            continue;
        }
        const auto x = rotate(worldQ, {1, 0, 0}), y = rotate(worldQ, {0, 1, 0}), z = rotate(worldQ, {0, 0, 1});
        const std::array<double, 16> matrix{x[0], x[1], x[2], 0, y[0], y[1], y[2], 0, z[0], z[1], z[2], 0, worldT[0], worldT[1], worldT[2], 1};
        const auto moved2 = kernel.transformShape(s.parts[instance.definition].shape, matrix);
        if (!moved2.isOk()) continue;
        const auto props = kernel.volumeProperties(moved2.value());
        const auto bounds = kernel.boundingBox(moved2.value());
        if (!props.isOk() || !bounds.isOk()) continue;
        out.volume += props.value().volumeM3;
        out.solids += 1;
        out.occurrences += 1;
        const auto& b = bounds.value();
        out.box = {std::min(out.box[0], b.min.x), std::min(out.box[1], b.min.y), std::min(out.box[2], b.min.z),
                   std::max(out.box[3], b.max.x), std::max(out.box[4], b.max.y), std::max(out.box[5], b.max.z)};
    }
}

double boxDeviationM(const std::array<double, 6>& ours, const QJsonArray& theirsMm) {
    double worst = 0.0;
    for (int k = 0; k < 6; ++k) worst = std::max(worst, std::fabs(ours[k] - theirsMm[k].toDouble() / 1000.0));
    return worst;
}

} // namespace

int main() {
    const char* configured = std::getenv("CADNEXT_TEST_FREECADCMD");
    if (!configured || !fs::exists(configured)) {
        std::printf("FreeCADCmd не задан (CADNEXT_TEST_FREECADCMD) — внешняя проверка пропущена\n");
        return 77;
    }
    freecad = configured;
    scriptPath = fs::path(CADNEXT_FREECAD_SCRIPT);

    OcctKernel kernel;
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
    Placed ours;
    place(kernel, sent, 0, {1, 0, 0, 0}, {0, 0, 0}, ours);
    const double expectedVolume = 2.0 * (boxVolume + shaftVolume) + boxVolume;

    const fs::path directory = fs::temp_directory_path() / "cadnext_freecad_interchange";
    fs::remove_all(directory);
    fs::create_directories(directory);
    const fs::path report = directory / "report.json";

    // --- 1. Our STEP, read by FreeCAD.
    for (const auto& [schema, name] : {std::pair{StepSchema::AP214, "AP214"}, std::pair{StepSchema::AP242, "AP242"}}) {
        std::printf("CADNext STEP %s → FreeCAD\n", name);
        const fs::path step = directory / (std::string("cadnext-") + name + ".step");
        check(writeStepProductStructure(kernel, sent, step.string(), schema).isOk(), std::string(name) + ": written");
        const QJsonObject result = runFreeCad("inspect-step", step, {}, report);
        if (!result.value("ok").toBool()) {
            check(false, std::string(name) + ": FreeCAD reads the file", result.value("error").toString().toStdString());
            continue;
        }
        const QJsonObject geometry = result.value("geometry").toObject();
        const int solids = geometry.value("solids").toInt();
        const double volume = geometry.value("volume").toDouble() * 1e-9; // mm³ → m³
        const double boxOff = boxDeviationM(ours.box, geometry.value("bbox").toArray());
        std::printf("  FreeCAD %s: %d solids, %.9g m³ (ours %.9g), bbox off by %.3g m\n",
                    result.value("freecad").toString().toStdString().c_str(), solids, volume, expectedVolume, boxOff);
        check(solids == 5 && std::fabs(volume / expectedVolume - 1.0) <= 1e-6 && boxOff <= 1e-6,
              std::string(name) + ": FreeCAD sees five solids with our volume, where we put them");
        QStringList labels;
        for (const auto& label : result.value("labels").toArray()) labels << label.toString();
        check(labels.contains(QStringLiteral("Корпус")) && labels.contains(QStringLiteral("Вал")),
              std::string(name) + ": the Cyrillic part names reach FreeCAD's tree",
              labels.join(QStringLiteral(", ")).toStdString());
    }

    // --- 2. Our FCStd, opened by FreeCAD.
    std::printf("CADNext FCStd → FreeCAD\n");
    {
        std::vector<gui::FreeCadShape> shapes;
        ExchangeBody housing{box.value(), {}};
        housing.placement.position = {0.0, 0.0, 0.050};
        ExchangeBody shaft{cylinder.value(), {}};
        const auto housingBrep = kernel.exportFreeCadBRep(housing);
        const auto shaftBrep = kernel.exportFreeCadBRep(shaft);
        shapes.push_back({QStringLiteral("Корпус"), QByteArray(reinterpret_cast<const char*>(housingBrep.value().data()),
                                                               qsizetype(housingBrep.value().size())), false});
        shapes.push_back({QStringLiteral("Вал"), QByteArray(reinterpret_cast<const char*>(shaftBrep.value().data()),
                                                            qsizetype(shaftBrep.value().size())), false});
        const fs::path fcstd = directory / "cadnext.FCStd";
        QString error;
        check(gui::writeFreeCadShapes(QString::fromStdString(fcstd.string()), shapes, error), "FCStd written", error.toStdString());
        const QJsonObject result = runFreeCad("inspect-fcstd", fcstd, {}, report);
        bool found = result.value("ok").toBool();
        int matched = 0;
        for (const auto& value : result.value("bodies").toArray()) {
            const QJsonObject body = value.toObject();
            const double v = body.value("volume").toDouble() * 1e-9;
            const QString label = body.value("label").toString();
            if (label == QStringLiteral("Корпус") && std::fabs(v / boxVolume - 1.0) <= 1e-6) ++matched;
            if (label == QStringLiteral("Вал") && std::fabs(v / shaftVolume - 1.0) <= 1e-6) ++matched;
        }
        std::printf("  FreeCAD opened it: %lld bodies, %d matched by name and volume\n",
                    static_cast<long long>(result.value("bodies").toArray().size()), matched);
        check(found && matched == 2, "FreeCAD opens our FCStd with both bodies, their names and their volumes",
              found ? "" : result.value("error").toString().toStdString());
    }

    // --- 3. FreeCAD's own assembly, read by us.
    std::printf("FreeCAD STEP → CADNext\n");
    {
        const fs::path step = directory / "freecad-assembly.step";
        const QJsonObject result = runFreeCad("build-step", {}, step, report);
        if (!result.value("ok").toBool() || !fs::exists(step)) {
            check(false, "FreeCAD builds and exports its assembly", result.value("error").toString().toStdString());
        } else {
            const auto read = readStepProductStructure(kernel, step.string());
            check(read.isOk(), "we read FreeCAD's STEP", read.isOk() ? "" : read.error().message);
            if (read.isOk()) {
                Placed theirs;
                place(kernel, read.value(), read.value().root, {1, 0, 0, 0}, {0, 0, 0}, theirs);
                const QJsonObject geometry = result.value("geometry").toObject();
                const double volume = geometry.value("volume").toDouble() * 1e-9;
                const double boxOff = boxDeviationM(theirs.box, geometry.value("bbox").toArray());
                std::printf("  ours: %zu parts, %zu assemblies, %d occurrences, %.9g m³; FreeCAD: %d solids, %.9g m³; bbox off by %.3g m\n",
                            read.value().parts.size(), read.value().assemblies.size(), theirs.occurrences, theirs.volume,
                            geometry.value("solids").toInt(), volume, boxOff);
                check(read.value().parts.size() == 2 && theirs.occurrences == 5,
                      "FreeCAD's assembly arrives as 2 parts in 5 occurrences, not five loose bodies");
                check(std::fabs(theirs.volume / volume - 1.0) <= 1e-6 && boxOff <= 1e-6,
                      "and it has the volume and the extent FreeCAD itself reports for the file");
            }
        }
    }

    std::printf("%d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
