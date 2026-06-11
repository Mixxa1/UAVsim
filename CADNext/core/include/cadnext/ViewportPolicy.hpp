#pragma once

#include <optional>
#include <string>

#include "cadnext/Sketch.hpp"

namespace cadnext {

// Viewer presentation mode. Free3D is the regular modeling view; Sketch2D
// is the flat orthographic normal-to-plane sketch editor.
enum class ViewportViewMode {
    Free3D,
    Sketch2D
};

// What Fit View should frame in the current mode/selection.
enum class ViewportFitTarget {
    Bodies,
    ActiveSketchPlane,
    SelectedPlane,
    WholeScene
};

// Pure helper-geometry presentation policy (no Coin3D/Qt dependencies so
// it is testable headless). It decides which work planes / world helpers
// are visible, whether orbit navigation is allowed and what Fit View
// frames; the viewer only applies this state to the scene graph.
//
// Rules:
//  - Free3D shows the world grid/axes and the canonical work plane frames;
//    "hide other planes" keeps only the selected plane visible.
//  - Sketch2D hides every work plane helper and the world grid/axes — the
//    active sketch plane is rendered by the dedicated sketch plane helper,
//    not by the Free3D plane frames — and disables orbit so the camera
//    stays normal to the plane.
class ViewportPolicy {
public:
    void enterSketch2D(const SketchReference& reference);
    void exitSketch2D();

    ViewportViewMode mode() const { return mode_; }
    bool inSketch2D() const { return mode_ == ViewportViewMode::Sketch2D; }
    const std::optional<SketchReference>& activeReference() const { return activeReference_; }

    void setSelectedWorkPlane(const std::string& planeId);
    const std::string& selectedWorkPlane() const { return selectedWorkPlaneId_; }

    // Free3D "Hide Other Planes": only the selected plane stays visible.
    // The flag is a user choice and survives entering/leaving Sketch2D.
    void setOtherWorkPlanesHidden(bool hidden);
    bool otherWorkPlanesHidden() const { return otherWorkPlanesHidden_; }

    bool workPlaneVisible(const std::string& planeId) const;
    bool worldGridVisible() const;
    bool worldAxesVisible() const;
    bool orbitEnabled() const;

    // Fit View priority: the active sketch plane in Sketch2D, otherwise
    // bodies; a selected plane only counts when there are no bodies.
    ViewportFitTarget fitTarget(bool hasBodies) const;

private:
    ViewportViewMode mode_ = ViewportViewMode::Free3D;
    std::optional<SketchReference> activeReference_;
    std::string selectedWorkPlaneId_;
    bool otherWorkPlanesHidden_ = false;
};

} // namespace cadnext
