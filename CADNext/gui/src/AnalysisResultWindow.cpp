#include "cadnext/gui/AnalysisResultWindow.hpp"

#include "cadnext/fea/FeaJson.hpp"
#include "cadnext/gui/ModalResultWindow.hpp"
#include "cadnext/gui/StructuralResultWindow.hpp"

#include <QFile>
#include <QMessageBox>

namespace cadnext::gui {

AnalysisResultWindow* AnalysisResultWindow::forResultFile(const QString& resultPath, QString* error) {
    QFile file(resultPath);
    if (!file.open(QIODevice::ReadOnly)) {
        if (error) *error = QObject::tr("Не удалось открыть %1").arg(resultPath);
        return nullptr;
    }
    fea::json::JsonValue root;
    std::string parseError;
    if (!fea::json::parseJson(file.readAll().toStdString(), root, parseError)) {
        if (error) *error = QObject::tr("%1 — не JSON").arg(resultPath);
        return nullptr;
    }
    const std::string schema = root.stringOr("schema", "");
    if (schema == "cadnext-structural-result/1") return new StructuralResultWindow();
    if (schema == "cadnext-modal-result/1") return new ModalResultWindow();
    if (error) *error = QObject::tr("Неизвестный формат результата «%1»").arg(QString::fromStdString(schema));
    return nullptr;
}

AnalysisResultWindow* AnalysisResultWindow::showResult(const QString& resultPath, QWidget* messageParent) {
    QString error;
    AnalysisResultWindow* window = forResultFile(resultPath, &error);
    if (window == nullptr) {
        QMessageBox::warning(messageParent, QObject::tr("Результат расчёта"), error);
        return nullptr;
    }
    if (!window->openResult(resultPath)) {
        window->close(); // WA_DeleteOnClose
        return nullptr;
    }
    window->show();
    return window;
}

} // namespace cadnext::gui
