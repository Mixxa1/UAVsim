import Foundation
import simd

// MARK: - Scenario kind

/// A mission scenario type.
enum MissionScenarioKind: String, CaseIterable, Identifiable, Hashable {
    case searchAndRescue
    case fireResponse

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .searchAndRescue:
            return "mission.scenario.search_and_rescue.title"
        case .fireResponse:
            return "mission.scenario.fire_response.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .searchAndRescue:
            return "mission.scenario.search_and_rescue.subtitle"
        case .fireResponse:
            return "mission.scenario.fire_response.subtitle"
        }
    }

    var iconSystemName: String {
        switch self {
        case .searchAndRescue:
            return "figure.wave"
        case .fireResponse:
            return "flame.fill"
        }
    }

    /// Payload types whose camera can accomplish this scenario's detection objective.
    var compatiblePayloads: [PayloadType] {
        switch self {
        case .searchAndRescue:
            return [.thermalCamera, .cameraGimbal]
        case .fireResponse:
            return [.fireHose, .fireCapsuleLauncher]
        }
    }
}

// MARK: - Time of day

/// Time-of-day setting for a mission. Drives scene lighting/sky and is forwarded
/// to the thermal pipeline (`ThermalEnvironmentAdapter.makeContext(isNight:timeOfDayHours:)`).
enum TimeOfDay: String, CaseIterable, Identifiable, Hashable {
    case day
    case dusk
    case night

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .day:
            return "mission.time_of_day.day"
        case .dusk:
            return "mission.time_of_day.dusk"
        case .night:
            return "mission.time_of_day.night"
        }
    }

    var iconSystemName: String {
        switch self {
        case .day:
            return "sun.max"
        case .dusk:
            return "sun.horizon"
        case .night:
            return "moon.stars"
        }
    }

    var timeOfDayHours: Double {
        switch self {
        case .day:
            return 12.0
        case .dusk:
            return 19.5
        case .night:
            return 1.0
        }
    }

    var isNight: Bool { self == .night }

    /// Multiplier applied to the scene's default sun light intensity (1.0 = full daylight).
    var sunIntensityMultiplier: Double {
        switch self {
        case .day:
            return 1.0
        case .dusk:
            return 0.45
        case .night:
            return 0.01
        }
    }

    /// Multiplier applied to ambient/IBL exposure. Night is intentionally near-black — the
    /// scenario's whole premise is that you can't see, hence thermal/searchlight equipment.
    var ambientIntensityMultiplier: Double {
        switch self {
        case .day:
            return 1.0
        case .dusk:
            return 0.55
        case .night:
            return 0.015
        }
    }
}

// MARK: - Difficulty

enum MissionDifficulty: String, CaseIterable, Identifiable, Hashable {
    case easy
    case medium
    case hard

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .easy:
            return "mission.difficulty.easy"
        case .medium:
            return "mission.difficulty.medium"
        case .hard:
            return "mission.difficulty.hard"
        }
    }

    /// Radius of the circular search sector. Harder = larger area to sweep.
    var searchRadiusMeters: Float {
        switch self {
        case .easy:
            return 120.0
        case .medium:
            return 200.0
        case .hard:
            return 320.0
        }
    }

    /// Default mission time budget; remains user-editable after a difficulty change.
    var defaultTimeLimitMinutes: Int {
        switch self {
        case .easy:
            return 12
        case .medium:
            return 10
        case .hard:
            return 8
        }
    }

    /// How many candidate (possible) target markers to scatter in the sector for briefing.
    var candidatePositionCount: Int {
        switch self {
        case .easy:
            return 2
        case .medium:
            return 3
        case .hard:
            return 4
        }
    }

    /// Radius of the fire zone (`.fireResponse`). Deliberately more compact than
    /// `searchRadiusMeters` so multiple simultaneous fires read as one zone, not a scavenger hunt.
    var fireZoneRadiusMeters: Float {
        switch self {
        case .easy:
            return 90.0
        case .medium:
            return 130.0
        case .hard:
            return 180.0
        }
    }

    /// Total trees seeded in the fire zone (a fixed pool; `initialFireCount` of them start lit).
    var fireTreeCount: Int {
        switch self {
        case .easy:
            return 6
        case .medium:
            return 9
        case .hard:
            return 13
        }
    }

    /// How many trees in the zone start pre-ignited.
    var initialFireCount: Int {
        switch self {
        case .easy:
            return 2
        case .medium:
            return 3
        case .hard:
            return 4
        }
    }

    /// How long an unattended burning tree takes before it ignites its nearest unburned
    /// neighbor. Shorter = harder (less time to react before the fire escalates).
    var fireSpreadIntervalSeconds: Double {
        switch self {
        case .easy:
            return 45.0
        case .medium:
            return 35.0
        case .hard:
            return 25.0
        }
    }

    /// Maximum distance a burning tree can ignite an unburned neighbor across.
    var fireSpreadRadiusMeters: Float {
        switch self {
        case .easy:
            return 12.0
        case .medium:
            return 14.0
        case .hard:
            return 16.0
        }
    }

    /// World map scale to generate at. Tree/object count is capped (a fixed pool spread over the
    /// whole map, regardless of preset — see `ScenePopulationService.maxCollidableObjectCount`,
    /// a deliberate collision/pathfinding performance ceiling), so a map much bigger than the
    /// search sector spreads that fixed pool thin and the forest reads as sparse no matter how
    /// high density is set. Picking the smallest map that still comfortably fits the sector (plus
    /// dock/corridor room) keeps the same object count but visually denser.
    var recommendedMapScale: MapScale {
        switch self {
        case .easy, .medium:
            return .x8
        case .hard:
            return .x16
        }
    }
}

// MARK: - Terrain density (pre-launch, user-editable)

/// Player-facing density preset for mission terrain generation. Exposed in `MissionSetupView`
/// instead of the raw 0...1 `TerrainConfiguration.density` value, since the mission flow already
/// concentrates most of the generated forest into the search sector (see
/// `ScenePopulationService.generateForest`'s sector-bias split) — this just lets the player trade
/// a bit of that sector density for fewer objects if they want it, rather than always maxing out.
enum MissionTerrainDensity: String, CaseIterable, Identifiable, Hashable {
    case sparse
    case medium
    case dense

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .sparse:
            return "mission.terrain_density.sparse"
        case .medium:
            return "mission.terrain_density.medium"
        case .dense:
            return "mission.terrain_density.dense"
        }
    }

    var densityValue: Float {
        switch self {
        case .sparse:
            return 0.5
        case .medium:
            return 0.75
        case .dense:
            return 1.0
        }
    }
}

// MARK: - Parameters (pre-launch, user-editable)

struct MissionScenarioParameters: Equatable {
    var kind: MissionScenarioKind
    var terrain: TerrainPreset
    var terrainDensity: MissionTerrainDensity
    var difficulty: MissionDifficulty
    var weather: WeatherPreset
    var weatherIntensity: Float
    var timeOfDay: TimeOfDay
    var timeLimitMinutes: Int
    var seed: UInt64

    init(
        kind: MissionScenarioKind = .searchAndRescue,
        terrain: TerrainPreset = .forest,
        terrainDensity: MissionTerrainDensity = .dense,
        difficulty: MissionDifficulty = .medium,
        weather: WeatherPreset = .normal,
        weatherIntensity: Float = 0.3,
        timeOfDay: TimeOfDay = .day,
        timeLimitMinutes: Int? = nil,
        seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) {
        self.kind = kind
        self.terrain = terrain
        self.terrainDensity = terrainDensity
        self.difficulty = difficulty
        self.weather = weather
        self.weatherIntensity = weatherIntensity
        self.timeOfDay = timeOfDay
        self.timeLimitMinutes = timeLimitMinutes ?? difficulty.defaultTimeLimitMinutes
        self.seed = seed
    }

    var searchRadiusMeters: Float { difficulty.searchRadiusMeters }
    var timeLimitSeconds: Double { Double(max(1, timeLimitMinutes)) * 60.0 }
}

// MARK: - Launch configuration (handed to the simulation view model)

struct MissionScenarioConfiguration: Equatable {
    var parameters: MissionScenarioParameters
    var selectedUAVProfileID: String
    var payloadType: PayloadType
    /// Only meaningful when `payloadType == .fireHose` — the rigging chosen at Mission Setup.
    var fireHoseDiameterClass: FireHoseDiameterClass = .standard
    var fireHoseLengthMeters: Float = 30.0
    /// Only meaningful when `payloadType == .fireCapsuleLauncher` — the rigging chosen at Mission Setup.
    var fireCapsuleSize: FireCapsuleSize = .medium
    var fireCapsuleCount: Int = 2
}

// MARK: - Derived placement (computed at launch from parameters + world)

struct MissionScenarioPlacement: Equatable {
    var sectorCenter: SIMD2<Float>
    var sectorRadius: Float
    var targetPosition: SIMD2<Float>
    var candidatePositions: [SIMD2<Float>]

    /// Deterministically derives the search sector + target/candidate positions from the
    /// scenario seed and the playable world bounds. Keeps the sector away from the world
    /// edge and the launch/dock point so the objective is always reachable.
    static func generate(
        parameters: MissionScenarioParameters,
        worldHalfExtent: Float,
        dockPosition: SIMD2<Float>
    ) -> MissionScenarioPlacement {
        var rng = MissionSeededGenerator(seed: parameters.seed)
        let radius = parameters.searchRadiusMeters

        // Keep the whole sector inside a safe inner region of the world.
        let safeExtent = max(radius + 20.0, worldHalfExtent * 0.7)
        let centerSpan = max(0.0, safeExtent - radius)

        func randomOffset(_ span: Float) -> Float {
            span <= 0.0 ? 0.0 : Float.random(in: -span...span, using: &rng)
        }

        // Place the sector center at least ~1 sector-radius from the dock so the operator
        // has to actually transit to the search area.
        var sectorCenter = dockPosition
        for _ in 0..<8 {
            let candidate = SIMD2<Float>(randomOffset(centerSpan), randomOffset(centerSpan))
            if simd_distance(candidate, dockPosition) >= radius * 0.9 {
                sectorCenter = candidate
                break
            }
            sectorCenter = candidate
        }

        func randomPointInSector() -> SIMD2<Float> {
            // Uniform-ish disc sample (sqrt for area weighting).
            let angle = Float.random(in: 0...(2.0 * .pi), using: &rng)
            let r = radius * sqrt(Float.random(in: 0...1, using: &rng)) * 0.92
            return sectorCenter + SIMD2<Float>(cos(angle) * r, sin(angle) * r)
        }

        let targetPosition = randomPointInSector()
        var candidates: [SIMD2<Float>] = [targetPosition]
        let extraCount = max(0, parameters.difficulty.candidatePositionCount - 1)
        for _ in 0..<extraCount {
            candidates.append(randomPointInSector())
        }
        candidates.shuffle(using: &rng)

        return MissionScenarioPlacement(
            sectorCenter: sectorCenter,
            sectorRadius: radius,
            targetPosition: targetPosition,
            candidatePositions: candidates
        )
    }
}

// MARK: - Runtime objective + outcome

/// Geometry facts about the scenario target relative to the payload camera, sampled by the
/// scene layer each tick. Detection thresholds (range / cone / dwell) live in the runtime, so
/// this struct stays free of SceneKit and policy.
struct MissionTargetDetectionSample: Equatable {
    var distanceMeters: Float
    var angleFromCameraAxisDegrees: Float
    var lineOfSightClear: Bool
}

enum MissionScenarioObjectiveState: Equatable {
    case searching
    case detected
    case failedTimeout
}

enum MissionScenarioOutcome: Equatable {
    case success(detectionElapsedSeconds: Double)
    case failureTimeout
    case aborted
}

// MARK: - Deterministic RNG

/// Small linear-congruential generator (matches the seeded-RNG style used elsewhere in the
/// project, e.g. `ScenePopulationService`) so scenario placement is reproducible from a seed.
struct MissionSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xCAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}
