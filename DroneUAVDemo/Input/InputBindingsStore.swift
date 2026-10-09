import Foundation

final class InputBindingsStore {
    private let keyboardInputService: KeyboardInputProviding

    init(keyboardInputService: KeyboardInputProviding) {
        self.keyboardInputService = keyboardInputService
    }

    func exportKeyboard() -> [KeyboardProfileEntry] {
        keyboardInputService.currentBindingProfile().bindings.values.sorted { $0.command.rawValue < $1.command.rawValue }.map {
            KeyboardProfileEntry(command: $0.command.rawValue, keyCode: $0.keyCode, keyLabel: $0.keyLabel, requiresShift: $0.requiresShift)
        }
    }
    func importKeyboard(_ entries: [KeyboardProfileEntry]) {
        var profile = KeyBindingProfile.default
        for entry in entries {
            guard let command = KeyboardCommand(rawValue: entry.command) else { continue }
            profile.bindings[command] = KeyBindingDescriptor(command: command, keyCode: entry.keyCode, keyLabel: KeyboardKeyLabel.label(for: entry.keyCode, shift: entry.requiresShift) ?? entry.keyLabel, requiresShift: entry.requiresShift)
        }
        keyboardInputService.replaceBindingProfile(profile)
    }

    func sections() -> [KeyBindingSection] {
        let profile = keyboardInputService.currentBindingProfile()
        return KeyBindingCategory.allCases.compactMap { category in
            let bindings = (profile.groupedBindings()[category] ?? []).filter { $0.command != .toggleControlPanel }
            guard !bindings.isEmpty else {
                return nil
            }
            return KeyBindingSection(category: category, bindings: bindings)
        }
    }

    func conflicts() -> [String] {
        keyboardInputService.currentBindingConflicts()
            .filter { !$0.contains(KeyboardCommand.toggleControlPanel.titleKey) }
    }

    func rebind(_ command: KeyboardCommand, keyCode: UInt16, keyLabel: String, requiresShift: Bool = false) {
        keyboardInputService.rebind(command: command, to: keyCode, keyLabel: keyLabel, requiresShift: requiresShift)
    }

    func resetToDefaults() {
        keyboardInputService.resetBindingsToDefault()
    }
}
