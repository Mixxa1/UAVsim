import Foundation

enum ReplayExportBitratePreset: String, Codable, CaseIterable, Identifiable, Equatable {
    case automatic
    case low
    case medium
    case high
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .automatic:
            return "replay.bitrate.auto"
        case .low:
            return "replay.bitrate.low"
        case .medium:
            return "replay.bitrate.medium"
        case .high:
            return "replay.bitrate.high"
        case .custom:
            return "replay.bitrate.custom"
        }
    }

    var displayName: String {
        L10n.s(titleKey, language: L10n.currentLanguage())
    }
}

struct ReplayExportBitrateResolver {
    /// The mbps tables below were tuned against the original 24/30fps range. Frame rate wasn't a
    /// resolver input back then because it never went above 30 — now that quality mode allows up
    /// to 120fps, the same bitrate spread across 4x the frames means 4x less data per frame
    /// (visibly more compressed at high fps, exactly the "качество хромает" symptom this baseline
    /// scaling fixes). Scaling only ever kicks in above this baseline, so 24/30fps output is
    /// bit-for-bit identical to before this existed.
    private static let baselineFPS: Double = 30

    func bitrateBitsPerSecond(
        mode: ReplayVideoExportMode,
        resolution: ReplayExportResolutionPreset,
        preset: ReplayExportBitratePreset,
        customMbps: Double?,
        framesPerSecond: Int
    ) -> Int {
        let resolvedPreset = preset == .automatic ? .medium : preset
        if resolvedPreset == .custom {
            let clamped = min(40.0, max(0.5, customMbps ?? mediumMbps(mode: mode, resolution: resolution, framesPerSecond: framesPerSecond)))
            return Int(clamped * 1_000_000)
        }

        return Int(mbps(mode: mode, resolution: resolution, preset: resolvedPreset, framesPerSecond: framesPerSecond) * 1_000_000)
    }

    private func mediumMbps(mode: ReplayVideoExportMode, resolution: ReplayExportResolutionPreset, framesPerSecond: Int) -> Double {
        mbps(mode: mode, resolution: resolution, preset: .medium, framesPerSecond: framesPerSecond)
    }

    private func mbps(
        mode: ReplayVideoExportMode,
        resolution: ReplayExportResolutionPreset,
        preset: ReplayExportBitratePreset,
        framesPerSecond: Int
    ) -> Double {
        let base: Double
        switch mode {
        case .fast:
            switch resolution {
            case .p360:
                base = fast(low: 0.6, medium: 0.8, high: 1.2, preset: preset)
            case .p480:
                base = fast(low: 0.9, medium: 1.2, high: 2.0, preset: preset)
            case .p720:
                base = fast(low: 1.8, medium: 2.5, high: 4.0, preset: preset)
            case .p1080, .p1440:
                base = fast(low: 3.5, medium: 5.0, high: 7.0, preset: preset)
            }
        case .quality:
            switch resolution {
            case .p360, .p480, .p720:
                base = fast(low: 3.0, medium: 5.0, high: 7.5, preset: preset)
            case .p1080:
                base = fast(low: 6.0, medium: 8.0, high: 10.0, preset: preset)
            case .p1440:
                base = fast(low: 12.0, medium: 16.0, high: 24.0, preset: preset)
            }
        }
        let fpsScale = max(1.0, Double(framesPerSecond) / Self.baselineFPS)
        return base * fpsScale
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
