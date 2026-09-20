#pragma once

// Internal: what the sine and the random vibration solvers share — the constrained system with its
// unit load pattern, and the superposition basis (static correction + modes) with the stress and
// displacement of every basis vector at every node. Not part of the public fea API.

#include "cadnext/fea/Harmonic.hpp"

#include "SystemAssembly.hpp"

#include <array>
#include <complex>
#include <optional>
#include <string>
#include <vector>

namespace cadnext::fea::detail {

struct ResponseSystem {
    const TetMesh* mesh = nullptr;
    int nodeCount = 0;
    DofMap map;
    SymmetricCsc K, M;
    std::array<std::array<double, 6>, 6> elasticity{};
    std::vector<double> P;           // reduced load of a unit amplitude (1 m/s² of base motion, or 1 N)
    std::vector<double> probeWeights; // per node, normalised to 1; empty without a probe
    Vec3 direction;                  // unit
    bool base = true;
    std::vector<bool> stressExcluded; // empty: none

    bool counts(int node) const { return stressExcluded.empty() || !stressExcluded[node]; }
    std::vector<Vec3> toFull(const double* reduced) const;
    Vec3 probeOf(const std::vector<Vec3>& field) const;
};

// Validates the geometry, fixture and excitation shape (not its amplitude) and assembles the system.
// The message on failure.
std::optional<std::string> buildResponseSystem(const HarmonicProblem& problem, ResponseSystem& system);

struct ResponseBasis {
    ModalSolution modal;
    bool staticCorrection = true;
    int J = 0;      // basis vectors: [static response], modes
    int offset = 0; // 1 with the static correction
    std::vector<double> modalLoad; // φ_rᵀ P
    // Column-major, one column per basis vector: 6 stress components per node, 3 displacements.
    std::size_t stressRows = 0, motionRows = 0;
    std::vector<double> stressBasis, motionBasis;
    std::vector<Vec3> probeBasis;
    double effectiveMassFraction = 0.0; // NaN for a force
    double highestModeHz = 0.0;

    // Complex coefficient of every basis vector for a unit amplitude at angular frequency ω.
    void coefficients(double omega, double dampingRatio, double* real, double* imaginary) const;
};

std::optional<std::string> buildResponseBasis(const ResponseSystem& system, const HarmonicProblem& problem, const ModalSettings& modal,
                                              bool staticCorrection, ResponseBasis& basis);

} // namespace cadnext::fea::detail
