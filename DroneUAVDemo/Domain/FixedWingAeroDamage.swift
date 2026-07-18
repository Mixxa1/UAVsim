import Foundation

/// Aerodynamic consequences of structural damage, derived from the vehicle
/// component graph and applied on top of the airframe's pristine
/// `FixedWingAerodynamics` each step. All values are neutral (1 / 0) for an
/// undamaged aircraft, so the pristine flight model is bit-identical.
struct FixedWingAeroDamage: Hashable {
    /// Wing reference-area scale (section loss shrinks lift, drag and moment
    /// authority together).
    var liftScale: Float = 1.0
    /// Parasitic drag added by ragged/broken structure.
    var cd0Extra: Float = 0.0
    /// Constant rolling-moment coefficient offset from spanwise lift
    /// asymmetry (positive = rolls toward the damaged right wing).
    var clRollOffset: Float = 0.0
    /// Constant yawing-moment coefficient offset from spanwise drag
    /// asymmetry (positive = nose toward the damaged right side).
    var cnYawOffset: Float = 0.0
    var aileronScale: Float = 1.0
    var elevatorScale: Float = 1.0
    var rudderScale: Float = 1.0
    var pitchStabilityScale: Float = 1.0
    var yawStabilityScale: Float = 1.0

    static let pristine = FixedWingAeroDamage()

    var isPristine: Bool {
        liftScale > 0.999 && cd0Extra < 0.0001 &&
            abs(clRollOffset) < 0.0001 && abs(cnYawOffset) < 0.0001 &&
            aileronScale > 0.999 && elevatorScale > 0.999 && rudderScale > 0.999 &&
            pitchStabilityScale > 0.999 && yawStabilityScale > 0.999
    }

    /// Builds the deltas from wing-section/tail integrity in the graph.
    /// Sections are the builder's four wing quarters (root/outer per side,
    /// ~0.25 of area each, outer sections at the longer roll lever).
    static func build(from graph: VehicleComponentGraph) -> FixedWingAeroDamage {
        guard !graph.isEmpty else { return .pristine }

        let leftRoot = graph.integrity(id: "wing.left.root")
        let leftOuter = graph.integrity(id: "wing.left.outer")
        let rightRoot = graph.integrity(id: "wing.right.root")
        let rightOuter = graph.integrity(id: "wing.right.outer")
        let hTail = graph.integrity(id: "tail.horizontal")
        let vTail = graph.integrity(id: "tail.vertical")

        let totalSectionDamage = (1.0 - leftRoot) + (1.0 - leftOuter) + (1.0 - rightRoot) + (1.0 - rightOuter)
        // Right-minus-left damage asymmetry; outer sections carry the longer
        // roll lever (0.75 half-span vs 0.25 for root sections).
        let outerAsymmetry = (1.0 - rightOuter) - (1.0 - leftOuter)
        let rootAsymmetry = (1.0 - rightRoot) - (1.0 - leftRoot)

        let liftScale = (1.0 - totalSectionDamage * 0.25 * 0.8).clamped(to: 0.2...1.0)
        let cd0Extra = (totalSectionDamage * 0.25 * 0.04 + (1.0 - hTail) * 0.012 + (1.0 - vTail) * 0.010)
            .clamped(to: 0.0...0.08)
        let clRollOffset = ((outerAsymmetry * 0.75 + rootAsymmetry * 0.25) * 0.12).clamped(to: -0.15...0.15)
        // Ragged structure drags — nose pulls toward the damaged side.
        let cnYawOffset = ((outerAsymmetry * 0.7 + rootAsymmetry * 0.3) * 0.03).clamped(to: -0.04...0.04)

        return FixedWingAeroDamage(
            liftScale: liftScale,
            cd0Extra: cd0Extra,
            clRollOffset: clRollOffset,
            cnYawOffset: cnYawOffset,
            aileronScale: ((leftOuter + rightOuter) * 0.5).clamped(to: 0.0...1.0),
            elevatorScale: hTail.clamped(to: 0.0...1.0),
            rudderScale: vTail.clamped(to: 0.0...1.0),
            // Some pitch/yaw stiffness survives the tail (fuselage, wing) —
            // scales floor above zero so the model stays integrable.
            pitchStabilityScale: (0.35 + 0.65 * hTail).clamped(to: 0.35...1.0),
            yawStabilityScale: (0.45 + 0.55 * vTail).clamped(to: 0.45...1.0)
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
