import Foundation
import simd

/// Where the water is in an imported world, and at what level.
///
/// A photogrammetric reconstruction contains no semantics: the harbour is triangles like any other
/// triangles, which is why an aircraft over the sea would otherwise rest on it as if it were
/// asphalt. This model is the missing semantic layer.
///
/// It is deliberately a *plain mask plus a level*, not a reference to whatever produced it. Today it
/// is derived from the mesh itself (see `WaterSurfaceDetector`); an OSM `natural=water` import can
/// replace the detector without any consumer noticing, which is the point — the world constructor is
/// meant to be source-agnostic and to follow whatever fidelity the source offers.
struct WaterSurfaceModel {

    /// Elevation of the water plane in world metres.
    let level: Float

    /// Planar extent the mask covers. Queries outside it answer "not water" rather than guessing.
    let minimum: SIMD2<Float>
    let cellSize: Float
    let columns: Int
    let rows: Int

    /// Row-major occupancy, one entry per cell.
    private let mask: [Bool]

    /// Fraction of the covered area that is water. Diagnostics, and a sanity check for callers
    /// deciding whether a detector's answer is believable.
    var coverageFraction: Double {
        guard !mask.isEmpty else { return 0 }
        return Double(mask.lazy.filter { $0 }.count) / Double(mask.count)
    }

    init(level: Float, minimum: SIMD2<Float>, cellSize: Float, columns: Int, rows: Int, mask: [Bool]) {
        self.level = level
        self.minimum = minimum
        self.cellSize = max(0.5, cellSize)
        self.columns = columns
        self.rows = rows
        self.mask = mask
    }

    /// Is the surface under this column water?
    func isWater(x: Float, z: Float) -> Bool {
        let column = Int((x - minimum.x) / cellSize)
        let row = Int((z - minimum.y) / cellSize)
        guard column >= 0, column < columns, row >= 0, row < rows else { return false }
        return mask[row * columns + column]
    }

    /// How deep the given point sits under the water plane, or nil if it is clear of the water.
    ///
    /// Positive means submerged. Callers use this both for the immersion decision and for placing
    /// the splash at the point where the hull actually crossed the surface.
    func submersionDepth(at position: SIMD3<Float>) -> Float? {
        guard isWater(x: position.x, z: position.z) else { return nil }
        let depth = level - position.y
        return depth > 0 ? depth : nil
    }
}

/// Derives a `WaterSurfaceModel` from the collision mesh alone, with no network and no side data.
///
/// The separation this relies on was measured, not assumed. Sampling the central Helsinki tile every
/// 6 m and recording both the surface height and the local height spread over a 3 m probe:
///
/// ```
/// height (m)   columns   median roughness
///     -0.5      76759        0.00      <- the harbour: a dead-flat sheet
///      2.0       3597        0.15      <- quaysides: flat, but 2.5 m higher
///      5.5+       ...        2.0-6.0   <- everything with structure on it
/// ```
///
/// So flatness alone is not a water test — quaysides and large roofs are flat too. Water is the
/// combination: a single elevation shared by a large share of the tile, at which the surface is
/// essentially perfectly smooth. The level is read out of the data as the mode rather than hardcoded,
/// because it is a property of the source's vertical datum, not of this city.
enum WaterSurfaceDetector {

    struct Result {
        let model: WaterSurfaceModel?
        /// Why no model, when there is none — surfaced to the caller rather than silently returning
        /// "no water anywhere", which is indistinguishable from a bug.
        let rejection: String?
    }

    /// Bin width for the level histogram. Half a metre is fine enough to separate a water plane from
    /// a quay 2.5 m above it, and coarse enough that reconstruction noise stays in one bin.
    private static let binHeight: Float = 0.5

    /// A cell counts as water only if the surface within `probeRadius` of it varies by less than
    /// this. Real water in these exports reconstructs as an almost exactly flat sheet; anything with
    /// texture on it — waves modelled as geometry, moored boats, pontoons — is correctly excluded.
    private static let flatnessTolerance: Float = 0.12
    private static let probeRadius: Float = 3.0

    /// The water plane must account for at least this share of the tile before it is believed. A
    /// landlocked tile has no such plane and must produce no model at all.
    private static let minimumCoverage = 0.04

    static func detect(collision: MeshCollisionIndex, cellSize: Float = 4.0) -> Result {
        let minimum = SIMD2<Float>(collision.bounds.minimum.x, collision.bounds.minimum.z)
        let maximum = SIMD2<Float>(collision.bounds.maximum.x, collision.bounds.maximum.z)
        let columns = max(1, Int((maximum.x - minimum.x) / cellSize))
        let rows = max(1, Int((maximum.y - minimum.y) / cellSize))
        guard columns > 4, rows > 4 else {
            return Result(model: nil, rejection: "world too small to sample")
        }

        // Pass 1: surface height per cell, and the height histogram it implies.
        var heights = [Float](repeating: .nan, count: columns * rows)
        var histogram: [Int: Int] = [:]
        for row in 0..<rows {
            for column in 0..<columns {
                let x = minimum.x + (Float(column) + 0.5) * cellSize
                let z = minimum.y + (Float(row) + 0.5) * cellSize
                guard let height = collision.highestSurface(x: x, z: z) else { continue }
                heights[row * columns + column] = height
                histogram[Int(floor(height / binHeight)), default: 0] += 1
            }
        }

        // Pass 2: the candidate level is the most populated bin that is also flat. Taking the most
        // populated bin outright would pick a city's dominant roof height in an inland tile.
        var candidates = histogram.sorted { $0.value > $1.value }.prefix(6)
        candidates = ArraySlice(candidates.filter { $0.value > (columns * rows) / 50 })
        guard !candidates.isEmpty else {
            return Result(model: nil, rejection: "no elevation is common enough to be a water plane")
        }

        var best: (level: Float, mask: [Bool], count: Int)?
        for candidate in candidates {
            let level = (Float(candidate.key) + 0.5) * binHeight
            var mask = [Bool](repeating: false, count: columns * rows)
            var count = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    let height = heights[index]
                    guard height.isFinite, abs(height - level) <= binHeight else { continue }
                    guard isFlat(around: SIMD2<Float>(
                        minimum.x + (Float(column) + 0.5) * cellSize,
                        minimum.y + (Float(row) + 0.5) * cellSize
                    ), height: height, collision: collision) else { continue }
                    mask[index] = true
                    count += 1
                }
            }
            if count > (best?.count ?? 0) {
                best = (level, mask, count)
            }
        }

        // Pull the mask back from its own edge by one cell.
        //
        // The shoreline does not respect the grid: a cell straddling the water's edge is centred on
        // water and so gets marked, but part of it is quay. Sampling the tile confirmed this is the
        // only failure mode left — 3 land samples in 18,235 were claimed as water, all of them on
        // that boundary. The two errors are not equally bad. Drowning an aircraft that is standing
        // on a pier is a wrong outcome the pilot cannot argue with; failing to drown one that
        // ditches within four metres of the shore is a near-miss in the forgiving direction. So the
        // boundary is resolved in favour of dry land.
        var eroded = best?.mask ?? []
        var erodedCount = 0
        if let best {
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard best.mask[index] else { continue }
                    let keep = row > 0 && row < rows - 1 && column > 0 && column < columns - 1
                        && best.mask[index - 1] && best.mask[index + 1]
                        && best.mask[index - columns] && best.mask[index + columns]
                    eroded[index] = keep
                    if keep { erodedCount += 1 }
                }
            }
        }

        guard let best else {
            return Result(model: nil, rejection: "no flat plane found at any common elevation")
        }
        let coverage = Double(erodedCount) / Double(columns * rows)
        guard coverage >= minimumCoverage else {
            return Result(
                model: nil,
                rejection: String(format: "flattest plane covers only %.1f%% — treating as dry land",
                                  coverage * 100)
            )
        }

        return Result(
            model: WaterSurfaceModel(
                level: best.level,
                minimum: minimum,
                cellSize: cellSize,
                columns: columns,
                rows: rows,
                mask: eroded
            ),
            rejection: nil
        )
    }

    private static func isFlat(
        around point: SIMD2<Float>,
        height: Float,
        collision: MeshCollisionIndex
    ) -> Bool {
        let offsets: [SIMD2<Float>] = [
            SIMD2(probeRadius, 0), SIMD2(-probeRadius, 0),
            SIMD2(0, probeRadius), SIMD2(0, -probeRadius)
        ]
        for offset in offsets {
            guard let neighbour = collision.highestSurface(
                x: point.x + offset.x,
                z: point.y + offset.y
            ) else {
                // A missing neighbour is the tile edge or a hole; refuse rather than guess.
                return false
            }
            if abs(neighbour - height) > flatnessTolerance { return false }
        }
        return true
    }
}
