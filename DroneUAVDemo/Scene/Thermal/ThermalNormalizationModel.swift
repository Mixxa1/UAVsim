import Foundation
import simd

/// Sample material responses and facade orientations, not the camera image: panning cannot
/// pump exposure, and cold sky cannot flatten the entire city. The range can contract as surfaces
/// cool, with temporal smoothing at the caller.
enum ThermalNormalizationModel {
    static func make(
        population: [(materialClass: ThermalMaterialClass, weight: Double)],
        context: ThermalEnvironmentContext
    ) -> ThermalNormalizationState {
        let up = SIMD3<Double>(0, 1, 0)
        let walls: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        var samples: [(temp: Double, weight: Double)] = []
        for entry in population where entry.weight > 0 && entry.materialClass != .sky {
            let cls = entry.materialClass
            let normals = [.building, .glass, .metal, .generic].contains(cls) ? walls + [up] : [up]
            for normal in normals {
                let views = cls == .glass
                    ? [normal, simd_normalize(normal * 0.4 + SIMD3(0, -0.9, 0))] : [normal]
                for view in views {
                    let temp = ThermalMaterialModel.apparentSurfaceTemperature(for: cls,
                        context: context, normal: normal, view: view)
                    samples.append((temp, entry.weight / Double(normals.count * views.count)))
                }
            }
        }
        let ambient = context.ambientTemperatureCelsius
        var displayMin = samples.isEmpty ? ambient - 3 : weightedPercentile(samples, 0.02) - 3
        var displayMax = samples.isEmpty ? ambient + 10 : weightedPercentile(samples, 0.98) + 4
        // A small warm target must remain visible even in a dense forest population.
        if population.contains(where: { $0.materialClass == .body && $0.weight > 0 }) {
            displayMax = max(displayMax, ThermalMaterialModel.meanTemperature(for: .body, context: context) + 2)
        }
        let minSpan = context.sceneProfile == .snow ? 24.0 : 18.0
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

    static func stabilized(_ target: ThermalNormalizationState, previous: ThermalNormalizationState?,
                           elapsedSeconds: Double) -> ThermalNormalizationState {
        guard let previous else { return target }
        let blend = 1 - exp(-max(0, elapsedSeconds) / 1.5)
        return ThermalNormalizationState(
            displayMinCelsius: previous.displayMinCelsius + (target.displayMinCelsius - previous.displayMinCelsius) * blend,
            displayMaxCelsius: previous.displayMaxCelsius + (target.displayMaxCelsius - previous.displayMaxCelsius) * blend)
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
