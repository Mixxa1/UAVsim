import SwiftUI
import AppKit

struct KeyBindingsSettingsView: View {
    @ObservedObject var simulationViewModel: DroneSimulationViewModel
    @ObservedObject var bindingsViewModel: BindingsViewModel
    @ObservedObject private var captureCoordinator: InputCaptureCoordinator

    @State private var keyCaptureMonitor: Any?

    init(
        simulationViewModel: DroneSimulationViewModel,
        bindingsViewModel: BindingsViewModel
    ) {
        self.simulationViewModel = simulationViewModel
        self.bindingsViewModel = bindingsViewModel
        _captureCoordinator = ObservedObject(wrappedValue: bindingsViewModel.captureCoordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            captureStatusSection

            Divider()

            controllerSettingsSection

            Divider()

            ControllerScrollableRegion(
                id: "keybindings.sheet.scroll",
                showsIndicators: false,
                isPrimary: true
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bindingsViewModel.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringKey(section.category.titleKey))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(section.bindings) { binding in
                                bindingRow(for: binding)
                            }
                        }
                    }

                    if !bindingsViewModel.conflicts.isEmpty {
                        Divider()
                        ForEach(bindingsViewModel.conflicts, id: \.self) { issue in
                            Text("⚠︎ \(issue)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            stopRebindingCapture()
            simulationViewModel.setBindingsPanelVisible(false)
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text("keybind.section.title")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                doneButton
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("keybind.section.title")
                    .font(.title3.weight(.semibold))

                doneButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var captureStatusSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                captureStatusText
                    .frame(maxWidth: .infinity, alignment: .leading)

                resetDefaultsButton
            }

            VStack(alignment: .leading, spacing: 8) {
                captureStatusText

                resetDefaultsButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var controllerSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Controller")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    controllerInfoChip(
                        title: "Input source",
                        value: inputSourceTitle(simulationViewModel.activeInputSourceKind)
                    )
                    controllerInfoChip(
                        title: "Source device",
                        value: simulationViewModel.activeGameControllerName ?? "None"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    controllerInfoChip(
                        title: "Input source",
                        value: inputSourceTitle(simulationViewModel.activeInputSourceKind)
                    )
                    controllerInfoChip(
                        title: "Source device",
                        value: simulationViewModel.activeGameControllerName ?? "None"
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Connected controllers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if simulationViewModel.connectedGameControllers.isEmpty {
                    Text("No controller connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(simulationViewModel.connectedGameControllers) { controller in
                        HStack(spacing: 8) {
                            Text(controller.name)
                                .font(.caption)
                            Spacer()
                            if controller.isActive {
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Right stick X")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(GameControllerRightStickHorizontalMode.allCases) { mode in
                            rightStickModeButton(for: mode)
                        }
                    }

                    VStack(spacing: 8) {
                        ForEach(GameControllerRightStickHorizontalMode.allCases) { mode in
                            rightStickModeButton(for: mode)
                        }
                    }
                }

                Text("Default profile maps right stick horizontal to keyboard J / L yaw semantics.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func controllerInfoChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var doneButton: some View {
        Button("common.done") {
            simulationViewModel.setBindingsPanelVisible(false)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: true, vertical: false)
        .controllerButtonTarget(id: "keybind.done") {
            simulationViewModel.setBindingsPanelVisible(false)
        }
    }

    private var captureStatusText: some View {
        Group {
            if let rebindingCommand = captureCoordinator.activeCommand {
                Text(
                    String(
                        format: NSLocalizedString("keybind.capture.prompt", comment: ""),
                        localized(rebindingCommand.titleKey)
                    )
                )
                .foregroundStyle(.orange)
            } else {
                Text("keybind.capture.idle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var resetDefaultsButton: some View {
        Button("keybind.reset_defaults") {
            stopRebindingCapture()
            bindingsViewModel.resetToDefaults()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .controllerButtonTarget(id: "keybind.resetDefaults") {
            stopRebindingCapture()
            bindingsViewModel.resetToDefaults()
        }
    }

    private func rightStickModeButton(for mode: GameControllerRightStickHorizontalMode) -> some View {
        Button {
            simulationViewModel.setGameControllerRightStickHorizontalMode(mode)
        } label: {
            Text(mode.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(
            simulationViewModel.gameControllerRightStickHorizontalMode == mode
                ? .accentColor
                : .gray.opacity(0.6)
        )
        .controllerButtonTarget(id: "gamepad.rightStick.\(mode.rawValue)") {
            simulationViewModel.setGameControllerRightStickHorizontalMode(mode)
        }
    }

    @ViewBuilder
    private func bindingRow(for binding: KeyBindingDescriptor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                bindingTitle(for: binding)
                    .frame(maxWidth: .infinity, alignment: .leading)

                bindingKeyBadge(for: binding)
                rebindButton(for: binding)
            }

            VStack(alignment: .leading, spacing: 6) {
                bindingTitle(for: binding)

                HStack(spacing: 8) {
                    bindingKeyBadge(for: binding)
                    Spacer(minLength: 8)
                    rebindButton(for: binding)
                }
            }
        }
    }

    private func bindingTitle(for binding: KeyBindingDescriptor) -> some View {
        Text(LocalizedStringKey(binding.command.titleKey))
            .font(.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bindingKeyBadge(for binding: KeyBindingDescriptor) -> some View {
        Text(binding.keyLabel)
            .font(.caption.monospaced())
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rebindButton(for binding: KeyBindingDescriptor) -> some View {
        Button(captureCoordinator.activeCommand == binding.command ? String(localized: "keybind.capturing") : String(localized: "keybind.rebind")) {
            beginRebinding(for: binding.command)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(captureCoordinator.activeCommand == binding.command ? .orange : .accentColor)
        .fixedSize(horizontal: true, vertical: false)
        .controllerButtonTarget(id: "keybind.rebind.\(binding.command.titleKey)") {
            beginRebinding(for: binding.command)
        }
    }

    private func beginRebinding(for command: KeyboardCommand) {
        stopRebindingCapture()
        bindingsViewModel.beginCapture(for: command)

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard captureCoordinator.activeCommand != nil else {
                return event
            }

            if event.keyCode == 53 { // Escape
                stopRebindingCapture()
                return nil
            }

            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
                return nil
            }

            let label = Self.displayLabel(for: event)
            bindingsViewModel.rebindCurrentCommand(keyCode: event.keyCode, keyLabel: label)
            stopRebindingCapture()
            return nil
        }
    }

    private func stopRebindingCapture() {
        if let keyCaptureMonitor {
            NSEvent.removeMonitor(keyCaptureMonitor)
            self.keyCaptureMonitor = nil
        }
        bindingsViewModel.endCapture()
    }

    private static func displayLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 24:
            if event.modifierFlags.contains(.shift) || event.characters == "+" {
                return "+"
            }
            return "="
        case 27:
            return "-"
        case 69:
            return "Num+"
        case 78:
            return "Num-"
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        case 48:
            return "Tab"
        case 49:
            return String(localized: "keybind.key.space")
        case 53:
            return "Esc"
        case 56, 60:
            return "Shift"
        default:
            if let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !chars.isEmpty {
                return chars.uppercased()
            }
            return String(
                format: NSLocalizedString("keybind.key.code", comment: ""),
                event.keyCode
            )
        }
    }

    private func inputSourceTitle(_ source: InputSourceKind?) -> String {
        switch source {
        case .keyboard:
            return "Keyboard"
        case .gameController:
            return "Game controller"
        case .remote:
            return "Remote"
        case .autopilot:
            return "Autopilot"
        case nil:
            return "None"
        }
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
