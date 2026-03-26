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
    static let boundaryInset: Float = 0.6
    static let reentryInset: Float = 0.35
}

extension DroneSimulationViewModel {
    struct TerrainMapObject: Identifiable, Equatable {
        let id: UUID
        let kind: EnvironmentObjectKind
        let position: SIMD2<Float>
        let footprint: SIMD2<Float>
    }

    struct TerrainMapSnapshot: Equatable {
        let worldHalfExtent: Float
        let dockPosition: SIMD2<Float>
        let dronePosition: SIMD2<Float>
        let droneYawRadians: Float
        let droneAltitude: Float
        let trail: [SIMD2<Float>]
        let objects: [TerrainMapObject]

        static let empty = TerrainMapSnapshot(
            worldHalfExtent: TerrainConfiguration.default.worldHalfExtent,
            dockPosition: SIMD2<Float>(repeating: 0.0),
            dronePosition: SIMD2<Float>(repeating: 0.0),
            droneYawRadians: 0.0,
            droneAltitude: 0.0,
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
    @Published private(set) var terrainMapSnapshot: TerrainMapSnapshot

    var scene: SCNScene {
        sceneController.scene
    }

    var activeCameraNode: SCNNode {
        sceneController.pointOfView(for: cameraConfiguration.mode)
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
    private let collisionService: CollisionAnalysisService
    private let batteryThermalService: BatteryThermalSimulationService
    private let telemetryExporter: TelemetryExporting
    private let projectStorage: ProjectStorageManaging
    private let fleetManager: DroneFleetManager
    private let autoPathPlanner: AutoPathPlannerService

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
    private var autoFlightGoal: SIMD3<Float>?
    private var autoFlightGoalIndex: Int = 0
    private var returnHomeStage: ReturnHomeStage = .idle
    private var navigationSnapshot: NavigationPathSnapshot = .idle
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

    init(
        physicsEngine: DronePhysicsEngine = SimpleDronePhysicsEngine(),
        keyboardInputService: KeyboardInputProviding = KeyboardInputService(),
        collisionService: CollisionAnalysisService = CollisionAnalysisService(),
        batteryThermalService: BatteryThermalSimulationService = BatteryThermalSimulationService(),
        telemetryExporter: TelemetryExporting = TelemetryExportService(),
        projectStorage: ProjectStorageManaging = ProjectStorageService(),
        fleetManager: DroneFleetManager = DroneFleetManager(),
        autoPathPlanner: AutoPathPlannerService = AutoPathPlannerService(),
        initialProjectID: String? = nil,
        initialProjectName: String? = nil
    ) {
        self.physicsEngine = physicsEngine
        self.keyboardInputService = keyboardInputService
        self.collisionService = collisionService
        self.batteryThermalService = batteryThermalService
        self.telemetryExporter = telemetryExporter
        self.projectStorage = projectStorage
        self.fleetManager = fleetManager
        self.autoPathPlanner = autoPathPlanner

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
        self.terrainMapSnapshot = .empty
        self.telemetry = .zero
        self.cachedDiagnostics = .zero

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

        homePosition = sceneController.currentDockSpawnPoint()
        lastFiniteState = state
        resetTerrainMapTrail()
        refreshTerrainMapSnapshot(recordTrail: false)
        telemetry = buildTelemetrySnapshot()

        logAvailableUAVCatalog(models: models)
        refreshKeyBindingDiagnostics()
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
        installedPayloadConfiguration = attachedConfiguration
        payloadDraftConfiguration = attachedConfiguration
        payloadState = .attached
        payloadStatusMessageKey = "payload.message.attached"
        sceneController.attachPayloadVisual(attachedConfiguration)
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
        refreshPayloadRuntimeState()
        hasUnsavedChanges = true
    }

    func arm() {
        ensureSimulationRunning()
        guard physicalState.permitsRearm, !damageState.isFlightCritical else {
            return
        }
        isArmed = true
        if state.position.y <= 0.08 {
            transitionPhysicalState(.armedOnGround)
        }
        if state.position.y <= 0.05 {
            updateControlValues({ values in
                values.throttle = max(values.throttle, selectedDroneProfile.airframeClass == .multirotor ? 0.06 : 0.10)
            }, markManual: false)
        }
    }

    func disarm(forceEmergency: Bool = false) {
        isArmed = false
        if forceEmergency {
            mode = .emergencyStop
        } else if state.position.y <= 0.1 {
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
        manualYawIntent = 0.0
        keyboardInputService.resetTransientState()

        if state.position.y <= 0.08 || physicalState.isGroundRestState {
            settleDisarmedGroundedState()
        }
    }

    func reset() {
        ensureSimulationRunning()
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
        sceneController.resetCameraRuntimeState()
        refreshTerrainMapSnapshot(recordTrail: false)
        warnings = buildWarnings()
        telemetry = buildTelemetrySnapshot()
        hasUnsavedChanges = true
    }

    func takeoff() {
        ensureSimulationRunning()
        guard isArmed else {
            return
        }
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
        mode = .autoPath
        returnHomeStage = .idle
        autoPathPlanner.invalidate()
        autoFlightGoal = nextAutoPatrolGoal(resetCycle: true)
        navigationSnapshot = .idle
    }

    func activateReturnHome() {
        ensureSimulationRunning()
        mode = .returnHome
        returnHomeStage = .ascend
        autoFlightGoal = nil
        autoPathPlanner.invalidate()
        navigationSnapshot = .idle
    }

    func activateEmergencyStop() {
        ensureSimulationRunning()
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
        cameraConfiguration.mode = mode
        syncCameraSystem(from: oldMode)
    }

    func cycleCameraMode() {
        let oldMode = cameraConfiguration.mode
        let nextMode = cameraConfiguration.mode.next()
        cameraConfiguration.mode = nextMode
        syncCameraSystem(from: oldMode)
    }

    func setCameraPreset(_ preset: CameraPreset) {
        let previousMode = cameraConfiguration.mode
        selectedCameraPreset = preset
        cameraConfiguration.applyPreset(preset)
        syncCameraSystem(from: previousMode, resetOrientation: true)
    }

    func resetCameraToPreset() {
        let previousMode = cameraConfiguration.mode
        cameraConfiguration.applyPreset(selectedCameraPreset)
        syncCameraSystem(from: previousMode, resetOrientation: true)
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
    }

    func endKeyBindingCapture() {
        keyboardInputService.setInputProcessingMode(.flight)
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

    func setActiveCameraDistance(_ value: Double) {
        cameraConfiguration.setCameraDistance(Float(value))
    }

    func toggleCompactTelemetryHUD() {
        isCompactTelemetryHUDEnabled.toggle()
    }

    var supportsDistanceControl: Bool {
        cameraConfiguration.mode != .fpv
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
        cancelPendingTerrainDensityRegeneration()
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
            return
        }

        let dt = Float(max(1.0 / 240.0, min(now - lastTimestamp, 1.0 / 20.0)))
        self.lastTimestamp = now
        simulationTime += dt
        impactSeverityAccumulator = max(0.0, impactSeverityAccumulator - dt * 3.6)

        processKeyboardActions()
        applyContinuousCameraLook(deltaTime: dt)

        guard isSimulationRunning else {
            sceneController.update(
                with: state,
                camera: cameraConfiguration,
                damage: damageState,
                thermal: thermalState,
                diagnosticMode: diagnosticMode,
                deltaTime: 0.0
            )
            syncPayloadLifecycleEvents()
            return
        }

        if signalState.isInteractionBlocking {
            renderSignalLossFrame()
            syncPayloadLifecycleEvents()
            return
        }

        collisionCooldown = max(0.0, collisionCooldown - dt)

        applyKeyboardControls(deltaTime: dt)
        updateAutopilotTargets(deltaTime: dt)
        let pathfindingMs = autoPathPlanner.lastPlanDurationMs

        let fleetObstacles = updateFleetStatus(deltaTime: dt)

        collisionAnalysis = collisionService.analyze(
            input: CollisionAnalysisInput(
                dronePosition: state.position,
                droneVelocity: state.velocity,
                droneRadius: selectedDroneProfile.collisionRadius,
                obstacles: sceneController.environmentObstacles + fleetObstacles,
                weather: weather
            )
        )

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
        let physicsTimeMs = (CACurrentMediaTime() - physicsStart) * 1000.0

        if collisionAnalysis.nearestObstacleDistance <= -0.02,
           simd_length(state.velocity) > 0.45,
           collisionCooldown <= 0.0 {
            applyCollisionDamage()
            collisionCooldown = 0.7
        }

        updatePhysicalState(previousState: previousState, deltaTime: dt)
        applyGroundedSafetyIfNeeded(deltaTime: dt)
        handleModeTransitions()
        enforceRuntimeSafetyAndBounds(context: "tick.post_mode")
        updateSignalLossSequence(deltaTime: dt)

        if signalState.isInteractionBlocking {
            renderSignalLossFrame()
            syncPayloadLifecycleEvents()
            return
        }

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

        autosaveAccumulator += dt
        if autosaveAccumulator >= 6.0 {
            performAutosaveIfNeeded()
            autosaveAccumulator = 0.0
        }
    }

    private func applyCollisionDamage() {
        let impact = simd_length(state.velocity)
        lastCollisionSource = collisionAnalysis.nearestObstacleSource ?? "unknown"
        damageState = damageState.applyingCollisionDamage(impactEnergy: impact)
        impactSeverityAccumulator = max(
            impactSeverityAccumulator,
            impact + simd_length(state.angularVelocity) * 0.42 + max(0.0, -collisionAnalysis.nearestObstacleDistance) * 3.4
        )

        let penetration = max(0.0, -collisionAnalysis.nearestObstacleDistance)
        if penetration > 0.0001,
           let obstacleID = collisionAnalysis.nearestObstacleID,
           let obstacleCenter = sceneController.obstacleCenter(for: obstacleID) {
            var away = state.position - obstacleCenter
            away.y = 0.0
            if simd_length_squared(away) < 0.0001 {
                away = SIMD3<Float>(0.0, 0.0, 1.0)
            } else {
                away = simd_normalize(away)
            }
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

    private func applyKeyboardControls(deltaTime: Float) {
        let axis = keyboardInputService.currentAxisInput()
        let yawInput = keyboardInputService.currentYawInput()
        let hasAnyInput =
            abs(axis.forward) > 0.001 ||
            abs(axis.strafe) > 0.001 ||
            abs(axis.vertical) > 0.001 ||
            abs(yawInput.intent) > 0.001

        manualYawIntent = yawInput.intent * (yawInput.speedBoost ? 1.35 : 1.0)

        let maxAltitude = Double(terrain.maxFlightAltitude)

        if selectedDroneProfile.airframeClass == .fixedWing {
            guard hasAnyInput else {
                return
            }
            mode = .manual
            updateControlValues({ values in
                let throttleDelta = Double(axis.vertical) * (axis.speedBoost ? 0.55 : 0.32) * Double(deltaTime)
                values.throttle = (values.throttle + throttleDelta).clamped(to: 0.0...1.0)
                values.roll = Double((-axis.strafe * (flightControlMode == .acro ? 62.0 : 32.0)).clamped(to: -85.0...85.0))
                values.pitch = Double((-axis.forward * (flightControlMode == .acro ? 54.0 : 24.0)).clamped(to: -85.0...85.0))
                values.yaw = Double(state.orientation.z.radiansToDegrees)
                values.y = state.position.y > 0.05
                    ? Double(state.position.y).clamped(to: 0.0...maxAltitude)
                    : values.y.clamped(to: 0.0...maxAltitude)
            }, markManual: false)
            return
        }

        if hasAnyInput {
            mode = .manual
        }

        let climb = axis.vertical * (axis.speedBoost ? 5.4 : 3.0) * deltaTime
        let pitchScale: Float = flightControlMode == .acro ? 52.0 : 28.0
        let rollScale: Float = flightControlMode == .acro ? 52.0 : 26.0

        updateControlValues({ values in
            values.y = (values.y + Double(climb)).clamped(to: 0.0...maxAltitude)

            let verticalThrottleDelta = Double(axis.vertical) * (axis.speedBoost ? 0.40 : 0.26) * Double(deltaTime)
            values.throttle = (values.throttle + verticalThrottleDelta).clamped(to: 0.0...1.0)
            values.yaw = Double(state.orientation.z.radiansToDegrees)

            switch flightControlMode {
            case .stabilized, .hoverAssist:
                // W must command forward acceleration for multirotors (nose down => negative pitch in this frame convention).
                values.pitch = Double((-axis.forward * pitchScale).clamped(to: -36.0...36.0))
                values.roll = Double((-axis.strafe * rollScale).clamped(to: -36.0...36.0))
            case .acro:
                values.pitch = Double((-axis.forward * pitchScale).clamped(to: -82.0...82.0))
                values.roll = Double((-axis.strafe * rollScale).clamped(to: -82.0...82.0))
            }
        }, markManual: false)
    }

    private func processKeyboardActions() {
        guard !signalState.isInteractionBlocking else {
            _ = keyboardInputService.consumeActions()
            return
        }
        let actions = keyboardInputService.consumeActions()
        for action in actions {
            switch action {
            case .requestHover:
                hover()
            case .requestReset:
                reset()
            case .releasePayload:
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
            case .toggleFPV:
                setCameraMode(cameraConfiguration.mode == .fpv ? .follow : .fpv)
            case .toggleTerrainMap:
                toggleTerrainMap()
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
            }
        }
    }

    private func applyContinuousCameraLook(deltaTime: Float) {
        guard cameraConfiguration.mode == .fpv, !signalState.isInteractionBlocking else {
            cameraLookVelocity = .zero
            return
        }

        let look = keyboardInputService.currentLookInput()
        let speedMultiplier: Float = look.speedBoost ? 1.85 : 1.0
        let targetVelocity = SIMD2<Float>(look.yaw, look.pitch)
            * (92.0 * speedMultiplier * cameraConfiguration.effectiveLookSensitivity)

        let accelerationBlend = (deltaTime * 12.0).clamped(to: 0.0...1.0)
        cameraLookVelocity = simd_mix(
            cameraLookVelocity,
            targetVelocity,
            SIMD2<Float>(repeating: accelerationBlend)
        )

        if abs(look.yaw) < 0.001, abs(look.pitch) < 0.001 {
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
        }
    }

    private func updateAutopilotTargets(deltaTime: Float) {
        switch mode {
        case .autoPath:
            updateAutoFlightPath(deltaTime: deltaTime)

        case .returnHome:
            updateReturnHomePath(deltaTime: deltaTime)

        case .hover:
            navigationSnapshot = .idle
            let hoverBaseline = Double(resolvedFlightBaseline(for: .hover).hoverLockThrottle)
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(max(0.28, hoverBaseline - 0.04), min(values.throttle, hoverBaseline + 0.06))
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
            if horizontalDistance < 1.5 {
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
        deltaTime: Float
    ) {
        let headingVector = SIMD2<Float>(target.x - state.position.x, target.z - state.position.z)
        let planarDistance = max(0.001, simd_length(headingVector))
        let yaw = atan2(-headingVector.x, headingVector.y)
        let pitchToTarget = atan2(target.y - state.position.y, planarDistance)

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
                values.y = Double(targetAltitude)
                values.roll = Double((-headingVector.x * 1.8 * controlScale).clamped(to: -38.0...38.0))
                values.pitch = Double((pitchToTarget.radiansToDegrees).clamped(to: -22.0...22.0))
                values.throttle = max(values.throttle, Double(max(flightBaseline.cruiseReferenceThrottle, 0.55 + 0.18 * speedScale)))
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
        let half = max(4.0, terrain.worldHalfExtent - 1.2)
        let maxAltitude = max(10.0, terrain.maxFlightAltitude - 2.0)
        return SIMD3<Float>(
            point.x.clamped(to: -half...half),
            point.y.clamped(to: 0.0...maxAltitude),
            point.z.clamped(to: -half...half)
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
            controlMode: flightControlMode,
            manualYawIntent: manualYawIntent
        )
        return builder.build()
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
            )
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
           let mapScale = MapScale(rawValue: mapScaleRaw) {
            terrain.mapScale = mapScale
        } else {
            terrain.mapScale = .x16
        }
        terrain.density = snapshot.terrain.density
        terrain.seed = snapshot.terrain.seed
        terrain.safeSpawnRadius = snapshot.terrain.safeSpawnRadius > 0.1
            ? snapshot.terrain.safeSpawnRadius
            : recommendedSafeSpawnRadius(for: terrain.mapScale)
        isBoundaryBarrierVisible = snapshot.terrain.showsBoundaryBarrier ?? false

        if let cameraMode = CameraMode.fromStoredRaw(snapshot.camera.modeRaw) {
            cameraConfiguration.mode = cameraMode
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

        homePosition = state.position
        wingmen.removeAll()
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
            if event.state == .cleanedUp {
                activePayloadReleaseID = nil
            }
            didApplyEvent = true
        }

        if didApplyEvent {
            refreshPayloadRuntimeState()
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
        sceneController.clearDroppedPayloadVisuals()
        sceneController.removePayloadVisual()
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
            pathStatus: navigationSnapshot.status.rawValue,
            currentWaypointIndex: navigationSnapshot.currentWaypointIndex,
            remainingWaypoints: navigationSnapshot.remainingWaypoints,
            pathLengthMeters: Double(navigationSnapshot.pathLengthMeters),
            pathRemainingDistanceMeters: Double(navigationSnapshot.remainingDistanceMeters),
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
            worldHalfExtent: extent,
            dockPosition: SIMD2<Float>(dock.x, dock.z),
            dronePosition: dronePlanarPosition,
            droneYawRadians: safeOrientation.z,
            droneAltitude: max(0.0, safePosition.y),
            trail: terrainMapTrail,
            objects: mapObjects
        )

        if nextSnapshot != terrainMapSnapshot {
            terrainMapSnapshot = nextSnapshot
        }
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
        switch physicalState {
        case .crashed:
            return ("Crashed", "flight_state.crashed")
        case .disarmed:
            return ("Disarmed", "flight_state.disarmed")
        case .armedOnGround:
            return ("Armed Idle", "flight_state.armed_idle")
        case .takeoffTransition:
            return ("Ascending", "flight_state.ascending")
        case .landing:
            return ("Descending", "flight_state.descending")
        case .landed:
            return ("On Ground", "flight_state.on_ground")
        case .airborne:
            break
        }

        if !isArmed {
            return ("Disarmed", "flight_state.disarmed")
        }

        if state.position.y < 0.03 && state.throttle < 0.10 {
            return ("Armed Idle", "flight_state.armed_idle")
        }

        if batteryState.isDepleted {
            return ("Battery Depleted", "flight_state.battery_depleted")
        }

        if mode == .takeoff {
            return ("Ascending", "flight_state.ascending")
        }

        if mode == .landing {
            return ("Descending", "flight_state.descending")
        }

        if mode == .emergencyStop {
            return ("Emergency", "flight_state.emergency")
        }

        if speed < 0.25 {
            return ("Stable", "flight_state.stable")
        }

        if state.velocity.y > 0.2 {
            return ("Climbing", "flight_state.climbing")
        }

        if state.velocity.y < -0.2 {
            return ("Descending", "flight_state.descending")
        }

        return ("Cruise", "flight_state.cruise")
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
            mode = .manual
        }
    }

    private var playableBoundaryHalfExtent: Float {
        max(6.0, terrain.worldHalfExtent - SignalLossConfiguration.boundaryInset)
    }

    private var reentryBoundaryHalfExtent: Float {
        max(1.0, playableBoundaryHalfExtent - SignalLossConfiguration.reentryInset)
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
        manualYawIntent = 0.0
        cameraLookVelocity = .zero
        keyboardInputService.setInputProcessingMode(.editing)
        hasUnsavedChanges = true
    }

    private func clearSignalLossState(restoringInputMode: Bool) {
        let hadBlockingState = signalState.isInteractionBlocking
        signalState = .normal
        signalCountdownSecondsRemaining = SignalLossConfiguration.countdownDuration
        signalLossSecondAccumulator = 0.0

        if restoringInputMode && hadBlockingState {
            keyboardInputService.setInputProcessingMode(.flight)
        }
    }

    private func isOutsidePlayableBounds(_ position: SIMD3<Float>) -> Bool {
        abs(position.x) > playableBoundaryHalfExtent || abs(position.z) > playableBoundaryHalfExtent
    }

    private func isInsidePlayableRecoveryBounds(_ position: SIMD3<Float>) -> Bool {
        abs(position.x) <= reentryBoundaryHalfExtent && abs(position.z) <= reentryBoundaryHalfExtent
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

        let halfExtent = playableBoundaryHalfExtent
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

    private func recommendedSafeSpawnRadius(for scale: MapScale) -> Float {
        switch scale {
        case .x4:
            return 5.0
        case .x8:
            return 6.5
        case .x16:
            return 8.0
        case .x32:
            return 10.0
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
        let halfExtent = playableBoundaryHalfExtent
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
        state.position.y = 0.0
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
        let nearGround = state.position.y <= 0.08
        let stableGroundContact = nearGround &&
            abs(state.velocity.y) <= 0.24 &&
            planarSpeed <= 0.75 &&
            angularSpeed <= 1.8
        let confidentlyAirborne = state.position.y >= 0.18 || (!nearGround && abs(state.velocity.y) > 0.28)
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

        if previousState.position.y > 0.06 && state.position.y <= 0.02 {
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
        guard state.position.y <= 0.08 else {
            return
        }

        let requestedThrottle = max(Float(controlValues.throttle), state.throttle, state.motorThrottle)
        let idleHoldThreshold = resolvedFlightBaseline(for: mode).groundedIdleThreshold

        switch physicalState {
        case .airborne, .takeoffTransition, .landing:
            return
        case .crashed:
            state.position.y = 0.0
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
            state.position.y = 0.0
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
