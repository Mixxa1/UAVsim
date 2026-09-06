import Foundation
import simd

/// One independently integrated world actor: the target or the observer.
///
/// It runs the same flight model, the same component graph, the same impact resolver and the same
/// RF stack the player's aircraft runs. What it does not have is any connection to the app's UI —
/// no keyboard, no view-model timer, no viewport and no SceneKit nodes. The scene adapter reads
/// this object's state to place a model; nothing here reads the scene back.
final class InterceptVehicleRuntime {
    let id: String
    let role: InterceptVehicleRole
    let profile: DroneModelProfile
    let massModel: VehicleMassModel
    let spawnPosition: SIMD3<Float>
    var state: DroneState
    private(set) var previousState: DroneState
    var graph: VehicleComponentGraph
    let failures: ComponentFailureRuntime
    var payload: AttachedPayloadComponent?
    private(set) var battery: BatteryState = .full
    private(set) var contactProfile: VehicleContactProfile
    private(set) var rotorModel: VehicleRotorModel
    private(set) var video: RFVideoPresentationState = .unavailable
    private(set) var controlEvaluation: RFLinkEvaluation?

    private let pristineContacts: VehicleContactProfile
    private let pristineRotors: VehicleRotorModel
    private let physics = SimpleDronePhysicsEngine()
    private let collision = CollisionAnalysisService()
    private let impactResolver = ImpactResolutionService()
    private let batteryService = BatteryThermalSimulationService()
    private let baseRF: RFSystemConfiguration
    private var radioAccumulator: Float = 0
    private var packetStates: [LogicalLinkKind: RFPacketDeliveryState] = [:]
    private let channelScheduler = RFSharedChannelScheduler()
    private let groundID = UUID()
    private var wasGrounded = false

    /// Fixed-wing actors fly the app's own route follower rather than the hover controller — an
    /// aeroplane cannot be told to "be at this point", only to fly a leg towards it.
    private let fixedWingController = FixedWingAutopilotController()
    private let flightBaseline: ResolvedFlightBaseline
    /// The leg currently published to the follower, and the counter that gives each republished
    /// leg its own identity so the follower re-anchors instead of tracking a stale one.
    private var publishedLegEnd: SIMD3<Float>?
    private var legGeneration = 0
    /// Scales the airspeed the follower is allowed to ask for. Difficulty's lever on an aeroplane
    /// is how fast it crosses the area, since it cannot manoeuvre the way a rotorcraft can.
    var cruiseSpeedScale: Float = 1

    var isFixedWing: Bool { profile.airframeClass == .fixedWing }

    /// What this aircraft sounds like to somebody standing off from it, and a stable identity for
    /// the mixer to key its loop on. Every machine in the air is audible: a target crossing at a
    /// hundred metres and an observer holding station overhead are the two things the operator
    /// should be able to hear coming, and both were silent.
    let audioProfile: VehicleAudioProfile
    let audioID = UUID()

    /// Mean rotor speed, for an airframe that has rotors. An aeroplane returns nil and lets the
    /// audio layer infer its note from airspeed, which is the honest source for a propeller
    /// turning at a governed rate behind a fixed pitch.
    var audioShaftSpeedRadPerSec: Float? {
        guard !isFixedWing else { return nil }
        let speeds = state.rotorAngularSpeed
        let live = [speeds.x, speeds.y, speeds.z, speeds.w].filter { $0 > 0 }
        guard !live.isEmpty else { return 0 }
        return live.reduce(0, +) / Float(live.count)
    }

    // MARK: Tuning

    /// A subsystem below this fraction of nominal is treated as gone rather than weak.
    private static let functionalThreshold: Float = 0.05
    /// Hover-assist trim. The autopilot works from the target position; this is only the value the
    /// throttle channel sits at while it does.
    private static let hoverThrottle: Float = 0.5
    /// The flight model clamps altitude to `context.groundHeight` and would settle the aircraft
    /// there on its own. This runtime owns ground contact instead — it needs the impact, the
    /// damage and the crash state, not a silent clamp — so the model is handed a floor well below
    /// the real surface and never reaches it first.
    private static let physicsFloorClearance: Float = 2
    /// Below this speed a grounded actor is called settled and its residual motion is bled off.
    private static let restingSpeed: Float = 0.2
    /// Angular rate above which an airborne actor reads as tumbling rather than flying.
    private static let tumblingRate: Float = 1.8
    /// Descent rate below which an airborne actor reads as falling.
    private static let fallingSpeed: Float = -0.55
    /// The RF stack is evaluated on its own cadence rather than every physics tick.
    private static let radioInterval: Float = 0.05
    /// Cosine of the course change that justifies re-anchoring the follower (about 3°). Tighter
    /// than this and every tick would republish, resetting the turn it is halfway through.
    private static let legCourseTolerance: Float = 0.9986
    /// Republish once the aeroplane is this close to the end of its leg, so it always has
    /// somewhere to fly and never captures the waypoint and stops.
    private static let legRefreshRange: Float = 260
    /// Rotors below this share of nominal thrust cannot hold the aircraft up.
    private static let insufficientThrustFactor: Float = 0.35
    /// Integrity below this counts as wear worth reporting; above it the airframe reads pristine.
    private static let pristineIntegrity: Float = 0.985
    /// A control or power path this far gone takes the aircraft with it.
    private static let controlLossFactor: Float = 0.2

    init(
        id: String,
        role: InterceptVehicleRole,
        profile: DroneModelProfile,
        massModel: VehicleMassModel,
        position: SIMD3<Float>,
        graph: VehicleComponentGraph,
        contacts: VehicleContactProfile,
        rotors: VehicleRotorModel,
        payload: AttachedPayloadComponent?,
        seed: UInt64,
        initialCourse: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    ) {
        self.id = id
        self.role = role
        self.profile = profile
        self.massModel = massModel
        self.graph = graph
        self.payload = payload
        spawnPosition = position
        pristineContacts = contacts
        contactProfile = contacts
        pristineRotors = rotors
        rotorModel = rotors
        failures = ComponentFailureRuntime(seed: seed)
        let powerplant = profile.resolvedUAVProfile?.powerplant
        audioProfile = VehicleAudioProfile.resolve(
            airframeClass: profile.airframeClass,
            engineType: powerplant?.engineType,
            rotorCount: max(1, rotors.rotors.count),
            takeoffMassKg: profile.takeoffMassKg,
            maxHorizontalSpeedMps: profile.maxHorizontalSpeedMps,
            ratedShaftRPM: powerplant?.ratedShaftRPM,
            propellerBladeCount: powerplant?.propellerBladeCount ?? 2,
            vehicleType: profile.resolvedUAVProfile?.vehicleType
        )
        flightBaseline = FlightBaselineResolver.resolve(
            runtimeProfile: profile,
            activeUAVProfile: profile.resolvedUAVProfile,
            vehicleMassModel: massModel,
            flightMode: profile.airframeClass == .fixedWing ? .autoPath : .hover
        )

        var initial = DroneState.initial
        initial.position = position
        initial.physicalState = .airborne
        initial.armState = .armed
        initial.motionState = .airborne
        initial.throttle = Self.hoverThrottle
        initial.motorThrottle = Self.hoverThrottle
        // An aeroplane dropped into the world at rest is an aeroplane that falls out of it. It
        // starts on its course, at cruise, already flying — which is also what the scenario says
        // it is: an aircraft that was transiting the area before the run began.
        if profile.airframeClass == .fixedWing, let wing = profile.fixedWingParameters {
            let course = Self.horizontalCourse(initialCourse)
            initial.velocity = course * wing.cruiseAirspeed
            initial.forwardAirspeed = wing.cruiseAirspeed
            initial.orientation.z = atan2(-course.x, -course.z)
            // `orientation` is a display copy: the fixed-wing path integrates `attitudeQuat`, and
            // anything that writes the Euler angles from outside the physics step has to rebuild
            // the quaternion or the next substep flies the stale attitude. Skipping this spawned
            // the aeroplane nose-first down its old heading while moving along the new one — a
            // 29 m/s tail-first entry that tore itself out of the sky within two seconds.
            initial.attitudeQuat = Self.attitudeQuaternion(euler: initial.orientation)
            initial.bodyAngularVelocity = .zero
            initial.throttle = flightBaseline.cruiseReferenceThrottle
            initial.motorThrottle = flightBaseline.cruiseReferenceThrottle
            initial.mode = .autoPath
        }
        state = initial
        previousState = initial
        baseRF = RFCompatibilityPreset.make(for: profile)
    }

    private static func horizontalCourse(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let flat = SIMD3<Float>(vector.x, 0, vector.z)
        return simd_length_squared(flat) > 1e-6 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
    }

    /// Same composition order the view model's `resyncAttitudeQuaternionFromEuler` uses: yaw about
    /// world up, then pitch, then roll.
    private static func attitudeQuaternion(euler: SIMD3<Float>) -> simd_quatf {
        simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: euler.y, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: euler.x, axis: SIMD3<Float>(0, 0, 1))
    }

    // MARK: - Snapshot

    var snapshot: InterceptVehicleSnapshot {
        Self.snapshot(id: id, role: role, state: state, payload: payload)
    }

    /// Condenses a full flight state into the handful of facts the scenario rules are allowed to
    /// act on. Shared with the player's aircraft so both are judged by exactly the same ladder.
    static func snapshot(
        id: String,
        role: InterceptVehicleRole,
        state: DroneState,
        payload: AttachedPayloadComponent?
    ) -> InterceptVehicleSnapshot {
        let functional: InterceptFunctionalState
        if state.damageCondition == .destroyed {
            functional = .destroyed
        } else if state.physicalState == .crashed {
            functional = .crashed
        } else if state.controlState == .none || state.damageCondition == .uncontrolled {
            // On the ground with no control it is finished; still in the air it is a falling
            // aircraft, which the mission has to keep watching rather than write off.
            functional = [.grounded, .settled, .sliding, .rolling].contains(state.motionState) ? .disabled : .uncontrolled
        } else if state.damageCondition == .critical || state.controlState == .insufficient {
            functional = .uncontrolled
        } else if state.controlState != .full {
            functional = .degraded
        } else if state.damageCondition != .nominal {
            functional = .damaged
        } else {
            functional = .nominal
        }
        return InterceptVehicleSnapshot(
            id: id,
            role: role,
            position: state.position,
            velocity: state.velocity,
            functionalState: functional,
            payloadState: payload?.state
        )
    }

    // MARK: - Integration

    /// Advances one physics step towards `desiredPosition` and returns the contacts worth
    /// reporting. Environment and terrain contacts are resolved here; vehicle-to-vehicle contact
    /// belongs to `VehiclePairContactService`, which needs both bodies at once.
    func step(
        deltaTime: Float,
        desiredPosition: SIMD3<Float>,
        weather: WeatherModel,
        wind: SIMD3<Float>,
        groundHeight: Float,
        obstacles: [CollisionObstacle]
    ) -> [ImpactReport] {
        previousState = state
        failures.tick(deltaTime: deltaTime)
        refreshDamage()

        let power = InterceptRFDamageAdapter.factor("battery", graph, failures)
        let controller = InterceptRFDamageAdapter.factor("flightController", graph, failures)
        let canPower = power > Self.functionalThreshold
            && controller > Self.functionalThreshold
            && !battery.isDepleted
            && state.damageCondition != .destroyed
        let legacy = graph.projectedLegacyDamageState(base: .pristine)

        let context = DroneSimulationContext(
            profile: profile,
            activeUAVProfile: profile.resolvedUAVProfile,
            weather: weather,
            damageState: legacy,
            batteryState: battery,
            collisionRisk: 0,
            windVector: wind,
            vehicleMassModel: massModel,
            vehicleMassProperties: graph.massProperties,
            contactProfile: contactProfile,
            rotorModel: rotorModel,
            aeroDamage: FixedWingAeroDamage.build(from: graph),
            jammedSurfaces: failures.jammedSurfaces(),
            powerSystemFactor: power,
            controlSystemFactor: controller,
            groundHeight: groundHeight - contactProfile.boundingRadius - Self.physicsFloorClearance
        )
        let input = isFixedWing
            ? fixedWingInput(aimPoint: desiredPosition, groundHeight: groundHeight, canPower: canPower, deltaTime: deltaTime)
            : DroneControlInput(
                targetPosition: desiredPosition,
                targetOrientation: .zero,
                yawIntent: 0,
                throttle: canPower ? Self.hoverThrottle : 0,
                isArmed: canPower,
                mode: .hover,
                controlMode: .hoverAssist
            )
        state = physics.step(state: state, control: input, context: context, deltaTime: deltaTime)
        state.armState = canPower ? .armed : .disarmed

        var reports: [ImpactReport] = []
        if let report = resolveObstacleContact(obstacles: obstacles, rotorsSpinning: canPower, deltaTime: deltaTime) {
            reports.append(report)
        }
        if let report = resolveGroundContact(groundHeight: groundHeight, rotorsSpinning: canPower, deltaTime: deltaTime) {
            reports.append(report)
        }

        battery = batteryService.updateBattery(
            current: battery,
            input: BatteryComputationInput(
                droneProfile: profile,
                weather: weather,
                damageState: legacy,
                speedMps: simd_length(state.velocity),
                verticalSpeedMps: state.velocity.y,
                throttle: state.motorThrottle,
                maneuverAggressiveness: min(1, simd_length(state.angularVelocity))
            ),
            deltaTime: deltaTime
        )
        refreshDamage()
        return reports
    }

    /// Flies the aeroplane towards `aimPoint` on the app's own fixed-wing route follower — the
    /// same one the operator's aircraft uses, so a transiting target obeys the same bank limits,
    /// stall margins and turn radii as anything else in the world.
    ///
    /// The follower needs a leg, not a destination, so the actor keeps one published and renews
    /// it when the aim has moved or the end is coming up. Republishing every tick would reset the
    /// turn it is halfway through; never republishing would let it capture the end and stop.
    private func fixedWingInput(
        aimPoint: SIMD3<Float>,
        groundHeight: Float,
        canPower: Bool,
        deltaTime: Float
    ) -> DroneControlInput {
        guard let wing = profile.fixedWingParameters else {
            return DroneControlInput(
                targetPosition: aimPoint,
                targetOrientation: .zero,
                yawIntent: 0,
                throttle: canPower ? Self.hoverThrottle : 0,
                isArmed: canPower,
                mode: .hover,
                controlMode: .hoverAssist
            )
        }

        // Republish on a change of *course*, not on how far the aim point has moved. The aim point
        // is defined relative to the aircraft and therefore travels with it — judging it by
        // distance meant the aeroplane held a stale heading for seconds after the guidance had
        // already asked it to turn, which is several hundred metres of overshoot at cruise.
        let legEnd = publishedLegEnd
        var needsRepublish = legEnd == nil
        if let legEnd {
            let published = Self.horizontalCourse(legEnd - state.position)
            let requested = Self.horizontalCourse(aimPoint - state.position)
            needsRepublish = simd_dot(published, requested) < Self.legCourseTolerance
                || simd_distance(state.position, legEnd) < Self.legRefreshRange
        }
        if needsRepublish {
            publishedLegEnd = aimPoint
            legGeneration += 1
        }
        let target = publishedLegEnd ?? aimPoint

        let tracking = FixedWingRouteTrackingContext(
            routeIdentifier: "\(id)-leg-\(legGeneration)",
            waypoints: [
                FixedWingRouteWaypoint(position: state.position, missionWaypointIndex: nil, waypointIdentifier: nil),
                FixedWingRouteWaypoint(position: target, missionWaypointIndex: nil, waypointIdentifier: nil)
            ],
            minimumWaypointIndex: 1,
            preferredLoiterCenter: nil,
            preferredLoiterRadius: nil,
            turnsValidated: true,
            validatedTurnRadiusMeters: nil,
            validatedAirspeedMps: wing.cruiseAirspeed,
            flyableRoute: nil
        )
        let context = AutopilotTrackingContext(
            state: state,
            physicalState: state.physicalState,
            target: target,
            targetAltitude: target.y,
            speedScale: 1,
            yawAlignToHome: false,
            yawOverrideRadians: nil,
            deltaTime: max(0.001, deltaTime),
            flightBaseline: flightBaseline,
            heightAboveSurfaceMeters: state.position.y - groundHeight
        )
        // Difficulty slows the aeroplane down rather than making it turn harder, but never below
        // a speed it can actually stay in the air at.
        let cappedCruise = max(wing.minSafeAirspeed * 1.15, wing.cruiseAirspeed * cruiseSpeedScale)
        let output = fixedWingController.trackingCommand(
            for: context,
            parameters: wing,
            launchMode: .standard,
            launchAsset: nil,
            routeTracking: tracking,
            missionMaxAirspeed: cappedCruise
        )
        return DroneControlInput(
            targetPosition: output.command.positionTarget,
            targetOrientation: SIMD3<Float>(
                output.command.rollDegrees * .pi / 180,
                output.command.pitchDegrees * .pi / 180,
                output.command.yawDegrees * .pi / 180
            ),
            yawIntent: 0,
            throttle: canPower ? output.command.throttle : 0,
            isArmed: canPower,
            mode: .autoPath,
            controlMode: .stabilized
        )
    }

    private func resolveObstacleContact(
        obstacles: [CollisionObstacle],
        rotorsSpinning: Bool,
        deltaTime: Float
    ) -> ImpactReport? {
        guard let contact = collision.firstSweptVehicleCollision(
            contactSpheres: contactProfile.spheres,
            fromPosition: previousState.position,
            toPosition: state.position,
            fromOrientation: previousState.attitudeQuat,
            toOrientation: state.attitudeQuat,
            obstacles: obstacles
        ) else { return nil }
        let report = impactResolver.resolve(
            contact: contact,
            previousPosition: previousState.position,
            state: &state,
            graph: &graph,
            massProperties: graph.massProperties,
            airframeClass: profile.airframeClass,
            rotorsSpinning: rotorsSpinning,
            deltaTime: deltaTime
        )
        receive(report)
        // A sub-centimetre-per-second brush is the solver settling, not an event.
        return report.normalClosingSpeed > 0.05 ? report : nil
    }

    /// Terrain contact. Only the first touch of a landing/crash produces damage and an event; the
    /// aircraft then rests on the surface without the resolver restarting every tick.
    private func resolveGroundContact(
        groundHeight: Float,
        rotorsSpinning: Bool,
        deltaTime: Float
    ) -> ImpactReport? {
        guard let lowest = contactProfile.lowestContact(position: state.position, orientation: state.attitudeQuat),
              lowest.point.y <= groundHeight else {
            wasGrounded = false
            state.motionState = simd_length(state.angularVelocity) > Self.tumblingRate ? .tumbling
                : state.velocity.y < Self.fallingSpeed ? .falling
                : .airborne
            return nil
        }
        let previousLow = contactProfile.lowestPointY(position: previousState.position, orientation: previousState.attitudeQuat)
        let fraction = max(0, min(1, (previousLow - groundHeight) / max(0.0001, previousLow - lowest.point.y)))
        let obstacle = CollisionObstacle(
            id: groundID,
            center: SIMD3<Float>(state.position.x, groundHeight, state.position.z),
            radius: 10000,
            source: InterceptContactSource.terrain,
            baseY: groundHeight - 1,
            topY: groundHeight,
            acousticSurface: .soil
        )
        let contact = VehicleSweptContact(
            obstacle: obstacle,
            componentID: lowest.sphere.componentID,
            contactPoint: SIMD3<Float>(lowest.point.x, groundHeight, lowest.point.z),
            contactNormal: SIMD3<Float>(0, 1, 0),
            hitFraction: fraction,
            isSupportSurfaceContact: true,
            sphereOffset: lowest.sphere.offset,
            sphereRadius: lowest.sphere.radius
        )
        let isFirstTouch = !wasGrounded
        let report = impactResolver.resolve(
            contact: contact,
            previousPosition: previousState.position,
            state: &state,
            graph: &graph,
            massProperties: graph.massProperties,
            airframeClass: profile.airframeClass,
            rotorsSpinning: rotorsSpinning,
            deltaTime: deltaTime,
            applyDamage: isFirstTouch,
            restingSpeedThreshold: 0.1
        )
        state.position.y += max(0, groundHeight - contactProfile.lowestPointY(position: state.position, orientation: state.attitudeQuat))
        if isFirstTouch { receive(report) }
        // An aircraft that arrives on the ground already broken, or arrives hard, has crashed —
        // as opposed to one that simply set down.
        if !snapshot.functionalState.canAttempt || report.tier == .criticalImpact || report.tier == .heavyImpact {
            state.physicalState = .crashed
        }
        if simd_length(state.velocity) < Self.restingSpeed {
            state.velocity = .zero
            state.angularVelocity *= 0.9
        }
        state.motionState = simd_length(state.velocity) < Self.restingSpeed ? .settled : .sliding
        wasGrounded = true
        return isFirstTouch ? report : nil
    }

    // MARK: - Damage

    func receive(_ report: ImpactReport) {
        failures.noteDamage(entries: report.damage, graph: graph, currentAileron: 0, currentElevator: 0, currentRudder: 0)
        for root in graph.failedConnectionRootIDs { _ = graph.detachSubtree(rootComponentID: root) }
        refreshDamage()
    }

    /// Re-derives everything the flight model reads from the component graph: which contact
    /// spheres still exist, what each rotor can still pull, and the two condition enums the
    /// scenario snapshot is built from.
    func refreshDamage() {
        let detached = Set(graph.components.filter { !$0.isAttached }.map(\.id))
        contactProfile = pristineContacts.applyingDeformations(from: graph).removing(componentIDs: detached)
        rotorModel = pristineRotors
        for index in rotorModel.rotors.indices {
            let slot = rotorModel.rotors[index].slot
            let prop = graph.integrity(id: "propeller.\(slot)")
            let motor = graph.integrity(id: "motor.\(slot)")
            let attached = graph.component(id: "motor.\(slot)")?.isAttached ?? true
            rotorModel.rotors[index].thrustFactor = attached
                ? VehicleRotorModel.propellerThrustFactor(integrity: prop)
                    * VehicleRotorModel.motorThrustFactor(integrity: motor)
                    * failures.motorFailureFactor(slot: slot)
                    * InterceptRFDamageAdapter.factor("esc", graph, failures)
                : 0
            rotorModel.rotors[index].vibration01 = VehicleRotorModel.propellerVibration(integrity: prop)
        }

        let coreLost = ["frame", "fuselage"].contains { graph.component(id: $0) != nil && graph.integrity(id: $0) <= 0.001 }
        let controlsLost = InterceptRFDamageAdapter.factor("flightController", graph, failures) <= Self.controlLossFactor
            || InterceptRFDamageAdapter.factor("battery", graph, failures) <= Self.controlLossFactor
            || battery.isDepleted
        let damaged = graph.components.contains { !$0.isAttached || $0.integrity < Self.pristineIntegrity }
        state.damageCondition = coreLost ? .destroyed : controlsLost ? .uncontrolled : damaged ? .degraded : .nominal
        state.controlState = coreLost || controlsLost ? .none
            : rotorModel.totalThrustFactor < Self.insufficientThrustFactor ? .insufficient
            : damaged ? .reduced
            : .full

        if let mount = graph.component(id: payload?.mountPointID ?? AttachedPayloadComponent.defaultMountPointID) {
            payload?.updateMount(integrity: mount.integrity, attached: mount.isAttached)
        }
    }

    // MARK: - Radio

    /// Runs the actor's own RF stack so its video feed degrades for the same reasons the player's
    /// does: damaged equipment, distance, terrain in the path. The mission never sets RSSI itself.
    func updateRadio(
        deltaTime: Float,
        now: TimeInterval,
        home: SIMD3<Float>,
        environment: RFEnvironmentContext,
        path: (RFPathQuery, RFEndpointPose) -> RFPathContext
    ) {
        radioAccumulator += deltaTime
        guard radioAccumulator >= Self.radioInterval else { return }
        let elapsed = radioAccumulator
        radioAccumulator = 0

        let config = InterceptRFDamageAdapter.configuration(base: baseRF, graph: graph, failures: failures)
        let manager = RFSystemManager(configuration: config)
        let pose = RFEndpointPose(
            positionM: RFVector3D(x: Double(state.position.x), y: Double(state.position.y), z: Double(state.position.z)),
            orientation: RFOrientation(
                yawDegrees: Double(state.orientation.z) * 180 / .pi,
                pitchDegrees: Double(state.orientation.y) * 180 / .pi,
                rollDegrees: Double(state.orientation.x) * 180 / .pi
            )
        )
        let ground = RFEndpointPose(positionM: RFVector3D(x: Double(home.x), y: Double(home.y), z: Double(home.z)))
        let poses = Dictionary(uniqueKeysWithValues: config.devices.map { device in
            (device.id, device.endpoint == .airborne ? pose : ground)
        })
        let results = manager.evaluateAvailableLinks(
            endpointPosesM: poses,
            environment: environment,
            timestamp: now,
            pathContextResolver: { path($0, pose) }
        )
        var evaluations: [LogicalLinkKind: RFLinkEvaluation] = [:]
        for (kind, value) in results {
            if case let .success(evaluation) = value { evaluations[kind] = evaluation }
        }
        controlEvaluation = evaluations[.control]

        let qos = config.qos ?? .migrationDefault
        for (tx, links) in Dictionary(grouping: config.logicalLinks.all.filter(\.usesRFPropagation), by: \.transmitterDeviceID) {
            let inputs = links.compactMap { link -> RFSharedChannelInput? in
                guard let evaluation = evaluations[link.kind] else { return nil }
                return RFSharedChannelInput(
                    linkID: link.id,
                    linkKind: link.kind,
                    state: packetStates[link.kind] ?? .initial,
                    evaluation: evaluation,
                    traffic: qos.trafficProfile(for: link.kind)
                )
            }
            let output = channelScheduler.advance(
                transmitterDeviceID: tx,
                inputs: inputs,
                channelCapacityBPS: links.map(\.qualityProfile.nominalBitrateBps).max() ?? 0,
                qos: qos,
                deltaTime: Double(elapsed)
            )
            for (kind, value) in output.states { packetStates[kind] = value }
        }
        video = presentationState(config: config, evaluations: evaluations)
    }

    private func presentationState(
        config: RFSystemConfiguration,
        evaluations: [LogicalLinkKind: RFLinkEvaluation]
    ) -> RFVideoPresentationState {
        guard let link = config.logicalLinks.video else { return .unavailable }
        let mode = link.videoMode ?? .digital
        guard let evaluation = evaluations[.video] else { return .unavailable(mode: mode) }
        if mode == .analog {
            return AnalogVideoQualityModel().presentationState(for: evaluation)
        }
        let delivery = packetStates[.video]
        let loss = delivery?.smoothedPacketLoss ?? 0
        let freezeAfter = (link.videoLinkPreset ?? .genericDigital).freezeAfterNoDeliverySeconds
        return RFVideoPresentationState(
            mode: mode,
            health: evaluation.quality.health,
            analogNoiseIntensity: 0,
            digitalArtifactIntensity: max(evaluation.quality.packetErrorRate, loss),
            isFrozen: evaluation.quality.health == .lost
                || (delivery?.secondsSinceLastDelivery ?? .infinity) > freezeAfter,
            effectiveBitrateBPS: evaluation.quality.effectiveBitrateBps * (1 - loss),
            latencyMS: evaluation.quality.latencyMS + (delivery?.meanQueueDelaySeconds ?? 0) * 1000
        )
    }
}
