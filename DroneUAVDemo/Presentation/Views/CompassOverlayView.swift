import SwiftUI

struct CompassOverlayView: View {
    @ObservedObject var viewModel: CompassViewModel

    private var headingLabel: String {
        String(format: "%03.0f", viewModel.headingDegrees)
    }

    private var targetLabel: String {
        guard viewModel.targetBearingDegrees.isFinite else {
            return "—"
        }
        return String(format: "%03.0f", viewModel.targetBearingDegrees)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("overlay.compass.title")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text("overlay.compass.subtitle")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer(minLength: 12)

                Text("/")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(GroundControlPalette.inset, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                    )
            }

            CompassRibbonView(
                headingDegrees: viewModel.headingDegrees,
                targetBearingDegrees: viewModel.targetBearingDegrees
            )
            .frame(width: 304, height: 54)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )

            HStack(spacing: 16) {
                metric(label: localized("overlay.compass.metric.heading"), value: "\(headingLabel)°")
                metric(label: localized("overlay.compass.metric.north"), value: "000°")
                metric(label: localized("overlay.compass.metric.bearing"), value: viewModel.targetBearingDegrees.isFinite ? "\(targetLabel)°" : "—")
            }
        }
        .padding(12)
        .frame(width: 332, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(GroundControlPalette.panel.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, y: 10)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
    }
}

private struct CompassRibbonView: View {
    let headingDegrees: Double
    let targetBearingDegrees: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 10)
            let centerX = rect.midX
            let baselineY = rect.maxY - 12
            let pixelsPerDegree = rect.width / 120.0

            var baseline = Path()
            baseline.move(to: CGPoint(x: rect.minX, y: baselineY))
            baseline.addLine(to: CGPoint(x: rect.maxX, y: baselineY))
            context.stroke(
                baseline,
                with: .color(GroundControlPalette.borderStrong.opacity(0.9)),
                lineWidth: 1.2
            )

            let start = floor(headingDegrees / 15.0) * 15.0 - 90.0
            let end = start + 195.0
            stride(from: start, through: end, by: 15.0).forEach { absoluteValue in
                let normalized = normalized(absoluteValue)
                let delta = shortestDelta(from: headingDegrees, to: normalized)
                let x = centerX + delta * pixelsPerDegree
                guard x >= rect.minX - 12, x <= rect.maxX + 12 else {
                    return
                }

                let isMajor = Int(normalized.rounded()) % 30 == 0
                let tickHeight: CGFloat = isMajor ? 14 : 8
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: baselineY - tickHeight))
                tick.addLine(to: CGPoint(x: x, y: baselineY))
                context.stroke(
                    tick,
                    with: .color(GroundControlPalette.textSecondary.opacity(isMajor ? 0.88 : 0.56)),
                    lineWidth: isMajor ? 1.2 : 0.9
                )

                guard isMajor else {
                    return
                }

                let label = normalized == 0.0 ? localized("overlay.compass.metric.north") : String(format: "%03.0f", normalized)
                let resolvedColor = normalized == 0.0
                    ? GroundControlPalette.warning
                    : GroundControlPalette.textSecondary
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: normalized == 0.0 ? .bold : .semibold, design: .monospaced))
                        .foregroundColor(resolvedColor),
                    at: CGPoint(x: x, y: baselineY - 22),
                    anchor: .center
                )
            }

            drawReferenceMarker(
                context: &context,
                x: centerX,
                baselineY: baselineY,
                color: GroundControlPalette.danger,
                label: localized("overlay.compass.marker.current")
            )

            if targetBearingDegrees.isFinite {
                let delta = shortestDelta(from: headingDegrees, to: targetBearingDegrees)
                let x = centerX + delta * pixelsPerDegree
                if x >= rect.minX - 6, x <= rect.maxX + 6 {
                    drawReferenceMarker(
                        context: &context,
                        x: x,
                        baselineY: baselineY,
                        color: GroundControlPalette.warning,
                        label: localized("overlay.compass.marker.target")
                    )
                }
            }
        }
    }

    private func drawReferenceMarker(
        context: inout GraphicsContext,
        x: CGFloat,
        baselineY: CGFloat,
        color: Color,
        label: String
    ) {
        var marker = Path()
        marker.move(to: CGPoint(x: x, y: baselineY - 30))
        marker.addLine(to: CGPoint(x: x - 5, y: baselineY - 22))
        marker.addLine(to: CGPoint(x: x + 5, y: baselineY - 22))
        marker.closeSubpath()
        context.fill(marker, with: .color(color))

        context.draw(
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(color),
            at: CGPoint(x: x, y: baselineY - 38),
            anchor: .center
        )
    }

    private func normalized(_ value: Double) -> Double {
        let wrapped = value.truncatingRemainder(dividingBy: 360.0)
        return wrapped >= 0.0 ? wrapped : wrapped + 360.0
    }

    private func shortestDelta(from source: Double, to target: Double) -> CGFloat {
        let raw = (target - source).truncatingRemainder(dividingBy: 360.0)
        let corrected: Double
        if raw > 180.0 {
            corrected = raw - 360.0
        } else if raw < -180.0 {
            corrected = raw + 360.0
        } else {
            corrected = raw
        }
        return CGFloat(corrected)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
