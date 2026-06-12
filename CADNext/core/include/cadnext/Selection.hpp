#pragma once

#include <optional>
#include <string>

namespace cadnext {

// Shared selection vocabulary for CADNext interaction layers. GUI code can
// keep richer local state, but viewport/tree/property contracts should use
// these stable kinds when exposing what is currently selected.
enum class SelectionKind {
    None,
    Body,
    BodyFace,
    BodyEdge,
    WorkPlane,
    Sketch,
    SketchEntity,
    SketchProfile
};

struct BodyFaceSelection {
    std::string bodyId;
    std::string faceId;
};

struct BodyEdgeSelection {
    std::string bodyId;
    std::string edgeId;
};

struct SelectionState {
    SelectionKind kind = SelectionKind::None;
    std::optional<std::string> bodyId;
    std::optional<std::string> faceId;
    std::optional<std::string> edgeId;
    std::optional<std::string> sketchId;
    std::optional<std::string> entityId;
    std::optional<std::string> profileId;
};

} // namespace cadnext
