import Foundation
import simd

/// What the airframe's own model declares: which hardware exists and where its hinges are.
///
/// Authored with the USDZ (`Tools/UAVModelAssets/expansion_mechanics.py`) and read from the
/// library manifest. Its panel areas and chord ratios come from the same skin cuts as the
/// animated mesh. Aerodynamic effects and actuator times are derived from those quantities.
struct AircraftMechanizationConfiguration: Decodable {
    struct FlapGeometry: Decodable {
        struct Panel: Decodable {
            let name: String
            let side: Int
            let spanStart: Float
            let spanEnd: Float
            let chordRatio: Float
            let coveredAreaFraction: Float
            let panelAreaFraction: Float
            let lateralArm: Float
        }
        let type: AircraftFlapType
        let wingPlanformAreaM2: Float
        let panels: [Panel]
    }
    struct GearHinge: Decodable {
        let center: [Float]
        let axisVector: [Float]
        let retractedDegrees: Float
    }

    let hasFlaps: Bool
    let retractableGear: Bool
    let flapMaxDegrees: Float
    let gearHinges: [GearHinge]
    let flapGeometry: FlapGeometry?

    init(hasFlaps: Bool, retractableGear: Bool, flapMaxDegrees: Float, gearHinges: [GearHinge],
         flapGeometry: FlapGeometry? = nil) {
        self.hasFlaps = hasFlaps
        self.retractableGear = retractableGear
        self.flapMaxDegrees = flapMaxDegrees
        self.gearHinges = gearHinges
        self.flapGeometry = flapGeometry
    }

    static func forProfile(_ id: String) -> Self? {
        UAVExpansionCatalog.definition(for: id)?.mechanics
    }
}

/// Where the flaps and the undercarriage actually are, and what is left of them.
///
/// Plain values only — this lives inside `DroneState`, which is copied on every substep.
struct AircraftMechanizationState: Equatable {
    /// Where the selectors stand: the last position the operator's lever or the autopilot gave
    /// them. The hardware below travels toward these.
    var flapSelection: Float = 0
    var gearSelectedDown = true

    /// Drive position, 0 retracted … 1 full travel. Both panels share one drive.
    var flapDeployment: Float = 0
    var flapAngleRadians: Float = 0
    var gearExtension: Float = 1
    var gearDoorOpening: Float = 0

    /// 1 while the panel is on the aircraft, 0 once it has left it. `x` is the left wing.
    var flapPanelHealth = SIMD2<Float>(repeating: 1)
    /// Per leg, in the manifest's hinge order. 0 is a leg that no longer locks or carries load.
    var gearLegHealth = SIMD4<Float>(repeating: 1)
    var gearDoorsLost = false
    /// Set when the legs failed under the aircraft's own weight rather than in the air.
    var gearCrushedOnGround = false

    /// Air load over the limit load: 1 at the limit speed, `ultimateLoadFactor` at failure.
    /// The larger of the two panels.
    var flapLoadRatio: Float = 0
    /// The larger of the door and leg ratios.
    var gearLoadRatio: Float = 0

    /// One bit per leg that is NOT down, locked and intact. Zero is an undercarriage the
    /// aircraft can stand on, which is also what an airframe with fixed legs always reports.
    var gearUnsupportedMask: UInt8 = 0

    var gearInTransit: Bool { gearDoorOpening > 0.001 || (gearExtension > 0.001 && gearExtension < 0.999) }
    var gearDownAndLocked: Bool { gearUnsupportedMask == 0 }
    var gearLegFailed: Bool { simd_reduce_min(gearLegHealth) <= 0.5 }
    var hasFailure: Bool {
        gearDoorsLost || simd_reduce_min(flapPanelHealth) < 0.5 || simd_reduce_min(gearLegHealth) < 0.5
    }
}

/// The air and the ground as the flaps and the undercarriage meet them on one substep.
struct AircraftMechanizationFlightCondition {
    /// `½ρV²`, which is `½ρ₀·EAS²` — the pressure limit speeds are written against.
    var dynamicPressurePa: Float
    var airspeedMps: Float
    /// The wing on the outside of a turn flies faster and is loaded harder.
    var yawRateRadPerSec: Float
    var heightAboveGroundM: Float
}

/// One airframe's flaps and undercarriage: the hardware its model declares, the
/// characteristics derived for it, and the rules that move and break them.
///
/// Immutable and shared — the physics engine resolves it once per step and never per substep.
final class AircraftMechanizationModel {
    struct Hinge {
        /// Body frame, metres: +X right, +Y up, −Z forward.
        let center: SIMD3<Float>
        let axis: SIMD3<Float>
        /// How much of the air load on the extended leg turns it about its own hinge, 0…1.
        ///
        /// Drag pushes a leg aft. A leg that folds fore-and-aft is being pushed along its own
        /// travel, so the load arrives at its downlock and actuator; a leg that folds sideways
        /// takes the same load in bending on its trunnion, which a touchdown loads far harder
        /// than the air ever does.
        let airloadAlignment: Float
    }

    /// Limit load to failure, CS-23.303: structure carries 1.5 times its limit load.
    static let ultimateLoadFactor: Float = 1.5
    /// Height at which the autopilot raises the undercarriage: the 15 m (50 ft) screen a
    /// takeoff distance is measured to, by which the aircraft is established in the climb.
    static let autopilotGearRetractionHeightM: Float = 15
    /// Share of a limit load the autopilot allows itself. It flies to the limits it is given;
    /// going past them is left to the operator.
    static let autopilotLoadMargin: Float = 0.9
    /// A leg carries load once it is over centre; below this it is still on its actuator.
    static let lockedExtension: Float = 0.98

    let configuration: AircraftMechanizationConfiguration
    let characteristics: AircraftMechanizationCharacteristics
    let hinges: [Hinge]
    private let legMask: UInt8

    /// `modelGroundLift` is the height the visual is raised by so its lowest point rests on
    /// the ground — the same lift the contact profile was measured with.
    init(configuration: AircraftMechanizationConfiguration,
         characteristics: AircraftMechanizationCharacteristics,
         modelGroundLift: Float) {
        self.configuration = configuration
        self.characteristics = characteristics
        // The visual is yawed half a turn into the body frame and lifted onto the ground.
        hinges = configuration.gearHinges.prefix(4).compactMap { hinge in
            guard hinge.center.count == 3, hinge.axisVector.count == 3 else { return nil }
            let axis = SIMD3<Float>(-hinge.axisVector[0], hinge.axisVector[1], -hinge.axisVector[2])
            guard simd_length(axis) > 0.0001 else { return nil }
            let unit = simd_normalize(axis)
            return Hinge(center: SIMD3<Float>(-hinge.center[0], hinge.center[1] + modelGroundLift, -hinge.center[2]),
                         axis: unit, airloadAlignment: abs(unit.x))
        }
        legMask = configuration.retractableGear ? UInt8((1 << hinges.count) - 1) : 0
    }

    // MARK: - Shared instances

    private static let cacheLock = NSLock()
    private static var cache: [String: AircraftMechanizationModel?] = [:]

    /// The model for a catalogue airframe, or `nil` for one that has neither flaps nor a
    /// retractable undercarriage. Built once per airframe.
    static func shared(for profile: DroneModelProfile, uav: UAVProfile?) -> AircraftMechanizationModel? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[profile.id] { return cached }
        let model = make(profile: profile, uav: uav)
        cache[profile.id] = model
        return model
    }

    private static func make(profile: DroneModelProfile, uav: UAVProfile?) -> AircraftMechanizationModel? {
        guard let definition = UAVExpansionCatalog.definition(for: profile.id),
              let configuration = definition.mechanics,
              configuration.hasFlaps || configuration.retractableGear else { return nil }
        let lift = definition.boundsMin.count > 1 ? -definition.boundsMin[1] : 0
        return make(configuration: configuration, profile: profile, uav: uav, modelGroundLift: lift)
    }

    /// Builds a model from an explicit configuration — the catalogue path above, and the
    /// headless probes, which have no installed manifest to read one from.
    static func make(configuration: AircraftMechanizationConfiguration, profile: DroneModelProfile,
                     uav: UAVProfile?, modelGroundLift: Float) -> AircraftMechanizationModel? {
        guard let characteristics = AircraftMechanizationCharacteristics.resolve(
            configuration: configuration, profile: profile, uav: uav, modelGroundLift: modelGroundLift)
        else { return nil }
        return AircraftMechanizationModel(configuration: configuration, characteristics: characteristics,
                                          modelGroundLift: modelGroundLift)
    }

    // MARK: - Actuation

    /// Moves the flaps and the undercarriage to where their selectors stand and loads them
    /// with the air they are standing in.
    ///
    /// A lever the operator has moved is the operator's: its position is taken as given, at any
    /// height and speed and on the ground. A lever left in AUTO (`nil`) belongs to the
    /// autopilot while a guided mode is flying the aircraft, and to nobody in manual flight —
    /// there the selector stays where it was last put. No protection stands behind either:
    /// what an out-of-envelope selection costs is structural, and it is charged below.
    func advance(_ previous: AircraftMechanizationState, control: DroneControlInput,
                 condition: AircraftMechanizationFlightCondition,
                 actuatorAuthority: Float, isDestroyed: Bool, dt: Float) -> AircraftMechanizationState {
        guard dt.isFinite, dt > 0 else { return previous }
        var next = previous
        let c = characteristics
        // A dead flight controller or a wreck moves nothing, but the air keeps loading what is out.
        let drive = isDestroyed || actuatorAuthority <= 0.05 ? 0 : min(1, actuatorAuthority)
        let q = condition.dynamicPressurePa.isFinite ? max(0, condition.dynamicPressurePa) : 0
        let guided = Self.isGuided(control.mode) && drive > 0

        // --- Flaps.
        if configuration.hasFlaps {
            if let lever = control.flapCommand {
                next.flapSelection = Self.unit(lever)
            } else if guided {
                next.flapSelection = autopilotFlapSelection(previous.flapSelection, mode: control.mode,
                                                            dynamicPressurePa: q)
            }
            let target = next.flapSelection
            if drive > 0, simd_reduce_max(previous.flapPanelHealth) > 0.5 {
                next.flapDeployment = Self.approach(previous.flapDeployment, target,
                                                    dt / max(0.1, c.flapTravelSeconds) * drive)
            }
            next.flapAngleRadians = next.flapDeployment * c.flapMaxRad

            // Normal force on a deflected panel grows with `q·sin δ`; the limit is that product
            // at full deflection and the flap limit speed.
            let deflection = sin(next.flapAngleRadians) / max(0.05, sin(c.flapMaxRad))
            let symmetric = q / max(1, c.flapLimitDynamicPressurePa) * deflection
            // Local speed at a panel, as the wing strips see it: `1 ± 2·r̂·y/b`, r̂ = r·b/2V.
            let yawRateHat = condition.yawRateRadPerSec * c.wingSpanM / (2 * max(1, condition.airspeedMps))
            let yaw = (2 * yawRateHat * c.flapLateralArm).clamped(to: -0.5...0.5)
            let left = symmetric * (1 - yaw) * (1 - yaw) * (previous.flapPanelHealth.x > 0.5 ? 1 : 0)
            let right = symmetric * (1 + yaw) * (1 + yaw) * (previous.flapPanelHealth.y > 0.5 ? 1 : 0)
            next.flapLoadRatio = max(left, right)
            if left >= Self.ultimateLoadFactor { next.flapPanelHealth.x = 0 }
            if right >= Self.ultimateLoadFactor { next.flapPanelHealth.y = 0 }
        }

        // --- Undercarriage.
        guard configuration.retractableGear, !hinges.isEmpty else { return next }
        let intact = simd_reduce_max(previous.gearLegHealth) > 0.5
        if let lever = control.landingGearDownCommand {
            next.gearSelectedDown = lever
        } else if guided {
            next.gearSelectedDown = autopilotGearSelection(previous.gearSelectedDown, mode: control.mode,
                                                           dynamicPressurePa: q,
                                                           heightAboveGroundM: condition.heightAboveGroundM)
        }
        let target: Float = next.gearSelectedDown ? 1 : 0
        if drive > 0, intact, !previous.gearCrushedOnGround {
            // Doors open fully before a leg moves and close behind it once it has locked.
            if abs(previous.gearExtension - target) > 0.0001 {
                next.gearDoorOpening = Self.approach(previous.gearDoorOpening, 1, dt / max(0.1, c.doorTravelSeconds) * drive)
                if previous.gearDoorOpening >= 0.9999 || previous.gearDoorsLost {
                    next.gearExtension = Self.approach(previous.gearExtension, target,
                                                       dt / max(0.1, c.gearTravelSeconds) * drive)
                }
            } else {
                next.gearExtension = target
                next.gearDoorOpening = Self.approach(previous.gearDoorOpening, 0, dt / max(0.1, c.doorTravelSeconds) * drive)
            }
        }

        let gearLoad = q / max(1, c.gearLimitDynamicPressurePa)
        let doorRatio = previous.gearDoorsLost ? 0 : gearLoad * next.gearDoorOpening
        if doorRatio >= Self.ultimateLoadFactor { next.gearDoorsLost = true }
        var legRatio: Float = 0
        for index in hinges.indices where next.gearLegHealth[index] > 0.5 {
            let ratio = gearLoad * next.gearExtension * hinges[index].airloadAlignment
            legRatio = max(legRatio, ratio)
            if ratio >= Self.ultimateLoadFactor { next.gearLegHealth[index] = 0 }
        }
        next.gearLoadRatio = max(doorRatio, legRatio)
        next.gearUnsupportedMask = unsupportedMask(next)
        return next
    }

    // MARK: - The autopilot's hand on the levers

    /// Modes in which the autopilot is flying the aircraft and so works the levers left to it.
    static func isGuided(_ mode: DroneFlightMode) -> Bool {
        switch mode {
        case .takeoff, .autoPath, .returnHome, .hover, .landing: return true
        case .manual, .emergencyStop: return false
        }
    }

    /// Flap air load at a setting, as a share of the limit load.
    private func flapLoad(setting: Float, dynamicPressurePa: Float) -> Float {
        dynamicPressurePa / max(1, characteristics.flapLimitDynamicPressurePa)
            * sin(setting * characteristics.flapMaxRad) / max(0.05, sin(characteristics.flapMaxRad))
    }

    /// Takeoff setting for the takeoff, as much flap as the speed allows for the landing, and
    /// clean in between once the aircraft is past 1.2·VS — the takeoff safety speed, below
    /// which the lift is not given away.
    private func autopilotFlapSelection(_ current: Float, mode: DroneFlightMode, dynamicPressurePa q: Float) -> Float {
        let takeoff = AircraftMechanizationCharacteristics.takeoffFlapSetting
        // A setting is taken with a margin in hand and given up only at the limit itself, so
        // the selector does not hunt at the boundary.
        func available(_ setting: Float) -> Bool {
            flapLoad(setting: setting, dynamicPressurePa: q) <= (current >= setting - 0.01 ? 1 : Self.autopilotLoadMargin)
        }
        switch mode {
        case .takeoff:
            return available(takeoff) ? takeoff : 0
        case .landing:
            return available(1) ? 1 : available(takeoff) ? takeoff : 0
        default:
            let safetySpeed = 1.2 * characteristics.stallSpeedCleanMps
            let safetyPressure = 0.5 * AtmosphereModel.seaLevelDensity * safetySpeed * safetySpeed
            return q >= safetyPressure ? 0 : current
        }
    }

    /// Up once the takeoff is past its screen height; down for the landing as soon as the
    /// limit speed allows. On a route nothing lowers it.
    private func autopilotGearSelection(_ current: Bool, mode: DroneFlightMode,
                                        dynamicPressurePa q: Float, heightAboveGroundM: Float) -> Bool {
        if mode == .landing {
            return current || q <= Self.autopilotLoadMargin * characteristics.gearLimitDynamicPressurePa
        }
        return current && heightAboveGroundM < Self.autopilotGearRetractionHeightM
    }

    /// Called while the airframe is resting on, or striking, the ground.
    ///
    /// A leg that is not over centre is held by its actuator alone. Caught between the
    /// aircraft and the ground it folds, and it does not unfold again.
    func touchingGround(_ state: AircraftMechanizationState) -> AircraftMechanizationState {
        guard configuration.retractableGear, !state.gearCrushedOnGround,
              state.gearExtension > 0.02, state.gearExtension < Self.lockedExtension else { return state }
        var next = state
        next.gearCrushedOnGround = true
        next.gearLegHealth = .zero
        next.gearExtension = 0
        next.gearUnsupportedMask = unsupportedMask(next)
        return next
    }

    private func unsupportedMask(_ state: AircraftMechanizationState) -> UInt8 {
        guard legMask != 0 else { return 0 }
        guard state.gearExtension >= Self.lockedExtension else { return legMask }
        var mask: UInt8 = 0
        for index in hinges.indices where state.gearLegHealth[index] <= 0.5 { mask |= 1 << UInt8(index) }
        return mask
    }

    // MARK: - Ground contact

    /// Number of times a contact profile was rebuilt, for the probe that proves it is not
    /// done per substep.
    nonisolated(unsafe) static var contactRebuildCount = 0

    /// The contact profile for the legs that can currently carry the aircraft.
    ///
    /// A leg that is not down and locked holds nothing up, so its spheres are simply absent:
    /// the aircraft meets the ground with whatever is left. The answer depends only on
    /// `gearUnsupportedMask`, which changes when a leg locks, unlocks or fails — callers
    /// rebuild on those events and reuse the result in between.
    func contacts(_ neutral: VehicleContactProfile, unsupportedMask mask: UInt8) -> VehicleContactProfile {
        guard mask != 0, !hinges.isEmpty, !neutral.isEmpty else { return neutral }
        Self.contactRebuildCount &+= 1
        var spheres: [VehicleContactSphere] = []
        spheres.reserveCapacity(neutral.spheres.count)
        for sphere in neutral.spheres {
            guard sphere.componentID.hasPrefix("gear.") else { spheres.append(sphere); continue }
            var leg = 0
            var nearest = Float.greatestFiniteMagnitude
            for index in hinges.indices {
                // Horizontal distance: a wheel hangs below its own hinge.
                let d = simd_length_squared(SIMD2<Float>(hinges[index].center.x - sphere.offset.x,
                                                         hinges[index].center.z - sphere.offset.z))
                if d < nearest { nearest = d; leg = index }
            }
            guard mask & (1 << UInt8(leg)) == 0 else { continue }
            // What still stands is a strut, not an undercarriage: it holds the airframe where
            // it touches, without the levelling and steering a complete set of wheels gives.
            var remaining = sphere
            remaining.isGroundSupport = false
            remaining.supportIntegrity = 0
            spheres.append(remaining)
        }
        guard !spheres.isEmpty else { return neutral }
        return VehicleContactProfile(spheres: spheres, boundingRadius: neutral.boundingRadius,
                                     referenceGroundOffset: neutral.referenceGroundOffset)
    }

    private static func unit(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
    private static func approach(_ current: Float, _ target: Float, _ amount: Float) -> Float {
        let current = unit(current)
        return target > current ? min(target, current + amount) : max(target, current - amount)
    }
}

/// Approach and touchdown guidance for a landing flown with flaps down.
///
/// The stock landing holds a pitch attitude and a power setting and lets the aircraft settle.
/// That works clean. With flaps the same attitude carries far more lift at the same power, and
/// the aircraft floats or climbs — measured, a Heron TP climbed away at 0.7 m/s. So with flaps
/// down the approach is flown the way a slow, draggy approach is flown by hand: pitch holds
/// the speed, power holds the path, and the nose comes up in the flare. With the flaps up this
/// returns `nil` and the stock landing is left as it was.
///
/// ⚠️ The other arrangement — elevator for path, throttle for speed — was tried and measured:
/// the attitude loop of the heavy airframes answers a pitch command two to three seconds late,
/// and a path loop closed through it swung a P.1HH between −11° and +5° into the ground.
struct FixedWingFlapLandingGuidance {
    struct Command {
        let pitchRad: Float
        let throttle: Float
    }

    /// Approach speed over the stall speed in the configuration flown: VREF = 1.3·VS0.
    static let referenceSpeedFactor: Float = 1.3
    /// The standard three-degree approach path.
    static let approachPathRad: Float = 3 * .pi / 180
    /// Sink rate aimed for at the wheels. A third of the least descent velocity an
    /// undercarriage is designed to (CS-23.473: 7 ft/s), which is where a normal landing sits.
    static let touchdownSinkMps: Float = 0.7
    /// The flare starts this many seconds of approach sink above the ground.
    static let flareSeconds: Float = 7
    /// How fast the speed asked for comes down to the reference, m/s². Less than the drag of
    /// the landing configuration gives, so a fast entry is slowed rather than zoomed.
    static let decelerationMps2: Float = 0.5
    /// How far ahead the flare looks, seconds: the heavy airframes answer a pitch change
    /// about this late, and a flare timed on the present height arrives that much too low.
    static let flareLeadSeconds: Float = 1.5

    private var pitchTrim: Float?
    private var throttleTrim: Float?
    private var speedTarget: Float?

    var isActive: Bool { pitchTrim != nil }

    mutating func reset() {
        pitchTrim = nil
        throttleTrim = nil
        speedTarget = nil
    }

    /// - Parameter maximumThrottle: the most power an approach may ask for.
    mutating func command(state: DroneState, heightAboveGroundM: Float,
                          characteristics: AircraftMechanizationCharacteristics,
                          maximumThrottle: Float, dt: Float) -> Command? {
        let deployment = state.mechanization.flapDeployment
        guard deployment > 0.02, dt.isFinite, dt > 0 else {
            reset()
            return nil
        }
        let speed = max(1, state.equivalentAirspeedMps > 1 ? state.equivalentAirspeedMps : state.forwardAirspeed)
        let approachSpeed = Self.referenceSpeedFactor * characteristics.stallSpeed(deployment: deployment)
        // Taken over fast, the aircraft is slowed toward the reference rather than asked for it at once.
        let reference = max(approachSpeed, (speedTarget ?? speed) - Self.decelerationMps2 * dt)
        speedTarget = reference

        // The three-degree path down to the flare, then its sink rate taken off toward the
        // touchdown figure, timed on where the aircraft will be a moment from now.
        let approachSink = speed * sin(Self.approachPathRad)
        let flareHeight = Self.flareSeconds * approachSink
        let touchdown = min(approachSink, Self.touchdownSinkMps)
        let height = max(0, heightAboveGroundM + min(0, state.velocity.y) * Self.flareLeadSeconds)
        let flare = height >= flareHeight ? 0 : 1 - height / max(0.1, flareHeight)
        let targetSink = approachSink + (touchdown - approachSink) * flare
        // As a path angle: too shallow is positive.
        let pathError = ((targetSink + state.velocity.y) / speed).clamped(to: -0.2...0.2)

        // Pitch for speed: fast, raise the nose. Errors are fractions of the reference speed,
        // so one pair of gains serves a 180 kg aircraft and a six-tonne one. In the flare the
        // nose also comes up against the sink and the speed is allowed to go.
        let speedError = ((speed - reference) / reference).clamped(to: -0.5...0.5)
        let speedWeight = 1 - 0.8 * flare
        let pitchIntegral = ((pitchTrim ?? state.orientation.y) + speedError * 0.10 * speedWeight * dt).clamped(to: -0.14...0.21)
        pitchTrim = pitchIntegral
        let pitch = (pitchIntegral + speedError * 0.45 * speedWeight - pathError * 1.6 * flare).clamped(to: -0.17...0.24)

        // Power for path: too shallow wants less of it.
        let ceiling = max(0, maximumThrottle)
        let throttleIntegral = ((throttleTrim ?? state.motorThrottle) - pathError * 1.2 * dt).clamped(to: 0...ceiling)
        throttleTrim = throttleIntegral
        let throttle = (throttleIntegral - pathError * 3.0).clamped(to: 0...ceiling)
        return Command(pitchRad: pitch, throttle: throttle)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
