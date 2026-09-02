import Foundation

/// What a group of OSD cells *means*, rather than which MAX7456 character index sits in it.
///
/// The editor is built entirely on these: an operator arranges "battery voltage" and "link
/// quality", never glyph 0x7A. Keeping the semantic layer separate is also what lets one layout
/// survive a font change — each font resolves the same element through its own `FPVOSDSymbolMap`.
enum OSDElement: String, Codable, CaseIterable, Identifiable, Sendable {
    case batteryVoltage
    case batteryCapacity
    case linkQuality
    case rssi
    case snr
    case altitude
    case speed
    case satellites
    case flightMode
    case artificialHorizon
    case aircraftReference
    case artificialHorizonSidebars
    case compassRibbon
    case heading
    case throttle
    case distanceToHome
    case flightDistance
    case flightTimer
    case linkWarning
    case staleWarning

    var id: String { rawValue }

    var titleKey: String { "osd.element.\(rawValue)" }

    /// Which piece of equipment has to actually be installed for the element to mean anything.
    var requirement: OSDElementRequirement {
        switch self {
        case .linkQuality, .rssi, .snr:
            return .radioLink
        case .satellites, .distanceToHome, .flightDistance:
            // Range from home and path flown are GNSS-derived readings on a real aircraft, so
            // they follow the navigation module rather than being shown unconditionally.
            return .satelliteNavigation
        case .batteryVoltage, .batteryCapacity, .altitude, .speed, .flightMode,
             .artificialHorizon, .aircraftReference, .artificialHorizonSidebars,
             .compassRibbon, .heading, .throttle, .flightTimer,
             .linkWarning, .staleWarning:
            return .always
        }
    }

    /// Warnings are centred inside their box; everything else honours `rightAligned`.
    var isCentred: Bool {
        self == .linkWarning || self == .staleWarning
    }

    /// Drawn from glyph art rather than text, so the editor previews them differently and the
    /// composer routes them past its text formatter.
    var isGraphical: Bool {
        switch self {
        case .artificialHorizon, .aircraftReference, .artificialHorizonSidebars, .compassRibbon:
            return true
        default:
            return false
        }
    }

    /// Representative text for the editor's preview, so a layout can be arranged on the ground
    /// without flying to get real values on screen.
    var sampleText: String {
        switch self {
        case .batteryVoltage: return "BAT 16.8V"
        case .batteryCapacity: return "CAP 78%"
        case .linkQuality: return "LQ 100"
        case .rssi: return "RSSI -72"
        case .snr: return "SNR 39"
        case .altitude: return "ALT 156M"
        case .speed: return "SPD 12.4"
        case .satellites: return "GPS 14"
        case .flightMode: return "ARM ANGLE"
        case .artificialHorizon, .aircraftReference, .artificialHorizonSidebars,
             .compassRibbon:
            return ""
        case .heading: return "HDG 284"
        case .throttle: return "THR 46%"
        case .distanceToHome: return "HOME 432M"
        case .flightDistance: return "DST 653M"
        case .flightTimer: return "TIM 04:12"
        case .linkWarning: return "LINK LOW"
        case .staleWarning: return "DATA STALE"
        }
    }

    /// Grouping for the editor's element list.
    var group: OSDElementGroup {
        switch self {
        case .batteryVoltage, .batteryCapacity:
            return .power
        case .linkQuality, .rssi, .snr, .linkWarning, .staleWarning:
            return .link
        case .altitude, .speed, .satellites, .distanceToHome, .flightDistance,
             .heading, .compassRibbon:
            return .navigation
        case .flightMode, .artificialHorizon, .aircraftReference,
             .artificialHorizonSidebars, .throttle, .flightTimer:
            return .flight
        }
    }
}

enum OSDElementGroup: String, CaseIterable, Identifiable, Sendable {
    case power
    case link
    case navigation
    case flight

    var id: String { rawValue }
    var titleKey: String { "osd.group.\(rawValue)" }
}

/// Which of Betaflight's centre markers the aircraft reference draws. Fonts that carry no
/// dedicated wing art resolve both styles to the same glyphs, so the choice is always offered
/// but only visibly different where the font actually has the artwork.
enum OSDCrosshairStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case aircraft

    var id: String { rawValue }
    var titleKey: String { "osd.crosshair.\(rawValue)" }
}

enum OSDElementRequirement: String, Equatable, Sendable {
    case always
    case radioLink
    case satelliteNavigation
}

/// What the currently selected aircraft and radio system can actually supply. An element whose
/// requirement is unmet is never composed into the frame and is shown disabled — with the reason
/// — in the editor, so the OSD reflects the build rather than a wish list.
struct OSDElementAvailability: Equatable, Sendable {
    var hasRadioLink: Bool
    var hasSatelliteNavigation: Bool

    static let all = OSDElementAvailability(
        hasRadioLink: true,
        hasSatelliteNavigation: true
    )

    func isAvailable(_ element: OSDElement) -> Bool {
        switch element.requirement {
        case .always: return true
        case .radioLink: return hasRadioLink
        case .satelliteNavigation: return hasSatelliteNavigation
        }
    }

    /// Localization key explaining why the element is greyed out, or nil when it is available.
    func unavailableReasonKey(for element: OSDElement) -> String? {
        guard !isAvailable(element) else { return nil }
        switch element.requirement {
        case .always: return nil
        case .radioLink: return "osd.requirement.radio_link"
        case .satelliteNavigation: return "osd.requirement.satellite_navigation"
        }
    }
}

/// Where one element sits on the character grid. Stored per element rather than as fixed struct
/// fields so the editor can move, resize, disable and re-add elements without a schema change.
struct OSDPlacement: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var rightAligned: Bool
    var isEnabled: Bool

    init(x: Int, y: Int, width: Int, rightAligned: Bool = false, isEnabled: Bool = true) {
        self.x = x
        self.y = y
        self.width = width
        self.rightAligned = rightAligned
        self.isEnabled = isEnabled
    }
}

enum OSDLayoutPreset: String, CaseIterable, Identifiable, Sendable {
    /// Values pushed hard into the corners, the way a real MAX7456 OSD is laid out.
    case corners
    /// The looser arrangement UAVsim shipped before the editor existed.
    case classic
    /// Voltage, link and altitude only.
    case minimal
    /// Nothing that a pilot racing a gate has time to read.
    case racing

    var id: String { rawValue }
    var titleKey: String { "osd.preset.\(rawValue)" }

    var configuration: OSDLayoutConfiguration {
        switch self {
        case .corners: return .corners
        case .classic: return .classic
        case .minimal: return .minimal
        case .racing: return .racing
        }
    }
}

struct OSDLayoutConfiguration: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let defaultColumns = 30
    static let defaultRows = 16

    var version: Int
    var columns: Int
    var rows: Int
    /// Fraction of the frame kept clear on each side of the character grid. Real OSDs sit almost
    /// on the bezel; the generous default this replaced pulled every value toward the centre.
    var horizontalMarginFraction: Double
    var verticalMarginFraction: Double
    /// Keyed by `OSDElement.rawValue`. A dictionary rather than an array so a layout saved by an
    /// older build simply lacks the newer keys — and a key this build no longer knows is ignored
    /// — instead of failing to decode.
    var placements: [String: OSDPlacement]
    /// Optional so a layout saved before crosshair styles existed still decodes; Swift's
    /// synthesized decoder does not fall back to a property's default value for a missing key.
    var crosshairStyle: OSDCrosshairStyle?

    var resolvedCrosshairStyle: OSDCrosshairStyle { crosshairStyle ?? .standard }

    init(
        version: Int = OSDLayoutConfiguration.currentVersion,
        columns: Int = OSDLayoutConfiguration.defaultColumns,
        rows: Int = OSDLayoutConfiguration.defaultRows,
        horizontalMarginFraction: Double = 0.012,
        verticalMarginFraction: Double = 0.018,
        placements: [String: OSDPlacement],
        crosshairStyle: OSDCrosshairStyle? = nil
    ) {
        self.crosshairStyle = crosshairStyle
        self.version = version
        self.columns = columns
        self.rows = rows
        self.horizontalMarginFraction = horizontalMarginFraction
        self.verticalMarginFraction = verticalMarginFraction
        self.placements = placements
    }

    /// Falls back to the preset default so an element added in a later build still appears in a
    /// layout saved before it existed.
    func placement(for element: OSDElement) -> OSDPlacement {
        placements[element.rawValue]
            ?? Self.corners.placements[element.rawValue]
            ?? OSDPlacement(x: 0, y: 0, width: 10, rightAligned: false, isEnabled: false)
    }

    func isEnabled(_ element: OSDElement) -> Bool {
        placement(for: element).isEnabled
    }

    mutating func setPlacement(_ placement: OSDPlacement, for element: OSDElement) {
        placements[element.rawValue] = placement
    }

    mutating func move(_ element: OSDElement, toX x: Int, y: Int) {
        var placement = self.placement(for: element)
        placement.x = min(max(0, x), max(0, columns - 1))
        placement.y = min(max(0, y), max(0, rows - 1))
        placements[element.rawValue] = placement
    }

    mutating func setEnabled(_ isEnabled: Bool, for element: OSDElement) {
        var placement = self.placement(for: element)
        placement.isEnabled = isEnabled
        placements[element.rawValue] = placement
    }

    /// Elements in a stable order, so composing a frame never depends on dictionary ordering.
    func orderedPlacements(
        availability: OSDElementAvailability
    ) -> [(element: OSDElement, placement: OSDPlacement)] {
        OSDElement.allCases.compactMap { element in
            guard availability.isAvailable(element) else { return nil }
            let placement = self.placement(for: element)
            guard placement.isEnabled else { return nil }
            return (element, placement)
        }
    }

    /// Brings a decoded layout back inside the grid. A layout edited on one grid size and loaded
    /// on another would otherwise silently drop elements off the right-hand edge.
    func normalized() -> OSDLayoutConfiguration {
        var copy = self
        copy.columns = max(1, columns)
        copy.rows = max(1, rows)
        copy.horizontalMarginFraction = min(max(0, horizontalMarginFraction), 0.2)
        copy.verticalMarginFraction = min(max(0, verticalMarginFraction), 0.2)
        for (key, placement) in placements {
            var fixed = placement
            fixed.width = min(max(1, placement.width), copy.columns)
            fixed.x = min(max(0, placement.x), copy.columns - 1)
            fixed.y = min(max(0, placement.y), copy.rows - 1)
            copy.placements[key] = fixed
        }
        return copy
    }
}

extension OSDLayoutConfiguration {
    private static func layout(
        horizontalMargin: Double,
        verticalMargin: Double,
        _ entries: [OSDElement: OSDPlacement]
    ) -> OSDLayoutConfiguration {
        var placements: [String: OSDPlacement] = [:]
        for element in OSDElement.allCases {
            placements[element.rawValue] = entries[element]
                ?? OSDPlacement(x: 0, y: 0, width: 10, rightAligned: false, isEnabled: false)
        }
        return OSDLayoutConfiguration(
            horizontalMarginFraction: horizontalMargin,
            verticalMarginFraction: verticalMargin,
            placements: placements
        )
    }

    /// Default. Top two and bottom two rows, hard against the left and right edges.
    static let corners = layout(horizontalMargin: 0.012, verticalMargin: 0.018, [
        .batteryVoltage: OSDPlacement(x: 0, y: 0, width: 12),
        .batteryCapacity: OSDPlacement(x: 0, y: 1, width: 12),
        .linkQuality: OSDPlacement(x: 18, y: 0, width: 12, rightAligned: true),
        .rssi: OSDPlacement(x: 18, y: 1, width: 12, rightAligned: true),
        .snr: OSDPlacement(x: 18, y: 2, width: 12, rightAligned: true, isEnabled: false),
        .artificialHorizon: OSDPlacement(x: 13, y: 7, width: 3),
        .aircraftReference: OSDPlacement(x: 13, y: 7, width: 3),
        .artificialHorizonSidebars: OSDPlacement(x: 13, y: 7, width: 3),
        // Centred between the corner readouts with a cell of clearance either side, so enabling
        // the ribbon does not run straight into the battery and link columns.
        .compassRibbon: OSDPlacement(x: 10, y: 0, width: 10, isEnabled: false),
        .heading: OSDPlacement(x: 0, y: 2, width: 12, isEnabled: false),
        .throttle: OSDPlacement(x: 18, y: 3, width: 12, rightAligned: true, isEnabled: false),
        .linkWarning: OSDPlacement(x: 9, y: 10, width: 12),
        .staleWarning: OSDPlacement(x: 9, y: 11, width: 12),
        .distanceToHome: OSDPlacement(x: 0, y: 12, width: 12),
        .flightDistance: OSDPlacement(x: 0, y: 13, width: 12, isEnabled: false),
        .flightTimer: OSDPlacement(x: 18, y: 12, width: 12, rightAligned: true),
        .altitude: OSDPlacement(x: 0, y: 14, width: 12),
        .speed: OSDPlacement(x: 0, y: 15, width: 12),
        .satellites: OSDPlacement(x: 18, y: 14, width: 12, rightAligned: true),
        .flightMode: OSDPlacement(x: 18, y: 15, width: 12, rightAligned: true),
    ])

    static let classic = layout(horizontalMargin: 0.035, verticalMargin: 0.045, [
        .batteryVoltage: OSDPlacement(x: 1, y: 1, width: 12),
        .batteryCapacity: OSDPlacement(x: 1, y: 2, width: 12),
        .linkQuality: OSDPlacement(x: 19, y: 1, width: 10, rightAligned: true),
        .rssi: OSDPlacement(x: 17, y: 2, width: 12, rightAligned: true),
        .snr: OSDPlacement(x: 17, y: 3, width: 12, rightAligned: true, isEnabled: false),
        .artificialHorizon: OSDPlacement(x: 13, y: 7, width: 3),
        .aircraftReference: OSDPlacement(x: 13, y: 7, width: 3),
        .artificialHorizonSidebars: OSDPlacement(x: 13, y: 7, width: 3),
        .compassRibbon: OSDPlacement(x: 10, y: 1, width: 10, isEnabled: false),
        .heading: OSDPlacement(x: 1, y: 3, width: 12, isEnabled: false),
        .throttle: OSDPlacement(x: 17, y: 4, width: 12, rightAligned: true, isEnabled: false),
        .distanceToHome: OSDPlacement(x: 1, y: 11, width: 12, isEnabled: false),
        .flightDistance: OSDPlacement(x: 1, y: 12, width: 12, isEnabled: false),
        .flightTimer: OSDPlacement(x: 17, y: 11, width: 12, rightAligned: true, isEnabled: false),
        .linkWarning: OSDPlacement(x: 9, y: 9, width: 12),
        .staleWarning: OSDPlacement(x: 9, y: 10, width: 12),
        .altitude: OSDPlacement(x: 1, y: 13, width: 12),
        .speed: OSDPlacement(x: 1, y: 14, width: 12),
        .satellites: OSDPlacement(x: 19, y: 13, width: 10, rightAligned: true),
        .flightMode: OSDPlacement(x: 18, y: 14, width: 11, rightAligned: true),
    ])

    static let minimal = layout(horizontalMargin: 0.012, verticalMargin: 0.018, [
        .batteryVoltage: OSDPlacement(x: 0, y: 0, width: 12),
        .linkQuality: OSDPlacement(x: 18, y: 0, width: 12, rightAligned: true),
        .aircraftReference: OSDPlacement(x: 13, y: 7, width: 3),
        .linkWarning: OSDPlacement(x: 9, y: 10, width: 12),
        .staleWarning: OSDPlacement(x: 9, y: 11, width: 12),
        .altitude: OSDPlacement(x: 0, y: 15, width: 12),
        .flightMode: OSDPlacement(x: 18, y: 15, width: 12, rightAligned: true),
    ])

    static let racing = layout(horizontalMargin: 0.012, verticalMargin: 0.018, [
        .batteryVoltage: OSDPlacement(x: 0, y: 0, width: 12),
        .linkQuality: OSDPlacement(x: 18, y: 0, width: 12, rightAligned: true),
        .aircraftReference: OSDPlacement(x: 13, y: 7, width: 3),
        .artificialHorizonSidebars: OSDPlacement(x: 13, y: 7, width: 3),
        .throttle: OSDPlacement(x: 0, y: 1, width: 12),
        .flightTimer: OSDPlacement(x: 18, y: 1, width: 12, rightAligned: true),
        .linkWarning: OSDPlacement(x: 9, y: 10, width: 12),
        .speed: OSDPlacement(x: 0, y: 15, width: 12),
        .flightMode: OSDPlacement(x: 18, y: 15, width: 12, rightAligned: true),
    ])
}
