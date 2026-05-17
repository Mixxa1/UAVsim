import Foundation

enum ReplayVideoExportFormat: String, Codable, CaseIterable, Identifiable {
    case mov
    case mp4

    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

struct ReplayVideoExportSettings: Codable, Equatable {
    static let fastResolutionPreset: ReplayExportResolutionPreset = .p720
    static let qualityDefaultResolutionPreset: ReplayExportResolutionPreset = .p1080
    static let fastWidth = ReplayExportResolutionPreset.p720.width
    static let fastHeight = ReplayExportResolutionPreset.p720.height
    static let fastFramesPerSecond = 24
    static let temporaryMaxWidth = ReplayExportResolutionPreset.p1440.width
    static let temporaryMaxHeight = ReplayExportResolutionPreset.p1440.height
    static let temporaryMaxFramesPerSecond = 30
    static let performanceWarning = "Fast uses simplified environment rendering. Quality allows up to 1440p/30fps and may use more CPU."
    static let debugBuildWarning = "Debug builds may export significantly slower. Use Release for performance validation."

    var exportMode: ReplayVideoExportMode
    var resolutionPreset: ReplayExportResolutionPreset
    var format: ReplayVideoExportFormat
    var width: Int
    var height: Int
    var framesPerSecond: Int
    var bitratePreset: ReplayExportBitratePreset
    var customBitrateMbps: Double?
    var playbackSpeed: Double
    var includeOverlay: Bool
    var includePathTrail: Bool
    var includeEventMarkers: Bool
    var trimRange: ReplayTrimRange?

    static let defaultSettings = ReplayVideoExportSettings(
        exportMode: .fast,
        resolutionPreset: fastResolutionPreset,
        format: .mov,
        width: fastWidth,
        height: fastHeight,
        framesPerSecond: fastFramesPerSecond,
        bitratePreset: .automatic,
        customBitrateMbps: nil,
        playbackSpeed: 1.0,
        includeOverlay: false,
        includePathTrail: false,
        includeEventMarkers: false,
        trimRange: nil
    )

    var clamped: ReplayVideoExportSettings {
        let speed = min(8.0, max(0.25, playbackSpeed))
        let customMbps = customBitrateMbps.map { min(40.0, max(0.5, $0)) }
        if exportMode == .fast {
            let preset: ReplayExportResolutionPreset = resolutionPreset == .p1440 ? Self.fastResolutionPreset : resolutionPreset
            return ReplayVideoExportSettings(
                exportMode: .fast,
                resolutionPreset: preset,
                format: format,
                width: preset.width,
                height: preset.height,
                framesPerSecond: Self.fastFramesPerSecond,
                bitratePreset: bitratePreset,
                customBitrateMbps: customMbps,
                playbackSpeed: speed,
                includeOverlay: false,
                includePathTrail: false,
                includeEventMarkers: false,
                trimRange: trimRange
            )
        }

        let preset: ReplayExportResolutionPreset
        switch resolutionPreset {
        case .p360, .p480:
            preset = .p720
        case .p720, .p1080, .p1440:
            preset = resolutionPreset
        }

        return ReplayVideoExportSettings(
            exportMode: .quality,
            resolutionPreset: preset,
            format: format,
            width: min(Self.temporaryMaxWidth, max(640, preset.width)),
            height: min(Self.temporaryMaxHeight, max(360, preset.height)),
            framesPerSecond: [24, 30].contains(framesPerSecond) ? framesPerSecond : (framesPerSecond < 30 ? 24 : 30),
            bitratePreset: bitratePreset,
            customBitrateMbps: customMbps,
            playbackSpeed: speed,
            includeOverlay: includeOverlay,
            includePathTrail: includePathTrail,
            includeEventMarkers: includeEventMarkers,
            trimRange: trimRange
        )
    }

    var resolvedBitrateBitsPerSecond: Int {
        ReplayExportBitrateResolver().bitrateBitsPerSecond(
            mode: clamped.exportMode,
            resolution: clamped.resolutionPreset,
            preset: clamped.bitratePreset,
            customMbps: clamped.customBitrateMbps
        )
    }
}
