import Foundation
import simd

/// One sonic boom arriving at one observer.
struct SonicBoomEvent: Equatable {
    /// Seconds from now until the observer hears it. The boom that arrives was emitted
    /// when the aircraft was somewhere else, and at these distances the delay is the most
    /// noticeable thing about it: a Mach 2 aircraft at 15 km is heard three quarters of a
    /// minute after it passed overhead.
    let arrivalDelaySeconds: Float
    /// Peak overpressure at the observer, Pa. What decides whether this is a distant
    /// rumble or something that breaks windows.
    let overpressurePa: Float
    /// Slant range from the emission point to the observer, m.
    let slantRangeMeters: Float
    /// The aircraft's Mach number when the boom was made.
    let mach: Float
    /// Mach-cone half-angle, radians.
    let coneHalfAngleRad: Float
}

/// Whether a shock cone has swept over an observer, and how hard.
///
/// The plan is specific that a sonic boom must not be "speed above a threshold, play a
/// sound". A supersonic aircraft does not go bang once; it drags a cone behind it, and an
/// observer hears exactly one boom, at the moment that cone's surface reaches them —
/// which may be a minute after the aircraft passed, may be from an aircraft that is no
/// longer supersonic, and does not happen at all if the aircraft never pointed the cone
/// their way.
///
/// Three things follow from modelling the geometry rather than the speed, and all three
/// are audible:
///
///  - **A boom is a single event, not a state.** It fires on the transition as the cone
///    edge crosses the observer, not every tick the aircraft is fast.
///  - **It arrives late.** The delay is the slant range over the speed of sound.
///  - **An observer off to the side may hear nothing.** The cone is a cone.
///
/// Stateful by necessity: "the cone crossed you" is a change, and a change cannot be
/// computed from one instant.
struct SonicBoomTracker {
    /// Was the observer inside the cone at the previous evaluation?
    private var observerWasInsideCone = false
    /// Suppresses re-triggering while an aircraft weaves around the cone boundary. A real
    /// observer hears one boom per pass, not a machine-gun of them.
    private var secondsSinceLastBoom: Float = .greatestFiniteMagnitude

    /// Shortest gap between two booms from the same aircraft, s.
    private static let rearmSeconds: Float = 4.0

    mutating func reset() {
        observerWasInsideCone = false
        secondsSinceLastBoom = .greatestFiniteMagnitude
    }

    /// Advances the tracker and returns an event on the tick the cone arrives.
    ///
    /// `observerPosition` is where the listener is — the camera in a chase view, the
    /// operator's own position in first person. Not the aircraft: an aircraft never hears
    /// its own boom, which is the entire reason the effect is interesting.
    mutating func update(
        aircraftPosition: SIMD3<Float>,
        aircraftVelocity: SIMD3<Float>,
        mach: Float,
        observerPosition: SIMD3<Float>,
        atmosphere: AtmosphereState,
        aircraftMassKg: Float,
        aircraftLengthM: Float,
        deltaTime: Float
    ) -> SonicBoomEvent? {
        secondsSinceLastBoom += max(0.0, deltaTime)

        let speed = simd_length(aircraftVelocity)
        guard mach > 1.0, speed > 1.0 else {
            // Subsonic: there is no cone, so the observer cannot be inside one. Clearing
            // the latch here is what lets the next supersonic run trigger again.
            observerWasInsideCone = false
            return nil
        }

        let toObserver = observerPosition - aircraftPosition
        let range = simd_length(toObserver)
        guard range > 1.0 else {
            observerWasInsideCone = true
            return nil
        }

        // The cone opens *backwards* from the aircraft, so the test is against the
        // reversed velocity: an observer the aircraft is flying towards is in front of
        // the shock and has heard nothing yet.
        let backward = -aircraftVelocity / speed
        let cosine = simd_dot(toObserver / range, backward)
        let coneHalfAngle = asin(min(1.0, 1.0 / mach))
        let isInsideCone = cosine >= cos(coneHalfAngle)

        defer { observerWasInsideCone = isInsideCone }

        guard isInsideCone,
              !observerWasInsideCone,
              secondsSinceLastBoom >= Self.rearmSeconds else {
            return nil
        }
        secondsSinceLastBoom = 0.0

        return SonicBoomEvent(
            arrivalDelaySeconds: range / max(1.0, atmosphere.speedOfSoundMps),
            overpressurePa: Self.overpressure(
                mach: mach,
                slantRangeMeters: range,
                aircraftMassKg: aircraftMassKg,
                aircraftLengthM: aircraftLengthM,
                atmosphere: atmosphere
            ),
            slantRangeMeters: range,
            mach: mach,
            coneHalfAngleRad: coneHalfAngle
        )
    }

    /// Peak overpressure of the N-wave at the observer, Pa.
    ///
    /// Carlson's engineering method, in the form used for preliminary design. The shape of
    /// it is what matters here and each term earns its place:
    ///
    ///  - **√(weight)** — a heavier aircraft displaces more air and makes a stronger wave.
    ///  - **length^(1/4)** — a longer aircraft spreads the same disturbance over a longer
    ///    wave, which weakens it, but only slowly.
    ///  - **altitude^(-3/4)** — the dominant term by far. This is why supersonic flight is
    ///    tolerable at 18 km and unacceptable at 2 km: the same aircraft is four times
    ///    louder on the ground from a tenth of the height.
    ///  - **(M²−1)^(1/8)** — a weak dependence, which surprises people. Doubling the Mach
    ///    number barely changes the boom; halving the altitude changes everything.
    ///
    /// A reference figure to sanity-check against: an aircraft of this class at 15 km
    /// produces something in the region of 20-50 Pa at the ground, which is a distant
    /// double thud rather than anything alarming.
    static func overpressure(
        mach: Float,
        slantRangeMeters: Float,
        aircraftMassKg: Float,
        aircraftLengthM: Float,
        atmosphere: AtmosphereState
    ) -> Float {
        guard mach > 1.0 else { return 0.0 }
        let weightLb = max(1.0, aircraftMassKg * 2.20462)
        let lengthFt = max(1.0, aircraftLengthM * 3.28084)
        let rangeFt = max(100.0, slantRangeMeters * 3.28084)
        let machTerm = pow(max(0.02, mach * mach - 1.0), 0.125)

        // Carlson's shape constant for the simplified form, times the ground-reflection
        // factor of about 1.9 — the wave arrives, bounces off the ground and reinforces
        // itself, so an observer standing on the surface hears close to twice the
        // free-field pressure.
        //
        // The first version of this used 0.0207 and produced booms of a fifth of a pascal:
        // a Concorde at cruise came out at 0.7 Pa against a documented 90-100 Pa, which is
        // inaudible against a figure that broke windows. Checking the formula against a
        // known aircraft rather than only against itself is what caught it.
        let carlsonShapeConstant: Float = 1.05
        let groundReflectionFactor: Float = 1.90
        let overpressurePsf = carlsonShapeConstant * groundReflectionFactor
            * sqrt(weightLb)
            * pow(lengthFt, 0.25)
            * machTerm
            / pow(rangeFt, 0.75)

        // lb/ft² to Pa.
        let pascals = overpressurePsf * 47.8803
        return pascals.isFinite ? max(0.0, pascals) : 0.0
    }

    /// Sound pressure level of an N-wave of this peak overpressure, dB.
    ///
    /// Referenced to 20 µPa. Useful for deciding how loudly to play it and for saying
    /// something honest in the telemetry: 50 Pa is about 128 dB, which is a bang.
    static func soundPressureLevelDb(overpressurePa: Float) -> Float {
        guard overpressurePa > 1.0e-6 else { return 0.0 }
        return 20.0 * log10(overpressurePa / 2.0e-5)
    }
}

/// Whether the air is doing the thing that makes a visible vapour cone.
///
/// The plan calls this out specifically, and it is a common mistake: a condensation cone
/// is not what a supersonic aircraft looks like. It is what a *humid* aircraft looks like.
/// The local pressure drop over the wing cools the air below its dew point, water
/// condenses, and the cloud stands still relative to the aircraft. In dry air — which is
/// most of the atmosphere above a few kilometres — nothing appears at any Mach number.
///
/// So this returns a strength rather than a boolean, and it is zero far more often than
/// not.
enum CondensationCone {
    /// 0 = nothing visible, 1 = a full standing cloud.
    ///
    /// Peaks in the high transonic and fades supersonically: the effect needs a strong
    /// local expansion over the wing, which is exactly what happens between about Mach
    /// 0.9 and 1.1 and much less so at Mach 2.
    static func strength(mach: Float, relativeHumidity: Float, atmosphere: AtmosphereState) -> Float {
        let humidity = max(0.0, min(1.0, relativeHumidity))
        guard humidity > 0.45, mach > 0.80 else { return 0.0 }

        let machWindow: Float
        if mach <= 1.0 {
            machWindow = (mach - 0.80) / 0.20
        } else {
            machWindow = max(0.0, 1.0 - (mach - 1.0) / 0.45)
        }

        // Warm air holds far more water, so the cloud is a low-altitude phenomenon in
        // practice — which is why the photographs that make it famous are all of aircraft
        // near the surface over the sea.
        let warmth = ((atmosphere.temperatureK - 250.0) / 40.0).clampedToUnit()
        let humidityTerm = ((humidity - 0.45) / 0.45).clampedToUnit()

        return (machWindow.clampedToUnit() * humidityTerm * warmth).clampedToUnit()
    }
}

private extension Float {
    func clampedToUnit() -> Float {
        Swift.min(1.0, Swift.max(0.0, self))
    }
}
