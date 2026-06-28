import SwiftUI

/// Preflight setup for a flight mission: pick a scenario, edit its parameters, choose the UAV
/// and payload, then start. Builds a `MissionScenarioConfiguration` handed to the simulation.
struct MissionSetupView: View {
    let availableProfiles: [DroneModelProfile]
    let onCancel: () -> Void
    let onStart: (MissionScenarioConfiguration) -> Void

    @State private var kind: MissionScenarioKind = .searchAndRescue
    @State private var difficulty: MissionDifficulty = .medium
    @State private var terrain: TerrainPreset = .forest
    @State private var weather: WeatherPreset = .normal
    @State private var weatherIntensity: Double = 0.3
    @State private var timeOfDay: TimeOfDay = .day
    @State private var timeLimitMinutes: Int = MissionDifficulty.medium.defaultTimeLimitMinutes
    @State private var selectedProfileID: String = ""
    @State private var payload: PayloadType = .thermalCamera

    private var resolvedProfile: DroneModelProfile? {
        availableProfiles.first { $0.id == selectedProfileID } ?? availableProfiles.first
    }

    private var compatiblePayloads: [PayloadType] {
        kind.compatiblePayloads
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scenarioSection
                    parametersSection
                    platformSection
                }
                .padding(20)
            }

            footer
        }
        .frame(maxWidth: 720, maxHeight: 720)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            if selectedProfileID.isEmpty {
                selectedProfileID = availableProfiles.first?.id ?? ""
            }
            if !compatiblePayloads.contains(payload) {
                payload = compatiblePayloads.first ?? .thermalCamera
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("mission.setup.title")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("mission.setup.subtitle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    private var scenarioSection: some View {
        sectionCard(titleKey: "mission.setup.section.scenario") {
            HStack(spacing: 12) {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(kind.titleKey))
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(LocalizedStringKey(kind.subtitleKey))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
        }
    }

    private var parametersSection: some View {
        sectionCard(titleKey: "mission.setup.section.parameters") {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("mission.setup.difficulty") {
                    Picker("", selection: $difficulty) {
                        ForEach(MissionDifficulty.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: difficulty) { _, newValue in
                        timeLimitMinutes = newValue.defaultTimeLimitMinutes
                    }
                }

                labeledRow("mission.setup.time_of_day") {
                    Picker("", selection: $timeOfDay) {
                        ForEach(TimeOfDay.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                labeledRow("mission.setup.terrain") {
                    Picker("", selection: $terrain) {
                        ForEach(TerrainPreset.available(for: resolvedProfile?.airframeClass ?? .multirotor)) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.white)
                }

                labeledRow("mission.setup.weather") {
                    Picker("", selection: $weather) {
                        ForEach(WeatherPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("mission.setup.weather_intensity")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.0f%%", weatherIntensity * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                    Slider(value: $weatherIntensity, in: 0...1, step: 0.01)
                }

                Stepper(value: $timeLimitMinutes, in: 3...30) {
                    HStack {
                        Text("mission.setup.time_limit")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: NSLocalizedString("mission.setup.time_limit.value", comment: ""), timeLimitMinutes))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private var platformSection: some View {
        sectionCard(titleKey: "mission.setup.section.platform") {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("mission.setup.uav") {
                    Picker("", selection: $selectedProfileID) {
                        ForEach(availableProfiles) { profile in
                            Text(profile.uiDisplayName).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.white)
                }

                labeledRow("mission.setup.payload") {
                    Picker("", selection: $payload) {
                        ForEach(compatiblePayloads) { type in
                            Text(LocalizedStringKey(payloadTitleKey(type))).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.white)
                }

                Text("mission.setup.payload.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text("common.cancel")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: start) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("mission.setup.start")
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(GroundControlPalette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(resolvedProfile == nil)
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    // MARK: Helpers

    private func start() {
        guard let profile = resolvedProfile else { return }
        let parameters = MissionScenarioParameters(
            kind: kind,
            terrain: terrain,
            difficulty: difficulty,
            weather: weather,
            weatherIntensity: Float(weatherIntensity),
            timeOfDay: timeOfDay,
            timeLimitMinutes: timeLimitMinutes
        )
        let config = MissionScenarioConfiguration(
            parameters: parameters,
            selectedUAVProfileID: profile.id,
            payloadType: payload
        )
        onStart(config)
    }

    private func payloadTitleKey(_ type: PayloadType) -> String {
        switch type {
        case .thermalCamera: return "payload.type.thermal_camera"
        case .cameraGimbal: return "payload.type.camera_gimbal"
        case .laserRangefinder: return "payload.type.laser_rangefinder"
        case .lidarModule: return "payload.type.lidar_module"
        case .cargoBox: return "payload.type.cargo_box"
        case .rescuePack: return "payload.type.rescue_pack"
        case .sensorModule: return "payload.type.sensor_module"
        case .radioRelay: return "payload.type.radio_relay"
        case .custom: return "payload.type.custom"
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func labeledRow<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }
}
