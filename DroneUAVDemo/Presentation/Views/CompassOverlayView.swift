import SwiftUI

struct CompassOverlayView: View {
    @ObservedObject var viewModel: CompassViewModel
    let telemetry: TelemetrySnapshot

    private var headingDegrees: Double {
        viewModel.headingDegrees
    }

    private var targetBearingDegrees: Double {
        telemetry.targetBearingDegrees.isFinite
            ? telemetry.targetBearingDegrees
            : viewModel.targetBearingDegrees
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("overlay.pfd.title")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text("overlay.pfd.subtitle")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer(minLength: 12)

                Text(String(format: "%03.0f", headingDegrees))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(GroundControlPalette.warning.opacity(0.7), lineWidth: 1)
                    )
            }
            .foregroundStyle(GroundControlPalette.textPrimary)

            HStack(alignment: .center, spacing: 8) {
                FlightTapeView(
                    value: telemetry.speed,
                    targetValue: telemetry.fixedWingTargetAirspeed,
                    labelKey: "overlay.pfd.metric.speed",
                    unit: "m/s",
                    majorStep: 10.0,
                    minorStep: 5.0,
                    visibleSpan: 48.0,
                    valueFormatter: { String(format: "%.1f", max(0.0, $0)) },
                    scaleFormatter: { String(format: "%.0f", max(0.0, $0)) }
                )
                .frame(width: 64, height: 196)

                AttitudeDirectorView(
                    rollDegrees: telemetry.roll,
                    pitchDegrees: telemetry.pitch
                )
                .frame(width: 260, height: 196)

                FlightTapeView(
                    value: telemetry.y,
                    targetValue: telemetry.fixedWingTargetAltitude,
                    labelKey: "overlay.pfd.metric.altitude",
                    unit: "m",
                    majorStep: 20.0,
                    minorStep: 10.0,
                    visibleSpan: 120.0,
                    valueFormatter: { String(format: "%.0f", max(0.0, $0)) },
                    scaleFormatter: { String(format: "%.0f", max(0.0, $0)) },
                    accessoryValue: telemetry.velocityY,
                    accessoryLabelKey: "overlay.pfd.metric.vertical_speed"
                )
                .frame(width: 74, height: 196)
            }

            HeadingTapeView(
                headingDegrees: headingDegrees,
                targetBearingDegrees: targetBearingDegrees
            )
            .frame(width: 414, height: 46)

            HStack(spacing: 16) {
                metric(labelKey: "overlay.pfd.metric.roll", value: String(format: "%+.0f°", telemetry.roll))
                metric(labelKey: "overlay.pfd.metric.pitch", value: String(format: "%+.0f°", telemetry.pitch))
                metric(labelKey: "overlay.pfd.metric.bearing", value: targetBearingDegrees.isFinite ? String(format: "%03.0f°", normalized(targetBearingDegrees)) : "--")
                metric(labelKey: "overlay.pfd.metric.battery", value: String(format: "%.0f%%", telemetry.batteryPercent))
            }
        }
        .padding(10)
        .frame(width: 434, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 18, y: 12)
    }

    private func metric(labelKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(labelKey))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
        .frame(minWidth: 54, alignment: .leading)
    }
}

private struct AttitudeDirectorView: View {
    let rollDegrees: Double
    let pitchDegrees: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let frame = rect.insetBy(dx: 5, dy: 5)
            let center = CGPoint(x: frame.midX, y: frame.midY + 5)
            let mask = Path(roundedRect: frame, cornerRadius: 8)

            var clipped = context
            clipped.clip(to: mask)
            drawHorizon(context: &clipped, frame: frame, center: center)
            drawPitchLadder(context: &clipped, frame: frame, center: center)

            context.stroke(mask, with: .color(GroundControlPalette.borderStrong), lineWidth: 1.1)
            drawRollScale(context: &context, frame: frame, center: center)
            drawFixedAircraftSymbol(context: &context, center: center)
            drawReferenceReadouts(context: &context, frame: frame)
        }
    }

    private func drawHorizon(
        context: inout GraphicsContext,
        frame: CGRect,
        center: CGPoint
    ) {
        let pitchOffset = boundedPitch * 3.0
        let horizonY = center.y + pitchOffset
        let wide = max(frame.width, frame.height) * 2.6
        let tall = max(frame.width, frame.height) * 2.6

        var world = context
        world.translateBy(x: center.x, y: center.y)
        world.rotate(by: .degrees(-boundedRoll))
        world.translateBy(x: -center.x, y: -center.y)

        let skyRect = CGRect(x: center.x - wide / 2.0, y: horizonY - tall, width: wide, height: tall)
        let groundRect = CGRect(x: center.x - wide / 2.0, y: horizonY, width: wide, height: tall)
        world.fill(Path(skyRect), with: .linearGradient(
            Gradient(colors: [
                Color(red: 0.05, green: 0.35, blue: 0.88),
                Color(red: 0.08, green: 0.55, blue: 0.96)
            ]),
            startPoint: CGPoint(x: frame.midX, y: frame.minY),
            endPoint: CGPoint(x: frame.midX, y: horizonY)
        ))
        world.fill(Path(groundRect), with: .linearGradient(
            Gradient(colors: [
                Color(red: 0.58, green: 0.27, blue: 0.07),
                Color(red: 0.36, green: 0.17, blue: 0.05)
            ]),
            startPoint: CGPoint(x: frame.midX, y: horizonY),
            endPoint: CGPoint(x: frame.midX, y: frame.maxY)
        ))

        var horizon = Path()
        horizon.move(to: CGPoint(x: center.x - wide / 2.0, y: horizonY))
        horizon.addLine(to: CGPoint(x: center.x + wide / 2.0, y: horizonY))
        world.stroke(horizon, with: .color(.white.opacity(0.96)), lineWidth: 1.6)
    }

    private func drawPitchLadder(
        context: inout GraphicsContext,
        frame: CGRect,
        center: CGPoint
    ) {
        var world = context
        world.translateBy(x: center.x, y: center.y)
        world.rotate(by: .degrees(-boundedRoll))
        world.translateBy(x: -center.x, y: -center.y)

        stride(from: -30.0, through: 30.0, by: 5.0).forEach { mark in
            guard mark != 0 else { return }
            let y = center.y + (boundedPitch - mark) * 3.0
            guard y > frame.minY - 18, y < frame.maxY + 18 else { return }

            let major = Int(abs(mark).rounded()) % 10 == 0
            let halfWidth: CGFloat = major ? 42 : 24
            let gap: CGFloat = major ? 26 : 20
            let tickColor = Color.white.opacity(major ? 0.95 : 0.72)

            var left = Path()
            left.move(to: CGPoint(x: center.x - gap / 2.0 - halfWidth, y: y))
            left.addLine(to: CGPoint(x: center.x - gap / 2.0, y: y))
            world.stroke(left, with: .color(tickColor), lineWidth: major ? 1.3 : 0.9)

            var right = Path()
            right.move(to: CGPoint(x: center.x + gap / 2.0, y: y))
            right.addLine(to: CGPoint(x: center.x + gap / 2.0 + halfWidth, y: y))
            world.stroke(right, with: .color(tickColor), lineWidth: major ? 1.3 : 0.9)

            guard major else { return }
            let label = String(format: "%.0f", abs(mark))
            world.draw(
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92)),
                at: CGPoint(x: center.x - gap / 2.0 - halfWidth - 14, y: y),
                anchor: .center
            )
            world.draw(
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92)),
                at: CGPoint(x: center.x + gap / 2.0 + halfWidth + 14, y: y),
                anchor: .center
            )
        }
    }

    private func drawRollScale(
        context: inout GraphicsContext,
        frame: CGRect,
        center: CGPoint
    ) {
        let radius = min(frame.width, frame.height) * 0.47
        let topCenter = CGPoint(x: center.x, y: center.y)

        stride(from: -60.0, through: 60.0, by: 10.0).forEach { mark in
            let angle = (-90.0 + mark) * .pi / 180.0
            let tickOuter = CGPoint(
                x: topCenter.x + cos(angle) * radius,
                y: topCenter.y + sin(angle) * radius
            )
            let tickInner = CGPoint(
                x: topCenter.x + cos(angle) * (radius - (mark.truncatingRemainder(dividingBy: 30.0) == 0.0 ? 12 : 7)),
                y: topCenter.y + sin(angle) * (radius - (mark.truncatingRemainder(dividingBy: 30.0) == 0.0 ? 12 : 7))
            )
            var tick = Path()
            tick.move(to: tickInner)
            tick.addLine(to: tickOuter)
            context.stroke(
                tick,
                with: .color(Color.white.opacity(mark.truncatingRemainder(dividingBy: 30.0) == 0.0 ? 0.86 : 0.58)),
                lineWidth: mark.truncatingRemainder(dividingBy: 30.0) == 0.0 ? 1.2 : 0.9
            )
        }

        let bankAngle = (-90.0 + boundedRoll) * .pi / 180.0
        let markerTip = CGPoint(
            x: topCenter.x + cos(bankAngle) * (radius + 2),
            y: topCenter.y + sin(bankAngle) * (radius + 2)
        )
        let markerBase = CGPoint(
            x: topCenter.x + cos(bankAngle) * (radius - 14),
            y: topCenter.y + sin(bankAngle) * (radius - 14)
        )
        let tangent = CGPoint(x: -sin(bankAngle), y: cos(bankAngle))
        var marker = Path()
        marker.move(to: markerTip)
        marker.addLine(to: CGPoint(x: markerBase.x + tangent.x * 5, y: markerBase.y + tangent.y * 5))
        marker.addLine(to: CGPoint(x: markerBase.x - tangent.x * 5, y: markerBase.y - tangent.y * 5))
        marker.closeSubpath()
        context.fill(marker, with: .color(GroundControlPalette.warning))
    }

    private func drawFixedAircraftSymbol(context: inout GraphicsContext, center: CGPoint) {
        let y = center.y
        let wingY = y + 1

        var leftWing = Path()
        leftWing.move(to: CGPoint(x: center.x - 66, y: wingY))
        leftWing.addLine(to: CGPoint(x: center.x - 22, y: wingY))
        leftWing.addLine(to: CGPoint(x: center.x - 22, y: wingY + 13))
        leftWing.addLine(to: CGPoint(x: center.x - 36, y: wingY + 13))
        context.stroke(leftWing, with: .color(GroundControlPalette.warning), lineWidth: 3)

        var rightWing = Path()
        rightWing.move(to: CGPoint(x: center.x + 22, y: wingY))
        rightWing.addLine(to: CGPoint(x: center.x + 66, y: wingY))
        rightWing.addLine(to: CGPoint(x: center.x + 66, y: wingY + 13))
        rightWing.addLine(to: CGPoint(x: center.x + 52, y: wingY + 13))
        context.stroke(rightWing, with: .color(GroundControlPalette.warning), lineWidth: 3)

        let centerBox = Path(roundedRect: CGRect(x: center.x - 5, y: y - 5, width: 10, height: 10), cornerRadius: 2)
        context.fill(centerBox, with: .color(Color.black.opacity(0.5)))
        context.stroke(centerBox, with: .color(GroundControlPalette.warning), lineWidth: 2)

        var vertical = Path()
        vertical.move(to: CGPoint(x: center.x, y: y - 58))
        vertical.addLine(to: CGPoint(x: center.x, y: y + 42))
        context.stroke(vertical, with: .color(Color.green.opacity(0.9)), lineWidth: 1.5)
    }

    private func drawReferenceReadouts(context: inout GraphicsContext, frame: CGRect) {
        context.draw(
            Text(String(format: "R%+.0f", rollDegrees))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(GroundControlPalette.textSecondary),
            at: CGPoint(x: frame.minX + 24, y: frame.maxY - 14),
            anchor: .center
        )
        context.draw(
            Text(String(format: "P%+.0f", pitchDegrees))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(GroundControlPalette.textSecondary),
            at: CGPoint(x: frame.maxX - 24, y: frame.maxY - 14),
            anchor: .center
        )
    }

    private var boundedRoll: Double {
        clamped(rollDegrees.isFinite ? rollDegrees : 0.0, to: -75.0...75.0)
    }

    private var boundedPitch: Double {
        clamped(pitchDegrees.isFinite ? pitchDegrees : 0.0, to: -35.0...35.0)
    }
}

private struct FlightTapeView: View {
    let value: Double
    let targetValue: Double
    let labelKey: String
    let unit: String
    let majorStep: Double
    let minorStep: Double
    let visibleSpan: Double
    let valueFormatter: (Double) -> String
    let scaleFormatter: (Double) -> String
    var accessoryValue: Double?
    var accessoryLabelKey: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(LocalizedStringKey(labelKey))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity)

            Canvas(rendersAsynchronously: true) { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let tapeRect = rect.insetBy(dx: 4, dy: 4)
                context.fill(
                    Path(roundedRect: tapeRect, cornerRadius: 4),
                    with: .color(Color(red: 0.14, green: 0.18, blue: 0.20).opacity(0.88))
                )
                context.stroke(
                    Path(roundedRect: tapeRect, cornerRadius: 4),
                    with: .color(GroundControlPalette.borderStrong),
                    lineWidth: 1
                )

                drawScale(context: &context, rect: tapeRect)
                drawTargetMarker(context: &context, rect: tapeRect)
                drawValueBox(context: &context, rect: tapeRect)
                drawAccessory(context: &context, rect: tapeRect)
            }
        }
    }

    private func drawScale(context: inout GraphicsContext, rect: CGRect) {
        let centerY = rect.midY
        let current = safeValue
        let pixelsPerUnit = rect.height / visibleSpan
        let first = floor((current - visibleSpan / 2.0) / minorStep) * minorStep
        let last = current + visibleSpan / 2.0 + minorStep

        stride(from: first, through: last, by: minorStep).forEach { mark in
            let y = centerY - CGFloat((mark - current) * pixelsPerUnit)
            guard y >= rect.minY - 8, y <= rect.maxY + 8 else { return }
            let major = abs(mark.truncatingRemainder(dividingBy: majorStep)) < 0.001
            let x0 = rect.maxX - (major ? 24 : 14)
            var tick = Path()
            tick.move(to: CGPoint(x: x0, y: y))
            tick.addLine(to: CGPoint(x: rect.maxX - 4, y: y))
            context.stroke(
                tick,
                with: .color(GroundControlPalette.textSecondary.opacity(major ? 0.86 : 0.48)),
                lineWidth: major ? 1.1 : 0.8
            )

            guard major else { return }
            context.draw(
                Text(scaleFormatter(mark))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(GroundControlPalette.textPrimary.opacity(0.86)),
                at: CGPoint(x: rect.minX + 20, y: y),
                anchor: .center
            )
        }
    }

    private func drawTargetMarker(context: inout GraphicsContext, rect: CGRect) {
        guard targetValue.isFinite else { return }
        let pixelsPerUnit = rect.height / visibleSpan
        let delta = targetValue - safeValue
        let y = rect.midY - CGFloat(delta * pixelsPerUnit)
        guard y >= rect.minY + 8, y <= rect.maxY - 8 else { return }

        var marker = Path()
        marker.move(to: CGPoint(x: rect.minX + 2, y: y))
        marker.addLine(to: CGPoint(x: rect.minX + 13, y: y - 6))
        marker.addLine(to: CGPoint(x: rect.minX + 13, y: y + 6))
        marker.closeSubpath()
        context.fill(marker, with: .color(GroundControlPalette.warning))
    }

    private func drawValueBox(context: inout GraphicsContext, rect: CGRect) {
        let box = CGRect(x: rect.minX - 2, y: rect.midY - 18, width: rect.width + 4, height: 36)
        let boxPath = Path(roundedRect: box, cornerRadius: 4)
        context.fill(boxPath, with: .color(Color.black.opacity(0.74)))
        context.stroke(boxPath, with: .color(GroundControlPalette.warning.opacity(0.85)), lineWidth: 1.4)
        context.draw(
            Text(valueFormatter(safeValue))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(GroundControlPalette.textPrimary),
            at: CGPoint(x: box.midX, y: box.midY - 3),
            anchor: .center
        )
        context.draw(
            Text(unit)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(GroundControlPalette.textSecondary),
            at: CGPoint(x: box.midX, y: box.midY + 11),
            anchor: .center
        )
    }

    private func drawAccessory(context: inout GraphicsContext, rect: CGRect) {
        guard let accessoryValue, accessoryValue.isFinite, let accessoryLabelKey else { return }
        let label = localized(accessoryLabelKey)
        context.draw(
            Text(String(format: "%@ %+.1f", label, accessoryValue))
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(accessoryValue >= 0.0 ? GroundControlPalette.success : GroundControlPalette.warning),
            at: CGPoint(x: rect.midX, y: rect.maxY - 10),
            anchor: .center
        )
    }

    private var safeValue: Double {
        value.isFinite ? value : 0.0
    }
}

private struct HeadingTapeView: View {
    let headingDegrees: Double
    let targetBearingDegrees: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 4)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 4),
                with: .color(Color.black.opacity(0.55))
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 4),
                with: .color(GroundControlPalette.borderStrong),
                lineWidth: 1
            )

            let baselineY = rect.midY + 10
            let centerX = rect.midX
            let pixelsPerDegree = rect.width / 120.0

            var baseline = Path()
            baseline.move(to: CGPoint(x: rect.minX + 8, y: baselineY))
            baseline.addLine(to: CGPoint(x: rect.maxX - 8, y: baselineY))
            context.stroke(baseline, with: .color(GroundControlPalette.textSecondary.opacity(0.76)), lineWidth: 1)

            let start = floor(headingDegrees / 15.0) * 15.0 - 90.0
            let end = start + 195.0
            stride(from: start, through: end, by: 15.0).forEach { absoluteValue in
                let normalizedValue = normalized(absoluteValue)
                let delta = shortestDelta(from: headingDegrees, to: normalizedValue)
                let x = centerX + delta * pixelsPerDegree
                guard x >= rect.minX - 12, x <= rect.maxX + 12 else { return }

                let major = Int(normalizedValue.rounded()) % 30 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: baselineY - (major ? 14 : 8)))
                tick.addLine(to: CGPoint(x: x, y: baselineY))
                context.stroke(
                    tick,
                    with: .color(GroundControlPalette.textSecondary.opacity(major ? 0.86 : 0.52)),
                    lineWidth: major ? 1.1 : 0.8
                )

                guard major else { return }
                let label = headingLabel(normalizedValue)
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(normalizedValue == 0.0 ? GroundControlPalette.warning : GroundControlPalette.textSecondary),
                    at: CGPoint(x: x, y: baselineY - 23),
                    anchor: .center
                )
            }

            drawMarker(context: &context, x: centerX, baselineY: baselineY, color: GroundControlPalette.warning, label: "HDG")

            if targetBearingDegrees.isFinite {
                let delta = shortestDelta(from: headingDegrees, to: targetBearingDegrees)
                let x = centerX + delta * pixelsPerDegree
                if x >= rect.minX + 4, x <= rect.maxX - 4 {
                    drawMarker(context: &context, x: x, baselineY: baselineY, color: GroundControlPalette.success, label: localized("overlay.compass.marker.target"))
                }
            }
        }
    }

    private func drawMarker(
        context: inout GraphicsContext,
        x: CGFloat,
        baselineY: CGFloat,
        color: Color,
        label: String
    ) {
        var marker = Path()
        marker.move(to: CGPoint(x: x, y: baselineY - 31))
        marker.addLine(to: CGPoint(x: x - 5, y: baselineY - 22))
        marker.addLine(to: CGPoint(x: x + 5, y: baselineY - 22))
        marker.closeSubpath()
        context.fill(marker, with: .color(color))
        context.draw(
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(color),
            at: CGPoint(x: x, y: baselineY - 36),
            anchor: .center
        )
    }
}

private func headingLabel(_ heading: Double) -> String {
    switch Int(normalized(heading).rounded()) {
    case 0, 360:
        return localized("overlay.compass.metric.north")
    case 90:
        return "E"
    case 180:
        return "S"
    case 270:
        return "W"
    default:
        return String(format: "%03.0f", normalized(heading))
    }
}

private func normalized(_ value: Double) -> Double {
    let wrapped = value.truncatingRemainder(dividingBy: 360.0)
    return wrapped >= 0.0 ? wrapped : wrapped + 360.0
}

private func shortestDelta(from source: Double, to target: Double) -> CGFloat {
    let raw = (normalized(target) - normalized(source)).truncatingRemainder(dividingBy: 360.0)
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

private func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
