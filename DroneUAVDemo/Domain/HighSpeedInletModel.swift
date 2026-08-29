import Foundation

/// How much of the free stream's total pressure actually reaches the engine.
///
/// Below Mach 1 this is a detail — a well-shaped intake keeps 97–98 % of it and nobody
/// has to think about the difference. Above Mach 1 it becomes one of the two or three
/// numbers that decide what an aircraft can do, because the air has to be shocked down
/// to subsonic speed before it can enter a compressor, and every shock costs total
/// pressure irreversibly. Thrust scales almost directly with what survives.
///
/// Deliberately map-based rather than geometric. Building the actual shock structure of
/// a ramp intake at each flight condition is a solver, not a simulation tick, and the
/// plan says so explicitly: use recovery coefficients and maps, not a geometric
/// calculation of every shock interaction. What is modelled is the thing that shows up
/// in flight — that a plain hole runs out of usefulness around Mach 1.6, that a fixed
/// ramp is excellent at one Mach and mediocre away from it, and that only a variable
/// ramp holds good recovery across a wide range.
struct HighSpeedInletModel: Hashable {
    let type: UAVInletType
    /// Free-stream Mach the intake geometry is cut for. Ignored by a pitot intake,
    /// which has no geometry to schedule.
    let designMach: Float

    init(type: UAVInletType, designMach: Float = 2.0) {
        self.type = type
        self.designMach = max(1.0, designMach)
    }

    init(powerplant: UAVPowerplantSpec) {
        self.init(type: powerplant.inletType, designMach: powerplant.inletDesignMach)
    }

    /// Subsonic duct loss. Small, real, and the same for every arrangement — this is
    /// friction and diffusion in the duct rather than anything to do with shocks.
    private static let subsonicRecovery: Float = 0.980

    /// Total-pressure recovery, 0...1.
    ///
    /// `angleOfAttackRad` matters because an intake sees the flow at the aircraft's
    /// attitude, not at its flight path: a cone or a ramp cut for axial flow spills and
    /// distorts when the aircraft is manoeuvring, and the loss grows with the square of
    /// the incidence. A pitot intake is far less fussy, which is part of why it survives
    /// on aircraft that pull g.
    func pressureRecovery(mach: Float, angleOfAttackRad: Float = 0.0) -> Float {
        let m = max(0.0, mach.isFinite ? mach : 0.0)
        guard type != .none else { return 1.0 }

        let shockRecovery: Float
        switch type {
        case .none:
            shockRecovery = 1.0

        case .pitot:
            guard m > 1.0 else { return Self.subsonicRecovery }
            // One normal shock, and that is the whole story. The Rankine–Hugoniot
            // recovery is brutal: 0.72 at Mach 2, 0.33 at Mach 3. An engine fed a third
            // of its total pressure is not an engine any more, which is exactly why no
            // Mach 3 aircraft has a plain hole in front of it.
            shockRecovery = Self.normalShockRecovery(mach: m)

        case .fixedRamp, .variableRamp:
            guard m > 1.0 else { return Self.subsonicRecovery }
            // MIL-E-5008B, the standard reference schedule for a well-designed
            // supersonic intake: `1 − 0.075·(M−1)^1.35`. It is an empirical fit to what
            // real staged-compression intakes achieve, and it is what engine
            // manufacturers quote installed performance against.
            let reference = 1.0 - 0.075 * pow(max(0.0, m - 1.0), 1.35)
            if type == .variableRamp {
                shockRecovery = max(Self.normalShockRecovery(mach: m), reference)
            } else {
                // A fixed ramp only achieves that at the Mach it was cut for. Away from
                // its design point the shocks no longer land where the geometry expects
                // them: too slow and the system spills, too fast and the shock is
                // swallowed and the terminal shock strengthens. The penalty is symmetric
                // in form but not in consequence — being fast is worse.
                let offDesign = m - designMach
                let penalty = offDesign >= 0.0
                    ? 0.10 * offDesign * offDesign
                    : 0.055 * offDesign * offDesign
                // Never better than the ideal schedule, never worse than a plain hole:
                // a ramp that has lost its shock structure has at least still swallowed
                // a normal shock.
                shockRecovery = max(
                    Self.normalShockRecovery(mach: m),
                    min(reference, reference - penalty)
                )
            }
        }

        // Incidence loss. Quadratic in angle of attack, and much stronger for a ramp
        // because a ramp has a shape that the flow is supposed to arrive along.
        let incidence = abs(angleOfAttackRad.isFinite ? angleOfAttackRad : 0.0)
        let incidenceSensitivity: Float
        switch type {
        case .none:
            incidenceSensitivity = 0.0
        case .pitot:
            incidenceSensitivity = 0.35
        case .fixedRamp:
            incidenceSensitivity = 1.10
        case .variableRamp:
            incidenceSensitivity = 0.85
        }
        // Only counts supersonically — subsonically the flow simply turns into the duct.
        let supersonicWeight = m > 1.0 ? min(1.0, m - 1.0) : 0.0
        let incidenceLoss = incidenceSensitivity * incidence * incidence * supersonicWeight

        // Duct loss and shock loss multiply — they are separate mechanisms in series.
        // Incidence loss is subtracted rather than multiplied because it is spillage
        // and distortion at the lip rather than a further pressure ratio.
        return (Self.subsonicRecovery * shockRecovery - incidenceLoss).clampedToUnit()
    }

    /// Is the intake working at all at this condition?
    ///
    /// A supersonic intake has an operating envelope and leaving it is not a gradual
    /// derate — it is an unstart, where the shock system is expelled, the flow chokes,
    /// and the engine loses most of its air at once. The full dynamics of that are
    /// deliberately future work; what is modelled here is the boundary, so the aircraft
    /// can be told it has crossed one.
    func isWithinEnvelope(mach: Float) -> Bool {
        let m = max(0.0, mach.isFinite ? mach : 0.0)
        switch type {
        case .none:
            return true
        case .pitot:
            // No hard boundary — it just gets worse and worse. Called unusable where the
            // recovery is so poor the engine cannot sustain itself.
            return m <= 2.2
        case .fixedRamp:
            // Cut for one Mach; a long way past it the shock is swallowed.
            return m <= designMach + 0.8
        case .variableRamp:
            // The ramps can be scheduled, but not indefinitely.
            return m <= designMach + 1.4
        }
    }

    /// Additive drag from air the intake could not swallow, as a fraction of the
    /// aircraft's own drag coefficient.
    ///
    /// Air that approaches the intake and is turned away still had to be pushed aside,
    /// and that shows up on the drag ledger rather than the thrust one. Nothing at the
    /// design point, growing as the mismatch grows.
    func spillageDragFactor(mach: Float) -> Float {
        let m = max(0.0, mach.isFinite ? mach : 0.0)
        guard m > 1.0, type == .fixedRamp || type == .variableRamp else { return 0.0 }
        let mismatch = abs(m - designMach)
        return min(0.25, 0.06 * mismatch * mismatch)
    }

    /// Total-pressure recovery across a single normal shock — the Rankine–Hugoniot
    /// result, and the physical floor under any intake.
    static func normalShockRecovery(mach: Float) -> Float {
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
}

private extension Float {
    func clampedToUnit() -> Float {
        Swift.min(1.0, Swift.max(0.0, self))
    }
}
