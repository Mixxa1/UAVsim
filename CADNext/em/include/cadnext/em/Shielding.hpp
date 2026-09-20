#pragma once

#include "cadnext/em/Fdtd.hpp"

#include <string>
#include <vector>

// Shielding: how much of an outside field a metal box keeps out of itself, and the closed-form
// answers this project checks that against.
//
// Two mechanisms decide the shielding of a real avionics box, and both are here as exact formulas:
//   - a vent or a connector cut-out deeper than it is wide is a waveguide below its cutoff, and an
//     evanescent mode decays at a rate that follows from the mode's own wavenumber alone;
//   - a slot much shorter than the wavelength radiates as a pair of dipoles whose moments grow with
//     the cube of its size, so the field behind it does too.
// Everything else — the box's own resonances, the aperture's shape, the position inside — is what
// the finite-difference solver is for.
//
// Deliberately absent: the analytical formulation of Robinson et al. (IEEE Trans. EMC 40(3), 1998),
// the usual reference for a rectangular enclosure with a rectangular aperture. Its equations could
// not be read out of the paper (they are images in the only copy available), and a reference that
// has to be reconstructed from memory is not a reference. There is no shielding formula here that
// this file cannot derive.

namespace cadnext::em {

// The cutoff of the TE10 mode of a rectangular pipe: c/2a, with `a` the longer side.
double waveguideCutoffHz(double widthM, double heightM);

// How fast the field dies along a pipe below that cutoff, in nepers per metre:
// α = 2π f_c/c · √(1 − (f/f_c)²). Zero at and above the cutoff — there the mode propagates.
double belowCutoffAttenuationNpPerM(double frequencyHz, double cutoffHz);

inline double nepersToDecibels(double nepers) {
    return 20.0 * nepers / 2.302585092994046;
}

// Shielding in decibels: how much smaller the field inside is than the field that would be there
// without the metal.
double shieldingEffectivenessDb(double incidentVm, double insideVm);

// A box of metal cells, inclusive of both bounds, marked into the electric edges: every edge of
// every cell of the box is a perfect conductor. `hollow` leaves the inside empty (a shell one cell
// thick), which is what an enclosure is.
struct CellBox {
    int i0 = 0, i1 = 0, j0 = 0, j1 = 0, k0 = 0, k1 = 0;
    bool contains(int i, int j, int k) const { return i >= i0 && i <= i1 && j >= j0 && j <= j1 && k >= k0 && k <= k1; }
};
void markMetalCells(const YeeGrid& grid, PecEdges& pec, const CellBox& box, bool hollow = false, const std::vector<CellBox>& openings = {});

// The cells a solid occupies, by the classic ray count: a point is inside when a ray from it crosses
// the surface an odd number of times. `triangles` are indices into `vertices`, three per triangle,
// in metres. Cells whose centre falls inside become metal.
std::vector<std::uint8_t> voxelizeSurface(const YeeGrid& grid, const std::vector<std::array<double, 3>>& vertices,
                                          const std::vector<std::array<int, 3>>& triangles);
void markMetalCells(const YeeGrid& grid, PecEdges& pec, const std::vector<std::uint8_t>& cells);

// The field levels the standards ask a box to survive, for the verdict to mean something.
struct RadiatedLevel {
    std::string id, description;
    double lowHz = 0.0, highHz = 0.0, fieldVm = 0.0;
};
std::vector<RadiatedLevel> radiatedSusceptibilityLevels();
const RadiatedLevel* radiatedLevel(const std::string& id);

} // namespace cadnext::em
