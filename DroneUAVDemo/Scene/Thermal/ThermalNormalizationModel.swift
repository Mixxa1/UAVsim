import Foundation

/// Builds the display range (`displayMin`/`displayMax`).
///
/// The range is anchored to a fixed band expressed *relative to ambient* per scene profile, and
/// only **expands** to cover a colder/hotter population — it never contracts to fit the warmest
/// object present. That distinction is the whole point:
///
///  - It's camera-independent (the band is a function of weather + map, not of what's on screen),
///    so panning never re-stretches the palette — the old "tone jumps when the camera rotates" bug
///    is structurally impossible.
///  - The warmest *present* surface is never forced to the bright end. In a snow scene the trees
///    are warmer than the snow, but because the band already reserves warm headroom they read as a
///    mid-tone, not glowing yellow. The bright top is reserved for genuinely hot things (people /
///    fire / engines — out of scope in this environment-only patch), which would expand the band.
enum ThermalNormalizationModel {

    /// Fixed display band relative to ambient, per scene profile (cold, warm). `warm` carries
    /// headroom above the hottest ordinary surface so the environment sits in the lower ~60%.
    private static func fixedBand(for profile: ThermalSceneProfile) -> (cold: Double, warm: Double) {
        // Tuned (see scenario sweep) so cool vegetation lands in the lower-mid of the palette,
        // man-made/sunlit surfaces in the upper-mid, and the bright top stays reserved.
        switch profile {
        case .neutral: return (-14, 24)
        case .forest: return (-15, 22)
        case .field: return (-14, 24)
        case .city: return (-13, 27)
        case .snow: return (-24, 18)
        case .waterCoast: return (-15, 22)
        case .mountain: return (-15, 24)
        }
    }

    static func make(
        population: [(materialClass: ThermalMaterialClass, weight: Double)],
        context: ThermalEnvironmentContext
    ) -> ThermalNormalizationState {
        let ambient = context.ambientTemperatureCelsius
        let band = fixedBand(for: context.sceneProfile)
        var displayMin = ambient + band.cold
        var displayMax = ambient + band.warm

        // Expand (only) to cover outliers in the present population — never contract.
        var samples: [(temp: Double, weight: Double)] = []
        samples.reserveCapacity(population.count)
        for entry in population where entry.weight > 0 {
            let temp = ThermalMaterialModel.meanTemperature(for: entry.materialClass, context: context)
            samples.append((temp, entry.weight))
        }
        if !samples.isEmpty {
            // Use 2nd/98th percentile so a single stray class can't yank the band.
            let popLow = weightedPercentile(samples, 0.02)
            let popHigh = weightedPercentile(samples, 0.98)
            displayMin = min(displayMin, popLow)
            displayMax = max(displayMax, popHigh)
        }

        // Haze/rain lowers effective contrast: widen the band so temperature differences span less
        // of the palette (matches a degraded sensor in low visibility).
        let haze = max(context.fogDensity, context.rainIntensity * 0.6)
        if haze > 0.01 {
            let mid = (displayMin + displayMax) * 0.5
            let widen = 1.0 + 0.30 * haze
            displayMin = mid + (displayMin - mid) * widen
            displayMax = mid + (displayMax - mid) * widen
        }

        // Never collapse to a flat tone.
        let minSpan = 14.0
        if displayMax - displayMin < minSpan {
            let mid = (displayMin + displayMax) * 0.5
            displayMin = mid - minSpan * 0.5
            displayMax = mid + minSpan * 0.5
        }

        return ThermalNormalizationState(
            displayMinCelsius: displayMin,
            displayMaxCelsius: displayMax
        )
    }

    private static func weightedPercentile(
        _ samples: [(temp: Double, weight: Double)],
        _ fraction: Double
    ) -> Double {
        let sorted = samples.sorted { $0.temp < $1.temp }
        let totalWeight = sorted.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return sorted.first?.temp ?? 0.0 }

        let target = totalWeight * min(1.0, max(0.0, fraction))
        var cumulative = 0.0
        for sample in sorted {
            cumulative += sample.weight
            if cumulative >= target {
                return sample.temp
            }
        }
        return sorted.last?.temp ?? 0.0
    }
}
