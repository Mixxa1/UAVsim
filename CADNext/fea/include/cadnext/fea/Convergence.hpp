#pragma once

#include <cstddef>
#include <string>

// Discretisation error from a systematic mesh refinement — Richardson extrapolation and the
// Grid Convergence Index of Roache (1994, 1998), in the three-grid form of Celik et al.,
// "Procedure for Estimation and Reporting of Uncertainty Due to Discretization in CFD
// Applications", J. Fluids Eng. 130 (2008) 078001.
//
// This is what turns "max stress 128 MPa" into "128 MPa ± 1.2 MPa from the mesh", and what
// notices that a stress at a re-entrant corner or a point support does not converge at all.

namespace cadnext::fea {

enum class ConvergenceBehaviour {
    // Differences shrink with refinement and keep their sign: extrapolation is meaningful.
    Monotonic,
    // Differences change sign. Order and extrapolation are not reliable; the spread of the
    // three values is reported instead.
    Oscillatory,
    // Differences grow with refinement: typically a singularity. There is no converged value.
    Divergent,
    // Fine and medium solutions agree to round-off.
    Converged,
};

struct ConvergenceEstimate {
    ConvergenceBehaviour behaviour = ConvergenceBehaviour::Divergent;
    double fine = 0.0;
    double observedOrder = 0.0;
    double extrapolated = 0.0;
    // Relative GCI of the fine solution (Fs = 1.25) — a band, not a bias.
    double gciFineRelative = 0.0;
    // GCI_fine in the units of the value.
    double uncertaintyAbsolute = 0.0;
    // GCI_coarse / (r^p · GCI_fine): ≈ 1 inside the asymptotic range.
    double asymptoticRatio = 0.0;
    // The observed order exceeded the element's formal order, so extrapolation and GCI used the
    // formal one (Roache, "Verification and Validation in Computational Science and
    // Engineering", 1998, §5.9: an observed order above the theoretical one is not evidence of
    // faster convergence, only of meshes that are not geometrically similar — typical of
    // unstructured refinement — and taken at face value it shrinks the band to nothing).
    bool orderLimitedToFormal = false;

    bool isUsable() const {
        return behaviour == ConvergenceBehaviour::Monotonic || behaviour == ConvergenceBehaviour::Converged;
    }
    std::string describe() const;
};

// `fine`, `medium`, `coarse` from meshes refined by the constant ratio r = h_coarse/h_medium
// = h_medium/h_fine (> 1).
ConvergenceEstimate estimateConvergence(double fine, double medium, double coarse, double refinementRatio,
                                        double safetyFactor = 1.25);

// Unstructured meshes are not refined by a constant ratio: r21 = h_medium/h_fine and
// r32 = h_coarse/h_medium differ, and the observed order comes from the fixed-point iteration
// of Celik et al. eqs. (3)–(5). The iteration count is bounded, never timed.
ConvergenceEstimate estimateConvergence(double fine, double medium, double coarse, double ratioMediumToFine,
                                        double ratioCoarseToMedium, double safetyFactor);

// Same, with the formal order of accuracy of the quantity as an upper bound on p. For TET10:
// 3 for displacements, 2 for stresses (quadratic displacement, linear stress interpolation).
ConvergenceEstimate estimateConvergence(double fine, double medium, double coarse, double ratioMediumToFine,
                                        double ratioCoarseToMedium, double safetyFactor, double formalOrder);

inline constexpr double kTet10DisplacementOrder = 3.0;
inline constexpr double kTet10StressOrder = 2.0;
// Eigenvalues converge at twice the displacement order in energy, O(h^2p) (Strang & Fix, "An
// Analysis of the Finite Element Method", §6.3); so do frequencies, their square roots.
inline constexpr double kTet10EigenvalueOrder = 4.0;

// Representative cell size of a 3D mesh, h = (V / N)^(1/3) (Celik et al. eq. 1).
double representativeCellSize(double volume, std::size_t elementCount);

} // namespace cadnext::fea
