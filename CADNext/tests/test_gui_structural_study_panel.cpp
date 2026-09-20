// The «Прочность детали» panel end to end, as a user drives it: a part built by the kernel, faces
// picked (here: set as the viewport selection), supports and loads assigned, the job validated,
// cadnext_structural run as a process, the result read back.
//
//   cadnext_test_gui_structural_study_panel <cadnext_structural> [panel.png [modal-panel.png [random-panel.png [climate-window.png [fire-window.png
//   [lightning-window.png]]]]]]
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
        std::printf("usage: %s <cadnext_structural> [panel.png [modal-panel.png [random-panel.png]]]\n", argv[0]);
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
        check(QFileInfo::exists(QFileInfo(resultPath).dir().filePath("field.json")), "the run leaves its native field artifact");

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

    // --- Sine vibration through the panel: the supports are the fixture, ζ and the range have no
    // default, a shaker run opens in the strength window with the frequency response.
    panel.setAnalysis(fea::StructuralAnalysis::Harmonic);
    check(reason().find("амплитуда") != std::string::npos, "vibration: no amplitude yet, refused", reason());
    panel.setVibration(Panel::VibrationKind::Base, 2, 1.0, 0.0, 6, 5.0, 80.0);
    check(reason().find("демпфирование") != std::string::npos, "vibration: no damping, refused (no default)", reason());
    panel.setVibration(Panel::VibrationKind::Imbalance, 2, 20.0, 0.02, 6, 5.0, 80.0);
    check(reason().find("грань силы") != std::string::npos, "vibration: an imbalance needs its face", reason());
    selection = std::make_pair(std::string("bar"), tip);
    check(panel.setVibrationFaceFromSelection().isEmpty() && panel.setProbeFaceFromSelection().isEmpty(), "force face and probe on the tip");
    const auto imbalanceJob = panel.buildJob();
    check(imbalanceJob.isOk() && std::fabs(imbalanceJob.value().harmonic.excitation.imbalanceKgM - 2e-5) < 1e-18
              && imbalanceJob.value().harmonic.excitation.amplitude.empty(),
          "vibration: 20 g·mm of imbalance is written as 2e-5 kg·m, no amplitude", reason());
    panel.setVibration(Panel::VibrationKind::Base, 2, 1.0, 0.02, 6, 5.0, 80.0);
    const auto shakerJob = panel.buildJob();
    check(shakerJob.isOk(), "vibration: complete shaker panel builds a job", reason());
    if (shakerJob.isOk()) {
        const auto& j = shakerJob.value();
        check(j.analysis == fea::StructuralAnalysis::Harmonic && j.loadCase.forces.empty() && j.loadCase.supports.size() == 1
                  && std::fabs(j.harmonic.excitation.amplitude.front().amplitude - 9.80665) < 1e-12 && j.harmonic.dampingRatio == 0.02,
              "vibration job: supports as fixture, loads left out, 1 g as 9.80665 m/s², ζ as set");
        check(fea::parseStructuralJob(fea::structuralJobJson(j), "/tmp").isOk(), "vibration job the panel writes is one the tool accepts");
    }
    const QString shakerStarted = panel.run();
    check(shakerStarted.isEmpty(), "vibration run starts", shakerStarted.toStdString());
    const auto [shakerPath, shakerMessage] = shakerStarted.isEmpty() ? waitForFinish(panel, 180000) : std::make_pair(QString(), shakerStarted);
    check(!shakerPath.isEmpty(), "vibration run finishes with a result file (" + shakerMessage.toStdString() + ")");
    if (!shakerPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(shakerPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a vibration result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(shakerPath), "the vibration result opens");
            window->close();
        }
    }

    // --- Random vibration: the spectrum in g²/Hz becomes (m/s²)²/Hz in the job; a one-point spectrum is
    // refused; the run opens in the strength window.
    panel.setAnalysis(fea::StructuralAnalysis::Random);
    panel.setRandomVibration(2, {{5.0, 0.01}}, 0.02, 6);
    check(reason().find("двух точек") != std::string::npos, "random: a one-point spectrum is refused", reason());
    panel.setRandomVibration(2, {{5.0, 0.01}, {100.0, 0.01}}, 0.02, 6);
    const auto randomJob = panel.buildJob();
    check(randomJob.isOk(), "random: complete panel builds a job", reason());
    if (randomJob.isOk()) {
        const auto& r = randomJob.value().random;
        check(randomJob.value().analysis == fea::StructuralAnalysis::Random && r.accelerationPsd.size() == 2
                  && std::fabs(r.accelerationPsd[0].amplitude - 0.01 * 9.80665 * 9.80665) < 1e-12 && r.dampingRatio == 0.02 && r.modeCount == 6,
              "random job: 0.01 g²/Hz written as (m/s²)²/Hz, ζ and modes as set");
        check(fea::parseStructuralJob(fea::structuralJobJson(randomJob.value()), "/tmp").isOk(), "random job the panel writes is one the tool accepts");
    }
    if (argc > 4) check(panel.grab().save(QString::fromLocal8Bit(argv[4])), "random panel image saved");
    const QString randomStarted = panel.run();
    check(randomStarted.isEmpty(), "random run starts", randomStarted.toStdString());
    const auto [randomPath, randomMessage] = randomStarted.isEmpty() ? waitForFinish(panel, 180000) : std::make_pair(QString(), randomStarted);
    check(!randomPath.isEmpty(), "random run finishes with a result file (" + randomMessage.toStdString() + ")");
    if (!randomPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(randomPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a random result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(randomPath), "the random result opens");
            window->close();
        }
    }

    // --- Shock: a 20 g × 11 ms half-sine through the panel; the run opens in the strength window.
    panel.setAnalysis(fea::StructuralAnalysis::Shock);
    panel.setShock(0, 2, 0.0, 11.0, 0.0, 0.0, 0.02, 6);
    check(reason().find("Импульс") != std::string::npos, "shock: no peak, refused", reason());
    panel.setShock(2, 2, 20.0, 11.0, 6.0, 6.0, 0.02, 6);
    check(reason().find("Трапеция") != std::string::npos, "shock: an overlapping trapezoid is refused", reason());
    panel.setShock(0, 2, 20.0, 11.0, 0.0, 0.0, 0.02, 6);
    const auto shockJob = panel.buildJob();
    check(shockJob.isOk() && shockJob.value().analysis == fea::StructuralAnalysis::Shock
              && std::fabs(shockJob.value().shock.pulse.peakMs2 - 20.0 * 9.80665) < 1e-12 && std::fabs(shockJob.value().shock.pulse.durationS - 0.011) < 1e-15,
          "shock job: 20 g as m/s², 11 ms as seconds", reason());
    if (shockJob.isOk()) check(fea::parseStructuralJob(fea::structuralJobJson(shockJob.value()), "/tmp").isOk(), "shock job the panel writes is one the tool accepts");
    const QString shockStarted = panel.run();
    check(shockStarted.isEmpty(), "shock run starts", shockStarted.toStdString());
    const auto [shockPath, shockMessage] = shockStarted.isEmpty() ? waitForFinish(panel, 180000) : std::make_pair(QString(), shockStarted);
    check(!shockPath.isEmpty(), "shock run finishes with a result file (" + shockMessage.toStdString() + ")");
    if (!shockPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(shockPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a shock result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(shockPath), "the shock result opens");
            window->close();
        }
    }

    // --- Climate: MIL-STD-810H A1 with sun on the aluminium bar, a 2 W unit on its tip, clamped at the root.
    panel.setAnalysis(fea::StructuralAnalysis::Climate);
    panel.setMaterialId("al_6061_t6");
    panel.setMeshSettings(0.04, 1.5);
    panel.setClimate(0, false, 0.0, 0.0, 4, 0, 0.6, 0.8, 20.0, 300.0, true);
    check(reason().find("скорость воздуха") != std::string::npos, "climate: no air speed, refused (it has no default)", reason());
    panel.setClimate(0, false, 1.5, 0.0, 4, 0, 0.0, 0.8, 20.0, 300.0, true);
    check(reason().find("поглощательная") != std::string::npos, "climate: sun without α, refused", reason());
    panel.setClimate(0, false, 1.5, 0.0, 4, 0, 0.6, 0.8, 20.0, 300.0, true);
    selection = std::make_pair("bar", tip);
    check(panel.addClimateComponentOnSelectedFace(QStringLiteral("датчик"), 2.0, -40.0, 85.0).isEmpty(), "climate: a unit on the tip face");
    panel.setClimateMaterialLimits(NAN, 150.0);
    const auto climateJob = panel.buildJob();
    check(climateJob.isOk(), "climate: the panel builds a job", reason());
    if (climateJob.isOk()) {
        const auto& c = climateJob.value().climate;
        const std::string tipIndex = tip.substr(0, tip.find('-', 5));
        check(c.environment == fea::ClimateEnvironment::Hot && c.hotCategory == fea::HotCategory::A1HotDry && c.hotExposure == fea::HotExposure::Sun
                  && c.components.size() == 1 && c.components[0].face == tipIndex && c.components[0].powerW == 2.0
                  && c.components[0].maximumK && std::fabs(*c.components[0].maximumK - 358.15) < 1e-9 && c.materialMaximumK
                  && std::fabs(*c.materialMaximumK - 423.15) < 1e-9 && !c.materialMinimumK && std::fabs(c.stressFreeK - 293.15) < 1e-9
                  && climateJob.value().loadCase.supports.size() == 1 && climateJob.value().loadCase.forces.empty(),
              "climate job: A1 sun, the unit on the tip in kelvin, the material limit, the root clamp, no static force");
        check(fea::parseStructuralJob(fea::structuralJobJson(climateJob.value()), "/tmp").isOk(), "climate job the panel writes is one the tool accepts");
    }
    const QString climateStarted = panel.run();
    check(climateStarted.isEmpty(), "climate run starts", climateStarted.toStdString());
    const auto [climatePath, climateMessage] = climateStarted.isEmpty() ? waitForFinish(panel, 600000) : std::make_pair(QString(), climateStarted);
    check(!climatePath.isEmpty(), "climate run finishes with a result file (" + climateMessage.toStdString() + ")");
    if (!climatePath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(climatePath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a climate result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(climatePath), "the climate result opens (temperature field, day plot)");
            if (argc >= 6) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[5]));
            }
            window->close();
        }
    }

    // --- Fire: the ISO 2685 flame on the tip face of the bar for 5 minutes.
    panel.setAnalysis(fea::StructuralAnalysis::Fire);
    panel.setFire(0, fea::kFireResistantS, 1, 0.7, 5.0, true);
    check(reason().find("пламенем") != std::string::npos, "fire: no flame face, refused", reason());
    const std::string flank = faceWhere(faces, [](const auto& f) { return std::fabs(f.normal.y) > 0.99 && f.origin.y < 1e-9; });
    selection = std::make_pair("bar", flank);
    check(panel.addFlameFaceFromSelection().isEmpty(), "fire: a side face goes under the flame");
    check(panel.addFlameFaceFromSelection().contains(QStringLiteral("уже")), "fire: the same face twice is refused");
    const auto fireJob = panel.buildJob();
    check(fireJob.isOk(), "fire: the panel builds a job", reason());
    if (fireJob.isOk()) {
        const auto& f = fireJob.value().fire;
        const std::string flankIndex = flank.substr(0, flank.find('-', 5));
        check(f.standard == fea::FireStandard::Iso2685 && f.durationS == fea::kFireResistantS && f.flameFaces.size() == 1 && f.flameFaces[0] == flankIndex
                  && f.surfaceEmissivity == 0.7 && f.stepS == 5.0 && fireJob.value().loadCase.supports.size() == 1,
              "fire job: ISO 2685, 5 minutes, the side face, ε = 0.7, the root clamp");
        check(fea::parseStructuralJob(fea::structuralJobJson(fireJob.value()), "/tmp").isOk(), "fire job the panel writes is one the tool accepts");
    }
    const QString fireStarted = panel.run();
    check(fireStarted.isEmpty(), "fire run starts", fireStarted.toStdString());
    const auto [firePath, fireMessage] = fireStarted.isEmpty() ? waitForFinish(panel, 900000) : std::make_pair(QString(), fireStarted);
    check(!firePath.isEmpty(), "fire run finishes with a result file (" + fireMessage.toStdString() + ")");
    if (!firePath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(firePath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a fire result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(firePath), "the fire result opens (temperature field, history)");
            if (argc >= 7) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[6]));
            }
            window->close();
        }
    }

    // --- Lightning: components B and C on the tip of the bar, the current leaving through the root.
    panel.setAnalysis(fea::StructuralAnalysis::Lightning);
    panel.setLightning({}, 0, 400.0, 0, 0.0, 200);
    check(reason().find("составляющая") != std::string::npos, "lightning: no component chosen, refused", reason());
    panel.setLightning({fea::LightningComponent::B, fea::LightningComponent::C}, 0, 400.0, 0, 0.0, 200);
    check(reason().find("привязки дуги") != std::string::npos, "lightning: no attachment face, refused", reason());
    selection = std::make_pair("bar", tip);
    check(panel.addAttachmentFaceFromSelection().isEmpty(), "lightning: the tip face takes the arc");
    check(panel.addAttachmentFaceFromSelection().contains(QStringLiteral("уже")), "lightning: the same face twice is refused");
    check(panel.addGroundFaceFromSelection().contains(QStringLiteral("другой ролью")), "lightning: the arc's face cannot also carry the current away");
    check(reason().find("отвода тока") != std::string::npos, "lightning: no ground face, refused", reason());
    selection = std::make_pair("bar", root);
    check(panel.addGroundFaceFromSelection().isEmpty(), "lightning: the root face carries the current away");
    panel.setLightning({fea::LightningComponent::B, fea::LightningComponent::C}, 0, 1200.0, 0, 0.0, 200);
    check(reason().find("200–800") != std::string::npos, "lightning: a component C current outside the standard, refused", reason());
    panel.setLightning({fea::LightningComponent::B, fea::LightningComponent::C}, 0, 400.0, 0, 0.0, 200);
    panel.setMaterialId("steel_4130");
    check(reason().find("сопротивление") != std::string::npos, "lightning: a material without resistivity, refused", reason());
    panel.setMaterialId("al_6061_t6");
    panel.setLoadCaseName(QStringLiteral("Консоль, удар молнии в конец"));
    const auto lightningJob = panel.buildJob();
    check(lightningJob.isOk(), "lightning: the panel builds a job", reason());
    if (lightningJob.isOk()) {
        const auto& l = lightningJob.value().lightning;
        const std::string tipIndex = tip.substr(0, tip.find('-', 5)), rootIndex = root.substr(0, root.find('-', 5));
        check(l.components.size() == 2 && l.components[0] == fea::LightningComponent::B && l.components[1] == fea::LightningComponent::C
                  && l.attachmentFaces.size() == 1 && l.attachmentFaces[0] == tipIndex && l.groundFaces.size() == 1 && l.groundFaces[0] == rootIndex
                  && l.polarity == fea::ArcPolarity::Anode && l.continuingCurrentA == 400.0 && l.surfaceEmissivity == 0.3 && l.stepsPerComponent == 200
                  && lightningJob.value().loadCase.supports.size() == 1 && lightningJob.value().loadCase.forces.empty(),
              "lightning job: B then C, the arc on the tip, the current out through the root, ε = 0.3, no static load");
        check(fea::parseStructuralJob(fea::structuralJobJson(lightningJob.value()), "/tmp").isOk(), "lightning job the panel writes is one the tool accepts");
    }
    const QString lightningStarted = panel.run();
    check(lightningStarted.isEmpty(), "lightning run starts", lightningStarted.toStdString());
    const auto [lightningPath, lightningMessage] = lightningStarted.isEmpty() ? waitForFinish(panel, 900000) : std::make_pair(QString(), lightningStarted);
    check(!lightningPath.isEmpty(), "lightning run finishes with a result file (" + lightningMessage.toStdString() + ")");
    if (!lightningPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(lightningPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a lightning result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(lightningPath), "the lightning result opens (temperature field, current history)");
            if (argc >= 8) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[7]));
            }
            window->close();
        }
    }

    // --- EMC: the standard's field on the bar, with a probe beside it (the bar is solid, so there is
    // no cavity to sit in; what this exercises is the panel, the job, the process and the window).
    panel.setAnalysis(fea::StructuralAnalysis::Emc);
    panel.setEmc(0, 2, 2, 0.0, 200.0, 800.0, 5);
    check(reason().find("оборудования") != std::string::npos, "emc: no equipment inside, refused", reason());
    selection = std::make_pair("bar", tip);
    check(panel.addEmcEquipmentOnSelectedFace(QStringLiteral("приёмник"), 100.0, 200.0).isEmpty(), "emc: a point one step off the tip face");
    panel.setEmc(0, 0, 2, 0.0, 200.0, 800.0, 5);
    check(reason().find("поперечной") != std::string::npos, "emc: polarisation along the direction of travel, refused", reason());
    panel.setEmc(0, 2, 2, 0.0, 200.0, 40000.0, 5);
    check(reason().find("за диапазон") != std::string::npos, "emc: a sweep outside the standard's level, refused", reason());
    panel.setEmc(0, 2, 2, 0.0, 200.0, 800.0, 5);
    panel.setMeshSettings(0.02, 1.3);
    panel.setMaterialId("al_6061_t6");
    panel.setLoadCaseName(QStringLiteral("Консоль, RS103 по +x"));
    const auto emcJob = panel.buildJob();
    check(emcJob.isOk(), "emc: the panel builds a job", reason());
    if (emcJob.isOk()) {
        const auto& e = emcJob.value().emc;
        check(e.incidence == em::Axis::X && e.forward && e.polarization == em::Axis::Z && e.levelId == "mil461g-rs103-200" && e.lowHz == 2e8
                  && e.highHz == 8e8 && e.points == 5 && e.equipment.size() == 1 && e.equipment[0].immunityVm == 200.0
                  && std::fabs(e.equipment[0].x - (L + 0.1)) < 1e-6 && emcJob.value().loadCase.forces.empty(),
              "emc job: the wave along +x polarised along z, 200 V/m, the probe 100 mm past the tip, no static load");
        check(fea::parseStructuralJob(fea::structuralJobJson(emcJob.value()), "/tmp").isOk(), "emc job the panel writes is one the tool accepts");
    }
    const QString emcStarted = panel.run();
    check(emcStarted.isEmpty(), "emc run starts", emcStarted.toStdString());
    const auto [emcPath, emcMessage] = emcStarted.isEmpty() ? waitForFinish(panel, 900000) : std::make_pair(QString(), emcStarted);
    check(!emcPath.isEmpty(), "emc run finishes with a result file (" + emcMessage.toStdString() + ")");
    if (!emcPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(emcPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "an emc result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(emcPath), "the emc result opens (field on the surface, shielding over the sweep)");
            if (argc >= 9) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[8]));
            }
            window->close();
        }
    }

    // --- Icing: the bar as a (very blunt) wing in the regulation's takeoff maximum icing.
    panel.setAnalysis(fea::StructuralAnalysis::Icing);
    panel.setIcing(0, 0, 0.0, 0, -9.0, 0.35, 20.0, 60.0, 10.0, 0.0, 0.0, 5.0);
    check(reason().find("различаться") != std::string::npos, "icing: flow and span along the same axis, refused", reason());
    panel.setIcing(0, 1, 0.0, 0, -9.0, 0.35, 20.0, 60.0, 0.0, 0.0, 0.0, 5.0);
    check(reason().find("длительность") != std::string::npos, "icing: no time in the cloud, refused", reason());
    panel.setIcing(0, 1, 2.0, 1, 1.0, 0.35, 20.0, 60.0, 10.0, 0.0, 0.0, 5.0);
    check(reason().find("не ниже нуля") != std::string::npos, "icing: air above freezing, refused", reason());
    panel.setIcing(0, 1, 2.0, 0, -9.0, 0.35, 20.0, 60.0, 10.0, 0.0, 0.0, 5.0);
    panel.setMeshSettings(0.02, 1.3);
    panel.setMaterialId("al_6061_t6");
    panel.setLoadCaseName(QStringLiteral("Консоль, взлётное обледенение"));
    const auto icingJob = panel.buildJob();
    check(icingJob.isOk(), "icing: the panel builds a job", reason());
    if (icingJob.isOk()) {
        const auto& i = icingJob.value().icing;
        check(i.flowAxis == 0 && i.spanAxis == 1 && i.conditionId == "takeoffMaximum" && std::fabs(i.condition.lwcKgM3 - 0.35e-3) <= 1e-12
                  && std::fabs(i.condition.dropletDiameterM - 20e-6) <= 1e-15 && std::fabs(i.condition.durationS - 600.0) <= 1e-9
                  && std::fabs(i.maximumIceThicknessM - 0.005) <= 1e-12 && icingJob.value().loadCase.forces.empty(),
              "icing job: the regulation's takeoff condition, the wing's axes, a 5 mm limit, no static load");
        check(fea::parseStructuralJob(fea::structuralJobJson(icingJob.value()), "/tmp").isOk(), "icing job the panel writes is one the tool accepts");
    }
    const QString icingStarted = panel.run();
    check(icingStarted.isEmpty(), "icing run starts", icingStarted.toStdString());
    const auto [icingPath, icingMessage] = icingStarted.isEmpty() ? waitForFinish(panel, 900000) : std::make_pair(QString(), icingStarted);
    check(!icingPath.isEmpty(), "icing run finishes with a result file (" + icingMessage.toStdString() + ")");
    if (!icingPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(icingPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "an icing result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(icingPath), "the icing result opens (ice on the surface, catch along the section)");
            if (argc >= 10) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[9]));
            }
            window->close();
        }
    }

    // --- Flutter needs a lifting surface, and the square bar is not one: its first two modes are
    // both bending, in y and in z, and the study refuses it in as many words. So the flutter case
    // gets its own part and its own panel — a plate 0.5 m by 0.25 m by 6 mm.
    kernel::OcctKernel plateKernel;
    const double plateChord = 0.25, plateSpan = 0.5, plateThickness = 0.006;
    const auto plateShape = plateKernel.makeExtrudedPolygon(
        {{{0.0, 0.0, 0.0}, {plateChord, 0.0, 0.0}, {plateChord, plateSpan, 0.0}, {0.0, plateSpan, 0.0}}, {0.0, 0.0, plateThickness}});
    check(plateShape.isOk(), "the plate for the flutter case is built", plateShape.isOk() ? "" : plateShape.error().message);
    std::vector<kernel::FaceReference> plateFaces =
        plateShape.isOk() ? kernel::FaceAnalyzer(plateKernel).planarFacesForBody("plate", plateShape.value()) : std::vector<kernel::FaceReference>{};
    const std::string plateRoot = faceWhere(plateFaces, [](const auto& f) { return std::fabs(f.origin.y) < 1e-9 && std::fabs(f.normal.y) > 0.99; });
    std::optional<std::pair<std::string, std::string>> plateSelection;
    gui::StructuralPartContext plateContext;
    plateContext.selectedFace = [&]() { return plateSelection; };
    plateContext.bodyFaces = [&](const std::string& bodyId) {
        return bodyId == "plate" ? plateFaces : std::vector<kernel::FaceReference>{};
    };
    plateContext.bodyName = [](const std::string&) { return QStringLiteral("Пластина"); };
    plateContext.bodyMaterialId = [](const std::string&) { return std::optional<std::string>(); };
    plateContext.exportBody = [&](const std::string&) { return plateKernel.exportBRep(plateShape.value()); };
    plateContext.selectFace = [&](const std::string& bodyId, const std::string& faceId) { plateSelection = std::make_pair(bodyId, faceId); };
    Panel platePanel(plateContext);
    auto plateReason = [&]() {
        const auto job = platePanel.buildJob();
        return job.isOk() ? std::string() : job.error().message;
    };
    plateSelection = std::make_pair("plate", plateRoot);
    platePanel.selectionChanged();
    check(platePanel.addItemOnSelectedFace({Panel::ItemKind::Support, {}, {true, true, true}}).isEmpty(), "the plate is clamped at its root");
    auto& panelForFlutter = platePanel;
    auto& reasonForFlutter = plateReason;
    panelForFlutter.setAnalysis(fea::StructuralAnalysis::Flutter);
    panelForFlutter.setMaterialId("al_6061_t6");
    panelForFlutter.setMeshSettings(0.042, 1.4);
    panelForFlutter.setFlutter(0, 0, 8, 1.225, 0.0, 0.0, 10.0, 400.0);
    check(reasonForFlutter().find("различаться") != std::string::npos, "flutter: flow and span along the same axis, refused", reasonForFlutter());
    panelForFlutter.setFlutter(0, 1, 8, 0.0, 0.0, 0.0, 10.0, 400.0);
    check(reasonForFlutter().find("плотность") != std::string::npos, "flutter: no air, refused", reasonForFlutter());
    panelForFlutter.setFlutter(0, 1, 8, 1.225, 0.0, 120.0, 10.0, 400.0);
    panelForFlutter.setLoadCaseName(QStringLiteral("Консоль, флаттер"));
    const auto flutterJob = panelForFlutter.buildJob();
    check(flutterJob.isOk(), "flutter: the panel builds a job", reasonForFlutter());
    if (flutterJob.isOk()) {
        const auto& f = flutterJob.value().flutter;
        check(f.flowAxis == 0 && f.spanAxis == 1 && f.stations == 8 && std::fabs(f.airDensityKgM3 - 1.225) <= 1e-12
                  && std::fabs(f.diveSpeedMps - 120.0) <= 1e-9 && std::fabs(f.marginFactor - 1.15) <= 1e-12
                  && flutterJob.value().loadCase.supports.size() == 1 && flutterJob.value().loadCase.forces.empty(),
              "flutter job: the wing's axes, eight strips, the dive speed, the regulation's margin, the root clamp, no static load");
        check(fea::parseStructuralJob(fea::structuralJobJson(flutterJob.value()), "/tmp").isOk(), "flutter job the panel writes is one the tool accepts");
    }
    const QString flutterStarted = panelForFlutter.run();
    check(flutterStarted.isEmpty(), "flutter run starts", flutterStarted.toStdString());
    const auto [flutterPath, flutterMessage] = flutterStarted.isEmpty() ? waitForFinish(panelForFlutter, 900000) : std::make_pair(QString(), flutterStarted);
    check(!flutterPath.isEmpty(), "flutter run finishes with a result file (" + flutterMessage.toStdString() + ")");
    if (!flutterPath.isEmpty()) {
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(flutterPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a flutter result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(flutterPath), "the flutter result opens (the torsion mode, the damping over speed)");
            if (argc >= 11) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[10]));
            }
            window->close();
        }
    }

    // --- A bird into the same plate: the top face is far larger than the bird, which is exactly the
    // case the study must refuse to call PASS, and the panel is driven the way a user would.
    auto& panelForBird = platePanel;
    const std::string plateTop = faceWhere(plateFaces, [&](const auto& f) { return std::fabs(f.origin.z - plateThickness) < 1e-9 && f.normal.z > 0.99; });
    panelForBird.setAnalysis(fea::StructuralAnalysis::Bird);
    panelForBird.setBird(5, 1.81, 0.0, 90.0, 0.02, 12);
    check(plateReason().find("грань удара") != std::string::npos, "bird: no struck face, refused", plateReason());
    plateSelection = std::make_pair("plate", plateTop);
    panelForBird.selectionChanged();
    check(panelForBird.setBirdFaceFromSelection().isEmpty(), "bird: the struck face is taken from the selection");
    check(plateReason().find("скорость") != std::string::npos, "bird: no speed, refused", plateReason());
    panelForBird.setBird(5, 1.81, 80.0, 90.0, 0.02, 12);
    panelForBird.setLoadCaseName(QStringLiteral("Обшивка, птица 1.81 кг"));
    const auto birdJob = panelForBird.buildJob();
    check(birdJob.isOk(), "bird: the panel builds a job", plateReason());
    if (birdJob.isOk()) {
        const auto& b = birdJob.value().bird;
        check(std::fabs(b.bird.massKg - 1.81) <= 1e-12 && std::fabs(b.bird.speedMps - 80.0) <= 1e-12
                  && std::fabs(b.bird.obliquityRad - M_PI_2) <= 1e-12 && b.modeCount == 12 && std::fabs(b.dampingRatio - 0.02) <= 1e-12
                  && std::fabs(b.direction[2] + 1.0) <= 1e-12 && !b.impactFace.empty() && birdJob.value().loadCase.supports.size() == 1
                  && birdJob.value().loadCase.forces.empty(),
              "bird job: the regulation's bird, the struck face, the direction into the part, the root clamp, no static load");
        check(fea::parseStructuralJob(fea::structuralJobJson(birdJob.value()), "/tmp").isOk(), "bird job the panel writes is one the tool accepts");
    }
    const QString birdStarted = panelForBird.run();
    check(birdStarted.isEmpty(), "bird run starts", birdStarted.toStdString());
    const auto [birdPath, birdMessage] = birdStarted.isEmpty() ? waitForFinish(panelForBird, 900000) : std::make_pair(QString(), birdStarted);
    check(!birdPath.isEmpty(), "bird run finishes with a result file (" + birdMessage.toStdString() + ")");
    if (!birdPath.isEmpty()) {
        QFile file(birdPath);
        QString text;
        if (file.open(QIODevice::ReadOnly)) text = QString::fromUtf8(file.readAll());
        check(text.contains(QStringLiteral("больше миделя птицы")) && !text.contains(QStringLiteral("\"outcome\": \"pass\"")),
              "bird: a face far larger than the bird is named, and the verdict is not PASS");
        QString error;
        gui::AnalysisResultWindow* window = gui::AnalysisResultWindow::forResultFile(birdPath, &error);
        check(dynamic_cast<gui::StructuralResultWindow*>(window) != nullptr, "a bird result gets the strength window", error.toStdString());
        if (window != nullptr) {
            check(window->openResult(birdPath), "the bird result opens (the load, the histories, the field at the worst instant)");
            if (argc >= 12) {
                window->show();
                QEventLoop settle;
                QTimer::singleShot(800, &settle, &QEventLoop::quit);
                settle.exec();
                window->snapshot().save(QString::fromLocal8Bit(argv[11]));
            }
            window->close();
        }
    }

    return fea_test::finish("test_gui_structural_study_panel");
}
