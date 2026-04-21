import Foundation

final class InputBindingsStore {
    private let keyboardInputService: KeyboardInputProviding

    init(keyboardInputService: KeyboardInputProviding) {
        self.keyboardInputService = keyboardInputService
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

    func rebind(_ command: KeyboardCommand, keyCode: UInt16, keyLabel: String) {
        keyboardInputService.rebind(command: command, to: keyCode, keyLabel: keyLabel)
    }

    func resetToDefaults() {
        keyboardInputService.resetBindingsToDefault()
    }
}
