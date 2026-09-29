#pragma once

#include "cadnext/Thread.hpp"
#include "cadnext/Vector3.hpp"

#include <QDialog>

#include <array>

class QComboBox;
class QDoubleSpinBox;
class QLabel;
class QPushButton;

namespace cadnext::gui {

// The face a thread is to be cut on, as the Thread tool sees it.
struct ThreadFace {
    ThreadSurface surface;                   // model units
    std::array<bool, 2> free{false, false};  // air past axialStart / axialEnd: a free end, not a shoulder
    std::array<Vector3, 2> ends;             // the ends' centres on the axis, model units
};

// The Thread tool's window: standard, size (suggested by the face), length, which end it starts from,
// the hand; a line saying what will happen to the face (turned, bored) or why it cannot be threaded.
class ThreadDialog : public QDialog {
public:
    ThreadDialog(const ThreadFace& face, QWidget* parent = nullptr);

    // Everything but the body, the face id and the surface, which the caller knows.
    ThreadParameters parameters() const;

private:
    bool taperFace() const;
    bool cone() const;
    void fillSizes();
    void refresh();
    // The face's diameter, mm, where the thread starts (taper internal: at the mouth).
    double faceDiameterMm() const;

    ThreadFace face_;
    QLabel* faceLabel_ = nullptr;
    QComboBox* standard_ = nullptr;
    QComboBox* size_ = nullptr;
    QLabel* sizeLabel_ = nullptr;
    QDoubleSpinBox* diameter_ = nullptr;
    QLabel* diameterLabel_ = nullptr;
    QDoubleSpinBox* pitch_ = nullptr;
    QLabel* pitchLabel_ = nullptr;
    QDoubleSpinBox* length_ = nullptr;
    QComboBox* start_ = nullptr;
    QLabel* startLabel_ = nullptr;
    QComboBox* hand_ = nullptr;
    QLabel* note_ = nullptr;
    QPushButton* build_ = nullptr;
};

} // namespace cadnext::gui
