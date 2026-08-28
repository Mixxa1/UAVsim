import Foundation

/// Fixed-pitch propeller in proper non-dimensional form.
///
/// Replaces, for fuel aircraft, the calibrated thrust that `wingborneThrustMagnitude`
/// derives from the airframe's own weight. That backend cannot express the two
/// things a real propeller does: thrust falls as the aircraft speeds up toward the
/// disc's own pitch, and it falls with density. It also made burning fuel pointless,
/// because shedding weight removed the thrust that had been derived from it.
///
/// The coefficients are not invented per airframe. Each propeller is *self-calibrated*
/// from numbers the catalogue already holds — rated shaft power, rated shaft speed,
/// diameter and cruise speed — so that at its design point the disc absorbs exactly
/// the power its engine produces. That is a real constraint, not a fitted curve:
/// get the diameter or the shaft speed wrong and the aircraft will not fly.
struct PropellerModel: Hashable {
    let diameterM: Float
    let bladeCount: Int
    /// Advance ratio the disc is pitched for, J = V / (n·D) at the design point.
    let designAdvanceRatio: Float
    /// Power coefficient at the design point, from the engine/disc power balance.
    let designPowerCoefficient: Float
    /// Advance ratio at which the blade stops producing thrust — effectively the
    /// disc's geometric pitch expressed as a ratio.
    let zeroThrustAdvanceRatio: Float
    let isPusher: Bool
    /// Constant-speed (variable-pitch) disc.
    ///
    /// A fixed-pitch propeller is pitched for one advance ratio and loses badly
    /// either side of it — that off-design loss is real and is why a small UAV
    /// climbs worse than its installed power suggests. A constant-speed disc holds
    /// its shaft speed and changes blade angle instead, so it stays near its best
    /// efficiency across the whole useful range. Every turboprop in this catalogue
    /// has one; modelling the MQ-9A's as fixed-pitch cost it half its climb, purely
    /// because it climbs at 62 m/s and cruises at 87.
    let isConstantSpeed: Bool
    /// Fraction of shaft power a governed disc delivers to the slipstream, after
    /// blade profile drag, tip loss and swirl.
    ///
    /// Not propulsive efficiency, and not a tuned number: it is solved at build
    /// time so that momentum theory reproduces `designEfficiency` at the design
    /// point, exactly as `designThrustCoefficient` does for a fixed-pitch disc.
    /// One anchor for both kinds of propeller, so a governed disc cannot quietly
    /// drift away from the figure the rest of the model is calibrated on.
    let discTransmissionEfficiency: Float

    /// Builds the propeller from the powerplant's own published figures.
    ///
    /// `cruiseSpeedMps` sets the design advance ratio: a propeller is pitched for
    /// the speed its aircraft actually cruises at, which is why a 2.3 m turboprop
    /// disc turning at 1,591 rpm and a 0.46 m two-stroke disc at 5,500 rpm end up
    /// with such different coefficients.
    static func resolve(
        powerplant: UAVPowerplantSpec,
        cruiseSpeedMps: Float,
        referenceDensity: Float = AtmosphereModel.seaLevelDensity
    ) -> PropellerModel? {
        guard powerplant.drivesPropeller,
              let diameter = powerplant.propellerDiameterM, diameter > 0.02,
              let ratedRPM = powerplant.ratedShaftRPM, ratedRPM > 1.0,
              let ratedPowerKW = powerplant.ratedShaftPowerKW, ratedPowerKW > 0.001 else {
            return nil
        }

        let revsPerSecond = ratedRPM / 60.0
        // Design advance ratio, floored so a very slow aircraft still gets a
        // sensible curve rather than a degenerate one at J = 0.
        let designJ = max(0.12, cruiseSpeedMps / (revsPerSecond * diameter))
        // Power balance at the design point: P = Cp · rho · n^3 · D^5.
        let denominator = referenceDensity
            * pow(revsPerSecond, 3.0)
            * pow(diameter, 5.0)
        let designCp = ((ratedPowerKW * 1000.0) / max(1.0e-6, denominator))
            .clamped(to: 0.008...0.85)
        // A fixed-pitch disc stops pulling at roughly its geometric pitch ratio,
        // which sits well above the advance ratio it is designed to cruise at —
        // a design point at ~70 % of zero-thrust J is typical. 1.22 was too tight:
        // it put zero thrust barely above cruise, so any overspeed flipped the disc
        // into braking and the aircraft settled into a descent it could not leave.
        let zeroThrustJ = designJ * 1.45

        // Disc transmission efficiency, back-solved from the design point so a
        // governed disc lands on the same `designEfficiency` anchor a fixed-pitch
        // one does. At cruise the disc must make `T = eta·P/V`; momentum theory
        // then fixes the induced velocity, and what is left over is the fraction of
        // shaft power that never reached the air.
        let discArea = Float.pi * diameter * diameter * 0.25
        let designSpeed = max(1.0, cruiseSpeedMps)
        let designThrust = designEfficiency * (ratedPowerKW * 1000.0) / designSpeed
        let inducedAtDesign = 0.5 * (
            -designSpeed
                + (designSpeed * designSpeed
                    + 2.0 * designThrust / max(1.0e-4, referenceDensity * discArea)).squareRoot()
        )
        let discEfficiency = (designThrust * (designSpeed + inducedAtDesign)
            / max(1.0, ratedPowerKW * 1000.0)).clamped(to: 0.45...0.95)

        return PropellerModel(
            diameterM: diameter,
            bladeCount: powerplant.propellerBladeCount,
            designAdvanceRatio: designJ,
            designPowerCoefficient: designCp,
            zeroThrustAdvanceRatio: zeroThrustJ,
            isPusher: powerplant.propellerPlacement == .pusher,
            isConstantSpeed: powerplant.hasConstantSpeedPropeller,
            discTransmissionEfficiency: discEfficiency
        )
    }

    /// Swept area of the disc, m².
    var discAreaM2: Float {
        Float.pi * diameterM * diameterM * 0.25
    }

    func advanceRatio(airspeedMps: Float, shaftRPM: Float) -> Float {
        let revsPerSecond = shaftRPM / 60.0
        guard revsPerSecond > 0.05 else { return 0.0 }
        return max(0.0, airspeedMps) / (revsPerSecond * diameterM)
    }

    /// Propulsive efficiency the disc is designed to reach at its design advance
    /// ratio. A well-matched fixed-pitch propeller peaks around here.
    static let designEfficiency: Float = 0.78

    /// Thrust coefficient at the design point, from the definition of propulsive
    /// efficiency: `eta = Ct·J / Cp`.
    ///
    /// This is the anchor, and getting it wrong is subtle. Anchoring the curve on
    /// *static* thrust instead — the obvious-looking choice — silently set the
    /// efficiency at the design point to whatever the curve shape happened to
    /// produce. Measured, that was 0.23 to 0.30, so an MQ-9A's 671 kW came out as
    /// 1,785 N of thrust against 4,091 N of drag and the aircraft could not fly.
    /// Anchoring here instead makes the design point mean what it says and lets
    /// static thrust be the derived quantity.
    var designThrustCoefficient: Float {
        (Self.designEfficiency * designPowerCoefficient / max(0.05, designAdvanceRatio))
            .clamped(to: 0.01...0.42)
    }

    /// Ratio of static thrust to design-point thrust.
    ///
    /// A coarse propeller is a poor static thruster: pitched for a high advance
    /// ratio, its blades are deeply stalled when the aircraft is not moving, so the
    /// thrust it makes standing still is barely above what it makes at its design
    /// point. A fine disc on a slow aircraft keeps far more.
    ///
    /// Extrapolating the design-point line straight back to J = 0 instead — the
    /// obvious thing to do — ignores that stall entirely and multiplies by
    /// `1/(1 - J_design/J_zero)`, which is 3.2 for a coarse disc. Measured on the
    /// MQ-9A that produced 19 kN of static thrust, a thrust-to-weight of 0.49 for
    /// an aircraft whose real figure is near 0.20, and enough propeller torque to
    /// roll it over during its ground roll.
    var staticToDesignThrustRatio: Float {
        (2.2 - 0.6 * designAdvanceRatio).clamped(to: 1.05...2.2)
    }

    /// Thrust coefficient. Highest static, through the design point, to zero at the
    /// disc's own pitch ratio, and negative past it — which is what makes a
    /// windmilling propeller a brake rather than a neutral disc.
    func thrustCoefficient(advanceRatio: Float) -> Float {
        let designCt = designThrustCoefficient
        if advanceRatio <= designAdvanceRatio {
            // Between standing still and the design point the blade is coming out
            // of stall; interpolate from the static value.
            let staticCt = designCt * staticToDesignThrustRatio
            let t = (advanceRatio / max(0.02, designAdvanceRatio)).clamped(to: 0.0...1.0)
            return staticCt + (designCt - staticCt) * t
        }
        // Past the design point the disc unloads linearly to zero thrust.
        let span = max(0.02, zeroThrustAdvanceRatio - designAdvanceRatio)
        let beyond = (advanceRatio - designAdvanceRatio) / span
        if beyond <= 1.0 {
            return designCt * (1.0 - beyond)
        }
        return -designCt * min(0.6, (beyond - 1.0) * 0.9)
    }

    /// Static thrust, N — what the disc pulls standing still. Derived from the
    /// curve rather than assumed, and the figure a catapult or ground roll depends on.
    func staticThrustNewtons(shaftRPM: Float, shaftPowerW: Float, airDensity: Float) -> Float {
        thrustNewtons(
            airspeedMps: 0.0,
            shaftRPM: shaftRPM,
            shaftPowerW: shaftPowerW,
            airDensity: airDensity
        )
    }

    /// Power coefficient. Falls away as the disc unloads at high advance ratio.
    func powerCoefficient(advanceRatio: Float) -> Float {
        let normalized = advanceRatio / max(0.05, zeroThrustAdvanceRatio)
        let shape = (1.0 - 0.35 * normalized * normalized).clamped(to: 0.25...1.15)
        return designPowerCoefficient * shape
    }

    /// T = Ct · rho · n² · D⁴.
    ///
    /// A constant-speed disc is solved the other way round — from the power it is
    /// absorbing, `T = eta · P / V` — because that is what holding the design blade
    /// angle *means*: the pitch changes to keep the disc efficient, so thrust
    /// follows power and airspeed rather than a fixed-geometry coefficient curve.
    /// It is still bounded by the static thrust the blades can physically make.
    func thrustNewtons(
        airspeedMps: Float,
        shaftRPM: Float,
        shaftPowerW: Float,
        airDensity: Float
    ) -> Float {
        if isConstantSpeed {
            // A governed disc is solved from momentum theory, not from the Ct/Cp
            // curve — see `constantSpeedThrustNewtons`. Shaft speed does not enter
            // it at all, which is exactly the point: the governor holds that speed
            // and changes blade angle instead, so the disc absorbs whatever the
            // engine delivers and the coefficient curve has nothing to say.
            return constantSpeedThrustNewtons(
                airspeedMps: airspeedMps,
                shaftPowerW: shaftPowerW,
                airDensity: airDensity
            )
        }

        let revsPerSecond = shaftRPM / 60.0
        guard revsPerSecond > 0.05 else { return 0.0 }
        let j = advanceRatio(airspeedMps: airspeedMps, shaftRPM: shaftRPM)
        return thrustCoefficient(advanceRatio: j)
            * airDensity
            * revsPerSecond * revsPerSecond
            * pow(diameterM, 4.0)
    }

    /// Thrust of a constant-speed disc absorbing `shaftPowerW`, from momentum
    /// theory: `T = 2·rho·A·(V + v)·v` with the induced velocity `v` solved from
    /// `2·rho·A·v·(V + v)² = eta·P`.
    ///
    /// This replaces `T = eta·P/V`, which is the same statement written for cruise
    /// and which diverges at the one place a takeoff actually needs it — standing
    /// still. Patching that with an efficiency ramp (efficiency rising linearly
    /// from zero with advance ratio, capped by an extrapolated static ceiling) put
    /// the MQ-9A's thrust near zero for the first seconds of its ground roll.
    /// Momentum theory needs no patch: at V = 0 it reduces to the classical
    /// `T = (2·rho·A)^(1/3)·(eta·P)^(2/3)`, and it reproduces `eta·P/V` to within a
    /// few per cent at cruise, so nothing about the design point moves.
    ///
    /// `eta` here is *not* propulsive efficiency — momentum theory already accounts
    /// for that. It is `discTransmissionEfficiency`, the fraction of shaft power
    /// that reaches the air at all, back-solved from the design point.
    func constantSpeedThrustNewtons(
        airspeedMps: Float,
        shaftPowerW: Float,
        airDensity: Float
    ) -> Float {
        let usefulPower = max(0.0, shaftPowerW) * discTransmissionEfficiency
        guard usefulPower > 1.0, airDensity > 0.001 else { return 0.0 }
        let speed = max(0.0, airspeedMps)
        let discConstant = 2.0 * airDensity * discAreaM2

        // Static solution is exact and also the right first guess for the iteration.
        var induced = pow(usefulPower / discConstant, 1.0 / 3.0)
        guard speed > 0.05 else { return discConstant * induced * induced }

        // f(v) = discConstant·v·(V + v)² − usefulPower, monotonically increasing in
        // v, so a handful of Newton steps from the static solution converge hard.
        for _ in 0..<6 {
            let sum = speed + induced
            let value = discConstant * induced * sum * sum - usefulPower
            let derivative = discConstant * (sum * sum + 2.0 * induced * sum)
            guard derivative > 1.0e-6 else { break }
            induced = max(0.0, induced - value / derivative)
        }
        return discConstant * (speed + induced) * induced
    }

    /// P = Cp · rho · n³ · D⁵ — the power the disc demands of the shaft.
    func absorbedPowerWatts(airspeedMps: Float, shaftRPM: Float, airDensity: Float) -> Float {
        let revsPerSecond = shaftRPM / 60.0
        guard revsPerSecond > 0.05 else { return 0.0 }
        let j = advanceRatio(airspeedMps: airspeedMps, shaftRPM: shaftRPM)
        return powerCoefficient(advanceRatio: j)
            * airDensity
            * pow(revsPerSecond, 3.0)
            * pow(diameterM, 5.0)
    }

    /// Drag of a stopped or windmilling disc, N. A dead engine is not a clean
    /// airframe: the disc keeps turning in the flow and costs real drag, which is
    /// the difference between gliding to a field and arriving short of one.
    func windmillingDragNewtons(airspeedMps: Float, airDensity: Float) -> Float {
        guard airspeedMps > 0.5 else { return 0.0 }
        let discArea = Float.pi * diameterM * diameterM * 0.25
        // Equivalent flat-plate fraction of the disc. A freely windmilling
        // fixed-pitch propeller sits around 0.10-0.16 of its disc area.
        let dragCoefficient: Float = 0.13
        return 0.5 * airDensity * airspeedMps * airspeedMps * discArea * dragCoefficient
    }

    /// Propulsive efficiency at this operating point, for telemetry.
    func efficiency(advanceRatio: Float) -> Float {
        let cp = powerCoefficient(advanceRatio: advanceRatio)
        guard cp > 1.0e-5 else { return 0.0 }
        return (thrustCoefficient(advanceRatio: advanceRatio) * advanceRatio / cp)
            .clamped(to: 0.0...0.95)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
