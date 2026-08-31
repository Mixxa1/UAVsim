import Foundation
import simd

// MARK: - Tuning

/// Physical rules of aerial crop spraying, in one place.
///
/// The numbers are tied to each other rather than picked independently, and the anchor is the
/// sprayer hardware that already exists: `AgriculturalSprayerTuning` drains 0.55 L/s from a 44 L
/// tank. Flying the reference pass — 3.5 m above the crop at 8 m/s, which opens a 7.7 m swath —
/// therefore lays down 0.55 / (7.7 × 8) ≈ 89 litres per hectare. `requiredDoseLitersPerHectare`
/// is set well under that (55 L/ha) so the reference pass has real margin: a pilot flying a
/// little fast or a little high still treats the ground he covers, and only a pass that is
/// clearly wrong leaves the crop under-dosed and forces a second run over the same rows.
///
/// The altitude window is what stops the mission degrading into "climb to 100 m and hold the
/// trigger". Real spray drones work at 2-4 m over the canopy for a reason: too high and the mist
/// drifts before it settles, too low and rotor wash throws it sideways. Both failures are
/// modelled as an efficiency multiplier on the *delivered* dose, never on the tank drain — water
/// sprayed from the wrong height is still gone, which is exactly what makes the altitude matter.
enum AgriSprayTuning {
    /// Litres per hectare a cell must receive before it counts as treated.
    static let requiredDoseLitersPerHectare: Float = 55.0

    /// Coverage grid resolution. 2 m cells are fine enough that a missed row is visible on the
    /// field decal and coarse enough that even the largest field stays a few thousand cells.
    static let coverageCellMeters: Float = 2.0

    /// Fraction of the field that must be treated for the mission to succeed. Not 100%: with a
    /// 2 m grid a single ragged edge cell would otherwise sink an otherwise clean job.
    static let successCoverageFraction: Float = 0.95

    // Altitude window (metres above ground, measured to the airframe).
    static let idealAltitudeRange: ClosedRange<Float> = 2.0...5.0
    static let washAltitudeMeters: Float = 1.0
    static let driftCutoffAltitudeMeters: Float = 8.0
    /// Delivery efficiency below `washAltitudeMeters`, where rotor wash scatters the mist.
    static let washEfficiency: Float = 0.5

    // Swath: the boom's own width is fixed, but the mist cone spreads with height, so the treated
    // strip widens as the aircraft climbs — the trade the altitude window makes interesting.
    static let swathWidthPerAltitude: Float = 2.2
    static let minSwathMeters: Float = 3.0
    static let maxSwathMeters: Float = 9.0

    // Ground speed. Droplets need time to settle; past the cutoff the pass simply doesn't take.
    static let idealMaxGroundSpeed: Float = 10.0
    static let speedCutoffGroundSpeed: Float = 16.0

    // Wind. Spray drift is the profession's signature problem: a droplet takes about
    // `dropletSettlingSpeed` to reach the crop, and everything the wind does to it during that
    // fall lands somewhere other than where the aircraft was. Flying lower shortens the fall and
    // is the only real defence, which is exactly the trade a real operator makes.
    static let dropletSettlingSpeedMps: Float = 2.5
    /// Wind below this is a non-event.
    static let calmWindMps: Float = 2.0
    /// Above this the spray is unusable however low you fly.
    static let windCutoffMps: Float = 12.0
    /// Worst-case efficiency loss to atomisation at the cutoff (drift is modelled separately, by
    /// actually moving the treated strip).
    static let windEfficiencyFloor: Float = 0.25

    // Refill station.
    static let refillRadiusMeters: Float = 8.0
    static let refillMaxAltitudeMeters: Float = 4.0
    static let refillMaxGroundSpeed: Float = 1.5
    static let refillLitersPerSecond: Float = 2.0

    /// Delivered-dose multiplier for the current altitude above ground.
    static func altitudeEfficiency(altitudeAGL: Float) -> Float {
        if altitudeAGL < 0.0 {
            return 0.0
        }
        if altitudeAGL < washAltitudeMeters {
            return washEfficiency
        }
        if altitudeAGL < idealAltitudeRange.lowerBound {
            let t = (altitudeAGL - washAltitudeMeters) / max(0.001, idealAltitudeRange.lowerBound - washAltitudeMeters)
            return washEfficiency + (1.0 - washEfficiency) * t
        }
        if altitudeAGL <= idealAltitudeRange.upperBound {
            return 1.0
        }
        if altitudeAGL >= driftCutoffAltitudeMeters {
            return 0.0
        }
        let t = (altitudeAGL - idealAltitudeRange.upperBound)
            / max(0.001, driftCutoffAltitudeMeters - idealAltitudeRange.upperBound)
        return 1.0 - t
    }

    /// Delivered-dose multiplier for the current ground speed.
    static func speedEfficiency(groundSpeed: Float) -> Float {
        if groundSpeed <= idealMaxGroundSpeed {
            return 1.0
        }
        if groundSpeed >= speedCutoffGroundSpeed {
            return 0.0
        }
        let t = (groundSpeed - idealMaxGroundSpeed) / max(0.001, speedCutoffGroundSpeed - idealMaxGroundSpeed)
        return 1.0 - t
    }

    /// Delivered-dose multiplier for the wind: some of the mist is simply lost to the air.
    static func windEfficiency(windSpeed: Float) -> Float {
        guard windSpeed > calmWindMps else { return 1.0 }
        if windSpeed >= windCutoffMps { return windEfficiencyFloor }
        let t = (windSpeed - calmWindMps) / max(0.001, windCutoffMps - calmWindMps)
        return 1.0 - (1.0 - windEfficiencyFloor) * t
    }

    /// How far downwind the spray lands from where it was released.
    static func driftOffset(windXZ: SIMD2<Float>, altitudeAGL: Float) -> SIMD2<Float> {
        let fallSeconds = max(0.0, altitudeAGL) / dropletSettlingSpeedMps
        return windXZ * fallSeconds
    }

    static func swathWidth(altitudeAGL: Float) -> Float {
        min(maxSwathMeters, max(minSwathMeters, altitudeAGL * swathWidthPerAltitude))
    }

    /// Litres one grid cell must absorb to count as treated.
    static var requiredDoseLitersPerCell: Float {
        let cellArea = coverageCellMeters * coverageCellMeters
        return requiredDoseLitersPerHectare * cellArea / 10_000.0
    }
}

// MARK: - Difficulty scaling

extension MissionDifficulty {
    /// Side of the (square) treated sector. Sized against the tank: at 55 L/ha a full 44 L tank
    /// treats about 0.8 ha in ideal conditions, and realistically nearer 0.55 ha once turns and
    /// overlap are paid for — so easy is a single tank, medium about three, hard about five.
    var agriFieldSideMeters: Float {
        switch self {
        case .easy:
            return 70.0     // ≈ 0.49 ha
        case .medium:
            return 110.0    // ≈ 1.21 ha
        case .hard:
            return 160.0    // ≈ 2.56 ha
        }
    }

    var agriFieldAreaHectares: Float {
        let side = agriFieldSideMeters
        return side * side / 10_000.0
    }

    /// Water budget the field needs at the reference dose, before any waste.
    var agriRequiredLiters: Float {
        agriFieldAreaHectares * AgriSprayTuning.requiredDoseLitersPerHectare
    }

    /// Full tanks the field needs at the reference dose (rounded up); one less than this is the
    /// number of refill trips a perfectly flown mission costs.
    var agriTankLoads: Int {
        max(1, Int(ceil(agriRequiredLiters / AgriculturalSprayerTuning.tankCapacityLiters)))
    }

    /// How far off the edge of the field the canisters sit. The refill trip *is* the mission's
    /// difficulty: a station at the field's edge would make running dry free, and the whole point
    /// of a finite tank is that going back for more costs flying time.
    var agriStationStandoffMeters: Float {
        switch self {
        case .easy:
            return 45.0
        case .medium:
            return 75.0
        case .hard:
            return 110.0
        }
    }

    /// Time budget. Generous by design: the mission's pressure is the water logistics, not the
    /// clock, and a hard field is five tank loads of flying plus the trips back to the station.
    var agriDefaultTimeLimitMinutes: Int {
        switch self {
        case .easy:
            return 10
        case .medium:
            return 18
        case .hard:
            return 30
        }
    }

    /// Crop density on the field, in clumps per square metre.
    ///
    /// A wheat clump is a four-quad billboard — sixteen vertices — and a whole 16 m tile of them
    /// merges into a single geometry, so the cost of density is vertices, not draw calls. At five
    /// clumps per square metre the crop closes up into an actual field rather than reading as
    /// scattered tufts: the largest field is about 128,000 clumps, two million vertices across a
    /// hundred batched tiles, none of which casts a shadow. Density steps down with field size
    /// only to keep the total near that budget.
    var agriCropDensityPerSquareMeter: Float {
        switch self {
        case .easy:
            return 8.0
        case .medium:
            return 6.5
        case .hard:
            return 5.0
        }
    }
}

// MARK: - Placement

/// Where the field and its refill station sit, derived deterministically from the mission seed.
struct AgriFieldPlacement: Equatable {
    var fieldCenter: SIMD2<Float>
    var fieldHalfExtent: Float
    /// Heading of the crop rows; the field is axis-aligned in its own frame and rotated by this.
    var rowHeadingRadians: Float
    var stationPosition: SIMD2<Float>
    var cellsPerSide: Int

    var cellMeters: Float {
        (fieldHalfExtent * 2.0) / Float(max(1, cellsPerSide))
    }

    var cellCount: Int { cellsPerSide * cellsPerSide }

    var areaHectares: Float {
        let side = fieldHalfExtent * 2.0
        return side * side / 10_000.0
    }

    static func generate(
        parameters: MissionScenarioParameters,
        worldHalfExtent: Float,
        dockPosition: SIMD2<Float>
    ) -> AgriFieldPlacement {
        var rng = MissionSeededGenerator(seed: parameters.seed &+ 0x9E37_79B9)
        let halfExtent = parameters.difficulty.agriFieldSideMeters * 0.5

        // Keep the whole field, plus a working margin for turns at the headland, inside the world.
        // The field, the headland turns *and* the station's standoff all have to fit inside the
        // world, so the centre is kept in far enough for the whole arrangement.
        let standoff = parameters.difficulty.agriStationStandoffMeters
        let safeExtent = max(halfExtent + standoff + 40.0, worldHalfExtent * 0.65)
        let centerSpan = max(0.0, min(safeExtent, worldHalfExtent * 0.9) - halfExtent - standoff - 30.0)

        func randomOffset(_ span: Float) -> Float {
            span <= 0.0 ? 0.0 : Float.random(in: -span...span, using: &rng)
        }

        var center = SIMD2<Float>(randomOffset(centerSpan), randomOffset(centerSpan))
        // The operator should have to transit to the field, but a spraying mission is flown out
        // of the dock repeatedly, so this is a shorter leg than a search sector's.
        for _ in 0..<8 where simd_distance(center, dockPosition) < halfExtent * 0.8 {
            center = SIMD2<Float>(randomOffset(centerSpan), randomOffset(centerSpan))
        }

        let rowHeading = Float.random(in: 0...(Float.pi * 0.5), using: &rng)

        // The station sits just off one edge of the field, on the side facing the dock, so the
        // first approach and every refill run share the same corridor.
        let towardDock = simd_normalize(dockPosition - center + SIMD2<Float>(0.0001, 0.0))
        let station = center + towardDock * (halfExtent + parameters.difficulty.agriStationStandoffMeters)

        let cells = max(8, Int((halfExtent * 2.0 / AgriSprayTuning.coverageCellMeters).rounded()))

        return AgriFieldPlacement(
            fieldCenter: center,
            fieldHalfExtent: halfExtent,
            rowHeadingRadians: rowHeading,
            stationPosition: station,
            cellsPerSide: cells
        )
    }

    /// World position → field-local cell indices, or nil when the point is off the field.
    func cellIndex(forWorldPosition position: SIMD2<Float>) -> (x: Int, y: Int)? {
        let local = worldToFieldLocal(position)
        guard abs(local.x) <= fieldHalfExtent, abs(local.y) <= fieldHalfExtent else {
            return nil
        }
        let size = cellMeters
        let ix = Int((local.x + fieldHalfExtent) / size)
        let iy = Int((local.y + fieldHalfExtent) / size)
        guard ix >= 0, ix < cellsPerSide, iy >= 0, iy < cellsPerSide else {
            return nil
        }
        return (ix, iy)
    }

    func worldToFieldLocal(_ position: SIMD2<Float>) -> SIMD2<Float> {
        let delta = position - fieldCenter
        let c = cos(-rowHeadingRadians)
        let s = sin(-rowHeadingRadians)
        return SIMD2<Float>(delta.x * c - delta.y * s, delta.x * s + delta.y * c)
    }

    func fieldLocalToWorld(_ local: SIMD2<Float>) -> SIMD2<Float> {
        let c = cos(rowHeadingRadians)
        let s = sin(rowHeadingRadians)
        return fieldCenter + SIMD2<Float>(local.x * c - local.y * s, local.x * s + local.y * c)
    }

    /// Centre of a cell, in field-local coordinates.
    func cellCenterLocal(x: Int, y: Int) -> SIMD2<Float> {
        let size = cellMeters
        return SIMD2<Float>(
            -fieldHalfExtent + (Float(x) + 0.5) * size,
            -fieldHalfExtent + (Float(y) + 0.5) * size
        )
    }
}

// MARK: - Runtime state, reported to the HUD

/// Why the sprayer is not currently treating the crop, when it is running but ineffective.
enum AgriSprayInhibitor: String, Equatable {
    case none
    case offField
    case tooHigh
    case tooLow
    case tooFast
    case windy
    case tankEmpty
}

enum AgriRefillState: Equatable {
    case away
    /// In range of the station but not yet stable enough to connect.
    case inRangeUnstable
    case filling(progress: Float)
    case full
}

enum AgriSprayObjectiveState: Equatable {
    case spraying
    case complete
    case failedTimeout
}

enum AgriSprayOutcome: Equatable {
    case success(elapsedSeconds: Double, coverageFraction: Float, litersUsed: Float, litersWasted: Float)
    case failureTimeout(coverageFraction: Float)
    case aborted
}
