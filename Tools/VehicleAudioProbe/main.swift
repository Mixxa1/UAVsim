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
    .init(label: "battery VTOL", airframe: .hybridVTOL, engine: nil, rotors: 5, massKg: 5.5, speed: 26.0, expected: .electricFixedWing)
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
        propellerBladeCount: 2
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
    if let airflow = plan.layers.first(where: { $0.id == .airflowSynthetic }) {
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
        !plan.layers.contains { $0.id == .airflowSynthetic },
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
            .layers.first { $0.id == .airflowSynthetic }?.gainDb ?? 0.0
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
        propellerBladeCount: 2
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

let electricLoops: Set<AudioAssetID> = [.uavSmallHover, .uavHeavyHoverLoop, .uavHexFlight, .fpvFlightLoop]
let fuelLoops: Set<AudioAssetID> = [.pistonEngineLoop, .turbopropLoop, .turbojetLoop]

for testCase in profileCases {
    let profile = VehicleAudioProfile.resolve(
        airframeClass: testCase.airframe,
        engineType: testCase.engine,
        rotorCount: testCase.rotors,
        takeoffMassKg: testCase.massKg,
        maxHorizontalSpeedMps: testCase.speed,
        ratedShaftRPM: testCase.engine == .turboprop ? 1_591.0 : nil,
        propellerBladeCount: 2
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
    // Whatever it is, it has exactly one propulsion voice.
    let propulsionCount = layers.filter { electricLoops.contains($0) || fuelLoops.contains($0) }.count
    check(propulsionCount <= 1, "\(testCase.label) runs \(propulsionCount) propulsion loops at once")
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

// Two classes sharing a stand-in clip must at least not be the same sound. An electric
// aeroplane turns one big propeller slowly; a racing quad turns four small ones fast.
do {
    func cruisePitch(_ profile: VehicleAudioProfile, laneSpeed: Float) -> Float {
        let runtime = VehicleAudioRuntime()
        var input = baseInput()
        input.isArmed = true
        input.physicalState = .airborne
        input.rotorSpeedsRadPerSec = SIMD4<Float>(repeating: laneSpeed)
        return runtime.update(profile: profile, input: input)
            .layers.first { $0.id == profile.propulsionLoop }?.pitchRatio ?? 0.0
    }
    let planeProfile = VehicleAudioProfile.resolve(
        airframeClass: .fixedWing, engineType: .electricMotor, rotorCount: 1,
        takeoffMassKg: 3.5, maxHorizontalSpeedMps: 28.0, ratedShaftRPM: nil, propellerBladeCount: 2
    )
    // Each at its own cruise: the fixed-wing lane runs 60 + 540·throttle, the quad lanes
    // 120 + 640·thrustFraction.
    let planePitch = cruisePitch(planeProfile, laneSpeed: 357.0)
    let quadPitch = cruisePitch(quadProfile, laneSpeed: 440.0)
    print(String(format: "\nsame stand-in clip: electric aeroplane at pitch %.2f, camera quad at %.2f",
                 planePitch, quadPitch))
    check(
        abs(planePitch - quadPitch) > 0.15,
        "an electric aeroplane and a quadcopter play the shared clip at the same pitch"
    )
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
