import Foundation
import SceneKit

/// Player-facing graphics quality tier. Each case exposes the concrete render knobs it maps to,
/// so the scene/render layers (`ScenePopulationService`, `DroneSceneController`,
/// `DroneSceneViewRepresentable`) read one preset instead of scattering quality logic.
enum GraphicsQualityPreset: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var titleKey: String { "settings.graphics.\(rawValue)" }

    /// Multiplier on the visual-density tree layer, relative to the `.high` baseline (which equals
    /// the current full density). This layer is the bulk of the forest's render cost, so this is
    /// the main density-vs-performance lever; collision proxies are generated only for trees that
    /// remain visible at the selected quality.
    var visualTreeMultiplier: Float {
        switch self {
        case .low:
            return 0.45
        case .medium:
            return 0.72
        case .high:
            return 1.0
        }
    }

    /// Whether environment objects cast shadows at all. The shadow-map pass is a real GPU cost at
    /// forest density, so `.low` drops it entirely.
    var environmentShadowsEnabled: Bool {
        switch self {
        case .low:
            return false
        case .medium, .high:
            return true
        }
    }

    var antialiasingMode: SCNAntialiasingMode {
        switch self {
        case .low:
            return SCNAntialiasingMode.none
        case .medium:
            return .multisampling2X
        case .high:
            return .multisampling4X
        }
    }

    /// Whether the full-screen weather depth-of-field `SCNTechnique` is allowed (it's a constant
    /// per-frame post-process cost on top of whatever weather already requests).
    var weatherDepthOfFieldEnabled: Bool {
        switch self {
        case .low:
            return false
        case .medium, .high:
            return true
        }
    }

    /// Internal render-scale default for the tier. The GPU renders at this fraction of native
    /// drawable resolution and upscales — a direct fill/heat lever. Overridable by the explicit
    /// render-scale control.
    var defaultRenderScale: Double {
        switch self {
        case .low:
            return 0.7
        case .medium:
            return 0.85
        case .high:
            return 1.0
        }
    }

    /// `.high` maxes out fill (4x MSAA, full shadows, full tree density, native render scale) — the
    /// tier worth warning the user can run their machine hot.
    var showsHeatWarning: Bool { self == .high }
}

/// Fixed content-size presets for the main window. `.native` leaves the window at whatever size
/// the user last set (no forced resize).
enum WindowSizePreset: String, CaseIterable, Identifiable {
    case hd720
    case fhd1080
    case qhd1440
    case native

    var id: String { rawValue }

    var titleKey: String { "settings.window_size.\(rawValue)" }

    /// Target content size, or `nil` for `.native` (don't resize).
    var contentSize: CGSize? {
        switch self {
        case .hd720:
            return CGSize(width: 1280, height: 720)
        case .fhd1080:
            return CGSize(width: 1920, height: 1080)
        case .qhd1440:
            return CGSize(width: 2560, height: 1440)
        case .native:
            return nil
        }
    }
}

/// Non-SwiftUI accessor for the persisted graphics settings, mirroring `L10n.currentLanguage()`.
/// The SwiftUI settings screen writes these via `@AppStorage(<key>)`; scene/render code that has
/// no SwiftUI environment reads them here.
enum AppGraphicsSettings {
    static let qualityKey = "app.graphics.quality"
    static let renderScaleKey = "app.graphics.renderScale"
    static let windowSizeKey = "app.window.sizePreset"

    /// Default is `.high` so existing installs keep the current full-detail behavior until the
    /// user lowers it.
    static var quality: GraphicsQualityPreset {
        GraphicsQualityPreset(
            rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? GraphicsQualityPreset.high.rawValue
        ) ?? .high
    }

    /// Explicit render scale if the user set one (clamped 0.5…1.0); otherwise the current tier's
    /// default. A stored 0 means "not set" → fall back to the tier default.
    static var renderScale: Double {
        let stored = UserDefaults.standard.double(forKey: renderScaleKey)
        guard stored > 0 else { return quality.defaultRenderScale }
        return min(1.0, max(0.5, stored))
    }

    static var windowSize: WindowSizePreset {
        WindowSizePreset(
            rawValue: UserDefaults.standard.string(forKey: windowSizeKey) ?? WindowSizePreset.native.rawValue
        ) ?? .native
    }
}
