#pragma once

#include "cadnext/fea/StructuralFieldFile.hpp"

class SoCamera;
class SoCoordinate3;
class SoMaterial;
class SoSeparator;

// Coin3D scene of a modal result: the part displaced along one mode shape. The shape is
// dimensionless, so the displacement drawn is  amplitude · sin(phase) · shape  with the file's
// conventional amplitude — an animation of the form, never of a physical size. Colour is the
// relative amplitude of the shape, which does not change while it oscillates.
//
// No Qt: the CADNext modal result window animates it by setting the phase, and an offscreen
// snapshot draws the same scene at the phase of largest displacement.

namespace cadnext::viewer {

class ModalFieldScene {
public:
    explicit ModalFieldScene(fea::ModalFieldFile field);
    ~ModalFieldScene();

    ModalFieldScene(const ModalFieldScene&) = delete;
    ModalFieldScene& operator=(const ModalFieldScene&) = delete;

    SoSeparator* root() const { return root_; }
    const fea::ModalFieldFile& field() const { return field_; }

    void setMode(int index);
    int mode() const { return mode_; }

    // Multiplier of the file's display amplitude (1 = the conventional one).
    void setAmplitude(double multiplier);
    double amplitude() const { return amplitude_; }

    // Oscillation phase, radians; π/2 is the largest displacement.
    void setPhase(double phase);

    // Fits the part at its largest displacement, as StructuralFieldScene::frame does.
    void frame(SoCamera& camera, double aspectRatio, double margin = 1.15) const;

private:
    void updateCoordinates();
    void updateColors();

    fea::ModalFieldFile field_;
    int mode_ = 0;
    double amplitude_ = 1.0;
    double phase_ = 1.5707963267948966;
    SoSeparator* root_ = nullptr;
    SoCoordinate3* coordinates_ = nullptr;
    SoMaterial* material_ = nullptr;
};

} // namespace cadnext::viewer
