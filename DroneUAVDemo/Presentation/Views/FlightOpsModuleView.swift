import SwiftUI

struct FlightOpsModuleView: View {
    @SimulationObservedObject var viewModel: DroneSimulationViewModel

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
                    .instructorTarget("simulation.command.arm")

                    OperationalActionButton(
                        titleKey: "command.takeoff",
                        systemImage: "arrow.up.circle.fill",
                        prominent: true
                    ) {
                        viewModel.takeoff()
                    }
                    .disabled(!viewModel.canInitiateTakeoffCommand)
                    .instructorTarget("simulation.command.takeoff")

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
                        .instructorTarget("simulation.command.hover")

                        OperationalActionButton(
                            titleKey: "command.auto_path",
                            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                        ) {
                            viewModel.activateAutoPath()
                        }
                        .instructorTarget("simulation.command.autoPath")

                        OperationalActionButton(
                            titleKey: "command.return_home",
                            systemImage: "house.fill"
                        ) {
                            viewModel.activateReturnHome()
                        }
                        .instructorTarget("simulation.command.returnHome")
                    }
                }
            }

            if viewModel.showsFixedWingLaunchStatus {
                ModuleSection(
                    titleKey: "module.flight_ops.launch_status",
                    subtitleKey: "module.flight_ops.launch_status.subtitle"
                ) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            StatusBadge(
                                titleKey: viewModel.fixedWingLaunchState.titleKey,
                                tint: launchStatusTint
                            )
                            Spacer(minLength: 8)
                            Text(LocalizedStringKey(viewModel.fixedWingLaunchMode.titleKey))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }

                        ProgressView(value: viewModel.fixedWingLaunchProgress)
                            .tint(launchStatusTint)

                        HStack {
                            Text("module.flight_ops.launch_progress")
                            Spacer()
                            Text("\(Int((viewModel.fixedWingLaunchProgress * 100.0).rounded()))%")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(GroundControlPalette.textSecondary)

                        if viewModel.fixedWingLaunchState != .idle {
                            HStack {
                                Text("module.flight_ops.launch_airspeed")
                                Spacer()
                                Text(String(format: "%.1f m/s", viewModel.fixedWingLaunchAirspeedMps))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        }

                        if let failureKey = viewModel.fixedWingLaunchFailureDetailKey {
                            Text(LocalizedStringKey(failureKey))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let warningKey = viewModel.fixedWingLaunchWarningDetailKey {
                            // The launch is running; this says which part of it went unproven.
                            // Warning colour, not danger — nothing has failed.
                            VStack(alignment: .leading, spacing: 2) {
                                Text("module.flight_ops.launch_unverified")
                                    .font(.caption2.weight(.semibold))
                                Text(LocalizedStringKey(warningKey))
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(GroundControlPalette.warning)
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
                            .instructorTarget("simulation.assist.\(assistMode.rawValue)")
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

            if viewModel.aircraftMechanizationConfiguration != nil {
                ModuleSection(titleKey: "mechanics.title", subtitleKey: "mechanics.subtitle") {
                    AircraftMechanizationControls(viewModel: viewModel)
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

    private var launchStatusTint: Color {
        switch viewModel.fixedWingLaunchState {
        case .idle:
            return GroundControlPalette.textSecondary
        case .prelaunchCheck, .aligning, .launchCommit:
            return GroundControlPalette.warning
        case .assistedAcceleration, .rotation, .initialClimb, .transitionToFlight:
            return GroundControlPalette.accent
        case .completed:
            return GroundControlPalette.success
        case .aborted:
            return GroundControlPalette.danger
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
            return "airplane.circle.fill"
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

/// Shared by both flight panels. The positions below are measured servo
/// positions; the pickers issue commands and never set a visual's transform.
///
/// Nothing here refuses a selection. The limit speeds are shown next to the levers, the load
/// on what is out is shown against its limit, and what breaks is reported where it broke.
/// A lever left in AUTO is worked by the autopilot while it is flying; a selected position
/// is the operator's and the autopilot leaves it alone.
struct AircraftMechanizationControls: View {
    @SimulationObservedObject var viewModel: DroneSimulationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                surface("mechanics.aileron", viewModel.controlSurfaceAnglesDegrees.x)
                surface("mechanics.elevator", viewModel.controlSurfaceAnglesDegrees.y)
                surface("mechanics.rudder", viewModel.controlSurfaceAnglesDegrees.z)
            }
            if let model = viewModel.aircraftMechanizationModel {
                let state = viewModel.aircraftMechanizationState
                if model.configuration.hasFlaps {
                    flaps(model.characteristics, state: state)
                }
                if model.configuration.retractableGear {
                    gear(model.characteristics, state: state)
                }
            }
        }
    }

    @ViewBuilder
    private func flaps(_ c: AircraftMechanizationCharacteristics, state: AircraftMechanizationState) -> some View {
        Picker("mechanics.flaps", selection: Binding(
            get: {
                guard !viewModel.isFlapLeverAutomatic else { return -1 }
                return viewModel.flapLeverPosition < 0.1 ? 0 : viewModel.flapLeverPosition < 0.7 ? 1 : 2
            },
            set: { viewModel.setFlapCommand($0 < 0 ? nil : $0 == 0 ? 0 : $0 == 1 ? Double(AircraftMechanizationCharacteristics.takeoffFlapSetting) : 1) }
        )) {
            Text("mechanics.automatic").tag(-1)
            Text("mechanics.retracted").tag(0)
            Text(L10n.f("mechanics.takeoff", degrees(c.flapMaxRad * AircraftMechanizationCharacteristics.takeoffFlapSetting))).tag(1)
            Text(L10n.f("mechanics.landing", degrees(c.flapMaxRad))).tag(2)
        }
        .disabled(!viewModel.canAdjustMechanization)
        reading("mechanics.actual_flaps", String(format: "%.0f° → %.0f°", degrees(state.flapAngleRadians),
                                                 degrees(state.flapSelection * c.flapMaxRad)))
        reading("mechanics.flap_limit", speed(c.flapLimitSpeedMps))
        load(state.flapLoadRatio)
        if state.flapPanelHealth.x <= 0.5 { failure("mechanics.flap_lost_left") }
        if state.flapPanelHealth.y <= 0.5 { failure("mechanics.flap_lost_right") }
    }

    @ViewBuilder
    private func gear(_ c: AircraftMechanizationCharacteristics, state: AircraftMechanizationState) -> some View {
        Picker("mechanics.gear", selection: Binding(
            get: { viewModel.isLandingGearLeverAutomatic ? -1 : viewModel.landingGearLeverDown ? 1 : 0 },
            set: { viewModel.setLandingGearCommand($0 < 0 ? nil : $0 == 1) }
        )) {
            Text("mechanics.automatic").tag(-1)
            Text("mechanics.gear_up").tag(0)
            Text("mechanics.gear_down").tag(1)
        }
        .pickerStyle(.segmented)
        .disabled(!viewModel.canAdjustMechanization)
        reading("mechanics.actual_gear", L10n.s(gearStatusKey(state)),
                tint: state.gearDownAndLocked ? GroundControlPalette.success : GroundControlPalette.textSecondary)
        reading("mechanics.gear_limit", speed(c.gearLimitSpeedMps))
        load(state.gearLoadRatio)
        if state.gearDoorsLost { failure("mechanics.gear_doors_lost") }
        if state.gearCrushedOnGround {
            failure("mechanics.gear_crushed")
        } else if state.gearLegFailed {
            failure("mechanics.gear_leg_failed")
        }
    }

    private func gearStatusKey(_ state: AircraftMechanizationState) -> String {
        if state.gearInTransit { return "mechanics.gear_moving" }
        return state.gearExtension > 0.5 ? "mechanics.gear_locked_down" : "mechanics.gear_locked_up"
    }

    /// Air load on what is deployed, against its limit. Shown from the limit upwards: below
    /// it there is nothing to report.
    @ViewBuilder
    private func load(_ ratio: Float) -> some View {
        if ratio >= 1 {
            Text(L10n.f("mechanics.overload", Int((ratio * 100).rounded()),
                        Int(AircraftMechanizationModel.ultimateLoadFactor * 100)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failure(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(GroundControlPalette.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func surface(_ key: String, _ degrees: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(key)).foregroundStyle(GroundControlPalette.textSecondary)
            Text(String(format: "%+.1f°", degrees)).monospacedDigit()
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reading(_ key: String, _ value: String,
                         tint: Color = GroundControlPalette.textSecondary) -> some View {
        HStack {
            Text(LocalizedStringKey(key)).foregroundStyle(GroundControlPalette.textSecondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(tint)
        }
        .font(.caption)
    }

    private func degrees(_ radians: Float) -> Float { radians * 180 / .pi }
    private func speed(_ metersPerSecond: Float) -> String {
        String(format: "%.0f m/s · %.0f km/h", metersPerSecond, metersPerSecond * 3.6)
    }
}
