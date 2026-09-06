import Foundation

// Headless check of the gamepad axis mapping.
//
// The layout used to be fixed in code and matched no transmitter anyone owns: the left stick flew
// pitch and roll, the right stick's vertical axis did nothing, throttle sat on the triggers, and
// the UI cursor rode the flight stick — so the pointer crept across the screen the whole time the
// aircraft was being flown. These checks pin down what replaced it.
//
// Run: Tools/ControllerAxisProbe/run.sh

var failures: [String] = []
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures.append(message) }
}

// The default is Mode 2, which is what the operator asked for and what most pilots already fly.
let map = ControllerAxisMap.default
check(map.stickMode == .mode2, "the shipped default is Mode 2")
check(map.binding(for: .throttle).source == .leftStickY, "Mode 2 puts throttle on the left stick, vertically")
check(map.binding(for: .yaw).source == .leftStickX, "Mode 2 puts yaw on the left stick, horizontally")
check(map.binding(for: .pitch).source == .rightStickY, "Mode 2 puts pitch on the right stick, vertically")
check(map.binding(for: .roll).source == .rightStickX, "Mode 2 puts roll on the right stick, horizontally")
check(map.throttleMode == .absolute, "a throttle stick reports a position, not a rate")

// The cursor must not ride a flight axis: that is the drift the operator reported.
let flightSources = Set(ControllerAxisFunction.flightAxes.map { map.binding(for: $0).source })
check(!flightSources.contains(map.binding(for: .cursorX).source), "the cursor's X axis is not a flight axis")
check(!flightSources.contains(map.binding(for: .cursorY).source), "the cursor's Y axis is not a flight axis")
check(map.binding(for: .cursorX).deadzone >= map.binding(for: .roll).deadzone,
      "the cursor holds a wider dead zone than the sticks that fly the aircraft")
check(map.conflictingFlightAxes == false, "no two flight axes share one physical stick by default")

// Every named layout is a real, distinct layout with all four axes bound.
for mode in [ControllerStickMode.mode1, .mode2, .mode3, .mode4] {
    let preset = ControllerAxisMap.preset(mode)
    check(preset.stickMode == mode, "\(mode.rawValue) round-trips through stick-mode detection")
    check(!preset.conflictingFlightAxes, "\(mode.rawValue) does not double-book a stick")
    check(ControllerAxisFunction.flightAxes.allSatisfy { preset.binding(for: $0).source != .none },
          "\(mode.rawValue) binds all four flight axes")
}

// Axis shaping. The binding owns the hardware — dead zone and inversion — and nothing else.
var binding = ControllerAxisBinding(source: .leftStickY, isInverted: false, deadzone: 0.1)
check(binding.apply(to: 0.05) == 0, "inside the dead zone an axis reads exactly zero")
check(abs(binding.apply(to: 1.0) - 1.0) < 1e-6, "full deflection still reaches full output past a dead zone")
check(abs(binding.apply(to: -1.0) + 1.0) < 1e-6, "the dead zone is symmetric")
check(binding.apply(to: 0.55) > 0.4 && binding.apply(to: 0.55) < 0.55,
      "the dead zone is rescaled rather than subtracted, so travel stays smooth")
binding.isInverted = true
check(binding.apply(to: 1.0) < 0, "inversion flips the axis")
check(ControllerAxisBinding.unbound.apply(to: 1.0) == 0, "an unbound axis contributes nothing")

// Rates. Sensitivity is a share of the airframe's own ceiling, so full stick must land on it
// exactly however the curve in between is shaped.
for sensitivity in [0.35, 0.6, 1.0] {
    for superRate in [0.0, 0.4, 0.9] {
        for expo in [0.0, 0.5, 1.0] {
            let rates = ControllerAxisRates(sensitivity: sensitivity, superRate: superRate, expo: expo)
            check(abs(rates.command(1) - sensitivity) < 1e-3,
                  "full stick commands exactly the configured share (s=\(sensitivity) sr=\(superRate) e=\(expo))")
            check(abs(rates.command(-1) + sensitivity) < 1e-3, "the curve is symmetric about centre")
            check(rates.command(0) == 0, "centred stick commands nothing")
            let quarter = rates.command(0.25)
            let half = rates.command(0.5)
            check(quarter <= half && half <= rates.command(1) + 1e-6, "the curve never runs backwards")
        }
    }
}
let linear = ControllerAxisRates(sensitivity: 1, superRate: 0, expo: 0)
check(abs(linear.command(0.5) - 0.5) < 1e-3, "with no shaping the response is a straight line")
check(ControllerAxisRates(sensitivity: 1, superRate: 0, expo: 0.8).command(0.5) < linear.command(0.5),
      "expo softens the middle of the travel")
check(ControllerAxisRates(sensitivity: 1, superRate: 0.8, expo: 0).command(0.5) < linear.command(0.5),
      "super rate keeps the middle soft and moves the sharpness to the ends")
check(ControllerRateProfile.calm.roll.halfStickShare < ControllerRateProfile.sharp.roll.halfStickShare,
      "the calm preset really is calmer at half stick than the sharp one")
check(ControllerRateProfile.default.yaw.sensitivity <= ControllerRateProfile.default.roll.sensitivity,
      "yaw is not the sharpest axis on the aircraft")

// Throttle curve.
let throttle = ControllerThrottleCurve(mid: 0.5, expo: 0, idle: 0.04)
check(abs(throttle.shaped(0) - 0.04) < 1e-6, "the bottom of the travel sits at idle, not at zero")
check(abs(throttle.shaped(1) - 1.0) < 1e-6, "the top of the travel is full throttle")
check(throttle.shaped(0.3) < throttle.shaped(0.7), "throttle rises with the stick")
let shapedThrottle = ControllerThrottleCurve(mid: 0.35, expo: 0.8, idle: 0)
check(abs(shapedThrottle.shaped(0.35) - 0.35) < 0.02, "the curve passes through its own mid point")
check(shapedThrottle.shaped(1) <= 1 && shapedThrottle.shaped(0) >= 0, "the curve stays inside the travel")
for step in 0...20 {
    let value = ControllerThrottleCurve(mid: 0.62, expo: 0.5, idle: 0.06).shaped(Double(step) / 20)
    check(value >= 0 && value <= 1, "a shaped throttle never leaves 0…1")
}

// A layout the operator has edited stops claiming to be one of the presets.
var custom = ControllerAxisMap.default
custom.setBinding(ControllerAxisBinding(source: .triggerPair), for: .throttle)
check(custom.stickMode == .custom, "an edited layout reports itself as custom")
check(!custom.binding(for: .throttle).source.isStick,
      "throttle on the triggers is not a stick, so it must fall back to rate control")

// Double-booking is detectable, because two flight axes on one stick is unflyable.
var broken = ControllerAxisMap.default
broken.setBinding(ControllerAxisBinding(source: .rightStickX), for: .yaw)
check(broken.conflictingFlightAxes, "two flight axes on one physical axis is reported as a conflict")
check(broken.conflicts[.rightStickX]?.count == 2, "the conflict names both functions involved")

if failures.isEmpty { print("PASS: \(checks) controller axis checks") }
else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
