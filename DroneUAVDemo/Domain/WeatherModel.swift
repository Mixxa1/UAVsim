import Foundation
import simd

enum WeatherPreset: String, CaseIterable, Identifiable {
    case normal
    case wind
    case rain
    case snow
    case fog
    case smog
    case thunderstorm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            return "Normal"
        case .wind:
            return "Wind"
        case .rain:
            return "Rain"
        case .snow:
            return "Snow"
        case .fog:
            return "Fog"
        case .smog:
            return "Smog"
        case .thunderstorm:
            return "Thunderstorm"
        }
    }

    var titleKey: String {
        switch self {
        case .normal:
            return "weather.normal"
        case .wind:
            return "weather.wind"
        case .rain:
            return "weather.rain"
        case .snow:
            return "weather.snow"
        case .fog:
            return "weather.fog"
        case .smog:
            return "weather.smog"
        case .thunderstorm:
            return "weather.thunderstorm"
        }
    }

    var baseFactors: WeatherFactors {
        switch self {
        case .normal:
            return WeatherFactors(
                visibilityFactor: 1.0,
                turbulenceFactor: 0.0,
                dragMultiplier: 1.0,
                batteryDrainMultiplier: 1.0,
                sensorNoiseMultiplier: 1.0,
                collisionRiskMultiplier: 1.0
            )
        case .wind:
            return WeatherFactors(
                visibilityFactor: 0.95,
                turbulenceFactor: 0.68,
                dragMultiplier: 1.08,
                batteryDrainMultiplier: 1.12,
                sensorNoiseMultiplier: 1.16,
                collisionRiskMultiplier: 1.20
            )
        case .rain:
            return WeatherFactors(
                visibilityFactor: 0.72,
                turbulenceFactor: 0.47,
                dragMultiplier: 1.12,
                batteryDrainMultiplier: 1.30,
                sensorNoiseMultiplier: 1.35,
                collisionRiskMultiplier: 1.30
            )
        case .snow:
            return WeatherFactors(
                visibilityFactor: 0.66,
                turbulenceFactor: 0.52,
                dragMultiplier: 1.15,
                batteryDrainMultiplier: 1.36,
                sensorNoiseMultiplier: 1.42,
                collisionRiskMultiplier: 1.38
            )
        case .fog:
            return WeatherFactors(
                visibilityFactor: 0.40,
                turbulenceFactor: 0.20,
                dragMultiplier: 1.03,
                batteryDrainMultiplier: 1.12,
                sensorNoiseMultiplier: 1.34,
                collisionRiskMultiplier: 1.56
            )
        case .smog:
            return WeatherFactors(
                visibilityFactor: 0.44,
                turbulenceFactor: 0.30,
                dragMultiplier: 1.06,
                batteryDrainMultiplier: 1.22,
                sensorNoiseMultiplier: 1.50,
                collisionRiskMultiplier: 1.60
            )
        case .thunderstorm:
            return WeatherFactors(
                visibilityFactor: 0.28,
                turbulenceFactor: 1.0,
                dragMultiplier: 1.22,
                batteryDrainMultiplier: 1.72,
                sensorNoiseMultiplier: 1.95,
                collisionRiskMultiplier: 2.15
            )
        }
    }
}

struct WeatherFactors {
    let visibilityFactor: Float
    let turbulenceFactor: Float
    let dragMultiplier: Float
    let batteryDrainMultiplier: Float
    let sensorNoiseMultiplier: Float
    let collisionRiskMultiplier: Float
}

struct WeatherModel {
    var preset: WeatherPreset
    var intensity: Float
    var windDirectionDeg: Float
    var windSpeedMps: Float
    var gusts: Float

    static let normal = WeatherModel(
        preset: .normal,
        intensity: 0.0,
        windDirectionDeg: 0.0,
        windSpeedMps: 0.0,
        gusts: 0.0
    )

    var normalizedIntensity: Float {
        intensity.clamped(to: 0.0...1.0)
    }

    var effectiveFactors: WeatherFactors {
        let i = normalizedIntensity
        let base = preset.baseFactors

        return WeatherFactors(
            visibilityFactor: interpolate(from: 1.0, to: base.visibilityFactor, t: i),
            turbulenceFactor: interpolate(from: 0.0, to: base.turbulenceFactor, t: i),
            dragMultiplier: interpolate(from: 1.0, to: base.dragMultiplier, t: i),
            batteryDrainMultiplier: interpolate(from: 1.0, to: base.batteryDrainMultiplier, t: i),
            sensorNoiseMultiplier: interpolate(from: 1.0, to: base.sensorNoiseMultiplier, t: i),
            collisionRiskMultiplier: interpolate(from: 1.0, to: base.collisionRiskMultiplier, t: i)
        )
    }

    var windVector: SIMD3<Float> {
        let theta = windDirectionDeg * .pi / 180.0
        let gustTerm = 1.0 + normalizedIntensity * gusts.clamped(to: 0.0...1.0) * 0.7
        let magnitude = windSpeedMps * gustTerm
        return SIMD3<Float>(sin(theta) * magnitude, 0.0, cos(theta) * magnitude)
    }

    var severityScore: Float {
        let factors = effectiveFactors
        return (
            (1.0 - factors.visibilityFactor) * 0.20 +
            factors.turbulenceFactor * 0.23 +
            (factors.dragMultiplier - 1.0) * 0.11 +
            (factors.sensorNoiseMultiplier - 1.0) * 0.22 +
            (factors.collisionRiskMultiplier - 1.0) * 0.24
        ).clamped(to: 0.0...1.0)
    }

    private func interpolate(from start: Float, to end: Float, t: Float) -> Float {
        start + (end - start) * t
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
