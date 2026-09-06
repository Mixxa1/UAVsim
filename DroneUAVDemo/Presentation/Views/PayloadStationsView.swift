import SwiftUI

/// The aircraft's payload stations, and what is hanging on each.
///
/// Separate from `PayloadView` on purpose: that panel edits the one primary payload the mission
/// runtime is built around, while this one is about the airframe's other stations — where they
/// are, what they can take, and how much of the mass budget is left.
struct PayloadStationsView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    @State private var lastRejection: PayloadLoadoutRejection?
    @State private var expandedMount: PayloadMount?

    private var capabilities: [PayloadMountCapability] {
        viewModel.payloadMountCapabilities
    }

    /// Which station the payload view is actually showing: the operator's choice, or the first
    /// fitted camera when nothing has been chosen.
    private var liveCameraStation: PayloadMount? {
        viewModel.activeCameraStation ?? viewModel.cameraStations.first?.mount
    }

    var body: some View {
        // Styled as one of the payload window's own consoles rather than as a standalone card:
        // it is rendered inside that window's shell, and its own chrome made it read as an
        // unrelated panel floating underneath.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("payload.stations.title")
                    .font(.caption.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer(minLength: 6)
                Text("payload.stations.subtitle")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.40))
                    .lineLimit(1)
            }

            if capabilities.count <= 1 {
                Text("payload.stations.single")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }

            massSummary

            if !viewModel.cameraStations.isEmpty {
                Text("payload.stations.feed_hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(capabilities, id: \.mount) { capability in
                stationRow(capability)
            }

            if let lastRejection {
                Text(LocalizedStringKey(lastRejection.messageKey))
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(consoleChrome)
    }

    /// Matches `PayloadView`'s own console chrome — same radius, gradient, hairline and accent tab.
    private var consoleChrome: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.045), Color.black.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.065), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(GroundControlPalette.accent.opacity(0.52))
                    .frame(width: 38, height: 3)
                    .offset(x: 14, y: -1)
            }
    }

    private var massSummary: some View {
        HStack(spacing: 8) {
            Text("payload.stations.remaining")
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(String(
                format: "%.2f / %.2f кг",
                viewModel.remainingPayloadMassKg,
                viewModel.airframePayloadLimitKg
            ))
            .font(.caption.monospaced())
            .foregroundStyle(viewModel.remainingPayloadMassKg > 0.001
                             ? GroundControlPalette.textPrimary
                             : GroundControlPalette.warning)
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private func stationRow(_ capability: PayloadMountCapability) -> some View {
        let entry = viewModel.installedLoadout.entry(at: capability.mount)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(capability.mount.titleKey))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(String(format: "до %.2f кг", capability.massLimitKg))
                    .font(.caption2.monospaced())
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .frame(width: 150, alignment: .leading)

            if let entry {
                if let module = entry.cameraModule {
                    PayloadLivePreviewView(
                        configuration: entry.configuration,
                        cameraModule: module
                    )
                    .frame(width: 52, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.displayName)
                            .font(.caption)
                            .foregroundStyle(GroundControlPalette.textPrimary)
                        Text(String(
                            format: "%.0f°  %.2f кг",
                            module.horizontalFieldOfViewDegrees,
                            module.massKg
                        ))
                        .font(.caption2.monospaced())
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    }
                } else {
                    Text(entry.configuration.payloadType.title)
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textPrimary)
                }

                Spacer(minLength: 4)

                if entry.cameraModule != nil {
                    let isLive = liveCameraStation == capability.mount
                    Button {
                        viewModel.selectCameraStation(capability.mount)
                    } label: {
                        Label(
                            isLive ? "payload.stations.on_air" : "payload.stations.show_feed",
                            systemImage: isLive ? "dot.radiowaves.left.and.right" : "play.rectangle"
                        )
                        .font(.caption2.weight(isLive ? .bold : .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLive
                                     ? GroundControlPalette.success
                                     : GroundControlPalette.accent)
                    .disabled(isLive)
                }

                Button("payload.stations.remove") {
                    lastRejection = nil
                    viewModel.removePayload(at: capability.mount)
                }
                .font(.caption2)
            } else {
                Spacer(minLength: 4)
                Button {
                    expandedMount = expandedMount == capability.mount ? nil : capability.mount
                    lastRejection = nil
                } label: {
                    Label(
                        "payload.stations.fit_camera",
                        systemImage: expandedMount == capability.mount ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GroundControlPalette.accent)
            }
        }
        .padding(.vertical, 4)

        if expandedMount == capability.mount, viewModel.installedLoadout.entry(at: capability.mount) == nil {
            moduleChooser(for: capability)
        }
    }

    /// Only what actually fits: the station's own limit and the airframe's remaining budget both
    /// apply, so an overweight module is never offered and then rejected.
    @ViewBuilder
    private func moduleChooser(for capability: PayloadMountCapability) -> some View {
        let limit = min(capability.massLimitKg, viewModel.remainingPayloadMassKg)
        let modules = CameraModuleCatalog.modules(fittingWithinMassKg: limit)
        if modules.isEmpty {
            Text("payload.stations.nothing_fits")
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.warning)
                .padding(.leading, 150)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(modules) { module in
                        moduleCard(module, mount: capability.mount)
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.leading, 150)
        }
    }

    private func moduleCard(_ module: CameraModule, mount: PayloadMount) -> some View {
        Button {
            install(module, at: mount)
            expandedMount = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                PayloadLivePreviewView(
                    configuration: previewConfiguration(for: module),
                    cameraModule: module
                )
                .frame(width: 118, height: 74)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28)))

                Text(module.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .lineLimit(1)
                Text(String(
                    format: "%.0f°→%.0f°  %.2f кг",
                    module.horizontalFieldOfViewDegrees,
                    module.narrowestFieldOfViewDegrees,
                    module.massKg
                ))
                .font(.system(size: 9).monospaced())
                .foregroundStyle(GroundControlPalette.textSecondary)
                HStack(spacing: 4) {
                    // A LocalizedStringKey built from an interpolated literal becomes the format key
                    // "camera.spectrum.%@" and never resolves; the String initialiser looks up the
                    // key that was actually written.
                    Text(LocalizedStringKey("camera.spectrum." + module.spectrum.rawValue))
                        .font(.system(size: 9))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    // A hybrid turret carries more than one sensor, and which ones it has decides
                    // whether the thermal view is reachable at all — so it belongs on the card.
                    if module.channels.count > 1 {
                        ForEach(module.availableChannels, id: \.self) { channel in
                            Text(LocalizedStringKey(channel.titleKey))
                                .font(.system(size: 8).weight(.semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(GroundControlPalette.accent.opacity(0.18))
                                )
                                .foregroundStyle(GroundControlPalette.accent)
                        }
                    }
                }
            }
            .padding(7)
            .frame(width: 132, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(GroundControlPalette.panelRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func previewConfiguration(for module: CameraModule) -> PayloadConfiguration {
        PayloadConfiguration(
            payloadType: module.spectrum == .longwaveInfrared ? .thermalCamera : .cameraGimbal,
            customName: module.displayName,
            payloadMass: Float(module.massKg)
        )
    }

    private func install(_ module: CameraModule, at mount: PayloadMount) {
        let configuration = PayloadConfiguration(
            payloadType: module.spectrum == .longwaveInfrared ? .thermalCamera : .cameraGimbal,
            customName: module.displayName,
            payloadMass: Float(module.massKg)
        )
        lastRejection = viewModel.installPayload(
            configuration,
            at: mount,
            cameraModuleID: module.id
        )
    }
}
