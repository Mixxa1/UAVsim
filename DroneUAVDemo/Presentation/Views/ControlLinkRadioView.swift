import SwiftUI

/// The radio control link — the other half of the comms window, next to the fiber spool.
///
/// The point of the panel is one trade: an air rate is bought with receiver sensitivity, and the
/// band is bought with path loss. Both are shown as the numbers they are, and the range figure
/// under them is derived from those numbers rather than quoted, so raising the rate visibly costs
/// the operator distance instead of being asserted to.
struct ControlLinkRadioView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private var fitted: Bool { viewModel.controlLinkConfiguration != nil }
    private var configuration: ELRSConfiguration {
        viewModel.controlLinkConfiguration ?? .default
    }
    private var mode: ELRSMode { configuration.mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !viewModel.controlLinkAppliesToAircraft {
                Text("control_link.authored_suite")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if fitted {
                bandPicker
                modePicker
                HStack(alignment: .top, spacing: 14) {
                    telemetryPicker
                    powerPicker
                }
                readouts
            } else {
                Text("control_link.stock_hint")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!viewModel.controlLinkAppliesToAircraft)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            GroundControlPalette.inset,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text("control_link.title")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 6)
                // Labelled as what it does — fit the module or fly the stock receiver — because a
                // bare switch beside a section title reads as a switch for the whole section.
                Toggle(isOn: Binding(
                    get: { fitted },
                    set: { viewModel.setControlLinkFitted($0) }
                )) {
                    Text("control_link.fit_module")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            Text("control_link.subtitle")
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bandPicker: some View {
        HStack(spacing: 8) {
            ForEach(ELRSBand.allCases, id: \.self) { band in
                let isSelected = mode.band == band
                Button {
                    // Keep the operator on the rate they were flying where the other band has one,
                    // rather than dropping them onto whatever happens to be first in the list.
                    let candidates = ELRSLinkCatalog.modes(for: band)
                    let match = candidates.first { $0.packetRateHz == mode.packetRateHz }
                    viewModel.setControlLinkMode(match ?? ELRSLinkCatalog.defaultMode(for: band))
                } label: {
                    Text(LocalizedStringKey(band.titleKey))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected
                                      ? GroundControlPalette.accent.opacity(0.20)
                                      : GroundControlPalette.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(isSelected
                                        ? GroundControlPalette.accent.opacity(0.55)
                                        : GroundControlPalette.border, lineWidth: 1)
                        )
                        .foregroundStyle(isSelected
                                         ? GroundControlPalette.textPrimary
                                         : GroundControlPalette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Column headings: without them the two numbers on each row are unexplained, and the
            // whole point of the list is that they are the two sides of one trade.
            HStack(spacing: 8) {
                Text("control_link.rate")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 4)
                Text("control_link.column.sensitivity")
                    .font(.system(size: 9))
                    .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.75))
                Text("control_link.column.range")
                    .font(.system(size: 9))
                    .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.75))
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 9)
            ForEach(ELRSLinkCatalog.modes(for: mode.band)) { candidate in
                let isSelected = candidate.id == mode.id
                Button {
                    viewModel.setControlLinkMode(candidate)
                } label: {
                    HStack(spacing: 8) {
                        Text(candidate.displayName)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected
                                             ? GroundControlPalette.textPrimary
                                             : GroundControlPalette.textSecondary)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f dBm", candidate.sensitivityDBm))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Text(String(
                            format: "%.0f км",
                            candidate.freeSpaceRangeM(
                                txPowerDBm: configuration.transmitPowerDBm
                            ) / 1000
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isSelected
                                         ? GroundControlPalette.accent
                                         : GroundControlPalette.textSecondary)
                        .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected
                                  ? GroundControlPalette.accent.opacity(0.14)
                                  : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var telemetryPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("control_link.telemetry")
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Picker("", selection: Binding(
                get: { configuration.telemetryRatio },
                set: { viewModel.setControlLinkTelemetryRatio($0) }
            )) {
                ForEach(ELRSTelemetryRatio.allCases) { ratio in
                    Text(ratio.displayName).tag(ratio)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 96)
        }
    }

    private var powerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("control_link.power")
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Picker("", selection: Binding(
                get: { configuration.transmitPowerDBm },
                set: { viewModel.setControlLinkTransmitPowerDBm($0) }
            )) {
                ForEach(ELRSLinkCatalog.transmitPowerLevelsDBm, id: \.self) { power in
                    Text(String(format: "%.0f мВт", pow(10, power / 10))).tag(power)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(titleKey: "control_link.sensitivity",
                value: String(format: "%.0f dBm", mode.sensitivityDBm))
            row(titleKey: "control_link.slot_latency",
                value: String(format: "%.1f мс", mode.slotLatencyMS))
            row(titleKey: "control_link.range",
                value: String(
                    format: "%.0f км",
                    mode.freeSpaceRangeM(txPowerDBm: configuration.transmitPowerDBm) / 1000
                ))
            // What the telemetry setting actually costs, in the currency it is spent in.
            row(titleKey: "control_link.uplink_slots",
                value: String(
                    format: "%.1f%%",
                    (1 - configuration.telemetryRatio.dutyCycle) * 100
                ))
            Text("control_link.range_note")
                .font(.system(size: 9))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(titleKey: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(titleKey))
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
    }
}
