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

/// Scene-owned debris physics reports contacts back to the simulation layer,
/// where they enter the canonical damage-event/replay/LAN pipeline.
struct DetachedVehiclePartImpactEvent {
    let rootComponentID: String
    let detachedComponentIDs: [String]
    let colliderID: UUID
    let colliderSource: String
    let worldPoint: SIMD3<Float>
    let impulseNs: Float
    let energyJ: Float
}

private struct DetachedVehiclePartCollisionRuntime {
    let contactSpheres: [VehicleContactSphere]
    let boundingRadius: Float
    let massKg: Float
    let inertiaDiagonal: SIMD3<Float>
    let localCenterOfMassOffset: SIMD3<Float>
    let detachedComponentIDs: [String]
    var previousWorldPosition: SIMD3<Float>
    var previousWorldOrientation: simd_quatf
    var lastColliderID: UUID?
    var impactCooldownRemaining: Float = 0.0
}

struct MissionWaypointCaptureZoneVisual: Equatable {
    let id: UUID
    let label: String
    let center: SIMD3<Float>
    let radius: Float
    let isActive: Bool
    let isCompleted: Bool
}

/// Result of a swept-corridor environment query. `isComplete == false` is a hard safety signal:
/// callers must treat the unexplored remainder as blocked instead of interpreting an empty array
/// as clear air.
struct EnvironmentObstacleCorridorQueryResult {
    let obstacles: [CollisionObstacle]
    let isComplete: Bool
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
        let planePoint: SIMD3<Float>
        let normal: SIMD3<Float>
        let triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)?
        let source: String

        func height(at point: SIMD2<Float>) -> Float? {
            guard abs(normal.y) > 0.001 else {
                return nil
            }
            return planePoint.y -
                (normal.x * (point.x - planePoint.x) +
                 normal.z * (point.y - planePoint.z)) / normal.y
        }
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
    private let lidarRigNode = SCNNode()
    private let lidarYawNode = SCNNode()
    private let lidarPitchNode = SCNNode()
    private var lidarCameraNode: SCNNode?
    private var lidarOpticsState = PayloadLidarOpticsState()
    /// World-space parent of the accumulated point cloud (baked in fixed chunks so a growing survey
    /// never rebuilds the whole cloud per frame). Lives on the scene root, not the moving drone.
    private let lidarCloudRootNode = SCNNode()
    /// Two products, kept apart on purpose: the map is the voxel-centroid deliverable, the raw
    /// cloud is the sensor's own unfiltered record. Conflating them is what made centroid points
    /// carry a single arbitrary return's range/scan_id/ring.
    private var lidarMap = LidarVoxelMap()
    private var lidarRawCloud = LidarRawCloud()
    private var lidarRetainsRawReturns = false
    /// Unbounded on-disk record of every return. The in-memory raw cloud above is only a preview.
    private var lidarRawStream: LidarRawStreamWriter?
    private var lidarTrajectoryStream: LidarTrajectoryStreamWriter?
    /// Shared file-name stem, so all four views of a run carry the same session identity.
    private var lidarSessionBase: String?
    private(set) var lidarStreamedReturnCount = 0
    private var lidarScanCount = 0
    /// Once the bounded preview refuses a block it stays closed for the rest of the run. Letting a
    /// later, smaller block slip in would leave the preview a scattered sample of the sortie rather
    /// than its opening stretch — the one thing that makes it a faithful *preview* of the stream.
    private var lidarPreviewLatched = false
    private var lidarScanPoses: [LidarScanPose] = []
    /// New map cells since the last visual bake, awaiting a chunk node.
    private var lidarPendingPoints: [LidarVoxelMap.Cell] = []
    private var lidarLastBakeTime: TimeInterval = 0
    private var lidarNextScanID: UInt32 = 0
    /// Delay between successive channels inside one firing block — the fixed sequence a
    /// multi-channel head steps through. Microseconds: motion within a block is negligible.
    private static let lidarChannelFiringOffsetSeconds: Double = 2.304e-6
    /// Echoes one pulse may produce before the energy is spent.
    private static let lidarMaximumReturnsPerPulse = 3
    /// Monotonic instant of the survey's first firing block; every timestamp is relative to it.
    private var lidarEpoch: TimeInterval?
    /// The same instant as a wall-clock date, so the relative timeline can be anchored to UTC in
    /// the export and lined up against an external recording.
    private var lidarEpochDate: Date?
    private let hoseRigNode = SCNNode()
    private let hoseYawNode = SCNNode()
    private let hosePitchNode = SCNNode()
    private let hoseNozzleAssemblyNode = SCNNode()
    private let hoseNozzleTipNode = SCNNode()
    private var hoseBodyNode: SCNNode?
    private var hoseCameraNode: SCNNode?
    private var hoseCamera: SCNCamera?
    private var hoseStreamNode: SCNNode?
    private var hoseImpactNode: SCNNode?
    /// World-space charged hose from the parked fire truck to the UAV's swivel inlet. Kept
    /// separate from the gimballed nozzle rig because its truck end is fixed in world space.
    private let fireHoseTetherNode = SCNNode()
    private var fireHoseTetherSegmentNodes: [SCNNode] = []
    private var fireHoseTetherJointNodes: [SCNNode] = []
    private var fireHoseParticlePositions: [SIMD3<Float>] = []
    private var fireHosePreviousParticlePositions: [SIMD3<Float>] = []
    private var fireHoseSimulatedLengthMeters: Float = 0.0
    private weak var fireHoseSimulationTruckNode: SCNNode?
    // No aim rig at all (unlike the hose) — a fixed nadir mist cone under the payload mount.
    // Particle system attached/detached on the spray-state transition only, same "don't keep
    // simulating while hidden" discipline as the hose stream/impact nodes above.
    private var agriculturalSprayerMistNode: SCNNode?
    // Ground-truth "the field is getting wet" trail — the mist particles above fall from the
    // payload mount and die within ~1s/~3m, so at any normal flight altitude they never actually
    // reach and darken the ground on their own. Decals are dropped along the flight path instead
    // of relying on the particles landing.
    private let agriculturalWetGroundNode = SCNNode()
    private let fiberTetherPathNode = SCNNode()
    private var agriculturalWetGroundDecals: [SCNNode] = []
    private var lastAgriculturalWetDecalPlanarPosition: SIMD2<Float>?
    // Capsule bombardier camera — deliberately no yaw/pitch rig unlike the hose/rangefinder above:
    // the launcher has no aim mechanic at all, it's a fixed nadir view (see `dropFireCapsule`'s
    // zero-forward-throw fall kinematics, which makes a straight-down view always show the true
    // impact point at screen center regardless of drone speed).
    private let capsuleCameraRigNode = SCNNode()
    private var capsuleCameraNode: SCNNode?
    private var capsuleCamera: SCNCamera?
    private var capsuleLauncherOpticsAvailable = false
    private let payloadDropCameraController = PayloadDropCameraController()
    private let orbitCameraNode = SCNNode()
    private let topCameraNode = SCNNode()
    private let spectatorCameraNode = SCNNode()
    /// A short-lived stand-in `pointOfView` for `beginCameraTransition` — SceneKit's
    /// `pointOfView` is a single discrete node reference (no built-in cross-camera blend), and
    /// this project keeps one dedicated, continuously-updated node per mode rather than one
    /// shared camera reused across modes. Blending two *different* nodes' live transforms into a
    /// third node and pointing the view at that instead, for a short window, is the standard way
    /// to fake a smooth cut between them without touching that per-mode-node architecture.
    private let cameraTransitionNode = SCNNode()
    private var cameraTransitionFromNode: SCNNode?
    private var cameraTransitionElapsed: Float = 0.0
    private var cameraTransitionDuration: Float = 0.35
    private var cameraTransitionActive: Bool = false

    private let sunLightNode: SCNNode
    private let defaultSunLightPosition: SCNVector3
    private let ambientLightNode: SCNNode
    private let fillLightNode: SCNNode
    private let gridNode: SCNNode
    private let axesNode: SCNNode
    private let groundNode: SCNNode
    /// Camera-following plane carrying the real ground texture on extended ranges.
    /// Nil everywhere else — see `refreshGroundDetailPatch`.
    private var groundDetailNode: SCNNode?
    private var carrierNode: SCNNode?
    private var carrierPropellers: [SCNNode] = []
    private var carrierPylon: SCNNode?
    private var carrierPropellerAngle: Float = 0.0
    private var installedCarrierKind: CarrierAircraftKind?
    private let terrainDetailNode = SCNNode()
    private let worldBoundsNode = SCNNode()
    private let dockStationNode = SCNNode()
    private let missionDropZoneNode = SCNNode()
    private let missionWaypointCaptureNode = SCNNode()
    private var renderedMissionWaypointCaptureZones: [MissionWaypointCaptureZoneVisual] = []
    private var renderedMissionWaypointCaptureGroundY: Float?
    /// Marker height above ground currently applied by `setMissionWaypointCaptureAltitude`, kept
    /// separate from the zone list so altitude changes never trigger a geometry rebuild.
    private var renderedMissionWaypointCaptureHeight: Float?
    private let launchAssetNode = SCNNode()
    private let onlineTrialPlaceholderRootNode = SCNNode()
    // Mission scenarios (SAR etc.): root for spawned scenario entities + the active target.
    private let missionScenarioRootNode = SCNNode()
    private var missionTargetNode: SCNNode?
    // Agricultural spraying scenario: soil patch, crop, refill station and the wet-coverage decal
    // all live in their own layer object, which owns the coverage texture buffer.
    private let agriFieldLayer = AgriFieldSceneLayer()
    // Drone racing: gates, flags and start pad, plus their live highlight state.
    private let raceTrackLayer = RaceTrackSceneLayer()
    /// Collision proxies belonging to the current race track, so a rebuilt track replaces them
    /// instead of stacking a second set of solid gates on top of the first.
    private var raceObstacleIDs: Set<UUID> = []
    /// The track currently in the world, kept so its obstacles can be restored after an
    /// environment rebuild throws the obstacle list away.
    private var installedRaceTrack: RaceTrack?
    /// The crop field currently in the world. Scenery is kept off it — a pine standing in the
    /// wheat is both wrong to look at and a hazard on a 3 m spraying pass.
    private var installedAgriField: AgriFieldPlacement?
    /// Last installed scenery, so objects can be taken off a field that is spawned after the
    /// world was generated (the mission bootstrap does exactly that).
    private var installedEnvironmentNodes: [UUID: SCNNode] = [:]
    private var installedEnvironmentDescriptors: [EnvironmentObjectDescriptor] = []
    // Fire-response scenario: dedicated tree nodes + real flame/smoke VFX, kept entirely outside
    // ScenePopulationService's ambient forest (see FireResponseScenario plan) so charring a tree
    // never interacts with weather-driven forest visual refreshes.
    private(set) var fireTreeNodes: [SCNNode] = []
    private var fireTreeFlameNodes: [SCNNode] = []
    private var fireTreeSmokeNodes: [SCNNode] = []
    // Real-world tree heights, parallel to `fireTreeNodes` — needed to place world-space VFX
    // (like the charred-transition foam burst) without relying on `tree.boundingBox`, which is in
    // the tree's native/unscaled local units and only converts to real meters when parented under
    // that same scaled tree node (see the flame/smoke scale-parenting fix in
    // `spawnFireResponseScenario` for the fuller explanation of why that parenting is wrong).
    private var fireTreeHeightsMeters: [Float] = []
    private var fireTreeFoamAccumulationNodes: [SCNNode] = []
    private var lastFireTreeStatuses: [FireTreeStatus] = []
    private var fireTreeObstacleIDs: Set<UUID> = []
    private var missionFireTruckNode: SCNNode?
    private var freeFlightFireTruckNode: SCNNode?
    private var freeFlightFireTruckDockReference: SIMD3<Float>?
    private var freeFlightFireTruckObstacleIDs: Set<UUID> = []
    private var missionTimeOfDay: TimeOfDay = .day
    /// Continuous world time. `missionTimeOfDay` remains the coarse value existing consumers read;
    /// this is what the lighting actually uses, so dawn and dusk are gradients rather than steps.
    private var worldClock = WorldClock()
    /// Night blend the sky image was last generated for. Twilight is the only time it moves.
    private var lastAppliedNightBlend: Double = -1.0
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
    private var tiltPivotNodes: [SCNNode]
    private var componentNodes: [DamageComponent: [SCNNode]]
    /// SceneKit owns the post-detachment rigid-body motion. The simulation
    /// graph remains authoritative for which components are still attached;
    /// these nodes are only the visible/physical debris representation.
    private let detachedVehiclePartsRootNode = SCNNode()
    private let detachedVehiclePartsGroundNode = SCNNode()
    private var detachedVehiclePartNodes: [String: SCNNode] = [:]
    private var detachedVehiclePartCollisionRuntime: [String: DetachedVehiclePartCollisionRuntime] = [:]
    private var pendingDetachedVehiclePartImpactEvents: [DetachedVehiclePartImpactEvent] = []
    private let detachedVehiclePartCollisionService = CollisionAnalysisService()
    private(set) var detachedVehicleComponentIDs: Set<String> = []
    private var detachedVehicleLegacyComponents: Set<DamageComponent> = []
    private var detachedVehicleVisualNodeIDs: Set<ObjectIdentifier> = []
    private var batteryFireFlameNode: SCNNode?
    private var batteryFireSmokeNode: SCNNode?
    /// Some procedural fixed-wing models use one render node for both wing
    /// halves, while the physical graph has root/outer sections per side.
    /// Once only part of such a node remains attached, compact section boxes
    /// replace that indivisible source mesh so the visual topology continues
    /// to match the authoritative graph.
    private let retainedVehicleSectionProxiesNode = SCNNode()
    private var visualBoundsCenter = SIMD3<Float>(repeating: 0.0)
    private var visualBoundsSize = SIMD3<Float>(repeating: 0.36)
    private var cachedSubjectScale: Float = 0.36
    /// Body-frame geometry of the currently built visual, captured once per
    /// build — the component-graph/contact-profile source for physics.
    private(set) var currentVisualGeometry: DroneVisualGeometrySample = .empty
    /// 0...1 blade-imbalance level from damaged propellers (set per frame by
    /// the view model) — modulates FPV camera shake.
    private var damageVibrationLevel: Float = 0.0

    func setDamageVibrationLevel(_ level: Float) {
        damageVibrationLevel = level.clamped(to: 0.0...1.0)
    }
    private let droneCollisionProxyNode = SCNNode()
    private var droneCollisionProxyRadius: Float = 0.18
    private var fpvObstructionHidingActive: Bool = false
    private var fpvPresentationActive: Bool = false
    private var payloadVisualNode: SCNNode?
    private var activePayloadConfiguration: PayloadConfiguration?
    /// Independent comms/control-link equipment slot — shares the airframe's one payload mount
    /// point (no per-airframe second mount anchor exists in this codebase) but offset behind/
    /// below it so it doesn't visually overlap a simultaneously-mounted payload.
    private var fiberSpoolVisualNode: SCNNode?
    private var payloadCameraNode: SCNNode?
    private var payloadCamera: SCNCamera?
    private var payloadCameraOpticsState = PayloadCameraOpticsState()
    private var rangefinderOpticsState = PayloadRangefinderOpticsState()
    private var hoseOpticsState = PayloadFireHoseOpticsState()
    private let fpvPayloadPresentationNode = SCNNode()
    private var droppedPayloadNodes: [UUID: SCNNode] = [:]
    private var droppedPayloadRuntime: [UUID: DroppedPayloadRuntime] = [:]
    private var pendingPayloadLifecycleEvents: [PayloadLifecycleEvent] = []
    private var payloadCameraFocusReleaseID: UUID?
    private var payloadImpactNodes: [UUID: SCNNode] = [:]
    // Fire-capsule drops are deliberately tracked separately from the generic dropped-payload
    // system above — that system is single-ownership (attach once, drop once, gone for good; see
    // `releasePayloadVisual`), while the capsule launcher stays mounted and fires one capsule at a
    // time out of an ammo count. Keeping this dict (and `fireCapsuleTargetReticleNode` below)
    // fully separate also means a capsule drop can never be picked up by
    // `resolvedPayloadCameraRuntime()`'s "most recent release" fallback and hijack the unrelated
    // `.payload` chase-cam.
    private var fireCapsuleDropNodes: [UUID: SCNNode] = [:]
    private var fireCapsuleTargetReticleNode: SCNNode?
    private var fireCapsuleTargetReticleRingNode: SCNNode?
    private var fireCapsuleTargetReticleDiscNode: SCNNode?

    /// Collision surface of an imported photogrammetric world, when one is loaded.
    ///
    /// Additive rather than a replacement: the procedural obstacle catalogue still applies, so
    /// mission props (fire trucks, mannequins, dropped capsules) keep working on top of a real
    /// city. While this is `nil` every query below behaves exactly as it did before, which is what
    /// makes it safe to land alongside the existing terrain presets rather than replacing them.
    private(set) var meshCollision: MeshCollisionIndex?
    /// The installed imported world, whatever built it.
    private(set) var installedWorld: (any FlyableWorld)?
    /// Start point of the installed imported world, cached off the runtime at install time.
    private var meshSpawnPoint: SIMD3<Float>?

    /// Fallback ground height for launch-rig placement when a support query misses.
    ///
    /// The old fallback was `max(groundNode.y, 0)` — zero in an imported world, whose procedural
    /// ground plane is hidden. When `supportSurfaceHeight` at the spawn returned nil, the catapult
    /// and its aircraft were therefore seated at y ≈ deckHeight above *zero* while the real terrain
    /// was metres up; the aircraft then jumped up through the ground and crashed on its rail angle.
    /// The imported world's own chosen spawn height is the right answer, and it is already known.
    private var launchGroundFallbackY: Float {
        meshSpawnPoint?.y ?? max(Float(groundNode.presentation.position.y), 0.0)
    }
    /// Water plane of the installed imported world, if it has one.
    private(set) var meshWater: WaterSurfaceModel?
    /// Last camera position streaming actually ran from, used to recognise an unplaced camera node.
    private var lastStreamedCameraPosition: SIMD3<Float>?
    /// Viewport height the streaming error metric is computed against. A standing value rather
    /// than a live read: the selection only needs the right order of magnitude, and reading the
    /// live drawable size every tick would mean touching the view from the model layer.
    var meshStreamingViewportHeight: Float = 900

    /// Side of one cached collision cell, in metres. Large enough that a tick's movement rarely
    /// crosses more than one boundary, small enough that a cell holds a few hundred triangles
    /// rather than a few thousand.
    private static let meshCollisionCellSize: Float = 24.0
    /// Reverse lookup for cells synthesised on demand, so `obstacle(for:)` can resolve them.
    private var meshObstaclesByID: [UUID: CollisionObstacle] = [:]
    /// Slack on the analytic ray's spatial query. The index already buckets each obstacle across
    /// the cells its radius reaches, so this only covers cell-boundary rounding.
    private static let analyticRayQueryMargin: Float = 4.0
    // One complete 4096-cell fan plus moving headroom. Triangle-rich cells are expensive; keeping
    // three full fans could retain hundreds of MB in addition to the source collision index.
    private static let meshCollisionCellCacheLimit = 6_144
    // Up to 64×64 cells. The caller derives its horizon from the live turn radius and caps it at a
    // size this mesh cache can answer completely; exceeding the old 33×33 ceiling returned `[]`
    // and made photogrammetry avoidance silently blind.
    private static let meshObstacleQueryCellLimit = 4_096
    /// A single trajectory query must remain well below total cache capacity. Wide fans that exceed
    /// this are retried per course by the avoidance layer instead of flushing the shared cache.
    private static let meshCorridorQueryCellLimit = 4_096

    private struct MeshCollisionCellKey: Hashable {
        let column: Int
        let row: Int
    }

    /// `obstacle` is `nil` for a cell that genuinely holds no geometry — cached as a negative
    /// result so open water and sky are not re-extracted on every tick.
    private struct MeshCollisionCell {
        let obstacle: CollisionObstacle?
    }

    private var meshCollisionCellCache: [MeshCollisionCellKey: MeshCollisionCell] = [:]
    private var meshCollisionCellLastAccess: [MeshCollisionCellKey: UInt64] = [:]
    private var meshCollisionCellAccessCounter: UInt64 = 0

    private var obstacleMap: [UUID: SCNNode] = [:]
    private(set) var environmentObstacles: [CollisionObstacle] = []
    /// Outlines of registry objects that have one, keyed by obstacle id.
    private var worldObjectFootprints: [UUID: [SIMD2<Float>]] = [:]
    /// `worldNavigationObstacles` keyed by id, for the by-id lookups the risk report drives.
    private var worldNavigationObstaclesByID: [UUID: CollisionObstacle] = [:]
    private var environmentObstacleIndex = CollisionObstacleSpatialIndex.empty
    private(set) var environmentMapDescriptors: [EnvironmentObjectDescriptor] = []
    /// The installed world's own buildings and trees, as planning obstacles.
    ///
    /// Separate from `environmentObstacles` on purpose — see `publishWorldRegistry`. These are
    /// footprint boxes for the route planner, whose grid is metres per cell; contact keeps using
    /// the world's exact mesh. Empty when no world is installed, and when the installed world
    /// cannot describe itself as objects (a photogrammetric mesh), which is also the signal that
    /// planning must fall back to mesh collision cells.
    private(set) var worldNavigationObstacles: [CollisionObstacle] = []
    private var worldNavigationObstacleIndex = CollisionObstacleSpatialIndex.empty
    private(set) var environmentRevision: UInt64 = 0
    private var supportSurfaces: [SupportSurfaceDescriptor] = []
    private var dynamicObstacles: [UUID: CollisionObstacle] = [:]
    private var wingmanVisuals: [UUID: WingmanVisual] = [:]
    private var obstacleSourceByID: [UUID: String] = [:]
    private let collisionDebugNode = SCNNode()
    /// Where the collision-debug markers were built; they are rebuilt when the
    /// aircraft leaves that neighbourhood.
    private var collisionDebugAnchor: SIMD3<Float>?
    /// Planar extent of each debug marker, so visibility is judged from the obstacle's surface.
    private var obstacleDebugPlanarRadii: [UUID: Float] = [:]
    private var abandonedCityCollisionDebugVisible = false
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
    private var undeformedComponentTransforms: [ObjectIdentifier: simd_float4x4] = [:]
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
        static let detachedVehiclePart = 1 << 3
    }

    private enum RenderCategory {
        static let droppedPayload = 1 << 6
        static let mountedPayload = 1 << 7
        // Thermal proxy geometry: only the payload camera in thermal mode renders it. Every
        // other camera must clear this bit (cameras default to -1 = all bits set).
        static let thermalProxy = ThermalRenderCategory.proxyBit
        /// The accumulated LiDAR returns. Visible to every ordinary camera *and* to the LiDAR
        /// sensor camera, which renders this and nothing else.
        static let lidarCloud = 1 << 8
        /// The black shell that gives the LiDAR view its darkness. Only the sensor camera sees it —
        /// ordinary cameras must never have a black sphere dropped in front of them.
        static let lidarBackdrop = 1 << 9
        static let standardVisible = Int.max & ~thermalProxy & ~lidarBackdrop
        static let visibleInFPV = standardVisible & ~droppedPayload
        static let visibleInPayloadOptics = standardVisible & ~mountedPayload
        /// A real LiDAR feed is a cloud of returns in darkness — no terrain, no buildings, no
        /// shadows. Restricting the sensor camera to those two bits is what makes it look right,
        /// and it also stops the whole city being re-rendered from a second viewpoint (the lag on
        /// entering this camera).
        static let visibleInLidar = lidarCloud | lidarBackdrop
    }

    private enum CameraClipping {
        static let standardFar: CGFloat = 900
        static let payloadOpticsFar: CGFloat = 2400
    }

    private var freeLookAngles = SIMD2<Float>(repeating: 0.0)   // yaw, pitch
    private let handLaunchPOVCameraNode = SCNNode()
    private var handLaunchPOVLookAngles = SIMD2<Float>(repeating: 0.0) // yaw, pitch
    private var handLaunchPOVArmBuilt = false
    private(set) var isHandLaunchPOVActive = false
    private var orbitLookAngles = SIMD2<Float>(repeating: 0.0)  // yaw, pitch
    private var fpvLookAngles = SIMD2<Float>(repeating: 0.0)    // yaw, pitch
    private var topLookAngles = SIMD2<Float>(repeating: 0.0)    // yaw, pitch
    private var spectatorLookAngles = SIMD2<Float>(repeating: 0.0) // yaw, pitch

    private var orbitAngle: Float = 0.0
    private var activeProfile: DroneModelProfile
    private var vehicleGroundRestLift: Float = 0.0
    private var currentWeather: WeatherModel = .normal
    private var payloadOpticsShadowQualityActive = false
    private var lastPayloadOpticsShadowWeatherPreset: WeatherPreset?
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
        self.ambientLightNode = setup.ambientLightNode
        self.fillLightNode = setup.fillLightNode
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
        self.tiltPivotNodes = droneVisual.tiltPivotNodes
        self.componentNodes = droneVisual.componentNodes
        self.visualBoundsCenter = droneVisual.visualBoundsCenter
        self.visualBoundsSize = droneVisual.visualBoundsSize
        self.cachedSubjectScale = droneVisual.subjectScale
        self.currentVisualGeometry = DroneVisualGeometrySample.capture(from: droneVisual)

        scene.rootNode.addChildNode(droneNode)

        retainedVehicleSectionProxiesNode.name = "retainedVehicleSectionProxiesNode"
        visualRootNode.addChildNode(retainedVehicleSectionProxiesNode)

        detachedVehiclePartsRootNode.name = "detachedVehiclePartsRootNode"
        scene.rootNode.addChildNode(detachedVehiclePartsRootNode)

        self.scenePopulationService = ScenePopulationService(rootNode: scene.rootNode)
        configureDetachedVehiclePartsGroundCollision()
        configureDroneCollisionProxy(for: initialProfile)
        ensurePayloadCameraNode()

        configureCameraNode(followCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(fpvCameraNode, fov: initialProfile.cameraPreset.fpvFov, hidesDroppedPayload: true)
        configureCameraNode(payloadDropCameraController.cameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(orbitCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(topCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(spectatorCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(cameraTransitionNode, fov: initialProfile.cameraPreset.fpvFov)
        scene.rootNode.addChildNode(cameraTransitionNode)

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

        agriculturalWetGroundNode.name = "agriculturalWetGroundNode"
        scene.rootNode.addChildNode(agriculturalWetGroundNode)

        fiberTetherPathNode.name = "fiberTetherPathNode"
        scene.rootNode.addChildNode(fiberTetherPathNode)

        fireHoseTetherNode.name = "fireHoseTetherNode"
        fireHoseTetherNode.isHidden = true
        scene.rootNode.addChildNode(fireHoseTetherNode)

        missionDropZoneNode.name = "missionDropZoneNode"
        missionDropZoneNode.isHidden = true
        scene.rootNode.addChildNode(missionDropZoneNode)

        missionWaypointCaptureNode.name = "missionWaypointCaptureNode"
        missionWaypointCaptureNode.isHidden = true
        scene.rootNode.addChildNode(missionWaypointCaptureNode)

        launchAssetNode.name = "launchAssetNode"
        launchAssetNode.isHidden = true
        scene.rootNode.addChildNode(launchAssetNode)

        // Warm the hand-launch arm rig off the main thread now, so the first
        // time the operator actually enters hand-launch hold doesn't pay for
        // the USDZ parse as a mid-session hitch.
        HandLaunchArmAssetLoader.shared.preloadInBackground()

        onlineTrialPlaceholderRootNode.name = "online_trial_vehicle_placeholders"
        scene.rootNode.addChildNode(onlineTrialPlaceholderRootNode)

        missionScenarioRootNode.name = "missionScenarioRootNode"
        scene.rootNode.addChildNode(missionScenarioRootNode)

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
        if cameraTransitionActive {
            return cameraTransitionNode
        }
        return resolvedPointOfView(for: mode)
    }

    /// The real per-mode lookup `pointOfView(for:)` normally delegates to — kept separate so
    /// `beginCameraTransition`/the per-frame blend can resolve the actual target node even while
    /// `pointOfView(for:)` itself is busy returning the transition stand-in.
    private func resolvedPointOfView(for mode: CameraMode) -> SCNNode {
        // The pre-launch hand-hold is always experienced first-person,
        // regardless of which regular camera mode is selected underneath.
        if isHandLaunchPOVActive {
            return handLaunchPOVCameraNode
        }
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
            return payloadCameraPointOfView() ?? rangefinderCameraPointOfView() ?? lidarCameraPointOfView() ?? hoseCameraPointOfView() ?? capsuleCameraPointOfView() ?? followCameraNode
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

    // MARK: - Capsule bombardier camera

    private func ensureCapsuleCameraRig() {
        if capsuleCameraRigNode.name == nil {
            capsuleCameraRigNode.name = "capsuleCameraRigNode"
            // Same R_x(-90°) rotation used elsewhere in this file (e.g. `hoseBodyNode`) to
            // reorient a node's default forward axis — here it turns the camera's default -Z
            // "forward" into -Y "straight down", a fixed nadir view with no yaw/pitch gimbal.
            capsuleCameraRigNode.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
        }

        if capsuleCameraNode == nil {
            let node = SCNNode()
            node.name = "capsuleCameraNode"

            let camera = SCNCamera()
            camera.fieldOfView = 60.0
            camera.zNear = 0.015
            camera.zFar = CameraClipping.payloadOpticsFar
            camera.categoryBitMask = RenderCategory.visibleInPayloadOptics
            node.camera = camera

            capsuleCameraRigNode.addChildNode(node)
            capsuleCameraNode = node
            capsuleCamera = camera
        }

        if capsuleCameraRigNode.parent !== payloadMountNode {
            capsuleCameraRigNode.removeFromParentNode()
            payloadMountNode.addChildNode(capsuleCameraRigNode)
        }
    }

    func setCapsuleLauncherOpticsAvailability(_ isAvailable: Bool) {
        capsuleLauncherOpticsAvailable = isAvailable
        ensureCapsuleCameraRig()
        capsuleCameraRigNode.isHidden = !isAvailable
    }

    func capsuleCameraPointOfView() -> SCNNode? {
        guard capsuleLauncherOpticsAvailable else {
            return nil
        }
        ensureCapsuleCameraRig()
        return capsuleCameraNode
    }

    func hoseCameraPointOfView() -> SCNNode? {
        guard hoseOpticsState.isAvailable else {
            return nil
        }
        ensureHoseRig()
        return hoseCameraNode
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
        // The renderer is created lazily on first thermal activation, which can happen before or
        // after a mission scenario spawns its target — hand it whatever target is current now.
        renderer.setMissionTarget(missionTargetNode)
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
            sceneProfile: profile,
            isNight: missionTimeOfDay.isNight,
            timeOfDayHours: missionTimeOfDay.timeOfDayHours
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
        // Model transform, not `.presentation` — see `payloadCameraTargetDistance` (render-thread
        // scene-lock stall avoidance).
        let origin = payloadCameraNode.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(payloadCameraNode.simdWorldTransform),
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

    private var activeFireTruckNode: SCNNode? {
        missionFireTruckNode ?? freeFlightFireTruckNode
    }

    /// World position of whichever supply truck is active. Fire-response missions own their
    /// scenario truck; sandbox/free flight gets an equivalent support truck beside the dock.
    func currentFireTruckWorldPosition() -> SIMD3<Float>? {
        activeFireTruckNode?.simdWorldPosition
    }

    /// Exact pump outlet used by both the hard length constraint and the simulated hose chain.
    /// Keeping one anchor prevents the visual hose from claiming more reach than the flight model.
    func currentFireHoseAnchorWorldPosition() -> SIMD3<Float>? {
        guard let truck = activeFireTruckNode else { return nil }
        guard let outlet = truck.childNode(
            withName: FireTruckAssetLoader.pumpOutletAnchorNodeName,
            recursively: true
        ) else { return nil }
        let point = outlet.convertPosition(SCNVector3Zero, to: scene.rootNode)
        return SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
    }

    /// Offset from the physics state's aircraft origin to the actual swivel inlet. The hard
    /// length constraint uses this rather than the vehicle centre, so a 30 m configuration means
    /// 30 m from pump coupling to hose coupling regardless of airframe size or attitude.
    func currentFireHosePayloadOffsetFromStateOrigin() -> SIMD3<Float> {
        let inlet = currentFireHosePayloadAnchorWorldPosition()
        return inlet - droneNode.simdWorldPosition + SIMD3<Float>(0.0, vehicleGroundRestLift, 0.0)
    }

    private func currentFireHosePayloadAnchorWorldPosition() -> SIMD3<Float> {
        let point = payloadMountNode.convertPosition(
            SCNVector3(-0.08, -0.16, 0.04),
            to: scene.rootNode
        )
        return SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
    }

    /// Makes the fire truck part of the hose equipment rather than mission-only decoration. The
    /// free-flight truck follows the dock when the active world changes, while a fire-response
    /// mission temporarily supplies its own scenario-positioned truck instead.
    func setFireHoseSupportActive(_ isActive: Bool) {
        guard isActive else {
            let needsVisualCleanup = freeFlightFireTruckNode != nil
                || !fireHoseParticlePositions.isEmpty
                || !fireHoseTetherNode.isHidden
                || !hoseRigNode.isHidden
                || hoseStreamNode?.isHidden == false
                || hoseImpactNode?.isHidden == false
            removeFreeFlightFireTruck()
            guard needsVisualCleanup else { return }
            hoseRigNode.isHidden = true
            hideHoseSprayVisual()
            resetFireHoseSimulation(hideVisual: true)
            return
        }

        guard missionFireTruckNode == nil else {
            removeFreeFlightFireTruck()
            return
        }

        if freeFlightFireTruckNode != nil,
           let reference = freeFlightFireTruckDockReference,
           simd_distance(reference, dockSpawnPosition) < 0.5 {
            return
        }

        removeFreeFlightFireTruck()

        // Close enough for the shortest supported 10 m hose even when measured from the side
        // pump outlet, but clear of the launch pad and the aircraft's take-off envelope.
        let dock = dockSpawnPosition
        let planarPosition = SIMD2<Float>(dock.x + 6.0, dock.z + 4.0)
        let groundY = supportSurfaceHeight(
            at: planarPosition,
            clearanceRadius: 1.4,
            maximumHeight: max(dock.y + 12.0, 20.0)
        ) ?? dock.y
        let toDock = SIMD2<Float>(dock.x, dock.z) - planarPosition
        let yaw = simd_length(toDock) > 0.001 ? atan2(toDock.x, toDock.y) : 0.0

        let truck = FireTruckAssetLoader.shared.makeTruckNode(targetHeightMeters: 3.0, yaw: yaw)
        truck.name = "support.fire_truck"
        truck.position = SCNVector3(planarPosition.x, groundY, planarPosition.y)
        scene.rootNode.addChildNode(truck)
        freeFlightFireTruckNode = truck
        freeFlightFireTruckDockReference = dock

        let size = SIMD3<Float>(7.0, 3.0, 2.5)
        let descriptor = EnvironmentObjectDescriptor(
            id: UUID(),
            kind: .crate,
            biome: .forest,
            position: SIMD3<Float>(planarPosition.x, groundY, planarPosition.y),
            yawRadians: yaw,
            size: size,
            boundingRadius: max(size.x, size.z) * 0.56,
            isCollidable: true,
            collisionParts: [
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, size.y * 0.5, 0.0),
                    size: size,
                    source: "fire_truck_support",
                    supportsLanding: false
                )
            ]
        )
        let obstacles = configureObstacleCollisionProxies(for: truck, descriptor: descriptor)
        for obstacle in obstacles {
            obstacleMap[obstacle.id] = truck
            obstacleSourceByID[obstacle.id] = obstacle.source
            freeFlightFireTruckObstacleIDs.insert(obstacle.id)
        }
        environmentObstacles.append(contentsOf: obstacles)
        environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
        environmentRevision &+= 1
        resetFireHoseSimulation(hideVisual: true)
    }

    private func removeFreeFlightFireTruck() {
        freeFlightFireTruckNode?.removeFromParentNode()
        freeFlightFireTruckNode = nil
        freeFlightFireTruckDockReference = nil

        guard !freeFlightFireTruckObstacleIDs.isEmpty else { return }
        environmentObstacles.removeAll { freeFlightFireTruckObstacleIDs.contains($0.id) }
        obstacleMap = obstacleMap.filter { !freeFlightFireTruckObstacleIDs.contains($0.key) }
        obstacleSourceByID = obstacleSourceByID.filter { !freeFlightFireTruckObstacleIDs.contains($0.key) }
        freeFlightFireTruckObstacleIDs.removeAll(keepingCapacity: false)
        environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
        environmentRevision &+= 1
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
            applyOnlineComponentDamage(state.componentDamage, to: node)
        }
    }

    private func applyOnlineComponentDamage(
        _ snapshots: [OnlineVehicleComponentDamageSnapshot],
        to root: SCNNode
    ) {
        var taggedNodes: [SCNNode] = []
        root.enumerateChildNodes { node, _ in
            if node.categoryBitMask & Self.onlineDamageComponentMask != 0 {
                taggedNodes.append(node)
                node.isHidden = false
            }
        }

        var minimumIntegrity: Float = 1.0
        var detachedCount = 0
        for snapshot in snapshots {
            minimumIntegrity = min(minimumIntegrity, snapshot.integrity)
            guard snapshot.attachmentState == VehicleAttachmentState.detached.rawValue,
                  let legacy = legacyDamageComponent(forGraphComponentID: snapshot.componentID) else {
                continue
            }
            detachedCount += 1
            guard let componentIndex = DamageComponent.allCases.firstIndex(of: legacy) else { continue }
            let componentBit = 1 << (8 + componentIndex)
            for node in taggedNodes {
                if node.categoryBitMask & componentBit != 0 {
                    node.isHidden = true
                }
            }
        }

        let labelName = "component_damage_label"
        root.childNodes.filter { $0.name == labelName }.forEach { $0.removeFromParentNode() }
        guard !snapshots.isEmpty else { return }
        root.opacity = min(root.opacity, minimumIntegrity < 0.25 || detachedCount > 0 ? 0.52 : 0.76)
        let label = detachedCount > 0 ? "STRUCTURAL DAMAGE" : "COMPONENT DAMAGE"
        addDamageLabel(
            label,
            color: detachedCount > 0 ? .systemRed : .systemOrange,
            to: root,
            name: labelName
        )
    }

    private func legacyDamageComponent(forGraphComponentID id: String) -> DamageComponent? {
        let token = id.lowercased()
        if token == "battery" { return .battery }
        if token == "esc" { return .escPower }
        if token == "flightcontroller" || token == "frame" || token == "fuselage" || token == "radio" {
            return .flightControllerCore
        }
        if token == "cameragimbal" { return .frontCameraGimbal }
        if token.hasPrefix("wing.left") { return .armFL }
        if token.hasPrefix("wing.right") { return .armFR }
        if token == "tail.horizontal" { return .armRL }
        if token == "tail.vertical" { return .armRR }

        let slot = id.split(separator: ".").last.map(String.init)?.uppercased()
        switch (id.split(separator: ".").first.map(String.init), slot) {
        case ("arm", "FL"): return .armFL
        case ("arm", "FR"): return .armFR
        case ("arm", "RL"): return .armRL
        case ("arm", "RR"): return .armRR
        case ("motor", "FL"): return .motorFL
        case ("motor", "FR"): return .motorFR
        case ("motor", "RL"): return .motorRL
        case ("motor", "RR"): return .motorRR
        case ("propeller", "FL"): return .propellerFL
        case ("propeller", "FR"): return .propellerFR
        case ("propeller", "RL"): return .propellerRL
        case ("propeller", "RR"): return .propellerRR
        default: return nil
        }
    }

    private static let onlineDamageComponentMask: Int = DamageComponent.allCases.indices.reduce(0) {
        $0 | (1 << (8 + $1))
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

        switch asset {
        case .handLaunch(let hand):
            // With the first-person view up, the hold point rides the
            // operator's gaze (and walks with him); otherwise it is the
            // static drafted launch point. This is called every simulation
            // tick for as long as the operator stands in the pre-launch
            // hold, so once the POV cradle is available, take it directly —
            // scanning every support surface in the scene (trees,
            // buildings, decorations) just to compute a `supportY` that the
            // POV branch then throws away was a real per-tick cost while the
            // operator was simply standing there aiming.
            if let povCradle = handLaunchPOVCradlePoint() {
                return povCradle
            }
            // Same footprint-probed height the visual pad uses, so the release point stays glued
            // to the plate the pilot sees even when it rests on a road edge.
            let supportY = launchPadSupportHeight(at: asset.position)
            let forward = hand.horizontalDirection * LaunchRigMetrics.handHoldForwardOffset
            return SIMD3<Float>(
                hand.position.x + forward.x,
                supportY + hand.releaseHeightMeters,
                hand.position.y + forward.y
            )
        case .catapult(let catapult):
            let supportY = launchPadSupportHeight(at: asset.position)
            return SIMD3<Float>(
                catapult.position.x,
                supportY + LaunchRigMetrics.catapultDeckHeight + LaunchRigMetrics.catapultCradleOffset,
                catapult.position.y
            )
        case .canister(let canister):
            // Inside the tube, not at its mouth.
            //
            // A sealed round is not visible before launch — that is what "sealed"
            // means — and parking it at the muzzle left it standing proud of its
            // own launcher, nose in the air, which is not how a canister looks on
            // the ground. A third of the way up the tube puts the airframe within
            // the cell it is fired from; the booster carries it out through the
            // rest of the tube on the way.
            let supportY = launchPadSupportHeight(at: asset.position)
            let elevation = canister.elevationDegrees.degreesToRadians
            let muzzle = canister.tubeLengthMeters * 0.32
            let horizontal = MissionLaunchGeometry.horizontalDirection(
                headingDegrees: canister.headingDegrees
            ) * (muzzle * cos(elevation))
            return SIMD3<Float>(
                canister.position.x + horizontal.x,
                supportY + LaunchRigMetrics.canisterPivotHeight + muzzle * sin(elevation),
                canister.position.y + horizontal.y
            )
        case .runway(let runway):
            // Standing on its own gear at the threshold. The physics engine's
            // ground clamp puts the origin at the support height at rest, so no
            // rig offset belongs here — unlike a cradle, a deck or a muzzle, the
            // strip holds nothing up.
            let supportY = launchPadSupportHeight(at: asset.position)
            return SIMD3<Float>(runway.position.x, supportY, runway.position.y)
        case .airLaunch(let release):
            // The one spawn point with no ground under it. Nothing is holding the
            // aircraft up because nothing needs to: it is at the carrier's altitude and
            // about to be at the carrier's speed.
            return release.releasePosition
        }
    }

    /// Highest support under the launch pad's whole base plate, not just its centre point.
    ///
    /// A pad whose centre lands on bare ground right beside a road used to sink its plate edge
    /// under the road's draped ribbon, which sits ~10 cm above the terrain. Probing the plate's
    /// corners keeps the plate resting on the highest surface it actually touches.
    private func launchPadSupportHeight(at position: SIMD2<Float>) -> Float {
        var best: Float?
        let probes: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.7, 0), SIMD2<Float>(-0.7, 0),
            SIMD2<Float>(0, 0.7), SIMD2<Float>(0, -0.7)
        ]
        for offset in probes {
            if let height = supportSurfaceHeight(
                at: position + offset,
                clearanceRadius: 0.32,
                maximumHeight: .greatestFiniteMagnitude
            ) {
                best = max(best ?? height, height)
            }
        }
        return best ?? launchGroundFallbackY
    }

    /// Is the airframe currently inside a sealed canister?
    ///
    /// A stored flag rather than a call to `droneNode.isHidden`, because the camera
    /// update rewrites that every frame — it unhides the aircraft unconditionally
    /// whenever the view is not first-person, which silently undid the launch
    /// presentation's hiding on the very next tick. Two writers, one property; the
    /// one that runs last wins, and it was not the one that knew.
    private var canisterRoundSealed = false

    func setLaunchAsset(_ asset: LaunchAsset?) {
        currentLaunchAsset = asset
        // A round placed on the map is sealed until its launch is commanded.
        canisterRoundSealed = asset?.isCanister == true
        launchAssetNode.childNodes.forEach { $0.removeFromParentNode() }

        guard let asset else {
            launchAssetNode.isHidden = true
            return
        }

        launchAssetNode.isHidden = false

        let supportY = launchPadSupportHeight(at: asset.position)
        launchAssetNode.simdPosition = SIMD3<Float>(asset.position.x, supportY, asset.position.y)
        launchAssetNode.eulerAngles = SCNVector3(
            0.0,
            SCNFloat(asset.worldYawRadians),
            0.0
        )

        switch asset {
        case .handLaunch(let hand):
            launchAssetNode.addChildNode(makeHandLaunchNode(for: hand))
        case .catapult(let catapult):
            launchAssetNode.addChildNode(makeCatapultNode(for: catapult))
        case .canister(let canister):
            launchAssetNode.addChildNode(makeCanisterNode(for: canister))
        case .runway(let runway):
            launchAssetNode.addChildNode(makeRunwayNode(for: runway))
        case .airLaunch:
            // Nothing to build. The carrier is not in the scene — the aircraft simply
            // appears where it was released, already flying, which is exactly what the
            // plan asks for: inherited kinematics and then ordinary 6DOF, with no
            // scripted release animation to go wrong.
            break
        }
    }

    func updateLaunchAssetPresentation(
        progress: Float,
        state: LaunchState
    ) {
        let clampedProgress = progress.clamped(to: 0.0...1.0)
        updateAirframeBoosterEfflux(state: state)
        // Only a canister hides its round.
        if currentLaunchAsset?.isCanister != true {
            canisterRoundSealed = false
        }
        switch currentLaunchAsset {
        case .catapult(let catapult):
            if let carriage = launchAssetNode.childNode(
                withName: "catapult_carriage",
                recursively: true
            ) {
                carriage.simdPosition.z = -catapult.rail.railLengthMeters * clampedProgress
                carriage.opacity = state == .aborted ? 0.45 : 1.0
            }
            if let efflux = launchAssetNode.childNode(
                withName: "catapult_booster_efflux",
                recursively: true
            ) {
                // Burning only while the booster is: the bottle lights at commit
                // and is spent by the time the round is off the rail.
                let burning = state == .assistedAcceleration
                if efflux.isHidden == burning { efflux.isHidden = !burning }
                efflux.particleSystems?.forEach { $0.birthRate = burning ? 900 : 0 }
            }
        case .canister(let canister):
            // The launcher itself does not move; the launch reads through the round
            // leaving it, so only the cap over the launch cell is animated away at
            // commit — and the booster efflux fires with it.
            // Sealed means sealed: the round is inside the tube with its wings
            // folded, and the cell it sits in is narrower than its own span. Leaving
            // the airframe drawn put a wings-out aircraft visibly outside its own
            // launcher, most obviously at a steep elevation. It appears when the cap
            // comes off and the booster fires, which is when it really appears.
            let sealedInTube = state == .idle || state == .prelaunchCheck || state == .aligning
            canisterRoundSealed = sealedInTube
            if let cap = launchAssetNode.childNode(withName: "canister_muzzle_cap", recursively: true) {
                cap.opacity = sealedInTube ? 1.0 : 0.0
            }
            if let efflux = launchAssetNode.childNode(
                withName: "canister_booster_efflux",
                recursively: true
            ) {
                // Burning only while the booster is: `assistedAcceleration` is the
                // boost phase, and the smoke should stop when the motor does rather
                // than trail the aircraft for the rest of the climb.
                let burning = state == .assistedAcceleration
                if efflux.isHidden == burning { efflux.isHidden = !burning }
                efflux.particleSystems?.forEach { $0.birthRate = burning ? 900 : 0 }
            }
            _ = canister
        case .runway:
            // Nothing to animate: the strip is scenery, and the launch reads
            // entirely through the aircraft rolling along it.
            break
        case .handLaunch:
            let throwing = state == .assistedAcceleration
            let released = state == .rotation ||
                state == .initialClimb ||
                state == .transitionToFlight ||
                state == .completed
            let releaseBlend = throwing ? clampedProgress : (released ? 1.0 : 0.0)
            // 0 = holding the airframe at the release point, 1 = full forward
            // follow-through after the throw (arm sweeps down along -Z).
            if let armPivot = handLaunchPOVCameraNode.childNode(
                withName: "hand_launch_pov_arm_pivot",
                recursively: true
            ) {
                armPivot.eulerAngles.x = SCNFloat(-releaseBlend * 1.05)
            }
        case .airLaunch:
            // No launcher in the scene to animate: a carrier release is the absence of
            // an attachment, and the only thing that changes is that the aircraft is
            // now flying on its own.
            break
        case .none:
            break
        }
    }

    // MARK: - Hand-launch first-person view

    /// While the airframe sits in the operator's hand, the scene is viewed
    /// through this camera — the eyes of an operator who is intentionally
    /// not modelled in the world. A sculpted first-person arm hangs under
    /// the camera and carries the aircraft; mouse look turns both the view
    /// and, via the view model, the held airframe. WASD walks the operator.
    func activateHandLaunchPOV(initialYawRadians: Float, initialPitchRadians: Float) {
        guard case .handLaunch(let hand)? = currentLaunchAsset else {
            return
        }

        if handLaunchPOVCameraNode.parent == nil {
            let camera = SCNCamera()
            camera.fieldOfView = 74.0
            camera.zNear = 0.015
            camera.zFar = Double(CameraClipping.standardFar)
            handLaunchPOVCameraNode.camera = camera
            handLaunchPOVCameraNode.name = "hand_launch_pov_camera"
            scene.rootNode.addChildNode(handLaunchPOVCameraNode)
        }
        if !handLaunchPOVArmBuilt {
            buildHandLaunchPOVArm()
        }

        guard !isHandLaunchPOVActive else {
            return
        }
        isHandLaunchPOVActive = true
        handLaunchPOVCameraNode.isHidden = false
        handLaunchPOVLookAngles = SIMD2<Float>(
            initialYawRadians,
            initialPitchRadians.clamped(to: -0.55...0.45)
        )

        // Eyes start at the drafted launch point; afterwards the operator is
        // free to walk (`moveHandLaunchPOVOperator`), so the position is only
        // set here, on entry.
        let supportY = supportSurfaceHeight(
            at: hand.position,
            clearanceRadius: 0.28,
            maximumHeight: .greatestFiniteMagnitude
        ) ?? launchGroundFallbackY
        handLaunchPOVCameraNode.simdPosition = SIMD3<Float>(
            hand.position.x,
            supportY + hand.releaseHeightMeters + LaunchRigMetrics.handEyeAboveRelease,
            hand.position.y
        )
        applyHandLaunchPOVAngles()
    }

    /// Closest spot to a map-drafted start that an aircraft may actually occupy.
    ///
    /// The tactical map is a flat plan: a tap carries no information about what stands at that
    /// spot, so it can land inside a building or under a road deck. Judged by the same
    /// `WorldSpawnFinder` criteria the world's own start point is chosen with, except that rooftops
    /// count — a tap on a building is read as a request to launch *from* it, not beside it. Nil when
    /// the world is procedural (no imported collision to consult) or nothing legal is near.
    @MainActor
    func nearestValidLaunchPoint(near planarPosition: SIMD2<Float>) -> SIMD2<Float>? {
        guard let world = installedWorld else { return nil }
        let finder = WorldSpawnFinder(collision: world.collision, water: world.water)
        // A tap on a building is a request for its roof, and it is asked first: the ordinary snap
        // judges a roof by street-level clearance rules and would send the operator down to the
        // pavement beside the building he picked.
        let roof = finder.rooftopStart(at: planarPosition)
        guard let point = roof ?? finder.nearestValidPoint(
            to: planarPosition,
            allowElevated: true
        ) else { return nil }
        return SIMD2<Float>(point.x, point.z)
    }

    /// Walks the first-person operator over to a newly drafted launch point.
    ///
    /// `activateHandLaunchPOV` sets the eye position **on entry only** — afterwards the operator
    /// walks himself — and re-entry is a no-op while the view is up. So moving the start on the
    /// tactical map left him standing at the old spot, and with him the airframe: its hold point
    /// is `handLaunchPOVCradlePoint()`, which rides this camera rather than the drafted position.
    /// Look angles are deliberately untouched — the operator keeps facing where he was aiming.
    func relocateHandLaunchPOVOperator(
        to planarPosition: SIMD2<Float>,
        releaseHeightMeters: Float
    ) {
        guard isHandLaunchPOVActive else {
            return
        }
        let supportY = supportSurfaceHeight(
            at: planarPosition,
            clearanceRadius: 0.28,
            maximumHeight: .greatestFiniteMagnitude
        ) ?? launchGroundFallbackY
        handLaunchPOVCameraNode.simdPosition = SIMD3<Float>(
            planarPosition.x,
            supportY + releaseHeightMeters + LaunchRigMetrics.handEyeAboveRelease,
            planarPosition.y
        )
        applyHandLaunchPOVAngles()
    }

    /// Hold point of the airframe in the operator's hand, in world space —
    /// rides the gaze ray so hand, aircraft and view stay glued together.
    func handLaunchPOVCradlePoint() -> SIMD3<Float>? {
        guard isHandLaunchPOVActive else {
            return nil
        }
        return handLaunchPOVCameraNode.simdConvertPosition(
            SIMD3<Float>(
                LaunchRigMetrics.handHoldSideOffset,
                -LaunchRigMetrics.handHoldDropBelowEyes,
                -LaunchRigMetrics.handHoldForwardOffset
            ),
            to: nil
        )
    }

    func handLaunchPOVLookPitchRadians() -> Float {
        handLaunchPOVLookAngles.y
    }

    /// First-person walking (WASD): moves the operator across the terrain in
    /// look-relative directions, keeping the eyes at standing height above
    /// whatever surface he is on. The held airframe follows via the per-tick
    /// cradle hold, which reads `handLaunchPOVCradlePoint()`.
    func moveHandLaunchPOVOperator(
        forward: Float,
        strafe: Float,
        deltaTime: Float,
        speed: Float,
        worldHalfExtent: Float
    ) {
        guard isHandLaunchPOVActive,
              deltaTime > 0.0,
              case .handLaunch(let hand)? = currentLaunchAsset else {
            return
        }
        let input = SIMD2<Float>(strafe, forward)
        let magnitude = simd_length(input)
        guard magnitude > 0.02 else {
            return
        }
        let clamped = magnitude > 1.0 ? input / magnitude : input

        let yaw = handLaunchPOVLookAngles.x
        let forwardDir = SIMD2<Float>(-sin(yaw), -cos(yaw))
        let rightDir = SIMD2<Float>(cos(yaw), -sin(yaw))
        let origin = SIMD2<Float>(
            handLaunchPOVCameraNode.simdPosition.x,
            handLaunchPOVCameraNode.simdPosition.z
        )
        let eyeAboveFoot = hand.releaseHeightMeters + LaunchRigMetrics.handEyeAboveRelease
        let footY = handLaunchPOVCameraNode.simdPosition.y - eyeAboveFoot

        let step = (forwardDir * clamped.y + rightDir * clamped.x) * speed * deltaTime
        let stepLength = simd_length(step)
        guard stepLength > 0.0001 else {
            return
        }

        // Walls. The step used to be applied unconditionally, so walking into a facade carried the
        // operator inside the building — and the airframe with him, since its hold point rides this
        // camera. Probed at chest height, which is what a wall blocks; a kerb or a bollard below
        // that is handled by the step-up limit instead.
        if let meshCollision {
            let probeOrigin = SIMD3<Float>(origin.x, footY + Self.handLaunchPOVChestHeight, origin.y)
            let direction = simd_normalize(SIMD3<Float>(step.x, 0.0, step.y))
            if meshCollision.raycast(
                origin: probeOrigin,
                direction: direction,
                maxDistance: stepLength + Self.handLaunchPOVShoulderMargin
            ) != nil {
                return
            }
        }

        var planar = origin + step
        let bound = max(4.0, worldHalfExtent - 2.0)
        planar.x = planar.x.clamped(to: -bound...bound)
        planar.y = planar.y.clamped(to: -bound...bound)

        // Ceiling on the support probe. Searching from the sky takes the *highest* surface in the
        // column, which beside a building is its roof — the operator was lifted to roof height and
        // left standing in mid-air. Capping the search just above his own feet keeps him on the
        // surface he is walking on: he may step up a kerb, never up a facade. Descent is left
        // unbounded so a walk off an edge lands him on the street rather than stranding him.
        let supportY = supportSurfaceHeight(
            at: planar,
            clearanceRadius: 0.28,
            maximumHeight: footY + Self.handLaunchPOVStepUpLimit
        ) ?? launchGroundFallbackY
        handLaunchPOVCameraNode.simdPosition = SIMD3<Float>(
            planar.x,
            supportY + eyeAboveFoot,
            planar.y
        )
    }

    /// Height the wall probe is cast at — above kerbs and bollards, below a doorway lintel.
    private static let handLaunchPOVChestHeight: Float = 1.1
    /// How far ahead of the step a wall still counts, so the operator stops short of the facade
    /// instead of ending the step with his eyes inside it.
    private static let handLaunchPOVShoulderMargin: Float = 0.45
    /// Tallest rise the operator may walk up in one step. A kerb, a ramp or a low plinth passes; a
    /// wall and a rooftop do not.
    private static let handLaunchPOVStepUpLimit: Float = 0.9

    func deactivateHandLaunchPOV() {
        guard isHandLaunchPOVActive else {
            return
        }
        isHandLaunchPOVActive = false
        handLaunchPOVCameraNode.isHidden = true
    }

    func applyHandLaunchPOVLook(
        yawDeltaDeg: Float,
        pitchDeltaDeg: Float,
        invertX: Bool,
        invertY: Bool
    ) {
        guard isHandLaunchPOVActive else {
            return
        }
        let yawSign: Float = invertX ? -1.0 : 1.0
        let pitchSign: Float = invertY ? -1.0 : 1.0
        handLaunchPOVLookAngles.x += yawDeltaDeg.degreesToRadians * yawSign
        handLaunchPOVLookAngles.y = (handLaunchPOVLookAngles.y + pitchDeltaDeg.degreesToRadians * pitchSign)
            .clamped(to: -0.55...0.45)
        applyHandLaunchPOVAngles()
    }

    func handLaunchPOVWorldYawRadians() -> Float {
        handLaunchPOVLookAngles.x
    }

    private func applyHandLaunchPOVAngles() {
        handLaunchPOVCameraNode.eulerAngles = SCNVector3(
            CGFloat(handLaunchPOVLookAngles.y),
            CGFloat(handLaunchPOVLookAngles.x),
            0.0
        )
    }

    /// First-person viewmodel arm: the left arm enters the frame from the
    /// lower-left, its open palm cupping the airframe's belly at the hold
    /// point. Camera-local, so it follows every look movement together with
    /// the held aircraft (whose cradle point rides the same gaze ray).
    private func buildHandLaunchPOVArm() {
        handLaunchPOVArmBuilt = true

        let shoulderLocal = SIMD3<Float>(-0.32, -0.48, 0.15)
        let palmTargetLocal = SIMD3<Float>(
            LaunchRigMetrics.handHoldSideOffset,
            -LaunchRigMetrics.handHoldDropBelowEyes - 0.085,
            -LaunchRigMetrics.handHoldForwardOffset
        )
        let reachVector = palmTargetLocal - shoulderLocal
        let reach = simd_length(reachVector)

        let aligner = SCNNode()
        aligner.simdPosition = shoulderLocal
        aligner.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0.0, 0.0, -1.0),
            to: reachVector / reach
        )
        handLaunchPOVCameraNode.addChildNode(aligner)

        let pivot = SCNNode()
        pivot.name = "hand_launch_pov_arm_pivot"
        aligner.addChildNode(pivot)

        if let armModel = HandLaunchArmAssetLoader.shared.makeArmNode(reach: reach) {
            pivot.addChildNode(armModel)
        } else {
            let skinMaterial = SCNMaterial()
            skinMaterial.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.56, blue: 0.45, alpha: 1.0)
            skinMaterial.roughness.contents = 0.85
            let elbowLocal = SIMD3<Float>(0.02, -0.055, -reach * 0.52)
            let handLocal = SIMD3<Float>(0.0, 0.0, -reach)
            pivot.addChildNode(launchRigSegment(
                from: .zero, to: elbowLocal, radius: 0.052, material: skinMaterial
            ))
            pivot.addChildNode(launchRigSegment(
                from: elbowLocal, to: handLocal, radius: 0.044, material: skinMaterial
            ))
            let palm = SCNNode(geometry: SCNSphere(radius: 0.055))
            palm.geometry?.materials = [skinMaterial]
            palm.simdPosition = handLocal
            pivot.addChildNode(palm)
        }

        // A first-person viewmodel casting a big detached shadow on the
        // ground reads as a glitch, not realism.
        disableShadowsRecursively(handLaunchPOVCameraNode)
    }

    private func disableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = false
        for child in node.childNodes {
            disableShadowsRecursively(child)
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
            centerMarker.name = "mission_capture_marker"
            centerMarker.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.95)
            centerMarker.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(0.38)
            centerMarker.geometry?.firstMaterial?.lightingModel = .constant
            centerMarker.simdPosition = sphereNode.simdPosition
            root.addChildNode(centerMarker)

            // Always built, even when currently too short to show: the altitude now follows the
            // aircraft (see `setMissionWaypointCaptureAltitude`), so a stem that only existed for
            // tall zones would be missing exactly when the aircraft climbed and needed it.
            let stemHeight = max(0.0, altitude - groundY)
            let stem = SCNCylinder(
                radius: CGFloat(max(0.018, min(0.055, radius * 0.006))),
                height: CGFloat(max(0.001, stemHeight))
            )
            let stemMaterial = SCNMaterial()
            stemMaterial.diffuse.contents = color.withAlphaComponent(zone.isActive ? 0.62 : 0.34)
            stemMaterial.emission.contents = color.withAlphaComponent(zone.isActive ? 0.22 : 0.10)
            stemMaterial.lightingModel = .constant
            stem.materials = [stemMaterial]

            let stemNode = SCNNode(geometry: stem)
            stemNode.name = "mission_capture_stem"
            stemNode.simdPosition = SIMD3<Float>(0.0, stemHeight * 0.5, 0.0)
            stemNode.isHidden = stemHeight <= 0.35
            root.addChildNode(stemNode)

            missionWaypointCaptureNode.addChildNode(root)
        }

        renderedMissionWaypointCaptureHeight = max(
            0.0,
            (zones.first.map { max(groundY + 0.35, $0.center.y) } ?? groundY) - groundY
        )
    }

    /// Moves the capture markers to a new working altitude without rebuilding any geometry.
    ///
    /// The zone *list* changes only on mission edits, but its height should follow the aircraft
    /// every tick. Sharing one path meant the whole marker set — torus, wireframe sphere, stem,
    /// per-zone materials — was torn down and rebuilt on every altitude change, so in practice the
    /// height was refreshed only when the tactical map happened to be open. That is what made the
    /// spheres appear to jump the moment the planner was opened.
    func setMissionWaypointCaptureAltitude(_ altitude: Float) {
        guard !missionWaypointCaptureNode.isHidden,
              !renderedMissionWaypointCaptureZones.isEmpty else {
            return
        }
        let groundY = renderedMissionWaypointCaptureGroundY ?? 0.0
        let height = max(0.0, altitude - groundY)
        if let rendered = renderedMissionWaypointCaptureHeight,
           abs(rendered - height) <= 0.05 {
            return
        }
        renderedMissionWaypointCaptureHeight = height

        let markerPosition = SIMD3<Float>(0.0, height, 0.0)
        for root in missionWaypointCaptureNode.childNodes {
            for child in root.childNodes {
                switch child.name {
                case "mission_capture_sphere", "mission_capture_marker":
                    child.simdPosition = markerPosition
                case "mission_capture_stem":
                    (child.geometry as? SCNCylinder)?.height = CGFloat(max(0.001, height))
                    child.simdPosition = SIMD3<Float>(0.0, height * 0.5, 0.0)
                    child.isHidden = height <= 0.35
                default:
                    break
                }
            }
        }
    }

    /// Height of the catapult shuttle deck (rail start) above the ground and
    /// the extra offset that puts the aircraft's fuselage centre into the
    /// shuttle cradle. `currentLaunchSpawnPoint` and the launch physics origin
    /// must stay in lockstep with the visual rig built by `makeCatapultNode`.
    private enum LaunchRigMetrics {
        static let catapultDeckHeight: Float = 0.62
        static let catapultCradleOffset: Float = 0.17
        /// Hand launch is presented first-person: the airframe rides the
        /// operator's gaze ray, held in the left hand (the sculpted asset is
        /// a left arm) — forward of, below and to the left of the eyes
        /// (composition validated with offscreen renders: the screen centre
        /// stays clear for aiming, the arm enters from the lower-left). The
        /// physics release origin and the POV camera must agree on these
        /// numbers.
        static let handHoldForwardOffset: Float = 0.75
        static let handHoldDropBelowEyes: Float = 0.22
        static let handHoldSideOffset: Float = -0.18
        static let handEyeAboveRelease: Float = 0.20
        /// Height of the canister trunnion above the launch vehicle's deck.
        static let canisterPivotHeight: Float = 1.35
    }

    /// Loads `HandLaunchArm.usdz` (sculpted human arm, shoulder ball to open
    /// hand) for the hand-launch rig. The anchor points below were measured
    /// from the mesh vertices (model units): the returned node has the
    /// shoulder ball at its origin and the palm centre at `(0, 0, -reach)`,
    /// so a parent pivot can swing it like a shoulder joint.
    final class HandLaunchArmAssetLoader {
        static let shared = HandLaunchArmAssetLoader()

        private static let shoulderAnchor = SIMD3<Float>(-29.24, 77.21, 3.64)
        private static let palmAnchor = SIMD3<Float>(71.54, -136.39, 23.21)
        /// Roll about the arm axis that turns the open palm upward so it
        /// carries the fuselage from below (chosen from rendered variants).
        private static let palmUpRollRadians: Float = .pi / 2.0

        private let loadLock = NSLock()
        private var cachedTemplate: SCNNode?
        private var didAttemptLoad = false

        private init() {}

        /// Kicks off the USDZ parse on a background queue as early as the
        /// scene exists, well before the operator ever reaches hand-launch
        /// hold. Parsing `HandLaunchArm.usdz` synchronously on first use used
        /// to show up as a sudden frame hitch right as the first-person rig
        /// was built; warming the cache ahead of time makes that first
        /// `makeArmNode` call a cheap clone instead.
        func preloadInBackground() {
            DispatchQueue.global(qos: .utility).async { [self] in
                _ = loadTemplate()
            }
        }

        /// Arm with the shoulder at the node origin reaching to a palm at
        /// `(0, 0, -reach)`. Returns nil when the USDZ asset is unavailable —
        /// the caller supplies its own procedural fallback.
        func makeArmNode(reach: Float) -> SCNNode? {
            guard let template = loadTemplate() else {
                return nil
            }
            let shoulder = Self.shoulderAnchor
            let armAxis = simd_normalize(Self.palmAnchor - shoulder)
            let armLength = simd_length(Self.palmAnchor - shoulder)
            let scale = max(0.05, reach) / max(1.0, armLength)

            let alignRotation = simd_quatf(from: armAxis, to: SIMD3<Float>(0.0, 0.0, -1.0))
            let rollRotation = simd_quatf(
                angle: Self.palmUpRollRadians,
                axis: SIMD3<Float>(0.0, 0.0, 1.0)
            )
            let rotation = rollRotation * alignRotation

            let arm = template.clone()
            arm.simdScale = SIMD3<Float>(repeating: scale)
            arm.simdOrientation = rotation
            arm.simdPosition = -rotation.act(shoulder * scale)

            let wrapper = SCNNode()
            wrapper.name = "hand_launch_arm_model"
            wrapper.addChildNode(arm)
            return wrapper
        }

        /// Locked across the whole load (not just the cache read) so a
        /// background preload and a main-thread `makeArmNode` racing each
        /// other never both parse the USDZ, and the main thread — if it
        /// somehow gets there first — simply blocks until the one load
        /// finishes rather than falling back to the procedural arm.
        private func loadTemplate() -> SCNNode? {
            loadLock.lock()
            defer { loadLock.unlock() }

            if didAttemptLoad {
                return cachedTemplate
            }
            didAttemptLoad = true

            guard let url = Bundle.main.url(
                forResource: "HandLaunchArm",
                withExtension: "usdz"
            ), let scene = try? SCNScene(url: url, options: [
                .checkConsistency: false
            ]) else {
                print("[LaunchRig] HandLaunchArm.usdz unavailable; using procedural arm fallback")
                return nil
            }

            let root = SCNNode()
            root.name = "hand_launch_arm_template"
            for child in scene.rootNode.childNodes {
                root.addChildNode(child.clone())
            }
            normalizeMaterials(root)
            cachedTemplate = root
            return root
        }

        /// The Sketchfab sculpt ships with a translucent-looking material that
        /// lets the terrain bleed through; force an opaque matte skin tone.
        private func normalizeMaterials(_ node: SCNNode) {
            node.castsShadow = true
            node.geometry?.materials.forEach { material in
                material.transparency = 1.0
                material.blendMode = .replace
                material.transparent.contents = nil
                material.diffuse.contents = NSColor(
                    calibratedRed: 0.87, green: 0.70, blue: 0.58, alpha: 1.0
                )
                material.roughness.contents = 0.85
                material.metalness.contents = 0.0
                material.isDoubleSided = true
            }
            for child in node.childNodes {
                normalizeMaterials(child)
            }
        }
    }

    /// Capsule strut between two points; the workhorse of the procedural
    /// launch-rig builders. Guards the degenerate anti-parallel case of
    /// `simd_quatf(from:to:)` (straight-down segments) explicitly.
    private func launchRigSegment(
        name: String? = nil,
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let delta = end - start
        let length = max(0.01, simd_length(delta))
        let direction = delta / length
        let node = SCNNode(
            geometry: SCNCapsule(
                capRadius: CGFloat(radius),
                height: CGFloat(length)
            )
        )
        node.name = name
        node.geometry?.materials = [material]
        node.simdPosition = (start + end) * 0.5
        let up = SIMD3<Float>(0.0, 1.0, 0.0)
        if simd_dot(up, direction) < -0.9995 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1.0, 0.0, 0.0))
        } else {
            node.simdOrientation = simd_quatf(from: up, to: direction)
        }
        return node
    }

    /// Truck-mounted launch canister: a flatbed, a trunnion and an elevated tube.
    /// Deliberately not a rail — a canister launch has no carriage travelling
    /// along anything, which is exactly the difference from a catapult.
    /// The strip. Geometry lives in `RunwayAssetLoader`, which prefers a bundled
    /// `Runway.usdz` and falls back to a procedural paved strip with markings.
    private func makeRunwayNode(for asset: RunwayLaunchAsset) -> SCNNode {
        RunwayAssetLoader.shared.makeRunwayNode(lengthMeters: asset.usableLengthMeters)
    }

    private func makeCanisterNode(for asset: CanisterLaunchAsset) -> SCNNode {
        let root = SCNNode()
        let elevation = asset.elevationDegrees.degreesToRadians
        let tubeLength = max(1.6, asset.tubeLengthMeters)
        let pivotHeight = LaunchRigMetrics.canisterPivotHeight

        let deckMaterial = SCNMaterial()
        deckMaterial.diffuse.contents = NSColor(calibratedRed: 0.30, green: 0.33, blue: 0.29, alpha: 1.0)
        deckMaterial.roughness.contents = 0.62
        deckMaterial.metalness.contents = 0.34

        let tubeMaterial = SCNMaterial()
        tubeMaterial.diffuse.contents = NSColor(calibratedRed: 0.38, green: 0.41, blue: 0.38, alpha: 1.0)
        tubeMaterial.roughness.contents = 0.44
        tubeMaterial.metalness.contents = 0.58

        let capMaterial = SCNMaterial()
        capMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.92)
        capMaterial.roughness.contents = 0.50

        let tyreMaterial = SCNMaterial()
        tyreMaterial.diffuse.contents = NSColor(calibratedWhite: 0.09, alpha: 1.0)
        tyreMaterial.roughness.contents = 0.94

        let deck = SCNNode(geometry: SCNBox(width: 2.3, height: 0.34, length: 5.4, chamferRadius: 0.06))
        deck.geometry?.materials = [deckMaterial]
        deck.simdPosition = SIMD3<Float>(0.0, 0.86, 0.0)
        root.addChildNode(deck)

        let cab = SCNNode(geometry: SCNBox(width: 2.1, height: 1.3, length: 1.7, chamferRadius: 0.12))
        cab.geometry?.materials = [deckMaterial]
        cab.simdPosition = SIMD3<Float>(0.0, 1.65, 1.9)
        root.addChildNode(cab)

        for side in [Float(-1.0), Float(1.0)] {
            for axle in [Float(-1.6), Float(0.4), Float(1.9)] {
                let wheel = SCNNode(geometry: SCNCylinder(radius: 0.52, height: 0.34))
                wheel.geometry?.materials = [tyreMaterial]
                wheel.eulerAngles = SCNVector3(0.0, 0.0, SCNFloat.pi / 2.0)
                wheel.simdPosition = SIMD3<Float>(side * 1.12, 0.52, axle)
                root.addChildNode(wheel)
            }
        }

        // Trunnion and the elevated tube. The tube points along -Z at zero
        // elevation, matching the launch heading applied to the parent node.
        let trunnion = SCNNode()
        trunnion.simdPosition = SIMD3<Float>(0.0, pivotHeight, -0.6)
        trunnion.eulerAngles = SCNVector3(SCNFloat(-elevation), 0.0, 0.0)
        root.addChildNode(trunnion)

        // A single tube was wrong for both aircraft that use this launcher. The
        // Harpy is carried as a rack of separate containerised rounds, the Harop in
        // one inclined pack whose face is a grid of large square muzzles — the
        // launcher in almost every published photograph of it. The airframe leaves
        // from the centre cell either way, which is where the physics puts it.
        let columns: Int
        let rows: Int
        let cellSize: Float
        let cellGap: Float
        switch asset.launcherPattern {
        case .containerRack:
            columns = 3
            rows = 3
            cellSize = 0.56
            cellGap = 0.12
        case .cellBlock:
            // Three by three, not three by two: the launch cell has to be the
            // centre one, or the round sits offset from the axis the physics
            // spawns it on and appears to hang beside its own launcher.
            columns = 3
            rows = 3
            cellSize = 0.78
            cellGap = 0.03
        }
        let pitchX = cellSize + cellGap
        let pitchY = cellSize + cellGap

        if asset.launcherPattern == .cellBlock {
            // One structural pack: the cells are cut into a single block rather
            // than being individual containers strapped to a frame.
            let pack = SCNNode(geometry: SCNBox(
                width: CGFloat(Float(columns) * pitchX + 0.10),
                height: CGFloat(Float(rows) * pitchY + 0.10),
                length: CGFloat(tubeLength),
                chamferRadius: 0.04
            ))
            pack.geometry?.materials = [tubeMaterial]
            pack.simdPosition = SIMD3<Float>(0.0, 0.0, -tubeLength * 0.5)
            trunnion.addChildNode(pack)
        }

        for column in 0..<columns {
            for row in 0..<rows {
                let x = (Float(column) - Float(columns - 1) * 0.5) * pitchX
                let y = (Float(row) - Float(rows - 1) * 0.5) * pitchY
                let isLaunchCell = column == columns / 2 && row == rows / 2

                if asset.launcherPattern == .containerRack {
                    let container = SCNNode(geometry: SCNBox(
                        width: CGFloat(cellSize),
                        height: CGFloat(cellSize),
                        length: CGFloat(tubeLength),
                        chamferRadius: 0.05
                    ))
                    container.geometry?.materials = [tubeMaterial]
                    container.simdPosition = SIMD3<Float>(x, y, -tubeLength * 0.5)
                    trunnion.addChildNode(container)
                } else {
                    // The muzzle opening, recessed into the pack face.
                    let mouth = SCNNode(geometry: SCNBox(
                        width: CGFloat(cellSize * 0.86),
                        height: CGFloat(cellSize * 0.86),
                        length: 0.16,
                        chamferRadius: 0.02
                    ))
                    mouth.geometry?.materials = [deckMaterial]
                    mouth.simdPosition = SIMD3<Float>(x, y, -tubeLength + 0.06)
                    trunnion.addChildNode(mouth)
                }

                let cap = SCNNode(geometry: SCNBox(
                    width: CGFloat(cellSize * (asset.launcherPattern == .containerRack ? 1.06 : 0.9)),
                    height: CGFloat(cellSize * (asset.launcherPattern == .containerRack ? 1.06 : 0.9)),
                    length: 0.07,
                    chamferRadius: 0.03
                ))
                cap.geometry?.materials = [capMaterial]
                // Only the cell the airframe leaves from is animated away at commit.
                cap.name = isLaunchCell ? "canister_muzzle_cap" : "canister_cap_\(column)_\(row)"
                cap.simdPosition = SIMD3<Float>(x, y, -tubeLength - 0.035)
                trunnion.addChildNode(cap)
            }
        }

        // Booster efflux. A canister round is thrown out by a rocket motor, and the
        // launch is unmistakable from outside because of it: a bright plume off the
        // muzzle and a cloud that hangs over the vehicle afterwards. Parked here on
        // the launcher rather than on the airframe so it stays where the smoke
        // actually is once the aircraft has gone.
        let effluxAnchor = SCNNode()
        effluxAnchor.name = "canister_booster_efflux"
        effluxAnchor.simdPosition = SIMD3<Float>(0.0, 0.0, -tubeLength - 0.2)
        effluxAnchor.addParticleSystem(makeCanisterBoosterPlume())
        effluxAnchor.isHidden = true
        trunnion.addChildNode(effluxAnchor)

        return root
    }

    /// The round's own booster, burning behind the airframe after it leaves.
    ///
    /// The launcher-side plume stops at the muzzle, and in every photograph of a
    /// canister or rail launch the flame is still there once the aircraft is
    /// clear — the booster burns for another second in the air. Only a launch that
    /// is actually boosted gets one: a hand throw and a runway roll have no motor
    /// to show.
    private func updateAirframeBoosterEfflux(state: LaunchState) {
        let boosted: Bool
        switch currentLaunchAsset {
        case .canister:
            boosted = true
        case .catapult(let catapult):
            boosted = catapult.rail.usesRocketBooster
        default:
            boosted = false
        }
        let burning = boosted && state == .assistedAcceleration

        let existing = droneNode.childNode(withName: "airframeBoosterEfflux", recursively: true)
        guard burning || existing != nil else { return }

        let anchor: SCNNode
        if let existing {
            anchor = existing
        } else {
            anchor = SCNNode()
            anchor.name = "airframeBoosterEfflux"
            // Behind the tail: the airframe's nose is -Z, so the motor fires +Z.
            let (minBB, maxBB) = droneNode.boundingBox
            anchor.simdPosition = SIMD3<Float>(0.0, 0.0, Float(maxBB.z - minBB.z) * 0.5 + 0.05)
            anchor.addParticleSystem(makeBoosterPlume(scale: 0.45))
            droneNode.addChildNode(anchor)
        }
        if anchor.isHidden == burning { anchor.isHidden = !burning }
        anchor.particleSystems?.forEach { $0.birthRate = burning ? 700 : 0 }
    }

    /// Rocket efflux off the muzzle at the moment of ejection.
    private func makeCanisterBoosterPlume() -> SCNParticleSystem {
        // Fired forward along the tube: the plume comes out of the muzzle with the
        // round, which is the whole reason a canister launch is visible from a
        // kilometre away.
        makeBoosterPlume(scale: 1.0, direction: SCNVector3(0, 0, -1))
    }

    /// Solid-booster efflux. One shape for every rocket launch in the simulation —
    /// a canister muzzle, a rocket-assisted rail — because they are the same event.
    private func makeBoosterPlume(
        scale: Float,
        direction: SCNVector3 = SCNVector3(0, 0, 1)
    ) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.42, alpha: 0.95)
        system.particleColorVariation = SCNVector4(0.06, 0.22, 0.30, 0.20)
        system.particleSize = CGFloat(0.55 * scale)
        system.particleSizeVariation = CGFloat(0.35 * scale)
        system.birthRate = 900
        system.particleLifeSpan = 0.55
        system.particleLifeSpanVariation = 0.30
        system.emitterShape = SCNSphere(radius: CGFloat(0.16 * scale))
        system.spreadingAngle = 26
        system.particleVelocity = CGFloat(22.0 * scale)
        system.particleVelocityVariation = CGFloat(9.0 * scale)
        system.emittingDirection = direction
        system.acceleration = SCNVector3(0, 2.4, 0)
        system.isAffectedByGravity = false
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.loops = true
        return system
    }

    /// Turbojet exhaust. Not a rocket: no flame front, a much tighter cone, and it
    /// is a heat-haze bloom rather than a plume — but a jet whose tailpipe shows
    /// nothing at all while it accelerates reads as unpowered.
    private func makeJetExhaustPlume() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        // Small and dark. A turbojet's visible exhaust is a thin, sooty shimmer, not
        // a bright plume — that is the rocket booster's job, and the two must not
        // look alike or a launch stops reading as a launch. Alpha rather than
        // additive for the same reason: additive is what makes something glow.
        system.particleColor = NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.38, alpha: 0.24)
        system.particleColorVariation = SCNVector4(0.04, 0.04, 0.06, 0.08)
        system.particleSize = 0.07
        system.particleSizeVariation = 0.04
        system.birthRate = 0
        system.particleLifeSpan = 0.22
        system.particleLifeSpanVariation = 0.10
        system.emitterShape = SCNSphere(radius: 0.03)
        system.spreadingAngle = 5
        system.particleVelocity = 26
        system.particleVelocityVariation = 8
        system.emittingDirection = SCNVector3(0, 0, 1)
        system.isAffectedByGravity = false
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.loops = true
        return system
    }

    private func makeCatapultNode(for asset: CatapultLaunchAsset) -> SCNNode {
        let root = SCNNode()
        let railPitch = asset.rail.railAngleDegrees.degreesToRadians
        let railLength = max(2.0, asset.rail.railLengthMeters)
        let deckHeight = LaunchRigMetrics.catapultDeckHeight

        let steelMaterial = SCNMaterial()
        steelMaterial.diffuse.contents = NSColor(calibratedRed: 0.52, green: 0.55, blue: 0.57, alpha: 1.0)
        steelMaterial.roughness.contents = 0.38
        steelMaterial.metalness.contents = 0.72

        let frameMaterial = SCNMaterial()
        frameMaterial.diffuse.contents = NSColor(calibratedRed: 0.33, green: 0.37, blue: 0.33, alpha: 1.0)
        frameMaterial.roughness.contents = 0.58
        frameMaterial.metalness.contents = 0.42

        let railMaterial = SCNMaterial()
        railMaterial.diffuse.contents = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.27, alpha: 1.0)
        railMaterial.roughness.contents = 0.44
        railMaterial.metalness.contents = 0.86

        let shuttleMaterial = SCNMaterial()
        shuttleMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.96)
        shuttleMaterial.emission.contents = NSColor.systemOrange.withAlphaComponent(0.08)
        shuttleMaterial.roughness.contents = 0.46

        let rubberMaterial = SCNMaterial()
        rubberMaterial.diffuse.contents = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1.0)
        rubberMaterial.roughness.contents = 0.92

        let tankMaterial = SCNMaterial()
        tankMaterial.diffuse.contents = NSColor(calibratedRed: 0.62, green: 0.64, blue: 0.60, alpha: 1.0)
        tankMaterial.roughness.contents = 0.32
        tankMaterial.metalness.contents = 0.68

        // Point at travel distance `d` along the rail centreline (optionally
        // dropped vertically below it), expressed in root (ground) space.
        func railPoint(_ d: Float, drop: Float = 0.0) -> SIMD3<Float> {
            SIMD3<Float>(
                0.0,
                deckHeight + sin(railPitch) * d - drop,
                -cos(railPitch) * d
            )
        }

        // --- Trailer chassis under the low (start) end ---------------------
        for x: Float in [-0.34, 0.34] {
            let sideMember = SCNNode(geometry: SCNBox(
                width: 0.09, height: 0.14, length: 2.7, chamferRadius: 0.02
            ))
            sideMember.geometry?.materials = [frameMaterial]
            sideMember.simdPosition = SIMD3<Float>(x, 0.40, 0.15)
            root.addChildNode(sideMember)
        }
        for z: Float in [-1.05, 0.15, 1.35] {
            let crossMember = SCNNode(geometry: SCNBox(
                width: 0.72, height: 0.09, length: 0.09, chamferRadius: 0.02
            ))
            crossMember.geometry?.materials = [frameMaterial]
            crossMember.simdPosition = SIMD3<Float>(0.0, 0.40, z)
            root.addChildNode(crossMember)
        }

        let axle = SCNNode(geometry: SCNCylinder(radius: 0.035, height: 1.34))
        axle.geometry?.materials = [steelMaterial]
        axle.simdPosition = SIMD3<Float>(0.0, 0.30, 0.35)
        axle.eulerAngles.z = SCNFloat.pi / 2.0
        root.addChildNode(axle)

        for x: Float in [-0.62, 0.62] {
            let tire = SCNNode(geometry: SCNCylinder(radius: 0.30, height: 0.17))
            tire.geometry?.materials = [rubberMaterial]
            tire.simdPosition = SIMD3<Float>(x, 0.30, 0.35)
            tire.eulerAngles.z = SCNFloat.pi / 2.0
            root.addChildNode(tire)

            let hub = SCNNode(geometry: SCNCylinder(radius: 0.11, height: 0.19))
            hub.geometry?.materials = [steelMaterial]
            hub.simdPosition = SIMD3<Float>(x, 0.30, 0.35)
            hub.eulerAngles.z = SCNFloat.pi / 2.0
            root.addChildNode(hub)
        }

        // Tow drawbar with a hitch eye at the rear (+Z, away from launch).
        let drawbar = launchRigSegment(
            from: SIMD3<Float>(0.0, 0.40, 1.45),
            to: SIMD3<Float>(0.0, 0.30, 2.10),
            radius: 0.04,
            material: frameMaterial
        )
        root.addChildNode(drawbar)
        let hitchEye = SCNNode(geometry: SCNTorus(ringRadius: 0.07, pipeRadius: 0.022))
        hitchEye.geometry?.materials = [steelMaterial]
        hitchEye.simdPosition = SIMD3<Float>(0.0, 0.28, 2.18)
        root.addChildNode(hitchEye)

        // Rear stabiliser jacks so the trailer reads as deployed, not parked.
        for x: Float in [-0.34, 0.34] {
            let jack = SCNNode(geometry: SCNCylinder(radius: 0.028, height: 0.36))
            jack.geometry?.materials = [steelMaterial]
            jack.simdPosition = SIMD3<Float>(x, 0.18, -1.05)
            root.addChildNode(jack)
            let pad = SCNNode(geometry: SCNBox(
                width: 0.16, height: 0.03, length: 0.16, chamferRadius: 0.01
            ))
            pad.geometry?.materials = [frameMaterial]
            pad.simdPosition = SIMD3<Float>(x, 0.015, -1.05)
            root.addChildNode(pad)
        }

        // --- What drives the rail -------------------------------------------
        //
        // A pneumatic catapult stores its energy on the trailer, in receivers and a
        // manifold. A rocket-assisted rail stores none: the energy arrives with the
        // round, in a bottle strapped under it, and what the trailer needs instead
        // is a blast deflector so the efflux does not go into its own chassis.
        if asset.rail.usesRocketBooster {
            let deflector = SCNNode(geometry: SCNBox(
                width: 1.10, height: 0.90, length: 0.10, chamferRadius: 0.03
            ))
            deflector.geometry?.materials = [frameMaterial]
            deflector.simdPosition = SIMD3<Float>(0.0, deckHeight + 0.34, 0.86)
            deflector.eulerAngles.x = SCNFloat(-0.45)
            root.addChildNode(deflector)

            for x: Float in [-0.46, 0.46] {
                let brace = SCNNode(geometry: SCNBox(
                    width: 0.07, height: 0.07, length: 0.80, chamferRadius: 0.02
                ))
                brace.geometry?.materials = [steelMaterial]
                brace.simdPosition = SIMD3<Float>(x, deckHeight + 0.05, 1.02)
                root.addChildNode(brace)
            }
        } else {
            for x: Float in [-0.20, 0.20] {
                let receiver = SCNNode(geometry: SCNCylinder(radius: 0.14, height: 1.05))
                receiver.geometry?.materials = [tankMaterial]
                receiver.simdPosition = SIMD3<Float>(x, 0.60, 0.72)
                receiver.eulerAngles.x = SCNFloat.pi / 2.0
                root.addChildNode(receiver)
            }
            let manifold = SCNNode(geometry: SCNBox(
                width: 0.34, height: 0.20, length: 0.26, chamferRadius: 0.03
            ))
            manifold.geometry?.materials = [steelMaterial]
            manifold.simdPosition = SIMD3<Float>(0.0, 0.58, 1.32)
            root.addChildNode(manifold)
        }

        // --- Inclined launch rail ------------------------------------------
        let railAssembly = SCNNode()
        railAssembly.name = "catapult_rail_assembly"
        railAssembly.simdPosition = SIMD3<Float>(0.0, deckHeight, 0.0)
        railAssembly.eulerAngles.x = SCNFloat(railPitch)
        root.addChildNode(railAssembly)

        let railSpan = railLength + 0.55
        let railCenterZ = -(railLength - 0.25) * 0.5 - 0.15
        for x: Float in [-0.17, 0.17] {
            let rail = SCNNode(geometry: SCNBox(
                width: 0.07, height: 0.11, length: CGFloat(railSpan), chamferRadius: 0.012
            ))
            rail.geometry?.materials = [railMaterial]
            rail.simdPosition = SIMD3<Float>(x, -0.02, railCenterZ)
            railAssembly.addChildNode(rail)

            let flange = SCNNode(geometry: SCNBox(
                width: 0.10, height: 0.022, length: CGFloat(railSpan), chamferRadius: 0.008
            ))
            flange.geometry?.materials = [steelMaterial]
            flange.simdPosition = SIMD3<Float>(x, 0.045, railCenterZ)
            railAssembly.addChildNode(flange)
        }

        // Lower truss chord + verticals: box-truss silhouette under the rails.
        let chord = SCNNode(geometry: SCNBox(
            width: 0.06, height: 0.06, length: CGFloat(railSpan - 0.3), chamferRadius: 0.012
        ))
        chord.geometry?.materials = [railMaterial]
        chord.simdPosition = SIMD3<Float>(0.0, -0.26, railCenterZ)
        railAssembly.addChildNode(chord)

        let ribCount = max(4, Int(ceil(railLength / 0.62)))
        for index in 0...ribCount {
            let z = -railLength * (Float(index) / Float(ribCount))
            let rib = SCNNode(geometry: SCNBox(
                width: 0.42, height: 0.035, length: 0.06, chamferRadius: 0.008
            ))
            rib.geometry?.materials = [steelMaterial]
            rib.simdPosition = SIMD3<Float>(0.0, -0.085, z)
            railAssembly.addChildNode(rib)

            let post = SCNNode(geometry: SCNCylinder(radius: 0.016, height: 0.15))
            post.geometry?.materials = [steelMaterial]
            post.simdPosition = SIMD3<Float>(0.0, -0.18, z)
            railAssembly.addChildNode(post)
        }

        // Acceleration tube (pneumatic piston) slung between the chords.
        let tube = SCNNode(geometry: SCNCylinder(
            radius: 0.075, height: CGFloat(railLength * 0.92)
        ))
        tube.geometry?.materials = [tankMaterial]
        tube.simdPosition = SIMD3<Float>(0.0, -0.16, -railLength * 0.46)
        tube.eulerAngles.x = SCNFloat.pi / 2.0
        railAssembly.addChildNode(tube)

        // End bumper / shuttle arrestor at the tip.
        let bumper = SCNNode(geometry: SCNBox(
            width: 0.46, height: 0.17, length: 0.11, chamferRadius: 0.02
        ))
        bumper.geometry?.materials = [shuttleMaterial]
        bumper.simdPosition = SIMD3<Float>(0.0, 0.06, -railLength - 0.24)
        railAssembly.addChildNode(bumper)
        for x: Float in [-0.12, 0.12] {
            let absorber = SCNNode(geometry: SCNCylinder(radius: 0.025, height: 0.16))
            absorber.geometry?.materials = [steelMaterial]
            absorber.simdPosition = SIMD3<Float>(x, 0.06, -railLength - 0.14)
            absorber.eulerAngles.x = SCNFloat.pi / 2.0
            railAssembly.addChildNode(absorber)
        }

        // --- Launch shuttle (moved along -Z by rail progress) ---------------
        let shuttle = SCNNode()
        shuttle.name = "catapult_carriage"
        railAssembly.addChildNode(shuttle)

        let shuttlePlate = SCNNode(geometry: SCNBox(
            width: 0.46, height: 0.05, length: 0.46, chamferRadius: 0.015
        ))
        shuttlePlate.geometry?.materials = [shuttleMaterial]
        shuttlePlate.simdPosition = SIMD3<Float>(0.0, 0.075, 0.0)
        shuttle.addChildNode(shuttlePlate)

        for z: Float in [-0.14, 0.14] {
            for side: Float in [-1.0, 1.0] {
                let cradleArm = SCNNode(geometry: SCNBox(
                    width: 0.035, height: 0.17, length: 0.05, chamferRadius: 0.008
                ))
                cradleArm.geometry?.materials = [steelMaterial]
                cradleArm.simdPosition = SIMD3<Float>(side * 0.115, 0.16, z)
                cradleArm.eulerAngles.z = SCNFloat(side * 0.5)
                shuttle.addChildNode(cradleArm)
            }
        }

        let pusherPlate = SCNNode(geometry: SCNBox(
            width: 0.30, height: 0.17, length: 0.03, chamferRadius: 0.01
        ))
        pusherPlate.geometry?.materials = [shuttleMaterial]
        pusherPlate.simdPosition = SIMD3<Float>(0.0, 0.16, 0.235)
        shuttle.addChildNode(pusherPlate)

        if asset.rail.usesRocketBooster {
            // The bottle rides with the round and its nozzle points back down the
            // rail, which is where the flame goes.
            let bottle = SCNNode(geometry: SCNCylinder(radius: 0.085, height: 0.62))
            bottle.geometry?.materials = [tankMaterial]
            bottle.simdPosition = SIMD3<Float>(0.0, 0.10, 0.16)
            bottle.eulerAngles.x = SCNFloat.pi / 2.0
            shuttle.addChildNode(bottle)

            let nozzle = SCNNode(geometry: SCNCone(
                topRadius: 0.045, bottomRadius: 0.085, height: 0.14
            ))
            nozzle.geometry?.materials = [steelMaterial]
            nozzle.simdPosition = SIMD3<Float>(0.0, 0.10, 0.50)
            nozzle.eulerAngles.x = SCNFloat(-Float.pi / 2.0)
            shuttle.addChildNode(nozzle)

            let efflux = SCNNode()
            efflux.name = "catapult_booster_efflux"
            efflux.simdPosition = SIMD3<Float>(0.0, 0.10, 0.60)
            efflux.addParticleSystem(makeBoosterPlume(scale: 1.0))
            efflux.isHidden = true
            shuttle.addChildNode(efflux)
        }

        // --- Forward support legs under the high end ------------------------
        let legFraction: Float = 0.86
        let legAttach = railPoint(railLength * legFraction, drop: 0.10)
        for side: Float in [-1.0, 1.0] {
            let footPoint = SIMD3<Float>(
                side * 0.58,
                0.0,
                legAttach.z + 0.22
            )
            let leg = launchRigSegment(
                from: SIMD3<Float>(side * 0.13, legAttach.y - 0.06, legAttach.z),
                to: footPoint,
                radius: 0.032,
                material: steelMaterial
            )
            root.addChildNode(leg)

            let foot = SCNNode(geometry: SCNBox(
                width: 0.20, height: 0.035, length: 0.20, chamferRadius: 0.012
            ))
            foot.geometry?.materials = [frameMaterial]
            foot.simdPosition = SIMD3<Float>(footPoint.x, 0.018, footPoint.z)
            root.addChildNode(foot)
        }
        let legBrace = launchRigSegment(
            from: SIMD3<Float>(-0.42, 0.34, legAttach.z + 0.16),
            to: SIMD3<Float>(0.42, 0.34, legAttach.z + 0.16),
            radius: 0.022,
            material: steelMaterial
        )
        root.addChildNode(legBrace)

        // Diagonal brace from the chassis front to the rail mid-span.
        let midAttach = railPoint(railLength * 0.42, drop: 0.14)
        let diagonal = launchRigSegment(
            from: SIMD3<Float>(0.0, 0.42, -1.0),
            to: SIMD3<Float>(0.0, midAttach.y, midAttach.z),
            radius: 0.030,
            material: steelMaterial
        )
        root.addChildNode(diagonal)

        return root
    }

    /// The hand launch is presented purely first-person (see
    /// `activateHandLaunchPOV`): the operator is not modelled in the world
    /// and, per design, the launch spot carries no ground furniture either —
    /// the tactical map is the only place the drafted point is visualised.
    private func makeHandLaunchNode(for asset: HandLaunchAsset) -> SCNNode {
        SCNNode()
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

    // MARK: - Analytic environment raycast

    /// First hit along a ray against the environment's analytic collision catalog
    /// (`environmentObstacles`: tree trunk/canopy boxes, building boxes/meshes, fire-truck box…)
    /// plus the flat ground plane.
    ///
    /// This deliberately replaces SceneKit's `hitTestWithSegment` for the per-tick payload-camera/
    /// rangefinder/hose-nozzle distance queries: the render-scene hit test has to triangle-test
    /// every high-poly USDZ pine whose bounds the segment touches, measured at ~33ms per call
    /// through dense forest (the direct cause of the reported sim-wide FPS degradation — and
    /// `.closest` instead of `.all` did NOT fix it, SceneKit still visits every candidate).
    /// An analytic pass over the same proxies the flight model collides with costs microseconds.
    ///
    /// Trade-off: the ray sees collision proxies, not render meshes — non-collidable decorations
    /// (e.g. the SAR mannequin) are invisible to it, and a tree reads as its trunk/canopy boxes.
    /// That's the same world the drone physically flies against, so HUD distance readouts stay
    /// consistent with collision behavior.
    private func analyticEnvironmentRayHit(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float
    ) -> (distance: Float, obstacleID: UUID?)? {
        guard maxDistance > 0.0, simd_length_squared(direction) > 0.000001 else { return nil }
        let dir = simd_normalize(direction)
        var bestDistance = maxDistance
        var bestObstacleID: UUID?
        var hasHit = false

        // An imported mesh world replaces the flat plane entirely — it carries the terrain, the
        // water surface, the quaysides and every rooftop. Its own spatial index does the work, so
        // this stays a single call rather than the linear obstacle sweep below, which is the only
        // reason a three-quarter-million-triangle city is affordable on the per-tick sensor path.
        if let meshCollision {
            if let hit = meshCollision.raycast(
                origin: origin,
                direction: dir,
                maxDistance: bestDistance
            ) {
                bestDistance = hit.distance
                bestObstacleID = nil
                hasHit = true
            }
        } else {
            // Flat ground plane — same reference height the payload drop camera uses. Model
            // position (not `.presentation`): the ground never animates, so they're equal, but the
            // model read avoids the render-thread scene-lock sync `.presentation` forces.
            let groundY = max(Float(groundNode.position.y), 0.0)
            if dir.y < -0.0001 {
                let t = (groundY - origin.y) / dir.y
                if t > 0.0001, t < bestDistance {
                    bestDistance = t
                    bestObstacleID = nil
                    hasHit = true
                }
            }
        }

        // Only the obstacles along the ray, not the whole catalogue.
        //
        // The linear sweep this replaces was written when the catalogue was procedural scenery —
        // hundreds of items — and stayed correct but not affordable once an imported city started
        // publishing its ~20 000 buildings and trees into the same array: this runs several times
        // per tick for the rangefinder, the drop prediction and the hose. The index is keyed on the
        // planar footprint, so the query is the ray's XZ extent with a margin for obstacle radius;
        // the bounding-sphere reject below still does the exact work.
        let rayEnd = origin + dir * bestDistance
        let raySweptObstacles = environmentObstacleIndex.query(
            from: origin,
            to: rayEnd,
            margin: Self.analyticRayQueryMargin
        )

        for obstacle in raySweptObstacles {
            // Bounding-sphere reject before any narrow-phase math.
            let halfHeight = (obstacle.topY - obstacle.baseY) * 0.5
            let boundsCenter = SIMD3<Float>(
                obstacle.center.x,
                (obstacle.baseY + obstacle.topY) * 0.5,
                obstacle.center.z
            )
            let boundsRadius = sqrt(obstacle.radius * obstacle.radius + halfHeight * halfHeight)
            let toCenter = boundsCenter - origin
            let projection = simd_dot(toCenter, dir)
            if projection < -boundsRadius || projection - boundsRadius > bestDistance { continue }
            if simd_length_squared(toCenter) - projection * projection > boundsRadius * boundsRadius {
                continue
            }

            let hit: Float?
            if let triangles = obstacle.meshTriangles, !triangles.isEmpty {
                hit = rayMeshDistance(
                    origin: origin,
                    direction: dir,
                    maxDistance: bestDistance,
                    triangles: triangles
                )
            } else if let halfExtents = obstacle.planarHalfExtents {
                hit = rayBoxDistance(
                    origin: origin,
                    direction: dir,
                    obstacle: obstacle,
                    halfExtents: halfExtents
                )
            } else {
                hit = rayCylinderDistance(origin: origin, direction: dir, obstacle: obstacle)
            }
            if let hit, hit < bestDistance {
                bestDistance = hit
                bestObstacleID = obstacle.id
                hasHit = true
            }
        }

        return hasHit ? (bestDistance, bestObstacleID) : nil
    }

    /// Slab test against an upright yaw-rotated box (rotation convention matches
    /// `CollisionObstacle.rotate`/`rotatePlanar`). Returns entry distance, or nil when the ray
    /// misses or starts inside (no meaningful "distance to" reading from inside a proxy).
    private func rayBoxDistance(
        origin: SIMD3<Float>,
        direction dir: SIMD3<Float>,
        obstacle: CollisionObstacle,
        halfExtents: SIMD2<Float>
    ) -> Float? {
        let localOrigin = rotatePlanar(
            SIMD2<Float>(origin.x - obstacle.center.x, origin.z - obstacle.center.z),
            radians: -obstacle.yawRadians
        )
        let localDir = rotatePlanar(SIMD2<Float>(dir.x, dir.z), radians: -obstacle.yawRadians)

        var tMin: Float = 0.0
        var tMax = Float.greatestFiniteMagnitude

        func clipSlab(originC: Float, dirC: Float, minC: Float, maxC: Float) -> Bool {
            if abs(dirC) < 0.000001 {
                return originC >= minC && originC <= maxC
            }
            let inverse = 1.0 / dirC
            var t1 = (minC - originC) * inverse
            var t2 = (maxC - originC) * inverse
            if t1 > t2 { swap(&t1, &t2) }
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            return tMin <= tMax
        }

        guard clipSlab(originC: localOrigin.x, dirC: localDir.x, minC: -halfExtents.x, maxC: halfExtents.x),
              clipSlab(originC: localOrigin.y, dirC: localDir.y, minC: -halfExtents.y, maxC: halfExtents.y),
              clipSlab(originC: origin.y, dirC: dir.y, minC: obstacle.baseY, maxC: obstacle.topY) else {
            return nil
        }
        return tMin > 0.0001 ? tMin : nil
    }

    /// Capped-vertical-cylinder intersection (the default proxy shape for obstacles without
    /// explicit box extents or mesh triangles). Same inside-start semantics as `rayBoxDistance`.
    private func rayCylinderDistance(
        origin: SIMD3<Float>,
        direction dir: SIMD3<Float>,
        obstacle: CollisionObstacle
    ) -> Float? {
        var tMin: Float = 0.0
        var tMax = Float.greatestFiniteMagnitude

        if abs(dir.y) < 0.000001 {
            if origin.y < obstacle.baseY || origin.y > obstacle.topY { return nil }
        } else {
            let inverse = 1.0 / dir.y
            var t1 = (obstacle.baseY - origin.y) * inverse
            var t2 = (obstacle.topY - origin.y) * inverse
            if t1 > t2 { swap(&t1, &t2) }
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }

        let offsetX = origin.x - obstacle.center.x
        let offsetZ = origin.z - obstacle.center.z
        let planarA = dir.x * dir.x + dir.z * dir.z
        if planarA < 0.00000001 {
            if offsetX * offsetX + offsetZ * offsetZ > obstacle.radius * obstacle.radius {
                return nil
            }
        } else {
            let planarB = 2.0 * (offsetX * dir.x + offsetZ * dir.z)
            let planarC = offsetX * offsetX + offsetZ * offsetZ - obstacle.radius * obstacle.radius
            let discriminant = planarB * planarB - 4.0 * planarA * planarC
            if discriminant < 0.0 { return nil }
            let sqrtDiscriminant = sqrt(discriminant)
            var t1 = (-planarB - sqrtDiscriminant) / (2.0 * planarA)
            var t2 = (-planarB + sqrtDiscriminant) / (2.0 * planarA)
            if t1 > t2 { swap(&t1, &t2) }
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }

        return tMin > 0.0001 ? tMin : nil
    }

    /// Möller–Trumbore over an obstacle's mesh triangles (no backface culling — matches the old
    /// hit test's `backFaceCulling: false`), with each triangle's stored AABB as a prefilter.
    private func rayMeshDistance(
        origin: SIMD3<Float>,
        direction dir: SIMD3<Float>,
        maxDistance: Float,
        triangles: [CollisionMeshTriangle]
    ) -> Float? {
        var best: Float?
        let end = origin + dir * maxDistance
        let segmentMin = simd_min(origin, end)
        let segmentMax = simd_max(origin, end)

        for triangle in triangles {
            if triangle.maximum.x < segmentMin.x || triangle.minimum.x > segmentMax.x ||
                triangle.maximum.y < segmentMin.y || triangle.minimum.y > segmentMax.y ||
                triangle.maximum.z < segmentMin.z || triangle.minimum.z > segmentMax.z {
                continue
            }
            let edge1 = triangle.point1 - triangle.point0
            let edge2 = triangle.point2 - triangle.point0
            let pVector = simd_cross(dir, edge2)
            let determinant = simd_dot(edge1, pVector)
            if abs(determinant) < 0.0000001 { continue }
            let inverseDeterminant = 1.0 / determinant
            let tVector = origin - triangle.point0
            let u = simd_dot(tVector, pVector) * inverseDeterminant
            if u < 0.0 || u > 1.0 { continue }
            let qVector = simd_cross(tVector, edge1)
            let v = simd_dot(dir, qVector) * inverseDeterminant
            if v < 0.0 || u + v > 1.0 { continue }
            let t = simd_dot(edge2, qVector) * inverseDeterminant
            if t > 0.0001, t < (best ?? maxDistance) { best = t }
        }
        return best
    }

    func payloadCameraTargetDistance(maxDistance: Double) -> Double? {
        guard payloadCameraOpticsState.isAvailable,
              payloadCameraOpticsState.isPowered,
              let payloadCameraNode else {
            return nil
        }

        // Model transform, NOT `.presentation`: reading `.presentation` from the main thread
        // blocks on SceneKit's scene lock, which the render thread holds for most of each frame
        // while drawing the dense forest — measured at ~16ms (one full frame) per call. The rig
        // is kinematic and we set the drone/rig transform ourselves earlier in this same tick
        // (`update(with:...)`), so the model transform here is both stall-free AND more current
        // than the render thread's last-presented copy.
        let origin = payloadCameraNode.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(payloadCameraNode.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        guard simd_length_squared(forward) > 0.000001 else {
            return nil
        }

        let distanceLimit = max(1.0, Float(maxDistance))
        guard let hit = analyticEnvironmentRayHit(
            origin: origin,
            direction: forward,
            maxDistance: distanceLimit
        ) else {
            return nil
        }
        return Double(hit.distance)
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

    func attachFiberSpoolVisual(_ module: FiberSpoolModule) {
        removeFiberSpoolVisual()
        let node = FiberSpoolVisualFactory.build(reelClass: module.reelClass)
        node.simdPosition = SIMD3<Float>(0.0, -0.02, 0.09)
        applyCategoryBitMask(RenderCategory.mountedPayload, to: node)
        payloadMountNode.addChildNode(node)
        fiberSpoolVisualNode = node
    }

    func removeFiberSpoolVisual() {
        fiberSpoolVisualNode?.removeFromParentNode()
        fiberSpoolVisualNode = nil
    }

    /// First obstacle hit along the fiber's live leg — for the laid-line polyline's contact
    /// detection. Ground-plane hits are deliberately excluded (`obstacleID == nil`): fiber lying
    /// on the ground is its normal state, not a snag.
    func fiberSegmentObstacleHitDistance(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float
    ) -> Float? {
        guard let hit = analyticEnvironmentRayHit(
            origin: origin,
            direction: direction,
            maxDistance: maxDistance
        ), hit.obstacleID != nil else {
            return nil
        }
        return hit.distance
    }

    /// Renders the deployed fiber as a hairline line-strip through the polyline's checkpoints,
    /// with a subtle sag on the live leg (last segment) only — the fixed segments were laid under
    /// payout tension and read fine as straight runs. Rebuilt per call; at the checkpoint cap
    /// (~100 vertices) that's negligible against the frame budget.
    func updateFiberTetherVisual(points: [SIMD3<Float>]) {
        guard points.count >= 2 else {
            clearFiberTetherVisual()
            return
        }

        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(points.count + 6)
        for index in 0..<(points.count - 1) {
            vertices.append(SCNVector3(points[index]))
        }

        let legStart = points[points.count - 2]
        let legEnd = points[points.count - 1]
        let legLength = simd_distance(legStart, legEnd)
        let sagDepth = min(2.2, legLength * 0.05)
        let sagSamples = 6
        for step in 1...sagSamples {
            let t = Float(step) / Float(sagSamples)
            var point = legStart + (legEnd - legStart) * t
            point.y = max(0.04, point.y - sagDepth * sinf(.pi * t))
            vertices.append(SCNVector3(point))
        }

        var indices: [Int32] = []
        indices.reserveCapacity((vertices.count - 1) * 2)
        for index in 0..<(vertices.count - 1) {
            indices.append(Int32(index))
            indices.append(Int32(index + 1))
        }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        // A pale hairline, not literal 0.28mm black — a real fiber would be invisible at any
        // camera distance, and the player needs to see where their line lies.
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.8, alpha: 0.55)
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        fiberTetherPathNode.geometry = geometry
    }

    func clearFiberTetherVisual() {
        fiberTetherPathNode.geometry = nil
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

    /// Fires one capsule from the (still-mounted) fire-capsule launcher — deliberately independent
    /// of `releasePayloadVisual()` above: that function's whole design is single-ownership (attach
    /// once, drop once, the payload is gone for good), while the launcher stays mounted and this
    /// gets called repeatedly, once per remaining round of ammo. The fall kinematics are the same
    /// technique (constant-gravity `SCNAction.customAction`, no real physics body) but kept as an
    /// independent copy rather than a shared refactor, to avoid touching the already-proven
    /// cargo/hose drop path at all.
    @discardableResult
    func dropFireCapsule(size: FireCapsuleSize, onImpact: @escaping (SIMD3<Float>) -> Void) -> UUID {
        let dropID = UUID()
        let capsuleNode = makeFireCapsuleProjectileNode()
        let startPosition = payloadMountNode.presentation.simdWorldPosition
        capsuleNode.simdWorldPosition = startPosition
        scene.rootNode.addChildNode(capsuleNode)
        applyCategoryBitMask(RenderCategory.droppedPayload, to: capsuleNode)
        fireCapsuleDropNodes[dropID] = capsuleNode

        let landedY = min(startPosition.y, max(Float(groundNode.presentation.position.y) + 0.04, 0.04))
        let dropHeight = max(0.0, startPosition.y - landedY)
        let gravity: Float = 9.8
        let unconstrainedDuration = sqrt(max(0.0001, (2.0 * dropHeight) / gravity))
        let fallDuration = Double(dropHeight > 0.01 ? unconstrainedDuration.clamped(to: 0.18...8.0) : 0.08)

        let fallAction = SCNAction.customAction(duration: fallDuration) { node, elapsedTime in
            let elapsed = Float(elapsedTime)
            let distance = min(dropHeight, 0.5 * gravity * elapsed * elapsed)
            let nextY = max(landedY, startPosition.y - distance)
            node.simdWorldPosition = SIMD3<Float>(startPosition.x, nextY, startPosition.z)
        }

        let landedAction = SCNAction.run { [weak self] _ in
            guard let self else { return }
            let impactPosition = SIMD3<Float>(startPosition.x, landedY, startPosition.z)
            capsuleNode.simdWorldPosition = impactPosition
            self.spawnFireCapsuleBurstVisual(at: impactPosition, blastRadiusMeters: size.blastRadiusMeters)
            // `SCNAction.run` closures are NOT guaranteed to execute on the main thread (same
            // hazard as `SCNSceneRendererDelegate.renderer(_:updateAtTime:)`, see
            // `handleSceneRenderFrame`'s own hop for the same reason). `onImpact` mutates the view
            // model's `@Published` state — calling it directly here caused exactly the crash this
            // comment is warning about: Combine's "Publishing changes from background threads is
            // not allowed" + the app hanging with the main thread stuck in `__ulock_wait2`,
            // contending with a background thread for the same object's internal lock. Hopping to
            // the main thread here, at the one place this closure is actually invoked from a
            // non-main context, is more robust than trusting every future caller to hop themselves.
            DispatchQueue.main.async {
                onImpact(impactPosition)
            }
        }

        let cleanupAction = SCNAction.run { [weak self, weak capsuleNode] _ in
            capsuleNode?.removeAllActions()
            capsuleNode?.removeFromParentNode()
            self?.fireCapsuleDropNodes.removeValue(forKey: dropID)
        }

        capsuleNode.runAction(
            .sequence([fallAction, landedAction, .wait(duration: 0.5), cleanupAction]),
            forKey: "fireCapsuleDropLifecycle"
        )

        return dropID
    }

    private func makeFireCapsuleProjectileNode() -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        material.roughness.contents = 0.3
        material.metalness.contents = 0.1

        let sphere = SCNSphere(radius: 0.06)
        sphere.firstMaterial = material

        let node = SCNNode(geometry: sphere)
        node.name = "mission.fire_capsule.projectile"
        node.castsShadow = true
        return node
    }

    private func spawnFireCapsuleBurstVisual(at position: SIMD3<Float>, blastRadiusMeters: Float) {
        let burst = FireVisualAssetLoader.shared.makeCapsuleBurstNode(blastRadiusMeters: blastRadiusMeters)
        burst.simdPosition = position
        missionScenarioRootNode.addChildNode(burst)
    }

    /// Ground-projected reticle showing where a dropped capsule would land and how large its
    /// blast radius is — real 3D scene geometry (mirroring `setMissionDropZone`'s exact technique),
    /// not a screen-space camera overlay, so it's visible from every camera mode automatically
    /// with none of the render-category/shadow-quality/blur coupling a dedicated payload-optics
    /// camera mode would need. `dronePlanarPosition == nil` hides it (no capsule launcher mounted).
    func setFireCapsuleTargetReticle(dronePlanarPosition: SIMD2<Float>?, radiusMeters: Float) {
        guard let dronePlanarPosition else {
            fireCapsuleTargetReticleNode?.isHidden = true
            return
        }

        let node: SCNNode
        if let existing = fireCapsuleTargetReticleNode {
            node = existing
        } else {
            node = SCNNode()
            node.name = "mission.fire_capsule.target_reticle"

            let ringMaterial = SCNMaterial()
            ringMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.65)
            ringMaterial.emission.contents = NSColor.systemOrange.withAlphaComponent(0.35)
            ringMaterial.lightingModel = .constant
            ringMaterial.isDoubleSided = true
            let ringNode = SCNNode(geometry: SCNTorus(ringRadius: 1.0, pipeRadius: 0.05))
            ringNode.geometry?.firstMaterial = ringMaterial
            ringNode.name = "mission.fire_capsule.target_reticle.ring"
            ringNode.castsShadow = false
            node.addChildNode(ringNode)
            fireCapsuleTargetReticleRingNode = ringNode

            let discMaterial = SCNMaterial()
            discMaterial.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.14)
            discMaterial.lightingModel = .constant
            discMaterial.isDoubleSided = true
            discMaterial.writesToDepthBuffer = false
            let discNode = SCNNode(geometry: SCNCylinder(radius: 1.0, height: 0.006))
            discNode.geometry?.firstMaterial = discMaterial
            discNode.name = "mission.fire_capsule.target_reticle.disc"
            discNode.castsShadow = false
            node.addChildNode(discNode)
            fireCapsuleTargetReticleDiscNode = discNode

            missionScenarioRootNode.addChildNode(node)
            fireCapsuleTargetReticleNode = node
        }

        (fireCapsuleTargetReticleRingNode?.geometry as? SCNTorus)?.ringRadius = CGFloat(radiusMeters)
        (fireCapsuleTargetReticleDiscNode?.geometry as? SCNCylinder)?.radius = CGFloat(radiusMeters)

        let groundY = max(Float(groundNode.presentation.position.y) + 0.03, 0.03)
        node.simdPosition = SIMD3<Float>(dronePlanarPosition.x, groundY, dronePlanarPosition.y)
        node.isHidden = false
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
        for node in fireCapsuleDropNodes.values {
            node.removeAllActions()
            node.removeFromParentNode()
        }
        droppedPayloadNodes.removeAll(keepingCapacity: false)
        droppedPayloadRuntime.removeAll(keepingCapacity: false)
        payloadImpactNodes.removeAll(keepingCapacity: false)
        fireCapsuleDropNodes.removeAll(keepingCapacity: false)
        fireCapsuleTargetReticleNode?.removeFromParentNode()
        fireCapsuleTargetReticleNode = nil
        fireCapsuleTargetReticleRingNode = nil
        fireCapsuleTargetReticleDiscNode = nil
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

    /// Starts a short blend from whatever `oldMode`'s camera was showing toward the point of
    /// view `CameraConfiguration.mode` resolves to once the caller applies its already-decided
    /// mode change — call this *before* flipping the mode (it captures the "from" transform right
    /// now), the per-frame update in `updateCameras` then resolves the "to" transform live each
    /// frame off the (by-then-new) mode. Deliberately scoped to the zoom-triggered FPV
    /// engage/exit (see `DroneSimulationViewModel.engageFPVFromZoom`/`exitFPVFromZoom`) rather
    /// than every mode switch — `cycleCameraMode`/camera presets keep their existing instant cut.
    func beginCameraTransition(from oldMode: CameraMode, duration: Float = 0.35) {
        cameraTransitionFromNode = resolvedPointOfView(for: oldMode)
        cameraTransitionElapsed = 0.0
        cameraTransitionDuration = max(0.05, duration)
        cameraTransitionActive = true
    }

    func obstacleSourceLabel(for id: UUID) -> String? {
        obstacleSourceByID[id]
    }

    func sceneDiagnostics() -> (activeObjectCount: Int, activePhysicsBodyCount: Int, activeParticleCount: Int) {
        let objects = obstacleMap.count + wingmanVisuals.count + detachedVehiclePartNodes.count + 1
        let bodyCount = (droneCollisionProxyNode.physicsBody == nil ? 0 : 1) +
            detachedVehiclePartNodes.values.reduce(into: 0) { count, node in
                if node.physicsBody != nil { count += 1 }
            }
        let particleCount = Int((rainSystem?.birthRate ?? 0) + (snowSystem?.birthRate ?? 0))
        return (objects, bodyCount, particleCount)
    }

    /// Spawns a SceneKit rigid body for a subtree already detached by the
    /// authoritative component graph. Inherited angular velocity is expected
    /// in the vehicle body frame. An impact may override both velocities with
    /// the post-fracture world-space solution calculated at the failed joint.
    func spawnDetachedVehiclePart(
        _ part: VehicleDetachedSubtree,
        retainedLegacyComponents: Set<DamageComponent>,
        vehicleWorldPosition: SIMD3<Float>,
        vehicleOrientation: simd_quatf,
        inheritedVelocity: SIMD3<Float>,
        inheritedAngularVelocity: SIMD3<Float>,
        initialCenterOfMassVelocityWorld: SIMD3<Float>? = nil,
        initialAngularVelocityWorld: SIMD3<Float>? = nil
    ) {
        let key = part.rootComponentID
        if let existingNode = detachedVehiclePartNodes.removeValue(forKey: key) {
            existingNode.removeAllActions()
            existingNode.removeFromParentNode()
        }
        detachedVehiclePartCollisionRuntime.removeValue(forKey: key)

        // A fixed-wing root and outer section can share one legacy visual
        // node. Only clone/hide that full node when every graph component
        // represented by it left the airframe; otherwise use the subtree's
        // physical fallback bounds for the fragment and retain the root.
        let fullyDetachedLegacyComponents = part.legacyComponents
            .subtracting(retainedLegacyComponents)
        let sourceNodes = detachedVisualSourceNodes(for: fullyDetachedLegacyComponents)
        detachedVehicleComponentIDs.formUnion(part.componentIDs)
        detachedVehicleLegacyComponents.formUnion(fullyDetachedLegacyComponents)

        let minimumHalfExtent: Float = 0.018
        let halfExtents = simd_max(
            part.localBoundsHalfExtents,
            SIMD3<Float>(repeating: minimumHalfExtent)
        )
        let box = SCNBox(
            width: CGFloat(halfExtents.x * 2.0),
            height: CGFloat(halfExtents.y * 2.0),
            length: CGFloat(halfExtents.z * 2.0),
            chamferRadius: CGFloat(min(halfExtents.x, halfExtents.y, halfExtents.z) * 0.08)
        )
        box.materials = [detachedVehiclePartFallbackMaterial()]

        let partNode = SCNNode()
        partNode.name = "detachedVehiclePart.\(key)"
        partNode.simdPosition = vehicleWorldPosition +
            simd_act(vehicleOrientation, part.localBoundsCenter)
        partNode.simdOrientation = vehicleOrientation
        detachedVehiclePartsRootNode.addChildNode(partNode)

        let partWorldTransformInverse = simd_inverse(partNode.simdWorldTransform)
        var installedVisualClone = false
        for sourceNode in sourceNodes {
            let sourceWorldTransform = sourceNode.presentation.simdWorldTransform
            let clone = sourceNode.clone()
            prepareDetachedVehiclePartClone(clone)
            clone.simdTransform = simd_mul(partWorldTransformInverse, sourceWorldTransform)
            partNode.addChildNode(clone)
            installedVisualClone = true
        }
        if !installedVisualClone {
            partNode.geometry = box
        }

        let shape = SCNPhysicsShape(
            geometry: box,
            options: [SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.boundingBox]
        )
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = CGFloat(max(0.005, part.massProperties.totalMassKg))
        body.centerOfMassOffset = SCNVector3(
            part.massProperties.centerOfMassOffset.x - part.localBoundsCenter.x,
            part.massProperties.centerOfMassOffset.y - part.localBoundsCenter.y,
            part.massProperties.centerOfMassOffset.z - part.localBoundsCenter.z
        )
        body.usesDefaultMomentOfInertia = false
        body.momentOfInertia = SCNVector3(
            max(0.000_01, part.massProperties.inertiaDiagonal.x),
            max(0.000_01, part.massProperties.inertiaDiagonal.y),
            max(0.000_01, part.massProperties.inertiaDiagonal.z)
        )
        body.isAffectedByGravity = true
        body.allowsResting = true
        body.friction = 0.72
        body.rollingFriction = 0.18
        body.restitution = 0.14
        body.damping = 0.035
        body.angularDamping = 0.055
        body.continuousCollisionDetectionThreshold = CGFloat(
            max(0.008, min(halfExtents.x, halfExtents.y, halfExtents.z) * 0.35)
        )
        // Manual environment geometry is resolved analytically below. Keeping
        // the `.drone` bit here would also activate abandoned-city SceneKit
        // mesh bodies (their masks target `.drone`) and apply the same impact
        // twice. Ground and debris/debris contacts use the dedicated bit.
        body.categoryBitMask = PhysicsCategory.detachedVehiclePart
        body.collisionBitMask = PhysicsCategory.environment | PhysicsCategory.detachedVehiclePart | PhysicsCategory.drone
        body.contactTestBitMask = PhysicsCategory.environment | PhysicsCategory.detachedVehiclePart | PhysicsCategory.drone

        let worldAngularVelocity = initialAngularVelocityWorld ??
            simd_act(vehicleOrientation, inheritedAngularVelocity)
        let worldCenterOfMassOffset = simd_act(
            vehicleOrientation,
            part.massProperties.centerOfMassOffset
        )
        let centerOfMassVelocity = initialCenterOfMassVelocityWorld ?? (
            inheritedVelocity + simd_cross(worldAngularVelocity, worldCenterOfMassOffset)
        )
        body.velocity = SCNVector3(
            centerOfMassVelocity.x,
            centerOfMassVelocity.y,
            centerOfMassVelocity.z
        )
        let angularSpeed = simd_length(worldAngularVelocity)
        if angularSpeed > 0.0001 {
            let axis = worldAngularVelocity / angularSpeed
            body.angularVelocity = SCNVector4(axis.x, axis.y, axis.z, angularSpeed)
        }
        partNode.physicsBody = body
        detachedVehiclePartNodes[key] = partNode
        let contactSpheres = detachedPartContactSpheres(
            rootComponentID: key,
            halfExtents: halfExtents
        )
        let boundingRadius = contactSpheres.reduce(Float(0.0)) { partial, sphere in
            max(partial, simd_length(sphere.offset) + sphere.radius)
        }
        detachedVehiclePartCollisionRuntime[key] = DetachedVehiclePartCollisionRuntime(
            contactSpheres: contactSpheres,
            boundingRadius: boundingRadius,
            massKg: max(0.005, part.massProperties.totalMassKg),
            inertiaDiagonal: simd_max(
                part.massProperties.inertiaDiagonal,
                SIMD3<Float>(repeating: 0.000_01)
            ),
            localCenterOfMassOffset: part.massProperties.centerOfMassOffset -
                part.localBoundsCenter,
            detachedComponentIDs: part.componentIDs.sorted(),
            previousWorldPosition: partNode.simdWorldPosition,
            previousWorldOrientation: partNode.simdWorldOrientation,
            lastColliderID: nil
        )

        for legacyComponent in fullyDetachedLegacyComponents {
            for sourceNode in componentNodes[legacyComponent] ?? [] {
                detachedVehicleVisualNodeIDs.insert(ObjectIdentifier(sourceNode))
                sourceNode.isHidden = true
            }
        }
        lastComponentOverlaySignature = nil

        let cleanup = SCNAction.run { [weak self, weak partNode] _ in
            guard let self, let partNode else { return }
            if self.detachedVehiclePartNodes[key] === partNode {
                self.detachedVehiclePartNodes.removeValue(forKey: key)
                self.detachedVehiclePartCollisionRuntime.removeValue(forKey: key)
            }
            partNode.removeFromParentNode()
        }
        partNode.runAction(.sequence([
            .wait(duration: 28.0),
            .fadeOut(duration: 2.0),
            cleanup
        ]), forKey: "detachedVehiclePart.autoCleanup")
    }

    /// Clears transient debris and allows the current damage overlay to
    /// restore visibility on the next scene update (used on reset/profile change).
    func clearDetachedVehicleParts() {
        for node in detachedVehiclePartNodes.values {
            node.removeAllActions()
            node.removeFromParentNode()
        }
        detachedVehiclePartNodes.removeAll()
        detachedVehiclePartCollisionRuntime.removeAll()
        pendingDetachedVehiclePartImpactEvents.removeAll(keepingCapacity: false)

        let previouslyHiddenNodeIDs = detachedVehicleVisualNodeIDs
        detachedVehicleComponentIDs.removeAll()
        detachedVehicleLegacyComponents.removeAll()
        detachedVehicleVisualNodeIDs.removeAll()
        retainedVehicleSectionProxiesNode.childNodes.forEach { $0.removeFromParentNode() }
        for nodes in componentNodes.values {
            for node in nodes where previouslyHiddenNodeIDs.contains(ObjectIdentifier(node)) {
                node.isHidden = false
            }
        }
        lastComponentOverlaySignature = nil
    }

    /// Battery thermal-runaway/rupture consequence: a small flame (reusing the Fire Response
    /// flame flipbook) plus rising smoke, parented under the drone's own node at the battery
    /// component's local position so it tracks the airframe — including a post-crash tumble —
    /// without per-tick repositioning. Flame and smoke are driven independently so the caller can
    /// let the flame burn out first and the smoke linger, matching how a real LiPo fire behaves.
    /// Nodes are created once and reused; call with both flags false (or `clearBatteryFireVisual`)
    /// to tear them down.
    func updateBatteryFireVisual(flameActive: Bool, smokeActive: Bool, localPosition: SIMD3<Float>) {
        guard flameActive || smokeActive else {
            clearBatteryFireVisual()
            return
        }
        let position = SCNVector3(localPosition.x, localPosition.y, localPosition.z)
        if batteryFireFlameNode == nil {
            let flame = FireVisualAssetLoader.shared.makeFlameNode(heightMeters: 0.4)
            flame.name = "batteryFire.flame"
            flame.position = position
            droneNode.addChildNode(flame)
            batteryFireFlameNode = flame
        }
        if batteryFireSmokeNode == nil {
            let smoke = FireVisualAssetLoader.shared.makeSmokeNode()
            smoke.name = "batteryFire.smoke"
            smoke.position = position
            droneNode.addChildNode(smoke)
            batteryFireSmokeNode = smoke
        }
        if let flame = batteryFireFlameNode {
            flame.isHidden = !flameActive
            FireVisualAssetLoader.shared.setFlameAnimating(flame, isAnimating: flameActive)
        }
        if let smoke = batteryFireSmokeNode {
            smoke.isHidden = !smokeActive
            FireVisualAssetLoader.shared.setSmokeActive(smoke, isActive: smokeActive)
        }
    }

    /// Tears down the battery-fire nodes (reset/profile change/graph rebuild) — mirrors
    /// `clearDetachedVehicleParts`.
    func clearBatteryFireVisual() {
        if let flame = batteryFireFlameNode {
            FireVisualAssetLoader.shared.setFlameAnimating(flame, isAnimating: false)
            flame.removeFromParentNode()
            batteryFireFlameNode = nil
        }
        if let smoke = batteryFireSmokeNode {
            FireVisualAssetLoader.shared.setSmokeActive(smoke, isActive: false)
            smoke.removeFromParentNode()
            batteryFireSmokeNode = nil
        }
    }

    /// Reconciles indivisible legacy meshes with the graph after one or more
    /// subtrees detach. Normal, independently mapped source nodes keep their
    /// original high-detail geometry. Shared or partially detached nodes are
    /// hidden and only their still-attached physical sections are redrawn.
    func reconcileDetachedVehicleVisuals(_ graph: VehicleComponentGraph) {
        retainedVehicleSectionProxiesNode.childNodes.forEach { $0.removeFromParentNode() }
        if retainedVehicleSectionProxiesNode.parent !== visualRootNode {
            retainedVehicleSectionProxiesNode.removeFromParentNode()
            visualRootNode.addChildNode(retainedVehicleSectionProxiesNode)
        }

        let attachedLegacy = Set(graph.attachedComponents.compactMap(\.legacyComponent))
        let detachedLegacy = Set(
            graph.components.lazy
                .filter { !$0.isAttached }
                .compactMap(\.legacyComponent)
        )
        let partiallyDetachedLegacy = attachedLegacy.intersection(detachedLegacy)
        var proxyLegacy = partiallyDetachedLegacy

        // A node may be registered in both armFL and armFR (or both tail
        // buckets). If any of its owners detached, the mesh cannot represent
        // the remaining topology and must be replaced for every retained owner.
        var ownersByNodeID: [ObjectIdentifier: Set<DamageComponent>] = [:]
        var nodeByID: [ObjectIdentifier: SCNNode] = [:]
        for (legacy, nodes) in componentNodes {
            for node in nodes {
                let id = ObjectIdentifier(node)
                ownersByNodeID[id, default: []].insert(legacy)
                nodeByID[id] = node
            }
        }
        for (nodeID, owners) in ownersByNodeID {
            let hasDetachedOwner = !owners.intersection(detachedLegacy).isEmpty
            let retainedOwners = owners.intersection(attachedLegacy)
            guard hasDetachedOwner, !retainedOwners.isEmpty,
                  let node = nodeByID[nodeID] else { continue }
            node.isHidden = true
            detachedVehicleVisualNodeIDs.insert(nodeID)
            proxyLegacy.formUnion(retainedOwners)
        }

        for legacy in partiallyDetachedLegacy {
            for node in componentNodes[legacy] ?? [] {
                node.isHidden = true
                detachedVehicleVisualNodeIDs.insert(ObjectIdentifier(node))
            }
        }

        for component in graph.attachedComponents
        where component.kind.isStructural {
            guard let legacy = component.legacyComponent,
                  proxyLegacy.contains(legacy) else { continue }

            let halfExtents = simd_max(
                component.boundingHalfExtents,
                SIMD3<Float>(repeating: 0.006)
            )
            let geometry = SCNBox(
                width: CGFloat(halfExtents.x * 2.0),
                height: CGFloat(halfExtents.y * 2.0),
                length: CGFloat(halfExtents.z * 2.0),
                chamferRadius: CGFloat(min(halfExtents.x, halfExtents.y, halfExtents.z) * 0.08)
            )
            if let sourceMaterial = componentNodes[legacy]?
                .lazy
                .compactMap({ $0.geometry?.firstMaterial })
                .first,
               let material = sourceMaterial.copy() as? SCNMaterial {
                geometry.materials = [material]
            } else {
                geometry.materials = [detachedVehiclePartFallbackMaterial()]
            }

            let proxy = SCNNode(geometry: geometry)
            proxy.name = "retainedVehicleSection.\(component.id)"
            proxy.simdPosition = component.localPosition + component.deformation.translationMeters
            let bend = component.deformation.bendRadians
            let bendMagnitude = simd_length(bend)
            if bendMagnitude > 0.0001 {
                proxy.simdOrientation = simd_quatf(
                    angle: min(Float(25.0).degreesToRadians, bendMagnitude),
                    axis: bend / bendMagnitude
                )
            }
            retainedVehicleSectionProxiesNode.addChildNode(proxy)
        }
        lastComponentOverlaySignature = nil
    }

    func consumeDetachedVehiclePartImpactEvents() -> [DetachedVehiclePartImpactEvent] {
        let events = pendingDetachedVehiclePartImpactEvents
        pendingDetachedVehiclePartImpactEvents.removeAll(keepingCapacity: true)
        return events
    }

    /// A short chain of spheres encloses the detached part's fallback box.
    /// It stays compact for long wings/arms while retaining the same analytic
    /// box/cylinder/mesh narrow phase as the main aircraft.
    private func detachedPartContactSpheres(
        rootComponentID: String,
        halfExtents: SIMD3<Float>
    ) -> [VehicleContactSphere] {
        let dominantAxis: Int
        if halfExtents.x >= halfExtents.y, halfExtents.x >= halfExtents.z {
            dominantAxis = 0
        } else if halfExtents.y >= halfExtents.z {
            dominantAxis = 1
        } else {
            dominantAxis = 2
        }

        let dominantHalfExtent = halfExtents[dominantAxis]
        let crossAxes = (0..<3).filter { $0 != dominantAxis }
        let crossRadius = sqrt(
            halfExtents[crossAxes[0]] * halfExtents[crossAxes[0]] +
            halfExtents[crossAxes[1]] * halfExtents[crossAxes[1]]
        )
        let sphereCount = min(
            7,
            max(1, Int((dominantHalfExtent / max(0.025, crossRadius)).rounded(.up)))
        )
        let intervalLength = dominantHalfExtent * 2.0 / Float(sphereCount)
        let radius = max(
            0.022,
            sqrt(crossRadius * crossRadius + intervalLength * intervalLength * 0.25)
        )

        return (0..<sphereCount).map { index in
            var offset = SIMD3<Float>(repeating: 0.0)
            offset[dominantAxis] = -dominantHalfExtent +
                intervalLength * (Float(index) + 0.5)
            return VehicleContactSphere(
                componentID: rootComponentID,
                offset: offset,
                radius: radius
            )
        }
    }

    private func updateDetachedVehiclePartObstacleCollisions(deltaTime: Float) {
        guard deltaTime > 0.0, !detachedVehiclePartCollisionRuntime.isEmpty else { return }

        for key in detachedVehiclePartCollisionRuntime.keys.sorted() {
            guard let node = detachedVehiclePartNodes[key],
                  let body = node.physicsBody,
                  var runtime = detachedVehiclePartCollisionRuntime[key] else {
                detachedVehiclePartCollisionRuntime.removeValue(forKey: key)
                continue
            }

            runtime.impactCooldownRemaining = max(
                0.0,
                runtime.impactCooldownRemaining - deltaTime
            )
            let currentNode = node.presentation
            let currentPosition = currentNode.simdWorldPosition
            let currentOrientation = currentNode.simdWorldOrientation
            let candidates = nearbyEnvironmentObstacles(
                from: runtime.previousWorldPosition,
                to: currentPosition,
                margin: runtime.boundingRadius
            )

            guard let contact = detachedVehiclePartCollisionService.firstSweptVehicleCollision(
                contactSpheres: runtime.contactSpheres,
                fromPosition: runtime.previousWorldPosition,
                toPosition: currentPosition,
                fromOrientation: runtime.previousWorldOrientation,
                toOrientation: currentOrientation,
                obstacles: candidates
            ) else {
                runtime.previousWorldPosition = currentPosition
                runtime.previousWorldOrientation = currentOrientation
                detachedVehiclePartCollisionRuntime[key] = runtime
                continue
            }

            let normal = simd_length_squared(contact.contactNormal) > 0.0001
                ? simd_normalize(contact.contactNormal)
                : SIMD3<Float>(0.0, 1.0, 0.0)
            let velocity = SIMD3<Float>(
                Float(body.velocity.x),
                Float(body.velocity.y),
                Float(body.velocity.z)
            )
            let rawAngularAxis = SIMD3<Float>(
                Float(body.angularVelocity.x),
                Float(body.angularVelocity.y),
                Float(body.angularVelocity.z)
            )
            let angularVelocity = simd_length_squared(rawAngularAxis) > 0.0001
                ? simd_normalize(rawAngularAxis) * Float(body.angularVelocity.w)
                : SIMD3<Float>(repeating: 0.0)
            let worldCenterOfMass = currentPosition + simd_act(
                currentOrientation,
                runtime.localCenterOfMassOffset
            )
            let contactLever = contact.contactPoint - worldCenterOfMass
            let contactVelocity = velocity + simd_cross(angularVelocity, contactLever)
            let closingSpeed = max(0.0, -simd_dot(contactVelocity, normal))
            let correctedPosition = runtime.previousWorldPosition +
                (currentPosition - runtime.previousWorldPosition) * contact.hitFraction +
                normal * 0.003
            node.simdWorldPosition = correctedPosition
            body.resetTransform()

            if closingSpeed > 0.02 {
                let restitution: Float = 0.14
                let leverCrossNormal = simd_cross(contactLever, normal)
                let leverCrossNormalLocal = simd_act(
                    currentOrientation.inverse,
                    leverCrossNormal
                )
                let inverseInertia = SIMD3<Float>(
                    1.0 / runtime.inertiaDiagonal.x,
                    1.0 / runtime.inertiaDiagonal.y,
                    1.0 / runtime.inertiaDiagonal.z
                )
                let effectiveMassDenominator = max(
                    0.000_01,
                    1.0 / runtime.massKg + simd_dot(
                        leverCrossNormalLocal * inverseInertia,
                        leverCrossNormalLocal
                    )
                )
                let impulse = (1.0 + restitution) * closingSpeed /
                    effectiveMassDenominator
                let normalImpulse = normal * impulse
                var outgoingVelocity = velocity + normalImpulse / runtime.massKg
                let angularImpulseLocal = simd_act(
                    currentOrientation.inverse,
                    simd_cross(contactLever, normalImpulse)
                )
                let outgoingAngularVelocity = angularVelocity + simd_act(
                    currentOrientation,
                    angularImpulseLocal * inverseInertia
                )
                let outgoingNormalVelocity = normal * simd_dot(outgoingVelocity, normal)
                let outgoingTangentVelocity = outgoingVelocity - outgoingNormalVelocity
                outgoingVelocity = outgoingNormalVelocity + outgoingTangentVelocity * 0.82
                body.velocity = SCNVector3(
                    outgoingVelocity.x,
                    outgoingVelocity.y,
                    outgoingVelocity.z
                )
                let outgoingAngularSpeed = simd_length(outgoingAngularVelocity)
                if outgoingAngularSpeed > 0.0001 {
                    let outgoingAngularAxis = outgoingAngularVelocity / outgoingAngularSpeed
                    body.angularVelocity = SCNVector4(
                        outgoingAngularAxis.x,
                        outgoingAngularAxis.y,
                        outgoingAngularAxis.z,
                        outgoingAngularSpeed
                    )
                } else {
                    body.angularVelocity = SCNVector4(0.0, 0.0, 0.0, 0.0)
                }

                let shouldReport = closingSpeed >= 0.18 &&
                    (runtime.lastColliderID != contact.obstacle.id ||
                     runtime.impactCooldownRemaining <= 0.0)
                if shouldReport {
                    pendingDetachedVehiclePartImpactEvents.append(
                        DetachedVehiclePartImpactEvent(
                            rootComponentID: key,
                            detachedComponentIDs: runtime.detachedComponentIDs,
                            colliderID: contact.obstacle.id,
                            colliderSource: contact.obstacle.source,
                            worldPoint: contact.contactPoint,
                            impulseNs: impulse,
                            energyJ: 0.5 / effectiveMassDenominator *
                                closingSpeed * closingSpeed
                        )
                    )
                    runtime.lastColliderID = contact.obstacle.id
                    runtime.impactCooldownRemaining = 0.12
                }
            }

            runtime.previousWorldPosition = correctedPosition
            runtime.previousWorldOrientation = currentOrientation
            detachedVehiclePartCollisionRuntime[key] = runtime
        }
    }

    /// Restores the main-airframe visibility for a graph loaded from disk.
    /// Debris bodies are transient and are not recreated after a cold load,
    /// but detached geometry must not silently reappear on the vehicle.
    func restoreDetachedVehicleComponentVisibility(_ graph: VehicleComponentGraph) {
        clearDetachedVehicleParts()
        let detached = graph.components.filter { !$0.isAttached }
        let retainedLegacy = Set(graph.attachedComponents.compactMap(\.legacyComponent))
        detachedVehicleComponentIDs = Set(detached.map(\.id))
        detachedVehicleLegacyComponents = Set(detached.compactMap(\.legacyComponent))
            .subtracting(retainedLegacy)
        for component in detachedVehicleLegacyComponents {
            for node in componentNodes[component] ?? [] {
                detachedVehicleVisualNodeIDs.insert(ObjectIdentifier(node))
                node.isHidden = true
            }
        }
        reconcileDetachedVehicleVisuals(graph)
        lastComponentOverlaySignature = nil
    }

    /// Applies permanent structural bend/translation without accumulating a
    /// transform every frame. The component graph remains authoritative;
    /// pristine/reset graphs restore the exact original node transforms.
    func applyVehicleComponentDeformations(_ graph: VehicleComponentGraph) {
        for nodes in componentNodes.values {
            for node in nodes {
                let key = ObjectIdentifier(node)
                if let baseline = undeformedComponentTransforms[key] {
                    node.simdTransform = baseline
                } else {
                    undeformedComponentTransforms[key] = node.simdTransform
                }
            }
        }

        var strongestByLegacy: [DamageComponent: VehicleComponentDeformation] = [:]
        for component in graph.components where component.isAttached {
            guard let legacy = component.legacyComponent else { continue }
            let deformation = component.deformation
            let magnitude = simd_length(deformation.bendRadians) +
                simd_length(deformation.translationMeters) * 4.0
            let existingMagnitude = strongestByLegacy[legacy].map {
                simd_length($0.bendRadians) + simd_length($0.translationMeters) * 4.0
            } ?? -1.0
            if magnitude > existingMagnitude {
                strongestByLegacy[legacy] = deformation
            }
        }

        for (legacy, deformation) in strongestByLegacy {
            let rawAngle = simd_length(deformation.bendRadians)
            for node in componentNodes[legacy] ?? [] {
                if rawAngle > 0.0001 {
                    let angle = min(Float(25.0) * .pi / 180.0, rawAngle)
                    let axis = deformation.bendRadians / rawAngle
                    node.simdOrientation = node.simdOrientation * simd_quatf(angle: angle, axis: axis)
                }
                node.simdPosition += deformation.translationMeters
            }
        }
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

    /// See `DroneSimulationViewModel.vehicleGroundRestOffset` — how far the airframe reaches below
    /// `state.position` when resting correctly. 0 for everything that sits on its belly or gear.
    func setVehicleGroundRestLift(_ lift: Float) {
        vehicleGroundRestLift = lift.isFinite ? max(0.0, lift) : 0.0
    }

    func setDroneProfile(_ profile: DroneModelProfile) {
        activeProfile = profile

        clearDetachedVehicleParts()
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
        undeformedComponentTransforms.removeAll(keepingCapacity: false)
        spinAngles = Array(repeating: 0.0, count: propellerNodes.count)
        tiltPivotNodes = droneVisual.tiltPivotNodes
        visualBoundsCenter = droneVisual.visualBoundsCenter
        visualBoundsSize = droneVisual.visualBoundsSize
        cachedSubjectScale = droneVisual.subjectScale
        currentVisualGeometry = DroneVisualGeometrySample.capture(from: droneVisual)
        retainedVehicleSectionProxiesNode.removeFromParentNode()
        visualRootNode.addChildNode(retainedVehicleSectionProxiesNode)
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

    /// Decals are positioned against the terrain's ground height at the moment they're dropped —
    /// a full regeneration (new map scale/preset/seed) invalidates that, so clear rather than
    /// leave a trail floating above or buried under the new surface.
    func clearAgriculturalWetGroundDecals() {
        agriculturalWetGroundDecals.forEach { $0.removeFromParentNode() }
        agriculturalWetGroundDecals.removeAll()
        lastAgriculturalWetDecalPlanarPosition = nil
    }

    func regenerateEnvironment(_ terrain: TerrainConfiguration) {
        clearAgriculturalWetGroundDecals()
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
        descriptors incomingDescriptors: [EnvironmentObjectDescriptor],
        nodesByID: [UUID: SCNNode],
        terrain: TerrainConfiguration,
        printProceduralDiagnostics: Bool
    ) {
        // The dock and support surface may move when a new world is installed. Recreate the
        // sandbox hose truck on the next payload refresh so it cannot remain at the old origin.
        removeFreeFlightFireTruck()

        // Scenery yields to a crop field. Filtering here rather than deleting afterwards means
        // every regeneration keeps the field clear on its own, including the debounced one the
        // mission bootstrap schedules after the field has already been spawned.
        var descriptors = incomingDescriptors
        if let field = installedAgriField {
            let doomed = descriptors.filter { isInsideAgriField($0.position, field) }
            if !doomed.isEmpty {
                for descriptor in doomed {
                    nodesByID[descriptor.id]?.removeFromParentNode()
                }
                let doomedIDs = Set(doomed.map(\.id))
                descriptors.removeAll { doomedIDs.contains($0.id) }
                print("[Agri] scenery kept off the field: \(doomed.count) objects removed at generation")
            }
        }
        installedEnvironmentDescriptors = descriptors
        installedEnvironmentNodes = nodesByID.filter { key, _ in
            descriptors.contains { $0.id == key }
        }
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
        // An imported world *is* the environment: its ground, its relief, its edges, its obstacles.
        //
        // Letting the procedural pipeline run underneath it too was not harmless decoration. It laid
        // a generated landscape over the real city — the green hillock that survived every attempt to
        // remove it — walled the map at the procedural extent, and, worst of all,
        // `buildSupplementalCollisionObstacles` filled the tile with collision volumes sized to a
        // world that is not there. Those are the invisible walls the aircraft landed on, and the
        // geometry a reset dropped it inside of.
        //
        // The dock is deliberately still positioned: it is the launch pad, not scenery, and it has
        // its own imported-world branch that puts it on the real spawn point.
        let hasImportedWorld = meshCollision != nil
        applyTerrainVisualStyle(terrain)
        updateDockStationPosition(for: terrain)
        if !hasImportedWorld {
            updateWorldBoundsVisual(for: terrain)

            let supplementalObstacles = buildSupplementalCollisionObstacles(for: terrain)
            for entry in supplementalObstacles {
                obstacles.append(entry.obstacle)
                obstacleSourceByID[entry.obstacle.id] = entry.obstacle.source
                if let node = entry.highlightNode {
                    obstacleMap[entry.obstacle.id] = node
                }
            }
        }

        environmentObstacles = obstacles
        environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: obstacles)
        environmentRevision &+= 1

        // The procedural populator runs after a world is installed and would otherwise overwrite
        // the imported world's registry with its own (suppressed, therefore empty) scenery — which
        // is why the tactical overlay kept reporting zero objects even once the world published
        // them. When a world owns the scene, its objects win.
        if let installedWorld {
            MainActor.assumeIsolated {
                publishWorldRegistry(for: installedWorld)
            }
        }

        obstacleDebugProxyNodes.removeAll(keepingCapacity: false)
        obstacleDebugPlanarRadii.removeAll(keepingCapacity: false)
        collisionDebugNode.childNodes
            .filter { $0 !== nearestContactNode }
            .forEach { $0.removeFromParentNode() }
        nearestContactNode.isHidden = true
        abandonedCityCollisionDebugVisible = false

        pathDebugSignature = 0
        rebuildPathDebug(path: [])
        pathStartMarkerNode.isHidden = true
        pathGoalMarkerNode.isHidden = true
        pathCurrentWaypointNode.isHidden = true

        if !hasImportedWorld {
            buildSnowDecorations(for: terrain)
        }
        if terrain.preset == .city {
            printCityGenerationDiagnostics(descriptors: descriptors)
        }

        // A race track's gates are obstacles too, and this method replaces the obstacle list
        // wholesale — so anything a scenario registered before the (debounced) regeneration ran is
        // gone by now. That is exactly how the gates ended up passable: the racing bootstrap
        // changes the map scale, which schedules this rebuild for *after* the track was spawned.
        if let installedRaceTrack {
            registerRaceTrackObstacles(installedRaceTrack)
        }

        // Environment was rebuilt — thermal proxies are stale.
        invalidateThermalScene()
    }

    /// Installs an imported photogrammetric world into the live flight scene.
    ///
    /// The procedural ground plane is hidden rather than removed: a great deal of existing code
    /// reads `groundNode.position.y` as a reference height, and deleting the node would strand all
    /// of it. Hidden, it keeps answering those queries while the mesh — which is consulted first
    /// everywhere that matters — provides the real surface.
    /// `MeshWorldRuntime` is main-actor isolated because it owns the streamer that mutates the
    /// scene graph, and that isolation is worth keeping rather than weakening. This controller is
    /// not annotated, but every path that reaches these methods originates in the main-actor view
    /// model — `assumeIsolated` states that explicitly and traps if it ever stops being true,
    /// which is preferable to hopping asynchronously and letting the world install a frame late.
    func installWorld(_ world: (any FlyableWorld)?) {
        MainActor.assumeIsolated {
            installedWorld?.rootNode.removeFromParentNode()
            installedWorld = world
            publishWorldRegistry(for: world)
            // A survey cloud is geo-anchored to the world it was captured over; a new world would
            // leave those points floating in the wrong place, so start each world clean.
            clearLidarCloud()

            guard let world else {
                groundNode.isHidden = false
                meshSpawnPoint = nil
                meshWater = nil
                setMeshCollision(nil)
                return
            }

            scene.rootNode.addChildNode(world.rootNode)
            // Hide every procedural visual the instant the world arrives, not on the next deferred
            // terrain pass. On a reload the snapshot restores the `.gridDemo` preset, which draws the
            // reference grid and axes; leaving them for `applyTerrainVisualStyle` to hide later let
            // them flash for a frame under the real city.
            groundNode.isHidden = true
            gridNode.isHidden = true
            axesNode.isHidden = true
            setMeshCollision(world.collision)
            // Resolved here, on the main actor, so the dock placement — which runs nonisolated —
            // can read it without touching the world.
            meshSpawnPoint = world.spawnPoint
            meshWater = world.water

            // Move the dock onto the spawn *now*, not on the next deferred terrain regeneration.
            //
            // `attachWorld` reads `currentSpawnPoint()` — which resolves through the dock — the
            // instant this returns, to place the aircraft. If the dock is still at its old position
            // then (the origin, on a reload), the aircraft is dropped at the origin and only the
            // deferred `updateDockStationPosition` moves the pad, tens of metres away. Syncing the
            // dock here closes that window.
            if let spawn = world.spawnPoint {
                dockSpawnPosition = spawn
                dockStationNode.simdPosition = spawn
                    + SIMD3<Float>(0.0, -dockDeckSurfaceHeight, 0.0)
            }

            #if DEBUG
            print("[World] installed: origin \(world.origin.coordinate.displayString), "
                  + "bounds \(Int(world.worldBounds.maximum.x - world.worldBounds.minimum.x)) m, "
                  + "water \(world.water == nil ? "none" : "yes")")
            #endif
        }
    }

    /// Drives level-of-detail streaming from whichever camera is actually rendering.
    ///
    /// Called from the per-tick `update`, which runs on the main actor from the view model — not
    /// from a render callback, which this project has established is neither guaranteed to be the
    /// main thread nor safe for scene-graph mutation.
    private func updateMeshWorldStreaming(cameraMode: CameraMode) {
        guard let installedWorld else { return }
        MainActor.assumeIsolated {
        let pointOfView = resolvedPointOfView(for: cameraMode)
        let transform = pointOfView.simdWorldTransform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // A camera looks down its own local -Z.
        var forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let fieldOfView = Float(pointOfView.camera?.fieldOfView ?? 55)

        // A camera node that has not been placed yet carries the identity transform, which points
        // the selection at the world origin and produces a completely unrelated node set for that
        // frame — visible as the whole view changing and changing back. Rather than stream from a
        // position that is certainly wrong, keep last frame's selection until the node is real.
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
        let forwardLength = simd_length(forward)
        guard forwardLength > 0.001 else { return }
        forward /= forwardLength
        if simd_length_squared(position) < 0.000001, lastStreamedCameraPosition != nil {
            return
        }
        lastStreamedCameraPosition = position

        installedWorld.updateStreaming(
            camera: MeshStreamingPolicy.Camera(
                position: position,
                forward: forward,
                verticalFieldOfViewRadians: max(fieldOfView, 20) * .pi / 180.0,
                viewportHeightPixels: max(meshStreamingViewportHeight, 240),
                aspectRatio: 16.0 / 9.0
            )
        )
        }
    }

    /// Installs (or clears, with `nil`) the collision surface of an imported photogrammetric
    /// world. Passing `nil` restores the flat-plane behaviour exactly.
    func setMeshCollision(_ index: MeshCollisionIndex?) {
        meshCollision = index
        // Synthesised cells belong to the world that produced them; keeping them across a swap
        // would leave the previous city's walls standing invisibly in the new one.
        meshCollisionCellCache.removeAll(keepingCapacity: false)
        meshCollisionCellLastAccess.removeAll(keepingCapacity: false)
        meshObstaclesByID.removeAll(keepingCapacity: false)
        meshCollisionCellAccessCounter = 0
        environmentRevision &+= 1
        #if DEBUG
        if let index {
            print("[MeshWorld] collision installed: \(index.triangleCount) triangles, "
                  + String(format: "%.1f MB", Double(index.memoryFootprintBytes) / 1_048_576.0))
        } else {
            print("[MeshWorld] collision cleared")
        }
        #endif
    }

    /// The installed world's own buildings and trees near a point.
    ///
    /// Separate from `nearbyEnvironmentObstacles` because these are *objects* — a façade with a
    /// real footprint, a crown with a real radius — while what that returns for an imported world
    /// includes `world.mesh.cell` entries, which are 24 m buckets of the collision index. A bucket
    /// is the right shape for "which triangles are near", and completely the wrong shape for "how
    /// much room is there beside me": in a city the aircraft is always inside one.
    func nearbyWorldNavigationObstacles(
        near position: SIMD3<Float>,
        radius: Float
    ) -> [CollisionObstacle] {
        worldNavigationObstacleIndex.query(near: position, radius: radius)
    }

    func nearbyEnvironmentObstacles(
        near position: SIMD3<Float>,
        radius: Float,
        includeMesh: Bool = true
    ) -> [CollisionObstacle] {
        var obstacles = environmentObstacleIndex.query(near: position, radius: radius)
        obstacles.append(contentsOf: worldNavigationObstacleIndex.query(near: position, radius: radius))
        if includeMesh {
            obstacles.append(contentsOf: meshObstacles(
                inBox: position - SIMD3<Float>(repeating: radius),
                maximum: position + SIMD3<Float>(repeating: radius)
            ))
        }
        return obstacles
    }

    func nearbyEnvironmentObstacles(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        margin: Float
    ) -> [CollisionObstacle] {
        var obstacles = environmentObstacleIndex.query(from: start, to: end, margin: margin)
        obstacles.append(contentsOf: worldNavigationObstacleIndex.query(from: start, to: end, margin: margin))
        let low = simd_min(start, end) - SIMD3<Float>(repeating: margin)
        let high = simd_max(start, end) + SIMD3<Float>(repeating: margin)
        obstacles.append(contentsOf: meshObstacles(inBox: low, maximum: high))
        return obstacles
    }

    /// Queries a narrow swept tube around one or more predicted trajectories.
    ///
    /// A square radius query scales with horizon² and therefore had to be truncated at 700 m.
    /// Heavy fixed-wing aircraft can need more than two kilometres to roll in and turn, so that
    /// cap made the reactive predictor blind. Rasterising the tube scales with path length instead;
    /// every touched mesh cell is enumerated explicitly and incompleteness is reported, never
    /// converted to an empty (apparently clear) obstacle set.
    func nearbyEnvironmentObstacles(
        along paths: [[SIMD3<Float>]],
        margin: Float,
        includeMesh: Bool = true
    ) -> EnvironmentObstacleCorridorQueryResult {
        let safeMargin = max(0.0, margin)
        var byID: [UUID: CollisionObstacle] = [:]

        for path in paths where !path.isEmpty {
            if path.count == 1, let point = path.first {
                for obstacle in environmentObstacleIndex.query(near: point, radius: safeMargin) {
                    byID[obstacle.id] = obstacle
                }
                for obstacle in worldNavigationObstacleIndex.query(near: point, radius: safeMargin) {
                    byID[obstacle.id] = obstacle
                }
                continue
            }
            for segment in zip(path, path.dropFirst()) {
                for obstacle in environmentObstacleIndex.query(
                    from: segment.0,
                    to: segment.1,
                    margin: safeMargin
                ) {
                    byID[obstacle.id] = obstacle
                }
                for obstacle in worldNavigationObstacleIndex.query(
                    from: segment.0,
                    to: segment.1,
                    margin: safeMargin
                ) {
                    byID[obstacle.id] = obstacle
                }
            }
        }

        var complete = true
        if includeMesh {
            let meshResult = meshObstacles(along: paths, margin: safeMargin)
            complete = meshResult.isComplete
            for obstacle in meshResult.obstacles {
                byID[obstacle.id] = obstacle
            }
        }
        return EnvironmentObstacleCorridorQueryResult(
            obstacles: Array(byID.values),
            isComplete: complete
        )
    }

    /// Mesh-world geometry presented to the flight model as ordinary obstacles.
    ///
    /// `CollisionObstacle` already carries triangle soup and `CollisionAnalysisService` already
    /// solves swept spheres against it, so an imported city needs no change to the physics at
    /// all — it only has to arrive in the same shape as everything else.
    ///
    /// Results are cached per grid cell because the aircraft re-queries almost the same
    /// neighbourhood every tick, and re-extracting a few hundred triangles sixty times a second
    /// would be pure waste. The cache is keyed on the cell, not the aircraft, so a second vehicle
    /// flying the same street reuses it.
    private func meshObstacles(
        inBox minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> [CollisionObstacle] {
        guard meshCollision != nil else { return [] }

        let cell = Self.meshCollisionCellSize
        let columnStart = Int(floor(minimum.x / cell))
        let columnEnd = Int(floor(maximum.x / cell))
        let rowStart = Int(floor(minimum.z / cell))
        let rowEnd = Int(floor(maximum.z / cell))

        // A query spanning an implausible number of cells means something asked for the whole
        // city at once; answering it would allocate megabytes on the tick path.
        //
        // A query limit below the fixed-wing prediction horizon silently returns no mesh blockers
        // at all. Cells are cached, so subsequent ticks reuse the extracted obstacle buckets.
        let spanned = (columnEnd - columnStart + 1) * (rowEnd - rowStart + 1)
        guard spanned > 0, spanned <= Self.meshObstacleQueryCellLimit else { return [] }

        var result: [CollisionObstacle] = []
        result.reserveCapacity(spanned)
        for row in rowStart...rowEnd {
            for column in columnStart...columnEnd {
                if let obstacle = meshObstacle(column: column, row: row) {
                    result.append(obstacle)
                }
            }
        }
        return result
    }

    private func meshObstacles(
        along paths: [[SIMD3<Float>]],
        margin: Float
    ) -> EnvironmentObstacleCorridorQueryResult {
        guard let meshCollision else {
            // This overload is called only when mesh coverage was explicitly requested. An
            // installed photogrammetry world whose collision index is absent/not ready is unknown
            // space, never an empty clear sky.
            return EnvironmentObstacleCorridorQueryResult(obstacles: [], isComplete: false)
        }
        guard margin.isFinite,
              !paths.isEmpty,
              paths.allSatisfy({ path in
                  !path.isEmpty && path.allSatisfy { point in
                      point.x.isFinite && point.y.isFinite && point.z.isFinite
                  }
              }) else {
            return EnvironmentObstacleCorridorQueryResult(obstacles: [], isComplete: false)
        }

        let cell = Self.meshCollisionCellSize
        let neighbourRadius = max(1, Int(ceil(max(0.0, margin) / cell)) + 1)
        // Large enough for several multi-kilometre turn tubes, bounded so a corrupt trajectory
        // cannot allocate the whole world on the simulation tick.
        let maximumKeys = Self.meshCorridorQueryCellLimit
        let coverageMinimum = meshCollision.bounds.minimum
        let coverageMaximum = meshCollision.bounds.maximum
        var keys = Set<MeshCollisionCellKey>()
        keys.reserveCapacity(min(maximumKeys, 4_096))
        var complete = true

        func insertTubeSample(_ point: SIMD3<Float>) {
            guard complete else { return }
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                complete = false
                return
            }
            // `MeshCollisionIndex.bounds` is the only authoritative coverage boundary. Cells
            // outside it contain unknown world, not confirmed empty air. Require the complete
            // requested tube (not just its centre line) to remain inside the X/Z coverage before
            // extracting any cells, so an edge rollout cannot turn an out-of-bounds `[]` into a
            // successful safety proof.
            guard point.x - margin >= coverageMinimum.x,
                  point.x + margin <= coverageMaximum.x,
                  point.z - margin >= coverageMinimum.z,
                  point.z + margin <= coverageMaximum.z else {
                complete = false
                return
            }
            let centerColumn = Int(floor(point.x / cell))
            let centerRow = Int(floor(point.z / cell))
            for row in (centerRow - neighbourRadius)...(centerRow + neighbourRadius) {
                for column in (centerColumn - neighbourRadius)...(centerColumn + neighbourRadius) {
                    // The extra neighbour ring is broad-phase padding and may straddle the mesh
                    // boundary even though the requested tube itself is fully covered. Skip cells
                    // wholly outside the index instead of caching their empty extraction result.
                    let cellMinimumX = Float(column) * cell
                    let cellMaximumX = Float(column + 1) * cell
                    let cellMinimumZ = Float(row) * cell
                    let cellMaximumZ = Float(row + 1) * cell
                    guard cellMaximumX >= coverageMinimum.x,
                          cellMinimumX <= coverageMaximum.x,
                          cellMaximumZ >= coverageMinimum.z,
                          cellMinimumZ <= coverageMaximum.z else {
                        continue
                    }
                    keys.insert(MeshCollisionCellKey(column: column, row: row))
                    if keys.count > maximumKeys {
                        complete = false
                        return
                    }
                }
                if !complete { return }
            }
        }

        for path in paths where complete && !path.isEmpty {
            if path.count == 1, let point = path.first {
                insertTubeSample(point)
                continue
            }
            for segment in zip(path, path.dropFirst()) where complete {
                let delta = segment.1 - segment.0
                let planarLength = simd_length(SIMD2<Float>(delta.x, delta.z))
                let steps = max(1, Int(ceil(planarLength / max(1.0, cell * 0.45))))
                for index in 0...steps {
                    let fraction = Float(index) / Float(steps)
                    insertTubeSample(segment.0 + delta * fraction)
                    if !complete { break }
                }
            }
        }

        guard complete else {
            return EnvironmentObstacleCorridorQueryResult(obstacles: [], isComplete: false)
        }

        var obstacles: [CollisionObstacle] = []
        obstacles.reserveCapacity(keys.count)
        for key in keys {
            if let obstacle = meshObstacle(column: key.column, row: key.row) {
                obstacles.append(obstacle)
            }
        }
        return EnvironmentObstacleCorridorQueryResult(
            obstacles: obstacles,
            isComplete: true
        )
    }

    private func meshObstacle(column: Int, row: Int) -> CollisionObstacle? {
        let key = MeshCollisionCellKey(column: column, row: row)
        if let cached = meshCollisionCellCache[key] {
            meshCollisionCellAccessCounter &+= 1
            meshCollisionCellLastAccess[key] = meshCollisionCellAccessCounter
            return cached.obstacle
        }
        guard let meshCollision else { return nil }

        let cell = Self.meshCollisionCellSize
        // Cells are extracted with a margin so a triangle straddling the boundary is present in
        // both, rather than falling through the crack between two adjacent queries.
        let margin: Float = 1.5
        let low = SIMD3<Float>(
            Float(column) * cell - margin,
            meshCollision.bounds.minimum.y - 1.0,
            Float(row) * cell - margin
        )
        let high = SIMD3<Float>(
            Float(column + 1) * cell + margin,
            meshCollision.bounds.maximum.y + 1.0,
            Float(row + 1) * cell + margin
        )

        let corners = meshCollision.triangleCorners(inBox: low, maximum: high)
        guard corners.count >= 3 else {
            storeMeshCollisionCell(MeshCollisionCell(obstacle: nil), for: key)
            return nil
        }

        var triangles: [CollisionMeshTriangle] = []
        triangles.reserveCapacity(corners.count / 3)
        var boundsLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        // NOTE: cells deliberately keep describing buildings as well.
        //
        // Stripping object-claimed triangles here was correct in principle and unaffordable in
        // practice: it ran point-in-polygon for every triangle of every newly synthesised cell
        // against every nearby outline — hundreds of triangles against outlines of up to 146
        // vertices — and cells are re-synthesised continuously as the aircraft moves. That is the
        // 0 FPS hang after the first waypoint. Buildings now carry their own exact prisms, so the
        // tight geometry exists either way; what remains is that a cell's coarse 24 m proxy still
        // double-describes them, which costs accuracy in the risk estimate, not correctness of
        // contact. Re-doing this needs the claim resolved once at cell level (or at world build
        // time), never per triangle per frame.
        for index in stride(from: 0, to: corners.count - 2, by: 3) {
            let a = corners[index], b = corners[index + 1], c = corners[index + 2]
            // A near-horizontal face is landable; a facade is not. The mesh has no semantics, so
            // slope is the only available signal — and it is the right one, since what matters to
            // a settling aircraft is whether the surface can hold it.
            let normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            let landable = length > 1e-9 && abs(normal.y / length) > 0.7
            guard let triangle = CollisionMeshTriangle(
                point0: a,
                point1: b,
                point2: c,
                supportsLandingSurface: landable
            ) else { continue }
            triangles.append(triangle)
            boundsLow = simd_min(boundsLow, triangle.minimum)
            boundsHigh = simd_max(boundsHigh, triangle.maximum)
        }

        guard !triangles.isEmpty else {
            storeMeshCollisionCell(MeshCollisionCell(obstacle: nil), for: key)
            return nil
        }

        let center = (boundsLow + boundsHigh) * 0.5
        // The planar footprint is given explicitly. Without it the only shape available is the
        // bounding sphere of the *3-D* extent, and for a cell holding a tall building that sphere's
        // radius is dominated by the building's height — a 24 m cell with a 100 m tower reads as a
        // ~52 m blocking disc. Steering decisions made against that are nonsense in a street. The
        // cell's true XZ extent is a box, and `CollisionObstacle` prefers it when supplied; the
        // broad-phase radius is left as it was, since the initialiser only ever widens it.
        let planarHalfExtents = SIMD2<Float>(
            max(0.5, (boundsHigh.x - boundsLow.x) * 0.5),
            max(0.5, (boundsHigh.z - boundsLow.z) * 0.5)
        )
        let obstacle = CollisionObstacle(
            id: UUID(),
            center: center,
            radius: simd_length(boundsHigh - boundsLow) * 0.5,
            source: "world.mesh.cell.\(column).\(row)",
            baseY: boundsLow.y,
            topY: boundsHigh.y,
            planarHalfExtents: planarHalfExtents,
            meshTriangles: triangles
        )

        // Bound the cache: a long flight would otherwise accumulate the whole tile in synthesised
        // form alongside the index it came from.
        storeMeshCollisionCell(MeshCollisionCell(obstacle: obstacle), for: key)
        // Synthesised cells live only in this cache, so a risk report naming one could not be
        // resolved back to its obstacle — which silently disabled avoidance on every imported world.
        meshObstaclesByID[obstacle.id] = obstacle
        return obstacle
    }

    private func storeMeshCollisionCell(
        _ cell: MeshCollisionCell,
        for key: MeshCollisionCellKey
    ) {
        // Empty cells count too. The corridor query visits open ground as well as buildings, and
        // the old early-return branches cached those misses without ever applying the bound.
        if meshCollisionCellCache[key] == nil,
           meshCollisionCellCache.count >= Self.meshCollisionCellCacheLimit {
            // Evict one generation, not the complete cache. A full clear made a long fixed-wing
            // fan re-extract thousands of triangle buckets again on the very next tick.
            let evictionCount = max(1, Self.meshCollisionCellCacheLimit / 4)
            let evictionKeys = meshCollisionCellCache.keys.sorted {
                (meshCollisionCellLastAccess[$0] ?? 0) <
                    (meshCollisionCellLastAccess[$1] ?? 0)
            }.prefix(evictionCount)
            for evictionKey in evictionKeys {
                if let obstacleID = meshCollisionCellCache[evictionKey]?.obstacle?.id {
                    meshObstaclesByID.removeValue(forKey: obstacleID)
                }
                meshCollisionCellCache.removeValue(forKey: evictionKey)
                meshCollisionCellLastAccess.removeValue(forKey: evictionKey)
            }
        }
        meshCollisionCellCache[key] = cell
        meshCollisionCellAccessCounter &+= 1
        meshCollisionCellLastAccess[key] = meshCollisionCellAccessCounter
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
            let resolvedBackground = nightOverriddenBackground(backgroundImage)
            scene.background.contents = resolvedBackground
            // Keep the thermal restore target current if the EO sky changed while thermal is
            // active (the dirty flag re-paints the thermal sky on the next frame).
            if thermalRenderingActive { thermalSavedBackground = resolvedBackground }
            // applyTerrainVisualStyle keeps lightingEnvironment.contents in lockstep with the
            // visible sky on terrain changes; weather can change independently of terrain, so
            // without this the IBL ambient light kept using the pre-storm bright gradient even
            // though the visible sky had already gone dark. Night uses the same dark override as
            // the background — a bright daytime gradient merely turned down in intensity still
            // floods diffuse surfaces (grass, trees) with a sky-bright dome of fill light, which
            // reads as "lit", not dark.
            scene.lightingEnvironment.contents = resolvedBackground

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
        // Tailsitters rest nose-up on their tail, well below the airframe origin physics measures
        // from — but position.y == supportY at rest is a load-bearing contract for arm/takeoff
        // ground checks and throttle floors elsewhere (see the reverted physics-side attempt at
        // this same offset: it silently made the aircraft read as already airborne at rest and
        // self-throttle on arm). So the offset lives outside physics, and the *same* offset now
        // serves the renderer and the environment-collision sweep:
        // `DroneSimulationViewModel.vehicleGroundRestOffset`, measured from the contact profile
        // rather than typed in by hand against a particular fuselage capsule.
        //
        // Deliberately not scaled by `|sin(pitch)|` any more. A rigid body's origin does not
        // migrate as it pitches; the old attitude-scaled version agreed with the collision geometry
        // only at rest and drifted from it everywhere else, which is exactly the disagreement that
        // ground the tailsitter's propeller into the terrain on arm.
        droneNode.position = SCNVector3(
            state.position.x,
            state.position.y + vehicleGroundRestLift,
            state.position.z
        )
        let droneOrientation = orientationQuaternion(from: state.orientation)
        droneNode.simdOrientation = droneOrientation


        updateGroundDetailPatch(around: state.position)

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
            droneNode.isHidden = canisterRoundSealed
            droneNode.opacity = 1.0
        }
        applyPayloadFPVPresentation()
        updatePayloadCamera(state: payloadCameraOpticsState, droneState: state, deltaTime: deltaTime)

        updatePropulsionUnitVisuals(state: state)
        rotatePropellers(state: state, deltaTime: deltaTime)
        updateJetExhaust(state: state)
        updateCondensationCone(state: state)
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
        updateDetachedVehiclePartObstacleCollisions(deltaTime: deltaTime)

        // Streamed last, deliberately. The camera nodes are positioned and blended earlier in this
        // same function, so selecting level of detail before that ran meant choosing geometry for
        // where the camera *was*, and — during a camera-mode change — for a node that had not been
        // placed yet at all. A no-op when no mesh world is installed.
        updateMeshWorldStreaming(cameraMode: camera.mode)
    }

    func updateCollisionDebug(risk: CollisionAnalysisSnapshot, enabled: Bool) {
        guard enabled else {
            collisionDebugNode.isHidden = true
            nearestContactNode.isHidden = true
            setAbandonedCityCollisionDebugVisible(false)
            return
        }

        // A city registry holds thousands of buildings, and the overlay hides everything past
        // 32 m anyway — instantiating a marker for each would cost a frame for geometry nobody
        // sees. Markers are built around the aircraft and rebuilt only when it has actually left
        // the neighbourhood they were built for.
        let debugAnchor = droneNode.presentation.simdWorldPosition
        // The anchor moves only when the markers are rebuilt around a new one.
        //
        // Updating it every frame made `previous` last frame's position, so the distance compared
        // here was one frame of travel — a few centimetres — and the 60 m rebuild threshold could
        // never be reached. The overlay therefore kept whatever it built when debug was switched
        // on and never followed the aircraft: fly a block away and buildings show no wireframe at
        // all, which reads exactly like "some buildings have collision and some do not".
        let needsRebuild = collisionDebugAnchor.map {
            simd_distance($0, debugAnchor) > 60.0
        } ?? true
        if needsRebuild, collisionDebugAnchor != nil {
            obstacleDebugProxyNodes.removeAll(keepingCapacity: false)
            obstacleDebugPlanarRadii.removeAll(keepingCapacity: false)
            collisionDebugNode.childNodes
                .filter { $0 !== nearestContactNode }
                .forEach { $0.removeFromParentNode() }
        }
        if needsRebuild {
            collisionDebugAnchor = debugAnchor
        }
        ensureCollisionDebugMarkers(around: collisionDebugAnchor ?? debugAnchor)
        collisionDebugNode.isHidden = false
        setAbandonedCityCollisionDebugVisible(true)

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

            // Distance to the *surface*, not the centroid. A building's centre can sit 60 m away
            // while its façade is a metre off the rotor, so a centre-based test hid exactly the
            // obstacles worth showing — every large building, always.
            let planarDistance = max(
                0.0,
                simd_distance(dronePlanarPosition, SIMD2<Float>(center.x, center.z))
                    - (obstacleDebugPlanarRadii[id] ?? 0.0)
            )
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

    /// Publishes an imported world's own objects into the shared environment registry.
    ///
    /// Before this, the registry was filled only by the procedural populator, so on an imported map
    /// it stayed empty — which is why the route planner treated a city as open ground and the
    /// aircraft flew into buildings it had no record of. The world knows its buildings and trees as
    /// objects, so it can say so rather than leaving them as nothing but triangles in the collision
    /// index.
    ///
    /// **These objects are for planning, not for contact.** They are published into
    /// `worldNavigationObstacles`, deliberately *not* into `environmentObstacles`: an object here is
    /// a bounding box, and the same building already exists in the mesh collision index as its exact
    /// walls. Feeding the box into the physics as well would put a solid slab across the concave
    /// part of every L-shaped footprint — an invisible wall in the street beside it — and would give
    /// every tree a 4 m box on top of the slim canopy proxy the foliage work deliberately kept.
    /// The planner rasterises to a ~7 m grid, where a footprint box is the right approximation, and
    /// contact stays with the triangles the pilot can see.
    /// The outline of a mapped building, extruded into the surface the aircraft can touch.
    static func polygonContains(_ polygon: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    @MainActor
    private func buildingContactPrism(for object: FlyableWorldObject) -> [CollisionMeshTriangle]? {
        guard object.kind == .building, var outline = object.footprint, outline.count >= 3 else {
            return nil
        }
        if let first = outline.first, let last = outline.last, simd_distance(first, last) < 0.01 {
            outline.removeLast()
        }
        guard outline.count >= 3 else { return nil }

        let baseY = object.position.y
        let topY = baseY + object.size.y
        var triangles: [CollisionMeshTriangle] = []
        triangles.reserveCapacity(outline.count * 3)

        for index in outline.indices {
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            let a0 = SIMD3<Float>(a.x, baseY, a.y), a1 = SIMD3<Float>(a.x, topY, a.y)
            let b0 = SIMD3<Float>(b.x, baseY, b.y), b1 = SIMD3<Float>(b.x, topY, b.y)
            // A façade is never landable, whatever its normal works out to.
            if let wall = CollisionMeshTriangle(
                point0: a0, point1: b0, point2: b1, supportsLandingSurface: false
            ) { triangles.append(wall) }
            if let wall = CollisionMeshTriangle(
                point0: a0, point1: b1, point2: a1, supportsLandingSurface: false
            ) { triangles.append(wall) }
        }

        if let indices = PolygonTriangulator.triangulate(outline), indices.count >= 3 {
            for start in stride(from: 0, to: indices.count - 2, by: 3) {
                let p0 = outline[indices[start]]
                let p1 = outline[indices[start + 1]]
                let p2 = outline[indices[start + 2]]
                if let roof = CollisionMeshTriangle(
                    point0: SIMD3<Float>(p0.x, topY, p0.y),
                    point1: SIMD3<Float>(p1.x, topY, p1.y),
                    point2: SIMD3<Float>(p2.x, topY, p2.y),
                    supportsLandingSurface: true
                ) { triangles.append(roof) }
            }
        }
        return triangles.isEmpty ? nil : triangles
    }

    @MainActor
    private func publishWorldRegistry(for world: (any FlyableWorld)?) {
        guard let world else {
            environmentMapDescriptors = []
            worldNavigationObstacles = []
            worldNavigationObstaclesByID = [:]
            worldObjectFootprints = [:]
            worldNavigationObstacleIndex = .empty
            supportSurfaces = []
            environmentRevision &+= 1
            return
        }

        let objects = world.registryObjects()
        guard !objects.isEmpty else {
            // A photogrammetric world has no notion of discrete objects; consumers that need its
            // buildings must go on reading the mesh collision index.
            worldNavigationObstacles = []
            worldNavigationObstaclesByID = [:]
            worldObjectFootprints = [:]
            worldNavigationObstacleIndex = .empty
            return
        }

        var descriptors: [EnvironmentObjectDescriptor] = []
        var obstacles: [CollisionObstacle] = []
        var footprints: [UUID: [SIMD2<Float>]] = [:]
        descriptors.reserveCapacity(objects.count)
        obstacles.reserveCapacity(objects.count)

        for object in objects {
            let halfExtents = SIMD2<Float>(object.size.x * 0.5, object.size.z * 0.5)
            let boundingRadius = simd_length(halfExtents)
            descriptors.append(EnvironmentObjectDescriptor(
                id: object.id,
                kind: object.kind,
                biome: .city,
                position: object.position,
                yawRadians: object.yawRadians,
                size: object.size,
                boundingRadius: boundingRadius,
                isCollidable: true,
                collisionParts: []
            ))
            // A crown is round, so it stays a cylinder. Squaring it off would block the four corners
            // of every tree — about a quarter more area each, along the very street edges a route
            // has to thread through.
            let isCircular = object.kind == .tree
            // Contact geometry follows the outline; the box stays only as the broad phase.
            //
            // The operator's complaint was exact: you cannot fly close to a building, because the
            // minimum-area rectangle juts into the street — ×1.29 of the true footprint at the
            // 90th percentile, ×7.4 at worst, and 42% of these outlines are not quads at all. So
            // the wall the aircraft actually touches is now the wall that is drawn: the footprint
            // extruded from base to roof, plus a triangulated cap that is flagged landable so a
            // rooftop still holds an aircraft. `CollisionAnalysisService` already prefers exact
            // triangles over the planar box whenever an obstacle carries them, and the planner
            // goes on reading `planarHalfExtents`, which is what keeps its search cheap.
            let outlinePrism = buildingContactPrism(for: object)
            if outlinePrism != nil, let outline = object.footprint {
                footprints[object.id] = outline
            }
            obstacles.append(CollisionObstacle(
                id: object.id,
                center: SIMD3<Float>(
                    object.position.x,
                    object.position.y + object.size.y * 0.5,
                    object.position.z
                ),
                radius: isCircular ? max(halfExtents.x, halfExtents.y) : boundingRadius,
                source: object.source,
                baseY: object.position.y,
                topY: object.position.y + object.size.y,
                planarHalfExtents: isCircular ? nil : halfExtents,
                yawRadians: object.yawRadians,
                meshTriangles: outlinePrism,
                planarFootprint: outlinePrism == nil ? nil : object.footprint
            ))
        }

        environmentMapDescriptors = descriptors
        worldNavigationObstacles = obstacles
        worldObjectFootprints = footprints
        worldNavigationObstaclesByID = Dictionary(
            obstacles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        worldNavigationObstacleIndex = CollisionObstacleSpatialIndex(obstacles: obstacles)
        // Support surfaces stay with the mesh: a building's roof is already a landable face there,
        // and synthesising a second flat top from the bounding box would fight it.
        supportSurfaces = []
        environmentRevision &+= 1
    }

    func obstacleCenter(for id: UUID) -> SIMD3<Float>? {
        if let dynamicObstacle = dynamicObstacles[id] {
            return dynamicObstacle.center
        }
        // Mesh cells too. Missing them here disabled the *mode-independent* emergency avoidance on
        // every imported world: the risk report would name a façade, this lookup would return nil,
        // and the `.avoid` case would bail out silently while the aircraft kept closing on it.
        if let meshObstacle = meshObstaclesByID[id] {
            return meshObstacle.center
        }
        // The installed world's own buildings and trees. The comment above applies to them word
        // for word: the risk report names `world.building`, and without this the lookup returned
        // nil, so the collision overlay drew nothing and — far worse — the mode-independent
        // `.avoid` case bailed out silently while the aircraft kept closing on the façade.
        if let worldObstacle = worldNavigationObstaclesByID[id] {
            return worldObstacle.center
        }
        return environmentObstacles.first(where: { $0.id == id })?.center
    }

    /// Diagnostic only: where an obstacle id resolves and how much exact geometry it carries.
    ///
    /// Read by the impact log to settle a question that no observable behaviour distinguishes —
    /// a façade reported as a high collision risk, drawn in the overlay and scraped for damage
    /// looks identical whether it is a real footprint prism or the plain box that preceded it.
    /// Deliberately searches every registry, including the ones `obstacle(for:)` does not.
    func obstacleDiagnostics(for id: UUID) -> (origin: String, triangleCount: Int)? {
        if let obstacle = dynamicObstacles[id] {
            return ("dynamic", obstacle.meshTriangles?.count ?? 0)
        }
        if let obstacle = meshObstaclesByID[id] {
            return ("meshCell", obstacle.meshTriangles?.count ?? 0)
        }
        if let obstacle = worldNavigationObstaclesByID[id] {
            return ("worldRegistry", obstacle.meshTriangles?.count ?? 0)
        }
        if let obstacle = environmentObstacles.first(where: { $0.id == id }) {
            return ("environment", obstacle.meshTriangles?.count ?? 0)
        }
        return nil
    }

    func obstacle(for id: UUID) -> CollisionObstacle? {
        if let dynamicObstacle = dynamicObstacles[id] {
            return dynamicObstacle
        }
        if let meshObstacle = meshObstaclesByID[id] {
            return meshObstacle
        }
        // Registry objects — where an imported world's buildings live.
        //
        // Two things were needed and only one of them was a sign. `resolveObstaclePenetration`
        // fires on `nearestObstacleDistance <= -0.02`, which an unsigned mesh distance could
        // never produce, so while the prism was a hollow shell this lookup would have changed
        // nothing — the function was never even reached. With the outline restoring the interior
        // the condition is now met, and this is the guard that decides whether anything can act
        // on it: the one registry it never searched. Measured, not inferred — every
        // `world.building` impact reports `origin=worldRegistry` with a real triangle count.
        if let worldObstacle = worldNavigationObstaclesByID[id] {
            return worldObstacle
        }
        return environmentObstacles.first(where: { $0.id == id })
    }

    func supportSurfaceHeight(
        at planarPosition: SIMD2<Float>,
        clearanceRadius: Float,
        maximumHeight: Float
    ) -> Float? {
        supportSurfaceContact(
            at: planarPosition,
            clearanceRadius: clearanceRadius,
            maximumHeight: maximumHeight
        )?.height
    }

    /// Highest support surface under `planarPosition` together with its world-space
    /// up-normal (y > 0). Flat tops (container/crate/building bounds) return (0, 1, 0);
    /// pitched building-roof triangles return the actual slope normal so a resting drone
    /// can be laid flush against the incline instead of hovering level over it.
    func supportSurfaceContact(
        at planarPosition: SIMD2<Float>,
        clearanceRadius: Float,
        maximumHeight: Float
    ) -> (height: Float, normal: SIMD3<Float>)? {
        var best: (height: Float, normal: SIMD3<Float>)?

        // An imported mesh world *is* the terrain and the rooftops, so it is consulted first and
        // then competes with the procedural surfaces on height like any other candidate. The
        // query starts from `maximumHeight` rather than from the sky so that standing under a
        // bridge or an arcade finds the deck above only when the caller asked to look that high.
        if let meshCollision {
            // Never cast from higher than the world's own sky. Callers say "look as high as you
            // like" with `.greatestFiniteMagnitude`, and that is *finite* — so the sky branch below
            // was never taken and the ray was fired from 3.4e38 metres up. At that magnitude a
            // Float's own step is ~1e31 m, so the ray had no usable precision left by the time it
            // reached the city: the probe returned nil and every caller silently fell back to its
            // default ground height. That is why a launch point snapped onto a 21 m roof put the
            // operator down at street level.
            let skyCeiling = meshCollision.bounds.maximum.y + 10.0
            let ceiling = maximumHeight.isFinite
                ? min(maximumHeight + 0.08, skyCeiling)
                : skyCeiling
            if let surface = meshCollision.surfaceHeight(
                x: planarPosition.x,
                z: planarPosition.y,
                startingFrom: ceiling
            ) {
                // Re-cast for the normal: a pitched roof must be reported with its true slope so
                // a resting aircraft lies flush instead of hovering level over it.
                let probe = meshCollision.raycast(
                    origin: SIMD3<Float>(planarPosition.x, surface + 0.5, planarPosition.y),
                    direction: SIMD3<Float>(0, -1, 0),
                    maxDistance: 1.5
                )
                var normal = probe?.normal ?? SIMD3<Float>(0, 1, 0)
                if normal.y < 0 { normal = -normal }
                best = (surface, normal)
            }
        }

        for surface in supportSurfaces {
            guard planarPoint(planarPosition, intersects: surface, clearanceRadius: clearanceRadius) else {
                continue
            }
            guard let surfaceHeight = surface.height(at: planarPosition),
                  surfaceHeight <= maximumHeight + 0.08 else {
                continue
            }
            if best == nil || surfaceHeight > best!.height {
                best = (surfaceHeight, surface.normal)
            }
        }
        return best
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

        // Model transform, not `.presentation` — see `payloadCameraTargetDistance` for why
        // (avoids a ~16ms render-thread scene-lock stall; gimbal euler angles were just set above
        // this same tick, so model is the current pose).
        let origin = rangefinderPitchNode.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(rangefinderPitchNode.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        guard simd_length_squared(forward) > 0.000001 else {
            return nil
        }

        let distanceLimit = max(1.0, Float(maxDistance))
        guard let hit = analyticEnvironmentRayHit(
            origin: origin,
            direction: forward,
            maxDistance: distanceLimit
        ) else {
            return nil
        }
        return Double(hit.distance)
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

    // MARK: - LiDAR survey rig

    func ensureLidarRig() {
        if lidarYawNode.parent !== lidarRigNode {
            lidarRigNode.name = "lidarRigNode"
            lidarYawNode.name = "lidarYawNode"
            lidarPitchNode.name = "lidarPitchNode"
            lidarRigNode.removeFromParentNode()
            lidarYawNode.removeFromParentNode()
            lidarPitchNode.removeFromParentNode()
            lidarRigNode.addChildNode(lidarYawNode)
            lidarYawNode.addChildNode(lidarPitchNode)
            lidarPitchNode.simdPosition = SIMD3<Float>(0.0, -0.04, 0.0)
        }
        if lidarCameraNode == nil {
            let node = SCNNode()
            node.name = "lidarCameraNode"
            // Down the boresight, clear of the airframe. The pitch node's local −Z is the beam
            // direction (world-down at −90° pitch), so a negative Z offset drops the camera below
            // the aircraft and its payload housing — otherwise it stares straight into the drone's
            // own white belly. It looks further along the beam from there, so the spray is in frame.
            node.simdPosition = SIMD3<Float>(0.0, 0.0, -1.2)
            let camera = SCNCamera()
            camera.fieldOfView = 64.0
            camera.zNear = 0.05
            camera.zFar = CameraClipping.payloadOpticsFar
            // Sensor feed, not a photograph: only the returns and the dark shell behind them.
            camera.categoryBitMask = RenderCategory.visibleInLidar
            node.camera = camera
            lidarPitchNode.addChildNode(node)
            lidarCameraNode = node

            // The scene's sky background is drawn for every camera regardless of category masks,
            // so darkness has to be geometry: an inside-out shell riding with the camera. It writes
            // no depth and draws first, so returns at any range paint over it.
            let shell = SCNSphere(radius: 60.0)
            shell.segmentCount = 12
            let shellMaterial = SCNMaterial()
            shellMaterial.lightingModel = .constant
            shellMaterial.diffuse.contents = NSColor.black
            shellMaterial.emission.contents = NSColor(calibratedWhite: 0.015, alpha: 1.0)
            shellMaterial.isDoubleSided = true
            shellMaterial.writesToDepthBuffer = false
            shellMaterial.readsFromDepthBuffer = false
            shell.firstMaterial = shellMaterial
            let shellNode = SCNNode(geometry: shell)
            shellNode.name = "lidarBackdropShell"
            shellNode.categoryBitMask = RenderCategory.lidarBackdrop
            shellNode.renderingOrder = -10_000
            shellNode.castsShadow = false
            node.addChildNode(shellNode)
        }

        if lidarRigNode.parent !== payloadMountNode {
            lidarRigNode.removeFromParentNode()
            payloadMountNode.addChildNode(lidarRigNode)
        }
        // The cloud lives in world space: the points stay put on the terrain as the drone flies on.
        if lidarCloudRootNode.parent == nil {
            lidarCloudRootNode.name = "lidar.cloud.root"
            scene.rootNode.addChildNode(lidarCloudRootNode)
        }
    }

    func updateLidarGimbal(state: PayloadLidarOpticsState) {
        lidarOpticsState = state
        ensureLidarRig()
        lidarRigNode.isHidden = !state.isAvailable
        lidarYawNode.eulerAngles.y = CGFloat(Float(state.gimbalYawDegrees).degreesToRadians)
        lidarPitchNode.eulerAngles.x = CGFloat(Float(state.gimbalPitchDegrees).degreesToRadians)
    }

    func lidarCameraPointOfView() -> SCNNode? {
        guard lidarOpticsState.isAvailable else { return nil }
        ensureLidarRig()
        return lidarCameraNode
    }

    /// One cross-track sweep of the scanner.
    ///
    /// The fan is not fired instantaneously. Beam `i` is cast from the sensor pose interpolated
    /// between the previous sweep and this one and carries the timestamp of that instant, because
    /// the aircraft really does move while the fan sweeps: the returns arrive slightly skewed, which
    /// is the motion distortion a real scanner exhibits — present in the data to be measured rather
    /// than assumed away. Every return keeps its range, intensity, channel and surface class, and
    /// carries ranging noise, which is precisely what the voxel centroid filter averages back out.
    /// Main-actor isolated because it asks the installed world about its water and its surface
    /// provenance, both of which the `FlyableWorld` contract keeps on the main actor. The only
    /// caller is the view model's per-tick refresh, which is already there.
    @MainActor
    func scanLidarSweep(state: PayloadLidarOpticsState) -> LidarScanStatistics {
        guard state.isAvailable, state.isPowered, state.isScanning else {
            return lidarStatistics()
        }
        ensureLidarRig()

        let now = CACurrentMediaTime()
        if lidarEpoch == nil {
            lidarEpoch = now
            lidarEpochDate = Date()
        }
        let epoch = lidarEpoch ?? now
        let blockTimestamp = now - epoch

        // One tick emits one firing block. A multi-channel head fires its whole vertical fan at a
        // single instant, so every channel in a block shares that instant and differs only by the
        // fixed inter-channel delay of the firing sequence — microseconds, far below any motion the
        // airframe can produce. Distortion therefore lives *between* blocks, where the trajectory
        // table corrects it, instead of being smeared through one block's own geometry as it was
        // when the fan was swept across the whole tick.
        let sensorPosition = lidarPitchNode.simdWorldPosition
        let sensorOrientation = simd_normalize(simd_quatf(lidarPitchNode.simdWorldTransform))
        let vehiclePosition = droneNode.simdWorldPosition
        let vehicleOrientation = simd_normalize(simd_quatf(droneNode.simdWorldTransform))
        let boresight = simd_normalize(simd_act(sensorOrientation, SIMD3<Float>(0.0, 0.0, -1.0)))

        let scanID = lidarNextScanID
        lidarNextScanID &+= 1

        // Horizontal flight axis (the airframe's forward), about which the channel fan spreads.
        var axis = simd_act(vehicleOrientation, SIMD3<Float>(0.0, 0.0, -1.0))
        axis.y = 0.0
        let axisLength = simd_length(axis)
        let flightAxis = axisLength > 0.05 ? axis / axisLength : SIMD3<Float>(0.0, 0.0, 1.0)

        let beamCount = max(2, state.beamCount)
        let fanRadians = Float(state.fanFieldOfViewDegrees).degreesToRadians
        let maxRange = max(1.0, Float(state.maxRangeMeters))
        let water = installedWorld?.water
        let foliage = installedWorld?.lidarFoliage
        var blockReturns: [LidarRawCloud.Return] = []
        blockReturns.reserveCapacity(beamCount * Self.lidarMaximumReturnsPerPulse)

        for ring in 0..<beamCount {
            let fraction = Float(ring) / Float(beamCount - 1)
            let angle = (fraction - 0.5) * fanRadians
            let direction = simd_normalize(simd_act(
                simd_quatf(angle: angle, axis: flightAxis),
                boresight
            ))
            let timestamp = blockTimestamp
                + Double(ring) * Self.lidarChannelFiringOffsetSeconds

            // Hard surfaces first: one opaque return, wherever the beam finally stops.
            var pulse: [(position: SIMD3<Float>, normal: SIMD3<Float>, surface: LidarSurfaceClass)] = []
            var hardDistance = maxRange
            if let meshCollision,
               let hit = meshCollision.raycast(
                   origin: sensorPosition,
                   direction: direction,
                   maxDistance: maxRange
               ) {
                hardDistance = hit.distance
                pulse.append((
                    hit.point,
                    hit.normal,
                    installedWorld?.surfaceClass(forTriangle: hit.triangleIndex) ?? .unclassified
                ))
            } else if let hit = analyticEnvironmentRayHit(
                origin: sensorPosition,
                direction: direction,
                maxDistance: maxRange
            ) {
                hardDistance = hit.distance
                pulse.append((sensorPosition + direction * hit.distance, SIMD3<Float>(0.0, 1.0, 0.0), .unclassified))
            }

            // Foliage before it: a crown is a porous medium, not a wall, so returns come from
            // *inside* its depth and a pulse routinely yields a canopy echo and a ground echo
            // behind it. Sensor-only — the flight model's tree proxy is untouched.
            if let foliage, !foliage.isEmpty {
                var foliageReturns: [(distance: Float, position: SIMD3<Float>)] = []
                foliage.candidates(
                    origin: sensorPosition,
                    direction: direction,
                    maxDistance: hardDistance
                ) { volume in
                    guard foliageReturns.count < Self.lidarMaximumReturnsPerPulse,
                          let span = LidarFoliageIndex.intersection(
                              volume: volume,
                              origin: sensorPosition,
                              direction: direction,
                              maxDistance: hardDistance
                          )
                    else { return }

                    // Beer-Lambert: each step through foliage has probability 1 − e^(−μ·ds) of
                    // sending part of the pulse back.
                    let step: Float = 0.4
                    let probability = 1.0 - exp(-volume.density * step)
                    var travelled = span.entry
                    var stepIndex = 0
                    while travelled < span.exit, foliageReturns.count < Self.lidarMaximumReturnsPerPulse {
                        let draw = lidarBeamHash(
                            scanID: scanID,
                            ring: ring &+ stepIndex &* 977,
                            salt: UInt64(volume.center.x.bitPattern) ^ 0xF0_11A6E
                        )
                        if Float(draw % 10_000) / 10_000.0 < probability {
                            foliageReturns.append((
                                travelled,
                                sensorPosition + direction * travelled
                            ))
                        }
                        travelled += step
                        stepIndex += 1
                    }
                }
                for entry in foliageReturns {
                    pulse.append((entry.position, -direction, .vegetation))
                }
                // Echoes must be ordered by range: that ordering is what return_number means.
                pulse.sort { simd_length($0.position - sensorPosition) < simd_length($1.position - sensorPosition) }
                if pulse.count > Self.lidarMaximumReturnsPerPulse {
                    pulse.removeSubrange(Self.lidarMaximumReturnsPerPulse...)
                }
            }

            // Water swallows a topographic scanner's beam: at these wavelengths the surface is
            // specular and reflects it away, so most shots over water return nothing at all and the
            // few that do are single weak surface returns — not the riverbed the ray reaches
            // geometrically (water carries no collision surface of its own).
            if let water, direction.y < 0.0 {
                let travel = (water.level - sensorPosition.y) / direction.y
                let firstGeometry = pulse.first
                    .map { simd_length($0.position - sensorPosition) } ?? .greatestFiniteMagnitude
                if travel > 0.0, travel <= maxRange, travel < firstGeometry {
                    let surfacePoint = sensorPosition + direction * travel
                    if water.isWater(x: surfacePoint.x, z: surfacePoint.z) {
                        guard lidarBeamHash(scanID: scanID, ring: ring, salt: 0x5EA) % 100 < 22
                        else { continue }
                        pulse = [(surfacePoint, SIMD3<Float>(0.0, 1.0, 0.0), .water)]
                    }
                }
            }

            guard !pulse.isEmpty else { continue }
            let numberOfReturns = UInt8(pulse.count)

            for (offset, entry) in pulse.enumerated() {
                let trueRange = simd_length(entry.position - sensorPosition)
                let measuredRange = max(0.05, trueRange + lidarRangeNoise(
                    scanID: scanID,
                    ring: ring &+ offset &* 4_096,
                    range: trueRange
                ))
                let measuredPoint = sensorPosition + direction * measuredRange

                let cosIncidence = abs(simd_dot(direction, simd_normalize(entry.normal)))
                let rangeFactor = max(0.15, 1.0 - (measuredRange / maxRange) * 0.7)
                // A later echo runs on the energy the earlier ones did not absorb.
                let attenuation = pow(0.55, Float(offset))
                let intensity = max(0.01, min(
                    1.0,
                    entry.surface.reflectance * cosIncidence * rangeFactor * attenuation * 1.6
                ))

                blockReturns.append(LidarRawCloud.Return(
                    position: measuredPoint,
                    intensity: intensity,
                    range: measuredRange,
                    timestamp: timestamp,
                    scanID: scanID,
                    ring: UInt16(ring),
                    classification: entry.surface,
                    returnNumber: UInt8(offset + 1),
                    numberOfReturns: numberOfReturns
                ))
            }
        }

        let returnsInScan = blockReturns.count
        lidarScanCount += 1

        // 1. The files, always, from the first block: the complete record, limited only by free
        //    space. The trajectory row is written for every block, including empty ones.
        ensureLidarStreams(colorMode: state.colorMode)
        if !blockReturns.isEmpty {
            lidarRawStream?.write(blockReturns)
            lidarStreamedReturnCount = lidarRawStream?.writtenCount ?? lidarStreamedReturnCount
        }
        lidarTrajectoryStream?.write(LidarScanPose(
            scanID: scanID,
            timestamp: blockTimestamp,
            sensorPosition: sensorPosition,
            sensorOrientation: sensorOrientation,
            vehiclePosition: vehiclePosition,
            vehicleOrientation: vehicleOrientation,
            returnsInScan: returnsInScan
        ))

        // 2. The map keeps its own counsel: it has its own capacity and must not stop merging just
        //    because the bounded preview filled up.
        if lidarMap.canAccept(returnCount: returnsInScan) {
            for entry in blockReturns {
                let result = lidarMap.insert(
                    position: entry.position,
                    intensity: entry.intensity,
                    timestamp: entry.timestamp,
                    classification: entry.classification
                )
                // Only a genuinely new cell needs drawing; a merge refines a centroid already on
                // screen, by at most one voxel edge.
                if case .inserted(let storedIndex) = result {
                    lidarPendingPoints.append(lidarMap.cells[storedIndex])
                }
            }
        }

        // 3. The preview takes blocks whole, in order, until one does not fit — then it latches
        //    closed for the rest of the run rather than cherry-picking whichever later blocks
        //    happen to be small enough.
        if lidarRetainsRawReturns, !lidarPreviewLatched, !blockReturns.isEmpty {
            if lidarRawCloud.canAccept(returnCount: returnsInScan) {
                for entry in blockReturns {
                    lidarRawCloud.append(entry)
                }
            } else {
                lidarPreviewLatched = true
            }
        }

        // Chunks are one draw call each, and from the sensor's own viewpoint every chunk is on
        // screen at once — so flush on a decent batch, not on a twitchy interval that would leave
        // a long survey as hundreds of near-empty nodes.
        if !lidarPendingPoints.isEmpty,
           lidarPendingPoints.count >= 4_000 || now - lidarLastBakeTime > 0.6 {
            bakeLidarChunk(lidarPendingPoints, colorMode: state.colorMode)
            lidarPendingPoints.removeAll(keepingCapacity: true)
            lidarLastBakeTime = now
        }

        return lidarStatistics()
    }

    /// Opens the on-disk record and the trajectory beside it, on the **first block of the run** —
    /// not on the first retained one, and not on export. Both files then cover exactly the stretch
    /// of flight the map and the preview were built from. Main-actor isolated because it reads the
    /// installed world; its only caller is the sweep, which is already there.
    @MainActor
    private func ensureLidarStreams(colorMode: LidarColorMode) {
        guard lidarRawStream == nil else { return }
        let fileManager = FileManager.default
        let directory = InternalStorePaths.lidarSurveys(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: lidarEpochDate ?? Date())
        let epochFormatter = ISO8601DateFormatter()
        epochFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // A stream cannot colour by the cloud's own vertical span — it is unknown while writing —
        // so the height ramp is pinned to the world's extent and stated in the header.
        let bounds = installedWorld?.worldBounds
        let reference = (
            minimum: bounds?.minimum.y ?? 0.0,
            maximum: bounds?.maximum.y ?? 300.0
        )
        let base = "lidar-\(stamp)"
        let epochUTC = lidarEpochDate.map { epochFormatter.string(from: $0) } ?? "unknown"
        lidarSessionBase = base
        lidarRawStream = LidarRawStreamWriter(
            url: directory.appendingPathComponent("\(base)-raw.ply"),
            colorMode: colorMode,
            elevationReference: reference,
            comment: "raw returns, unfiltered, streamed during flight",
            trajectoryFileName: "\(base)-trajectory.csv",
            epochUTC: epochUTC
        )
        lidarTrajectoryStream = LidarTrajectoryStreamWriter(
            url: directory.appendingPathComponent("\(base)-trajectory.csv"),
            origin: installedWorld?.origin,
            epochUTC: epochUTC
        )
        lidarStreamedReturnCount = 0
    }

    /// Makes both files complete on disk without ending the recording — used when scanning stops and
    /// on export, so a paused or exported run is readable and still resumable into the same files.
    func snapshotLidarStreams() {
        lidarRawStream?.snapshot()
        lidarTrajectoryStream?.snapshot()
    }

    private func lidarStatistics() -> LidarScanStatistics {
        LidarScanStatistics(
            mapPointCount: lidarMap.count,
            rawReturnCount: lidarRetainsRawReturns ? lidarStreamedReturnCount : 0,
            coverageSquareMeters: Double(lidarMap.coverageSquareMeters),
            meanReturnsPerPoint: Double(lidarMap.meanReturnsPerCell),
            scanCount: lidarScanCount,
            // "Full" now means the *preview* stopped taking blocks — the file keeps recording.
            isBufferFull: lidarPreviewLatched || lidarMap.isFull
        )
    }

    /// Deterministic per-beam hash — SplitMix64 finalisation over the beam's identity.
    private func lidarBeamHash(scanID: UInt32, ring: Int, salt: UInt64) -> UInt64 {
        var value = UInt64(scanID) &* 0x9E37_79B9_7F4A_7C15
        value ^= UInt64(UInt32(truncatingIfNeeded: ring)) &* 0xBF58_476D_1CE4_E5B9
        value ^= salt
        value ^= value >> 30
        value = value &* 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value = value &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return value
    }

    private func lidarRangeNoise(scanID: UInt32, ring: Int, range: Float) -> Float {
        let hash = lidarBeamHash(scanID: scanID, ring: ring, salt: 0x9E17_5E00)
        let first = max(1e-7, Float(hash & 0xFF_FFFF) / Float(0xFF_FFFF))
        let second = Float((hash >> 24) & 0xFF_FFFF) / Float(0xFF_FFFF)
        // Box-Muller: uniform pair to a standard normal.
        let gaussian = (-2.0 * log(first)).squareRoot() * cos(2.0 * .pi * second)
        let sigma = 0.012 + range * 0.00005
        return gaussian * sigma
    }

    private func bakeLidarChunk(_ points: [LidarVoxelMap.Cell], colorMode: LidarColorMode) {
        guard !points.isEmpty else { return }
        let range = lidarMap.elevationRange
            ?? (points[0].position.y, points[0].position.y + 1.0)

        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(points.count)
        var colors: [SIMD4<Float>] = []
        colors.reserveCapacity(points.count)
        for point in points {
            // Visual lift only — the exported cloud keeps the true hit position.
            vertices.append(SCNVector3(
                point.position.x,
                point.position.y + 0.08,
                point.position.z
            ))
            let color = LidarColorResolver.color(
                classification: point.classification,
                intensity: point.intensity,
                height: point.position.y,
                mode: colorMode,
                elevationMinimum: range.minimum,
                elevationMaximum: range.maximum
            )
            // Lifted toward white: against the sensor's black field these read as glowing returns
            // rather than flat paint. The exported cloud keeps the unboosted ramp.
            colors.append(SIMD4<Float>(
                min(1.0, Float(color.red) / 255.0 * 1.35 + 0.10),
                min(1.0, Float(color.green) / 255.0 * 1.35 + 0.10),
                min(1.0, Float(color.blue) / 255.0 * 1.35 + 0.10),
                1.0
            ))
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = colors.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let element = SCNGeometryElement(
            indices: Array(0..<Int32(vertices.count)),
            primitiveType: .point
        )
        element.pointSize = 3.2
        element.minimumPointScreenSpaceRadius = 1.4
        element.maximumPointScreenSpaceRadius = 4.5

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        // Points DO write depth. Looking straight down the sensor boresight stacks the whole cloud
        // column into a few pixels; with depth writes off, every one of those overlapping sprites
        // was shaded. Writing depth lets the nearest point win each pixel.
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "lidar.chunk"
        node.castsShadow = false
        // Ordinary cameras carry this bit inside `standardVisible`, so the cloud is still visible
        // in the normal 3-D view; the sensor camera carries only this and the backdrop.
        node.categoryBitMask = RenderCategory.lidarCloud
        lidarCloudRootNode.addChildNode(node)
    }

    /// Re-colours the whole stored survey — the returns are untouched, only their RGB is re-derived,
    /// so switching view mode is free of any data loss.
    func rebuildLidarVisual(colorMode: LidarColorMode) {
        lidarCloudRootNode.childNodes.forEach { $0.removeFromParentNode() }
        lidarPendingPoints.removeAll(keepingCapacity: true)
        guard !lidarMap.isEmpty else { return }
        let batch = 60_000
        var start = 0
        while start < lidarMap.cells.count {
            let end = min(start + batch, lidarMap.cells.count)
            bakeLidarChunk(Array(lidarMap.cells[start..<end]), colorMode: colorMode)
            start = end
        }
    }

    /// Applies a new filter configuration. Returns true when the stored survey had to be discarded
    /// — a coarser cloud cannot be refined back, and raw returns a previous voxel pass threw away
    /// cannot be recovered.
    @discardableResult
    func configureLidarFilter(voxelSizeMeters: Float, retainsRawReturns: Bool) -> Bool {
        let voxelChanged = lidarMap.voxelSizeMeters != voxelSizeMeters
        guard voxelChanged || lidarRetainsRawReturns != retainsRawReturns else { return false }
        let hadPoints = !lidarMap.isEmpty || !lidarRawCloud.isEmpty
        lidarRetainsRawReturns = retainsRawReturns
        lidarRawStream?.discard()
        lidarTrajectoryStream?.discard()
        lidarRawStream = nil
        lidarTrajectoryStream = nil
        lidarSessionBase = nil
        lidarStreamedReturnCount = 0
        lidarScanCount = 0
        lidarPreviewLatched = false
        // Re-voxelising cannot recover what a coarser pass already merged, and raw retention that
        // was off cannot be back-filled, so both products restart together and stay consistent.
        lidarMap.reconfigure(voxelSizeMeters: voxelSizeMeters)
        lidarRawCloud.clear()
        lidarPendingPoints.removeAll(keepingCapacity: true)
        lidarCloudRootNode.childNodes.forEach { $0.removeFromParentNode() }
        return hadPoints
    }

    func clearLidarCloud() {
        // Clearing is a discard, not an export: the partial recording goes with it.
        lidarRawStream?.discard()
        lidarTrajectoryStream?.discard()
        lidarRawStream = nil
        lidarTrajectoryStream = nil
        lidarSessionBase = nil
        lidarStreamedReturnCount = 0
        lidarScanCount = 0
        lidarPreviewLatched = false
        lidarMap.clear()
        lidarRawCloud.clear()
        lidarPendingPoints.removeAll(keepingCapacity: true)
        lidarEpoch = nil
        lidarEpochDate = nil
        lidarNextScanID = 0
        lidarCloudRootNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    /// Writes the survey to the app's `LidarSurveys` folder and returns the written files: a binary
    /// PLY (position, RGB and every physical attribute), a geo-referenced CSV in WGS84, and the
    /// sensor trajectory, one row per sweep, without which the cloud could not be de-skewed.
    /// Publishes the run's four views as of this instant. The streams are **snapshotted, not
    /// closed**: their files become complete and readable while the same continuous recording keeps
    /// growing into them, so a second export later covers the same run rather than starting a new
    /// one. Every file shares the session stem, so the four belong together by name as well.
    func exportLidarCloud(origin: GeoOrigin?, colorMode: LidarColorMode) -> [URL]? {
        guard !lidarMap.isEmpty || lidarStreamedReturnCount > 0 else { return nil }
        let fileManager = FileManager.default
        let directory = InternalStorePaths.lidarSurveys(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = lidarSessionBase ?? "lidar-\(formatter.string(from: lidarEpochDate ?? Date()))"
        let epochFormatter = ISO8601DateFormatter()
        epochFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let epochUTC = lidarEpochDate.map { epochFormatter.string(from: $0) } ?? "unknown"

        var written: [URL] = []
        func write(_ data: Data, _ name: String) {
            let url = directory.appendingPathComponent(name)
            if (try? data.write(to: url, options: .atomic)) != nil {
                written.append(url)
            }
        }

        let rawURL = lidarRawStream?.snapshot()
        let trajectoryURL = lidarTrajectoryStream?.snapshot()

        // The map product: voxel centroids, aggregate attributes only.
        if !lidarMap.isEmpty {
            write(
                lidarMap.binaryPLYData(
                    colorMode: colorMode,
                    comment: "voxel centroid map, \(lidarMap.voxelSizeMeters) m",
                    rawFileName: rawURL?.lastPathComponent,
                    epochUTC: epochUTC
                ),
                "\(base)-map.ply"
            )
            if let origin {
                write(lidarMap.geoCSVData(origin: origin), "\(base)-map.csv")
            }
        }
        if let rawURL { written.append(rawURL) }
        if let trajectoryURL { written.append(trajectoryURL) }
        return written.isEmpty ? nil : written
    }

    // MARK: - Fire hose rig

    func ensureHoseRig() {
        if hoseYawNode.parent !== hoseRigNode {
            hoseRigNode.name = "hoseRigNode"
            hoseYawNode.name = "hoseYawNode"
            hosePitchNode.name = "hosePitchNode"

            hoseRigNode.removeFromParentNode()
            hoseYawNode.removeFromParentNode()
            hosePitchNode.removeFromParentNode()

            hoseRigNode.addChildNode(hoseYawNode)
            hoseYawNode.addChildNode(hosePitchNode)
            // The detailed payload model's physical monitor pivot is on its right-hand side and
            // its branch pipe points along payload-local +X. The aiming math uses local -Z, so the
            // base rotation aligns those coordinate systems instead of drawing an unrelated red
            // rod straight down through the airframe.
            hoseRigNode.simdPosition = SIMD3<Float>(0.067, -0.098, 0.0)
            hoseRigNode.eulerAngles = SCNVector3(0.0, -Float.pi / 2.0, 0.0)
            hosePitchNode.simdPosition = .zero
        }

        if hoseBodyNode == nil {
            hoseNozzleAssemblyNode.name = "hoseNozzleAssemblyNode"
            hosePitchNode.addChildNode(hoseNozzleAssemblyNode)

            let barrelMaterial = SCNMaterial()
            barrelMaterial.lightingModel = .physicallyBased
            barrelMaterial.diffuse.contents = NSColor(calibratedWhite: 0.10, alpha: 1.0)
            barrelMaterial.metalness.contents = 0.68
            barrelMaterial.roughness.contents = 0.38

            let couplingMaterial = SCNMaterial()
            couplingMaterial.lightingModel = .physicallyBased
            couplingMaterial.diffuse.contents = NSColor(calibratedWhite: 0.58, alpha: 1.0)
            couplingMaterial.metalness.contents = 0.82
            couplingMaterial.roughness.contents = 0.26

            let mouthMaterial = SCNMaterial()
            mouthMaterial.lightingModel = .physicallyBased
            mouthMaterial.diffuse.contents = NSColor(calibratedWhite: 0.025, alpha: 1.0)
            mouthMaterial.roughness.contents = 0.92

            let geometry = SCNCylinder(radius: 0.021, height: 0.09)
            geometry.radialSegmentCount = 24
            geometry.firstMaterial = barrelMaterial

            let body = SCNNode(geometry: geometry)
            body.name = "hoseBodyNode"
            body.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
            body.position = SCNVector3(0.0, 0.0, -0.045)
            body.isHidden = true
            hoseNozzleAssemblyNode.addChildNode(body)
            hoseBodyNode = body

            let reducer = SCNCone(topRadius: 0.010, bottomRadius: 0.021, height: 0.066)
            reducer.radialSegmentCount = 24
            reducer.firstMaterial = couplingMaterial
            let reducerNode = SCNNode(geometry: reducer)
            reducerNode.name = "hoseNozzleReducerNode"
            reducerNode.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
            reducerNode.position = SCNVector3(0.0, 0.0, -0.123)
            hoseNozzleAssemblyNode.addChildNode(reducerNode)

            let lip = SCNTorus(ringRadius: 0.0105, pipeRadius: 0.0024)
            lip.ringSegmentCount = 32
            lip.pipeSegmentCount = 10
            lip.firstMaterial = couplingMaterial
            let lipNode = SCNNode(geometry: lip)
            lipNode.name = "hoseNozzleLipNode"
            lipNode.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            lipNode.position = SCNVector3(0.0, 0.0, -0.158)
            hoseNozzleAssemblyNode.addChildNode(lipNode)

            let mouth = SCNCylinder(radius: 0.008, height: 0.008)
            mouth.radialSegmentCount = 24
            mouth.firstMaterial = mouthMaterial
            let mouthNode = SCNNode(geometry: mouth)
            mouthNode.name = "hoseNozzleMouthNode"
            mouthNode.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
            mouthNode.position = SCNVector3(0.0, 0.0, -0.163)
            hoseNozzleAssemblyNode.addChildNode(mouthNode)

            hoseNozzleTipNode.name = "hoseNozzleTipNode"
            hoseNozzleTipNode.simdPosition = SIMD3<Float>(0.0, 0.0, -0.169)
            hosePitchNode.addChildNode(hoseNozzleTipNode)
        }

        // The catalogue model keeps its own fixed barrel for standalone previews. Once mounted,
        // the animated barrel above replaces only those two static pieces; the cradle, valve and
        // swivel remain visible and connected.
        payloadVisualNode?.childNode(withName: "payloadFireHoseStaticBarrelNode", recursively: true)?.isHidden = true
        payloadVisualNode?.childNode(withName: "payloadFireHoseStaticTipNode", recursively: true)?.isHidden = true

        if hoseCameraNode == nil {
            let node = SCNNode()
            node.name = "hoseCameraNode"

            let camera = SCNCamera()
            camera.fieldOfView = 45.0
            camera.zNear = 0.015
            camera.zFar = CameraClipping.payloadOpticsFar
            camera.categoryBitMask = RenderCategory.visibleInPayloadOptics
            node.camera = camera

            hosePitchNode.addChildNode(node)
            hoseCameraNode = node
            hoseCamera = camera
        }

        // Deliberately created WITHOUT particle systems attached — same "hidden but still
        // simulating" cost as the fire flipbook/smoke fix above applies here too: these ran at
        // birthRate 300/70 continuously in the background for the entire mission whenever a hose
        // is mounted, even while not spraying (the vast majority of the time). Attached/removed
        // on the actual spray-state transition instead, see `updateHoseAimAndSpray`/`hideHoseSprayVisual`.
        if hoseStreamNode == nil {
            let node = SCNNode()
            node.name = "hoseStreamNode"
            node.simdPosition = .zero
            node.isHidden = true
            hoseNozzleTipNode.addChildNode(node)
            hoseStreamNode = node
        }

        if hoseImpactNode == nil {
            let node = SCNNode()
            node.name = "hoseImpactNode"
            node.isHidden = true
            hoseNozzleTipNode.addChildNode(node)
            hoseImpactNode = node
        }

        if hoseRigNode.parent !== payloadMountNode {
            hoseRigNode.removeFromParentNode()
            payloadMountNode.addChildNode(hoseRigNode)
        }
    }

    func updateHoseGimbal(
        state: PayloadFireHoseOpticsState,
        tetherLengthMeters: Float,
        diameterClass: FireHoseDiameterClass,
        deltaTime: Float
    ) {
        hoseOpticsState = state
        ensureHoseRig()

        hoseRigNode.isHidden = !state.isAvailable
        updateFireHosePhysics(
            isAvailable: state.isAvailable,
            tetherLengthMeters: tetherLengthMeters,
            diameterClass: diameterClass,
            deltaTime: deltaTime
        )
        hoseYawNode.eulerAngles.y = CGFloat(Float(state.gimbalYawDegrees).degreesToRadians)
        hosePitchNode.eulerAngles.x = CGFloat(Float(state.gimbalPitchDegrees).degreesToRadians)

        guard let body = hoseBodyNode else { return }
        guard state.isAvailable, state.isPowered else {
            hoseNozzleAssemblyNode.isHidden = true
            return
        }
        // A branch pipe is rigid hardware: spraying changes only the emitted particles, never the
        // length of the mesh. Stretching this cylinder was the visible red "cut-off" the user saw.
        hoseNozzleAssemblyNode.isHidden = false
        body.isHidden = false
    }

    /// Simulates the charged supply line as a position-based dynamics chain. Every particle has
    /// inertia and gravity, adjacent particles keep a fixed rest distance, intermediate points
    /// collide with the ground and lose tangential speed through friction, and only the pump and
    /// swivel endpoints are pinned. This is deliberately not an analytic curve rebuilt between
    /// two points: turns, acceleration and landing leave visible motion in the hose itself.
    private func updateFireHosePhysics(
        isAvailable: Bool,
        tetherLengthMeters: Float,
        diameterClass: FireHoseDiameterClass,
        deltaTime: Float
    ) {
        guard isAvailable,
              let truck = activeFireTruckNode,
              let start = currentFireHoseAnchorWorldPosition() else {
            resetFireHoseSimulation(hideVisual: true)
            return
        }

        let configuredLength = max(1.0, tetherLengthMeters)
        // Short links and matching joint sleeves make the rendered line read as one continuous
        // hose even while the PBD particles articulate independently. Long 150 m configurations
        // cap the count to keep the per-frame constraint pass bounded.
        let segmentCount = min(120, max(36, Int(ceil(configuredLength / 0.5))))
        let hoseRadius: Float = diameterClass == .narrow ? 0.025 : 0.038
        let restLength = configuredLength / Float(segmentCount)

        let end = currentFireHosePayloadAnchorWorldPosition()

        if fireHoseTetherSegmentNodes.count != segmentCount {
            fireHoseTetherNode.childNodes.forEach { $0.removeFromParentNode() }
            fireHoseTetherSegmentNodes.removeAll(keepingCapacity: true)
            fireHoseTetherJointNodes.removeAll(keepingCapacity: true)

            let hoseMaterial = SCNMaterial()
            hoseMaterial.lightingModel = .physicallyBased
            hoseMaterial.diffuse.contents = NSColor(calibratedRed: 0.48, green: 0.07, blue: 0.045, alpha: 1.0)
            hoseMaterial.roughness.contents = 0.86
            hoseMaterial.metalness.contents = 0.0

            for index in 0..<segmentCount {
                let cylinder = SCNCylinder(radius: CGFloat(hoseRadius), height: 1.0)
                cylinder.radialSegmentCount = 8
                cylinder.firstMaterial = hoseMaterial
                let segment = SCNNode(geometry: cylinder)
                segment.name = "fireHoseTetherSegment.\(index)"
                segment.castsShadow = true
                fireHoseTetherNode.addChildNode(segment)
                fireHoseTetherSegmentNodes.append(segment)
            }

            for index in 1..<segmentCount {
                let sleeve = SCNSphere(radius: CGFloat(hoseRadius * 1.02))
                sleeve.segmentCount = 8
                sleeve.firstMaterial = hoseMaterial
                let joint = SCNNode(geometry: sleeve)
                joint.name = "fireHoseTetherJoint.\(index)"
                joint.castsShadow = true
                fireHoseTetherNode.addChildNode(joint)
                fireHoseTetherJointNodes.append(joint)
            }
        } else {
            for segment in fireHoseTetherSegmentNodes {
                (segment.geometry as? SCNCylinder)?.radius = CGFloat(hoseRadius)
            }
            for joint in fireHoseTetherJointNodes {
                (joint.geometry as? SCNSphere)?.radius = CGFloat(hoseRadius * 1.02)
            }
        }

        let particlesAreFinite = fireHoseParticlePositions.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        }
        let endpointJump = fireHoseParticlePositions.last.map { simd_distance($0, end) } ?? .infinity
        let needsReset = fireHoseParticlePositions.count != segmentCount + 1
            || fireHosePreviousParticlePositions.count != segmentCount + 1
            || abs(fireHoseSimulatedLengthMeters - configuredLength) > 0.01
            || fireHoseSimulationTruckNode !== truck
            || !particlesAreFinite
            || endpointJump > max(5.0, restLength * 4.0)

        let startGround = supportSurfaceHeight(
            at: SIMD2<Float>(start.x, start.z),
            clearanceRadius: hoseRadius,
            maximumHeight: start.y + 4.0
        ) ?? min(start.y, dockSpawnPosition.y)
        let endGround = supportSurfaceHeight(
            at: SIMD2<Float>(end.x, end.z),
            clearanceRadius: hoseRadius,
            maximumHeight: max(end.y + 4.0, startGround + 20.0)
        ) ?? startGround

        func groundHeight(for particleIndex: Int) -> Float {
            let t = Float(particleIndex) / Float(segmentCount)
            return startGround + (endGround - startGround) * t + hoseRadius
        }

        if needsReset {
            fireHoseParticlePositions = []
            fireHoseParticlePositions.reserveCapacity(segmentCount + 1)
            let straightDistance = simd_distance(start, end)
            let slack = max(0.0, configuredLength - straightDistance)
            let horizontal = SIMD3<Float>(end.x - start.x, 0.0, end.z - start.z)
            let lateral: SIMD3<Float>
            if simd_length_squared(horizontal) > 0.0001 {
                lateral = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), horizontal))
            } else {
                lateral = SIMD3<Float>(1, 0, 0)
            }
            let initialSag = min(3.0, max(0.12, slack * 0.10))

            // Seed slack as one broad S laid on the ground, not as compressed distance that the
            // solver has to dispose of as a high-frequency accordion. Binary-searching the
            // lateral amplitude gives the starting polyline the configured arc length while
            // leaving the physical solver free to move it afterwards.
            func initialPoint(index: Int, lateralAmplitude: Float) -> SIMD3<Float> {
                let t = Float(index) / Float(segmentCount)
                var point = start + (end - start) * t
                point.y -= initialSag * sinf(.pi * t)
                point += lateral * (lateralAmplitude * sinf(.pi * 2.0 * t))
                if index > 0 && index < segmentCount {
                    point.y = max(point.y, groundHeight(for: index))
                }
                return point
            }

            func initialPathLength(lateralAmplitude: Float) -> Float {
                var total: Float = 0.0
                var previous = initialPoint(index: 0, lateralAmplitude: lateralAmplitude)
                for index in 1...segmentCount {
                    let current = initialPoint(index: index, lateralAmplitude: lateralAmplitude)
                    total += simd_distance(previous, current)
                    previous = current
                }
                return total
            }

            var amplitudeLow: Float = 0.0
            var amplitudeHigh = max(0.5, configuredLength * 0.55)
            while initialPathLength(lateralAmplitude: amplitudeHigh) < configuredLength,
                  amplitudeHigh < configuredLength {
                amplitudeHigh *= 1.5
            }
            for _ in 0..<14 {
                let candidate = (amplitudeLow + amplitudeHigh) * 0.5
                if initialPathLength(lateralAmplitude: candidate) < configuredLength {
                    amplitudeLow = candidate
                } else {
                    amplitudeHigh = candidate
                }
            }
            let lateralSlack = (amplitudeLow + amplitudeHigh) * 0.5

            for index in 0...segmentCount {
                fireHoseParticlePositions.append(
                    initialPoint(index: index, lateralAmplitude: lateralSlack)
                )
            }
            fireHosePreviousParticlePositions = fireHoseParticlePositions
            fireHoseSimulatedLengthMeters = configuredLength
            fireHoseSimulationTruckNode = truck
        }

        let clampedDelta = min(max(0.0, deltaTime), 1.0 / 15.0)
        if clampedDelta > 0.0001 {
            let substepCount = min(4, max(1, Int(ceil(clampedDelta / (1.0 / 60.0)))))
            let substepDelta = clampedDelta / Float(substepCount)
            let damping = powf(0.985, substepDelta * 60.0)
            let gravityStep = SIMD3<Float>(0.0, -9.81 * 0.82 * substepDelta * substepDelta, 0.0)

            for _ in 0..<substepCount {
                fireHoseParticlePositions[0] = start
                fireHoseParticlePositions[segmentCount] = end
                fireHosePreviousParticlePositions[0] = start
                fireHosePreviousParticlePositions[segmentCount] = end

                for index in 1..<segmentCount {
                    let current = fireHoseParticlePositions[index]
                    let velocity = (current - fireHosePreviousParticlePositions[index]) * damping
                    fireHosePreviousParticlePositions[index] = current
                    fireHoseParticlePositions[index] = current + velocity + gravityStep

                    let floorY = groundHeight(for: index)
                    if fireHoseParticlePositions[index].y < floorY {
                        let horizontalVelocity = SIMD3<Float>(velocity.x, 0.0, velocity.z) * 0.42
                        fireHoseParticlePositions[index].y = floorY
                        fireHosePreviousParticlePositions[index] = fireHoseParticlePositions[index] - horizontalVelocity
                    }
                }

                // Alternating passes keep the constraint response symmetric and propagate a
                // moving endpoint through a long 150 m hose without making it numerically rigid.
                for iteration in 0..<14 {
                    let forward = iteration.isMultiple(of: 2)

                    // A charged fabric hose resists sharp alternating folds. This inexpensive
                    // bending term gives excess length broad loops while preserving dynamic lag;
                    // the final distance-only passes restore the exact per-link rest length.
                    if iteration < 6, forward {
                        for index in 1..<segmentCount {
                            let midpoint = (
                                fireHoseParticlePositions[index - 1]
                                    + fireHoseParticlePositions[index + 1]
                            ) * 0.5
                            fireHoseParticlePositions[index] += (
                                midpoint - fireHoseParticlePositions[index]
                            ) * 0.08
                        }
                    } else if iteration < 6 {
                        for index in stride(from: segmentCount - 1, through: 1, by: -1) {
                            let midpoint = (
                                fireHoseParticlePositions[index - 1]
                                    + fireHoseParticlePositions[index + 1]
                            ) * 0.5
                            fireHoseParticlePositions[index] += (
                                midpoint - fireHoseParticlePositions[index]
                            ) * 0.08
                        }
                    }

                    func satisfyDistanceConstraint(at index: Int) {
                        let nextIndex = index + 1
                        let delta = fireHoseParticlePositions[nextIndex] - fireHoseParticlePositions[index]
                        let distance = simd_length(delta)
                        guard distance > 0.00001 else { return }
                        let correction = delta * ((distance - restLength) / distance)

                        if index == 0 {
                            fireHoseParticlePositions[nextIndex] -= correction
                        } else if nextIndex == segmentCount {
                            fireHoseParticlePositions[index] += correction
                        } else {
                            fireHoseParticlePositions[index] += correction * 0.5
                            fireHoseParticlePositions[nextIndex] -= correction * 0.5
                        }
                    }

                    if forward {
                        for index in 0..<segmentCount {
                            satisfyDistanceConstraint(at: index)
                        }
                    } else {
                        for index in stride(from: segmentCount - 1, through: 0, by: -1) {
                            satisfyDistanceConstraint(at: index)
                        }
                    }

                    fireHoseParticlePositions[0] = start
                    fireHoseParticlePositions[segmentCount] = end
                    for index in 1..<segmentCount {
                        fireHoseParticlePositions[index].y = max(
                            fireHoseParticlePositions[index].y,
                            groundHeight(for: index)
                        )
                    }
                }
            }
        }

        for index in 0..<segmentCount {
            let previousPoint = fireHoseParticlePositions[index]
            let point = fireHoseParticlePositions[index + 1]
            let delta = point - previousPoint
            let length = max(0.001, simd_length(delta))
            let segment = fireHoseTetherSegmentNodes[index]
            segment.simdPosition = (previousPoint + point) * 0.5
            segment.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0.0, 1.0, 0.0),
                to: delta / length
            )
            (segment.geometry as? SCNCylinder)?.height = CGFloat(length)
        }
        for index in 1..<segmentCount {
            fireHoseTetherJointNodes[index - 1].simdPosition = fireHoseParticlePositions[index]
        }

        fireHoseTetherNode.isHidden = false
    }

    private func resetFireHoseSimulation(hideVisual: Bool) {
        fireHoseParticlePositions.removeAll(keepingCapacity: false)
        fireHosePreviousParticlePositions.removeAll(keepingCapacity: false)
        fireHoseSimulatedLengthMeters = 0.0
        fireHoseSimulationTruckNode = nil
        if hideVisual {
            fireHoseTetherNode.isHidden = true
        }
    }

    /// Common raycast along the hose nozzle's current aim direction, out to its fixed spray-throw
    /// distance (nozzle pump pressure, not hose length). Shared by the suppression-target lookup
    /// and the visible foam stream, so both always agree on where the nozzle is actually pointing.
    /// Analytic (`analyticEnvironmentRayHit`), not a SceneKit hit test — see that function's note.
    private func hoseAimRaycast() -> (
        origin: SIMD3<Float>,
        forward: SIMD3<Float>,
        hitDistance: Float?,
        hitObstacleID: UUID?
    )? {
        guard hoseOpticsState.isAvailable, hoseOpticsState.isPowered else { return nil }
        ensureHoseRig()

        // Model transform, not `.presentation` — see `payloadCameraTargetDistance` for why
        // (avoids a ~16ms render-thread scene-lock stall).
        let origin = hoseNozzleTipNode.simdWorldPosition
        let forward = simd_normalize(simd_act(
            simd_quatf(hoseNozzleTipNode.simdWorldTransform),
            SIMD3<Float>(0.0, 0.0, -1.0)
        ))
        guard simd_length_squared(forward) > 0.000001 else { return nil }

        let reach = max(1.0, Float(hoseOpticsState.nozzleThrowMeters))
        if let hit = analyticEnvironmentRayHit(origin: origin, direction: forward, maxDistance: reach) {
            return (origin, forward, hit.distance, hit.obstacleID)
        }
        return (origin, forward, nil, nil)
    }

    /// Single per-tick nozzle raycast, shared by the suppression-target lookup and the visible
    /// foam stream — previously each ran its own full-scene `hitTestWithSegment` independently, so
    /// every tick spent spraying paid for this expensive query twice over. Returns the index into
    /// `fireTreeNodes` of the first thing hit, if (and only if) that first hit is one of the
    /// tracked fire trees — a tree partially screened by terrain/another tree in front of it is
    /// correctly not aimable, same LOS spirit as the payload camera's mission sample. As a side
    /// effect, positions and shows/hides the foam stream/impact visuals to match wherever the
    /// nozzle points while `isSpraying`, independent of whether that hit counts as a suppression
    /// target (a real hose sprays wherever it's pointed, on-target or not).
    @discardableResult
    func updateHoseAimAndSpray(fireTreeNodes: [SCNNode], isSpraying: Bool) -> Int? {
        ensureHoseRig()
        guard let hit = hoseAimRaycast() else {
            hideHoseSprayVisual()
            return nil
        }

        // The analytic hit reports the obstacle it struck; fire trees registered their collision
        // proxies with `obstacleMap[id] = tree` in `spawnFireResponseScenario`, where `tree` is
        // the exact node stored in `fireTreeNodes` — so owner-identity lookup replaces the old
        // hit-node-descendant walk.
        let aimedIndex: Int? = hit.hitObstacleID.flatMap { obstacleID in
            guard let ownerNode = obstacleMap[obstacleID] else { return nil }
            return fireTreeNodes.firstIndex { $0 === ownerNode }
        }

        guard isSpraying, let stream = hoseStreamNode, let impact = hoseImpactNode else {
            hideHoseSprayVisual()
            return aimedIndex
        }

        let endpoint: SIMD3<Float>
        if let hitDistance = hit.hitDistance {
            endpoint = hit.origin + hit.forward * hitDistance
        } else {
            let reach = max(1.0, Float(hoseOpticsState.nozzleThrowMeters))
            endpoint = hit.origin + hit.forward * reach
        }

        let distance = max(0.3, simd_distance(hit.origin, endpoint))

        if stream.particleSystems?.isEmpty ?? true {
            stream.addParticleSystem(FireVisualAssetLoader.shared.makeFoamStreamParticleSystem())
        }
        if impact.particleSystems?.isEmpty ?? true {
            impact.addParticleSystem(FireVisualAssetLoader.shared.makeFoamImpactParticleSystem())
        }

        stream.isHidden = false
        impact.isHidden = false
        impact.simdPosition = SIMD3<Float>(0.0, 0.0, -distance)

        if let particleSystem = stream.particleSystems?.first {
            let travelTime: CGFloat = 0.35
            let travelDistance = CGFloat(max(0.3, distance - 0.4))
            particleSystem.particleLifeSpan = travelTime
            particleSystem.particleVelocity = travelDistance / travelTime
            particleSystem.particleVelocityVariation = particleSystem.particleVelocity * 0.08
        }

        return aimedIndex
    }

    /// Cheap fallback for ticks that skip the raycast entirely (see
    /// `DroneSimulationViewModel.refreshHoseAimStatus`) — hides the spray visuals AND detaches
    /// their particle systems (not just `isHidden`, which only skips drawing — a `loops = true`
    /// particle system keeps emitting/simulating in the background otherwise, a constant tax for
    /// the whole mission whenever a hose is mounted, not just while actively spraying) so a stream
    /// that was visible on a previous tick doesn't stay stuck on-screen, and doesn't keep costing
    /// anything, once spraying/viewing the hose optics stops.
    ///
    /// Called every non-spraying/non-viewing tick (i.e. nearly always, for the whole mission,
    /// whenever a hose is mounted) — so `removeAllParticleSystems()` must be skipped once already
    /// empty. That call mutates the render scene graph, which (measured directly: a constant
    /// ~16ms/tick, exactly one frame at 60Hz) blocks the main thread on the render thread's scene
    /// lock while it's busy drawing dense forest, same class of stall as reading `.presentation`
    /// from the main thread. Guarding it turns a per-tick cost into a one-time cost at the actual
    /// stop-spraying transition.
    func hideHoseSprayVisual() {
        hoseStreamNode?.isHidden = true
        hoseImpactNode?.isHidden = true
        if hoseStreamNode?.particleSystems?.isEmpty == false {
            hoseStreamNode?.removeAllParticleSystems()
        }
        if hoseImpactNode?.particleSystems?.isEmpty == false {
            hoseImpactNode?.removeAllParticleSystems()
        }
    }

    private enum AgriculturalSprayVFXTuning {
        /// Minimum planar distance between two consecutive wet-ground decals — spraying every
        /// tick would drop a decal 60x/sec at typical framerates, far denser than needed.
        static let decalSpacingMeters: Float = 0.6
        /// Bounds memory/node count for a long spraying pass — oldest decals are dropped first.
        static let maxDecalCount = 260
    }

    /// No aiming, no raycast — the sprayer always emits straight down from the payload mount
    /// while the trigger is held. Mirrors the hose stream's discipline of only attaching the
    /// particle system while actually visible, not for the whole mission a sprayer is mounted.
    func setAgriculturalSprayerSpraying(_ isSpraying: Bool, dronePlanarPosition: SIMD2<Float>) {
        if agriculturalSprayerMistNode == nil {
            let node = SCNNode()
            node.name = "agriculturalSprayerMistNode"
            node.simdPosition = SIMD3<Float>(0.0, -0.06, 0.0)
            node.isHidden = true
            payloadMountNode.addChildNode(node)
            agriculturalSprayerMistNode = node
        }
        guard let mistNode = agriculturalSprayerMistNode else {
            return
        }

        guard isSpraying else {
            mistNode.isHidden = true
            if mistNode.particleSystems?.isEmpty == false {
                mistNode.removeAllParticleSystems()
            }
            lastAgriculturalWetDecalPlanarPosition = nil
            return
        }

        mistNode.isHidden = false
        if mistNode.particleSystems?.isEmpty ?? true {
            let system = SCNParticleSystem()
            system.particleColor = NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.80, alpha: 0.55)
            system.particleSize = 0.05
            system.particleSizeVariation = 0.02
            system.birthRate = 220
            system.emitterShape = SCNCylinder(radius: 0.16, height: 0.02)
            system.birthLocation = .volume
            system.birthDirection = .constant
            system.emittingDirection = SCNVector3(0, -1, 0)
            system.spreadingAngle = 22
            system.particleVelocity = 3.2
            system.particleVelocityVariation = 0.8
            system.particleLifeSpan = 0.9
            system.particleLifeSpanVariation = 0.2
            system.isAffectedByGravity = true
            system.acceleration = SCNVector3(0, -1.4, 0)
            system.blendMode = .alpha
            system.loops = true
            mistNode.addParticleSystem(system)
        }

        dropAgriculturalWetGroundDecalIfNeeded(at: dronePlanarPosition)
    }

    /// The mist particles above fall from the payload mount and die out within ~1s/~3m — at any
    /// normal flight altitude they never actually reach the ground, so "spraying" had no visible
    /// effect on the field at all. Ground truth is tracked here instead: a trail of darkened,
    /// slightly irregular patches dropped along the flight path at the analytic ground height
    /// (`supportSurfaceHeight`, no SceneKit hit-testing) — the same "wet ground" read as the hose
    /// truck's own foam/impact visuals, just left behind rather than momentary.
    private func dropAgriculturalWetGroundDecalIfNeeded(at dronePlanarPosition: SIMD2<Float>) {
        if let lastPosition = lastAgriculturalWetDecalPlanarPosition,
           simd_distance(dronePlanarPosition, lastPosition) < AgriculturalSprayVFXTuning.decalSpacingMeters {
            return
        }
        lastAgriculturalWetDecalPlanarPosition = dronePlanarPosition

        let groundY = supportSurfaceHeight(
            at: dronePlanarPosition,
            clearanceRadius: 0.3,
            maximumHeight: .greatestFiniteMagnitude
        ) ?? Float(groundNode.presentation.position.y)

        // Mirrors the drop-zone ring's working translucent-disc recipe (diffuse alpha + constant
        // lighting, default `.alpha` blend) — `.multiply` blend on a near-black diffuse rendered
        // fully opaque black instead of a subtle tint, reading as a spilled-oil puddle rather
        // than wet ground.
        let radius = Float.random(in: 0.32...0.5)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.09, alpha: 0.22)
        material.lightingModel = .constant
        material.isDoubleSided = true

        let disc = SCNCylinder(radius: CGFloat(radius), height: 0.004)
        disc.radialSegmentCount = 14
        disc.materials = [material]

        let decal = SCNNode(geometry: disc)
        decal.simdPosition = SIMD3<Float>(dronePlanarPosition.x, groundY + 0.014, dronePlanarPosition.y)
        decal.eulerAngles.y = CGFloat.random(in: 0...(2 * .pi))
        agriculturalWetGroundNode.addChildNode(decal)

        agriculturalWetGroundDecals.append(decal)
        if agriculturalWetGroundDecals.count > AgriculturalSprayVFXTuning.maxDecalCount {
            agriculturalWetGroundDecals.removeFirst().removeFromParentNode()
        }
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

        // While the aircraft is hanging on a carrier's pylon, the carrier is what the chase
        // camera is looking at.
        //
        // Not a cosmetic preference. Every range in this function is derived from
        // `subjectScale`, and taking that from an eight-metre target drone caps the chase at
        // about fifty metres — so a request to sit seventy-five metres behind a C-130 was
        // silently cut down, and the aeroplane was framed from a rear quarter instead of
        // from directly astern. Substituting the subject fixes the clamps and the aim
        // together: the anchor becomes the carrier's own centre, the axis its own heading,
        // and the shot is from the tail because it is built from the tail.
        let attached = attachedCarrierForCamera
        let dronePos = attached?.position ?? state.position
        let yawAngle = attached?.headingRadians ?? state.orientation.z
        let yawOnly = simd_quatf(angle: yawAngle, axis: SIMD3<Float>(0, 1, 0))
        let bodyForward = attached == nil ? modelForwardLocal() : SIMD3<Float>(0.0, 0.0, 1.0)
        let forward = simd_normalize(simd_act(yawOnly, bodyForward))
        let up = SIMD3<Float>(0.0, 1.0, 0.0)

        let dims = activeProfile.dimensions
        let subjectScale = attached.map { $0.kind.lengthMeters }
            ?? max(activeProfile.collisionRadius * 2.0, max(dims.widthM, dims.lengthM))

        let chaseDistanceRange: ClosedRange<Float>
        let chaseHeightRange: ClosedRange<Float>
        let anchorLift: Float
        if activeProfile.airframeClass == .fixedWing {
            // Lower bound deliberately tiny, not a "comfortable viewing distance" — this is also
            // the floor `DroneSimulationViewModel.fpvAutoEngageDistance` mirrors, so holding zoom
            // in actually carries the camera visually into the airframe before handing off to
            // FPV, instead of stalling at a earlier, still-external distance.
            chaseDistanceRange = max(0.15, subjectScale * 0.16)...max(7.2, subjectScale * 5.6)
            chaseHeightRange = max(0.03, subjectScale * 0.04)...max(2.2, subjectScale * 0.68)
            anchorLift = max(0.20, subjectScale * 0.10)
        } else {
            chaseDistanceRange = max(0.10, subjectScale * 0.14)...max(3.9, subjectScale * 5.0)
            chaseHeightRange = max(0.02, subjectScale * 0.03)...max(1.35, subjectScale * 0.52)
            anchorLift = max(0.10, subjectScale * 0.08)
        }

        // Distance alone closing in while height stays pinned at its normal chase-camera ceiling
        // would slide the camera horizontally closer while it keeps hovering well above the
        // aircraft — never actually reading as "inside" it. Only within the final approach (the
        // bottom `heightCollapseFraction` of the distance range — ordinary zoom well above that
        // is untouched) does the height ceiling itself collapse toward the same tiny floor the
        // distance range now has, so both close in together and the camera genuinely passes into
        // the airframe's own silhouette right before the FPV hand-off.
        func heightCollapseProgress(requested: Float, distanceRange: ClosedRange<Float>) -> Float {
            let heightCollapseFraction: Float = 0.12
            let zoneWidth = (distanceRange.upperBound - distanceRange.lowerBound) * heightCollapseFraction
            guard zoneWidth > 0.0001 else { return 0.0 }
            return (1.0 - (requested - distanceRange.lowerBound) / zoneWidth).clamped(to: 0.0...1.0)
        }

        let chaseDistanceRequested = settings.follow.distance.clamped(to: settings.follow.minDistance...settings.follow.maxDistance)
        let chaseDistance = chaseDistanceRequested.clamped(to: chaseDistanceRange)
        let chaseHeightCollapse = heightCollapseProgress(requested: chaseDistanceRequested, distanceRange: chaseDistanceRange)
        let effectiveChaseHeightCeiling = chaseHeightRange.upperBound +
            (chaseHeightRange.lowerBound - chaseHeightRange.upperBound) * chaseHeightCollapse
        let chaseHeightRequested = settings.follow.height + (activeProfile.airframeClass == .fixedWing ? Float(0.30) : Float(0.14))
        let chaseHeight = chaseHeightRequested.clamped(
            to: chaseHeightRange.lowerBound...max(chaseHeightRange.lowerBound, effectiveChaseHeightCeiling)
        )
        // A carried aircraft is framed on the carrier's own centre.
        //
        // Both lifts below exist for a drone: raising the anchor and aiming above it keeps a
        // small airframe off the bottom edge of the frame. Scaled by a thirty-metre subject
        // they come to seven metres, so the camera ended up looking at a point well over the
        // carrier's back and the aeroplane sat low in the shot. With the carrier as the
        // subject there is nothing to lift it off — it fills the frame on its own.
        let framingLift = attached == nil ? anchorLift : 0.0
        let chaseAnchor = dronePos + up * framingLift
        let chaseVerticalOffset = attached == nil
            ? up * max(0.12, subjectScale * 0.14)
            : SIMD3<Float>(repeating: 0.0)

        followRigNode.simdPosition = chaseAnchor
        followRigNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0.0, 0.0, -1.0), to: forward)

        var followLocalPosition = SIMD3<Float>(
            settings.follow.lateralOffset,
            chaseHeight,
            chaseDistance
        )
        followLocalPosition.y = max(followLocalPosition.y, max(0.02, subjectScale * 0.03))
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
        // Lower bounds mirror `chaseDistanceRange`'s (see the comment there) so holding zoom in
        // while orbiting also carries the camera into the airframe before the FPV hand-off.
        let orbitDistanceRange: ClosedRange<Float> = activeProfile.airframeClass == .fixedWing
            ? max(0.15, subjectScale * 0.16)...max(8.0, subjectScale * 6.4)
            : max(0.10, subjectScale * 0.14)...max(5.0, subjectScale * 6.2)
        let orbitDistanceRequested = settings.orbit.distance
            .clamped(to: settings.orbit.minDistance...settings.orbit.maxDistance)
        let orbitDistance = orbitDistanceRequested.clamped(to: orbitDistanceRange)
        // Same distance/height coupling as the chase camera above, in the final approach only.
        let orbitHeightCollapse = heightCollapseProgress(requested: orbitDistanceRequested, distanceRange: orbitDistanceRange)
        let orbitHeightRange = max(0.02, subjectScale * 0.03)...max(2.4, subjectScale * 0.80)
        let effectiveOrbitHeightCeiling = orbitHeightRange.upperBound +
            (orbitHeightRange.lowerBound - orbitHeightRange.upperBound) * orbitHeightCollapse
        let orbitHeight = (settings.orbit.height + max(0.10, subjectScale * 0.10))
            .clamped(to: orbitHeightRange.lowerBound...max(orbitHeightRange.lowerBound, effectiveOrbitHeightCeiling))
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

        // Damaged-propeller imbalance adds onto the configured baseline
        // shake: higher frequency than the normal sway (blade-rate buzz).
        cameraNoisePhase += deltaTime * (5.6 + damageVibrationLevel * 22.0)
        let shake = (settings.fpv.shake + damageVibrationLevel * 0.22).clamped(to: 0.0...0.42)
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

        cameraTransitionNode.camera?.fieldOfView = fov
        cameraTransitionNode.camera?.zNear = fpvCameraNode.camera?.zNear ?? 0.01
        if cameraTransitionActive {
            cameraTransitionElapsed += deltaTime
            let rawProgress = (cameraTransitionElapsed / cameraTransitionDuration).clamped(to: 0.0...1.0)
            // Smoothstep, not linear — reads like an actual camera move easing in/out rather
            // than a mechanical constant-speed slide.
            let progress = rawProgress * rawProgress * (3.0 - 2.0 * rawProgress)
            let fromNode = cameraTransitionFromNode ?? resolvedPointOfView(for: settings.mode)
            let toNode = resolvedPointOfView(for: settings.mode)
            let fromPosition = fromNode.presentation.simdWorldPosition
            let toPosition = toNode.presentation.simdWorldPosition
            let fromOrientation = simd_quatf(fromNode.presentation.simdWorldTransform)
            let toOrientation = simd_quatf(toNode.presentation.simdWorldTransform)
            cameraTransitionNode.simdPosition = simd_mix(
                fromPosition,
                toPosition,
                SIMD3<Float>(repeating: progress)
            )
            cameraTransitionNode.simdOrientation = simd_normalize(
                simd_slerp(fromOrientation, toOrientation, progress)
            )
            if rawProgress >= 1.0 {
                cameraTransitionActive = false
                cameraTransitionFromNode = nil
            }
        }
    }

    private func restoreAfterFPVIfNeeded() {
        droneNode.isHidden = canisterRoundSealed
        droneNode.opacity = 1.0
        visualRootNode.isHidden = false
        fpvObstructionHidingActive = false
        fpvPresentationActive = false
        applyPayloadFPVPresentation()

        for nodes in componentNodes.values {
            for node in nodes {
                node.isHidden = detachedVehicleVisualNodeIDs.contains(ObjectIdentifier(node))
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
        case .multirotor, .fixedWing, .hybridVTOL:
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

    /// Turbojet tailpipe efflux, driven by the engine's own spool fraction.
    ///
    /// A propeller aircraft shows its power in the disc; a jet shows nothing at all
    /// unless the tailpipe does, and a target drone accelerating past 200 m/s with
    /// a cold, empty exhaust reads as a glider. Driven by shaft speed rather than
    /// by the throttle lever, so it follows the spool up and down the way the
    /// thrust does — an engine still winding up is not yet making a plume.
    /// The standing condensation cloud, and the shock cone it sits on.
    ///
    /// Not a Mach-1 effect, whatever the photographs suggest. What is being seen is water
    /// condensing in the low-pressure region behind the strong expansion over the aircraft's
    /// upper surfaces, so it needs three things at once: enough speed for that expansion to
    /// be strong, enough water in the air to condense, and warm enough air to be holding it.
    /// `CondensationCone` decides that; this only draws what it decides, which is why the
    /// cloud appears on a humid low-level dash and not on the same aircraft at Mach 2 in the
    /// stratosphere.
    ///
    /// The cone geometry is real Mach-cone geometry: its half-angle is `asin(1/M)`, so it
    /// starts as a flat disc at Mach 1 and closes down around the aircraft as it accelerates.
    /// Drawn from the aircraft backwards, since that is the half of the cone that exists.
    private func updateCondensationCone(state: DroneState) {
        let strength = state.condensationConeStrength.clamped(to: 0.0...1.0)
        let existing = droneNode.childNode(withName: "condensationCone", recursively: false)

        // A faint cloud is no cloud. At 0.02 this was drawing a barely-there wash in ordinary
        // weather, where the humidity only just clears the model's own threshold — and a
        // barely-there wash across a large surface is exactly what reads as a white sheet
        // across the screen rather than as vapour around an aeroplane. The effect either
        // happens or it does not.
        guard strength > 0.18 else {
            existing?.removeFromParentNode()
            return
        }

        let node: SCNNode
        if let existing {
            node = existing
        } else {
            node = SCNNode()
            node.name = "condensationCone"
            node.castsShadow = false
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(calibratedWhite: 1.0, alpha: 1.0)
            material.blendMode = .add
            material.isDoubleSided = true
            // The cloud is fog, not a surface. Writing it into the depth buffer would let it
            // hide the aircraft that is inside it.
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = true
            let cone = SCNCone(topRadius: 0.0, bottomRadius: 1.0, height: 1.0)
            cone.materials = [material]
            node.geometry = cone
            droneNode.addChildNode(node)
        }

        // Mach-cone half angle, and a hard ceiling on it.
        //
        // Below Mach 1 there is no cone at all — the disturbance outruns the aircraft — so
        // the shape wants to open out. Letting it open all the way was the bug: a half angle
        // of 82 degrees has a tangent of nearly seven, so the radius came out seven times
        // the length, and a 9 m drone grew a 35 m disc that filled the screen from a camera
        // 22 m behind it. What the photographs actually show is a shroud about as wide as
        // the aircraft is long, so that is the ceiling.
        let mach = max(0.80, state.machNumber)
        let maxHalfAngle: Float = 50.0 * .pi / 180.0
        let halfAngle: Float = mach > 1.0
            ? min(maxHalfAngle, asin((1.0 / mach).clamped(to: 0.05...1.0)))
            : maxHalfAngle

        // Sized off the airframe so it reads correctly for a 3 m target drone and a 21 m
        // X-10 alike.
        let bodyLength = max(1.0, Float(activeProfile.dimensionsUnfoldedMm.y) / 1000.0)
        let coneLength = bodyLength * (0.55 + 0.65 * strength)
        // Belt and braces: even inside the angle ceiling the radius stays within the
        // aircraft's own length, so no combination of numbers can put a sheet across the
        // camera again.
        let radius = min(coneLength * tan(halfAngle), bodyLength * 0.9)

        if let cone = node.geometry as? SCNCone {
            cone.height = CGFloat(coneLength)
            cone.bottomRadius = CGFloat(radius)
            cone.firstMaterial?.transparency = CGFloat(0.06 + 0.30 * strength)
        }
        // SCNCone points up its own +Y with the apex at the top; the cone wanted here has
        // its apex forward on the aircraft and opens aft, so it is laid down along -Z and
        // pushed back by half its length.
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        node.position = SCNVector3(0.0, 0.0, -coneLength * 0.5)
    }

    private func updateJetExhaust(state: DroneState) {
        guard let anchor = droneNode.childNode(withName: "jetExhaustAnchor", recursively: true) else {
            return
        }
        if anchor.particleSystems?.isEmpty ?? true {
            anchor.addParticleSystem(makeJetExhaustPlume())
        }
        let ratedRPM = max(1.0, activeProfile.resolvedUAVProfile?.powerplant?.ratedShaftRPM ?? 30_000.0)
        let spool: Float
        if let engine = state.engineRuntime, engine.runState.isFiring {
            spool = (engine.shaftRPM / ratedRPM).clamped(to: 0.0...1.2)
        } else {
            spool = 0.0
        }
        // Idle barely shows; the plume grows with the square of the spool fraction
        // above it, the same shape the thrust follows.
        let above = max(0.0, spool - 0.35) / 0.65
        let intensity = (above * above).clamped(to: 0.0...1.0)
        anchor.particleSystems?.forEach { system in
            system.birthRate = CGFloat(140.0 * intensity)
            system.particleVelocity = CGFloat(14.0 + 26.0 * intensity)
        }
    }

    private func rotatePropellers(state: DroneState, deltaTime: Float) {
        let profileFactor = (activeProfile.maxHorizontalSpeedMps / 20.0).clamped(to: 0.55...1.2)
        let rotorOmega = state.rotorAngularSpeed
        let base = [rotorOmega.x, rotorOmega.y, rotorOmega.z, rotorOmega.w]
        // Real per-unit RPM when the airframe actually models propulsion
        // units (hybridVTOL with a populated template) — all units share one
        // rate in this simplified model, so a single representative value
        // drives every visual prop. Falls back to the legacy decorative
        // formula otherwise (unchanged behavior for multirotor/fixedWing and
        // any hybridVTOL airframe that doesn't seed propulsionUnits yet).
        let propulsionUnitOmega = state.propulsionUnits.first(where: { $0.role == .tiltRotor })?.rotationalSpeedRadPerSec

        for index in propellerNodes.indices {
            let omega = propulsionUnitOmega ?? (index < base.count ? base[index] : rotorOmega.x)
            let fallback = 18.0 + 160.0 * state.throttle * profileFactor
            let spinSpeed = max(0.0, omega) > 0.1 ? omega : fallback
            spinAngles[index] += spinDirections[index] * spinSpeed * deltaTime
            propellerNodes[index].eulerAngles.y = CGFloat(spinAngles[index])
        }
    }

    /// Tilts each nacelle pivot to match the propulsion units' real servo
    /// angle — the visual consumer of `PropulsionUnit.tiltAngleRad` that
    /// makes the transition physically visible, not just a number in the
    /// telemetry panel. All tiltRotor units share one target/rate in this
    /// simplified model, so one representative angle drives every pivot,
    /// even where the physics template has more units (Wingcopter: 8) than
    /// the visual rig has pods (4).
    private func updatePropulsionUnitVisuals(state: DroneState) {
        guard !tiltPivotNodes.isEmpty else { return }
        guard let representative = state.propulsionUnits.first(where: { $0.role == .tiltRotor }) else { return }
        let angle = CGFloat(representative.tiltAngleRad)
        for pivot in tiltPivotNodes {
            pivot.eulerAngles.x = angle
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

    // MARK: - Carrier aircraft

    /// Installs, updates or removes the carrier.
    ///
    /// Called every tick with the current state, so there is one path rather than separate
    /// create/update/destroy calls that could disagree about whether a carrier exists.
    /// The carrier the aircraft is currently hanging from, if any.
    ///
    /// Kept here so the camera can make it the subject of the chase shot without the view
    /// model having to reach into the camera rig. Cleared the moment the shackle opens: from
    /// then on the aircraft is what the operator is watching.
    private var attachedCarrierForCamera: CarrierAircraftState?

    func syncCarrier(_ carrier: CarrierAircraftState?, deltaTime: Float) {
        attachedCarrierForCamera = (carrier?.hasReleased ?? true) ? nil : carrier
        guard let carrier, carrier.isVisible else {
            carrierNode?.removeFromParentNode()
            carrierNode = nil
            carrierPropellers = []
            carrierPylon = nil
            carrierPropellerAngle = 0.0
            return
        }

        if carrierNode == nil || installedCarrierKind != carrier.kind {
            carrierNode?.removeFromParentNode()
            guard let prepared = CarrierAircraftLoader.prepare(kind: carrier.kind) else {
                carrierNode = nil
                return
            }
            scene.rootNode.addChildNode(prepared.rootNode)
            carrierNode = prepared.rootNode
            carrierPropellers = prepared.propellerNodes
            carrierPylon = prepared.bayNode
            installedCarrierKind = carrier.kind
        }
        guard let node = carrierNode else { return }

        node.position = SCNVector3(carrier.position.x, carrier.position.y, carrier.position.z)
        node.eulerAngles = SCNVector3(0.0, carrier.headingRadians, 0.0)

        // Propellers turn at a fixed rate rather than at anything derived from airspeed:
        // a constant-speed propeller holds its rpm, which is the whole point of one, and a
        // C-130's turns at a little over a thousand a minute whatever the aircraft is doing.
        if !carrierPropellers.isEmpty {
            carrierPropellerAngle += deltaTime * 18.0
            if carrierPropellerAngle > .pi * 2.0 {
                carrierPropellerAngle -= .pi * 2.0
            }
            for propeller in carrierPropellers {
                propeller.eulerAngles.z = SCNFloat(carrierPropellerAngle)
            }
        }

        // The shackle swings down and out of the way as the round is released.
        if let shackle = carrierPylon?.childNode(withName: "carrier_shackle", recursively: false) {
            shackle.eulerAngles.x = SCNFloat(-carrier.bayOpenFraction * 1.15)
        }
    }

    // MARK: - Ground detail patch
    //
    // Why the ground turns to soap on a large map, and why capping the tiling does not fix
    // it.
    //
    // The world is one plane the size of the whole map, and its texture is tiled by
    // setting a repeat count proportional to that size. At the ordinary map sizes that is
    // a few thousand repeats and looks right. An extended range is a thousand kilometres
    // across, which asks for a hundred and eighty thousand — and a texture coordinate of
    // 180,000 in a 32-bit float has a spacing of about 0.016, which is nearly two per cent
    // of a tile. The sampler is being handed coordinates that quantise inside a single
    // blade of grass, and the result is exactly the smearing in the screenshots.
    //
    // Capping the repeat count trades one blur for another: the coordinates become precise
    // and each tile becomes eighty metres across, which is a grass texture magnified until
    // it is a green cloud. Both roads lead to soap.
    //
    // So the far ground keeps a capped, coarse tiling — it is kilometres away and nobody
    // can resolve it — and a second, much smaller plane carries the real texture at its
    // designed eight-metre tile and follows the aircraft. Twelve kilometres across is
    // beyond the distance grass detail can be resolved at all, and at that size the repeat
    // count is 1,500, where float coordinates are exact to a thousandth of a tile.
    //
    // The patch is snapped to whole tiles as it moves. Without that the texture would slide
    // under the aircraft — the classic swimming-ground artefact, which is more distracting
    // than the blur it replaces.
    private func updateGroundDetailPatch(around position: SIMD3<Float>) {
        guard let patch = groundDetailNode, !patch.isHidden else { return }
        let tile = Self.groundDetailTileMeters
        let snappedX = (position.x / tile).rounded() * tile
        let snappedZ = (position.z / tile).rounded() * tile
        patch.position = SCNVector3(
            snappedX,
            Float(groundNode.position.y) + Self.groundDetailLift,
            snappedZ
        )
    }

    /// Side of the detail patch, m.
    ///
    /// 40 km, not the 12 km first tried. The patch has to cover everything the operator can
    /// actually resolve, because whatever lies beyond it is drawn by the far ground — and
    /// on an extended range that plane's tiles are a hundred and seventy metres across. A
    /// twelve-kilometre patch left most of the visible world to it, which is why the
    /// screenshots still showed a dandelion the size of the aircraft.
    ///
    /// 40 km still divides exactly by the eight-metre tile, giving 5,000 repeats, where a
    /// float texture coordinate is precise to a five-thousandth of a tile.
    private static let groundDetailExtentMeters: Float = 40_000.0
    /// The grass asset's designed tile size. Snapping to it is what stops the texture
    /// swimming as the patch follows the aircraft.
    private static let groundDetailTileMeters: Float = 8.0
    /// How far above the main ground plane the patch sits: nothing at all.
    ///
    /// It was 3 cm, which flickered, and then 40 cm, which stopped the flicker and buried
    /// every aircraft. Both were attempts to win a depth fight with geometry, and both were
    /// the wrong tool — the ground the aircraft rests on is defined by the physics at
    /// `groundNode`'s own height, so *any* lift puts the grass above the wheels.
    ///
    /// The fight is settled in the depth test instead. The patch renders after the far
    /// ground and does not read depth, so it always wins against the plane underneath it,
    /// and it still writes depth, so the aircraft and everything else standing on the ground
    /// sort against it correctly. Two coplanar planes, no z-fighting, and nothing buried.
    private static let groundDetailLift: Float = 0.0

    /// Builds or removes the detail patch for this terrain.
    ///
    /// Only ever present on an extended range. Every ordinary map size tiles its ground
    /// plane at a repeat count where float coordinates are exact, so adding a second plane
    /// there would be cost with no benefit — and a behaviour change to worlds that already
    /// look right.
    private func refreshGroundDetailPatch(for terrain: TerrainConfiguration) {
        // The far ground goes down first, before the patch and before everything else.
        // Harmless in every world — a ground plane is what you want drawn first anyway — and
        // it is what lets the coplanar patch win by order instead of by a geometric lift.
        groundNode.renderingOrder = -2
        guard terrain.mapScale.isExtendedRange,
              terrain.preset != .gridDemo,
              terrain.preset != .city else {
            groundDetailNode?.removeFromParentNode()
            groundDetailNode = nil
            return
        }

        let extent = Self.groundDetailExtentMeters
        let node: SCNNode
        if let existing = groundDetailNode {
            node = existing
        } else {
            node = SCNNode()
            node.name = "groundDetailPatch"
            node.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
            // Under the aircraft and under everything placed on the ground, but over the
            // far ground plane — which is the coplanar surface it has to beat. Drawn after
            // it and with the depth comparison switched off on the material below, so the
            // winner is decided by order rather than by a fraction of a millimetre of
            // floating-point depth that changes from frame to frame.
            node.renderingOrder = -1
            scene.rootNode.addChildNode(node)
            groundDetailNode = node
        }

        let plane = (node.geometry as? SCNPlane) ?? SCNPlane(width: 1, height: 1)
        plane.width = CGFloat(extent)
        plane.height = CGFloat(extent)
        node.geometry = plane

        // The same loader the far ground uses, asked for a plane that is forty kilometres
        // across rather than a thousand — which is the whole fix, since the repeat count is
        // computed from exactly this number.
        let material: SCNMaterial = currentWeather.preset == .snow
            ? SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: extent)
            : GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: extent)
        // Always drawn over the far ground, never by being nudged above it.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = true
        plane.materials = [material]
        node.isHidden = false
    }

    /// Untextured ground for beyond the detail patch, tinted to the texture's own average
    /// so the join is a change of detail rather than a change of colour.
    private static func flatFarGroundMaterial(isSnow: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        // Beaten by the detail patch on purpose: the patch renders after this and ignores
        // depth, so wherever the two overlap the textured one is what is seen. This still
        // writes depth, so anything standing on the ground beyond the patch sorts normally.
        material.writesToDepthBuffer = true
        material.diffuse.contents = isSnow
            ? NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.93, alpha: 1.0)
            : NSColor(calibratedRed: 0.40, green: 0.50, blue: 0.26, alpha: 1.0)
        material.roughness.contents = NSNumber(value: 0.95)
        material.metalness.contents = NSNumber(value: 0.0)
        return material
    }

    private func refreshGroundMaterial(for terrain: TerrainConfiguration) {
        guard let geometry = groundNode.geometry, terrain.preset != .gridDemo else { return }
        // Matches the ground plane's own size (`configureWorldSurfaceGeometry`, keyed off
        // `beltOuterRadius`) so the tiled texture keeps a consistent scale all the way to the
        // belt's outer edge instead of stretching past the old, smaller scenic extent.
        let mapSizeMeters = terrain.beltOuterRadius * 2.0
        let material: SCNMaterial
        if terrain.preset == .city {
            material = AbandonedCityMaterialLoader.makeBrittleStoneMaterial(
                mapSizeMeters: mapSizeMeters
            )
        } else if terrain.mapScale.isExtendedRange {
            // No texture at all out here.
            //
            // A thousand-kilometre plane cannot carry an eight-metre tile — the repeat count
            // needed for that is where float texture coordinates fall apart — and capping the
            // repeat instead stretches each tile to a hundred and seventy metres, which is
            // what put a dandelion the size of the aircraft on the ground. Neither is worth
            // having, and neither is *needed*: everything within sight is drawn by the detail
            // patch, and what lies past it is far enough away that a flat tone under the haze
            // is indistinguishable from anything more elaborate.
            material = Self.flatFarGroundMaterial(isSnow: currentWeather.preset == .snow)
        } else {
            material = (currentWeather.preset == .snow)
                ? SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: mapSizeMeters)
                : GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: mapSizeMeters)
        }
        geometry.materials = [material]
        refreshGroundDetailPatch(for: terrain)
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
        // An imported world overrides procedural styling wherever the request comes from.
        //
        // This guard lived at one call site — the terrain regeneration — and leaked immediately,
        // because two other paths call this too. `attachWorld` forces the preset to `.gridDemo` so
        // the procedural populator stays cheap, and this function reads that preset as "show the
        // grid and axes": reopening a project therefore drew a reference grid underneath a real
        // city. Suppression belongs to the function, not to whoever happens to call it.
        guard meshCollision == nil else {
            gridNode.isHidden = true
            axesNode.isHidden = true
            groundNode.isHidden = true
            return
        }

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

        let resolvedBackground = nightOverriddenBackground(backgroundImage)
        scene.background.contents = resolvedBackground
        if thermalRenderingActive { thermalSavedBackground = resolvedBackground }
        // Night uses the same dark override as the background for IBL too — a bright daytime
        // gradient merely turned down in intensity still floods diffuse surfaces with a
        // sky-bright dome of fill light, which reads as "lit", not dark.
        scene.lightingEnvironment.contents = resolvedBackground

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
                // The second of two places that dress the ground, and the one that runs
                // last on a terrain change — so an extended range has to be handled here
                // too, or the flat far-field material set by `refreshGroundMaterial` is
                // immediately overwritten with a texture stretched to 170-metre tiles. That
                // is exactly what left a dandelion the size of the aircraft on the ground
                // after the first attempt at this fix.
                if terrain.mapScale.isExtendedRange {
                    groundMaterial = Self.flatFarGroundMaterial(isSnow: currentWeather.preset == .snow)
                } else if currentWeather.preset == .snow {
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
        refreshGroundDetailPatch(for: terrain)

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

        // Layer mission time-of-day on top of the per-terrain daylight baseline so night reads
        // dark (and stays dark across any lighting re-application) without separate dusk gradients.
        // Reverted from literal 0 back to the (small, non-zero) multiplier values: a separate
        // test isolating variables is needed before trying absolute zero again — see the
        // dedicated [[project_missions_increment1_bugfixes]] memory note on the FPV-mode crash.
        //
        // These come from the continuous clock now, not from the three-way enum. The enum's
        // multipliers were a step function — 1.0, then 0.45, then 0.01 — so dusk arrived as a
        // single jump. The clock's versions are smoothsteps across the sun's own elevation, which
        // is why sunrise and sunset now take real time to happen.
        let sunFactor = CGFloat(worldClock.sunIntensityMultiplier)
        let envFactor = CGFloat(worldClock.ambientIntensityMultiplier)
        sunLightNode.light?.intensity = sunIntensity * sunFactor
        sunLightNode.light?.color = sunColorForWorldClock(base: sunColor)
        scene.lightingEnvironment.intensity = environmentIntensity * envFactor
        // SceneFactory's always-on ambient + omni fill lights are independent of terrain/weather
        // and were never part of this day/night model — at fixed intensity they alone (300+340)
        // dwarf the dimmed sun, which is why earlier night passes that only touched the sun/IBL
        // stayed bright. Dim them in lockstep with the IBL ambient factor.
        ambientLightNode.light?.intensity = SceneFactory.ambientLightBaseIntensity * envFactor
        fillLightNode.light?.intensity = SceneFactory.fillLightBaseIntensity * envFactor

    }

    /// Sun colour for the current world time: the terrain's own daylight tint high in the sky,
    /// reddening as the sun approaches the horizon, and the cold night tint once it is down.
    ///
    /// Golden hour is not a special case here — it is what `sunWarmth` produces on its own as the
    /// elevation falls, which is why it arrives and leaves gradually.
    private func sunColorForWorldClock(base: NSColor) -> NSColor {
        let night = nightTintedSunColor(base, timeOfDay: .night)
        // Below the horizon, fade the (already dim) sun to the night tint.
        if worldClock.sunElevationDegrees <= 0.0 {
            return night
        }
        let warmth = CGFloat(worldClock.sunWarmth)
        guard warmth > 0.001 else { return base }
        let horizon = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.34, alpha: 1.0)
        return blend(base, horizon, amount: warmth)
    }

    private func blend(_ a: NSColor, _ b: NSColor, amount: CGFloat) -> NSColor {
        let t = max(0.0, min(1.0, amount))
        let lhs = a.usingColorSpace(.deviceRGB) ?? a
        let rhs = b.usingColorSpace(.deviceRGB) ?? b
        return NSColor(
            calibratedRed: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * t,
            green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * t,
            blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * t,
            alpha: 1.0
        )
    }



    private func nightTintedSunColor(_ base: NSColor, timeOfDay: TimeOfDay) -> NSColor {
        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
        switch timeOfDay {
        case .day:
            return base
        case .dusk:
            // Warm, low sun.
            return NSColor(calibratedRed: min(1.0, rgb.redComponent * 1.05),
                           green: rgb.greenComponent * 0.82,
                           blue: rgb.blueComponent * 0.62,
                           alpha: 1.0)
        case .night:
            // Cool moonlight.
            return NSColor(calibratedRed: rgb.redComponent * 0.55,
                           green: rgb.greenComponent * 0.62,
                           blue: min(1.0, rgb.blueComponent * 0.95),
                           alpha: 1.0)
        }
    }

    /// Single source of truth for "what should the visible (non-thermal) sky actually look like
    /// right now" — both `applyTerrainVisualStyle` and `applyWeatherVisual` recompute the EO sky
    /// background independently (terrain vs. weather change at different times), so the night
    /// override has to live here and be called from both, or whichever ran most recently silently
    /// wins and undoes the other's night sky / thermal-restore snapshot.
    private func nightOverriddenBackground(_ base: Any) -> Any {
        // ⚠️ This was `missionTimeOfDay == .night ? nightColour : base` — a binary switch, so the
        // whole sky went from the full daylight gradient to a flat dark blue in one frame the
        // moment the sun crossed -6 deg. That is the "it was light, then someone turned the
        // lights off" the operator reported, and it was the sky doing it, not the lamps: the
        // ground was already fading continuously while the sky was still waiting to snap.
        let blend = CGFloat(worldClock.nightBlend)
        let night = NSColor(calibratedRed: 0.03, green: 0.045, blue: 0.085, alpha: 1.0)
        guard blend > 0.002 else { return base }
        guard blend < 0.998, let image = base as? NSImage else { return night }
        return image.tinted(with: night, alpha: blend)
    }

    /// Applies the world clock: continuous sun angle and light levels, plus the coarse
    /// `TimeOfDay` the thermal pipeline and the night handling already speak.
    ///
    /// The sun is *moved*, not just dimmed. Dimming alone gives a night that looks like an
    /// underexposed noon — shadows still point where they did at midday — so the light node is
    /// aimed from the clock's own elevation and azimuth and the whole scene's shadows travel with
    /// it across the day.
    func applyWorldClock(_ clock: WorldClock) {
        worldClock = clock
        let previousTimeOfDay = missionTimeOfDay
        missionTimeOfDay = clock.legacyTimeOfDay
        aimSunLight(for: clock)

        // Cheap path, every update: lamp intensities, colour and angle. This is what makes the
        // day read as continuous.
        applyLightingProfile(for: lastTerrainConfig?.preset ?? .field)

        // Expensive path: the sky is a generated 1024x768 gradient and rebuilding it drags the
        // whole terrain visual style along. It only needs to run while the sky is actually
        // changing colour — during twilight — so it is keyed on the night blend rather than on
        // the sun angle. Outside dawn and dusk the blend is pinned at 0 or 1 and this never fires,
        // which matters at 64x where a whole day passes in twenty seconds.
        if abs(clock.nightBlend - lastAppliedNightBlend) >= 0.05 {
            lastAppliedNightBlend = clock.nightBlend
            if let terrain = lastTerrainConfig {
                applyTerrainVisualStyle(terrain)
            }
        }

        if previousTimeOfDay != missionTimeOfDay {
            refreshThermalContextForTimeOfDay()
        }
    }

    /// Points the directional light from the sun's current position.
    private func aimSunLight(for clock: WorldClock) {
        let elevation = Float(clock.sunElevationDegrees).degreesToRadians
        let azimuth = Float(clock.sunAzimuthDegrees).degreesToRadians
        // Euler order here is (pitch, yaw, roll) on the node: pitch it down from the horizontal by
        // the elevation and swing it round by the azimuth. Negative pitch aims the light's -Z at
        // the ground, which is the direction SceneKit shines a directional light along.
        sunLightNode.eulerAngles = SCNVector3(
            CGFloat(-(Float.pi / 2.0 - elevation)),
            CGFloat(azimuth),
            0.0
        )
    }

    /// Applies a mission time-of-day setting: re-runs lighting/sky for the current terrain and
    /// refreshes the thermal context so `isNight`/`timeOfDayHours` flow into the thermal pipeline.
    func applyMissionTimeOfDay(_ timeOfDay: TimeOfDay) {
        missionTimeOfDay = timeOfDay
        if let terrain = lastTerrainConfig {
            applyTerrainVisualStyle(terrain)
        } else {
            applyLightingProfile(for: lastTerrainConfig?.preset ?? .field)
        }
        refreshThermalContextForTimeOfDay()
    }

    private func refreshThermalContextForTimeOfDay() {
        thermalContext = makeThermalContext()
    }

    // MARK: - Mission scenario entities

    /// Spawns the search-and-rescue scenario: a ground ring marking the search sector and the
    /// target person at the resolved position. Returns the person's chest-height world position
    /// for detection sampling.
    @discardableResult
    func spawnMissionSearchScenario(placement: MissionScenarioPlacement) -> SIMD3<Float> {
        clearMissionScenario()
        let groundY: Float = 0.0

        let ring = makeSearchSectorRing(radius: placement.sectorRadius)
        ring.position = SCNVector3(placement.sectorCenter.x, groundY + 0.05, placement.sectorCenter.y)
        missionScenarioRootNode.addChildNode(ring)

        var rng = SystemRandomNumberGenerator()
        let yaw = Float.random(in: 0...(2.0 * .pi), using: &rng)
        let person = ManAssetLoader.shared.makePersonNode(targetHeightMeters: 1.8, yaw: yaw)
        person.position = SCNVector3(placement.targetPosition.x, groundY, placement.targetPosition.y)
        person.name = "mission.target.person"
        missionScenarioRootNode.addChildNode(person)
        missionTargetNode = person
        thermalRenderer?.setMissionTarget(person)

        return SIMD3<Float>(placement.targetPosition.x, groundY + 1.0, placement.targetPosition.y)
    }

    /// Spawns the agricultural spraying field: soil, crop, boundary, refill station and the
    /// coverage decal. Returns the refill station's world position.
    @discardableResult
    func spawnAgriSprayScenario(
        placement: AgriFieldPlacement,
        difficulty: MissionDifficulty
    ) -> SIMD3<Float> {
        clearMissionScenario()
        installedAgriField = placement
        // The populator keeps its own copy of the scenery and regrows every tree from it on a
        // weather change, so the field has to be a rule it knows about — not something removed
        // behind its back.
        scenePopulationService.sceneryExclusion = { [placement] position in
            let planar = SIMD2<Float>(position.x, position.z)
            let local = placement.worldToFieldLocal(planar)
            let half = placement.fieldHalfExtent + 3.0
            if abs(local.x) <= half, abs(local.y) <= half {
                return true
            }
            return simd_distance(planar, placement.stationPosition)
                <= AgriSprayTuning.refillRadiusMeters + 4.0
        }
        scenePopulationService.pruneStoredScenery()
        scenePopulationService.refreshTreeVisuals(snowWeatherActive: currentWeather.preset == .snow)
        clearEnvironmentInsideAgriField(placement)
        return agriFieldLayer.build(
            placement: placement,
            difficulty: difficulty,
            into: missionScenarioRootNode
        )
    }

    /// Repaints the treated-rows decal from the runtime's dose grid. Returns true while the soil
    /// is still visually catching up with the dose.
    @discardableResult
    func updateAgriCoverage(doseFractions: [Float], deltaTime: TimeInterval) -> Bool {
        agriFieldLayer.updateCoverage(doseFractions: doseFractions, deltaTime: deltaTime)
    }

    /// Whether a world position stands on the crop field, or close enough to it to matter.
    ///
    /// The margin covers both the headland the aircraft turns over and the refill station's own
    /// apron: a tree inside either is in the way of the mission rather than scenery.
    private func isInsideAgriField(_ position: SIMD3<Float>, _ placement: AgriFieldPlacement) -> Bool {
        let planar = SIMD2<Float>(position.x, position.z)
        let local = placement.worldToFieldLocal(planar)
        let half = placement.fieldHalfExtent + 3.0
        if abs(local.x) <= half, abs(local.y) <= half {
            return true
        }
        return simd_distance(planar, placement.stationPosition)
            <= AgriSprayTuning.refillRadiusMeters + 4.0
    }

    /// Takes scenery off a field that was spawned into an already-generated world.
    private func clearEnvironmentInsideAgriField(_ placement: AgriFieldPlacement) {
        let doomed = installedEnvironmentDescriptors.filter { isInsideAgriField($0.position, placement) }
        guard !doomed.isEmpty else { return }
        let doomedIDs = Set(doomed.map(\.id))

        var doomedNodes: Set<ObjectIdentifier> = []
        for id in doomedIDs {
            guard let node = installedEnvironmentNodes[id] else { continue }
            doomedNodes.insert(ObjectIdentifier(node))
            node.removeFromParentNode()
        }
        // Obstacles are per collision part and several share one node; dropping a tree's trunk
        // while leaving its canopy behind would leave an invisible obstacle standing in the crop.
        let doomedObstacleIDs = Set(
            obstacleMap
                .filter { doomedNodes.contains(ObjectIdentifier($0.value)) }
                .map(\.key)
        )

        installedEnvironmentNodes = installedEnvironmentNodes.filter { !doomedIDs.contains($0.key) }
        installedEnvironmentDescriptors.removeAll { doomedIDs.contains($0.id) }
        environmentMapDescriptors.removeAll { doomedIDs.contains($0.id) }
        supportSurfaces = environmentMapDescriptors.flatMap(supportSurfaceDescriptors(for:))

        if !doomedObstacleIDs.isEmpty {
            environmentObstacles.removeAll { doomedObstacleIDs.contains($0.id) }
            obstacleMap = obstacleMap.filter { !doomedObstacleIDs.contains($0.key) }
            obstacleSourceByID = obstacleSourceByID.filter { !doomedObstacleIDs.contains($0.key) }
            environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
            environmentRevision &+= 1
        }
        print("[Agri] scenery cleared off the field: \(doomed.count) objects, \(doomedObstacleIDs.count) obstacles")
    }

    // MARK: - Drone racing

    /// Spawns a race track's equipment. Unlike the other scenarios this does not clear the
    /// mission root first: the track builder rebuilds tracks live, and a full teardown would take
    /// the rest of the scenario with it.
    func spawnRaceTrack(_ track: RaceTrack, showsGateNumbers: Bool) {
        raceTrackLayer.build(
            track: track,
            into: missionScenarioRootNode,
            showsGateNumbers: showsGateNumbers
        )
        installedRaceTrack = track
        registerRaceTrackObstacles(track)
    }

    /// Makes the equipment solid: a gate's frame can be hit, its opening cannot.
    ///
    /// Registered as ordinary environment obstacles (the same list trees and crates live in), so
    /// collision, damage and the map overlay all treat a gate post like any other thing in the
    /// world. Rebuilt wholesale whenever the track changes, which is also what the in-scene
    /// builder does on every edit.
    private func registerRaceTrackObstacles(_ track: RaceTrack) {
        clearRaceTrackObstacles()

        var newObstacles: [CollisionObstacle] = []
        for element in track.elements {
            guard let descriptor = element.descriptor else { continue }
            let boxes = element.collisionBoxes(
                from: RacingEquipmentAssetLoader.shared.collisionBoxes(for: descriptor)
            )
            guard !boxes.isEmpty else { continue }
            let scale = max(0.05, element.scale)
            let size = descriptor.sizeMeters * scale
            let descriptorModel = EnvironmentObjectDescriptor(
                id: UUID(),
                kind: descriptor.role == .decor ? .pole : .marker,
                biome: .field,
                position: element.position,
                yawRadians: element.yawRadians,
                size: size,
                boundingRadius: max(size.x, size.z) * 0.56,
                isCollidable: true,
                collisionParts: boxes.map { box in
                    EnvironmentCollisionPart(
                        localCenter: box.localCenter,
                        size: box.size,
                        source: "race_" + descriptor.id,
                        supportsLanding: false
                    )
                }
            )
            let node = raceTrackLayer.node(for: element.id)
            let obstacles = configureObstacleCollisionProxies(
                for: node ?? missionScenarioRootNode,
                descriptor: descriptorModel
            )
            for obstacle in obstacles {
                if let node {
                    obstacleMap[obstacle.id] = node
                }
                obstacleSourceByID[obstacle.id] = obstacle.source
                raceObstacleIDs.insert(obstacle.id)
            }
            newObstacles.append(contentsOf: obstacles)
        }

        guard !newObstacles.isEmpty else { return }
        environmentObstacles.append(contentsOf: newObstacles)
        environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
        environmentRevision &+= 1
        print("[Race] track obstacles registered: \(newObstacles.count) boxes over \(track.elements.count) elements")
    }

    private func clearRaceTrackObstacles() {
        guard !raceObstacleIDs.isEmpty else { return }
        environmentObstacles.removeAll { raceObstacleIDs.contains($0.id) }
        obstacleMap = obstacleMap.filter { !raceObstacleIDs.contains($0.key) }
        obstacleSourceByID = obstacleSourceByID.filter { !raceObstacleIDs.contains($0.key) }
        environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
        raceObstacleIDs.removeAll(keepingCapacity: false)
        // Same reason the fire scenario announces its own removals: everything that caches on the
        // obstacle revision would otherwise keep colliding with gates that are no longer there.
        environmentRevision &+= 1
    }

    func applyRaceGateStates(_ states: [UUID: RaceGateVisualState]) {
        raceTrackLayer.applyGateStates(states)
    }

    func updateRaceGhost(_ element: RaceTrackElement) {
        raceTrackLayer.attach(to: missionScenarioRootNode)
        raceTrackLayer.updateGhost(element: element)
    }

    func clearRaceGhost() {
        raceTrackLayer.clearGhost()
    }

    func nearestRaceElement(to point: SIMD3<Float>, within radius: Float) -> UUID? {
        raceTrackLayer.nearestElement(to: point, within: radius)
    }

    // MARK: - Free camera (track builder)

    /// Flies the free camera under its own power: the builder needs to get around the world the
    /// way a spectator does, not orbit a paused aircraft.
    func moveFreeCamera(forward: Float, strafe: Float, vertical: Float, deltaTime: Float, speed: Float) {
        guard deltaTime > 0.0 else { return }
        let orientation = freeCameraNode.simdOrientation
        let forwardVector = simd_normalize(simd_act(orientation, SIMD3<Float>(0.0, 0.0, -1.0)))
        let rightVector = simd_normalize(simd_act(orientation, SIMD3<Float>(1.0, 0.0, 0.0)))
        // Vertical stays world-up rather than camera-up: pitching the view down should not turn
        // "go up" into "go backwards".
        var motion = forwardVector * forward + rightVector * strafe
        motion.y += vertical
        let length = simd_length(motion)
        guard length > 0.001 else { return }
        freeCameraNode.simdPosition += (motion / length) * max(0.0, speed) * deltaTime
        // Never let the builder camera sink through the ground; the track is built from above it.
        freeCameraNode.simdPosition.y = max(0.6, freeCameraNode.simdPosition.y)
    }

    var freeCameraWorldPosition: SIMD3<Float> {
        freeCameraNode.simdPosition
    }

    /// Where the free camera is pointing, on the ground. Falls back to a fixed distance ahead
    /// when the camera is level or looking up, so the builder always has somewhere to put things.
    func freeCameraGroundAimPoint(fallbackDistance: Float = 30.0) -> SIMD3<Float> {
        let origin = freeCameraNode.simdPosition
        let forward = simd_normalize(simd_act(freeCameraNode.simdOrientation, SIMD3<Float>(0.0, 0.0, -1.0)))
        if forward.y < -0.05 {
            let distance = min(400.0, origin.y / -forward.y)
            let hit = origin + forward * distance
            return SIMD3<Float>(hit.x, 0.0, hit.z)
        }
        let ahead = origin + forward * fallbackDistance
        return SIMD3<Float>(ahead.x, 0.0, ahead.z)
    }

    /// Puts the builder camera somewhere useful when it is switched on: behind and above the
    /// aircraft, looking at it.
    func placeFreeCameraForBuilder(near position: SIMD3<Float>, yaw: Float) {
        let back = SIMD3<Float>(-sin(yaw), 0, -cos(yaw)) * 12.0
        freeCameraNode.simdPosition = SIMD3<Float>(
            position.x + back.x,
            max(6.0, position.y + 6.0),
            position.z + back.z
        )
        freeLookAngles = SIMD2<Float>(yaw, -0.35)
        freeCameraNode.eulerAngles = SCNVector3(CGFloat(-0.35), CGFloat(yaw), 0)
    }

    func clearMissionScenario() {
        agriFieldLayer.detach()
        if installedAgriField != nil {
            scenePopulationService.sceneryExclusion = nil
        }
        installedAgriField = nil
        installedRaceTrack = nil
        clearRaceTrackObstacles()
        raceTrackLayer.detach()
        missionScenarioRootNode.childNodes.forEach { $0.removeFromParentNode() }
        missionTargetNode = nil
        thermalRenderer?.setMissionTarget(nil)

        fireTreeNodes.removeAll(keepingCapacity: false)
        fireTreeFlameNodes.removeAll(keepingCapacity: false)
        fireTreeSmokeNodes.removeAll(keepingCapacity: false)
        fireTreeHeightsMeters.removeAll(keepingCapacity: false)
        fireTreeFoamAccumulationNodes.removeAll(keepingCapacity: false)
        lastFireTreeStatuses.removeAll(keepingCapacity: false)
        missionFireTruckNode = nil
        resetFireHoseSimulation(hideVisual: true)
        if !fireTreeObstacleIDs.isEmpty {
            environmentObstacles.removeAll { fireTreeObstacleIDs.contains($0.id) }
            obstacleMap = obstacleMap.filter { !fireTreeObstacleIDs.contains($0.key) }
            obstacleSourceByID = obstacleSourceByID.filter { !fireTreeObstacleIDs.contains($0.key) }
            environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
            fireTreeObstacleIDs.removeAll(keepingCapacity: false)
            // The one mutation of the obstacle list that did not announce itself. Every consumer
            // that caches on this revision — the map overlay, the fixed-wing signature, and now the
            // navigation obstacle set — would have gone on describing burnt trees that are no
            // longer there.
            environmentRevision &+= 1
        }
    }

    /// Spawns the fire-response scenario: a pool of trees in a zone, each with real flame/smoke
    /// VFX (see `FireVisualAssetLoader`) attached and hidden until the tree actually burns. Trees
    /// are dedicated nodes outside `ScenePopulationService`'s ambient forest, but are registered
    /// as real collision obstacles (appended to, not replacing, the ambient forest's obstacle
    /// list) so they behave like any other tree for flight collision.
    ///
    /// Each tree's materials are copied (`makeMaterialsIndependent`) rather than left shared with
    /// `PineTreeAssetLoader`'s cached template — `SCNNode.clone()` shares geometry/materials by
    /// reference, so without this, permanently charring one burnt-out tree would silently darken
    /// every other tree (including the ambient forest) using the same template.
    ///
    /// Returns each tree's mid-canopy world position, used both for suppression aiming and as the
    /// scene-layer anchor for per-tree VFX.
    @discardableResult
    func spawnFireResponseScenario(placement: FireZonePlacement) -> [SIMD3<Float>] {
        removeFreeFlightFireTruck()
        clearMissionScenario()
        let groundY: Float = 0.0

        var rng = SystemRandomNumberGenerator()
        var newObstacles: [CollisionObstacle] = []
        var treeNodes: [SCNNode] = []
        var flameNodes: [SCNNode] = []
        var smokeNodes: [SCNNode] = []
        var foamAccumulationNodes: [SCNNode] = []
        var heightsMeters: [Float] = []
        var anchorPositions: [SIMD3<Float>] = []

        for position in placement.treePositions {
            let heightMeters = Float.random(in: 14.0...22.0, using: &rng)
            let yaw = Float.random(in: 0...(2.0 * .pi), using: &rng)
            let tree = PineTreeAssetLoader.shared.makeTreeNode(targetHeightMeters: heightMeters, yaw: yaw) ?? SCNNode()
            tree.position = SCNVector3(position.x, groundY, position.y)
            tree.name = "mission.fire_tree"
            makeMaterialsIndependent(tree)
            missionScenarioRootNode.addChildNode(tree)
            treeNodes.append(tree)
            heightsMeters.append(heightMeters)

            // Parented to `missionScenarioRootNode`, NOT `tree` — `tree`'s own node carries
            // `PineTreeAssetLoader`'s model-to-world scale factor (the raw Pine_Tree.usdz is ~300
            // native units tall, scaled down to match `heightMeters`). `heightMeters` below is
            // already a real-world meter quantity; parenting a same-unit offset under a node that
            // re-applies that scale factor on top would silently shrink/mislocate it (this was a
            // real bug: it put the flame near the trunk base, occluded, instead of at canopy
            // height — the smoke's own upward particle drift over its lifetime hid the same bug
            // from view since particles rise well past their scaled-down birth point regardless).
            let flame = FireVisualAssetLoader.shared.makeFlameNode(
                heightMeters: heightMeters * 0.55,
                baseYawDegrees: yaw * 180.0 / .pi
            )
            flame.position = SCNVector3(tree.position.x, tree.position.y + CGFloat(heightMeters * 0.58), tree.position.z)
            flame.isHidden = true
            missionScenarioRootNode.addChildNode(flame)
            flameNodes.append(flame)

            let smoke = FireVisualAssetLoader.shared.makeSmokeNode()
            smoke.position = SCNVector3(tree.position.x, tree.position.y + CGFloat(heightMeters * 0.78), tree.position.z)
            smoke.isHidden = true
            missionScenarioRootNode.addChildNode(smoke)
            smokeNodes.append(smoke)

            // Same anchor as the flame — the foam visually grows over the fire itself as
            // suppression progress advances, in place of a HUD progress bar.
            let foamAccumulation = FireVisualAssetLoader.shared.makeFoamAccumulationNode()
            foamAccumulation.position = SCNVector3(tree.position.x, tree.position.y + CGFloat(heightMeters * 0.58), tree.position.z)
            missionScenarioRootNode.addChildNode(foamAccumulation)
            foamAccumulationNodes.append(foamAccumulation)

            let size = SIMD3<Float>(heightMeters * 0.30, heightMeters, heightMeters * 0.30)
            let descriptor = EnvironmentObjectDescriptor(
                id: UUID(),
                kind: .tree,
                biome: .forest,
                position: SIMD3<Float>(position.x, groundY, position.y),
                yawRadians: yaw,
                size: size,
                boundingRadius: max(size.x, size.z) * 0.56,
                isCollidable: true,
                collisionParts: ScenePopulationService.treeCollisionParts(size: size)
            )
            let descriptorObstacles = configureObstacleCollisionProxies(for: tree, descriptor: descriptor)
            for obstacle in descriptorObstacles {
                obstacleMap[obstacle.id] = tree
                obstacleSourceByID[obstacle.id] = obstacle.source
                fireTreeObstacleIDs.insert(obstacle.id)
            }
            newObstacles.append(contentsOf: descriptorObstacles)

            anchorPositions.append(SIMD3<Float>(position.x, groundY + heightMeters * 0.5, position.y))
        }

        fireTreeNodes = treeNodes
        fireTreeFlameNodes = flameNodes
        fireTreeSmokeNodes = smokeNodes
        fireTreeHeightsMeters = heightsMeters
        fireTreeFoamAccumulationNodes = foamAccumulationNodes
        lastFireTreeStatuses = Array(repeating: .unburned, count: treeNodes.count)

        let truckObstacle = spawnFireTruckDecoration(placement: placement, groundY: groundY)
        if let truckObstacle {
            newObstacles.append(truckObstacle)
        }

        environmentObstacles.append(contentsOf: newObstacles)
        environmentObstacleIndex = CollisionObstacleSpatialIndex(obstacles: environmentObstacles)
        environmentRevision &+= 1

        return anchorPositions
    }

    /// Parks a `Fire_Truck.usdz` just outside the fire zone, facing the blaze — the fixed anchor
    /// point the hose's physical tether length is measured from at runtime (see
    /// `DroneSimulationViewModel.enforceHoseTetherConstraint`). `placement.truckStandoffMeters`
    /// (not a fixed constant) keeps this in sync with the reachability guarantee
    /// `FireZonePlacement.generate` sized the zone against. Registered as a single-box collision
    /// obstacle so the drone doesn't clip through it, same as any other obstacle.
    @discardableResult
    private func spawnFireTruckDecoration(placement: FireZonePlacement, groundY: Float) -> CollisionObstacle? {
        let dock = currentDockSpawnPoint()
        let dockPlanar = SIMD2<Float>(dock.x, dock.z)
        let toDock = dockPlanar - placement.zoneCenter
        let direction = simd_length(toDock) > 0.001 ? simd_normalize(toDock) : SIMD2<Float>(1.0, 0.0)
        let truckPosition2D = placement.zoneCenter + direction * (placement.zoneRadius + placement.truckStandoffMeters)

        let toZoneCenter = placement.zoneCenter - truckPosition2D
        let yaw = simd_length(toZoneCenter) > 0.001 ? atan2(toZoneCenter.x, toZoneCenter.y) : 0.0

        let truck = FireTruckAssetLoader.shared.makeTruckNode(targetHeightMeters: 3.0, yaw: yaw)
        truck.position = SCNVector3(truckPosition2D.x, groundY, truckPosition2D.y)
        missionScenarioRootNode.addChildNode(truck)
        missionFireTruckNode = truck
        resetFireHoseSimulation(hideVisual: true)

        let size = SIMD3<Float>(7.0, 3.0, 2.5)
        let descriptor = EnvironmentObjectDescriptor(
            id: UUID(),
            kind: .crate,
            biome: .forest,
            position: SIMD3<Float>(truckPosition2D.x, groundY, truckPosition2D.y),
            yawRadians: yaw,
            size: size,
            boundingRadius: max(size.x, size.z) * 0.56,
            isCollidable: true,
            collisionParts: [
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, size.y * 0.5, 0.0),
                    size: size,
                    source: "fire_truck",
                    supportsLanding: false
                )
            ]
        )
        let descriptorObstacles = configureObstacleCollisionProxies(for: truck, descriptor: descriptor)
        for obstacle in descriptorObstacles {
            obstacleMap[obstacle.id] = truck
            obstacleSourceByID[obstacle.id] = obstacle.source
            fireTreeObstacleIDs.insert(obstacle.id)
        }
        return descriptorObstacles.first
    }

    /// Replaces every material on `node` (recursively) with its own copy. `SCNNode.clone()` only
    /// deep-copies the node graph — geometry and materials are shared by reference with whatever
    /// template they came from. Fire trees need independent materials before they can be safely,
    /// permanently darkened one at a time without affecting `PineTreeAssetLoader`'s cached
    /// template (and every other tree cloned from it, including the ambient forest).
    private func makeMaterialsIndependent(_ node: SCNNode) {
        if let geometry = node.geometry, !geometry.materials.isEmpty {
            // `SCNNode.clone()` shares the SCNGeometry object itself, not just its materials — so
            // reassigning `.materials` on the existing (shared) geometry would still mutate every
            // other node that references it. The geometry itself must be copied first so this
            // node gets its own independent object to reassign materials on.
            let geometryCopy = (geometry.copy() as? SCNGeometry) ?? geometry
            geometryCopy.materials = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            node.geometry = geometryCopy
        }
        for child in node.childNodes {
            makeMaterialsIndependent(child)
        }
    }

    /// Updates each fire tree's flame/smoke VFX to reflect its current burn state, and — on the
    /// instant a tree is first suppressed (`.burning` → `.charred`) — permanently darkens its
    /// (already-independent, see `makeMaterialsIndependent`) materials and triggers a one-shot
    /// foam-impact burst. Called once per tick from the simulation view model alongside the
    /// fire-response runtime tick. `viewerWorldPosition` (the drone's own position — a fine proxy
    /// for the payload-optics camera mounted on it) drives the smoke's overdraw LOD below (the
    /// flame itself is always fully visible while burning — no distance-based plane hiding, since
    /// that used to visibly pop planes in/out as the viewer's distance crossed a threshold).
    func updateFireResponseVisuals(treeStatuses: [FireTreeStatus], viewerWorldPosition: SIMD3<Float>) {
        for (index, status) in treeStatuses.enumerated() where index < fireTreeNodes.count {
            let previousStatus = index < lastFireTreeStatuses.count ? lastFireTreeStatuses[index] : .unburned
            let flame = index < fireTreeFlameNodes.count ? fireTreeFlameNodes[index] : nil
            let smoke = index < fireTreeSmokeNodes.count ? fireTreeSmokeNodes[index] : nil

            // The flame's flipbook `SCNAction` and the smoke's particle system both keep costing a
            // constant per-frame tax across the WHOLE tree pool (up to 13 trees at hard difficulty)
            // for the entire mission if simply left running/attached behind `isHidden` — hidden only
            // skips drawing, not action evaluation or particle simulation. Start/stop them only on
            // the actual burning-state transition (not every tick) so the cost only exists for trees
            // that are actually alight right now.
            let isBurningNow: Bool
            if case .burning = status { isBurningNow = true } else { isBurningNow = false }
            let wasBurningBefore: Bool
            if case .burning = previousStatus { wasBurningBefore = true } else { wasBurningBefore = false }
            if isBurningNow != wasBurningBefore {
                if let flame {
                    FireVisualAssetLoader.shared.setFlameAnimating(flame, isAnimating: isBurningNow)
                }
                if let smoke {
                    FireVisualAssetLoader.shared.setSmokeActive(smoke, isActive: isBurningNow)
                }
            }

            switch status {
            case .unburned:
                flame?.isHidden = true
                smoke?.isHidden = true
            case .burning(_, let suppressionProgress):
                flame?.isHidden = false
                smoke?.isHidden = false
                if let smoke {
                    applySmokeOverdrawLOD(smoke, viewerWorldPosition: viewerWorldPosition)
                }
                if index < fireTreeFoamAccumulationNodes.count {
                    let fraction = Float(min(1.0, suppressionProgress / FireHoseTuning.default.suppressionDwellSeconds))
                    updateFoamAccumulation(fireTreeFoamAccumulationNodes[index], fraction: fraction)
                }
            case .charred:
                flame?.isHidden = true
                smoke?.isHidden = true
                if index < fireTreeFoamAccumulationNodes.count {
                    updateFoamAccumulation(fireTreeFoamAccumulationNodes[index], fraction: 1.0)
                }
                if previousStatus != .charred {
                    let treeNode = fireTreeNodes[index]
                    darkenMaterialsRecursively(treeNode)
                    // Parented to `missionScenarioRootNode`, NOT `treeNode` — same scale-parenting
                    // pitfall as the flame/smoke fix above: `treeNode.boundingBox` is in the raw
                    // Pine_Tree.usdz's native/unscaled local units (~300 tall), which only
                    // converts to real meters when read INSIDE that same scaled node. A hardcoded
                    // `SCNSphere(radius: 0.6)` burst parented there would render at ~0.6 * scale
                    // (scale ≈ heightMeters/300, so ~3.6cm for an 18m tree) instead of the intended
                    // 0.6m. `fireTreeHeightsMeters[index]` gives the real height directly, so the
                    // burst's world position is computed the same way flame/smoke already are.
                    let heightMeters = index < fireTreeHeightsMeters.count ? fireTreeHeightsMeters[index] : 18.0
                    let burst = FireVisualAssetLoader.shared.makeFoamBurstNode()
                    burst.position = SCNVector3(
                        treeNode.position.x,
                        treeNode.position.y + CGFloat(heightMeters * 0.5),
                        treeNode.position.z
                    )
                    missionScenarioRootNode.addChildNode(burst)
                }
            }
        }
        lastFireTreeStatuses = treeStatuses
    }

    /// Scales the persistent foam-accumulation node to match suppression progress (0...1) — a
    /// small but already-visible blob as soon as suppression starts, growing to a size that
    /// visually starts to envelop the flame by the time a tree is fully suppressed. Reading
    /// straight from the runtime's own per-tick progress value (which already decays on its own
    /// when the trigger isn't held on this tree, see `FireResponseRuntime.applySuppression`) means
    /// the foam visibly shrinks back down too if the operator gives up on a tree partway through —
    /// the same single source of truth driving both the mechanic and what's on screen, not a
    /// separate tracked state that could drift out of sync.
    private func updateFoamAccumulation(_ node: SCNNode, fraction: Float) {
        let clamped = max(0.0, min(1.0, fraction))
        node.isHidden = clamped <= 0.001
        let scale = CGFloat(0.2 + clamped * 1.6)
        node.scale = SCNVector3(scale, scale, scale)
    }

    /// Cuts smoke's overdraw cost as the viewer closes in — up close, each particle's quad covers
    /// far more screen area (and there are up to ~24 alive at once per tree at the base birth
    /// rate), so emitting fewer of them is the lever. The equivalent trick for the flame
    /// cross-billboard (hiding planes at close range) was tried and reverted: it made distance
    /// crossings visibly pop planes in/out — reported as "мерцающими" (flickering) trees, and the
    /// user wants a burning tree to always read as fully, continuously on fire. The ambient-forest
    /// density/map-scale fixes (see project memory) turned out to be the dominant performance
    /// lever anyway, so losing this specific LOD is an acceptable trade.
    private func applySmokeOverdrawLOD(_ smoke: SCNNode, viewerWorldPosition: SIMD3<Float>) {
        guard let particleSystem = smoke.particleSystems?.first else { return }
        let distance = simd_distance(viewerWorldPosition, smoke.simdWorldPosition)
        if distance < 10.0 {
            particleSystem.birthRate = 1
        } else if distance < 20.0 {
            particleSystem.birthRate = 2
        } else {
            particleSystem.birthRate = 4
        }
    }

    /// Permanently darkens a suppressed tree's (already independent) materials toward soot-grey —
    /// no new asset, just a recursive material mutation on a node the ambient-forest rebuild
    /// never touches (fire trees live entirely outside `ScenePopulationService`).
    private func darkenMaterialsRecursively(_ node: SCNNode) {
        node.geometry?.materials.forEach { material in
            material.diffuse.contents = NSColor(calibratedWhite: 0.09, alpha: 1.0)
            material.emission.contents = NSColor.clear
            material.roughness.contents = 0.95
            material.metalness.contents = 0.0
        }
        for child in node.childNodes {
            darkenMaterialsRecursively(child)
        }
    }

    private func makeSearchSectorRing(radius: Float) -> SCNNode {
        let torus = SCNTorus(
            ringRadius: CGFloat(radius),
            pipeRadius: CGFloat(max(0.6, radius * 0.012))
        )
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal.withAlphaComponent(0.55)
        material.emission.contents = NSColor.systemTeal.withAlphaComponent(0.30)
        material.lightingModel = .constant
        material.isDoubleSided = true
        // Ground overlay marker, same treatment as the payload-impact mark: skip the depth
        // buffer entirely so this large ring never occludes or gets occluded by real geometry's
        // depth, which is also what the sun's shadow pass reads — leaving it out keeps shadows
        // from trees/the drone falling normally across the sector instead of getting clipped by
        // (or rendering artifacts from) the ring's own geometry.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        torus.firstMaterial = material
        let node = SCNNode(geometry: torus)
        node.name = "mission.search_sector"
        node.castsShadow = false
        return node
    }

    /// Samples target geometry relative to the payload camera for the mission runtime.
    /// Returns `nil` when there is no active payload camera or scenario target.
    ///
    /// `maxRangeMeters`/`coneHalfAngleDegrees` gate the expensive line-of-sight raycast: this
    /// runs every simulation tick, so the full-scene `hitTestWithSegment` below must only fire
    /// once the target is already plausibly in view, not on every tick regardless of where the
    /// camera happens to be pointed.
    func payloadCameraMissionSample(
        targetWorldPosition: SIMD3<Float>,
        maxRangeMeters: Float,
        coneHalfAngleDegrees: Float
    ) -> MissionTargetDetectionSample? {
        guard let cameraNode = payloadCameraNode, missionTargetNode != nil else {
            return nil
        }
        // Model transform, not `.presentation` — see `payloadCameraTargetDistance` for why
        // (avoids a ~16ms render-thread scene-lock stall; this runs every tick a SAR target is in
        // the camera's range/cone gate).
        let camPos = cameraNode.simdWorldPosition
        let worldTransform = cameraNode.simdWorldTransform
        // SceneKit cameras look down their local -Z axis.
        let forwardColumn = SIMD3<Float>(
            worldTransform.columns.2.x,
            worldTransform.columns.2.y,
            worldTransform.columns.2.z
        )
        let forward = simd_normalize(-forwardColumn)

        let toTarget = targetWorldPosition - camPos
        let distance = simd_length(toTarget)
        guard distance > 0.001 else {
            return MissionTargetDetectionSample(
                distanceMeters: 0.0,
                angleFromCameraAxisDegrees: 0.0,
                lineOfSightClear: true
            )
        }
        let direction = toTarget / distance
        let cosAngle = max(-1.0, min(1.0, simd_dot(forward, direction)))
        let angleDegrees = acos(cosAngle) * 180.0 / .pi

        guard distance <= maxRangeMeters, angleDegrees <= coneHalfAngleDegrees else {
            return MissionTargetDetectionSample(
                distanceMeters: distance,
                angleFromCameraAxisDegrees: angleDegrees,
                lineOfSightClear: false
            )
        }

        let losClear = isLineOfSightClearToMissionTarget(from: camPos, to: targetWorldPosition)
        return MissionTargetDetectionSample(
            distanceMeters: distance,
            angleFromCameraAxisDegrees: angleDegrees,
            lineOfSightClear: losClear
        )
    }

    /// Analytic occlusion check against the collision catalog (see `analyticEnvironmentRayHit`).
    /// This fires every tick while the target sits inside the camera's range/cone gate — exactly
    /// the "climbed high enough to see the search sector" moment — so the SceneKit hit test it
    /// replaces (which had no searchMode option at all, i.e. the exhaustive default) was itself a
    /// 30ms-class per-tick cost the instant detection became possible. The mannequin and the
    /// drone aren't in the obstacle catalog, so the old self-hit filtering is unnecessary.
    private func isLineOfSightClearToMissionTarget(from: SIMD3<Float>, to: SIMD3<Float>) -> Bool {
        let targetDistance = simd_distance(from, to)
        guard targetDistance > 0.6 else { return true }
        // Same 0.5m tolerance as before: anything the ray strikes meaningfully closer than the
        // target counts as an occluder; capping maxDistance at that tolerance means any hit at
        // all answers the question.
        return analyticEnvironmentRayHit(
            origin: from,
            direction: (to - from) / targetDistance,
            maxDistance: targetDistance - 0.5
        ) == nil
    }

    private func nodeIsDescendant(_ node: SCNNode, of ancestor: SCNNode?) -> Bool {
        guard let ancestor else { return false }
        var current: SCNNode? = node
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.parent
        }
        return false
    }

    private func configureWorldSurfaceGeometry(for terrain: TerrainConfiguration) {
        // Sized to the belt's outermost ring (not just the scenic/authored extent) so the ground
        // always reaches at least as far as the decorated outer belt — no bare ground under the
        // trees, and no cliff/void beyond it either. Past this radius is flat, undecorated ground;
        // true unbounded/streamed terrain stays separate, deferred work.
        let groundHalfExtent = terrain.beltOuterRadius + 24.0
        if let plane = groundNode.geometry as? SCNPlane {
            plane.width = CGFloat(groundHalfExtent * 2.0)
            plane.height = CGFloat(groundHalfExtent * 2.0)
        }

        let gridHalfExtent = min(terrain.worldHalfExtent, max(108.0, terrain.signalBoundaryRadius + 18.0))
        let preferredSpacing: Float = gridHalfExtent > 180.0 ? 12.0 : 8.0
        // The guide is one SCNNode per line, so its node count grows linearly with the
        // map. At 12 m spacing the largest conventional map already builds about four
        // thousand of them; an extended range at the same spacing would ask for over a
        // hundred thousand and the world would never finish loading. Capping the count
        // rather than the extent keeps every existing map's spacing exactly as it was —
        // at x256 the cap computes to 11.1 m, which loses to the preferred 12 m.
        let maximumLinesPerAxis: Float = 2_200.0
        let gridSpacing = max(preferredSpacing, (gridHalfExtent * 2.0) / maximumLinesPerAxis)
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
        // An imported world has no world-origin apron: (0, 0, 0) in a photogrammetric tile is an
        // arbitrary point, in this city usually open harbour, and always at the vertical datum's
        // zero rather than on the ground. Since `currentDockSpawnPoint()` is what every reset and
        // the home point resolve to, leaving it at the origin teleported the aircraft under the
        // terrain on the first reset — including the one at session start, which is why the
        // aircraft appeared beneath the surface instead of on its deck.
        if let meshSpawn = meshSpawnPoint {
            dockSpawnPosition = meshSpawn
            dockStationNode.simdPosition = meshSpawn + SIMD3<Float>(0.0, -dockDeckSurfaceHeight, 0.0)
            return
        }

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

    private func configureDetachedVehiclePartsGroundCollision() {
        guard detachedVehiclePartsGroundNode.parent == nil else { return }

        let groundShapeGeometry = SCNBox(
            width: 30_000.0,
            height: 0.10,
            length: 30_000.0,
            chamferRadius: 0.0
        )
        let shape = SCNPhysicsShape(
            geometry: groundShapeGeometry,
            options: [SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.boundingBox]
        )
        let body = SCNPhysicsBody(type: .static, shape: shape)
        body.isAffectedByGravity = false
        body.friction = 0.86
        body.rollingFriction = 0.24
        body.restitution = 0.08
        body.categoryBitMask = PhysicsCategory.environment
        body.collisionBitMask = PhysicsCategory.detachedVehiclePart
        body.contactTestBitMask = PhysicsCategory.detachedVehiclePart

        detachedVehiclePartsGroundNode.name = "detachedVehiclePartsGroundCollision"
        detachedVehiclePartsGroundNode.simdPosition = SIMD3<Float>(0.0, -0.053, 0.0)
        detachedVehiclePartsGroundNode.physicsBody = body
        scene.rootNode.addChildNode(detachedVehiclePartsGroundNode)
    }

    /// Select only the highest mapped nodes. Some builders map a parent and
    /// one of its children to the same legacy damage component; cloning both
    /// would duplicate the child geometry in the detached proxy.
    private func detachedVisualSourceNodes(
        for legacyComponents: Set<DamageComponent>
    ) -> [SCNNode] {
        var candidates: [SCNNode] = []
        var seen: Set<ObjectIdentifier> = []
        for component in legacyComponents.sorted(by: { $0.rawValue < $1.rawValue }) {
            for node in componentNodes[component] ?? [] {
                let identifier = ObjectIdentifier(node)
                if seen.insert(identifier).inserted {
                    candidates.append(node)
                }
            }
        }

        // A mesh registered under several legacy buckets is indivisible (a
        // common example is one full-span wing used by armFL + armFR). It
        // cannot be an accurate detached subtree, so let the physical-bounds
        // fallback represent the debris and rebuild retained sections below.
        let ownershipCount: [ObjectIdentifier: Int] = componentNodes.reduce(into: [:]) { result, entry in
            for node in Set(entry.value.map(ObjectIdentifier.init)) {
                result[node, default: 0] += 1
            }
        }
        candidates.removeAll { ownershipCount[ObjectIdentifier($0), default: 0] > 1 }

        let candidateIDs = Set(candidates.map(ObjectIdentifier.init))
        return candidates.filter { candidate in
            var ancestor = candidate.parent
            while let node = ancestor {
                if candidateIDs.contains(ObjectIdentifier(node)) {
                    return false
                }
                ancestor = node.parent
            }
            return true
        }
    }

    private func prepareDetachedVehiclePartClone(_ node: SCNNode) {
        node.physicsBody = nil
        node.camera = nil
        node.light = nil
        node.removeAllActions()
        node.isHidden = false
        node.opacity = 1.0
        node.enumerateChildNodes { child, _ in
            child.physicsBody = nil
            child.camera = nil
            child.light = nil
            child.removeAllActions()
        }
        makeMaterialsIndependent(node)
        applyCategoryBitMask(RenderCategory.standardVisible, to: node)
    }

    private func detachedVehiclePartFallbackMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.name = "detachedVehiclePart.fallback"
        material.diffuse.contents = NSColor(
            calibratedRed: 0.22,
            green: 0.24,
            blue: 0.27,
            alpha: 1.0
        )
        material.emission.contents = NSColor.systemRed.withAlphaComponent(0.055)
        material.metalness.contents = 0.24
        material.roughness.contents = 0.72
        return material
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
        if descriptor.usesScenePhysicsCollision {
            return configureMeshObstacleCollisionProxies(for: descriptor)
        }
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
                    yawRadians: descriptor.yawRadians + part.yawRadians,
                    // The scene knows what it placed, so the obstacle carries its material
                    // rather than leaving the impact solver to infer one from the name.
                    acousticSurface: AcousticSurfaceMaterial.resolve(
                        source: part.source,
                        kind: descriptor.kind
                    )
                )
            }
    }

    private func configureMeshObstacleCollisionProxies(
        for descriptor: EnvironmentObjectDescriptor
    ) -> [CollisionObstacle] {
        descriptor.collisionMeshParts.compactMap { part in
            var triangles: [CollisionMeshTriangle] = []
            triangles.reserveCapacity(part.triangles.count)
            var hasBounds = false
            var minimum = SIMD3<Float>(repeating: 0.0)
            var maximum = SIMD3<Float>(repeating: 0.0)

            for sourceTriangle in part.triangles {
                let point0 = worldPoint(for: sourceTriangle.point0, descriptor: descriptor)
                let point1 = worldPoint(for: sourceTriangle.point1, descriptor: descriptor)
                let point2 = worldPoint(for: sourceTriangle.point2, descriptor: descriptor)
                guard let triangle = CollisionMeshTriangle(
                    point0: point0,
                    point1: point1,
                    point2: point2,
                    supportsLandingSurface: sourceTriangle.supportsLanding
                ) else {
                    continue
                }
                triangles.append(triangle)
                if hasBounds {
                    minimum = simd_min(minimum, triangle.minimum)
                    maximum = simd_max(maximum, triangle.maximum)
                } else {
                    minimum = triangle.minimum
                    maximum = triangle.maximum
                    hasBounds = true
                }
            }

            guard hasBounds, !triangles.isEmpty else {
                return nil
            }
            let center = (minimum + maximum) * 0.5
            let planarHalfExtents = SIMD2<Float>(
                max(0.05, (maximum.x - minimum.x) * 0.5),
                max(0.05, (maximum.z - minimum.z) * 0.5)
            )
            return CollisionObstacle(
                id: part.id,
                center: center,
                radius: simd_length(planarHalfExtents),
                source: part.source,
                baseY: minimum.y,
                topY: maximum.y,
                planarHalfExtents: nil,
                yawRadians: 0.0,
                meshTriangles: triangles,
                acousticSurface: AcousticSurfaceMaterial.resolve(
                    source: part.source,
                    kind: descriptor.kind
                )
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
            topY: descriptor.position.y + proxy.topY,
            acousticSurface: AcousticSurfaceMaterial.resolve(
                source: proxy.source,
                kind: descriptor.kind
            )
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
        if !descriptor.supportSurfaceTriangleParts.isEmpty {
            return descriptor.supportSurfaceTriangleParts.compactMap { part in
                let point0 = worldPoint(for: part.point0, descriptor: descriptor)
                let point1 = worldPoint(for: part.point1, descriptor: descriptor)
                let point2 = worldPoint(for: part.point2, descriptor: descriptor)
                let rawNormal = simd_cross(point1 - point0, point2 - point0)
                guard simd_length_squared(rawNormal) > 0.000001 else {
                    return nil
                }
                var normal = simd_normalize(rawNormal)
                if normal.y < 0.0 {
                    normal = -normal
                }
                guard normal.y > 0.001 else {
                    return nil
                }
                let center3D = (point0 + point1 + point2) / 3.0
                let planarMinimum = simd_min(
                    simd_min(SIMD2<Float>(point0.x, point0.z), SIMD2<Float>(point1.x, point1.z)),
                    SIMD2<Float>(point2.x, point2.z)
                )
                let planarMaximum = simd_max(
                    simd_max(SIMD2<Float>(point0.x, point0.z), SIMD2<Float>(point1.x, point1.z)),
                    SIMD2<Float>(point2.x, point2.z)
                )
                return SupportSurfaceDescriptor(
                    center: SIMD2<Float>(center3D.x, center3D.z),
                    halfExtents: simd_max(
                        (planarMaximum - planarMinimum) * 0.5,
                        SIMD2<Float>(repeating: 0.02)
                    ),
                    yawRadians: 0.0,
                    planePoint: center3D,
                    normal: normal,
                    triangle: (point0, point1, point2),
                    source: part.source
                )
            }
        }

        if !descriptor.supportSurfaceParts.isEmpty {
            return descriptor.supportSurfaceParts.compactMap { part in
                let planarOffset = rotatePlanar(
                    SIMD2<Float>(part.localCenter.x, part.localCenter.z),
                    radians: descriptor.yawRadians
                )
                let normalOffset = rotatePlanar(
                    SIMD2<Float>(part.normal.x, part.normal.z),
                    radians: descriptor.yawRadians + part.yawRadians
                )
                let normal = simd_normalize(SIMD3<Float>(
                    normalOffset.x,
                    part.normal.y,
                    normalOffset.y
                ))
                guard normal.y > 0.001 else {
                    return nil
                }
                return SupportSurfaceDescriptor(
                    center: SIMD2<Float>(
                        descriptor.position.x + planarOffset.x,
                        descriptor.position.z + planarOffset.y
                    ),
                    halfExtents: part.halfExtents,
                    yawRadians: descriptor.yawRadians + part.yawRadians,
                    planePoint: SIMD3<Float>(
                        descriptor.position.x + planarOffset.x,
                        descriptor.position.y + part.localCenter.y,
                        descriptor.position.z + planarOffset.y
                    ),
                    normal: normal,
                    triangle: nil,
                    source: part.source
                )
            }
        }

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
                    planePoint: SIMD3<Float>(
                        descriptor.position.x + offset.x,
                        descriptor.position.y + part.localCenter.y + part.size.y * 0.5,
                        descriptor.position.z + offset.y
                    ),
                    normal: SIMD3<Float>(0.0, 1.0, 0.0),
                    triangle: nil,
                    source: part.source
                )
            }
        }

        if descriptor.usesScenePhysicsCollision {
            return []
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
                planePoint: SIMD3<Float>(
                    descriptor.position.x,
                    descriptor.position.y + height,
                    descriptor.position.z
                ),
                normal: SIMD3<Float>(0.0, 1.0, 0.0),
                triangle: nil,
                source: "abandonedBuilding.bounds"
            )]

        case .crate:
            return [SupportSurfaceDescriptor(
                center: SIMD2<Float>(descriptor.position.x, descriptor.position.z),
                halfExtents: SIMD2<Float>(descriptor.size.x * 0.52, descriptor.size.z * 0.52),
                yawRadians: descriptor.yawRadians,
                planePoint: SIMD3<Float>(
                    descriptor.position.x,
                    descriptor.position.y + descriptor.size.y,
                    descriptor.position.z
                ),
                normal: SIMD3<Float>(0.0, 1.0, 0.0),
                triangle: nil,
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

    private func worldPoint(
        for localPoint: SIMD3<Float>,
        descriptor: EnvironmentObjectDescriptor
    ) -> SIMD3<Float> {
        let planar = rotatePlanar(
            SIMD2<Float>(localPoint.x, localPoint.z),
            radians: descriptor.yawRadians
        )
        return SIMD3<Float>(
            descriptor.position.x + planar.x,
            descriptor.position.y + localPoint.y,
            descriptor.position.z + planar.y
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
        if let triangle = surface.triangle {
            return planarPoint(
                point,
                isInsideTriangle: SIMD2<Float>(triangle.0.x, triangle.0.z),
                SIMD2<Float>(triangle.1.x, triangle.1.z),
                SIMD2<Float>(triangle.2.x, triangle.2.z),
                clearanceRadius: clearanceRadius
            )
        }

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

    // `clearanceRadius` mirrors the box-surface branch above, which grows its footprint by the
    // same margin: without it, a rooftop assembled from mesh triangles only reports support
    // height within ~2mm of a triangle edge, so the drone's collision radius (tens of cm) finds
    // no support the moment its center nears a roof edge or an inter-triangle seam — even though
    // the mesh-collision system (which uses a much looser 0.015-0.045 tolerance) already treats
    // that spot as a valid landing contact. That mismatch is what stranded landed drones at roof
    // edges: the tick falls back to the hard-collision path, which re-teleports position onto the
    // same contact point every frame, reads as "stuck jittering," and can accumulate enough
    // pseudo-impact severity to force-disarm.
    private func planarPoint(
        _ point: SIMD2<Float>,
        isInsideTriangle point0: SIMD2<Float>,
        _ point1: SIMD2<Float>,
        _ point2: SIMD2<Float>,
        clearanceRadius: Float
    ) -> Bool {
        let area = triangleEdge(point0, point1, point2)
        guard abs(area) > 0.000001 else {
            return false
        }
        let w0 = triangleEdge(point1, point2, point) / area
        let w1 = triangleEdge(point2, point0, point) / area
        let w2 = triangleEdge(point0, point1, point) / area
        let tolerance: Float = -0.002
        if w0 >= tolerance && w1 >= tolerance && w2 >= tolerance {
            return true
        }
        guard clearanceRadius > 0.0 else {
            return false
        }
        let clearanceSq = clearanceRadius * clearanceRadius
        return distanceSquared(from: point, toSegment: point0, point1) <= clearanceSq ||
            distanceSquared(from: point, toSegment: point1, point2) <= clearanceSq ||
            distanceSquared(from: point, toSegment: point2, point0) <= clearanceSq
    }

    private func distanceSquared(
        from point: SIMD2<Float>,
        toSegment segmentStart: SIMD2<Float>,
        _ segmentEnd: SIMD2<Float>
    ) -> Float {
        let segment = segmentEnd - segmentStart
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0.000001 else {
            return simd_length_squared(point - segmentStart)
        }
        let t = min(1.0, max(0.0, simd_dot(point - segmentStart, segment) / lengthSquared))
        let closest = segmentStart + segment * t
        return simd_length_squared(point - closest)
    }

    private func triangleEdge(
        _ point0: SIMD2<Float>,
        _ point1: SIMD2<Float>,
        _ point2: SIMD2<Float>
    ) -> Float {
        (point1.x - point0.x) * (point2.y - point0.y) -
            (point1.y - point0.y) * (point2.x - point0.x)
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
                let hiddenByDetachment = detachedVehicleVisualNodeIDs.contains(ObjectIdentifier(node))
                let hidden = hiddenByDamage || hiddenBySelectiveFPV || hiddenByDetachment
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
            // This used to write every SCNLight shadow knob unconditionally on every frame while
            // payload optics stayed active — measured as a real per-frame cost in Debug (each
            // SCNLight property write has Metal-side bookkeeping/validation overhead, and most of
            // these values are constant for the whole time payload optics is active). Now the
            // constant config only gets (re-)written on the transition into this mode.
            if !payloadOpticsShadowQualityActive {
                // Respect the graphics tier — at `.low` shadows stay off even in payload optics.
                light.castsShadow = AppGraphicsSettings.quality.environmentShadowsEnabled
                light.automaticallyAdjustsShadowProjection = false
                light.maximumShadowDistance = CameraClipping.payloadOpticsFar
                light.sampleDistributedShadowMaps = false
                light.shadowCascadeCount = 1
                light.shadowCascadeSplittingFactor = 0.15
                // Was 4096/32 — measured FPS drop in payload view at that resolution/sample count;
                // 2048/16 keeps shadows visibly sharper than the non-payload default (1536/12)
                // without the cost of the full 4096/32 pass. Confirmed NOT the cause of the
                // fire-response payload-optics lag (user tested dropping to 1536/12, no change) —
                // reverted back to this.
                light.shadowMapSize = CGSize(width: 2048, height: 2048)
                light.shadowSampleCount = 16
                light.shadowBias = 0.62
                light.zNear = 1
                light.zFar = CameraClipping.payloadOpticsFar + 500
                payloadOpticsShadowQualityActive = true
            }

            // These genuinely need to track the camera every frame (zoom/aim changes the useful
            // shadow frustum), so they stay outside the one-time block above.
            let projection = payloadOpticsShadowProjection()
            light.orthographicScale = projection.scale
            sunLightNode.simdPosition = projection.lightPosition

            if weather.preset != lastPayloadOpticsShadowWeatherPreset {
                lastPayloadOpticsShadowWeatherPreset = weather.preset
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
            }
            return
        }

        guard payloadOpticsShadowQualityActive else {
            return
        }
        lastPayloadOpticsShadowWeatherPreset = nil

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

    private func ensureCollisionDebugMarkers(around anchor: SIMD3<Float>) {
        guard obstacleDebugProxyNodes.isEmpty else {
            return
        }

        let worldObstacles = worldNavigationObstacles.filter {
            simd_distance(
                SIMD2<Float>($0.center.x, $0.center.z),
                SIMD2<Float>(anchor.x, anchor.z)
            ) <= 140.0
        }

        // An imported world's buildings are obstacles too, and until now the overlay could not
        // show them: it only ever walked `environmentObstacles`, which a photogrammetric or
        // open-data world does not populate. Switching collision debug on beside a façade
        // therefore drew nothing at all, which reads as "these buildings have no collision" —
        // indistinguishable from the real thing. They are drawn from the same registry that
        // feeds contact, so what appears here is exactly what the physics is testing against.
        let worldObstacleIDs = Set(worldObstacles.map(\.id))

        for obstacle in environmentObstacles + worldObstacles {
            // Mesh cells are still skipped — a 24 m bucket of city is not a shape anyone can read
            // — but a registry object's triangles are its real outline, so they are drawn as they
            // are. A box here would show the operator a wall that is not where the wall is: that
            // rectangle overshoots the true footprint by ×1.29 at the 90th percentile.
            let isRegistryObject = worldObstacleIDs.contains(obstacle.id)
            if obstacle.hasMeshCollision, !isRegistryObject {
                continue
            }
            obstacleDebugPlanarRadii[obstacle.id] = obstacle.planarHalfExtents
                .map { simd_length($0) } ?? obstacle.radius
            let marker: SCNNode
            if isRegistryObject,
               let triangles = obstacle.meshTriangles,
               let outline = collisionOutlineGeometry(from: triangles) {
                // Already in world space, so the node carries no transform of its own.
                marker = SCNNode(geometry: outline)
            } else if let halfExtents = obstacle.planarHalfExtents {
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

    /// The exact contact triangles as drawable geometry. Rendered with the overlay's existing
    /// `fillMode = .lines`, which turns the solid prism into the wireframe of its own outline.
    private func collisionOutlineGeometry(
        from triangles: [CollisionMeshTriangle]
    ) -> SCNGeometry? {
        guard !triangles.isEmpty, triangles.count <= 4_000 else { return nil }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            vertices.append(SCNVector3(triangle.point0))
            vertices.append(SCNVector3(triangle.point1))
            vertices.append(SCNVector3(triangle.point2))
        }
        let indices = (0..<Int32(vertices.count)).map { $0 }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }

    private func setAbandonedCityCollisionDebugVisible(_ isVisible: Bool) {
        guard abandonedCityCollisionDebugVisible != isVisible else {
            return
        }
        abandonedCityCollisionDebugVisible = isVisible
        setAbandonedCityCollisionDebugVisible(
            isVisible,
            in: scene.rootNode
        )
    }

    private func setAbandonedCityCollisionDebugVisible(
        _ isVisible: Bool,
        in node: SCNNode
    ) {
        if node.name?.hasPrefix("environment.abandonedCity.collisionDebugMesh.") == true {
            node.isHidden = !isVisible
        }
        for child in node.childNodes {
            setAbandonedCityCollisionDebugVisible(isVisible, in: child)
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


private extension NSImage {
    /// Returns a copy with `colour` composited over it at `alpha`.
    ///
    /// Used to carry the sky gradient continuously into night rather than swapping it for a flat
    /// colour, so dusk is a fade instead of a cut.
    func tinted(with colour: NSColor, alpha: CGFloat) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        colour.withAlphaComponent(max(0.0, min(1.0, alpha))).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceOver)
        result.unlockFocus()
        return result
    }
}
