import Foundation

struct RFPacketDeliveryState: Equatable, Sendable {
    var nextSequence: UInt64 = 0
    var packetsGenerated: UInt64 = 0
    var packetsDelivered: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var consecutiveDroppedPackets: Int = 0
    var secondsSinceLastDelivery: Double = 0
    var packetAccumulator: Double = 0
    var lastDeliveredSequence: UInt64?
    var smoothedPacketLoss: Double = 0
    var packetsExpired: UInt64 = 0
    var transmissionAttempts: UInt64 = 0
    var retryAttempts: UInt64 = 0
    var packetsRecoveredByRetry: UInt64 = 0
    var bytesDelivered: UInt64 = 0
    var effectiveThroughputBPS: Double = 0
    var meanQueueDelaySeconds: Double = 0
    var selectedMCS: RFModulationCodingScheme = .robust
    var queueCapacity: Int = 0
    var transmissionBitAccumulator: Double = 0
    var transportClockSeconds: Double = 0
    var queuedPackets: [RFQueuedPacket] = []

    static let initial = RFPacketDeliveryState()

    var deliveryRatio: Double {
        guard packetsGenerated > 0 else { return 1 }
        return Double(packetsDelivered) / Double(packetsGenerated)
    }

    var queueDepth: Int { queuedPackets.count }

    var retryRecoveryRatio: Double {
        guard retryAttempts > 0 else { return 0 }
        return Double(packetsRecoveredByRetry) / Double(retryAttempts)
    }
}

enum RFModulationCodingScheme: String, Codable, CaseIterable, Equatable, Sendable {
    case robust
    case balanced
    case highThroughput
}

struct RFMCSProfile: Equatable, Sendable {
    var scheme: RFModulationCodingScheme
    var requiredSINRDB: Double
    var bitrateMultiplier: Double

    static let robust = RFMCSProfile(
        scheme: .robust,
        requiredSINRDB: 2,
        bitrateMultiplier: 0.45
    )
    static let balanced = RFMCSProfile(
        scheme: .balanced,
        requiredSINRDB: 8,
        bitrateMultiplier: 0.72
    )
    static let highThroughput = RFMCSProfile(
        scheme: .highThroughput,
        requiredSINRDB: 15,
        bitrateMultiplier: 1.0
    )
}

struct RFAdaptiveMCSController {
    func select(for evaluation: RFLinkEvaluation) -> RFMCSProfile {
        if evaluation.rf.sinrDB >= 18, evaluation.rf.linkMarginDB >= 12 {
            return .highThroughput
        }
        if evaluation.rf.sinrDB >= 10, evaluation.rf.linkMarginDB >= 5 {
            return .balanced
        }
        return .robust
    }

    func packetErrorRate(
        for evaluation: RFLinkEvaluation,
        using profile: RFMCSProfile
    ) -> Double {
        let sinrMargin = evaluation.rf.sinrDB - profile.requiredSINRDB
        let governingMargin = min(evaluation.rf.linkMarginDB, sinrMargin)
        let mcsErrorRate = 1.0 / (1.0 + exp(0.9 * governingMargin))
        return min(1, max(evaluation.quality.packetErrorRate, mcsErrorRate))
    }
}

struct RFPacketTrafficProfile: Equatable, Sendable {
    var packetsPerSecond: Double
    var packetSizeBytes: Int
    var queueCapacity: Int
    var packetTTLSeconds: Double
    var retryLimit: Int

    static func profile(for kind: LogicalLinkKind) -> RFPacketTrafficProfile {
        switch kind {
        case .control:
            return RFPacketTrafficProfile(
                packetsPerSecond: 50,
                packetSizeBytes: 48,
                queueCapacity: 64,
                packetTTLSeconds: 1.0,
                retryLimit: 2
            )
        case .video:
            return RFPacketTrafficProfile(
                packetsPerSecond: 60,
                packetSizeBytes: 1_200,
                queueCapacity: 180,
                packetTTLSeconds: 0.35,
                retryLimit: 1
            )
        case .telemetry:
            return RFPacketTrafficProfile(
                packetsPerSecond: 10,
                packetSizeBytes: 128,
                queueCapacity: 80,
                packetTTLSeconds: 3.0,
                retryLimit: 2
            )
        case .payloadData:
            return RFPacketTrafficProfile(
                packetsPerSecond: 20,
                packetSizeBytes: 512,
                queueCapacity: 120,
                packetTTLSeconds: 5.0,
                retryLimit: 3
            )
        }
    }

    func applying(_ policy: RFQoSLinkPolicy) -> RFPacketTrafficProfile {
        RFPacketTrafficProfile(
            packetsPerSecond: policy.packetsPerSecond ?? packetsPerSecond,
            packetSizeBytes: policy.packetSizeBytes ?? packetSizeBytes,
            queueCapacity: policy.queueCapacity ?? queueCapacity,
            packetTTLSeconds: policy.packetTTLSeconds ?? packetTTLSeconds,
            retryLimit: policy.retryLimit ?? retryLimit
        )
    }
}

extension RFQoSConfiguration {
    func trafficProfile(for kind: LogicalLinkKind) -> RFPacketTrafficProfile {
        RFPacketTrafficProfile.profile(for: kind).applying(policy(for: kind))
    }
}

struct RFQueuedPacket: Equatable, Sendable {
    var sequence: UInt64
    var generatedAtSeconds: Double
    var attemptsMade: Int = 0
}

enum RFControlLinkAvailability: String, Codable, CaseIterable, Equatable, Sendable {
    case nominal
    case warning
    case critical
    case lost
}

struct RFShadowComparisonStatistics: Equatable, Sendable {
    var sampleCount: UInt64 = 0
    var matchingSampleCount: UInt64 = 0
    var physicalMoreSevereCount: UInt64 = 0
    var legacyMoreSevereCount: UInt64 = 0

    static let initial = RFShadowComparisonStatistics()

    var agreementRatio: Double {
        guard sampleCount > 0 else { return 1 }
        return Double(matchingSampleCount) / Double(sampleCount)
    }

    mutating func record(
        legacy: RFControlLinkAvailability,
        physical: RFControlLinkAvailability
    ) {
        sampleCount &+= 1
        if legacy == physical {
            matchingSampleCount &+= 1
        } else if physical.severity > legacy.severity {
            physicalMoreSevereCount &+= 1
        } else {
            legacyMoreSevereCount &+= 1
        }
    }
}

private extension RFControlLinkAvailability {
    var severity: Int {
        switch self {
        case .nominal: return 0
        case .warning: return 1
        case .critical: return 2
        case .lost: return 3
        }
    }
}

struct RFPacketDeliveryEngine {
    var mcsController = RFAdaptiveMCSController()

    func advance(
        _ current: RFPacketDeliveryState,
        linkID: String,
        packetRateHz: Double,
        deltaTime: Double,
        evaluation: RFLinkEvaluation
    ) -> RFPacketDeliveryState {
        advance(
            current,
            linkID: linkID,
            traffic: RFPacketTrafficProfile(
                packetsPerSecond: packetRateHz,
                packetSizeBytes: 1,
                queueCapacity: 10_000,
                packetTTLSeconds: 1.0,
                retryLimit: 0
            ),
            deltaTime: deltaTime,
            evaluation: evaluation
        )
    }

    func advance(
        _ current: RFPacketDeliveryState,
        linkID: String,
        linkKind: LogicalLinkKind,
        deltaTime: Double,
        evaluation: RFLinkEvaluation
    ) -> RFPacketDeliveryState {
        advance(
            current,
            linkID: linkID,
            traffic: RFPacketTrafficProfile.profile(for: linkKind),
            deltaTime: deltaTime,
            evaluation: evaluation
        )
    }

    func advance(
        _ current: RFPacketDeliveryState,
        linkID: String,
        traffic: RFPacketTrafficProfile,
        deltaTime: Double,
        evaluation: RFLinkEvaluation,
        transmissionBudgetBits: Double? = nil
    ) -> RFPacketDeliveryState {
        var next = current
        guard deltaTime.isFinite, deltaTime > 0,
              traffic.packetsPerSecond.isFinite, traffic.packetsPerSecond > 0,
              traffic.packetSizeBytes > 0,
              traffic.queueCapacity > 0 else {
            return next
        }

        let startTime = next.transportClockSeconds
        next.transportClockSeconds += deltaTime
        next.secondsSinceLastDelivery += deltaTime
        next.queueCapacity = traffic.queueCapacity
        let mcs = mcsController.select(for: evaluation)
        next.selectedMCS = mcs.scheme

        var finalizedThisStep = 0
        var droppedThisStep = 0
        while let oldest = next.queuedPackets.first,
              next.transportClockSeconds - oldest.generatedAtSeconds > traffic.packetTTLSeconds {
            next.queuedPackets.removeFirst()
            next.packetsDropped &+= 1
            next.packetsExpired &+= 1
            next.consecutiveDroppedPackets += 1
            finalizedThisStep += 1
            droppedThisStep += 1
        }

        next.packetAccumulator += deltaTime * traffic.packetsPerSecond
        let generatedThisStep = min(10_000, Int(next.packetAccumulator.rounded(.down)))
        next.packetAccumulator -= Double(generatedThisStep)
        for packetIndex in 0..<generatedThisStep {
            let sequence = next.nextSequence
            next.nextSequence &+= 1
            next.packetsGenerated &+= 1
            guard next.queuedPackets.count < traffic.queueCapacity else {
                next.packetsDropped &+= 1
                next.consecutiveDroppedPackets += 1
                finalizedThisStep += 1
                droppedThisStep += 1
                continue
            }
            let generatedAt = startTime
                + deltaTime * Double(packetIndex + 1) / Double(max(1, generatedThisStep))
            next.queuedPackets.append(RFQueuedPacket(
                sequence: sequence,
                generatedAtSeconds: generatedAt
            ))
        }

        let availableBitrateBPS = max(0, evaluation.quality.effectiveBitrateBps)
            * mcs.bitrateMultiplier
        let bitsPerAttempt = Double(traffic.packetSizeBytes * 8 + 64)
        let grantedBits = transmissionBudgetBits.map { max(0, $0) }
            ?? availableBitrateBPS * deltaTime
        next.transmissionBitAccumulator += grantedBits
        next.transmissionBitAccumulator = min(
            next.transmissionBitAccumulator,
            max(
                bitsPerAttempt,
                transmissionBudgetBits == nil
                    ? availableBitrateBPS * 2.0
                    : grantedBits * 2.0
            )
        )
        let packetErrorRate = mcsController.packetErrorRate(for: evaluation, using: mcs)
        var deliveredBytesThisStep = 0

        while !next.queuedPackets.isEmpty,
              next.transmissionBitAccumulator >= bitsPerAttempt {
            next.transmissionBitAccumulator -= bitsPerAttempt
            var packet = next.queuedPackets.removeFirst()
            let isRetry = packet.attemptsMade > 0
            next.transmissionAttempts &+= 1
            if isRetry { next.retryAttempts &+= 1 }

            let sample = deterministicUnitSample(
                linkID: linkID,
                sequence: packet.sequence,
                attempt: packet.attemptsMade,
                scheme: mcs.scheme
            )
            if sample >= packetErrorRate {
                next.packetsDelivered &+= 1
                next.consecutiveDroppedPackets = 0
                next.lastDeliveredSequence = packet.sequence
                next.bytesDelivered &+= UInt64(traffic.packetSizeBytes)
                if isRetry { next.packetsRecoveredByRetry &+= 1 }
                deliveredBytesThisStep += traffic.packetSizeBytes
                finalizedThisStep += 1
                next.secondsSinceLastDelivery = 0
                let queueDelay = max(0, next.transportClockSeconds - packet.generatedAtSeconds)
                next.meanQueueDelaySeconds += (
                    queueDelay - next.meanQueueDelaySeconds
                ) / Double(next.packetsDelivered)
            } else if packet.attemptsMade < traffic.retryLimit {
                packet.attemptsMade += 1
                next.queuedPackets.insert(packet, at: 0)
            } else {
                next.packetsDropped &+= 1
                next.consecutiveDroppedPackets += 1
                finalizedThisStep += 1
                droppedThisStep += 1
            }
        }

        if finalizedThisStep > 0 {
            let stepLoss = Double(droppedThisStep) / Double(finalizedThisStep)
            next.smoothedPacketLoss += (stepLoss - next.smoothedPacketLoss) * 0.2
        }
        let instantaneousThroughput = Double(deliveredBytesThisStep * 8) / deltaTime
        next.effectiveThroughputBPS += (
            instantaneousThroughput - next.effectiveThroughputBPS
        ) * 0.2
        return next
    }

    /// Stable across processes and test runs; unlike Swift.Hasher, this seed is not randomized.
    private func deterministicUnitSample(
        linkID: String,
        sequence: UInt64,
        attempt: Int,
        scheme: RFModulationCodingScheme
    ) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (linkID + scheme.rawValue).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        var value = hash
            ^ (sequence &* 0x9E37_79B9_7F4A_7C15)
            ^ (UInt64(attempt) &* 0xD6E8_FEB8_6659_FD93)
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}

struct RFControlLinkAvailabilityPolicy {
    var warningCommandAgeSeconds: Double = 0.15
    var criticalCommandAgeSeconds: Double = 0.45
    var lostCommandAgeSeconds: Double = 1.0

    func evaluate(
        delivery: RFPacketDeliveryState,
        link: RFLinkEvaluation
    ) -> RFControlLinkAvailability {
        let age = max(0, delivery.secondsSinceLastDelivery)
        if age >= lostCommandAgeSeconds {
            return .lost
        }
        if age >= criticalCommandAgeSeconds
            || link.quality.health == .lost
            || link.quality.health == .critical {
            return .critical
        }
        if age >= warningCommandAgeSeconds {
            return .warning
        }
        if link.quality.health == .degraded || delivery.smoothedPacketLoss > 0.05 {
            return .warning
        }
        return .nominal
    }
}

enum RFPacketRateProfile {
    static func packetsPerSecond(for kind: LogicalLinkKind) -> Double {
        switch kind {
        case .control: return 50
        case .video: return 60
        case .telemetry: return 10
        case .payloadData: return 20
        }
    }
}
