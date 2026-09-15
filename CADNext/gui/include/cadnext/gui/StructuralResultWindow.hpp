#pragma once

#include "cadnext/gui/AnalysisResultWindow.hpp"

#include <memory>

class QComboBox;
class QLabel;
class QPushButton;
class QSlider;
class SoQtExaminerViewer;
class SoSeparator;

namespace cadnext::viewer {
class StructuralFieldScene;
}

namespace cadnext::gui {

class StructuralLegend;

// Structural result of one part and load case, where the part is designed: the verdict with
// its reasons, the numbers with their mesh uncertainty, and the part coloured by utilisation on
// its deformed shape. Opened from Анализ → «Открыть результат прочности…» on a
// cadnext-structural-result file; the field file next to it supplies the geometry.
//
// Colours, the allowable and the deformation magnification come from the field file
// (StructuralPresentation), the same values the HTML report and the Workbench draw from.
class StructuralResultWindow : public AnalysisResultWindow {
    Q_OBJECT

public:
    explicit StructuralResultWindow(QWidget* parent = nullptr);
    ~StructuralResultWindow() override;

    bool openResult(const QString& resultPath) override;
    QImage snapshot() override;

private:
    void buildInterface();
    void applyQuantity(int index);
    void applyDeformationSlider(int position);
    void updateScaleLabel();
    void saveReport();

    QString resultPath_;
    QByteArray resultJson_;
    QByteArray fieldJson_;
    std::unique_ptr<viewer::StructuralFieldScene> scene_;
    SoSeparator* viewerRoot_ = nullptr;
    SoQtExaminerViewer* viewer_ = nullptr;

    QLabel* title_ = nullptr;
    QLabel* verdict_ = nullptr;
    QLabel* numbers_ = nullptr;
    QLabel* reasons_ = nullptr;
    QLabel* study_ = nullptr;
    QComboBox* quantity_ = nullptr;
    QSlider* deformation_ = nullptr;
    QLabel* scaleLabel_ = nullptr;
    StructuralLegend* legend_ = nullptr;
};

} // namespace cadnext::gui
