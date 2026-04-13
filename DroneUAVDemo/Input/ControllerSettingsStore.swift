import Foundation
import SwiftUI

enum ControllerUIBindingAction: String, CaseIterable, Identifiable, Codable {
    case toggleCursor
    case openControllerHub
    case confirm
    case cancel
    case previousSection
    case nextSection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleCursor:
            return "Toggle Cursor"
        case .openControllerHub:
            return "Open Controller Hub"
        case .confirm:
            return "Confirm"
        case .cancel:
            return "Cancel / Back"
        case .previousSection:
            return "Previous Section"
        case .nextSection:
            return "Next Section"
        }
    }
}

enum ControllerButtonBinding: String, CaseIterable, Identifiable, Codable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case leftShoulder
    case rightShoulder
    case leftThumbstickButton
    case rightThumbstickButton
    case menu
    case options
    case home
    case secondaryMenu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttonA:
            return "A"
        case .buttonB:
            return "B"
        case .buttonX:
            return "X"
        case .buttonY:
            return "Y"
        case .dpadUp:
            return "D-Pad Up"
        case .dpadDown:
            return "D-Pad Down"
        case .dpadLeft:
            return "D-Pad Left"
        case .dpadRight:
            return "D-Pad Right"
        case .leftShoulder:
            return "LB / L1"
        case .rightShoulder:
            return "RB / R1"
        case .leftThumbstickButton:
            return "L3"
        case .rightThumbstickButton:
            return "R3"
        case .menu:
            return "Menu / Start"
        case .options:
            return "Options / Share"
        case .home:
            return "Home"
        case .secondaryMenu:
            return "Options / Menu"
        }
    }
}

enum ControllerScrollBehavior: String, CaseIterable, Identifiable, Codable {
    case rightStick
    case rightStickWithTriggerBoost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightStick:
            return "Right Stick"
        case .rightStickWithTriggerBoost:
            return "Stick + Trigger Boost"
        }
    }

    var summary: String {
        switch self {
        case .rightStick:
            return "Right stick Y scrolls the active panel."
        case .rightStickWithTriggerBoost:
            return "Right stick scrolls; triggers add page-style acceleration."
        }
    }
}

private struct PersistedControllerSettings: Codable {
    var bindings: [String: String]
    var cursorSpeedMultiplier: Double
    var scrollBehavior: String
}

final class ControllerSettingsStore: ObservableObject {
    private enum Persistence {
        static let settingsKey = "input.gamecontroller.uiSettings.v1"
    }

    static let defaultBindings: [ControllerUIBindingAction: ControllerButtonBinding] = [
        .toggleCursor: .rightThumbstickButton,
        .openControllerHub: .secondaryMenu,
        .confirm: .buttonA,
        .cancel: .buttonB,
        .previousSection: .leftShoulder,
        .nextSection: .rightShoulder
    ]

    private let userDefaults: UserDefaults

    @Published private(set) var bindings: [ControllerUIBindingAction: ControllerButtonBinding]
    @Published private(set) var cursorSpeedMultiplier: Double
    @Published private(set) var scrollBehavior: ControllerScrollBehavior
    @Published private(set) var validationIssues: [String] = []

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let data = userDefaults.data(forKey: Persistence.settingsKey),
           let persisted = try? JSONDecoder().decode(PersistedControllerSettings.self, from: data) {
            self.bindings = Self.decodeBindings(from: persisted.bindings)
            self.cursorSpeedMultiplier = Self.clampedCursorSpeed(persisted.cursorSpeedMultiplier)
            self.scrollBehavior = ControllerScrollBehavior(rawValue: persisted.scrollBehavior) ?? .rightStickWithTriggerBoost
        } else {
            self.bindings = Self.defaultBindings
            self.cursorSpeedMultiplier = 1.0
            self.scrollBehavior = .rightStickWithTriggerBoost
        }

        ensureDefaultBindingsPresent()
        validateBindings()
        persist()
    }

    func binding(for action: ControllerUIBindingAction) -> ControllerButtonBinding {
        bindings[action] ?? Self.defaultBindings[action] ?? .buttonA
    }

    func setBinding(_ binding: ControllerButtonBinding, for action: ControllerUIBindingAction) {
        var updated = bindings
        updated[action] = binding

        let issues = Self.validationIssues(for: updated)
        if issues.isEmpty {
            bindings = updated
            validationIssues = []
            persist()
        } else {
            validationIssues = issues
        }
    }

    func cycleBinding(
        for action: ControllerUIBindingAction,
        step: Int
    ) {
        let options = ControllerButtonBinding.allCases
        let currentBinding = binding(for: action)
        guard let currentIndex = options.firstIndex(of: currentBinding), !options.isEmpty else {
            return
        }

        let nextIndex = (currentIndex + step).positiveModulo(options.count)
        setBinding(options[nextIndex], for: action)
    }

    func setCursorSpeedMultiplier(_ value: Double) {
        let clamped = Self.clampedCursorSpeed(value)
        guard abs(cursorSpeedMultiplier - clamped) > 0.0001 else {
            return
        }

        cursorSpeedMultiplier = clamped
        persist()
    }

    func stepCursorSpeed(by delta: Double) {
        setCursorSpeedMultiplier(cursorSpeedMultiplier + delta)
    }

    func setScrollBehavior(_ behavior: ControllerScrollBehavior) {
        guard scrollBehavior != behavior else {
            return
        }

        scrollBehavior = behavior
        persist()
    }

    func restoreDefaults() {
        bindings = Self.defaultBindings
        cursorSpeedMultiplier = 1.0
        scrollBehavior = .rightStickWithTriggerBoost
        validationIssues = []
        persist()
    }

    private func ensureDefaultBindingsPresent() {
        for (action, binding) in Self.defaultBindings where bindings[action] == nil {
            bindings[action] = binding
        }
    }

    private func validateBindings() {
        validationIssues = Self.validationIssues(for: bindings)
    }

    private func persist() {
        let persisted = PersistedControllerSettings(
            bindings: bindings.reduce(into: [:]) { result, entry in
                result[entry.key.rawValue] = entry.value.rawValue
            },
            cursorSpeedMultiplier: cursorSpeedMultiplier,
            scrollBehavior: scrollBehavior.rawValue
        )

        if let data = try? JSONEncoder().encode(persisted) {
            userDefaults.set(data, forKey: Persistence.settingsKey)
        }
    }

    private static func decodeBindings(
        from rawBindings: [String: String]
    ) -> [ControllerUIBindingAction: ControllerButtonBinding] {
        var decoded: [ControllerUIBindingAction: ControllerButtonBinding] = [:]

        for (rawAction, rawBinding) in rawBindings {
            guard let action = ControllerUIBindingAction(rawValue: rawAction),
                  let binding = ControllerButtonBinding(rawValue: rawBinding) else {
                continue
            }
            decoded[action] = binding
        }

        return decoded
    }

    private static func validationIssues(
        for bindings: [ControllerUIBindingAction: ControllerButtonBinding]
    ) -> [String] {
        var issues = groupedBindingIssues(for: bindings)

        if bindings[.openControllerHub] == .menu {
            issues.append("Menu / Start is reserved for Return Home.")
        }

        return issues.sorted()
    }

    private static func groupedBindingIssues(
        for bindings: [ControllerUIBindingAction: ControllerButtonBinding]
    ) -> [String] {
        let grouped = Dictionary(grouping: bindings, by: \.value)

        return grouped.values
            .compactMap { entries in
                guard entries.count > 1 else {
                    return nil
                }

                let actions = entries
                    .map(\.key.title)
                    .sorted()
                    .joined(separator: ", ")
                let binding = entries.first?.value.title ?? "Unknown"
                return "\(binding): \(actions)"
            }
    }

    private static func clampedCursorSpeed(_ value: Double) -> Double {
        min(max(value, 0.45), 2.4)
    }
}

private extension Int {
    func positiveModulo(_ modulus: Int) -> Int {
        guard modulus > 0 else {
            return 0
        }
        let remainder = self % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
