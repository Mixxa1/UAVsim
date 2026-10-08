import Foundation

/// Converts Workbench engineering results into a runtime profile for the
/// selected architecture. The simulator therefore receives the composed
/// aircraft's mass, energy, propulsion layout and fixed-wing envelope instead
/// of silently flying a generic multirotor.
enum UAVBuildProfileSynthesizer {
    static func profileID(for build: WorkbenchBuild) -> String {
        "workbench.\(build.id.uuidString.lowercased())"
    }

    // MARK: - The envelope of a designed wing

    /// What a designed fixed wing flies like, worked out from the wing on its drawing, the weight
    /// of what was fitted to it and the motor that pulls it.
    ///
    /// ⚠️ The whole envelope used to hang on one number — the top speed the propeller's pitch
    /// suggested. Cruise was that speed, the stall 0.56 of it, the climb speed 0.78 of it, and
    /// the solver then sized a wing to stall where it had been told to. The base Surveyor S1,
    /// 2.3 kg on a 0.48 m² wing, was flown as an aircraft with a 0.086 m² wing that stalled at
    /// 17 m/s; its own wing stalls at seven. Nothing drawn in CAD reached the flight.
    struct DesignedWingEnvelope: Hashable {
        let wingAreaM2: Float
        let stallSpeedMps: Float
        let cruiseSpeedMps: Float
        let climbSpeedMps: Float
        /// `nil` when the build has no motor rating to work a climb out of.
        let climbRateMps: Float?
        let maximumSpeedMps: Float
        /// Drag times speed in level cruise, W: what the battery has to supply, after losses.
        let cruiseThrustPowerW: Float
        /// Radii of gyration about (roll, pitch, yaw), m, from where the parts are fitted.
        let gyrationRadiiMeters: SIMD3<Float>
        /// How long the fitted battery lasts in level cruise; `nil` without a battery.
        let flightMinutes: Double?
    }

    /// Share of a bare fixed-wing frame's mass that is wing and tail rather than fuselage.
    /// The frame arrives as one mass; until its drawing carries a tensor of its own, half of
    /// it is spread along the span and half along the length.
    private static let frameMassAlongSpan: Double = 0.5

    /// Radii of gyration of a designed fixed wing: every fitted part where it is fitted, plus
    /// the frame's own extent.
    ///
    /// ⚠️ The solver's inertia for a build used to come from its visual, with the battery taken
    /// as a quarter of the mass wherever the picture put it. Moving the pack along the fuselage
    /// in the Workbench moved the centre of mass and nothing else.
    private static func gyrationRadii(stats: WorkbenchBuildStats, frame: WorkbenchResolvedFrame) -> SIMD3<Float> {
        let mass = max(stats.totalMassKg, 1e-6)
        let frameMass = max(frame.massKg, 0)
        let span = frame.sizeMeters.x, length = frame.sizeMeters.z
        // Body axes: x to the right, y up, z along the fuselage. A rod of length l about its
        // middle is m·l²/12.
        // A frame drawn in CAD brings the distribution of its own solids; the rods stand in for
        // a library frame, which is one number.
        let own = stats.frameSecondMoments ?? SIMD3<Double>(
            frameMassAlongSpan * frameMass * span * span / 12, 0,
            (1 - frameMassAlongSpan) * frameMass * length * length / 12)
        let m = stats.secondMomentsAboutCenterOfMass
        let roll = m.x + m.y + own.x + own.y
        let pitch = m.y + m.z + own.y + own.z
        let yaw = m.x + m.z + own.x + own.z
        return SIMD3<Float>(Float((roll / mass).squareRoot()), Float((pitch / mass).squareRoot()),
                            Float((yaw / mass).squareRoot()))
    }

    /// Share of a bare multicopter frame's mass that is in its arms rather than its centre
    /// plates. The frame arrives as one mass; the arms are taken as rods from the centre to the
    /// motor mounts, the rest as sitting at the centre.
    private static let frameMassInArms: Double = 0.5

    /// Radii of gyration of a designed multicopter about (roll, pitch, yaw): every fitted part
    /// where it is fitted — the motors and propellers out at their mounts, the pack, the payload
    /// and the avionics wherever the Workbench has them — plus the frame's arms.
    ///
    /// ⚠️ The solver's own figure is half the aircraft's mass at 0.35 of its footprint, whatever is
    /// fitted. For a five-inch quad that is about right. For the Atlas X4 with a six-cell pack and
    /// a gimbal on the centreline it is twice the inertia the layout has, three times in yaw, and
    /// the component graph, drawn from the picture, is held to within a factor of three of it.
    private static func multicopterGyrationRadii(stats: WorkbenchBuildStats, frame: WorkbenchResolvedFrame) -> SIMD3<Float>? {
        let mass = stats.totalMassKg
        guard mass > 0.02, !frame.motorMounts.isEmpty else { return nil }
        let armMass = frameMassInArms * max(frame.massKg, 0) / Double(frame.motorMounts.count)
        // Body axes: x to the right, y up, z along the nose. A rod from the centre out to a
        // mount, about the centre, is m·l²/3, shared between the axes as the mount lies.
        var armsAcross = 0.0, armsAlong = 0.0
        for mount in frame.motorMounts {
            armsAcross += armMass * Double(mount.x * mount.x) / 3
            armsAlong += armMass * Double(mount.z * mount.z) / 3
        }
        // A frame drawn in CAD brings the distribution of its own solids instead.
        let own = stats.frameSecondMoments ?? SIMD3<Double>(armsAcross, 0, armsAlong)
        let m = stats.secondMomentsAboutCenterOfMass
        let roll = m.x + m.y + own.x + own.y
        let pitch = m.y + m.z + own.y + own.z
        let yaw = m.x + m.z + own.x + own.z
        return SIMD3<Float>(Float((roll / mass).squareRoot()), Float((pitch / mass).squareRoot()),
                            Float((yaw / mass).squareRoot()))
    }

    /// How strong the airframe is against the loads it is designed for, as its own strength
    /// calculations found it: 1 for a build that has not been calculated, the reserve factor of
    /// its static cases for one that has.
    ///
    /// The same factor already scales the damage model's section capacities, the energy a part
    /// absorbs before it fails, and the load factors of the flight envelope — it is how a foam
    /// survey wing and a research airframe are told apart in the catalogue. A build whose
    /// governing case has a reserve of 0.7 fails at seven tenths of the loads its class is
    /// designed for, and that is where it now breaks in the air.
    ///
    /// Held to 0.4…1.5. Below the first the envelope's own floor takes over; above the second the
    /// cases that were calculated are not the whole airframe, and a wing spar found twice as
    /// strong as it need be says nothing about the tail.
    static func structuralQuality(for build: WorkbenchBuild) -> Float {
        guard let reserve = build.structuralReserveFactor, reserve.isFinite, reserve > 0 else { return 1.0 }
        return Float(min(max(reserve, 0.4), 1.5))
    }

    /// Electrical power in to thrust power out at the propeller's design point: 0.80 for the
    /// motor and its controller, 0.75 for the propeller.
    private static let electricalToThrustPower: Float = 0.80 * 0.75

    private static let envelopeLock = NSLock()
    private static var envelopeCache: (build: WorkbenchBuild, envelope: DesignedWingEnvelope?)?

    /// `nil` for a multicopter, and for a lift-and-cruise frame with no motor left over to pull it:
    /// neither has a wing-borne flight to describe.
    ///
    /// ⚠️ A lift-and-cruise build flew the old figures until 2026-10-08: the solver sized a wing to
    /// the speed its propeller's pitch suggested and flew 0.11 m² where the Aquila LC-4 frame
    /// draws 0.43 m², stalling at 15 m/s an aircraft whose own wing stalls at 7.5.
    static func designedEnvelope(for build: WorkbenchBuild) -> DesignedWingEnvelope? {
        envelopeLock.lock()
        defer { envelopeLock.unlock() }
        // One entry is the whole need: the build being flown is asked for many times over.
        if let cached = envelopeCache, cached.build == build { return cached.envelope }
        let envelope = deriveEnvelope(for: build)
        envelopeCache = (build, envelope)
        return envelope
    }

    private static func deriveEnvelope(for build: WorkbenchBuild) -> DesignedWingEnvelope? {
        let frame = build.resolvedFrame
        guard frame.architecture != .multicopter else { return nil }
        let isVTOL = frame.architecture == .liftCruiseVTOL
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        // On the wing a lift-and-cruise aircraft is pulled by its cruise motors alone; the lift
        // motors are the larger part of what is installed and none of what flies it there.
        let wingborneElectricalWatts: Double
        if isVTOL {
            let cruiseMotorCount = max(frame.motorMounts.count - frame.liftMotorCount, 0)
            guard cruiseMotorCount > 0 else { return nil }
            wingborneElectricalWatts = Double(cruiseMotorCount)
                * (build.spec(for: .motor)?.param(WorkbenchComponentSpec.ParamKey.motorMaxPowerW) ?? 0)
        } else {
            wingborneElectricalWatts = stats.maxElectricalPowerW
        }
        let mass = Float(stats.totalMassKg)
        let span = Float(frame.sizeMeters.x)
        let length = Float(frame.sizeMeters.z)
        guard mass > 0.02, span > 0.05, length > 0.05 else { return nil }
        // The reference area the analyzer's own aerodynamic checks already use.
        let area = max(Float(frame.wingAreaM2), span * length * 0.18)
        // The planform and the authority the build is flown with, so the polar read here is the
        // one the solver builds.
        let family = frame.fixedWingPlanform ?? (isVTOL ? .surveyEVTOL : .conventionalSurvey)
        let turnAuthority: Float = isVTOL ? 0.62 : 0.72
        let weight = mass * 9.81
        let density = AtmosphereModel.seaLevelDensity
        let engineering = EngineeringAeroRuntime.resolve(build: build)

        func wing(stallSpeed: Float) -> FixedWingAerodynamics {
            FixedWingAerodynamics.build(
                family: family, massKg: mass, wingSpanM: span, fuselageLengthM: length,
                heightM: Float(frame.sizeMeters.y), turnAuthority: turnAuthority,
                minSustainableSpeedMps: stallSpeed, designMassKg: mass, profileID: profileID(for: build),
                engineering: engineering, wingAreaM2: area)
        }
        /// Highest lift the polar reaches and the lift it has at its best lift-to-drag.
        func polarPoints(_ aero: FixedWingAerodynamics) -> (maximumLift: Float, bestGlideLift: Float) {
            var maximumLift: Float = 0.1
            var bestRatio: Float = 0
            var bestGlideLift: Float = 0.5
            var alpha: Float = 0.0
            while alpha <= aero.stallAlphaRad + 0.035 {
                let point = aero.liftDrag(alphaRad: alpha)
                maximumLift = max(maximumLift, point.cl)
                if alpha <= aero.stallAlphaRad, point.cl > 0.05, point.cd > 0, point.cl / point.cd > bestRatio {
                    bestRatio = point.cl / point.cd
                    bestGlideLift = point.cl
                }
                alpha += 0.004
            }
            return (maximumLift, bestGlideLift)
        }
        func speed(forLift lift: Float, _ aero: FixedWingAerodynamics) -> Float {
            (2 * weight / (density * aero.wingArea * max(0.05, lift))).squareRoot()
        }

        // The polar is built twice: its damping floors take the stall speed as an input, and the
        // stall speed is what the polar is being asked for.
        var aero = wing(stallSpeed: 10)
        let stall = speed(forLift: polarPoints(aero).maximumLift, aero)
        aero = wing(stallSpeed: stall)
        let points = polarPoints(aero)

        // Cruise at the best lift-to-drag — the speed a propeller aircraft covers most ground on —
        // never closer to the stall than 1.3 of it, and not past what the propeller's pitch allows.
        let pitchLimitedSpeed = Float(stats.estimatedMaxSpeedMps)
        var cruise = max(1.3 * stall, speed(forLift: points.bestGlideLift, aero))
        if pitchLimitedSpeed > 0 {
            cruise = min(cruise, max(1.3 * stall, 0.9 * pitchLimitedSpeed))
        }
        // The same rule the catalogue airframes take their climb speed from.
        let climbSpeed = max(1.15 * stall, 0.85 * cruise)

        var climbRate: Float?
        var maximumSpeed = max(cruise * 1.25, pitchLimitedSpeed > 0 ? min(pitchLimitedSpeed, cruise * 1.6) : cruise * 1.25)
        let thrustPower = Float(wingborneElectricalWatts) * electricalToThrustPower
        if thrustPower > 1 {
            let climbDrag = AirframePerformanceEstimate.levelDrag(aero, speed: climbSpeed, weight: weight, density: density)
            let efficiency = max(0.3, FixedPitchPropellerShape.efficiency(speed: climbSpeed, cruiseSpeed: cruise))
            let available = (thrustPower * efficiency - climbDrag * climbSpeed) / weight
            // Not past a 34 % gradient: beyond it the attitude limit, not the motor, sets the
            // climb, and an aircraft with thrust to hover is not described by a rate of climb.
            let rate = min(max(available, 0.5), 0.34 * climbSpeed)
            climbRate = rate
            // The solver sizes its power from that climb at that speed. The top speed is where
            // the same power, falling off with the propeller, meets the drag.
            let sizedPower = (climbDrag + weight * rate / climbSpeed) * climbSpeed / efficiency
            let ceiling = pitchLimitedSpeed > cruise ? pitchLimitedSpeed : cruise * 2.5
            var fastest = cruise
            while fastest + 0.25 <= ceiling {
                let next = fastest + 0.25
                let thrust = sizedPower * FixedPitchPropellerShape.efficiency(speed: next, cruiseSpeed: cruise) / next
                if thrust < AirframePerformanceEstimate.levelDrag(aero, speed: next, weight: weight, density: density) { break }
                fastest = next
            }
            maximumSpeed = fastest
        }
        let cruiseDrag = AirframePerformanceEstimate.levelDrag(aero, speed: cruise, weight: weight, density: density)
        // What the battery lasts in level cruise on the designed wing. 0.82 of the pack is usable,
        // the allowance the lift-and-cruise estimate already makes.
        let cruiseElectricalWatts = Double(cruiseDrag * cruise / electricalToThrustPower)
        let flightMinutes: Double? = stats.batteryEnergyWh > 0 && cruiseElectricalWatts > 0
            ? stats.batteryEnergyWh / cruiseElectricalWatts * 60 * 0.82 : nil
        return DesignedWingEnvelope(
            wingAreaM2: aero.wingArea, stallSpeedMps: stall, cruiseSpeedMps: cruise,
            climbSpeedMps: climbSpeed, climbRateMps: climbRate, maximumSpeedMps: maximumSpeed,
            cruiseThrustPowerW: cruiseDrag * cruise,
            gyrationRadiiMeters: gyrationRadii(stats: stats, frame: frame),
            flightMinutes: flightMinutes)
    }

    static func abstractParameters(for build: WorkbenchBuild) -> AbstractDroneParameters {
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        let frame = build.resolvedFrame
        let dimensions = frame.sizeMeters
        let speed = Float(max(4, designedEnvelope(for: build).map { Double($0.maximumSpeedMps) } ?? stats.estimatedMaxSpeedMps))
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
        let frame = build.resolvedFrame
        let architecture = frame.architecture
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
        var profile = DroneModelProfile(
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
                speed: parameters.maxHorizontalSpeedMps,
                planform: frame.fixedWingPlanform,
                envelope: designedEnvelope(for: build)),
            launchMethod: runtimeArchitecture.launchMethod,
            landingMethod: runtimeArchitecture.landingMethod,
            controlResponsiveness: parameters.controlResponsiveness,
            hoverThrottle: hoverThrottle,
            cameraPreset: DroneCameraPreset(fpvFov: 92, followDistance: 5.8, followHeight: 2.4),
            collisionRadiusMeters: parameters.collisionRadiusMeters,
            propulsionUnitTemplate: propulsionUnits,
            notes: "Синтезировано из Workbench: \(stats.componentCount) компонентов",
            sourceURL: nil,
            workbenchBuild: build,
            structuralQualityFactor: structuralQuality(for: build))
        // Declared skin, or the aluminium every build has implicitly been made of until
        // now. Applied after construction because it is a property of the airframe rather
        // than a flight parameter, and the initialiser above takes flight parameters.
        profile.skinMaterial = frame.skinMaterial ?? .aluminium
        profile.engineeringAerodynamics = EngineeringAeroRuntime.resolve(build: build)
        if architecture == .multicopter {
            profile.multirotorGyrationRadiiMeters = multicopterGyrationRadii(stats: stats, frame: frame)
        }
        return profile
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
            nominalCruiseSpeedMps: designedEnvelope(for: build)?.cruiseSpeedMps ?? Float(stats.estimatedMaxSpeedMps),
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
        speed: Float,
        planform: FixedWingFamily?,
        envelope: DesignedWingEnvelope? = nil
    ) -> FixedWingParameters? {
        guard architecture != .multicopter else { return nil }
        let isVTOL = architecture == .liftCruiseVTOL
        if let envelope {
            let cruise = envelope.cruiseSpeedMps
            var designed = FixedWingParameters(
                family: planform ?? (isVTOL ? .surveyEVTOL : .conventionalSurvey),
                minSustainableSpeedMps: envelope.stallSpeedMps,
                cruiseSpeedMps: cruise,
                climbSpeedMps: envelope.climbSpeedMps,
                stallWarningSpeedMps: envelope.stallSpeedMps * 0.95,
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
                maxAirspeed: envelope.maximumSpeedMps,
                nominalClimbRateMps: envelope.climbRateMps,
                initialClimbPitchDeg: isVTOL ? 9.0 : 11.0,
                initialClimbTargetAltitude: isVTOL ? 14.0 : 18.0)
            designed.wingAreaM2 = envelope.wingAreaM2
            // The lift motors of a lift-and-cruise build are parts like any other and are
            // counted where they are fitted, out on their booms. On its rotors the aircraft is
            // turned by a rate loop that does not divide by inertia; these radii decide how it
            // answers its control surfaces once the wing has it.
            designed.gyrationRadiiMeters = envelope.gyrationRadiiMeters
            return designed
        }
        let cruise = max(13.0, min(speed, 34.0))
        let stall = max(7.0, cruise * 0.56)
        let minimum = max(stall + 0.8, cruise * 0.64)
        let climb = max(minimum + 1.0, cruise * 0.78)
        return FixedWingParameters(
            // A frame that declares its own planform gets it. Without that declaration the
            // choice below is the safe one rather than the right one — it is what the
            // synthesizer has always assumed, and it stays the assumption for every build
            // that does not say otherwise.
            family: planform ?? (isVTOL ? .surveyEVTOL : .conventionalSurvey),
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
            // The designed wing's own cruise. The figure used to be the time the same parts would
            // hover for — twelve minutes for an aircraft whose cruise takes a thirtieth of its motor.
            if let minutes = designedEnvelope(for: build)?.flightMinutes {
                return EnduranceEstimate(hover: 0, maximumFlight: minutes)
            }
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
            // The analyzer's figure: the lift motors alone, power as thrust to the three-halves.
            let hover = max(stats.estimatedHoverTimeMin, 0)

            let cruiseMotorCount = max(frame.motorMounts.count - frame.liftMotorCount, 0)
            guard cruiseMotorCount > 0 else {
                return EnduranceEstimate(hover: hover, maximumFlight: hover)
            }
            // On the wing: what the drawn wing's drag takes at its cruise. The figure used to be
            // 38 % of the cruise motor's rating plus 35 W whatever the aircraft was — 233 W for a
            // 2.3 kg build whose cruise drag takes 27 W of thrust power, under five minutes where
            // the wing gives it over twenty.
            if let minutes = designedEnvelope(for: build)?.flightMinutes {
                return EnduranceEstimate(hover: hover, maximumFlight: max(hover, minutes))
            }
            let cruisePower = motorPower * Double(cruiseMotorCount) * 0.38 + 35
            let cruise = stats.batteryEnergyWh / max(cruisePower, 1) * 60 * 0.82
            return EnduranceEstimate(hover: hover, maximumFlight: max(hover, cruise))
        }
    }
}
