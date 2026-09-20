// A bird into a part: the load it makes, and what the part does about it.
//
// Criteria, fixed before the first run:
//   1. The load carries the bird. Whatever shape the pressure takes, the impulse it delivers must be
//      the bird's own normal momentum m·u·sin θ to 1e-12 relative — that is imposed by construction
//      and this check is what makes sure the construction holds. The shock pressure must be the
//      Hugoniot jump ρ(c₀ + k u)u and the steady one the stagnation ½ρu², both to round-off, and the
//      cylinder's geometry must give back the mass it was made from.
//   2. The quasi-static limit. Push the same patch with a force that rises over a hundred first
//      periods and the part cannot tell it from a static load: the peak stress must be the static
//      solver's answer to 2 %.
//   3. The impulsive end. Hit the same patch with a spike twenty times shorter than the fastest mode
//      kept and the history the solver integrates must carry exactly the impulse it was handed, to
//      1e-9. (This file first proposed comparing the peak stress with the superposition of the
//      closed-form modal peaks q = p·I/ω. That is not a check but a second implementation of the
//      same sum, and a loose one — the modes do not peak together, so it can only bound. The two
//      ends that are checked instead pin the solver from both sides: the static limit against the
//      static solver, exactly, and the impulse against arithmetic.)
//   4. Scaling. Twice the force is twice the stress: the model is linear and must say so. This file
//      first asked for it "to the last digit" (1e-9) and that criterion was wrong — it demanded a
//      determinism the modal solver does not have. Each call re-solves the modes iteratively through
//      a multithreaded BLAS, and two calls on identical input were measured to differ by up to 2e-9
//      relative on the first eigenvalue, which lands as ~1e-9 on the stress; the check failed about
//      once in three runs for that reason alone. The criterion is now 1e-7: two orders above the
//      measured scatter, so it cannot flake, and four orders below anything a real loss of linearity
//      would do (that shows up in percent). Both numbers are printed so the residue stays visible.
//   5. Refusals: no damping, no modes, no face, a bird with no speed.

#include "fea_test_support.hpp"

#include "cadnext/fea/BirdStrike.hpp"
#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/MeshGeneration.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>

using namespace cadnext::fea;
using fea_test::check;

namespace {

TetMesh box(double lx, double ly, double lz, int cx, int cy, int cz, const std::array<std::string, 6>& names) {
    MappedBlockSpec spec;
    spec.cellsU = cx, spec.cellsV = cy, spec.cellsW = cz;
    spec.mapping = [=](double u, double v, double w) { return Vec3{u * lx, v * ly, w * lz}; };
    spec.faceNames = names;
    return generateMappedBlock(spec);
}

} // namespace

int main() {
    const auto material = *findMaterial("al_6061_t6");

    // --- 1. The load.
    {
        BirdModel bird;
        bird.massKg = 1.81;
        bird.speedMps = 90.0;
        const auto impact = birdImpact(bird);
        check(impact.isOk(), "the bird's load is built", impact.isOk() ? "" : impact.error().message);
        if (impact.isOk()) {
            const auto& i = impact.value();
            const double volume = M_PI * i.diameterM * i.diameterM / 4.0 * i.lengthM;
            const double hugoniot = bird.densityKgM3 * (bird.shockSpeedMps + bird.shockSlope * i.normalSpeedMps) * i.normalSpeedMps;
            const double steady = 0.5 * bird.densityKgM3 * i.normalSpeedMps * i.normalSpeedMps;
            // The impulse by quadrature over the history the solver will actually sample.
            const int samples = 2000001;
            double impulse = 0.0;
            for (int s = 1; s < samples; ++s) {
                const double a = i.totalDurationS * (s - 1) / (samples - 1), b = i.totalDurationS * s / (samples - 1);
                impulse += 0.5 * (i.forceAt(a) + i.forceAt(b)) * (b - a);
            }
            std::printf("  bird: %.3f kg at %.0f m/s → cylinder %.1f × %.1f mm, area %.1f cm², Hugoniot %.2f MPa, steady %.3f MPa\n", bird.massKg,
                        bird.speedMps, i.diameterM * 1e3, i.lengthM * 1e3, i.areaM2 * 1e4, i.hugoniotPressurePa / 1e6, i.steadyPressurePa / 1e6);
            std::printf("  phases: shock %.1f µs, decay %.1f µs, steady %.1f µs, total %.1f µs against L/u = %.1f µs; impulse %.6f N·s of %.6f\n",
                        i.shockDurationS * 1e6, i.decayDurationS * 1e6, i.steadyDurationS * 1e6, i.totalDurationS * 1e6, i.geometricDurationS * 1e6, impulse,
                        i.normalMomentumNs);
            check(std::fabs(volume * bird.densityKgM3 / bird.massKg - 1.0) <= 1e-12, "the cylinder weighs what the bird weighs");
            check(std::fabs(i.hugoniotPressurePa / hugoniot - 1.0) <= 1e-15 && std::fabs(i.steadyPressurePa / steady - 1.0) <= 1e-15,
                  "the shock pressure is the Hugoniot jump and the steady one the stagnation pressure");
            check(std::fabs(impulse / i.normalMomentumNs - 1.0) <= 1e-9, "the load carries exactly the bird's normal momentum");
        }
        // Obliquity takes only the normal component, and a bird with no speed is refused.
        BirdModel oblique = bird;
        oblique.obliquityRad = M_PI / 6.0; // 30°
        const auto slanted = birdImpact(oblique);
        check(slanted.isOk() && std::fabs(slanted.value().normalSpeedMps / (bird.speedMps * 0.5) - 1.0) <= 1e-12
                  && std::fabs(slanted.value().normalMomentumNs / (bird.massKg * bird.speedMps * 0.5) - 1.0) <= 1e-12,
              "at 30° only half the speed is normal, and the momentum follows it");
        BirdModel still = bird;
        still.speedMps = 0.0;
        check(!birdImpact(still).isOk(), "a bird at rest is refused");
    }

    // --- The part every response check uses: a clamped plate, hit on its top face.
    const double lx = 0.30, ly = 0.20, lz = 0.006;
    const TetMesh mesh = box(lx, ly, lz, 10, 7, 2, {"root", "tip", "side", "side", "bottom", "top"});
    std::vector<DisplacementConstraint> clamp(1);
    clamp[0].nodes = mesh.nodesOnGroup("root");
    clamp[0].value = {0.0, 0.0, 0.0};

    BirdStrikeProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    problem.constraints = clamp;
    problem.impactFaceGroup = "top";
    problem.direction = {0.0, 0.0, -1.0};
    problem.dampingRatio = 0.02;
    problem.modeCount = 12;

    // --- 2. The quasi-static limit.
    {
        const auto modal = solveModal({&mesh, material, clamp, {}, 3});
        check(modal.isOk(), "the plate's modes are found", modal.isOk() ? "" : modal.error().message);
        if (!modal.isOk()) return fea_test::finish("test_fea_bird_strike");
        const double firstPeriod = 1.0 / modal.value().modes.front().frequencyHz;
        const double force = 500.0;
        BirdStrikeProblem slow = problem;
        // Up over fifty periods, held for fifty more: as static as a transient can be.
        slow.forceHistory = {{0.0, 0.0}, {50.0 * firstPeriod, force}, {100.0 * firstPeriod, force}};
        BirdStrikeSettings settings;
        settings.residualPeriods = 0.5;
        const auto ran = solveBirdStrike(slow, settings);
        check(ran.isOk(), "the slow push runs", ran.isOk() ? "" : ran.error().message);

        // The same force, statically.
        LinearStaticProblem statics;
        statics.mesh = &mesh;
        statics.material = material;
        statics.constraints = clamp;
        SurfaceTraction traction;
        traction.faceGroup = "top";
        const double area = faceGroupArea(mesh, "top");
        traction.tractionPa = {0.0, 0.0, -force / area};
        statics.tractions = {traction};
        const auto stat = solveLinearStatic(statics);
        check(stat.isOk(), "the static reference solves", stat.isOk() ? "" : stat.error().message);
        if (ran.isOk() && stat.isOk()) {
            std::printf("  quasi-static: %.4f MPa dynamic against %.4f MPa static (%+.3f %%), first period %.3f ms\n", ran.value().peakVonMisesPa / 1e6,
                        stat.value().maxNodalVonMisesPa / 1e6, 100.0 * (ran.value().peakVonMisesPa / stat.value().maxNodalVonMisesPa - 1.0), firstPeriod * 1e3);
            check(std::fabs(ran.value().peakVonMisesPa / stat.value().maxNodalVonMisesPa - 1.0) <= 0.02,
                  "a load slow against the part's own periods gives the static answer");
        }
    }

    // --- 3, 4. The impulsive limit and linearity.
    {
        const auto modal = solveModal({&mesh, material, clamp, {}, problem.modeCount});
        if (!modal.isOk()) return fea_test::finish("test_fea_bird_strike");
        const double firstPeriod = 1.0 / modal.value().modes.front().frequencyHz;
        const double lastPeriod = 1.0 / modal.value().modes.back().frequencyHz;
        const double spike = 0.05 * lastPeriod; // short against every mode kept
        const double peak = 20000.0;
        BirdStrikeProblem sharp = problem;
        sharp.dampingRatio = 0.0;
        sharp.forceHistory = {{0.0, 0.0}, {0.5 * spike, peak}, {spike, 0.0}};
        BirdStrikeSettings settings;
        settings.residualPeriods = 1.5;
        const auto ran = solveBirdStrike(sharp, settings);
        check(ran.isOk(), "the spike runs", ran.isOk() ? "" : ran.error().message);
        if (ran.isOk()) {
            const double impulse = 0.5 * peak * spike;
            std::printf("  impulsive: spike %.1f µs against the fastest period %.1f µs, impulse %.4f N·s (solver says %.4f), peak %.3f MPa\n", spike * 1e6,
                        lastPeriod * 1e6, impulse, ran.value().impulseNs, ran.value().peakVonMisesPa / 1e6);
            check(std::fabs(ran.value().impulseNs / impulse - 1.0) <= 1e-9, "the solver's own history carries the impulse it was given");
            // Twice the force is twice the answer.
            BirdStrikeProblem twice = sharp;
            for (auto& point : twice.forceHistory) point.second *= 2.0;
            const auto doubled = solveBirdStrike(twice, settings);
            if (doubled.isOk()) {
                std::printf("  linearity: %.17g against %.17g (%+.3e relative); first eigenvalue %.17g against %.17g (%+.3e)\n",
                            doubled.value().peakVonMisesPa, 2.0 * ran.value().peakVonMisesPa,
                            doubled.value().peakVonMisesPa / (2.0 * ran.value().peakVonMisesPa) - 1.0,
                            doubled.value().modal.modes.front().eigenvalue, ran.value().modal.modes.front().eigenvalue,
                            doubled.value().modal.modes.front().eigenvalue / ran.value().modal.modes.front().eigenvalue - 1.0);
            }
            check(doubled.isOk() && std::fabs(doubled.value().peakVonMisesPa / (2.0 * ran.value().peakVonMisesPa) - 1.0) <= 1e-7,
                  "twice the force is twice the stress, to the modal solver's own reproducibility");
        }
    }

    // --- 5. Refusals.
    {
        auto refused = [&](BirdStrikeProblem p, const std::string& reason) {
            const auto run = solveBirdStrike(p);
            if (run.isOk()) return false;
            return run.error().message.find(reason) != std::string::npos;
        };
        BirdStrikeProblem noDamping = problem;
        noDamping.dampingRatio = -1.0;
        noDamping.bird.speedMps = 90.0;
        BirdStrikeProblem noModes = problem;
        noModes.modeCount = 0;
        noModes.bird.speedMps = 90.0;
        BirdStrikeProblem noFace = problem;
        noFace.impactFaceGroup.clear();
        noFace.bird.speedMps = 90.0;
        BirdStrikeProblem noSpeed = problem;
        check(refused(noDamping, "демпфирование") && refused(noModes, "число мод") && refused(noFace, "грань удара") && refused(noSpeed, "скорость удара"),
              "no damping, no modes, no face and a bird with no speed are each refused for their own reason");
    }
    return fea_test::finish("test_fea_bird_strike");
}
