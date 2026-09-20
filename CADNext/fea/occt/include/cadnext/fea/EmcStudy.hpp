#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/em/Shielding.hpp"
#include "cadnext/fea/ClimateStudy.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <optional>
#include <string>
#include <vector>

// Radiated susceptibility of a CAD enclosure (MIL-STD-461G RS103 / RTCA DO-160G §20): the standard's
// field arrives as a plane wave, and the question is how much of it reaches the equipment inside.
//
// The part is voxelised into a Yee grid — every cell whose centre is inside the solid becomes a
// perfect conductor, which is what a metal wall is at radio frequencies (in aluminium the skin depth
// at 100 MHz is 8 µm) — and a broadband pulse is run through it once per mesh, giving the whole
// sweep from one run. The shielding at a point is how much smaller the field there is than the
// incident field that would be at that point without the box.
//
// What is modelled and what is not:
//   - metal is perfect and walls are opaque: only openings, seams and slots let anything through, so
//     a wall thinner than a cell is a warning, not a result;
//   - the enclosure is empty and lossless. A real box is loaded by what is inside it, which damps
//     its resonances; here nothing does, so at a resonance the field inside is held down only by the
//     length of the run. Those frequencies are reported as resonances, and the shielding there is a
//     lower bound on the real one, not an estimate of it;
//   - the wave arrives along an axis at normal incidence, polarised along another; other directions
//     are other runs;
//   - cables and their coupling are not here at all (RS103 tests a box, CS114/CS116 test cables);
//   - the conductivity of the metal, gaskets, and dielectric windows are not modelled: нет данных.
//
// The verdict: the field at each piece of equipment is the standard's level divided by the shielding,
// compared with that equipment's immunity. The numerical floor of the solver (about −50 dB, measured
// in test_em_fdtd) is reported beside it: a shielding claim near that floor is the grid's, not the
// part's.

namespace cadnext::fea {

struct EmcProbe {
    std::string name;
    double x = 0.0, y = 0.0, z = 0.0; // inside the enclosure, in the part's own coordinates
    double immunityVm = 0.0;          // what this equipment is qualified to; 0 = unknown
};

struct EmcStudySettings {
    double coarseCellM = 0.0;        // required: the Yee cell of the coarse grid
    double refinementFactor = 0.0;   // required, ≥ 1.2: each level's cell is smaller by this factor
    double surfaceElementSizeM = 0.0; // the triangulation the voxels are cut from; defaults to the coarse cell
    em::Axis incidence = em::Axis::X;
    bool forward = true;
    em::Axis polarization = em::Axis::Z;
    std::string levelId;   // a level of the standard, or empty with `fieldVm`
    double fieldVm = 0.0;  // required when `levelId` is empty
    double lowHz = 0.0, highHz = 0.0; // required
    int points = 0;                   // required: how many frequencies across the sweep
    std::vector<EmcProbe> probes;     // required: at least one
    int pmlCells = 8;
    int marginCells = 4;
};

struct EmcLevel {
    double cellM = 0.0;
    std::size_t cells = 0;
    int nx = 0, ny = 0, nz = 0;
    double worstShieldingDb = 0.0;
    double worstFrequencyHz = 0.0;
};

struct EmcProbeResult {
    std::string name;
    std::vector<double> shieldingDb; // one per frequency
    double worstShieldingDb = 0.0, worstFrequencyHz = 0.0;
    double fieldVm = 0.0, uncertaintyDb = 0.0;
    double immunityVm = 0.0;
    std::string outcome; // "pass" | "warning" | "fail" | "unknown"
};

struct EmcStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    std::string mesherVersion, levelDescription;
    double fieldVm = 0.0;
    double lowHz = 0.0, highHz = 0.0;
    std::vector<double> frequenciesHz;
    std::vector<EmcProbeResult> probes;
    std::vector<double> resonancesHz;     // where the empty box rings: shielding there is a lower bound
    std::vector<EmcLevel> levels;
    ConvergenceEstimate shieldingConvergence;
    double worstShieldingDb = 0.0, shieldingUncertaintyDb = 0.0, worstFrequencyHz = 0.0;
    double numericalFloorDb = -50.0;
    double smallestOpeningCells = 0.0;  // how well the smallest way in is resolved, in cells
    double wallCells = 0.0;             // how many cells thick the thinnest wall is
    double cellsPerWavelength = 0.0;    // at the highest frequency of the sweep
    double stepS = 0.0;
    int steps = 0;
    StrengthVerdict verdict = StrengthVerdict::Warning;
    std::vector<std::string> failureReasons, reasons, warnings;
    StructuralSurfaceField field;       // geometry only
    std::vector<double> fieldEVm;       // |E| at every surface node, at the worst frequency
};

inline constexpr const char* kEmcSolverID = "cadnext.em.fdtd-yee";

Result<EmcStudyResult> runEmcStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                   const std::string& loadCaseName, const EmcStudySettings& settings, const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
