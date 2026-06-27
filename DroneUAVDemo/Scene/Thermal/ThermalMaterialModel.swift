import Foundation

/// The single temperature model shared by every palette and by the diagnostics probe.
///
/// `T = ambient + baseline + sun - rain - snow - wind - night + variation`, clamped per class.
/// All terms are already in °C. Ground/terrain are deliberately *not* hot by default; snow/ice/
/// water/foliage/treeTrunk stay cool; man-made surfaces (road/roof/metal) heat under sun and cool
/// fast under rain/snow/wind/night.
enum ThermalMaterialModel {

    static func properties(for materialClass: ThermalMaterialClass) -> ThermalMaterialProperties {
        switch materialClass {
        case .sky:
            return props(materialClass, baseline: -32, amp: 2.5, sun: 0, rain: 0, snow: 0, wind: 0, night: 4, lo: -42, hi: -18)
        case .snow:
            return props(materialClass, baseline: -12, amp: 2.0, sun: 1.0, rain: 0, snow: 4, wind: 1.5, night: 2, lo: -22, hi: -3)
        case .ice:
            return props(materialClass, baseline: -10, amp: 1.8, sun: 1.0, rain: 0, snow: 3, wind: 1.5, night: 2, lo: -20, hi: -2)
        case .water:
            return props(materialClass, baseline: 0, amp: 1.4, sun: 1.0, rain: 1.0, snow: 2, wind: 0.8, night: 1.5, lo: -6, hi: 5)
        case .terrain:
            return props(materialClass, baseline: 1.5, amp: 3.0, sun: 5.0, rain: 4.0, snow: 8.0, wind: 1.5, night: 3.0, lo: -10, hi: 11)
        case .grass:
            return props(materialClass, baseline: 0, amp: 2.6, sun: 3.0, rain: 3.0, snow: 7.0, wind: 2.0, night: 2.5, lo: -10, hi: 8)
        case .foliage:
            return props(materialClass, baseline: -1.0, amp: 2.2, sun: 2.5, rain: 2.5, snow: 5.0, wind: 2.5, night: 2.0, lo: -9, hi: 6)
        case .treeTrunk:
            return props(materialClass, baseline: -1.0, amp: 1.6, sun: 2.0, rain: 1.5, snow: 4.0, wind: 1.5, night: 2.0, lo: -8, hi: 5)
        case .rock:
            return props(materialClass, baseline: 3.0, amp: 3.0, sun: 6.0, rain: 3.0, snow: 6.0, wind: 1.0, night: 4.0, lo: -8, hi: 13)
        case .road, .asphalt:
            return props(materialClass, baseline: 4.0, amp: 2.4, sun: 9.0, rain: 6.0, snow: 8.0, wind: 1.5, night: 5.0, lo: -8, hi: 16)
        case .bareSoil:
            return props(materialClass, baseline: 3.0, amp: 3.0, sun: 7.0, rain: 5.0, snow: 7.0, wind: 1.5, night: 3.5, lo: -8, hi: 14)
        case .building:
            return props(materialClass, baseline: 2.0, amp: 2.6, sun: 5.0, rain: 3.0, snow: 5.0, wind: 1.0, night: 3.5, lo: -7, hi: 12)
        case .roof:
            return props(materialClass, baseline: 5.0, amp: 3.0, sun: 9.0, rain: 5.0, snow: 7.0, wind: 2.0, night: 5.5, lo: -7, hi: 17)
        case .concrete:
            return props(materialClass, baseline: 3.0, amp: 2.4, sun: 6.0, rain: 4.0, snow: 6.0, wind: 1.0, night: 4.0, lo: -7, hi: 13)
        case .metal:
            // Spec: metal cools rapidly under snow/wind — snow sensitivity kept the highest of any
            // class, sun-heating brought below road/roof's (a thin cargo-container wall doesn't
            // out-heat thick asphalt/concrete). Without this, metal containers under snow weather
            // landed almost exactly at the normalization band's midpoint — read as "hot" magenta/red
            // in iron despite being well below freezing (confirmed by hand-computing against a
            // cargoYard+snow screenshot).
            return props(materialClass, baseline: 1.0, amp: 3.2, sun: 5.0, rain: 6.0, snow: 13.0, wind: 4.0, night: 6.0, lo: -10, hi: 14)
        case .glass:
            return props(materialClass, baseline: 0, amp: 2.0, sun: 4.0, rain: 3.0, snow: 4.0, wind: 2.0, night: 4.0, lo: -8, hi: 9)
        case .shadow:
            return props(materialClass, baseline: -3.0, amp: 2.0, sun: 0.5, rain: 3.0, snow: 5.0, wind: 1.5, night: 2.0, lo: -12, hi: 4)
        case .generic:
            return props(materialClass, baseline: 1.0, amp: 2.2, sun: 3.0, rain: 3.0, snow: 5.0, wind: 1.5, night: 2.5, lo: -8, hi: 9)
        }
    }

    /// Apparent temperature for a surface. `variation` ∈ [-1, 1] is a stable per-object/world
    /// spatial term (never time-varying) that scatters surfaces of the same class into soft
    /// patches without flicker.
    static func apparentTemperature(
        for materialClass: ThermalMaterialClass,
        context: ThermalEnvironmentContext,
        variation: Double
    ) -> Double {
        let p = properties(for: materialClass)
        let ambient = context.ambientTemperatureCelsius

        let sun = p.sunHeatingCelsius * context.sunExposure
        let rain = p.rainCoolingCelsius * context.rainIntensity
        let snow = p.snowCoolingCelsius * context.snowIntensity
        let windNorm = min(1.0, context.windSpeedMps / 14.0)
        let wind = p.windCoolingCelsius * windNorm
        let night = context.isNight ? p.nightCoolingCelsius : 0.0
        let spatial = variation * p.variationAmplitudeCelsius

        let raw = p.baselineOffsetCelsius + sun - rain - snow - wind - night + spatial
        let clampedOffset = min(p.maxClampOffsetCelsius, max(p.minClampOffsetCelsius, raw))
        return ambient + clampedOffset
    }

    /// Mean apparent temperature for a class (variation = 0). Used to build the normalization
    /// population without per-instance noise.
    static func meanTemperature(
        for materialClass: ThermalMaterialClass,
        context: ThermalEnvironmentContext
    ) -> Double {
        apparentTemperature(for: materialClass, context: context, variation: 0.0)
    }

    private static func props(
        _ cls: ThermalMaterialClass,
        baseline: Double,
        amp: Double,
        sun: Double,
        rain: Double,
        snow: Double,
        wind: Double,
        night: Double,
        lo: Double,
        hi: Double
    ) -> ThermalMaterialProperties {
        ThermalMaterialProperties(
            materialClass: cls,
            baselineOffsetCelsius: baseline,
            variationAmplitudeCelsius: amp,
            sunHeatingCelsius: sun,
            rainCoolingCelsius: rain,
            snowCoolingCelsius: snow,
            windCoolingCelsius: wind,
            nightCoolingCelsius: night,
            minClampOffsetCelsius: lo,
            maxClampOffsetCelsius: hi
        )
    }
}
