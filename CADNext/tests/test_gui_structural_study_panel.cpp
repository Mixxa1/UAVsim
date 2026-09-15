// The «Прочность детали» panel end to end, as a user drives it: a part built by the kernel, faces
// picked (here: set as the viewport selection), supports and loads assigned, the job validated,
// cadnext_structural run as a process, the result read back.
//
//   cadnext_test_gui_structural_study_panel <cadnext_structural> [panel.png [modal-panel.png]]
//
// Checked: every "not runnable yet" state names its reason; a face of another body is refused; a
// load whose face disappeared from the part blocks the run; the job the panel writes is the job
// the tool reads; a run finishes with a result; a cancelled run reports cancellation, not a
// result. Then the same panel switched to natural modes: the loads stay listed but out of the job,
// the mode count has no default, the run's result opens in the modal window. With a second
// argument the panel (static) is saved as an image, with a third the modal one.

#include "fea_test_support.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/gui/ModalResultWindow.hpp"
#include "cadnext/gui/StructuralResultWindow.hpp"
#include "cadnext/gui/StructuralStudyPanel.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <Inventor/Qt/SoQt.h>

#include <QApplication>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QTimer>

#include <algorithm>
#include <cmath>

using namespace cadnext;
using fea_test::check;
using Panel = gui::StructuralStudyPanel;

namespace {

std::string faceWhere(const std::vector<kernel::FaceReference>& faces,
                      const std::function<bool(const kernel::FaceReference&)>& predicate) {
    for (const auto& face : faces)
        if (predicate(face)) return face.faceId;
    return {};
}

// Waits for finished(); the timeout only guards against a hung process in CI.
std::pair<QString, QString> waitForFinish(Panel& panel, int timeoutMs) {
    QEventLoop loop;
    std::pair<QString, QString> outcome{QString(), QStringLiteral("timeout")};
    QObject::connect(&panel, &Panel::finished, &loop, [&](const QString& path, const QString& message) {
        outcome = {path, message};
        loop.quit();
    });
    QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
    loop.exec();
    return outcome;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::printf("usage: %s <cadnext_structural> [panel.png [modal-panel.png]]\n", argv[0]);
        return 64;
    }
    QStandardPaths::setTestModeEnabled(true); // work folders go to the test location, not the user's
    qputenv("CADNEXT_STRUCTURAL_TOOL", QByteArray(argv[1]));
    QApplication app(argc, argv);
    SoQt::init(static_cast<QWidget*>(nullptr));

    kernel::OcctKernel kernel;
    const double L = 1.0, w = 0.05, h = 0.05;
    const auto bar = kernel.makeExtrudedPolygon({{{0, 0, 0}, {0, w, 0}, {0, w, h}, {0, 0, h}}, {L, 0, 0}});
    std::vector<kernel::FaceReference> faces = kernel::FaceAnalyzer(kernel).planarFacesForBody("bar", bar.value());
    const std::string root = faceWhere(faces, [](const auto& f) { return std::fabs(f.origin.x) < 1e-9; });
    const std::string tip = faceWhere(faces, [&](const auto& f) { return std::fabs(f.origin.x - L) < 1e-9; });
    check(!root.empty() && !tip.empty(), "root and tip faces found");

    std::optional<std::pair<std::string, std::string>> selection;
    gui::StructuralPartContext context;
    context.selectedFace = [&]() { return selection; };
    context.bodyFaces = [&](const std::string& bodyId) {
        return bodyId == "bar" ? faces : std::vector<kernel::FaceReference>{};
    };
    context.bodyName = [](const std::string&) { return QStringLiteral("Консоль"); };
    context.bodyMaterialId = [](const std::string&) { return std::optional<std::string>(); };
    context.exportBody = [&](const std::string&) { return kernel.exportBRep(bar.value()); };
    context.selectFace = [&](const std::string& bodyId, const std::string& faceId) { selection = std::make_pair(bodyId, faceId); };

    Panel panel(context);
    panel.resize(420, 760);
    auto reason = [&]() {
        const auto job = panel.buildJob();
        return job.isOk() ? std::string() : job.error().message;
    };

    check(reason().find("Нет опор") != std::string::npos, "empty panel: says there are no supports and loads", reason());
    check(!panel.addItemOnSelectedFace({}).isEmpty(), "adding with nothing selected is refused");

    selection = std::make_pair("bar", root);
    panel.selectionChanged();
    check(panel.addItemOnSelectedFace({Panel::ItemKind::Support, {}, {true, true, true}}).isEmpty(), "clamp on the root face");
    check(reason().find("Нет нагрузок") != std::string::npos, "support only: says there is no load", reason());

    selection = std::make_pair("other-body", root);
    check(!panel.addItemOnSelectedFace({Panel::ItemKind::Pressure}).isEmpty(), "a face of another body is refused");

    selection = std::make_pair("bar", tip);
    Panel::Item force;
    force.kind = Panel::ItemKind::Force;
    force.forceN = {0.0, 0.0, -1000.0};
    check(panel.addItemOnSelectedFace(force).isEmpty(), "force on the tip face");
    check(reason().find("материал") != std::string::npos, "no material chosen: refused, nothing preselected", reason());
    panel.setMaterialId("steel_4130");
    check(reason().find("сетки") != std::string::npos, "no element size: refused", reason());
    panel.setMeshSettings(0.02, 1.6);
    panel.setLoadCaseName(QStringLiteral("Консоль, 1 кН на конце"));
    const auto job = panel.buildJob();
    check(job.isOk(), "complete panel builds a job", reason());
    if (job.isOk()) {
        const auto& j = job.value();
        const std::string rootIndex = root.substr(0, root.find('-', 5));
        const std::string tipIndex = tip.substr(0, tip.find('-', 5));
        check(j.loadCase.supports.size() == 1 && j.loadCase.supports[0].face == rootIndex
                  && j.loadCase.forces.size() == 1 && j.loadCase.forces[0].face == tipIndex
                  && std::fabs(j.loadCase.forces[0].totalForceN.z + 1000.0) < 1e-12 && j.materialId == std::string("steel_4130"),
              "job carries the picked faces by kernel index, the force and the material");
    }

    // A load whose face vanished (the part was edited) blocks the run.
    {
        const auto saved = faces;
        faces.erase(std::remove_if(faces.begin(), faces.end(), [&](const auto& f) { return f.faceId == tip; }), faces.end());
        check(reason().find("больше не существует") != std::string::npos, "a load on a face that no longer exists blocks the run", reason());
        faces = saved;
    }

    if (argc > 2) {
        panel.selectionChanged();
        check(panel.grab().save(QString::fromLocal8Bit(argv[2])), "panel image saved");
    }

    // Full run through the process.
    const QString started = panel.run();
    check(started.isEmpty() && panel.isRunning(), "run starts the solver process", started.toStdString());
    const auto [resultPath, message] = started.isEmpty() ? waitForFinish(panel, 180000) : std::make_pair(QString(), started);
    check(!resultPath.isEmpty() && QFileInfo::exists(resultPath), "run finishes with a result file (" + message.toStdString() + ")");
    if (!resultPath.isEmpty()) {
        QFile resultFile(resultPath);
        check(resultFile.open(QIODevice::ReadOnly), "result file opens");
        fea::json::JsonValue result;
        std::string error;
        fea::json::parseJson(resultFile.readAll().toStdString(), result, error);
        check(result.stringOr("outcome", "") == "warning", "clamped cantilever through the panel: WARNING, as through the command line");
        QFile jobFile(QFileInfo(resultPath).dir().filePath("job.json"));
        check(jobFile.open(QIODevice::ReadOnly), "job file opens");
        check(jobFile.readAll().toStdString() == fea::structuralJobJson(job.value()), "the job on disk is the job the panel built");
        check(QFileInfo::exists(QFileInfo(resultPath).dir().filePath("report.html")), "the run also leaves its HTML report");

        auto* window = new gui::StructuralResultWindow();
        check(window->openResult(resultPath), "the result opens in the result window");
        window->close();
    }

    // Cancel.
    const QString restarted = panel.run();
    check(restarted.isEmpty(), "second run starts", restarted.toStdString());
    QTimer::singleShot(200, &panel, [&panel]() { panel.cancel(); });
    const auto [cancelledPath, cancelledMessage] = restarted.isEmpty() ? waitForFinish(panel, 60000) : std::make_pair(QString(), restarted);
    check(cancelledPath.isEmpty() && cancelledMessage.contains(QStringLiteral("отменён")),
          "a cancelled run reports cancellation and no result (" + cancelledMessage.toStdString() + ")");

    // --- Natural modes with the same supports.
    panel.setAnalysis(fea::StructuralAnalysis::Modal);
    check(reason().find("число мод") != std::string::npos, "modal: no mode count, refused (no default)", reason());
    panel.setModeCount(2);
    panel.addRotor({"rotor", 3000.0, 6000.0, 2});
    const auto modalJob = panel.buildJob();
    check(modalJob.isOk(), "modal: complete panel builds a job", reason());
    if (modalJob.isOk()) {
        const auto& j = modalJob.value();
        check(j.analysis == fea::StructuralAnalysis::Modal && j.loadCase.supports.size() == 1 && j.loadCase.forces.empty()
                  && j.loadCase.pressures.empty() && length(j.loadCase.bodyAccelerationMps2) == 0.0 && j.modal.modeCount == 2
                  && j.modal.rotors.size() == 1 && j.modal.separationMargin == 0.0,
              "modal job: supports only, loads left out, rotor and mode count as set, no margin unless set");
        check(fea::parseStructuralJob(fea::structuralJobJson(j), "/tmp").isOk(), "modal job the panel writes is one the tool accepts");
    }
    if (argc > 3) check(panel.grab().save(QString::fromLocal8Bit(argv[3])), "modal panel image saved");
    const QString modalStarted = panel.run();
    check(modalStarted.isEmpty(), "modal run starts", modalStarted.toStdString());
    const auto [modalPath, modalMessage] = modalStarted.isEmpty() ? waitForFinish(panel, 180000) : std::make_pair(QString(), modalStarted);
    check(!modalPath.isEmpty(), "modal run finishes with a result file (" + modalMessage.toStdString() + ")");
    if (!modalPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(modalPath, &error);
        check(dynamic_cast<gui::ModalResultWindow*>(window) != nullptr, "a modal result gets the modal window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(modalPath), "the modal result opens");
            if (auto* modalWindow = dynamic_cast<gui::ModalResultWindow*>(window)) {
                modalWindow->selectMode(1);
                check(modalWindow->selectedMode() == 1 && modalWindow->isPlaying(), "mode 2 selected, shape animating");
            }
            window->close();
        }
        if (resultPath.isEmpty() == false) {
            gui::AnalysisResultWindow* staticWindow = gui::AnalysisResultWindow::forResultFile(resultPath, &error);
            check(dynamic_cast<gui::StructuralResultWindow*>(staticWindow) != nullptr, "a strength result gets the strength window");
            delete staticWindow;
        }
    }

    return fea_test::finish("test_gui_structural_study_panel");
}
