import SwiftUI
import AppKit

struct KeyBindingsSettingsView: View {
    let simulationViewModel: DroneSimulationViewModel?
    @ObservedObject var bindingsViewModel: BindingsViewModel
    @ObservedObject private var captureCoordinator: InputCaptureCoordinator

    @State private var keyCaptureMonitor: Any?
    @State private var reservedKeyNotice = false

    init(
        simulationViewModel: DroneSimulationViewModel? = nil,
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
        .padding(4)
        .frame(minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(Text("keybind.reserved.title"), isPresented: $reservedKeyNotice) {
            Button("common.ok", role: .cancel) {}
        } message: { Text("keybind.reserved.detail") }
        .onDisappear {
            stopRebindingCapture()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text("keybind.section.title")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                EmptyView()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("keybind.section.title")
                    .font(.title3.weight(.semibold))

                EmptyView()
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

    private var doneButton: some View {
        Button("common.done") {
            simulationViewModel?.setBindingsPanelVisible(false)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: true, vertical: false)
        .controllerButtonTarget(id: "keybind.done") {
            simulationViewModel?.setBindingsPanelVisible(false)
        }
    }

    private var captureStatusText: some View {
        Group {
            if let rebindingCommand = captureCoordinator.activeCommand {
                Text(
                    String(
                        format: L10n.s("keybind.capture.prompt"),
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
        Text(binding.keyCode == 49 ? L10n.s("keybind.key.space") : binding.keyLabel)
            .font(.caption.monospaced())
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rebindButton(for binding: KeyBindingDescriptor) -> some View {
        Button(captureCoordinator.activeCommand == binding.command ? L10n.s("keybind.capturing") : L10n.s("keybind.rebind")) {
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

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard captureCoordinator.activeCommand != nil else {
                return event
            }

            if event.type == .flagsChanged {
                let shift = [UInt16(56), 60].contains(event.keyCode) && event.modifierFlags.contains(.shift)
                let option = [UInt16(58), 61].contains(event.keyCode) && event.modifierFlags.contains(.option)
                if !shift && !option { return event }
            }
            if [30, 33, 34, 40].contains(event.keyCode) {
                stopRebindingCapture()
                reservedKeyNotice = true
                return nil
            }
            if event.keyCode == 53 { // Escape
                stopRebindingCapture()
                return nil
            }

            if event.type != .flagsChanged && event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
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
            return L10n.s("keybind.key.space")
        case 53:
            return "Esc"
        case 56, 60:
            return "Shift"
        case 58, 61:
            return "⌥"
        default:
            if let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !chars.isEmpty {
                return chars.uppercased()
            }
            return String(
                format: L10n.s("keybind.key.code"),
                event.keyCode
            )
        }
    }

    private func inputSourceTitle(_ source: InputSourceKind?) -> String {
        switch source {
        case .keyboard:
            return "Клавиатура"
        case .gameController:
            return "Геймпад"
        case .remote:
            return "Пульт ДУ"
        case .autopilot:
            return "Автопилот"
        case nil:
            return "Нет"
        }
    }
}

private func localized(_ key: String) -> String {
    L10n.s(key)
}
