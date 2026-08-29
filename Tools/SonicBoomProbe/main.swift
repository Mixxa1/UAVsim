import Foundation
import simd

// Headless probe for sonic-boom geometry.
//
// The plan states the requirement as a prohibition: a boom must depend on Mach and on
// where the observer is, not on speed crossing a threshold. That is a testable claim, and
// it decomposes into four things a threshold model cannot do:
//
//  1. **Nothing below Mach 1.** Not a quiet boom — none, because there is no cone.
//  2. **One boom per pass.** The cone edge crosses the observer once; an observer does not
//     hear a bang every tick the aircraft is fast.
//  3. **Geometry decides who hears it.** An observer the aircraft is flying away from,
//     outside the cone, hears nothing at all.
//  4. **It arrives late, and the delay is the distance.**
//
// The overpressure is checked separately against the two things it is known to depend on:
// altitude strongly, Mach weakly. That relationship is counter-intuitive enough that
// getting it backwards would look plausible.
//
// Run: Tools/SonicBoomProbe/run.sh

var failures: [String] = []
let atmosphere = AtmosphereModel.standard
let dt: Float = 1.0 / 60.0

// A Firebee-class aircraft: about a tonne, nine metres long.
let massKg: Float = 951.0
let lengthM: Float = 8.89

// MARK: - 1. A pass overhead: one boom, arriving late

print("A supersonic pass over a ground observer — aircraft at 12 km, Mach 1.6, flying north")
print(String(repeating: "-", count: 92))

let air = atmosphere.state(altitudeMeters: 12_000.0)
let speed = 1.6 * air.speedOfSoundMps
let observer = SIMD3<Float>(0, 0, 0)
var tracker = SonicBoomTracker()
var booms: [(time: Float, event: SonicBoomEvent)] = []

// Starts 40 km short of the observer and flies past it by 40 km.
var position = SIMD3<Float>(0, 12_000, 40_000)
let velocity = SIMD3<Float>(0, 0, -speed)
var elapsed: Float = 0.0

while position.z > -40_000 {
    position += velocity * dt
    elapsed += dt
    if let event = tracker.update(
        aircraftPosition: position,
        aircraftVelocity: velocity,
        mach: 1.6,
        observerPosition: observer,
        atmosphere: air,
        aircraftMassKg: massKg,
        aircraftLengthM: lengthM,
        deltaTime: dt
    ) {
        booms.append((elapsed, event))
    }
}

for (time, event) in booms {
    print(String(format: "boom at t = %.1f s · Mach %.2f · cone half-angle %.1f° · slant range %.1f km · %.1f Pa (%.0f dB) · arrives %.1f s later",
                 time, event.mach, event.coneHalfAngleRad * 180.0 / .pi,
                 event.slantRangeMeters / 1000.0, event.overpressurePa,
                 SonicBoomTracker.soundPressureLevelDb(overpressurePa: event.overpressurePa),
                 event.arrivalDelaySeconds))
}

if booms.count != 1 {
    failures.append("one pass produced \(booms.count) booms — an observer hears exactly one")
}
if let first = booms.first {
    // The cone reaches the ground behind the aircraft, so the aircraft has already gone
    // past by the time the boom is made — and the sound then takes its own travel time.
    if first.event.arrivalDelaySeconds < 20.0 {
        failures.append(String(format: "the boom arrives %.1f s after emission — from 12 km that is too soon",
                               first.event.arrivalDelaySeconds))
    }
    let expectedHalfAngle = asin(1.0 / 1.6) * 180.0 / Float.pi
    let modelled = first.event.coneHalfAngleRad * 180.0 / Float.pi
    if abs(modelled - expectedHalfAngle) > 0.5 {
        failures.append(String(format: "cone half-angle is %.2f°, expected %.2f° for Mach 1.6",
                               modelled, expectedHalfAngle))
    }
}

// MARK: - 2. Subsonic: nothing at all

print("\n\nThe same pass at Mach 0.95")
print(String(repeating: "-", count: 92))

var subsonicTracker = SonicBoomTracker()
var subsonicBooms = 0
var subsonicPosition = SIMD3<Float>(0, 12_000, 40_000)
let subsonicVelocity = SIMD3<Float>(0, 0, -0.95 * air.speedOfSoundMps)
while subsonicPosition.z > -40_000 {
    subsonicPosition += subsonicVelocity * dt
    if subsonicTracker.update(
        aircraftPosition: subsonicPosition,
        aircraftVelocity: subsonicVelocity,
        mach: 0.95,
        observerPosition: observer,
        atmosphere: air,
        aircraftMassKg: massKg,
        aircraftLengthM: lengthM,
        deltaTime: dt
    ) != nil {
        subsonicBooms += 1
    }
}
print("booms heard: \(subsonicBooms)")
if subsonicBooms != 0 {
    failures.append("a subsonic aircraft produced \(subsonicBooms) booms")
}

// MARK: - 3. Geometry: an observer outside the cone hears nothing

print("\n\nAn observer 60 km off to the side of the same pass")
print(String(repeating: "-", count: 92))

var lateralTracker = SonicBoomTracker()
var lateralBooms = 0
let lateralObserver = SIMD3<Float>(60_000, 0, 0)
var lateralPosition = SIMD3<Float>(0, 12_000, 40_000)
while lateralPosition.z > -40_000 {
    lateralPosition += velocity * dt
    if lateralTracker.update(
        aircraftPosition: lateralPosition,
        aircraftVelocity: velocity,
        mach: 1.6,
        observerPosition: lateralObserver,
        atmosphere: air,
        aircraftMassKg: massKg,
        aircraftLengthM: lengthM,
        deltaTime: dt
    ) != nil {
        lateralBooms += 1
    }
}
// The Mach cone at 1.6 opens 38.7° from the flight path. From 12 km up, a 60 km lateral
// offset is well outside it, and no amount of speed brings it inside — which is precisely
// the behaviour a speed threshold cannot produce.
print("booms heard 60 km abeam: \(lateralBooms)")
if lateralBooms != 0 {
    failures.append("an observer 60 km outside the Mach cone heard \(lateralBooms) booms")
}

// MARK: - 4. Overpressure: strongly on altitude, weakly on Mach

print("\n\nOverpressure at the ground, Pa — the two dependencies that matter")
print(String(repeating: "-", count: 92))
print(String(format: "%-12@ %12@ %12@ %12@ %12@",
             "altitude" as NSString, "M 1.2" as NSString, "M 1.6" as NSString,
             "M 2.5" as NSString, "M 4.0" as NSString))

var byAltitude: [Float: Float] = [:]
for altitude in [Float(2_000), 6_000, 12_000, 18_000] {
    let air = atmosphere.state(altitudeMeters: altitude)
    let values = [Float(1.2), 1.6, 2.5, 4.0].map { mach in
        SonicBoomTracker.overpressure(
            mach: mach,
            slantRangeMeters: altitude,
            aircraftMassKg: massKg,
            aircraftLengthM: lengthM,
            atmosphere: air
        )
    }
    byAltitude[altitude] = values[1]
    print(String(format: "%9.0f m %12.1f %12.1f %12.1f %12.1f",
                 altitude, values[0], values[1], values[2], values[3]))
}

// Checked against an aircraft whose boom is documented rather than only against itself.
// Concorde at cruise put roughly 90-100 Pa on the ground, and a formula that cannot
// reproduce a case everyone knows is not going to be right about the ones nobody has
// measured. The first version of this model returned 0.7 Pa here.
let concordeBoom = SonicBoomTracker.overpressure(
    mach: 2.0,
    slantRangeMeters: 18_000.0,
    aircraftMassKg: 180_000.0,
    aircraftLengthM: 62.0,
    atmosphere: atmosphere.state(altitudeMeters: 18_000.0)
)
print(String(format: "\nreference case — Concorde at cruise: %.0f Pa (documented 90-100 Pa)", concordeBoom))
if concordeBoom < 40.0 || concordeBoom > 200.0 {
    failures.append(String(format: "the reference Concorde boom comes out at %.1f Pa against a documented 90-100 Pa", concordeBoom))
}

if let low = byAltitude[2_000], let high = byAltitude[18_000] {
    // Altitude must dominate. A boom from 2 km has to be several times what the same
    // aircraft makes from 18 km, or the model is saying supersonic flight over a city is
    // no worse than over the stratosphere.
    if low <= high * 3.0 {
        failures.append(String(format: "overpressure falls only from %.1f Pa to %.1f Pa over a ninefold change in altitude", low, high))
    }
}
let machLow = SonicBoomTracker.overpressure(mach: 1.2, slantRangeMeters: 12_000,
                                            aircraftMassKg: massKg, aircraftLengthM: lengthM,
                                            atmosphere: air)
let machHigh = SonicBoomTracker.overpressure(mach: 4.0, slantRangeMeters: 12_000,
                                             aircraftMassKg: massKg, aircraftLengthM: lengthM,
                                             atmosphere: air)
print(String(format: "\nMach 1.2 to Mach 4.0 at a fixed 12 km: %.1f Pa to %.1f Pa — a factor of %.2f",
             machLow, machHigh, machHigh / max(0.01, machLow)))
// The Mach dependence is a one-eighth power, so more than doubling it would mean the
// exponent is wrong.
if machHigh / max(0.01, machLow) > 2.0 {
    failures.append("overpressure more than doubles from Mach 1.2 to Mach 4 — the Mach exponent is too strong")
}
if machHigh <= machLow {
    failures.append("overpressure does not rise with Mach at all")
}

// MARK: - 5. The vapour cone is about humidity, not about Mach 1

print("\n\nCondensation cone strength — it is a humidity effect, not a speed one")
print(String(repeating: "-", count: 92))
print(String(format: "%-16@ %12@ %12@ %12@ %12@",
             "humidity" as NSString, "M 0.85" as NSString, "M 0.98" as NSString,
             "M 1.10" as NSString, "M 2.00" as NSString))

let seaLevel = atmosphere.state(altitudeMeters: 200.0)
for humidity in [Float(0.20), 0.55, 0.80, 0.95] {
    let values = [Float(0.85), 0.98, 1.10, 2.00].map {
        CondensationCone.strength(mach: $0, relativeHumidity: humidity, atmosphere: seaLevel)
    }
    print(String(format: "%13.0f%% %12.2f %12.2f %12.2f %12.2f",
                 humidity * 100.0, values[0], values[1], values[2], values[3]))
}

let dry = CondensationCone.strength(mach: 0.98, relativeHumidity: 0.20, atmosphere: seaLevel)
let humid = CondensationCone.strength(mach: 0.98, relativeHumidity: 0.95, atmosphere: seaLevel)
let humidHighMach = CondensationCone.strength(mach: 2.00, relativeHumidity: 0.95, atmosphere: seaLevel)
if dry > 0.0 {
    failures.append("a vapour cone appeared in 20 % humidity — it is a condensation effect and there is nothing to condense")
}
if humid <= 0.2 {
    failures.append("no vapour cone in 95 % humidity at Mach 0.98, which is exactly where the photographs come from")
}
if humidHighMach >= humid {
    failures.append("the vapour cone is strongest at Mach 2 — it peaks in the high transonic")
}

print("\n" + String(repeating: "=", count: 92))
if failures.isEmpty {
    print("""

    RESULT: PASS — one boom per pass, none below Mach 1, none outside the cone, arrival \
    delayed by the slant range, overpressure governed by altitude rather than by speed, \
    and a vapour cone that needs humidity rather than a Mach number.
    """)
} else {
    print("\nRESULT: FAIL")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
