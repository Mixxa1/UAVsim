import Foundation
import simd

/// Air a projectile falls through: density from altitude, plus the wind it is carried by.
struct BallisticEnvironment {
    var atmosphere: AtmosphereModel
    /// Steady wind vector in world axes, m/s. The projectile feels airspeed relative to this, which
    /// is why a released object drifts downwind instead of falling along the ground track.
    var windVector: SIMD3<Float>

    static let standardStill = BallisticEnvironment(
        atmosphere: .standard,
        windVector: .zero
    )

    func airDensity(worldY: Float) -> Float {
        atmosphere.state(worldY: worldY).airDensity
    }
}

/// One object in the air after release.
struct BallisticProjectile: Identifiable {
    let id: UUID
    /// Current aerodynamic properties. Not a constant: a canopy inflating replaces the object with
    /// a much draggier one partway down.
    private(set) var descriptor: BallisticDescriptor
    /// The properties it was released with, kept for reporting.
    let releaseDescriptor: BallisticDescriptor
    /// What was released, for the caller to route the impact back to the right subsystem.
    let kind: Kind
    /// Whose drop this is.
    let ownership: Ownership
    private(set) var position: SIMD3<Float>
    private(set) var velocity: SIMD3<Float>
    private(set) var elapsedSeconds: Float
    /// Visual attitude. Integrated kinematically and never fed back into the trajectory — the drag
    /// model is orientation-independent, so this is presentation, not physics.
    private(set) var orientation: simd_quatf
    private(set) var angularVelocity: SIMD3<Float>
    private(set) var isParachuteDeployed: Bool
    /// Bounces already taken, so a projectile cannot skitter forever.
    private(set) var bounceCount: Int
    /// Last surface height actually returned for this projectile's column, so a `nil` answer over a
    /// streamed-out chunk falls back to the last thing the world was known to have, never to zero.
    fileprivate var lastKnownSurfaceY: Float
    fileprivate var surfaceQueryPlanarPosition: SIMD2<Float>
    fileprivate var secondsSinceSurfaceQuery: Float

    enum Kind: Equatable {
        /// A fire capsule from the launcher rack, carrying the size it was rigged at.
        case fireCapsule(FireCapsuleSize)
        /// A payload released whole from the mount.
        case releasedPayload(PayloadType)
        /// A fragment shed by an airframe — a component knocked off in a collision.
        ///
        /// On the same runtime as the drops for the same reason they were put there: the intercept
        /// scene was flying its wreckage on its own `origin + v·t + ½g·t²`, with no air resistance,
        /// no wind, and no ground to land on — pieces simply faded out after eight seconds
        /// wherever they had got to.
        case debris
    }

    /// Who owns the consequences of this drop.
    ///
    /// A replicated drop is integrated and drawn on every participant's machine, but only the
    /// releasing side may act on the impact. Without this a capsule dropped in a LAN trial would
    /// extinguish the same fire once per connected player, and each of them would record a
    /// mission event for a drop they did not make.
    enum Ownership: Equatable {
        case local
        case remote
    }

    var speed: Float {
        simd_length(velocity)
    }

    fileprivate init(
        id: UUID,
        descriptor: BallisticDescriptor,
        kind: Kind,
        ownership: Ownership,
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        spinAxis: SIMD3<Float>,
        initialSurfaceY: Float
    ) {
        self.id = id
        self.descriptor = descriptor
        self.releaseDescriptor = descriptor
        self.kind = kind
        self.ownership = ownership
        self.position = position
        self.velocity = velocity
        self.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        self.angularVelocity = spinAxis * (descriptor.tumbleRatePerAirspeed * simd_length(velocity))
        self.isParachuteDeployed = false
        self.bounceCount = 0
        self.elapsedSeconds = 0.0
        self.lastKnownSurfaceY = initialSurfaceY
        self.surfaceQueryPlanarPosition = SIMD2<Float>(position.x, position.z)
        self.secondsSinceSurfaceQuery = .greatestFiniteMagnitude
    }

    fileprivate mutating func apply(position: SIMD3<Float>, velocity: SIMD3<Float>, stepSeconds: Float) {
        self.position = position
        self.velocity = velocity
        self.elapsedSeconds += stepSeconds
        self.secondsSinceSurfaceQuery += stepSeconds
        integrateAttitude(stepSeconds: stepSeconds)
    }

    /// Kinematic attitude integration: q' = q + ½·ω⊗q·dt, renormalised.
    private mutating func integrateAttitude(stepSeconds: Float) {
        guard simd_length_squared(angularVelocity) > 1e-8 else {
            return
        }
        let omega = simd_quatf(real: 0, imag: angularVelocity)
        let derivative = omega * orientation
        let updated = simd_quatf(vector: orientation.vector + derivative.vector * (0.5 * stepSeconds))
        orientation = simd_normalize(updated)
    }

    /// Inflates the canopy, replacing the object's aerodynamics and killing its tumble.
    fileprivate mutating func deployParachute() {
        descriptor = descriptor.deployed()
        isParachuteDeployed = true
        angularVelocity = .zero
    }

    /// Reflects off a surface, keeping the tangential component and a fraction of the normal one.
    fileprivate mutating func bounce(at point: SIMD3<Float>, normal: SIMD3<Float>) {
        let normalSpeed = simd_dot(velocity, normal)
        let tangential = velocity - normal * normalSpeed
        // Tangential friction: a bouncing object scrubs speed along the surface, it does not skate.
        velocity = tangential * 0.7 - normal * (normalSpeed * descriptor.restitution)
        position = point + normal * 0.02
        bounceCount += 1
        // A bounce spins it up rather than settling it down.
        angularVelocity = angularVelocity * 0.6
            + simd_cross(normal, tangential) * (descriptor.tumbleRatePerAirspeed * 0.5)
    }
}

/// How a projectile's flight ended.
struct BallisticImpact {
    let projectileID: UUID
    let kind: BallisticProjectile.Kind
    let ownership: BallisticProjectile.Ownership
    let descriptor: BallisticDescriptor
    let position: SIMD3<Float>
    /// Full impact velocity vector — the horizontal part is not incidental, a capsule released from
    /// a moving aircraft arrives travelling forwards.
    let velocity: SIMD3<Float>
    let normal: SIMD3<Float>
    let isWater: Bool
    let flightTimeSeconds: Float
    /// Bounces this projectile took before coming to rest.
    let bounceCount: Int

    var speedMps: Float {
        simd_length(velocity)
    }

    /// Momentum carried into the surface, kg·m/s.
    ///
    /// The impact services were being handed a bare speed, which cannot distinguish a 1.5 kg
    /// capsule from a 3 kg cargo box arriving equally fast.
    var momentumKgMps: Float {
        descriptor.massKg * speedMps
    }
}

/// A projectile striking a surface and carrying on.
///
/// Reported separately from `BallisticImpact` because it is not the end of anything: the object is
/// still in play. It is surfaced at all because a bounce is observable — it has a sound, it can
/// scuff a surface, and without it the only evidence a crate skipped is that it ended up somewhere
/// unexpected at an implausibly low speed.
struct BallisticBounce {
    let projectileID: UUID
    let kind: BallisticProjectile.Kind
    let ownership: BallisticProjectile.Ownership
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    /// Speed into the surface along its normal, before the bounce.
    let normalSpeedMps: Float
    /// Which bounce this is, starting at 1.
    let index: Int
}

/// Everything that happened to in-flight projectiles during one tick.
struct BallisticTickResult {
    /// Projectiles that hit something.
    let impacts: [BallisticImpact]
    /// Surfaces struck by projectiles that kept going.
    let bounces: [BallisticBounce]
    /// Projectiles given up on without an impact — they left the world, fell through a hole in it,
    /// or ran past the flight-time limit.
    ///
    /// Reported rather than silently dropped: the scene is holding a node for each one, and a
    /// projectile that disappears from the runtime without telling anyone leaks that node into the
    /// world for the rest of the session.
    let abandoned: [(id: UUID, kind: BallisticProjectile.Kind, ownership: BallisticProjectile.Ownership)]

    var isEmpty: Bool {
        impacts.isEmpty && bounces.isEmpty && abandoned.isEmpty
    }
}

/// A predicted impact point, for aiming.
struct BallisticPrediction {
    let position: SIMD3<Float>
    let velocity: SIMD3<Float>
    let flightTimeSeconds: Float
    /// True when the trajectory ran out of time or left the world instead of hitting something, so
    /// the caller can show the reticle as unreliable rather than pretending to know.
    let isExtrapolated: Bool
}

/// Integrates released objects through air until they hit something.
///
/// Replaces two hand-written copies of `s = ½gt²` driven by `SCNAction`, which froze the release
/// point's x and z for the whole fall. Three consequences of that shortcut are gone here: the
/// carrier's velocity is inherited, wind acts on the object, and the impact is resolved against
/// whatever the world actually has underneath instead of a flat plane at y ≈ 0.
///
/// The runtime is driven from the simulation tick rather than from a scene action. That is not
/// only a physics improvement: the old `SCNAction.run` impact closure ran on an arbitrary thread
/// and had to hop to the main actor by hand, after a real deadlock had already been shipped and
/// commented about at the call site.
final class BallisticProjectileRuntime {
    /// Fixed integration step. Independent of frame rate so a drop is reproducible for replay and
    /// unaffected by the renderer stalling.
    static let stepSeconds: Float = 1.0 / 120.0
    /// A projectile still airborne after this long is abandoned — it left the world, or the surface
    /// query never answered.
    static let maximumFlightSeconds: Float = 60.0
    /// How far below the last known surface a projectile may travel before it is written off as
    /// having fallen through a hole in the world.
    private static let lostBelowSurfaceMeters: Float = 500.0
    /// Column queries are cached while the projectile is still high; within this distance of the
    /// last known surface every step queries afresh.
    private static let closeApproachMeters: Float = 12.0
    /// Cache invalidation for the column query while still high up.
    private static let surfaceQueryPlanarToleranceMeters: Float = 3.0
    private static let surfaceQueryIntervalSeconds: Float = 0.2
    /// Bounce budget. A crate can skip once or twice; it cannot tumble across the map.
    private static let maximumBounces: Int = 3
    /// Reflected normal speed below this settles instead of bouncing, m/s.
    private static let minimumBounceSpeed: Float = 1.2

    private(set) var projectiles: [BallisticProjectile] = []
    private var accumulatedSeconds: Float = 0.0

    var isEmpty: Bool { projectiles.isEmpty }

    // MARK: - Launch

    /// Registers a released object.
    ///
    /// `carrierVelocity` is the whole point of this signature: the old drop path had no parameter
    /// for it and so implicitly assumed zero. At 15 m/s and 40 m altitude that assumption moves the
    /// impact point by about 40 metres.
    /// `id` is caller-supplied when the drop already has an identity elsewhere — a released payload
    /// is tracked by the scene's release id, and giving the projectile a second one would mean two
    /// keys for one falling object.
    @discardableResult
    func launch(
        id: UUID = UUID(),
        kind: BallisticProjectile.Kind,
        descriptor: BallisticDescriptor,
        ownership: BallisticProjectile.Ownership = .local,
        position: SIMD3<Float>,
        carrierVelocity: SIMD3<Float>,
        separationImpulse: SIMD3<Float> = .zero,
        surfaceProbe: BallisticSurfaceProbe
    ) -> UUID {
        let initialSurface = surfaceProbe.ballisticSurfaceHeight(
            x: position.x,
            z: position.z,
            maximumHeight: position.y
        ) ?? 0.0
        projectiles.append(
            BallisticProjectile(
                id: id,
                descriptor: descriptor,
                kind: kind,
                ownership: ownership,
                position: position,
                velocity: carrierVelocity + separationImpulse,
                // Derived from the id rather than randomised, so a replicated drop tumbles the same
                // way on every machine and a replay reproduces the one that was recorded.
                spinAxis: Self.spinAxis(for: id),
                initialSurfaceY: initialSurface
            )
        )
        return id
    }

    /// A stable unit vector derived from the projectile's identity.
    ///
    /// Tumble has to look arbitrary without *being* arbitrary: a random axis would make the same
    /// drop spin differently on each participant's screen in a LAN trial, and differently again on
    /// every replay of the same recording.
    private static func spinAxis(for id: UUID) -> SIMD3<Float> {
        var hasher = Hasher()
        hasher.combine(id)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        let a = Float(value & 0xFFFF) / Float(0xFFFF)
        let b = Float((value >> 16) & 0xFFFF) / Float(0xFFFF)
        let theta = a * 2.0 * .pi
        let z = b * 2.0 - 1.0
        let r = (1.0 - z * z).squareRoot()
        return SIMD3<Float>(r * cos(theta), z, r * sin(theta))
    }

    func projectile(id: UUID) -> BallisticProjectile? {
        projectiles.first { $0.id == id }
    }

    func removeAll() {
        projectiles.removeAll(keepingCapacity: true)
        accumulatedSeconds = 0.0
    }

    // MARK: - Tick

    /// Advances every projectile and returns the ones that ended this tick.
    func update(
        deltaTime: Float,
        environment: BallisticEnvironment,
        surfaceProbe: BallisticSurfaceProbe
    ) -> BallisticTickResult {
        guard !projectiles.isEmpty, deltaTime > 0, deltaTime.isFinite else {
            return BallisticTickResult(impacts: [], bounces: [], abandoned: [])
        }

        // Clamp the catch-up so a stalled frame cannot spend a second of simulation in one tick.
        accumulatedSeconds = min(accumulatedSeconds + deltaTime, 0.5)
        let step = Self.stepSeconds
        var impacts: [BallisticImpact] = []
        var bounces: [BallisticBounce] = []
        var abandoned: [(id: UUID, kind: BallisticProjectile.Kind, ownership: BallisticProjectile.Ownership)] = []

        while accumulatedSeconds >= step {
            accumulatedSeconds -= step
            guard !projectiles.isEmpty else { break }

            var survivors: [BallisticProjectile] = []
            survivors.reserveCapacity(projectiles.count)

            for var projectile in projectiles {
                if let parachute = projectile.descriptor.parachute,
                   projectile.elapsedSeconds >= parachute.deployDelaySeconds {
                    projectile.deployParachute()
                }

                let previousPosition = projectile.position
                let previousVelocity = projectile.velocity
                let (nextPosition, nextVelocity) = Self.integrate(
                    position: projectile.position,
                    velocity: projectile.velocity,
                    descriptor: projectile.descriptor,
                    environment: environment,
                    stepSeconds: step
                )
                projectile.apply(position: nextPosition, velocity: nextVelocity, stepSeconds: step)

                if let contact = Self.resolveContact(
                    projectile: &projectile,
                    from: previousPosition,
                    to: nextPosition,
                    surfaceProbe: surfaceProbe
                ) {
                    // Everything about the impact is reported at the crossing, not at the end of
                    // the step the crossing happened in.
                    let velocityAtContact = previousVelocity
                        + (nextVelocity - previousVelocity) * contact.stepFraction

                    // A solid object that still has energy bounces instead of stopping dead. The
                    // floor on normal speed is what ends it: without one the reflected speed decays
                    // geometrically and the object trembles against the surface forever.
                    let normalSpeed = abs(simd_dot(velocityAtContact, contact.normal))
                    if !contact.isWater,
                       projectile.descriptor.restitution > 0.01,
                       projectile.bounceCount < Self.maximumBounces,
                       normalSpeed * projectile.descriptor.restitution > Self.minimumBounceSpeed {
                        projectile.bounce(at: contact.point, normal: contact.normal)
                        bounces.append(
                            BallisticBounce(
                                projectileID: projectile.id,
                                kind: projectile.kind,
                                ownership: projectile.ownership,
                                position: contact.point,
                                normal: contact.normal,
                                normalSpeedMps: normalSpeed,
                                index: projectile.bounceCount
                            )
                        )
                        survivors.append(projectile)
                        continue
                    }
                    impacts.append(
                        BallisticImpact(
                            projectileID: projectile.id,
                            kind: projectile.kind,
                            ownership: projectile.ownership,
                            descriptor: projectile.descriptor,
                            position: contact.point,
                            velocity: velocityAtContact,
                            normal: contact.normal,
                            isWater: contact.isWater,
                            flightTimeSeconds: projectile.elapsedSeconds
                                - step * (1.0 - contact.stepFraction),
                            bounceCount: projectile.bounceCount
                        )
                    )
                    continue
                }

                let ranOut = projectile.elapsedSeconds >= Self.maximumFlightSeconds
                let fellThrough = projectile.position.y
                    < projectile.lastKnownSurfaceY - Self.lostBelowSurfaceMeters
                if ranOut || fellThrough {
                    abandoned.append((projectile.id, projectile.kind, projectile.ownership))
                    continue
                }
                survivors.append(projectile)
            }

            projectiles = survivors
        }

        return BallisticTickResult(impacts: impacts, bounces: bounces, abandoned: abandoned)
    }

    // MARK: - Prediction

    /// Where a projectile released *right now* would land — the continuously computed impact point
    /// an aiming reticle needs.
    ///
    /// Runs the same integrator, at a coarser step by default: the reticle needs metres of accuracy
    /// at ten hertz, not the millimetres the real flight is integrated to, and the difference is
    /// three hundred surface queries per frame versus thirty.
    func predictImpact(
        descriptor: BallisticDescriptor,
        position: SIMD3<Float>,
        carrierVelocity: SIMD3<Float>,
        separationImpulse: SIMD3<Float> = .zero,
        environment: BallisticEnvironment,
        surfaceProbe: BallisticSurfaceProbe,
        stepSeconds: Float = 1.0 / 30.0,
        maximumSeconds: Float = BallisticProjectileRuntime.maximumFlightSeconds
    ) -> BallisticPrediction {
        var projectile = BallisticProjectile(
            id: UUID(),
            descriptor: descriptor,
            kind: .fireCapsule(.medium),
            ownership: .local,
            position: position,
            velocity: carrierVelocity + separationImpulse,
            spinAxis: SIMD3<Float>(0, 1, 0),
            initialSurfaceY: surfaceProbe.ballisticSurfaceHeight(
                x: position.x,
                z: position.z,
                maximumHeight: position.y
            ) ?? 0.0
        )

        let step = max(1.0 / 240.0, stepSeconds)
        var elapsed: Float = 0.0
        while elapsed < maximumSeconds {
            // The canopy has to open in the prediction too. A rescue pack lands roughly a third as
            // far downrange under silk as it would in free fall, so a reticle that ignored the
            // parachute would point the pilot at somewhere the load never reaches.
            if let parachute = projectile.descriptor.parachute,
               projectile.elapsedSeconds >= parachute.deployDelaySeconds {
                projectile.deployParachute()
            }

            let previousPosition = projectile.position
            let previousVelocity = projectile.velocity
            let (nextPosition, nextVelocity) = Self.integrate(
                position: projectile.position,
                velocity: projectile.velocity,
                descriptor: projectile.descriptor,
                environment: environment,
                stepSeconds: step
            )
            projectile.apply(position: nextPosition, velocity: nextVelocity, stepSeconds: step)
            elapsed += step

            if let contact = Self.resolveContact(
                projectile: &projectile,
                from: previousPosition,
                to: nextPosition,
                surfaceProbe: surfaceProbe
            ) {
                return BallisticPrediction(
                    position: contact.point,
                    velocity: previousVelocity
                        + (nextVelocity - previousVelocity) * contact.stepFraction,
                    flightTimeSeconds: elapsed - step * (1.0 - contact.stepFraction),
                    isExtrapolated: false
                )
            }

            if projectile.position.y < projectile.lastKnownSurfaceY - Self.lostBelowSurfaceMeters {
                break
            }
        }

        return BallisticPrediction(
            position: projectile.position,
            velocity: projectile.velocity,
            flightTimeSeconds: elapsed,
            isExtrapolated: true
        )
    }

    // MARK: - Integration

    /// Acceleration on a projectile: gravity plus quadratic drag against the air it is moving
    /// through.
    ///
    /// Air density comes from the ISA model at the projectile's own altitude rather than a sea-level
    /// constant, matching what the flight model already does for the aircraft.
    private static func acceleration(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        descriptor: BallisticDescriptor,
        environment: BallisticEnvironment
    ) -> SIMD3<Float> {
        let gravity = SIMD3<Float>(0.0, -AtmosphereModel.gravityMps2, 0.0)
        let relativeVelocity = velocity - environment.windVector
        let relativeSpeed = simd_length(relativeVelocity)
        guard relativeSpeed > 1e-4 else {
            return gravity
        }
        let density = environment.airDensity(worldY: position.y)
        // ½·ρ·Cd·A·|v|² opposing motion, divided by mass → acceleration. Written as
        // (…·|v|)·v so the direction comes out of the vector itself.
        let dragMagnitudePerMass = 0.5 * density * descriptor.dragAreaPerMass * relativeSpeed
        return gravity - relativeVelocity * dragMagnitudePerMass
    }

    /// One classical RK4 step over the coupled position/velocity state.
    private static func integrate(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        descriptor: BallisticDescriptor,
        environment: BallisticEnvironment,
        stepSeconds: Float
    ) -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
        let h = stepSeconds

        let k1v = acceleration(position: position, velocity: velocity, descriptor: descriptor, environment: environment)
        let k1p = velocity

        let k2v = acceleration(
            position: position + k1p * (h * 0.5),
            velocity: velocity + k1v * (h * 0.5),
            descriptor: descriptor,
            environment: environment
        )
        let k2p = velocity + k1v * (h * 0.5)

        let k3v = acceleration(
            position: position + k2p * (h * 0.5),
            velocity: velocity + k2v * (h * 0.5),
            descriptor: descriptor,
            environment: environment
        )
        let k3p = velocity + k2v * (h * 0.5)

        let k4v = acceleration(
            position: position + k3p * h,
            velocity: velocity + k3v * h,
            descriptor: descriptor,
            environment: environment
        )
        let k4p = velocity + k3v * h

        let nextPosition = position + (k1p + 2.0 * k2p + 2.0 * k3p + k4p) * (h / 6.0)
        let nextVelocity = velocity + (k1v + 2.0 * k2v + 2.0 * k3v + k4v) * (h / 6.0)
        return (nextPosition, nextVelocity)
    }

    // MARK: - Contact

    private struct Contact {
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
        let isWater: Bool
        /// Where inside the step the crossing happened, 0...1.
        ///
        /// Carried out of the contact test because the impact point is not the only quantity that
        /// belongs at the crossing: reporting the velocity and the flight time from the *end* of
        /// the step instead overstates both by up to one step. Small — a step is 8 ms — but it is a
        /// bias, always in the same direction, and it showed up immediately as the probe's vacuum
        /// comparison failing by exactly that much.
        let stepFraction: Float
    }

    /// Did the segment `from` → `to` cross a surface?
    ///
    /// Two levels of fidelity, deliberately. A world that can cast a segment answers exactly,
    /// including vertical faces — a capsule thrown forward into a wall stops at the wall. A world
    /// that can only answer "what is under this column" (every procedural scene) is tested by
    /// stepping: the projectile is considered to have hit when it drops below the surface reported
    /// for its own column. That catches a building, but reports the contact on its roof rather than
    /// on the façade it actually flew into. Accepted for now, and the reason the segment cast is
    /// preferred whenever it is available.
    private static func resolveContact(
        projectile: inout BallisticProjectile,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        surfaceProbe: BallisticSurfaceProbe
    ) -> Contact? {
        if let hit = surfaceProbe.ballisticSegmentHit(from: from, to: to) {
            projectile.lastKnownSurfaceY = hit.point.y
            let segmentLength = simd_distance(from, to)
            let fraction = segmentLength > 1e-6
                ? min(1.0, max(0.0, simd_distance(from, hit.point) / segmentLength))
                : 1.0
            return Contact(
                point: hit.point,
                normal: hit.normal,
                isWater: hit.isWater,
                stepFraction: fraction
            )
        }

        let surfaceY = columnSurface(projectile: &projectile, from: from, to: to, surfaceProbe: surfaceProbe)

        // Water is checked against its own datum: open-data water has no collision floor, so the
        // column query returns the river bed or nothing at all where a splash belongs.
        if let waterLevel = surfaceProbe.ballisticWaterLevel(x: to.x, z: to.z),
           waterLevel >= surfaceY,
           to.y <= waterLevel,
           from.y > waterLevel {
            let crossing = interpolate(from: from, to: to, crossingY: waterLevel)
            return Contact(
                point: crossing.point,
                normal: SIMD3<Float>(0, 1, 0),
                isWater: true,
                stepFraction: crossing.fraction
            )
        }

        guard to.y <= surfaceY else {
            return nil
        }
        let crossing = from.y > surfaceY
            ? interpolate(from: from, to: to, crossingY: surfaceY)
            : (point: SIMD3<Float>(to.x, surfaceY, to.z), fraction: Float(1.0))
        return Contact(
            point: crossing.point,
            normal: SIMD3<Float>(0, 1, 0),
            isWater: false,
            stepFraction: crossing.fraction
        )
    }

    /// Surface height under the projectile, cached while it is still far above it.
    ///
    /// The uncached cost is real: the scene's column query casts twice into the mesh and then walks
    /// every procedural support surface. At 120 Hz with several capsules in the air that is over a
    /// thousand queries a second where the flight model does about a hundred.
    private static func columnSurface(
        projectile: inout BallisticProjectile,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        surfaceProbe: BallisticSurfaceProbe
    ) -> Float {
        let planar = SIMD2<Float>(to.x, to.z)
        let isCloseToSurface = to.y - projectile.lastKnownSurfaceY < closeApproachMeters
        let movedFar = simd_distance(planar, projectile.surfaceQueryPlanarPosition)
            > surfaceQueryPlanarToleranceMeters
        let staleQuery = projectile.secondsSinceSurfaceQuery > surfaceQueryIntervalSeconds

        if isCloseToSurface || movedFar || staleQuery {
            // Look down from the top of this step, so a roof the projectile is descending onto is
            // found while it is still above it.
            let ceiling = max(from.y, to.y)
            if let surface = surfaceProbe.ballisticSurfaceHeight(x: to.x, z: to.z, maximumHeight: ceiling) {
                projectile.lastKnownSurfaceY = surface
            }
            // A `nil` answer keeps the previous value: unknown ground is not sea level.
            projectile.surfaceQueryPlanarPosition = planar
            projectile.secondsSinceSurfaceQuery = 0.0
        }

        return projectile.lastKnownSurfaceY
    }

    private static func interpolate(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        crossingY: Float
    ) -> (point: SIMD3<Float>, fraction: Float) {
        let dy = from.y - to.y
        guard dy > 1e-6 else {
            return (SIMD3<Float>(to.x, crossingY, to.z), 1.0)
        }
        let t = min(1.0, max(0.0, (from.y - crossingY) / dy))
        let point = from + (to - from) * t
        return (SIMD3<Float>(point.x, crossingY, point.z), t)
    }
}
