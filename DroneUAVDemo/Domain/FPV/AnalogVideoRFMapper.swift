import Foundation

/// Signal-domain controls consumed by the analog FPV post-process. The value ranges mirror the
/// controls exposed by kdkd/Analog-NTSC, but stay renderer-agnostic so RF Core does not depend on
/// SceneKit or the native processor bridge.
struct AnalogNTSCParameters: Equatable, Sendable {
    var noiseStandardDeviationIRE: Double
    var multipathGain: Double
    var multipathDelayPixels: Double
    var multipathEnsemble: Double
    var impulseNoise: Double
    var burstNoiseIRE: Double
    var horizontalSyncInstability: Double
    var verticalSyncInstability: Double
    var chromaFlutter: Double
    var signalLoss: Double

    static let clean = AnalogNTSCParameters(
        // A decoded composite feed is never mathematically perfect, even with a strong link.
        noiseStandardDeviationIRE: 0.35,
        multipathGain: 0,
        multipathDelayPixels: 0,
        multipathEnsemble: 0,
        impulseNoise: 0,
        burstNoiseIRE: 0,
        horizontalSyncInstability: 0,
        verticalSyncInstability: 0,
        chromaFlutter: 0,
        signalLoss: 0
    )
}

/// Adapts the already-computed physical video-link state to an NTSC receiver. It deliberately
/// contains no propagation logic: RF Core remains the only authority for SNR, SINR, margin,
/// obstruction and fading.
struct AnalogVideoRFMapper: Sendable {
    func parameters(for evaluation: RFLinkEvaluation) -> AnalogNTSCParameters {
        let rf = evaluation.rf

        // Thermal/channel noise is driven by carrier-to-noise ratio, independently of packet
        // loss. The range is the Analog-NTSC library's IRE-domain control range (0...20 IRE).
        let snrSeverity = easedInverse(value: rf.snrDB, cleanAt: 32, saturatedAt: 1)
        let noiseIRE = 0.35 + 19.65 * pow(snrSeverity, 1.35)

        // Interference is not folded into generic snow: it creates impulsive streaks and corrupts
        // the color burst. Use both the explicit C/I ratio and the SNR-to-SINR collapse.
        let interferenceSeverity: Double = {
            guard let interferenceDBm = rf.interferenceDBm else { return 0 }
            let carrierToInterferenceDB = rf.receivedPowerDBm - interferenceDBm
            let ciSeverity = easedInverse(
                value: carrierToInterferenceDB,
                cleanAt: 28,
                saturatedAt: -2
            )
            let sinrCollapse = clamp((rf.snrDB - rf.sinrDB) / 24)
            return max(ciSeverity, sinrCollapse)
        }()

        // There is no synthetic "multipath" number in RF Core. Derive the receiver control from
        // physical evidence already present in the evaluated path: NLOS, blockers, excess path
        // losses and negative small-scale fading.
        let obstructionSeverity = rf.hasLineOfSight
            ? clamp(Double(rf.obstructionCount) / 10) * 0.22
            : 0.42 + clamp(Double(rf.obstructionCount) / 6) * 0.30
        let reflectedPathLoss = rf.diffractionLossDB
            + rf.vegetationLossDB
            + rf.materialLossDB
            + rf.clutterLossDB
        let excessLossSeverity = clamp(reflectedPathLoss / 42)
        let deepFadeSeverity = clamp(max(0, -rf.fadingAdjustmentDB) / 14)
        let multipathSeverity = clamp(
            obstructionSeverity + excessLossSeverity * 0.28 + deepFadeSeverity * 0.30
        )

        // Low governing margin destabilizes sync before the analog picture disappears. SINR is
        // referenced to the same 3 dB floor used by AnalogVideoQualityModel.
        let governingMarginDB = min(rf.linkMarginDB, rf.sinrDB - 3)
        var syncSeverity = easedInverse(value: governingMarginDB, cleanAt: 9, saturatedAt: -12)
        switch evaluation.quality.health {
        case .healthy:
            break
        case .degraded:
            syncSeverity = max(syncSeverity, 0.18)
        case .critical:
            syncSeverity = max(syncSeverity, 0.58)
        case .lost:
            syncSeverity = 1
        }

        let signalLoss = max(
            evaluation.quality.health == .lost ? 1 : 0,
            easedInverse(value: governingMarginDB, cleanAt: -5, saturatedAt: -20)
        )

        return AnalogNTSCParameters(
            noiseStandardDeviationIRE: noiseIRE,
            multipathGain: 0.58 * pow(multipathSeverity, 1.15),
            multipathDelayPixels: multipathSeverity > 0.01
                ? 1.5 + 22 * multipathSeverity
                : 0,
            multipathEnsemble: 0.82 * multipathSeverity,
            impulseNoise: clamp(0.92 * interferenceSeverity),
            burstNoiseIRE: 18 * interferenceSeverity,
            horizontalSyncInstability: clamp(syncSeverity),
            verticalSyncInstability: clamp(pow(syncSeverity, 1.45)),
            chromaFlutter: clamp(0.55 * interferenceSeverity + 0.35 * multipathSeverity),
            signalLoss: clamp(signalLoss)
        )
    }

    private func easedInverse(value: Double, cleanAt: Double, saturatedAt: Double) -> Double {
        let linear = clamp((cleanAt - value) / max(0.000_001, cleanAt - saturatedAt))
        return linear * linear * (3 - 2 * linear)
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 1))
    }
}
