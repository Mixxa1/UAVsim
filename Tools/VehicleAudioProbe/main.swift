import Foundation
import simd

// Headless probe for the vehicle acoustic model.
//
// The audio plan asks for a specific set of behaviours from the aircraft's own sound, and
// almost all of them are wrong-by-arithmetic rather than wrong-by-taste — which means they
// can be caught here instead of by listening:
//
//  1. **The profile comes from the machine, not from its name.** A 900 g quad that does
//     30 m/s is an FPV quad; a 25 kg hexacopter is not; a turboprop is neither.
//  2. **Pitch tracks shaft speed, monotonically.** More RPM must never mean lower pitch.
//  3. **Doppler has the right sign.** An aircraft coming at the listener is sharper, one
//     going away is flatter, and a chase camera moving with it hears neither.
//  4. **The life cycle is not one flag.** Powered is not armed, armed is not spinning, and
//     spinning on the ground is not flying — the plan is explicit that collapsing these is
//     what makes a link failure stop the motors.
//  5. **Airflow is gated on flight and grows with speed.**
//  6. **Damage is audible.** A rotor that has lost thrust is quieter; an unbalanced one is
//     uneven.
//
// Run: Tools/VehicleAudioProbe/run.sh

var failures: [String] = []

/// `String(format:)` with `%s` takes a C string; handing it a Swift String is undefined and
/// crashes. Columns are padded here instead.
func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
}

func check(_ condition: Bool, _ description: String) {
    if !condition { failures.append(description) }
}

func baseInput() -> VehicleAudioInput {
    var input = VehicleAudioInput()
    input.isSessionRunning = true
    input.listenerPosition = SIMD3<Float>(0, 2, 0)
    input.worldPosition = SIMD3<Float>(0, 30, -40)
    return input
}

// MARK: - 1. Profiles come from the vehicle's own numbers

print("Acoustic class resolution — from powerplant, rotor count, mass and speed")
print(String(repeating: "-", count: 92))

struct ProfileCase {
    let label: String
    let airframe: AirframeClass
    let engine: UAVEngineType?
    let rotors: Int
    let massKg: Float
    let speed: Float
    let expected: VehicleAudioClass
    var vehicle: UAVVehicleType? = nil
}

let profileCases: [ProfileCase] = [
    .init(label: "5-inch FPV quad", airframe: .multirotor, engine: nil, rotors: 4, massKg: 0.72, speed: 32.0, expected: .fpvQuad),
    .init(label: "camera quad (Mavic class)", airframe: .multirotor, engine: nil, rotors: 4, massKg: 0.57, speed: 16.0, expected: .smallMultirotor),
    .init(label: "industrial hexacopter", airframe: .multirotor, engine: nil, rotors: 6, massKg: 9.5, speed: 20.0, expected: .heavyMultirotor),
    .init(label: "heavy quad lifter", airframe: .multirotor, engine: nil, rotors: 4, massKg: 24.0, speed: 18.0, expected: .heavyMultirotor),
    .init(label: "electric fixed wing", airframe: .fixedWing, engine: .electricMotor, rotors: 1, massKg: 3.5, speed: 28.0, expected: .electricFixedWing),
    .init(label: "two-stroke fixed wing", airframe: .fixedWing, engine: .pistonTwoStroke, rotors: 1, massKg: 22.0, speed: 45.0, expected: .pistonFixedWing),
    .init(label: "turboprop UAV", airframe: .fixedWing, engine: .turboprop, rotors: 1, massKg: 2_200.0, speed: 130.0, expected: .turbopropFixedWing),
    .init(label: "turbojet UAV", airframe: .fixedWing, engine: .turbojet, rotors: 1, massKg: 1_100.0, speed: 300.0, expected: .turbojetFixedWing),
    .init(label: "battery VTOL", airframe: .hybridVTOL, engine: nil, rotors: 5, massKg: 5.5, speed: 26.0, expected: .electricFixedWing),
    // The catalogue's one rotorcraft: a 57 kg tandem-rotor cargo machine. It is filed under
    // `.multirotor` like every other rotor-borne airframe, so without the vehicle type it
    // resolves to "heavy multirotor" and flies on small fast propellers.
    .init(label: "tandem-rotor cargo helicopter", airframe: .multirotor, engine: nil, rotors: 2,
          massKg: 57.0, speed: 19.0, expected: .helicopter, vehicle: .helicopter)
]

print(pad("aircraft", 28) + pad("expected", 24) + pad("resolved", 24))
for testCase in profileCases {
    let profile = VehicleAudioProfile.resolve(
        airframeClass: testCase.airframe,
        engineType: testCase.engine,
        rotorCount: testCase.rotors,
        takeoffMassKg: testCase.massKg,
        maxHorizontalSpeedMps: testCase.speed,
        ratedShaftRPM: testCase.engine == .turboprop ? 1_591.0 : nil,
        propellerBladeCount: 2,
        vehicleType: testCase.vehicle
    )
    let ok = profile.audioClass == testCase.expected
    print(pad(testCase.label, 28) + pad(testCase.expected.rawValue, 24)
          + pad(profile.audioClass.rawValue, 24) + (ok ? "ok" : "MISMATCH"))
    check(ok, "\(testCase.label) resolved to \(profile.audioClass.rawValue), expected \(testCase.expected.rawValue)")
}

// MARK: - 2. Pitch and level follow shaft speed

print()
print("Rotor speed → pitch and level (small multirotor, reference 440 rad/s)")
print(String(repeating: "-", count: 92))

let quadProfile = VehicleAudioProfile.resolve(
    airframeClass: .multirotor,
    engineType: nil,
    rotorCount: 4,
    takeoffMassKg: 0.6,
    maxHorizontalSpeedMps: 16.0,
    ratedShaftRPM: nil,
    propellerBladeCount: 2
)

var previousPitch: Float = 0.0
var previousGain: Float = -.greatestFiniteMagnitude
var pitchMonotonic = true
var gainMonotonic = true
print(padLeft("rad/s", 10) + padLeft("pitch", 11) + padLeft("gain dB", 11))
for omega in stride(from: Float(80.0), through: Float(760.0), by: 80.0) {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .airborne
    input.rotorSpeedsRadPerSec = SIMD4<Float>(repeating: omega)
    let plan = runtime.update(profile: quadProfile, input: input)
    guard let layer = plan.layers.first(where: { $0.id == quadProfile.propulsionLoop }) else {
        check(false, "no propulsion layer at \(omega) rad/s")
        continue
    }
    print(String(format: "%10.0f %10.3f %10.1f", omega, layer.pitchRatio, layer.gainDb))
    if layer.pitchRatio < previousPitch { pitchMonotonic = false }
    if layer.gainDb < previousGain { gainMonotonic = false }
    previousPitch = layer.pitchRatio
    previousGain = layer.gainDb
}
check(pitchMonotonic, "pitch is not monotonic in rotor speed")
check(gainMonotonic, "level is not monotonic in rotor speed")

// A rotor below the spin threshold makes no propulsion sound at all.
do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.rotorSpeedsRadPerSec = SIMD4<Float>(repeating: 10.0)
    let plan = runtime.update(profile: quadProfile, input: input)
    check(
        !plan.layers.contains { $0.id == quadProfile.propulsionLoop },
        "a barely-turning rotor still produced a propulsion loop"
    )
}

// A dead lane must not drag the average down — the surviving rotors are what is audible.
do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .airborne
    input.rotorSpeedsRadPerSec = SIMD4<Float>(440.0, 440.0, 440.0, 0.0)
    let plan = runtime.update(profile: quadProfile, input: input)
    let pitch = plan.layers.first { $0.id == quadProfile.propulsionLoop }?.pitchRatio ?? 0.0
    print(String(format: "\nthree live rotors at 440 rad/s, one dead: pitch %.3f (expected ≈ 1.0)", pitch))
    check(abs(pitch - 1.0) < 0.03, "a dead rotor lane changed the pitch of the surviving ones")
}

// MARK: - 3. Doppler

print()
print("Doppler — c = 343 m/s, source 100 m from the listener")
print(String(repeating: "-", count: 92))

let listener = SIMD3<Float>(0, 0, 0)
let source = SIMD3<Float>(0, 0, -100)
let towards = SIMD3<Float>(0, 0, 60)      // +z is towards the listener from −z
let away = SIMD3<Float>(0, 0, -60)
let across = SIMD3<Float>(60, 0, 0)

let approaching = VehicleAudioRuntime.dopplerRatio(
    sourcePosition: source, sourceVelocity: towards,
    listenerPosition: listener, listenerVelocity: .zero, speedOfSoundMps: 343.0
)
let receding = VehicleAudioRuntime.dopplerRatio(
    sourcePosition: source, sourceVelocity: away,
    listenerPosition: listener, listenerVelocity: .zero, speedOfSoundMps: 343.0
)
let tangential = VehicleAudioRuntime.dopplerRatio(
    sourcePosition: source, sourceVelocity: across,
    listenerPosition: listener, listenerVelocity: .zero, speedOfSoundMps: 343.0
)
let chased = VehicleAudioRuntime.dopplerRatio(
    sourcePosition: source, sourceVelocity: towards,
    listenerPosition: listener, listenerVelocity: towards, speedOfSoundMps: 343.0
)
print(String(format: "approaching at 60 m/s : %.4f   (expected > 1)", approaching))
print(String(format: "receding at 60 m/s    : %.4f   (expected < 1)", receding))
print(String(format: "crossing at 60 m/s    : %.4f   (expected = 1)", tangential))
print(String(format: "chase camera keeping up: %.4f   (expected = 1)", chased))
check(approaching > 1.15, "an approaching source was not raised in pitch")
check(receding < 0.88, "a receding source was not lowered in pitch")
check(abs(tangential - 1.0) < 0.001, "a source crossing the line of sight was shifted")
check(abs(chased - 1.0) < 0.02, "a listener moving with the source still heard a shift")

// The textbook value: 343/(343−60) = 1.212.
check(abs(approaching - 343.0 / 283.0) < 0.001, "approach ratio does not match c/(c−v)")

// MARK: - 4. The life cycle is not one flag

print()
print("Acoustic phase — the plan's OFF → POWERED → ARMED → SPINNING → AIRBORNE chain")
print(String(repeating: "-", count: 92))

struct PhaseCase {
    let label: String
    let armed: Bool
    let physical: DronePhysicalState
    let omega: Float
    let expected: VehicleAudioPhase
}

let phaseCases: [PhaseCase] = [
    .init(label: "avionics on, disarmed", armed: false, physical: .disarmed, omega: 0, expected: .powered),
    .init(label: "armed, rotors stopped", armed: true, physical: .armedOnGround, omega: 0, expected: .armed),
    .init(label: "armed, rotors turning on the ground", armed: true, physical: .armedOnGround, omega: 300, expected: .rotorsSpinning),
    .init(label: "airborne", armed: true, physical: .airborne, omega: 460, expected: .airborne),
    .init(label: "disarmed in the air, rotors still turning", armed: false, physical: .airborne, omega: 300, expected: .airborne),
    .init(label: "crashed, rotors winding down", armed: false, physical: .crashed, omega: 200, expected: .spindown),
    .init(label: "crashed and still", armed: false, physical: .crashed, omega: 0, expected: .powered)
]

for testCase in phaseCases {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = testCase.armed
    input.physicalState = testCase.physical
    input.rotorSpeedsRadPerSec = SIMD4<Float>(repeating: testCase.omega)
    let plan = runtime.update(profile: quadProfile, input: input)
    let ok = plan.phase == testCase.expected
    print(String(
        format: "%-44@ %-16@ %@",
        testCase.label as NSString,
        plan.phase.rawValue as NSString,
        ok ? "ok" : "expected \(testCase.expected.rawValue)"
    ))
    check(ok, "\(testCase.label) gave phase \(plan.phase.rawValue), expected \(testCase.expected.rawValue)")
}

// The electronics cue fires once, and it fires before anything is armed.
do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    let first = runtime.update(profile: quadProfile, input: input)
    input.simulationTime = 0.1
    let second = runtime.update(profile: quadProfile, input: input)
    check(first.cues.contains { $0.id == .fpvElectronicsBoot }, "no electronics boot cue on power-up")
    check(second.cues.isEmpty, "the electronics boot cue repeated on the next tick")
    print("\nelectronics boot fires once on power-up, before arming: ok")
}

// Spin-up fires on the threshold crossing, not every tick above it.
do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    _ = runtime.update(profile: quadProfile, input: input)
    input.rotorSpeedsRadPerSec = SIMD4<Float>(repeating: 300.0)
    let crossing = runtime.update(profile: quadProfile, input: input)
    let after = runtime.update(profile: quadProfile, input: input)
    check(crossing.cues.contains { $0.id == quadProfile.spinUpCue }, "no spin-up cue when the rotors started")
    check(after.cues.isEmpty, "the spin-up cue repeated while the rotors kept turning")
    print("spin-up fires once on the threshold crossing: ok")
}

// MARK: - 5. Airflow

print()
print("Airflow layer — gated on flight, level rising with airspeed")
print(String(repeating: "-", count: 92))

let wingProfile = VehicleAudioProfile.resolve(
    airframeClass: .fixedWing,
    engineType: .electricMotor,
    rotorCount: 1,
    takeoffMassKg: 3.5,
    maxHorizontalSpeedMps: 30.0,
    ratedShaftRPM: nil,
    propellerBladeCount: 2
)

var previousAirflowGain = -Float.greatestFiniteMagnitude
var airflowMonotonic = true
print(padLeft("m/s", 10) + padLeft("airflow dB", 13) + padLeft("pitch", 11))
for airspeed in stride(from: Float(4.0), through: Float(40.0), by: 6.0) {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .airborne
    input.rotorSpeedsRadPerSec = SIMD4<Float>(400.0, 0, 0, 0)
    input.forwardAirspeedMps = airspeed
    let plan = runtime.update(profile: wingProfile, input: input)
    if let airflow = plan.layers.first(where: { $0.id == .airflowLoop }) {
        print(String(format: "%10.0f %12.1f %10.3f", airspeed, airflow.gainDb, airflow.pitchRatio))
        if airflow.gainDb < previousAirflowGain { airflowMonotonic = false }
        previousAirflowGain = airflow.gainDb
    } else {
        print(padLeft(String(format: "%.0f", airspeed), 10) + padLeft("—", 13) + padLeft("—", 11))
        check(airspeed < 9.0, "no airflow layer at \(airspeed) m/s")
    }
}
check(airflowMonotonic, "airflow level is not monotonic in airspeed")

do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .armedOnGround
    input.rotorSpeedsRadPerSec = SIMD4<Float>(400.0, 0, 0, 0)
    input.forwardAirspeedMps = 30.0
    let plan = runtime.update(profile: wingProfile, input: input)
    check(
        !plan.layers.contains { $0.id == .airflowLoop },
        "an aircraft sitting on the ground produced airflow noise"
    )
    print("\nno airflow while on the ground, whatever the airspeed reads: ok")
}

// Thinner air is quieter at the same true airspeed.
do {
    func airflowGain(density: Float) -> Float {
        let runtime = VehicleAudioRuntime()
        var input = baseInput()
        input.isArmed = true
        input.physicalState = .airborne
        input.rotorSpeedsRadPerSec = SIMD4<Float>(400.0, 0, 0, 0)
        input.forwardAirspeedMps = 30.0
        input.airDensityKgPerM3 = density
        return runtime.update(profile: wingProfile, input: input)
            .layers.first { $0.id == .airflowLoop }?.gainDb ?? 0.0
    }
    let seaLevel = airflowGain(density: AtmosphereModel.seaLevelDensity)
    let highAltitude = airflowGain(density: AtmosphereModel.seaLevelDensity * 0.3)
    print(String(format: "airflow at 30 m/s: %.1f dB at sea level, %.1f dB at 30%% density", seaLevel, highAltitude))
    check(highAltitude < seaLevel - 3.0, "thin air was not quieter than sea level")
}

// MARK: - 6. Damage is audible

print()
print("Damage — lost thrust and rotor imbalance")
print(String(repeating: "-", count: 92))

func propulsionGain(thrustFactor: Float, vibration: Float, time: Float) -> Float {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .airborne
    input.rotorSpeedsRadPerSec = SIMD4<Float>(repeating: 440.0)
    input.rotorThrustFactor = thrustFactor
    input.rotorVibration = vibration
    input.simulationTime = time
    return runtime.update(profile: quadProfile, input: input)
        .layers.first { $0.id == quadProfile.propulsionLoop }?.gainDb ?? -.greatestFiniteMagnitude
}

let healthy = propulsionGain(thrustFactor: 1.0, vibration: 0.0, time: 0.0)
let damaged = propulsionGain(thrustFactor: 0.45, vibration: 0.0, time: 0.0)
print(String(format: "intact rotors: %.1f dB, rotors at 45%% thrust: %.1f dB", healthy, damaged))
check(damaged < healthy - 1.5, "damaged rotors were not quieter")

// The wobble must actually move, and must be reproducible for the same simulation time —
// a replay has to sound like the flight it recorded.
let wobbleA = propulsionGain(thrustFactor: 1.0, vibration: 0.8, time: 0.30)
let wobbleB = propulsionGain(thrustFactor: 1.0, vibration: 0.8, time: 0.34)
let wobbleARepeat = propulsionGain(thrustFactor: 1.0, vibration: 0.8, time: 0.30)
print(String(format: "unbalanced rotor at t=0.30 s: %.2f dB, at t=0.34 s: %.2f dB", wobbleA, wobbleB))
check(abs(wobbleA - wobbleB) > 0.3, "an unbalanced rotor produced a steady level")
check(wobbleA == wobbleARepeat, "the imbalance wobble is not reproducible at the same time")

// MARK: - 7. Every class has a voice, and they are different voices

print()
print("Propulsion assets by class")
print(String(repeating: "-", count: 92))

var loopsByClass: [VehicleAudioClass: AudioAssetID] = [:]
for testCase in profileCases {
    let profile = VehicleAudioProfile.resolve(
        airframeClass: testCase.airframe,
        engineType: testCase.engine,
        rotorCount: testCase.rotors,
        takeoffMassKg: testCase.massKg,
        maxHorizontalSpeedMps: testCase.speed,
        ratedShaftRPM: testCase.engine == .turboprop ? 1_591.0 : nil,
        propellerBladeCount: 2,
        vehicleType: testCase.vehicle
    )
    loopsByClass[profile.audioClass] = profile.propulsionLoop
    let loop = profile.propulsionLoop?.rawValue ?? "— none —"
    let start = profile.engineStartCue?.rawValue ?? "—"
    let servo = profile.mechanismCue?.rawValue ?? "—"
    print(pad(profile.audioClass.rawValue, 22) + pad(loop, 26) + pad(start, 20) + servo)
    check(profile.propulsionLoop != nil, "\(profile.audioClass.rawValue) has no propulsion sound")
}

// A turbojet must not be issued a propeller loop, and a piston engine must not be issued a
// turbine — the whole point of resolving a class is that the classes differ.
check(
    loopsByClass[.turbojetFixedWing] != loopsByClass[.pistonFixedWing],
    "turbojet and piston share a propulsion loop"
)
check(
    loopsByClass[.turbopropFixedWing] != loopsByClass[.turbojetFixedWing],
    "turboprop and turbojet share a propulsion loop"
)
check(
    loopsByClass[.pistonFixedWing] != loopsByClass[.smallMultirotor],
    "a piston aeroplane and a camera quad share a propulsion loop"
)

// Fuel engines get a start cue and multirotors do not — there is nothing to start.
let pistonProfile = VehicleAudioProfile.resolve(
    airframeClass: .fixedWing, engineType: .pistonTwoStroke, rotorCount: 1,
    takeoffMassKg: 22.0, maxHorizontalSpeedMps: 45.0, ratedShaftRPM: 5_500.0, propellerBladeCount: 2
)
check(pistonProfile.engineStartCue != nil, "a piston engine has no start cue")
check(quadProfile.engineStartCue == nil, "a battery quadcopter was given an engine start cue")
check(quadProfile.mechanismCue == nil, "a multirotor was given control-surface servos")

// The start cue fires when the starter engages, once, not on every tick of the sequence.
do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.engineRunState = .priming
    _ = runtime.update(profile: pistonProfile, input: input)
    input.engineRunState = .cranking
    let cranking = runtime.update(profile: pistonProfile, input: input)
    let stillCranking = runtime.update(profile: pistonProfile, input: input)
    input.engineRunState = .lightOff
    let lightOff = runtime.update(profile: pistonProfile, input: input)
    check(cranking.cues.contains { $0.id == pistonProfile.engineStartCue },
          "no start cue when the starter engaged")
    check(stillCranking.cues.isEmpty, "the start cue repeated while still cranking")
    check(!lightOff.cues.contains { $0.id == pistonProfile.engineStartCue },
          "the start cue fired again at light-off")
    print("\nengine start fires once, when the starter engages: ok")
}

// A ramjet has no starter at all, so it must not be given a start sound to explain.
let ramjetProfile = VehicleAudioProfile.resolve(
    airframeClass: .fixedWing, engineType: .ramjet, rotorCount: 1,
    takeoffMassKg: 1_100.0, maxHorizontalSpeedMps: 700.0, ratedShaftRPM: nil, propellerBladeCount: 1
)
check(ramjetProfile.engineStartCue == nil, "a ramjet was given a start cue")
print("a ramjet gets no start cue: ok")

// MARK: - 7b. No aircraft plays another aircraft's engine

print()
print("Layer separation — what each class actually has running in cruise")
print(String(repeating: "-", count: 92))

func cruiseLayers(_ profile: VehicleAudioProfile, wingborneBlend: Float = 1.0) -> [AudioAssetID] {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .airborne
    input.rotorSpeedsRadPerSec = SIMD4<Float>(420.0, 0, 0, 0)
    input.engineShaftSpeedRadPerSec = profile.usesFuelEngine ? profile.referenceShaftSpeedRadPerSec : 0.0
    input.engineRunState = profile.usesFuelEngine ? .ready : nil
    input.forwardAirspeedMps = 30.0
    input.vtolWingborneBlend = wingborneBlend
    return runtime.update(profile: profile, input: input).layers.map(\.id)
}

let rotorLoops: Set<AudioAssetID> = [.uavSmallHover, .uavHeavyHoverLoop, .uavHexFlight,
                                    .fpvFlightLoop, .helicopterRotorLoop]
let electricLoops: Set<AudioAssetID> = rotorLoops.union([.fixedWingElectricMotor, .fixedWingPropellerLoop])
let fuelLoops: Set<AudioAssetID> = [.pistonEngineLoop, .turbopropLoop, .turbojetLoop]

for testCase in profileCases {
    let profile = VehicleAudioProfile.resolve(
        airframeClass: testCase.airframe,
        engineType: testCase.engine,
        rotorCount: testCase.rotors,
        takeoffMassKg: testCase.massKg,
        maxHorizontalSpeedMps: testCase.speed,
        ratedShaftRPM: testCase.engine == .turboprop ? 1_591.0 : nil,
        propellerBladeCount: 2,
        vehicleType: testCase.vehicle
    )
    let layers = cruiseLayers(profile)
    print(pad(testCase.label, 28) + layers.map(\.rawValue).joined(separator: " + "))

    // A fuel aircraft must not have a battery-powered rotor recording running underneath it,
    // and an electric one must not have an engine. This is the check that would have caught
    // the lift-rotor layer firing on every aeroplane.
    if profile.usesFuelEngine {
        let stray = layers.filter { electricLoops.contains($0) }
        check(stray.isEmpty, "\(testCase.label) plays electric rotor loops: \(stray.map(\.rawValue))")
    } else {
        let stray = layers.filter { fuelLoops.contains($0) }
        check(stray.isEmpty, "\(testCase.label) plays fuel engine loops: \(stray.map(\.rawValue))")
    }
    // One powerplant, whatever it is made of. An electric wing is allowed its motor and its
    // propeller as separate layers; nothing is allowed two powerplants.
    let rotorCount = layers.filter { rotorLoops.contains($0) }.count
    let fuelCount = layers.filter { fuelLoops.contains($0) }.count
    check(rotorCount <= 1, "\(testCase.label) runs \(rotorCount) rotor loops at once")
    check(fuelCount <= 1, "\(testCase.label) runs \(fuelCount) engine loops at once")
}

// A genuine VTOL is the one aircraft allowed two, and only while it is still on its rotors.
let vtolProfile = VehicleAudioProfile.resolve(
    airframeClass: .hybridVTOL, engineType: .electricMotor, rotorCount: 5,
    takeoffMassKg: 5.5, maxHorizontalSpeedMps: 26.0, ratedShaftRPM: nil, propellerBladeCount: 2
)
let hovering = cruiseLayers(vtolProfile, wingborneBlend: 0.0)
let cruising = cruiseLayers(vtolProfile, wingborneBlend: 1.0)
print("\nVTOL hovering: " + hovering.map(\.rawValue).joined(separator: " + "))
print("VTOL cruising: " + cruising.map(\.rawValue).joined(separator: " + "))
check(vtolProfile.liftRotorLoop != nil, "a hybrid VTOL has no lift-rotor voice")
check(hovering.contains { $0 == vtolProfile.liftRotorLoop }, "a hovering VTOL has no rotor sound")
check(!cruising.contains { $0 == vtolProfile.liftRotorLoop }, "a wingborne VTOL still runs its lift rotors")

// An electric aeroplane and a quadcopter must not be the same recording. They shared one for
// a while — the aeroplane borrowed the FPV loop — and the only thing separating them was a
// deliberately wrong reference speed. Now each has its own.
do {
    let planeProfile = VehicleAudioProfile.resolve(
        airframeClass: .fixedWing, engineType: .electricMotor, rotorCount: 1,
        takeoffMassKg: 3.5, maxHorizontalSpeedMps: 28.0, ratedShaftRPM: nil, propellerBladeCount: 2
    )
    let fpvProfile = VehicleAudioProfile.resolve(
        airframeClass: .multirotor, engineType: nil, rotorCount: 4,
        takeoffMassKg: 0.72, maxHorizontalSpeedMps: 32.0, ratedShaftRPM: nil, propellerBladeCount: 2
    )
    print("\nelectric aeroplane: "
          + [planeProfile.propulsionLoop, planeProfile.propellerLoop]
              .compactMap { $0?.rawValue }.joined(separator: " + "))
    print("racing quad:        " + (fpvProfile.propulsionLoop?.rawValue ?? "—"))
    check(planeProfile.propulsionLoop != fpvProfile.propulsionLoop,
          "an electric aeroplane and a racing quad still share a propulsion recording")
    check(planeProfile.propulsionLoop != quadProfile.propulsionLoop,
          "an electric aeroplane and a camera quad still share a propulsion recording")
    check(planeProfile.propellerLoop != nil,
          "an electric aeroplane has no propeller layer")
    // Every size of multirotor starts up differently, and each fuel class starts its own way.
    let heavyProfile = VehicleAudioProfile.resolve(
        airframeClass: .multirotor, engineType: nil, rotorCount: 6,
        takeoffMassKg: 12.0, maxHorizontalSpeedMps: 18.0, ratedShaftRPM: nil, propellerBladeCount: 2
    )
    let spinUps = Set([quadProfile.spinUpCue, fpvProfile.spinUpCue, heavyProfile.spinUpCue].compactMap { $0 })
    print("spin-up cues across camera quad, racing quad and heavy lifter: "
          + spinUps.map(\.rawValue).sorted().joined(separator: ", "))
    check(spinUps.count == 3, "two multirotor sizes share a spin-up cue")
}

// A helicopter must not be issued a multirotor's recording, and vice versa.
do {
    let heli = VehicleAudioProfile.resolve(
        airframeClass: .multirotor, engineType: nil, rotorCount: 2,
        takeoffMassKg: 57.0, maxHorizontalSpeedMps: 19.0, ratedShaftRPM: nil,
        propellerBladeCount: 3, vehicleType: .helicopter
    )
    let heavyQuad = VehicleAudioProfile.resolve(
        airframeClass: .multirotor, engineType: nil, rotorCount: 4,
        takeoffMassKg: 24.0, maxHorizontalSpeedMps: 18.0, ratedShaftRPM: nil,
        propellerBladeCount: 2, vehicleType: .multicopter
    )
    print("\nhelicopter:         " + (heli.propulsionLoop?.rawValue ?? "—"))
    print("heavy multirotor:   " + (heavyQuad.propulsionLoop?.rawValue ?? "—"))
    check(heli.audioClass == .helicopter, "a helicopter did not resolve to the rotorcraft class")
    check(heli.propulsionLoop != heavyQuad.propulsionLoop,
          "a helicopter and a heavy multirotor share a propulsion recording")
    // Without a catalogue entry it has to degrade to something, and that something is the
    // mass rule — stated here so the fallback is a decision rather than a surprise.
    let unknown = VehicleAudioProfile.resolve(
        airframeClass: .multirotor, engineType: nil, rotorCount: 2,
        takeoffMassKg: 57.0, maxHorizontalSpeedMps: 19.0, ratedShaftRPM: nil,
        propellerBladeCount: 3, vehicleType: nil
    )
    check(unknown.audioClass == .heavyMultirotor,
          "an aircraft with no catalogue entry no longer falls back to the mass rule")
}

// A plain aeroplane must never have one, whatever its powerplant.
for engine in [UAVEngineType.electricMotor, .pistonTwoStroke, .turboprop, .turbojet] {
    let plane = VehicleAudioProfile.resolve(
        airframeClass: .fixedWing, engineType: engine, rotorCount: 1,
        takeoffMassKg: 40.0, maxHorizontalSpeedMps: 60.0, ratedShaftRPM: 2_000.0, propellerBladeCount: 3
    )
    check(plane.liftRotorLoop == nil, "a fixed-wing \(engine.rawValue) was given lift rotors")
}
print("fixed wings carry no lift-rotor layer, whatever their engine: ok")

// A stopped engine is silent, however open the throttle is.
do {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.isArmed = true
    input.physicalState = .airborne
    input.engineRunState = .stopped
    input.engineShaftSpeedRadPerSec = 0.0
    // What the flight model actually writes for a fixed wing at full throttle.
    input.rotorSpeedsRadPerSec = SIMD4<Float>(600.0, 0, 0, 0)
    input.motorThrottle = 1.0
    let layers = runtime.update(profile: pistonProfile, input: input).layers.map(\.id)
    print("piston aircraft, engine stopped, throttle open: "
          + (layers.isEmpty ? "silent" : layers.map(\.rawValue).joined(separator: " + ")))
    check(
        !layers.contains(.pistonEngineLoop),
        "a stopped engine kept running because the throttle was open"
    )
}

// MARK: - 7c. The carrier aircraft is not silent

print()
print("Carrier aircraft")
print(String(repeating: "-", count: 92))
for kind in CarrierAircraftKind.allCases {
    print(pad(kind.rawValue, 10) + pad(kind.audioLoop.rawValue, 22)
          + String(format: "trim %+.1f dB, pitch %.2f", kind.audioTrimDb, kind.audioPitchRatio))
}
// Four turboprops and eight turbojets are not the same sound, and neither is silence.
check(CarrierAircraftKind.c130.audioLoop != CarrierAircraftKind.b52.audioLoop,
      "both carriers share one engine recording")
check(CarrierAircraftKind.b52.audioTrimDb > CarrierAircraftKind.c130.audioTrimDb,
      "a B-52 is not louder than a C-130")
// Both carrier loops must be things the pack can actually supply.
for kind in CarrierAircraftKind.allCases {
    check([AudioAssetID.turbopropLoop, .turbojetLoop].contains(kind.audioLoop),
          "\(kind.rawValue) asks for an engine loop outside the packed set")
}

// MARK: - 7d. Other aircraft in the air

print()
print("Other aircraft — wingmen and networked participants")
print(String(repeating: "-", count: 92))

let listenerHere = SIMD3<Float>(0, 2, 0)

func remoteSource(id: Int, distance: Float, running: Bool = true,
                  profile: VehicleAudioProfile? = nil,
                  shaft: Float? = nil,
                  velocity: SIMD3<Float> = .zero) -> RemoteVehicleAudioSource {
    RemoteVehicleAudioSource(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
        profile: profile ?? quadProfile,
        worldPosition: SIMD3<Float>(0, 2, -distance),
        worldVelocity: velocity,
        isRunning: running,
        shaftSpeedRadPerSec: shaft
    )
}

// Nearest first, disarmed dropped, far-away dropped, and never more than the budget.
let crowd = [
    remoteSource(id: 1, distance: 400),
    remoteSource(id: 2, distance: 40),
    remoteSource(id: 3, distance: 5_000),          // beyond hearing
    remoteSource(id: 4, distance: 90),
    remoteSource(id: 5, distance: 15, running: false),  // parked and disarmed
    remoteSource(id: 6, distance: 200),
    remoteSource(id: 7, distance: 250)
]
let chosen = RemoteVehicleAudio.select(crowd, listenerPosition: listenerHere)
print("seven aircraft nearby, chosen: "
      + chosen.map { String(format: "%.0f m", simd_distance($0.worldPosition, listenerHere)) }
              .joined(separator: ", "))
check(chosen.count <= RemoteVehicleAudio.maximumVoices, "more aircraft sounded than the voice budget allows")
check(!chosen.contains { !$0.isRunning }, "a disarmed aircraft was given a voice")
check(!chosen.contains { simd_distance($0.worldPosition, listenerHere) > RemoteVehicleAudio.maximumAudibleDistance },
      "an inaudibly distant aircraft was given a voice")
let distances = chosen.map { simd_distance($0.worldPosition, listenerHere) }
check(distances == distances.sorted(), "the nearest aircraft were not the ones chosen")

// Selection must be stable — a flickering choice is worse than a missing one.
let again = RemoteVehicleAudio.select(crowd.reversed(), listenerPosition: listenerHere)
check(chosen.map(\.id) == again.map(\.id), "the same crowd in a different order chose different aircraft")

// One voice each, never the local aircraft's full stack.
if let layer = RemoteVehicleAudio.layer(for: remoteSource(id: 2, distance: 40),
                                        listenerPosition: listenerHere,
                                        listenerVelocity: .zero, speedOfSoundMps: 343.0) {
    print(String(format: "one aircraft at 40 m: %@ at %.1f dB", layer.id.rawValue, layer.gainDb))
    check(layer.gainDb <= 0.0, "another aircraft asked for more than unity gain")
} else {
    check(false, "a running aircraft 40 m away produced no sound")
}

// A wingman's shaft speed is known exactly; a networked aircraft's is inferred and must stay
// inside a believable band rather than swinging with whatever speed arrives.
let inferredSlow = RemoteVehicleAudio.inferredShaftSpeed(profile: quadProfile, speedMps: 0.0)
let inferredFast = RemoteVehicleAudio.inferredShaftSpeed(profile: quadProfile, speedMps: 60.0)
print(String(format: "inferred shaft speed: %.0f rad/s hovering, %.0f rad/s at 60 m/s (reference %.0f)",
             inferredSlow, inferredFast, quadProfile.referenceShaftSpeedRadPerSec))
check(inferredFast > inferredSlow, "a faster aircraft is not working harder")
check(inferredSlow > quadProfile.referenceShaftSpeedRadPerSec * 0.5,
      "an airborne aircraft was inferred to be barely turning")
check(inferredFast < quadProfile.referenceShaftSpeedRadPerSec * 1.5,
      "the inferred speed swings further than a proxy should")

// Doppler still applies to other aircraft: one coming at the listener is sharper.
let approachingRemote = RemoteVehicleAudio.layer(
    for: remoteSource(id: 8, distance: 100, velocity: SIMD3<Float>(0, 0, 40)),
    listenerPosition: listenerHere, listenerVelocity: .zero, speedOfSoundMps: 343.0)
let recedingRemote = RemoteVehicleAudio.layer(
    for: remoteSource(id: 9, distance: 100, velocity: SIMD3<Float>(0, 0, -40)),
    listenerPosition: listenerHere, listenerVelocity: .zero, speedOfSoundMps: 343.0)
print(String(format: "another aircraft approaching: pitch %.2f, receding: %.2f",
             approachingRemote?.pitchRatio ?? 0, recedingRemote?.pitchRatio ?? 0))
check((approachingRemote?.pitchRatio ?? 0) > (recedingRemote?.pitchRatio ?? 0),
      "Doppler is not applied to other aircraft")

// MARK: - 7e. Somebody else's aircraft breaking

print()
print("Networked damage")
print(String(repeating: "-", count: 92))

// Severity has to come from what the wire actually carries. The local model reports a pair
// and subtracts; the snapshot carries only the value after.
let brokenSeverity = RemoteVehicleAudio.severity(integrity: 0.1, residualStrength: nil)
let scratchedSeverity = RemoteVehicleAudio.severity(integrity: 0.9, residualStrength: nil)
let jointSeverity = RemoteVehicleAudio.severity(integrity: nil, residualStrength: 0.2)
let silentSeverity = RemoteVehicleAudio.severity(integrity: nil, residualStrength: nil)
print(String(format: "integrity 0.1 → %.2f, integrity 0.9 → %.2f, residual 0.2 → %.2f, nothing → %.2f",
             brokenSeverity, scratchedSeverity, jointSeverity, silentSeverity))
check(brokenSeverity > scratchedSeverity, "a nearly destroyed part is not louder than a scratched one")
check(jointSeverity > 0.5, "a joint down to a fifth of its strength reads as minor")
check(silentSeverity > 0.0 && silentSeverity < 1.0, "an event with no numbers is not mid-scale")

// A remote impact resolves its surface from the same provenance string a local one does, so
// the two machines describe the same collision the same way.
for reason in ["world.building", "ground.field", "tree.canopy", "container.wall.left"] {
    let surface = AcousticSurfaceMaterial.fromObstacleSource(reason)
    let layers = ImpactAudioResolver.resolve(ImpactAudioEvent(
        worldPosition: .zero, surface: surface, vehicleMaterial: .aluminum,
        normalImpulse: 40.0, normalSpeed: 0.0, tangentialSpeed: 0.0,
        damageSeverity: 0.4, brokeSurface: false, isDetachedPart: false, seed: 77))
    print(pad(reason, 24) + pad("→ " + surface.rawValue, 14)
          + layers.map(\.id.rawValue).joined(separator: " + "))
    check(!layers.isEmpty, "a remote impact against \(reason) made no sound")
}

// The seed is the sender's sequence number, so both machines pick the same take.
let here = ImpactAudioResolver.resolveDamage(type: .componentDetached, material: .composite,
                                             severity: 0.8, seed: 4_242)
let there = ImpactAudioResolver.resolveDamage(type: .componentDetached, material: .composite,
                                              severity: 0.8, seed: 4_242)
check(here == there, "the same networked event resolves differently on two machines")
print("\nsame event id on two machines resolves identically: ok")

// A newly seen participant must not replay its history.
check(!RemoteVehicleAudio.shouldPlayOnFirstSight(),
      "an aircraft coming into range would replay its whole damage history")

// MARK: - 8. Servos move, they do not hum

print()
print("Control-surface servos")
print(String(repeating: "-", count: 92))

func servoCues(rate: Float, ticks: Int) -> Int {
    let runtime = VehicleAudioRuntime()
    var input = baseInput()
    input.deltaTime = 1.0 / 60.0
    var fired = 0
    for _ in 0..<ticks {
        input.controlSurfaceRate = rate
        fired += runtime.update(profile: pistonProfile, input: input)
            .cues.filter { $0.id == .mechanismServo }.count
    }
    return fired
}

let trimCues = servoCues(rate: 0.4, ticks: 60)
let sweepCues = servoCues(rate: 5.0, ticks: 60)
print("autopilot trimming for one second at 0.4 /s: \(trimCues) servo sounds")
print("a full stick sweep for one second at 5.0 /s: \(sweepCues) servo sounds")
check(trimCues == 0, "continuous autopilot trim produced servo chatter")
check(sweepCues >= 1, "a fast surface movement produced no servo sound")
check(sweepCues <= 6, "a one-second sweep produced more than six servo sounds")

// MARK: - Result

print()
print(String(repeating: "=", count: 92))
if failures.isEmpty {
    print("RESULT: PASS — profiles resolve from the machine's own numbers, pitch and level track "
          + "shaft speed, Doppler has the right sign and magnitude, the life cycle keeps power, "
          + "arming, spinning and flight distinct, airflow is gated on flight and scales with "
          + "speed and density, and damage is audible.")
} else {
    print("RESULT: FAIL — \(failures.count) problem(s)")
    for failure in failures {
        print("  • \(failure)")
    }
    exit(1)
}
