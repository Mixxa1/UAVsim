import Foundation

struct TelemetrySnapshot {
    var timestampISO8601: String

    var droneModelID: String
    var droneModelName: String
    var droneManufacturer: String
    var isAbstractModel: Bool
    var abstractParametersSummary: String

    var terrainPreset: String
    var terrainDensity: Double
    var cameraMode: String

    var x: Double
    var y: Double
    var z: Double

    var velocityX: Double
    var velocityY: Double
    var velocityZ: Double

    var roll: Double
    var pitch: Double
    var yaw: Double

    var speed: Double
    var throttle: Double

    var modeTitle: String
    var modeKey: String
    var controlModeKey: String
    var armStateKey: String
    var flightState: String
    var flightStateKey: String

    var batteryPercent: Double
    var batteryHealthPercent: Double
    var powerDrawW: Double
    var estimatedRemainingMin: Double

    var weatherPreset: String
    var weatherPresetKey: String
    var weatherIntensity: Double

    var collisionRisk: Double
    var nearestObstacleDistance: Double
    var nearestObstacleSource: String
    var autoNavigationActive: Bool
    var targetDistanceMeters: Double
    var targetBearingDegrees: Double
    var pathStatus: String
    var currentWaypointIndex: Int
    var remainingWaypoints: Int
    var pathLengthMeters: Double
    var pathRemainingDistanceMeters: Double
    var fixedWingMissionState: String
    var fixedWingActiveWaypointIndex: Int
    var fixedWingCrossTrackErrorMeters: Double
    var fixedWingLegCourseDegrees: Double
    var fixedWingLegStartX: Double
    var fixedWingLegStartZ: Double
    var fixedWingLegEndX: Double
    var fixedWingLegEndZ: Double
    var fixedWingWaypointVectorX: Double
    var fixedWingWaypointVectorZ: Double
    var fixedWingHeadingDegrees: Double
    var fixedWingGroundTrackDegrees: Double
    var fixedWingTargetAirspeed: Double
    var fixedWingTargetAltitude: Double
    var fixedWingCommandedRollDegrees: Double
    var fixedWingCommandedPitchDegrees: Double
    var fixedWingCommandedThrottle: Double
    var fixedWingSpeedRecoveryActive: Bool
    var fixedWingAlongTrackProgress: Double
    var fixedWingBatteryWarningLevel: String
    var fixedWingProfileLimitsActive: Bool
    var fixedWingTransitionReason: String
    var missionAbortReason: String
    var modeTransitionReason: String
    var controlAuthority: String
    var manualInputActive: Bool
    var markerGuidanceActive: Bool
    var payloadViewActive: Bool
    var mapOverlayActive: Bool
    var missionMapActive: Bool
    var dropZoneSet: Bool
    var deliveryMissionReady: Bool
    var inDropZone: Bool
    var payloadReleasedForMission: Bool
    var disarmedState: Bool
    var blockedState: Bool
    var lostSignalState: Bool
    var emergencyAction: String
    var emergencyActionKey: String

    var damageSummary: String
    var thermalSummary: String

    var fleetMode: String
    var fleetModeKey: String
    var wingmanCount: Int
    var interDroneRisk: Double
    var nearestInterDroneDistance: Double

    var frameTimeMs: Double
    var physicsTimeMs: Double
    var renderTimeMs: Double
    var pathfindingTimeMs: Double
    var activeObjectCount: Int
    var activePhysicsBodyCount: Int
    var activeParticleCount: Int

    static let zero = TelemetrySnapshot(
        timestampISO8601: ISO8601DateFormatter().string(from: Date()),
        droneModelID: "n/a",
        droneModelName: "n/a",
        droneManufacturer: "n/a",
        isAbstractModel: false,
        abstractParametersSummary: "n/a",
        terrainPreset: TerrainPreset.gridDemo.title,
        terrainDensity: 0.0,
        cameraMode: CameraMode.follow.title,
        x: 0.0,
        y: 0.0,
        z: 0.0,
        velocityX: 0.0,
        velocityY: 0.0,
        velocityZ: 0.0,
        roll: 0.0,
        pitch: 0.0,
        yaw: 0.0,
        speed: 0.0,
        throttle: 0.0,
        modeTitle: DroneFlightMode.manual.title,
        modeKey: DroneFlightMode.manual.titleKey,
        controlModeKey: FlightControlMode.stabilized.titleKey,
        armStateKey: "arm_state.disarmed",
        flightState: NSLocalizedString("flight_state.on_ground", comment: ""),
        flightStateKey: "flight_state.on_ground",
        batteryPercent: 100.0,
        batteryHealthPercent: 100.0,
        powerDrawW: 0.0,
        estimatedRemainingMin: 0.0,
        weatherPreset: WeatherPreset.normal.title,
        weatherPresetKey: WeatherPreset.normal.titleKey,
        weatherIntensity: 0.0,
        collisionRisk: 0.0,
        nearestObstacleDistance: .infinity,
        nearestObstacleSource: "n/a",
        autoNavigationActive: false,
        targetDistanceMeters: .nan,
        targetBearingDegrees: .nan,
        pathStatus: "idle",
        currentWaypointIndex: 0,
        remainingWaypoints: 0,
        pathLengthMeters: 0.0,
        pathRemainingDistanceMeters: 0.0,
        fixedWingMissionState: FixedWingAutopilotDebugState.MissionState.idle.rawValue,
        fixedWingActiveWaypointIndex: 0,
        fixedWingCrossTrackErrorMeters: 0.0,
        fixedWingLegCourseDegrees: .nan,
        fixedWingLegStartX: .nan,
        fixedWingLegStartZ: .nan,
        fixedWingLegEndX: .nan,
        fixedWingLegEndZ: .nan,
        fixedWingWaypointVectorX: .nan,
        fixedWingWaypointVectorZ: .nan,
        fixedWingHeadingDegrees: .nan,
        fixedWingGroundTrackDegrees: .nan,
        fixedWingTargetAirspeed: .nan,
        fixedWingTargetAltitude: .nan,
        fixedWingCommandedRollDegrees: .nan,
        fixedWingCommandedPitchDegrees: .nan,
        fixedWingCommandedThrottle: .nan,
        fixedWingSpeedRecoveryActive: false,
        fixedWingAlongTrackProgress: .nan,
        fixedWingBatteryWarningLevel: "nominal",
        fixedWingProfileLimitsActive: false,
        fixedWingTransitionReason: "n/a",
        missionAbortReason: "n/a",
        modeTransitionReason: "initialization",
        controlAuthority: FlightControlAuthority.none.title,
        manualInputActive: false,
        markerGuidanceActive: false,
        payloadViewActive: false,
        mapOverlayActive: false,
        missionMapActive: false,
        dropZoneSet: false,
        deliveryMissionReady: false,
        inDropZone: false,
        payloadReleasedForMission: false,
        disarmedState: true,
        blockedState: false,
        lostSignalState: false,
        emergencyAction: CollisionEmergencyAction.none.title,
        emergencyActionKey: CollisionEmergencyAction.none.titleKey,
        damageSummary: NSLocalizedString("summary.damage.none", comment: ""),
        thermalSummary: "BAT:33C FC:33C",
        fleetMode: FormationMode.off.title,
        fleetModeKey: FormationMode.off.titleKey,
        wingmanCount: 0,
        interDroneRisk: 0.0,
        nearestInterDroneDistance: .infinity,
        frameTimeMs: 0.0,
        physicsTimeMs: 0.0,
        renderTimeMs: 0.0,
        pathfindingTimeMs: 0.0,
        activeObjectCount: 0,
        activePhysicsBodyCount: 0,
        activeParticleCount: 0
    )
}
