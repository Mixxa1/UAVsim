import Foundation

enum RFPropagationMath {
    static let speedOfLightMPS = 299_792_458.0
    static let thermalNoiseDensityDBmPerHz = -174.0

    static func freeSpacePathLossDB(distanceM: Double, frequencyHz: Double) -> Double {
        guard distanceM.isFinite, frequencyHz.isFinite,
              distanceM > 0, frequencyHz > 0 else {
            return 0
        }
        let wavelengthM = speedOfLightMPS / frequencyHz
        return 20.0 * log10(4.0 * Double.pi * distanceM / wavelengthM)
    }

    static func noiseFloorDBm(bandwidthHz: Double, noiseFigureDB: Double) -> Double {
        guard bandwidthHz.isFinite, bandwidthHz > 0, noiseFigureDB.isFinite else {
            return thermalNoiseDensityDBmPerHz
        }
        return thermalNoiseDensityDBmPerHz + 10.0 * log10(bandwidthHz) + noiseFigureDB
    }

    static func dbmToMilliwatts(_ dbm: Double) -> Double {
        pow(10.0, dbm / 10.0)
    }

    static func milliwattsToDBm(_ milliwatts: Double) -> Double {
        guard milliwatts.isFinite, milliwatts > 0 else { return -.infinity }
        return 10.0 * log10(milliwatts)
    }

    static func combinedPowerDBm(_ powersDBm: [Double]) -> Double? {
        let total = powersDBm.reduce(0.0) { partial, power in
            guard power.isFinite else { return partial }
            return partial + dbmToMilliwatts(power)
        }
        guard total > 0 else { return nil }
        return milliwattsToDBm(total)
    }
}

enum RFInterferenceModel {
    static func spectralOverlapFraction(
        transmitterCenterHz: Double,
        transmitterBandwidthHz: Double,
        receiverCenterHz: Double,
        receiverBandwidthHz: Double
    ) -> Double {
        guard transmitterCenterHz.isFinite, receiverCenterHz.isFinite,
              transmitterBandwidthHz.isFinite, receiverBandwidthHz.isFinite,
              transmitterBandwidthHz > 0, receiverBandwidthHz > 0 else {
            return 0
        }
        let txLower = transmitterCenterHz - transmitterBandwidthHz * 0.5
        let txUpper = transmitterCenterHz + transmitterBandwidthHz * 0.5
        let rxLower = receiverCenterHz - receiverBandwidthHz * 0.5
        let rxUpper = receiverCenterHz + receiverBandwidthHz * 0.5
        let overlapHz = max(0, min(txUpper, rxUpper) - max(txLower, rxLower))
        return min(1.0, overlapHz / transmitterBandwidthHz)
    }

    static func effectivePowerDBm(
        receivedPowerDBm: Double,
        dutyCycle: Double,
        spectralOverlapFraction: Double
    ) -> Double? {
        let occupiedFraction = min(1.0, max(0.0, dutyCycle))
            * min(1.0, max(0.0, spectralOverlapFraction))
        guard receivedPowerDBm.isFinite, occupiedFraction > 0 else { return nil }
        return receivedPowerDBm + 10.0 * log10(occupiedFraction)
    }
}

struct RFPropagationRequest: Sendable {
    var linkID: String = ""
    var transmitter: RFDeviceInstance
    var receiver: RFDeviceInstance
    var transmitterAntenna: RFAntennaInstance
    var receiverAntenna: RFAntennaInstance
    var transmitterPositionM: RFVector3D
    var receiverPositionM: RFVector3D
    var transmitterOrientation: RFOrientation = .identity
    var receiverOrientation: RFOrientation = .identity
    var qualityProfile: RFLinkQualityProfile
    var pathContext: RFPathContext = .clear
    var environment: RFEnvironmentContext = .clear
    var supplementalLosses: RFSupplementalLosses = RFSupplementalLosses()
    var interferencePowersDBm: [Double] = []
    var timestamp: TimeInterval = 0
}

struct RFPropagationEngine {
    var pathLossModel = RFPathLossModel()
    var environmentModel = RFEnvironmentPropagationModel()

    func evaluate(_ request: RFPropagationRequest) -> RFLinkState {
        let distanceM = max(0.01, request.transmitterPositionM.distance(to: request.receiverPositionM))
        let propagationDirection = request.receiverPositionM - request.transmitterPositionM
        let frequencyHz = request.transmitter.centerFrequencyHz
        let bandwidthHz = max(request.transmitter.bandwidthHz, request.receiver.bandwidthHz)
        let txPowerDBm = min(
            request.transmitter.txPowerDBm ?? -.infinity,
            request.transmitter.profile.maxTxPowerDBm ?? .infinity
        )
        let txGainDBi = effectiveGainDBi(
            request.transmitterAntenna,
            endpointOrientation: request.transmitterOrientation,
            directionWorld: propagationDirection
        )
        let rxGainDBi = effectiveGainDBi(
            request.receiverAntenna,
            endpointOrientation: request.receiverOrientation,
            directionWorld: propagationDirection * -1.0
        )
        let freeSpaceLossDB = RFPropagationMath.freeSpacePathLossDB(
            distanceM: distanceM,
            frequencyHz: frequencyHz
        )
        let cableLossDB = cableLossDB(request.transmitter, request.transmitterAntenna)
            + cableLossDB(request.receiver, request.receiverAntenna)
        var resolvedLosses = adding(
            request.supplementalLosses,
            pathLossModel.losses(for: request.pathContext, frequencyHz: frequencyHz)
        )
        resolvedLosses.polarizationDB += RFAntennaSpatialModel.polarizationMismatchLossDB(
            transmitter: request.transmitterAntenna,
            transmitterOrientation: request.transmitterOrientation,
            receiver: request.receiverAntenna,
            receiverOrientation: request.receiverOrientation,
            propagationDirectionWorld: propagationDirection
        )
        let environmentalEffects = environmentModel.effects(
            context: request.environment,
            linkID: request.linkID,
            frequencyHz: frequencyHz,
            distanceM: distanceM,
            transmitterPositionM: request.transmitterPositionM,
            receiverPositionM: request.receiverPositionM,
            hasLineOfSight: request.pathContext.hasLineOfSight,
            timestamp: request.timestamp
        )
        let clutterLossDB = resolvedLosses.clutterDB + environmentalEffects.clutterLossDB
        let totalLossDB = freeSpaceLossDB
            + cableLossDB
            + resolvedLosses.totalDB
            + environmentalEffects.atmosphericLossDB
            + environmentalEffects.weatherLossDB
            + environmentalEffects.clutterLossDB
            - environmentalEffects.fadingAdjustmentDB
        let receivedPowerDBm = txPowerDBm + txGainDBi + rxGainDBi - totalLossDB
        let noiseFloorDBm = RFPropagationMath.noiseFloorDBm(
            bandwidthHz: bandwidthHz,
            noiseFigureDB: request.receiver.profile.noiseFigureDB ?? 0
        )
        let interferenceDBm = RFPropagationMath.combinedPowerDBm(request.interferencePowersDBm)
        let snrDB = receivedPowerDBm - noiseFloorDBm
        let denominatorMW = RFPropagationMath.dbmToMilliwatts(noiseFloorDBm)
            + (interferenceDBm.map(RFPropagationMath.dbmToMilliwatts) ?? 0)
        let sinrDB = receivedPowerDBm - RFPropagationMath.milliwattsToDBm(denominatorMW)
        let requiredRxLevelDBm = max(
            request.receiver.profile.receiverSensitivityDBm ?? -.infinity,
            request.qualityProfile.requiredRxLevelDBm
        )

        return RFLinkState(
            distanceM: distanceM,
            frequencyHz: frequencyHz,
            bandwidthHz: bandwidthHz,
            txPowerDBm: txPowerDBm,
            txGainDBi: txGainDBi,
            rxGainDBi: rxGainDBi,
            freeSpaceLossDB: freeSpaceLossDB,
            diffractionLossDB: resolvedLosses.diffractionDB,
            vegetationLossDB: resolvedLosses.vegetationDB,
            materialLossDB: resolvedLosses.materialDB,
            clutterLossDB: clutterLossDB,
            polarizationLossDB: resolvedLosses.polarizationDB,
            bodyShadowLossDB: resolvedLosses.bodyShadowDB,
            cableLossDB: cableLossDB,
            miscellaneousLossDB: resolvedLosses.miscellaneousDB,
            atmosphericLossDB: environmentalEffects.atmosphericLossDB,
            weatherLossDB: environmentalEffects.weatherLossDB,
            fadingAdjustmentDB: environmentalEffects.fadingAdjustmentDB,
            hasLineOfSight: request.pathContext.hasLineOfSight,
            obstructionCount: request.pathContext.obstructions.count,
            receivedPowerDBm: receivedPowerDBm,
            noiseFloorDBm: noiseFloorDBm,
            interferenceDBm: interferenceDBm,
            snrDB: snrDB,
            sinrDB: sinrDB,
            linkMarginDB: receivedPowerDBm - requiredRxLevelDBm,
            lastUpdateTime: request.timestamp
        )
    }

    private func effectiveGainDBi(
        _ antenna: RFAntennaInstance,
        endpointOrientation: RFOrientation,
        directionWorld: RFVector3D
    ) -> Double {
        guard antenna.enabled else { return -300 }
        let health = max(0.000_001, 1.0 - antenna.damageFraction)
        let efficiency = max(0.000_001, min(1.0, antenna.profile.efficiency) * health)
        return antenna.profile.peakGainDBi
            + 10.0 * log10(efficiency)
            + RFAntennaSpatialModel.patternAdjustmentDB(
                antenna: antenna,
                endpointOrientation: endpointOrientation,
                directionWorld: directionWorld
            )
    }

    private func cableLossDB(_ device: RFDeviceInstance, _ antenna: RFAntennaInstance) -> Double {
        max(0, device.connectorLossDB)
            + max(0, antenna.profile.connectorLossDB)
            + max(0, antenna.cableLengthM) * max(0, antenna.cableLossDBPerM)
    }

    private func adding(_ lhs: RFSupplementalLosses, _ rhs: RFSupplementalLosses) -> RFSupplementalLosses {
        RFSupplementalLosses(
            diffractionDB: lhs.diffractionDB + rhs.diffractionDB,
            vegetationDB: lhs.vegetationDB + rhs.vegetationDB,
            materialDB: lhs.materialDB + rhs.materialDB,
            clutterDB: lhs.clutterDB + rhs.clutterDB,
            polarizationDB: lhs.polarizationDB + rhs.polarizationDB,
            bodyShadowDB: lhs.bodyShadowDB + rhs.bodyShadowDB,
            miscellaneousDB: lhs.miscellaneousDB + rhs.miscellaneousDB
        )
    }
}

struct DigitalLinkQualityModel {
    func evaluate(rf: RFLinkState, profile: RFLinkQualityProfile) -> RFLinkQualityState {
        let sinrExcessDB = rf.sinrDB - profile.requiredSINRDB
        let governingMarginDB = min(rf.linkMarginDB, sinrExcessDB)
        let packetErrorRate = clamp(1.0 / (1.0 + exp(0.9 * governingMarginDB)))
        let health: RFLinkHealth
        switch (governingMarginDB, packetErrorRate) {
        case let (margin, _) where margin < -6:
            health = .lost
        case let (margin, _) where margin < 0:
            health = .critical
        case let (_, per) where per > 0.05:
            health = .degraded
        default:
            health = .healthy
        }

        let latencyPenaltyMS = packetErrorRate * 120.0
        return RFLinkQualityState(
            health: health,
            packetErrorRate: packetErrorRate,
            packetLoss: packetErrorRate,
            latencyMS: profile.baseLatencyMS + latencyPenaltyMS,
            jitterMS: packetErrorRate * 35.0,
            effectiveBitrateBps: profile.nominalBitrateBps * max(0, 1.0 - packetErrorRate)
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct AnalogVideoQualityModel {
    func presentationState(for evaluation: RFLinkEvaluation) -> RFVideoPresentationState {
        // Analog video has no packet cliff: noise and sync instability increase continuously as
        // the governing RF margin falls. It never freezes a stale complete frame.
        let governingMargin = min(evaluation.rf.linkMarginDB, evaluation.rf.sinrDB - 3)
        let noise = clamp(1.0 / (1.0 + exp(0.42 * (governingMargin - 2))))
        return RFVideoPresentationState(
            mode: .analog,
            health: evaluation.quality.health,
            analogNoiseIntensity: noise,
            digitalArtifactIntensity: 0,
            isFrozen: false,
            effectiveBitrateBPS: 0,
            latencyMS: evaluation.quality.latencyMS
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
