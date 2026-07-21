import Foundation
import QuartzCore
import SceneKit
import SwiftUI
import AppKit
import simd

struct TelemetryExportAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

struct KeyBindingSection: Identifiable {
    let category: KeyBindingCategory
    let bindings: [KeyBindingDescriptor]

    var id: String { category.id }
}

struct SimulationDiagnostics: Equatable {
    var frameTimeMs: Double
    var physicsTimeMs: Double
    var renderTimeMs: Double
    var pathfindingTimeMs: Double
    var activeObjectCount: Int
    var activePhysicsBodyCount: Int
    var activeParticleCount: Int

    static let zero = SimulationDiagnostics(
        frameTimeMs: 0.0,
        physicsTimeMs: 0.0,
        renderTimeMs: 0.0,
        pathfindingTimeMs: 0.0,
        activeObjectCount: 0,
        activePhysicsBodyCount: 0,
        activeParticleCount: 0
    )
}

private struct DroneControlInputBuilder {
    private struct YawRouting {
        let targetYaw: Float
        let intent: Float
    }

    let controls: DroneControlValues
    let state: DroneState
    let isArmed: Bool
    let mode: DroneFlightMode
    let controlMode: FlightControlMode
    let manualYawIntent: Float
    let usesTargetYawWhileManual: Bool

    func build() -> DroneControlInput {
        let yawRouting = resolveYawRouting()
        let targetPosition = SIMD3<Float>(Float(controls.x), Float(controls.y), Float(controls.z))
        let targetOrientation = SIMD3<Float>(
            Float(controls.roll).degreesToRadians,
            Float(controls.pitch).degreesToRadians,
            yawRouting.targetYaw
        )

        return DroneControlInput(
            targetPosition: targetPosition,
            targetOrientation: targetOrientation,
            yawIntent: yawRouting.intent,
            throttle: Float(controls.throttle),
            isArmed: isArmed,
            mode: mode,
            controlMode: controlMode,
            vtolTransitionLever: Float(controls.vtolTransitionLever)
        )
    }

    private func resolveYawRouting() -> YawRouting {
        if mode == .manual, usesTargetYawWhileManual {
            return YawRouting(
                targetYaw: Float(controls.yaw).degreesToRadians,
                intent: 0.0
            )
        }

        guard mode == .manual else {
            return YawRouting(
                targetYaw: Float(controls.yaw).degreesToRadians,
                intent: 0.0
            )
        }

        return YawRouting(
            targetYaw: state.orientation.z,
            intent: manualYawIntent
        )
    }
}

private struct FixedWingAssistOverrideAxes: OptionSet {
    let rawValue: Int

    static let turn = FixedWingAssistOverrideAxes(rawValue: 1 << 0)
    static let altitude = FixedWingAssistOverrideAxes(rawValue: 1 << 1)
    static let all: FixedWingAssistOverrideAxes = [.turn, .altitude]
}

private enum VTOLAutopilotPhase: String, Equatable {
    case idleGrounded
    case verticalTakeoff
    case hoverHold
    case transitionToCruise
    case wingborneCruise
    case transitionToHover
    case precisionHover
    case verticalLanding
    case emergencyHover
    case forcedLanding
    case transitionAbort
}

private enum VTOLAutopilotSafetyState: Equatable {
    case nominal
    case transitionBlocked(String)
    case transitionAborting(String)
    case emergencyHover(String)
    case forcedLanding(String)
}

private struct VTOLAutopilotDecision: Equatable {
    var phase: VTOLAutopilotPhase
    var target: SIMD3<Float>
    var targetAltitude: Float
    var targetAirspeed: Float?
    var targetHeading: Float?
    var maxSinkRate: Float
    var transitionLever: Double
    var speedScale: Float
    var safetyState: VTOLAutopilotSafetyState
    var reason: String
}

private struct DroneWarningBuilder {
    let isArmed: Bool
    let physicalState: DronePhysicalState
    let collisionAnalysis: CollisionAnalysisSnapshot
    let weather: WeatherModel
    let batteryState: BatteryState
    let batteryFireActive: Bool
    let damageState: DamageState
    let collisionAftermathState: CollisionAftermathState
    let signalLossCause: SignalLossCause?
    let payloadSelfInteractionSeverity: Float
    let selectedDroneProfile: DroneModelProfile
    let state: DroneState
    let fleetStatus: FleetStatus
    let mode: DroneFlightMode

    func build() -> [String] {
        var output: [String] = []
        let grounded = physicalState.isGroundRestState || state.position.y <= 0.08
        let activelyFlying = isArmed && !grounded

        if !isArmed { output.append("warning.disarmed") }
        if physicalState == .crashed { output.append("warning.crashed") }
        if activelyFlying, collisionAnalysis.riskScore >= 0.65 { output.append("warning.collision_high") }
        if weather.severityScore >= 0.7 { output.append("warning.weather_severe") }
        if batteryState.chargePercent <= 20 { output.append("warning.battery_low") }
        if batteryFireActive { output.append("warning.battery_fire") }
        if damageState.averageHealth <= 0.70 { output.append("warning.integrity_low") }
        if damageState.isFlightCritical { output.append("warning.integrity_critical") }
        switch collisionAftermathState {
        case .nominal:
            break
        case .impactRecovery:
            output.append("warning.impact_detected")
        case .damaged:
            output.append("warning.stability_degraded")
        case .emergencyDescent:
            output.append("warning.emergency_descent")
            output.append("warning.control_reduced")
        case .crashed:
            output.append("warning.crash_state")
        }
        if signalLossCause == .impactDamage {
            output.append("warning.signal_lost_impact")
        }
        if payloadSelfInteractionSeverity > 0.05 {
            output.append("warning.payload_self_interference")
        }
        if selectedDroneProfile.airframeClass == .fixedWing,
           let wing = selectedDroneProfile.fixedWingParameters,
           activelyFlying,
           state.forwardAirspeed < wing.minSustainableSpeedMps * 0.9 {
            output.append("warning.fixedwing_low_speed")
        }
        if activelyFlying, fleetStatus.enabled, fleetStatus.interDroneRisk >= 0.5 { output.append("warning.fleet_risk") }
        if fleetStatus.enabled,
           activelyFlying,
           fleetStatus.nearestInterDroneDistance.isFinite,
           fleetStatus.nearestInterDroneDistance < 1.5 {
            output.append("warning.interdrone_critical")
        }
        if mode == .emergencyStop, activelyFlying { output.append("warning.emergency") }

        return output
    }
}

private enum ReturnHomeStage: String {
    case idle
    case ascend
    case navigate
    case align
    case descend
}

enum UAVSignalState: Equatable {
    case normal
    case outOfBoundsWarning
    case signalDegrading
    case boundaryCountdown
    case signalLost
    case recoveryPending

    var isCountdownActive: Bool {
        switch self {
        case .boundaryCountdown:
            return true
        case .normal, .outOfBoundsWarning, .signalDegrading, .signalLost, .recoveryPending:
            return false
        }
    }

    var isInteractionBlocking: Bool {
        switch self {
        case .signalLost, .recoveryPending:
            return true
        case .normal, .outOfBoundsWarning, .signalDegrading, .boundaryCountdown:
            return false
        }
    }
}

struct SignalInterferencePresentation: Equatable {
    let state: UAVSignalState
    let countdownText: String?
    let intensity: Double
    let warningTitle: String?
    let warningDetail: String?
    let lostTitle: String?
    let lostMessage: String?
    let recoveryButtonTitle: String?

    var isVisible: Bool {
        state != .normal
    }

    var isInteractionBlocking: Bool {
        state.isInteractionBlocking
    }
}

private enum CollisionAftermathState: String {
    case nominal
    case impactRecovery
    case damaged
    case emergencyDescent
    case crashed
}

private enum SignalLossCause: String {
    case linkRange
    case impactDamage
}

private struct PayloadProximityEffect {
    enum SeverityLevel: String {
        case minor
        case moderate
        case severe
        case catastrophic
    }

    var severity: SeverityLevel
    var normalizedIntensity: Float
    var damageEnergy: Float
    var stabilityDisturbance: Float
    var controlPenalty: Float
    var missionFailureRequired: Bool
    var forcedCrashRequired: Bool
}

private struct PayloadProximityEffectModel {
    func evaluate(
        impact: DroneSimulationViewModel.TerrainMapPayloadImpact,
        payload: PayloadConfiguration,
        dronePosition: SIMD3<Float>,
        droneVelocity: SIMD3<Float>,
        profile: DroneModelProfile
    ) -> PayloadProximityEffect? {
        let dronePlanar = SIMD2<Float>(dronePosition.x, dronePosition.z)
        let distance = simd_distance(dronePlanar, impact.position)
        let verticalSeparation = max(0.0, dronePosition.y)
        let relativeSpeed = simd_length(droneVelocity) + impact.measuredImpactSpeedMps * 0.32
        let massFactor = max(0.4, payload.payloadMass / max(0.2, payload.payloadType.defaultMass))
        let typeFactor: Float = 0.92
        let distanceFactor = (1.0 - distance / max(0.35, impact.falloffRadius * 1.55)).clamped(to: 0.0...1.0)
        let altitudeFactor = (1.0 - verticalSeparation / 4.2).clamped(to: 0.0...1.0)
        let speedFactor = (relativeSpeed / 16.0).clamped(to: 0.2...1.55)
        let normalizedIntensity = (distanceFactor * altitudeFactor * speedFactor * massFactor * typeFactor).clamped(to: 0.0...2.0)

        guard normalizedIntensity >= 0.10 else {
            return nil
        }

        let severity: PayloadProximityEffect.SeverityLevel
        if normalizedIntensity >= 1.25 {
            severity = .catastrophic
        } else if normalizedIntensity >= 0.82 {
            severity = .severe
        } else if normalizedIntensity >= 0.46 {
            severity = .moderate
        } else {
            severity = .minor
        }

        let airframeScale: Float = profile.airframeClass == .fixedWing ? 1.15 : 1.0
        let damageEnergy = (normalizedIntensity * 6.8 * airframeScale).clamped(to: 0.22...11.5)
        let disturbance = (normalizedIntensity * 0.86).clamped(to: 0.12...1.25)
        let controlPenalty = (normalizedIntensity * 0.44).clamped(to: 0.05...0.88)

        return PayloadProximityEffect(
            severity: severity,
            normalizedIntensity: normalizedIntensity,
            damageEnergy: damageEnergy,
            stabilityDisturbance: disturbance,
            controlPenalty: controlPenalty,
            missionFailureRequired: severity == .severe || severity == .catastrophic,
            forcedCrashRequired: severity == .catastrophic
        )
    }
}

private enum SignalLossConfiguration {
    static let countdownDuration = 8
    /// How long the radio link must sit continuously in the nominal zone before
    /// `controlLinkFailsafeLatched` clears — a momentary blip crossing back into range shouldn't
    /// immediately re-authorize arming.
    static let stableReconnectionRequiredSeconds: Float = 1.5
}

/// Fixed-wing/hybridVTOL control-link failsafe orbit tuning — a real loiter/glide (not the
/// open-loop constant-15°-bank the sequence originally used, whose turn radius at cruise speed
/// was wide enough that 8 seconds barely curved the flight path, letting the aircraft drift far
/// enough to fly over unrendered terrain past the world's outer belt).
private enum ControlLinkFailsafeOrbitTuning {
    // Sized so a typical fixed-wing cruise speed can actually achieve this turn radius at
    // `maxBankDegrees` (r = v²/(g·tanφ) — a tighter target than the achievable turn radius would
    // just leave the aircraft perpetually overshooting the ring instead of settling into a circle).
    static let radiusMeters: Float = 220.0
    static let courseErrorToBankGain: Float = 1.8
    static let maxBankDegrees: Double = 35.0
}

private extension Int {
    func positiveModulo(_ modulus: Int) -> Int {
        guard modulus > 0 else {
            return 0
        }

        let remainder = self % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}

extension DroneSimulationViewModel {
    enum PayloadImpactOutcome: String, Equatable {
        case generic
        case onTarget
        case nearTarget
        case offTarget

        var messageKey: String {
            switch self {
            case .generic:
                return "payload.message.dropped_successfully"
            case .onTarget:
                return "payload.message.impact_within_target"
            case .nearTarget:
                return "payload.message.impact_near_target"
            case .offTarget:
                return "payload.message.impact_off_target"
            }
        }

        var overlayTitleKey: String {
            switch self {
            case .generic:
                return "tactical.map.overlay.payload_impact"
            case .onTarget:
                return "tactical.map.overlay.payload_on_target"
            case .nearTarget:
                return "tactical.map.overlay.payload_near_target"
            case .offTarget:
                return "tactical.map.overlay.payload_off_target"
            }
        }

        var missionStatusKey: String? {
            switch self {
            case .generic:
                return nil
            case .onTarget:
                return "mission.status.payload_on_target"
            case .nearTarget:
                return "mission.status.payload_near_target"
            case .offTarget:
                return "mission.status.payload_off_target"
            }
        }
    }

    struct TerrainMapPayloadImpact: Equatable {
        let position: SIMD2<Float>
        let coreRadius: Float
        let falloffRadius: Float
        let outcome: PayloadImpactOutcome
        let measuredImpactSpeedMps: Float
    }

    struct TerrainMapMissionWaypoint: Identifiable, Equatable {
        let id: UUID
        let label: String
        let position: SIMD2<Float>
        let acceptanceRadius: Float
        let isActive: Bool
        let isAssistSelected: Bool
        let isCompleted: Bool
    }

    struct TerrainMapObject: Identifiable, Equatable {
        let id: UUID
        let kind: EnvironmentObjectKind
        let position: SIMD2<Float>
        let footprint: SIMD2<Float>
    }

    struct TerrainMapSnapshot: Equatable {
        let preset: TerrainPreset
        let mapScale: MapScale
        let worldHalfExtent: Float
        let terrainSeed: UInt64
        let operationalRadius: Float
        let linkQualityRadius: Float
        let degradedLinkRadius: Float
        let lostLinkRadius: Float
        let hardWorldBoundsRadius: Float
        let currentMapSuitability: MapScaleSuitability
        let airframeClass: AirframeClass
        let dockPosition: SIMD2<Float>
        let dronePosition: SIMD2<Float>
        let dronePlanarVelocity: SIMD2<Float>
        let droneYawRadians: Float
        let droneAltitude: Float
        let targetMarkerPosition: SIMD2<Float>?
        let missionRoutePoints: [SIMD2<Float>]
        let activeLegPoints: [SIMD2<Float>]
        let predictedPathPoints: [SIMD2<Float>]
        let missionWaypoints: [TerrainMapMissionWaypoint]
        let noFlyZones: [MissionZone]
        let payloadImpact: TerrainMapPayloadImpact?
        let trail: [SIMD2<Float>]
        let objects: [TerrainMapObject]

        static let empty = TerrainMapSnapshot(
            preset: TerrainConfiguration.default.preset,
            mapScale: TerrainConfiguration.default.mapScale,
            worldHalfExtent: TerrainConfiguration.default.worldHalfExtent,
            terrainSeed: TerrainConfiguration.default.seed,
            operationalRadius: 0.0,
            linkQualityRadius: 0.0,
            degradedLinkRadius: 0.0,
            lostLinkRadius: 0.0,
            hardWorldBoundsRadius: TerrainConfiguration.default.hardWorldBoundsRadius,
            currentMapSuitability: .acceptable,
            airframeClass: .multirotor,
            dockPosition: SIMD2<Float>(repeating: 0.0),
            dronePosition: SIMD2<Float>(repeating: 0.0),
            dronePlanarVelocity: SIMD2<Float>(repeating: 0.0),
            droneYawRadians: 0.0,
            droneAltitude: 0.0,
            targetMarkerPosition: nil,
            missionRoutePoints: [],
            activeLegPoints: [],
            predictedPathPoints: [],
            missionWaypoints: [],
            noFlyZones: [],
            payloadImpact: nil,
            trail: [],
            objects: []
        )
    }
}

@MainActor
final class DroneSimulationViewModel: ObservableObject {
    private static let simulationTickInterval: TimeInterval = 1.0 / 60.0

    @Published private(set) var controlValues: DroneControlValues
    @Published private(set) var telemetry: TelemetrySnapshot
    @Published private(set) var mode: DroneFlightMode
    @Published private(set) var flightControlMode: FlightControlMode
    @Published private(set) var isSimulationRunning: Bool

    // MARK: - FPV OSD overlay inputs
    // Feed the aircraft-camera "digital viewfinder" HUD (`FPVViewportOverlayView`). All computed
    // from already-published state (read at the overlay's redraw cadence), so there is no extra
    // per-frame @Published churn.

    /// Left transmitter stick (Mode 2 layout): `x` = yaw stick, `y` = throttle position, each in
    /// −1...1 with `y = +1` at full throttle. Yaw comes from the live resolved pilot input and
    /// throttle from the commanded motor value, so the OSD stick reads neutral under autopilot —
    /// which is correct, the pilot isn't touching it.
    var fpvLeftStick: CGPoint {
        CGPoint(
            x: clampedUnitAxis(resolvedInputState.yaw),
            y: clampedUnitAxis(controlValues.throttle * 2.0 - 1.0)
        )
    }

    /// Right transmitter stick (Mode 2 layout): `x` = roll stick, `y` = pitch stick, each in −1...1.
    var fpvRightStick: CGPoint {
        CGPoint(
            x: clampedUnitAxis(resolvedInputState.roll),
            y: clampedUnitAxis(resolvedInputState.pitch)
        )
    }

    /// Whether the onboard DVR (mission replay recorder) is actively capturing — drives the FPV
    /// OSD's blinking "Rec." tag.
    var isOnboardRecording: Bool { missionReplayRecorder.isRecording }

    private func clampedUnitAxis(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, -1.0), 1.0)
    }
    @Published private(set) var currentProjectID: String
    @Published private(set) var currentProjectName: String
    @Published private(set) var hasUnsavedChanges: Bool
    @Published private(set) var simulationRunMode: SimulationRunMode
    @Published private(set) var onlineSessionConfig: OnlineTrialSessionConfig?
    @Published private(set) var localOnlineParticipant: LocalOnlineParticipant?
    @Published private(set) var onlineRuntimeContext: OnlineTrialRuntimeContext?
    @Published private(set) var onlineFleetState: OnlineTrialFleetState?
    @Published private(set) var onlineAuthorityRegistry: OnlineObjectAuthorityRegistry?
    // P2P v1.2: replicated collision events can revoke local vehicle control authority
    // by setting disabled/crashed state.
    @Published private(set) var onlineDamageState = OnlineVehicleDamageState()
    @Published private(set) var onlineRemoteSnapshotState = OnlineRemoteVehicleSnapshotState()
    @Published private(set) var onlineInterpolatedRemoteStates: [OnlineVehicleInterpolatedState] = []
    private var onlineInterpolationStore = OnlineVehicleInterpolationStore()
    // P2P v1.3: diagnostics mirrored from LANSessionViewModel via applyOnlineDiagnostics.
    @Published private(set) var onlineRuntimeDiagnostics = OnlineRuntimeNetworkDiagnostics()

    // v1.4.6: activity-state-driven performance policy
    @Published private(set) var performancePolicy = RuntimePerformancePolicy.default
    private var backgroundTickSkipCounter = 0
    // Window visibility is set by delegate events; combined with input recency → activityState.
    private var currentVisibilityState: RuntimeVisibilityState = .activeVisible
    private var lastUserInteractionAt: TimeInterval = CACurrentMediaTime()

    // v1.4.4: Hz/FPS counters for PERF diagnostics; reset each second in tick().
    private var diagSnapshotOutCount: Int = 0
    private var diagSnapshotInCount: Int = 0
    private var diagSceneApplyCount: Int = 0
    private var diagRenderFrameCount: Int = 0
    private var lastThermalDiagnosticsUpdate: TimeInterval = 0.0
    private var lastThermalRenderFrameHop: TimeInterval = 0.0
    private var diagLastResetTime: TimeInterval = 0
    private var diagLastComputedHz = (out: 0.0, rx: 0.0, sceneApply: 0.0, renderFPS: 0.0)
    // Throttle @Published onlineInterpolatedRemoteStates; interval driven by policy.overlayPublishInterval.
    private var lastRemoteStatesPublishTime: TimeInterval = 0
    // v1.4.6: time-gated remote scene apply (policy.remoteSceneApplyInterval)
    private var lastOnlineSceneApplyTime: TimeInterval = 0
    private var previousPayloadCameraVelocity: SIMD3<Float>?
    private var previousPayloadCameraAngularVelocity: SIMD3<Float>?

    @Published private(set) var availableDroneProfiles: [DroneModelProfile]
    @Published private(set) var selectedDroneProfile: DroneModelProfile
    @Published private(set) var activeUAVProfile: UAVProfile?
    @Published private(set) var uavCatalogFilterState: UAVFilterState
    @Published private(set) var abstractParameters: AbstractDroneParameters

    @Published private(set) var weather: WeatherModel
    @Published private(set) var terrain: TerrainConfiguration
    @Published private(set) var cameraConfiguration: CameraConfiguration
    /// The chase/orbit mode auto-zoom-into-FPV last engaged from — where zooming back out of
    /// FPV returns to. See `applyContinuousCameraZoom`'s `.fpv` case.
    private var lastDistanceCameraMode: CameraMode = .follow
    /// True only while the current FPV session was entered via `engageFPVFromZoom()` (holding
    /// "+" in chase/orbit until it passes into the airframe). Gates the zoom-out-exits-FPV
    /// behavior so it does NOT fire when FPV was entered directly (e.g. the "4" hotkey via
    /// `setCameraMode`/`cycleCameraMode`/preset selection) — in that case "-" should only narrow
    /// FPV's own FOV zoom back down, exactly like before this feature existed.
    private var fpvEnteredViaZoomEngage: Bool = false

    // Matches the weather envelope sphere's own visibility gate in DroneSceneController
    // (`updateWeatherEnvelope`), which shows the haze at preset selection alone — its opacity
    // formula has a non-zero floor (`0.25 + intensity*0.55`) so it's visible even at
    // intensity == 0. Originally also required `normalizedIntensity > 0` here, which meant
    // picking a fog/smog preset without separately raising intensity showed the envelope haze
    // but never enabled blur — inconsistent with what the user actually sees on screen.
    var wantsWeatherDepthOfField: Bool {
        weather.preset == .fog || weather.preset == .smog
    }

    // Plain computed read for the diagnostics panel — deliberately *not* round-tripped through
    // a callback from DroneSceneViewRepresentable: an earlier version had updateNSView report
    // back via a closure that set an @Published property, which triggered another SceneViewportView
    // body re-evaluation, another updateNSView call, another callback — an unbounded SwiftUI
    // re-render loop that pegged CPU even with no weather active. Never feed view-update-cycle
    // callbacks back into @Published state on the same observed object.
    var weatherDepthOfFieldAppliedStatus: String {
        "wants=\(wantsWeatherDepthOfField)"
    }

    private(set) var batteryState: BatteryState
    private(set) var collisionAnalysis: CollisionAnalysisSnapshot
    @Published private(set) var damageState: DamageState
    private(set) var thermalState: ThermalState
    @Published private(set) var fleetStatus: FleetStatus

    @Published private(set) var warnings: [String]
    @Published private(set) var diagnostics: SimulationDiagnostics
    @Published private(set) var lastCollisionSource: String
    @Published private(set) var lastCollisionDetail: String = "n/a"
    // Decremented only while preset == .thunderstorm (see updateThunderstormLightning) — picking
    // the preset doesn't reset it, so toggling away and back resumes the same wait rather than
    // restarting a fresh 60-600s window every time.
    private var nextLightningStrikeCountdown: Float = Float.random(in: 60...600)
    @Published private(set) var lastModeTransitionReason: String
    @Published private(set) var fixedWingLastTransitionReason: String?
    @Published private(set) var fixedWingAutopilotDebugState: FixedWingAutopilotDebugState
    @Published private(set) var fixedWingBatteryWarningLevel: FixedWingMissionBatteryLevel
    @Published private(set) var fixedWingAssistState: FixedWingAssistState
    @Published var collisionDebugEnabled: Bool
    @Published var showBatteryDepletedDialog: Bool
    @Published var diagnosticMode: DiagnosticOverlayMode
    @Published var isToolPanelVisible: Bool
    @Published var isParametersPanelVisible: Bool
    @Published var activeControlModule: ControlModule?
    @Published private(set) var isPayloadPanelVisible: Bool
    /// Separate top-level panel from `isPayloadPanelVisible` — the fiber-optic control link is
    /// not mission payload (see `UAVControlLinkType`), so it gets its own toolbar entry/overlay
    /// rather than living inside the payload editor.
    @Published private(set) var isCommsLinkPanelVisible = false
    @Published var isBoundaryBarrierVisible: Bool
    @Published var isCompactTelemetryHUDEnabled: Bool
    @Published var telemetryExportAlert: TelemetryExportAlert?
    @Published private(set) var keyBindingSections: [KeyBindingSection]
    @Published private(set) var keyBindingConflicts: [String]
    @Published private(set) var selectedCameraPreset: CameraPreset
    @Published private(set) var isArmed: Bool
    @Published private(set) var physicalState: DronePhysicalState
    @Published private(set) var payloadDraftConfiguration: PayloadConfiguration
    /// Independent comms/control-link equipment slot — separate from the mission payload bay
    /// above (see `UAVControlLinkType`), so an aircraft can carry a fiber spool and a camera/
    /// sprayer/etc. at the same time rather than competing for one slot.
    @Published private(set) var fiberSpoolDraftConfiguration = FiberSpoolModule()
    @Published private(set) var isFiberSpoolAttached = false
    @Published private(set) var fiberLinkState = FiberLinkState()
    @Published private(set) var controlLinkFailsafeStage: ControlLinkFailsafeStage = .none
    /// Which event triggered the currently-running (or most recently completed) failsafe stage —
    /// same state machine either way, only the HUD text differs.
    @Published private(set) var controlLinkFailsafeTrigger: ControlLinkFailsafeTrigger = .fiberBroken
    /// Persists independently of `controlLinkFailsafeStage` reaching a terminal value (landed/
    /// crashed) — a landing ends the aircraft's *motion*, it does not repair whatever caused the
    /// control link to be lost. Gates `resolveArmAuthorization()` until an explicit recovery event
    /// clears it: for radio, a stable reconnection held for `stableReconnectionRequiredSeconds`
    /// (`updateControlLinkFailsafeLatchRecovery`); for fiber, only detaching/reattaching a reel
    /// (a real repair/replacement action), never automatically.
    @Published private(set) var controlLinkFailsafeLatched = false
    /// Live, continuously-recomputed reason `arm()` would currently be refused (`.none` when
    /// arming is allowed) — surfaced to the HUD so the block is visible before the player even
    /// tries, not just as a rejected-command flash.
    @Published private(set) var armBlockReason: ArmBlockReason = .none
    /// Explicit opt-in (default off) to let an autonomous mission keep flying unattended after a
    /// fiber break instead of the default `.returnHome` — must be a deliberate setting, not
    /// default behavior.
    @Published var continueMissionOnFiberLoss = false
    @Published private(set) var payloadState: PayloadState
    @Published private(set) var payloadMountState: PayloadMountState
    @Published private(set) var payloadCapabilityCheck: PayloadCapabilityCheck
    @Published private(set) var vehicleMassModel: VehicleMassModel
    @Published private(set) var payloadStatusMessageKey: String?
    @Published private(set) var simulationLaunchConfiguration: SimulationLaunchConfiguration?
    // Mission scenario (SAR) runtime state, surfaced for the in-sim HUD.
    @Published private(set) var missionScenarioObjectiveState: MissionScenarioObjectiveState?
    @Published private(set) var missionScenarioRemainingSeconds: Double = 0.0
    @Published private(set) var missionScenarioDetectionProgress: Double = 0.0
    @Published private(set) var fireResponseObjectiveState: FireResponseObjectiveState?
    @Published private(set) var fireResponseRemainingSeconds: Double = 0.0
    @Published private(set) var fireResponseBurningCount: Int = 0
    @Published private(set) var fireResponseTotalCount: Int = 0
    @Published private(set) var fireResponseOutcome: FireResponseOutcome?
    @Published private(set) var missionScenarioOutcome: MissionScenarioOutcome?
    @Published private(set) var mountedCADPayload: MountedCADPayload?
    @Published private(set) var lastPayloadImpact: TerrainMapPayloadImpact?
    @Published private(set) var signalState: UAVSignalState
    @Published private(set) var signalCountdownSecondsRemaining: Int
    @Published private(set) var isTerrainMapVisible: Bool
    @Published private(set) var isMissionMapVisible: Bool
    @Published private(set) var missionMapMode: MissionMapMode
    @Published private(set) var terrainMapSnapshot: TerrainMapSnapshot
    @Published private(set) var targetMarkerState: TargetMarkerState?
    @Published private(set) var missionPlanState: MissionPlanningState
    @Published private(set) var missionPlanningDraft: MissionPlanningState
    @Published private(set) var isInMissionDropZone: Bool
    @Published private(set) var tacticalMapState: TacticalMapState
    @Published private(set) var tacticalMapMode: TacticalMapMode
    @Published private(set) var currentMissionPlan: MissionPlan?
    @Published private(set) var missionExecutionState: MissionExecutionState
    @Published private(set) var missionStatusSnapshot: MissionStatusSnapshot
    @Published private(set) var missionTimeline: MissionTimeline?
    @Published private(set) var missionDebrief: MissionDebrief?
    @Published private(set) var isCompassVisible: Bool
    @Published private(set) var payloadCameraStatus: PayloadCameraStatus
    @Published private(set) var payloadCameraOpticsState: PayloadCameraOpticsState
    @Published private(set) var rangefinderOpticsState = PayloadRangefinderOpticsState()
    @Published private(set) var hoseOpticsState = PayloadFireHoseOpticsState()
    @Published private(set) var capsuleState = PayloadFireCapsuleState()
    @Published private(set) var agriculturalSprayerState = PayloadAgriculturalSprayerState()
    /// Whether the hose-tether constraint is currently in effect (a fire-response mission with an
    /// attached, available hose payload) — false in every other scenario/payload combination.
    @Published private(set) var isHoseTetherActive = false
    /// True the instant the drone is being held at the tether's radius — a real taut rope, not a
    /// warning-only state.
    @Published private(set) var isHoseTetherTaut = false
    @Published private(set) var hoseTetherDistanceMeters: Float = 0.0
    @Published private(set) var hoseTetherLimitMeters: Float = 0.0
    @Published private(set) var payloadThermalState: PayloadThermalState = .default
    @Published private(set) var payloadMissionSignals: [PayloadMissionSignal]
    @Published private(set) var isPayloadCameraAutoSwitchEnabled: Bool
    @Published private(set) var controllerInteractionMode: ControllerInteractionMode = .flight
    @Published private(set) var activeInputSourceKind: InputSourceKind?
    @Published private(set) var activeGameControllerName: String?
    @Published private(set) var connectedGameControllers: [GameControllerDeviceSummary] = []
    @Published private(set) var gameControllerRightStickHorizontalMode: GameControllerRightStickHorizontalMode = .yawLeftRight
    @Published private(set) var isControllerCursorEnabled: Bool = false
    @Published private(set) var isControllerHubVisible: Bool = false
    @Published var controllerHubSection: ControllerHubSection = .connectedDevices
    @Published private(set) var isMissionReplayRecording: Bool = false
    @Published private(set) var lastMissionReplaySession: MissionReplaySession?
    @Published private(set) var lastMissionReport: MissionReport?
    /// First-person hand-launch hold: the scene is viewed through the eyes of
    /// the (unmodelled) operator whose arm carries the airframe. Published so
    /// the viewport re-resolves its point of view and mouse-look routing.
    @Published private(set) var isHandLaunchPOVActive: Bool = false

    let bindingsViewModel: BindingsViewModel
    let compassViewModel: CompassViewModel
    let controllerSettingsStore: ControllerSettingsStore
    let controllerUIBridge: ControllerUIBridge

    var scene: SCNScene {
        sceneController.scene
    }

    var activeCameraNode: SCNNode {
        sceneController.pointOfView(for: cameraConfiguration.mode)
    }

    var payloadCameraPointOfView: SCNNode? {
        sceneController.payloadCameraPointOfView()
    }

    var isSpectatorMode: Bool {
        simulationRunMode.isSpectator
    }

    var onlineTrialContext: OnlineTrialRuntimeContext? {
        onlineRuntimeContext
    }

    var onlineTrialStaleRemoteCount: Int {
        onlineInterpolatedRemoteStates.filter { $0.sourceSnapshotAge > 1.0 }.count
    }

    func hasLocalAuthority(over objectID: UUID) -> Bool {
        onlineAuthorityRegistry?.hasLocalAuthority(objectID: objectID) ?? true
    }

    var canControlLocalVehicle: Bool {
        guard LANRuntimeRolePolicy.canControlVehicle(context: onlineRuntimeContext) else { return false }
        // P2P v1.2: collision damage state can revoke local vehicle authority.
        if let vehicleID = onlineRuntimeContext?.localVehicleID,
           onlineDamageState.isControlDisabled(vehicleID: vehicleID) {
            return false
        }
        return true
    }

    /// True for the whole fiber-severance failsafe sequence (braking/hoverFailsafe/landing,
    /// stabilize/loiterGlide/emergencyLanding) — blocks player input the same way
    /// `signalState.isInteractionBlocking` does, so the autonomous recovery isn't fought by the
    /// player's own stick.
    var isControlLinkFailsafeActive: Bool {
        controlLinkFailsafeStage.isActive
    }

    /// Gates whether the existing world-boundary/geofence signal-loss machinery applies at all
    /// (see `UAVControlLinkType`) — `.fiberOptic` only while the reel is actually mounted and the
    /// link hasn't already broken (once broken, `ControlLinkFailsafeStage` owns recovery, not a control
    /// "link type").
    /// Deliberately stays `.fiberOptic` even after the link breaks — a severed fiber doesn't
    /// fall back to radio, it's just gone, and the aircraft is on `ControlLinkFailsafeStage`'s own
    /// autonomous recovery until it lands. Handing control back to the geofence/radio signal-loss
    /// machine mid-failsafe would let it fight (or freeze) the failsafe's own flight commands.
    var activeControlLinkType: UAVControlLinkType {
        isFiberSpoolAttached ? .fiberOptic : .radio
    }

    var showsFixedWingLaunchStatus: Bool {
        selectedDroneProfile.airframeClass == .fixedWing &&
            selectedDroneProfile.supportedLaunchModes.contains {
                $0 == .handLaunch || $0 == .catapult
            }
    }

    var canInitiateTakeoffCommand: Bool {
        guard isArmed,
              !batteryState.isDepleted,
              physicalState != .crashed else {
            return false
        }
        guard selectedDroneProfile.airframeClass == .fixedWing else {
            return true
        }
        let launchMode = activeLaunchMode()
        guard launchMode == .handLaunch || launchMode == .catapult else {
            return true
        }
        return selectedDroneProfile.supportedLaunchModes.contains(launchMode) &&
            activeLaunchAsset() != nil
    }

    var fixedWingLaunchMode: LaunchMode {
        activeLaunchMode()
    }

    var fixedWingLaunchState: LaunchState {
        launchState
    }

    var fixedWingLaunchProgress: Double {
        Double(launchRuntimeSnapshot.railProgress.clamped(to: 0.0...1.0))
    }

    var fixedWingLaunchAirspeedMps: Float {
        launchRuntimeSnapshot.longitudinalAirspeedMps
    }

    var fixedWingLaunchFailureDetailKey: String? {
        guard launchState == .aborted else {
            return nil
        }
        switch fixedWingLastTransitionReason {
        case "launch_preflight_configuration_failed":
            return "launch.reason.configuration_failed"
        case "launch_preflight_corridor_invalid":
            return "launch.reason.corridor_invalid"
        case "launch_preflight_mass_exceeded":
            return "launch.reason.mass_exceeded"
        case "launch_preflight_tailwind_unsafe":
            return "launch.reason.tailwind_unsafe"
        case "launch_preflight_crosswind_unsafe":
            return "launch.reason.crosswind_unsafe"
        case "launch_preflight_vertical_clearance_invalid":
            return "launch.reason.vertical_clearance_invalid"
        case "launch_preflight_corridor_obstructed":
            return "launch.reason.corridor_obstructed"
        case "launch_preflight_runtime_failure":
            return "launch.reason.runtime_failure"
        case "catapult_acceleration_timeout", "launch_global_timeout":
            return "launch.reason.acceleration_timeout"
        case .some(_):
            return "launch.reason.generic"
        case .none:
            return nil
        }
    }

    func applyOnlineDamageState(_ damageState: OnlineVehicleDamageState) {
        guard onlineRuntimeContext != nil else { return }
        onlineDamageState = damageState
        sceneController.applyOnlineVehicleDamageState(damageState)
        // If local UAV has become disabled/crashed, disarm immediately.
        if let vehicleID = onlineRuntimeContext?.localVehicleID,
           damageState.isControlDisabled(vehicleID: vehicleID),
           isArmed {
            disarm(forceEmergency: true, preserveCrashDynamics: false)
        }
    }

    // v1.3+: mirror LANSessionViewModel diagnostics for display in overlay.
    // Replica counts are patched in from the interpolation result — rest comes from session layer.
    // All times here use CACurrentMediaTime() (receiver-local clock, same as receivedAtLocalTime).
    func applyOnlineDiagnostics(_ diagnostics: OnlineRuntimeNetworkDiagnostics) {
        var merged = diagnostics
        let now = CACurrentMediaTime()
        let staleThreshold = 2.0
        merged.remoteReplicaVisibleCount = onlineInterpolatedRemoteStates.filter { $0.sourceSnapshotAge < staleThreshold }.count
        merged.remoteReplicaStaleCount = onlineInterpolatedRemoteStates.filter { $0.sourceSnapshotAge >= staleThreshold }.count
        // sourceSnapshotAge = now(render) - receivedAtLocalTime; after clock fix both use CACurrentMediaTime.
        // Clamp to 0 as safety guard against any transient ordering.
        merged.remoteVisualLagMs = onlineInterpolatedRemoteStates
            .max(by: { $0.sourceSnapshotAge < $1.sourceSnapshotAge })
            .map { max(0, $0.sourceSnapshotAge) * 1000 }
        // How long ago the last snapshot was received (receiver-local clock).
        merged.lastSnapshotReceivedAgoMs = onlineInterpolationStore.latestReceivedAt
            .map { max(0, now - $0) * 1000 }
        merged.remoteSnapshotBufferDepthMax = onlineInterpolationStore.totalBufferDepth
        merged.remoteOutOfOrderDropCount = onlineInterpolationStore.outOfOrderDropCount
        merged.outgoingSnapshotHz = diagLastComputedHz.out
        merged.incomingSnapshotHz = diagLastComputedHz.rx
        merged.sceneApplyHz = diagLastComputedHz.sceneApply
        merged.renderFPS = diagLastComputedHz.renderFPS
        merged.visibilityStateLabel = performancePolicy.activityState.label
        merged.windowVisibilityLabel = currentVisibilityState.label
        merged.sceneIsPlaying = !performancePolicy.stopRendering
        merged.scenePreferredFPS = performancePolicy.targetRenderFPS
        onlineRuntimeDiagnostics = merged
    }

    func applyWindowVisibilityState(_ state: RuntimeVisibilityState) {
        if state == .activeVisible {
            noteUserInteraction()   // window becoming key / restored from minimize counts as interaction
        }
        currentVisibilityState = state
        refreshActivityPolicy(now: CACurrentMediaTime())
    }

    private func noteUserInteraction() {
        lastUserInteractionAt = CACurrentMediaTime()
        // Promote activeIdle → interacting immediately on any interaction, so arming/flying/camera
        // movement restores 60 FPS without requiring a windowDidBecomeKey event.
        if currentVisibilityState == .activeVisible,
           performancePolicy.activityState == .activeIdle {
            refreshActivityPolicy(now: lastUserInteractionAt)
        }
    }

    private func refreshActivityPolicy(now: TimeInterval) {
        let activity: RuntimeActivityState
        switch currentVisibilityState {
        case .minimized:       activity = .minimized
        case .hidden:          activity = .hidden
        case .inactiveVisible: activity = .backgroundIdle
        case .activeVisible:
            activity = (now - lastUserInteractionAt < 1.0) ? .interacting : .activeIdle
        }
        let policy = RuntimePerformancePolicy(activity)
        guard policy != performancePolicy else { return }
        performancePolicy = policy
        backgroundTickSkipCounter = 0
        if policy.stopRendering {
            sceneController.resetRemoteApplyTime()
            lastOnlineSceneApplyTime = 0
        }
        #if DEBUG
        print("[PERF] activity: \(activity.label) (vis=\(currentVisibilityState.label))")
        #endif
    }

    private func refreshDiagnosticHz(now: TimeInterval) {
        guard now - diagLastResetTime >= 1.0 else { return }
        let elapsed = max(now - diagLastResetTime, 0.001)
        diagLastComputedHz = (
            out: Double(diagSnapshotOutCount) / elapsed,
            rx: Double(diagSnapshotInCount) / elapsed,
            sceneApply: Double(diagSceneApplyCount) / elapsed,
            renderFPS: Double(diagRenderFrameCount) / elapsed
        )
        diagSnapshotOutCount = 0
        diagSnapshotInCount = 0
        diagSceneApplyCount = 0
        diagRenderFrameCount = 0
        diagLastResetTime = now
    }

    func canUseControlModule(_ module: ControlModule) -> Bool {
        guard let onlineRuntimeContext else { return true }

        switch module {
        case .flightOps, .uavCatalog, .diagnostics:
            return LANRuntimeRolePolicy.canControlVehicle(context: onlineRuntimeContext)
        case .scenario:
            return LANRuntimeRolePolicy.canUseScenarioAdmin(context: onlineRuntimeContext)
        case .camera:
            return true
        }
    }

    var shouldPromptBeforeExit: Bool {
        // Online trials and mission scenarios are transient runs, not saveable projects — exiting
        // them should return to the menu directly, without the "save your project?" prompt (which
        // otherwise made the mission Exit button appear to do nothing useful).
        !simulationRunMode.isOnlineTrial && !hasMissionScenario
    }

    var availableCameraModes: [CameraMode] {
        if isSpectatorMode {
            return [.spectator]
        }

        var modes: [CameraMode] = [.free, .follow, .orbit, .fpv, .top]
        if payloadCameraOpticsState.isAvailable || rangefinderOpticsState.isAvailable || hoseOpticsState.isAvailable || capsuleState.isAvailable || cameraConfiguration.mode == .payloadOptics {
            modes.append(.payloadOptics)
        }
        if payloadCameraController.canActivatePayloadView() || cameraConfiguration.mode == .payload {
            modes.append(.payload)
        }
        return modes
    }

    var missionStatusLabels: [String] {
        var labels: [String] = []
        if isMissionMapVisible {
            labels.append("mission.status.map_active")
        }
        if missionPlanState.dropZone != nil {
            labels.append("mission.status.drop_zone_set")
        }
        if missionPlanState.isDeliveryMissionReady, payloadState == .attached {
            labels.append("mission.status.delivery_ready")
        }
        if isInMissionDropZone {
            labels.append("mission.status.in_drop_zone")
        }
        if payloadState == .released || payloadState == .falling || payloadState == .landed || payloadState == .cleanedUp {
            labels.append("mission.status.payload_released")
        }
        if let impactStatusKey = lastPayloadImpact?.outcome.missionStatusKey {
            labels.append(impactStatusKey)
        }
        return labels
    }

    var signalInterferencePresentation: SignalInterferencePresentation {
        let intensity: Double
        switch signalState {
        case .normal:
            intensity = 0.0
        case .outOfBoundsWarning:
            intensity = 0.18
        case .signalDegrading:
            intensity = 0.34
        case .boundaryCountdown:
            let elapsed = Double(SignalLossConfiguration.countdownDuration - max(0, signalCountdownSecondsRemaining))
            let progress = elapsed / Double(SignalLossConfiguration.countdownDuration)
            intensity = min(0.62, 0.40 + progress * 0.20)
        case .signalLost, .recoveryPending:
            intensity = 1.0
        }

        let countdownText: String?
        if signalState.isCountdownActive {
            let format = NSLocalizedString("signal_loss.warning", comment: "")
            countdownText = String.localizedStringWithFormat(format, signalCountdownSecondsRemaining)
        } else {
            countdownText = nil
        }

        let warningTitle: String?
        let warningDetail: String?
        switch signalState {
        case .outOfBoundsWarning:
            warningTitle = String(localized: "signal_loss.warning_stage_title")
            warningDetail = String(localized: "signal_loss.warning_stage_detail")
        case .signalDegrading:
            warningTitle = String(localized: "signal_loss.critical_stage_title")
            warningDetail = String(localized: "signal_loss.critical_stage_detail")
        case .boundaryCountdown:
            warningTitle = String(localized: "signal_loss.boundary_stage_title")
            warningDetail = String(localized: "signal_loss.boundary_stage_detail")
        case .normal, .signalLost, .recoveryPending:
            warningTitle = nil
            warningDetail = nil
        }

        let lostTitle: String?
        let lostMessage: String?
        if signalState.isInteractionBlocking {
            switch signalLossCause {
            case .impactDamage:
                lostTitle = String(localized: "signal_loss.impact_title")
                lostMessage = String(localized: "signal_loss.impact_message")
            case .linkRange, .none:
                lostTitle = String(localized: "signal_loss.lost_title")
                lostMessage = String(localized: "signal_loss.lost_message")
            }
        } else {
            lostTitle = nil
            lostMessage = nil
        }
        let recoveryButtonTitle = signalState == .signalLost
            ? String(localized: "signal_loss.recover")
            : nil

        return SignalInterferencePresentation(
            state: signalState,
            countdownText: countdownText,
            intensity: intensity,
            warningTitle: warningTitle,
            warningDetail: warningDetail,
            lostTitle: lostTitle,
            lostMessage: lostMessage,
            recoveryButtonTitle: recoveryButtonTitle
        )
    }

    private let physicsEngine: DronePhysicsEngine
    private let sceneController: DroneSceneController
    private let keyboardInputService: KeyboardInputProviding
    private let gameControllerInputProvider: GameControllerInputProvider
    private let remoteInputProvider: RemoteInputProvider
    private let inputManager: InputManager
    private let collisionService: CollisionAnalysisService
    private let impactResolutionService = ImpactResolutionService()
    private let structuralLoadSolver = UAVStructuralLoadSolver()
    private let damageEventRecorder = UAVDamageEventRecorder()
    /// Component graph + physical contact profile of the selected aircraft,
    /// rebuilt from the freshly built visual whenever the model (or the
    /// installed mass) changes. `damageState` stays the legacy UI projection
    /// of this graph.
    private(set) var componentGraph: VehicleComponentGraph = .empty
    private(set) var vehicleContactProfile: VehicleContactProfile = .empty
    private var pristineVehicleContactProfile: VehicleContactProfile = .empty
    private var vehicleMassProperties: VehicleMassProperties = .fallback
    /// Pristine rotor layout from the builder; `vehicleRotorModel` is the
    /// same layout with damage/failure thrust factors baked in.
    private var pristineRotorModel: VehicleRotorModel = .empty
    private(set) var vehicleRotorModel: VehicleRotorModel = .empty
    private var vehicleAeroDamage: FixedWingAeroDamage = .pristine
    private let componentFailureRuntime = ComponentFailureRuntime()
    /// Battery thermal-runaway/rupture consequence (impact puncture or sustained
    /// overheat/over-discharge under load) — visual + instant power loss only, see
    /// `igniteBatteryFireIfNeeded`/`updateBatteryFireState`.
    @Published private(set) var batteryFireActive: Bool = false
    private var batteryFireIgnitedAtSimulationTime: TimeInterval?
    private static let batteryFireFlameDurationSec: Float = 6.0
    private static let batteryFireSmokeTailDurationSec: Float = 10.0
    /// Seconds of *continuous* near-100% throttle — resets the instant the operator eases off,
    /// by design (see `updateBatteryFireState`): this is specifically about refusing to let go of
    /// the stick/E, not cumulative time spent near max throttle across a flight.
    private var sustainedMaxThrottleSeconds: Float = 0.0
    private static let batteryOverheatThrottleThreshold: Float = 0.97
    private static let batteryOverheatDurationSec: Float = 12.0
    /// Generic hobby-LiPo continuous discharge rating used to derive a "safe" continuous current
    /// from pack capacity alone (no per-aircraft C-rating field exists) — real packs commonly run
    /// 15-25C continuous; 15C is the conservative end.
    private static let batteryContinuousDischargeCRating: Float = 15.0
    private let batteryThermalService: BatteryThermalSimulationService
    private let telemetryExporter: TelemetryExporting
    private let projectStorage: ProjectStorageManaging
    private let fleetManager: DroneFleetManager
    private let autoPathPlanner: AutoPathPlannerService
    private let flightControlRouter: FlightControlRouter
    private let autoNavigationController: AutoNavigationController
    private let multicopterAutopilotController = MulticopterAutopilotController()
    private let fixedWingAutopilotController = FixedWingAutopilotController()
    private let fixedWingLaunchController = FixedWingLaunchController()
    private let fixedWingAssistController = FixedWingAssistController()
    private let payloadCameraController: PayloadCameraController
    private let rangefinderController: PayloadRangefinderController
    private let hoseController: PayloadFireHoseController
    private let capsuleController: PayloadFireCapsuleController
    private let agriculturalSprayerController: PayloadAgriculturalSprayerController
    private let tacticalMapCoordinator = TacticalMapCoordinator()
    private let missionDraftBuilder = MissionDraftBuilder()
    private let missionPreviewBuilder = MissionPreviewBuilder()
    private let missionPlanBuilder = MissionPlanBuilder()
    private let missionExecutionBinder = MissionExecutionBinder()
    private let missionExecutionCoordinator = MissionExecutionCoordinator()
    // Mission scenario (SAR) state.
    private let missionScenarioConfiguration: MissionScenarioConfiguration?
    private var missionScenarioRuntime: MissionScenarioRuntime?
    private var missionScenarioTargetWorldPosition: SIMD3<Float>?
    private var didBootstrapMissionScenario = false
    private var didReportMissionScenarioOutcome = false
    private var fireResponseRuntime: FireResponseRuntime?
    private var didReportFireResponseOutcome = false
    private let missionAutopilotAdapter = MissionAutopilotAdapter()
    private let missionGuidanceTargetResolver = MissionGuidanceTargetResolver()
    private let fixedWingFlyableRouteBuilder = FixedWingFlyableRouteBuilder()
    private let missionProgressTracker = MissionProgressTracker()
    private let missionAuthorityGuard = MissionAuthorityGuard()
    private let missionRuntimeMonitor = MissionRuntimeMonitor()
    private let missionSafetyEvaluator = MissionSafetyEvaluator()
    private let missionFailsafeCoordinator = MissionFailsafeCoordinator()
    private let fixedWingMissionStateArbiter = FixedWingMissionStateArbiter()
    private let missionStatusResolver = MissionStatusResolver()
    private let missionEventRecorder = MissionEventRecorder()
    private let missionDebriefService = MissionDebriefService()
    private let missionEventMapper = MissionEventMapper()
    private let missionPersistenceAdapter = MissionPersistenceAdapter()
    private let payloadProximityEffectModel = PayloadProximityEffectModel()
    private let missionReplayRecorder = MissionReplayRecorder()
    private let missionReportBuilder = MissionReportBuilder()
    let replayLibraryViewModel = ReplayLibraryViewModel()

    private var vtolAutopilotPhase: VTOLAutopilotPhase = .idleGrounded
    private var state: DroneState
    private var lastFiniteState: DroneState
    private var simulationTimer: Timer?
    private var lastTimestamp: CFTimeInterval?
    private var simulationTime: Float = 0.0
    private var telemetrySamplingAccumulator: Float = 0.0
    private var hudPublishAccumulator: Float = 0.0
    private var diagnosticsSamplingAccumulator: Float = 0.0
    private var previousReplayArmedState: Bool = false
    private var previousReplayAutopilotActive: Bool = false
    private var previousReplayWarningMessages: Set<String> = []
    private var groundContactAccumulator: Float = 0.0
    private var stableGroundAccumulator: Float = 0.0
    private var airborneAccumulator: Float = 0.0
    private var impactSeverityAccumulator: Float = 0.0
    private var collisionAftermathState: CollisionAftermathState = .nominal
    private var signalLossCause: SignalLossCause?
    private var collisionCooldown: Float = 0.0
    private var groundImpactCooldown: Float = 0.0
    private var recentDamageEvents: [UAVDamageEvent] = []
    private var recordedPhysicalImpactCount: UInt64 = 0
    private var replayStopPendingAfterDisarm = false
    private var launchState: LaunchState = .idle
    private var launchStateElapsed: Float = 0.0
    private var launchRuntimeSnapshot: FixedWingLaunchRuntimeSnapshot = .idle
    private var activeFixedWingLaunchDynamics: FixedWingLaunchDynamics?
    /// While true the idle aircraft is physically seated in its launch cradle
    /// (catapult shuttle / operator's hand) instead of resting on the ground.
    /// Engaged at spawn/reset and after a pre-release abort; released the
    /// moment the launch state machine takes ownership of the airframe.
    private var launchCradleHoldActive = false
    /// Seconds since the hand-launch release: the first-person view lingers
    /// briefly so the operator watches the airframe leave his hand before the
    /// camera returns to the regular UAV view.
    private var fixedWingLaunchReleaseElapsed: Float = 0.0
    /// Player's live roll-stick command for a fixed wing, refreshed every
    /// tick in `applyResolvedFlightControls` regardless of flight mode. The
    /// assisted hand-launch/catapult corridor (`updateFixedWingLaunchSequence`)
    /// reads this so the operator can bank left/right immediately after
    /// release instead of being locked out until the corridor hands off to
    /// `.manual` several seconds later.
    private var fixedWingManualRollCommandDegrees: Float = 0.0
    private var fixedWingManualTurnInputActive = false
    /// Launch corridor frozen at the moment the launch began. The live asset
    /// heading keeps following the operator's aim (and reverts to the drafted
    /// heading once the POV closes), so the climb-out guidance must NOT
    /// re-read it mid-launch — that made the aircraft turn back toward the
    /// drafted corridor right after release.
    private var activeLaunchCorridor: (
        origin: SIMD3<Float>,
        horizontal: SIMD2<Float>,
        releaseAttitudeDegrees: Float
    )?
    private var homePosition = SIMD3<Float>(0.0, 0.0, 0.0)
    private var releasedPayloadConfiguration: PayloadConfiguration?
    private var payloadSelfInteractionTimer: Float = 0.0
    private var payloadSelfInteractionSeverity: Float = 0.0
    private var payloadControlPenalty: Float = 0.0
    #if DEBUG
    private var lastLoggedAgriSprayerDebugState: String?
    #endif
    /// Cumulative flight-path distance (not straight-line range) consumed from the fiber-optic
    /// reel this flight — reset whenever the tether goes from inactive to active (fresh reel).
    private var fiberOpticPathLengthUsedMeters: Float = 0.0
    private var fiberOpticSnagRisk: Float = 0.0
    /// Laid-line geometry for the current sortie: anchor at the launch point, then turn/contact
    /// checkpoints (see `FiberPolylineCheckpoint`) — appended only, never removed mid-sortie,
    /// because deployed fiber stays where it fell. Consumption and snag risk both derive from
    /// this, and it's what the scene renders as the visible fiber.
    private var fiberPolylineCheckpoints: [FiberPolylineCheckpoint] = []
    /// Sum of the fixed (checkpoint-to-checkpoint) segment lengths — the live leg from the last
    /// checkpoint to the aircraft is measured fresh each tick on top of this.
    private var fiberPolylineFixedLengthMeters: Float = 0.0
    /// Farthest point (and its distance) the aircraft has reached on the current live leg —
    /// where a turn checkpoint gets fixed if the aircraft then backtracks or deviates laterally.
    private var fiberLegFarthestPoint: SIMD3<Float>?
    private var fiberLegFarthestDistance: Float = 0.0
    private var controlLinkFailsafeStageElapsed: Float = 0.0
    /// How long the radio link has been continuously back in the nominal zone while
    /// `controlLinkFailsafeLatched` is set — only used to confirm a *stable* reconnection before
    /// clearing the latch (see `updateControlLinkFailsafeLatchRecovery`); resets to 0 the instant
    /// the link degrades again. Fiber never uses this — it has no automatic recovery path.
    private var stableRadioReconnectionSeconds: Float = 0.0
    /// Planar point the fixed-wing/hybridVTOL control-link failsafe orbits during
    /// `.loiterGlide`/`.emergencyLanding` — captured once, right when the failsafe begins, so the
    /// aircraft loiters near where the link was actually lost instead of drifting in whatever
    /// direction it happened to be flying (which could easily carry it past the rendered world).
    private var controlLinkFailsafeLoiterCenter: SIMD2<Float>?
    private var fixedWingAutopilotAltitudeCommand: Float?
    private var fixedWingAutopilotCourseCommand: Float?
    private var fixedWingAssistTurnOverrideTimeRemaining: Float = 0.0
    private var fixedWingAssistAltitudeOverrideTimeRemaining: Float = 0.0
    private var fixedWingAssistUsesTargetYawWhileManual: Bool = false
    private var wingmen: [DroneEntity] = []
    private let fleetLeaderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var collisionDebugAccumulator: Float = 0.0
    private var lastCollisionDebugEnabled: Bool = false
    private var autosaveAccumulator: Float = 0.0
    private var onlineSnapshotSequenceNumber: UInt64 = 0
    private var lastOnlineSnapshotSentAt: TimeInterval = 0
    private var lastOnlineSnapshotCleanupAt: TimeInterval = 0
    private var onlineSnapshotSendInterval: TimeInterval { performancePolicy.snapshotSendInterval }
    private weak var onlineSnapshotTransport: OnlineTrialSnapshotTransport?
    // P2P v1.2: owner-side collision detection + shared event submission.
    private weak var onlineSharedEventTransport: OnlineSharedEventTransport?
    private let localCollisionDetector = OnlineLocalCollisionDetector()
    private var recentLocalCollisionPairKeys: [String: TimeInterval] = [:]
    private let localCollisionEventCooldownSeconds: TimeInterval = 2.0
    // v1.4: grace period prevents spawn-overlap collision events at trial start.
    private var onlineTrialStartedAt: TimeInterval? = nil
    private let onlineCollisionGracePeriodSeconds: TimeInterval = 3.0
    private var manualYawIntent: Float = 0.0
    private var cameraLookVelocity = SIMD2<Float>(repeating: 0.0)
    private var payloadGimbalLookVelocity = SIMD2<Float>(repeating: 0.0)
    private var resolvedInputState: ResolvedControlState = .neutral
    private var autoFlightGoal: SIMD3<Float>?
    private var autoFlightGoalIndex: Int = 0
    private var returnHomeStage: ReturnHomeStage = .idle
    private var navigationSnapshot: NavigationPathSnapshot = .idle
    private var flightControlDiagnostics: FlightControlDiagnostics = .zero
    private var cachedDiagnostics: SimulationDiagnostics = .zero
    private var pendingTerrainRegenerationTask: Task<Void, Never>?
    private var pendingTerrainRegenerationRequiresReset = false
    private var signalLossSecondAccumulator: Float = 0.0
    private var fleetInterDroneRisk: Float = 0.0
    private var fleetNearestInterDroneDistance: Float = .infinity
    private var isTerrainDensitySliderEditing: Bool = false
    private var terrainMapTrail: [SIMD2<Float>] = []
    /// `obstacle.source` -> classified base radius, so the string-matching
    /// switch in `fixedWingProtectedObstacleRadius` runs once per distinct
    /// source string instead of on every call. `fixedWingPathNeedsObstacleReroute`
    /// calls it once per obstacle per route-rebuild, and that rebuild happens
    /// every simulation tick — with a couple hundred environment obstacles
    /// (e.g. procedurally placed trees), the repeated `.contains` chains were
    /// measured pegging the main thread (confirmed via Xcode's paused-thread
    /// backtrace landing in Foundation's string search machinery).
    private var fixedWingObstacleBaseRadiusCache: [String: Float] = [:]
    private var installedPayloadConfiguration: PayloadConfiguration?
    private var installedFiberSpoolModule: FiberSpoolModule?
    private var activePayloadReleaseID: UUID?
    private var lastSidebarModule: ControlModule = .flightOps
    private var committedTacticalMissionDraft: MissionDraft = .empty
    private var workingTacticalMissionDraft: MissionDraft = .empty
    private var missionSafetyState: MissionSafetyState = .idle
    private var fixedWingMissionArbiterDecision: FixedWingMissionArbiterDecision = .nominal
    private var activeRouteTargetSource: ActiveRouteTargetSource = .none
    private var activeRouteTargetAltitude: Float?
    private var activeRouteTargetAltitudeMarkerID: UUID?
    private var multirotorMarkerLastPlanTick: UInt64?
    private var multirotorAvoidanceLateralOffset: Float = 0.0
    private var multirotorAvoidanceHoldUntilTick: UInt64 = 0
    private var missionObservation = MissionObservationAccumulator()
    private var externalControllerOverlayActive: Bool = false
    private var activeFixedWingGuidanceSource: FixedWingGuidanceSource = .none
    private var fixedWingFlyByPlanCacheKey: FixedWingFlyByPlanKey?
    private var fixedWingFlyByPlanCache: FixedWingFlyByTransitionPlan?
    private var fixedWingGuidanceRecomputeCount: Int = 0
    private var fixedWingFlyByRoutePlanCacheKey: FixedWingFlyByRoutePlanKey?
    private var fixedWingFlyByRoutePlanCache: FixedWingFlyByRoutePlan?
    private var fixedWingFullRouteRebuildCount: Int = 0
    private var fixedWingRuntimeRouteStartKey: String?
    private var fixedWingRuntimeRouteStartPosition: SIMD3<Float>?
    private var fixedWingRouteTrackingContextCacheTick: UInt64?
    private var fixedWingRouteTrackingContextCacheFallback: SIMD3<Float>?
    private var fixedWingRouteTrackingContextCacheValue: FixedWingRouteTrackingContext?
    private var fixedWingFlyablePathCacheKey: String?
    private var fixedWingFlyablePathCacheRoute: FixedWingFlyableRoute?
    private var fixedWingSafeRouteCacheKey: FixedWingSafeRouteCacheKey?
    private var fixedWingSafeRouteCacheRoute: FixedWingSafeRoute?
    private var fixedWingSafeRouteCacheStoresNil: Bool = false
    private var simulationTickCounter: UInt64 = 0
    private var fixedWingGuidanceDeferredThroughTick: UInt64?
    private var lastTargetMarkerRejectionReason: MissionGuidanceRejectionReason?
    private var terrainMapStaticOverlayCacheKey: TerrainMapStaticOverlayKey?
    private var terrainMapStaticOverlayCache: TerrainMapStaticOverlay?
    private var terrainMapObjectsCacheRevision: UInt64?
    private var terrainMapObjectsCacheExtentBucket: Int?
    private var terrainMapObjectsCache: [TerrainMapObject] = []
    private var terrainMapHeavyRebuildCount: Int = 0
    private var fixedWingObstacleSignatureRevision: UInt64?
    private var fixedWingObstacleSignatureCache: Int = 0
    private var environmentObjectSignatureRevision: UInt64?
    private var environmentObjectSignatureCache: Int = 0

    private enum ActiveRouteTargetSource {
        case none
        case manualMarker
        case mission
    }

    private enum FixedWingGuidanceSource: String {
        case none
        case launch
        case mission
        case marker
        case returnHome
    }

    private struct FixedWingTurnCorridorAssessment {
        let obstacleInTurnCorridor: Bool
        let blockedPath: Bool
        let collisionRisk: Float
        let suppressedReason: String?
    }

    private struct FixedWingAssistLegProjection {
        let alongTrackDistance: Float
        let alongTrackProgress: Float
        let crossTrackError: Float
        let distanceToEnd: Float
        let legLength: Float
    }

    private struct FixedWingAssistFlyByGuidanceSnapshot {
        let guidanceTarget: SIMD2<Float>
        let captureTarget: SIMD2<Float>
        let guidanceMode: String
        let currentLegStart: SIMD2<Float>?
        let currentLegMiddle: SIMD2<Float>?
        let currentLegEnd: SIMD2<Float>?
        let inboundCourseDegrees: Float?
        let outboundCourseDegrees: Float?
        let courseChangeDegrees: Float?
        let estimatedTurnRadius: Float?
        let leadDistanceMeters: Float?
        let flyByTransitionActive: Bool
        let flyByTransitionFeasible: Bool
        let headingErrorToNextWaypointDegrees: Float?
        let nextWaypointInForwardSector: Bool
        let enoughTurnInDistance: Bool
        let collisionRiskToNextWaypoint: Float?
        let obstacleInTurnCorridor: Bool
        let blockedPathToNextWaypoint: Bool
        let lateralGuidanceSuppressedForPoorGeometry: Bool
        let shouldPauseForPoorGeometry: Bool
        let shouldPauseForObstacle: Bool
        let shouldHandoffToNext: Bool
        let suppressedReason: String?
    }

    private struct FixedWingFlyByPlanKey: Equatable {
        let waypointOptions: [FixedWingAssistWaypointOption]
        let selectedWaypointID: UUID?
        let activeIndex: Int?
        let autoAdvanceEnabled: Bool
        let turnRadiusBucket: Int
        let obstacleSignature: Int
        let noFlyZoneSignature: Int
        let weatherSignature: Int
        let terrainSignature: Int
    }

    private struct FixedWingFlyByTransitionPlan {
        let selectedWaypoint: FixedWingAssistWaypointOption
        let nextWaypointIndex: Int?
        let currentLegStart: SIMD2<Float>?
        let currentLegMiddle: SIMD2<Float>?
        let currentLegEnd: SIMD2<Float>?
        let inboundDirection: SIMD2<Float>?
        let outboundDirection: SIMD2<Float>?
        let inboundLength: Float
        let outboundLength: Float
        let estimatedTurnRadius: Float
        let lookaheadDistance: Float
        let inboundCourseDegrees: Float?
        let outboundCourseDegrees: Float?
        let courseChangeDegrees: Float?
        let leadDistanceMeters: Float?
        let isDirectIntercept: Bool
        let isStraightTransition: Bool
        let flyByTransitionFeasible: Bool
        let obstacleInTurnCorridor: Bool
        let blockedPathToNextWaypoint: Bool
        let collisionRiskToNextWaypoint: Float?
        let shouldPauseForPoorGeometry: Bool
        let shouldPauseForObstacle: Bool
        let lateralGuidanceSuppressedForPoorGeometry: Bool
        let suppressedReason: String?
    }

    private struct FixedWingFlyByRoutePlanKey: Equatable {
        let missionPlanID: UUID?
        let missionPlanSignature: Int
        let previewRouteID: UUID?
        let workingDraft: MissionDraft
        let obstacleSignature: Int
        let airframeClass: AirframeClass
    }

    private struct FixedWingFlyByRoutePlan {
        let routePoints: [SIMD2<Float>]
        let routeWaypoints: [FixedWingRouteWaypoint]
        let waypointRoutePointIndices: [Int]
        let previewUsesCachedFlyByPlan: Bool
        let controllerUsesCachedFlyByPlan: Bool
        let guidanceDirectToWaypointSuppressed: Bool
    }

    private struct FixedWingSafeRoute {
        let points: [SIMD2<Float>]
        let wasRerouted: Bool
    }

    private struct FixedWingSafeRouteCacheKey: Equatable {
        let routeSignature: Int
        let noFlyZoneSignature: Int
        let obstacleSignature: Int
        let terrainSignature: Int
        let viewportSignature: Int
        let targetAltitudeBucket: Int
        let profileID: String
    }

    private struct FixedWingWaypointClassification {
        let activeWaypointIndex: Int?
        let nextWaypointIndex: Int?
        let hasPrevWaypoint: Bool
        let hasNextWaypoint: Bool
        let isFinalWaypoint: Bool
        let isPenultimateWaypoint: Bool
        let flyByCenterWaypointIndex: Int?
        let terminalCaptureAllowed: Bool

        static let none = FixedWingWaypointClassification(
            activeWaypointIndex: nil,
            nextWaypointIndex: nil,
            hasPrevWaypoint: false,
            hasNextWaypoint: false,
            isFinalWaypoint: false,
            isPenultimateWaypoint: false,
            flyByCenterWaypointIndex: nil,
            terminalCaptureAllowed: false
        )
    }

    private struct TerrainMapStaticOverlayKey: Equatable {
        let missionPlanID: UUID?
        let previewRouteID: UUID?
        let draftWaypoints: [MissionWaypoint]
        let draftZones: [MissionZone]
        let activeAssistWaypointID: UUID?
        let activeMissionWaypointID: UUID?
        let completedWaypointIDs: [UUID]
        let objectSignature: Int
        let extentBucket: Int
    }

    private struct TerrainMapStaticOverlay {
        let routePoints: [SIMD2<Float>]
        let waypoints: [TerrainMapMissionWaypoint]
        let noFlyZones: [MissionZone]
        let objects: [TerrainMapObject]
    }

    private enum ObstacleImpactClass {
        case foliage
        case softSurface
        case hardSurface
    }

    private struct MissionObservationAccumulator {
        var startBatteryPercent: Float?
        var totalDistanceMeters: Float
        var maxAltitudeMeters: Float
        var altitudeSumMeters: Float
        var altitudeSamples: Int
        var lastPosition: SIMD3<Float>?

        init() {
            self.startBatteryPercent = nil
            self.totalDistanceMeters = 0.0
            self.maxAltitudeMeters = 0.0
            self.altitudeSumMeters = 0.0
            self.altitudeSamples = 0
            self.lastPosition = nil
        }

        mutating func begin(position: SIMD3<Float>, batteryPercent: Float) {
            startBatteryPercent = batteryPercent
            totalDistanceMeters = 0.0
            maxAltitudeMeters = max(0.0, position.y)
            altitudeSumMeters = max(0.0, position.y)
            altitudeSamples = 1
            lastPosition = position
        }

        mutating func resume(position: SIMD3<Float>) {
            lastPosition = position
        }

        mutating func sample(position: SIMD3<Float>) {
            if let lastPosition {
                totalDistanceMeters += simd_distance(position, lastPosition)
            }
            self.lastPosition = position
            maxAltitudeMeters = max(maxAltitudeMeters, max(0.0, position.y))
            altitudeSumMeters += max(0.0, position.y)
            altitudeSamples += 1
        }

        mutating func reset() {
            self = MissionObservationAccumulator()
        }

        var averageAltitudeMeters: Float {
            guard altitudeSamples > 0 else {
                return 0.0
            }
            return altitudeSumMeters / Float(altitudeSamples)
        }
    }

    init(
        physicsEngine: DronePhysicsEngine = SimpleDronePhysicsEngine(),
        keyboardInputService: KeyboardInputProviding = KeyboardInputService(),
        controllerSettingsStore: ControllerSettingsStore = ControllerSettingsStore(),
        collisionService: CollisionAnalysisService = CollisionAnalysisService(),
        batteryThermalService: BatteryThermalSimulationService = BatteryThermalSimulationService(),
        telemetryExporter: TelemetryExporting = TelemetryExportService(),
        projectStorage: ProjectStorageManaging = ProjectStorageService(),
        fleetManager: DroneFleetManager = DroneFleetManager(),
        autoPathPlanner: AutoPathPlannerService = AutoPathPlannerService(),
        flightControlRouter: FlightControlRouter = FlightControlRouter(),
        autoNavigationController: AutoNavigationController = AutoNavigationController(),
        payloadCameraController: PayloadCameraController = PayloadCameraController(),
        rangefinderController: PayloadRangefinderController = PayloadRangefinderController(),
        hoseController: PayloadFireHoseController = PayloadFireHoseController(),
        capsuleController: PayloadFireCapsuleController = PayloadFireCapsuleController(),
        agriculturalSprayerController: PayloadAgriculturalSprayerController = PayloadAgriculturalSprayerController(),
        remoteHostPort: UInt16 = 7777,
        initialProjectID: String? = nil,
        initialProjectName: String? = nil,
        launchConfiguration: SimulationLaunchConfiguration? = nil,
        initialDroneProfile: DroneModelProfile? = nil,
        initialAbstractParameters: AbstractDroneParameters? = nil,
        simulationRunMode: SimulationRunMode = .singlePlayer,
        onlineSessionConfig: OnlineTrialSessionConfig? = nil,
        localOnlineParticipant: LocalOnlineParticipant? = nil,
        onlineRuntimeContext: OnlineTrialRuntimeContext? = nil,
        onlineSnapshotTransport: OnlineTrialSnapshotTransport? = nil,
        onlineSharedEventTransport: OnlineSharedEventTransport? = nil,
        missionScenarioContext: MissionScenarioConfiguration? = nil
    ) {
        self.missionScenarioConfiguration = missionScenarioContext
        self.physicsEngine = physicsEngine
        self.keyboardInputService = keyboardInputService
        self.controllerSettingsStore = controllerSettingsStore
        self.simulationRunMode = simulationRunMode
        self.onlineSessionConfig = onlineSessionConfig
        self.localOnlineParticipant = localOnlineParticipant
        self.onlineRuntimeContext = onlineRuntimeContext
        self.onlineFleetState = nil
        self.onlineSnapshotTransport = onlineSnapshotTransport
        self.onlineSharedEventTransport = onlineSharedEventTransport
        let gameControllerInputProvider = GameControllerInputProvider(
            settingsStore: controllerSettingsStore
        )
        self.controllerUIBridge = ControllerUIBridge(settingsStore: controllerSettingsStore)
        self.gameControllerInputProvider = gameControllerInputProvider
        let remoteTransport: RemoteTransport? = simulationRunMode.isOnlineTrial ? nil : NetworkRemoteHost(port: remoteHostPort)
        let remoteInputProvider = RemoteInputProvider(transport: remoteTransport)
        self.remoteInputProvider = remoteInputProvider
        self.inputManager = InputManager(
            providers: [
                KeyboardInputProvider(keyboardInputService: keyboardInputService),
                gameControllerInputProvider,
                remoteInputProvider,
                AutopilotInputProvider()
            ]
        )
        let bindingsStore = InputBindingsStore(keyboardInputService: keyboardInputService)
        let captureCoordinator = InputCaptureCoordinator(
            keyboardInputService: keyboardInputService,
            inputManager: self.inputManager
        )
        self.bindingsViewModel = BindingsViewModel(
            store: bindingsStore,
            captureCoordinator: captureCoordinator
        )
        self.collisionService = collisionService
        self.batteryThermalService = batteryThermalService
        self.telemetryExporter = telemetryExporter
        self.projectStorage = projectStorage
        self.fleetManager = fleetManager
        self.autoPathPlanner = autoPathPlanner
        self.flightControlRouter = flightControlRouter
        self.autoNavigationController = autoNavigationController
        self.payloadCameraController = payloadCameraController
        self.rangefinderController = rangefinderController
        self.hoseController = hoseController
        self.capsuleController = capsuleController
        self.agriculturalSprayerController = agriculturalSprayerController
        self.compassViewModel = CompassViewModel()

        let abstract = initialAbstractParameters ?? AbstractDroneParameters.default
        self.abstractParameters = abstract
        let repository = LIPODroneModelRepository(abstractParameters: abstract)
        var models = repository.allProfiles
        for build in WorkbenchBuildStore.listLibraryBuilds() {
            let profile = UAVBuildProfileSynthesizer.synthesizeProfile(for: build)
            if !models.contains(where: { $0.id == profile.id }) {
                models.append(profile)
            }
        }
        if let initialDroneProfile {
            if let index = models.firstIndex(where: { $0.id == initialDroneProfile.id }) {
                models[index] = initialDroneProfile
            } else {
                models.append(initialDroneProfile)
            }
        }
        let requestedProfileID = launchConfiguration?.selectedUAVProfile ?? missionScenarioContext?.selectedUAVProfileID
        let selectedProfile = initialDroneProfile ?? requestedProfileID.flatMap { requestedID in
            let canonicalID = LIPODroneModelRepository.canonicalModelID(requestedID)
            return models.first { $0.id == canonicalID }
        } ?? repository.defaultProfile
        let initialActiveUAVProfile = Self.resolveActiveUAVProfile(for: selectedProfile, abstractParameters: abstract)
        self.selectedDroneProfile = selectedProfile
        self.activeUAVProfile = initialActiveUAVProfile
        self.availableDroneProfiles = models
        self.uavCatalogFilterState = UAVFilterState()
        self.simulationLaunchConfiguration = launchConfiguration
        self.mountedCADPayload = launchConfiguration?.mountedCADPayload

        self.sceneController = DroneSceneController(initialProfile: selectedProfile)

        var initialState = DroneState.initial
        initialState.propulsionUnits = selectedProfile.propulsionUnitTemplate
        self.state = initialState
        self.lastFiniteState = initialState
        self.controlValues = DroneControlValues(
            x: Double(initialState.position.x),
            y: Double(initialState.position.y),
            z: Double(initialState.position.z),
            roll: 0.0,
            pitch: 0.0,
            yaw: 0.0,
            throttle: Double(initialState.throttle)
        )

        self.mode = .manual
        self.flightControlMode = .stabilized
        self.isSimulationRunning = true
        let createdID = initialProjectID ?? projectStorage.createProjectID()
        self.currentProjectID = createdID
        self.currentProjectName = initialProjectName ?? projectStorage.defaultProjectName()
        self.hasUnsavedChanges = !simulationRunMode.isOnlineTrial

        self.weather = .normal
        self.terrain = .default
        // Start from `.default` (single source of truth for the size-aware zoom-to-FPV floors —
        // see `fpvAutoEngageDistance`/`DroneSceneController.updateCameras`) and only override the
        // fields that are genuinely per-profile at launch. This used to hand-construct the whole
        // struct with its own hardcoded minDistance/maxDistance (stale pre-zoom-to-FPV values,
        // e.g. `follow.minDistance: 2.0`), silently shadowing every `.default` floor change made
        // this session — the actual reason zoom never approached past ~2m regardless of how many
        // times the render-side floors were lowered.
        var initialCameraConfiguration = CameraConfiguration.default
        initialCameraConfiguration.mode = simulationRunMode.isSpectator ? .spectator : .follow
        initialCameraConfiguration.fov = selectedProfile.cameraPreset.fpvFov
        initialCameraConfiguration.lookNudgeStepDeg = 2.0
        initialCameraConfiguration.free.moveSpeed = 4.2
        initialCameraConfiguration.follow.distance = selectedProfile.cameraPreset.followDistance
        initialCameraConfiguration.follow.height = selectedProfile.cameraPreset.followHeight
        initialCameraConfiguration.orbit.distance = selectedProfile.cameraPreset.followDistance
        initialCameraConfiguration.orbit.height = selectedProfile.cameraPreset.followHeight
        self.cameraConfiguration = initialCameraConfiguration

        self.batteryState = .full
        self.collisionAnalysis = .safe
        self.damageState = .pristine
        self.thermalState = .nominal
        self.fleetStatus = .disabled
        self.fleetInterDroneRisk = 0.0
        self.fleetNearestInterDroneDistance = .infinity

        self.warnings = []
        self.diagnostics = .zero
        self.lastCollisionSource = "n/a"
        self.lastModeTransitionReason = "initialization"
        self.fixedWingLastTransitionReason = nil
        self.fixedWingAutopilotDebugState = .idle
        self.fixedWingBatteryWarningLevel = .nominal
        self.fixedWingAssistState = .manual
        self.collisionDebugEnabled = false
        self.showBatteryDepletedDialog = false
        self.diagnosticMode = .normal
        self.isToolPanelVisible = !simulationRunMode.isSpectator
        self.isParametersPanelVisible = false
        self.activeControlModule = nil
        self.isPayloadPanelVisible = false
        self.isBoundaryBarrierVisible = false
        self.isCompactTelemetryHUDEnabled = !simulationRunMode.isSpectator
        self.telemetryExportAlert = nil
        self.keyBindingSections = []
        self.keyBindingConflicts = []
        self.selectedCameraPreset = .pilot
        self.isArmed = false
        self.physicalState = initialState.physicalState
        let initialPayloadConfiguration: PayloadConfiguration
        let initialInstalledPayloadConfiguration: PayloadConfiguration?
        let initialPayloadState: PayloadState
        let initialPayloadStatusMessageKey: String?
        if let mountedPayload = launchConfiguration?.mountedCADPayload,
           launchConfiguration?.launchSource == .cadPayloadTest,
           launchConfiguration?.initialPayloadState == .mounted {
            initialPayloadConfiguration = PayloadConfiguration(
                payloadType: .custom,
                customName: mountedPayload.partName,
                payloadMass: Float(mountedPayload.massKg),
                visualPreset: .customModule,
                isAttached: true
            )
            initialInstalledPayloadConfiguration = initialPayloadConfiguration
            initialPayloadState = .attached
            initialPayloadStatusMessageKey = "cad.payload.runtime.mounted"
        } else {
            initialPayloadConfiguration = PayloadController.defaultConfiguration()
            initialInstalledPayloadConfiguration = nil
            initialPayloadState = .noPayload
            initialPayloadStatusMessageKey = nil
        }
        self.payloadDraftConfiguration = initialPayloadConfiguration
        self.payloadState = initialPayloadState
        self.installedPayloadConfiguration = initialInstalledPayloadConfiguration
        self.payloadMountState = initialActiveUAVProfile == nil ? .unavailable : .ready
        self.payloadCapabilityCheck = PayloadController.capabilityCheck(
            for: initialPayloadConfiguration,
            profile: initialActiveUAVProfile
        )
        self.vehicleMassModel = PayloadController.massModel(
            for: selectedProfile,
            uavProfile: initialActiveUAVProfile,
            installedPayload: initialInstalledPayloadConfiguration,
            payloadState: initialPayloadState
        )
        self.payloadStatusMessageKey = initialPayloadStatusMessageKey
        self.lastPayloadImpact = nil
        self.signalState = .normal
        self.signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
        self.isTerrainMapVisible = false
        self.isMissionMapVisible = false
        self.missionMapMode = .navigation
        self.terrainMapSnapshot = .empty
        self.targetMarkerState = nil
        self.missionPlanState = .empty
        self.missionPlanningDraft = .empty
        self.isInMissionDropZone = false
        self.tacticalMapState = .empty
        self.tacticalMapMode = .waypoint
        self.currentMissionPlan = nil
        self.missionExecutionState = .idle
        self.missionStatusSnapshot = .empty
        self.missionTimeline = nil
        self.missionDebrief = nil
        self.isCompassVisible = false
        self.payloadCameraStatus = .inactive
        self.payloadCameraOpticsState = PayloadCameraOpticsState()
        self.payloadMissionSignals = []
        self.isPayloadCameraAutoSwitchEnabled = false
        self.telemetry = .zero
        self.cachedDiagnostics = .zero

        self.payloadCameraController.setAutoSwitchAfterRelease(false)
        self.sceneController.setPayloadCameraOpticsState(self.payloadCameraOpticsState)
        sceneController.regenerateEnvironment(terrain)
        sceneController.setWorldBoundsVisible(isBoundaryBarrierVisible)
        rebuildVehicleComponentGraph()
        let initialLaunchDraft = defaultLaunchConfiguredDraft()
        committedTacticalMissionDraft = initialLaunchDraft
        workingTacticalMissionDraft = initialLaunchDraft
        refreshSceneLaunchAsset()
        sanitizeDynamicStateForSpawn(context: "init")
        sceneController.applyWeatherVisual(weather)
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        if let mountedCADPayload {
            sceneController.attachMountedCADPayload(mountedCADPayload)
        }
        if simulationRunMode.isSpectator {
            sceneController.configureSpectatorRuntime(camera: cameraConfiguration)
        }
        if let onlineRuntimeContext {
            configureOnlineTrial(onlineRuntimeContext)
        }
        refreshPayloadCameraStatus()

        homePosition = currentSpawnPoint()
        lastFiniteState = state
        resetTerrainMapTrail()
        refreshTerrainMapSnapshot(recordTrail: false)
        refreshTacticalMapState()
        refreshCompassOverlay()
        refreshFlightControlDiagnostics()
        refreshMissionStatus()
        telemetry = buildTelemetrySnapshot()

        logAvailableUAVCatalog(models: models)
        refreshKeyBindingDiagnostics()
        refreshGameControllerPresentation(force: true)
        syncControllerInteractionMode()
        keyboardInputService.setInputProcessingMode(.flight)
        keyboardInputService.start()
        emitLaunchDiagnostics(context: "init")
        startSimulationLoop()
    }

    deinit {
        simulationTimer?.invalidate()
        keyboardInputService.stop()
        telemetryExporter.finalizeSession()
    }

    func stopRuntimeForExit() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        keyboardInputService.stop()
        inputManager.reset()
        sceneController.configureOnlineTrialPlaceholders(nil)
        onlineFleetState = nil
        onlineAuthorityRegistry = nil
        onlineDamageState = OnlineVehicleDamageState()
        onlineRemoteSnapshotState = OnlineRemoteVehicleSnapshotState()
        recentLocalCollisionPairKeys = [:]
        onlineTrialStartedAt = nil
        onlineSharedEventTransport = nil
        onlineInterpolationStore = OnlineVehicleInterpolationStore()
        onlineInterpolatedRemoteStates = []
        onlineSnapshotTransport = nil
        isSimulationRunning = false
    }

    func configureOnlineTrial(
        _ context: OnlineTrialRuntimeContext,
        snapshotTransport: OnlineTrialSnapshotTransport? = nil,
        sharedEventTransport: OnlineSharedEventTransport? = nil
    ) {
        onlineRuntimeContext = context
        onlineAuthorityRegistry = context.makeInitialAuthorityRegistry()
        if let snapshotTransport {
            onlineSnapshotTransport = snapshotTransport
        }
        if let sharedEventTransport {
            onlineSharedEventTransport = sharedEventTransport
        }

        // v1.4: reset damage so new trial never inherits a previous DAMAGED state.
        onlineDamageState = OnlineVehicleDamageState()

        let fleetState = OnlineTrialFleetState(
            localParticipantID: context.localParticipant.id,
            localVehicleID: context.localVehicleID,
            vehicles: context.vehicleSlots
        )
        onlineFleetState = fleetState
        sceneController.configureOnlineTrialPlaceholders(fleetState)

        // v1.4: spawn local pilot UAV at its assigned slot position.
        if let slot = context.localVehicleSlot {
            let spawnPosition = OnlineTrialSpawnLayout.position(for: slot.spawnIndex)
            state.position = spawnPosition
            homePosition = spawnPosition
            #if DEBUG
            print("[LAN] online spawn local vehicle=\(slot.vehicleID) spawnIndex=\(slot.spawnIndex) position=\(spawnPosition)")
            #endif
        }

        // v1.4: record start time for collision grace period.
        onlineTrialStartedAt = Date().timeIntervalSince1970

        if context.isLocalSpectator {
            isToolPanelVisible = false
            isParametersPanelVisible = false
            activeControlModule = nil
            isPayloadPanelVisible = false
            isCommsLinkPanelVisible = false
            cameraConfiguration.mode = .spectator
            sceneController.configureSpectatorRuntime(camera: cameraConfiguration)
            inputManager.reset()
            keyboardInputService.resetTransientState()
        }
    }

    func configureOnlineSnapshotTransport(_ transport: OnlineTrialSnapshotTransport?) {
        onlineSnapshotTransport = transport
    }

    func applyOnlineRemoteSnapshotState(_ state: OnlineRemoteVehicleSnapshotState) {
        guard let onlineRuntimeContext else {
            return
        }

        var filteredState = OnlineRemoteVehicleSnapshotState()
        for snapshot in state.snapshots {
            filteredState.apply(
                snapshot,
                ignoringLocalVehicleID: onlineRuntimeContext.localVehicleID
            )
        }

        guard onlineRemoteSnapshotState != filteredState else { return }

        onlineRemoteSnapshotState = filteredState
        diagSnapshotInCount += filteredState.snapshots.count
        // Feed into interpolation buffer. Use local receive time so clock skew between sender
        // and receiver does not corrupt the interpolation timeline (v1.4.3 fix).
        onlineInterpolationStore.apply(
            filteredState,
            ignoringLocalVehicleID: onlineRuntimeContext.localVehicleID,
            receivedAt: CACurrentMediaTime()
        )
    }

    private func updateOnlineInterpolatedRemoteStates(now: TimeInterval) {
        guard onlineRuntimeContext != nil else { return }
        onlineInterpolationStore.removeStaleSnapshots(olderThan: 2.0, now: now)
        let states = onlineInterpolationStore.interpolatedStates(now: now)

        // Rate-gate scene node writes by activity-state-driven remoteSceneApplyInterval.
        // Skip entirely when rendering is paused.
        if !performancePolicy.stopRendering,
           now - lastOnlineSceneApplyTime >= performancePolicy.remoteSceneApplyInterval {
            sceneController.applyOnlineInterpolatedRemoteStates(states)
            lastOnlineSceneApplyTime = now
            diagSceneApplyCount += 1
        }

        // Throttle @Published update by overlayPublishInterval (min 0.25 s).
        // Presence changes (UAV appears / disappears) always publish immediately.
        let presenceChanged = states.isEmpty != onlineInterpolatedRemoteStates.isEmpty
            || states.count != onlineInterpolatedRemoteStates.count
        let publishInterval = max(0.25, performancePolicy.overlayPublishInterval)
        if presenceChanged || now - lastRemoteStatesPublishTime >= publishInterval {
            lastRemoteStatesPublishTime = now
            onlineInterpolatedRemoteStates = states
        }
    }

    #if DEBUG
    func injectDebugRemoteSnapshot() {
        let fakeVehicleID = UUID()
        let snapshot = OnlineVehicleStateSnapshot(
            sequenceNumber: 1,
            vehicleID: fakeVehicleID,
            participantID: UUID(),
            participantName: "DEBUG Ghost",
            timestamp: Date().timeIntervalSince1970,
            pose: OnlineVehiclePose(positionX: 5.0, positionY: 2.5, positionZ: 5.0, yaw: 0, pitch: 0, roll: 0),
            kinematics: .zero,
            isArmed: true,
            flightModeLabel: "manual"
        )
        var state = OnlineRemoteVehicleSnapshotState()
        state.apply(snapshot, ignoringLocalVehicleID: onlineTrialContext?.localVehicleID)
        onlineInterpolationStore.apply(state, ignoringLocalVehicleID: onlineTrialContext?.localVehicleID, receivedAt: CACurrentMediaTime())
    }
    #endif

    private func publishOnlineVehicleSnapshotIfNeeded(now: TimeInterval) {
        guard let context = onlineRuntimeContext,
              context.role == .pilot,
              let localVehicleID = context.localVehicleID,
              isSimulationRunning,
              now - lastOnlineSnapshotSentAt >= onlineSnapshotSendInterval else {
            return
        }
        // P2P v1.1: only the participant with local object authority publishes
        // simulation snapshots for that object.
        guard onlineAuthorityRegistry?.hasLocalAuthority(objectID: localVehicleID) != false else {
            return
        }

        onlineSnapshotSequenceNumber &+= 1
        lastOnlineSnapshotSentAt = now

        let componentDamage = componentGraph.components
            .filter { component in
                component.integrity < 0.999 || !component.isAttached ||
                    componentFailureRuntime.failures[component.id] != nil
            }
            .sorted { $0.id < $1.id }
            .map { component in
                OnlineVehicleComponentDamageSnapshot(
                    componentID: component.id,
                    integrity: component.integrity,
                    residualStrength: component.residualStrength,
                    attachmentState: component.attachmentState.rawValue,
                    failureMode: componentFailureRuntime.failures[component.id]?.mode.rawValue
                )
            }
        let onlineDamageEvents = recentDamageEvents.suffix(12).map { event in
            OnlineVehicleDamageEventSnapshot(
                sequenceNumber: event.sequenceNumber,
                timestamp: event.timestamp,
                type: event.type.rawValue,
                componentID: event.componentID,
                connectionID: event.connectionID,
                colliderID: event.colliderID,
                worldPointX: event.worldPoint?.x,
                worldPointY: event.worldPoint?.y,
                worldPointZ: event.worldPoint?.z,
                impulseNs: event.impulseNs,
                energyJ: event.energyJ,
                integrity: event.integrityAfter,
                residualStrength: event.residualStrengthAfter,
                failureMode: event.failureMode?.rawValue,
                reason: event.reason,
                detachedComponentIDs: event.detachedComponentIDs,
                massPropertiesRevision: event.massPropertiesRevision
            )
        }

        // P2P 0.8: snapshot publishing mirrors the local pilot vehicle only.
        // It is not authoritative network physics.
        let snapshot = OnlineVehicleStateSnapshot(
            sequenceNumber: onlineSnapshotSequenceNumber,
            vehicleID: localVehicleID,
            participantID: context.localParticipant.id,
            participantName: context.localParticipant.displayName,
            pose: OnlineVehiclePose(
                positionX: Double(state.position.x),
                positionY: Double(state.position.y),
                positionZ: Double(state.position.z),
                yaw: Double(state.orientation.z),
                pitch: Double(state.orientation.y),
                roll: Double(state.orientation.x)
            ),
            kinematics: OnlineVehicleKinematics(
                velocityX: Double(state.velocity.x),
                velocityY: Double(state.velocity.y),
                velocityZ: Double(state.velocity.z),
                speedMetersPerSecond: Double(simd_length(state.velocity)),
                altitudeMeters: Double(max(0.0, state.position.y))
            ),
            isArmed: isArmed,
            flightModeLabel: mode.rawValue,
            componentDamage: componentDamage,
            massPropertiesRevision: componentGraph.massPropertiesRevision,
            damageEventSequence: recentDamageEvents.last?.sequenceNumber ?? 0,
            damageEvents: onlineDamageEvents
        )
        onlineSnapshotTransport?.sendVehicleSnapshot(snapshot)
        diagSnapshotOutCount += 1
        emitLocalCollisionEventsIfNeeded(localSnapshot: snapshot, now: now)
    }

    // P2P v1.2: authority owner detects collision against remote replicas and submits
    // an OnlineSharedEvent. Host does NOT detect collision from snapshots.
    private func emitLocalCollisionEventsIfNeeded(
        localSnapshot: OnlineVehicleStateSnapshot,
        now: TimeInterval
    ) {
        guard let context = onlineRuntimeContext,
              context.localHasVehicleAuthority,
              let localVehicleID = context.localVehicleID,
              localSnapshot.vehicleID == localVehicleID,
              !onlineDamageState.isControlDisabled(vehicleID: localVehicleID),
              let sessionID = context.launchDescriptor.id as UUID? else { return }

        // v1.4: skip collision detection during grace period to avoid spawn-overlap false positives.
        if let startedAt = onlineTrialStartedAt,
           now - startedAt < onlineCollisionGracePeriodSeconds { return }

        // Only collide against replicas with fresh receiver-local snapshot data.
        // Stale replicas (>350 ms) may be frozen at a position that no longer reflects
        // the remote UAV's actual location, causing false collision events.
        let freshRemoteStates = onlineInterpolatedRemoteStates.filter { $0.sourceSnapshotAge < 0.35 }
        let candidates = localCollisionDetector.detect(
            localSnapshot: localSnapshot,
            remoteStates: freshRemoteStates
        )

        for candidate in candidates {
            let pairKey = [
                candidate.localVehicleID.uuidString,
                candidate.remoteVehicleID.uuidString
            ].sorted().joined(separator: ":")

            if let lastTime = recentLocalCollisionPairKeys[pairKey],
               now - lastTime < localCollisionEventCooldownSeconds { continue }

            let result = localCollisionDetector.result(for: candidate.relativeSpeedMetersPerSecond)
            guard result != .ignored else { continue }

            recentLocalCollisionPairKeys[pairKey] = now

            let event = OnlineSharedEvent(
                sessionID: sessionID,
                kind: .vehicleCollision,
                reporterParticipantID: context.localParticipant.id,
                reporterObjectID: localVehicleID,
                pairKey: pairKey,
                positionX: candidate.positionX,
                positionY: candidate.positionY,
                positionZ: candidate.positionZ,
                result: result,
                participants: [
                    OnlineSharedEventParticipant(
                        objectID: candidate.localVehicleID,
                        objectKind: .vehicle,
                        ownerParticipantID: context.localParticipant.id,
                        ownerVehicleID: candidate.localVehicleID,
                        displayName: context.localParticipant.displayName
                    ),
                    OnlineSharedEventParticipant(
                        objectID: candidate.remoteVehicleID,
                        objectKind: .vehicle,
                        ownerParticipantID: candidate.remoteParticipantID,
                        ownerVehicleID: candidate.remoteVehicleID,
                        displayName: candidate.remoteParticipantName
                    )
                ]
            )
            onlineSharedEventTransport?.submitSharedEvent(event)
        }
    }

    private func cleanupOnlineRemoteSnapshotsIfNeeded(now: TimeInterval) {
        guard onlineRuntimeContext != nil,
              now - lastOnlineSnapshotCleanupAt >= 0.5 else {
            return
        }

        lastOnlineSnapshotCleanupAt = now
        var snapshotState = onlineRemoteSnapshotState
        snapshotState.removeStaleSnapshots(olderThan: 2.0)
        applyOnlineRemoteSnapshotState(snapshotState)
    }

    // MARK: - Controls

    func injectMockRemotePacket(_ packet: RemoteControlPacket) {
        remoteInputProvider.ingestRemotePacket(packet)
    }

    func setX(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.x = value }, markManual: true, fixedWingManualOverrideAxes: .all)
    }

    func setY(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.y = value }, markManual: true, fixedWingManualOverrideAxes: .altitude)
    }

    func setZ(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.z = value }, markManual: true, fixedWingManualOverrideAxes: .all)
    }

    func setRoll(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.roll = value }, markManual: true, fixedWingManualOverrideAxes: .turn)
    }

    func setPitch(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.pitch = value }, markManual: true, fixedWingManualOverrideAxes: .altitude)
    }

    func setYaw(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.yaw = value }, markManual: true, fixedWingManualOverrideAxes: .turn)
    }

    func setThrottle(_ value: Double) {
        guard canControlLocalVehicle else { return }
        updateControlValues({ $0.throttle = value }, markManual: true, fixedWingManualOverrideAxes: .altitude)
    }

    func setPayloadType(_ type: PayloadType) {
        guard canControlLocalVehicle else { return }
        guard payloadDraftConfiguration.payloadType != type else {
            return
        }

        payloadDraftConfiguration.payloadType = type
        payloadDraftConfiguration.visualPreset = type.defaultVisualPreset
        if type == .fireHose {
            // Seed a default rig — a real hose's mass follows length × diameter class, not a
            // flat constant, so reset both alongside the type switch.
            payloadDraftConfiguration.fireHoseDiameterClass = .standard
            payloadDraftConfiguration.fireHoseLengthMeters = 30.0
            payloadDraftConfiguration.payloadMass = FireHoseDiameterClass.standard.massForLength(30.0)
        } else if type == .agriculturalSprayer {
            // Same idea as the hose: a real tank's mass follows how full it is, not a flat
            // constant. Reseed to a full tank on every switch into this type so a previously
            // drained tank (from an earlier attach/spray cycle) never silently carries over.
            payloadDraftConfiguration.agriculturalSprayerTankLiters = AgriculturalSprayerTuning.tankCapacityLiters
            payloadDraftConfiguration.payloadMass = AgriculturalSprayerTuning.massForFullTank()
        } else {
            payloadDraftConfiguration.payloadMass = type.defaultMass
        }
        if type != .custom {
            payloadDraftConfiguration.customName = ""
        }
        payloadDraftConfiguration.isAttached = payloadDraftMatchesInstalledPayload()
        payloadStatusMessageKey = nil
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func setPayloadMass(_ value: Double) {
        guard canControlLocalVehicle else { return }
        let clamped = Float(max(0.0, min(value, 5000.0)))
        guard abs(payloadDraftConfiguration.payloadMass - clamped) > 0.0001 else {
            return
        }

        payloadDraftConfiguration.payloadMass = clamped
        payloadDraftConfiguration.isAttached = payloadDraftMatchesInstalledPayload()
        payloadStatusMessageKey = nil
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    /// Rigs the fire-hose payload with a given diameter class and length, recomputing its mass
    /// as length × diameter-class kg/meter + fixed reel/nozzle hardware overhead — a real hose's
    /// mass isn't independently editable the way other payloads' is.
    func setFireHoseRigging(diameterClass: FireHoseDiameterClass, lengthMeters: Double) {
        guard canControlLocalVehicle else { return }
        let clampedLength = Float(lengthMeters).clamped(to: diameterClass.lengthRangeMeters)
        guard payloadDraftConfiguration.fireHoseDiameterClass != diameterClass
            || abs(payloadDraftConfiguration.fireHoseLengthMeters - clampedLength) > 0.001 else {
            return
        }

        payloadDraftConfiguration.fireHoseDiameterClass = diameterClass
        payloadDraftConfiguration.fireHoseLengthMeters = clampedLength
        payloadDraftConfiguration.payloadMass = diameterClass.massForLength(clampedLength)
        payloadDraftConfiguration.isAttached = payloadDraftMatchesInstalledPayload()
        payloadStatusMessageKey = nil
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    /// Rigs the fire-capsule launcher with a given capsule size and count, recomputing its mass as
    /// hardware overhead + count × per-capsule kg — mirrors `setFireHoseRigging`'s exact shape.
    func setFireCapsuleRigging(size: FireCapsuleSize, count: Int) {
        guard canControlLocalVehicle else { return }
        let clampedCount = min(max(count, FireCapsuleTuning.countRange.lowerBound), FireCapsuleTuning.countRange.upperBound)
        guard payloadDraftConfiguration.fireCapsuleSize != size
            || payloadDraftConfiguration.fireCapsuleCount != clampedCount else {
            return
        }

        payloadDraftConfiguration.fireCapsuleSize = size
        payloadDraftConfiguration.fireCapsuleCount = clampedCount
        payloadDraftConfiguration.payloadMass = FireCapsuleTuning.totalMass(size: size, count: clampedCount)
        payloadDraftConfiguration.isAttached = payloadDraftMatchesInstalledPayload()
        payloadStatusMessageKey = nil
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    // MARK: - Fiber-optic control link (comms equipment, not mission payload)

    func setFiberSpoolRigging(reelClass: FiberOpticReelClass, lengthMeters: Double) {
        guard canControlLocalVehicle else { return }
        let clampedLength = Float(lengthMeters).clamped(to: reelClass.lengthRangeMeters)
        guard fiberSpoolDraftConfiguration.reelClass != reelClass
            || abs(fiberSpoolDraftConfiguration.totalLengthMeters - clampedLength) > 0.001 else {
            return
        }

        fiberSpoolDraftConfiguration = FiberSpoolModule(reelClass: reelClass, totalLengthMeters: clampedLength)
        if isFiberSpoolAttached {
            installedFiberSpoolModule = fiberSpoolDraftConfiguration
            sceneController.attachFiberSpoolVisual(fiberSpoolDraftConfiguration)
            refreshPayloadRuntimeState()
        }
        hasUnsavedChanges = true
    }

    func attachFiberSpoolModule() {
        guard canControlLocalVehicle, !isFiberSpoolAttached else { return }
        installedFiberSpoolModule = fiberSpoolDraftConfiguration
        isFiberSpoolAttached = true
        // A freshly mounted reel starts fully wound — reset path-length/snag-risk accounting
        // rather than inheriting whatever a previously mounted (and possibly severed) reel left
        // behind.
        fiberLinkState = FiberLinkState()
        fiberOpticPathLengthUsedMeters = 0.0
        // Same reasoning as the fiber latch above: a drowned airframe from the previous attempt
        // must not keep sinking the freshly respawned one.
        isDrowned = false
        waterContactSeconds = 0.0
        fiberOpticSnagRisk = 0.0
        clearFiberPolyline()
        sceneController.clearFiberTetherVisual()
        // A previous reel's failsafe sequence may have ended in a terminal stage (landed/crashed/
        // etc.) — `beginControlLinkFailsafeSequence` only fires from `.none`, so this must be
        // cleared for a fresh reel's eventual severance to trigger the sequence again. Mounting a
        // fresh reel is exactly the "replace the reel" recovery action fiber requires — nothing
        // else ever clears `controlLinkFailsafeLatched` for a fiber-triggered latch.
        controlLinkFailsafeStage = .none
        controlLinkFailsafeStageElapsed = 0.0
        controlLinkFailsafeLatched = false
        controlLinkFailsafeLoiterCenter = nil
        sceneController.attachFiberSpoolVisual(fiberSpoolDraftConfiguration)
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func detachFiberSpoolModule() {
        guard canControlLocalVehicle, isFiberSpoolAttached else { return }
        installedFiberSpoolModule = nil
        isFiberSpoolAttached = false
        fiberLinkState = FiberLinkState()
        fiberOpticPathLengthUsedMeters = 0.0
        fiberOpticSnagRisk = 0.0
        clearFiberPolyline()
        sceneController.clearFiberTetherVisual()
        controlLinkFailsafeStage = .none
        controlLinkFailsafeStageElapsed = 0.0
        controlLinkFailsafeLatched = false
        controlLinkFailsafeLoiterCenter = nil
        sceneController.removeFiberSpoolVisual()
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func setPayloadCustomName(_ value: String) {
        guard canControlLocalVehicle else { return }
        guard payloadDraftConfiguration.customName != value else {
            return
        }

        payloadDraftConfiguration.customName = value
        payloadDraftConfiguration.isAttached = payloadDraftMatchesInstalledPayload()
        payloadStatusMessageKey = nil
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func attachPayload() {
        guard canControlLocalVehicle else { return }
        let capabilityCheck = PayloadController.capabilityCheck(
            for: payloadDraftConfiguration,
            profile: activeUAVProfile
        )
        payloadCapabilityCheck = capabilityCheck

        guard capabilityCheck.isAllowed else {
            payloadStatusMessageKey = capabilityCheck.rejectReason?.messageKey
            return
        }

        var attachedConfiguration = payloadDraftConfiguration
        attachedConfiguration.isAttached = true
        activePayloadReleaseID = nil
        releasedPayloadConfiguration = nil
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        installedPayloadConfiguration = attachedConfiguration
        mountedCADPayload = nil
        simulationLaunchConfiguration = nil
        payloadDraftConfiguration = attachedConfiguration
        payloadState = .attached
        payloadStatusMessageKey = "payload.message.attached"
        sceneController.attachPayloadVisual(attachedConfiguration)
        refreshPayloadCameraStatus()
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func removePayload() {
        guard canControlLocalVehicle else { return }
        guard installedPayloadConfiguration != nil || payloadState == .attached else {
            return
        }

        activePayloadReleaseID = nil
        installedPayloadConfiguration = nil
        mountedCADPayload = nil
        simulationLaunchConfiguration = nil
        releasedPayloadConfiguration = nil
        payloadDraftConfiguration.isAttached = false
        payloadState = .removed
        payloadStatusMessageKey = "payload.message.removed"
        sceneController.removePayloadVisual()
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        if cameraConfiguration.mode == .payload || cameraConfiguration.mode == .payloadOptics {
            setCameraMode(.follow)
        } else {
            refreshPayloadCameraStatus()
        }
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func releasePayload() {
        guard canControlLocalVehicle else { return }
        // The capsule launcher stays mounted and fires one capsule at a time out of an ammo
        // count — deliberately NOT the single-ownership attach-once/drop-once flow below (that
        // flow fully detaches `installedPayloadConfiguration`, which would "use up" the whole
        // launcher on the first drop). Same drop keybind, different mechanic underneath.
        if installedPayloadConfiguration?.payloadType == .fireCapsuleLauncher {
            dropFireCapsule()
            return
        }
        guard installedPayloadConfiguration != nil, payloadState == .attached else {
            payloadStatusMessageKey = "payload.message.no_payload_attached"
            refreshPayloadRuntimeState()
            return
        }

        releasedPayloadConfiguration = installedPayloadConfiguration
        lastPayloadImpact = nil
        let releaseID = sceneController.releasePayloadVisual()
        activePayloadReleaseID = releaseID
        installedPayloadConfiguration = nil
        payloadDraftConfiguration.isAttached = false
        payloadState = .released
        payloadStatusMessageKey = "payload.message.released"
        sceneController.setPayloadCameraFocusReleaseID(releaseID)
        if let nextMode = payloadCameraController.registerPayloadRelease(
            releaseID: releaseID,
            currentMode: cameraConfiguration.mode
        ) {
            let oldMode = cameraConfiguration.mode
            cameraConfiguration.mode = nextMode
            syncCameraSystem(from: oldMode)
        }
        refreshPayloadCameraStatus()
        refreshPayloadRuntimeState()
        if missionEventRecorder.currentTimeline != nil {
            recordMissionEvents([
                missionEventMapper.payloadTriggeredEvent(
                    missionID: currentMissionPlan?.id,
                    projectID: currentProjectID,
                    projectName: currentProjectName,
                    payloadState: payloadState,
                    statusSnapshot: missionStatusSnapshot,
                    batteryState: batteryState,
                    detailKey: payloadStatusMessageKey
                )
            ])
        }
        hasUnsavedChanges = true
    }

    /// Fires one capsule from the mounted fire-capsule launcher. Unlike `releasePayload()` above,
    /// the launcher itself never gets detached here — only the ammo count decrements. Impact
    /// suppression uses the same read-mutate-write pattern as `debugExtinguishNearestFireResponseTree`.
    private func dropFireCapsule() {
        guard capsuleController.consumeCapsule() else {
            payloadStatusMessageKey = "payload.capsule.empty"
            refreshPayloadRuntimeState()
            return
        }

        capsuleState = capsuleController.state
        let size = capsuleController.state.capsuleSize
        payloadStatusMessageKey = "payload.capsule.dropped_status"
        refreshPayloadRuntimeState()

        sceneController.dropFireCapsule(size: size) { [weak self] impactPosition in
            guard let self else { return }
            guard var runtime = self.fireResponseRuntime, runtime.isActive else { return }
            runtime.extinguishTreesInRadius(
                center: SIMD2<Float>(impactPosition.x, impactPosition.z),
                radiusMeters: size.blastRadiusMeters
            )
            self.fireResponseRuntime = runtime
            self.sceneController.updateFireResponseVisuals(
                treeStatuses: runtime.treeStatuses,
                viewerWorldPosition: finiteVector(self.state.position, fallback: self.lastFiniteState.position)
            )
            self.publishFireResponseState()
            if let outcome = runtime.outcome {
                self.handleFireResponseOutcome(outcome)
            }
        }

        if missionEventRecorder.currentTimeline != nil {
            recordMissionEvents([
                missionEventMapper.payloadTriggeredEvent(
                    missionID: currentMissionPlan?.id,
                    projectID: currentProjectID,
                    projectName: currentProjectName,
                    payloadState: payloadState,
                    statusSnapshot: missionStatusSnapshot,
                    batteryState: batteryState,
                    detailKey: payloadStatusMessageKey
                )
            ])
        }
    }

    /// Single, central source of truth for whether `arm()` is allowed right now — checked inside
    /// `arm()` itself (not just used to disable a SwiftUI button), so no input source (keyboard,
    /// controller, remote) can bypass it. Landing ends the aircraft's *motion*; it does not by
    /// itself repair whatever caused the control link to be lost, so this stays independent of
    /// `physicalState` reaching a grounded/rest value.
    func resolveArmAuthorization() -> ArmAuthorization {
        guard physicalState.permitsRearm, !hasFlightCriticalGraphDamage else {
            return ArmAuthorization(isAllowed: false, reason: .vehicleRequiresRecovery)
        }
        if fiberLinkState.status == .broken {
            return ArmAuthorization(
                isAllowed: false,
                reason: fiberLinkState.isSnagged ? .fiberBroken : .fiberExhausted
            )
        }
        if controlLinkFailsafeLatched {
            return ArmAuthorization(
                isAllowed: false,
                reason: controlLinkFailsafeTrigger == .radioLinkLost
                    ? .radioLinkUnavailable
                    : .linkLossFailsafeLatched
            )
        }
        if activeControlLinkType == .radio {
            let operationalStatus = currentMissionOperationalStatus(
                missionDistanceEstimate: currentMissionDistanceEstimate()
            )
            if operationalStatus.isInWarningLinkZone {
                return ArmAuthorization(isAllowed: false, reason: .radioLinkUnavailable)
            }
        }
        return .allowed
    }

    private func publishArmRejected(reason: ArmBlockReason) {
        armBlockReason = reason
    }

    func arm() {
        guard canControlLocalVehicle else { return }
        ensureSimulationRunning()
        let authorization = resolveArmAuthorization()
        guard authorization.isAllowed else {
            publishArmRejected(reason: authorization.reason)
            return
        }
        isArmed = true
        // Per-flight consumption counter, mirrors a real FC's flight log — charge level itself
        // (chargePercent) is untouched, only the "since arm" mAh tally resets.
        batteryState.mahDrawn = 0.0
        // Assisted-launch fixed wings have no ground takeoff: arming while
        // grounded returns the airframe to its launcher (the operator picks
        // it up / the shuttle receives it), ready for the next launch.
        if selectedDroneProfile.airframeClass == .fixedWing,
           activeLaunchMode().requiresLaunchObject,
           missionExecutionState.status != .running,
           missionExecutionState.status != .paused,
           launchCradleHoldActive ||
               physicalState.isGroundRestState ||
               heightAboveSupportSurface(for: state.position) <= 0.08 {
            seatAircraftInLaunchCradleIfAvailable()
        }
        let heightAboveSupport = heightAboveSupportSurface(for: state.position)
        if heightAboveSupport <= 0.08 {
            transitionPhysicalState(.armedOnGround)
        }
        if heightAboveSupport <= 0.05,
           selectedDroneProfile.airframeStyle == .tailsitterVTOL {
            beginTailsitterVerticalTakeoffOnArm()
        } else if heightAboveSupport <= 0.05,
                  selectedDroneProfile.airframeClass == .multirotor {
            updateControlValues({ values in
                values.throttle = max(values.throttle, 0.06)
            }, markManual: false)
        }
    }

    private func beginTailsitterVerticalTakeoffOnArm() {
        let baseline = resolvedFlightBaseline(for: .takeoff)
        state.propulsionUnits = selectedDroneProfile.propulsionUnitTemplate
        state.vtolTransitionProgress = 0.0
        state.vtolWingborneBlend = 0.0
        state.vtolWingLiftRatio = 0.0
        state.vtolTransitionBlocked = false
        state.vtolPhase = .verticalTakeoff
        let restOrientation = spawnOrientation(for: selectedDroneProfile)
        state.orientation.x = restOrientation.x
        state.orientation.y = restOrientation.y
        resyncFixedWingAttitudeFromEuler()
        setFlightMode(.takeoff, reason: "tailsitter_arm_vertical_takeoff")
        transitionPhysicalState(.takeoffTransition)
        updateControlValues({ values in
            values.y = max(values.y, Double(max(3.0, state.position.y + 3.0)))
            values.roll = 0.0
            values.pitch = 0.0
            values.yaw = Double(state.orientation.z.radiansToDegrees)
            values.throttle = max(values.throttle, Double(baseline.takeoffThrottleReference))
            values.vtolTransitionLever = 0.0
        }, markManual: false)
    }

    func disarm(forceEmergency: Bool = false, preserveCrashDynamics: Bool = false) {
        guard canControlLocalVehicle else { return }
        cancelTargetMarkerAutoNavigation()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_disarmed")
        isArmed = false
        if forceEmergency {
            setFlightMode(.emergencyStop, reason: "disarm_emergency")
        } else if heightAboveSupportSurface(for: state.position) <= 0.1 {
            setFlightMode(.manual, reason: "disarm_grounded")
        }
        if preserveCrashDynamics {
            transitionPhysicalState(.crashed)
        } else if physicalState != .crashed {
            transitionPhysicalState(.disarmed)
        }

        updateControlValues({ values in
            values.throttle = 0.0
            values.roll = 0.0
            values.pitch = 0.0
        }, markManual: false)
        keyboardInputService.resetTransientState()
        inputManager.reset()
        resetFlightControlRouting()

        let hasUnsettledPhysicalAftermath = collisionAftermathState != .nominal ||
            simd_length(state.velocity) > 0.18 ||
            simd_length(state.angularVelocity) > 0.25 ||
            simd_length(state.bodyAngularVelocity) > 0.25
        if !preserveCrashDynamics,
           !hasUnsettledPhysicalAftermath,
           !launchCradleHoldActive,
           // A crashed airframe is still tumbling in the normal airframe
           // solver — settling would snap it flat mid-motion.
           physicalState != .crashed,
           (heightAboveSupportSurface(for: state.position) <= 0.08 || physicalState.isGroundRestState) {
            settleDisarmedGroundedState()
        }
    }

    func reset() {
        ensureSimulationRunning()
        clearMissionPlan()
        clearTargetMarker()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_reset")
        setFlightMode(.manual, reason: "reset")
        flightControlMode = .stabilized
        clearSignalLossState(restoringInputMode: false)
        // A full reset is a clean slate for a new attempt with the same equipment loadout — any
        // fiber break/radio-lost latch from the previous attempt must not carry over and leave
        // `resolveArmAuthorization()` still refusing to arm the freshly-respawned aircraft. A
        // mounted fiber spool stays mounted, just returned to a fresh, unbroken state (mirrors
        // `attachFiberSpoolModule()`'s own "freshly wound reel" reset).
        fiberLinkState = FiberLinkState()
        fiberOpticPathLengthUsedMeters = 0.0
        fiberOpticSnagRisk = 0.0
        clearFiberPolyline()
        // Same reasoning as the fiber latch above: a drowned airframe from the previous attempt
        // must not keep sinking the freshly respawned one.
        isDrowned = false
        waterContactSeconds = 0.0
        sceneController.clearFiberTetherVisual()
        installedFiberSpoolModule?.deployedLengthMeters = 0.0
        controlLinkFailsafeStage = .none
        controlLinkFailsafeStageElapsed = 0.0
        controlLinkFailsafeLatched = false
        controlLinkFailsafeLoiterCenter = nil
        stableRadioReconnectionSeconds = 0.0
        armBlockReason = .none
        state = DroneState.initial
        state.propulsionUnits = selectedDroneProfile.propulsionUnitTemplate
        lastFiniteState = state
        controlValues = DroneControlValues()
        batteryState = .full
        damageState = .pristine
        rebuildVehicleComponentGraph()
        thermalState = .nominal
        diagnosticMode = .normal
        collisionAnalysis = .safe
        isArmed = false
        wingmen.removeAll()
        fleetInterDroneRisk = 0.0
        fleetNearestInterDroneDistance = .infinity
        showBatteryDepletedDialog = false
        homePosition = currentSpawnPoint()
        simulationTime = 0.0
        telemetrySamplingAccumulator = 0.0
        hudPublishAccumulator = 0.0
        diagnosticsSamplingAccumulator = 0.0
        groundContactAccumulator = 0.0
        stableGroundAccumulator = 0.0
        airborneAccumulator = 0.0
        impactSeverityAccumulator = 0.0
        collisionAftermathState = .nominal
        signalLossCause = nil
        collisionCooldown = 0.0
        manualYawIntent = 0.0
        cameraLookVelocity = .zero
        payloadGimbalLookVelocity = .zero
        lastCollisionDebugEnabled = false
        releasedPayloadConfiguration = nil
        lastPayloadImpact = nil
        payloadSelfInteractionTimer = 0.0
        payloadSelfInteractionSeverity = 0.0
        payloadControlPenalty = 0.0
        resetFixedWingAutopilotCommands()
        autoPathPlanner.invalidate()
        autoFlightGoal = nil
        autoFlightGoalIndex = 0
        returnHomeStage = .idle
        navigationSnapshot = .idle
        activePayloadReleaseID = nil
        releasedPayloadConfiguration = nil
        payloadSelfInteractionTimer = 0.0
        payloadSelfInteractionSeverity = 0.0
        payloadControlPenalty = 0.0
        keyboardInputService.setInputProcessingMode(.flight)
        keyboardInputService.resetTransientState()
        inputManager.reset()
        resetFlightControlRouting()
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        if cameraConfiguration.mode == .payload || cameraConfiguration.mode == .payloadOptics {
            cameraConfiguration.mode = .follow
        }
        sceneController.resetCameraRuntimeState()
        sceneController.clearDroppedPayloadVisuals()
        if payloadState == .released || payloadState == .falling || payloadState == .landed {
            payloadState = .cleanedUp
            payloadStatusMessageKey = nil
        }

        sanitizeDynamicStateForSpawn(context: "reset")
        controlValues = neutralControls(from: state)
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        sceneController.updateFleetWingmen([], profile: selectedDroneProfile, throttle: 0.0, deltaTime: 0.0)
        sceneController.updatePathDebug(
            path: [],
            currentWaypointIndex: 0,
            start: nil,
            goal: nil,
            enabled: false
        )
        refreshPayloadRuntimeState()
        refreshTerrainMapSnapshot(recordTrail: false)
        refreshCompassOverlay()

        warnings = []
        lastCollisionSource = "n/a"
        telemetry = buildTelemetrySnapshot()
        telemetryExporter.append(snapshot: telemetry)
        hasUnsavedChanges = true
        emitLaunchDiagnostics(context: "reset")
    }

    func recoverSignal() {
        guard signalState == .signalLost else {
            return
        }

        cancelTargetMarkerAutoNavigation()
        signalState = .recoveryPending
        signalLossSecondAccumulator = 0.0

        setFlightMode(.manual, reason: "signal_recovery")
        isArmed = false
        manualYawIntent = 0.0
        cameraLookVelocity = .zero
        payloadGimbalLookVelocity = .zero
        autoPathPlanner.invalidate()
        autoFlightGoal = nil
        autoFlightGoalIndex = 0
        returnHomeStage = .idle
        navigationSnapshot = .idle
        collisionCooldown = 0.0

        sanitizeDynamicStateForSpawn(context: "signal_recovery")
        controlValues = neutralControls(from: state)
        collisionAnalysis = .safe
        showBatteryDepletedDialog = false
        fleetInterDroneRisk = 0.0
        fleetNearestInterDroneDistance = .infinity

        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        sceneController.updateFleetWingmen(
            wingmen,
            profile: selectedDroneProfile,
            throttle: state.throttle,
            deltaTime: 0.0
        )
        sceneController.updatePathDebug(
            path: [],
            currentWaypointIndex: 0,
            start: nil,
            goal: nil,
            enabled: false
        )

        clearSignalLossState(restoringInputMode: false)
        keyboardInputService.setInputProcessingMode(.flight)
        keyboardInputService.resetTransientState()
        inputManager.reset()
        resetFlightControlRouting()
        sceneController.resetCameraRuntimeState()
        refreshTerrainMapSnapshot(recordTrail: false)
        refreshCompassOverlay()
        warnings = buildWarnings()
        telemetry = buildTelemetrySnapshot()
        hasUnsavedChanges = true
    }

    func takeoff() {
        guard canControlLocalVehicle else { return }
        ensureSimulationRunning()
        guard isArmed else {
            return
        }
        cancelTargetMarkerAutoNavigation()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_takeoff")
        let baseline = resolvedFlightBaseline(for: .takeoff)
        setFlightMode(.takeoff, reason: "takeoff_requested")
        if state.position.y <= 0.10 {
            transitionPhysicalState(.takeoffTransition)
        }
        switch selectedDroneProfile.airframeClass {
        case .fixedWing:
            if activeLaunchMode() != .standard {
                beginFixedWingLaunchSequence()
            } else {
                resetFixedWingAutopilotCommands()
            }
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = max(
                    values.pitch,
                    Double(selectedDroneProfile.fixedWingParameters?.initialClimbPitchDeg ?? 10.0)
                )
                values.throttle = max(values.throttle, Double(baseline.takeoffThrottleReference))
            }, markManual: false)
        case .multirotor:
            updateControlValues({ values in
                values.y = max(values.y, 3.0)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, Double(baseline.takeoffThrottleReference))
            }, markManual: false)
        case .hybridVTOL:
            updateControlValues({ values in
                values.y = max(values.y, 3.0)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, Double(baseline.takeoffThrottleReference))
                values.vtolTransitionLever = 0.0
            }, markManual: false)
        }
    }

    func land() {
        guard canControlLocalVehicle else { return }
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_landing")
        let baseline = resolvedFlightBaseline(for: .landing)
        setFlightMode(.landing, reason: "landing_requested")
        if state.position.y > 0.05 {
            transitionPhysicalState(.landing)
        }
        switch selectedDroneProfile.airframeClass {
        case .fixedWing:
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = min(max(values.pitch, 6.0), 14.0)
                values.throttle = min(values.throttle, Double(baseline.landingThrottleReference))
            }, markManual: false)
        case .multirotor:
            updateControlValues({ values in
                values.y = 0.0
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = min(values.throttle, Double(baseline.landingThrottleReference))
            }, markManual: false)
        case .hybridVTOL:
            let hoverBaseline = resolvedFlightBaseline(for: .hover)
            let needsHoverTransition = state.vtolTransitionProgress > 0.08
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.z = Double(state.position.z)
                values.y = needsHoverTransition
                    ? Double(max(homePosition.y + 1.8, state.position.y))
                    : 0.0
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = needsHoverTransition
                    ? max(values.throttle, Double(hoverBaseline.hoverLockThrottle))
                    : min(values.throttle, Double(baseline.landingThrottleReference))
                values.vtolTransitionLever = -1.0
            }, markManual: false)
        }
    }

    func hover() {
        guard canControlLocalVehicle else { return }
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_hover")
        let baseline = resolvedFlightBaseline(for: .hover)
        guard baseline.hoverCapable else {
            setFlightMode(.manual, reason: "hover_unavailable_for_airframe")
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, Double(baseline.cruiseReferenceThrottle))
            }, markManual: false)
            return
        }
        setFlightMode(.hover, reason: "hover_requested")
        lockControlsToCurrentState(overrideThrottle: Double(baseline.hoverLockThrottle))
        if selectedDroneProfile.airframeClass == .hybridVTOL {
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, Double(baseline.hoverLockThrottle))
                values.vtolTransitionLever = -1.0
            }, markManual: false)
        }
    }

    func activateAutoPath() {
        ensureSimulationRunning()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_auto_path")
        guard fixedWingAutonomousRouteExecutionEnabled else {
            disengageFixedWingAutonomousRouteExecution(
                reason: "fixed_wing_auto_path_disabled"
            )
            return
        }
        if targetMarkerState != nil {
            guard canStartTargetMarkerAutoNavigation else {
                return
            }
            autoPathPlanner.invalidate()
            autoFlightGoal = nil
            autoNavigationController.start(safeTravelAltitude: targetMarkerTravelAltitude())
            setFlightMode(.autoPath, reason: "user_requested_auto_path_marker")
            prepareHybridVTOLAutopilotForForwardRoute()
            navigationSnapshot = .idle
            refreshTerrainMapSnapshot(recordTrail: false)
            return
        }
        setFlightMode(.autoPath, reason: "user_requested_auto_path_patrol")
        prepareHybridVTOLAutopilotForForwardRoute()
        returnHomeStage = .idle
        autoPathPlanner.invalidate()
        autoFlightGoal = nextAutoPatrolGoal(resetCycle: true)
        navigationSnapshot = .idle
    }

    func activateReturnHome(reason: String = "user_requested_return_home") {
        ensureSimulationRunning()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_return_home")
        guard fixedWingAutonomousRouteExecutionEnabled else {
            disengageFixedWingAutonomousRouteExecution(
                reason: "fixed_wing_return_home_disabled"
            )
            return
        }
        cancelTargetMarkerAutoNavigation()
        setFlightMode(.returnHome, reason: reason)
        prepareHybridVTOLAutopilotForForwardRoute()
        returnHomeStage = .ascend
        setFixedWingGuidanceSource(.returnHome, reason: "\(reason)_guidance_armed")
        autoFlightGoal = nil
        autoPathPlanner.invalidate()
        navigationSnapshot = .idle
    }

    func activateEmergencyStop() {
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
        deactivateFixedWingAssist(reason: "fixed_wing_assist_emergency_stop")
        disarm(forceEmergency: true)
        lockControlsToCurrentState(overrideThrottle: 0.0)
    }

    func toggleSimulation() {
        isSimulationRunning.toggle()
        lastTimestamp = nil
    }

    func toggleControlPanel() {
        setControlPanelVisible(!isParametersPanelVisible)
    }

    func setControlPanelVisible(_ visible: Bool) {
        if visible {
            if activeControlModule == nil {
                activeControlModule = canUseControlModule(lastSidebarModule) ? lastSidebarModule : .camera
            }
            isParametersPanelVisible = activeControlModule != nil
        } else {
            isParametersPanelVisible = false
        }
    }

    func setActiveControlModule(_ module: ControlModule?) {
        if let module, !canUseControlModule(module) {
            return
        }
        if let activeControlModule {
            lastSidebarModule = activeControlModule
        }
        if let module {
            lastSidebarModule = module
        }
        activeControlModule = module
        isParametersPanelVisible = module != nil
        isPayloadPanelVisible = false
        isCommsLinkPanelVisible = false
    }

    func toggleActiveControlModule(_ module: ControlModule) {
        setActiveControlModule(activeControlModule == module ? nil : module)
    }

    func togglePayloadPanel() {
        guard canControlLocalVehicle else { return }
        isPayloadPanelVisible.toggle()
        if isPayloadPanelVisible {
            isCommsLinkPanelVisible = false
        }
    }

    func toggleCommsLinkPanel() {
        guard canControlLocalVehicle else { return }
        isCommsLinkPanelVisible.toggle()
        if isCommsLinkPanelVisible {
            isPayloadPanelVisible = false
        }
    }

    func setCommsLinkPanelVisible(_ visible: Bool) {
        guard canControlLocalVehicle || !visible else { return }
        isCommsLinkPanelVisible = visible
    }

    func setPayloadPanelVisible(_ visible: Bool) {
        guard canControlLocalVehicle || !visible else { return }
        isPayloadPanelVisible = visible
    }

    func setBoundaryBarrierVisible(_ visible: Bool) {
        guard isBoundaryBarrierVisible != visible else {
            return
        }
        isBoundaryBarrierVisible = visible
        sceneController.setWorldBoundsVisible(visible)
    }

    func toggleTerrainMap() {
        refreshTerrainMapSnapshot(recordTrail: false)
        isTerrainMapVisible.toggle()
        refreshFlightControlDiagnostics()
    }

    func toggleMissionMap() {
        if isMissionMapVisible {
            exitMissionMap()
        } else {
            openMissionMap()
        }
    }

    func openMissionMap() {
        refreshTerrainMapSnapshot(recordTrail: false)
        workingTacticalMissionDraft = committedTacticalMissionDraft
        tacticalMapMode = workingTacticalMissionDraft.selectedLaunchMode.requiresLaunchObject
            ? .launchObject
            : .waypoint
        if bindingsViewModel.isPresented {
            setBindingsPanelVisible(false)
        }
        controllerUIBridge.clearSurfaceTargets("simulation-workspace")
        isMissionMapVisible = true
        refreshTacticalMapState()
        refreshFlightControlDiagnostics()
    }

    func exitMissionMap() {
        workingTacticalMissionDraft = committedTacticalMissionDraft
        controllerUIBridge.clearSurfaceTargets("mission-map-overlay")
        isMissionMapVisible = false
        controllerUIBridge.invalidateSurfaceLayout("simulation-workspace", resetCursor: true)
        refreshTacticalMapState()
        refreshFlightControlDiagnostics()
    }

    func cancelMissionPlanningChanges() {
        workingTacticalMissionDraft = committedTacticalMissionDraft
        refreshTacticalMapState()
    }

    func setTacticalMapMode(_ mode: TacticalMapMode) {
        if mode == .launchObject,
           !workingTacticalMissionDraft.selectedLaunchMode.requiresLaunchObject,
           let assistedMode = selectedDroneProfile.supportedLaunchModes.first(where: {
               ($0 == .handLaunch || $0 == .catapult) && $0.isRuntimeImplemented
           }) {
            workingTacticalMissionDraft = missionDraftBuilder.setLaunchMode(
                assistedMode,
                in: workingTacticalMissionDraft,
                defaultLaunchAngleDegrees: preferredLaunchAngleDegrees(for: assistedMode)
            )
        }

        guard tacticalMapMode != mode else {
            refreshTacticalMapState()
            return
        }
        tacticalMapMode = mode
        refreshTacticalMapState()
    }

    func handleTacticalMapTap(at planarPosition: SIMD2<Float>) {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        let viewport = currentTacticalMapViewport()
        if tacticalMapMode == .waypoint,
           let tappedWaypoint = fixedWingAssistWaypoint(near: planarPosition, viewport: viewport) {
            selectFixedWingAssistWaypoint(tappedWaypoint.id)
            return
        }

        if tacticalMapMode == .launchObject {
            var launchMode = workingTacticalMissionDraft.selectedLaunchMode
            if !launchMode.requiresLaunchObject,
               let assistedMode = selectedDroneProfile.supportedLaunchModes.first(where: {
                   ($0 == .handLaunch || $0 == .catapult) && $0.isRuntimeImplemented
               }) {
                launchMode = assistedMode
                workingTacticalMissionDraft = missionDraftBuilder.setLaunchMode(
                    assistedMode,
                    in: workingTacticalMissionDraft,
                    defaultLaunchAngleDegrees: preferredLaunchAngleDegrees(for: assistedMode)
                )
            }
            guard let launchObjectType = launchMode.defaultLaunchObjectType else {
                refreshTacticalMapState()
                return
            }
            let heading = workingTacticalMissionDraft.launchObject?.headingDegrees ??
                initialLaunchHeadingDegrees(from: planarPosition)
            workingTacticalMissionDraft = missionDraftBuilder.upsertLaunchObject(
                at: planarPosition,
                headingDegrees: heading,
                type: launchObjectType,
                in: workingTacticalMissionDraft,
                viewport: viewport,
                defaultLaunchAngleDegrees: preferredLaunchAngleDegrees(
                    for: launchObjectType.launchMode
                )
            )
        } else if let zoneType = tacticalMapMode.zoneType {
            workingTacticalMissionDraft = missionDraftBuilder.upsertZone(
                type: zoneType,
                center: planarPosition,
                in: workingTacticalMissionDraft,
                viewport: viewport
            )
        } else {
            workingTacticalMissionDraft = missionDraftBuilder.addWaypoint(
                at: planarPosition,
                to: workingTacticalMissionDraft,
                viewport: viewport
            )
        }

        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func setTacticalLaunchMode(_ launchMode: LaunchMode) {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused,
              selectedDroneProfile.supportedLaunchModes.contains(launchMode),
              launchMode.isRuntimeImplemented else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.setLaunchMode(
            launchMode,
            in: workingTacticalMissionDraft,
            defaultLaunchAngleDegrees: preferredLaunchAngleDegrees(for: launchMode)
        )
        tacticalMapMode = launchMode.requiresLaunchObject ? .launchObject : .waypoint
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func setTacticalLaunchHeading(_ headingDegrees: Float) {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.setLaunchHeading(
            headingDegrees,
            in: workingTacticalMissionDraft
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func setTacticalLaunchAngle(_ angleDegrees: Float) {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.setLaunchAngle(
            angleDegrees,
            in: workingTacticalMissionDraft
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    private func initialLaunchHeadingDegrees(
        from launchPosition: SIMD2<Float>
    ) -> Float {
        if let firstWaypoint = workingTacticalMissionDraft.waypoints.first {
            let delta = firstWaypoint.position - launchPosition
            if simd_length(delta) > 0.05 {
                return MissionLaunchGeometry.normalizedHeadingDegrees(
                    atan2(delta.x, delta.y) * 180.0 / .pi
                )
            }
        }

        let forward = SIMD2<Float>(-sin(state.orientation.z), -cos(state.orientation.z))
        return MissionLaunchGeometry.normalizedHeadingDegrees(
            atan2(forward.x, forward.y) * 180.0 / .pi
        )
    }

    private func preferredLaunchAngleDegrees(for mode: LaunchMode) -> Float? {
        guard let wing = selectedDroneProfile.fixedWingParameters else {
            return nil
        }
        switch mode {
        case .handLaunch:
            return wing.handLaunchAngleDegrees
        case .catapult:
            return wing.catapultRailAngleDegrees
        case .standard, .runway, .vtol:
            return nil
        }
    }

    func clearTacticalLaunchObject() {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.clearLaunchObject(
            from: workingTacticalMissionDraft
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func removeLastTacticalWaypoint() {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.removeLastWaypoint(
            from: workingTacticalMissionDraft
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func clearTacticalRoute() {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.clearRoute(
            from: workingTacticalMissionDraft
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func clearTacticalZones() {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.clearZones(
            from: workingTacticalMissionDraft
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func setTacticalZoneRadius(
        type: MissionZoneType,
        radius: Float
    ) {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        workingTacticalMissionDraft = missionDraftBuilder.setZoneRadius(
            radius,
            for: type,
            in: workingTacticalMissionDraft,
            viewport: currentTacticalMapViewport()
        )
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func setTacticalMinimumAltitude(_ altitudeMeters: Float) {
        updateWorkingMissionConstraints { constraints in
            constraints.altitude.minimumMeters = max(0.0, altitudeMeters)
            constraints.altitude.maximumMeters = max(
                constraints.altitude.minimumMeters,
                constraints.altitude.maximumMeters
            )
        }
    }

    func setTacticalMaximumAltitude(_ altitudeMeters: Float) {
        updateWorkingMissionConstraints { constraints in
            constraints.altitude.maximumMeters = max(0.0, altitudeMeters)
            constraints.altitude.minimumMeters = min(
                constraints.altitude.minimumMeters,
                constraints.altitude.maximumMeters
            )
        }
    }

    func setTacticalMinimumSpeed(_ speedMetersPerSecond: Float) {
        updateWorkingMissionConstraints { constraints in
            constraints.speed.minimumMetersPerSecond = max(0.0, speedMetersPerSecond)
            constraints.speed.maximumMetersPerSecond = max(
                constraints.speed.minimumMetersPerSecond,
                constraints.speed.maximumMetersPerSecond
            )
        }
    }

    func setTacticalMaximumSpeed(_ speedMetersPerSecond: Float) {
        updateWorkingMissionConstraints { constraints in
            constraints.speed.maximumMetersPerSecond = max(0.1, speedMetersPerSecond)
            constraints.speed.minimumMetersPerSecond = min(
                constraints.speed.minimumMetersPerSecond,
                constraints.speed.maximumMetersPerSecond
            )
        }
    }

    func saveTacticalMissionDraft() {
        guard tacticalMapState.draftStatus.canSave else {
            refreshTacticalMapState()
            return
        }

        committedTacticalMissionDraft = workingTacticalMissionDraft
        hasUnsavedChanges = true
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    private func updateWorkingMissionConstraints(
        _ update: (inout MissionConstraints) -> Void
    ) {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        var nextDraft = workingTacticalMissionDraft
        update(&nextDraft.constraints)
        workingTacticalMissionDraft = nextDraft
        invalidatePreparedMissionIfNeeded()
        refreshTacticalMapState()
    }

    func prepareMission() {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            refreshMissionStatus()
            return
        }

        let draft = isMissionMapVisible
            ? workingTacticalMissionDraft
            : committedTacticalMissionDraft
        let plan = missionPlanBuilder.buildPlan(
            from: draft,
            viewport: currentTacticalMapViewport(),
            airframeClass: selectedDroneProfile.airframeClass,
            fixedWingParameters: selectedDroneProfile.fixedWingParameters,
            supportedLaunchModes: selectedDroneProfile.supportedLaunchModes
        )
        currentMissionPlan = plan
        invalidateFixedWingRouteCaches()
        syncFixedWingAssistSelection()
        refreshFixedWingAssistRuntimeDebugState()
        refreshSceneMissionWaypointCaptureZones()
        missionRuntimeMonitor.reset()
        if plan.isReadyForExecution {
            let binding = missionExecutionBinder.bind(
                plan: plan,
                currentPosition: currentPlanarPosition()
            )
            missionExecutionState = missionExecutionCoordinator.prepare(
                plan: plan,
                binding: binding
            )
        } else {
            missionExecutionState = .idle
        }
        refreshSceneMissionWaypointCaptureZones()
        refreshMissionStatus()
        beginMissionTimelineSession(for: plan)
        recordMissionEvents(
            missionEventMapper.preparedEvents(
                plan: plan,
                projectID: currentProjectID,
                projectName: currentProjectName,
                statusSnapshot: missionStatusSnapshot,
                batteryState: batteryState
            )
        )
    }

    func startMissionExecution() {
        recordMissionEvents([
            missionEventMapper.missionStartRequestedEvent(
                plan: currentMissionPlan,
                projectID: currentProjectID,
                projectName: currentProjectName,
                statusSnapshot: missionStatusSnapshot,
                batteryState: batteryState
            )
        ])
        refreshMissionStatus()

        guard currentMissionPlan != nil,
              missionExecutionState.canStart,
              missionStatusSnapshot.canStart else {
            refreshMissionStatus()
            recordMissionStartBlockedEvent(plan: currentMissionPlan)
            return
        }

        let previousExecutionState = missionExecutionState
        let previousSafetyState = missionSafetyState
        let previousSnapshot = missionStatusSnapshot

        guard fixedWingAutonomousRouteExecutionEnabled else {
            missionExecutionState = missionExecutionCoordinator.blocked(
                from: missionExecutionState,
                reason: .missionStartBlocked,
                detailKey: "mission.status.reason.mission_start_blocked"
            )
            disengageFixedWingAutonomousRouteExecution(
                reason: "fixed_wing_mission_autopilot_disabled"
            )
            refreshMissionStatus()
            recordMissionStateTransitions(
                previousExecutionState: previousExecutionState,
                previousSafetyState: previousSafetyState,
                previousSnapshot: previousSnapshot
            )
            return
        }

        guard canBindMissionTargetToAutopilot else {
            missionExecutionState = missionExecutionCoordinator.blocked(
                from: missionExecutionState,
                reason: missionSafetyState.blockReason?.failureReason ?? .missionStartBlocked,
                detailKey: missionSafetyState.blockReason?.detailKey ?? "mission.status.reason.mission_start_blocked"
            )
            refreshMissionStatus()
            recordMissionStateTransitions(
                previousExecutionState: previousExecutionState,
                previousSafetyState: previousSafetyState,
                previousSnapshot: previousSnapshot
            )
            return
        }

        missionExecutionState = missionExecutionCoordinator.start(
            state: missionExecutionState
        )
        missionRuntimeMonitor.reset()
        if let activeTarget = missionExecutionState.activeTarget {
            let shouldDelayRouteCapture = shouldDelayFixedWingRouteCaptureDuringLaunch()
            bindMissionExecutionTarget(activeTarget, startNavigation: !shouldDelayRouteCapture)
            if shouldDelayRouteCapture {
                setFlightMode(.takeoff, reason: "mission_start_fixed_wing_launch")
                beginFixedWingLaunchSequence()
            }
        }
        missionPlanState = .empty
        refreshSceneMissionWaypointCaptureZones()
        refreshMissionStatus()
        recordMissionStateTransitions(
            previousExecutionState: previousExecutionState,
            previousSafetyState: previousSafetyState,
            previousSnapshot: previousSnapshot
        )
    }

    func pauseMissionExecution() {
        guard missionExecutionState.canPause else {
            refreshMissionStatus()
            return
        }

        let previousExecutionState = missionExecutionState
        let previousSafetyState = missionSafetyState
        let previousSnapshot = missionStatusSnapshot
        missionExecutionState = missionExecutionCoordinator.pause(
            state: missionExecutionState
        )
        enterMissionExecutionHold()
        refreshMissionStatus()
        recordMissionStateTransitions(
            previousExecutionState: previousExecutionState,
            previousSafetyState: previousSafetyState,
            previousSnapshot: previousSnapshot
        )
    }

    func resumeMissionExecution() {
        refreshMissionStatus()

        guard missionExecutionState.canResume else {
            refreshMissionStatus()
            return
        }
        let previousExecutionState = missionExecutionState
        let previousSafetyState = missionSafetyState
        let previousSnapshot = missionStatusSnapshot
        guard fixedWingAutonomousRouteExecutionEnabled else {
            missionExecutionState = missionExecutionCoordinator.blocked(
                from: missionExecutionState,
                reason: .missionStartBlocked,
                detailKey: "mission.status.reason.mission_start_blocked"
            )
            disengageFixedWingAutonomousRouteExecution(
                reason: "fixed_wing_mission_autopilot_disabled"
            )
            refreshMissionStatus()
            recordMissionStateTransitions(
                previousExecutionState: previousExecutionState,
                previousSafetyState: previousSafetyState,
                previousSnapshot: previousSnapshot
            )
            return
        }
        guard missionStatusSnapshot.canResume,
              canBindMissionTargetToAutopilot,
              let activeTarget = missionExecutionState.activeTarget else {
            missionExecutionState = missionExecutionCoordinator.blocked(
                from: missionExecutionState,
                reason: missionSafetyState.blockReason?.failureReason ?? .missionStartBlocked,
                detailKey: missionSafetyState.blockReason?.detailKey ?? "mission.status.reason.mission_start_blocked"
            )
            refreshMissionStatus()
            recordMissionStateTransitions(
                previousExecutionState: previousExecutionState,
                previousSafetyState: previousSafetyState,
                previousSnapshot: previousSnapshot
            )
            return
        }

        missionExecutionState = missionExecutionCoordinator.resume(
            state: missionExecutionState
        )
        missionRuntimeMonitor.reset()
        let shouldDelayRouteCapture = shouldDelayFixedWingRouteCaptureDuringLaunch()
        bindMissionExecutionTarget(activeTarget, startNavigation: !shouldDelayRouteCapture)
        if shouldDelayRouteCapture {
            setFlightMode(.takeoff, reason: "mission_resume_fixed_wing_launch")
            beginFixedWingLaunchSequence()
        }
        refreshSceneMissionWaypointCaptureZones()
        refreshMissionStatus()
        recordMissionStateTransitions(
            previousExecutionState: previousExecutionState,
            previousSafetyState: previousSafetyState,
            previousSnapshot: previousSnapshot
        )
    }

    func abortMissionExecution() {
        guard missionExecutionState.canAbort else {
            refreshMissionStatus()
            return
        }

        let previousExecutionState = missionExecutionState
        let previousSafetyState = missionSafetyState
        let previousSnapshot = missionStatusSnapshot
        missionExecutionState = missionExecutionCoordinator.abort(
            state: missionExecutionState
        )
        enterMissionExecutionHold()
        missionRuntimeMonitor.reset()
        refreshMissionStatus()
        recordMissionStateTransitions(
            previousExecutionState: previousExecutionState,
            previousSafetyState: previousSafetyState,
            previousSnapshot: previousSnapshot
        )
    }

    func setMissionMapMode(_ mode: MissionMapMode) {
        missionMapMode = mode
    }

    func setMissionDraftRouteTarget(at planarPosition: SIMD2<Float>) {
        let marker = TargetMarkerState(position: clampedPlanarPosition(planarPosition))
        missionPlanningDraft.routeTarget = marker
    }

    func clearMissionDraftRoute() {
        missionPlanningDraft.routeTarget = nil
    }

    func setMissionDraftDropZoneCenter(at planarPosition: SIMD2<Float>) {
        let clampedCenter = clampedPlanarPosition(planarPosition)
        let radius = missionPlanningDraft.dropZone?.radius ?? 9.0
        missionPlanningDraft.dropZone = DropZoneState(center: clampedCenter, radius: radius)
    }

    func setMissionDraftDropZoneRadius(_ radius: Float) {
        guard var dropZone = missionPlanningDraft.dropZone else {
            return
        }
        dropZone.radius = max(1.0, min(radius, hardWorldBoundsRadius * 0.6))
        missionPlanningDraft.dropZone = dropZone
    }

    func clearMissionDraftDropZone() {
        missionPlanningDraft.dropZone = nil
    }

    func setMissionAutoReleaseEnabled(_ enabled: Bool) {
        missionPlanningDraft.autoReleaseEnabled = enabled
    }

    func confirmMissionPlan() {
        var nextPlan = missionPlanningDraft
        if nextPlan.routeTarget == nil, let dropZone = nextPlan.dropZone {
            nextPlan.routeTarget = TargetMarkerState(position: dropZone.center)
        }

        missionPlanState = nextPlan
        missionPlanningDraft = nextPlan
        sceneController.setMissionDropZone(nextPlan.dropZone)
        isMissionMapVisible = false
        isInMissionDropZone = missionPlanState.dropZone?.contains(currentPlanarPosition()) ?? false

        if let routeTarget = nextPlan.routeTarget {
            applyActiveRouteTarget(
                routeTarget,
                source: .manualMarker,
                startNavigationIfPossible: true
            )
        } else {
            applyActiveRouteTarget(
                nil,
                source: .none,
                startNavigationIfPossible: false
            )
        }

        hasUnsavedChanges = true
        refreshFlightControlDiagnostics()
    }

    func toggleCompassOverlay() {
        refreshCompassOverlay()
        isCompassVisible.toggle()
    }

    func setTargetMarker(at planarPosition: SIMD2<Float>) {
        guard !missionExecutionState.isMissionActive else {
            refreshMissionStatus()
            return
        }

        let marker = TargetMarkerState(position: clampedPlanarPosition(planarPosition))
        missionPlanState.routeTarget = marker
        if isMissionMapVisible {
            missionPlanningDraft.routeTarget = marker
        }
        applyActiveRouteTarget(
            marker,
            source: .manualMarker,
            startNavigationIfPossible: true
        )
        hasUnsavedChanges = true
    }

    func clearTargetMarker() {
        guard activeRouteTargetSource != .mission else {
            refreshMissionStatus()
            return
        }

        missionPlanState.routeTarget = nil
        if isMissionMapVisible {
            missionPlanningDraft.routeTarget = nil
        }
        applyActiveRouteTarget(
            nil,
            source: .none,
            startNavigationIfPossible: false
        )
        hasUnsavedChanges = true
    }

    func toggleToolPanel() {
        isToolPanelVisible.toggle()
    }

    func setToolPanelVisible(_ visible: Bool) {
        isToolPanelVisible = visible
    }

    // MARK: - Drone models

    func selectDroneModel(id: String) {
        guard canControlLocalVehicle else { return }
        let canonicalID = LIPODroneModelRepository.canonicalModelID(id)
        guard let profile = availableDroneProfiles.first(where: { $0.id == canonicalID }) else {
            return
        }

        selectedDroneProfile = profile
        activeUAVProfile = Self.resolveActiveUAVProfile(for: profile, abstractParameters: abstractParameters)
        sceneController.setDroneProfile(profile)
        resetPayloadForProfileSwitch()
        resetCameraConfigurationForSelectedProfile()
        normalizeMissionLaunchConfigurationForSelectedProfile()
        let didChangeTerrain = normalizeTerrainForSelectedDroneProfile()

        batteryState = .full
        reset()
        if didChangeTerrain {
            regenerateEnvironment()
        }
    }

    func applyAbstractParameters(_ parameters: AbstractDroneParameters) {
        abstractParameters = parameters
        let abstractProfile = LIPODroneModelRepository.abstractProfile(from: parameters)

        if let index = availableDroneProfiles.firstIndex(where: { $0.id == abstractProfile.id }) {
            availableDroneProfiles[index] = abstractProfile
        } else {
            availableDroneProfiles.append(abstractProfile)
        }

        if selectedDroneProfile.id == abstractProfile.id {
            selectDroneModel(id: abstractProfile.id)
        }

        logAvailableUAVCatalog(models: availableDroneProfiles)
    }

    var uavCatalogSelectionState: UAVSelectionState {
        UAVCatalog.selectionState(
            runtimeProfiles: availableDroneProfiles,
            selectedRuntimeProfileID: selectedDroneProfile.id,
            abstractParameters: abstractParameters,
            filterState: uavCatalogFilterState
        )
    }

    func setUAVVehicleTypeFilter(_ filter: UAVVehicleTypeFilter) {
        guard uavCatalogFilterState.vehicleType != filter else {
            return
        }
        uavCatalogFilterState.vehicleType = filter
    }

    func setUAVMassCategoryFilter(_ filter: UAVMassCategoryFilter) {
        guard uavCatalogFilterState.massCategory != filter else {
            return
        }
        uavCatalogFilterState.massCategory = filter
    }

    private func resetCameraConfigurationForSelectedProfile() {
        selectedCameraPreset = .pilot
        cameraConfiguration.applyPreset(.pilot)
        cameraConfiguration.fov = selectedDroneProfile.cameraPreset.fpvFov
        cameraConfiguration.follow.distance = selectedDroneProfile.cameraPreset.followDistance
        cameraConfiguration.follow.height = selectedDroneProfile.cameraPreset.followHeight
        cameraConfiguration.follow.lateralOffset = 0.0
        cameraConfiguration.orbit.distance = max(
            cameraConfiguration.orbit.minDistance,
            min(cameraConfiguration.orbit.maxDistance, selectedDroneProfile.cameraPreset.followDistance + 0.8)
        )
        cameraConfiguration.orbit.height = max(
            cameraConfiguration.orbit.minDistance * 0.5,
            min(cameraConfiguration.orbit.height, selectedDroneProfile.cameraPreset.followHeight + 0.6)
        )
        cameraConfiguration.top.forwardLead = 0.0
    }

    // MARK: - Camera

    func setCameraMode(_ mode: CameraMode) {
        if isSpectatorMode {
            guard mode == .spectator else { return }
        }

        let oldMode = cameraConfiguration.mode
        guard oldMode != mode else {
            refreshPayloadCameraStatus()
            return
        }

        cameraLookVelocity = .zero
        payloadGimbalLookVelocity = .zero

        if oldMode == .payload, mode != .payload {
            payloadCameraController.leavePayloadViewManually()
        }

        if mode == .payload {
            guard payloadCameraController.canActivatePayloadView() else {
                return
            }
            _ = payloadCameraController.activatePayloadView(from: oldMode)
            sceneController.setPayloadCameraFocusReleaseID(payloadCameraController.trackedReleaseID)
        } else if mode == .payloadOptics {
            guard payloadCameraOpticsState.isAvailable || rangefinderOpticsState.isAvailable || hoseOpticsState.isAvailable || capsuleState.isAvailable else {
                return
            }
        }

        fpvEnteredViaZoomEngage = false
        cameraConfiguration.mode = mode
        syncCameraSystem(from: oldMode)
        refreshPayloadCameraStatus()
    }

    func cycleCameraMode() {
        guard !isSpectatorMode else {
            return
        }

        let oldMode = cameraConfiguration.mode
        if oldMode == .payload {
            payloadCameraController.leavePayloadViewManually()
        }
        let nextMode = cameraConfiguration.mode.next()
        fpvEnteredViaZoomEngage = false
        cameraConfiguration.mode = nextMode
        syncCameraSystem(from: oldMode)
        refreshPayloadCameraStatus()
    }

    func setCameraPreset(_ preset: CameraPreset) {
        let previousMode = cameraConfiguration.mode
        if previousMode == .payload {
            payloadCameraController.leavePayloadViewManually()
        }
        selectedCameraPreset = preset
        fpvEnteredViaZoomEngage = false
        cameraConfiguration.applyPreset(preset)
        syncCameraSystem(from: previousMode, resetOrientation: true)
        refreshPayloadCameraStatus()
    }

    func resetCameraToPreset() {
        let previousMode = cameraConfiguration.mode
        if previousMode == .payload {
            payloadCameraController.leavePayloadViewManually()
        }
        fpvEnteredViaZoomEngage = false
        cameraConfiguration.applyPreset(selectedCameraPreset)
        syncCameraSystem(from: previousMode, resetOrientation: true)
        refreshPayloadCameraStatus()
    }

    func setCameraFov(_ value: Double) { cameraConfiguration.fov = Float(value) }
    func setCameraSensitivity(_ value: Double) { cameraConfiguration.sensitivity = Float(value) }
    func setCameraSmoothing(_ value: Double) { cameraConfiguration.smoothing = Float(value) }
    func setCameraInvertX(_ value: Bool) { cameraConfiguration.invertLookX = value }
    func setCameraInvertY(_ value: Bool) { cameraConfiguration.invertLookY = value }
    func setPayloadZoom(_ value: Double) {
        payloadCameraController.setZoom(value)
        publishPayloadCameraOpticsState()
    }

    func resetPayloadZoom() {
        payloadCameraController.setZoom(payloadCameraController.opticsState.minZoom)
        publishPayloadCameraOpticsState()
    }

    func setPayloadFocusDistance(_ value: Double) {
        payloadCameraController.setFocusDistance(value)
        publishPayloadCameraOpticsState()
    }

    func setPayloadStabilizationMode(_ mode: PayloadCameraStabilizationMode) {
        payloadCameraController.setStabilizationMode(mode)
        publishPayloadCameraOpticsState()
    }

    func adjustPayloadGimbal(yawDeltaDegrees: Double, pitchDeltaDegrees: Double) {
        payloadCameraController.adjustGimbal(
            yawDeltaDegrees: yawDeltaDegrees,
            pitchDeltaDegrees: pitchDeltaDegrees
        )
        publishPayloadCameraOpticsState()
    }

    func resetPayloadGimbalOrientation() {
        payloadCameraController.resetGimbalOrientation()
        publishPayloadCameraOpticsState()
    }

    func togglePayloadAutofocus() {
        payloadCameraController.setAutofocusEnabled(!payloadCameraController.opticsState.autofocusEnabled)
        publishPayloadCameraOpticsState()
    }

    func triggerPayloadAutofocusOnce() {
        let targetDistance = sceneController.payloadCameraTargetDistance(maxDistance: 500.0)
        payloadCameraController.updateTargetDistance(targetDistance)
        if let targetDistance {
            payloadCameraController.setFocusDistance(targetDistance)
        }
        publishPayloadCameraOpticsState()
    }

    func togglePayloadRecording() {
        payloadCameraController.toggleRecording()
        publishPayloadCameraOpticsState()
    }

    // MARK: - Laser rangefinder

    func setRangefinderArmed(_ enabled: Bool) {
        rangefinderController.setArmed(enabled)
        refreshRangefinderStatus()
    }

    func adjustRangefinderGimbal(yawDeltaDegrees: Double, pitchDeltaDegrees: Double) {
        rangefinderController.adjustGimbal(
            yawDeltaDegrees: yawDeltaDegrees,
            pitchDeltaDegrees: pitchDeltaDegrees
        )
        refreshRangefinderStatus()
    }

    func resetRangefinderGimbalOrientation() {
        rangefinderController.resetGimbalOrientation()
        refreshRangefinderStatus()
    }

    func setRangefinderZoom(_ value: Double) {
        rangefinderController.setZoom(value)
        refreshRangefinderStatus()
    }

    func resetRangefinderZoom() {
        rangefinderController.setZoom(rangefinderController.opticsState.minZoom)
        refreshRangefinderStatus()
    }

    func toggleRangefinderArmed() {
        setRangefinderArmed(!rangefinderOpticsState.isArmed)
    }

    // MARK: - Fire hose

    /// Spraying tracks the physical hold-state of the spray trigger key each tick (see
    /// `processInputActions`, which calls this every frame with `controlState.isHoseSprayHeld`) —
    /// a real hose sprays only while the trigger is held, not "press once to leave it running."
    func setHoseSpraying(_ enabled: Bool) {
        hoseController.setSpraying(enabled)
        refreshHoseAimStatus()
    }

    // MARK: - Agricultural sprayer

    /// Same physical trigger as the fire hose (`controlState.isHoseSprayHeld`) — whichever
    /// payload is actually mounted reacts, the other controller no-ops on its own availability
    /// guard, so no extra dispatch logic is needed at the call site.
    func setAgriculturalSprayerSpraying(_ enabled: Bool) {
        agriculturalSprayerController.setSpraying(enabled)
    }

    func adjustHoseGimbal(yawDeltaDegrees: Double, pitchDeltaDegrees: Double) {
        hoseController.adjustGimbal(
            yawDeltaDegrees: yawDeltaDegrees,
            pitchDeltaDegrees: pitchDeltaDegrees
        )
        refreshHoseAimStatus()
    }

    func resetHoseGimbalOrientation() {
        hoseController.resetGimbalOrientation()
        refreshHoseAimStatus()
    }

    // MARK: - Thermal camera

    /// Switch the payload camera between EO (`.optical`) and thermal (`.thermalStub`). Zoom /
    /// focus / autofocus / stabilization are preserved — only the sensor sub-mode changes.
    func setPayloadCameraMode(_ mode: PayloadCameraMode) {
        // `.nightStub` is still unimplemented — ignore taps on it.
        guard mode == .optical || mode == .thermalStub else { return }
        guard payloadCameraController.opticsState.mode != mode else { return }
        payloadCameraController.setPayloadCameraMode(mode)
        publishPayloadCameraOpticsState()
        payloadThermalState.isEnabled = mode == .thermalStub
        payloadThermalState.isAvailable = payloadCameraOpticsState.isAvailable
    }

    func setThermalPalette(_ palette: ThermalPalette) {
        guard payloadThermalState.palette != palette else { return }
        payloadThermalState.palette = palette
        sceneController.setThermalPalette(palette)
    }

    /// Quick-select shortcut: jumps straight to the thermal sensor (if available) and applies
    /// the requested palette in one keystroke, instead of requiring a manual mode switch first.
    func activateThermalPalette(_ palette: ThermalPalette) {
        guard isMountedThermalCapablePayload, payloadCameraOpticsState.isAvailable else { return }
        if payloadCameraController.opticsState.mode != .thermalStub {
            setPayloadCameraMode(.thermalStub)
        }
        setThermalPalette(palette)
    }

    func setThermalProfileSelection(_ selection: ThermalProfileSelection) {
        guard payloadThermalState.profileSelection != selection else { return }
        payloadThermalState.profileSelection = selection
        sceneController.setThermalProfileSelection(selection)
    }

    func setThermalContrast(_ value: Double) {
        payloadThermalState.contrast = min(1.8, max(0.4, value))
        sceneController.setThermalContrast(value)
    }

    func setThermalBrightness(_ value: Double) {
        payloadThermalState.brightness = min(0.3, max(-0.3, value))
        sceneController.setThermalBrightness(value)
    }

    func setThermalNoiseAmount(_ value: Double) {
        payloadThermalState.noiseAmount = min(1.0, max(0.0, value))
        sceneController.setThermalNoiseAmount(value)
    }

    func setThermalDiagnosticsVisible(_ visible: Bool) {
        guard payloadThermalState.showDiagnostics != visible else { return }
        payloadThermalState.showDiagnostics = visible
    }

    func toggleThermalDiagnostics() {
        payloadThermalState.showDiagnostics.toggle()
    }
    func setCameraSensitivityProfile(_ value: CameraSensitivityProfile) { cameraConfiguration.sensitivityProfile = value }
    func setOrbitDistance(_ value: Double) { cameraConfiguration.orbit.distance = Float(value).clamped(to: cameraConfiguration.orbit.minDistance...cameraConfiguration.orbit.maxDistance) }
    func setFollowOffsetX(_ value: Double) { cameraConfiguration.follow.lateralOffset = Float(value) }
    func setFollowOffsetY(_ value: Double) { cameraConfiguration.follow.height = Float(value) }
    func setFollowOffsetZ(_ value: Double) { cameraConfiguration.follow.distance = Float(value).clamped(to: cameraConfiguration.follow.minDistance...cameraConfiguration.follow.maxDistance) }
    func setFPVStabilization(_ value: Double) { cameraConfiguration.fpv.stabilization = Float(value).clamped(to: 0.0...1.0) }
    func setFPVShake(_ value: Double) { cameraConfiguration.fpv.shake = Float(value).clamped(to: 0.0...0.4) }
    func setFPVYawLimit(_ value: Double) { cameraConfiguration.fpv.yawLimitDeg = Float(value).clamped(to: 2.0...60.0) }
    func setFPVPitchLimit(_ value: Double) { cameraConfiguration.fpv.pitchLimitDeg = Float(value).clamped(to: 2.0...45.0) }
    func setFPVNearClip(_ value: Double) { cameraConfiguration.fpv.nearClip = Float(value).clamped(to: 0.005...0.25) }
    func setFPVMountOffsetX(_ value: Double) { cameraConfiguration.fpv.mountOffset.x = Float(value) }
    func setFPVMountOffsetY(_ value: Double) { cameraConfiguration.fpv.mountOffset.y = Float(value) }
    func setFPVMountOffsetZ(_ value: Double) { cameraConfiguration.fpv.mountOffset.z = Float(value) }
    func setFPVHideObstructions(_ value: Bool) { cameraConfiguration.fpv.hideObstructingParts = value }
    func setFreeCameraMoveSpeed(_ value: Double) { cameraConfiguration.free.moveSpeed = Float(value).clamped(to: 0.5...16.0) }
    func setCameraZoomSensitivity(_ value: Double) { cameraConfiguration.free.zoomSensitivity = Float(value).clamped(to: 0.2...3.0) }

    func setFlightControlMode(_ mode: FlightControlMode) {
        flightControlMode = mode
    }

    func rebindKey(_ command: KeyboardCommand, keyCode: UInt16, keyLabel: String) {
        bindingsViewModel.beginCapture(for: command)
        bindingsViewModel.rebindCurrentCommand(keyCode: keyCode, keyLabel: keyLabel)
        refreshKeyBindingDiagnostics()
    }

    func resetKeyBindingsToDefault() {
        bindingsViewModel.resetToDefaults()
        refreshKeyBindingDiagnostics()
    }

    func beginKeyBindingCapture() {
        setBindingsPanelVisible(true)
    }

    func endKeyBindingCapture() {
        bindingsViewModel.endCapture()
    }

    func setBindingsPanelVisible(_ visible: Bool) {
        guard bindingsViewModel.isPresented != visible else {
            return
        }

        if visible {
            bindingsViewModel.present()
            setControllerHubVisible(false)
            controllerUIBridge.clearSurfaceTargets("simulation-workspace")
        } else {
            bindingsViewModel.dismiss()
            controllerUIBridge.clearSurfaceTargets("keybindings-sheet")
            controllerUIBridge.invalidateSurfaceLayout("simulation-workspace", resetCursor: true)
        }

        setExternalControllerOverlayActive(visible)
    }

    func setExternalControllerOverlayActive(_ active: Bool) {
        guard externalControllerOverlayActive != active else {
            return
        }

        externalControllerOverlayActive = active
        if active, isControllerHubVisible {
            isControllerHubVisible = false
        }
        syncControllerInteractionMode()
    }

    func toggleControllerCursor() {
        guard inputManager.isSourceConnected(.gameController) else {
            return
        }

        isControllerCursorEnabled.toggle()
        syncControllerInteractionMode()
    }

    func setControllerCursorEnabled(_ enabled: Bool) {
        guard isControllerCursorEnabled != enabled else {
            return
        }

        isControllerCursorEnabled = enabled
        syncControllerInteractionMode()
    }

    func toggleControllerHub() {
        guard !externalControllerOverlayActive else {
            return
        }

        setControllerHubVisible(!isControllerHubVisible)
    }

    func setControllerHubVisible(_ visible: Bool) {
        guard isControllerHubVisible != visible else {
            return
        }

        if visible {
            controllerUIBridge.cancelTextInput()
        }

        isControllerHubVisible = visible
        syncControllerInteractionMode()
    }

    func cycleControllerHubSection(step: Int) {
        let sections = ControllerHubSection.allCases
        guard let currentIndex = sections.firstIndex(of: controllerHubSection), !sections.isEmpty else {
            return
        }

        let nextIndex = (currentIndex + step).positiveModulo(sections.count)
        controllerHubSection = sections[nextIndex]
    }

    func handleControllerUICancel() {
        if bindingsViewModel.isPresented {
            setBindingsPanelVisible(false)
            return
        }

        if isControllerHubVisible {
            setControllerHubVisible(false)
            return
        }

        if controllerUIBridge.isTextInputPresented {
            controllerUIBridge.cancelTextInput()
            return
        }

        if isMissionMapVisible {
            exitMissionMap()
            return
        }

        if isPayloadPanelVisible {
            setPayloadPanelVisible(false)
            return
        }

        if isCommsLinkPanelVisible {
            setCommsLinkPanelVisible(false)
            return
        }

        if isParametersPanelVisible {
            setControlPanelVisible(false)
        }
    }

    func setGameControllerRightStickHorizontalMode(_ mode: GameControllerRightStickHorizontalMode) {
        gameControllerInputProvider.setRightStickHorizontalMode(mode)
        refreshGameControllerPresentation(force: true)
    }

    func handlePointerLook(deltaX: Float, deltaY: Float) {
        noteUserInteraction()
        if isSpectatorMode {
            sceneController.applySpectatorLook(
                yawDeltaDeg: deltaX * 0.08 * cameraConfiguration.effectiveLookSensitivity,
                pitchDeltaDeg: deltaY * 0.08 * cameraConfiguration.effectiveLookSensitivity,
                invertX: cameraConfiguration.invertLookX,
                invertY: cameraConfiguration.invertLookY
            )
            return
        }

        if isHandLaunchPOVActive, !signalState.isInteractionBlocking {
            sceneController.applyHandLaunchPOVLook(
                yawDeltaDeg: deltaX * 0.08 * cameraConfiguration.effectiveLookSensitivity,
                pitchDeltaDeg: deltaY * 0.08 * cameraConfiguration.effectiveLookSensitivity,
                invertX: cameraConfiguration.invertLookX,
                invertY: cameraConfiguration.invertLookY
            )
            return
        }

        guard cameraConfiguration.mode == .fpv, !signalState.isInteractionBlocking else {
            return
        }
        sceneController.applyCameraNudge(
            mode: cameraConfiguration.mode,
            yawDeltaDeg: deltaX * 0.08 * cameraConfiguration.effectiveLookSensitivity,
            pitchDeltaDeg: deltaY * 0.08 * cameraConfiguration.effectiveLookSensitivity,
            invertX: cameraConfiguration.invertLookX,
            invertY: cameraConfiguration.invertLookY
        )
    }

    func handleSceneRenderFrame(atTime time: TimeInterval, cameraMode: CameraMode) {
        diagRenderFrameCount += 1
        sceneController.updatePayloadCameraForRenderFrame(
            atTime: time,
            isActive: cameraMode == .payload
        )

        // `SCNSceneRendererDelegate.renderer(_:updateAtTime:)` (this method's caller) is
        // documented to run on SceneKit's own rendering thread, not necessarily the main thread.
        // The thermal path below does AppKit drawing (NSImage.lockFocus / NSBezierPath / NSGradient
        // in ThermalVariationTexture) and mutates @Published state — both require the main thread;
        // calling lockFocus() off-main is a known hang/deadlock hazard. Hop explicitly rather than
        // assume the caller's thread.
        guard cameraMode == .payloadOptics else { return }

        // This callback fires at the display's actual render rate (up to 60-120/sec), not the
        // simulation tick rate — a fresh `Task { @MainActor ... }` every single frame has real
        // per-call scheduling/allocation overhead, paid continuously for the entire time ANY
        // payload-optics view (camera/rangefinder/hose) is active, independent of whether thermal
        // is even engaged (the check for that happens only after the hop, since it needs
        // `self.payloadCameraOpticsState` which isn't safe to read off the main actor). Thermal
        // has no real need for per-frame granularity here anyway — its own diagnostics refresh
        // below is already throttled to ~8Hz — so the hop itself is throttled to roughly that same
        // cadence instead of firing every frame. Found while investigating reported lag specific
        // to payload-optics view (not the fire-response scene itself, already checked separately).
        guard time - lastThermalRenderFrameHop >= 0.05 else { return }
        lastThermalRenderFrameHop = time

        Task { @MainActor [weak self] in
            self?.updateThermalForRenderFrame(atTime: time, cameraMode: cameraMode)
        }
    }

    private func updateThermalForRenderFrame(atTime time: TimeInterval, cameraMode: CameraMode) {
        let wantsThermal = cameraMode == .payloadOptics
            && payloadCameraOpticsState.mode == .thermalStub
            && payloadCameraOpticsState.isAvailable
        sceneController.updateThermalPresentation(active: wantsThermal)

        guard wantsThermal else { return }

        // Diagnostics @ ~8 Hz, only mutating @Published when the snapshot actually changes.
        if time - lastThermalDiagnosticsUpdate >= 0.12 {
            lastThermalDiagnosticsUpdate = time
            let diagnostics = sceneController.thermalDiagnostics(
                includeCenterProbe: payloadThermalState.showDiagnostics
            )
            let resolved = sceneController.resolvedThermalProfile()
            if diagnostics != payloadThermalState.diagnostics
                || resolved != payloadThermalState.resolvedProfile {
                payloadThermalState.diagnostics = diagnostics
                payloadThermalState.resolvedProfile = resolved
            }
        }
    }

    func setActiveCameraDistance(_ value: Double) {
        cameraConfiguration.setCameraDistance(Float(value))
    }

    func toggleCompactTelemetryHUD() {
        isCompactTelemetryHUDEnabled.toggle()
    }

    func setPayloadCameraAutoSwitchEnabled(_ enabled: Bool) {
        guard isPayloadCameraAutoSwitchEnabled != enabled else {
            return
        }
        isPayloadCameraAutoSwitchEnabled = enabled
        payloadCameraController.setAutoSwitchAfterRelease(enabled)
    }

    var supportsDistanceControl: Bool {
        cameraConfiguration.mode != .fpv &&
            cameraConfiguration.mode != .payloadOptics &&
            cameraConfiguration.mode != .payload &&
            cameraConfiguration.mode != .spectator
    }

    var activeCameraDistance: Double {
        Double(cameraConfiguration.cameraDistance)
    }

    var activeCameraDistanceRange: ClosedRange<Double> {
        switch cameraConfiguration.mode {
        case .free:
            return Double(cameraConfiguration.free.minDistance)...Double(cameraConfiguration.free.maxDistance)
        case .follow:
            return Double(cameraConfiguration.follow.minDistance)...Double(cameraConfiguration.follow.maxDistance)
        case .orbit:
            return Double(cameraConfiguration.orbit.minDistance)...Double(cameraConfiguration.orbit.maxDistance)
        case .top:
            return Double(cameraConfiguration.top.minHeight)...Double(cameraConfiguration.top.maxHeight)
        case .fpv:
            return 0.0...0.0
        case .payloadOptics:
            return 0.0...0.0
        case .payload:
            return 0.0...0.0
        case .spectator:
            return 0.0...0.0
        }
    }

    // MARK: - Weather and terrain

    func setWeatherPreset(_ preset: WeatherPreset) {
        weather.preset = preset
        if preset == .normal {
            weather.intensity = 0.0
            weather.windSpeedMps = 0.0
            weather.gusts = 0.0
        }
    }

    func setWeatherIntensity(_ value: Double) { weather.intensity = Float(value) }
    func setWindDirection(_ value: Double) { weather.windDirectionDeg = Float(value) }
    func setWindSpeed(_ value: Double) { weather.windSpeedMps = Float(value) }
    func setWindGusts(_ value: Double) { weather.gusts = Float(value) }

    /// Adopts an imported photogrammetric world as the flight environment.
    ///
    /// Called once, before the session becomes active. The procedural terrain still exists
    /// underneath — the preset is forced to the cheapest one so `ScenePopulationService` does not
    /// spend its budget scattering trees inside a real city that will hide them anyway, while the
    /// terrain configuration keeps supplying map scale, weather and the other session settings
    /// that are not the ground itself.
    /// Smallest map scale whose boundary encloses an imported tile, so the geofence never fires on
    /// ground the aircraft is meant to be flying over. Falls back to the largest available.
    private static func mapScale(
        covering bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)
    ) -> MapScale {
        let reach = max(
            max(abs(bounds.minimum.x), abs(bounds.maximum.x)),
            max(abs(bounds.minimum.z), abs(bounds.maximum.z))
        )
        return MapScale.allCases.first { $0.worldHalfExtentMeters >= reach }
            ?? MapScale.allCases[MapScale.allCases.count - 1]
    }

    /// Set once a world is attached, and written into every subsequent save so reopening the
    /// project restores the same city rather than dropping the pilot onto the procedural grid the
    /// preset was forced to.
    private(set) var attachedMeshWorld: ProjectSnapshot.MeshWorld?

    /// Read by the shell after `loadProject` to decide whether a world still has to be loaded.
    var meshWorldToRestore: ProjectSnapshot.MeshWorld? { attachedMeshWorld }

    func attachMeshWorld(_ runtime: MeshWorldRuntime, sourceIdentifier: String) {
        attachedMeshWorld = ProjectSnapshot.MeshWorld(
            sourceIdentifier: sourceIdentifier,
            tileKey: runtime.report.tileKey
        )
        terrain.preset = .gridDemo
        terrain.density = 0.0
        // The world has to be at least as big as the world.
        //
        // Map scale still drives the boundary geofence, and the procedural default is far smaller
        // than an imported tile: x4 gives a half-extent of 200 m and x8 gives 400 m, while this
        // tile reaches beyond 1000 m and its own chosen start point sits 424 m from the origin.
        // The aircraft therefore spawned *outside* the world and the geofence did exactly its job —
        // carrying it off, disarming it and leaving it in the sea. That reads as "the aircraft moved
        // by itself", and no amount of work on terrain height or water could have fixed it.
        terrain.mapScale = Self.mapScale(covering: runtime.report.bounds)
        sceneController.installMeshWorld(runtime)
        isAwaitingImportedWorld = false

        // Start on a real surface rather than at the origin, which in a photogrammetric tile is
        // as likely to be open water or a rooftop as an apron.
        if let spawn = runtime.spawnPoint {
            state.position = SIMD3<Float>(spawn.x, spawn.y, spawn.z)
            lastFiniteState = state
            let geo = runtime.origin.geographic(ofLocalPosition: spawn)
            #if DEBUG
            print("[MeshWorld] spawn at \(geo.displayString), "
                  + String(format: "%.1f m MSL", geo.altitudeMetersMSL))
            #endif
        }

        scheduleTerrainRegeneration(resetAfter: false)
    }

    func setTerrainPreset(_ preset: TerrainPreset) {
        let compatiblePreset = preset.compatiblePreset(for: selectedDroneProfile.airframeClass)
        terrain.preset = compatiblePreset
        terrain.density = compatiblePreset.defaultDensity
        terrain.safeSpawnRadius = recommendedSafeSpawnRadius(for: terrain.mapScale)
        scheduleTerrainRegeneration(resetAfter: false)
    }

    @discardableResult
    private func normalizeTerrainForSelectedDroneProfile() -> Bool {
        let compatiblePreset = terrain.preset.compatiblePreset(for: selectedDroneProfile.airframeClass)
        guard compatiblePreset != terrain.preset else {
            return false
        }

        terrain.preset = compatiblePreset
        terrain.density = compatiblePreset.defaultDensity
        terrain.safeSpawnRadius = recommendedSafeSpawnRadius(for: terrain.mapScale)
        return true
    }

    func setTerrainMapScale(_ scale: MapScale) {
        guard terrain.mapScale != scale else {
            return
        }
        terrain.mapScale = scale
        terrain.safeSpawnRadius = recommendedSafeSpawnRadius(for: scale)
        scheduleTerrainRegeneration(resetAfter: true)
    }

    func setTerrainDensity(_ value: Double) {
        let clampedValue = Float(value).clamped(to: 0.0...1.0)
        guard abs(terrain.density - clampedValue) > 0.0001 else {
            return
        }
        terrain.density = clampedValue
        if !isTerrainDensitySliderEditing {
            scheduleTerrainRegeneration(resetAfter: false, delayNanoseconds: 180_000_000)
        }
    }

    func setTerrainSeed(_ value: UInt64) {
        terrain.seed = value
        scheduleTerrainRegeneration(resetAfter: false)
    }

    func commitTerrainDensityChange() {
        cancelPendingTerrainDensityRegeneration()
        regenerateEnvironment()
    }

    func setTerrainDensityEditing(_ editing: Bool) {
        isTerrainDensitySliderEditing = editing
    }

    // MARK: - Diagnostics

    func setDiagnosticMode(_ mode: DiagnosticOverlayMode) {
        diagnosticMode = mode
    }

    func toggleThermalOverlay() {
        diagnosticMode = diagnosticMode == .thermal ? .normal : .thermal
    }

    func toggleDamageOverlay() {
        diagnosticMode = diagnosticMode == .damage ? .normal : .damage
    }

    func setComponentHidden(_ component: DamageComponent, hidden: Bool) {
        damageState = damageState.withHidden(component, hidden: hidden)
    }

    func selectComponent(_ component: DamageComponent?) {
        damageState = damageState.withSelected(component)
    }

    func resetDamageState() {
        damageState = .pristine
        rebuildVehicleComponentGraph()
        thermalState = .nominal
        diagnosticMode = .normal
    }

    // MARK: - Fleet

    func toggleFleetEnabled() {
        fleetStatus.enabled.toggle()
        if !fleetStatus.enabled {
            fleetStatus.mode = .off
            fleetInterDroneRisk = 0.0
            fleetNearestInterDroneDistance = .infinity
            wingmen.removeAll()
            sceneController.updateFleetWingmen([], profile: selectedDroneProfile, throttle: state.throttle, deltaTime: 0.0)
        } else if fleetStatus.mode == .off {
            fleetStatus.mode = .line
        }
    }

    func setFormationMode(_ mode: FormationMode) { fleetStatus.mode = mode }
    func setSeparationDistance(_ value: Double) { fleetStatus.separationDistance = Float(value) }

    func setFleetWingmanCount(_ value: Int) {
        fleetStatus.wingmanCount = max(1, min(value, 5))
        if wingmen.count > fleetStatus.wingmanCount {
            wingmen = Array(wingmen.prefix(fleetStatus.wingmanCount))
        }
    }

    // MARK: - Battery and telemetry

    func chargeDroneAndContinue() {
        batteryState.chargePercent = 100
        showBatteryDepletedDialog = false
        setFlightMode(.hover, reason: "battery_recovery_hover")
        lockControlsToCurrentState(overrideThrottle: Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle))
    }

    /// Battery thermal-runaway/rupture: visual consequence only (flame + smoke, instant power
    /// loss) — no secondary component damage, matching a fire that starts *because* the pack
    /// failed rather than one more structural failure of its own. Idempotent: a second trigger
    /// while already on fire is a no-op, so the impact path and the per-tick overheat/discharge
    /// checks can both call this without double-igniting.
    private func igniteBatteryFireIfNeeded(reason: String) {
        guard !batteryFireActive, componentGraph.component(id: "battery") != nil else { return }
        batteryFireActive = true
        batteryFireIgnitedAtSimulationTime = TimeInterval(simulationTime)
        // Otherwise this would still read >= batteryOverheatDurationSec on the very next check
        // once the fire's own timeline clears batteryFireActive, re-igniting it immediately.
        sustainedMaxThrottleSeconds = 0.0
        batteryState.chargePercent = 0.0
        damageEventRecorder.record(
            timestamp: TimeInterval(simulationTime),
            type: .subsystemFailed,
            componentID: "battery",
            reason: reason
        )
    }

    /// Per-tick ignition check plus the flame → smoke-tail → out timeline once burning.
    ///
    /// Overheat trigger: holding throttle at (near) 100% continuously for
    /// `batteryOverheatDurationSec` — eases off the instant the operator lets go, by design (a
    /// pilot who backs off periodically is managing the pack, not abusing it). At that point the
    /// pack is asked to sustain its computed "critical" continuous current — capacity x a generic
    /// hobby-LiPo C-rating — and real packs can't do that indefinitely without heat damage.
    /// Requiring *both* the duration and the current actually being at/above that critical level
    /// (rather than duration alone) means a already-weakened/damaged pack, which draws more
    /// current for the same throttle, can cross it sooner — consequence compounds on prior damage.
    /// The over-discharge leg specifically wants continued *load* on an empty pack (a paperweight
    /// sitting at 0% on the ground is not the failure mode) — mirrors `BatteryState.isDepleted`'s
    /// 0.1% floor.
    private func updateBatteryFireState(deltaTime: Float) {
        if !batteryFireActive {
            if isArmed, state.throttle >= Self.batteryOverheatThrottleThreshold {
                sustainedMaxThrottleSeconds += deltaTime
            } else {
                sustainedMaxThrottleSeconds = 0.0
            }

            let criticalContinuousCurrentA = (selectedDroneProfile.batteryCapacitymAh / 1000.0) *
                Self.batteryContinuousDischargeCRating
            let isDrawingCriticalCurrent = batteryState.currentDrawA >= criticalContinuousCurrentA * 0.9

            if sustainedMaxThrottleSeconds >= Self.batteryOverheatDurationSec, isDrawingCriticalCurrent {
                igniteBatteryFireIfNeeded(reason: "battery_sustained_overcurrent")
            } else if batteryState.chargePercent <= 0.1, batteryState.powerDrawW > 5.0 {
                igniteBatteryFireIfNeeded(reason: "battery_over_discharge")
            }
        }

        guard batteryFireActive, let ignitedAt = batteryFireIgnitedAtSimulationTime else {
            return
        }
        let elapsed = Float(TimeInterval(simulationTime) - ignitedAt)
        let flameActive = elapsed < Self.batteryFireFlameDurationSec
        let smokeActive = elapsed < Self.batteryFireFlameDurationSec + Self.batteryFireSmokeTailDurationSec
        sceneController.updateBatteryFireVisual(
            flameActive: flameActive,
            smokeActive: smokeActive,
            localPosition: componentGraph.component(id: "battery")?.localPosition ?? .zero
        )
        if !flameActive, !smokeActive {
            batteryFireActive = false
            batteryFireIgnitedAtSimulationTime = nil
        }
    }

    func simulateAgainFromStart() {
        showBatteryDepletedDialog = false
        reset()
    }

    func exportTelemetry() {
        let metadata = buildTelemetryMetadata()

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "telemetry.export.select_folder")
        panel.prompt = String(localized: "common.export")

        guard panel.runModal() == .OK else {
            return
        }

        switch telemetryExporter.exportNow(metadata: metadata, destinationDirectory: panel.url) {
        case let .success(url):
            telemetryExportAlert = TelemetryExportAlert(
                titleKey: "telemetry.export.success",
                message: url.path
            )
        case let .failure(error):
            telemetryExportAlert = TelemetryExportAlert(
                titleKey: "telemetry.export.failure",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Project persistence

    func assignProjectContext(id: String, name: String) {
        currentProjectID = id
        currentProjectName = name
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentProjectName = trimmed
        hasUnsavedChanges = true
    }

    func saveProject() -> Result<ProjectRecordSummary, Error> {
        let snapshot = buildProjectSnapshot()
        do {
            let saved = try projectStorage.saveProject(
                id: currentProjectID,
                name: currentProjectName,
                snapshot: snapshot
            )
            hasUnsavedChanges = false
            currentProjectID = saved.id
            currentProjectName = saved.name

            _ = telemetryExporter.persistInternalSession(metadata: buildTelemetryMetadata())
            return .success(saved)
        } catch {
            return .failure(error)
        }
    }

    func saveProjectAs(name: String) -> Result<ProjectRecordSummary, Error> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ProjectStorageError.writeFailed)
        }
        currentProjectID = projectStorage.createProjectID()
        currentProjectName = trimmed
        return saveProject()
    }

    func loadProject(id: String) -> Result<ProjectRecordSummary, Error> {
        do {
            let snapshot = try projectStorage.loadProject(id: id)
            applyProjectSnapshot(snapshot)
            currentProjectID = snapshot.projectID
            currentProjectName = snapshot.projectName
            hasUnsavedChanges = false

            let summary = projectStorage.listProjects().first(where: { $0.id == id }) ??
                ProjectRecordSummary(
                    id: snapshot.projectID,
                    name: snapshot.projectName,
                    createdAt: snapshot.savedAt,
                    modifiedAt: snapshot.savedAt,
                    lastOpenedAt: snapshot.savedAt,
                    lastSavedAt: snapshot.savedAt
                )
            return .success(summary)
        } catch {
            return .failure(error)
        }
    }

    func duplicateCurrentProject(newName: String) -> Result<ProjectRecordSummary, Error> {
        do {
            let duplicated = try projectStorage.duplicateProject(id: currentProjectID, newName: newName)
            return .success(duplicated)
        } catch {
            return .failure(error)
        }
    }

    func deleteCurrentProject() -> Result<Void, Error> {
        do {
            try projectStorage.deleteProject(id: currentProjectID)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func performAutosaveIfNeeded() {
        let snapshot = buildProjectSnapshot()
        try? projectStorage.autosave(projectID: currentProjectID, snapshot: snapshot)
    }

    private func refreshKeyBindingDiagnostics() {
        bindingsViewModel.refresh()
        keyBindingSections = bindingsViewModel.sections
        keyBindingConflicts = bindingsViewModel.conflicts
    }

    private func regenerateEnvironment() {
        clearMissionPlan()
        cancelPendingTerrainDensityRegeneration()
        clearTargetMarker()
        autoPathPlanner.invalidate()
        navigationSnapshot = .idle
        autoFlightGoal = nil
        autoFlightGoalIndex = 0
        if mode == .returnHome {
            returnHomeStage = .ascend
        }
        sceneController.regenerateEnvironment(terrain)
        sceneController.setWorldBoundsVisible(isBoundaryBarrierVisible)
        refreshSceneLaunchAsset()
        homePosition = currentSpawnPoint()
        enforceRuntimeSafetyAndBounds(context: "regenerate_environment")
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        resetTerrainMapTrail()
        refreshTerrainMapSnapshot(recordTrail: false)
    }

    private func scheduleTerrainRegeneration(
        resetAfter: Bool,
        delayNanoseconds: UInt64 = 90_000_000
    ) {
        let requiresReset = pendingTerrainRegenerationRequiresReset || resetAfter
        cancelPendingTerrainDensityRegeneration()
        pendingTerrainRegenerationRequiresReset = requiresReset
        pendingTerrainRegenerationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else {
                return
            }
            self.commitPendingTerrainDensityRegeneration()
        }
    }

    private func cancelPendingTerrainDensityRegeneration() {
        pendingTerrainRegenerationTask?.cancel()
        pendingTerrainRegenerationTask = nil
        pendingTerrainRegenerationRequiresReset = false
    }

    private func commitPendingTerrainDensityRegeneration() {
        let requiresReset = pendingTerrainRegenerationRequiresReset
        pendingTerrainRegenerationTask = nil
        pendingTerrainRegenerationRequiresReset = false
        regenerateEnvironment()
        if requiresReset {
            reset()
        }
    }

    private func startSimulationLoop() {
        simulationTimer?.invalidate()
        simulationTimer = Timer(timeInterval: Self.simulationTickInterval, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        simulationTimer?.tolerance = Self.simulationTickInterval * 0.08

        if let simulationTimer {
            RunLoop.main.add(simulationTimer, forMode: .common)
        }
    }

    // MARK: - Mission scenario (SAR)

    var hasMissionScenario: Bool { missionScenarioConfiguration != nil }

    var activeMissionScenarioKind: MissionScenarioKind? {
        missionScenarioConfiguration?.parameters.kind
    }

    /// One-time setup when the view model was launched with a mission scenario: applies the
    /// environment (terrain/weather/time-of-day), installs the payload, then spawns the scenario
    /// and starts the runtime. Runs on the first tick so the scene graph is fully constructed.
    private func bootstrapMissionScenarioIfNeeded() {
        guard !didBootstrapMissionScenario, let config = missionScenarioConfiguration else { return }
        didBootstrapMissionScenario = true

        let params = config.parameters
        setTerrainPreset(params.terrain)
        // Search missions need real cover to search through — the terrain preset's generic
        // default density (0.72 for forest) reads too sparse for "the target could be behind any
        // of these trees" to feel true. Player picks the density preset in MissionSetupView
        // (MissionTerrainDensity); the small mission boost on top (see
        // TerrainConfiguration.missionDensityBoost) is now just a safety margin, not the main
        // lever — most of the visible density now comes from concentrating generation around the
        // search sector (see ScenePopulationService.generateForest's sector-bias split) rather
        // than from maxing out density/cap multipliers across the whole map.
        terrain.missionDensityBoost = true
        setTerrainDensity(Double(params.terrainDensity.densityValue))
        // Object count is capped at a fixed pool regardless of map size (see
        // ScenePopulationService.maxCollidableObjectCount, a collision/pathfinding performance
        // ceiling) — so density alone barely helps if the map is much bigger than the search
        // sector; that fixed pool just spreads thinner. Shrink the map to fit the sector instead,
        // which makes the same tree count read as a real forest. Mutating mapScale directly
        // (rather than calling setTerrainMapScale) skips its resetAfter:true, which would wipe
        // the drone back to spawn mid-bootstrap.
        //
        // `MissionDifficulty.recommendedMapScale` shrinks easy/medium down to `.x8` — right for
        // SAR (a smaller search sector should feel like a smaller, tighter search), but this same
        // fixed-pool-cap-regardless-of-map-size mechanic backfires for Fire Response: confirmed via
        // a user's Debug log + testing that easy/medium's `.x8` map crams roughly the same ambient
        // tree count into 1/4 the area of hard's `.x16`, so easy/medium missions were the *more*
        // GPU-taxed ones, backwards from what difficulty would suggest. Fire Response's own
        // difficulty scaling already lives in fireZoneRadiusMeters/fireTreeCount/spread rate, not
        // overall map size, so it always gets the larger `.x16` regardless of difficulty instead of
        // inheriting SAR's shrink-for-easier-difficulty logic.
        // A difficulty/mission-kind baseline is a floor, not a ceiling. Two separate reasons a
        // fixed-wing aircraft needs more room than that baseline:
        //  1. A large/long-range airframe (e.g. the MQ-9B SkyGuardian, 24 m wingspan) needs more
        //     maneuvering room in general — `DroneModelProfile.preferredMapScaleMin` already
        //     computes exactly this per aircraft (turn radius/maneuver comfort, used elsewhere for
        //     free-flight map selection).
        //  2. Confirmed via user testing: even a merely medium airframe (FT5 Łoś) that does NOT
        //     trip `preferredMapScaleMin` still flew clean past the world boundary — signal-loss
        //     locks flight controls entirely (see `signal_loss.lost_message`), and unlike a
        //     multirotor a fixed-wing can't just stop and hover to avoid it. It can't loiter in
        //     place while working a mission's target cluster; every attack pass needs a wide
        //     banking turn to reposition, and that turn's radius alone can exceed a "just barely
        //     big enough" map's margin even when nothing about the airframe looks oversized on
        //     paper. So ANY fixed-wing gets a flat floor here, not just ones flagged by
        //     `preferredMapScaleMin`.
        let fixedWingFloor: MapScale = (
            selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL
        ) ? .x32 : .x4
        let missionKindBaseline = params.kind == .fireResponse ? MapScale.x16 : params.difficulty.recommendedMapScale
        let aircraftMinScale = selectedDroneProfile.operationalProfile.preferredMapScaleMin
        let recommendedScale = [missionKindBaseline, aircraftMinScale, fixedWingFloor]
            .max { $0.numericPreset < $1.numericPreset }!
        if terrain.mapScale != recommendedScale {
            terrain.mapScale = recommendedScale
            terrain.safeSpawnRadius = recommendedSafeSpawnRadius(for: recommendedScale)
            scheduleTerrainRegeneration(resetAfter: false)
        }
        setWeatherPreset(params.weather)
        setWeatherIntensity(Double(params.weatherIntensity))
        sceneController.applyMissionTimeOfDay(params.timeOfDay)

        setPayloadType(config.payloadType)
        if config.payloadType == .fireHose {
            setFireHoseRigging(
                diameterClass: config.fireHoseDiameterClass,
                lengthMeters: Double(config.fireHoseLengthMeters)
            )
        } else if config.payloadType == .fireCapsuleLauncher {
            setFireCapsuleRigging(
                size: config.fireCapsuleSize,
                count: config.fireCapsuleCount
            )
        }
        attachPayload()

        let dock = sceneController.currentDockSpawnPoint()
        // Concentrate forest generation around the sector/zone instead of the whole map — set
        // before the still-pending debounced regen (scheduled above) fires, so this terrain
        // mutation rides along with the others into the same regeneration pass.
        switch params.kind {
        case .searchAndRescue:
            let placement = MissionScenarioPlacement.generate(
                parameters: params,
                worldHalfExtent: terrain.worldHalfExtent,
                dockPosition: SIMD2<Float>(dock.x, dock.z)
            )
            terrain.missionSearchSectorCenter = placement.sectorCenter
            terrain.missionSearchSectorRadius = placement.sectorRadius
            let target = sceneController.spawnMissionSearchScenario(placement: placement)
            missionScenarioTargetWorldPosition = target
            missionScenarioRuntime = MissionScenarioRuntime(configuration: config, placement: placement)
            publishMissionScenarioState()
        case .fireResponse:
            // Only the hose has a real physical tether to the truck. The capsule launcher has no
            // such hard constraint, but it still needs a real, difficulty-scaled "operational
            // reach" here — a recharge system depends on the truck sitting a meaningful (and
            // harder-scaling) distance from the fire, so a fallback to the world's own half-extent
            // would place the truck absurdly far away regardless of difficulty. Any other payload
            // (no tether, no recharge logistics) still falls back to the unconstrained half-extent.
            let riggedTetherLength: Float
            switch config.payloadType {
            case .fireHose:
                riggedTetherLength = config.fireHoseLengthMeters
            case .fireCapsuleLauncher:
                riggedTetherLength = FireCapsuleTuning.truckOperationalReachMeters(for: params.difficulty)
            default:
                riggedTetherLength = terrain.worldHalfExtent
            }
            let placement = FireZonePlacement.generate(
                parameters: params,
                worldHalfExtent: terrain.worldHalfExtent,
                dockPosition: SIMD2<Float>(dock.x, dock.z),
                tetherLengthMeters: riggedTetherLength
            )
            // Deliberately NOT setting terrain.missionSearchSectorCenter/Radius here (unlike SAR):
            // ScenePopulationService's sector-bias concentrates a near-fixed ambient-forest object
            // budget (~26 clusters × 12-24 trees each) into that radius regardless of how small it
            // is — fine for SAR's 90-320m search sectors, but the hose-tether-derived fire zone
            // can be a small fraction of that (as low as a few meters for a short narrow hose),
            // which crammed hundreds of overlapping ambient trees on top of the dedicated fire
            // trees. The fire zone already gets its own dense, guaranteed tree population from
            // `spawnFireResponseScenario`; the ambient forest doesn't need to also pile in.
            sceneController.spawnFireResponseScenario(placement: placement)
            fireResponseRuntime = FireResponseRuntime(configuration: config, placement: placement)
            publishFireResponseState()
        }
    }

    private func updateMissionScenarioRuntime(deltaTime: TimeInterval) {
        guard var runtime = missionScenarioRuntime,
              runtime.isActive,
              let target = missionScenarioTargetWorldPosition else { return }

        // Detection requires the operator to actually be watching the payload feed — the gimbal
        // is slaved to drone body orientation (it has no independent mouse-look; aim comes from
        // yaw/pitch sliders in the Camera module) plus a small fixed offset, so without this gate
        // the target could be "found" just by flying near it while looking through any other
        // camera, with nobody ever looking at the payload picture.
        let isWatchingPayloadFeed = cameraConfiguration.mode == .payloadOptics && isMountedPayloadCameraAvailable
        // Detection must mean "crosshair is actually on the target", not "target is somewhere in
        // the wide-FOV frame" — 0.7x half-FOV (tried previously) still covered most of the
        // picture at wide zoom. 0.08x requires the target to sit within ~8% of the frame's half
        // extent from center: a real, deliberate aim, not just generic framing. Floored so very
        // high zoom (FOV ~1°) doesn't demand literally sub-pixel precision.
        let liveFovHalfAngle = Float(payloadCameraController.opticsState.currentFieldOfViewDegrees) * 0.5
        let effectiveConeHalfAngle = min(
            runtime.tuning.coneHalfAngleDegrees,
            max(0.3, liveFovHalfAngle * 0.08)
        )
        let sample = isWatchingPayloadFeed
            ? sceneController.payloadCameraMissionSample(
                targetWorldPosition: target,
                maxRangeMeters: runtime.tuning.maxRangeMeters,
                coneHalfAngleDegrees: effectiveConeHalfAngle
            )
            : nil
        runtime.tick(deltaTime: deltaTime, sample: sample)
        missionScenarioRuntime = runtime
        publishMissionScenarioState()

        if let outcome = runtime.outcome {
            handleMissionScenarioOutcome(outcome)
        }
    }

    private func publishMissionScenarioState() {
        guard let runtime = missionScenarioRuntime else { return }
        missionScenarioObjectiveState = runtime.objectiveState
        missionScenarioRemainingSeconds = runtime.remainingClampedSeconds
        missionScenarioDetectionProgress = runtime.detectionProgress
        missionScenarioOutcome = runtime.outcome
    }

    private func handleMissionScenarioOutcome(_ outcome: MissionScenarioOutcome) {
        guard !didReportMissionScenarioOutcome else { return }
        didReportMissionScenarioOutcome = true
        switch outcome {
        case let .success(elapsed):
            print("[MissionScenario] target detected after \(String(format: "%.1f", elapsed))s")
        case .failureTimeout:
            print("[MissionScenario] failed — time limit reached")
        case .aborted:
            print("[MissionScenario] aborted")
        }
    }

    // MARK: - Mission scenario (Fire Response)

    private func updateFireResponseRuntime(deltaTime: TimeInterval) {
        guard var runtime = fireResponseRuntime, runtime.isActive else { return }

        runtime.tick(
            deltaTime: deltaTime,
            aimedFireIndex: hoseOpticsState.aimedFireTreeIndex,
            isSpraying: hoseOpticsState.isSpraying
        )
        fireResponseRuntime = runtime
        sceneController.updateFireResponseVisuals(
            treeStatuses: runtime.treeStatuses,
            viewerWorldPosition: finiteVector(state.position, fallback: lastFiniteState.position)
        )
        publishFireResponseState()

        if let outcome = runtime.outcome {
            handleFireResponseOutcome(outcome)
        }
    }

    private func publishFireResponseState() {
        guard let runtime = fireResponseRuntime else { return }
        fireResponseObjectiveState = runtime.objectiveState
        fireResponseRemainingSeconds = runtime.remainingClampedSeconds
        fireResponseBurningCount = runtime.burningCount
        fireResponseTotalCount = runtime.treeStatuses.count
        fireResponseOutcome = runtime.outcome
    }

    private func handleFireResponseOutcome(_ outcome: FireResponseOutcome) {
        guard !didReportFireResponseOutcome else { return }
        didReportFireResponseOutcome = true
        switch outcome {
        case let .success(elapsed):
            print("[FireResponse] all fires extinguished after \(String(format: "%.1f", elapsed))s")
        case .failureTimeout:
            print("[FireResponse] failed — time limit reached")
        case .aborted:
            print("[FireResponse] aborted")
        }
    }

    /// Increment-1 manual test hook: extinguishes the fire nearest the drone's current position,
    /// bypassing the (not-yet-built) hose-aim requirement. Exposed for a temporary HUD debug
    /// button; removed once the real hose payload lands.
    func debugExtinguishNearestFireResponseTree() {
        guard var runtime = fireResponseRuntime, runtime.isActive else { return }
        runtime.debugExtinguishNearestFire(to: currentPlanarPosition())
        fireResponseRuntime = runtime
        sceneController.updateFireResponseVisuals(
            treeStatuses: runtime.treeStatuses,
            viewerWorldPosition: finiteVector(state.position, fallback: lastFiniteState.position)
        )
        publishFireResponseState()
        if let outcome = runtime.outcome {
            handleFireResponseOutcome(outcome)
        }
    }

    private func tick() {
        let frameStart = CACurrentMediaTime()
        let now = CACurrentMediaTime()

        // v1.4.6: drive interacting → activeIdle transition (key window, no input for 1 s).
        // The reverse (activeIdle → interacting) is triggered immediately by noteUserInteraction().
        if currentVisibilityState == .activeVisible,
           performancePolicy.activityState == .interacting,
           now - lastUserInteractionAt >= 1.0 {
            refreshActivityPolicy(now: now)
        }

        // v1.4.3+: when throttled, run only 1 in N full ticks. Online work is split:
        //   • stopRendering=false (inactive): scene interpolation runs on skip ticks too so
        //     remote replicas stay smooth between 30 Hz full ticks.
        //   • stopRendering=true (minimized/hidden): skip-ticks do nothing but TX rate-check;
        //     full tick (5 Hz) handles cleanup, interpolation, and scene apply.
        if performancePolicy.isThrottled {
            backgroundTickSkipCounter += 1
            if backgroundTickSkipCounter < performancePolicy.backgroundTickDivisor {
                if onlineRuntimeContext != nil {
                    if !performancePolicy.stopRendering {
                        cleanupOnlineRemoteSnapshotsIfNeeded(now: now)
                        updateOnlineInterpolatedRemoteStates(now: now)
                    }
                    publishOnlineVehicleSnapshotIfNeeded(now: now)
                }
                return
            }
            backgroundTickSkipCounter = 0
        }

        bootstrapMissionScenarioIfNeeded()

        guard let lastTimestamp else {
            self.lastTimestamp = now
            let resolvedInput = updateInputPipeline(deltaTime: 0.0)
            let controllerSnapshot = inputManager.snapshot(for: .gameController)
            if isSpectatorMode {
                updateSpectatorRuntime(deltaTime: 0.0)
                return
            }
            syncControllerInteractionMode()
            processControllerUIInput(
                using: controllerResolvedControlState(from: controllerSnapshot),
                deltaTime: 0.0
            )
            processInputActions(
                using: resolvedInput.applyingInteractionMode(
                    controllerInteractionMode,
                    controllerSnapshot: controllerSnapshot
                )
            )
            syncMissionDeliveryState(triggerAutoRelease: false)
            refreshFlightControlDiagnostics()
            refreshCompassOverlay()
            refreshPayloadCameraStatus(deltaTime: 0.0)
            return
        }

        let dt = Float(max(1.0 / 240.0, min(now - lastTimestamp, 1.0 / 20.0)))
        self.lastTimestamp = now
        simulationTime += dt
        simulationTickCounter &+= 1
        state.armState = isArmed ? .armed : .disarmed
        invalidateFixedWingRouteTrackingContextCache()
        impactSeverityAccumulator = max(0.0, impactSeverityAccumulator - dt * 3.6)
        if physicalState == .crashed {
            collisionAftermathState = .crashed
        } else if impactSeverityAccumulator < 0.18, signalLossCause == nil {
            collisionAftermathState = .nominal
        } else if collisionAftermathState == .impactRecovery, impactSeverityAccumulator > 2.4 {
            collisionAftermathState = .damaged
        }

        let resolvedInput = updateInputPipeline(deltaTime: TimeInterval(dt))
        let controllerSnapshot = inputManager.snapshot(for: .gameController)
        // Keep interacting (60 FPS) whenever the UAV is armed, regardless of velocity.
        if currentVisibilityState == .activeVisible, isArmed {
            noteUserInteraction()
        }
        cleanupOnlineRemoteSnapshotsIfNeeded(now: now)
        refreshDiagnosticHz(now: now)
        updateOnlineInterpolatedRemoteStates(now: now)
        if isSpectatorMode {
            if !performancePolicy.stopRendering {
                updateSpectatorRuntime(deltaTime: dt)
            }
            return
        }
        syncControllerInteractionMode()
        processControllerUIInput(
            using: controllerResolvedControlState(from: controllerSnapshot),
            deltaTime: TimeInterval(dt)
        )
        let interactionAwareInput = resolvedInput.applyingInteractionMode(
            controllerInteractionMode,
            controllerSnapshot: controllerSnapshot
        )
        processInputActions(using: interactionAwareInput)
        applyContinuousCameraLook(deltaTime: dt, controlState: interactionAwareInput)
        applyContinuousCameraZoom(deltaTime: dt)

        // Physics must not run before the ground exists.
        //
        // An imported world takes tens of seconds to prepare, and the session is live throughout.
        // Measured at startup: eight ticks of free fall before `[MeshWorld] collision installed`,
        // velocity already −0.57 m/s and accelerating, because with no collision surface the support
        // query returns nothing and the safety floor sits a metre under a ground height that is
        // still zero. The aircraft was therefore *below the terrain* by the time the terrain
        // arrived — seen as being carried off the pad and left under the textures.
        guard !isAwaitingImportedWorld, isSimulationRunning else {
            syncMissionDeliveryState(triggerAutoRelease: false)
            refreshFlightControlDiagnostics()
            if !performancePolicy.stopRendering {
                sceneController.update(
                    with: state,
                    camera: cameraConfiguration,
                    damage: damageState,
                    thermal: thermalState,
                    diagnosticMode: diagnosticMode,
                    deltaTime: 0.0
                )
            }
            refreshCompassOverlay()
            refreshPayloadCameraStatus(deltaTime: 0.0)
            syncPayloadLifecycleEvents()
            return
        }

        let blocksSimulationForSignalLoss = signalState.isInteractionBlocking &&
            signalLossCause != .impactDamage
        if blocksSimulationForSignalLoss {
            syncMissionDeliveryState(triggerAutoRelease: false)
            refreshFlightControlDiagnostics()
            renderSignalLossFrame()
            refreshCompassOverlay()
            refreshPayloadCameraStatus(deltaTime: TimeInterval(dt))
            syncPayloadLifecycleEvents()
            return
        }

        collisionCooldown = max(0.0, collisionCooldown - dt)
        groundImpactCooldown = max(0.0, groundImpactCooldown - dt)
        supportReacquireBlockTimer = max(0.0, supportReacquireBlockTimer - dt)
        decayFixedWingAssistOverrideTimers(deltaTime: dt)
        componentFailureRuntime.tick(deltaTime: dt)
        if !componentFailureRuntime.isEmpty {
            // Intermittent failures toggle over time — re-bake their factors.
            refreshDamagePhysicsModels()
        }

        applyResolvedFlightControls(deltaTime: dt, controlState: interactionAwareInput)
        updateHandLaunchPOVWalk(deltaTime: dt)
        updateMissionReplayLifecycle()
        activeFixedWingLaunchDynamics = nil
        updateAutopilotTargets(deltaTime: dt)
        let pathfindingMs = autoPathPlanner.lastPlanDurationMs

        _ = updateFleetStatus(deltaTime: dt)

        let collisionCandidateRadius = collisionService.spatialQueryRadius
        let prePhysicsCollisionObstacles = sceneController.nearbyEnvironmentObstacles(
            near: state.position,
            radius: collisionCandidateRadius
        )
        let prePhysicsCollisionAnalysis = collisionService.analyze(
            input: CollisionAnalysisInput(
                dronePosition: state.position,
                droneVelocity: state.velocity,
                droneRadius: selectedDroneProfile.collisionRadius,
                // Fleet spacing is handled separately; feeding wingmen back into leader
                // collision avoidance makes formation flight self-block on map guidance.
                obstacles: prePhysicsCollisionObstacles,
                weather: weather
            )
        )
        collisionAnalysis = prePhysicsCollisionAnalysis

        handleAutoCollisionInterventions(deltaTime: dt)

        let control = buildControlInput(from: controlValues)
        let context = DroneSimulationContext(
            profile: selectedDroneProfile,
            activeUAVProfile: activeUAVProfile,
            weather: weather,
            damageState: damageState,
            batteryState: batteryState,
            collisionRisk: collisionAnalysis.riskScore,
            windVector: weather.windVector,
            vehicleMassModel: vehicleMassModel,
            fixedWingLaunchDynamics: activeFixedWingLaunchDynamics,
            vehicleMassProperties: vehicleMassProperties,
            contactProfile: vehicleContactProfile,
            rotorModel: vehicleRotorModel,
            aeroDamage: vehicleAeroDamage,
            jammedSurfaces: componentFailureRuntime.jammedSurfaces(),
            powerSystemFactor: componentFailureRuntime.functionalFactor(componentID: "battery"),
            controlSystemFactor: componentFailureRuntime.functionalFactor(componentID: "flightController"),
            groundHeight: currentGroundHeight()
        )

        let previousState = state
        let physicsStart = CACurrentMediaTime()
        state = physicsEngine.step(
            state: state,
            control: control,
            context: context,
            deltaTime: dt
        )
        #if DEBUG
        let afterPhysicsY = state.position.y
        let afterPhysicsVY = state.velocity.y
        #endif
        enforceRuntimeSafetyAndBounds(context: "tick.physics")
        #if DEBUG
        let afterSafetyY = state.position.y
        #endif
        applySupportSurfaceConstraint(previousState: previousState)
        applyWaterImmersionIfNeeded(deltaTime: dt)
        #if DEBUG
        // Which stage of the vertical chain is holding the aircraft down. Prints only while armed
        // and commanding climb, roughly twice a second, so a short takeoff attempt is readable.
        if isArmed, controlValues.throttle > 0.6 {
            verticalDebugTicks += 1
            if verticalDebugTicks % 30 == 0 {
                print(String(format:
                    "[Vert] тяга %.2f | до физики y %.3f → после физики %.3f (vy %+.3f) → после границ %.3f → после опоры %.3f | земля %.3f | сост %@",
                    controlValues.throttle, previousState.position.y, afterPhysicsY, afterPhysicsVY,
                    afterSafetyY, state.position.y, lastKnownGroundHeight,
                    String(describing: physicalState)))
            }
        } else {
            verticalDebugTicks = 0
        }
        #endif
        applyPayloadSelfInteractionIfNeeded(deltaTime: dt)
        let structuralLoadState = state
        let physicsTimeMs = (CACurrentMediaTime() - physicsStart) * 1000.0

        var postPhysicsCollisionAnalysis: CollisionAnalysisSnapshot
        let sweptCollisionObstacles = sceneController.nearbyEnvironmentObstacles(
            from: previousState.position,
            to: state.position,
            margin: max(selectedDroneProfile.collisionRadius, vehicleContactProfile.boundingRadius) + 1.0
        )
        var impactReport: ImpactReport?
        if let vehicleContact = collisionService.firstSweptVehicleCollision(
            contactSpheres: vehicleContactProfile.spheres,
            fromPosition: previousState.position,
            toPosition: state.position,
            fromOrientation: attitudeQuaternion(of: previousState),
            toOrientation: attitudeQuaternion(of: state),
            obstacles: sweptCollisionObstacles
        ) {
            if vehicleContact.isSupportSurfaceContact {
                // A slow roof landing remains a light touch. A hard gear,
                // wingtip or prop contact uses the real swept contact even
                // when the vehicle CG is already outside the roof footprint.
                if let report = resolveSupportSurfaceImpactIfNeeded(
                    contact: vehicleContact,
                    previousState: previousState,
                    deltaTime: dt
                ) {
                    impactReport = report
                    postPhysicsCollisionAnalysis = CollisionAnalysisSnapshot(
                        riskScore: 1.0,
                        nearestObstacleDistance: 0.0,
                        nearestObstacleID: vehicleContact.obstacle.id,
                        nearestObstacleSource: vehicleContact.obstacle.source,
                        timeToCollision: 0.0,
                        emergencyAction: collisionEmergencyAction(for: report.tier),
                        contactNormal: vehicleContact.contactNormal
                    )
                } else {
                    postPhysicsCollisionAnalysis = .safe
                }
            } else {
                // Impulse-based contact: the vehicle stops at its own pose along
                // the step, receives a proper linear+angular impulse with lever
                // arm and material restitution/friction, and takes damage
                // localized to the struck component. No teleport, no velocity
                // zeroing, no forced disarm here.
                let report = impactResolutionService.resolve(
                    contact: vehicleContact,
                    previousPosition: previousState.position,
                    state: &state,
                    graph: &componentGraph,
                    massProperties: vehicleMassProperties,
                    airframeClass: selectedDroneProfile.airframeClass,
                    rotorsSpinning: state.throttle > 0.05 && isArmed,
                    deltaTime: dt,
                    applyDamage: collisionCooldown <= 0.0,
                    restingSpeedThreshold: crashResolutionRestingSpeedThreshold
                )
                impactReport = report
                postPhysicsCollisionAnalysis = CollisionAnalysisSnapshot(
                    riskScore: 1.0,
                    nearestObstacleDistance: -0.02,
                    nearestObstacleID: vehicleContact.obstacle.id,
                    nearestObstacleSource: vehicleContact.obstacle.source,
                    timeToCollision: 0.0,
                    emergencyAction: collisionEmergencyAction(for: report.tier),
                    contactNormal: vehicleContact.contactNormal
                )
            }
        } else {
            let postPhysicsCollisionObstacles = sceneController.nearbyEnvironmentObstacles(
                near: state.position,
                radius: collisionCandidateRadius
            )
            postPhysicsCollisionAnalysis = collisionService.analyze(
                input: CollisionAnalysisInput(
                    dronePosition: state.position,
                    droneVelocity: state.velocity,
                    droneRadius: selectedDroneProfile.collisionRadius,
                    obstacles: postPhysicsCollisionObstacles,
                    weather: weather
                )
            )
        }

        // Flat terrain is not represented by the obstacle broad phase. Feed
        // touchdown through the same contact/impulse/damage path so a hard
        // landing can bend gear, break propellers and bounce instead of being
        // silently clamped to Y with its velocity erased.
        if impactReport == nil,
           let groundReport = resolveGroundImpactIfNeeded(
               previousState: previousState,
               deltaTime: dt
           ) {
            impactReport = groundReport
            postPhysicsCollisionAnalysis = CollisionAnalysisSnapshot(
                riskScore: 1.0,
                nearestObstacleDistance: 0.0,
                nearestObstacleID: nil,
                nearestObstacleSource: groundReport.obstacleSource,
                timeToCollision: 0.0,
                emergencyAction: collisionEmergencyAction(for: groundReport.tier),
                contactNormal: groundReport.contactNormal
            )
        }

        collisionAnalysis = postPhysicsCollisionAnalysis
        var needsCollisionAnalysisRefresh = false
        if let report = impactReport {
            applyImpactConsequences(report)
            if report.tier != .lightTouch, collisionCooldown <= 0.0 {
                collisionCooldown = collisionCooldownDuration(for: report.obstacleSource, tier: report.tier)
            }
            enforceRuntimeSafetyAndBounds(context: "tick.collision_damage")
            needsCollisionAnalysisRefresh = true
        } else if postPhysicsCollisionAnalysis.nearestObstacleDistance <= -0.02 {
            // Top faces of support surfaces (roofs, container/crate tops) are excluded from the
            // collision analysis (see CollisionAnalysisService.isPassiveTopSupport*), and the
            // support-surface floor clamp has already seated a landed drone, so any penetration
            // reported here is a genuine wall / underside strike the sweep missed (slow push).
            if resolveObstaclePenetration(using: postPhysicsCollisionAnalysis) {
                enforceRuntimeSafetyAndBounds(context: "tick.collision_resolve")
                needsCollisionAnalysisRefresh = true
            }
        }


        if impactReport == nil, !needsCollisionAnalysisRefresh {
            advanceStructuralDamage(
                previousState: previousState,
                loadState: structuralLoadState,
                deltaTime: dt
            )
        }
        enforceComponentFunctionalState()

        if needsCollisionAnalysisRefresh {
            let refreshedCollisionObstacles = sceneController.nearbyEnvironmentObstacles(
                near: state.position,
                radius: collisionCandidateRadius
            )
            collisionAnalysis = collisionService.analyze(
                input: CollisionAnalysisInput(
                    dronePosition: state.position,
                    droneVelocity: state.velocity,
                    droneRadius: selectedDroneProfile.collisionRadius,
                    obstacles: refreshedCollisionObstacles,
                    weather: weather
                )
            )
        }

        updatePhysicalState(previousState: previousState, deltaTime: dt)
        if let launchDynamics = activeFixedWingLaunchDynamics,
           launchDynamics.phase == .held || launchDynamics.phase == .catapultRail {
            transitionPhysicalState(.takeoffTransition)
        }
        applyGroundedSafetyIfNeeded(deltaTime: dt)
        refreshFixedWingLaunchPresentation()

        #if DEBUG
        // Launch detector: a sudden upward position jump with low vertical velocity is a teleport
        // (collision push-out / support snap), not real climb — the "thrown up several meters" bug.
        let verticalJump = state.position.y - previousState.position.y
        if verticalJump > 0.5, state.velocity.y < verticalJump / dt * 0.5 {
            print(
                "[LaunchDetect] up-jump dy=\(verticalJump) prevY=\(previousState.position.y) " +
                "newY=\(state.position.y) velY=\(state.velocity.y) physState=\(physicalState) " +
                "collisionSource=\(collisionAnalysis.nearestObstacleSource ?? "n/a") " +
                "dist=\(collisionAnalysis.nearestObstacleDistance)"
            )
        }
        #endif

        handleModeTransitions()
        enforceRuntimeSafetyAndBounds(context: "tick.post_mode")
        updateSignalLossSequence(deltaTime: dt)
        updateFiberOpticTether(deltaTime: dt)
        updateControlLinkFailsafeSequence(deltaTime: dt)
        updateControlLinkFailsafeLatchRecovery(deltaTime: dt)
        armBlockReason = resolveArmAuthorization().reason
        syncMissionDeliveryState(triggerAutoRelease: false)

        if blocksSimulationForSignalLoss {
            refreshFlightControlDiagnostics()
            renderSignalLossFrame()
            refreshCompassOverlay()
            syncPayloadLifecycleEvents()
            return
        }

        syncMissionDeliveryState(triggerAutoRelease: true)
        updateMissionExecutionRuntime()

        let maneuverAggressiveness = (abs(Float(controlValues.roll)) + abs(Float(controlValues.pitch))) / 120.0
        batteryState = batteryThermalService.updateBattery(
            current: batteryState,
            input: BatteryComputationInput(
                droneProfile: selectedDroneProfile,
                weather: weather,
                damageState: damageState,
                speedMps: simd_length(state.velocity),
                verticalSpeedMps: abs(state.velocity.y),
                throttle: state.throttle,
                maneuverAggressiveness: maneuverAggressiveness
            ),
            deltaTime: dt
        )

        thermalState = batteryThermalService.updateThermal(
            current: thermalState,
            throttle: state.throttle,
            weather: weather,
            damageState: damageState,
            collisionRisk: collisionAnalysis.riskScore,
            maneuverAggressiveness: maneuverAggressiveness,
            deltaTime: dt
        )
        updateBatteryFireState(deltaTime: dt)

        if batteryState.isDepleted {
            disarm(forceEmergency: true)
            updateControlValues({ values in
                values.throttle = 0.0
            }, markManual: false)
            if !showBatteryDepletedDialog {
                showBatteryDepletedDialog = true
            }
        }

        applyMissionSafetyRuntimeIfNeeded()
        sampleMissionObservationIfNeeded()
        updateThunderstormLightning(deltaTime: dt)

        let renderStart = CACurrentMediaTime()
        if !performancePolicy.stopRendering {
            sceneController.setDamageVibrationLevel(
                vehicleRotorModel.vibrationLevel * state.motorThrottle
            )
            sceneController.applyWeatherVisual(weather)
            sceneController.update(
                with: state,
                camera: cameraConfiguration,
                damage: damageState,
                thermal: thermalState,
                diagnosticMode: diagnosticMode,
                deltaTime: dt
            )
            sceneController.updateFleetWingmen(
                wingmen,
                profile: selectedDroneProfile,
                throttle: state.throttle,
                deltaTime: dt
            )
        }
        refreshCompassOverlay()
        refreshPayloadCameraStatus(deltaTime: TimeInterval(dt))
        syncPayloadLifecycleEvents()
        updateMissionScenarioRuntime(deltaTime: TimeInterval(dt))
        updateFireResponseRuntime(deltaTime: TimeInterval(dt))
        recordDetachedVehiclePartImpactEvents()
        // Make secondary debris impacts visible to the outgoing LAN event
        // tail in this publish cycle. The end-of-tick flush remains in place
        // for any events produced later in the frame.
        flushDamageEventAdapters()
        publishOnlineVehicleSnapshotIfNeeded(now: now)
        let renderTimeMs = (CACurrentMediaTime() - renderStart) * 1000.0

        collisionDebugAccumulator += dt
        let collisionDebugStateChanged = (lastCollisionDebugEnabled != collisionDebugEnabled)
        if !performancePolicy.stopRendering,
           (collisionDebugEnabled && collisionDebugAccumulator > 0.12) || collisionDebugStateChanged {
            sceneController.updateCollisionDebug(risk: collisionAnalysis, enabled: collisionDebugEnabled)
            sceneController.updatePathDebug(
                path: navigationSnapshot.waypoints,
                currentWaypointIndex: navigationSnapshot.currentWaypointIndex,
                start: navigationSnapshot.start,
                goal: navigationSnapshot.goal,
                enabled: collisionDebugEnabled && (mode == .autoPath || mode == .returnHome)
            )
            collisionDebugAccumulator = 0.0
            lastCollisionDebugEnabled = collisionDebugEnabled
        }

        diagnosticsSamplingAccumulator += dt
        if !performancePolicy.stopRendering,
           diagnosticsSamplingAccumulator >= 0.45 || cachedDiagnostics.activeObjectCount == 0 {
            let sceneStats = sceneController.sceneDiagnostics()
            let nextDiagnostics = SimulationDiagnostics(
                frameTimeMs: (CACurrentMediaTime() - frameStart) * 1000.0,
                physicsTimeMs: physicsTimeMs,
                renderTimeMs: renderTimeMs,
                pathfindingTimeMs: pathfindingMs,
                activeObjectCount: sceneStats.activeObjectCount,
                activePhysicsBodyCount: sceneStats.activePhysicsBodyCount,
                activeParticleCount: sceneStats.activeParticleCount
            )
            cachedDiagnostics = nextDiagnostics
            if diagnostics != nextDiagnostics {
                diagnostics = nextDiagnostics
            }
            diagnosticsSamplingAccumulator = 0.0
        }

        hudPublishAccumulator += dt
        let shouldPublishHUD = hudPublishAccumulator >= 0.15 || telemetry.timestampISO8601.isEmpty
        let shouldPersistTelemetry = telemetrySamplingAccumulator + dt >= 0.2
        if shouldPublishHUD || shouldPersistTelemetry {
            refreshFixedWingAssistRuntimeDebugState()
            refreshTerrainMapSnapshotIfVisible(recordTrail: true)
            let latestWarnings = buildWarnings()
            let latestTelemetry = buildTelemetrySnapshot()

            if shouldPublishHUD {
                if warnings != latestWarnings {
                    warnings = latestWarnings
                }
                telemetry = latestTelemetry
                hudPublishAccumulator = 0.0
            }

            if shouldPersistTelemetry {
                telemetryExporter.append(snapshot: latestTelemetry)
                telemetrySamplingAccumulator = 0.0
            }
        }

        telemetrySamplingAccumulator += dt

        if !hasUnsavedChanges,
           simd_length(state.velocity) > 0.03 || abs(state.throttle) > 0.02 || mode != .manual {
            hasUnsavedChanges = true
        }

        refreshMissionStatus()
        flushDamageEventAdapters()
        recordMissionReplayFrameIfNeeded()
        recordMissionReplayWarningsIfNeeded()

        autosaveAccumulator += dt
        if autosaveAccumulator >= 6.0 {
            performAutosaveIfNeeded()
            autosaveAccumulator = 0.0
        }
    }

    /// HUD/state consequences of an impulse-resolved impact. The physical
    /// response (impulse, positional correction, localized graph damage) has
    /// already been applied by `ImpactResolutionService` — this maps the
    /// report onto aftermath state, severity accumulation, the legacy damage
    /// projection and possible internal failures. Signal/FPV loss is no
    /// longer automatic on a severe hit: it only happens when the hit
    /// actually took out the radio/flight controller
    /// (`evaluateImpactInternalFailures`).
    private func applyImpactConsequences(_ report: ImpactReport) {
        let wasAlreadyDamaged = recordedPhysicalImpactCount > 0
        lastCollisionSource = report.obstacleSource ?? lastCollisionSource
        lastCollisionDetail = String(
            format: "comp=%@ E=%.1fJ vN=%.2f j=%.2f tier=%@",
            report.componentID,
            report.impactEnergyJ,
            report.normalClosingSpeed,
            report.appliedImpulse,
            report.tier.rawValue
        )

        #if DEBUG
        if report.tier != .lightTouch {
            let damageSummary = report.damage
                .map { entry in
                    "\(entry.componentID):\(String(format: "%.2f", entry.integrityBefore))→\(String(format: "%.2f", entry.integrityAfter))"
                }
                .joined(separator: ",")
            print(
                "[Impact] tier=\(report.tier.rawValue) comp=\(report.componentID) " +
                "src=\(report.obstacleSource ?? "?") E=\(String(format: "%.1f", report.impactEnergyJ))J " +
                "vN=\(String(format: "%.2f", report.normalClosingSpeed)) " +
                "j=\(String(format: "%.2f", report.appliedImpulse)) dmg=[\(damageSummary)]"
            )
        }
        #endif

        if report.impactEnergyJ > 0.0 || report.appliedImpulse > 0.0 {
            recordedPhysicalImpactCount &+= 1
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: wasAlreadyDamaged ? .secondaryImpact : .impact,
                componentID: report.componentID,
                colliderID: report.obstacleID.uuidString,
                worldPoint: report.contactPoint,
                impulseNs: report.appliedImpulse,
                energyJ: report.impactEnergyJ,
                reason: report.obstacleSource ?? "physical_contact"
            )
        }

        if !report.damage.isEmpty {
            // Localized damage went into the graph — project onto the legacy
            // DamageState so overlay/diagnostics/battery model keep working.
            damageState = componentGraph.projectedLegacyDamageState(base: damageState)

            // Roll for new failure modes and re-bake the physics-facing
            // damage models (rotor thrust factors, aero deltas).
            let assignedFailures = componentFailureRuntime.noteDamage(
                entries: report.damage,
                graph: componentGraph,
                currentAileron: state.aileronDeflection,
                currentElevator: state.elevatorDeflection,
                currentRudder: state.rudderDeflection
            )
            for entry in report.damage {
                let meaningfulDelta = entry.integrityBefore - entry.integrityAfter >= 0.0005
                guard meaningfulDelta || entry.integrityAfter <= 0.0001 else { continue }
                damageEventRecorder.record(
                    timestamp: TimeInterval(simulationTime),
                    type: entry.integrityAfter <= 0.0001 ? .componentFailed : .componentDamaged,
                    componentID: entry.componentID,
                    worldPoint: report.contactPoint,
                    energyJ: report.impactEnergyJ,
                    integrityBefore: entry.integrityBefore,
                    integrityAfter: entry.integrityAfter,
                    residualStrengthBefore: entry.residualStrengthBefore,
                    residualStrengthAfter: entry.residualStrengthAfter,
                    reason: "localized_impact"
                )
                if entry.componentID == "battery", entry.integrityAfter <= 0.0001,
                   entry.integrityBefore > 0.0001, report.tier == .criticalImpact {
                    igniteBatteryFireIfNeeded(reason: "battery_impact_rupture")
                }
            }
            for assigned in assignedFailures {
                let componentID = assigned.split(separator: ":", maxSplits: 1).first.map(String.init)
                let mode = componentID.flatMap { componentFailureRuntime.failures[$0]?.mode }
                damageEventRecorder.record(
                    timestamp: TimeInterval(simulationTime),
                    type: .subsystemFailed,
                    componentID: componentID,
                    failureMode: mode,
                    reason: assigned
                )
            }
            refreshDamagePhysicsModels()
            #if DEBUG
            if !assignedFailures.isEmpty {
                print("[DamageFx] failures assigned: \(assignedFailures.joined(separator: ", "))")
            }
            let factors = vehicleRotorModel.rotors
                .map { "\($0.slot)=\(String(format: "%.2f", $0.thrustFactor))" }
                .joined(separator: " ")
            print("[DamageFx] rotors: \(factors) vib=\(String(format: "%.2f", vehicleRotorModel.vibrationLevel))")
            #endif
        }

        for entry in report.connectionDamage {
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: entry.stateAfter == .attached ? .componentDeformed : .connectionLoosened,
                componentID: entry.childComponentID,
                connectionID: entry.connectionID,
                worldPoint: report.contactPoint,
                impulseNs: report.appliedImpulse,
                energyJ: report.impactEnergyJ,
                residualStrengthBefore: entry.residualStrengthBefore,
                residualStrengthAfter: entry.residualStrengthAfter,
                reason: "connection_impact"
            )
        }

        detachFailedSubtrees(
            rootComponentIDs: componentGraph.failedConnectionRootIDs,
            reason: "impact_connection_failure",
            impactMotions: Dictionary(
                uniqueKeysWithValues: report.detachedPartMotions.map {
                    ($0.rootComponentID, $0)
                }
            )
        )

        guard report.tier != .lightTouch else { return }

        let severityGain: Float
        switch report.tier {
        case .lightTouch:
            severityGain = 0.0
        case .scrape:
            severityGain = 0.45
        case .heavyImpact:
            severityGain = 0.9
        case .criticalImpact:
            severityGain = 1.4
        }
        impactSeverityAccumulator = max(
            impactSeverityAccumulator,
            report.normalClosingSpeed * severityGain
        )

        switch report.tier {
        case .lightTouch:
            break
        case .scrape:
            collisionAftermathState = .impactRecovery
            if mode.isAutoControlled {
                setFlightMode(.manual, reason: "auto_mode_cancelled_minor_collision")
            }
            evaluateImpactInternalFailures(report)
        case .heavyImpact:
            collisionAftermathState = .damaged
            if selectedDroneProfile.airframeClass == .multirotor, physicalState != .crashed {
                setFlightMode(.hover, reason: "multicopter_collision_hover_recovery")
            }
            evaluateImpactInternalFailures(report)
        case .criticalImpact:
            // A severe hit changes only damage/control authority. Surviving
            // propulsion and aerodynamic sections remain in the normal
            // solver and determine whether the aircraft recovers or tumbles.
            collisionAftermathState = .damaged
            evaluateImpactInternalFailures(report)
        }
    }

    private func resolveSupportSurfaceImpactIfNeeded(
        contact: VehicleSweptContact,
        previousState: DroneState,
        deltaTime: Float
    ) -> ImpactReport? {
        guard groundImpactCooldown <= 0.0 else { return nil }
        let normal = simd_length_squared(contact.contactNormal) > 0.0001
            ? simd_normalize(contact.contactNormal)
            : SIMD3<Float>(0.0, 1.0, 0.0)
        let orientation = attitudeQuaternion(of: previousState)
        let rates = selectedDroneProfile.airframeClass == .multirotor
            ? previousState.angularVelocity
            : previousState.bodyAngularVelocity
        let omegaWorld = simd_act(orientation, SIMD3<Float>(rates.y, rates.z, rates.x))
        let previousCoM = previousState.position + simd_act(
            orientation,
            vehicleMassProperties.centerOfMassOffset
        )
        let incomingVelocity = previousState.velocity + simd_cross(
            omegaWorld,
            contact.contactPoint - previousCoM
        )
        let closingSpeed = -simd_dot(incomingVelocity, normal)
        guard closingSpeed > 0.35 else { return nil }

        let previousLinearNormal = simd_dot(previousState.velocity, normal)
        let currentLinearNormal = simd_dot(state.velocity, normal)
        if previousLinearNormal < currentLinearNormal {
            state.velocity += normal * (previousLinearNormal - currentLinearNormal)
        }
        let report = impactResolutionService.resolve(
            contact: contact,
            previousPosition: previousState.position,
            state: &state,
            graph: &componentGraph,
            massProperties: vehicleMassProperties,
            airframeClass: selectedDroneProfile.airframeClass,
            rotorsSpinning: state.throttle > 0.05 && isArmed,
            deltaTime: deltaTime,
            applyDamage: true,
            restingSpeedThreshold: crashResolutionRestingSpeedThreshold
        )
        groundImpactCooldown = report.tier == .lightTouch ? 0.05 : 0.16
        return report
    }

    private func resolveGroundImpactIfNeeded(
        previousState: DroneState,
        deltaTime: Float
    ) -> ImpactReport? {
        guard groundImpactCooldown <= 0.0 else { return nil }

        let currentOrientation = attitudeQuaternion(of: state)
        let previousOrientation = attitudeQuaternion(of: previousState)
        let support = supportSurfaceContact(for: state.position)
        let supportY = support?.height ?? supportSurfaceY(for: state.position)
        var normal = support?.normal ?? SIMD3<Float>(0.0, 1.0, 0.0)
        if simd_length_squared(normal) < 0.0001 {
            normal = SIMD3<Float>(0.0, 1.0, 0.0)
        } else {
            normal = simd_normalize(normal)
        }

        let fallbackSphere = VehicleContactSphere(
            componentID: componentGraph.component(id: "gear.main") != nil ? "gear.main" : "frame",
            offset: .zero,
            radius: max(0.05, selectedDroneProfile.collisionRadius * 0.22)
        )
        let currentLowest = vehicleContactProfile.lowestContact(
            position: state.position,
            orientation: currentOrientation
        ) ?? (sphere: fallbackSphere, point: state.position)
        let previousLowest = vehicleContactProfile.lowestContact(
            position: previousState.position,
            orientation: previousOrientation
        ) ?? (sphere: fallbackSphere, point: previousState.position)

        let currentHeight = currentLowest.point.y - supportY
        let previousSupportY = supportSurfaceY(for: previousState.position)
        let previousHeight = previousLowest.point.y - previousSupportY
        guard currentHeight <= 0.035, previousHeight > 0.018 else { return nil }

        let rates = selectedDroneProfile.airframeClass == .multirotor
            ? previousState.angularVelocity
            : previousState.bodyAngularVelocity
        let omegaBodyAxes = SIMD3<Float>(rates.y, rates.z, rates.x)
        let omegaWorld = simd_act(previousOrientation, omegaBodyAxes)
        let previousCoM = previousState.position + simd_act(
            previousOrientation,
            vehicleMassProperties.centerOfMassOffset
        )
        let incomingContactVelocity = previousState.velocity + simd_cross(
            omegaWorld,
            previousLowest.point - previousCoM
        )
        let closingSpeed = -simd_dot(incomingContactVelocity, normal)
        guard closingSpeed > 0.35 else { return nil }

        // The legacy engine/support constraint may already have erased the
        // downward component. Restore the pre-contact normal velocity so the
        // impulse solver sees the real approach speed.
        let previousLinearNormal = simd_dot(previousState.velocity, normal)
        let currentLinearNormal = simd_dot(state.velocity, normal)
        if previousLinearNormal < currentLinearNormal {
            state.velocity += normal * (previousLinearNormal - currentLinearNormal)
        }

        let elevatedStructure = supportY > 0.05
        let source = elevatedStructure
            ? "ground.structure"
            : "ground.\(terrain.preset.rawValue.lowercased())"
        let obstacle = CollisionObstacle(
            id: UUID(),
            center: SIMD3<Float>(state.position.x, supportY - 0.25, state.position.z),
            radius: 500.0,
            source: source,
            baseY: supportY - 0.5,
            topY: supportY,
            planarHalfExtents: SIMD2<Float>(repeating: 500.0)
        )
        let contactPoint = SIMD3<Float>(currentLowest.point.x, supportY, currentLowest.point.z)
        let syntheticContact = VehicleSweptContact(
            obstacle: obstacle,
            componentID: currentLowest.sphere.componentID,
            contactPoint: contactPoint,
            contactNormal: normal,
            hitFraction: 1.0,
            isSupportSurfaceContact: true,
            sphereOffset: currentLowest.sphere.offset,
            sphereRadius: currentLowest.sphere.radius
        )
        let report = impactResolutionService.resolve(
            contact: syntheticContact,
            previousPosition: previousState.position,
            state: &state,
            graph: &componentGraph,
            massProperties: vehicleMassProperties,
            airframeClass: selectedDroneProfile.airframeClass,
            rotorsSpinning: state.throttle > 0.05 && isArmed,
            deltaTime: deltaTime,
            applyDamage: true,
            restingSpeedThreshold: crashResolutionRestingSpeedThreshold
        )
        groundImpactCooldown = report.tier == .lightTouch ? 0.05 : 0.16
        return report
    }

    private func advanceStructuralDamage(
        previousState: DroneState,
        loadState: DroneState,
        deltaTime: Float
    ) {
        let result = structuralLoadSolver.evaluate(
            graph: &componentGraph,
            previousState: previousState,
            state: loadState,
            airframeClass: selectedDroneProfile.airframeClass,
            rotorModel: vehicleRotorModel,
            deltaTime: deltaTime
        )
        for entry in result.connectionDamage {
            let meaningfulDelta = entry.residualStrengthBefore - entry.residualStrengthAfter >= 0.002
            guard meaningfulDelta || entry.stateBefore != entry.stateAfter else { continue }
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: entry.stateAfter == .attached ? .componentDeformed : .connectionLoosened,
                componentID: entry.childComponentID,
                connectionID: entry.connectionID,
                residualStrengthBefore: entry.residualStrengthBefore,
                residualStrengthAfter: entry.residualStrengthAfter,
                reason: "structural_load_progression"
            )
        }
        detachFailedSubtrees(
            rootComponentIDs: result.failedConnectionRootIDs,
            reason: "structural_overload"
        )
    }

    private func enforceComponentFunctionalState() {
        let batteryAvailable = componentGraph.integrity(id: "battery") > 0.001 &&
            componentFailureRuntime.functionalFactor(componentID: "battery") > 0.20
        let controllerAvailable = componentGraph.integrity(id: "flightController") > 0.05 &&
            componentFailureRuntime.functionalFactor(componentID: "flightController") > 0.20
        let radioAvailable = componentGraph.integrity(id: "radio") > 0.05 &&
            componentFailureRuntime.functionalFactor(componentID: "radio") > 0.20
        let rootDestroyed = ["frame", "fuselage"].contains { id in
            componentGraph.component(id: id) != nil && componentGraph.integrity(id: id) <= 0.001
        }

        if !radioAvailable, signalLossCause == nil {
            signalLossCause = .impactDamage
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: .subsystemFailed,
                componentID: "radio",
                reason: "radio_function_unavailable"
            )
            enterSignalLostState(cause: .impactDamage)
        }

        guard isArmed, !batteryAvailable || !controllerAvailable || rootDestroyed else { return }
        let componentID: String
        let reason: String
        if rootDestroyed {
            componentID = componentGraph.component(id: "frame") != nil ? "frame" : "fuselage"
            reason = "primary_structure_destroyed"
        } else if !batteryAvailable {
            componentID = "battery"
            reason = "power_source_unavailable"
        } else {
            componentID = "flightController"
            reason = "flight_controller_unavailable"
        }
        collisionAftermathState = .damaged
        damageEventRecorder.record(
            timestamp: TimeInterval(simulationTime),
            type: .subsystemFailed,
            componentID: componentID,
            reason: reason
        )
        damageEventRecorder.record(
            timestamp: TimeInterval(simulationTime),
            type: .controlAuthorityLost,
            componentID: componentID,
            reason: reason
        )
        disarm(forceEmergency: true, preserveCrashDynamics: false)
    }

    private func detachFailedSubtrees(
        rootComponentIDs: [String],
        reason: String,
        impactMotions: [String: ImpactDetachedPartMotion] = [:]
    ) {
        var detachedParts: [VehicleDetachedSubtree] = []
        for rootID in Set(rootComponentIDs).sorted() {
            if let part = componentGraph.detachSubtree(rootComponentID: rootID) {
                detachedParts.append(part)
                componentFailureRuntime.removeFailures(componentIDs: part.componentIDs)
                vehicleContactProfile = vehicleContactProfile.removing(componentIDs: part.componentIDs)
                damageEventRecorder.record(
                    timestamp: TimeInterval(simulationTime),
                    type: .componentDetached,
                    componentID: part.rootComponentID,
                    reason: reason,
                    detachedComponentIDs: Array(part.componentIDs),
                    massPropertiesRevision: componentGraph.massPropertiesRevision
                )
            }
        }
        guard !detachedParts.isEmpty else { return }

        vehicleMassProperties = componentGraph.massProperties
        damageState = componentGraph.projectedLegacyDamageState(base: damageState)
        // Clone the currently deformed source geometry before refreshing the
        // attached-airframe overlay hides/resets the detached source nodes.
        let orientation = attitudeQuaternion(of: state)
        let rates = selectedDroneProfile.airframeClass == .multirotor
            ? state.angularVelocity
            : state.bodyAngularVelocity
        let omegaBodyAxes = SIMD3<Float>(rates.y, rates.z, rates.x)
        let retainedLegacyComponents = Set(
            componentGraph.attachedComponents.compactMap(\.legacyComponent)
        )
        for part in detachedParts {
            let impactMotion = impactMotions[part.rootComponentID]
            sceneController.spawnDetachedVehiclePart(
                part,
                retainedLegacyComponents: retainedLegacyComponents,
                vehicleWorldPosition: state.position,
                vehicleOrientation: orientation,
                inheritedVelocity: state.velocity,
                inheritedAngularVelocity: omegaBodyAxes,
                initialCenterOfMassVelocityWorld: impactMotion?.centerOfMassVelocityWorld,
                initialAngularVelocityWorld: impactMotion?.angularVelocityWorld
            )
        }
        sceneController.reconcileDetachedVehicleVisuals(componentGraph)
        refreshDamagePhysicsModels()
        damageEventRecorder.record(
            timestamp: TimeInterval(simulationTime),
            type: .massPropertiesChanged,
            reason: reason,
            detachedComponentIDs: detachedParts.flatMap { Array($0.componentIDs) },
            massPropertiesRevision: componentGraph.massPropertiesRevision
        )
    }

    private func recordDetachedVehiclePartImpactEvents() {
        for event in sceneController.consumeDetachedVehiclePartImpactEvents() {
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: .secondaryImpact,
                componentID: event.rootComponentID,
                colliderID: event.colliderID.uuidString,
                worldPoint: event.worldPoint,
                impulseNs: event.impulseNs,
                energyJ: event.energyJ,
                reason: "detached_part_impact:\(event.colliderSource)",
                detachedComponentIDs: event.detachedComponentIDs,
                massPropertiesRevision: componentGraph.massPropertiesRevision
            )
        }
    }

    private func flushDamageEventAdapters() {
        let events = damageEventRecorder.consumePendingEvents()
        guard !events.isEmpty else { return }
        recentDamageEvents.append(contentsOf: events)
        if recentDamageEvents.count > 32 {
            recentDamageEvents.removeFirst(recentDamageEvents.count - 32)
        }
        for event in events {
            let replayType: MissionReplayEventType
            switch event.type {
            case .impact, .secondaryImpact:
                replayType = .impact
            case .componentDamaged, .componentDeformed, .connectionLoosened, .componentFailed:
                replayType = .componentDamaged
            case .componentDetached:
                replayType = .componentDetached
            case .subsystemFailed:
                replayType = .subsystemFailed
            case .massPropertiesChanged:
                replayType = .massPropertiesChanged
            case .controlAuthorityReduced, .controlAuthorityLost:
                replayType = .controlAuthorityReduced
            case .vehicleSettled:
                replayType = .vehicleSettled
            }
            let subject = event.componentID.map { " [\($0)]" } ?? ""
            let payload = MissionReplayDamagePayload(
                sequenceNumber: event.sequenceNumber,
                canonicalEventTypeRawValue: event.type.rawValue,
                vehicleID: onlineRuntimeContext?.localVehicleID,
                componentID: event.componentID,
                connectionID: event.connectionID,
                colliderID: event.colliderID,
                impulseNs: event.impulseNs,
                energyJ: event.energyJ,
                integrityBefore: event.integrityBefore,
                integrityAfter: event.integrityAfter,
                residualStrengthBefore: event.residualStrengthBefore,
                residualStrengthAfter: event.residualStrengthAfter,
                failureModeRawValue: event.failureMode?.rawValue,
                detachedComponentIDs: event.detachedComponentIDs,
                massPropertiesRevision: event.massPropertiesRevision,
                rotorThrustFactors: Dictionary(
                    vehicleRotorModel.rotors.map { ($0.slot, $0.thrustFactor) },
                    uniquingKeysWith: { _, latest in latest }
                ),
                reason: event.reason
            )
            recordMissionReplayEvent(
                replayType,
                message: "\(event.reason)\(subject)",
                position: event.worldPoint,
                damage: payload
            )
        }
    }

    private func collisionEmergencyAction(for tier: ImpactOutcomeTier) -> CollisionEmergencyAction {
        switch tier {
        case .lightTouch:
            return .none
        case .scrape:
            return .slowDown
        case .heavyImpact:
            return .avoid
        case .criticalImpact:
            return .avoid
        }
    }

    /// Post-impact internal failures — since the impulse rework this is the
    /// ONLY collision path that cuts signal/video: a static overlay now means
    /// the radio actually died, not "the hit was hard". Proximity damage has
    /// already reduced internal-component integrity in the graph; destroyed
    /// or heavily damaged electronics produce their functional effect here.
    private func evaluateImpactInternalFailures(_ report: ImpactReport) {
        // Radio: destroyed → immediate link loss; badly damaged → a chance,
        // growing as integrity drops.
        if signalLossCause == nil {
            let radioIntegrity = componentGraph.integrity(id: "radio")
            let radioWasDamaged = report.damage.contains { $0.componentID == "radio" }
            let radioFailed = radioIntegrity <= 0.05 ||
                (radioWasDamaged && radioIntegrity < 0.45 && componentFailureRuntime.chance(
                    probability: (0.45 - radioIntegrity) * 0.8
                ))
            if radioFailed {
                signalLossCause = .impactDamage
                enterSignalLostState(cause: .impactDamage)
            }
        }

        // Flight-controller/power effects are enforced centrally by
        // `enforceComponentFunctionalState`, avoiding duplicate events and
        // a second, competing disarm path.
    }

    private func obstacleImpactClass(for source: String?) -> ObstacleImpactClass {
        let token = (source ?? "").lowercased()
        if token.hasPrefix("tree.") {
            return .foliage
        }
        if token.hasPrefix("rock.") || token.hasPrefix("crate.") {
            return .softSurface
        }
        return .hardSurface
    }

    /// The material duration is the ceiling for a genuinely violent hit; a tier that only just
    /// cleared `.lightTouch` (a graze, a slow scrape settling against a trunk) gets a much
    /// shorter cooldown instead of the same flat material duration — otherwise a single scrape
    /// blocks the *same ongoing contact* from registering again for most of a second, which is
    /// exactly what made sustained light contact (drifting into a tree, settling against a wall)
    /// barely damage anything: one small tick, then silence while the aircraft is still touching
    /// it. `.lightTouch` itself never reaches this function (see call sites' `tier != .lightTouch`
    /// guard) — it never needs a cooldown since it does no damage to rate-limit in the first place.
    private func collisionCooldownDuration(for source: String?, tier: ImpactOutcomeTier) -> Float {
        let materialDuration: Float
        switch obstacleImpactClass(for: source) {
        case .foliage:
            materialDuration = 0.18
        case .softSurface:
            materialDuration = 0.34
        case .hardSurface:
            materialDuration = 0.70
        }
        switch tier {
        case .lightTouch:
            return 0.0
        case .scrape:
            return materialDuration * 0.18
        case .heavyImpact:
            return materialDuration * 0.55
        case .criticalImpact:
            return materialDuration
        }
    }

    /// Scripted-event crash (mission scenario `forcedCrashRequired`, payload
    /// proximity events) — NOT reachable from physical collisions anymore;
    /// those go through `applyImpactConsequences`, where signal loss only
    /// follows an actual radio failure.
    private func applySevereCollisionConsequences(source: String?) {
        lastCollisionSource = source ?? lastCollisionSource
        collisionAftermathState = .damaged
        signalLossCause = .impactDamage
        enterSignalLostState(cause: .impactDamage)
        damageEventRecorder.record(
            timestamp: TimeInterval(simulationTime),
            type: .controlAuthorityLost,
            reason: source ?? "scripted_control_loss"
        )
        disarm(forceEmergency: true, preserveCrashDynamics: false)
        updateControlValues({ values in
            values.throttle = 0.0
        }, markManual: false)
    }

    /// Real, localized strikes rather than the old full-screen sun-intensity flash (removed from
    /// DroneSceneController's `updateWeatherAnimation`) — minutes apart per the user's spec ("от
    /// 60 до 600 секунд"), at a random point near the drone, with a small chance of actually
    /// hitting it.
    private func updateThunderstormLightning(deltaTime: Float) {
        guard weather.preset == .thunderstorm else {
            return
        }
        nextLightningStrikeCountdown -= deltaTime
        guard nextLightningStrikeCountdown <= 0 else {
            return
        }
        nextLightningStrikeCountdown = Float.random(in: 60...600)

        // Same non-zero-floor pattern as the visual darkening elsewhere in this preset — a
        // freshly-picked storm (intensity 0) still carries a real, if smaller, chance of a hit.
        let hitChance = 0.05 + weather.normalizedIntensity * 0.05
        let isHit = Float.random(in: 0...1) < hitChance

        let impactPosition: SCNVector3
        let boltHeight: Float
        if isHit {
            impactPosition = SCNVector3(state.position.x, state.position.y, state.position.z)
            boltHeight = max(40.0, state.position.y + 45.0)
            applyLightningStrikeDamage()
        } else {
            let radius = Float.random(in: 30...220)
            let angle = Float.random(in: 0...(2.0 * Float.pi))
            impactPosition = SCNVector3(
                state.position.x + cos(angle) * radius,
                0.0,
                state.position.z + sin(angle) * radius
            )
            boltHeight = Float.random(in: 50...75)
        }

        if !performancePolicy.stopRendering {
            sceneController.triggerLightningStrike(impactPosition: impactPosition, boltHeight: boltHeight)
        }
    }

    /// A struck aircraft takes real damage ("шанс никогда же не равен 0... приведет к
    /// поломке") — reuses the same collision-damage pipeline as a physical impact rather than
    /// inventing a separate one.
    private func applyLightningStrikeDamage() {
        damageState = damageState.applyingCollisionDamage(impactEnergy: 9.0)
        synchronizeLegacyDamageIntoGraph(reason: "lightning_strike")
        lastCollisionSource = "lightning_strike"
        collisionAftermathState = .damaged
        impactSeverityAccumulator = max(impactSeverityAccumulator, 2.0)
        state.angularVelocity += SIMD3<Float>(
            Float.random(in: -0.8...0.8),
            Float.random(in: -0.4...0.4),
            Float.random(in: -0.8...0.8)
        )
    }

    private func resolveObstaclePenetration(using analysis: CollisionAnalysisSnapshot) -> Bool {
        let penetration = max(0.0, -analysis.nearestObstacleDistance)
        guard penetration > 0.0001,
              let obstacleID = analysis.nearestObstacleID,
              let obstacle = sceneController.obstacle(for: obstacleID) else {
            return false
        }

        let normal: SIMD3<Float>
        if let contactNormal = analysis.contactNormal,
           simd_length_squared(contactNormal) > 0.0001 {
            normal = simd_normalize(contactNormal)
        } else {
            normal = horizontalPushNormal(awayFrom: obstacle)
        }

        let orientation = attitudeQuaternion(of: state)
        let fallback = VehicleContactSphere(
            componentID: componentGraph.component(id: "frame") != nil ? "frame" : "fuselage",
            offset: .zero,
            radius: max(0.05, selectedDroneProfile.collisionRadius)
        )
        let sphere = (vehicleContactProfile.spheres.isEmpty ? [fallback] : vehicleContactProfile.spheres)
            .min { lhs, rhs in
                let lhsCenter = lhs.worldCenter(position: state.position, orientation: orientation)
                let rhsCenter = rhs.worldCenter(position: state.position, orientation: orientation)
                return simd_distance_squared(lhsCenter, obstacle.center) <
                    simd_distance_squared(rhsCenter, obstacle.center)
            } ?? fallback
        let center = sphere.worldCenter(position: state.position, orientation: orientation)
        let contactPoint = center - normal * sphere.radius
        let report = impactResolutionService.resolvePenetration(
            penetrationDepth: penetration,
            contactNormal: normal,
            contactPoint: contactPoint,
            obstacle: obstacle,
            componentID: sphere.componentID,
            sphereRadius: sphere.radius,
            state: &state,
            graph: &componentGraph,
            massProperties: vehicleMassProperties,
            airframeClass: selectedDroneProfile.airframeClass,
            rotorsSpinning: state.throttle > 0.05 && isArmed,
            deltaTime: 1.0 / 60.0,
            applyDamage: collisionCooldown <= 0.0,
            restingSpeedThreshold: crashResolutionRestingSpeedThreshold
        )
        applyImpactConsequences(report)
        if report.tier != .lightTouch, collisionCooldown <= 0.0 {
            collisionCooldown = collisionCooldownDuration(for: report.obstacleSource, tier: report.tier)
        }
        return true
    }

    private func horizontalPushNormal(awayFrom obstacle: CollisionObstacle) -> SIMD3<Float> {
        var away = SIMD3<Float>(
            state.position.x - obstacle.center.x,
            0.0,
            state.position.z - obstacle.center.z
        )

        if simd_length_squared(away) < 0.0001 {
            let fallback = SIMD3<Float>(state.velocity.x, 0.0, state.velocity.z)
            if simd_length_squared(fallback) > 0.0001 {
                away = simd_normalize(fallback)
            } else {
                away = SIMD3<Float>(0.0, 0.0, 1.0)
            }
        } else {
            away = simd_normalize(away)
        }

        return away
    }

    private func applyPayloadSelfInteractionIfNeeded(deltaTime: Float) {
        guard payloadSelfInteractionTimer > 0.0, payloadSelfInteractionSeverity > 0.0 else {
            payloadSelfInteractionTimer = 0.0
            payloadSelfInteractionSeverity = 0.0
            payloadControlPenalty = 0.0
            return
        }

        payloadSelfInteractionTimer = max(0.0, payloadSelfInteractionTimer - deltaTime)
        let envelope = (payloadSelfInteractionTimer / 3.4).clamped(to: 0.0...1.0)
        let intensity = payloadSelfInteractionSeverity * envelope
        let phase = simulationTime * 7.0

        state.angularVelocity.z += sin(phase) * intensity * 0.30
        state.angularVelocity.x += cos(phase * 0.7) * intensity * 0.10
        state.orientation.z += sin(phase * 0.9) * intensity * 0.010
        state.orientation.x += cos(phase * 0.8) * intensity * 0.004
        state.velocity.y += sin(phase * 1.2) * intensity * 0.06
        let activePenalty = payloadControlPenalty * envelope
        if activePenalty > 0.05 {
            updateControlValues({ values in
                let rollLimit = Double(max(6.0, 18.0 * (1.0 - activePenalty)))
                let pitchLimit = Double(max(6.0, 18.0 * (1.0 - activePenalty)))
                values.roll = values.roll.clamped(to: -rollLimit...rollLimit)
                values.pitch = values.pitch.clamped(to: -pitchLimit...pitchLimit)
                values.throttle = max(0.18, values.throttle * Double(1.0 - activePenalty * 0.30))
            }, markManual: false)
        }

        if payloadSelfInteractionTimer <= 0.0 {
            payloadSelfInteractionSeverity = 0.0
            payloadControlPenalty = 0.0
        }
    }

    private func handleAutoCollisionInterventions(deltaTime: Float) {
        guard mode.isAutoControlled else {
            return
        }

        if isMultirotorMarkerRouteCollisionManagedByPlanner {
            return
        }

        switch collisionAnalysis.emergencyAction {
        case .none, .slowDown:
            return
        case .hover:
            setFlightMode(.hover, reason: "collision_intervention_hover")
            lockControlsToCurrentState(
                overrideThrottle: Double(max(resolvedFlightBaseline(for: .hover).hoverLockThrottle, state.throttle))
            )
            if selectedDroneProfile.airframeClass == .hybridVTOL {
                updateControlValues({ values in
                    values.roll = 0.0
                    values.pitch = 0.0
                    values.vtolTransitionLever = -1.0
                }, markManual: false)
            }
        case .avoid:
            guard let obstacleID = collisionAnalysis.nearestObstacleID,
                  let obstacle = sceneController.obstacleCenter(for: obstacleID) else {
                return
            }

            if selectedDroneProfile.airframeClass == .hybridVTOL {
                let planarOffset = SIMD2<Float>(
                    state.position.x - obstacle.x,
                    state.position.z - obstacle.z
                )
                let fallbackAway = SIMD2<Float>(-sin(state.orientation.z), -cos(state.orientation.z))
                let awayPlanar = simd_length(planarOffset) > 0.01
                    ? simd_normalize(planarOffset)
                    : fallbackAway
                let avoidAltitude = max(homePosition.y + 2.4, state.position.y)
                let avoidTarget = clampToWorldBounds(SIMD3<Float>(
                    state.position.x + awayPlanar.x * 4.0,
                    avoidAltitude,
                    state.position.z + awayPlanar.y * 4.0
                ))
                let avoidContext = AutopilotTrackingContext(
                    state: state,
                    physicalState: physicalState,
                    target: avoidTarget,
                    targetAltitude: avoidTarget.y,
                    speedScale: 0.36,
                    yawAlignToHome: false,
                    yawOverrideRadians: state.orientation.z,
                    deltaTime: deltaTime,
                    flightBaseline: resolvedFlightBaseline(for: .hover)
                )
                applyHybridVTOLHoverAutopilotCommand(
                    context: avoidContext,
                    target: avoidTarget,
                    targetAltitude: avoidTarget.y,
                    speedScale: 0.36,
                    yawOverrideRadians: state.orientation.z,
                    vtolTransitionLever: state.vtolTransitionProgress > 0.08 ? -1.0 : 0.0,
                    minimumThrottle: resolvedFlightBaseline(for: .hover).hoverLockThrottle,
                    reason: "vtol_collision_avoidance_hover",
                    deltaTime: deltaTime
                )
                return
            }

            let away = simd_normalize(state.position - obstacle)
            updateControlValues({ values in
                values.x += Double(away.x * 1.4)
                values.z += Double(away.z * 1.4)
                values.throttle = max(
                    values.throttle,
                    Double(resolvedFlightBaseline(for: mode).hoverLockThrottle)
                )
            }, markManual: false)
        case .emergencyStop:
            activateEmergencyStop()
        }
    }

    private var isMultirotorMarkerRouteCollisionManagedByPlanner: Bool {
        selectedDroneProfile.airframeClass == .multirotor &&
            mode == .autoPath &&
            targetMarkerState != nil &&
            activeRouteTargetSource != .none
    }

    private func applyResolvedFlightControls(
        deltaTime: Float,
        controlState: ResolvedControlState
    ) {
        guard canControlLocalVehicle, !isControlLinkFailsafeActive else { return }

        // hybridVTOL transition lever: a raw held-key input, not routed through
        // the assist/marker-guidance pipeline below (keyboard-only this pass;
        // ignored entirely by non-hybridVTOL physics).
        controlValues.vtolTransitionLever = Double(keyboardInputService.currentVTOLTransitionLever())

        // P2P 0.7: existing DroneState represents the local pilot vehicle only
        // until multi-state network physics is introduced.
        let inputState = buildFlightInputState(from: controlState)
        let routingContext = buildFlightControlRoutingContext()
        let route = flightControlRouter.route(
            inputState: inputState,
            context: routingContext,
            deltaTime: deltaTime
        )
        flightControlDiagnostics = flightControlRouter.diagnostics(
            authority: route.authority,
            inputState: inputState,
            context: routingContext
        )
        let effectiveControlMode = resolvedFlightControlMode(for: route.authority)

        let maxAltitude = Double(terrain.maxFlightAltitude)
        let effectiveAxis = route.axisInput
        let tailsitterHoverControlsActive = selectedDroneProfile.airframeStyle == .tailsitterVTOL &&
            state.vtolTransitionProgress < 0.25
        let tailsitterHoverTurnIntent = tailsitterHoverControlsActive ? -effectiveAxis.strafe : 0.0
        manualYawIntent = (route.yawInput.intent + tailsitterHoverTurnIntent).clamped(to: -1.0...1.0) *
            (route.yawInput.speedBoost ? 1.35 : 1.0)

        let hasEffectiveYawInput = abs(manualYawIntent) > 0.001
        let hasEffectiveInput =
            abs(effectiveAxis.forward) > 0.001 ||
            abs(effectiveAxis.strafe) > 0.001 ||
            abs(effectiveAxis.vertical) > 0.001 ||
            hasEffectiveYawInput
        let hasVTOLTransitionInput = abs(controlValues.vtolTransitionLever) > 0.05
        let shouldExitHoverForManualAuthority = selectedDroneProfile.airframeStyle == .tailsitterVTOL
            ? (hasEffectiveInput || hasVTOLTransitionInput)
            : true

        if route.authority == .manual, mode == .hover, shouldExitHoverForManualAuthority {
            setFlightMode(.manual, reason: "manual_input_exit_hover")
        }

        if route.shouldCancelMarkerGuidance {
            cancelTargetMarkerAutoNavigation()
            if mode == .autoPath {
                setFlightMode(.manual, reason: "marker_guidance_cancelled")
            }
        }

        if route.shouldAttemptMarkerGuidance,
           selectedDroneProfile.airframeClass == .multirotor {
            _ = applyMultirotorTargetMarkerGuidance(deltaTime: deltaTime)
            return
        }

        if selectedDroneProfile.airframeClass == .fixedWing || selectedDroneProfile.airframeClass == .hybridVTOL {
            fixedWingAssistUsesTargetYawWhileManual = false

            if route.authority == .markerGuidance,
               targetMarkerState != nil {
                if selectedDroneProfile.airframeClass == .hybridVTOL,
                   activeRouteTargetSource != .mission,
                   hybridVTOLMarkerGuidanceReachedTarget() {
                    finishTargetMarkerAutoNavigation()
                    return
                }
                if let output = applyFixedWingMarkerGuidance(deltaTime: deltaTime),
                   output.hasCompletedRoute,
                   activeRouteTargetSource != .mission {
                    finishTargetMarkerAutoNavigation()
                }
                if selectedDroneProfile.airframeClass == .hybridVTOL,
                   activeRouteTargetSource != .mission,
                   hybridVTOLMarkerGuidanceReachedTarget() {
                    finishTargetMarkerAutoNavigation()
                }
                return
            }

            let wing = selectedDroneProfile.fixedWingParameters ?? FixedWingParameters(
                family: .conventionalSurvey,
                minSustainableSpeedMps: 10.0,
                cruiseSpeedMps: 17.0,
                climbSpeedMps: 13.0,
                stallWarningSpeedMps: 9.0,
                waypointAcceptanceRadiusMeters: 9.0,
                nominalTurnRateDegPerSec: 9.0,
                bankResponseGain: 0.72,
                climbResponseGain: 0.64,
                descentResponseGain: 0.54,
                dragFactor: 1.0,
                throttleResponseGain: 0.64,
                turnAuthority: 0.64,
                maxBankAngleDeg: 38.0
            )
            let currentHorizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
            let speedRatioUpperBound: Float = selectedDroneProfile.airframeStyle == .tailsitterVTOL ? 1.0 : 1.35
            let speedRatio = (currentHorizontalSpeed / max(wing.cruiseSpeedMps, 0.1)).clamped(to: 0.55...speedRatioUpperBound)
            let speedRatioDouble = Double(speedRatio)
            // Stall-recovery throttle bias assumes low horizontal speed means
            // "about to stall, add power" — true for a conventional fixed-wing
            // aircraft, but a hybridVTOL hovering (or a tailsitter sitting
            // nose-up) is *supposed* to read near-zero horizontal speed while
            // perfectly safe, rotor/hover-borne. Without gating, this fought
            // the pilot's own throttle-down input every tick (Q barely moved
            // the number, any other key let it climb back) and the resulting
            // thrust fighting its own correction is what read as continuous
            // shake. Scale by how much of the weight the wing is actually
            // carrying (0 in hover, 1 once genuinely wing-borne) — unchanged
            // for conventional fixedWing, which doesn't populate this field
            // and always reads 1.0 here.
            let wingBorneFraction: Double = selectedDroneProfile.airframeClass == .hybridVTOL
                ? Double(state.vtolWingborneBlend)
                : 1.0
            let stallBias = Double(max(0.0, wing.stallWarningSpeedMps - currentHorizontalSpeed)) * 0.018 * Double(deltaTime) * wingBorneFraction
            let rollGain = Double((effectiveControlMode == .acro ? 58.0 : 30.0) * wing.bankResponseGain) * speedRatioDouble
            let pitchAuthority = Double(effectiveControlMode == .acro ? 50.0 : 24.0)
            let pitchResponseGain = Double(effectiveAxis.forward < 0.0 ? wing.climbResponseGain : wing.descentResponseGain)
            let pitchGain = pitchAuthority * pitchResponseGain * Double(max(0.74, speedRatio))
            let rollLimit = Double(wing.maxBankAngleDeg)
            let pitchLimit = 28.0
            let throttleDelta = Double(effectiveAxis.vertical) * Double((effectiveAxis.speedBoost ? 0.54 : 0.30) * wing.throttleResponseGain) * Double(deltaTime)
            let rollCommand = tailsitterHoverControlsActive
                ? 0.0
                : (-Double(effectiveAxis.strafe) * rollGain).clamped(to: -rollLimit...rollLimit)
            let pitchCommand = (-Double(effectiveAxis.forward) * pitchGain).clamped(to: -pitchLimit...pitchLimit)
            let manualThrottle = (controlValues.throttle + throttleDelta + stallBias).clamped(to: 0.0...1.0)
            let liveTurnOverride = (!tailsitterHoverControlsActive && abs(effectiveAxis.strafe) > 0.001) || hasEffectiveYawInput
            let liveAltitudeOverride = abs(effectiveAxis.forward) > 0.001 || abs(effectiveAxis.vertical) > 0.001

            // Captured unconditionally (not just in the manual/assist branches
            // below) so the assisted launch corridor can read live stick
            // input even while `mode == .takeoff` still owns `controlValues`.
            fixedWingManualRollCommandDegrees = Float(rollCommand)
            fixedWingManualTurnInputActive = liveTurnOverride

            if liveTurnOverride {
                registerFixedWingAssistOverride(.turn)
            }
            if liveAltitudeOverride {
                registerFixedWingAssistOverride(.altitude)
            }

            let turnOverrideActive = liveTurnOverride || fixedWingAssistTurnOverrideTimeRemaining > 0.0
            let altitudeOverrideActive = liveAltitudeOverride || fixedWingAssistAltitudeOverrideTimeRemaining > 0.0

            if fixedWingAssistState.mode != .manual, mode == .manual {
                setFixedWingGuidanceSource(.none, reason: "fixed_wing_assist_active")
                let assistWaypoint = resolvedFixedWingAssistWaypoint()
                let guidanceSnapshot = fixedWingAssistState.mode == .waypointIntercept
                    ? fixedWingAssistFlyByGuidanceSnapshot(wing: wing)
                    : nil
                let assistDebugLeg = (
                    start: guidanceSnapshot?.currentLegStart ?? fixedWingAssistSelectedRouteLeg().start,
                    end: guidanceSnapshot?.currentLegEnd ?? fixedWingAssistSelectedRouteLeg().end
                )
                let interceptTarget = guidanceSnapshot?.guidanceTarget ?? assistWaypoint?.position
                let captureTarget = guidanceSnapshot?.captureTarget ?? assistWaypoint?.position

                if let assistOutput = fixedWingAssistController.update(
                    assistState: fixedWingAssistState,
                    aircraftState: state,
                    wing: wing,
                    baseline: resolvedFlightBaseline(for: .manual),
                    currentControls: controlValues,
                    interceptTarget: interceptTarget,
                    captureTarget: captureTarget,
                    interceptDebugContext: FixedWingAssistInterceptDebugContext(
                        activeTargetSource: fixedWingAssistInterceptDebugSource(),
                        segmentCountAfterValidation: fixedWingValidatedMissionSegmentCount(),
                        activeRouteIncludesHome: fixedWingAssistActiveRouteIncludesHome(),
                        selectedWaypointID: assistWaypoint?.id,
                        guidanceTargetType: guidanceSnapshot?.guidanceMode ?? "selected_waypoint",
                        guidanceTargetPoint: interceptTarget,
                        currentLegStart: assistDebugLeg.start,
                        currentLegEnd: assistDebugLeg.end
                    ),
                    turnOverrideActive: turnOverrideActive,
                    altitudeOverrideActive: altitudeOverrideActive
                ) {
                    let previousAssistState = fixedWingAssistState
                    let captureTransitionOccurred = !previousAssistState.interceptCompleted && assistOutput.state.interceptCompleted
                    fixedWingAssistState = assistOutput.state
                    applyFixedWingAssistFlyBySnapshot(guidanceSnapshot, to: &fixedWingAssistState)
                    syncFixedWingAssistSelection()

                    var flyByHandoffCompleted = false
                    if fixedWingAssistState.mode == .waypointIntercept,
                       fixedWingAssistState.autoAdvanceEnabled,
                       guidanceSnapshot?.shouldHandoffToNext == true,
                       let nextWaypointIndex = resolvedFixedWingAssistNextWaypointIndex(
                           activeIndex: previousAssistState.activeWaypointIndex,
                           options: fixedWingAssistWaypointOptions
                       ) {
                        flyByHandoffCompleted = performFixedWingAssistFlyByHandoff(
                            to: nextWaypointIndex,
                            options: fixedWingAssistWaypointOptions
                        )
                    }

                    if !previousAssistState.interceptCompleted,
                       fixedWingAssistState.interceptCompleted,
                       let completedWaypointID = fixedWingAssistState.selectedWaypointID,
                       !fixedWingAssistState.capturedWaypointIDs.contains(completedWaypointID) {
                        fixedWingAssistState.capturedWaypointIDs.append(completedWaypointID)
                    }
                    var waypointChanged = flyByHandoffCompleted
                    if flyByHandoffCompleted {
                        // The next simulation tick computes guidance for the
                        // new waypoint before issuing its control command.
                    } else if captureTransitionOccurred {
                        waypointChanged = handleFixedWingAssistCaptureCompletion()
                    } else if fixedWingAssistState.interceptCompleted {
                        waypointChanged = updatePendingFixedWingAutoAdvanceIfNeeded()
                    }
                    if !waypointChanged {
                        refreshFixedWingAssistRuntimeDebugState(
                            precomputedGuidanceSnapshot: guidanceSnapshot,
                            recomputeGuidance: false
                        )
                    }
                    fixedWingAssistUsesTargetYawWhileManual = !turnOverrideActive
                    if let reason = assistOutput.transitionReason,
                       !captureTransitionOccurred {
                        fixedWingLastTransitionReason = reason
                    }

                    let desiredRoll = turnOverrideActive
                        ? (liveTurnOverride ? rollCommand : controlValues.roll)
                        : Double(assistOutput.rollDegrees)
                    let desiredPitch = altitudeOverrideActive
                        ? (liveAltitudeOverride ? pitchCommand : controlValues.pitch)
                        : Double(assistOutput.pitchDegrees)
                    let desiredThrottle = altitudeOverrideActive
                        ? (liveAltitudeOverride ? manualThrottle : controlValues.throttle)
                        : Double(assistOutput.throttle)
                    let altitudeTarget = assistOutput.state.mode == .altitudeHold || assistOutput.state.mode == .waypointIntercept
                        ? Double(assistOutput.state.targetAltitudeMeters ?? state.position.y)
                        : Double(state.position.y)

                    updateControlValues({ values in
                        values.throttle = desiredThrottle.clamped(to: 0.0...1.0)
                        values.roll = desiredRoll.clamped(to: -rollLimit...rollLimit)
                        values.pitch = desiredPitch.clamped(to: -pitchLimit...pitchLimit)
                        values.yaw = turnOverrideActive
                            ? Double(state.orientation.z.radiansToDegrees)
                            : Double(assistOutput.yawDegrees)
                        values.y = altitudeTarget.clamped(to: 0.0...maxAltitude)
                    }, markManual: false)
                    return
                }
            }

            guard hasEffectiveInput else {
                return
            }
            setFixedWingGuidanceSource(.none, reason: "manual_fixed_wing_input")
            updateControlValues({ values in
                values.throttle = manualThrottle
                values.roll = rollCommand
                values.pitch = pitchCommand
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                values.y = state.position.y > 0.05
                    ? Double(state.position.y).clamped(to: 0.0...maxAltitude)
                    : values.y.clamped(to: 0.0...maxAltitude)
            }, markManual: false)
            return
        }

        let climb = effectiveAxis.vertical * (effectiveAxis.speedBoost ? 5.4 : 3.0) * deltaTime
        let pitchScale: Float = effectiveControlMode == .acro ? 52.0 : 28.0
        let rollScale: Float = effectiveControlMode == .acro ? 52.0 : 26.0

        updateControlValues({ values in
            values.y = (values.y + Double(climb)).clamped(to: 0.0...maxAltitude)

            let verticalThrottleDelta = Double(effectiveAxis.vertical) * (effectiveAxis.speedBoost ? 0.40 : 0.26) * Double(deltaTime)
            values.throttle = (values.throttle + verticalThrottleDelta).clamped(to: 0.0...1.0)
            values.yaw = Double(state.orientation.z.radiansToDegrees)

            switch effectiveControlMode {
            case .stabilized, .hoverAssist:
                // W must command forward acceleration for multirotors (nose down => negative pitch in this frame convention).
                values.pitch = Double((-effectiveAxis.forward * pitchScale).clamped(to: -36.0...36.0))
                values.roll = Double((-effectiveAxis.strafe * rollScale).clamped(to: -36.0...36.0))
            case .acro:
                values.pitch = Double((-effectiveAxis.forward * pitchScale).clamped(to: -82.0...82.0))
                values.roll = Double((-effectiveAxis.strafe * rollScale).clamped(to: -82.0...82.0))
            }
        }, markManual: false)
    }

    private func processInputActions(using controlState: ResolvedControlState) {
        // Reset is a meta/administrative command ("give up, start over"), not a flight-control
        // input — it must never be swallowed by signal-loss/failsafe input blocking below, or the
        // player has no way out of a stuck sequence (e.g. a fixed-wing failsafe that can't find
        // ground to land on). Checked and handled unconditionally, before the interaction gate.
        if controlState.actions.contains(.requestReset) {
            reset()
            return
        }

        guard !signalState.isInteractionBlocking, !isControlLinkFailsafeActive else {
            return
        }

        // A real hose sprays only while the trigger is physically held, not "toggle it on and
        // walk away" — tracked every tick from the held-key state, not the one-shot action queue.
        // The agricultural sprayer reuses the same physical trigger; whichever payload is
        // actually mounted reacts, the other no-ops on its own availability guard.
        setHoseSpraying(controlState.isHoseSprayHeld)
        setAgriculturalSprayerSpraying(controlState.isHoseSprayHeld)

        for action in controlState.actions {
            switch action {
            case .requestHover:
                hover()
            case .requestReset:
                reset()
            case .dropPayload:
                releasePayload()
            case .armAircraft:
                arm()
            case .disarmAircraft:
                disarm()
            case .launchAircraft:
                // ⌘E: hand-throw / catapult release for assisted-launch
                // fixed wings. Arms the airframe first if needed, so the
                // whole launch is a single keystroke from the operator view.
                if selectedDroneProfile.airframeClass == .fixedWing,
                   activeLaunchMode().requiresLaunchObject {
                    if !isArmed {
                        arm()
                    }
                    if canInitiateTakeoffCommand {
                        takeoff()
                    }
                }
            case .selectFreeCamera:
                setCameraMode(.free)
            case .selectChaseCamera:
                setCameraMode(.follow)
            case .selectOrbitCamera:
                setCameraMode(.orbit)
            case .selectFPVCamera:
                setCameraMode(.fpv)
            case .selectTopCamera:
                setCameraMode(.top)
            case .selectPayloadOpticsCamera:
                setCameraMode(.payloadOptics)
            case .selectPayloadCamera:
                setCameraMode(.payload)
            case .toggleFPV:
                setCameraMode(cameraConfiguration.mode == .fpv ? .follow : .fpv)
            case .toggleTopView:
                setCameraMode(cameraConfiguration.mode == .top ? .follow : .top)
            case .toggleMissionMap:
                toggleMissionMap()
            case .togglePayloadPanel:
                togglePayloadPanel()
            case .toggleTerrainMap:
                toggleTerrainMap()
            case .toggleCompassOverlay:
                toggleCompassOverlay()
            case .toggleThermalOverlay:
                toggleThermalOverlay()
            case .toggleDamageOverlay:
                toggleDamageOverlay()
            case .selectThermalPaletteWhiteHot:
                activateThermalPalette(.whiteHot)
            case .selectThermalPaletteBlackHot:
                activateThermalPalette(.blackHot)
            case .selectThermalPaletteIron:
                activateThermalPalette(.iron)
            case .toggleRangefinderArmed:
                toggleRangefinderArmed()
            case .cycleCameraMode:
                cycleCameraMode()
            case .toggleControlPanel:
                toggleControlPanel()
            case .toggleToolPanel:
                toggleToolPanel()
            case .toggleTelemetryHUD:
                toggleCompactTelemetryHUD()
            case .zoomInCamera:
                adjustCameraZoom(inward: true)
            case .zoomOutCamera:
                adjustCameraZoom(inward: false)
            case .resetCameraOrientation:
                syncCameraSystem(resetOrientation: true)
            case .returnHome:
                activateReturnHome()
            case .pauseMission:
                pauseMissionExecution()
            case .resumeMission:
                resumeMissionExecution()
            case .toggleControllerCursor, .openControllerHub,
                 .uiSectionPrevious, .uiSectionNext,
                 .uiPrimary, .uiSecondary,
                 .uiFocusUp, .uiFocusDown, .uiFocusLeft, .uiFocusRight:
                break
            }
        }
    }

    private func applyContinuousCameraLook(
        deltaTime: Float,
        controlState: ResolvedControlState
    ) {
        guard !signalState.isInteractionBlocking else {
            cameraLookVelocity = .zero
            payloadGimbalLookVelocity = .zero
            return
        }

        let speedMultiplier: Float = controlState.precisionMode ? 0.22 : (controlState.boostMode ? 1.85 : 1.0)
        let inputVelocity = SIMD2<Float>(
            Float(controlState.cameraPan),
            Float(controlState.cameraTilt)
        )
        let hasLookInput = abs(controlState.cameraPan) >= 0.001 || abs(controlState.cameraTilt) >= 0.001

        if isHandLaunchPOVActive {
            let targetVelocity = inputVelocity * (92.0 * speedMultiplier * cameraConfiguration.effectiveLookSensitivity)
            let accelerationBlend = (deltaTime * 12.0).clamped(to: 0.0...1.0)
            cameraLookVelocity = simd_mix(
                cameraLookVelocity,
                targetVelocity,
                SIMD2<Float>(repeating: accelerationBlend)
            )
            if !hasLookInput {
                let damping = max(0.0, 1.0 - deltaTime * 9.0)
                cameraLookVelocity *= damping
                if simd_length_squared(cameraLookVelocity) < 0.0001 {
                    cameraLookVelocity = .zero
                }
            }
            payloadGimbalLookVelocity = .zero
            guard simd_length_squared(cameraLookVelocity) > 0.0 else {
                return
            }
            sceneController.applyHandLaunchPOVLook(
                yawDeltaDeg: cameraLookVelocity.x * deltaTime,
                pitchDeltaDeg: cameraLookVelocity.y * deltaTime,
                invertX: cameraConfiguration.invertLookX,
                invertY: cameraConfiguration.invertLookY
            )
            return
        }

        switch cameraConfiguration.mode {
        case .fpv:
            let targetVelocity = inputVelocity * (92.0 * speedMultiplier * cameraConfiguration.effectiveLookSensitivity)
            let accelerationBlend = (deltaTime * 12.0).clamped(to: 0.0...1.0)
            cameraLookVelocity = simd_mix(
                cameraLookVelocity,
                targetVelocity,
                SIMD2<Float>(repeating: accelerationBlend)
            )

            if !hasLookInput {
                let damping = max(0.0, 1.0 - deltaTime * 9.0)
                cameraLookVelocity *= damping
                if simd_length_squared(cameraLookVelocity) < 0.0001 {
                    cameraLookVelocity = .zero
                }
            }

            payloadGimbalLookVelocity = .zero
            guard simd_length_squared(cameraLookVelocity) > 0.0 else {
                return
            }

            sceneController.applyCameraNudge(
                mode: cameraConfiguration.mode,
                yawDeltaDeg: cameraLookVelocity.x * deltaTime,
                pitchDeltaDeg: cameraLookVelocity.y * deltaTime,
                invertX: cameraConfiguration.invertLookX,
                invertY: cameraConfiguration.invertLookY
            )
            return
        case .payloadOptics:
            let targetVelocity = inputVelocity * (118.0 * speedMultiplier * cameraConfiguration.effectiveLookSensitivity)
            let accelerationBlend = (deltaTime * 10.0).clamped(to: 0.0...1.0)
            payloadGimbalLookVelocity = simd_mix(
                payloadGimbalLookVelocity,
                targetVelocity,
                SIMD2<Float>(repeating: accelerationBlend)
            )

            if !hasLookInput {
                let damping = max(0.0, 1.0 - deltaTime * 8.5)
                payloadGimbalLookVelocity *= damping
                if simd_length_squared(payloadGimbalLookVelocity) < 0.0001 {
                    payloadGimbalLookVelocity = .zero
                }
            }

            cameraLookVelocity = .zero
            guard simd_length_squared(payloadGimbalLookVelocity) > 0.0 else {
                return
            }

            let yawSign: Float = cameraConfiguration.invertLookX ? -1.0 : 1.0
            let pitchSign: Float = cameraConfiguration.invertLookY ? -1.0 : 1.0
            if payloadCameraOpticsState.isAvailable {
                adjustPayloadGimbal(
                    yawDeltaDegrees: Double(payloadGimbalLookVelocity.x * deltaTime * yawSign),
                    pitchDeltaDegrees: Double(payloadGimbalLookVelocity.y * deltaTime * pitchSign)
                )
            } else if rangefinderOpticsState.isAvailable {
                adjustRangefinderGimbal(
                    yawDeltaDegrees: Double(payloadGimbalLookVelocity.x * deltaTime * yawSign),
                    pitchDeltaDegrees: Double(payloadGimbalLookVelocity.y * deltaTime * pitchSign)
                )
            } else {
                adjustHoseGimbal(
                    yawDeltaDegrees: Double(payloadGimbalLookVelocity.x * deltaTime * yawSign),
                    pitchDeltaDegrees: Double(payloadGimbalLookVelocity.y * deltaTime * pitchSign)
                )
            }
            return
        case .free, .follow, .orbit, .top, .payload, .spectator:
            cameraLookVelocity = .zero
            payloadGimbalLookVelocity = .zero
            return
        }
    }

    private func nudgeCamera(yawDeg: Float, pitchDeg: Float) {
        sceneController.applyCameraNudge(
            mode: cameraConfiguration.mode,
            yawDeltaDeg: yawDeg * cameraConfiguration.effectiveLookSensitivity,
            pitchDeltaDeg: pitchDeg * cameraConfiguration.effectiveLookSensitivity,
            invertX: cameraConfiguration.invertLookX,
            invertY: cameraConfiguration.invertLookY
        )
    }

    private func syncCameraSystem(from previousMode: CameraMode? = nil, resetOrientation: Bool = false) {
        if let previousMode {
            sceneController.syncCameraTransition(from: previousMode, to: cameraConfiguration.mode)
        }

        if resetOrientation {
            if cameraConfiguration.mode == .payloadOptics {
                resetPayloadGimbalOrientation()
                resetRangefinderGimbalOrientation()
            }
            sceneController.resetCameraOrientation(for: cameraConfiguration.mode)
        }

        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
    }

    private func applyContinuousCameraZoom(deltaTime: Float) {
        let keyboardSnapshot = keyboardInputService.currentInputSnapshot()
        let zoomInActive = keyboardSnapshot.activeContinuousCommands.contains(.zoomIn)
        let zoomOutActive = keyboardSnapshot.activeContinuousCommands.contains(.zoomOut)
        guard zoomInActive != zoomOutActive else {
            return
        }

        let zoomDirection: Double = zoomInActive ? 1.0 : -1.0
        let speedMultiplier: Double = keyboardSnapshot.axisInput.speedBoost || keyboardSnapshot.yawInput.speedBoost || keyboardSnapshot.lookInput.speedBoost
            ? 1.8
            : 1.0

        switch cameraConfiguration.mode {
        case .payloadOptics:
            let zoomUnitsPerSecond = 8.5 * speedMultiplier
            if payloadCameraOpticsState.isAvailable {
                setPayloadZoom(payloadCameraOpticsState.zoomLevel + zoomDirection * Double(deltaTime) * zoomUnitsPerSecond)
            } else if rangefinderOpticsState.isAvailable {
                setRangefinderZoom(rangefinderOpticsState.zoomLevel + zoomDirection * Double(deltaTime) * zoomUnitsPerSecond)
            }
        case .free:
            let zoomStep = 6.5 * speedMultiplier * Double(deltaTime) * Double(cameraConfiguration.free.zoomSensitivity)
            cameraConfiguration.free.distance = (cameraConfiguration.free.distance - Float(zoomDirection * zoomStep))
                .clamped(to: cameraConfiguration.free.minDistance...cameraConfiguration.free.maxDistance)
            sceneController.dollyFreeCamera(by: Float(-zoomDirection * zoomStep))
        case .follow, .orbit:
            let zoomStep = 6.5 * speedMultiplier * Double(deltaTime) * Double(cameraConfiguration.free.zoomSensitivity)
            let prospectiveDistance = cameraConfiguration.cameraDistance - Float(zoomDirection * zoomStep)
            if zoomInActive, prospectiveDistance <= fpvAutoEngageDistance(for: cameraConfiguration.mode) {
                engageFPVFromZoom()
            } else {
                cameraConfiguration.setCameraDistance(prospectiveDistance)
            }
        case .top:
            let zoomStep = 6.5 * speedMultiplier * Double(deltaTime) * Double(cameraConfiguration.free.zoomSensitivity)
            cameraConfiguration.setCameraDistance(
                cameraConfiguration.cameraDistance - Float(zoomDirection * zoomStep)
            )
        case .fpv:
            let fovDelta = Float(zoomDirection * 24.0 * speedMultiplier * Double(deltaTime))
            let prospectiveFov = cameraConfiguration.fov - fovDelta
            if fpvEnteredViaZoomEngage, zoomOutActive, cameraConfiguration.fov >= 109.5, prospectiveFov >= 110.0 {
                exitFPVFromZoom()
            } else {
                cameraConfiguration.fov = prospectiveFov.clamped(to: 30.0...110.0)
            }
        case .payload, .spectator:
            return
        }
    }

    /// How close the chase/orbit camera gets before handing off to FPV — mirrors
    /// `DroneSceneController.updateCameras`'s `chaseDistanceRange`/`orbitDistanceRange` lower
    /// bound exactly (both now a small fraction of the airframe's own size, not a "comfortable
    /// viewing distance"), so holding zoom in actually carries the camera visually into the
    /// airframe — passing through it — right up to the point FPV takes over, rather than
    /// stalling at an earlier, still-external distance and cutting to FPV from there.
    private func fpvAutoEngageDistance(for mode: CameraMode) -> Float {
        let dims = selectedDroneProfile.dimensions
        let subjectScale = max(selectedDroneProfile.collisionRadius * 2.0, max(dims.widthM, dims.lengthM))
        let isFixedWing = selectedDroneProfile.airframeClass == .fixedWing
        return isFixedWing ? max(0.15, subjectScale * 0.16) : max(0.10, subjectScale * 0.14)
    }

    /// Holding zoom-in past the chase camera's closest point hands off to FPV instead of just
    /// sitting at the floor — "keep pressing + until you're inside the aircraft."
    private func engageFPVFromZoom() {
        guard cameraConfiguration.mode != .fpv else { return }
        let previousMode = cameraConfiguration.mode
        lastDistanceCameraMode = previousMode
        fpvEnteredViaZoomEngage = true
        cameraConfiguration.mode = .fpv
        syncCameraSystem(from: previousMode)
        sceneController.beginCameraTransition(from: previousMode)
    }

    /// Mirror of `engageFPVFromZoom`: holding zoom-out past FPV's own widest field of view
    /// leaves FPV for whichever chase/orbit mode it was entered from, picking back up exactly at
    /// the distance it left off at so the reverse transition reads as continuous too.
    private func exitFPVFromZoom() {
        guard cameraConfiguration.mode == .fpv else { return }
        let previousMode = cameraConfiguration.mode
        let targetMode = lastDistanceCameraMode
        fpvEnteredViaZoomEngage = false
        cameraConfiguration.mode = targetMode
        cameraConfiguration.setCameraDistance(fpvAutoEngageDistance(for: targetMode))
        syncCameraSystem(from: previousMode)
        sceneController.beginCameraTransition(from: previousMode)
    }

    private func adjustCameraZoom(inward: Bool) {
        let sign: Float = inward ? -1.0 : 1.0
        let zoomStep = 0.9 * cameraConfiguration.free.zoomSensitivity

        switch cameraConfiguration.mode {
        case .free:
            cameraConfiguration.free.distance = (cameraConfiguration.free.distance + sign * zoomStep)
                .clamped(to: cameraConfiguration.free.minDistance...cameraConfiguration.free.maxDistance)
            sceneController.dollyFreeCamera(by: sign * zoomStep)
        case .follow, .orbit:
            let prospectiveDistance = cameraConfiguration.cameraDistance + sign * zoomStep
            if inward, prospectiveDistance <= fpvAutoEngageDistance(for: cameraConfiguration.mode) {
                engageFPVFromZoom()
            } else {
                cameraConfiguration.setCameraDistance(prospectiveDistance)
            }
        case .top:
            cameraConfiguration.setCameraDistance(cameraConfiguration.cameraDistance + sign * zoomStep)
        case .fpv:
            let prospectiveFov = cameraConfiguration.fov + sign * 1.2
            if fpvEnteredViaZoomEngage, !inward, cameraConfiguration.fov >= 109.5, prospectiveFov >= 110.0 {
                exitFPVFromZoom()
            } else {
                cameraConfiguration.fov = prospectiveFov.clamped(to: 30.0...110.0)
            }
        case .payloadOptics:
            let delta = inward ? 0.5 : -0.5
            if payloadCameraOpticsState.isAvailable {
                setPayloadZoom(payloadCameraOpticsState.zoomLevel + delta)
            } else if rangefinderOpticsState.isAvailable {
                setRangefinderZoom(rangefinderOpticsState.zoomLevel + delta)
            }
        case .payload:
            return
        case .spectator:
            return
        }
    }

    private func updateAutopilotTargets(deltaTime: Float) {
        if !fixedWingAutonomousRouteExecutionEnabled {
            switch mode {
            case .autoPath, .returnHome:
                disengageFixedWingAutonomousRouteExecution(
                    reason: "fixed_wing_autonomous_route_execution_disabled"
                )
                return
            case .manual, .hover, .emergencyStop, .takeoff, .landing:
                break
            }
        }

        switch mode {
        case .autoPath:
            if targetMarkerState == nil {
                updateAutoFlightPath(deltaTime: deltaTime)
            }

        case .returnHome:
            updateReturnHomePath(deltaTime: deltaTime)

        case .hover:
            navigationSnapshot = .idle
            let hoverBaseline = Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle)
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                let throttleTarget = hoverBaseline.clamped(to: 0.0...1.0)
                values.throttle = values.throttle + (throttleTarget - values.throttle) * 0.18
                if selectedDroneProfile.airframeClass == .hybridVTOL {
                    values.vtolTransitionLever = state.vtolTransitionProgress > 0.04 ? -1.0 : 0.0
                }
            }, markManual: false)

        case .emergencyStop:
            navigationSnapshot = .idle
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.y = max(0.0, Double(state.position.y - 0.02))
                values.z = Double(state.position.z)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(0.0, values.throttle - 0.02)
            }, markManual: false)

        case .manual, .takeoff, .landing:
            navigationSnapshot = .idle
            if mode == .takeoff {
                updateFixedWingLaunchSequence(deltaTime: deltaTime)
            } else if mode == .landing {
                updateHybridVTOLLandingCommand(deltaTime: deltaTime)
            }
        }
    }

    private func applyMultirotorTargetMarkerGuidance(deltaTime: Float) -> Bool {
        guard let marker = targetMarkerState else {
            navigationSnapshot = .idle
            return false
        }

        guard canStartTargetMarkerAutoNavigation else {
            cancelTargetMarkerAutoNavigation()
            navigationSnapshot = .idle
            if mode == .autoPath {
                setFlightMode(.manual, reason: "marker_auto_navigation_unavailable")
            }
            return false
        }

        let travelAltitude = targetMarkerTravelAltitude()
        guard let pathTarget = prepareMultirotorMarkerPath(
            marker: marker,
            travelAltitude: travelAltitude
        ) else {
            return false
        }

        if shouldFinishMultirotorMarkerGuidance(marker: marker) {
            navigationSnapshot = .idle
            finishTargetMarkerAutoNavigation()
            return true
        }

        autoNavigationController.cancel()
        let finalGoal = clampToWorldBounds(marker.worldPosition(altitude: travelAltitude))
        let adjustedTarget = multirotorCollisionAvoidanceTarget(
            nominalTarget: pathTarget,
            finalGoal: finalGoal,
            travelAltitude: travelAltitude
        ) ?? pathTarget
        let isAvoidingObstacle = simd_distance(
            SIMD2<Float>(adjustedTarget.x, adjustedTarget.z),
            SIMD2<Float>(pathTarget.x, pathTarget.z)
        ) > 0.05
        applyAutopilotTrackingControl(
            target: adjustedTarget,
            targetAltitude: travelAltitude,
            speedScale: isAvoidingObstacle
                ? min(multirotorMarkerSpeedScale(), 0.72)
                : multirotorMarkerSpeedScale(),
            yawAlignToHome: false,
            deltaTime: deltaTime
        )
        return true
    }

    private func prepareMultirotorMarkerPath(
        marker: TargetMarkerState,
        travelAltitude: Float
    ) -> SIMD3<Float>? {
        let finalGoal = clampToWorldBounds(marker.worldPosition(altitude: travelAltitude))
        autoPathPlanner.updateProgress(
            currentPosition: state.position,
            arrivalRadius: 1.35,
            planarOnly: true
        )

        var replanReason = autoPathPlanner.replanReasonIfNeeded(
            currentPosition: state.position,
            collisionRisk: collisionAnalysis.riskScore,
            deviationTolerance: max(2.2, terrain.worldHalfExtent * 0.025)
        )
        if replanReason == nil,
           collisionAnalysis.riskScore >= 0.42 {
            replanReason = "route_collision_risk"
        }

        if let replanReason,
           shouldRefreshMultirotorMarkerPath(for: replanReason) {
            autoPathPlanner.planIfNeeded(
                start: state.position,
                goal: finalGoal,
                terrain: terrain,
                obstacles: navigationObstaclesIncludingNoFlyZones(),
                droneRadius: selectedDroneProfile.collisionRadius,
                modeTag: activeRouteTargetSource == .mission ? "multirotor_mission_marker" : "multirotor_marker",
                forceRecompute: replanReason != "no_waypoints",
                reason: replanReason
            )
            multirotorMarkerLastPlanTick = simulationTickCounter
            autoPathPlanner.updateProgress(
                currentPosition: state.position,
                arrivalRadius: 1.35,
                planarOnly: true
            )
        }

        navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)

        let finalDistance = marker.distance(from: currentPlanarPosition())
        let plannedTarget = finalDistance <= multirotorMarkerFinalApproachDistance()
            ? finalGoal
            : autoPathPlanner.lookaheadTarget(
                currentPosition: state.position,
                minimumDistance: multirotorMarkerLookaheadDistance()
            )

        guard let plannedTarget else {
            autoNavigationController.cancel()
            let hoverThrottle = Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle)
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.y = Double(max(state.position.y, min(travelAltitude, terrain.maxFlightAltitude - 2.0)))
                values.z = Double(state.position.z)
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                values.throttle = max(values.throttle, hoverThrottle)
            }, markManual: false)
            return nil
        }

        return correctedMultirotorMarkerPathTarget(
            plannedTarget,
            finalGoal: finalGoal,
            currentDistanceToGoal: finalDistance
        )
    }

    private func correctedMultirotorMarkerPathTarget(
        _ plannedTarget: SIMD3<Float>,
        finalGoal: SIMD3<Float>,
        currentDistanceToGoal: Float
    ) -> SIMD3<Float> {
        let plannedDistanceToGoal = simd_distance(
            SIMD2<Float>(plannedTarget.x, plannedTarget.z),
            SIMD2<Float>(finalGoal.x, finalGoal.z)
        )
        let allowedRegression = max(3.0, multirotorMarkerLookaheadDistance() * 0.45)
        guard plannedDistanceToGoal > currentDistanceToGoal + allowedRegression else {
            return plannedTarget
        }

        let directAssessment = autoPathPlanner.assessDirectPath(
            from: state.position,
            to: finalGoal,
            terrain: terrain,
            obstacles: navigationObstaclesIncludingNoFlyZones(),
            droneRadius: selectedDroneProfile.collisionRadius
        )
        if !directAssessment.blocked && directAssessment.maxPenalty < 0.36 {
            return finalGoal
        }

        return plannedTarget
    }

    private func multirotorCollisionAvoidanceTarget(
        nominalTarget: SIMD3<Float>,
        finalGoal: SIMD3<Float>,
        travelAltitude: Float
    ) -> SIMD3<Float>? {
        guard selectedDroneProfile.airframeClass == .multirotor,
              collisionAnalysis.riskScore >= 0.30,
              let obstacleID = collisionAnalysis.nearestObstacleID,
              let obstacle = sceneController.obstacle(for: obstacleID),
              obstacle.source.contains("tree") else {
            multirotorAvoidanceLateralOffset = 0.0
            return nil
        }

        let current = SIMD2<Float>(state.position.x, state.position.z)
        let nominal = SIMD2<Float>(nominalTarget.x, nominalTarget.z)
        let finalPlanar = SIMD2<Float>(finalGoal.x, finalGoal.z)
        var routeVector = nominal - current

        if simd_length_squared(routeVector) < 0.04 {
            routeVector = finalPlanar - current
        }
        if simd_length_squared(routeVector) < 0.04 {
            let planarVelocity = SIMD2<Float>(state.velocity.x, state.velocity.z)
            if simd_length_squared(planarVelocity) > 0.01 {
                routeVector = planarVelocity
            }
        }

        guard simd_length_squared(routeVector) > 0.0001 else {
            return nil
        }

        let routeDirection = simd_normalize(routeVector)
        let sideAxis = SIMD2<Float>(-routeDirection.y, routeDirection.x)
        let forwardWindow = max(10.0, multirotorMarkerLookaheadDistance() + obstacle.radius)
        let immediateRisk = collisionAnalysis.nearestObstacleDistance < 2.4 ||
            collisionAnalysis.riskScore >= 0.55
        let nearbyTrees = sceneController.nearbyEnvironmentObstacles(
            near: state.position,
            radius: max(28.0, forwardWindow + obstacle.radius + 10.0)
        ).filter { $0.source.contains("tree") }

        func routeCoordinates(for tree: CollisionObstacle) -> (along: Float, lateral: Float) {
            let treeVector = tree.planarCenter - current
            return (
                simd_dot(treeVector, routeDirection),
                simd_dot(treeVector, sideAxis)
            )
        }

        let routeThreatened = nearbyTrees.contains { tree in
            let coordinates = routeCoordinates(for: tree)
            let protectedWidth = tree.radius + selectedDroneProfile.collisionRadius + 2.2
            return coordinates.along > -protectedWidth &&
                coordinates.along < forwardWindow &&
                abs(coordinates.lateral) <= protectedWidth
        }

        guard immediateRisk || routeThreatened else {
            multirotorAvoidanceLateralOffset = 0.0
            return nil
        }

        let nearestCoordinates = routeCoordinates(for: obstacle)
        let preferredSign: Float = nearestCoordinates.lateral >= 0.0 ? -1.0 : 1.0
        let sideDistance = max(
            6.0,
            obstacle.radius + selectedDroneProfile.collisionRadius * 2.2 + 3.0
        )
        let remainingDistance = max(2.5, simd_distance(current, finalPlanar))
        let forwardStep = min(
            remainingDistance,
            immediateRisk
                ? max(4.0, min(7.0, nearestCoordinates.along + 2.5))
                : max(4.0, min(8.0, nearestCoordinates.along + 3.0))
        )
        let smallOffset = min(2.4, sideDistance * 0.40)
        let mediumOffset = min(4.2, sideDistance * 0.70)
        let candidateOffsets: [Float] = [
            0.0,
            preferredSign * smallOffset,
            -preferredSign * smallOffset,
            preferredSign * mediumOffset,
            -preferredSign * mediumOffset,
            preferredSign * sideDistance,
            -preferredSign * sideDistance
        ]
        let requiredClearance = max(0.35, selectedDroneProfile.collisionRadius * 0.25)

        func clearance(at point: SIMD2<Float>) -> Float {
            nearbyTrees.reduce(Float.greatestFiniteMagnitude) { partial, tree in
                min(
                    partial,
                    tree.planarSignedDistance(to: point) - selectedDroneProfile.collisionRadius
                )
            }
        }

        func segmentClearance(to target: SIMD2<Float>) -> Float {
            var minimumClearance = Float.greatestFiniteMagnitude
            let segment = target - current
            for sample in [Float(0.20), Float(0.45), Float(0.70), Float(0.95)] {
                minimumClearance = min(
                    minimumClearance,
                    clearance(at: current + segment * sample)
                )
            }
            return minimumClearance
        }

        func candidateScore(offset: Float) -> (target: SIMD2<Float>, clearance: Float, score: Float) {
            let candidate = current +
                routeDirection * forwardStep +
                sideAxis * offset
            let candidateClearance = min(clearance(at: candidate), segmentClearance(to: candidate))
            let clearanceScore = min(candidateClearance, 6.0) * 2.2
            let unsafePenalty = candidateClearance < requiredClearance
                ? (requiredClearance - candidateClearance) * 18.0
                : 0.0
            let centerBonus: Float = abs(offset) < 0.10 && candidateClearance >= requiredClearance + 0.55
                ? 4.0
                : 0.0
            let progressScore = simd_dot(candidate - current, routeDirection) * 0.20 -
                simd_distance(candidate, finalPlanar) * 0.025
            let offsetPenalty = abs(offset) * 0.22
            let preferenceScore: Float = offset.sign == preferredSign.sign ? 0.35 : 0.0
            let holdBonus: Float
            if simulationTickCounter <= multirotorAvoidanceHoldUntilTick {
                let distanceFromHeldOffset = abs(offset - multirotorAvoidanceLateralOffset)
                holdBonus = max(0.0, 2.0 - distanceFromHeldOffset * 0.45)
            } else {
                holdBonus = 0.0
            }

            return (
                target: candidate,
                clearance: candidateClearance,
                score: clearanceScore + centerBonus + progressScore + preferenceScore + holdBonus -
                    offsetPenalty - unsafePenalty
            )
        }

        let scoredCandidates = candidateOffsets.map { offset in
            (offset: offset, result: candidateScore(offset: offset))
        }
        guard let bestCandidate = scoredCandidates.max(by: { $0.result.score < $1.result.score }) else {
            multirotorAvoidanceLateralOffset = 0.0
            return nil
        }

        if abs(bestCandidate.offset) < 0.10,
           bestCandidate.result.clearance >= requiredClearance {
            multirotorAvoidanceLateralOffset = 0.0
            multirotorAvoidanceHoldUntilTick = simulationTickCounter + 8
            return nil
        }

        multirotorAvoidanceLateralOffset = bestCandidate.offset
        multirotorAvoidanceHoldUntilTick = simulationTickCounter + 12
        return clampToWorldBounds(SIMD3<Float>(
            bestCandidate.result.target.x,
            travelAltitude,
            bestCandidate.result.target.y
        ))
    }

    private func shouldRefreshMultirotorMarkerPath(for reason: String) -> Bool {
        if reason == "no_waypoints" {
            return true
        }

        let minimumInterval: UInt64 = (reason == "high_collision_risk" || reason == "route_collision_risk") ? 8 : 18
        guard let lastTick = multirotorMarkerLastPlanTick else {
            return true
        }
        return simulationTickCounter >= lastTick + minimumInterval
    }

    private func multirotorMarkerLookaheadDistance() -> Float {
        let horizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        return (10.0 + horizontalSpeed * 1.2).clamped(to: 10.0...18.0)
    }

    private func multirotorMarkerFinalApproachDistance() -> Float {
        max(7.5, multirotorMarkerLookaheadDistance() * 0.65)
    }

    private func multirotorMarkerSpeedScale() -> Float {
        switch collisionAnalysis.riskScore {
        case 0.72...:
            return 0.62
        case 0.55..<0.72:
            return 0.76
        default:
            return 1.0
        }
    }

    private func shouldFinishMultirotorMarkerGuidance(marker: TargetMarkerState) -> Bool {
        guard activeRouteTargetSource != .mission else {
            return false
        }
        let horizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let verticalSpeed = abs(state.velocity.y)
        let hoverHandoffRadius: Float

        if let dropZone = missionPlanState.dropZone,
           missionPlanState.isDeliveryMissionReady,
           simd_distance(marker.position, dropZone.center) <= 0.001 {
            let releaseRadius = min(dropZone.radius, max(0.8, dropZone.radius * 0.24))
            hoverHandoffRadius = max(0.85, min(1.35, releaseRadius))
        } else {
            hoverHandoffRadius = 0.85
        }

        return marker.distance(from: currentPlanarPosition()) <= hoverHandoffRadius &&
            horizontalSpeed <= 0.95 &&
            verticalSpeed <= 0.55
    }

    private func hybridVTOLMarkerGuidanceReachedTarget() -> Bool {
        guard let marker = targetMarkerState,
              hybridVTOLReadyForPrecisionHover() else {
            return false
        }
        let horizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let verticalSpeed = abs(state.velocity.y)
        return marker.distance(from: currentPlanarPosition()) <= 1.10 &&
            horizontalSpeed <= 1.40 &&
            verticalSpeed <= 0.75
    }

    private func finishTargetMarkerAutoNavigation() {
        navigationSnapshot = .idle
        resetFixedWingAutopilotCommands()
        if selectedDroneProfile.airframeClass == .multirotor {
            hover()
            return
        }
        if selectedDroneProfile.airframeClass == .hybridVTOL {
            hover()
            return
        }

        setFlightMode(.manual, reason: "fixed_wing_marker_target_reached")
        let cruiseThrottle = Double(resolvedFlightBaseline(for: .autoPath).cruiseReferenceThrottle)
        updateControlValues({ values in
            values.x = Double(state.position.x)
            values.z = Double(state.position.z)
            values.y = Double(state.position.y)
            values.roll = 0.0
            values.pitch = 0.0
            values.yaw = Double(state.orientation.z.radiansToDegrees)
            values.throttle = max(cruiseThrottle, values.throttle * 0.96)
        }, markManual: false)
    }

    @discardableResult
    private func applyFixedWingMarkerGuidance(
        deltaTime: Float
    ) -> FixedWingAutopilotOutput? {
        guard let marker = targetMarkerState,
              canStartTargetMarkerAutoNavigation else {
            cancelTargetMarkerAutoNavigation()
            if mode == .autoPath {
                setFlightMode(.manual, reason: "fixed_wing_marker_guidance_unavailable")
            }
            return nil
        }

        let targetAltitude = targetMarkerTravelAltitude()
        let markerWorld = marker.worldPosition(altitude: targetAltitude)
        let guidanceSource: FixedWingGuidanceSource = activeRouteTargetSource == .mission ? .mission : .marker
        setFixedWingGuidanceSource(guidanceSource, reason: "fixed_wing_route_guidance_active")

        if activeRouteTargetSource != .mission {
            var recomputeReason = "fixed_wing_marker_route"
            var forceReplan = false
            if let reason = autoPathPlanner.replanReasonIfNeeded(
                currentPosition: state.position,
                collisionRisk: collisionAnalysis.riskScore,
                deviationTolerance: max(5.5, terrain.worldHalfExtent * 0.05)
            ) {
                recomputeReason = reason
                forceReplan = true
            }

            autoPathPlanner.planIfNeeded(
                start: state.position,
                goal: markerWorld,
                terrain: terrain,
                obstacles: navigationObstaclesIncludingNoFlyZones(),
                droneRadius: selectedDroneProfile.collisionRadius,
                modeTag: "fixed_wing_marker",
                forceRecompute: forceReplan,
                reason: recomputeReason
            )
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
        }

        return applyAutopilotTrackingControl(
            target: markerWorld,
            targetAltitude: targetAltitude,
            speedScale: collisionAnalysis.riskScore >= 0.55 ? 0.54 : 1.0,
            yawAlignToHome: false,
            deltaTime: deltaTime
        )
    }

    private func updateAutoFlightPath(deltaTime: Float) {
        if autoFlightGoal == nil {
            autoFlightGoal = nextAutoPatrolGoal(resetCycle: true)
            autoPathPlanner.invalidate()
        }

        guard let goal = autoFlightGoal else {
            navigationSnapshot = .idle
            return
        }

        if selectedDroneProfile.airframeClass == .multirotor,
           simd_distance(state.position, goal) < 2.4 {
            autoFlightGoal = nextAutoPatrolGoal(resetCycle: false)
            autoPathPlanner.invalidate()
        }

        guard let activeGoal = autoFlightGoal else {
            navigationSnapshot = .idle
            return
        }

        let travelAltitude: Float
        if selectedDroneProfile.airframeClass == .hybridVTOL {
            travelAltitude = hybridVTOLRouteAltitude(defaultAltitude: max(10.0, homePosition.y + 8.0))
        } else {
            travelAltitude = max(3.2, homePosition.y + 4.0)
        }
        var plannedGoal = clampToWorldBounds(SIMD3<Float>(activeGoal.x, travelAltitude, activeGoal.z))
        plannedGoal.y = min(plannedGoal.y, terrain.maxFlightAltitude - 2.0)

        var recomputeReason = "auto_update"
        var forceReplan = false
        if let reason = autoPathPlanner.replanReasonIfNeeded(
            currentPosition: state.position,
            collisionRisk: collisionAnalysis.riskScore,
            deviationTolerance: max(4.5, terrain.worldHalfExtent * 0.045)
        ) {
            recomputeReason = reason
            forceReplan = true
        }

        autoPathPlanner.planIfNeeded(
            start: state.position,
            goal: plannedGoal,
            terrain: terrain,
            obstacles: navigationObstaclesIncludingNoFlyZones(),
            droneRadius: selectedDroneProfile.collisionRadius,
            modeTag: "auto_flight",
            forceRecompute: forceReplan,
            reason: recomputeReason
        )

        if selectedDroneProfile.airframeClass == .fixedWing {
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
            let output = applyAutopilotTrackingControl(
                target: plannedGoal,
                targetAltitude: travelAltitude,
                speedScale: collisionAnalysis.riskScore >= 0.55 ? 0.45 : 1.0,
                yawAlignToHome: false,
                deltaTime: deltaTime
            )

            if output?.hasCompletedRoute == true ||
                autoPathPlanner.hasReachedGoal(
                    currentPosition: state.position,
                    threshold: activeFixedWingParameters().waypointAcceptanceRadiusMeters
                ) {
                autoFlightGoal = nextAutoPatrolGoal(resetCycle: false)
                autoPathPlanner.invalidate()
            }
            return
        }

        autoPathPlanner.updateProgress(
            currentPosition: state.position,
            arrivalRadius: selectedDroneProfile.airframeClass == .multirotor
                ? 1.6
                : max(3.4, selectedDroneProfile.fixedWingParameters?.waypointAcceptanceRadiusMeters ?? 3.4),
            planarOnly: selectedDroneProfile.airframeClass == .multirotor
        )
        navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)

        guard let target = autoPathPlanner.currentTarget() else {
            if selectedDroneProfile.airframeClass == .hybridVTOL,
               autoPathPlanner.hasReachedGoal(
                   currentPosition: state.position,
                   threshold: max(
                       5.0,
                       selectedDroneProfile.fixedWingParameters?.waypointAcceptanceRadiusMeters ?? 5.0
                   )
               ) {
                autoFlightGoal = nextAutoPatrolGoal(resetCycle: false)
                autoPathPlanner.invalidate()
                return
            }
            let holdThrottle = Double(resolvedFlightBaseline(for: .autoPath).cruiseReferenceThrottle)
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, holdThrottle)
                if selectedDroneProfile.airframeClass == .hybridVTOL {
                    values.vtolTransitionLever = state.vtolTransitionProgress > 0.08 ? -1.0 : 0.0
                }
            }, markManual: false)
            return
        }

        let output = applyAutopilotTrackingControl(
            target: target,
            targetAltitude: travelAltitude,
            speedScale: collisionAnalysis.riskScore >= 0.55 ? 0.45 : 1.0,
            yawAlignToHome: false,
            deltaTime: deltaTime
        )
        if selectedDroneProfile.airframeClass == .hybridVTOL,
           output?.hasCompletedRoute == true ||
            autoPathPlanner.hasReachedGoal(
                currentPosition: state.position,
                threshold: max(
                    5.0,
                    selectedDroneProfile.fixedWingParameters?.waypointAcceptanceRadiusMeters ?? 5.0
                )
            ) {
            autoFlightGoal = nextAutoPatrolGoal(resetCycle: false)
            autoPathPlanner.invalidate()
        }
    }

    private func updateReturnHomePath(deltaTime: Float) {
        let defaultSafeTravelAltitude = min(terrain.maxFlightAltitude - 2.0, max(homePosition.y + 6.0, state.position.y + 2.5))
        let safeTravelAltitude = selectedDroneProfile.airframeClass == .hybridVTOL
            ? hybridVTOLRouteAltitude(defaultAltitude: max(10.0, homePosition.y + 8.0, state.position.y))
            : defaultSafeTravelAltitude

        if selectedDroneProfile.airframeClass == .fixedWing, returnHomeStage == .ascend {
            returnHomeStage = .navigate
        }

        switch returnHomeStage {
        case .idle:
            returnHomeStage = .ascend
            navigationSnapshot = .idle

        case .ascend:
            navigationSnapshot = .idle
            let ascentThrottle = Double(resolvedFlightBaseline(for: .takeoff).takeoffThrottleReference)
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.z = Double(state.position.z)
                values.y = Double(safeTravelAltitude)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, ascentThrottle)
                if selectedDroneProfile.airframeClass == .hybridVTOL {
                    values.vtolTransitionLever = 0.0
                }
            }, markManual: false)

            if state.position.y >= safeTravelAltitude - 0.35 {
                returnHomeStage = .navigate
                autoPathPlanner.invalidate()
            }

        case .navigate:
            let goal = clampToWorldBounds(SIMD3<Float>(homePosition.x, safeTravelAltitude, homePosition.z))
            var recomputeReason = "rth_navigate"
            var forceReplan = false
            if let reason = autoPathPlanner.replanReasonIfNeeded(
                currentPosition: state.position,
                collisionRisk: collisionAnalysis.riskScore,
                deviationTolerance: max(4.0, terrain.worldHalfExtent * 0.04)
            ) {
                recomputeReason = reason
                forceReplan = true
            }

            autoPathPlanner.planIfNeeded(
                start: state.position,
                goal: goal,
                terrain: terrain,
                obstacles: navigationObstaclesIncludingNoFlyZones(),
                droneRadius: selectedDroneProfile.collisionRadius,
                modeTag: "return_home",
                forceRecompute: forceReplan,
                reason: recomputeReason
            )

            if selectedDroneProfile.airframeClass == .fixedWing {
                navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
                _ = applyAutopilotTrackingControl(
                    target: goal,
                    targetAltitude: safeTravelAltitude,
                    speedScale: collisionAnalysis.riskScore >= 0.5 ? 0.42 : 0.78,
                    yawAlignToHome: true,
                    deltaTime: deltaTime
                )

                let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
                let wing = selectedDroneProfile.fixedWingParameters
                let fixedWingArrivalRadius = max(
                    10.0,
                    (wing?.waypointAcceptanceRadiusMeters ?? 5.0) * 1.85
                )
                if horizontalDistance < fixedWingArrivalRadius {
                    returnHomeStage = .align
                    autoPathPlanner.invalidate()
                }
                return
            }

            autoPathPlanner.updateProgress(
                currentPosition: state.position,
                arrivalRadius: selectedDroneProfile.airframeClass == .multirotor
                    ? 1.4
                    : max(
                        6.4,
                        (selectedDroneProfile.fixedWingParameters?.waypointAcceptanceRadiusMeters ?? 3.6) * 1.45
                    ),
                planarOnly: selectedDroneProfile.airframeClass == .multirotor
            )
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)

            if let target = autoPathPlanner.currentTarget() {
                applyAutopilotTrackingControl(
                    target: target,
                    targetAltitude: safeTravelAltitude,
                    speedScale: collisionAnalysis.riskScore >= 0.5 ? 0.42 : 0.78,
                    yawAlignToHome: true,
                    deltaTime: deltaTime
                )
            } else {
                let cruiseThrottle = Double(resolvedFlightBaseline(for: .returnHome).cruiseReferenceThrottle)
                updateControlValues({ values in
                    values.roll = 0.0
                    values.pitch = 0.0
                    values.throttle = max(values.throttle, cruiseThrottle)
                }, markManual: false)
            }

            let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
            if selectedDroneProfile.airframeClass == .fixedWing {
                let wing = selectedDroneProfile.fixedWingParameters
                let fixedWingArrivalRadius = max(
                    10.0,
                    (wing?.waypointAcceptanceRadiusMeters ?? 5.0) * 1.85
                )
                if horizontalDistance < fixedWingArrivalRadius {
                    returnHomeStage = .align
                    autoPathPlanner.invalidate()
                }
            } else if selectedDroneProfile.airframeClass == .hybridVTOL {
                let wing = selectedDroneProfile.fixedWingParameters
                let vtolArrivalRadius = max(
                    8.0,
                    (wing?.waypointAcceptanceRadiusMeters ?? 5.0) * 1.45
                )
                if horizontalDistance < vtolArrivalRadius {
                    returnHomeStage = .align
                    autoPathPlanner.invalidate()
                }
            } else if horizontalDistance < 1.5 {
                returnHomeStage = .align
            }

        case .align:
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
            if selectedDroneProfile.airframeClass == .fixedWing {
                let cruiseThrottle = Double(resolvedFlightBaseline(for: .returnHome).cruiseReferenceThrottle)
                applyAutopilotTrackingControl(
                    target: SIMD3<Float>(homePosition.x, max(homePosition.y + 5.0, safeTravelAltitude), homePosition.z),
                    targetAltitude: max(homePosition.y + 5.0, safeTravelAltitude),
                    speedScale: 0.56,
                    yawAlignToHome: false,
                    deltaTime: deltaTime
                )

                let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
                let wing = selectedDroneProfile.fixedWingParameters
                let loiterRadius = max(8.0, (wing?.waypointAcceptanceRadiusMeters ?? 5.0) * 1.4)
                if horizontalDistance < loiterRadius {
                    setFlightMode(.manual, reason: "return_home_fixed_wing_loiter_complete")
                    setFixedWingGuidanceSource(.none, reason: "return_home_fixed_wing_completed")
                    returnHomeStage = .idle
                    autoPathPlanner.invalidate()
                    navigationSnapshot = .idle
                    updateControlValues({ values in
                        values.roll = 0.0
                        values.pitch = max(1.0, min(values.pitch, 5.0))
                        values.yaw = Double(state.orientation.z.radiansToDegrees)
                        values.throttle = max(cruiseThrottle, values.throttle * 0.94)
                    }, markManual: false)
                }
                return
            }

            if selectedDroneProfile.airframeClass == .hybridVTOL {
                let readyForPrecisionHover = hybridVTOLReadyForPrecisionHover()
                let alignmentAltitude = readyForPrecisionHover
                    ? max(homePosition.y + 1.8, state.position.y)
                    : max(homePosition.y + 3.0, state.position.y)
                let alignmentTarget = SIMD3<Float>(
                    homePosition.x,
                    alignmentAltitude,
                    homePosition.z
                )
                let alignmentContext = AutopilotTrackingContext(
                    state: state,
                    physicalState: physicalState,
                    target: alignmentTarget,
                    targetAltitude: alignmentAltitude,
                    speedScale: readyForPrecisionHover ? 0.42 : 0.32,
                    yawAlignToHome: true,
                    yawOverrideRadians: 0.0,
                    deltaTime: deltaTime,
                    flightBaseline: resolvedFlightBaseline(for: .hover)
                )
                applyHybridVTOLHoverAutopilotCommand(
                    context: alignmentContext,
                    target: alignmentTarget,
                    targetAltitude: alignmentAltitude,
                    speedScale: readyForPrecisionHover ? 0.42 : 0.32,
                    yawOverrideRadians: 0.0,
                    vtolTransitionLever: state.vtolTransitionProgress > 0.08 ? -1.0 : 0.0,
                    minimumThrottle: resolvedFlightBaseline(for: .hover).hoverLockThrottle,
                    reason: readyForPrecisionHover
                        ? "vtol_return_home_precision_align"
                        : "vtol_return_home_transition_to_hover",
                    deltaTime: deltaTime
                )
                let horizontalDistance = simd_length(SIMD2<Float>(
                    state.position.x - homePosition.x,
                    state.position.z - homePosition.z
                ))
                if readyForPrecisionHover && horizontalDistance < 0.45 {
                    returnHomeStage = .descend
                }
                return
            }

            let alignmentBaseline = resolvedFlightBaseline(for: .returnHome)
            let alignmentThrottle = Double(
                alignmentBaseline.hoverCapable
                    ? alignmentBaseline.hoverLockThrottle
                    : alignmentBaseline.cruiseReferenceThrottle
            )
            updateControlValues({ values in
                values.x = Double(homePosition.x)
                values.z = Double(homePosition.z)
                values.y = Double(max(homePosition.y + 1.8, state.position.y))
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = 0.0
                values.throttle = max(alignmentThrottle, values.throttle * 0.96)
                if selectedDroneProfile.airframeClass == .hybridVTOL {
                    values.vtolTransitionLever = 0.0
                }
            }, markManual: false)

            let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
            if horizontalDistance < 0.45 {
                returnHomeStage = .descend
            }

        case .descend:
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
            if selectedDroneProfile.airframeClass == .hybridVTOL,
               !hybridVTOLReadyForPrecisionHover() {
                returnHomeStage = .align
                return
            }
            let landingThrottle = Double(resolvedFlightBaseline(for: .landing).landingThrottleReference)
            updateControlValues({ values in
                values.x = Double(homePosition.x)
                values.z = Double(homePosition.z)
                values.y = Double(homePosition.y)
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = 0.0
                values.throttle = max(0.22, min(values.throttle, landingThrottle))
                if selectedDroneProfile.airframeClass == .hybridVTOL {
                    values.vtolTransitionLever = -1.0
                }
            }, markManual: false)

            let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
            if horizontalDistance < 0.4 && state.position.y <= homePosition.y + 0.10 && abs(state.velocity.y) < 0.25 {
                setFlightMode(.manual, reason: "return_home_landing_complete")
                setFixedWingGuidanceSource(.none, reason: "return_home_completed")
                returnHomeStage = .idle
                autoPathPlanner.invalidate()
                navigationSnapshot = .idle
                updateControlValues({ values in
                    values.y = Double(homePosition.y)
                    values.throttle = 0.0
                    values.roll = 0.0
                    values.pitch = 0.0
                    values.yaw = 0.0
                }, markManual: false)
            }
        }
    }

    private func updateHybridVTOLLandingCommand(deltaTime: Float) {
        guard selectedDroneProfile.airframeClass == .hybridVTOL else {
            return
        }

        let readyForDescent = hybridVTOLReadyForPrecisionHover()
        let targetAltitude = readyForDescent
            ? homePosition.y
            : max(homePosition.y + 1.8, state.position.y)
        let target = SIMD3<Float>(
            state.position.x,
            targetAltitude,
            state.position.z
        )
        let baseline = resolvedFlightBaseline(for: readyForDescent ? .landing : .hover)
        let context = AutopilotTrackingContext(
            state: state,
            physicalState: physicalState,
            target: target,
            targetAltitude: targetAltitude,
            speedScale: readyForDescent ? 0.35 : 0.50,
            yawAlignToHome: false,
            yawOverrideRadians: state.orientation.z,
            deltaTime: deltaTime,
            flightBaseline: baseline
        )
        applyHybridVTOLHoverAutopilotCommand(
            context: context,
            target: target,
            targetAltitude: targetAltitude,
            speedScale: readyForDescent ? 0.35 : 0.50,
            yawOverrideRadians: state.orientation.z,
            vtolTransitionLever: -1.0,
            minimumThrottle: readyForDescent ? nil : baseline.hoverLockThrottle,
            reason: readyForDescent ? "vtol_vertical_landing" : "vtol_transition_to_hover_before_landing",
            deltaTime: deltaTime
        )
    }

    @discardableResult
    private func applyAutopilotTrackingControl(
        target: SIMD3<Float>,
        targetAltitude: Float,
        speedScale: Float,
        yawAlignToHome: Bool,
        deltaTime: Float,
        yawOverrideRadians: Float? = nil
    ) -> FixedWingAutopilotOutput? {
        let speedBoost: Float = (simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z)) < 1.0 && speedScale > 0.6) ? 1.2 : 1.0
        let controlScale = speedScale * speedBoost
        let flightBaseline = resolvedFlightBaseline(for: mode)
        let context = AutopilotTrackingContext(
            state: state,
            physicalState: physicalState,
            target: target,
            targetAltitude: targetAltitude,
            speedScale: controlScale,
            yawAlignToHome: yawAlignToHome,
            yawOverrideRadians: yawOverrideRadians,
            deltaTime: deltaTime,
            flightBaseline: flightBaseline
        )

        switch selectedDroneProfile.airframeClass {
        case .multirotor:
            setFixedWingGuidanceSource(.none, reason: "multicopter_autopilot_active")
            let command = multicopterAutopilotController.command(for: context)
            fixedWingAutopilotDebugState = .idle
            applyAutopilotCommand(command, deltaTime: deltaTime)
            return nil
        case .fixedWing:
            return applyFixedWingAutopilotTracking(
                context: context,
                target: target,
                deltaTime: deltaTime
            )
        case .hybridVTOL:
            return applyHybridVTOLAutopilotTracking(
                context: context,
                deltaTime: deltaTime
            )
        }
    }

    @discardableResult
    private func applyFixedWingAutopilotTracking(
        context: AutopilotTrackingContext,
        target: SIMD3<Float>,
        deltaTime: Float,
        vtolTransitionLever: Double? = nil
    ) -> FixedWingAutopilotOutput? {
        let fixedWingGuidanceSource = fixedWingGuidanceSourceForCurrentRoute()
        setFixedWingGuidanceSource(fixedWingGuidanceSource, reason: "fixed_wing_autopilot_tracking")

        let routeTracking = currentFixedWingRouteTrackingContext(fallbackTarget: target)
        let missionSpeedConstraints = fixedWingGuidanceSource == .mission ? currentMissionPlan?.constraints.speed : nil
        let output = fixedWingAutopilotController.trackingCommand(
            for: context,
            parameters: activeFixedWingParameters(),
            launchMode: activeLaunchMode(),
            launchAsset: activeLaunchAsset(),
            routeTracking: routeTracking,
            missionMinAirspeed: missionSpeedConstraints?.minimumMetersPerSecond,
            missionMaxAirspeed: missionSpeedConstraints.map {
                $0.effectiveMaximum(profileMaxSpeed: activeFixedWingParameters().maxAirspeed)
            },
            useHybridVTOLCruiseStabilization: selectedDroneProfile.airframeClass == .hybridVTOL
        )
        fixedWingAutopilotAltitudeCommand = output.command.positionTarget.y
        fixedWingAutopilotCourseCommand = output.command.yawDegrees.degreesToRadians
        fixedWingLastTransitionReason = output.transitionReason
        fixedWingAutopilotDebugState = output.debugState
        updateFixedWingNavigationSnapshot(
            routeTracking: routeTracking,
            debugState: output.debugState
        )

        // Hand/catapult launch is owned exclusively by
        // `fixedWingLaunchController`. The legacy route-autopilot launch phase
        // must never overwrite its release/climb state while the new sequence
        // is active (or after it has produced a terminal snapshot).
        if launchRuntimeSnapshot.state == .idle {
            if output.launchPhase != nil {
                updateLegacyLaunchState(
                    legacyLaunchState(for: output, launchMode: activeLaunchMode()),
                    deltaTime: deltaTime
                )
            } else if launchState != .idle,
                      activeLaunchMode() == .standard {
                updateLegacyLaunchState(.completed)
            }
        }

        if output.phase == .failed {
            setFixedWingGuidanceSource(.none, reason: "fixed_wing_autopilot_failed")
            if mode.isAutoControlled {
                setFlightMode(.manual, reason: "fixed_wing_autopilot_failed")
            }
        }

        applyAutopilotCommand(
            output.command,
            deltaTime: deltaTime,
            vtolTransitionLever: vtolTransitionLever
        )
        return output
    }

    private func fixedWingGuidanceSourceForCurrentRoute() -> FixedWingGuidanceSource {
        if mode == .returnHome {
            return .returnHome
        }
        if activeRouteTargetSource == .mission {
            return .mission
        }
        if targetMarkerState != nil {
            return .marker
        }
        return activeFixedWingGuidanceSource == .none ? .mission : activeFixedWingGuidanceSource
    }

    @discardableResult
    private func applyHybridVTOLAutopilotTracking(
        context: AutopilotTrackingContext,
        deltaTime: Float
    ) -> FixedWingAutopilotOutput? {
        let wing = activeFixedWingParameters()
        let routeAltitude = hybridVTOLRouteAltitude(defaultAltitude: context.targetAltitude)
        let decision = hybridVTOLAutopilotDecision(
            context: context,
            wing: wing,
            routeAltitude: routeAltitude
        )
        vtolAutopilotPhase = decision.phase

        switch decision.phase {
        case .idleGrounded, .hoverHold, .precisionHover:
            applyHybridVTOLHoverAutopilotCommand(
                context: context,
                target: decision.target,
                targetAltitude: decision.targetAltitude,
                speedScale: decision.speedScale,
                yawOverrideRadians: decision.targetHeading ?? context.yawOverrideRadians,
                vtolTransitionLever: decision.transitionLever,
                minimumThrottle: nil,
                reason: decision.reason,
                deltaTime: deltaTime
            )
            return nil
        case .verticalTakeoff:
            applyHybridVTOLHoverAutopilotCommand(
                context: context,
                target: decision.target,
                targetAltitude: decision.targetAltitude,
                speedScale: decision.speedScale,
                yawOverrideRadians: decision.targetHeading ?? context.yawOverrideRadians,
                vtolTransitionLever: decision.transitionLever,
                minimumThrottle: resolvedFlightBaseline(for: .takeoff).takeoffThrottleReference,
                reason: decision.reason,
                deltaTime: deltaTime
            )
            return nil
        case .transitionToHover, .transitionAbort, .emergencyHover, .forcedLanding, .verticalLanding:
            let throttleFloor: Float?
            switch decision.phase {
            case .emergencyHover:
                throttleFloor = resolvedFlightBaseline(for: .hover).hoverLockThrottle
            case .forcedLanding, .verticalLanding:
                throttleFloor = resolvedFlightBaseline(for: .landing).landingThrottleReference
            default:
                throttleFloor = nil
            }
            applyHybridVTOLHoverAutopilotCommand(
                context: context,
                target: decision.target,
                targetAltitude: decision.targetAltitude,
                speedScale: decision.speedScale,
                yawOverrideRadians: decision.targetHeading ?? context.yawOverrideRadians,
                vtolTransitionLever: decision.transitionLever,
                minimumThrottle: throttleFloor,
                reason: decision.reason,
                deltaTime: deltaTime
            )
            return nil
        case .transitionToCruise:
            applyHybridVTOLTransitionToCruiseCommand(
                context: context,
                decision: decision,
                wing: wing,
                routeAltitude: routeAltitude,
                deltaTime: deltaTime
            )
            return nil
        case .wingborneCruise:
            let cruiseContext = AutopilotTrackingContext(
                state: state,
                physicalState: physicalState,
                target: decision.target,
                targetAltitude: routeAltitude,
                speedScale: context.speedScale,
                yawAlignToHome: context.yawAlignToHome,
                yawOverrideRadians: decision.targetHeading ?? context.yawOverrideRadians,
                deltaTime: context.deltaTime,
                flightBaseline: context.flightBaseline
            )
            return applyFixedWingAutopilotTracking(
                context: cruiseContext,
                target: decision.target,
                deltaTime: deltaTime,
                vtolTransitionLever: 1.0
            )
        }
    }

    private func hybridVTOLAutopilotDecision(
        context: AutopilotTrackingContext,
        wing: FixedWingParameters,
        routeAltitude: Float
    ) -> VTOLAutopilotDecision {
        let target = hybridVTOLActiveLegTarget(context: context, routeAltitude: routeAltitude)
        let currentPlanar = SIMD2<Float>(state.position.x, state.position.z)
        let targetPlanar = SIMD2<Float>(target.x, target.z)
        let routeVector = targetPlanar - currentPlanar
        let planarDistance = simd_length(routeVector)
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let airspeed = max(state.forwardAirspeed, planarSpeed)
        let liftRatio = max(state.vtolWingLiftRatio, state.vtolWingborneBlend)
        let routeYaw: Float? = planarDistance > 0.5
            ? fixedWingCourseRadians(from: routeVector)
            : context.yawOverrideRadians
        let precisionRadius = hybridVTOLPrecisionEntryRadius(wing: wing)
        let cruiseEntryDistance = hybridVTOLCruiseEntryDistance(wing: wing, precisionRadius: precisionRadius)
        let cruiseExitDistance = hybridVTOLCruiseExitDistance(wing: wing, precisionRadius: precisionRadius)
        let cruiseWasEstablished = vtolAutopilotPhase == .wingborneCruise
        let wasCruisePath = vtolAutopilotPhase == .transitionToCruise ||
            cruiseWasEstablished
        let wantsCruise = planarDistance > cruiseEntryDistance ||
            (wasCruisePath && planarDistance > cruiseExitDistance)
        let airborne = !physicalState.isGroundRestState && state.position.y > 0.45
        let maxSinkRate = max(1.4, min(3.2, wing.nominalSinkRateMps * 1.35))

        func decision(
            _ phase: VTOLAutopilotPhase,
            target: SIMD3<Float> = target,
            altitude: Float = routeAltitude,
            lever: Double,
            speedScale: Float,
            safety: VTOLAutopilotSafetyState = .nominal,
            reason: String
        ) -> VTOLAutopilotDecision {
            VTOLAutopilotDecision(
                phase: phase,
                target: target,
                targetAltitude: altitude,
                targetAirspeed: phase == .wingborneCruise || phase == .transitionToCruise ? wing.cruiseAirspeed : nil,
                targetHeading: routeYaw,
                maxSinkRate: maxSinkRate,
                transitionLever: lever,
                speedScale: speedScale,
                safetyState: safety,
                reason: reason
            )
        }

        if !isArmed && physicalState.isGroundRestState {
            return decision(
                .idleGrounded,
                target: SIMD3<Float>(state.position.x, max(0.0, state.position.y), state.position.z),
                altitude: max(0.0, state.position.y),
                lever: 0.0,
                speedScale: 0.0,
                reason: "vtol_idle_grounded"
            )
        }

        if mode == .landing {
            return decision(
                .verticalLanding,
                target: SIMD3<Float>(state.position.x, 0.0, state.position.z),
                altitude: 0.0,
                lever: -1.0,
                speedScale: 0.35,
                reason: "vtol_vertical_landing"
            )
        }

        if airborne && collisionAnalysis.riskScore >= 0.82 {
            return decision(
                .emergencyHover,
                target: SIMD3<Float>(state.position.x, max(routeAltitude, state.position.y), state.position.z),
                altitude: max(routeAltitude, state.position.y),
                lever: -1.0,
                speedScale: 0.25,
                safety: .emergencyHover("corridorBlocked"),
                reason: "vtol_emergency_hover_corridor_blocked"
            )
        }

        if airborne && (batteryState.chargePercent <= 4.0 || hasFlightCriticalGraphDamage) {
            return decision(
                .forcedLanding,
                target: SIMD3<Float>(state.position.x, 0.0, state.position.z),
                altitude: 0.0,
                lever: -1.0,
                speedScale: 0.25,
                safety: .forcedLanding(batteryState.chargePercent <= 4.0 ? "lowBattery" : "damageCritical"),
                reason: "vtol_forced_landing"
            )
        }

        if state.position.y < routeAltitude - 0.85 && state.vtolTransitionProgress < 0.20 {
            return decision(
                .verticalTakeoff,
                target: SIMD3<Float>(state.position.x, routeAltitude, state.position.z),
                altitude: routeAltitude,
                lever: 0.0,
                speedScale: min(context.speedScale, 0.55),
                reason: "vtol_vertical_takeoff_to_route_altitude"
            )
        }

        if planarDistance <= precisionRadius {
            let needsHoverCapture = state.vtolTransitionProgress > 0.08 ||
                planarSpeed > max(4.5, wing.minSafeAirspeed * 0.28)
            if needsHoverCapture {
                return decision(
                    .transitionToHover,
                    lever: -1.0,
                    speedScale: min(context.speedScale, 0.42),
                    reason: "vtol_transition_to_hover_for_waypoint"
                )
            }
            return decision(
                .precisionHover,
                lever: 0.0,
                speedScale: min(context.speedScale, 0.35),
                reason: "vtol_precision_hover_waypoint"
            )
        }

        if !wantsCruise {
            let hoverLever = state.vtolTransitionProgress > 0.08 ? -1.0 : 0.0
            return decision(
                hoverLever < 0.0 ? .transitionToHover : .hoverHold,
                lever: hoverLever,
                speedScale: min(context.speedScale, 0.62),
                reason: hoverLever < 0.0 ? "vtol_transition_to_hover_short_leg" : "vtol_hover_hold_short_leg"
            )
        }

        let transitionSafety = hybridVTOLTransitionSafetyState(
            airspeed: airspeed,
            routeAltitude: routeAltitude,
            wing: wing,
            cruiseWasEstablished: cruiseWasEstablished
        )
        switch transitionSafety {
        case .nominal:
            break
        case .transitionBlocked(let reason):
            if state.position.y < routeAltitude - 0.45 {
                return decision(
                    .verticalTakeoff,
                    target: SIMD3<Float>(state.position.x, routeAltitude, state.position.z),
                    altitude: routeAltitude,
                    lever: 0.0,
                    speedScale: min(context.speedScale, 0.50),
                    safety: transitionSafety,
                    reason: "vtol_transition_blocked_\(reason)"
                )
            }
            return decision(
                .hoverHold,
                target: SIMD3<Float>(state.position.x, routeAltitude, state.position.z),
                altitude: routeAltitude,
                lever: state.vtolTransitionProgress > 0.08 ? -1.0 : 0.0,
                speedScale: min(context.speedScale, 0.45),
                safety: transitionSafety,
                reason: "vtol_transition_blocked_\(reason)"
            )
        case .transitionAborting(let reason):
            return decision(
                .transitionAbort,
                target: SIMD3<Float>(state.position.x, max(routeAltitude, state.position.y), state.position.z),
                altitude: max(routeAltitude, state.position.y),
                lever: -1.0,
                speedScale: 0.32,
                safety: transitionSafety,
                reason: "vtol_transition_abort_\(reason)"
            )
        case .emergencyHover(let reason):
            return decision(
                .emergencyHover,
                target: SIMD3<Float>(state.position.x, max(routeAltitude, state.position.y), state.position.z),
                altitude: max(routeAltitude, state.position.y),
                lever: -1.0,
                speedScale: 0.25,
                safety: transitionSafety,
                reason: "vtol_emergency_hover_\(reason)"
            )
        case .forcedLanding(_):
            return decision(
                .forcedLanding,
                target: SIMD3<Float>(state.position.x, 0.0, state.position.z),
                altitude: 0.0,
                lever: -1.0,
                speedScale: 0.25,
                safety: transitionSafety,
                reason: "vtol_forced_landing"
            )
        }

        // A tailsitter must not bounce back to the transition controller every
        // time lift ratio or vertical speed crosses a cruise-entry threshold by
        // a small amount. That controller handoff replaces the fixed-wing pitch
        // command with a multicopter command, producing the visible Wingtra
        // pitch "saw" and making the AUTO telemetry alternate ON/OFF. Once
        // cruise has been established, retain it until the safety evaluator
        // above reports a genuine loss of speed, sink-rate margin, or corridor.
        if cruiseWasEstablished,
           selectedDroneProfile.airframeStyle == .tailsitterVTOL {
            return decision(
                .wingborneCruise,
                lever: 1.0,
                speedScale: context.speedScale,
                reason: "vtol_cruise_retained_hysteresis"
            )
        }

        if hybridVTOLCruiseReady(wing: wing) {
            return decision(
                .wingborneCruise,
                lever: 1.0,
                speedScale: context.speedScale,
                reason: "vtol_cruise_accepted_lift_ready"
            )
        }

        let transitionLever = hybridVTOLTransitionLever(
            wing: wing,
            airspeed: airspeed,
            liftRatio: liftRatio,
            transitionProgress: state.vtolTransitionProgress
        )
        let transitionReason = transitionLever > 0.05
            ? "vtol_transition_to_cruise"
            : "vtol_transition_delayed_lift_or_speed"
        return decision(
            .transitionToCruise,
            lever: transitionLever,
            speedScale: min(max(context.speedScale, 0.58), 0.84),
            reason: transitionReason
        )
    }

    private func applyHybridVTOLTransitionToCruiseCommand(
        context: AutopilotTrackingContext,
        decision: VTOLAutopilotDecision,
        wing: FixedWingParameters,
        routeAltitude: Float,
        deltaTime: Float
    ) {
        let currentPlanar = SIMD2<Float>(state.position.x, state.position.z)
        let targetPlanar = SIMD2<Float>(decision.target.x, decision.target.z)
        let routeVector = targetPlanar - currentPlanar
        let planarDistance = simd_length(routeVector)
        let direction: SIMD2<Float>
        if planarDistance > 0.01 {
            direction = routeVector / planarDistance
        } else {
            let yaw = state.orientation.z
            direction = SIMD2<Float>(-sin(yaw), -cos(yaw))
        }
        let lookaheadUpperBound = max(24.0, wing.cruiseAirspeed * 1.6)
        let transitionLookahead = min(max(planarDistance * 0.45, 12.0), lookaheadUpperBound)
        let transitionTarget = SIMD3<Float>(
            state.position.x + direction.x * transitionLookahead,
            routeAltitude,
            state.position.z + direction.y * transitionLookahead
        )
        let transitionBaseline = resolvedFlightBaseline(for: mode)
        let transitionContext = AutopilotTrackingContext(
            state: state,
            physicalState: physicalState,
            target: transitionTarget,
            targetAltitude: routeAltitude,
            speedScale: decision.speedScale,
            yawAlignToHome: context.yawAlignToHome,
            yawOverrideRadians: decision.targetHeading ?? context.yawOverrideRadians,
            deltaTime: context.deltaTime,
            flightBaseline: transitionBaseline
        )
        var command = multicopterAutopilotController.command(for: transitionContext)
        let attitudeScale = (1.0 - state.vtolTransitionProgress * 0.65).clamped(to: 0.25...1.0)
        command.rollDegrees *= attitudeScale
        command.pitchDegrees *= attitudeScale
        command.throttle = max(
            command.throttle,
            transitionBaseline.hoverLockThrottle,
            transitionBaseline.cruiseReferenceThrottle
        )
        if state.position.y < routeAltitude - 0.30 {
            command.throttle = max(
                command.throttle,
                resolvedFlightBaseline(for: .takeoff).takeoffThrottleReference
            )
        }
        fixedWingAutopilotAltitudeCommand = routeAltitude
        fixedWingAutopilotCourseCommand = decision.targetHeading
        fixedWingAutopilotDebugState = .idle
        fixedWingLastTransitionReason = decision.reason
        applyAutopilotCommand(
            command,
            deltaTime: deltaTime,
            vtolTransitionLever: decision.transitionLever
        )
    }

    private func hybridVTOLActiveLegTarget(
        context: AutopilotTrackingContext,
        routeAltitude: Float
    ) -> SIMD3<Float> {
        if activeRouteTargetSource == .mission,
           missionExecutionState.status == .running,
           let activeTarget = missionExecutionState.activeTarget,
           isFiniteVector2(activeTarget.position) {
            return SIMD3<Float>(
                activeTarget.position.x,
                routeAltitude,
                activeTarget.position.y
            )
        }
        return SIMD3<Float>(context.target.x, routeAltitude, context.target.z)
    }

    private func hybridVTOLPrecisionEntryRadius(wing: FixedWingParameters) -> Float {
        let captureRadius = wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed)
        let turnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed)
        if wing.family == .surveyEVTOL {
            return max(
                12.0,
                captureRadius * 0.95,
                min(turnRadius * 0.55, captureRadius * 2.4)
            )
        }
        return max(
            16.0,
            captureRadius * 1.10,
            min(turnRadius * 0.65, captureRadius * 2.6)
        )
    }

    private func hybridVTOLCruiseEntryDistance(
        wing: FixedWingParameters,
        precisionRadius: Float
    ) -> Float {
        let turnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed)
        return max(
            precisionRadius * 1.75,
            min(turnRadius * 1.10, precisionRadius * 3.4),
            wing.cruiseAirspeed * 3.5
        )
    }

    private func hybridVTOLCruiseExitDistance(
        wing: FixedWingParameters,
        precisionRadius: Float
    ) -> Float {
        let turnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed)
        return max(
            precisionRadius * 1.15,
            min(turnRadius * 0.72, precisionRadius * 2.2)
        )
    }

    private func hybridVTOLTransitionSafetyState(
        airspeed: Float,
        routeAltitude: Float,
        wing: FixedWingParameters,
        cruiseWasEstablished: Bool
    ) -> VTOLAutopilotSafetyState {
        let latchedTailsitterCruise = cruiseWasEstablished &&
            selectedDroneProfile.airframeStyle == .tailsitterVTOL
        let minimumAltitude = max(8.0, homePosition.y + 6.0)
        if state.position.y < minimumAltitude {
            return .transitionBlocked("insufficientAltitude")
        }
        if batteryState.chargePercent < 12.0 {
            return .transitionBlocked("lowBattery")
        }
        if hasFlightCriticalGraphDamage || damageState.averageHealth < 0.35 {
            return .transitionBlocked("damageCritical")
        }
        if collisionAnalysis.riskScore >= 0.70 {
            return .emergencyHover("corridorBlocked")
        }
        let sinkLimit = latchedTailsitterCruise
            ? max(2.4, wing.nominalSinkRateMps * 1.75)
            : max(1.2, wing.nominalSinkRateMps * 1.15)
        if state.vtolTransitionProgress > 0.10,
           state.velocity.y < -sinkLimit {
            return .transitionAborting("sinkRateExceeded")
        }
        let lateTiltSpeedScale: Float = latchedTailsitterCruise ? 0.62 : 0.72
        let tooSlowForLateTilt = state.vtolTransitionProgress > 0.62 &&
            airspeed < wing.minSustainableSpeedMps * lateTiltSpeedScale
        if tooSlowForLateTilt {
            return .transitionAborting("insufficientAirspeed")
        }
        if !latchedTailsitterCruise,
           state.vtolTransitionBlocked,
           state.vtolTransitionProgress > 0.20,
           state.velocity.y < -0.6 {
            return .transitionAborting("liftReserveLost")
        }
        if !latchedTailsitterCruise,
           state.position.y < routeAltitude - 1.6,
           state.vtolTransitionProgress > 0.35 {
            return .transitionAborting("altitudeNotHeld")
        }
        return .nominal
    }

    private func hybridVTOLTransitionLever(
        wing: FixedWingParameters,
        airspeed: Float,
        liftRatio: Float,
        transitionProgress: Float
    ) -> Double {
        guard collisionAnalysis.riskScore < 0.70 else {
            return 0.0
        }
        let sinkLimit = max(1.2, wing.nominalSinkRateMps * 1.15)
        guard state.velocity.y >= -sinkLimit else {
            return 0.0
        }
        guard !state.vtolTransitionBlocked else {
            return 0.0
        }
        if transitionProgress < 0.18 {
            return 1.0
        }
        let progress = transitionProgress.clamped(to: 0.0...1.0)
        let requiredLiftRatio = min(0.86, 0.10 + progress * 0.74)
        let requiredAirspeed = max(
            wing.minSafeAirspeed * (0.42 + progress * 0.38),
            wing.minSustainableSpeedMps * (0.38 + progress * 0.42)
        )
        if liftRatio >= requiredLiftRatio && airspeed >= requiredAirspeed {
            return 1.0
        }
        let degradedLiftOK = liftRatio >= requiredLiftRatio * 0.78
        let degradedSpeedOK = airspeed >= requiredAirspeed * 0.92
        return degradedLiftOK && degradedSpeedOK ? 0.45 : 0.0
    }

    private func applyHybridVTOLHoverAutopilotCommand(
        context: AutopilotTrackingContext,
        target: SIMD3<Float>,
        targetAltitude: Float,
        speedScale: Float,
        yawOverrideRadians: Float?,
        vtolTransitionLever: Double,
        minimumThrottle: Float?,
        reason: String,
        deltaTime: Float
    ) {
        let hoverBaseline = resolvedFlightBaseline(for: .hover)
        let hoverContext = AutopilotTrackingContext(
            state: state,
            physicalState: physicalState,
            target: target,
            targetAltitude: targetAltitude,
            speedScale: speedScale,
            yawAlignToHome: context.yawAlignToHome,
            yawOverrideRadians: yawOverrideRadians,
            deltaTime: context.deltaTime,
            flightBaseline: hoverBaseline
        )
        var command = multicopterAutopilotController.command(for: hoverContext)
        if state.vtolTransitionProgress > 0.12 {
            let attitudeScale = (1.0 - state.vtolTransitionProgress * 0.55).clamped(to: 0.35...1.0)
            command.rollDegrees *= attitudeScale
            command.pitchDegrees *= attitudeScale
        }
        if let minimumThrottle {
            command.throttle = max(command.throttle, minimumThrottle)
        }

        fixedWingAutopilotAltitudeCommand = targetAltitude
        fixedWingAutopilotCourseCommand = command.yawDegrees.degreesToRadians
        fixedWingAutopilotDebugState = .idle
        fixedWingLastTransitionReason = reason
        applyAutopilotCommand(
            command,
            deltaTime: deltaTime,
            vtolTransitionLever: vtolTransitionLever
        )
    }

    private func hybridVTOLCruiseReady(wing: FixedWingParameters) -> Bool {
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let airspeed = max(state.forwardAirspeed, planarSpeed)
        let liftRatio = max(state.vtolWingLiftRatio, state.vtolWingborneBlend)
        let altitudeStable = state.velocity.y > -max(1.1, wing.nominalSinkRateMps * 0.65)
        guard altitudeStable else {
            return false
        }
        if selectedDroneProfile.airframeStyle == .surveyEVTOL {
            return state.vtolTransitionProgress >= 0.72 &&
                liftRatio >= 0.62 &&
                airspeed >= wing.minSustainableSpeedMps * 0.78
        }

        return state.vtolTransitionProgress >= 0.86 &&
            liftRatio >= 0.74 &&
            airspeed >= wing.minSustainableSpeedMps * 0.82
    }

    private func hybridVTOLReadyForPrecisionHover() -> Bool {
        guard selectedDroneProfile.airframeClass == .hybridVTOL else {
            return true
        }
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        return state.vtolTransitionProgress <= 0.10 && planarSpeed <= 5.5
    }

    private func hybridVTOLRouteAltitude(defaultAltitude: Float) -> Float {
        let ceiling = max(6.0, terrain.maxFlightAltitude - 2.0)
        let cruiseFloor = max(10.0, homePosition.y + 8.0)
        return min(ceiling, max(defaultAltitude, cruiseFloor))
    }

    private func prepareHybridVTOLAutopilotForForwardRoute() {
        guard selectedDroneProfile.airframeClass == .hybridVTOL else {
            return
        }
        updateControlValues({ values in
            values.vtolTransitionLever = 0.0
        }, markManual: false)
    }

    private func updateFixedWingNavigationSnapshot(
        routeTracking: FixedWingRouteTrackingContext?,
        debugState: FixedWingAutopilotDebugState
    ) {
        guard let routeTracking,
              routeTracking.waypoints.count >= 2 else {
            return
        }

        let positions = routeTracking.waypoints.map(\.position)
        let clampedIndex = min(debugState.activeSegmentIndex + 1, max(0, positions.count - 1))
        navigationSnapshot = NavigationPathSnapshot(
            status: .valid,
            currentWaypointIndex: clampedIndex,
            remainingWaypoints: max(0, positions.count - clampedIndex),
            pathLengthMeters: fixedWingPathLength(of: positions),
            remainingDistanceMeters: max(0.0, debugState.remainingDistance),
            waypoints: positions,
            start: positions.first,
            goal: positions.last,
            reason: debugState.missionState.rawValue
        )
    }

    private func applyAutopilotCommand(
        _ command: AutopilotControlCommand,
        deltaTime: Float,
        vtolTransitionLever: Double? = nil
    ) {
        updateControlValues({ values in
            values.x = Double(command.positionTarget.x)
            values.y = Double(command.positionTarget.y)
            values.z = Double(command.positionTarget.z)
            values.roll = Double(command.rollDegrees)
            values.pitch = Double(command.pitchDegrees)
            values.yaw = Double(command.yawDegrees)

            let followBlend = (deltaTime * 3.4).clamped(to: 0.06...0.30)
            let blendedThrottle = Float(values.throttle) + (command.throttle - Float(values.throttle)) * followBlend
            values.throttle = Double(blendedThrottle.clamped(to: 0.0...1.0))
            if let vtolTransitionLever {
                values.vtolTransitionLever = vtolTransitionLever
            }
        }, markManual: false)
    }

    private func nextAutoPatrolGoal(resetCycle: Bool) -> SIMD3<Float> {
        let goals = autoPatrolGoals()
        if goals.isEmpty {
            return clampToWorldBounds(homePosition + SIMD3<Float>(0.0, 4.0, 0.0))
        }

        if resetCycle {
            autoFlightGoalIndex = 0
        } else {
            autoFlightGoalIndex = (autoFlightGoalIndex + 1) % goals.count
        }
        return goals[autoFlightGoalIndex]
    }

    private func autoPatrolGoals() -> [SIMD3<Float>] {
        let radius = max(8.0, min(terrain.worldHalfExtent * 0.55, 54.0))
        let altitude = max(3.2, homePosition.y + 4.2)
        let base = homePosition
        let raw: [SIMD3<Float>] = [
            SIMD3<Float>(base.x + radius, altitude, base.z),
            SIMD3<Float>(base.x, altitude, base.z + radius),
            SIMD3<Float>(base.x - radius, altitude, base.z),
            SIMD3<Float>(base.x, altitude, base.z - radius),
            SIMD3<Float>(base.x + radius * 0.5, altitude, base.z + radius * 0.5),
            SIMD3<Float>(base.x - radius * 0.5, altitude, base.z - radius * 0.5)
        ]
        return raw.map { clampToWorldBounds($0) }
    }

    private func clampToWorldBounds(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let maxAltitude = max(10.0, terrain.maxFlightAltitude - 2.0)
        let planar = clampPlanarToBoundarySquare(
            SIMD2<Float>(point.x, point.z),
            halfExtent: hardWorldBoundsRadius
        )
        return SIMD3<Float>(
            planar.x,
            point.y.clamped(to: 0.0...maxAltitude),
            planar.y
        )
    }

    private func handleModeTransitions() {
        if mode == .takeoff {
            if selectedDroneProfile.airframeClass == .fixedWing {
                if activeLaunchMode() != .standard, launchState.blocksRouteCapture {
                    return
                }
                let liftOffSpeed = selectedDroneProfile.fixedWingParameters?.minSustainableSpeedMps ?? 9.0
                if physicalState == .airborne || state.position.y >= 1.0 || state.forwardAirspeed >= liftOffSpeed * 0.92 {
                    setFlightMode(.manual, reason: "takeoff_completed_fixed_wing")
                    setFixedWingGuidanceSource(.none, reason: "fixed_wing_takeoff_completed")
                }
            } else {
                let targetAltitude = Float(controlValues.y)
                if selectedDroneProfile.airframeStyle == .tailsitterVTOL,
                   state.position.y >= targetAltitude - 0.08 {
                    setFlightMode(.hover, reason: "takeoff_completed_tailsitter")
                    updateControlValues({ values in
                        values.x = Double(state.position.x)
                        values.y = Double(state.position.y)
                        values.z = Double(state.position.z)
                        values.roll = 0.0
                        values.pitch = 0.0
                        values.yaw = Double(state.orientation.z.radiansToDegrees)
                        values.throttle = Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle)
                        values.vtolTransitionLever = 0.0
                    }, markManual: false)
                } else if physicalState == .airborne && state.position.y >= targetAltitude - 0.08 && abs(state.velocity.y) < 0.45 {
                    setFlightMode(.hover, reason: "takeoff_completed_multicopter")
                    lockControlsToCurrentState(overrideThrottle: Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle))
                }
            }
        }

        if mode == .landing,
           physicalState == .landed {
            setFlightMode(.manual, reason: "landing_completed")
            if selectedDroneProfile.airframeClass == .fixedWing {
                isArmed = false
                transitionPhysicalState(.disarmed)
            }
            updateControlValues({ values in
                values.y = 0.0
                values.throttle = 0.0
                values.roll = 0.0
                values.pitch = 0.0
            }, markManual: false)
        }

    }

    private func updateFleetStatus(deltaTime: Float) -> [CollisionObstacle] {
        guard fleetStatus.enabled, fleetStatus.mode != .off else {
            fleetInterDroneRisk = 0.0
            fleetNearestInterDroneDistance = .infinity
            wingmen.removeAll()
            return []
        }

        let leader = DroneEntity(
            id: fleetLeaderID,
            position: state.position,
            velocity: state.velocity,
            collisionRadius: selectedDroneProfile.collisionRadius
        )

        wingmen = fleetManager.stepWingmen(
            current: wingmen,
            leaderPosition: state.position,
            leaderVelocity: state.velocity,
            leaderYaw: state.orientation.z,
            mode: fleetStatus.mode,
            requestedCount: fleetStatus.wingmanCount,
            separation: fleetStatus.separationDistance,
            radius: selectedDroneProfile.collisionRadius,
            deltaTime: deltaTime
        )

        let interDrone = fleetManager.interDroneCollisionSnapshot(
            leader: leader,
            wingmen: wingmen
        )

        fleetInterDroneRisk = interDrone.riskScore
        fleetNearestInterDroneDistance = interDrone.nearestSeparation

        return fleetManager.collisionObstacles(for: wingmen)
    }

    private func lockControlsToCurrentState(overrideThrottle: Double) {
        updateControlValues({ values in
            values.x = Double(state.position.x)
            values.y = Double(state.position.y)
            values.z = Double(state.position.z)
            values.roll = Double(state.orientation.x.radiansToDegrees)
            values.pitch = Double(state.orientation.y.radiansToDegrees)
            values.yaw = Double(state.orientation.z.radiansToDegrees)
            values.throttle = overrideThrottle
        }, markManual: false)
    }

    private func resolvedFlightBaseline(for flightMode: DroneFlightMode? = nil) -> ResolvedFlightBaseline {
        FlightBaselineResolver.resolve(
            runtimeProfile: selectedDroneProfile,
            activeUAVProfile: activeUAVProfile,
            vehicleMassModel: vehicleMassModel,
            flightMode: flightMode ?? mode
        )
    }

    private func buildControlInput(from controls: DroneControlValues) -> DroneControlInput {
        let builder = DroneControlInputBuilder(
            controls: controls,
            state: state,
            isArmed: isArmed,
            mode: mode,
            controlMode: resolvedFlightControlMode(for: flightControlRouter.currentAuthority),
            manualYawIntent: manualYawIntent,
            usesTargetYawWhileManual: fixedWingAssistUsesTargetYawWhileManual
        )
        return builder.build()
    }

    private var canStartTargetMarkerAutoNavigation: Bool {
        guard fixedWingAutonomousRouteExecutionEnabled else {
            return false
        }
        guard targetMarkerState != nil else {
            return false
        }
        return canBindMissionTargetToAutopilot
    }

    private var fixedWingAutonomousRouteExecutionEnabled: Bool {
        selectedDroneProfile.airframeClass != .fixedWing
    }

    private func disengageFixedWingAutonomousRouteExecution(reason: String) {
        guard selectedDroneProfile.airframeClass == .fixedWing else {
            return
        }

        autoNavigationController.cancel()
        autoPathPlanner.invalidate()
        navigationSnapshot = .idle
        autoFlightGoal = nil
        returnHomeStage = .idle
        resetFixedWingAutopilotCommands()

        if mode == .autoPath || mode == .returnHome {
            setFlightMode(.manual, reason: reason)
        }

        refreshFlightControlDiagnostics()
    }

    private var canBindMissionTargetToAutopilot: Bool {
        guard isArmed, !signalState.isInteractionBlocking else {
            return false
        }
        guard physicalState != .disarmed, physicalState != .crashed else {
            return false
        }
        return mode != .emergencyStop
    }

    private func cancelTargetMarkerAutoNavigation() {
        autoNavigationController.cancel()
        navigationSnapshot = .idle
        resetFixedWingAutopilotCommands()
        resetActiveRouteTargetGuidanceCache()
    }

    private func resetActiveRouteTargetGuidanceCache() {
        activeRouteTargetAltitude = nil
        activeRouteTargetAltitudeMarkerID = nil
        multirotorMarkerLastPlanTick = nil
        multirotorAvoidanceLateralOffset = 0.0
        multirotorAvoidanceHoldUntilTick = 0
        multicopterAutopilotController.reset()
    }

    private var activeMissionAutopilotPlan: MissionPlan? {
        activeRouteTargetSource == .mission ? currentMissionPlan : nil
    }

    private func targetMarkerTravelAltitude() -> Float {
        let executionCeiling = max(6.0, terrain.maxFlightAltitude - 2.0)
        if selectedDroneProfile.airframeClass != .fixedWing,
           let marker = targetMarkerState,
           activeRouteTargetSource != .none,
           activeRouteTargetAltitudeMarkerID == marker.id,
           let cachedAltitude = activeRouteTargetAltitude {
            return cachedAltitude.clamped(to: 0.0...executionCeiling)
        }

        let baselineAltitude: Float
        switch selectedDroneProfile.airframeClass {
        case .multirotor:
            baselineAltitude = min(
                executionCeiling,
                max(3.4, homePosition.y + 4.0, state.position.y + (physicalState.isGroundRestState ? 3.0 : 0.8))
            )
        case .fixedWing, .hybridVTOL:
            baselineAltitude = min(
                executionCeiling,
                max(10.0, homePosition.y + 8.0, state.position.y + 3.4)
            )
        }
        let resolvedAltitude = missionAutopilotAdapter.resolvedTravelAltitude(
            for: activeMissionAutopilotPlan,
            baselineAltitude: baselineAltitude,
            terrainMaxAltitude: executionCeiling
        )
        if selectedDroneProfile.airframeClass != .fixedWing,
           let marker = targetMarkerState,
           activeRouteTargetSource != .none {
            let clampedAltitude = resolvedAltitude.clamped(to: 0.0...executionCeiling)
            activeRouteTargetAltitudeMarkerID = marker.id
            activeRouteTargetAltitude = clampedAltitude
            return clampedAltitude
        }
        return resolvedAltitude
    }

    private func buildFlightInputState(from controlState: ResolvedControlState) -> FlightInputState {
        FlightInputState(
            controlState: controlState,
            payloadViewActive: (
                cameraConfiguration.mode == .payload && payloadCameraStatus.isActive
            ) || cameraConfiguration.mode == .payloadOptics,
            mapOverlayActive: isTerrainMapVisible || isMissionMapVisible
        )
    }

    private func buildFlightControlRoutingContext() -> FlightControlRoutingContext {
        FlightControlRoutingContext(
            isArmed: isArmed,
            isInteractionBlocked: signalState.isInteractionBlocking,
            isSignalLost: signalState == .signalLost || signalState == .recoveryPending,
            isBlockedState: physicalState == .crashed || mode == .emergencyStop,
            isDisarmedState: physicalState == .disarmed || !isArmed,
            hasMarkerTarget: targetMarkerState != nil,
            canUseMarkerGuidance: canStartTargetMarkerAutoNavigation,
            markerGuidanceRequested: mode == .autoPath && targetMarkerState != nil
        )
    }

    private func refreshFlightControlDiagnostics(
        using controlState: ResolvedControlState? = nil,
        authorityOverride: FlightControlAuthority? = nil,
        contextOverride: FlightControlRoutingContext? = nil
    ) {
        let resolvedControlState = controlState ?? resolvedInputState
        let inputState = buildFlightInputState(from: resolvedControlState)
        let context = contextOverride ?? buildFlightControlRoutingContext()
        let authority = authorityOverride ?? flightControlRouter.currentAuthority
        flightControlDiagnostics = flightControlRouter.diagnostics(
            authority: authority,
            inputState: inputState,
            context: context
        )
        refreshMissionStatus()
    }

    private func resolvedFlightControlMode(for authority: FlightControlAuthority) -> FlightControlMode {
        if selectedDroneProfile.airframeClass == .fixedWing || selectedDroneProfile.airframeClass == .hybridVTOL {
            switch mode {
            case .autoPath, .returnHome, .takeoff, .landing:
                return .stabilized
            case .manual, .hover, .emergencyStop:
                break
            }
        }

        if selectedDroneProfile.airframeClass == .multirotor,
           mode == .hover {
            return .hoverAssist
        }

        if selectedDroneProfile.airframeClass == .multirotor,
           authority == .markerGuidance,
           mode == .autoPath,
           targetMarkerState != nil {
            return .hoverAssist
        }
        return flightControlMode
    }

    private func resetFlightControlRouting() {
        flightControlRouter.reset()
        manualYawIntent = 0.0
        resolvedInputState = .neutral
        refreshFlightControlDiagnostics(authorityOverride: FlightControlAuthority.none)
    }

    private func resolveControllerInteractionMode() -> ControllerInteractionMode {
        if controllerUIBridge.isTextInputPresented {
            return .textInput
        }

        if isControllerHubVisible ||
            externalControllerOverlayActive ||
            isMissionMapVisible ||
            isPayloadPanelVisible ||
            isCommsLinkPanelVisible ||
            (isParametersPanelVisible && activeControlModule != nil) ||
            isControllerCursorEnabled {
            return .uiNavigation
        }

        return .flight
    }

    private func syncControllerInteractionMode() {
        let nextMode = resolveControllerInteractionMode()
        if controllerInteractionMode != nextMode {
            controllerInteractionMode = nextMode
            debugControllerLog("Mode -> \(nextMode.rawValue)")
        }
    }

    private func handleControllerSystemActions(
        using controlState: ResolvedControlState
    ) {
        if controlState.toggleControllerCursorTriggered {
            toggleControllerCursor()
        }

        if controlState.openControllerHubTriggered {
            toggleControllerHub()
        }

        if isControllerHubVisible {
            if controlState.uiSectionPreviousTriggered {
                cycleControllerHubSection(step: -1)
            }
            if controlState.uiSectionNextTriggered {
                cycleControllerHubSection(step: 1)
            }
        }
    }

    private func processControllerUIInput(
        using controlState: ResolvedControlState,
        deltaTime: TimeInterval
    ) {
        handleControllerSystemActions(using: controlState)
        syncControllerInteractionMode()
        controllerUIBridge.update(
            from: controlState,
            mode: controllerInteractionMode,
            cursorEnabled: isControllerCursorEnabled,
            controllerConnected: inputManager.isSourceConnected(.gameController),
            deltaTime: deltaTime
        )
        controllerUIBridge.routeScroll(
            from: controlState,
            mode: controllerInteractionMode,
            deltaTime: deltaTime
        )
    }

    private func updateInputPipeline(deltaTime: TimeInterval) -> ResolvedControlState {
        inputManager.update(deltaTime: deltaTime)
        resolvedInputState = inputManager.currentState
        refreshGameControllerPresentation()
        return resolvedInputState
    }

    private func updateSpectatorRuntime(deltaTime: Float) {
        guard isSpectatorMode else {
            return
        }

        let keyboardSnapshot = keyboardInputService.currentInputSnapshot()
        let axis = keyboardSnapshot.axisInput
        let speedMultiplier: Float = axis.speedBoost ? 2.0 : 1.0
        sceneController.moveSpectatorCamera(
            forward: axis.forward,
            strafe: axis.strafe,
            deltaTime: deltaTime,
            speed: cameraConfiguration.free.moveSpeed * speedMultiplier
        )
        sceneController.updateSpectatorRuntime(camera: cameraConfiguration)
    }

    private func controllerResolvedControlState(
        from snapshot: InputSnapshot?
    ) -> ResolvedControlState {
        guard let snapshot, snapshot.isConnected else {
            return .neutral
        }

        return ResolvedControlState(
            yaw: snapshot.yaw,
            pitch: snapshot.pitch,
            roll: snapshot.roll,
            throttle: snapshot.throttle,
            cameraPan: snapshot.cameraPan,
            cameraTilt: snapshot.cameraTilt,
            uiPointerX: snapshot.uiPointerX,
            uiPointerY: snapshot.uiPointerY,
            uiScrollX: snapshot.uiScrollX,
            uiScrollY: snapshot.uiScrollY,
            precisionMode: snapshot.precisionMode,
            boostMode: snapshot.boostMode,
            isHoseSprayHeld: snapshot.isHoseSprayHeld,
            actions: snapshot.actions,
            dominantSource: .gameController
        )
    }

    private func refreshGameControllerPresentation(force: Bool = false) {
        let nextSourceKind = resolvedInputState.dominantSource
        if force || activeInputSourceKind != nextSourceKind {
            activeInputSourceKind = nextSourceKind
        }

        let nextActiveControllerName = gameControllerInputProvider.activeControllerName
        if force || activeGameControllerName != nextActiveControllerName {
            activeGameControllerName = nextActiveControllerName
        }

        let nextControllers = gameControllerInputProvider.connectedDeviceSummaries()
        if force || connectedGameControllers != nextControllers {
            connectedGameControllers = nextControllers
        }
        if nextControllers.isEmpty {
            if isControllerCursorEnabled {
                isControllerCursorEnabled = false
            }
            if isControllerHubVisible {
                isControllerHubVisible = false
            }
        }

        let nextRightStickMode = gameControllerInputProvider.currentRightStickHorizontalMode
        if force || gameControllerRightStickHorizontalMode != nextRightStickMode {
            gameControllerRightStickHorizontalMode = nextRightStickMode
        }

        if nextControllers.isEmpty {
            syncControllerInteractionMode()
        }
    }

    private func debugControllerLog(_ message: String) {
        #if DEBUG
        print("[ControllerInteraction] \(message)")
        #endif
    }

    private func currentAutoNavigationStatus() -> AutoNavigationStatus {
        if let synthesizedStatus = currentFixedWingAutoNavigationStatus() {
            return synthesizedStatus
        }
        if let synthesizedStatus = currentMultirotorMarkerNavigationStatus() {
            return synthesizedStatus
        }
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        return autoNavigationController.status(
            from: SIMD2<Float>(safePosition.x, safePosition.z)
        )
    }

    private func currentMultirotorMarkerNavigationStatus() -> AutoNavigationStatus? {
        guard selectedDroneProfile.airframeClass == .multirotor,
              mode == .autoPath,
              let marker = targetMarkerState else {
            return nil
        }

        let planarPosition = currentPlanarPosition()
        let distance = marker.distance(from: planarPosition)
        let bearing = marker.bearingDegrees(from: planarPosition)
        let travelAltitude = targetMarkerTravelAltitude()
        let phase: AutoNavigationPhase
        if distance <= 1.2 {
            phase = .hold
        } else if physicalState.isGroundRestState || state.position.y < travelAltitude - 1.2 {
            phase = .takeoff
        } else {
            phase = distance > 9.5 ? .cruise : .approach
        }

        return AutoNavigationStatus(
            isActive: true,
            phase: phase,
            distanceToTarget: distance,
            bearingDegrees: bearing,
            hasTarget: true
        )
    }

    private func currentFixedWingAutoNavigationStatus() -> AutoNavigationStatus? {
        guard selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL,
              let routePhase = fixedWingAutoNavigationPhase(
                for: fixedWingAutopilotDebugState,
                guidanceSource: activeFixedWingGuidanceSource
              ) else {
            return nil
        }

        let planarPosition = currentPlanarPosition()
        let distanceToTarget: Float = {
            if let activeTarget = missionExecutionState.activeTarget {
                let waypointDistance = simd_distance(planarPosition, activeTarget.position)
                if waypointDistance.isFinite {
                    return waypointDistance
                }
            }
            let remainingDistance = max(0.0, fixedWingAutopilotDebugState.remainingDistance)
            return remainingDistance.isFinite ? remainingDistance : .nan
        }()
        let bearingDegrees: Float = {
            if let marker = targetMarkerState {
                let markerBearing = marker.bearingDegrees(from: planarPosition)
                if markerBearing.isFinite {
                    return markerBearing
                }
            }
            let debugBearing = fixedWingAutopilotDebugState.desiredCourseDeg
            return debugBearing.isFinite ? debugBearing : .nan
        }()
        let isActive = mode == .autoPath || mode == .returnHome

        return AutoNavigationStatus(
            isActive: isActive,
            phase: routePhase,
            distanceToTarget: distanceToTarget,
            bearingDegrees: bearingDegrees,
            hasTarget: targetMarkerState != nil || activeRouteTargetSource == .mission
        )
    }

    private func fixedWingAutoNavigationPhase(
        for debugState: FixedWingAutopilotDebugState,
        guidanceSource: FixedWingGuidanceSource
    ) -> AutoNavigationPhase? {
        if guidanceSource == .none {
            return nil
        }
        switch debugState.missionState {
        case .idle, .failed:
            return nil
        case .aligningToLaunch, .climbout:
            return .takeoff
        case .capturingLeg, .trackingLeg, .recoveringSpeed:
            return .cruise
        case .flyByTurn:
            return .approach
        case .loitering, .completed:
            return .hold
        }
    }

    private func refreshCompassOverlay() {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        compassViewModel.update(
            headingRadians: finiteVector(state.orientation, fallback: lastFiniteState.orientation).z,
            dronePlanarPosition: SIMD2<Float>(safePosition.x, safePosition.z),
            targetMarker: targetMarkerState
        )
    }

    private var isMountedPayloadCameraAvailable: Bool {
        if mountedCADPayload != nil {
            return payloadState == .attached
        }

        guard payloadState == .attached, payloadMountState == .occupied else {
            return false
        }

        switch payloadDraftConfiguration.payloadType {
        case .cameraGimbal, .thermalCamera, .custom:
            return true
        case .cargoBox, .lidarModule, .laserRangefinder, .fireHose, .fireCapsuleLauncher, .agriculturalSprayer, .rescuePack, .sensorModule, .radioRelay:
            return false
        }
    }

    /// Stricter than `isMountedPayloadCameraAvailable`: excludes mounted CAD payloads, since
    /// those carry no `PayloadType` and the quick-select thermal binds must only fire when an
    /// actual EO/thermal-capable payload is on the airframe.
    private var isMountedThermalCapablePayload: Bool {
        guard mountedCADPayload == nil else {
            return false
        }

        guard payloadState == .attached, payloadMountState == .occupied else {
            return false
        }

        switch payloadDraftConfiguration.payloadType {
        case .cameraGimbal, .thermalCamera, .custom:
            return true
        case .cargoBox, .lidarModule, .laserRangefinder, .fireHose, .fireCapsuleLauncher, .agriculturalSprayer, .rescuePack, .sensorModule, .radioRelay:
            return false
        }
    }

    private var isMountedRangefinderAvailable: Bool {
        guard mountedCADPayload == nil else {
            return false
        }

        guard payloadState == .attached, payloadMountState == .occupied else {
            return false
        }

        return payloadDraftConfiguration.payloadType == .laserRangefinder
    }

    private var isMountedHoseAvailable: Bool {
        guard mountedCADPayload == nil else {
            return false
        }

        guard payloadState == .attached, payloadMountState == .occupied else {
            return false
        }

        return payloadDraftConfiguration.payloadType == .fireHose
    }

    private var isMountedCapsuleLauncherAvailable: Bool {
        guard mountedCADPayload == nil else {
            return false
        }

        guard payloadState == .attached, payloadMountState == .occupied else {
            return false
        }

        return payloadDraftConfiguration.payloadType == .fireCapsuleLauncher
    }

    /// Unlike the fire hose/capsule launcher, not gated to a specific mission scenario kind —
    /// the sprayer is a general-purpose payload usable in sandbox flight or any mission.
    private var isMountedAgriculturalSprayerAvailable: Bool {
        guard mountedCADPayload == nil else {
            return false
        }

        guard payloadState == .attached, payloadMountState == .occupied else {
            return false
        }

        return payloadDraftConfiguration.payloadType == .agriculturalSprayer
    }

    private var payloadCameraFeedLabel: String {
        switch payloadCameraController.opticsState.mode {
        case .optical:
            return "EO CAM"
        case .thermalStub:
            return "THERMAL"
        case .nightStub:
            return "NV CAM"
        }
    }

    private func publishPayloadCameraOpticsState() {
        payloadCameraOpticsState = payloadCameraController.opticsState
        sceneController.setPayloadCameraOpticsState(payloadCameraOpticsState)
        payloadThermalState.isAvailable = payloadCameraOpticsState.isAvailable
        payloadThermalState.isEnabled = payloadCameraOpticsState.isAvailable
            && payloadCameraOpticsState.mode == .thermalStub
    }

    private func refreshPayloadCameraStatus(deltaTime: TimeInterval = 0.0) {
        if !isMountedPayloadCameraAvailable {
            previousPayloadCameraVelocity = nil
            previousPayloadCameraAngularVelocity = nil
        }
        payloadCameraController.setOpticsAvailability(
            isAvailable: isMountedPayloadCameraAvailable,
            isPowered: isMountedPayloadCameraAvailable,
            feedLabel: payloadCameraFeedLabel
        )
        let targetDistance = sceneController.payloadCameraTargetDistance(maxDistance: 500.0)
        let linearSpeed = Double(simd_length(state.velocity))
        let angularSpeed = Double(simd_length(state.angularVelocity))
        let linearAcceleration: Double
        let angularAcceleration: Double
        if deltaTime > 0.0001,
           let previousVelocity = previousPayloadCameraVelocity,
           let previousAngularVelocity = previousPayloadCameraAngularVelocity {
            linearAcceleration = Double(simd_length((state.velocity - previousVelocity) / Float(deltaTime)))
            angularAcceleration = Double(simd_length((state.angularVelocity - previousAngularVelocity) / Float(deltaTime)))
        } else {
            linearAcceleration = 0.0
            angularAcceleration = 0.0
        }

        let speedStabilityLimit = selectedDroneProfile.airframeClass == .multirotor
            ? max(payloadCameraController.opticsState.stabilizationSpeedLimitMps, 3.0)
            : 14.0
        let linearStability = min(max(1.0 - linearSpeed / speedStabilityLimit, 0.0), 1.0)
        let angularStability = min(max(1.0 - angularSpeed / 0.65, 0.0), 1.0)
        let accelerationStability = min(max(1.0 - linearAcceleration / 3.6, 0.0), 1.0)
        let angularAccelerationStability = min(max(1.0 - angularAcceleration / 5.0, 0.0), 1.0)
        let platformStability = min(
            max(
                linearStability * 0.42 +
                angularStability * 0.34 +
                accelerationStability * 0.12 +
                angularAccelerationStability * 0.12,
                0.0
            ),
            1.0
        )

        let motionDisturbance = min(
            max(
                angularSpeed / 0.55 * 0.46 +
                angularAcceleration / 3.0 * 0.34 +
                linearAcceleration / 2.8 * 0.14 +
                linearSpeed / 1.2 * 0.06,
                0.0
            ),
            1.0
        )
        payloadCameraController.updateStabilization(
            speedMetersPerSecond: linearSpeed,
            airframeClass: selectedDroneProfile.airframeClass
        )
        payloadCameraController.updateTargetDistance(targetDistance)
        payloadCameraController.updateOptics(
            dt: deltaTime,
            platformStability: platformStability,
            motionDisturbance: motionDisturbance
        )
        publishPayloadCameraOpticsState()
        previousPayloadCameraVelocity = state.velocity
        previousPayloadCameraAngularVelocity = state.angularVelocity

        sceneController.setPayloadCameraFocusReleaseID(payloadCameraController.trackedReleaseID)
        let sceneSnapshot = sceneController.payloadCameraSnapshot(for: payloadCameraController.trackedReleaseID)
        if let restoreMode = payloadCameraController.sync(
            sceneSnapshot: sceneSnapshot,
            currentMode: cameraConfiguration.mode
        ) {
            let oldMode = cameraConfiguration.mode
            cameraConfiguration.mode = restoreMode
            syncCameraSystem(from: oldMode)
        }
        payloadCameraStatus = payloadCameraController.status
        let signals = payloadCameraController.consumeMissionSignals()
        if !signals.isEmpty {
            payloadMissionSignals.append(contentsOf: signals)
            if payloadMissionSignals.count > 24 {
                payloadMissionSignals.removeFirst(payloadMissionSignals.count - 24)
            }
        }
        refreshRangefinderStatus()
        refreshHoseAimStatus()
        refreshCapsuleLauncherStatus(deltaTime: deltaTime)
        refreshAgriculturalSprayerStatus(deltaTime: deltaTime)
        refreshFlightControlDiagnostics()
    }

    /// No aim/raycast needed at all (unlike the hose) — the launcher just needs to know it's
    /// mounted, keep its ammo/rig state in sync, run the truck-recharge timer, and keep the
    /// ground-projected blast-radius reticle plus the bombardier camera rig following the drone.
    /// Cheap enough to run unconditionally every tick.
    private func refreshCapsuleLauncherStatus(deltaTime: TimeInterval = 0.0) {
        capsuleController.setAvailability(
            isAvailable: isMountedCapsuleLauncherAvailable,
            isPowered: isMountedCapsuleLauncherAvailable,
            rigSize: payloadDraftConfiguration.fireCapsuleSize,
            rigCount: payloadDraftConfiguration.fireCapsuleCount
        )
        capsuleController.updateRecharge(
            isEligible: isCapsuleRechargeEligible(),
            secondsPerCapsule: FireCapsuleTuning.rechargeSecondsPerCapsule(
                for: missionScenarioConfiguration?.parameters.difficulty ?? .medium
            ),
            deltaTime: deltaTime
        )
        capsuleState = capsuleController.state
        sceneController.setCapsuleLauncherOpticsAvailability(capsuleState.isAvailable)

        if capsuleState.isAvailable {
            sceneController.setFireCapsuleTargetReticle(
                dronePlanarPosition: currentPlanarPosition(),
                radiusMeters: capsuleState.capsuleSize.blastRadiusMeters
            )
        } else {
            sceneController.setFireCapsuleTargetReticle(dronePlanarPosition: nil, radiusMeters: 0)
        }

        let capsuleSignals = capsuleController.consumeMissionSignals()
        if !capsuleSignals.isEmpty {
            payloadMissionSignals.append(contentsOf: capsuleSignals)
            if payloadMissionSignals.count > 24 {
                payloadMissionSignals.removeFirst(payloadMissionSignals.count - 24)
            }
        }
    }

    /// No aim/gimbal, no mission-scenario gating (unlike the hose/capsule launcher) — the
    /// sprayer just needs to know it's mounted and drain its tank while the trigger is held.
    /// The tank's liquid mass is mutated live into `installedPayloadConfiguration.payloadMass`
    /// so the airframe actually gets lighter (and more agile) as it empties, same idea as the
    /// fiber-optic reel losing mass as it pays out.
    private func refreshAgriculturalSprayerStatus(deltaTime: TimeInterval = 0.0) {
        agriculturalSprayerController.setAvailability(
            isAvailable: isMountedAgriculturalSprayerAvailable,
            isPowered: isMountedAgriculturalSprayerAvailable,
            configuredTankLiters: Double(payloadDraftConfiguration.agriculturalSprayerTankLiters)
        )
        let drainedLiters = agriculturalSprayerController.drain(deltaTime: Float(deltaTime))
        if drainedLiters > 0.0, let currentMass = installedPayloadConfiguration?.payloadMass,
           installedPayloadConfiguration?.payloadType == .agriculturalSprayer {
            let drainedMassKg = Float(drainedLiters) * AgriculturalSprayerTuning.liquidDensityKgPerLiter
            let newMass = max(AgriculturalSprayerTuning.hardwareOverheadKg, currentMass - drainedMassKg)
            installedPayloadConfiguration?.payloadMass = newMass
            refreshPayloadRuntimeState()
        }
        agriculturalSprayerState = agriculturalSprayerController.state
        sceneController.setAgriculturalSprayerSpraying(
            agriculturalSprayerState.isSpraying,
            dronePlanarPosition: currentPlanarPosition()
        )

        #if DEBUG
        let debugSummary = "mounted=\(isMountedAgriculturalSprayerAvailable) " +
            "type=\(payloadDraftConfiguration.payloadType.rawValue) " +
            "available=\(agriculturalSprayerState.isAvailable) powered=\(agriculturalSprayerState.isPowered) " +
            "spraying=\(agriculturalSprayerState.isSpraying) tank=\(agriculturalSprayerState.tankRemainingLiters)"
        if debugSummary != lastLoggedAgriSprayerDebugState {
            print("[AgriSprayer] \(debugSummary)")
            lastLoggedAgriSprayerDebugState = debugSummary
        }
        #endif
    }

    /// The drone must actually LAND (not just hover) within a small radius of the fire truck to
    /// reload — mirrors `enforceHoseTetherConstraint`'s distance-to-truck calc, but only reads
    /// distance, doesn't clamp position (there's no physical tether for the capsule launcher).
    private func isCapsuleRechargeEligible() -> Bool {
        guard activeMissionScenarioKind == .fireResponse,
              capsuleController.state.isAvailable,
              physicalState == .landed,
              let truckPosition = sceneController.currentFireTruckWorldPosition() else {
            return false
        }
        return simd_length(state.position - truckPosition) <= FireCapsuleTuning.rechargeZoneRadiusMeters
    }

    private func refreshRangefinderStatus() {
        rangefinderController.setAvailability(
            isAvailable: isMountedRangefinderAvailable,
            isPowered: isMountedRangefinderAvailable
        )
        sceneController.updateRangefinderGimbal(state: rangefinderController.opticsState)
        let distance = rangefinderController.opticsState.isArmed
            ? sceneController.rangefinderTargetDistance(maxDistance: rangefinderController.opticsState.maxRangeMeters)
            : nil
        rangefinderController.updateMeasuredDistance(distance)
        sceneController.updateRangefinderBeam(state: rangefinderController.opticsState)
        rangefinderOpticsState = rangefinderController.opticsState

        let rangefinderSignals = rangefinderController.consumeMissionSignals()
        if !rangefinderSignals.isEmpty {
            payloadMissionSignals.append(contentsOf: rangefinderSignals)
            if payloadMissionSignals.count > 24 {
                payloadMissionSignals.removeFirst(payloadMissionSignals.count - 24)
            }
        }
    }

    private func refreshHoseAimStatus() {
        hoseController.setAvailability(
            isAvailable: isMountedHoseAvailable,
            isPowered: isMountedHoseAvailable
        )
        // No hose mounted (SAR and every non-fire-response mission) → nothing to gimbal, aim, or
        // spray. Skip all scene-graph touches, including `ensureHoseRig()`'s node creation. This
        // ran every tick before, and once the main thread starts touching the SceneKit graph while
        // the render thread holds its scene lock (busy drawing the forest), each touch can stall
        // up to a full frame — so an empty no-op here was still costing ~16ms/tick.
        guard isMountedHoseAvailable else {
            hoseOpticsState = hoseController.opticsState
            return
        }
        sceneController.updateHoseGimbal(state: hoseController.opticsState)

        // The nozzle raycast (`updateHoseAimAndSpray`) is a full-scene hit-test — by far the most
        // expensive thing this function does, and it used to run unconditionally every tick
        // whenever a hose was mounted, whether or not the operator was even looking at it. The
        // suppression mechanic only reacts to the aimed tree while the trigger is held
        // (`FireResponseRuntime.applySuppression` ignores `aimedFireIndex` whenever `isSpraying`
        // is false), and the HUD's aim indicator is only ever visible while actually looking
        // through the hose's own payload-optics view — so flying around normally with a hose
        // mounted (most of a fire-response mission) can skip the raycast entirely.
        let isSpraying = hoseController.opticsState.isSpraying
        let isViewingHoseOptics = cameraConfiguration.mode == .payloadOptics
            && !payloadCameraOpticsState.isAvailable
            && !rangefinderOpticsState.isAvailable
            && hoseController.opticsState.isAvailable
        let shouldSampleAim = hoseController.opticsState.isAvailable && (isSpraying || isViewingHoseOptics)

        let aimedIndex: Int?
        if shouldSampleAim {
            aimedIndex = sceneController.updateHoseAimAndSpray(
                fireTreeNodes: sceneController.fireTreeNodes,
                isSpraying: isSpraying
            )
        } else {
            aimedIndex = nil
            sceneController.hideHoseSprayVisual()
        }

        hoseController.updateAimedFire(
            index: aimedIndex,
            progress: fireResponseRuntime?.suppressionProgress(for: aimedIndex) ?? 0.0
        )
        hoseOpticsState = hoseController.opticsState

        let hoseSignals = hoseController.consumeMissionSignals()
        if !hoseSignals.isEmpty {
            payloadMissionSignals.append(contentsOf: hoseSignals)
            if payloadMissionSignals.count > 24 {
                payloadMissionSignals.removeFirst(payloadMissionSignals.count - 24)
            }
        }
    }

    private func buildWarnings() -> [String] {
        let fleetWarningStatus = currentFleetStatusSnapshot()
        var output = DroneWarningBuilder(
            isArmed: isArmed,
            physicalState: physicalState,
            collisionAnalysis: collisionAnalysis,
            weather: weather,
            batteryState: batteryState,
            batteryFireActive: batteryFireActive,
            damageState: damageState,
            collisionAftermathState: collisionAftermathState,
            signalLossCause: signalLossCause,
            payloadSelfInteractionSeverity: payloadSelfInteractionSeverity,
            selectedDroneProfile: selectedDroneProfile,
            state: state,
            fleetStatus: fleetWarningStatus,
            mode: mode
        ).build()
        if let mountedCADPayload {
            output.append(contentsOf: mountedCADPayload.runtimeWarningKeys(
                maxPayloadMass: activeUAVProfile?.payloadDataResolution.maxPayloadMass
            ))
        }
        if isHoseTetherTaut {
            output.append("warning.hose_tether_taut")
        }
        return Array(NSOrderedSet(array: output)) as? [String] ?? output
    }

    private func buildTelemetryMetadata() -> TelemetrySessionMetadata {
        TelemetrySessionMetadata(
            projectID: currentProjectID,
            projectName: currentProjectName,
            modelID: selectedDroneProfile.id,
            modelName: selectedDroneProfile.displayName,
            manufacturer: selectedDroneProfile.manufacturer,
            isAbstractModel: selectedDroneProfile.isAbstract,
            abstractParametersSummary: selectedDroneProfile.isAbstract ? abstractParametersSummary : "n/a",
            weatherPreset: weather.preset.title,
            weatherIntensity: weather.intensity,
            terrainPreset: terrain.preset.title,
            terrainDensity: terrain.density,
            cameraMode: cameraConfiguration.mode.title,
            controlMode: flightControlMode.title
        )
    }

    private func buildProjectSnapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            schemaVersion: 3,
            projectID: currentProjectID,
            projectName: currentProjectName,
            savedAt: Date(),
            selectedDroneModelID: selectedDroneProfile.id,
            workbenchBuild: selectedDroneProfile.workbenchBuild,
            flightModeRaw: mode.rawValue,
            flightControlModeRaw: flightControlMode.rawValue,
            diagnosticModeRaw: diagnosticMode.rawValue,
            controlValues: ProjectSnapshot.ControlValues(
                x: controlValues.x,
                y: controlValues.y,
                z: controlValues.z,
                roll: controlValues.roll,
                pitch: controlValues.pitch,
                yaw: controlValues.yaw,
                throttle: controlValues.throttle
            ),
            abstractParameters: ProjectSnapshot.AbstractParameters(
                massKg: abstractParameters.massKg,
                unfoldedMmX: abstractParameters.unfoldedMm.x,
                unfoldedMmY: abstractParameters.unfoldedMm.y,
                unfoldedMmZ: abstractParameters.unfoldedMm.z,
                batteryEnergyWh: abstractParameters.batteryEnergyWh,
                maxHorizontalSpeedMps: abstractParameters.maxHorizontalSpeedMps,
                maxAscentSpeedMps: abstractParameters.maxAscentSpeedMps,
                maxDescentSpeedMps: abstractParameters.maxDescentSpeedMps,
                maxWindResistanceMps: abstractParameters.maxWindResistanceMps,
                controlResponsiveness: abstractParameters.controlResponsiveness,
                collisionRadiusMeters: abstractParameters.collisionRadiusMeters
            ),
            weather: ProjectSnapshot.Weather(
                presetRaw: weather.preset.rawValue,
                intensity: weather.intensity,
                windDirectionDeg: weather.windDirectionDeg,
                windSpeedMps: weather.windSpeedMps,
                gusts: weather.gusts
            ),
            terrain: ProjectSnapshot.Terrain(
                presetRaw: terrain.preset.rawValue,
                mapScaleRaw: terrain.mapScale.rawValue,
                density: terrain.density,
                seed: terrain.seed,
                safeSpawnRadius: terrain.safeSpawnRadius,
                showsBoundaryBarrier: isBoundaryBarrierVisible
            ),
            camera: ProjectSnapshot.Camera(
                modeRaw: cameraConfiguration.mode.rawValue,
                fov: cameraConfiguration.fov,
                sensitivity: cameraConfiguration.sensitivity,
                smoothing: cameraConfiguration.smoothing,
                invertLookX: cameraConfiguration.invertLookX,
                invertLookY: cameraConfiguration.invertLookY,
                sensitivityProfileRaw: cameraConfiguration.sensitivityProfile.rawValue,
                lookNudgeStepDeg: cameraConfiguration.lookNudgeStepDeg,
                freeMoveSpeed: cameraConfiguration.free.moveSpeed,
                freeZoomSensitivity: cameraConfiguration.free.zoomSensitivity,
                freeDistance: cameraConfiguration.free.distance,
                freeMinDistance: cameraConfiguration.free.minDistance,
                freeMaxDistance: cameraConfiguration.free.maxDistance,
                followDistance: cameraConfiguration.follow.distance,
                followHeight: cameraConfiguration.follow.height,
                followLateralOffset: cameraConfiguration.follow.lateralOffset,
                followMinDistance: cameraConfiguration.follow.minDistance,
                followMaxDistance: cameraConfiguration.follow.maxDistance,
                orbitDistance: cameraConfiguration.orbit.distance,
                orbitHeight: cameraConfiguration.orbit.height,
                orbitAngularSpeed: cameraConfiguration.orbit.angularSpeed,
                orbitMinDistance: cameraConfiguration.orbit.minDistance,
                orbitMaxDistance: cameraConfiguration.orbit.maxDistance,
                fpvStabilization: cameraConfiguration.fpv.stabilization,
                fpvShake: cameraConfiguration.fpv.shake,
                fpvYawLimitDeg: cameraConfiguration.fpv.yawLimitDeg,
                fpvPitchLimitDeg: cameraConfiguration.fpv.pitchLimitDeg,
                fpvNearClip: cameraConfiguration.fpv.nearClip,
                fpvMountOffsetX: cameraConfiguration.fpv.mountOffset.x,
                fpvMountOffsetY: cameraConfiguration.fpv.mountOffset.y,
                fpvMountOffsetZ: cameraConfiguration.fpv.mountOffset.z,
                fpvHideObstructingParts: cameraConfiguration.fpv.hideObstructingParts,
                topHeight: cameraConfiguration.top.height,
                topMinHeight: cameraConfiguration.top.minHeight,
                topMaxHeight: cameraConfiguration.top.maxHeight,
                topForwardLead: cameraConfiguration.top.forwardLead
            ),
            battery: ProjectSnapshot.Battery(
                chargePercent: batteryState.chargePercent,
                healthPercent: batteryState.healthPercent,
                powerDrawW: batteryState.powerDrawW,
                remainingTimeSec: batteryState.remainingTimeSec
            ),
            state: ProjectSnapshot.State(
                position: ProjectSnapshot.Vec3(x: state.position.x, y: state.position.y, z: state.position.z),
                velocity: ProjectSnapshot.Vec3(x: state.velocity.x, y: state.velocity.y, z: state.velocity.z),
                orientation: ProjectSnapshot.Vec3(x: state.orientation.x, y: state.orientation.y, z: state.orientation.z),
                throttle: state.throttle,
                motorThrottle: state.motorThrottle,
                forwardAirspeed: state.forwardAirspeed
            ),
            damageHealthByComponent: Dictionary(
                uniqueKeysWithValues: damageState.healthByComponent.map { ($0.key.rawValue, $0.value) }
            ),
            hiddenDamageComponents: damageState.hiddenComponents.map(\.rawValue),
            selectedDamageComponentRaw: damageState.selectedComponent?.rawValue,
            thermalByComponent: Dictionary(
                uniqueKeysWithValues: thermalState.temperatureByComponent.map { ($0.key.rawValue, $0.value) }
            ),
            missionTimeline: missionPersistenceAdapter.timelineForPersistence(missionTimeline),
            missionDebrief: missionPersistenceAdapter.debriefForPersistence(missionDebrief),
            componentDamageRuntime: componentGraph.components.sorted(by: { $0.id < $1.id }).map { component in
                ProjectSnapshot.ComponentDamageRuntime(
                    componentID: component.id,
                    integrity: component.integrity,
                    residualStrength: component.residualStrength,
                    stiffnessScale: component.stiffnessScale,
                    bendRadians: ProjectSnapshot.Vec3(
                        x: component.deformation.bendRadians.x,
                        y: component.deformation.bendRadians.y,
                        z: component.deformation.bendRadians.z
                    ),
                    translationMeters: ProjectSnapshot.Vec3(
                        x: component.deformation.translationMeters.x,
                        y: component.deformation.translationMeters.y,
                        z: component.deformation.translationMeters.z
                    ),
                    vibrationScale: component.deformation.vibrationScale,
                    attachmentStateRaw: component.attachmentState.rawValue,
                    forceScale: component.performance.forceScale,
                    torqueScale: component.performance.torqueScale,
                    efficiencyScale: component.performance.efficiencyScale,
                    responseSpeedScale: component.performance.responseSpeedScale,
                    rangeScale: component.performance.rangeScale,
                    dragScale: component.performance.dragScale,
                    performanceVibrationScale: component.performance.vibrationScale
                )
            },
            connectionDamageRuntime: componentGraph.structuralConnections
                .sorted(by: { $0.childComponentID < $1.childComponentID })
                .map { connection in
                    ProjectSnapshot.ConnectionDamageRuntime(
                        childComponentID: connection.childComponentID,
                        residualStrength: connection.residualStrength,
                        stiffnessScale: connection.stiffnessScale,
                        attachmentStateRaw: connection.state.rawValue
                    )
                },
            failureRuntime: ProjectSnapshot.FailureRuntime(
                seed: componentFailureRuntime.persistenceSeed,
                generatorState: componentFailureRuntime.persistenceGeneratorState,
                failures: componentFailureRuntime.failures.values
                    .sorted(by: { $0.componentID < $1.componentID })
                    .map { failure in
                        ProjectSnapshot.ActiveFailureRuntime(
                            componentID: failure.componentID,
                            modeRaw: failure.mode.rawValue,
                            frozenSurfaceValue: failure.frozenSurfaceValue,
                            intermittentActive: failure.intermittentActive,
                            intermittentTimer: failure.intermittentTimer
                        )
                    }
            ),
            massPropertiesRevision: componentGraph.massPropertiesRevision,
            meshWorld: attachedMeshWorld
        )
    }

    private func applyProjectSnapshot(_ snapshot: ProjectSnapshot) {
        let abstract = AbstractDroneParameters(
            massKg: snapshot.abstractParameters.massKg,
            unfoldedMm: DroneDimensionsMM(
                x: snapshot.abstractParameters.unfoldedMmX,
                y: snapshot.abstractParameters.unfoldedMmY,
                z: snapshot.abstractParameters.unfoldedMmZ
            ),
            batteryEnergyWh: snapshot.abstractParameters.batteryEnergyWh,
            maxHorizontalSpeedMps: snapshot.abstractParameters.maxHorizontalSpeedMps,
            maxAscentSpeedMps: snapshot.abstractParameters.maxAscentSpeedMps,
            maxDescentSpeedMps: snapshot.abstractParameters.maxDescentSpeedMps,
            maxWindResistanceMps: snapshot.abstractParameters.maxWindResistanceMps,
            controlResponsiveness: snapshot.abstractParameters.controlResponsiveness,
            collisionRadiusMeters: snapshot.abstractParameters.collisionRadiusMeters
        )
        abstractParameters = abstract
        var restoredProfiles = LIPODroneModelRepository(abstractParameters: abstract).allProfiles
        for build in WorkbenchBuildStore.listLibraryBuilds() {
            let profile = UAVBuildProfileSynthesizer.synthesizeProfile(for: build)
            if let index = restoredProfiles.firstIndex(where: { $0.id == profile.id }) {
                restoredProfiles[index] = profile
            } else {
                restoredProfiles.append(profile)
            }
        }
        if let embeddedBuild = snapshot.workbenchBuild {
            let embeddedProfile = UAVBuildProfileSynthesizer.synthesizeProfile(for: embeddedBuild)
            if let index = restoredProfiles.firstIndex(where: { $0.id == embeddedProfile.id }) {
                restoredProfiles[index] = embeddedProfile
            } else {
                restoredProfiles.append(embeddedProfile)
            }
        }
        availableDroneProfiles = restoredProfiles

        let selectedModelID = snapshot.workbenchBuild.map(UAVBuildProfileSynthesizer.profileID(for:))
            ?? LIPODroneModelRepository.canonicalModelID(snapshot.selectedDroneModelID)
        if let profile = availableDroneProfiles.first(where: { $0.id == selectedModelID }) {
            selectedDroneProfile = profile
            activeUAVProfile = Self.resolveActiveUAVProfile(for: profile, abstractParameters: abstract)
            sceneController.setDroneProfile(profile)
            resetPayloadForProfileSwitch()
            normalizeMissionLaunchConfigurationForSelectedProfile()
        }

        _ = DroneFlightMode(rawValue: snapshot.flightModeRaw)
        // Stable baseline: always load into manual mode to avoid unexpected auto movement at spawn.
        setFlightMode(.manual, reason: "load_project_baseline_manual")
        if let savedControlMode = FlightControlMode(rawValue: snapshot.flightControlModeRaw) {
            flightControlMode = savedControlMode
        }
        if let savedDiagnosticMode = DiagnosticOverlayMode(rawValue: snapshot.diagnosticModeRaw) {
            diagnosticMode = savedDiagnosticMode
        }

        controlValues = DroneControlValues(
            x: snapshot.controlValues.x,
            y: snapshot.controlValues.y,
            z: snapshot.controlValues.z,
            roll: snapshot.controlValues.roll,
            pitch: snapshot.controlValues.pitch,
            yaw: snapshot.controlValues.yaw,
            throttle: snapshot.controlValues.throttle
        )

        if let weatherPreset = WeatherPreset(rawValue: snapshot.weather.presetRaw) {
            weather.preset = weatherPreset
        }
        weather.intensity = snapshot.weather.intensity
        weather.windDirectionDeg = snapshot.weather.windDirectionDeg
        weather.windSpeedMps = snapshot.weather.windSpeedMps
        weather.gusts = snapshot.weather.gusts

        attachedMeshWorld = snapshot.meshWorld
        if let terrainPreset = TerrainPreset(rawValue: snapshot.terrain.presetRaw) {
            terrain.preset = terrainPreset
        }
        if let mapScaleRaw = snapshot.terrain.mapScaleRaw,
           let mapScale = MapScale.fromPersistedRawValue(mapScaleRaw) {
            terrain.mapScale = mapScale
        } else {
            terrain.mapScale = .x16
        }
        terrain.density = snapshot.terrain.density
        terrain.seed = snapshot.terrain.seed
        terrain.safeSpawnRadius = max(
            snapshot.terrain.safeSpawnRadius > 0.1
                ? snapshot.terrain.safeSpawnRadius
                : 0.0,
            recommendedSafeSpawnRadius(for: terrain.mapScale)
        )
        normalizeTerrainForSelectedDroneProfile()
        isBoundaryBarrierVisible = snapshot.terrain.showsBoundaryBarrier ?? false

        if let cameraMode = CameraMode.fromStoredRaw(snapshot.camera.modeRaw) {
            fpvEnteredViaZoomEngage = false
            cameraConfiguration.mode = cameraMode == .payload ? .follow : cameraMode
        }
        cameraConfiguration.fov = snapshot.camera.fov
        cameraConfiguration.sensitivity = snapshot.camera.sensitivity
        cameraConfiguration.smoothing = snapshot.camera.smoothing
        cameraConfiguration.invertLookX = snapshot.camera.invertLookX
        cameraConfiguration.invertLookY = snapshot.camera.invertLookY
        cameraConfiguration.sensitivityProfile = CameraSensitivityProfile(rawValue: snapshot.camera.sensitivityProfileRaw) ?? .medium
        cameraConfiguration.lookNudgeStepDeg = snapshot.camera.lookNudgeStepDeg
        // minDistance/maxDistance are intentionally NOT restored from the snapshot: they are
        // derived, size-aware safety floors (see `fpvAutoEngageDistance`/`updateCameras`'s
        // `chaseDistanceRange`), not a user preference, and an older save predating a floor
        // change would otherwise silently reintroduce a stale, larger floor that fights the
        // current one — the exact bug behind "zoom stops well short of the aircraft."
        cameraConfiguration.free.moveSpeed = snapshot.camera.freeMoveSpeed
        cameraConfiguration.free.zoomSensitivity = snapshot.camera.freeZoomSensitivity
        cameraConfiguration.free.distance = snapshot.camera.freeDistance
        cameraConfiguration.follow.distance = snapshot.camera.followDistance
        cameraConfiguration.follow.height = snapshot.camera.followHeight
        cameraConfiguration.follow.lateralOffset = snapshot.camera.followLateralOffset
        cameraConfiguration.orbit.distance = snapshot.camera.orbitDistance
        cameraConfiguration.orbit.height = snapshot.camera.orbitHeight
        cameraConfiguration.orbit.angularSpeed = snapshot.camera.orbitAngularSpeed
        cameraConfiguration.fpv = FPVCameraState(
            stabilization: snapshot.camera.fpvStabilization,
            shake: snapshot.camera.fpvShake,
            yawLimitDeg: snapshot.camera.fpvYawLimitDeg,
            pitchLimitDeg: snapshot.camera.fpvPitchLimitDeg,
            nearClip: snapshot.camera.fpvNearClip,
            mountOffset: SIMD3<Float>(
                snapshot.camera.fpvMountOffsetX,
                snapshot.camera.fpvMountOffsetY,
                snapshot.camera.fpvMountOffsetZ
            ),
            hideObstructingParts: snapshot.camera.fpvHideObstructingParts
        )
        cameraConfiguration.top = TopCameraState(
            height: snapshot.camera.topHeight ?? cameraConfiguration.top.height,
            minHeight: snapshot.camera.topMinHeight ?? cameraConfiguration.top.minHeight,
            maxHeight: snapshot.camera.topMaxHeight ?? cameraConfiguration.top.maxHeight,
            forwardLead: snapshot.camera.topForwardLead ?? cameraConfiguration.top.forwardLead
        )

        batteryState = BatteryState(
            chargePercent: snapshot.battery.chargePercent,
            healthPercent: snapshot.battery.healthPercent,
            powerDrawW: snapshot.battery.powerDrawW,
            remainingTimeSec: snapshot.battery.remainingTimeSec
        )

        state = DroneState(
            position: SIMD3<Float>(
                snapshot.state.position.x,
                snapshot.state.position.y,
                snapshot.state.position.z
            ),
            velocity: SIMD3<Float>(
                snapshot.state.velocity.x,
                snapshot.state.velocity.y,
                snapshot.state.velocity.z
            ),
            orientation: SIMD3<Float>(
                snapshot.state.orientation.x,
                snapshot.state.orientation.y,
                snapshot.state.orientation.z
            ),
            angularVelocity: SIMD3<Float>(repeating: 0.0),
            throttle: snapshot.state.throttle,
            motorThrottle: snapshot.state.motorThrottle,
            rotorAngularSpeed: SIMD4<Float>(repeating: 0.0),
            forwardAirspeed: snapshot.state.forwardAirspeed,
            physicalState: .disarmed,
            mode: mode
        )
        state.propulsionUnits = selectedDroneProfile.propulsionUnitTemplate
        sanitizeDynamicStateForSpawn(context: "load_project")
        controlValues = neutralControls(from: state)

        let healthPairs: [(DamageComponent, Float)] = snapshot.damageHealthByComponent.compactMap { entry in
            guard let component = DamageComponent(rawValue: entry.key) else { return nil }
            return (component, entry.value)
        }
        let healthByComponent = Dictionary(uniqueKeysWithValues: healthPairs)
        let hiddenComponents = Set(snapshot.hiddenDamageComponents.compactMap(DamageComponent.init(rawValue:)))
        damageState = DamageState(
            healthByComponent: healthByComponent,
            hiddenComponents: hiddenComponents,
            selectedComponent: snapshot.selectedDamageComponentRaw.flatMap(DamageComponent.init(rawValue:))
        )

        let thermalPairs: [(DamageComponent, Float)] = snapshot.thermalByComponent.compactMap { entry in
            guard let component = DamageComponent(rawValue: entry.key) else { return nil }
            return (component, entry.value)
        }
        let thermalByComponent = Dictionary(uniqueKeysWithValues: thermalPairs)
        thermalState = ThermalState(temperatureByComponent: thermalByComponent)
        missionTimeline = missionPersistenceAdapter.restoreTimeline(snapshot.missionTimeline)
        missionDebrief = missionPersistenceAdapter.restoreDebrief(snapshot.missionDebrief)
        missionEventRecorder.restore(timeline: missionTimeline)
        missionObservation.reset()

        homePosition = state.position
        wingmen.removeAll()
        clearMissionPlan()
        targetMarkerState = nil
        autoNavigationController.clearTarget()
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        keyboardInputService.setInputProcessingMode(.flight)
        keyboardInputService.resetTransientState()
        inputManager.reset()
        resetFlightControlRouting()
        regenerateEnvironment()
        rebuildVehicleComponentGraph()
        if let componentRuntime = snapshot.componentDamageRuntime {
            for saved in componentRuntime {
                guard let attachmentState = VehicleAttachmentState(rawValue: saved.attachmentStateRaw) else {
                    continue
                }
                componentGraph.restoreComponentRuntime(
                    id: saved.componentID,
                    integrity: saved.integrity,
                    residualStrength: saved.residualStrength,
                    stiffnessScale: saved.stiffnessScale,
                    deformation: VehicleComponentDeformation(
                        bendRadians: SIMD3<Float>(
                            saved.bendRadians.x,
                            saved.bendRadians.y,
                            saved.bendRadians.z
                        ),
                        translationMeters: SIMD3<Float>(
                            saved.translationMeters.x,
                            saved.translationMeters.y,
                            saved.translationMeters.z
                        ),
                        vibrationScale: saved.vibrationScale
                    ),
                    attachmentState: attachmentState,
                    performance: VehicleComponentPerformance(
                        forceScale: saved.forceScale,
                        torqueScale: saved.torqueScale,
                        efficiencyScale: saved.efficiencyScale,
                        responseSpeedScale: saved.responseSpeedScale,
                        rangeScale: saved.rangeScale,
                        dragScale: saved.dragScale,
                        vibrationScale: saved.performanceVibrationScale
                    )
                )
            }
            for saved in snapshot.connectionDamageRuntime ?? [] {
                guard let attachmentState = VehicleAttachmentState(rawValue: saved.attachmentStateRaw) else {
                    continue
                }
                componentGraph.restoreConnectionRuntime(
                    childComponentID: saved.childComponentID,
                    residualStrength: saved.residualStrength,
                    stiffnessScale: saved.stiffnessScale,
                    state: attachmentState
                )
            }
            if let revision = snapshot.massPropertiesRevision {
                componentGraph.restoreMassPropertiesRevision(revision)
            }
            if let runtime = snapshot.failureRuntime {
                let restoredFailures = runtime.failures.compactMap { saved -> ActiveComponentFailure? in
                    guard let mode = ComponentFailureMode(rawValue: saved.modeRaw) else { return nil }
                    return ActiveComponentFailure(
                        componentID: saved.componentID,
                        mode: mode,
                        frozenSurfaceValue: saved.frozenSurfaceValue,
                        intermittentActive: saved.intermittentActive,
                        intermittentTimer: saved.intermittentTimer
                    )
                }
                componentFailureRuntime.restore(
                    failures: restoredFailures,
                    seed: runtime.seed,
                    generatorState: runtime.generatorState
                )
            }
            damageState = componentGraph.projectedLegacyDamageState(base: damageState)
            refreshDamagePhysicsModels()
            sceneController.restoreDetachedVehicleComponentVisibility(componentGraph)
        } else {
            synchronizeLegacyDamageIntoGraph(reason: "project_restore", recordEvents: false)
        }

        sceneController.applyWeatherVisual(weather)
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        refreshCompassOverlay()
        refreshPayloadCameraStatus()
        emitLaunchDiagnostics(context: "load_project")
    }

    private func refreshPayloadRuntimeState() {
        payloadMountState = resolvePayloadMountState()
        payloadCapabilityCheck = PayloadController.capabilityCheck(
            for: payloadDraftConfiguration,
            profile: activeUAVProfile
        )
        vehicleMassModel = PayloadController.massModel(
            for: selectedDroneProfile,
            uavProfile: activeUAVProfile,
            installedPayload: installedPayloadConfiguration,
            payloadState: payloadState,
            installedFiberSpool: installedFiberSpoolModule
        )
        // Mass distribution changed (payload mounted/released) — rebuild the
        // physical graph but keep the damage already sustained.
        rebuildVehicleComponentGraph(preservingIntegrity: true)
    }

    /// Rebuilds the component graph and contact profile from the currently
    /// built visual + the current mass model. `preservingIntegrity` carries
    /// accumulated damage across payload/mass refreshes; a model switch or
    /// reset starts pristine.
    private func rebuildVehicleComponentGraph(preservingIntegrity: Bool = false) {
        let output = VehicleComponentGraphBuilder.build(
            profile: selectedDroneProfile,
            vehicleMassModel: vehicleMassModel,
            geometry: sceneController.currentVisualGeometry
        )
        var graph = output.graph
        if preservingIntegrity, !componentGraph.isEmpty {
            graph.applyRuntimeState(from: componentGraph)
        } else {
            componentFailureRuntime.reset(seed: terrain.seed)
            damageEventRecorder.reset()
            recentDamageEvents.removeAll(keepingCapacity: false)
            recordedPhysicalImpactCount = 0
            groundImpactCooldown = 0.0
            replayStopPendingAfterDisarm = missionReplayRecorder.isRecording
            sceneController.clearDetachedVehicleParts()
            sceneController.clearBatteryFireVisual()
            batteryFireActive = false
            batteryFireIgnitedAtSimulationTime = nil
            sustainedMaxThrottleSeconds = 0.0
        }
        componentGraph = graph
        pristineVehicleContactProfile = output.contactProfile
        let detachedIDs = Set(graph.components.filter { !$0.isAttached }.map(\.id))
        vehicleContactProfile = pristineVehicleContactProfile
            .applyingDeformations(from: graph)
            .removing(componentIDs: detachedIDs)
        vehicleMassProperties = graph.massProperties
        pristineRotorModel = output.rotorModel
        refreshDamagePhysicsModels()
    }

    /// Bakes graph integrity + active failure modes into the physics-facing
    /// damage models: per-rotor thrust/vibration factors and the fixed-wing
    /// aero deltas. Called after every damage event, after graph rebuilds,
    /// and every tick while intermittent failures are toggling.
    private func refreshDamagePhysicsModels() {
        vehicleMassProperties = componentGraph.massProperties
        let detachedIDs = Set(componentGraph.components.filter { !$0.isAttached }.map(\.id))
        vehicleContactProfile = pristineVehicleContactProfile
            .applyingDeformations(from: componentGraph)
            .removing(componentIDs: detachedIDs)
        var model = pristineRotorModel
        let escFactor = VehicleRotorModel.motorThrustFactor(
            integrity: componentGraph.integrity(id: "esc")
        ) * componentFailureRuntime.functionalFactor(componentID: "esc")
        for index in model.rotors.indices {
            let slot = model.rotors[index].slot
            let propIntegrity = componentGraph.integrity(id: "propeller.\(slot)")
            let motorIntegrity = componentGraph.integrity(id: "motor.\(slot)")
            let factor = VehicleRotorModel.propellerThrustFactor(integrity: propIntegrity) *
                VehicleRotorModel.motorThrustFactor(integrity: motorIntegrity) *
                escFactor *
                componentFailureRuntime.motorFailureFactor(slot: slot)
            model.rotors[index].thrustFactor = min(1.0, max(0.0, factor))
            model.rotors[index].vibration01 = VehicleRotorModel.propellerVibration(integrity: propIntegrity)

            if let propeller = componentGraph.component(id: "propeller.\(slot)") {
                model.rotors[index].offsetBody = propeller.localPosition +
                    propeller.deformation.translationMeters - vehicleMassProperties.centerOfMassOffset
            }
            let mount = componentGraph.component(id: "arm.\(slot)") ??
                componentGraph.component(id: "motor.\(slot)")
            if let bend = mount?.deformation.bendRadians,
               simd_length_squared(bend) > 0.000001 {
                let angle = min(Float(25.0) * .pi / 180.0, simd_length(bend))
                let axis = simd_normalize(bend)
                model.rotors[index].thrustDirectionBody = simd_act(
                    simd_quatf(angle: angle, axis: axis),
                    SIMD3<Float>(0.0, 1.0, 0.0)
                )
            }
        }
        vehicleRotorModel = model
        vehicleAeroDamage = FixedWingAeroDamage.build(from: componentGraph)
        sceneController.applyVehicleComponentDeformations(componentGraph)
    }

    private func synchronizeLegacyDamageIntoGraph(reason: String, recordEvents: Bool = true) {
        let before = Dictionary(uniqueKeysWithValues: componentGraph.components.map { ($0.id, $0.integrity) })
        componentGraph.applyLegacyDamageState(damageState)
        if recordEvents {
            for component in componentGraph.components.sorted(by: { $0.id < $1.id }) {
                guard let old = before[component.id], component.integrity < old - 0.0005 else { continue }
                damageEventRecorder.record(
                    timestamp: TimeInterval(simulationTime),
                    type: component.integrity <= 0.0001 ? .componentFailed : .componentDamaged,
                    componentID: component.id,
                    integrityBefore: old,
                    integrityAfter: component.integrity,
                    residualStrengthAfter: component.residualStrength,
                    reason: reason
                )
            }
        }
        damageState = componentGraph.projectedLegacyDamageState(base: damageState)
        refreshDamagePhysicsModels()
    }

    private func syncPayloadLifecycleEvents() {
        let events = sceneController.consumePayloadLifecycleEvents()
        guard events.isEmpty == false else {
            return
        }

        var didApplyEvent = false
        for event in events {
            guard event.releaseID == activePayloadReleaseID else {
                continue
            }
            guard payloadState != .attached else {
                continue
            }

            payloadState = event.state
            var resolvedMessageKey = event.messageKey
            if event.state == .landed,
               let impactPosition = event.impactPosition,
               let impactAssessment = assessPayloadImpact(
                    position: impactPosition,
                    impactSpeedMps: event.impactSpeedMps ?? 0.0
               ) {
                lastPayloadImpact = impactAssessment
                evaluatePayloadSelfInteraction(for: impactAssessment)
                resolvedMessageKey = impactAssessment.outcome.messageKey
                payloadStatusMessageKey = resolvedMessageKey
            } else if let messageKey = resolvedMessageKey {
                payloadStatusMessageKey = messageKey
            }
            if let restoreMode = payloadCameraController.handleLifecycleState(
                event.state,
                currentMode: cameraConfiguration.mode
            ) {
                let oldMode = cameraConfiguration.mode
                cameraConfiguration.mode = restoreMode
                syncCameraSystem(from: oldMode)
            }
            if event.state == .cleanedUp {
                activePayloadReleaseID = nil
                releasedPayloadConfiguration = nil
            }
            didApplyEvent = true

            if missionEventRecorder.currentTimeline != nil,
               event.state == .landed || event.state == .cleanedUp {
                recordMissionEvents([
                    missionEventMapper.payloadCompletedEvent(
                        missionID: currentMissionPlan?.id,
                        projectID: currentProjectID,
                        projectName: currentProjectName,
                        payloadState: event.state,
                        statusSnapshot: missionStatusSnapshot,
                        batteryState: batteryState,
                        detailKey: resolvedMessageKey
                    )
                ])
            }
        }

        if didApplyEvent {
            refreshPayloadRuntimeState()
            refreshPayloadCameraStatus()
        }
    }

    private func assessPayloadImpact(
        position: SIMD3<Float>,
        impactSpeedMps: Float
    ) -> TerrainMapPayloadImpact? {
        guard let releasedPayloadConfiguration else {
            return nil
        }

        let marker = payloadImpactMarker(
            configuration: releasedPayloadConfiguration,
            impactPosition: SIMD2<Float>(position.x, position.z),
            impactSpeedMps: impactSpeedMps
        )
        return marker
    }

    private func payloadImpactMarker(
        configuration: PayloadConfiguration,
        impactPosition: SIMD2<Float>,
        impactSpeedMps: Float
    ) -> TerrainMapPayloadImpact {
        let footprintScale = max(0.65, min(1.45, configuration.payloadMass / max(configuration.payloadType.defaultMass, 0.25)))
        let speedScale = max(0.55, min(1.55, impactSpeedMps / 11.0))

        let baseFalloffRadius: Float = 0.95 * footprintScale + 0.32 * speedScale
        let baseCoreRadius: Float = 0.42 * footprintScale + 0.14 * speedScale

        let falloffRadius = baseFalloffRadius.clamped(to: 0.9...4.6)
        let coreRadius = min(falloffRadius * 0.62, baseCoreRadius.clamped(to: 0.28...2.2))

        let dropZone = resolvedPayloadImpactDropZone()
        let outcome: PayloadImpactOutcome = {
            guard let dropZone else {
                return .generic
            }

            let distanceToCenter = simd_distance(impactPosition, dropZone.center)
            let nearTargetRadius = dropZone.radius + max(0.6, falloffRadius * 0.65)
            let onTargetRadius = max(1.0, min(dropZone.radius, max(dropZone.radius * 0.42, falloffRadius * 0.72)))
            if distanceToCenter <= onTargetRadius {
                return .onTarget
            }
            if distanceToCenter <= nearTargetRadius {
                return .nearTarget
            }
            return .offTarget
        }()

        return TerrainMapPayloadImpact(
            position: impactPosition,
            coreRadius: coreRadius,
            falloffRadius: falloffRadius,
            outcome: outcome,
            measuredImpactSpeedMps: max(0.0, impactSpeedMps)
        )
    }

    private func resolvedPayloadImpactDropZone() -> DropZoneState? {
        if let dropZone = missionPlanState.dropZone {
            return dropZone
        }

        if let zone = currentMissionPlan?.zones.first(where: { $0.type == .dropZone }) {
            return DropZoneState(center: zone.center, radius: zone.radius)
        }

        if let dropZone = tacticalMapState.workingDraft.dropZone {
            return DropZoneState(center: dropZone.center, radius: dropZone.radius)
        }

        return missionPlanningDraft.dropZone
    }

    private func evaluatePayloadSelfInteraction(for impact: TerrainMapPayloadImpact) {
        guard let releasedPayloadConfiguration,
              let effect = payloadProximityEffectModel.evaluate(
                impact: impact,
                payload: releasedPayloadConfiguration,
                dronePosition: state.position,
                droneVelocity: state.velocity,
                profile: selectedDroneProfile
              ) else {
            return
        }

        let dronePlanar = currentPlanarPosition()
        payloadSelfInteractionSeverity = max(payloadSelfInteractionSeverity, effect.stabilityDisturbance)
        payloadSelfInteractionTimer = max(payloadSelfInteractionTimer, 1.6 + effect.normalizedIntensity * 2.8)
        payloadControlPenalty = max(payloadControlPenalty, effect.controlPenalty)
        damageState = damageState.applyingCollisionDamage(impactEnergy: effect.damageEnergy)
        synchronizeLegacyDamageIntoGraph(reason: "payload_self_interaction")
        payloadStatusMessageKey = "payload.message.self_interference_risk"
        collisionAftermathState = effect.severity == .minor ? .impactRecovery : .damaged

        state.angularVelocity.z += effect.stabilityDisturbance * 0.55 * (dronePlanar.x >= impact.position.x ? 1.0 : -1.0)
        state.angularVelocity.x += effect.stabilityDisturbance * 0.28
        state.velocity.y += effect.stabilityDisturbance * 0.42
        if selectedDroneProfile.airframeClass == .multirotor {
            state.velocity.x += (dronePlanar.x - impact.position.x) * 0.22 * effect.stabilityDisturbance
            state.velocity.z += (dronePlanar.y - impact.position.y) * 0.22 * effect.stabilityDisturbance
        }

        if effect.severity == .severe && mode.isAutoControlled {
            cancelTargetMarkerAutoNavigation()
            setFlightMode(.manual, reason: "payload_proximity_severe_guidance_cancelled")
        }

        if effect.missionFailureRequired,
           missionExecutionState.status == .running {
            missionExecutionState = missionExecutionCoordinator.abort(
                state: missionExecutionState,
                reason: .missionAbortedBySafety,
                abortReason: .runtimeUnsafe,
                detailKey: "mission.status.reason.runtime_unsafe"
            )
            enterMissionExecutionHold()
            missionRuntimeMonitor.reset()
            refreshMissionStatus()
        }

        if effect.forcedCrashRequired {
            applySevereCollisionConsequences(source: "payload_proximity_event")
        }
    }

    private func payloadDraftMatchesInstalledPayload() -> Bool {
        guard payloadState == .attached,
              let installedPayloadConfiguration else {
            return false
        }

        return installedPayloadConfiguration.payloadType == payloadDraftConfiguration.payloadType &&
            installedPayloadConfiguration.customName == payloadDraftConfiguration.customName &&
            abs(installedPayloadConfiguration.payloadMass - payloadDraftConfiguration.payloadMass) <= 0.0001 &&
            installedPayloadConfiguration.visualPreset == payloadDraftConfiguration.visualPreset &&
            installedPayloadConfiguration.fireHoseDiameterClass == payloadDraftConfiguration.fireHoseDiameterClass &&
            abs(installedPayloadConfiguration.fireHoseLengthMeters - payloadDraftConfiguration.fireHoseLengthMeters) <= 0.001 &&
            installedPayloadConfiguration.fireCapsuleSize == payloadDraftConfiguration.fireCapsuleSize &&
            installedPayloadConfiguration.fireCapsuleCount == payloadDraftConfiguration.fireCapsuleCount &&
            abs(installedPayloadConfiguration.agriculturalSprayerTankLiters - payloadDraftConfiguration.agriculturalSprayerTankLiters) <= 0.001
    }

    private func resolvePayloadMountState() -> PayloadMountState {
        guard activeUAVProfile != nil else {
            return .unavailable
        }

        return payloadState == .attached ? .occupied : .ready
    }

    private func resetPayloadForProfileSwitch() {
        activePayloadReleaseID = nil
        releasedPayloadConfiguration = nil
        installedPayloadConfiguration = nil
        mountedCADPayload = nil
        simulationLaunchConfiguration = nil
        payloadDraftConfiguration = PayloadController.defaultConfiguration()
        payloadDraftConfiguration.isAttached = false
        payloadState = .noPayload
        payloadStatusMessageKey = nil
        lastPayloadImpact = nil
        payloadSelfInteractionTimer = 0.0
        payloadSelfInteractionSeverity = 0.0
        payloadControlPenalty = 0.0
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        if cameraConfiguration.mode == .payload {
            cameraConfiguration.mode = .follow
        }
        sceneController.clearDroppedPayloadVisuals()
        sceneController.removePayloadVisual()
        refreshPayloadCameraStatus()
        refreshPayloadRuntimeState()
    }

    private static func resolveActiveUAVProfile(
        for profile: DroneModelProfile,
        abstractParameters: AbstractDroneParameters
    ) -> UAVProfile? {
        if profile.isAbstract {
            return UAVReferenceCatalog.abstractProfile(from: abstractParameters)
        }

        return profile.resolvedUAVProfile
    }

    private func buildTelemetrySnapshot() -> TelemetrySnapshot {
        let fleetSnapshot = currentFleetStatusSnapshot()
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        let safeVelocity = finiteVector(state.velocity, fallback: lastFiniteState.velocity)
        let safeOrientation = finiteVector(state.orientation, fallback: lastFiniteState.orientation)
        let speed = simd_length(safeVelocity)
        let iso = Self.isoFormatter.string(from: Date())
        let flight = flightState(speed: speed)
        let autoNavigationStatus = currentAutoNavigationStatus()
        let fixedWingDebug = fixedWingAutopilotDebugState
        let fixedWingRouteCapable = selectedDroneProfile.airframeClass == .fixedWing ||
            selectedDroneProfile.airframeClass == .hybridVTOL
        let fixedWingRouteActive = fixedWingRouteCapable
            && activeFixedWingGuidanceSource != .none
            && fixedWingDebug.missionState != .idle
            && fixedWingDebug.missionState != .failed
        // During a hybrid transition the multicopter/transition controller is
        // still following the bound route, while fixed-wing debug is
        // intentionally `.idle`. Treat that as active auto-navigation instead
        // of flashing AUTO OFF at every legitimate controller handoff.
        let hybridRouteGuidanceActive = selectedDroneProfile.airframeClass == .hybridVTOL &&
            mode == .autoPath &&
            activeRouteTargetSource != .none &&
            targetMarkerState != nil
        let targetDistanceMeters: Double = {
            if autoNavigationStatus.distanceToTarget.isFinite {
                return Double(autoNavigationStatus.distanceToTarget)
            }
            if fixedWingRouteActive {
                return Double(max(0.0, fixedWingDebug.remainingDistance))
            }
            return .nan
        }()
        let targetBearingDegrees: Double = {
            if autoNavigationStatus.bearingDegrees.isFinite {
                return Double(autoNavigationStatus.bearingDegrees)
            }
            if fixedWingRouteActive {
                return Double(fixedWingDebug.desiredCourseDeg)
            }
            return .nan
        }()
        let fixedWingLegCourseDegrees: Double = {
            let direction = fixedWingDebug.legDirection
            let magnitudeSquared = Double(direction.x * direction.x + direction.y * direction.y)
            guard magnitudeSquared > 1e-6 else { return .nan }
            return Double(fixedWingCourseRadians(from: direction).radiansToDegrees)
        }()
        let collisionRisk = collisionAnalysis.riskScore.isFinite ? collisionAnalysis.riskScore : 0.0
        let nearestObstacleDistance = collisionAnalysis.nearestObstacleDistance.isFinite
            ? collisionAnalysis.nearestObstacleDistance
            : Float(terrain.worldHalfExtent * 2.0)
        let nearestInterDroneDistance = fleetSnapshot.nearestInterDroneDistance.isFinite
            ? fleetSnapshot.nearestInterDroneDistance
            : Float(terrain.worldHalfExtent * 2.0)

        let vtolPhaseKey: String
        let vtolTiltAngleDeg: Double
        let vtolTransitionProgressPercent: Double
        let vtolWingLiftRatioPercent: Double
        let vtolTransitionBlockedFlag: Bool
        if selectedDroneProfile.airframeClass == .hybridVTOL {
            switch state.vtolPhase {
            case .verticalTakeoff:
                vtolPhaseKey = "vtol.phase.vertical_takeoff"
            case .hover:
                vtolPhaseKey = "vtol.phase.hover"
            case .transitionToForward:
                vtolPhaseKey = "vtol.phase.transition_to_forward"
            case .cruise:
                vtolPhaseKey = "vtol.phase.cruise"
            case .transitionToHover:
                vtolPhaseKey = "vtol.phase.transition_to_hover"
            case .verticalLanding:
                vtolPhaseKey = "vtol.phase.vertical_landing"
            }
            // Tailsitters have no tiltRotor unit (thrust direction is fixed
            // relative to the body) — for them, "tilt" is the body's own
            // pitch, which is the real diagnostic signal when the hover
            // pitch-lock is suspected of not holding, so show the actual
            // measured attitude rather than the lever-derived progress
            // estimate.
            let tiltRad = state.propulsionUnits.first(where: { $0.role == .tiltRotor })?.tiltAngleRad
                ?? ((.pi / 2) - state.orientation.y)
            vtolTiltAngleDeg = Double(tiltRad.radiansToDegrees)
            vtolTransitionProgressPercent = Double(state.vtolTransitionProgress) * 100.0
            vtolWingLiftRatioPercent = Double(state.vtolWingLiftRatio) * 100.0
            vtolTransitionBlockedFlag = state.vtolTransitionBlocked
        } else {
            vtolPhaseKey = "vtol.phase.hover"
            vtolTiltAngleDeg = 0.0
            vtolTransitionProgressPercent = 0.0
            vtolWingLiftRatioPercent = 0.0
            vtolTransitionBlockedFlag = false
        }

        let latestDamageEvent = recentDamageEvents.last
        return TelemetrySnapshot(
            timestampISO8601: iso,
            droneModelID: selectedDroneProfile.id,
            droneModelName: selectedDroneProfile.displayName,
            droneManufacturer: selectedDroneProfile.manufacturer,
            isAbstractModel: selectedDroneProfile.isAbstract,
            abstractParametersSummary: selectedDroneProfile.isAbstract ? abstractParametersSummary : "n/a",
            terrainPreset: terrain.preset.title,
            terrainDensity: Double(terrain.density),
            cameraMode: cameraConfiguration.mode.title,
            x: Double(safePosition.x),
            y: Double(safePosition.y),
            z: Double(safePosition.z),
            velocityX: Double(safeVelocity.x),
            velocityY: Double(safeVelocity.y),
            velocityZ: Double(safeVelocity.z),
            roll: Double(safeOrientation.x.radiansToDegrees),
            pitch: Double(safeOrientation.y.radiansToDegrees),
            yaw: Double(safeOrientation.z.radiansToDegrees),
            speed: Double(speed),
            throttle: Double(state.throttle.isFinite ? state.throttle : 0.0),
            modeTitle: NSLocalizedString(displayFlightModeTitleKey, comment: ""),
            modeKey: displayFlightModeTitleKey,
            controlModeKey: flightControlMode.titleKey,
            armStateKey: isArmed ? "arm_state.armed" : "arm_state.disarmed",
            flightState: flight.title,
            flightStateKey: flight.key,
            batteryPercent: Double(batteryState.chargePercent),
            batteryHealthPercent: Double(batteryState.healthPercent),
            powerDrawW: Double(batteryState.powerDrawW.isFinite ? batteryState.powerDrawW : 0.0),
            estimatedRemainingMin: Double(batteryState.remainingTimeSec / 60.0),
            batteryVoltage: Double(batteryState.packVoltage.isFinite ? batteryState.packVoltage : 0.0),
            batteryCellVoltage: Double(batteryState.cellVoltage.isFinite ? batteryState.cellVoltage : 0.0),
            batteryCurrentDrawA: Double(batteryState.currentDrawA.isFinite ? batteryState.currentDrawA : 0.0),
            weatherPreset: weather.preset.title,
            weatherPresetKey: weather.preset.titleKey,
            weatherIntensity: Double(weather.normalizedIntensity),
            collisionRisk: Double(collisionRisk),
            nearestObstacleDistance: Double(nearestObstacleDistance),
            nearestObstacleSource: collisionAnalysis.nearestObstacleSource ?? "n/a",
            autoNavigationActive: autoNavigationStatus.isActive ||
                fixedWingRouteActive ||
                hybridRouteGuidanceActive,
            targetDistanceMeters: targetDistanceMeters,
            targetBearingDegrees: targetBearingDegrees,
            pathStatus: navigationSnapshot.status.rawValue,
            currentWaypointIndex: navigationSnapshot.currentWaypointIndex,
            remainingWaypoints: navigationSnapshot.remainingWaypoints,
            pathLengthMeters: Double(navigationSnapshot.pathLengthMeters),
            pathRemainingDistanceMeters: Double(navigationSnapshot.remainingDistanceMeters),
            fixedWingMissionState: fixedWingDebug.missionState.rawValue,
            fixedWingActiveWaypointIndex: fixedWingDebug.currentWaypointIndex,
            fixedWingCrossTrackErrorMeters: Double(fixedWingDebug.crossTrackError),
            fixedWingLegCourseDegrees: fixedWingLegCourseDegrees,
            fixedWingLegStartX: Double(fixedWingDebug.legStart.x),
            fixedWingLegStartZ: Double(fixedWingDebug.legStart.z),
            fixedWingLegEndX: Double(fixedWingDebug.legEnd.x),
            fixedWingLegEndZ: Double(fixedWingDebug.legEnd.z),
            fixedWingWaypointVectorX: Double(fixedWingDebug.waypointVector.x),
            fixedWingWaypointVectorZ: Double(fixedWingDebug.waypointVector.y),
            fixedWingHeadingDegrees: Double(fixedWingDebug.headingDeg),
            fixedWingGroundTrackDegrees: Double(fixedWingDebug.groundTrackDeg),
            fixedWingTargetAirspeed: Double(fixedWingDebug.targetAirspeed),
            fixedWingTargetAltitude: Double(fixedWingDebug.targetAltitude),
            fixedWingCommandedRollDegrees: Double(fixedWingDebug.commandedRollDeg),
            fixedWingCommandedPitchDegrees: Double(fixedWingDebug.commandedPitchDeg),
            fixedWingCommandedThrottle: Double(fixedWingDebug.commandedThrottle),
            fixedWingSpeedRecoveryActive: fixedWingDebug.speedRecoveryActive,
            fixedWingAlongTrackProgress: Double(fixedWingDebug.alongTrackProgress),
            fixedWingBatteryWarningLevel: fixedWingBatteryWarningLevel.rawValue,
            fixedWingProfileLimitsActive: fixedWingRouteCapable &&
                selectedDroneProfile.fixedWingParameters != nil,
            fixedWingTransitionReason: fixedWingLastTransitionReason ?? "n/a",
            vtolDiagnosticsVisible: selectedDroneProfile.airframeClass == .hybridVTOL,
            vtolPhaseKey: vtolPhaseKey,
            vtolTiltAngleDeg: vtolTiltAngleDeg,
            vtolTransitionProgressPercent: vtolTransitionProgressPercent,
            vtolWingLiftRatioPercent: vtolWingLiftRatioPercent,
            vtolTransitionBlocked: vtolTransitionBlockedFlag,
            missionAbortReason: missionExecutionState.abortReason?.rawValue ??
                missionSafetyState.abortReason?.rawValue ??
                "n/a",
            modeTransitionReason: lastModeTransitionReason,
            controlAuthority: flightControlDiagnostics.authority.title,
            manualInputActive: flightControlDiagnostics.manualInputActive,
            markerGuidanceActive: flightControlDiagnostics.markerGuidanceActive,
            payloadViewActive: flightControlDiagnostics.payloadViewActive,
            mapOverlayActive: flightControlDiagnostics.mapOverlayActive,
            missionMapActive: isMissionMapVisible,
            dropZoneSet: missionPlanState.dropZone != nil,
            deliveryMissionReady: missionPlanState.isDeliveryMissionReady && payloadState == .attached,
            inDropZone: isInMissionDropZone,
            payloadReleasedForMission: payloadState == .released || payloadState == .falling || payloadState == .landed || payloadState == .cleanedUp,
            disarmedState: flightControlDiagnostics.disarmed,
            blockedState: flightControlDiagnostics.blocked,
            lostSignalState: flightControlDiagnostics.lostSignal,
            emergencyAction: collisionAnalysis.emergencyAction.title,
            emergencyActionKey: collisionAnalysis.emergencyAction.titleKey,
            damageSummary: damageState.summary,
            thermalSummary: thermalState.summary,
            damageEventSequence: latestDamageEvent?.sequenceNumber ?? 0,
            damageEventType: latestDamageEvent?.type.rawValue ?? "n/a",
            damageEventComponentID: latestDamageEvent?.componentID ?? "n/a",
            damageEventColliderID: latestDamageEvent?.colliderID ?? "n/a",
            damageEventEnergyJ: latestDamageEvent?.energyJ.map(Double.init) ?? .nan,
            damageEventIntegrity: latestDamageEvent?.integrityAfter.map(Double.init) ?? .nan,
            damageMassPropertiesRevision: latestDamageEvent?.massPropertiesRevision ??
                componentGraph.massPropertiesRevision,
            fleetMode: fleetSnapshot.mode.title,
            fleetModeKey: fleetSnapshot.mode.titleKey,
            wingmanCount: fleetSnapshot.enabled ? wingmen.count : 0,
            interDroneRisk: Double(fleetSnapshot.interDroneRisk),
            nearestInterDroneDistance: Double(nearestInterDroneDistance),
            frameTimeMs: cachedDiagnostics.frameTimeMs,
            physicsTimeMs: cachedDiagnostics.physicsTimeMs,
            renderTimeMs: cachedDiagnostics.renderTimeMs,
            pathfindingTimeMs: cachedDiagnostics.pathfindingTimeMs,
            activeObjectCount: cachedDiagnostics.activeObjectCount,
            activePhysicsBodyCount: cachedDiagnostics.activePhysicsBodyCount,
            activeParticleCount: cachedDiagnostics.activeParticleCount
        )
    }

    private func currentMissionDistanceEstimate() -> Float {
        let homePlanar = SIMD2<Float>(homePosition.x, homePosition.z)
        let currentPlanar = currentPlanarPosition()

        if (missionExecutionState.status == .running || missionExecutionState.status == .paused),
           navigationSnapshot.remainingDistanceMeters > 0.05 {
            return navigationSnapshot.remainingDistanceMeters + simd_distance(currentPlanar, homePlanar)
        }

        if let currentMissionPlan,
           currentMissionPlan.routePoints.count > 1 {
            let routeLength = polylineLength(currentMissionPlan.routePoints)
            let returnDistance = simd_distance(currentMissionPlan.routePoints.last ?? homePlanar, homePlanar)
            return routeLength + returnDistance
        }

        return simd_distance(currentPlanar, homePlanar)
    }

    private func currentMissionOperationalStatus(
        missionDistanceEstimate: Float? = nil
    ) -> MissionOperationalStatus {
        let operationalProfile = selectedDroneProfile.operationalProfile
        let effectiveBatteryFraction = (batteryState.chargePercent / 100.0).clamped(to: 0.08...1.0)
        let batteryHealthFactor = max(0.60, (batteryState.healthPercent / 100.0).clamped(to: 0.0...1.0))
        let groundedStaticState = !isArmed || physicalState.isGroundRestState || state.position.y <= 0.10
        let payloadRangeFactor = max(
            0.42,
            1.0 - vehicleMassModel.payloadMass * operationalProfile.payloadRangePenaltyPerKg
        )
        let weatherPenalty = max(
            1.0,
            (weather.effectiveFactors.batteryDrainMultiplier * 0.64) +
                (weather.effectiveFactors.dragMultiplier * 0.36)
        )
        let healthPenalty = max(0.58, damageState.averageHealth.clamped(to: 0.0...1.0)) * batteryHealthFactor
        let consumptionMultiplier = currentConsumptionMultiplier(operationalProfile: operationalProfile)

        let nominalRemainingTimeSec = operationalProfile.nominalFlightTimeSec *
            effectiveBatteryFraction *
            healthPenalty
        let liveRemainingTimeSec: Float? = (!groundedStaticState && batteryState.remainingTimeSec > 1.0)
            ? batteryState.remainingTimeSec
            : nil
        let estimatedRemainingTimeSec = max(
            0.0,
            selectedDroneProfile.airframeClass == .hybridVTOL
                ? max(liveRemainingTimeSec ?? 0.0, nominalRemainingTimeSec)
                : (liveRemainingTimeSec ?? nominalRemainingTimeSec)
        )
        let nominalRangeWeatherDivisor = selectedDroneProfile.airframeClass == .hybridVTOL
            ? max(1.0, weatherPenalty)
            : 1.0
        let nominalRangeEstimate = max(
            0.0,
            operationalProfile.nominalMaxRangeM *
                effectiveBatteryFraction *
                payloadRangeFactor *
                max(0.76, healthPenalty) /
                nominalRangeWeatherDivisor
        )
        let liveRangeTimeSec = liveRemainingTimeSec ?? nominalRemainingTimeSec
        let liveRangeEstimate = max(
            0.0,
            liveRangeTimeSec *
                operationalProfile.nominalCruiseSpeedMps *
                payloadRangeFactor *
                healthPenalty /
                max(1.0, weatherPenalty * consumptionMultiplier)
        )
        let estimatedRemainingRangeM: Float = {
            if groundedStaticState {
                return nominalRangeEstimate
            }
            if selectedDroneProfile.airframeClass == .hybridVTOL {
                let liveRange = liveRemainingTimeSec == nil ? 0.0 : liveRangeEstimate
                return max(nominalRangeEstimate, liveRange)
            }
            return liveRangeEstimate
        }()
        let reserveDistance = max(
            operationalProfile.nominalCruiseSpeedMps * 30.0,
            operationalProfile.nominalMaxRangeM * operationalProfile.batteryReserveFraction
        )
        let estimatedSafeReturnRangeM = max(0.0, estimatedRemainingRangeM - reserveDistance)
        let homePlanar = SIMD2<Float>(homePosition.x, homePosition.z)
        let currentPlanar = currentPlanarPosition()
        let distanceToHomeM = simd_distance(currentPlanar, homePlanar)
        let missionBudget = max(missionDistanceEstimate ?? currentMissionDistanceEstimate(), distanceToHomeM)
        let mapRecommendation = selectedDroneProfile.mapScaleRecommendation(
            currentScale: terrain.mapScale,
            payloadMassKg: vehicleMassModel.payloadMass,
            batteryFraction: effectiveBatteryFraction,
            weatherPenalty: weatherPenalty
        )
        let boundaryHalfExtentM = hardWorldBoundsRadius
        let localToHome = currentPlanar - homePlanar
        let distanceToNearestEdgeM = boundaryHalfExtentM - max(abs(localToHome.x), abs(localToHome.y))
        let nearestBoundaryDirection: MapBoundaryDirection = {
            if abs(localToHome.x) >= abs(localToHome.y) {
                return localToHome.x >= 0.0 ? .east : .west
            }
            return localToHome.y >= 0.0 ? .north : .south
        }()
        // Purely a visual-detail concept (distance to the authored/detailed map's edge) — crossing
        // `.outside` is a benign notice, not a comms or mission event. See `updateSignalLossSequence`
        // below, which now drives off the radio link-quality zones instead of this.
        let worldDetailBoundaryState: WorldDetailBoundaryState = {
            let criticalBand = boundaryHalfExtentM * 0.05
            let warningBand = boundaryHalfExtentM * 0.15
            if distanceToNearestEdgeM < 0.0 {
                return .outside
            }
            if distanceToNearestEdgeM <= criticalBand {
                return .critical
            }
            if distanceToNearestEdgeM <= warningBand {
                return .warning
            }
            return .nominal
        }()
        let safeReturnRadiusM = max(
            12.0,
            min(
                estimatedSafeReturnRangeM * 0.48,
                operationalProfile.nominalMaxRangeM * 0.40,
                boundaryHalfExtentM * 0.92
            )
        )

        let operationalRadiusM = max(
            safeReturnRadiusM,
            min(
                estimatedSafeReturnRangeM * 0.62,
                operationalProfile.nominalMaxRangeM * 0.55,
                boundaryHalfExtentM * 0.96
            )
        )
        let linkQualityRadiusM = max(
            18.0,
            min(
                operationalProfile.nominalLinkRangeM * 0.62,
                boundaryHalfExtentM * 0.70
            )
        )
        let degradedLinkRadiusM = max(
            linkQualityRadiusM + 6.0,
            min(
                operationalProfile.nominalLinkRangeM * 0.82,
                boundaryHalfExtentM * 0.84
            )
        )
        let lostLinkRadiusM = max(
            degradedLinkRadiusM + 4.0,
            min(operationalProfile.nominalLinkRangeM, boundaryHalfExtentM * 0.96)
        )
        let currentLinkQuality = linkQuality(
            distanceToHome: distanceToHomeM,
            warningRadius: linkQualityRadiusM,
            criticalRadius: degradedLinkRadiusM,
            lostRadius: lostLinkRadiusM,
            weatherPenalty: weather.effectiveFactors.sensorNoiseMultiplier
        )

        return MissionOperationalStatus(
            estimatedRemainingTimeSec: estimatedRemainingTimeSec,
            estimatedRemainingRangeM: estimatedRemainingRangeM,
            estimatedSafeReturnRangeM: estimatedSafeReturnRangeM,
            safeReturnRadiusM: safeReturnRadiusM,
            distanceToHomeM: distanceToHomeM,
            distanceToNearestEdgeM: distanceToNearestEdgeM,
            nearestBoundaryDirection: nearestBoundaryDirection,
            worldDetailBoundaryState: worldDetailBoundaryState,
            missionDistanceBudgetM: missionBudget,
            canReachHomeSafely: distanceToHomeM <= estimatedSafeReturnRangeM + 0.05,
            canCompleteMissionSafely: missionBudget <= estimatedSafeReturnRangeM + 0.05,
            currentLinkQuality: currentLinkQuality,
            isInWarningLinkZone: distanceToHomeM > linkQualityRadiusM + 0.05,
            isInCriticalLinkZone: distanceToHomeM > degradedLinkRadiusM + 0.05,
            isLinkLost: distanceToHomeM > lostLinkRadiusM + 0.05 || currentLinkQuality <= 0.01,
            mapScaleSuitability: mapRecommendation.currentSuitability,
            recommendedMapScaleMin: mapRecommendation.recommendedMapScaleMin,
            recommendedMapScaleMax: mapRecommendation.recommendedMapScaleMax,
            recommendedOperationalMapScale: mapRecommendation.recommendedOperationalMapScale,
            linkQualityRadiusM: linkQualityRadiusM,
            degradedLinkRadiusM: degradedLinkRadiusM,
            lostLinkRadiusM: lostLinkRadiusM,
            operationalRadiusM: operationalRadiusM
        )
    }

    /// Mission geofence area — derived from the active scenario's own operational area
    /// (search sector for SAR, fire zone for fire response), not from the map's authored/detail
    /// boundary or the radio link range. `nil` when no scenario is running or the running kind
    /// doesn't define an operational area (matches Part E's "sensible default per mission type,
    /// no new authoring UI yet" scope).
    private func currentMissionGeofenceConfiguration() -> MissionGeofenceConfiguration? {
        if let runtime = missionScenarioRuntime, runtime.isActive {
            let placement = runtime.placement
            return MissionGeofenceConfiguration(
                center: placement.sectorCenter,
                // Generous margin over the search sector itself — chasing a lead just outside the
                // sector shouldn't immediately breach; only warningOnly is configured for SAR.
                radiusMeters: placement.sectorRadius * 1.5 + 60.0,
                configuredAction: .warningOnly
            )
        }
        if let runtime = fireResponseRuntime, runtime.isActive {
            let placement = runtime.placement
            return MissionGeofenceConfiguration(
                center: placement.zoneCenter,
                radiusMeters: placement.zoneRadius * 1.6 + 80.0,
                // A firefighting aircraft drifting away from the fire zone (most relevant for the
                // capsule launcher, which has no physical truck tether unlike the hose) should be
                // held rather than left to wander unattended.
                configuredAction: .hold
            )
        }
        return nil
    }

    private func currentMissionGeofenceState(configuration: MissionGeofenceConfiguration?) -> MissionGeofenceState {
        guard let configuration else {
            return .inactive
        }
        let distance = simd_distance(currentPlanarPosition(), configuration.center)
        let warningBand = configuration.radiusMeters * 0.85
        if distance > configuration.radiusMeters {
            return .breach
        }
        if distance > warningBand {
            return .warning
        }
        return .nominal
    }

    private func currentConsumptionMultiplier(
        operationalProfile: UAVOperationalProfile
    ) -> Float {
        var multiplier: Float = 1.0

        if state.velocity.y > 0.65 {
            multiplier *= operationalProfile.climbConsumptionMultiplier
        }

        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        if selectedDroneProfile.airframeClass == .multirotor &&
            isArmed &&
            state.position.y > 0.5 &&
            planarSpeed < max(1.0, operationalProfile.nominalCruiseSpeedMps * 0.24) {
            multiplier *= operationalProfile.hoverConsumptionMultiplier
        }

        if selectedDroneProfile.airframeClass == .fixedWing {
            let yawRate = abs(state.angularVelocity.z)
            if yawRate > 0.18 || mode == .autoPath || mode == .returnHome {
                multiplier *= operationalProfile.turnConsumptionMultiplier
            }
            if navigationSnapshot.remainingDistanceMeters < max(24.0, operationalProfile.nominalCruiseSpeedMps * 2.0) &&
                navigationSnapshot.status != .idle {
                multiplier *= operationalProfile.loiterConsumptionMultiplier
            }
        }

        return multiplier
    }

    private func linkQuality(
        distanceToHome: Float,
        warningRadius: Float,
        criticalRadius: Float,
        lostRadius: Float,
        weatherPenalty: Float
    ) -> Float {
        let rawQuality: Float
        switch distanceToHome {
        case ..<warningRadius:
            rawQuality = 1.0 - (distanceToHome / max(warningRadius, 0.1)) * 0.18
        case ..<criticalRadius:
            let t = (distanceToHome - warningRadius) / max(criticalRadius - warningRadius, 0.1)
            rawQuality = 0.82 - t * 0.38
        case ..<lostRadius:
            let t = (distanceToHome - criticalRadius) / max(lostRadius - criticalRadius, 0.1)
            rawQuality = 0.44 - t * 0.38
        default:
            rawQuality = 0.0
        }

        let sensorPenalty = max(0.64, 1.0 - max(0.0, weatherPenalty - 1.0) * 0.22)
        return (rawQuality * sensorPenalty).clamped(to: 0.0...1.0)
    }

    private func shortestAngleRadians(_ angle: Float) -> Float {
        var normalized = angle
        while normalized > .pi {
            normalized -= (.pi * 2.0)
        }
        while normalized < -.pi {
            normalized += (.pi * 2.0)
        }
        return normalized
    }

    private func fixedWingCourseRadians(from direction: SIMD2<Float>) -> Float {
        atan2(-direction.x, -direction.y)
    }

    private func setFlightMode(
        _ nextMode: DroneFlightMode,
        reason: String
    ) {
        guard mode != nextMode else {
            return
        }
        mode = nextMode
        state.mode = nextMode
        lastModeTransitionReason = reason
    }

    private func setFixedWingGuidanceSource(
        _ source: FixedWingGuidanceSource,
        reason: String
    ) {
        guard activeFixedWingGuidanceSource != source else {
            return
        }
        activeFixedWingGuidanceSource = source
        resetFixedWingRuntimeRouteStart()
        fixedWingLastTransitionReason = reason
    }

    private func registerFixedWingAssistOverride(_ axes: FixedWingAssistOverrideAxes) {
        guard selectedDroneProfile.airframeClass == .fixedWing,
              fixedWingAssistState.mode != .manual else {
            return
        }

        if axes.contains(.turn) {
            fixedWingAssistTurnOverrideTimeRemaining = max(fixedWingAssistTurnOverrideTimeRemaining, 0.7)
        }
        if axes.contains(.altitude) {
            fixedWingAssistAltitudeOverrideTimeRemaining = max(fixedWingAssistAltitudeOverrideTimeRemaining, 0.7)
        }
    }

    private func decayFixedWingAssistOverrideTimers(deltaTime: Float) {
        fixedWingAssistTurnOverrideTimeRemaining = max(0.0, fixedWingAssistTurnOverrideTimeRemaining - deltaTime)
        fixedWingAssistAltitudeOverrideTimeRemaining = max(0.0, fixedWingAssistAltitudeOverrideTimeRemaining - deltaTime)
    }

    private func deactivateFixedWingAssist(reason: String) {
        guard fixedWingAssistState.mode != .manual ||
                fixedWingAssistState.selectedWaypointID != nil ||
                fixedWingAssistState.interceptCompleted else {
            fixedWingAssistTurnOverrideTimeRemaining = 0.0
            fixedWingAssistAltitudeOverrideTimeRemaining = 0.0
            fixedWingAssistUsesTargetYawWhileManual = false
            return
        }

        fixedWingAssistController.reset()
        fixedWingAssistState = FixedWingAssistState(
            mode: .manual,
            selectedWaypointID: fixedWingAssistState.selectedWaypointID,
            activeWaypointIndex: fixedWingAssistState.activeWaypointIndex,
            autoAdvanceEnabled: fixedWingAssistState.autoAdvanceEnabled,
            waypointMode: fixedWingAssistState.waypointMode,
            nextWaypointIndex: resolvedFixedWingAssistNextWaypointIndex(
                activeIndex: fixedWingAssistState.activeWaypointIndex
            ),
            hasPrevWaypoint: fixedWingAssistState.hasPrevWaypoint,
            hasNextWaypoint: fixedWingAssistState.hasNextWaypoint,
            isFinalWaypoint: fixedWingAssistState.isFinalWaypoint,
            isPenultimateWaypoint: fixedWingAssistState.isPenultimateWaypoint,
            flyByCenterWaypointIndex: fixedWingAssistState.flyByCenterWaypointIndex,
            activeTripleIndices: fixedWingAssistState.activeTripleIndices,
            terminalCaptureAllowed: fixedWingAssistState.terminalCaptureAllowed,
            capturedWaypointIDs: fixedWingAssistState.capturedWaypointIDs,
            interceptState: .manual,
            interceptFeasibilityState: fixedWingAssistState.interceptFeasibilityState,
            distanceToActiveWaypointMeters: fixedWingAssistState.distanceToActiveWaypointMeters,
            headingErrorDegrees: fixedWingAssistState.headingErrorDegrees,
            rawHeadingErrorDegrees: fixedWingAssistState.rawHeadingErrorDegrees,
            estimatedTurnRadiusMeters: fixedWingAssistState.estimatedTurnRadiusMeters,
            commandedBankDegrees: fixedWingAssistState.commandedBankDegrees,
            filteredBankCommandDegrees: fixedWingAssistState.filteredBankCommandDegrees,
            commandedTurnDirection: fixedWingAssistState.commandedTurnDirection,
            stateTransitionReason: fixedWingAssistState.stateTransitionReason,
            activeGuidanceTargetType: "none",
            targetHeadingRadians: nil,
            targetAltitudeMeters: nil,
            interceptCompleted: false,
            captureCompletedReason: nil,
            autoAdvanceSuppressed: false,
            autoAdvanceSuppressedReason: nil,
            currentLegStart: fixedWingAssistState.currentLegStart,
            currentLegMiddle: fixedWingAssistState.currentLegMiddle,
            currentLegEnd: fixedWingAssistState.currentLegEnd,
            inboundCourseDegrees: fixedWingAssistState.inboundCourseDegrees,
            outboundCourseDegrees: fixedWingAssistState.outboundCourseDegrees,
            courseChangeDegrees: fixedWingAssistState.courseChangeDegrees,
            leadDistanceMeters: fixedWingAssistState.leadDistanceMeters,
            flyByTransitionActive: false,
            flyByTransitionFeasible: false,
            activeGuidanceMode: "none",
            headingErrorToNextWaypointDegrees: nil,
            nextWaypointInForwardSector: false,
            enoughTurnInDistance: false,
            collisionRiskToNextWaypoint: nil,
            obstacleInTurnCorridor: false,
            blockedPathToNextWaypoint: false,
            lateralGuidanceSuppressedForPoorGeometry: false,
            usingObsoleteFixedWingMode: false,
            previewUsesCachedFlyByPlan: fixedWingAssistState.previewUsesCachedFlyByPlan,
            controllerUsesCachedFlyByPlan: fixedWingAssistState.controllerUsesCachedFlyByPlan,
            guidanceDirectToWaypointSuppressed: fixedWingAssistState.guidanceDirectToWaypointSuppressed,
            flyByPlanRecomputeCount: fixedWingAssistState.flyByPlanRecomputeCount,
            fullRouteRebuildCount: fixedWingAssistState.fullRouteRebuildCount,
            overlayRebuildCount: fixedWingAssistState.overlayRebuildCount,
            guidanceRecomputeCount: fixedWingAssistState.guidanceRecomputeCount,
            heavyMapRebuildCount: fixedWingAssistState.heavyMapRebuildCount,
            frameTimeMs: fixedWingAssistState.frameTimeMs,
            frameTimeDuringTransitionMs: nil
        )
        fixedWingAssistTurnOverrideTimeRemaining = 0.0
        fixedWingAssistAltitudeOverrideTimeRemaining = 0.0
        fixedWingAssistUsesTargetYawWhileManual = false
        fixedWingAssistState.stateTransitionReason = reason
        fixedWingLastTransitionReason = reason
    }

    private var displayFlightModeTitleKey: String {
        if selectedDroneProfile.airframeClass == .fixedWing,
           mode == .manual,
           fixedWingAssistState.mode != .manual {
            return fixedWingAssistState.mode.titleKey
        }
        return mode.titleKey
    }

    var isFixedWingAssistEnabled: Bool {
        selectedDroneProfile.airframeClass == .fixedWing
    }

    var fixedWingAssistWaypointOptions: [FixedWingAssistWaypointOption] {
        if let missionPlan = currentMissionPlan {
            return missionPlan.waypoints.map { target in
                FixedWingAssistWaypointOption(
                    id: target.waypointID,
                    label: target.label,
                    position: target.position
                )
            }
        }

        return tacticalMapState.workingDraft.waypoints.map { waypoint in
            FixedWingAssistWaypointOption(
                id: waypoint.id,
                label: waypoint.label,
                position: waypoint.position
            )
        }
    }

    var selectedFixedWingAssistWaypointID: UUID? {
        resolvedFixedWingAssistWaypoint()?.id
    }

    var selectedFixedWingAssistWaypointLabel: String? {
        resolvedFixedWingAssistWaypoint()?.label
    }

    var canActivateFixedWingWaypointIntercept: Bool {
        isFixedWingAssistEnabled &&
            resolvedFixedWingAssistWaypoint() != nil &&
            isArmed &&
            mode != .emergencyStop
    }

    private func fixedWingAssistWaypointResolution(
        options: [FixedWingAssistWaypointOption]? = nil
    ) -> (option: FixedWingAssistWaypointOption?, index: Int?) {
        let resolvedOptions = options ?? fixedWingAssistWaypointOptions
        guard !resolvedOptions.isEmpty else {
            return (nil, nil)
        }

        if let selectedID = fixedWingAssistState.selectedWaypointID,
           let selectedIndex = resolvedOptions.firstIndex(where: { $0.id == selectedID }) {
            return (resolvedOptions[selectedIndex], selectedIndex)
        }

        if let activeWaypointIndex = fixedWingAssistState.activeWaypointIndex,
           resolvedOptions.indices.contains(activeWaypointIndex) {
            return (resolvedOptions[activeWaypointIndex], activeWaypointIndex)
        }

        return (resolvedOptions[0], 0)
    }

    private func resolvedFixedWingAssistWaypoint() -> FixedWingAssistWaypointOption? {
        fixedWingAssistWaypointResolution().option
    }

    private func activeFixedWingAssistWaypoint() -> FixedWingAssistWaypointOption? {
        guard selectedDroneProfile.airframeClass == .fixedWing,
              fixedWingAssistState.mode == .waypointIntercept,
              !fixedWingAssistState.interceptCompleted else {
            return nil
        }
        return resolvedFixedWingAssistWaypoint()
    }

    private func fixedWingAssistInterceptDebugSource() -> String {
        if let currentMissionPlan, !currentMissionPlan.waypoints.isEmpty {
            return "selected_mission_waypoint"
        }
        if tacticalMapState.previewRoute != nil || !tacticalMapState.workingDraft.waypoints.isEmpty {
            return "selected_draft_waypoint"
        }
        return "selected_direct_waypoint"
    }

    private func fixedWingValidatedMissionSegmentCount() -> Int {
        if let currentMissionPlan {
            return max(0, currentMissionPlan.waypoints.count - 1)
        }
        if let previewRoute = tacticalMapState.previewRoute {
            return max(0, previewRoute.waypointExecutionPointIndices.count - 1)
        }
        return max(0, tacticalMapState.workingDraft.waypoints.count - 1)
    }

    private func fixedWingAssistActiveRouteIncludesHome() -> Bool {
        let spawnPlanar = SIMD2<Float>(currentSpawnPoint().x, currentSpawnPoint().z)
        let activeRoutePoints: [SIMD2<Float>] = {
            if let routePlan = fixedWingFlyByRoutePlan(targetAltitude: max(0.0, state.position.y)) {
                return routePlan.routePoints
            }
            if let currentMissionPlan, !currentMissionPlan.waypoints.isEmpty {
                return currentMissionPlan.missionPoints
            }
            if let previewRoute = tacticalMapState.previewRoute {
                return previewRoute.missionPlanPoints
            }
            return tacticalMapState.workingDraft.waypoints.map(\.position)
        }()

        return activeRoutePoints.contains { simd_distance($0, spawnPlanar) <= 0.05 }
    }

    private func fixedWingAssistSelectedRouteLeg() -> (start: SIMD2<Float>?, end: SIMD2<Float>?) {
        guard let selectedWaypoint = activeFixedWingAssistWaypoint() else {
            return (nil, nil)
        }
        return (currentPlanarPosition(), selectedWaypoint.position)
    }

    private func resolvedFixedWingAssistNextWaypointIndex(
        activeIndex: Int?,
        options: [FixedWingAssistWaypointOption]? = nil
    ) -> Int? {
        guard let activeIndex else {
            return nil
        }

        let resolvedOptions = options ?? fixedWingAssistWaypointOptions
        let nextIndex = activeIndex + 1
        guard resolvedOptions.indices.contains(nextIndex) else {
            return nil
        }
        return nextIndex
    }

    private func fixedWingAssistWaypointClassification(
        activeIndex: Int?,
        options: [FixedWingAssistWaypointOption]? = nil
    ) -> FixedWingWaypointClassification {
        let resolvedOptions = options ?? fixedWingAssistWaypointOptions
        guard let activeIndex,
              resolvedOptions.indices.contains(activeIndex) else {
            return .none
        }

        let hasPrevWaypoint = resolvedOptions.indices.contains(activeIndex - 1)
        let nextWaypointIndex = resolvedFixedWingAssistNextWaypointIndex(
            activeIndex: activeIndex,
            options: resolvedOptions
        )
        let hasNextWaypoint = nextWaypointIndex != nil
        let finalWaypointIndex = resolvedOptions.count - 1
        let isFinalWaypoint = activeIndex == finalWaypointIndex
        let isPenultimateWaypoint = resolvedOptions.count >= 2 && activeIndex == finalWaypointIndex - 1
        let flyByCenterWaypointIndex = hasPrevWaypoint && hasNextWaypoint ? activeIndex : nil

        return FixedWingWaypointClassification(
            activeWaypointIndex: activeIndex,
            nextWaypointIndex: nextWaypointIndex,
            hasPrevWaypoint: hasPrevWaypoint,
            hasNextWaypoint: hasNextWaypoint,
            isFinalWaypoint: isFinalWaypoint,
            isPenultimateWaypoint: isPenultimateWaypoint,
            flyByCenterWaypointIndex: flyByCenterWaypointIndex,
            terminalCaptureAllowed: isFinalWaypoint
        )
    }

    private func applyFixedWingWaypointClassification(
        _ classification: FixedWingWaypointClassification,
        to assistState: inout FixedWingAssistState
    ) {
        assistState.activeWaypointIndex = classification.activeWaypointIndex
        assistState.nextWaypointIndex = classification.nextWaypointIndex
        assistState.hasPrevWaypoint = classification.hasPrevWaypoint
        assistState.hasNextWaypoint = classification.hasNextWaypoint
        assistState.isFinalWaypoint = classification.isFinalWaypoint
        assistState.isPenultimateWaypoint = classification.isPenultimateWaypoint
        assistState.flyByCenterWaypointIndex = classification.flyByCenterWaypointIndex
        assistState.activeTripleIndices = fixedWingActiveTripleDebugIndices(
            activeWaypointIndex: classification.activeWaypointIndex,
            nextWaypointIndex: classification.nextWaypointIndex,
            hasPrevWaypoint: classification.hasPrevWaypoint
        )
        assistState.terminalCaptureAllowed = classification.terminalCaptureAllowed
    }

    private func fixedWingActiveTripleDebugIndices(
        activeWaypointIndex: Int?,
        nextWaypointIndex: Int?,
        hasPrevWaypoint: Bool
    ) -> String? {
        guard let activeWaypointIndex,
              let nextWaypointIndex,
              hasPrevWaypoint else {
            return nil
        }
        return "\(activeWaypointIndex - 1)->\(activeWaypointIndex)->\(nextWaypointIndex)"
    }

    private func fixedWingFlyByRoutePlanKey() -> FixedWingFlyByRoutePlanKey {
        let sourceDraft = isMissionMapVisible
            ? tacticalMapState.workingDraft
            : tacticalMapState.committedDraft
        return FixedWingFlyByRoutePlanKey(
            missionPlanID: currentMissionPlan?.id,
            missionPlanSignature: fixedWingMissionPlanSignature(currentMissionPlan),
            previewRouteID: tacticalMapState.previewRoute?.id,
            workingDraft: sourceDraft,
            obstacleSignature: fixedWingObstacleSignature(),
            airframeClass: selectedDroneProfile.airframeClass
        )
    }

    private func fixedWingMissionPlanSignature(_ plan: MissionPlan?) -> Int {
        guard let plan else {
            return 0
        }

        var hasher = Hasher()
        hasher.combine(plan.routeKind.rawValue)
        hasher.combine(Int((plan.startPoint.x * 10.0).rounded()))
        hasher.combine(Int((plan.startPoint.y * 10.0).rounded()))
        hasher.combine(plan.routePoints.count)
        for point in plan.routePoints {
            hasher.combine(Int((point.x * 10.0).rounded()))
            hasher.combine(Int((point.y * 10.0).rounded()))
        }
        hasher.combine(plan.missionPoints.count)
        for point in plan.missionPoints {
            hasher.combine(Int((point.x * 10.0).rounded()))
            hasher.combine(Int((point.y * 10.0).rounded()))
        }
        hasher.combine(plan.waypoints.count)
        for waypoint in plan.waypoints {
            hasher.combine(waypoint.waypointID)
            hasher.combine(waypoint.index)
            hasher.combine(Int((waypoint.position.x * 10.0).rounded()))
            hasher.combine(Int((waypoint.position.y * 10.0).rounded()))
        }
        hasher.combine(fixedWingNoFlyZoneSignature(plan.zones))
        return hasher.finalize()
    }

    private func fixedWingNoFlyZoneSignature(_ zones: [MissionZone]) -> Int {
        var hasher = Hasher()
        let noFlyZones = zones
            .filter { $0.type == .noFlyZone }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        hasher.combine(noFlyZones.count)
        for zone in noFlyZones {
            hasher.combine(zone.id)
            hasher.combine(zone.type.rawValue)
            hasher.combine(Int((zone.center.x * 10.0).rounded()))
            hasher.combine(Int((zone.center.y * 10.0).rounded()))
            hasher.combine(Int((zone.radius * 10.0).rounded()))
        }
        return hasher.finalize()
    }

    private func fixedWingFlyByRoutePlan(
        targetAltitude: Float
    ) -> FixedWingFlyByRoutePlan? {
        guard selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL else {
            return nil
        }

        let planKey = fixedWingFlyByRoutePlanKey()
        if fixedWingFlyByRoutePlanCacheKey == planKey {
            return fixedWingFlyByRoutePlanCache
        }

        let plan = buildFixedWingFlyByRoutePlan(targetAltitude: targetAltitude)
        fixedWingFlyByRoutePlanCacheKey = planKey
        fixedWingFlyByRoutePlanCache = plan
        fixedWingFullRouteRebuildCount += 1
        fixedWingAssistState.fullRouteRebuildCount = fixedWingFullRouteRebuildCount
        return plan
    }

    private func safeFixedWingRoute(
        from routePoints: [SIMD2<Float>],
        zones: [MissionZone],
        viewport: MapViewportState,
        targetAltitude: Float
    ) -> FixedWingSafeRoute? {
        let cacheKey = makeFixedWingSafeRouteCacheKey(
            routePoints: routePoints,
            zones: zones,
            viewport: viewport,
            targetAltitude: targetAltitude
        )
        if fixedWingSafeRouteCacheKey == cacheKey {
            return fixedWingSafeRouteCacheStoresNil ? nil : fixedWingSafeRouteCacheRoute
        }

        let route = buildSafeFixedWingRoute(
            from: routePoints,
            zones: zones,
            viewport: viewport,
            targetAltitude: targetAltitude
        )
        fixedWingSafeRouteCacheKey = cacheKey
        fixedWingSafeRouteCacheRoute = route
        fixedWingSafeRouteCacheStoresNil = route == nil
        return route
    }

    private func buildSafeFixedWingRoute(
        from routePoints: [SIMD2<Float>],
        zones: [MissionZone],
        viewport: MapViewportState,
        targetAltitude: Float
    ) -> FixedWingSafeRoute? {
        let compactedOriginal = compactedPlanarPath(routePoints)
        guard compactedOriginal.count >= 2 else {
            return nil
        }

        let candidateRoute = compactedOriginal
        let wasRerouted = false
        let noFlyZones = zones.filter { $0.type == .noFlyZone && $0.radius > 0.0 }
        let protectedNoFlyZones = fixedWingProtectedNoFlyZones(noFlyZones)

        let obstacles = navigationObstacles(including: protectedNoFlyZones)
        guard fixedWingPathNeedsObstacleReroute(
            candidateRoute,
            obstacles: obstacles,
            targetAltitude: targetAltitude
        ) else {
            return FixedWingSafeRoute(points: candidateRoute, wasRerouted: wasRerouted)
        }

        if let gridReroute = gridSafeFixedWingRoute(
            from: candidateRoute,
            protectedNoFlyZones: protectedNoFlyZones,
            viewport: viewport,
            targetAltitude: targetAltitude
        ) {
            return FixedWingSafeRoute(points: gridReroute, wasRerouted: true)
        }

        return nil
    }

    private func makeFixedWingSafeRouteCacheKey(
        routePoints: [SIMD2<Float>],
        zones: [MissionZone],
        viewport: MapViewportState,
        targetAltitude: Float
    ) -> FixedWingSafeRouteCacheKey {
        FixedWingSafeRouteCacheKey(
            routeSignature: fixedWingCoarseRouteSignature(routePoints),
            noFlyZoneSignature: fixedWingNoFlyZoneSignature(zones),
            obstacleSignature: fixedWingObstacleSignature(),
            terrainSignature: fixedWingTerrainSignature(),
            viewportSignature: fixedWingViewportSignature(viewport),
            targetAltitudeBucket: Int((targetAltitude * 2.0).rounded()),
            profileID: selectedDroneProfile.id
        )
    }

    /// Coarser than `fixedWingPlanarRouteSignature` (0.5m buckets) on purpose:
    /// several call sites feed this cache the *live* aircraft position as the
    /// route's first point (e.g. `fixedWingAssistProtectedGuidanceSnapshot`,
    /// `fixedWingAssistSafeOverlayRoute`), which moves every tick — at 0.5m
    /// buckets the cache key changes essentially every tick during flight,
    /// so it never hits and `buildSafeFixedWingRoute`'s grid A* search (the
    /// confirmed hot path in a profiled freeze) reruns from scratch every
    /// tick for as long as a reroute is needed. 15m buckets mean "moved a
    /// little since the last reroute" reuses the same safe path instead of
    /// recomputing it — safe because the underlying obstacle/no-fly geometry
    /// the path avoids hasn't moved, only where exactly along it we ask.
    private func fixedWingCoarseRouteSignature(_ routePoints: [SIMD2<Float>]) -> Int {
        var hasher = Hasher()
        let compacted = compactedPlanarPath(routePoints)
        hasher.combine(compacted.count)
        for point in compacted {
            hasher.combine(Int((point.x / 15.0).rounded()))
            hasher.combine(Int((point.y / 15.0).rounded()))
        }
        return hasher.finalize()
    }

    private func fixedWingPlanarRouteSignature(_ routePoints: [SIMD2<Float>]) -> Int {
        var hasher = Hasher()
        let compacted = compactedPlanarPath(routePoints)
        hasher.combine(compacted.count)
        for point in compacted {
            hasher.combine(Int((point.x * 2.0).rounded()))
            hasher.combine(Int((point.y * 2.0).rounded()))
        }
        return hasher.finalize()
    }

    private func fixedWingViewportSignature(_ viewport: MapViewportState) -> Int {
        var hasher = Hasher()
        hasher.combine(viewport.mapScale.rawValue)
        hasher.combine(Int((viewport.worldHalfExtent * 2.0).rounded()))
        hasher.combine(Int((viewport.hardWorldBoundsRadius * 2.0).rounded()))
        hasher.combine(Int((viewport.minimumTurnRadiusM * 2.0).rounded()))
        hasher.combine(Int((viewport.waypointAnticipationDistanceM * 2.0).rounded()))
        return hasher.finalize()
    }

    private func fixedWingProtectedNoFlyZones(_ zones: [MissionZone]) -> [MissionZone] {
        let wing = activeFixedWingParameters()
        let margin = max(
            selectedDroneProfile.collisionRadius + 0.8,
            min(8.0, wing.waypointAcceptanceRadiusMeters * 0.75)
        )
        return zones.map { zone in
            MissionZone(
                id: zone.id,
                type: zone.type,
                center: zone.center,
                radius: zone.radius + margin
            )
        }
    }

    private func planarPathIntersectsNoFly(
        _ points: [SIMD2<Float>],
        zones: [MissionZone]
    ) -> Bool {
        guard points.count >= 2 else {
            return false
        }

        for zone in zones where zone.type == .noFlyZone && zone.radius > 0.0 {
            let protectedRadius = zone.radius + 0.05
            for point in points where simd_distance(point, zone.center) <= protectedRadius {
                return true
            }
            for pair in zip(points, points.dropFirst()) where segmentIntersectsNoFlyZone(
                from: pair.0,
                to: pair.1,
                center: zone.center,
                radius: protectedRadius
            ) {
                return true
            }
        }

        return false
    }

    private func segmentIntersectsNoFlyZone(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float
    ) -> Bool {
        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.0001 else {
            return simd_distance(start, center) <= radius
        }

        let t = simd_dot(center - start, delta) / lengthSquared
        let clampedT = min(1.0, max(0.0, t))
        let closest = start + delta * clampedT
        return simd_distance(closest, center) <= radius
    }

    private func fixedWingPathNeedsObstacleReroute(
        _ points: [SIMD2<Float>],
        obstacles: [CollisionObstacle],
        targetAltitude: Float
    ) -> Bool {
        guard points.count >= 2, !obstacles.isEmpty else {
            return false
        }

        for obstacle in obstacles {
            let protectedRadius = fixedWingProtectedObstacleRadius(obstacle)
            for point in points where simd_distance(point, obstacle.planarCenter) <= protectedRadius {
                return true
            }

            for pair in zip(points, points.dropFirst()) {
                let segmentDistance = planarDistanceToSegment(
                    point: obstacle.planarCenter,
                    segmentStart: pair.0,
                    segmentEnd: pair.1
                )
                if segmentDistance <= protectedRadius {
                    return true
                }
            }
        }

        return false
    }

    private func fixedWingProtectedObstacleRadius(_ obstacle: CollisionObstacle) -> Float {
        let base: Float
        if let cached = fixedWingObstacleBaseRadiusCache[obstacle.source] {
            base = cached
        } else {
            let classified: Float
            switch obstacle.source {
            case let value where value.contains("no_fly"):
                classified = 2.2
            case let value where value.contains("building"):
                classified = 1.4
            case let value where value.contains("tree"):
                classified = 1.1
            case let value where value.contains("pole"):
                classified = 1.2
            case let value where value.contains("barrier"):
                classified = 1.6
            case let value where value.contains("dock"):
                classified = 0.9
            case let value where value.contains("terrain"):
                classified = 0.8
            default:
                classified = 1.0
            }
            fixedWingObstacleBaseRadiusCache[obstacle.source] = classified
            base = classified
        }
        return obstacle.radius + base + selectedDroneProfile.collisionRadius * 0.6
    }

    private func gridSafeFixedWingRoute(
        from points: [SIMD2<Float>],
        protectedNoFlyZones noFlyZones: [MissionZone],
        viewport: MapViewportState,
        targetAltitude: Float
    ) -> [SIMD2<Float>]? {
        guard points.count >= 2 else {
            return nil
        }

        // Reuse the shared planner instance (same one evaluateFixedWingTurnCorridorAssessment
        // uses) rather than `AutoPathPlannerService()` — a fresh instance has no grid cache,
        // so every call below was rebuilding the *entire-map* navigation grid from scratch
        // (cellSize ~3m over a 25,600m map is on the order of tens of millions of cells,
        // allocated and rasterized every time) instead of reusing it across calls the way
        // `ensureGrid`'s own signature-based cache is designed to. Confirmed via a paused
        // backtrace landing in AutoPathPlannerService.astar's cell hashing exactly when this
        // ran. `invalidate()` below only clears path/goal state, not the grid cache, so the
        // grid still gets rebuilt correctly whenever terrain/obstacles actually change.
        let planner = autoPathPlanner
        let obstacles = navigationObstacles(including: noFlyZones)
        let droneRadius = selectedDroneProfile.collisionRadius
        let altitude = max(2.0, targetAltitude)
        var output: [SIMD2<Float>] = [viewport.clampedToWorld(points[0])]
        output.reserveCapacity(points.count + noFlyZones.count * 4)

        for point in points.dropFirst() {
            let startPlanar = output[output.count - 1]
            let goalPlanar = viewport.clampedToWorld(point)
            let start = SIMD3<Float>(startPlanar.x, altitude, startPlanar.y)
            let goal = SIMD3<Float>(goalPlanar.x, altitude, goalPlanar.y)

            planner.invalidate()
            planner.planIfNeeded(
                start: start,
                goal: goal,
                terrain: terrain,
                obstacles: obstacles,
                droneRadius: droneRadius,
                modeTag: "fixed_wing_mission_obstacle_segment",
                forceRecompute: true,
                reason: "mission_obstacle_reroute"
            )

            let snapshot = planner.snapshot(currentPosition: start)
            guard snapshot.status == .valid,
                  snapshot.waypoints.count >= 2 else {
                return nil
            }

            let segmentPoints = snapshot.waypoints.dropFirst().map {
                viewport.clampedToWorld(SIMD2<Float>($0.x, $0.z))
            }
            for segmentPoint in segmentPoints {
                if simd_distance(segmentPoint, output[output.count - 1]) > 0.05 {
                    output.append(segmentPoint)
                }
            }
        }

        let compactedOutput = compactedPlanarPath(output)
        if planarPathIntersectsNoFly(compactedOutput, zones: noFlyZones) ||
            fixedWingPathNeedsObstacleReroute(
                compactedOutput,
                obstacles: obstacles,
                targetAltitude: targetAltitude
            ) {
            return nil
        }
        return compactedOutput
    }

    private func samePlanarRoute(_ lhs: [SIMD2<Float>], _ rhs: [SIMD2<Float>]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for (left, right) in zip(lhs, rhs) {
            if simd_distance(left, right) > 0.05 {
                return false
            }
        }
        return true
    }

    private func buildFixedWingFlyByRoutePlan(
        targetAltitude: Float
    ) -> FixedWingFlyByRoutePlan? {
        if let currentMissionPlan,
           !currentMissionPlan.routePoints.isEmpty {
            guard let safeRoute = safeFixedWingRoute(
                from: currentMissionPlan.routePoints,
                zones: currentMissionPlan.zones,
                viewport: currentTacticalMapViewport(),
                targetAltitude: targetAltitude
            ) else {
                return nil
            }
            let routePoints = safeRoute.points
            guard routePoints.count >= 2 else {
                return nil
            }
            let waypointRoutePointIndices = safeRoute.wasRerouted
                ? fixedWingMappedRoutePointIndices(
                    routePoints: routePoints,
                    targets: currentMissionPlan.waypoints
                )
                : fixedWingMissionWaypointRoutePointIndices(
                    for: currentMissionPlan,
                    routePointCount: routePoints.count
                ) ?? fixedWingMappedRoutePointIndices(
                    routePoints: routePoints,
                    targets: currentMissionPlan.waypoints
                )
            guard let waypointRoutePointIndices else {
                return nil
            }
            let routeWaypoints = fixedWingRouteWaypoints(
                routePoints: routePoints,
                waypointRoutePointIndices: waypointRoutePointIndices,
                targets: currentMissionPlan.waypoints,
                targetAltitude: targetAltitude
            )
            return FixedWingFlyByRoutePlan(
                routePoints: routePoints,
                routeWaypoints: routeWaypoints,
                waypointRoutePointIndices: waypointRoutePointIndices,
                previewUsesCachedFlyByPlan: true,
                controllerUsesCachedFlyByPlan: true,
                guidanceDirectToWaypointSuppressed: routeWaypoints.count > max(2, currentMissionPlan.waypoints.count)
            )
        }

        let sourceDraft = isMissionMapVisible
            ? tacticalMapState.workingDraft
            : tacticalMapState.committedDraft
        if let previewRoute = tacticalMapState.previewRoute {
            guard let safeRoute = safeFixedWingRoute(
                from: previewRoute.points,
                zones: sourceDraft.zones,
                viewport: currentTacticalMapViewport(),
                targetAltitude: targetAltitude
            ) else {
                return nil
            }
            let routePoints = safeRoute.points
            guard routePoints.count >= 2 else {
                return nil
            }
            let previewTargets = sourceDraft.waypoints.map(MissionTarget.init)
            let waypointRoutePointIndices = safeRoute.wasRerouted
                ? fixedWingMappedRoutePointIndices(
                    routePoints: routePoints,
                    targets: previewTargets
                )
                : fixedWingPreviewWaypointRoutePointIndices(
                    for: previewRoute,
                    waypointCount: previewTargets.count,
                    routePointCount: routePoints.count
                ) ?? fixedWingMappedRoutePointIndices(
                    routePoints: routePoints,
                    targets: previewTargets
                )
            guard let waypointRoutePointIndices else {
                return nil
            }
            let routeWaypoints = fixedWingRouteWaypoints(
                routePoints: routePoints,
                waypointRoutePointIndices: waypointRoutePointIndices,
                targets: previewTargets,
                targetAltitude: targetAltitude
            )
            return FixedWingFlyByRoutePlan(
                routePoints: routePoints,
                routeWaypoints: routeWaypoints,
                waypointRoutePointIndices: waypointRoutePointIndices,
                previewUsesCachedFlyByPlan: true,
                controllerUsesCachedFlyByPlan: true,
                guidanceDirectToWaypointSuppressed: routeWaypoints.count > max(2, previewTargets.count)
            )
        }

        let previewTargets = sourceDraft.waypoints.map(MissionTarget.init)
        guard let safeRoute = safeFixedWingRoute(
            from: previewTargets.map(\.position),
            zones: sourceDraft.zones,
            viewport: currentTacticalMapViewport(),
            targetAltitude: targetAltitude
        ) else {
            return nil
        }
        let routePoints = safeRoute.points
        guard routePoints.count >= 2 else {
            return nil
        }
        let waypointRoutePointIndices = safeRoute.wasRerouted
            ? fixedWingMappedRoutePointIndices(
                routePoints: routePoints,
                targets: previewTargets
            ) ?? Array(routePoints.indices.prefix(previewTargets.count))
            : Array(routePoints.indices)
        let routeWaypoints = fixedWingRouteWaypoints(
            routePoints: routePoints,
            waypointRoutePointIndices: waypointRoutePointIndices,
            targets: previewTargets,
            targetAltitude: targetAltitude
        )
        return FixedWingFlyByRoutePlan(
            routePoints: routePoints,
            routeWaypoints: routeWaypoints,
            waypointRoutePointIndices: waypointRoutePointIndices,
            previewUsesCachedFlyByPlan: false,
            controllerUsesCachedFlyByPlan: false,
            guidanceDirectToWaypointSuppressed: false
        )
    }

    private func fixedWingMissionWaypointRoutePointIndices(
        for plan: MissionPlan,
        routePointCount: Int
    ) -> [Int]? {
        guard routePointCount > 1 else {
            return nil
        }

        var cursor = 0
        var pairs: [(targetIndex: Int, routePointIndex: Int)] = []

        for leg in plan.legs {
            let sampledCount = max(1, leg.sampledPoints.count)
            let legEndIndex = min(routePointCount - 1, cursor + sampledCount - 1)
            if let targetWaypointIndex = leg.targetWaypointIndex {
                pairs.append((targetWaypointIndex, legEndIndex))
            }
            cursor = legEndIndex
        }

        guard !pairs.isEmpty else {
            return nil
        }

        let sortedPairs = pairs.sorted { lhs, rhs in
            if lhs.targetIndex == rhs.targetIndex {
                return lhs.routePointIndex < rhs.routePointIndex
            }
            return lhs.targetIndex < rhs.targetIndex
        }
        let expectedWaypointCount = plan.waypoints.count
        guard sortedPairs.count >= expectedWaypointCount else {
            return nil
        }

        let indices = Array(sortedPairs.prefix(expectedWaypointCount).map(\.routePointIndex))
        guard indices.count == expectedWaypointCount,
              indices.allSatisfy({ $0 >= 0 && $0 < routePointCount }) else {
            return nil
        }
        return indices
    }

    private func fixedWingPreviewWaypointRoutePointIndices(
        for previewRoute: MissionPreviewRoute,
        waypointCount: Int,
        routePointCount: Int
    ) -> [Int]? {
        let indices = previewRoute.waypointExecutionPointIndices
        guard indices.count == waypointCount,
              indices.allSatisfy({ $0 >= 0 && $0 < routePointCount }) else {
            return nil
        }
        return indices
    }

    private func fixedWingMappedRoutePointIndices(
        routePoints: [SIMD2<Float>],
        targets: [MissionTarget]
    ) -> [Int]? {
        guard routePoints.count >= 2,
              !targets.isEmpty else {
            return nil
        }

        var mappedIndices: [Int] = []
        var searchStart = 0
        mappedIndices.reserveCapacity(targets.count)

        for target in targets {
            guard searchStart < routePoints.count else {
                return nil
            }

            var bestIndex = searchStart
            var bestDistance = Float.greatestFiniteMagnitude
            for index in searchStart..<routePoints.count {
                let distance = simd_distance(routePoints[index], target.position)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            mappedIndices.append(bestIndex)
            searchStart = min(routePoints.count - 1, bestIndex + 1)
        }

        return mappedIndices.count == targets.count ? mappedIndices : nil
    }

    private func fixedWingRouteWaypoints(
        routePoints: [SIMD2<Float>],
        waypointRoutePointIndices: [Int],
        targets: [MissionTarget],
        targetAltitude: Float
    ) -> [FixedWingRouteWaypoint] {
        var waypoints = routePoints.map { point in
            FixedWingRouteWaypoint(
                position: SIMD3<Float>(point.x, targetAltitude, point.y),
                missionWaypointIndex: nil,
                waypointIdentifier: nil
            )
        }

        for (target, routePointIndex) in zip(targets, waypointRoutePointIndices) {
            guard waypoints.indices.contains(routePointIndex) else {
                continue
            }
            waypoints[routePointIndex] = FixedWingRouteWaypoint(
                position: SIMD3<Float>(routePoints[routePointIndex].x, targetAltitude, routePoints[routePointIndex].y),
                missionWaypointIndex: target.index,
                waypointIdentifier: target.waypointID.uuidString
            )
        }

        return waypoints
    }

    private func fixedWingAssistProjection(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        position: SIMD2<Float>
    ) -> FixedWingAssistLegProjection {
        let legDelta = end - start
        let legLength = max(0.001, simd_length(legDelta))
        let direction = legDelta / legLength
        let local = position - start
        let alongTrack = simd_dot(local, direction)
        let normal = SIMD2<Float>(-direction.y, direction.x)
        let crossTrack = simd_dot(local, normal)

        return FixedWingAssistLegProjection(
            alongTrackDistance: alongTrack,
            alongTrackProgress: (alongTrack / legLength).clamped(to: -1.0...2.0),
            crossTrackError: crossTrack,
            distanceToEnd: simd_distance(position, end),
            legLength: legLength
        )
    }

    private func fixedWingAssistTurnLeadDistance(
        start: SIMD2<Float>,
        middle: SIMD2<Float>,
        end: SIMD2<Float>,
        wing: FixedWingParameters,
        airspeed: Float
    ) -> Float {
        let inbound = middle - start
        let outbound = end - middle
        let inboundLength = max(0.001, simd_length(inbound))
        let outboundLength = max(0.001, simd_length(outbound))
        let inboundCourse = fixedWingCourseRadians(from: inbound / inboundLength)
        let outboundCourse = fixedWingCourseRadians(from: outbound / outboundLength)
        let turnAngle = abs(shortestAngleRadians(outboundCourse - inboundCourse))
        guard turnAngle > 0.06 else {
            return wing.waypointAcceptanceRadiusMeters
        }

        let radius = fixedWingGuidanceTurnRadius(
            wing: wing,
            airspeed: airspeed
        )
        let geometricLead = radius * tan(min(.pi * 0.45, turnAngle * 0.5))
        let waypointLeadLimit = max(
            wing.waypointAcceptanceRadiusMeters * 2.05,
            min(inboundLength, outboundLength) * 0.22
        )
        let boundedLead = min(
            geometricLead,
            inboundLength * 0.36,
            outboundLength * 0.36,
            waypointLeadLimit
        )
        return max(wing.waypointAcceptanceRadiusMeters * 0.85, boundedLead)
    }

    private func fixedWingGuidanceTurnRadius(
        wing: FixedWingParameters,
        airspeed: Float
    ) -> Float {
        let bankDegrees = min(
            wing.maxBankAngleDeg,
            max(8.0, wing.maxBankAngleDeg * 0.92)
        )
        let bankRadians = bankDegrees.degreesToRadians
        let speed = max(airspeed, wing.minSafeAirspeed)
        let bankLimitedRadius = speed * speed / max(0.1, 9.81 * tan(bankRadians))
        return max(
            wing.waypointAcceptanceRadiusMeters * 1.05,
            min(wing.minimumTurnRadius(airspeed: airspeed), bankLimitedRadius)
        )
    }

    private func fixedWingObstacleSignature() -> Int {
        let revision = sceneController.environmentRevision
        if fixedWingObstacleSignatureRevision == revision {
            return fixedWingObstacleSignatureCache
        }

        var hasher = Hasher()
        for obstacle in sceneController.environmentObstacles {
            hasher.combine(obstacle.id)
            hasher.combine(Int((obstacle.center.x * 2.0).rounded()))
            hasher.combine(Int((obstacle.center.y * 2.0).rounded()))
            hasher.combine(Int((obstacle.center.z * 2.0).rounded()))
            hasher.combine(Int((obstacle.radius * 4.0).rounded()))
        }
        let signature = hasher.finalize()
        fixedWingObstacleSignatureRevision = revision
        fixedWingObstacleSignatureCache = signature
        return signature
    }

    private func fixedWingWeatherSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(weather.preset.rawValue)
        hasher.combine(Int((weather.intensity * 100.0).rounded()))
        hasher.combine(Int((weather.windDirectionDeg * 2.0).rounded()))
        hasher.combine(Int((weather.windSpeedMps * 10.0).rounded()))
        hasher.combine(Int((weather.gusts * 100.0).rounded()))
        return hasher.finalize()
    }

    private func fixedWingTerrainSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(terrain.preset.rawValue)
        hasher.combine(terrain.mapScale.rawValue)
        hasher.combine(Int((terrain.density * 100.0).rounded()))
        hasher.combine(terrain.seed)
        hasher.combine(Int((terrain.safeSpawnRadius * 10.0).rounded()))
        return hasher.finalize()
    }

    private func fixedWingFlyByPlanKey(
        wing: FixedWingParameters,
        options: [FixedWingAssistWaypointOption]
    ) -> FixedWingFlyByPlanKey {
        let currentAirspeed = max(wing.cruiseAirspeed, wing.minSustainableSpeedMps)
        let turnRadius = fixedWingGuidanceTurnRadius(
            wing: wing,
            airspeed: currentAirspeed
        )
        return FixedWingFlyByPlanKey(
            waypointOptions: options,
            selectedWaypointID: fixedWingAssistState.selectedWaypointID,
            activeIndex: fixedWingAssistState.activeWaypointIndex,
            autoAdvanceEnabled: fixedWingAssistState.autoAdvanceEnabled,
            turnRadiusBucket: Int((turnRadius / 5.0).rounded()),
            obstacleSignature: fixedWingObstacleSignature(),
            noFlyZoneSignature: fixedWingNoFlyZoneSignature(activeNoFlyZonesForNavigation()),
            weatherSignature: fixedWingWeatherSignature(),
            terrainSignature: fixedWingTerrainSignature()
        )
    }

    private func fixedWingFlyByTransitionPlan(
        wing: FixedWingParameters,
        options: [FixedWingAssistWaypointOption]
    ) -> FixedWingFlyByTransitionPlan? {
        let planKey = fixedWingFlyByPlanKey(wing: wing, options: options)
        if fixedWingFlyByPlanCacheKey == planKey {
            return fixedWingFlyByPlanCache
        }

        let plan = buildFixedWingFlyByTransitionPlan(
            wing: wing,
            options: options
        )
        fixedWingFlyByPlanCacheKey = planKey
        fixedWingFlyByPlanCache = plan
        fixedWingGuidanceRecomputeCount += 1
        fixedWingAssistState.guidanceRecomputeCount = fixedWingGuidanceRecomputeCount
        return plan
    }

    private func buildFixedWingFlyByTransitionPlan(
        wing: FixedWingParameters,
        options: [FixedWingAssistWaypointOption]
    ) -> FixedWingFlyByTransitionPlan? {
        guard let activeIndex = fixedWingAssistState.activeWaypointIndex,
              options.indices.contains(activeIndex),
              let selectedWaypoint = fixedWingAssistWaypointResolution(options: options).option else {
            return nil
        }

        let currentAirspeed = max(state.forwardAirspeed, wing.minSustainableSpeedMps)
        let estimatedTurnRadius = fixedWingGuidanceTurnRadius(
            wing: wing,
            airspeed: currentAirspeed
        )
        let lookaheadDistance = max(
            wing.guidanceLookaheadDistance(airspeed: currentAirspeed),
            wing.loiterRadiusMeters * 1.15
        )
        let classification = fixedWingAssistWaypointClassification(
            activeIndex: activeIndex,
            options: options
        )
        let nextWaypointIndex = classification.nextWaypointIndex
        let inboundStart = fixedWingAssistRuntimeStart(
            selectedWaypointID: selectedWaypoint.id,
            activeWaypointIndex: activeIndex
        )
        let directDelta = selectedWaypoint.position - inboundStart
        let directDistance = simd_length(directDelta)
        let directPlan = FixedWingFlyByTransitionPlan(
            selectedWaypoint: selectedWaypoint,
            nextWaypointIndex: nextWaypointIndex,
            currentLegStart: directDistance > 0.001 ? inboundStart : nil,
            currentLegMiddle: selectedWaypoint.position,
            currentLegEnd: nextWaypointIndex.flatMap { options[$0].position },
            inboundDirection: directDistance > 0.001 ? directDelta / directDistance : nil,
            outboundDirection: nil,
            inboundLength: directDistance,
            outboundLength: 0.0,
            estimatedTurnRadius: estimatedTurnRadius,
            lookaheadDistance: lookaheadDistance,
            inboundCourseDegrees: directDistance > 0.001
                ? fixedWingCourseRadians(from: directDelta / directDistance).radiansToDegrees
                : nil,
            outboundCourseDegrees: nil,
            courseChangeDegrees: nil,
            leadDistanceMeters: nil,
            isDirectIntercept: true,
            isStraightTransition: true,
            flyByTransitionFeasible: false,
            obstacleInTurnCorridor: false,
            blockedPathToNextWaypoint: false,
            collisionRiskToNextWaypoint: nil,
            shouldPauseForPoorGeometry: false,
            shouldPauseForObstacle: false,
            lateralGuidanceSuppressedForPoorGeometry: false,
            suppressedReason: nil
        )

        guard directDistance > 0.001,
              let nextIndex = nextWaypointIndex,
              options.indices.contains(nextIndex) else {
            return directPlan
        }

        let middle = selectedWaypoint.position
        let end = options[nextIndex].position
        let inbound = middle - inboundStart
        let outbound = end - middle
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.001,
              outboundLength > 0.001 else {
            return directPlan
        }
        let inboundDirection = inbound / inboundLength
        let outboundDirection = outbound / outboundLength
        let inboundCourse = fixedWingCourseRadians(from: inboundDirection)
        let outboundCourse = fixedWingCourseRadians(from: outboundDirection)
        let courseChangeRadians = abs(shortestAngleRadians(outboundCourse - inboundCourse))
        let courseChangeDegrees = courseChangeRadians.radiansToDegrees
        let leadDistance = fixedWingAssistTurnLeadDistance(
            start: inboundStart,
            middle: middle,
            end: end,
            wing: wing,
            airspeed: currentAirspeed
        )
        let isStraightTransition = courseChangeRadians <= 0.06
        let segmentTooShort = min(inboundLength, outboundLength) < max(
            wing.waypointAcceptanceRadiusMeters * 1.4,
            estimatedTurnRadius * 0.75
        )
        let angleTooSharp = courseChangeDegrees >= 150.0
        let insufficientTurnRadius = courseChangeDegrees >= 35.0 &&
            min(inboundLength, outboundLength) < max(leadDistance * 1.35, estimatedTurnRadius * 0.9)
        let corridorAssessment = evaluateFixedWingTurnCorridorAssessment(
            start: inboundStart,
            middle: middle,
            end: end,
            leadDistance: leadDistance,
            estimatedTurnRadius: estimatedTurnRadius,
            airspeed: currentAirspeed,
            wing: wing
        )
        let shouldPauseForObstacle = corridorAssessment.obstacleInTurnCorridor || corridorAssessment.blockedPath
        let flyByTransitionFeasible = !shouldPauseForObstacle && (
            isStraightTransition || (
                !segmentTooShort &&
                !angleTooSharp &&
                !insufficientTurnRadius
            )
        )
        let poorGeometryReason: String? = {
            if segmentTooShort { return "turn_transition_segment_too_short" }
            if angleTooSharp { return "turn_transition_angle_too_sharp" }
            if insufficientTurnRadius { return "turn_transition_insufficient_radius" }
            if isStraightTransition { return nil }
            return "fly_by_transition_not_feasible"
        }()
        let suppressedReason = shouldPauseForObstacle
            ? corridorAssessment.suppressedReason
            : poorGeometryReason

        return FixedWingFlyByTransitionPlan(
            selectedWaypoint: selectedWaypoint,
            nextWaypointIndex: nextWaypointIndex,
            currentLegStart: inboundStart,
            currentLegMiddle: middle,
            currentLegEnd: end,
            inboundDirection: inboundDirection,
            outboundDirection: outboundDirection,
            inboundLength: inboundLength,
            outboundLength: outboundLength,
            estimatedTurnRadius: estimatedTurnRadius,
            lookaheadDistance: lookaheadDistance,
            inboundCourseDegrees: inboundCourse.radiansToDegrees,
            outboundCourseDegrees: outboundCourse.radiansToDegrees,
            courseChangeDegrees: courseChangeDegrees,
            leadDistanceMeters: leadDistance,
            isDirectIntercept: false,
            isStraightTransition: isStraightTransition,
            flyByTransitionFeasible: flyByTransitionFeasible,
            obstacleInTurnCorridor: corridorAssessment.obstacleInTurnCorridor,
            blockedPathToNextWaypoint: corridorAssessment.blockedPath,
            collisionRiskToNextWaypoint: corridorAssessment.collisionRisk,
            shouldPauseForPoorGeometry: !shouldPauseForObstacle && !flyByTransitionFeasible,
            shouldPauseForObstacle: shouldPauseForObstacle,
            lateralGuidanceSuppressedForPoorGeometry: !shouldPauseForObstacle && !flyByTransitionFeasible,
            suppressedReason: suppressedReason
        )
    }

    private func fixedWingAssistFlyByGuidanceSnapshot(
        wing: FixedWingParameters
    ) -> FixedWingAssistFlyByGuidanceSnapshot? {
        let options = fixedWingAssistWaypointOptions
        guard let activeIndex = fixedWingAssistState.activeWaypointIndex,
              options.indices.contains(activeIndex),
              let plan = fixedWingFlyByTransitionPlan(wing: wing, options: options) else {
            return nil
        }

        let currentPosition = currentPlanarPosition()
        let captureRadius = wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed)
        var directGuidanceTarget = plan.selectedWaypoint.position
        var directGuidanceMode = "singlePointIntercept"
        if let start = plan.currentLegStart,
           let middle = plan.currentLegMiddle {
            let legDelta = middle - start
            let legLength = simd_length(legDelta)
            if legLength > 0.001 {
                let legDirection = legDelta / legLength
                let projection = fixedWingAssistProjection(
                    from: start,
                    to: middle,
                    position: currentPosition
                )
                directGuidanceTarget = fixedWingAssistCaptureLineAimPoint(
                    start: start,
                    direction: legDirection,
                    alongTrackDistance: projection.alongTrackDistance,
                    legLength: legLength,
                    captureRadius: captureRadius,
                    lookaheadDistance: plan.lookaheadDistance
                )
                directGuidanceMode = "inboundLegTrack"
            }
        } else {
            let directDelta = plan.selectedWaypoint.position - currentPosition
            let directLength = simd_length(directDelta)
            if directLength > 0.001 {
                directGuidanceTarget = fixedWingAssistCaptureLineAimPoint(
                    start: currentPosition,
                    direction: directDelta / directLength,
                    alongTrackDistance: 0.0,
                    legLength: directLength,
                    captureRadius: captureRadius,
                    lookaheadDistance: plan.lookaheadDistance
                )
                directGuidanceMode = "directCaptureLine"
            }
        }
        if let protectedGuidanceSnapshot = fixedWingAssistProtectedGuidanceSnapshot(
            plan: plan,
            currentPosition: currentPosition,
            captureRadius: captureRadius,
            targetAltitude: max(0.0, state.position.y)
        ) {
            return protectedGuidanceSnapshot
        }
        let directSnapshot = FixedWingAssistFlyByGuidanceSnapshot(
            guidanceTarget: directGuidanceTarget,
            captureTarget: plan.selectedWaypoint.position,
            guidanceMode: directGuidanceMode,
            currentLegStart: plan.currentLegStart,
            currentLegMiddle: plan.currentLegMiddle,
            currentLegEnd: plan.currentLegEnd,
            inboundCourseDegrees: plan.inboundCourseDegrees,
            outboundCourseDegrees: plan.outboundCourseDegrees,
            courseChangeDegrees: plan.courseChangeDegrees,
            estimatedTurnRadius: plan.estimatedTurnRadius,
            leadDistanceMeters: plan.leadDistanceMeters,
            flyByTransitionActive: false,
            flyByTransitionFeasible: true,
            headingErrorToNextWaypointDegrees: nil,
            nextWaypointInForwardSector: false,
            enoughTurnInDistance: false,
            collisionRiskToNextWaypoint: plan.collisionRiskToNextWaypoint,
            obstacleInTurnCorridor: plan.obstacleInTurnCorridor,
            blockedPathToNextWaypoint: plan.blockedPathToNextWaypoint,
            lateralGuidanceSuppressedForPoorGeometry: false,
            shouldPauseForPoorGeometry: false,
            shouldPauseForObstacle: false,
            shouldHandoffToNext: false,
            suppressedReason: nil
        )

        guard !plan.isDirectIntercept,
              let start = plan.currentLegStart,
              let middle = plan.currentLegMiddle,
              let end = plan.currentLegEnd,
              let inboundDirection = plan.inboundDirection,
              let leadDistance = plan.leadDistanceMeters else {
            return directSnapshot
        }

        let currentProjection = fixedWingAssistProjection(
            from: start,
            to: middle,
            position: currentPosition
        )
        let inboundAimPoint = fixedWingAssistCaptureLineAimPoint(
            start: start,
            direction: inboundDirection,
            alongTrackDistance: currentProjection.alongTrackDistance,
            legLength: currentProjection.legLength,
            captureRadius: captureRadius,
            lookaheadDistance: plan.lookaheadDistance
        )

        return FixedWingAssistFlyByGuidanceSnapshot(
            guidanceTarget: inboundAimPoint,
            captureTarget: middle,
            guidanceMode: "inboundLegTrack",
            currentLegStart: start,
            currentLegMiddle: middle,
            currentLegEnd: end,
            inboundCourseDegrees: plan.inboundCourseDegrees,
            outboundCourseDegrees: plan.outboundCourseDegrees,
            courseChangeDegrees: plan.courseChangeDegrees,
            estimatedTurnRadius: plan.estimatedTurnRadius,
            leadDistanceMeters: leadDistance,
            flyByTransitionActive: false,
            flyByTransitionFeasible: true,
            headingErrorToNextWaypointDegrees: nil,
            nextWaypointInForwardSector: false,
            enoughTurnInDistance: false,
            collisionRiskToNextWaypoint: plan.collisionRiskToNextWaypoint,
            obstacleInTurnCorridor: plan.obstacleInTurnCorridor,
            blockedPathToNextWaypoint: plan.blockedPathToNextWaypoint,
            lateralGuidanceSuppressedForPoorGeometry: false,
            shouldPauseForPoorGeometry: false,
            shouldPauseForObstacle: false,
            shouldHandoffToNext: false,
            suppressedReason: nil
        )
    }

    private func fixedWingAssistProtectedGuidanceSnapshot(
        plan: FixedWingFlyByTransitionPlan,
        currentPosition: SIMD2<Float>,
        captureRadius: Float,
        targetAltitude: Float
    ) -> FixedWingAssistFlyByGuidanceSnapshot? {
        let noFlyZones = activeNoFlyZonesForNavigation()
        let protectedNoFlyZones = fixedWingProtectedNoFlyZones(noFlyZones)
        let directPath = [currentPosition, plan.selectedWaypoint.position]
        let obstacles = navigationObstacles(including: protectedNoFlyZones)
        let pathBlocked = planarPathIntersectsNoFly(directPath, zones: protectedNoFlyZones) ||
            fixedWingPathNeedsObstacleReroute(
                directPath,
                obstacles: obstacles,
                targetAltitude: targetAltitude
            )
        guard pathBlocked else {
            return nil
        }

        guard let safeRoute = safeFixedWingRoute(
            from: [currentPosition, plan.selectedWaypoint.position],
            zones: noFlyZones,
            viewport: currentTacticalMapViewport(),
            targetAltitude: targetAltitude
        ),
              safeRoute.wasRerouted,
              safeRoute.points.count >= 2 else {
            return fixedWingAssistBlockedProtectedGuidanceSnapshot(
                plan: plan,
                currentPosition: currentPosition,
                obstacles: obstacles
            )
        }

        let routePoints = safeRoute.points
        let segmentStart = routePoints[0]
        let segmentEnd = routePoints[1]
        let segmentDelta = segmentEnd - segmentStart
        let segmentLength = simd_length(segmentDelta)
        guard segmentLength > 0.001 else {
            return nil
        }

        let direction = segmentDelta / segmentLength
        let isFinalSegment = routePoints.count == 2
        let guidanceTarget: SIMD2<Float>
        if isFinalSegment {
            guidanceTarget = fixedWingAssistCaptureLineAimPoint(
                start: segmentStart,
                direction: direction,
                alongTrackDistance: 0.0,
                legLength: segmentLength,
                captureRadius: captureRadius,
                lookaheadDistance: plan.lookaheadDistance
            )
        } else {
            guidanceTarget = segmentStart + direction * min(
                segmentLength,
                max(1.0, plan.lookaheadDistance)
            )
        }

        let nextLegEnd = routePoints.indices.contains(2)
            ? routePoints[2]
            : plan.selectedWaypoint.position
        let inboundCourse = fixedWingCourseRadians(from: direction).radiansToDegrees

        return FixedWingAssistFlyByGuidanceSnapshot(
            guidanceTarget: guidanceTarget,
            captureTarget: plan.selectedWaypoint.position,
            guidanceMode: "protectedRouteTrack",
            currentLegStart: segmentStart,
            currentLegMiddle: segmentEnd,
            currentLegEnd: nextLegEnd,
            inboundCourseDegrees: inboundCourse,
            outboundCourseDegrees: nil,
            courseChangeDegrees: nil,
            estimatedTurnRadius: plan.estimatedTurnRadius,
            leadDistanceMeters: plan.leadDistanceMeters,
            flyByTransitionActive: false,
            flyByTransitionFeasible: true,
            headingErrorToNextWaypointDegrees: nil,
            nextWaypointInForwardSector: false,
            enoughTurnInDistance: false,
            collisionRiskToNextWaypoint: plan.collisionRiskToNextWaypoint,
            obstacleInTurnCorridor: plan.obstacleInTurnCorridor,
            blockedPathToNextWaypoint: plan.blockedPathToNextWaypoint,
            lateralGuidanceSuppressedForPoorGeometry: false,
            shouldPauseForPoorGeometry: false,
            shouldPauseForObstacle: false,
            shouldHandoffToNext: false,
            suppressedReason: nil
        )
    }

    private func fixedWingAssistBlockedProtectedGuidanceSnapshot(
        plan: FixedWingFlyByTransitionPlan,
        currentPosition: SIMD2<Float>,
        obstacles: [CollisionObstacle]
    ) -> FixedWingAssistFlyByGuidanceSnapshot {
        let fallbackDirection: SIMD2<Float> = {
            if let nearestObstacle = obstacles.min(by: {
                simd_distance(currentPosition, $0.planarCenter) < simd_distance(currentPosition, $1.planarCenter)
            }) {
                let away = currentPosition - nearestObstacle.planarCenter
                let awayLength = simd_length(away)
                if awayLength > 0.001 {
                    return away / awayLength
                }
            }

            return SIMD2<Float>(
                -sin(state.orientation.z),
                -cos(state.orientation.z)
            )
        }()
        let holdDistance = max(plan.lookaheadDistance, plan.estimatedTurnRadius * 0.6, 8.0)
        let guidanceTarget = currentPosition + fallbackDirection * holdDistance
        let inboundCourse = fixedWingCourseRadians(from: fallbackDirection).radiansToDegrees

        return FixedWingAssistFlyByGuidanceSnapshot(
            guidanceTarget: guidanceTarget,
            captureTarget: plan.selectedWaypoint.position,
            guidanceMode: "protectedRouteBlocked",
            currentLegStart: currentPosition,
            currentLegMiddle: guidanceTarget,
            currentLegEnd: nil,
            inboundCourseDegrees: inboundCourse,
            outboundCourseDegrees: nil,
            courseChangeDegrees: nil,
            estimatedTurnRadius: plan.estimatedTurnRadius,
            leadDistanceMeters: plan.leadDistanceMeters,
            flyByTransitionActive: false,
            flyByTransitionFeasible: false,
            headingErrorToNextWaypointDegrees: nil,
            nextWaypointInForwardSector: false,
            enoughTurnInDistance: false,
            collisionRiskToNextWaypoint: max(plan.collisionRiskToNextWaypoint ?? 0.0, 0.72),
            obstacleInTurnCorridor: true,
            blockedPathToNextWaypoint: true,
            lateralGuidanceSuppressedForPoorGeometry: true,
            shouldPauseForPoorGeometry: false,
            shouldPauseForObstacle: true,
            shouldHandoffToNext: false,
            suppressedReason: "protected_route_blocked"
        )
    }

    private func fixedWingAssistCaptureLineAimPoint(
        start: SIMD2<Float>,
        direction: SIMD2<Float>,
        alongTrackDistance: Float,
        legLength: Float,
        captureRadius: Float,
        lookaheadDistance: Float
    ) -> SIMD2<Float> {
        guard legLength > 0.001 else {
            return start
        }

        let boundedLookahead = min(
            lookaheadDistance,
            max(captureRadius * 3.0, legLength)
        )
        // Stop the moving aim point at the waypoint center. Letting it extend
        // beyond the waypoint and continue moving ahead kept the aircraft on a
        // nearly parallel course whenever cross-track error remained.
        let desiredDistance = min(
            legLength,
            max(0.0, alongTrackDistance + boundedLookahead)
        )
        return start + direction * desiredDistance
    }

    private func evaluateFixedWingTurnCorridorAssessment(
        start: SIMD2<Float>,
        middle: SIMD2<Float>,
        end: SIMD2<Float>,
        leadDistance: Float,
        estimatedTurnRadius: Float,
        airspeed: Float,
        wing: FixedWingParameters
    ) -> FixedWingTurnCorridorAssessment {
        let inbound = middle - start
        let outbound = end - middle
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.001, outboundLength > 0.001 else {
            return FixedWingTurnCorridorAssessment(
                obstacleInTurnCorridor: false,
                blockedPath: false,
                collisionRisk: 0.0,
                suppressedReason: nil
            )
        }

        let inboundDirection = inbound / inboundLength
        let outboundDirection = outbound / outboundLength
        let inboundCourse = fixedWingCourseRadians(from: inboundDirection)
        let outboundCourse = fixedWingCourseRadians(from: outboundDirection)
        let courseChangeRadians = abs(shortestAngleRadians(outboundCourse - inboundCourse))
        let tangentFactor = tan(min(.pi * 0.45, courseChangeRadians * 0.5))
        let turnSign = inboundDirection.x * outboundDirection.y - inboundDirection.y * outboundDirection.x

        guard courseChangeRadians > 0.06,
              abs(turnSign) > 0.001,
              tangentFactor.isFinite,
              tangentFactor > 0.05 else {
            return FixedWingTurnCorridorAssessment(
                obstacleInTurnCorridor: false,
                blockedPath: false,
                collisionRisk: 0.0,
                suppressedReason: nil
            )
        }

        let effectiveRadius = max(
            wing.waypointAcceptanceRadiusMeters,
            min(estimatedTurnRadius, leadDistance / tangentFactor)
        )
        let entryPoint = middle - inboundDirection * leadDistance
        let exitPoint = middle + outboundDirection * leadDistance
        let leftNormal = SIMD2<Float>(-inboundDirection.y, inboundDirection.x)
        let center = turnSign > 0.0
            ? entryPoint + leftNormal * effectiveRadius
            : entryPoint - leftNormal * effectiveRadius

        let startAngle = atan2(entryPoint.y - center.y, entryPoint.x - center.x)
        let endAngle = atan2(exitPoint.y - center.y, exitPoint.x - center.x)
        let sweepAngle = fixedWingArcSweep(
            startAngle: startAngle,
            endAngle: endAngle,
            turnSign: turnSign
        )
        let sampleCount = max(5, min(14, Int(ceil(abs(sweepAngle) / (.pi / 10.0)))))
        var arcPoints: [SIMD2<Float>] = [entryPoint]
        arcPoints.reserveCapacity(sampleCount + 1)
        for index in 1..<sampleCount {
            let fraction = Float(index) / Float(sampleCount)
            let sampleAngle = startAngle + sweepAngle * fraction
            arcPoints.append(
                SIMD2<Float>(
                    center.x + cos(sampleAngle) * effectiveRadius,
                    center.y + sin(sampleAngle) * effectiveRadius
                )
            )
        }
        arcPoints.append(exitPoint)

        let droneRadius = selectedDroneProfile.collisionRadius
        let corridorHalfWidth = max(
            droneRadius * 1.8,
            min(
                max(wing.waypointAcceptanceRadiusMeters * 0.95, effectiveRadius * 0.28),
                12.0
            )
        )
        let verticalTolerance = max(2.0, droneRadius * 1.6)
        // Cheap distance pre-filter before any of the expensive per-obstacle
        // work below (segment-distance scan, full collision analysis, path
        // assessment) — on a large map with hundreds of environment
        // obstacles (procedural trees etc.), running that work against every
        // single one every time the aircraft nears a waypoint measured as a
        // real, reproducible freeze. Nothing farther than the corridor's own
        // reach from `middle` can possibly intersect it, so this can only
        // drop obstacles that were guaranteed-irrelevant anyway.
        let corridorBoundingRadius = leadDistance + effectiveRadius + corridorHalfWidth + 20.0
        let navigationObstacles = navigationObstaclesIncludingNoFlyZones().filter {
            simd_distance($0.planarCenter, middle) <= corridorBoundingRadius + $0.radius
        }
        let obstacleInTurnCorridor = navigationObstacles.contains { obstacle in
            let minimumDistance = zip(arcPoints, arcPoints.dropFirst()).reduce(Float.greatestFiniteMagnitude) { currentMinimum, segment in
                min(
                    currentMinimum,
                    planarDistanceToSegment(
                        point: obstacle.planarCenter,
                        segmentStart: segment.0,
                        segmentEnd: segment.1
                    )
                )
            }
            let verticalGap = obstacle.verticalGap(
                toDroneCenterY: state.position.y,
                droneRadius: droneRadius
            )
            return minimumDistance <= corridorHalfWidth + obstacle.radius && verticalGap <= verticalTolerance
        }

        let probeAltitude = max(2.0, state.position.y)
        let probeSpeed = max(state.forwardAirspeed, wing.minSustainableSpeedMps, airspeed)
        var collisionRisk: Float = 0.0
        var blockedPath = false
        var penaltySuggestsRisk = false

        for segment in zip(arcPoints, arcPoints.dropFirst()) {
            let segmentDelta = segment.1 - segment.0
            let segmentLength = simd_length(segmentDelta)
            guard segmentLength > 0.05 else {
                continue
            }

            let direction = segmentDelta / segmentLength
            let midpoint = segment.0 + segmentDelta * 0.5
            let probeVelocity = SIMD3<Float>(
                direction.x * probeSpeed,
                0.0,
                direction.y * probeSpeed
            )
            let risk = collisionService.analyze(
                input: CollisionAnalysisInput(
                    dronePosition: SIMD3<Float>(midpoint.x, probeAltitude, midpoint.y),
                    droneVelocity: probeVelocity,
                    droneRadius: droneRadius,
                    obstacles: navigationObstacles,
                    weather: weather
                )
            ).riskScore
            collisionRisk = max(collisionRisk, risk)

            let pathAssessment = autoPathPlanner.assessDirectPath(
                from: SIMD3<Float>(segment.0.x, probeAltitude, segment.0.y),
                to: SIMD3<Float>(segment.1.x, probeAltitude, segment.1.y),
                terrain: terrain,
                obstacles: navigationObstacles,
                droneRadius: droneRadius
            )
            blockedPath = blockedPath || pathAssessment.blocked
            penaltySuggestsRisk = penaltySuggestsRisk || pathAssessment.maxPenalty >= 0.72
        }

        if penaltySuggestsRisk {
            collisionRisk = max(collisionRisk, 0.72)
        }

        let suppressedReason: String?
        if blockedPath {
            suppressedReason = "blocked_turn_corridor"
        } else if obstacleInTurnCorridor {
            suppressedReason = "obstacle_in_turn_corridor"
        } else if collisionRisk >= 0.65 {
            suppressedReason = "collision_risk_in_turn_corridor"
        } else {
            suppressedReason = nil
        }

        return FixedWingTurnCorridorAssessment(
            obstacleInTurnCorridor: obstacleInTurnCorridor,
            blockedPath: blockedPath || penaltySuggestsRisk,
            collisionRisk: collisionRisk,
            suppressedReason: suppressedReason
        )
    }

    private func fixedWingArcSweep(
        startAngle: Float,
        endAngle: Float,
        turnSign: Float
    ) -> Float {
        var delta = shortestAngleRadians(endAngle - startAngle)
        if turnSign > 0.0, delta < 0.0 {
            delta += .pi * 2.0
        } else if turnSign < 0.0, delta > 0.0 {
            delta -= .pi * 2.0
        }
        return delta
    }

    private func planarDistanceToSegment(
        point: SIMD2<Float>,
        segmentStart: SIMD2<Float>,
        segmentEnd: SIMD2<Float>
    ) -> Float {
        let delta = segmentEnd - segmentStart
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.0001 else {
            return simd_distance(point, segmentStart)
        }

        let projection = simd_dot(point - segmentStart, delta) / lengthSquared
        let clampedProjection = projection.clamped(to: 0.0...1.0)
        let closestPoint = segmentStart + delta * clampedProjection
        return simd_distance(point, closestPoint)
    }

    private func clearFixedWingAssistTurnTransitionDiagnostics(
        _ assistState: inout FixedWingAssistState
    ) {
        assistState.currentLegStart = nil
        assistState.currentLegMiddle = nil
        assistState.currentLegEnd = nil
        assistState.inboundCourseDegrees = nil
        assistState.outboundCourseDegrees = nil
        assistState.courseChangeDegrees = nil
        assistState.leadDistanceMeters = nil
        assistState.flyByTransitionActive = false
        assistState.flyByTransitionFeasible = false
        assistState.activeGuidanceMode = assistState.mode == .waypointIntercept ? "singlePointIntercept" : "none"
        assistState.frameTimeDuringTransitionMs = nil
    }

    private func applyFixedWingAssistFlyBySnapshot(
        _ snapshot: FixedWingAssistFlyByGuidanceSnapshot?,
        to assistState: inout FixedWingAssistState
    ) {
        if assistState.mode == .waypointIntercept,
           assistState.interceptCompleted {
            assistState.flyByTransitionActive = false
            assistState.flyByTransitionFeasible = false
            assistState.headingErrorToNextWaypointDegrees = nil
            assistState.nextWaypointInForwardSector = false
            assistState.enoughTurnInDistance = false
            assistState.lateralGuidanceSuppressedForPoorGeometry = false
            assistState.autoAdvanceSuppressed = false
            assistState.autoAdvanceSuppressedReason = nil
            assistState.usingObsoleteFixedWingMode = false
            assistState.guidanceRecomputeCount = fixedWingGuidanceRecomputeCount
            assistState.heavyMapRebuildCount = terrainMapHeavyRebuildCount
            assistState.frameTimeDuringTransitionMs = nil
            return
        }

        guard let snapshot else {
            clearFixedWingAssistTurnTransitionDiagnostics(&assistState)
            assistState.headingErrorToNextWaypointDegrees = nil
            assistState.nextWaypointInForwardSector = false
            assistState.enoughTurnInDistance = false
            assistState.collisionRiskToNextWaypoint = nil
            assistState.obstacleInTurnCorridor = false
            assistState.blockedPathToNextWaypoint = false
            assistState.lateralGuidanceSuppressedForPoorGeometry = false
            assistState.autoAdvanceSuppressed = false
            assistState.autoAdvanceSuppressedReason = nil
            assistState.usingObsoleteFixedWingMode = false
            assistState.guidanceRecomputeCount = fixedWingGuidanceRecomputeCount
            assistState.heavyMapRebuildCount = terrainMapHeavyRebuildCount
            assistState.frameTimeDuringTransitionMs = nil
            return
        }

        assistState.currentLegStart = snapshot.currentLegStart
        assistState.currentLegMiddle = snapshot.currentLegMiddle
        assistState.currentLegEnd = snapshot.currentLegEnd
        assistState.inboundCourseDegrees = snapshot.inboundCourseDegrees
        assistState.outboundCourseDegrees = snapshot.outboundCourseDegrees
        assistState.courseChangeDegrees = snapshot.courseChangeDegrees
        assistState.estimatedTurnRadiusMeters = snapshot.estimatedTurnRadius
        assistState.leadDistanceMeters = snapshot.leadDistanceMeters
        assistState.flyByTransitionActive = snapshot.flyByTransitionActive
        assistState.flyByTransitionFeasible = snapshot.flyByTransitionFeasible
        assistState.activeGuidanceMode = snapshot.guidanceMode
        assistState.headingErrorToNextWaypointDegrees = snapshot.headingErrorToNextWaypointDegrees
        assistState.nextWaypointInForwardSector = snapshot.nextWaypointInForwardSector
        assistState.enoughTurnInDistance = snapshot.enoughTurnInDistance
        assistState.collisionRiskToNextWaypoint = snapshot.collisionRiskToNextWaypoint
        assistState.obstacleInTurnCorridor = snapshot.obstacleInTurnCorridor
        assistState.blockedPathToNextWaypoint = snapshot.blockedPathToNextWaypoint
        assistState.lateralGuidanceSuppressedForPoorGeometry = snapshot.lateralGuidanceSuppressedForPoorGeometry
        assistState.activeGuidanceTargetType = snapshot.guidanceMode
        assistState.usingObsoleteFixedWingMode = false
        assistState.guidanceRecomputeCount = fixedWingGuidanceRecomputeCount
        assistState.heavyMapRebuildCount = terrainMapHeavyRebuildCount
        assistState.frameTimeDuringTransitionMs = snapshot.flyByTransitionActive
            ? cachedDiagnostics.frameTimeMs
            : nil

        if snapshot.shouldPauseForObstacle {
            assistState.interceptState = .autoAdvancePausedObstacle
            assistState.autoAdvanceSuppressed = true
            assistState.autoAdvanceSuppressedReason = snapshot.suppressedReason
        } else if snapshot.shouldPauseForPoorGeometry {
            assistState.interceptState = .autoAdvancePausedPoorGeometry
            assistState.autoAdvanceSuppressed = true
            assistState.autoAdvanceSuppressedReason = snapshot.suppressedReason
        } else {
            assistState.interceptState = fixedWingAssistInterceptState(for: snapshot.guidanceMode)
            assistState.autoAdvanceSuppressed = false
            assistState.autoAdvanceSuppressedReason = nil
        }
    }

    private func fixedWingAssistInterceptState(
        for guidanceMode: String
    ) -> FixedWingAssistInterceptState {
        switch guidanceMode {
        case "inboundLegTrack":
            return .inboundLegTrack
        case "flyByTurnTransition":
            return .flyByTurnTransition
        case "outboundLegTrack":
            return .outboundLegTrack
        case "terminalCapture":
            return .terminalCapture
        case "routeComplete":
            return .routeComplete
        case "singlePointIntercept":
            return .singlePointIntercept
        default:
            return .singlePointIntercept
        }
    }

    private func performFixedWingAssistFlyByHandoff(
        to nextWaypointIndex: Int,
        options: [FixedWingAssistWaypointOption]
    ) -> Bool {
        guard options.indices.contains(nextWaypointIndex) else {
            return false
        }

        let previousWaypointID = fixedWingAssistState.selectedWaypointID
        let nextWaypoint = options[nextWaypointIndex]
        resetFixedWingRuntimeRouteStart()
        fixedWingAssistState.selectedWaypointID = nextWaypoint.id
        fixedWingAssistState.activeWaypointIndex = nextWaypointIndex
        fixedWingAssistState.nextWaypointIndex = resolvedFixedWingAssistNextWaypointIndex(
            activeIndex: nextWaypointIndex,
            options: options
        )
        fixedWingAssistState.interceptCompleted = false
        fixedWingAssistState.captureCompletedReason = nil
        clearFixedWingAssistAutoAdvanceDiagnostics(
            &fixedWingAssistState,
            preserveCaptureCompletedReason: false
        )
        fixedWingAssistState = fixedWingAssistController.engage(
            .waypointIntercept,
            from: state,
            selectedWaypointID: nextWaypoint.id,
            currentState: fixedWingAssistState
        )
        if let previousWaypointID,
           !fixedWingAssistState.capturedWaypointIDs.contains(previousWaypointID) {
            fixedWingAssistState.capturedWaypointIDs.append(previousWaypointID)
        }
        syncFixedWingAssistSelection()
        fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_flyby_handoff"
        fixedWingAssistState.activeGuidanceMode = "outboundLegTrack"
        fixedWingAssistState.activeGuidanceTargetType = "outboundLegTrack"
        fixedWingAssistState.interceptState = .outboundLegTrack
        fixedWingLastTransitionReason = fixedWingAssistState.stateTransitionReason
        return true
    }

    private func clearFixedWingAssistAutoAdvanceDiagnostics(
        _ assistState: inout FixedWingAssistState,
        preserveCaptureCompletedReason: Bool = true
    ) {
        if !preserveCaptureCompletedReason {
            assistState.captureCompletedReason = nil
        }
        assistState.autoAdvanceSuppressed = false
        assistState.autoAdvanceSuppressedReason = nil
        assistState.headingErrorToNextWaypointDegrees = nil
        assistState.nextWaypointInForwardSector = false
        assistState.enoughTurnInDistance = false
        assistState.collisionRiskToNextWaypoint = nil
        assistState.obstacleInTurnCorridor = false
        assistState.blockedPathToNextWaypoint = false
        assistState.lateralGuidanceSuppressedForPoorGeometry = false
        assistState.usingObsoleteFixedWingMode = false
    }

    @discardableResult
    private func updatePendingFixedWingAutoAdvanceIfNeeded() -> Bool {
        let options = fixedWingAssistWaypointOptions
        let classification = fixedWingAssistWaypointClassification(
            activeIndex: fixedWingAssistState.activeWaypointIndex,
            options: options
        )
        applyFixedWingWaypointClassification(classification, to: &fixedWingAssistState)

        guard fixedWingAssistState.autoAdvanceEnabled,
              fixedWingAssistState.interceptCompleted,
              fixedWingAssistState.mode == .waypointIntercept,
              let nextWaypointIndex = classification.nextWaypointIndex else {
            return false
        }

        guard options.indices.contains(nextWaypointIndex) else {
            return false
        }

        let nextWaypoint = options[nextWaypointIndex]
        resetFixedWingRuntimeRouteStart()
        fixedWingAssistState.selectedWaypointID = nextWaypoint.id
        fixedWingAssistState.activeWaypointIndex = nextWaypointIndex
        fixedWingAssistState.nextWaypointIndex = resolvedFixedWingAssistNextWaypointIndex(
            activeIndex: nextWaypointIndex,
            options: options
        )
        clearFixedWingAssistAutoAdvanceDiagnostics(
            &fixedWingAssistState,
            preserveCaptureCompletedReason: false
        )

        fixedWingAssistState = fixedWingAssistController.engage(
            .waypointIntercept,
            from: state,
            selectedWaypointID: nextWaypoint.id,
            currentState: fixedWingAssistState
        )
        syncFixedWingAssistSelection()
        // Defer potentially expensive protected-route/A* guidance for the new
        // waypoint until the next simulation tick.
        fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_auto_advance_to_next_waypoint"
        fixedWingLastTransitionReason = fixedWingAssistState.stateTransitionReason
        return true
    }

    @discardableResult
    private func handleFixedWingAssistCaptureCompletion() -> Bool {
        let options = fixedWingAssistWaypointOptions
        let classification = fixedWingAssistWaypointClassification(
            activeIndex: fixedWingAssistState.activeWaypointIndex,
            options: options
        )
        applyFixedWingWaypointClassification(classification, to: &fixedWingAssistState)

        if classification.isFinalWaypoint || !classification.hasNextWaypoint {
            clearFixedWingAssistAutoAdvanceDiagnostics(&fixedWingAssistState)
            fixedWingAssistState.targetHeadingRadians = state.orientation.z
            fixedWingAssistState.targetAltitudeMeters = max(0.0, state.position.y)
            fixedWingAssistState.interceptState = .routeComplete
            fixedWingAssistState.activeGuidanceTargetType = "routeComplete"
            fixedWingAssistState.activeGuidanceMode = "routeComplete"
            fixedWingAssistUsesTargetYawWhileManual = true
            return false
        }

        guard fixedWingAssistState.autoAdvanceEnabled else {
            clearFixedWingAssistAutoAdvanceDiagnostics(&fixedWingAssistState)
            fixedWingAssistState.interceptState = .outboundLegTrack
            fixedWingAssistState.activeGuidanceTargetType = "outboundLegTrack"
            fixedWingAssistState.activeGuidanceMode = "outboundLegTrack"
            fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_nonfinal_waypoint_waiting_next_selection"
            fixedWingLastTransitionReason = fixedWingAssistState.stateTransitionReason
            return false
        }

        guard let activeWaypointIndex = classification.activeWaypointIndex,
              options.indices.contains(activeWaypointIndex),
              let nextWaypointIndex = classification.nextWaypointIndex,
              options.indices.contains(nextWaypointIndex) else {
            fixedWingAssistState.autoAdvanceSuppressed = true
            fixedWingAssistState.autoAdvanceSuppressedReason = "no_active_waypoint"
            fixedWingAssistState.headingErrorToNextWaypointDegrees = nil
            fixedWingAssistState.nextWaypointInForwardSector = false
            fixedWingAssistState.enoughTurnInDistance = false
            fixedWingAssistState.collisionRiskToNextWaypoint = nil
            fixedWingAssistState.obstacleInTurnCorridor = false
            fixedWingAssistState.blockedPathToNextWaypoint = false
            fixedWingAssistState.lateralGuidanceSuppressedForPoorGeometry = false
            fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_auto_advance_missing_active_waypoint"
            fixedWingLastTransitionReason = fixedWingAssistState.stateTransitionReason
            return false
        }

        clearFixedWingAssistAutoAdvanceDiagnostics(&fixedWingAssistState)
        fixedWingAssistState.nextWaypointIndex = nextWaypointIndex
        fixedWingAssistState.interceptState = .outboundLegTrack
        fixedWingAssistState.activeGuidanceTargetType = "outboundLegTrack"
        fixedWingAssistState.activeGuidanceMode = "outboundLegTrack"
        fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_auto_advance_pending_flyby_handoff"
        fixedWingLastTransitionReason = fixedWingAssistState.stateTransitionReason
        return updatePendingFixedWingAutoAdvanceIfNeeded()
    }

    func selectFixedWingAssistWaypoint(_ id: UUID) {
        guard isFixedWingAssistEnabled else {
            return
        }

        let options = fixedWingAssistWaypointOptions
        guard let nextIndex = options.firstIndex(where: { $0.id == id }) else {
            return
        }

        resetFixedWingRuntimeRouteStart()
        fixedWingAssistState.selectedWaypointID = id
        fixedWingAssistState.activeWaypointIndex = nextIndex
        fixedWingAssistState.nextWaypointIndex = resolvedFixedWingAssistNextWaypointIndex(
            activeIndex: nextIndex,
            options: options
        )
        clearFixedWingAssistAutoAdvanceDiagnostics(
            &fixedWingAssistState,
            preserveCaptureCompletedReason: false
        )

        if fixedWingAssistState.mode == .waypointIntercept {
            fixedWingAssistState = fixedWingAssistController.engage(
                .waypointIntercept,
                from: state,
                selectedWaypointID: id,
                currentState: fixedWingAssistState
            )
            // Guidance for the newly selected waypoint is computed by the
            // simulation tick. Running it synchronously from the UI action
            // can include protected-route/A* work and stalls rendering.
            fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_target_selected"
            fixedWingLastTransitionReason = "fixed_wing_assist_target_selected"
        } else {
            fixedWingAssistState.interceptCompleted = false
            switch fixedWingAssistState.mode {
            case .manual:
                fixedWingAssistState.interceptState = .manual
                fixedWingAssistState.activeGuidanceTargetType = "none"
            case .headingHold:
                fixedWingAssistState.interceptState = .headingHold
                fixedWingAssistState.activeGuidanceTargetType = "none"
            case .altitudeHold:
                fixedWingAssistState.interceptState = .altitudeHold
                fixedWingAssistState.activeGuidanceTargetType = "none"
            case .waypointIntercept:
                break
            }
        }

        // Runtime diagnostics and map overlays are refreshed by the normal
        // simulation cadence. Keeping them out of the selection action avoids
        // a route rebuild on the UI/main thread.
        refreshFlightControlDiagnostics()
    }

    func setFixedWingAutoAdvanceEnabled(_ enabled: Bool) {
        guard isFixedWingAssistEnabled else {
            return
        }

        fixedWingAssistState.autoAdvanceEnabled = enabled
        let classification = fixedWingAssistWaypointClassification(
            activeIndex: fixedWingAssistState.activeWaypointIndex
        )
        applyFixedWingWaypointClassification(classification, to: &fixedWingAssistState)
        var waypointChanged = false
        if enabled,
           fixedWingAssistState.interceptCompleted,
           selectedDroneProfile.fixedWingParameters != nil {
            waypointChanged = handleFixedWingAssistCaptureCompletion()
        } else if !enabled {
            clearFixedWingAssistAutoAdvanceDiagnostics(&fixedWingAssistState)
            if fixedWingAssistState.interceptCompleted {
                if classification.hasNextWaypoint {
                    fixedWingAssistState.interceptState = .outboundLegTrack
                    fixedWingAssistState.activeGuidanceTargetType = "outboundLegTrack"
                    fixedWingAssistState.activeGuidanceMode = "outboundLegTrack"
                } else {
                    fixedWingAssistState.interceptState = .routeComplete
                    fixedWingAssistState.activeGuidanceTargetType = "routeComplete"
                    fixedWingAssistState.activeGuidanceMode = "routeComplete"
                }
            }
        }
        if !waypointChanged {
            refreshFixedWingAssistRuntimeDebugState(recomputeGuidance: false)
        }
        refreshTerrainMapSnapshotIfVisible(recordTrail: false)
        refreshFlightControlDiagnostics()
    }

    func activateFixedWingAssist(_ assistMode: FixedWingAssistMode) {
        guard isFixedWingAssistEnabled else {
            return
        }

        ensureSimulationRunning()

        if assistMode == .manual {
            cancelTargetMarkerAutoNavigation()
            if mode != .manual {
                setFlightMode(.manual, reason: "fixed_wing_assist_manual")
            }
            deactivateFixedWingAssist(reason: "fixed_wing_assist_manual")
            refreshFlightControlDiagnostics()
            return
        }

        guard isArmed, physicalState != .crashed, mode != .emergencyStop else {
            return
        }

        if assistMode == .waypointIntercept,
           resolvedFixedWingAssistWaypoint() == nil {
            return
        }

        cancelTargetMarkerAutoNavigation()
        if mode != .manual {
            setFlightMode(.manual, reason: "fixed_wing_assist_engaged")
        }
        if assistMode == .waypointIntercept {
            resetFixedWingRuntimeRouteStart()
        }

        let nextState = fixedWingAssistController.engage(
            assistMode,
            from: state,
            selectedWaypointID: resolvedFixedWingAssistWaypoint()?.id,
            currentState: fixedWingAssistState
        )
        fixedWingAssistState = nextState
        syncFixedWingAssistSelection()
        fixedWingAssistUsesTargetYawWhileManual = assistMode != .manual
        fixedWingAssistTurnOverrideTimeRemaining = 0.0
        fixedWingAssistAltitudeOverrideTimeRemaining = 0.0
        fixedWingAssistState.stateTransitionReason = "fixed_wing_assist_\(assistMode.rawValue)"
        fixedWingLastTransitionReason = "fixed_wing_assist_\(assistMode.rawValue)"
        refreshFixedWingAssistRuntimeDebugState()
        refreshTerrainMapSnapshotIfVisible(recordTrail: false)
        refreshFlightControlDiagnostics()
    }

    private func syncFixedWingAssistSelection() {
        let options = fixedWingAssistWaypointOptions
        let validIDs = Set(options.map(\.id))

        var nextState = fixedWingAssistState
        nextState.capturedWaypointIDs = nextState.capturedWaypointIDs.filter { validIDs.contains($0) }

        let resolution = fixedWingAssistWaypointResolution(options: options)
        let classification = fixedWingAssistWaypointClassification(
            activeIndex: resolution.index,
            options: options
        )
        nextState.selectedWaypointID = resolution.option?.id
        applyFixedWingWaypointClassification(classification, to: &nextState)

        guard resolution.option != nil else {
            nextState.distanceToActiveWaypointMeters = nil
            nextState.interceptCompleted = false
            nextState.interceptFeasibilityState = nil
            nextState.headingErrorDegrees = nil
            nextState.rawHeadingErrorDegrees = nil
            nextState.estimatedTurnRadiusMeters = nil
            nextState.commandedBankDegrees = nil
            nextState.filteredBankCommandDegrees = nil
            nextState.commandedTurnDirection = .none
            nextState.activeGuidanceTargetType = "none"
            clearFixedWingAssistTurnTransitionDiagnostics(&nextState)
            clearFixedWingAssistAutoAdvanceDiagnostics(
                &nextState,
                preserveCaptureCompletedReason: false
            )
            switch nextState.mode {
            case .manual:
                nextState.interceptState = .manual
            case .headingHold:
                nextState.interceptState = .headingHold
            case .altitudeHold:
                nextState.interceptState = .altitudeHold
            case .waypointIntercept:
                nextState = fixedWingAssistController.engage(
                    .headingHold,
                    from: state,
                    selectedWaypointID: nil,
                    currentState: nextState
                )
            }
            fixedWingAssistState = nextState
            return
        }

        if nextState != fixedWingAssistState {
            fixedWingAssistState = nextState
        }
    }

    private func fixedWingAssistWaypoint(
        near planarPosition: SIMD2<Float>,
        viewport: MapViewportState
    ) -> FixedWingAssistWaypointOption? {
        guard isFixedWingAssistEnabled else {
            return nil
        }

        let selectionRadius = max(
            selectedDroneProfile.fixedWingParameters?.waypointAcceptanceRadiusMeters ?? 6.0,
            min(viewport.boundaryHalfExtent * 0.03, 18.0)
        )

        return fixedWingAssistWaypointOptions
            .map { option in
                (
                    option: option,
                    distance: simd_distance(option.position, planarPosition)
                )
            }
            .filter { $0.distance <= selectionRadius }
            .min(by: { $0.distance < $1.distance })?
            .option
    }

    private func refreshFixedWingAssistRuntimeDebugState(
        precomputedGuidanceSnapshot: FixedWingAssistFlyByGuidanceSnapshot? = nil,
        recomputeGuidance: Bool = true
    ) {
        let guidanceDeferred = fixedWingGuidanceDeferredThroughTick == simulationTickCounter
        let routePlan = guidanceDeferred
            ? fixedWingFlyByRoutePlanCache
            : fixedWingFlyByRoutePlan(targetAltitude: max(0.0, state.position.y))
        let previewUsesCachedFlyByPlan = routePlan?.previewUsesCachedFlyByPlan == true && (
            currentMissionPlan != nil || tacticalMapState.previewRoute != nil
        )
        let controllerUsesCachedFlyByPlan = routePlan?.controllerUsesCachedFlyByPlan == true && (
            activeRouteTargetSource == .mission || fixedWingAssistState.mode == .waypointIntercept
        )
        fixedWingAssistState.previewUsesCachedFlyByPlan = previewUsesCachedFlyByPlan
        fixedWingAssistState.controllerUsesCachedFlyByPlan = controllerUsesCachedFlyByPlan
        fixedWingAssistState.guidanceDirectToWaypointSuppressed = controllerUsesCachedFlyByPlan &&
            (routePlan?.guidanceDirectToWaypointSuppressed ?? false)
        fixedWingAssistState.flyByPlanRecomputeCount = fixedWingGuidanceRecomputeCount
        fixedWingAssistState.fullRouteRebuildCount = fixedWingFullRouteRebuildCount
        fixedWingAssistState.overlayRebuildCount = terrainMapHeavyRebuildCount
        fixedWingAssistState.guidanceRecomputeCount = fixedWingGuidanceRecomputeCount
        fixedWingAssistState.heavyMapRebuildCount = terrainMapHeavyRebuildCount
        fixedWingAssistState.frameTimeMs = cachedDiagnostics.frameTimeMs
        if !fixedWingAssistState.flyByTransitionActive {
            fixedWingAssistState.frameTimeDuringTransitionMs = nil
        } else {
            fixedWingAssistState.frameTimeDuringTransitionMs = cachedDiagnostics.frameTimeMs
        }

        guard let activeWaypoint = resolvedFixedWingAssistWaypoint(),
              let wing = selectedDroneProfile.fixedWingParameters else {
            applyFixedWingAssistGeometryDiagnostics(nil)
            clearFixedWingAssistTurnTransitionDiagnostics(&fixedWingAssistState)
            fixedWingAssistState.activeGuidanceTargetType = "none"
            applyFixedWingWaypointClassification(
                fixedWingAssistWaypointClassification(
                    activeIndex: fixedWingAssistState.activeWaypointIndex
                ),
                to: &fixedWingAssistState
            )
            return
        }

        let classification = fixedWingAssistWaypointClassification(
            activeIndex: fixedWingAssistState.activeWaypointIndex
        )
        applyFixedWingWaypointClassification(classification, to: &fixedWingAssistState)

        fixedWingAssistState.distanceToActiveWaypointMeters = simd_distance(
            currentPlanarPosition(),
            activeWaypoint.position
        )

        if fixedWingAssistState.interceptCompleted {
            fixedWingAssistState.interceptFeasibilityState = nil
            fixedWingAssistState.headingErrorDegrees = nil
            fixedWingAssistState.rawHeadingErrorDegrees = nil
            fixedWingAssistState.estimatedTurnRadiusMeters = nil
            fixedWingAssistState.commandedBankDegrees = nil
            fixedWingAssistState.filteredBankCommandDegrees = nil
            fixedWingAssistState.commandedTurnDirection = .none
            fixedWingAssistState.flyByTransitionActive = false
            fixedWingAssistState.flyByTransitionFeasible = false
            fixedWingAssistState.activeGuidanceMode = classification.hasNextWaypoint
                ? "outboundLegTrack"
                : "routeComplete"
            fixedWingAssistState.interceptState = classification.hasNextWaypoint
                ? .outboundLegTrack
                : .routeComplete
            fixedWingAssistState.activeGuidanceTargetType = fixedWingAssistState.activeGuidanceMode
            fixedWingAssistState.usingObsoleteFixedWingMode = false
            return
        }

        let geometryAssessment = fixedWingAssistController.evaluateInterceptGeometry(
            aircraftState: state,
            wing: wing,
            target: activeWaypoint.position
        )
        if fixedWingAssistState.mode == .waypointIntercept {
            let guidanceSnapshot = precomputedGuidanceSnapshot ?? (
                recomputeGuidance && !guidanceDeferred
                    ? fixedWingAssistFlyByGuidanceSnapshot(wing: wing)
                    : nil
            )
            if let guidanceSnapshot {
                applyFixedWingAssistFlyBySnapshot(
                    guidanceSnapshot,
                    to: &fixedWingAssistState
                )
            }
            if fixedWingAssistState.interceptFeasibilityState == nil {
                fixedWingAssistState.interceptFeasibilityState = geometryAssessment?.feasibilityState
            }
            if fixedWingAssistState.rawHeadingErrorDegrees == nil {
                fixedWingAssistState.rawHeadingErrorDegrees = geometryAssessment?.headingErrorRadians.radiansToDegrees
            }
            if fixedWingAssistState.filteredBankCommandDegrees == nil {
                fixedWingAssistState.filteredBankCommandDegrees = fixedWingAssistState.commandedBankDegrees
            }
            fixedWingAssistState.activeGuidanceTargetType = fixedWingAssistState.activeGuidanceMode == "none"
                ? "singlePointIntercept"
                : fixedWingAssistState.activeGuidanceMode
        } else {
            applyFixedWingAssistGeometryDiagnostics(geometryAssessment)
            clearFixedWingAssistTurnTransitionDiagnostics(&fixedWingAssistState)
            fixedWingAssistState.activeGuidanceTargetType = "none"
        }
    }

    private func applyFixedWingAssistGeometryDiagnostics(
        _ assessment: FixedWingAssistGeometryAssessment?
    ) {
        guard let assessment else {
            fixedWingAssistState.distanceToActiveWaypointMeters = nil
            fixedWingAssistState.interceptFeasibilityState = nil
            fixedWingAssistState.headingErrorDegrees = nil
            fixedWingAssistState.rawHeadingErrorDegrees = nil
            fixedWingAssistState.estimatedTurnRadiusMeters = nil
            fixedWingAssistState.commandedBankDegrees = nil
            fixedWingAssistState.filteredBankCommandDegrees = nil
            fixedWingAssistState.commandedTurnDirection = .none
            fixedWingAssistState.usingObsoleteFixedWingMode = false
            return
        }

        fixedWingAssistState.distanceToActiveWaypointMeters = assessment.distanceToWaypoint
        fixedWingAssistState.interceptFeasibilityState = assessment.feasibilityState
        fixedWingAssistState.headingErrorDegrees = assessment.headingErrorRadians.radiansToDegrees
        fixedWingAssistState.rawHeadingErrorDegrees = assessment.headingErrorRadians.radiansToDegrees
        fixedWingAssistState.estimatedTurnRadiusMeters = assessment.estimatedTurnRadius
        fixedWingAssistState.commandedBankDegrees = assessment.commandedBankDegrees
        fixedWingAssistState.filteredBankCommandDegrees = assessment.commandedBankDegrees
        fixedWingAssistState.commandedTurnDirection = assessment.commandedTurnDirection
        fixedWingAssistState.usingObsoleteFixedWingMode = false
    }

    private func resetFixedWingAutopilotCommands() {
        fixedWingAutopilotController.reset()
        fixedWingLaunchController.reset()
        fixedWingMissionStateArbiter.reset()
        fixedWingAutopilotAltitudeCommand = nil
        fixedWingAutopilotCourseCommand = nil
        launchState = .idle
        launchStateElapsed = 0.0
        launchRuntimeSnapshot = .idle
        activeFixedWingLaunchDynamics = nil
        fixedWingLaunchReleaseElapsed = 0.0
        activeLaunchCorridor = nil
        // Deliberately NOT deactivating the hand-launch POV here: this reset
        // runs at the start of every takeoff (via target-marker cancellation)
        // and the first-person aim must survive into the launch sequence.
        // The POV is owned by the cradle-hold/launch-release transitions.
        sceneController.updateLaunchAssetPresentation(progress: 0.0, state: .idle)
        fixedWingLastTransitionReason = nil
        fixedWingAutopilotDebugState = .idle
        fixedWingMissionArbiterDecision = .nominal
        fixedWingBatteryWarningLevel = .nominal
        activeFixedWingGuidanceSource = .none
        resetFixedWingRuntimeRouteStart()
    }

    private func resetFixedWingRuntimeRouteStart() {
        fixedWingRuntimeRouteStartKey = nil
        fixedWingRuntimeRouteStartPosition = nil
        fixedWingGuidanceDeferredThroughTick = simulationTickCounter
        // A waypoint handoff changes only the runtime join anchor. The static
        // mission route, safe route and obstacle-grid caches remain valid.
        // Clearing all of them here caused synchronous full-route/A* rebuilds
        // in the exact frame where the active waypoint changed.
        fixedWingFlyablePathCacheKey = nil
        fixedWingFlyablePathCacheRoute = nil
        invalidateFixedWingRouteTrackingContextCache()
    }

    private func invalidateFixedWingRouteCaches() {
        fixedWingFlyByPlanCacheKey = nil
        fixedWingFlyByPlanCache = nil
        fixedWingFlyByRoutePlanCacheKey = nil
        fixedWingFlyByRoutePlanCache = nil
        fixedWingFlyablePathCacheKey = nil
        fixedWingFlyablePathCacheRoute = nil
        fixedWingSafeRouteCacheKey = nil
        fixedWingSafeRouteCacheRoute = nil
        fixedWingSafeRouteCacheStoresNil = false
        invalidateFixedWingRouteTrackingContextCache()
    }

    private func fixedWingRuntimeRouteStart(
        routeKey: String,
        targetAltitude: Float
    ) -> SIMD3<Float> {
        if fixedWingRuntimeRouteStartKey != routeKey ||
            fixedWingRuntimeRouteStartPosition == nil {
            fixedWingRuntimeRouteStartKey = routeKey
            fixedWingRuntimeRouteStartPosition = SIMD3<Float>(
                state.position.x,
                targetAltitude,
                state.position.z
            )
        }

        return fixedWingRuntimeRouteStartPosition ?? SIMD3<Float>(
            state.position.x,
            targetAltitude,
            state.position.z
        )
    }

    private func fixedWingRuntimeRouteStartWaypoint(
        routeKey: String,
        targetAltitude: Float
    ) -> FixedWingRouteWaypoint {
        FixedWingRouteWaypoint(
            position: fixedWingRuntimeRouteStart(
                routeKey: routeKey,
                targetAltitude: targetAltitude
            ),
            missionWaypointIndex: nil,
            waypointIdentifier: fixedWingRuntimeRouteStartIdentifier
        )
    }

    private func fixedWingAssistRuntimeStart(
        selectedWaypointID: UUID,
        activeWaypointIndex: Int
    ) -> SIMD2<Float> {
        let routeKey = "assist:\(selectedWaypointID.uuidString):active:\(activeWaypointIndex)"
        let start = fixedWingRuntimeRouteStart(
            routeKey: routeKey,
            targetAltitude: max(0.0, state.position.y)
        )
        return SIMD2<Float>(start.x, start.z)
    }

    private func fixedWingMissionRuntimeWaypoints(
        from routeWaypoints: [FixedWingRouteWaypoint],
        routeKey: String,
        activeWaypointIndex: Int,
        targetAltitude: Float
    ) -> [FixedWingRouteWaypoint] {
        guard routeWaypoints.count >= 2 else {
            return routeWaypoints
        }

        let activeRouteIndex: Int = {
            if let previousMissionRouteIndex = routeWaypoints.indices.last(where: { index in
                routeWaypoints[index].missionWaypointIndex.map { $0 < activeWaypointIndex } ?? false
            }) {
                return min(previousMissionRouteIndex + 1, routeWaypoints.count - 1)
            }
            if selectedDroneProfile.airframeClass == .hybridVTOL,
               routeWaypoints[0].missionWaypointIndex != nil {
                return 0
            }
            return min(1, routeWaypoints.count - 1)
        }()

        let runtimeStart = fixedWingRuntimeRouteStartWaypoint(
            routeKey: routeKey,
            targetAltitude: targetAltitude
        )
        return [runtimeStart] + Array(routeWaypoints[activeRouteIndex...])
    }

    private func fixedWingRuntimeWaypoints(
        replacingStartOf routeWaypoints: [FixedWingRouteWaypoint],
        routeKey: String,
        targetAltitude: Float
    ) -> [FixedWingRouteWaypoint] {
        guard !routeWaypoints.isEmpty else {
            return routeWaypoints
        }

        var runtimeWaypoints = routeWaypoints
        runtimeWaypoints[0] = fixedWingRuntimeRouteStartWaypoint(
            routeKey: routeKey,
            targetAltitude: targetAltitude
        )
        return runtimeWaypoints
    }

    private func currentFixedWingRouteTrackingContext(
        fallbackTarget: SIMD3<Float>? = nil
    ) -> FixedWingRouteTrackingContext? {
        guard selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL else {
            return nil
        }

        // Per-tick memoisation: the same tick can request the route tracking
        // context multiple times (lateral guidance + navigation snapshot).
        // Without this cache we would rebuild runtime waypoints, hash the
        // route key, and walk the mission plan twice every frame, which is
        // measurable on 256-meter maps with long routes.
        if let cachedTick = fixedWingRouteTrackingContextCacheTick,
           cachedTick == simulationTickCounter,
           sameFallbackTarget(fixedWingRouteTrackingContextCacheFallback, fallbackTarget) {
            return fixedWingRouteTrackingContextCacheValue
        }

        let value = computeFixedWingRouteTrackingContext(fallbackTarget: fallbackTarget)
        fixedWingRouteTrackingContextCacheTick = simulationTickCounter
        fixedWingRouteTrackingContextCacheFallback = fallbackTarget
        fixedWingRouteTrackingContextCacheValue = value
        return value
    }

    private func sameFallbackTarget(
        _ lhs: SIMD3<Float>?,
        _ rhs: SIMD3<Float>?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(a), .some(b)):
            return a.x == b.x && a.y == b.y && a.z == b.z
        default:
            return false
        }
    }

    private func fixedWingDirectRouteTrackingContext(
        prefix: String,
        target: SIMD3<Float>,
        targetAltitude: Float,
        wing: FixedWingParameters,
        targetWaypointIdentifier: String?,
        targetMissionWaypointIndex: Int?
    ) -> FixedWingRouteTrackingContext {
        let activeNoFlyZones = activeNoFlyZonesForNavigation()
        let routeSeed = "\(prefix):nofly:\(fixedWingNoFlyZoneSignature(activeNoFlyZones)):obstacles:\(fixedWingObstacleSignature())"
        let routeStart = fixedWingRuntimeRouteStart(
            routeKey: routeSeed,
            targetAltitude: targetAltitude
        )
        let startPlanar = SIMD2<Float>(routeStart.x, routeStart.z)
        let targetPlanar = SIMD2<Float>(target.x, target.z)
        let routePoints: [SIMD2<Float>]

        if let safeRoute = safeFixedWingRoute(
            from: [startPlanar, targetPlanar],
            zones: activeNoFlyZones,
            viewport: currentTacticalMapViewport(),
            targetAltitude: targetAltitude
        ) {
            routePoints = safeRoute.points
        } else if !navigationObstacles(including: activeNoFlyZones).isEmpty {
            return FixedWingRouteTrackingContext(
                routeIdentifier: "\(routeSeed):blocked",
                waypoints: [],
                minimumWaypointIndex: nil,
                preferredLoiterCenter: nil,
                preferredLoiterRadius: nil,
                flyableRoute: nil
            )
        } else {
            routePoints = compactedPlanarPath([startPlanar, targetPlanar])
        }

        let compactedRoutePoints = compactedPlanarPath(routePoints)
        guard compactedRoutePoints.count >= 2 else {
            return FixedWingRouteTrackingContext(
                routeIdentifier: "\(routeSeed):empty",
                waypoints: [],
                minimumWaypointIndex: nil,
                preferredLoiterCenter: nil,
                preferredLoiterRadius: nil,
                flyableRoute: nil
            )
        }

        let finalIndex = compactedRoutePoints.count - 1
        let routeWaypoints = compactedRoutePoints.enumerated().map { index, point in
            FixedWingRouteWaypoint(
                position: SIMD3<Float>(point.x, targetAltitude, point.y),
                missionWaypointIndex: index == finalIndex ? targetMissionWaypointIndex : nil,
                waypointIdentifier: index == finalIndex ? targetWaypointIdentifier : nil
            )
        }
        let routeIdentifier = fixedWingRouteIdentifier(
            prefix: routeSeed,
            waypoints: Array(routeWaypoints.dropFirst()).map(\.position)
        )
        let flyableRoute = buildFixedWingFlyableRoute(
            fromRuntimeWaypoints: routeWaypoints,
            routeIdentifier: routeIdentifier,
            wing: wing
        )

        return FixedWingRouteTrackingContext(
            routeIdentifier: routeIdentifier,
            waypoints: routeWaypoints,
            minimumWaypointIndex: 1,
            preferredLoiterCenter: target,
            preferredLoiterRadius: wing.loiterRadiusMeters,
            flyableRoute: flyableRoute
        )
    }

    private func computeFixedWingRouteTrackingContext(
        fallbackTarget: SIMD3<Float>?
    ) -> FixedWingRouteTrackingContext? {
        let targetAltitude = fallbackTarget?.y ?? targetMarkerTravelAltitude()
        let wing = activeFixedWingParameters()

        if activeRouteTargetSource == .mission,
           let currentMissionPlan {
            if selectedDroneProfile.airframeClass == .hybridVTOL,
               let activeTarget = missionExecutionState.activeTarget,
               isFiniteVector2(activeTarget.position) {
                let activeWaypointIndex = missionExecutionState.activeWaypointIndex ?? activeTarget.index
                let activeTargetWorld = SIMD3<Float>(
                    activeTarget.position.x,
                    targetAltitude,
                    activeTarget.position.y
                )
                return fixedWingDirectRouteTrackingContext(
                    prefix: "vtol-mission:\(currentMissionPlan.id.uuidString):active:\(activeWaypointIndex):target:\(activeTarget.id.uuidString)",
                    target: activeTargetWorld,
                    targetAltitude: targetAltitude,
                    wing: wing,
                    targetWaypointIdentifier: activeTarget.waypointID.uuidString,
                    targetMissionWaypointIndex: activeTarget.index
                )
            }
            let missionWaypoints = fixedWingMissionRouteWaypoints(
                from: currentMissionPlan,
                targetAltitude: targetAltitude
            )
            let minimumWaypointIndex = missionExecutionState.activeWaypointIndex
            let activeWaypointIndex = minimumWaypointIndex ?? 0
            let missionRouteKey = "mission:\(currentMissionPlan.id.uuidString):active:\(activeWaypointIndex)"
            let runtimeWaypoints = fixedWingMissionRuntimeWaypoints(
                from: missionWaypoints,
                routeKey: missionRouteKey,
                activeWaypointIndex: activeWaypointIndex,
                targetAltitude: targetAltitude
            )
            if runtimeWaypoints.count >= 2 {
                let flyableRoute = buildFixedWingFlyableRoute(
                    fromRuntimeWaypoints: runtimeWaypoints,
                    routeIdentifier: missionRouteKey,
                    wing: wing
                )
                return FixedWingRouteTrackingContext(
                    routeIdentifier: missionRouteKey,
                    waypoints: runtimeWaypoints,
                    minimumWaypointIndex: 1,
                    preferredLoiterCenter: runtimeWaypoints.last?.position,
                    preferredLoiterRadius: wing.loiterRadiusMeters,
                    flyableRoute: flyableRoute
                )
            }
            if currentMissionPlan.zones.contains(where: { $0.type == .noFlyZone && $0.radius > 0.0 }) {
                return FixedWingRouteTrackingContext(
                    routeIdentifier: missionRouteKey,
                    waypoints: [],
                    minimumWaypointIndex: nil,
                    preferredLoiterCenter: nil,
                    preferredLoiterRadius: nil,
                    flyableRoute: nil
                )
            }
            let directMissionRoute = compactedPlanarPath(
                currentMissionPlan.routePoints.isEmpty
                    ? [currentMissionPlan.startPoint] + currentMissionPlan.executionTargets.map(\.position)
                    : currentMissionPlan.routePoints
            )
            if fixedWingPathNeedsObstacleReroute(
                directMissionRoute,
                obstacles: navigationObstacles(including: []),
                targetAltitude: targetAltitude
            ) {
                return FixedWingRouteTrackingContext(
                    routeIdentifier: missionRouteKey,
                    waypoints: [],
                    minimumWaypointIndex: nil,
                    preferredLoiterCenter: nil,
                    preferredLoiterRadius: nil,
                    flyableRoute: nil
                )
            }
        }

        if navigationSnapshot.waypoints.count >= 2 {
            let fixedWingPathPoints = simplifiedFixedWingRoutePoints(
                navigationSnapshot.waypoints,
                wing: wing
            )
            let plannedWaypoints = fixedWingPathPoints.enumerated().map { index, point in
                FixedWingRouteWaypoint(
                    position: point,
                    missionWaypointIndex: index == fixedWingPathPoints.count - 1 ? 0 : nil,
                    waypointIdentifier: index == fixedWingPathPoints.count - 1 ? targetMarkerState?.id.uuidString : nil
                )
            }
            let routeKey = fixedWingRouteIdentifier(
                prefix: activeFixedWingGuidanceSource.rawValue,
                waypoints: Array(plannedWaypoints.dropFirst()).map(\.position)
            )
            let runtimeWaypoints = fixedWingRuntimeWaypoints(
                replacingStartOf: plannedWaypoints,
                routeKey: routeKey,
                targetAltitude: targetAltitude
            )
            let flyableRoute = buildFixedWingFlyableRoute(
                fromRuntimeWaypoints: runtimeWaypoints,
                routeIdentifier: routeKey,
                wing: wing
            )
            return FixedWingRouteTrackingContext(
                routeIdentifier: routeKey,
                waypoints: runtimeWaypoints,
                minimumWaypointIndex: nil,
                preferredLoiterCenter: runtimeWaypoints.last?.position,
                preferredLoiterRadius: wing.loiterRadiusMeters,
                flyableRoute: flyableRoute
            )
        }

        if let marker = targetMarkerState {
            let markerWorld = marker.worldPosition(altitude: targetAltitude)
            return fixedWingDirectRouteTrackingContext(
                prefix: "marker:\(marker.id.uuidString)",
                target: markerWorld,
                targetAltitude: targetAltitude,
                wing: wing,
                targetWaypointIdentifier: marker.id.uuidString,
                targetMissionWaypointIndex: 0
            )
        }

        if let fallbackTarget {
            let fallbackPrefix = fixedWingRouteIdentifier(
                prefix: "fallback",
                waypoints: [fallbackTarget]
            )
            return fixedWingDirectRouteTrackingContext(
                prefix: fallbackPrefix,
                target: fallbackTarget,
                targetAltitude: targetAltitude,
                wing: wing,
                targetWaypointIdentifier: nil,
                targetMissionWaypointIndex: 0
            )
        }

        return nil
    }

    private func simplifiedFixedWingRoutePoints(
        _ points: [SIMD3<Float>],
        wing: FixedWingParameters
    ) -> [SIMD3<Float>] {
        guard !points.isEmpty else {
            return []
        }

        var deduplicated: [SIMD3<Float>] = [points[0]]
        deduplicated.reserveCapacity(points.count)
        for point in points.dropFirst() {
            if simd_distance(point, deduplicated[deduplicated.count - 1]) > 0.05 {
                deduplicated.append(point)
            }
        }

        guard deduplicated.count > 2 else {
            return deduplicated
        }

        let minSpacing = max(
            wing.waypointAcceptanceRadiusMeters * 0.42,
            wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed) * 0.20
        )
        let cornerThreshold = Float(10.0).degreesToRadians
        var output: [SIMD3<Float>] = [deduplicated[0]]
        output.reserveCapacity(deduplicated.count)

        for index in 1..<(deduplicated.count - 1) {
            let lastKept = output[output.count - 1]
            let current = deduplicated[index]
            let next = deduplicated[index + 1]

            let incoming = SIMD2<Float>(current.x - lastKept.x, current.z - lastKept.z)
            let outgoing = SIMD2<Float>(next.x - current.x, next.z - current.z)
            let incomingLength = simd_length(incoming)
            let outgoingLength = simd_length(outgoing)

            guard incomingLength > 0.001, outgoingLength > 0.001 else {
                continue
            }

            let incomingDirection = incoming / incomingLength
            let outgoingDirection = outgoing / outgoingLength
            let turnAngle = acos(simd_dot(incomingDirection, outgoingDirection).clamped(to: -1.0...1.0))
            let keepAsTurnPoint = turnAngle >= cornerThreshold
            let keepAsSpacingPoint = incomingLength >= minSpacing && outgoingLength >= minSpacing * 0.8

            if keepAsTurnPoint || keepAsSpacingPoint {
                output.append(current)
            }
        }

        if simd_distance(output[output.count - 1], deduplicated[deduplicated.count - 1]) > 0.05 {
            output.append(deduplicated[deduplicated.count - 1])
        }

        return output
    }

    private func fixedWingMissionRouteWaypoints(
        from plan: MissionPlan,
        targetAltitude: Float
    ) -> [FixedWingRouteWaypoint] {
        if let routePlan = fixedWingFlyByRoutePlan(targetAltitude: targetAltitude),
           routePlan.routeWaypoints.count >= 2 {
            return routePlan.routeWaypoints.map { waypoint in
                FixedWingRouteWaypoint(
                    position: SIMD3<Float>(
                        waypoint.position.x,
                        targetAltitude,
                        waypoint.position.z
                    ),
                    missionWaypointIndex: waypoint.missionWaypointIndex,
                    waypointIdentifier: waypoint.waypointIdentifier
                )
            }
        }

        if plan.zones.contains(where: { $0.type == .noFlyZone && $0.radius > 0.0 }) {
            return []
        }

        let fallbackRoutePoints = compactedPlanarPath(
            [plan.startPoint] + plan.executionTargets.map(\.position)
        )
        if fixedWingPathNeedsObstacleReroute(
            fallbackRoutePoints,
            obstacles: navigationObstacles(including: []),
            targetAltitude: targetAltitude
        ) {
            return []
        }

        var fallbackWaypoints: [FixedWingRouteWaypoint] = [
            FixedWingRouteWaypoint(
                position: SIMD3<Float>(plan.startPoint.x, targetAltitude, plan.startPoint.y),
                missionWaypointIndex: nil,
                waypointIdentifier: nil
            )
        ]
        fallbackWaypoints.append(contentsOf: plan.executionTargets.map { target in
            FixedWingRouteWaypoint(
                position: SIMD3<Float>(target.position.x, targetAltitude, target.position.y),
                missionWaypointIndex: target.index,
                waypointIdentifier: target.waypointID.uuidString
            )
        })

        return fallbackWaypoints
    }

    private func fixedWingRouteIdentifier(
        prefix: String,
        waypoints: [SIMD3<Float>]
    ) -> String {
        var hasher = Hasher()
        hasher.combine(prefix)
        hasher.combine(waypoints.count)
        for waypoint in waypoints {
            hasher.combine(Int((waypoint.x * 10.0).rounded()))
            hasher.combine(Int((waypoint.z * 10.0).rounded()))
        }
        return "\(prefix):\(hasher.finalize())"
    }

    private func activeLaunchMode() -> LaunchMode {
        let mode = currentMissionPlan?.launchMode ?? activeLaunchDraft().selectedLaunchMode
        let supportedModes = selectedDroneProfile.supportedLaunchModes
        if mode.isRuntimeImplemented, supportedModes.contains(mode) {
            return mode
        }
        return supportedModes.first(where: { $0.isRuntimeImplemented }) ?? .standard
    }

    private func activeLaunchObject() -> MissionLaunchObject? {
        currentMissionPlan?.launchObject ?? activeLaunchDraft().launchObject
    }

    private func activeLaunchAsset() -> LaunchAsset? {
        guard activeLaunchMode().requiresLaunchObject,
              let launchObject = activeLaunchObject(),
              launchObject.type.launchMode == activeLaunchMode(),
              var asset = launchObject.launchAsset else {
            return nil
        }

        let wing = selectedDroneProfile.fixedWingParameters
        switch asset {
        case .handLaunch(var hand):
            if let wing {
                hand.releaseHeightMeters = wing.handReleaseHeightMeters
            }
            // In the first-person hold the operator aims with the mouse: the
            // effective launch heading (and, within the physical throw range,
            // the launch elevation) is wherever he is currently looking, not
            // what was drafted on the tactical map.
            if isHandLaunchPOVActive {
                hand.headingDegrees = handLaunchPOVHeadingDegrees()
                let lookPitchDegrees = sceneController.handLaunchPOVLookPitchRadians() * 180.0 / .pi
                hand.launchAngleDegrees = lookPitchDegrees.clamped(
                    to: MissionLaunchObjectType.handLaunchPoint.launchAngleRange
                )
            }
            asset = .handLaunch(hand)
        case .catapult(var catapult):
            if let wing {
                catapult.rail.railLengthMeters = wing.catapultRailLengthMeters
            }
            asset = .catapult(catapult)
        }
        return asset
    }

    private func activeLaunchDraft() -> MissionDraft {
        isMissionMapVisible
            ? workingTacticalMissionDraft
            : committedTacticalMissionDraft
    }

    private func activeFixedWingParameters() -> FixedWingParameters {
        let base = selectedDroneProfile.fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
        guard selectedDroneProfile.airframeClass == .fixedWing,
              fixedWingMissionArbiterDecision.conserveEnergy else {
            return base
        }

        return FixedWingParameters(
            family: base.family,
            minSustainableSpeedMps: base.minSustainableSpeedMps,
            cruiseSpeedMps: base.cruiseSpeedMps,
            climbSpeedMps: base.climbSpeedMps,
            stallWarningSpeedMps: base.stallWarningSpeedMps,
            waypointAcceptanceRadiusMeters: base.waypointAcceptanceRadiusMeters,
            nominalTurnRateDegPerSec: base.nominalTurnRateDegPerSec,
            bankResponseGain: base.bankResponseGain,
            climbResponseGain: base.climbResponseGain,
            descentResponseGain: base.descentResponseGain,
            dragFactor: base.dragFactor,
            throttleResponseGain: base.throttleResponseGain,
            turnAuthority: base.turnAuthority,
            maxBankAngleDeg: base.maxBankAngleDeg,
            supportedLaunchModes: base.supportedLaunchModes,
            preferredLaunchMode: base.preferredLaunchMode,
            minSafeAirspeed: base.minSafeAirspeed,
            climbAirspeed: base.climbAirspeed,
            cruiseAirspeed: max(
                base.minSafeAirspeed + 1.0,
                min(base.maxAirspeed, base.cruiseAirspeed * 0.95)
            ),
            maxAirspeed: base.maxAirspeed,
            nominalClimbRateMps: max(0.8, base.nominalClimbRateMps * 0.84),
            nominalSinkRateMps: max(0.8, base.nominalSinkRateMps * 0.90),
            loiterRadiusMeters: base.loiterRadiusMeters,
            maxPitchUpDeg: base.maxPitchUpDeg,
            maxPitchDownDeg: base.maxPitchDownDeg,
            minThrottle: base.minThrottle,
            maxThrottle: base.maxThrottle,
            speedRecoveryPitchCeilingDeg: base.speedRecoveryPitchCeilingDeg,
            takeoffRotationSpeed: base.takeoffRotationSpeed,
            initialClimbPitchDeg: base.initialClimbPitchDeg,
            maxInitialBankDeg: base.maxInitialBankDeg,
            handThrowSpeed: base.handThrowSpeed,
            catapultExitSpeed: base.catapultExitSpeed,
            handLaunchAngleDegrees: base.handLaunchAngleDegrees,
            handReleaseHeightMeters: base.handReleaseHeightMeters,
            catapultRailAngleDegrees: base.catapultRailAngleDegrees,
            catapultRailLengthMeters: base.catapultRailLengthMeters,
            maxCatapultAccelerationG: base.maxCatapultAccelerationG,
            launchPreSpoolSeconds: base.launchPreSpoolSeconds,
            runwayTakeoffDistance: base.runwayTakeoffDistance,
            initialClimbTargetAltitude: base.initialClimbTargetAltitude
        )
    }

    private func currentFixedWingMissionArbiterDecision(
        operationalStatus: MissionOperationalStatus
    ) -> FixedWingMissionArbiterDecision {
        guard selectedDroneProfile.airframeClass == .fixedWing,
              missionExecutionState.isMissionActive ||
                currentMissionPlan != nil ||
                activeRouteTargetSource == .mission else {
            fixedWingMissionStateArbiter.reset()
            return .nominal
        }

        return fixedWingMissionStateArbiter.evaluate(
            batteryState: batteryState,
            operationalStatus: operationalStatus,
            wing: activeFixedWingProfileParameters()
        )
    }

    private func activeFixedWingProfileParameters() -> FixedWingParameters {
        selectedDroneProfile.fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
    }

    private func reconcileFixedWingMissionSafetyState(
        _ safetyState: MissionSafetyState,
        currentPlan: MissionPlan?,
        operationalStatus: MissionOperationalStatus,
        arbiterDecision: FixedWingMissionArbiterDecision
    ) -> MissionSafetyState {
        var nextState = safetyState
        nextState.warnings.removeAll {
            $0.reason == .batteryUnsafe ||
            $0.reason == .noMissionTarget ||
            $0.reason == .noControlAuthority ||
            $0.reason == .authorityFlapDetected
        }

        switch arbiterDecision.batteryLevel {
        case .nominal:
            if nextState.blockReason == .batteryUnsafe {
                nextState.blockReason = nil
            }
        case .advisory:
            nextState.warnings.append(
                MissionWarning(
                    reason: .batteryUnsafe,
                    severity: .warning,
                    detailKey: "mission.status.reason.battery_unsafe"
                )
            )
            if nextState.blockReason == .batteryUnsafe {
                nextState.blockReason = nil
            }
        case .caution:
            nextState.warnings.append(
                MissionWarning(
                    reason: .batteryUnsafe,
                    severity: .warning,
                    detailKey: operationalStatus.canCompleteMissionSafely
                        ? "mission.status.reason.battery_unsafe"
                        : "mission.status.reason.route_exceeds_safe_return"
                )
            )
            if nextState.blockReason == .batteryUnsafe {
                nextState.blockReason = nil
            }
        case .critical:
            nextState.warnings.append(
                MissionWarning(
                    reason: .batteryUnsafe,
                    severity: .critical,
                    detailKey: "mission.status.reason.battery_unsafe"
                )
            )
            nextState.blockReason = .batteryUnsafe
            nextState.abortReason = arbiterDecision.abortReason
        }

        let batteryIsCritical = arbiterDecision.batteryLevel == .critical
        nextState.runtimeConstraints.batterySafeToStart = !batteryIsCritical
        nextState.runtimeConstraints.batterySafeToContinue = !batteryIsCritical
        nextState.runtimeConstraints.returnSafe = batteryIsCritical
            ? operationalStatus.canReachHomeSafely
            : true
        nextState.runtimeConstraints.missionSafe = batteryIsCritical
            ? operationalStatus.canCompleteMissionSafely
            : true

        if !batteryIsCritical,
           missionExecutionState.status == .running,
           activeRouteTargetSource == .mission,
           fixedWingMissionRouteHealthy(debugState: fixedWingAutopilotDebugState) {
            nextState.runtimeConstraints.hasExecutionContour = true
            nextState.runtimeConstraints.hasMissionTarget = true
            nextState.runtimeConstraints.hasRuntimeDistance = true
            nextState.runtimeConstraints.progressHealthy = true
            nextState.runtimeConstraints.adapterHealthy = true
            nextState.runtimeConstraints.targetBindingAvailable = true
            nextState.runtimeConstraints.routeHealthy = true

            switch nextState.blockReason {
            case .noMissionTarget,
                 .noControlAuthority,
                 .runtimeStallDetected,
                 .executionContourMissing,
                 .executionBindingFailed,
                 .runtimeDistanceUnavailable:
                nextState.blockReason = nil
            case .runtimeUnsafe:
                if nextState.runtimeConstraints.signalSafe &&
                    nextState.runtimeConstraints.collisionSafe &&
                    nextState.runtimeConstraints.thermalSafe {
                    nextState.blockReason = nil
                }
            case .none,
                 .noValidatedPlan,
                 .routeInvalid,
                 .batteryUnsafe,
                 .missionStartBlocked:
                break
            }
        }

        if !batteryIsCritical,
           nextState.blockReason == nil,
           let currentPlan,
           currentPlan.isReadyForExecution {
            nextState.readiness = .ready
        }

        if !batteryIsCritical && nextState.abortReason == .batteryUnsafe {
            nextState.abortReason = nil
        }

        nextState.warnings = deduplicatedMissionWarnings(nextState.warnings)
        return nextState
    }

    private func fixedWingMissionRouteHealthy(
        debugState: FixedWingAutopilotDebugState
    ) -> Bool {
        guard let routeIdentifier = debugState.routeIdentifier,
              routeIdentifier.hasPrefix("mission:") else {
            return false
        }
        switch debugState.missionState {
        case .idle, .failed:
            return false
        case .aligningToLaunch,
             .climbout,
             .capturingLeg,
             .trackingLeg,
             .flyByTurn,
             .loitering,
             .completed,
             .recoveringSpeed:
            return true
        }
    }

    private func deduplicatedMissionWarnings(
        _ warnings: [MissionWarning]
    ) -> [MissionWarning] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.severity.priority != rhs.severity.priority {
                    return lhs.severity.priority < rhs.severity.priority
                }
                return lhs.detailKey < rhs.detailKey
            }
    }

    private func normalizeMissionLaunchConfigurationForSelectedProfile() {
        committedTacticalMissionDraft = normalizedLaunchConfiguration(
            for: committedTacticalMissionDraft
        )
        workingTacticalMissionDraft = normalizedLaunchConfiguration(
            for: workingTacticalMissionDraft
        )
    }

    /// Launch equipment is part of the selected airframe configuration, even
    /// when no waypoint mission exists yet. Keeping a default object at the
    /// dock prevents reset/profile selection from silently reverting an
    /// assisted-launch aircraft to an unusable standard draft.
    private func defaultLaunchConfiguredDraft() -> MissionDraft {
        let launchMode = selectedDroneProfile.preferredLaunchMode
        var draft = missionDraftBuilder.setLaunchMode(
            launchMode,
            in: .empty,
            defaultLaunchAngleDegrees: preferredLaunchAngleDegrees(for: launchMode)
        )
        guard launchMode == .handLaunch || launchMode == .catapult,
              selectedDroneProfile.supportedLaunchModes.contains(launchMode),
              let objectType = launchMode.defaultLaunchObjectType else {
            return draft
        }

        let dock = sceneController.currentDockSpawnPoint()
        let forward = SIMD2<Float>(-sin(state.orientation.z), -cos(state.orientation.z))
        let heading = MissionLaunchGeometry.normalizedHeadingDegrees(
            atan2(forward.x, forward.y) * 180.0 / .pi
        )
        let angle = preferredLaunchAngleDegrees(for: launchMode) ?? 0.0
        draft.launchObject = MissionLaunchObject(
            type: objectType,
            position: SIMD2<Float>(dock.x, dock.z),
            headingDegrees: heading,
            railAngleDegrees: angle,
            transitionHeadingDegrees: heading
        )
        return draft
    }

    private func normalizedLaunchConfiguration(
        for draft: MissionDraft
    ) -> MissionDraft {
        let supportedModes = selectedDroneProfile.supportedLaunchModes
        let preferredMode = selectedDroneProfile.preferredLaunchMode
        let resolvedMode = supportedModes.contains(draft.selectedLaunchMode)
            ? draft.selectedLaunchMode
            : preferredMode

        var nextDraft = missionDraftBuilder.setLaunchMode(
            resolvedMode,
            in: draft,
            defaultLaunchAngleDegrees: preferredLaunchAngleDegrees(for: resolvedMode)
        )

        if resolvedMode == .standard {
            return nextDraft
        }

        guard let requiredType = resolvedMode.defaultLaunchObjectType,
              let launchObject = nextDraft.launchObject,
              launchObject.type != requiredType else {
            return nextDraft
        }

        nextDraft.launchObject = MissionLaunchObject(
            id: launchObject.id,
            type: requiredType,
            position: launchObject.position,
            headingDegrees: launchObject.headingDegrees,
            railAngleDegrees: launchObject.railAngleDegrees,
            transitionHeadingDegrees: launchObject.transitionHeadingDegrees
        )
        return nextDraft
    }

    private func shouldDelayFixedWingRouteCaptureDuringLaunch() -> Bool {
        guard selectedDroneProfile.airframeClass == .fixedWing else {
            return false
        }
        let launchMode = activeLaunchMode()
        guard launchMode != .standard else {
            return false
        }
        let wing = activeFixedWingParameters()
        let spawnPoint = currentSpawnPoint()
        let targetAltitude = max(spawnPoint.y + wing.initialClimbTargetAltitude * 0.65, 1.8)
        return physicalState.isGroundRestState || state.position.y < targetAltitude
    }

    private func beginFixedWingLaunchSequence() {
        guard selectedDroneProfile.airframeClass == .fixedWing,
              activeLaunchMode() == .handLaunch || activeLaunchMode() == .catapult else {
            resetFixedWingAutopilotCommands()
            return
        }

        let launchMode = activeLaunchMode()
        guard selectedDroneProfile.supportedLaunchModes.contains(launchMode),
              launchMode.isRuntimeImplemented,
              isArmed,
              !batteryState.isDepleted,
              physicalState != .crashed,
              let launchAsset = activeLaunchAsset(),
              let launchObject = activeLaunchObject(),
              launchObject.type.launchMode == launchMode else {
            abortFixedWingLaunch(reason: "launch_preflight_configuration_failed")
            return
        }

        let launchPreview = missionPreviewBuilder.buildLaunchPreview(
            draft: currentMissionPlan.map { plan in
                MissionDraft(
                    waypoints: activeLaunchDraft().waypoints,
                    zones: activeLaunchDraft().zones,
                    constraints: activeLaunchDraft().constraints,
                    selectedLaunchMode: plan.launchMode,
                    launchObject: plan.launchObject
                )
            } ?? activeLaunchDraft(),
            viewport: currentTacticalMapViewport(),
            fixedWingParameters: selectedDroneProfile.fixedWingParameters,
            supportedLaunchModes: selectedDroneProfile.supportedLaunchModes
        )
        guard launchPreview?.isValid == true else {
            abortFixedWingLaunch(reason: "launch_preflight_corridor_invalid")
            return
        }

        let spawnPoint = currentSpawnPoint()
        let wing = activeFixedWingParameters()
        if let failureReason = fixedWingLaunchPreflightFailure(
            mode: launchMode,
            asset: launchAsset,
            spawnPoint: spawnPoint,
            parameters: wing
        ) {
            abortFixedWingLaunch(reason: failureReason)
            return
        }
        let spawnYaw = launchAsset.worldYawRadians
        let spawnPitch = launchAsset.railAngleDegrees.degreesToRadians

        fixedWingAutopilotController.reset()
        fixedWingLaunchController.reset()
        guard fixedWingLaunchController.begin(
            mode: activeLaunchMode(),
            asset: launchAsset,
            origin: spawnPoint,
            wing: wing,
            nominalLaunchMassKg: selectedDroneProfile.takeoffMassKg
        ) else {
            abortFixedWingLaunch(reason: "launch_controller_rejected_configuration")
            return
        }
        // The launch state machine now owns the airframe: its `.held` dynamics
        // phase pins the aircraft, so the idle cradle hold must let go.
        launchCradleHoldActive = false
        fixedWingLaunchReleaseElapsed = 0.0
        activeLaunchCorridor = (
            origin: spawnPoint,
            horizontal: launchAsset.horizontalDirection,
            releaseAttitudeDegrees: launchAsset.railAngleDegrees +
                (launchMode == .handLaunch
                    ? FixedWingHandLaunchTuning.releaseAngleOfAttackDegrees
                    : 0.0)
        )
        launchRuntimeSnapshot = FixedWingLaunchRuntimeSnapshot(
            mode: launchMode,
            state: .prelaunchCheck,
            railProgress: 0.0,
            longitudinalAirspeedMps: 0.0,
            altitudeAboveLaunchMeters: 0.0,
            transitionReason: "launch_preflight_started",
            dynamics: nil
        )
        fixedWingAutopilotAltitudeCommand = spawnPoint.y
        fixedWingAutopilotCourseCommand = spawnYaw
        homePosition = spawnPoint
        state.position = spawnPoint
        state.velocity = .zero
        state.orientation.x = 0.0
        state.orientation.y = spawnPitch
        state.orientation.z = spawnYaw
        resyncFixedWingAttitudeFromEuler()
        transitionPhysicalState(.takeoffTransition)
        lastFiniteState = state
        updateLegacyLaunchState(.prelaunchCheck)
        refreshSceneLaunchAsset()
        sceneController.updateLaunchAssetPresentation(progress: 0.0, state: .prelaunchCheck)
        updateControlValues({ values in
            values.x = Double(spawnPoint.x)
            values.y = Double(spawnPoint.y)
            values.z = Double(spawnPoint.z)
            values.roll = 0.0
            values.pitch = Double(spawnPitch.radiansToDegrees)
            values.yaw = Double(spawnYaw.radiansToDegrees)
            values.throttle = max(
                values.throttle,
                Double(resolvedFlightBaseline(for: .takeoff).takeoffThrottleReference)
            )
        }, markManual: false)
    }

    private func abortFixedWingLaunch(reason: String) {
        fixedWingLaunchController.reset()
        activeFixedWingLaunchDynamics = nil
        launchRuntimeSnapshot = FixedWingLaunchRuntimeSnapshot(
            mode: activeLaunchMode(),
            state: .aborted,
            railProgress: 0.0,
            longitudinalAirspeedMps: 0.0,
            altitudeAboveLaunchMeters: 0.0,
            transitionReason: reason,
            dynamics: nil
        )
        updateLegacyLaunchState(.aborted)
        fixedWingLastTransitionReason = reason
        sceneController.updateLaunchAssetPresentation(progress: 0.0, state: .aborted)
        // A pre-release abort leaves the airframe physically on the launcher —
        // keep it seated there instead of letting it drop through the model.
        if let cradlePoint = launchCradlePoint(),
           simd_distance(state.position, cradlePoint) < 2.0 {
            launchCradleHoldActive = true
        }
    }

    private func launchCradlePoint() -> SIMD3<Float>? {
        guard selectedDroneProfile.airframeClass == .fixedWing,
              activeLaunchMode().requiresLaunchObject,
              let asset = activeLaunchAsset() else {
            return nil
        }
        return sceneController.currentLaunchSpawnPoint(for: asset)
    }

    /// Enters/leaves the first-person hand-launch view. Activation is
    /// idempotent and re-called every held tick so the eye position tracks
    /// the launch point; the scene keeps its look angles across calls.
    private func setHandLaunchPOVActive(_ active: Bool) {
        if active {
            guard canControlLocalVehicle, !isSpectatorMode else {
                return
            }
            let initialYaw = activeLaunchAsset()?.worldYawRadians ?? state.orientation.z
            let initialPitch = (activeLaunchAsset()?.railAngleDegrees ?? 8.0).degreesToRadians
            sceneController.activateHandLaunchPOV(
                initialYawRadians: initialYaw,
                initialPitchRadians: initialPitch
            )
            if !isHandLaunchPOVActive, sceneController.isHandLaunchPOVActive {
                isHandLaunchPOVActive = true
            }
        } else {
            sceneController.deactivateHandLaunchPOV()
            if isHandLaunchPOVActive {
                isHandLaunchPOVActive = false
            }
        }
    }

    /// First-person walking while holding the airframe: WASD moves the
    /// operator (look-relative), Shift jogs. Only while the launch sequence
    /// has not taken over the airframe.
    private func updateHandLaunchPOVWalk(deltaTime: Float) {
        guard isHandLaunchPOVActive,
              launchRuntimeSnapshot.state == .idle ||
                launchRuntimeSnapshot.state == .aborted,
              !signalState.isInteractionBlocking else {
            return
        }
        let axis = keyboardInputService.currentInputSnapshot().axisInput
        guard abs(axis.forward) > 0.02 || abs(axis.strafe) > 0.02 else {
            return
        }
        sceneController.moveHandLaunchPOVOperator(
            forward: axis.forward,
            strafe: axis.strafe,
            deltaTime: deltaTime,
            speed: axis.speedBoost ? 3.4 : 1.7,
            worldHalfExtent: terrain.worldHalfExtent
        )
    }

    /// Compass heading (map convention: 0° = +Z, 90° = +X) of the operator's
    /// current first-person look direction.
    private func handLaunchPOVHeadingDegrees() -> Float {
        let yaw = sceneController.handLaunchPOVWorldYawRadians()
        return MissionLaunchGeometry.normalizedHeadingDegrees(
            atan2(-sin(yaw), -cos(yaw)) * 180.0 / .pi
        )
    }

    /// Places the idle airframe into its launch cradle (catapult shuttle or
    /// operator's hand) with the launcher's own heading and pitch. Returns
    /// false when the selected aircraft has no assisted-launch equipment.
    @discardableResult
    private func seatAircraftInLaunchCradleIfAvailable() -> Bool {
        guard let asset = activeLaunchAsset(),
              let cradlePoint = launchCradlePoint() else {
            launchCradleHoldActive = false
            setHandLaunchPOVActive(false)
            return false
        }
        state.position = cradlePoint
        state.velocity = .zero
        state.angularVelocity = .zero
        state.orientation = SIMD3<Float>(
            0.0,
            asset.railAngleDegrees.degreesToRadians,
            asset.worldYawRadians
        )
        resyncFixedWingAttitudeFromEuler()
        homePosition = cradlePoint
        lastFiniteState = state
        launchCradleHoldActive = true
        return true
    }

    /// Per-tick enforcement of the pre-launch cradle hold. The physics step
    /// has already integrated gravity for this tick, so the hold re-pins the
    /// airframe every frame until the launch state machine (or a cleared
    /// launch configuration) releases it.
    private func maintainLaunchCradleHoldIfNeeded() -> Bool {
        guard launchCradleHoldActive else {
            return false
        }
        guard physicalState != .crashed,
              launchRuntimeSnapshot.state == .idle ||
                launchRuntimeSnapshot.state == .aborted,
              activeLaunchAsset() != nil else {
            launchCradleHoldActive = false
            setHandLaunchPOVActive(false)
            return false
        }

        // While the hand-launch airframe is in its pre-launch hold, the whole
        // experience is first-person — armed or not, the operator stands with
        // the aircraft in hand from the moment the platform is selected. The
        // catapult keeps its external view.
        if activeLaunchMode() == .handLaunch {
            setHandLaunchPOVActive(true)
        } else {
            setHandLaunchPOVActive(false)
        }

        // Re-resolve after the POV update: with the first-person view active
        // the asset heading (and therefore the hold point) follows the
        // operator's look direction.
        guard let asset = activeLaunchAsset(),
              let cradlePoint = launchCradlePoint() else {
            launchCradleHoldActive = false
            setHandLaunchPOVActive(false)
            return false
        }

        state.position = cradlePoint
        state.velocity = .zero
        state.angularVelocity = .zero
        state.bodyAngularVelocity = .zero
        state.forwardAirspeed = simd_length(weather.windVector)
        state.orientation = SIMD3<Float>(
            0.0,
            asset.railAngleDegrees.degreesToRadians,
            asset.worldYawRadians
        )
        resyncFixedWingAttitudeFromEuler()
        transitionPhysicalState(isArmed ? .armedOnGround : .disarmed)
        if !isArmed {
            state.throttle = 0.0
            state.motorThrottle = 0.0
            state.rotorAngularSpeed = .zero
        }
        return true
    }

    private func fixedWingLaunchPreflightFailure(
        mode: LaunchMode,
        asset: LaunchAsset,
        spawnPoint: SIMD3<Float>,
        parameters wing: FixedWingParameters
    ) -> String? {
        let currentMass = max(0.2, vehicleMassModel.resolvedCurrentTotalMass)
        let nominalMass = max(0.2, selectedDroneProfile.takeoffMassKg)
        guard currentMass <= nominalMass * 1.12 else {
            return "launch_preflight_mass_exceeded"
        }

        let direction = simd_normalize(asset.direction3D)
        let nominalReleaseSpeed: Float
        if mode == .handLaunch {
            nominalReleaseSpeed = wing.handThrowSpeed *
                sqrt(nominalMass / currentMass).clamped(to: 0.65...1.15)
        } else {
            let availableAcceleration = wing.maxCatapultAccelerationG * 9.81 *
                nominalMass / currentMass
            let forceLimitedExitSpeed = sqrt(
                max(0.0, 2.0 * availableAcceleration * wing.catapultRailLengthMeters)
            )
            nominalReleaseSpeed = min(wing.catapultExitSpeed, forceLimitedExitSpeed)
        }
        let longitudinalWind = simd_dot(weather.windVector, direction)
        let predictedLongitudinalAirspeed = nominalReleaseSpeed - longitudinalWind
        let crosswind = simd_length(weather.windVector - direction * longitudinalWind)
        // The airframe must leave the launcher flying, not stalling: predicted
        // airspeed at release (throw/exit speed corrected for the along-track
        // wind) has to retain the mode-specific margin above minSafeAirspeed,
        // or the launch is refused as a tailwind/overweight configuration
        // instead of being allowed to mush into the ground after release.
        let minimumReleaseEnergy = wing.minSafeAirspeed * (mode == .handLaunch
            ? FixedWingHandLaunchTuning.minimumReleaseAirspeedFactor
            : 1.02)
        guard predictedLongitudinalAirspeed >= minimumReleaseEnergy else {
            return "launch_preflight_tailwind_unsafe"
        }
        let crosswindLimit = min(
            selectedDroneProfile.maxWindResistanceMps,
            max(3.0, nominalReleaseSpeed * 0.45)
        )
        guard crosswind <= crosswindLimit else {
            return "launch_preflight_crosswind_unsafe"
        }

        let corridorLength = wing.corridorLength(for: mode)
        let railSkip = mode == .catapult ? wing.catapultRailLengthMeters : 0.4
        let clearanceStart = spawnPoint + direction * min(railSkip, corridorLength * 0.45)
        let clearanceEnd = spawnPoint + direction * corridorLength
        guard clearanceEnd.y <= terrain.maxFlightAltitude - selectedDroneProfile.collisionRadius else {
            return "launch_preflight_vertical_clearance_invalid"
        }
        let obstacles = sceneController.nearbyEnvironmentObstacles(
            from: clearanceStart,
            to: clearanceEnd,
            margin: selectedDroneProfile.collisionRadius + 0.8
        )
        if let collision = collisionService.firstSweptCollision(
            from: clearanceStart,
            to: clearanceEnd,
            droneRadius: selectedDroneProfile.collisionRadius,
            obstacles: obstacles
        ), !collision.isSupportSurfaceContact {
            return "launch_preflight_corridor_obstructed"
        }
        return nil
    }

    private func launchHeadingRadians(for launchObject: MissionLaunchObject) -> Float {
        launchObject.worldYawRadians
    }

    private func updateLegacyLaunchState(_ nextState: LaunchState, deltaTime: Float = 0.0) {
        if launchState == nextState {
            launchStateElapsed += deltaTime
        } else {
            launchState = nextState
            launchStateElapsed = 0.0
        }
    }

    private func legacyLaunchState(
        for output: FixedWingAutopilotOutput,
        launchMode: LaunchMode
    ) -> LaunchState {
        switch output.launchPhase {
        case .onRail:
            return output.phase == .launchClimb ? .aligning : .prelaunchCheck
        case .launchImpulse:
            return .assistedAcceleration
        case .railRelease:
            return .rotation
        case .initialClimb:
            return .initialClimb
        case .missionJoin:
            return .transitionToFlight
        case .none:
            return launchMode == .vtol ? .transitionToFlight : .completed
        }
    }

    private func launchSequenceTarget(
        for asset: LaunchAsset?,
        launchMode: LaunchMode,
        parameters wing: FixedWingParameters
    ) -> SIMD3<Float> {
        // The corridor frozen at launch begin is authoritative: the live
        // asset heading follows the (possibly re-aimed / reverted-to-draft)
        // launch object and must not steer the climb-out after release.
        let origin = activeLaunchCorridor?.origin ?? currentSpawnPoint()
        let horizontalDirection: SIMD2<Float> = activeLaunchCorridor?.horizontal ??
            asset?.horizontalDirection ??
            activeLaunchObject()?.horizontalLaunchDirection ??
            SIMD2<Float>(-sin(state.orientation.z), -cos(state.orientation.z))

        let baseDistance: Float = {
            switch launchMode {
            case .catapult:
                return max(wing.catapultExitSpeed * 1.6, 16.0)
            case .handLaunch:
                return max(wing.handThrowSpeed * 1.8, 12.0)
            case .runway:
                return max(wing.takeoffRotationSpeed * 1.2, 20.0)
            case .vtol:
                return max(wing.initialClimbTargetAltitude * 0.45, 8.0)
            case .standard:
                return max(wing.cruiseAirspeed, 10.0)
            }
        }()

        // The climb-out point must recede ahead of the aircraft: a fixed
        // corridor end (~25-30 m) is overflown within seconds, and chasing a
        // waypoint behind the aircraft bends the whole launch into a circle.
        let alongTrack = simd_dot(
            SIMD2<Float>(state.position.x - origin.x, state.position.z - origin.z),
            horizontalDirection
        )
        let lookahead = max(
            45.0,
            wing.guidanceLookaheadDistance(airspeed: state.forwardAirspeed)
        )
        let distance = max(baseDistance, alongTrack + lookahead)

        return SIMD3<Float>(
            origin.x + horizontalDirection.x * distance,
            max(origin.y + wing.initialClimbTargetAltitude, wing.initialClimbTargetAltitude),
            origin.z + horizontalDirection.y * distance
        )
    }

    private func updateFixedWingLaunchSequence(deltaTime: Float) {
        guard selectedDroneProfile.airframeClass == .fixedWing else {
            return
        }

        let launchMode = activeLaunchMode()
        guard launchMode == .handLaunch || launchMode == .catapult else {
            return
        }

        let wing = activeFixedWingParameters()
        if launchState == .aborted || launchRuntimeSnapshot.state == .aborted {
            activeFixedWingLaunchDynamics = nil
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = 0.0
            }, markManual: false)
            setFlightMode(.manual, reason: "fixed_wing_launch_aborted")
            return
        }
        if launchState == .idle {
            beginFixedWingLaunchSequence()
            if launchState == .aborted {
                activeFixedWingLaunchDynamics = nil
                updateControlValues({ values in
                    values.roll = 0.0
                    values.pitch = 0.0
                    values.throttle = 0.0
                }, markManual: false)
                setFlightMode(.manual, reason: "fixed_wing_launch_aborted")
                return
            }
        }

        launchRuntimeSnapshot = fixedWingLaunchController.update(
            aircraftState: state,
            windVector: weather.windVector,
            isArmed: isArmed,
            batteryAvailable: !batteryState.isDepleted,
            deltaTime: deltaTime
        )
        updateLegacyLaunchState(launchRuntimeSnapshot.state, deltaTime: deltaTime)
        activeFixedWingLaunchDynamics = launchRuntimeSnapshot.dynamics
        fixedWingLastTransitionReason = launchRuntimeSnapshot.transitionReason
        sceneController.updateLaunchAssetPresentation(
            progress: launchRuntimeSnapshot.railProgress,
            state: launchRuntimeSnapshot.state
        )

        switch launchRuntimeSnapshot.state {
        case .idle:
            return
        case .prelaunchCheck, .aligning, .launchCommit, .assistedAcceleration:
            fixedWingLaunchReleaseElapsed = 0.0
            let yaw = activeLaunchAsset()?.worldYawRadians ?? state.orientation.z
            let pitch = activeLaunchAsset()?.railAngleDegrees ?? 0.0
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = Double(pitch)
                values.yaw = Double(yaw.radiansToDegrees)
                values.throttle = max(
                    values.throttle,
                    Double(resolvedFlightBaseline(for: .takeoff).takeoffThrottleReference)
                )
            }, markManual: false)
            return
        case .aborted:
            activeFixedWingLaunchDynamics = nil
            // A released-then-failed launch leaves the airframe away from the
            // cradle; the first-person view must not stay latched to it.
            if !launchCradleHoldActive {
                setHandLaunchPOVActive(false)
            }
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = 0.0
            }, markManual: false)
            setFlightMode(.manual, reason: "fixed_wing_launch_aborted")
            return
        case .completed:
            activeFixedWingLaunchDynamics = nil
            setHandLaunchPOVActive(false)
            if missionExecutionState.status == .running,
               let activeTarget = missionExecutionState.activeTarget,
               activeRouteTargetSource == .mission {
                // The runtime monitor has been ticking (with no progress recorded)
                // since the mission started, through the whole pre-launch hold and
                // launch corridor — reset it here, same as every other mission
                // (re)engagement call site (startMissionExecution, resumeMissionExecution,
                // the auto-resume path). Without this, `lastProgressAt` is already
                // stale the instant autoPath engages, so the very first runtime-monitor
                // evaluation reads as an immediate stall and the failsafe drops the
                // aircraft to a manual course-hold with no active altitude correction —
                // the "autopilot only works after pause/resume, otherwise it slowly
                // sinks" symptom.
                missionRuntimeMonitor.reset()
                bindMissionExecutionTarget(activeTarget, startNavigation: true)
                setFlightMode(.autoPath, reason: "fixed_wing_launch_joined_mission")
            } else {
                setFlightMode(.manual, reason: "fixed_wing_launch_completed")
            }
            return
        case .rotation, .initialClimb, .transitionToFlight:
            // Let the operator watch the airframe leave his hand for a
            // moment, then hand the screen back to the regular UAV cameras.
            fixedWingLaunchReleaseElapsed += deltaTime
            if fixedWingLaunchReleaseElapsed >= 0.7 {
                setHandLaunchPOVActive(false)
            }
        }

        let target = launchSequenceTarget(
            for: activeLaunchAsset(),
            launchMode: launchMode,
            parameters: wing
        )
        let context = AutopilotTrackingContext(
            state: state,
            physicalState: physicalState,
            target: target,
            targetAltitude: target.y,
            speedScale: 1.0,
            yawAlignToHome: false,
            yawOverrideRadians: nil,
            deltaTime: deltaTime,
            flightBaseline: resolvedFlightBaseline(for: .takeoff)
        )
        let output = fixedWingAutopilotController.trackingCommand(
            for: context,
            parameters: wing,
            launchMode: .standard,
            launchAsset: nil,
            routeTracking: FixedWingRouteTrackingContext(
                routeIdentifier: "launch:\(activeLaunchObject()?.id.uuidString ?? selectedDroneProfile.id)",
                waypoints: [
                    FixedWingRouteWaypoint(
                        position: target,
                        missionWaypointIndex: nil,
                        waypointIdentifier: "fixed-wing-launch-corridor"
                    )
                ]
            )
        )

        var protectedCommand = output.command
        let maxBank = launchRuntimeSnapshot.state == .transitionToFlight
            ? wing.maxInitialBankDeg
            : max(2.0, wing.maxInitialBankDeg * 0.45)
        // The corridor's own route-tracking roll only holds the airframe on
        // the launch heading; it never reflects the stick, so any manual
        // roll input was being silently discarded for the whole climb-out
        // (several seconds on some airframes) — the aircraft simply could
        // not be steered left/right after a hand throw or catapult shot.
        // Let a live stick command through immediately, still bounded by the
        // same reduced-bank safety envelope used for the corridor hold.
        protectedCommand.rollDegrees = fixedWingManualTurnInputActive
            ? fixedWingManualRollCommandDegrees.clamped(to: -maxBank...maxBank)
            : protectedCommand.rollDegrees.clamped(to: -maxBank...maxBank)
        if launchMode == .handLaunch,
           fixedWingLaunchReleaseElapsed < FixedWingHandLaunchTuning.releaseAttitudeHoldSeconds,
           let releaseAttitudeDegrees = activeLaunchCorridor?.releaseAttitudeDegrees {
            // The throw leaves the hand with a working angle of attack. The
            // route controller's first transient command can be near-level;
            // applying it immediately unloads the wing before its pitch loop
            // has settled. Preserve the actual release attitude briefly, then
            // hand over continuously to the normal aerodynamic controller.
            protectedCommand.pitchDegrees = releaseAttitudeDegrees.clamped(
                to: 1.0...max(wing.initialClimbPitchDeg, wing.maxPitchUpDeg)
            )
        } else if launchRuntimeSnapshot.state == .rotation,
           launchRuntimeSnapshot.longitudinalAirspeedMps < wing.minSafeAirspeed * 0.86 {
            protectedCommand.pitchDegrees = protectedCommand.pitchDegrees.clamped(to: -1.0...3.0)
        } else {
            // Ceiling at maxPitchUpDeg, not initialClimbPitchDeg: right after
            // a hand throw the airframe flies barely above minSafeAirspeed,
            // where holding altitude alone already needs most of the
            // initial-climb pitch as angle of attack — clamping to it left
            // no margin to actually climb (observed as a ground-skimming
            // launch that only rose after the manual handoff).
            protectedCommand.pitchDegrees = protectedCommand.pitchDegrees.clamped(
                to: 1.0...max(wing.initialClimbPitchDeg, wing.maxPitchUpDeg)
            )
        }
        protectedCommand.throttle = max(protectedCommand.throttle, wing.maxThrottle * 0.92)

        fixedWingAutopilotAltitudeCommand = output.command.positionTarget.y
        fixedWingAutopilotCourseCommand = protectedCommand.yawDegrees.degreesToRadians
        fixedWingAutopilotDebugState = output.debugState
        applyAutopilotCommand(protectedCommand, deltaTime: deltaTime)
    }

    private func refreshFixedWingLaunchPresentation() {
        guard activeLaunchMode() == .handLaunch || activeLaunchMode() == .catapult else {
            return
        }

        let progress: Float
        if let dynamics = activeFixedWingLaunchDynamics,
           dynamics.phase == .catapultRail {
            progress = (simd_dot(state.position - dynamics.origin, dynamics.direction) /
                max(0.1, dynamics.travelLengthMeters)).clamped(to: 0.0...1.0)
        } else {
            progress = launchRuntimeSnapshot.railProgress
        }
        sceneController.updateLaunchAssetPresentation(progress: progress, state: launchState)
    }

    private func polylineLength(_ points: [SIMD2<Float>]) -> Float {
        guard points.count > 1 else {
            return 0.0
        }

        var total: Float = 0.0
        for pair in zip(points, points.dropFirst()) {
            total += simd_distance(pair.0, pair.1)
        }
        return total
    }

    private func fixedWingPathLength(of points: [SIMD3<Float>]) -> Float {
        guard points.count > 1 else {
            return 0.0
        }

        var total: Float = 0.0
        for pair in zip(points, points.dropFirst()) {
            total += simd_distance(pair.0, pair.1)
        }
        return total
    }

    private func refreshTerrainMapSnapshot(recordTrail: Bool) {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        let safeOrientation = finiteVector(state.orientation, fallback: lastFiniteState.orientation)
        let safeVelocity = finiteVector(state.velocity, fallback: lastFiniteState.velocity)
        let dronePlanarPosition = SIMD2<Float>(safePosition.x, safePosition.z)
        let dronePlanarVelocity = SIMD2<Float>(safeVelocity.x, safeVelocity.z)
        let dock = sceneController.currentDockSpawnPoint()
        let extent = max(1.0, terrain.worldHalfExtent)
        let viewport = currentTacticalMapViewport()
        let staticOverlay = terrainMapStaticOverlay(viewport: viewport, extent: extent)
        refreshSceneMissionWaypointCaptureZones(waypoints: staticOverlay.waypoints)
        let assistInterceptTarget = activeFixedWingAssistWaypoint()
        let predictedPathPoints = predictedPathOverlayPoints(assistTarget: assistInterceptTarget?.position)
        let activeLegPoints = activeMissionLegOverlayPoints(
            routePoints: staticOverlay.routePoints,
            assistTarget: assistInterceptTarget?.position
        )
        let operationalStatus = currentMissionOperationalStatus()

        if recordTrail {
            appendTerrainMapTrailSample(dronePlanarPosition)
        } else if terrainMapTrail.isEmpty {
            terrainMapTrail = [dronePlanarPosition]
        }

        let nextSnapshot = TerrainMapSnapshot(
            preset: terrain.preset,
            mapScale: terrain.mapScale,
            worldHalfExtent: extent,
            terrainSeed: terrain.seed,
            operationalRadius: operationalStatus.operationalRadiusM,
            linkQualityRadius: operationalStatus.linkQualityRadiusM,
            degradedLinkRadius: operationalStatus.degradedLinkRadiusM,
            lostLinkRadius: operationalStatus.lostLinkRadiusM,
            hardWorldBoundsRadius: terrain.hardWorldBoundsRadius,
            currentMapSuitability: operationalStatus.mapScaleSuitability,
            airframeClass: selectedDroneProfile.airframeClass,
            dockPosition: SIMD2<Float>(dock.x, dock.z),
            dronePosition: dronePlanarPosition,
            dronePlanarVelocity: dronePlanarVelocity,
            droneYawRadians: safeOrientation.z,
            droneAltitude: max(0.0, safePosition.y),
            targetMarkerPosition: assistInterceptTarget?.position ?? targetMarkerState?.position,
            missionRoutePoints: staticOverlay.routePoints,
            activeLegPoints: activeLegPoints,
            predictedPathPoints: predictedPathPoints,
            missionWaypoints: staticOverlay.waypoints,
            noFlyZones: staticOverlay.noFlyZones,
            payloadImpact: lastPayloadImpact,
            trail: terrainMapTrail,
            objects: staticOverlay.objects
        )

        if nextSnapshot != terrainMapSnapshot {
            terrainMapSnapshot = nextSnapshot
        }
    }

    private func refreshTerrainMapSnapshotIfVisible(recordTrail: Bool) {
        guard isTerrainMapVisible || isMissionMapVisible else {
            if recordTrail {
                appendTerrainMapTrailSample(currentPlanarPosition())
            }
            return
        }
        refreshTerrainMapSnapshot(recordTrail: recordTrail)
    }

    private func terrainMapStaticOverlay(
        viewport: MapViewportState,
        extent: Float
    ) -> TerrainMapStaticOverlay {
        let key = terrainMapStaticOverlayKey(extent: extent)
        if terrainMapStaticOverlayCacheKey == key,
           let terrainMapStaticOverlayCache {
            return terrainMapStaticOverlayCache
        }

        terrainMapHeavyRebuildCount += 1
        fixedWingAssistState.heavyMapRebuildCount = terrainMapHeavyRebuildCount

        let missionOverlay = terrainMapMissionOverlay(viewport: viewport)
        let mapObjects = terrainMapObjects(extent: extent)

        let overlay = TerrainMapStaticOverlay(
            routePoints: missionOverlay.routePoints,
            waypoints: missionOverlay.waypoints,
            noFlyZones: missionOverlay.noFlyZones,
            objects: mapObjects
        )
        terrainMapStaticOverlayCacheKey = key
        terrainMapStaticOverlayCache = overlay
        return overlay
    }

    private func terrainMapObjects(extent: Float) -> [TerrainMapObject] {
        let revision = sceneController.environmentRevision
        let extentBucket = Int(extent.rounded())
        if terrainMapObjectsCacheRevision == revision,
           terrainMapObjectsCacheExtentBucket == extentBucket {
            return terrainMapObjectsCache
        }

        let objects = sceneController.environmentMapDescriptors
            .filter { descriptor in
                guard shouldShowEnvironmentObjectOnMap(descriptor.kind) else {
                    return false
                }
                return abs(descriptor.position.x) <= extent + descriptor.boundingRadius &&
                    abs(descriptor.position.z) <= extent + descriptor.boundingRadius
            }
            .map { descriptor in
                TerrainMapObject(
                    id: descriptor.id,
                    kind: descriptor.kind,
                    position: SIMD2<Float>(descriptor.position.x, descriptor.position.z),
                    footprint: SIMD2<Float>(
                        max(0.35, descriptor.size.x),
                        max(0.35, descriptor.size.z)
                    )
                )
            }
            .sorted { lhs, rhs in
                max(lhs.footprint.x, lhs.footprint.y) > max(rhs.footprint.x, rhs.footprint.y)
            }

        terrainMapObjectsCacheRevision = revision
        terrainMapObjectsCacheExtentBucket = extentBucket
        terrainMapObjectsCache = objects
        return objects
    }

    private func shouldShowEnvironmentObjectOnMap(_ kind: EnvironmentObjectKind) -> Bool {
        switch kind {
        case .tree, .building, .cargoContainer:
            return true
        case .pole, .rock, .crate, .marker:
            return EnvironmentDebugOptions.showPlaceholderObjects
        }
    }

    private func terrainMapStaticOverlayKey(extent: Float) -> TerrainMapStaticOverlayKey {
        let sourceDraft = isMissionMapVisible ? tacticalMapState.workingDraft : tacticalMapState.committedDraft
        let activeMissionWaypointID = missionExecutionState.activeTarget?.waypointID
        let completedWaypointIDs = missionExecutionState.waypointProgress
            .filter { $0.state == .completed }
            .map { $0.target.waypointID }
            .sorted { $0.uuidString < $1.uuidString }
        let objectSignature = environmentObjectSignature()

        return TerrainMapStaticOverlayKey(
            missionPlanID: currentMissionPlan?.id,
            previewRouteID: tacticalMapState.previewRoute?.id,
            draftWaypoints: sourceDraft.waypoints,
            draftZones: sourceDraft.zones,
            activeAssistWaypointID: resolvedFixedWingAssistWaypoint()?.id,
            activeMissionWaypointID: activeMissionWaypointID,
            completedWaypointIDs: completedWaypointIDs,
            objectSignature: objectSignature,
            extentBucket: Int(extent.rounded())
        )
    }

    private func environmentObjectSignature() -> Int {
        let revision = sceneController.environmentRevision
        if environmentObjectSignatureRevision == revision {
            return environmentObjectSignatureCache
        }

        var hasher = Hasher()
        for descriptor in sceneController.environmentMapDescriptors {
            hasher.combine(descriptor.id)
            hasher.combine(descriptor.kind.rawValue)
            hasher.combine(Int((descriptor.position.x * 0.5).rounded()))
            hasher.combine(Int((descriptor.position.z * 0.5).rounded()))
            hasher.combine(Int((descriptor.boundingRadius * 2.0).rounded()))
        }
        let signature = hasher.finalize()
        environmentObjectSignatureRevision = revision
        environmentObjectSignatureCache = signature
        return signature
    }

    private func activeNoFlyZonesForNavigation() -> [MissionZone] {
        if let currentMissionPlan {
            return currentMissionPlan.zones.filter { $0.type == .noFlyZone }
        }

        let sourceDraft = isMissionMapVisible
            ? workingTacticalMissionDraft
            : committedTacticalMissionDraft
        return sourceDraft.zones.filter { $0.type == .noFlyZone }
    }

    private func navigationObstaclesIncludingNoFlyZones() -> [CollisionObstacle] {
        navigationObstacles(including: activeNoFlyZonesForNavigation())
    }

    private func navigationObstacles(including noFlyZones: [MissionZone]) -> [CollisionObstacle] {
        // Trees carry two real-time collision parts (a slim trunk + the canopy) so the drone gets
        // an accurate fly-into-the-trunk response. For *navigation* the trunk is redundant — it
        // sits entirely inside the canopy's planar footprint, so rasterizing it blocks no extra
        // grid cells; it only doubles the obstacle count that the per-tick fixed-wing forward-
        // avoidance probe feeds into ensureGrid()/obstacleHash() on every arc segment. That
        // doubling (once tree collision became mesh-fitted) is what tipped manual fixed-wing flight
        // into multi-second grid-rebuild freezes. Dropping trunk parts here restores the nav
        // obstacle count to one-per-tree (canopy only) — exactly what the autopilot saw before the
        // mesh-fitted change, which the user already confirmed routes fine. Real-time collision in
        // tick() still uses the full `environmentObstacles` list, so trunk collision is unaffected.
        let base = sceneController.environmentObstacles.filter { $0.source != "tree.trunk" }
        guard !noFlyZones.isEmpty else {
            return base
        }

        let zoneTop = max(terrain.maxFlightAltitude + 4.0, 12.0)
        let zoneObstacles = noFlyZones.map { zone in
            CollisionObstacle(
                id: zone.id,
                center: SIMD3<Float>(zone.center.x, zoneTop * 0.5, zone.center.y),
                radius: zone.radius,
                source: "mission.no_fly_zone",
                baseY: 0.0,
                topY: zoneTop
            )
        }
        return base + zoneObstacles
    }

    private func missionWaypointAcceptanceRadiusMeters() -> Float {
        switch selectedDroneProfile.airframeClass {
        case .fixedWing, .hybridVTOL:
            let wing = activeFixedWingParameters()
            return wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed)
        case .multirotor:
            return 1.2
        }
    }

    private func refreshSceneMissionWaypointCaptureZones(
        waypoints: [TerrainMapMissionWaypoint]? = nil
    ) {
        let overlayWaypoints: [TerrainMapMissionWaypoint]
        if let waypoints {
            overlayWaypoints = waypoints
        } else {
            overlayWaypoints = terrainMapMissionOverlay(
                viewport: currentTacticalMapViewport()
            ).waypoints
        }

        guard !overlayWaypoints.isEmpty else {
            sceneController.setMissionWaypointCaptureZones([])
            return
        }

        let captureAltitude = max(
            1.0,
            selectedDroneProfile.airframeClass == .fixedWing
                ? targetMarkerTravelAltitude()
                : max(state.position.y, 1.2)
        )
        let visuals = overlayWaypoints.map { waypoint in
            MissionWaypointCaptureZoneVisual(
                id: waypoint.id,
                label: waypoint.label,
                center: SIMD3<Float>(waypoint.position.x, captureAltitude, waypoint.position.y),
                radius: waypoint.acceptanceRadius,
                isActive: waypoint.isActive || waypoint.isAssistSelected,
                isCompleted: waypoint.isCompleted
            )
        }
        sceneController.setMissionWaypointCaptureZones(visuals)
    }

    private func terrainMapMissionOverlay(
        viewport: MapViewportState
    ) -> (
        routePoints: [SIMD2<Float>],
        waypoints: [TerrainMapMissionWaypoint],
        noFlyZones: [MissionZone]
    ) {
        let routePoints: [SIMD2<Float>]
        let overlayWaypoints: [TerrainMapMissionWaypoint]
        let noFlyZones: [MissionZone]
        let waypointAcceptanceRadius = missionWaypointAcceptanceRadiusMeters()
        let activeAssistWaypointID = resolvedFixedWingAssistWaypoint()?.id
        let cachedFlyByRoutePlan = fixedWingFlyByRoutePlan(
            targetAltitude: max(0.0, state.position.y)
        )

        if let currentMissionPlan, !currentMissionPlan.waypoints.isEmpty {
            if selectedDroneProfile.airframeClass == .fixedWing,
               let cachedFlyByRoutePlan {
                routePoints = cachedFlyByRoutePlan.routePoints
            } else {
                routePoints = currentMissionPlan.missionPoints
            }
            overlayWaypoints = currentMissionPlan.waypoints.map { target in
                TerrainMapMissionWaypoint(
                    id: target.waypointID,
                    label: target.label,
                    position: target.position,
                    acceptanceRadius: waypointAcceptanceRadius,
                    isActive: missionExecutionState.activeTarget?.waypointID == target.waypointID,
                    isAssistSelected: activeAssistWaypointID == target.waypointID,
                    isCompleted: missionExecutionState.waypointProgress.contains {
                        $0.target.waypointID == target.waypointID && $0.state == .completed
                    }
                )
            }
            noFlyZones = currentMissionPlan.zones.filter { $0.type == .noFlyZone }
        } else {
            let sourceDraft = isMissionMapVisible ? workingTacticalMissionDraft : committedTacticalMissionDraft
            let previewRoute = tacticalMapState.previewRoute
            if selectedDroneProfile.airframeClass == .fixedWing,
               let cachedFlyByRoutePlan {
                routePoints = cachedFlyByRoutePlan.routePoints
            } else {
                routePoints = previewRoute?.missionPlanPoints ?? sourceDraft.waypoints.map(\.position)
            }
            overlayWaypoints = sourceDraft.waypoints.map { waypoint in
                TerrainMapMissionWaypoint(
                    id: waypoint.id,
                    label: waypoint.label,
                    position: waypoint.position,
                    acceptanceRadius: waypointAcceptanceRadius,
                    isActive: missionExecutionState.activeTarget?.waypointID == waypoint.id,
                    isAssistSelected: activeAssistWaypointID == waypoint.id,
                    isCompleted: missionExecutionState.waypointProgress.contains {
                        $0.target.waypointID == waypoint.id && $0.state == .completed
                    }
                )
            }
            noFlyZones = sourceDraft.zones.filter { $0.type == .noFlyZone }
        }

        return (
            routePoints: routePoints,
            waypoints: overlayWaypoints,
            noFlyZones: noFlyZones
        )
    }

    private func predictedPathOverlayPoints(assistTarget: SIMD2<Float>?) -> [SIMD2<Float>] {
        if assistTarget != nil {
            return []
        }

        let finitePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        var points: [SIMD2<Float>] = [SIMD2<Float>(finitePosition.x, finitePosition.z)]

        if !navigationSnapshot.waypoints.isEmpty {
            points.append(contentsOf: navigationSnapshot.waypoints.map { SIMD2<Float>($0.x, $0.z) })
        } else if let marker = targetMarkerState {
            points.append(marker.position)
        }

        return compactedPlanarPath(points)
    }

    private func activeMissionLegOverlayPoints(
        routePoints: [SIMD2<Float>],
        assistTarget: SIMD2<Float>?
    ) -> [SIMD2<Float>] {
        if selectedDroneProfile.airframeClass == .fixedWing,
           fixedWingAssistState.mode == .waypointIntercept,
           let assistTarget {
            return fixedWingAssistSafeOverlayRoute(to: assistTarget)
        }

        if selectedDroneProfile.airframeClass == .fixedWing,
           let routePlan = fixedWingFlyByRoutePlan(targetAltitude: max(0.0, state.position.y)),
           let routeSegment = fixedWingActiveRouteOverlaySegment(routePlan: routePlan),
           routeSegment.count > 1 {
            return routeSegment
        }

        if let assistTarget {
            return compactedPlanarPath([
                currentPlanarPosition(),
                assistTarget
            ])
        }

        if selectedDroneProfile.airframeClass == .fixedWing,
           fixedWingMissionRouteHealthy(debugState: fixedWingAutopilotDebugState) {
            return compactedPlanarPath([
                SIMD2<Float>(fixedWingAutopilotDebugState.legStart.x, fixedWingAutopilotDebugState.legStart.z),
                SIMD2<Float>(fixedWingAutopilotDebugState.legEnd.x, fixedWingAutopilotDebugState.legEnd.z)
            ])
        }

        guard !routePoints.isEmpty else {
            return []
        }

        if let activeTarget = missionExecutionState.activeTarget {
            let boundedIndex = max(0, min(activeTarget.index, routePoints.count - 1))
            let legStart = boundedIndex == 0
                ? currentPlanarPosition()
                : routePoints[boundedIndex - 1]
            return compactedPlanarPath([
                legStart,
                routePoints[boundedIndex]
            ])
        }

        if routePoints.count >= 2 {
            return [routePoints[0], routePoints[1]]
        }

        return []
    }

    private func fixedWingActiveRouteOverlaySegment(
        routePlan: FixedWingFlyByRoutePlan
    ) -> [SIMD2<Float>]? {
        if fixedWingAssistState.mode == .waypointIntercept {
            guard let activeWaypoint = activeFixedWingAssistWaypoint() else {
                return nil
            }
            return fixedWingAssistSafeOverlayRoute(to: activeWaypoint.position)
        }

        if fixedWingMissionRouteHealthy(debugState: fixedWingAutopilotDebugState) {
            return compactedPlanarPath([
                SIMD2<Float>(fixedWingAutopilotDebugState.legStart.x, fixedWingAutopilotDebugState.legStart.z),
                SIMD2<Float>(fixedWingAutopilotDebugState.legEnd.x, fixedWingAutopilotDebugState.legEnd.z)
            ])
        }

        return nil
    }

    private func fixedWingAssistSafeOverlayRoute(to target: SIMD2<Float>) -> [SIMD2<Float>] {
        let currentPosition = currentPlanarPosition()
        let noFlyZones = activeNoFlyZonesForNavigation()
        let targetAltitude = max(0.0, state.position.y)
        if let safeRoute = safeFixedWingRoute(
            from: [currentPosition, target],
            zones: noFlyZones,
            viewport: currentTacticalMapViewport(),
            targetAltitude: targetAltitude
        ),
           safeRoute.wasRerouted,
           safeRoute.points.count > 1 {
            return safeRoute.points
        }

        let protectedNoFlyZones = fixedWingProtectedNoFlyZones(noFlyZones)
        let directPath = [currentPosition, target]
        let pathBlocked = planarPathIntersectsNoFly(directPath, zones: protectedNoFlyZones) ||
            fixedWingPathNeedsObstacleReroute(
                directPath,
                obstacles: navigationObstacles(including: protectedNoFlyZones),
                targetAltitude: targetAltitude
            )
        guard !pathBlocked else {
            return [currentPosition]
        }

        return compactedPlanarPath([
            currentPosition,
            target
        ])
    }

    private func compactedPlanarPath(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard !points.isEmpty else {
            return []
        }

        var output: [SIMD2<Float>] = [points[0]]
        output.reserveCapacity(points.count)
        for point in points.dropFirst() {
            if simd_distance(point, output[output.count - 1]) > 0.05 {
                output.append(point)
            }
        }
        return output
    }

    private func currentSpawnPoint() -> SIMD3<Float> {
        if activeLaunchMode().requiresLaunchObject,
           let launchPoint = sceneController.currentLaunchSpawnPoint(for: activeLaunchAsset()) {
            return launchPoint
        }
        return sceneController.currentDockSpawnPoint()
    }

    private func refreshSceneLaunchAsset() {
        sceneController.setLaunchAsset(activeLaunchAsset())
    }

    private func resetTerrainMapTrail() {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        terrainMapTrail = [SIMD2<Float>(safePosition.x, safePosition.z)]
    }

    private func appendTerrainMapTrailSample(_ planarPosition: SIMD2<Float>) {
        guard planarPosition.x.isFinite, planarPosition.y.isFinite else {
            return
        }

        let minimumSampleSpacing = max(0.9, terrain.worldHalfExtent * 0.015)
        if let lastPoint = terrainMapTrail.last,
           simd_distance(lastPoint, planarPosition) < minimumSampleSpacing {
            return
        }

        terrainMapTrail.append(planarPosition)
        let overflow = terrainMapTrail.count - 72
        if overflow > 0 {
            terrainMapTrail.removeFirst(overflow)
        }
    }

    private func currentFleetStatusSnapshot() -> FleetStatus {
        var snapshot = fleetStatus
        snapshot.interDroneRisk = fleetInterDroneRisk
        snapshot.nearestInterDroneDistance = fleetNearestInterDroneDistance
        return snapshot
    }

    private func finiteVector(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            value.x.isFinite ? value.x : fallback.x,
            value.y.isFinite ? value.y : fallback.y,
            value.z.isFinite ? value.z : fallback.z
        )
    }

    private func flightState(speed: Float) -> (title: String, key: String) {
        func localizedFlightState(_ key: String) -> (title: String, key: String) {
            (NSLocalizedString(key, comment: ""), key)
        }

        switch physicalState {
        case .crashed:
            return localizedFlightState("flight_state.crashed")
        case .disarmed:
            return localizedFlightState("flight_state.disarmed")
        case .armedOnGround:
            return localizedFlightState("flight_state.armed_idle")
        case .takeoffTransition:
            return localizedFlightState("flight_state.ascending")
        case .landing:
            return localizedFlightState("flight_state.descending")
        case .landed:
            return localizedFlightState("flight_state.on_ground")
        case .airborne:
            break
        }

        if !isArmed {
            return localizedFlightState("flight_state.disarmed")
        }

        if state.position.y < 0.03 && state.throttle < 0.10 {
            return localizedFlightState("flight_state.armed_idle")
        }

        if batteryState.isDepleted {
            return localizedFlightState("flight_state.battery_depleted")
        }

        if mode == .takeoff {
            return localizedFlightState("flight_state.ascending")
        }

        if mode == .landing {
            return localizedFlightState("flight_state.descending")
        }

        if mode == .emergencyStop {
            return localizedFlightState("flight_state.emergency")
        }

        if speed < 0.25 {
            return localizedFlightState("flight_state.stable")
        }

        if state.velocity.y > 0.2 {
            return localizedFlightState("flight_state.climbing")
        }

        if state.velocity.y < -0.2 {
            return localizedFlightState("flight_state.descending")
        }

        return localizedFlightState("flight_state.cruise")
    }

    private var abstractParametersSummary: String {
        "mass=\(String(format: "%.2f", abstractParameters.massKg))kg,dim=\(Int(abstractParameters.unfoldedMm.x))x\(Int(abstractParameters.unfoldedMm.y))x\(Int(abstractParameters.unfoldedMm.z))mm,batt=\(String(format: "%.1f", abstractParameters.batteryEnergyWh))Wh,max=\(String(format: "%.1f", abstractParameters.maxHorizontalSpeedMps))mps"
    }

    private func updateControlValues(
        _ mutate: (inout DroneControlValues) -> Void,
        markManual: Bool,
        fixedWingManualOverrideAxes: FixedWingAssistOverrideAxes = []
    ) {
        var next = controlValues
        mutate(&next)

        let worldHalfExtent = Double(terrain.worldHalfExtent)
        let maxAltitude = Double(terrain.maxFlightAltitude)
        next.x = next.x.clamped(to: -worldHalfExtent...worldHalfExtent)
        next.y = next.y.clamped(to: 0.0...maxAltitude)
        next.z = next.z.clamped(to: -worldHalfExtent...worldHalfExtent)
        next.throttle = next.throttle.clamped(to: 0.0...1.0)
        next.roll = next.roll.clamped(to: -70.0...70.0)
        next.pitch = next.pitch.clamped(to: -70.0...70.0)
        next.yaw = next.yaw.clamped(to: -180.0...180.0)
        next.vtolTransitionLever = next.vtolTransitionLever.clamped(to: -1.0...1.0)

        if next == controlValues {
            return
        }

        controlValues = next
        hasUnsavedChanges = true
        if markManual {
            if selectedDroneProfile.airframeClass == .fixedWing,
               fixedWingAssistState.mode != .manual {
                registerFixedWingAssistOverride(
                    fixedWingManualOverrideAxes.isEmpty ? .all : fixedWingManualOverrideAxes
                )
            } else {
                cancelTargetMarkerAutoNavigation()
                setFlightMode(.manual, reason: "manual_control_update")
            }
        }
    }

    private var hardWorldBoundsRadius: Float {
        max(24.0, terrain.hardWorldBoundsRadius)
    }

    private func clampedPlanarPosition(_ planarPosition: SIMD2<Float>) -> SIMD2<Float> {
        clampPlanarToBoundarySquare(planarPosition, halfExtent: hardWorldBoundsRadius)
    }

    private func clampPlanarToBoundarySquare(_ planar: SIMD2<Float>, halfExtent: Float) -> SIMD2<Float> {
        let safeHalfExtent = max(1.0, halfExtent)
        let home = SIMD2<Float>(homePosition.x, homePosition.z)
        let local = planar - home
        let clamped = SIMD2<Float>(
            min(max(local.x, -safeHalfExtent), safeHalfExtent),
            min(max(local.y, -safeHalfExtent), safeHalfExtent)
        )
        return home + clamped
    }

    private func currentPlanarPosition() -> SIMD2<Float> {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        return SIMD2<Float>(safePosition.x, safePosition.z)
    }

    private func applyActiveRouteTarget(
        _ marker: TargetMarkerState?,
        source: ActiveRouteTargetSource,
        startNavigationIfPossible: Bool
    ) {
        // Validate marker through the guidance resolver before promoting it to
        // a flight target. Rejecting invalid/out-of-bounds/non-snapped markers
        // here keeps a stray UI tap or a malformed plan from steering the
        // multicopter off course.
        let acceptedMarker = sanitizedMarkerForRouteTarget(
            marker,
            source: source
        )
        activeRouteTargetSource = acceptedMarker == nil ? .none : source
        targetMarkerState = acceptedMarker
        resetActiveRouteTargetGuidanceCache()

        if let acceptedMarker {
            autoNavigationController.replaceTarget(acceptedMarker)
            autoPathPlanner.invalidate()
            autoFlightGoal = nil
            navigationSnapshot = .idle
            invalidateFixedWingRouteTrackingContextCache()

            if startNavigationIfPossible, canStartTargetMarkerAutoNavigation {
                if selectedDroneProfile.airframeClass == .multirotor {
                    autoNavigationController.start(safeTravelAltitude: targetMarkerTravelAltitude())
                } else {
                    autoNavigationController.cancel()
                }
                setFlightMode(.autoPath, reason: source == .mission ? "mission_target_bound_auto_path" : "manual_marker_auto_path")
                prepareHybridVTOLAutopilotForForwardRoute()
            }
        } else {
            autoNavigationController.clearTarget()
            autoPathPlanner.invalidate()
            invalidateFixedWingRouteTrackingContextCache()
            if mode == .autoPath {
                setFlightMode(.manual, reason: "route_target_cleared")
            }
            navigationSnapshot = .idle
        }

        isInMissionDropZone = missionPlanState.dropZone?.contains(currentPlanarPosition()) ?? false
        // Rebinding the next mission waypoint happens on the simulation/main
        // thread. Rebuilding the complete tactical-map snapshot here is wasted
        // work while both map surfaces are hidden and can include sorting every
        // environment descriptor plus regenerating route overlays. On large
        // worlds this blocked rendering for several seconds immediately after
        // waypoint capture. A visible map is still refreshed synchronously; a
        // hidden map is rebuilt by its normal visibility refresh when opened.
        refreshTerrainMapSnapshotIfVisible(recordTrail: false)
        refreshCompassOverlay()
        refreshFlightControlDiagnostics()
    }

    /// Validates a marker before it becomes the active autopilot target.
    /// Mission markers are accepted if they relay the active mission target.
    /// Manual markers must lie inside the world bounds and not collide with
    /// the drone's current position. Anything else is rejected and the
    /// rejection reason is recorded for diagnostics.
    private func sanitizedMarkerForRouteTarget(
        _ marker: TargetMarkerState?,
        source: ActiveRouteTargetSource
    ) -> TargetMarkerState? {
        guard let marker else {
            lastTargetMarkerRejectionReason = nil
            return nil
        }

        let activeMissionTarget: MissionTarget? = {
            switch source {
            case .mission:
                return missionExecutionState.activeTarget
            case .manualMarker, .none:
                return nil
            }
        }()

        let resolution = missionGuidanceTargetResolver.resolve(
            MissionGuidanceResolutionInput(
                marker: marker,
                activeMissionTarget: activeMissionTarget,
                missionIsActive: source == .mission && activeMissionTarget != nil,
                currentPlanarPosition: currentPlanarPosition(),
                hardWorldHalfExtent: hardWorldBoundsRadius,
                waypointSnapToleranceMeters: 0.5,
                minimumEngagementDistanceMeters: 0.20
            )
        )

        lastTargetMarkerRejectionReason = resolution.rejectionReason

        guard let planarPosition = resolution.planarPosition,
              isFiniteVector2(planarPosition) else {
            return nil
        }

        if simd_distance(planarPosition, marker.position) <= 0.001 {
            return marker
        }

        // The resolver may snap a marker that drifted off the active mission
        // waypoint back to the validated position. Preserve the marker id so
        // mission progress accounting and adapter binding stay consistent.
        return TargetMarkerState(
            id: marker.id,
            position: planarPosition,
            createdAt: marker.createdAt
        )
    }

    private func invalidateFixedWingRouteTrackingContextCache() {
        fixedWingRouteTrackingContextCacheTick = nil
        fixedWingRouteTrackingContextCacheFallback = nil
        fixedWingRouteTrackingContextCacheValue = nil
    }

    /// Builds (or reuses) the flyable line+arc primitive route for a given
    /// runtime waypoint list. The result is cached by `routeIdentifier` plus a
    /// shape signature so that re-rendering during a single mission only does
    /// one fillet pass even if the runtime waypoint array is rebuilt every
    /// frame.
    private func buildFixedWingFlyableRoute(
        fromRuntimeWaypoints runtimeWaypoints: [FixedWingRouteWaypoint],
        routeIdentifier: String,
        wing: FixedWingParameters
    ) -> FixedWingFlyableRoute? {
        guard runtimeWaypoints.count >= 2 else { return nil }

        // Cache key combines the route identifier with a coarse fingerprint
        // of the actual waypoint positions so that any meaningful change
        // (waypoint moved, runtime start re-stamped, route refreshed)
        // triggers a rebuild without rebuilding every tick.
        var hasher = Hasher()
        hasher.combine(routeIdentifier)
        hasher.combine(runtimeWaypoints.count)
        for waypoint in runtimeWaypoints {
            hasher.combine(Int((waypoint.position.x * 10.0).rounded()))
            hasher.combine(Int((waypoint.position.z * 10.0).rounded()))
            hasher.combine(waypoint.missionWaypointIndex ?? -1)
        }
        let cacheKey = "\(routeIdentifier)|\(hasher.finalize())"
        if cacheKey == fixedWingFlyablePathCacheKey,
           let cachedRoute = fixedWingFlyablePathCacheRoute {
            return cachedRoute
        }

        guard let start = runtimeWaypoints.first else { return nil }
        let startPlanar = SIMD2<Float>(start.position.x, start.position.z)
        let inputs: [FixedWingFlyableRouteBuilder.WaypointInput] = runtimeWaypoints
            .dropFirst()
            .map { waypoint in
                FixedWingFlyableRouteBuilder.WaypointInput(
                    position: SIMD2<Float>(waypoint.position.x, waypoint.position.z),
                    missionWaypointIndex: waypoint.missionWaypointIndex
                )
            }
        guard !inputs.isEmpty else { return nil }

        let airspeed = max(
            wing.minSafeAirspeed,
            simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        )
        let flyable = fixedWingFlyableRouteBuilder.build(
            routeIdentifier: routeIdentifier,
            start: startPlanar,
            waypoints: inputs,
            wing: wing,
            airspeed: airspeed
        )

        fixedWingFlyablePathCacheKey = cacheKey
        fixedWingFlyablePathCacheRoute = flyable
        return flyable
    }

    private func clearMissionPlan() {
        if activeRouteTargetSource == .mission {
            applyMissionAutopilotCommand(missionAutopilotAdapter.clear())
        }
        missionPlanState = .empty
        missionPlanningDraft = .empty
        missionMapMode = .navigation
        isMissionMapVisible = false
        isInMissionDropZone = false
        sceneController.setMissionDropZone(nil)
        let launchDraft = defaultLaunchConfiguredDraft()
        committedTacticalMissionDraft = launchDraft
        workingTacticalMissionDraft = launchDraft
        tacticalMapMode = .waypoint
        currentMissionPlan = nil
        missionExecutionState = .idle
        missionRuntimeMonitor.reset()
        missionSafetyState = .idle
        fixedWingMissionStateArbiter.reset()
        fixedWingMissionArbiterDecision = .nominal
        fixedWingBatteryWarningLevel = .nominal
        missionEventRecorder.reset()
        missionTimeline = nil
        missionObservation.reset()
        refreshSceneLaunchAsset()
        refreshTacticalMapState()
        refreshMissionStatus()
    }

    private func currentTacticalMapViewport() -> MapViewportState {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        let dock = sceneController.currentDockSpawnPoint()
        let operationalStatus = currentMissionOperationalStatus()
        let weatherPenalty = max(
            1.0,
            (weather.effectiveFactors.batteryDrainMultiplier * 0.64) +
                (weather.effectiveFactors.dragMultiplier * 0.36)
        )
        let mapRecommendation = selectedDroneProfile.mapScaleRecommendation(
            currentScale: terrain.mapScale,
            payloadMassKg: vehicleMassModel.payloadMass,
            batteryFraction: (batteryState.chargePercent / 100.0).clamped(to: 0.08...1.0),
            weatherPenalty: weatherPenalty
        )
        return MapViewportState(
            center: SIMD2<Float>(safePosition.x, safePosition.z),
            mapScale: terrain.mapScale,
            worldHalfExtent: max(1.0, terrain.worldHalfExtent),
            worldPhysicalScale: max(1.0, terrain.worldHalfExtent * 2.0),
            operationalRadius: operationalStatus.operationalRadiusM,
            linkQualityRadius: operationalStatus.linkQualityRadiusM,
            degradedLinkRadius: operationalStatus.degradedLinkRadiusM,
            lostLinkRadius: operationalStatus.lostLinkRadiusM,
            hardWorldBoundsRadius: hardWorldBoundsRadius,
            dronePosition: SIMD2<Float>(safePosition.x, safePosition.z),
            dockPosition: SIMD2<Float>(dock.x, dock.z),
            droneAltitudeMeters: max(0.0, safePosition.y),
            dockAltitudeMeters: max(0.0, dock.y),
            terrainMaxAltitudeMeters: max(0.0, terrain.maxFlightAltitude),
            airframeClass: selectedDroneProfile.airframeClass,
            profileMaxHorizontalSpeedMps: max(0.0, selectedDroneProfile.maxHorizontalSpeedMps),
            estimatedRemainingTimeSec: operationalStatus.estimatedRemainingTimeSec,
            estimatedRemainingRangeM: operationalStatus.estimatedRemainingRangeM,
            estimatedSafeReturnRangeM: operationalStatus.estimatedSafeReturnRangeM,
            canReachHomeSafely: operationalStatus.canReachHomeSafely,
            currentLinkQuality: operationalStatus.currentLinkQuality,
            currentMapSuitability: operationalStatus.mapScaleSuitability,
            recommendedMapScaleMin: operationalStatus.recommendedMapScaleMin,
            recommendedMapScaleMax: operationalStatus.recommendedMapScaleMax,
            recommendedOperationalMapScale: operationalStatus.recommendedOperationalMapScale,
            unsuitableMapScales: mapRecommendation.unsuitableMapScales,
            minimumTurnRadiusM: mapRecommendation.minimumTurnRadiusM,
            waypointAnticipationDistanceM: mapRecommendation.waypointAnticipationDistanceM
        )
    }

    private func refreshTacticalMapState() {
        let nextState = tacticalMapCoordinator.buildState(
            isVisible: isMissionMapVisible,
            mode: tacticalMapMode,
            viewport: currentTacticalMapViewport(),
            committedDraft: committedTacticalMissionDraft,
            workingDraft: workingTacticalMissionDraft,
            airframeClass: selectedDroneProfile.airframeClass,
            fixedWingParameters: selectedDroneProfile.fixedWingParameters,
            supportedLaunchModes: selectedDroneProfile.supportedLaunchModes
        )

        if nextState != tacticalMapState {
            terrainMapHeavyRebuildCount += 1
            fixedWingAssistState.heavyMapRebuildCount = terrainMapHeavyRebuildCount
            tacticalMapState = nextState
            invalidateFixedWingRouteCaches()
        }
        syncFixedWingAssistSelection()
        refreshFixedWingAssistRuntimeDebugState()
        refreshSceneMissionWaypointCaptureZones()
        refreshSceneLaunchAsset()
        refreshMissionStatus()
    }

    private func invalidatePreparedMissionIfNeeded() {
        guard missionExecutionState.status != .running,
              missionExecutionState.status != .paused else {
            return
        }

        let hadPlan = currentMissionPlan != nil || missionExecutionState.status != .idle
        currentMissionPlan = nil
        missionExecutionState = .idle
        missionRuntimeMonitor.reset()
        missionSafetyState = .idle
        invalidateFixedWingRouteCaches()
        missionEventRecorder.reset()
        missionTimeline = nil
        missionObservation.reset()
        if hadPlan && activeRouteTargetSource == .mission {
            applyMissionAutopilotCommand(missionAutopilotAdapter.clear())
        }
    }

    private func applyMissionAutopilotCommand(_ command: MissionAutopilotCommand) {
        applyActiveRouteTarget(
            command.targetMarker,
            source: command.targetMarker == nil ? .none : .mission,
            startNavigationIfPossible: command.startNavigation
        )
    }

    private func bindMissionExecutionTarget(
        _ target: MissionTarget,
        startNavigation: Bool
    ) {
        applyMissionAutopilotCommand(
            missionAutopilotAdapter.bind(
                target: target,
                startNavigation: startNavigation
            )
        )

        missionExecutionState.bindingState = .bound
        missionExecutionState.hasBoundAutopilotTarget = missionAutopilotAdapter.isBound(
            activeTarget: target,
            currentMarker: targetMarkerState
        )

        let distance = simd_distance(currentPlanarPosition(), target.position)
        if distance.isFinite {
            missionExecutionState.distanceToActiveTarget = distance
        }
        missionExecutionState.lastUpdatedAt = Date()
    }

    private func enterMissionExecutionHold() {
        if let activeTarget = missionExecutionState.activeTarget {
            let distance = simd_distance(currentPlanarPosition(), activeTarget.position)
            if distance.isFinite {
                missionExecutionState.distanceToActiveTarget = distance
            }
        }

        missionExecutionState.hasBoundAutopilotTarget = false
        applyMissionAutopilotCommand(missionAutopilotAdapter.clear())

        if selectedDroneProfile.airframeClass == .fixedWing,
           isArmed,
           state.position.y > 0.05 {
            navigationSnapshot = .idle
            resetFixedWingAutopilotCommands()
            setFixedWingGuidanceSource(.none, reason: "fixed_wing_mission_course_hold")
            setFlightMode(.manual, reason: "fixed_wing_mission_completed_course_hold")
            fixedWingAssistUsesTargetYawWhileManual = true

            let cruiseThrottle = Double(resolvedFlightBaseline(for: .autoPath).cruiseReferenceThrottle)
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.y = Double(state.position.y)
                values.z = Double(state.position.z)
                values.roll = 0.0
                values.pitch = max(-2.0, min(values.pitch, 4.0))
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                values.throttle = max(cruiseThrottle, values.throttle * 0.96)
            }, markManual: false)
            return
        }

        if selectedDroneProfile.airframeClass == .hybridVTOL,
           isArmed,
           state.position.y > 0.05 {
            hover()
            return
        }

        if selectedDroneProfile.airframeClass == .multirotor,
           isArmed,
           state.position.y > 0.05 {
            hover()
        }
    }

    private func beginMissionTimelineSession(for plan: MissionPlan) {
        missionTimeline = missionEventRecorder.beginSession(
            projectID: currentProjectID,
            projectName: currentProjectName,
            missionPlanID: plan.id
        )
        missionDebrief = nil
        missionObservation.reset()
    }

    private func recordMissionEvents(_ events: [MissionEvent]) {
        guard !events.isEmpty else {
            return
        }

        missionTimeline = missionEventRecorder.record(contentsOf: events)
        hasUnsavedChanges = true
    }

    private func recordMissionStateTransitions(
        previousExecutionState: MissionExecutionState,
        previousSafetyState: MissionSafetyState,
        previousSnapshot: MissionStatusSnapshot,
        plan: MissionPlan? = nil
    ) {
        let activePlan = plan ?? currentMissionPlan
        var events = missionEventMapper.executionTransitionEvents(
            previous: previousExecutionState,
            current: missionExecutionState,
            plan: activePlan,
            projectID: currentProjectID,
            projectName: currentProjectName,
            statusSnapshot: missionStatusSnapshot,
            batteryState: batteryState
        )

        events.append(contentsOf: missionEventMapper.safetyTransitionEvents(
            previous: previousSafetyState,
            current: missionSafetyState,
            plan: activePlan,
            projectID: currentProjectID,
            projectName: currentProjectName,
            statusSnapshot: missionStatusSnapshot,
            batteryState: batteryState
        ))

        recordMissionEvents(events)

        if previousExecutionState.status != missionExecutionState.status {
            if missionExecutionState.status == .running {
                if previousExecutionState.status == .paused {
                    missionObservation.resume(position: state.position)
                } else {
                    missionObservation.begin(
                        position: state.position,
                        batteryPercent: batteryState.chargePercent
                    )
                }
            }
        }

        finalizeMissionDebriefIfNeeded(previousExecutionState: previousExecutionState)

        if previousSnapshot != missionStatusSnapshot {
            hasUnsavedChanges = true
        }
    }

    private func currentMissionDebriefInput(timeline: MissionTimeline) -> MissionDebriefInput {
        MissionDebriefInput(
            timeline: timeline,
            plan: currentMissionPlan,
            executionState: missionExecutionState,
            statusSnapshot: missionStatusSnapshot,
            safetyState: missionSafetyState,
            batteryState: batteryState,
            payloadState: payloadState,
            totalDistanceMeters: missionObservation.totalDistanceMeters,
            maxAltitudeMeters: missionObservation.maxAltitudeMeters,
            averageAltitudeMeters: missionObservation.averageAltitudeMeters,
            startBatteryPercent: missionObservation.startBatteryPercent
        )
    }

    private func finalizeMissionDebriefIfNeeded(previousExecutionState: MissionExecutionState) {
        guard previousExecutionState.status != missionExecutionState.status,
              missionExecutionState.status == .completed ||
                missionExecutionState.status == .aborted ||
                missionExecutionState.status == .failed,
              let timeline = missionEventRecorder.currentTimeline,
              missionDebrief?.timelineID != timeline.id else {
            return
        }

        let outcome = missionDebriefService.resolveOutcome(
            for: currentMissionDebriefInput(timeline: timeline)
        )
        let finalizedTimeline = missionEventRecorder.finishSession(outcome: outcome) ?? timeline
        missionTimeline = finalizedTimeline

        let debrief = missionDebriefService.buildDebrief(
            from: currentMissionDebriefInput(timeline: finalizedTimeline)
        )
        missionDebrief = debrief

        let debriefEvent = missionEventMapper.debriefGeneratedEvent(
            debrief: debrief,
            projectID: currentProjectID,
            projectName: currentProjectName
        )
        missionTimeline = missionEventRecorder.record(debriefEvent)
        hasUnsavedChanges = true
    }

    private func sampleMissionObservationIfNeeded() {
        if missionExecutionState.status == .running {
            missionObservation.sample(position: state.position)
        } else if missionExecutionState.status == .paused {
            missionObservation.resume(position: state.position)
        }
    }

    private func recordMissionStartBlockedEvent(plan: MissionPlan?) {
        let blockedEvent = missionEventMapper.simpleEvent(
            missionID: plan?.id,
            category: .execution,
            severity: missionStatusSnapshot.primaryExplanation?.severity == .critical ? .critical : .warning,
            code: .missionBlocked,
            detailKey: missionStatusSnapshot.primaryExplanation?.detailKey ??
                missionSafetyState.blockReason?.detailKey ??
                "mission.status.reason.mission_start_blocked",
            projectID: currentProjectID,
            projectName: currentProjectName,
            plan: plan,
            statusSnapshot: missionStatusSnapshot,
            batteryState: batteryState
        )
        recordMissionEvents([blockedEvent])
    }

    private func updateMissionExecutionRuntime() {
        guard let currentMissionPlan,
              missionExecutionState.status == .running else {
            return
        }

        let progress = missionProgressTracker.evaluate(
            executionState: missionExecutionState,
            planarPosition: currentPlanarPosition(),
            currentMarker: targetMarkerState,
            autoNavigationStatus: currentAutoNavigationStatus(),
            flightMode: mode,
            airframeClass: selectedDroneProfile.airframeClass,
            fixedWingParameters: selectedDroneProfile.fixedWingParameters,
            fixedWingDebugState: selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL
                ? fixedWingAutopilotDebugState
                : nil,
            adapter: missionAutopilotAdapter
        )
        let previousState = missionExecutionState
        let previousSafetyState = missionSafetyState
        let previousSnapshot = missionStatusSnapshot
        missionExecutionState = missionExecutionCoordinator.update(
            state: missionExecutionState,
            plan: currentMissionPlan,
            progress: progress
        )

        let needsTargetRebind =
            missionExecutionState.status == .running &&
            missionExecutionState.activeTarget != nil &&
            (
                previousState.activeTarget != missionExecutionState.activeTarget ||
                !missionExecutionState.hasBoundAutopilotTarget
            )

        guard missionExecutionState != previousState || needsTargetRebind else {
            return
        }

        switch missionExecutionState.status {
        case .running:
            if let activeTarget = missionExecutionState.activeTarget,
               previousState.activeTarget != activeTarget || !missionExecutionState.hasBoundAutopilotTarget {
                if canStartTargetMarkerAutoNavigation {
                    bindMissionExecutionTarget(activeTarget, startNavigation: true)
                }
            }
        case .completed:
            enterMissionExecutionHold()
        case .aborted, .blocked, .failed:
            enterMissionExecutionHold()
        case .idle, .ready, .paused:
            break
        }

        refreshSceneMissionWaypointCaptureZones()
        refreshMissionStatus()
        recordMissionStateTransitions(
            previousExecutionState: previousState,
            previousSafetyState: previousSafetyState,
            previousSnapshot: previousSnapshot,
            plan: currentMissionPlan
        )
    }

    private func evaluateMissionSafetyState() -> MissionSafetyState {
        let authorityState = missionAuthorityGuard.evaluate(
            executionState: missionExecutionState,
            controlAuthority: flightControlDiagnostics.authority,
            missionOwnsTargetSource: activeRouteTargetSource == .mission,
            airframeClass: selectedDroneProfile.airframeClass,
            fixedWingDebugState: selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL
                ? fixedWingAutopilotDebugState
                : nil,
            currentMarker: targetMarkerState,
            adapter: missionAutopilotAdapter
        )
        let runtimeMonitor = missionRuntimeMonitor.evaluate(
            executionState: missionExecutionState,
            autoNavigationStatus: currentAutoNavigationStatus(),
            currentMarker: targetMarkerState,
            missionOwnsTargetSource: activeRouteTargetSource == .mission,
            flightMode: mode,
            launchState: launchState,
            airframeClass: selectedDroneProfile.airframeClass,
            fixedWingParameters: selectedDroneProfile.fixedWingParameters,
            fixedWingDebugState: selectedDroneProfile.airframeClass == .fixedWing ||
                selectedDroneProfile.airframeClass == .hybridVTOL
                ? fixedWingAutopilotDebugState
                : nil
        )
        let operationalStatus = currentMissionOperationalStatus(
            missionDistanceEstimate: currentMissionDistanceEstimate()
        )
        let missionGeofenceConfiguration = currentMissionGeofenceConfiguration()
        let missionGeofenceState = currentMissionGeofenceState(configuration: missionGeofenceConfiguration)

        var safetyState = missionSafetyEvaluator.evaluate(
            draftStatus: tacticalMapState.draftStatus,
            currentPlan: currentMissionPlan,
            executionState: missionExecutionState,
            authorityState: authorityState,
            runtimeMonitor: runtimeMonitor,
            canStartMissionAutopilot: canBindMissionTargetToAutopilot,
            batteryState: batteryState,
            airframeClass: selectedDroneProfile.airframeClass,
            collisionAnalysis: collisionAnalysis,
            thermalState: thermalState,
            signalState: signalState,
            operationalStatus: operationalStatus,
            missionGeofenceState: missionGeofenceState
        )

        if selectedDroneProfile.airframeClass == .fixedWing {
            let arbiterDecision = currentFixedWingMissionArbiterDecision(
                operationalStatus: operationalStatus
            )
            fixedWingMissionArbiterDecision = arbiterDecision
            fixedWingBatteryWarningLevel = arbiterDecision.batteryLevel
            safetyState = reconcileFixedWingMissionSafetyState(
                safetyState,
                currentPlan: currentMissionPlan,
                operationalStatus: operationalStatus,
                arbiterDecision: arbiterDecision
            )
        } else {
            fixedWingMissionArbiterDecision = .nominal
            fixedWingBatteryWarningLevel = .nominal
            fixedWingMissionStateArbiter.reset()
        }

        let failsafeMode = missionFailsafeCoordinator.resolve(
            executionState: missionExecutionState,
            safetyState: safetyState,
            airframeClass: selectedDroneProfile.airframeClass,
            flightMode: mode,
            missionGeofenceState: missionGeofenceState,
            missionGeofenceAction: missionGeofenceConfiguration?.configuredAction ?? .warningOnly
        )
        safetyState.failsafeMode = failsafeMode
        safetyState.abortReason = abortReason(for: failsafeMode, safetyState: safetyState)
        return safetyState
    }

    private func applyMissionSafetyRuntimeIfNeeded() {
        let previousExecutionState = missionExecutionState
        let previousSafetyState = missionSafetyState
        let previousSnapshot = missionStatusSnapshot
        let nextSafetyState = evaluateMissionSafetyState()
        missionSafetyState = nextSafetyState

        if shouldAutomaticallyResumeMission(from: nextSafetyState) {
            missionExecutionState = missionExecutionCoordinator.resume(
                state: missionExecutionState
            )
            missionRuntimeMonitor.reset()
            if let activeTarget = missionExecutionState.activeTarget {
                bindMissionExecutionTarget(activeTarget, startNavigation: true)
            }
            missionSafetyState = evaluateMissionSafetyState()
            refreshMissionStatus()
            recordMissionStateTransitions(
                previousExecutionState: previousExecutionState,
                previousSafetyState: previousSafetyState,
                previousSnapshot: previousSnapshot
            )
            return
        }

        guard missionExecutionState.status == .running else {
            if previousSafetyState != missionSafetyState {
                refreshMissionStatus()
                recordMissionStateTransitions(
                    previousExecutionState: previousExecutionState,
                    previousSafetyState: previousSafetyState,
                    previousSnapshot: previousSnapshot
                )
            }
            return
        }

        switch nextSafetyState.failsafeMode {
        case .none:
            break
        case .hold:
            missionExecutionState = missionExecutionCoordinator.pause(
                state: missionExecutionState,
                reason: .missionPausedByRuntime,
                detailKey: "mission.status.reason.mission_paused_by_runtime"
            )
            enterMissionExecutionHold()
        case .pauseMission:
            missionExecutionState = missionExecutionCoordinator.pause(
                state: missionExecutionState,
                reason: .missionPausedByRuntime,
                detailKey: "mission.status.reason.mission_paused_by_runtime"
            )
            enterMissionExecutionHold()
        case .abortMission:
            missionExecutionState = missionExecutionCoordinator.abort(
                state: missionExecutionState,
                reason: .missionAbortedBySafety,
                abortReason: nextSafetyState.abortReason ?? .safetyAbort,
                detailKey: "mission.status.reason.mission_aborted_by_safety"
            )
            applyMissionAutopilotCommand(missionAutopilotAdapter.clear())
            missionRuntimeMonitor.reset()
        case .returnHome:
            missionExecutionState = missionExecutionCoordinator.abort(
                state: missionExecutionState,
                reason: .returnHomeTriggered,
                abortReason: nextSafetyState.abortReason ?? .returnHomeTriggered,
                detailKey: "mission.status.reason.return_home_triggered"
            )
            applyMissionAutopilotCommand(missionAutopilotAdapter.clear())
            missionRuntimeMonitor.reset()
            if mode != .returnHome {
                activateReturnHome(reason: "mission_failsafe_return_home")
            }
        }

        missionSafetyState = evaluateMissionSafetyState()
        refreshMissionStatus()
        recordMissionStateTransitions(
            previousExecutionState: previousExecutionState,
            previousSafetyState: previousSafetyState,
            previousSnapshot: previousSnapshot
        )
    }

    private func shouldAutomaticallyResumeMission(
        from safetyState: MissionSafetyState
    ) -> Bool {
        guard missionExecutionState.status == .paused,
              missionExecutionState.failureReason == .missionPausedByRuntime,
              missionExecutionState.canResume,
              missionExecutionState.activeTarget != nil,
              safetyState.readiness == .ready,
              safetyState.blockReason == nil,
              safetyState.failsafeMode == .none,
              canBindMissionTargetToAutopilot else {
            return false
        }
        return true
    }

    private func abortReason(
        for failsafeMode: MissionFailsafeMode,
        safetyState: MissionSafetyState
    ) -> MissionAbortReason? {
        switch failsafeMode {
        case .none:
            return nil
        case .hold, .pauseMission:
            return .runtimeUnsafe
        case .abortMission:
            switch safetyState.blockReason {
            case .routeInvalid, .noValidatedPlan:
                return .routeInvalid
            case .batteryUnsafe:
                return .batteryUnsafe
            case .noControlAuthority:
                return .authorityLost
            case .executionContourMissing,
                 .executionBindingFailed,
                 .runtimeDistanceUnavailable,
                 .runtimeStallDetected,
                 .missionStartBlocked,
                 .runtimeUnsafe,
                 .noMissionTarget,
                 .none:
                return .safetyAbort
            }
        case .returnHome:
            switch safetyState.blockReason {
            case .batteryUnsafe:
                return .batteryUnsafe
            case .none:
                return .returnHomeTriggered
            case .some:
                return .returnHomeTriggered
            }
        }
    }

    private func refreshMissionStatus() {
        missionSafetyState = evaluateMissionSafetyState()
        let operationalStatus = currentMissionOperationalStatus(
            missionDistanceEstimate: currentMissionDistanceEstimate()
        )
        let nextSnapshot = missionStatusResolver.resolve(
            draftStatus: tacticalMapState.draftStatus,
            currentPlan: currentMissionPlan,
            executionState: missionExecutionState,
            safetyState: missionSafetyState,
            operationalStatus: operationalStatus,
            controlAuthority: flightControlDiagnostics.authority,
            flightMode: mode
        )

        if nextSnapshot != missionStatusSnapshot {
            missionStatusSnapshot = nextSnapshot
        }
    }

    private func syncMissionDeliveryState(triggerAutoRelease: Bool) {
        let planarPosition = currentPlanarPosition()
        let nextInDropZone = missionPlanState.dropZone?.contains(planarPosition) ?? false
        if isInMissionDropZone != nextInDropZone {
            isInMissionDropZone = nextInDropZone
        }

        guard triggerAutoRelease,
              let dropZone = missionPlanState.dropZone,
              missionPlanState.isDeliveryMissionReady,
              missionPlanState.autoReleaseEnabled,
              payloadState == .attached,
              installedPayloadConfiguration != nil,
              selectedDroneProfile.airframeClass == .multirotor,
              (mode == .autoPath || mode == .hover),
              isArmed,
              !signalState.isInteractionBlocking else {
            return
        }

        let distanceToCenter = simd_distance(planarPosition, dropZone.center)
        let releaseRadius = min(dropZone.radius, max(0.8, dropZone.radius * 0.24))
        let horizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let isStableOverZone = horizontalSpeed <= 0.55 && abs(state.velocity.y) <= 0.32

        guard distanceToCenter <= releaseRadius,
              isStableOverZone,
              state.position.y > 0.35 else {
            return
        }

        releasePayload()
    }

    /// Local, cascade-only mirror of the radio link-quality zones — kept separate from
    /// `WorldDetailBoundaryState` (which is a map-edge/visual-detail concept) since this drives
    /// signal behavior purely from distance-to-home vs. the aircraft's nominal radio range.
    private enum RadioLinkZone {
        case nominal
        case warning
        case critical
        case lost
    }

    private func updateSignalLossSequence(deltaTime: Float) {
        // Fiber isn't affected by distance from the map center at all — it's bypassed entirely
        // under `.fiberOptic` in favor of `FiberLinkState`/`ControlLinkFailsafeStage` above.
        guard activeControlLinkType == .radio else {
            return
        }
        guard signalLossCause != .impactDamage else {
            return
        }
        // Once the control link is genuinely lost and latched, this whole warning/countdown
        // cascade stops running entirely — recovery is owned by
        // `updateControlLinkFailsafeLatchRecovery`'s stable-reconnection timer, not by re-running
        // this cascade every tick. Without this guard, `signalState` kept re-entering
        // `.boundaryCountdown` from `.normal` every ~8s forever (harmless re-triggers) and, before
        // this fix, `signalCountdownSecondsRemaining` never stopped decrementing past zero.
        guard !controlLinkFailsafeLatched else {
            return
        }

        let operationalStatus = currentMissionOperationalStatus(
            missionDistanceEstimate: currentMissionDistanceEstimate()
        )
        let linkLossPolicy = selectedDroneProfile.operationalProfile.linkLossPolicy
        let radioZone: RadioLinkZone = {
            if operationalStatus.isLinkLost { return .lost }
            if operationalStatus.isInCriticalLinkZone { return .critical }
            if operationalStatus.isInWarningLinkZone { return .warning }
            return .nominal
        }()

        // A genuine radio-range failsafe reaction is a function of equipment, not of the world's
        // detail boundary — an aircraft with an autopilot doesn't need to freeze/go dark just
        // because it drifted out of nominal link range, it hands off to the same equipment
        // failsafe a severed fiber would (see `beginControlLinkFailsafeSequence`). Only a simple
        // aircraft with no autopilot to fall back on (`.strandedWithoutInput`) still goes through
        // the freeze/dark countdown below — losing the channel really is losing the ability to
        // fly for that equipment class.
        func handleLinkLost() {
            signalCountdownSecondsRemaining = 0
            signalLossSecondAccumulator = 0.0
            if linkLossPolicy == .strandedWithoutInput {
                enterSignalLostState(cause: .linkRange)
            } else {
                // Not `.signalLost` — that state (and the interaction-blocking machinery it
                // drives: full-screen freeze, `blocksSimulationForSignalLoss`, etc.) is reserved
                // for aircraft with no autopilot to fall back on. This aircraft keeps flying
                // itself through the failsafe below (input blocked via
                // `isControlLinkFailsafeActive` instead), so the stale top-right countdown card
                // just needs to clear — `ControlLinkFailsafeStageHUDView` takes over as the
                // relevant HUD element from here, and `controlLinkFailsafeLatched` (set inside
                // `beginControlLinkFailsafeSequence`) stops this cascade from re-entering.
                signalState = .normal
                beginControlLinkFailsafeSequence(trigger: .radioLinkLost)
            }
        }

        switch signalState {
        case .normal:
            switch radioZone {
            case .warning:
                signalState = .outOfBoundsWarning
            case .critical:
                signalState = .signalDegrading
            case .lost:
                signalState = .boundaryCountdown
                signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
                signalLossSecondAccumulator = 0.0
            case .nominal:
                break
            }

        case .outOfBoundsWarning, .signalDegrading, .boundaryCountdown:
            switch radioZone {
            case .nominal:
                clearSignalLossState(restoringInputMode: false)
                return
            case .warning:
                signalState = .outOfBoundsWarning
                signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
                signalLossSecondAccumulator = 0.0
                return
            case .critical:
                signalState = .signalDegrading
                signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
                signalLossSecondAccumulator = 0.0
                return
            case .lost:
                signalState = .boundaryCountdown
            }

            signalLossSecondAccumulator += deltaTime

            while signalLossSecondAccumulator >= 1.0, signalCountdownSecondsRemaining > 0 {
                signalLossSecondAccumulator -= 1.0
                signalCountdownSecondsRemaining = max(0, signalCountdownSecondsRemaining - 1)

                if signalCountdownSecondsRemaining <= 0 {
                    handleLinkLost()
                    return
                }
            }

        case .signalLost, .recoveryPending:
            break
        }
    }

    private func renderSignalLossFrame() {
        sceneController.applyWeatherVisual(weather)
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        sceneController.updateFleetWingmen(
            wingmen,
            profile: selectedDroneProfile,
            throttle: state.throttle,
            deltaTime: 0.0
        )
    }

    private func enterSignalLostState(cause: SignalLossCause) {
        guard signalState != .signalLost else {
            return
        }

        signalLossCause = cause
        signalState = .signalLost
        signalCountdownSecondsRemaining = 0
        signalLossSecondAccumulator = 0.0
        cancelTargetMarkerAutoNavigation()
        cameraLookVelocity = .zero
        payloadGimbalLookVelocity = .zero
        controllerUIBridge.cancelTextInput()
        keyboardInputService.setInputProcessingMode(.editing)
        inputManager.reset()
        resetFlightControlRouting()
        hasUnsavedChanges = true
    }

    private func clearSignalLossState(restoringInputMode: Bool) {
        let hadBlockingState = signalState.isInteractionBlocking
        signalState = .normal
        signalLossCause = nil
        signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
        signalLossSecondAccumulator = 0.0

        if restoringInputMode && hadBlockingState {
            keyboardInputService.setInputProcessingMode(.flight)
            inputManager.reset()
        }
        refreshFlightControlDiagnostics()
    }

    private func enforceRuntimeSafetyAndBounds(context: String) {
        let spawn = currentSpawnPoint()

        if !isFinite(state.position) || !isFinite(state.velocity) || !isFinite(state.orientation) || !isFinite(state.angularVelocity) || !state.throttle.isFinite || !state.motorThrottle.isFinite {
            print("[RuntimeSafety][\(context)] Non-finite state detected, restoring last finite state.")
            state = lastFiniteState
            state.position = SIMD3<Float>(
                state.position.x,
                max(lastKnownGroundHeight, state.position.y),
                state.position.z
            )
            setFlightMode(.manual, reason: "runtime_safety_non_finite_restore")
            transitionPhysicalState(isArmed ? .armedOnGround : .disarmed)
            controlValues = neutralControls(from: state)
            return
        }

        let halfExtent = terrain.worldHalfExtent
        let maxAltitude = max(80.0, terrain.maxFlightAltitude)

        // The floor is the surface below the aircraft, not the world origin.
        //
        // This ran immediately after the physics step and before every other constraint, so a hard
        // clamp at zero here silently overrode the terrain no matter what the engine, the support
        // surface or the water rule had decided. Two flights ended with the aircraft pinned at
        // exactly y = 0.0 over a harbour whose water plane is at −0.25: it could not reach the water
        // to drown in it, and equally could not descend into any terrain lying below sea level —
        // three quarters of this tile.
        //
        // A metre of slack below the surface keeps this a *safety* net catching a runaway fall,
        // rather than a second ground contact competing with the constraint that owns that job.
        let floor = lastKnownGroundHeight - 1.0
        if state.position.y < floor {
            state.position.y = floor
            if state.velocity.y < 0.0 {
                state.velocity.y = 0.0
            }
        } else if state.position.y > maxAltitude {
            state.position.y = maxAltitude
            if state.velocity.y > 0.0 {
                state.velocity.y = 0.0
            }
        }

        if !state.position.x.isFinite || !state.position.y.isFinite || !state.position.z.isFinite {
            state.position = spawn
            state.velocity = .zero
            state.angularVelocity = .zero
            state.throttle = 0.0
            state.motorThrottle = 0.0
            isArmed = false
            setFlightMode(.manual, reason: "runtime_safety_position_recovery")
            transitionPhysicalState(.disarmed)
            if !state.orientation.x.isFinite || !state.orientation.y.isFinite || !state.orientation.z.isFinite {
                state.orientation = .zero
            }
            resyncFixedWingAttitudeFromEuler()
        }

        if !controlValues.x.isFinite || !controlValues.y.isFinite || !controlValues.z.isFinite ||
            !controlValues.roll.isFinite || !controlValues.pitch.isFinite || !controlValues.yaw.isFinite || !controlValues.throttle.isFinite {
            controlValues = neutralControls(from: state)
        } else {
            controlValues.x = controlValues.x.clamped(to: -Double(halfExtent)...Double(halfExtent))
            controlValues.y = controlValues.y.clamped(to: 0.0...Double(maxAltitude))
            controlValues.z = controlValues.z.clamped(to: -Double(halfExtent)...Double(halfExtent))
        }

        enforceHoseTetherConstraint()

        lastFiniteState = state
    }

    /// A real fire hose is a fixed-length physical line to the ground truck's pump — it cannot
    /// stretch. Mirrors the altitude-ceiling clamp above (hard position stop + zero the offending
    /// velocity component), generalized from a 1-D vertical wall to a 3-D spherical one centered
    /// on the truck, rather than the world-bounds geofence's "lose signal after a countdown"
    /// pattern — a taut rope stops the drone immediately, it doesn't cut its signal.
    private func enforceHoseTetherConstraint() {
        guard activeMissionScenarioKind == .fireResponse,
              isMountedHoseAvailable,
              let installed = installedPayloadConfiguration,
              let truckPosition = sceneController.currentFireTruckWorldPosition() else {
            isHoseTetherActive = false
            isHoseTetherTaut = false
            hoseTetherDistanceMeters = 0.0
            hoseTetherLimitMeters = 0.0
            return
        }

        let tetherLength = max(1.0, installed.fireHoseLengthMeters)
        let toTruck = state.position - truckPosition
        let distance = simd_length(toTruck)

        isHoseTetherActive = true
        hoseTetherLimitMeters = tetherLength
        hoseTetherDistanceMeters = min(distance, tetherLength)

        guard distance > tetherLength, distance > 0.0001 else {
            isHoseTetherTaut = false
            return
        }

        isHoseTetherTaut = true
        let radial = toTruck / distance
        state.position = truckPosition + radial * tetherLength
        let outwardSpeed = simd_dot(state.velocity, radial)
        if outwardSpeed > 0.0 {
            state.velocity -= radial * outwardSpeed
        }
    }

    /// Laid-line fiber model: an anchor at the launch point plus turn/contact checkpoints form
    /// the polyline of deployed fiber (`fiberPolylineCheckpoints`); the live leg runs from the
    /// last checkpoint to the aircraft. Consumption is the polyline's total length, monotonic via
    /// `max` — a reel pays out, it never rewinds — so hover/wind micro-jitter costs nothing
    /// (the old per-tick `simd_distance` integration charged every centimeter of oscillation).
    /// Snag risk comes only from the *line* actually bending around obstacles (contact
    /// checkpoints, found by raycasting the live leg), never from the aircraft merely flying
    /// near one. Called once per simulation tick.
    ///
    /// The fiber spool is a control-link module (`installedFiberSpoolModule`), not mission
    /// payload — this only ever reads/writes that slot, never `installedPayloadConfiguration`.
    private func updateFiberOpticTether(deltaTime: Float) {
        guard installedFiberSpoolModule != nil, isFiberSpoolAttached else {
            // Genuinely detached — only this resets link state to fresh. Neither being grounded
            // nor being broken should (see the two guards below): a real reel doesn't un-sever
            // just because the aircraft happens to touch the ground, and the failsafe's own
            // final landing necessarily drops through this same altitude check.
            if fiberLinkState.status != .connected || !fiberPolylineCheckpoints.isEmpty {
                fiberLinkState = FiberLinkState()
                clearFiberPolyline()
                sceneController.clearFiberTetherVisual()
            }
            return
        }

        guard fiberLinkState.status != .broken else {
            // Terminal — never reconnects, regardless of ground/armed state. `ControlLinkFailsafeStage`
            // owns recovery from here, including the landing this same reel is still mounted for.
            // The rendered line deliberately stays frozen where it lay at the moment of the break.
            return
        }

        guard let installed = installedFiberSpoolModule, isArmed, state.position.y > 0.05 else {
            // Grounded/disarmed but the reel is still mounted and hasn't broken (e.g. sitting on
            // the pad before launch) — pause tracking without resetting the laid line or risk;
            // a real reel doesn't refill because the aircraft landed for a moment.
            return
        }

        // Seed the anchor on the sortie's first airborne tick — the line starts where the
        // aircraft actually lifted off.
        if fiberPolylineCheckpoints.isEmpty {
            fiberPolylineCheckpoints = [FiberPolylineCheckpoint(position: state.position, kind: .anchor)]
            fiberPolylineFixedLengthMeters = 0.0
            fiberLegFarthestPoint = nil
            fiberLegFarthestDistance = 0.0
        }

        // 1) Line contact: does the live leg (last checkpoint → aircraft) pass through an
        // obstacle? One pivot per tick at most — the wrap geometry refines over subsequent ticks
        // as the aircraft keeps moving, without pivot-spamming a single trunk.
        var newContactCreated = false
        if let lastCP = fiberPolylineCheckpoints.last?.position {
            let toDrone = state.position - lastCP
            let legLength = simd_length(toDrone)
            if legLength > FiberOpticTetherTuning.minCheckpointSpacingMeters + 0.5 {
                let direction = toDrone / legLength
                if let hitDistance = sceneController.fiberSegmentObstacleHitDistance(
                    origin: lastCP,
                    direction: direction,
                    // Stop short of the aircraft itself — the leg endpoint is the airframe, and
                    // its immediate vicinity is the reel outlet, not a snag.
                    maxDistance: legLength - 0.4
                ), hitDistance > FiberOpticTetherTuning.minCheckpointSpacingMeters {
                    let pivot = lastCP
                        + direction * max(0.3, hitDistance - FiberOpticTetherTuning.contactPivotClearanceMeters)
                        + SIMD3<Float>(0.0, 0.2, 0.0)
                    newContactCreated = appendFiberCheckpoint(
                        FiberPolylineCheckpoint(position: pivot, kind: .contact)
                    )
                }
            }
        }

        // 2) Turn points: capture the macroscopic flown path (out-and-back legs and real course
        // changes) without charging for micro-jitter. A leg's farthest point becomes a fixed
        // checkpoint once the aircraft backtracks or deviates sideways past the thresholds.
        if let lastCP = fiberPolylineCheckpoints.last?.position {
            let liveDistance = simd_distance(lastCP, state.position)
            if let farthest = fiberLegFarthestPoint {
                if liveDistance > fiberLegFarthestDistance {
                    fiberLegFarthestPoint = state.position
                    fiberLegFarthestDistance = liveDistance
                } else if fiberLegFarthestDistance > FiberOpticTetherTuning.turnMinLegLengthMeters {
                    let backtracked = fiberLegFarthestDistance - liveDistance > FiberOpticTetherTuning.turnBacktrackThresholdMeters
                    var deviatedLaterally = false
                    let axisVector = farthest - lastCP
                    let axisLength = simd_length(axisVector)
                    if axisLength > 0.001 {
                        let axis = axisVector / axisLength
                        let relative = state.position - lastCP
                        let along = simd_dot(relative, axis)
                        deviatedLaterally = simd_length(relative - axis * along) > FiberOpticTetherTuning.turnLateralDeviationMeters
                    }
                    if backtracked || deviatedLaterally {
                        _ = appendFiberCheckpoint(FiberPolylineCheckpoint(position: farthest, kind: .turn))
                    }
                }
            } else {
                fiberLegFarthestPoint = state.position
                fiberLegFarthestDistance = liveDistance
            }
        }

        // 3) Consumption: fixed polyline length + live leg, monotonic (payout only).
        let lastCPPosition = fiberPolylineCheckpoints.last?.position ?? state.position
        let requiredLength = fiberPolylineFixedLengthMeters + simd_distance(lastCPPosition, state.position)
        let previousDeployed = fiberOpticPathLengthUsedMeters
        fiberOpticPathLengthUsedMeters = max(fiberOpticPathLengthUsedMeters, requiredLength)
        let payoutDelta = fiberOpticPathLengthUsedMeters - previousDeployed

        // The rigged capacity is immutable — payout is tracked on its own field. (An earlier
        // version overwrote `totalLengthMeters` with the remaining length every tick to drain
        // mass, which compounded the consumption math and burned a 0.5 km reel in seconds.)
        let configuredLength = installed.totalLengthMeters
        let usableBudget = configuredLength * FiberOpticTetherTuning.usableLengthFraction
        let remainingUsable = max(0.0, usableBudget - fiberOpticPathLengthUsedMeters)

        // Mass drain: coarse 0.5 m granularity — no point re-running the whole mass model for
        // sub-centimeter payout every tick.
        if abs(installed.deployedLengthMeters - fiberOpticPathLengthUsedMeters) > 0.5 {
            installedFiberSpoolModule?.deployedLengthMeters = min(fiberOpticPathLengthUsedMeters, configuredLength)
            refreshPayloadRuntimeState()
        }

        // 4) Snag risk: a fresh wrap bumps it once; paying line out *over* existing contacts
        // grinds it up (abrasion, scaled by contact count); a fully free line lets it decay.
        let contactCount = fiberPolylineCheckpoints.reduce(into: 0) { count, checkpoint in
            if checkpoint.kind == .contact { count += 1 }
        }
        if newContactCreated {
            fiberOpticSnagRisk += FiberOpticTetherTuning.contactRiskPerNewContact
        }
        if contactCount > 0 {
            fiberOpticSnagRisk += payoutDelta
                * FiberOpticTetherTuning.contactAbrasionRiskPerMeter
                * min(Float(contactCount), FiberOpticTetherTuning.contactCountRiskCap)
        } else {
            fiberOpticSnagRisk -= FiberOpticTetherTuning.snagRiskDecayPerSecondWhenFree * deltaTime
        }
        fiberOpticSnagRisk = fiberOpticSnagRisk.clamped(to: 0.0...1.0)

        let remainingLengthFraction = usableBudget > 0.0001 ? remainingUsable / usableBudget : 0.0
        let isSnagged = fiberOpticSnagRisk >= 1.0
        let isExhausted = remainingUsable <= 0.0001
        let status: FiberLinkStatus
        if isSnagged || isExhausted {
            status = .broken
        } else if fiberOpticSnagRisk >= FiberOpticTetherTuning.degradedSnagRiskThreshold
            || remainingLengthFraction <= FiberOpticTetherTuning.degradedRemainingLengthFraction {
            status = .degraded
        } else {
            status = .connected
        }

        fiberLinkState = FiberLinkState(
            status: status,
            deployedLengthMeters: fiberOpticPathLengthUsedMeters,
            remainingLengthMeters: remainingUsable,
            usableLengthMeters: usableBudget,
            isSnagged: isSnagged,
            snagRiskLevel: fiberOpticSnagRisk
        )

        // 5) The visible line: fixed checkpoints plus the live leg to the aircraft.
        var visualPoints = fiberPolylineCheckpoints.map(\.position)
        visualPoints.append(state.position)
        sceneController.updateFiberTetherVisual(points: visualPoints)

        if status == .broken {
            beginControlLinkFailsafeSequence(trigger: .fiberBroken)
        }
    }

    /// Appends a checkpoint if it clears the spacing/cap guards; returns whether it was added.
    /// Fixing a checkpoint folds its segment into `fiberPolylineFixedLengthMeters` and starts a
    /// fresh live leg.
    private func appendFiberCheckpoint(_ checkpoint: FiberPolylineCheckpoint) -> Bool {
        guard fiberPolylineCheckpoints.count < FiberOpticTetherTuning.maxCheckpoints,
              let last = fiberPolylineCheckpoints.last else {
            return false
        }
        let segmentLength = simd_distance(last.position, checkpoint.position)
        guard segmentLength >= FiberOpticTetherTuning.minCheckpointSpacingMeters else {
            return false
        }
        fiberPolylineFixedLengthMeters += segmentLength
        fiberPolylineCheckpoints.append(checkpoint)
        fiberLegFarthestPoint = nil
        fiberLegFarthestDistance = 0.0
        return true
    }

    private func clearFiberPolyline() {
        fiberPolylineCheckpoints = []
        fiberPolylineFixedLengthMeters = 0.0
        fiberLegFarthestPoint = nil
        fiberLegFarthestDistance = 0.0
    }

    /// Entry point into the control-link-loss failsafe — shared by a severed fiber and a lost
    /// radio link on an aircraft whose `linkLossPolicy` calls for it (see
    /// `updateSignalLossSequence`): the reaction depends on equipment/policy, not on which link
    /// type failed. A mission-bound autonomous aircraft reuses the existing `.returnHome` state
    /// machine directly instead of the staged sequence below — `continueMissionOnFiberLoss`
    /// (default off) is the explicit opt-in to skip even that, per the requirement that continuing
    /// unattended must be a deliberate setting, not the default (applies to both triggers).
    private func beginControlLinkFailsafeSequence(trigger: ControlLinkFailsafeTrigger) {
        guard controlLinkFailsafeStage == .none else {
            return
        }
        controlLinkFailsafeTrigger = trigger
        // Persists through the whole sequence and past landing — a landing ends the aircraft's
        // motion, not the reason it lost control in the first place. Cleared only by
        // `updateControlLinkFailsafeLatchRecovery` (radio, after a stable reconnection) or by
        // detaching/reattaching the fiber spool (a real repair/replacement action).
        controlLinkFailsafeLatched = true

        if activeRouteTargetSource == .mission, missionExecutionState.status == .running {
            if continueMissionOnFiberLoss {
                controlLinkFailsafeStage = .missionContinued
            } else {
                setFlightMode(.returnHome, reason: trigger == .fiberBroken ? "fiber_link_broken" : "radio_link_lost")
                controlLinkFailsafeStage = .returnedHome
            }
            return
        }

        controlLinkFailsafeStageElapsed = 0.0
        switch selectedDroneProfile.airframeClass {
        case .multirotor:
            controlLinkFailsafeStage = .braking
        case .fixedWing, .hybridVTOL:
            // Captured right here (not later, when `.loiterGlide` begins) so the orbit centers on
            // where the link was actually lost — minimizing how far the brief wings-level
            // `.stabilize` hold can carry it before the loiter takes over.
            controlLinkFailsafeLoiterCenter = SIMD2<Float>(state.position.x, state.position.z)
            controlLinkFailsafeStage = .stabilize
        }
    }

    /// Course (radians, codebase convention `atan2(-dx, -dz)` — matches
    /// `MulticopterAutopilotController`/`SimpleDronePhysicsEngine`/`FixedWingAutopilot`) toward a
    /// planar direction vector, used only by the control-link failsafe's own simple loiter so it
    /// doesn't need to reach into the full waypoint-tracking autopilot for one bearing calculation.
    private func controlLinkFailsafeCourse(direction: SIMD2<Float>) -> Float {
        let course = atan2f(-direction.x, -direction.y)
        return course.isFinite ? course : 0.0
    }

    private func controlLinkFailsafeShortestAngle(_ angle: Float) -> Float {
        var normalized = angle
        while normalized > .pi { normalized -= 2.0 * .pi }
        while normalized < -.pi { normalized += 2.0 * .pi }
        return normalized
    }

    /// Bank command (degrees) that flies a bounded circle around `controlLinkFailsafeLoiterCenter`:
    /// heads toward the center while outside `ControlLinkFailsafeOrbitTuning.radiusMeters`, then
    /// switches to the tangential direction to hold the circle — a deliberately simple "ring
    /// following" guidance, not the full L1 path-tracking `FixedWingAutopilotController` uses for
    /// missions, since this only ever needs to bound one orbit, not track a route.
    private func controlLinkFailsafeOrbitBankDegrees() -> Double {
        let currentPlanar = SIMD2<Float>(state.position.x, state.position.z)
        let center = controlLinkFailsafeLoiterCenter ?? currentPlanar
        let toCenter = center - currentPlanar
        let distance = simd_length(toCenter)
        let direction: SIMD2<Float> = distance > ControlLinkFailsafeOrbitTuning.radiusMeters
            ? toCenter
            : SIMD2<Float>(-toCenter.y, toCenter.x)
        let desiredCourse = controlLinkFailsafeCourse(direction: direction)
        let courseError = controlLinkFailsafeShortestAngle(desiredCourse - state.orientation.z)
        let bankDeg = Double(courseError.radiansToDegrees) * Double(ControlLinkFailsafeOrbitTuning.courseErrorToBankGain)
        return min(max(bankDeg, -ControlLinkFailsafeOrbitTuning.maxBankDegrees), ControlLinkFailsafeOrbitTuning.maxBankDegrees)
    }

    /// Drives the active failsafe stage every tick, once `controlLinkFailsafeStage.isActive`. Applies
    /// commands the same way `.hover`/`.emergencyStop`/autopilot modes already do elsewhere
    /// (`updateControlValues(markManual: false)`), which is why gating player input
    /// (`isControlLinkFailsafeActive`) matters — otherwise the player's own stick would fight this
    /// every other tick instead of being cleanly superseded.
    private func updateControlLinkFailsafeSequence(deltaTime: Float) {
        guard controlLinkFailsafeStage.isActive else {
            return
        }
        controlLinkFailsafeStageElapsed += deltaTime

        switch controlLinkFailsafeStage {
        case .braking:
            let horizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                values.x = Double(state.position.x)
                values.z = Double(state.position.z)
            }, markManual: false)
            if controlLinkFailsafeStageElapsed >= 1.0 || horizontalSpeed < 0.3 {
                controlLinkFailsafeStage = .hoverFailsafe
                controlLinkFailsafeStageElapsed = 0.0
            }

        case .hoverFailsafe:
            let hoverBaseline = Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle)
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                let throttleTarget = hoverBaseline.clamped(to: 0.0...1.0)
                values.throttle = values.throttle + (throttleTarget - values.throttle) * 0.18
            }, markManual: false)
            // Real fiber breaks never reconnect — a brief 1-3s stabilization is enough before
            // landing, unlike radio range loss where waiting longer might recover the link.
            if controlLinkFailsafeStageElapsed >= 2.0 {
                controlLinkFailsafeStage = .landing
                controlLinkFailsafeStageElapsed = 0.0
            }

        case .landing:
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.y = max(0.0, Double(state.position.y - 0.02))
                values.z = Double(state.position.z)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(0.0, values.throttle - 0.02)
            }, markManual: false)
            if physicalState.isGroundRestState {
                finalizeControlLinkFailsafeLanding()
            }

        case .stabilize:
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                values.throttle = values.throttle + (0.5 - values.throttle) * 0.12
            }, markManual: false)
            if controlLinkFailsafeStageElapsed >= 2.0 {
                controlLinkFailsafeStage = .loiterGlide
                controlLinkFailsafeStageElapsed = 0.0
            }

        case .loiterGlide:
            // Banks toward `controlLinkFailsafeLoiterCenter` and circles it (`
            // controlLinkFailsafeOrbitBankDegrees`) — a fixed 15° bank previously had a turn
            // radius wide enough (~650m+ at cruise speed) that it barely curved the flight path in
            // 8 seconds, letting the aircraft drift far outside the rendered world before ever
            // starting to loop back.
            updateControlValues({ values in
                values.roll = controlLinkFailsafeOrbitBankDegrees()
                values.pitch = 0.0
                values.throttle = values.throttle + (0.5 - values.throttle) * 0.08
            }, markManual: false)
            if controlLinkFailsafeStageElapsed >= 8.0 {
                controlLinkFailsafeStage = .emergencyLanding
                controlLinkFailsafeStageElapsed = 0.0
            }

        case .emergencyLanding:
            // Same bounded orbit as `.loiterGlide` (not a dead-straight glide) plus a gentle
            // nose-up bias and decaying throttle — a slow, controlled spiral toward the ground
            // near the loiter center. Close to the ground the nose-up bias strengthens into a
            // flare and the bank levels out: a real belly landing bleeds vertical speed right
            // before touchdown instead of flying into the ground at descent attitude (which the
            // collision system rightly classified as a crash, not a landing).
            let heightAboveGround = heightAboveSupportSurface(for: state.position)
            let flareBlend = Double((1.0 - heightAboveGround / 14.0).clamped(to: 0.0...1.0))
            updateControlValues({ values in
                values.roll = controlLinkFailsafeOrbitBankDegrees() * (1.0 - flareBlend)
                values.pitch = 3.0 + flareBlend * 5.0
                values.throttle = max(0.0, values.throttle - 0.01)
            }, markManual: false)
            if physicalState.isGroundRestState {
                finalizeControlLinkFailsafeLanding()
            }

        case .none, .landed, .crashed, .returnedHome, .missionContinued:
            break
        }
    }

    /// Clears `controlLinkFailsafeLatched` on genuine recovery — the *only* place it's cleared
    /// outside of a fiber-spool attach/detach. Radio can recover (a real RSSI-style channel can
    /// come back into range); fiber cannot (a severed line is a terminal condition for the
    /// sortie), so this deliberately does nothing at all for `.fiberBroken`.
    private func updateControlLinkFailsafeLatchRecovery(deltaTime: Float) {
        guard controlLinkFailsafeLatched else {
            stableRadioReconnectionSeconds = 0.0
            return
        }
        guard controlLinkFailsafeTrigger == .radioLinkLost else {
            return
        }

        let operationalStatus = currentMissionOperationalStatus(
            missionDistanceEstimate: currentMissionDistanceEstimate()
        )
        guard !operationalStatus.isInWarningLinkZone else {
            stableRadioReconnectionSeconds = 0.0
            return
        }

        stableRadioReconnectionSeconds += deltaTime
        guard stableRadioReconnectionSeconds >= SignalLossConfiguration.stableReconnectionRequiredSeconds else {
            return
        }

        controlLinkFailsafeLatched = false
        controlLinkFailsafeStage = .none
        controlLinkFailsafeStageElapsed = 0.0
        controlLinkFailsafeLoiterCenter = nil
        stableRadioReconnectionSeconds = 0.0
    }

    /// A severed control link doesn't come back by wiggling the stick — landing/crashing under
    /// the failsafe disarms the aircraft, same as any other post-crash/post-landing state, so
    /// resuming flight needs an explicit re-arm rather than seamlessly handing control back the
    /// instant the failsafe's own descent touches down.
    private func finalizeControlLinkFailsafeLanding() {
        let crashed = physicalState == .crashed
        controlLinkFailsafeStage = crashed ? .crashed : .landed
        disarm(preserveCrashDynamics: crashed)
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func supportSurfaceY(for position: SIMD3<Float>) -> Float {
        supportSurfaceY(for: position, maximumHeight: position.y)
    }

    /// Planar tolerance for "is there support under the drone" queries. Deliberately small: support
    /// is only reported while the drone's centre of gravity is actually over the surface. The old
    /// ~collision-radius expansion (0.36 m) let the floor clamp keep holding the aircraft after it
    /// slid past a roof edge, leaving it parked on empty air beside the eave — once the CG passes
    /// the edge the drone must lose support and simply descend, like a real airframe tipping off.
    private var supportQueryClearanceRadius: Float {
        max(0.05, selectedDroneProfile.collisionRadius * 0.12)
    }

    private func supportSurfaceY(for position: SIMD3<Float>, maximumHeight: Float) -> Float {
        supportSurfaceYIfAny(for: position, maximumHeight: maximumHeight) ?? 0.0
    }

    /// The same query, keeping "nothing under here" distinct from "the surface is at zero".
    ///
    /// Collapsing the two was safe only while every world was flat and every support surface was a
    /// rooftop standing above the y = 0 plane. On imported terrain a real surface can sit at or below
    /// zero — a quay, a shoreline, anything referenced to a vertical datum whose origin is sea level
    /// — and treating that as "no support" is what let the aircraft sink through the ground near the
    /// water's edge.
    private func supportSurfaceYIfAny(for position: SIMD3<Float>, maximumHeight: Float) -> Float? {
        sceneController.supportSurfaceHeight(
            at: SIMD2<Float>(position.x, position.z),
            clearanceRadius: supportQueryClearanceRadius,
            maximumHeight: maximumHeight
        )
    }

    /// Surface elevation under the aircraft, remembered between ticks.
    ///
    /// A query legitimately misses — beyond the imported tile's edge, or over a hole in the mesh —
    /// and answering zero there would drop the aircraft to sea level for one tick and snap it back
    /// on the next. Ground does not teleport, so the last known elevation is a far better answer
    /// than the world origin. Stays at zero for the procedural presets, where no query ever
    /// succeeds and the ground genuinely is the y = 0 plane.
    private func currentGroundHeight() -> Float {
        if let surface = supportSurfaceYIfAny(for: state.position, maximumHeight: state.position.y) {
            lastKnownGroundHeight = surface
        }
        return lastKnownGroundHeight
    }

    private var lastKnownGroundHeight: Float = 0.0
    #if DEBUG
    private var verticalDebugTicks = 0
    #endif

    /// How long the airframe has been in contact with the water, in seconds.
    private var waterContactSeconds: Float = 0.0

    /// Set once the aircraft has been lost to the water, cleared when it is recovered.
    ///
    /// Needed as its own flag because "crashed" alone cannot express it: a wreck on land rests on
    /// the surface it hit, which is exactly what must *not* happen here. Without this the drowned
    /// aircraft sat on the sea intact and merely disarmed — technically lost, and reading to the
    /// pilot as nothing having happened at all.
    private(set) var isDrowned = false

    /// True between choosing an imported world and that world being installed.
    private(set) var isAwaitingImportedWorld = false

    /// Called by the shell before it starts loading an imported world, so the flight model holds
    /// still instead of falling through a world that does not exist yet.
    func beginAwaitingImportedWorld() {
        isAwaitingImportedWorld = true
        state.velocity = .zero
        state.angularVelocity = .zero
    }

    /// Releases the hold without a world — the load failed, and a frozen session with no explanation
    /// would be worse than procedural ground.
    func endAwaitingImportedWorld() {
        isAwaitingImportedWorld = false
    }

    /// Ends the flight when the aircraft meets water it cannot survive.
    ///
    /// A photogrammetric harbour is collision geometry like any other, so without this the aircraft
    /// simply rests on the sea as though it were asphalt — the single most obviously wrong thing in
    /// a coastal city, and one this project created for itself by teaching the support surface to
    /// accept elevations at and below zero (nearly three quarters of the Helsinki tile).
    ///
    /// The outcome is a property of the airframe, not of the water: an unsealed multirotor is gone
    /// the moment it touches, a weather-sealed one survives a brief slap of the surface but not
    /// going under, and a buoyant hull simply floats and is left alone — the support surface is
    /// already holding it up, which is exactly what floating looks like.
    private func applyWaterImmersionIfNeeded(deltaTime: Float) {
        guard let water = sceneController.meshWater else { return }
        if isDrowned {
            // Self-correcting: a drowned airframe that is no longer over water is not drowning any
            // more, whatever set the flag. Without this, one stale flag sank the aircraft forever —
            // including while parked on dry ground two metres up, where the 0.55 m/s descent exactly
            // cancelled the climb and looked, from the cockpit, like the throttle had stopped
            // working. It cost several test flights to find, so the flag is no longer trusted on its
            // own.
            guard water.isWater(x: state.position.x, z: state.position.z) else {
                isDrowned = false
                waterContactSeconds = 0.0
                return
            }
            sinkDrownedAircraft(water: water, deltaTime: deltaTime)
            return
        }
        guard physicalState != .crashed else { return }
        guard water.isWater(x: state.position.x, z: state.position.z) else {
            waterContactSeconds = 0.0
            return
        }

        // Contact is decided against the surface actually under the aircraft, not against the fitted
        // water plane.
        //
        // A photogrammetric sea is not flat: reconstructed from imagery, it carries the swell it was
        // photographed with. Measured across three points where the aircraft was reported sitting on
        // the water "like asphalt", the mesh surface read −0.193, −0.247 and −0.355 m against a fitted
        // plane of −0.250 — a spread of 16 cm, with points *above* the plane. Comparing the hull to
        // that plane therefore concluded the aircraft was airborne while it was parked on the sea,
        // and whether an aircraft drowned came down to which wave it happened to land on.
        //
        // The plane stays the right tool for *classification* — deciding which columns are water at
        // all — and the wrong one for contact. If the aircraft is resting on a surface and that
        // surface is water, it is in the water, whatever height the water happens to be at there.
        let surfaceY = supportSurfaceYIfAny(for: state.position, maximumHeight: state.position.y)
            ?? water.level
        let hullY = state.position.y - vehicleGroundClearance()
        let depth = surfaceY - hullY

        guard depth > -0.15 else {
            waterContactSeconds = 0.0
            return
        }

        let protection = selectedDroneProfile.waterProtection
        // Under the surface by more than the airframe's own radius: the hull is in, not skimming.
        let submerged = depth > max(0.25, selectedDroneProfile.collisionRadius)
        if submerged && protection.submersionIsTerminal {
            loseAircraftToWater(reason: "submerged", depth: depth)
            return
        }

        waterContactSeconds += deltaTime
        if waterContactSeconds > protection.surfaceContactToleranceSeconds {
            loseAircraftToWater(reason: "surface contact", depth: depth)
        }
    }

    private static let drownedSettlingDepth: Float = 0.8

    /// Sinks a lost airframe until it is under the surface, then lets it rest there.
    private func sinkDrownedAircraft(water: WaterSurfaceModel, deltaTime: Float) {
        let target = water.level - Self.drownedSettlingDepth + vehicleGroundClearance()
        guard state.position.y > target else {
            state.position.y = target
            state.velocity = .zero
            return
        }
        // A flooded multirotor goes down steadily rather than dropping like a stone: it is nearly
        // neutrally buoyant for the first moment and the water resists the frame broadside.
        state.position.y = max(target, state.position.y - 0.55 * deltaTime)
        state.velocity.y = min(state.velocity.y, 0.0)
    }

    private func loseAircraftToWater(reason: String, depth: Float) {
        #if DEBUG
        print(String(format: "[Water] aircraft lost (%@, %.2f m) — protection %@",
                     reason, depth, selectedDroneProfile.waterProtection.rawValue))
        #endif
        waterContactSeconds = 0.0
        isDrowned = true
        disarm(forceEmergency: true, preserveCrashDynamics: true)
    }

    private func supportSurfaceContact(for position: SIMD3<Float>) -> (height: Float, normal: SIMD3<Float>)? {
        sceneController.supportSurfaceContact(
            at: SIMD2<Float>(position.x, position.z),
            clearanceRadius: supportQueryClearanceRadius,
            maximumHeight: position.y
        )
    }

    /// Rest-attitude support normal from a least-squares plane fit over the footprint HEIGHTS
    /// (centre + 8 compass points at ~one footprint radius). Fitting heights — rather than
    /// averaging the normals of whichever triangle happens to top each sample — matches what the
    /// gear physically rests on: corrugated-sheet ribs and uneven planks collapse to the sheet's
    /// overall plane, a ridge straddle fits ~level, and a smooth slope reproduces that slope
    /// exactly (the shingle-roof behaviour, now for every model). Samples far below the highest
    /// contact (holes between planks exposing interior floors) can't carry the airframe and are
    /// dropped before fitting. Height queries stay single-point elsewhere so the drone still
    /// seats on the actual crest it is standing on.
    private func fittedSupportPlaneNormal(at position: SIMD3<Float>) -> SIMD3<Float>? {
        let footprint = max(0.3, selectedDroneProfile.collisionRadius * 1.2)
        let clearanceRadius = supportQueryClearanceRadius
        // Allow samples a little above the centre so the up-slope side of the footprint is not
        // rejected by the height guard on a real incline.
        let maximumHeight = position.y + max(0.35, footprint)
        let diagonal = footprint * 0.7071
        let offsets: [SIMD2<Float>] = [
            SIMD2<Float>(0.0, 0.0),
            SIMD2<Float>(footprint, 0.0),
            SIMD2<Float>(-footprint, 0.0),
            SIMD2<Float>(0.0, footprint),
            SIMD2<Float>(0.0, -footprint),
            SIMD2<Float>(diagonal, diagonal),
            SIMD2<Float>(diagonal, -diagonal),
            SIMD2<Float>(-diagonal, diagonal),
            SIMD2<Float>(-diagonal, -diagonal)
        ]

        var samples: [(x: Float, z: Float, height: Float)] = []
        samples.reserveCapacity(offsets.count)
        var highestContact = -Float.greatestFiniteMagnitude
        for offset in offsets {
            guard let contact = sceneController.supportSurfaceContact(
                at: SIMD2<Float>(position.x + offset.x, position.z + offset.y),
                clearanceRadius: clearanceRadius,
                maximumHeight: maximumHeight
            ) else {
                continue
            }
            samples.append((offset.x, offset.y, contact.height))
            highestContact = max(highestContact, contact.height)
        }
        guard !samples.isEmpty else {
            return nil
        }
        // A contact well below the crest is seen through a gap, not something the gear rests on.
        let restBand = max(0.5, footprint * 1.5)
        samples.removeAll { highestContact - $0.height > restBand }
        guard samples.count >= 3 else {
            return SIMD3<Float>(0.0, 1.0, 0.0)
        }

        let count = Float(samples.count)
        var meanX: Float = 0.0, meanZ: Float = 0.0, meanH: Float = 0.0
        for sample in samples {
            meanX += sample.x
            meanZ += sample.z
            meanH += sample.height
        }
        meanX /= count
        meanZ /= count
        meanH /= count

        var sxx: Float = 0.0, szz: Float = 0.0, sxz: Float = 0.0
        var sxh: Float = 0.0, szh: Float = 0.0
        for sample in samples {
            let dx = sample.x - meanX
            let dz = sample.z - meanZ
            let dh = sample.height - meanH
            sxx += dx * dx
            szz += dz * dz
            sxz += dx * dz
            sxh += dx * dh
            szh += dz * dh
        }
        let determinant = sxx * szz - sxz * sxz
        guard abs(determinant) > 0.0001 else {
            return SIMD3<Float>(0.0, 1.0, 0.0)
        }
        // h(x, z) = slopeX·x + slopeZ·z + c  →  plane normal ∝ (−slopeX, 1, −slopeZ).
        let slopeX = (sxh * szz - szh * sxz) / determinant
        let slopeZ = (szh * sxx - sxh * sxz) / determinant
        return simd_normalize(SIMD3<Float>(-slopeX, 1.0, -slopeZ))
    }

    private var restSupportNormalLatch: (position: SIMD2<Float>, normal: SIMD3<Float>)?

    /// Set when a resting drone loses its elevated support (CG slid past a roof edge). While
    /// positive, elevated-support re-acquisition is suppressed so the falling airframe can't be
    /// re-caught by the same roof plane a few centimetres down — that fall/snap-up cycle reads
    /// as the drone pogo-bouncing in place at the eave. Once it has fallen clear, the height
    /// guard in the support queries keeps the roof invisible from below anyway.
    private var supportReacquireBlockTimer: Float = 0.0

    /// The support normal is latched at touchdown and reused while the drone stays parked on
    /// roughly the same spot. Re-deriving it every tick fed the conform target with sampling
    /// noise — on corrugated sheets the rib faces flip the queried normal side-to-side under
    /// millimetre drift, so the target attitude lurched left/right each tick and the copter
    /// visibly "danced". Latching breaks that tilt→thrust→drift feedback: the pose is decided
    /// once from the fitted contact plane and only re-derived after the drone leaves the
    /// surface or slides to a new patch.
    private func latchedRestSupportNormal() -> SIMD3<Float>? {
        let planar = SIMD2<Float>(state.position.x, state.position.z)
        let footprint = max(0.3, selectedDroneProfile.collisionRadius * 1.2)
        if let latch = restSupportNormalLatch,
           simd_distance(latch.position, planar) <= footprint * 0.75 {
            return latch.normal
        }
        guard let normal = fittedSupportPlaneNormal(at: state.position) else {
            restSupportNormalLatch = nil
            return nil
        }
        restSupportNormalLatch = (planar, normal)
        return normal
    }

    /// Roll/pitch (in the project's `yaw * pitch * roll` Euler convention, i.e.
    /// `orientation = (roll.x, pitch.y, yaw.z)`) that lays the drone flush against a
    /// support surface with the given world-space up-normal, accounting for current yaw.
    /// A flat surface (or `nil`) yields level `(0, 0)`, so ground / flat tops are unchanged.
    private func restAttitudeTargets(surfaceNormal: SIMD3<Float>?) -> (roll: Float, pitch: Float) {
        guard let rawNormal = surfaceNormal,
              simd_length_squared(rawNormal) > 0.0001 else {
            return (0.0, 0.0)
        }
        var normal = simd_normalize(rawNormal)
        if normal.y < 0.0 {
            normal = -normal
        }
        // Near-flat surface: keep level to avoid pointless micro-tilt.
        guard normal.y < 0.9995 else {
            return (0.0, 0.0)
        }

        // Cap the TOTAL tilt from vertical before deriving roll/pitch. Clamping roll and pitch
        // independently (the old approach) let them stack — e.g. 0.7 + 0.7 ≈ 54° on a roof viewed
        // diagonally — which laid the copter right over on steep barn roofs. Capping the normal's
        // deviation from vertical bounds the visible lean in every direction to one gentle value.
        let maxTilt: Float = 0.52 // ~30°
        let tiltFromVertical = acos(min(1.0, max(-1.0, normal.y)))
        if tiltFromVertical > maxTilt {
            let horizontal = SIMD2<Float>(normal.x, normal.z)
            let horizontalLength = simd_length(horizontal)
            if horizontalLength > 0.0001 {
                let cappedHorizontal = (horizontal / horizontalLength) * sin(maxTilt)
                normal = SIMD3<Float>(cappedHorizontal.x, cos(maxTilt), cappedHorizontal.y)
            }
        }

        let yaw = state.orientation.z
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        // Un-yaw the normal into the drone's heading frame, then invert the body-up
        // expression up = (-sinRoll, cosRoll·cosPitch, cosRoll·sinPitch).
        let localX = normal.x * cosYaw - normal.z * sinYaw
        let localZ = normal.x * sinYaw + normal.z * cosYaw
        let roll = -asin(min(1.0, max(-1.0, localX)))
        let cosRoll = max(0.2, cos(roll))
        let pitch = asin(min(1.0, max(-1.0, localZ / cosRoll)))
        return (roll, pitch)
    }

    private func heightAboveSupportSurface(for position: SIMD3<Float>) -> Float {
        position.y - supportSurfaceY(for: position)
    }

    /// Treats an elevated support surface (building roof, container / crate top) as a hard
    /// floor: the drone's gear reference is never allowed to sink below the surface under its
    /// current XZ. This is intentionally the *only* per-tick position constraint for such
    /// surfaces — it does not damp horizontal motion, level attitude, or force the drone down,
    /// so flying across a roof or taking off from one is unobstructed. Resting/settling once
    /// the drone is actually grounded is handled solely by `applyGroundedSafetyIfNeeded`, which
    /// mirrors the physics engine's own y=0 ground-rest contract at the elevated height.
    private func applySupportSurfaceConstraint(previousState: DroneState) {
        // A drowned airframe is not resting on anything — the surface below it is the water that
        // took it, and clamping to that is what kept the wreck floating.
        guard !isDrowned else { return }
        // See supportReacquireBlockTimer: a drone that just slid off a roof edge must fall clear,
        // not get re-clamped to the plane it left.
        guard supportReacquireBlockTimer <= 0.0 else {
            return
        }
        // Attitude-aware clearance (0 at rest attitude — the roof hard-floor
        // clamp contract `position.y == supportY` at rest is preserved; only
        // a tilted airframe rests higher, on its actual lowest structure).
        let clearance = vehicleGroundClearance()
        let supportY = supportSurfaceYIfAny(
            for: state.position,
            maximumHeight: max(previousState.position.y, state.position.y) +
                max(0.18, selectedDroneProfile.collisionRadius * 0.50)
        )
        guard let supportY, state.position.y < supportY + clearance else {
            return
        }

        // Only clamp a drone that was resting on / descending onto the surface. A drone that
        // is genuinely below it (e.g. flew in under an overhang) must not be shoved up through
        // the surface, so require it to have been at or above the surface on the previous tick —
        // except an uncontrolled crashed body, which has no "intentionally flew under it" reading:
        // stepUncontrolledBody's fall only ever stops at the flat world ground (it has no
        // knowledge of building geometry), so a fast post-crash tumble can cross a roof within
        // one tick and land on the far side of this guard. It must still be caught here rather
        // than left to free-fall through the structure's mesh toward world Y=0.
        let comeFromAboveTolerance = max(0.05, selectedDroneProfile.collisionRadius * 0.5)
        guard physicalState == .crashed ||
            previousState.position.y >= supportY + clearance - comeFromAboveTolerance else {
            return
        }

        state.position.y = supportY + clearance
        if state.velocity.y < 0.0 {
            state.velocity.y = 0.0
        }
    }

    /// ImpactResolutionService's live-flight default (0.01 m/s) treats almost any positive
    /// closing speed as a fresh collision worth a bounce impulse. That is correct while flying,
    /// but an uncontrolled crashed body can sit embedded against an obstacle (a building wall,
    /// a tree) where gravity re-creates a small positive closing speed every tick — with the
    /// live-flight threshold each of those re-triggers a full bounce, "dancing" the wreck in
    /// place indefinitely. stepUncontrolledBody already avoids this for the flat ground via its
    /// own resting/support-polygon branch; raising the threshold here gives the general
    /// obstacle-contact path the same "settled, not colliding" reading once armed control is
    /// gone, without weakening the live-flight collision response at all.
    private var crashResolutionRestingSpeedThreshold: Float {
        physicalState == .crashed ? 0.6 : 0.01
    }

    /// Rest-normalized ground clearance of the vehicle contact profile at the
    /// current attitude — see `VehicleContactProfile.groundClearanceOffset`.
    private func vehicleGroundClearance() -> Float {
        guard !vehicleContactProfile.isEmpty else {
            return 0.0
        }
        return vehicleContactProfile.groundClearanceOffset(
            orientation: attitudeQuaternion(of: state),
            restOrientation: VehicleContactProfile.restOrientation(for: selectedDroneProfile.airframeStyle)
        )
    }

    /// The attitude quaternion physics actually flies with: the fixed-wing
    /// quaternion for fixed-wing/hybrid airframes, Euler-composed for
    /// multirotors (same yaw*pitch*roll order as the physics engine).
    private func attitudeQuaternion(of droneState: DroneState) -> simd_quatf {
        switch selectedDroneProfile.airframeClass {
        case .fixedWing, .hybridVTOL:
            return droneState.fixedWingOrientationQuat
        case .multirotor:
            let yaw = simd_quatf(angle: droneState.orientation.z, axis: SIMD3<Float>(0.0, 1.0, 0.0))
            let pitch = simd_quatf(angle: droneState.orientation.y, axis: SIMD3<Float>(1.0, 0.0, 0.0))
            let roll = simd_quatf(angle: droneState.orientation.x, axis: SIMD3<Float>(0.0, 0.0, 1.0))
            return yaw * pitch * roll
        }
    }

    private func recommendedSafeSpawnRadius(for scale: MapScale) -> Float {
        switch scale {
        case .x4:
            return 10.0
        case .x8:
            return 12.0
        case .x16:
            return 15.0
        case .x32:
            return 18.0
        case .x64:
            return 22.0
        case .x128:
            return 26.0
        case .x256:
            return 30.0
        }
    }

    private func ensureSimulationRunning() {
        guard !isSimulationRunning else {
            return
        }
        isSimulationRunning = true
        lastTimestamp = nil
    }

    private func sanitizeDynamicStateForSpawn(context: String) {
        let hardReset = (context == "init" || context == "reset")
        let forceSpawnRelocation = hardReset || context == "signal_recovery"
        let spawn = currentSpawnPoint()
        let halfExtent = terrain.worldHalfExtent
        let maxAltitude = max(80.0, terrain.maxFlightAltitude)

        if forceSpawnRelocation {
            state.position = spawn
            state.orientation = spawnOrientation(for: selectedDroneProfile)
            homePosition = spawn
            seatAircraftInLaunchCradleIfAvailable()
        }

        if hardReset {
            weather = .normal
        }

        if !state.position.x.isFinite || !state.position.y.isFinite || !state.position.z.isFinite {
            state.position = spawn
        }
        if state.position.y < 0.0 || !state.position.y.isFinite {
            state.position.y = 0.0
        }
        state.position.x = state.position.x.clamped(to: -halfExtent...halfExtent)
        state.position.z = state.position.z.clamped(to: -halfExtent...halfExtent)
        state.position.y = state.position.y.clamped(to: 0.0...maxAltitude)

        state.velocity = SIMD3<Float>(repeating: 0.0)
        state.angularVelocity = SIMD3<Float>(repeating: 0.0)
        state.rotorAngularSpeed = SIMD4<Float>(repeating: 0.0)
        state.forwardAirspeed = 0.0
        isArmed = false
        state.throttle = 0.0
        state.motorThrottle = state.throttle
        transitionPhysicalState(.disarmed)
        setFlightMode(.manual, reason: "spawn_state_sanitized")
        state.mode = mode
        groundContactAccumulator = 0.0
        stableGroundAccumulator = 0.0
        airborneAccumulator = 0.0
        impactSeverityAccumulator = 0.0
        collisionAftermathState = .nominal
        signalLossCause = nil
        resetTerrainMapTrail()

        if weather.preset == .normal || hardReset {
            weather.intensity = 0.0
            weather.windSpeedMps = 0.0
            weather.gusts = 0.0
        }

        if state.position.y <= 0.05 {
            let restOrientation = spawnOrientation(for: selectedDroneProfile)
            state.orientation.x = restOrientation.x
            state.orientation.y = restOrientation.y
        }

        resyncFixedWingAttitudeFromEuler()
        lastFiniteState = state
    }

    private func spawnOrientation(for profile: DroneModelProfile) -> SIMD3<Float> {
        // A tailsitter rests nose-up on its tail (pitch = +90°), not flat —
        // matching the hover transition controller's rest target
        // (vtolTransitionProgress = 0 always demands pitch -> 90°).
        if profile.airframeStyle == .tailsitterVTOL {
            return SIMD3<Float>(0, .pi / 2, 0)
        }
        return .zero
    }

    /// Rebuilds `state.fixedWingOrientationQuat` from the current Euler
    /// `state.orientation` and zeroes `state.bodyAngularVelocity`.
    ///
    /// `SimpleDronePhysicsEngine`'s fixed-wing step treats the quaternion as
    /// authoritative (Euler `orientation` is just a derived display copy) so
    /// every place outside the physics step that forces `state.orientation`/
    /// `state.angularVelocity` to a specific value (spawn, launch sequence,
    /// disarm/ground settling, NaN recovery) must call this afterward.
    /// Otherwise the quaternion is left stale from whatever attitude the
    /// aircraft (or a previously-flown different aircraft) last had, and the
    /// next physics step applies thrust along that stale nose direction
    /// instead of the visually-reset one — looks like the aircraft barely
    /// moves even at full throttle.
    private func resyncFixedWingAttitudeFromEuler() {
        guard selectedDroneProfile.airframeClass == .fixedWing || selectedDroneProfile.airframeClass == .hybridVTOL else { return }
        state.fixedWingOrientationQuat = simd_quatf(angle: state.orientation.z, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: state.orientation.y, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: state.orientation.x, axis: SIMD3<Float>(0, 0, 1))
        state.bodyAngularVelocity = .zero
    }

    private func neutralControls(from state: DroneState) -> DroneControlValues {
        let baseline = resolvedFlightBaseline(for: .manual)
        let airborneThrottle = baseline.hoverCapable ? baseline.hoverLockThrottle : baseline.cruiseReferenceThrottle
        return DroneControlValues(
            x: Double(state.position.x),
            y: Double(max(0.0, state.position.y)),
            z: Double(state.position.z),
            roll: 0.0,
            pitch: 0.0,
            yaw: Double(state.orientation.z.radiansToDegrees),
            throttle: isArmed && state.position.y > 0.10 ? Double(airborneThrottle) : 0.0
        )
    }

    /// `collisionService.analyze()` / `resolveObstaclePenetration`'s "nearest obstacle distance"
    /// is a nearest-SURFACE-POINT query: a body resting in the middle of a room reads as "far
    /// from any obstacle" (a large positive clearance to whichever wall happens to be nearest),
    /// because the query only ever measures proximity to a surface, never containment. It can
    /// therefore never catch "trapped inside a building" the way it catches "overlapping a
    /// specific wall" — and `settleDisarmedGroundedState` only ever corrects Y (nearest
    /// support-surface height), trusting whatever X/Z the vehicle already has. A body that
    /// tunneled horizontally into a building (a fast swept step crossing a thin/gappy wall) is
    /// therefore left to settle calmly inside it forever, with nothing in the per-tick pipeline
    /// ever revisiting horizontal position once armed control is gone. This coarse footprint
    /// check — bounding circle + height band, both already computed per mesh obstacle for the
    /// swept/analysis paths, no new geometry — catches exactly that: if settling lands inside a
    /// building's overall footprint, shove it back out past the bounding radius instead of
    /// leaving it resting inside the walls. Deliberately approximate (the circumscribing circle
    /// over-covers a rectangular footprint's corners) — acceptable because this only fires once,
    /// at the rare moment of settling to a full stop, not every tick.
    private func ejectFromEnclosingBuildingFootprintIfNeeded() {
        let obstacles = sceneController.nearbyEnvironmentObstacles(
            near: state.position,
            radius: collisionService.spatialQueryRadius
        )
        let planar = SIMD2<Float>(state.position.x, state.position.z)

        // Being inside a bounding circle is not being inside a building.
        //
        // That test was written when every mesh obstacle was a discrete structure, so "inside the
        // circle, within the height band" could only mean trapped indoors. An imported
        // photogrammetric world breaks the assumption completely: its obstacles are 24 m *terrain
        // cells*, and an aircraft parked on open ground is inside its own cell's circle and height
        // band by definition. It was therefore shoved out past the cell radius, landed in the
        // neighbouring cell, was shoved again, and cascaded roughly 70 m off the pad into the
        // harbour — deterministically, on every session, before the pilot had even armed.
        //
        // What actually distinguishes indoors is a roof: something solid directly overhead. An
        // aircraft standing on terrain or on a rooftop has nothing above it and is left alone.
        let overheadClearanceRequired = max(1.5, selectedDroneProfile.collisionRadius * 3.0)
        let highestHere = sceneController.supportSurfaceHeight(
            at: planar,
            clearanceRadius: max(0.05, selectedDroneProfile.collisionRadius * 0.12),
            maximumHeight: .greatestFiniteMagnitude
        )
        guard let highestHere, highestHere > state.position.y + overheadClearanceRequired else {
            return
        }

        for obstacle in obstacles where obstacle.hasMeshCollision {
            guard state.position.y >= obstacle.baseY, state.position.y <= obstacle.topY else {
                continue
            }
            let toDrone = planar - obstacle.planarCenter
            let distance = simd_length(toDrone)
            guard distance < obstacle.radius else { continue }

            let outward = distance > 0.001 ? toDrone / distance : SIMD2<Float>(1.0, 0.0)
            let pushedPlanar = obstacle.planarCenter +
                outward * (obstacle.radius + max(0.3, selectedDroneProfile.collisionRadius))
            state.position.x = pushedPlanar.x
            state.position.z = pushedPlanar.y
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: .vehicleSettled,
                colliderID: obstacle.id.uuidString,
                worldPoint: state.position,
                reason: "ejected_from_building_footprint"
            )
        }
    }

    private func settleDisarmedGroundedState() {
        ejectFromEnclosingBuildingFootprintIfNeeded()
        let hasPhysicalDamage = componentGraph.components.contains {
            !$0.isAttached || $0.integrity < 0.999 || $0.residualStrength < 0.999
        }
        state.position.y = supportSurfaceY(for: state.position) +
            (hasPhysicalDamage ? vehicleGroundClearance() : 0.0)
        state.velocity = .zero
        state.angularVelocity = .zero
        state.rotorAngularSpeed = .zero
        state.forwardAirspeed = 0.0
        state.throttle = 0.0
        state.motorThrottle = 0.0
        if !hasPhysicalDamage {
            let restOrientation = spawnOrientation(for: selectedDroneProfile)
            state.orientation.x = restOrientation.x
            state.orientation.y = restOrientation.y
            resyncFixedWingAttitudeFromEuler()
        }
        setFlightMode(.manual, reason: "settle_disarmed_grounded")
        state.mode = mode
        collisionCooldown = 0.0
        groundContactAccumulator = max(groundContactAccumulator, 0.5)
        stableGroundAccumulator = max(stableGroundAccumulator, 0.5)
        airborneAccumulator = 0.0
        transitionPhysicalState(.disarmed)
        controlValues = neutralControls(from: state)
    }

    private func transitionPhysicalState(_ newState: DronePhysicalState) {
        guard physicalState != newState || state.physicalState != newState else {
            return
        }
        physicalState = newState
        state.physicalState = newState
    }

    private func updatePhysicalState(previousState: DroneState, deltaTime: Float) {
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let angularSpeed = simd_length(state.angularVelocity)
        let supportY = supportSurfaceY(for: state.position)
        let previousSupportY = supportSurfaceY(for: previousState.position)
        // Contact-aware: a tilted/tipped airframe rests with its origin at
        // clearance(attitude) above the support (phase-1 ground clamp), so
        // every height threshold here must include it. Without this, a
        // tipped-over copter (clearance > 0.08) never read as nearGround,
        // never met severeAttitudeOnGround -> never crashed, and kept
        // thrashing on the ground under power; a fixed-wing that touched
        // down slightly rolled never reached .landed and never leveled.
        let groundClearance = vehicleGroundClearance()
        let nearGround = (state.position.y - supportY) <= groundClearance + 0.08
        let stableGroundContact = nearGround &&
            abs(state.velocity.y) <= 0.24 &&
            planarSpeed <= 0.75 &&
            angularSpeed <= 1.8
        let confidentlyAirborne = (state.position.y - supportY) >= groundClearance + 0.18 ||
            (!nearGround && abs(state.velocity.y) > 0.28)
        let groundedBaseline = resolvedFlightBaseline(for: mode)
        let takeoffThrottleThreshold = groundedBaseline.groundedTakeoffThreshold
        let lowThrottle = max(Float(controlValues.throttle), state.throttle, state.motorThrottle) <= groundedBaseline.groundedIdleThreshold

        if nearGround {
            groundContactAccumulator += deltaTime
        } else {
            groundContactAccumulator = 0.0
        }

        if stableGroundContact {
            stableGroundAccumulator += deltaTime
        } else {
            stableGroundAccumulator = 0.0
        }

        if confidentlyAirborne {
            airborneAccumulator += deltaTime
        } else {
            airborneAccumulator = 0.0
        }

        if previousState.position.y > previousSupportY + groundClearance + 0.06,
           state.position.y <= supportY + groundClearance + 0.02 {
            // Same tailsitter carve-out as severeAttitudeOnGround below: a
            // correct nose-up touchdown (pitch ~ +90°) shouldn't itself
            // count as impact severity — measure deviation from the
            // expected rest pitch instead of raw magnitude.
            let pitchSeverityTerm: Float = selectedDroneProfile.airframeStyle == .tailsitterVTOL
                ? abs(abs(previousState.orientation.y) - .pi / 2)
                : abs(previousState.orientation.y)
            let touchdownSeverity =
                abs(previousState.velocity.y) * 1.45 +
                simd_length(SIMD2<Float>(previousState.velocity.x, previousState.velocity.z)) * 0.72 +
                simd_length(previousState.angularVelocity) * 0.42 +
                (abs(previousState.orientation.x) + pitchSeverityTerm) * 0.45
            impactSeverityAccumulator = max(impactSeverityAccumulator, touchdownSeverity)
        }

        // A tailsitter's *correct* rest attitude is nose-up (pitch ~ +90°) —
        // unlike every other airframe, where any such pitch on the ground
        // can only mean it tipped over. Flagging raw pitch magnitude here
        // treated a perfectly normal, correctly-resting Wingtra as crashed
        // within ~0.12s of settling, forcing a repeated arm -> instantly
        // "crashed" -> auto-disarm loop (the "can't even take off" / shaking
        // the user reported — each arm attempt produced a thrust pulse
        // before being killed). Roll is unambiguous either way — tipping
        // onto a wingtip is never correct — so only that still counts.
        let severeAttitudeOnGround: Bool
        if selectedDroneProfile.airframeStyle == .tailsitterVTOL {
            severeAttitudeOnGround = nearGround && abs(state.orientation.x) > 1.22
        } else {
            severeAttitudeOnGround = nearGround && (abs(state.orientation.x) > 1.22 || abs(state.orientation.y) > 1.22)
        }
        let hasCrashCondition =
            physicalState == .crashed ||
            (severeAttitudeOnGround && groundContactAccumulator > 0.12)

        let nextPhysicalState: DronePhysicalState
        if hasCrashCondition {
            nextPhysicalState = .crashed
        } else if !isArmed {
            nextPhysicalState = .disarmed
        } else if nearGround {
            if mode == .takeoff || Float(controlValues.throttle) >= takeoffThrottleThreshold {
                nextPhysicalState = .takeoffTransition
            } else if mode == .landing || stableGroundAccumulator > 0.28 {
                nextPhysicalState = stableGroundAccumulator > 0.28 ? .landed : .landing
            } else if groundContactAccumulator > 0.06 || lowThrottle {
                nextPhysicalState = .armedOnGround
            } else {
                nextPhysicalState = physicalState
            }
        } else if confidentlyAirborne || airborneAccumulator > 0.08 {
            nextPhysicalState = (mode == .landing) ? .landing : .airborne
        } else {
            nextPhysicalState = physicalState
        }

        #if DEBUG
        if nextPhysicalState == .crashed, physicalState != .crashed {
            print(
                "[CrashDetect] → crashed: impactSev=\(impactSeverityAccumulator) " +
                "damageCritical=\(damageState.isFlightCritical) " +
                "severeAttitudeOnGround=\(severeAttitudeOnGround) groundContact=\(groundContactAccumulator) " +
                "ori=\(state.orientation) pos=\(state.position) supportY=\(supportY) " +
                "vel=\(state.velocity) source=\(lastCollisionSource)"
            )
        }
        #endif

        transitionPhysicalState(nextPhysicalState)
        updateOrthogonalPhysicalStates(
            nearGround: nearGround,
            planarSpeed: planarSpeed,
            angularSpeed: angularSpeed,
            stableGroundContact: stableGroundContact
        )

        if nextPhysicalState == .crashed, isArmed {
            // preserveCrashDynamics: the crash disarm must NOT run
            // settleDisarmedGroundedState (snap-to-ground, zeroed velocities,
            // leveled attitude — the old "teleports onto the ground" bug).
            // The ordinary airframe solver carries the disarmed aircraft to
            // rest while retaining surviving aero and asymmetric drag.
            disarm(forceEmergency: true, preserveCrashDynamics: true)
        }
    }

    private func updateOrthogonalPhysicalStates(
        nearGround: Bool,
        planarSpeed: Float,
        angularSpeed: Float,
        stableGroundContact: Bool
    ) {
        let previousMotionState = state.motionState
        let previousControlState = state.controlState
        state.armState = isArmed ? .armed : .disarmed

        if nearGround {
            if terrain.preset.rawValue.lowercased().contains("water") {
                state.motionState = .floating
            } else if stableGroundContact,
                      stableGroundAccumulator >= 0.35,
                      planarSpeed < 0.12,
                      angularSpeed < 0.20 {
                state.motionState = .settled
            } else if angularSpeed > 1.2 {
                state.motionState = .rolling
            } else if planarSpeed > 0.18 {
                state.motionState = .sliding
            } else {
                state.motionState = .grounded
            }
        } else if angularSpeed > 1.8 {
            state.motionState = .tumbling
        } else if state.velocity.y < -0.55 {
            state.motionState = .falling
        } else {
            state.motionState = .airborne
        }

        let flightCriticalKinds = componentGraph.attachedComponents.filter { component in
            switch component.kind {
            case .frame, .fuselage, .arm, .motor, .propeller, .battery,
                 .flightController, .esc, .radio, .wingSection,
                 .tailSection, .horizontalTail, .verticalTail, .elevator, .rudder:
                return true
            case .cameraGimbal, .payloadMount, .landingGear:
                return false
            }
        }
        let criticalMinimumIntegrity = flightCriticalKinds.map(\.integrity).min() ?? 1.0
        let hasCriticalDetachment = componentGraph.components.contains { component in
            guard !component.isAttached else { return false }
            switch component.kind {
            case .frame, .fuselage, .arm, .motor, .propeller, .battery,
                 .flightController, .esc, .radio, .wingSection,
                 .tailSection, .horizontalTail, .verticalTail, .elevator, .rudder:
                return true
            case .cameraGimbal, .payloadMount, .landingGear:
                return false
            }
        }
        let hasAnyDamage = componentGraph.components.contains {
            !$0.isAttached || $0.integrity < 0.985 || $0.residualStrength < 0.985
        }
        let frameLost = componentGraph.integrity(id: "frame") <= 0.001 ||
            componentGraph.integrity(id: "fuselage") <= 0.001
        let controllerLost = componentGraph.integrity(id: "flightController") <= 0.05 ||
            componentFailureRuntime.functionalFactor(componentID: "flightController") <= 0.20
        let powerLost = componentGraph.integrity(id: "battery") <= 0.001 ||
            componentFailureRuntime.functionalFactor(componentID: "battery") <= 0.20

        if frameLost {
            state.damageCondition = .destroyed
        } else if controllerLost || powerLost {
            state.damageCondition = .uncontrolled
        } else if hasCriticalDetachment || criticalMinimumIntegrity < 0.22 {
            state.damageCondition = .critical
        } else if hasAnyDamage || !componentFailureRuntime.isEmpty {
            state.damageCondition = .degraded
        } else {
            state.damageCondition = .nominal
        }

        let availableRotorFraction: Float
        if vehicleRotorModel.rotors.isEmpty {
            availableRotorFraction = 1.0
        } else {
            availableRotorFraction = vehicleRotorModel.rotors.reduce(0.0) { $0 + $1.thrustFactor } /
                Float(vehicleRotorModel.rotors.count)
        }
        let radioFactor = componentFailureRuntime.functionalFactor(componentID: "radio")
        let radioLost = componentGraph.integrity(id: "radio") <= 0.05 || radioFactor <= 0.20
        let fixedWingSurfaceAuthority = min(
            vehicleAeroDamage.aileronScale,
            vehicleAeroDamage.elevatorScale,
            vehicleAeroDamage.rudderScale
        )
        let hasSeizedSurface = !componentFailureRuntime.jammedSurfaces().isEmpty
        if controllerLost || powerLost || frameLost {
            state.controlState = .none
        } else if availableRotorFraction < 0.35 || fixedWingSurfaceAuthority < 0.25 {
            state.controlState = .insufficient
        } else if radioLost || hasCriticalDetachment || fixedWingSurfaceAuthority < 0.60 {
            state.controlState = .emergency
        } else if state.damageCondition == .degraded || !vehicleAeroDamage.isPristine || hasSeizedSurface {
            state.controlState = .reduced
        } else {
            state.controlState = .full
        }

        if previousControlState != state.controlState,
           state.controlState != .full {
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: state.controlState == .none ? .controlAuthorityLost : .controlAuthorityReduced,
                reason: "control_authority_\(state.controlState.rawValue)"
            )
        }
        if previousMotionState != .settled,
           state.motionState == .settled,
           (state.damageCondition != .nominal || replayStopPendingAfterDisarm) {
            damageEventRecorder.record(
                timestamp: TimeInterval(simulationTime),
                type: .vehicleSettled,
                reason: "vehicle_motion_settled"
            )
        }
    }

    /// Recovery/forced-landing decisions use flight-relevant graph state,
    /// not the legacy minimum across camera, payload and landing gear.
    private var hasFlightCriticalGraphDamage: Bool {
        guard !componentGraph.isEmpty else { return damageState.isFlightCritical }

        let unavailableCore = ["frame", "fuselage", "battery", "flightController", "esc"].contains { id in
            guard componentGraph.component(id: id) != nil else { return false }
            let threshold: Float = id == "frame" || id == "fuselage" ? 0.001 : 0.05
            return componentGraph.integrity(id: id) <= threshold
        }
        if unavailableCore { return true }
        if componentFailureRuntime.functionalFactor(componentID: "battery") <= 0.20 ||
            componentFailureRuntime.functionalFactor(componentID: "flightController") <= 0.20 {
            return true
        }

        let criticalDetachment = componentGraph.components.contains { component in
            guard !component.isAttached else { return false }
            switch component.kind {
            case .frame, .fuselage, .arm, .motor, .propeller, .battery,
                 .flightController, .esc, .wingSection, .tailSection,
                 .horizontalTail, .verticalTail, .elevator, .rudder:
                return true
            case .radio, .cameraGimbal, .payloadMount, .landingGear:
                return false
            }
        }
        if criticalDetachment { return true }

        guard !vehicleRotorModel.rotors.isEmpty else { return false }
        let availableRotorFraction = vehicleRotorModel.rotors.reduce(Float(0.0)) {
            $0 + $1.thrustFactor
        } / Float(vehicleRotorModel.rotors.count)
        return availableRotorFraction < 0.35
    }

    private func applyGroundedSafetyIfNeeded(deltaTime: Float) {
        if maintainLaunchCradleHoldIfNeeded() {
            return
        }
        let contact = supportSurfaceContact(for: state.position)
        let supportY = contact?.height ?? 0.0
        guard state.position.y <= supportY + vehicleGroundClearance() + 0.08 else {
            // A resting drone whose support VANISHED (as opposed to one climbing away from a
            // still-present surface) has slid past a roof edge — arm the re-acquisition block.
            if restSupportNormalLatch != nil, contact == nil {
                supportReacquireBlockTimer = 0.6
            }
            restSupportNormalLatch = nil
            return
        }
        if supportReacquireBlockTimer > 0.0, supportY > 0.0 {
            // Just slid off an eave: let the airframe fall clear of the plane instead of
            // re-settling onto it a few centimetres down (pogo-bounce). Flat-ground settling
            // (supportY == 0) is unaffected.
            restSupportNormalLatch = nil
            return
        }

        let commandedThrottle = Float(controlValues.throttle)
        let requestedThrottle = max(commandedThrottle, state.throttle, state.motorThrottle)
        let idleHoldThreshold = resolvedFlightBaseline(for: mode).groundedIdleThreshold
        let takeoffThreshold = resolvedFlightBaseline(for: mode).groundedTakeoffThreshold
        let onElevatedSupport = contact != nil && supportY > 0.0
        // Pilot intent (commanded throttle), not the lagging motor spin-down, decides whether the
        // aircraft is settling or leaving. Using the motor/state throttle kept the slope conform
        // switched off while the rotors were still winding down through a landing — the drone
        // jittered level until they finally dropped below the threshold.
        let spoolingUpForTakeoff = commandedThrottle >= takeoffThreshold

        var holdRestAttitude = false

        switch physicalState {
        case .takeoffTransition:
            restSupportNormalLatch = nil
            return
        case .airborne, .landing:
            // Bridge the touchdown gap: once genuinely in contact with an elevated support
            // surface (and not spooling up to leave), conform + gently settle even before the
            // state machine reports .armedOnGround/.landed — that needs ~0.28 s of stable
            // contact, during which the physics step keeps leveling the attitude while the floor
            // clamp holds Y, so the drone visibly jitters on the slope until it fully stops.
            // Flat-ground landings stay on the engine's own ground handling as before.
            guard selectedDroneProfile.airframeClass == .multirotor,
                  onElevatedSupport,
                  !spoolingUpForTakeoff else {
                restSupportNormalLatch = nil
                return
            }
            state.position.y = supportY
            if state.velocity.y < 0.0 {
                state.velocity.y = 0.0
            }
            state.velocity.x *= max(0.0, 1.0 - deltaTime * 10.0)
            state.velocity.z *= max(0.0, 1.0 - deltaTime * 10.0)
            state.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - deltaTime * 12.0))
            holdRestAttitude = true
        case .crashed:
            // Motors are dead, but the regular airframe solver still owns
            // motion — no snapping to the support height and no velocity
            // zeroing (the old teleport-flat behavior).
            // applySupportSurfaceConstraint keeps it from sinking through an
            // elevated support at its actual lowest structure.
            state.throttle = 0.0
            state.motorThrottle = 0.0
            restSupportNormalLatch = nil
            return
        case .disarmed, .armedOnGround, .landed:
            let preserveRecentContactMotion = stableGroundAccumulator < 0.35 &&
                (groundImpactCooldown > 0.0 || collisionAftermathState != .nominal)
            if preserveRecentContactMotion {
                restSupportNormalLatch = nil
                return
            }
            if !isArmed {
                let preservePhysicalAftermath = stableGroundAccumulator < 0.35 && (
                    replayStopPendingAfterDisarm ||
                    state.damageCondition != .nominal ||
                    simd_length(state.velocity) > 0.16 ||
                    simd_length(state.angularVelocity) > 0.22 ||
                    simd_length(state.bodyAngularVelocity) > 0.22
                )
                if preservePhysicalAftermath {
                    state.throttle = 0.0
                    state.motorThrottle = 0.0
                    restSupportNormalLatch = nil
                    return
                }
                settleDisarmedGroundedState()
                return
            }
            state.position.y = supportY
            state.velocity.x *= max(0.0, 1.0 - deltaTime * 14.0)
            state.velocity.z *= max(0.0, 1.0 - deltaTime * 14.0)
            state.velocity.y = 0.0
            state.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - deltaTime * 18.0))

            // Hold the resting attitude across the whole parked throttle range (a drone sitting on
            // a surface still carries idle-to-near-hover throttle); release only when the pilot
            // actually commands takeoff throttle, matching the .takeoffTransition flip so there is
            // no conform/release flip-flop.
            holdRestAttitude = physicalState == .disarmed || !spoolingUpForTakeoff

            if physicalState == .disarmed {
                state.throttle = 0.0
                state.motorThrottle = 0.0
                state.rotorAngularSpeed = .zero
            } else if requestedThrottle <= idleHoldThreshold {
                state.throttle = min(state.throttle, 0.08)
                state.motorThrottle = min(state.motorThrottle, 0.08)
            }
        }

        // Touchdown-latched, plane-fitted contact normal (see latchedRestSupportNormal); a roof
        // ridge fits ~level, corrugated ribs and uneven planks collapse to their overall plane.
        // Fixed-wing keeps its own level belly-landing behaviour.
        let restAttitude: (roll: Float, pitch: Float)
        if holdRestAttitude, selectedDroneProfile.airframeClass == .multirotor {
            restAttitude = restAttitudeTargets(surfaceNormal: latchedRestSupportNormal())
        } else {
            restSupportNormalLatch = nil
            restAttitude = (0.0, 0.0)
        }

        if holdRestAttitude {
            state.orientation.x = approach(current: state.orientation.x, target: restAttitude.roll, rate: 5.8, dt: deltaTime)
            state.orientation.y = approach(current: state.orientation.y, target: restAttitude.pitch, rate: 5.8, dt: deltaTime)
        }

        if simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z)) < 0.02 {
            state.velocity.x = 0.0
            state.velocity.z = 0.0
        }
        if simd_length(state.angularVelocity) < 0.02 {
            state.angularVelocity = .zero
        }
        if holdRestAttitude {
            if abs(state.orientation.x - restAttitude.roll) < 0.0005 { state.orientation.x = restAttitude.roll }
            if abs(state.orientation.y - restAttitude.pitch) < 0.0005 { state.orientation.y = restAttitude.pitch }
        }
        resyncFixedWingAttitudeFromEuler()
    }

    private func approach(current: Float, target: Float, rate: Float, dt: Float) -> Float {
        if current < target {
            return min(target, current + rate * dt)
        }
        return max(target, current - rate * dt)
    }

    private func emitLaunchDiagnostics(context: String) {
        let controllerType = selectedDroneProfile.airframeClass == .multirotor ? "multirotor_baseline" : "fixedwing_baseline"
        let f = weather.effectiveFactors
        let motors = state.rotorAngularSpeed
        print(
            "[LaunchDiagnostics][\(context)] " +
            "pos=\(state.position) ori=\(state.orientation) vel=\(state.velocity) angVel=\(state.angularVelocity) " +
            "controller=\(controllerType) mode=\(mode.rawValue) weather=\(weather.preset.rawValue) " +
            "wind=\(weather.windVector) turb=\(f.turbulenceFactor) motors=[\(motors.x),\(motors.y),\(motors.z),\(motors.w)]"
        )
    }

    private func logAvailableUAVCatalog(models: [DroneModelProfile]) {
        let duplicateIDs = Dictionary(grouping: models, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()

        print("[UAVCatalog][UIAvailable] count=\(models.count)")
        for profile in models {
            let family = profile.fixedWingParameters?.family.rawValue ?? "n/a"
            print(
                "[UAVCatalog][UI] id=\(profile.id) name=\(profile.displayName) " +
                "category=\(profile.operationalCategory.rawValue) airframe=\(profile.airframeClass.rawValue) " +
                "style=\(profile.airframeStyle.rawValue) visual=\(profile.visualClass.rawValue) family=\(family) " +
                "launch=\(profile.launchMethod.rawValue) landing=\(profile.landingMethod.rawValue) " +
                "maxSpeed=\(profile.maxHorizontalSpeedMps)mps collisionRadius=\(profile.collisionRadius)m"
            )
        }

        let availableVisuals = Set(models.map(\.visualClass))
        let codeOnlyVisuals = DroneVisualClass.allCases
            .filter { !availableVisuals.contains($0) }
            .map(\.rawValue)
            .sorted()
        let availableFamilies = Set(models.compactMap { $0.fixedWingParameters?.family })
        let codeOnlyFamilies = FixedWingFamily.allCases
            .filter { !availableFamilies.contains($0) }
            .map(\.rawValue)
            .sorted()

        print("[UAVCatalog][CodeOnlyVisualClasses] \(codeOnlyVisuals.isEmpty ? "none" : codeOnlyVisuals.joined(separator: ", "))")
        print("[UAVCatalog][CodeOnlyFixedWingFamilies] \(codeOnlyFamilies.isEmpty ? "none" : codeOnlyFamilies.joined(separator: ", "))")
        if duplicateIDs.isEmpty {
            print("[UAVCatalog][Duplicates] none")
        } else {
            print("[UAVCatalog][Duplicates] \(duplicateIDs.joined(separator: ", "))")
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension DroneFlightMode {
    var isAutoControlled: Bool {
        switch self {
        case .autoPath, .returnHome:
            return true
        case .manual, .hover, .emergencyStop, .takeoff, .landing:
            return false
        }
    }
}

// MARK: - Mission Replay Recording

private extension DroneSimulationViewModel {

    func missionReplayTimestamp() -> TimeInterval {
        guard let startedAt = missionReplayRecorder.currentSessionStartedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func updateMissionReplayLifecycle() {
        let currentArmedState = isArmed

        if !previousReplayArmedState && currentArmedState {
            if !missionReplayRecorder.isRecording {
                missionReplayRecorder.startSession(timestamp: 0, context: makeMissionReplayContextSnapshot())
            }
            replayStopPendingAfterDisarm = false
            isMissionReplayRecording = true
            previousReplayWarningMessages = []
            recordMissionReplayEvent(.armed, message: "UAV armed")
        } else if previousReplayArmedState && !currentArmedState {
            recordMissionReplayEvent(.disarmed, message: "UAV disarmed")
            // Keep recording the physical aftermath. A motor/FC failure can
            // disarm the vehicle high in the air; the fall, secondary ground
            // impact and final rest belong to the same replay session.
            replayStopPendingAfterDisarm = true
        }

        if replayStopPendingAfterDisarm,
           !currentArmedState,
           state.motionState == .settled,
           stableGroundAccumulator >= 0.45,
           missionReplayRecorder.isRecording {
            let ts = missionReplayTimestamp()
            missionReplayRecorder.stopSession(timestamp: ts)
            lastMissionReplaySession = missionReplayRecorder.lastCompletedSession
            if let session = missionReplayRecorder.lastCompletedSession {
                let report = missionReportBuilder.buildReport(from: session)
                lastMissionReport = report
                replayLibraryViewModel.saveAndEnforce(session: session, report: report)
            }
            isMissionReplayRecording = false
            replayStopPendingAfterDisarm = false
        }
        previousReplayArmedState = currentArmedState

        let currentAutopilotActive = missionExecutionState.status == .running || autoNavigationController.isActive
        if !previousReplayAutopilotActive && currentAutopilotActive {
            recordMissionReplayEvent(.autopilotEnabled, message: "Autopilot enabled: \(mode.rawValue)")
        } else if previousReplayAutopilotActive && !currentAutopilotActive {
            recordMissionReplayEvent(.autopilotDisabled, message: "Autopilot disabled: \(mode.rawValue)")
        }
        previousReplayAutopilotActive = currentAutopilotActive
    }

    func recordMissionReplayFrameIfNeeded() {
        guard missionReplayRecorder.isRecording else { return }
        let isAutopilotActive = missionExecutionState.status == .running || autoNavigationController.isActive
        let autopilotDescription: String? = isAutopilotActive ? mode.rawValue : nil
        let frame = MissionReplayFrame(
            id: UUID(),
            timestamp: missionReplayTimestamp(),
            position: CodableVector3D(state.position),
            velocity: CodableVector3D(state.velocity),
            attitude: MissionAttitudeSnapshot(
                rollRadians: Double(state.orientation.x),
                pitchRadians: Double(state.orientation.y),
                yawRadians: Double(state.orientation.z)
            ),
            flightModeDescription: mode.rawValue,
            autopilotDescription: autopilotDescription,
            activeWaypointIndex: missionExecutionState.activeWaypointIndex,
            batteryPercent: Double(batteryState.chargePercent),
            payloadStatusDescription: payloadStatusMessageKey,
            warningCount: warnings.count
        )
        missionReplayRecorder.recordFrame(frame)
    }

    func recordMissionReplayWarningsIfNeeded() {
        guard missionReplayRecorder.isRecording else { return }
        let current = Set(warnings)
        let newWarnings = current.subtracting(previousReplayWarningMessages)
        for warning in newWarnings {
            recordMissionReplayEvent(.warning, message: warning)
        }
        previousReplayWarningMessages = current
    }

    func recordMissionReplayEvent(
        _ type: MissionReplayEventType,
        message: String,
        position: SIMD3<Float>? = nil,
        damage: MissionReplayDamagePayload? = nil
    ) {
        guard missionReplayRecorder.isRecording else { return }
        let event = MissionReplayEvent(
            id: UUID(),
            timestamp: missionReplayTimestamp(),
            type: type,
            message: message,
            position: CodableVector3D(position ?? state.position),
            damage: damage
        )
        missionReplayRecorder.recordEvent(event)
    }

    func makeMissionReplayContextSnapshot() -> MissionReplayContextSnapshot {
        MissionReplayContextSnapshot(
            projectName: currentProjectName,
            selectedDroneProfileID: selectedDroneProfile.id,
            selectedDroneProfileName: selectedDroneProfile.displayName,
            selectedUAVProfileID: activeUAVProfile?.id,
            selectedUAVProfileName: activeUAVProfile?.displayName,
            workbenchBuild: selectedDroneProfile.workbenchBuild,
            terrainPresetRawValue: terrain.preset.rawValue,
            mapScaleRawValue: terrain.mapScale.rawValue,
            terrainSeed: terrain.seed,
            weatherPresetRawValue: weather.preset.rawValue,
            payloadTypeRawValue: payloadMountState == .occupied ? payloadDraftConfiguration.payloadType.rawValue : nil,
            payloadResolvedName: payloadMountState == .occupied ? payloadDraftConfiguration.resolvedName : nil,
            hasPayloadAttachedAtStart: payloadMountState == .occupied,
            recordedAtAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }
}

private extension Float {
    var radiansToDegrees: Float {
        self * 180.0 / .pi
    }

    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
