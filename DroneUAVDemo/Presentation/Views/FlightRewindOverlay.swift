import SwiftUI
import AppKit

/// Visible only while a transport control is held; it leaves the flight view interactive.
struct FlightRewindOverlay: View {
    @SimulationObservedObject var viewModel: DroneSimulationViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
                    HStack(spacing: -3) {
                        ForEach(0..<3) { index in
                            Image(systemName: "chevron.left")
                                .opacity(reduceMotion ? 1 : 0.3 + 0.7 * max(0, cos((phase + Double(index) / 3) * 2 * .pi)))
                        }
                    }
                    .font(.title3.weight(.heavy)).foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Перемотка назад").font(.headline)
                    Text(viewModel.rewindOffsetSeconds >= viewModel.rewindAvailableSeconds - 0.02
                         ? "Начало доступного полёта · отпустите кнопку"
                         : "Отпустите кнопку — продолжите полёт")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: "−%.1f с", viewModel.rewindOffsetSeconds))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .contentTransition(.identity)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.cyan.opacity(0.3)))
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// Uses the native button's press tracking, including release outside the button.
struct FlightRewindHoldButtonStyle: ButtonStyle {
    let onHoldChange: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onHoldChange(pressed) }
            .onDisappear { onHoldChange(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in onHoldChange(false) }
    }
}
