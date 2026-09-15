#include "cadnext/viewer/StructuralFieldScene.hpp"

#include <Inventor/SbMatrix.h>
#include <Inventor/nodes/SoBaseColor.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoDepthBuffer.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoDrawStyle.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoMarkerSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoMaterialBinding.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <Inventor/nodes/SoTranslation.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace cadnext::viewer {

StructuralFieldScene::StructuralFieldScene(fea::StructuralFieldFile field) : field_(std::move(field)) {
    deformationScale_ = field_.deformationAutoScale;

    double best = std::numeric_limits<double>::infinity();
    for (int n = 0; n < static_cast<int>(field_.nodes.size()); ++n) {
        const double d = fea::length(field_.nodes[n] - field_.criticalPoint);
        if (d < best) {
            best = d;
            criticalNode_ = n;
        }
    }

    root_ = new SoSeparator;
    root_->ref();

    // Triangles are outward-oriented (tetrahedron faces seen from outside); a crease angle keeps
    // CAD edges sharp instead of smoothing shading across them.
    auto* hints = new SoShapeHints;
    hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    hints->shapeType = SoShapeHints::SOLID;
    hints->creaseAngle = 0.6f;
    root_->addChild(hints);

    // Fixed fill lights (Z-up world): from above and from two opposite sides, so no face of a
    // part is left unlit whatever the camera does.
    for (const auto& [direction, intensity] : {std::pair{SbVec3f(0.0f, 0.0f, -1.0f), 0.25f},
                                                std::pair{SbVec3f(-0.7f, -0.5f, -0.3f), 0.2f},
                                                std::pair{SbVec3f(0.7f, 0.5f, -0.3f), 0.2f}}) {
        auto* light = new SoDirectionalLight;
        light->direction = direction;
        light->intensity = intensity;
        root_->addChild(light);
    }

    coordinates_ = new SoCoordinate3;
    root_->addChild(coordinates_);

    material_ = new SoMaterial;
    // Only the diffuse colour is bound per vertex — Coin takes ambient, specular and emissive
    // from the first entry for the whole shape. A non-black ambient therefore tinted every
    // vertex with node 0's colour (seen in the first snapshot: the zero-stress end of a beam
    // came out magenta instead of viridis purple). Black ambient and specular keep the drawn
    // colour a pure multiple of the scale colour: shading changes brightness, never hue.
    material_->ambientColor.setValue(0.0f, 0.0f, 0.0f);
    material_->specularColor.setValue(0.0f, 0.0f, 0.0f);
    root_->addChild(material_);
    auto* binding = new SoMaterialBinding;
    binding->value = SoMaterialBinding::PER_VERTEX_INDEXED;
    root_->addChild(binding);

    auto* faces = new SoIndexedFaceSet;
    faces->coordIndex.setNum(static_cast<int>(field_.triangles.size() * 4));
    int* index = faces->coordIndex.startEditing();
    for (const auto& triangle : field_.triangles) {
        *index++ = triangle[0];
        *index++ = triangle[1];
        *index++ = triangle[2];
        *index++ = -1;
    }
    faces->coordIndex.finishEditing();
    root_->addChild(faces);

    // Critical point: a marker drawn over the part so it is never hidden behind a face.
    auto* marker = new SoSeparator;
    auto* noDepth = new SoDepthBuffer;
    noDepth->test = FALSE;
    marker->addChild(noDepth);
    markerPosition_ = new SoTranslation;
    marker->addChild(markerPosition_);
    auto* markerColor = new SoBaseColor;
    markerColor->rgb.setValue(1.0f, 1.0f, 1.0f);
    marker->addChild(markerColor);
    auto* markerPoint = new SoCoordinate3;
    markerPoint->point.setValue(0.0f, 0.0f, 0.0f);
    marker->addChild(markerPoint);
    auto* markers = new SoMarkerSet;
    markers->markerIndex = SoMarkerSet::CIRCLE_LINE_9_9;
    marker->addChild(markers);
    root_->addChild(marker);

    updateCoordinates();
    updateColors();
}

StructuralFieldScene::~StructuralFieldScene() {
    root_->unref();
}

void StructuralFieldScene::setQuantity(FieldQuantity quantity) {
    quantity_ = quantity;
    updateColors();
}

void StructuralFieldScene::setDeformationScale(double scale) {
    deformationScale_ = std::max(0.0, scale);
    updateCoordinates();
}

void StructuralFieldScene::updateCoordinates() {
    const int count = static_cast<int>(field_.nodes.size());
    coordinates_->point.setNum(count);
    SbVec3f* points = coordinates_->point.startEditing();
    for (int n = 0; n < count; ++n) {
        const fea::Vec3 p = field_.nodes[n] + field_.displacement[n] * deformationScale_;
        points[n].setValue(static_cast<float>(p.x), static_cast<float>(p.y), static_cast<float>(p.z));
    }
    coordinates_->point.finishEditing();
    const fea::Vec3 critical = field_.nodes[criticalNode_] + field_.displacement[criticalNode_] * deformationScale_;
    markerPosition_->translation.setValue(static_cast<float>(critical.x), static_cast<float>(critical.y),
                                          static_cast<float>(critical.z));
}

void StructuralFieldScene::updateColors() {
    const int count = static_cast<int>(field_.nodes.size());
    double maxStress = field_.maxVonMisesPa();
    double maxDisplacement = 0.0;
    for (const auto& d : field_.displacement) maxDisplacement = std::max(maxDisplacement, fea::length(d));

    material_->diffuseColor.setNum(count);
    SbColor* diffuse = material_->diffuseColor.startEditing();
    for (int n = 0; n < count; ++n) {
        std::array<float, 3> c{};
        switch (quantity_) {
        case FieldQuantity::Utilization:
            c = field_.utilizationColor(n);
            break;
        case FieldQuantity::VonMises:
            c = field_.rampColor(maxStress > 0.0 ? field_.vonMisesPa[n] / maxStress : 0.0);
            break;
        case FieldQuantity::Displacement:
            c = field_.rampColor(maxDisplacement > 0.0 ? fea::length(field_.displacement[n]) / maxDisplacement : 0.0);
            break;
        }
        diffuse[n].setValue(c[0], c[1], c[2]);
    }
    material_->diffuseColor.finishEditing();
}

void StructuralFieldScene::frame(SoCamera& camera, double aspectRatio, double margin) const {
    if (field_.nodes.empty()) return;
    fea::Vec3 low = field_.nodes.front() + field_.displacement.front() * deformationScale_;
    fea::Vec3 high = low;
    for (std::size_t n = 0; n < field_.nodes.size(); ++n) {
        const fea::Vec3 p = field_.nodes[n] + field_.displacement[n] * deformationScale_;
        low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
        high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
    }
    const fea::Vec3 center = (low + high) * 0.5;
    const double radius = std::max(fea::length(high - low) * 0.5, 1e-9);
    double halfAngle = 0.39; // 45° default
    if (camera.isOfType(SoPerspectiveCamera::getClassTypeId())) {
        halfAngle = static_cast<SoPerspectiveCamera&>(camera).heightAngle.getValue() * 0.5;
    }
    const double verticalHalf = halfAngle;
    const double horizontalHalf = std::atan(std::tan(verticalHalf) * std::max(aspectRatio, 1e-3));
    const double distance = radius * margin / std::sin(std::min(verticalHalf, horizontalHalf));
    SbVec3f direction;
    camera.orientation.getValue().multVec(SbVec3f(0.0f, 0.0f, -1.0f), direction);
    const SbVec3f target(static_cast<float>(center.x), static_cast<float>(center.y), static_cast<float>(center.z));
    camera.position = target - direction * static_cast<float>(distance);
    camera.focalDistance = static_cast<float>(distance);
    camera.nearDistance = static_cast<float>(std::max(distance - radius * 2.0, distance * 0.01));
    camera.farDistance = static_cast<float>(distance + radius * 2.0);
}

void applyAxonometricZUpOrientation(SoCamera& camera) {
    SbVec3f direction(-1.0f, -1.2f, -0.8f);
    direction.normalize();
    SbVec3f right = direction.cross(SbVec3f(0.0f, 0.0f, 1.0f));
    right.normalize();
    const SbVec3f up = right.cross(direction);
    const SbVec3f back = -direction;
    // Coin matrices act on row vectors: rows are where the camera's local x, y, z axes point.
    const SbMatrix basis(right[0], right[1], right[2], 0.0f,
                         up[0], up[1], up[2], 0.0f,
                         back[0], back[1], back[2], 0.0f,
                         0.0f, 0.0f, 0.0f, 1.0f);
    camera.orientation = SbRotation(basis);
}

} // namespace cadnext::viewer
