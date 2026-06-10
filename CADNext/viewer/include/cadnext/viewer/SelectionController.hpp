#pragma once

#include <string>

namespace cadnext::viewer {

class SceneGraph;

// Tracks the single selected object id and keeps the viewport highlight
// in sync. CADNext 0.2 selection is driven by the project tree; viewport
// picking is planned for CADNext 0.3/0.4.
class SelectionController {
public:
    explicit SelectionController(SceneGraph& scene);

    void selectObject(const std::string& objectId);
    void clearSelection();
    bool hasSelection() const;
    const std::string& selectedObjectId() const;

private:
    SceneGraph& scene_;
    std::string selectedObjectId_;
};

} // namespace cadnext::viewer
