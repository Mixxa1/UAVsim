import Foundation
import simd

// MARK: - Materials

struct ImpactSurfaceMaterial: Hashable {
    let restitution: Float
    let friction: Float
    let damageFactor: Float
    /// Relative resistance of the contacted surface.  This is kept separate
    /// from restitution: a soft surface can still bounce while absorbing a
    /// large part of the energy.
    let hardness: Float
    let energyAbsorption: Float
    let cuttingFactor: Float
    let abrasionFactor: Float
    let isFoliage: Bool

    static let hardStructure = ImpactSurfaceMaterial(restitution: 0.30, friction: 0.60, damageFactor: 1.15, hardness: 0.95, energyAbsorption: 0.12, cuttingFactor: 0.08, abrasionFactor: 0.75, isFoliage: false)
    static let metalVehicle = ImpactSurfaceMaterial(restitution: 0.30, friction: 0.50, damageFactor: 1.10, hardness: 0.90, energyAbsorption: 0.18, cuttingFactor: 0.15, abrasionFactor: 0.62, isFoliage: false)
    static let asphalt = ImpactSurfaceMaterial(restitution: 0.24, friction: 0.82, damageFactor: 1.10, hardness: 0.90, energyAbsorption: 0.15, cuttingFactor: 0.03, abrasionFactor: 1.00, isFoliage: false)
    static let glass = ImpactSurfaceMaterial(restitution: 0.12, friction: 0.35, damageFactor: 0.88, hardness: 0.72, energyAbsorption: 0.42, cuttingFactor: 0.90, abrasionFactor: 0.55, isFoliage: false)
    static let woodTrunk = ImpactSurfaceMaterial(restitution: 0.25, friction: 0.50, damageFactor: 1.00, hardness: 0.68, energyAbsorption: 0.30, cuttingFactor: 0.42, abrasionFactor: 0.48, isFoliage: false)
    static let foliage = ImpactSurfaceMaterial(restitution: 0.00, friction: 0.10, damageFactor: 0.00, hardness: 0.02, energyAbsorption: 0.95, cuttingFactor: 0.00, abrasionFactor: 0.00, isFoliage: true)
    static let soil = ImpactSurfaceMaterial(restitution: 0.18, friction: 0.70, damageFactor: 0.85, hardness: 0.45, energyAbsorption: 0.55, cuttingFactor: 0.00, abrasionFactor: 0.58, isFoliage: false)
    static let sand = ImpactSurfaceMaterial(restitution: 0.05, friction: 0.72, damageFactor: 0.55, hardness: 0.18, energyAbsorption: 0.82, cuttingFactor: 0.00, abrasionFactor: 0.78, isFoliage: false)
    static let snow = ImpactSurfaceMaterial(restitution: 0.03, friction: 0.34, damageFactor: 0.32, hardness: 0.08, energyAbsorption: 0.90, cuttingFactor: 0.00, abrasionFactor: 0.15, isFoliage: false)
    static let water = ImpactSurfaceMaterial(restitution: 0.02, friction: 0.08, damageFactor: 0.62, hardness: 0.12, energyAbsorption: 0.78, cuttingFactor: 0.00, abrasionFactor: 0.04, isFoliage: false)
    static let generic = ImpactSurfaceMaterial(restitution: 0.25, friction: 0.60, damageFactor: 1.00, hardness: 0.70, energyAbsorption: 0.30, cuttingFactor: 0.05, abrasionFactor: 0.55, isFoliage: false)
}

// MARK: - Report

enum ImpactOutcomeTier: String {
    /// Trajectory deflection, no damage.
    case lightTouch
    /// Scratches/scuffs — minor integrity loss.
    case scrape
    /// Component efficiency visibly reduced.
    case heavyImpact
    /// Component destroyed (integrity -> 0 possible).
    case criticalImpact
}

struct ImpactReport {
    let componentID: String
    let obstacleID: UUID
    let obstacleSource: String?
    let material: ImpactSurfaceMaterial
    /// What was struck, acoustically. Separate from `material`, which describes behaviour
    /// rather than sound — see `AcousticSurfaceMaterial`.
    let acousticSurface: AcousticSurfaceMaterial
    /// What struck it. The same wall is a different noise against a plastic cover and a steel
    /// motor, and a resolver given only one side of the contact cannot say which.
    let vehicleMaterial: VehicleAcousticMaterial
    let impactEnergyJ: Float
    let normalClosingSpeed: Float
    /// Sliding speed in the contact plane, m/s.
    ///
    /// The solver has always computed this — it is what the friction impulse is built from —
    /// and never published it, which is why nothing downstream could tell a hit from a hit
    /// that turns into a slide. A scrape needs exactly this number.
    let tangentialSpeed: Float
    let tier: ImpactOutcomeTier
    let damage: [VehicleComponentGraph.ImpactDamageEntry]
    let connectionDamage: [VehicleComponentGraph.ConnectionDamageEntry]
    let contactPoint: SIMD3<Float>
    let contactNormal: SIMD3<Float>
    let appliedImpulse: Float
    /// Explicit post-fracture motion for subtrees hit during this contact.
    /// The main airframe receives only the reaction transmitted through the
    /// failed joint; the remainder of the obstacle impulse stays with the
    /// separating part.
    let detachedPartMotions: [ImpactDetachedPartMotion]
    /// Steady contact forces (support, sliding friction) on the airframe this tick, body
    /// frame. They load the structure quasi-statically; they are not impacts.
    var sustainedForces: [StructuralPointForce] = []
    /// The obstacle broke instead of stopping the aircraft (a branch snapped).
    var obstacleGaveWay = false
}

/// An obstacle that is not rigid: it gives way at `force`, can then be pushed `stroke` further
/// before it has broken off or slid clear, and deflects with `stiffness` up to that point.
struct ObstacleYield {
    let force: Float
    let stroke: Float
    let stiffness: Float
    /// Whether giving way means breaking (a snapped branch stays gone) rather than bending
    /// clear and springing back.
    let breaks: Bool
    /// Mass the obstacle moves with at the struck point, and how far it can be pushed before
    /// it slides clear round the part.
    var mass: Float = .infinity
    var clearance: Float = .greatestFiniteMagnitude

    /// Work the obstacle can take before it has gone: its elastic energy at its yield load and
    /// the plastic work after that.
    var capacity: Float { force * (0.5 * force / max(1, stiffness) + stroke) }
}

struct ImpactDetachedPartMotion: Hashable {
    let rootComponentID: String
    let centerOfMassVelocityWorld: SIMD3<Float>
    let angularVelocityWorld: SIMD3<Float>
    let obstacleImpulseWorld: SIMD3<Float>
    let transmittedJointImpulseWorld: SIMD3<Float>
}

/// All contacting components share one body's momentum. Grouping a component's
/// coplanar samples gives a contact patch, so four feet do not become four full
/// aircraft impacts and a level touchdown does not invent a wingtip torque.
struct VehicleGroundContactSolver {
    func resolve(
        previousState: DroneState, state: inout DroneState,
        graph: inout VehicleComponentGraph, profile: VehicleContactProfile,
        massProperties: VehicleMassProperties, airframeClass: AirframeClass,
        obstacle: CollisionObstacle, normal: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        bodyOriginWorldOffset: SIMD3<Float> = .zero,
        hasWheels: Bool = false, rotorsSpinning: Bool, deltaTime: Float,
        skinMaterial: UAVSkinMaterial = .aluminium,
        jointPreload: [String: VehicleJointLoad]? = nil,
        thermalWeakening: Float = 0
    ) -> [ImpactReport] {
        guard !profile.isEmpty, deltaTime > 0 else { return [] }
        let n = simd_length_squared(normal) > 0.0001 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        let approach = state.groundApproach
        let orientation = approach?.attitude ?? state.attitudeQuat
        let origin = state.position + bodyOriginWorldOffset
        let planePoint = SIMD3<Float>(state.position.x, obstacle.topY, state.position.z)
        var patches: [String: [(VehicleContactSphere, SIMD3<Float>)]] = [:]
        for sphere in profile.spheres {
            guard graph.component(id: sphere.componentID)?.isAttached == true else { continue }
            let center = sphere.worldCenter(position: origin, orientation: orientation)
            let clearance = simd_dot(center - planePoint, n) - sphere.radius
            // Broad-phase proximity is not physical contact. In particular,
            // a spinning blade a few centimetres above the surface must not
            // spend its rotational energy against that surface.
            if clearance <= 0.002 {
                patches[sphere.componentID, default: []].append((sphere, center - n * (sphere.radius + clearance)))
            }
        }
        guard !patches.isEmpty else { return [] }
        let rates = approach?.rates ?? (airframeClass == .multirotor ? state.angularVelocity : state.bodyAngularVelocity)
        let omega = simd_act(orientation, SIMD3<Float>(rates.y, rates.z, rates.x))
        let incoming = approach?.velocity ?? state.velocity
        let com = origin + simd_act(orientation, massProperties.centerOfMassOffset)
        let hasArrival = patches.values.contains { patch in
            patch.contains { -simd_dot(incoming + simd_cross(omega, $0.1 - com), n) > 0.35 }
        }
        if hasArrival, let approach {
            state.velocity = approach.velocity
            state.attitudeQuat = approach.attitude
            state.orientation = approach.euler
            state.angularVelocity = approach.rates
            state.bodyAngularVelocity = approach.rates
        }
        state.groundApproach = nil
        let resolver = ImpactResolutionService()
        var reports: [ImpactReport] = []
        let ids = patches.keys.sorted()
        let points = ids.map { id in patches[id]!.reduce(SIMD3<Float>.zero) { $0 + $1.1 } / Float(patches[id]!.count) }
        // How the weight is actually shared: the least-effort set of support forces that holds
        // the aircraft in equilibrium over its contacts. A wing tip touching beside a loaded gear
        // leg takes almost nothing; the same tip with the gear gone takes its share of the weight.
        // What the ground has to hold is the weight less what the wing is already lifting.
        let flightLift = state.specificForceBody.map { simd_act(orientation, $0).y } ?? 0
        let support = Self.supportDistribution(points: points, centerOfMass: com, normal: n,
                                               weight: massProperties.totalMassKg * max(0, 9.81 - flightLift))
        for (slot, id) in ids.enumerated() {
            guard let patch = patches[id], let component = graph.component(id: id) else { continue }
            let point = points[slot]
            let sphere = patch[0].0
            let gear: Bool = { if case .landingGear = component.kind { return true }; return false }()
            let contact = VehicleSweptContact(obstacle: obstacle, componentID: id,
                contactPoint: point, contactNormal: n, hitFraction: 1,
                isSupportSurfaceContact: true, sphereOffset: sphere.offset, sphereRadius: sphere.radius)
            let rotorSpeed: Float = {
                guard case .propeller(let slot) = component.kind else { return 0 }
                if let lane = VehicleRotor.laneIndex(forSlot: slot) { return abs(state.rotorAngularSpeed[lane]) }
                return max(abs(state.rotorAngularSpeed.x), state.motorThrottle * 600)
            }()
            let report = resolver.resolve(contact: contact, previousPosition: previousState.position,
                state: &state, graph: &graph, massProperties: massProperties,
                airframeClass: airframeClass, bodyOriginWorldOffset: bodyOriginWorldOffset,
                rotorsSpinning: rotorsSpinning, deltaTime: deltaTime,
                restingSpeedThreshold: 0.35, skinMaterial: skinMaterial,
                supportLoadNewtons: support[slot],
                rollingContact: hasWheels && gear && component.integrity > 0.6 && component.stiffnessScale > 0.6,
                rotorSpeedRadPerSec: rotorSpeed,
                jointPreload: jointPreload, thermalWeakening: thermalWeakening)
            if report.normalClosingSpeed > 0.35 || !report.damage.isEmpty || !report.connectionDamage.isEmpty || report.tangentialSpeed > 0.1 {
                reports.append(report)
            }
        }
        // The blow is resolved; what remains is standing on the ground. Putting the approach
        // state back (above) also undid the contact the engine had already applied at the points
        // that touch, so a wreck rocking on its arms had its rotation restored to it every step
        // and rocked for ever. The same contact is applied once more over the result: no
        // restitution, only what holds a body on a surface and rubs against its motion.
        let restingAttitude = state.attitudeQuat
        let onGear = profile.spheres.contains { sphere in
            let bottom = simd_act(restingAttitude, sphere.offset).y - sphere.radius
            let lowest = profile.spheres.map { simd_act(restingAttitude, $0.offset).y - $0.radius }.min() ?? bottom
            return bottom <= lowest + 0.025 && (sphere.isGroundSupport || sphere.componentID.hasPrefix("gear."))
        }
        if !onGear {
            var rates = airframeClass == .multirotor ? state.angularVelocity : state.bodyAngularVelocity
            ImpactResolutionService.applyGroundContactImpulses(
                velocity: &state.velocity,
                rates: &rates,
                attitude: restingAttitude,
                normal: n,
                penetration: 0,
                spheres: profile.spheres,
                fallbackBoxes: graph.rotationalDragElements(),
                centerOfMass: massProperties.centerOfMassOffset,
                mass: max(0.05, massProperties.totalMassKg),
                inertiaRateOrdered: SIMD3<Float>(massProperties.inertiaDiagonal.z,
                                                 massProperties.inertiaDiagonal.x,
                                                 massProperties.inertiaDiagonal.y))
            state.angularVelocity = rates
            state.bodyAngularVelocity = rates
        }
        return reports
    }

    /// Minimum-norm non-negative support forces at the contact points that balance the weight
    /// and its moments about the centre of mass in the contact plane (active-set least
    /// squares). A contact that would have to pull is dropped and the rest re-solved.
    static func supportDistribution(points: [SIMD3<Float>], centerOfMass: SIMD3<Float>,
                                    normal: SIMD3<Float>, weight: Float) -> [Float] {
        guard !points.isEmpty else { return [] }
        let helper = abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let axisA = simd_normalize(simd_cross(normal, helper))
        let axisB = simd_cross(normal, axisA)
        let levers = points.map { point -> SIMD2<Double> in
            let d = point - centerOfMass
            return SIMD2<Double>(Double(simd_dot(d, axisA)), Double(simd_dot(d, axisB)))
        }
        var active = Array(points.indices)
        var result = [Float](repeating: 0, count: points.count)
        for _ in 0..<points.count {
            // A F = b with rows (1…1), (dA…), (dB…); F = Aᵀ (A Aᵀ)⁻¹ b.
            var m = simd_double3x3()
            for i in active {
                let row = SIMD3<Double>(1, levers[i].x, levers[i].y)
                m += simd_double3x3(columns: (row * row.x, row * row.y, row * row.z))
            }
            let b = SIMD3<Double>(Double(weight), 0, 0)
            let determinant = m.determinant
            var forces = [Double](repeating: 0, count: points.count)
            if abs(determinant) > 1e-12 {
                let lambda = m.inverse * b
                for i in active { forces[i] = simd_dot(SIMD3<Double>(1, levers[i].x, levers[i].y), lambda) }
            } else {
                // Collinear or single contact: share the weight among them.
                for i in active { forces[i] = Double(weight) / Double(active.count) }
            }
            let negative = active.filter { forces[$0] < 0 }
            if negative.isEmpty || active.count <= 1 {
                for i in active { result[i] = Float(max(0, forces[i])) }
                return result
            }
            // Drop the most negative contact and solve again.
            let worst = negative.min { forces[$0] < forces[$1] }!
            active.removeAll { $0 == worst }
        }
        for i in active { result[i] = weight / Float(max(1, active.count)) }
        return result
    }
}

// MARK: - Service

/// Rigid-body impact resolution replacing the legacy "teleport to contact,
/// zero the velocity, flatten the attitude" collision response: a proper
/// contact impulse with lever arm (linear + angular response), tangential
/// friction, material-dependent restitution, and *localized* damage applied
/// to the struck component and its neighbors — never uniformly to the whole
/// airframe.
final class ImpactResolutionService {

    static func isPenetrable(_ contact: VehicleSweptContact) -> Bool {
        material(forObstacleSource: contact.obstacle.source, obstacle: contact.obstacle,
                 contactPoint: contact.contactPoint).isFoliage
    }

    static func contactDuration(component: VehicleComponent?, material: ImpactSurfaceMaterial, closingSpeed: Float) -> Float {
        let dimension = component.map { min($0.boundingHalfExtents.x, $0.boundingHalfExtents.y, $0.boundingHalfExtents.z) * 2 } ?? 0.02
        let gearTravel: Float = component.map { if case .landingGear = $0.kind { return max(0.025, dimension * 0.65) }; return dimension * 0.12 } ?? 0.003
        let stroke = gearTravel + material.energyAbsorption * 0.06
        return min(0.12, max(0.004, 2 * stroke / max(0.5, closingSpeed)))
    }

    // MARK: Material lookup

    /// Material by obstacle source string. Tree obstacles are composite:
    /// contact low on the cylinder or close to its axis is trunk wood,
    /// everything else is canopy foliage.
    static func material(
        forObstacleSource source: String?,
        obstacle: CollisionObstacle?,
        contactPoint: SIMD3<Float>
    ) -> ImpactSurfaceMaterial {
        guard let source = source?.lowercased() else {
            return .generic
        }

        if source.contains("trunk") || source.contains("branch") {
            return .woodTrunk
        }
        if source.contains("canopy") || source.contains("foliage") || source.contains("leaves") {
            return .foliage
        }
        if source.contains("tree") {
            guard let obstacle else { return .woodTrunk }
            let height = max(0.1, obstacle.topY - obstacle.baseY)
            let heightFraction = (contactPoint.y - obstacle.baseY) / height
            let planarDistance = simd_distance(
                SIMD2<Float>(contactPoint.x, contactPoint.z),
                obstacle.planarCenter
            )
            let isTrunk = heightFraction < 0.35 || planarDistance < obstacle.radius * 0.30
            return isTrunk ? .woodTrunk : .foliage
        }
        if source.contains("glass") || source.contains("window") {
            return .glass
        }
        if source.contains("container") || source.contains("building") ||
            source.contains("wall") || source.contains("concrete") ||
            source.contains("crate") || source.contains("structure") {
            return .hardStructure
        }
        if source.contains("truck") || source.contains("vehicle") || source.contains("metal") {
            return .metalVehicle
        }
        if source.contains("asphalt") || source.contains("runway") || source.contains("road") {
            return .asphalt
        }
        if source.contains("sand") {
            return .sand
        }
        if source.contains("snow") || source.contains("ice") {
            return .snow
        }
        if source.contains("water") || source.contains("river") || source.contains("lake") {
            return .water
        }
        if source.contains("ground") || source.contains("terrain") || source.contains("soil") {
            return .soil
        }
        return .generic
    }

    /// What the struck surface sounds like.
    ///
    /// The obstacle's own declaration wins, because whoever built it knew. Only when nothing
    /// was declared does this fall back — first to the physical material the collision solver
    /// already resolved, which is a better guess than a second independent keyword match, and
    /// then to the provenance string.
    ///
    /// The tree case is the one place the two resolutions must agree rather than merely
    /// coexist: `material(forObstacleSource:)` decides trunk-versus-canopy from where on the
    /// cylinder the contact landed, and an acoustic classifier that re-derived that from the
    /// name alone would put a canopy brush and a trunk strike in the same bucket.
    static func acousticSurface(
        for obstacle: CollisionObstacle,
        contactPoint: SIMD3<Float>,
        physicalMaterial: ImpactSurfaceMaterial
    ) -> AcousticSurfaceMaterial {
        if let declared = obstacle.acousticSurface { return declared }

        switch physicalMaterial {
        case .foliage:
            return .foliage
        case .woodTrunk:
            return .treeTrunk
        case .glass:
            return .glass
        case .asphalt:
            return .asphalt
        case .metalVehicle:
            return .metal
        case .water:
            return .water
        case .snow:
            return .snow
        case .sand, .soil:
            // Sand and soil differ in how much they absorb, which the physics cares about,
            // and hardly at all in the dull thump they make.
            return .soil
        case .hardStructure, .generic:
            // A hard structure could be masonry, a shipping container or a crate. This is
            // where the name is genuinely the only evidence.
            return AcousticSurfaceMaterial.fromObstacleSource(obstacle.source)
        default:
            return AcousticSurfaceMaterial.fromObstacleSource(obstacle.source)
        }
    }

    /// What the part that made contact is made of.
    static func vehicleMaterial(
        componentID: String,
        graph: VehicleComponentGraph,
        skin: UAVSkinMaterial
    ) -> VehicleAcousticMaterial {
        guard let component = graph.component(id: componentID) else {
            return VehicleAcousticMaterial.fromSkin(skin)
        }
        return VehicleAcousticMaterial.resolve(componentKind: component.kind, skin: skin)
    }

    // MARK: Impact resolution

    /// Resolves a swept contact in place: applies the contact impulse (and
    /// friction) to the state's linear/angular velocity, moves the vehicle to
    /// its pose at the hit fraction plus a small separation, and applies
    /// localized damage to the graph. Returns the report for HUD/log/failure
    /// consumers.
    func resolve(
        contact: VehicleSweptContact,
        previousPosition: SIMD3<Float>,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        bodyOriginWorldOffset: SIMD3<Float> = .zero,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool = true,
        restingSpeedThreshold: Float = 0.01,
        /// What the airframe's structure is made of. Defaulted so callers that do not care
        /// about sound — the headless contact probes — are unaffected.
        skinMaterial: UAVSkinMaterial = .aluminium,
        supportLoadNewtons: Float = 0.0,
        rollingContact: Bool = false,
        rotorSpeedRadPerSec: Float = 0.0,
        /// Loads already on each joint before this contact (flight or resting), by child id.
        /// Nil means the aircraft is taken as resting under its own weight.
        jointPreload: [String: VehicleJointLoad]? = nil,
        thermalWeakening: Float = 0.0,
        obstacleYield: ObstacleYield? = nil
    ) -> ImpactReport {
        let material = Self.material(
            forObstacleSource: contact.obstacle.source,
            obstacle: contact.obstacle,
            contactPoint: contact.contactPoint
        )
        let acousticSurface = Self.acousticSurface(
            for: contact.obstacle,
            contactPoint: contact.contactPoint,
            physicalMaterial: material
        )

        if material.isFoliage {
            return resolveFoliageContact(
                contact: contact,
                material: material,
                acousticSurface: acousticSurface,
                skinMaterial: skinMaterial,
                previousPosition: previousPosition,
                state: &state,
                graph: &graph,
                massProperties: massProperties,
                airframeClass: airframeClass,
                bodyOriginWorldOffset: bodyOriginWorldOffset,
                rotorsSpinning: rotorsSpinning,
                deltaTime: deltaTime,
                applyDamage: applyDamage,
                jointPreload: jointPreload,
                thermalWeakening: thermalWeakening
            )
        }

        let orientation = attitudeQuaternion(state: state, airframeClass: airframeClass)
        let normal = simd_normalize(contact.contactNormal)
        let mass = max(0.2, massProperties.totalMassKg)
        let travel: SIMD3<Float> = state.position - previousPosition
        let statePositionAtHit: SIMD3<Float> = previousPosition + travel * contact.hitFraction
        let bodyOriginAtHit = statePositionAtHit + bodyOriginWorldOffset
        let contactBodyAtHit = simd_act(
            orientation.conjugate,
            contact.contactPoint - bodyOriginAtHit
        )
        let resolvedComponentID = nearestComponentID(
            to: contactBodyAtHit,
            preferred: contact.componentID,
            graph: graph
        )

        // Contact kinematics are evaluated before touching the position so a
        // resting/tangential contact (a parked aircraft brushing a wall, a
        // gear sphere kissing a container roof at zero approach speed) does
        // NOT get shoved around every tick.
        let worldCoM = bodyOriginAtHit + simd_act(orientation, massProperties.centerOfMassOffset)
        let leverArm = contact.contactPoint - worldCoM
        let omegaWorld = worldAngularVelocity(state: state, orientation: orientation, airframeClass: airframeClass)
        let incomingLinearVelocity = state.velocity
        let failedRootsBeforeImpact = Set(graph.failedConnectionRootIDs)
        let contactVelocity = state.velocity + simd_cross(omegaWorld, leverArm)
        let normalClosingSpeed = -simd_dot(contactVelocity, normal)

        let primary = graph.component(id: resolvedComponentID)
        let bladeRadius = primary.map { max($0.boundingHalfExtents.x, $0.boundingHalfExtents.y, $0.boundingHalfExtents.z) } ?? 0
        let shaftSpeed: Float = {
            if rotorSpeedRadPerSec > 0 { return rotorSpeedRadPerSec }
            if case .propeller(let slot) = primary?.kind, let lane = VehicleRotor.laneIndex(forSlot: slot) {
                return abs(state.rotorAngularSpeed[lane])
            }
            return max(abs(state.rotorAngularSpeed.x), state.motorThrottle * 600)
        }()
        let bladeEnergy: Float = rotorsSpinning && isPropellerComponent(resolvedComponentID, graph: graph)
            ? 0.5 * (primary?.massKg ?? 0) * (primary?.integrity ?? 0) * bladeRadius * bladeRadius / 3.0 * shaftSpeed * shaftSpeed : 0
        guard normalClosingSpeed > restingSpeedThreshold || supportLoadNewtons > 0 || bladeEnergy > 0 else {
            // Receding, tangential, or (for an uncontrolled/crashed body, whose caller raises
            // restingSpeedThreshold above the live-flight default) a settled resting contact:
            // nothing to bounce off. If the
            // sweep started already penetrating (hitFraction ~ 0) AND the
            // vehicle is actually moving, bleed out of the surface gently
            // instead of allowing a slow burrow. A resting body is left
            // alone — the per-tick nudge would read as creeping/fidgeting.
            if contact.hitFraction <= 0.001, simd_length(state.velocity) > 0.1 {
                state.position += normal * min(0.004, max(0.001, contact.sphereRadius * 0.02))
            }
            // A contact with no approach speed is very often a *slide* — a wreck skidding
            // along a runway, a gear leg dragging across a roof — so the tangential speed is
            // reported here too. Returning zero would silence exactly the case scrape exists
            // for.
            let restingTangentialSpeed = simd_length(contactVelocity + normal * normalClosingSpeed)
            return ImpactReport(
                componentID: contact.componentID,
                obstacleID: contact.obstacle.id,
                obstacleSource: contact.obstacle.source,
                material: material,
                acousticSurface: acousticSurface,
                vehicleMaterial: Self.vehicleMaterial(
                    componentID: contact.componentID,
                    graph: graph,
                    skin: skinMaterial
                ),
                impactEnergyJ: 0.0,
                normalClosingSpeed: max(0.0, normalClosingSpeed),
                tangentialSpeed: restingTangentialSpeed,
                tier: .lightTouch,
                damage: [],
                connectionDamage: [],
                contactPoint: contact.contactPoint,
                contactNormal: normal,
                appliedImpulse: 0.0,
                detachedPartMotions: []
            )
        }

        // Stop the vehicle at its pose along the step where contact happened
        // (its own path — not a jump to some other point), with a small
        // normal separation so the next tick doesn't immediately re-collide.
        let separation = max(0.005, contact.sphereRadius * 0.04)
        // The ground already holds the aircraft on its surface (the engine's clamp). Lifting it
        // off as well — 4 % of a sphere's radius, two centimetres on an MQ-9B — handed a lying
        // 4.7-tonne wreck 900 J at every touch, and it hopped for ever on its own lift.
        if normalClosingSpeed > restingSpeedThreshold && !contact.isSupportSurfaceContact {
            state.position = statePositionAtHit + normal * separation
        }

        // Effective mass along the contact normal: 1/K with the standard
        // K = 1/m + n·((I⁻¹(r×n))×r). Glancing hits far from the CoM see a
        // much smaller effective mass — they spin the airframe instead of
        // stopping it.
        let angularTermNormal = angularResponse(
            leverArm: leverArm,
            direction: normal,
            orientation: orientation,
            inertiaDiagonal: massProperties.inertiaDiagonal
        )
        let kNormal = 1.0 / mass + simd_dot(angularTermNormal.velocityAtContact, normal)
        let effectiveMass = 1.0 / max(0.0001, kNormal)

        let closing = max(0, normalClosingSpeed)
        let restitution = Self.impactRestitution(material: material, closingSpeed: closing)
        var candidateNormalImpulse = normalClosingSpeed > restingSpeedThreshold
            ? (1.0 + restitution) * closing * effectiveMass : 0.0
        // A yielding obstacle takes at most the work it can absorb before it has gone. If the
        // blow carries more than that, the aircraft goes through with what is left over: it
        // loses exactly that work along the normal, and no rebound.
        var rigidObstacleGaveWay = false
        if let obstacleYield, candidateNormalImpulse > 0 {
            // Going through it means doing its work and carrying its mass away at the speed
            // the aircraft leaves with: ½·m·v² = ½·(m + M)·v′² + W.
            let obstacleMass = obstacleYield.mass.isFinite ? obstacleYield.mass : 0
            let spare = effectiveMass * closing * closing - 2 * obstacleYield.capacity
            if spare > 0 {
                let exitSpeed = (spare / (effectiveMass + obstacleMass)).squareRoot()
                candidateNormalImpulse = effectiveMass * (closing - exitSpeed)
                rigidObstacleGaveWay = true
            }
        }
        let supportImpulse = max(0, supportLoadNewtons) * max(0, deltaTime)

        // Coulomb-ish friction impulse against the tangential contact velocity.
        var tangentialVelocity = contactVelocity + normal * normalClosingSpeed
        if rollingContact {
            let forward = simd_act(orientation, SIMD3<Float>(0, 0, -1))
            let projected = forward - normal * simd_dot(forward, normal)
            if simd_length_squared(projected) > 0.0001 {
                let rollingAxis = simd_normalize(projected)
                tangentialVelocity -= rollingAxis * simd_dot(tangentialVelocity, rollingAxis)
            }
        }
        let tangentialSpeed = simd_length(tangentialVelocity)
        var tangent = SIMD3<Float>(repeating: 0.0)
        var candidateFrictionImpulse: Float = 0.0
        var tangentInverseMass: Float = 0
        if tangentialSpeed > 0.05 {
            tangent = tangentialVelocity / tangentialSpeed
            let angularTermTangent = angularResponse(
                leverArm: leverArm,
                direction: tangent,
                orientation: orientation,
                inertiaDiagonal: massProperties.inertiaDiagonal
            )
            let kTangent = 1.0 / mass + simd_dot(angularTermTangent.velocityAtContact, tangent)
            tangentInverseMass = max(0.0001, kTangent)
            let stoppingImpulse = tangentialSpeed / tangentInverseMass
            candidateFrictionImpulse = min(material.friction * max(candidateNormalImpulse, supportImpulse), stoppingImpulse)
        }

        // Localized damage from the energy the contact actually absorbed.
        let impactEnergy = 0.5 * effectiveMass * closing * closing
        let absorption = min(1.0, max(0.0, material.energyAbsorption))
        var transmittedNormalEnergy = impactEnergy * (1.0 - restitution * restitution) * (1.0 - absorption)
        if let obstacleYield {
            // The part deforms against at most the obstacle's own resistance: it cannot be
            // handed more work than the obstacle can take before it has gone.
            transmittedNormalEnergy = min(transmittedNormalEnergy, obstacleYield.capacity * (1.0 - absorption))
        }
        // Work done by friction, bounded by the stopping impulse. Previously
        // every glancing touch charged a fixed fraction of ALL sideways kinetic
        // energy, even when almost no impulse could be transmitted.
        let frictionWork = max(0, candidateFrictionImpulse * tangentialSpeed
            - 0.5 * tangentInverseMass * candidateFrictionImpulse * candidateFrictionImpulse)
        let abrasionEnergy = frictionWork * material.abrasionFactor
        var damageFactor = material.damageFactor
        if rotorsSpinning, isPropellerComponent(resolvedComponentID, graph: graph) {
            // A spinning blade striking anything sheds far more of itself
            // than a static one.
            damageFactor *= 1.6 + material.cuttingFactor * 0.25
        }
        let isImpact = normalClosingSpeed > restingSpeedThreshold
        var contactDuration = Self.contactDuration(component: primary, material: material, closingSpeed: closing)
        if let obstacleYield, obstacleYield.stiffness.isFinite, obstacleYield.mass < effectiveMass {
            // Against something lighter than the blow that bends, the contact lasts as long as
            // half a swing of the aircraft on the obstacle's spring — a twig is not a wall. A
            // heavier obstacle is met by its mass first, as abruptly as any other; its sway
            // afterwards is too slow to matter to the aircraft's structure.
            let reduced = effectiveMass * obstacleYield.mass / (effectiveMass + obstacleYield.mass)
            contactDuration = max(contactDuration, Float.pi * (reduced / max(1, obstacleYield.stiffness)).squareRoot())
        }
        // A blunt part — a fuselage, a pod, a gimbal — struck harder than its skin and core
        // can carry folds up locally, the way a member station does in the member solver: the
        // blow is carried at its crush force for as long as there is depth left to crush, and
        // only what is left after that is a hard stop. Left out, every such blow was a rigid
        // three-millisecond pulse, and a fuselage meeting a tree at 30 m/s put a thousand g
        // through every mount on the aircraft.
        var bluntCrush: (force: Float, crushTime: Float, energy: Float, remainder: Float)?
        if isImpact, !rigidObstacleGaveWay, candidateNormalImpulse > 0,
           Self.memberStation(containing: resolvedComponentID, graph: graph) == nil,
           let primary, let limit = Self.bluntCrushLimit(part: primary, normalBody: simd_act(orientation.conjugate, normal),
                                                       obstacle: contact.obstacle, material: material, graph: graph),
           candidateNormalImpulse * Float.pi / (2 * max(0.001, contactDuration)) > limit.force {
            let normalEnergy = 0.5 * effectiveMass * closing * closing
            if normalEnergy <= limit.force * limit.depth {
                // All of it goes into folding the part up; nothing is left to rebound with.
                candidateNormalImpulse = effectiveMass * closing
                bluntCrush = (limit.force, candidateNormalImpulse / limit.force, normalEnergy, 0)
            } else {
                let exit = (closing * closing - 2 * limit.force * limit.depth / effectiveMass).squareRoot()
                let crushImpulse = effectiveMass * (closing - exit)
                // What is behind a part crushed through is more structure, and it crushes too:
                // nothing is left to spring back with.
                let remainder = exit * effectiveMass
                candidateNormalImpulse = crushImpulse + remainder
                bluntCrush = (limit.force, crushImpulse / limit.force, limit.force * limit.depth, remainder)
            }
            if tangentialSpeed > 0.05 {
                candidateFrictionImpulse = min(material.friction * candidateNormalImpulse, tangentialSpeed / tangentInverseMass)
            }
            // The part took the crushing itself; only the hard remainder hands energy over the
            // way an elastic blow does.
            let remainderSpeed = bluntCrush!.remainder / max(0.0001, effectiveMass)
            transmittedNormalEnergy = bluntCrush!.energy + 0.5 * effectiveMass * remainderSpeed * remainderSpeed * (1 - absorption)
        }
        let preload = jointPreload ?? Self.restingPreload(graph: graph, massProperties: massProperties, orientation: orientation)

        var damage: [VehicleComponentGraph.ImpactDamageEntry] = []
        var connectionDamage: [VehicleComponentGraph.ConnectionDamageEntry] = []
        var detachedPartMotions: [ImpactDetachedPartMotion] = []
        var appliedNormalImpulse = candidateNormalImpulse
        var damageEnergy = transmittedNormalEnergy + abrasionEnergy + bladeEnergy * (1.0 - absorption)
        var sustainedForces: [StructuralPointForce] = []

        if isImpact, applyDamage, let member = Self.memberStation(containing: resolvedComponentID, graph: graph) {
            // A slender member was struck: solve the member and the aircraft together through
            // the contact. The chain decides where it bends, folds or breaks, how long the
            // contact lasts, and what momentum each piece leaves with.
            let restitution = min(0.95, max(0.02, Self.impactRestitution(material: material, closingSpeed: closing)))
            let logE = log(restitution)
            let contactZeta = -logE / (Float.pi * Float.pi + logE * logE).squareRoot()
            let conjugate = orientation.conjugate
            let normalBody = simd_act(conjugate, normal)
            let crush = Self.crushLimits(station: member.stations[member.index], normalBody: normalBody,
                                         obstacle: contact.obstacle, material: material, graph: graph)
            // The contact spring is the struck part's own local stiffness: it deflects about
            // 3 % of its crushable depth before it starts to crush (the elastic range of a
            // honeycomb or laminate panel). A stiffness taken from the whole aircraft's
            // effective mass would bounce the part off in a fraction of a millisecond.
            let rigidStiffness = max(1, effectiveMass) * (Float.pi / max(0.001, contactDuration)) * (Float.pi / max(0.001, contactDuration))
            let localStiffness = crush.force.isFinite ? crush.force / max(1e-4, 0.03 * crush.depth) : rigidStiffness
            let stiffness = min(rigidStiffness, localStiffness)
            let localMass = max(0.001, graph.component(id: member.stations[member.index])?.massKg ?? effectiveMass)
            let damping = 2 * contactZeta * (stiffness * localMass).squareRoot()
            let input = StructuralMemberImpactSolver.Input(
                graph: graph,
                memberStationIDs: member.stations,
                contact: .init(
                    stationIndex: member.index,
                    pointBody: contactBodyAtHit,
                    normalBody: normalBody,
                    stiffness: stiffness,
                    damping: damping,
                    friction: material.friction,
                    expectedDuration: contactDuration,
                    crushForce: crush.force,
                    crushDepth: crush.depth,
                    obstacleMass: obstacleYield?.mass ?? .infinity,
                    obstacleStiffness: obstacleYield?.stiffness ?? .infinity,
                    obstacleYieldForce: obstacleYield?.force ?? .greatestFiniteMagnitude,
                    obstacleStroke: obstacleYield?.stroke ?? .greatestFiniteMagnitude,
                    obstacleClearance: obstacleYield?.clearance ?? .greatestFiniteMagnitude),
                velocityBody: simd_act(conjugate, incomingLinearVelocity),
                angularVelocityBody: simd_act(conjugate, omegaWorld),
                centerOfMassBody: massProperties.centerOfMassOffset,
                preload: preload,
                thermalWeakening: thermalWeakening)
            let solveStart = CFAbsoluteTimeGetCurrent()
            let solved = StructuralMemberImpactSolver().solve(input)
            if StructuralMemberImpactSolver.debugLog {
                print("[MemberImpact] solve \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - solveStart) * 1000))ms")
            }
            if let result = solved {
                // Local crushing takes what the contact dissipated on the aircraft's side, and
                // everything the part absorbed folding up.
                damageEnergy = result.contactDissipatedEnergy * (1 - absorption) + result.crushEnergy
                    + result.frictionWork * material.abrasionFactor + bladeEnergy * (1 - absorption)
                if damageEnergy > 0.0001 {
                    let ratio = damageEnergy * damageFactor / max(0.5, Self.tierStrength(for: resolvedComponentID, graph: graph))
                    damage = graph.applyImpact(
                        primaryComponentID: resolvedComponentID,
                        energyJ: damageEnergy,
                        damageFactor: damageFactor,
                        spreadRadius: 0.15 + 0.45 * min(1, ratio),
                        contactPointBody: contactBodyAtHit,
                        impulseBody: simd_act(conjugate, normal) * result.normalImpulse)
                }
                if result.cutThrough {
                    // The obstacle went through this station: what remains of it is wreckage.
                    let struckStation = member.stations[member.index]
                    let before = graph.component(id: struckStation)?.integrity ?? 1
                    graph.setIntegrity(min(before, 0.05), id: struckStation)
                    damage.append(VehicleComponentGraph.ImpactDamageEntry(
                        componentID: struckStation,
                        legacyComponent: graph.component(id: struckStation)?.legacyComponent,
                        integrityBefore: before, integrityAfter: min(before, 0.05),
                        residualStrengthBefore: 1, residualStrengthAfter: 0.05,
                        stiffnessBefore: 1, stiffnessAfter: 0.08))
                }
                for joint in result.joints {
                    if let entry = graph.applyJointOutcome(
                        childComponentID: joint.stationID,
                        plasticRotationBody: joint.outcome.plasticRotationBody,
                        plasticRotationSpent: joint.outcome.plasticRotationSpent,
                        residualStrength: joint.outcome.residualStrength,
                        stiffnessScale: joint.outcome.stiffnessScale,
                        fracture: joint.outcome.fracture) {
                        connectionDamage.append(entry)
                    }
                }
                // The rest of the airframe felt the retained body's deceleration.
                let shockStart = CFAbsoluteTimeGetCurrent()
                defer {
                    if StructuralMemberImpactSolver.debugLog {
                        print("[MemberImpact] shock \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - shockStart) * 1000))ms")
                    }
                }
                connectionDamage += Self.applyInertialShock(
                    graph: &graph,
                    massProperties: massProperties,
                    history: result.bodyAccelerationHistory,
                    excludedMember: member.memberID,
                    stationAccelerations: result.peakStationAcceleration,
                    directForce: nil,
                    preload: preload,
                    thermalWeakening: thermalWeakening)
                state.velocity = simd_act(orientation, result.retainedVelocityBody)
                if result.obstacleGaveWay {
                    // Nothing is left in the way: the aircraft finishes the step through where
                    // the obstacle was, at the speed it came out with.
                    state.position = statePositionAtHit + state.velocity * (1 - contact.hitFraction) * deltaTime
                }
                let omegaAfter = simd_act(orientation, result.retainedAngularVelocityBody)
                applyWorldAngularDelta(omegaAfter - omegaWorld, state: &state, orientation: orientation,
                                       airframeClass: airframeClass)
                appliedNormalImpulse = result.normalImpulse
                for fragment in result.fragments {
                    detachedPartMotions.append(ImpactDetachedPartMotion(
                        rootComponentID: fragment.rootStationID,
                        centerOfMassVelocityWorld: simd_act(orientation, fragment.velocityBody),
                        angularVelocityWorld: clampMagnitude(simd_act(orientation, fragment.angularVelocityBody), limit: 60),
                        obstacleImpulseWorld: normal * result.normalImpulse,
                        transmittedJointImpulseWorld: .zero))
                }
                let ratio = damageEnergy * damageFactor / max(0.5, Self.tierStrength(for: resolvedComponentID, graph: graph))
                var report = ImpactReport(
                    componentID: resolvedComponentID,
                    obstacleID: contact.obstacle.id,
                    obstacleSource: contact.obstacle.source,
                    material: material,
                    acousticSurface: acousticSurface,
                    vehicleMaterial: Self.vehicleMaterial(componentID: resolvedComponentID, graph: graph, skin: skinMaterial),
                    impactEnergyJ: impactEnergy,
                    normalClosingSpeed: normalClosingSpeed,
                    tangentialSpeed: tangentialSpeed,
                    tier: Self.tier(forEnergyRatio: ratio, structuralFailure: !result.fragments.isEmpty
                        || result.joints.contains { $0.outcome.fracture != .intact }),
                    damage: damage,
                    connectionDamage: connectionDamage,
                    contactPoint: contact.contactPoint,
                    contactNormal: normal,
                    appliedImpulse: appliedNormalImpulse,
                    detachedPartMotions: detachedPartMotions
                )
                report.obstacleGaveWay = result.obstacleGaveWay
                return report
            }
        }

        let primaryStrength = max(0.5, Self.tierStrength(for: resolvedComponentID, graph: graph))
        let energyRatio = damageEnergy * damageFactor / primaryStrength

        if applyDamage, damageEnergy > 0.0001, damageFactor > 0.0 {
            let spreadRadius = 0.15 + 0.45 * min(1.0, energyRatio)
            damage = graph.applyImpact(
                primaryComponentID: resolvedComponentID,
                energyJ: damageEnergy,
                damageFactor: damageFactor,
                spreadRadius: spreadRadius,
                contactPointBody: contactBodyAtHit,
                elasticReserveScale: transmittedNormalEnergy / max(0.0001, damageEnergy),
                impulseBody: simd_act(orientation.conjugate, normal * candidateNormalImpulse - tangent * candidateFrictionImpulse)
            )
        }
        if applyDamage, isImpact {
            // A rigid-body contact (fuselage, gear, a pod, a rotor): the struck part's own
            // mount carries the contact force directly, and every other joint carries the
            // inertia of what hangs off it while the airframe decelerates.
            let conjugate = orientation.conjugate
            let impulseWorld = normal * candidateNormalImpulse - tangent * candidateFrictionImpulse
            var peakForceBody = simd_act(conjugate, impulseWorld) * (Float.pi / (2 * max(0.001, contactDuration)))
            var pulseDuration = contactDuration
            if let obstacleYield, simd_length(peakForceBody) > obstacleYield.force {
                // A yielding obstacle never pushes harder than it gives way at; the same impulse
                // is spread over a longer, gentler pulse.
                let scale = obstacleYield.force / simd_length(peakForceBody)
                peakForceBody *= scale
                pulseDuration = contactDuration / max(0.01, scale)
            }
            let lever = contactBodyAtHit - massProperties.centerOfMassOffset
            let inertia = simd_max(massProperties.inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
            var peakAcceleration = peakForceBody / mass
            var peakAngular = simd_cross(lever, peakForceBody) / inertia
            var history = StructuralAccelerationHistory.halfSine(peakLinear: peakAcceleration, peakAngular: peakAngular, duration: pulseDuration)
            if let bluntCrush {
                // A plateau at the crush force while the part folds, then the hard remainder.
                let direction = simd_length(impulseWorld) > 1e-6 ? simd_act(conjugate, impulseWorld) / simd_length(impulseWorld) : .zero
                let plateau = direction * bluntCrush.force
                history = StructuralAccelerationHistory()
                let samples = 24
                for index in 0...samples {
                    let t = bluntCrush.crushTime * Float(index) / Float(samples)
                    history.append(time: t, linear: plateau / mass, angular: simd_cross(lever, plateau) / inertia)
                }
                if bluntCrush.remainder > 0 {
                    let remainderPeak = direction * (bluntCrush.remainder * Float.pi / (2 * max(0.001, contactDuration)))
                    for index in 1...samples {
                        let t = contactDuration * Float(index) / Float(samples)
                        let shape = sin(Float.pi * t / contactDuration)
                        history.append(time: bluntCrush.crushTime + t, linear: remainderPeak * shape / mass,
                                       angular: simd_cross(lever, remainderPeak * shape) / inertia)
                    }
                }
                let remainderForce = direction * (bluntCrush.remainder * Float.pi / (2 * max(0.001, contactDuration)))
                peakForceBody = simd_length(remainderForce) > bluntCrush.force ? remainderForce : plateau
                peakAcceleration = plateau / mass
                peakAngular = simd_cross(lever, plateau) / inertia
            }
            _ = peakAcceleration; _ = peakAngular
            connectionDamage += Self.applyInertialShock(
                graph: &graph,
                massProperties: massProperties,
                history: history,
                excludedMember: nil,
                stationAccelerations: [:],
                directForce: StructuralPointForce(componentID: resolvedComponentID, pointBody: contactBodyAtHit,
                                                  forceBody: peakForceBody),
                preload: preload,
                thermalWeakening: thermalWeakening)
        } else if !isImpact, supportLoadNewtons > 0 || candidateFrictionImpulse > 0 {
            // Resting or sliding: a steady support force and friction, not a blow. They go to
            // the quasi-static structural check with the rest of this tick's loads; they must
            // not be replayed through the joints as a stream of small impacts.
            let conjugate = orientation.conjugate
            let frictionForce = -tangent * (candidateFrictionImpulse / max(0.0001, deltaTime))
            let support = normal * max(0, supportLoadNewtons)
            sustainedForces.append(StructuralPointForce(
                componentID: resolvedComponentID,
                pointBody: contactBodyAtHit,
                forceBody: simd_act(conjugate, support + frictionForce)))
        }

        let tier = Self.tier(forEnergyRatio: energyRatio, structuralFailure: connectionDamage.contains { $0.stateAfter != .attached })

        let newlyFailedRoots = graph.failedConnectionRootIDs.filter {
            !failedRootsBeforeImpact.contains($0)
        }

        // A contact that breaks its load path is no longer a collision of the
        // entire intact aircraft. Only the root's finite reaction reaches the
        // retained airframe; the remaining obstacle impulse stays with the
        // separating subtree. This prevents a wing-tip strike from making the
        // fuselage rebound like a single rigid ball.
        if let failedRootID = newlyFailedRoots.first(where: { rootID in
            graph.detachedSubtreePreview(rootComponentID: rootID)?
                .componentIDs.contains(resolvedComponentID) == true
        }),
           let part = graph.detachedSubtreePreview(rootComponentID: failedRootID),
           let rootConnection = graph.connection(childComponentID: failedRootID),
           let rootComponent = graph.component(id: failedRootID),
           let parentComponent = graph.component(id: rootConnection.parentComponentID) {
            // Fracture consumes the restitution part of the candidate impulse:
            // the detached piece may deflect, but the broken assembly does not
            // receive an elastic whole-aircraft rebound.
            let residualBefore = connectionDamage.first {
                $0.childComponentID == failedRootID
            }?.residualStrengthBefore ?? max(0.015, rootConnection.residualStrength)
            let normalBody = simd_act(orientation.conjugate, normal)
            let mountCapacity = jointImpulseCapacity(
                connection: rootConnection,
                parent: parentComponent,
                child: rootComponent,
                contactPointBody: contactBodyAtHit,
                impulseDirectionBody: normalBody,
                residualStrength: residualBefore,
                contactDuration: contactDuration
            )
            // The obstacle stops the part that broke away and, through its mount until the
            // mount let go, pushes on the rest. It cannot deliver more than that: the whole
            // aircraft's impulse applied to a one-kilogram gear leg sent it off at hundreds of
            // metres a second.
            let partStopping = max(0.005, part.massProperties.totalMassKg) * closing
            let fractureNormalImpulse = min(
                candidateNormalImpulse / max(1.0, 1.0 + restitution),
                partStopping + mountCapacity
            )
            let fractureFrictionImpulse = min(
                candidateFrictionImpulse,
                material.friction * fractureNormalImpulse
            )
            let obstacleImpulse = normal * fractureNormalImpulse -
                tangent * fractureFrictionImpulse
            appliedNormalImpulse = fractureNormalImpulse
            let transmissibleNormalImpulse = min(fractureNormalImpulse, mountCapacity)
            let transmissionFraction = (
                transmissibleNormalImpulse / max(0.0001, fractureNormalImpulse)
            )
            let clampedTransmissionFraction = min(1.0, max(0.0, transmissionFraction))
            let transmittedJointImpulse = normal * transmissibleNormalImpulse -
                tangent * (fractureFrictionImpulse * clampedTransmissionFraction)

            let jointBodyPoint = rootConnection.section?.anchor
                ?? (parentComponent.localPosition + rootComponent.localPosition) * 0.5
            let jointWorldPoint = bodyOriginAtHit + simd_act(orientation, jointBodyPoint)
            let retainedProperties = graph.massProperties(
                excludingComponentIDs: part.componentIDs
            )
            let retainedMass = max(0.2, retainedProperties.totalMassKg)
            let retainedCoMWorld = bodyOriginAtHit + simd_act(
                orientation,
                retainedProperties.centerOfMassOffset
            )
            // `state.velocity` is the CoM velocity in the impact solver. Move
            // it from the old combined CoM to the new retained CoM before
            // applying the limited joint reaction.
            state.velocity = incomingLinearVelocity +
                simd_cross(omegaWorld, retainedCoMWorld - worldCoM) +
                transmittedJointImpulse / retainedMass
            let retainedAngularDelta = angularVelocityDelta(
                leverArm: jointWorldPoint - retainedCoMWorld,
                impulse: transmittedJointImpulse,
                orientation: orientation,
                inertiaDiagonal: retainedProperties.inertiaDiagonal
            )
            applyWorldAngularDelta(
                retainedAngularDelta,
                state: &state,
                orientation: orientation,
                airframeClass: airframeClass
            )

            let partMass = max(0.005, part.massProperties.totalMassKg)
            let partCoMWorld = bodyOriginAtHit + simd_act(
                orientation,
                part.massProperties.centerOfMassOffset
            )
            let partInitialVelocity = incomingLinearVelocity +
                simd_cross(omegaWorld, partCoMWorld - worldCoM)
            let partNetImpulse = obstacleImpulse - transmittedJointImpulse
            let partContactAngularDelta = angularVelocityDelta(
                leverArm: contact.contactPoint - partCoMWorld,
                impulse: obstacleImpulse,
                orientation: orientation,
                inertiaDiagonal: part.massProperties.inertiaDiagonal
            )
            let partJointAngularDelta = angularVelocityDelta(
                leverArm: jointWorldPoint - partCoMWorld,
                impulse: -transmittedJointImpulse,
                orientation: orientation,
                inertiaDiagonal: part.massProperties.inertiaDiagonal
            )
            detachedPartMotions.append(
                ImpactDetachedPartMotion(
                    rootComponentID: failedRootID,
                    centerOfMassVelocityWorld: partInitialVelocity + partNetImpulse / partMass,
                    angularVelocityWorld: clampMagnitude(
                        omegaWorld + partContactAngularDelta + partJointAngularDelta,
                        limit: 35.0
                    ),
                    obstacleImpulseWorld: obstacleImpulse,
                    transmittedJointImpulseWorld: transmittedJointImpulse
                )
            )
        } else {
            let rigidImpulse = normal * candidateNormalImpulse -
                tangent * candidateFrictionImpulse
            state.velocity += rigidImpulse / mass
            // The support a resting contact gives is the engine's to apply, at the points that
            // touch and with its linear part (`applyGroundContactImpulses`). Adding its moment
            // here as well, without the force that makes it, turned a lying wreck by a torque
            // nothing balanced, a little every step, and kept it rolling.
            let rigidAngularDelta = angularVelocityDelta(
                leverArm: leverArm,
                impulse: rigidImpulse,
                orientation: orientation,
                inertiaDiagonal: massProperties.inertiaDiagonal
            )
            applyWorldAngularDelta(
                rigidAngularDelta,
                state: &state,
                orientation: orientation,
                airframeClass: airframeClass
            )
        }

        var report = ImpactReport(
            componentID: resolvedComponentID,
            obstacleID: contact.obstacle.id,
            obstacleSource: contact.obstacle.source,
            material: material,
            acousticSurface: acousticSurface,
            vehicleMaterial: Self.vehicleMaterial(
                componentID: resolvedComponentID,
                graph: graph,
                skin: skinMaterial
            ),
            impactEnergyJ: impactEnergy,
            normalClosingSpeed: normalClosingSpeed,
            tangentialSpeed: tangentialSpeed,
            tier: tier,
            damage: damage,
            connectionDamage: connectionDamage,
            contactPoint: contact.contactPoint,
            contactNormal: normal,
            appliedImpulse: appliedNormalImpulse,
            detachedPartMotions: detachedPartMotions
        )
        report.sustainedForces = sustainedForces
        report.obstacleGaveWay = rigidObstacleGaveWay
        if rigidObstacleGaveWay {
            state.position = statePositionAtHit + state.velocity * (1 - contact.hitFraction) * deltaTime
        }
        return report
    }

    // MARK: Structural helpers

    /// Coulomb friction of an airframe's skin sliding on the ground: 0.5–0.8 across the surfaces
    /// this file knows (soil 0.70, asphalt 0.82, grass lower). Where the ground's own material is
    /// not resolved, the soil figure is taken.
    static let groundSlidingFriction: Float = 0.7
    /// Rolling resistance of a wreck on the ground, as a fraction of its load times its rolling
    /// radius: an irregular deforming body on soil or turf runs 0.05–0.3 (a ball on turf
    /// 0.05–0.1, on sand ~0.3), and 0.1 is the soil figure.
    static let groundRollingResistance: Float = 0.1

    /// Ground contact of the airframe's own contact spheres, as impulses at the points that
    /// touch — the contact that holds a body on the ground, not the blow that brought it there.
    ///
    /// The clamp alone lifted the airframe onto its lowest point and zeroed its sinking speed,
    /// and that was all: nothing at the contact pushed back on the rotation or rubbed against
    /// the slide, and the impact solver only acts on points arriving faster than 0.35 m/s — the
    /// contact point of a rolling body hardly moves. A wreck therefore rolled over its corners
    /// like a wheel with no resistance: measured, a crashed eBee was still turning at 9 rad/s
    /// twenty seconds after it hit the runway.
    ///
    /// Each touching point gets the normal impulse that stops it sinking, through its lever to
    /// the centre of mass so that it acts on the rotation too, and Coulomb friction against its
    /// sliding, within the friction cone — sequential impulses, a few passes over the points.
    /// No restitution here: a real blow is resolved by `VehicleGroundContactSolver`, which puts
    /// the approach state back and solves the impact with its damage.
    static func applyGroundContactImpulses(
        velocity: inout SIMD3<Float>,
        rates: inout SIMD3<Float>,
        attitude: simd_quatf,
        normal: SIMD3<Float>,
        penetration: Float,
        spheres: [VehicleContactSphere],
        fallbackBoxes: [RotationalDragElement],
        centerOfMass: SIMD3<Float>,
        mass: Float,
        inertiaRateOrdered: SIMD3<Float>,
        log: Bool = false
    ) {
        guard !spheres.isEmpty, mass > 0 else { return }
        let com = centerOfMass
        var bottoms = spheres.map { sphere -> SIMD3<Float> in
            let local = simd_act(attitude, sphere.offset - com)
            return SIMD3<Float>(local.x, local.y - sphere.radius, local.z)
        }
        // A wreck stripped of its wings, arms and gear keeps their contact spheres no longer, and
        // what is left can be a single sphere on the body — a ball, which no contact can stop
        // turning. What is left is still a shape: the corners of the parts still attached carry
        // the aircraft instead. Measured on a heavy multirotor: one sphere left, flipping at
        // 6 rad/s twenty seconds after it hit the ground.
        if bottoms.count < 3, !fallbackBoxes.isEmpty {
            bottoms = fallbackBoxes.flatMap { element -> [SIMD3<Float>] in
                let h = element.halfExtents
                return [-1, 1].flatMap { x in [-1, 1].map { z -> SIMD3<Float> in
                    let corner = SIMD3<Float>(h.x * Float(x), -h.y, h.z * Float(z))
                    return simd_act(attitude, element.center + simd_act(element.rotation, corner) - com)
                } }
            }
        }
        guard let lowest = bottoms.map(\.y).min() else { return }
        let touching = bottoms.filter { $0.y <= lowest + max(0, penetration) + 0.005 }
        guard !touching.isEmpty else { return }

        let inertia = simd_max(SIMD3<Float>(inertiaRateOrdered.y, inertiaRateOrdered.z, inertiaRateOrdered.x),
                               SIMD3<Float>(repeating: 0.0005))
        let conjugate = attitude.conjugate
        var omega = simd_act(attitude, SIMD3<Float>(rates.y, rates.z, rates.x))
        func angular(_ lever: SIMD3<Float>, _ impulse: SIMD3<Float>) -> SIMD3<Float> {
            simd_act(attitude, simd_act(conjugate, simd_cross(lever, impulse)) / inertia)
        }
        func effectiveInverse(_ lever: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
            1 / mass + simd_dot(simd_cross(angular(lever, direction), lever), direction)
        }
        let up = simd_length_squared(normal) > 0.0001 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        var normalImpulse = [Float](repeating: 0, count: touching.count)
        var frictionImpulse = [SIMD3<Float>](repeating: .zero, count: touching.count)
        for _ in 0..<4 {
            for (index, lever) in touching.enumerated() {
                // Normal: the point may not sink; the accumulated push stays a push.
                let approach = simd_dot(velocity + simd_cross(omega, lever), up)
                let previous = normalImpulse[index]
                normalImpulse[index] = max(0, previous - approach / max(1e-6, effectiveInverse(lever, up)))
                let pushed = up * (normalImpulse[index] - previous)
                velocity += pushed / mass
                omega += angular(lever, pushed)

                // Friction: stop the slip, within μ times the push at this point.
                let contactVelocity = velocity + simd_cross(omega, lever)
                let slip = contactVelocity - up * simd_dot(contactVelocity, up)
                let slipSpeed = simd_length(slip)
                guard slipSpeed > 1e-5 else { continue }
                let direction = slip / slipSpeed
                let wanted = frictionImpulse[index] - direction * (slipSpeed / max(1e-6, effectiveInverse(lever, direction)))
                let limit = Self.groundSlidingFriction * normalImpulse[index]
                let clamped = simd_length(wanted) > limit ? wanted / simd_length(wanted) * limit : wanted
                let applied = clamped - frictionImpulse[index]
                frictionImpulse[index] = clamped
                velocity += applied / mass
                omega += angular(lever, applied)
            }
        }
        // Rolling and pivoting resistance. A wreck is not a wheel: its skin flattens and its
        // edges dig in, so turning over the ground costs work that a set of rigid spheres does
        // not charge — a fuselage stub was rolling along the runway like a bottle, 0.45 m/s for
        // twenty seconds. Rolling resistance of an irregular, deforming body on soil or grass
        // runs 0.05–0.3 of its load times its rolling radius (a ball on turf ~0.05–0.1, on sand
        // ~0.3); the soil figure 0.1 is taken. Pivoting about the normal is resisted by friction
        // over a contact patch taken as half the sphere's radius: (2/3)·μ·N·a.
        for (index, lever) in touching.enumerated() where normalImpulse[index] > 0 {
            let axisRoll = omega - up * simd_dot(omega, up)
            let spin = simd_dot(omega, up)
            let radius = simd_length(lever)
            var resisting = SIMD3<Float>.zero
            if simd_length(axisRoll) > 1e-5 {
                resisting -= simd_normalize(axisRoll) * (Self.groundRollingResistance * normalImpulse[index] * radius)
            }
            if abs(spin) > 1e-5 {
                let patch: Float = 0.5 * 0.05
                resisting -= up * (spin > 0 ? 1 : -1) * (2.0 / 3.0 * Self.groundSlidingFriction * normalImpulse[index] * patch)
            }
            guard simd_length_squared(resisting) > 0 else { continue }
            let delta = simd_act(attitude, simd_act(conjugate, resisting) / inertia)
            // Resistance stops a rotation; it never turns it the other way.
            let along = simd_dot(delta, omega) / max(1e-9, simd_length_squared(omega))
            omega += along < -1 ? delta / -along : delta
        }
        let body = simd_act(conjugate, omega)
        if log {
            print(String(format: "[GroundContact] pen=%.3f points=%d/%d ΣPn=%.1f |w| %.2f→%.2f v.y %.2f",
                         penetration, touching.count, spheres.count, normalImpulse.reduce(0, +),
                         simd_length(SIMD3<Float>(rates.y, rates.z, rates.x)), simd_length(omega), velocity.y))
        }
        rates = SIMD3<Float>(body.z, body.x, body.y)
    }

    /// Restitution of a blow at this closing speed.
    ///
    /// The material's figure is a bounce at a few metres a second. Harder than that, more of the
    /// contact goes plastic and less comes back: for elastic–plastic impact `e` falls as
    /// `(v_y/v)^¼` once the closing speed is well past first yield (Johnson, *Contact
    /// Mechanics*, §11.4). Taking the table figure as holding at 3 m/s, a 55 m/s dive into
    /// asphalt comes back at 0.12 of its speed rather than 0.24 — the difference between a
    /// wreck that stays down and one that was thrown seven metres into the air.
    static func impactRestitution(material: ImpactSurfaceMaterial, closingSpeed: Float) -> Float {
        let reference: Float = 3
        guard closingSpeed > reference else { return material.restitution }
        return material.restitution * pow(reference / closingSpeed, 0.25)
    }

    /// Severity tier. A structural failure is at least a heavy impact whatever the energy.
    static func tier(forEnergyRatio ratio: Float, structuralFailure: Bool) -> ImpactOutcomeTier {
        let byEnergy: ImpactOutcomeTier
        switch ratio {
        case ..<0.05: byEnergy = .lightTouch
        case ..<0.30: byEnergy = .scrape
        case ..<1.00: byEnergy = .heavyImpact
        default: byEnergy = .criticalImpact
        }
        guard structuralFailure else { return byEnergy }
        return byEnergy == .criticalImpact ? .criticalImpact : .heavyImpact
    }

    /// How hard a struck station can be pushed before it crushes locally, and how far it can
    /// crush before the obstacle is through it. The crushed face is the station's cross-
    /// section seen along the contact normal, as wide as the obstacle where the obstacle is
    /// narrower than the station (a pole, a trunk) and the whole station otherwise (a wall,
    /// the ground). A soft obstacle crushes less of the aircraft: the force scales with its
    /// hardness.
    static func crushLimits(
        station: String,
        normalBody: SIMD3<Float>,
        obstacle: CollisionObstacle,
        material: ImpactSurfaceMaterial,
        graph: VehicleComponentGraph
    ) -> (force: Float, depth: Float) {
        guard let component = graph.component(id: station),
              let section = graph.connection(childComponentID: station)?.section else {
            return (.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        }
        let span = abs(simd_dot(normalBody, section.spanAxis))
        let flap = abs(simd_dot(normalBody, section.normalAxis))
        let chordwise = abs(simd_dot(normalBody, section.chordAxis))
        let half = component.boundingHalfExtents
        // Station extents along its own axes.
        let length = 2 * abs(simd_dot(component.localPosition - section.anchor, section.spanAxis))
        let chord = 2 * simd_length(half * simd_abs(section.chordAxis))
        let depth = 2 * simd_length(half * simd_abs(section.normalAxis))
        let isBroad = obstacle.meshTriangles != nil || obstacle.planarFootprint != nil
            || obstacle.planarHalfExtents != nil || obstacle.radius > 50
        let source = obstacle.source.lowercased()
        let trunkFraction: Float = source.contains("tree") && !source.contains("branch") ? 0.3 : 1
        let obstacleWidth = isBroad ? Float.greatestFiniteMagnitude : max(0.01, 2 * obstacle.radius * trunkFraction)
        let width = min(obstacleWidth, max(0.005, length))
        // Face seen along the normal: a leading-edge strike crushes depth × width, a strike
        // on the skin crushes chord × width, an end-on strike the whole cross-section.
        let face = chordwise * depth * width + flap * chord * width + span * chord * depth
        let through = chordwise * chord + flap * depth + span * max(0.005, length)
        let hardness = max(0.15, material.hardness)
        let force = section.material.crushStrengthPa * max(1e-6, face) * hardness
        // Whichever gives first decides: a skin weaker than the section crushes, a section
        // weaker than the skin breaks in shear — the solver checks the latter itself.
        return (force, max(0.002, through))
    }

    /// Crush force and crushable depth of a part that is not a slender member, struck along
    /// `normalBody`: the airframe's crushing pressure over the face the obstacle meets — the
    /// part's whole shadow along the blow for a broad obstacle, a strip of the obstacle's own
    /// width across it for a pole or a stem — and the part's depth along the blow. Propellers,
    /// landing gear and motors are excluded: a blade breaks, a gear leg strokes, and a motor is
    /// a lump of metal on a mount that the mount decides about.
    static func bluntCrushLimit(
        part: VehicleComponent,
        normalBody: SIMD3<Float>,
        obstacle: CollisionObstacle,
        material: ImpactSurfaceMaterial,
        graph: VehicleComponentGraph
    ) -> (force: Float, depth: Float)? {
        switch part.kind {
        case .propeller, .landingGear, .motor: return nil
        default: break
        }
        guard let structure = graph.connection(childComponentID: part.id)?.section?.material
                ?? graph.structuralConnections.lazy.compactMap({ $0.section?.material }).first else { return nil }
        let h = part.boundingHalfExtents
        let n = simd_abs(normalBody)
        let depth = 2 * (h.x * n.x + h.y * n.y + h.z * n.z)
        let shadow = 4 * (h.y * h.z * n.x + h.x * h.z * n.y + h.x * h.y * n.z)
        let isBroad = obstacle.meshTriangles != nil || obstacle.planarFootprint != nil
            || obstacle.planarHalfExtents != nil || obstacle.radius > 50
        let face = isBroad ? shadow : min(shadow, 2 * max(0.005, obstacle.radius) * shadow.squareRoot())
        let force = structure.crushStrengthPa * max(1e-6, face) * max(0.15, material.hardness)
        return (force, max(0.005, depth))
    }

    /// The energy scale an impact on this part is judged against. A wing station is a
    /// twelfth of a wing; grading a blow against one station alone would call every brush a
    /// critical impact, so a member is graded as the whole member.
    static func tierStrength(for componentID: String, graph: VehicleComponentGraph) -> Float {
        guard let member = memberStation(containing: componentID, graph: graph) else {
            return graph.component(id: componentID)?.strengthJ ?? 40
        }
        return member.stations.reduce(Float(0)) { $0 + (graph.component(id: $1)?.strengthJ ?? 0) }
    }

    /// The member station a part belongs to — itself, or the station it is mounted on —
    /// with the member's whole chain and the station's place in it.
    static func memberStation(containing componentID: String, graph: VehicleComponentGraph)
        -> (memberID: String, stations: [String], index: Int)? {
        var cursor = graph.component(id: componentID)
        var depth = 0
        while let current = cursor, depth < 64 {
            if let section = graph.connection(childComponentID: current.id)?.section,
               section.isMemberStation, !section.memberID.isEmpty {
                let chain = graph.memberChains[section.memberID] ?? []
                // Only the attached part of the chain up to the first separation takes part.
                let attached = chain.prefix { graph.component(id: $0)?.isAttached == true }
                guard let index = attached.firstIndex(of: current.id) else { return nil }
                return (section.memberID, Array(attached), index)
            }
            cursor = current.parentID.flatMap { graph.component(id: $0) }
            depth += 1
        }
        return nil
    }

    /// Joint loads of an aircraft at rest under its own weight, attitude as given — the
    /// preload an impact adds to when the flight solver has not supplied one.
    static func restingPreload(
        graph: VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        orientation: simd_quatf
    ) -> [String: VehicleJointLoad] {
        let up = simd_act(orientation.conjugate, SIMD3<Float>(0, 9.81, 0))
        return StructuralLoadField.jointLoads(
            graph: graph,
            loadCase: StructuralLoadCase(specificForceBody: up, centerOfMass: massProperties.centerOfMassOffset))
    }

    /// Joint loads of an aircraft in steady 1 g flight: lift on the horizontal lifting
    /// surfaces by area (multirotors: thrust at every motor), weight everywhere.
    static func flightPreload(
        graph: VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        orientation: simd_quatf
    ) -> [String: VehicleJointLoad] {
        let weight = massProperties.totalMassKg * 9.81
        var forces: [StructuralPointForce] = []
        let transforms = graph.deformationTransforms()
        func position(_ component: VehicleComponent) -> SIMD3<Float> {
            let p = (transforms[component.id] ?? matrix_identity_float4x4) * SIMD4<Float>(component.localPosition, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        let lifting = graph.attachedComponents.filter {
            switch $0.kind {
            case .wingSection, .horizontalTail: return true
            default: return false
            }
        }
        let area = lifting.reduce(Float(0)) { $0 + ($1.liftingSurface?.area ?? 0) }
        if area > 0.0001 {
            for component in lifting {
                let share = (component.liftingSurface?.area ?? 0) / area
                forces.append(StructuralPointForce(componentID: component.id, pointBody: position(component),
                                                   forceBody: SIMD3<Float>(0, weight * share, 0)))
            }
        } else {
            let motors = graph.attachedComponents.filter { if case .motor = $0.kind { return true }; return false }
            for motor in motors {
                forces.append(StructuralPointForce(componentID: motor.id, pointBody: position(motor),
                                                   forceBody: SIMD3<Float>(0, weight / Float(max(1, motors.count)), 0)))
            }
        }
        return StructuralLoadField.jointLoads(
            graph: graph,
            loadCase: StructuralLoadCase(specificForceBody: SIMD3<Float>(0, 9.81, 0),
                                         centerOfMass: massProperties.centerOfMassOffset,
                                         pointForces: forces),
            transforms: transforms)
    }

    /// Checks every joint against the inertia of what hangs off it during an impact pulse,
    /// plus the contact force on the struck part itself, and applies the outcomes. A hard
    /// landing folds wings down here; a gear strike tears the gear leg off here.
    /// Natural period of an equipment mount or small attachment (motor, gimbal, gear leg):
    /// such mounts sit at 50–200 Hz, so they follow any impact pulse almost exactly.
    static let attachmentPeriod: Float = 0.01

    static func applyInertialShock(
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        history: StructuralAccelerationHistory,
        excludedMember: String?,
        stationAccelerations: [String: SIMD3<Float>],
        directForce: StructuralPointForce?,
        preload: [String: VehicleJointLoad],
        thermalWeakening: Float
    ) -> [VehicleComponentGraph.ConnectionDamageEntry] {
        let attachment = history.shockResponse(period: attachmentPeriod, damping: 0.05)
        guard simd_length(attachment.linear) > 0.5 || directForce != nil else { return [] }
        // Each member responds to the retained body's deceleration through its own
        // dynamics: its shock response at its own first bending period.
        var impulsive: [String: (linear: SIMD3<Float>, angular: SIMD3<Float>)] = ["*": attachment]
        let chains = graph.memberChains
        for (memberID, stations) in chains where memberID != excludedMember {
            let period = firstBendingPeriod(stations: stations, graph: graph)
            let damping = graph.connection(childComponentID: stations.first ?? "")?.section?.material.dampingRatio ?? 0.02
            impulsive[memberID] = history.shockResponse(period: period, damping: damping)
        }
        // Each part must be given the retained body's acceleration during the pulse; the
        // joint above it supplies that, and bends accordingly.
        var loadCase = StructuralLoadCase(specificForceBody: .zero, centerOfMass: massProperties.centerOfMassOffset)
        loadCase.impulsive = impulsive
        if let excludedMember { loadCase.excludedMembers = [excludedMember] }
        if let directForce { loadCase.pointForces = [directForce] }
        let transforms = graph.deformationTransforms()
        let pulseLoads = StructuralLoadField.jointLoads(graph: graph, loadCase: loadCase, transforms: transforms)
        var entries: [VehicleComponentGraph.ConnectionDamageEntry] = []
        let stations = Set(chains.values.flatMap { $0 })
        let subtrees = graph.subtreeMass(transforms: transforms)
        // Parts on the struck part's line of ancestry carry the contact force directly.
        var loadPath: Set<String> = []
        var cursor = directForce.flatMap { graph.component(id: $0.componentID) }
        while let current = cursor, loadPath.insert(current.id).inserted {
            cursor = current.parentID.flatMap { graph.component(id: $0) }
        }
        var periodResponses: [Int: (linear: SIMD3<Float>, angular: SIMD3<Float>)] = [:]
        for connection in graph.structuralConnections where connection.state != .detached {
            guard var load = pulseLoads[connection.childComponentID],
                  let child = graph.component(id: connection.childComponentID), child.isAttached,
                  let section = connection.section else { continue }
            if !section.isMemberStation {
                // An attachment (battery, gimbal, motor, control surface, gear leg) rides its
                // own mount: a spring of its own stiffness carrying its own mass. It sees the
                // shock at its own period — the base being the station it sits on when that
                // station was the one struck, the fuselage otherwise.
                let subtree = subtrees[child.id]
                let mass = max(0.001, subtree?.mass ?? child.massKg)
                let center = subtree?.center ?? child.localPosition
                let parentTransform = transforms[connection.parentComponentID] ?? matrix_identity_float4x4
                let a4 = parentTransform * SIMD4<Float>(section.anchor, 1)
                let anchor = SIMD3<Float>(a4.x, a4.y, a4.z)
                let stiffness = max(1, min(section.shearStiffness, section.axialStiffness) * connection.stiffnessScale)
                let period = 2 * Float.pi * (mass / stiffness).squareRoot()
                let base: SIMD3<Float>
                if let parentStation = stationAccelerations[connection.parentComponentID] {
                    base = parentStation
                } else {
                    // Periods bucketed to 5 % so neighbouring mounts share one response.
                    let bucket = Int((log(max(1e-5, period)) / log(1.05)).rounded())
                    let response = periodResponses[bucket] ?? history.shockResponse(period: period, damping: 0.05)
                    periodResponses[bucket] = response
                    base = response.linear + simd_cross(response.angular, center - massProperties.centerOfMassOffset)
                }
                var force = base * mass
                var moment = simd_cross(center - anchor, base * mass)
                if let directForce, loadPath.contains(child.id) {
                    force -= directForce.forceBody
                    moment -= simd_cross(directForce.pointBody - anchor, directForce.forceBody)
                }
                load = section.localLoad(force: force, moment: moment)
            } else if stations.contains(connection.childComponentID) == false {
                continue
            }
            let total = load + (preload[connection.childComponentID] ?? .zero)
            guard let outcome = StructuralJointResponse.evaluate(
                connection: connection,
                currentRotation: child.deformation.bendRadians,
                load: total,
                thermalWeakening: thermalWeakening) else { continue }

            if let entry = graph.applyJointOutcome(
                childComponentID: connection.childComponentID,
                plasticRotationBody: outcome.plasticRotationBody,
                plasticRotationSpent: outcome.plasticRotationSpent,
                residualStrength: outcome.residualStrength,
                stiffnessScale: outcome.stiffnessScale,
                fracture: outcome.fracture) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// First bending period of a member as a uniform cantilever from its root section:
    /// ω₁ = 1.875²·√(EI/(m·L³)), with EI from the root joint spring times its station length.
    static func firstBendingPeriod(stations: [String], graph: VehicleComponentGraph) -> Float {
        guard let first = stations.first, let root = graph.connection(childComponentID: first)?.section else { return 0.05 }
        var span: Float = 0
        var mass: Float = 0
        for id in stations {
            guard let component = graph.component(id: id),
                  let section = graph.connection(childComponentID: id)?.section else { continue }
            span += 2 * abs(simd_dot(component.localPosition - section.anchor, section.spanAxis))
            mass += component.massKg
        }
        let firstLength = 2 * abs(simd_dot((graph.component(id: first)?.localPosition ?? root.anchor) - root.anchor, root.spanAxis))
        let bending = root.flapStiffness * max(0.005, firstLength)
        let omega = 3.516 * (bending / max(1e-6, mass * pow(max(0.01, span), 3))).squareRoot()
        return 2 * Float.pi / max(0.1, omega)
    }

    /// Static-penetration variant for contacts the sweep didn't catch (slow
    /// push into a wall detected by the analyzer): positional push-out along
    /// the normal plus the same impulse/damage math, driven by the current
    /// velocity instead of a swept hit.
    func resolvePenetration(
        penetrationDepth: Float,
        contactNormal: SIMD3<Float>,
        contactPoint: SIMD3<Float>,
        obstacle: CollisionObstacle,
        componentID: String,
        sphereRadius: Float,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        bodyOriginWorldOffset: SIMD3<Float> = .zero,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool = true,
        restingSpeedThreshold: Float = 0.01,
        skinMaterial: UAVSkinMaterial = .aluminium
    ) -> ImpactReport {
        let normal = simd_normalize(contactNormal)
        state.position += normal * (max(0.0, penetrationDepth) + max(0.005, sphereRadius * 0.04))

        let syntheticContact = VehicleSweptContact(
            obstacle: obstacle,
            componentID: componentID,
            contactPoint: contactPoint,
            contactNormal: normal,
            hitFraction: 1.0,
            isSupportSurfaceContact: false,
            sphereOffset: .zero,
            sphereRadius: sphereRadius
        )
        return resolve(
            contact: syntheticContact,
            previousPosition: state.position,
            state: &state,
            graph: &graph,
            massProperties: massProperties,
            airframeClass: airframeClass,
            bodyOriginWorldOffset: bodyOriginWorldOffset,
            rotorsSpinning: rotorsSpinning,
            deltaTime: deltaTime,
            applyDamage: applyDamage,
            restingSpeedThreshold: restingSpeedThreshold,
            skinMaterial: skinMaterial
        )
    }

    // MARK: Foliage

    /// One part of the aircraft as the crown sees it: its box, where it sits, which way it faces.
    fileprivate struct CrownPartBox {
        let id: String
        let local: SIMD3<Float>
        let rotation: simd_quatf
        let half: SIMD3<Float>
    }

    /// Fine fuel — needles and shoots under 6 mm — per cubic metre *inside* a conifer crown.
    ///
    /// Not the fire-science canopy bulk density (0.05–0.3 kg/m³): that is averaged over a whole
    /// stand, gaps between the crowns included, and taking it for the inside of one crown made
    /// flying into a tree a light breeze. Inside the crown it is the tree's own foliage over
    /// its own volume: a 15–18 m pine carries about 30 kg of fresh needles and 15 kg of fine
    /// shoots (biomass allometry for Scots pine at 30 cm DBH) in some 50 m³ of crown.
    static let canopyBulkDensity: Float = 0.9

    /// Flying through a tree's crown.
    ///
    /// Two things are in there, and they act differently. The wood — the stem and every
    /// branch and lateral off it, `TreeCrownStructure` — is struck: the first branch any part
    /// of the aircraft reaches this step is resolved as an impact through the same solvers as
    /// a pole or a wall, except that the branch is a tapered green-wood cantilever that bends,
    /// and gives way at its breaking load. A twig bends clear or snaps and costs the aircraft
    /// almost nothing; a 5 cm limb stops a small wing or breaks it; the stem does not give.
    /// A snapped branch stays snapped.
    ///
    /// The needles and fine twigs are the other thing, and they are swept, not struck: every
    /// part inside the crown has to push its own swept volume of that fuel out of the way,
    /// which is a snow-plough momentum loss, `ρ·A·|v|·v` on its shadow area at its own velocity.
    /// It depends on the aircraft's size and speed and not on its mass, so a heavy aircraft is
    /// slowed less — the old flat `exp(−2.8·dt)` stopped a 5-tonne and a 1-kilogram aircraft
    /// alike — and a wing in the crown on one side yaws the aircraft toward it.
    ///
    /// A spinning propeller in the crown also chews through the fine fuel, which nicks it.
    private func resolveFoliageContact(
        contact: VehicleSweptContact,
        material: ImpactSurfaceMaterial,
        acousticSurface: AcousticSurfaceMaterial,
        skinMaterial: UAVSkinMaterial,
        previousPosition: SIMD3<Float>,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        bodyOriginWorldOffset: SIMD3<Float>,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool,
        jointPreload: [String: VehicleJointLoad]?,
        thermalWeakening: Float
    ) -> ImpactReport {
        if let report = resolveCrownPassage(
            canopy: contact.obstacle, previousPosition: previousPosition, state: &state, graph: &graph,
            massProperties: massProperties, airframeClass: airframeClass,
            bodyOriginWorldOffset: bodyOriginWorldOffset, rotorsSpinning: rotorsSpinning,
            deltaTime: deltaTime, skinMaterial: skinMaterial, applyDamage: applyDamage,
            jointPreload: jointPreload, thermalWeakening: thermalWeakening, reportEntry: true) {
            return report
        }
        return ImpactReport(
            componentID: contact.componentID, obstacleID: contact.obstacle.id,
            obstacleSource: contact.obstacle.source, material: material, acousticSurface: acousticSurface,
            vehicleMaterial: Self.vehicleMaterial(componentID: contact.componentID, graph: graph, skin: skinMaterial),
            impactEnergyJ: 0, normalClosingSpeed: simd_length(state.velocity), tangentialSpeed: 0,
            tier: .lightTouch, damage: [], connectionDamage: [], contactPoint: contact.contactPoint,
            contactNormal: contact.contactNormal, appliedImpulse: 0, detachedPartMotions: [])
    }

    /// Whether an obstacle is a tree's crown, which the aircraft is inside of for as long as any
    /// part of it is — not only on the step it crosses the crown's surface.
    static func isTreeCrown(_ obstacle: CollisionObstacle) -> Bool {
        let source = obstacle.source.lowercased()
        if source.contains("canopy") { return true }
        return source.contains("tree") && !source.contains("trunk") && !source.contains("branch")
    }

    /// A tree's separate trunk box. Its crown models the whole stem as wood, so the box stays
    /// with navigation and is not a contact surface of its own — two descriptions of one trunk
    /// would strike the aircraft twice.
    static func isTreeTrunkProxy(_ obstacle: CollisionObstacle) -> Bool {
        obstacle.source.lowercased() == "tree.trunk"
    }

    /// One step of the aircraft in (or entering) a tree's crown; nil when no part of it is.
    ///
    /// Called every step, because a crown is not a surface: the aircraft meets branches all the
    /// way through it. Returns a report when something happened — a branch struck, the crown
    /// entered (for the sound of it), a propeller nicked — and nothing on a quiet step inside,
    /// where the fine fuel's drag is all there is.
    func resolveCrownPassage(
        canopy: CollisionObstacle,
        previousPosition: SIMD3<Float>,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        bodyOriginWorldOffset: SIMD3<Float> = .zero,
        rotorsSpinning: Bool,
        deltaTime: Float,
        skinMaterial: UAVSkinMaterial = .aluminium,
        applyDamage: Bool = true,
        jointPreload: [String: VehicleJointLoad]? = nil,
        thermalWeakening: Float = 0,
        reportEntry: Bool = false
    ) -> ImpactReport? {
        let orientation = attitudeQuaternion(state: state, airframeClass: airframeClass)
        let originNow = state.position + bodyOriginWorldOffset
        let originBefore = previousPosition + bodyOriginWorldOffset
        // Broad phase: the aircraft's reach against the tree — crown and the stem under it —
        // over the step.
        let halfWidth: Float = canopy.planarHalfExtents.map { simd_length($0) } ?? canopy.radius
        let reach = graph.attachedComponents.reduce(Float(0)) {
            max($0, simd_length($1.localPosition) + simd_length($1.boundingHalfExtents))
        } + simd_distance(originNow, originBefore)
        let planar = simd_distance(SIMD2<Float>(originNow.x, originNow.z), SIMD2<Float>(canopy.center.x, canopy.center.z))
        let crownHeight = max(0.5, canopy.topY - canopy.baseY)
        let groundGuess = canopy.topY - crownHeight / 0.6
        guard planar <= halfWidth + reach,
              max(originNow.y, originBefore.y) + reach >= groundGuess,
              min(originNow.y, originBefore.y) - reach <= canopy.topY else { return nil }

        let crown = TreeCrownStructure.build(canopy: canopy)
        let registry = TreeBranchRegistry.shared
        let transforms = graph.deformationTransforms()
        let parts: [CrownPartBox] = graph.attachedComponents.compactMap { component in
            let half = component.boundingHalfExtents
            guard half.x + half.y + half.z > 0.01 else { return nil }
            // What a branch can reach is the outside of the aircraft: its structure and the
            // pods hung off it. A battery or a flight controller is struck through the skin
            // around it, not directly.
            switch component.kind {
            case .battery, .flightController, .esc, .radio: return nil
            default: break
            }
            let transform = transforms[component.id] ?? matrix_identity_float4x4
            let p = transform * SIMD4<Float>(component.localPosition, 1)
            return CrownPartBox(id: component.id, local: SIMD3<Float>(p.x, p.y, p.z),
                                rotation: orientation * simd_quatf(transform), half: half)
        }
        let material = ImpactSurfaceMaterial.foliage
        let acousticSurface = Self.acousticSurface(for: canopy, contactPoint: canopy.center, physicalMaterial: material)

        // The wood: the first branch any part reaches this step.
        var strike: (crossing: TreeCrownStructure.Crossing, part: CrownPartBox)?
        for part in parts {
            let now = originNow + simd_act(orientation, part.local)
            let before = originBefore + simd_act(orientation, part.local)
            if let crossing = crown.firstCrossing(from: before, to: now, orientation: part.rotation,
                                                  halfExtents: part.half, isBroken: registry.isBroken),
               strike == nil || crossing.t < strike!.crossing.t {
                strike = (crossing, part)
            }
        }
        if applyDamage, let strike {
            let branch = strike.crossing.branch
            let mechanics = branch.mechanics(at: strike.crossing.s)
            // Past about 22° of bend (a deflection of 0.4 of its lever) a branch no longer
            // resists the part pushing it — it slides off round it. One whose breaking
            // deflection comes first snaps, after bending as far again as green wood does
            // before its fibres let go (Wood Handbook: the total work of a green softwood in
            // bending is 1–2 × its load × deflection at maximum load).
            let breakingDeflection = mechanics.breakingForce / max(1, mechanics.stiffness)
            let clearance = 0.4 * mechanics.lever
            let breaks = 2 * breakingDeflection <= clearance
            let yieldForce = mechanics.breakingForce
            let stroke = breakingDeflection
            let diameter = branch.diameter(at: strike.crossing.s)
            let branchPoint = branch.point(at: strike.crossing.s)
            let axis = simd_normalize(branch.end - branch.start)
            let omega = worldAngularVelocity(state: state, orientation: orientation, airframeClass: airframeClass)
            let lever = strike.crossing.pointWorld - (originNow + simd_act(orientation, massProperties.centerOfMassOffset))
            let partVelocity = state.velocity + simd_cross(omega, lever)
            let across = partVelocity - axis * simd_dot(partVelocity, axis)
            let normal = simd_length(across) > 1e-4 ? -simd_normalize(across)
                : (simd_length(partVelocity) > 1e-4 ? -simd_normalize(partVelocity) : SIMD3<Float>(0, 1, 0))
            let obstacle = CollisionObstacle(
                id: canopy.id, center: branchPoint, radius: diameter * 0.5, source: "tree.branch",
                acousticSurface: diameter < 0.03 ? .foliage : .treeTrunk)
            let branchContact = VehicleSweptContact(
                obstacle: obstacle, componentID: strike.part.id, contactPoint: strike.crossing.pointWorld,
                contactNormal: normal, hitFraction: strike.crossing.t, isSupportSurfaceContact: false,
                sphereOffset: strike.part.local,
                sphereRadius: max(0.005, min(strike.part.half.x, strike.part.half.y, strike.part.half.z)))
            let report = resolve(
                contact: branchContact, previousPosition: previousPosition, state: &state, graph: &graph,
                massProperties: massProperties, airframeClass: airframeClass,
                bodyOriginWorldOffset: bodyOriginWorldOffset, rotorsSpinning: rotorsSpinning,
                deltaTime: deltaTime, applyDamage: true, skinMaterial: skinMaterial,
                jointPreload: jointPreload, thermalWeakening: thermalWeakening,
                obstacleYield: ObstacleYield(force: yieldForce, stroke: stroke,
                                             stiffness: mechanics.stiffness, breaks: breaks,
                                             mass: branch.effectiveMass(at: strike.crossing.s),
                                             clearance: clearance))
            if report.obstacleGaveWay && breaks { registry.markBroken(branch.key) }
            #if DEBUG
            // Only what matters: a twig brushed every step would bury the log.
            if report.appliedImpulse >= 0.5 || report.tier != .lightTouch || !report.connectionDamage.isEmpty {
            print(String(format: "[Tree] %@ struck %@ d=%.1fcm breaks@%.0fN mass=%.2fkg at %.1fm/s → impulse %.1fN·s, %@, %@, joints %d, parts %d",
                         strike.part.id, branch.key.index == 0 ? "stem" : "branch", diameter * 100, yieldForce,
                         branch.effectiveMass(at: strike.crossing.s), simd_length(partVelocity), report.appliedImpulse,
                         report.obstacleGaveWay ? (breaks ? "snapped" : "pushed aside") : "held",
                         "\(report.tier)", report.connectionDamage.count, report.damage.count))
            }
            #endif
            _ = sweepFineFuel(crown: canopy, parts: parts, orientation: orientation,
                              origin: state.position + bodyOriginWorldOffset, state: &state,
                              massProperties: massProperties, airframeClass: airframeClass, deltaTime: deltaTime)
            return report
        }

        let speed = simd_length(state.velocity)
        let insideBefore = partsInside(crown: canopy, parts: parts, orientation: orientation, origin: originBefore)
        let inside = sweepFineFuel(crown: canopy, parts: parts, orientation: orientation,
                                   origin: originNow, state: &state, massProperties: massProperties,
                                   airframeClass: airframeClass, deltaTime: deltaTime)
        guard !inside.isEmpty else { return nil }

        var damage: [VehicleComponentGraph.ImpactDamageEntry] = []
        var worstPart: (id: String, energy: Float)?
        if applyDamage {
            // The fine shoots every part advances into strike it: a third of the crown's fine
            // fuel is shoot rather than needle (fire-science fuel classes), taken as 4 mm green
            // wood, and each crossing hands the part the kinetic energy of the length of shoot
            // it meets — its own thickness across it — brought up to the part's speed. That
            // gouges a leading edge and nicks a blade; a spinning blade meets it at three
            // quarters of its tip speed. Wood thicker than this is struck explicitly above.
            let twigArea = Float.pi * 0.002 * 0.002
            let twigLengthDensity = Self.canopyBulkDensity / 3 / (TreeCrownStructure.greenDensity * twigArea)
            let omega = worldAngularVelocity(state: state, orientation: orientation, airframeClass: airframeClass)
            let com = originNow + simd_act(orientation, massProperties.centerOfMassOffset)
            for part in parts where inside.contains(part.id) {
                guard let component = graph.component(id: part.id) else { continue }
                let center = originNow + simd_act(orientation, part.local)
                let velocity = state.velocity + simd_cross(omega, center - com)
                let partSpeed = simd_length(velocity)
                guard partSpeed > 0.3 else { continue }
                let h = part.half
                let direction = simd_act(part.rotation.conjugate, velocity / partSpeed)
                let shadow = 4 * (h.y * h.z * abs(direction.x) + h.x * h.z * abs(direction.y) + h.x * h.y * abs(direction.z))
                var impactSpeed = partSpeed
                var contactLength = min(0.1, 2 * min(h.x, h.y, h.z))
                var sweptArea = shadow
                if rotorsSpinning, isPropellerComponent(part.id, graph: graph) {
                    let radius = max(h.x, h.z)
                    let lane: Int? = { if case .propeller(let slot) = component.kind { return VehicleRotor.laneIndex(forSlot: slot) }; return nil }()
                    let shaft = lane.map { abs(state.rotorAngularSpeed[$0]) } ?? state.motorThrottle * 600
                    impactSpeed = max(partSpeed, 0.75 * shaft * radius)
                    contactLength = max(0.01, 0.2 * radius)
                    sweptArea = Float.pi * radius * radius
                }
                let crossings = twigLengthDensity * sweptArea * partSpeed * deltaTime
                let energy = crossings * 0.5 * TreeCrownStructure.greenDensity * twigArea * contactLength * impactSpeed * impactSpeed
                guard energy > 1e-4 else { continue }
                damage += graph.applyImpact(primaryComponentID: part.id, energyJ: energy,
                                            damageFactor: 0.35, spreadRadius: 0.05)
                if worstPart == nil || energy > worstPart!.energy { worstPart = (part.id, energy) }
            }
        }
        let spinningProps = inside.filter { isPropellerComponent($0, graph: graph) }
        let entered = insideBefore.isEmpty
        #if DEBUG
        if entered {
            print(String(format: "[Tree] entered crown of %@ at %.1fm/s: %d parts inside, %d branches in the tree",
                         canopy.source, speed, inside.count, crown.branches.count))
        }
        #endif
        guard entered && reportEntry || entered || !damage.isEmpty else { return nil }
        let componentID = worstPart?.id ?? spinningProps.first ?? inside[0]
        let point = originNow + simd_act(orientation, parts.first { $0.id == componentID }?.local ?? .zero)
        return ImpactReport(
            componentID: componentID,
            obstacleID: canopy.id,
            obstacleSource: canopy.source,
            material: material,
            acousticSurface: acousticSurface,
            vehicleMaterial: Self.vehicleMaterial(componentID: componentID, graph: graph, skin: skinMaterial),
            // Abrasion, not a blow: it wears the parts it reports, and is not logged as an impact
            // on every step the aircraft spends in the crown.
            impactEnergyJ: 0,
            normalClosingSpeed: speed,
            // Brushing through a canopy is not a slide against anything: the branches move.
            tangentialSpeed: 0.0,
            tier: .lightTouch,
            damage: damage,
            connectionDamage: [],
            contactPoint: point,
            contactNormal: speed > 1e-4 ? -state.velocity / speed : SIMD3<Float>(0, 1, 0),
            appliedImpulse: 0.0,
            detachedPartMotions: []
        )
    }

    /// Parts whose centre is inside the crown: a cone standing on the crown's base, as wide
    /// as its box there and coming to a point at its top.
    private func partsInside(crown: CollisionObstacle, parts: [CrownPartBox], orientation: simd_quatf,
                             origin: SIMD3<Float>) -> [String] {
        let axis = SIMD2<Float>(crown.center.x, crown.center.z)
        let radius: Float = crown.planarHalfExtents.map { min($0.x, $0.y) } ?? crown.radius
        return parts.compactMap { part in
            let center = origin + simd_act(orientation, part.local)
            guard center.y >= crown.baseY, center.y <= crown.topY else { return nil }
            let heightFraction = (center.y - crown.baseY) / max(0.1, crown.topY - crown.baseY)
            return simd_distance(SIMD2<Float>(center.x, center.z), axis) <= radius * (1 - heightFraction) ? part.id : nil
        }
    }

    /// The needles and fine twigs every part inside the crown pushes aside this step. Returns
    /// the parts that were inside.
    @discardableResult
    private func sweepFineFuel(
        crown: CollisionObstacle,
        parts: [CrownPartBox],
        orientation: simd_quatf,
        origin: SIMD3<Float>,
        state: inout DroneState,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        deltaTime: Float
    ) -> [String] {
        let inside = Set(partsInside(crown: crown, parts: parts, orientation: orientation, origin: origin))
        guard !inside.isEmpty else { return [] }
        let omega = worldAngularVelocity(state: state, orientation: orientation, airframeClass: airframeClass)
        let com = origin + simd_act(orientation, massProperties.centerOfMassOffset)
        let mass = max(0.05, massProperties.totalMassKg)
        var impulse = SIMD3<Float>.zero
        var angularImpulse = SIMD3<Float>.zero
        for part in parts where inside.contains(part.id) {
            let center = origin + simd_act(orientation, part.local)
            let velocity = state.velocity + simd_cross(omega, center - com)
            let speed = simd_length(velocity)
            guard speed > 0.05 else { continue }
            let direction = simd_act(part.rotation.conjugate, velocity / speed)
            let h = part.half
            let shadow = 4 * (h.y * h.z * abs(direction.x) + h.x * h.z * abs(direction.y) + h.x * h.y * abs(direction.z))
            let force = -Self.canopyBulkDensity * shadow * speed * velocity
            impulse += force * deltaTime
            angularImpulse += simd_cross(center - com, force * deltaTime)
        }
        guard simd_length_squared(impulse) > 0 else { return parts.map(\.id).filter(inside.contains) }
        // Never more than stops the aircraft: the fuel cannot push it backwards.
        let dv = impulse / mass
        let scale = min(1, simd_length(state.velocity) / max(1e-5, simd_length(dv)))
        state.velocity += dv * scale
        let torqueBody = simd_act(orientation.conjugate, angularImpulse * scale)
        let inertia = simd_max(massProperties.inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
        applyWorldAngularDelta(simd_act(orientation, torqueBody / inertia), state: &state,
                               orientation: orientation, airframeClass: airframeClass)
        return parts.map(\.id).filter(inside.contains)
    }

    // MARK: Frame math

    private struct AngularResponse {
        /// I⁻¹(r×d) in world frame — angular velocity change per unit impulse.
        let omegaPerUnitImpulse: SIMD3<Float>
        /// (I⁻¹(r×d))×r — the contact-point velocity contribution term.
        let velocityAtContact: SIMD3<Float>
    }

    private func angularResponse(
        leverArm: SIMD3<Float>,
        direction: SIMD3<Float>,
        orientation: simd_quatf,
        inertiaDiagonal: SIMD3<Float>
    ) -> AngularResponse {
        let torquePerImpulse = simd_cross(leverArm, direction)
        // World -> body axes, divide by diagonal inertia, back to world.
        let torqueBody = simd_act(orientation.conjugate, torquePerImpulse)
        let inertia = simd_max(inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
        let omegaBody = torqueBody / inertia
        let omegaWorld = simd_act(orientation, omegaBody)
        return AngularResponse(
            omegaPerUnitImpulse: omegaWorld,
            velocityAtContact: simd_cross(omegaWorld, leverArm)
        )
    }

    /// Angular-velocity change from an arbitrary world-space impulse.
    private func angularVelocityDelta(
        leverArm: SIMD3<Float>,
        impulse: SIMD3<Float>,
        orientation: simd_quatf,
        inertiaDiagonal: SIMD3<Float>
    ) -> SIMD3<Float> {
        let angularImpulseWorld = simd_cross(leverArm, impulse)
        let angularImpulseBody = simd_act(orientation.conjugate, angularImpulseWorld)
        let inertia = simd_max(inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
        return simd_act(orientation, angularImpulseBody / inertia)
    }

    /// Maximum scalar impulse that the joint could transmit along the impact
    /// direction before reaching its pre-impact residual force/moment limit.
    /// The ratios deliberately mirror `applyConnectionImpact` so structural
    /// failure and retained-body reaction use the same load envelope.
    private func jointImpulseCapacity(
        connection: VehicleStructuralConnection,
        parent: VehicleComponent,
        child: VehicleComponent,
        contactPointBody: SIMD3<Float>,
        impulseDirectionBody: SIMD3<Float>,
        residualStrength: Float,
        contactDuration: Float
    ) -> Float {
        let directionLength = simd_length(impulseDirectionBody)
        guard directionLength > 0.0001 else { return 0.0 }
        let direction = impulseDirectionBody / directionLength
        let duration = max(0.004, contactDuration)
        let forcePerImpulse = direction / duration
        let lever = contactPointBody - parent.localPosition
        let momentPerImpulse = simd_cross(lever, forcePerImpulse)
        let jointAxisRaw = child.localPosition - parent.localPosition
        let jointAxis = simd_length_squared(jointAxisRaw) > 0.000001
            ? simd_normalize(jointAxisRaw)
            : SIMD3<Float>(0.0, 1.0, 0.0)
        let axialForce = simd_dot(forcePerImpulse, jointAxis)
        let tensilePerImpulse = abs(axialForce)
        let shearPerImpulse = simd_length(forcePerImpulse - jointAxis * axialForce)
        let axialMoment = simd_dot(momentPerImpulse, jointAxis)
        let torsionPerImpulse = abs(axialMoment)
        let bendingPerImpulse = simd_length(momentPerImpulse - jointAxis * axialMoment)
        let ratioPerImpulse = max(
            tensilePerImpulse / max(0.01, connection.tensileLimitN),
            shearPerImpulse / max(0.01, connection.shearLimitN),
            bendingPerImpulse / max(0.01, connection.bendingLimitNm),
            torsionPerImpulse / max(0.01, connection.torsionLimitNm)
        )
        guard ratioPerImpulse > 0.000001 else { return .greatestFiniteMagnitude }
        return max(0.0, residualStrength) / ratioPerImpulse
    }

    private func attitudeQuaternion(state: DroneState, airframeClass: AirframeClass) -> simd_quatf {
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            return state.attitudeQuat
        case .multirotor:
            return orientationQuaternion(from: state.orientation)
        }
    }

    /// This codebase labels rates in (roll, pitch, yaw) component order with
    /// roll about body Z, pitch about body X, yaw about body Y (see the
    /// gyroscopic-precession note in SimpleDronePhysicsEngine). Standard
    /// (X,Y,Z) axis vector = (rates.y, rates.z, rates.x); inverse mapping
    /// axes -> rates = (axes.z, axes.x, axes.y).
    private func worldAngularVelocity(
        state: DroneState,
        orientation: simd_quatf,
        airframeClass: AirframeClass
    ) -> SIMD3<Float> {
        let rates: SIMD3<Float>
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            rates = state.bodyAngularVelocity
        case .multirotor:
            rates = state.angularVelocity
        }
        let axesVector = SIMD3<Float>(rates.y, rates.z, rates.x)
        return simd_act(orientation, axesVector)
    }

    private func applyWorldAngularDelta(
        _ deltaOmegaWorld: SIMD3<Float>,
        state: inout DroneState,
        orientation: simd_quatf,
        airframeClass: AirframeClass
    ) {
        let axesBody = simd_act(orientation.conjugate, deltaOmegaWorld)
        let ratesDelta = SIMD3<Float>(axesBody.z, axesBody.x, axesBody.y)
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            state.bodyAngularVelocity = clampMagnitude(state.bodyAngularVelocity + ratesDelta, limit: 10.0)
            state.angularVelocity = state.bodyAngularVelocity
        case .multirotor:
            state.angularVelocity = clampMagnitude(state.angularVelocity + ratesDelta, limit: 9.0)
        }
    }

    private func isPropellerComponent(_ id: String, graph: VehicleComponentGraph) -> Bool {
        guard let component = graph.component(id: id) else { return false }
        if case .propeller = component.kind { return true }
        return false
    }

    /// Explicit contact ownership wins even when the sphere extends outside
    /// a thin wing's bounds. Proximity is only a fallback for legacy contacts
    /// whose owner is unavailable; overlapping fuselage bounds cannot steal
    /// a wing strike.
    private func nearestComponentID(
        to bodyPoint: SIMD3<Float>,
        preferred: String,
        graph: VehicleComponentGraph
    ) -> String {
        func distanceToBounds(_ component: VehicleComponent) -> Float {
            let delta = simd_abs(bodyPoint - component.localPosition) - component.boundingHalfExtents
            return simd_length(simd_max(delta, SIMD3<Float>(repeating: 0.0)))
        }

        if let preferredComponent = graph.component(id: preferred),
           preferredComponent.isAttached {
            return preferred
        }
        return graph.attachedComponents
            .filter { $0.kind.isStructural }
            .min { lhs, rhs in
                let lhsDistance = distanceToBounds(lhs)
                let rhsDistance = distanceToBounds(rhs)
                if abs(lhsDistance - rhsDistance) < 0.0001 {
                    return lhs.id < rhs.id
                }
                return lhsDistance < rhsDistance
            }?.id ?? preferred
    }

    private func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
        let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1.0, 0.0, 0.0))
        let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0.0, 0.0, 1.0))
        return yaw * pitch * roll
    }

    private func clampMagnitude(_ vector: SIMD3<Float>, limit: Float) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > limit else {
            return vector
        }
        return simd_normalize(vector) * limit
    }
}
