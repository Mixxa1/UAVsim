#pragma once

#include "cadnext/Result.hpp"

#include <array>
#include <complex>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

// Maxwell's equations on a Yee grid (FDTD), written here rather than taken from a library: the
// open FDTD codes are GPL, and this stage may only use LGPL/MPL.
//
// What it is: a uniform cubic grid, second-order in space and time (Yee 1966), absorbed at the
// outer boundary by a convolutional PML (Roden & Gedney 2000), fed either by a point dipole or by
// a plane wave injected across a total-field / scattered-field surface at normal incidence, with an
// auxiliary one-dimensional grid so the injected wave carries the grid's own numerical dispersion
// instead of the textbook one. Metal is perfect: the electric field on the marked edges is held at
// zero, which is what a metal enclosure is at radio frequencies (in aluminium the skin depth at
// 100 MHz is 8 µm — the wall is opaque and the shielding is decided by its apertures and seams).
//
// What it is not: no lossy or dielectric materials, no oblique incidence, no sub-cell wire or slot
// models. An aperture narrower than a cell is not represented — the caller is told, not guessed for.

namespace cadnext::em {

inline constexpr double kSpeedOfLightMps = 299792458.0;
inline constexpr double kVacuumPermeability = 1.25663706212e-6; // H/m, CODATA 2018
inline constexpr double kVacuumPermittivity = 1.0 / (kVacuumPermeability * kSpeedOfLightMps * kSpeedOfLightMps);
inline constexpr double kFreeSpaceImpedance = kVacuumPermeability * kSpeedOfLightMps; // ≈ 376.730 Ω

enum class Axis { X = 0, Y = 1, Z = 2 };

// A cubic Yee grid of nx × ny × nz cells whose corner (0,0,0) sits at `origin`.
struct YeeGrid {
    double originX = 0.0, originY = 0.0, originZ = 0.0;
    double cellM = 0.0;
    int nx = 0, ny = 0, nz = 0;

    // Arrays are allocated over the corner lattice, so every component has the same indexing.
    std::size_t nodes() const { return static_cast<std::size_t>(nx + 1) * (ny + 1) * (nz + 1); }
    std::size_t index(int i, int j, int k) const {
        return (static_cast<std::size_t>(i) * (ny + 1) + static_cast<std::size_t>(j)) * (nz + 1) + static_cast<std::size_t>(k);
    }
    // The nearest lattice node to a point in metres (clamped to the grid).
    void nearestNode(double x, double y, double z, int& i, int& j, int& k) const;
    double courantStepS(double factor) const { return factor * cellM / (kSpeedOfLightMps * 1.7320508075688772); }
};

// Perfect electric conductor: the marked edges hold zero tangential field. Edge (i,j,k) of family
// Ex spans from node (i,j,k) to (i+1,j,k), and so on.
struct PecEdges {
    std::vector<std::uint8_t> x, y, z;
    void clear(const YeeGrid& grid);
    bool empty() const { return x.empty() && y.empty() && z.empty(); }
};

// A plane wave at normal incidence, injected over the faces of a box inside the grid (the
// total-field / scattered-field surface): inside that box the field is total, outside it is the
// scattered field alone, so the absorbing layer never sees the incident wave. `waveform(t)` is the
// incident E in V/m at the box's entry face.
struct PlaneWaveSource {
    Axis propagation = Axis::X;
    bool forward = true;         // +axis when true
    Axis polarization = Axis::Z; // the electric field's direction; must differ from `propagation`
    int marginCells = 2;         // the surface sits this many cells inside the layer's inner edge (at least 2)
    std::function<double(double)> waveform;
};

// A soft current source on one electric-field edge: what feeds the cavity checks.
struct PointSource {
    double x = 0.0, y = 0.0, z = 0.0;
    Axis polarization = Axis::Z;
    std::function<double(double)> waveform; // V/m added to the edge each step
};

struct FdtdProblem {
    YeeGrid grid;
    PecEdges pec;
    std::optional<PlaneWaveSource> plane;
    std::optional<PointSource> point;
    // Where the field is watched, in metres. Each probe records the three electric components at
    // the nearest edges of the lattice.
    std::vector<std::array<double, 3>> probes;
    std::vector<double> frequenciesHz; // running DFT of every probe at these frequencies
    // The absorbing layer (Roden & Gedney; Taflove & Hagness §7.9): a cubic grading aimed at a
    // reflection of 1e-6 at normal incidence, with the complex-frequency shift α that keeps the
    // static part of a nearby source out of the layer.
    //
    // The defaults are measured here, not taken from the books. The usual textbook pair, κ up to 5
    // and α = 0.24 S/m, reflects a dipole's near field at ten cells at −45 dB and a wave grazing
    // along the layer at −57 dB; κ = 1 with α = 0.05 S/m gives −92 dB and −78…−90 dB for the same
    // runs, and leaves −157 dB long after the pulse has gone (α = 0 leaves −89 dB there, which is
    // what α is for). A wave at normal incidence is absorbed to machine precision either way.
    int pmlCells = 10;
    double pmlOrder = 3.0, pmlKappaMax = 1.0, pmlAlphaMax = 0.05, pmlReflection = 1e-6;
    double courantFactor = 0.99;
    int steps = 0;
    bool recordHistory = true;
};

struct FdtdProbeResult {
    std::vector<double> exVm, eyVm, ezVm;               // the time history, when asked for
    std::vector<std::array<std::complex<double>, 3>> spectrum; // per requested frequency, V/m·s
};

struct FdtdResult {
    double stepS = 0.0;
    int steps = 0;
    std::vector<FdtdProbeResult> probes;
    // The incident wave as the grid carries it, at the same frequencies: what shielding is measured
    // against. Empty without a plane wave.
    std::vector<std::complex<double>> incidentSpectrum;
    std::vector<double> incidentVm;
    double pmlReflectionR0 = 0.0;
};

// Runs the problem. `progress(step)` may return false to stop early.
Result<FdtdResult> solveFdtd(const FdtdProblem& problem, const std::function<bool(int)>& progress = {});

// The pulse the validations and the studies use: a differentiated Gaussian, flat enough in
// amplitude from `lowHz` to `highHz` to read a spectrum off one run. Its peak is 1 V/m.
struct GaussianDerivative {
    double tauS = 0.0, delayS = 0.0;
    double operator()(double t) const;
};
GaussianDerivative ricker(double lowHz, double highHz);

// The exact dispersion relation of this scheme along an axis (Taflove & Hagness, eq. 4.16 in 1D):
// the numerical wavenumber that a wave of frequency f has on a grid with cell Δ and step Δt.
double numericalWavenumber(double frequencyHz, double cellM, double stepS);

} // namespace cadnext::em
