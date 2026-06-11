#include "cadnext/viewer/SceneGraph.hpp"

#include <cmath>
#include <vector>

#include "cadnext/SketchInput.hpp"

#include <Inventor/SoPath.h>
#include <Inventor/nodes/SoBaseColor.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoCube.h>
#include <Inventor/nodes/SoCylinder.h>
#include <Inventor/nodes/SoDepthBuffer.h>
#include <Inventor/nodes/SoDrawStyle.h>
#include <Inventor/nodes/SoFaceSet.h>
#include <Inventor/nodes/SoCone.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoLightModel.h>
#include <Inventor/nodes/SoLineSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoPickStyle.h>
#include <Inventor/nodes/SoRotation.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <Inventor/nodes/SoSphere.h>
#include <Inventor/nodes/SoSwitch.h>
#include <Inventor/nodes/SoText2.h>
#include <Inventor/nodes/SoTransform.h>
#include <Inventor/nodes/SoTranslation.h>

namespace cadnext::viewer {

namespace {

constexpr float kGridHalfExtent = 10.0f;
constexpr int kGridLineCount = 21; // every 1.0 units from -10 to +10
constexpr float kAxisLength = 10.0f;

// Index of the SoTransform / SoMaterial children inside each object node;
// shape children start right after the material (see addObjectNode).
constexpr int kTransformChildIndex = 0;
constexpr int kMaterialChildIndex = 1;

const SbColor kDefaultDiffuse(0.72f, 0.74f, 0.78f);
const SbColor kPlaneDiffuse(0.35f, 0.55f, 0.85f);
const SbColor kHighlightDiffuse(0.95f, 0.65f, 0.15f);
const SbColor kHighlightEmissive(0.30f, 0.18f, 0.02f);
const SbColor kWorkPlaneFill(0.30f, 0.43f, 0.72f);
const SbColor kWorkPlaneBorder(0.55f, 0.68f, 0.95f);
const SbColor kWorkPlaneHoverFill(0.30f, 0.60f, 0.88f);
const SbColor kWorkPlaneHoverBorder(0.70f, 0.88f, 1.0f);
const SbColor kWorkPlaneSelectedFill(0.90f, 0.62f, 0.18f);
const SbColor kWorkPlaneSelectedBorder(1.0f, 0.82f, 0.30f);

// Outline-first plane highlighting: by default only the frame is drawn —
// the fill quad stays in the graph as an invisible pick proxy and only
// gets a faint tint on hover/selection. It never writes depth, so it can
// tint but never occlude bodies.
constexpr float kWorkPlaneFillIdleTransparency = 1.0f;
constexpr float kWorkPlaneFillHoverTransparency = 0.92f;
constexpr float kWorkPlaneFillSelectedTransparency = 0.85f;

// Prevents transparent helper fills from writing the depth buffer (so
// bodies rendered around them are never hidden behind "glass").
SoDepthBuffer* noDepthWrite() {
    auto* depth = new SoDepthBuffer;
    depth->write = FALSE;
    return depth;
}

constexpr double kDegreesToRadians = M_PI / 180.0;

SoPickStyle* unpickableStyle() {
    auto* style = new SoPickStyle;
    style->style = SoPickStyle::UNPICKABLE;
    return style;
}

SbVec3f toSb(const Vector3& v) {
    return {static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)};
}

SbVec3f planePoint(const WorkPlane& plane, double u, double v) {
    const Vector3 point{plane.origin.x + plane.uAxis.x * u + plane.vAxis.x * v,
                        plane.origin.y + plane.uAxis.y * u + plane.vAxis.y * v,
                        plane.origin.z + plane.uAxis.z * u + plane.vAxis.z * v};
    return toSb(point);
}

SoSeparator* buildGrid() {
    auto* grid = new SoSeparator;
    grid->addChild(unpickableStyle());

    auto* lightModel = new SoLightModel;
    lightModel->model = SoLightModel::BASE_COLOR;
    grid->addChild(lightModel);

    auto* color = new SoBaseColor;
    color->rgb = SbColor(0.32f, 0.34f, 0.38f);
    grid->addChild(color);

    auto* style = new SoDrawStyle;
    style->lineWidth = 1.0f;
    grid->addChild(style);

    auto* coords = new SoCoordinate3;
    auto* lines = new SoLineSet;

    int vertexIndex = 0;
    int lineIndex = 0;
    coords->point.setNum(kGridLineCount * 4);
    lines->numVertices.setNum(kGridLineCount * 2);
    for (int i = 0; i < kGridLineCount; ++i) {
        const float offset = -kGridHalfExtent + static_cast<float>(i);
        // Line parallel to X axis.
        coords->point.set1Value(vertexIndex++, -kGridHalfExtent, offset, 0.0f);
        coords->point.set1Value(vertexIndex++, kGridHalfExtent, offset, 0.0f);
        lines->numVertices.set1Value(lineIndex++, 2);
        // Line parallel to Y axis.
        coords->point.set1Value(vertexIndex++, offset, -kGridHalfExtent, 0.0f);
        coords->point.set1Value(vertexIndex++, offset, kGridHalfExtent, 0.0f);
        lines->numVertices.set1Value(lineIndex++, 2);
    }
    grid->addChild(coords);
    grid->addChild(lines);
    return grid;
}

SoSeparator* buildAxis(const SbColor& color, const SbVec3f& direction, const char* label) {
    auto* axis = new SoSeparator;

    auto* baseColor = new SoBaseColor;
    baseColor->rgb = color;
    axis->addChild(baseColor);

    auto* coords = new SoCoordinate3;
    coords->point.set1Value(0, 0.0f, 0.0f, 0.0f);
    coords->point.set1Value(1, direction * kAxisLength);
    axis->addChild(coords);

    auto* line = new SoLineSet;
    line->numVertices.set1Value(0, 2);
    axis->addChild(line);

    auto* labelOffset = new SoTranslation;
    labelOffset->translation = direction * (kAxisLength * 1.04f);
    axis->addChild(labelOffset);

    auto* text = new SoText2;
    text->string = label;
    axis->addChild(text);

    return axis;
}

SoSeparator* buildAxes() {
    auto* axes = new SoSeparator;
    axes->addChild(unpickableStyle());

    auto* lightModel = new SoLightModel;
    lightModel->model = SoLightModel::BASE_COLOR;
    axes->addChild(lightModel);

    auto* style = new SoDrawStyle;
    style->lineWidth = 2.0f;
    axes->addChild(style);

    axes->addChild(buildAxis(SbColor(0.85f, 0.20f, 0.20f), SbVec3f(1.0f, 0.0f, 0.0f), "X"));
    axes->addChild(buildAxis(SbColor(0.20f, 0.75f, 0.25f), SbVec3f(0.0f, 1.0f, 0.0f), "Y"));
    axes->addChild(buildAxis(SbColor(0.25f, 0.45f, 0.95f), SbVec3f(0.0f, 0.0f, 1.0f), "Z"));
    return axes;
}

// World axes are Z-up; SoCylinder/SoCone are built along +Y, so primitive
// geometry that should stand on the grid gets a +90° rotation about X.
SoRotation* yUpToZUpRotation() {
    auto* rotation = new SoRotation;
    rotation->rotation = SbRotation(SbVec3f(1.0f, 0.0f, 0.0f), static_cast<float>(M_PI_2));
    return rotation;
}

void addPrimitiveShape(SoSeparator* parent, const Object& object) {
    const PrimitiveParameters& params = object.primitive;

    if (object.type == ObjectType::ReferencePlane) {
        // Placeholder reference plane: a lightly tinted quad in XY, sized
        // by width (X) and height (Y). Like the canonical plane helpers it
        // never writes depth, so it cannot visually occlude bodies.
        auto* depth = new SoDepthBuffer;
        depth->write = FALSE;
        parent->addChild(depth);
        auto* hints = new SoShapeHints;
        hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
        hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
        parent->addChild(hints);

        const float halfW = static_cast<float>(params.width) * 0.5f;
        const float halfH = static_cast<float>(params.height) * 0.5f;
        auto* coords = new SoCoordinate3;
        coords->point.set1Value(0, -halfW, -halfH, 0.0f);
        coords->point.set1Value(1, halfW, -halfH, 0.0f);
        coords->point.set1Value(2, halfW, halfH, 0.0f);
        coords->point.set1Value(3, -halfW, halfH, 0.0f);
        parent->addChild(coords);

        auto* face = new SoFaceSet;
        face->numVertices.set1Value(0, 4);
        parent->addChild(face);
        return;
    }

    switch (params.kind) {
    case PrimitiveKind::Box: {
        auto* cube = new SoCube;
        // PrimitiveParameters: width=X, depth=Y, height=Z.
        // SoCube: width=X, height=Y, depth=Z.
        cube->width = static_cast<float>(params.width);
        cube->height = static_cast<float>(params.depth);
        cube->depth = static_cast<float>(params.height);
        parent->addChild(cube);
        break;
    }
    case PrimitiveKind::Cylinder: {
        parent->addChild(yUpToZUpRotation());
        auto* cylinder = new SoCylinder;
        cylinder->radius = static_cast<float>(params.radius);
        cylinder->height = static_cast<float>(params.height);
        parent->addChild(cylinder);
        break;
    }
    case PrimitiveKind::Sphere: {
        auto* sphere = new SoSphere;
        sphere->radius = static_cast<float>(params.radius);
        parent->addChild(sphere);
        break;
    }
    case PrimitiveKind::Cone: {
        parent->addChild(yUpToZUpRotation());
        auto* cone = new SoCone;
        cone->bottomRadius = static_cast<float>(params.radius);
        cone->height = static_cast<float>(params.height);
        parent->addChild(cone);
        break;
    }
    case PrimitiveKind::None:
        break;
    }
}

SketchReference referenceForSketch(const cadnext::Sketch& sketch) {
    if (!sketch.reference.sourceId.empty()) {
        return sketch.reference;
    }
    return canonicalSketchReference(sketch.plane);
}

SbVec3f sketchUVToWorld(const cadnext::SketchReference& reference, double u, double v) {
    // Single source of truth: the same core transform the input projection
    // and the transient previews use.
    return toSb(cadnext::sketchPointToWorld({u, v}, reference));
}

std::vector<SbVec3f> sketchEntityPolyline(const cadnext::SketchReference& reference,
                                          const cadnext::SketchEntity& entity) {
    std::vector<SbVec3f> points;
    switch (entity.type) {
    case cadnext::SketchEntityType::Line:
        points.push_back(sketchUVToWorld(reference, entity.line.start.u, entity.line.start.v));
        points.push_back(sketchUVToWorld(reference, entity.line.end.u, entity.line.end.v));
        break;
    case cadnext::SketchEntityType::Rectangle: {
        const auto& rect = entity.rectangle;
        const double u0 = rect.origin.u;
        const double v0 = rect.origin.v;
        const double u1 = rect.origin.u + rect.width;
        const double v1 = rect.origin.v + rect.height;
        points.push_back(sketchUVToWorld(reference, u0, v0));
        points.push_back(sketchUVToWorld(reference, u1, v0));
        points.push_back(sketchUVToWorld(reference, u1, v1));
        points.push_back(sketchUVToWorld(reference, u0, v1));
        points.push_back(sketchUVToWorld(reference, u0, v0));
        break;
    }
    case cadnext::SketchEntityType::Circle: {
        constexpr int kSegments = 48;
        const auto& circle = entity.circle;
        for (int i = 0; i <= kSegments; ++i) {
            const double angle = 2.0 * M_PI * static_cast<double>(i) / kSegments;
            points.push_back(sketchUVToWorld(reference,
                                             circle.center.u + circle.radius * std::cos(angle),
                                             circle.center.v + circle.radius * std::sin(angle)));
        }
        break;
    }
    }
    return points;
}

const SbColor kSketchEntityColor(0.92f, 0.93f, 0.97f);
const SbColor kSketchEntityHighlight(0.95f, 0.65f, 0.15f);

// Detected profile regions: faint fill so the user sees "this area can be
// extruded"; the selected profile turns brighter with an orange outline.
const SbColor kProfileFill(0.40f, 0.62f, 0.85f);
const SbColor kProfileSelectedFill(0.95f, 0.65f, 0.15f);
const SbColor kProfileOutline(0.55f, 0.75f, 0.95f);
const SbColor kProfileSelectedOutline(1.0f, 0.82f, 0.30f);
constexpr float kProfileFillTransparency = 0.88f;
constexpr float kProfileSelectedFillTransparency = 0.72f;

const SbColor kExtrudePreviewColor(0.35f, 0.85f, 0.95f);
constexpr float kExtrudePreviewTransparency = 0.65f;

// Transient input visuals: distinct from committed entity white so the
// user can tell pending geometry from real geometry at a glance.
const SbColor kSketchCursorColor(0.45f, 0.95f, 0.60f);
const SbColor kSketchAnchorColor(0.95f, 0.65f, 0.15f);
const SbColor kSketchPreviewColor(0.35f, 0.85f, 0.95f);

// Transients are lifted slightly along the plane normal so they always
// render above the plane fill and grid lines.
constexpr double kTransientLift = 0.002;
constexpr double kCursorCrossHalf = 0.12;
constexpr double kCursorBoxHalf = 0.03;
constexpr double kAnchorHalf = 0.06;
constexpr int kCirclePreviewSegments = 48;

SbVec3f transientPoint(const cadnext::SketchReference& reference, double u, double v) {
    Vector3 point = cadnext::sketchPointToWorld({u, v}, reference);
    point.x += reference.normal.x * kTransientLift;
    point.y += reference.normal.y * kTransientLift;
    point.z += reference.normal.z * kTransientLift;
    return toSb(point);
}

// Triangle mesh derived from an evaluated BRep shape (OCCT path). Coin
// computes smooth normals from the crease angle, so curved OCCT surfaces
// shade correctly without explicit per-vertex normals.
void addMeshShape(SoSeparator* parent, const cadnext::kernel::TriangleMesh& mesh) {
    auto* hints = new SoShapeHints;
    hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    hints->shapeType = SoShapeHints::SOLID;
    hints->creaseAngle = 0.9f;
    parent->addChild(hints);

    auto* coords = new SoCoordinate3;
    coords->point.setNum(static_cast<int>(mesh.vertices.size()));
    for (size_t i = 0; i < mesh.vertices.size(); ++i) {
        const auto& vertex = mesh.vertices[i];
        coords->point.set1Value(static_cast<int>(i), static_cast<float>(vertex.x),
                                static_cast<float>(vertex.y), static_cast<float>(vertex.z));
    }
    parent->addChild(coords);

    auto* faceSet = new SoIndexedFaceSet;
    faceSet->coordIndex.setNum(static_cast<int>(mesh.triangles.size() * 4));
    int index = 0;
    for (const auto& triangle : mesh.triangles) {
        faceSet->coordIndex.set1Value(index++, static_cast<int>(triangle.a));
        faceSet->coordIndex.set1Value(index++, static_cast<int>(triangle.b));
        faceSet->coordIndex.set1Value(index++, static_cast<int>(triangle.c));
        faceSet->coordIndex.set1Value(index++, -1);
    }
    parent->addChild(faceSet);
}

// rotationEuler is stored in degrees (see README); applied as a rotation
// about X, then Y, then Z (extrinsic, world axes).
void applyTransform(SoTransform* node, const Transform& transform) {
    node->translation = SbVec3f(static_cast<float>(transform.position.x),
                                static_cast<float>(transform.position.y),
                                static_cast<float>(transform.position.z));
    node->scaleFactor = SbVec3f(static_cast<float>(transform.scale.x),
                                static_cast<float>(transform.scale.y),
                                static_cast<float>(transform.scale.z));

    const SbRotation rx(SbVec3f(1.0f, 0.0f, 0.0f),
                        static_cast<float>(transform.rotationEuler.x * kDegreesToRadians));
    const SbRotation ry(SbVec3f(0.0f, 1.0f, 0.0f),
                        static_cast<float>(transform.rotationEuler.y * kDegreesToRadians));
    const SbRotation rz(SbVec3f(0.0f, 0.0f, 1.0f),
                        static_cast<float>(transform.rotationEuler.z * kDegreesToRadians));
    // Coin composes q1 * q2 as "q1 first, then q2".
    node->rotation = rx * ry * rz;
}

} // namespace

SceneGraph::SceneGraph() {
    root_ = new SoSeparator;
    root_->ref();

    worldHelpersSwitch_ = new SoSwitch;
    worldHelpersSwitch_->whichChild = SO_SWITCH_ALL;
    worldHelpersSwitch_->addChild(buildGrid());
    worldHelpersSwitch_->addChild(buildAxes());
    root_->addChild(worldHelpersSwitch_);

    documentRoot_ = new SoSeparator;
    objectsRoot_ = new SoSeparator;
    documentRoot_->addChild(objectsRoot_);
    sketchesRoot_ = new SoSeparator;
    documentRoot_->addChild(sketchesRoot_);
    root_->addChild(documentRoot_);

    // Work planes render after the document so their depth-write-free
    // fill blends over bodies instead of occluding them.
    workPlaneRoot_ = new SoSeparator;
    root_->addChild(workPlaneRoot_);
    showCanonicalWorkPlanes(8.0);

    // Detected sketch profile fills (active sketch only).
    sketchProfilesRoot_ = new SoSeparator;
    root_->addChild(sketchProfilesRoot_);

    sketchPlaneRoot_ = new SoSeparator;
    root_->addChild(sketchPlaneRoot_);

    // Extrude preview ghost: after the sketch plane helper so the
    // translucent prism reads on top of the plane fill/grid.
    extrudePreviewRoot_ = new SoSeparator;
    root_->addChild(extrudePreviewRoot_);

    // Always last in the root so transient input visuals render after the
    // sketch plane helper; unpickable so the cursor/preview never swallow
    // tool clicks or selection picks.
    sketchTransientRoot_ = new SoSeparator;
    sketchTransientRoot_->addChild(unpickableStyle());
    root_->addChild(sketchTransientRoot_);
}

SceneGraph::~SceneGraph() {
    root_->unref();
}

SoSeparator* SceneGraph::root() const { return root_; }

SoSeparator* SceneGraph::objectsRoot() const { return objectsRoot_; }

SoSeparator* SceneGraph::documentRoot() const { return documentRoot_; }

SoSeparator* SceneGraph::sketchPlaneRoot() const { return sketchPlaneRoot_; }

SoSeparator* SceneGraph::workPlaneNode(const std::string& planeId) const {
    auto it = workPlaneNodes_.find(planeId);
    return it != workPlaneNodes_.end() ? it->second : nullptr;
}

void SceneGraph::setWorldHelpersVisible(bool visible) {
    worldHelpersSwitch_->whichChild = visible ? SO_SWITCH_ALL : SO_SWITCH_NONE;
}

void SceneGraph::setWorkPlaneVisible(const std::string& planeId, bool visible) {
    auto it = workPlaneSwitches_.find(planeId);
    if (it == workPlaneSwitches_.end()) {
        return;
    }
    it->second->whichChild = visible ? SO_SWITCH_ALL : SO_SWITCH_NONE;
}

void SceneGraph::addObjectNode(const Object& object) {
    if (hasObjectNode(object.id)) {
        removeObjectNode(object.id);
    }

    auto* node = new SoSeparator;

    auto* transform = new SoTransform;
    applyTransform(transform, object.transform);
    node->addChild(transform);

    auto* material = new SoMaterial;
    material->diffuseColor = kDefaultDiffuse;
    if (object.type == ObjectType::ReferencePlane) {
        material->diffuseColor = kPlaneDiffuse;
        material->transparency = 0.75f;
    }
    node->addChild(material);

    addPrimitiveShape(node, object);

    objectsRoot_->addChild(node);
    objectNodes_[object.id] = node;
    objectTransforms_[object.id] = transform;
    objectMaterials_[object.id] = material;
    objectBaseColors_[object.id] = material->diffuseColor[0];
    objectTypes_[object.id] = object.type;
    if (object.type == ObjectType::ReferencePlane) {
        nodeToWorkPlaneId_[node] = object.id;
    } else {
        nodeToObjectId_[node] = object.id;
    }
}

void SceneGraph::removeObjectNode(const std::string& objectId) {
    auto it = objectNodes_.find(objectId);
    if (it == objectNodes_.end()) {
        return;
    }
    nodeToObjectId_.erase(it->second);
    nodeToWorkPlaneId_.erase(it->second);
    objectsRoot_->removeChild(it->second);
    objectNodes_.erase(it);
    objectTransforms_.erase(objectId);
    objectMaterials_.erase(objectId);
    objectBaseColors_.erase(objectId);
    objectTypes_.erase(objectId);
    if (hoveredWorkPlaneId_ == objectId) {
        hoveredWorkPlaneId_.clear();
    }
    if (selectedWorkPlaneId_ == objectId) {
        selectedWorkPlaneId_.clear();
    }
}

void SceneGraph::clearObjectNodes() {
    objectsRoot_->removeAllChildren();
    objectNodes_.clear();
    objectTransforms_.clear();
    objectMaterials_.clear();
    objectBaseColors_.clear();
    objectTypes_.clear();
    nodeToObjectId_.clear();
    nodeToWorkPlaneId_.clear();
    hoveredWorkPlaneId_.clear();
    selectedWorkPlaneId_.clear();
}

bool SceneGraph::hasObjectNode(const std::string& objectId) const {
    return objectNodes_.find(objectId) != objectNodes_.end();
}

void SceneGraph::updateObjectTransform(const std::string& objectId, const Transform& transform) {
    auto it = objectTransforms_.find(objectId);
    if (it == objectTransforms_.end()) {
        return;
    }
    applyTransform(it->second, transform);
}

void SceneGraph::updateObjectPrimitive(const Object& object) {
    auto it = objectNodes_.find(object.id);
    if (it == objectNodes_.end()) {
        return;
    }
    SoSeparator* node = it->second;
    // Drop only the shape children; transform and material (and with it
    // the selection highlight) stay in place.
    while (node->getNumChildren() > kMaterialChildIndex + 1) {
        node->removeChild(node->getNumChildren() - 1);
    }
    addPrimitiveShape(node, object);
}

void SceneGraph::addOrUpdateObjectMesh(const Object& object,
                                       const kernel::TriangleMesh& mesh) {
    auto it = objectNodes_.find(object.id);
    if (it == objectNodes_.end()) {
        // Create the node skeleton (transform + material) without shape
        // children, then attach the mesh below.
        auto* node = new SoSeparator;

        auto* transform = new SoTransform;
        applyTransform(transform, object.transform);
        node->addChild(transform);

        auto* material = new SoMaterial;
        material->diffuseColor = kDefaultDiffuse;
        node->addChild(material);

        objectsRoot_->addChild(node);
        objectNodes_[object.id] = node;
        objectTransforms_[object.id] = transform;
        objectMaterials_[object.id] = material;
        objectBaseColors_[object.id] = material->diffuseColor[0];
        objectTypes_[object.id] = object.type;
        nodeToObjectId_[node] = object.id;

        addMeshShape(node, mesh);
        return;
    }

    SoSeparator* node = it->second;
    while (node->getNumChildren() > kMaterialChildIndex + 1) {
        node->removeChild(node->getNumChildren() - 1);
    }
    addMeshShape(node, mesh);
}

void SceneGraph::setHighlighted(const std::string& objectId, bool highlighted) {
    auto it = objectMaterials_.find(objectId);
    if (it == objectMaterials_.end()) {
        return;
    }
    SoMaterial* material = it->second;
    if (highlighted) {
        material->diffuseColor = kHighlightDiffuse;
        material->emissiveColor = kHighlightEmissive;
    } else {
        material->diffuseColor = objectBaseColors_[objectId];
        material->emissiveColor = SbColor(0.0f, 0.0f, 0.0f);
    }
}

void SceneGraph::setBodiesDimmed(bool dimmed) {
    bodiesDimmed_ = dimmed;
    for (auto& entry : objectMaterials_) {
        const std::string& objectId = entry.first;
        if (objectTypes_[objectId] != ObjectType::Body) {
            continue;
        }
        entry.second->transparency = dimmed ? 0.65f : 0.0f;
    }
}

void SceneGraph::showCanonicalWorkPlanes(double extent) {
    workPlaneRoot_->removeAllChildren();
    workPlaneNodes_.clear();
    workPlaneSwitches_.clear();
    workPlaneFillMaterials_.clear();
    workPlaneBorderColors_.clear();
    workPlaneBorderStyles_.clear();
    for (auto it = nodeToWorkPlaneId_.begin(); it != nodeToWorkPlaneId_.end();) {
        if (it->second.rfind("workplane-", 0) == 0) {
            it = nodeToWorkPlaneId_.erase(it);
        } else {
            ++it;
        }
    }

    const SketchPlane planes[] = {SketchPlane::XY, SketchPlane::XZ, SketchPlane::YZ};
    for (const SketchPlane sketchPlane : planes) {
        const WorkPlane plane = makeCanonicalWorkPlane(sketchPlane, extent);
        auto* node = new SoSeparator;

        // Fill quad: invisible by default (outline-first), faintly tinted
        // on hover/selection. No depth write, so it can never hide bodies
        // or the other plane frames; it stays pickable as the pick proxy
        // for the whole plane area.
        auto* fill = new SoSeparator;
        fill->addChild(noDepthWrite());
        auto* hints = new SoShapeHints;
        hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
        hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
        fill->addChild(hints);

        auto* material = new SoMaterial;
        material->diffuseColor = kWorkPlaneFill;
        material->transparency = kWorkPlaneFillIdleTransparency;
        fill->addChild(material);

        const double halfW = plane.width * 0.5;
        const double halfH = plane.height * 0.5;
        auto* fillCoords = new SoCoordinate3;
        fillCoords->point.set1Value(0, planePoint(plane, -halfW, -halfH));
        fillCoords->point.set1Value(1, planePoint(plane, halfW, -halfH));
        fillCoords->point.set1Value(2, planePoint(plane, halfW, halfH));
        fillCoords->point.set1Value(3, planePoint(plane, -halfW, halfH));
        fill->addChild(fillCoords);

        auto* face = new SoFaceSet;
        face->numVertices.set1Value(0, 4);
        fill->addChild(face);
        node->addChild(fill);

        auto* border = new SoSeparator;
        border->addChild(unpickableStyle());
        auto* lightModel = new SoLightModel;
        lightModel->model = SoLightModel::BASE_COLOR;
        border->addChild(lightModel);

        auto* borderColor = new SoBaseColor;
        borderColor->rgb = kWorkPlaneBorder;
        border->addChild(borderColor);

        auto* borderStyle = new SoDrawStyle;
        borderStyle->lineWidth = 1.5f;
        border->addChild(borderStyle);

        auto* borderCoords = new SoCoordinate3;
        borderCoords->point.set1Value(0, planePoint(plane, -halfW, -halfH));
        borderCoords->point.set1Value(1, planePoint(plane, halfW, -halfH));
        borderCoords->point.set1Value(2, planePoint(plane, halfW, halfH));
        borderCoords->point.set1Value(3, planePoint(plane, -halfW, halfH));
        borderCoords->point.set1Value(4, planePoint(plane, -halfW, -halfH));
        border->addChild(borderCoords);

        auto* line = new SoLineSet;
        line->numVertices.set1Value(0, 5);
        border->addChild(line);
        node->addChild(border);

        auto* planeSwitch = new SoSwitch;
        planeSwitch->whichChild = SO_SWITCH_ALL;
        planeSwitch->addChild(node);
        workPlaneRoot_->addChild(planeSwitch);
        workPlaneNodes_[plane.id] = node;
        workPlaneSwitches_[plane.id] = planeSwitch;
        workPlaneFillMaterials_[plane.id] = material;
        workPlaneBorderColors_[plane.id] = borderColor;
        workPlaneBorderStyles_[plane.id] = borderStyle;
        nodeToWorkPlaneId_[node] = plane.id;
    }
}

void SceneGraph::setHoveredWorkPlane(const std::string& planeId) {
    if (hoveredWorkPlaneId_ == planeId) {
        return;
    }
    const std::string old = hoveredWorkPlaneId_;
    hoveredWorkPlaneId_ = planeId;
    updateWorkPlaneVisual(old);
    updateWorkPlaneVisual(hoveredWorkPlaneId_);
}

void SceneGraph::setSelectedWorkPlane(const std::string& planeId) {
    if (selectedWorkPlaneId_ == planeId) {
        return;
    }
    const std::string old = selectedWorkPlaneId_;
    selectedWorkPlaneId_ = planeId;
    updateWorkPlaneVisual(old);
    updateWorkPlaneVisual(selectedWorkPlaneId_);
}

void SceneGraph::updateWorkPlaneVisual(const std::string& planeId) {
    if (planeId.empty()) {
        return;
    }

    const bool selected = planeId == selectedWorkPlaneId_;
    const bool hovered = planeId == hoveredWorkPlaneId_;
    const SbColor fillColor = selected ? kWorkPlaneSelectedFill
                                       : (hovered ? kWorkPlaneHoverFill : kWorkPlaneFill);
    const SbColor borderColor = selected ? kWorkPlaneSelectedBorder
                                         : (hovered ? kWorkPlaneHoverBorder : kWorkPlaneBorder);
    // Outline-first: the idle fill is fully transparent (frame only); the
    // highlight lives mostly in the border color/width.
    const float transparency = selected
                                   ? kWorkPlaneFillSelectedTransparency
                                   : (hovered ? kWorkPlaneFillHoverTransparency
                                              : kWorkPlaneFillIdleTransparency);
    const float lineWidth = selected ? 3.0f : (hovered ? 2.5f : 1.5f);

    if (auto it = workPlaneFillMaterials_.find(planeId);
        it != workPlaneFillMaterials_.end()) {
        it->second->diffuseColor = fillColor;
        it->second->emissiveColor = selected ? SbColor(0.25f, 0.14f, 0.03f)
                                             : SbColor(0.0f, 0.0f, 0.0f);
        it->second->transparency = transparency;
    }
    if (auto it = workPlaneBorderColors_.find(planeId);
        it != workPlaneBorderColors_.end()) {
        it->second->rgb = borderColor;
    }
    if (auto it = workPlaneBorderStyles_.find(planeId);
        it != workPlaneBorderStyles_.end()) {
        it->second->lineWidth = lineWidth;
    }

    if (auto it = objectMaterials_.find(planeId);
        it != objectMaterials_.end() && objectTypes_[planeId] == ObjectType::ReferencePlane) {
        it->second->diffuseColor = fillColor;
        it->second->emissiveColor = selected ? SbColor(0.25f, 0.14f, 0.03f)
                                             : SbColor(0.0f, 0.0f, 0.0f);
        it->second->transparency = selected ? 0.55f : (hovered ? 0.65f : 0.75f);
    }
}

void SceneGraph::showSketchPlane(const WorkPlane& plane, double gridStep, bool showGrid) {
    hideSketchPlane();

    auto* node = new SoSeparator;

    // Faint plane fill. Unpickable: sketch input projects the mouse onto
    // the plane analytically (see CoinViewer), so the quad must never
    // swallow selection picks; no depth write, so the dimmed bodies stay
    // visible through it instead of sitting "behind glass".
    {
        auto* fill = new SoSeparator;
        fill->addChild(unpickableStyle());
        fill->addChild(noDepthWrite());
        auto* hints = new SoShapeHints;
        hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
        hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
        fill->addChild(hints);

        auto* material = new SoMaterial;
        material->diffuseColor = SbColor(0.30f, 0.45f, 0.80f);
        material->transparency = 0.92f;
        fill->addChild(material);

        const double halfW = std::max(plane.width * 0.5, 1.0);
        const double halfH = std::max(plane.height * 0.5, 1.0);
        auto* coords = new SoCoordinate3;
        coords->point.set1Value(0, planePoint(plane, -halfW, -halfH));
        coords->point.set1Value(1, planePoint(plane, halfW, -halfH));
        coords->point.set1Value(2, planePoint(plane, halfW, halfH));
        coords->point.set1Value(3, planePoint(plane, -halfW, halfH));
        fill->addChild(coords);

        auto* face = new SoFaceSet;
        face->numVertices.set1Value(0, 4);
        fill->addChild(face);
        node->addChild(fill);
    }

    // Sketch grid (unpickable overlay). The drawn spacing follows the snap
    // grid step but is capped so a very fine step cannot freeze the viewer
    // — snapping itself always uses the exact step.
    if (showGrid) {
        auto* grid = new SoSeparator;
        grid->addChild(unpickableStyle());

        auto* lightModel = new SoLightModel;
        lightModel->model = SoLightModel::BASE_COLOR;
        grid->addChild(lightModel);

        auto* color = new SoBaseColor;
        color->rgb = SbColor(0.42f, 0.48f, 0.62f);
        grid->addChild(color);

        auto* style = new SoDrawStyle;
        style->lineWidth = 1.0f;
        grid->addChild(style);

        const double halfW = std::max(plane.width * 0.5, 1.0);
        const double halfH = std::max(plane.height * 0.5, 1.0);
        double drawStep = (!std::isfinite(gridStep) || gridStep <= 0.0)
                              ? 1.0
                              : std::max(gridStep, kMinSketchGridStep);
        constexpr double kMaxGridLinesPerAxis = 200.0;
        while (halfW / drawStep > kMaxGridLinesPerAxis ||
               halfH / drawStep > kMaxGridLinesPerAxis) {
            drawStep *= 2.0;
        }
        const int stepsU = static_cast<int>(std::floor(halfW / drawStep));
        const int stepsV = static_cast<int>(std::floor(halfH / drawStep));
        auto* coords = new SoCoordinate3;
        auto* lines = new SoLineSet;
        const int lineCount = (stepsU * 2 + 1) + (stepsV * 2 + 1);
        coords->point.setNum(lineCount * 2);
        lines->numVertices.setNum(lineCount);
        int vertex = 0;
        int line = 0;
        for (int i = -stepsU; i <= stepsU; ++i) {
            coords->point.set1Value(vertex++, planePoint(plane, i * drawStep, -halfH));
            coords->point.set1Value(vertex++, planePoint(plane, i * drawStep, halfH));
            lines->numVertices.set1Value(line++, 2);
        }
        for (int i = -stepsV; i <= stepsV; ++i) {
            coords->point.set1Value(vertex++, planePoint(plane, -halfW, i * drawStep));
            coords->point.set1Value(vertex++, planePoint(plane, halfW, i * drawStep));
            lines->numVertices.set1Value(line++, 2);
        }
        grid->addChild(coords);
        grid->addChild(lines);
        node->addChild(grid);
    }

    // Center cross marking the sketch origin (stays even with the grid
    // hidden).
    {
        auto* cross = new SoSeparator;
        cross->addChild(unpickableStyle());

        auto* lightModel = new SoLightModel;
        lightModel->model = SoLightModel::BASE_COLOR;
        cross->addChild(lightModel);

        auto* color = new SoBaseColor;
        color->rgb = SbColor(0.42f, 0.48f, 0.62f);
        cross->addChild(color);

        auto* coords = new SoCoordinate3;
        coords->point.set1Value(0, planePoint(plane, -0.18, 0.0));
        coords->point.set1Value(1, planePoint(plane, 0.18, 0.0));
        coords->point.set1Value(2, planePoint(plane, 0.0, -0.18));
        coords->point.set1Value(3, planePoint(plane, 0.0, 0.18));
        cross->addChild(coords);

        auto* lines = new SoLineSet;
        lines->numVertices.set1Value(0, 2);
        lines->numVertices.set1Value(1, 2);
        cross->addChild(lines);
        node->addChild(cross);
    }

    // U/V axes + labels (unpickable so they never swallow tool clicks).
    {
        auto* axes = new SoSeparator;
        axes->addChild(unpickableStyle());

        auto* lightModel = new SoLightModel;
        lightModel->model = SoLightModel::BASE_COLOR;
        axes->addChild(lightModel);

        auto* style = new SoDrawStyle;
        style->lineWidth = 2.0f;
        axes->addChild(style);

        const struct {
            SbColor color;
            double endU;
            double endV;
            const char* label;
        } axisDefs[] = {
            {SbColor(0.95f, 0.45f, 0.25f), 3.0, 0.0, "U"},
            {SbColor(0.35f, 0.85f, 0.45f), 0.0, 3.0, "V"},
        };
        for (const auto& def : axisDefs) {
            auto* axis = new SoSeparator;
            auto* color = new SoBaseColor;
            color->rgb = def.color;
            axis->addChild(color);

            auto* coords = new SoCoordinate3;
            coords->point.set1Value(0, planePoint(plane, 0.0, 0.0));
            coords->point.set1Value(1, planePoint(plane, def.endU, def.endV));
            axis->addChild(coords);

            auto* line = new SoLineSet;
            line->numVertices.set1Value(0, 2);
            axis->addChild(line);

            auto* offset = new SoTranslation;
            offset->translation = planePoint(plane, def.endU * 1.07, def.endV * 1.07);
            axis->addChild(offset);

            auto* text = new SoText2;
            text->string = def.label;
            axis->addChild(text);

            axes->addChild(axis);
        }
        node->addChild(axes);
    }

    // The dedicated sketch plane layer renders after bodies/work planes
    // and before the transient root, so cursor/preview stay on top.
    sketchPlaneRoot_->addChild(node);
    sketchPlaneNode_ = node;
}

void SceneGraph::hideSketchPlane() {
    if (sketchPlaneNode_) {
        sketchPlaneRoot_->removeChild(sketchPlaneNode_);
        sketchPlaneNode_ = nullptr;
    }
    hideSketchCursor();
    hideSketchAnchor();
    clearSketchPreview();
}

// --- Transient sketch input visuals ----------------------------------------

SoSeparator* SceneGraph::ensureTransientPolyline(SoSeparator*& node, SoCoordinate3*& coords,
                                                 SoLineSet*& lines, const SbColor& color,
                                                 float lineWidth) {
    if (node) {
        return node;
    }
    node = new SoSeparator;

    auto* lightModel = new SoLightModel;
    lightModel->model = SoLightModel::BASE_COLOR;
    node->addChild(lightModel);

    auto* baseColor = new SoBaseColor;
    baseColor->rgb = color;
    node->addChild(baseColor);

    auto* style = new SoDrawStyle;
    style->lineWidth = lineWidth;
    node->addChild(style);

    coords = new SoCoordinate3;
    coords->point.setNum(0);
    node->addChild(coords);

    lines = new SoLineSet;
    lines->numVertices.setNum(0);
    node->addChild(lines);

    sketchTransientRoot_->addChild(node);
    return node;
}

void SceneGraph::showSketchCursor(const SketchPoint2D& point, const SketchReference& reference) {
    ensureTransientPolyline(sketchCursorNode_, sketchCursorCoords_, sketchCursorLines_,
                            kSketchCursorColor, 1.5f);
    const double u = point.u;
    const double v = point.v;
    // Crosshair plus a small square marking the exact (snapped) point.
    sketchCursorCoords_->point.setNum(9);
    sketchCursorCoords_->point.set1Value(0, transientPoint(reference, u - kCursorCrossHalf, v));
    sketchCursorCoords_->point.set1Value(1, transientPoint(reference, u + kCursorCrossHalf, v));
    sketchCursorCoords_->point.set1Value(2, transientPoint(reference, u, v - kCursorCrossHalf));
    sketchCursorCoords_->point.set1Value(3, transientPoint(reference, u, v + kCursorCrossHalf));
    sketchCursorCoords_->point.set1Value(
        4, transientPoint(reference, u - kCursorBoxHalf, v - kCursorBoxHalf));
    sketchCursorCoords_->point.set1Value(
        5, transientPoint(reference, u + kCursorBoxHalf, v - kCursorBoxHalf));
    sketchCursorCoords_->point.set1Value(
        6, transientPoint(reference, u + kCursorBoxHalf, v + kCursorBoxHalf));
    sketchCursorCoords_->point.set1Value(
        7, transientPoint(reference, u - kCursorBoxHalf, v + kCursorBoxHalf));
    sketchCursorCoords_->point.set1Value(
        8, transientPoint(reference, u - kCursorBoxHalf, v - kCursorBoxHalf));
    sketchCursorLines_->numVertices.setNum(3);
    sketchCursorLines_->numVertices.set1Value(0, 2);
    sketchCursorLines_->numVertices.set1Value(1, 2);
    sketchCursorLines_->numVertices.set1Value(2, 5);
}

void SceneGraph::updateSketchCursor(const SketchPoint2D& point,
                                    const SketchReference& reference) {
    showSketchCursor(point, reference);
}

void SceneGraph::hideSketchCursor() {
    if (sketchCursorNode_) {
        sketchTransientRoot_->removeChild(sketchCursorNode_);
        sketchCursorNode_ = nullptr;
        sketchCursorCoords_ = nullptr;
        sketchCursorLines_ = nullptr;
    }
}

void SceneGraph::showSketchAnchor(const SketchPoint2D& point, const SketchReference& reference) {
    ensureTransientPolyline(sketchAnchorNode_, sketchAnchorCoords_, sketchAnchorLines_,
                            kSketchAnchorColor, 2.0f);
    const double u = point.u;
    const double v = point.v;
    // Diamond marker around the locked first point.
    sketchAnchorCoords_->point.setNum(5);
    sketchAnchorCoords_->point.set1Value(0, transientPoint(reference, u - kAnchorHalf, v));
    sketchAnchorCoords_->point.set1Value(1, transientPoint(reference, u, v + kAnchorHalf));
    sketchAnchorCoords_->point.set1Value(2, transientPoint(reference, u + kAnchorHalf, v));
    sketchAnchorCoords_->point.set1Value(3, transientPoint(reference, u, v - kAnchorHalf));
    sketchAnchorCoords_->point.set1Value(4, transientPoint(reference, u - kAnchorHalf, v));
    sketchAnchorLines_->numVertices.setNum(1);
    sketchAnchorLines_->numVertices.set1Value(0, 5);
}

void SceneGraph::hideSketchAnchor() {
    if (sketchAnchorNode_) {
        sketchTransientRoot_->removeChild(sketchAnchorNode_);
        sketchAnchorNode_ = nullptr;
        sketchAnchorCoords_ = nullptr;
        sketchAnchorLines_ = nullptr;
    }
}

void SceneGraph::updateLinePreview(const SketchPoint2D& start, const SketchPoint2D& end,
                                   const SketchReference& reference) {
    ensureTransientPolyline(sketchPreviewNode_, sketchPreviewCoords_, sketchPreviewLines_,
                            kSketchPreviewColor, 2.0f);
    sketchPreviewCoords_->point.setNum(2);
    sketchPreviewCoords_->point.set1Value(0, transientPoint(reference, start.u, start.v));
    sketchPreviewCoords_->point.set1Value(1, transientPoint(reference, end.u, end.v));
    sketchPreviewLines_->numVertices.setNum(1);
    sketchPreviewLines_->numVertices.set1Value(0, 2);
}

void SceneGraph::updateRectanglePreview(const SketchPoint2D& first, const SketchPoint2D& second,
                                        const SketchReference& reference) {
    ensureTransientPolyline(sketchPreviewNode_, sketchPreviewCoords_, sketchPreviewLines_,
                            kSketchPreviewColor, 2.0f);
    sketchPreviewCoords_->point.setNum(5);
    sketchPreviewCoords_->point.set1Value(0, transientPoint(reference, first.u, first.v));
    sketchPreviewCoords_->point.set1Value(1, transientPoint(reference, second.u, first.v));
    sketchPreviewCoords_->point.set1Value(2, transientPoint(reference, second.u, second.v));
    sketchPreviewCoords_->point.set1Value(3, transientPoint(reference, first.u, second.v));
    sketchPreviewCoords_->point.set1Value(4, transientPoint(reference, first.u, first.v));
    sketchPreviewLines_->numVertices.setNum(1);
    sketchPreviewLines_->numVertices.set1Value(0, 5);
}

void SceneGraph::updateCirclePreview(const SketchPoint2D& center, const SketchPoint2D& radiusPoint,
                                     const SketchReference& reference) {
    ensureTransientPolyline(sketchPreviewNode_, sketchPreviewCoords_, sketchPreviewLines_,
                            kSketchPreviewColor, 2.0f);
    const double radius = std::hypot(radiusPoint.u - center.u, radiusPoint.v - center.v);
    // Circle loop plus the radius rubber line to the current cursor point.
    sketchPreviewCoords_->point.setNum(kCirclePreviewSegments + 3);
    for (int i = 0; i <= kCirclePreviewSegments; ++i) {
        const double angle = 2.0 * M_PI * static_cast<double>(i) / kCirclePreviewSegments;
        sketchPreviewCoords_->point.set1Value(
            i, transientPoint(reference, center.u + radius * std::cos(angle),
                              center.v + radius * std::sin(angle)));
    }
    sketchPreviewCoords_->point.set1Value(kCirclePreviewSegments + 1,
                                          transientPoint(reference, center.u, center.v));
    sketchPreviewCoords_->point.set1Value(kCirclePreviewSegments + 2,
                                          transientPoint(reference, radiusPoint.u, radiusPoint.v));
    sketchPreviewLines_->numVertices.setNum(2);
    sketchPreviewLines_->numVertices.set1Value(0, kCirclePreviewSegments + 1);
    sketchPreviewLines_->numVertices.set1Value(1, 2);
}

void SceneGraph::clearSketchPreview() {
    if (sketchPreviewNode_) {
        sketchTransientRoot_->removeChild(sketchPreviewNode_);
        sketchPreviewNode_ = nullptr;
        sketchPreviewCoords_ = nullptr;
        sketchPreviewLines_ = nullptr;
    }
}

void SceneGraph::addOrUpdateSketchNode(const Sketch& sketch) {
    removeSketchNode(sketch.id);

    auto* node = new SoSeparator;
    const SketchReference reference = referenceForSketch(sketch);

    auto* lightModel = new SoLightModel;
    lightModel->model = SoLightModel::BASE_COLOR;
    node->addChild(lightModel);

    auto* style = new SoDrawStyle;
    style->lineWidth = 2.0f;
    node->addChild(style);

    for (const SketchEntity& entity : sketch.entities) {
        const std::vector<SbVec3f> points = sketchEntityPolyline(reference, entity);
        if (points.size() < 2) {
            continue;
        }

        auto* entityNode = new SoSeparator;

        auto* color = new SoBaseColor;
        color->rgb = kSketchEntityColor;
        entityNode->addChild(color);

        auto* coords = new SoCoordinate3;
        coords->point.setNum(static_cast<int>(points.size()));
        for (size_t i = 0; i < points.size(); ++i) {
            coords->point.set1Value(static_cast<int>(i), points[i]);
        }
        entityNode->addChild(coords);

        auto* line = new SoLineSet;
        line->numVertices.set1Value(0, static_cast<int>(points.size()));
        entityNode->addChild(line);

        node->addChild(entityNode);
        nodeToSketchEntity_[entityNode] = {sketch.id, entity.id};
        entityColors_[sketch.id + "\n" + entity.id] = color;
    }

    sketchesRoot_->addChild(node);
    sketchNodes_[sketch.id] = node;
}

void SceneGraph::removeSketchNode(const std::string& sketchId) {
    auto it = sketchNodes_.find(sketchId);
    if (it == sketchNodes_.end()) {
        return;
    }
    for (auto entityIt = nodeToSketchEntity_.begin(); entityIt != nodeToSketchEntity_.end();) {
        if (entityIt->second.first == sketchId) {
            entityIt = nodeToSketchEntity_.erase(entityIt);
        } else {
            ++entityIt;
        }
    }
    for (auto colorIt = entityColors_.begin(); colorIt != entityColors_.end();) {
        if (colorIt->first.rfind(sketchId + "\n", 0) == 0) {
            colorIt = entityColors_.erase(colorIt);
        } else {
            ++colorIt;
        }
    }
    sketchesRoot_->removeChild(it->second);
    sketchNodes_.erase(it);
}

void SceneGraph::clearSketchNodes() {
    sketchesRoot_->removeAllChildren();
    sketchNodes_.clear();
    nodeToSketchEntity_.clear();
    entityColors_.clear();
}

void SceneGraph::setSketchEntityHighlighted(const std::string& sketchId,
                                            const std::string& entityId, bool highlighted) {
    auto it = entityColors_.find(sketchId + "\n" + entityId);
    if (it == entityColors_.end()) {
        return;
    }
    it->second->rgb = highlighted ? kSketchEntityHighlight : kSketchEntityColor;
}

// --- Sketch profiles ---------------------------------------------------------

namespace {

SbVec3f liftedSketchPoint(const cadnext::SketchReference& reference,
                          const cadnext::SketchPoint2D& point, double lift) {
    Vector3 world = cadnext::sketchPointToWorld(point, reference);
    world.x += reference.normal.x * lift;
    world.y += reference.normal.y * lift;
    world.z += reference.normal.z * lift;
    return toSb(world);
}

} // namespace

void SceneGraph::showSketchProfiles(const Sketch& sketch,
                                    const std::vector<SketchProfile>& profiles) {
    clearSketchProfiles();

    const SketchReference reference = referenceForSketch(sketch);
    // The Sketch2D camera sits on the planeNormalViewSide of the plane:
    // the fill goes slightly behind the plane (entity lines keep winning
    // overlapping picks) and the outline slightly in front (a selected
    // outline reads above the entity lines).
    const double side =
        planeNormalViewSide(reference.uAxis, reference.vAxis, reference.normal);
    const double fillLift = -side * kTransientLift;
    const double outlineLift = side * kTransientLift;

    for (const SketchProfile& profile : profiles) {
        if (!profile.isValid || profile.outerLoop.size() < 3) {
            continue;
        }
        const std::vector<unsigned int> triangles = triangulatePolygon(profile.outerLoop);
        if (triangles.empty()) {
            continue;
        }
        const int pointCount = static_cast<int>(profile.outerLoop.size());

        auto* node = new SoSeparator;

        // Faint fill; pickable — it is the click target for "select the
        // profile by clicking inside it".
        auto* fill = new SoSeparator;
        fill->addChild(noDepthWrite());
        auto* hints = new SoShapeHints;
        hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
        hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
        fill->addChild(hints);

        auto* material = new SoMaterial;
        fill->addChild(material);

        auto* fillCoords = new SoCoordinate3;
        fillCoords->point.setNum(pointCount);
        for (int i = 0; i < pointCount; ++i) {
            fillCoords->point.set1Value(
                i, liftedSketchPoint(reference, profile.outerLoop[i], fillLift));
        }
        fill->addChild(fillCoords);

        auto* faces = new SoIndexedFaceSet;
        faces->coordIndex.setNum(static_cast<int>(triangles.size() / 3) * 4);
        int index = 0;
        for (size_t t = 0; t + 2 < triangles.size(); t += 3) {
            faces->coordIndex.set1Value(index++, static_cast<int>(triangles[t]));
            faces->coordIndex.set1Value(index++, static_cast<int>(triangles[t + 1]));
            faces->coordIndex.set1Value(index++, static_cast<int>(triangles[t + 2]));
            faces->coordIndex.set1Value(index++, -1);
        }
        fill->addChild(faces);
        node->addChild(fill);

        // Outline loop (unpickable; brightens when selected).
        auto* outline = new SoSeparator;
        outline->addChild(unpickableStyle());
        auto* lightModel = new SoLightModel;
        lightModel->model = SoLightModel::BASE_COLOR;
        outline->addChild(lightModel);

        auto* outlineColor = new SoBaseColor;
        outline->addChild(outlineColor);

        auto* outlineStyle = new SoDrawStyle;
        outline->addChild(outlineStyle);

        auto* outlineCoords = new SoCoordinate3;
        outlineCoords->point.setNum(pointCount + 1);
        for (int i = 0; i <= pointCount; ++i) {
            outlineCoords->point.set1Value(
                i, liftedSketchPoint(reference, profile.outerLoop[i % pointCount],
                                     outlineLift));
        }
        outline->addChild(outlineCoords);

        auto* outlineLines = new SoLineSet;
        outlineLines->numVertices.set1Value(0, pointCount + 1);
        outline->addChild(outlineLines);
        node->addChild(outline);

        sketchProfilesRoot_->addChild(node);
        nodeToProfileId_[node] = profile.id;
        profileFillMaterials_[profile.id] = material;
        profileOutlineColors_[profile.id] = outlineColor;
        profileOutlineStyles_[profile.id] = outlineStyle;
        updateProfileVisual(profile.id);
    }
}

void SceneGraph::clearSketchProfiles() {
    // The selected profile id survives a refresh: re-detected profiles
    // with the same id pick the highlight back up in updateProfileVisual.
    sketchProfilesRoot_->removeAllChildren();
    nodeToProfileId_.clear();
    profileFillMaterials_.clear();
    profileOutlineColors_.clear();
    profileOutlineStyles_.clear();
}

void SceneGraph::setSelectedProfile(const std::string& profileId) {
    if (selectedProfileId_ == profileId) {
        return;
    }
    const std::string old = selectedProfileId_;
    selectedProfileId_ = profileId;
    updateProfileVisual(old);
    updateProfileVisual(selectedProfileId_);
}

void SceneGraph::updateProfileVisual(const std::string& profileId) {
    if (profileId.empty()) {
        return;
    }
    const bool selected = profileId == selectedProfileId_;
    if (auto it = profileFillMaterials_.find(profileId); it != profileFillMaterials_.end()) {
        it->second->diffuseColor = selected ? kProfileSelectedFill : kProfileFill;
        it->second->transparency =
            selected ? kProfileSelectedFillTransparency : kProfileFillTransparency;
        it->second->emissiveColor = selected ? SbColor(0.25f, 0.14f, 0.03f)
                                             : SbColor(0.0f, 0.0f, 0.0f);
    }
    if (auto it = profileOutlineColors_.find(profileId); it != profileOutlineColors_.end()) {
        it->second->rgb = selected ? kProfileSelectedOutline : kProfileOutline;
    }
    if (auto it = profileOutlineStyles_.find(profileId); it != profileOutlineStyles_.end()) {
        it->second->lineWidth = selected ? 3.0f : 1.0f;
    }
}

// --- Extrude preview ----------------------------------------------------------

void SceneGraph::showExtrudePreview(const kernel::TriangleMesh& mesh) {
    hideExtrudePreview();
    if (mesh.isEmpty()) {
        return;
    }
    auto* node = new SoSeparator;
    node->addChild(unpickableStyle());

    auto* material = new SoMaterial;
    material->diffuseColor = kExtrudePreviewColor;
    material->transparency = kExtrudePreviewTransparency;
    node->addChild(material);

    addMeshShape(node, mesh);
    extrudePreviewRoot_->addChild(node);
    extrudePreviewNode_ = node;
}

void SceneGraph::hideExtrudePreview() {
    if (extrudePreviewNode_) {
        extrudePreviewRoot_->removeChild(extrudePreviewNode_);
        extrudePreviewNode_ = nullptr;
    }
}

ViewportPickTarget SceneGraph::pickTargetForPath(const SoPath* path) const {
    ViewportPickTarget target;
    if (!path) {
        return target;
    }
    for (int i = path->getLength() - 1; i >= 0; --i) {
        const auto* node = static_cast<const SoSeparator*>(path->getNode(i));
        auto entityIt = nodeToSketchEntity_.find(node);
        if (entityIt != nodeToSketchEntity_.end()) {
            target.sketchId = entityIt->second.first;
            target.entityId = entityIt->second.second;
            return target;
        }
        auto profileIt = nodeToProfileId_.find(node);
        if (profileIt != nodeToProfileId_.end()) {
            target.profileId = profileIt->second;
            return target;
        }
        auto planeIt = nodeToWorkPlaneId_.find(node);
        if (planeIt != nodeToWorkPlaneId_.end()) {
            target.workPlaneId = planeIt->second;
            return target;
        }
        auto objectIt = nodeToObjectId_.find(node);
        if (objectIt != nodeToObjectId_.end()) {
            target.objectId = objectIt->second;
            return target;
        }
    }
    return target;
}

} // namespace cadnext::viewer
