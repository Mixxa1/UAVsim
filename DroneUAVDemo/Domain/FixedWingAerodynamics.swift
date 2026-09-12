import Foundation
import simd

/// Sorted breakpoint table with linear interpolation, clamped past the ends.
/// Used to give aerodynamic coefficients a real per-family *shape* over angle
/// of attack / sideslip instead of a single flat derivative.
struct BreakpointTable1D {
    private let xs: [Float]
    private let ys: [Float]

    init(_ points: [(Float, Float)]) {
        let sorted = points.sorted { $0.0 < $1.0 }
        xs = sorted.map { $0.0 }
        ys = sorted.map { $0.1 }
    }

    func sample(_ x: Float) -> Float {
        guard let firstX = xs.first, let lastX = xs.last else { return 0.0 }
        if x <= firstX { return ys[0] }
        if x >= lastX { return ys[ys.count - 1] }

        var i = 0
        while i < xs.count - 2 && xs[i + 1] < x {
            i += 1
        }
        let x0 = xs[i], x1 = xs[i + 1]
        let y0 = ys[i], y1 = ys[i + 1]
        let t = (x - x0) / max(1e-6, x1 - x0)
        return y0 + (y1 - y0) * t
    }
}

/// Real(-ish) aerodynamic coefficient bundle for one fixed-wing aircraft at
/// its current mass. Built fresh each physics step from the airframe's
/// `FixedWingFamily` + live geometry/mass via `build(...)` — cheap (a handful
/// of small fixed-size tables), so no caching is needed.
///
/// Coefficients vary with angle of attack / sideslip / control deflection /
/// body rate rather than being flat scalar derivatives: `CL` is a genuine
/// per-family breakpoint curve through the stall and beyond (continuous and
/// bounded everywhere, including past 90° — the exact place the old
/// `sin(pitch)` kinematic model broke down during acro loops); `Cm`/`Cl`/`Cn`
/// damping and stability terms weaken near/past stall via `stallBlend`,
/// which is the nonlinear behavior that lets a real aircraft depart into a
/// spin instead of just losing lift uniformly.
struct FixedWingAerodynamics {
    // `var` (not `let`) fields are the ones structural damage modifies via
    // `applyingDamage` — everything else stays immutable airframe identity.
    var wingArea: Float
    let wingSpan: Float
    let meanChord: Float
    let stallAlphaRad: Float

    let clTable: BreakpointTable1D
    var cd0: Float
    let inducedDragFactor: Float
    let stallDragBump: Float

    let cm0: Float
    var cmAlpha: Float
    var cmDeltaE: Float
    var cmq: Float

    let clBeta: Float
    var clDeltaA: Float
    let clp: Float

    var cnBeta: Float
    var cnDeltaR: Float
    var cnr: Float

    let cyBeta: Float

    /// Tabulated (alpha, Mach) coefficients, when this airframe has them.
    ///
    /// `nil` for the whole existing catalogue, which is what keeps this addition free: a
    /// `nil` here means every code path below behaves exactly as it did before the table
    /// existed. See `MachCoefficientDatabase`.
    let coefficientTable: AeroCoefficientTable?

    /// Compressibility corrections for this airframe's planform.
    ///
    /// Every coefficient above this line is a low-speed number, exactly as it always
    /// was. This is what turns them into functions of Mach — and it is inert below
    /// Mach 0.3, so an airframe flying where the rest of the catalogue flies gets
    /// bit-identical coefficients to the ones it got before compressibility existed.
    let transonic: TransonicAeroModel

    /// Constant rolling/yawing-moment offsets from asymmetric structural
    /// damage (see FixedWingAeroDamage). Zero for a pristine airframe.
    var clRollDamageOffset: Float = 0.0
    var cnYawDamageOffset: Float = 0.0
    var damagePanels: [DamagedWingPanel] = []
    var damageLiftScale: Float = 1.0
    var damageDragExtra: Float = 0.0
    /// How much of the geometric inflow change a rotating wing's strips actually see.
    ///
    /// Strip theory takes the whole `p·y/V` at every station and so over-damps roll: for a
    /// rectangular wing it gives `Clp = −CLα/6`, about twice what aircraft measure, because
    /// the antisymmetric loading of a rolling wing sheds its own trailing vorticity and the
    /// downwash it induces cancels part of the angle change (lifting-surface theory and
    /// DATCOM put the difference at 0.5–0.7 for ordinary aspect ratios). The strips here
    /// take that fraction, solved so their attached-flow roll damping equals this
    /// airframe's own `clp` — the linear model and the strips then agree wherever both
    /// hold, and past the stall the strips carry on where the derivative cannot.
    var rotationalInflowScale: Float = 1.0
    var damageReferencePanels: [DamagedWingPanel] = []

    let maxElevatorRad: Float
    let maxAileronRad: Float
    let maxRudderRad: Float

    /// Diagonal inertia, kg·m², in **(roll, pitch, yaw)** order — see
    /// `boxInertiaTensor` below for why that's the order and not
    /// generic world-axis (Ixx, Iyy, Izz).
    let inertiaTensor: SIMD3<Float>

    // MARK: - Propulsion-airframe coupling (Layer 2)

    let propRadius: Float
    /// Reaction-torque roll moment per unit (thrust × propRadius).
    let torqueThrustRatio: Float
    /// P-factor yaw moment gain — grows with AoA and thrust.
    let pFactorGain: Float
    /// Propeller's own moment of inertia about its spin axis, kg·m².
    let propInertia: Float
    /// How much of the prop-wash induced velocity actually reaches the tail
    /// control surfaces, 0...1. Most of this fleet is a *pusher* layout
    /// (prop at the rear, behind the tail — common for ISR UAVs that need a
    /// clear nose for sensors), so the tail mostly sits ahead of the wash,
    /// not in it — kept low/uniform rather than guessing per-airframe
    /// tractor-vs-pusher placement from incomplete data.
    let tailSlipstreamCoverage: Float
    /// +1 or -1: which way the prop's reaction torque rolls the airframe.
    let propSpinSign: Float

    /// Effective dynamic pressure at the tail (elevator/rudder), boosted by
    /// the propeller's induced velocity on top of freestream airspeed —
    /// real low-speed/high-throttle elevator authority (e.g. holding the
    /// nose up on takeoff roll before there's enough airspeed for the wing
    /// alone), via simple momentum theory: v_induced = sqrt(T / (2ρA)).
    func tailDynamicPressure(airspeed: Float, thrust: Float, airDensity: Float) -> Float {
        let diskArea = Float.pi * propRadius * propRadius
        let inducedVelocity = sqrt(max(0.0, thrust) / max(0.05, 2.0 * airDensity * diskArea))
        let effectiveSpeed = airspeed + tailSlipstreamCoverage * inducedVelocity
        return 0.5 * airDensity * effectiveSpeed * effectiveSpeed
    }

    /// 0 below stall, 1 well past it — used to weaken static stability and
    /// rate damping near/past stall (the nonlinear behavior real aircraft
    /// show, distinct from the lift curve itself).
    func stallBlend(alphaRad: Float) -> Float {
        let absAlpha = abs(alphaRad)
        let edge0 = stallAlphaRad
        let edge1 = stallAlphaRad + Float(8.0).fwDegreesToRadians
        let t = ((absAlpha - edge0) / max(1e-4, edge1 - edge0)).clampedUnit()
        return t * t * (3.0 - 2.0 * t)
    }

    /// Lift + drag coefficients at the given angle of attack and Mach number.
    ///
    /// `mach` defaults to zero, which makes every compressibility term inert — so the
    /// dozens of existing call sites that have no flow state to hand keep the exact
    /// coefficients they had before. The physics step passes the real value.
    ///
    /// Damage enters as a difference: the same strips integrated damaged and undamaged at
    /// this instant's flow, added to the pristine coefficients. An undamaged wing's strips
    /// cancel exactly, so the first dent changes the aircraft by what the dent does and not
    /// by the gap between two models of it.
    func liftDrag(alphaRad: Float, mach: Float = 0.0, pHat: Float = 0, rHat: Float = 0) -> (cl: Float, cd: Float) {
        let pristine = undamagedLiftDrag(alphaRad: alphaRad, mach: mach)
        guard !damagePanels.isEmpty else {
            return (pristine.cl * damageLiftScale, pristine.cd + damageDragExtra)
        }
        let delta = damageStripDelta(alphaRad: alphaRad, mach: mach, pHat: pHat, rHat: rHat)
        return (pristine.cl + delta.cl, max(0, pristine.cd + damageDragExtra + delta.cd))
    }

    private func undamagedLiftDrag(alphaRad: Float, mach: Float) -> (cl: Float, cd: Float) {
        // A tabulated airframe uses its table whole. Its numbers already contain
        // compressibility, wave drag and the vortex behaviour the closed form below models
        // separately, so applying those corrections on top would count each of them twice.
        if let table = coefficientTable {
            let sample = table.sample(alphaRad: alphaRad, mach: mach)
            return (sample.cl, sample.cd)
        }
        let incompressibleCl = clTable.sample(alphaRad)
        let blend = stallBlend(alphaRad: alphaRad)
        let cl = incompressibleCl * transonic.liftFactor(mach: mach)
        // Induced drag is charged on the *compressible* lift, because that is the lift
        // the wing is actually making and therefore the vorticity it is actually
        // shedding. Wave drag is separate and additive — it is a different mechanism,
        // and keeping it separate is what lets it be logged and diagnosed on its own,
        // which the plan asks for.
        let cd = cd0
            + inducedDragFactor * cl * cl
            + blend * stallDragBump
            + transonic.waveDragIncrement(mach: mach, liftCoefficient: cl)
        return (cl, cd)
    }

    /// The wave-drag part of `liftDrag`'s CD on its own, for telemetry and the drag
    /// breakdown the engineering diagnostics need. Recomputing it rather than
    /// returning it from `liftDrag` keeps that call's return shape unchanged for the
    /// solver, which runs it every substep for every aircraft.
    func waveDragCoefficient(alphaRad: Float, mach: Float) -> Float {
        if let table = coefficientTable {
            // A table carries total drag, not a breakdown, so the wave part is recovered as
            // the rise over the same aircraft's incompressible drag at the same alpha.
            // Reported as a difference because that is honestly what is known about it.
            let here = table.sample(alphaRad: alphaRad, mach: mach)
            let low = table.sample(alphaRad: alphaRad, mach: 0.0)
            return max(0.0, here.cd - low.cd)
        }
        let cl = clTable.sample(alphaRad) * transonic.liftFactor(mach: mach)
        return transonic.waveDragIncrement(mach: mach, liftCoefficient: cl)
    }

    /// Pitching moment coefficient: alpha-dependent static stability term
    /// (weakened past stall) + elevator + pitch-rate damping (also weakened
    /// past stall, modeling real tail-effectiveness loss in the wing's wake).
    /// Pitching moment, including the aerodynamic-centre shift through the transonic.
    ///
    /// The shift is applied as a change of moment *reference point* —
    /// `Cm_cg = Cm_ac + CL·Δx/c̄`, negative because the centre moves aft — and not as a
    /// force acting on a lever about the centre of mass. Written the other way it
    /// double-counts a moment the coefficient build-up already contains.
    ///
    /// This term is what stops an aircraft crossing Mach 1 on its old trim. It is also
    /// why a supersonic aircraft needs so much more nose-up elevator to hold level
    /// flight than the same airframe does subsonically.
    func pitchMoment(
        alphaRad: Float,
        elevatorFraction: Float,
        qHat: Float,
        mach: Float = 0.0
    ) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let controlScale = transonic.controlEffectiveness(mach: mach)
        let effectiveCmAlpha = cmAlpha * (1.0 - 0.6 * blend)
        let effectiveCmq = cmq * (1.0 - 0.5 * blend) * controlScale
        // The elevator is on the tail whose stability contribution `cmAlpha` loses 60 % in
        // the wake: the dynamic pressure that goes missing there multiplies the elevator's
        // term exactly as it multiplies the stability term. With the stability weakened and
        // the elevator left whole, full aft stick held every airframe in the fleet at 80°
        // angle of attack — a deep stall no conventional aircraft flies, and the flat spin
        // that followed it. Scaled together they keep the trim angle the stick commands.
        let effectiveCmDeltaE = cmDeltaE * (1.0 - 0.6 * blend) * controlScale
        let base = cm0
            + effectiveCmAlpha * alphaRad
            + effectiveCmDeltaE * elevatorFraction
            + effectiveCmq * qHat

        let shift = transonic.aeroCenterShiftFraction(mach: mach)
        guard shift > 1.0e-5 else { return base }
        let cl = clTable.sample(alphaRad) * transonic.liftFactor(mach: mach)
        return base - cl * shift
    }

    /// The wing integrated strip by strip, in body axes.
    ///
    /// Each strip sees the free stream plus the wing's own rotation — roll changes its
    /// angle of attack (`2·p̂·y`, scaled by `rotationalInflowScale`), yaw its speed — and
    /// makes the section force of the aircraft's own polar at that local angle. Lift and
    /// drag are resolved into the strip's body-normal and body-axial force before they are
    /// summed, because that is what gives the rolling and yawing moments: at 80° angle of
    /// attack a wing's force is nearly all drag in the wind frame and nearly all normal
    /// force on the wing, and it is the normal force that rolls the aircraft.
    ///
    /// A strip beyond its lift peak loses lift as it descends, which is autorotation: no
    /// spin state is scripted anywhere.
    private func stripCoefficients(_ panels: [DamagedWingPanel], alphaRad: Float, mach: Float, pHat: Float, rHat: Float)
        -> (cl: Float, cd: Float, roll: Float, yaw: Float) {
        var normal: Float = 0, axial: Float = 0, roll: Float = 0, yaw: Float = 0
        let freeForward = cos(alphaRad), freeVertical = sin(alphaRad)
        let inflow = 2 * rotationalInflowScale * pHat
        for panel in panels where panel.isPresent {
            let forward = freeForward + 2 * rHat * panel.spanPosition
            let vertical = freeVertical - inflow * panel.spanPosition
            let flow = atan2(vertical, forward)
            let speed = min(9, forward * forward + vertical * vertical)
            let section = undamagedLiftDrag(alphaRad: (flow + panel.incidenceRad) / max(0.4, panel.stallScale), mach: mach)
            let lift = section.cl * panel.stallScale * panel.effectiveness
            let drag = section.cd + (1 - panel.health) * DamagedWingPanel.damagedSectionDragIncrement
            let cosFlow = cos(flow), sinFlow = sin(flow)
            let n = (lift * cosFlow + drag * sinFlow) * speed * panel.areaFraction
            let a = (drag * cosFlow - lift * sinFlow) * speed * panel.areaFraction
            normal += n
            axial += a
            // Body axes: +X right, +Y up, −Z forward. A normal force on the right wing rolls
            // it up (+); an aft force there swings the nose right (−).
            roll += panel.spanPosition * n
            yaw -= panel.spanPosition * a
        }
        return (normal * freeForward - axial * freeVertical, normal * freeVertical + axial * freeForward, roll, yaw)
    }

    private func damageStripDelta(alphaRad: Float, mach: Float, pHat: Float, rHat: Float)
        -> (cl: Float, cd: Float, roll: Float, yaw: Float) {
        let damaged = stripCoefficients(damagePanels, alphaRad: alphaRad, mach: mach, pHat: pHat, rHat: rHat)
        let reference = stripCoefficients(damageReferencePanels, alphaRad: alphaRad, mach: mach, pHat: pHat, rHat: rHat)
        return (damaged.cl - reference.cl, damaged.cd - reference.cd,
                damaged.roll - reference.roll, damaged.yaw - reference.yaw)
    }

    /// Sixteen equal strips across the span: the pristine wing the rate model integrates
    /// when there is no measured planform to hand. The calibration of
    /// `rotationalInflowScale` absorbs the planform's shape in attached flow, which is the
    /// only place the shape would otherwise show.
    static let uniformStrips: [DamagedWingPanel] = (0..<16).map { index in
        DamagedWingPanel(areaFraction: 1.0 / 16.0, spanPosition: (Float(index) + 0.5) / 16.0 - 0.5,
                         effectiveness: 1, stallScale: 1, incidenceRad: 0)
    }

    /// Roll-rate damping past the stall, from the strips.
    ///
    /// Below the stall the airframe's own `clp` is exact and is kept, so attached flight is
    /// unchanged to the bit. Through the stall the strips take over: the descending wing
    /// runs further past its lift peak and loses lift, the rising one regains it, and the
    /// damping falls through zero into autorotation. The old `clp·(1 − ½·blend)` said the
    /// same thing in one number and could never go past zero, so an aircraft could not spin.
    private func rollRateMoment(alphaRad: Float, mach: Float, pHat: Float) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let controlScale = transonic.controlEffectiveness(mach: mach)
        let attached = clp * controlScale * pHat
        guard blend > 0 else { return attached }
        let strips = stripCoefficients(Self.uniformStrips, alphaRad: alphaRad, mach: mach, pHat: pHat, rHat: 0).roll
        return attached * (1 - blend) + strips * blend
    }

    /// `rotationalInflowScale` for this airframe: its `clp` over the uniform strips' own
    /// attached-flow roll damping, `−2·CLα·Σa·y²` = `−CLα/6`.
    func calibratedRotationalInflowScale() -> Float {
        let step: Float = 0.035
        let slope = (undamagedLiftDrag(alphaRad: step, mach: 0).cl - undamagedLiftDrag(alphaRad: -step, mach: 0).cl) / (2 * step)
        guard slope > 0.5 else { return 1 }
        return (abs(clp) / (slope / 6)).clamped(to: 0.2...2.5)
    }

    /// Rolling moment coefficient: sideslip (dihedral) + aileron + roll-rate
    /// damping + the constant asymmetric-damage offset.
    func rollMoment(
        alphaRad: Float,
        betaRad: Float,
        aileronFraction: Float,
        pHat: Float,
        mach: Float = 0.0,
        rHat: Float = 0.0
    ) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let controlScale = transonic.controlEffectiveness(mach: mach)
        // Ailerons work on the flow over the outer wing; once that has separated they have
        // nothing to deflect. Same loss as the wing's other lateral derivatives.
        let effectiveClDeltaA = clDeltaA * (1.0 - 0.5 * blend) * controlScale
        let damage = damagePanels.isEmpty ? 0
            : damageStripDelta(alphaRad: alphaRad, mach: mach, pHat: pHat, rHat: rHat).roll
        return clBeta * betaRad
            + effectiveClDeltaA * aileronFraction
            + rollRateMoment(alphaRad: alphaRad, mach: mach, pHat: pHat)
            + damage
            + clRollDamageOffset
    }

    /// Yawing moment coefficient: sideslip (weathercock) + rudder + yaw-rate
    /// damping + the constant asymmetric-damage offset.
    func yawMoment(
        alphaRad: Float,
        betaRad: Float,
        rudderFraction: Float,
        rHat: Float,
        mach: Float = 0.0,
        pHat: Float = 0.0
    ) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let controlScale = transonic.controlEffectiveness(mach: mach)
        let effectiveCnBeta = cnBeta * (1.0 - 0.5 * blend)
        let effectiveCnr = cnr * (1.0 - 0.5 * blend) * controlScale
        // The rudder sits on the fin whose weathercock stiffness `cnBeta` loses half its
        // effect in the stalled wing's wake: it is the same surface in the same wake, so it
        // loses the same half. Leaving it whole let full rudder drive a stalled aircraft to
        // the angular-rate clamp.
        let effectiveCnDeltaR = cnDeltaR * (1.0 - 0.5 * blend) * controlScale
        return effectiveCnBeta * betaRad
            + effectiveCnDeltaR * rudderFraction
            + effectiveCnr * rHat
            + cnYawDamageOffset
            + (damagePanels.isEmpty ? 0 : damageStripDelta(alphaRad: alphaRad, mach: mach, pHat: pHat, rHat: rHat).yaw)
    }

    /// Applies structural-damage deltas on top of the pristine model.
    /// Neutral deltas return the model untouched, so the undamaged flight
    /// path stays bit-identical.
    func applyingDamage(_ damage: FixedWingAeroDamage) -> FixedWingAerodynamics {
        guard !damage.isPristine else { return self }
        var damaged = self
        // Keep reference geometry for moments, drag and wing-area telemetry.
        // Lost lift belongs to the coefficients; no phantom 20% wing remains.
        damaged.damageLiftScale = damage.liftScale.clampedUnit()
        damaged.damageDragExtra = max(0, damage.cd0Extra)
        damaged.damagePanels = damage.panels
        damaged.damageReferencePanels = damage.panels.map(\.undamaged)
        damaged.clDeltaA = clDeltaA * damage.aileronScale.clampedUnit()
        damaged.cmDeltaE = cmDeltaE * damage.elevatorScale.clampedUnit()
        damaged.cmAlpha = cmAlpha * damage.pitchStabilityScale.clampedUnit()
        damaged.cmq = cmq * damage.pitchStabilityScale.clampedUnit()
        damaged.cnDeltaR = cnDeltaR * damage.rudderScale.clampedUnit()
        damaged.cnBeta = cnBeta * damage.yawStabilityScale.clampedUnit()
        damaged.cnr = cnr * damage.yawStabilityScale.clampedUnit()
        damaged.clRollDamageOffset = clRollDamageOffset + damage.clRollOffset
        damaged.cnYawDamageOffset = cnYawDamageOffset + damage.cnYawOffset
        return damaged
    }

    /// This family's stall angle of attack, radians.
    ///
    /// Exposed on its own because the flight envelope needs it without needing an
    /// airframe: building a whole coefficient set to read one preset value would mean
    /// supplying a mass, a span and a stall speed that have nothing to do with the
    /// question being asked.
    static func stallAngleOfAttack(for family: FixedWingFamily) -> Float {
        FamilyAeroPreset.preset(for: family).stallAlphaRad
    }

    /// Mach at which this planform's drag rise becomes steep.
    ///
    /// Exposed for the same reason as the stall angle, and used for the same kind of
    /// thing: it is the aerodynamic ceiling a subsonic airframe actually has, and it
    /// belongs to the shape rather than to any particular aircraft's declared speeds.
    static func dragDivergenceMach(for family: FixedWingFamily) -> Float {
        FamilyAeroPreset.preset(for: family).dragDivergenceMach
    }

    static func build(
        family: FixedWingFamily,
        massKg: Float,
        wingSpanM: Float,
        fuselageLengthM: Float,
        heightM: Float,
        turnAuthority: Float,
        minSustainableSpeedMps: Float,
        /// Mass the airframe's published stall speed refers to — its maximum takeoff weight, where
        /// the catalogue gives one. Only the wing geometry uses it; everything mass-dependent
        /// downstream keeps using the live mass.
        designMassKg: Float? = nil
    ) -> FixedWingAerodynamics {
        let preset = FamilyAeroPreset.preset(for: family)
        let span = max(0.3, wingSpanM)
        let fuselageLength = max(0.2, fuselageLengthM)
        let height = max(0.08, heightM)
        let mass = max(0.1, massKg)
        // No per-airframe prop size data is available; approximate from
        // span using a typical small-UAV prop-to-span ratio.
        let propRadius = (span * 0.035).clamped(to: 0.03...1.2)

        let coefficientTable = MachCoefficientDatabase.table(profileID: nil, family: family)
        // Calibrate the area against whichever lift curve this airframe will actually fly
        // on. Solving the area from the closed form and then flying a table is how an
        // aircraft ends up stalling nowhere near its published speed — the area and the
        // curve have to be two halves of one statement.
        let clMaxAtStall: Float = {
            guard let table = coefficientTable else {
                return preset.cl0 + preset.clAlpha * preset.stallAlphaRad
            }
            // Read at the family's stall angle and at low speed — the same two conditions
            // the closed form's own CLmax is evaluated at, so the calibration keeps meaning
            // the same thing whichever curve supplies the number.
            //
            // Not the table's global peak, which for a delta sits out past 30 degrees where
            // the leading-edge vortex is at its strongest. That value is real, and it is
            // real for the wrong question: a stall speed is quoted at a usable attitude, and
            // taking the vortex maximum instead reported the aircraft as having twice the
            // lift it can use, which halved its wing and then let it fly at Mach 2.2 on a
            // published 1.40. The extra lift above the stall angle is still there in the
            // table and still available in flight — that is the point of having it — it is
            // just not what sizes the wing.
            return max(0.3, table.sample(alphaRad: preset.stallAlphaRad, mach: 0.15).cl)
        }()
        let clMinAtNegStall = (2.0 * preset.cl0) - clMaxAtStall

        // Wing area is calibrated so THIS airframe's modeled stall speed
        // matches its existing (already-tuned-by-feel) `minSustainableSpeedMps`
        // — not guessed from a per-family aspect ratio. A guessed aspect
        // ratio can quietly imply a stall/liftoff speed wildly different
        // from what the rest of the sim (and the developer's tuning) expects
        // — e.g. a real-world-accurate high-AR guess for a heavy airframe
        // pushed its emergent liftoff speed to ~90 m/s against a tuned
        // takeoff rotation speed of 53 m/s. Calibrating area directly keeps
        // every airframe's stall/liftoff feel consistent with its existing
        // speed tuning regardless of how (un)realistic the guessed aspect
        // ratio would otherwise have been.
        //
        // The density here is deliberately the fixed sea-level value and NOT the
        // ambient density from `AtmosphereModel`, even though every dynamic-pressure
        // calculation downstream now uses the latter. This expression is a
        // *calibration* — it solves for the airframe's geometry from a stall speed
        // quoted at sea level. Feeding it live density would make the wing physically
        // grow as the aircraft climbed, which is the opposite of the altitude effect
        // being modelled: real altitude performance comes from the thinner air acting
        // on a fixed wing, and that happens in the solver.
        let stallSpeed = max(minSustainableSpeedMps, 3.0)
        // ⚠️ Solve the geometry from the mass the stall speed was quoted AT, not from whatever the
        // aircraft weighs right now. A quoted stall speed belongs to a loaded aeroplane; feeding
        // the live mass made the wing shrink as the tanks emptied, which is not a thing wings do.
        //
        // The effect is not subtle on a fuel-burning jet: the HESA Karrar came out with 0.85 m² of
        // wing against roughly 2.35 m² at its own maximum weight, so its drag was a third of what
        // it should be and its engine simply pushed it through its published top speed — measured
        // at 340 m/s against a catalogued 250. Inertia below still uses the live mass, because
        // that genuinely does change as fuel burns.
        let geometryMass = max(mass, designMassKg ?? mass)
        let area = ((2.0 * geometryMass * 9.81) / (AtmosphereModel.seaLevelDensity * stallSpeed * stallSpeed * max(0.3, clMaxAtStall))).clamped(to: 0.05...400.0)
        let chord = area / span
        // Effective aspect ratio, back-derived from the calibrated area, used
        // only for induced drag — clamped to a believable range so a
        // pathological mass/speed/span combination can't blow up drag.
        let aspectRatio = (span * span / area).clamped(to: 3.0...25.0)
        let postStall = preset.stallAlphaRad + Float(8.0).fwDegreesToRadians
        let flatPlateAtPost = 2.0 * sin(postStall) * cos(postStall)
        let halfPi = Float.pi / 2.0

        let clTable = BreakpointTable1D([
            (-halfPi, 0.0),
            (-postStall, -flatPlateAtPost),
            (-preset.stallAlphaRad, clMinAtNegStall),
            (0.0, preset.cl0),
            (preset.stallAlphaRad, clMaxAtStall),
            (postStall, flatPlateAtPost),
            (halfPi, 0.0)
        ])

        // Rate-damping magnitudes scale with mass so a 5+ ton airframe and a
        // 1.6 kg one both get plausible (non-flat) damping without
        // hand-authoring per-airframe derivatives.
        let dampingScale = sqrt(mass / 20.0).clamped(to: 0.5...3.0)
        let turnGain = turnAuthority.clamped(to: 0.4...1.4)

        // Roll-damping floor. The mass-based dampingScale collapses for
        // ultralight airframes (floors at 0.5) while the damping moment's
        // pHat = p*b/2V lever also shrinks with the small span — combined,
        // a ~1.7 kg hand-launch wing ends up with a full-aileron steady
        // roll rate of tens of rad/s. In flight that showed up as the wing
        // blowing through its commanded 36° bank to a knife edge on the
        // second turn input and falling out of the sky. Floor clp so the
        // implied steady full-aileron roll rate stays believable for the
        // airframe's size; for the existing heavy fleet this floor computes
        // to at or below their current clp (FT5's within a few percent), so
        // their tuned behaviour is unchanged.
        let referenceSpeed = stallSpeed * 1.55
        let targetMaxRollRateRadPerSec = (4.8 / span).clamped(to: 0.7...3.0)
        let clpFloorMagnitude = (preset.clDeltaA * turnGain) *
            (2.0 * referenceSpeed / span) / targetMaxRollRateRadPerSec

        // Pitch-damping floor, the exact counterpart of the roll floor above and
        // added for the same reason.
        //
        // `dampingScale` collapses to its 0.5 floor for a light airframe while the
        // qHat = q·c/2V lever also shrinks with the small chord. On a 2.6 kg delta
        // that left cmq at -2.5 against a `cmDeltaE` of 0.17 and a pitch inertia
        // near 0.1 kg·m², so full elevator commanded some 700 deg/s² and the
        // attitude loop's proportional term drove a divergent oscillation: measured
        // in flight, pitch went +22.8°, +1.6°, -7.4°, -40.8° on consecutive samples
        // and the aircraft hit the ground inverted. The `.delta` preset is worst hit
        // because its cmqBase is a third of the flying wing's.
        //
        // Floor cmq so the implied short-period damping stays believable for the
        // airframe's size. For the heavier fleet this computes below their existing
        // damping and changes nothing.
        let targetPitchRateRadPerSec = (3.2 / max(0.08, chord)).clamped(to: 1.2...9.0)
        let cmqFloorMagnitude = (preset.cmDeltaE)
            * (2.0 * referenceSpeed / max(0.08, chord)) / targetPitchRateRadPerSec

        let inertia = boxInertiaTensor(
            massKg: mass,
            wingSpanM: span,
            fuselageLengthM: fuselageLength,
            heightM: height
        )

        var aerodynamics = FixedWingAerodynamics(
            wingArea: area,
            wingSpan: span,
            meanChord: chord,
            stallAlphaRad: preset.stallAlphaRad,
            clTable: clTable,
            cd0: preset.cd0,
            inducedDragFactor: 1.0 / (Float.pi * preset.oswaldEfficiency * aspectRatio),
            stallDragBump: preset.stallDragBump,
            cm0: preset.cm0,
            cmAlpha: preset.cmAlpha,
            cmDeltaE: preset.cmDeltaE,
            cmq: -max(abs(preset.cmqBase * dampingScale), cmqFloorMagnitude),
            clBeta: preset.clBetaSlope,
            clDeltaA: preset.clDeltaA * turnGain,
            clp: -max(abs(preset.clpBase * dampingScale), clpFloorMagnitude),
            cnBeta: preset.cnBetaSlope,
            cnDeltaR: preset.cnDeltaR * turnGain,
            cnr: preset.cnrBase * dampingScale,
            cyBeta: preset.cyBeta,
            coefficientTable: coefficientTable,
            transonic: TransonicAeroModel(
                criticalMach: preset.criticalMach,
                dragDivergenceMach: preset.dragDivergenceMach,
                waveDragPeak: preset.waveDragPeak,
                supersonicAeroCenterShift: preset.supersonicAeroCenterShift
            ),
            maxElevatorRad: preset.maxElevatorDeg.fwDegreesToRadians,
            maxAileronRad: preset.maxAileronDeg.fwDegreesToRadians,
            maxRudderRad: preset.maxRudderDeg.fwDegreesToRadians,
            inertiaTensor: inertia,
            propRadius: propRadius,
            torqueThrustRatio: preset.torqueThrustRatio,
            pFactorGain: preset.pFactorGain,
            // Flat-disk inertia (I = 0.5*m*r²) using ~2% of airframe mass as
            // a propeller+spinner mass proxy, capped so the heaviest
            // airframes don't imply an absurdly heavy prop.
            propInertia: 0.5 * (mass.clamped(to: 0.05...40.0) * 0.02) * propRadius * propRadius,
            tailSlipstreamCoverage: preset.tailSlipstreamCoverage,
            propSpinSign: 1.0
        )
        aerodynamics.rotationalInflowScale = aerodynamics.calibratedRotationalInflowScale()
        return aerodynamics
    }

    /// Diagonal box-approximation inertia tensor from mass + overall
    /// dimensions, scaled down since real mass concentrates nearer the
    /// fuselage centerline than a uniform box implies.
    ///
    /// Returned in **(roll, pitch, yaw) inertia** order — i.e. matching the
    /// `.x = roll, .y = pitch, .z = yaw` convention already used for
    /// `orientation`/`angularVelocity` everywhere in this codebase — not
    /// generic textbook (Ixx, Iyy, Izz) about the literal world X/Y/Z axes.
    /// Concretely, in this engine's world axes (X = right, Y = up,
    /// Z = aft, nose along -Z): roll is about Z (span/height extents),
    /// pitch is about X (height/fuselage extents), yaw is about Y
    /// (span/fuselage extents).
    private static func boxInertiaTensor(
        massKg: Float,
        wingSpanM: Float,
        fuselageLengthM: Float,
        heightM: Float
    ) -> SIMD3<Float> {
        let concentration: Float = 0.7
        let rollInertia = massKg * (wingSpanM * wingSpanM + heightM * heightM) / 12.0 * concentration
        let pitchInertia = massKg * (fuselageLengthM * fuselageLengthM + heightM * heightM) / 12.0 * concentration
        let yawInertia = massKg * (wingSpanM * wingSpanM + fuselageLengthM * fuselageLengthM) / 12.0 * concentration
        return SIMD3<Float>(max(0.001, rollInertia), max(0.001, pitchInertia), max(0.001, yawInertia))
    }
}

extension FixedWingAerodynamics {
    /// Maximum lift coefficient at the family's stall angle and its lift-curve slope (per
    /// radian) — the two numbers a structural gust case needs from the aerodynamics.
    static func designLiftCharacteristics(for family: FixedWingFamily) -> (maximumLift: Float, liftSlope: Float) {
        let preset = FamilyAeroPreset.preset(for: family)
        return (max(0.3, preset.cl0 + preset.clAlpha * preset.stallAlphaRad), max(1, preset.clAlpha))
    }
}

private struct FamilyAeroPreset {
    let cl0: Float
    let clAlpha: Float // per radian
    let stallAlphaRad: Float
    let cd0: Float
    let oswaldEfficiency: Float
    let stallDragBump: Float
    // Sign convention note: this engine's body axes are X=right, Y=up,
    // Z=aft (nose along -Z), which mirrors the standard aerospace body-axis
    // convention (X=forward, Y=right, Z=down) on the roll AND yaw axes.
    // That mirroring flips the textbook sign of the two *stability*
    // derivatives below relative to what you'd copy from a standard
    // reference: clBetaSlope must be POSITIVE (not the textbook-negative
    // Clβ) and cnBetaSlope must be NEGATIVE (not the textbook-positive
    // Cnβ) for dihedral/weathercock restoring moments to actually restore
    // in this engine's convention. cmDeltaE must be POSITIVE so that a
    // positive elevator fraction (stick back, matching the pre-existing
    // "positive targetOrientation.y -> nose up" convention) produces a
    // nose-up moment. Damping terms (cmqBase/clpBase/cnrBase) are
    // convention-independent (always oppose their own rate) and stay
    // negative. Verified against a standalone physics-only harness
    // (full-aft-stick acro loop) — get this wrong and the aircraft trims
    // to an extreme AoA and tumbles within a few seconds.
    let cm0: Float
    let cmAlpha: Float // per radian
    let cmDeltaE: Float // per radian of elevator deflection — must be POSITIVE, see note above
    let cmqBase: Float
    let clBetaSlope: Float // per radian sideslip (dihedral) — must be POSITIVE, see note above
    let clDeltaA: Float // per radian of aileron deflection
    let clpBase: Float
    let cnBetaSlope: Float // per radian sideslip (weathercock) — must be NEGATIVE, see note above
    let cnDeltaR: Float // per radian of rudder deflection
    let cnrBase: Float
    let cyBeta: Float // per radian sideslip
    // Compressibility shape parameters. Diagnostic and fallback figures rather than
    // measured ones — the plan asks for them to be stored per profile precisely so that
    // a universal "+30 % drag above Mach 1" is impossible to write. A thin slender delta
    // and a thick straight wing differ here by a factor of three, which is most of why
    // one of them can go supersonic and the other cannot.
    let criticalMach: Float
    let dragDivergenceMach: Float
    let waveDragPeak: Float
    let supersonicAeroCenterShift: Float
    let maxElevatorDeg: Float
    let maxAileronDeg: Float
    let maxRudderDeg: Float
    let torqueThrustRatio: Float
    let pFactorGain: Float
    let tailSlipstreamCoverage: Float

    static func preset(for family: FixedWingFamily) -> FamilyAeroPreset {
        switch family {
        case .rectangular:
            return FamilyAeroPreset(
                cl0: 0.25, clAlpha: 5.3, stallAlphaRad: Float(15.5).fwDegreesToRadians,
                cd0: 0.032, oswaldEfficiency: 0.78, stallDragBump: 1.1,
                cm0: 0.02, cmAlpha: -0.65, cmDeltaE: 0.19, cmqBase: -8.0,
                clBetaSlope: 0.10, clDeltaA: 0.12, clpBase: -0.45,
                cnBetaSlope: -0.10, cnDeltaR: 0.06, cnrBase: -0.22,
                cyBeta: -0.30,
                criticalMach: 0.68, dragDivergenceMach: 0.74,
                waveDragPeak: 0.075, supersonicAeroCenterShift: 0.24,
                maxElevatorDeg: 24.0, maxAileronDeg: 20.0, maxRudderDeg: 18.0,
                torqueThrustRatio: 0.08, pFactorGain: 0.05, tailSlipstreamCoverage: 0.30
            )
        case .delta:
            return FamilyAeroPreset(
                cl0: 0.05, clAlpha: 3.0, stallAlphaRad: Float(23.0).fwDegreesToRadians,
                cd0: 0.028, oswaldEfficiency: 0.70, stallDragBump: 0.7,
                cm0: 0.0, cmAlpha: -0.35, cmDeltaE: 0.17, cmqBase: -5.0,
                clBetaSlope: 0.06, clDeltaA: 0.09, clpBase: -0.35,
                cnBetaSlope: -0.07, cnDeltaR: 0.05, cnrBase: -0.15,
                cyBeta: -0.22,
                criticalMach: 0.82, dragDivergenceMach: 0.90,
                waveDragPeak: 0.030, supersonicAeroCenterShift: 0.22,
                maxElevatorDeg: 22.0, maxAileronDeg: 18.0, maxRudderDeg: 16.0,
                torqueThrustRatio: 0.06, pFactorGain: 0.03, tailSlipstreamCoverage: 0.20
            )
        case .swept:
            return FamilyAeroPreset(
                cl0: 0.18, clAlpha: 4.6, stallAlphaRad: Float(14.0).fwDegreesToRadians,
                cd0: 0.026, oswaldEfficiency: 0.75, stallDragBump: 1.2,
                cm0: 0.0, cmAlpha: -0.55, cmDeltaE: 0.16, cmqBase: -10.0,
                clBetaSlope: 0.09, clDeltaA: 0.10, clpBase: -0.40,
                cnBetaSlope: -0.12, cnDeltaR: 0.07, cnrBase: -0.24,
                cyBeta: -0.28,
                criticalMach: 0.76, dragDivergenceMach: 0.82,
                waveDragPeak: 0.050, supersonicAeroCenterShift: 0.25,
                maxElevatorDeg: 20.0, maxAileronDeg: 18.0, maxRudderDeg: 16.0,
                // MQ-9B (the only user of this family) is a confirmed rear
                // pusher-prop design — tail sits ahead of the disk, barely
                // in the wash at all.
                torqueThrustRatio: 0.07, pFactorGain: 0.06, tailSlipstreamCoverage: 0.12
            )
        case .flyingWing:
            return FamilyAeroPreset(
                cl0: 0.10, clAlpha: 4.0, stallAlphaRad: Float(19.0).fwDegreesToRadians,
                cd0: 0.024, oswaldEfficiency: 0.74, stallDragBump: 0.8,
                cm0: 0.0, cmAlpha: -0.30, cmDeltaE: 0.12, cmqBase: -15.0,
                clBetaSlope: 0.07, clDeltaA: 0.11, clpBase: -0.38,
                cnBetaSlope: -0.06, cnDeltaR: 0.045, cnrBase: -0.13,
                cyBeta: -0.18,
                criticalMach: 0.78, dragDivergenceMach: 0.85,
                waveDragPeak: 0.040, supersonicAeroCenterShift: 0.20,
                maxElevatorDeg: 18.0, maxAileronDeg: 18.0, maxRudderDeg: 12.0,
                torqueThrustRatio: 0.05, pFactorGain: 0.02, tailSlipstreamCoverage: 0.15
            )
        case .conventionalSurvey:
            return FamilyAeroPreset(
                cl0: 0.22, clAlpha: 5.1, stallAlphaRad: Float(16.0).fwDegreesToRadians,
                cd0: 0.028, oswaldEfficiency: 0.80, stallDragBump: 1.0,
                cm0: 0.015, cmAlpha: -0.60, cmDeltaE: 0.19, cmqBase: -7.0,
                clBetaSlope: 0.09, clDeltaA: 0.115, clpBase: -0.42,
                cnBetaSlope: -0.11, cnDeltaR: 0.065, cnrBase: -0.22,
                cyBeta: -0.27,
                criticalMach: 0.70, dragDivergenceMach: 0.76,
                waveDragPeak: 0.070, supersonicAeroCenterShift: 0.24,
                maxElevatorDeg: 22.0, maxAileronDeg: 20.0, maxRudderDeg: 18.0,
                torqueThrustRatio: 0.08, pFactorGain: 0.05, tailSlipstreamCoverage: 0.30
            )
        case .tailsitterVTOL:
            return FamilyAeroPreset(
                cl0: 0.20, clAlpha: 4.7, stallAlphaRad: Float(15.0).fwDegreesToRadians,
                cd0: 0.034, oswaldEfficiency: 0.72, stallDragBump: 1.0,
                cm0: 0.01, cmAlpha: -0.50, cmDeltaE: 0.15, cmqBase: -6.0,
                clBetaSlope: 0.08, clDeltaA: 0.10, clpBase: -0.40,
                cnBetaSlope: -0.09, cnDeltaR: 0.06, cnrBase: -0.19,
                cyBeta: -0.25,
                criticalMach: 0.68, dragDivergenceMach: 0.74,
                waveDragPeak: 0.080, supersonicAeroCenterShift: 0.24,
                maxElevatorDeg: 20.0, maxAileronDeg: 18.0, maxRudderDeg: 16.0,
                torqueThrustRatio: 0.07, pFactorGain: 0.04, tailSlipstreamCoverage: 0.25
            )
        // MARK: Supersonic planforms
        //
        // The three below differ where it matters and are alike where it does not. All
        // are thin and slender, so all pay far less wave drag than the subsonic families
        // above — a cropped-delta target drone's wave-drag peak is a third of a thick
        // straight wing's, which is most of why one of them can go supersonic on 8 kN and
        // the other cannot go supersonic at all.
        //
        // Where they part company is the aerodynamic-centre shift, and that is not a
        // detail: it is the trim change through Mach 1. A tailless delta pays the most, a
        // cruciform-tailed slender body somewhat less, and a close-coupled canard the
        // least — which is the actual aerodynamic argument for putting a canard on a
        // supersonic aircraft, and the reason all three configurations exist.
        //
        // Propeller-coupling terms are zero throughout. Every aircraft on these planforms
        // is a jet, and the solver gates those terms on having a disc to react against.
        case .supersonicCruciform:
            return FamilyAeroPreset(
                cl0: 0.04, clAlpha: 2.9, stallAlphaRad: Float(20.0).fwDegreesToRadians,
                cd0: 0.022, oswaldEfficiency: 0.66, stallDragBump: 0.55,
                cm0: 0.0, cmAlpha: -0.46, cmDeltaE: 0.20, cmqBase: -9.0,
                clBetaSlope: 0.05, clDeltaA: 0.085, clpBase: -0.30,
                // A cruciform tail is a large fin: this planform weathercocks hard, which
                // is what keeps a slender body pointed the right way at Mach 1.8.
                cnBetaSlope: -0.16, cnDeltaR: 0.085, cnrBase: -0.30,
                cyBeta: -0.34,
                criticalMach: 0.88, dragDivergenceMach: 0.95,
                // 0.014, not the 0.022 first written. A body of revolution with small
                // wings is the lowest-wave-drag shape there is, and the reference
                // aircraft on this planform could not reach their published speeds at the
                // higher figure. The estimate moved; their published performance did not.
                waveDragPeak: 0.014, supersonicAeroCenterShift: 0.26,
                maxElevatorDeg: 22.0, maxAileronDeg: 18.0, maxRudderDeg: 22.0,
                torqueThrustRatio: 0.0, pFactorGain: 0.0, tailSlipstreamCoverage: 0.0
            )
        case .supersonicDelta:
            return FamilyAeroPreset(
                // Vortex lift: a thin delta keeps making lift to angles that would have
                // stalled a straight wing long before, and it does it with a lift-curve
                // slope that is low all the way up.
                cl0: 0.03, clAlpha: 2.6, stallAlphaRad: Float(28.0).fwDegreesToRadians,
                cd0: 0.020, oswaldEfficiency: 0.62, stallDragBump: 0.5,
                cm0: 0.0, cmAlpha: -0.30, cmDeltaE: 0.16, cmqBase: -4.5,
                clBetaSlope: 0.05, clDeltaA: 0.095, clpBase: -0.32,
                cnBetaSlope: -0.06, cnDeltaR: 0.05, cnrBase: -0.14,
                cyBeta: -0.20,
                criticalMach: 0.90, dragDivergenceMach: 0.98,
                waveDragPeak: 0.014, supersonicAeroCenterShift: 0.24,
                maxElevatorDeg: 24.0, maxAileronDeg: 20.0, maxRudderDeg: 18.0,
                torqueThrustRatio: 0.0, pFactorGain: 0.0, tailSlipstreamCoverage: 0.0
            )
        case .canardDelta:
            return FamilyAeroPreset(
                // The canard carries lift of its own, so the configuration's lift-curve
                // slope is higher than a bare delta's and its induced efficiency better.
                cl0: 0.08, clAlpha: 3.4, stallAlphaRad: Float(26.0).fwDegreesToRadians,
                cd0: 0.024, oswaldEfficiency: 0.72, stallDragBump: 0.6,
                // Deliberately weak static stability. A close-coupled canard aircraft is
                // built near neutral and flown by its computer — HiMAT explicitly so —
                // and pretending otherwise would make it handle like an airliner.
                cm0: 0.01, cmAlpha: -0.22, cmDeltaE: 0.24, cmqBase: -5.5,
                clBetaSlope: 0.06, clDeltaA: 0.115, clpBase: -0.34,
                cnBetaSlope: -0.09, cnDeltaR: 0.06, cnrBase: -0.18,
                cyBeta: -0.24,
                criticalMach: 0.86, dragDivergenceMach: 0.94,
                waveDragPeak: 0.019,
                // Half the shift of a tailless delta. This single number is the
                // configuration's whole reason for existing.
                supersonicAeroCenterShift: 0.13,
                maxElevatorDeg: 25.0, maxAileronDeg: 22.0, maxRudderDeg: 20.0,
                torqueThrustRatio: 0.0, pFactorGain: 0.0, tailSlipstreamCoverage: 0.0
            )
        case .surveyEVTOL:
            return FamilyAeroPreset(
                cl0: 0.21, clAlpha: 4.9, stallAlphaRad: Float(15.5).fwDegreesToRadians,
                cd0: 0.030, oswaldEfficiency: 0.76, stallDragBump: 1.0,
                cm0: 0.012, cmAlpha: -0.55, cmDeltaE: 0.17, cmqBase: -6.5,
                clBetaSlope: 0.085, clDeltaA: 0.11, clpBase: -0.41,
                cnBetaSlope: -0.10, cnDeltaR: 0.06, cnrBase: -0.20,
                cyBeta: -0.26,
                criticalMach: 0.70, dragDivergenceMach: 0.76,
                waveDragPeak: 0.075, supersonicAeroCenterShift: 0.24,
                maxElevatorDeg: 21.0, maxAileronDeg: 19.0, maxRudderDeg: 17.0,
                torqueThrustRatio: 0.07, pFactorGain: 0.04, tailSlipstreamCoverage: 0.25
            )
        }
    }
}

private extension Float {
    var fwDegreesToRadians: Float {
        self * .pi / 180.0
    }

    func clampedUnit() -> Float {
        Swift.min(1.0, Swift.max(0.0, self))
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
