#pragma once

#include "cadnext/Result.hpp"

#include <vector>

// Two-dimensional potential flow around a closed section (Hess & Smith, 1967): constant-strength
// source panels with one constant vortex strength over the whole body, and the Kutta condition at
// the trailing edge. It is here because the droplets of an icing calculation have to fly through
// something, and an ice shape is decided within a few per cent of the surface where the air is
// nearly inviscid — the boundary layer decides the heat transfer, not the trajectories.
//
// What it is not: no viscosity, no separation, no compressibility (below about Mach 0.3 the error
// is under 5 % by the Prandtl–Glauert factor, and the caller is told when it is above that), and no
// three-dimensional effect whatever. A section of a wing is not a wing.

namespace cadnext::fea {

// A closed polygon, in metres. The points run once around the section and are not repeated; the
// order decides which side is outside (counter-clockwise puts the interior on the left).
struct SectionGeometry {
    std::vector<double> x, y;
    std::size_t size() const { return x.size(); }
    bool closed() const { return x.size() >= 3 && x.size() == y.size(); }
    // Twice the signed area: positive when the points run counter-clockwise.
    double signedArea() const;
    void makeClockwise();
};

struct PanelFlowSolution {
    SectionGeometry section;
    double freeStreamMps = 0.0, angleOfAttackRad = 0.0;
    std::vector<double> sourceStrength;        // per panel
    double vortexStrength = 0.0;               // shared by every panel
    std::vector<double> controlX, controlY;    // panel midpoints
    std::vector<double> normalX, normalY;      // outward unit normals
    std::vector<double> tangentX, tangentY;    // unit tangents, in the order of the points
    std::vector<double> length;                // panel lengths
    std::vector<double> surfaceSpeedMps;       // tangential speed at each control point
    std::vector<double> pressureCoefficient;   // 1 − (V/V∞)²
    double circulation = 0.0;                  // Γ, positive counter-clockwise
    double liftCoefficient = 0.0;              // from Γ by Kutta–Joukowski, chord = the section's x extent

    // The velocity anywhere outside the body.
    void velocityAt(double x, double y, double& u, double& v) const;
};

// `angleOfAttackRad` turns the free stream, not the body. A section whose first and last points meet
// at a sharp trailing edge gets the Kutta condition; `kutta = false` leaves the body without
// circulation, which is what a cylinder or a fuselage section wants.
Result<PanelFlowSolution> solvePanelFlow(const SectionGeometry& section, double freeStreamMps, double angleOfAttackRad, bool kutta = true);

// A circle of `radius` about the origin, as `count` panels: the section every check of this file
// starts from, because its exact answer is known (Cp = 1 − 4 sin²θ).
SectionGeometry circleSection(double radius, int count);

} // namespace cadnext::fea
