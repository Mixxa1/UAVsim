import Foundation

struct InternalStorePaths {
    static func root(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("DroneUAVDemo", isDirectory: true)
            .appendingPathComponent("InternalStore", isDirectory: true)
    }

    static func projects(fileManager: FileManager) -> URL {
        root(fileManager: fileManager).appendingPathComponent("Projects", isDirectory: true)
    }

    static func autosaves(fileManager: FileManager) -> URL {
        root(fileManager: fileManager).appendingPathComponent("Autosaves", isDirectory: true)
    }

    static func telemetry(fileManager: FileManager) -> URL {
        root(fileManager: fileManager).appendingPathComponent("Telemetry", isDirectory: true)
    }

    /// Imported real-world map packages (`.uavworld`). Kept out of the app bundle because these
    /// are user-generated, can reach gigabytes once imagery and terrain are included, and must
    /// survive an app update.
    static func worlds(fileManager: FileManager) -> URL {
        root(fileManager: fileManager).appendingPathComponent("Worlds", isDirectory: true)
    }

    /// User-facing LiDAR survey exports. Kept directly under `DroneUAVDemo` (not inside the opaque
    /// `InternalStore`) because the pilot opens these files themselves.
    static func lidarSurveys(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("DroneUAVDemo", isDirectory: true)
            .appendingPathComponent("LidarSurveys", isDirectory: true)
    }

    static func index(fileManager: FileManager) -> URL {
        root(fileManager: fileManager).appendingPathComponent("Index", isDirectory: true)
    }

    static func replays(fileManager: FileManager) -> URL {
        root(fileManager: fileManager).appendingPathComponent("Replays", isDirectory: true)
    }
}

struct ProjectRecordSummary: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var lastOpenedAt: Date
    var lastSavedAt: Date
}

struct ProjectSnapshot: Codable {
    struct Vec3: Codable {
        var x: Float
        var y: Float
        var z: Float
    }

    struct ControlValues: Codable {
        var x: Double
        var y: Double
        var z: Double
        var roll: Double
        var pitch: Double
        var yaw: Double
        var throttle: Double
    }

    struct AbstractParameters: Codable {
        var massKg: Float
        var unfoldedMmX: Float
        var unfoldedMmY: Float
        var unfoldedMmZ: Float
        var batteryEnergyWh: Float
        var maxHorizontalSpeedMps: Float
        var maxAscentSpeedMps: Float
        var maxDescentSpeedMps: Float
        var maxWindResistanceMps: Float
        var controlResponsiveness: Float
        var collisionRadiusMeters: Float
    }

    struct Weather: Codable {
        var presetRaw: String
        var intensity: Float
        var windDirectionDeg: Float
        var windSpeedMps: Float
        var gusts: Float
    }

    struct Terrain: Codable {
        var presetRaw: String
        var mapScaleRaw: String?
        var density: Float
        var seed: UInt64
        var safeSpawnRadius: Float
        var showsBoundaryBarrier: Bool?
    }

    /// The imported photogrammetric world this project flies in, if any.
    ///
    /// Recorded as a source identifier plus a tile key rather than a path, because the tile store
    /// owns where the data lives — an absolute URL saved here would break the moment the store moved
    /// or the project was opened on another machine, and would break silently, as a project that
    /// quietly reverts to procedural ground.
    struct MeshWorld: Codable {
        var sourceIdentifier: String
        var tileKey: String
    }

    /// A world built from open geodata, referenced by its package identifier.
    ///
    /// Kept as its own field rather than folded into `MeshWorld` with a discriminator, because the
    /// two references genuinely differ — a photogrammetric tile is a source plus a tile key inside
    /// it, an open-data world is one self-contained package — and because projects already saved
    /// with a `meshWorld` must keep decoding untouched.
    struct OpenDataWorld: Codable {
        var packageIdentifier: String
    }

    struct Camera: Codable {
        var modeRaw: String
        var fov: Float
        var sensitivity: Float
        var smoothing: Float
        var invertLookX: Bool
        var invertLookY: Bool
        var sensitivityProfileRaw: String
        var lookNudgeStepDeg: Float

        var freeMoveSpeed: Float
        var freeZoomSensitivity: Float
        var freeDistance: Float
        var freeMinDistance: Float
        var freeMaxDistance: Float

        var followDistance: Float
        var followHeight: Float
        var followLateralOffset: Float
        var followMinDistance: Float
        var followMaxDistance: Float

        var orbitDistance: Float
        var orbitHeight: Float
        var orbitAngularSpeed: Float
        var orbitMinDistance: Float
        var orbitMaxDistance: Float

        var fpvStabilization: Float
        var fpvShake: Float
        var fpvYawLimitDeg: Float
        var fpvPitchLimitDeg: Float
        var fpvNearClip: Float
        var fpvMountOffsetX: Float
        var fpvMountOffsetY: Float
        var fpvMountOffsetZ: Float
        var fpvHideObstructingParts: Bool

        var topHeight: Float?
        var topMinHeight: Float?
        var topMaxHeight: Float?
        var topForwardLead: Float?
    }

    struct Battery: Codable {
        var chargePercent: Float
        var healthPercent: Float
        var powerDrawW: Float
        var remainingTimeSec: Float
    }

    struct State: Codable {
        var position: Vec3
        var velocity: Vec3
        var orientation: Vec3
        var throttle: Float
        var motorThrottle: Float
        var forwardAirspeed: Float
    }

    struct ComponentDamageRuntime: Codable {
        var componentID: String
        var integrity: Float
        var residualStrength: Float
        var stiffnessScale: Float
        var bendRadians: Vec3
        var translationMeters: Vec3
        var vibrationScale: Float
        var attachmentStateRaw: String
        var forceScale: Float
        var torqueScale: Float
        var efficiencyScale: Float
        var responseSpeedScale: Float
        var rangeScale: Float
        var dragScale: Float
        var performanceVibrationScale: Float
    }

    struct ConnectionDamageRuntime: Codable {
        var childComponentID: String
        var residualStrength: Float
        var stiffnessScale: Float
        var attachmentStateRaw: String
    }

    struct ActiveFailureRuntime: Codable {
        var componentID: String
        var modeRaw: String
        var frozenSurfaceValue: Float?
        var intermittentActive: Bool
        var intermittentTimer: Float
    }

    struct FailureRuntime: Codable {
        var seed: UInt64
        var generatorState: UInt64
        var failures: [ActiveFailureRuntime]
    }

    var schemaVersion: Int
    var projectID: String
    var projectName: String
    var savedAt: Date

    var selectedDroneModelID: String
    /// Exact, self-contained Workbench assembly. Optional keeps projects
    /// written before schema 2 decodable and also lets a project reopen after
    /// its catalog entry has been deleted from the user's library.
    var workbenchBuild: WorkbenchBuild?
    var flightModeRaw: String
    var flightControlModeRaw: String
    var diagnosticModeRaw: String

    var controlValues: ControlValues
    var abstractParameters: AbstractParameters
    var weather: Weather
    var terrain: Terrain
    var camera: Camera
    var battery: Battery
    var state: State

    var damageHealthByComponent: [String: Float]
    var hiddenDamageComponents: [String]
    var selectedDamageComponentRaw: String?
    var thermalByComponent: [String: Float]
    var missionTimeline: MissionTimeline?
    var missionDebrief: MissionDebrief?
    /// Added in schema 3. Optional fields preserve decoding of schema 1/2
    /// projects and fall back to the legacy health projection when absent.
    var componentDamageRuntime: [ComponentDamageRuntime]? = nil
    var connectionDamageRuntime: [ConnectionDamageRuntime]? = nil
    var failureRuntime: FailureRuntime? = nil
    var massPropertiesRevision: UInt64? = nil
    /// Optional so every project saved before imported worlds existed still decodes.
    var meshWorld: MeshWorld? = nil
    var openDataWorld: OpenDataWorld? = nil
}

protocol ProjectStorageManaging {
    func listProjects() -> [ProjectRecordSummary]
    @discardableResult
    func saveProject(id: String, name: String, snapshot: ProjectSnapshot) throws -> ProjectRecordSummary
    func loadProject(id: String) throws -> ProjectSnapshot
    @discardableResult
    func duplicateProject(id: String, newName: String) throws -> ProjectRecordSummary
    func deleteProject(id: String) throws
    func autosave(projectID: String, snapshot: ProjectSnapshot) throws
    func loadAutosave(projectID: String) -> ProjectSnapshot?
    func createProjectID() -> String
    func defaultProjectName() -> String
}

enum ProjectStorageError: Error {
    case projectNotFound
    case indexReadFailed
    case writeFailed
    case decodeFailed
}

final class ProjectStorageService: ProjectStorageManaging {
    private let fileManager: FileManager
    private let projectsURL: URL
    private let autosavesURL: URL
    private let telemetryURL: URL
    private let indexURL: URL
    private let indexFileURL: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.projectsURL = InternalStorePaths.projects(fileManager: fileManager)
        self.autosavesURL = InternalStorePaths.autosaves(fileManager: fileManager)
        self.telemetryURL = InternalStorePaths.telemetry(fileManager: fileManager)
        self.indexURL = InternalStorePaths.index(fileManager: fileManager)
        self.indexFileURL = indexURL.appendingPathComponent("projects_index.json")

        ensureBaseDirectories()
    }

    func listProjects() -> [ProjectRecordSummary] {
        (try? readIndex()) ?? []
    }

    @discardableResult
    func saveProject(id: String, name: String, snapshot: ProjectSnapshot) throws -> ProjectRecordSummary {
        ensureBaseDirectories()

        let now = Date()
        let projectDir = projectsURL.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        } catch {
            throw ProjectStorageError.writeFailed
        }

        let snapshotURL = projectDir.appendingPathComponent("project.json")
        var materialized = snapshot
        materialized.projectID = id
        materialized.projectName = name
        materialized.savedAt = now

        do {
            let data = try encoder.encode(materialized)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            throw ProjectStorageError.writeFailed
        }

        var index = try readIndex()
        let summary: ProjectRecordSummary
        if let existing = index.firstIndex(where: { $0.id == id }) {
            var updated = index[existing]
            updated.name = name
            updated.modifiedAt = now
            updated.lastSavedAt = now
            summary = updated
            index[existing] = updated
        } else {
            let created = ProjectRecordSummary(
                id: id,
                name: name,
                createdAt: now,
                modifiedAt: now,
                lastOpenedAt: now,
                lastSavedAt: now
            )
            summary = created
            index.append(created)
        }

        try writeIndex(index)
        return summary
    }

    func loadProject(id: String) throws -> ProjectSnapshot {
        let snapshotURL = projectsURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("project.json")

        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw ProjectStorageError.projectNotFound
        }

        let snapshot: ProjectSnapshot
        do {
            let data = try Data(contentsOf: snapshotURL)
            snapshot = try decoder.decode(ProjectSnapshot.self, from: data)
        } catch {
            throw ProjectStorageError.decodeFailed
        }

        var index = try readIndex()
        if let existing = index.firstIndex(where: { $0.id == id }) {
            index[existing].lastOpenedAt = Date()
            index[existing].modifiedAt = max(index[existing].modifiedAt, snapshot.savedAt)
            try writeIndex(index)
        }

        return snapshot
    }

    @discardableResult
    func duplicateProject(id: String, newName: String) throws -> ProjectRecordSummary {
        let original = try loadProject(id: id)
        var duplicate = original
        duplicate.projectID = createProjectID()
        duplicate.projectName = newName
        duplicate.savedAt = Date()
        return try saveProject(id: duplicate.projectID, name: newName, snapshot: duplicate)
    }

    func deleteProject(id: String) throws {
        let projectDir = projectsURL.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: projectDir.path) {
            do {
                try fileManager.removeItem(at: projectDir)
            } catch {
                throw ProjectStorageError.writeFailed
            }
        }

        let autosaveURL = autosavesURL.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: autosaveURL.path) {
            try? fileManager.removeItem(at: autosaveURL)
        }

        let projectTelemetryURL = telemetryURL.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: projectTelemetryURL.path) {
            try? fileManager.removeItem(at: projectTelemetryURL)
        }

        var index = try readIndex()
        index.removeAll { $0.id == id }
        try writeIndex(index)
    }

    func autosave(projectID: String, snapshot: ProjectSnapshot) throws {
        ensureBaseDirectories()
        let autosaveURL = autosavesURL.appendingPathComponent("\(projectID).json")
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: autosaveURL, options: .atomic)
        } catch {
            throw ProjectStorageError.writeFailed
        }
    }

    func loadAutosave(projectID: String) -> ProjectSnapshot? {
        let autosaveURL = autosavesURL.appendingPathComponent("\(projectID).json")
        guard fileManager.fileExists(atPath: autosaveURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: autosaveURL) else {
            return nil
        }
        return try? decoder.decode(ProjectSnapshot.self, from: data)
    }

    func createProjectID() -> String {
        UUID().uuidString.lowercased()
    }

    func defaultProjectName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Project \(formatter.string(from: Date()))"
    }

    private func ensureBaseDirectories() {
        [projectsURL, autosavesURL, telemetryURL, indexURL].forEach { url in
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: indexFileURL.path) {
            try? writeIndex([])
        }
    }

    private func readIndex() throws -> [ProjectRecordSummary] {
        ensureBaseDirectories()
        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: indexFileURL)
            if data.isEmpty {
                return []
            }
            return try decoder.decode([ProjectRecordSummary].self, from: data)
        } catch {
            throw ProjectStorageError.indexReadFailed
        }
    }

    private func writeIndex(_ value: [ProjectRecordSummary]) throws {
        do {
            let data = try encoder.encode(value)
            try data.write(to: indexFileURL, options: .atomic)
        } catch {
            throw ProjectStorageError.writeFailed
        }
    }
}

struct TelemetrySessionMetadata {
    var projectID: String
    var projectName: String
    var modelID: String
    var modelName: String
    var manufacturer: String
    var isAbstractModel: Bool
    var abstractParametersSummary: String
    var weatherPreset: String
    var weatherIntensity: Float
    var terrainPreset: String
    var terrainDensity: Float
    var cameraMode: String
    var controlMode: String
}

protocol TelemetryExporting {
    func append(snapshot: TelemetrySnapshot)
    func exportNow(metadata: TelemetrySessionMetadata, destinationDirectory: URL?) -> Result<URL, Error>
    func persistInternalSession(metadata: TelemetrySessionMetadata) -> Result<URL, Error>
    func finalizeSession()
}

enum TelemetryExportError: Error {
    case cannotCreateDirectory
    case cannotWriteData
    case missingDestination
}

final class TelemetryExportService: TelemetryExporting {
    private let fileManager: FileManager
    private let telemetryRootURL: URL
    private var snapshots: [TelemetrySnapshot] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.telemetryRootURL = InternalStorePaths.telemetry(fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: telemetryRootURL, withIntermediateDirectories: true)
        } catch {
            // Keep in-memory recording and report only when explicit export is requested.
        }
    }

    func append(snapshot: TelemetrySnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > 20_000 {
            snapshots.removeFirst(snapshots.count - 20_000)
        }
    }

    func exportNow(metadata: TelemetrySessionMetadata, destinationDirectory: URL?) -> Result<URL, Error> {
        guard let destinationDirectory else {
            return .failure(TelemetryExportError.missingDestination)
        }

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(TelemetryExportError.cannotCreateDirectory)
        }

        return writeTelemetryFile(
            to: destinationDirectory,
            metadata: metadata,
            filenamePrefix: "telemetry_export"
        )
    }

    func persistInternalSession(metadata: TelemetrySessionMetadata) -> Result<URL, Error> {
        let projectTelemetryURL = telemetryRootURL.appendingPathComponent(metadata.projectID, isDirectory: true)
        do {
            try fileManager.createDirectory(at: projectTelemetryURL, withIntermediateDirectories: true)
        } catch {
            return .failure(TelemetryExportError.cannotCreateDirectory)
        }

        return writeTelemetryFile(
            to: projectTelemetryURL,
            metadata: metadata,
            filenamePrefix: "session"
        )
    }

    func finalizeSession() {
        snapshots.removeAll(keepingCapacity: false)
    }

    private func writeTelemetryFile(
        to directoryURL: URL,
        metadata: TelemetrySessionMetadata,
        filenamePrefix: String
    ) -> Result<URL, Error> {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let safeName = metadata.projectName.replacingOccurrences(of: " ", with: "_")
        let url = directoryURL.appendingPathComponent("\(filenamePrefix)_\(safeName)_\(stamp).txt")

        let payload = buildPayload(metadata: metadata, snapshots: snapshots)
        guard let data = payload.data(using: .utf8) else {
            return .failure(TelemetryExportError.cannotWriteData)
        }

        do {
            try data.write(to: url, options: .atomic)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    private func buildPayload(metadata: TelemetrySessionMetadata, snapshots: [TelemetrySnapshot]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(snapshots.count + 16)

        lines.append("# Telemetry Session")
        lines.append("# exported_at=\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("# project_id=\(metadata.projectID)")
        lines.append("# project_name=\(metadata.projectName)")
        lines.append("# model_id=\(metadata.modelID)")
        lines.append("# model_name=\(metadata.modelName)")
        lines.append("# manufacturer=\(metadata.manufacturer)")
        lines.append("# abstract_model=\(metadata.isAbstractModel)")
        lines.append("# abstract_parameters=\(metadata.abstractParametersSummary)")
        lines.append("# weather=\(metadata.weatherPreset)")
        lines.append("# weather_intensity=\(String(format: "%.2f", metadata.weatherIntensity))")
        lines.append("# terrain=\(metadata.terrainPreset)")
        lines.append("# terrain_density=\(String(format: "%.2f", metadata.terrainDensity))")
        lines.append("# camera_mode=\(metadata.cameraMode)")
        lines.append("# control_mode=\(metadata.controlMode)")
        lines.append(Self.header)

        for snapshot in snapshots {
            lines.append(Self.serialize(snapshot: snapshot))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static let header: String = [
        "timestamp",
        "drone_id",
        "drone_name",
        "terrain",
        "terrain_density",
        "camera_mode",
        "x",
        "y",
        "z",
        "vx",
        "vy",
        "vz",
        "roll_deg",
        "pitch_deg",
        "yaw_deg",
        "speed_mps",
        "throttle",
        "flight_mode",
        "control_mode",
        "flight_state",
        "battery_percent",
        "battery_health_percent",
        "power_draw_w",
        "remaining_minutes",
        "weather_preset",
        "weather_intensity",
        "collision_risk",
        "nearest_obstacle_distance_m",
        "nearest_obstacle_source",
        "path_status",
        "current_waypoint_index",
        "remaining_waypoints",
        "path_length_m",
        "path_remaining_distance_m",
        "fixed_wing_state",
        "fixed_wing_active_waypoint_index",
        "fixed_wing_cross_track_error_m",
        "fixed_wing_leg_course_deg",
        "fixed_wing_leg_start_x",
        "fixed_wing_leg_start_z",
        "fixed_wing_leg_end_x",
        "fixed_wing_leg_end_z",
        "fixed_wing_waypoint_vector_x",
        "fixed_wing_waypoint_vector_z",
        "fixed_wing_heading_deg",
        "fixed_wing_ground_track_deg",
        "fixed_wing_target_airspeed_mps",
        "fixed_wing_target_altitude_m",
        "fixed_wing_roll_cmd_deg",
        "fixed_wing_pitch_cmd_deg",
        "fixed_wing_throttle_cmd",
        "fixed_wing_speed_recovery",
        "fixed_wing_along_track_progress",
        "fixed_wing_battery_tier",
        "fixed_wing_profile_limits_active",
        "fixed_wing_transition_reason",
        "mission_abort_reason",
        "mode_transition_reason",
        "emergency_action",
        "damage_summary",
        "thermal_summary",
        "damage_event_sequence",
        "damage_event_type",
        "damage_event_component_id",
        "damage_event_collider_id",
        "damage_event_energy_j",
        "damage_event_integrity",
        "damage_mass_revision",
        "fleet_mode",
        "wingman_count",
        "inter_drone_risk",
        "nearest_inter_drone_distance_m",
        "frame_ms",
        "physics_ms",
        "render_ms",
        "path_ms",
        "active_objects",
        "active_physics_bodies",
        "particle_count",
        "abstract_parameters"
    ].joined(separator: "\t")

    private static func serialize(snapshot: TelemetrySnapshot) -> String {
        [
            snapshot.timestampISO8601,
            snapshot.droneModelID,
            snapshot.droneModelName,
            snapshot.terrainPreset,
            String(format: "%.2f", snapshot.terrainDensity),
            snapshot.cameraMode,
            String(format: "%.3f", snapshot.x),
            String(format: "%.3f", snapshot.y),
            String(format: "%.3f", snapshot.z),
            String(format: "%.3f", snapshot.velocityX),
            String(format: "%.3f", snapshot.velocityY),
            String(format: "%.3f", snapshot.velocityZ),
            String(format: "%.2f", snapshot.roll),
            String(format: "%.2f", snapshot.pitch),
            String(format: "%.2f", snapshot.yaw),
            String(format: "%.2f", snapshot.speed),
            String(format: "%.3f", snapshot.throttle),
            snapshot.modeTitle,
            snapshot.controlModeKey,
            snapshot.flightState,
            String(format: "%.2f", snapshot.batteryPercent),
            String(format: "%.2f", snapshot.batteryHealthPercent),
            String(format: "%.2f", snapshot.powerDrawW),
            String(format: "%.1f", snapshot.estimatedRemainingMin),
            snapshot.weatherPreset,
            String(format: "%.2f", snapshot.weatherIntensity),
            String(format: "%.2f", snapshot.collisionRisk),
            String(format: "%.2f", snapshot.nearestObstacleDistance),
            snapshot.nearestObstacleSource,
            snapshot.pathStatus,
            String(snapshot.currentWaypointIndex),
            String(snapshot.remainingWaypoints),
            String(format: "%.2f", snapshot.pathLengthMeters),
            String(format: "%.2f", snapshot.pathRemainingDistanceMeters),
            snapshot.fixedWingMissionState,
            String(snapshot.fixedWingActiveWaypointIndex),
            String(format: "%.2f", snapshot.fixedWingCrossTrackErrorMeters),
            String(format: "%.2f", snapshot.fixedWingLegCourseDegrees),
            String(format: "%.2f", snapshot.fixedWingLegStartX),
            String(format: "%.2f", snapshot.fixedWingLegStartZ),
            String(format: "%.2f", snapshot.fixedWingLegEndX),
            String(format: "%.2f", snapshot.fixedWingLegEndZ),
            String(format: "%.2f", snapshot.fixedWingWaypointVectorX),
            String(format: "%.2f", snapshot.fixedWingWaypointVectorZ),
            String(format: "%.2f", snapshot.fixedWingHeadingDegrees),
            String(format: "%.2f", snapshot.fixedWingGroundTrackDegrees),
            String(format: "%.2f", snapshot.fixedWingTargetAirspeed),
            String(format: "%.2f", snapshot.fixedWingTargetAltitude),
            String(format: "%.2f", snapshot.fixedWingCommandedRollDegrees),
            String(format: "%.2f", snapshot.fixedWingCommandedPitchDegrees),
            String(format: "%.3f", snapshot.fixedWingCommandedThrottle),
            snapshot.fixedWingSpeedRecoveryActive ? "1" : "0",
            String(format: "%.3f", snapshot.fixedWingAlongTrackProgress),
            snapshot.fixedWingBatteryWarningLevel,
            snapshot.fixedWingProfileLimitsActive ? "1" : "0",
            snapshot.fixedWingTransitionReason,
            snapshot.missionAbortReason,
            snapshot.modeTransitionReason,
            snapshot.emergencyAction,
            snapshot.damageSummary,
            snapshot.thermalSummary,
            String(snapshot.damageEventSequence),
            snapshot.damageEventType,
            snapshot.damageEventComponentID,
            snapshot.damageEventColliderID,
            String(format: "%.3f", snapshot.damageEventEnergyJ),
            String(format: "%.5f", snapshot.damageEventIntegrity),
            String(snapshot.damageMassPropertiesRevision),
            snapshot.fleetMode,
            String(snapshot.wingmanCount),
            String(format: "%.2f", snapshot.interDroneRisk),
            String(format: "%.2f", snapshot.nearestInterDroneDistance),
            String(format: "%.2f", snapshot.frameTimeMs),
            String(format: "%.2f", snapshot.physicsTimeMs),
            String(format: "%.2f", snapshot.renderTimeMs),
            String(format: "%.2f", snapshot.pathfindingTimeMs),
            String(snapshot.activeObjectCount),
            String(snapshot.activePhysicsBodyCount),
            String(snapshot.activeParticleCount),
            snapshot.abstractParametersSummary
        ].joined(separator: "\t")
    }
}
