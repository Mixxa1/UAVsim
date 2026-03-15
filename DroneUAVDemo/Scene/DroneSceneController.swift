import AppKit
import SceneKit
import simd

private struct WingmanVisual {
    var rootNode: SCNNode
    var propellerNodes: [SCNNode]
    var spinDirections: [Float]
    var spinAngles: [Float]
}

final class DroneSceneController {
    let scene: SCNScene

    private let freeCameraNode: SCNNode
    private let followCameraNode = SCNNode()
    private let fpvYawNode = SCNNode()
    private let fpvPitchNode = SCNNode()
    private let fpvCameraNode = SCNNode()
    private let orbitCameraNode = SCNNode()
    private let topCameraNode = SCNNode()

    private let sunLightNode: SCNNode
    private let gridNode: SCNNode
    private let axesNode: SCNNode
    private let groundNode: SCNNode
    private let worldBoundsNode = SCNNode()
    private let dockStationNode = SCNNode()

    private let weatherNode = SCNNode()
    private var rainSystem: SCNParticleSystem?
    private var snowSystem: SCNParticleSystem?
    private var thunderPulse: Float = 0.0
    private var cameraNoisePhase: Float = 0.0

    private let scenePopulationService: ScenePopulationService

    private var droneNode: SCNNode
    private var fpvAnchorNode: SCNNode
    private var propellerNodes: [SCNNode]
    private var spinDirections: [Float]
    private var spinAngles: [Float]
    private var componentNodes: [DamageComponent: [SCNNode]]
    private let droneCollisionProxyNode = SCNNode()
    private var droneCollisionProxyRadius: Float = 0.18
    private var fpvObstructionHidingActive: Bool = false

    private var obstacleMap: [UUID: SCNNode] = [:]
    private(set) var environmentObstacles: [CollisionObstacle] = []
    private var dynamicObstacleCenters: [UUID: SIMD3<Float>] = [:]
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

    private struct SupplementalCollisionObstacle {
        let obstacle: CollisionObstacle
        let highlightNode: SCNNode?
    }

    private enum PhysicsCategory {
        static let environment = 1 << 1
        static let drone = 1 << 2
    }

    private var freeLookAngles = SIMD2<Float>(repeating: 0.0)   // yaw, pitch
    private var followLookAngles = SIMD2<Float>(repeating: 0.0) // yaw, pitch
    private var orbitLookAngles = SIMD2<Float>(repeating: 0.0)  // yaw, pitch
    private var fpvLookAngles = SIMD2<Float>(repeating: 0.0)    // yaw, pitch
    private var topLookAngles = SIMD2<Float>(repeating: 0.0)    // yaw, pitch

    private var orbitAngle: Float = 0.0
    private var activeProfile: DroneModelProfile
    private var currentWeather: WeatherModel = .normal
    private(set) var dockSpawnPosition = SIMD3<Float>(0.0, 0.0, 0.0)
    private let dockDeckSurfaceHeight: Float = 0.037

    init(initialProfile: DroneModelProfile) {
        self.activeProfile = initialProfile

        let setup = SceneFactory.makeScene()
        self.scene = setup.scene
        self.freeCameraNode = setup.cameraNode
        self.sunLightNode = setup.sunLightNode
        self.gridNode = setup.gridNode
        self.axesNode = setup.axesNode
        self.groundNode = setup.groundNode

        let droneVisual = DroneModelBuilder.build(profile: initialProfile)
        self.droneNode = droneVisual.rootNode
        self.fpvAnchorNode = droneVisual.fpvAnchorNode
        self.propellerNodes = droneVisual.propellerNodes
        self.spinDirections = droneVisual.propellerSpinDirections
        self.spinAngles = Array(repeating: 0.0, count: droneVisual.propellerNodes.count)
        self.componentNodes = droneVisual.componentNodes

        scene.rootNode.addChildNode(droneNode)

        self.scenePopulationService = ScenePopulationService(rootNode: scene.rootNode)
        configureDroneCollisionProxy(for: initialProfile)

        configureCameraNode(followCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(fpvCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(orbitCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(topCameraNode, fov: initialProfile.cameraPreset.fpvFov)

        scene.rootNode.addChildNode(followCameraNode)
        scene.rootNode.addChildNode(orbitCameraNode)
        scene.rootNode.addChildNode(topCameraNode)

        fpvYawNode.name = "fpvYawMount"
        fpvPitchNode.name = "fpvPitchMount"
        fpvYawNode.addChildNode(fpvPitchNode)
        fpvPitchNode.addChildNode(fpvCameraNode)
        fpvAnchorNode.addChildNode(fpvYawNode)

        weatherNode.name = "weatherNode"
        scene.rootNode.addChildNode(weatherNode)

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
        applyTerrainVisualStyle(TerrainConfiguration.default.preset)
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
        }
    }

    func currentDockSpawnPoint() -> SIMD3<Float> {
        dockSpawnPosition
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
        case .follow:
            followLookAngles.x += yawDelta
            followLookAngles.y = (followLookAngles.y + pitchDelta).clamped(to: -0.72...0.72)
        case .orbit:
            orbitLookAngles.x += yawDelta
            orbitLookAngles.y = (orbitLookAngles.y + pitchDelta).clamped(to: -0.72...0.72)
        case .fpv:
            fpvLookAngles.x = (fpvLookAngles.x + yawDelta).clamped(to: -0.9...0.9)
            fpvLookAngles.y = (fpvLookAngles.y + pitchDelta).clamped(to: -0.7...0.7)
        case .top:
            topLookAngles.x += yawDelta
            topLookAngles.y = (topLookAngles.y + pitchDelta).clamped(to: -0.35...0.22)
        }
    }

    func resetCameraOrientation(for mode: CameraMode) {
        switch mode {
        case .free:
            freeLookAngles = .zero
        case .follow:
            followLookAngles = .zero
        case .orbit:
            orbitLookAngles = .zero
        case .fpv:
            fpvLookAngles = .zero
        case .top:
            topLookAngles = .zero
        }
    }

    func syncCameraTransition(from oldMode: CameraMode, to newMode: CameraMode) {
        if oldMode == newMode {
            return
        }

        if oldMode == .fpv, newMode != .fpv {
            followLookAngles = .zero
            orbitLookAngles = .zero
            topLookAngles = .zero
            fpvObstructionHidingActive = false
            restoreAfterFPVIfNeeded()
        }

        // Safe external-mode initialization: avoid stale transforms/angles when switching hotkeys.
        switch newMode {
        case .follow:
            followLookAngles = .zero
        case .orbit:
            orbitLookAngles = .zero
        case .top:
            topLookAngles = .zero
        case .free, .fpv:
            break
        }

        switch (oldMode, newMode) {
        case (.follow, .orbit):
            orbitLookAngles = followLookAngles
        case (.orbit, .follow):
            followLookAngles = orbitLookAngles
        default:
            break
        }
    }

    func obstacleSourceLabel(for id: UUID) -> String? {
        obstacleSourceByID[id]
    }

    func sceneDiagnostics() -> (activeObjectCount: Int, activePhysicsBodyCount: Int, activeParticleCount: Int) {
        let objects = obstacleMap.count + wingmanVisuals.count + 1
        var bodyCount = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.physicsBody != nil {
                bodyCount += 1
            }
        }
        let particleCount = Int((rainSystem?.birthRate ?? 0) + (snowSystem?.birthRate ?? 0))
        return (objects, bodyCount, particleCount)
    }

    func dollyFreeCamera(by step: Float) {
        let forward = simd_normalize(simd_act(freeCameraNode.simdOrientation, SIMD3<Float>(0, 0, -1)))
        freeCameraNode.simdPosition += forward * step
    }

    func setDroneProfile(_ profile: DroneModelProfile) {
        activeProfile = profile

        droneNode.removeFromParentNode()

        let droneVisual = DroneModelBuilder.build(profile: profile)
        droneNode = droneVisual.rootNode
        fpvAnchorNode = droneVisual.fpvAnchorNode
        propellerNodes = droneVisual.propellerNodes
        spinDirections = droneVisual.propellerSpinDirections
        componentNodes = droneVisual.componentNodes
        spinAngles = Array(repeating: 0.0, count: propellerNodes.count)
        fpvLookAngles = .zero
        followLookAngles = .zero
        orbitLookAngles = .zero
        topLookAngles = .zero
        lastComponentOverlaySignature = nil

        scene.rootNode.addChildNode(droneNode)
        fpvAnchorNode.addChildNode(fpvYawNode)
        configureDroneCollisionProxy(for: profile)
    }

    func regenerateEnvironment(_ terrain: TerrainConfiguration) {
        let (descriptors, nodesByID) = scenePopulationService.populate(with: terrain)

        obstacleMap = [:]
        obstacleSourceByID = [:]
        var obstacles: [CollisionObstacle] = []
        for descriptor in descriptors where descriptor.isCollidable {
            if let node = nodesByID[descriptor.id] {
                let obstacle = configureObstacleCollisionProxy(for: node, descriptor: descriptor)
                obstacleMap[descriptor.id] = node
                obstacleSourceByID[descriptor.id] = obstacle.source
                obstacles.append(obstacle)
            }
        }

        applyTerrainVisualStyle(terrain.preset)
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
    }

    func applyWeatherVisual(_ weather: WeatherModel) {
        let signature = weatherVisualSignature(weather)
        if lastWeatherVisualSignature == signature {
            return
        }

        lastWeatherVisualSignature = signature
        currentWeather = weather

        let factors = weather.effectiveFactors
        scene.fogStartDistance = CGFloat(32.0 * factors.visibilityFactor + 4.0)
        scene.fogEndDistance = CGFloat(260.0 * factors.visibilityFactor + 24.0)
        scene.fogDensityExponent = CGFloat(0.75 + (1.0 - factors.visibilityFactor) * 2.7)

        let fogColor: NSColor
        switch weather.preset {
        case .rain:
            fogColor = NSColor(calibratedRed: 0.38, green: 0.42, blue: 0.49, alpha: 1.0)
        case .snow:
            fogColor = NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.90, alpha: 1.0)
        case .fog:
            fogColor = NSColor(calibratedWhite: 0.84, alpha: 1.0)
        case .smog:
            fogColor = NSColor(calibratedRed: 0.56, green: 0.54, blue: 0.50, alpha: 1.0)
        case .thunderstorm:
            fogColor = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.29, alpha: 1.0)
        case .wind, .normal:
            fogColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 1.0)
        }

        scene.fogColor = fogColor
        updateWeatherParticles(weather)
    }

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

        fpvObstructionHidingActive = (camera.mode == .fpv) && camera.fpv.hideObstructingParts
        if camera.mode != .fpv {
            droneNode.isHidden = false
            droneNode.opacity = 1.0
        }

        rotatePropellers(state: state, deltaTime: deltaTime)
        applyComponentOverlays(damage: damage, thermal: thermal, mode: diagnosticMode)
        updateCameras(state: state, droneOrientation: droneOrientation, settings: camera, deltaTime: deltaTime)
        updateWeatherAnimation(deltaTime: deltaTime, weather: currentWeather)
    }

    func updateCollisionDebug(risk: CollisionAnalysisSnapshot, enabled: Bool) {
        guard enabled else {
            collisionDebugNode.isHidden = true
            nearestContactNode.isHidden = true
            obstacleMap.values.forEach { clearEmission(on: $0) }
            wingmanVisuals.values.forEach { clearEmission(on: $0.rootNode) }
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

        for (id, node) in obstacleMap {
            if id == nearestID {
                applyEmission(on: node, color: highlightColor)
            } else {
                clearEmission(on: node)
            }
        }

        for (id, visual) in wingmanVisuals {
            if id == nearestID {
                applyEmission(on: visual.rootNode, color: highlightColor)
            } else {
                clearEmission(on: visual.rootNode)
            }
        }

        for (id, marker) in obstacleDebugProxyNodes {
            marker.isHidden = false
            let isNearest = id == nearestID
            marker.geometry?.firstMaterial?.diffuse.contents = isNearest
                ? NSColor.systemRed.withAlphaComponent(0.72)
                : NSColor.systemYellow.withAlphaComponent(0.42)
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
        if let center = dynamicObstacleCenters[id] {
            return center
        }
        return environmentObstacles.first(where: { $0.id == id })?.center
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
            dynamicObstacleCenters[id] = nil
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
            dynamicObstacleCenters[wingman.id] = wingman.position
        }
    }

    private func configureCameraNode(_ node: SCNNode, fov: Float) {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fov)
        camera.zNear = 0.01
        camera.zFar = 900
        node.camera = camera
    }

    private func updateCameras(
        state: DroneState,
        droneOrientation: simd_quatf,
        settings: CameraConfiguration,
        deltaTime: Float
    ) {
        let response: Float
        if deltaTime <= 0.0001 {
            // Snap instantly for mode switches / reset passes where caller uses deltaTime = 0.
            response = 1.0
        } else {
            let blend = (1.0 - settings.smoothing.clamped(to: 0.0...0.95)) * deltaTime * 8.0
            response = blend.clamped(to: 0.05...1.0)
        }

        let dronePos = state.position
        let yawOnly = simd_quatf(angle: state.orientation.z, axis: SIMD3<Float>(0, 1, 0))
        let bodyForward = modelForwardLocal()
        let forward = simd_normalize(simd_act(yawOnly, bodyForward))
        let right = simd_normalize(SIMD3<Float>(forward.z, 0.0, -forward.x))
        let up = SIMD3<Float>(0.0, 1.0, 0.0)

        let dims = activeProfile.dimensions
        let subjectScale = max(activeProfile.collisionRadius * 2.0, max(dims.widthM, dims.lengthM))

        let chaseDistanceRange: ClosedRange<Float>
        let chaseHeightRange: ClosedRange<Float>
        let chaseLeadRange: ClosedRange<Float>
        let anchorLift: Float
        if activeProfile.airframeClass == .fixedWing {
            chaseDistanceRange = max(3.4, subjectScale * 3.0)...max(7.2, subjectScale * 5.6)
            chaseHeightRange = max(0.8, subjectScale * 0.22)...max(2.2, subjectScale * 0.68)
            chaseLeadRange = max(1.3, subjectScale * 0.70)...max(3.4, subjectScale * 1.75)
            anchorLift = max(0.20, subjectScale * 0.10)
        } else {
            chaseDistanceRange = max(1.6, subjectScale * 2.8)...max(3.9, subjectScale * 5.0)
            chaseHeightRange = max(0.36, subjectScale * 0.18)...max(1.35, subjectScale * 0.52)
            chaseLeadRange = max(0.45, subjectScale * 0.55)...max(1.55, subjectScale * 1.55)
            anchorLift = max(0.10, subjectScale * 0.08)
        }

        let chaseDistanceRequested = settings.follow.distance.clamped(to: settings.follow.minDistance...settings.follow.maxDistance)
        let chaseDistance = chaseDistanceRequested.clamped(to: chaseDistanceRange)
        let chaseHeightRequested = settings.follow.height + (activeProfile.airframeClass == .fixedWing ? Float(0.30) : Float(0.14))
        let chaseHeight = chaseHeightRequested.clamped(to: chaseHeightRange)
        let chaseLeadBase = activeProfile.airframeClass == .fixedWing ? Float(2.1) : Float(0.95)
        let chaseLead = chaseLeadBase.clamped(to: chaseLeadRange)
        let chaseAnchor = dronePos + up * anchorLift
        let chaseLeadOffset = forward * chaseLead
        let chaseVerticalOffset = up * max(0.12, subjectScale * 0.14)
        let chaseTarget = chaseAnchor + chaseLeadOffset + chaseVerticalOffset

        var followTargetPos = chaseAnchor - forward * chaseDistance + right * settings.follow.lateralOffset + up * chaseHeight
        followTargetPos.y = max(followTargetPos.y, chaseAnchor.y + max(0.30, subjectScale * 0.28))

        let followResponse = max(response, 0.24)
        followCameraNode.simdPosition = simd_mix(
            followCameraNode.simdPosition,
            followTargetPos,
            SIMD3<Float>(repeating: followResponse)
        )

        let followOrientation = cameraOrientation(
            from: followCameraNode.simdPosition,
            to: chaseTarget,
            yawOffset: followLookAngles.x,
            pitchOffset: followLookAngles.y
        )
        followCameraNode.simdOrientation = simd_normalize(
            simd_slerp(followCameraNode.simdOrientation, followOrientation, followResponse)
        )

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
            yawOffset: orbitLookAngles.x,
            pitchOffset: orbitLookAngles.y
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
        let topPitch = (-Float.pi / 2.0 + topLookAngles.y).clamped(to: -1.54...(-1.08))
        topCameraNode.eulerAngles = SCNVector3(topPitch, topLookAngles.x, 0.0)

        cameraNoisePhase += deltaTime * 5.6
        let shake = settings.fpv.shake.clamped(to: 0.0...0.3)
        let sway = SIMD3<Float>(
            sin(cameraNoisePhase * 2.7) * 0.015 * shake,
            sin(cameraNoisePhase * 1.9 + 0.5) * 0.010 * shake,
            0.0
        )
        // Mount offset z is interpreted as forward distance from anchor; forward differs by airframe class.
        let mountForwardDistance = max(0.018, abs(settings.fpv.mountOffset.z))
        let mountForwardOffset = bodyForward * mountForwardDistance
        let mountLateralOffset = SIMD3<Float>(settings.fpv.mountOffset.x, settings.fpv.mountOffset.y, 0.0)
        fpvPitchNode.simdPosition = mountLateralOffset + mountForwardOffset + sway

        let planarVelocity = SIMD2<Float>(state.velocity.x, state.velocity.z)
        let planarSpeed = simd_length(planarVelocity)
        let velocityYaw: Float
        if planarSpeed > 0.35 {
            if bodyForward.z < 0.0 {
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
        let fpvBaseYaw: Float = activeProfile.airframeClass == .fixedWing ? .pi : 0.0
        fpvYawNode.eulerAngles.y = CGFloat(fpvBaseYaw + relativeYaw + userYaw)

        let gimbalPitch = (-state.velocity.y * 0.05).clamped(
            to: (-settings.fpv.pitchLimitDeg.degreesToRadians)...(settings.fpv.pitchLimitDeg.degreesToRadians)
        )
        let stabilizer = settings.fpv.stabilization.clamped(to: 0.0...1.0)
        let localPitch = (-state.orientation.y * stabilizer * 0.30) + gimbalPitch
        let userPitch = fpvLookAngles.y.clamped(
            to: (-settings.fpv.pitchLimitDeg.degreesToRadians)...(settings.fpv.pitchLimitDeg.degreesToRadians)
        )
        let localRoll = -state.orientation.x * stabilizer * 0.30
        fpvPitchNode.eulerAngles = SCNVector3(localPitch + userPitch, 0.0, localRoll)

        let fov = CGFloat(settings.fov.clamped(to: 30.0...110.0))
        followCameraNode.camera?.fieldOfView = fov
        orbitCameraNode.camera?.fieldOfView = fov
        fpvCameraNode.camera?.fieldOfView = fov
        topCameraNode.camera?.fieldOfView = fov
        freeCameraNode.camera?.fieldOfView = fov
        fpvCameraNode.camera?.zNear = CGFloat(settings.fpv.nearClip.clamped(to: 0.005...0.25))
        topCameraNode.camera?.zNear = 0.03
        freeCameraNode.camera?.zNear = 0.01

        _ = droneOrientation
    }

    private func restoreAfterFPVIfNeeded() {
        droneNode.isHidden = false
        droneNode.opacity = 1.0

        let fpvHidden: Set<DamageComponent> = [
            .propellerFL, .propellerFR, .propellerRL, .propellerRR,
            .armFL, .armFR
        ]
        for component in fpvHidden {
            for node in componentNodes[component] ?? [] {
                node.isHidden = false
            }
        }
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
            return SIMD3<Float>(0.0, 0.0, 1.0)
        }
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

    private func applyTerrainVisualStyle(_ terrain: TerrainPreset) {
        let background: NSColor
        switch terrain {
        case .gridDemo:
            background = NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)
            gridNode.isHidden = false
            axesNode.isHidden = false
        case .field:
            background = NSColor(calibratedRed: 0.22, green: 0.27, blue: 0.20, alpha: 1.0)
            gridNode.isHidden = true
            axesNode.isHidden = true
        case .forest:
            background = NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.12, alpha: 1.0)
            gridNode.isHidden = true
            axesNode.isHidden = true
        case .city:
            background = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
            gridNode.isHidden = true
            axesNode.isHidden = true
        }

        scene.background.contents = background

        if let geometry = groundNode.geometry {
            geometry.materials = [EnvironmentMaterialRegistry.groundMaterial(for: terrain)]
        }
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

        let extent = terrain.worldHalfExtent
        let thickness = max(0.28, extent * 0.008)
        let wallHeight = max(2.2, min(6.8, extent * 0.06))
        let y = wallHeight * 0.5
        let edgeColor = NSColor.systemBlue.withAlphaComponent(0.20)

        let northSouth = SCNBox(
            width: CGFloat(extent * 2.0),
            height: CGFloat(wallHeight),
            length: CGFloat(thickness),
            chamferRadius: 0.0
        )
        northSouth.firstMaterial?.diffuse.contents = edgeColor
        northSouth.firstMaterial?.isDoubleSided = true

        let eastWest = SCNBox(
            width: CGFloat(thickness),
            height: CGFloat(wallHeight),
            length: CGFloat(extent * 2.0),
            chamferRadius: 0.0
        )
        eastWest.firstMaterial?.diffuse.contents = edgeColor
        eastWest.firstMaterial?.isDoubleSided = true

        let north = SCNNode(geometry: northSouth.copy() as? SCNGeometry)
        north.position = SCNVector3(0.0, y, extent)
        north.name = "boundary_north"

        let south = SCNNode(geometry: northSouth.copy() as? SCNGeometry)
        south.position = SCNVector3(0.0, y, -extent)
        south.name = "boundary_south"

        let east = SCNNode(geometry: eastWest.copy() as? SCNGeometry)
        east.position = SCNVector3(extent, y, 0.0)
        east.name = "boundary_east"

        let west = SCNNode(geometry: eastWest.copy() as? SCNGeometry)
        west.position = SCNVector3(-extent, y, 0.0)
        west.name = "boundary_west"

        worldBoundsNode.addChildNode(north)
        worldBoundsNode.addChildNode(south)
        worldBoundsNode.addChildNode(east)
        worldBoundsNode.addChildNode(west)
    }

    private func buildSupplementalCollisionObstacles(for terrain: TerrainConfiguration) -> [SupplementalCollisionObstacle] {
        var entries: [SupplementalCollisionObstacle] = []

        // Model dock hazards as perimeter posts so spawn center stays safe.
        let dockRingRadius: Float = 2.2
        let dockObstacleRadius: Float = 0.46
        let dockHeight: Float = 0.24
        let dockOffsets: [SIMD2<Float>] = [
            SIMD2<Float>( dockRingRadius, 0.0),
            SIMD2<Float>(-dockRingRadius, 0.0),
            SIMD2<Float>(0.0,  dockRingRadius),
            SIMD2<Float>(0.0, -dockRingRadius)
        ]

        for offset in dockOffsets {
            let center = dockSpawnPosition + SIMD3<Float>(offset.x, dockHeight, offset.y)
            entries.append(
                SupplementalCollisionObstacle(
                    obstacle: CollisionObstacle(
                        id: UUID(),
                        center: center,
                        radius: dockObstacleRadius,
                        source: "dock_station"
                    ),
                    highlightNode: dockStationNode
                )
            )
        }

        let extent = terrain.worldHalfExtent
        let wallHeight = max(2.2, min(6.8, extent * 0.06))
        let wallY = wallHeight * 0.5
        let wallRadius = max(2.6, min(6.4, extent * 0.08))
        let boundaryNodes = boundaryHighlightNodesBySource()
        let barrierSourcesAndCenters: [(String, SIMD3<Float>)] = [
            ("barrier_north", SIMD3<Float>(0.0, wallY, extent)),
            ("barrier_south", SIMD3<Float>(0.0, wallY, -extent)),
            ("barrier_east", SIMD3<Float>(extent, wallY, 0.0)),
            ("barrier_west", SIMD3<Float>(-extent, wallY, 0.0))
        ]

        for (source, center) in barrierSourcesAndCenters {
            entries.append(
                SupplementalCollisionObstacle(
                    obstacle: CollisionObstacle(
                        id: UUID(),
                        center: center,
                        radius: wallRadius,
                        source: source
                    ),
                    highlightNode: boundaryNodes[source]
                )
            )
        }

        return entries
    }

    private func boundaryHighlightNodesBySource() -> [String: SCNNode] {
        var result: [String: SCNNode] = [:]
        for node in worldBoundsNode.childNodes {
            switch node.name {
            case "boundary_north":
                result["barrier_north"] = node
            case "boundary_south":
                result["barrier_south"] = node
            case "boundary_east":
                result["barrier_east"] = node
            case "boundary_west":
                result["barrier_west"] = node
            default:
                break
            }
        }
        return result
    }

    private func configureDroneCollisionProxy(for profile: DroneModelProfile) {
        droneCollisionProxyNode.removeFromParentNode()

        let compactRadius = max(0.08, profile.collisionRadius * 0.78)
        droneCollisionProxyRadius = compactRadius

        let sphere = SCNSphere(radius: CGFloat(compactRadius))
        sphere.firstMaterial?.diffuse.contents = NSColor.clear
        sphere.firstMaterial?.lightingModel = .constant
        droneCollisionProxyNode.geometry = sphere
        droneCollisionProxyNode.position = SCNVector3(0.0, compactRadius * 0.92, 0.0)
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

        droneNode.addChildNode(droneCollisionProxyNode)
    }

    private func configureObstacleCollisionProxy(for node: SCNNode, descriptor: EnvironmentObjectDescriptor) -> CollisionObstacle {
        let proxy = obstacleProxySpec(for: descriptor)
        let proxyNode = SCNNode(geometry: proxy.geometry)
        proxyNode.position = SCNVector3(0.0, proxy.localCenterY, 0.0)
        let shape = SCNPhysicsShape(
            node: proxyNode,
            options: [
                SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.boundingBox
            ]
        )

        let body = SCNPhysicsBody(type: .static, shape: shape)
        body.isAffectedByGravity = false
        body.restitution = 0.0
        body.friction = 0.88
        body.categoryBitMask = PhysicsCategory.environment
        body.collisionBitMask = PhysicsCategory.drone
        body.contactTestBitMask = PhysicsCategory.drone
        node.physicsBody = body

        return CollisionObstacle(
            id: descriptor.id,
            center: descriptor.position + SIMD3<Float>(0.0, proxy.localCenterY, 0.0),
            radius: proxy.analysisRadius,
            source: proxy.source
        )
    }

    private func obstacleProxySpec(for descriptor: EnvironmentObjectDescriptor) -> (geometry: SCNGeometry, localCenterY: Float, analysisRadius: Float, source: String) {
        switch descriptor.kind {
        case .tree:
            let trunkRadius = max(0.16, min(descriptor.size.x, descriptor.size.z) * 0.20)
            let trunkHeight = max(2.2, descriptor.size.y * 0.68)
            return (
                geometry: SCNCylinder(radius: CGFloat(trunkRadius), height: CGFloat(trunkHeight)),
                localCenterY: trunkHeight * 0.5,
                analysisRadius: max(0.42, trunkRadius * 1.4),
                source: "tree.trunk"
            )

        case .building:
            let width = max(4.0, descriptor.size.x)
            let depth = max(4.0, descriptor.size.z)
            let height = max(6.0, descriptor.size.y)
            return (
                geometry: SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth), chamferRadius: 0.0),
                localCenterY: height * 0.5,
                analysisRadius: max(width, depth) * 0.5,
                source: "building.box"
            )

        case .crate:
            let width = max(0.8, descriptor.size.x)
            let depth = max(0.8, descriptor.size.z)
            let height = max(0.8, descriptor.size.y)
            return (
                geometry: SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth), chamferRadius: 0.0),
                localCenterY: height * 0.5,
                analysisRadius: max(width, depth) * 0.5,
                source: "crate.box"
            )

        case .pole:
            let capRadius = max(0.16, descriptor.size.x * 0.22)
            let height = max(4.0, descriptor.size.y)
            return (
                geometry: SCNCapsule(capRadius: CGFloat(capRadius), height: CGFloat(height)),
                localCenterY: height * 0.5,
                analysisRadius: max(0.22, capRadius * 1.12),
                source: "pole.capsule"
            )

        case .rock:
            let radius = max(0.45, max(descriptor.size.x, descriptor.size.z) * 0.42)
            return (
                geometry: SCNSphere(radius: CGFloat(radius)),
                localCenterY: max(0.24, descriptor.size.y * 0.45),
                analysisRadius: radius,
                source: "rock.sphere"
            )

        case .marker:
            let radius = max(0.30, descriptor.size.x * 0.45)
            let height = max(0.8, descriptor.size.y)
            return (
                geometry: SCNCone(topRadius: 0.01, bottomRadius: CGFloat(radius), height: CGFloat(height)),
                localCenterY: height * 0.5,
                analysisRadius: max(radius, height * 0.20),
                source: "marker.cone"
            )

        case .distantBelt:
            let width = max(4.0, descriptor.size.x)
            let depth = max(4.0, descriptor.size.z)
            let height = max(2.0, descriptor.size.y)
            return (
                geometry: SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth), chamferRadius: 0.0),
                localCenterY: height * 0.5,
                analysisRadius: max(width, depth) * 0.5,
                source: "belt.box"
            )
        }
    }

    private func applyComponentOverlays(damage: DamageState, thermal: ThermalState, mode: DiagnosticOverlayMode) {
        let signature = componentOverlaySignature(damage: damage, thermal: thermal, mode: mode)
        if lastComponentOverlaySignature == signature {
            return
        }
        lastComponentOverlaySignature = signature

        let fpvHidden: Set<DamageComponent> = [
            .propellerFL, .propellerFR, .propellerRL, .propellerRR,
            .armFL, .armFR
        ]

        for component in DamageComponent.allCases {
            let nodes = componentNodes[component] ?? []
            let hidden = damage.hiddenComponents.contains(component) || (fpvObstructionHidingActive && fpvHidden.contains(component))
            let selected = damage.selectedComponent == component

            for node in nodes {
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
        let baseSun = CGFloat(1200 * (0.65 + weather.effectiveFactors.visibilityFactor * 0.5))
        var intensity = baseSun

        if weather.preset == .thunderstorm {
            thunderPulse -= deltaTime
            if thunderPulse <= 0.0 {
                thunderPulse = Float.random(in: 0.6...2.2)
                if Float.random(in: 0...1) < weather.normalizedIntensity * 0.5 + 0.2 {
                    intensity += CGFloat(Float.random(in: 900...2600) * weather.normalizedIntensity)
                }
            }
        }

        sunLightNode.light?.intensity = intensity
    }

    private func ensureCollisionDebugMarkers() {
        guard obstacleDebugProxyNodes.isEmpty else {
            return
        }

        for obstacle in environmentObstacles {
            let marker = SCNNode(geometry: SCNSphere(radius: CGFloat(obstacle.radius)))
            marker.position = SCNVector3(obstacle.center.x, obstacle.center.y + obstacle.radius, obstacle.center.z)
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
