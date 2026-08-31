import Foundation
import simd

// Headless check of the agricultural spraying mission's economy.
//
// Flies a textbook boustrophedon pattern over each difficulty's field at the reference altitude
// and speed, draining and refilling exactly the way the simulation does, and reports what a
// clean run actually costs: time, water, refill trips. The point is to catch a mission that
// cannot be finished inside its own time limit, or a coverage grid that leaves permanent gaps,
// before either has to be discovered in flight.
//
// Usage: Tools/AgriCoverageProbe/run.sh [altitude] [speed]

let arguments = Array(CommandLine.arguments.dropFirst())
let flightAltitude = Float(arguments.first.flatMap { Float($0) } ?? 3.5)
let flightSpeed = Float(arguments.dropFirst().first.flatMap { Float($0) } ?? 8.0)
/// Crosswind, in metres per second, blowing along +X. Spray drifts downwind by the time it takes
/// a droplet to fall, so this is the third lever a real operator has to think about.
let windSpeed = Float(arguments.dropFirst(2).first.flatMap { Float($0) } ?? 0.0)

let dt = 1.0 / 50.0
let tankCapacity = AgriculturalSprayerTuning.tankCapacityLiters
let drainRate = AgriculturalSprayerTuning.drainRateLitersPerSecond

print("=== Agricultural spraying probe ===")
print(String(format: "wind %.1f m/s — drift %.1f m at the flight altitude",
             windSpeed, simd_length(AgriSprayTuning.driftOffset(windXZ: SIMD2<Float>(windSpeed, 0), altitudeAGL: flightAltitude))))
print(String(format: "altitude %.1f m, ground speed %.1f m/s, swath %.2f m, efficiency %.2f",
             flightAltitude, flightSpeed,
             AgriSprayTuning.swathWidth(altitudeAGL: flightAltitude),
             AgriSprayTuning.altitudeEfficiency(altitudeAGL: flightAltitude)
                * AgriSprayTuning.speedEfficiency(groundSpeed: flightSpeed)))
print(String(format: "tank %.0f L, drain %.2f L/s, required dose %.0f L/ha, success at %.0f%%",
             tankCapacity, drainRate,
             AgriSprayTuning.requiredDoseLitersPerHectare,
             AgriSprayTuning.successCoverageFraction * 100.0))
print("")

for difficulty in MissionDifficulty.allCases {
    let parameters = MissionScenarioParameters(
        kind: .agriculturalSpraying,
        difficulty: difficulty,
        timeLimitMinutes: difficulty.agriDefaultTimeLimitMinutes,
        seed: 20_260_831
    )
    let configuration = MissionScenarioConfiguration(
        parameters: parameters,
        selectedUAVProfileID: "agrowing-titan-at40",
        payloadType: .agriculturalSprayer
    )
    let placement = AgriFieldPlacement.generate(
        parameters: parameters,
        worldHalfExtent: difficulty.recommendedMapScale.worldHalfExtentMeters,
        dockPosition: SIMD2<Float>(0, 0)
    )
    var runtime = AgriSprayRuntime(configuration: configuration, placement: placement)

    var tank = tankCapacity
    var elapsed = 0.0
    var refillTrips = 0
    var transitSeconds = 0.0

    let half = placement.fieldHalfExtent
    let swath = AgriSprayTuning.swathWidth(altitudeAGL: flightAltitude)
    // Rows are laid one swath apart: the pattern a real operator would fly, with no deliberate
    // overlap, so any coverage shortfall here is the model's, not the pilot's.
    var rowIndex = 0
    var alongForward = true
    var position = SIMD2<Float>(-half, -half + swath * 0.5)
    var previousWorld = SIMD3<Float>(0, flightAltitude, 0)
    var didSeedPrevious = false

    func worldPosition(_ local: SIMD2<Float>) -> SIMD3<Float> {
        let world = placement.fieldLocalToWorld(local)
        return SIMD3<Float>(world.x, flightAltitude, world.y)
    }

    // Fly rows until the field is done, the clock runs out, or the pattern is exhausted.
    rowLoop: while runtime.isActive {
        let rowY = -half + swath * 0.5 + Float(rowIndex) * swath
        if rowY > half + swath {
            break
        }
        position = SIMD2<Float>(alongForward ? -half : half, rowY)

        while runtime.isActive {
            // Refill trip when the tank runs dry: fly to the canisters, fill, fly back. Charged
            // as real time, which is what the difficulty's time budget has to absorb.
            if tank <= 0.001 {
                let fieldWorld = placement.fieldLocalToWorld(position)
                let legDistance = simd_distance(fieldWorld, placement.stationPosition)
                let legSeconds = Double(legDistance / max(1.0, flightSpeed)) * 2.0
                let fillSeconds = Double(tankCapacity / AgriSprayTuning.refillLitersPerSecond)
                elapsed += legSeconds + fillSeconds
                transitSeconds += legSeconds + fillSeconds
                tank = tankCapacity
                refillTrips += 1
                didSeedPrevious = false
                if elapsed >= parameters.timeLimitSeconds { break rowLoop }
                continue
            }

            let step = flightSpeed * Float(dt)
            let advance = alongForward ? step : -step
            let next = SIMD2<Float>(position.x + advance, position.y)
            let world = worldPosition(next)
            if !didSeedPrevious {
                previousWorld = worldPosition(position)
                didSeedPrevious = true
            }

            let drained = min(tank, drainRate * Float(dt))
            tank -= drained

            _ = runtime.tick(
                deltaTime: dt,
                previousPosition: previousWorld,
                currentPosition: world,
                groundSpeed: flightSpeed,
                altitudeAGL: flightAltitude,
                windXZ: SIMD2<Float>(windSpeed, 0.0),
                isSpraying: true,
                drainedLiters: drained,
                tankRemainingLiters: tank,
                tankCapacityLiters: tankCapacity
            )
            previousWorld = world
            position = next
            elapsed += dt

            if alongForward ? (position.x >= half) : (position.x <= -half) {
                break
            }
        }

        // Headland turn outside the crop, no spray.
        elapsed += 4.0
        transitSeconds += 4.0
        didSeedPrevious = false
        rowIndex += 1
        alongForward.toggle()
    }

    let used = runtime.litersDelivered + runtime.litersWasted
    let status: String
    switch runtime.outcome {
    case .success:
        status = "COMPLETE"
    case .failureTimeout:
        status = "TIMED OUT"
    default:
        status = runtime.coverageFraction >= AgriSprayTuning.successCoverageFraction
            ? "COMPLETE"
            : "PATTERN EXHAUSTED"
    }

    print("--- \(difficulty.rawValue) ---")
    print(String(format: "field %.0f x %.0f m (%.2f ha), %d x %d cells of %.2f m",
                 placement.fieldHalfExtent * 2, placement.fieldHalfExtent * 2,
                 placement.areaHectares, placement.cellsPerSide, placement.cellsPerSide,
                 placement.cellMeters))
    print(String(format: "station %.0f m from field centre",
                 simd_distance(placement.stationPosition, placement.fieldCenter)))
    print(String(format: "result: %@ — coverage %.1f%% after %.1f min (limit %d min)",
                 status, runtime.coverageFraction * 100.0, elapsed / 60.0,
                 parameters.timeLimitMinutes))
    print(String(format: "water: %.1f L used (%.1f delivered, %.1f wasted), %d refill trips, planned %d tanks",
                 used, runtime.litersDelivered, runtime.litersWasted,
                 refillTrips, difficulty.agriTankLoads))
    print(String(format: "time split: %.1f min spraying, %.1f min transit/refill",
                 (elapsed - transitSeconds) / 60.0, transitSeconds / 60.0))
    // Where the untreated cells sit: a per-row profile makes a systematic gap (a swath the
    // pattern never reached, or a dose that lands just short) obvious at a glance.
    var untreatedByRow: [Int] = []
    var worstPartial: Float = 1.0
    for y in 0..<placement.cellsPerSide {
        var untreated = 0
        for x in 0..<placement.cellsPerSide {
            let fraction = runtime.doseFraction(x: x, y: y)
            if fraction < 1.0 {
                untreated += 1
                worstPartial = min(worstPartial, fraction)
            }
        }
        untreatedByRow.append(untreated)
    }
    let profile = untreatedByRow.map { String($0) }.joined(separator: " ")
    print("untreated cells per row: \(profile)")
    print(String(format: "lowest partial dose among untreated cells: %.2f", worstPartial))
    print("")
}
