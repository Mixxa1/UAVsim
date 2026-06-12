#pragma once

#include <optional>
#include <string>
#include <vector>

#include "cadnext/Selection.hpp"
#include "cadnext/Vector3.hpp"

namespace cadnext {

struct CameraNavigationOptions {
    double minDistance = 0.02;
    double maxDistance = 10000.0;
    double zoomSpeed = 1.15;
    double fitPadding = 1.35;
};

enum class ViewGeometryKind {
    Body,
    BodyFace,
    Sketch,
    SketchEntity,
    SketchProfile,
    ActiveSketch,
    CommittedSketch,
    HelperPlane,
    WorldGrid,
    WorldAxes,
    TransientPreview,
    DefaultGrid
};

struct ViewBounds {
    Vector3 min;
    Vector3 max;
    bool valid = false;

    void include(const Vector3& point);
    void include(const ViewBounds& bounds);
    Vector3 center() const;
    double radius() const;
};

struct ViewBoundsEntry {
    ViewGeometryKind kind = ViewGeometryKind::Body;
    ViewBounds bounds;
    std::string bodyId;
    std::string faceId;
    std::string sketchId;
    std::string entityId;
    std::string profileId;
    std::string debugName;
};

struct ViewBoundsScene {
    std::vector<ViewBoundsEntry> entries;
    ViewBounds defaultGridBounds;
};

struct CameraFocusTarget {
    std::string kind = "None";
    ViewBounds bounds;
    Vector3 center;
    double radius = 0.0;
    bool valid = false;
};

ViewBounds defaultGridViewBounds(double halfExtent = 4.0);

bool viewGeometryContributesToFitAll(ViewGeometryKind kind);
bool viewGeometryIsHelper(ViewGeometryKind kind);

CameraFocusTarget cameraFocusTargetForSelection(const ViewBoundsScene& scene,
                                                const SelectionState& selection);
CameraFocusTarget cameraFitAllTarget(const ViewBoundsScene& scene,
                                      const SelectionState& selection = {});

const char* viewGeometryKindName(ViewGeometryKind kind);

} // namespace cadnext
