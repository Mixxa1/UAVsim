import SwiftUI

struct FlightOpsModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private static let throttleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private let actionColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleSection(
                titleKey: "module.flight_ops.command_stack",
                subtitleKey: "module.flight_ops.command_stack.subtitle"
            ) {
                LazyVGrid(columns: actionColumns, spacing: 8) {
                    OperationalActionButton(
                        titleKey: viewModel.isArmed ? "command.disarm" : "command.arm",
                        systemImage: viewModel.isArmed ? "lock.open.fill" : "lock.fill",
                        tint: viewModel.isArmed ? GroundControlPalette.warning : GroundControlPalette.success,
                        prominent: true
                    ) {
                        if viewModel.isArmed {
                            viewModel.disarm()
                        } else {
                            viewModel.arm()
                        }
                    }

                    OperationalActionButton(
                        titleKey: "command.takeoff",
                        systemImage: "arrow.up.circle.fill",
                        prominent: true
                    ) {
                        viewModel.takeoff()
                    }

                    OperationalActionButton(
                        titleKey: "command.land",
                        systemImage: "arrow.down.circle.fill"
                    ) {
                        viewModel.land()
                    }

                    if !viewModel.isFixedWingAssistEnabled {
                        OperationalActionButton(
                            titleKey: "command.hover",
                            systemImage: "pause.circle.fill"
                        ) {
                            viewModel.hover()
                        }

                        OperationalActionButton(
                            titleKey: "command.auto_path",
                            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                        ) {
                            viewModel.activateAutoPath()
                        }

                        OperationalActionButton(
                            titleKey: "command.return_home",
                            systemImage: "house.fill"
                        ) {
                            viewModel.activateReturnHome()
                        }
                    }
                }
            }

            if viewModel.isFixedWingAssistEnabled {
                ModuleSection(
                    titleKey: "module.flight_ops.fixed_wing_assist",
                    subtitleKey: "module.flight_ops.fixed_wing_assist.subtitle"
                ) {
                    LazyVGrid(columns: actionColumns, spacing: 8) {
                        ForEach(FixedWingAssistMode.allCases) { assistMode in
                            ModuleModeTile(
                                titleKey: assistMode.titleKey,
                                subtitle: fixedWingAssistSubtitle(for: assistMode),
                                iconSystemName: fixedWingAssistIcon(for: assistMode),
                                isActive: viewModel.mode == .manual && viewModel.fixedWingAssistState.mode == assistMode
                            ) {
                                viewModel.activateFixedWingAssist(assistMode)
                            }
                            .disabled(isFixedWingAssistDisabled(assistMode))
                        }
                    }
                }
            }

            ModuleSection(
                titleKey: "module.flight_ops.control_law",
                subtitleKey: "module.flight_ops.control_law.subtitle"
            ) {
                LazyVGrid(columns: actionColumns, spacing: 8) {
                    ForEach(FlightControlMode.allCases) { mode in
                        ModuleModeTile(
                            titleKey: mode.titleKey,
                            subtitle: mode == viewModel.flightControlMode ? localized("module.flight_ops.active_mode") : nil,
                            iconSystemName: icon(for: mode),
                            isActive: viewModel.flightControlMode == mode
                        ) {
                            viewModel.setFlightControlMode(mode)
                        }
                    }
                }
            }

            ModuleSection(
                titleKey: "module.flight_ops.thrust",
                subtitleKey: "module.flight_ops.thrust.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ModuleSliderRow(
                        titleKey: "panel.throttle",
                        value: Binding(
                            get: { viewModel.controlValues.throttle },
                            set: { viewModel.setThrottle($0) }
                        ),
                        range: 0.0...1.0,
                        step: 0.01,
                        formatter: Self.throttleFormatter
                    )

                    HStack(spacing: 6) {
                        throttlePresetButton(value: 0.0, label: "0%")
                        throttlePresetButton(value: 0.25, label: "25%")
                        throttlePresetButton(value: 0.50, label: "50%")
                        throttlePresetButton(value: 0.75, label: "75%")
                        throttlePresetButton(value: 1.0, label: "100%")
                    }
                }
            }

            ModuleSection(
                titleKey: "module.flight_ops.override",
                subtitleKey: "module.flight_ops.override.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        OperationalActionButton(
                            titleKey: viewModel.isSimulationRunning ? "command.stop_animation" : "command.start_animation",
                            systemImage: viewModel.isSimulationRunning ? "stop.fill" : "play.fill",
                            prominent: true
                        ) {
                            viewModel.toggleSimulation()
                        }

                        OperationalActionButton(
                            titleKey: "command.reset",
                            systemImage: "arrow.counterclockwise",
                            tint: GroundControlPalette.warning
                        ) {
                            viewModel.reset()
                        }
                    }

                    OperationalActionButton(
                        titleKey: "command.emergency_stop",
                        systemImage: "xmark.octagon.fill",
                        tint: GroundControlPalette.danger,
                        prominent: true
                    ) {
                        viewModel.activateEmergencyStop()
                    }
                }
            }
        }
    }

    private func throttlePresetButton(value: Double, label: String) -> some View {
        Button(label) {
            viewModel.setThrottle(value)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(GroundControlPalette.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(abs(viewModel.controlValues.throttle - value) < 0.01 ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(abs(viewModel.controlValues.throttle - value) < 0.01 ? GroundControlPalette.accent.opacity(0.6) : GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func icon(for mode: FlightControlMode) -> String {
        switch mode {
        case .stabilized:
            return "gyroscope"
        case .acro:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .hoverAssist:
            return "dot.radiowaves.up.forward"
        }
    }

    private func fixedWingAssistIcon(for mode: FixedWingAssistMode) -> String {
        switch mode {
        case .manual:
            return "hand.raised.fill"
        case .headingHold:
            return "location.north.line.fill"
        case .altitudeHold:
            return "arrow.up.and.down.circle.fill"
        case .waypointIntercept:
            return "dot.scope"
        }
    }

    private func fixedWingAssistSubtitle(for mode: FixedWingAssistMode) -> String? {
        switch mode {
        case .manual:
            return nil
        case .headingHold:
            return viewModel.fixedWingAssistState.mode == .headingHold ? localized("module.flight_ops.active_mode") : nil
        case .altitudeHold:
            return viewModel.fixedWingAssistState.mode == .altitudeHold ? localized("module.flight_ops.active_mode") : nil
        case .waypointIntercept:
            if let label = viewModel.selectedFixedWingAssistWaypointLabel {
                return label
            }
            return localized("fixed_wing.assist.waypoint.none")
        }
    }

    private func isFixedWingAssistDisabled(_ mode: FixedWingAssistMode) -> Bool {
        switch mode {
        case .manual:
            return false
        case .waypointIntercept:
            return !viewModel.canActivateFixedWingWaypointIntercept
        case .headingHold, .altitudeHold:
            return !viewModel.isArmed || viewModel.mode == .emergencyStop
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
