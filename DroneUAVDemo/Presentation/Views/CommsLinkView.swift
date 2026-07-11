import SwiftUI

/// Fiber-optic control-link equipment — a sibling section to the mission payload panel above it,
/// not a payload type itself (see `UAVControlLinkType`/`FiberSpoolModule`). An aircraft can carry
/// this alongside a camera/sprayer/etc. since it occupies its own equipment slot.
struct CommsLinkView: View {
    let fiberModule: FiberSpoolModule
    let isAttached: Bool
    let linkState: FiberLinkState

    let onRiggingChange: (FiberOpticReelClass, Double) -> Void
    let onAttach: () -> Void
    let onDetach: () -> Void

    /// Physical fiber remaining on the spool (not the margin-adjusted usable budget) — what
    /// actually determines the reel's live mass, mirrored from `updateFiberOpticTether`.
    private var remainingPhysicalLengthMeters: Float {
        max(0.0, fiberModule.totalLengthMeters - linkState.deployedLengthMeters)
    }

    private var liveMassKg: Float {
        fiberModule.reelClass.massForLength(remainingPhysicalLengthMeters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("comms_link.title")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))

            Text("comms_link.subtitle")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            // Only configurable before mounting — a real reel isn't swapped mid-flight, and a
            // severed one can't be "resized" back to working via the slider, only replaced.
            VStack(alignment: .leading, spacing: 12) {
                if isAttached {
                    Text("comms_link.rigging_locked")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Picker("", selection: Binding(
                    get: { fiberModule.reelClass },
                    set: { onRiggingChange($0, Double(fiberModule.totalLengthMeters)) }
                )) {
                    ForEach(FiberOpticReelClass.allCases) { value in
                        Text(LocalizedStringKey(value.titleKey)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("payload.fiber.reel_length")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.1f km", fiberModule.totalLengthMeters / 1000.0))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                    Slider(
                        value: Binding(
                            get: { Double(fiberModule.totalLengthMeters) },
                            set: { onRiggingChange(fiberModule.reelClass, $0) }
                        ),
                        in: Double(fiberModule.reelClass.lengthRangeMeters.lowerBound)...Double(fiberModule.reelClass.lengthRangeMeters.upperBound),
                        step: Double(fiberModule.reelClass.lengthStepMeters)
                    )
                }

                Text(String(format: NSLocalizedString("payload.fiber.rig_mass", comment: ""), fiberModule.spoolMassKg))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .disabled(isAttached)
            .opacity(isAttached ? 0.4 : 1.0)
            .padding(14)
            .background(Color(red: 0.86, green: 0.53, blue: 0.06).opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if isAttached {
                liveTelemetrySection
            }

            Button(action: isAttached ? onDetach : onAttach) {
                Text(isAttached ? "comms_link.detach" : "comms_link.attach")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isAttached ? .red : .accentColor)
        }
        .padding(14)
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var liveTelemetrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            telemetryRow(
                titleKey: "comms_link.telemetry.remaining",
                value: String(format: "%.1f / %.1f km", linkState.remainingLengthMeters / 1000.0, linkState.usableLengthMeters / 1000.0)
            )
            telemetryRow(
                titleKey: "comms_link.telemetry.deployed",
                value: String(format: "%.0f m", linkState.deployedLengthMeters)
            )
            telemetryRow(
                titleKey: "comms_link.telemetry.mass",
                value: String(format: "%.1f kg", liveMassKg)
            )
            telemetryRow(
                titleKey: "comms_link.telemetry.snag_risk",
                value: String(format: "%.0f%%", linkState.snagRiskLevel * 100.0),
                valueColor: linkState.snagRiskLevel > 0.6 ? .red : (linkState.snagRiskLevel > FiberOpticTetherTuning.degradedSnagRiskThreshold ? .orange : .white.opacity(0.8))
            )

            if linkState.status != .connected {
                Text(severedOrDegradedMessageKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(linkState.status == .broken ? Color.red : Color.orange)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var severedOrDegradedMessageKey: LocalizedStringKey {
        guard linkState.status == .broken else {
            return "comms_link.degraded_warning"
        }
        return linkState.isSnagged ? "comms_link.severed_snagged" : "comms_link.severed_exhausted"
    }

    private func telemetryRow(titleKey: String, value: String, valueColor: Color = .white.opacity(0.8)) -> some View {
        HStack {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(valueColor)
        }
    }
}
