import SwiftUI
import AppKit

struct KeyBindingsSettingsView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var rebindingCommand: KeyboardCommand?
    @State private var keyCaptureMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("keybind.section.title")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("common.done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controllerButtonTarget(id: "keybind.done") {
                    dismiss()
                }
            }

            HStack {
                if let rebindingCommand {
                    Text(
                        String(
                            format: NSLocalizedString("keybind.capture.prompt", comment: ""),
                            localized(rebindingCommand.titleKey)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("keybind.capture.idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("keybind.reset_defaults") {
                    stopRebindingCapture()
                    viewModel.resetKeyBindingsToDefault()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .controllerButtonTarget(id: "keybind.resetDefaults") {
                    stopRebindingCapture()
                    viewModel.resetKeyBindingsToDefault()
                }
            }

            Divider()

            controllerSettingsSection

            Divider()

            ControllerScrollableRegion(
                id: "keybindings.sheet.scroll",
                showsIndicators: false,
                isPrimary: true
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.keyBindingSections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringKey(section.category.titleKey))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(section.bindings) { binding in
                                HStack(spacing: 8) {
                                    Text(LocalizedStringKey(binding.command.titleKey))
                                        .font(.caption)
                                    Spacer()
                                    Text(binding.keyLabel)
                                        .font(.caption.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                                    Button(rebindingCommand == binding.command ? String(localized: "keybind.capturing") : String(localized: "keybind.rebind")) {
                                        beginRebinding(for: binding.command)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(rebindingCommand == binding.command ? .orange : .accentColor)
                                    .controllerButtonTarget(id: "keybind.rebind.\(binding.command.titleKey)") {
                                        beginRebinding(for: binding.command)
                                    }
                                }
                            }
                        }
                    }

                    if !viewModel.keyBindingConflicts.isEmpty {
                        Divider()
                        ForEach(viewModel.keyBindingConflicts, id: \.self) { issue in
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
        .frame(minWidth: 600, minHeight: 620)
        .onDisappear {
            stopRebindingCapture()
        }
    }

    private var controllerSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Controller")
                .font(.headline)

            HStack(spacing: 12) {
                controllerInfoChip(
                    title: "Input source",
                    value: inputSourceTitle(viewModel.activeInputSourceKind)
                )
                controllerInfoChip(
                    title: "Source device",
                    value: viewModel.activeGameControllerName ?? "None"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Connected controllers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if viewModel.connectedGameControllers.isEmpty {
                    Text("No controller connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.connectedGameControllers) { controller in
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

                HStack(spacing: 8) {
                    ForEach(GameControllerRightStickHorizontalMode.allCases) { mode in
                        Button {
                            viewModel.setGameControllerRightStickHorizontalMode(mode)
                        } label: {
                            Text(mode.title)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(
                            viewModel.gameControllerRightStickHorizontalMode == mode
                                ? .accentColor
                                : .gray.opacity(0.6)
                        )
                        .controllerButtonTarget(id: "gamepad.rightStick.\(mode.rawValue)") {
                            viewModel.setGameControllerRightStickHorizontalMode(mode)
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

    private func beginRebinding(for command: KeyboardCommand) {
        stopRebindingCapture()
        viewModel.beginKeyBindingCapture()
        rebindingCommand = command

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let activeCommand = rebindingCommand else {
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
            viewModel.rebindKey(activeCommand, keyCode: event.keyCode, keyLabel: label)
            stopRebindingCapture()
            return nil
        }
    }

    private func stopRebindingCapture() {
        if let keyCaptureMonitor {
            NSEvent.removeMonitor(keyCaptureMonitor)
            self.keyCaptureMonitor = nil
        }
        viewModel.endKeyBindingCapture()
        rebindingCommand = nil
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
