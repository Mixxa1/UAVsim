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
    /// How long the picture is gone outright at the moment of contact, before the link budget is
    /// left to speak for itself.
    private static let contactBlackoutSeconds: TimeInterval = 3.5

    init(
        configuration: InterceptMissionConfiguration,
        target: InterceptVehicleRuntime,
        observer: InterceptVehicleRuntime,
        origin: SIMD3<Float>,
        authorityID: String = "local"
    ) {
        director = InterceptMissionRuntime(configuration: configuration, authorityID: authorityID)
        self.target = target
        self.observer = observer
        self.origin = origin
        playerPayload = AttachedPayloadComponent(
            ownerVehicleID: InterceptCallsign.attacker,
            profile: configuration.payloadProfile
        )
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
        return playerReports
    }

    private func stepActors(
        deltaTime: Float,
        attacker: SIMD3<Float>,
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
            addEffect(impact: event, vehicleID: actor.id, kind: .contact, lifetime: Self.contactEffectLifetime)
        }
        return reports
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
        // The carried module's own electronics sit in its owner's graph too: whatever it does to
        // the target at contact range, it does to the optics and the radio riding next to it.
        //
        // Deliberately wounded rather than switched off. A camera taken straight to zero leaves
        // the RF stack with no video device at all, and the operator gets an instant cut to NO
        // SIGNAL — which is the one thing the stage plan rules out. Left barely alive, the link
        // budget carries it down through RSSI LOW and a frozen frame first, which is what the
        // handoff is supposed to follow.
        if playerPayload.effectProfileID == .equipmentDisruption {
            for component in playerGraph.components {
                switch component.kind {
                case .cameraGimbal:
                    playerGraph.setIntegrity(min(component.integrity, Self.disruptedOwnOpticsIntegrity), id: component.id)
                case .radio:
                    playerGraph.setIntegrity(min(component.integrity, Self.disruptedOwnRadioIntegrity), id: component.id)
                default:
                    break
                }
            }
        }
        // The module goes off against the airframe the camera is bolted to. The operator loses the
        // picture at the instant of contact — that is the event the whole observation handoff
        // exists for — and the link budget then decides whether it ever comes back.
        observation.disrupt(vehicleID: InterceptCallsign.attacker, until: worldTime + Self.contactBlackoutSeconds)
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
        if player.armState == .armed, distance <= director.configuration.attemptRange {
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
            targetEscaped: escapeDistance > director.configuration.areaRadius
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

    /// A configured game rule on named components, not a blast solver and not a uniform health
    /// bar: the module takes out optics and radio, and leaves the aircraft on a crippled battery.
    private func applyEquipmentEffect(profile: AttachedPayloadProfile, graph: inout VehicleComponentGraph) {
        guard profile == .equipmentDisruption else { return }
        for component in graph.components where component.isAttached {
            switch component.kind {
            case .cameraGimbal, .radio:
                graph.setIntegrity(min(component.integrity, 0.04), id: component.id)
            case .battery:
                graph.setIntegrity(min(component.integrity, 0.35), id: component.id)
            default:
                break
            }
        }
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
