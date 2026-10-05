import Foundation
import simd

/// The single temperature model shared by every palette and by the diagnostics probe.
///
/// Surfaces respond to directional sunlight, thermal inertia and weather. Apparent temperature
/// additionally includes material emissivity, reflected surroundings and atmospheric attenuation.
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
            return props(materialClass, baseline: 1.5, amp: 1.2, sun: 12.0, rain: 3.0, snow: 5.0, wind: 1.0, night: 2.0, lo: -7, hi: 18)
        case .roof:
            return props(materialClass, baseline: 2.0, amp: 1.8, sun: 20.0, rain: 5.0, snow: 7.0, wind: 2.0, night: 4.0, lo: -7, hi: 25)
        case .concrete:
            return props(materialClass, baseline: 3.0, amp: 2.4, sun: 6.0, rain: 4.0, snow: 6.0, wind: 1.0, night: 4.0, lo: -7, hi: 13)
        case .metal:
            // Thin painted panels respond quickly to wind and precipitation.
            return props(materialClass, baseline: 1.0, amp: 3.2, sun: 5.0, rain: 6.0, snow: 13.0, wind: 4.0, night: 6.0, lo: -10, hi: 14)
        case .glass:
            return props(materialClass, baseline: 0, amp: 2.0, sun: 4.0, rain: 3.0, snow: 4.0, wind: 2.0, night: 4.0, lo: -8, hi: 9)
        case .shadow:
            return props(materialClass, baseline: -3.0, amp: 2.0, sun: 0.5, rain: 3.0, snow: 5.0, wind: 1.5, night: 2.0, lo: -12, hi: 4)
        case .generic:
            return props(materialClass, baseline: 1.0, amp: 2.2, sun: 3.0, rain: 3.0, snow: 5.0, wind: 1.5, night: 2.5, lo: -8, hi: 9)
        case .body:
            // SurfaceResponse supplies the ambient-independent temperature of a living target.
            return props(materialClass, baseline: 16.0, amp: 1.0, sun: 0.5, rain: 1.0, snow: 1.0, wind: 0.5, night: 1.0, lo: 10, hi: 18)
        }
    }

    /// Representative surface temperature without spatial variation or reflected radiance.
    static func meanTemperature(
        for materialClass: ThermalMaterialClass,
        context: ThermalEnvironmentContext
    ) -> Double {
        if materialClass == .sky { return skyTemperature(context: context) }
        let normal: SIMD3<Double> = [.building, .glass, .metal].contains(materialClass)
            ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        return surfaceTemperature(for: materialClass, context: context, normal: normal)
    }

    /// Passive surface response. The three solar terms approximate a material's thermal inertia
    /// with current, two-hour-old and four-hour-old irradiance. They are deterministic at a given
    /// world time, including when a replay seeks backwards. Weather history is not available.
    struct SurfaceResponse: Equatable {
        var baseCelsius: Double
        var solar: SIMD3<Double>
        var emissivity: Double
        var diffuseFraction: Double
    }

    static func surfaceResponse(for cls: ThermalMaterialClass,
                                context: ThermalEnvironmentContext) -> SurfaceResponse {
        let p = properties(for: cls)
        let night = 1 - WorldClock(startHour: context.timeOfDayHours).sunIntensityMultiplier
        var base = cls == .body ? 31 - 1.5 * night - 2 * context.rainIntensity
            : context.ambientTemperatureCelsius + p.baselineOffsetCelsius
                - p.rainCoolingCelsius * context.rainIntensity
                - p.snowCoolingCelsius * context.snowIntensity
                - p.windCoolingCelsius * min(1, context.windSpeedMps / 14)
                - p.nightCoolingCelsius * night
        // Modest interior coupling for cold building envelopes. Occupancy is not simulated.
        if cls == .glass { base += max(0, 20 - context.ambientTemperatureCelsius) * 0.25 }
        if cls == .building { base += max(0, 20 - context.ambientTemperatureCelsius) * 0.12 }
        let inertia: SIMD3<Double>
        let emissivity: Double
        let diffuse: Double
        switch cls {
        case .glass: inertia = SIMD3(0.85, 0.12, 0.03); emissivity = 0.92; diffuse = 0.03
        // Most simulator metal assets are painted, rather than polished bare metal.
        case .metal: inertia = SIMD3(0.85, 0.12, 0.03); emissivity = 0.80; diffuse = 0.35
        case .building, .concrete, .rock:
            inertia = SIMD3(0.35, 0.40, 0.25); emissivity = 0.93; diffuse = 0.90
        case .roof, .road, .asphalt:
            inertia = SIMD3(0.55, 0.30, 0.15); emissivity = 0.95; diffuse = 0.88
        case .water, .ice: inertia = SIMD3(0.20, 0.40, 0.40); emissivity = 0.97; diffuse = 0.12
        case .body: inertia = .zero; emissivity = 0.98; diffuse = 0.95
        default: inertia = SIMD3(0.70, 0.23, 0.07); emissivity = 0.96; diffuse = 0.90
        }
        let weatherGain = max(0, 1 - context.cloudiness) * (1 - 0.65 * context.groundWetness)
            * (1 - 0.45 * context.snowCoverage) / (1 + context.windSpeedMps / 22)
        // sunExposure can explicitly suppress the current sun (e.g. in probes/legacy contexts).
        let currentGain = min(weatherGain, max(0, context.sunExposure))
        let energies = SIMD3(solarEnergy(at: context.timeOfDayHours) * currentGain,
                             solarEnergy(at: context.timeOfDayHours - 2) * weatherGain,
                             solarEnergy(at: context.timeOfDayHours - 4) * weatherGain)
        return SurfaceResponse(baseCelsius: base, solar: inertia * energies * p.sunHeatingCelsius,
                               emissivity: emissivity, diffuseFraction: diffuse)
    }

    static func sunDirection(at hour: Double) -> SIMD3<Double> {
        let clock = WorldClock(startHour: hour)
        let elevation = clock.sunElevationDegrees * .pi / 180
        let azimuth = clock.sunAzimuthDegrees * .pi / 180
        // Matches the directional lamp's Euler transform in DroneSceneController. Using the
        // same world basis avoids heating the opposite side from the visible sunlight.
        return SIMD3(sin(azimuth) * sin(elevation), cos(elevation), cos(azimuth) * sin(elevation))
    }

    private static func solarEnergy(at hour: Double) -> Double {
        let elevation = WorldClock(startHour: hour).sunElevationDegrees * .pi / 180
        return max(0, sin(elevation))
    }

    static func surfaceTemperature(for cls: ThermalMaterialClass, context: ThermalEnvironmentContext,
                                   normal: SIMD3<Double>, variation: Double = 0) -> Double {
        let response = surfaceResponse(for: cls, context: context)
        let incidence = SIMD3(max(0, simd_dot(normal, sunDirection(at: context.timeOfDayHours))),
                              max(0, simd_dot(normal, sunDirection(at: context.timeOfDayHours - 2))),
                              max(0, simd_dot(normal, sunDirection(at: context.timeOfDayHours - 4))))
        return response.baseCelsius + simd_dot(response.solar, incidence)
            + variation * properties(for: cls).variationAmplitudeCelsius
    }

    /// Brightness temperature from emitted + reflected radiance, approximated at 10 µm in LWIR.
    /// This is a rendering model, not a calibrated radiometric instrument or a heat-flow solver.
    static func radiance(_ celsius: Double) -> Double {
        1 / expm1(1438.8 / max(100, celsius + 273.15))
    }

    static func brightnessTemperature(radiance: Double) -> Double {
        1438.8 / log1p(1 / max(0.000001, radiance)) - 273.15
    }

    static func apparentSurfaceTemperature(for cls: ThermalMaterialClass,
                                          context: ThermalEnvironmentContext,
                                          normal: SIMD3<Double>, view: SIMD3<Double>,
                                          distance: Double = 0) -> Double {
        let response = surfaceResponse(for: cls, context: context)
        let actual = surfaceTemperature(for: cls, context: context, normal: normal)
        let cosView = min(1, abs(simd_dot(normal, view)))
        let epsilon = response.emissivity * (1 - (1 - response.diffuseFraction) * pow(1 - cosView, 5))
        let reflected = 2 * simd_dot(normal, view) * normal - view
        let skyFraction = max(0, min(1, (reflected.y + 0.05) / 0.65))
        let sky = skyTemperature(context: context)
        let surroundings = context.ambientTemperatureCelsius + 2
        let specularRadiance = radiance(surroundings) * (1 - skyFraction) + radiance(sky) * skyFraction
        let diffuseRadiance = radiance(surroundings) * 0.75 + radiance(sky) * 0.25
        let reflection = specularRadiance * (1 - response.diffuseFraction)
            + diffuseRadiance * response.diffuseFraction
        let transmission = exp(-max(0, distance) * atmosphericExtinction(context: context))
        let received = transmission * (epsilon * radiance(actual) + (1 - epsilon) * reflection)
            + (1 - transmission) * radiance(context.ambientTemperatureCelsius)
        return brightnessTemperature(radiance: received)
    }

    static func skyTemperature(context: ThermalEnvironmentContext) -> Double {
        // Clouds are much warmer in LWIR than clear zenith sky.
        context.ambientTemperatureCelsius - 32 + 26 * context.cloudiness
    }

    static func atmosphericExtinction(context: ThermalEnvironmentContext) -> Double {
        0.000025 + context.fogDensity * 0.0012 + context.rainIntensity * 0.00035
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
