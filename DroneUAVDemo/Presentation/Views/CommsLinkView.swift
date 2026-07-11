import SwiftUI

/// Fiber-optic control-link equipment — a sibling section to the mission payload panel above it,
/// not a payload type itself (see `UAVControlLinkType`/`FiberSpoolModule`). An aircraft can carry
/// this alongside a camera/sprayer/etc. since it occupies its own equipment slot.
struct CommsLinkView: View {
    let controlLinkType: UAVControlLinkType
    let operationalStatus: MissionOperationalStatus
    let linkLossPolicy: LinkLossPolicy
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("comms_link.title")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(GroundControlPalette.textSecondary)

                Text("comms_link.subtitle")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                if controlLinkType == .radio {
                    radioLinkSection
                }

                // Only configurable before mounting — a real reel isn't swapped mid-flight, and a
                // severed one can't be "resized" back to working via the slider, only replaced.
                VStack(alignment: .leading, spacing: 12) {
                    if isAttached {
                        Text("comms_link.rigging_locked")
                            .font(.caption2)
                            .foregroundStyle(GroundControlPalette.textSecondary)
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

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("payload.fiber.reel_length")
                                .font(.caption).foregroundStyle(GroundControlPalette.textPrimary.opacity(0.85))
                            Spacer()
                            Text(String(format: "%.1f km", fiberModule.totalLengthMeters / 1000.0))
                                .font(.caption.monospacedDigit()).foregroundStyle(GroundControlPalette.textPrimary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(fiberModule.totalLengthMeters) },
                                set: { onRiggingChange(fiberModule.reelClass, $0) }
                            ),
                            in: Double(fiberModule.reelClass.lengthRangeMeters.lowerBound)...Double(fiberModule.reelClass.lengthRangeMeters.upperBound),
                            step: Double(fiberModule.reelClass.lengthStepMeters)
                        )
                        lengthPresetChips
                    }

                    Text(String(format: NSLocalizedString("payload.fiber.rig_mass", comment: ""), fiberModule.spoolMassKg))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                .disabled(isAttached)
                .opacity(isAttached ? 0.4 : 1.0)
                .padding(14)
                .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(GroundControlPalette.border, lineWidth: 1)
                )

                if isAttached {
                    liveTelemetrySection
                }

                Button(action: isAttached ? onDetach : onAttach) {
                    Text(isAttached ? "comms_link.detach" : "comms_link.attach")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isAttached ? GroundControlPalette.warning : GroundControlPalette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FiberSpoolIllustrationView(
                reelClass: fiberModule.reelClass,
                totalLengthMeters: fiberModule.totalLengthMeters,
                isAttached: isAttached
            )
            .frame(width: 132)
        }
        .padding(16)
        .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    /// Five evenly-spaced quick-pick lengths across the selected reel class's range, in addition
    /// to the fine slider — a single coarse-stepped slider made it hard to land on a specific
    /// "round" length quickly.
    private var lengthPresetMeters: [Float] {
        let range = fiberModule.reelClass.lengthRangeMeters
        let steps = 4
        return (0...steps).map { index in
            range.lowerBound + (range.upperBound - range.lowerBound) * Float(index) / Float(steps)
        }
    }

    private var lengthPresetChips: some View {
        HStack(spacing: 6) {
            ForEach(lengthPresetMeters, id: \.self) { preset in
                let isSelected = abs(preset - fiberModule.totalLengthMeters) < fiberModule.reelClass.lengthStepMeters * 0.5
                Button {
                    onRiggingChange(fiberModule.reelClass, Double(preset))
                } label: {
                    Text(preset >= 1000 ? String(format: "%.1fkm", preset / 1000.0) : String(format: "%.0fm", preset))
                        .font(.caption2.monospacedDigit().weight(isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSelected ? GroundControlPalette.accent.opacity(0.30) : GroundControlPalette.inset,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? GroundControlPalette.accent.opacity(0.65) : GroundControlPalette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Radio link-quality readout — a live gradient of distance-from-home vs. this airframe's
    /// nominal radio range (`MissionOperationalStatus.currentLinkQuality`), independent of both
    /// the fiber rigging below and the map's authored/detail boundary. Only shown while the
    /// aircraft is actually on radio (`UAVControlLinkType`), since fiber bypasses this system.
    @ViewBuilder
    private var radioLinkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            telemetryRow(
                titleKey: "comms_link.radio.quality",
                value: "\(Int((operationalStatus.currentLinkQuality * 100.0).rounded()))%",
                valueColor: radioZoneColor
            )
            telemetryRow(
                titleKey: "comms_link.radio.zone",
                value: NSLocalizedString(radioZoneTitleKey, comment: ""),
                valueColor: radioZoneColor
            )

            if operationalStatus.isLinkLost {
                Text(linkLossPolicy == .strandedWithoutInput
                    ? "comms_link.radio.lost_stranded"
                    : "comms_link.radio.lost_failsafe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.warning)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var radioZoneTitleKey: String {
        if operationalStatus.isLinkLost { return "comms_link.radio.zone.lost" }
        if operationalStatus.isInCriticalLinkZone { return "comms_link.radio.zone.critical" }
        if operationalStatus.isInWarningLinkZone { return "comms_link.radio.zone.degraded" }
        return "comms_link.radio.zone.stable"
    }

    private var radioZoneColor: Color {
        if operationalStatus.isLinkLost { return GroundControlPalette.warning }
        if operationalStatus.isInCriticalLinkZone { return GroundControlPalette.warning }
        if operationalStatus.isInWarningLinkZone { return GroundControlPalette.warning.opacity(0.8) }
        return GroundControlPalette.textPrimary
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
                valueColor: linkState.snagRiskLevel > 0.6
                    ? GroundControlPalette.warning
                    : (linkState.snagRiskLevel > FiberOpticTetherTuning.degradedSnagRiskThreshold
                        ? GroundControlPalette.warning.opacity(0.8)
                        : GroundControlPalette.textPrimary)
            )

            if linkState.status != .connected {
                Text(severedOrDegradedMessageKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.warning)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var severedOrDegradedMessageKey: LocalizedStringKey {
        guard linkState.status == .broken else {
            return "comms_link.degraded_warning"
        }
        return linkState.isSnagged ? "comms_link.severed_snagged" : "comms_link.severed_exhausted"
    }

    private func telemetryRow(titleKey: String, value: String, valueColor: Color = GroundControlPalette.textPrimary) -> some View {
        HStack {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(GroundControlPalette.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(valueColor)
        }
    }
}

/// A stylized side view of the physical reel — real fiber-optic FPV tether spools are compact
/// black ABS-plastic canisters (inner-winding drum, not an exposed open bobbin) with a small
/// outlet where the fiber leader exits. Purely a vector illustration (no photo asset), scaled to
/// suggest a bigger canister for a longer rigged length.
private struct FiberSpoolIllustrationView: View {
    let reelClass: FiberOpticReelClass
    let totalLengthMeters: Float
    let isAttached: Bool

    private var fillFraction: CGFloat {
        let range = reelClass.lengthRangeMeters
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return CGFloat(((totalLengthMeters - range.lowerBound) / (range.upperBound - range.lowerBound)))
            .clamped(to: 0.0...1.0)
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let capHeight = width * 0.30
                let bodyHeight = geometry.size.height - capHeight * 1.4
                let bodyTop = capHeight * 0.7

                ZStack {
                    // Bottom cap — drawn first, fully dark, reads as the far edge of the drum.
                    Ellipse()
                        .fill(Color(white: 0.05))
                        .frame(width: width, height: capHeight)
                        .position(x: width / 2, y: bodyTop + bodyHeight)

                    // Cylindrical body — a subtle left-to-right sheen gradient on near-black ABS
                    // plastic, not a flat fill, so it still reads as a solid object rather than a
                    // silhouette.
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(white: 0.16),
                                    Color(white: 0.07),
                                    Color(white: 0.03)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width, height: bodyHeight)
                        .position(x: width / 2, y: bodyTop + bodyHeight / 2)

                    // Top cap — a touch lighter than the body, the near edge catching more light.
                    Ellipse()
                        .fill(Color(white: 0.13))
                        .frame(width: width, height: capHeight)
                        .position(x: width / 2, y: bodyTop)
                    Ellipse()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        .frame(width: width, height: capHeight)
                        .position(x: width / 2, y: bodyTop)

                    // Fiber leader — a thin pale line paying out from a small outlet nub, curling
                    // down past the canister (mirrors the real "inner-winding capsule" outlet).
                    let outletY = bodyTop + bodyHeight * 0.62
                    Path { path in
                        path.move(to: CGPoint(x: width * 0.88, y: outletY))
                        path.addCurve(
                            to: CGPoint(x: width * 0.62, y: bodyTop + bodyHeight + capHeight * 0.5),
                            control1: CGPoint(x: width * 1.05, y: outletY + bodyHeight * 0.18),
                            control2: CGPoint(x: width * 0.80, y: bodyTop + bodyHeight + capHeight * 0.1)
                        )
                    }
                    .stroke(Color(white: 0.75).opacity(0.55), lineWidth: 1.1)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(white: 0.09))
                        .frame(width: width * 0.14, height: capHeight * 0.34)
                        .position(x: width * 0.9, y: outletY)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .opacity(isAttached ? 1.0 : 0.8)

            VStack(spacing: 2) {
                Text(LocalizedStringKey(reelClass.titleKey))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Text(String(format: "%.1f km", totalLengthMeters / 1000.0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
