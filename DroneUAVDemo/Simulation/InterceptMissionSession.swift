import Foundation
import simd

/// Owns one interception run: the two world actors, the player's attached module, the observation
/// source list, the world effects and the scenario rules.
///
/// The split it enforces is the stage plan's: physics resolves contacts, the component graph
/// resolves damage, this session normalises both into events, and `InterceptMissionRuntime` reads
/// those events to decide what the mission thinks. Nothing here decides a result, and nothing here
/// touches a camera. A single caller owns mutations for this run.
final class InterceptMissionSession {
    var director: InterceptMissionRuntime
    let target: InterceptVehicleRuntime
    let observer: InterceptVehicleRuntime
    var playerPayload: AttachedPayloadComponent
    var observation = InterceptObservationRuntime()
    var effects = InterceptEffectRuntime()
    private(set) var pendingImpacts: [InterceptImpactEvent] = []
    private(set) var eventHistory: [InterceptMissionEvent] = []
    private(set) var worldTime: TimeInterval = 0
    let origin: SIMD3<Float>

    /// The operator's load once the mission is the delivery one. Nil on the interceptor side,
    /// where the module is spent against a target rather than taken anywhere.
    private(set) var delivery: InterceptDeliveryRuntime?
    /// Pairs currently in contact. A contact is only "fresh" — and therefore only damages, logs
    /// and triggers — on the tick it starts. Without this a single physical touch spread over
    /// several ticks would arrive as a burst of separate impacts.
    private var touchingPairs: Set<String> = []
    private var lastEnvironmentImpact: [String: TimeInterval] = [:]
    /// The target's flight behaviour, including the heading it is currently holding.
    private var targetGuidance = InterceptTargetGuidance()

    // MARK: Tuning

    /// Repeat contacts with the same obstacle inside this window are the same event.
    private static let environmentImpactCooldown: TimeInterval = 0.25
    private static let contactEffectLifetime: TimeInterval = 1.5
    private static let smokeLifetime: TimeInterval = 12
    private static let secondaryFlashLifetime: TimeInterval = 1
    private static let secondaryFireLifetime: TimeInterval = 6
    private static let secondarySmokeLifetime: TimeInterval = 18

    /// What the module leaves of its own aircraft's optics and radio. Above the threshold at which
    /// `InterceptRFDamageAdapter` treats a device as absent, so the picture degrades on the way
    /// out instead of disappearing between two frames.
    private static let disruptedOwnOpticsIntegrity: Float = 0.09
    private static let disruptedOwnRadioIntegrity: Float = 0.30
    /// A blade wrapped in netting. Not gone — `VehicleRotorModel` treats zero as a missing prop —
    /// but far below the thrust an airframe needs to stay up.
    private static let fouledPropellerIntegrity: Float = 0.06
    private static let fouledMotorIntegrity: Float = 0.40
    /// What is left of the structure of an aircraft that drove a rigid slug into another one.
    /// Above zero on purpose: this airframe is wrecked and falling, not scattered.
    private static let penetrationCarrierStructure: Float = 0.12
    /// How long the picture is gone outright at the moment of contact, before the link budget is
    /// left to speak for itself. Deliberately longer than the handoff's hold, so the blackout that
    /// starts at activation is the one that carries through to the observer rather than recovering
    /// just short of it.
    private static let contactBlackoutSeconds: TimeInterval = 6

    init(
        configuration: InterceptMissionConfiguration,
        target: InterceptVehicleRuntime,
        observer: InterceptVehicleRuntime,
        origin: SIMD3<Float>,
        deliveryZone: SIMD3<Float>? = nil,
        authorityID: String = "local"
    ) {
        let settings = configuration.validated
        director = InterceptMissionRuntime(configuration: settings, authorityID: authorityID)
        self.target = target
        self.observer = observer
        self.origin = origin
        playerPayload = AttachedPayloadComponent(
            ownerVehicleID: InterceptCallsign.attacker,
            mountPointID: AttachedPayloadComponent.noseMountPointID,
            // A delivery is cargo. It is not armed, and running into the hunter must not "activate"
            // it — that is the other side's mission.
            profile: settings.payloadProfile,
            triggerPolicy: settings.side == .delivery ? .never : .targetContact
        )
        if settings.side == .delivery {
            delivery = InterceptDeliveryRuntime(
                zoneCentre: deliveryZone ?? (origin + settings.deliveryZoneOffset),
                zoneRadius: settings.deliveryZoneRadius,
                massKg: settings.moduleShape.massKg,
                size: settings.moduleShape.sizeMeters
            )
        }
    }

    var actors: [InterceptVehicleRuntime] { [target, observer] }

    func snapshots(player: DroneState) -> [InterceptVehicleSnapshot] {
        [
            InterceptVehicleRuntime.snapshot(
                id: InterceptCallsign.attacker,
                role: .attacker,
                state: player,
                payload: playerPayload
            ),
            target.snapshot,
            observer.snapshot
        ]
    }

    // MARK: - Physics step

    /// Integrates both world actors, then resolves every vehicle-to-vehicle contact for this step.
    /// Returns the player's own impact reports so the caller can run them through the app's normal
    /// damage/audio consequences — this session never reaches into the view model to do that.
    func simulate(
        deltaTime: Float,
        playerPrevious: DroneState,
        player: inout DroneState,
        playerGraph: inout VehicleComponentGraph,
        playerContacts: VehicleContactProfile,
        playerClass: AirframeClass,
        weather: WeatherModel,
        wind: SIMD3<Float>,
        ground: (SIMD3<Float>, Float) -> Float,
        obstacles: (SIMD3<Float>, SIMD3<Float>, Float) -> [CollisionObstacle]
    ) -> [ImpactReport] {
        worldTime += Double(deltaTime)
        stepActors(
            deltaTime: deltaTime,
            attacker: player.position,
            attackerVelocity: player.velocity,
            weather: weather,
            wind: wind,
            ground: ground,
            obstacles: obstacles
        )
        let playerReports = resolvePlayerContacts(
            deltaTime: deltaTime,
            playerPrevious: playerPrevious,
            player: &player,
            playerGraph: &playerGraph,
            playerContacts: playerContacts,
            playerClass: playerClass
        )
        resolveActorPairContact(deltaTime: deltaTime)
        triggerSecondaryIfNeeded()
        stepDelivery(deltaTime: deltaTime, player: player, playerGraph: playerGraph, ground: ground)
        return playerReports
    }

    // MARK: - Delivery

    /// Lets the load go. Returns false when there is nothing to release — no delivery on this side,
    /// or it has already gone.
    @discardableResult
    func releaseDelivery(from player: DroneState) -> Bool {
        guard delivery?.state == .carried else { return false }
        delivery?.release(from: player.position, velocity: player.velocity)
        playerPayload.state = .consumed
        director.record(.payload(InterceptCallsign.attacker, .consumed))
        return true
    }

    /// Carries the load, or flies it once it has been let go.
    ///
    /// An aircraft that comes apart in the air lets go of what it was carrying — so a wreck over
    /// the zone can still deliver, which is exactly the case the mission's own rules single out.
    private func stepDelivery(
        deltaTime: Float,
        player: DroneState,
        playerGraph: VehicleComponentGraph,
        ground: (SIMD3<Float>, Float) -> Float
    ) {
        guard delivery != nil else { return }
        switch delivery?.state {
        case .carried:
            delivery?.carry(on: player.position)
            let mount = playerGraph.component(id: playerPayload.mountPointID)
            let lost = mount != nil && (!mount!.isAttached || mount!.integrity <= 0.001)
            if lost || player.damageCondition == .destroyed || player.physicalState == .crashed {
                delivery?.release(from: player.position, velocity: player.velocity)
                playerPayload.state = .consumed
                director.record(.payload(InterceptCallsign.attacker, .consumed))
            }
        case .falling:
            let position = delivery?.position ?? .zero
            delivery?.step(deltaTime: deltaTime, groundHeight: ground(position, 0.2))
            if let state = delivery?.state, state.isResolved {
                director.record(.payload(InterceptCallsign.attacker, state == .landedInside ? .consumed : .destroyed))
                addArrivalEffects(at: delivery?.position ?? position)
            }
        default:
            break
        }
    }

    /// What arriving looks like. A charge that is put on the ground is still a charge, and a dense
    /// slug arriving at terminal velocity is not a parcel being set down — both go off where they
    /// land, whether or not that was the right place. The two inert loads simply land.
    private func addArrivalEffects(at point: SIMD3<Float>) {
        let profile = director.configuration.moduleShape.effectProfile
        let impactID = UUID()
        switch profile {
        case .structuralDestruction, .kineticPenetration:
            addEffect(at: point, impactID: impactID, kind: .secondary, lifetime: Self.secondaryFlashLifetime)
            addEffect(at: point, impactID: impactID, kind: .smoke, lifetime: Self.secondarySmokeLifetime)
            if profile == .structuralDestruction {
                addEffect(at: point, impactID: impactID, kind: .fire, lifetime: Self.secondaryFireLifetime)
            }
        case .equipmentDisruption, .contactOnly:
            addEffect(at: point, impactID: impactID, kind: .contact, lifetime: Self.contactEffectLifetime)
        }
    }

    private func stepActors(
        deltaTime: Float,
        attacker: SIMD3<Float>,
        attackerVelocity: SIMD3<Float>,
        weather: WeatherModel,
        wind: SIMD3<Float>,
        ground: (SIMD3<Float>, Float) -> Float,
        obstacles: (SIMD3<Float>, SIMD3<Float>, Float) -> [CollisionObstacle]
    ) {
        // What the target can see around itself, in the same query the actors already use for
        // their own collision sweeps. Radius rather than a corridor: the guidance turns, so the
        // corridor it will need in a second is not the one it is flying now.
        let targetLookahead = max(60, simd_length(target.state.velocity) * 4)
        let aimPoint = desiredTargetPosition(
            attacker: attacker,
            attackerVelocity: attackerVelocity,
            deltaTime: deltaTime,
            obstacles: obstacles(
                target.state.position,
                target.state.position,
                targetLookahead
            )
        )
        for actor in actors {
            // The observer holds its station. It was airborne before the run started and its
            // position is never adjusted to produce a better camera angle.
            let desired = actor.role == .observer ? actor.spawnPosition : aimPoint
            let radius = actor.contactProfile.boundingRadius
            let predicted = actor.state.position + actor.state.velocity * deltaTime
            let contacts = actor.step(
                deltaTime: deltaTime,
                desiredPosition: desired,
                weather: weather,
                wind: wind,
                groundHeight: ground(predicted, radius),
                obstacles: obstacles(actor.state.position, predicted, radius + 1)
            )
            for contact in contacts { recordEnvironment(contact, vehicleID: actor.id) }
        }
    }

    private func resolvePlayerContacts(
        deltaTime: Float,
        playerPrevious: DroneState,
        player: inout DroneState,
        playerGraph: inout VehicleComponentGraph,
        playerContacts: VehicleContactProfile,
        playerClass: AirframeClass
    ) -> [ImpactReport] {
        var reports: [ImpactReport] = []
        for actor in actors {
            let key = "\(InterceptCallsign.attacker)/\(actor.id)"
            guard let contact = VehiclePairContactService.firstContact(
                firstPrevious: playerPrevious,
                first: player,
                firstProfile: playerContacts,
                secondPrevious: actor.previousState,
                second: actor.state,
                secondProfile: actor.contactProfile
            ) else {
                touchingPairs.remove(key)
                continue
            }
            let freshContact = touchingPairs.insert(key).inserted
            if actor.role == .target, freshContact {
                // Touching the target is itself proof it was found and closed on, whatever the
                // acquisition range said.
                director.acquireTarget()
                director.beginAttempt(vehicles: snapshots(player: player))
            }
            let resolved = VehiclePairContactService.resolve(
                contact: contact,
                firstPrevious: playerPrevious,
                secondPrevious: actor.previousState,
                first: &player,
                firstGraph: &playerGraph,
                firstClass: playerClass,
                second: &actor.state,
                secondGraph: &actor.graph,
                secondClass: actor.profile.airframeClass,
                deltaTime: deltaTime,
                applyDamage: freshContact
            )
            actor.receive(resolved.second)
            guard freshContact else { continue }
            reports.append(resolved.first)

            var event = makeImpact(
                resolved.first,
                vehicleID: InterceptCallsign.attacker,
                other: actor.id,
                kind: .vehicle,
                secondComponent: contact.secondSphere.componentID
            )
            if actor.role == .target {
                triggerPlayerPayload(on: actor, impact: &event, playerGraph: &playerGraph)
            }
            pendingImpacts.append(event)
            // Whether the module went off is written on the impact, not read back off the module.
            // `trigger` advances the state to `contactTriggered` and `consume` immediately moves it
            // on to `consumed`, so a test for `contactTriggered` here was never true and the whole
            // activation effect was unreachable — the operator rammed a target and saw a puff.
            addActivationEffects(impact: event, target: actor.id)
        }
        return reports
    }

    /// What a contact looks like. An activation is the loudest moment of the run and it happens to
    /// both aircraft at once: the module is bolted to the operator's own airframe, so the effect
    /// belongs at the point where the two met, on both of them.
    private func addActivationEffects(impact: InterceptImpactEvent, target: String) {
        guard impact.payloadIDs.contains(playerPayload.id) else {
            addEffect(impact: impact, vehicleID: target, kind: .contact, lifetime: Self.contactEffectLifetime)
            return
        }
        let vehicles = [InterceptCallsign.attacker, target]
        switch playerPayload.effectProfileID {
        case .structuralDestruction:
            for vehicleID in vehicles {
                addEffect(impact: impact, vehicleID: vehicleID, kind: .secondary, lifetime: Self.secondaryFlashLifetime)
                addEffect(impact: impact, vehicleID: vehicleID, kind: .fire, lifetime: Self.secondaryFireLifetime)
                addEffect(impact: impact, vehicleID: vehicleID, kind: .smoke, lifetime: Self.secondarySmokeLifetime)
            }
        case .kineticPenetration:
            // All of the closing energy through one point of structure: the flash and the debris
            // of a hard strike, and no sustained flame, because there is nothing in a slug to burn.
            for vehicleID in vehicles {
                addEffect(impact: impact, vehicleID: vehicleID, kind: .secondary, lifetime: Self.secondaryFlashLifetime)
                addEffect(impact: impact, vehicleID: vehicleID, kind: .smoke, lifetime: Self.secondarySmokeLifetime)
            }
        case .equipmentDisruption:
            // No fireball — a net is not a charge — but two aircraft shedding rotors is not a
            // silent event either, and both of them trail smoke on the way down.
            for vehicleID in vehicles {
                addEffect(impact: impact, vehicleID: vehicleID, kind: .contact, lifetime: Self.contactEffectLifetime)
                addEffect(impact: impact, vehicleID: vehicleID, kind: .smoke, lifetime: Self.secondarySmokeLifetime)
            }
        case .contactOnly:
            addEffect(impact: impact, vehicleID: target, kind: .contact, lifetime: Self.contactEffectLifetime)
        }
    }

    /// A resolved, non-trivial target contact is the only thing that spends the module. A grazing
    /// touch leaves it available for the next approach, and a miss never reaches this path at all.
    private func triggerPlayerPayload(
        on actor: InterceptVehicleRuntime,
        impact: inout InterceptImpactEvent,
        playerGraph: inout VehicleComponentGraph
    ) {
        guard impact.impactClass != .touch,
              playerPayload.trigger(impactID: impact.id, policy: .targetContact) else { return }
        impact.payloadIDs.append(playerPayload.id)
        applyEquipmentEffect(profile: playerPayload.effectProfileID, graph: &actor.graph)
        // Whatever the module does to the target at contact range, it does to the aircraft carrying
        // it. There is no standing off from something bolted to your own airframe.
        applyCarrierEffect(profile: playerPayload.effectProfileID, graph: &playerGraph)
        // The module goes off against the airframe the camera is bolted to. The operator loses the
        // picture at the instant of contact — that is the event the whole observation handoff
        // exists for — and the link budget then decides whether it ever comes back.
        //
        // Only when something actually goes off, though. Inert practice mass does nothing to the
        // aircraft carrying it, so blacking the picture out at the moment of contact took away the
        // one thing the operator had come to see and left the run looking as if nothing happened.
        if !playerPayload.effectProfileID.sparesCarrier {
            observation.disrupt(vehicleID: InterceptCallsign.attacker, until: worldTime + Self.contactBlackoutSeconds)
        }
        playerPayload.consume()
        director.record(.payload(InterceptCallsign.attacker, playerPayload.state))
        actor.refreshDamage()
    }

    /// Target and observer can also run into each other. Neither is treated as scenery.
    private func resolveActorPairContact(deltaTime: Float) {
        let key = "\(target.id)/\(observer.id)"
        guard let contact = VehiclePairContactService.firstContact(
            firstPrevious: target.previousState,
            first: target.state,
            firstProfile: target.contactProfile,
            secondPrevious: observer.previousState,
            second: observer.state,
            secondProfile: observer.contactProfile
        ) else {
            touchingPairs.remove(key)
            return
        }
        let fresh = touchingPairs.insert(key).inserted
        let resolved = VehiclePairContactService.resolve(
            contact: contact,
            firstPrevious: target.previousState,
            secondPrevious: observer.previousState,
            first: &target.state,
            firstGraph: &target.graph,
            firstClass: target.profile.airframeClass,
            second: &observer.state,
            secondGraph: &observer.graph,
            secondClass: observer.profile.airframeClass,
            deltaTime: deltaTime,
            applyDamage: fresh
        )
        target.receive(resolved.first)
        observer.receive(resolved.second)
        guard fresh else { return }
        let impact = makeImpact(
            resolved.first,
            vehicleID: target.id,
            other: observer.id,
            kind: .vehicle,
            secondComponent: contact.secondSphere.componentID
        )
        pendingImpacts.append(impact)
        addEffect(impact: impact, vehicleID: target.id, kind: .contact, lifetime: Self.contactEffectLifetime)
    }

    /// Normalises a terrain or environment contact into a mission impact. Called for the actors
    /// from `stepActors`, and by the view model for the player's own impacts, which the app's
    /// collision pipeline resolves rather than this session.
    func recordEnvironment(_ report: ImpactReport, vehicleID: String = InterceptCallsign.attacker) {
        guard report.tier != .lightTouch else { return }
        let key = "\(vehicleID)/\(report.obstacleID)"
        guard director.elapsed - (lastEnvironmentImpact[key] ?? -.infinity) > Self.environmentImpactCooldown else { return }
        lastEnvironmentImpact[key] = director.elapsed

        let source = report.obstacleSource ?? ""
        let isTerrain = source.contains("ground") || source.contains("terrain")
        let impact = makeImpact(
            report,
            vehicleID: vehicleID,
            other: report.obstacleID.uuidString,
            kind: isTerrain ? .terrain : .environment
        )
        pendingImpacts.append(impact)
        addEffect(impact: impact, vehicleID: vehicleID, kind: .contact, lifetime: Self.contactEffectLifetime)
        if report.tier == .criticalImpact {
            addEffect(impact: impact, vehicleID: vehicleID, kind: .smoke, lifetime: Self.smokeLifetime)
        }
    }

    // MARK: - Scenario step

    /// Hands one step's worth of resolved world state to the scenario rules. Separate from
    /// `simulate` on purpose: everything physical has already happened by the time the mission is
    /// allowed to have an opinion about it.
    func assess(deltaTime: Float, player: DroneState, graph: VehicleComponentGraph, targetVisible: Bool) {
        if let mount = graph.component(id: playerPayload.mountPointID) {
            playerPayload.updateMount(integrity: mount.integrity, attached: mount.isAttached)
        }
        director.worldReady()

        let distance = simd_distance(player.position, target.state.position)
        if targetVisible, distance <= director.configuration.acquisitionRange {
            director.acquireTarget()
        }
        let vehicles = snapshots(player: player)
        // Being this close, armed, is an approach whether or not the operator pressed the button.
        // The button exists so an approach can also be declared (and aborted) deliberately.
        if director.configuration.side == .interceptor,
           player.armState == .armed,
           distance <= director.configuration.attemptRange {
            director.beginAttempt(vehicles: vehicles)
        }

        let escapeDistance = simd_length(SIMD2<Float>(
            target.state.position.x - origin.x,
            target.state.position.z - origin.z
        ))
        director.step(
            deltaTime: Double(deltaTime),
            vehicles: vehicles,
            impacts: pendingImpacts,
            observerCanConfirm: observation.observerCanConfirm,
            // A hunter leaving the area is not an escape — it is the mission going away, and on
            // that side nothing is trying to keep it in.
            targetEscaped: director.configuration.side == .interceptor
                && escapeDistance > director.configuration.areaRadius,
            delivery: delivery?.state ?? .carried
        )
        pendingImpacts.removeAll(keepingCapacity: true)

        for event in observation.step(now: worldTime, noSignalHold: director.configuration.noSignalHold) {
            director.record(event)
        }
        effects.step(now: worldTime)
    }

    func drainEvents() -> [InterceptMissionEvent] {
        let events = director.drainEvents()
        eventHistory.append(contentsOf: events)
        return events
    }

    // MARK: - Target behaviour

    /// Hands the guidance everything it is allowed to see and gets back the point the target is
    /// flying towards. The behaviour itself lives in `InterceptTargetGuidance` so it can be
    /// measured without a scene, a component graph or a session.
    private func desiredTargetPosition(
        attacker: SIMD3<Float>,
        attackerVelocity: SIMD3<Float>,
        deltaTime: Float,
        obstacles: [CollisionObstacle]
    ) -> SIMD3<Float> {
        targetGuidance.aimPoint(InterceptTargetGuidance.Situation(
            behavior: director.configuration.targetBehavior,
            agility: director.configuration.targetAgility,
            position: target.state.position,
            velocity: target.state.velocity,
            spawnPosition: target.spawnPosition,
            attacker: attacker,
            attackerVelocity: attackerVelocity,
            cruiseSpeed: target.profile.maxHorizontalSpeedMps * target.cruiseSpeedScale,
            origin: origin,
            areaRadius: director.configuration.areaRadius,
            isFixedWing: target.isFixedWing,
            isDamaged: target.snapshot.functionalState != .nominal,
            obstacles: obstacles,
            deltaTime: deltaTime
        ))
    }

    // MARK: - Payload effects

    /// The target's own module, if it has one and the policy allows it. Once, ever — a module that
    /// has already gone, or that was inert to begin with, produces nothing on the way down.
    private func triggerSecondaryIfNeeded() {
        guard !target.snapshot.functionalState.canAttempt,
              target.payload?.canProduceSecondaryEffect == true,
              let cause = pendingImpacts.last(where: {
                  $0.firstVehicleID == target.id || $0.secondEntityID == target.id
              }),
              target.payload?.trigger(impactID: cause.id, policy: .ownerCritical) == true else { return }

        if let profile = target.payload?.effectProfileID {
            applyEquipmentEffect(profile: profile, graph: &target.graph)
        }
        target.payload?.consume()
        director.record(.payload(target.id, target.payload?.state ?? .consumed))
        addEffect(impact: cause, vehicleID: target.id, kind: .secondary, lifetime: Self.secondaryFlashLifetime)
        addEffect(impact: cause, vehicleID: target.id, kind: .fire, lifetime: Self.secondaryFireLifetime)
        addEffect(impact: cause, vehicleID: target.id, kind: .smoke, lifetime: Self.secondarySmokeLifetime)
        target.refreshDamage()
    }

    /// A configured game rule on named components, not a blast solver and not a uniform health bar.
    /// This is what the module does to the aircraft it touched.
    private func applyEquipmentEffect(profile: AttachedPayloadProfile, graph: inout VehicleComponentGraph) {
        switch profile {
        case .contactOnly:
            return
        case .equipmentDisruption:
            // A net does what a net does: it goes into the disc. The airframe is untouched and the
            // aircraft is not blown up — it simply stops being able to hold itself up. Blinding it
            // instead, which is what this used to do, left a fully powered aircraft flying on and
            // the operator watching a target that did not care it had been hit.
            foulRotors(in: &graph)
            for component in graph.components where component.isAttached {
                switch component.kind {
                case .cameraGimbal, .radio:
                    graph.setIntegrity(min(component.integrity, 0.04), id: component.id)
                default:
                    break
                }
            }
        case .kineticPenetration, .structuralDestruction:
            // A dense slug arriving at interception speed does not dent an airframe of this size;
            // it goes through it. The target comes apart either way — what differs is what is left
            // of the aircraft that delivered it (see `applyCarrierEffect`).
            applyStructuralDestruction(to: &graph, detaching: true)
        }
    }

    /// What the module leaves of the aircraft that was carrying it.
    private func applyCarrierEffect(profile: AttachedPayloadProfile, graph: inout VehicleComponentGraph) {
        switch profile {
        case .contactOnly:
            // Inert mass. The contact itself is the only thing that happened, and the impact
            // solver has already had its say about that.
            return
        case .equipmentDisruption:
            // The net deploys off a mount under the operator's own aircraft, at contact range,
            // into its own disc first. The carrier goes down under the same fouled rotors as the
            // target — not blown apart, just no longer flying.
            foulRotors(in: &graph)
            // Wounded rather than switched off: a camera taken straight to zero leaves the RF
            // stack with no video device at all, and the link budget has nothing left to degrade.
            for component in graph.components {
                switch component.kind {
                case .cameraGimbal:
                    graph.setIntegrity(min(component.integrity, Self.disruptedOwnOpticsIntegrity), id: component.id)
                case .radio:
                    graph.setIntegrity(min(component.integrity, Self.disruptedOwnRadioIntegrity), id: component.id)
                default:
                    break
                }
            }
        case .kineticPenetration:
            // The slug is rigid and it is bolted to the nose. Everything it does to the target it
            // does back through the mount into this airframe: the rotors go, the structure is left
            // barely holding together, and the aircraft comes down. It is not scattered, which is
            // the one thing separating it from a charge.
            foulRotors(in: &graph)
            for component in graph.components where component.isAttached {
                switch component.kind {
                case .frame, .fuselage:
                    graph.setIntegrity(min(component.integrity, Self.penetrationCarrierStructure), id: component.id)
                case .cameraGimbal:
                    graph.setIntegrity(min(component.integrity, Self.disruptedOwnOpticsIntegrity), id: component.id)
                case .radio:
                    graph.setIntegrity(min(component.integrity, Self.disruptedOwnRadioIntegrity), id: component.id)
                default:
                    break
                }
            }
        case .structuralDestruction:
            // Both aircraft come apart. This is the whole point of the charge, and it is the one
            // module for which "I rammed it and flew home" is not an outcome.
            applyStructuralDestruction(to: &graph, detaching: false)
        }
    }

    /// Takes the lift out of a rotorcraft without taking it apart. The propellers keep a trace of
    /// their integrity so they are fouled rather than absent — an integrity of exactly zero would
    /// read to the rest of the model as a missing blade.
    private func foulRotors(in graph: inout VehicleComponentGraph) {
        for component in graph.components where component.isAttached {
            switch component.kind {
            case .propeller:
                graph.setIntegrity(min(component.integrity, Self.fouledPropellerIntegrity), id: component.id)
            case .motor:
                graph.setIntegrity(min(component.integrity, Self.fouledMotorIntegrity), id: component.id)
            default:
                break
            }
        }
    }

    /// Takes an airframe apart: every component to zero integrity *and* every joint to zero
    /// strength. The condition ladder reads the result as `destroyed`, so nothing downstream has to
    /// be told separately that this aircraft is finished.
    ///
    /// Both halves are needed. Integrity and joint strength are independent, and zeroing only the
    /// first left `failedConnectionRootIDs` empty — the target was reported destroyed and stayed on
    /// screen in one piece, because nothing had actually come off it.
    ///
    /// `detaching` says who performs the separation. The mission's own actors are detached here and
    /// the scene sheds anything no longer attached. The operator's aircraft is left with failed
    /// joints instead, because the app's impact pipeline detaches those itself a moment later and
    /// spawns real physics debris for them — doing it here would empty the list it reads.
    private func applyStructuralDestruction(to graph: inout VehicleComponentGraph, detaching: Bool) {
        for component in graph.components where component.isAttached {
            graph.setIntegrity(0, id: component.id)
        }
        graph.failAllConnections()
        guard detaching else { return }
        for root in graph.failedConnectionRootIDs { _ = graph.detachSubtree(rootComponentID: root) }
    }

    // MARK: - Event construction

    private func makeImpact(
        _ report: ImpactReport,
        vehicleID: String,
        other: String,
        kind: InterceptContactKind,
        secondComponent: String? = nil
    ) -> InterceptImpactEvent {
        InterceptImpactEvent(
            id: UUID(),
            runID: director.runID,
            timestamp: director.elapsed,
            authorityID: director.authorityID,
            firstVehicleID: vehicleID,
            secondEntityID: other,
            kind: kind,
            position: report.contactPoint,
            normal: report.contactNormal,
            firstComponentID: report.componentID,
            secondComponentID: secondComponent,
            impactClass: InterceptImpactClass(report.tier),
            surface: report.acousticSurface.rawValue
        )
    }

    /// An effect at a place rather than at a contact — where the delivery came down, which no
    /// impact report describes because nothing collided with anything the mission resolves.
    private func addEffect(
        at point: SIMD3<Float>,
        impactID: UUID,
        kind: InterceptEffectKind,
        lifetime: TimeInterval
    ) {
        let effect = InterceptWorldEffect(
            id: UUID(),
            runID: director.runID,
            impactID: impactID,
            vehicleID: InterceptCallsign.attacker,
            kind: kind,
            position: point,
            normal: SIMD3<Float>(0, 1, 0),
            startedAt: worldTime,
            lifetime: lifetime
        )
        if effects.add(effect, runID: director.runID) { director.record(.effect(effect)) }
    }

    private func addEffect(
        impact: InterceptImpactEvent,
        vehicleID: String,
        kind: InterceptEffectKind,
        lifetime: TimeInterval
    ) {
        let effect = InterceptWorldEffect(
            id: UUID(),
            runID: director.runID,
            impactID: impact.id,
            vehicleID: vehicleID,
            kind: kind,
            position: impact.position,
            normal: impact.normal,
            startedAt: worldTime,
            lifetime: lifetime
        )
        if effects.add(effect, runID: director.runID) { director.record(.effect(effect)) }
    }
}

// MARK: - Delivery

/// The operator's load on the delivery side of the mission: carried, then dropped, then somewhere.
///
/// A real object rather than a scored event. It leaves the aircraft with the aircraft's velocity
/// and falls under gravity and its own drag, which is what makes the run a piece of flying — the
/// operator has to be over the zone, at a sensible height and speed, when they let go. A release
/// from 200 m at cruise lands a long way downrange, and that is the point.
///
/// Pure value logic, no scene and no session, so the ballistics can be measured headlessly.
struct InterceptDeliveryRuntime {
    private(set) var state: InterceptDeliveryState = .carried
    private(set) var position: SIMD3<Float> = .zero
    private(set) var velocity: SIMD3<Float> = .zero
    /// Where it came to rest, once it has. Nil while it is still in the air.
    private(set) var restingPlace: SIMD3<Float>?
    let zoneCentre: SIMD3<Float>
    let zoneRadius: Float
    let massKg: Float
    /// Frontal area times drag coefficient, square metres.
    let dragArea: Float

    static let gravity: Float = 9.81
    static let airDensity: Float = 1.225
    /// A taped box is not a streamlined body.
    static let dragCoefficient: Float = 1.05

    init(zoneCentre: SIMD3<Float>, zoneRadius: Float, massKg: Float, size: SIMD3<Float>) {
        self.zoneCentre = zoneCentre
        self.zoneRadius = max(1, zoneRadius)
        self.massKg = max(0.05, massKg)
        dragArea = max(0.002, abs(size.x) * abs(size.y)) * Self.dragCoefficient
    }

    /// Follows the aircraft while it is still aboard, so the HUD and the scene have somewhere to
    /// draw it and the drop starts from where the load actually is.
    mutating func carry(on carrier: SIMD3<Float>) {
        guard state == .carried else { return }
        position = carrier
    }

    mutating func release(from position: SIMD3<Float>, velocity: SIMD3<Float>) {
        guard state == .carried else { return }
        self.position = position
        self.velocity = velocity
        state = .falling
    }

    /// Marks the load as never having arrived. Used when it is taken apart rather than dropped.
    mutating func destroy() {
        guard !state.isResolved else { return }
        state = .destroyed
    }

    mutating func step(deltaTime: Float, groundHeight: Float) {
        guard state == .falling, deltaTime > 0, deltaTime.isFinite else { return }
        let speed = simd_length(velocity)
        // Quadratic drag, integrated with the same forward step the rest of the mission uses. It
        // is what stops a heavy load from arriving at an absurd speed and what makes a light one
        // drift — the difference between the four modules on this side of the mission.
        var acceleration = SIMD3<Float>(0, -Self.gravity, 0)
        if speed > 0.001 {
            let drag = 0.5 * Self.airDensity * dragArea * speed * speed / massKg
            acceleration -= velocity / speed * drag
        }
        velocity += acceleration * deltaTime
        position += velocity * deltaTime
        guard position.y <= groundHeight else { return }
        position.y = groundHeight
        restingPlace = position
        state = planarRange(from: position) <= zoneRadius ? .landedInside : .landedOutside
    }

    /// Horizontal distance from a point to the centre of the zone. Horizontal on purpose: the zone
    /// is a place on the ground, and an aircraft 120 m above its middle is over it.
    func planarRange(from point: SIMD3<Float>) -> Float {
        simd_length(SIMD2<Float>(point.x - zoneCentre.x, point.z - zoneCentre.z))
    }

    func isOverZone(_ point: SIMD3<Float>) -> Bool { planarRange(from: point) <= zoneRadius }
}
