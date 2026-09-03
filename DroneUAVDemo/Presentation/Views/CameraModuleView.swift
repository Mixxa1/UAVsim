import SwiftUI

struct CameraModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    @State private var showAdvancedControls = false
    @State private var showOSDEditor = false

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

    private static let scalarFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private let tileColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleSection(
                titleKey: "module.camera.mode_stack",
                subtitleKey: "module.camera.mode_stack.subtitle"
            ) {
                LazyVGrid(columns: tileColumns, spacing: 8) {
                    ForEach(viewModel.availableCameraModes) { mode in
                        ModuleModeTile(
                            titleKey: mode.titleKey,
                            subtitle: nil,
                            iconSystemName: icon(for: mode),
                            isActive: viewModel.cameraConfiguration.mode == mode
                        ) {
                            viewModel.setCameraMode(mode)
                        }
                    }
                }

                Toggle("camera.payload.auto_switch", isOn: Binding(
                    get: { viewModel.isPayloadCameraAutoSwitchEnabled },
                    set: { viewModel.setPayloadCameraAutoSwitchEnabled($0) }
                ))
                .toggleStyle(.switch)
                .foregroundStyle(GroundControlPalette.textPrimary)
            }

            if viewModel.payloadCameraOpticsState.isAvailable || viewModel.cameraConfiguration.mode == .payloadOptics {
                payloadOpticsSection
            }

            if viewModel.rangefinderOpticsState.isAvailable {
                rangefinderSection
            }

            if viewModel.hoseOpticsState.isAvailable {
                hoseAimSection
            }

            ModuleSection(
                titleKey: "module.camera.presets",
                subtitleKey: "module.camera.presets.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: tileColumns, spacing: 8) {
                        ForEach(CameraPreset.allCases) { preset in
                            Button {
                                viewModel.setCameraPreset(preset)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(LocalizedStringKey(preset.titleKey))
                                        .font(.subheadline.weight(.semibold))
                                    Text(LocalizedStringKey(presetHintKey(for: preset)))
                                        .font(.caption2)
                                        .foregroundStyle(GroundControlPalette.textSecondary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .foregroundStyle(GroundControlPalette.textPrimary)
                                .padding(10)
                                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(viewModel.selectedCameraPreset == preset ? GroundControlPalette.accent.opacity(0.20) : GroundControlPalette.inset)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(viewModel.selectedCameraPreset == preset ? GroundControlPalette.accent.opacity(0.62) : GroundControlPalette.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .controllerButtonTarget(id: "camera.preset.\(preset.id)") {
                                viewModel.setCameraPreset(preset)
                            }
                        }
                    }

                    LazyVGrid(columns: tileColumns, spacing: 8) {
                        OperationalActionButton(
                            titleKey: "camera.reset_to_preset",
                            systemImage: "scope",
                            prominent: true
                        ) {
                            viewModel.resetCameraToPreset()
                        }

                        if viewModel.supportsDistanceControl {
                            OperationalActionButton(
                                titleKey: "camera.zoom_in",
                                systemImage: "plus.magnifyingglass"
                            ) {
                                viewModel.setActiveCameraDistance(
                                    max(viewModel.activeCameraDistanceRange.lowerBound, viewModel.activeCameraDistance - 0.9)
                                )
                            }

                            OperationalActionButton(
                                titleKey: "camera.zoom_out",
                                systemImage: "minus.magnifyingglass"
                            ) {
                                viewModel.setActiveCameraDistance(
                                    min(viewModel.activeCameraDistanceRange.upperBound, viewModel.activeCameraDistance + 0.9)
                                )
                            }
                        }
                    }
                }
            }

            ModuleSection(
                titleKey: "module.camera.optics",
                subtitleKey: "module.camera.optics.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.supportsDistanceControl {
                        ModuleSliderRow(
                            titleKey: "camera.distance",
                            value: Binding(
                                get: { viewModel.activeCameraDistance },
                                set: { viewModel.setActiveCameraDistance($0) }
                            ),
                            range: viewModel.activeCameraDistanceRange,
                            step: 0.1,
                            formatter: Self.coordinateFormatter
                        )
                    }

                    ModuleSliderRow(
                        titleKey: "camera.fov",
                        value: Binding(
                            get: { Double(viewModel.cameraConfiguration.fov) },
                            set: { viewModel.setCameraFov($0) }
                        ),
                        range: 30.0...110.0,
                        step: 1.0,
                        formatter: Self.angleFormatter
                    )
                }
            }

            ModuleSection(
                titleKey: "camera.advanced",
                subtitleKey: "module.camera.advanced.subtitle"
            ) {
                DisclosureGroup(
                    isExpanded: $showAdvancedControls,
                    content: {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("camera.sensitivity_profile", selection: Binding(
                                get: { viewModel.cameraConfiguration.sensitivityProfile },
                                set: { viewModel.setCameraSensitivityProfile($0) }
                            )) {
                                ForEach(CameraSensitivityProfile.allCases) { profile in
                                    Text(LocalizedStringKey(profile.titleKey)).tag(profile)
                                }
                            }
                            .pickerStyle(.segmented)

                            ModuleSliderRow(
                                titleKey: "camera.sensitivity",
                                value: Binding(
                                    get: { Double(viewModel.cameraConfiguration.sensitivity) },
                                    set: { viewModel.setCameraSensitivity($0) }
                                ),
                                range: 0.2...2.5,
                                step: 0.05,
                                formatter: Self.scalarFormatter
                            )
                            ModuleSliderRow(
                                titleKey: "camera.smoothing",
                                value: Binding(
                                    get: { Double(viewModel.cameraConfiguration.smoothing) },
                                    set: { viewModel.setCameraSmoothing($0) }
                                ),
                                range: 0.0...0.95,
                                step: 0.01,
                                formatter: Self.scalarFormatter
                            )
                            ModuleSliderRow(
                                titleKey: "camera.zoom_sensitivity",
                                value: Binding(
                                    get: { Double(viewModel.cameraConfiguration.free.zoomSensitivity) },
                                    set: { viewModel.setCameraZoomSensitivity($0) }
                                ),
                                range: 0.2...3.0,
                                step: 0.05,
                                formatter: Self.scalarFormatter
                            )
                            ModuleSliderRow(
                                titleKey: "camera.free_speed",
                                value: Binding(
                                    get: { Double(viewModel.cameraConfiguration.free.moveSpeed) },
                                    set: { viewModel.setFreeCameraMoveSpeed($0) }
                                ),
                                range: 0.5...16.0,
                                step: 0.1,
                                formatter: Self.coordinateFormatter
                            )

                            Toggle("camera.invert_x", isOn: Binding(
                                get: { viewModel.cameraConfiguration.invertLookX },
                                set: { viewModel.setCameraInvertX($0) }
                            ))
                            .toggleStyle(.switch)
                            .foregroundStyle(GroundControlPalette.textPrimary)

                            Toggle("camera.invert_y", isOn: Binding(
                                get: { viewModel.cameraConfiguration.invertLookY },
                                set: { viewModel.setCameraInvertY($0) }
                            ))
                            .toggleStyle(.switch)
                            .foregroundStyle(GroundControlPalette.textPrimary)

                            if viewModel.cameraConfiguration.mode == .fpv || viewModel.selectedCameraPreset == .fpv {
                                fpvAdvancedBlock
                            }
                        }
                        .padding(.top, 10)
                    },
                    label: {
                        Text(showAdvancedControls ? "module.camera.hide_advanced" : "module.camera.show_advanced")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                    }
                )
                .tint(GroundControlPalette.accent)
            }
        }
    }

    @ViewBuilder
    private var payloadOpticsSection: some View {
        let state = viewModel.payloadCameraOpticsState
        let controlsEnabled = state.isAvailable && state.isPowered

        ModuleSection(
            titleKey: "payload.camera.title",
            subtitleKey: "camera.mode.payload_optics"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                // Only the channels the fitted camera actually carries. Offering all three made
                // the panel claim a thermal core on a mapping camera and a visible channel on a
                // bare LWIR one.
                HStack(spacing: 8) {
                    ForEach(viewModel.availablePayloadCameraModes) { mode in
                        payloadModeChip(mode: mode, isSelected: state.mode == mode)
                    }
                }

                if state.mode == .thermalStub {
                    thermalControls(enabled: controlsEnabled)
                }

                LazyVGrid(columns: tileColumns, spacing: 8) {
                    ForEach(PayloadCameraStabilizationMode.allCases) { mode in
                        stabilizationModeChip(mode: mode, isSelected: state.stabilizationMode == mode) {
                            viewModel.setPayloadStabilizationMode(mode)
                        }
                    }
                }

                ModuleSliderRow(
                    titleKey: "payload.camera.zoom",
                    value: Binding(
                        get: { state.zoomLevel },
                        set: { viewModel.setPayloadZoom($0) }
                    ),
                    range: state.minZoom...state.maxZoom,
                    step: 0.1,
                    formatter: Self.coordinateFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                ModuleSliderRow(
                    titleKey: "payload.camera.focus",
                    value: Binding(
                        get: { state.focusDistanceMeters },
                        set: { viewModel.setPayloadFocusDistance($0) }
                    ),
                    range: 1.0...500.0,
                    step: 0.5,
                    formatter: Self.coordinateFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                LazyVGrid(columns: tileColumns, spacing: 8) {
                    payloadMetricCard(
                        titleKey: "payload.camera.target_distance",
                        value: state.targetDistanceMeters.map { String(format: "%.1f m", $0) } ?? "-- m"
                    )
                    payloadMetricCard(
                        titleKey: "payload.camera.focus_error",
                        value: String(format: "%.1f m", state.focusErrorMeters)
                    )
                    payloadMetricCard(
                        titleKey: "payload.camera.fov",
                        value: String(format: "%.1f°", state.currentFieldOfViewDegrees)
                    )
                    payloadMetricCard(
                        titleKey: "payload.camera.stabilization_strength",
                        value: String(format: "%.0f%%", state.stabilizationStrength * 100.0)
                    )
                    payloadMetricCard(
                        titleKey: "payload.camera.vibration",
                        value: vibrationLabel(for: state)
                    )
                }

                LazyVGrid(columns: tileColumns, spacing: 8) {
                    payloadActionButton(
                        titleKey: state.isRecording ? "payload.camera.stop_record" : "payload.camera.record",
                        systemImage: state.isRecording ? "stop.circle" : "record.circle",
                        tint: Color.red,
                        prominent: state.isRecording,
                        isDisabled: !controlsEnabled
                    ) {
                        viewModel.togglePayloadRecording()
                    }

                    payloadActionButton(
                        titleKey: "payload.camera.autofocus",
                        systemImage: "viewfinder.circle",
                        tint: GroundControlPalette.accent,
                        prominent: state.autofocusEnabled,
                        isDisabled: !controlsEnabled
                    ) {
                        viewModel.togglePayloadAutofocus()
                    }

                    payloadActionButton(
                        titleKey: "payload.camera.focus_target",
                        systemImage: "scope",
                        tint: Color.orange,
                        prominent: state.targetDistanceMeters != nil,
                        isDisabled: !controlsEnabled || state.targetDistanceMeters == nil
                    ) {
                        viewModel.triggerPayloadAutofocusOnce()
                    }

                    payloadActionButton(
                        titleKey: "payload.camera.reset_zoom",
                        systemImage: "minus.magnifyingglass",
                        tint: GroundControlPalette.textSecondary,
                        prominent: false,
                        isDisabled: !controlsEnabled || state.zoomLevel <= state.minZoom + 0.01
                    ) {
                        viewModel.resetPayloadZoom()
                    }
                }

                if !state.isPowered {
                    payloadStatusBanner("payload.camera.powered_off", tint: GroundControlPalette.warning)
                } else if !state.isAvailable {
                    payloadStatusBanner("payload.camera.unavailable", tint: GroundControlPalette.warning)
                }
            }
        }
    }

    @ViewBuilder
    private var rangefinderSection: some View {
        let state = viewModel.rangefinderOpticsState
        let controlsEnabled = state.isAvailable && state.isPowered

        ModuleSection(
            titleKey: "payload.rangefinder.title",
            subtitleKey: "payload.rangefinder.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                payloadActionButton(
                    titleKey: state.isArmed ? "payload.rangefinder.disarm" : "payload.rangefinder.arm",
                    systemImage: state.isArmed ? "scope" : "dot.scope",
                    tint: Color.red,
                    prominent: state.isArmed,
                    isDisabled: !controlsEnabled
                ) {
                    viewModel.setRangefinderArmed(!state.isArmed)
                }

                ModuleSliderRow(
                    titleKey: "payload.rangefinder.zoom",
                    value: Binding(
                        get: { state.zoomLevel },
                        set: { viewModel.setRangefinderZoom($0) }
                    ),
                    range: state.minZoom...state.maxZoom,
                    step: 0.1,
                    formatter: Self.coordinateFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                ModuleSliderRow(
                    titleKey: "payload.rangefinder.gimbal_yaw",
                    value: Binding(
                        get: { state.gimbalYawDegrees },
                        set: { newValue in
                            viewModel.adjustRangefinderGimbal(
                                yawDeltaDegrees: newValue - state.gimbalYawDegrees,
                                pitchDeltaDegrees: 0.0
                            )
                        }
                    ),
                    range: -180.0...180.0,
                    step: 1.0,
                    formatter: Self.angleFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                ModuleSliderRow(
                    titleKey: "payload.rangefinder.gimbal_pitch",
                    value: Binding(
                        get: { state.gimbalPitchDegrees },
                        set: { newValue in
                            viewModel.adjustRangefinderGimbal(
                                yawDeltaDegrees: 0.0,
                                pitchDeltaDegrees: newValue - state.gimbalPitchDegrees
                            )
                        }
                    ),
                    range: -90.0...35.0,
                    step: 1.0,
                    formatter: Self.angleFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                LazyVGrid(columns: tileColumns, spacing: 8) {
                    payloadMetricCard(
                        titleKey: "payload.rangefinder.distance",
                        value: state.measuredDistanceMeters.map { String(format: "%.1f m", $0) } ?? "-- m"
                    )
                    payloadActionButton(
                        titleKey: "payload.rangefinder.reset_aim",
                        systemImage: "arrow.counterclockwise",
                        tint: GroundControlPalette.textSecondary,
                        prominent: false,
                        isDisabled: !controlsEnabled
                    ) {
                        viewModel.resetRangefinderGimbalOrientation()
                    }
                }

                if !state.isPowered {
                    payloadStatusBanner("payload.rangefinder.powered_off", tint: GroundControlPalette.warning)
                } else if !state.isAvailable {
                    payloadStatusBanner("payload.rangefinder.unavailable", tint: GroundControlPalette.warning)
                }
            }
        }
    }

    private var hoseAimSection: some View {
        let state = viewModel.hoseOpticsState
        let controlsEnabled = state.isAvailable && state.isPowered

        return ModuleSection(
            titleKey: "payload.hose.title",
            subtitleKey: "payload.hose.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                payloadActionButton(
                    titleKey: state.isSpraying ? "payload.hose.stop_spray" : "payload.hose.spray",
                    systemImage: state.isSpraying ? "drop.circle.fill" : "drop.fill",
                    tint: Color(red: 0.86, green: 0.22, blue: 0.10),
                    prominent: state.isSpraying,
                    isDisabled: !controlsEnabled
                ) {
                    viewModel.setHoseSpraying(!state.isSpraying)
                }

                ModuleSliderRow(
                    titleKey: "payload.hose.gimbal_yaw",
                    value: Binding(
                        get: { state.gimbalYawDegrees },
                        set: { newValue in
                            viewModel.adjustHoseGimbal(
                                yawDeltaDegrees: newValue - state.gimbalYawDegrees,
                                pitchDeltaDegrees: 0.0
                            )
                        }
                    ),
                    range: -180.0...180.0,
                    step: 1.0,
                    formatter: Self.angleFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                ModuleSliderRow(
                    titleKey: "payload.hose.gimbal_pitch",
                    value: Binding(
                        get: { state.gimbalPitchDegrees },
                        set: { newValue in
                            viewModel.adjustHoseGimbal(
                                yawDeltaDegrees: 0.0,
                                pitchDeltaDegrees: newValue - state.gimbalPitchDegrees
                            )
                        }
                    ),
                    range: -90.0...35.0,
                    step: 1.0,
                    formatter: Self.angleFormatter
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1.0 : 0.5)

                LazyVGrid(columns: tileColumns, spacing: 8) {
                    payloadMetricCard(
                        titleKey: "payload.hose.fires_remaining",
                        value: "\(viewModel.fireResponseBurningCount)/\(viewModel.fireResponseTotalCount)"
                    )
                    payloadActionButton(
                        titleKey: "payload.hose.reset_aim",
                        systemImage: "arrow.counterclockwise",
                        tint: GroundControlPalette.textSecondary,
                        prominent: false,
                        isDisabled: !controlsEnabled
                    ) {
                        viewModel.resetHoseGimbalOrientation()
                    }
                }

                if !state.isPowered {
                    payloadStatusBanner("payload.hose.powered_off", tint: GroundControlPalette.warning)
                } else if !state.isAvailable {
                    payloadStatusBanner("payload.hose.unavailable", tint: GroundControlPalette.warning)
                }
            }
        }
    }

    @ViewBuilder
    private var fpvAdvancedBlock: some View {
        ModuleSection(titleKey: "module.camera.fpv_stack") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("camera.fpv.osd_font", selection: Binding(
                        get: { viewModel.fpvFontPreset },
                        set: { viewModel.setFPVFontPreset($0) }
                    )) {
                        ForEach(FPVFontPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("camera.fpv.osd_font.hint")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)

                    Button {
                        showOSDEditor = true
                    } label: {
                        Label("camera.fpv.osd_editor", systemImage: "square.grid.3x3.topleft.filled")
                            .font(.caption)
                    }
                    .padding(.top, 2)
                }

                ModuleSliderRow(
                    titleKey: "camera.fpv_yaw_limit",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.yawLimitDeg) },
                        set: { viewModel.setFPVYawLimit($0) }
                    ),
                    range: 2.0...60.0,
                    step: 1.0,
                    formatter: Self.angleFormatter
                )
                ModuleSliderRow(
                    titleKey: "camera.fpv_pitch_limit",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.pitchLimitDeg) },
                        set: { viewModel.setFPVPitchLimit($0) }
                    ),
                    range: 2.0...45.0,
                    step: 1.0,
                    formatter: Self.angleFormatter
                )
                ModuleSliderRow(
                    titleKey: "camera.fpv_near_clip",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.nearClip) },
                        set: { viewModel.setFPVNearClip($0) }
                    ),
                    range: 0.005...0.25,
                    step: 0.005,
                    formatter: Self.scalarFormatter
                )
                Toggle("camera.fpv_lens", isOn: Binding(
                    get: { viewModel.cameraConfiguration.fpv.lensEnabled },
                    set: { viewModel.setFPVLensEnabled($0) }
                ))
                .toggleStyle(.switch)
                .foregroundStyle(GroundControlPalette.textPrimary)

                Text("camera.fpv_lens.hint")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ModuleSliderRow(
                    titleKey: "camera.fpv_lens_distortion",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.lensDistortion) },
                        set: { viewModel.setFPVLensDistortion($0) }
                    ),
                    range: 0.0...1.0,
                    step: 0.05,
                    formatter: Self.scalarFormatter
                )
                .disabled(!viewModel.cameraConfiguration.fpv.lensEnabled)

                ModuleSliderRow(
                    titleKey: "camera.fpv_mount_x",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.x) },
                        set: { viewModel.setFPVMountOffsetX($0) }
                    ),
                    range: -0.08...0.08,
                    step: 0.001,
                    formatter: Self.scalarFormatter
                )
                ModuleSliderRow(
                    titleKey: "camera.fpv_mount_y",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.y) },
                        set: { viewModel.setFPVMountOffsetY($0) }
                    ),
                    range: -0.02...0.12,
                    step: 0.001,
                    formatter: Self.scalarFormatter
                )
                ModuleSliderRow(
                    titleKey: "camera.fpv_mount_z",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.z) },
                        set: { viewModel.setFPVMountOffsetZ($0) }
                    ),
                    range: -0.20...0.08,
                    step: 0.001,
                    formatter: Self.scalarFormatter
                )

                Toggle("camera.fpv_hide_obstructing", isOn: Binding(
                    get: { viewModel.cameraConfiguration.fpv.hideObstructingParts },
                    set: { viewModel.setFPVHideObstructions($0) }
                ))
                .toggleStyle(.switch)
                .foregroundStyle(GroundControlPalette.textPrimary)
            }
        }
        .sheet(isPresented: $showOSDEditor) {
            FPVOSDEditorView(viewModel: viewModel)
        }
    }

    private func icon(for mode: CameraMode) -> String {
        switch mode {
        case .free:
            return "cursorarrow.motionlines"
        case .follow:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .orbit:
            return "rotate.3d"
        case .fpv:
            return "record.circle"
        case .top:
            return "view.2d"
        case .payloadOptics:
            return "camera.viewfinder"
        case .payload:
            return "shippingbox"
        case .spectator:
            return "eye"
        }
    }

    private func presetHintKey(for preset: CameraPreset) -> String {
        switch preset {
        case .cinematic:
            return "module.camera.preset_hint.cinematic"
        case .pilot:
            return "module.camera.preset_hint.pilot"
        case .inspection:
            return "module.camera.preset_hint.inspection"
        case .wideFollow:
            return "module.camera.preset_hint.wide_follow"
        case .tightFollow:
            return "module.camera.preset_hint.tight_follow"
        case .fpv:
            return "module.camera.preset_hint.fpv"
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    @ViewBuilder
    private func thermalControls(enabled: Bool) -> some View {
        let thermal = viewModel.payloadThermalState

        VStack(alignment: .leading, spacing: 10) {
            Text("payload.camera.thermal.palette")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 8) {
                ForEach(ThermalPalette.allCases) { palette in
                    thermalPaletteChip(palette: palette, isSelected: thermal.palette == palette)
                }
            }

            HStack {
                Text("payload.camera.thermal.profile")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                thermalProfileMenu(selection: thermal.profileSelection)
            }

            ModuleSliderRow(
                titleKey: "payload.camera.thermal.contrast",
                value: Binding(
                    get: { thermal.contrast },
                    set: { viewModel.setThermalContrast($0) }
                ),
                range: 0.4...1.8,
                step: 0.05,
                formatter: Self.scalarFormatter
            )

            ModuleSliderRow(
                titleKey: "payload.camera.thermal.brightness",
                value: Binding(
                    get: { thermal.brightness },
                    set: { viewModel.setThermalBrightness($0) }
                ),
                range: -0.3...0.3,
                step: 0.02,
                formatter: Self.scalarFormatter
            )

            ModuleSliderRow(
                titleKey: "payload.camera.thermal.noise",
                value: Binding(
                    get: { thermal.noiseAmount },
                    set: { viewModel.setThermalNoiseAmount($0) }
                ),
                range: 0.0...1.0,
                step: 0.05,
                formatter: Self.scalarFormatter
            )

            Toggle(isOn: Binding(
                get: { thermal.showDiagnostics },
                set: { viewModel.setThermalDiagnosticsVisible($0) }
            )) {
                Text("payload.camera.thermal.diagnostics")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }
            .tint(GroundControlPalette.accent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
        .opacity(enabled ? 1.0 : 0.5)
        .disabled(!enabled)
    }

    private func thermalPaletteChip(palette: ThermalPalette, isSelected: Bool) -> some View {
        Button {
            viewModel.setThermalPalette(palette)
        } label: {
            Text(LocalizedStringKey(palette.titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? GroundControlPalette.accent.opacity(0.20) : GroundControlPalette.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isSelected ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func thermalProfileMenu(selection: ThermalProfileSelection) -> some View {
        Menu {
            ForEach(ThermalProfileSelection.allCases) { option in
                Button {
                    viewModel.setThermalProfileSelection(option)
                } label: {
                    if option == selection {
                        Label(localized(option.titleKey), systemImage: "checkmark")
                    } else {
                        Text(localized(option.titleKey))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(localized(selection.titleKey))
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(GroundControlPalette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func payloadModeChip(mode: PayloadCameraMode, isSelected: Bool) -> some View {
        // Night is still unimplemented (dimmed, non-interactive) if it ever reaches this list.
        let isEnabled = mode == .optical || mode == .thermalStub

        return Button {
            viewModel.setPayloadCameraMode(mode)
        } label: {
            Text(payloadModeTitle(for: mode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? GroundControlPalette.accent.opacity(0.20) : GroundControlPalette.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.42)
    }

    private func payloadMetricCard(titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func stabilizationModeChip(
        mode: PayloadCameraStabilizationMode,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(stabilizationModeTitle(for: mode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? GroundControlPalette.accent.opacity(0.20) : GroundControlPalette.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func payloadActionButton(
        titleKey: String,
        systemImage: String,
        tint: Color,
        prominent: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        OperationalActionButton(
            titleKey: titleKey,
            systemImage: systemImage,
            tint: tint,
            prominent: prominent,
            action: action
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
    }

    private func payloadStatusBanner(_ titleKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.caption.weight(.semibold))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.42), lineWidth: 1)
            )
    }

    private func payloadModeTitle(for mode: PayloadCameraMode) -> String {
        switch mode {
        case .optical:
            return localized("payload.camera.mode.eo")
        case .thermalStub:
            return localized("payload.camera.mode.thermal_stub")
        case .nightStub:
            return localized("payload.camera.mode.night_stub")
        }
    }

    private func stabilizationModeTitle(for mode: PayloadCameraStabilizationMode) -> String {
        switch mode {
        case .off:
            return localized("payload.camera.stabilization.off")
        case .horizonLock:
            return localized("payload.camera.stabilization.horizon")
        case .targetLock:
            return localized("payload.camera.stabilization.target")
        case .lowSpeedStabilized:
            return localized("payload.camera.stabilization.low_speed")
        }
    }

    private func vibrationLabel(for state: PayloadCameraOpticsState) -> String {
        let visibleVibration = max(0.0, 1.0 - state.vibrationSuppression * state.stabilizationStrength)
        switch visibleVibration {
        case ..<0.22:
            return localized("payload.camera.vibration.low")
        case ..<0.52:
            return localized("payload.camera.vibration.medium")
        default:
            return localized("payload.camera.vibration.high")
        }
    }
}
