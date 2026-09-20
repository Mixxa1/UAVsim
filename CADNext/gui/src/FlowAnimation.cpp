#include "FlowAnimation.hpp"

#include "cadnext/cfd/SectionFrames.hpp"

#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoDrawStyle.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoLightModel.h>
#include <Inventor/nodes/SoLineSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoMaterialBinding.h>
#include <Inventor/nodes/SoPointSet.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QObject>

#include <algorithm>
#include <cmath>

namespace cadnext::gui::detail {

namespace {

// Moreland's cool–warm diverging scale, blue → light grey → red, t in [−1, 1].
SbColor coolWarm(double t) {
    t = std::clamp(t, -1.0, 1.0);
    const SbColor blue(0.230f, 0.299f, 0.754f), middle(0.865f, 0.865f, 0.865f), red(0.706f, 0.016f, 0.150f);
    const float f = static_cast<float>(std::fabs(t));
    return t < 0 ? middle * (1.0f - f) + blue * f : middle * (1.0f - f) + red * f;
}

constexpr int kColumns = 320;
constexpr int kStreamlines = 17;
constexpr int kParticles = 320;

} // namespace

FlowAnimation::FlowAnimation(cfd::FlowSection section, std::array<double, 4> region, double plane, double speed)
    : section_(std::move(section)), region_(region), plane_(plane), speed_(speed > 0 ? speed : 1.0) {
    const double width = region_[1] - region_[0], height = region_[3] - region_[2];
    columns_ = kColumns;
    rows_ = std::max(16, static_cast<int>(std::lround(kColumns * height / width)));
    auto display = [&](double x, double z, float lift) { return SbVec3f(static_cast<float>(plane_) - lift, static_cast<float>(z), static_cast<float>(x)); };

    // Colour map: a fixed grid over the region; faces only where all four corners are fluid, which
    // does not change between frames (the body does not move).
    colourMap_ = new SoSeparator;
    colourMap_->ref();
    auto* flat = new SoLightModel;
    flat->model = SoLightModel::BASE_COLOR;
    colourMap_->addChild(flat);
    mapColours_ = new SoMaterial;
    auto* binding = new SoMaterialBinding;
    binding->value = SoMaterialBinding::PER_VERTEX_INDEXED;
    colourMap_->addChild(mapColours_);
    colourMap_->addChild(binding);
    mapCoordinates_ = new SoCoordinate3;
    colourMap_->addChild(mapCoordinates_);
    std::vector<SbVec3f> points(static_cast<std::size_t>(columns_ * rows_));
    std::vector<char> fluid(points.size(), 0);
    for (int row = 0; row < rows_; ++row) {
        for (int column = 0; column < columns_; ++column) {
            const double x = region_[0] + width * column / (columns_ - 1), z = region_[2] + height * row / (rows_ - 1);
            points[static_cast<std::size_t>(row * columns_ + column)] = display(x, z, 0.0f);
            double u = 0, w = 0, s = 0;
            fluid[static_cast<std::size_t>(row * columns_ + column)] = sample(x, z, u, w, s) ? 1 : 0;
        }
    }
    mapCoordinates_->point.setValues(0, static_cast<int>(points.size()), points.data());
    auto* faces = new SoIndexedFaceSet;
    std::vector<int32_t> indices;
    for (int row = 0; row + 1 < rows_; ++row) {
        for (int column = 0; column + 1 < columns_; ++column) {
            const int a = row * columns_ + column, b = a + 1, c = a + columns_, d = c + 1;
            if (!(fluid[a] && fluid[b] && fluid[c] && fluid[d])) continue;
            for (int vertex : {a, b, d, -1, a, d, c, -1}) indices.push_back(vertex);
        }
    }
    faces->coordIndex.setValues(0, static_cast<int>(indices.size()), indices.data());
    colourMap_->addChild(faces);

    // The colour scale: 99th percentile of |V/V∞ − 1| over the section, so one spike at a sharp edge
    // does not wash the rest of the picture out.
    std::vector<double> deviations;
    for (std::size_t i = 0; i < points.size(); ++i) {
        if (!fluid[i]) continue;
        double u = 0, w = 0, s = 0;
        if (sample(points[i][2], points[i][1], u, w, s)) deviations.push_back(std::fabs(s / speed_ - 1.0));
    }
    std::sort(deviations.begin(), deviations.end());
    validSamples_ = static_cast<int>(deviations.size());
    if (!deviations.empty()) deviation_ = std::clamp(deviations[static_cast<std::size_t>(0.99 * (deviations.size() - 1))], 0.05, 1.0);
    recolour();

    // Streamlines: thin and quiet — the particles carry the motion, the lines only the shape.
    streamlines_ = new SoSeparator;
    streamlines_->ref();
    auto* lineLight = new SoLightModel;
    lineLight->model = SoLightModel::BASE_COLOR;
    streamlines_->addChild(lineLight);
    auto* lineMaterial = new SoMaterial;
    lineMaterial->diffuseColor.setValue(0.18f, 0.20f, 0.24f);
    lineMaterial->transparency.setValue(0.55f);
    streamlines_->addChild(lineMaterial);
    auto* lineStyle = new SoDrawStyle;
    lineStyle->lineWidth = 1.0f;
    streamlines_->addChild(lineStyle);
    lineCoordinates_ = new SoCoordinate3;
    streamlines_->addChild(lineCoordinates_);
    lines_ = new SoLineSet;
    streamlines_->addChild(lines_);
    rebuildStreamlines();

    // Particles: a fading trail per particle plus a head.
    particles_ = new SoSeparator;
    particles_->ref();
    auto* particleLight = new SoLightModel;
    particleLight->model = SoLightModel::BASE_COLOR;
    particles_->addChild(particleLight);
    auto* trailStyle = new SoDrawStyle;
    trailStyle->lineWidth = 1.4f;
    particles_->addChild(trailStyle);
    trailColours_ = new SoMaterial;
    auto* trailBinding = new SoMaterialBinding;
    trailBinding->value = SoMaterialBinding::PER_VERTEX;
    particles_->addChild(trailColours_);
    particles_->addChild(trailBinding);
    trailCoordinates_ = new SoCoordinate3;
    particles_->addChild(trailCoordinates_);
    trails_ = new SoLineSet;
    particles_->addChild(trails_);
    auto* heads = new SoSeparator;
    auto* headMaterial = new SoMaterial;
    headMaterial->diffuseColor.setValue(0.05f, 0.06f, 0.08f);
    heads->addChild(headMaterial);
    auto* headBinding = new SoMaterialBinding; // one colour, whatever the trails above bound
    headBinding->value = SoMaterialBinding::OVERALL;
    heads->addChild(headBinding);
    auto* headStyle = new SoDrawStyle;
    headStyle->pointSize = 2.5f;
    heads->addChild(headStyle);
    headCoordinates_ = new SoCoordinate3;
    heads->addChild(headCoordinates_);
    heads->addChild(new SoPointSet);
    particles_->addChild(heads);

    cfd::ParticleTracerSettings settings;
    settings.region = region_;
    settings.particles = kParticles;
    settings.referenceSpeed = speed_;
    // A trail as long as the particle travels in 4 % of a free-stream transit: long enough to show
    // direction and speed, short enough not to turn into streamlines.
    settings.trailSeconds = 0.04 * width / speed_;
    settings.trailSamples = 10;
    settings.lifetimeTransits = 2.5;
    tracer_ = std::make_unique<cfd::ParticleTracer>(settings);
    tracer_->setSampler([this](double x, double z, double& u, double& w, double& s) { return sample(x, z, u, w, s); });
    redrawParticles();
}

FlowAnimation::~FlowAnimation() {
    for (auto* node : {colourMap_, streamlines_, particles_}) if (node) node->unref();
}

bool FlowAnimation::sample(double x, double z, double& u, double& w, double& speed) const {
    cfd::FlowSection::Vector v{};
    if (!section_.sample(x, z, v)) return false;
    u = v[0] * speed_;
    w = v[2] * speed_;
    speed = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) * speed_;
    return true;
}

void FlowAnimation::recolour() {
    const int count = mapCoordinates_->point.getNum();
    std::vector<SbColor> colours(static_cast<std::size_t>(count), SbColor(0.93f, 0.94f, 0.95f));
    const SbVec3f* points = mapCoordinates_->point.getValues(0);
    for (int i = 0; i < count; ++i) {
        double u = 0, w = 0, s = 0;
        if (sample(points[i][2], points[i][1], u, w, s)) colours[static_cast<std::size_t>(i)] = coolWarm((s / speed_ - 1.0) / deviation_);
    }
    mapColours_->diffuseColor.setValues(0, count, colours.data());
}

void FlowAnimation::rebuildStreamlines() {
    const double width = region_[1] - region_[0], height = region_[3] - region_[2];
    const double step = 0.004 * width;
    const float lift = static_cast<float>(0.002 * width);
    // Seeds on the inflow edge: the side whose mean streamwise velocity points inwards.
    double upstream = 0;
    for (int i = 0; i <= 20; ++i) {
        double u = 0, w = 0, s = 0;
        if (sample(region_[0] + 0.02 * width, region_[2] + height * i / 20.0, u, w, s)) upstream += u;
    }
    const double inlet = upstream >= 0 ? region_[0] + 1e-6 * width : region_[1] - 1e-6 * width;
    std::vector<SbVec3f> points;
    std::vector<int32_t> counts;
    for (int seed = 0; seed < kStreamlines; ++seed) {
        double x = inlet, z = region_[2] + height * (seed + 0.5) / kStreamlines;
        const std::size_t first = points.size();
        for (int n = 0; n < 2000; ++n) {
            double u = 0, w = 0, s = 0;
            if (!sample(x, z, u, w, s)) break;
            points.emplace_back(static_cast<float>(plane_) - lift, static_cast<float>(z), static_cast<float>(x));
            const double planar = std::hypot(u, w);
            if (planar < 1e-9) break;
            double um = 0, wm = 0, sm = 0;
            if (!sample(x + 0.5 * step * u / planar, z + 0.5 * step * w / planar, um, wm, sm)) break;
            const double mid = std::hypot(um, wm);
            if (mid < 1e-9) break;
            x += step * um / mid;
            z += step * wm / mid;
        }
        const auto length = points.size() - first;
        if (length < 4) points.resize(first);
        else counts.push_back(static_cast<int32_t>(length));
    }
    lineCoordinates_->point.setNum(0);
    lineCoordinates_->point.setValues(0, static_cast<int>(points.size()), points.data());
    lines_->numVertices.setNum(0);
    lines_->numVertices.setValues(0, static_cast<int>(counts.size()), counts.data());
}

void FlowAnimation::redrawParticles() {
    const double width = region_[1] - region_[0];
    const float lift = static_cast<float>(0.004 * width);
    std::vector<SbVec3f> points, heads;
    std::vector<SbColor> colours;
    std::vector<float> transparency;
    std::vector<int32_t> counts;
    const SbColor ink(0.05f, 0.06f, 0.08f);
    for (const auto& particle : tracer_->particles()) {
        if (!std::isfinite(particle.position[0])) continue;
        heads.emplace_back(static_cast<float>(plane_) - lift, static_cast<float>(particle.position[1]), static_cast<float>(particle.position[0]));
        const std::size_t length = particle.trail.size() + 1;
        if (length < 2) continue;
        for (std::size_t i = 0; i < length; ++i) {
            const auto& p = i < particle.trail.size() ? particle.trail[i] : particle.position;
            points.emplace_back(static_cast<float>(plane_) - lift, static_cast<float>(p[1]), static_cast<float>(p[0]));
            colours.push_back(ink);
            // Oldest point nearly transparent, the head nearly opaque.
            transparency.push_back(0.92f - 0.8f * static_cast<float>(i) / static_cast<float>(length - 1));
        }
        counts.push_back(static_cast<int32_t>(length));
    }
    trailCoordinates_->point.setNum(0);
    trailCoordinates_->point.setValues(0, static_cast<int>(points.size()), points.data());
    trailColours_->diffuseColor.setNum(0);
    trailColours_->diffuseColor.setValues(0, static_cast<int>(colours.size()), colours.data());
    trailColours_->transparency.setNum(0);
    trailColours_->transparency.setValues(0, static_cast<int>(transparency.size()), transparency.data());
    trails_->numVertices.setNum(0);
    trails_->numVertices.setValues(0, static_cast<int>(counts.size()), counts.data());
    headCoordinates_->point.setNum(0);
    headCoordinates_->point.setValues(0, static_cast<int>(heads.size()), heads.data());
}

void FlowAnimation::setFrames(std::vector<Frame> frames) {
    std::sort(frames.begin(), frames.end(), [](const Frame& a, const Frame& b) { return a.time < b.time; });
    frames_ = std::move(frames);
    loaded_.clear();
    clock_ = 0.0;
    shownFrame_ = static_cast<std::size_t>(-1);
    problem_.clear();
}

const std::vector<cfd::FlowSection::Vector>* FlowAnimation::frame(std::size_t index) {
    if (index >= frames_.size()) return nullptr;
    const auto found = loaded_.find(index);
    if (found != loaded_.end()) return &found->second;
    auto read = cfd::readSectionFrame(frames_[index].sectionPath, section_.referencedNodes());
    if (!read.isOk()) {
        problem_ = QString::fromStdString(read.error().message);
        return nullptr;
    }
    return &loaded_.emplace(index, std::move(read.value())).first->second;
}

void FlowAnimation::advance(double physicalSeconds, bool playFrames) {
    if (!(physicalSeconds > 0.0)) return;
    if (playFrames) clock_ += physicalSeconds;
    if (unsteady() && (playFrames || shownFrame_ == static_cast<std::size_t>(-1))) {
        const double start = frames_.front().time, span = frames_.back().time - start;
        const double now = span > 0 ? start + std::fmod(clock_, span) : start;
        std::size_t k = 0;
        while (k + 2 < frames_.size() && frames_[k + 1].time <= now) ++k;
        const auto* a = frame(k);
        const auto* b = frame(k + 1);
        if (a != nullptr && b != nullptr) {
            const double gap = frames_[k + 1].time - frames_[k].time;
            const double weight = gap > 0 ? std::clamp((now - frames_[k].time) / gap, 0.0, 1.0) : 0.0;
            std::vector<cfd::FlowSection::Vector> blended(a->size());
            for (std::size_t i = 0; i < blended.size(); ++i)
                for (int c = 0; c < 3; ++c) blended[i][c] = (1.0 - weight) * (*a)[i][c] + weight * (*b)[i][c];
            showField(blended);
            if (k != shownFrame_) {
                shownFrame_ = k;
                rebuildStreamlines();
            }
        }
    }
    tracer_->advance(physicalSeconds);
    redrawParticles();
}

void FlowAnimation::showField(const std::vector<cfd::FlowSection::Vector>& nodeVelocity) {
    try {
        section_.refresh(nodeVelocity);
    } catch (const std::exception& error) {
        problem_ = QString::fromUtf8(error.what());
        return;
    }
    recolour();
}

QString FlowAnimation::clockLabel() const {
    if (!unsteady()) return {};
    const double start = frames_.front().time, span = frames_.back().time - start;
    const double now = span > 0 ? start + std::fmod(clock_, span) : start;
    std::size_t k = 0;
    while (k + 2 < frames_.size() && frames_[k + 1].time <= now) ++k;
    return QObject::tr("t = %1 мс · между кадрами %2 и %3 из %4")
        .arg(now * 1000.0, 0, 'f', 2).arg(k + 1).arg(k + 2).arg(frames_.size());
}

} // namespace cadnext::gui::detail
