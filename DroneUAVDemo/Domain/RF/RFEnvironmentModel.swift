import Foundation

enum RFEnvironmentScene: String, Codable, CaseIterable, Hashable, Sendable {
    case testGrid
    case openField
    case forest
    case industrial
    case urban
}

enum RFWeatherCondition: String, Codable, CaseIterable, Hashable, Sendable {
    case clear
    case wind
    case rain
    case snow
    case fog
    case smog
    case thunderstorm
}

struct RFEnvironmentContext: Codable, Hashable, Sendable {
    var effectsEnabled: Bool
    var scene: RFEnvironmentScene
    var density: Double
    var weather: RFWeatherCondition
    var weatherIntensity: Double
    var relativeHumidity: Double
    var windSpeedMPS: Double
    var deterministicSeed: UInt64

    static let clear = RFEnvironmentContext(
        effectsEnabled: false,
        scene: .openField,
        density: 0,
        weather: .clear,
        weatherIntensity: 0,
        relativeHumidity: 0.48,
        windSpeedMPS: 0,
        deterministicSeed: 0
    )
}

struct RFEnvironmentalEffects: Equatable, Sendable {
    var atmosphericLossDB: Double
    var weatherLossDB: Double
    var clutterLossDB: Double
    /// Signed small-scale fading term. Positive values improve received power; negative values
    /// deepen a fade. It is reported separately so calibration never mistakes it for material loss.
    var fadingAdjustmentDB: Double

    var netAdditionalLossDB: Double {
        atmosphericLossDB + weatherLossDB + clutterLossDB - fadingAdjustmentDB
    }
}

/// Macro-environment and slow-fading model. The result is deterministic for the same world seed,
/// link, geometry and simulation time, so replay and accelerated-time runs stay reproducible.
struct RFEnvironmentPropagationModel {
    func effects(
        context: RFEnvironmentContext,
        linkID: String,
        frequencyHz: Double,
        distanceM: Double,
        transmitterPositionM: RFVector3D,
        receiverPositionM: RFVector3D,
        hasLineOfSight: Bool,
        timestamp: TimeInterval
    ) -> RFEnvironmentalEffects {
        guard context.effectsEnabled else {
            return RFEnvironmentalEffects(
                atmosphericLossDB: 0,
                weatherLossDB: 0,
                clutterLossDB: 0,
                fadingAdjustmentDB: 0
            )
        }
        let frequencyGHz = max(0.001, frequencyHz / 1_000_000_000)
        let distanceKM = max(0, distanceM) / 1_000
        let density = clamp(context.density)
        let intensity = clamp(context.weatherIntensity)
        let humidity = clamp(context.relativeHumidity)

        // Below microwave oxygen/water resonances this intentionally remains a small correction.
        // It grows with frequency and path length, while rain/snow/fog add their own term below.
        let atmosphericLossDB = distanceKM
            * (0.001 + 0.004 * humidity)
            * pow(frequencyGHz / 10.0, 1.2)
        let weatherLossDB = distanceKM
            * weatherAttenuationDBPerKM(
                condition: context.weather,
                intensity: intensity,
                frequencyGHz: frequencyGHz
            )

        // Hard obstacles are already handled by RFPathContext. This lower macro-clutter term
        // represents unresolved scatterers and canopy/building density between those ray hits.
        let distanceSaturation = 1.0 - exp(-max(0, distanceM) / 450.0)
        let losMultiplier = hasLineOfSight ? 0.42 : 1.0
        let clutterLossDB = sceneClutterCeilingDB(context.scene)
            * (0.35 + 0.65 * density)
            * distanceSaturation
            * losMultiplier

        let sigmaDB = fadingSigmaDB(
            scene: context.scene,
            density: density,
            weatherIntensity: intensity,
            hasLineOfSight: hasLineOfSight
        )
        let fadingAdjustmentDB = deterministicFadingSample(
            seed: context.deterministicSeed,
            linkID: linkID,
            transmitterPositionM: transmitterPositionM,
            receiverPositionM: receiverPositionM,
            timestamp: timestamp,
            windSpeedMPS: max(0, context.windSpeedMPS)
        ) * sigmaDB

        return RFEnvironmentalEffects(
            atmosphericLossDB: atmosphericLossDB,
            weatherLossDB: weatherLossDB,
            clutterLossDB: clutterLossDB,
            fadingAdjustmentDB: fadingAdjustmentDB
        )
    }

    private func weatherAttenuationDBPerKM(
        condition: RFWeatherCondition,
        intensity: Double,
        frequencyGHz: Double
    ) -> Double {
        let coefficient: Double
        switch condition {
        case .clear, .wind: coefficient = 0
        case .rain: coefficient = 0.045
        case .snow: coefficient = 0.025
        case .fog: coefficient = 0.012
        case .smog: coefficient = 0.008
        case .thunderstorm: coefficient = 0.12
        }
        return coefficient * intensity * pow(frequencyGHz / 10.0, 1.35)
    }

    private func sceneClutterCeilingDB(_ scene: RFEnvironmentScene) -> Double {
        switch scene {
        case .openField: return 0.25
        case .testGrid: return 0.55
        case .forest: return 2.2
        case .industrial: return 2.7
        case .urban: return 3.3
        }
    }

    private func fadingSigmaDB(
        scene: RFEnvironmentScene,
        density: Double,
        weatherIntensity: Double,
        hasLineOfSight: Bool
    ) -> Double {
        let sceneSigma: Double
        switch scene {
        case .openField: sceneSigma = 0.35
        case .testGrid: sceneSigma = 0.70
        case .forest: sceneSigma = 1.80
        case .industrial: sceneSigma = 2.20
        case .urban: sceneSigma = 2.80
        }
        return sceneSigma * (0.50 + 0.50 * density)
            + weatherIntensity * 0.8
            + (hasLineOfSight ? 0 : 1.2)
    }

    private func deterministicFadingSample(
        seed: UInt64,
        linkID: String,
        transmitterPositionM: RFVector3D,
        receiverPositionM: RFVector3D,
        timestamp: TimeInterval,
        windSpeedMPS: Double
    ) -> Double {
        let coherenceSeconds = max(0.15, 1.25 / (1.0 + windSpeedMPS * 0.15))
        let safeTime = timestamp.isFinite ? max(0, timestamp) : 0
        let slotPosition = safeTime / coherenceSeconds
        let slot = Int64(slotPosition.rounded(.down))
        let fraction = slotPosition - Double(slot)
        let smoothFraction = fraction * fraction * (3.0 - 2.0 * fraction)

        let midpoint = (transmitterPositionM + receiverPositionM) * 0.5
        let cellX = Int64((midpoint.x / 25.0).rounded(.down))
        let cellY = Int64((midpoint.y / 25.0).rounded(.down))
        let cellZ = Int64((midpoint.z / 25.0).rounded(.down))
        let current = boundedNormalSample(
            seed: seed,
            linkID: linkID,
            slot: slot,
            cellX: cellX,
            cellY: cellY,
            cellZ: cellZ
        )
        let next = boundedNormalSample(
            seed: seed,
            linkID: linkID,
            slot: slot &+ 1,
            cellX: cellX,
            cellY: cellY,
            cellZ: cellZ
        )
        return current + (next - current) * smoothFraction
    }

    private func boundedNormalSample(
        seed: UInt64,
        linkID: String,
        slot: Int64,
        cellX: Int64,
        cellY: Int64,
        cellZ: Int64
    ) -> Double {
        var state = seed ^ UInt64(bitPattern: slot)
        state = mix(state ^ UInt64(bitPattern: cellX))
        state = mix(state ^ UInt64(bitPattern: cellY) &* 0x9E37_79B9_7F4A_7C15)
        state = mix(state ^ UInt64(bitPattern: cellZ) &* 0xBF58_476D_1CE4_E5B9)
        for byte in linkID.utf8 {
            state = mix(state ^ UInt64(byte))
        }

        var sum = 0.0
        for offset in 0..<4 {
            sum += unitSample(mix(state &+ UInt64(offset)))
        }
        // Four uniforms centred at zero, normalized to approximately unit variance and bounded
        // to avoid an improbable single sample destabilizing the control-link acceptance tests.
        return min(2.5, max(-2.5, (sum - 2.0) * sqrt(3.0)))
    }

    private func unitSample(_ value: UInt64) -> Double {
        Double(value >> 11) / Double(UInt64(1) << 53)
    }

    private func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

struct RFCalibrationKey: Codable, Hashable, Sendable {
    var scene: RFEnvironmentScene
    var weather: RFWeatherCondition
    var deterministicSeed: UInt64
}

struct RFCalibrationBucket: Codable, Equatable, Identifiable, Sendable {
    var key: RFCalibrationKey
    var sampleCount: UInt64 = 0
    var meanEnvironmentDensity: Double = 0
    var meanWeatherIntensity: Double = 0
    var meanRSSIDBm: Double = 0
    var rssiSquaredDeviationSum: Double = 0
    var meanSINRDB: Double = 0
    var meanMarginDB: Double = 0
    var meanPacketErrorRate: Double = 0
    var meanCommandAgeSeconds: Double = 0
    var nlosSampleCount: UInt64 = 0
    var matchingStateCount: UInt64 = 0
    var physicalMoreSevereCount: UInt64 = 0
    var legacyMoreSevereCount: UInt64 = 0

    var id: String {
        "\(key.scene.rawValue):\(key.weather.rawValue):\(key.deterministicSeed)"
    }

    var rssiStandardDeviationDB: Double {
        guard sampleCount > 1 else { return 0 }
        return sqrt(max(0, rssiSquaredDeviationSum / Double(sampleCount - 1)))
    }

    var nlosRatio: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(nlosSampleCount) / Double(sampleCount)
    }

    var stateAgreementRatio: Double {
        guard sampleCount > 0 else { return 1 }
        return Double(matchingStateCount) / Double(sampleCount)
    }

    mutating func record(
        context: RFEnvironmentContext,
        evaluation: RFLinkEvaluation,
        delivery: RFPacketDeliveryState,
        legacy: RFControlLinkAvailability,
        physical: RFControlLinkAvailability
    ) {
        sampleCount &+= 1
        let count = Double(sampleCount)
        meanEnvironmentDensity += (context.density - meanEnvironmentDensity) / count
        meanWeatherIntensity += (context.weatherIntensity - meanWeatherIntensity) / count

        let rssiDelta = evaluation.rf.receivedPowerDBm - meanRSSIDBm
        meanRSSIDBm += rssiDelta / count
        rssiSquaredDeviationSum += rssiDelta * (evaluation.rf.receivedPowerDBm - meanRSSIDBm)
        meanSINRDB += (evaluation.rf.sinrDB - meanSINRDB) / count
        meanMarginDB += (evaluation.rf.linkMarginDB - meanMarginDB) / count
        meanPacketErrorRate += (evaluation.quality.packetErrorRate - meanPacketErrorRate) / count
        meanCommandAgeSeconds += (
            delivery.secondsSinceLastDelivery - meanCommandAgeSeconds
        ) / count
        if !evaluation.rf.hasLineOfSight { nlosSampleCount &+= 1 }

        if legacy == physical {
            matchingStateCount &+= 1
        } else if physical.calibrationSeverity > legacy.calibrationSeverity {
            physicalMoreSevereCount &+= 1
        } else {
            legacyMoreSevereCount &+= 1
        }
    }
}

struct RFCalibrationReport: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var simulationTimeSeconds: Double
    var activeTerrainSeed: UInt64
    var buckets: [RFCalibrationBucket]
}

struct RFShadowBaselineAccumulator: Sendable {
    private var bucketsByKey: [RFCalibrationKey: RFCalibrationBucket] = [:]

    var buckets: [RFCalibrationBucket] {
        bucketsByKey.values.sorted { $0.id < $1.id }
    }

    mutating func record(
        context: RFEnvironmentContext,
        evaluation: RFLinkEvaluation,
        delivery: RFPacketDeliveryState,
        legacy: RFControlLinkAvailability,
        physical: RFControlLinkAvailability
    ) {
        let key = RFCalibrationKey(
            scene: context.scene,
            weather: context.weather,
            deterministicSeed: context.deterministicSeed
        )
        var bucket = bucketsByKey[key] ?? RFCalibrationBucket(key: key)
        bucket.record(
            context: context,
            evaluation: evaluation,
            delivery: delivery,
            legacy: legacy,
            physical: physical
        )
        bucketsByKey[key] = bucket
    }

    mutating func reset() {
        bucketsByKey.removeAll(keepingCapacity: true)
    }
}

private extension RFControlLinkAvailability {
    var calibrationSeverity: Int {
        switch self {
        case .nominal: return 0
        case .warning: return 1
        case .critical: return 2
        case .lost: return 3
        }
    }
}
