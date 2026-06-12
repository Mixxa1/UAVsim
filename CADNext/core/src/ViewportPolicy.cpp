#include "cadnext/ViewportPolicy.hpp"

namespace cadnext {

void ViewportPolicy::enterSketch2D(const SketchReference& reference) {
    mode_ = ViewportViewMode::Sketch2D;
    activeReference_ = reference;
}

void ViewportPolicy::exitSketch2D() {
    mode_ = ViewportViewMode::Free3D;
    activeReference_.reset();
}

void ViewportPolicy::setSelectedWorkPlane(const std::string& planeId) {
    selectedWorkPlaneId_ = planeId;
}

void ViewportPolicy::setOtherWorkPlanesHidden(bool hidden) {
    otherWorkPlanesHidden_ = hidden;
}

bool ViewportPolicy::workPlaneVisible(const std::string& planeId) const {
    if (mode_ == ViewportViewMode::Sketch2D) {
        return false;
    }
    if (!otherWorkPlanesHidden_) {
        return true;
    }
    return !selectedWorkPlaneId_.empty() && planeId == selectedWorkPlaneId_;
}

bool ViewportPolicy::worldGridVisible() const {
    return mode_ == ViewportViewMode::Free3D;
}

bool ViewportPolicy::worldAxesVisible() const {
    return mode_ == ViewportViewMode::Free3D;
}

bool ViewportPolicy::orbitEnabled() const {
    return mode_ == ViewportViewMode::Free3D;
}

ViewportFitTarget ViewportPolicy::fitTarget(bool hasBodies) const {
    if (mode_ == ViewportViewMode::Sketch2D) {
        return ViewportFitTarget::ActiveSketchPlane;
    }
    if (hasBodies) {
        return ViewportFitTarget::Bodies;
    }
    if (!selectedWorkPlaneId_.empty()) {
        return ViewportFitTarget::SelectedPlane;
    }
    return ViewportFitTarget::WholeScene;
}

} // namespace cadnext
