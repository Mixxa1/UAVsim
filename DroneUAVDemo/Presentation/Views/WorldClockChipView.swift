import SwiftUI

/// World time, as its own small instrument.
///
/// Deliberately separate from the telemetry panel rather than a row inside it: putting the clock
/// in there stretched the translucent panel across the whole viewport for the sake of five
/// characters, and a wide mostly-empty panel reads as clutter over the scene.
struct WorldClockChipView: View {
    let time: String
    let phase: DayPhase
    /// Shown only while the world is running faster than real time — at 1× the multiplier is not
    /// information.
    let timeScale: SimulationTimeScale
    /// Steps the last frame actually managed. Shown instead of the requested multiplier when the
    /// machine cannot keep up, so a world running slower than its label says so.
    let achieved: Double

    private var isBehind: Bool {
        timeScale != .realtime && achieved < Double(timeScale.stepsPerFrame) * 0.8
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: phase.iconSystemName)
                .font(.caption)
                .foregroundStyle(GroundControlPalette.textSecondary)

            VStack(alignment: .trailing, spacing: 1) {
                Text(time)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(LocalizedStringKey(phase.titleKey))
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            if timeScale != .realtime {
                Text(isBehind ? String(format: "≈%.0f×", achieved) : timeScale.label)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(isBehind
                                     ? GroundControlPalette.warning
                                     : GroundControlPalette.textPrimary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(GroundControlPalette.textPrimary.opacity(0.18))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .fixedSize()
    }
}
