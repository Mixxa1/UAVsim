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
    let wingArea: Float
    let wingSpan: Float
    let meanChord: Float
    let stallAlphaRad: Float

    let clTable: BreakpointTable1D
    let cd0: Float
    let inducedDragFactor: Float
    let stallDragBump: Float

    let cm0: Float
    let cmAlpha: Float
    let cmDeltaE: Float
    let cmq: Float

    let clBeta: Float
    let clDeltaA: Float
    let clp: Float

    let cnBeta: Float
    let cnDeltaR: Float
    let cnr: Float

    let cyBeta: Float

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

    /// Lift + drag coefficients at the given angle of attack.
    func liftDrag(alphaRad: Float) -> (cl: Float, cd: Float) {
        let cl = clTable.sample(alphaRad)
        let blend = stallBlend(alphaRad: alphaRad)
        let cd = cd0 + inducedDragFactor * cl * cl + blend * stallDragBump
        return (cl, cd)
    }

    /// Pitching moment coefficient: alpha-dependent static stability term
    /// (weakened past stall) + elevator + pitch-rate damping (also weakened
    /// past stall, modeling real tail-effectiveness loss in the wing's wake).
    func pitchMoment(alphaRad: Float, elevatorFraction: Float, qHat: Float) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let effectiveCmAlpha = cmAlpha * (1.0 - 0.6 * blend)
        let effectiveCmq = cmq * (1.0 - 0.5 * blend)
        return cm0 + effectiveCmAlpha * alphaRad + cmDeltaE * elevatorFraction + effectiveCmq * qHat
    }

    /// Rolling moment coefficient: sideslip (dihedral) + aileron + roll-rate damping.
    func rollMoment(alphaRad: Float, betaRad: Float, aileronFraction: Float, pHat: Float) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let effectiveClp = clp * (1.0 - 0.5 * blend)
        return clBeta * betaRad + clDeltaA * aileronFraction + effectiveClp * pHat
    }

    /// Yawing moment coefficient: sideslip (weathercock) + rudder + yaw-rate damping.
    func yawMoment(alphaRad: Float, betaRad: Float, rudderFraction: Float, rHat: Float) -> Float {
        let blend = stallBlend(alphaRad: alphaRad)
        let effectiveCnBeta = cnBeta * (1.0 - 0.5 * blend)
        let effectiveCnr = cnr * (1.0 - 0.5 * blend)
        return effectiveCnBeta * betaRad + cnDeltaR * rudderFraction + effectiveCnr * rHat
    }

    static func build(
        family: FixedWingFamily,
        massKg: Float,
        wingSpanM: Float,
        fuselageLengthM: Float,
        heightM: Float,
        turnAuthority: Float,
        minSustainableSpeedMps: Float
    ) -> FixedWingAerodynamics {
        let preset = FamilyAeroPreset.preset(for: family)
        let span = max(0.3, wingSpanM)
        let fuselageLength = max(0.2, fuselageLengthM)
        let height = max(0.08, heightM)
        let mass = max(0.1, massKg)
        // No per-airframe prop size data is available; approximate from
        // span using a typical small-UAV prop-to-span ratio.
        let propRadius = (span * 0.035).clamped(to: 0.03...1.2)

        let clMaxAtStall = preset.cl0 + preset.clAlpha * preset.stallAlphaRad
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
        let stallSpeed = max(minSustainableSpeedMps, 3.0)
        let area = ((2.0 * mass * 9.81) / (1.225 * stallSpeed * stallSpeed * max(0.3, clMaxAtStall))).clamped(to: 0.05...400.0)
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

        let inertia = boxInertiaTensor(
            massKg: mass,
            wingSpanM: span,
            fuselageLengthM: fuselageLength,
            heightM: height
        )

        return FixedWingAerodynamics(
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
            cmq: preset.cmqBase * dampingScale,
            clBeta: preset.clBetaSlope,
            clDeltaA: preset.clDeltaA * turnGain,
            clp: preset.clpBase * dampingScale,
            cnBeta: preset.cnBetaSlope,
            cnDeltaR: preset.cnDeltaR * turnGain,
            cnr: preset.cnrBase * dampingScale,
            cyBeta: preset.cyBeta,
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
                cnBetaSlope: -0.08, cnDeltaR: 0.06, cnrBase: -0.12,
                cyBeta: -0.30,
                maxElevatorDeg: 24.0, maxAileronDeg: 20.0, maxRudderDeg: 18.0,
                torqueThrustRatio: 0.08, pFactorGain: 0.05, tailSlipstreamCoverage: 0.30
            )
        case .delta:
            return FamilyAeroPreset(
                cl0: 0.05, clAlpha: 3.0, stallAlphaRad: Float(23.0).fwDegreesToRadians,
                cd0: 0.028, oswaldEfficiency: 0.70, stallDragBump: 0.7,
                cm0: 0.0, cmAlpha: -0.35, cmDeltaE: 0.17, cmqBase: -5.0,
                clBetaSlope: 0.06, clDeltaA: 0.09, clpBase: -0.35,
                cnBetaSlope: -0.05, cnDeltaR: 0.05, cnrBase: -0.08,
                cyBeta: -0.22,
                maxElevatorDeg: 22.0, maxAileronDeg: 18.0, maxRudderDeg: 16.0,
                torqueThrustRatio: 0.06, pFactorGain: 0.03, tailSlipstreamCoverage: 0.20
            )
        case .swept:
            return FamilyAeroPreset(
                cl0: 0.18, clAlpha: 4.6, stallAlphaRad: Float(14.0).fwDegreesToRadians,
                cd0: 0.026, oswaldEfficiency: 0.75, stallDragBump: 1.2,
                cm0: 0.0, cmAlpha: -0.55, cmDeltaE: 0.16, cmqBase: -10.0,
                clBetaSlope: 0.09, clDeltaA: 0.10, clpBase: -0.40,
                cnBetaSlope: -0.10, cnDeltaR: 0.07, cnrBase: -0.14,
                cyBeta: -0.28,
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
                cnBetaSlope: -0.04, cnDeltaR: 0.045, cnrBase: -0.07,
                cyBeta: -0.18,
                maxElevatorDeg: 18.0, maxAileronDeg: 18.0, maxRudderDeg: 12.0,
                torqueThrustRatio: 0.05, pFactorGain: 0.02, tailSlipstreamCoverage: 0.15
            )
        case .conventionalSurvey:
            return FamilyAeroPreset(
                cl0: 0.22, clAlpha: 5.1, stallAlphaRad: Float(16.0).fwDegreesToRadians,
                cd0: 0.028, oswaldEfficiency: 0.80, stallDragBump: 1.0,
                cm0: 0.015, cmAlpha: -0.60, cmDeltaE: 0.19, cmqBase: -7.0,
                clBetaSlope: 0.09, clDeltaA: 0.115, clpBase: -0.42,
                cnBetaSlope: -0.085, cnDeltaR: 0.065, cnrBase: -0.11,
                cyBeta: -0.27,
                maxElevatorDeg: 22.0, maxAileronDeg: 20.0, maxRudderDeg: 18.0,
                torqueThrustRatio: 0.08, pFactorGain: 0.05, tailSlipstreamCoverage: 0.30
            )
        case .tailsitterVTOL:
            return FamilyAeroPreset(
                cl0: 0.20, clAlpha: 4.7, stallAlphaRad: Float(15.0).fwDegreesToRadians,
                cd0: 0.034, oswaldEfficiency: 0.72, stallDragBump: 1.0,
                cm0: 0.01, cmAlpha: -0.50, cmDeltaE: 0.15, cmqBase: -6.0,
                clBetaSlope: 0.08, clDeltaA: 0.10, clpBase: -0.40,
                cnBetaSlope: -0.07, cnDeltaR: 0.06, cnrBase: -0.10,
                cyBeta: -0.25,
                maxElevatorDeg: 20.0, maxAileronDeg: 18.0, maxRudderDeg: 16.0,
                torqueThrustRatio: 0.07, pFactorGain: 0.04, tailSlipstreamCoverage: 0.25
            )
        case .surveyEVTOL:
            return FamilyAeroPreset(
                cl0: 0.21, clAlpha: 4.9, stallAlphaRad: Float(15.5).fwDegreesToRadians,
                cd0: 0.030, oswaldEfficiency: 0.76, stallDragBump: 1.0,
                cm0: 0.012, cmAlpha: -0.55, cmDeltaE: 0.17, cmqBase: -6.5,
                clBetaSlope: 0.085, clDeltaA: 0.11, clpBase: -0.41,
                cnBetaSlope: -0.08, cnDeltaR: 0.06, cnrBase: -0.105,
                cyBeta: -0.26,
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
