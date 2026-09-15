#pragma once

#include "cadnext/cfd/Su2Mesh.hpp"

// The Joukowski airfoil: the image of a circle under z = ζ + c²/ζ, with an exact potential-flow
// solution. It is the flow solver's code-verification case — lift known in closed form, geometry
// exact, and a body-fitted O-mesh that comes for free from the same mapping (a conformal map keeps
// the circle's polar grid orthogonal).
//
// Circle centre ζ0 = c·(−μx + i·μy) through the trailing-edge point ζ = c. The Kutta condition at the
// cusp fixes the circulation Γ = 4π R U sin(α + β), β = atan(μy / (1 + μx)), so per unit span
//   CL = 2Γ / (U·chord) = 8π R sin(α + β) / chord.
// Everything is scaled to chord 1, leading edge at x = 0.

namespace cadnext::cfd {

struct JoukowskiAirfoil {
    double thicknessParameter = 0.1; // μx
    double camberParameter = 0.0;    // μy

    // Before scaling (c = 1): circle radius, zero-lift angle β, chord and leading-edge x.
    double radius() const;
    double beta() const;
    double unscaledChord() const;
    double unscaledLeadingEdge() const;

    double exactLiftCoefficient(double alphaRadians) const;

    // O-mesh of quads: `circumferential` × `radial` cells, radial spacing uniform in ln ρ (square cells
    // in the circle plane, and so near-square everywhere), outer boundary `farfieldChords` chords
    // from the airfoil. Markers "airfoil" and "farfield".
    Su2Mesh oMesh(int circumferential, int radial, double farfieldChords) const;
};

} // namespace cadnext::cfd
