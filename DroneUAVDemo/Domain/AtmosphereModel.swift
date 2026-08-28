import Foundation

/// Ambient air at one point in the world.
///
/// Replaces the `1.225` literal that every dynamic-pressure calculation in the
/// flight model used to carry. That constant is fine for a survey drone working
/// a few hundred metres over a city, but it silently removes altitude from the
/// aerodynamics entirely — an aircraft at 5,000 m generated exactly as much lift
/// and drag per unit airspeed as one at sea level.
struct AtmosphereState: Hashable {
    /// Geometric altitude above mean sea level this state was evaluated at.
    let altitudeMeters: Float
    let temperatureK: Float
    let pressurePa: Float
    let airDensity: Float
    let speedOfSoundMps: Float
    let dynamicViscosityPaS: Float

    func dynamicPressure(airspeedMps: Float) -> Float {
        0.5 * airDensity * airspeedMps * airspeedMps
    }

    /// Density relative to the standard sea-level value — the term that scales
    /// naturally-aspirated engine power and propeller thrust with altitude.
    var densityRatio: Float {
        airDensity / AtmosphereModel.seaLevelDensity
    }

    var machNumber: Float {
        speedOfSoundMps > 1.0 ? 1.0 / speedOfSoundMps : 0.0
    }

    static let seaLevelStandard = AtmosphereModel.standard.state(altitudeMeters: 0.0)
}

/// International Standard Atmosphere troposphere model, with explicit offsets for
/// a non-standard day.
///
/// Deliberately kept as physics rather than as another weather severity factor:
/// `WeatherModel` decides how bad the weather *feels* (turbulence, drag, visibility),
/// while pressure, temperature and density are computed here from the actual
/// altitude. Weather may bias the ambient temperature, but it never replaces the
/// formula.
struct AtmosphereModel: Hashable {
    static let seaLevelDensity: Float = 1.225
    static let seaLevelPressurePa: Float = 101_325.0
    static let seaLevelTemperatureK: Float = 288.15
    /// ISA troposphere lapse rate, K per metre.
    static let temperatureLapseRateKPerM: Float = 0.0065
    /// Specific gas constant for dry air, J/(kg·K).
    static let gasConstantJPerKgK: Float = 287.052_87
    static let gravityMps2: Float = 9.806_65
    static let ratioOfSpecificHeats: Float = 1.4
    /// Top of the modelled troposphere. Above this the lapse rate stops and the
    /// profile becomes isothermal — no aircraft in this catalogue reaches it, but
    /// clamping keeps the exponent well behaved rather than producing a negative
    /// absolute temperature for an out-of-range altitude.
    static let tropopauseAltitudeMeters: Float = 11_000.0

    /// Difference from the standard day at sea level, K. Positive is hotter, which
    /// thins the air.
    var temperatureOffsetK: Float
    /// Difference from standard sea-level pressure, Pa (a weather system's
    /// high/low, not an altitude effect).
    var pressureOffsetPa: Float
    /// Height of the world origin above mean sea level. The physics engine knows
    /// only `position.y`, which is metres above that origin.
    var siteElevationMeters: Float

    static let standard = AtmosphereModel(
        temperatureOffsetK: 0.0,
        pressureOffsetPa: 0.0,
        siteElevationMeters: 0.0
    )

    init(
        temperatureOffsetK: Float = 0.0,
        pressureOffsetPa: Float = 0.0,
        siteElevationMeters: Float = 0.0
    ) {
        self.temperatureOffsetK = temperatureOffsetK.clamped(to: -40.0...40.0)
        self.pressureOffsetPa = pressureOffsetPa.clamped(to: -6_000.0...6_000.0)
        self.siteElevationMeters = siteElevationMeters
    }

    /// `worldY` is the altitude the physics engine works in — metres above the
    /// world origin, not above sea level.
    func state(worldY: Float) -> AtmosphereState {
        state(altitudeMeters: worldY + siteElevationMeters)
    }

    func state(altitudeMeters: Float) -> AtmosphereState {
        let altitude = altitudeMeters.isFinite ? altitudeMeters : 0.0
        let lapsedAltitude = min(max(altitude, -500.0), Self.tropopauseAltitudeMeters)

        let standardTemperature = Self.seaLevelTemperatureK - Self.temperatureLapseRateKPerM * lapsedAltitude
        // The offset shifts the whole column; pressure still integrates the
        // standard lapse, which is what keeps the model physical rather than
        // letting a "hot day" quietly rewrite the barometric relation.
        let pressureExponent = Self.gravityMps2
            / (Self.temperatureLapseRateKPerM * Self.gasConstantJPerKgK)
        let temperatureRatio = max(0.05, standardTemperature / Self.seaLevelTemperatureK)
        var pressure = Self.seaLevelPressurePa * pow(temperatureRatio, pressureExponent)
        // An isothermal continuation past the tropopause, for completeness.
        if altitude > Self.tropopauseAltitudeMeters {
            let excess = altitude - Self.tropopauseAltitudeMeters
            let scaleHeight = Self.gasConstantJPerKgK * standardTemperature / Self.gravityMps2
            pressure *= exp(-excess / max(1.0, scaleHeight))
        }
        pressure = max(100.0, pressure + pressureOffsetPa)

        let temperature = max(150.0, standardTemperature + temperatureOffsetK)
        let density = pressure / (Self.gasConstantJPerKgK * temperature)
        let speedOfSound = sqrt(Self.ratioOfSpecificHeats * Self.gasConstantJPerKgK * temperature)

        // Sutherland's law — needed the moment aerodynamic coefficients become
        // Reynolds-dependent, and free to compute now.
        let sutherlandConstant: Float = 110.4
        let referenceViscosity: Float = 1.789_4e-5
        let viscosity = referenceViscosity
            * pow(temperature / Self.seaLevelTemperatureK, 1.5)
            * ((Self.seaLevelTemperatureK + sutherlandConstant) / (temperature + sutherlandConstant))

        return AtmosphereState(
            altitudeMeters: altitude,
            temperatureK: temperature,
            pressurePa: pressure,
            airDensity: max(0.02, density),
            speedOfSoundMps: speedOfSound,
            dynamicViscosityPaS: max(1.0e-6, viscosity)
        )
    }

    /// Ambient bias contributed by the active weather. Intentionally modest and
    /// temperature-only: the presets describe visibility and turbulence, not a
    /// pressure system, so inventing a barometric swing from them would be making
    /// up data rather than modelling it.
    static func resolve(weather: WeatherModel, siteElevationMeters: Float = 0.0) -> AtmosphereModel {
        let intensity = weather.normalizedIntensity
        let offset: Float
        switch weather.preset {
        case .normal:
            offset = 0.0
        case .wind:
            offset = -1.0
        case .rain:
            offset = -3.0
        case .snow:
            offset = -14.0
        case .fog:
            offset = -4.0
        case .smog:
            offset = 2.0
        case .thunderstorm:
            offset = -6.0
        }
        return AtmosphereModel(
            temperatureOffsetK: offset * intensity,
            pressureOffsetPa: 0.0,
            siteElevationMeters: siteElevationMeters
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
