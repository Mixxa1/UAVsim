import Foundation
import simd

// Headless probe for the flight envelope and aerodynamic heating.
//
// Two things are being checked, and neither is visible from a cockpit.
//
// **The thermal lag.** A stagnation temperature is easy: it is algebra on the Mach
// number, and a model that simply reported it would look plausible and be useless. What
// decides whether an aircraft can fly a Mach number is how fast its structure gets there
// — the Firebee II's Mach 1.5 is quoted as a *four-minute dash* precisely because the
// answer is "not fast enough to matter, if you do not linger". So the checks here are
// about time constants and about the ceiling never being exceeded, not about the value.
//
// **Which limit binds.** The plan asks for warnings that distinguish an overspeed from
// an over-q, because the corrections are opposite: climbing fixes dynamic pressure and
// makes Mach worse. That distinction is only real if the same true airspeed produces
// different binding limits at different altitudes, which is what is measured.
//
// Run: Tools/EnvelopeThermalProbe/run.sh

var failures: [String] = []
let atmosphere = AtmosphereModel.standard

// MARK: - 1. Heating has a time constant, and a ceiling it never passes

print("Thermal response — step to Mach 3 at 20 km, aluminium airframe")
print(String(repeating: "-", count: 84))
print(String(format: "%-10@ %12@ %12@ %12@ %12@",
             "t, s" as NSString, "nose K" as NSString, "skin K" as NSString,
             "recovery K" as NSString, "stagnation K" as NSString))

let highAir = atmosphere.state(altitudeMeters: 20_000.0)
let dashFlow = CompressibleFlowState(
    atmosphere: highAir,
    trueAirspeedMps: 3.0 * highAir.speedOfSoundMps
)
let aluminium = AeroThermalModel(
    material: .aluminium,
    referenceLengthM: 9.0,
    referenceAreaM2: 26.0
)

var thermal = AeroThermalState.ambient(highAir.temperatureK)
var elapsed: Float = 0.0
var skinHalfTime: Float?
let skinStart = thermal.skinK
let skinTarget = dashFlow.recoveryTemperatureK(recoveryFactor: AeroThermalZone.skin.recoveryFactor)

for tick in 0..<(60 * 400) {
    thermal = aluminium.advance(state: thermal, flow: dashFlow, deltaTime: 1.0 / 60.0)
    elapsed += 1.0 / 60.0

    if skinHalfTime == nil, thermal.skinK >= skinStart + (skinTarget - skinStart) * 0.5 {
        skinHalfTime = elapsed
    }
    // The recovery temperature is a ceiling, not a target to overshoot. A surface hotter
    // than the flow that heats it would be a sign the integration has gone unstable —
    // which is exactly what an explicit step does here at large time steps.
    if thermal.noseK > dashFlow.totalTemperatureK + 1.0 {
        failures.append(String(format: "nose reached %.0f K, above the stagnation temperature of %.0f K",
                               thermal.noseK, dashFlow.totalTemperatureK))
        break
    }
    if !thermal.skinK.isFinite {
        failures.append("skin temperature went non-finite")
        break
    }
    if tick % (60 * 60) == 0 || tick == 60 * 400 - 1 {
        print(String(format: "%10.0f %12.1f %12.1f %12.1f %12.1f",
                     elapsed, thermal.noseK, thermal.skinK,
                     dashFlow.recoveryTemperatureK(), dashFlow.totalTemperatureK))
    }
}

if let half = skinHalfTime {
    print(String(format: "\nskin reached half its temperature rise after %.1f s", half))
    // Instant would mean no thermal mass; a quarter of an hour would mean the model can
    // never matter inside a flight. Both are failures of the thing being modelled.
    if half < 2.0 {
        failures.append(String(format: "skin heats to half its rise in %.1f s — there is no thermal inertia", half))
    }
    if half > 300.0 {
        failures.append(String(format: "skin takes %.0f s to half its rise — heating could never matter in a flight", half))
    }
} else {
    failures.append("skin never reached half its temperature rise")
}

// Cooling. The same node, flown slowly, has to come back down — otherwise heat is a
// one-way ratchet and any aircraft that ever dashed is permanently damaged.
let slowFlow = CompressibleFlowState(atmosphere: highAir, trueAirspeedMps: 0.5 * highAir.speedOfSoundMps)
let hotSkin = thermal.skinK
for _ in 0..<(60 * 300) {
    thermal = aluminium.advance(state: thermal, flow: slowFlow, deltaTime: 1.0 / 60.0)
}
print(String(format: "after 300 s back at Mach 0.5: skin %.1f K (was %.1f K)", thermal.skinK, hotSkin))
if thermal.skinK >= hotSkin - 20.0 {
    failures.append("the skin does not cool when the aircraft slows down")
}

// MARK: - 2. Material is the difference between a dash and a cruise

print("\n\nSustained Mach 3 at 20 km — equilibrium skin temperature against the material limit")
print(String(repeating: "-", count: 84))
print(String(format: "%-18@ %12@ %12@ %12@ %10@",
             "material" as NSString, "skin K" as NSString, "limit K" as NSString,
             "fraction" as NSString, "verdict" as NSString))

for material in UAVSkinMaterial.allCases {
    let model = AeroThermalModel(material: material, referenceLengthM: 9.0, referenceAreaM2: 26.0)
    var state = AeroThermalState.ambient(highAir.temperatureK)
    for _ in 0..<(60 * 900) {
        state = model.advance(state: state, flow: dashFlow, deltaTime: 1.0 / 60.0)
    }
    let limits = FlightEnvelopeLimits.derived(
        maxAirspeedMps: 1_000.0,
        stallAlphaRad: 0.30,
        dragDivergenceMach: 0.90,
        structuralQualityFactor: 1.0,
        skinMaterial: material
    )
    let fraction = (state.hottestK - 288.15) / max(1.0, limits.maxSkinTemperatureK - 288.15)
    print(String(format: "%-18@ %12.1f %12.1f %12.2f %10@",
                 material.rawValue as NSString, state.hottestK, limits.maxSkinTemperatureK,
                 fraction, (fraction > 1.0 ? "EXCEEDED" : "ok") as NSString))

    if state.hottestK > dashFlow.totalTemperatureK + 1.0 {
        failures.append("\(material.rawValue): equilibrium above the stagnation temperature")
    }
}

// Aluminium at Mach 3 has to be over its limit and titanium has to be under it. If both
// come out the same the material is decoration, and the whole reason a Mach 3 airframe is
// built of something expensive has been modelled away.
let aluminiumEquilibrium: Float = {
    var state = AeroThermalState.ambient(highAir.temperatureK)
    for _ in 0..<(60 * 900) {
        state = aluminium.advance(state: state, flow: dashFlow, deltaTime: 1.0 / 60.0)
    }
    return state.hottestK
}()
if aluminiumEquilibrium <= UAVSkinMaterial.aluminium.workingLimitK {
    failures.append("aluminium survives a sustained Mach 3 — the thermal limit is not biting")
}
if aluminiumEquilibrium >= UAVSkinMaterial.titanium.workingLimitK {
    failures.append("even titanium would fail at Mach 3 — the heating is too strong")
}

// MARK: - 3. Which limit binds, and does it depend on where you are?

print("\n\nBinding limit for one airframe at one true airspeed, by altitude")
print(String(repeating: "-", count: 92))
print(String(format: "%-10@ %9@ %11@ %11@ %11@ %20@",
             "altitude" as NSString, "Mach" as NSString, "q kPa" as NSString,
             "M frac" as NSString, "q frac" as NSString, "binding" as NSString))

// A never-exceed of 250 m/s at sea level: Mach 0.73 and 38 kPa. Read at 15 km the same
// airspeed is Mach 0.85 and 6 kPa — the aircraft is close to its Mach limit and nowhere
// near its structural one. Down low it is the other way round. That inversion is the
// entire reason the plan asks for the two to be separated.
let limits = FlightEnvelopeLimits.derived(
    maxAirspeedMps: 250.0,
    stallAlphaRad: 0.30,
    dragDivergenceMach: 0.90,
    structuralQualityFactor: 1.2,
    skinMaterial: .aluminium
)
let monitor = FlightEnvelopeMonitor(limits: limits)
var bindingLimits: Set<FlightEnvelopeLimit> = []

for altitude in [Float(0), 3_000, 9_000, 15_000, 20_000] {
    let air = atmosphere.state(altitudeMeters: altitude)
    let flow = CompressibleFlowState(atmosphere: air, trueAirspeedMps: 240.0)
    let state = monitor.evaluate(
        previous: .nominal,
        mach: flow.mach,
        dynamicPressurePa: flow.dynamicPressurePa,
        loadFactor: 1.0,
        angleOfAttackRad: 0.05,
        skinTemperatureK: 300.0,
        inletWithinEnvelope: true,
        deltaTime: 1.0 / 60.0
    )
    bindingLimits.insert(state.bindingLimit)
    print(String(format: "%8.0f m %9.2f %11.1f %11.2f %11.2f %20@",
                 altitude, flow.mach, flow.dynamicPressurePa / 1000.0,
                 state.machFraction, state.dynamicPressureFraction,
                 state.bindingLimit.rawValue as NSString))
}

if bindingLimits.count < 2 {
    failures.append("the same airspeed binds against the same limit at every altitude — Mach and dynamic pressure are not actually separated")
}

// MARK: - 4. Exceedance accumulates and decays; it does not trip

print("\n\nExceedance accounting — 10 s outside the envelope, then 10 s back inside")
print(String(repeating: "-", count: 84))

var envelope = FlightEnvelopeState.nominal
for _ in 0..<600 {
    envelope = monitor.evaluate(
        previous: envelope,
        mach: 1.4,
        dynamicPressurePa: limits.maxDynamicPressurePa * 1.3,
        loadFactor: 1.0,
        angleOfAttackRad: 0.05,
        skinTemperatureK: 300.0,
        inletWithinEnvelope: true,
        deltaTime: 1.0 / 60.0
    )
}
let accumulated = envelope.exceedanceSeconds
for _ in 0..<600 {
    envelope = monitor.evaluate(
        previous: envelope,
        mach: 0.5,
        dynamicPressurePa: limits.maxDynamicPressurePa * 0.4,
        loadFactor: 1.0,
        angleOfAttackRad: 0.05,
        skinTemperatureK: 300.0,
        inletWithinEnvelope: true,
        deltaTime: 1.0 / 60.0
    )
}
print(String(format: "accumulated %.1f s outside, %.1f s remaining after 10 s back inside",
             accumulated, envelope.exceedanceSeconds))
if abs(accumulated - 10.0) > 0.3 {
    failures.append(String(format: "10 s outside the envelope accumulated %.1f s", accumulated))
}
if envelope.exceedanceSeconds >= accumulated {
    failures.append("exceedance never decays — an aircraft can never come back inside its envelope")
}
if envelope.exceedanceSeconds <= 0.0 {
    failures.append("exceedance is forgotten immediately — a sustained overload costs no more than a brief one")
}

print("\n" + String(repeating: "=", count: 92))
if failures.isEmpty {
    print("""

    RESULT: PASS — heating lags and is bounded by the recovery temperature, the material \
    decides whether a Mach number is survivable, and the binding limit changes with \
    altitude at constant airspeed.
    """)
} else {
    print("\nRESULT: FAIL")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
