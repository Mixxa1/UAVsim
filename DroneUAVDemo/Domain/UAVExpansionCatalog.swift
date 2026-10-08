import Foundation
import simd

/// Flight baselines shipped with the additional USDZ library. The manifest is
/// also the authority for identity, scale and propulsion-unit locations.
/// Unpublished performance/installation figures are representative estimates.
enum UAVExpansionCatalog {
    struct Flight: Decodable {
        let manufacturer: String
        let country: String
        let massKg: Float
        let payloadMassKg: Float
        let batteryMassKg: Float
        let flightMinutes: Float
        let cruiseSpeedMps: Float
        let maxSpeedMps: Float
        let minSpeedMps: Float
        let batteryEnergyWh: Float
        let launchMode: String
        let windSpeedMps: Float
        let fuelMassKg: Float
        let engineType: String?
        let ratedPowerKw: Float?
        let ratedThrustN: Float?
        let engineCount: Int
        let videoPreset: RFVideoLinkPreset
        let cameraModuleId: String?
        let dimensionsMm: [Float]
    }

    struct Rotor: Decodable {
        let name: String
        let center: [Float]
        let axis: String
        let radiusM: Float
        let blades: Int
    }

    struct Definition {
        let id: String
        let name: String
        let category: String
        let layout: String
        let sourceURL: URL?
        let boundsMin: [Float]
        let publishedDimensions: String
        let flight: Flight
        let rotors: [Rotor]
        let mechanics: AircraftMechanizationConfiguration?

        var isMulticopter: Bool { category == "multicopter" }
        var isVTOL: Bool { category == "vtol" }
        var isTailsitter: Bool { layout == "ray" }
        var isFlyingWing: Bool { ["ebee", "ux11", "bramor", "orbiter", "deltaquad"].contains(layout) }
        var isJet: Bool { flight.engineType == "turbojet" }
        var dimensions: DroneDimensionsMM {
            DroneDimensionsMM(x: flight.dimensionsMm[0], y: flight.dimensionsMm[1], z: flight.dimensionsMm[2])
        }
        var massCategory: UAVMassCategory {
            switch flight.massKg {
            case ..<0.25: return .nano
            case ..<2.5: return .micro
            case ..<15: return .light
            case ..<120: return .medium
            case ..<250: return .heavy
            default: return .superheavy
            }
        }
        var family: FixedWingFamily {
            if isTailsitter { return .tailsitterVTOL }
            if isVTOL { return .surveyEVTOL }
            if isJet { return .canardDelta }
            if isFlyingWing { return .flyingWing }
            if layout == "scaneagle" { return .swept }
            return .conventionalSurvey
        }
        var visualClass: DroneVisualClass {
            if isMulticopter { return .miniCompact }
            if isTailsitter { return .wingtraClass }
            if isVTOL { return .trinityClass }
            if isFlyingWing { return .ebeeClass }
            if isJet { return .fixedWingDelta }
            return .fixedWingRectangular
        }
        var visualPreset: UAVVisualPreset {
            if isMulticopter { return .djiMavic4Pro }
            if isTailsitter { return .wingtraOneGenII }
            if isVTOL { return .quantumSystemsTrinityPro }
            if isJet { return .northAmericanX10 }
            if isFlyingWing { return .lightFixedWingSurvey }
            return flight.massKg > 500 ? .mq9bSkyGuardian : .lightFixedWingSurvey
        }
        var description: String {
            if isMulticopter { return "Compact digital quadcopter with an integrated imaging camera." }
            if isTailsitter { return "Twin-propeller mapping aircraft with tailsitter vertical takeoff and landing." }
            if isVTOL { return "Fixed-wing aircraft with separate vertical-lift rotors and a cruise propeller." }
            if isJet { return "Jet-powered unmanned aircraft." }
            if isFlyingWing { return "Electric or fuel-powered flying-wing aircraft for mapping and observation." }
            return "Fixed-wing unmanned aircraft for survey, observation and long-range flight."
        }

        var powerplant: UAVPowerplantSpec? {
            guard let kind = flight.engineType else { return nil }
            let engine: UAVEngineType
            switch kind {
            case "pistonTwoStroke": engine = .pistonTwoStroke
            case "pistonFourStroke": engine = .pistonFourStroke
            case "wankelRotary": engine = .wankelRotary
            case "turboprop": engine = .turboprop
            case "turbojet": engine = .turbojet
            default: return nil
            }
            let prop = rotors.first { $0.axis == "z" }
            let radius = prop?.radiusM ?? 0.2
            // Approximate shaft speed constrained by a subsonic propeller tip;
            // engine and fuel ratings are explicitly estimated in these baselines.
            let rpm: Float = isJet ? 30_000 : min(7_000, max(900, 210 / radius * 60 / (2 * .pi)))
            let placement: UAVPropellerPlacement = ["puma", "jump", "ar5"].contains(layout) ? .tractor : .pusher
            return UAVPowerplantSpec(
                engineType: engine, engineDesignation: "Representative simulation installation",
                engineCount: flight.engineCount, ratedShaftPowerKW: flight.ratedPowerKw,
                ratedThrustN: flight.ratedThrustN,
                propellerPlacement: isJet ? nil : placement,
                propellerDiameterM: isJet ? nil : radius * 2,
                ratedShaftRPM: rpm, propellerBladeCount: prop?.blades ?? 2,
                fuel: UAVFuelSpec(fuelType: engine == .turboprop || isJet ? .turbineKerosene : .gasoline,
                                  usableFuelMassKg: flight.fuelMassKg),
                inletType: isJet ? .fixedRamp : UAVInletType.none,
                inletDesignMach: isJet ? 0.8 : 0
            )
        }

        var propulsionUnits: [PropulsionUnit] {
            guard isVTOL else { return [] }
            let groundLift = max(0, -(boundsMin.count == 3 ? boundsMin[1] : 0))
            return rotors.map { rotor in
                // The visual builder applies a 180-degree yaw and a ground lift.
                let mount = SIMD3<Float>(-rotor.center[0], rotor.center[1] + groundLift, -rotor.center[2])
                return rotor.axis == "y"
                    ? .liftRotor(id: rotor.name, mountOffset: mount)
                    : .cruiseProp(id: rotor.name, mountOffset: mount)
            }
        }

        var profile: UAVProfile {
            let f = flight
            let dryMass = max(0.01, f.massKg - f.payloadMassKg - f.batteryMassKg - f.fuelMassKg)
            // A fuel fixed wing flies on its own two throttle figures where they can be worked
            // out; everything else about its tuning stays the class's. Same climb speed and turn
            // authority as its runtime tuning asks the estimate with, so both read one result.
            var tuning: UAVFlightTuningProfile?
            if !isMulticopter, !isVTOL, !isJet,
               let performance = AirframePerformanceEstimate.cached(
                for: self, climbSpeedMps: max(f.minSpeedMps * 1.15, f.cruiseSpeedMps * 0.85), turnAuthority: 0.62),
               let cruiseLever = performance.cruiseLever, let minimumLever = performance.minimumLever {
                let classFigures = UAVFlightTuningProfile.catalogDefault(
                    vehicleType: .fixedWing, specConfidence: .partial, baseMass: dryMass, batteryMass: nil,
                    estimatedBatteryMass: f.batteryMassKg, maxPayloadMass: nil, estimatedMaxPayloadMass: f.payloadMassKg,
                    maxTakeoffMass: nil, estimatedMaxTakeoffMass: f.massKg, visualPreset: visualPreset)
                if let fixedWing = classFigures.fixedWing {
                    tuning = .fixedWing(
                        referenceMass: classFigures.referenceMass,
                        cruiseThrottleBaseline: cruiseLever,
                        minimumSafeFlightThrottle: min(minimumLever, cruiseLever),
                        climbThrottleBaseline: fixedWing.climbThrottleBaseline,
                        glideThrottleFactor: fixedWing.glideThrottleFactor,
                        stallProtectionBias: fixedWing.stallProtectionBias,
                        payloadCruisePenaltyFactor: fixedWing.payloadCruisePenaltyFactor,
                        landingThrottleBaseline: fixedWing.minimumSafeFlightThrottle,
                        source: .derived)
                }
            }
            return UAVProfile(
                id: id, displayName: name, manufacturer: f.manufacturer, countryOfOrigin: f.country,
                vehicleType: isMulticopter ? .multicopter : isVTOL ? .hybridVTOL : .fixedWing,
                massCategory: massCategory, specConfidence: .partial,
                payloadCapabilityMode: isMulticopter ? .sensor : .modular,
                baseMass: dryMass, batteryMass: nil, estimatedBatteryMass: f.batteryMassKg,
                maxPayloadMass: nil, estimatedMaxPayloadMass: f.payloadMassKg,
                maxTakeoffMass: nil, estimatedMaxTakeoffMass: f.massKg,
                dimensions: UAVDimensions(unfoldedMillimeters: dimensions,
                    wingspanMillimeters: isMulticopter ? nil : dimensions.x,
                    fuselageLengthMillimeters: isMulticopter ? nil : dimensions.y,
                    heightMillimeters: dimensions.z),
                payloadMountOffset: SIMD3<Float>(0, -min(0.6, dimensions.meters.z * 0.20), -dimensions.meters.y * 0.18),
                visualPreset: visualPreset, shortDescription: description,
                notes: "Exterior and published dimensions: \(publishedDimensions). Source: \(sourceURL?.absoluteString ?? "manufacturer reference"). Flight limits, empty mass, payload budget, battery/fuel installation and aerodynamic tuning are representative estimates, not a flight-test-certified model.",
                missionRole: isMulticopter ? "Aerial imaging and observation" : "Mapping, observation and flight training",
                flightTuningProfile: tuning,
                nominalFlightTimeSec: f.flightMinutes * 60,
                nominalCruiseSpeedMps: f.cruiseSpeedMps,
                minSafeAirspeedMps: isMulticopter ? nil : f.minSpeedMps,
                estimatedDataQuality: .estimated,
                powerplant: powerplant
            )
        }
    }

    private struct Row: Decodable {
        let id: String
        let name: String
        let category: String?
        let layout: String?
        let sourceUrl: String?
        let staticBoundsMinM: [Float]?
        let publishedDimensions: String?
        let runtimeProfile: Flight?
        let rotors: [Rotor]?
        let mechanics: AircraftMechanizationConfiguration?
    }
    private struct Document: Decodable { let models: [Row] }

    static let definitions: [Definition] = {
        let bundled = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "UAVModels")
        // Headless probes compile the Domain layer without an app resource bundle.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Models/UAVModels/manifest.json")
        guard let url = bundled ?? (Bundle.main.bundleURL.pathExtension == "app" ? nil : source),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let document = try? decoder.decode(Document.self, from: data) else {
            assertionFailure("Cannot decode the additional UAV flight catalogue")
            return []
        }
        return document.models.compactMap { row in
            guard let flight = row.runtimeProfile, flight.dimensionsMm.count == 3,
                  let category = row.category, let layout = row.layout else { return nil }
            return Definition(id: row.id, name: row.name, category: category, layout: layout,
                sourceURL: row.sourceUrl.flatMap(URL.init(string:)), boundsMin: row.staticBoundsMinM ?? [],
                publishedDimensions: row.publishedDimensions ?? "", flight: flight, rotors: row.rotors ?? [],
                mechanics: row.mechanics)
        }
    }()
    static let profiles = definitions.map(\.profile)
    static let ids = Set(definitions.map(\.id))
    private static let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    static func definition(for id: String) -> Definition? { byID[id] }

    /// Geometry is derived from the published sensor class/equivalent lens and
    /// field of view. ISP and package mass are representative characterisations.
    static let cameraModules: [CameraModule] = [
        CameraModule(id: "dji-mini-5-pro-camera", displayName: "Mini 5 Pro 1-inch camera", manufacturer: "DJI",
            videoOutput: .digital, primaryChannel: opticalChannel(width: 13.2, focal: 8.8,
                resolution: (8192, 6144), distortion: 0.04), massKg: 0.030),
        CameraModule(id: "dji-avata-2-camera", displayName: "Avata 2 wide-angle camera", manufacturer: "DJI",
            videoOutput: .digital, primaryChannel: opticalChannel(width: 9.6, focal: 3.0,
                resolution: (4000, 3000), distortion: 0.25), massKg: 0.035),
        CameraModule(id: "autel-fusion-4t-v2", displayName: "Fusion 4T V2", manufacturer: "Autel Robotics",
            videoOutput: .digital, primaryChannel: opticalChannel(width: 6.4, focal: 5.0,
                resolution: (8000, 6000), distortion: 0.04, zoom: 10),
            additionalChannels: [CameraChannelSpec(channel: .thermal, spectrum: .longwaveInfrared,
                shutter: .global, specConfidence: .estimated, sensorWidthMM: 7.68, focalLengthMM: 9.1,
                maximumOpticalZoom: 1, horizontalResolution: 640, verticalResolution: 512,
                barrelDistortion: 0.04, baseNoise: 0.20, dynamicRangeStops: 14,
                autoExposure: CameraAutoExposure(targetLevel: 0.46, responseSeconds: 0.25, gainUpStops: 4, gainDownStops: 4.5),
                colorResponse: .neutral)], massKg: 0.160)
    ]

    private static func opticalChannel(width: Double, focal: Double, resolution: (Int, Int),
                                       distortion: Double, zoom: Double = 1) -> CameraChannelSpec {
        CameraChannelSpec(channel: .optical, spectrum: .visibleLight, shutter: .rolling, specConfidence: .estimated,
            sensorWidthMM: width, focalLengthMM: focal, maximumOpticalZoom: zoom,
            horizontalResolution: resolution.0, verticalResolution: resolution.1, barrelDistortion: distortion,
            baseNoise: 0.10, dynamicRangeStops: 12,
            autoExposure: CameraAutoExposure(targetLevel: 0.42, responseSeconds: 0.25, gainUpStops: 2.5, gainDownStops: 5.5),
            colorResponse: .neutral)
    }
}
