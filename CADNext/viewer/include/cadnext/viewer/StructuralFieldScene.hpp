#pragma once

#include "cadnext/fea/StructuralFieldFile.hpp"

class SoCamera;
class SoCoordinate3;
class SoMaterial;
class SoSeparator;
class SoTranslation;

// Coin3D scene of a structural result's surface field: the part coloured by the chosen
// quantity on its deformed shape, with the critical point marked. No Qt — the CADNext result
// window shows it in an examiner viewer, and cadnext_structural_snapshot renders it offscreen,
// so what a test image shows is what the window shows.

namespace cadnext::viewer {

enum class FieldQuantity {
    Utilization,  // σ/σ_allowable, absolute, overflow colour above 1
    VonMises,     // auto-ranged over this field
    Displacement, // auto-ranged over this field
};

class StructuralFieldScene {
public:
    explicit StructuralFieldScene(fea::StructuralFieldFile field);
    ~StructuralFieldScene();

    StructuralFieldScene(const StructuralFieldScene&) = delete;
    StructuralFieldScene& operator=(const StructuralFieldScene&) = delete;

    SoSeparator* root() const { return root_; }
    const fea::StructuralFieldFile& field() const { return field_; }

    void setQuantity(FieldQuantity quantity);
    FieldQuantity quantity() const { return quantity_; }

    // Display magnification of the displacement; 1 is true scale.
    void setDeformationScale(double scale);
    double deformationScale() const { return deformationScale_; }

    // Places a perspective camera, keeping its orientation, so the whole deformed part fits a
    // viewport of the given width/height with `margin` around it. Uses the narrower of the two
    // view angles: Coin's viewAll fits the vertical angle and crops a part in a tall viewport.
    void frame(SoCamera& camera, double aspectRatio, double margin = 1.15) const;

private:
    void updateCoordinates();
    void updateColors();

    fea::StructuralFieldFile field_;
    FieldQuantity quantity_ = FieldQuantity::Utilization;
    double deformationScale_ = 1.0;
    int criticalNode_ = 0;
    SoSeparator* root_ = nullptr;
    SoCoordinate3* coordinates_ = nullptr;
    SoMaterial* material_ = nullptr;
    SoTranslation* markerPosition_ = nullptr;
};

// Axonometric view with +Z up (the CAD convention; Coin viewers default to looking down −Z with
// +Y up, which shows a beam along X as a flat strip with its deflection edge-on).
void applyAxonometricZUpOrientation(SoCamera& camera);

// Intensity of the camera-attached headlight every view of this scene should use. The scene
// carries its own fixed fill lights; together they stay near a total of one, so a face turned
// to the light is not clipped into a different hue and a face turned away is not black.
inline constexpr float kStructuralHeadlightIntensity = 0.6f;

} // namespace cadnext::viewer
