import Foundation

/// Converts Workbench engineering results into a runtime profile for the
/// selected architecture. The simulator therefore receives the composed
/// aircraft's mass, energy, propulsion layout and fixed-wing envelope instead
/// of silently flying a generic multirotor.
enum UAVBuildProfileSynthesizer {
    static func profileID(for build: WorkbenchBuild) -> String {
        "workbench.\(build.id.uuidString.lowercased())"
    }

    static func abstractParameters(for build: WorkbenchBuild) -> AbstractDroneParameters {
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        let frame = build.resolvedFrame
        let dimensions = frame.sizeMeters
        let speed = Float(max(4, stats.estimatedMaxSpeedMps))
        let liftRatio = effectiveLiftThrustToWeight(for: build, stats: stats)
        let authority: Float
        let ascent: Float
        switch frame.architecture {
        case .multicopter:
            authority = Float(max(0.35, min(1.0, liftRatio / 3.8)))
            ascent = Float(max(2.0, min(12.0, (liftRatio - 1) * 4.2)))
        case .fixedWing:
            // Static thrust-to-weight does not describe control authority for
            // an airplane. Servo speed is a much better available signal.
            let servoSpeed = build.spec(for: .servo)?.param(
                WorkbenchComponentSpec.ParamKey.servoSpeedSec60) ?? 0.12
            authority = Float(max(0.48, min(0.92, 0.98 - servoSpeed * 2.7)))
            ascent = Float(max(2.0, min(8.0, stats.thrustToWeight * 2.5)))
        case .liftCruiseVTOL:
            authority = Float(max(0.38, min(1.0, liftRatio / 3.4)))
            ascent = Float(max(2.0, min(10.0, (liftRatio - 1) * 4.0)))
        }
        return AbstractDroneParameters(
            massKg: Float(max(stats.totalMassKg, 0.025)),
            unfoldedMm: DroneDimensionsMM(
                x: Float(max(dimensions.x, 0.05) * 1000),
                y: Float(max(dimensions.z, 0.05) * 1000),
                z: Float(max(dimensions.y, 0.025) * 1000)),
            batteryEnergyWh: Float(max(stats.batteryEnergyWh, 1)),
            maxHorizontalSpeedMps: speed,
            maxAscentSpeedMps: ascent,
            maxDescentSpeedMps: max(2.0, ascent * 0.72),
            maxWindResistanceMps: max(4.0, min(16.0, speed * 0.52)),
            controlResponsiveness: authority,
            collisionRadiusMeters: Float(max(collisionRadius(for: build), 0.045)))
    }

    static func synthesizeProfile(for build: WorkbenchBuild) -> DroneModelProfile {
        let parameters = abstractParameters(for: build)
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        let architecture = build.resolvedFrame.architecture
        let endurance = enduranceMinutes(for: build, stats: stats)
        let flightTime = Float(max(endurance.maximumFlight, 1.0))
        let hoverTime: Float = architecture == .fixedWing
            ? 0
            : Float(max(endurance.hover, 0.8))
        let liftRatio = effectiveLiftThrustToWeight(for: build, stats: stats)
        let hoverThrottle: Float = architecture == .fixedWing
            ? 0
            : Float(max(0.18, min(0.92, sqrt(1 / max(liftRatio, 0.01)))))
        let runtimeArchitecture = runtimeArchitecture(for: architecture)
        let propulsionUnits = propulsionUnits(for: build)
        return DroneModelProfile(
            id: profileID(for: build),
            displayName: build.name.isEmpty ? "Workbench UAV" : build.name,
            displayNameKey: build.name,
            manufacturer: "UAVSim Workbench",
            takeoffMassKg: parameters.massKg,
            dimensionsFoldedMm: parameters.unfoldedMm,
            dimensionsUnfoldedMm: parameters.unfoldedMm,
            maxHorizontalSpeedMps: parameters.maxHorizontalSpeedMps,
            maxAscentSpeedMps: parameters.maxAscentSpeedMps,
            maxDescentSpeedMps: parameters.maxDescentSpeedMps,
            maxFlightTimeMin: flightTime,
            maxHoverTimeMin: hoverTime,
            maxWindResistanceMps: parameters.maxWindResistanceMps,
            batteryCapacitymAh: Float(max(stats.batteryCapacityMah, 100)),
            batteryEnergyWh: parameters.batteryEnergyWh,
            cameraLayoutKey: "drone.camera.custom",
            visualClass: runtimeArchitecture.visualClass,
            operationalCategory: runtimeArchitecture.operationalCategory,
            airframeClass: runtimeArchitecture.airframeClass,
            airframeStyle: runtimeArchitecture.airframeStyle,
            fixedWingParameters: fixedWingParameters(
                architecture: architecture,
                speed: parameters.maxHorizontalSpeedMps),
            launchMethod: runtimeArchitecture.launchMethod,
            landingMethod: runtimeArchitecture.landingMethod,
            controlResponsiveness: parameters.controlResponsiveness,
            hoverThrottle: hoverThrottle,
            cameraPreset: DroneCameraPreset(fpvFov: 92, followDistance: 5.8, followHeight: 2.4),
            collisionRadiusMeters: parameters.collisionRadiusMeters,
            propulsionUnitTemplate: propulsionUnits,
            notes: "Синтезировано из Workbench: \(stats.componentCount) компонентов",
            sourceURL: nil,
            workbenchBuild: build)
    }

    static func catalogProfile(for build: WorkbenchBuild) -> UAVProfile {
        let runtime = abstractParameters(for: build)
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        let frame = build.resolvedFrame
        let endurance = enduranceMinutes(for: build, stats: stats)
        let batteryMass = build.spec(for: .battery).map { Float($0.massKg) }
        let payloadMass = build.spec(for: .payload).map { Float($0.massKg) }
        let dimensions = UAVDimensions(
            foldedMillimeters: runtime.unfoldedMm,
            unfoldedMillimeters: runtime.unfoldedMm,
            diagonalWheelbaseMillimeters: Float(max(frame.sizeMeters.x, frame.sizeMeters.z) * 1000),
            heightMillimeters: runtime.unfoldedMm.z)
        return UAVProfile(
            id: profileID(for: build),
            displayName: build.name.isEmpty ? "Пользовательская сборка" : build.name,
            manufacturer: "UAVSim Workbench",
            countryOfOrigin: "User Defined",
            vehicleType: vehicleType(for: frame.architecture),
            massCategory: massCategory(for: stats.totalMassKg),
            specConfidence: .custom,
            payloadCapabilityMode: payloadMass == nil ? .sensor : .modular,
            baseMass: Float(stats.totalMassKg) - (batteryMass ?? 0) - (payloadMass ?? 0),
            batteryMass: batteryMass,
            maxPayloadMass: payloadMass,
            maxTakeoffMass: Float(stats.totalMassKg),
            dimensions: dimensions,
            payloadMountOffset: WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)[.payload]?.position ?? .zero,
            visualPreset: .abstractCustom,
            shortDescription: build.buildDescription.isEmpty
                ? "Составная модель из Мастерской"
                : build.buildDescription,
            notes: "Пользовательская модель: \(stats.componentCount) компонентов",
            missionRole: "Пользовательская сборка",
            nominalFlightTimeSec: Float(max(endurance.maximumFlight, 0) * 60),
            nominalCruiseSpeedMps: Float(stats.estimatedMaxSpeedMps),
            nominalMaxRangeM: nil,
            nominalLinkRangeM: build.spec(for: .receiver).flatMap {
                $0.param(WorkbenchComponentSpec.ParamKey.receiverRangeKm).map { Float($0 * 1000) }
            })
    }

    private static func massCategory(for kilograms: Double) -> UAVMassCategory {
        switch kilograms {
        case ..<0.25: return .nano
        case ..<2.0: return .micro
        case ..<7.0: return .light
        case ..<25.0: return .medium
        case ..<150.0: return .heavy
        default: return .superheavy
        }
    }

    private struct RuntimeArchitecture {
        var visualClass: DroneVisualClass
        var operationalCategory: DroneOperationalCategory
        var airframeClass: AirframeClass
        var airframeStyle: AirframeStyle
        var launchMethod: LaunchMethod
        var landingMethod: LandingMethod
    }

    private static func runtimeArchitecture(
        for architecture: WorkbenchVehicleArchitecture
    ) -> RuntimeArchitecture {
        switch architecture {
        case .multicopter:
            return RuntimeArchitecture(
                visualClass: .abstract,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                launchMethod: .vertical,
                landingMethod: .vertical)
        case .fixedWing:
            return RuntimeArchitecture(
                visualClass: .fixedWingRectangular,
                operationalCategory: .fixedWing,
                airframeClass: .fixedWing,
                airframeStyle: .conventionalFixedWing,
                launchMethod: .handLaunch,
                landingMethod: .bellyLanding)
        case .liftCruiseVTOL:
            return RuntimeArchitecture(
                visualClass: .fixedWingRectangular,
                operationalCategory: .fixedWingVTOL,
                airframeClass: .hybridVTOL,
                airframeStyle: .surveyEVTOL,
                launchMethod: .vertical,
                landingMethod: .vertical)
        }
    }

    private static func vehicleType(
        for architecture: WorkbenchVehicleArchitecture
    ) -> UAVVehicleType {
        switch architecture {
        case .multicopter: return .multicopter
        case .fixedWing: return .fixedWing
        case .liftCruiseVTOL: return .hybridVTOL
        }
    }

    private static func fixedWingParameters(
        architecture: WorkbenchVehicleArchitecture,
        speed: Float
    ) -> FixedWingParameters? {
        guard architecture != .multicopter else { return nil }
        let cruise = max(13.0, min(speed, 34.0))
        let stall = max(7.0, cruise * 0.56)
        let minimum = max(stall + 0.8, cruise * 0.64)
        let climb = max(minimum + 1.0, cruise * 0.78)
        let isVTOL = architecture == .liftCruiseVTOL
        return FixedWingParameters(
            family: isVTOL ? .surveyEVTOL : .conventionalSurvey,
            minSustainableSpeedMps: minimum,
            cruiseSpeedMps: cruise,
            climbSpeedMps: climb,
            stallWarningSpeedMps: stall,
            waypointAcceptanceRadiusMeters: max(8.0, cruise * 0.62),
            nominalTurnRateDegPerSec: isVTOL ? 12.0 : 14.0,
            bankResponseGain: 0.82,
            climbResponseGain: 0.68,
            descentResponseGain: 0.58,
            dragFactor: 1.0,
            throttleResponseGain: 0.68,
            turnAuthority: isVTOL ? 0.62 : 0.72,
            maxBankAngleDeg: isVTOL ? 38 : 42,
            supportedLaunchModes: isVTOL ? [.standard, .vtol] : [.standard, .handLaunch],
            preferredLaunchMode: isVTOL ? .vtol : .handLaunch,
            initialClimbPitchDeg: isVTOL ? 9.0 : 11.0,
            initialClimbTargetAltitude: isVTOL ? 14.0 : 18.0)
    }

    private static func propulsionUnits(for build: WorkbenchBuild) -> [PropulsionUnit] {
        let frame = build.resolvedFrame
        guard frame.architecture == .liftCruiseVTOL else { return [] }
        return frame.motorMounts.enumerated().map { index, mount in
            if index < frame.liftMotorCount {
                return .liftRotor(id: "workbench_lift_\(index)", mountOffset: mount)
            }
            return .cruiseProp(id: "workbench_cruise_\(index)", mountOffset: mount)
        }
    }

    private static func collisionRadius(for build: WorkbenchBuild) -> Double {
        let dimensions = build.resolvedFrame.sizeMeters
        return max(dimensions.x, dimensions.z) * 0.52
    }

    private static func effectiveLiftThrustToWeight(
        for build: WorkbenchBuild,
        stats: WorkbenchBuildStats
    ) -> Double {
        let frame = build.resolvedFrame
        guard stats.totalMassKg > 0 else { return 0 }
        switch frame.architecture {
        case .fixedWing:
            return stats.thrustToWeight
        case .multicopter:
            return stats.thrustToWeight
        case .liftCruiseVTOL:
            let singleThrust = build.spec(for: .motor)?.param(
                WorkbenchComponentSpec.ParamKey.motorMaxThrustN) ?? 0
            return singleThrust * Double(frame.liftMotorCount)
                / (stats.totalMassKg * 9.80665)
        }
    }

    private struct EnduranceEstimate {
        var hover: Double
        var maximumFlight: Double
    }

    private static func enduranceMinutes(
        for build: WorkbenchBuild,
        stats: WorkbenchBuildStats
    ) -> EnduranceEstimate {
        let frame = build.resolvedFrame
        switch frame.architecture {
        case .fixedWing:
            return EnduranceEstimate(
                hover: 0,
                maximumFlight: max(stats.estimatedHoverTimeMin, 0))
        case .multicopter:
            let hover = max(stats.estimatedHoverTimeMin, 0)
            return EnduranceEstimate(hover: hover, maximumFlight: hover * 1.18)
        case .liftCruiseVTOL:
            guard stats.batteryEnergyWh > 0,
                  let motorPower = build.spec(for: .motor)?.param(
                    WorkbenchComponentSpec.ParamKey.motorMaxPowerW),
                  motorPower > 0 else {
                return EnduranceEstimate(
                    hover: max(stats.estimatedHoverTimeMin, 0),
                    maximumFlight: max(stats.estimatedHoverTimeMin, 0))
            }
            let liftRatio = effectiveLiftThrustToWeight(for: build, stats: stats)
            let hoverThrottle = sqrt(min(1, 1 / max(liftRatio, 0.01)))
            let hoverPower = motorPower * Double(max(frame.liftMotorCount, 1))
                * pow(hoverThrottle, 1.55)
            let hover = stats.batteryEnergyWh / max(hoverPower, 1) * 60 * 0.82

            let cruiseMotorCount = max(frame.motorMounts.count - frame.liftMotorCount, 0)
            guard cruiseMotorCount > 0 else {
                return EnduranceEstimate(hover: hover, maximumFlight: hover)
            }
            // Cruise propulsors operate far below static maximum power. A
            // modest avionics/servo hotel load prevents unrealistically large
            // endurance values for low-power imported assemblies.
            let cruisePower = motorPower * Double(cruiseMotorCount) * 0.38 + 35
            let cruise = stats.batteryEnergyWh / max(cruisePower, 1) * 60 * 0.82
            return EnduranceEstimate(hover: hover, maximumFlight: max(hover, cruise))
        }
    }
}
