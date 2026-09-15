#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/Modal.hpp"
#include "cadnext/fea/Resonance.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <array>
#include <string>
#include <vector>

// Natural frequencies of a CAD solid as an Engineering Validation test (spec §6.2 Modal /
// Vibration): three meshes, each frequency with its discretisation uncertainty, the modes checked
// against excitation bands.
//
// Supports are optional. A part without them is analysed free–free — the right model for an
// airframe in flight — and its six rigid-body modes are left out of the reported modes.

namespace cadnext::fea {

struct ModalStudySettings {
    double coarseElementSizeM = 0.0; // required, as for the static study
    double refinementFactor = 0.0;   // required, ≥ 1.3
    int modeCount = 0;               // flexible modes wanted
    std::vector<ExcitationBand> bands;
    double separationMargin = 0.0;
    // Equipment carried by faces ("face-<index>"), see AttachedMass.
    std::vector<AttachedMass> attachedMasses;
};

struct ModalStudyMode {
    double frequencyHz = 0.0;         // finest mesh
    ConvergenceEstimate convergence;  // over the three meshes, formal order 4
    // Band used against excitation: the GCI when the convergence is usable, otherwise the
    // difference between the two finest meshes.
    double resonanceUncertaintyHz = 0.0;
    Vec3 effectiveMassFraction;       // of the free mass, per direction
};

struct ModalSurfaceField {
    std::vector<Vec3> nodes;
    std::vector<std::array<int, 3>> triangles;
    std::vector<std::string> triangleFace;
    // One shape per reported mode, on the surface nodes, scaled so the largest displacement is 1.
    std::vector<std::vector<Vec3>> shapes;
};

struct ModalStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    std::string mesherVersion;
    bool constrained = true;
    double totalMassKg = 0.0;
    double attachedMassKg = 0.0;
    std::vector<double> levelElementSizes;
    std::vector<std::size_t> levelElements;
    std::vector<std::vector<double>> levelFrequencies; // per level, the reported (flexible) modes
    std::vector<ModalStudyMode> modes;
    std::vector<ResonanceFinding> resonance;
    std::vector<ExcitationBand> bands;
    double separationMargin = 0.0;
    std::vector<std::string> warnings;
    bool resonanceOverlap = false;
    bool uncertaintyUnknown = false; // some frequency did not converge monotonically
    // Bands reaching above the last computed mode: a higher mode could lie in them unseen.
    std::vector<std::string> uncheckedBands;
    ModalSurfaceField field;
};

inline constexpr const char* kModalSolverID = "cadnext.fea.modal-tet10";

Result<ModalStudyResult> runModalStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                                       const IsotropicMaterial& material, const std::string& loadCaseName,
                                       const std::vector<FaceSupport>& supports, const ModalStudySettings& settings,
                                       const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
