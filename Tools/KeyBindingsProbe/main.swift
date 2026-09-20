import Foundation
let suite = "UAVsim.KeyBindingsProbe.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let service = KeyboardInputService(userDefaults: defaults)
service.rebind(command: .moveForward, to: 2, keyLabel: "D")
precondition(service.currentBindingProfile().descriptor(for: .moveForward)?.keyCode == 2, "Rebinding must not be reset immediately")
let restored = KeyboardInputService(userDefaults: defaults)
precondition(restored.currentBindingProfile().descriptor(for: .moveForward)?.keyCode == 2, "Rebinding must survive relaunch")
precondition(restored.currentBindingProfile().descriptor(for: .moveRight)?.keyCode == 13, "Conflicting key must swap")
restored.resetBindingsToDefault()
let reset = KeyboardInputService(userDefaults: defaults)
precondition(reset.currentBindingProfile().descriptor(for: .moveForward)?.keyCode == 13, "Reset must persist")
print("PASS: rebind, conflict swap, relaunch persistence, reset persistence")
