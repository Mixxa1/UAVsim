#include "cadnext/viewer/SelectionController.hpp"

#include "cadnext/viewer/SceneGraph.hpp"

namespace cadnext::viewer {

SelectionController::SelectionController(SceneGraph& scene)
    : scene_(scene) {}

void SelectionController::selectObject(const std::string& objectId) {
    if (selectedObjectId_ == objectId) {
        return;
    }
    if (!selectedObjectId_.empty()) {
        scene_.setHighlighted(selectedObjectId_, false);
    }
    selectedObjectId_ = objectId;
    if (!selectedObjectId_.empty()) {
        scene_.setHighlighted(selectedObjectId_, true);
    }
}

void SelectionController::clearSelection() {
    if (!selectedObjectId_.empty()) {
        scene_.setHighlighted(selectedObjectId_, false);
    }
    selectedObjectId_.clear();
}

bool SelectionController::hasSelection() const {
    return !selectedObjectId_.empty();
}

const std::string& SelectionController::selectedObjectId() const {
    return selectedObjectId_;
}

} // namespace cadnext::viewer
