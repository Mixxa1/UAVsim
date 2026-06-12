#include "cadnext/ViewBoundsPolicy.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace cadnext {

namespace {

bool finiteVector(const Vector3& point) {
    return std::isfinite(point.x) && std::isfinite(point.y) && std::isfinite(point.z);
}

CameraFocusTarget targetFromBounds(const std::string& kind, const ViewBounds& bounds) {
    CameraFocusTarget target;
    if (!bounds.valid) {
        return target;
    }
    target.kind = kind;
    target.bounds = bounds;
    target.center = bounds.center();
    target.radius = std::max(bounds.radius(), 1.0e-6);
    target.valid = true;
    return target;
}

bool entryMatchesSelection(const ViewBoundsEntry& entry, const SelectionState& selection) {
    switch (selection.kind) {
    case SelectionKind::Body:
        return selection.bodyId && entry.kind == ViewGeometryKind::Body &&
               entry.bodyId == *selection.bodyId;
    case SelectionKind::BodyFace:
        return selection.bodyId && selection.faceId &&
               entry.kind == ViewGeometryKind::BodyFace &&
               entry.bodyId == *selection.bodyId && entry.faceId == *selection.faceId;
    case SelectionKind::Sketch:
        return selection.sketchId &&
               (entry.kind == ViewGeometryKind::Sketch ||
                entry.kind == ViewGeometryKind::CommittedSketch ||
                entry.kind == ViewGeometryKind::ActiveSketch ||
                entry.kind == ViewGeometryKind::SketchEntity ||
                entry.kind == ViewGeometryKind::SketchProfile) &&
               entry.sketchId == *selection.sketchId;
    case SelectionKind::SketchEntity:
        return selection.sketchId && selection.entityId &&
               entry.kind == ViewGeometryKind::SketchEntity &&
               entry.sketchId == *selection.sketchId && entry.entityId == *selection.entityId;
    case SelectionKind::SketchProfile:
        return selection.sketchId && selection.profileId &&
               entry.kind == ViewGeometryKind::SketchProfile &&
               entry.sketchId == *selection.sketchId && entry.profileId == *selection.profileId;
    case SelectionKind::WorkPlane:
    case SelectionKind::None:
        return false;
    }
    return false;
}

std::string selectionKindName(const SelectionState& selection) {
    switch (selection.kind) {
    case SelectionKind::Body: return "Body";
    case SelectionKind::BodyFace: return "Face";
    case SelectionKind::Sketch: return "Sketch";
    case SelectionKind::SketchEntity: return "SketchEntity";
    case SelectionKind::SketchProfile: return "SketchProfile";
    case SelectionKind::WorkPlane: return "WorkPlane";
    case SelectionKind::None: return "None";
    }
    return "None";
}

bool hasEntriesOfKind(const ViewBoundsScene& scene, ViewGeometryKind kind) {
    return std::any_of(scene.entries.begin(), scene.entries.end(),
                       [kind](const ViewBoundsEntry& entry) {
                           return entry.kind == kind && entry.bounds.valid;
                       });
}

} // namespace

void ViewBounds::include(const Vector3& point) {
    if (!finiteVector(point)) {
        return;
    }
    if (!valid) {
        min = point;
        max = point;
        valid = true;
        return;
    }
    min.x = std::min(min.x, point.x);
    min.y = std::min(min.y, point.y);
    min.z = std::min(min.z, point.z);
    max.x = std::max(max.x, point.x);
    max.y = std::max(max.y, point.y);
    max.z = std::max(max.z, point.z);
}

void ViewBounds::include(const ViewBounds& bounds) {
    if (!bounds.valid) {
        return;
    }
    include(bounds.min);
    include(bounds.max);
}

Vector3 ViewBounds::center() const {
    if (!valid) {
        return {};
    }
    return {(min.x + max.x) * 0.5, (min.y + max.y) * 0.5, (min.z + max.z) * 0.5};
}

double ViewBounds::radius() const {
    if (!valid) {
        return 0.0;
    }
    const double dx = max.x - min.x;
    const double dy = max.y - min.y;
    const double dz = max.z - min.z;
    return 0.5 * std::sqrt(dx * dx + dy * dy + dz * dz);
}

ViewBounds defaultGridViewBounds(double halfExtent) {
    const double extent = std::max(halfExtent, 0.5);
    ViewBounds bounds;
    bounds.include(Vector3{-extent, -extent, 0.0});
    bounds.include(Vector3{extent, extent, 0.0});
    return bounds;
}

bool viewGeometryContributesToFitAll(ViewGeometryKind kind) {
    switch (kind) {
    case ViewGeometryKind::Body:
    case ViewGeometryKind::Sketch:
    case ViewGeometryKind::ActiveSketch:
    case ViewGeometryKind::CommittedSketch:
        return true;
    case ViewGeometryKind::BodyFace:
    case ViewGeometryKind::SketchEntity:
    case ViewGeometryKind::SketchProfile:
    case ViewGeometryKind::HelperPlane:
    case ViewGeometryKind::WorldGrid:
    case ViewGeometryKind::WorldAxes:
    case ViewGeometryKind::TransientPreview:
    case ViewGeometryKind::DefaultGrid:
        return false;
    }
    return false;
}

bool viewGeometryIsHelper(ViewGeometryKind kind) {
    switch (kind) {
    case ViewGeometryKind::HelperPlane:
    case ViewGeometryKind::WorldGrid:
    case ViewGeometryKind::WorldAxes:
    case ViewGeometryKind::TransientPreview:
        return true;
    case ViewGeometryKind::Body:
    case ViewGeometryKind::BodyFace:
    case ViewGeometryKind::Sketch:
    case ViewGeometryKind::SketchEntity:
    case ViewGeometryKind::SketchProfile:
    case ViewGeometryKind::ActiveSketch:
    case ViewGeometryKind::CommittedSketch:
    case ViewGeometryKind::DefaultGrid:
        return false;
    }
    return false;
}

CameraFocusTarget cameraFocusTargetForSelection(const ViewBoundsScene& scene,
                                                const SelectionState& selection) {
    ViewBounds selectedBounds;
    for (const ViewBoundsEntry& entry : scene.entries) {
        if (entryMatchesSelection(entry, selection)) {
            selectedBounds.include(entry.bounds);
        }
    }
    if (selectedBounds.valid) {
        return targetFromBounds(selectionKindName(selection), selectedBounds);
    }
    return cameraFitAllTarget(scene, selection);
}

CameraFocusTarget cameraFitAllTarget(const ViewBoundsScene& scene,
                                     const SelectionState& selection) {
    ViewBounds bounds;
    for (const ViewBoundsEntry& entry : scene.entries) {
        if (viewGeometryContributesToFitAll(entry.kind)) {
            bounds.include(entry.bounds);
        }
    }
    if (bounds.valid) {
        return targetFromBounds("FitAll", bounds);
    }

    // If there are no bodies or committed sketches, a selected face/profile
    // is still real working geometry and is a better target than the grid.
    const bool hasBody = hasEntriesOfKind(scene, ViewGeometryKind::Body);
    if (!hasBody && selection.kind != SelectionKind::None) {
        ViewBounds selectedBounds;
        for (const ViewBoundsEntry& entry : scene.entries) {
            if (entryMatchesSelection(entry, selection)) {
                selectedBounds.include(entry.bounds);
            }
        }
        if (selectedBounds.valid) {
            return targetFromBounds(selectionKindName(selection), selectedBounds);
        }
    }

    const ViewBounds grid = scene.defaultGridBounds.valid
                                ? scene.defaultGridBounds
                                : defaultGridViewBounds();
    return targetFromBounds("DefaultGrid", grid);
}

const char* viewGeometryKindName(ViewGeometryKind kind) {
    switch (kind) {
    case ViewGeometryKind::Body: return "Body";
    case ViewGeometryKind::BodyFace: return "Face";
    case ViewGeometryKind::Sketch: return "Sketch";
    case ViewGeometryKind::SketchEntity: return "SketchEntity";
    case ViewGeometryKind::SketchProfile: return "SketchProfile";
    case ViewGeometryKind::ActiveSketch: return "ActiveSketch";
    case ViewGeometryKind::CommittedSketch: return "CommittedSketch";
    case ViewGeometryKind::HelperPlane: return "HelperPlane";
    case ViewGeometryKind::WorldGrid: return "WorldGrid";
    case ViewGeometryKind::WorldAxes: return "WorldAxes";
    case ViewGeometryKind::TransientPreview: return "TransientPreview";
    case ViewGeometryKind::DefaultGrid: return "DefaultGrid";
    }
    return "Unknown";
}

} // namespace cadnext
