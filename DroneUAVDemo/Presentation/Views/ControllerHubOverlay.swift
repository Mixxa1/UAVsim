import SwiftUI

enum ControllerHubSection: String, CaseIterable, Identifiable {
    case connectedDevices
    case activeProfile
    case customization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connectedDevices:
            return "Connected Devices"
        case .activeProfile:
            return "Active Controller Profile"
        case .customization:
            return "Control Customization"
        }
    }
}

struct ControllerHubOverlay: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @ObservedObject var settingsStore: ControllerSettingsStore

    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 14) {
                header
                sectionTabs
                Divider()
                    .overlay(GroundControlPalette.borderStrong)

                ControllerScrollableRegion(
                    id: "controller.hub.scroll",
                    showsIndicators: false,
                    isPrimary: true
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionContent
                    }
                    .padding(.vertical, 2)
                }

                footer
            }
            .padding(18)
            .frame(width: 760, height: 620)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(GroundControlPalette.panel.opacity(0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 26, y: 14)
            .padding(24)
        }
        .zIndex(7)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CONTROLLER HUB")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text("Input devices, routing, and controller UI bindings.")
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            Spacer()

            controllerModeBadge

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(GroundControlPalette.panelRaised)
                    )
            }
            .buttonStyle(.plain)
            .controllerButtonTarget(id: "controller.hub.close", action: onClose)
        }
    }

    private var controllerModeBadge: some View {
        let title: String
        switch viewModel.controllerInteractionMode {
        case .flight:
            title = "FLIGHT"
        case .uiNavigation:
            title = "UI NAVIGATION"
        case .textInput:
            title = "TEXT INPUT"
        }

        return Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(GroundControlPalette.inset)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )
    }

    private var sectionTabs: some View {
        HStack(spacing: 8) {
            ForEach(ControllerHubSection.allCases) { section in
                Button {
                    viewModel.controllerHubSection = section
                } label: {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            viewModel.controllerHubSection == section
                                ? GroundControlPalette.textPrimary
                                : GroundControlPalette.textSecondary
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    viewModel.controllerHubSection == section
                                        ? GroundControlPalette.accent.opacity(0.18)
                                        : GroundControlPalette.inset
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    viewModel.controllerHubSection == section
                                        ? GroundControlPalette.accent.opacity(0.58)
                                        : GroundControlPalette.border,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .controllerButtonTarget(id: "controller.hub.section.\(section.rawValue)") {
                    viewModel.controllerHubSection = section
                }
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch viewModel.controllerHubSection {
        case .connectedDevices:
            connectedDevicesSection
        case .activeProfile:
            activeProfileSection
        case .customization:
            customizationSection
        }
    }

    private var connectedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            hubSectionCard(title: "Connected Devices", subtitle: "Controllers detected by the Game Controller framework.") {
                if viewModel.connectedGameControllers.isEmpty {
                    Text("No controller connected.")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.connectedGameControllers) { controller in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(controller.name)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(GroundControlPalette.textPrimary)
                                    Spacer()
                                    statusChip(title: controller.connectionState, tint: GroundControlPalette.success)
                                    if controller.isActive {
                                        statusChip(title: "Active", tint: GroundControlPalette.accent)
                                    }
                                }

                                deviceMetaRow(title: "Vendor", value: controller.vendorName)
                                deviceMetaRow(title: "Product", value: controller.productCategory)
                                deviceMetaRow(title: "Player", value: controller.playerIndex)
                                deviceMetaRow(
                                    title: "Profile",
                                    value: controller.supportsExtendedGamepad ? "Extended Gamepad" : "Unsupported"
                                )
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(GroundControlPalette.inset)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(GroundControlPalette.border, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    private var activeProfileSection: some View {
        hubSectionCard(
            title: "Active Controller Profile",
            subtitle: "Current routing for flight controls and UI mode."
        ) {
            VStack(spacing: 10) {
                profileRow(title: "Left Stick", value: "Flight movement in flight; cursor movement when the controller cursor is visible.")
                profileRow(
                    title: "Right Stick",
                    value: "\(viewModel.gameControllerRightStickHorizontalMode.title) in flight; vertical panel scroll in UI."
                )
                profileRow(title: "Confirm", value: settingsStore.binding(for: .confirm).title)
                profileRow(title: "Cancel", value: settingsStore.binding(for: .cancel).title)
                profileRow(title: "Toggle Cursor", value: settingsStore.binding(for: .toggleCursor).title)
                profileRow(title: "Open Controller Hub", value: settingsStore.binding(for: .openControllerHub).title)
                profileRow(
                    title: "LB / RB",
                    value: "\(settingsStore.binding(for: .previousSection).title) / \(settingsStore.binding(for: .nextSection).title) cycle hub sections when the hub is open."
                )
                profileRow(
                    title: "Triggers",
                    value: settingsStore.scrollBehavior == .rightStickWithTriggerBoost
                        ? "Throttle in flight; trigger boost for panel scrolling in UI."
                        : "Throttle in flight; no extra UI scroll boost."
                )
            }
        }
    }

    private var customizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            hubSectionCard(
                title: "UI Bindings",
                subtitle: "Bindings here only affect the controller-driven UI layer."
            ) {
                VStack(spacing: 10) {
                    ForEach(ControllerUIBindingAction.allCases) { action in
                        bindingRow(for: action)
                    }

                    if !settingsStore.validationIssues.isEmpty {
                        Divider()
                        ForEach(settingsStore.validationIssues, id: \.self) { issue in
                            Text("Conflict: \(issue)")
                                .font(.caption)
                                .foregroundStyle(GroundControlPalette.warning)
                        }
                    }
                }
            }

            hubSectionCard(
                title: "Pointer & Scroll",
                subtitle: "Cursor speed and panel scroll behavior for UI navigation."
            ) {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Cursor Speed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Spacer()
                        bindingAdjustmentButton(
                            title: "Decrease Cursor Speed",
                            systemImage: "minus",
                            id: "controller.hub.cursorSpeed.decrease"
                        ) {
                            settingsStore.stepCursorSpeed(by: -0.1)
                        }
                        Text(String(format: "%.2fx", settingsStore.cursorSpeedMultiplier))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(GroundControlPalette.textPrimary)
                            .frame(width: 62)
                        bindingAdjustmentButton(
                            title: "Increase Cursor Speed",
                            systemImage: "plus",
                            id: "controller.hub.cursorSpeed.increase"
                        ) {
                            settingsStore.stepCursorSpeed(by: 0.1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scroll Behavior")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)

                        HStack(spacing: 8) {
                            ForEach(ControllerScrollBehavior.allCases) { behavior in
                                Button {
                                    settingsStore.setScrollBehavior(behavior)
                                } label: {
                                    Text(behavior.title)
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(
                                    settingsStore.scrollBehavior == behavior
                                        ? GroundControlPalette.accent
                                        : .gray.opacity(0.6)
                                )
                                .controllerButtonTarget(id: "controller.hub.scroll.\(behavior.rawValue)") {
                                    settingsStore.setScrollBehavior(behavior)
                                }
                            }
                        }

                        Text(settingsStore.scrollBehavior.summary)
                            .font(.caption)
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settingsStore.restoreDefaults()
                }
                .buttonStyle(.bordered)
                .controllerButtonTarget(id: "controller.hub.restoreDefaults") {
                    settingsStore.restoreDefaults()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(
                "\(settingsStore.binding(for: .toggleCursor).title) Toggle Cursor  •  \(settingsStore.binding(for: .openControllerHub).title) Open Hub  •  \(settingsStore.binding(for: .cancel).title) Back"
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer()
        }
    }

    private func bindingRow(
        for action: ControllerUIBindingAction
    ) -> some View {
        HStack(spacing: 10) {
            Text(action.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)

            Spacer()

            bindingAdjustmentButton(
                title: "Previous \(action.title) binding",
                systemImage: "chevron.left",
                id: "controller.hub.binding.previous.\(action.rawValue)"
            ) {
                settingsStore.cycleBinding(for: action, step: -1)
            }

            Text(settingsStore.binding(for: action).title)
                .font(.caption.monospaced())
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(GroundControlPalette.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(GroundControlPalette.border, lineWidth: 1)
                )
                .frame(width: 150)

            bindingAdjustmentButton(
                title: "Next \(action.title) binding",
                systemImage: "chevron.right",
                id: "controller.hub.binding.next.\(action.rawValue)"
            ) {
                settingsStore.cycleBinding(for: action, step: 1)
            }
        }
    }

    private func bindingAdjustmentButton(
        title: String,
        systemImage: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(GroundControlPalette.panelRaised)
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .controllerButtonTarget(id: id, action: action)
    }

    private func hubSectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func profileRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(width: 126, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func deviceMetaRow(title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusChip(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.46), lineWidth: 1)
            )
    }
}
