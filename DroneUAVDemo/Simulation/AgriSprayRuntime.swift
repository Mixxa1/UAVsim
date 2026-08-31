import Foundation
import simd

/// What the simulation should do with the tick's result.
struct AgriSprayTickResult: Equatable {
    /// Litres the refill station transferred into the tank this tick.
    var litersRefilled: Float = 0.0
    /// Set when a cell crossed the treated threshold this tick (worth a sound/HUD nudge).
    var didCompleteCells: Bool = false
}

/// Pure coverage logic for the agricultural spraying mission: a dose grid over the field, the
/// altitude/speed rules that decide how much of each drained litre actually reaches the crop, and
/// the refill station's state machine. No SceneKit, in the same spirit as `MissionScenarioRuntime`
/// and `FireResponseRuntime`.
///
/// Coverage is integrated along the *segment* the aircraft flew this tick, not sampled at its
/// current point. At 10 m/s a 60 Hz tick still moves 17 cm, but the simulation does not promise a
/// steady tick rate — a frame hitch at speed would punch an untreated hole straight across the
/// field, and the pilot would have no way to tell why.
struct AgriSprayRuntime {
    let configuration: MissionScenarioConfiguration
    let placement: AgriFieldPlacement
    let requiredDosePerCell: Float

    /// Litres absorbed by each cell, row-major (`y * cellsPerSide + x`).
    private(set) var doseByCell: [Float]
    private(set) var treatedCellCount: Int = 0
    /// Treated cells per sector, and how many cells each sector holds. The field is worked in
    /// blocks — a pilot finishes one part before moving on — so progress is accumulated the same
    /// way: each sector carries its own fill, and the mission's figure is the average of them.
    private(set) var treatedCellsBySector: [Int]
    private let cellsPerSector: Int
    let sectorsPerSide: Int
    private(set) var objectiveState: AgriSprayObjectiveState = .spraying
    private(set) var outcome: AgriSprayOutcome?
    private(set) var remainingSeconds: Double
    private(set) var elapsedSeconds: Double = 0.0
    private(set) var litersDelivered: Float = 0.0
    private(set) var litersWasted: Float = 0.0
    private(set) var refillState: AgriRefillState = .away
    private(set) var inhibitor: AgriSprayInhibitor = .none
    private(set) var currentSwathMeters: Float = 0.0
    private(set) var currentEfficiency: Float = 0.0
    /// Downwind offset between the aircraft and the ground its spray is treating.
    private(set) var currentDriftMeters: SIMD2<Float> = .zero
    private(set) var currentWindSpeed: Float = 0.0
    /// Bumped whenever the dose grid changed, so the scene layer can rebuild the field decal only
    /// when there is something new to show.
    private(set) var coverageRevision: UInt64 = 0
    /// Spray that left the tank over the field but whose swept strip did not reach a cell centre
    /// this tick; deposited on the next tick that does, together with the ground it covered.
    private var pendingLiters: Float = 0.0
    private var pendingTravelMeters: Float = 0.0

    init(configuration: MissionScenarioConfiguration, placement: AgriFieldPlacement) {
        self.configuration = configuration
        self.placement = placement
        self.remainingSeconds = configuration.parameters.timeLimitSeconds
        let cellArea = placement.cellMeters * placement.cellMeters
        self.requiredDosePerCell = AgriSprayTuning.requiredDoseLitersPerHectare * cellArea / 10_000.0
        self.doseByCell = [Float](repeating: 0.0, count: placement.cellCount)
        // Sectors must tile the cell grid exactly, or the edge sectors would be smaller and would
        // then count for more than their share of the field.
        let side = max(1, placement.cellsPerSide)
        let divisor = (2...6).reversed().first { side % $0 == 0 } ?? 1
        self.sectorsPerSide = divisor
        self.cellsPerSector = (side / divisor) * (side / divisor)
        self.treatedCellsBySector = [Int](repeating: 0, count: divisor * divisor)
    }

    var isActive: Bool { outcome == nil }

    /// Mission progress: the average of the sectors' own fills.
    ///
    /// With sectors that tile the grid exactly this is the same number as treated-cells over
    /// all-cells — deliberately so, since the balance was measured against that. What it buys is
    /// the per-sector figure underneath it, which is what a field is actually worked in.
    var coverageFraction: Float {
        guard cellsPerSector > 0, !treatedCellsBySector.isEmpty else { return 0.0 }
        let sum = treatedCellsBySector.reduce(Float(0.0)) { $0 + Float($1) / Float(cellsPerSector) }
        return sum / Float(treatedCellsBySector.count)
    }

    /// 0...1 fill of one sector, for anything that wants to reason about parts of the field.
    func sectorCoverage(x: Int, y: Int) -> Float {
        guard x >= 0, x < sectorsPerSide, y >= 0, y < sectorsPerSide, cellsPerSector > 0 else {
            return 0.0
        }
        return Float(treatedCellsBySector[y * sectorsPerSide + x]) / Float(cellsPerSector)
    }

    /// Which sector a cell index belongs to.
    private func sectorIndex(forCell index: Int) -> Int {
        let side = placement.cellsPerSide
        guard side > 0, sectorsPerSide > 0 else { return 0 }
        let cellsPerSectorSide = max(1, side / sectorsPerSide)
        let x = index % side
        let y = index / side
        let sx = min(sectorsPerSide - 1, x / cellsPerSectorSide)
        let sy = min(sectorsPerSide - 1, y / cellsPerSectorSide)
        return sy * sectorsPerSide + sx
    }

    var remainingClampedSeconds: Double { max(0.0, remainingSeconds) }

    /// 0...1 treated dose of a cell, for the field decal.
    func doseFraction(x: Int, y: Int) -> Float {
        guard x >= 0, x < placement.cellsPerSide, y >= 0, y < placement.cellsPerSide else { return 0.0 }
        return min(1.0, doseByCell[y * placement.cellsPerSide + x] / max(0.0001, requiredDosePerCell))
    }

    @discardableResult
    mutating func tick(
        deltaTime: Double,
        previousPosition: SIMD3<Float>,
        currentPosition: SIMD3<Float>,
        groundSpeed: Float,
        altitudeAGL: Float,
        windXZ: SIMD2<Float>,
        isSpraying: Bool,
        drainedLiters: Float,
        tankRemainingLiters: Float,
        tankCapacityLiters: Float
    ) -> AgriSprayTickResult {
        var result = AgriSprayTickResult()
        guard isActive, deltaTime > 0 else { return result }

        elapsedSeconds += deltaTime
        remainingSeconds -= deltaTime

        result.litersRefilled = updateRefill(
            deltaTime: deltaTime,
            position: currentPosition,
            groundSpeed: groundSpeed,
            altitudeAGL: altitudeAGL,
            tankRemainingLiters: tankRemainingLiters,
            tankCapacityLiters: tankCapacityLiters
        )

        currentSwathMeters = AgriSprayTuning.swathWidth(altitudeAGL: altitudeAGL)
        let altitudeEfficiency = AgriSprayTuning.altitudeEfficiency(altitudeAGL: altitudeAGL)
        let speedEfficiency = AgriSprayTuning.speedEfficiency(groundSpeed: groundSpeed)
        let windSpeed = simd_length(windXZ)
        let windEfficiency = AgriSprayTuning.windEfficiency(windSpeed: windSpeed)
        currentEfficiency = altitudeEfficiency * speedEfficiency * windEfficiency
        // Where this tick's spray will actually land, as opposed to where the aircraft is.
        currentDriftMeters = AgriSprayTuning.driftOffset(windXZ: windXZ, altitudeAGL: altitudeAGL)
        currentWindSpeed = windSpeed

        if drainedLiters > 0.0 {
            result.didCompleteCells = applySpray(
                previousPosition: previousPosition,
                currentPosition: currentPosition,
                drainedLiters: drainedLiters,
                efficiency: currentEfficiency
            )
        }

        inhibitor = resolveInhibitor(
            isSpraying: isSpraying,
            position: currentPosition,
            altitudeAGL: altitudeAGL,
            groundSpeed: groundSpeed,
            altitudeEfficiency: altitudeEfficiency,
            speedEfficiency: speedEfficiency,
            tankRemainingLiters: tankRemainingLiters
        )

        if coverageFraction >= AgriSprayTuning.successCoverageFraction {
            objectiveState = .complete
            outcome = .success(
                elapsedSeconds: elapsedSeconds,
                coverageFraction: coverageFraction,
                litersUsed: litersDelivered + litersWasted,
                litersWasted: litersWasted
            )
            return result
        }

        if remainingSeconds <= 0.0 {
            remainingSeconds = 0.0
            objectiveState = .failedTimeout
            outcome = .failureTimeout(coverageFraction: coverageFraction)
        }
        return result
    }

    mutating func abort() {
        guard isActive else { return }
        outcome = .aborted
    }

    // MARK: Spray application

    /// Spreads this tick's drained water over the ground swept by the boom, and returns whether
    /// any cell reached its required dose.
    private mutating func applySpray(
        previousPosition: SIMD3<Float>,
        currentPosition: SIMD3<Float>,
        drainedLiters: Float,
        efficiency: Float
    ) -> Bool {
        // The strip is laid where the droplets land, not under the aircraft: in wind the treated
        // rows are the ones downwind of the flight path, and the pilot has to fly upwind of the
        // row he means to treat. The offset is a world-space vector, so it is rotated into the
        // field's frame with the positions rather than added afterwards.
        let drift = currentDriftMeters
        let from = placement.worldToFieldLocal(
            SIMD2<Float>(previousPosition.x + drift.x, previousPosition.z + drift.y)
        )
        let to = placement.worldToFieldLocal(
            SIMD2<Float>(currentPosition.x + drift.x, currentPosition.z + drift.y)
        )
        let travelled = simd_distance(from, to)
        let halfSwath = currentSwathMeters * 0.5

        // Water that missed because of altitude or speed is spent, not saved.
        let effective = drainedLiters * max(0.0, min(1.0, efficiency))
        litersWasted += drainedLiters - effective
        // Carried-over spray from ticks whose swept strip fell between cell centres (see below),
        // together with the ground those ticks covered — carrying both keeps litres and area in
        // step, so the dose stays a real litres-per-hectare figure however the ticks fall.
        pendingLiters += effective
        pendingTravelMeters += travelled
        let deliverable = pendingLiters
        guard deliverable > 0.0 else { return false }

        // The ground treated this tick is the strip the boom swept: `currentSwathMeters` wide, as
        // long as the aircraft actually moved. Each cell's share is how much of it the strip
        // actually crossed, and the shares are normalised, so every drained litre is either
        // absorbed by a cell or explicitly counted as waste — no geometric fudge factor in
        // between. (Two earlier versions got this wrong in instructive ways: dosing a *disc*
        // while dividing by the area of a *strip* reported ~40% of the tank wasted on a textbook
        // pass, and a binary "is the cell centre inside this tick's window" test aliased against
        // the grid — at exactly 10 m/s one tick advances exactly a tenth of a cell, centres
        // landed on window boundaries, and a third of the field silently took no spray at all.)
        let sprayedCells = cellsSwept(from: from, to: to, travelled: travelled, halfSwath: halfSwath)
        guard !sprayedCells.isEmpty else {
            // Two very different reasons the strip can be empty, and they must not be confused.
            // Off the field: the crop gets nothing and the tank still pays. Over the field but
            // between cell centres — which is most ticks at a slow crawl, where one tick advances
            // a couple of centimetres across a 2 m grid — the spray is real and simply has not
            // reached a cell centre yet, so it is carried into the next tick instead of being
            // written off. Without this the model would have declared almost everything wasted at
            // low speed, punishing the most careful flying there is.
            let midpoint = (from + to) * 0.5
            let reach = placement.fieldHalfExtent + halfSwath
            if abs(midpoint.x) > reach || abs(midpoint.y) > reach {
                litersWasted += deliverable
                pendingLiters = 0.0
                pendingTravelMeters = 0.0
            }
            return false
        }

        pendingLiters = 0.0
        pendingTravelMeters = 0.0
        let totalWeight = sprayedCells.reduce(Float(0.0)) { $0 + $1.weight }
        guard totalWeight > 0.0 else {
            litersWasted += deliverable
            return false
        }

        var completedAny = false
        var appliedLiters: Float = 0.0
        for cell in sprayedCells {
            let dose = deliverable * cell.weight / totalWeight
            let before = doseByCell[cell.index]
            // Already treated — a second pass over the same rows is pure over-application.
            guard before < requiredDosePerCell else { continue }
            let applied = min(dose, requiredDosePerCell - before)
            doseByCell[cell.index] = before + applied
            appliedLiters += applied
            if doseByCell[cell.index] >= requiredDosePerCell {
                treatedCellCount += 1
                treatedCellsBySector[sectorIndex(forCell: cell.index)] += 1
                completedAny = true
            }
        }

        coverageRevision &+= 1
        litersDelivered += appliedLiters
        // Anything the crop could not take — over-application on treated rows, or the part of the
        // swath hanging over the headland — is wasted, and the pilot pays for it in refill trips.
        litersWasted += max(0.0, deliverable - appliedLiters)
        return completedAny
    }

    /// One cell touched by this tick's swept strip, weighted by how much of the cell the strip
    /// actually crossed.
    private struct SweptCell {
        var index: Int
        var weight: Float
    }

    /// Field cells the boom swept between two points (or, when the aircraft is hovering, the
    /// swath-wide patch under it), each weighted by its overlap with the strip.
    ///
    /// The weight is a *length*, not a yes/no: as the strip slides forward, a cell's share grows
    /// and shrinks continuously, so a cell's total dose over a pass depends only on the swath and
    /// the ground speed — never on where the tick boundaries happened to fall relative to the
    /// grid. That is what makes the model immune to the tick-rate aliasing that a binary
    /// inside/outside test suffers from.
    private func cellsSwept(
        from: SIMD2<Float>,
        to: SIMD2<Float>,
        travelled: Float,
        halfSwath: Float
    ) -> [SweptCell] {
        let half = placement.fieldHalfExtent
        let size = placement.cellMeters
        let isHovering = travelled < 0.02
        let direction = isHovering ? SIMD2<Float>(1, 0) : (to - from) / travelled

        let minCorner = SIMD2<Float>(min(from.x, to.x), min(from.y, to.y)) - SIMD2<Float>(repeating: halfSwath)
        let maxCorner = SIMD2<Float>(max(from.x, to.x), max(from.y, to.y)) + SIMD2<Float>(repeating: halfSwath)
        let minX = Int(floor((minCorner.x + half) / size))
        let maxX = Int(floor((maxCorner.x + half) / size))
        let minY = Int(floor((minCorner.y + half) / size))
        let maxY = Int(floor((maxCorner.y + half) / size))
        guard maxX >= 0, maxY >= 0, minX < placement.cellsPerSide, minY < placement.cellsPerSide else {
            return []
        }

        // Half the cell's extent along the flight direction: the projection of a square onto an
        // arbitrary axis, so a diagonal pass weights cells as generously as it should.
        let cellAlongHalf = 0.5 * size * (abs(direction.x) + abs(direction.y))

        var result: [SweptCell] = []
        for y in max(0, minY)...min(placement.cellsPerSide - 1, maxY) {
            for x in max(0, minX)...min(placement.cellsPerSide - 1, maxX) {
                let centre = placement.cellCenterLocal(x: x, y: y)
                let offset = centre - from
                let index = y * placement.cellsPerSide + x
                if isHovering {
                    if simd_length_squared(offset) <= halfSwath * halfSwath {
                        result.append(SweptCell(index: index, weight: 1.0))
                    }
                    continue
                }
                let along = simd_dot(offset, direction)
                let perpendicular = simd_length(offset - direction * along)
                guard perpendicular <= halfSwath else { continue }
                let overlap = min(travelled, along + cellAlongHalf) - max(0.0, along - cellAlongHalf)
                guard overlap > 0.0 else { continue }
                result.append(SweptCell(index: index, weight: overlap))
            }
        }
        return result
    }

    // MARK: Refill

    private mutating func updateRefill(
        deltaTime: Double,
        position: SIMD3<Float>,
        groundSpeed: Float,
        altitudeAGL: Float,
        tankRemainingLiters: Float,
        tankCapacityLiters: Float
    ) -> Float {
        let planar = SIMD2<Float>(position.x, position.z)
        let distance = simd_distance(planar, placement.stationPosition)
        guard distance <= AgriSprayTuning.refillRadiusMeters else {
            refillState = .away
            return 0.0
        }
        guard altitudeAGL <= AgriSprayTuning.refillMaxAltitudeMeters,
              groundSpeed <= AgriSprayTuning.refillMaxGroundSpeed else {
            refillState = .inRangeUnstable
            return 0.0
        }
        let missing = max(0.0, tankCapacityLiters - tankRemainingLiters)
        guard missing > 0.001 else {
            refillState = .full
            return 0.0
        }
        let transferred = min(missing, AgriSprayTuning.refillLitersPerSecond * Float(deltaTime))
        let newLevel = tankRemainingLiters + transferred
        refillState = .filling(progress: min(1.0, newLevel / max(0.001, tankCapacityLiters)))
        return transferred
    }

    // MARK: Diagnostics for the HUD

    private func resolveInhibitor(
        isSpraying: Bool,
        position: SIMD3<Float>,
        altitudeAGL: Float,
        groundSpeed: Float,
        altitudeEfficiency: Float,
        speedEfficiency: Float,
        tankRemainingLiters: Float
    ) -> AgriSprayInhibitor {
        guard isSpraying else { return .none }
        if tankRemainingLiters <= 0.001 {
            return .tankEmpty
        }
        if placement.cellIndex(forWorldPosition: SIMD2<Float>(position.x, position.z)) == nil {
            return .offField
        }
        if speedEfficiency < 1.0 {
            return .tooFast
        }
        if currentWindSpeed > AgriSprayTuning.calmWindMps * 2.0 {
            return .windy
        }
        if altitudeAGL > AgriSprayTuning.idealAltitudeRange.upperBound {
            return .tooHigh
        }
        if altitudeAGL < AgriSprayTuning.idealAltitudeRange.lowerBound {
            return .tooLow
        }
        return .none
    }
}
