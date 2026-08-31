import SwiftUI

/// The in-scene track builder's panel: the palette of equipment, the piece's current pose, the
/// track's own settings, and the key legend.
///
/// Deliberately a panel rather than a modal editor. The track is built in the flying scene, with
/// the world paused around it, so everything here has to sit beside the view the pilot is aiming
/// with — never on top of it.
struct RaceBuilderPanelView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @State private var trackName: String = ""
    @State private var laps: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            palette
            passageRow
            poseRow
            trackRow
            actionRow
            legend
            if let statusKey = viewModel.raceBuilderStatusKey {
                Text(LocalizedStringKey(statusKey))
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(GroundControlPalette.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .onAppear {
            trackName = viewModel.raceTrack?.name ?? ""
            laps = viewModel.raceTrack?.laps ?? 3
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .foregroundStyle(GroundControlPalette.accent)
            Text("race.builder.title")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Text(String(
                format: NSLocalizedString("race.builder.gate_count", comment: ""),
                viewModel.raceTrack?.gateCount ?? 0
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("race.builder.palette")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88, maximum: 140), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(viewModel.raceBuilderPalette) { descriptor in
                        Button {
                            viewModel.selectRaceBuilderElement(catalogID: descriptor.id)
                        } label: {
                            paletteCell(descriptor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 168)
        }
    }

    private func paletteCell(_ descriptor: RacingElementDescriptor) -> some View {
        let isSelected = descriptor.id == viewModel.raceBuilderSelectedDescriptor?.id
        return VStack(spacing: 4) {
            Image(systemName: descriptor.iconSystemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? GroundControlPalette.accent : .white.opacity(0.8))
            Text(LocalizedStringKey(descriptor.titleKey))
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.7))
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(
            Color.white.opacity(isSelected ? 0.14 : 0.05),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? GroundControlPalette.accent : .clear, lineWidth: 1)
        )
    }

    /// Which way through the selected piece this placement will use. Hidden for pieces that have
    /// only one, so the row never asks a question with a single answer.
    @ViewBuilder
    private var passageRow: some View {
        if viewModel.raceBuilderPassageCount > 1, let titleKey = viewModel.raceBuilderPassageTitleKey {
            Button {
                viewModel.cycleRaceBuilderPassage()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .font(.system(size: 10, weight: .semibold))
                    Text("race.builder.passage")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(LocalizedStringKey(titleKey))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(viewModel.raceBuilderApertureIndex + 1)/\(viewModel.raceBuilderPassageCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(GroundControlPalette.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var poseRow: some View {
        HStack(spacing: 12) {
            poseValue(
                titleKey: "race.builder.pose.yaw",
                value: String(format: "%.0f°", viewModel.raceBuilderYawDegrees)
            )
            poseValue(
                titleKey: "race.builder.pose.scale",
                value: String(format: "%.2f×", viewModel.raceBuilderScale)
            )
            poseValue(
                titleKey: "race.builder.pose.height",
                value: String(format: "%.1f m", viewModel.raceBuilderHeightMeters)
            )
        }
    }

    private func poseValue(titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("race.builder.name_placeholder", text: $trackName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Stepper(value: $laps, in: 1...10) {
                HStack {
                    Text("race.setup.laps")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("\(laps)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                }
            }
            .onChange(of: laps) { _, newValue in
                viewModel.setRaceBuilderLaps(newValue)
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                actionButton("race.builder.action.place", icon: "plus.circle.fill", tint: GroundControlPalette.accent) {
                    viewModel.placeRaceBuilderElement()
                }
                actionButton("race.builder.action.delete", icon: "trash.fill", tint: GroundControlPalette.danger) {
                    viewModel.deleteRaceBuilderElementUnderAim()
                }
            }
            HStack(spacing: 6) {
                actionButton("race.builder.action.generate", icon: "wand.and.stars", tint: GroundControlPalette.panelRaised) {
                    viewModel.generateRaceBuilderTrack()
                }
                actionButton("race.builder.action.clear", icon: "xmark.bin", tint: GroundControlPalette.panelRaised) {
                    viewModel.clearRaceBuilderTrack()
                }
            }
            HStack(spacing: 6) {
                actionButton("race.builder.action.save", icon: "square.and.arrow.down.fill", tint: GroundControlPalette.success) {
                    viewModel.saveRaceBuilderTrack(name: trackName)
                }
                actionButton("race.builder.action.exit", icon: "airplane.departure", tint: GroundControlPalette.panelRaised) {
                    viewModel.setRaceTrackBuilder(active: false)
                }
            }
        }
    }

    private func actionButton(
        _ titleKey: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("race.builder.legend.title")
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.45))
            Text("race.builder.legend.body")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
