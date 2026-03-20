import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Binding var appLanguage: AppLanguage

    @State private var showAbstractEditor: Bool = false

    @State private var sectionFlightExpanded: Bool = true
    @State private var sectionCameraExpanded: Bool = true
    @State private var sectionEnvironmentExpanded: Bool = true
    @State private var sectionDiagnosticsExpanded: Bool = false
    @State private var sectionAdvancedExpanded: Bool = false
    @State private var advancedCameraExpanded: Bool = false

    private static let coordinateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let angleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let throttleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                languageSection
                flightSection
                cameraSection
                environmentSection
                diagnosticsSection
                advancedSection
                telemetrySection
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAbstractEditor) {
            AbstractModelEditorView(initial: viewModel.abstractParameters) { updated in
                viewModel.applyAbstractParameters(updated)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("panel.title")
                .font(.title3.weight(.semibold))
            Text("panel.workflow_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("language.section")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("language.section", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.titleKey)).tag(language)
                    }
                }

                HStack(spacing: 8) {
                    Button("ui.toggle_telemetry_hud") {
                        viewModel.toggleCompactTelemetryHUD()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 2)
        }
    }

    private var flightSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $sectionFlightExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    modelSection

                    Picker("control_mode.title", selection: Binding(
                        get: { viewModel.flightControlMode },
                        set: { viewModel.setFlightControlMode($0) }
                    )) {
                        ForEach(FlightControlMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("command.reset") { viewModel.reset() }
                        Button("command.takeoff") { viewModel.takeoff() }
                        Button("command.land") { viewModel.land() }
                    }

                    HStack(spacing: 8) {
                        Button("command.hover") { viewModel.hover() }
                        Button("command.auto_path") { viewModel.activateAutoPath() }
                        Button("command.return_home") { viewModel.activateReturnHome() }
                    }

                    HStack(spacing: 8) {
                        Button("command.emergency_stop") { viewModel.activateEmergencyStop() }
                            .foregroundStyle(.red)
                        Spacer()
                        Button(viewModel.isSimulationRunning ? String(localized: "command.stop_animation") : String(localized: "command.start_animation")) {
                            viewModel.toggleSimulation()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    SliderControlRow(
                        title: String(localized: "panel.throttle"),
                        value: binding(get: { viewModel.controlValues.throttle }, set: viewModel.setThrottle),
                        range: 0.0...1.0,
                        step: 0.01,
                        formatter: Self.throttleFormatter
                    )
                }
                .padding(.top, 6)
            } label: {
                Text("section.flight")
                    .font(.headline)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("panel.model", selection: Binding(
                get: { viewModel.selectedDroneProfile.id },
                set: { viewModel.selectDroneModel(id: $0) }
            )) {
                ForEach(viewModel.availableDroneProfiles, id: \.id) { profile in
                    Text(localized(profile.displayNameKey)).tag(profile.id)
                }
            }

            if viewModel.selectedDroneProfile.isAbstract {
                Button("abstract.edit") {
                    showAbstractEditor = true
                }
                .buttonStyle(.borderedProminent)
            }

            modelRow("panel.mass", String(format: "%.3f kg", viewModel.selectedDroneProfile.massKg))
            modelRow("panel.max_flight", String(format: "%.0f min", viewModel.selectedDroneProfile.maxFlightTimeMin))
            modelRow("panel.max_wind", String(format: "%.1f m/s", viewModel.selectedDroneProfile.maxWindResistanceMps))
            modelRow("panel.camera_layout", localized(viewModel.selectedDroneProfile.cameraLayoutKey))
            modelRow("panel.visual_class", localized(viewModel.selectedDroneProfile.visualClass.titleKey))
        }
    }

    private var cameraSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $sectionCameraExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("panel.camera_mode", selection: Binding(
                        get: { viewModel.cameraConfiguration.mode },
                        set: { viewModel.setCameraMode($0) }
                    )) {
                        ForEach(CameraMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                        }
                    }

                    Picker("camera.preset", selection: Binding(
                        get: { viewModel.selectedCameraPreset },
                        set: { viewModel.setCameraPreset($0) }
                    )) {
                        ForEach(CameraPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }

                    HStack {
                        Button("camera.reset_to_preset") {
                            viewModel.resetCameraToPreset()
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    if viewModel.supportsDistanceControl {
                        SliderControlRow(
                            title: String(localized: "camera.distance"),
                            value: binding(get: { viewModel.activeCameraDistance }, set: viewModel.setActiveCameraDistance),
                            range: viewModel.activeCameraDistanceRange,
                            step: 0.1,
                            formatter: Self.coordinateFormatter
                        )
                    }

                    SliderControlRow(title: String(localized: "camera.fov"), value: binding(get: { Double(viewModel.cameraConfiguration.fov) }, set: viewModel.setCameraFov), range: 30.0...110.0, step: 1.0, formatter: Self.angleFormatter)

                    DisclosureGroup(isExpanded: $advancedCameraExpanded) {
                        VStack(spacing: 10) {
                            Picker("camera.sensitivity_profile", selection: Binding(
                                get: { viewModel.cameraConfiguration.sensitivityProfile },
                                set: { viewModel.setCameraSensitivityProfile($0) }
                            )) {
                                ForEach(CameraSensitivityProfile.allCases) { profile in
                                    Text(LocalizedStringKey(profile.titleKey)).tag(profile)
                                }
                            }

                            SliderControlRow(title: String(localized: "camera.sensitivity"), value: binding(get: { Double(viewModel.cameraConfiguration.sensitivity) }, set: viewModel.setCameraSensitivity), range: 0.2...2.5, step: 0.05, formatter: Self.throttleFormatter)
                            SliderControlRow(title: String(localized: "camera.smoothing"), value: binding(get: { Double(viewModel.cameraConfiguration.smoothing) }, set: viewModel.setCameraSmoothing), range: 0.0...0.95, step: 0.01, formatter: Self.throttleFormatter)
                            SliderControlRow(title: String(localized: "camera.zoom_sensitivity"), value: binding(get: { Double(viewModel.cameraConfiguration.free.zoomSensitivity) }, set: viewModel.setCameraZoomSensitivity), range: 0.2...3.0, step: 0.05, formatter: Self.throttleFormatter)
                            SliderControlRow(title: String(localized: "camera.free_speed"), value: binding(get: { Double(viewModel.cameraConfiguration.free.moveSpeed) }, set: viewModel.setFreeCameraMoveSpeed), range: 0.5...16.0, step: 0.1, formatter: Self.coordinateFormatter)

                            Toggle("camera.invert_x", isOn: Binding(
                                get: { viewModel.cameraConfiguration.invertLookX },
                                set: { viewModel.setCameraInvertX($0) }
                            ))
                            Toggle("camera.invert_y", isOn: Binding(
                                get: { viewModel.cameraConfiguration.invertLookY },
                                set: { viewModel.setCameraInvertY($0) }
                            ))

                            SliderControlRow(title: String(localized: "camera.fpv_yaw_limit"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.yawLimitDeg) }, set: viewModel.setFPVYawLimit), range: 2.0...60.0, step: 1.0, formatter: Self.angleFormatter)
                            SliderControlRow(title: String(localized: "camera.fpv_pitch_limit"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.pitchLimitDeg) }, set: viewModel.setFPVPitchLimit), range: 2.0...45.0, step: 1.0, formatter: Self.angleFormatter)
                            SliderControlRow(title: String(localized: "camera.fpv_near_clip"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.nearClip) }, set: viewModel.setFPVNearClip), range: 0.005...0.25, step: 0.005, formatter: Self.throttleFormatter)
                            SliderControlRow(title: String(localized: "camera.fpv_stabilization"), value: binding(get: { Double(viewModel.cameraConfiguration.fpvStabilization) }, set: viewModel.setFPVStabilization), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)

                            SliderControlRow(title: String(localized: "camera.fpv_mount_x"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.x) }, set: viewModel.setFPVMountOffsetX), range: -0.08...0.08, step: 0.001, formatter: Self.throttleFormatter)
                            SliderControlRow(title: String(localized: "camera.fpv_mount_y"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.y) }, set: viewModel.setFPVMountOffsetY), range: -0.02...0.12, step: 0.001, formatter: Self.throttleFormatter)
                            SliderControlRow(title: String(localized: "camera.fpv_mount_z"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.z) }, set: viewModel.setFPVMountOffsetZ), range: -0.20...0.08, step: 0.001, formatter: Self.throttleFormatter)

                            Toggle("camera.fpv_hide_obstructing", isOn: Binding(
                                get: { viewModel.cameraConfiguration.fpv.hideObstructingParts },
                                set: { viewModel.setFPVHideObstructions($0) }
                            ))
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("camera.advanced")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("section.camera")
                    .font(.headline)
            }
        }
    }

    private var environmentSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $sectionEnvironmentExpanded) {
                VStack(spacing: 10) {
                    Picker("panel.weather", selection: Binding(
                        get: { viewModel.weather.preset },
                        set: { viewModel.setWeatherPreset($0) }
                    )) {
                        ForEach(WeatherPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }

                    SliderControlRow(title: String(localized: "weather.intensity"), value: binding(get: { Double(viewModel.weather.intensity) }, set: viewModel.setWeatherIntensity), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)
                    SliderControlRow(title: String(localized: "weather.wind_direction"), value: binding(get: { Double(viewModel.weather.windDirectionDeg) }, set: viewModel.setWindDirection), range: -180.0...180.0, step: 1.0, formatter: Self.angleFormatter)
                    SliderControlRow(title: String(localized: "weather.wind_speed"), value: binding(get: { Double(viewModel.weather.windSpeedMps) }, set: viewModel.setWindSpeed), range: 0.0...30.0, step: 0.1, formatter: Self.coordinateFormatter)
                    SliderControlRow(title: String(localized: "weather.gusts"), value: binding(get: { Double(viewModel.weather.gusts) }, set: viewModel.setWindGusts), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)

                    Divider()

                    Picker("panel.terrain", selection: Binding(
                        get: { viewModel.terrain.preset },
                        set: { viewModel.setTerrainPreset($0) }
                    )) {
                        ForEach(TerrainPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }

                    Picker("terrain.scale", selection: Binding(
                        get: { viewModel.terrain.mapScale },
                        set: { viewModel.setTerrainMapScale($0) }
                    )) {
                        ForEach(MapScale.allCases) { scale in
                            Text(LocalizedStringKey(scale.titleKey)).tag(scale)
                        }
                    }

                    SliderControlRow(
                        title: String(localized: "terrain.density"),
                        value: binding(get: { Double(viewModel.terrain.density) }, set: viewModel.setTerrainDensity),
                        range: 0.0...1.0,
                        step: 0.01,
                        formatter: Self.throttleFormatter,
                        onEditingChanged: viewModel.setTerrainDensityEditing,
                        onCommit: viewModel.commitTerrainDensityChange
                    )

                    Toggle("environment.boundary_barrier_visible", isOn: Binding(
                        get: { viewModel.isBoundaryBarrierVisible },
                        set: { viewModel.setBoundaryBarrierVisible($0) }
                    ))
                }
                .padding(.top, 6)
            } label: {
                Text("section.environment")
                    .font(.headline)
            }
        }
    }

    private var diagnosticsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $sectionDiagnosticsExpanded) {
                VStack(spacing: 8) {
                    Picker("diagnostic.mode", selection: Binding(
                        get: { viewModel.diagnosticMode },
                        set: { viewModel.setDiagnosticMode($0) }
                    )) {
                        ForEach(DiagnosticOverlayMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                        }
                    }

                    Toggle("diagnostic.collision_debug", isOn: $viewModel.collisionDebugEnabled)

                    HStack {
                        Text("diagnostic.last_collision_source")
                        Spacer()
                        Text(viewModel.lastCollisionSource)
                            .font(.caption.monospaced())
                    }

                    HStack {
                        Text("diagnostic.active_objects")
                        Spacer()
                        Text("\(viewModel.diagnostics.activeObjectCount)")
                    }
                    HStack {
                        Text("diagnostic.active_physics")
                        Spacer()
                        Text("\(viewModel.diagnostics.activePhysicsBodyCount)")
                    }
                    HStack {
                        Text("diagnostic.active_particles")
                        Spacer()
                        Text("\(viewModel.diagnostics.activeParticleCount)")
                    }
                }
                .font(.caption)
                .padding(.top, 6)
            } label: {
                Text("section.diagnostics")
                    .font(.headline)
            }
        }
    }

    private var advancedSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $sectionAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    fleetSection
                    damageSection
                    warningsSection
                }
                .padding(.top, 6)
            } label: {
                Text("section.advanced")
                    .font(.headline)
            }
        }
    }

    private var fleetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("panel.fleet")
                .font(.subheadline.weight(.semibold))

            Toggle("diagnostic.fleet_mode", isOn: Binding(
                get: { viewModel.fleetStatus.enabled },
                set: { _ in viewModel.toggleFleetEnabled() }
            ))

            Picker("fleet.formation", selection: Binding(
                get: { viewModel.fleetStatus.mode },
                set: { viewModel.setFormationMode($0) }
            )) {
                ForEach(FormationMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                }
            }

            SliderControlRow(title: String(localized: "fleet.separation"), value: binding(get: { Double(viewModel.fleetStatus.separationDistance) }, set: viewModel.setSeparationDistance), range: 1.0...20.0, step: 0.1, formatter: Self.coordinateFormatter)
        }
    }

    private var damageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("panel.damage")
                .font(.subheadline.weight(.semibold))

            HStack {
                Button("damage.reset") {
                    viewModel.resetDamageState()
                }
                Spacer()
                Button("damage.clear_selection") {
                    viewModel.selectComponent(nil)
                }
            }

            ForEach(DamageComponent.allCases.prefix(6)) { component in
                HStack(spacing: 8) {
                    Button {
                        viewModel.selectComponent(component)
                    } label: {
                        Text(LocalizedStringKey(component.titleKey))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text("\(Int(viewModel.damageState.health(for: component) * 100))%")
                        .font(.caption.monospacedDigit())

                    Toggle("damage.hide", isOn: Binding(
                        get: { viewModel.damageState.hiddenComponents.contains(component) },
                        set: { viewModel.setComponentHidden(component, hidden: $0) }
                    ))
                    .labelsHidden()
                }
            }
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("panel.warnings")
                .font(.subheadline.weight(.semibold))

            if viewModel.warnings.isEmpty {
                Text("warnings.none")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.warnings, id: \.self) { warning in
                    Text("• \(localized(warning))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var telemetrySection: some View {
        GroupBox(LocalizedStringKey("panel.telemetry")) {
            VStack(spacing: 8) {
                TelemetryPanelView(telemetry: viewModel.telemetry)

                Button("telemetry.export") {
                    viewModel.exportTelemetry()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 4)
        }
    }

    private func modelRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key))
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private func binding(get: @escaping () -> Double, set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private struct SliderControlRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let formatter: NumberFormatter
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onCommit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(title, value: value, formatter: formatter)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit {
                        onCommit?()
                    }
            }

            Slider(value: value, in: range, step: step, onEditingChanged: { editing in
                onEditingChanged?(editing)
                if !editing {
                    onCommit?()
                }
            })
        }
    }
}
