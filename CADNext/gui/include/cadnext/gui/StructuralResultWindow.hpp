#pragma once

#include "cadnext/gui/AnalysisResultWindow.hpp"

#include <memory>

class QComboBox;
class QLabel;
class QPushButton;
class QSlider;
class QSplitter;
class QTreeWidget;
class QCheckBox;
class SoQtExaminerViewer;
class SoSeparator;

namespace cadnext::viewer {
class StructuralFieldScene;
}

namespace cadnext::gui {

class StructuralLegend;
class ResponsePlot;

// Structural result of one part and load case, where the part is designed: the verdict with
// its reasons, the numbers with their mesh uncertainty, and the part coloured by utilisation on
// its deformed shape. Opened from Анализ → «Открыть результат прочности…» on a
// cadnext-structural-result file; the field file next to it supplies the geometry.
//
// Colours, the allowable and the deformation magnification come from the field file
// (StructuralPresentation), so the native window is a reproducible view of solver artifacts.
//
// A cadnext-harmonic-result (sine vibration) opens here too: the same verdict and field — the
// utilisation of the stress amplitude at the worst frequency — plus the response over the sweep
// under the part, with the natural frequencies and the allowable drawn on it. So do random, shock,
// climatic, fire and lightning results; a climatic one colours the part by its temperature at the
// hottest instant and plots the last day (air, sun, the part, each piece of equipment against its
// limit), a lightning one colours it at the moment of the burn-through and plots the strike's
// current and the metal's temperature against it, and a radiated-susceptibility one colours it by
// the field on its surface and plots the shielding across the sweep; an icing one colours it by the
// ice and plots the catch and the ice along each section.
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

    bool harmonic_ = false;
    bool random_ = false;
    bool shock_ = false;
    bool climate_ = false;
    bool fire_ = false;
    bool lightning_ = false;
    bool emc_ = false;
    bool icing_ = false;
    bool flutter_ = false;
    bool bird_ = false;
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
    QTreeWidget* details_=nullptr;
    QCheckBox *meshVisible_=nullptr,*criticalVisible_=nullptr;
    ResponsePlot* response_ = nullptr;
    QComboBox* responseQuantity_ = nullptr;
    QWidget* responseBox_ = nullptr;
    QSplitter* viewSplitter_ = nullptr;
};

} // namespace cadnext::gui
