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
            controlMode: controlMode
        )
    }

    private func resolveYawRouting() -> YawRouting {
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

private struct DroneWarningBuilder {
    let isArmed: Bool
    let physicalState: DronePhysicalState
    let collisionAnalysis: CollisionAnalysisSnapshot
    let weather: WeatherModel
    let batteryState: BatteryState
    let damageState: DamageState
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
        if damageState.averageHealth <= 0.70 { output.append("warning.integrity_low") }
        if damageState.isFlightCritical { output.append("warning.integrity_critical") }
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
    case signalLost
    case recoveryPending

    var isCountdownActive: Bool {
        switch self {
        case .outOfBoundsWarning, .signalDegrading:
            return true
        case .normal, .signalLost, .recoveryPending:
            return false
        }
    }

    var isInteractionBlocking: Bool {
        switch self {
        case .signalLost, .recoveryPending:
            return true
        case .normal, .outOfBoundsWarning, .signalDegrading:
            return false
        }
    }
}

struct SignalInterferencePresentation: Equatable {
    let state: UAVSignalState
    let countdownText: String?
    let intensity: Double
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

private enum SignalLossConfiguration {
    static let countdownDuration = 8
    static let reentryInset: Float = 8.0
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
    struct TerrainMapMissionWaypoint: Identifiable, Equatable {
        let id: UUID
        let label: String
        let position: SIMD2<Float>
        let isActive: Bool
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
        let worldHalfExtent: Float
        let signalBoundaryRadius: Float
        let dockPosition: SIMD2<Float>
        let dronePosition: SIMD2<Float>
        let droneYawRadians: Float
        let droneAltitude: Float
        let targetMarkerPosition: SIMD2<Float>?
        let missionRoutePoints: [SIMD2<Float>]
        let missionWaypoints: [TerrainMapMissionWaypoint]
        let noFlyZones: [MissionZone]
        let trail: [SIMD2<Float>]
        let objects: [TerrainMapObject]

        static let empty = TerrainMapSnapshot(
            preset: TerrainConfiguration.default.preset,
            worldHalfExtent: TerrainConfiguration.default.worldHalfExtent,
            signalBoundaryRadius: TerrainConfiguration.default.signalBoundaryRadius,
            dockPosition: SIMD2<Float>(repeating: 0.0),
            dronePosition: SIMD2<Float>(repeating: 0.0),
            droneYawRadians: 0.0,
            droneAltitude: 0.0,
            targetMarkerPosition: nil,
            missionRoutePoints: [],
            missionWaypoints: [],
            noFlyZones: [],
            trail: [],
            objects: []
        )
    }
}

@MainActor
final class DroneSimulationViewModel: ObservableObject {
    @Published private(set) var controlValues: DroneControlValues
    @Published private(set) var telemetry: TelemetrySnapshot
    @Published private(set) var mode: DroneFlightMode
    @Published private(set) var flightControlMode: FlightControlMode
    @Published private(set) var isSimulationRunning: Bool
    @Published private(set) var currentProjectID: String
    @Published private(set) var currentProjectName: String
    @Published private(set) var hasUnsavedChanges: Bool

    @Published private(set) var availableDroneProfiles: [DroneModelProfile]
    @Published private(set) var selectedDroneProfile: DroneModelProfile
    @Published private(set) var activeUAVProfile: UAVProfile?
    @Published private(set) var uavCatalogFilterState: UAVFilterState
    @Published private(set) var abstractParameters: AbstractDroneParameters

    @Published private(set) var weather: WeatherModel
    @Published private(set) var terrain: TerrainConfiguration
    @Published private(set) var cameraConfiguration: CameraConfiguration

    private(set) var batteryState: BatteryState
    private(set) var collisionAnalysis: CollisionAnalysisSnapshot
    @Published private(set) var damageState: DamageState
    private(set) var thermalState: ThermalState
    @Published private(set) var fleetStatus: FleetStatus

    @Published private(set) var warnings: [String]
    @Published private(set) var diagnostics: SimulationDiagnostics
    @Published private(set) var lastCollisionSource: String
    @Published var collisionDebugEnabled: Bool
    @Published var showBatteryDepletedDialog: Bool
    @Published var diagnosticMode: DiagnosticOverlayMode
    @Published var isToolPanelVisible: Bool
    @Published var isParametersPanelVisible: Bool
    @Published var activeControlModule: ControlModule?
    @Published private(set) var isPayloadPanelVisible: Bool
    @Published var isBoundaryBarrierVisible: Bool
    @Published var isCompactTelemetryHUDEnabled: Bool
    @Published var telemetryExportAlert: TelemetryExportAlert?
    @Published private(set) var keyBindingSections: [KeyBindingSection]
    @Published private(set) var keyBindingConflicts: [String]
    @Published private(set) var selectedCameraPreset: CameraPreset
    @Published private(set) var isArmed: Bool
    @Published private(set) var physicalState: DronePhysicalState
    @Published private(set) var payloadDraftConfiguration: PayloadConfiguration
    @Published private(set) var payloadState: PayloadState
    @Published private(set) var payloadMountState: PayloadMountState
    @Published private(set) var payloadCapabilityCheck: PayloadCapabilityCheck
    @Published private(set) var vehicleMassModel: VehicleMassModel
    @Published private(set) var payloadStatusMessageKey: String?
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
    @Published private(set) var isPayloadCameraAutoSwitchEnabled: Bool
    @Published private(set) var controllerInteractionMode: ControllerInteractionMode = .flight
    @Published private(set) var activeInputSourceKind: InputSourceKind?
    @Published private(set) var activeGameControllerName: String?
    @Published private(set) var connectedGameControllers: [GameControllerDeviceSummary] = []
    @Published private(set) var gameControllerRightStickHorizontalMode: GameControllerRightStickHorizontalMode = .yawLeftRight
    @Published private(set) var isControllerCursorEnabled: Bool = false
    @Published private(set) var isControllerHubVisible: Bool = false
    @Published var controllerHubSection: ControllerHubSection = .connectedDevices

    let compassViewModel: CompassViewModel
    let controllerSettingsStore: ControllerSettingsStore
    let controllerUIBridge: ControllerUIBridge

    var scene: SCNScene {
        sceneController.scene
    }

    var activeCameraNode: SCNNode {
        sceneController.pointOfView(for: cameraConfiguration.mode)
    }

    var availableCameraModes: [CameraMode] {
        var modes: [CameraMode] = [.free, .follow, .orbit, .fpv, .top]
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
        return labels
    }

    var signalInterferencePresentation: SignalInterferencePresentation {
        let intensity: Double
        switch signalState {
        case .normal:
            intensity = 0.0
        case .outOfBoundsWarning, .signalDegrading:
            let elapsed = Double(SignalLossConfiguration.countdownDuration - max(0, signalCountdownSecondsRemaining))
            let progress = elapsed / Double(SignalLossConfiguration.countdownDuration)
            intensity = min(0.92, 0.18 + progress * 0.72)
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

        let lostTitle = signalState.isInteractionBlocking
            ? String(localized: "signal_loss.lost_title")
            : nil
        let lostMessage = signalState.isInteractionBlocking
            ? String(localized: "signal_loss.lost_message")
            : nil
        let recoveryButtonTitle = signalState == .signalLost
            ? String(localized: "signal_loss.recover")
            : nil

        return SignalInterferencePresentation(
            state: signalState,
            countdownText: countdownText,
            intensity: intensity,
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
    private let batteryThermalService: BatteryThermalSimulationService
    private let telemetryExporter: TelemetryExporting
    private let projectStorage: ProjectStorageManaging
    private let fleetManager: DroneFleetManager
    private let autoPathPlanner: AutoPathPlannerService
    private let flightControlRouter: FlightControlRouter
    private let autoNavigationController: AutoNavigationController
    private let payloadCameraController: PayloadCameraController
    private let tacticalMapCoordinator = TacticalMapCoordinator()
    private let missionDraftBuilder = MissionDraftBuilder()
    private let missionPreviewBuilder = MissionPreviewBuilder()
    private let missionPlanBuilder = MissionPlanBuilder()
    private let missionExecutionBinder = MissionExecutionBinder()
    private let missionExecutionCoordinator = MissionExecutionCoordinator()
    private let missionAutopilotAdapter = MissionAutopilotAdapter()
    private let missionProgressTracker = MissionProgressTracker()
    private let missionAuthorityGuard = MissionAuthorityGuard()
    private let missionRuntimeMonitor = MissionRuntimeMonitor()
    private let missionSafetyEvaluator = MissionSafetyEvaluator()
    private let missionFailsafeCoordinator = MissionFailsafeCoordinator()
    private let missionStatusResolver = MissionStatusResolver()
    private let missionEventRecorder = MissionEventRecorder()
    private let missionDebriefService = MissionDebriefService()
    private let missionEventMapper = MissionEventMapper()
    private let missionPersistenceAdapter = MissionPersistenceAdapter()

    private var state: DroneState
    private var lastFiniteState: DroneState
    private var simulationTimer: Timer?
    private var lastTimestamp: CFTimeInterval?
    private var simulationTime: Float = 0.0
    private var telemetrySamplingAccumulator: Float = 0.0
    private var hudPublishAccumulator: Float = 0.0
    private var diagnosticsSamplingAccumulator: Float = 0.0
    private var groundContactAccumulator: Float = 0.0
    private var stableGroundAccumulator: Float = 0.0
    private var airborneAccumulator: Float = 0.0
    private var impactSeverityAccumulator: Float = 0.0
    private var collisionCooldown: Float = 0.0
    private var homePosition = SIMD3<Float>(0.0, 0.0, 0.0)
    private var wingmen: [DroneEntity] = []
    private let fleetLeaderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var collisionDebugAccumulator: Float = 0.0
    private var lastCollisionDebugEnabled: Bool = false
    private var autosaveAccumulator: Float = 0.0
    private var manualYawIntent: Float = 0.0
    private var cameraLookVelocity = SIMD2<Float>(repeating: 0.0)
    private var resolvedInputState: ResolvedControlState = .neutral
    private var autoFlightGoal: SIMD3<Float>?
    private var autoFlightGoalIndex: Int = 0
    private var returnHomeStage: ReturnHomeStage = .idle
    private var navigationSnapshot: NavigationPathSnapshot = .idle
    private var flightControlDiagnostics: FlightControlDiagnostics = .zero
    private var cachedDiagnostics: SimulationDiagnostics = .zero
    private var pendingTerrainRegenerationTask: Task<Void, Never>?
    private var signalLossSecondAccumulator: Float = 0.0
    private var fleetInterDroneRisk: Float = 0.0
    private var fleetNearestInterDroneDistance: Float = .infinity
    private var isTerrainDensitySliderEditing: Bool = false
    private var terrainMapTrail: [SIMD2<Float>] = []
    private var installedPayloadConfiguration: PayloadConfiguration?
    private var activePayloadReleaseID: UUID?
    private var lastSidebarModule: ControlModule = .flightOps
    private var committedTacticalMissionDraft: MissionDraft = .empty
    private var workingTacticalMissionDraft: MissionDraft = .empty
    private var missionSafetyState: MissionSafetyState = .idle
    private var activeRouteTargetSource: ActiveRouteTargetSource = .none
    private var missionObservation = MissionObservationAccumulator()
    private var externalControllerOverlayActive: Bool = false

    private enum ActiveRouteTargetSource {
        case none
        case manualMarker
        case mission
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
        remoteHostPort: UInt16 = 7777,
        initialProjectID: String? = nil,
        initialProjectName: String? = nil
    ) {
        self.physicsEngine = physicsEngine
        self.keyboardInputService = keyboardInputService
        self.controllerSettingsStore = controllerSettingsStore
        let gameControllerInputProvider = GameControllerInputProvider(
            settingsStore: controllerSettingsStore
        )
        self.controllerUIBridge = ControllerUIBridge(settingsStore: controllerSettingsStore)
        self.gameControllerInputProvider = gameControllerInputProvider
        let remoteTransport = NetworkRemoteHost(port: remoteHostPort)
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
        self.collisionService = collisionService
        self.batteryThermalService = batteryThermalService
        self.telemetryExporter = telemetryExporter
        self.projectStorage = projectStorage
        self.fleetManager = fleetManager
        self.autoPathPlanner = autoPathPlanner
        self.flightControlRouter = flightControlRouter
        self.autoNavigationController = autoNavigationController
        self.payloadCameraController = payloadCameraController
        self.compassViewModel = CompassViewModel()

        let abstract = AbstractDroneParameters.default
        self.abstractParameters = abstract
        let repository = LIPODroneModelRepository(abstractParameters: abstract)
        let models = repository.allProfiles
        let selectedProfile = repository.defaultProfile
        let initialActiveUAVProfile = Self.resolveActiveUAVProfile(for: selectedProfile, abstractParameters: abstract)
        self.selectedDroneProfile = selectedProfile
        self.activeUAVProfile = initialActiveUAVProfile
        self.availableDroneProfiles = models
        self.uavCatalogFilterState = UAVFilterState()

        self.sceneController = DroneSceneController(initialProfile: selectedProfile)

        let initialState = DroneState.initial
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
        self.hasUnsavedChanges = true

        self.weather = .normal
        self.terrain = .default
        self.cameraConfiguration = CameraConfiguration(
            mode: .follow,
            fov: selectedProfile.cameraPreset.fpvFov,
            sensitivity: 1.0,
            smoothing: 0.72,
            invertLookX: false,
            invertLookY: false,
            sensitivityProfile: .medium,
            lookNudgeStepDeg: 2.0,
            free: FreeCameraState(
                moveSpeed: 4.2,
                zoomSensitivity: 1.0,
                distance: 14.0,
                minDistance: 2.0,
                maxDistance: 80.0
            ),
            follow: FollowCameraState(
                distance: selectedProfile.cameraPreset.followDistance,
                height: selectedProfile.cameraPreset.followHeight,
                lateralOffset: 0.0,
                minDistance: 2.0,
                maxDistance: 26.0
            ),
            orbit: OrbitCameraState(
                distance: selectedProfile.cameraPreset.followDistance,
                height: selectedProfile.cameraPreset.followHeight,
                angularSpeed: 0.42,
                minDistance: 2.0,
                maxDistance: 32.0
            ),
            fpv: FPVCameraState(
                stabilization: 0.45,
                shake: 0.07,
                yawLimitDeg: 24.0,
                pitchLimitDeg: 18.0,
                nearClip: 0.02,
                mountOffset: SIMD3<Float>(0.0, 0.006, -0.014),
                hideObstructingParts: true
            ),
            top: TopCameraState(
                height: 34.0,
                minHeight: 8.0,
                maxHeight: 120.0,
                forwardLead: 0.0
            )
        )

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
        self.collisionDebugEnabled = false
        self.showBatteryDepletedDialog = false
        self.diagnosticMode = .normal
        self.isToolPanelVisible = true
        self.isParametersPanelVisible = false
        self.activeControlModule = nil
        self.isPayloadPanelVisible = false
        self.isBoundaryBarrierVisible = false
        self.isCompactTelemetryHUDEnabled = true
        self.telemetryExportAlert = nil
        self.keyBindingSections = []
        self.keyBindingConflicts = []
        self.selectedCameraPreset = .pilot
        self.isArmed = false
        self.physicalState = initialState.physicalState
        let initialPayloadConfiguration = PayloadController.defaultConfiguration()
        self.payloadDraftConfiguration = initialPayloadConfiguration
        self.payloadState = .noPayload
        self.payloadMountState = initialActiveUAVProfile == nil ? .unavailable : .ready
        self.payloadCapabilityCheck = PayloadController.capabilityCheck(
            for: initialPayloadConfiguration,
            profile: initialActiveUAVProfile
        )
        self.vehicleMassModel = PayloadController.massModel(
            for: selectedProfile,
            uavProfile: initialActiveUAVProfile,
            installedPayload: nil,
            payloadState: .noPayload
        )
        self.payloadStatusMessageKey = nil
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
        self.isPayloadCameraAutoSwitchEnabled = false
        self.telemetry = .zero
        self.cachedDiagnostics = .zero

        self.payloadCameraController.setAutoSwitchAfterRelease(false)
        sceneController.regenerateEnvironment(terrain)
        sceneController.setWorldBoundsVisible(isBoundaryBarrierVisible)
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
        refreshPayloadCameraStatus()

        homePosition = sceneController.currentDockSpawnPoint()
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

    // MARK: - Controls

    func injectMockRemotePacket(_ packet: RemoteControlPacket) {
        remoteInputProvider.ingestRemotePacket(packet)
    }

    func setX(_ value: Double) { updateControlValues({ $0.x = value }, markManual: true) }
    func setY(_ value: Double) { updateControlValues({ $0.y = value }, markManual: true) }
    func setZ(_ value: Double) { updateControlValues({ $0.z = value }, markManual: true) }
    func setRoll(_ value: Double) { updateControlValues({ $0.roll = value }, markManual: true) }
    func setPitch(_ value: Double) { updateControlValues({ $0.pitch = value }, markManual: true) }
    func setYaw(_ value: Double) { updateControlValues({ $0.yaw = value }, markManual: true) }
    func setThrottle(_ value: Double) { updateControlValues({ $0.throttle = value }, markManual: true) }

    func setPayloadType(_ type: PayloadType) {
        guard payloadDraftConfiguration.payloadType != type else {
            return
        }

        payloadDraftConfiguration.payloadType = type
        payloadDraftConfiguration.visualPreset = type.defaultVisualPreset
        payloadDraftConfiguration.payloadMass = type.defaultMass
        if type != .custom {
            payloadDraftConfiguration.customName = ""
        }
        payloadDraftConfiguration.isAttached = payloadDraftMatchesInstalledPayload()
        payloadStatusMessageKey = nil
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func setPayloadMass(_ value: Double) {
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

    func setPayloadCustomName(_ value: String) {
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
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        installedPayloadConfiguration = attachedConfiguration
        payloadDraftConfiguration = attachedConfiguration
        payloadState = .attached
        payloadStatusMessageKey = "payload.message.attached"
        sceneController.attachPayloadVisual(attachedConfiguration)
        refreshPayloadCameraStatus()
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func removePayload() {
        guard installedPayloadConfiguration != nil || payloadState == .attached else {
            return
        }

        activePayloadReleaseID = nil
        installedPayloadConfiguration = nil
        payloadDraftConfiguration.isAttached = false
        payloadState = .removed
        payloadStatusMessageKey = "payload.message.removed"
        sceneController.removePayloadVisual()
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        if cameraConfiguration.mode == .payload {
            setCameraMode(.follow)
        } else {
            refreshPayloadCameraStatus()
        }
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func releasePayload() {
        guard installedPayloadConfiguration != nil, payloadState == .attached else {
            payloadStatusMessageKey = "payload.message.no_payload_attached"
            refreshPayloadRuntimeState()
            return
        }

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

    func arm() {
        ensureSimulationRunning()
        guard physicalState.permitsRearm, !damageState.isFlightCritical else {
            return
        }
        isArmed = true
        if heightAboveSupportSurface(for: state.position) <= 0.08 {
            transitionPhysicalState(.armedOnGround)
        }
        if heightAboveSupportSurface(for: state.position) <= 0.05,
           selectedDroneProfile.airframeClass == .multirotor {
            updateControlValues({ values in
                values.throttle = max(values.throttle, 0.06)
            }, markManual: false)
        }
    }

    func disarm(forceEmergency: Bool = false) {
        cancelTargetMarkerAutoNavigation()
        isArmed = false
        if forceEmergency {
            mode = .emergencyStop
        } else if heightAboveSupportSurface(for: state.position) <= 0.1 {
            mode = .manual
        }
        if physicalState != .crashed {
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

        if heightAboveSupportSurface(for: state.position) <= 0.08 || physicalState.isGroundRestState {
            settleDisarmedGroundedState()
        }
    }

    func reset() {
        ensureSimulationRunning()
        clearMissionPlan()
        clearTargetMarker()
        mode = .manual
        flightControlMode = .stabilized
        clearSignalLossState(restoringInputMode: false)
        state = DroneState.initial
        lastFiniteState = state
        controlValues = DroneControlValues()
        batteryState = .full
        damageState = .pristine
        thermalState = .nominal
        diagnosticMode = .normal
        collisionAnalysis = .safe
        isArmed = false
        wingmen.removeAll()
        fleetInterDroneRisk = 0.0
        fleetNearestInterDroneDistance = .infinity
        showBatteryDepletedDialog = false
        homePosition = sceneController.currentDockSpawnPoint()
        simulationTime = 0.0
        telemetrySamplingAccumulator = 0.0
        hudPublishAccumulator = 0.0
        diagnosticsSamplingAccumulator = 0.0
        groundContactAccumulator = 0.0
        stableGroundAccumulator = 0.0
        airborneAccumulator = 0.0
        impactSeverityAccumulator = 0.0
        collisionCooldown = 0.0
        manualYawIntent = 0.0
        cameraLookVelocity = .zero
        lastCollisionDebugEnabled = false
        autoPathPlanner.invalidate()
        autoFlightGoal = nil
        autoFlightGoalIndex = 0
        returnHomeStage = .idle
        navigationSnapshot = .idle
        activePayloadReleaseID = nil
        keyboardInputService.setInputProcessingMode(.flight)
        keyboardInputService.resetTransientState()
        inputManager.reset()
        resetFlightControlRouting()
        payloadCameraController.clearTracking()
        sceneController.setPayloadCameraFocusReleaseID(nil)
        if cameraConfiguration.mode == .payload {
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

        mode = .manual
        isArmed = false
        manualYawIntent = 0.0
        cameraLookVelocity = .zero
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
        ensureSimulationRunning()
        guard isArmed else {
            return
        }
        cancelTargetMarkerAutoNavigation()
        let baseline = resolvedFlightBaseline(for: .takeoff)
        mode = .takeoff
        if state.position.y <= 0.10 {
            transitionPhysicalState(.takeoffTransition)
        }
        if selectedDroneProfile.airframeClass == .fixedWing {
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = max(values.pitch, 10.0)
                values.throttle = max(values.throttle, Double(baseline.takeoffThrottleReference))
            }, markManual: false)
        } else {
            updateControlValues({ values in
                values.y = max(values.y, 3.0)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, Double(baseline.takeoffThrottleReference))
            }, markManual: false)
        }
    }

    func land() {
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
        let baseline = resolvedFlightBaseline(for: .landing)
        mode = .landing
        if state.position.y > 0.05 {
            transitionPhysicalState(.landing)
        }
        if selectedDroneProfile.airframeClass == .fixedWing {
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = min(max(values.pitch, 6.0), 14.0)
                values.throttle = min(values.throttle, Double(baseline.landingThrottleReference))
            }, markManual: false)
        } else {
            updateControlValues({ values in
                values.y = 0.0
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = min(values.throttle, Double(baseline.landingThrottleReference))
            }, markManual: false)
        }
    }

    func hover() {
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
        let baseline = resolvedFlightBaseline(for: .hover)
        guard baseline.hoverCapable else {
            mode = .manual
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, Double(baseline.cruiseReferenceThrottle))
            }, markManual: false)
            return
        }
        mode = .hover
        lockControlsToCurrentState(overrideThrottle: Double(baseline.hoverLockThrottle))
    }

    func activateAutoPath() {
        ensureSimulationRunning()
        if targetMarkerState != nil {
            guard canStartTargetMarkerAutoNavigation else {
                return
            }
            autoPathPlanner.invalidate()
            autoFlightGoal = nil
            autoNavigationController.start(safeTravelAltitude: targetMarkerTravelAltitude())
            mode = .autoPath
            navigationSnapshot = .idle
            refreshTerrainMapSnapshot(recordTrail: false)
            return
        }
        mode = .autoPath
        returnHomeStage = .idle
        autoPathPlanner.invalidate()
        autoFlightGoal = nextAutoPatrolGoal(resetCycle: true)
        navigationSnapshot = .idle
    }

    func activateReturnHome() {
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
        mode = .returnHome
        returnHomeStage = .ascend
        autoFlightGoal = nil
        autoPathPlanner.invalidate()
        navigationSnapshot = .idle
    }

    func activateEmergencyStop() {
        ensureSimulationRunning()
        cancelTargetMarkerAutoNavigation()
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
                activeControlModule = lastSidebarModule
            }
            isParametersPanelVisible = activeControlModule != nil
        } else {
            isParametersPanelVisible = false
        }
    }

    func setActiveControlModule(_ module: ControlModule?) {
        if let activeControlModule {
            lastSidebarModule = activeControlModule
        }
        if let module {
            lastSidebarModule = module
        }
        activeControlModule = module
        isParametersPanelVisible = module != nil
        isPayloadPanelVisible = false
    }

    func toggleActiveControlModule(_ module: ControlModule) {
        setActiveControlModule(activeControlModule == module ? nil : module)
    }

    func togglePayloadPanel() {
        isPayloadPanelVisible.toggle()
    }

    func setPayloadPanelVisible(_ visible: Bool) {
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
        tacticalMapMode = .waypoint
        isMissionMapVisible = true
        refreshTacticalMapState()
        refreshFlightControlDiagnostics()
    }

    func exitMissionMap() {
        workingTacticalMissionDraft = committedTacticalMissionDraft
        isMissionMapVisible = false
        refreshTacticalMapState()
        refreshFlightControlDiagnostics()
    }

    func cancelMissionPlanningChanges() {
        workingTacticalMissionDraft = committedTacticalMissionDraft
        refreshTacticalMapState()
    }

    func setTacticalMapMode(_ mode: TacticalMapMode) {
        guard tacticalMapMode != mode else {
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
        if let zoneType = tacticalMapMode.zoneType {
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
            viewport: currentTacticalMapViewport()
        )
        currentMissionPlan = plan
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
            bindMissionExecutionTarget(activeTarget, startNavigation: true)
        }
        missionPlanState = .empty
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
        bindMissionExecutionTarget(activeTarget, startNavigation: true)
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
        dropZone.radius = max(1.0, min(radius, playableBoundaryRadius * 0.6))
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
        let canonicalID = LIPODroneModelRepository.canonicalModelID(id)
        guard let profile = availableDroneProfiles.first(where: { $0.id == canonicalID }) else {
            return
        }

        selectedDroneProfile = profile
        activeUAVProfile = Self.resolveActiveUAVProfile(for: profile, abstractParameters: abstractParameters)
        sceneController.setDroneProfile(profile)
        resetPayloadForProfileSwitch()
        resetCameraConfigurationForSelectedProfile()

        batteryState = .full
        reset()
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
        let oldMode = cameraConfiguration.mode
        guard oldMode != mode else {
            refreshPayloadCameraStatus()
            return
        }

        if mode == .payload {
            guard payloadCameraController.canActivatePayloadView() else {
                return
            }
            _ = payloadCameraController.activatePayloadView(from: oldMode)
            sceneController.setPayloadCameraFocusReleaseID(payloadCameraController.trackedReleaseID)
        } else if oldMode == .payload {
            payloadCameraController.leavePayloadViewManually()
        }

        cameraConfiguration.mode = mode
        syncCameraSystem(from: oldMode)
        refreshPayloadCameraStatus()
    }

    func cycleCameraMode() {
        let oldMode = cameraConfiguration.mode
        if oldMode == .payload {
            payloadCameraController.leavePayloadViewManually()
        }
        let nextMode = cameraConfiguration.mode.next()
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
        cameraConfiguration.applyPreset(preset)
        syncCameraSystem(from: previousMode, resetOrientation: true)
        refreshPayloadCameraStatus()
    }

    func resetCameraToPreset() {
        let previousMode = cameraConfiguration.mode
        if previousMode == .payload {
            payloadCameraController.leavePayloadViewManually()
        }
        cameraConfiguration.applyPreset(selectedCameraPreset)
        syncCameraSystem(from: previousMode, resetOrientation: true)
        refreshPayloadCameraStatus()
    }

    func setCameraFov(_ value: Double) { cameraConfiguration.fov = Float(value) }
    func setCameraSensitivity(_ value: Double) { cameraConfiguration.sensitivity = Float(value) }
    func setCameraSmoothing(_ value: Double) { cameraConfiguration.smoothing = Float(value) }
    func setCameraInvertX(_ value: Bool) { cameraConfiguration.invertLookX = value }
    func setCameraInvertY(_ value: Bool) { cameraConfiguration.invertLookY = value }
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
        keyboardInputService.rebind(command: command, to: keyCode, keyLabel: keyLabel)
        refreshKeyBindingDiagnostics()
    }

    func resetKeyBindingsToDefault() {
        keyboardInputService.resetBindingsToDefault()
        refreshKeyBindingDiagnostics()
    }

    func beginKeyBindingCapture() {
        keyboardInputService.setInputProcessingMode(.bindingCapture)
        inputManager.reset()
    }

    func endKeyBindingCapture() {
        keyboardInputService.setInputProcessingMode(.flight)
        inputManager.reset()
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

        if isParametersPanelVisible {
            setControlPanelVisible(false)
        }
    }

    func setGameControllerRightStickHorizontalMode(_ mode: GameControllerRightStickHorizontalMode) {
        gameControllerInputProvider.setRightStickHorizontalMode(mode)
        refreshGameControllerPresentation(force: true)
    }

    func handlePointerLook(deltaX: Float, deltaY: Float) {
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
        sceneController.updatePayloadCameraForRenderFrame(
            atTime: time,
            isActive: cameraMode == .payload
        )
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
        cameraConfiguration.mode != .fpv && cameraConfiguration.mode != .payload
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
        case .payload:
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

    func setTerrainPreset(_ preset: TerrainPreset) {
        cancelPendingTerrainDensityRegeneration()
        terrain.preset = preset
        terrain.density = preset.defaultDensity
        terrain.safeSpawnRadius = recommendedSafeSpawnRadius(for: terrain.mapScale)
        regenerateEnvironment()
    }

    func setTerrainMapScale(_ scale: MapScale) {
        guard terrain.mapScale != scale else {
            return
        }
        cancelPendingTerrainDensityRegeneration()
        terrain.mapScale = scale
        terrain.safeSpawnRadius = recommendedSafeSpawnRadius(for: scale)
        regenerateEnvironment()
        reset()
    }

    func setTerrainDensity(_ value: Double) {
        let clampedValue = Float(value).clamped(to: 0.0...1.0)
        guard abs(terrain.density - clampedValue) > 0.0001 else {
            return
        }
        terrain.density = clampedValue
        if !isTerrainDensitySliderEditing {
            scheduleTerrainDensityRegeneration()
        }
    }

    func setTerrainSeed(_ value: UInt64) {
        cancelPendingTerrainDensityRegeneration()
        terrain.seed = value
        regenerateEnvironment()
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
        mode = .hover
        lockControlsToCurrentState(overrideThrottle: Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle))
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
        let profile = keyboardInputService.currentBindingProfile()
        keyBindingSections = KeyBindingCategory.allCases.compactMap { category in
            let bindings = (profile.groupedBindings()[category] ?? []).filter { $0.command != .toggleControlPanel }
            if bindings.isEmpty {
                return nil
            }
            return KeyBindingSection(category: category, bindings: bindings)
        }
        keyBindingConflicts = keyboardInputService.currentBindingConflicts()
            .filter { !$0.contains(KeyboardCommand.toggleControlPanel.titleKey) }
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
        homePosition = sceneController.currentDockSpawnPoint()
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

    private func scheduleTerrainDensityRegeneration() {
        cancelPendingTerrainDensityRegeneration()
        pendingTerrainRegenerationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else {
                return
            }
            self.commitPendingTerrainDensityRegeneration()
        }
    }

    private func cancelPendingTerrainDensityRegeneration() {
        pendingTerrainRegenerationTask?.cancel()
        pendingTerrainRegenerationTask = nil
    }

    private func commitPendingTerrainDensityRegeneration() {
        pendingTerrainRegenerationTask = nil
        regenerateEnvironment()
    }

    private func startSimulationLoop() {
        simulationTimer?.invalidate()
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.tick()
            }
        }

        if let simulationTimer {
            RunLoop.main.add(simulationTimer, forMode: .common)
        }
    }

    private func tick() {
        let frameStart = CACurrentMediaTime()
        let now = CACurrentMediaTime()
        guard let lastTimestamp else {
            self.lastTimestamp = now
            let resolvedInput = updateInputPipeline(deltaTime: 0.0)
            let controllerSnapshot = inputManager.snapshot(for: .gameController)
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
            refreshPayloadCameraStatus()
            return
        }

        let dt = Float(max(1.0 / 240.0, min(now - lastTimestamp, 1.0 / 20.0)))
        self.lastTimestamp = now
        simulationTime += dt
        impactSeverityAccumulator = max(0.0, impactSeverityAccumulator - dt * 3.6)

        let resolvedInput = updateInputPipeline(deltaTime: TimeInterval(dt))
        let controllerSnapshot = inputManager.snapshot(for: .gameController)
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

        guard isSimulationRunning else {
            syncMissionDeliveryState(triggerAutoRelease: false)
            refreshFlightControlDiagnostics()
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
            syncPayloadLifecycleEvents()
            return
        }

        if signalState.isInteractionBlocking {
            syncMissionDeliveryState(triggerAutoRelease: false)
            refreshFlightControlDiagnostics()
            renderSignalLossFrame()
            refreshCompassOverlay()
            refreshPayloadCameraStatus()
            syncPayloadLifecycleEvents()
            return
        }

        collisionCooldown = max(0.0, collisionCooldown - dt)

        applyResolvedFlightControls(deltaTime: dt, controlState: interactionAwareInput)
        updateAutopilotTargets(deltaTime: dt)
        let pathfindingMs = autoPathPlanner.lastPlanDurationMs

        _ = updateFleetStatus(deltaTime: dt)

        let prePhysicsCollisionAnalysis = collisionService.analyze(
            input: CollisionAnalysisInput(
                dronePosition: state.position,
                droneVelocity: state.velocity,
                droneRadius: selectedDroneProfile.collisionRadius,
                // Fleet spacing is handled separately; feeding wingmen back into leader
                // collision avoidance makes formation flight self-block on map guidance.
                obstacles: sceneController.environmentObstacles,
                weather: weather
            )
        )
        collisionAnalysis = prePhysicsCollisionAnalysis

        handleAutoCollisionInterventions()

        let control = buildControlInput(from: controlValues)
        let context = DroneSimulationContext(
            profile: selectedDroneProfile,
            activeUAVProfile: activeUAVProfile,
            weather: weather,
            damageState: damageState,
            batteryState: batteryState,
            collisionRisk: collisionAnalysis.riskScore,
            windVector: weather.windVector,
            vehicleMassModel: vehicleMassModel
        )

        let previousState = state
        let physicsStart = CACurrentMediaTime()
        state = physicsEngine.step(
            state: state,
            control: control,
            context: context,
            deltaTime: dt
        )
        enforceRuntimeSafetyAndBounds(context: "tick.physics")
        applySupportSurfaceConstraint(previousState: previousState)
        let physicsTimeMs = (CACurrentMediaTime() - physicsStart) * 1000.0

        let postPhysicsCollisionAnalysis = collisionService.analyze(
            input: CollisionAnalysisInput(
                dronePosition: state.position,
                droneVelocity: state.velocity,
                droneRadius: selectedDroneProfile.collisionRadius,
                obstacles: sceneController.environmentObstacles,
                weather: weather
            )
        )

        if postPhysicsCollisionAnalysis.nearestObstacleDistance <= -0.02 {
            collisionAnalysis = postPhysicsCollisionAnalysis
            if simd_length(state.velocity) > 0.45, collisionCooldown <= 0.0 {
                handleObstacleCollision(using: postPhysicsCollisionAnalysis)
                collisionCooldown = collisionCooldownDuration(for: postPhysicsCollisionAnalysis.nearestObstacleSource)
                enforceRuntimeSafetyAndBounds(context: "tick.collision_damage")
            } else if resolveObstaclePenetration(using: postPhysicsCollisionAnalysis) {
                enforceRuntimeSafetyAndBounds(context: "tick.collision_resolve")
            }
        }

        collisionAnalysis = collisionService.analyze(
            input: CollisionAnalysisInput(
                dronePosition: state.position,
                droneVelocity: state.velocity,
                droneRadius: selectedDroneProfile.collisionRadius,
                obstacles: sceneController.environmentObstacles,
                weather: weather
            )
        )

        updatePhysicalState(previousState: previousState, deltaTime: dt)
        applyGroundedSafetyIfNeeded(deltaTime: dt)
        handleModeTransitions()
        enforceRuntimeSafetyAndBounds(context: "tick.post_mode")
        updateSignalLossSequence(deltaTime: dt)
        syncMissionDeliveryState(triggerAutoRelease: false)

        if signalState.isInteractionBlocking {
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

        let renderStart = CACurrentMediaTime()
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
        refreshCompassOverlay()
        refreshPayloadCameraStatus()
        syncPayloadLifecycleEvents()
        let renderTimeMs = (CACurrentMediaTime() - renderStart) * 1000.0

        collisionDebugAccumulator += dt
        let collisionDebugStateChanged = (lastCollisionDebugEnabled != collisionDebugEnabled)
        if (collisionDebugEnabled && collisionDebugAccumulator > 0.12) || collisionDebugStateChanged {
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
        if diagnosticsSamplingAccumulator >= 0.45 || cachedDiagnostics.activeObjectCount == 0 {
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
            refreshTerrainMapSnapshot(recordTrail: true)
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

        autosaveAccumulator += dt
        if autosaveAccumulator >= 6.0 {
            performAutosaveIfNeeded()
            autosaveAccumulator = 0.0
        }
    }

    private func handleObstacleCollision(using analysis: CollisionAnalysisSnapshot) {
        switch obstacleImpactClass(for: analysis.nearestObstacleSource) {
        case .foliage:
            applyFoliageCollisionResponse(using: analysis)
        case .softSurface:
            applySoftSurfaceCollisionResponse(using: analysis)
        case .hardSurface:
            applyCollisionDamage(using: analysis)
        }
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

    private func collisionCooldownDuration(for source: String?) -> Float {
        switch obstacleImpactClass(for: source) {
        case .foliage:
            return 0.18
        case .softSurface:
            return 0.34
        case .hardSurface:
            return 0.70
        }
    }

    private func applyFoliageCollisionResponse(using analysis: CollisionAnalysisSnapshot) {
        let impact = simd_length(state.velocity)
        lastCollisionSource = analysis.nearestObstacleSource ?? "unknown"
        _ = resolveObstaclePenetration(using: analysis)

        impactSeverityAccumulator = max(
            impactSeverityAccumulator,
            impact * 0.36 + max(0.0, -analysis.nearestObstacleDistance) * 1.6
        )

        let planar = SIMD2<Float>(state.velocity.x, state.velocity.z)
        let planarSpeed = simd_length(planar)
        if planarSpeed > 0.001 {
            let damped = simd_normalize(planar) * (min(planarSpeed, 1.4) * 0.32)
            state.velocity.x = damped.x
            state.velocity.z = damped.y
        } else {
            state.velocity.x = 0.0
            state.velocity.z = 0.0
        }

        if state.velocity.y < 0.0 {
            state.velocity.y = max(-0.16, state.velocity.y * 0.28)
        } else {
            state.velocity.y *= 0.68
        }

        state.angularVelocity *= SIMD3<Float>(0.44, 0.44, 0.56)
        state.orientation.x *= 0.88
        state.orientation.y *= 0.88
    }

    private func applySoftSurfaceCollisionResponse(using analysis: CollisionAnalysisSnapshot) {
        let impact = simd_length(state.velocity)
        lastCollisionSource = analysis.nearestObstacleSource ?? "unknown"

        if impact > 2.2 {
            damageState = damageState.applyingCollisionDamage(impactEnergy: impact * 0.42)
        }

        _ = resolveObstaclePenetration(using: analysis)

        let planar = SIMD2<Float>(state.velocity.x, state.velocity.z)
        let planarSpeed = simd_length(planar)
        if planarSpeed > 0.001 {
            let damped = simd_normalize(planar) * (min(planarSpeed, 1.6) * 0.28)
            state.velocity.x = damped.x
            state.velocity.z = damped.y
        }
        state.velocity.y = max(-0.24, state.velocity.y * 0.34)
        state.angularVelocity *= SIMD3<Float>(0.22, 0.22, 0.34)
    }

    private func applyCollisionDamage(using analysis: CollisionAnalysisSnapshot) {
        let impact = simd_length(state.velocity)
        lastCollisionSource = analysis.nearestObstacleSource ?? "unknown"
        damageState = damageState.applyingCollisionDamage(impactEnergy: impact)
        impactSeverityAccumulator = max(
            impactSeverityAccumulator,
            impact + simd_length(state.angularVelocity) * 0.42 + max(0.0, -analysis.nearestObstacleDistance) * 3.4
        )

        let penetration = max(0.0, -analysis.nearestObstacleDistance)
        if penetration > 0.0001,
           let obstacleID = analysis.nearestObstacleID,
           let obstacle = sceneController.obstacle(for: obstacleID) {
            let away = horizontalPushNormal(awayFrom: obstacle)
            let pushDistance = penetration + max(0.04, selectedDroneProfile.collisionRadius * 0.10)
            state.position += away * pushDistance
        }

        let planar = SIMD2<Float>(state.velocity.x, state.velocity.z)
        let planarSpeed = simd_length(planar)
        if planarSpeed > 0.001 {
            let limited = min(planarSpeed, 1.9)
            let damped = simd_normalize(planar) * (limited * 0.24)
            state.velocity.x = damped.x
            state.velocity.z = damped.y
        } else {
            state.velocity.x = 0.0
            state.velocity.z = 0.0
        }

        if state.velocity.y < 0.0 {
            state.velocity.y = max(-0.32, state.velocity.y * 0.14)
        } else {
            state.velocity.y *= 0.34
        }

        state.angularVelocity *= SIMD3<Float>(0.14, 0.14, 0.22)
        state.orientation.x *= 0.74
        state.orientation.y *= 0.74
        if abs(state.orientation.x) < 0.002 { state.orientation.x = 0.0 }
        if abs(state.orientation.y) < 0.002 { state.orientation.y = 0.0 }

        if damageState.isFlightCritical || impact > 5.6 {
            disarm(forceEmergency: true)
            updateControlValues({ values in
                values.throttle = 0.0
            }, markManual: false)
        } else if impact > 4.5 {
            mode = .emergencyStop
            updateControlValues({ values in
                values.throttle = min(values.throttle, 0.25)
            }, markManual: false)
        }
    }

    private func resolveObstaclePenetration(using analysis: CollisionAnalysisSnapshot) -> Bool {
        let penetration = max(0.0, -analysis.nearestObstacleDistance)
        guard penetration > 0.0001,
              let obstacleID = analysis.nearestObstacleID,
              let obstacle = sceneController.obstacle(for: obstacleID) else {
            return false
        }

        let normal = horizontalPushNormal(awayFrom: obstacle)

        let pushDistance = penetration + max(0.03, selectedDroneProfile.collisionRadius * 0.08)
        state.position += normal * pushDistance

        let inwardVelocity = simd_dot(state.velocity, normal)
        if inwardVelocity < 0.0 {
            state.velocity -= normal * inwardVelocity
        }
        state.velocity *= SIMD3<Float>(0.82, 0.88, 0.82)
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

    private func handleAutoCollisionInterventions() {
        guard mode.isAutoControlled else {
            return
        }

        switch collisionAnalysis.emergencyAction {
        case .none, .slowDown:
            return
        case .hover:
            mode = .hover
            lockControlsToCurrentState(
                overrideThrottle: Double(max(resolvedFlightBaseline(for: .hover).hoverLockThrottle, state.throttle))
            )
        case .avoid:
            guard let obstacleID = collisionAnalysis.nearestObstacleID,
                  let obstacle = sceneController.obstacleCenter(for: obstacleID) else {
                return
            }

            let away = simd_normalize(state.position - obstacle)
            updateControlValues({ values in
                values.x += Double(away.x * 1.4)
                values.z += Double(away.z * 1.4)
                values.y = max(values.y, Double(state.position.y + 0.45))
                values.throttle = max(values.throttle, 0.56)
            }, markManual: false)
        case .emergencyStop:
            activateEmergencyStop()
        }
    }

    private func applyResolvedFlightControls(
        deltaTime: Float,
        controlState: ResolvedControlState
    ) {
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

        manualYawIntent = route.yawInput.intent * (route.yawInput.speedBoost ? 1.35 : 1.0)
        let maxAltitude = Double(terrain.maxFlightAltitude)
        var effectiveAxis = route.axisInput
        var markerDirective: AutoNavigationDirective?
        let markerObstacleAvoidanceActive = route.authority == .markerGuidance &&
            selectedDroneProfile.airframeClass == .multirotor &&
            collisionAnalysis.emergencyAction == .avoid
        let isMarkerGuidanceMultirotor = route.authority == .markerGuidance &&
            selectedDroneProfile.airframeClass == .multirotor &&
            !markerObstacleAvoidanceActive

        if route.authority == .manual, mode == .hover {
            mode = .manual
        }

        if route.shouldCancelMarkerGuidance {
            cancelTargetMarkerAutoNavigation()
            if mode == .autoPath {
                mode = .manual
            }
        }

        if route.shouldAttemptMarkerGuidance {
            markerDirective = updateTargetMarkerAutoNavigation(deltaTime: deltaTime)
            if let directive = markerDirective {
                effectiveAxis = keyboardAxisInput(from: directive)
                if isMarkerGuidanceMultirotor {
                    effectiveAxis = KeyboardAxisInput(
                        forward: effectiveAxis.forward,
                        strafe: effectiveAxis.strafe,
                        vertical: 0.0,
                        speedBoost: effectiveAxis.speedBoost
                    )
                }
            }
        }

        let hasEffectiveYawInput = abs(route.yawInput.intent) > 0.001
        let hasEffectiveInput =
            abs(effectiveAxis.forward) > 0.001 ||
            abs(effectiveAxis.strafe) > 0.001 ||
            abs(effectiveAxis.vertical) > 0.001 ||
            hasEffectiveYawInput

        if selectedDroneProfile.airframeClass == .fixedWing {
            guard hasEffectiveInput else {
                return
            }
            updateControlValues({ values in
                let throttleDelta = Double(effectiveAxis.vertical) * (effectiveAxis.speedBoost ? 0.55 : 0.32) * Double(deltaTime)
                values.throttle = (values.throttle + throttleDelta).clamped(to: 0.0...1.0)
                values.roll = Double((-effectiveAxis.strafe * (effectiveControlMode == .acro ? 62.0 : 32.0)).clamped(to: -85.0...85.0))
                values.pitch = Double((-effectiveAxis.forward * (effectiveControlMode == .acro ? 54.0 : 24.0)).clamped(to: -85.0...85.0))
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
        let autoAltitudeTarget = markerObstacleAvoidanceActive
            ? nil
            : markerDirective.map { Double($0.targetAltitude).clamped(to: 0.0...maxAltitude) }
        let hoverBaselineThrottle = Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle)

        updateControlValues({ values in
            if let autoAltitudeTarget {
                values.y = autoAltitudeTarget
            } else {
                values.y = (values.y + Double(climb)).clamped(to: 0.0...maxAltitude)
            }

            if isMarkerGuidanceMultirotor && markerDirective != nil {
                let throttleTarget = hoverBaselineThrottle.clamped(to: 0.0...1.0)
                values.throttle = values.throttle + (throttleTarget - values.throttle) * 0.18
            } else {
                let verticalThrottleDelta = Double(effectiveAxis.vertical) * (effectiveAxis.speedBoost ? 0.40 : 0.26) * Double(deltaTime)
                values.throttle = (values.throttle + verticalThrottleDelta).clamped(to: 0.0...1.0)
            }
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
        guard !signalState.isInteractionBlocking else {
            return
        }

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
        guard cameraConfiguration.mode == .fpv, !signalState.isInteractionBlocking else {
            cameraLookVelocity = .zero
            return
        }

        let speedMultiplier: Float = controlState.boostMode ? 1.85 : 1.0
        let targetVelocity = SIMD2<Float>(
            Float(controlState.cameraPan),
            Float(controlState.cameraTilt)
        )
            * (92.0 * speedMultiplier * cameraConfiguration.effectiveLookSensitivity)

        let accelerationBlend = (deltaTime * 12.0).clamped(to: 0.0...1.0)
        cameraLookVelocity = simd_mix(
            cameraLookVelocity,
            targetVelocity,
            SIMD2<Float>(repeating: accelerationBlend)
        )

        if abs(controlState.cameraPan) < 0.001, abs(controlState.cameraTilt) < 0.001 {
            let damping = max(0.0, 1.0 - deltaTime * 9.0)
            cameraLookVelocity *= damping
            if simd_length_squared(cameraLookVelocity) < 0.0001 {
                cameraLookVelocity = .zero
            }
        }

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

    private func adjustCameraZoom(inward: Bool) {
        let sign: Float = inward ? -1.0 : 1.0
        let zoomStep = 0.9 * cameraConfiguration.free.zoomSensitivity

        switch cameraConfiguration.mode {
        case .free:
            cameraConfiguration.free.distance = (cameraConfiguration.free.distance + sign * zoomStep)
                .clamped(to: cameraConfiguration.free.minDistance...cameraConfiguration.free.maxDistance)
            sceneController.dollyFreeCamera(by: sign * zoomStep)
        case .follow, .orbit, .top:
            cameraConfiguration.setCameraDistance(cameraConfiguration.cameraDistance + sign * zoomStep)
        case .fpv:
            cameraConfiguration.fov = (cameraConfiguration.fov + sign * 1.2).clamped(to: 30.0...110.0)
        case .payload:
            return
        }
    }

    private func updateAutopilotTargets(deltaTime: Float) {
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
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                let throttleTarget = hoverBaseline.clamped(to: 0.0...1.0)
                values.throttle = values.throttle + (throttleTarget - values.throttle) * 0.18
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
        }
    }

    private func updateTargetMarkerAutoNavigation(deltaTime: Float) -> AutoNavigationDirective? {
        guard targetMarkerState != nil else {
            navigationSnapshot = .idle
            return nil
        }

        guard canStartTargetMarkerAutoNavigation else {
            cancelTargetMarkerAutoNavigation()
            navigationSnapshot = .idle
            if mode == .autoPath {
                mode = .manual
            }
            return nil
        }

        let travelAltitude = targetMarkerTravelAltitude()
        if !autoNavigationController.isActive {
            autoNavigationController.start(safeTravelAltitude: travelAltitude)
        }

        let input = AutoNavigationUpdateInput(
            position: state.position,
            velocity: state.velocity,
            currentYawRadians: state.orientation.z,
            physicalState: physicalState,
            airframeClass: selectedDroneProfile.airframeClass,
            deltaTime: deltaTime,
            safeTravelAltitude: travelAltitude
        )

        guard let directive = autoNavigationController.update(with: input) else {
            navigationSnapshot = .idle
            switch autoNavigationController.consumeCompletionReason() {
            case .reachedTarget:
                finishTargetMarkerAutoNavigation()
            case .cancelled, .none:
                if mode == .autoPath {
                    mode = .manual
                }
            }
            return nil
        }

        if shouldStabilizeMarkerArrivalWithHover(directive) {
            navigationSnapshot = .idle
            hover()
            return nil
        }

        navigationSnapshot = NavigationPathSnapshot(
            status: .valid,
            currentWaypointIndex: 0,
            remainingWaypoints: 1,
            pathLengthMeters: directive.distanceToTarget,
            remainingDistanceMeters: directive.distanceToTarget,
            waypoints: [directive.targetWorldPosition],
            start: state.position,
            goal: directive.targetWorldPosition,
            reason: "target_marker"
        )
        return directive
    }

    private func shouldStabilizeMarkerArrivalWithHover(_ directive: AutoNavigationDirective) -> Bool {
        guard selectedDroneProfile.airframeClass == .multirotor,
              mode == .autoPath,
              autoNavigationController.phase == .hold else {
            return false
        }

        let horizontalSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let verticalSpeed = abs(state.velocity.y)
        let hoverHandoffRadius: Float

        if let dropZone = missionPlanState.dropZone,
           missionPlanState.isDeliveryMissionReady,
           let targetMarkerState,
           simd_distance(targetMarkerState.position, dropZone.center) <= 0.001 {
            let releaseRadius = min(dropZone.radius, max(0.8, dropZone.radius * 0.24))
            hoverHandoffRadius = max(0.85, min(1.35, releaseRadius))
        } else {
            hoverHandoffRadius = 0.85
        }

        return directive.distanceToTarget <= hoverHandoffRadius &&
            horizontalSpeed <= 0.95 &&
            verticalSpeed <= 0.55
    }

    private func keyboardAxisInput(from directive: AutoNavigationDirective) -> KeyboardAxisInput {
        let axisIntent = directive.axisIntent
        let speedEnvelope = missionAutopilotAdapter.controlEnvelope(
            for: activeMissionAutopilotPlan,
            currentHorizontalSpeed: simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z)),
            profileMaxSpeed: selectedDroneProfile.maxHorizontalSpeedMps
        )
        let shouldBoostForMissionSpeed = directive.distanceToTarget > 1.5 &&
            autoNavigationController.phase != .hold &&
            speedEnvelope.forceSpeedBoost
        let speedBoost = autoNavigationController.phase == .takeoff ||
            abs(axisIntent.vertical) > 0.72 ||
            shouldBoostForMissionSpeed
        return KeyboardAxisInput(
            forward: (axisIntent.forward * speedEnvelope.axisScale).clamped(to: -1.0...1.0),
            strafe: (axisIntent.strafe * speedEnvelope.axisScale).clamped(to: -1.0...1.0),
            vertical: axisIntent.vertical.clamped(to: -1.0...1.0),
            speedBoost: speedBoost
        )
    }

    private func finishTargetMarkerAutoNavigation() {
        navigationSnapshot = .idle
        if selectedDroneProfile.airframeClass == .multirotor {
            hover()
            return
        }

        mode = .manual
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

    private func updateAutoFlightPath(deltaTime: Float) {
        if autoFlightGoal == nil {
            autoFlightGoal = nextAutoPatrolGoal(resetCycle: true)
            autoPathPlanner.invalidate()
        }

        guard let goal = autoFlightGoal else {
            navigationSnapshot = .idle
            return
        }

        if simd_distance(state.position, goal) < 2.4 {
            autoFlightGoal = nextAutoPatrolGoal(resetCycle: false)
            autoPathPlanner.invalidate()
        }

        guard let activeGoal = autoFlightGoal else {
            navigationSnapshot = .idle
            return
        }

        let travelAltitude = max(3.2, homePosition.y + 4.0)
        var plannedGoal = clampToPlayableBounds(SIMD3<Float>(activeGoal.x, travelAltitude, activeGoal.z))
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
            obstacles: sceneController.environmentObstacles,
            droneRadius: selectedDroneProfile.collisionRadius,
            modeTag: "auto_flight",
            forceRecompute: forceReplan,
            reason: recomputeReason
        )

        autoPathPlanner.updateProgress(
            currentPosition: state.position,
            arrivalRadius: selectedDroneProfile.airframeClass == .multirotor ? 1.6 : 3.4
        )
        navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)

        guard let target = autoPathPlanner.currentTarget() else {
            let holdThrottle = Double(resolvedFlightBaseline(for: .autoPath).cruiseReferenceThrottle)
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, holdThrottle)
            }, markManual: false)
            return
        }

        applyAutopilotTrackingControl(
            target: target,
            targetAltitude: travelAltitude,
            speedScale: collisionAnalysis.riskScore >= 0.55 ? 0.45 : 1.0,
            yawAlignToHome: false,
            deltaTime: deltaTime
        )
    }

    private func updateReturnHomePath(deltaTime: Float) {
        let safeTravelAltitude = min(terrain.maxFlightAltitude - 2.0, max(homePosition.y + 6.0, state.position.y + 2.5))

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
            }, markManual: false)

            if state.position.y >= safeTravelAltitude - 0.35 {
                returnHomeStage = .navigate
                autoPathPlanner.invalidate()
            }

        case .navigate:
            let goal = clampToPlayableBounds(SIMD3<Float>(homePosition.x, safeTravelAltitude, homePosition.z))
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
                obstacles: sceneController.environmentObstacles,
                droneRadius: selectedDroneProfile.collisionRadius,
                modeTag: "return_home",
                forceRecompute: forceReplan,
                reason: recomputeReason
            )

            autoPathPlanner.updateProgress(
                currentPosition: state.position,
                arrivalRadius: selectedDroneProfile.airframeClass == .multirotor ? 1.4 : 3.6
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
            if selectedDroneProfile.airframeClass == .fixedWing, horizontalDistance < 7.0 {
                let cruiseThrottle = Double(resolvedFlightBaseline(for: .returnHome).cruiseReferenceThrottle)
                mode = .manual
                returnHomeStage = .idle
                autoPathPlanner.invalidate()
                navigationSnapshot = .idle
                updateControlValues({ values in
                    values.roll = 0.0
                    values.pitch = max(2.0, min(values.pitch, 6.0))
                    values.yaw = 0.0
                    values.throttle = max(cruiseThrottle, values.throttle * 0.92)
                }, markManual: false)
            } else if horizontalDistance < 1.5 {
                returnHomeStage = .align
            }

        case .align:
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
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
            }, markManual: false)

            let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
            if horizontalDistance < 0.45 {
                returnHomeStage = .descend
            }

        case .descend:
            navigationSnapshot = autoPathPlanner.snapshot(currentPosition: state.position)
            let landingThrottle = Double(resolvedFlightBaseline(for: .landing).landingThrottleReference)
            updateControlValues({ values in
                values.x = Double(homePosition.x)
                values.z = Double(homePosition.z)
                values.y = Double(homePosition.y)
                values.roll = 0.0
                values.pitch = 0.0
                values.yaw = 0.0
                values.throttle = max(0.22, min(values.throttle, landingThrottle))
            }, markManual: false)

            let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
            if horizontalDistance < 0.4 && state.position.y <= homePosition.y + 0.10 && abs(state.velocity.y) < 0.25 {
                mode = .manual
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

    private func applyAutopilotTrackingControl(
        target: SIMD3<Float>,
        targetAltitude: Float,
        speedScale: Float,
        yawAlignToHome: Bool,
        deltaTime: Float,
        yawOverrideRadians: Float? = nil
    ) {
        let headingVector = SIMD2<Float>(target.x - state.position.x, target.z - state.position.z)
        let planarDistance = max(0.001, simd_length(headingVector))
        let direction = headingVector / planarDistance
        let yaw = yawOverrideRadians ?? atan2(-headingVector.x, headingVector.y)
        let pitchToTarget = atan2(target.y - state.position.y, planarDistance)
        let bodyForwardWorld = SIMD2<Float>(sin(state.orientation.z), -cos(state.orientation.z))
        let rightWorld = SIMD2<Float>(cos(state.orientation.z), sin(state.orientation.z))
        let localForward = simd_dot(direction, bodyForwardWorld)
        let localRight = simd_dot(direction, rightWorld)
        let headingErrorRadians = atan2(localRight, localForward)

        let speedBoost: Float = (simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z)) < 1.0 && speedScale > 0.6) ? 1.2 : 1.0
        let controlScale = speedScale * speedBoost
        let flightBaseline = resolvedFlightBaseline(for: mode)

        updateControlValues({ values in
            if selectedDroneProfile.airframeClass == .multirotor {
                values.x = Double(target.x)
                values.z = Double(target.z)
                values.y = Double(targetAltitude)
                values.roll = Double((-headingVector.x * 0.95 * controlScale).clamped(to: -16.0...16.0))
                values.pitch = Double((headingVector.y * 0.95 * controlScale).clamped(to: -16.0...16.0))

                let altitudeError = targetAltitude - state.position.y
                let verticalComp = (altitudeError * 0.06 - state.velocity.y * 0.03) * flightBaseline.effectiveVerticalResponseFactor
                let commandedThrottle = (flightBaseline.hoverLockThrottle + verticalComp).clamped(to: 0.18...0.90)
                let followBlend = (deltaTime * 3.4).clamped(to: 0.06...0.30)
                let blendedThrottle = Float(values.throttle) + (commandedThrottle - Float(values.throttle)) * followBlend
                values.throttle = Double(blendedThrottle.clamped(to: 0.0...1.0))
            } else {
                let altitudeError = targetAltitude - state.position.y
                let bankCommand = (headingErrorRadians.radiansToDegrees * 0.42 * controlScale).clamped(to: -36.0...36.0)
                var pitchCommand = (
                    pitchToTarget.radiansToDegrees * 0.75 +
                    altitudeError * 1.8 -
                    state.velocity.y * 1.4
                ).clamped(to: -6.0...16.0)
                if physicalState.isGroundRestState || state.position.y < 1.2 {
                    pitchCommand = max(pitchCommand, 10.0)
                }
                let throttleTarget = (
                    max(flightBaseline.cruiseReferenceThrottle, 0.58 + 0.16 * speedScale) +
                    altitudeError * 0.035 -
                    state.velocity.y * 0.02
                ).clamped(to: 0.50...1.0)
                values.y = Double(targetAltitude)
                values.roll = Double((-bankCommand).clamped(to: -38.0...38.0))
                values.pitch = Double(pitchCommand)
                values.throttle = max(values.throttle * 0.94, Double(throttleTarget))
            }

            if yawAlignToHome, simd_length(headingVector) < 1.2 {
                values.yaw = 0.0
            } else {
                values.yaw = Double(yaw.radiansToDegrees)
            }
        }, markManual: false)
    }

    private func nextAutoPatrolGoal(resetCycle: Bool) -> SIMD3<Float> {
        let goals = autoPatrolGoals()
        if goals.isEmpty {
            return clampToPlayableBounds(homePosition + SIMD3<Float>(0.0, 4.0, 0.0))
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
        return raw.map { clampToPlayableBounds($0) }
    }

    private func clampToPlayableBounds(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let maxAltitude = max(10.0, terrain.maxFlightAltitude - 2.0)
        let planar = clampPlanarToRadius(
            SIMD2<Float>(point.x, point.z),
            radius: playableBoundaryRadius
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
                let liftOffSpeed = selectedDroneProfile.fixedWingParameters?.minSustainableSpeedMps ?? 9.0
                if physicalState == .airborne || state.position.y >= 1.0 || state.forwardAirspeed >= liftOffSpeed * 0.92 {
                    mode = .manual
                }
            } else {
                let targetAltitude = Float(controlValues.y)
                if physicalState == .airborne && state.position.y >= targetAltitude - 0.08 && abs(state.velocity.y) < 0.45 {
                    mode = .hover
                    lockControlsToCurrentState(overrideThrottle: Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle))
                }
            }
        }

        if mode == .landing,
           physicalState == .landed {
            mode = .manual
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
            manualYawIntent: manualYawIntent
        )
        return builder.build()
    }

    private var canStartTargetMarkerAutoNavigation: Bool {
        guard targetMarkerState != nil else {
            return false
        }
        return canBindMissionTargetToAutopilot
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
    }

    private var activeMissionAutopilotPlan: MissionPlan? {
        activeRouteTargetSource == .mission ? currentMissionPlan : nil
    }

    private func targetMarkerTravelAltitude() -> Float {
        let executionCeiling = max(6.0, terrain.maxFlightAltitude - 2.0)
        let baselineAltitude: Float
        switch selectedDroneProfile.airframeClass {
        case .multirotor:
            baselineAltitude = min(
                executionCeiling,
                max(3.4, homePosition.y + 4.0, state.position.y + (physicalState.isGroundRestState ? 3.0 : 0.8))
            )
        case .fixedWing:
            baselineAltitude = min(
                executionCeiling,
                max(10.0, homePosition.y + 8.0, state.position.y + 3.4)
            )
        }
        return missionAutopilotAdapter.resolvedTravelAltitude(
            for: activeMissionAutopilotPlan,
            baselineAltitude: baselineAltitude,
            terrainMaxAltitude: executionCeiling
        )
    }

    private func buildFlightInputState(from controlState: ResolvedControlState) -> FlightInputState {
        FlightInputState(
            controlState: controlState,
            payloadViewActive: cameraConfiguration.mode == .payload && payloadCameraStatus.isActive,
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
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        return autoNavigationController.status(
            from: SIMD2<Float>(safePosition.x, safePosition.z)
        )
    }

    private func refreshCompassOverlay() {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        compassViewModel.update(
            headingRadians: finiteVector(state.orientation, fallback: lastFiniteState.orientation).z,
            dronePlanarPosition: SIMD2<Float>(safePosition.x, safePosition.z),
            targetMarker: targetMarkerState
        )
    }

    private func refreshPayloadCameraStatus() {
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
        refreshFlightControlDiagnostics()
    }

    private func buildWarnings() -> [String] {
        let fleetWarningStatus = currentFleetStatusSnapshot()
        return DroneWarningBuilder(
            isArmed: isArmed,
            physicalState: physicalState,
            collisionAnalysis: collisionAnalysis,
            weather: weather,
            batteryState: batteryState,
            damageState: damageState,
            selectedDroneProfile: selectedDroneProfile,
            state: state,
            fleetStatus: fleetWarningStatus,
            mode: mode
        ).build()
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
            schemaVersion: 1,
            projectID: currentProjectID,
            projectName: currentProjectName,
            savedAt: Date(),
            selectedDroneModelID: selectedDroneProfile.id,
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
            missionDebrief: missionPersistenceAdapter.debriefForPersistence(missionDebrief)
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
        availableDroneProfiles = LIPODroneModelRepository(abstractParameters: abstract).allProfiles

        let selectedModelID = LIPODroneModelRepository.canonicalModelID(snapshot.selectedDroneModelID)
        if let profile = availableDroneProfiles.first(where: { $0.id == selectedModelID }) {
            selectedDroneProfile = profile
            activeUAVProfile = Self.resolveActiveUAVProfile(for: profile, abstractParameters: abstract)
            sceneController.setDroneProfile(profile)
            resetPayloadForProfileSwitch()
        }

        _ = DroneFlightMode(rawValue: snapshot.flightModeRaw)
        // Stable baseline: always load into manual mode to avoid unexpected auto movement at spawn.
        mode = .manual
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
        isBoundaryBarrierVisible = snapshot.terrain.showsBoundaryBarrier ?? false

        if let cameraMode = CameraMode.fromStoredRaw(snapshot.camera.modeRaw) {
            cameraConfiguration.mode = cameraMode == .payload ? .follow : cameraMode
        }
        cameraConfiguration.fov = snapshot.camera.fov
        cameraConfiguration.sensitivity = snapshot.camera.sensitivity
        cameraConfiguration.smoothing = snapshot.camera.smoothing
        cameraConfiguration.invertLookX = snapshot.camera.invertLookX
        cameraConfiguration.invertLookY = snapshot.camera.invertLookY
        cameraConfiguration.sensitivityProfile = CameraSensitivityProfile(rawValue: snapshot.camera.sensitivityProfileRaw) ?? .medium
        cameraConfiguration.lookNudgeStepDeg = snapshot.camera.lookNudgeStepDeg
        cameraConfiguration.free = FreeCameraState(
            moveSpeed: snapshot.camera.freeMoveSpeed,
            zoomSensitivity: snapshot.camera.freeZoomSensitivity,
            distance: snapshot.camera.freeDistance,
            minDistance: snapshot.camera.freeMinDistance,
            maxDistance: snapshot.camera.freeMaxDistance
        )
        cameraConfiguration.follow = FollowCameraState(
            distance: snapshot.camera.followDistance,
            height: snapshot.camera.followHeight,
            lateralOffset: snapshot.camera.followLateralOffset,
            minDistance: snapshot.camera.followMinDistance,
            maxDistance: snapshot.camera.followMaxDistance
        )
        cameraConfiguration.orbit = OrbitCameraState(
            distance: snapshot.camera.orbitDistance,
            height: snapshot.camera.orbitHeight,
            angularSpeed: snapshot.camera.orbitAngularSpeed,
            minDistance: snapshot.camera.orbitMinDistance,
            maxDistance: snapshot.camera.orbitMaxDistance
        )
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
            payloadState: payloadState
        )
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
            if let messageKey = event.messageKey {
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
                        detailKey: event.messageKey
                    )
                ])
            }
        }

        if didApplyEvent {
            refreshPayloadRuntimeState()
            refreshPayloadCameraStatus()
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
            installedPayloadConfiguration.visualPreset == payloadDraftConfiguration.visualPreset
    }

    private func resolvePayloadMountState() -> PayloadMountState {
        guard activeUAVProfile != nil else {
            return .unavailable
        }

        return payloadState == .attached ? .occupied : .ready
    }

    private func resetPayloadForProfileSwitch() {
        activePayloadReleaseID = nil
        installedPayloadConfiguration = nil
        payloadDraftConfiguration = PayloadController.defaultConfiguration()
        payloadDraftConfiguration.isAttached = false
        payloadState = .noPayload
        payloadStatusMessageKey = nil
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
        let collisionRisk = collisionAnalysis.riskScore.isFinite ? collisionAnalysis.riskScore : 0.0
        let nearestObstacleDistance = collisionAnalysis.nearestObstacleDistance.isFinite
            ? collisionAnalysis.nearestObstacleDistance
            : Float(terrain.worldHalfExtent * 2.0)
        let nearestInterDroneDistance = fleetSnapshot.nearestInterDroneDistance.isFinite
            ? fleetSnapshot.nearestInterDroneDistance
            : Float(terrain.worldHalfExtent * 2.0)

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
            modeTitle: mode.title,
            modeKey: mode.titleKey,
            controlModeKey: flightControlMode.titleKey,
            armStateKey: isArmed ? "arm_state.armed" : "arm_state.disarmed",
            flightState: flight.title,
            flightStateKey: flight.key,
            batteryPercent: Double(batteryState.chargePercent),
            batteryHealthPercent: Double(batteryState.healthPercent),
            powerDrawW: Double(batteryState.powerDrawW.isFinite ? batteryState.powerDrawW : 0.0),
            estimatedRemainingMin: Double(batteryState.remainingTimeSec / 60.0),
            weatherPreset: weather.preset.title,
            weatherPresetKey: weather.preset.titleKey,
            weatherIntensity: Double(weather.normalizedIntensity),
            collisionRisk: Double(collisionRisk),
            nearestObstacleDistance: Double(nearestObstacleDistance),
            nearestObstacleSource: collisionAnalysis.nearestObstacleSource ?? "n/a",
            autoNavigationActive: autoNavigationStatus.isActive,
            targetDistanceMeters: autoNavigationStatus.distanceToTarget.isFinite ? Double(autoNavigationStatus.distanceToTarget) : .nan,
            targetBearingDegrees: autoNavigationStatus.bearingDegrees.isFinite ? Double(autoNavigationStatus.bearingDegrees) : .nan,
            pathStatus: navigationSnapshot.status.rawValue,
            currentWaypointIndex: navigationSnapshot.currentWaypointIndex,
            remainingWaypoints: navigationSnapshot.remainingWaypoints,
            pathLengthMeters: Double(navigationSnapshot.pathLengthMeters),
            pathRemainingDistanceMeters: Double(navigationSnapshot.remainingDistanceMeters),
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

    private func refreshTerrainMapSnapshot(recordTrail: Bool) {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        let safeOrientation = finiteVector(state.orientation, fallback: lastFiniteState.orientation)
        let dronePlanarPosition = SIMD2<Float>(safePosition.x, safePosition.z)
        let dock = sceneController.currentDockSpawnPoint()
        let extent = max(1.0, terrain.worldHalfExtent)
        let viewport = currentTacticalMapViewport()
        let missionOverlay = terrainMapMissionOverlay(viewport: viewport)

        if recordTrail {
            appendTerrainMapTrailSample(dronePlanarPosition)
        } else if terrainMapTrail.isEmpty {
            terrainMapTrail = [dronePlanarPosition]
        }

        let mapObjects = sceneController.environmentMapDescriptors
            .filter { descriptor in
                descriptor.kind != .distantBelt &&
                abs(descriptor.position.x) <= extent + descriptor.boundingRadius &&
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

        let nextSnapshot = TerrainMapSnapshot(
            preset: terrain.preset,
            worldHalfExtent: extent,
            signalBoundaryRadius: playableBoundaryRadius,
            dockPosition: SIMD2<Float>(dock.x, dock.z),
            dronePosition: dronePlanarPosition,
            droneYawRadians: safeOrientation.z,
            droneAltitude: max(0.0, safePosition.y),
            targetMarkerPosition: targetMarkerState?.position,
            missionRoutePoints: missionOverlay.routePoints,
            missionWaypoints: missionOverlay.waypoints,
            noFlyZones: missionOverlay.noFlyZones,
            trail: terrainMapTrail,
            objects: mapObjects
        )

        if nextSnapshot != terrainMapSnapshot {
            terrainMapSnapshot = nextSnapshot
        }

        if isMissionMapVisible {
            refreshTacticalMapState()
        }
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

        if let currentMissionPlan, !currentMissionPlan.waypoints.isEmpty {
            routePoints = currentMissionPlan.routePoints
            overlayWaypoints = currentMissionPlan.waypoints.map { target in
                TerrainMapMissionWaypoint(
                    id: target.waypointID,
                    label: target.label,
                    position: target.position,
                    isActive: missionExecutionState.activeTarget?.waypointID == target.waypointID,
                    isCompleted: missionExecutionState.waypointProgress.contains {
                        $0.target.waypointID == target.waypointID && $0.state == .completed
                    }
                )
            }
            noFlyZones = currentMissionPlan.zones.filter { $0.type == .noFlyZone }
        } else {
            let sourceDraft = isMissionMapVisible ? workingTacticalMissionDraft : committedTacticalMissionDraft
            let previewRoute = missionPreviewBuilder.buildPreview(
                draft: sourceDraft,
                viewport: viewport
            )
            routePoints = previewRoute?.points ?? []
            overlayWaypoints = sourceDraft.waypoints.map { waypoint in
                TerrainMapMissionWaypoint(
                    id: waypoint.id,
                    label: waypoint.label,
                    position: waypoint.position,
                    isActive: missionExecutionState.activeTarget?.waypointID == waypoint.id,
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
        markManual: Bool
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

        if next == controlValues {
            return
        }

        controlValues = next
        hasUnsavedChanges = true
        if markManual {
            cancelTargetMarkerAutoNavigation()
            mode = .manual
        }
    }

    private var playableBoundaryRadius: Float {
        max(24.0, terrain.signalBoundaryRadius)
    }

    private var reentryBoundaryRadius: Float {
        max(8.0, playableBoundaryRadius - SignalLossConfiguration.reentryInset)
    }

    private func clampedPlanarPosition(_ planarPosition: SIMD2<Float>) -> SIMD2<Float> {
        clampPlanarToRadius(planarPosition, radius: playableBoundaryRadius)
    }

    private func clampPlanarToRadius(_ planar: SIMD2<Float>, radius: Float) -> SIMD2<Float> {
        let safeRadius = max(1.0, radius)
        let distance = simd_length(planar)
        guard distance > safeRadius, distance > 0.0001 else {
            return planar
        }
        return planar / distance * safeRadius
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
        activeRouteTargetSource = marker == nil ? .none : source
        targetMarkerState = marker

        if let marker {
            autoNavigationController.replaceTarget(marker)
            autoPathPlanner.invalidate()
            autoFlightGoal = nil
            navigationSnapshot = .idle

            if startNavigationIfPossible, canStartTargetMarkerAutoNavigation {
                autoNavigationController.start(safeTravelAltitude: targetMarkerTravelAltitude())
                mode = .autoPath
            }
        } else {
            autoNavigationController.clearTarget()
            autoPathPlanner.invalidate()
            if mode == .autoPath {
                mode = .manual
            }
            navigationSnapshot = .idle
        }

        isInMissionDropZone = missionPlanState.dropZone?.contains(currentPlanarPosition()) ?? false
        refreshTerrainMapSnapshot(recordTrail: false)
        refreshCompassOverlay()
        refreshFlightControlDiagnostics()
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
        committedTacticalMissionDraft = .empty
        workingTacticalMissionDraft = .empty
        tacticalMapMode = .waypoint
        currentMissionPlan = nil
        missionExecutionState = .idle
        missionRuntimeMonitor.reset()
        missionSafetyState = .idle
        missionEventRecorder.reset()
        missionTimeline = nil
        missionObservation.reset()
        refreshTacticalMapState()
        refreshMissionStatus()
    }

    private func currentTacticalMapViewport() -> MapViewportState {
        let safePosition = finiteVector(state.position, fallback: lastFiniteState.position)
        let dock = sceneController.currentDockSpawnPoint()
        return MapViewportState(
            center: SIMD2<Float>(safePosition.x, safePosition.z),
            worldHalfExtent: max(1.0, terrain.worldHalfExtent),
            signalBoundaryRadius: playableBoundaryRadius,
            dronePosition: SIMD2<Float>(safePosition.x, safePosition.z),
            dockPosition: SIMD2<Float>(dock.x, dock.z),
            droneAltitudeMeters: max(0.0, safePosition.y),
            dockAltitudeMeters: max(0.0, dock.y),
            terrainMaxAltitudeMeters: max(0.0, terrain.maxFlightAltitude),
            airframeClass: selectedDroneProfile.airframeClass,
            profileMaxHorizontalSpeedMps: max(0.0, selectedDroneProfile.maxHorizontalSpeedMps)
        )
    }

    private func refreshTacticalMapState() {
        let nextState = tacticalMapCoordinator.buildState(
            isVisible: isMissionMapVisible,
            mode: tacticalMapMode,
            viewport: currentTacticalMapViewport(),
            committedDraft: committedTacticalMissionDraft,
            workingDraft: workingTacticalMissionDraft
        )

        if nextState != tacticalMapState {
            tacticalMapState = nextState
        }
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
            currentMarker: targetMarkerState,
            adapter: missionAutopilotAdapter
        )
        let runtimeMonitor = missionRuntimeMonitor.evaluate(
            executionState: missionExecutionState,
            autoNavigationStatus: currentAutoNavigationStatus(),
            currentMarker: targetMarkerState,
            missionOwnsTargetSource: activeRouteTargetSource == .mission,
            flightMode: mode
        )

        var safetyState = missionSafetyEvaluator.evaluate(
            draftStatus: tacticalMapState.draftStatus,
            currentPlan: currentMissionPlan,
            executionState: missionExecutionState,
            authorityState: authorityState,
            runtimeMonitor: runtimeMonitor,
            canStartMissionAutopilot: canBindMissionTargetToAutopilot,
            batteryState: batteryState,
            collisionAnalysis: collisionAnalysis,
            thermalState: thermalState,
            signalState: signalState
        )

        let failsafeMode = missionFailsafeCoordinator.resolve(
            executionState: missionExecutionState,
            safetyState: safetyState,
            airframeClass: selectedDroneProfile.airframeClass,
            flightMode: mode
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
                activateReturnHome()
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
        let nextSnapshot = missionStatusResolver.resolve(
            draftStatus: tacticalMapState.draftStatus,
            currentPlan: currentMissionPlan,
            executionState: missionExecutionState,
            safetyState: missionSafetyState,
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

    private func updateSignalLossSequence(deltaTime: Float) {
        switch signalState {
        case .normal:
            if isOutsidePlayableBounds(state.position) {
                signalState = .outOfBoundsWarning
                signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
                signalLossSecondAccumulator = 0.0
            }

        case .outOfBoundsWarning, .signalDegrading:
            if isInsidePlayableRecoveryBounds(state.position) {
                clearSignalLossState(restoringInputMode: false)
                return
            }

            signalLossSecondAccumulator += deltaTime
            while signalLossSecondAccumulator >= 1.0 {
                signalLossSecondAccumulator -= 1.0
                signalCountdownSecondsRemaining -= 1

                if signalCountdownSecondsRemaining <= 0 {
                    enterSignalLostState()
                    return
                }

                if signalCountdownSecondsRemaining < SignalLossConfiguration.countdownDuration {
                    signalState = .signalDegrading
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

    private func enterSignalLostState() {
        guard signalState != .signalLost else {
            return
        }

        signalState = .signalLost
        signalCountdownSecondsRemaining = 0
        signalLossSecondAccumulator = 0.0
        cancelTargetMarkerAutoNavigation()
        cameraLookVelocity = .zero
        controllerUIBridge.cancelTextInput()
        keyboardInputService.setInputProcessingMode(.editing)
        inputManager.reset()
        resetFlightControlRouting()
        hasUnsavedChanges = true
    }

    private func clearSignalLossState(restoringInputMode: Bool) {
        let hadBlockingState = signalState.isInteractionBlocking
        signalState = .normal
        signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
        signalLossSecondAccumulator = 0.0

        if restoringInputMode && hadBlockingState {
            keyboardInputService.setInputProcessingMode(.flight)
            inputManager.reset()
        }
        refreshFlightControlDiagnostics()
    }

    private func isOutsidePlayableBounds(_ position: SIMD3<Float>) -> Bool {
        simd_length(SIMD2<Float>(position.x, position.z)) > playableBoundaryRadius
    }

    private func isInsidePlayableRecoveryBounds(_ position: SIMD3<Float>) -> Bool {
        simd_length(SIMD2<Float>(position.x, position.z)) <= reentryBoundaryRadius
    }

    private func enforceRuntimeSafetyAndBounds(context: String) {
        let spawn = sceneController.currentDockSpawnPoint()

        if !isFinite(state.position) || !isFinite(state.velocity) || !isFinite(state.orientation) || !isFinite(state.angularVelocity) || !state.throttle.isFinite || !state.motorThrottle.isFinite {
            print("[RuntimeSafety][\(context)] Non-finite state detected, restoring last finite state.")
            state = lastFiniteState
            state.position = SIMD3<Float>(state.position.x, max(0.0, state.position.y), state.position.z)
            mode = .manual
            transitionPhysicalState(isArmed ? .armedOnGround : .disarmed)
            controlValues = neutralControls(from: state)
            return
        }

        let halfExtent = terrain.worldHalfExtent
        let maxAltitude = max(80.0, terrain.maxFlightAltitude)

        if state.position.y < 0.0 {
            state.position.y = 0.0
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
            mode = .manual
            transitionPhysicalState(.disarmed)
        }

        if !controlValues.x.isFinite || !controlValues.y.isFinite || !controlValues.z.isFinite ||
            !controlValues.roll.isFinite || !controlValues.pitch.isFinite || !controlValues.yaw.isFinite || !controlValues.throttle.isFinite {
            controlValues = neutralControls(from: state)
        } else {
            controlValues.x = controlValues.x.clamped(to: -Double(halfExtent)...Double(halfExtent))
            controlValues.y = controlValues.y.clamped(to: 0.0...Double(maxAltitude))
            controlValues.z = controlValues.z.clamped(to: -Double(halfExtent)...Double(halfExtent))
        }

        lastFiniteState = state
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func supportSurfaceY(for position: SIMD3<Float>) -> Float {
        sceneController.supportSurfaceHeight(
            at: SIMD2<Float>(position.x, position.z),
            clearanceRadius: max(0.36, selectedDroneProfile.collisionRadius * 0.48)
        ) ?? 0.0
    }

    private func heightAboveSupportSurface(for position: SIMD3<Float>) -> Float {
        position.y - supportSurfaceY(for: position)
    }

    private func applySupportSurfaceConstraint(previousState: DroneState) {
        let supportY = supportSurfaceY(for: state.position)
        guard supportY > 0.0 else {
            return
        }

        let wasAboveSurface = previousState.position.y > supportY + 0.06
        let nearSurface = state.position.y <= supportY + 0.14
        let descending = state.velocity.y <= 0.24 || previousState.position.y >= state.position.y
        guard nearSurface, descending else {
            return
        }

        if state.position.y < supportY || wasAboveSurface {
            state.position.y = max(state.position.y, supportY)
            if state.velocity.y < 0.0 {
                state.velocity.y = 0.0
            }
            state.velocity.x *= 0.96
            state.velocity.z *= 0.96
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
        let spawn = sceneController.currentDockSpawnPoint()
        let halfExtent = terrain.worldHalfExtent
        let maxAltitude = max(80.0, terrain.maxFlightAltitude)

        if forceSpawnRelocation {
            state.position = spawn
            state.orientation = spawnOrientation(for: selectedDroneProfile)
            homePosition = spawn
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
        state.mode = .manual
        mode = .manual
        groundContactAccumulator = 0.0
        stableGroundAccumulator = 0.0
        airborneAccumulator = 0.0
        impactSeverityAccumulator = 0.0
        resetTerrainMapTrail()

        if weather.preset == .normal || hardReset {
            weather.intensity = 0.0
            weather.windSpeedMps = 0.0
            weather.gusts = 0.0
        }

        if state.position.y <= 0.05 {
            state.orientation.x = 0.0
            state.orientation.y = 0.0
        }

        lastFiniteState = state
    }

    private func spawnOrientation(for profile: DroneModelProfile) -> SIMD3<Float> {
        if profile.airframeClass == .fixedWing, profile.launchMethod == .handLaunch {
            return SIMD3<Float>(0.0, 0.0, Float.pi * 0.25)
        }
        return .zero
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

    private func settleDisarmedGroundedState() {
        state.position.y = supportSurfaceY(for: state.position)
        state.velocity = .zero
        state.angularVelocity = .zero
        state.rotorAngularSpeed = .zero
        state.forwardAirspeed = 0.0
        state.throttle = 0.0
        state.motorThrottle = 0.0
        state.orientation.x = 0.0
        state.orientation.y = 0.0
        state.mode = .manual
        mode = .manual
        collisionCooldown = 0.0
        groundContactAccumulator = 0.0
        stableGroundAccumulator = 0.0
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
        let nearGround = (state.position.y - supportY) <= 0.08
        let stableGroundContact = nearGround &&
            abs(state.velocity.y) <= 0.24 &&
            planarSpeed <= 0.75 &&
            angularSpeed <= 1.8
        let confidentlyAirborne = (state.position.y - supportY) >= 0.18 || (!nearGround && abs(state.velocity.y) > 0.28)
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

        if previousState.position.y > previousSupportY + 0.06 && state.position.y <= supportY + 0.02 {
            let touchdownSeverity =
                abs(previousState.velocity.y) * 1.45 +
                simd_length(SIMD2<Float>(previousState.velocity.x, previousState.velocity.z)) * 0.72 +
                simd_length(previousState.angularVelocity) * 0.42 +
                (abs(previousState.orientation.x) + abs(previousState.orientation.y)) * 0.45
            impactSeverityAccumulator = max(impactSeverityAccumulator, touchdownSeverity)
        }

        let severeAttitudeOnGround = nearGround && (abs(state.orientation.x) > 1.22 || abs(state.orientation.y) > 1.22)
        let hasCrashCondition =
            physicalState == .crashed ||
            damageState.isFlightCritical ||
            impactSeverityAccumulator > 4.8 ||
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

        transitionPhysicalState(nextPhysicalState)

        if nextPhysicalState == .crashed, isArmed {
            disarm(forceEmergency: true)
        }
    }

    private func applyGroundedSafetyIfNeeded(deltaTime: Float) {
        let supportY = supportSurfaceY(for: state.position)
        guard state.position.y <= supportY + 0.08 else {
            return
        }

        let requestedThrottle = max(Float(controlValues.throttle), state.throttle, state.motorThrottle)
        let idleHoldThreshold = resolvedFlightBaseline(for: mode).groundedIdleThreshold

        switch physicalState {
        case .airborne, .takeoffTransition, .landing:
            return
        case .crashed:
            state.position.y = supportY
            state.velocity.x *= max(0.0, 1.0 - deltaTime * 12.0)
            state.velocity.z *= max(0.0, 1.0 - deltaTime * 12.0)
            state.velocity.y = 0.0
            state.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - deltaTime * 14.0))
            state.throttle = 0.0
            state.motorThrottle = 0.0
            state.rotorAngularSpeed = .zero
        case .disarmed, .armedOnGround, .landed:
            if !isArmed {
                settleDisarmedGroundedState()
                return
            }
            state.position.y = supportY
            state.velocity.x *= max(0.0, 1.0 - deltaTime * 14.0)
            state.velocity.z *= max(0.0, 1.0 - deltaTime * 14.0)
            state.velocity.y = 0.0
            state.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - deltaTime * 18.0))
            state.orientation.x = approach(current: state.orientation.x, target: 0.0, rate: 5.8, dt: deltaTime)
            state.orientation.y = approach(current: state.orientation.y, target: 0.0, rate: 5.8, dt: deltaTime)

            if physicalState == .disarmed {
                state.throttle = 0.0
                state.motorThrottle = 0.0
                state.rotorAngularSpeed = .zero
            } else if requestedThrottle <= idleHoldThreshold {
                state.throttle = min(state.throttle, 0.08)
                state.motorThrottle = min(state.motorThrottle, 0.08)
            }
        }

        if simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z)) < 0.02 {
            state.velocity.x = 0.0
            state.velocity.z = 0.0
        }
        if simd_length(state.angularVelocity) < 0.02 {
            state.angularVelocity = .zero
        }
        if abs(state.orientation.x) < 0.0005 { state.orientation.x = 0.0 }
        if abs(state.orientation.y) < 0.0005 { state.orientation.y = 0.0 }
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
