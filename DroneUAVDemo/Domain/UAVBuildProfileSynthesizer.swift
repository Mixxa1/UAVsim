import Foundation

/// Converts engineering results from the Workbench into the existing custom
/// multirotor runtime profile. The simulator therefore receives the selected
/// mass, dimensions, energy, speed and control authority instead of silently
/// flying the default catalog aircraft.
enum UAVBuildProfileSynthesizer {
    // Reuse the repository's persistent custom-profile identity so project
    // snapshots can reload the derived parameters without a new schema.
    static let profileID = UAVReferenceCatalog.abstractProfileID

    static func abstractParameters(for build: WorkbenchBuild) -> AbstractDroneParameters {
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        let dimensions = build.resolvedFrame.sizeMeters
        let speed = Float(max(4, stats.estimatedMaxSpeedMps))
        let authority = Float(max(0.35, min(1.0, stats.thrustToWeight / 3.8)))
        let ascent = Float(max(2.0, min(12.0, (stats.thrustToWeight - 1) * 4.2)))
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
        let flightTime = Float(max(stats.estimatedHoverTimeMin * 1.18, 1.0))
        let hoverTime = Float(max(stats.estimatedHoverTimeMin, 0.8))
        let hoverThrottle = Float(max(0.18, min(0.92, sqrt(1 / max(stats.thrustToWeight, 0.01)))))
        return DroneModelProfile(
            id: profileID,
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
            visualClass: .abstract,
            operationalCategory: .multirotor,
            airframeClass: .multirotor,
            airframeStyle: .multirotorQuad,
            fixedWingParameters: nil,
            launchMethod: .vertical,
            landingMethod: .vertical,
            controlResponsiveness: parameters.controlResponsiveness,
            hoverThrottle: hoverThrottle,
            cameraPreset: DroneCameraPreset(fpvFov: 92, followDistance: 5.8, followHeight: 2.4),
            collisionRadiusMeters: parameters.collisionRadiusMeters,
            notes: "Синтезировано из Workbench: \(stats.componentCount) компонентов",
            sourceURL: nil)
    }

    private static func collisionRadius(for build: WorkbenchBuild) -> Double {
        let dimensions = build.resolvedFrame.sizeMeters
        return max(dimensions.x, dimensions.z) * 0.52
    }
}
