#pragma once

#include <string>
#include <unordered_map>

#include <utility>
#include <vector>

#include "cadnext/AttachmentPoint.hpp"
#include "cadnext/Object.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/EdgeAnalyzer.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/TriangleMesh.hpp"

#include <Inventor/SbColor.h>
#include <Inventor/SbVec3f.h>

class SoBaseColor;
class SoCoordinate3;
class SoDrawStyle;
class SoIndexedFaceSet;
class SoLineSet;
class SoMaterial;
class SoPath;
class SoPickedPoint;
class SoSeparator;
class SoSwitch;
class SoTransform;
class SoTranslation;

namespace cadnext::viewer {

// What a viewport click resolved to: a body, a body face, a sketch
// entity, a sketch profile region, an attachment point marker, or nothing.
// Face picks carry both the face id and the owning body id (objectId), so
// body picking keeps working underneath face picking. Attachment point
// picks carry both the point id and the owning body id (objectId).
struct ViewportPickTarget {
    std::string objectId;
    std::string workPlaneId;
    std::string sketchId;
    std::string entityId;
    std::string profileId;
    std::string faceId;
    std::string edgeId;
    std::string attachmentPointId;
    cadnext::Vector3 worldPoint;
    int triangleIndex = -1;
    bool faceLookupAttempted = false;
    bool hasWorldPoint = false;

    bool isBody() const { return !objectId.empty(); }
    bool isBodyFace() const { return !faceId.empty(); }
    bool isBodyEdge() const { return !edgeId.empty(); }
    bool isWorkPlane() const { return !workPlaneId.empty(); }
    bool isSketchEntity() const { return !entityId.empty(); }
    bool isProfile() const { return !profileId.empty(); }
    bool isAttachmentPoint() const { return !attachmentPointId.empty(); }
    bool isEmpty() const {
        return objectId.empty() && workPlaneId.empty() && entityId.empty() &&
               profileId.empty() && faceId.empty() && edgeId.empty() &&
               attachmentPointId.empty();
    }
};

// Owns the Coin3D scene graph for the CADNext prototype viewer.
// Layered root (render order = child order):
//
//   worldHelpersSwitch_   world grid + X/Y/Z axes (hidden in Sketch2D)
//   documentRoot_         objectsRoot_ (bodies) + sketchesRoot_
//   workPlaneRoot_        canonical work plane helpers, one SoSwitch per
//                         plane; outline-first, fill never writes depth
//   sketchPlaneRoot_      active sketch plane helper (Sketch2D only)
//   sketchTransientRoot_  cursor / anchor / rubber-band preview
//
// Work planes render after the bodies and their fill does not write the
// depth buffer, so helper planes can never visually occlude bodies; the
// fill stays pickable as the plane's pick proxy (the thin outline alone
// would be too hard to hit). Geometry is built from the
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
    // Bodies + sketches (the document contents a Fit View frames).
    SoSeparator* documentRoot() const;
    // Active sketch plane helper container (empty outside Sketch2D).
    SoSeparator* sketchPlaneRoot() const;
    // Canonical work plane helper node, or nullptr for unknown ids.
    SoSeparator* workPlaneNode(const std::string& planeId) const;

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
    void setBodiesDimmed(bool dimmed);

    // Selectable work planes. Canonical XY/XZ/YZ planes are persistent
    // scene helpers; reference plane objects are rendered through the
    // object path but resolve to work-plane pick targets.
    void showCanonicalWorkPlanes(double extent);
    void setHoveredWorkPlane(const std::string& planeId);
    void setSelectedWorkPlane(const std::string& planeId);

    // Document work planes (CADNext 0.8: planes created from body faces).
    // Same outline-first visual and hover/selection states as the
    // canonical planes; they share the work-plane pick target path.
    void addOrUpdateDocumentWorkPlane(const WorkPlane& plane);
    void removeDocumentWorkPlane(const std::string& planeId);
    void clearDocumentWorkPlanes();

    // --- Body face overlays (CADNext 0.8 Sketch on Face) -----------------
    // Per-face pick proxies built from the FaceAnalyzer triangulation,
    // lifted slightly along the face normal so they win picks over the
    // body surface. Idle faces are invisible; hover tints the fill,
    // selection brightens the fill and shows the boundary outline. The
    // overlays are viewer-only state: never part of the document, never
    // serialized. Hidden in Sketch2D so they cannot steal sketch picks.
    void setBodyFaces(const std::string& bodyId,
                      const std::vector<kernel::FaceReference>& faces);
    void removeBodyFaces(const std::string& bodyId);
    void clearBodyFaces();
    void setBodyFacesVisible(bool visible);
    void setHoveredBodyFace(const std::string& bodyId, const std::string& faceId);
    void setSelectedBodyFace(const std::string& bodyId, const std::string& faceId);

    // --- Body edge highlight (CADNext 0.9 Edge Selection) ----------------
    // Edge references are transient derived data from the current BRep
    // state. The selected edge is drawn as one bright unpickable polyline;
    // it does not select or tint the whole body.
    void setBodyEdges(const std::string& bodyId,
                      const std::vector<kernel::EdgeReference>& edges);
    void removeBodyEdges(const std::string& bodyId);
    void clearBodyEdges();
    void highlightBodyEdge(const std::string& bodyId, const std::string& edgeId);
    void clearBodyEdgeHighlight();

    // --- Attachment point markers (UAVPart v1.1) --------------------------
    // Small sphere markers at each attachment point's local position inside
    // the body node so they track body transforms automatically. The
    // selected point is highlighted in yellow. Markers are pickable and
    // resolve to a ViewportPickTarget with attachmentPointId set.
    // The preview is a transient world-space sphere shown while the
    // attachment point tool is active and the cursor hovers a body face.
    void addOrUpdateAttachmentPointMarkers(const std::string& bodyId,
                                           const std::vector<AttachmentPoint>& points);
    void removeAttachmentPointMarkers(const std::string& bodyId);
    void clearAttachmentPointMarkers();
    void setSelectedAttachmentPoint(const std::string& bodyId, const std::string& pointId);
    void clearSelectedAttachmentPoint();
    void showAttachmentPointPreview(const Vector3& worldPos);
    void hideAttachmentPointPreview();

    // --- Helper visibility (ViewportPolicy application) -------------------
    // World grid + axes; hidden in Sketch2D so no huge 3D axes cross the
    // flat sketch view.
    void setWorldHelpersVisible(bool visible);
    // Per-plane visibility for Sketch2D (all hidden) and the Free3D
    // "Hide Other Planes" action.
    void setWorkPlaneVisible(const std::string& planeId, bool visible);

    // --- Sketch display (CADNext 0.5) ------------------------------------
    // Entities are drawn as world-space polylines on the sketch's plane;
    // the active-sketch plane helper (translucent quad + U/V axes) is shown
    // only while a sketch is being edited. gridStep controls the helper
    // grid spacing (visually capped for very fine steps); showGrid hides
    // the grid lines while keeping the plane fill and axes.
    void showSketchPlane(const WorkPlane& plane, double gridStep = 1.0, bool showGrid = true);
    void hideSketchPlane();
    void addOrUpdateSketchNode(const Sketch& sketch);
    void removeSketchNode(const std::string& sketchId);
    void clearSketchNodes();
    void setSketchEntityHighlighted(const std::string& sketchId, const std::string& entityId,
                                    bool highlighted);

    // --- Sketch profiles (CADNext 0.6) ------------------------------------
    // Detected closed profiles drawn as a faint pickable fill slightly
    // behind the sketch plane (so entity lines win the pick on overlap);
    // the selected profile gets a brighter fill plus an outline. Only the
    // active sketch shows profiles; clearSketchProfiles() removes them.
    void showSketchProfiles(const Sketch& sketch, const std::vector<SketchProfile>& profiles);
    void clearSketchProfiles();
    void setSelectedProfile(const std::string& profileId);

    // --- Extrude / cutter preview -------------------------------------------
    // Translucent, unpickable prism mesh shown while the Extrude or Cut
    // Extrude dialog is open. cutStyle renders the cutter volume in
    // warning red/orange instead of the additive cyan. Never part of the
    // document and never serialized.
    void showExtrudePreview(const kernel::TriangleMesh& mesh, bool cutStyle = false);
    void hideExtrudePreview();

    // --- Transient sketch input visuals -----------------------------------
    // Cursor crosshair, first-point anchor marker and the rubber-band
    // preview for Line/Rectangle/Circle. They live under a dedicated
    // unpickable root rendered after the sketch plane, are never part of
    // the document tree and are never serialized; commit/Esc/exit sketch
    // mode clears them.
    void showSketchCursor(const SketchPoint2D& point, const SketchReference& reference);
    void updateSketchCursor(const SketchPoint2D& point, const SketchReference& reference);
    void hideSketchCursor();
    void showSketchAnchor(const SketchPoint2D& point, const SketchReference& reference);
    void hideSketchAnchor();
    void updateLinePreview(const SketchPoint2D& start, const SketchPoint2D& end,
                           const SketchReference& reference);
    void updateRectanglePreview(const SketchPoint2D& first, const SketchPoint2D& second,
                                const SketchReference& reference);
    void updateCirclePreview(const SketchPoint2D& center, const SketchPoint2D& radiusPoint,
                             const SketchReference& reference);
    void clearSketchPreview();

    // Maps a pick path to a body or sketch entity. Grid and axes are
    // unpickable; the sketch plane helper IS pickable (sketch tools read
    // click positions from ray hits on it) but resolves to an empty target.
    ViewportPickTarget pickTargetForPickedPoint(const SoPickedPoint* picked) const;
    ViewportPickTarget pickTargetForPath(const SoPath* path) const;

private:
    struct MeshPickInfo {
        std::string objectId;
        std::vector<std::string> triangleFaceIds;
    };

    void removeMeshPickInfoForObject(const std::string& objectId);
    std::string resolveBodyFaceFromPoint(const std::string& bodyId,
                                         const SbVec3f& worldPoint) const;
    void updateWorkPlaneVisual(const std::string& planeId);
    void updateProfileVisual(const std::string& profileId);
    void updateBodyFaceVisual(const std::string& faceKey);
    void addWorkPlaneVisual(const WorkPlane& plane);

    // Lazily creates one transient polyline slot (cursor/anchor/preview).
    SoSeparator* ensureTransientPolyline(SoSeparator*& node, SoCoordinate3*& coords,
                                         SoLineSet*& lines, const SbColor& color,
                                         float lineWidth);

    SoSeparator* root_ = nullptr;
    SoSwitch* worldHelpersSwitch_ = nullptr;
    SoSeparator* documentRoot_ = nullptr;
    SoSeparator* objectsRoot_ = nullptr;
    SoSeparator* sketchesRoot_ = nullptr;
    SoSeparator* workPlaneRoot_ = nullptr;
    SoSeparator* sketchProfilesRoot_ = nullptr;
    SoSeparator* extrudePreviewRoot_ = nullptr;
    SoSeparator* extrudePreviewNode_ = nullptr;
    SoSeparator* sketchPlaneRoot_ = nullptr;
    SoSeparator* sketchPlaneNode_ = nullptr;
    SoSeparator* sketchTransientRoot_ = nullptr;
    SoSeparator* sketchCursorNode_ = nullptr;
    SoCoordinate3* sketchCursorCoords_ = nullptr;
    SoLineSet* sketchCursorLines_ = nullptr;
    SoSeparator* sketchAnchorNode_ = nullptr;
    SoCoordinate3* sketchAnchorCoords_ = nullptr;
    SoLineSet* sketchAnchorLines_ = nullptr;
    SoSeparator* sketchPreviewNode_ = nullptr;
    SoCoordinate3* sketchPreviewCoords_ = nullptr;
    SoLineSet* sketchPreviewLines_ = nullptr;
    std::unordered_map<std::string, SoSeparator*> objectNodes_;
    std::unordered_map<std::string, SoTransform*> objectTransforms_;
    std::unordered_map<std::string, SoMaterial*> objectMaterials_;
    std::unordered_map<std::string, SbColor> objectBaseColors_;
    std::unordered_map<std::string, ObjectType> objectTypes_;
    std::unordered_map<const SoIndexedFaceSet*, MeshPickInfo> meshPickInfo_;
    std::unordered_map<std::string, std::vector<kernel::FaceReference>> bodyFaceReferences_;
    std::unordered_map<const SoSeparator*, std::string> nodeToObjectId_;
    std::unordered_map<const SoSeparator*, std::string> nodeToWorkPlaneId_;
    std::unordered_map<std::string, SoSeparator*> workPlaneNodes_;
    std::unordered_map<std::string, SoSwitch*> workPlaneSwitches_;
    std::unordered_map<std::string, SoMaterial*> workPlaneFillMaterials_;
    std::unordered_map<std::string, SoBaseColor*> workPlaneBorderColors_;
    std::unordered_map<std::string, SoDrawStyle*> workPlaneBorderStyles_;
    std::unordered_map<std::string, SoSeparator*> sketchNodes_;
    std::unordered_map<const SoSeparator*, std::pair<std::string, std::string>>
        nodeToSketchEntity_;
    std::unordered_map<std::string, SoBaseColor*> entityColors_; // "sketchId\nentityId"
    std::unordered_map<const SoSeparator*, std::string> nodeToProfileId_;
    std::unordered_map<std::string, SoMaterial*> profileFillMaterials_;
    std::unordered_map<std::string, SoBaseColor*> profileOutlineColors_;
    std::unordered_map<std::string, SoDrawStyle*> profileOutlineStyles_;
    // Body face overlays, keyed by "bodyId\nfaceId".
    SoSwitch* bodyFacesSwitch_ = nullptr;
    SoSeparator* bodyFacesRoot_ = nullptr;
    SoSeparator* bodyEdgeHighlightRoot_ = nullptr;
    SoSeparator* bodyEdgeHighlightNode_ = nullptr;
    std::unordered_map<std::string, SoSeparator*> bodyFaceGroups_; // per body
    std::unordered_map<const SoSeparator*, std::pair<std::string, std::string>>
        nodeToBodyFace_;
    std::unordered_map<std::string, SoMaterial*> faceFillMaterials_;
    std::unordered_map<std::string, SoSwitch*> faceOutlineSwitches_;
    std::unordered_map<std::string, std::vector<kernel::EdgeReference>> bodyEdgeReferences_;
    std::string hoveredWorkPlaneId_;
    std::string selectedWorkPlaneId_;
    std::string selectedProfileId_;
    std::string hoveredBodyFaceKey_;
    std::string selectedBodyFaceKey_;
    std::string selectedBodyEdgeKey_;
    bool bodiesDimmed_ = false;

    // Attachment point markers: one SoSeparator per body (added as a child
    // of the body node so local positions are in body space). The preview
    // node lives in world space and is repositioned on hover.
    std::unordered_map<std::string, SoSeparator*> attachmentMarkerGroups_;
    std::unordered_map<const SoSeparator*, std::pair<std::string, std::string>>
        nodeToAttachmentPoint_; // marker sep → {bodyId, pointId}
    SoSeparator* attachmentPreviewRoot_ = nullptr;
    SoSeparator* attachmentPreviewNode_ = nullptr;
    SoTranslation* attachmentPreviewTranslation_ = nullptr;
    std::string selectedAttachmentBodyId_;
    std::string selectedAttachmentPointId_;
};

} // namespace cadnext::viewer
