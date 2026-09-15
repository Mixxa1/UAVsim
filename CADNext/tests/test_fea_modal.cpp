// Modal analysis verification: consistent mass, the eigen-solver's own guarantees, and beam
// vibration theory.
//
// References (Blevins, "Formulas for Natural Frequency and Mode Shape", 1979, tables 8-1, 8-2):
//   f_n = (β_n L)² / (2π L²) · √(E I / (ρ A))
//   cantilever  β_n L = 1.875104, 4.694091, 7.854757; effective mass 61.31 %, 18.82 %, 6.47 %
//   free–free   β_n L = 4.730041, 7.853205 (after six rigid-body modes)
//
// Beam: L = 1 m, section b = 30 mm (y) × h = 20 mm (z), steel. Unequal sides keep the two bending
// planes apart (a square section would give pairs of equal frequencies whose order is arbitrary).
//
// Tolerances, fixed before the first run. Euler–Bernoulli ignores shear and rotary inertia; the
// Timoshenko correction is about ½(β r)²(1 + E/κG) with r = t/√12 the radius of gyration in the
// bending plane (t = h or b): 0.02 %, 0.15 %, 0.42 % for the weak plane, 0.05 %, 0.33 %, 0.94 % for
// the strong. Each tolerance is twice that plus 0.1 % for discretisation:
//   weak 1: 0.15 %   strong 1: 0.2 %   weak 2: 0.4 %   strong 2: 0.8 %   weak 3: 1.0 %   strong 3: 2.0 %
// Found later (test_fea_modal_study): the extrapolated values carry almost no discretisation error
// (GCI ≈ 0.014 %), and the 0.1 % is taken instead by the solid's clamped root face, which cannot
// contract laterally and stiffens the beam by about that much — mode 1 lands at +0.095 % where
// Timoshenko alone predicts −0.02 %. Tolerances unchanged; the free–free checks carry no clamp.
// Clamped roots also slow eigenvalue convergence to an observed order near 2 (formal 4).
// Effective-mass fractions: 0.5 percentage point (beam theory integrates ρAφ, the solid mesh its
// own mass distribution; the clamped root's nodes carry no participation).

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/Modal.hpp"
#include "cadnext/fea/Resonance.hpp"

#include <cmath>
#include <limits>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kLength = 1.0;
constexpr double kWidth = 0.03;  // y
constexpr double kHeight = 0.02; // z

TetMesh beam(int lengthCells, int sectionCells) {
    MappedBlockSpec spec;
    spec.cellsU = lengthCells;
    spec.cellsV = sectionCells;
    spec.cellsW = sectionCells;
    spec.mapping = [](double u, double v, double w) { return Vec3{u * kLength, v * kWidth, w * kHeight}; };
    spec.faceNames = {"root", "tip", "", "", "", ""};
    return generateMappedBlock(spec);
}

ModalSolution solveOrDie(const ModalProblem& problem) {
    const auto result = solveModal(problem);
    if (!result.isOk()) {
        std::printf("  FAIL  modal solver: %s\n", result.error().message.c_str());
        ++fea_test::failures();
        std::exit(fea_test::finish("test_fea_modal"));
    }
    return result.value();
}

double beamFrequency(double betaL, double E, double rho, double I, double A) {
    return betaL * betaL / (2.0 * M_PI * kLength * kLength) * std::sqrt(E * I / (rho * A));
}

// Dominant displacement direction of a mode (1 = y, 2 = z) from its shape.
int bendingPlane(const NaturalMode& mode) {
    double y = 0.0, z = 0.0;
    for (const auto& d : mode.shape) {
        y += d.y * d.y;
        z += d.z * d.z;
    }
    return z > y ? 2 : 1;
}

} // namespace

int main() {
    const auto steel = *findMaterial("steel_4130");
    const double E = steel.youngsModulusPa;
    const double rho = steel.densityKgPerM3;
    const double area = kWidth * kHeight;
    const double Iweak = kWidth * kHeight * kHeight * kHeight / 12.0;   // bending in z
    const double Istrong = kHeight * kWidth * kWidth * kWidth / 12.0;  // bending in y

    // --- Solver guarantees on a small constrained model where every mode can be requested.
    {
        const TetMesh mesh = beam(4, 1);
        ModalProblem problem;
        problem.mesh = &mesh;
        problem.material = steel;
        problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
        problem.modeCount = 1000; // clipped to the free DOFs
        const auto all = solveOrDie(problem);
        check(static_cast<int>(all.modes.size()) == all.freeDofs, "all " + std::to_string(all.freeDofs) + " modes of a small model");
        checkRelative(all.totalMassKg, rho * mesh.volume(), 1e-12, "consistent mass sums to ρV");
        Vec3 effective;
        double worstResidual = 0.0;
        for (const auto& mode : all.modes) {
            effective += mode.effectiveMassKg;
            worstResidual = std::max(worstResidual, mode.residual);
        }
        for (std::size_t i = 0; i < all.modes.size(); i += all.modes.size() / 8) {
            std::printf("  mode %zu: f = %.6g Hz, residual %.3e\n", i + 1, all.modes[i].frequencyHz, all.modes[i].residual);
        }
        for (int d = 0; d < 3; ++d) {
            checkRelative(effective[d], all.freeMassKg[d], 1e-8,
                          std::string("effective masses over all modes add up to the free mass, ") + "xyz"[d]);
        }
        // A backward-stable eigen-solution cannot do better than about ε·κ, κ = λ_max/λ_i; each
        // mode is held to 1000× that. (The first version of this test demanded 1e-8 flat, which the
        // lowest mode of this model, κ ≈ 3.6e8, cannot reach in double precision.)
        const double lambdaMax = all.modes.back().eigenvalue;
        bool allTrue = true;
        double worstRatio = 0.0;
        for (const auto& mode : all.modes) {
            const double attainable = 1e3 * std::numeric_limits<double>::epsilon() * lambdaMax / mode.eigenvalue;
            worstRatio = std::max(worstRatio, mode.residual / attainable);
            allTrue = allTrue && mode.residual <= attainable;
        }
        char residualText[96];
        std::snprintf(residualText, sizeof(residualText), "worst residual %.3e, worst residual/(1000·ε·κ) %.3f", worstResidual, worstRatio);
        check(allTrue, std::string("every eigenpair satisfies K φ = λ M φ to round-off (") + residualText + ")");
        bool ascending = true;
        for (std::size_t i = 1; i < all.modes.size(); ++i) ascending = ascending && all.modes[i].frequencyHz >= all.modes[i - 1].frequencyHz * (1 - 1e-12);
        check(ascending, "frequencies ascend");
    }

    // --- Free–free beam: six rigid-body modes, then the first bending pair.
    {
        const TetMesh mesh = beam(100, 2);
        ModalProblem problem;
        problem.mesh = &mesh;
        problem.material = steel;
        problem.modeCount = 8;
        const auto free = solveOrDie(problem);
        check(!free.constrained, "unsupported beam is solved, not refused");
        double rigidMax = 0.0;
        Vec3 rigidMass;
        for (int i = 0; i < 6; ++i) {
            rigidMax = std::max(rigidMax, free.modes[i].frequencyHz);
            rigidMass += free.modes[i].effectiveMassKg;
        }
        check(rigidMax < 1e-3 * free.modes[6].frequencyHz,
              "six rigid-body modes at zero frequency (largest " + std::to_string(rigidMax) + " Hz vs " + std::to_string(free.modes[6].frequencyHz) + " Hz)");
        checkRelative(rigidMass.z, free.totalMassKg, 1e-6, "rigid-body modes carry the whole mass in z");
        // βL = 4.730 here, so the Timoshenko correction is that of a cantilever's second mode:
        // 0.15 % weak, 0.34 % strong → tolerances 0.4 % and 0.8 %. (The first version of this test
        // used the cantilever first-mode tolerances by mistake and failed the strong plane at
        // 0.32 % — which is the predicted shear/rotary-inertia correction, not a solver error.)
        checkRelative(free.modes[6].frequencyHz, beamFrequency(4.730041, E, rho, Iweak, area), 0.004, "free–free 1st bending, weak plane");
        checkRelative(free.modes[7].frequencyHz, beamFrequency(4.730041, E, rho, Istrong, area), 0.008, "free–free 1st bending, strong plane");
        check(free.modes[6].residual < 1e-6 && free.modes[7].residual < 1e-6,
              "free–free bending shapes converged, not only their frequencies (residual " + std::to_string(free.modes[6].residual) + ")");
    }

    // --- Cantilever: first six modes on three meshes, extrapolated.
    struct Reference {
        double betaL;
        int plane; // 2 = weak (z), 1 = strong (y)
        double tolerance;
        double effectiveFraction; // of the free mass, in the bending direction; 0 = not checked
    };
    const Reference references[6] = {
        {1.875104, 2, 0.0015, 0.6131}, {1.875104, 1, 0.002, 0.6131}, {4.694091, 2, 0.004, 0.1882},
        {4.694091, 1, 0.008, 0.1882},  {7.854757, 2, 0.010, 0.0647}, {7.854757, 1, 0.020, 0.0647},
    };
    std::vector<ModalSolution> levels;
    std::vector<std::size_t> elements;
    for (int k : {1, 2, 4}) {
        const TetMesh mesh = beam(50 * k, k);
        ModalProblem problem;
        problem.mesh = &mesh;
        problem.material = steel;
        problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
        problem.modeCount = 6;
        levels.push_back(solveOrDie(problem));
        elements.push_back(mesh.elements.size());
        std::printf("  mesh %d×%d×%d: %d free DOFs, %d iterations\n", 50 * k, k, k, levels.back().freeDofs, levels.back().iterations);
    }
    for (int i = 0; i < 6; ++i) {
        const auto& r = references[i];
        const double exact = beamFrequency(r.betaL, E, rho, r.plane == 2 ? Iweak : Istrong, area);
        const double coarse = levels[0].modes[i].frequencyHz;
        const double medium = levels[1].modes[i].frequencyHz;
        const double fine = levels[2].modes[i].frequencyHz;
        const auto study = estimateConvergence(fine, medium, coarse, 2.0, 2.0, 1.25, 4.0); // eigenvalue error O(h^2p), p = 2
        const std::string label = "cantilever mode " + std::to_string(i + 1) + (r.plane == 2 ? " (weak plane)" : " (strong plane)");
        fea_test::printConvergence((label + " [Hz]").c_str(), coarse, medium, fine, study);
        check(bendingPlane(levels[2].modes[i]) == r.plane, label + ": bends in the expected plane");
        checkRelative(study.isUsable() ? study.extrapolated : fine, exact, r.tolerance, label + " vs Euler–Bernoulli");
        const double fraction = levels[2].modes[i].effectiveMassKg[r.plane] / levels[2].freeMassKg[r.plane];
        check(std::fabs(fraction - r.effectiveFraction) < 0.005,
              label + ": effective mass " + std::to_string(fraction * 100) + " % (beam theory " + std::to_string(r.effectiveFraction * 100) + " %)");
    }

    // --- Attached equipment mass: the cantilever with a tip mass equal to its own mass.
    // Euler–Bernoulli with a tip mass M (Blevins 1979, table 8-1): the first root of
    //   1 + cos λ cosh λ + (M / m_b) λ (cos λ sinh λ − sin λ cosh λ) = 0,   λ = βL.
    // Tolerance 0.1 % on the ratio f(tip mass) / f(bare) from the same mesh: the clamp, shear and
    // mesh biases enter both and cancel to far below that; what remains is the tip mass being spread
    // over a 20 mm end face instead of a point (rotary inertia ~ (h/L)²/12 ≈ 3·10⁻⁵).
    {
        const TetMesh mesh = beam(200, 4);
        ModalProblem bare;
        bare.mesh = &mesh;
        bare.material = steel;
        bare.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
        bare.modeCount = 1;
        const auto bareSolution = solveOrDie(bare);
        const double beamMass = rho * area * kLength;
        ModalProblem loaded = bare;
        loaded.attachedMasses.push_back({"tip", beamMass});
        const auto loadedSolution = solveOrDie(loaded);

        auto characteristic = [](double lambda, double ratio) {
            return 1.0 + std::cos(lambda) * std::cosh(lambda)
                   + ratio * lambda * (std::cos(lambda) * std::sinh(lambda) - std::sin(lambda) * std::cosh(lambda));
        };
        double lo = 0.1, hi = 1.875104;
        for (int i = 0; i < 200; ++i) {
            const double mid = 0.5 * (lo + hi);
            if ((characteristic(lo, 1.0) > 0) == (characteristic(mid, 1.0) > 0)) lo = mid; else hi = mid;
        }
        const double lambda = 0.5 * (lo + hi);
        const double theoryRatio = (lambda * lambda) / (1.875104 * 1.875104);
        const double feRatio = loadedSolution.modes[0].frequencyHz / bareSolution.modes[0].frequencyHz;
        std::printf("  tip mass = beam mass: βL %.6f, f %.4f → %.4f Hz, ratio %.6f (theory %.6f)\n", lambda,
                    bareSolution.modes[0].frequencyHz, loadedSolution.modes[0].frequencyHz, feRatio, theoryRatio);
        checkRelative(feRatio, theoryRatio, 0.001, "tip mass: frequency ratio vs Euler–Bernoulli with tip mass");
        checkRelative(loadedSolution.attachedMassKg, beamMass, 1e-12, "attached mass reported");
        checkRelative(loadedSolution.totalMassKg, bareSolution.totalMassKg, 1e-12, "structural mass unchanged by equipment");
        checkRelative(loadedSolution.freeMassKg.z, bareSolution.freeMassKg.z + beamMass, 1e-9,
                      "the attached mass is all on free DOFs: free mass grows by exactly M");
        ModalProblem missing = bare;
        missing.attachedMasses.push_back({"no-such-face", 1.0});
        check(!solveModal(missing).isOk(), "attached mass on a missing face is refused");
    }

    // --- Resonance classification.
    {
        const auto bands = rotorExcitationBands({"rotor", 6000.0, 7200.0, 2});
        check(bands.size() == 2 && bands[0].minimumHz == 100.0 && bands[0].maximumHz == 120.0 && bands[1].minimumHz == 200.0
                  && bands[1].maximumHz == 240.0,
              "rotor bands: 1P = RPM/60, NP = N·RPM/60");
        // Spec §6.2 example: mode at 121 Hz, excitation 118–126 Hz.
        const auto spec = assessResonance({121.0}, {0.0}, {{"propeller", 118.0, 126.0}}, 0.0);
        check(spec.size() == 1 && spec[0].overlaps && spec[0].separation < 0.0, "spec example: 121 Hz inside 118–126 Hz overlaps");
        const auto clear = assessResonance({130.0}, {0.0}, {{"propeller", 118.0, 126.0}}, 0.0);
        check(!clear[0].overlaps && std::fabs(clear[0].separation - 4.0 / 130.0) < 1e-12, "130 Hz: clear by 4 Hz, reported as a fraction");
        const auto uncertain = assessResonance({130.0}, {5.0}, {{"propeller", 118.0, 126.0}}, 0.0);
        check(uncertain[0].overlaps, "130 ± 5 Hz: the mesh cannot rule the resonance out → overlap");
        const auto margin = assessResonance({130.0}, {0.0}, {{"propeller", 118.0, 126.0}}, 0.05);
        check(margin[0].overlaps, "a 5 % separation margin widens 118–126 to 112.1–132.3 Hz → overlap");
        const auto nearest = assessResonance({150.0}, {0.0}, bands, 0.0);
        check(nearest[0].band == "rotor 1P" && std::fabs(nearest[0].separation - 30.0 / 150.0) < 1e-12,
              "nearest band is chosen (150 Hz: 1P ends 30 Hz below, 2P starts 50 Hz above)");
    }

    return fea_test::finish("test_fea_modal");
}
