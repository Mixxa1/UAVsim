import SwiftUI

/// Plots of the coefficients the aircraft is actually flying on.
///
/// Everything else in this application shows what the aircraft *did*: where it went, how
/// fast, how hot. This shows the model underneath — the lift, drag and moment curves as a
/// function of angle of attack, at a Mach number the reader chooses. That is the difference
/// between finding out an aircraft climbs badly and finding out that its drag rise starts at
/// Mach 0.72 rather than 0.82, which is the question worth answering.
///
/// Read from exactly the same `FixedWingAerodynamics` the solver builds, from the same
/// inputs, so what is drawn here is the aircraft and not a second description of it. The one
/// deliberate difference is that damage is not applied: this is the airframe's designed
/// aerodynamics, and a plot that changed shape because a wing was bent would be answering a
/// different question.
struct AeroDiagnosticsPanelView: View {
    let profile: DroneModelProfile
    let liveMach: Float
    let liveAlphaRad: Float

    @State private var machSlice: Double = 0.3
    @State private var followsLiveMach = true

    private var wing: FixedWingParameters? { profile.fixedWingParameters }

    private var aerodynamics: FixedWingAerodynamics? {
        guard let wing else { return nil }
        let dimensions = profile.dimensionsUnfoldedMm
        return FixedWingAerodynamics.build(
            family: wing.family,
            massKg: max(0.1, profile.takeoffMassKg),
            wingSpanM: Float(dimensions.x) / 1000.0,
            fuselageLengthM: Float(dimensions.y) / 1000.0,
            heightM: Float(dimensions.z) / 1000.0,
            turnAuthority: wing.turnAuthority,
            minSustainableSpeedMps: wing.minSustainableSpeedMps
        )
    }

    private var effectiveMach: Float {
        followsLiveMach ? max(0.0, liveMach) : Float(machSlice)
    }

    var body: some View {
        Group {
            if let aerodynamics, let wing {
                content(aerodynamics: aerodynamics, wing: wing)
            } else {
                Text("diagnostics.aero.rotary_only")
                    .font(.system(size: 12))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
    }

    @ViewBuilder
    private func content(aerodynamics: FixedWingAerodynamics, wing: FixedWingParameters) -> some View {
        ModuleSection(
            titleKey: "diagnostics.aero.curves",
            subtitleKey: "diagnostics.aero.curves.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                machControl

                AeroCurveChart(
                    aerodynamics: aerodynamics,
                    mach: effectiveMach,
                    liveAlphaRad: liveAlphaRad,
                    stallAlphaRad: FixedWingAerodynamics.stallAngleOfAttack(for: wing.family)
                )
                .frame(height: 190)

                legend
            }
        }

        ModuleSection(
            titleKey: "diagnostics.aero.drag_breakdown",
            subtitleKey: "diagnostics.aero.drag_breakdown.subtitle"
        ) {
            DragBreakdownChart(
                aerodynamics: aerodynamics,
                alphaRad: liveAlphaRad,
                divergenceMach: FixedWingAerodynamics.dragDivergenceMach(for: wing.family)
            )
            .frame(height: 170)
        }

        ModuleSection(
            titleKey: "diagnostics.aero.model",
            subtitleKey: "diagnostics.aero.model.subtitle"
        ) {
            ModuleMetricGrid {
                ModuleMetricCell(
                    labelKey: "diagnostics.aero.wing_area",
                    value: String(format: "%.2f m²", aerodynamics.wingArea)
                )
                ModuleMetricCell(
                    labelKey: "diagnostics.aero.aspect_ratio",
                    value: String(
                        format: "%.2f",
                        aerodynamics.wingSpan * aerodynamics.wingSpan / max(0.01, aerodynamics.wingArea)
                    )
                )
                ModuleMetricCell(
                    labelKey: "diagnostics.aero.divergence_mach",
                    value: String(format: "M %.2f", FixedWingAerodynamics.dragDivergenceMach(for: wing.family))
                )
                ModuleMetricCell(
                    labelKey: "diagnostics.aero.source",
                    value: aerodynamics.coefficientTable?.provenance
                        ?? NSLocalizedString("diagnostics.aero.source.closed_form", comment: "")
                )
            }
        }
    }

    private var machControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("diagnostics.aero.follow_live", isOn: $followsLiveMach)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundStyle(GroundControlPalette.textPrimary)

            HStack(spacing: 10) {
                Text(String(format: "M %.2f", effectiveMach))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .frame(width: 66, alignment: .leading)
                Slider(value: $machSlice, in: 0.0...3.0)
                    .disabled(followsLiveMach)
                    .opacity(followsLiveMach ? 0.4 : 1.0)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendSwatch(color: GroundControlPalette.accent, textKey: "diagnostics.aero.cl")
            legendSwatch(color: GroundControlPalette.warning, textKey: "diagnostics.aero.cd")
            legendSwatch(color: GroundControlPalette.textSecondary, textKey: "diagnostics.aero.cm")
        }
    }

    private func legendSwatch(color: Color, textKey: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.0).fill(color).frame(width: 14, height: 2.5)
            Text(LocalizedStringKey(textKey))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
    }
}

/// CL, CD and Cm against angle of attack at one Mach number.
///
/// Three curves on one pair of axes with three very different natural ranges, so each is
/// drawn against its own scale and the scales are printed rather than the gridlines being
/// labelled. Sharing one axis would flatten the moment curve into the zero line, which is
/// the curve most worth looking at.
private struct AeroCurveChart: View {
    let aerodynamics: FixedWingAerodynamics
    let mach: Float
    let liveAlphaRad: Float
    let stallAlphaRad: Float

    private let alphaRangeDeg: ClosedRange<Float> = -10.0...30.0

    var body: some View {
        Canvas { context, size in
            let samples = 121
            var lift: [Float] = []
            var drag: [Float] = []
            var moment: [Float] = []
            for step in 0..<samples {
                let fraction = Float(step) / Float(samples - 1)
                let alphaDeg = alphaRangeDeg.lowerBound
                    + (alphaRangeDeg.upperBound - alphaRangeDeg.lowerBound) * fraction
                let alpha = alphaDeg * .pi / 180.0
                let (cl, cd) = aerodynamics.liftDrag(alphaRad: alpha, mach: mach)
                lift.append(cl)
                drag.append(cd)
                // Elevator neutral and no pitch rate: the airframe's own static moment,
                // which is what a stability plot is asking about.
                moment.append(aerodynamics.pitchMoment(
                    alphaRad: alpha,
                    elevatorFraction: 0.0,
                    qHat: 0.0,
                    mach: mach
                ))
            }

            drawFrame(context: context, size: size)
            drawStallMarker(context: context, size: size)
            drawSeries(context: context, size: size, values: lift, color: GroundControlPalette.accent)
            drawSeries(context: context, size: size, values: drag, color: GroundControlPalette.warning)
            drawSeries(context: context, size: size, values: moment, color: GroundControlPalette.textSecondary)
            drawLiveMarker(context: context, size: size)
            drawScales(context: context, size: size, lift: lift, drag: drag, moment: moment)
        }
        .background(GroundControlPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func x(_ alphaDeg: Float, _ size: CGSize) -> CGFloat {
        let span = alphaRangeDeg.upperBound - alphaRangeDeg.lowerBound
        return CGFloat((alphaDeg - alphaRangeDeg.lowerBound) / span) * size.width
    }

    private func drawFrame(context: GraphicsContext, size: CGSize) {
        // Vertical rules every 10 degrees, and a heavier one at zero alpha.
        var alphaDeg = ceil(alphaRangeDeg.lowerBound / 10.0) * 10.0
        while alphaDeg <= alphaRangeDeg.upperBound {
            var path = Path()
            path.move(to: CGPoint(x: x(alphaDeg, size), y: 0))
            path.addLine(to: CGPoint(x: x(alphaDeg, size), y: size.height))
            context.stroke(
                path,
                with: .color(GroundControlPalette.textSecondary.opacity(alphaDeg == 0.0 ? 0.35 : 0.12)),
                lineWidth: alphaDeg == 0.0 ? 1.0 : 0.5
            )
            alphaDeg += 10.0
        }
        var midline = Path()
        midline.move(to: CGPoint(x: 0, y: size.height * 0.5))
        midline.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
        context.stroke(midline, with: .color(GroundControlPalette.textSecondary.opacity(0.2)), lineWidth: 0.5)
    }

    private func drawStallMarker(context: GraphicsContext, size: CGSize) {
        let stallDeg = stallAlphaRad * 180.0 / .pi
        guard alphaRangeDeg.contains(stallDeg) else { return }
        var path = Path()
        path.move(to: CGPoint(x: x(stallDeg, size), y: 0))
        path.addLine(to: CGPoint(x: x(stallDeg, size), y: size.height))
        context.stroke(
            path,
            with: .color(GroundControlPalette.danger.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
        )
    }

    private func drawLiveMarker(context: GraphicsContext, size: CGSize) {
        let alphaDeg = liveAlphaRad * 180.0 / .pi
        guard alphaRangeDeg.contains(alphaDeg) else { return }
        var path = Path()
        path.move(to: CGPoint(x: x(alphaDeg, size), y: 0))
        path.addLine(to: CGPoint(x: x(alphaDeg, size), y: size.height))
        context.stroke(path, with: .color(GroundControlPalette.textPrimary.opacity(0.55)), lineWidth: 1.0)
    }

    /// Each series normalised to its own peak so all three are legible together.
    private func drawSeries(context: GraphicsContext, size: CGSize, values: [Float], color: Color) {
        let peak = max(0.0001, values.map { abs($0) }.max() ?? 1.0)
        var path = Path()
        for (index, value) in values.enumerated() {
            let fraction = Float(index) / Float(max(1, values.count - 1))
            let alphaDeg = alphaRangeDeg.lowerBound
                + (alphaRangeDeg.upperBound - alphaRangeDeg.lowerBound) * fraction
            let normalised = value / peak
            let point = CGPoint(
                x: x(alphaDeg, size),
                y: size.height * 0.5 - CGFloat(normalised) * size.height * 0.45
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.8)
    }

    private func drawScales(
        context: GraphicsContext,
        size: CGSize,
        lift: [Float],
        drag: [Float],
        moment: [Float]
    ) {
        let entries: [(String, [Float], Color)] = [
            ("CL", lift, GroundControlPalette.accent),
            ("CD", drag, GroundControlPalette.warning),
            ("Cm", moment, GroundControlPalette.textSecondary)
        ]
        for (index, entry) in entries.enumerated() {
            let peak = entry.1.map { abs($0) }.max() ?? 0.0
            let text = Text(String(format: "%@ ±%.3f", entry.0, peak))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(entry.2)
            context.draw(text, at: CGPoint(x: 6, y: 10 + CGFloat(index) * 12), anchor: .topLeading)
        }
    }
}

/// Where the drag is going, against Mach, at the aircraft's current angle of attack.
///
/// Stacked rather than overlaid, because the question this answers is what fraction of the
/// total each mechanism owns — and the moment it becomes interesting is the one where the
/// wave-drag band opens up and swallows the other two. The drag-divergence Mach is marked so
/// that the rise can be read against where it was predicted to start.
private struct DragBreakdownChart: View {
    let aerodynamics: FixedWingAerodynamics
    let alphaRad: Float
    let divergenceMach: Float

    private let machRange: ClosedRange<Float> = 0.0...3.0

    var body: some View {
        Canvas { context, size in
            let samples = 90
            var parasite: [Float] = []
            var induced: [Float] = []
            var wave: [Float] = []
            for step in 0..<samples {
                let mach = machRange.lowerBound
                    + (machRange.upperBound - machRange.lowerBound) * Float(step) / Float(samples - 1)
                let (_, cd) = aerodynamics.liftDrag(alphaRad: alphaRad, mach: mach)
                let waveComponent = aerodynamics.waveDragCoefficient(alphaRad: alphaRad, mach: mach)
                parasite.append(aerodynamics.cd0)
                wave.append(waveComponent)
                // Whatever the total is not otherwise accounted for. Taken as a remainder
                // rather than recomputed, so the three bands always sum to the drag the
                // solver actually charges — a breakdown that does not add up to the total is
                // worse than no breakdown.
                induced.append(max(0.0, cd - aerodynamics.cd0 - waveComponent))
            }

            let peak = max(0.0001, (0..<samples).map { parasite[$0] + induced[$0] + wave[$0] }.max() ?? 1.0)
            func y(_ value: Float) -> CGFloat {
                size.height - CGFloat(value / peak) * size.height * 0.9
            }
            func x(_ index: Int) -> CGFloat {
                CGFloat(index) / CGFloat(samples - 1) * size.width
            }

            func band(lower: [Float], upper: [Float], color: Color) {
                var path = Path()
                path.move(to: CGPoint(x: x(0), y: y(lower[0])))
                for index in 0..<samples { path.addLine(to: CGPoint(x: x(index), y: y(upper[index]))) }
                for index in stride(from: samples - 1, through: 0, by: -1) {
                    path.addLine(to: CGPoint(x: x(index), y: y(lower[index])))
                }
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }

            let zero = [Float](repeating: 0.0, count: samples)
            let firstBand = parasite
            let secondBand = (0..<samples).map { parasite[$0] + induced[$0] }
            let thirdBand = (0..<samples).map { secondBand[$0] + wave[$0] }

            band(lower: zero, upper: firstBand, color: GroundControlPalette.textSecondary.opacity(0.55))
            band(lower: firstBand, upper: secondBand, color: GroundControlPalette.accent.opacity(0.55))
            band(lower: secondBand, upper: thirdBand, color: GroundControlPalette.warning.opacity(0.7))

            // Drag divergence.
            if machRange.contains(divergenceMach) {
                let fraction = (divergenceMach - machRange.lowerBound)
                    / (machRange.upperBound - machRange.lowerBound)
                var path = Path()
                path.move(to: CGPoint(x: CGFloat(fraction) * size.width, y: 0))
                path.addLine(to: CGPoint(x: CGFloat(fraction) * size.width, y: size.height))
                context.stroke(
                    path,
                    with: .color(GroundControlPalette.danger.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
                )
                context.draw(
                    Text(String(format: "M%.2f", divergenceMach))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.danger),
                    at: CGPoint(x: CGFloat(fraction) * size.width + 4, y: 8),
                    anchor: .topLeading
                )
            }

            // Mach 1, for orientation.
            let sonicFraction = (1.0 - machRange.lowerBound)
                / (machRange.upperBound - machRange.lowerBound)
            var sonic = Path()
            sonic.move(to: CGPoint(x: CGFloat(sonicFraction) * size.width, y: 0))
            sonic.addLine(to: CGPoint(x: CGFloat(sonicFraction) * size.width, y: size.height))
            context.stroke(sonic, with: .color(GroundControlPalette.textSecondary.opacity(0.3)), lineWidth: 0.5)

            context.draw(
                Text(String(format: "CD max %.4f", peak))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary),
                at: CGPoint(x: 6, y: 8),
                anchor: .topLeading
            )
        }
        .background(GroundControlPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
