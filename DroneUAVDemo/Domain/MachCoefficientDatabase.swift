import Foundation

/// A table of aerodynamic coefficients against angle of attack and Mach number.
///
/// Everything the simulation flew on until now came out of a closed-form model: a linear
/// lift slope with a stall knee, a parabolic drag polar, a constant pitching-moment
/// derivative, and a compressibility correction applied on top of all three. That model is
/// good, and it stays — it is what every airframe without a table still uses, unchanged.
///
/// What it cannot do is represent an aircraft whose coefficients are *shaped*. A slender
/// delta does not stall at a knee; it grows a leading-edge vortex that keeps adding lift
/// well past where a straight wing has given up, and then loses it gradually. A transonic
/// airframe's drag does not follow one curve scaled by a Mach factor; it has a bucket, a
/// rise, a peak just past Mach 1 and a decline after. A closed form fitted to any one of
/// those points is wrong at the others, and the aircraft this stage added spend their whole
/// flight moving between them.
///
/// So: a table. Two independent variables, three coefficients, bilinear interpolation,
/// clamped at the edges. Where one exists for an airframe it replaces the closed form
/// outright rather than correcting it, because a measured curve and a fitted curve should
/// not be averaged.
struct AeroCoefficientTable: Hashable {
    /// Angle-of-attack breakpoints, radians, ascending.
    let alphaBreakpointsRad: [Float]
    /// Mach breakpoints, ascending.
    let machBreakpoints: [Float]
    /// `[mach][alpha]`. Mach-major because a flight sweeps alpha far faster than Mach, so
    /// the inner row is the one that stays in cache.
    let liftCoefficient: [[Float]]
    let dragCoefficient: [[Float]]
    let pitchingMoment: [[Float]]
    /// Where the numbers came from. Carried with the data so that nobody has to guess
    /// later whether a curve was measured, computed or invented.
    let provenance: String

    /// Bilinear sample with edge clamping.
    ///
    /// Clamped rather than extrapolated. A table's edges are where the data ran out, and a
    /// linear extension of a curve that was already bending is a confident wrong answer;
    /// holding the last real value at least fails in a direction someone can recognise.
    func sample(alphaRad: Float, mach: Float) -> (cl: Float, cd: Float, cm: Float) {
        let (machLow, machHigh, machFraction) = bracket(machBreakpoints, mach)
        let (alphaLow, alphaHigh, alphaFraction) = bracket(alphaBreakpointsRad, alphaRad)

        func blend(_ grid: [[Float]]) -> Float {
            let low = mix(grid[machLow][alphaLow], grid[machLow][alphaHigh], alphaFraction)
            let high = mix(grid[machHigh][alphaLow], grid[machHigh][alphaHigh], alphaFraction)
            return mix(low, high, machFraction)
        }

        return (blend(liftCoefficient), blend(dragCoefficient), blend(pitchingMoment))
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    private func bracket(_ points: [Float], _ value: Float) -> (Int, Int, Float) {
        guard points.count > 1 else { return (0, 0, 0.0) }
        if value <= points[0] { return (0, 0, 0.0) }
        if value >= points[points.count - 1] {
            let last = points.count - 1
            return (last, last, 0.0)
        }
        var index = 0
        while index + 1 < points.count && points[index + 1] < value { index += 1 }
        let span = points[index + 1] - points[index]
        let fraction = span > 1.0e-6 ? (value - points[index]) / span : 0.0
        return (index, index + 1, fraction)
    }

    /// Is the table self-consistent enough to fly on?
    ///
    /// Checked rather than assumed, because the whole point of this type is that its
    /// contents come from outside the code — a hand-typed table with a transposed grid or a
    /// breakpoint out of order would otherwise fail as a strange handling quirk rather than
    /// as the data error it is.
    var isWellFormed: Bool {
        guard alphaBreakpointsRad.count >= 2, machBreakpoints.count >= 2 else { return false }
        guard zip(alphaBreakpointsRad, alphaBreakpointsRad.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(machBreakpoints, machBreakpoints.dropFirst()).allSatisfy({ $0 < $1 }) else {
            return false
        }
        for grid in [liftCoefficient, dragCoefficient, pitchingMoment] {
            guard grid.count == machBreakpoints.count else { return false }
            for row in grid where row.count != alphaBreakpointsRad.count { return false }
            for row in grid where row.contains(where: { !$0.isFinite }) { return false }
        }
        return true
    }
}

/// Which airframes have tabulated coefficients, and where they come from.
///
/// A registry rather than a field on the profile, for two reasons. Tables are large and
/// most airframes do not have one, so carrying an optional on every profile would be mostly
/// empty. And a table is *data about* an aircraft rather than part of its identity — it can
/// be improved, replaced or generated offline without the aircraft itself changing, which
/// is exactly what a data pipeline needs.
///
/// Lookup is by profile identifier first, then by family. An airframe with its own measured
/// curves uses them; one without falls back to whatever its planform class has; one whose
/// class has nothing falls back to the closed-form model, which is what the entire existing
/// catalogue does and will keep doing, unchanged.
enum MachCoefficientDatabase {
    private static var profileTables: [String: AeroCoefficientTable] = [:]
    private static var familyTables: [FixedWingFamily: AeroCoefficientTable] = seededFamilyTables()

    /// Installs a table for one airframe, replacing any already present.
    ///
    /// The gate is deliberate: a malformed table is rejected here, once, at the point it is
    /// introduced, rather than producing nonsense in flight. `@discardableResult` because
    /// most callers are seeding known-good data; a pipeline importing files should check.
    @discardableResult
    static func register(profileID: String, table: AeroCoefficientTable) -> Bool {
        guard table.isWellFormed else {
            print("[Aero] rejected malformed coefficient table for \(profileID)")
            return false
        }
        profileTables[profileID] = table
        return true
    }

    @discardableResult
    static func register(family: FixedWingFamily, table: AeroCoefficientTable) -> Bool {
        guard table.isWellFormed else {
            print("[Aero] rejected malformed coefficient table for family \(family)")
            return false
        }
        familyTables[family] = table
        return true
    }

    static func table(profileID: String?, family: FixedWingFamily) -> AeroCoefficientTable? {
        if let profileID, let table = profileTables[profileID] { return table }
        return familyTables[family]
    }

    /// Every table currently installed, for the diagnostics view and for tests.
    static func inventory() -> [(key: String, provenance: String)] {
        let profiles = profileTables.map { (key: $0.key, provenance: $0.value.provenance) }
        let families = familyTables.map { (key: "family:\($0.key)", provenance: $0.value.provenance) }
        return (profiles + families).sorted { $0.key < $1.key }
    }

    // MARK: - Seeded tables

    /// The tables that ship with the simulation.
    ///
    /// Only the delta planforms, and only because a delta is the one case where the
    /// closed-form model is not merely imprecise but the wrong shape. Everything else in the
    /// catalogue is a straight or moderately swept wing, which is what the linear-plus-knee
    /// model was built for and describes well.
    private static func seededFamilyTables() -> [FixedWingFamily: AeroCoefficientTable] {
        var tables: [FixedWingFamily: AeroCoefficientTable] = [:]
        // Only the two supersonic delta classes, and the omission of the other two is the
        // point. `.delta` and `.blendedWingBody` are flown today by aircraft whose wing area
        // was solved backwards from the closed form's own CLmax so that each would stall at
        // its published speed. Swapping the lift curve underneath that calibration does not
        // improve those aircraft, it un-calibrates them — the area no longer corresponds to
        // the curve it was derived from, and every one of them changes stall speed. Moving
        // them across is a re-calibration, not a data change, and it belongs on its own.
        //
        // The two supersonic classes have no such history: they were introduced this stage
        // and their areas are solved against whichever curve is installed, so a table costs
        // them nothing. The generator below is public precisely so the other two can be
        // brought over when someone is prepared to re-verify their stall speeds.
        let deltas: [(FixedWingFamily, Float, Float, String)] = [
            (.supersonicDelta, 60.0, 2.2, "Polhamus analogy, 60 deg sweep, thin supersonic section"),
            (.canardDelta, 58.0, 2.4, "Polhamus analogy, 58 deg sweep, close-coupled canard")
        ]
        for (family, sweepDeg, aspectRatio, provenance) in deltas {
            let table = polhamusDeltaTable(
                family: family,
                leadingEdgeSweepDeg: sweepDeg,
                aspectRatio: aspectRatio,
                provenance: provenance
            )
            if table.isWellFormed {
                tables[family] = table
            }
        }
        return tables
    }

    /// Builds a delta wing's coefficients from the leading-edge suction analogy.
    ///
    /// Polhamus's result is that a sharp-edged slender wing's lift has two parts. The
    /// potential-flow part behaves like any wing's, `Kp * sin(a) * cos^2(a)`. The second
    /// part is the leading-edge vortex: flow that separates at the sharp edge and rolls into
    /// a stable vortex sitting over the upper surface, whose suction contributes
    /// `Kv * sin^2(a) * cos(a)`. Because the vortex term is quadratic in alpha it is
    /// negligible at cruise and dominant at high alpha, which is why a delta keeps gaining
    /// lift to 30 degrees and beyond where a straight wing has stalled at 15.
    ///
    /// That behaviour is the reason for this whole file. A closed-form stall knee fitted to
    /// a delta either stalls it far too early or never stalls it at all; neither is the
    /// aircraft. Vortex breakdown is put in by hand as a decay past the burst angle, since
    /// the analogy itself says nothing about where the vortex fails.
    ///
    /// Drag follows from the same decomposition — a vortex is lift bought with drag, and the
    /// suction force acts normal to the wing rather than forward, so induced drag is
    /// `CL * tan(a)` rather than the attached-flow `CL^2 / (pi * AR * e)`.
    static func polhamusDeltaTable(
        family: FixedWingFamily,
        leadingEdgeSweepDeg: Float,
        aspectRatio: Float,
        provenance: String
    ) -> AeroCoefficientTable {
        let alphas: [Float] = stride(from: Float(-12.0), through: 40.0, by: 2.0)
            .map { $0 * .pi / 180.0 }
        let machs: [Float] = [0.0, 0.3, 0.6, 0.8, 0.9, 0.95, 1.05, 1.2, 1.6, 2.0, 2.5, 3.0]

        let sweepRad = leadingEdgeSweepDeg * .pi / 180.0
        // Potential-flow constant: this wing's own lift-curve slope, per radian.
        //
        // The slender-wing limit `pi*AR/2` is the wrong number here and it is wrong by a
        // lot — at the aspect ratios in this catalogue it overstates the slope by about
        // three quarters, which sizes the wing at two thirds of its real area and then lets
        // the aircraft fly at half again its published top speed. What Polhamus's analogy
        // actually calls for is the wing's potential-flow slope, which for a finite aspect
        // ratio is the DATCOM/Helmbold form below.
        //
        // Half-chord sweep from the leading-edge sweep for a pure delta, whose taper ratio
        // is zero: `tan(L_half) = tan(L_LE) - 2/AR`.
        let tanHalfChordSweep = max(0.0, tan(sweepRad) - 2.0 / max(0.5, aspectRatio))
        let kp = 2.0 * Float.pi * aspectRatio
            / (2.0 + sqrt(aspectRatio * aspectRatio * (1.0 + tanHalfChordSweep * tanHalfChordSweep) + 4.0))
        // Vortex constant, from Polhamus's own relation to the potential term rather than
        // from its slender limit — the suction that would have acted forward on a rounded
        // leading edge is what reappears as normal force when the edge is sharp. For the
        // sweeps here this lands on the 3.0-3.5 the paper tabulates.
        let kv = kp * max(0.0, 1.0 - kp / (Float.pi * max(0.5, aspectRatio))) / cos(sweepRad)
        // Where the vortex bursts over the trailing edge and the lift starts to go. Sharper
        // sweeps hold their vortex to higher angles — that is the trade a delta makes.
        let burstAlphaRad = (18.0 + leadingEdgeSweepDeg * 0.28) * .pi / 180.0

        let zeroLiftDrag: Float = family == .supersonicDelta ? 0.0135 : 0.0175

        var cl: [[Float]] = []
        var cd: [[Float]] = []
        var cm: [[Float]] = []

        for mach in machs {
            // Compressibility on the potential term only. The vortex term is a separated-flow
            // phenomenon and does not follow Prandtl-Glauert; supersonically the potential
            // term goes over to the Ackeret slope.
            let potentialScale: Float
            if mach < 0.75 {
                potentialScale = 1.0 / sqrt(max(0.25, 1.0 - mach * mach))
            } else if mach < 1.15 {
                // Through the transonic the slope peaks and then falls; a linear theory has
                // nothing to say here and the shape is taken from the measured behaviour of
                // thin delta sections.
                potentialScale = 1.45 - (mach - 0.75) * 0.85
            } else {
                let ackeret = 4.0 / sqrt(max(0.05, mach * mach - 1.0))
                potentialScale = min(1.35, ackeret / (2.0 * Float.pi) * 2.0)
            }
            // The vortex weakens and then disappears as the leading edge goes supersonic:
            // once the flow normal to the edge is supersonic it attaches to a shock instead
            // of rolling up.
            let normalMach = mach * cos(sweepRad)
            let vortexScale = (1.0 - (normalMach - 0.7) / 0.5).clamped(to: 0.0...1.0)

            // Wave drag: none below the divergence Mach, a fourth-power rise through it, a
            // peak just past Mach 1, then the slow decline of supersonic wave drag.
            let waveDrag: Float
            let divergence: Float = family == .supersonicDelta ? 0.95 : 0.82
            if mach < divergence {
                waveDrag = 0.0
            } else if mach < 1.1 {
                let rise = (mach - divergence) / max(0.05, 1.1 - divergence)
                waveDrag = 0.030 * rise * rise * rise * rise
            } else {
                waveDrag = 0.030 * (1.1 / mach)
            }

            var clRow: [Float] = []
            var cdRow: [Float] = []
            var cmRow: [Float] = []
            for alpha in alphas {
                let sinA = sin(alpha)
                let cosA = cos(alpha)
                let potential = kp * sinA * cosA * cosA * potentialScale
                var vortex = kv * sinA * abs(sinA) * cosA * vortexScale
                // Vortex breakdown. Past the burst angle the vortex leaves the wing from the
                // trailing edge forward and its contribution decays; the potential term is
                // untouched, which is why a delta's lift falls away rather than dropping.
                if abs(alpha) > burstAlphaRad {
                    let past = (abs(alpha) - burstAlphaRad) / (0.45)
                    vortex *= max(0.0, 1.0 - past * past)
                }
                let liftCoefficient = potential + vortex
                clRow.append(liftCoefficient)

                // Induced drag from the suction analogy: the vortex's force is normal to the
                // surface, so the whole lift vector is tilted back by alpha rather than by
                // the smaller attached-flow induced angle.
                let attachedInduced = liftCoefficient * liftCoefficient
                    / (Float.pi * aspectRatio * 0.85)
                let vortexInduced = abs(liftCoefficient * tan(min(abs(alpha), 1.2)))
                let vortexShare = (abs(alpha) / burstAlphaRad).clamped(to: 0.0...1.0)
                let induced = attachedInduced * (1.0 - vortexShare) + vortexInduced * vortexShare
                cdRow.append(zeroLiftDrag + waveDrag + induced)

                // Pitching moment about the quarter-chord. The vortex acts aft of the
                // potential centre of pressure, so a delta pitches down as the vortex builds
                // and then up again when it bursts — the pitch-up that gives deltas their
                // reputation. Supersonically the whole centre of pressure moves aft, which
                // the Mach term carries.
                let vortexMoment = -vortex * 0.055
                let supersonicShift = mach > 1.0 ? -liftCoefficient * 0.13 : 0.0
                var moment = -0.035 * liftCoefficient + vortexMoment + supersonicShift
                if abs(alpha) > burstAlphaRad {
                    let past = ((abs(alpha) - burstAlphaRad) / 0.45).clamped(to: 0.0...1.0)
                    moment += 0.085 * past * (alpha > 0.0 ? 1.0 : -1.0)
                }
                cmRow.append(moment)
            }
            cl.append(clRow)
            cd.append(cdRow)
            cm.append(cmRow)
        }

        return AeroCoefficientTable(
            alphaBreakpointsRad: alphas,
            machBreakpoints: machs,
            liftCoefficient: cl,
            dragCoefficient: cd,
            pitchingMoment: cm,
            provenance: provenance
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
