#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/FeaTypes.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/TetMesh.hpp"

#include <array>
#include <optional>
#include <string>
#include <vector>

namespace cadnext::fea {

struct DisplacementConstraint {
    std::vector<int> nodes;
    // Prescribed value per component; empty components are free.
    std::array<std::optional<double>, 3> value;
};

// Constant traction vector (Pa) over a face group.
struct SurfaceTraction {
    std::string faceGroup;
    Vec3 tractionPa;
};

// Pressure (Pa) over a face group, acting along the local normal: positive pushes *into*
// the body (traction = −p·n), negative pulls outward. Follows curved faces point by point.
struct SurfacePressure {
    std::string faceGroup;
    double pressurePa = 0.0;
};

struct NodalForce {
    int node = 0;
    Vec3 forceN;
};

struct LinearStaticProblem {
    const TetMesh* mesh = nullptr;
    IsotropicMaterial material;
    std::vector<DisplacementConstraint> constraints;
    std::vector<SurfaceTraction> tractions;
    std::vector<SurfacePressure> pressures;
    std::vector<NodalForce> nodalForces;
    // Inertial/body load as an acceleration field (m/s²), applied as ρ·a to every element:
    // gravity is (0, 0, −9.81), a 3.5 g pull-up load case is 3.5 times that.
    Vec3 bodyAcceleration;
};

enum class LinearSolverKind {
    // Sparse Cholesky from Apple Accelerate. The production path.
    AccelerateCholesky,
    // Jacobi-preconditioned conjugate gradients, written here. Exists as an independent
    // cross-check of the direct solver, not for speed.
    JacobiConjugateGradient,
};

struct LinearStaticSettings {
    LinearSolverKind solver = LinearSolverKind::AccelerateCholesky;
    // Iterative solver only. A count, never a wall-clock budget: the same problem must give
    // the same answer on a loaded machine.
    int maximumIterations = 200000;
    double relativeTolerance = 1.0e-12;
};

struct LinearStaticSolution {
    std::vector<Vec3> displacement;
    // Quadrature-point stresses extrapolated to corners, midsides from their edge, then
    // averaged over the elements sharing the node.
    std::vector<Voigt> nodalStress;
    std::vector<double> nodalVonMises;
    double maxNodalVonMisesPa = 0.0;
    int maxNodalVonMisesNode = -1;
    // Unaveraged quadrature-point maximum. Its distance from the averaged maximum is a
    // cheap local indicator of discretisation error.
    double maxQuadratureVonMisesPa = 0.0;
    int maxQuadratureVonMisesElement = -1;
    double maxDisplacementM = 0.0;
    int maxDisplacementNode = -1;
    // Sum of all consistent external nodal forces, and of the support reactions.
    Vec3 appliedForceN;
    Vec3 reactionForceN;
    double strainEnergyJ = 0.0;
    // ‖f_int − f_ext‖ over free DOFs relative to ‖f_int‖ over all DOFs: what the linear
    // solve left behind.
    double freeResidualRelative = 0.0;
    int totalDofs = 0;
    int freeDofs = 0;
    int solverIterations = 0;
};

Result<LinearStaticSolution> solveLinearStatic(const LinearStaticProblem& problem,
                                               const LinearStaticSettings& settings = {});

// Area of a face group as the elements represent it (curved faces included), m². Zero for an
// unknown group.
double faceGroupArea(const TetMesh& mesh, const std::string& group);

} // namespace cadnext::fea
