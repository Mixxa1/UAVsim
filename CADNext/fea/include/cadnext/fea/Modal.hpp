#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/LinearStatic.hpp"

#include <vector>

// Natural frequencies and mode shapes (spec §6.2): K φ = ω² M φ with the consistent TET10 mass.
//
// Subspace iteration with a shift (Bathe, "Finite Element Procedures", §11.6): one sparse Cholesky
// of K − σM, then repeated inverse iteration on a block of vectors with Rayleigh–Ritz projection.
// Chosen over Lanczos for robustness — no loss of orthogonality to manage — at the cost of speed
// that the few modes a UAV part needs do not notice. Iterations are counted, never timed.
//
// Unconstrained parts are allowed: their six rigid-body modes come out at (numerically) zero
// frequency, which the tests use as a check.

namespace cadnext::fea {

// Equipment carried by a face — a battery on a plate, a camera on a bracket. Its mass is spread over
// the face as a uniform areal density and lumped to the face's nodes with the nodal shares of a
// uniform load (∫ N dA), so the total is exact on any mesh. Translational inertia only: the
// equipment's own rotary inertia and stiffness are not represented, which suits a compact part
// bearing on a face, not a mass hanging off a long bracket.
struct AttachedMass {
    std::string faceGroup;
    double massKg = 0.0;
};

struct ModalProblem {
    const TetMesh* mesh = nullptr;
    IsotropicMaterial material;
    std::vector<DisplacementConstraint> constraints; // values must be zero (a support, not a load)
    std::vector<AttachedMass> attachedMasses;
    int modeCount = 10;
};

struct ModalSettings {
    int maximumIterations = 200;
    // Relative change of every requested eigenvalue between iterations.
    double tolerance = 1.0e-10;
    // ‖(K − σM)φ − μMφ‖ / ‖μMφ‖ of every requested mode (bounded below by round-off, ε·κ). The
    // eigenvalue error is of the order of its square, so 1e-6 already means frequencies to ~1e-12.
    double residualTolerance = 1.0e-6;
};

struct NaturalMode {
    double frequencyHz = 0.0;
    double eigenvalue = 0.0; // ω², rad²/s²
    // Mass-normalised: φᵀ M φ = 1 (units 1/√kg).
    std::vector<Vec3> shape;
    // Participation Γ_d = φᵀ M r_d and effective mass Γ_d² for unit translations r_d along x, y, z,
    // over the free DOFs. Their sums over all modes are the mass of the free DOFs in each direction.
    Vec3 participation;
    Vec3 effectiveMassKg;
    // ‖K φ − λ M φ‖ / ‖λ M φ‖ — how true the eigenpair is, independent of the iteration.
    double residual = 0.0;
};

struct ModalSolution {
    std::vector<NaturalMode> modes; // ascending frequency
    double totalMassKg = 0.0;       // ρ·V of the whole mesh
    double attachedMassKg = 0.0;    // Σ attached equipment (not part of totalMassKg)
    Vec3 freeMassKg;                // r_dᵀ M_ff r_d: what the effective masses add up to
    int totalDofs = 0;
    int freeDofs = 0;
    int iterations = 0;
    bool constrained = true; // false: rigid-body modes are among the results
};

Result<ModalSolution> solveModal(const ModalProblem& problem, const ModalSettings& settings = {});

} // namespace cadnext::fea
