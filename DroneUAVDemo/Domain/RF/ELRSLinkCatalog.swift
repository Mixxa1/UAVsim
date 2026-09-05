import Foundation

/// ExpressLRS: the control link, described by what its radio actually does.
///
/// Every figure below is taken from the ExpressLRS firmware's own air-rate tables
/// (`src/src/common.cpp`, `ExpressLRS_AirRateConfig` and `ExpressLRS_AirRateRFperf`) rather than
/// from a review or a forum post, and the sensitivities agree with the published signal-health
/// table. The 900 MHz set is what an SX127x runs, the 2.4 GHz set what an SX1280 runs — the two
/// chips the overwhelming majority of hardware uses.
///
/// The point of modelling this at all is one trade-off: **packet rate is bought with sensitivity**.
/// On 900 MHz the span is 25 Hz at -123 dBm to 200 Hz at -112 dBm; on 2.4 GHz it is 50 Hz at
/// -115 dBm to 1000 Hz at -104 dBm. Eleven decibels is a factor of 3.5 in free-space range, and
/// choosing the band on top of that adds the 8.5 dB of path loss between 915 MHz and 2.44 GHz. So
/// the operator picking "1000 Hz because it feels sharper" is really giving up most of the range,
/// and the simulator can show that instead of asserting it.
enum ELRSBand: String, Codable, CaseIterable, Hashable, Sendable {
    case mhz900
    case ghz24

    /// Centre frequency used for the link budget, Hz.
    ///
    /// Both bands hop across a set of channels; a single representative centre is enough for path
    /// loss, which changes by less than 0.3 dB across either band's width.
    var centerFrequencyHz: Double {
        switch self {
        case .mhz900: return 915_000_000
        case .ghz24: return 2_440_000_000
        }
    }

    var titleKey: String { "rf.elrs.band.\(rawValue)" }
}

/// Modulation the mode runs. LoRa spreads the signal and buys processing gain; FLRC is a fast
/// coded FSK with none of it, which is exactly why the 1000 Hz modes sit at the bottom of the
/// sensitivity table.
enum ELRSModulation: String, Hashable, Sendable {
    case lora
    case flrc
}

/// How often the receiver is allowed to answer, as one telemetry packet per N control packets.
///
/// This is a time-division split of one channel, not a second radio: telemetry occupies slots the
/// handset is listening in. Modelling it as an independent transmitter is what used to jam the
/// control link on 900 MHz.
enum ELRSTelemetryRatio: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case off
    case ratio1to128
    case ratio1to64
    case ratio1to32
    case ratio1to16
    case ratio1to8
    case ratio1to4
    case ratio1to2

    var id: String { rawValue }

    /// N in "one in N". Nil when telemetry is off.
    var denominator: Int? {
        switch self {
        case .off: return nil
        case .ratio1to128: return 128
        case .ratio1to64: return 64
        case .ratio1to32: return 32
        case .ratio1to16: return 16
        case .ratio1to8: return 8
        case .ratio1to4: return 4
        case .ratio1to2: return 2
        }
    }

    /// Fraction of air time the downlink occupies. This is the duty cycle of the air unit's
    /// transmitter, and it is what makes telemetry cost uplink slots rather than being free.
    var dutyCycle: Double {
        guard let denominator else { return 0 }
        return 1.0 / Double(denominator)
    }

    var displayName: String {
        guard let denominator else { return "Off" }
        return "1:\(denominator)"
    }
}

/// One selectable air rate.
struct ELRSMode: Identifiable, Hashable, Sendable {
    let id: String
    let band: ELRSBand
    let modulation: ELRSModulation
    /// Control packets per second seen by the flight controller.
    let packetRateHz: Double
    /// Occupied bandwidth, Hz — the noise floor is computed from it.
    let bandwidthHz: Double
    /// Receiver sensitivity, dBm. Straight from the firmware's RF performance table.
    let sensitivityDBm: Double
    /// The telemetry ratio the firmware defaults this rate to.
    let defaultTelemetryRatio: ELRSTelemetryRatio
    /// Interval between packets, microseconds, as the firmware states it.
    let packetIntervalMicroseconds: Double
    /// How many channels are carried over the air. The 8-channel modes trade payload for rate.
    let channelCount: Int
    /// How many times each packet is repeated (DVDA). One for ordinary modes.
    let packetRepeats: Int

    /// LoRa spreading factor, where the mode uses LoRa. Nil for FLRC.
    let spreadingFactor: Int?

    /// One-way air latency floor, milliseconds: a command waits for the next slot.
    ///
    /// Deliberately only the slot wait. It is not fed into control authority anywhere — the
    /// command-latency experiment in the RF work was reverted for breaking the aircraft, and this
    /// is a number to display, not a delay to apply.
    var slotLatencyMS: Double {
        packetIntervalMicroseconds / 1000.0
    }

    /// Distance at which the received power falls to this mode's sensitivity, metres.
    ///
    /// Free space only: no terrain, no obstruction, no fade margin. A ceiling rather than a
    /// prediction — what it is for is showing the operator the *ratio* between one air rate and
    /// another, which is the decision they are actually making.
    func freeSpaceRangeM(txPowerDBm: Double, antennaGainDBi: Double = 4) -> Double {
        let budgetDB = txPowerDBm + antennaGainDBi - sensitivityDBm
        let exponent = (budgetDB - 20 * log10(band.centerFrequencyHz) + 147.55) / 20
        return pow(10, exponent)
    }

    var displayName: String {
        let rate = packetRateHz.rounded() == packetRateHz
            ? String(format: "%.0f Hz", packetRateHz)
            : String(format: "%.0f Hz", packetRateHz)
        let suffix: String
        switch (channelCount, packetRepeats) {
        case (8, _): suffix = " 8ch"
        case (_, let repeats) where repeats > 1: suffix = " DVDA"
        default: suffix = ""
        }
        return "\(rate)\(suffix) \(modulation == .flrc ? "FLRC" : "LoRa")"
    }
}

enum ELRSLinkCatalog {
    /// 900 MHz, SX127x. LoRa at 500 kHz throughout.
    static let mhz900Modes: [ELRSMode] = [
        ELRSMode(
            id: "elrs.900.200hz",
            band: .mhz900,
            modulation: .lora,
            packetRateHz: 200,
            bandwidthHz: 500_000,
            sensitivityDBm: -112,
            defaultTelemetryRatio: .ratio1to64,
            packetIntervalMicroseconds: 5000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 6
        ),
        ELRSMode(
            id: "elrs.900.100hz.8ch",
            band: .mhz900,
            modulation: .lora,
            packetRateHz: 100,
            bandwidthHz: 500_000,
            sensitivityDBm: -112,
            defaultTelemetryRatio: .ratio1to32,
            packetIntervalMicroseconds: 10000,
            channelCount: 8,
            packetRepeats: 1,
            spreadingFactor: 6
        ),
        ELRSMode(
            id: "elrs.900.100hz",
            band: .mhz900,
            modulation: .lora,
            packetRateHz: 100,
            bandwidthHz: 500_000,
            sensitivityDBm: -117,
            defaultTelemetryRatio: .ratio1to32,
            packetIntervalMicroseconds: 10000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 7
        ),
        ELRSMode(
            id: "elrs.900.50hz",
            band: .mhz900,
            modulation: .lora,
            packetRateHz: 50,
            bandwidthHz: 500_000,
            sensitivityDBm: -120,
            defaultTelemetryRatio: .ratio1to16,
            packetIntervalMicroseconds: 20000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 8
        ),
        ELRSMode(
            id: "elrs.900.25hz",
            band: .mhz900,
            modulation: .lora,
            packetRateHz: 25,
            bandwidthHz: 500_000,
            sensitivityDBm: -123,
            defaultTelemetryRatio: .ratio1to8,
            packetIntervalMicroseconds: 40000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 9
        ),
        ELRSMode(
            id: "elrs.900.50hz.dvda",
            band: .mhz900,
            modulation: .lora,
            packetRateHz: 50,
            bandwidthHz: 500_000,
            sensitivityDBm: -112,
            defaultTelemetryRatio: .ratio1to64,
            packetIntervalMicroseconds: 5000,
            channelCount: 4,
            packetRepeats: 4,
            spreadingFactor: 6
        ),
    ]

    /// 2.4 GHz, SX1280. FLRC at 0.6 MHz, LoRa at 800 kHz.
    static let ghz24Modes: [ELRSMode] = [
        ELRSMode(
            id: "elrs.2g4.1000hz",
            band: .ghz24,
            modulation: .flrc,
            packetRateHz: 1000,
            bandwidthHz: 600_000,
            sensitivityDBm: -104,
            defaultTelemetryRatio: .ratio1to128,
            packetIntervalMicroseconds: 1000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: nil
        ),
        ELRSMode(
            id: "elrs.2g4.500hz.flrc",
            band: .ghz24,
            modulation: .flrc,
            packetRateHz: 500,
            bandwidthHz: 600_000,
            sensitivityDBm: -104,
            defaultTelemetryRatio: .ratio1to128,
            packetIntervalMicroseconds: 2000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: nil
        ),
        ELRSMode(
            id: "elrs.2g4.500hz",
            band: .ghz24,
            modulation: .lora,
            packetRateHz: 500,
            bandwidthHz: 800_000,
            sensitivityDBm: -105,
            defaultTelemetryRatio: .ratio1to128,
            packetIntervalMicroseconds: 2000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 5
        ),
        ELRSMode(
            id: "elrs.2g4.333hz.8ch",
            band: .ghz24,
            modulation: .lora,
            packetRateHz: 333,
            bandwidthHz: 800_000,
            sensitivityDBm: -105,
            defaultTelemetryRatio: .ratio1to128,
            packetIntervalMicroseconds: 3003,
            channelCount: 8,
            packetRepeats: 1,
            spreadingFactor: 5
        ),
        ELRSMode(
            id: "elrs.2g4.250hz",
            band: .ghz24,
            modulation: .lora,
            packetRateHz: 250,
            bandwidthHz: 800_000,
            sensitivityDBm: -108,
            defaultTelemetryRatio: .ratio1to64,
            packetIntervalMicroseconds: 4000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 6
        ),
        ELRSMode(
            id: "elrs.2g4.150hz",
            band: .ghz24,
            modulation: .lora,
            packetRateHz: 150,
            bandwidthHz: 800_000,
            sensitivityDBm: -112,
            defaultTelemetryRatio: .ratio1to32,
            packetIntervalMicroseconds: 6666,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 7
        ),
        ELRSMode(
            id: "elrs.2g4.100hz.8ch",
            band: .ghz24,
            modulation: .lora,
            packetRateHz: 100,
            bandwidthHz: 800_000,
            sensitivityDBm: -112,
            defaultTelemetryRatio: .ratio1to32,
            packetIntervalMicroseconds: 10000,
            channelCount: 8,
            packetRepeats: 1,
            spreadingFactor: 7
        ),
        ELRSMode(
            id: "elrs.2g4.50hz",
            band: .ghz24,
            modulation: .lora,
            packetRateHz: 50,
            bandwidthHz: 800_000,
            sensitivityDBm: -115,
            defaultTelemetryRatio: .ratio1to16,
            packetIntervalMicroseconds: 20000,
            channelCount: 4,
            packetRepeats: 1,
            spreadingFactor: 8
        ),
    ]

    static let allModes: [ELRSMode] = mhz900Modes + ghz24Modes

    static func modes(for band: ELRSBand) -> [ELRSMode] {
        switch band {
        case .mhz900: return mhz900Modes
        case .ghz24: return ghz24Modes
        }
    }

    static func mode(id: String) -> ELRSMode? {
        allModes.first { $0.id == id }
    }

    /// What a handset can be set to, dBm. ExpressLRS steps in the familiar 10 mW to 2 W ladder.
    static let transmitPowerLevelsDBm: [Double] = [10, 14, 17, 20, 24, 27, 30, 33]

    /// Sensible defaults: the rate most people fly on each band.
    static func defaultMode(for band: ELRSBand) -> ELRSMode {
        switch band {
        case .mhz900:
            return mode(id: "elrs.900.100hz") ?? mhz900Modes[0]
        case .ghz24:
            return mode(id: "elrs.2g4.250hz") ?? ghz24Modes[0]
        }
    }
}

/// What the operator has set on the link.
struct ELRSConfiguration: Codable, Hashable, Sendable {
    var modeID: String
    var telemetryRatio: ELRSTelemetryRatio
    var transmitPowerDBm: Double
    /// Air-unit transmit power, dBm. Far below the handset's — a receiver runs on the aircraft's
    /// budget — which is why telemetry drops out well before control does.
    var airTransmitPowerDBm: Double

    var mode: ELRSMode {
        ELRSLinkCatalog.mode(id: modeID) ?? ELRSLinkCatalog.defaultMode(for: .ghz24)
    }

    static let `default` = ELRSConfiguration(
        modeID: ELRSLinkCatalog.defaultMode(for: .ghz24).id,
        telemetryRatio: ELRSLinkCatalog.defaultMode(for: .ghz24).defaultTelemetryRatio,
        transmitPowerDBm: 20,
        airTransmitPowerDBm: 10
    )
}
