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

    /// Flight Mach number at a given true airspeed.
    ///
    /// Was a computed property returning `1.0 / speedOfSoundMps` — the Mach number
    /// of an aircraft doing one metre per second, which is nobody. Nothing read it,
    /// so the error never surfaced; it is a function now because Mach describes the
    /// *aircraft's* motion through this air, not a property of the air itself.
    func machNumber(trueAirspeedMps: Float) -> Float {
        speedOfSoundMps > 1.0 ? max(0.0, trueAirspeedMps) / speedOfSoundMps : 0.0
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
    /// Effective Earth radius used by the ISA to convert geometric altitude to the
    /// geopotential altitude its layer definitions are written against, m.
    static let earthRadiusMeters: Float = 6_356_766.0
    static let ratioOfSpecificHeats: Float = 1.4
    /// Top of the modelled troposphere. Above this the lapse rate stops and the
    /// profile becomes isothermal.
    static let tropopauseAltitudeMeters: Float = 11_000.0
    /// Top of the isothermal lower stratosphere. Above it the ISA temperature climbs
    /// again as ozone absorbs solar ultraviolet, and a model that keeps extending the
    /// 216.65 K isotherm upward reports air that is steadily too cold, too dense and
    /// too slow-sounding — which lands directly on the Mach number of anything flying
    /// there. Below 20 km this constant changes nothing: the layer above is only
    /// evaluated when the aircraft is actually in it.
    static let stratosphereInversionAltitudeMeters: Float = 20_000.0
    /// Top of the modelled column. Every reference aircraft in the supersonic scope
    /// works below 22 km; past 32 km the single-gas ISA relations stop being the
    /// right model at all, so the profile is clamped rather than extrapolated.
    static let modelCeilingAltitudeMeters: Float = 32_000.0
    /// ISA temperature gradient in the 20–32 km layer, K per metre. Positive, and
    /// deliberately not expressed as a negative `temperatureLapseRateKPerM`: the sign
    /// convention on the tropospheric constant is "temperature falls by this much",
    /// and reusing it for a warming layer is exactly how a sign error gets written.
    static let stratosphereWarmingRateKPerM: Float = 0.001

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
        let geometric = min(max(altitude, -500.0), Self.modelCeilingAltitudeMeters)
        // The ISA layer boundaries and lapse rates are defined against *geopotential*
        // altitude, which folds the weakening of gravity with height into the height
        // itself. Feeding geometric altitude straight in is what the model used to do,
        // and below the tropopause the difference is small enough to disappear into
        // the tuning: 0.02 % of density at 1 km, 0.2 % at 11 km. It is not small where
        // the supersonic scope lives — at 25 km it is a hundred metres of altitude and
        // 1.5 % of pressure — so the conversion is applied over the whole column
        // rather than only above 20 km, which would put a kink in the middle of it.
        let column = Self.earthRadiusMeters * geometric / (Self.earthRadiusMeters + geometric)
        let lapsedAltitude = min(column, Self.tropopauseAltitudeMeters)

        // --- Layer 0: troposphere, up to 11 km.
        let tropopauseTemperature = Self.seaLevelTemperatureK - Self.temperatureLapseRateKPerM * lapsedAltitude
        var standardTemperature = tropopauseTemperature
        // The offset shifts the whole column; pressure still integrates the
        // standard lapse, which is what keeps the model physical rather than
        // letting a "hot day" quietly rewrite the barometric relation.
        let pressureExponent = Self.gravityMps2
            / (Self.temperatureLapseRateKPerM * Self.gasConstantJPerKgK)
        let temperatureRatio = max(0.05, tropopauseTemperature / Self.seaLevelTemperatureK)
        var pressure = Self.seaLevelPressurePa * pow(temperatureRatio, pressureExponent)

        // --- Layer 1: isothermal lower stratosphere, 11 km to 20 km.
        if column > Self.tropopauseAltitudeMeters {
            let excess = min(column, Self.stratosphereInversionAltitudeMeters)
                - Self.tropopauseAltitudeMeters
            let scaleHeight = Self.gasConstantJPerKgK * tropopauseTemperature / Self.gravityMps2
            pressure *= exp(-excess / max(1.0, scaleHeight))
        }

        // --- Layer 2: warming stratosphere, 20 km to 32 km.
        //
        // The reference aircraft that need this are real: the AQM-35B's published
        // ceiling is 21,300 m and the Firebee II's supersonic dash sits at 13,700 m
        // on the way there. Held isothermal, the air at 21 km comes out about 5 K
        // colder than standard — a one-per-cent error in the speed of sound, which is
        // a one-per-cent error in every Mach number the aircraft reports at exactly
        // the altitude the whole scope is about.
        if column > Self.stratosphereInversionAltitudeMeters {
            let excess = column - Self.stratosphereInversionAltitudeMeters
            let layerTopTemperature = tropopauseTemperature
                + Self.stratosphereWarmingRateKPerM * excess
            let exponent = -Self.gravityMps2
                / (Self.stratosphereWarmingRateKPerM * Self.gasConstantJPerKgK)
            pressure *= pow(layerTopTemperature / tropopauseTemperature, exponent)
            standardTemperature = layerTopTemperature
        }

        // The weather anomaly is a *sea-level* pressure difference. Added unchanged at
        // altitude it would be nonsense — the whole column at 25 km is about 2.5 kPa
        // against a clamp of ±6 kPa, so a "low" could drive the pressure negative.
        // Carried up as a fraction of the local pressure instead. Every weather preset
        // supplies zero today, so this is identical to the previous arithmetic for
        // every case the simulation actually produces.
        let pressureAnomalyFraction = pressureOffsetPa / Self.seaLevelPressurePa
        pressure = max(1.0, pressure * (1.0 + pressureAnomalyFraction))

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
            // Floor lowered from 0.02 to 0.001 kg/m³ when the column was extended past
            // 20 km. Standard density at 30 km is 0.0184, so the old floor silently
            // clamped — an aircraft climbing through 30 km would have stopped losing
            // lift and drag exactly where it should have been losing them fastest.
            // 0.001 corresponds to roughly 48 km, well outside the modelled column.
            airDensity: max(0.001, density),
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
