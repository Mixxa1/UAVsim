#include "FlowScene3D.hpp"

#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoDrawStyle.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoLightModel.h>
#include <Inventor/nodes/SoLineSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoMaterialBinding.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <Inventor/nodes/SoSwitch.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <unordered_map>

namespace cadnext::gui::detail {

namespace {

struct Key {
    std::int64_t x, y, z;
    bool operator==(const Key& o) const { return x == o.x && y == o.y && z == o.z; }
};
struct KeyHash {
    std::size_t operator()(const Key& k) const {
        return std::hash<std::int64_t>()(k.x * 73856093LL ^ k.y * 19349663LL ^ k.z * 83492791LL);
    }
};
// Wall nodes are the same mesh nodes in the mesh file and in the surface field; a tenth of a micron
// is far below any cell and far above the printed precision.
Key keyOf(const std::array<double, 3>& p) {
    return {std::llround(p[0] * 1e7), std::llround(p[1] * 1e7), std::llround(p[2] * 1e7)};
}

constexpr int kArrowSides = 6;
constexpr int kMaxLinePoints = 500;

} // namespace

SbColor turbo(double t) {
    t = std::clamp(t, 0.0, 1.0);
    auto channel = [t](double c0, double c1, double c2, double c3, double c4, double c5) {
        const double value = c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * c5))));
        return static_cast<float>(std::clamp(value, 0.0, 1.0));
    };
    return SbColor(channel(0.13572138, 4.61539260, -42.66032258, 132.13108234, -152.94239396, 59.28637943),
                   channel(0.09140261, 2.19418839, 4.84296658, -14.18503333, 4.27729857, 2.82956604),
                   channel(0.10667330, 12.64194608, -60.58204836, 110.36276771, -89.90310912, 27.34824973));
}

FlowScene3D::FlowScene3D() {
    root_ = new SoSeparator;
    root_->ref();

    // Body: smooth within a face, sharp at the edges, lit from both sides (CAD solids are closed,
    // but a cut section or an open shell must not render black from inside).
    auto* body = new SoSeparator;
    // Coin lights both sides only when the vertex order is declared and the shape is not called
    // solid. Mesh wall faces point into the fluid or into the body depending on the mesher, so both
    // sides must be lit — with UNKNOWN_ORDERING half the body renders black.
    auto* hints = new SoShapeHints;
    hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    hints->shapeType = SoShapeHints::UNKNOWN_SHAPE_TYPE;
    hints->creaseAngle = 0.7f;
    body->addChild(hints);
    bodyMaterial_ = new SoMaterial;
    bodyMaterial_->diffuseColor.setValue(0.74f, 0.76f, 0.79f);
    bodyMaterial_->specularColor.setValue(0.35f, 0.35f, 0.35f);
    bodyMaterial_->shininess = 0.35f;
    body->addChild(bodyMaterial_);
    bodyBinding_ = new SoMaterialBinding;
    bodyBinding_->value = SoMaterialBinding::OVERALL;
    body->addChild(bodyBinding_);
    bodyCoordinates_ = new SoCoordinate3;
    body->addChild(bodyCoordinates_);
    bodyFaces_ = new SoIndexedFaceSet;
    body->addChild(bodyFaces_);
    root_->addChild(body);

    // Trajectories: flat colour by speed, thin.
    lineSwitch_ = new SoSwitch;
    lineSwitch_->whichChild = SO_SWITCH_ALL;
    auto* lines = new SoSeparator;
    auto* flat = new SoLightModel;
    flat->model = SoLightModel::BASE_COLOR;
    lines->addChild(flat);
    auto* style = new SoDrawStyle;
    style->lineWidth = 1.4f;
    lines->addChild(style);
    lineColours_ = new SoMaterial;
    lines->addChild(lineColours_);
    auto* lineBinding = new SoMaterialBinding;
    lineBinding->value = SoMaterialBinding::PER_VERTEX;
    lines->addChild(lineBinding);
    lineCoordinates_ = new SoCoordinate3;
    lines->addChild(lineCoordinates_);
    lineSet_ = new SoLineSet;
    lines->addChild(lineSet_);
    lineSwitch_->addChild(lines);
    auto* vortices = new SoSeparator;
    auto* vortexFlat = new SoLightModel;
    vortexFlat->model = SoLightModel::BASE_COLOR;
    vortices->addChild(vortexFlat);
    auto* vortexStyle = new SoDrawStyle;
    vortexStyle->lineWidth = 3.0f;
    vortices->addChild(vortexStyle);
    vortexColours_ = new SoMaterial;
    vortices->addChild(vortexColours_);
    auto* vortexBinding = new SoMaterialBinding;
    vortexBinding->value = SoMaterialBinding::PER_VERTEX;
    vortices->addChild(vortexBinding);
    vortexCoordinates_ = new SoCoordinate3;
    vortices->addChild(vortexCoordinates_);
    vortexSet_ = new SoLineSet;
    vortices->addChild(vortexSet_);
    lineSwitch_->addChild(vortices);
    root_->addChild(lineSwitch_);

    // Arrows: lit cones, coloured by the speed where they are.
    arrowSwitch_ = new SoSwitch;
    arrowSwitch_->whichChild = SO_SWITCH_ALL;
    auto* arrows = new SoSeparator;
    // Unlit, with the shading baked into each face's colour: GL lighting of a coloured cone mixes
    // the colour with grey on every side turned from the light, and the speed scale stops being
    // readable. A fixed light from above-front keeps the cones round.
    auto* arrowLight = new SoLightModel;
    arrowLight->model = SoLightModel::BASE_COLOR;
    arrows->addChild(arrowLight);
    arrowColours_ = new SoMaterial;
    arrows->addChild(arrowColours_);
    auto* arrowBinding = new SoMaterialBinding;
    arrowBinding->value = SoMaterialBinding::PER_FACE;
    arrows->addChild(arrowBinding);
    arrowCoordinates_ = new SoCoordinate3;
    arrows->addChild(arrowCoordinates_);
    arrowFaces_ = new SoIndexedFaceSet;
    arrows->addChild(arrowFaces_);
    arrowSwitch_->addChild(arrows);
    root_->addChild(arrowSwitch_);
}

FlowScene3D::~FlowScene3D() {
    if (root_) root_->unref();
}

void FlowScene3D::setBody(const std::vector<std::array<cfd::FlowVolume::Point, 3>>& walls) {
    std::unordered_map<Key, int32_t, KeyHash> index;
    std::vector<SbVec3f> points;
    bodySolver_.clear();
    std::vector<int32_t> faces;
    bodyMin_ = SbVec3f(1e30f, 1e30f, 1e30f);
    bodyMax_ = SbVec3f(-1e30f, -1e30f, -1e30f);
    for (const auto& triangle : walls) {
        for (const auto& corner : triangle) {
            const auto key = keyOf(corner);
            auto found = index.find(key);
            if (found == index.end()) {
                found = index.emplace(key, static_cast<int32_t>(points.size())).first;
                const auto p = display(corner);
                points.push_back(p);
                bodySolver_.push_back(corner);
                for (int k = 0; k < 3; ++k) { bodyMin_[k] = std::min(bodyMin_[k], p[k]); bodyMax_[k] = std::max(bodyMax_[k], p[k]); }
            }
            faces.push_back(found->second);
        }
        faces.push_back(-1);
    }
    bodyCoordinates_->point.setNum(0);
    bodyCoordinates_->point.setValues(0, static_cast<int>(points.size()), points.data());
    bodyFaces_->coordIndex.setNum(0);
    bodyFaces_->coordIndex.setValues(0, static_cast<int>(faces.size()), faces.data());
    bodyColours_.clear();
    setBodyColoured(bodyColoured_);
}

void FlowScene3D::setBodyValues(const std::vector<SurfaceValue>& values, double low, double high) {
    std::unordered_map<Key, double, KeyHash> byNode;
    for (const auto& v : values) byNode.emplace(keyOf(v.position), v.value);
    const auto count = bodySolver_.size();
    bodyColours_.assign(count, SbColor(0.74f, 0.76f, 0.79f));
    for (std::size_t i = 0; i < count; ++i) {
        const auto found = byNode.find(keyOf(bodySolver_[i]));
        if (found != byNode.end()) bodyColours_[i] = turbo((found->second - low) / std::max(high - low, 1e-12));
    }
    setBodyColoured(bodyColoured_);
}

void FlowScene3D::setBodyColoured(bool coloured) {
    bodyColoured_ = coloured;
    if (coloured && !bodyColours_.empty()) {
        bodyMaterial_->diffuseColor.setValues(0, static_cast<int>(bodyColours_.size()), bodyColours_.data());
        bodyBinding_->value = SoMaterialBinding::PER_VERTEX_INDEXED;
    } else {
        bodyMaterial_->diffuseColor.setNum(1);
        bodyMaterial_->diffuseColor.set1Value(0, SbColor(0.74f, 0.76f, 0.79f));
        bodyBinding_->value = SoMaterialBinding::OVERALL;
    }
}

void FlowScene3D::setTrajectories(std::vector<cfd::Trajectory> lines, double freeStream, std::size_t emphasisedFrom) {
    lines_ = std::move(lines);
    freeStream_ = freeStream > 0 ? freeStream : 1.0;
    // Colour range: 2nd…98th percentile of the speeds on the lines, so a single point at a stagnation
    // or a sharp edge does not take the whole scale.
    std::vector<double> speeds;
    double streamwise = 0.0;
    for (const auto& line : lines_) {
        for (std::size_t i = 0; i < line.speed.size(); i += 4) speeds.push_back(line.speed[i]);
        streamwise = std::max(streamwise, line.points.back()[0] - line.points.front()[0]);
    }
    std::sort(speeds.begin(), speeds.end());
    if (!speeds.empty()) {
        speedLow_ = speeds[speeds.size() * 2 / 100];
        speedHigh_ = std::max(speeds[speeds.size() * 98 / 100], speedLow_ + 1e-6);
    }
    // Arrows: on every third line, one every 9 % of the stream-wise extent at the free-stream speed,
    // sized to the body. Fewer and smaller than the lines — they show motion, the lines show paths.
    spacing_ = 0.09 * std::max(streamwise, 1e-3) / freeStream_;
    const SbVec3f extent = bodyMax_ - bodyMin_;
    arrowSize_ = 0.034 * std::max({extent[0], extent[1], extent[2], 1e-3f});
    std::mt19937 random(11);
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    phase_.clear();
    for (std::size_t i = 0; i < lines_.size(); ++i) phase_.push_back(unit(random) * spacing_);

    std::vector<SbVec3f> points, vortexPoints;
    std::vector<SbColor> colours, vortexColours;
    std::vector<int32_t> counts, vortexCounts;
    linesMin_ = bodyMin_;
    linesMax_ = bodyMax_;
    for (const auto& line : lines_) {
        for (const auto& p : line.points) {
            const auto d = display(p);
            for (int k = 0; k < 3; ++k) { linesMin_[k] = std::min(linesMin_[k], d[k]); linesMax_[k] = std::max(linesMax_[k], d[k]); }
        }
    }
    for (std::size_t l = 0; l < lines_.size(); ++l) {
        const auto& line = lines_[l];
        const bool emphasised = l >= emphasisedFrom;
        auto& p = emphasised ? vortexPoints : points;
        auto& c = emphasised ? vortexColours : colours;
        auto& n = emphasised ? vortexCounts : counts;
        const std::size_t stride = std::max<std::size_t>(1, line.points.size() / kMaxLinePoints);
        int32_t count = 0;
        for (std::size_t i = 0; i < line.points.size(); i += stride) {
            p.push_back(display(line.points[i]));
            c.push_back(turbo((line.speed[i] - speedLow_) / (speedHigh_ - speedLow_)));
            ++count;
        }
        if (count >= 2) n.push_back(count);
        else { p.resize(p.size() - count); c.resize(c.size() - count); }
    }
    vortexCoordinates_->point.setNum(0);
    vortexCoordinates_->point.setValues(0, static_cast<int>(vortexPoints.size()), vortexPoints.data());
    vortexColours_->diffuseColor.setNum(0);
    vortexColours_->diffuseColor.setValues(0, static_cast<int>(vortexColours.size()), vortexColours.data());
    vortexSet_->numVertices.setNum(0);
    vortexSet_->numVertices.setValues(0, static_cast<int>(vortexCounts.size()), vortexCounts.data());
    lineCoordinates_->point.setNum(0);
    lineCoordinates_->point.setValues(0, static_cast<int>(points.size()), points.data());
    lineColours_->diffuseColor.setNum(0);
    lineColours_->diffuseColor.setValues(0, static_cast<int>(colours.size()), colours.data());
    lineSet_->numVertices.setNum(0);
    lineSet_->numVertices.setValues(0, static_cast<int>(counts.size()), counts.data());
    clock_ = 0.0;
    rebuildArrows();
}

void FlowScene3D::setShowLines(bool show) { lineSwitch_->whichChild = show ? SO_SWITCH_ALL : SO_SWITCH_NONE; }
void FlowScene3D::setShowArrows(bool show) { arrowSwitch_->whichChild = show ? SO_SWITCH_ALL : SO_SWITCH_NONE; }

void FlowScene3D::advance(double physicalSeconds) {
    if (!(physicalSeconds > 0.0) || lines_.empty()) return;
    clock_ += physicalSeconds;
    if (arrowSwitch_->whichChild.getValue() == SO_SWITCH_ALL) rebuildArrows();
}

void FlowScene3D::rebuildArrows() {
    std::vector<SbVec3f> points;
    std::vector<SbColor> colours;
    std::vector<int32_t> faces;
    if (spacing_ > 0.0) {
        for (std::size_t l = 0; l < lines_.size(); l += 2) {
            const auto& line = lines_[l];
            const double end = line.time.back();
            for (double t = std::fmod(phase_[l] + clock_, spacing_); t <= end; t += spacing_) {
                const auto after = std::upper_bound(line.time.begin(), line.time.end(), t);
                const std::size_t b = std::min<std::size_t>(static_cast<std::size_t>(after - line.time.begin()), line.time.size() - 1);
                const std::size_t a = b > 0 ? b - 1 : 0;
                if (a == b) continue;
                const double f = (t - line.time[a]) / std::max(line.time[b] - line.time[a], 1e-12);
                const SbVec3f pa = display(line.points[a]), pb = display(line.points[b]);
                SbVec3f direction = pb - pa;
                if (direction.length() < 1e-9f) continue;
                direction.normalize();
                const SbVec3f centre = pa + (pb - pa) * static_cast<float>(f);
                const double speed = line.speed[a] + f * (line.speed[b] - line.speed[a]);
                const SbColor colour = turbo((speed - speedLow_) / (speedHigh_ - speedLow_));
                // Cone: tip ahead, six-sided base behind.
                SbVec3f side = std::fabs(direction[1]) < 0.9f ? direction.cross(SbVec3f(0, 1, 0)) : direction.cross(SbVec3f(1, 0, 0));
                side.normalize();
                const SbVec3f up = direction.cross(side);
                const float size = static_cast<float>(arrowSize_);
                const int32_t tip = static_cast<int32_t>(points.size());
                points.push_back(centre + direction * (0.6f * size));
                for (int k = 0; k < kArrowSides; ++k) {
                    const float angle = 2.0f * static_cast<float>(M_PI) * k / kArrowSides;
                    points.push_back(centre - direction * (0.4f * size) + (side * std::cos(angle) + up * std::sin(angle)) * (0.26f * size));
                }
                static const SbVec3f light = [] { SbVec3f l(-0.35f, 0.8f, 0.5f); l.normalize(); return l; }();
                for (int k = 0; k < kArrowSides; ++k) {
                    faces.push_back(tip);
                    faces.push_back(tip + 1 + k);
                    faces.push_back(tip + 1 + (k + 1) % kArrowSides);
                    faces.push_back(-1);
                    const float mid = 2.0f * static_cast<float>(M_PI) * (k + 0.5f) / kArrowSides;
                    const SbVec3f normal = side * std::cos(mid) + up * std::sin(mid);
                    colours.push_back(colour * (0.62f + 0.38f * std::max(0.0f, normal.dot(light))));
                }
            }
        }
    }
    arrowCoordinates_->point.setNum(0);
    arrowCoordinates_->point.setValues(0, static_cast<int>(points.size()), points.data());
    arrowColours_->diffuseColor.setNum(0);
    arrowColours_->diffuseColor.setValues(0, static_cast<int>(colours.size()), colours.data());
    arrowFaces_->coordIndex.setNum(0);
    arrowFaces_->coordIndex.setValues(0, static_cast<int>(faces.size()), faces.data());
}

} // namespace cadnext::gui::detail
