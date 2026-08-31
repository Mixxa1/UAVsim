import Foundation

/// What an aircraft sounds like, as a class rather than as a name.
///
/// The plan is explicit that a sound must not be attached to a model designation: an audio
/// profile is built from the powerplant, the number of rotors, the speed range and the size
/// class, so a new airframe added to the catalogue tomorrow gets the right voice without
/// anyone editing an audio table. Two 900 g quadcopters sound alike because they *are* alike,
/// not because someone listed them together.
enum VehicleAudioClass: String, CaseIterable, Hashable {
    /// Camera/utility quadcopter up to a couple of kilograms.
    case smallMultirotor
    /// Industrial multirotor — heavier, slower blades, more of them.
    case heavyMultirotor
    /// Small racing/freestyle quad: the same rotor count as a camera drone and nothing else
    /// in common. Its blades change speed several times a second, which is most of what the
    /// class sounds like.
    case fpvQuad
    /// Rotorcraft: one or two large rotors rather than many small ones. The catalogue holds a
    /// single example — a tandem-rotor cargo machine — and it flew on a heavy multirotor's
    /// voice until this class existed.
    case helicopter
    case electricFixedWing
    case pistonFixedWing
    case turbopropFixedWing
    case turbojetFixedWing

    var localizationKey: String { "audio.vehicle.class.\(rawValue)" }
}

/// The assets and coupling constants one acoustic class flies with.
struct VehicleAudioProfile: Hashable {
    let audioClass: VehicleAudioClass

    /// The continuous propulsion sound. `nil` when the pack has nothing for this class —
    /// which is the current state for every fuel-burning aircraft, and is reported as a
    /// stated gap rather than filled with a rotor recording of the wrong material.
    let propulsionLoop: AudioAssetID?
    /// Fired once when the rotors start turning.
    let spinUpCue: AudioAssetID?
    /// Fired through a fuel engine's start sequence.
    let engineStartCue: AudioAssetID?
    /// Avionics coming alive. Deliberately *not* the sound of taking off — the plan is
    /// specific that losing the link must not stop the motors and that arming must not be
    /// implied by the electronics being on.
    let electronicsBootCue: AudioAssetID?
    /// Control-surface servos. Only for aircraft that have control surfaces: a multirotor
    /// steers by changing rotor speeds and has nothing to move.
    var mechanismCue: AudioAssetID? = nil

    /// The lift-rotor voice, for an airframe that spends part of its flight hanging on rotors
    /// and the rest on a wing.
    ///
    /// `nil` for everything else, and that is the whole point of the field. It was previously
    /// decided at runtime by asking whether the audio class was a multirotor one — which is
    /// true of every aeroplane — and `vtolWingborneBlend` is zero for an aircraft that has no
    /// wingborne blend to speak of, so the "how much is it still hovering" term read as
    /// *fully hovering*. Every piston, turboprop and turbojet aircraft therefore flew with a
    /// full-level recording of an electric quadcopter mixed over its engine.
    var liftRotorLoop: AudioAssetID? = nil
    var liftRotorReferenceSpeedRadPerSec: Float = 430.0
    var liftRotorTrimDb: Float = 0.0

    /// The propeller in front of the motor, when the two are worth hearing separately.
    ///
    /// The plan describes an electric fixed wing as "motor whine + propeller + airflow", and
    /// those are three things rather than one: the motor's tone is electrical and tied to the
    /// shaft, the propeller's is aerodynamic. Kept as its own layer so each can be driven and
    /// trimmed separately. `nil` wherever the pack has one recording of the whole powerplant,
    /// which is every fuel engine here.
    var propellerLoop: AudioAssetID? = nil
    var propellerTrimDb: Float = 0.0

    /// Whether the propulsion sound comes from a fuel engine's own shaft.
    ///
    /// Decides where the speed reading comes from, and it has to be a property of the
    /// aircraft rather than of the reading: the flight model writes a synthetic rotor speed
    /// for *every* fixed wing, fuel-burning ones included, so a stopped engine still reports
    /// a throttle-derived number on the rotor lanes. Falling back to it made a dead engine
    /// keep running.
    var usesFuelEngine: Bool = false

    /// Shaft speed at which `propulsionLoop` plays at its recorded rate, rad/s.
    ///
    /// Everything is rad/s, engines included, because mixing rev/min and rad/s in the same
    /// struct is how a factor of 9.55 ends up somewhere it does not belong.
    let referenceShaftSpeedRadPerSec: Float
    /// Blades per revolution. The blade-pass frequency is `speed / 2π · blades`, and it is
    /// what the ear actually latches onto — a four-blade prop at 3,000 rpm and a two-blade at
    /// 6,000 rpm hum at the same pitch.
    let bladeCount: Int
    /// Airspeed at which the airflow layer plays at its recorded rate, m/s.
    let referenceAirspeedMps: Float
    /// Level of the propulsion loop at its reference speed, dB relative to the asset's own
    /// authored gain. A heavy industrial multirotor is genuinely louder than a 249 g toy.
    let propulsionTrimDb: Float
    /// Level of the airflow layer at the reference airspeed.
    let airflowTrimDb: Float

    /// How sharply loudness follows shaft speed.
    ///
    /// Rotor noise power grows roughly with the fifth power of tip speed, which would be
    /// 50·log₁₀ in level. That is the free-field figure for an isolated rotor and it is far
    /// too violent here — the operator hears a mix, not an anechoic chamber, and a law that
    /// steep makes idle inaudible and full throttle painful. This is the tamed exponent, and
    /// it is a mixing decision rather than a physical claim.
    static let speedToLevelExponent: Float = 24.0

    /// Chooses a profile from what the aircraft is made of.
    ///
    /// `engineType` is nil for anything on a battery, which is also the fallback for a
    /// profile that predates the fuel catalogue.
    static func resolve(
        airframeClass: AirframeClass,
        engineType: UAVEngineType?,
        rotorCount: Int,
        takeoffMassKg: Float,
        maxHorizontalSpeedMps: Float,
        ratedShaftRPM: Float?,
        propellerBladeCount: Int,
        /// What the catalogue calls this aircraft.
        ///
        /// Needed because `AirframeClass` cannot express it: a helicopter is filed under
        /// `.multirotor` there — correctly, since the flight model treats both as rotor-borne —
        /// and nothing else on the runtime profile distinguishes them. Without this a 57 kg
        /// tandem-rotor machine resolves to "heavy multirotor" and flies on a recording of
        /// small fast propellers. `nil` for an aircraft with no catalogue entry, which falls
        /// back to the rotor-count and mass rules.
        vehicleType: UAVVehicleType? = nil
    ) -> VehicleAudioProfile {
        if vehicleType == .helicopter {
            return helicopterProfile(
                takeoffMassKg: takeoffMassKg,
                rotorCount: rotorCount,
                propellerBladeCount: propellerBladeCount
            )
        }
        switch airframeClass {
        case .multirotor:
            return multirotorProfile(
                rotorCount: rotorCount,
                takeoffMassKg: takeoffMassKg,
                maxHorizontalSpeedMps: maxHorizontalSpeedMps
            )
        case .fixedWing, .hybridVTOL:
            var profile = wingProfile(
                engineType: engineType,
                ratedShaftRPM: ratedShaftRPM,
                propellerBladeCount: propellerBladeCount,
                maxHorizontalSpeedMps: maxHorizontalSpeedMps,
                takeoffMassKg: takeoffMassKg
            )
            // Only a hybrid VTOL has lift rotors to hear. A tilt-rotor in the hover is a
            // multirotor and in cruise is an aeroplane, and it does not stop being either one
            // at a threshold — `vtolWingborneBlend` says how far across it is — so it gets
            // both voices, crossfaded. An ordinary aeroplane gets one voice, because it has
            // one.
            if airframeClass == .hybridVTOL {
                // Sized from the aircraft's own mass and rotor count, so a 25 kg VTOL lifts
                // on the heavy rotor voice rather than on a camera drone's.
                let lift = multirotorProfile(
                    rotorCount: rotorCount,
                    takeoffMassKg: takeoffMassKg,
                    maxHorizontalSpeedMps: 0.0
                )
                profile.liftRotorLoop = lift.propulsionLoop
                profile.liftRotorReferenceSpeedRadPerSec = lift.referenceShaftSpeedRadPerSec
                profile.liftRotorTrimDb = lift.propulsionTrimDb
            }
            return profile
        }
    }

    /// A rotorcraft's voice.
    ///
    /// The distinction that matters is blade-pass frequency. A heavy multirotor's props turn
    /// at several thousand rpm; a helicopter's main rotor turns at a few hundred, with more
    /// blades, and the tone that comes out is an order of magnitude lower. Playing one for the
    /// other is the same class of error as putting a rotor loop under a piston engine.
    private static func helicopterProfile(
        takeoffMassKg: Float,
        rotorCount: Int,
        propellerBladeCount: Int
    ) -> VehicleAudioProfile {
        VehicleAudioProfile(
            audioClass: .helicopter,
            propulsionLoop: .helicopterRotorLoop,
            // A large rotor spinning up is closer to a heavy multirotor's launch than to
            // anything else in the pack. Approximate, and the nearest thing there is.
            spinUpCue: .uavHeavySpinup,
            engineStartCue: nil,
            electronicsBootCue: .fpvElectronicsBoot,
            // Collective and cyclic are the controls, and both are servo-driven.
            mechanismCue: .mechanismServo,
            // The flight model drives rotorcraft through the same multirotor lanes, so the
            // reference is that solver's hover point rather than a real rotor speed. The
            // recording is of a real rotor; the ratio is what moves it.
            referenceShaftSpeedRadPerSec: 430.0,
            bladeCount: max(2, propellerBladeCount),
            referenceAirspeedMps: 16.0,
            // A 57 kg machine is loud.
            propulsionTrimDb: 3.0,
            airflowTrimDb: -14.0
        )
    }

    private static func multirotorProfile(
        rotorCount: Int,
        takeoffMassKg: Float,
        maxHorizontalSpeedMps: Float
    ) -> VehicleAudioProfile {
        // An FPV quad is separated from a camera quad by what it can do, not by its name:
        // four rotors, little mass and a speed a camera drone has no reason to reach.
        let isFPV = rotorCount <= 4 && takeoffMassKg <= 1.6 && maxHorizontalSpeedMps >= 20.0
        let isHeavy = takeoffMassKg >= 8.0 || rotorCount >= 6

        if isFPV {
            return VehicleAudioProfile(
                audioClass: .fpvQuad,
                propulsionLoop: .fpvFlightLoop,
                // A racing quad revs; it does not wind up the way a camera drone does.
                spinUpCue: .fpvSpinup,
                engineStartCue: nil,
                electronicsBootCue: .fpvElectronicsBoot,
                mechanismCue: nil,
                // The multirotor solver runs its lanes at 120 + 640·thrustFraction rad/s
                // (SimpleDronePhysicsEngine), so a rotor holding a hover sits near 440. An FPV
                // quad hovers at a lower fraction of its own capability than anything else
                // here, hence the lower reference.
                referenceShaftSpeedRadPerSec: 380.0,
                bladeCount: 2,
                referenceAirspeedMps: 22.0,
                propulsionTrimDb: -1.0,
                airflowTrimDb: -12.0
            )
        }
        if isHeavy {
            return VehicleAudioProfile(
                audioClass: .heavyMultirotor,
                // Six rotors and four rotors are not the same sound at any level: the
                // blade-pass tones beat against each other differently.
                propulsionLoop: rotorCount >= 6 ? .uavHexFlight : .uavHeavyHoverLoop,
                // Its own launch recording, slowed. Borrowing the small one made a 25 kg
                // machine start up like a 249 g one.
                spinUpCue: .uavHeavySpinup,
                engineStartCue: nil,
                electronicsBootCue: .fpvElectronicsBoot,
                mechanismCue: nil,
                referenceShaftSpeedRadPerSec: 430.0,
                bladeCount: 2,
                referenceAirspeedMps: 16.0,
                propulsionTrimDb: 2.0,
                airflowTrimDb: -14.0
            )
        }
        return VehicleAudioProfile(
            audioClass: .smallMultirotor,
            propulsionLoop: .uavSmallHover,
            spinUpCue: .uavSmallSpinup,
            engineStartCue: nil,
            electronicsBootCue: .fpvElectronicsBoot,
            mechanismCue: nil,
            referenceShaftSpeedRadPerSec: 440.0,
            bladeCount: 2,
            referenceAirspeedMps: 14.0,
            propulsionTrimDb: 0.0,
            airflowTrimDb: -14.0
        )
    }

    private static func wingProfile(
        engineType: UAVEngineType?,
        ratedShaftRPM: Float?,
        propellerBladeCount: Int,
        maxHorizontalSpeedMps: Float,
        takeoffMassKg: Float
    ) -> VehicleAudioProfile {
        // Cruise sits near three quarters of rated on every engine class here, and that is
        // the condition a recording of one would have been made at.
        let cruiseShaftRadPerSec = (ratedShaftRPM.map { $0 * 0.75 } ?? 0.0) * Float.pi / 30.0
        let referenceAirspeed = max(12.0, maxHorizontalSpeedMps * 0.7)
        let blades = max(1, propellerBladeCount)

        switch engineType {
        case .pistonTwoStroke, .pistonFourStroke, .wankelRotary:
            return VehicleAudioProfile(
                audioClass: .pistonFixedWing,
                propulsionLoop: .pistonEngineLoop,
                spinUpCue: nil,
                engineStartCue: .pistonEngineStart,
                electronicsBootCue: .fpvElectronicsBoot,
                mechanismCue: .mechanismServo,
                usesFuelEngine: true,
                referenceShaftSpeedRadPerSec: cruiseShaftRadPerSec > 1.0 ? cruiseShaftRadPerSec : 430.0,
                bladeCount: blades,
                referenceAirspeedMps: referenceAirspeed,
                propulsionTrimDb: 1.0,
                airflowTrimDb: -10.0
            )
        case .turboprop:
            return VehicleAudioProfile(
                audioClass: .turbopropFixedWing,
                propulsionLoop: .turbopropLoop,
                spinUpCue: nil,
                engineStartCue: .turbopropStart,
                electronicsBootCue: .fpvElectronicsBoot,
                mechanismCue: .mechanismServo,
                usesFuelEngine: true,
                referenceShaftSpeedRadPerSec: cruiseShaftRadPerSec > 1.0 ? cruiseShaftRadPerSec : 165.0,
                bladeCount: blades,
                referenceAirspeedMps: referenceAirspeed,
                propulsionTrimDb: 2.0,
                airflowTrimDb: -8.0
            )
        case .turbojet, .ramjet:
            return VehicleAudioProfile(
                audioClass: .turbojetFixedWing,
                propulsionLoop: .turbojetLoop,
                spinUpCue: nil,
                // A ramjet has nothing to start — it is the one engine in the catalogue with
                // no starter at all — so it gets no start cue and no silence to explain.
                engineStartCue: engineType == .ramjet ? nil : .turbojetStart,
                electronicsBootCue: .fpvElectronicsBoot,
                mechanismCue: .mechanismServo,
                usesFuelEngine: true,
                referenceShaftSpeedRadPerSec: cruiseShaftRadPerSec > 1.0 ? cruiseShaftRadPerSec : 3_300.0,
                bladeCount: 1,
                referenceAirspeedMps: referenceAirspeed,
                propulsionTrimDb: 3.0,
                airflowTrimDb: -6.0
            )
        case .electricMotor, .none:
            return VehicleAudioProfile(
                audioClass: .electricFixedWing,
                // Two layers rather than a borrowed quadcopter: a recording of a small
                // electric motor, and a steady propeller over it. This is what the plan asks
                // for — "motor whine + propeller + airflow" — and it is why an electric
                // aeroplane no longer sounds like a racing quad with the pitch pulled down.
                propulsionLoop: .fixedWingElectricMotor,
                spinUpCue: .uavSmallSpinup,
                engineStartCue: nil,
                electronicsBootCue: .fpvElectronicsBoot,
                mechanismCue: .mechanismServo,
                propellerLoop: .fixedWingPropellerLoop,
                propellerTrimDb: 1.0,
                // Back to the speed the aircraft actually cruises at — the fixed-wing solver
                // runs its single lane at 60 + 540·throttle rad/s, so cruise sits near 350 and
                // both recordings play at their own pitch there. This reference was
                // deliberately wrong for a while, pushed to 520 so a borrowed quadcopter clip
                // would at least come out a third lower than the quadcopter's. With real motor
                // and propeller recordings there is nothing left to disguise.
                referenceShaftSpeedRadPerSec: 350.0,
                bladeCount: blades,
                referenceAirspeedMps: referenceAirspeed,
                propulsionTrimDb: 0.0,
                airflowTrimDb: -10.0
            )
        }
    }
}
