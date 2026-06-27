import AppKit
import QuartzCore
import SceneKit
import simd

private struct WingmanVisual {
    var rootNode: SCNNode
    var propellerNodes: [SCNNode]
    var spinDirections: [Float]
    var spinAngles: [Float]
}

private struct DroppedPayloadRuntime {
    var node: SCNNode
    var releasedAt: CFTimeInterval
    var lastSampledPosition: SIMD3<Float>
    var verticalSpeed: Float
    var state: PayloadCameraLifecycleState
    var impactTimestamp: CFTimeInterval?
}

struct PayloadLifecycleEvent {
    let releaseID: UUID
    let state: PayloadState
    let messageKey: String?
    let impactPosition: SIMD3<Float>?
    let impactSpeedMps: Float?
}

struct MissionWaypointCaptureZoneVisual: Equatable {
    let id: UUID
    let label: String
    let center: SIMD3<Float>
    let radius: Float
    let isActive: Bool
    let isCompleted: Bool
}

private struct CityGenerationKey: Equatable {
    let mapPreset: TerrainPreset
    let mapScale: MapScale
    let densityBits: UInt32
    let seed: UInt64
    let weatherPreset: WeatherPreset
    let environmentRevision: Int
}

private struct CityCleanupStats {
    let rootCount: Int
    let nodeCount: Int
}

    private struct SupportSurfaceDescriptor {
        let center: SIMD2<Float>
        let halfExtents: SIMD2<Float>
        let yawRadians: Float
        let topY: Float
        let source: String
    }

    private struct ObstacleProxySpec {
        let localCenterY: Float
        let analysisRadius: Float
        let source: String
        let baseY: Float
        let topY: Float
    }

final class DroneSceneController {
    let scene: SCNScene

    private let freeCameraNode: SCNNode
    private let followRigNode = SCNNode()
    private let followCameraNode = SCNNode()
    private let fpvPresentationRootNode = SCNNode()
    private let fpvCameraAnchorNode = SCNNode()
    private let fpvYawNode = SCNNode()
    private let fpvPitchNode = SCNNode()
    private let fpvCameraNode = SCNNode()
    private let payloadCameraRigNode = SCNNode()
    private let payloadCameraYawNode = SCNNode()
    private let payloadCameraPitchNode = SCNNode()
    private var payloadCameraStabilizationEuler = SIMD3<Float>(repeating: 0.0)
    private var payloadCameraTargetLockYaw: Float?
    private var payloadCameraTargetLockPitch: Float?
    private let rangefinderRigNode = SCNNode()
    private let rangefinderYawNode = SCNNode()
    private let rangefinderPitchNode = SCNNode()
    private var rangefinderBeamNode: SCNNode?
    private var rangefinderCameraNode: SCNNode?
    private var rangefinderCamera: SCNCamera?
    private let payloadDropCameraController = PayloadDropCameraController()
    private let orbitCameraNode = SCNNode()
    private let topCameraNode = SCNNode()
    private let spectatorCameraNode = SCNNode()

    private let sunLightNode: SCNNode
    private let defaultSunLightPosition: SCNVector3
    private let gridNode: SCNNode
    private let axesNode: SCNNode
    private let groundNode: SCNNode
    private let terrainDetailNode = SCNNode()
    private let worldBoundsNode = SCNNode()
    private let dockStationNode = SCNNode()
    private let missionDropZoneNode = SCNNode()
    private let missionWaypointCaptureNode = SCNNode()
    private var renderedMissionWaypointCaptureZones: [MissionWaypointCaptureZoneVisual] = []
    private var renderedMissionWaypointCaptureGroundY: Float?
    private let launchAssetNode = SCNNode()
    private let onlineTrialPlaceholderRootNode = SCNNode()
    // v1.5: vehicleID → vehicleProfileID so late-arriving snapshots can build the right visual.
    private var replicaProfileCache: [UUID: String] = [:]
    // v1.4.4: timestamp for computing deltaTime inside applyOnlineInterpolatedRemoteStates.
    private var lastRemoteApplyTime: TimeInterval = 0

    func resetRemoteApplyTime() { lastRemoteApplyTime = 0 }

    private let weatherNode = SCNNode()
    private var rainSystem: SCNParticleSystem?
    private var snowSystem: SCNParticleSystem?
    private var cameraNoisePhase: Float = 0.0

    private let skyCloudsNode = SCNNode()
    private let stormCloudsNode = SCNNode()
    private var stormCloudsBuilt = false
    private let lightningStrikesNode = SCNNode()
    private let weatherEnvelopeNode = SCNNode()
    private var activeWeatherEnvelopePreset: WeatherPreset?
    // The envelope is a sphere centered on the drone, depth-tested normally — anything closer
    // than this radius (terrain, trees) correctly occludes it, so it never visibly "blocks"
    // nearby objects; its only real job is tinting the sky and anything beyond native fog's own
    // falloff range (≈130-140m at full intensity), which scene.fog doesn't reach on its own.
    // 250m keeps it well outside normal close-range flying so its boundary is never grazed.
    private static let weatherEnvelopeRadius: Float = 250.0

    private let scenePopulationService: ScenePopulationService
    private let abandonedCitySceneComposer = AbandonedCitySceneComposer()
    private let cityEnvironmentRevision = 1

    private var droneNode: SCNNode
    private var visualRootNode: SCNNode
    private var cameraAnchorNode: SCNNode
    private var groundReferenceNode: SCNNode
    private var fpvAnchorNode: SCNNode
    private var payloadMountNode: SCNNode
    private var propellerNodes: [SCNNode]
    private var spinDirections: [Float]
    private var spinAngles: [Float]
    private var componentNodes: [DamageComponent: [SCNNode]]
    private var visualBoundsCenter = SIMD3<Float>(repeating: 0.0)
    private var visualBoundsSize = SIMD3<Float>(repeating: 0.36)
    private var cachedSubjectScale: Float = 0.36
    private let droneCollisionProxyNode = SCNNode()
    private var droneCollisionProxyRadius: Float = 0.18
    private var fpvObstructionHidingActive: Bool = false
    private var fpvPresentationActive: Bool = false
    private var payloadVisualNode: SCNNode?
    private var activePayloadConfiguration: PayloadConfiguration?
    private var payloadCameraNode: SCNNode?
    private var payloadCamera: SCNCamera?
    private var payloadCameraOpticsState = PayloadCameraOpticsState()
    private var rangefinderOpticsState = PayloadRangefinderOpticsState()
    private let fpvPayloadPresentationNode = SCNNode()
    private var droppedPayloadNodes: [UUID: SCNNode] = [:]
    private var droppedPayloadRuntime: [UUID: DroppedPayloadRuntime] = [:]
    private var pendingPayloadLifecycleEvents: [PayloadLifecycleEvent] = []
    private var payloadCameraFocusReleaseID: UUID?
    private var payloadImpactNodes: [UUID: SCNNode] = [:]

    private var obstacleMap: [UUID: SCNNode] = [:]
    private(set) var environmentObstacles: [CollisionObstacle] = []
    private(set) var environmentMapDescriptors: [EnvironmentObjectDescriptor] = []
    private(set) var environmentRevision: UInt64 = 0
    private var supportSurfaces: [SupportSurfaceDescriptor] = []
    private var dynamicObstacles: [UUID: CollisionObstacle] = [:]
    private var wingmanVisuals: [UUID: WingmanVisual] = [:]
    private var obstacleSourceByID: [UUID: String] = [:]
    private let collisionDebugNode = SCNNode()
    private var obstacleDebugProxyNodes: [UUID: SCNNode] = [:]
    private let nearestContactNode = SCNNode()
    private let pathDebugNode = SCNNode()
    private let pathStartMarkerNode = SCNNode()
    private let pathGoalMarkerNode = SCNNode()
    private let pathCurrentWaypointNode = SCNNode()
    private var pathSegmentNodes: [SCNNode] = []
    private var pathPointNodes: [SCNNode] = []
    private var pathDebugSignature: Int = 0
    private var lastWeatherVisualSignature: Int?
    private var lastComponentOverlaySignature: Int?
    private var lastTerrainConfig: TerrainConfiguration?
    private var lastGeneratedCityKey: CityGenerationKey?
    private let snowDecorationsNode = SCNNode()

    // MARK: Thermal camera
    private var thermalRenderer: ThermalProxyRenderer?
    private var thermalRenderingActive = false
    private var thermalContext = ThermalEnvironmentContext.neutral
    private var thermalPalette: ThermalPalette = .whiteHot
    private var thermalProfileSelection: ThermalProfileSelection = .auto
    private var thermalContrast: Double = 1.0
    private var thermalBrightness: Double = 0.0
    private var thermalNoiseAmount: Double = 0.5
    private var thermalNormalization = ThermalNormalizationState.neutral
    private var thermalSavedBackground: Any?
    private var thermalSavedFogStart: CGFloat?
    private var thermalSavedFogEnd: CGFloat?
    private var thermalPresentationDirty = true

    private struct SupplementalCollisionObstacle {
        let obstacle: CollisionObstacle
        let highlightNode: SCNNode?
    }

    private enum PhysicsCategory {
        static let environment = 1 << 1
        static let drone = 1 << 2
    }

    private enum RenderCategory {
        static let droppedPayload = 1 << 6
        static let mountedPayload = 1 << 7
        // Thermal proxy geometry: only the payload camera in thermal mode renders it. Every
        // other camera must clear this bit (cameras default to -1 = all bits set).
        static let thermalProxy = ThermalRenderCategory.proxyBit
        static let standardVisible = Int.max & ~thermalProxy
        static let visibleInFPV = standardVisible & ~droppedPayload
        static let visibleInPayloadOptics = standardVisible & ~mountedPayload
    }

    private enum CameraClipping {
        static let standardFar: CGFloat = 900
        static let payloadOpticsFar: CGFloat = 2400
    }

    private var freeLookAngles = SIMD2<Float>(repeating: 0.0)   // yaw, pitch
    private var orbitLookAngles = SIMD2<Float>(repeating: 0.0)  // yaw, pitch
    private var fpvLookAngles = SIMD2<Float>(repeating: 0.0)    // yaw, pitch
    private var topLookAngles = SIMD2<Float>(repeating: 0.0)    // yaw, pitch
    private var spectatorLookAngles = SIMD2<Float>(repeating: 0.0) // yaw, pitch

    private var orbitAngle: Float = 0.0
    private var activeProfile: DroneModelProfile
    private var currentWeather: WeatherModel = .normal
    private var payloadOpticsShadowQualityActive = false
    private var areWorldBoundsVisible: Bool = false
    private(set) var dockSpawnPosition = SIMD3<Float>(0.0, 0.0, 0.0)
    private let dockDeckSurfaceHeight: Float = 0.037
    private var currentLaunchAsset: LaunchAsset?

    init(initialProfile: DroneModelProfile) {
        self.activeProfile = initialProfile

        let setup = SceneFactory.makeScene()
        self.scene = setup.scene
        self.freeCameraNode = setup.cameraNode
        self.sunLightNode = setup.sunLightNode
        self.defaultSunLightPosition = setup.sunLightNode.position
        self.gridNode = setup.gridNode
        self.axesNode = setup.axesNode
        self.groundNode = setup.groundNode

        let droneVisual = DroneModelBuilder.build(profile: initialProfile)
        self.droneNode = droneVisual.rootNode
        self.visualRootNode = droneVisual.visualRootNode
        self.cameraAnchorNode = droneVisual.cameraAnchorNode
        self.groundReferenceNode = droneVisual.groundReferenceNode
        self.fpvAnchorNode = droneVisual.fpvAnchorNode
        self.payloadMountNode = droneVisual.payloadMountNode
        self.propellerNodes = droneVisual.propellerNodes
        self.spinDirections = droneVisual.propellerSpinDirections
        self.spinAngles = Array(repeating: 0.0, count: droneVisual.propellerNodes.count)
        self.componentNodes = droneVisual.componentNodes
        self.visualBoundsCenter = droneVisual.visualBoundsCenter
        self.visualBoundsSize = droneVisual.visualBoundsSize
        self.cachedSubjectScale = droneVisual.subjectScale

        scene.rootNode.addChildNode(droneNode)

        self.scenePopulationService = ScenePopulationService(rootNode: scene.rootNode)
        configureDroneCollisionProxy(for: initialProfile)
        ensurePayloadCameraNode()

        configureCameraNode(followCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(fpvCameraNode, fov: initialProfile.cameraPreset.fpvFov, hidesDroppedPayload: true)
        configureCameraNode(payloadDropCameraController.cameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(orbitCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(topCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(spectatorCameraNode, fov: initialProfile.cameraPreset.fpvFov)

        followRigNode.name = "followRigNode"
        followRigNode.addChildNode(followCameraNode)
        scene.rootNode.addChildNode(followRigNode)
        scene.rootNode.addChildNode(orbitCameraNode)
        scene.rootNode.addChildNode(topCameraNode)
        scene.rootNode.addChildNode(spectatorCameraNode)

        fpvPresentationRootNode.name = "fpvPresentationRootNode"
        fpvYawNode.name = "fpvYawMount"
        fpvPitchNode.name = "fpvPitchMount"
        fpvCameraAnchorNode.name = "fpvCameraAnchorNode"
        fpvPayloadPresentationNode.name = "fpvPayloadPresentationNode"
        fpvPayloadPresentationNode.isHidden = true
        fpvCameraAnchorNode.addChildNode(fpvPayloadPresentationNode)
        fpvCameraAnchorNode.addChildNode(fpvYawNode)
        fpvYawNode.addChildNode(fpvPitchNode)
        fpvPitchNode.addChildNode(fpvCameraNode)
        fpvPresentationRootNode.addChildNode(fpvCameraAnchorNode)
        scene.rootNode.addChildNode(fpvPresentationRootNode)
        scene.rootNode.addChildNode(payloadDropCameraController.anchorNode)

        weatherNode.name = "weatherNode"
        scene.rootNode.addChildNode(weatherNode)

        skyCloudsNode.name = "skyCloudsNode"
        scene.rootNode.addChildNode(skyCloudsNode)
        setUpSkyClouds()

        stormCloudsNode.name = "stormCloudsNode"
        stormCloudsNode.isHidden = true
        scene.rootNode.addChildNode(stormCloudsNode)

        setUpLightningStrikes()

        weatherEnvelopeNode.name = "weatherEnvelopeNode"
        weatherEnvelopeNode.isHidden = true
        scene.rootNode.addChildNode(weatherEnvelopeNode)

        terrainDetailNode.name = "terrainDetailNode"
        scene.rootNode.addChildNode(terrainDetailNode)

        collisionDebugNode.name = "collisionDebugNode"
        collisionDebugNode.isHidden = true
        scene.rootNode.addChildNode(collisionDebugNode)

        pathDebugNode.name = "pathDebugNode"
        pathDebugNode.isHidden = true
        scene.rootNode.addChildNode(pathDebugNode)

        worldBoundsNode.name = "worldBoundsNode"
        scene.rootNode.addChildNode(worldBoundsNode)

        dockStationNode.name = "dockStationNode"
        scene.rootNode.addChildNode(dockStationNode)

        missionDropZoneNode.name = "missionDropZoneNode"
        missionDropZoneNode.isHidden = true
        scene.rootNode.addChildNode(missionDropZoneNode)

        missionWaypointCaptureNode.name = "missionWaypointCaptureNode"
        missionWaypointCaptureNode.isHidden = true
        scene.rootNode.addChildNode(missionWaypointCaptureNode)

        launchAssetNode.name = "launchAssetNode"
        launchAssetNode.isHidden = true
        scene.rootNode.addChildNode(launchAssetNode)

        onlineTrialPlaceholderRootNode.name = "online_trial_vehicle_placeholders"
        scene.rootNode.addChildNode(onlineTrialPlaceholderRootNode)

        snowDecorationsNode.name = "environment.snowDecorations"
        scene.rootNode.addChildNode(snowDecorationsNode)

        nearestContactNode.geometry = SCNSphere(radius: 0.14)
        nearestContactNode.geometry?.firstMaterial?.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.82)
        nearestContactNode.isHidden = true
        collisionDebugNode.addChildNode(nearestContactNode)

        pathStartMarkerNode.geometry = SCNSphere(radius: 0.20)
        pathStartMarkerNode.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.95)
        pathGoalMarkerNode.geometry = SCNSphere(radius: 0.22)
        pathGoalMarkerNode.geometry?.firstMaterial?.diffuse.contents = NSColor.systemPurple.withAlphaComponent(0.95)
        pathCurrentWaypointNode.geometry = SCNSphere(radius: 0.16)
        pathCurrentWaypointNode.geometry?.firstMaterial?.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.95)
        pathCurrentWaypointNode.isHidden = true
        pathDebugNode.addChildNode(pathStartMarkerNode)
        pathDebugNode.addChildNode(pathGoalMarkerNode)
        pathDebugNode.addChildNode(pathCurrentWaypointNode)

        configureDockStationGeometry()
        updateDockStationPosition(for: .default)
        updateWorldBoundsVisual(for: .default)
        applyTerrainVisualStyle(.default)
    }

    func pointOfView(for mode: CameraMode) -> SCNNode {
        switch mode {
        case .free:
            return freeCameraNode
        case .follow:
            return followCameraNode
        case .fpv:
            return fpvCameraNode
        case .orbit:
            return orbitCameraNode
        case .top:
            return topCameraNode
        case .payloadOptics:
            return payloadCameraPointOfView() ?? rangefinderCameraPointOfView() ?? followCameraNode
        case .payload:
            return payloadDropCameraController.cameraNode
        case .spectator:
            return spectatorCameraNode
        }
    }

    func setPayloadCameraOpticsState(_ state: PayloadCameraOpticsState) {
        payloadCameraOpticsState = state
        updatePayloadCamera(state: state, droneState: .initial, deltaTime: 0.0)
    }

    func payloadCameraPointOfView() -> SCNNode? {
        guard payloadCameraOpticsState.isAvailable else {
            return nil
        }
        ensurePayloadCameraNode()
        return payloadCameraNode
    }

    func rangefinderCameraPointOfView() -> SCNNode? {
        guard rangefinderOpticsState.isAvailable else {
            return nil
        }
        ensureRangefinderRig()
        return rangefinderCameraNode
    }

    // MARK: - Thermal Rendering

    func setThermalPalette(_ palette: ThermalPalette) {
        guard thermalPalette != palette else { return }
        thermalPalette = palette
        thermalPresentationDirty = true
    }

    func setThermalProfileSelection(_ selection: ThermalProfileSelection) {
        guard thermalProfileSelection != selection else { return }
        thermalProfileSelection = selection
        thermalPresentationDirty = true
    }

    func setThermalContrast(_ value: Double) {
        let clamped = min(1.8, max(0.4, value))
        guard abs(thermalContrast - clamped) > 0.0001 else { return }
        thermalContrast = clamped
        thermalPresentationDirty = true
    }

    func setThermalBrightness(_ value: Double) {
        let clamped = min(0.3, max(-0.3, value))
        guard abs(thermalBrightness - clamped) > 0.0001 else { return }
        thermalBrightness = clamped
        thermalPresentationDirty = true
    }

    func setThermalNoiseAmount(_ value: Double) {
        let clamped = min(1.0, max(0.0, value))
        guard abs(thermalNoiseAmount - clamped) > 0.0001 else { return }
        thermalNoiseAmount = clamped
        thermalPresentationDirty = true
    }

    /// Mark the thermal scene stale (weather/environment changed). Cheap; the rebuild happens on
    /// the next presentation while thermal is active.
    func invalidateThermalScene() {
        thermalRenderer?.invalidate()
        thermalPresentationDirty = true
    }

    /// Per-frame gate. Toggles the payload camera between the real scene and the thermal proxy
    /// scene (idempotent), and recolours only when something actually changed.
    func updateThermalPresentation(active: Bool) {
        if active != thermalRenderingActive {
            thermalRenderingActive = active
            if active {
                activateThermalRendering()
            } else {
                deactivateThermalRendering()
            }
        }

        guard thermalRenderingActive else { return }
        if thermalPresentationDirty {
            refreshThermalPresentation()
            thermalPresentationDirty = false
        }
    }

    private func ensureThermalRenderer() -> ThermalProxyRenderer {
        if let thermalRenderer {
            return thermalRenderer
        }
        let renderer = ThermalProxyRenderer(sceneRoot: scene.rootNode, groundNode: groundNode)
        thermalRenderer = renderer
        return renderer
    }

    private func activateThermalRendering() {
        ensurePayloadCameraNode()
        _ = ensureThermalRenderer()
        thermalSavedBackground = scene.background.contents
        thermalSavedFogStart = scene.fogStartDistance
        thermalSavedFogEnd = scene.fogEndDistance
        neutralizeFogForThermal()
        payloadCamera?.categoryBitMask = RenderCategory.thermalProxy
        thermalPresentationDirty = true
    }

    private func deactivateThermalRendering() {
        payloadCamera?.categoryBitMask = RenderCategory.visibleInPayloadOptics
        if let saved = thermalSavedBackground {
            scene.background.contents = saved
        }
        thermalSavedBackground = nil
        if let start = thermalSavedFogStart {
            scene.fogStartDistance = start
        }
        if let end = thermalSavedFogEnd {
            scene.fogEndDistance = end
        }
        thermalSavedFogStart = nil
        thermalSavedFogEnd = nil
    }

    /// `scene.fog*` is a scene-wide property (not per-camera) — the EO atmospheric haze colour
    /// (near-white for snow/fog presets) was blending into thermal proxy fragments by distance,
    /// painting far snow/ground white regardless of its actual temperature. Thermal already
    /// represents fog/haze degradation by widening the normalization band (less apparent
    /// contrast), so the literal screen-space fog blend is pushed out beyond the payload camera's
    /// far clip while thermal is active — it never reaches any rendered fragment.
    private func neutralizeFogForThermal() {
        scene.fogStartDistance = CameraClipping.payloadOpticsFar * 4
        scene.fogEndDistance = CameraClipping.payloadOpticsFar * 6
    }

    private func refreshThermalPresentation() {
        #if DEBUG
        let thermalRefreshStartTime = CACurrentMediaTime()
        defer {
            let elapsedMs = (CACurrentMediaTime() - thermalRefreshStartTime) * 1000.0
            if elapsedMs > 4.0 {
                print("[Thermal] refreshThermalPresentation total: \(String(format: "%.1f", elapsedMs)) ms")
            }
        }
        #endif
        let renderer = ensureThermalRenderer()
        let context = makeThermalContext()
        thermalContext = context

        let groundClass = groundThermalClass()
        let population = renderer.normalizationPopulation(
            groundClass: groundClass,
            environmentRevision: environmentRevision
        )
        thermalNormalization = ThermalNormalizationModel.make(population: population, context: context)

        renderer.updatePresentation(
            context: context,
            palette: thermalPalette,
            contrast: thermalContrast,
            brightness: thermalBrightness,
            noiseAmount: thermalNoiseAmount,
            normalization: thermalNormalization,
            groundClass: groundClass,
            environmentRevision: environmentRevision
        )

        // Sky/background: coldest class, mapped through the same range + palette.
        let skyTemperature = ThermalMaterialModel.meanTemperature(for: .sky, context: context)
        let skyColor = ThermalPaletteMapper.color(
            forTemperature: skyTemperature,
            displayMin: thermalNormalization.displayMinCelsius,
            displayMax: thermalNormalization.displayMaxCelsius,
            palette: thermalPalette,
            contrast: thermalContrast,
            brightness: thermalBrightness
        )
        scene.background.contents = skyColor
    }

    private func makeThermalContext() -> ThermalEnvironmentContext {
        let terrainPreset = lastTerrainConfig?.preset ?? .field
        let profile = ThermalSceneProfileResolver.resolve(
            terrain: terrainPreset,
            weather: currentWeather.preset,
            selection: thermalProfileSelection
        )
        return ThermalEnvironmentAdapter.makeContext(
            weather: currentWeather,
            terrain: terrainPreset,
            sceneProfile: profile
        )
    }

    private func groundThermalClass() -> ThermalMaterialClass {
        guard let terrain = lastTerrainConfig else { return .terrain }
        switch terrain.preset {
        case .gridDemo:
            return .generic
        case .city:
            return .concrete
        case .field, .forest, .cargoYard:
            return currentWeather.preset == .snow ? .snow : .grass
        }
    }

    /// Diagnostics snapshot for the debug overlay. The center probe casts a ray down the payload
    /// camera's forward axis and reads the hit proxy's stored temperature/class.
    func thermalDiagnostics(includeCenterProbe: Bool) -> ThermalDiagnosticsSnapshot {
        var center: (cls: ThermalMaterialClass, temp: Double, name: String?)?
        if includeCenterProbe, thermalRenderingActive {
            center = thermalCenterProbe()
        }

        return ThermalDiagnosticsSnapshot(
            ambientTemperatureCelsius: thermalContext.ambientTemperatureCelsius,
            weatherKind: thermalContext.weatherKind,
            sceneProfile: thermalContext.sceneProfile,
            displayMinCelsius: thermalNormalization.displayMinCelsius,
            displayMaxCelsius: thermalNormalization.displayMaxCelsius,
            centerTemperatureCelsius: center?.temp,
            centerMaterialClass: center?.cls,
            centerNodeName: center?.name,
            rainIntensity: thermalContext.rainIntensity,
            snowIntensity: thermalContext.snowIntensity,
            fogDensity: thermalContext.fogDensity,
            cloudiness: thermalContext.cloudiness,
            windSpeedMps: thermalContext.windSpeedMps,
            sunExposure: thermalContext.sunExposure
        )
    }

    func resolvedThermalProfile() -> ThermalSceneProfile {
        thermalContext.sceneProfile
    }

    private func thermalCenterProbe() -> (cls: ThermalMaterialClass, temp: Double, name: String?)? {
        guard let renderer = thermalRenderer, let payloadCameraNode else { return nil }
        let origin = payloadCameraNode.presentation.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(payloadCameraNode.presentation.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        guard simd_length_squared(forward) > 0.000001 else { return nil }

        let end = origin + forward * Float(CameraClipping.payloadOpticsFar)
        let results = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(origin.x, origin.y, origin.z),
            to: SCNVector3(end.x, end.y, end.z),
            options: [
                SCNHitTestOption.categoryBitMask.rawValue: RenderCategory.thermalProxy,
                SCNHitTestOption.backFaceCulling.rawValue: false,
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue
            ]
        )
        for result in results {
            if let probe = renderer.probe(node: result.node) {
                return (probe.materialClass, probe.temperatureCelsius, probe.name)
            }
        }
        return nil
    }

    func currentDockSpawnPoint() -> SIMD3<Float> {
        dockSpawnPosition
    }

    func configureOnlineTrialPlaceholders(_ fleetState: OnlineTrialFleetState?) {
        onlineTrialPlaceholderRootNode.childNodes.forEach { $0.removeFromParentNode() }
        replicaProfileCache.removeAll()
        droneNode.isHidden = fleetState?.isSpectator ?? false

        guard let fleetState else {
            return
        }

        // v1.5: build remote replicas using each participant's actual UAV profile.
        for slot in fleetState.remoteVehicles {
            replicaProfileCache[slot.vehicleID] = slot.vehicleProfileID
            #if DEBUG
            print("[LAN] replica slot participant=\(slot.participantName) vehicle=\(slot.vehicleID.uuidString.prefix(8)) profile=\(slot.vehicleProfileID)")
            #endif
            onlineTrialPlaceholderRootNode.addChildNode(
                OnlineTrialVehiclePlaceholderNodeFactory.makeGhostNode(
                    vehicleID: slot.vehicleID,
                    participantName: slot.participantName,
                    spawnIndex: slot.spawnIndex,
                    vehicleProfileID: slot.vehicleProfileID
                )
            )
        }
    }

    func applyOnlineVehicleSnapshots(_ snapshotState: OnlineRemoteVehicleSnapshotState) {
        let snapshots = snapshotState.snapshots
        let activeNodeNames = Set(snapshots.map { onlineTrialVehicleNodeName(for: $0.vehicleID) })

        for child in onlineTrialPlaceholderRootNode.childNodes {
            guard let name = child.name,
                  name.hasPrefix("online_trial_vehicle_"),
                  !activeNodeNames.contains(name) else {
                continue
            }
            child.removeFromParentNode()
        }

        for (index, snapshot) in snapshots.enumerated() {
            let nodeName = onlineTrialVehicleNodeName(for: snapshot.vehicleID)
            let node: SCNNode
            if let existing = onlineTrialPlaceholderRootNode.childNode(withName: nodeName, recursively: false) {
                node = existing
            } else {
                let cachedProfileID = replicaProfileCache[snapshot.vehicleID]
                node = OnlineTrialVehiclePlaceholderNodeFactory.makeGhostNode(
                    vehicleID: snapshot.vehicleID,
                    participantName: snapshot.participantName,
                    spawnIndex: index,
                    vehicleProfileID: cachedProfileID
                )
                onlineTrialPlaceholderRootNode.addChildNode(node)
            }

            node.position = SCNVector3(
                Float(snapshot.pose.positionX),
                Float(snapshot.pose.positionY),
                Float(snapshot.pose.positionZ)
            )
            node.simdOrientation = orientationQuaternion(
                from: SIMD3<Float>(
                    Float(snapshot.pose.roll),
                    Float(snapshot.pose.pitch),
                    Float(snapshot.pose.yaw)
                )
            )
            node.isHidden = false
        }
    }

    // P2P 0.9: ghost nodes are visual-only remote vehicles, not physics bodies.
    // Called per-frame from simulation tick with interpolated states for smooth movement.
    // v1.4.4: position lerp eliminates micro-jitter; if > 20 m away the node snaps to avoid drag.
    func applyOnlineInterpolatedRemoteStates(_ states: [OnlineVehicleInterpolatedState]) {
        let now = CACurrentMediaTime()
        let dt: Float = lastRemoteApplyTime == 0
            ? 0.016
            : Float(min(now - lastRemoteApplyTime, 0.1))
        lastRemoteApplyTime = now

        let activeNodeNames = Set(states.map { onlineTrialVehicleNodeName(for: $0.vehicleID) })

        for child in onlineTrialPlaceholderRootNode.childNodes {
            guard let name = child.name, name.hasPrefix("online_trial_vehicle_") else { continue }
            child.isHidden = !activeNodeNames.contains(name)
        }

        let smoothingRate: Float = 14.0
        let alpha = min(dt * smoothingRate, 1.0)

        for state in states {
            let nodeName = onlineTrialVehicleNodeName(for: state.vehicleID)
            let node: SCNNode
            if let existing = onlineTrialPlaceholderRootNode.childNode(withName: nodeName, recursively: false) {
                node = existing
            } else {
                let cachedProfileID = replicaProfileCache[state.vehicleID]
                node = OnlineTrialVehiclePlaceholderNodeFactory.makeGhostNode(
                    vehicleID: state.vehicleID,
                    participantName: state.participantName,
                    spawnIndex: nil,
                    vehicleProfileID: cachedProfileID
                )
                onlineTrialPlaceholderRootNode.addChildNode(node)
            }

            let targetPos = SIMD3<Float>(
                Float(state.pose.positionX),
                Float(state.pose.positionY),
                Float(state.pose.positionZ)
            )
            let currentPos = node.simdPosition
            // Snap if the node is far away (first appearance, warp, etc.)
            if simd_distance(currentPos, targetPos) > 20.0 {
                node.simdPosition = targetPos
            } else {
                node.simdPosition = simd_mix(currentPos, targetPos, SIMD3<Float>(repeating: alpha))
            }

            node.simdOrientation = orientationQuaternion(
                from: SIMD3<Float>(
                    Float(state.pose.roll),
                    Float(state.pose.pitch),
                    Float(state.pose.yaw)
                )
            )
            node.opacity = state.sourceSnapshotAge > 1.0 ? 0.30 : 0.88
            node.isHidden = false
        }
    }

    // P2P v1.2: update ghost visual damage state — called after collision events are applied.
    func applyOnlineVehicleDamageState(_ damageState: OnlineVehicleDamageState) {
        for child in onlineTrialPlaceholderRootNode.childNodes {
            guard let name = child.name,
                  name.hasPrefix("online_trial_vehicle_"),
                  let uuidString = name.components(separatedBy: "online_trial_vehicle_").last,
                  let vehicleID = UUID(uuidString: uuidString) else { continue }

            let opState = damageState.record(for: vehicleID)?.operationalState ?? .normal
            applyDamageVisual(to: child, operationalState: opState)
        }
    }

    private func applyDamageVisual(to node: SCNNode, operationalState: OnlineVehicleOperationalState) {
        let labelNodeName = "damage_label"
        node.childNodes.filter { $0.name == labelNodeName }.forEach { $0.removeFromParentNode() }

        switch operationalState {
        case .normal:
            break
        case .damaged:
            node.opacity = min(node.opacity, 0.85)
            addDamageLabel("DAMAGED", color: NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1.0), to: node, name: labelNodeName)
        case .disabled:
            node.opacity = min(node.opacity, 0.55)
            addDamageLabel("DISABLED", color: NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0), to: node, name: labelNodeName)
        case .crashed:
            node.opacity = min(node.opacity, 0.45)
            addDamageLabel("CRASHED", color: NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0), to: node, name: labelNodeName)
        }
    }

    private func addDamageLabel(_ text: String, color: NSColor, to parent: SCNNode, name: String) {
        let textGeometry = SCNText(string: text, extrusionDepth: 0)
        textGeometry.font = NSFont.systemFont(ofSize: 0.15, weight: .bold)
        textGeometry.firstMaterial?.diffuse.contents = color
        textGeometry.firstMaterial?.isDoubleSided = true

        let labelNode = SCNNode(geometry: textGeometry)
        labelNode.name = name
        labelNode.position = SCNVector3(0, 0.6, 0)
        labelNode.scale = SCNVector3(1, 1, 1)
        parent.addChildNode(labelNode)
    }

    private func onlineTrialVehicleNodeName(for vehicleID: UUID) -> String {
        "online_trial_vehicle_\(vehicleID.uuidString)"
    }

    func currentLaunchSpawnPoint(for asset: LaunchAsset?) -> SIMD3<Float>? {
        guard let asset else {
            return nil
        }

        let supportY = supportSurfaceHeight(
            at: asset.position,
            clearanceRadius: 0.28,
            maximumHeight: .greatestFiniteMagnitude
        ) ?? max(Float(groundNode.presentation.position.y), 0.0)

        switch asset {
        case .catapult(let catapult):
            let direction = SIMD3<Float>(
                sin(catapult.rail.headingRadians),
                0.0,
                cos(catapult.rail.headingRadians)
            )
            let startOffset = direction * -0.72
            return SIMD3<Float>(
                catapult.position.x + startOffset.x,
                supportY + 0.18,
                catapult.position.y + startOffset.z
            )
        }
    }

    func setLaunchAsset(_ asset: LaunchAsset?) {
        currentLaunchAsset = asset
        launchAssetNode.childNodes.forEach { $0.removeFromParentNode() }

        guard let asset else {
            launchAssetNode.isHidden = true
            return
        }

        launchAssetNode.isHidden = false

        let supportY = supportSurfaceHeight(
            at: asset.position,
            clearanceRadius: 0.32,
            maximumHeight: .greatestFiniteMagnitude
        ) ?? max(Float(groundNode.presentation.position.y), 0.0)
        launchAssetNode.simdPosition = SIMD3<Float>(asset.position.x, supportY, asset.position.y)
        launchAssetNode.eulerAngles = SCNVector3(
            0.0,
            SCNFloat(asset.headingRadians),
            0.0
        )

        switch asset {
        case .catapult(let catapult):
            launchAssetNode.addChildNode(makeCatapultNode(for: catapult))
        }
    }

    func setMissionDropZone(_ dropZone: DropZoneState?) {
        missionDropZoneNode.childNodes.forEach { node in
            node.removeFromParentNode()
        }

        guard let dropZone else {
            missionDropZoneNode.isHidden = true
            return
        }

        let groundY = max(Float(groundNode.presentation.position.y), 0.0)
        missionDropZoneNode.simdPosition = SIMD3<Float>(dropZone.center.x, groundY + 0.01, dropZone.center.y)
        missionDropZoneNode.isHidden = false

        let radius = max(1.0, dropZone.radius)

        let disk = SCNCylinder(radius: CGFloat(radius), height: 0.012)
        let diskMaterial = SCNMaterial()
        diskMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.10)
        diskMaterial.emission.contents = NSColor.systemOrange.withAlphaComponent(0.06)
        diskMaterial.lightingModel = .constant
        diskMaterial.isDoubleSided = true
        disk.materials = [diskMaterial]

        let diskNode = SCNNode(geometry: disk)
        diskNode.simdPosition = SIMD3<Float>(0.0, 0.0, 0.0)
        missionDropZoneNode.addChildNode(diskNode)

        let ring = SCNTorus(
            ringRadius: CGFloat(radius),
            pipeRadius: CGFloat(max(0.04, min(0.12, radius * 0.035)))
        )
        let ringMaterial = SCNMaterial()
        ringMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.92)
        ringMaterial.emission.contents = NSColor.systemOrange.withAlphaComponent(0.38)
        ringMaterial.lightingModel = .constant
        ring.materials = [ringMaterial]

        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = .pi / 2.0
        ringNode.simdPosition = SIMD3<Float>(0.0, 0.008, 0.0)
        missionDropZoneNode.addChildNode(ringNode)
    }

    func setMissionWaypointCaptureZones(_ zones: [MissionWaypointCaptureZoneVisual]) {
        let groundY = max(Float(groundNode.presentation.position.y), 0.0)
        if zones == renderedMissionWaypointCaptureZones,
           let renderedGroundY = renderedMissionWaypointCaptureGroundY,
           abs(renderedGroundY - groundY) <= 0.001 {
            return
        }
        renderedMissionWaypointCaptureZones = zones
        renderedMissionWaypointCaptureGroundY = groundY

        missionWaypointCaptureNode.childNodes.forEach { node in
            node.removeFromParentNode()
        }

        guard !zones.isEmpty else {
            missionWaypointCaptureNode.isHidden = true
            return
        }

        missionWaypointCaptureNode.isHidden = false

        for zone in zones {
            let radius = max(0.6, zone.radius)
            let altitude = max(groundY + 0.35, zone.center.y)
            let root = SCNNode()
            root.name = "mission_capture_\(zone.id.uuidString)"
            root.simdPosition = SIMD3<Float>(zone.center.x, groundY + 0.018, zone.center.z)

            let color: NSColor = {
                if zone.isCompleted {
                    return NSColor.systemGreen
                }
                if zone.isActive {
                    return NSColor.systemOrange
                }
                return NSColor.systemCyan
            }()

            let ring = SCNTorus(
                ringRadius: CGFloat(radius),
                pipeRadius: CGFloat(max(0.035, min(0.13, radius * 0.018)))
            )
            let ringMaterial = SCNMaterial()
            ringMaterial.diffuse.contents = color.withAlphaComponent(zone.isActive ? 0.92 : 0.58)
            ringMaterial.emission.contents = color.withAlphaComponent(zone.isActive ? 0.42 : 0.20)
            ringMaterial.lightingModel = .constant
            ring.materials = [ringMaterial]

            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles.x = .pi / 2.0
            ringNode.simdPosition = SIMD3<Float>(0.0, 0.012, 0.0)
            root.addChildNode(ringNode)

            let sphere = SCNSphere(radius: CGFloat(radius))
            sphere.segmentCount = 36
            let sphereMaterial = SCNMaterial()
            sphereMaterial.diffuse.contents = color.withAlphaComponent(zone.isActive ? 0.36 : 0.22)
            sphereMaterial.emission.contents = color.withAlphaComponent(zone.isActive ? 0.16 : 0.08)
            sphereMaterial.lightingModel = .constant
            sphereMaterial.fillMode = .lines
            sphereMaterial.isDoubleSided = true
            sphereMaterial.readsFromDepthBuffer = false
            sphere.materials = [sphereMaterial]

            let sphereNode = SCNNode(geometry: sphere)
            sphereNode.name = "mission_capture_sphere"
            sphereNode.simdPosition = SIMD3<Float>(0.0, altitude - groundY, 0.0)
            root.addChildNode(sphereNode)

            let centerMarker = SCNNode(geometry: SCNSphere(radius: CGFloat(max(0.16, min(0.34, radius * 0.04)))))
            centerMarker.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.95)
            centerMarker.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(0.38)
            centerMarker.geometry?.firstMaterial?.lightingModel = .constant
            centerMarker.simdPosition = sphereNode.simdPosition
            root.addChildNode(centerMarker)

            let stemHeight = max(0.0, altitude - groundY)
            if stemHeight > 0.35 {
                let stem = SCNCylinder(radius: CGFloat(max(0.018, min(0.055, radius * 0.006))), height: CGFloat(stemHeight))
                let stemMaterial = SCNMaterial()
                stemMaterial.diffuse.contents = color.withAlphaComponent(zone.isActive ? 0.62 : 0.34)
                stemMaterial.emission.contents = color.withAlphaComponent(zone.isActive ? 0.22 : 0.10)
                stemMaterial.lightingModel = .constant
                stem.materials = [stemMaterial]

                let stemNode = SCNNode(geometry: stem)
                stemNode.simdPosition = SIMD3<Float>(0.0, stemHeight * 0.5, 0.0)
                root.addChildNode(stemNode)
            }

            missionWaypointCaptureNode.addChildNode(root)
        }
    }

    private func makeCatapultNode(for asset: CatapultLaunchAsset) -> SCNNode {
        let root = SCNNode()
        let railPitch = SCNFloat(asset.rail.railAngleDegrees.degreesToRadians)

        let frameMaterial = SCNMaterial()
        frameMaterial.diffuse.contents = NSColor(calibratedRed: 0.58, green: 0.61, blue: 0.65, alpha: 1.0)
        frameMaterial.roughness.contents = 0.34
        frameMaterial.metalness.contents = 0.78

        let railMaterial = SCNMaterial()
        railMaterial.diffuse.contents = NSColor(calibratedRed: 0.24, green: 0.26, blue: 0.30, alpha: 1.0)
        railMaterial.roughness.contents = 0.46
        railMaterial.metalness.contents = 0.84

        let carriageMaterial = SCNMaterial()
        carriageMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.94)
        carriageMaterial.emission.contents = NSColor.systemOrange.withAlphaComponent(0.12)
        carriageMaterial.roughness.contents = 0.42

        let base = SCNNode(
            geometry: SCNBox(width: 1.55, height: 0.05, length: 0.42, chamferRadius: 0.02)
        )
        base.geometry?.materials = [frameMaterial]
        base.simdPosition = SIMD3<Float>(0.0, 0.03, 0.0)
        root.addChildNode(base)

        let railLeft = SCNNode(
            geometry: SCNBox(width: 1.92, height: 0.03, length: 0.05, chamferRadius: 0.01)
        )
        railLeft.geometry?.materials = [railMaterial]
        railLeft.simdPosition = SIMD3<Float>(0.0, 0.24, -0.08)
        railLeft.eulerAngles.x = railPitch
        root.addChildNode(railLeft)

        let railRight = SCNNode(
            geometry: SCNBox(width: 1.92, height: 0.03, length: 0.05, chamferRadius: 0.01)
        )
        railRight.geometry?.materials = [railMaterial]
        railRight.simdPosition = SIMD3<Float>(0.0, 0.24, 0.08)
        railRight.eulerAngles.x = railPitch
        root.addChildNode(railRight)

        let carriage = SCNNode(
            geometry: SCNBox(width: 0.22, height: 0.04, length: 0.22, chamferRadius: 0.01)
        )
        carriage.geometry?.materials = [carriageMaterial]
        carriage.simdPosition = SIMD3<Float>(-0.56, 0.14, 0.0)
        carriage.eulerAngles.x = railPitch
        root.addChildNode(carriage)

        let strutOffsets: [SIMD3<Float>] = [
            SIMD3<Float>(-0.62, 0.10, -0.12),
            SIMD3<Float>(-0.20, 0.10, 0.12),
            SIMD3<Float>(0.22, 0.10, -0.12),
            SIMD3<Float>(0.64, 0.10, 0.12)
        ]

        for offset in strutOffsets {
            let strut = SCNNode(
                geometry: SCNCylinder(radius: 0.018, height: 0.30)
            )
            strut.geometry?.materials = [frameMaterial]
            strut.simdPosition = offset
            strut.eulerAngles.z = 0.22
            root.addChildNode(strut)
        }

        let headingMarker = SCNNode(
            geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.05, height: 0.18)
        )
        headingMarker.geometry?.materials = [carriageMaterial]
        headingMarker.simdPosition = SIMD3<Float>(0.98, 0.26, 0.0)
        headingMarker.eulerAngles.z = -SCNFloat.pi / 2.0
        root.addChildNode(headingMarker)

        return root
    }

    func currentPayloadMountNode() -> SCNNode {
        payloadMountNode
    }

    func consumePayloadLifecycleEvents() -> [PayloadLifecycleEvent] {
        let events = pendingPayloadLifecycleEvents
        pendingPayloadLifecycleEvents.removeAll(keepingCapacity: true)
        return events
    }

    func setPayloadCameraFocusReleaseID(_ releaseID: UUID?) {
        payloadCameraFocusReleaseID = releaseID
        payloadDropCameraController.setFocusReleaseID(releaseID)
    }

    func updatePayloadCameraForRenderFrame(atTime time: TimeInterval, isActive: Bool) {
        payloadDropCameraController.updateForRenderFrame(
            atTime: time,
            target: currentPayloadDropCameraTarget(),
            groundY: max(Float(groundNode.presentation.position.y), 0.0),
            isActive: isActive
        )
    }

    func payloadCameraSnapshot(for releaseID: UUID?) -> PayloadCameraSceneSnapshot? {
        let resolvedReleaseID = releaseID ?? payloadCameraFocusReleaseID
        guard let resolvedReleaseID,
              let runtime = droppedPayloadRuntime[resolvedReleaseID] else {
            return nil
        }

        let position = runtime.node.presentation.simdWorldPosition
        let elapsedTime = max(0.0, CACurrentMediaTime() - runtime.releasedAt)
        return PayloadCameraSceneSnapshot(
            releaseID: resolvedReleaseID,
            altitude: max(0.0, position.y),
            verticalSpeed: runtime.verticalSpeed,
            elapsedTime: elapsedTime,
            state: runtime.state
        )
    }

    func payloadCameraTargetDistance(maxDistance: Double) -> Double? {
        guard payloadCameraOpticsState.isAvailable,
              payloadCameraOpticsState.isPowered,
              let payloadCameraNode else {
            return nil
        }

        let origin = payloadCameraNode.presentation.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(payloadCameraNode.presentation.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        guard simd_length_squared(forward) > 0.000001 else {
            return nil
        }

        let distanceLimit = max(1.0, Float(maxDistance))
        let end = origin + forward * distanceLimit
        let results = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(origin.x, origin.y, origin.z),
            to: SCNVector3(end.x, end.y, end.z),
            options: [
                SCNHitTestOption.backFaceCulling.rawValue: false,
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue
            ]
        )

        for result in results {
            if isDescendant(result.node, of: droneNode) || isDescendant(result.node, of: payloadCameraRigNode) {
                continue
            }

            let hit = SIMD3<Float>(
                Float(result.worldCoordinates.x),
                Float(result.worldCoordinates.y),
                Float(result.worldCoordinates.z)
            )
            return Double(simd_distance(origin, hit))
        }

        return nil
    }

    func attachPayloadVisual(_ configuration: PayloadConfiguration) {
        removePayloadVisual()
        let node = PayloadVisualFactory.build(configuration: configuration)
        applyCategoryBitMask(RenderCategory.mountedPayload, to: node)
        payloadMountNode.addChildNode(node)
        payloadVisualNode = node
        activePayloadConfiguration = configuration
        installFPVPayloadPresentation(from: node)
        applyPayloadFPVPresentation()
    }

    func attachMountedCADPayload(_ payload: MountedCADPayload) {
        removePayloadVisual()
        let node = CADPayloadVisualFactory.build(payload: payload)
        applyCategoryBitMask(RenderCategory.mountedPayload, to: node)
        let mountCoordinateRoot = payloadMountNode.parent ?? visualRootNode
        mountCoordinateRoot.addChildNode(node)
        payloadVisualNode = node
        activePayloadConfiguration = PayloadConfiguration(
            payloadType: .custom,
            customName: payload.partName,
            payloadMass: Float(payload.massKg),
            visualPreset: .customModule,
            isAttached: true
        )
        installFPVPayloadPresentation(from: node)
        applyPayloadFPVPresentation()
    }

    func removePayloadVisual() {
        payloadVisualNode?.removeFromParentNode()
        payloadVisualNode = nil
        activePayloadConfiguration = nil
        resetFPVPayloadPresentation()
    }

    @discardableResult
    func releasePayloadVisual() -> UUID? {
        guard let attachedPayloadNode = payloadVisualNode else {
            return nil
        }

        let releaseID = UUID()
        let releasedPayloadType = activePayloadConfiguration?.payloadType
        let worldTransform = attachedPayloadNode.presentation.simdWorldTransform
        attachedPayloadNode.removeAllActions()
        attachedPayloadNode.removeFromParentNode()
        payloadVisualNode = nil
        activePayloadConfiguration = nil
        resetFPVPayloadPresentation()

        scene.rootNode.addChildNode(attachedPayloadNode)
        attachedPayloadNode.simdWorldTransform = worldTransform
        applyCategoryBitMask(RenderCategory.droppedPayload, to: attachedPayloadNode)

        let startPosition = attachedPayloadNode.simdWorldPosition
        let landedY = min(startPosition.y, max(Float(groundNode.presentation.position.y) + 0.04, 0.04))
        let dropHeight = max(0.0, startPosition.y - landedY)
        let gravity: Float = 9.8
        let unconstrainedDuration = sqrt(max(0.0001, (2.0 * dropHeight) / gravity))
        let estimatedImpactSpeed = sqrt(max(0.0, 2.0 * gravity * dropHeight))
        // Keep the payload in continuous visible fall until real impact instead of
        // truncating the action early and forcing a long teleport in landedAction.
        let fallDuration = Double(dropHeight > 0.01 ? unconstrainedDuration.clamped(to: 0.18...8.0) : 0.08)

        droppedPayloadNodes[releaseID] = attachedPayloadNode
        droppedPayloadRuntime[releaseID] = DroppedPayloadRuntime(
            node: attachedPayloadNode,
            releasedAt: CACurrentMediaTime(),
            lastSampledPosition: startPosition,
            verticalSpeed: 0.0,
            state: .falling,
            impactTimestamp: nil
        )

        let startFalling = SCNAction.run { [weak self] _ in
            self?.pendingPayloadLifecycleEvents.append(
                PayloadLifecycleEvent(
                releaseID: releaseID,
                state: .falling,
                messageKey: nil,
                impactPosition: nil,
                impactSpeedMps: nil
                )
            )
        }

        let fallAction = SCNAction.customAction(duration: fallDuration) { node, elapsedTime in
            let elapsed = Float(elapsedTime)
            let distance = min(dropHeight, 0.5 * gravity * elapsed * elapsed)
            let nextY = max(landedY, startPosition.y - distance)
            node.simdWorldPosition = SIMD3<Float>(startPosition.x, nextY, startPosition.z)
        }

        let landedAction = SCNAction.run { [weak self] _ in
            guard let self else {
                return
            }
            attachedPayloadNode.simdWorldPosition = SIMD3<Float>(startPosition.x, landedY, startPosition.z)
            self.spawnPayloadImpactVisual(
                releaseID: releaseID,
                position: SIMD3<Float>(startPosition.x, landedY, startPosition.z),
                payloadType: releasedPayloadType,
                impactSpeedMps: estimatedImpactSpeed
            )
            if var runtime = self.droppedPayloadRuntime[releaseID] {
                runtime.lastSampledPosition = attachedPayloadNode.presentation.simdWorldPosition
                runtime.verticalSpeed = 0.0
                runtime.state = .impact
                runtime.impactTimestamp = CACurrentMediaTime()
                self.droppedPayloadRuntime[releaseID] = runtime
            }
            self.pendingPayloadLifecycleEvents.append(
                PayloadLifecycleEvent(
                    releaseID: releaseID,
                    state: .landed,
                    messageKey: "payload.message.dropped_successfully",
                    impactPosition: SIMD3<Float>(startPosition.x, landedY, startPosition.z),
                    impactSpeedMps: estimatedImpactSpeed
                )
            )
        }

        let cleanupAction = SCNAction.run { [weak self, weak attachedPayloadNode] _ in
            guard let self else {
                return
            }
            attachedPayloadNode?.removeAllActions()
            attachedPayloadNode?.removeFromParentNode()
            self.droppedPayloadNodes.removeValue(forKey: releaseID)
            self.droppedPayloadRuntime.removeValue(forKey: releaseID)
            if self.payloadCameraFocusReleaseID == releaseID {
                self.payloadCameraFocusReleaseID = nil
            }
            self.pendingPayloadLifecycleEvents.append(
                PayloadLifecycleEvent(
                    releaseID: releaseID,
                    state: .cleanedUp,
                    messageKey: "payload.message.cleanup_completed",
                    impactPosition: nil,
                    impactSpeedMps: nil
                )
            )
        }

        attachedPayloadNode.runAction(
            .sequence([
                .wait(duration: 0.06),
                startFalling,
                fallAction,
                landedAction,
                .wait(duration: 1.2),
                cleanupAction
            ]),
            forKey: "payloadDropLifecycle"
        )

        return releaseID
    }

    func clearDroppedPayloadVisuals() {
        for node in droppedPayloadNodes.values {
            node.removeAllActions()
            node.removeFromParentNode()
        }
        for node in payloadImpactNodes.values {
            node.removeAllActions()
            node.removeFromParentNode()
        }
        droppedPayloadNodes.removeAll(keepingCapacity: false)
        droppedPayloadRuntime.removeAll(keepingCapacity: false)
        payloadImpactNodes.removeAll(keepingCapacity: false)
        payloadCameraFocusReleaseID = nil
        payloadDropCameraController.reset()
        pendingPayloadLifecycleEvents.removeAll(keepingCapacity: false)
    }

    func setWorldBoundsVisible(_ visible: Bool) {
        guard areWorldBoundsVisible != visible else {
            return
        }
        areWorldBoundsVisible = visible
        applyWorldBoundsVisibility()
    }

    func applyCameraNudge(
        mode: CameraMode,
        yawDeltaDeg: Float,
        pitchDeltaDeg: Float,
        invertX: Bool,
        invertY: Bool
    ) {
        let yawSign: Float = invertX ? -1.0 : 1.0
        let pitchSign: Float = invertY ? -1.0 : 1.0
        let yawDelta = yawDeltaDeg.degreesToRadians * yawSign
        let pitchDelta = pitchDeltaDeg.degreesToRadians * pitchSign

        switch mode {
        case .free:
            freeLookAngles.x += yawDelta
            freeLookAngles.y = (freeLookAngles.y + pitchDelta).clamped(to: -1.2...1.2)
            freeCameraNode.eulerAngles.y = CGFloat(freeLookAngles.x)
            freeCameraNode.eulerAngles.x = CGFloat(freeLookAngles.y)
        case .fpv:
            fpvLookAngles.x = (fpvLookAngles.x + yawDelta).clamped(to: -0.9...0.9)
            fpvLookAngles.y = (fpvLookAngles.y + pitchDelta).clamped(to: -0.7...0.7)
        case .follow, .orbit, .top, .payloadOptics, .payload, .spectator:
            return
        }
    }

    func resetCameraOrientation(for mode: CameraMode) {
        switch mode {
        case .free:
            freeLookAngles = .zero
            freeCameraNode.eulerAngles = SCNVector3Zero
        case .follow:
            return
        case .orbit:
            orbitLookAngles = .zero
        case .fpv:
            fpvLookAngles = .zero
        case .top:
            topLookAngles = .zero
        case .payloadOptics:
            return
        case .payload:
            return
        case .spectator:
            spectatorLookAngles = .zero
            spectatorCameraNode.eulerAngles = SCNVector3Zero
        }
    }

    func syncCameraTransition(from oldMode: CameraMode, to newMode: CameraMode) {
        if oldMode == newMode {
            return
        }

        if oldMode == .fpv, newMode != .fpv {
            orbitLookAngles = .zero
            topLookAngles = .zero
            fpvObstructionHidingActive = false
            restoreAfterFPVIfNeeded()
        }

        switch newMode {
        case .orbit:
            orbitLookAngles = .zero
        case .top:
            topLookAngles = .zero
        case .free, .follow, .fpv, .payloadOptics, .payload, .spectator:
            break
        }
    }

    func obstacleSourceLabel(for id: UUID) -> String? {
        obstacleSourceByID[id]
    }

    func sceneDiagnostics() -> (activeObjectCount: Int, activePhysicsBodyCount: Int, activeParticleCount: Int) {
        let objects = obstacleMap.count + wingmanVisuals.count + 1
        let bodyCount = droneCollisionProxyNode.physicsBody == nil ? 0 : 1
        let particleCount = Int((rainSystem?.birthRate ?? 0) + (snowSystem?.birthRate ?? 0))
        return (objects, bodyCount, particleCount)
    }

    func dollyFreeCamera(by step: Float) {
        let forward = simd_normalize(simd_act(freeCameraNode.simdOrientation, SIMD3<Float>(0, 0, -1)))
        freeCameraNode.simdPosition += forward * step
    }

    func configureSpectatorRuntime(camera: CameraConfiguration) {
        droneNode.isHidden = true
        droneNode.opacity = 0.0
        visualRootNode.isHidden = true
        fpvPresentationActive = false
        fpvObstructionHidingActive = false
        spectatorLookAngles = SIMD2<Float>(0.0, -0.18)
        spectatorCameraNode.camera?.fieldOfView = CGFloat(camera.fov)
        spectatorCameraNode.camera?.zNear = 0.01
        spectatorCameraNode.simdPosition = SIMD3<Float>(0.0, 5.2, 12.0)
        spectatorCameraNode.eulerAngles = SCNVector3(
            CGFloat(spectatorLookAngles.y),
            CGFloat(spectatorLookAngles.x),
            0.0
        )
    }

    func updateSpectatorRuntime(camera: CameraConfiguration) {
        spectatorCameraNode.camera?.fieldOfView = CGFloat(camera.fov)
        spectatorCameraNode.camera?.zNear = 0.01
        droneNode.isHidden = true
        visualRootNode.isHidden = true
    }

    func applySpectatorLook(
        yawDeltaDeg: Float,
        pitchDeltaDeg: Float,
        invertX: Bool,
        invertY: Bool
    ) {
        let yawSign: Float = invertX ? -1.0 : 1.0
        let pitchSign: Float = invertY ? -1.0 : 1.0
        spectatorLookAngles.x += yawDeltaDeg.degreesToRadians * yawSign
        spectatorLookAngles.y = (spectatorLookAngles.y + pitchDeltaDeg.degreesToRadians * pitchSign)
            .clamped(to: -1.45...1.45)
        spectatorCameraNode.eulerAngles = SCNVector3(
            CGFloat(spectatorLookAngles.y),
            CGFloat(spectatorLookAngles.x),
            0.0
        )
    }

    func moveSpectatorCamera(
        forward: Float,
        strafe: Float,
        deltaTime: Float,
        speed: Float
    ) {
        guard deltaTime > 0.0 else {
            return
        }

        let forwardVector = simd_normalize(simd_act(spectatorCameraNode.simdOrientation, SIMD3<Float>(0.0, 0.0, -1.0)))
        let rightVector = simd_normalize(simd_act(spectatorCameraNode.simdOrientation, SIMD3<Float>(1.0, 0.0, 0.0)))
        let desiredMotion = forwardVector * forward + rightVector * strafe
        let length = simd_length(desiredMotion)
        guard length > 0.001 else {
            return
        }

        spectatorCameraNode.simdPosition += (desiredMotion / length) * max(0.0, speed) * deltaTime
    }

    func setDroneProfile(_ profile: DroneModelProfile) {
        activeProfile = profile

        droneNode.removeFromParentNode()
        clearDroppedPayloadVisuals()

        let droneVisual = DroneModelBuilder.build(profile: profile)
        droneNode = droneVisual.rootNode
        visualRootNode = droneVisual.visualRootNode
        cameraAnchorNode = droneVisual.cameraAnchorNode
        groundReferenceNode = droneVisual.groundReferenceNode
        fpvAnchorNode = droneVisual.fpvAnchorNode
        payloadMountNode = droneVisual.payloadMountNode
        propellerNodes = droneVisual.propellerNodes
        spinDirections = droneVisual.propellerSpinDirections
        componentNodes = droneVisual.componentNodes
        spinAngles = Array(repeating: 0.0, count: propellerNodes.count)
        visualBoundsCenter = droneVisual.visualBoundsCenter
        visualBoundsSize = droneVisual.visualBoundsSize
        cachedSubjectScale = droneVisual.subjectScale
        fpvLookAngles = .zero
        orbitLookAngles = .zero
        topLookAngles = .zero
        lastComponentOverlaySignature = nil
        fpvObstructionHidingActive = false
        fpvPresentationActive = false
        payloadVisualNode = nil
        activePayloadConfiguration = nil
        resetFPVPayloadPresentation()

        scene.rootNode.addChildNode(droneNode)
        ensurePayloadCameraNode()
        fpvPresentationRootNode.simdTransform = matrix_identity_float4x4
        configureDroneCollisionProxy(for: profile)
        resetCameraRuntimeState()
    }

    func resetCameraRuntimeState() {
        orbitAngle = 0.0
        fpvObstructionHidingActive = false
        fpvPresentationActive = false
        restoreAfterFPVIfNeeded()
        fpvPresentationRootNode.simdTransform = matrix_identity_float4x4
        followRigNode.simdPosition = .zero
        followRigNode.simdOrientation = simd_quatf()
        followCameraNode.simdPosition = .zero
        followCameraNode.simdOrientation = simd_quatf()
        fpvCameraAnchorNode.simdPosition = .zero
        fpvCameraAnchorNode.simdOrientation = simd_quatf()
        fpvYawNode.eulerAngles = SCNVector3(0.0, 0.0, 0.0)
        fpvPitchNode.eulerAngles = SCNVector3(0.0, 0.0, 0.0)
        fpvPitchNode.simdPosition = .zero
        payloadDropCameraController.reset()
    }

    func regenerateEnvironment(_ terrain: TerrainConfiguration) {
        lastTerrainConfig = terrain
        EnvironmentObjectFactory.resetDiagnostics()
        EnvironmentObjectFactory.snowWeatherActive = (currentWeather.preset == .snow)

        if terrain.preset == .city {
            let generationKey = CityGenerationKey(
                mapPreset: terrain.preset,
                mapScale: terrain.mapScale,
                densityBits: terrain.density.bitPattern,
                seed: terrain.seed,
                weatherPreset: currentWeather.preset,
                environmentRevision: cityEnvironmentRevision
            )
            if lastGeneratedCityKey == generationKey, hasCityRootInstalled(in: scene.rootNode) {
                #if DEBUG
                print("[City] generation skipped: same generation key")
                #endif
                return
            }

            let cleanup = removeExistingCityRoots(from: scene.rootNode)
            if cleanup.rootCount > 0 || cleanup.nodeCount > 0 {
                #if DEBUG
                print("[City] cleanup removed oldCityRoots=\(cleanup.rootCount) oldCityNodes=\(cleanup.nodeCount)")
                #endif
            }
            regenerateAbandonedCityEnvironment(terrain)
            lastGeneratedCityKey = generationKey
            return
        }

        lastGeneratedCityKey = nil
        let cleanup = removeExistingCityRoots(from: scene.rootNode)
        if cleanup.rootCount > 0 || cleanup.nodeCount > 0 {
            #if DEBUG
            print("[City] cleanup removed oldCityRoots=\(cleanup.rootCount) oldCityNodes=\(cleanup.nodeCount)")
            #endif
        }
        #if DEBUG
        print("[City] skipped: map is not city")
        #endif
        let (descriptors, nodesByID) = scenePopulationService.populate(with: terrain)
        installEnvironment(
            descriptors: descriptors,
            nodesByID: nodesByID,
            terrain: terrain,
            printProceduralDiagnostics: true
        )
    }

    private func regenerateAbandonedCityEnvironment(_ terrain: TerrainConfiguration) {
        scenePopulationService.clear()
        let composition = abandonedCitySceneComposer.rebuild(
            in: scene.rootNode,
            terrain: terrain
        )
        installEnvironment(
            descriptors: composition.descriptors,
            nodesByID: composition.nodesByID,
            terrain: terrain,
            printProceduralDiagnostics: false
        )
    }

    private func installEnvironment(
        descriptors: [EnvironmentObjectDescriptor],
        nodesByID: [UUID: SCNNode],
        terrain: TerrainConfiguration,
        printProceduralDiagnostics: Bool
    ) {
        environmentMapDescriptors = descriptors.filter(\.isCollidable)
        supportSurfaces = environmentMapDescriptors.flatMap(supportSurfaceDescriptors(for:))

        obstacleMap = [:]
        obstacleSourceByID = [:]
        var obstacles: [CollisionObstacle] = []
        for descriptor in descriptors where descriptor.isCollidable {
            if let node = nodesByID[descriptor.id] {
                let descriptorObstacles = configureObstacleCollisionProxies(
                    for: node,
                    descriptor: descriptor
                )
                for obstacle in descriptorObstacles {
                    obstacleMap[obstacle.id] = node
                    obstacleSourceByID[obstacle.id] = obstacle.source
                    obstacles.append(obstacle)
                }
            }
        }

        if printProceduralDiagnostics {
            EnvironmentObjectFactory.printDiagnostics()
        }
        applyTerrainVisualStyle(terrain)
        updateDockStationPosition(for: terrain)
        updateWorldBoundsVisual(for: terrain)

        let supplementalObstacles = buildSupplementalCollisionObstacles(for: terrain)
        for entry in supplementalObstacles {
            obstacles.append(entry.obstacle)
            obstacleSourceByID[entry.obstacle.id] = entry.obstacle.source
            if let node = entry.highlightNode {
                obstacleMap[entry.obstacle.id] = node
            }
        }

        environmentObstacles = obstacles
        environmentRevision &+= 1

        obstacleDebugProxyNodes.removeAll(keepingCapacity: false)
        collisionDebugNode.childNodes
            .filter { $0 !== nearestContactNode }
            .forEach { $0.removeFromParentNode() }
        nearestContactNode.isHidden = true

        pathDebugSignature = 0
        rebuildPathDebug(path: [])
        pathStartMarkerNode.isHidden = true
        pathGoalMarkerNode.isHidden = true
        pathCurrentWaypointNode.isHidden = true

        buildSnowDecorations(for: terrain)
        if terrain.preset == .city {
            printCityGenerationDiagnostics(descriptors: descriptors)
        }

        // Environment was rebuilt — thermal proxies are stale.
        invalidateThermalScene()
    }

    func applyWeatherVisual(_ weather: WeatherModel) {
        let signature = weatherVisualSignature(weather)
        if lastWeatherVisualSignature == signature {
            return
        }

        lastWeatherVisualSignature = signature
        currentWeather = weather

        applyFogParameters(for: weather)
        updateWeatherParticles(weather)
        updateWeatherEnvelope(weather)
        updateStormClouds(weather)

        if let terrain = lastTerrainConfig {
            let haze = skyHorizonHazeColor(for: weather)
            let backgroundImage = skyGradientImage(
                for: terrain.preset,
                weatherFogColor: haze?.color,
                weatherFogStrength: haze?.strength ?? 0,
                weatherHazeDistribution: haze?.distribution ?? .groundHaze
            )
            scene.background.contents = backgroundImage
            // Keep the thermal restore target current if the EO sky changed while thermal is
            // active (the dirty flag re-paints the thermal sky on the next frame).
            if thermalRenderingActive { thermalSavedBackground = backgroundImage }
            // applyTerrainVisualStyle keeps lightingEnvironment.contents in lockstep with the
            // visible sky on terrain changes; weather can change independently of terrain, so
            // without this the IBL ambient light kept using the pre-storm bright gradient even
            // though the visible sky had already gone dark.
            scene.lightingEnvironment.contents = backgroundImage

            let isSnow = weather.preset == .snow
            if terrain.preset != .city {
                scenePopulationService.refreshTreeVisuals(snowWeatherActive: isSnow)
            }
            refreshGroundMaterial(for: terrain)
            buildSnowDecorations(for: terrain)

            // Weather change re-creates tree/ground visuals → thermal proxies are stale.
            invalidateThermalScene()
        }
    }

    private func applyFogParameters(for weather: WeatherModel) {
        let intensity = CGFloat(weather.normalizedIntensity)

        switch weather.preset {
        case .normal:
            scene.fogStartDistance = 760
            scene.fogEndDistance = 2600
            scene.fogDensityExponent = 1.18
            scene.fogColor = NSColor(calibratedRed: 0.62, green: 0.74, blue: 0.86, alpha: 1.0)

        case .wind:
            scene.fogStartDistance = 580 - intensity * 90
            scene.fogEndDistance = 2200 - intensity * 360
            scene.fogDensityExponent = 1.16 + intensity * 0.34
            scene.fogColor = NSColor(calibratedRed: 0.58, green: 0.68, blue: 0.76, alpha: 1.0)

        case .rain, .snow, .fog, .smog, .thunderstorm:
            let factors = weather.effectiveFactors
            scene.fogStartDistance = CGFloat(32.0 * factors.visibilityFactor + 4.0)
            scene.fogEndDistance = CGFloat(260.0 * factors.visibilityFactor + 24.0)
            scene.fogDensityExponent = CGFloat(0.75 + (1.0 - factors.visibilityFactor) * 2.7)

            switch weather.preset {
            case .rain:
                scene.fogColor = NSColor(calibratedRed: 0.38, green: 0.42, blue: 0.49, alpha: 1.0)
            case .snow:
                scene.fogColor = NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.90, alpha: 1.0)
            case .fog:
                scene.fogColor = NSColor(calibratedWhite: 0.84, alpha: 1.0)
            case .smog:
                scene.fogColor = NSColor(calibratedRed: 0.56, green: 0.54, blue: 0.50, alpha: 1.0)
            case .thunderstorm:
                scene.fogColor = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.29, alpha: 1.0)
            case .normal, .wind:
                break
            }
        }

        // Keep the thermal restore target current, then re-neutralize so the EO haze colour just
        // applied above never reaches the thermal proxies (see neutralizeFogForThermal).
        if thermalRenderingActive {
            thermalSavedFogStart = scene.fogStartDistance
            thermalSavedFogEnd = scene.fogEndDistance
            neutralizeFogForThermal()
        }
    }

    /// Background cloud decoration — always present regardless of weather, similar to how a
    /// clear sky still has some clouds in it. Re-centered on the drone's XZ position (and held
    /// a fixed height above its *current* altitude) every frame in `update`, but never rotated
    /// to match drone heading — that distinction matters: every camera (main or FPV) uses a
    /// `zFar` of only 900 units (`configureCameraNode`), so anything genuinely fixed in world
    /// space gets left behind — and hard-clipped mid-card, reading as a sharp edge — the moment
    /// the drone flies any real distance from spawn. Following position keeps it in range;
    /// *not* following orientation is what actually fixed the "rotates with the aircraft" complaint
    /// (that turned out to be a billboard-constraint bug, not the position tracking itself).
    ///
    /// Dubai_Clouds only has 6 unique cloud shapes spread across one ~3km cluster — at native
    /// scale most of that already exceeds the 900-unit budget on its own. Each instance is
    /// scaled down to fit comfortably inside it, and several differently-rotated instances are
    /// placed at small offsets to fill more of the sky using the same asset.
    // A steep altitude-vs-spread ratio buries clouds almost directly overhead, invisible
    // without pitching the camera up. Verified via an offscreen SCNRenderer snapshot test at
    // *level* camera pitch (no looking up) before settling on these — this spread keeps
    // multiple instances in view at a normal forward-looking angle, on most headings.
    private static let skyCloudInstanceRadius: Float = 180
    private static let skyCloudAltitudeAboveDrone: Float = 90
    private static let skyCloudInstanceOffsets: [(SCNVector3, Float)] = [
        (SCNVector3(0, 0, 500), 0),
        (SCNVector3(420, 15, -380), 1.1),
        (SCNVector3(-480, -10, 300), 2.6),
        (SCNVector3(350, 20, 420), 4.0),
        (SCNVector3(-520, 5, -280), 5.4)
    ]

    private func setUpSkyClouds() {
        for (offset, yaw) in Self.skyCloudInstanceOffsets {
            guard let node = WeatherCloudAssetLoader.shared.makeSkyCloudsNode(
                offset: offset,
                yaw: yaw,
                targetRadius: Self.skyCloudInstanceRadius
            ) else {
                continue
            }
            skyCloudsNode.addChildNode(node)
        }
    }

    // 8 hand-placed cards left wide gaps between them — at a typical forward-pitched view, mostly
    // empty dark gradient showed through, which read as "night sky" rather than "covered in dark
    // clouds" (the user's exact complaint). Two full-360° rings of big, overlapping cards instead
    // — a near/low ring (closer, lower, smaller cards) and a far/high ring (farther, much higher
    // above the drone, bigger cards so they stay legible at distance) — so wherever the camera
    // looks, there's cloud coverage both near the horizon and higher up, not just a thin band.
    // Each tuple is (offset, yaw, tint, opacity, radius) — darker tint + higher opacity reads as a
    // denser, thicker cell; lighter/more transparent ones read as thinner, wispier cloud, which is
    // "разной густоты" (varying density), not just "more clouds".
    private struct StormCloudRingSpec {
        let distance: Float
        let altitude: Float
        let radius: Float
        let count: Int
    }

    // Offset magnitude + radius for the far ring is ~531+300=831, safely inside camera.zFar=900
    // (see SceneFactory.makeCameraNode) — the same zFar-safety margin every other cloud placement
    // in this file keeps.
    private static let stormCloudRings: [StormCloudRingSpec] = [
        StormCloudRingSpec(distance: 320, altitude: 55, radius: 230, count: 10),
        StormCloudRingSpec(distance: 520, altitude: 130, radius: 300, count: 10)
    ]

    private static let stormCloudInstances: [(offset: SCNVector3, yaw: Float, tint: NSColor, opacity: Float, radius: Float)] = {
        var instances: [(offset: SCNVector3, yaw: Float, tint: NSColor, opacity: Float, radius: Float)] = []
        for ring in stormCloudRings {
            for i in 0..<ring.count {
                let baseAngle = (Float(i) / Float(ring.count)) * 2.0 * Float.pi
                let angle = baseAngle + Float.random(in: -0.18...0.18)
                let x = cos(angle) * ring.distance
                let z = sin(angle) * ring.distance
                // 0.22-0.58 stays well lighter than the near-black sky color (~0.13-0.16 after the
                // night-vs-storm-day rebalance below) — a card tinted as dark as its backdrop has
                // no contrast and effectively disappears.
                let grey = CGFloat(Float.random(in: 0.22...0.58))
                let tint = NSColor(calibratedWhite: grey, alpha: 1.0)
                let opacity = Float.random(in: 0.45...0.92)
                instances.append((
                    offset: SCNVector3(x, ring.altitude, z),
                    yaw: angle,
                    tint: tint,
                    opacity: opacity,
                    radius: ring.radius
                ))
            }
        }
        return instances
    }()

    private func setUpStormClouds() {
        guard !stormCloudsBuilt else { return }
        stormCloudsBuilt = true
        for instance in Self.stormCloudInstances {
            guard let node = WeatherCloudAssetLoader.shared.makeStormCloudNode(
                offset: instance.offset,
                yaw: instance.yaw,
                targetRadius: instance.radius,
                tintColor: instance.tint,
                opacity: instance.opacity
            ) else {
                continue
            }
            stormCloudsNode.addChildNode(node)
        }
    }

    /// Fog/smog get a tangible cloud/smoke volume around the drone, on top of the existing
    /// distance-based `scene.fog*` properties — a single floating cloud wouldn't read as
    /// ambient haze, so the asset is scaled up into a soft shell the drone flies inside of.
    private func updateWeatherEnvelope(_ weather: WeatherModel) {
        // Thunderstorm deliberately does NOT use this envelope, unlike fog/smog: it's a flat,
        // untextured, single-color sphere by construction (see makeEnvelopeSphere) — exactly
        // right for uniform haze, but at storm-strength opacity it fills the whole view with one
        // flat color and erases any cloud structure behind it. The user's own read on that result
        // was "это больше похоже на туман другого цвета, чем на отличительные черты погоды с
        // грозой" (this looks more like fog of a different color than distinctive thunderstorm
        // features) — confirming the flat sphere is the wrong tool for "distinctive dark clouds".
        // Thunderstorm darkening instead comes from the sky gradient's `.overcast` distribution
        // (real gradient/structure) plus the storm cloud cards plus dimmed sun/shadows.
        guard weather.preset == .fog || weather.preset == .smog else {
            weatherEnvelopeNode.isHidden = true
            activeWeatherEnvelopePreset = nil
            return
        }

        if activeWeatherEnvelopePreset != weather.preset {
            weatherEnvelopeNode.childNodes.forEach { $0.removeFromParentNode() }
            let node: SCNNode?
            switch weather.preset {
            case .fog:
                node = WeatherCloudAssetLoader.shared.makeFogEnvelopeNode(targetRadius: Self.weatherEnvelopeRadius)
            case .smog:
                node = WeatherCloudAssetLoader.shared.makeSmogEnvelopeNode(targetRadius: Self.weatherEnvelopeRadius)
            default:
                node = nil
            }
            if let node {
                weatherEnvelopeNode.addChildNode(node)
                activeWeatherEnvelopePreset = weather.preset
            } else {
                activeWeatherEnvelopePreset = nil
            }
        }

        let hasContent = !weatherEnvelopeNode.childNodes.isEmpty
        weatherEnvelopeNode.isHidden = !hasContent
        // A single flat-shaded sphere layer, no overlapping duplicates compounding alpha
        // (unlike the old mesh-based envelope), so this opacity is the actual visible strength,
        // not diluted by stacking — can run much higher than the old 0.03-0.12 range.
        weatherEnvelopeNode.opacity = CGFloat(0.25 + weather.normalizedIntensity * 0.55)
    }

    // Built lazily on first thunderstorm activation rather than at scene setup like skyCloudsNode
    // — this avoids paying the Dubai_Clouds clone+tint+deep-copy cost for every session that never
    // selects this preset. Stays built afterward (just toggled hidden) since presets are switched
    // back and forth far more often than this initial build cost would justify repeating.
    private func updateStormClouds(_ weather: WeatherModel) {
        guard weather.preset == .thunderstorm else {
            stormCloudsNode.isHidden = true
            return
        }
        setUpStormClouds()
        stormCloudsNode.isHidden = false
        // Same non-zero floor pattern as weatherEnvelopeNode/skyHorizonHazeColor — intensity is
        // 0 by default until the user separately touches a slider, and gating fully on it caused
        // the exact same "preset selected but nothing visible" bug fixed twice already elsewhere.
        stormCloudsNode.opacity = CGFloat(0.6 + weather.normalizedIntensity * 0.4)
    }

    // SCNCamera.wantsDepthOfField produced zero visible blur in this SceneKit/macOS build, even
    // at extreme settings (fStop 0.5, focalLength 135mm), verified via both an offscreen
    // SCNRenderer and a live SCNView snapshot — a known SceneKit limitation, not a tuning gap.
    // Real blur is now a from-scratch SCNTechnique (WeatherDepthOfFieldTechnique.swift +
    // WeatherDepthOfField.metal), toggled on the SCNView itself based on
    // DroneSimulationViewModel.wantsWeatherDepthOfField — see DroneSceneViewRepresentable.

    func update(
        with state: DroneState,
        camera: CameraConfiguration,
        damage: DamageState,
        thermal: ThermalState,
        diagnosticMode: DiagnosticOverlayMode,
        deltaTime: Float
    ) {
        droneNode.position = SCNVector3(state.position.x, state.position.y, state.position.z)
        let droneOrientation = orientationQuaternion(from: state.orientation)
        droneNode.simdOrientation = droneOrientation

        skyCloudsNode.position = SCNVector3(
            CGFloat(state.position.x),
            CGFloat(state.position.y + Self.skyCloudAltitudeAboveDrone),
            CGFloat(state.position.z)
        )

        if !weatherEnvelopeNode.isHidden {
            weatherEnvelopeNode.position = SCNVector3(state.position.x, state.position.y, state.position.z)
        }

        if !stormCloudsNode.isHidden {
            // Each ring's altitude is already baked into its instances' own offsets (see
            // stormCloudRings) — this just keeps the whole formation centered over the drone's
            // current position, not an extra altitude on top.
            stormCloudsNode.position = SCNVector3(
                CGFloat(state.position.x),
                CGFloat(state.position.y),
                CGFloat(state.position.z)
            )
        }

        fpvPresentationActive = camera.mode == .fpv
        fpvObstructionHidingActive = (camera.mode == .fpv) && camera.fpv.hideObstructingParts
        visualRootNode.isHidden = fpvPresentationActive
        if camera.mode != .fpv {
            droneNode.isHidden = false
            droneNode.opacity = 1.0
        }
        applyPayloadFPVPresentation()
        updatePayloadCamera(state: payloadCameraOpticsState, droneState: state, deltaTime: deltaTime)

        rotatePropellers(state: state, deltaTime: deltaTime)
        updateDroppedPayloadRuntime(deltaTime: deltaTime)
        applyComponentOverlays(damage: damage, thermal: thermal, mode: diagnosticMode)
        updateCameras(
            state: state,
            droneOrientation: droneOrientation,
            settings: camera,
            deltaTime: deltaTime
        )
        updateWeatherAnimation(deltaTime: deltaTime, weather: currentWeather)
        applyPayloadOpticsShadowQuality(
            isActive: camera.mode == .payloadOptics,
            weather: currentWeather
        )
    }

    func updateCollisionDebug(risk: CollisionAnalysisSnapshot, enabled: Bool) {
        guard enabled else {
            collisionDebugNode.isHidden = true
            nearestContactNode.isHidden = true
            return
        }

        ensureCollisionDebugMarkers()
        collisionDebugNode.isHidden = false

        let highlightColor: NSColor
        switch risk.emergencyAction {
        case .none:
            highlightColor = .clear
        case .slowDown:
            highlightColor = NSColor.systemYellow.withAlphaComponent(0.55)
        case .hover, .avoid:
            highlightColor = NSColor.systemOrange.withAlphaComponent(0.58)
        case .emergencyStop:
            highlightColor = NSColor.systemRed.withAlphaComponent(0.62)
        }

        let nearestID = risk.nearestObstacleID
        let dronePlanarPosition = SIMD2<Float>(droneNode.presentation.simdWorldPosition.x, droneNode.presentation.simdWorldPosition.z)
        let visibleDebugRadius: Float = 32.0
        let emphasizedDebugRadius: Float = 14.0

        for (id, marker) in obstacleDebugProxyNodes {
            guard let center = obstacleCenter(for: id) else {
                marker.isHidden = true
                continue
            }

            let planarDistance = simd_distance(dronePlanarPosition, SIMD2<Float>(center.x, center.z))
            let isNearest = id == nearestID
            let isVisible = isNearest || planarDistance <= visibleDebugRadius
            marker.isHidden = !isVisible

            let color: NSColor
            if isNearest {
                color = risk.emergencyAction == .none
                    ? NSColor.systemRed.withAlphaComponent(0.82)
                    : highlightColor
            } else if planarDistance <= emphasizedDebugRadius {
                color = NSColor.systemOrange.withAlphaComponent(0.56)
            } else {
                color = NSColor.systemYellow.withAlphaComponent(0.34)
            }

            marker.geometry?.firstMaterial?.diffuse.contents = color
        }

        if let nearestID,
           let center = obstacleCenter(for: nearestID) {
            nearestContactNode.isHidden = false
            nearestContactNode.position = SCNVector3(center.x, center.y + 0.2, center.z)
        } else {
            nearestContactNode.isHidden = true
        }
    }

    func updatePathDebug(
        path: [SIMD3<Float>],
        currentWaypointIndex: Int,
        start: SIMD3<Float>?,
        goal: SIMD3<Float>?,
        enabled: Bool
    ) {
        guard enabled else {
            pathDebugNode.isHidden = true
            pathCurrentWaypointNode.isHidden = true
            return
        }

        pathDebugNode.isHidden = false
        let signature = pathSignature(path: path, currentWaypointIndex: currentWaypointIndex)
        if signature != pathDebugSignature {
            rebuildPathDebug(path: path)
            pathDebugSignature = signature
        }

        if let start {
            pathStartMarkerNode.isHidden = false
            pathStartMarkerNode.position = SCNVector3(start.x, start.y + 0.12, start.z)
        } else {
            pathStartMarkerNode.isHidden = true
        }

        if let goal {
            pathGoalMarkerNode.isHidden = false
            pathGoalMarkerNode.position = SCNVector3(goal.x, goal.y + 0.14, goal.z)
        } else {
            pathGoalMarkerNode.isHidden = true
        }

        if path.indices.contains(currentWaypointIndex) {
            let point = path[currentWaypointIndex]
            pathCurrentWaypointNode.isHidden = false
            pathCurrentWaypointNode.position = SCNVector3(point.x, point.y + 0.10, point.z)
        } else {
            pathCurrentWaypointNode.isHidden = true
        }
    }

    func obstacleCenter(for id: UUID) -> SIMD3<Float>? {
        if let dynamicObstacle = dynamicObstacles[id] {
            return dynamicObstacle.center
        }
        return environmentObstacles.first(where: { $0.id == id })?.center
    }

    func obstacle(for id: UUID) -> CollisionObstacle? {
        if let dynamicObstacle = dynamicObstacles[id] {
            return dynamicObstacle
        }
        return environmentObstacles.first(where: { $0.id == id })
    }

    func supportSurfaceHeight(
        at planarPosition: SIMD2<Float>,
        clearanceRadius: Float,
        maximumHeight: Float
    ) -> Float? {
        var bestHeight: Float?
        for surface in supportSurfaces {
            guard surface.topY <= maximumHeight + 0.08 else {
                continue
            }
            guard planarPoint(planarPosition, intersects: surface, clearanceRadius: clearanceRadius) else {
                continue
            }
            if bestHeight == nil || surface.topY > (bestHeight ?? -.greatestFiniteMagnitude) {
                bestHeight = surface.topY
            }
        }
        return bestHeight
    }

    private func pathSignature(path: [SIMD3<Float>], currentWaypointIndex: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(path.count)
        hasher.combine(currentWaypointIndex)
        for point in path {
            hasher.combine(Int((point.x * 10.0).rounded()))
            hasher.combine(Int((point.y * 10.0).rounded()))
            hasher.combine(Int((point.z * 10.0).rounded()))
        }
        return hasher.finalize()
    }

    private func rebuildPathDebug(path: [SIMD3<Float>]) {
        pathSegmentNodes.forEach { $0.removeFromParentNode() }
        pathPointNodes.forEach { $0.removeFromParentNode() }
        pathSegmentNodes.removeAll(keepingCapacity: false)
        pathPointNodes.removeAll(keepingCapacity: false)

        guard path.count >= 2 else {
            return
        }

        for index in 0..<(path.count - 1) {
            let from = path[index]
            let to = path[index + 1]
            let segmentNode = makePathSegmentNode(from: from, to: to)
            pathDebugNode.addChildNode(segmentNode)
            pathSegmentNodes.append(segmentNode)
        }

        for point in path {
            let marker = SCNNode(geometry: SCNSphere(radius: 0.05))
            marker.position = SCNVector3(point.x, point.y + 0.02, point.z)
            marker.geometry?.firstMaterial?.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.72)
            marker.geometry?.firstMaterial?.lightingModel = .constant
            pathDebugNode.addChildNode(marker)
            pathPointNodes.append(marker)
        }
    }

    private func makePathSegmentNode(from: SIMD3<Float>, to: SIMD3<Float>) -> SCNNode {
        let delta = to - from
        let length = max(0.001, simd_length(delta))
        let cylinder = SCNCylinder(radius: 0.045, height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.66)
        cylinder.firstMaterial?.lightingModel = .constant
        cylinder.firstMaterial?.readsFromDepthBuffer = false

        let node = SCNNode(geometry: cylinder)
        let midpoint = (from + to) * 0.5
        node.simdPosition = midpoint

        if simd_length_squared(delta) > 0.00001 {
            let direction = simd_normalize(delta)
            let up = SIMD3<Float>(0.0, 1.0, 0.0)
            node.simdOrientation = simd_quatf(from: up, to: direction)
        } else {
            node.simdOrientation = simd_quatf()
        }
        return node
    }

    func updateFleetWingmen(
        _ wingmen: [DroneEntity],
        profile: DroneModelProfile,
        throttle: Float,
        deltaTime: Float
    ) {
        let incomingIDs = Set(wingmen.map(\.id))
        let obsoleteIDs = wingmanVisuals.keys.filter { !incomingIDs.contains($0) }

        for id in obsoleteIDs {
            if let visual = wingmanVisuals[id] {
                visual.rootNode.removeFromParentNode()
            }
            wingmanVisuals[id] = nil
            dynamicObstacles[id] = nil
        }

        for wingman in wingmen {
            if wingmanVisuals[wingman.id] == nil {
                wingmanVisuals[wingman.id] = makeWingmanVisual(profile: profile)
                if let root = wingmanVisuals[wingman.id]?.rootNode {
                    scene.rootNode.addChildNode(root)
                }
            }

            guard var visual = wingmanVisuals[wingman.id] else {
                continue
            }

            visual.rootNode.simdPosition = wingman.position
            let velocityMagnitude = simd_length(wingman.velocity)
            if velocityMagnitude > 0.1 {
                let yaw = atan2(wingman.velocity.x, wingman.velocity.z)
                visual.rootNode.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0.0, 1.0, 0.0))
            }

            rotateWingmanPropellers(visual: &visual, throttle: throttle, deltaTime: deltaTime)
            wingmanVisuals[wingman.id] = visual
            dynamicObstacles[wingman.id] = CollisionObstacle(
                id: wingman.id,
                center: wingman.position,
                radius: wingman.collisionRadius,
                source: "wingman",
                baseY: wingman.position.y - wingman.collisionRadius,
                topY: wingman.position.y + wingman.collisionRadius
            )
        }
    }

    private func configureCameraNode(_ node: SCNNode, fov: Float, hidesDroppedPayload: Bool = false) {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fov)
        camera.zNear = 0.01
        camera.zFar = CameraClipping.standardFar
        camera.categoryBitMask = hidesDroppedPayload ? RenderCategory.visibleInFPV : RenderCategory.standardVisible
        node.camera = camera
    }

    func ensurePayloadCameraNode() {
        if payloadCameraNode == nil {
            let node = SCNNode()
            node.name = "payloadCameraNode"

            let camera = SCNCamera()
            camera.fieldOfView = CGFloat(payloadCameraOpticsState.currentFieldOfViewDegrees)
            camera.zNear = 0.015
            camera.zFar = CameraClipping.payloadOpticsFar
            camera.categoryBitMask = RenderCategory.visibleInPayloadOptics
            node.camera = camera

            payloadCameraRigNode.name = "payloadCameraRigNode"
            payloadCameraYawNode.name = "payloadCameraYawNode"
            payloadCameraPitchNode.name = "payloadCameraPitchNode"

            payloadCameraRigNode.removeFromParentNode()
            payloadCameraYawNode.removeFromParentNode()
            payloadCameraPitchNode.removeFromParentNode()

            payloadCameraRigNode.addChildNode(payloadCameraYawNode)
            payloadCameraYawNode.addChildNode(payloadCameraPitchNode)
            payloadCameraPitchNode.addChildNode(node)

            payloadCameraPitchNode.simdPosition = SIMD3<Float>(0.0, -0.02, 0.02)
            payloadCameraNode = node
            payloadCamera = camera
        }

        if payloadCameraRigNode.parent !== payloadMountNode {
            payloadCameraRigNode.removeFromParentNode()
            payloadMountNode.addChildNode(payloadCameraRigNode)
        }
    }

    func updatePayloadCamera(state: PayloadCameraOpticsState, droneState: DroneState, deltaTime: Float = 0.0) {
        payloadCameraOpticsState = state
        ensurePayloadCameraNode()

        payloadCameraRigNode.isHidden = !state.isAvailable
        updatePayloadTargetLockReferenceIfNeeded(state: state, droneState: droneState)
        let stabilizationTarget = state.isAvailable ? stabilizedPayloadCameraEuler(for: droneState) : .zero
        let response = 3.0 + Float(state.angularDamping) * 9.0
        let stabilizationBlend = deltaTime > 0.0 ? min(deltaTime * response, 1.0) : 1.0
        payloadCameraStabilizationEuler += (stabilizationTarget - payloadCameraStabilizationEuler) * stabilizationBlend
        payloadCameraRigNode.eulerAngles = SCNVector3(
            payloadCameraStabilizationEuler.x,
            payloadCameraStabilizationEuler.y,
            payloadCameraStabilizationEuler.z
        )
        payloadCameraYawNode.eulerAngles.y = CGFloat(Float(state.gimbalYawDegrees).degreesToRadians)
        payloadCameraPitchNode.eulerAngles.x = CGFloat(Float(state.gimbalPitchDegrees).degreesToRadians)
        payloadCamera?.fieldOfView = CGFloat(state.currentFieldOfViewDegrees)
        payloadCamera?.zNear = 0.015
        payloadCamera?.zFar = CameraClipping.payloadOpticsFar
    }

    func ensureRangefinderRig() {
        if rangefinderYawNode.parent !== rangefinderRigNode {
            rangefinderRigNode.name = "rangefinderRigNode"
            rangefinderYawNode.name = "rangefinderYawNode"
            rangefinderPitchNode.name = "rangefinderPitchNode"

            rangefinderRigNode.removeFromParentNode()
            rangefinderYawNode.removeFromParentNode()
            rangefinderPitchNode.removeFromParentNode()

            rangefinderRigNode.addChildNode(rangefinderYawNode)
            rangefinderYawNode.addChildNode(rangefinderPitchNode)
            rangefinderPitchNode.simdPosition = SIMD3<Float>(0.0, -0.02, 0.02)
        }

        if rangefinderBeamNode == nil {
            let beamMaterial = SCNMaterial()
            beamMaterial.lightingModel = .constant
            beamMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.08, blue: 0.05, alpha: 1.0)
            beamMaterial.emission.contents = NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.08, alpha: 1.0)

            let geometry = SCNCylinder(radius: 0.0035, height: 1.0)
            geometry.radialSegmentCount = 8
            geometry.firstMaterial = beamMaterial

            let beam = SCNNode(geometry: geometry)
            beam.name = "rangefinderBeamNode"
            beam.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
            beam.isHidden = true
            rangefinderPitchNode.addChildNode(beam)
            rangefinderBeamNode = beam
        }

        if rangefinderCameraNode == nil {
            let node = SCNNode()
            node.name = "rangefinderCameraNode"

            let camera = SCNCamera()
            camera.fieldOfView = CGFloat(rangefinderOpticsState.currentFieldOfViewDegrees)
            camera.zNear = 0.015
            camera.zFar = CameraClipping.payloadOpticsFar
            camera.categoryBitMask = RenderCategory.visibleInPayloadOptics
            node.camera = camera

            rangefinderPitchNode.addChildNode(node)
            rangefinderCameraNode = node
            rangefinderCamera = camera
        }

        if rangefinderRigNode.parent !== payloadMountNode {
            rangefinderRigNode.removeFromParentNode()
            payloadMountNode.addChildNode(rangefinderRigNode)
        }
    }

    func updateRangefinderGimbal(state: PayloadRangefinderOpticsState) {
        rangefinderOpticsState = state
        ensureRangefinderRig()

        rangefinderRigNode.isHidden = !state.isAvailable
        rangefinderYawNode.eulerAngles.y = CGFloat(Float(state.gimbalYawDegrees).degreesToRadians)
        rangefinderPitchNode.eulerAngles.x = CGFloat(Float(state.gimbalPitchDegrees).degreesToRadians)
        rangefinderCamera?.fieldOfView = CGFloat(state.currentFieldOfViewDegrees)
    }

    func rangefinderTargetDistance(maxDistance: Double) -> Double? {
        guard rangefinderOpticsState.isAvailable, rangefinderOpticsState.isPowered else {
            return nil
        }
        ensureRangefinderRig()

        let origin = rangefinderPitchNode.presentation.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(rangefinderPitchNode.presentation.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        guard simd_length_squared(forward) > 0.000001 else {
            return nil
        }

        let distanceLimit = max(1.0, Float(maxDistance))
        let end = origin + forward * distanceLimit
        let results = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(origin.x, origin.y, origin.z),
            to: SCNVector3(end.x, end.y, end.z),
            options: [
                SCNHitTestOption.backFaceCulling.rawValue: false,
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue
            ]
        )

        for result in results {
            if isDescendant(result.node, of: droneNode) || isDescendant(result.node, of: rangefinderRigNode) {
                continue
            }

            let hit = SIMD3<Float>(
                Float(result.worldCoordinates.x),
                Float(result.worldCoordinates.y),
                Float(result.worldCoordinates.z)
            )
            return Double(simd_distance(origin, hit))
        }

        return nil
    }

    func updateRangefinderBeam(state: PayloadRangefinderOpticsState) {
        ensureRangefinderRig()
        guard let beam = rangefinderBeamNode else {
            return
        }

        guard state.isAvailable, state.isPowered, state.isArmed else {
            beam.isHidden = true
            return
        }

        let length = max(0.01, Float(state.measuredDistanceMeters ?? state.maxRangeMeters))
        beam.isHidden = false
        (beam.geometry as? SCNCylinder)?.height = CGFloat(length)
        beam.position = SCNVector3(0.0, 0.0, -length / 2.0)
    }

    private func stabilizedPayloadCameraEuler(for droneState: DroneState) -> SIMD3<Float> {
        let strength = Float(payloadCameraOpticsState.stabilizationStrength).clamped(to: 0.0...1.0)
        guard strength > 0.001 else {
            return .zero
        }

        let rollCompensation = (-droneState.orientation.x * (0.76 + 0.22 * strength)).clamped(to: -0.8...0.8)
        let pitchCompensation = (-droneState.orientation.y * (0.78 + 0.20 * strength)).clamped(to: -0.8...0.8)
        let yawRateCompensation = (-droneState.angularVelocity.z * Float(payloadCameraOpticsState.vibrationSuppression) * 0.24 * strength)
            .clamped(to: -0.32...0.32)

        switch payloadCameraOpticsState.stabilizationMode {
        case .off:
            return .zero
        case .horizonLock:
            return SIMD3<Float>(pitchCompensation * strength, yawRateCompensation, rollCompensation * strength)
        case .lowSpeedStabilized:
            return SIMD3<Float>(pitchCompensation * strength, yawRateCompensation, rollCompensation * strength)
        case .targetLock:
            let lockedYaw = payloadCameraTargetLockYaw ?? droneState.orientation.z
            let lockedPitch = payloadCameraTargetLockPitch ?? (-0.18)
            let yawHold = (lockedYaw - droneState.orientation.z).clamped(to: -1.15...1.15)
            let pitchHold = (lockedPitch - droneState.orientation.y).clamped(to: -0.95...0.95)
            return SIMD3<Float>(pitchHold, yawHold, rollCompensation * strength)
        }
    }

    private func updatePayloadTargetLockReferenceIfNeeded(state: PayloadCameraOpticsState, droneState: DroneState) {
        guard state.isAvailable, state.targetLockEnabled else {
            payloadCameraTargetLockYaw = nil
            payloadCameraTargetLockPitch = nil
            return
        }

        if payloadCameraTargetLockYaw == nil {
            payloadCameraTargetLockYaw = droneState.orientation.z + Float(state.gimbalYawDegrees).degreesToRadians
        }
        if payloadCameraTargetLockPitch == nil {
            payloadCameraTargetLockPitch = droneState.orientation.y + Float(state.gimbalPitchDegrees).degreesToRadians
        }
    }

    private func updateCameras(
        state: DroneState,
        droneOrientation: simd_quatf,
        settings: CameraConfiguration,
        deltaTime: Float
    ) {
        let response: Float
        if deltaTime <= 0.0001 {
            response = 1.0
        } else {
            let blend = (1.0 - settings.smoothing.clamped(to: 0.0...0.95)) * deltaTime * 8.0
            response = blend.clamped(to: 0.05...1.0)
        }

        let dronePos = state.position
        let yawOnly = simd_quatf(angle: state.orientation.z, axis: SIMD3<Float>(0, 1, 0))
        let bodyForward = modelForwardLocal()
        let forward = simd_normalize(simd_act(yawOnly, bodyForward))
        let up = SIMD3<Float>(0.0, 1.0, 0.0)

        let dims = activeProfile.dimensions
        let subjectScale = max(activeProfile.collisionRadius * 2.0, max(dims.widthM, dims.lengthM))

        let chaseDistanceRange: ClosedRange<Float>
        let chaseHeightRange: ClosedRange<Float>
        let anchorLift: Float
        if activeProfile.airframeClass == .fixedWing {
            chaseDistanceRange = max(3.4, subjectScale * 3.0)...max(7.2, subjectScale * 5.6)
            chaseHeightRange = max(0.8, subjectScale * 0.22)...max(2.2, subjectScale * 0.68)
            anchorLift = max(0.20, subjectScale * 0.10)
        } else {
            chaseDistanceRange = max(1.6, subjectScale * 2.8)...max(3.9, subjectScale * 5.0)
            chaseHeightRange = max(0.36, subjectScale * 0.18)...max(1.35, subjectScale * 0.52)
            anchorLift = max(0.10, subjectScale * 0.08)
        }

        let chaseDistanceRequested = settings.follow.distance.clamped(to: settings.follow.minDistance...settings.follow.maxDistance)
        let chaseDistance = chaseDistanceRequested.clamped(to: chaseDistanceRange)
        let chaseHeightRequested = settings.follow.height + (activeProfile.airframeClass == .fixedWing ? Float(0.30) : Float(0.14))
        let chaseHeight = chaseHeightRequested.clamped(to: chaseHeightRange)
        let chaseAnchor = dronePos + up * anchorLift
        let chaseVerticalOffset = up * max(0.12, subjectScale * 0.14)

        followRigNode.simdPosition = chaseAnchor
        followRigNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0.0, 0.0, -1.0), to: forward)

        var followLocalPosition = SIMD3<Float>(
            settings.follow.lateralOffset,
            chaseHeight,
            chaseDistance
        )
        followLocalPosition.y = max(followLocalPosition.y, max(0.30, subjectScale * 0.28))
        followCameraNode.simdPosition = followLocalPosition

        let followLocalLookTarget = SIMD3<Float>(0.0, chaseVerticalOffset.y, 0.0)
        let followOrientation = cameraOrientation(
            from: followLocalPosition,
            to: followLocalLookTarget,
            yawOffset: 0.0,
            pitchOffset: 0.0
        )
        followCameraNode.simdOrientation = followOrientation

        orbitAngle += deltaTime * settings.orbit.angularSpeed.clamped(to: 0.05...2.0)
        let orbitDistanceRange: ClosedRange<Float> = activeProfile.airframeClass == .fixedWing
            ? max(4.0, subjectScale * 3.4)...max(8.0, subjectScale * 6.4)
            : max(2.2, subjectScale * 3.6)...max(5.0, subjectScale * 6.2)
        let orbitDistance = settings.orbit.distance
            .clamped(to: settings.orbit.minDistance...settings.orbit.maxDistance)
            .clamped(to: orbitDistanceRange)
        let orbitHeight = (settings.orbit.height + max(0.10, subjectScale * 0.10))
            .clamped(to: max(0.5, subjectScale * 0.16)...max(2.4, subjectScale * 0.80))
        let orbitPos = SIMD3<Float>(
            chaseAnchor.x + cos(orbitAngle) * orbitDistance,
            chaseAnchor.y + orbitHeight,
            chaseAnchor.z + sin(orbitAngle) * orbitDistance
        )
        orbitCameraNode.simdPosition = simd_mix(orbitCameraNode.simdPosition, orbitPos, SIMD3<Float>(repeating: response))
        let orbitOrientation = cameraOrientation(
            from: orbitCameraNode.simdPosition,
            to: chaseAnchor + up * max(0.16, subjectScale * 0.14),
            yawOffset: 0.0,
            pitchOffset: 0.0
        )
        orbitCameraNode.simdOrientation = simd_normalize(
            simd_slerp(orbitCameraNode.simdOrientation, orbitOrientation, response)
        )

        let topHeightRange: ClosedRange<Float> = activeProfile.airframeClass == .fixedWing
            ? 9.0...26.0
            : 6.0...15.0
        let topHeight = settings.top.height
            .clamped(to: settings.top.minHeight...settings.top.maxHeight)
            .clamped(to: topHeightRange)
        let topForwardLead = settings.top.forwardLead.clamped(to: -subjectScale...subjectScale)
        let topTarget = chaseAnchor + forward * topForwardLead
        let topPosition = topTarget + up * topHeight
        topCameraNode.simdPosition = simd_mix(topCameraNode.simdPosition, topPosition, SIMD3<Float>(repeating: response))
        topCameraNode.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)

        cameraNoisePhase += deltaTime * 5.6
        let shake = settings.fpv.shake.clamped(to: 0.0...0.3)
        let sway = SIMD3<Float>(
            sin(cameraNoisePhase * 2.7) * 0.015 * shake,
            sin(cameraNoisePhase * 1.9 + 0.5) * 0.010 * shake,
            0.0
        )
        let fpvAnchor = FPVCameraAnchor.resolved(
            for: activeProfile,
            subjectScale: max(subjectScale, cachedSubjectScale)
        )
        fpvPresentationRootNode.simdWorldTransform = fpvAnchorNode.simdWorldTransform
        let fpvLocalForward = resolvedFPVLocalForward(desiredWorldForward: forward)
        let mountForwardDistance = max(fpvAnchor.forwardClearance, abs(settings.fpv.mountOffset.z))
        let mountForwardOffset = fpvLocalForward * mountForwardDistance
        let mountLateralOffset = SIMD3<Float>(settings.fpv.mountOffset.x, settings.fpv.mountOffset.y, 0.0)
        fpvCameraAnchorNode.simdPosition = fpvAnchor.baseOffset + mountLateralOffset + mountForwardOffset + sway
        updateFPVPayloadPresentationPose(
            bodyForward: fpvLocalForward,
            subjectScale: max(subjectScale, cachedSubjectScale)
        )
        fpvPitchNode.simdPosition = .zero

        let planarVelocity = SIMD2<Float>(state.velocity.x, state.velocity.z)
        let planarSpeed = simd_length(planarVelocity)
        let velocityYaw: Float
        if planarSpeed > 0.35 {
            if fpvLocalForward.z < 0.0 {
                velocityYaw = atan2(-state.velocity.x, -state.velocity.z)
            } else {
                velocityYaw = atan2(state.velocity.x, state.velocity.z)
            }
        } else {
            velocityYaw = state.orientation.z
        }

        let relativeYaw = wrapAngle(velocityYaw - state.orientation.z).clamped(
            to: (-settings.fpv.yawLimitDeg.degreesToRadians)...(settings.fpv.yawLimitDeg.degreesToRadians)
        ) * 0.22
        let userYaw = fpvLookAngles.x.clamped(
            to: (-settings.fpv.yawLimitDeg.degreesToRadians)...(settings.fpv.yawLimitDeg.degreesToRadians)
        )
        let fpvBaseYaw = atan2(fpvLocalForward.x, -fpvLocalForward.z)
        let targetFpvYaw = fpvBaseYaw + relativeYaw + userYaw
        let currentFpvYaw = Float(fpvYawNode.eulerAngles.y)
        fpvYawNode.eulerAngles.y = CGFloat(currentFpvYaw + wrapAngle(targetFpvYaw - currentFpvYaw) * response)

        let gimbalPitch = (-state.velocity.y * 0.05).clamped(
            to: (-settings.fpv.pitchLimitDeg.degreesToRadians)...(settings.fpv.pitchLimitDeg.degreesToRadians)
        )
        let stabilizer = settings.fpv.stabilization.clamped(to: 0.0...1.0)
        let localPitch = (-state.orientation.y * stabilizer * 0.30) + gimbalPitch
        let userPitch = fpvLookAngles.y.clamped(
            to: (-settings.fpv.pitchLimitDeg.degreesToRadians)...(settings.fpv.pitchLimitDeg.degreesToRadians)
        )
        let localRoll = -state.orientation.x * stabilizer * 0.30
        let targetFpvPitch = localPitch + userPitch
        let currentFpvPitch = Float(fpvPitchNode.eulerAngles.x)
        let currentFpvRoll = Float(fpvPitchNode.eulerAngles.z)
        fpvPitchNode.eulerAngles = SCNVector3(
            CGFloat(currentFpvPitch + (targetFpvPitch - currentFpvPitch) * response),
            0.0,
            CGFloat(currentFpvRoll + (localRoll - currentFpvRoll) * response)
        )

        let fov = CGFloat(settings.fov.clamped(to: 30.0...110.0))
        followCameraNode.camera?.fieldOfView = fov
        orbitCameraNode.camera?.fieldOfView = fov
        fpvCameraNode.camera?.fieldOfView = fov
        topCameraNode.camera?.fieldOfView = fov
        freeCameraNode.camera?.fieldOfView = fov
        spectatorCameraNode.camera?.fieldOfView = fov
        fpvCameraNode.camera?.zNear = CGFloat(max(0.015, settings.fpv.nearClip.clamped(to: 0.005...0.25)))
        topCameraNode.camera?.zNear = 0.03
        freeCameraNode.camera?.zNear = 0.01
        spectatorCameraNode.camera?.zNear = 0.01
        payloadDropCameraController.updateCameraProperties(fov: Float(fov), zNear: 0.025)
        if settings.mode == .payload,
           deltaTime <= 0.0001,
           let target = currentPayloadDropCameraTarget() {
            payloadDropCameraController.syncImmediate(
                target: target,
                groundY: max(Float(groundNode.presentation.position.y), 0.0)
            )
        }
    }

    private func restoreAfterFPVIfNeeded() {
        droneNode.isHidden = false
        droneNode.opacity = 1.0
        visualRootNode.isHidden = false
        fpvObstructionHidingActive = false
        fpvPresentationActive = false
        applyPayloadFPVPresentation()

        for nodes in componentNodes.values {
            for node in nodes {
                node.isHidden = false
            }
        }
        lastComponentOverlaySignature = nil
    }

    private func updateDroppedPayloadRuntime(deltaTime: Float) {
        guard !droppedPayloadRuntime.isEmpty else {
            return
        }

        let now = CACurrentMediaTime()
        let sampleDelta = max(0.0001, deltaTime)

        for releaseID in droppedPayloadRuntime.keys {
            guard var runtime = droppedPayloadRuntime[releaseID] else {
                continue
            }

            let position = runtime.node.presentation.simdWorldPosition
            runtime.verticalSpeed = (position.y - runtime.lastSampledPosition.y) / sampleDelta
            runtime.lastSampledPosition = position

            if runtime.state == .impact,
               let impactTimestamp = runtime.impactTimestamp,
               now - impactTimestamp >= 0.24 {
                runtime.state = .rest
            }

            droppedPayloadRuntime[releaseID] = runtime
        }
    }

    private func resolvedPayloadCameraRuntime() -> (UUID, DroppedPayloadRuntime)? {
        let resolvedReleaseID = payloadCameraFocusReleaseID ?? droppedPayloadRuntime.keys.sorted { $0.uuidString < $1.uuidString }.last
        guard let resolvedReleaseID,
              let runtime = droppedPayloadRuntime[resolvedReleaseID] else {
            return nil
        }
        return (resolvedReleaseID, runtime)
    }

    private func spawnPayloadImpactVisual(
        releaseID: UUID,
        position: SIMD3<Float>,
        payloadType _: PayloadType?,
        impactSpeedMps: Float
    ) {
        let impactNode = SCNNode()
        impactNode.name = "payloadImpactVisual_\(releaseID.uuidString)"
        impactNode.simdPosition = SIMD3<Float>(
            position.x,
            max(Float(groundNode.presentation.position.y) + 0.012, position.y),
            position.z
        )

        let markColor = NSColor(calibratedWhite: 0.74, alpha: 0.52)
        let plumeColor = NSColor(calibratedWhite: 0.88, alpha: 0.20)
        let impactRadius = CGFloat((0.42 + min(1.0, impactSpeedMps / 14.0) * 0.30).clamped(to: 0.42...0.82))

        let coreRadius = max(0.08, impactRadius * 0.42)
        let falloffRadius = max(coreRadius + 0.08, impactRadius * 0.88)

        let markMaterial = SCNMaterial()
        markMaterial.diffuse.contents = markColor
        markMaterial.emission.contents = markColor.withAlphaComponent(0.22)
        markMaterial.lightingModel = .constant
        markMaterial.isDoubleSided = true
        markMaterial.blendMode = .alpha
        markMaterial.readsFromDepthBuffer = false
        markMaterial.writesToDepthBuffer = false

        let mark = SCNNode(geometry: SCNCylinder(radius: coreRadius, height: 0.008))
        mark.geometry?.firstMaterial = markMaterial
        mark.opacity = 0.0
        impactNode.addChildNode(mark)

        let falloffMaterial = SCNMaterial()
        falloffMaterial.diffuse.contents = plumeColor.withAlphaComponent(0.18)
        falloffMaterial.emission.contents = plumeColor.withAlphaComponent(0.08)
        falloffMaterial.lightingModel = .constant
        falloffMaterial.blendMode = .alpha
        falloffMaterial.readsFromDepthBuffer = false
        falloffMaterial.writesToDepthBuffer = false

        let falloffDisk = SCNNode(geometry: SCNCylinder(radius: falloffRadius, height: 0.004))
        falloffDisk.geometry?.firstMaterial = falloffMaterial
        falloffDisk.opacity = 0.0
        impactNode.addChildNode(falloffDisk)

        let ringMaterial = SCNMaterial()
        ringMaterial.diffuse.contents = markColor.withAlphaComponent(0.92)
        ringMaterial.emission.contents = markColor.withAlphaComponent(0.34)
        ringMaterial.lightingModel = .constant
        ringMaterial.blendMode = .alpha
        ringMaterial.readsFromDepthBuffer = false
        ringMaterial.writesToDepthBuffer = false

        let ring = SCNNode(geometry: SCNTorus(ringRadius: max(0.06, coreRadius * 0.42), pipeRadius: max(0.010, impactRadius * 0.050)))
        ring.geometry?.firstMaterial = ringMaterial
        ring.eulerAngles.x = .pi / 2.0
        ring.opacity = 0.88
        impactNode.addChildNode(ring)

        let plumeMaterial = SCNMaterial()
        plumeMaterial.diffuse.contents = plumeColor
        plumeMaterial.emission.contents = plumeColor
        plumeMaterial.lightingModel = .constant
        plumeMaterial.blendMode = .alpha

        let plume = SCNNode(geometry: SCNSphere(radius: max(0.08, impactRadius * 0.24)))
        plume.geometry?.firstMaterial = plumeMaterial
        plume.position = SCNVector3(0.0, Float(impactRadius * 0.18), 0.0)
        plume.opacity = 0.0
        impactNode.addChildNode(plume)

        scene.rootNode.addChildNode(impactNode)
        payloadImpactNodes[releaseID] = impactNode

        mark.runAction(.sequence([
            .fadeOpacity(to: 0.64, duration: 0.16),
            .wait(duration: 14.0),
            .fadeOut(duration: 1.2)
        ]))

        falloffDisk.runAction(.sequence([
            .group([
                .fadeOpacity(to: 0.78, duration: 0.12),
                .scale(to: 1.10, duration: 0.16)
            ]),
            .group([
                .fadeOut(duration: 0.92),
                .scale(to: 1.55, duration: 0.92)
            ])
        ]))

        ring.runAction(.group([
            .scale(to: 3.4, duration: 0.56),
            .fadeOut(duration: 0.56)
        ]))

        plume.runAction(.sequence([
            .group([
                .fadeOpacity(to: 0.72, duration: 0.10),
                .scale(to: 1.4, duration: 0.18)
            ]),
            .group([
                .moveBy(x: 0.0, y: impactRadius * 0.58, z: 0.0, duration: 0.60),
                .scale(to: 2.1, duration: 0.60),
                .fadeOut(duration: 0.60)
            ])
        ]))

        impactNode.runAction(.sequence([
            .wait(duration: 15.4),
            .run { [weak self] node in
                node.removeAllActions()
                node.removeFromParentNode()
                self?.payloadImpactNodes.removeValue(forKey: releaseID)
            }
        ]))
    }

    private func currentPayloadDropCameraTarget() -> PayloadDropCameraTarget? {
        guard let (releaseID, runtime) = resolvedPayloadCameraRuntime() else {
            return nil
        }
        return PayloadDropCameraTarget(
            releaseID: releaseID,
            position: runtime.node.presentation.simdWorldPosition
        )
    }

    private func cameraOrientation(
        from position: SIMD3<Float>,
        to target: SIMD3<Float>,
        yawOffset: Float,
        pitchOffset: Float
    ) -> simd_quatf {
        let toTarget = target - position
        let distanceSquared = simd_length_squared(toTarget)
        if distanceSquared < 0.000001 {
            return simd_quatf()
        }

        let forward = simd_normalize(toTarget)
        let planarLength = max(0.0001, simd_length(SIMD2<Float>(forward.x, forward.z)))
        let baseYaw = atan2(forward.x, -forward.z)
        let basePitch = atan2(forward.y, planarLength)
        let yaw = simd_quatf(angle: baseYaw + yawOffset, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: basePitch + pitchOffset, axis: SIMD3<Float>(1, 0, 0))
        return simd_normalize(yaw * pitch)
    }

    private func modelForwardLocal() -> SIMD3<Float> {
        switch activeProfile.airframeClass {
        case .multirotor:
            return SIMD3<Float>(0.0, 0.0, -1.0)
        case .fixedWing:
            return SIMD3<Float>(0.0, 0.0, -1.0)
        }
    }

    private func resolvedFPVLocalForward(desiredWorldForward: SIMD3<Float>) -> SIMD3<Float> {
        let worldOrientation = simd_quatf(fpvPresentationRootNode.simdWorldTransform)
        let localForward = simd_act(simd_inverse(worldOrientation), desiredWorldForward)
        let planarForward = SIMD3<Float>(localForward.x, 0.0, localForward.z)
        let planarLength = simd_length(SIMD2<Float>(planarForward.x, planarForward.z))
        if planarLength < 0.0001 {
            return modelForwardLocal()
        }
        return planarForward / planarLength
    }

    private func isDescendant(_ node: SCNNode, of ancestor: SCNNode) -> Bool {
        var cursor: SCNNode? = node
        while let current = cursor {
            if current === ancestor {
                return true
            }
            cursor = current.parent
        }
        return false
    }

    private func wrapAngle(_ value: Float) -> Float {
        var angle = value
        let tau = Float.pi * 2.0
        while angle > Float.pi { angle -= tau }
        while angle < -Float.pi { angle += tau }
        return angle
    }

    private func rotatePropellers(state: DroneState, deltaTime: Float) {
        let profileFactor = (activeProfile.maxHorizontalSpeedMps / 20.0).clamped(to: 0.55...1.2)
        let rotorOmega = state.rotorAngularSpeed
        let base = [rotorOmega.x, rotorOmega.y, rotorOmega.z, rotorOmega.w]

        for index in propellerNodes.indices {
            let omega = index < base.count ? base[index] : rotorOmega.x
            let fallback = 18.0 + 160.0 * state.throttle * profileFactor
            let spinSpeed = max(0.0, omega) > 0.1 ? omega : fallback
            spinAngles[index] += spinDirections[index] * spinSpeed * deltaTime
            propellerNodes[index].eulerAngles.y = CGFloat(spinAngles[index])
        }
    }

    private func rotateWingmanPropellers(visual: inout WingmanVisual, throttle: Float, deltaTime: Float) {
        let profileFactor = (activeProfile.maxHorizontalSpeedMps / 20.0).clamped(to: 0.55...1.2)
        let idleSpeed: Float = 6.4
        let maxAdditionalSpeed: Float = 114.0 * profileFactor
        let spinSpeed = idleSpeed + maxAdditionalSpeed * throttle

        for index in visual.propellerNodes.indices {
            visual.spinAngles[index] += visual.spinDirections[index] * spinSpeed * deltaTime
            visual.propellerNodes[index].eulerAngles.y = CGFloat(visual.spinAngles[index])
        }
    }

    private func makeWingmanVisual(profile: DroneModelProfile) -> WingmanVisual {
        let model = DroneModelBuilder.build(profile: profile)
        model.rootNode.opacity = 0.74
        model.rootNode.scale = SCNVector3(0.86, 0.86, 0.86)
        tintWingmanNode(model.rootNode)

        return WingmanVisual(
            rootNode: model.rootNode,
            propellerNodes: model.propellerNodes,
            spinDirections: model.propellerSpinDirections,
            spinAngles: Array(repeating: 0.0, count: model.propellerNodes.count)
        )
    }

    private func tintWingmanNode(_ node: SCNNode) {
        if let geometry = node.geometry {
            geometry.materials.forEach {
                $0.multiply.contents = NSColor(calibratedRed: 0.70, green: 0.90, blue: 1.0, alpha: 1.0)
            }
        }

        for child in node.childNodes {
            tintWingmanNode(child)
        }
    }

    private func refreshGroundMaterial(for terrain: TerrainConfiguration) {
        guard let geometry = groundNode.geometry, terrain.preset != .gridDemo else { return }
        let mapSizeMeters = terrain.scenicHalfExtent * 2.0
        let material: SCNMaterial
        if terrain.preset == .city {
            material = AbandonedCityMaterialLoader.makeBrittleStoneMaterial(
                mapSizeMeters: mapSizeMeters
            )
        } else {
            material = (currentWeather.preset == .snow)
                ? SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: mapSizeMeters)
                : GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: mapSizeMeters)
        }
        geometry.materials = [material]
    }

    private func buildSnowDecorations(for terrain: TerrainConfiguration) {
        snowDecorationsNode.childNodes.forEach { $0.removeFromParentNode() }
        guard currentWeather.preset == .snow,
              terrain.preset != .gridDemo,
              terrain.preset != .city else { return }

        var rng = TerrainDetailSeededGenerator(seed: terrain.seed &+ 0xDEAD_BEEF_C0FF_EE42)
        let spawnR = max(terrain.safeSpawnRadius, 6.0)
        let extent = terrain.scenicHalfExtent * 0.82

        // Target visual diameter for each decoration kind, independent of asset native size.
        let targetPatchDiameter: Float = 3.5      // meters across for a snow patch
        let targetFootstepDiameter: Float = 0.55  // meters across for a single footstep print

        let patchLoader = SnowPatchAssetLoader.shared
        let footLoader = SnowFootstepAssetLoader.shared

        // Force asset load (bounding boxes are measured on first load)
        _ = patchLoader.makePatchNode(scale: 1.0)
        _ = footLoader.makeFootstepNode(scale: 1.0)

        let patchBaseScale = patchLoader.naturalFootprint > 0.001
            ? targetPatchDiameter / patchLoader.naturalFootprint : 1.0
        let footBaseScale = footLoader.naturalFootprint > 0.001
            ? targetFootstepDiameter / footLoader.naturalFootprint : 1.0

        // Hard exclusion: no patch centre within (spawnR + half target diameter) of origin,
        // so even the edge of the largest patch never reaches the drone spawn.
        let patchExclusion = spawnR + targetPatchDiameter * 0.6

        let patchCount = 12 + Int(Float.random(in: 0..<1, using: &rng) * 19)
        var placed = 0
        var attempts = 0
        while placed < patchCount, attempts < patchCount * 4 {
            attempts += 1
            let x = Float.random(in: -extent...extent, using: &rng)
            let z = Float.random(in: -extent...extent, using: &rng)
            guard simd_length(SIMD2<Float>(x, z)) >= patchExclusion else { continue }
            let jitter = Float.random(in: 0.7...1.35, using: &rng)
            let scale = patchBaseScale * jitter
            let yaw = Float.random(in: 0..<(.pi * 2), using: &rng)
            if let node = patchLoader.makePatchNode(scale: scale, yaw: yaw) {
                node.position = SCNVector3(x, 0.0, z)
                snowDecorationsNode.addChildNode(node)
                placed += 1
            }
        }

        // Footsteps: scattered in a band beyond spawn, not directly at origin
        let footMin = spawnR + 4.0
        let footMax = min(spawnR + 22.0, extent * 0.9)
        let footCount = 4 + Int(Float.random(in: 0..<1, using: &rng) * 7)
        for _ in 0..<footCount {
            let angle = Float.random(in: 0..<(.pi * 2), using: &rng)
            let dist = Float.random(in: footMin...max(footMin + 1, footMax), using: &rng)
            let x = cos(angle) * dist
            let z = sin(angle) * dist
            let jitter = Float.random(in: 0.85...1.15, using: &rng)
            let scale = footBaseScale * jitter
            let yaw = Float.random(in: 0..<(.pi * 2), using: &rng)
            if let node = footLoader.makeFootstepNode(scale: scale, yaw: yaw) {
                node.position = SCNVector3(x, 0.0, z)
                snowDecorationsNode.addChildNode(node)
            }
        }

        let patches = snowDecorationsNode.childNodes.filter { $0.name == "environment.snow_patch" }.count
        let footsteps = snowDecorationsNode.childNodes.filter { $0.name == "environment.snow_footstep" }.count
        print("[Snow] Decorations built: patches=\(patches) footsteps=\(footsteps) patchScale=\(String(format:"%.3f",patchBaseScale)) footScale=\(String(format:"%.3f",footBaseScale))")
    }

    private func applyTerrainVisualStyle(_ terrain: TerrainConfiguration) {
        configureWorldSurfaceGeometry(for: terrain)
        applyLightingProfile(for: terrain.preset)

        let haze = skyHorizonHazeColor(for: currentWeather)
        let backgroundImage = skyGradientImage(
            for: terrain.preset,
            weatherFogColor: haze?.color,
            weatherFogStrength: haze?.strength ?? 0,
            weatherHazeDistribution: haze?.distribution ?? .groundHaze
        )

        switch terrain.preset {
        case .gridDemo:
            gridNode.isHidden = false
            axesNode.isHidden = false
        case .field, .forest, .cargoYard, .city:
            gridNode.isHidden = true
            axesNode.isHidden = true
        }

        scene.background.contents = backgroundImage
        if thermalRenderingActive { thermalSavedBackground = backgroundImage }
        scene.lightingEnvironment.contents = backgroundImage

        if let geometry = groundNode.geometry {
            let mapSizeMeters = terrain.scenicHalfExtent * 2.0
            let groundMaterial: SCNMaterial
            switch terrain.preset {
            case .city:
                groundMaterial = AbandonedCityMaterialLoader.makeBrittleStoneMaterial(
                    mapSizeMeters: mapSizeMeters
                )
            case .cargoYard:
                if currentWeather.preset == .snow {
                    groundMaterial = SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: mapSizeMeters)
                } else {
                    groundMaterial = AsphaltMaterialLoader.makeAsphaltMaterial(mapSizeMeters: mapSizeMeters)
                }
            case .field, .forest:
                if currentWeather.preset == .snow {
                    groundMaterial = SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: mapSizeMeters)
                } else {
                    groundMaterial = GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: mapSizeMeters)
                }
            case .gridDemo:
                let proc = (EnvironmentProceduralMaterials.groundMaterial(for: terrain.preset).copy() as? SCNMaterial)
                    ?? EnvironmentProceduralMaterials.groundMaterial(for: terrain.preset)
                let scenicRepeat = max(10.0, min(28.0, terrain.scenicHalfExtent / 28.0))
                proc.diffuse.wrapS = .repeat
                proc.diffuse.wrapT = .repeat
                proc.diffuse.contentsTransform = SCNMatrix4MakeScale(
                    CGFloat(scenicRepeat),
                    CGFloat(scenicRepeat),
                    1.0
                )
                groundMaterial = proc
            }
            geometry.materials = [groundMaterial]
        }

        updateTerrainDetailGeometry(for: terrain)
    }

    private func updateTerrainDetailGeometry(for terrain: TerrainConfiguration) {
        terrainDetailNode.childNodes.forEach { $0.removeFromParentNode() }

        switch terrain.preset {
        case .field, .forest:
            rebuildNaturalSurfaceDetail(for: terrain)
        case .cargoYard, .city, .gridDemo:
            return
        }
    }

    private func rebuildNaturalSurfaceDetail(for terrain: TerrainConfiguration) {
        let coverageScale = max(1.0, terrain.worldHalfExtent / 96.0)
        let detailScale = max(0.9, terrain.areaScaleFactor * 0.58 + coverageScale * 0.42)
        let halfExtent = terrain.worldHalfExtent * 0.92
        let isForest = terrain.preset == .forest
        let primaryCount = isForest
            ? max(14, Int(12.0 + detailScale * 5.0))
            : max(5, Int(4.0 + detailScale * 1.8))
        let accentCount = isForest
            ? max(7, Int(5.0 + detailScale * 2.4))
            : max(2, Int(1.0 + detailScale * 0.8))
        let shadowCount = isForest
            ? max(8, Int(6.0 + detailScale * 2.2))
            : 0
        let seedOffset: UInt64 = isForest ? 0xF057 : 0xF13D
        var generator = TerrainDetailSeededGenerator(seed: terrain.seed &+ seedOffset)

        let primaryMaterial = terrainDetailMaterial(
            diffuse: isForest
                ? NSColor(calibratedRed: 0.18, green: 0.17, blue: 0.11, alpha: 0.32)
                : NSColor(calibratedRed: 0.45, green: 0.40, blue: 0.21, alpha: 0.20),
            emission: isForest
                ? NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.04, alpha: 0.05)
                : NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.07, alpha: 0.03),
            roughness: 0.99
        )
        let accentMaterial = terrainDetailMaterial(
            diffuse: isForest
                ? NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.12, alpha: 0.24)
                : NSColor(calibratedRed: 0.38, green: 0.44, blue: 0.20, alpha: 0.18),
            emission: isForest
                ? NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.06, alpha: 0.05)
                : NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.04, alpha: 0.03),
            roughness: 0.98
        )
        let shadowMaterial = terrainDetailMaterial(
            diffuse: NSColor(calibratedWhite: 0.02, alpha: 0.28),
            roughness: 1.0
        )

        for index in 0..<primaryCount {
            let radiusX = Float.random(
                in: isForest ? 10.0...24.0 : 14.0...30.0,
                using: &generator
            )
            let radiusZ = Float.random(
                in: isForest ? 8.0...20.0 : 10.0...22.0,
                using: &generator
            )
            let material = index % 4 == 0 ? accentMaterial : primaryMaterial
            terrainDetailNode.addChildNode(
                makeTerrainPatchNode(
                    radiusX: radiusX,
                    radiusZ: radiusZ,
                    y: 0.008 + Float(index % 3) * 0.001,
                    halfExtent: halfExtent,
                    material: material,
                    generator: &generator
                )
            )
        }

        for _ in 0..<accentCount {
            terrainDetailNode.addChildNode(
                makeTerrainPatchNode(
                    radiusX: Float.random(in: 8.0...18.0, using: &generator),
                    radiusZ: Float.random(in: 7.0...16.0, using: &generator),
                    y: 0.012,
                    halfExtent: halfExtent,
                    material: accentMaterial,
                    generator: &generator
                )
            )
        }

        for _ in 0..<shadowCount {
            terrainDetailNode.addChildNode(
                makeTerrainPatchNode(
                    radiusX: Float.random(in: 5.0...11.0, using: &generator),
                    radiusZ: Float.random(in: 4.0...10.0, using: &generator),
                    y: 0.014,
                    halfExtent: halfExtent,
                    material: shadowMaterial,
                    generator: &generator
                )
            )
        }
    }

    private func terrainDetailMaterial(
        diffuse: NSColor,
        emission: NSColor = .clear,
        roughness: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness
        material.metalness.contents = 0.0
        material.emission.contents = emission
        return material
    }

    private func makeTerrainPatchNode(
        radiusX: Float,
        radiusZ: Float,
        y: Float,
        halfExtent: Float,
        material: SCNMaterial,
        generator: inout TerrainDetailSeededGenerator
    ) -> SCNNode {
        let baseRadius = max(radiusX, radiusZ) * 0.5
        let patch = SCNNode(geometry: SCNCylinder(radius: CGFloat(baseRadius), height: 0.010))
        patch.scale = SCNVector3(radiusX / (baseRadius * 2.0), 1.0, radiusZ / (baseRadius * 2.0))
        patch.position = SCNVector3(
            Float.random(in: -halfExtent...halfExtent, using: &generator),
            y,
            Float.random(in: -halfExtent...halfExtent, using: &generator)
        )
        patch.eulerAngles = SCNVector3(0, Float.random(in: 0.0...(.pi * 2.0), using: &generator), 0)
        patch.geometry?.materials = [material]
        return patch
    }

    private func applyLightingProfile(for terrain: TerrainPreset) {
        let sunIntensity: CGFloat
        let sunColor: NSColor
        let environmentIntensity: CGFloat

        switch terrain {
        case .gridDemo:
            sunIntensity = 1500
            sunColor = NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1.0)
            environmentIntensity = 0.82
        case .field:
            sunIntensity = 1840
            sunColor = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.88, alpha: 1.0)
            environmentIntensity = 1.18
        case .forest:
            sunIntensity = 1720
            sunColor = NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.92, alpha: 1.0)
            environmentIntensity = 1.08
        case .cargoYard:
            sunIntensity = 1810
            sunColor = NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.86, alpha: 1.0)
            environmentIntensity = 1.02
        case .city:
            sunIntensity = 1760
            sunColor = NSColor(calibratedRed: 0.99, green: 0.95, blue: 0.90, alpha: 1.0)
            environmentIntensity = 0.96
        }

        sunLightNode.light?.intensity = sunIntensity
        sunLightNode.light?.color = sunColor
        scene.lightingEnvironment.intensity = environmentIntensity
    }

    private func configureWorldSurfaceGeometry(for terrain: TerrainConfiguration) {
        let scenicHalfExtent = terrain.scenicHalfExtent + 24.0
        if let plane = groundNode.geometry as? SCNPlane {
            plane.width = CGFloat(scenicHalfExtent * 2.0)
            plane.height = CGFloat(scenicHalfExtent * 2.0)
        }

        let gridHalfExtent = min(terrain.worldHalfExtent, max(108.0, terrain.signalBoundaryRadius + 18.0))
        let gridSpacing: Float = gridHalfExtent > 180.0 ? 12.0 : 8.0
        rebuildGridGuide(halfExtent: gridHalfExtent, spacing: gridSpacing)
    }

    private func rebuildGridGuide(halfExtent: Float, spacing: Float) {
        gridNode.childNodes.forEach { $0.removeFromParentNode() }

        for index in stride(from: -halfExtent, through: halfExtent, by: spacing) {
            let majorLine = abs(index.truncatingRemainder(dividingBy: spacing * 4.0)) < 0.001
            let thickness: CGFloat = majorLine ? 0.11 : 0.05
            let alpha: CGFloat = majorLine ? 0.22 : 0.10

            let xLine = SCNNode(geometry: SCNBox(
                width: CGFloat(halfExtent * 2.0),
                height: 0.0004,
                length: thickness,
                chamferRadius: 0.0
            ))
            xLine.position = SCNVector3(0.0, 0.0, index)
            xLine.geometry?.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(alpha)

            let zLine = SCNNode(geometry: SCNBox(
                width: thickness,
                height: 0.0004,
                length: CGFloat(halfExtent * 2.0),
                chamferRadius: 0.0
            ))
            zLine.position = SCNVector3(index, 0.0, 0.0)
            zLine.geometry?.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(alpha)

            gridNode.addChildNode(xLine)
            gridNode.addChildNode(zLine)
        }
    }

    /// `.groundHaze` keeps the existing fog/smog behavior: strongest at the horizon, thinning out
    /// overhead, matching how ground-level haze actually thins with altitude. `.overcast` is for
    /// thunderstorm — a real storm sky is capped by cloud nearly everywhere, often *darkest*
    /// overhead rather than at the horizon (where a paler band under the storm's leading edge is
    /// common) — so it blends strongly at all three gradient stops instead of fading toward the
    /// top. See `skyGradientImage` for where the fractions actually differ.
    private enum SkyHazeDistribution {
        case groundHaze
        case overcast
    }

    /// Only fog/smog/thunderstorm get a sky-gradient haze blend — matches `wantsWeatherDepthOfField`'s
    /// own gating and the envelope sphere's preset check. Other presets (rain, snow, wind) keep
    /// their `scene.fogColor` treatment on real geometry only; reusing them here unconditionally
    /// would incorrectly recolor the sky for weather that was never meant to touch the horizon.
    /// Strength has the same non-zero floor as the weather envelope sphere's opacity
    /// (`0.25 + intensity*0.55` in `updateWeatherEnvelope`) — and for the same reason that bit
    /// `wantsWeatherDepthOfField` earlier: picking a fog/smog/thunderstorm preset from the UI
    /// without separately raising an intensity slider leaves `weather.intensity` at 0, and a
    /// strength tied directly to `normalizedIntensity` (no floor) meant `weatherFogStrength > 0`
    /// was false and the whole blend got skipped — zero visible error, zero visible effect.
    /// Thunderstorm's floor is deliberately higher than fog/smog's (0.78 vs 0.7) and its color
    /// near-black rather than pale — a freshly-selected storm preset with no slider touch should
    /// already read as a real storm, not "barely different from clear weather", which is what it
    /// looked like before this existed: `effectiveFactors.visibilityFactor` itself is 1.0 (fully
    /// clear) at intensity 0 since it interpolates *from* 1.0, so nothing else in
    /// `applyWeatherVisual` darkened anything either at that point.
    private func skyHorizonHazeColor(for weather: WeatherModel) -> (color: NSColor, strength: CGFloat, distribution: SkyHazeDistribution)? {
        let groundHazeStrength = CGFloat(0.7 + weather.normalizedIntensity * 0.3)
        switch weather.preset {
        case .fog:
            return (NSColor(calibratedRed: 0.84, green: 0.84, blue: 0.84, alpha: 1.0), groundHazeStrength, .groundHaze)
        case .smog:
            return (NSColor(calibratedRed: 0.56, green: 0.54, blue: 0.50, alpha: 1.0), groundHazeStrength, .groundHaze)
        case .thunderstorm:
            // Near-black (0.06-0.08) read as literal nighttime rather than a dark stormy *day* —
            // the user's screenshot showed a near-black sky with the storm cloud cards crushed
            // into it, indistinguishable from stars/night texture. A heavy-overcast slate grey
            // keeps the "oppressive" read while leaving enough headroom for the (now much denser)
            // cloud cards to actually show up as visibly darker shapes against it.
            let stormStrength = CGFloat(0.72 + weather.normalizedIntensity * 0.22)
            return (NSColor(calibratedRed: 0.16, green: 0.165, blue: 0.19, alpha: 1.0), stormStrength, .overcast)
        default:
            return nil
        }
    }

    /// `weatherFogColor`/`weatherFogStrength` pull the gradient's horizon (and partly mid) stop
    /// toward the active fog/smog color. This is what actually fixes the ground/sky horizon seam
    /// — `scene.fog` only tints real depth-tested geometry, never this background image, so the
    /// sky stayed its clear color no matter how the ground faded into fog. A post-process blur
    /// shader can soften the seam's *shape* but can't erase a hard color contrast between two
    /// flat regions; baking the haze into the sky gradient itself, at the source, means there's
    /// no contrast left to fight by the time anything else runs.
    private func skyGradientImage(
        for terrain: TerrainPreset,
        weatherFogColor: NSColor? = nil,
        weatherFogStrength: CGFloat = 0,
        weatherHazeDistribution: SkyHazeDistribution = .groundHaze
    ) -> NSImage {
        let size = NSSize(width: 1024, height: 768)
        let image = NSImage(size: size)
        image.lockFocus()

        var topColor: NSColor
        var midColor: NSColor
        var horizonColor: NSColor

        switch terrain {
        case .gridDemo:
            topColor = NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.28, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.17, green: 0.28, blue: 0.42, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.37, green: 0.52, blue: 0.66, alpha: 1.0)
        case .field:
            topColor = NSColor(calibratedRed: 0.24, green: 0.46, blue: 0.74, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.49, green: 0.69, blue: 0.86, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.83, green: 0.84, blue: 0.69, alpha: 1.0)
        case .forest:
            topColor = NSColor(calibratedRed: 0.16, green: 0.33, blue: 0.51, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.34, green: 0.54, blue: 0.63, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.70, green: 0.76, blue: 0.66, alpha: 1.0)
        case .cargoYard:
            topColor = NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.58, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.51, green: 0.64, blue: 0.72, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.80, green: 0.74, blue: 0.60, alpha: 1.0)
        case .city:
            topColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.35, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.39, green: 0.46, blue: 0.57, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.74, green: 0.68, blue: 0.60, alpha: 1.0)
        }

        if let rawFogColor = weatherFogColor, weatherFogStrength > 0,
           let fogColor = rawFogColor.usingColorSpace(.genericRGB) {
            let clampedStrength = min(max(weatherFogStrength, 0), 1)
            switch weatherHazeDistribution {
            case .groundHaze:
                horizonColor = horizonColor.blended(withFraction: clampedStrength, of: fogColor) ?? horizonColor
                midColor = midColor.blended(withFraction: clampedStrength * 0.65, of: fogColor) ?? midColor
                topColor = topColor.blended(withFraction: clampedStrength * 0.28, of: fogColor) ?? topColor
            case .overcast:
                // Strong at every stop, slightly *more* overhead than at the horizon (1.0 vs 0.85)
                // — a storm ceiling reads as thick cloud everywhere, not haze that thins with
                // altitude, and a paler band right at the horizon under the front is realistic.
                horizonColor = horizonColor.blended(withFraction: clampedStrength * 0.85, of: fogColor) ?? horizonColor
                midColor = midColor.blended(withFraction: clampedStrength * 0.95, of: fogColor) ?? midColor
                topColor = topColor.blended(withFraction: clampedStrength, of: fogColor) ?? topColor
            }
        }

        let bounds = NSRect(origin: .zero, size: size)
        if let gradient = NSGradient(colors: [topColor, midColor, horizonColor]) {
            gradient.draw(in: bounds, angle: -90.0)
        }

        // A thick storm ceiling has no visible sun glow through it — drawing this highlight at
        // its usual strength was quietly re-brightening the otherwise-darkened overcast sky.
        if weatherHazeDistribution != .overcast {
            let hazeRect = NSRect(
                x: size.width * 0.12,
                y: size.height * 0.06,
                width: size.width * 0.76,
                height: size.height * 0.24
            )
            let hazePath = NSBezierPath(ovalIn: hazeRect)
            NSColor.white.withAlphaComponent(0.10).setFill()
            hazePath.fill()
        }

        image.unlockFocus()
        return image
    }

    private func configureDockStationGeometry() {
        dockStationNode.childNodes.forEach { $0.removeFromParentNode() }

        let platformMaterial = SCNMaterial()
        platformMaterial.diffuse.contents = NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.39, alpha: 1.0)
        platformMaterial.roughness.contents = 0.74
        platformMaterial.metalness.contents = 0.42

        let accentMaterial = SCNMaterial()
        accentMaterial.diffuse.contents = NSColor(calibratedRed: 0.84, green: 0.86, blue: 0.88, alpha: 1.0)
        accentMaterial.roughness.contents = 0.38
        accentMaterial.metalness.contents = 0.28

        let footMaterial = SCNMaterial()
        footMaterial.diffuse.contents = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.27, alpha: 1.0)
        footMaterial.roughness.contents = 0.82
        footMaterial.metalness.contents = 0.34

        let base = SCNNode(geometry: SCNBox(width: 2.10, height: 0.10, length: 2.10, chamferRadius: 0.08))
        base.position = SCNVector3(0.0, -0.05, 0.0)
        base.geometry?.materials = [platformMaterial]

        let topPlate = SCNNode(geometry: SCNBox(width: 1.58, height: 0.025, length: 1.58, chamferRadius: 0.04))
        topPlate.position = SCNVector3(0.0, 0.015, 0.0)
        topPlate.geometry?.materials = [accentMaterial]

        let stripeA = SCNNode(geometry: SCNBox(width: 0.12, height: 0.01, length: 1.04, chamferRadius: 0.01))
        stripeA.position = SCNVector3(0.0, 0.032, 0.0)
        stripeA.geometry?.materials = [footMaterial]

        let stripeB = SCNNode(geometry: SCNBox(width: 1.04, height: 0.01, length: 0.12, chamferRadius: 0.01))
        stripeB.position = SCNVector3(0.0, 0.032, 0.0)
        stripeB.geometry?.materials = [footMaterial]

        let footOffsets: [SCNVector3] = [
            SCNVector3(-0.84, -0.12, -0.84),
            SCNVector3(0.84, -0.12, -0.84),
            SCNVector3(-0.84, -0.12, 0.84),
            SCNVector3(0.84, -0.12, 0.84)
        ]

        for offset in footOffsets {
            let foot = SCNNode(geometry: SCNBox(width: 0.16, height: 0.14, length: 0.16, chamferRadius: 0.02))
            foot.position = offset
            foot.geometry?.materials = [footMaterial]
            dockStationNode.addChildNode(foot)
        }

        dockStationNode.addChildNode(base)
        dockStationNode.addChildNode(topPlate)
        dockStationNode.addChildNode(stripeA)
        dockStationNode.addChildNode(stripeB)
    }

    private func updateDockStationPosition(for terrain: TerrainConfiguration) {
        let extent = max(terrain.safeSpawnRadius + 3.0, terrain.worldHalfExtent - 4.0)
        let dockCenter = SIMD3<Float>(0.0, 0.0, 0.0)
        dockSpawnPosition = SIMD3<Float>(
            dockCenter.x.clamped(to: -extent...extent),
            0.0,
            dockCenter.z.clamped(to: -extent...extent)
        )
        // Keep the visual launch deck flush with the physics ground plane so spawn/reset use the same reference height.
        dockStationNode.simdPosition = dockSpawnPosition + SIMD3<Float>(0.0, -dockDeckSurfaceHeight, 0.0)
    }

    private func updateWorldBoundsVisual(for terrain: TerrainConfiguration) {
        worldBoundsNode.childNodes.forEach { $0.removeFromParentNode() }

        let halfExtent = terrain.signalBoundaryRadius
        let edgeThickness = max(0.28, min(0.74, halfExtent * 0.0032))
        let warningBandDepth = max(5.0, min(halfExtent * 0.15, 24.0))

        let ringNode = SCNNode()
        ringNode.name = "boundary_signal_ring"

        let haloNode = SCNNode()
        haloNode.name = "boundary_signal_halo"

        for edge in makeBoundaryEdgeNodes(
            halfExtent: halfExtent,
            edgeThickness: edgeThickness
        ) {
            ringNode.addChildNode(edge)
        }

        for band in makeBoundaryWarningBandNodes(
            halfExtent: halfExtent,
            bandDepth: warningBandDepth
        ) {
            haloNode.addChildNode(band)
        }

        worldBoundsNode.addChildNode(haloNode)
        worldBoundsNode.addChildNode(ringNode)
        applyWorldBoundsVisibility()
    }

    private func applyWorldBoundsVisibility() {
        for node in worldBoundsNode.childNodes {
            node.isHidden = !areWorldBoundsVisible
        }
    }

    private func buildSupplementalCollisionObstacles(for terrain: TerrainConfiguration) -> [SupplementalCollisionObstacle] {
        var entries: [SupplementalCollisionObstacle] = []

        let boundaryRadius = terrain.signalBoundaryRadius
        let boundaryHighlightNode = worldBoundsNode.childNode(withName: "boundary_signal_ring", recursively: false)
        let wallY: Float = 0.42
        let wallRadius = max(3.2, min(7.0, boundaryRadius * 0.032))

        for center in boundaryObstacleCenters(
            halfExtent: boundaryRadius,
            wallY: wallY,
            obstacleRadius: wallRadius
        ) {
            entries.append(
                SupplementalCollisionObstacle(
                    obstacle: CollisionObstacle(
                        id: UUID(),
                        center: center,
                        radius: wallRadius,
                        source: "barrier_signal",
                        baseY: 0.0,
                        topY: max(1.2, wallY * 2.4)
                    ),
                    highlightNode: boundaryHighlightNode
                )
            )
        }

        return entries
    }

    private func makeBoundaryEdgeNodes(
        halfExtent: Float,
        edgeThickness: Float
    ) -> [SCNNode] {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.72)
        material.emission.contents = NSColor.systemCyan.withAlphaComponent(0.18)
        material.roughness.contents = 0.42

        let horizontalGeometry = SCNBox(
            width: CGFloat(halfExtent * 2.0),
            height: CGFloat(edgeThickness),
            length: CGFloat(edgeThickness),
            chamferRadius: CGFloat(edgeThickness * 0.25)
        )
        horizontalGeometry.firstMaterial = material

        let verticalGeometry = SCNBox(
            width: CGFloat(edgeThickness),
            height: CGFloat(edgeThickness),
            length: CGFloat(halfExtent * 2.0),
            chamferRadius: CGFloat(edgeThickness * 0.25)
        )
        verticalGeometry.firstMaterial = material

        let north = SCNNode(geometry: horizontalGeometry)
        north.position = SCNVector3(0.0, 0.08, halfExtent)

        let south = SCNNode(geometry: horizontalGeometry.copy() as? SCNGeometry)
        south.position = SCNVector3(0.0, 0.08, -halfExtent)

        let east = SCNNode(geometry: verticalGeometry)
        east.position = SCNVector3(halfExtent, 0.08, 0.0)

        let west = SCNNode(geometry: verticalGeometry.copy() as? SCNGeometry)
        west.position = SCNVector3(-halfExtent, 0.08, 0.0)

        return [north, south, east, west]
    }

    private func makeBoundaryWarningBandNodes(
        halfExtent: Float,
        bandDepth: Float
    ) -> [SCNNode] {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.10)
        material.emission.contents = NSColor.systemBlue.withAlphaComponent(0.05)
        material.roughness.contents = 0.48

        let innerHalfExtent = max(1.0, halfExtent - bandDepth * 0.5)
        let horizontalGeometry = SCNBox(
            width: CGFloat(halfExtent * 2.0),
            height: 0.02,
            length: CGFloat(bandDepth),
            chamferRadius: 0.0
        )
        horizontalGeometry.firstMaterial = material

        let verticalGeometry = SCNBox(
            width: CGFloat(bandDepth),
            height: 0.02,
            length: CGFloat(halfExtent * 2.0),
            chamferRadius: 0.0
        )
        verticalGeometry.firstMaterial = material

        let north = SCNNode(geometry: horizontalGeometry)
        north.position = SCNVector3(0.0, 0.01, innerHalfExtent)

        let south = SCNNode(geometry: horizontalGeometry.copy() as? SCNGeometry)
        south.position = SCNVector3(0.0, 0.01, -innerHalfExtent)

        let east = SCNNode(geometry: verticalGeometry)
        east.position = SCNVector3(innerHalfExtent, 0.01, 0.0)

        let west = SCNNode(geometry: verticalGeometry.copy() as? SCNGeometry)
        west.position = SCNVector3(-innerHalfExtent, 0.01, 0.0)

        return [north, south, east, west]
    }

    private func boundaryObstacleCenters(
        halfExtent: Float,
        wallY: Float,
        obstacleRadius: Float
    ) -> [SIMD3<Float>] {
        let spacing = max(obstacleRadius * 1.55, 10.0)
        let rawStepCount = max(3, Int(ceil((halfExtent * 2.0) / spacing)))
        let stepCount = min(rawStepCount, 72)
        let effectiveSpacing = (halfExtent * 2.0) / Float(stepCount)
        let offsetRange = 0...stepCount
        var centers: [SIMD3<Float>] = []

        for step in offsetRange {
            let offset = -halfExtent + Float(step) * effectiveSpacing
            centers.append(SIMD3<Float>(offset, wallY, halfExtent))
            centers.append(SIMD3<Float>(offset, wallY, -halfExtent))
        }

        if stepCount > 1 {
            for step in 1..<stepCount {
                let offset = -halfExtent + Float(step) * effectiveSpacing
                centers.append(SIMD3<Float>(halfExtent, wallY, offset))
                centers.append(SIMD3<Float>(-halfExtent, wallY, offset))
            }
        }

        return centers
    }

    private func configureDroneCollisionProxy(for profile: DroneModelProfile) {
        droneCollisionProxyNode.removeFromParentNode()

        let compactRadius = max(0.08, profile.collisionRadius * 0.78)
        droneCollisionProxyRadius = compactRadius

        let sphere = SCNSphere(radius: CGFloat(compactRadius))
        sphere.firstMaterial?.diffuse.contents = NSColor.clear
        sphere.firstMaterial?.lightingModel = .constant
        droneCollisionProxyNode.geometry = sphere
        droneCollisionProxyNode.name = "drone_collision_proxy"
        droneCollisionProxyNode.isHidden = true

        let shape = SCNPhysicsShape(
            geometry: sphere,
            options: [SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.boundingBox]
        )
        let body = SCNPhysicsBody(type: .kinematic, shape: shape)
        body.isAffectedByGravity = false
        body.restitution = 0.0
        body.friction = 0.65
        body.categoryBitMask = PhysicsCategory.drone
        body.collisionBitMask = PhysicsCategory.environment
        body.contactTestBitMask = PhysicsCategory.environment
        droneCollisionProxyNode.physicsBody = body

        let proxyCenter = SIMD3<Float>(
            visualBoundsCenter.x,
            max(compactRadius * 1.02, visualBoundsCenter.y),
            visualBoundsCenter.z
        )
        droneCollisionProxyNode.simdPosition = proxyCenter

        droneNode.addChildNode(droneCollisionProxyNode)
    }

    private func configureObstacleCollisionProxies(
        for node: SCNNode,
        descriptor: EnvironmentObjectDescriptor
    ) -> [CollisionObstacle] {
        node.physicsBody = nil
        guard !descriptor.collisionParts.isEmpty else {
            return [configureDefaultObstacleCollisionProxy(for: descriptor)]
        }

        return descriptor.collisionParts
            .map { part in
                let planarOffset = rotatePlanar(
                    SIMD2<Float>(part.localCenter.x, part.localCenter.z),
                    radians: descriptor.yawRadians
                )
                let center = SIMD3<Float>(
                    descriptor.position.x + planarOffset.x,
                    descriptor.position.y + part.localCenter.y,
                    descriptor.position.z + planarOffset.y
                )
                let halfExtents = SIMD2<Float>(
                    max(0.02, part.size.x * 0.5),
                    max(0.02, part.size.z * 0.5)
                )
                return CollisionObstacle(
                    id: part.id,
                    center: center,
                    radius: simd_length(halfExtents),
                    source: part.source,
                    baseY: center.y - part.size.y * 0.5,
                    topY: center.y + part.size.y * 0.5,
                    planarHalfExtents: halfExtents,
                    yawRadians: descriptor.yawRadians + part.yawRadians
                )
            }
    }

    private func configureDefaultObstacleCollisionProxy(
        for descriptor: EnvironmentObjectDescriptor
    ) -> CollisionObstacle {
        let proxy = obstacleProxySpec(for: descriptor)

        return CollisionObstacle(
            id: descriptor.id,
            center: descriptor.position + SIMD3<Float>(0.0, proxy.localCenterY, 0.0),
            radius: proxy.analysisRadius,
            source: proxy.source,
            baseY: descriptor.position.y + proxy.baseY,
            topY: descriptor.position.y + proxy.topY
        )
    }

    private func obstacleProxySpec(for descriptor: EnvironmentObjectDescriptor) -> ObstacleProxySpec {
        switch descriptor.kind {
        case .tree:
            let canopyWidth = max(2.4, descriptor.size.x * 1.18)
            let canopyDepth = max(2.4, descriptor.size.z * 1.18)
            let canopyHeight = max(3.0, descriptor.size.y * 0.42)
            let canopyBaseY = max(2.2, descriptor.size.y * 0.42)
            return ObstacleProxySpec(
                localCenterY: canopyBaseY + canopyHeight * 0.5,
                analysisRadius: max(canopyWidth, canopyDepth) * 0.46,
                source: "tree.canopy",
                baseY: canopyBaseY,
                topY: canopyBaseY + canopyHeight
            )

        case .building:
            let width = max(4.0, descriptor.size.x)
            let depth = max(4.0, descriptor.size.z)
            let height = max(6.0, descriptor.size.y)
            return ObstacleProxySpec(
                localCenterY: height * 0.5,
                analysisRadius: max(width, depth) * 0.5,
                source: "building.box",
                baseY: 0.0,
                topY: height
            )

        case .crate:
            let width = max(0.8, descriptor.size.x)
            let depth = max(0.8, descriptor.size.z)
            let height = max(0.8, descriptor.size.y)
            return ObstacleProxySpec(
                localCenterY: height * 0.5,
                analysisRadius: max(width, depth) * 0.5,
                source: "crate.box",
                baseY: 0.0,
                topY: height
            )

        case .cargoContainer:
            let width = max(1.6, descriptor.size.x)
            let depth = max(1.6, descriptor.size.z)
            let height = max(1.8, descriptor.size.y)
            return ObstacleProxySpec(
                localCenterY: height * 0.5,
                analysisRadius: max(width, depth) * 0.5,
                source: "container.fallback",
                baseY: 0.0,
                topY: height
            )

        case .pole:
            let capRadius = max(0.16, descriptor.size.x * 0.22)
            let height = max(4.0, descriptor.size.y)
            return ObstacleProxySpec(
                localCenterY: height * 0.5,
                analysisRadius: max(0.22, capRadius * 1.12),
                source: "pole.capsule",
                baseY: 0.0,
                topY: height
            )

        case .rock:
            let radius = max(0.45, max(descriptor.size.x, descriptor.size.z) * 0.42)
            return ObstacleProxySpec(
                localCenterY: max(0.24, descriptor.size.y * 0.45),
                analysisRadius: radius,
                source: "rock.sphere",
                baseY: 0.0,
                topY: max(descriptor.size.y, radius * 1.6)
            )

        case .marker:
            let radius = max(0.30, descriptor.size.x * 0.45)
            let height = max(0.8, descriptor.size.y)
            return ObstacleProxySpec(
                localCenterY: height * 0.5,
                analysisRadius: max(radius, height * 0.20),
                source: "marker.cone",
                baseY: 0.0,
                topY: height
            )
        }
    }

    private func supportSurfaceDescriptors(
        for descriptor: EnvironmentObjectDescriptor
    ) -> [SupportSurfaceDescriptor] {
        if !descriptor.collisionParts.isEmpty {
            return descriptor.collisionParts.compactMap { part in
                guard part.supportsLanding else {
                    return nil
                }
                let offset = rotatePlanar(
                    SIMD2<Float>(part.localCenter.x, part.localCenter.z),
                    radians: descriptor.yawRadians
                )
                return SupportSurfaceDescriptor(
                    center: SIMD2<Float>(
                        descriptor.position.x + offset.x,
                        descriptor.position.z + offset.y
                    ),
                    halfExtents: SIMD2<Float>(
                        part.size.x * 0.5,
                        part.size.z * 0.5
                    ),
                    yawRadians: descriptor.yawRadians + part.yawRadians,
                    topY: descriptor.position.y + part.localCenter.y + part.size.y * 0.5,
                    source: part.source
                )
            }
        }

        switch descriptor.kind {
        case .building:
            let width = max(6.0, descriptor.size.x) * 0.50
            let depth = max(6.0, descriptor.size.z) * 0.50
            let height = max(6.0, descriptor.size.y)
            return [SupportSurfaceDescriptor(
                center: SIMD2<Float>(descriptor.position.x, descriptor.position.z),
                halfExtents: SIMD2<Float>(width * 1.02, depth * 1.02),
                yawRadians: descriptor.yawRadians,
                topY: descriptor.position.y + height,
                source: "abandonedBuilding.bounds"
            )]

        case .crate:
            return [SupportSurfaceDescriptor(
                center: SIMD2<Float>(descriptor.position.x, descriptor.position.z),
                halfExtents: SIMD2<Float>(descriptor.size.x * 0.52, descriptor.size.z * 0.52),
                yawRadians: descriptor.yawRadians,
                topY: descriptor.position.y + descriptor.size.y,
                source: "crate.top"
            )]

        case .tree, .pole, .cargoContainer, .rock, .marker:
            return []
        }
    }

    // Matches SceneKit's actual eulerAngles.y rotation direction (verified empirically: a
    // child at local +X ends up at world -Z under a +90° parent rotation). The textbook 2D
    // rotation matrix [[cos,-sin],[sin,cos]] turns out to spin the opposite way once X/Z are
    // mapped onto SceneKit's right-handed, Y-up axes — this previously meant collision parts
    // were mirrored relative to the visual model for any non-zero descriptor.yawRadians.
    private func rotatePlanar(
        _ value: SIMD2<Float>,
        radians: Float
    ) -> SIMD2<Float> {
        let cosine = cos(radians)
        let sine = sin(radians)
        return SIMD2<Float>(
            value.x * cosine + value.y * sine,
            -value.x * sine + value.y * cosine
        )
    }

    private func removeExistingCityRoots(from root: SCNNode) -> CityCleanupStats {
        var targets: [SCNNode] = []
        collectCityRoots(in: root, targets: &targets)
        let nodeCount = targets.reduce(0) { $0 + subtreeNodeCount(for: $1) }
        targets.forEach { $0.removeFromParentNode() }
        return CityCleanupStats(rootCount: targets.count, nodeCount: nodeCount)
    }

    private func collectCityRoots(in node: SCNNode, targets: inout [SCNNode]) {
        for child in node.childNodes {
            if shouldRemoveCityRoot(named: child.name) {
                targets.append(child)
            } else {
                collectCityRoots(in: child, targets: &targets)
            }
        }
    }

    private func shouldRemoveCityRoot(named name: String?) -> Bool {
        guard let name else { return false }
        if name.hasPrefix("environment.city.") || name.hasPrefix("environment.urban.") {
            return true
        }

        return [
            "environment.city.root",
            "environment.urban.root",
            AbandonedCitySceneComposer.rootName,
            "cityRoot",
            "urbanRoot",
            "oldCityDebugRoot",
            "proceduralCityRoot",
            "roadRoot",
            "sidewalkRoot",
            "blockRoot",
            "buildingRoot",
            "debugCityRoot"
        ].contains(name)
    }

    private func subtreeNodeCount(for node: SCNNode) -> Int {
        1 + node.childNodes.reduce(0) { $0 + subtreeNodeCount(for: $1) }
    }

    private func hasCityRootInstalled(in node: SCNNode) -> Bool {
        if shouldRemoveCityRoot(named: node.name) {
            return true
        }

        for child in node.childNodes where hasCityRootInstalled(in: child) {
            return true
        }
        return false
    }

    private func printCityGenerationDiagnostics(descriptors: [EnvironmentObjectDescriptor]) {
        guard let cityRoot = findFirstNode(named: AbandonedCitySceneComposer.rootName, in: scene.rootNode) else {
            #if DEBUG
            print("[City] generated map=city buildings=0 roads=0 decorations=0 totalNodes=0 materials=0 memoryMode=legacy-disabled")
            #endif
            return
        }

        let buildings = descriptors.filter { $0.kind == .building }.count
        let totalNodes = subtreeNodeCount(for: cityRoot)
        let materials = uniqueMaterialCount(in: cityRoot)
        #if DEBUG
        print(
            "[City] generated map=city buildings=\(buildings) roads=0 decorations=0 " +
            "totalNodes=\(totalNodes) materials=\(materials) memoryMode=legacy-disabled"
        )
        #endif
    }

    private func findFirstNode(named targetName: String, in node: SCNNode) -> SCNNode? {
        if node.name == targetName {
            return node
        }

        for child in node.childNodes {
            if let match = findFirstNode(named: targetName, in: child) {
                return match
            }
        }
        return nil
    }

    private func uniqueMaterialCount(in node: SCNNode) -> Int {
        var identities = Set<ObjectIdentifier>()
        collectMaterials(in: node, identities: &identities)
        return identities.count
    }

    private func collectMaterials(in node: SCNNode, identities: inout Set<ObjectIdentifier>) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                identities.insert(ObjectIdentifier(material))
            }
        }

        for child in node.childNodes {
            collectMaterials(in: child, identities: &identities)
        }
    }

    private func planarPoint(
        _ point: SIMD2<Float>,
        intersects surface: SupportSurfaceDescriptor,
        clearanceRadius: Float
    ) -> Bool {
        let delta = point - surface.center
        let cosine = cos(-surface.yawRadians)
        let sine = sin(-surface.yawRadians)
        let local = SIMD2<Float>(
            delta.x * cosine - delta.y * sine,
            delta.x * sine + delta.y * cosine
        )
        return abs(local.x) <= surface.halfExtents.x + clearanceRadius &&
            abs(local.y) <= surface.halfExtents.y + clearanceRadius
    }

    private func applyComponentOverlays(damage: DamageState, thermal: ThermalState, mode: DiagnosticOverlayMode) {
        let signature = componentOverlaySignature(damage: damage, thermal: thermal, mode: mode)
        if lastComponentOverlaySignature == signature {
            return
        }
        lastComponentOverlaySignature = signature

        let fpvHidden: Set<DamageComponent> = [
            .propellerFL, .propellerFR, .propellerRL, .propellerRR,
            .motorFL, .motorFR,
            .armFL, .armFR
        ]

        for component in DamageComponent.allCases {
            let nodes = componentNodes[component] ?? []
            let selected = damage.selectedComponent == component

            for node in nodes {
                let hiddenByDamage = damage.hiddenComponents.contains(component)
                let hiddenBySelectiveFPV = fpvObstructionHidingActive && fpvHidden.contains(component)
                let hidden = hiddenByDamage || hiddenBySelectiveFPV
                node.isHidden = hidden

                switch mode {
                case .normal:
                    if selected {
                        applyEmission(on: node, color: NSColor.systemCyan.withAlphaComponent(0.78))
                    } else {
                        clearEmission(on: node)
                    }
                case .thermal:
                    let color = temperatureColor(thermal.temperature(for: component), selected: selected)
                    applyEmission(on: node, color: color)
                case .damage:
                    let warning = damage.warningState(for: component, temperature: thermal.temperature(for: component))
                    let color = warningColor(warning, selected: selected)
                    applyEmission(on: node, color: color)
                }
            }
        }
    }

    private func applyPayloadFPVPresentation() {
        let useFPVPresentation = fpvPresentationActive
        fpvPayloadPresentationNode.isHidden = !useFPVPresentation || fpvPayloadPresentationNode.childNodes.isEmpty

        guard let payloadVisualNode else {
            return
        }

        let useFPVProxy = useFPVPresentation
        if let standardPresentation = payloadVisualNode.childNode(withName: "payloadStandardPresentationNode", recursively: false),
           let fpvProxyPresentation = payloadVisualNode.childNode(withName: "payloadFPVProxyNode", recursively: false) {
            standardPresentation.isHidden = useFPVProxy
            fpvProxyPresentation.isHidden = !useFPVProxy
            payloadVisualNode.isHidden = false
        } else {
            payloadVisualNode.isHidden = useFPVProxy
        }
    }

    private func installFPVPayloadPresentation(from payloadVisualNode: SCNNode) {
        resetFPVPayloadPresentation()

        let proxySource = payloadVisualNode.childNode(withName: "payloadFPVProxyNode", recursively: false) ?? payloadVisualNode
        let proxyNode = proxySource.clone()
        proxyNode.name = "fpvDetachedPayloadProxyNode"
        proxyNode.isHidden = false
        fpvPayloadPresentationNode.addChildNode(proxyNode)
    }

    private func resetFPVPayloadPresentation() {
        for child in fpvPayloadPresentationNode.childNodes {
            child.removeFromParentNode()
        }
        fpvPayloadPresentationNode.isHidden = true
        fpvPayloadPresentationNode.simdPosition = .zero
    }

    private func updateFPVPayloadPresentationPose(bodyForward: SIMD3<Float>, subjectScale: Float) {
        guard fpvPayloadPresentationNode.childNodes.isEmpty == false else {
            return
        }

        let forwardOffset = bodyForward * max(0.022, min(0.080, subjectScale * 0.14))
        let verticalOffset = SIMD3<Float>(0.0, -max(0.055, min(0.16, subjectScale * 0.18)), 0.0)
        let aftBias = -bodyForward * max(0.008, min(0.030, subjectScale * 0.05))
        fpvPayloadPresentationNode.simdPosition = forwardOffset + verticalOffset + aftBias
    }

    private func applyEmission(on node: SCNNode, color: NSColor) {
        if let geometry = node.geometry {
            geometry.materials.forEach { $0.emission.contents = color }
        }
        for child in node.childNodes {
            applyEmission(on: child, color: color)
        }
    }

    private func clearEmission(on node: SCNNode) {
        applyEmission(on: node, color: .clear)
    }

    private func applyCategoryBitMask(_ mask: Int, to node: SCNNode) {
        node.categoryBitMask = mask
        for child in node.childNodes {
            applyCategoryBitMask(mask, to: child)
        }
    }

    private func warningColor(_ state: ComponentWarningState, selected: Bool) -> NSColor {
        let base: NSColor
        switch state {
        case .nominal:
            base = NSColor.systemGreen.withAlphaComponent(0.32)
        case .warning:
            base = NSColor.systemYellow.withAlphaComponent(0.52)
        case .critical:
            base = NSColor.systemRed.withAlphaComponent(0.72)
        }

        if selected {
            return base.blended(withFraction: 0.42, of: .systemCyan) ?? base
        }
        return base
    }

    private func temperatureColor(_ temperature: Float, selected: Bool) -> NSColor {
        let t = ((temperature - 28.0) / 65.0).clamped(to: 0.0...1.0)
        let red = CGFloat(t)
        let blue = CGFloat(1.0 - t)
        let green = CGFloat(max(0.0, 1.0 - abs(t - 0.52) * 2.0))
        let alpha: CGFloat = selected ? 0.84 : 0.66
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func updateWeatherParticles(_ weather: WeatherModel) {
        let intensity = weather.normalizedIntensity

        if weather.preset == .rain || weather.preset == .thunderstorm {
            if rainSystem == nil {
                rainSystem = makeRainSystem()
                weatherNode.addParticleSystem(rainSystem!)
            }
            let rate = CGFloat(260 + 2100 * intensity)
            rainSystem?.birthRate = rate
            rainSystem?.particleVelocity = CGFloat(18 + 24 * intensity)
            rainSystem?.acceleration = SCNVector3(
                weather.windVector.x * 1.6,
                -34.0,
                weather.windVector.z * 1.6
            )
        } else if let rainSystem {
            weatherNode.removeParticleSystem(rainSystem)
            self.rainSystem = nil
        }

        if weather.preset == .snow {
            if snowSystem == nil {
                snowSystem = makeSnowSystem()
                weatherNode.addParticleSystem(snowSystem!)
            }
            let rate = CGFloat(120 + 780 * intensity)
            snowSystem?.birthRate = rate
            snowSystem?.particleVelocity = CGFloat(4.0 + 4.5 * intensity)
            snowSystem?.acceleration = SCNVector3(
                weather.windVector.x * 0.9,
                -6.0,
                weather.windVector.z * 0.9
            )
        } else if let snowSystem {
            weatherNode.removeParticleSystem(snowSystem)
            self.snowSystem = nil
        }
    }

    private func updateWeatherAnimation(deltaTime: Float, weather: WeatherModel) {
        var baseSun = CGFloat(1200 * (0.65 + weather.effectiveFactors.visibilityFactor * 0.5))

        if weather.preset == .thunderstorm {
            // effectiveFactors.visibilityFactor interpolates *from* 1.0 at intensity 0, so at the
            // moment the preset is picked (before any slider is touched) it's identical to clear
            // weather's brightness — same non-zero-floor fix as everywhere else, applied directly
            // to the sun instead of through that shared interpolation (which also drives
            // gameplay-tuning factors like drag/collision risk that shouldn't jump just because
            // the preset was selected).
            // Raised from 0.50-0.30*intensity — that range pushed full-intensity brightness down
            // to ~14% of clear weather, dark enough that the ground/trees read as literal night
            // rather than an overcast day. This keeps it dim but still day-lit at any intensity.
            let dimFloor = CGFloat(0.62 - weather.normalizedIntensity * 0.28)
            baseSun *= dimFloor

            // A thick overcast deck scatters direct sunlight, so real storm-day shadows are soft
            // and faint rather than the hard, crisp-edged shadows clear weather casts — the user
            // pointed out the shadows in a screenshot still looked just as sharp as clear weather.
            // Same non-zero floor as everywhere else: noticeably softened the moment the preset
            // is picked, softer still as intensity rises.
            let softness = CGFloat(0.55 + weather.normalizedIntensity * 0.45)
            sunLightNode.light?.shadowRadius = Self.clearWeatherShadowRadius + softness * 14.0
            sunLightNode.light?.shadowColor = NSColor.black.withAlphaComponent(Self.clearWeatherShadowAlpha * (1.0 - softness * 0.65))
        } else {
            sunLightNode.light?.shadowRadius = Self.clearWeatherShadowRadius
            sunLightNode.light?.shadowColor = NSColor.black.withAlphaComponent(Self.clearWeatherShadowAlpha)
        }

        // Lightning used to also jolt sunLightNode.light.intensity here on a 0.6-2.2s random
        // pulse — a full-screen brightness spike on every flash. The user explicitly found that
        // unpleasant ("резкие вспышки на экране... не по себе от этого"), so strikes are now a
        // real 3D event instead: see `triggerLightningStrike`, scheduled minutes apart by the
        // view model, with its own small localized light that never touches the global sun.
        sunLightNode.light?.intensity = baseSun
    }

    private func applyPayloadOpticsShadowQuality(isActive: Bool, weather: WeatherModel) {
        guard let light = sunLightNode.light else {
            return
        }

        if isActive {
            let projection = payloadOpticsShadowProjection()

            light.castsShadow = true
            light.automaticallyAdjustsShadowProjection = false
            light.maximumShadowDistance = CameraClipping.payloadOpticsFar
            light.sampleDistributedShadowMaps = false
            light.shadowCascadeCount = 1
            light.shadowCascadeSplittingFactor = 0.15
            light.shadowMapSize = CGSize(width: 4096, height: 4096)
            light.shadowSampleCount = 32
            light.shadowBias = 0.62
            light.zNear = 1
            light.zFar = CameraClipping.payloadOpticsFar + 500
            light.orthographicScale = projection.scale
            sunLightNode.simdPosition = projection.lightPosition

            switch weather.preset {
            case .thunderstorm:
                light.shadowRadius = 7.0
                light.shadowColor = NSColor.black.withAlphaComponent(0.20)
            case .fog, .smog, .snow:
                light.shadowRadius = 4.5
                light.shadowColor = NSColor.black.withAlphaComponent(0.24)
            case .rain:
                light.shadowRadius = 3.4
                light.shadowColor = NSColor.black.withAlphaComponent(0.28)
            case .normal, .wind:
                light.shadowRadius = 1.6
                light.shadowColor = NSColor.black.withAlphaComponent(0.42)
            }

            payloadOpticsShadowQualityActive = true
            return
        }

        guard payloadOpticsShadowQualityActive else {
            return
        }

        light.automaticallyAdjustsShadowProjection = true
        light.maximumShadowDistance = 100
        light.sampleDistributedShadowMaps = false
        light.shadowCascadeCount = 1
        light.shadowCascadeSplittingFactor = 0.15
        light.shadowMapSize = CGSize(width: 1536, height: 1536)
        light.shadowSampleCount = 12
        light.shadowBias = 1.0
        light.zNear = 1
        light.zFar = 100
        light.orthographicScale = 1
        sunLightNode.position = defaultSunLightPosition

        if weather.preset == .thunderstorm {
            let softness = CGFloat(0.55 + weather.normalizedIntensity * 0.45)
            light.shadowRadius = Self.clearWeatherShadowRadius + softness * 14.0
            light.shadowColor = NSColor.black.withAlphaComponent(Self.clearWeatherShadowAlpha * (1.0 - softness * 0.65))
        } else {
            light.shadowRadius = Self.clearWeatherShadowRadius
            light.shadowColor = NSColor.black.withAlphaComponent(Self.clearWeatherShadowAlpha)
        }

        payloadOpticsShadowQualityActive = false
    }

    private func payloadOpticsShadowProjection() -> (lightPosition: SIMD3<Float>, scale: CGFloat) {
        guard let payloadCameraNode else {
            return (sunLightNode.simdPosition, 420)
        }

        let cameraTransform = payloadCameraNode.presentation.simdWorldTransform
        let cameraPosition = payloadCameraNode.presentation.simdWorldPosition
        let cameraForward = simd_normalize(simd_act(
            simd_quatf(cameraTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        let safeForward = simd_length_squared(cameraForward) > 0.0001
            ? cameraForward
            : SIMD3<Float>(0.0, -0.18, -0.98)

        let targetDistance = Float(
            payloadCameraOpticsState.targetDistanceMeters
            ?? payloadCameraOpticsState.focusDistanceMeters
        ).clamped(to: 80.0...720.0)
        let fovRadians = Float(payloadCameraOpticsState.currentFieldOfViewDegrees)
            .clamped(to: 1.0...55.0)
            .degreesToRadians
        let frameWidthAtTarget = tan(fovRadians * 0.5) * targetDistance * 2.0
        let shadowScale = CGFloat((frameWidthAtTarget * 2.8 + 140.0).clamped(to: 180.0...920.0))

        var focusPoint = cameraPosition + safeForward * targetDistance
        let texelSize = Float(shadowScale) / 4096.0
        if texelSize > 0.0001 {
            focusPoint.x = (focusPoint.x / texelSize).rounded() * texelSize
            focusPoint.y = (focusPoint.y / texelSize).rounded() * texelSize
            focusPoint.z = (focusPoint.z / texelSize).rounded() * texelSize
        }

        let lightDirection = simd_normalize(simd_act(
            simd_quatf(sunLightNode.presentation.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        let safeLightDirection = simd_length_squared(lightDirection) > 0.0001
            ? lightDirection
            : simd_normalize(SIMD3<Float>(-0.58, -0.66, -0.47))
        return (focusPoint - safeLightDirection * 760.0, shadowScale)
    }

    // Mirrors SceneFactory.makeDirectionalLightNode's defaults — kept here so updateWeatherAnimation
    // can restore them exactly when leaving thunderstorm, instead of hardcoding the same numbers twice.
    private static let clearWeatherShadowRadius: CGFloat = 1.0
    private static let clearWeatherShadowAlpha: CGFloat = 0.26

    // Container for transient lightning-bolt nodes spawned by `triggerLightningStrike` — kept
    // separate from `stormCloudsNode` since bolts are short-lived one-shots (each removes itself
    // via SCNAction when its flash finishes), not a persistent, toggled-by-preset visual.
    private func setUpLightningStrikes() {
        lightningStrikesNode.name = "lightningStrikesNode"
        scene.rootNode.addChildNode(lightningStrikesNode)
    }

    /// Spawns one of the 3 bolt variants at `impactPosition` (its base; `boltHeight` is how far
    /// it extends straight up from there), flashes briefly, and removes itself — no per-frame
    /// view-model bookkeeping needed for cleanup. The accompanying light is a child of the bolt
    /// node, short-range (`attenuationEndDistance`) and short-lived (removed along with the bolt
    /// when its action sequence finishes) — deliberately NOT `sunLightNode`, so this never
    /// produces the disliked full-screen brightness spike; it only lights up the immediate area
    /// around the strike, the same way a real nearby lightning flash would.
    func triggerLightningStrike(impactPosition: SCNVector3, boltHeight: Float) {
        guard let bolt = WeatherCloudAssetLoader.shared.makeLightningBoltNode(targetHeight: boltHeight) else {
            return
        }
        bolt.position = impactPosition
        bolt.opacity = 0.0
        lightningStrikesNode.addChildNode(bolt)

        let flashLight = SCNLight()
        flashLight.type = .omni
        flashLight.color = NSColor(calibratedRed: 0.80, green: 0.84, blue: 1.0, alpha: 1.0)
        flashLight.intensity = 4500
        flashLight.attenuationStartDistance = 4
        flashLight.attenuationEndDistance = 50
        let flashLightNode = SCNNode()
        flashLightNode.light = flashLight
        flashLightNode.position = SCNVector3(0, boltHeight * 0.3, 0)
        bolt.addChildNode(flashLightNode)

        let appear = SCNAction.fadeIn(duration: 0.035)
        let hold = SCNAction.wait(duration: Double.random(in: 0.06...0.12))
        let fade = SCNAction.fadeOut(duration: 0.22)
        let remove = SCNAction.removeFromParentNode()
        bolt.runAction(.sequence([appear, hold, fade, remove]))
    }

    private func ensureCollisionDebugMarkers() {
        guard obstacleDebugProxyNodes.isEmpty else {
            return
        }

        for obstacle in environmentObstacles {
            let marker: SCNNode
            if let halfExtents = obstacle.planarHalfExtents {
                marker = SCNNode(geometry: SCNBox(
                    width: CGFloat(halfExtents.x * 2.0),
                    height: CGFloat(max(0.04, obstacle.topY - obstacle.baseY)),
                    length: CGFloat(halfExtents.y * 2.0),
                    chamferRadius: 0.0
                ))
                marker.position = SCNVector3(
                    obstacle.center.x,
                    (obstacle.baseY + obstacle.topY) * 0.5,
                    obstacle.center.z
                )
                marker.eulerAngles.y = CGFloat(obstacle.yawRadians)
            } else {
                marker = SCNNode(geometry: SCNSphere(radius: CGFloat(obstacle.radius)))
                marker.position = SCNVector3(
                    obstacle.center.x,
                    obstacle.center.y,
                    obstacle.center.z
                )
            }
            marker.name = "debug_obstacle_\(obstacle.id.uuidString)"
            marker.geometry?.firstMaterial?.diffuse.contents = NSColor.systemYellow.withAlphaComponent(0.42)
            marker.geometry?.firstMaterial?.fillMode = .lines
            marker.geometry?.firstMaterial?.lightingModel = .constant
            marker.geometry?.firstMaterial?.readsFromDepthBuffer = false
            collisionDebugNode.addChildNode(marker)
            obstacleDebugProxyNodes[obstacle.id] = marker
        }
    }

    private func weatherVisualSignature(_ weather: WeatherModel) -> Int {
        var hasher = Hasher()
        hasher.combine(weather.preset.rawValue)
        hasher.combine(weather.intensity.bitPattern)
        hasher.combine(weather.windDirectionDeg.bitPattern)
        hasher.combine(weather.windSpeedMps.bitPattern)
        hasher.combine(weather.gusts.bitPattern)
        return hasher.finalize()
    }

    private func componentOverlaySignature(
        damage: DamageState,
        thermal: ThermalState,
        mode: DiagnosticOverlayMode
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(mode.rawValue)
        hasher.combine(fpvObstructionHidingActive)
        hasher.combine(damage.selectedComponent?.rawValue ?? "none")

        for component in DamageComponent.allCases {
            hasher.combine(damage.hiddenComponents.contains(component))

            switch mode {
            case .normal:
                break
            case .thermal:
                hasher.combine(Int((thermal.temperature(for: component) * 2.0).rounded()))
            case .damage:
                hasher.combine(damage.warningState(for: component, temperature: thermal.temperature(for: component)).rawValue)
            }
        }

        return hasher.finalize()
    }

    private func makeRainSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedWhite: 0.85, alpha: 0.55)
        system.particleSize = 0.018
        system.birthRate = 0
        system.particleLifeSpan = 2.2
        system.particleLifeSpanVariation = 0.6
        system.emitterShape = SCNBox(width: 260, height: 1, length: 260, chamferRadius: 0)
        system.spreadingAngle = 2
        system.particleVelocity = 22
        system.particleVelocityVariation = 4
        system.acceleration = SCNVector3(0, -32, 0)
        system.isAffectedByGravity = false
        system.loops = true
        weatherNode.position = SCNVector3(0, 45, 0)
        return system
    }

    private func makeSnowSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedWhite: 0.95, alpha: 0.9)
        system.particleSize = 0.042
        system.birthRate = 0
        system.particleLifeSpan = 8.0
        system.particleLifeSpanVariation = 2.0
        system.emitterShape = SCNBox(width: 260, height: 1, length: 260, chamferRadius: 0)
        system.spreadingAngle = 8
        system.particleVelocity = 5.0
        system.particleVelocityVariation = 1.6
        system.acceleration = SCNVector3(0, -6.0, 0)
        system.isAffectedByGravity = false
        system.loops = true
        weatherNode.position = SCNVector3(0, 45, 0)
        return system
    }

    private func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
        let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1, 0, 0))
        let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0, 0, 1))
        return yaw * pitch * roll
    }
}

private extension Float {
    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

private struct TerrainDetailSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEAD_BEEF : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}
