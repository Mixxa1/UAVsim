#pragma once

#include "cadnext/bridge/ConstructionExport.hpp"
#include "cadnext/cfd/FlowSection.hpp"

#include <QElapsedTimer>
#include <QImage>
#include <QJsonObject>
#include <QString>
#include <QWidget>

#include <algorithm>
#include <array>
#include <memory>
#include <vector>

class QButtonGroup;
class QCheckBox;
class QLabel;
class QPushButton;
class QSlider;
class QStackedWidget;
class QTimer;
class SoQtExaminerViewer;
class SoQtPlaneViewer;
class SoSeparator;

// The result of one computed point, shown the way a flow simulation is read:
//
//   Обтекание 3D — the body, flow trajectories from a rake upstream coloured by speed, arrows running
//                  along them at the computed speed; rotate, zoom, standard views;
//   Давление     — the body coloured by the pressure coefficient;
//   Сечение      — the mid-span section: colour map of the speed relative to the free stream,
//                  streamlines and particles; the frames of a time-accurate run play here.
//
// Everything is drawn from the point's own files (mesh, volume and surface fields, section frames);
// nothing is decoration. One legend, always for what the current view colours.

namespace cadnext::gui::detail {

class FlowAnimation;
class FlowScene3D;
class ColourLegend;

class FlowResultView : public QWidget {
public:
    explicit FlowResultView(QWidget* parent = nullptr);
    ~FlowResultView() override;

    // Before any result: the body of the document, so the window is never empty.
    void showGeometry(const bridge::ConstructionDescriptor& construction);

    struct Point {
        QString directory;   // flow/point-<n>
        QString fieldSuffix; // "" or "_00012" while a time-accurate run is writing
        QJsonObject settings;
        double sectionPlane = 0.0;
        bool haveSectionPlane = false;
        bool playFrames = true; // false while the solver is still running
    };
    // False with a reason when the point's files are missing or not complete yet.
    bool showPoint(const Point& point, QString& problem);

    // The viewer area as displayed, for documentation and tests.
    QImage capture();
    // 0 isometric, 1 from behind, 2 side, 3 top, 4 front.
    void viewPreset(int preset);
    // 0 flow 3D, 1 pressure on the body, 2 section.
    void setModeIndex(int index) { setMode(static_cast<Mode>(std::clamp(index, 0, 2))); }
    QString describe() const;

private:
    enum class Mode { Flow, Pressure, Section };
    void setMode(Mode mode);
    void ensureSection();
    void applyToggles();
    void updateLegend();
    double playbackRate() const;

    // Controls.
    QButtonGroup* modes_ = nullptr;
    QCheckBox *lines_ = nullptr, *arrows_ = nullptr, *pressureOnBody_ = nullptr;
    QCheckBox *sectionMap_ = nullptr, *sectionLines_ = nullptr, *particles_ = nullptr, *frames_ = nullptr;
    QWidget *flowControls_ = nullptr, *sectionControls_ = nullptr, *cameraControls_ = nullptr;
    QSlider* speed_ = nullptr;
    QLabel *speedLabel_ = nullptr, *clock_ = nullptr, *status_ = nullptr;
    QStackedWidget* stack_ = nullptr;
    ColourLegend* legend_ = nullptr;
    QTimer* timer_ = nullptr;
    QElapsedTimer wall_;

    // 3D.
    SoQtExaminerViewer* viewer3d_ = nullptr;
    SoSeparator* root3d_ = nullptr;
    std::unique_ptr<FlowScene3D> scene_;
    // Section.
    SoQtPlaneViewer* viewer2d_ = nullptr;
    SoSeparator* root2d_ = nullptr;
    std::unique_ptr<FlowAnimation> section_;
    SoSeparator* sectionBody_ = nullptr;
    std::array<double, 4> sectionRegion_{};

    // Data of the point shown, kept for building the section on demand.
    Point point_;
    std::vector<cfd::FlowSection::Vector> normalisedVelocity_;
    std::array<double, 6> body_{}; // solver-frame bounds of the walls
    double freeStream_ = 1.0;
    double cpLow_ = -1.0, cpHigh_ = 1.0;
    int vortexCores_ = 0;
    Mode mode_ = Mode::Flow;
    bool haveField_ = false;
    QString shownDirectory_;
};

} // namespace cadnext::gui::detail
