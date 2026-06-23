import SwiftUI

private func localized(_ key: String) -> String {
    L10n.s(key, language: L10n.currentLanguage())
}

struct ReplayTimelineEditorView: View {
    let duration: TimeInterval
    let events: [MissionReplayEvent]
    @Binding var currentTime: TimeInterval
    @Binding var trimRange: ReplayTrimRange
    let onSeek: (TimeInterval) -> Void

    private let handleWidth: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("replay.timeline.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                Text("\(fmt(trimRange.startTime)) - \(fmt(trimRange.endTime))  (\(fmt(trimRange.duration)))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            GeometryReader { proxy in
                timelineBody(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 42)
            .opacity(duration > 0 ? 1 : 0.45)
            .allowsHitTesting(duration > 0)
        }
    }

    private func timelineBody(width: CGFloat, height: CGFloat) -> some View {
        let safeDuration = max(0.001, duration)
        let clampedTrim = trimRange.clamped(to: safeDuration)
        let startX = x(for: clampedTrim.startTime, width: width, duration: safeDuration)
        let endX = x(for: clampedTrim.endTime, width: width, duration: safeDuration)
        let playheadX = x(for: currentTime, width: width, duration: safeDuration)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(GroundControlPalette.panelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(GroundControlPalette.border, lineWidth: 1)
                )

            Rectangle()
                .fill(GroundControlPalette.accent.opacity(0.18))
                .frame(width: max(1, endX - startX), height: height - 14)
                .offset(x: startX, y: 7)

            ForEach(events.prefix(300)) { event in
                eventMarker(event, width: width, height: height, duration: safeDuration)
            }

            rulerTicks(width: width, height: height, duration: safeDuration)

            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 2, height: height)
                .offset(x: playheadX)

            trimHandle(x: startX, height: height, isStart: true)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let t = time(for: value.location.x, width: width, duration: safeDuration)
                            trimRange = ReplayTrimRange(startTime: min(t, trimRange.endTime), endTime: trimRange.endTime)
                                .clamped(to: safeDuration)
                        }
                )

            trimHandle(x: endX - handleWidth, height: height, isStart: false)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let t = time(for: value.location.x, width: width, duration: safeDuration)
                            trimRange = ReplayTrimRange(startTime: trimRange.startTime, endTime: max(t, trimRange.startTime))
                                .clamped(to: safeDuration)
                        }
                )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = time(for: value.location.x, width: width, duration: safeDuration)
                    currentTime = t
                    onSeek(t)
                }
        )
    }

    private func eventMarker(_ event: MissionReplayEvent, width: CGFloat, height: CGFloat, duration: TimeInterval) -> some View {
        let markerX = x(for: event.timestamp, width: width, duration: duration)
        return Rectangle()
            .fill(eventColor(event.type))
            .frame(width: 2, height: height - 12)
            .offset(x: markerX, y: 6)
            .help(event.message)
    }

    private func rulerTicks(width: CGFloat, height: CGFloat, duration: TimeInterval) -> some View {
        let count = max(2, min(8, Int(width / 110)))
        return ZStack(alignment: .leading) {
            ForEach(0...count, id: \.self) { index in
                let fraction = Double(index) / Double(count)
                let tickX = CGFloat(fraction) * width
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: index == 0 || index == count ? height : 10)
                    .offset(x: tickX, y: index == 0 || index == count ? 0 : height - 12)
            }
        }
    }

    private func trimHandle(x: CGFloat, height: CGFloat, isStart: Bool) -> some View {
        let base = RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(GroundControlPalette.accent)
            .frame(width: handleWidth, height: height)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.50))
                    .frame(width: 1, height: height - 12)
            )
            .offset(x: x)
        if isStart {
            return base.help("replay.trim.start_tooltip")
        } else {
            return base.help("replay.trim.end_tooltip")
        }
    }

    private func x(for time: TimeInterval, width: CGFloat, duration: TimeInterval) -> CGFloat {
        CGFloat(max(0, min(1, time / duration))) * width
    }

    private func time(for x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        TimeInterval(max(0, min(1, x / max(1, width)))) * duration
    }

    private func fmt(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        let tenths = Int((t - Double(total)) * 10)
        if total < 60 { return String(format: "%d.%ds", total, tenths) }
        return String(format: "%dm%02ds", total / 60, total % 60)
    }

    private func eventColor(_ type: MissionReplayEventType) -> Color {
        switch type {
        case .warning, .recordingLimitReached:
            return GroundControlPalette.warning
        case .payloadReleased, .payloadImpact:
            return .orange
        case .missionAborted:
            return .red
        case .armed, .takeoff, .waypointReached, .missionCompleted:
            return .green
        default:
            return GroundControlPalette.accent
        }
    }
}

struct ReplayTelemetryGraphView: View {
    let series: [ReplayTelemetrySeries]
    let events: [MissionReplayEvent]
    let duration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                if let unit = series.first?.unit, !unit.isEmpty {
                    Text(localized(unit))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }

            GeometryReader { proxy in
                graph(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 86)
        }
        .padding(10)
        .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    private var title: String {
        if series.count == 1 { return localized(series[0].title) }
        return series.map { localized($0.title) }.joined(separator: " / ")
    }

    private func graph(width: CGFloat, height: CGFloat) -> some View {
        let allPoints = series.flatMap(\.points)
        let minValue = allPoints.map(\.value).min() ?? 0
        let maxValue = allPoints.map(\.value).max() ?? 1
        let span = max(0.001, maxValue - minValue)
        let safeDuration = max(0.001, duration)

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.20))

            ForEach(events.prefix(200)) { event in
                let x = CGFloat(max(0, min(1, event.timestamp / safeDuration))) * width
                Rectangle()
                    .fill(event.type == .warning ? GroundControlPalette.warning.opacity(0.55) : GroundControlPalette.accent.opacity(0.28))
                    .frame(width: 1, height: height)
                    .offset(x: x)
            }

            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                Path { path in
                    for (pointIndex, point) in item.points.enumerated() {
                        let px = CGFloat(max(0, min(1, point.timestamp / safeDuration))) * width
                        let py = height - CGFloat((point.value - minValue) / span) * height
                        if pointIndex == 0 {
                            path.move(to: CGPoint(x: px, y: py))
                        } else {
                            path.addLine(to: CGPoint(x: px, y: py))
                        }
                    }
                }
                .stroke(color(for: index), lineWidth: 1.8)
            }

            VStack {
                Text(String(format: "%.1f", maxValue))
                Spacer()
                Text(String(format: "%.1f", minValue))
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textSecondary)
            .padding(.leading, 4)
            .padding(.vertical, 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func color(for index: Int) -> Color {
        switch index % 4 {
        case 0: return GroundControlPalette.accent
        case 1: return .green
        case 2: return .orange
        default: return .pink
        }
    }
}
