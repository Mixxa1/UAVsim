import Foundation

struct RFAcceptanceCriteria: Codable, Equatable, Sendable {
    var minimumDeliveryRatio: Double
    var maximumCommandAgeSeconds: Double
    var maximumSevereStateFraction: Double
    var minimumLinkMarginDB: Double
}

struct RFAcceptanceScenario: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var environment: RFEnvironmentContext
    var distanceM: Double
    var altitudeM: Double
    var pathContext: RFPathContext
    var durationSeconds: Double
    var stepSeconds: Double
    var criteria: RFAcceptanceCriteria
}

struct RFAcceptanceResult: Codable, Equatable, Identifiable, Sendable {
    var scenarioID: String
    var passed: Bool
    var sampleCount: Int
    var deliveryRatio: Double
    var retryRecoveredPackets: UInt64
    var meanPacketErrorRate: Double
    var minimumLinkMarginDB: Double
    var maximumCommandAgeSeconds: Double
    var severeStateFraction: Double
    var finalMCS: RFModulationCodingScheme
    var failureCodes: [String]

    var id: String { scenarioID }
}

/// A deterministic scale gate for the RF hot path. `activeEndpointCount` represents independent
/// aircraft whose configured logical links are evaluated once in the same simulation tick.
struct RFPerformanceBudgetResult: Codable, Equatable, Identifiable, Sendable {
    var activeEndpointCount: Int
    var evaluatedLinkCount: Int
    var failedEvaluationCount: Int
    var elapsedMilliseconds: Double
    var budgetMilliseconds: Double
    var passed: Bool

    var id: String { "rf-performance-\(activeEndpointCount)" }
}

struct RFPerformanceBudgetRunner {
    var activeEndpointCounts = [10, 50, 100]
    /// Keeps the gate useful on CI while allowing for debug builds and first-use module overhead.
    var minimumBudgetMilliseconds = 12.0
    var budgetMillisecondsPerEndpoint = 0.75

    func run(manager: RFSystemManager) -> [RFPerformanceBudgetResult] {
        let linkCount = manager.configuration.logicalLinks.all.filter(\.usesRFPropagation).count
        return activeEndpointCounts.map { endpointCount in
            let start = ProcessInfo.processInfo.systemUptime
            var evaluatedLinks = 0
            var failedEvaluations = 0

            for index in 0..<endpointCount {
                let distanceM = 80.0 + Double(index) * 13.0
                let poses = endpointPoses(
                    configuration: manager.configuration,
                    distanceM: distanceM,
                    altitudeM: 25.0 + Double(index % 12) * 4.0
                )
                let results = manager.evaluateAvailableLinks(
                    endpointPosesM: poses,
                    environment: .clear,
                    timestamp: Double(index) * 0.02,
                    pathContextResolver: { _ in .clear }
                )
                evaluatedLinks += results.count
                failedEvaluations += results.values.reduce(0) { partial, result in
                    if case .failure = result { return partial + 1 }
                    return partial
                }
            }

            let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            let budgetMilliseconds = max(
                minimumBudgetMilliseconds,
                Double(endpointCount) * budgetMillisecondsPerEndpoint
            )
            let expectedLinks = endpointCount * linkCount
            return RFPerformanceBudgetResult(
                activeEndpointCount: endpointCount,
                evaluatedLinkCount: evaluatedLinks,
                failedEvaluationCount: failedEvaluations,
                elapsedMilliseconds: elapsedMilliseconds,
                budgetMilliseconds: budgetMilliseconds,
                passed: failedEvaluations == 0
                    && evaluatedLinks == expectedLinks
                    && elapsedMilliseconds <= budgetMilliseconds
            )
        }
    }

    private func endpointPoses(
        configuration: RFSystemConfiguration,
        distanceM: Double,
        altitudeM: Double
    ) -> [String: RFEndpointPose] {
        Dictionary(uniqueKeysWithValues: configuration.devices.map { device in
            let placement = configuration.endpointPlacement(for: device.id)
            let pose: RFEndpointPose
            switch device.endpoint {
            case .airborne:
                pose = RFEndpointPose(
                    positionM: RFVector3D(x: distanceM, y: altitudeM, z: 0),
                    orientation: .identity
                )
            case .ground:
                pose = RFEndpointPose(
                    positionM: placement.offsetFromHomeM,
                    orientation: placement.orientation
                )
            case .relay:
                pose = RFEndpointPose(
                    positionM: placement.offsetFromHomeM + RFVector3D(
                        x: distanceM * 0.5,
                        y: altitudeM * 0.75,
                        z: 0
                    ),
                    orientation: placement.orientation
                )
            }
            return (device.id, pose)
        })
    }
}

struct RFAcceptanceScenarioRunner {
    var packetEngine = RFPacketDeliveryEngine()
    var availabilityPolicy = RFControlLinkAvailabilityPolicy()

    func run(
        _ scenario: RFAcceptanceScenario,
        manager: RFSystemManager,
        linkKind: LogicalLinkKind = .control
    ) -> RFAcceptanceResult {
        let stepSeconds = max(0.01, scenario.stepSeconds)
        let stepCount = max(1, Int(ceil(max(stepSeconds, scenario.durationSeconds) / stepSeconds)))
        let poses = endpointPoses(
            configuration: manager.configuration,
            distanceM: scenario.distanceM,
            altitudeM: scenario.altitudeM
        )
        var delivery = RFPacketDeliveryState.initial
        var perSum = 0.0
        var minimumMarginDB = Double.infinity
        var maximumAgeSeconds = 0.0
        var severeSamples = 0
        var evaluatedSamples = 0

        for step in 0..<stepCount {
            let timestamp = Double(step + 1) * stepSeconds
            guard let evaluation = try? manager.evaluate(
                linkKind: linkKind,
                endpointPosesM: poses,
                pathContext: scenario.pathContext,
                environment: scenario.environment,
                timestamp: timestamp
            ) else {
                return failedEvaluationResult(for: scenario)
            }
            delivery = packetEngine.advance(
                delivery,
                linkID: "acceptance.\(scenario.id).\(linkKind.rawValue)",
                linkKind: linkKind,
                deltaTime: stepSeconds,
                evaluation: evaluation
            )
            perSum += evaluation.quality.packetErrorRate
            minimumMarginDB = min(minimumMarginDB, evaluation.rf.linkMarginDB)
            maximumAgeSeconds = max(maximumAgeSeconds, delivery.secondsSinceLastDelivery)
            let availability = availabilityPolicy.evaluate(delivery: delivery, link: evaluation)
            if availability == .critical || availability == .lost {
                severeSamples += 1
            }
            evaluatedSamples += 1
        }

        let meanPER = perSum / Double(max(1, evaluatedSamples))
        let severeFraction = Double(severeSamples) / Double(max(1, evaluatedSamples))
        var failures: [String] = []
        if delivery.deliveryRatio < scenario.criteria.minimumDeliveryRatio {
            failures.append("delivery_ratio")
        }
        if maximumAgeSeconds > scenario.criteria.maximumCommandAgeSeconds {
            failures.append("command_age")
        }
        if severeFraction > scenario.criteria.maximumSevereStateFraction {
            failures.append("severe_state_fraction")
        }
        if minimumMarginDB < scenario.criteria.minimumLinkMarginDB {
            failures.append("link_margin")
        }

        return RFAcceptanceResult(
            scenarioID: scenario.id,
            passed: failures.isEmpty,
            sampleCount: evaluatedSamples,
            deliveryRatio: delivery.deliveryRatio,
            retryRecoveredPackets: delivery.packetsRecoveredByRetry,
            meanPacketErrorRate: meanPER,
            minimumLinkMarginDB: minimumMarginDB,
            maximumCommandAgeSeconds: maximumAgeSeconds,
            severeStateFraction: severeFraction,
            finalMCS: delivery.selectedMCS,
            failureCodes: failures
        )
    }

    static func defaultControlSuite(seed: UInt64) -> [RFAcceptanceScenario] {
        [
            RFAcceptanceScenario(
                id: "RF-04-field-clear",
                environment: environment(
                    scene: .openField,
                    weather: .clear,
                    intensity: 0,
                    density: 0.24,
                    seed: seed
                ),
                distanceM: 750,
                altitudeM: 80,
                pathContext: .clear,
                durationSeconds: 8,
                stepSeconds: 0.05,
                criteria: RFAcceptanceCriteria(
                    minimumDeliveryRatio: 0.98,
                    maximumCommandAgeSeconds: 0.15,
                    maximumSevereStateFraction: 0.02,
                    minimumLinkMarginDB: 3
                )
            ),
            RFAcceptanceScenario(
                id: "RF-05-forest-nlos",
                environment: environment(
                    scene: .forest,
                    weather: .fog,
                    intensity: 0.6,
                    density: 0.72,
                    seed: seed &+ 1
                ),
                distanceM: 500,
                altitudeM: 45,
                pathContext: RFPathContext(
                    hasLineOfSight: false,
                    obstructions: [RFPathObstruction(
                        id: "acceptance.forest.canopy",
                        kind: .vegetation,
                        material: .foliage,
                        distanceFromTransmitterM: 260
                    )]
                ),
                durationSeconds: 8,
                stepSeconds: 0.05,
                criteria: RFAcceptanceCriteria(
                    minimumDeliveryRatio: 0.75,
                    maximumCommandAgeSeconds: 0.45,
                    maximumSevereStateFraction: 0.35,
                    minimumLinkMarginDB: -2
                )
            ),
            RFAcceptanceScenario(
                id: "RF-06-urban-rain",
                environment: environment(
                    scene: .urban,
                    weather: .rain,
                    intensity: 0.8,
                    density: 0.82,
                    seed: seed &+ 2
                ),
                distanceM: 350,
                altitudeM: 65,
                pathContext: RFPathContext(
                    hasLineOfSight: false,
                    obstructions: [RFPathObstruction(
                        id: "acceptance.urban.concrete",
                        kind: .structure,
                        material: .concrete,
                        distanceFromTransmitterM: 170
                    )]
                ),
                durationSeconds: 8,
                stepSeconds: 0.05,
                criteria: RFAcceptanceCriteria(
                    minimumDeliveryRatio: 0.70,
                    maximumCommandAgeSeconds: 0.45,
                    maximumSevereStateFraction: 0.40,
                    minimumLinkMarginDB: -3
                )
            ),
        ]
    }

    private func endpointPoses(
        configuration: RFSystemConfiguration,
        distanceM: Double,
        altitudeM: Double
    ) -> [String: RFEndpointPose] {
        var poses: [String: RFEndpointPose] = [:]
        for device in configuration.devices {
            switch device.endpoint {
            case .ground:
                poses[device.id] = RFEndpointPose(positionM: .zero)
            case .airborne:
                poses[device.id] = RFEndpointPose(positionM: RFVector3D(
                    x: max(0, distanceM),
                    y: max(0, altitudeM),
                    z: 0
                ))
            case .relay:
                poses[device.id] = RFEndpointPose(positionM: RFVector3D(
                    x: max(0, distanceM) * 0.5,
                    y: max(0, altitudeM) * 0.75,
                    z: 0
                ))
            }
        }
        return poses
    }

    private func failedEvaluationResult(
        for scenario: RFAcceptanceScenario
    ) -> RFAcceptanceResult {
        RFAcceptanceResult(
            scenarioID: scenario.id,
            passed: false,
            sampleCount: 0,
            deliveryRatio: 0,
            retryRecoveredPackets: 0,
            meanPacketErrorRate: 1,
            minimumLinkMarginDB: -300,
            maximumCommandAgeSeconds: scenario.durationSeconds,
            severeStateFraction: 1,
            finalMCS: .robust,
            failureCodes: ["evaluation_error"]
        )
    }

    private static func environment(
        scene: RFEnvironmentScene,
        weather: RFWeatherCondition,
        intensity: Double,
        density: Double,
        seed: UInt64
    ) -> RFEnvironmentContext {
        RFEnvironmentContext(
            effectsEnabled: true,
            scene: scene,
            density: density,
            weather: weather,
            weatherIntensity: intensity,
            relativeHumidity: weather == .rain || weather == .fog ? 0.92 : 0.55,
            windSpeedMPS: weather == .rain ? 8 : 2,
            deterministicSeed: seed
        )
    }
}
