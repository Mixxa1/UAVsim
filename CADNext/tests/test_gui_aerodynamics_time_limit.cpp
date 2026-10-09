// The CFD study dialog's per-point time limit, as a user meets it: the limit in the settings belongs
// to the model the dialog shows, follows the model from one default to the other, and a limit typed
// into the settings stays as typed. The rule itself is checked in test_cfd_study; this is the wiring.
//
//   cadnext_test_gui_aerodynamics_time_limit <frame.uavframe>

#include "cadnext/bridge/ConstructionExport.hpp"
#include "cadnext/gui/AerodynamicsStudyDialog.hpp"

#include <Inventor/Qt/SoQt.h>

#include <QApplication>
#include <QComboBox>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPlainTextEdit>

#include <cstdio>

namespace {

int failures = 0;

void check(bool passed, const char* name) {
    std::printf("  %s  %s\n", passed ? "PASS" : "FAIL", name);
    if (!passed) ++failures;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::printf("usage: %s <frame.uavframe>\n", argv[0]);
        return 64;
    }
    QApplication app(argc, argv);
    SoQt::init(static_cast<QWidget*>(nullptr));
    const auto construction = cadnext::bridge::ConstructionExport::loadFromFile(argv[1]);
    if (!construction.isOk()) {
        std::printf("cannot load %s\n", argv[1]);
        return 2;
    }
    cadnext::gui::showAerodynamicsStudy(construction.value(), nullptr);

    QComboBox* model = nullptr;
    QPlainTextEdit* settings = nullptr;
    for (auto* window : QApplication::topLevelWidgets()) {
        for (auto* box : window->findChildren<QComboBox*>())
            if (box->findData(QStringLiteral("urans_sst")) >= 0) model = box;
        for (auto* edit : window->findChildren<QPlainTextEdit*>())
            if (edit->toPlainText().contains(QStringLiteral("timeoutSeconds"))) settings = edit;
    }
    if (!model || !settings) {
        std::printf("the dialog has no model selector or no settings text\n");
        return 1;
    }
    const auto limit = [&] {
        const auto json = QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();
        return json["timeoutSeconds"].toDouble();
    };
    const auto select = [&](const char* id) { model->setCurrentIndex(model->findData(QString::fromLatin1(id))); };
    const auto expected = [&] { return model->currentData().toString() == QStringLiteral("urans_sst") ? 28800.0 : 3600.0; };

    check(model->currentData().toString() == QStringLiteral("urans_sst") && limit() == 28800.0,
          "the dialog is built on URANS with the URANS limit");
    // The quick preset the dialog opens with replaces URANS by steady SST on the first event pass.
    QApplication::processEvents();
    check(limit() == expected(), "after the opening preset the limit is still the shown model's");

    select("urans_sst");
    check(limit() == 28800.0, "choosing URANS gives a point eight hours");
    select("sst");
    check(limit() == 3600.0, "choosing steady SST returns the steady hour");
    select("laminar");
    check(limit() == 3600.0, "steady models share one limit");

    auto json = QJsonDocument::fromJson(settings->toPlainText().toUtf8()).object();
    json["timeoutSeconds"] = 7200;
    settings->setPlainText(QJsonDocument(json).toJson(QJsonDocument::Indented));
    select("urans_sst");
    check(limit() == 7200.0, "a limit typed into the settings survives the change to URANS");
    select("sst");
    check(limit() == 7200.0, "and the change back");

    std::printf(failures ? "test_gui_aerodynamics_time_limit: FAILED\n" : "test_gui_aerodynamics_time_limit: OK\n");
    return failures ? 1 : 0;
}
