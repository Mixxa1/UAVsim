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
            }

            Divider()

            ScrollView {
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
        .frame(minWidth: 560, minHeight: 560)
        .onDisappear {
            stopRebindingCapture()
        }
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
            return "Left"
        case 124:
            return "Right"
        case 125:
            return "Down"
        case 126:
            return "Up"
        case 48:
            return "Tab"
        case 49:
            return "Space"
        case 53:
            return "Esc"
        case 56, 60:
            return "Shift"
        default:
            if let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key \(event.keyCode)"
        }
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
