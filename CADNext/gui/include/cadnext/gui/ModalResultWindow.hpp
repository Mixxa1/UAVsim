#pragma once

#include "cadnext/gui/AnalysisResultWindow.hpp"

#include <QElapsedTimer>

#include <memory>

class QLabel;
class QPushButton;
class QSlider;
class QTableWidget;
class QTimer;
class SoQtExaminerViewer;
class SoSeparator;

namespace cadnext::viewer {
class ModalFieldScene;
}

namespace cadnext::gui {

class ModalLegend;
class ModalSpectrum;

// Natural modes of one part (a cadnext-modal-result file and its mode-shape field): the verdict
// with its reasons, the spectrum of modes with their mesh bands against the excitation bands, the
// mode table, and the selected mode animated on the part.
//
// What is drawn follows the same honesty rules as the HTML report (fea/report/modal-report.html):
// a frequency always with its band or "не оценена"; an overlap on the spectrum is exactly an
// overlap in the verdict; the shape amplitude is conventional and labelled so.
class ModalResultWindow : public AnalysisResultWindow {
    Q_OBJECT

public:
    explicit ModalResultWindow(QWidget* parent = nullptr);
    ~ModalResultWindow() override;

    bool openResult(const QString& resultPath) override;

    // Drawn at the largest displacement of the selected mode, whatever the animation phase, so
    // an image of the window shows the shape rather than a moment of it.
    QImage snapshot() override;

    void selectMode(int index);
    int selectedMode() const;
    void setPlaying(bool playing);
    bool isPlaying() const { return playing_; }

private:
    void buildInterface();
    void advanceAnimation();
    void saveReport();

    QString resultPath_;
    QByteArray resultJson_;
    QByteArray fieldJson_;
    std::unique_ptr<viewer::ModalFieldScene> scene_;
    SoSeparator* viewerRoot_ = nullptr;
    SoQtExaminerViewer* viewer_ = nullptr;

    QLabel* title_ = nullptr;
    QLabel* verdict_ = nullptr;
    QLabel* numbers_ = nullptr;
    QLabel* reasons_ = nullptr;
    QLabel* conditions_ = nullptr;
    QLabel* study_ = nullptr;
    QPushButton* play_ = nullptr;
    QSlider* amplitude_ = nullptr;
    QTableWidget* modes_ = nullptr;
    ModalLegend* legend_ = nullptr;
    ModalSpectrum* spectrum_ = nullptr;
    QTimer* timer_ = nullptr;
    QElapsedTimer clock_;
    double phase_ = 1.5707963267948966;
    bool playing_ = false;
};

} // namespace cadnext::gui
