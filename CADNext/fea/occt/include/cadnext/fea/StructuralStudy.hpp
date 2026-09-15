#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/FeaTypes.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

#include <array>
#include <functional>
#include <string>
#include <vector>

namespace cadnext::kernel {
class OcctKernel;
}

// One structural load case on one CAD solid, answered the way spec §6.1 asks: a stress, how
// far the mesh can be trusted, and a verdict — never a single-mesh number.
//
// The study meshes the part three times (element size h, h/f, h/f²), solves each, estimates
// discretisation error on the maximum von Mises stress and the maximum displacement with the
// order bounded by TET10's formal order, and assesses strength at limit load (CS-23.305).

namespace cadnext::fea {

// Faces are the kernel's face ids ("face-<index>").
struct FaceSupport {
    std::string face;
    // x, y, z held at zero.
    std::array<bool, 3> fixed{true, true, true};
};

// A resultant force spread uniformly over the face area (a distributed load, not a bearing
// or bolt load — those concentrate and need their own modelling).
struct FaceForce {
    std::string face;
    Vec3 totalForceN;
};

struct FacePressure {
    std::string face;
    double pressurePa = 0.0; // positive pushes into the part
};

// Nodes closer than `distanceM` to a face are left out of the stress maximum. For use where a
// support or load idealisation creates a stress that does not exist in the real part; recorded
// in the result so nobody mistakes the excluded maximum for the whole-part one.
struct StressExclusion {
    std::string face;
    double distanceM = 0.0;
};

struct StructuralLoadCase {
    std::string name;
    std::vector<FaceSupport> supports;
    std::vector<FaceForce> forces;
    std::vector<FacePressure> pressures;
    Vec3 bodyAccelerationMps2;
    std::vector<StressExclusion> stressExclusions;
};

struct StructuralStudySettings {
    // Both required, no defaults: they decide how much the study costs and how well it resolves
    // the part, which is the analyst's call. Celik et al. recommend a factor of at least 1.3.
    double coarseElementSizeM = 0.0;
    double refinementFactor = 0.0;
    StrengthCriteria criteria;
};

struct StructuralStudyLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    int dofs = 0;
    double maxVonMisesPa = 0.0;
    double maxDisplacementM = 0.0;
    Vec3 criticalPoint;
};

// Boundary of the finest mesh, for display: corner/midside nodes and the four linear triangles
// of every six-node face.
struct StructuralSurfaceField {
    std::vector<Vec3> nodes;
    std::vector<Vec3> displacement;
    std::vector<double> vonMisesPa;
    std::vector<std::array<int, 3>> triangles;
    std::vector<std::string> triangleFace;
};

struct StructuralStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    double factorOfSafety = 1.5;
    std::string mesherVersion;
    double cadVolumeM3 = 0.0;
    std::vector<StructuralStudyLevel> levels;
    ConvergenceEstimate stressConvergence;
    ConvergenceEstimate displacementConvergence;
    StrengthAssessment assessment;
    Vec3 criticalPoint;
    std::string criticalFace; // empty when the maximum is inside the part
    std::vector<std::string> warnings;
    StructuralSurfaceField field;
};

inline constexpr const char* kStructuralSolverID = "cadnext.fea.linear-static-tet10";
// 2: modal jobs accept attached equipment masses (older solvers ignore the key silently, so the
// Workbench checks that a result echoes the masses it was given).
inline constexpr int kStructuralSolverVersion = 2;

// Reported before each step of the study: level 0…2 and "mesh" or "solve".
using StructuralStudyProgress = std::function<void(int level, const char* stage)>;

Result<StructuralStudyResult> runStructuralStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                                                 const IsotropicMaterial& material, const StructuralLoadCase& loadCase,
                                                 const StructuralStudySettings& settings,
                                                 const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
