#include "cadnext/viewer/ModalFieldScene.hpp"

#include <Inventor/nodes/SoCamera.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoMaterialBinding.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>

#include <algorithm>
#include <cmath>
#include <utility>

namespace cadnext::viewer {

ModalFieldScene::ModalFieldScene(fea::ModalFieldFile field) : field_(std::move(field)) {
    root_ = new SoSeparator;
    root_->ref();

    // Same lighting and material rules as StructuralFieldScene: fixed fill lights, colour bound
    // per vertex through the diffuse channel only, black ambient and specular so shading changes
    // brightness and never hue.
    auto* hints = new SoShapeHints;
    hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    hints->shapeType = SoShapeHints::SOLID;
    hints->creaseAngle = 0.6f;
    root_->addChild(hints);
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

    updateCoordinates();
    updateColors();
}

ModalFieldScene::~ModalFieldScene() {
    root_->unref();
}

void ModalFieldScene::setMode(int index) {
    if (index < 0 || index >= static_cast<int>(field_.modes.size())) return;
    mode_ = index;
    updateCoordinates();
    updateColors();
}

void ModalFieldScene::setAmplitude(double multiplier) {
    amplitude_ = std::max(0.0, multiplier);
    updateCoordinates();
}

void ModalFieldScene::setPhase(double phase) {
    phase_ = phase;
    updateCoordinates();
}

void ModalFieldScene::updateCoordinates() {
    const int count = static_cast<int>(field_.nodes.size());
    const double scale = field_.displayAmplitudeM * amplitude_ * std::sin(phase_);
    const auto& shape = field_.modes[mode_].shape;
    coordinates_->point.setNum(count);
    SbVec3f* points = coordinates_->point.startEditing();
    for (int n = 0; n < count; ++n) {
        const fea::Vec3 p = field_.nodes[n] + shape[n] * scale;
        points[n].setValue(static_cast<float>(p.x), static_cast<float>(p.y), static_cast<float>(p.z));
    }
    coordinates_->point.finishEditing();
}

void ModalFieldScene::updateColors() {
    const int count = static_cast<int>(field_.nodes.size());
    const auto& shape = field_.modes[mode_].shape;
    material_->diffuseColor.setNum(count);
    SbColor* diffuse = material_->diffuseColor.startEditing();
    for (int n = 0; n < count; ++n) {
        const auto c = fea::rampColor(field_.colorStops, fea::length(shape[n]));
        diffuse[n].setValue(c[0], c[1], c[2]);
    }
    material_->diffuseColor.finishEditing();
}

void ModalFieldScene::frame(SoCamera& camera, double aspectRatio, double margin) const {
    if (field_.nodes.empty()) return;
    // Envelope of the whole oscillation: the part at both extremes.
    const double scale = field_.displayAmplitudeM * amplitude_;
    const auto& shape = field_.modes[mode_].shape;
    fea::Vec3 low = field_.nodes.front();
    fea::Vec3 high = low;
    for (std::size_t n = 0; n < field_.nodes.size(); ++n) {
        for (double sign : {-1.0, 1.0}) {
            const fea::Vec3 p = field_.nodes[n] + shape[n] * (sign * scale);
            low = {std::min(low.x, p.x), std::min(low.y, p.y), std::min(low.z, p.z)};
            high = {std::max(high.x, p.x), std::max(high.y, p.y), std::max(high.z, p.z)};
        }
    }
    const fea::Vec3 center = (low + high) * 0.5;
    const double radius = std::max(fea::length(high - low) * 0.5, 1e-9);
    double halfAngle = 0.39;
    if (camera.isOfType(SoPerspectiveCamera::getClassTypeId())) {
        halfAngle = static_cast<SoPerspectiveCamera&>(camera).heightAngle.getValue() * 0.5;
    }
    const double horizontalHalf = std::atan(std::tan(halfAngle) * std::max(aspectRatio, 1e-3));
    const double distance = radius * margin / std::sin(std::min(halfAngle, horizontalHalf));
    SbVec3f direction;
    camera.orientation.getValue().multVec(SbVec3f(0.0f, 0.0f, -1.0f), direction);
    const SbVec3f target(static_cast<float>(center.x), static_cast<float>(center.y), static_cast<float>(center.z));
    camera.position = target - direction * static_cast<float>(distance);
    camera.focalDistance = static_cast<float>(distance);
    camera.nearDistance = static_cast<float>(std::max(distance - radius * 2.0, distance * 0.01));
    camera.farDistance = static_cast<float>(distance + radius * 2.0);
}

} // namespace cadnext::viewer
