import SwiftUI

struct CameraModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    @State private var showAdvancedControls = false

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
    private var fpvAdvancedBlock: some View {
        ModuleSection(titleKey: "module.camera.fpv_stack") {
            VStack(alignment: .leading, spacing: 12) {
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
                ModuleSliderRow(
                    titleKey: "camera.fpv_stabilization",
                    value: Binding(
                        get: { Double(viewModel.cameraConfiguration.fpvStabilization) },
                        set: { viewModel.setFPVStabilization($0) }
                    ),
                    range: 0.0...1.0,
                    step: 0.01,
                    formatter: Self.scalarFormatter
                )
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
        case .payload:
            return "shippingbox"
        case .spectatorFree:
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
}
