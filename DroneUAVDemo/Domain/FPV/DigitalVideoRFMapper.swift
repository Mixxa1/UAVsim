import Foundation

/// Decoder/delivery controls for a packet video link. None of these values represents an analog
/// waveform: degradation is expressed only as lost detail, stale regions, dropped frames and a
/// retained frame.
struct DigitalVideoParameters: Equatable, Sendable {
    var detailScale: Double
    var targetFrameRateFPS: Double
    var packetArtifactIntensity: Double
    var staleRegionIntensity: Double
    var frameDropProbability: Double
    var isFrozen: Bool

    static let clean = DigitalVideoParameters(
        detailScale: 1,
        targetFrameRateFPS: 60,
        packetArtifactIntensity: 0,
        staleRegionIntensity: 0,
        frameDropProbability: 0,
        isFrozen: false
    )

    static func clean(frameRateFPS: Double) -> DigitalVideoParameters {
        var value = clean
        value.targetFrameRateFPS = max(1, frameRateFPS)
        return value
    }

    var requiresPostProcessing: Bool {
        isFrozen
            || detailScale < 0.999
            || packetArtifactIntensity > 0.001
            || staleRegionIntensity > 0.001
            || frameDropProbability > 0.001
    }
}

struct DigitalVideoRFMapper: Sendable {
    func parameters(
        for state: RFVideoPresentationState,
        nominalBitrateBPS: Double,
        linkPreset: RFVideoLinkPreset
    ) -> DigitalVideoParameters {
        let bitrateRatio = clamp(
            state.effectiveBitrateBPS / max(1, nominalBitrateBPS)
        )
        // Adaptive packet video spends bandwidth first, then cadence, to preserve a coherent
        // picture. Visible decoder damage starts later on continuity-biased enterprise/BVLOS
        // links than on a generic low-buffer consumer decoder.
        let bitrateStress = clamp((0.96 - bitrateRatio) / 0.86)
        let rawPacketStress = clamp(state.digitalArtifactIntensity)
        let continuity = clamp(linkPreset.continuityBias)
        let artifactDeadZone = 0.025 + continuity * 0.075
        let packetStress = clamp(
            (rawPacketStress - artifactDeadZone) / max(0.01, 1 - artifactDeadZone)
        )

        let healthFloor: Double
        switch state.health {
        case .healthy: healthFloor = 0
        case .degraded: healthFloor = 0.16
        case .critical: healthFloor = 0.52
        case .lost: healthFloor = 1
        }
        let deliveryStress = max(healthFloor, packetStress, bitrateStress)

        let detailLoss = pow(bitrateStress, 0.76)
        let detailScale = max(
            linkPreset.minimumDetailScale,
            1 - detailLoss * (1 - linkPreset.minimumDetailScale)
        )
        let cadenceStress = clamp((bitrateStress - 0.18) / 0.82)
        let targetFrameRate = linkPreset.nominalFrameRateFPS
            - cadenceStress
                * (linkPreset.nominalFrameRateFPS - linkPreset.minimumAdaptiveFrameRateFPS)

        // A healthy digital link is visually clean. Do not leak low-level RF noise into pixels.
        if !state.isFrozen,
           state.health == .healthy,
           bitrateRatio >= 0.94,
           rawPacketStress < artifactDeadZone {
            return .clean(frameRateFPS: linkPreset.nominalFrameRateFPS)
        }

        let frameDropProbability: Double
        switch state.health {
        case .healthy:
            frameDropProbability = 0
        case .degraded:
            frameDropProbability = max(0, deliveryStress - 0.45) * (0.08 - continuity * 0.05)
        case .critical:
            frameDropProbability = 0.04 + deliveryStress * (0.38 - continuity * 0.20)
        case .lost:
            frameDropProbability = 1
        }

        return DigitalVideoParameters(
            detailScale: detailScale,
            targetFrameRateFPS: max(linkPreset.minimumAdaptiveFrameRateFPS, targetFrameRate),
            packetArtifactIntensity: clamp(max(packetStress, (deliveryStress - 0.48) * (0.85 - continuity * 0.30))),
            staleRegionIntensity: clamp(max(packetStress * 0.90, (deliveryStress - 0.56) * (0.80 - continuity * 0.22))),
            frameDropProbability: clamp(frameDropProbability),
            isFrozen: state.isFrozen || state.health == .lost
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 1))
    }
}

/// A fiber video path stays pixel-clean. Its only visual failures are skipped delivery and a hard
/// retained-frame loss; RF-derived snow, color errors and synchronization damage are impossible.
struct FiberVideoParameters: Equatable, Sendable {
    var frameDropProbability: Double
    var isFrozen: Bool

    static let clean = FiberVideoParameters(frameDropProbability: 0, isFrozen: false)

    var requiresPostProcessing: Bool {
        isFrozen || frameDropProbability > 0.001
    }
}

struct FiberVideoRFMapper: Sendable {
    func parameters(for state: RFVideoPresentationState) -> FiberVideoParameters {
        let dropProbability: Double
        switch state.health {
        case .healthy: dropProbability = 0
        case .degraded: dropProbability = 0.012
        case .critical: dropProbability = 0.08
        case .lost: dropProbability = 1
        }
        return FiberVideoParameters(
            frameDropProbability: dropProbability,
            isFrozen: state.isFrozen || state.health == .lost
        )
    }
}
