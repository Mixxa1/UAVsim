import Foundation

// MARK: - Palette

/// False-color palette applied to the normalized thermal value. All three share one
/// temperature model + normalization — the palette only changes how a value is displayed.
enum ThermalPalette: String, CaseIterable, Identifiable, Codable {
    case whiteHot
    case blackHot
    case iron

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .whiteHot: return "payload.camera.thermal.palette.white_hot"
        case .blackHot: return "payload.camera.thermal.palette.black_hot"
        case .iron: return "payload.camera.thermal.palette.iron"
        }
    }

    var feedLabel: String {
        switch self {
        case .whiteHot: return "THERMAL WHITE HOT"
        case .blackHot: return "THERMAL BLACK HOT"
        case .iron: return "THERMAL IRON"
        }
    }
}

// MARK: - Scene profile

/// Coarse description of the map, used to bias the display range so the picture reads
/// like the right kind of scene (a snow map should not normalize to a hot field).
enum ThermalSceneProfile: String, CaseIterable, Identifiable, Codable {
    case neutral
    case forest
    case field
    case city
    case snow
    case waterCoast
    case mountain

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .neutral: return "payload.camera.thermal.profile.neutral"
        case .forest: return "payload.camera.thermal.profile.forest"
        case .field: return "payload.camera.thermal.profile.field"
        case .city: return "payload.camera.thermal.profile.city"
        case .snow: return "payload.camera.thermal.profile.snow"
        case .waterCoast: return "payload.camera.thermal.profile.water"
        case .mountain: return "payload.camera.thermal.profile.mountain"
        }
    }
}

/// User-facing profile selection: `.auto` lets the resolver pick from the map + weather.
enum ThermalProfileSelection: String, CaseIterable, Identifiable, Codable {
    case auto
    case neutral
    case forest
    case field
    case city
    case snow
    case waterCoast
    case mountain

    var id: String { rawValue }

    var explicitProfile: ThermalSceneProfile? {
        switch self {
        case .auto: return nil
        case .neutral: return .neutral
        case .forest: return .forest
        case .field: return .field
        case .city: return .city
        case .snow: return .snow
        case .waterCoast: return .waterCoast
        case .mountain: return .mountain
        }
    }

    var titleKey: String {
        switch self {
        case .auto: return "payload.camera.thermal.profile.auto"
        case .neutral: return "payload.camera.thermal.profile.neutral"
        case .forest: return "payload.camera.thermal.profile.forest"
        case .field: return "payload.camera.thermal.profile.field"
        case .city: return "payload.camera.thermal.profile.city"
        case .snow: return "payload.camera.thermal.profile.snow"
        case .waterCoast: return "payload.camera.thermal.profile.water"
        case .mountain: return "payload.camera.thermal.profile.mountain"
        }
    }
}

// MARK: - Material class

/// Thermal surface classes. Determines the baseline temperature + weather sensitivity of
/// a surface — this is the primary signal, far more important than per-pixel colour.
enum ThermalMaterialClass: String, CaseIterable, Codable {
    case sky
    case snow
    case ice
    case water
    case terrain
    case grass
    case foliage
    case treeTrunk
    case rock
    case road
    case bareSoil
    case building
    case roof
    case concrete
    case metal
    case asphalt
    case glass
    case shadow
    case generic
    case body

    var titleKey: String { "payload.camera.thermal.class.\(rawValue)" }
}

// MARK: - Environment context

/// Read-only snapshot of the simulation conditions that drive the thermal model.
/// Built once per weather/map change by `ThermalEnvironmentAdapter` — never mutates the
/// real weather/map state.
struct ThermalEnvironmentContext: Equatable {
    var mapKind: String
    var sceneProfile: ThermalSceneProfile

    var timeOfDayHours: Double
    var isNight: Bool
    var sunExposure: Double          // 0...1 effective solar heating multiplier

    var ambientTemperatureCelsius: Double

    var weatherKind: String
    var rainIntensity: Double        // 0...1
    var snowIntensity: Double        // 0...1
    var fogDensity: Double           // 0...1
    var cloudiness: Double           // 0...1
    var windSpeedMps: Double
    var visibilityMeters: Double

    var groundWetness: Double        // 0...1
    var snowCoverage: Double         // 0...1

    static let neutral = ThermalEnvironmentContext(
        mapKind: "neutral",
        sceneProfile: .neutral,
        timeOfDayHours: 12.0,
        isNight: false,
        sunExposure: 1.0,
        ambientTemperatureCelsius: 16.0,
        weatherKind: "normal",
        rainIntensity: 0.0,
        snowIntensity: 0.0,
        fogDensity: 0.0,
        cloudiness: 0.1,
        windSpeedMps: 0.0,
        visibilityMeters: 4000.0,
        groundWetness: 0.0,
        snowCoverage: 0.0
    )
}

// MARK: - Material properties

/// Per-class tuning. Offsets/sensitivities are expressed directly in °C contributions so the
/// final temperature formula stays readable.
struct ThermalMaterialProperties {
    var materialClass: ThermalMaterialClass

    var baselineOffsetCelsius: Double      // offset from ambient at neutral conditions
    var variationAmplitudeCelsius: Double  // spatial spread within the class

    var sunHeatingCelsius: Double          // added at full sun exposure
    var rainCoolingCelsius: Double         // subtracted at full rain
    var snowCoolingCelsius: Double         // subtracted at full snow
    var windCoolingCelsius: Double         // subtracted at full wind
    var nightCoolingCelsius: Double        // subtracted at night

    var minClampOffsetCelsius: Double      // clamp final T to ambient+min...ambient+max
    var maxClampOffsetCelsius: Double
}

// MARK: - Normalization

/// Display-range stabilizer. Range is derived from the *scene-wide population* of classified
/// temperatures (camera-independent by construction), so panning the camera never re-stretches
/// the palette.
struct ThermalNormalizationState: Equatable {
    var displayMinCelsius: Double
    var displayMaxCelsius: Double

    static let neutral = ThermalNormalizationState(
        displayMinCelsius: -6.0,
        displayMaxCelsius: 28.0
    )

    var spanCelsius: Double { max(0.5, displayMaxCelsius - displayMinCelsius) }
}

// MARK: - Diagnostics

/// Plain data for the debug overlay. Center fields come from a center-of-frame raycast against
/// the thermal proxy geometry, computed only while diagnostics are enabled.
struct ThermalDiagnosticsSnapshot: Equatable {
    var ambientTemperatureCelsius: Double
    var weatherKind: String
    var sceneProfile: ThermalSceneProfile
    var displayMinCelsius: Double
    var displayMaxCelsius: Double

    var centerTemperatureCelsius: Double?
    var centerMaterialClass: ThermalMaterialClass?
    var centerNodeName: String?

    var rainIntensity: Double
    var snowIntensity: Double
    var fogDensity: Double
    var cloudiness: Double
    var windSpeedMps: Double
    var sunExposure: Double

    static let empty = ThermalDiagnosticsSnapshot(
        ambientTemperatureCelsius: 16.0,
        weatherKind: "normal",
        sceneProfile: .neutral,
        displayMinCelsius: -6.0,
        displayMaxCelsius: 28.0,
        centerTemperatureCelsius: nil,
        centerMaterialClass: nil,
        centerNodeName: nil,
        rainIntensity: 0.0,
        snowIntensity: 0.0,
        fogDensity: 0.0,
        cloudiness: 0.0,
        windSpeedMps: 0.0,
        sunExposure: 1.0
    )
}

// MARK: - Payload thermal display state

/// UI-facing thermal state for the payload camera (published from the view model).
struct PayloadThermalState: Equatable {
    var isAvailable: Bool
    var isEnabled: Bool

    var palette: ThermalPalette
    var profileSelection: ThermalProfileSelection
    var resolvedProfile: ThermalSceneProfile

    var contrast: Double      // 0.4...1.8, default 1.0
    var brightness: Double    // -0.3...0.3, default 0.0
    var noiseAmount: Double   // 0...1, default 0.35

    var showDiagnostics: Bool
    var diagnostics: ThermalDiagnosticsSnapshot

    static let `default` = PayloadThermalState(
        isAvailable: true,
        isEnabled: false,
        palette: .whiteHot,
        profileSelection: .auto,
        resolvedProfile: .neutral,
        contrast: 1.0,
        brightness: 0.0,
        noiseAmount: 0.5,
        showDiagnostics: false,
        diagnostics: .empty
    )
}
