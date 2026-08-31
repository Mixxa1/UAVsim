import Foundation
import simd

// Headless check of the racing scoring rules.
//
// Generates a track, then flies four different runs through it and reports what the runtime made
// of each: a clean lap, a lap flown far too fast for a proximity test to survive, a run that
// skips a gate, and a gate taken backwards. The gate-crossing maths is the one part of a race
// that is invisible when it is subtly wrong — a pass that does not score, or a gate that scores
// when the aircraft went past it — so it gets checked here rather than in flight.
//
// Usage: Tools/RaceGateProbe/run.sh [speed] [tickHz]

let arguments = Array(CommandLine.arguments.dropFirst())
let speed = Float(arguments.first.flatMap { Float($0) } ?? 22.0)
let tickHz = Double(arguments.dropFirst().first.flatMap { Double($0) } ?? 60.0)
let dt = 1.0 / tickHz

let track = RaceTrackGenerator.generate(
    parameters: RaceTrackGenerator.Parameters.forDifficulty(.medium, seed: 20_260_831),
    worldHalfExtent: 800.0
)
let gates = track.gateGeometry

print("=== Race gate probe ===")
print("track '\(track.name)': \(track.gateCount) gates, lap \(String(format: "%.0f", track.lapLengthMeters)) m, \(track.laps) laps")
print(String(format: "flying at %.0f m/s, %.0f Hz — %.2f m of travel per tick", speed, tickHz, Double(speed) * dt))
print("")

/// Flies straight from point to point through the runtime, reporting every event.
func fly(
    runtime: inout RaceRuntime,
    through points: [SIMD3<Float>],
    label: String
) {
    var position = points.first ?? .zero
    var log: [String] = []
    for target in points.dropFirst() {
        let leg = target - position
        let distance = simd_length(leg)
        guard distance > 0.001 else { continue }
        let direction = leg / distance
        var travelled: Float = 0.0
        while travelled < distance {
            let step = min(speed * Float(dt), distance - travelled)
            let next = position + direction * step
            runtime.tick(deltaTime: dt, previousPosition: position, currentPosition: next)
            position = next
            travelled += step
            for event in runtime.drainEvents() {
                switch event {
                case .started:
                    log.append("start")
                case let .gatePassed(order, elapsed):
                    log.append(String(format: "gate %d @ %.2fs", order + 1, elapsed))
                case let .gateWrongWay(order):
                    log.append("gate \(order + 1) WRONG WAY")
                case let .lapCompleted(lap, seconds, isBest):
                    log.append(String(format: "lap %d in %.2fs%@", lap, seconds, isBest ? " (best)" : ""))
                case let .raceFinished(total, best):
                    log.append(String(format: "FINISH total %.2fs, best lap %.2fs", total, best))
                case .countdownTick:
                    break
                }
            }
        }
    }
    print("--- \(label) ---")
    print(log.isEmpty ? "(no events)" : log.joined(separator: " | "))
    print("")
}

/// The line through a gate: a point on the approach side, the aperture centre, and a point beyond.
func line(through gate: RaceGateGeometry, backOff: Float = 6.0) -> [SIMD3<Float>] {
    [
        gate.centre - gate.normal * backOff,
        gate.centre + gate.normal * backOff
    ]
}

// 1. A clean run: every gate in order, for the full race distance.
var cleanPoints: [SIMD3<Float>] = []
for _ in 0..<track.laps {
    for gate in gates {
        cleanPoints.append(contentsOf: line(through: gate))
    }
}
if let first = gates.first {
    cleanPoints.append(contentsOf: line(through: first))
}
var cleanRuntime = RaceRuntime(mode: .timed, lapCount: track.laps, gates: gates)
fly(runtime: &cleanRuntime, through: cleanPoints, label: "clean run at \(Int(speed)) m/s")

// 2. The same line at a frame rate low enough that one tick jumps clean through a gate — the
//    case a proximity test cannot survive.
var coarseRuntime = RaceRuntime(mode: .timed, lapCount: 1, gates: gates)
let coarseDt = 1.0 / 12.0
do {
    var position = cleanPoints.first ?? .zero
    var passes = 0
    for target in cleanPoints.dropFirst() {
        let leg = target - position
        let distance = simd_length(leg)
        guard distance > 0.001 else { continue }
        let direction = leg / distance
        var travelled: Float = 0.0
        while travelled < distance {
            let step = min(speed * Float(coarseDt), distance - travelled)
            let next = position + direction * step
            coarseRuntime.tick(deltaTime: coarseDt, previousPosition: position, currentPosition: next)
            position = next
            travelled += step
            for event in coarseRuntime.drainEvents() {
                if case .gatePassed = event { passes += 1 }
            }
        }
    }
    print("--- 12 Hz run (\(String(format: "%.1f", Double(speed) * coarseDt)) m per tick) ---")
    print("gates scored: \(passes) of \(gates.count) — lap \(coarseRuntime.currentLap), state \(coarseRuntime.objectiveState.rawValue)")
    print("")
}

// 3. Skipping a gate: the pilot flies past gate 3 and carries on.
var skipRuntime = RaceRuntime(mode: .timed, lapCount: 1, gates: gates)
var skipPoints: [SIMD3<Float>] = []
for (index, gate) in gates.enumerated() where index != 2 {
    skipPoints.append(contentsOf: line(through: gate))
}
fly(runtime: &skipRuntime, through: skipPoints, label: "run that skips gate 3")
print("after skipping: next gate is \(skipRuntime.nextGateOrder.map { $0 + 1 } ?? -1), lap \(skipRuntime.currentLap)")
print("")

// 4. Taking the first gate backwards.
var reverseRuntime = RaceRuntime(mode: .timed, lapCount: 1, gates: gates)
if let first = gates.first {
    let reversed = Array(line(through: first).reversed())
    fly(runtime: &reverseRuntime, through: reversed, label: "gate 1 taken backwards")
}

// 5. Flying past a gate rather than through it: 3 m off to the side of the opening.
var pastRuntime = RaceRuntime(mode: .timed, lapCount: 1, gates: gates)
if let first = gates.first {
    let sideStep = first.lateral * (first.halfWidth + 2.5)
    let pastPoints = [
        first.centre - first.normal * 8.0 + sideStep,
        first.centre + first.normal * 8.0 + sideStep
    ]
    fly(runtime: &pastRuntime, through: pastPoints, label: "flying past gate 1, \(String(format: "%.1f", first.halfWidth + 2.5)) m off centre")
}
