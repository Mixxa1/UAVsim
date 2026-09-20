#pragma once

#include "cadnext/cfd/FlowVolume.hpp"

#include <Inventor/SbColor.h>
#include <Inventor/SbVec3f.h>

#include <array>
#include <cstdint>
#include <vector>

class SoCoordinate3;
class SoIndexedFaceSet;
class SoMaterialBinding;
class SoLineSet;
class SoMaterial;
class SoSeparator;
class SoSwitch;

// The flow around the body in three dimensions: the body itself, flow trajectories from a rake
// upstream coloured by speed, and arrows running along the trajectories at the computed speed — the
// picture a flow simulation is expected to give, drawn only from the solver's field.
//
// Arrows are spaced in time, not in distance: every arrow on a line left the rake a fixed interval
// after the one ahead of it. So they crowd where the air slows down (ahead of the body, in the wake)
// and spread out where it speeds up — the spacing itself shows the speed, as smoke pulses would.
//
// Display frame: solver x (aft) → display x, solver z (up) → display y, solver y (right) → display −z.
// Right-handed, y up, as the viewer expects.

namespace cadnext::gui::detail {

// Perceptually ordered rainbow ("Turbo", polynomial fit), t in [0, 1]: the scale engineers read flow
// pictures in, without the dark bands of the classic jet map.
SbColor turbo(double t);

class FlowScene3D {
public:
    struct SurfaceValue {
        std::array<double, 3> position; // solver frame
        double value;
    };

    FlowScene3D();
    ~FlowScene3D();
    FlowScene3D(const FlowScene3D&) = delete;
    FlowScene3D& operator=(const FlowScene3D&) = delete;

    SoSeparator* root() const { return root_; }

    // Body walls in the solver frame.
    void setBody(const std::vector<std::array<cfd::FlowVolume::Point, 3>>& walls);
    // Colours the body by a surface quantity (Cp) given at its wall nodes; empty: plain grey.
    void setBodyValues(const std::vector<SurfaceValue>& values, double low, double high);
    void setBodyColoured(bool coloured);
    // Trajectories (solver frame, m/s) and the free-stream speed used for arrow spacing.
    // Lines from `emphasisedFrom` on (the ones traced through vortex cores) are drawn thicker.
    void setTrajectories(std::vector<cfd::Trajectory> lines, double freeStream, std::size_t emphasisedFrom = SIZE_MAX);

    void setShowLines(bool show);
    void setShowArrows(bool show);
    void advance(double physicalSeconds);

    double speedLow() const { return speedLow_; }
    double speedHigh() const { return speedHigh_; }
    // Display-frame bounding box of the body.
    SbVec3f bodyMin() const { return bodyMin_; }
    SbVec3f bodyMax() const { return bodyMax_; }
    // Display-frame bounding box of the body and the trajectories together.
    SbVec3f sceneMin() const { return linesMin_; }
    SbVec3f sceneMax() const { return linesMax_; }
    std::size_t lineCount() const { return lines_.size(); }

    static SbVec3f display(const cfd::FlowVolume::Point& solver) {
        return SbVec3f(static_cast<float>(solver[0]), static_cast<float>(solver[2]), static_cast<float>(-solver[1]));
    }

private:
    void rebuildArrows();

    SoSeparator* root_ = nullptr;
    SoMaterial* bodyMaterial_ = nullptr;
    SoCoordinate3* bodyCoordinates_ = nullptr;
    SoIndexedFaceSet* bodyFaces_ = nullptr;
    SoMaterialBinding* bodyBinding_ = nullptr;
    std::vector<SbColor> bodyColours_;
    std::vector<std::array<double, 3>> bodySolver_; // the same vertices in solver metres, for lookups
    bool bodyColoured_ = false;
    SoSwitch* lineSwitch_ = nullptr;
    SoCoordinate3* lineCoordinates_ = nullptr;
    SoMaterial* lineColours_ = nullptr;
    SoLineSet* lineSet_ = nullptr;
    SoCoordinate3* vortexCoordinates_ = nullptr;
    SoMaterial* vortexColours_ = nullptr;
    SoLineSet* vortexSet_ = nullptr;
    SoSwitch* arrowSwitch_ = nullptr;
    SoCoordinate3* arrowCoordinates_ = nullptr;
    SoMaterial* arrowColours_ = nullptr;
    SoIndexedFaceSet* arrowFaces_ = nullptr;

    std::vector<cfd::Trajectory> lines_;
    std::vector<double> phase_; // per line, seconds
    double freeStream_ = 1.0;
    double spacing_ = 0.0;      // seconds between arrows on a line
    double arrowSize_ = 0.0;    // metres
    double clock_ = 0.0;
    double speedLow_ = 0.0, speedHigh_ = 1.0;
    SbVec3f bodyMin_{0, 0, 0}, bodyMax_{0, 0, 0};
    SbVec3f linesMin_{0, 0, 0}, linesMax_{0, 0, 0};
};

} // namespace cadnext::gui::detail
