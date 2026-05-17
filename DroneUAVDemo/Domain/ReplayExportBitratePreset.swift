import Foundation

enum ReplayExportBitratePreset: String, Codable, CaseIterable, Identifiable, Equatable {
    case automatic
    case low
    case medium
    case high
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .custom:
            return "Custom"
        }
    }
}

struct ReplayExportBitrateResolver {
    func bitrateBitsPerSecond(
        mode: ReplayVideoExportMode,
        resolution: ReplayExportResolutionPreset,
        preset: ReplayExportBitratePreset,
        customMbps: Double?
    ) -> Int {
        let resolvedPreset = preset == .automatic ? .medium : preset
        if resolvedPreset == .custom {
            let clamped = min(40.0, max(0.5, customMbps ?? mediumMbps(mode: mode, resolution: resolution)))
            return Int(clamped * 1_000_000)
        }

        return Int(mbps(mode: mode, resolution: resolution, preset: resolvedPreset) * 1_000_000)
    }

    private func mediumMbps(mode: ReplayVideoExportMode, resolution: ReplayExportResolutionPreset) -> Double {
        mbps(mode: mode, resolution: resolution, preset: .medium)
    }

    private func mbps(
        mode: ReplayVideoExportMode,
        resolution: ReplayExportResolutionPreset,
        preset: ReplayExportBitratePreset
    ) -> Double {
        switch mode {
        case .fast:
            switch resolution {
            case .p360:
                return fast(low: 0.6, medium: 0.8, high: 1.2, preset: preset)
            case .p480:
                return fast(low: 0.9, medium: 1.2, high: 2.0, preset: preset)
            case .p720:
                return fast(low: 1.8, medium: 2.5, high: 4.0, preset: preset)
            case .p1080, .p1440:
                return fast(low: 3.5, medium: 5.0, high: 7.0, preset: preset)
            }
        case .quality:
            switch resolution {
            case .p360, .p480, .p720:
                return fast(low: 3.0, medium: 5.0, high: 7.5, preset: preset)
            case .p1080:
                return fast(low: 6.0, medium: 8.0, high: 10.0, preset: preset)
            case .p1440:
                return fast(low: 12.0, medium: 16.0, high: 24.0, preset: preset)
            }
        }
    }

    private func fast(low: Double, medium: Double, high: Double, preset: ReplayExportBitratePreset) -> Double {
        switch preset {
        case .low:
            return low
        case .automatic, .medium, .custom:
            return medium
        case .high:
            return high
        }
    }
}
