import Foundation

/// Compressibility corrections applied on top of a low-speed coefficient set.
///
/// This is the *fallback*, and the distinction matters. Where an airframe has real
/// wind-tunnel or flight-derived coefficients over a Mach grid, those tables are the
/// truth and this model must not be consulted; the plan is explicit that a synthetic
/// curve must never stand in for published data on a reference aircraft. What this
/// gives is a physically-shaped, continuous and bounded answer for every profile that
/// has no such tables — which today is all of them.
///
/// Three things change between Mach 0.3 and Mach 4, and all three are here:
///
///  - **Lift slope.** Prandtl–Glauert growth through the subsonic range, then the
///    supersonic collapse of linearised theory, `CL_α = 4/√(M²−1)`.
///  - **Drag.** Wave drag appears once the flow goes locally supersonic, rises very
///    steeply, peaks just past Mach 1 and then falls away.
///  - **Balance.** The aerodynamic centre moves aft from roughly the quarter chord to
///    roughly the half chord, which trims the aircraft nose-down and changes its
///    static margin. Without this an aircraft crosses Mach 1 holding its old trim as
///    though nothing had happened, which is precisely the failure the plan names.
///
/// **Nothing here fires below Mach 0.3.** Every correction is identically 1.0 (or 0.0)
/// there, so every subsonic aircraft in the catalogue flies exactly as it did. Above
/// it, corrections fade in over a band rather than switching on, because a step in a
/// force coefficient is a step in an acceleration.
struct TransonicAeroModel: Hashable {
    /// Below this Mach number nothing in this type does anything. The plan's
    /// "legacy equivalence up to M~0.3" is enforced here, once, rather than being
    /// remembered at each call site.
    static let legacyEquivalenceMach: Float = 0.30
    /// Width of the band over which the subsonic correction fades in.
    private static let fadeInWidth: Float = 0.15

    /// Free-stream Mach at which the flow first goes sonic somewhere on the airframe.
    /// Below it there is no wave drag at all.
    let criticalMach: Float
    /// Where the drag rise becomes steep. Conventionally the Mach at which
    /// `dCD/dM = 0.1`; used here as the shape parameter it is.
    let dragDivergenceMach: Float
    /// Wave-drag increment on CD at the peak, for a wing carrying no lift. The single
    /// number that says how much a given planform hates going transonic: a thin
    /// slender delta pays a fraction of what a thick straight wing pays.
    let waveDragPeak: Float
    /// How far aft the aerodynamic centre ends up supersonically, as a fraction of the
    /// mean chord. Around 0.25 for a conventional wing — quarter chord to half chord.
    let supersonicAeroCenterShift: Float

    /// Mach at which wave drag peaks. Just past the drag-divergence point, which is
    /// where a real drag curve turns over.
    var peakDragMach: Float { dragDivergenceMach + 0.15 }

    /// Multiplier on the low-speed lift coefficient.
    ///
    /// Returns exactly 1.0 below the legacy-equivalence Mach, so this is a no-op for
    /// the existing fleet at the speeds it flies.
    func liftFactor(mach: Float) -> Float {
        let m = max(0.0, mach.isFinite ? mach : 0.0)
        guard m > Self.legacyEquivalenceMach else { return 1.0 }

        // Subsonic: Prandtl–Glauert, capped. Uncapped it is singular at Mach 1, which
        // the plan bans by name.
        //
        // The cap is 1.45, and the number is chosen rather than picked: 1/√(1−M²)
        // reaches 1.45 at Mach 0.725, which is where the critical Mach of every
        // planform in this catalogue sits. That is precisely where the correction stops
        // being valid — Prandtl–Glauert describes an inviscid, shock-free flow, and once
        // local pockets go supersonic the lift stops following it and shock-induced
        // separation takes over. So the cap engages exactly where the physics it
        // represents runs out, instead of at an arbitrary height.
        //
        // It was 1.8 first, which put the saturation at Mach 0.83, well past the point
        // the theory holds, and implied a wing making eighty per cent more lift at the
        // same angle of attack. The sweep probe found the resulting gradient before any
        // aircraft had to fly through it.
        let prandtlGlauert = min(1.45, 1.0 / sqrt(max(0.05, 1.0 - m * m)))
        let fadeIn = Self.smoothstep(
            Self.legacyEquivalenceMach,
            Self.legacyEquivalenceMach + Self.fadeInWidth,
            m
        )
        let subsonic = 1.0 + (prandtlGlauert - 1.0) * fadeIn

        // Supersonic: linearised (Ackeret) theory, `CL_α = 4/√(M²−1)`, expressed
        // relative to the thin-aerofoil incompressible slope of 2π that the low-speed
        // curve is already built around. The floor under `M²−1` keeps it finite
        // through Mach 1 instead of blowing up there.
        let supersonic = 4.0 / (2.0 * Float.pi * sqrt(max(0.20, m * m - 1.0)))

        // One blend across the transonic band rather than two formulas meeting at a
        // point. Both branches are finite everywhere, so the result is continuous and
        // has no step at M = 1.0.
        let blend = Self.smoothstep(0.95, 1.15, m)
        return max(0.12, subsonic * (1.0 - blend) + supersonic * blend)
    }

    /// Wave-drag increment to add to the low-speed CD.
    ///
    /// Not a universal "+30 % above Mach 1" — the plan forbids that, and rightly: the
    /// increment here depends on the airframe's own critical Mach, on how far past it
    /// the aircraft is, and on how hard the wing is working, because a lifting wing
    /// forms its supersonic pocket earlier and larger than one at zero lift.
    func waveDragIncrement(mach: Float, liftCoefficient: Float) -> Float {
        let m = max(0.0, mach.isFinite ? mach : 0.0)
        guard m > criticalMach else { return 0.0 }

        let cl = liftCoefficient.isFinite ? liftCoefficient : 0.0
        let liftPenalty = 1.0 + 2.2 * min(1.0, cl * cl)
        let peak = max(0.0, waveDragPeak) * liftPenalty
        let peakMach = peakDragMach

        if m <= peakMach {
            // Lock's fourth-power law. The steepness is the point: this is what makes
            // the drag rise a wall the aircraft has to be thrown through rather than a
            // gentle slope it drifts up.
            let t = ((m - criticalMach) / max(1.0e-3, peakMach - criticalMach))
                .clampedToUnit()
            return peak * t * t * t * t
        }

        // Past the peak the Mach cone sweeps back and wave drag falls away, toward a
        // floor rather than to nothing — a supersonic aircraft never stops paying for
        // its own volume.
        let softening: Float = 0.30
        let decay = sqrt(
            (peakMach * peakMach - 1.0 + softening) / max(1.0e-3, m * m - 1.0 + softening)
        )
        return peak * max(0.30, decay)
    }

    /// How far aft the aerodynamic centre has moved at this Mach, as a fraction of the
    /// mean chord. Zero below the critical Mach.
    ///
    /// Consumed as a shift of the moment reference point — `Cm_cg = Cm_ac + CL·Δx/c̄`,
    /// the same relation the fuel-burn balance shift already uses — and *not* as an
    /// extra `r × F` about the centre of mass. That distinction is not cosmetic: doing
    /// it the other way double-counts the moment, which once put the entire fuel fleet
    /// on its tail.
    func aeroCenterShiftFraction(mach: Float) -> Float {
        let m = max(0.0, mach.isFinite ? mach : 0.0)
        return supersonicAeroCenterShift * Self.smoothstep(criticalMach, 1.20, m)
    }

    /// Multiplier on control-surface and rate-damping derivatives.
    ///
    /// A plain trailing-edge surface behind a shock changes the pressure only
    /// downstream of its own hinge line, so it loses much of the authority it has
    /// subsonically. Floored rather than taken to zero: it still does something, and a
    /// zero here would silently remove the aircraft's damping along with its controls.
    func controlEffectiveness(mach: Float) -> Float {
        max(0.30, min(1.0, liftFactor(mach: mach)))
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let t = ((value - edge0) / max(1.0e-4, edge1 - edge0)).clampedToUnit()
        return t * t * (3.0 - 2.0 * t)
    }
}

private extension Float {
    func clampedToUnit() -> Float {
        Swift.min(1.0, Swift.max(0.0, self))
    }
}
