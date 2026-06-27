import Foundation

/// Read-only collector: turns the live `WeatherModel` + map preset into a `ThermalEnvironmentContext`.
///
/// This project has no real day/night or ambient-temperature system (verified by grep — no
/// time-of-day / sun-elevation state anywhere). Ambient temperature and the rain/snow/fog/wind
/// fields are therefore *synthesized* from the weather preset + intensity. `isNight` /
/// `timeOfDayHours` are accepted as parameters for forward-compat but default to daytime; if a
/// real day/night cycle is ever added, wire it in here first.
enum ThermalEnvironmentAdapter {

    /// Per-preset ambient temperature: (value at 0 intensity, value at full intensity).
    /// Snow's floor (0% intensity) is already well below freezing, not just "cool" — matching
    /// `refreshGroundMaterial`/tree-kind switching, which both key on `preset == .snow` alone,
    /// independent of the intensity slider (selecting Snow always means snow, even at 0%).
    private static func ambientRange(for preset: WeatherPreset) -> (calm: Double, severe: Double) {
        switch preset {
        case .normal: return (18.0, 16.0)
        case .wind: return (15.0, 11.0)
        case .rain: return (13.0, 5.0)
        case .snow: return (-6.0, -12.0)
        case .fog: return (11.0, 6.0)
        case .smog: return (13.0, 9.0)
        case .thunderstorm: return (12.0, 6.0)
        }
    }

    static func makeContext(
        weather: WeatherModel,
        terrain: TerrainPreset,
        sceneProfile: ThermalSceneProfile,
        isNight: Bool = false,
        timeOfDayHours: Double = 12.0
    ) -> ThermalEnvironmentContext {
        let intensity = Double(weather.normalizedIntensity)
        let preset = weather.preset

        let ambientBounds = ambientRange(for: preset)
        var ambient = ambientBounds.calm + (ambientBounds.severe - ambientBounds.calm) * intensity
        if isNight {
            ambient -= 6.0
        }

        // Derived weather scalars. Each "active" preset has a floor so even a 0% slider reads
        // as the right kind of weather (matching the ground-material/tree-visual switches, which
        // also key on the preset rather than the intensity).
        let rain: Double
        switch preset {
        case .rain, .thunderstorm: rain = (0.35 + 0.65 * intensity).clampedUnit
        default: rain = 0.0
        }

        let snow: Double
        switch preset {
        // High floor: city/cargoYard's high-baseline classes (roof/road/concrete/metal) need
        // strong snow-cooling even at 0% intensity to read as cold — a low floor left them
        // reading warm/orange even though the much-colder ambient alone wasn't enough (confirmed
        // by hand-computing normalized values against a live screenshot of a city+snow scene).
        case .snow: snow = (0.70 + 0.30 * intensity).clampedUnit
        default: snow = 0.0
        }

        let fog: Double
        switch preset {
        case .fog, .smog: fog = (0.45 + 0.55 * intensity).clampedUnit
        case .thunderstorm: fog = (0.20 * intensity).clampedUnit
        default: fog = 0.05 * intensity
        }

        let cloudiness: Double
        switch preset {
        case .normal: cloudiness = 0.10 + 0.20 * intensity
        case .wind: cloudiness = 0.30 + 0.30 * intensity
        case .rain, .snow: cloudiness = 0.70 + 0.30 * intensity
        case .fog, .smog: cloudiness = 0.55 + 0.30 * intensity
        case .thunderstorm: cloudiness = 0.85 + 0.15 * intensity
        }

        let presetWind: Double
        switch preset {
        case .wind: presetWind = 6.0 + 8.0 * intensity
        case .thunderstorm: presetWind = 8.0 + 9.0 * intensity
        case .rain, .snow: presetWind = 2.0 + 4.0 * intensity
        default: presetWind = 1.0 + 2.0 * intensity
        }
        // Prefer the real configured wind speed if present, else the preset estimate.
        let wind = max(Double(weather.windSpeedMps), presetWind)

        let groundWetness: Double
        switch preset {
        case .rain, .thunderstorm: groundWetness = (0.30 + 0.70 * intensity).clampedUnit
        case .fog: groundWetness = 0.20 * intensity
        default: groundWetness = 0.0
        }

        let snowCoverage = snow > 0.0 ? (0.45 + 0.55 * intensity).clampedUnit : 0.0

        // Effective solar heating: knocked down by cloud cover, zeroed at night. Full (not
        // dampened) cloud-cover suppression — at the snow/rain preset's high cloudiness this
        // keeps roofs/roads from heating up almost as much as on a clear day, which a partial
        // (×0.75) damping let happen (a sunlit roof under snow weather isn't physically sensible).
        let sunExposure = isNight ? 0.0 : max(0.0, 1.0 - cloudiness)

        let visibility = max(60.0, Double(weather.effectiveFactors.visibilityFactor) * 4000.0)

        return ThermalEnvironmentContext(
            mapKind: terrain.rawValue,
            sceneProfile: sceneProfile,
            timeOfDayHours: timeOfDayHours,
            isNight: isNight,
            sunExposure: sunExposure,
            ambientTemperatureCelsius: ambient,
            weatherKind: preset.rawValue,
            rainIntensity: rain,
            snowIntensity: snow,
            fogDensity: fog,
            cloudiness: cloudiness.clampedUnit,
            windSpeedMps: wind,
            visibilityMeters: visibility,
            groundWetness: groundWetness,
            snowCoverage: snowCoverage
        )
    }
}

private extension Double {
    var clampedUnit: Double { Swift.min(1.0, Swift.max(0.0, self)) }
}
