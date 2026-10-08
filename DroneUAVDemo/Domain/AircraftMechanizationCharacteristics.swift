import Foundation
import simd

/// How the flap is built. This is the part of an airframe's high-lift system that its
/// planform does not give away, so it is recorded per airframe below.
enum AircraftFlapType: String, Decodable {
    /// A hinged trailing edge. The flow leaves it early, so each further degree buys less.
    case plain
    /// The slot re-energises the flow over the flap and keeps it attached to larger angles.
    case singleSlotted
    /// A slotted flap that also travels aft, adding chord as it comes down.
    case fowler

    /// Share of the thin-aerofoil lift a real flap delivers at a deflection, radians.
    ///
    /// Plain: McCormick, *Aerodynamics, Aeronautics and Flight Mechanics*, fig. 3.33 — about
    /// 0.8 at 10° falling to under 0.5 at 40°. Slotted flaps hold the flow on, so their loss is
    /// roughly half as steep (Abbott & von Doenhoff, slotted-flap sections).
    func effectiveness(deflectionRad: Float) -> Float {
        let degrees = abs(deflectionRad) * 180 / .pi
        let table = self == .plain ? Self.plainEffectiveness : Self.slottedEffectiveness
        return table.sample(degrees)
    }

    /// Profile-drag constant of `ΔCD₀ = k·(c_f/c)^1.38·(S_f/S)·sin²δ` (Raymer, *Aircraft
    /// Design*, eq. 12.61): 1.7 for plain and split flaps, 0.9 for slotted ones.
    var profileDragFactor: Float { self == .plain ? 1.7 : 0.9 }

    /// Aft travel at full deflection, in flap chords. A Fowler flap ends up roughly 60 % of its
    /// own chord behind where it started (Torenbeek, *Synthesis of Subsonic Airplane Design*, G-2).
    var chordExtension: Float { self == .fowler ? 0.6 : 0 }

    private static let plainEffectiveness = BreakpointTable1D([(0, 1.0), (10, 0.80), (20, 0.67), (30, 0.56), (40, 0.47), (60, 0.38)])
    private static let slottedEffectiveness = BreakpointTable1D([(0, 1.0), (10, 0.95), (20, 0.88), (30, 0.80), (40, 0.70), (60, 0.55)])
}

/// What one airframe's flaps and undercarriage do to it.
///
/// Derived from that airframe's own wing, mass, stall speed and leg geometry, so no two
/// aircraft share a number here unless they share the aircraft. Where a quantity is fixed by
/// an airworthiness rule rather than by the designer, the rule is used and named; where it is
/// an estimate, the comment says what it was fitted to.
struct AircraftMechanizationCharacteristics {
    /// The lever's middle position, as a share of full travel: the usual takeoff detent.
    static let takeoffFlapSetting: Float = 0.5

    // MARK: Flaps

    let flapType: AircraftFlapType
    /// Flap chord over wing chord.
    let flapChordRatio: Float
    /// Share of the wing area that lies ahead of the flaps.
    let flappedAreaRatio: Float
    let flapMaxRad: Float
    /// Main-wing panels as measured from the authored mesh, including boom/nacelle gaps.
    let flapPanels: [AircraftMechanizationConfiguration.FlapGeometry.Panel]
    /// Lift-curve slope of this wing, per radian, from its own aspect ratio.
    let liftSlope: Float
    let aspectRatio: Float
    /// Thin-aerofoil flap effectiveness `τ` for this chord ratio.
    let flapTheoreticalEffectiveness: Float
    /// `ΔCm/ΔCL` of lowering the flaps (negative: nose down): the flap's own lift acting aft of
    /// the quarter chord, less what the deeper downwash on the tail gives back.
    let flapPitchRatio: Float
    /// Spanwise centroid of one panel, as a fraction of the span (0…0.5).
    let flapLateralArm: Float
    /// One panel's own area over the wing area — what the wing loses with the panel.
    let flapPanelAreaRatio: Float
    let flapTravelSeconds: Float
    /// VFE at full deflection, equivalent airspeed.
    let flapLimitSpeedMps: Float
    let flapLimitDynamicPressurePa: Float
    let stallSpeedCleanMps: Float
    let stallSpeedFlapsMps: Float
    /// Maximum lift coefficient of the clean wing, the one the stall speed is calibrated to.
    let maximumLiftClean: Float

    // MARK: Undercarriage

    /// Extended legs and wheels, as a drag coefficient on the wing area.
    let gearDragCoefficient: Float
    /// Open wells: while the doors are open, and for good once they are gone.
    let gearWellDragCoefficient: Float
    let gearTravelSeconds: Float
    let doorTravelSeconds: Float
    /// VLO and VLE, equivalent airspeed.
    let gearLimitSpeedMps: Float
    let gearLimitDynamicPressurePa: Float

    let wingAreaM2: Float
    let wingSpanM: Float
    let designMassKg: Float

    // MARK: - Aerodynamic increments

    /// Lift coefficient both panels add at a drive position, in attached flow.
    func flapLift(deployment: Float) -> Float {
        guard !flapPanels.isEmpty else {
            return Self.flapLift(type: flapType, liftSlope: liftSlope, theoretical: flapTheoreticalEffectiveness,
                chordRatio: flapChordRatio, flappedArea: flappedAreaRatio, maxRad: flapMaxRad, deployment: deployment)
        }
        return flapPanels.reduce(0) { total, panel in
            let theta = acos(2*panel.chordRatio-1)
            let tau = 1-(theta-sin(theta)) / .pi
            return total + Self.flapLift(type: flapType, liftSlope: liftSlope, theoretical: tau,
                chordRatio: panel.chordRatio, flappedArea: panel.coveredAreaFraction,
                maxRad: flapMaxRad, deployment: deployment)
        }
    }

    /// `ΔCL = CLα·τ·η(δ)·δ·(S_f/S)`, times the chord a Fowler flap adds as it travels.
    private static func flapLift(type: AircraftFlapType, liftSlope: Float, theoretical: Float,
                                 chordRatio: Float, flappedArea: Float, maxRad: Float,
                                 deployment: Float) -> Float {
        let delta = deployment * maxRad
        let chordGrowth = 1 + type.chordExtension * chordRatio * deployment
        return liftSlope * theoretical * type.effectiveness(deflectionRad: delta) * delta
            * flappedArea * chordGrowth
    }

    /// Stall speed at design weight with the flaps at a drive position.
    func stallSpeed(deployment: Float) -> Float {
        stallSpeedCleanMps * sqrt(maximumLiftClean / (maximumLiftClean + max(0, flapLift(deployment: deployment))))
    }

    /// Profile drag both panels add. Induced drag on the extra lift is charged by the polar.
    func flapDrag(deployment: Float) -> Float {
        let s = sin(deployment * flapMaxRad)
        let area = flapPanels.isEmpty ? pow(flapChordRatio, 1.38)*flappedAreaRatio
            : flapPanels.reduce(Float(0)) { $0 + pow($1.chordRatio, 1.38)*$1.coveredAreaFraction }
        return flapType.profileDragFactor * area * s * s
    }

    /// Everything the mechanization adds to the polar and the moments at this instant.
    func aeroIncrements(state: AircraftMechanizationState, hasFlaps: Bool, retractableGear: Bool)
        -> FixedWingMechanizationIncrements {
        var result = FixedWingMechanizationIncrements()
        if hasFlaps {
            let lift = flapLift(deployment: state.flapDeployment) * 0.5
            let drag = flapDrag(deployment: state.flapDeployment) * 0.5
            let left = state.flapPanelHealth.x > 0.5, right = state.flapPanelHealth.y > 0.5
            result.flapLiftLeft = left ? lift : 0
            result.flapLiftRight = right ? lift : 0
            result.flapDragLeft = left ? drag : 0
            result.flapDragRight = right ? drag : 0
            // A panel that has gone took its share of the wing with it.
            result.lostAreaLeft = left ? 0 : flapPanelAreaRatio
            result.lostAreaRight = right ? 0 : flapPanelAreaRatio
            result.flapPitchRatio = flapPitchRatio
            result.lateralArm = flapLateralArm
        }
        if retractableGear {
            let wells = state.gearDoorsLost ? 1 : state.gearDoorOpening
            result.gearDrag = gearDragCoefficient * state.gearExtension + gearWellDragCoefficient * wells
        }
        return result
    }

    // MARK: - Per-airframe design records

    /// Flap construction by airframe. Representative, not manufacturer data: the Heron wing
    /// and its slotted flap are documented, as are the Avanti's Fowler flaps the P.1HH
    /// inherits; the tactical airframes are recorded as plain flaps, the simplest hinge that
    /// fits their size, until something better is known.
    static let flapTypes: [String: AircraftFlapType] = [
        "tekever-ar5": .plain,
        "aeronautics-aerostar": .plain,
        "elbit-hermes-450": .plain,
        "leonardo-falco-evo": .plain,
        "leonardo-falco-xplorer": .singleSlotted,
        "iai-heron-mk-ii": .singleSlotted,
        "iai-heron-tp": .singleSlotted,
        "piaggio-p1hh-hammerhead": .fowler
    ]

    /// Airframes whose flaps are geared to a second surface that cancels their trim change.
    /// The P.1HH keeps the Avanti's forward wing, whose own flap comes down with the main
    /// ones for exactly this purpose.
    static let trimCompensatedFlaps: Set<String> = ["piaggio-p1hh-hammerhead"]

    /// Compatibility for explicit old configurations used by third-party builds/probes.
    /// The shipped expansion uses its measured panel geometry instead.
    private static let legacyFlappedArea: Float = 0.33
    private static let legacyFlapChord: Float = 0.28

    // MARK: - Derivation

    static func resolve(configuration: AircraftMechanizationConfiguration, profile: DroneModelProfile,
                        uav: UAVProfile?, modelGroundLift: Float) -> AircraftMechanizationCharacteristics? {
        guard let wing = profile.fixedWingParameters else { return nil }
        let uav = uav ?? profile.resolvedUAVProfile
        let dimensions = uav?.dimensions
        let spanMm = dimensions?.wingspanMillimeters ?? profile.dimensionsUnfoldedMm.x
        let designMass = max(0.1, uav.flatMap { $0.maxTakeoffMass ?? $0.estimatedMaxTakeoffMass } ?? profile.takeoffMassKg)
        // The same wing the solver flies: its area is calibrated to this stall speed and mass.
        let aero = FixedWingAerodynamics.build(
            family: wing.family, massKg: designMass, wingSpanM: spanMm / 1000,
            fuselageLengthM: (dimensions?.fuselageLengthMillimeters ?? spanMm * 0.55) / 1000,
            heightM: (dimensions?.heightMillimeters ?? spanMm * 0.12) / 1000,
            turnAuthority: wing.turnAuthority, minSustainableSpeedMps: wing.minSustainableSpeedMps,
            designMassKg: designMass, profileID: profile.id, engineering: profile.engineeringAerodynamics)
        return resolve(configuration: configuration, profileID: profile.id, aero: aero,
                       stallSpeedMps: wing.minSustainableSpeedMps, designMassKg: designMass,
                       modelGroundLift: modelGroundLift)
    }

    /// The same derivation from the wing itself, for callers that have no runtime profile yet —
    /// the catalogue works out an airframe's takeoff figures before the profile exists.
    static func resolve(configuration: AircraftMechanizationConfiguration, profileID: String,
                        aero: FixedWingAerodynamics, stallSpeedMps: Float, designMassKg designMass: Float,
                        modelGroundLift: Float) -> AircraftMechanizationCharacteristics? {
        let spanMm = aero.wingSpan * 1000
        // Lift-curve slope of this wing from its own aspect ratio (Helmbold): a flap turns a
        // section's zero-lift angle, and what the whole wing makes of that is its 3-D slope.
        // The family polar's slope is one number per family and would give every member of
        // it the same flap.
        let aspectRatio = aero.wingSpan * aero.wingSpan / max(0.05, aero.wingArea)
        let liftSlope = 2 * Float.pi * aspectRatio / (2 + sqrt(4 + aspectRatio * aspectRatio))
        let maximumLift = max(0.3, aero.liftDrag(alphaRad: aero.stallAlphaRad).cl)
        let rho = AtmosphereModel.seaLevelDensity
        let stall = max(3, stallSpeedMps)

        // --- Flaps.
        let geometry = configuration.flapGeometry
        let panels = geometry?.panels.filter {
            $0.chordRatio > 0 && $0.chordRatio < 1 && $0.coveredAreaFraction > 0 && $0.coveredAreaFraction < 1
                && $0.panelAreaFraction > 0 && $0.lateralArm >= 0 && $0.lateralArm <= 0.5
        } ?? []
        let type = geometry?.type ?? flapTypes[profileID] ?? .plain
        let flappedArea = panels.isEmpty ? legacyFlappedArea : panels.reduce(0) { $0+$1.coveredAreaFraction }
        let panelArea = panels.isEmpty ? legacyFlapChord*legacyFlappedArea : panels.reduce(0) { $0+$1.panelAreaFraction }
        let chordRatio = panelArea/flappedArea
        // Thin-aerofoil theory for a flap of chord ratio E, with θ_f = acos(2E − 1):
        // τ = 1 − (θ_f − sin θ_f)/π, and Δcm(c/4)/Δcl = −sin θ_f·(1 − cos θ_f) / 4(π − θ_f + sin θ_f).
        let theta = acos(2 * chordRatio - 1)
        let tau = 1 - (theta - sin(theta)) / .pi
        let wingPitchRatio: Float
        if panels.isEmpty {
            wingPitchRatio = -sin(theta) * (1-cos(theta)) / (4*(.pi-theta+sin(theta)))
        } else {
            var totalLift: Float = 0
            var totalMoment: Float = 0
            for panel in panels {
                let t = acos(2*panel.chordRatio-1)
                let panelTau = 1-(t-sin(t)) / .pi
                let lift = panelTau*panel.coveredAreaFraction
                totalLift += lift
                totalMoment += lift * (-sin(t)*(1-cos(t))/(4*(.pi-t+sin(t))))
            }
            wingPitchRatio = totalMoment/max(0.0001,totalLift)
        }
        // The flaps' lift also deepens the downwash at the tail, which answers nose-up. The
        // same downwash is why the tail gives less than its full stability, so the airframe's
        // own `cmAlpha` sizes the relief: ΔCm = |Cmα|·κ/(1 − κ)·ΔCL/CLα, with κ = dε/dα = 2·CLα/πA.
        let downwashSlope = min(0.6, 2 * liftSlope / (.pi * aspectRatio))
        let tailRelief = abs(aero.cmAlpha) * downwashSlope / (1 - downwashSlope) / liftSlope
        let pitchRatio = trimCompensatedFlaps.contains(profileID) ? 0 : wingPitchRatio + tailRelief
        let flapMax = max(0, configuration.flapMaxDegrees) * .pi / 180

        // Flap limit speed, CS-23.335(e)/23.345: not less than 1.4·VS (clean) nor 1.8·VSF
        // (flaps fully down), both at design weight.
        let flapsDownLift: Float
        if !configuration.hasFlaps { flapsDownLift = 0 }
        else if panels.isEmpty {
            flapsDownLift = flapLift(type: type, liftSlope: liftSlope, theoretical: tau,
                chordRatio: chordRatio, flappedArea: flappedArea, maxRad: flapMax, deployment: 1)
        } else {
            flapsDownLift = panels.reduce(0) { total, panel in
                let t = acos(2*panel.chordRatio-1)
                return total + flapLift(type: type, liftSlope: liftSlope, theoretical: 1-(t-sin(t)) / .pi,
                    chordRatio: panel.chordRatio, flappedArea: panel.coveredAreaFraction, maxRad: flapMax, deployment: 1)
            }
        }
        let stallFlaps = stall * sqrt(maximumLift / (maximumLift + flapsDownLift))
        let flapLimit = max(1.4 * stall, 1.8 * stallFlaps)
        // Undercarriage: FAR 23.729(a)(2) has the retraction mechanism carry its air loads at
        // any speed up to 1.6·VS1, and that minimum is the limit taken here for VLO and VLE.
        let gearLimit = 1.6 * stall

        // --- Undercarriage drag, from each leg's own load and length.
        var gearDragArea: Float = 0
        if configuration.retractableGear {
            let hinges = configuration.gearHinges.prefix(4).filter { $0.center.count == 3 }
            let halfSpan = max(0.1, spanMm / 2000)
            let centreline = hinges.filter { abs($0.center[0]) < 0.05 * halfSpan }.count
            let mains = hinges.count - centreline
            for hinge in hinges {
                let onCentreline = abs(hinge.center[0]) < 0.05 * halfSpan
                // Static balance of a tricycle: about a tenth of the weight on the nose leg.
                let share: Float = centreline == 0 || mains == 0
                    ? 1 / Float(hinges.count)
                    : (onCentreline ? 0.10 / Float(centreline) : 0.90 / Float(mains))
                let wheelLoadKg = designMass * share
                // Statistical tyre size from the load it carries (Raymer, *Aircraft Design*,
                // table 11.1, general aviation, metric form: centimetres from kilograms).
                let tyreDiameter = 0.051 * pow(wheelLoadKg, 0.349)
                let tyreWidth = 0.023 * pow(wheelLoadKg, 0.312)
                // Oleo diameter for an 1800 psi strut (Raymer, eq. 11.13).
                let strutDiameter = 1.3 * sqrt(4 * wheelLoadKg * 9.81 / (Float.pi * 12.4e6))
                // The leg the model actually has: hinge height down to the top of the tyre.
                let strutLength = max(0, hinge.center[1] + modelGroundLift - tyreDiameter)
                // Drag areas per frontal area (Raymer, table 12.5): wheel and tyre 0.25, round
                // strut 0.30; 20 % on the sum for mutual interference.
                gearDragArea += 1.2 * (0.25 * tyreDiameter * tyreWidth + 0.30 * strutLength * strutDiameter)
            }
        }
        let gearDrag = gearDragArea / max(0.05, aero.wingArea)
        // Light retractables cycle in 6–7 s (Cessna 172RG, Piper Arrow) and transports in
        // 10–15 s: a weak dependence on size, anchored at one tonne.
        let gearTravel = (6.0 * pow(designMass / 1000, 0.2)).clamped(to: 2...15)

        return AircraftMechanizationCharacteristics(
            flapType: type, flapChordRatio: chordRatio, flappedAreaRatio: flappedArea,
            flapMaxRad: flapMax, flapPanels: panels, liftSlope: liftSlope, aspectRatio: aspectRatio,
            flapTheoreticalEffectiveness: tau,
            flapPitchRatio: pitchRatio,
            flapLateralArm: panels.isEmpty ? 0.1725 : panels.reduce(0) { $0+$1.lateralArm*$1.coveredAreaFraction }/flappedArea,
            flapPanelAreaRatio: panelArea / 2,
            // Fitted to two aircraft whose flap times are well known and far apart in size:
            // about 9 s for a 1.1 t Cessna 172 and 15 s for a 5.2 t P.180. A screw-jack's speed
            // falls with the hinge moment it holds, which grows faster than the airframe.
            flapTravelSeconds: (3.0 * pow(designMass / 100, 0.4)).clamped(to: 0.6...25),
            flapLimitSpeedMps: flapLimit, flapLimitDynamicPressurePa: 0.5 * rho * flapLimit * flapLimit,
            stallSpeedCleanMps: stall, stallSpeedFlapsMps: stallFlaps, maximumLiftClean: maximumLift,
            gearDragCoefficient: gearDrag,
            // Open wells add 7 % to the undercarriage's drag (Raymer, section 12.5).
            gearWellDragCoefficient: gearDrag * 0.07,
            gearTravelSeconds: gearTravel,
            // Doors are small panels on short jacks: a fifth of the leg's time each way.
            doorTravelSeconds: gearTravel * 0.2,
            gearLimitSpeedMps: gearLimit, gearLimitDynamicPressurePa: 0.5 * rho * gearLimit * gearLimit,
            wingAreaM2: aero.wingArea, wingSpanM: aero.wingSpan, designMassKg: designMass)
    }
}

/// The mechanization's contribution to one evaluation of the polar and the moments.
/// All zero for an airframe with nothing deployed, which leaves every coefficient untouched.
struct FixedWingMechanizationIncrements {
    var flapLiftLeft: Float = 0
    var flapLiftRight: Float = 0
    var flapDragLeft: Float = 0
    var flapDragRight: Float = 0
    var lostAreaLeft: Float = 0
    var lostAreaRight: Float = 0
    var flapPitchRatio: Float = 0
    var lateralArm: Float = 0
    var gearDrag: Float = 0

    var isNeutral: Bool {
        flapLiftLeft == 0 && flapLiftRight == 0 && flapDragLeft == 0 && flapDragRight == 0
            && lostAreaLeft == 0 && lostAreaRight == 0 && gearDrag == 0
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
