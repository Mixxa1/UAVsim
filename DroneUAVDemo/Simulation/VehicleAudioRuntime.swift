import Foundation
import simd

/// Where the aircraft is in its own acoustic life cycle.
///
/// Separate from `DronePhysicalState` and from the arming state on purpose. The plan is
/// specific that these must not be collapsed into one another: powering the avionics is not
/// arming, arming is not spinning the rotors, and losing the control link must not stop a
/// motor that is still perfectly happy. Each of those is a different sound, and a state
/// machine that cannot tell them apart cannot make them.
enum VehicleAudioPhase: String, Hashable {
    /// Nothing running.
    case off
    /// Avionics alive, motors not.
    case powered
    /// Armed and holding — still no flight loop. An armed multirotor sitting on the ground
    /// with its motors idling is not the same sound as one in the air.
    case armed
    /// Rotors or shaft turning, aircraft still on the ground.
    case rotorsSpinning
    /// Flying: propulsion plus airflow, both Doppler-shifted.
    case airborne
    /// Rotors winding down after a disarm or a crash.
    case spindown
}

/// Everything the acoustic model needs from one simulation tick.
///
/// A plain value, and deliberately not a reference to the view model: this is what makes the
/// runtime testable in a headless probe, where there is no scene, no audio device and no
/// SwiftUI.
struct VehicleAudioInput {
    var isSessionRunning: Bool = false
    var isArmed: Bool = false
    var physicalState: DronePhysicalState = .disarmed
    /// Per-lane rotor speed, rad/s, as the flight model produced it. Dead lanes read zero,
    /// which is exactly what a failed motor should sound like.
    var rotorSpeedsRadPerSec: SIMD4<Float> = .init(repeating: 0.0)
    /// Fuel engines report the real shaft speed instead; converted to rad/s by the caller.
    var engineShaftSpeedRadPerSec: Float = 0.0
    var engineRunState: EngineRunState?
    var motorThrottle: Float = 0.0
    var forwardAirspeedMps: Float = 0.0
    var airDensityKgPerM3: Float = AtmosphereModel.seaLevelDensity
    var speedOfSoundMps: Float = 343.0
    /// Mean surviving thrust fraction across the rotors, 0…1. Damage arrives here.
    var rotorThrustFactor: Float = 1.0
    /// Worst rotor imbalance, 0…1.
    var rotorVibration: Float = 0.0
    /// How much of the aircraft's weight the wing is carrying, 0…1. Only a hybrid VTOL ever
    /// sits between the ends.
    var vtolWingborneBlend: Float = 0.0
    /// Fastest control-surface movement this tick, deflection units per second.
    ///
    /// One number rather than three: the operator hears "a servo moved", not which one, and a
    /// simultaneous aileron-and-elevator input is one command rather than two sounds.
    var controlSurfaceRate: Float = 0.0
    var worldPosition: SIMD3<Float> = .init(repeating: 0.0)
    var worldVelocity: SIMD3<Float> = .init(repeating: 0.0)
    var listenerPosition: SIMD3<Float> = .init(repeating: 0.0)
    var listenerVelocity: SIMD3<Float> = .init(repeating: 0.0)
    var simulationTime: Float = 0.0
    /// Tick length, seconds. Only the servo cooldown needs it; everything else here is a
    /// function of state rather than of elapsed time.
    var deltaTime: Float = 1.0 / 60.0
}

/// A continuous sound that should be running this tick, with the parameters it should run at.
struct VehicleAudioLayer: Hashable {
    let id: AudioAssetID
    let gainDb: Float
    let pitchRatio: Float
    let worldPosition: SIMD3<Float>
}

/// A one-shot to fire this tick.
struct VehicleAudioCue: Hashable {
    let id: AudioAssetID
    let gainDb: Float
    let worldPosition: SIMD3<Float>
    /// Deterministic variant/jitter seed — see `AudioAssetCatalog.variantIndex`.
    let seed: UInt64
}

struct VehicleAudioPlan {
    let phase: VehicleAudioPhase
    let layers: [VehicleAudioLayer]
    let cues: [VehicleAudioCue]

    static let silent = VehicleAudioPlan(phase: .off, layers: [], cues: [])
}

/// Turns the aircraft's mechanical state into the sound it should be making.
///
/// Knows nothing about `AVAudioEngine`: it produces a description of what should be audible,
/// and something else makes it audible. That separation is what lets the coupling laws be
/// checked in a probe — the interesting failures here are wrong pitch against RPM and wrong
/// Doppler sign, and neither needs a speaker to catch.
final class VehicleAudioRuntime {

    private(set) var phase: VehicleAudioPhase = .off
    private var hasPlayedElectronicsBoot = false
    private var previousShaftSpeed: Float = 0.0
    private var previousEngineRunState: EngineRunState?
    private var cueSequence: UInt64 = 0
    private var servoCooldownSeconds: Float = 0.0

    /// Deflection rate above which a surface movement is a distinct servo action rather than
    /// the continuous trimming an autopilot does every tick.
    private static let servoRateThreshold: Float = 1.6
    /// Minimum gap between servo sounds. Without it a stick sweep would fire one per tick.
    private static let servoCooldownSecondsValue: Float = 0.22

    /// Below this the rotors are not turning as far as the ear is concerned.
    private static let spinningThresholdRadPerSec: Float = 45.0
    /// Airflow is inaudible under the noise of the machine itself until the aircraft is
    /// genuinely moving.
    private static let airflowThresholdMps: Float = 8.0

    func reset() {
        phase = .off
        hasPlayedElectronicsBoot = false
        previousShaftSpeed = 0.0
        previousEngineRunState = nil
        cueSequence = 0
        servoCooldownSeconds = 0.0
    }

    func update(profile: VehicleAudioProfile, input: VehicleAudioInput) -> VehicleAudioPlan {
        guard input.isSessionRunning else {
            reset()
            return .silent
        }

        let shaftSpeed = Self.effectiveShaftSpeed(profile: profile, input: input)
        var cues: [VehicleAudioCue] = []

        if !hasPlayedElectronicsBoot, let boot = profile.electronicsBootCue {
            hasPlayedElectronicsBoot = true
            cues.append(makeCue(boot, gainDb: -4.0, at: input.worldPosition))
        }

        // The spin-up is a threshold crossing, not a state: it fires when the rotors start
        // turning, whether that came from arming, from an autopilot, or from a restart in the
        // air after a failure.
        if previousShaftSpeed < Self.spinningThresholdRadPerSec,
           shaftSpeed >= Self.spinningThresholdRadPerSec,
           let spinUp = profile.spinUpCue {
            cues.append(makeCue(spinUp, gainDb: -3.0, at: input.worldPosition))
        }

        if let runState = input.engineRunState,
           runState != previousEngineRunState,
           runState == .cranking,
           let startCue = profile.engineStartCue {
            cues.append(makeCue(startCue, gainDb: -2.0, at: input.worldPosition))
        }
        previousEngineRunState = input.engineRunState
        previousShaftSpeed = shaftSpeed

        // Control surfaces. A servo is heard when it *moves*, and only from close by — which
        // the distance attenuation handles, so all this decides is whether a movement was a
        // movement. The autopilot trims continuously and must not chatter, hence a rate
        // threshold and a cooldown rather than a level.
        servoCooldownSeconds = max(0.0, servoCooldownSeconds - max(0.0, input.deltaTime))
        if let servo = profile.mechanismCue,
           input.controlSurfaceRate > Self.servoRateThreshold,
           servoCooldownSeconds <= 0.0 {
            servoCooldownSeconds = Self.servoCooldownSecondsValue
            let excess = min(1.0, (input.controlSurfaceRate - Self.servoRateThreshold) / 6.0)
            cues.append(makeCue(servo, gainDb: -18.0 + 8.0 * excess, at: input.worldPosition))
        }

        phase = Self.resolvePhase(input: input, shaftSpeed: shaftSpeed)

        var layers: [VehicleAudioLayer] = []
        let doppler = Self.dopplerRatio(
            sourcePosition: input.worldPosition,
            sourceVelocity: input.worldVelocity,
            listenerPosition: input.listenerPosition,
            listenerVelocity: input.listenerVelocity,
            speedOfSoundMps: input.speedOfSoundMps
        )

        if let propulsion = propulsionLayer(
            profile: profile,
            input: input,
            shaftSpeed: shaftSpeed,
            doppler: doppler
        ) {
            layers.append(propulsion)
        }

        // The propeller, when it is its own recording rather than part of the engine's.
        //
        // Driven off the same shaft — a direct-drive propeller turns with its motor — but
        // trimmed separately, because how loud the blades are relative to the motor is a
        // property of the aircraft rather than of the shaft speed.
        if let propellerAsset = profile.propellerLoop,
           shaftSpeed > Self.spinningThresholdRadPerSec {
            let reference = max(1.0, profile.referenceShaftSpeedRadPerSec)
            let speedRatio = shaftSpeed / reference
            var gain = profile.propellerTrimDb
            gain += VehicleAudioProfile.speedToLevelExponent * log10(max(0.08, speedRatio))
            gain += 6.0 * log10(max(0.15, input.rotorThrustFactor))
            layers.append(VehicleAudioLayer(
                id: propellerAsset,
                gainDb: min(6.0, gain),
                pitchRatio: pow(max(0.05, speedRatio), 0.7) * doppler,
                worldPosition: input.worldPosition
            ))
        }

        // A hybrid VTOL hanging on its lift rotors gets the rotor voice as well, faded out as
        // the wing takes over. Crossfaded rather than switched: the transition is continuous
        // in the flight model and has to be continuous here too.
        //
        // Gated on the profile *declaring* lift rotors, not on what its audio class is not.
        // The earlier form asked whether the class was one of the three multirotor ones, which
        // every aeroplane passes, and then scaled by `1 − vtolWingborneBlend` — zero for an
        // aircraft that never hovers, so the scale was 1. That is how a turboprop ended up
        // flying with a quadcopter mixed in at full level.
        if let liftLoop = profile.liftRotorLoop,
           shaftSpeed > Self.spinningThresholdRadPerSec {
            let rotorFraction = 1.0 - min(1.0, max(0.0, input.vtolWingborneBlend))
            if rotorFraction > 0.02 {
                let reference = max(1.0, profile.liftRotorReferenceSpeedRadPerSec)
                let speedRatio = shaftSpeed / reference
                var gain = profile.liftRotorTrimDb + Self.fractionToDb(rotorFraction)
                gain += VehicleAudioProfile.speedToLevelExponent * log10(max(0.08, speedRatio))
                gain += 6.0 * log10(max(0.15, input.rotorThrustFactor))
                layers.append(VehicleAudioLayer(
                    id: liftLoop,
                    gainDb: min(6.0, gain),
                    pitchRatio: pow(max(0.05, speedRatio), 0.7) * doppler,
                    worldPosition: input.worldPosition
                ))
            }
        }

        if let airflow = airflowLayer(profile: profile, input: input, doppler: doppler) {
            layers.append(airflow)
        }

        return VehicleAudioPlan(phase: phase, layers: layers, cues: cues)
    }

    // MARK: Layers

    private func propulsionLayer(
        profile: VehicleAudioProfile,
        input: VehicleAudioInput,
        shaftSpeed: Float,
        doppler: Float,
        extraGainDb: Float = 0.0
    ) -> VehicleAudioLayer? {
        guard let asset = profile.propulsionLoop else { return nil }
        guard shaftSpeed > Self.spinningThresholdRadPerSec else { return nil }

        let reference = max(1.0, profile.referenceShaftSpeedRadPerSec)
        let speedRatio = shaftSpeed / reference

        // Pitch follows blade-pass frequency, which is linear in shaft speed — but the
        // recorded clip has a blade count of its own that we do not know, so this can only
        // ever be relative. Compressed with a root so that a rotor at half speed is a fifth
        // lower rather than an octave: the recordings carry body resonances that do not
        // actually move with RPM, and shifting the whole clip by the full ratio drags those
        // with it and turns a quadcopter into a toy.
        let pitch = pow(max(0.05, speedRatio), 0.7) * doppler

        // Loudness from speed, with damage folded in. A rotor down to half thrust is not
        // half as loud — it is a rotor turning slower, and the speed term already says that;
        // what the thrust factor adds is the part that has been torn off.
        var gain = profile.propulsionTrimDb + extraGainDb
        gain += VehicleAudioProfile.speedToLevelExponent * log10(max(0.08, speedRatio))
        gain += 6.0 * log10(max(0.15, input.rotorThrustFactor))

        // An unbalanced rotor does not just get quieter, it gets uneven. This is the wobble,
        // driven off simulation time so a replay reproduces it exactly.
        if input.rotorVibration > 0.02 {
            let wobble = sin(input.simulationTime * 37.0) * input.rotorVibration
            gain += wobble * 3.0
        }

        return VehicleAudioLayer(
            id: asset,
            gainDb: min(6.0, gain),
            pitchRatio: pitch,
            worldPosition: input.worldPosition
        )
    }

    /// Airflow over the airframe.
    ///
    /// Level follows 40·log₁₀ of speed. Boundary-layer noise radiates as a dipole and scales
    /// nearer the sixth power of velocity — 60·log₁₀ — but that is the isolated-surface
    /// figure, and against a rotor that is already running it makes the wind either absent or
    /// overwhelming with almost nothing in between. Forty is the compromise; it is a mixing
    /// choice and not a claim about aeroacoustics.
    private func airflowLayer(
        profile: VehicleAudioProfile,
        input: VehicleAudioInput,
        doppler: Float
    ) -> VehicleAudioLayer? {
        guard phase == .airborne || phase == .spindown else { return nil }
        let speed = input.forwardAirspeedMps
        guard speed > Self.airflowThresholdMps else { return nil }

        let reference = max(1.0, profile.referenceAirspeedMps)
        let ratio = speed / reference
        // Thinner air makes less noise for the same true airspeed, which is why a high pass
        // is quieter than the same speed near the ground.
        let densityRatio = max(0.05, input.airDensityKgPerM3 / AtmosphereModel.seaLevelDensity)
        let gain = profile.airflowTrimDb
            + 40.0 * log10(max(0.1, ratio))
            + 10.0 * log10(densityRatio)

        return VehicleAudioLayer(
            id: .airflowLoop,
            // Capped, but not at the asset's own level: a clamp at zero saturates the wind
            // well before the fastest aircraft in the catalogue reaches its own top speed,
            // and the last third of the speed range then has no audible consequence at all.
            gainDb: min(3.0, gain),
            pitchRatio: min(1.6, max(0.7, ratio)) * doppler,
            worldPosition: input.worldPosition
        )
    }

    // MARK: Helpers

    private func makeCue(_ id: AudioAssetID, gainDb: Float, at position: SIMD3<Float>) -> VehicleAudioCue {
        cueSequence &+= 1
        return VehicleAudioCue(id: id, gainDb: gainDb, worldPosition: position, seed: cueSequence)
    }

    private static func fractionToDb(_ fraction: Float) -> Float {
        20.0 * log10(max(0.001, min(1.0, fraction)))
    }

    /// Which speed actually drives the sound.
    ///
    /// A fuel engine reports its own shaft speed and that is the honest number. An electric
    /// aircraft has no such instrument, so the flight model's per-lane rotor speeds are used,
    /// averaged over the lanes that are still turning — averaging in the dead ones would make
    /// a failed motor sound like the whole aircraft slowing down.
    private static func effectiveShaftSpeed(profile: VehicleAudioProfile, input: VehicleAudioInput) -> Float {
        if profile.usesFuelEngine, input.engineRunState != nil {
            // Once an engine is actually being simulated, its shaft speed is the only speed
            // that means anything, and a stopped engine means zero. There is deliberately no
            // fallback here: the flight model writes a throttle-derived number onto the rotor
            // lanes for every fixed wing, fuel-burning ones included, so falling back to it
            // kept a dead engine running for as long as the throttle was open.
            //
            // The `engineRunState != nil` test is what keeps that from over-reaching: an
            // aircraft whose engine model is not running at all has no engine reading to
            // prefer, and silencing it would be worse than reading the lane.
            return input.engineShaftSpeedRadPerSec
        }
        var total: Float = 0.0
        var count: Float = 0.0
        for lane in 0..<4 where input.rotorSpeedsRadPerSec[lane] > 1.0 {
            total += input.rotorSpeedsRadPerSec[lane]
            count += 1.0
        }
        return count > 0.0 ? total / count : 0.0
    }

    private static func resolvePhase(input: VehicleAudioInput, shaftSpeed: Float) -> VehicleAudioPhase {
        let spinning = shaftSpeed > spinningThresholdRadPerSec
        switch input.physicalState {
        case .crashed:
            return spinning ? .spindown : .powered
        case .airborne, .takeoffTransition, .landing:
            return spinning ? .airborne : .spindown
        case .disarmed, .landed, .armedOnGround:
            if spinning { return input.isArmed ? .rotorsSpinning : .spindown }
            return input.isArmed ? .armed : .powered
        }
    }

    /// Frequency ratio from relative motion along the line of sight.
    ///
    /// `f' = f · (c − v_listener·û) / (c − v_source·û)`, with `û` the unit vector from source
    /// to listener. A source approaching the listener has a positive component along `û`,
    /// which shrinks the denominator and raises the pitch — which is the whole point, and
    /// also the sign that is easiest to get backwards.
    ///
    /// The denominator is floored well above zero. At Mach 1 the true formula is singular,
    /// because that is the condition where the aircraft arrives with its own sound: what
    /// happens there is a sonic boom, and that is modelled elsewhere as its own event rather
    /// than as an infinite pitch shift here.
    static func dopplerRatio(
        sourcePosition: SIMD3<Float>,
        sourceVelocity: SIMD3<Float>,
        listenerPosition: SIMD3<Float>,
        listenerVelocity: SIMD3<Float>,
        speedOfSoundMps: Float
    ) -> Float {
        let separation = listenerPosition - sourcePosition
        let distanceSquared = simd_length_squared(separation)
        guard distanceSquared > 0.01 else { return 1.0 }
        let direction = separation / sqrt(distanceSquared)
        let c = max(1.0, speedOfSoundMps)
        let sourceAlong = simd_dot(sourceVelocity, direction)
        let listenerAlong = simd_dot(listenerVelocity, direction)
        let ratio = (c - listenerAlong) / max(0.25 * c, c - sourceAlong)
        return min(1.8, max(0.6, ratio.isFinite ? ratio : 1.0))
    }
}
