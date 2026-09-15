#pragma once

#include <QImage>
#include <QMainWindow>

// A window showing one solver result file written by cadnext_structural. Which window depends
// on the file's schema — static strength or natural modes — so every place that opens a result
// (Анализ menu, the «Прочность детали» dock, --open-structural-result) goes through
// showResult() and none of them has to know the formats.

namespace cadnext::gui {

class AnalysisResultWindow : public QMainWindow {
    Q_OBJECT

public:
    using QMainWindow::QMainWindow;

    // Returns false (with a message box) when the result or its field cannot be read.
    virtual bool openResult(const QString& resultPath) = 0;

    // The window as displayed, 3D viewport included (QWidget::grab() leaves OpenGL black).
    virtual QImage snapshot() = 0;

    // The window for this file's schema, not yet opened; nullptr with `error` when the file is
    // not a known result.
    static AnalysisResultWindow* forResultFile(const QString& resultPath, QString* error);

    // Creates, opens and shows the right window (deleted on close). nullptr, after a message
    // box on `messageParent`, when that fails.
    static AnalysisResultWindow* showResult(const QString& resultPath, QWidget* messageParent);
};

} // namespace cadnext::gui
