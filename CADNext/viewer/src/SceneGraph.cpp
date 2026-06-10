#include "cadnext/viewer/SceneGraph.hpp"

#include <cmath>
#include <vector>

#include <Inventor/SoPath.h>
#include <Inventor/nodes/SoBaseColor.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoCube.h>
#include <Inventor/nodes/SoCylinder.h>
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

constexpr double kDegreesToRadians = M_PI / 180.0;

SoPickStyle* unpickableStyle() {
    auto* style = new SoPickStyle;
    style->style = SoPickStyle::UNPICKABLE;
    return style;
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
        // Placeholder reference plane: a semi-transparent quad in XY,
        // sized by width (X) and height (Y).
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

// Converts sketch-local u/v to world coordinates. The canonical planes
// pass through the origin, so this is pure component placement:
// XY: (u, v, 0) | XZ: (u, 0, v) | YZ: (0, u, v).
SbVec3f sketchUVToWorld(cadnext::SketchPlane plane, double u, double v) {
    switch (plane) {
    case cadnext::SketchPlane::XY:
        return {static_cast<float>(u), static_cast<float>(v), 0.0f};
    case cadnext::SketchPlane::XZ:
        return {static_cast<float>(u), 0.0f, static_cast<float>(v)};
    case cadnext::SketchPlane::YZ:
        return {0.0f, static_cast<float>(u), static_cast<float>(v)};
    }
    return {static_cast<float>(u), static_cast<float>(v), 0.0f};
}

std::vector<SbVec3f> sketchEntityPolyline(cadnext::SketchPlane plane,
                                          const cadnext::SketchEntity& entity) {
    std::vector<SbVec3f> points;
    switch (entity.type) {
    case cadnext::SketchEntityType::Line:
        points.push_back(sketchUVToWorld(plane, entity.line.start.u, entity.line.start.v));
        points.push_back(sketchUVToWorld(plane, entity.line.end.u, entity.line.end.v));
        break;
    case cadnext::SketchEntityType::Rectangle: {
        const auto& rect = entity.rectangle;
        const double u0 = rect.origin.u;
        const double v0 = rect.origin.v;
        const double u1 = rect.origin.u + rect.width;
        const double v1 = rect.origin.v + rect.height;
        points.push_back(sketchUVToWorld(plane, u0, v0));
        points.push_back(sketchUVToWorld(plane, u1, v0));
        points.push_back(sketchUVToWorld(plane, u1, v1));
        points.push_back(sketchUVToWorld(plane, u0, v1));
        points.push_back(sketchUVToWorld(plane, u0, v0));
        break;
    }
    case cadnext::SketchEntityType::Circle: {
        constexpr int kSegments = 48;
        const auto& circle = entity.circle;
        for (int i = 0; i <= kSegments; ++i) {
            const double angle = 2.0 * M_PI * static_cast<double>(i) / kSegments;
            points.push_back(sketchUVToWorld(plane,
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

    root_->addChild(buildGrid());
    root_->addChild(buildAxes());

    objectsRoot_ = new SoSeparator;
    root_->addChild(objectsRoot_);

    sketchesRoot_ = new SoSeparator;
    root_->addChild(sketchesRoot_);
}

SceneGraph::~SceneGraph() {
    root_->unref();
}

SoSeparator* SceneGraph::root() const { return root_; }

SoSeparator* SceneGraph::objectsRoot() const { return objectsRoot_; }

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
        material->transparency = 0.6f;
    }
    node->addChild(material);

    addPrimitiveShape(node, object);

    objectsRoot_->addChild(node);
    objectNodes_[object.id] = node;
    objectTransforms_[object.id] = transform;
    objectMaterials_[object.id] = material;
    objectBaseColors_[object.id] = material->diffuseColor[0];
    nodeToObjectId_[node] = object.id;
}

void SceneGraph::removeObjectNode(const std::string& objectId) {
    auto it = objectNodes_.find(objectId);
    if (it == objectNodes_.end()) {
        return;
    }
    nodeToObjectId_.erase(it->second);
    objectsRoot_->removeChild(it->second);
    objectNodes_.erase(it);
    objectTransforms_.erase(objectId);
    objectMaterials_.erase(objectId);
    objectBaseColors_.erase(objectId);
}

void SceneGraph::clearObjectNodes() {
    objectsRoot_->removeAllChildren();
    objectNodes_.clear();
    objectTransforms_.clear();
    objectMaterials_.clear();
    objectBaseColors_.clear();
    nodeToObjectId_.clear();
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

void SceneGraph::showSketchPlane(SketchPlane plane) {
    hideSketchPlane();

    auto* node = new SoSeparator;

    // Translucent plane fill. Intentionally pickable: sketch tools place
    // points by ray-picking this quad and reading the world hit position.
    {
        auto* fill = new SoSeparator;
        auto* hints = new SoShapeHints;
        hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
        hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
        fill->addChild(hints);

        auto* material = new SoMaterial;
        material->diffuseColor = SbColor(0.30f, 0.45f, 0.80f);
        material->transparency = 0.85f;
        fill->addChild(material);

        constexpr float kHalf = 10.0f;
        auto* coords = new SoCoordinate3;
        coords->point.set1Value(0, sketchUVToWorld(plane, -kHalf, -kHalf));
        coords->point.set1Value(1, sketchUVToWorld(plane, kHalf, -kHalf));
        coords->point.set1Value(2, sketchUVToWorld(plane, kHalf, kHalf));
        coords->point.set1Value(3, sketchUVToWorld(plane, -kHalf, kHalf));
        fill->addChild(coords);

        auto* face = new SoFaceSet;
        face->numVertices.set1Value(0, 4);
        fill->addChild(face);
        node->addChild(fill);
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
            coords->point.set1Value(0, sketchUVToWorld(plane, 0.0, 0.0));
            coords->point.set1Value(1, sketchUVToWorld(plane, def.endU, def.endV));
            axis->addChild(coords);

            auto* line = new SoLineSet;
            line->numVertices.set1Value(0, 2);
            axis->addChild(line);

            auto* offset = new SoTranslation;
            offset->translation = sketchUVToWorld(plane, def.endU * 1.07, def.endV * 1.07);
            axis->addChild(offset);

            auto* text = new SoText2;
            text->string = def.label;
            axis->addChild(text);

            axes->addChild(axis);
        }
        node->addChild(axes);
    }

    root_->addChild(node);
    sketchPlaneNode_ = node;
}

void SceneGraph::hideSketchPlane() {
    if (sketchPlaneNode_) {
        root_->removeChild(sketchPlaneNode_);
        sketchPlaneNode_ = nullptr;
    }
}

void SceneGraph::addOrUpdateSketchNode(const Sketch& sketch) {
    removeSketchNode(sketch.id);

    auto* node = new SoSeparator;

    auto* lightModel = new SoLightModel;
    lightModel->model = SoLightModel::BASE_COLOR;
    node->addChild(lightModel);

    auto* style = new SoDrawStyle;
    style->lineWidth = 2.0f;
    node->addChild(style);

    for (const SketchEntity& entity : sketch.entities) {
        const std::vector<SbVec3f> points = sketchEntityPolyline(sketch.plane, entity);
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
        auto objectIt = nodeToObjectId_.find(node);
        if (objectIt != nodeToObjectId_.end()) {
            target.objectId = objectIt->second;
            return target;
        }
    }
    return target;
}

} // namespace cadnext::viewer
