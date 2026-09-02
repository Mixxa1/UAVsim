import Foundation

enum TelemetryValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case live(Value)
    case stale(Value)
    case unavailable

    var value: Value? {
        switch self {
        case let .live(value), let .stale(value): return value
        case .unavailable: return nil
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    func map<Mapped: Equatable & Sendable>(
        _ transform: (Value) -> Mapped
    ) -> TelemetryValue<Mapped> {
        switch self {
        case let .live(value): return .live(transform(value))
        case let .stale(value): return .stale(transform(value))
        case .unavailable: return .unavailable
        }
    }
}

enum FPVLinkState: String, Codable, CaseIterable, Equatable, Sendable {
    case excellent
    case good
    case degraded
    case critical
    case lost
}

enum FPVControlLinkSeverity: String, Codable, Equatable, Sendable {
    case nominal
    case warning
    case critical
    case lost
}

enum FPVFlightMode: String, Codable, CaseIterable, Equatable, Sendable {
    case acro = "ACRO"
    case angle = "ANGLE"
    case hover = "HOVER"
}

enum FPVFontPreset: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case betaflight
    case clarity
    case mainframe
    case axisfont
    case cleanfont
    case impact
    case xanderFullV3 = "Xander_Full_v3"

    var id: String { rawValue }
    var resourceName: String { rawValue }

    var titleKey: String {
        switch self {
        case .betaflight: return "camera.fpv.osd_font.betaflight"
        case .clarity: return "camera.fpv.osd_font.clarity"
        case .mainframe: return "camera.fpv.osd_font.mainframe"
        case .axisfont: return "camera.fpv.osd_font.axisfont"
        case .cleanfont: return "camera.fpv.osd_font.cleanfont"
        case .impact: return "camera.fpv.osd_font.impact"
        case .xanderFullV3: return "camera.fpv.osd_font.xander_full_v3"
        }
    }
}

/// Semantic MAX7456 glyph locations are not identical across every historical MCM font.
/// In particular, Clarity and the bundled Impact variant use the legacy three-glyph crosshair
/// slots while retaining the standard nine artificial-horizon bar slots. Xander is a generic
/// character font rather than a Betaflight semantic font, so it receives an ASCII-safe fallback.
struct FPVOSDSymbolMap: Equatable, Sendable {
    let artificialHorizonCenterLine: UInt8
    let artificialHorizonCenter: UInt8
    let artificialHorizonCenterLineRight: UInt8
    let artificialHorizonBarStart: UInt8
    let artificialHorizonSymbolCount: Int
    /// Betaflight's artificial-horizon sidebars: a ladder of ticks either side of centre with a
    /// level arrow on each. These slots are filled in every bundled font; UAVsim simply never
    /// drew them, which is why its horizon read as sparser than a real MAX7456 one.
    var sidebarLeftArrow: UInt8 = 0x02
    var sidebarRightArrow: UInt8 = 0x03
    var sidebarTick: UInt8 = 0x13
    /// Betaflight's alternative "aircraft" crosshair: swept wings either side of the centre.
    /// Fonts that carry no such art point these back at their own centre-line glyphs, so the
    /// style stays selectable everywhere and simply looks the same as the default there.
    var aircraftWingLeft: UInt8 = 0x77
    var aircraftWingRight: UInt8 = 0x78

    /// Betaflight's semantic label and unit pictograms. Every bundled font fills all of these —
    /// verified by decoding all seven MCM files — which is what lets one layout keep the icon
    /// look while each font draws it in its own style. Where a font ever leaves one blank, the
    /// composer falls back to a plain text label rather than an invisible cell.
    var rssiIcon: UInt8 = 0x01
    var throttleIcon: UInt8 = 0x04
    var voltIcon: UInt8 = 0x06
    var metreIcon: UInt8 = 0x0C
    var homeIcon: UInt8 = 0x11
    var satelliteLeftIcon: UInt8 = 0x1E
    var satelliteRightIcon: UInt8 = 0x1F
    /// Sixteen headings, 22.5° apart. Index 8 points straight ahead, index 0 straight back.
    var directionArrowStart: UInt8 = 0x60
    var linkQualityIcon: UInt8 = 0x7B
    var altitudeIcon: UInt8 = 0x7F
    /// Seven fill levels, full first.
    var batteryLevelStart: UInt8 = 0x90
    var batteryLevelCount: Int = 7
    var flightTimerIcon: UInt8 = 0x9C
    var metresPerSecondIcon: UInt8 = 0x9F

    static let betaflight = FPVOSDSymbolMap(
        artificialHorizonCenterLine: 0x72,
        artificialHorizonCenter: 0x73,
        artificialHorizonCenterLineRight: 0x74,
        artificialHorizonBarStart: 0x80,
        artificialHorizonSymbolCount: 9
    )

    // Clarity and Impact keep unrelated art at 0x77/0x78, so their aircraft wings fall back to
    // their own centre-line halves rather than drawing an arrow where a wing belongs.
    static let clarity = FPVOSDSymbolMap(
        artificialHorizonCenterLine: 0x26,
        artificialHorizonCenter: 0x7E,
        artificialHorizonCenterLineRight: 0x27,
        artificialHorizonBarStart: 0x80,
        artificialHorizonSymbolCount: 9,
        aircraftWingLeft: 0x26,
        aircraftWingRight: 0x27
    )

    static let asciiFallback = FPVOSDSymbolMap(
        artificialHorizonCenterLine: 0x2D,       // -
        artificialHorizonCenter: 0x2B,           // +
        artificialHorizonCenterLineRight: 0x2D,  // -
        artificialHorizonBarStart: 0x2D,
        artificialHorizonSymbolCount: 1,
        aircraftWingLeft: 0x3E,                  // >
        aircraftWingRight: 0x3C                  // <
    )

    static func forFont(named sourceName: String) -> FPVOSDSymbolMap {
        let normalized = sourceName.lowercased()
        switch normalized {
        case FPVFontPreset.clarity.resourceName.lowercased(),
             FPVFontPreset.impact.resourceName.lowercased():
            return .clarity
        case FPVFontPreset.xanderFullV3.resourceName.lowercased():
            return .asciiFallback
        default:
            return .betaflight
        }
    }

    var artificialHorizonGlyphs: [UInt8] {
        [
            artificialHorizonCenterLine,
            artificialHorizonCenter,
            artificialHorizonCenterLineRight,
        ] + (0..<artificialHorizonSymbolCount).map {
            artificialHorizonBarStart + UInt8($0)
        }
    }
}

struct FPVOSDState: Equatable, Sendable {
    var voltage: TelemetryValue<Double>
    var batteryPercent: TelemetryValue<Double>

    var rssi: TelemetryValue<Double>
    var linkQuality: TelemetryValue<Int>
    var snr: TelemetryValue<Double>

    var altitude: TelemetryValue<Double>
    var speed: TelemetryValue<Double>
    var satellites: TelemetryValue<Int>
    var rollDegrees: TelemetryValue<Double> = .unavailable
    var pitchDegrees: TelemetryValue<Double> = .unavailable
    var headingDegrees: TelemetryValue<Double> = .unavailable
    var throttlePercent: TelemetryValue<Double> = .unavailable
    /// Straight-line range back to the launch point, and the path actually flown since arming.
    var distanceToHome: TelemetryValue<Double> = .unavailable
    /// Where home is relative to the nose, clockwise, so the OSD can point an arrow at it.
    var homeBearingDegrees: TelemetryValue<Double> = .unavailable
    var flightDistance: TelemetryValue<Double> = .unavailable
    var flightSeconds: TelemetryValue<Double> = .unavailable

    var armed: Bool
    var flightMode: FPVFlightMode
    var linkState: FPVLinkState

    static let unavailable = FPVOSDState(
        voltage: .unavailable,
        batteryPercent: .unavailable,
        rssi: .unavailable,
        linkQuality: .unavailable,
        snr: .unavailable,
        altitude: .unavailable,
        speed: .unavailable,
        satellites: .unavailable,
        rollDegrees: .unavailable,
        pitchDegrees: .unavailable,
        armed: false,
        flightMode: .angle,
        linkState: .lost
    )

    var containsStaleData: Bool {
        voltage.isStale
            || batteryPercent.isStale
            || rssi.isStale
            || linkQuality.isStale
            || snr.isStale
            || altitude.isStale
            || speed.isStale
            || satellites.isStale
            || rollDegrees.isStale
            || pitchDegrees.isStale
            || headingDegrees.isStale
            || throttlePercent.isStale
            || distanceToHome.isStale
            || homeBearingDegrees.isStale
            || flightDistance.isStale
            || flightSeconds.isStale
    }
}

struct FPVLocalTelemetrySample: Equatable, Sendable {
    var voltage: Double
    var batteryPercent: Double
    var altitude: Double
    var speed: Double
    var satellites: Int?
    var armed: Bool
    var flightMode: FPVFlightMode
    var rollDegrees: Double = 0
    var pitchDegrees: Double = 0
    var headingDegrees: Double = 0
    var throttlePercent: Double = 0
    var distanceToHome: Double = 0
    var homeBearingDegrees: Double = 0
    var flightDistance: Double = 0
    var flightSeconds: Double = 0
}

/// A UI-independent projection of the physical CONTROL stream. The application maps RF core
/// output into this value; the OSD resolver never invents RSSI/LQ/SNR on its own.
struct FPVRadioLinkSample: Equatable, Sendable {
    var rssiDBm: Double
    var snrDB: Double
    var packetErrorRate: Double
    var smoothedPacketLoss: Double
    var secondsSinceLastDelivery: Double
    var severity: FPVControlLinkSeverity

    var calculatedLinkQuality: Int {
        guard severity != .lost else { return 0 }
        let packetLoss = min(1, max(packetErrorRate, smoothedPacketLoss))
        let agePenalty = min(1, max(0, secondsSinceLastDelivery - 0.05) / 0.95)
        let fraction = min(1 - packetLoss, 1 - agePenalty)
        return min(100, max(0, Int((fraction * 100).rounded())))
    }
}

struct FPVOSDStateResolver: Sendable {
    var staleTimeoutSeconds: Double = 2

    private var lastLiveTelemetry: FPVLocalTelemetrySample?
    private var lastLiveRadio: FPVRadioLinkSample?
    private var linkLossBeganAt: TimeInterval?

    init(staleTimeoutSeconds: Double = 2) {
        self.staleTimeoutSeconds = max(0, staleTimeoutSeconds)
    }

    mutating func reset() {
        lastLiveTelemetry = nil
        lastLiveRadio = nil
        linkLossBeganAt = nil
    }

    mutating func resolve(
        telemetry: FPVLocalTelemetrySample,
        radio: FPVRadioLinkSample?,
        timestamp: TimeInterval
    ) -> FPVOSDState {
        guard let radio, radio.severity != .lost else {
            return resolveLost(telemetry: telemetry, timestamp: timestamp)
        }

        linkLossBeganAt = nil
        lastLiveTelemetry = telemetry
        lastLiveRadio = radio
        let lq = radio.calculatedLinkQuality
        return FPVOSDState(
            voltage: .live(telemetry.voltage),
            batteryPercent: .live(telemetry.batteryPercent),
            rssi: .live(radio.rssiDBm),
            linkQuality: .live(lq),
            snr: .live(radio.snrDB),
            altitude: .live(telemetry.altitude),
            speed: .live(telemetry.speed),
            satellites: telemetry.satellites.map(TelemetryValue.live) ?? .unavailable,
            rollDegrees: .live(telemetry.rollDegrees),
            pitchDegrees: .live(telemetry.pitchDegrees),
            headingDegrees: .live(telemetry.headingDegrees),
            throttlePercent: .live(telemetry.throttlePercent),
            distanceToHome: .live(telemetry.distanceToHome),
            homeBearingDegrees: .live(telemetry.homeBearingDegrees),
            flightDistance: .live(telemetry.flightDistance),
            flightSeconds: .live(telemetry.flightSeconds),
            armed: telemetry.armed,
            flightMode: telemetry.flightMode,
            linkState: Self.linkState(lq: lq, severity: radio.severity)
        )
    }

    private mutating func resolveLost(
        telemetry: FPVLocalTelemetrySample,
        timestamp: TimeInterval
    ) -> FPVOSDState {
        if linkLossBeganAt == nil {
            linkLossBeganAt = timestamp
        }
        let age = max(0, timestamp - (linkLossBeganAt ?? timestamp))
        guard age < staleTimeoutSeconds, let held = lastLiveTelemetry else {
            return FPVOSDState(
                voltage: .unavailable,
                batteryPercent: .unavailable,
                rssi: .unavailable,
                linkQuality: .unavailable,
                snr: .unavailable,
                altitude: .unavailable,
                speed: .unavailable,
                satellites: .unavailable,
                rollDegrees: .unavailable,
                pitchDegrees: .unavailable,
                armed: telemetry.armed,
                flightMode: telemetry.flightMode,
                linkState: .lost
            )
        }

        // The last complete OSD data remains on screen briefly, like a real receiver retaining
        // its last decoded values. LQ drops to zero immediately; after timeout every RF/flight
        // value becomes unavailable instead of pretending to remain fresh forever.
        return FPVOSDState(
            voltage: .stale(held.voltage),
            batteryPercent: .stale(held.batteryPercent),
            rssi: lastLiveRadio.map { .stale($0.rssiDBm) } ?? .unavailable,
            linkQuality: .live(0),
            snr: lastLiveRadio.map { .stale($0.snrDB) } ?? .unavailable,
            altitude: .stale(held.altitude),
            speed: .stale(held.speed),
            satellites: held.satellites.map(TelemetryValue.stale) ?? .unavailable,
            rollDegrees: .stale(held.rollDegrees),
            pitchDegrees: .stale(held.pitchDegrees),
            headingDegrees: .stale(held.headingDegrees),
            throttlePercent: .stale(held.throttlePercent),
            distanceToHome: .stale(held.distanceToHome),
            homeBearingDegrees: .stale(held.homeBearingDegrees),
            flightDistance: .stale(held.flightDistance),
            flightSeconds: .stale(held.flightSeconds),
            armed: telemetry.armed,
            flightMode: telemetry.flightMode,
            linkState: .lost
        )
    }

    static func linkState(lq: Int, severity: FPVControlLinkSeverity) -> FPVLinkState {
        if severity == .lost || lq <= 0 { return .lost }
        if severity == .critical || lq < 25 { return .critical }
        if severity == .warning || lq < 60 { return .degraded }
        if lq < 90 { return .good }
        return .excellent
    }
}

struct OSDCell: Equatable, Sendable {
    var glyph: UInt8
    var x: Int
    var y: Int
}

struct OSDGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int
    private(set) var glyphs: [UInt8]

    init(columns: Int = 30, rows: Int = 16, emptyGlyph: UInt8 = 32) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        glyphs = Array(repeating: emptyGlyph, count: self.columns * self.rows)
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get {
            guard contains(x: x, y: y) else { return 32 }
            return glyphs[y * columns + x]
        }
        set {
            guard contains(x: x, y: y) else { return }
            glyphs[y * columns + x] = newValue
        }
    }

    mutating func write(_ text: String, x: Int, y: Int, width: Int? = nil, rightAligned: Bool = false) {
        write(
            glyphs: text.utf8.map { $0 < 128 ? $0 : 63 },
            x: x,
            y: y,
            width: width,
            rightAligned: rightAligned
        )
    }

    /// Writes an explicit glyph run, so a label can be a single MAX7456 pictogram rather than
    /// spelled-out ASCII.
    mutating func write(
        glyphs run: [UInt8],
        x: Int,
        y: Int,
        width: Int? = nil,
        rightAligned: Bool = false
    ) {
        guard y >= 0, y < rows else { return }
        let availableWidth = max(0, min(width ?? run.count, columns - max(0, x)))
        guard availableWidth > 0 else { return }
        let clipped = Array(run.prefix(availableWidth))
        let startX = rightAligned ? x + max(0, availableWidth - clipped.count) : x
        for (offset, glyph) in clipped.enumerated() {
            self[startX + offset, y] = glyph
        }
    }

    var cells: [OSDCell] {
        glyphs.enumerated().map { index, glyph in
            OSDCell(glyph: glyph, x: index % columns, y: index / columns)
        }
    }

    private func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < columns && y >= 0 && y < rows
    }
}

struct OSDPosition: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var rightAligned: Bool = false
}
