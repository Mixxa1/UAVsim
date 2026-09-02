import Foundation

enum RFSystemEvaluationError: Error, Equatable {
    case missingLink(LogicalLinkKind)
    case nonRFTransport(LogicalLinkKind)
    case missingDevice(String)
    case missingAntenna(String)
    case disabledDevice(String)
    case frequencyMismatch
}

enum RFConfigurationIssueSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

struct RFConfigurationIssue: Codable, Equatable, Sendable {
    var severity: RFConfigurationIssueSeverity
    var code: String
    var linkKind: LogicalLinkKind?
    var detail: String
}

struct RFSystemConfigurationValidator {
    func validate(_ configuration: RFSystemConfiguration) -> [RFConfigurationIssue] {
        var issues: [RFConfigurationIssue] = []
        if configuration.version != RFSystemSchema.currentVersion {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "unsupported_schema_version",
                detail: "RF schema version \(configuration.version) is unsupported."
            ))
        }

        let deviceIDs = Set(configuration.devices.map(\.id))
        let antennaIDs = Set(configuration.antennas.map(\.id))
        if deviceIDs.count != configuration.devices.count {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "duplicate_device_id",
                detail: "RF device identifiers must be unique."
            ))
        }
        if antennaIDs.count != configuration.antennas.count {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "duplicate_antenna_id",
                detail: "RF antenna identifiers must be unique."
            ))
        }

        let linkIDs = configuration.logicalLinks.all.map(\.id)
        if Set(linkIDs).count != linkIDs.count {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "duplicate_link_id",
                detail: "RF link identifiers must be unique."
            ))
        }
        if configuration.logicalLinks.control == nil {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "missing_control_link",
                linkKind: .control,
                detail: "A radio-controlled build requires a CONTROL link."
            ))
        }

        for device in configuration.devices {
            if !device.dutyCycle.isFinite || !(0...1).contains(device.dutyCycle) {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_duty_cycle",
                    detail: "RF device \(device.id) duty cycle must be within 0...1."
                ))
            }
            if !device.bandwidthHz.isFinite || device.bandwidthHz <= 0 {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_device_bandwidth",
                    detail: "RF device \(device.id) bandwidth must be greater than zero."
                ))
            }
        }
        for antenna in configuration.antennas {
            if !antenna.profile.efficiency.isFinite
                || !(0...1).contains(antenna.profile.efficiency) {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_antenna_efficiency",
                    detail: "RF antenna \(antenna.id) efficiency must be within 0...1."
                ))
            }
            let beamWidths = [
                antenna.profile.horizontalBeamwidthDegrees,
                antenna.profile.verticalBeamwidthDegrees,
            ].compactMap { $0 }
            if beamWidths.contains(where: { !$0.isFinite || $0 <= 0 || $0 > 360 }) {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_antenna_beamwidth",
                    detail: "RF antenna \(antenna.id) beam width must be within 0...360 degrees."
                ))
            }
            if !antenna.damageFraction.isFinite || !(0...1).contains(antenna.damageFraction) {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_antenna_damage",
                    detail: "RF antenna \(antenna.id) damage fraction must be within 0...1."
                ))
            }
        }

        for (deviceID, placement) in configuration.endpointPlacements ?? [:] {
            let position = placement.offsetFromHomeM
            let orientation = placement.orientation
            let values = [
                position.x, position.y, position.z,
                orientation.yawDegrees, orientation.pitchDegrees, orientation.rollDegrees,
            ]
            if !deviceIDs.contains(deviceID) || values.contains(where: { !$0.isFinite }) {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_endpoint_placement",
                    detail: "RF endpoint placement for \(deviceID) is invalid."
                ))
            }
        }

        for link in configuration.logicalLinks.all {
            validate(link, configuration: configuration, into: &issues)
        }
        if let qos = configuration.qos {
            validate(qos, into: &issues)
            validateQoSCapacity(qos, configuration: configuration, into: &issues)
        }
        return issues
    }

    private func validateQoSCapacity(
        _ qos: RFQoSConfiguration,
        configuration: RFSystemConfiguration,
        into issues: inout [RFConfigurationIssue]
    ) {
        let groups = Dictionary(
            grouping: configuration.logicalLinks.all.filter(\.usesRFPropagation),
            by: \.transmitterDeviceID
        )
        for (transmitterID, links) in groups {
            let capacity = links.map(\.qualityProfile.nominalBitrateBps).max() ?? 0
            let reserved = links.reduce(0.0) { partial, link in
                partial + qos.policy(for: link.kind).minimumReservedBitrateBPS
            }
            if reserved > capacity + 0.5 {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "qos_reservation_overcommit",
                    detail: "QoS reserves on \(transmitterID) require \(reserved) BPS but the channel provides \(capacity) BPS."
                ))
            }
        }
    }

    private func validate(
        _ qos: RFQoSConfiguration,
        into issues: inout [RFConfigurationIssue]
    ) {
        if qos.version != RFQoSSchema.currentVersion {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "unsupported_qos_schema_version",
                detail: "RF QoS schema version \(qos.version) is unsupported."
            ))
        }
        if !qos.controlBoostCommandAgeSeconds.isFinite || qos.controlBoostCommandAgeSeconds < 0 {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "invalid_qos_control_boost_age",
                detail: "RF QoS control boost age must be finite and non-negative."
            ))
        }
        if !qos.controlBoostMultiplier.isFinite || qos.controlBoostMultiplier < 1 {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "invalid_qos_control_boost_multiplier",
                detail: "RF QoS control boost multiplier must be finite and at least one."
            ))
        }

        let kinds = qos.linkPolicies.map(\.kind)
        if Set(kinds).count != kinds.count {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "duplicate_qos_link_policy",
                detail: "RF QoS may define at most one policy per logical link kind."
            ))
        }
        let priorities = qos.linkPolicies.map(\.priority)
        if Set(priorities).count != priorities.count {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "duplicate_qos_priority",
                detail: "RF QoS link priorities must be unique."
            ))
        }

        for policy in qos.linkPolicies {
            let invalidOptionalRate = policy.packetsPerSecond.map { !$0.isFinite || $0 < 0 } ?? false
            let invalidTTL = policy.packetTTLSeconds.map { !$0.isFinite || $0 <= 0 } ?? false
            let invalidIntegers = (policy.packetSizeBytes.map { $0 <= 0 } ?? false)
                || (policy.queueCapacity.map { $0 <= 0 } ?? false)
                || (policy.retryLimit.map { $0 < 0 } ?? false)
            if policy.priority < 0
                || !policy.minimumReservedBitrateBPS.isFinite
                || policy.minimumReservedBitrateBPS < 0
                || !policy.maximumShareFraction.isFinite
                || !(0...1).contains(policy.maximumShareFraction)
                || invalidOptionalRate
                || invalidTTL
                || invalidIntegers {
                issues.append(RFConfigurationIssue(
                    severity: .error,
                    code: "invalid_qos_link_policy",
                    linkKind: policy.kind,
                    detail: "RF QoS policy for \(policy.kind.rawValue) contains an invalid value."
                ))
            }
        }
    }

    private func validate(
        _ link: RFLinkConfiguration,
        configuration: RFSystemConfiguration,
        into issues: inout [RFConfigurationIssue]
    ) {
        guard let transmitter = configuration.devices.first(where: { $0.id == link.transmitterDeviceID }) else {
            issues.append(missing("missing_transmitter", id: link.transmitterDeviceID, link: link))
            return
        }
        guard let receiver = configuration.devices.first(where: { $0.id == link.receiverDeviceID }) else {
            issues.append(missing("missing_receiver", id: link.receiverDeviceID, link: link))
            return
        }
        guard let txAntenna = configuration.antennas.first(where: { $0.id == link.transmitterAntennaID }) else {
            issues.append(missing("missing_tx_antenna", id: link.transmitterAntennaID, link: link))
            return
        }
        guard let rxAntenna = configuration.antennas.first(where: { $0.id == link.receiverAntennaID }) else {
            issues.append(missing("missing_rx_antenna", id: link.receiverAntennaID, link: link))
            return
        }

        let frequencyHz = transmitter.centerFrequencyHz
        let txSupportsFrequency = transmitter.profile.frequencyRanges.contains { $0.contains(frequencyHz) }
        let rxSupportsFrequency = receiver.profile.frequencyRanges.contains { $0.contains(frequencyHz) }
        let tunedChannelsOverlap = abs(receiver.centerFrequencyHz - frequencyHz)
            <= (transmitter.bandwidthHz + receiver.bandwidthHz) * 0.5
        let antennasSupportFrequency = txAntenna.profile.frequencyRange.contains(frequencyHz)
            && rxAntenna.profile.frequencyRange.contains(frequencyHz)
        if !txSupportsFrequency || !rxSupportsFrequency || !tunedChannelsOverlap || !antennasSupportFrequency {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "frequency_mismatch",
                linkKind: link.kind,
                detail: "The selected devices and antennas do not share \(frequencyHz) Hz."
            ))
        }
        if transmitter.bandwidthHz <= 0 || receiver.bandwidthHz <= 0 {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "invalid_bandwidth",
                linkKind: link.kind,
                detail: "RF bandwidth must be greater than zero."
            ))
        }
        let txSupportsBandwidth = transmitter.profile.supportedBandwidthsHz.isEmpty
            || transmitter.profile.supportedBandwidthsHz.contains(where: {
                abs($0 - transmitter.bandwidthHz) <= max(1, $0 * 0.001)
            })
        let rxSupportsBandwidth = receiver.profile.supportedBandwidthsHz.isEmpty
            || receiver.profile.supportedBandwidthsHz.contains(where: {
                abs($0 - receiver.bandwidthHz) <= max(1, $0 * 0.001)
            })
        if !txSupportsBandwidth || !rxSupportsBandwidth {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "unsupported_bandwidth",
                linkKind: link.kind,
                detail: "The selected RF bandwidth is not supported by both endpoints."
            ))
        }
        if transmitter.profile.kind == .receiver || receiver.profile.kind == .transmitter {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "invalid_device_direction",
                linkKind: link.kind,
                detail: "The RF link endpoints do not provide the required TX/RX direction."
            ))
        }
        if txAntenna.deviceID != transmitter.id || rxAntenna.deviceID != receiver.id {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "antenna_connection_mismatch",
                linkKind: link.kind,
                detail: "An antenna is connected to a different RF device than the link endpoint."
            ))
        }
        let txConnectionExists = configuration.connections.contains {
            $0.deviceID == transmitter.id && $0.antennaID == txAntenna.id
        }
        let rxConnectionExists = configuration.connections.contains {
            $0.deviceID == receiver.id && $0.antennaID == rxAntenna.id
        }
        if !txConnectionExists || !rxConnectionExists {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "missing_antenna_connection",
                linkKind: link.kind,
                detail: "The selected RF antennas must be connected to their endpoint devices."
            ))
        }
        if !txAntenna.enabled || !rxAntenna.enabled {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "disabled_link_antenna",
                linkKind: link.kind,
                detail: "Each RF link requires an enabled antenna at both endpoints."
            ))
        }
        if !transmitter.profile.modulationProfiles.contains(link.qualityProfile.modulationProfile)
            || !receiver.profile.modulationProfiles.contains(link.qualityProfile.modulationProfile) {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "modulation_mismatch",
                linkKind: link.kind,
                detail: "The transmitter and receiver do not share the selected modulation profile."
            ))
        }
        if txAntenna.profile.polarization != rxAntenna.profile.polarization {
            issues.append(RFConfigurationIssue(
                severity: .warning,
                code: "polarization_mismatch",
                linkKind: link.kind,
                detail: "The antenna polarizations differ and require a polarization mismatch loss."
            ))
        }
        if transmitter.txPowerDBm == nil {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "missing_tx_power",
                linkKind: link.kind,
                detail: "The transmitter has no active TX power."
            ))
        }
        if receiver.profile.receiverSensitivityDBm == nil {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "missing_receiver_sensitivity",
                linkKind: link.kind,
                detail: "The receiver has no sensitivity value."
            ))
        }
        let quality = link.qualityProfile
        if !quality.requiredRxLevelDBm.isFinite
            || !quality.requiredSINRDB.isFinite
            || !quality.nominalBitrateBps.isFinite
            || quality.nominalBitrateBps <= 0
            || !quality.baseLatencyMS.isFinite
            || quality.baseLatencyMS < 0 {
            issues.append(RFConfigurationIssue(
                severity: .error,
                code: "invalid_link_quality_profile",
                linkKind: link.kind,
                detail: "The RF link quality profile contains an invalid threshold or bitrate."
            ))
        }
    }

    private func missing(_ code: String, id: String, link: RFLinkConfiguration) -> RFConfigurationIssue {
        RFConfigurationIssue(
            severity: .error,
            code: code,
            linkKind: link.kind,
            detail: "RF component \(id) referenced by \(link.id) is missing."
        )
    }
}

struct RFSystemManager {
    var configuration: RFSystemConfiguration
    var propagationEngine = RFPropagationEngine()
    var digitalQualityModel = DigitalLinkQualityModel()

    func evaluate(
        linkKind: LogicalLinkKind,
        endpointPositionsM: [String: RFVector3D],
        environment: RFEnvironmentContext = .clear,
        supplementalLosses: RFSupplementalLosses = RFSupplementalLosses(),
        interferencePowersDBm: [Double] = [],
        timestamp: TimeInterval = 0
    ) throws -> RFLinkEvaluation {
        try evaluate(
            linkKind: linkKind,
            endpointPosesM: endpointPositionsM.mapValues { RFEndpointPose(positionM: $0) },
            environment: environment,
            supplementalLosses: supplementalLosses,
            interferencePowersDBm: interferencePowersDBm,
            timestamp: timestamp
        )
    }

    func evaluate(
        linkKind: LogicalLinkKind,
        endpointPosesM: [String: RFEndpointPose],
        pathContext: RFPathContext = .clear,
        environment: RFEnvironmentContext = .clear,
        supplementalLosses: RFSupplementalLosses = RFSupplementalLosses(),
        interferencePowersDBm: [Double] = [],
        timestamp: TimeInterval = 0
    ) throws -> RFLinkEvaluation {
        guard let link = configuration.logicalLinks.link(for: linkKind) else {
            throw RFSystemEvaluationError.missingLink(linkKind)
        }
        guard link.usesRFPropagation else {
            throw RFSystemEvaluationError.nonRFTransport(linkKind)
        }
        guard let transmitter = configuration.devices.first(where: { $0.id == link.transmitterDeviceID }) else {
            throw RFSystemEvaluationError.missingDevice(link.transmitterDeviceID)
        }
        guard let receiver = configuration.devices.first(where: { $0.id == link.receiverDeviceID }) else {
            throw RFSystemEvaluationError.missingDevice(link.receiverDeviceID)
        }
        guard transmitter.enabled else { throw RFSystemEvaluationError.disabledDevice(transmitter.id) }
        guard receiver.enabled else { throw RFSystemEvaluationError.disabledDevice(receiver.id) }
        guard let txAntenna = configuration.antennas.first(where: { $0.id == link.transmitterAntennaID }) else {
            throw RFSystemEvaluationError.missingAntenna(link.transmitterAntennaID)
        }
        guard let rxAntenna = configuration.antennas.first(where: { $0.id == link.receiverAntennaID }) else {
            throw RFSystemEvaluationError.missingAntenna(link.receiverAntennaID)
        }
        guard transmitter.profile.frequencyRanges.contains(where: { $0.contains(transmitter.centerFrequencyHz) }),
              receiver.profile.frequencyRanges.contains(where: { $0.contains(transmitter.centerFrequencyHz) }),
              abs(receiver.centerFrequencyHz - transmitter.centerFrequencyHz)
                <= (transmitter.bandwidthHz + receiver.bandwidthHz) * 0.5 else {
            throw RFSystemEvaluationError.frequencyMismatch
        }

        let txPose = endpointPosesM[transmitter.id] ?? RFEndpointPose(positionM: .zero)
        let rxPose = endpointPosesM[receiver.id] ?? RFEndpointPose(positionM: .zero)
        let rf = propagationEngine.evaluate(RFPropagationRequest(
            linkID: link.id,
            transmitter: transmitter,
            receiver: receiver,
            transmitterAntenna: txAntenna,
            receiverAntenna: rxAntenna,
            transmitterPositionM: txPose.phaseCenter(for: txAntenna),
            receiverPositionM: rxPose.phaseCenter(for: rxAntenna),
            transmitterOrientation: txPose.orientation,
            receiverOrientation: rxPose.orientation,
            qualityProfile: link.qualityProfile,
            pathContext: pathContext,
            environment: environment,
            supplementalLosses: supplementalLosses,
            interferencePowersDBm: interferencePowersDBm,
            timestamp: timestamp
        ))
        return RFLinkEvaluation(
            rf: rf,
            quality: digitalQualityModel.evaluate(rf: rf, profile: link.qualityProfile)
        )
    }

    func evaluateAvailableLinks(
        endpointPositionsM: [String: RFVector3D],
        environment: RFEnvironmentContext = .clear,
        timestamp: TimeInterval = 0
    ) -> [LogicalLinkKind: Result<RFLinkEvaluation, RFSystemEvaluationError>] {
        var result: [LogicalLinkKind: Result<RFLinkEvaluation, RFSystemEvaluationError>] = [:]
        for link in configuration.logicalLinks.all where link.usesRFPropagation {
            do {
                result[link.kind] = .success(try evaluate(
                    linkKind: link.kind,
                    endpointPositionsM: endpointPositionsM,
                    environment: environment,
                    timestamp: timestamp
                ))
            } catch let error as RFSystemEvaluationError {
                result[link.kind] = .failure(error)
            } catch {
                result[link.kind] = .failure(.missingLink(link.kind))
            }
        }
        return result
    }

    func evaluateAvailableLinks(
        endpointPosesM: [String: RFEndpointPose],
        environment: RFEnvironmentContext = .clear,
        timestamp: TimeInterval = 0,
        pathContextResolver: (RFPathQuery) -> RFPathContext
    ) -> [LogicalLinkKind: Result<RFLinkEvaluation, RFSystemEvaluationError>] {
        var result: [LogicalLinkKind: Result<RFLinkEvaluation, RFSystemEvaluationError>] = [:]
        for link in configuration.logicalLinks.all where link.usesRFPropagation {
            do {
                guard let transmitter = configuration.devices.first(where: {
                    $0.id == link.transmitterDeviceID
                }) else {
                    throw RFSystemEvaluationError.missingDevice(link.transmitterDeviceID)
                }
                guard let receiver = configuration.devices.first(where: {
                    $0.id == link.receiverDeviceID
                }) else {
                    throw RFSystemEvaluationError.missingDevice(link.receiverDeviceID)
                }
                guard let txAntenna = configuration.antennas.first(where: {
                    $0.id == link.transmitterAntennaID
                }) else {
                    throw RFSystemEvaluationError.missingAntenna(link.transmitterAntennaID)
                }
                guard let rxAntenna = configuration.antennas.first(where: {
                    $0.id == link.receiverAntennaID
                }) else {
                    throw RFSystemEvaluationError.missingAntenna(link.receiverAntennaID)
                }
                let txPose = endpointPosesM[transmitter.id] ?? RFEndpointPose(positionM: .zero)
                let rxPose = endpointPosesM[receiver.id] ?? RFEndpointPose(positionM: .zero)
                let query = RFPathQuery(
                    linkKind: link.kind,
                    transmitterEndpoint: transmitter.endpoint,
                    receiverEndpoint: receiver.endpoint,
                    transmitterPhaseCenterM: txPose.phaseCenter(for: txAntenna),
                    receiverPhaseCenterM: rxPose.phaseCenter(for: rxAntenna)
                )
                let pathContext = pathContextResolver(query)
                let interferencePowersDBm = resolvedInterferencePowersDBm(
                    for: link,
                    desiredTransmitter: transmitter,
                    receiver: receiver,
                    receiverAntenna: rxAntenna,
                    receiverPose: rxPose,
                    endpointPosesM: endpointPosesM,
                    environment: environment,
                    timestamp: timestamp,
                    pathContextResolver: pathContextResolver
                )
                result[link.kind] = .success(try evaluate(
                    linkKind: link.kind,
                    endpointPosesM: endpointPosesM,
                    pathContext: pathContext,
                    environment: environment,
                    interferencePowersDBm: interferencePowersDBm,
                    timestamp: timestamp
                ))
            } catch let error as RFSystemEvaluationError {
                result[link.kind] = .failure(error)
            } catch {
                result[link.kind] = .failure(.missingLink(link.kind))
            }
        }
        return result
    }

    private func resolvedInterferencePowersDBm(
        for desiredLink: RFLinkConfiguration,
        desiredTransmitter: RFDeviceInstance,
        receiver: RFDeviceInstance,
        receiverAntenna: RFAntennaInstance,
        receiverPose: RFEndpointPose,
        endpointPosesM: [String: RFEndpointPose],
        environment: RFEnvironmentContext,
        timestamp: TimeInterval,
        pathContextResolver: (RFPathQuery) -> RFPathContext
    ) -> [Double] {
        var powers: [Double] = []
        for interfererLink in configuration.logicalLinks.all
        where interfererLink.id != desiredLink.id && interfererLink.usesRFPropagation {
            guard let interferer = configuration.devices.first(where: {
                $0.id == interfererLink.transmitterDeviceID
            }), interferer.enabled, interferer.txPowerDBm != nil,
            // Streams sharing one physical transmitter occupy one waveform; counting them as
            // separate radios would manufacture self-interference from logical multiplexing.
            interferer.id != desiredTransmitter.id,
            interferer.id != receiver.id,
            let interfererAntenna = configuration.antennas.first(where: {
                $0.id == interfererLink.transmitterAntennaID
            }), interfererAntenna.enabled else {
                continue
            }

            let overlap = RFInterferenceModel.spectralOverlapFraction(
                transmitterCenterHz: interferer.centerFrequencyHz,
                transmitterBandwidthHz: interferer.bandwidthHz,
                receiverCenterHz: receiver.centerFrequencyHz,
                receiverBandwidthHz: receiver.bandwidthHz
            )
            guard overlap > 0,
                  receiver.profile.frequencyRanges.contains(where: {
                      $0.contains(interferer.centerFrequencyHz)
                  }),
                  receiverAntenna.profile.frequencyRange.contains(interferer.centerFrequencyHz) else {
                continue
            }

            let interfererPose = endpointPosesM[interferer.id]
                ?? RFEndpointPose(positionM: .zero)
            let interfererPhaseCenter = interfererPose.phaseCenter(for: interfererAntenna)
            let receiverPhaseCenter = receiverPose.phaseCenter(for: receiverAntenna)
            let query = RFPathQuery(
                linkKind: interfererLink.kind,
                transmitterEndpoint: interferer.endpoint,
                receiverEndpoint: receiver.endpoint,
                transmitterPhaseCenterM: interfererPhaseCenter,
                receiverPhaseCenterM: receiverPhaseCenter
            )
            let sample = propagationEngine.evaluate(RFPropagationRequest(
                linkID: interfererLink.id,
                transmitter: interferer,
                receiver: receiver,
                transmitterAntenna: interfererAntenna,
                receiverAntenna: receiverAntenna,
                transmitterPositionM: interfererPhaseCenter,
                receiverPositionM: receiverPhaseCenter,
                transmitterOrientation: interfererPose.orientation,
                receiverOrientation: receiverPose.orientation,
                qualityProfile: desiredLink.qualityProfile,
                pathContext: pathContextResolver(query),
                environment: environment,
                timestamp: timestamp
            ))
            if let effectivePower = RFInterferenceModel.effectivePowerDBm(
                receivedPowerDBm: sample.receivedPowerDBm,
                dutyCycle: interferer.dutyCycle,
                spectralOverlapFraction: overlap
            ) {
                powers.append(effectivePower)
            }
        }
        return powers
    }
}
