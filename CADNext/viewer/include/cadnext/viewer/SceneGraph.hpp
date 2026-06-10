#pragma once

#include <string>
#include <unordered_map>

#include <utility>

#include "cadnext/Object.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

#include <Inventor/SbColor.h>

class SoBaseColor;
class SoMaterial;
class SoPath;
class SoSeparator;
class SoTransform;

namespace cadnext::viewer {

// What a viewport click resolved to: a body, a sketch entity, or nothing.
struct ViewportPickTarget {
    std::string objectId;
    std::string sketchId;
    std::string entityId;

    bool isBody() const { return !objectId.empty(); }
    bool isSketchEntity() const { return !entityId.empty(); }
    bool isEmpty() const { return objectId.empty() && entityId.empty(); }
};

// Owns the Coin3D scene graph for the CADNext prototype viewer:
// a world-space grid on the XY plane, colored X/Y/Z axes, and one
// SoSeparator per document object. Geometry is built from the
// PrimitiveParameters construction descriptor (procedural Coin3D
// primitives), not from a BRep kernel — that arrives in CADNext 0.4+.
class SceneGraph {
public:
    SceneGraph();
    ~SceneGraph();

    SceneGraph(const SceneGraph&) = delete;
    SceneGraph& operator=(const SceneGraph&) = delete;

    SoSeparator* root() const;
    SoSeparator* objectsRoot() const;

    void addObjectNode(const Object& object);
    void removeObjectNode(const std::string& objectId);
    void clearObjectNodes();
    bool hasObjectNode(const std::string& objectId) const;

    // Per-object updates: grid/axes and untouched objects are not rebuilt.
    void updateObjectTransform(const std::string& objectId, const Transform& transform);
    // Rebuilds only the shape children of the object node; the transform
    // and material (and therefore the selection highlight) are preserved.
    void updateObjectPrimitive(const Object& object);

    // Mesh-backed display path (OCCT BRep evaluation): replaces the shape
    // children with a triangle mesh node, creating the object node when it
    // does not exist yet. Transform/material/highlight behave exactly like
    // the procedural path.
    void addOrUpdateObjectMesh(const Object& object, const kernel::TriangleMesh& mesh);

    void setHighlighted(const std::string& objectId, bool highlighted);

    // --- Sketch display (CADNext 0.5) ------------------------------------
    // Entities are drawn as world-space polylines on the sketch's plane;
    // the active-sketch plane helper (translucent quad + U/V axes) is shown
    // only while a sketch is being edited.
    void showSketchPlane(SketchPlane plane);
    void hideSketchPlane();
    void addOrUpdateSketchNode(const Sketch& sketch);
    void removeSketchNode(const std::string& sketchId);
    void clearSketchNodes();
    void setSketchEntityHighlighted(const std::string& sketchId, const std::string& entityId,
                                    bool highlighted);

    // Maps a pick path to a body or sketch entity. Grid and axes are
    // unpickable; the sketch plane helper IS pickable (sketch tools read
    // click positions from ray hits on it) but resolves to an empty target.
    ViewportPickTarget pickTargetForPath(const SoPath* path) const;

private:
    SoSeparator* root_ = nullptr;
    SoSeparator* objectsRoot_ = nullptr;
    SoSeparator* sketchesRoot_ = nullptr;
    SoSeparator* sketchPlaneNode_ = nullptr;
    std::unordered_map<std::string, SoSeparator*> objectNodes_;
    std::unordered_map<std::string, SoTransform*> objectTransforms_;
    std::unordered_map<std::string, SoMaterial*> objectMaterials_;
    std::unordered_map<std::string, SbColor> objectBaseColors_;
    std::unordered_map<const SoSeparator*, std::string> nodeToObjectId_;
    std::unordered_map<std::string, SoSeparator*> sketchNodes_;
    std::unordered_map<const SoSeparator*, std::pair<std::string, std::string>>
        nodeToSketchEntity_;
    std::unordered_map<std::string, SoBaseColor*> entityColors_; // "sketchId\nentityId"
};

} // namespace cadnext::viewer
