#pragma once

#include "cadnext/cfd/FlowSection.hpp"
#include "cadnext/cfd/ParticleTracer.hpp"

#include <QString>

#include <array>
#include <map>
#include <memory>
#include <string>
#include <vector>

class SoCoordinate3;
class SoLineSet;
class SoMaterial;
class SoSeparator;

// The moving part of the CFD result window: a colour map of the speed on a section through the flow,
// particles carried by that same field, and streamlines — all drawn from one FlowSection, so the
// picture cannot disagree with itself.
//
// Colour: the speed relative to the free stream on a diverging scale, blue slower, near-white at the
// free-stream speed, red faster. A rainbow of absolute speed paints almost the whole picture one
// colour (everything far from the body is at the free-stream speed); the deviation is what shows
// the wake, the stagnation region and the suction side. The scale is fixed when the field is loaded
// and kept through a time-accurate playback, so colour changes are the flow's, not the legend's.
//
// A time-accurate result plays its frames on one physical clock with the particles: between two
// saved frames the section velocity is blended linearly, and the particles keep moving through each
// change of field instead of restarting.

namespace cadnext::gui::detail {

class FlowAnimation {
public:
    struct Frame {
        std::string sectionPath; // section_<step>.csv
        double time = 0.0;       // physical seconds
        int step = 0;
    };

    // `section` carries the field to show (the final or only one); `region` is x₀, x₁ (streamwise),
    // z₀, z₁ (up) in solver metres; `plane` is the section's position along the display depth axis;
    // `speed` the free-stream speed the stored velocities are normalised by.
    FlowAnimation(cfd::FlowSection section, std::array<double, 4> region, double plane, double speed);
    ~FlowAnimation();
    FlowAnimation(const FlowAnimation&) = delete;
    FlowAnimation& operator=(const FlowAnimation&) = delete;

    SoSeparator* colourMap() const { return colourMap_; }
    SoSeparator* streamlines() const { return streamlines_; }
    SoSeparator* particles() const { return particles_; }

    // Time frames of an unsteady run, in time order. Empty: a steady field.
    void setFrames(std::vector<Frame> frames);
    bool unsteady() const { return frames_.size() > 1; }

    // Advances the physical clock and everything that depends on it. With playFrames off an unsteady
    // field stays on the frame shown and only the particles move.
    void advance(double physicalSeconds, bool playFrames = true);

    // Half-width of the colour scale as a fraction of the free-stream speed.
    double deviation() const { return deviation_; }
    double freeStreamSpeed() const { return speed_; }
    QString clockLabel() const;
    int validSamples() const { return validSamples_; }
    // Last frame problem (a frame that could not be read), empty when all is well.
    const QString& problem() const { return problem_; }

private:
    bool sample(double x, double z, double& u, double& w, double& speed) const;
    void showField(const std::vector<cfd::FlowSection::Vector>& nodeVelocity);
    void recolour();
    void rebuildStreamlines();
    void redrawParticles();
    const std::vector<cfd::FlowSection::Vector>* frame(std::size_t index);

    cfd::FlowSection section_;
    std::array<double, 4> region_;
    double plane_ = 0.0;
    double speed_ = 1.0;
    double deviation_ = 0.5;
    int columns_ = 0, rows_ = 0, validSamples_ = 0;

    std::unique_ptr<cfd::ParticleTracer> tracer_;
    std::vector<Frame> frames_;
    std::map<std::size_t, std::vector<cfd::FlowSection::Vector>> loaded_;
    double clock_ = 0.0;
    std::size_t shownFrame_ = static_cast<std::size_t>(-1);
    QString problem_;

    SoSeparator* colourMap_ = nullptr;
    SoCoordinate3* mapCoordinates_ = nullptr;
    SoMaterial* mapColours_ = nullptr;
    SoSeparator* streamlines_ = nullptr;
    SoCoordinate3* lineCoordinates_ = nullptr;
    SoLineSet* lines_ = nullptr;
    SoSeparator* particles_ = nullptr;
    SoCoordinate3* trailCoordinates_ = nullptr;
    SoMaterial* trailColours_ = nullptr;
    SoLineSet* trails_ = nullptr;
    SoCoordinate3* headCoordinates_ = nullptr;
};

} // namespace cadnext::gui::detail
