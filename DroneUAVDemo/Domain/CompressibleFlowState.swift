import Foundation
import simd

/// Everything about the air an aircraft is moving through that depends on how fast it
/// is moving through it.
///
/// `AtmosphereState` answers "what is the air like here" — temperature, pressure,
/// density, the speed of sound. It says nothing about the aircraft. This is the other
/// half: Mach number, dynamic pressure, Reynolds number, and the total (stagnation)
/// conditions the flow reaches when it is brought to rest against the airframe.
///
/// It exists as one value rather than as four loose numbers computed in four places
/// because the aerodynamic coefficients, the inlet model, the structural envelope and
/// the skin-temperature model must all be looking at the same instant of the same
/// flow. Dynamic pressure was previously recomputed as a bare `0.5 * rho * v * v` in
/// five separate places; Mach was computed nowhere at all.
///
/// Deliberately a plain value type with no behaviour beyond its own arithmetic: it is
/// produced once per physics substep and read by everything downstream.
struct CompressibleFlowState: Hashable {
    /// The air this flow is moving through.
    let atmosphere: AtmosphereState
    /// True airspeed — the aircraft's speed relative to the air mass, m/s.
    let trueAirspeedMps: Float
    /// Flight Mach number.
    let mach: Float
    /// Dynamic pressure `q = ½ρV²`, Pa. What aerodynamic forces and structural loads
    /// actually scale with, and the quantity a high-speed envelope is written against.
    let dynamicPressurePa: Float
    /// Equivalent airspeed — the speed at sea level that would produce this dynamic
    /// pressure, m/s. The number a structural limit is naturally expressed in, and the
    /// reason "speed" stops being one quantity above the tropopause: an aircraft at
    /// 18 km doing Mach 1.8 has a true airspeed of 530 m/s and an equivalent airspeed
    /// of under 190.
    let equivalentAirspeedMps: Float
    /// Reynolds number per metre of reference length. Multiply by a chord to get the
    /// chord Reynolds number; kept per-metre so one flow state serves surfaces of
    /// different sizes.
    let reynoldsPerMeter: Float
    /// Stagnation temperature — what the flow reaches when brought isentropically to
    /// rest. The physical ceiling on skin temperature, and the first thing the thermal
    /// model needs.
    let totalTemperatureK: Float
    /// Stagnation pressure, Pa. Isentropic, so above Mach 1 it describes the flow
    /// ahead of any shock rather than what an inlet actually recovers — an inlet model
    /// applies its own pressure-recovery factor to this.
    let totalPressurePa: Float

    /// Ratio of specific heats, carried here so consumers do not each reach into
    /// `AtmosphereModel` for it.
    static var gamma: Float { AtmosphereModel.ratioOfSpecificHeats }

    var isSubsonic: Bool { mach < 1.0 }
    var isTransonic: Bool { mach >= 0.8 && mach <= 1.2 }
    var isSupersonic: Bool { mach > 1.0 }

    /// Builds the flow state from ambient air and an air-relative speed.
    ///
    /// `trueAirspeedMps` must be the speed relative to the *air mass* — wind and gusts
    /// already removed. Passing ground speed here would report an aircraft holding
    /// station in a 40 m/s jet stream as flying at zero.
    init(atmosphere: AtmosphereState, trueAirspeedMps: Float) {
        let speed = max(0.0, trueAirspeedMps.isFinite ? trueAirspeedMps : 0.0)
        let gamma = AtmosphereModel.ratioOfSpecificHeats

        self.atmosphere = atmosphere
        self.trueAirspeedMps = speed
        self.mach = atmosphere.machNumber(trueAirspeedMps: speed)
        self.dynamicPressurePa = 0.5 * atmosphere.airDensity * speed * speed
        self.equivalentAirspeedMps = speed * sqrt(
            max(0.0, atmosphere.airDensity) / AtmosphereModel.seaLevelDensity
        )
        self.reynoldsPerMeter = atmosphere.airDensity * speed
            / max(1.0e-9, atmosphere.dynamicViscosityPaS)

        // Isentropic stagnation relations. Valid as written into the low hypersonic
        // range; past Mach 5 the air starts dissociating and gamma stops being 1.4,
        // which is explicitly outside this scope.
        let machSquared = self.mach * self.mach
        let stagnationRatio = 1.0 + 0.5 * (gamma - 1.0) * machSquared
        self.totalTemperatureK = atmosphere.temperatureK * stagnationRatio
        self.totalPressurePa = atmosphere.pressurePa
            * pow(stagnationRatio, gamma / (gamma - 1.0))
    }

    /// Chord (or any other reference length) Reynolds number.
    func reynolds(referenceLengthM: Float) -> Float {
        reynoldsPerMeter * max(0.0, referenceLengthM)
    }

    /// Adiabatic recovery temperature — the equilibrium the skin actually tends to,
    /// which is below the stagnation temperature because a real boundary layer does
    /// not bring the flow fully to rest and does not do it without loss.
    ///
    /// `recoveryFactor` is 0.85 for a turbulent boundary layer (the usual engineering
    /// figure, and what a full-scale airframe at these Reynolds numbers has almost
    /// everywhere) and about 0.89 for a laminar one.
    func recoveryTemperatureK(recoveryFactor: Float = 0.85) -> Float {
        let gamma = AtmosphereModel.ratioOfSpecificHeats
        let factor = recoveryFactor.clampedToUnit()
        return atmosphere.temperatureK
            * (1.0 + factor * 0.5 * (gamma - 1.0) * mach * mach)
    }

    /// Static conditions behind a normal shock, from the Rankine–Hugoniot relations.
    ///
    /// Returned as ratios rather than absolute values so one call answers for pressure,
    /// temperature, density and the downstream Mach number at once. Below Mach 1 there
    /// is no shock and every ratio is 1.
    ///
    /// This is here for inlet models and for diagnostics. It must not be plumbed into
    /// the wing force integration: the coefficient tables already contain whatever the
    /// shocks do to the airframe, and adding this on top would charge the same physics
    /// twice — the same error that the centre-of-mass moment work had to unpick.
    func normalShock() -> (pressureRatio: Float, temperatureRatio: Float, densityRatio: Float, downstreamMach: Float) {
        guard mach > 1.0 else { return (1.0, 1.0, 1.0, mach) }
        let gamma = AtmosphereModel.ratioOfSpecificHeats
        let m2 = mach * mach
        let pressureRatio = (2.0 * gamma * m2 - (gamma - 1.0)) / (gamma + 1.0)
        let densityRatio = ((gamma + 1.0) * m2) / ((gamma - 1.0) * m2 + 2.0)
        let temperatureRatio = pressureRatio / densityRatio
        let downstreamMachSquared = ((gamma - 1.0) * m2 + 2.0)
            / (2.0 * gamma * m2 - (gamma - 1.0))
        return (
            pressureRatio,
            temperatureRatio,
            densityRatio,
            sqrt(max(0.0, downstreamMachSquared))
        )
    }

    /// Total-pressure recovery across a single normal shock, 0...1.
    ///
    /// The simplest possible inlet: a pitot intake swallowing one normal shock. Real
    /// supersonic inlets do much better by staging oblique shocks, but this is the
    /// physical floor and a useful sanity bound on any recovery map — at Mach 3 a
    /// normal shock alone keeps only about a third of the total pressure, which is why
    /// aircraft that fly there have geometry in front of the compressor face.
    var normalShockPressureRecovery: Float {
        guard mach > 1.0 else { return 1.0 }
        let gamma = AtmosphereModel.ratioOfSpecificHeats
        let m2 = mach * mach
        let term1 = pow(
            ((gamma + 1.0) * m2) / ((gamma - 1.0) * m2 + 2.0),
            gamma / (gamma - 1.0)
        )
        let term2 = pow(
            (gamma + 1.0) / (2.0 * gamma * m2 - (gamma - 1.0)),
            1.0 / (gamma - 1.0)
        )
        return (term1 * term2).clampedToUnit()
    }

    static let still = CompressibleFlowState(
        atmosphere: .seaLevelStandard,
        trueAirspeedMps: 0.0
    )
}

private extension Float {
    func clampedToUnit() -> Float {
        Swift.min(1.0, Swift.max(0.0, self))
    }
}
