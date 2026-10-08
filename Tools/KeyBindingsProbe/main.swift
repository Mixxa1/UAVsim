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

// Shift chords: the undercarriage and flap levers ride C and F with Shift held.
let fresh = reset.currentBindingProfile()
precondition(fresh.commands(for: 8, shiftHeld: true) == [.toggleLandingGear], "Shift+C must be the undercarriage lever")
precondition(fresh.commands(for: 8, shiftHeld: false) == [.cycleCameraMode], "C alone must still cycle the camera")
precondition(fresh.commands(for: 3, shiftHeld: true) == [.stepFlaps], "Shift+F must step the flaps")
precondition(fresh.commands(for: 3, shiftHeld: false) == [.toggleMissionMap], "F alone must still open the mission map")
// Shift is also "accelerate": a key with no chord on it must keep working while Shift is down.
precondition(fresh.commands(for: 13, shiftHeld: true) == [.moveForward], "Shift+W must still be W")
precondition(!fresh.conflicts().contains { $0.hasPrefix("C:") || $0.hasPrefix("F:") || $0.contains("⇧") },
             "A key and its Shift chord are not a conflict: \(fresh.conflicts())")

// Re-applying the unshifted binding, as a stored profile does on every launch, must leave the chord alone.
reset.rebind(command: .cycleCameraMode, to: 8, keyLabel: "C")
precondition(reset.currentBindingProfile().descriptor(for: .toggleLandingGear)?.requiresShift == true
             && reset.currentBindingProfile().descriptor(for: .toggleLandingGear)?.keyCode == 8,
             "Rebinding C must not disturb Shift+C")
let chordRestored = KeyboardInputService(userDefaults: defaults)
precondition(chordRestored.currentBindingProfile().commands(for: 8, shiftHeld: true) == [.toggleLandingGear],
             "The chord must survive relaunch")

// A profile saved before these commands existed gets them at their defaults.
let legacy = #"{"bindings":[{"command":"moveForward","keyCode":13,"keyLabel":"W"},{"command":"cycleCameraMode","keyCode":8,"keyLabel":"C"},{"command":"toggleMissionMap","keyCode":3,"keyLabel":"F"}]}"#
defaults.set(Data(legacy.utf8), forKey: "input.bindings.profile.v3")
let migrated = KeyboardInputService(userDefaults: defaults).currentBindingProfile()
precondition(migrated.commands(for: 8, shiftHeld: true) == [.toggleLandingGear]
             && migrated.commands(for: 3, shiftHeld: true) == [.stepFlaps]
             && migrated.commands(for: 8, shiftHeld: false) == [.cycleCameraMode],
             "An older saved profile must gain the new chords without losing its own keys")

// Moved to a plain key from the bindings screen, a lever is a plain key from then on.
let rebound = KeyboardInputService(userDefaults: defaults)
rebound.rebind(command: .toggleLandingGear, to: 41, keyLabel: ";")
let plain = KeyboardInputService(userDefaults: defaults).currentBindingProfile()
precondition(plain.commands(for: 41, shiftHeld: false) == [.toggleLandingGear]
             && plain.commands(for: 8, shiftHeld: true) == [.cycleCameraMode],
             "A lever rebound to a plain key must leave Shift+C to C")
print("PASS: rebind, conflict swap, relaunch persistence, reset persistence, Shift chords and their migration")

let training = KeyBindingProfile.default
precondition(training.commands(for: 43, shiftHeld: false) == [.armAircraft], "< arms the aircraft")
precondition(training.commands(for: 47, shiftHeld: false) == [.disarmAircraft], "> disarms the aircraft")
precondition(training.commands(for: 0, shiftHeld: true) == [.moveLeft], "Shift+A must retain boosted lateral flight")
precondition(training.commands(for: 0, shiftHeld: false) == [.moveLeft], "A remains the normal lateral input")
precondition(training.commands(for: 32, shiftHeld: false) == [.takeoff], "U takes off")
precondition(training.commands(for: 32, shiftHeld: true) == [.land], "Shift+U lands")
precondition(training.commands(for: 17, shiftHeld: true) == [.altitudeHold], "Shift+T engages altitude hold")
precondition(training.commands(for: 17, shiftHeld: false) == [.toggleTelemetryHUD], "T keeps its existing HUD action")
precondition(training.commands(for: 46, shiftHeld: true) == [.openFlightPanel], "Flight controls have an actual shortcut")
precondition(training.commands(for: 46, shiftHeld: false) == [.manualControl], "M hands back manual control")
for command in [KeyboardCommand.moveForward, .moveBackward, .moveLeft, .moveRight, .ascend, .descend, .yawLeft, .yawRight] {
    let descriptor = training.descriptor(for: command)!
    precondition(training.commands(for: descriptor.keyCode, shiftHeld: true) == [command], "Boosted flight axes must retain their bindings")
}
precondition(training.commands(for: 31, shiftHeld: true) == [.openCameraPanel], "Camera controls have an actual shortcut")
precondition(training.commands(for: 31, shiftHeld: false) == [.cameraModePayloadOptics], "O keeps its existing camera action")
let assignedTraining = KeyBindingProfile(bindings: training.bindings.filter { $0.value.keyCode != UInt16.max })
precondition(assignedTraining.conflicts().isEmpty, "New training shortcuts must not conflict with existing assigned bindings")
let mapped = KeyboardInputService(userDefaults: defaults)
mapped.rebind(command: .takeoff, to: 9, keyLabel: "⇧V", requiresShift: true)
let savedChord = KeyboardInputService(userDefaults: defaults).currentBindingProfile()
precondition(savedChord.commands(for: 9, shiftHeld: true) == [.takeoff], "A custom tutorial chord persists")
precondition(savedChord.descriptor(for: .takeoff)?.requiresShift == true, "Shift is stored as a modifier")
mapped.rebind(command: .takeoff, to: 9, keyLabel: "V")
let savedPlain = KeyboardInputService(userDefaults: defaults).currentBindingProfile()
precondition(savedPlain.commands(for: 9, shiftHeld: false) == [.takeoff], "A tutorial command can be rebound to a plain key")
precondition(savedPlain.descriptor(for: .takeoff)?.requiresShift == false, "Changing to a plain key clears the chord")
print("PASS: tutorial command defaults, conflict-free chords, modifier persistence and plain-key remapping")

// Profiles created by the first instructor build used Y / Shift+Y. Migrate only those generated
// descriptors so the established physical arm/disarm keys return without overwriting a deliberate
// custom mapping.
let migrationSuite = "UAVsim.KeyBindingsMigrationProbe.\(UUID().uuidString)"
let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
migrationDefaults.set(true, forKey: "input.bindings.migrated.instructor.v2")
let staleTutorialProfile = #"{"bindings":[{"command":"armAircraft","keyCode":16,"keyLabel":"Y"},{"command":"disarmAircraft","keyCode":16,"keyLabel":"⇧Y","requiresShift":true}]}"#
migrationDefaults.set(Data(staleTutorialProfile.utf8), forKey: "input.bindings.profile.v3")
let repaired = KeyboardInputService(userDefaults: migrationDefaults).currentBindingProfile()
precondition(repaired.descriptor(for: .armAircraft)?.keyCode == 43
             && repaired.descriptor(for: .armAircraft)?.keyLabel == "<"
             && repaired.descriptor(for: .disarmAircraft)?.keyCode == 47
             && repaired.descriptor(for: .disarmAircraft)?.keyLabel == ">",
             "The shipped Y tutorial bindings must migrate to < and >")
print("PASS: stale tutorial arm/disarm bindings migrate to < and >")

// Exercise the production command dispatcher directly; no desktop input events are posted.
let dispatcher = KeyboardInputService(userDefaults: defaults)
let tutorialActions: [(KeyboardCommand, InputAction)] = [
    (.armAircraft, .armAircraft), (.disarmAircraft, .disarmAircraft),
    (.takeoff, .requestTakeoff), (.land, .requestLanding), (.autoPath, .activateAutoPath),
    (.returnHome, .returnHome), (.manualControl, .takeManualControl), (.altitudeHold, .activateAltitudeHold),
    (.openFlightPanel, .openFlightPanel), (.openCameraPanel, .openCameraPanel)
]
for (command, expected) in tutorialActions {
    precondition(dispatcher.dispatchCommandForTesting(command) == [expected], "Tutorial key must dispatch its actual flight command: \(command)")
}
print("PASS: all ten tutorial keyboard commands dispatch real input actions")
