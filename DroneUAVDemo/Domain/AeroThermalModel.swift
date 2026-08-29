import Foundation

/// Which part of the airframe a temperature belongs to.
///
/// Four nodes rather than one, because they do not behave alike and the differences are
/// what matter. The nose sits at a stagnation point and sees the whole recovery
/// temperature; the skin is a flat plate in a turbulent boundary layer and sees less;
/// the leading edge is between the two; the intake lip is heated on both faces and is
/// usually the first thing to give.
enum AeroThermalZone: String, Hashable, CaseIterable {
    case nose
    case leadingEdge
    case skin
    case inletLip

    var localizationKey: String { "thermal.zone.\(rawValue)" }

    /// Recovery factor for this zone: how much of the flow's kinetic energy actually
    /// turns into heat at the surface.
    ///
    /// A true stagnation point recovers all of it. A turbulent boundary layer over a
    /// flat plate recovers about 0.89 — the flow near the wall is slowed but never quite
    /// stopped, and what it loses to friction it partly carries away.
    var recoveryFactor: Float {
        switch self {
        case .nose: return 1.00
        case .inletLip: return 0.96
        case .leadingEdge: return 0.92
        case .skin: return 0.85
        }
    }

    /// Multiplier on the convective heat-transfer coefficient. A stagnation region is
    /// scrubbed far harder than a flat panel two metres downstream.
    var convectionFactor: Float {
        switch self {
        case .nose: return 2.6
        case .inletLip: return 2.2
        case .leadingEdge: return 1.8
        case .skin: return 1.0
        }
    }

    /// Characteristic length used for the Reynolds number, as a fraction of the
    /// airframe's own length. A leading edge is thermally short; the skin is not.
    var lengthFraction: Float {
        switch self {
        case .nose: return 0.02
        case .leadingEdge: return 0.05
        case .inletLip: return 0.03
        case .skin: return 0.60
        }
    }

    /// Thermal mass as a fraction of a reference panel mass. A nose cap is a small piece
    /// of structure and heats fast; the skin is most of the airframe and heats slowly.
    /// This is what produces the lag the plan asks for rather than an instantaneous jump
    /// to the recovery temperature.
    var massFraction: Float {
        switch self {
        case .nose: return 0.06
        case .leadingEdge: return 0.10
        case .inletLip: return 0.05
        case .skin: return 1.00
        }
    }
}

/// Temperatures around the airframe.
struct AeroThermalState: Hashable {
    var noseK: Float
    var leadingEdgeK: Float
    var skinK: Float
    var inletLipK: Float
    /// The equilibrium the surfaces are heading towards — the physical ceiling, and the
    /// number that says whether the aircraft is in trouble in a minute or in an hour.
    var recoveryTemperatureK: Float

    var hottestK: Float {
        max(max(noseK, leadingEdgeK), max(skinK, inletLipK))
    }

    func temperature(_ zone: AeroThermalZone) -> Float {
        switch zone {
        case .nose: return noseK
        case .leadingEdge: return leadingEdgeK
        case .skin: return skinK
        case .inletLip: return inletLipK
        }
    }

    static func ambient(_ temperatureK: Float = 288.15) -> AeroThermalState {
        AeroThermalState(
            noseK: temperatureK,
            leadingEdgeK: temperatureK,
            skinK: temperatureK,
            inletLipK: temperatureK,
            recoveryTemperatureK: temperatureK
        )
    }

    static let standard = AeroThermalState.ambient()
}

/// First-order aerodynamic heating.
///
/// Not a stagnation-temperature readout dressed up as a model. The whole point of the
/// plan's requirement is the *lag*: the recovery temperature is where a surface is
/// heading, and how fast it gets there — and whether it arrives before the aircraft
/// slows down again — is what decides whether a Mach 1.5 dash is survivable and a Mach 3
/// cruise is not.
///
/// Three terms per node, each of which is doing real work:
///
///  - **Convection in.** `h·A·(T_recovery − T)`, with `h` from the flat-plate turbulent
///    correlation `Nu = 0.0296·Re^0.8·Pr^(1/3)`. This is why heating grows so steeply
///    with speed: `Re^0.8` on top of a recovery temperature that already grows with M².
///  - **Radiation out.** `εσ(T⁴ − T_ambient⁴)`. Negligible at Mach 1 and the dominant
///    cooling mechanism at Mach 3 — a surface at 600 K radiates thirty times what it
///    does at 300 K, which is most of why sustained high-Mach flight is possible at all.
///  - **Thermal mass.** `m·c·dT/dt`, which is the lag itself.
///
/// Integrated with an implicit step on the convective term so the model cannot overshoot
/// its own equilibrium at large time steps — an explicit step here oscillates and then
/// diverges, and the temperature it diverges to is one that would break the airframe.
struct AeroThermalModel {
    let material: UAVSkinMaterial
    /// Reference airframe length, m. Sets the Reynolds numbers and, with the reference
    /// area, the thermal masses.
    let referenceLengthM: Float
    /// Wetted area used as the reference panel, m².
    let referenceAreaM2: Float
    /// Areal density of the structure, kg/m². A representative skin-plus-stringer figure
    /// rather than a modelled layup.
    let arealDensityKgPerM2: Float

    init(
        material: UAVSkinMaterial,
        referenceLengthM: Float,
        referenceAreaM2: Float,
        arealDensityKgPerM2: Float = 8.0
    ) {
        self.material = material
        self.referenceLengthM = max(0.2, referenceLengthM)
        self.referenceAreaM2 = max(0.05, referenceAreaM2)
        self.arealDensityKgPerM2 = max(0.5, arealDensityKgPerM2)
    }

    private static let stefanBoltzmann: Float = 5.670_374_4e-8
    private static let airSpecificHeatJPerKgK: Float = 1_005.0
    private static let airPrandtl: Float = 0.71

    func advance(
        state: AeroThermalState,
        flow: CompressibleFlowState,
        deltaTime: Float
    ) -> AeroThermalState {
        let dt = max(0.0, deltaTime)
        let ambient = flow.atmosphere.temperatureK
        guard dt > 0.0 else { return state }

        // Thermal conductivity of air from its viscosity, via the Prandtl number. Saves
        // carrying a second temperature-dependent property that would have to agree with
        // the first one.
        let conductivity = flow.atmosphere.dynamicViscosityPaS
            * Self.airSpecificHeatJPerKgK / Self.airPrandtl

        func advanceZone(_ zone: AeroThermalZone, current: Float) -> Float {
            let length = max(0.01, referenceLengthM * zone.lengthFraction)
            let reynolds = max(1.0e3, flow.reynolds(referenceLengthM: length))
            let nusselt = 0.0296 * pow(reynolds, 0.8) * pow(Self.airPrandtl, 1.0 / 3.0)
            let convection = max(
                1.0,
                nusselt * conductivity / length * zone.convectionFactor
            )
            let recovery = flow.recoveryTemperatureK(recoveryFactor: zone.recoveryFactor)

            let area = referenceAreaM2 * max(0.02, zone.massFraction)
            let mass = area * arealDensityKgPerM2
            let capacity = max(1.0, mass * material.specificHeatJPerKgK)

            // Radiation is linearised about the current temperature so it can join the
            // implicit convective step. Over one physics tick the error is negligible and
            // it keeps the whole update unconditionally stable.
            let radiationSlope = 4.0 * material.emissivity * Self.stefanBoltzmann
                * current * current * current
            let radiationOffset = material.emissivity * Self.stefanBoltzmann
                * (pow(ambient, 4.0) + 3.0 * pow(current, 4.0))

            // dT/dt = [h·(T_r − T) − (kR·T − cR)] · A / (m·c)
            let gain = (convection + radiationSlope) * area / capacity
            let drive = (convection * recovery + radiationOffset) * area / capacity
            let equilibrium = drive / max(1.0e-6, gain)
            // Implicit (backward Euler) step toward the equilibrium: cannot overshoot,
            // whatever the time step.
            let blend = 1.0 - exp(-gain * dt)
            let next = current + (equilibrium - current) * blend
            return next.isFinite ? max(ambient - 5.0, next) : current
        }

        return AeroThermalState(
            noseK: advanceZone(.nose, current: state.noseK),
            leadingEdgeK: advanceZone(.leadingEdge, current: state.leadingEdgeK),
            skinK: advanceZone(.skin, current: state.skinK),
            inletLipK: advanceZone(.inletLip, current: state.inletLipK),
            recoveryTemperatureK: flow.recoveryTemperatureK()
        )
    }

    /// How much of its strength the structure has lost to heat, 0 = none, 1 = all of it.
    ///
    /// Zero until the working limit is reached and then rising, rather than a gradual
    /// derate from cold: metals hold their properties almost unchanged until they do not.
    /// Fed to the structural model as a multiplier on residual strength, so an aircraft
    /// held above its thermal limit fails at loads it would have carried cold — which is
    /// how heat actually destroys an airframe, rather than by melting it.
    func thermalWeakening(state: AeroThermalState, limits: FlightEnvelopeLimits) -> Float {
        let hottest = state.hottestK
        let limit = limits.maxSkinTemperatureK
        guard hottest > limit else { return 0.0 }
        // Fully weakened 250 K past the working limit.
        return min(1.0, (hottest - limit) / 250.0)
    }
}
