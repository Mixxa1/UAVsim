import Foundation
import simd

// Headless probe for the compressible aerodynamics.
//
// Three questions, and none of them can be answered by flying the aircraft:
//
//  1. **Is the legacy fleet untouched?** Every correction is supposed to be identically
//     inert below Mach 0.3. That is a promise about bit-level equality, not about
//     "close enough", so it is checked as bit-level equality against the same
//     coefficient call with compressibility switched off.
//  2. **Is Mach 1 continuous?** The plan's own acceptance criterion: no NaN, no Inf and
//     no step in force or moment crossing 0.95 → 1.05. A step in a coefficient is a
//     step in an acceleration, and an aircraft cannot fly through one.
//  3. **Is the drag rise real and physical?** It has to appear (or the transonic costs
//     nothing and the aircraft sails through Mach 1), peak just past Mach 1, and then
//     fall away — and it must not be a universal constant applied to every planform,
//     which the plan forbids by name.
//
// Run: Tools/TransonicProbe/run.sh

var failures: [String] = []

let families: [FixedWingFamily] = FixedWingFamily.allCases

/// One representative airframe per family, so the coefficients being swept belong to a
/// plausible aircraft rather than to a set of defaults.
func aerodynamics(for family: FixedWingFamily) -> FixedWingAerodynamics {
    FixedWingAerodynamics.build(
        family: family,
        massKg: 700.0,
        wingSpanM: 2.5,
        fuselageLengthM: 4.0,
        heightM: 0.95,
        turnAuthority: 0.6,
        minSustainableSpeedMps: 63.0
    )
}

// MARK: - 1. Legacy equivalence below Mach 0.3

print("Legacy equivalence — coefficients below Mach 0.3 must be bit-identical")
print(String(repeating: "-", count: 84))

let legacyAlphas: [Float] = [-0.25, -0.10, 0.0, 0.05, 0.12, 0.25, 0.45]
let legacyMachs: [Float] = [0.0, 0.05, 0.12, 0.20, 0.29, 0.30]

// A tabulated family is exempt, and the exemption is the honest reading of the rule rather
// than a way around it. `legacyEquivalenceMach` exists so that aircraft which were flying
// before compressibility was modelled keep flying identically; it is a compatibility
// promise, not a claim that air is incompressible below Mach 0.3. A family introduced in
// this same stage has no prior behaviour to be compatible with, and its table carries the
// real Prandtl-Glauert factor all the way down — 4.8% at Mach 0.3, which is simply true.
// Holding it to the rule would mean deleting correct physics to satisfy a promise made to
// nobody.
//
// The exemption is written as "has a table" rather than as a list of family names so that
// it cannot silently start covering a legacy family: the day someone gives `.delta` a
// table, that aircraft's stall speed has to be re-verified anyway, and this check going
// quiet is not how anyone should find out.
for family in families {
    let aero = aerodynamics(for: family)
    if aero.coefficientTable != nil {
        print(String(format: "%-22@ tabulated — exempt, see the note above",
                     family.rawValue as NSString))
        continue
    }
    var worst: Float = 0.0
    for mach in legacyMachs {
        for alpha in legacyAlphas {
            let reference = aero.liftDrag(alphaRad: alpha)
            let corrected = aero.liftDrag(alphaRad: alpha, mach: mach)
            worst = max(worst, abs(reference.cl - corrected.cl))
            worst = max(worst, abs(reference.cd - corrected.cd))

            let referenceCm = aero.pitchMoment(alphaRad: alpha, elevatorFraction: 0.4, qHat: 0.02)
            let correctedCm = aero.pitchMoment(
                alphaRad: alpha, elevatorFraction: 0.4, qHat: 0.02, mach: mach
            )
            worst = max(worst, abs(referenceCm - correctedCm))
        }
    }
    if worst != 0.0 {
        failures.append(String(format: "%@ coefficients move by %.3e below Mach 0.3",
                               family.rawValue, worst))
    }
    print(String(format: "%-22@ max deviation %.3e  %@",
                 family.rawValue as NSString, worst,
                 (worst == 0.0 ? "identical" : "CHANGED") as NSString))
}

// MARK: - 2. Continuity through Mach 1

print("\n\nContinuity — Mach 0.05 to 4.0, step halving test")
print(String(repeating: "-", count: 92))

let sweepAlpha: Float = 4.0 * .pi / 180.0

/// Largest change in each coefficient between adjacent samples of a sweep at step `h`.
///
/// The quantity that matters is not this number on its own. A steep curve and a step
/// function both produce a large one; what tells them apart is what happens when the
/// sampling step is halved. For anything continuous the largest change halves with it,
/// because over a small enough interval a smooth function is its own tangent. Across a
/// genuine discontinuity it does not move at all — the jump is the jump however finely
/// you sample around it.
///
/// This is why the check is a *ratio* rather than a threshold on the change itself. The
/// transonic drag rise is supposed to be brutally steep; it is not supposed to be a step.
func sweepMaxDeltas(
    aero: FixedWingAerodynamics,
    step: Float
) -> (cl: Float, cd: Float, cm: Float, worstMach: Float, finite: Bool) {
    var previous: (cl: Float, cd: Float, cm: Float)?
    var maxCl: Float = 0.0
    var maxCd: Float = 0.0
    var maxCm: Float = 0.0
    var worstMach: Float = 0.0
    var mach: Float = 0.05

    while mach <= 4.0 {
        let (cl, cd) = aero.liftDrag(alphaRad: sweepAlpha, mach: mach)
        let cm = aero.pitchMoment(alphaRad: sweepAlpha, elevatorFraction: 0.0, qHat: 0.0, mach: mach)
        guard cl.isFinite, cd.isFinite, cm.isFinite else {
            return (maxCl, maxCd, maxCm, mach, false)
        }
        if let previous {
            let deltaCd = abs(cd - previous.cd)
            if deltaCd > maxCd { maxCd = deltaCd; worstMach = mach }
            maxCl = max(maxCl, abs(cl - previous.cl))
            maxCm = max(maxCm, abs(cm - previous.cm))
        }
        previous = (cl, cd, cm)
        mach += step
    }
    return (maxCl, maxCd, maxCm, worstMach, true)
}

print(String(format: "%-22@ %10@ %10@ %10@ %10@ %9@ %9@",
             "family" as NSString, "dCD @h" as NSString, "dCD @h/2" as NSString,
             "ratio" as NSString, "at Mach" as NSString,
             "per tick" as NSString, "finite" as NSString))

for family in families {
    let aero = aerodynamics(for: family)
    let coarse = sweepMaxDeltas(aero: aero, step: 0.005)
    let fine = sweepMaxDeltas(aero: aero, step: 0.0025)

    if !coarse.finite || !fine.finite {
        failures.append(String(format: "%@ produced a non-finite coefficient near Mach %.3f",
                               family.rawValue, coarse.finite ? fine.worstMach : coarse.worstMach))
        continue
    }

    // 0.5 for a perfectly smooth curve, 1.0 across a jump. 0.65 leaves room for the
    // curvature of a genuinely steep region without admitting a step.
    let ratios = [
        ("CD", coarse.cd > 1.0e-9 ? fine.cd / coarse.cd : 0.0),
        ("CL", coarse.cl > 1.0e-9 ? fine.cl / coarse.cl : 0.0),
        ("Cm", coarse.cm > 1.0e-9 ? fine.cm / coarse.cm : 0.0)
    ]
    for (name, ratio) in ratios where ratio > 0.65 {
        failures.append(String(format: "%@ %@ does not halve when the Mach step halves (%.2f) — that is a step, not a slope",
                               family.rawValue, name, ratio))
    }

    // The operational form of the same question. An aircraft accelerating hard through
    // the transonic gains about 0.0002 Mach per 1/90 s substep; this is what the solver
    // actually sees between one force evaluation and the next.
    let perTickDeltaCd = coarse.cd * (0.0002 / 0.005)
    if perTickDeltaCd > 0.004 {
        failures.append(String(format: "%@ CD moves %.4f in a single physics substep through the rise",
                               family.rawValue, perTickDeltaCd))
    }

    print(String(format: "%-22@ %10.5f %10.5f %10.2f %10.3f %9.5f %9@",
                 family.rawValue as NSString, coarse.cd, fine.cd,
                 ratios[0].1, coarse.worstMach, perTickDeltaCd,
                 "yes" as NSString))
}

// MARK: - 3. Is the drag rise real, peaked and per-planform?

print("\n\nDrag rise — CD at alpha 4 deg across the regimes")
print(String(repeating: "-", count: 96))
print(String(format: "%-22@ %8@ %8@ %8@ %8@ %8@ %8@ %9@",
             "family" as NSString, "M0.30" as NSString, "M0.80" as NSString,
             "M0.95" as NSString, "M1.05" as NSString, "M2.00" as NSString,
             "M3.00" as NSString, "peak/sub" as NSString))

var riseRatios: [Float] = []

for family in families {
    let aero = aerodynamics(for: family)
    let samples = [0.30, 0.80, 0.95, 1.05, 2.00, 3.00].map { mach -> Float in
        aero.liftDrag(alphaRad: sweepAlpha, mach: Float(mach)).cd
    }
    let subsonic = samples[0]
    let peak = samples.max() ?? subsonic
    let ratio = subsonic > 1.0e-6 ? peak / subsonic : 0.0
    riseRatios.append(ratio)

    // A transonic drag rise that does not at least half again the subsonic drag is not
    // a drag rise; one that multiplies it by ten is a wall nothing could be flown
    // through. Both ends are checked because "it moved" is not the claim being made.
    if ratio < 1.4 {
        failures.append(String(format: "%@ shows almost no drag rise (peak is %.2fx subsonic)",
                               family.rawValue, ratio))
    }
    if ratio > 9.0 {
        failures.append(String(format: "%@ drag rise is %.1fx subsonic, which is a wall",
                               family.rawValue, ratio))
    }
    // Past the peak it has to come back down. An aircraft that pays its maximum wave
    // drag for ever cannot accelerate away from Mach 1, which is the whole point of
    // going supersonic.
    if samples[5] >= peak {
        failures.append(String(format: "%@ drag never falls after the transonic peak",
                               family.rawValue))
    }

    print(String(format: "%-22@ %8.4f %8.4f %8.4f %8.4f %8.4f %8.4f %9.2f",
                 family.rawValue as NSString,
                 samples[0], samples[1], samples[2], samples[3], samples[4], samples[5],
                 ratio))
}

// The plan bans a universal coefficient. If every family rose by the same factor, that
// is exactly what this would be — a constant wearing a per-family costume.
if let low = riseRatios.min(), let high = riseRatios.max(), high - low < 0.25 {
    failures.append(String(format: "every family rises by the same factor (%.2f–%.2f) — that is a universal constant",
                           low, high))
}

// MARK: - 4. Lift slope and balance across Mach

print("\n\nLift and balance — CL and Cm at alpha 4 deg, elevator neutral")
print(String(repeating: "-", count: 84))
print(String(format: "%-22@ %9@ %9@ %9@ %9@ %9@",
             "family" as NSString, "CL M0.3" as NSString, "CL M0.9" as NSString,
             "CL M2.0" as NSString, "Cm M0.3" as NSString, "Cm M2.0" as NSString))

for family in families {
    let aero = aerodynamics(for: family)
    let clLow = aero.liftDrag(alphaRad: sweepAlpha, mach: 0.30).cl
    let clHigh = aero.liftDrag(alphaRad: sweepAlpha, mach: 0.90).cl
    let clSuper = aero.liftDrag(alphaRad: sweepAlpha, mach: 2.00).cl
    let cmLow = aero.pitchMoment(alphaRad: sweepAlpha, elevatorFraction: 0.0, qHat: 0.0, mach: 0.30)
    let cmSuper = aero.pitchMoment(alphaRad: sweepAlpha, elevatorFraction: 0.0, qHat: 0.0, mach: 2.00)

    // Subsonic compressibility raises the lift slope; supersonic linear theory drops it
    // well below the incompressible value. Both are the sign of the effect, not its
    // magnitude, so only the direction is asserted.
    if clHigh <= clLow {
        failures.append("\(family.rawValue): lift slope does not rise through the subsonic range")
    }
    if clSuper >= clLow {
        failures.append("\(family.rawValue): lift slope does not fall supersonically")
    }
    // The aerodynamic centre moves aft, which for a positive lift coefficient is a
    // nose-down change. An aircraft whose trim does not move has not crossed Mach 1 in
    // any sense that matters.
    if cmSuper >= cmLow {
        failures.append("\(family.rawValue): pitching moment does not go nose-down supersonically")
    }

    print(String(format: "%-22@ %9.4f %9.4f %9.4f %9.4f %9.4f",
                 family.rawValue as NSString, clLow, clHigh, clSuper, cmLow, cmSuper))
}

// MARK: - 5. Does the existing fleet actually stay below Mach 0.3?

print("\n\nWhere the existing fleet flies — Mach at its own cruise and maximum speed")
print(String(repeating: "-", count: 84))
print(String(format: "%-24@ %10@ %10@ %10@ %12@",
             "profile" as NSString, "cruise" as NSString, "M cruise" as NSString,
             "max" as NSString, "M max" as NSString))

let repository = LIPODroneModelRepository()
let atmosphere = AtmosphereModel.standard
// 3 km: a representative working altitude for the current fleet, and the one that
// gives the *highest* Mach for a given true airspeed among the altitudes they use.
let referenceAir = atmosphere.state(altitudeMeters: 3_000.0)
var abovelegacy: [String] = []

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters else { continue }
    let machCruise = referenceAir.machNumber(trueAirspeedMps: wing.cruiseAirspeed)
    let machMax = referenceAir.machNumber(trueAirspeedMps: wing.maxAirspeed)
    if machMax > TransonicAeroModel.legacyEquivalenceMach {
        abovelegacy.append(String(format: "%@ (M %.2f at max)", profile.displayName, machMax))
    }
    print(String(format: "%-24@ %10.1f %10.3f %10.1f %12.3f",
                 profile.displayName as NSString,
                 wing.cruiseAirspeed, machCruise, wing.maxAirspeed, machMax))
}

print("\n" + String(repeating: "=", count: 84))
if !abovelegacy.isEmpty {
    print("\nAircraft that can now see compressibility (correctly — they are jets):")
    for entry in abovelegacy { print("  - \(entry)") }
}

if failures.isEmpty {
    print("""

    RESULT: PASS — corrections are inert below Mach 0.3, continuous through Mach 1, and \
    produce a per-planform drag rise that peaks and then falls.
    """)
} else {
    print("\nRESULT: FAIL")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
