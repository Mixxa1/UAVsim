import Foundation

/// Converts legacy Workbench receiver/range fields into physical equipment once, at load time.
/// The resulting runtime never compares distance with the legacy range.
enum RFCompatibilityPreset {
    static func make(for build: WorkbenchBuild) -> RFSystemConfiguration {
        let camera = build.spec(for: .camera)
        let videoMode: RFVideoTransmissionMode = camera?.id.hasPrefix("camera-fpv") == true
            ? .analog
            : .digital
        return make(
            receiver: build.spec(for: .receiver),
            hasVideo: camera != nil,
            videoMode: videoMode,
            videoLinkPreset: .fallback(for: videoMode)
        )
    }

    static func make(for profile: DroneModelProfile) -> RFSystemConfiguration {
        if let build = profile.workbenchBuild {
            // A Workbench build already owns an installed RF system. Re-deriving it here from a
            // camera ID would let the camera silently override an explicitly selected VIDEO mode.
            return build.rfSystem
        }
        return make(
            receiver: nil,
            hasVideo: true,
            videoMode: profile.defaultVideoMode,
            videoLinkPreset: profile.defaultVideoLinkPreset,
            fallbackControlFrequencyHz: 2_400_000_000,
            fallbackLegacyRangeM: Double(profile.operationalProfile.nominalLinkRangeM)
        )
    }

    static func make(
        receiver: WorkbenchComponentSpec?,
        hasVideo: Bool,
        videoMode: RFVideoTransmissionMode = .digital,
        videoLinkPreset: RFVideoLinkPreset? = nil,
        fallbackControlFrequencyHz: Double = 2_400_000_000,
        fallbackLegacyRangeM: Double = 12_000
    ) -> RFSystemConfiguration {
        let resolvedVideoLinkPreset = videoLinkPreset ?? .fallback(for: videoMode)
        let receiverFrequencyMHz = receiver?.param(
            WorkbenchComponentSpec.ParamKey.receiverFrequencyMHz
        ) ?? fallbackControlFrequencyHz / 1_000_000
        let controlFrequencyHz = receiverFrequencyMHz * 1_000_000
        let legacyRangeM = max(
            250,
            receiver?.param(WorkbenchComponentSpec.ParamKey.receiverRangeKm).map { $0 * 1_000 }
                ?? fallbackLegacyRangeM
        )
        let controlBandwidthHz = controlFrequencyHz < 1_000_000_000 ? 250_000.0 : 500_000.0
        let controlTxPowerDBm = controlFrequencyHz < 1_000_000_000 ? 24.0 : 20.0
        let controlRequiredRxDBm = calibratedRequiredRxLevelDBm(
            legacyRangeM: legacyRangeM,
            frequencyHz: controlFrequencyHz,
            txPowerDBm: controlTxPowerDBm,
            combinedAntennaGainDB: 4.0,
            fixedLossDB: 2.0
        )

        var devices: [RFDeviceInstance] = []
        var antennas: [RFAntennaInstance] = []
        var connections: [RFAntennaConnection] = []

        func frequencyRange(centerHz: Double, fractionalWidth: Double = 0.12) -> RFFrequencyRange {
            RFFrequencyRange(
                lowerBoundHz: centerHz * (1.0 - fractionalWidth),
                upperBoundHz: centerHz * (1.0 + fractionalWidth)
            )
        }

        func device(
            id: String,
            endpoint: RFEndpointKind,
            kind: RFDeviceKind,
            frequencyHz: Double,
            bandwidthHz: Double,
            txPowerDBm: Double?,
            sensitivityDBm: Double?,
            noiseFigureDB: Double,
            modulation: String
        ) -> RFDeviceInstance {
            RFDeviceInstance(
                id: id,
                endpoint: endpoint,
                profile: RFDeviceProfile(
                    id: "compat-profile.\(id)",
                    kind: kind,
                    frequencyRanges: [frequencyRange(centerHz: frequencyHz)],
                    maxTxPowerDBm: txPowerDBm,
                    receiverSensitivityDBm: sensitivityDBm,
                    noiseFigureDB: noiseFigureDB,
                    supportedBandwidthsHz: [bandwidthHz],
                    modulationProfiles: [modulation]
                ),
                centerFrequencyHz: frequencyHz,
                bandwidthHz: bandwidthHz,
                txPowerDBm: txPowerDBm,
                dutyCycle: 1,
                connectorLossDB: 0.35,
                enabled: true
            )
        }

        func antenna(
            id: String,
            deviceID: String,
            frequencyHz: Double,
            polarization: RFPolarization,
            mount: RFVector3D
        ) -> RFAntennaInstance {
            RFAntennaInstance(
                id: id,
                deviceID: deviceID,
                profile: RFAntennaProfile(
                    id: "compat-omni.\(Int(frequencyHz.rounded()))",
                    frequencyRange: frequencyRange(centerHz: frequencyHz, fractionalWidth: 0.15),
                    peakGainDBi: 2,
                    patternKind: .omnidirectional,
                    polarization: polarization,
                    efficiency: 0.82,
                    connectorLossDB: 0.2
                ),
                mountPositionM: mount,
                orientation: .identity,
                cableLengthM: 0.15,
                cableLossDBPerM: 0.45,
                damageFraction: 0,
                enabled: true
            )
        }

        func install(_ device: RFDeviceInstance, antenna: RFAntennaInstance) {
            devices.append(device)
            antennas.append(antenna)
            connections.append(RFAntennaConnection(deviceID: device.id, antennaID: antenna.id))
        }

        let controlGround = device(
            id: "compat.control.ground.tx",
            endpoint: .ground,
            kind: .transmitter,
            frequencyHz: controlFrequencyHz,
            bandwidthHz: controlBandwidthHz,
            txPowerDBm: controlTxPowerDBm,
            sensitivityDBm: nil,
            noiseFigureDB: 0,
            modulation: "compat-control"
        )
        let controlAir = device(
            id: "compat.control.air.rx",
            endpoint: .airborne,
            kind: .receiver,
            frequencyHz: controlFrequencyHz,
            bandwidthHz: controlBandwidthHz,
            txPowerDBm: nil,
            sensitivityDBm: controlRequiredRxDBm,
            noiseFigureDB: 6,
            modulation: "compat-control"
        )
        let controlGroundAntenna = antenna(
            id: "compat.control.ground.antenna",
            deviceID: controlGround.id,
            frequencyHz: controlFrequencyHz,
            polarization: .linearVertical,
            mount: RFVector3D(x: 0, y: 1.5, z: 0)
        )
        let controlAirAntenna = antenna(
            id: "compat.control.air.antenna",
            deviceID: controlAir.id,
            frequencyHz: controlFrequencyHz,
            polarization: .linearVertical,
            mount: RFVector3D(x: 0, y: 0.03, z: -0.08)
        )
        install(controlGround, antenna: controlGroundAntenna)
        install(controlAir, antenna: controlAirAntenna)

        let telemetryFrequencyHz = controlFrequencyHz < 1_000_000_000
            ? controlFrequencyHz
            : 915_000_000.0
        let telemetryBandwidthHz = 250_000.0
        let telemetryAir = device(
            id: "compat.telemetry.air.tx",
            endpoint: .airborne,
            kind: .transceiver,
            frequencyHz: telemetryFrequencyHz,
            bandwidthHz: telemetryBandwidthHz,
            txPowerDBm: 24,
            sensitivityDBm: -112,
            noiseFigureDB: 5,
            modulation: "compat-telemetry"
        )
        let telemetryGround = device(
            id: "compat.telemetry.ground.rx",
            endpoint: .ground,
            kind: .transceiver,
            frequencyHz: telemetryFrequencyHz,
            bandwidthHz: telemetryBandwidthHz,
            txPowerDBm: 24,
            sensitivityDBm: -112,
            noiseFigureDB: 5,
            modulation: "compat-telemetry"
        )
        let telemetryAirAntenna = antenna(
            id: "compat.telemetry.air.antenna",
            deviceID: telemetryAir.id,
            frequencyHz: telemetryFrequencyHz,
            polarization: .linearVertical,
            mount: RFVector3D(x: 0.05, y: 0.02, z: -0.06)
        )
        let telemetryGroundAntenna = antenna(
            id: "compat.telemetry.ground.antenna",
            deviceID: telemetryGround.id,
            frequencyHz: telemetryFrequencyHz,
            polarization: .linearVertical,
            mount: RFVector3D(x: 0.15, y: 1.5, z: 0)
        )
        install(telemetryAir, antenna: telemetryAirAntenna)
        install(telemetryGround, antenna: telemetryGroundAntenna)

        let controlLink = RFLinkConfiguration(
            id: "compat.link.control",
            kind: .control,
            transmitterDeviceID: controlGround.id,
            receiverDeviceID: controlAir.id,
            transmitterAntennaID: controlGroundAntenna.id,
            receiverAntennaID: controlAirAntenna.id,
            qualityProfile: RFLinkQualityProfile(
                id: "compat.quality.control",
                modulationProfile: "compat-control",
                requiredRxLevelDBm: controlRequiredRxDBm,
                requiredSINRDB: 3,
                nominalBitrateBps: 100_000,
                baseLatencyMS: 8
            )
        )
        let telemetryLink = RFLinkConfiguration(
            id: "compat.link.telemetry",
            kind: .telemetry,
            transmitterDeviceID: telemetryAir.id,
            receiverDeviceID: telemetryGround.id,
            transmitterAntennaID: telemetryAirAntenna.id,
            receiverAntennaID: telemetryGroundAntenna.id,
            qualityProfile: RFLinkQualityProfile(
                id: "compat.quality.telemetry",
                modulationProfile: "compat-telemetry",
                requiredRxLevelDBm: -108,
                requiredSINRDB: 4,
                nominalBitrateBps: 64_000,
                baseLatencyMS: 18
            )
        )

        var videoLink: RFLinkConfiguration?
        if hasVideo {
            let videoModulation: String
            switch videoMode {
            case .analog: videoModulation = "compat-analog-video"
            case .digital: videoModulation = "compat-digital-video"
            case .fiber: videoModulation = "compat-fiber-video"
            }
            let videoFrequencyHz = 5_800_000_000.0
            let videoBandwidthHz = 20_000_000.0
            let videoAir = device(
                id: "compat.video.air.tx",
                endpoint: .airborne,
                kind: .transmitter,
                frequencyHz: videoFrequencyHz,
                bandwidthHz: videoBandwidthHz,
                txPowerDBm: 30,
                sensitivityDBm: nil,
                noiseFigureDB: 0,
                modulation: videoModulation
            )
            let videoGround = device(
                id: "compat.video.ground.rx",
                endpoint: .ground,
                kind: .receiver,
                frequencyHz: videoFrequencyHz,
                bandwidthHz: videoBandwidthHz,
                txPowerDBm: nil,
                sensitivityDBm: -92,
                noiseFigureDB: 6,
                modulation: videoModulation
            )
            let videoAirAntenna = antenna(
                id: "compat.video.air.antenna",
                deviceID: videoAir.id,
                frequencyHz: videoFrequencyHz,
                polarization: .rhcp,
                mount: RFVector3D(x: -0.05, y: 0.04, z: -0.07)
            )
            let videoGroundAntenna = antenna(
                id: "compat.video.ground.antenna",
                deviceID: videoGround.id,
                frequencyHz: videoFrequencyHz,
                polarization: .rhcp,
                mount: RFVector3D(x: -0.15, y: 1.6, z: 0)
            )
            install(videoAir, antenna: videoAirAntenna)
            install(videoGround, antenna: videoGroundAntenna)
            videoLink = RFLinkConfiguration(
                id: "compat.link.video",
                kind: .video,
                transmitterDeviceID: videoAir.id,
                receiverDeviceID: videoGround.id,
                transmitterAntennaID: videoAirAntenna.id,
                receiverAntennaID: videoGroundAntenna.id,
                qualityProfile: RFLinkQualityProfile(
                    id: "compat.quality.video",
                    modulationProfile: videoModulation,
                    requiredRxLevelDBm: -90,
                    requiredSINRDB: videoMode == .analog ? 4 : 10,
                    nominalBitrateBps: videoMode == .analog
                        ? 8_000_000
                        : (videoMode == .fiber ? 100_000_000 : 25_000_000),
                    baseLatencyMS: videoMode == .analog
                        ? 5
                        : (videoMode == .fiber ? 2 : 28)
                ),
                videoMode: videoMode,
                videoLinkPreset: resolvedVideoLinkPreset
            )
        }

        return RFSystemConfiguration(
            version: RFSystemSchema.currentVersion,
            origin: .compatibilityPreset,
            devices: devices,
            antennas: antennas,
            connections: connections,
            logicalLinks: RFLogicalLinksConfiguration(
                control: controlLink,
                video: videoLink,
                telemetry: telemetryLink,
                payloadData: nil
            ),
            qos: .migrationDefault
        )
    }

    private static func calibratedRequiredRxLevelDBm(
        legacyRangeM: Double,
        frequencyHz: Double,
        txPowerDBm: Double,
        combinedAntennaGainDB: Double,
        fixedLossDB: Double
    ) -> Double {
        let receivedAtLegacyRange = txPowerDBm + combinedAntennaGainDB - fixedLossDB
            - RFPropagationMath.freeSpacePathLossDB(
                distanceM: legacyRangeM,
                frequencyHz: frequencyHz
            )
        return min(-82, max(-125, receivedAtLegacyRange - 3))
    }
}
