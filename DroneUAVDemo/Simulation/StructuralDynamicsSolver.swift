import Foundation
import simd

// MARK: - Load field (quasi-static)

/// A point force on the airframe, body frame.
struct StructuralPointForce: Hashable {
    let componentID: String
    let pointBody: SIMD3<Float>
    let forceBody: SIMD3<Float>
}

/// Everything that loads the structure at one instant: the rigid-body motion (what every
/// mass must be accelerated with) and the external point forces (lift, thrust, contacts).
struct StructuralLoadCase {
    /// Acceleration minus gravity at the centre of mass, body frame.
    var specificForceBody: SIMD3<Float>
    var angularVelocityBody: SIMD3<Float> = .zero
    var angularAccelerationBody: SIMD3<Float> = .zero
    var centerOfMass: SIMD3<Float>
    var pointForces: [StructuralPointForce] = []
    /// Extra acceleration an impact imposes, by member ("*" for everything not on a member):
    /// the shock response of that member to the retained body's deceleration, applied on
    /// top of the steady field.
    var impulsive: [String: (linear: SIMD3<Float>, angular: SIMD3<Float>)] = [:]
    /// Members whose joints are skipped (already solved dynamically in this event).
    var excludedMembers: Set<String> = []
}

/// Joint loads of the whole attached tree for one load case, in each joint's own axes.
///
/// D'Alembert over subtrees: the parent must supply each child subtree with
/// `Σ m·(a − g) − F_ext`, and the moment of that about the joint. One bottom-up pass
/// accumulates both, so the cost is linear in the number of parts.
enum StructuralLoadField {
    static func jointLoads(
        graph: VehicleComponentGraph,
        loadCase: StructuralLoadCase,
        transforms: [String: simd_float4x4]? = nil
    ) -> [String: VehicleJointLoad] {
        let transforms = transforms ?? graph.deformationTransforms()
        let attached = graph.attachedComponents
        guard !attached.isEmpty else { return [:] }
        var memberOf: [String: String] = [:]
        for connection in graph.structuralConnections {
            if let member = connection.section?.memberID, !member.isEmpty {
                memberOf[connection.childComponentID] = member
            }
        }
        // Attachments inherit the member of the station they ride on.
        var memberCache: [String: String?] = [:]
        func member(of component: VehicleComponent) -> String? {
            if let cached = memberCache[component.id] { return cached }
            let resolved: String?
            if let own = memberOf[component.id] {
                resolved = own
            } else if let parentID = component.parentID, let parent = graph.component(id: parentID) {
                resolved = member(of: parent)
            } else {
                resolved = nil
            }
            memberCache[component.id] = resolved
            return resolved
        }
        var externalForce: [String: SIMD3<Float>] = [:]
        var externalMoment: [String: SIMD3<Float>] = [:]
        for force in loadCase.pointForces {
            externalForce[force.componentID, default: .zero] += force.forceBody
            externalMoment[force.componentID, default: .zero] += simd_cross(force.pointBody, force.forceBody)
        }
        let omega = loadCase.angularVelocityBody
        let alpha = loadCase.angularAccelerationBody
        let cm = loadCase.centerOfMass

        var subtreeForce: [String: SIMD3<Float>] = [:]
        var subtreeMoment: [String: SIMD3<Float>] = [:]
        let depths = graph.depths()
        let ordered = attached.sorted { (depths[$0.id] ?? 0) > (depths[$1.id] ?? 0) }
        for component in ordered {
            let transform = transforms[component.id] ?? matrix_identity_float4x4
            let p4 = transform * SIMD4<Float>(component.localPosition, 1)
            let position = SIMD3<Float>(p4.x, p4.y, p4.z)
            let d: SIMD3<Float> = position - cm
            let tangential: SIMD3<Float> = simd_cross(alpha, d)
            let centripetal: SIMD3<Float> = simd_cross(omega, simd_cross(omega, d))
            var acceleration: SIMD3<Float> = loadCase.specificForceBody + tangential + centripetal
            var angularAcceleration: SIMD3<Float> = alpha
            if let shock = member(of: component).flatMap({ loadCase.impulsive[$0] }) ?? loadCase.impulsive["*"] {
                let pulseTangential: SIMD3<Float> = simd_cross(shock.angular, d)
                acceleration += shock.linear + pulseTangential
                angularAcceleration += shock.angular
            }
            let external: SIMD3<Float> = externalForce[component.id] ?? .zero
            let required: SIMD3<Float> = acceleration * component.massKg - external
            let h = component.boundingHalfExtents
            let inertiaXYZ = SIMD3<Float>(h.y * h.y + h.z * h.z, h.x * h.x + h.z * h.z, h.x * h.x + h.y * h.y)
            let inertia: SIMD3<Float> = inertiaXYZ * (component.massKg / 3)
            let gyroscopic: SIMD3<Float> = simd_cross(omega, inertia * omega)
            let rotational: SIMD3<Float> = inertia * angularAcceleration + gyroscopic
            let childForce: SIMD3<Float> = subtreeForce[component.id] ?? .zero
            let childMoment: SIMD3<Float> = subtreeMoment[component.id] ?? .zero
            let externalTorque: SIMD3<Float> = externalMoment[component.id] ?? .zero
            let force: SIMD3<Float> = required + childForce
            let ownMoment: SIMD3<Float> = simd_cross(position, required) - externalTorque
            let moment: SIMD3<Float> = ownMoment + rotational + childMoment
            // Pass the whole subtree to the parent.
            if let parentID = component.parentID {
                subtreeForce[parentID, default: .zero] += force
                subtreeMoment[parentID, default: .zero] += moment
            }
            subtreeForce[component.id] = force
            subtreeMoment[component.id] = moment
        }

        var result: [String: VehicleJointLoad] = [:]
        for connection in graph.structuralConnections where connection.state != .detached {
            guard let section = connection.section,
                  let child = graph.component(id: connection.childComponentID), child.isAttached else { continue }
            if !section.memberID.isEmpty, loadCase.excludedMembers.contains(section.memberID) { continue }
            let parentTransform = graph.component(id: connection.parentComponentID).flatMap { transforms[$0.id] }
                ?? matrix_identity_float4x4
            let a4 = parentTransform * SIMD4<Float>(section.anchor, 1)
            let anchor = SIMD3<Float>(a4.x, a4.y, a4.z)
            let rotation = simd_quatf(parentTransform)
            var rotated = section
            rotated.anchor = anchor
            rotated.spanAxis = simd_act(rotation, section.spanAxis)
            rotated.normalAxis = simd_act(rotation, section.normalAxis)
            let force = subtreeForce[child.id] ?? .zero
            let momentOrigin = subtreeMoment[child.id] ?? .zero
            let moment = momentOrigin - simd_cross(anchor, force)
            result[connection.childComponentID] = rotated.localLoad(force: force, moment: moment)
        }
        return result
    }
}

// MARK: - Joint outcome rules

/// One place that turns "this joint saw that load" into what physically happens to it, so
/// the flight solver and the impact solver cannot disagree.
enum StructuralJointResponse {
    struct Outcome {
        var plasticRotationBody: SIMD3<Float>
        var plasticRotationSpent: Float
        var residualStrength: Float
        var stiffnessScale: Float
        var fracture: VehicleJointFracture
        var utilisation: Float
    }

    /// Fold a panel takes once its bending capacity is gone under a sustained load, radians.
    /// The panel turns with the load until it no longer carries it — about 70° for a wing
    /// folding in the airflow or down onto the ground.
    static let sustainedFoldAngle: Float = 1.2
    /// Plastic rotation past bending rupture at which a hanging panel's skin tears through.
    static let tearRotation: Float = 2.4

    /// Evaluates a quasi-static load: rupture if the section cannot carry it, permanent set
    /// if it yielded, nothing otherwise. Instantaneous — no time appears here.
    static func evaluate(
        connection: VehicleStructuralConnection,
        currentRotation: SIMD3<Float>,
        load: VehicleJointLoad,
        thermalWeakening: Float
    ) -> Outcome? {
        guard let section = connection.section, connection.state != .detached,
              connection.fracture != .separated else { return nil }
        let material = section.material
        let weakening = 1 - max(0, min(0.95, thermalWeakening))
        let residual = max(0.016, connection.residualStrength) * weakening

        if connection.fracture == .hinged {
            // Only the torn skin holds it: shear or tension beyond that tears it free.
            let force = section.forceUtilisation(of: load, residual: residual)
            guard force >= 1 else { return nil }
            return Outcome(plasticRotationBody: currentRotation, plasticRotationSpent: connection.plasticRotationSpent,
                           residualStrength: 0, stiffnessScale: 0, fracture: .separated, utilisation: force)
        }

        let total = section.utilisation(of: load, residual: residual)
        let momentUse = section.momentUtilisation(of: load, residual: residual)
        let forceUse = section.forceUtilisation(of: load, residual: residual)
        let capacity = max(0.001, material.plasticRotationCapacity)
        let yield = material.yieldRatio
        let spentFraction = min(1, connection.plasticRotationSpent / capacity)
        let currentYield = yield + (1 - yield) * spentFraction

        if forceUse >= 1 {
            return Outcome(plasticRotationBody: currentRotation, plasticRotationSpent: connection.plasticRotationSpent,
                           residualStrength: 0, stiffnessScale: 0, fracture: .separated, utilisation: total)
        }
        if momentUse >= 1 {
            // Bending capacity exhausted: the spar is gone. Whether the panel stays on depends
            // on whether the remaining skin can carry the shear and tension it still sees.
            let skin = material.retainedSkinFraction
            let skinUse = section.forceUtilisation(of: load, residual: residual * skin)
            let direction = hingeDirection(section: section, load: load)
            let fold = currentRotation + direction * (sustainedFoldAngle + capacity)
            return Outcome(plasticRotationBody: fold, plasticRotationSpent: capacity + sustainedFoldAngle,
                           residualStrength: skin * max(0.016, connection.residualStrength),
                           stiffnessScale: 0.02, fracture: skinUse >= 1 ? .separated : .hinged, utilisation: total)
        }
        guard momentUse > currentYield else { return nil }
        // Bilinear hardening: the section yields at `yield` and reaches ultimate after its
        // full plastic rotation. The new permanent set is where this load sits on that line.
        let targetSpent = capacity * (momentUse - yield) / max(0.001, 1 - yield)
        let increment = max(0, targetSpent - connection.plasticRotationSpent)
        guard increment > 1e-5 else { return nil }
        let direction = hingeDirection(section: section, load: load)
        let loss = material.strengthLossPerPlasticCapacity * (connection.plasticRotationSpent + increment) / capacity
        // A section that just carried this load can carry it: its residual never drops below it.
        let survived = max(0.016, total / max(0.001, weakening))
        let residual01 = max(min(connection.residualStrength, 1 - loss), min(1, survived * connection.residualStrength))
        return Outcome(
            plasticRotationBody: currentRotation + direction * increment,
            plasticRotationSpent: connection.plasticRotationSpent + increment,
            residualStrength: residual01,
            stiffnessScale: max(0.2, 1 - 0.6 * (connection.plasticRotationSpent + increment) / capacity),
            fracture: .intact,
            utilisation: total
        )
    }

    /// Unit body-frame direction a hinge turns under this load: each rotational component
    /// weighted by how close it is to its own capacity.
    static func hingeDirection(section: VehicleJointSection, load: VehicleJointLoad) -> SIMD3<Float> {
        let flapCapacity = load.flap >= 0 ? section.flapUltimateNm : section.flapNegativeUltimateNm
        let flap = load.flap / max(0.001, flapCapacity)
        let lag = load.lag / max(0.001, section.lagUltimateNm)
        let torsion = load.torsion / max(0.001, section.torsionUltimateNm)
        let vector = section.bodyRotation(torsion: torsion, flap: flap, lag: lag)
        return simd_length_squared(vector) > 1e-12 ? simd_normalize(vector) : section.chordAxis
    }
}

// MARK: - Dynamic amplification

enum StructuralDynamicAmplification {
    /// Peak response of an undamped oscillator of period `period` to a half-sine
    /// acceleration pulse of duration `pulse`, over its static response to the pulse peak.
    /// Short pulses barely move a flexible wing; a pulse near half its period nearly
    /// doubles the load.
    static func halfSine(pulse: Float, period: Float, damping: Float = 0.02) -> Float {
        guard pulse > 1e-5, period > 1e-5 else { return 1 }
        let omega = 2 * Float.pi / period
        let steps = 400
        let duration = pulse + period
        let dt = duration / Float(steps)
        var x: Float = 0, v: Float = 0, peak: Float = 0
        for step in 0..<steps {
            let t = Float(step) * dt
            let input: Float = t < pulse ? sin(Float.pi * t / pulse) : 0
            // Semi-implicit Euler on x'' + 2ζωx' + ω²x = ω²·input (static response = input).
            let a = omega * omega * (input - x) - 2 * damping * omega * v
            v += a * dt
            x += v * dt
            peak = max(peak, abs(x))
        }
        return max(0.05, peak)
    }
}

// MARK: - Member impact transient

/// Transient response of one slender member to a contact on it.
///
/// The member is a chain of rigid stations joined by six-way springs (axial, two shears,
/// flap, lag, torsion) whose stiffness follows from each section's strength and failure
/// strain; the rest of the aircraft is one rigid body at the root. The contact is a local
/// spring against the obstacle that crushes at the struck part's crush force, with Coulomb
/// friction and re-contact. Everything is solved together with implicit Newmark (average
/// acceleration) on a block-tridiagonal system, with joints yielding, folding and rupturing
/// during the pulse.
///
/// Because the whole chain responds, where a member breaks is an outcome: a short, sharp
/// strike loads the stations near it before the rest of the wing has moved and breaks it
/// there; a slow push loads the whole wing and breaks it near the root; a violent one can
/// break it in several places, and each piece leaves with its own velocity.
struct StructuralMemberImpactSolver {
    struct Contact {
        /// Station index along the chain (0 = root) and the struck point, body frame.
        let stationIndex: Int
        let pointBody: SIMD3<Float>
        /// Unit normal pointing from the obstacle into the aircraft, body frame.
        let normalBody: SIMD3<Float>
        let stiffness: Float
        let damping: Float
        let friction: Float
        let expectedDuration: Float
        /// Force at which the struck part crushes locally instead of passing more load on,
        /// and how deep it can crush before the obstacle is through it.
        var crushForce: Float = .greatestFiniteMagnitude
        var crushDepth: Float = .greatestFiniteMagnitude
        /// An obstacle that moves: its mass at the struck point and the spring holding it
        /// there (a branch bending, a sapling swaying). Infinite for a rigid obstacle, which is
        /// solved as a fixed wall exactly as before.
        var obstacleMass: Float = .infinity
        var obstacleStiffness: Float = .infinity
        /// Force at which the obstacle itself gives way (a branch at its breaking load), how
        /// far it bends on past that before it has broken off, and how far it can be pushed in
        /// all before it slides clear round the part instead.
        var obstacleYieldForce: Float = .greatestFiniteMagnitude
        var obstacleStroke: Float = .greatestFiniteMagnitude
        var obstacleClearance: Float = .greatestFiniteMagnitude
    }

    struct Input {
        let graph: VehicleComponentGraph
        let memberStationIDs: [String]
        let contact: Contact
        /// Pre-impact rigid motion, body frame.
        let velocityBody: SIMD3<Float>
        let angularVelocityBody: SIMD3<Float>
        let centerOfMassBody: SIMD3<Float>
        /// Sustained loads already on each joint (1 g, flight), by station id.
        let preload: [String: VehicleJointLoad]
        let thermalWeakening: Float
    }

    struct JointResult {
        let stationID: String
        let outcome: StructuralJointResponse.Outcome
        let peakUtilisation: Float
        let timeOfFracture: Float?
    }

    struct Fragment {
        let rootStationID: String
        let velocityBody: SIMD3<Float>
        let angularVelocityBody: SIMD3<Float>
    }

    struct Result {
        let joints: [JointResult]
        let fragments: [Fragment]
        /// Rigid velocity of the retained aircraft after the event, body frame.
        let retainedVelocityBody: SIMD3<Float>
        let retainedAngularVelocityBody: SIMD3<Float>
        let normalImpulse: Float
        let contactDissipatedEnergy: Float
        let frictionWork: Float
        let contactDuration: Float
        /// How far the struck part crushed, the energy that took, and whether the obstacle
        /// went right through it.
        let crushDepth: Float
        let crushEnergy: Float
        let cutThrough: Bool
        /// The obstacle gave way completely (a branch snapped or was pushed clear), and the work
        /// that took out of the aircraft.
        var obstacleGaveWay: Bool = false
        var obstacleWork: Float = 0
        /// The retained body's acceleration over the event, for the rest of the airframe.
        let bodyAccelerationHistory: StructuralAccelerationHistory
        /// Peak acceleration of each station, for the parts mounted on it.
        let peakStationAcceleration: [String: SIMD3<Float>]
        let steps: Int
    }

    private enum JointState { case intact, hinged, separated }

    /// Prints one summary line per solved impact (probes and debugging).
    static var debugLog = false

    func solve(_ input: Input) -> Result? {
        let graph = input.graph
        let n = input.memberStationIDs.count
        guard n > 0, input.contact.stationIndex >= 0, input.contact.stationIndex < n else { return nil }
        let transforms = graph.deformationTransforms()
        let stationSet = Set(input.memberStationIDs)

        // Lumped bodies: every station with whatever rides on it; body 0 is the rest.
        var childrenOf: [String: [String]] = [:]
        for component in graph.attachedComponents {
            if let parent = component.parentID { childrenOf[parent, default: []].append(component.id) }
        }
        var bodyIDs: [Set<String>] = []
        for id in input.memberStationIDs {
            var ids: Set<String> = []
            var pending = [id]
            while let current = pending.popLast() {
                guard ids.insert(current).inserted else { continue }
                for child in childrenOf[current] ?? [] where !stationSet.contains(child) { pending.append(child) }
            }
            bodyIDs.append(ids)
        }
        let memberIDs = bodyIDs.reduce(into: Set<String>()) { $0.formUnion($1) }
        let restIDs = Set(graph.attachedComponents.map(\.id)).subtracting(memberIDs)
        guard !restIDs.isEmpty else { return nil }
        var properties = [graph.massProperties(of: restIDs)]
        for ids in bodyIDs { properties.append(graph.massProperties(of: ids)) }
        let bodies = properties.count

        // Joints: joint j connects body j (parent; 0 = rest of aircraft) to body j+1.
        struct Joint {
            var section: VehicleJointSection
            var state: JointState
            var plastic: SIMD3<Float> = .zero
            var spent: Float
            var residual: Float
            var peak: Float = 0
            var fractureTime: Float?
            var stiffness: (axial: Float, shear: Float, torsion: Float, lag: Float, flap: Float)
            let connection: VehicleStructuralConnection
        }
        var joints: [Joint] = []
        for id in input.memberStationIDs {
            guard let connection = graph.connection(childComponentID: id), let base = connection.section else { return nil }
            let parentTransform = graph.component(id: connection.parentComponentID).flatMap { transforms[$0.id] }
                ?? matrix_identity_float4x4
            let a4 = parentTransform * SIMD4<Float>(base.anchor, 1)
            var section = base
            section.anchor = SIMD3<Float>(a4.x, a4.y, a4.z)
            let rotation = simd_quatf(parentTransform)
            section.spanAxis = simd_act(rotation, base.spanAxis)
            section.normalAxis = simd_act(rotation, base.normalAxis)
            let state: JointState = connection.fracture == .separated ? .separated
                : connection.fracture == .hinged ? .hinged : .intact
            let scale = max(0.05, connection.stiffnessScale)
            joints.append(Joint(
                section: section, state: state,
                spent: connection.plasticRotationSpent,
                residual: max(0.016, connection.residualStrength) * (1 - max(0, min(0.95, input.thermalWeakening))),
                stiffness: (base.axialStiffness * scale, base.shearStiffness * scale, base.torsionStiffness * scale,
                            base.lagStiffness * scale, base.flapStiffness * scale),
                connection: connection))
        }

        var mass = [Vec6](repeating: .zero, count: bodies)
        for (b, p) in properties.enumerated() {
            let m = Double(max(0.0005, p.totalMassKg))
            mass[b] = Vec6(top: SIMD3<Double>(repeating: m),
                           bottom: SIMD3<Double>(simd_max(p.inertiaDiagonal, SIMD3<Float>(repeating: 1e-7))))
        }
        let centers = properties.map(\.centerOfMassOffset)

        struct JointBlocks { var cc, pp, cp, d, bc, bp: Block6 }
        func jointBlocks(_ joint: Joint, parent p: Int, child c: Int) -> JointBlocks {
            let s = joint.section
            let es = SIMD3<Double>(s.spanAxis), en = SIMD3<Double>(s.normalAxis), ec = SIMD3<Double>(s.chordAxis)
            var k = joint.stiffness
            switch joint.state {
            case .intact: break
            case .hinged:
                // Torn skin: a fraction of the shear/axial path, almost no bending.
                let skin = s.material.retainedSkinFraction
                k = (k.axial * skin, k.shear * skin, k.torsion * 0.02, k.lag * 0.02, k.flap * 0.02)
            case .separated:
                k = (0, 0, 0, 0, 0)
            }
            let translational = outer(es, Double(k.axial)) + outer(en, Double(k.shear)) + outer(ec, Double(k.shear))
            let rotational = outer(es, Double(k.torsion)) + outer(en, Double(k.lag)) + outer(ec, Double(k.flap))
            let d = Block6(tl: translational, tr: .zero3, bl: .zero3, br: rotational)
            let dc = SIMD3<Double>(s.anchor - centers[c]), dp = SIMD3<Double>(s.anchor - centers[p])
            let identity = matrix_identity_double3x3
            let bc = Block6(tl: identity, tr: skew(dc) * -1, bl: .zero3, br: identity)
            let bp = Block6(tl: identity * -1, tr: skew(dp), bl: .zero3, br: identity * -1)
            let dbc = d * bc, dbp = d * bp
            return JointBlocks(cc: bc.transposed * dbc, pp: bp.transposed * dbp, cp: bc.transposed * dbp,
                               d: d, bc: bc, bp: bp)
        }

        var blockCache: [JointBlocks] = []
        func assemble() -> (diag: [Block6], lower: [Block6]) {
            var diag = [Block6](repeating: .zero, count: bodies)
            var lower = [Block6](repeating: .zero, count: bodies)
            blockCache = []
            blockCache.reserveCapacity(joints.count)
            for (j, joint) in joints.enumerated() {
                let blocks = jointBlocks(joint, parent: j, child: j + 1)
                blockCache.append(blocks)
                diag[j + 1] = diag[j + 1] + blocks.cc
                diag[j] = diag[j] + blocks.pp
                lower[j + 1] = lower[j + 1] + blocks.cp
            }
            return (diag, lower)
        }

        // First bending period of the member with the rest of the aircraft held still:
        // Rayleigh quotient of the static deflection under a uniform normal load.
        var stiffnessBlocks = assemble()
        let rootNormal = SIMD3<Double>(joints[0].section.normalAxis)
        let firstPeriod: Float = {
            var diag = Array(stiffnessBlocks.diag[1...])
            let lower = Array(stiffnessBlocks.lower[1...])
            for i in diag.indices { diag[i] = diag[i].addingDiagonal(mass[i + 1] * 1e-9) }
            guard let factor = BlockTridiagonalCholesky(diag: diag, lower: lower) else { return 0.1 }
            let load = (0..<n).map { Vec6(top: mass[$0 + 1].top * rootNormal, bottom: .zero) }
            let u = factor.solve(load)
            var work = 0.0, kinetic = 0.0
            for i in 0..<n {
                work += u[i].dot(load[i])
                kinetic += u[i].dot(u[i] * mass[i + 1])
            }
            guard work > 0, kinetic > 0 else { return 0.1 }
            return Float(2 * Double.pi / sqrt(work / kinetic))
        }()
        let zeta = Double(joints[0].section.material.dampingRatio)
        let beta = 2 * zeta / (2 * Double.pi / Double(max(1e-4, firstPeriod)))

        // Contact geometry: n^T · B_p over the struck body's six DOFs.
        let contact = input.contact
        let struck = contact.stationIndex + 1
        let arm = contact.pointBody - centers[struck]
        let contactRow = Vec6(top: SIMD3<Double>(contact.normalBody),
                              bottom: SIMD3<Double>(simd_cross(arm, contact.normalBody)))
        let contactOuter = Block6.outer(contactRow, contactRow)

        // Initial state: every body moves with the rigid pre-impact field.
        var u = [Vec6](repeating: .zero, count: bodies)
        var v = [Vec6](repeating: .zero, count: bodies)
        var a = [Vec6](repeating: .zero, count: bodies)
        for b in 0..<bodies {
            let rel = centers[b] - input.centerOfMassBody
            let lin = input.velocityBody + simd_cross(input.angularVelocityBody, rel)
            v[b] = Vec6(top: SIMD3<Double>(lin), bottom: SIMD3<Double>(input.angularVelocityBody))
        }

        let localMass = Double(max(0.0005, properties[struck].totalMassKg))
        let kc = Double(max(1e-3, contact.stiffness)), cc = Double(max(0, contact.damping))
        let localPeriod = Double.pi * sqrt(localMass / kc)
        let pulse = Double(max(0.001, contact.expectedDuration))
        // Twelve steps across the stiffest contact oscillation keeps average-acceleration
        // Newmark within a few per cent of its period; while the part is crushing the contact
        // is a constant force, not a spring, and three times that step is enough.
        let fineStep = max(2e-5, min(pulse, localPeriod) / 12)
        var dt = fineStep
        let settle = Double(max(0.004, firstPeriod)) * 0.5
        var time = 0.0
        let preloads = joints.map { input.preload[$0.connection.childComponentID] ?? .zero }

        /// Unilateral contact with local crushing: open, elastic (a spring against the crushed
        /// surface), or crushing (the part folds up at its crush force while it keeps being
        /// pushed in). Re-contact is allowed — a wing tip knocked back off a pole is pushed
        /// into it again by the rest of the wing.
        enum ContactMode { case open, elastic, crushing }
        func approachRate(_ velocity: [Vec6]) -> Double { -contactRow.dot(velocity[struck]) }
        func penetration(_ displacement: [Vec6]) -> Double { -contactRow.dot(displacement[struck]) }
        var mode: ContactMode = approachRate(v) > 0 ? .elastic : .open
        var everContact = false
        var lastContact = 0.0
        var friction = SIMD3<Float>.zero
        var normalImpulse = 0.0, dissipated = 0.0, frictionWork = 0.0
        var crushed = 0.0, crushEnergy = 0.0
        var cutThrough = false
        let crushLimit = Double(contact.crushForce)
        let crushDepthLimit = Double(contact.crushDepth)
        // The obstacle, when it moves: one degree of freedom along the contact normal — its
        // effective mass on an elastic–plastic spring to the ground. It is condensed into the
        // struck station's contact row every step, so the chain stays block-tridiagonal:
        // eliminating `x_o` from `(M_o·a0 + k_t)·x_o = F_c − f_0 + R_o` leaves the station a
        // contact spring `k·(M_o·a0 + k_t)/(M_o·a0 + k_t + k)` and a known force. A heavy
        // obstacle is a wall again; a light one is knocked aside by its own inertia before its
        // stiffness counts, which is how a twig meets a wing at 20 m/s.
        let obstacleMoves = contact.obstacleMass.isFinite && contact.obstacleStiffness.isFinite
        let obstacleMass = Double(obstacleMoves ? max(1e-4, contact.obstacleMass) : 0)
        let obstacleSpring = Double(obstacleMoves ? max(1e-3, contact.obstacleStiffness) : 0)
        let obstacleYield = Double(contact.obstacleYieldForce)
        let obstacleStroke = Double(contact.obstacleStroke)
        let obstacleClearance = Double(contact.obstacleClearance)
        var xo = 0.0, vo = 0.0, ao = 0.0, xp = 0.0
        var obstacleYielding = false
        var obstacleGaveWay = false, obstacleWork = 0.0
        // Candidate obstacle state for the step being solved; committed with the chain.
        var nextXo = 0.0, nextVo = 0.0, nextAo = 0.0
        var history = StructuralAccelerationHistory()
        var peakStation = [SIMD3<Float>](repeating: .zero, count: n)
        var factor: BlockTridiagonalCholesky?
        var factorKey: (dt: Double, contact: Bool, yielding: Bool, revision: Int) = (-1, false, false, -1)
        var revision = 0
        let maxSteps = 1600
        var step = 0
        var a0 = 0.0, a1 = 0.0, a2 = 0.0
        var rhs = [Vec6](repeating: .zero, count: bodies)
        var predictor = [Vec6](repeating: .zero, count: bodies)
        var next = [Vec6](repeating: .zero, count: bodies)
        var nextA = [Vec6](repeating: .zero, count: bodies)
        var nextV = [Vec6](repeating: .zero, count: bodies)

        /// The obstacle's own terms for this step: its tangent spring, the constant part of its
        /// spring force, and its Newmark inertia.
        func obstacleTerms() -> (kt: Double, f0: Double, inertia: Double) {
            let kt = obstacleYielding ? 0 : obstacleSpring
            let f0 = obstacleYielding ? obstacleYield : -obstacleSpring * xp
            return (kt, f0, obstacleMass * (a0 * xo + a2 * vo + ao))
        }
        /// Station contact stiffness in the elastic mode, with the obstacle condensed out.
        func elasticContactStiffness() -> Double {
            let kcc = kc + a1 * cc
            guard obstacleMoves else { return kcc }
            let terms = obstacleTerms()
            let held = obstacleMass * a0 + terms.kt
            return kcc * held / (held + kcc)
        }

        func stepSolve(_ mode: ContactMode) -> Bool {
            let spring = mode == .elastic
            if factor == nil || factorKey.dt != dt || factorKey.contact != spring
                || factorKey.yielding != obstacleYielding || factorKey.revision != revision {
                var diag = stiffnessBlocks.diag.map { $0 * (1 + a1 * beta) }
                let lower = stiffnessBlocks.lower.map { $0 * (1 + a1 * beta) }
                for b in 0..<bodies { diag[b] = diag[b].addingDiagonal(mass[b] * a0) }
                if spring { diag[struck] = diag[struck] + contactOuter * elasticContactStiffness() }
                factor = BlockTridiagonalCholesky(diag: diag, lower: lower)
                factorKey = (dt, spring, obstacleYielding, revision)
            }
            guard let factor else { return false }
            // RHS = F + F_plastic + M(a0 u + a2 v + a) + C(a1 u + v)   (β = ¼, γ = ½)
            for b in 0..<bodies {
                rhs[b] = mass[b] * (u[b] * a0 + v[b] * a2 + a[b])
                predictor[b] = u[b] * a1 + v[b]
            }
            let damped = blockMultiply(stiffnessBlocks, predictor)
            for b in 0..<bodies { rhs[b] = rhs[b] + damped[b] * beta }
            // Plastic rest rotations of the joints.
            for j in joints.indices where joints[j].state != .separated && simd_length_squared(joints[j].plastic) > 0 {
                let blocks = blockCache[j]
                let rest = blocks.d * Vec6(top: .zero, bottom: SIMD3<Double>(joints[j].plastic))
                rhs[j + 1] = rhs[j + 1] + blocks.bc.transposed * rest
                rhs[j] = rhs[j] + blocks.bp.transposed * rest
            }
            // Contact force on the station, `F_c = k·(p − x_o − crushed) + c·(ṗ − ẋ_o)`; with a
            // rigid obstacle `x_o ≡ 0`.
            let kcc = kc + a1 * cc
            let terms = obstacleTerms()
            let relativeDamping = cc * contactRow.dot(predictor[struck]) - kc * crushed + (obstacleMoves ? cc * (a1 * xo + vo) : 0)
            let held = obstacleMass * a0 + terms.kt
            switch mode {
            case .open:
                break
            case .elastic:
                // Contact damping on the predictor terms, the crushed depth that no longer pushes
                // back, and — for a moving obstacle — what its inertia and spring leave over.
                let constant = obstacleMoves
                    ? relativeDamping - kcc * (relativeDamping - terms.f0 + terms.inertia) / (held + kcc)
                    : relativeDamping
                rhs[struck] = rhs[struck] + contactRow * constant
            case .crushing:
                // A crushing part pushes back with its crush force, no more.
                rhs[struck] = rhs[struck] + contactRow * crushLimit
            }
            if mode != .open {
                rhs[struck] = rhs[struck] + Vec6(top: SIMD3<Double>(friction), bottom: SIMD3<Double>(simd_cross(arm, friction)))
            }
            next = factor.solve(rhs)
            for b in 0..<bodies {
                nextA[b] = (next[b] - u[b]) * a0 - v[b] * a2 - a[b]
                nextV[b] = v[b] + (a[b] + nextA[b]) * (0.5 * dt)
            }
            if obstacleMoves {
                // Recover the obstacle from the solved station.
                switch mode {
                case .open:
                    nextXo = (terms.inertia - terms.f0) / held
                case .elastic:
                    nextXo = (kcc * penetration(next) + relativeDamping - terms.f0 + terms.inertia) / (held + kcc)
                case .crushing:
                    nextXo = (crushLimit - terms.f0 + terms.inertia) / held
                }
                nextAo = (nextXo - xo) * a0 - vo * a2 - ao
                nextVo = vo + (ao + nextAo) * (0.5 * dt)
            }
            return true
        }

        integration: while step < maxSteps {
            step += 1
            // Newmark average-acceleration constants.
            a0 = 4 / (dt * dt); a1 = 2 / dt; a2 = 4 / dt

            var attempts = 0
            while true {
                attempts += 1
                guard stepSolve(mode) else { return nil }
                guard attempts < 4, !cutThrough, !obstacleGaveWay else { break }
                // Relative to the obstacle, which is where it has moved to.
                let delta = penetration(next) - (obstacleMoves ? nextXo : 0)
                let rate = approachRate(nextV) - (obstacleMoves ? nextVo : 0)
                let previousMode = mode
                let previousYielding = obstacleYielding
                switch mode {
                case .open:
                    if delta > crushed + 1e-9 { mode = .elastic }
                case .elastic:
                    let force = kc * (delta - crushed) + cc * rate
                    if force < 0 { mode = .open } else if force > crushLimit { mode = .crushing }
                case .crushing:
                    if rate < 0 {
                        crushed = max(crushed, delta - crushLimit / kc)
                        mode = .elastic
                    }
                }
                if obstacleMoves {
                    // The obstacle's spring is elastic–perfectly plastic: it yields at its
                    // breaking load and unloads elastically when it swings back.
                    if !obstacleYielding, obstacleSpring * (nextXo - xp) > obstacleYield {
                        obstacleYielding = true
                    } else if obstacleYielding, nextVo < 0 {
                        xp = max(xp, nextXo - obstacleYield / obstacleSpring)
                        obstacleYielding = false
                    }
                }
                if mode == previousMode && obstacleYielding == previousYielding { break }
            }

            // Contact bookkeeping and friction for the next step.
            let delta = penetration(next) - (obstacleMoves ? nextXo : 0)
            let rate = approachRate(nextV) - (obstacleMoves ? nextVo : 0)
            var fn = 0.0
            switch mode {
            case .open:
                fn = 0
            case .elastic:
                fn = max(0, kc * (delta - crushed) + cc * rate)
                dissipated += cc * rate * rate * dt
            case .crushing:
                fn = crushLimit
                let depth = delta - crushLimit / kc
                if depth > crushed {
                    crushEnergy += crushLimit * (depth - crushed)
                    crushed = depth
                }
            }
            if obstacleMoves {
                if obstacleYielding {
                    let plastic = nextXo - obstacleYield / obstacleSpring
                    if plastic > xp {
                        obstacleWork += obstacleYield * (plastic - xp)
                        xp = plastic
                    }
                }
                xo = nextXo; vo = nextVo; ao = nextAo
            }
            if fn > 0 {
                everContact = true
                lastContact = time + dt
                normalImpulse += fn * dt
                let lin = SIMD3<Float>(nextV[struck].top), ang = SIMD3<Float>(nextV[struck].bottom)
                let point = lin + simd_cross(ang, arm)
                let slip = point - contact.normalBody * simd_dot(point, contact.normalBody)
                let slipSpeed = simd_length(slip)
                friction = slipSpeed > 1e-4 ? -slip / max(slipSpeed, 0.05) * Float(fn) * contact.friction : .zero
                frictionWork += Double(simd_length(friction) * slipSpeed) * dt
            } else {
                friction = .zero
            }
            if obstacleMoves && !obstacleGaveWay && (xp >= obstacleStroke || xo >= obstacleClearance) {
                // The obstacle has gone: snapped, or bent far enough to slide clear round the
                // part. What it was carrying goes with it, and nothing pushes on the part now.
                obstacleGaveWay = true
                mode = .open
            }
            if crushed >= crushDepthLimit && !cutThrough {
                // The obstacle is through the part: nothing is left to push on, and the
                // station is cut where it was struck — on its inboard side if the strike was
                // in its inboard half, otherwise outboard.
                cutThrough = true
                mode = .open
                let strikeJoint = contact.stationIndex
                let s = joints[strikeJoint].section
                let along = simd_dot(contact.pointBody - s.anchor, s.spanAxis)
                let outboard = strikeJoint + 1 < joints.count
                    ? simd_dot(joints[strikeJoint + 1].section.anchor - s.anchor, s.spanAxis) : 2 * along
                let cut = along > outboard * 0.5 && strikeJoint + 1 < joints.count ? strikeJoint + 1 : strikeJoint
                if joints[cut].state != .separated {
                    joints[cut].state = .separated
                    joints[cut].fractureTime = Float(time)
                    stiffnessBlocks = assemble()
                    revision += 1
                }
            }

            u = next; v = nextV; a = nextA
            time += dt
            history.append(time: Float(time), linear: SIMD3<Float>(a[0].top), angular: SIMD3<Float>(a[0].bottom))
            for i in 0..<n {
                let stationA = SIMD3<Float>(a[i + 1].top)
                if simd_length_squared(stationA) > simd_length_squared(peakStation[i]) { peakStation[i] = stationA }
            }

            // Joint yield / fold / rupture during the pulse.
            var topologyChanged = false
            for j in joints.indices where joints[j].state != .separated {
                let joint = joints[j]
                let blocks = blockCache[j]
                let g = blocks.bc * u[j + 1] + blocks.bp * u[j]
                let deltaJoint = SIMD3<Float>(g.top)
                let rotation = SIMD3<Float>(g.bottom) - joint.plastic
                let s = joint.section
                let es = s.spanAxis, en = s.normalAxis, ec = s.chordAxis
                let k = joint.stiffness
                // Elastic joint load, applied-load convention (see `localLoad`).
                var load = VehicleJointLoad(
                    axial: k.axial * simd_dot(deltaJoint, es),
                    shearNormal: k.shear * simd_dot(deltaJoint, en),
                    shearChord: k.shear * simd_dot(deltaJoint, ec),
                    torsion: k.torsion * simd_dot(rotation, es),
                    flap: k.flap * simd_dot(rotation, ec),
                    lag: k.lag * simd_dot(rotation, en))
                if joint.state == .hinged {
                    let skin = s.material.retainedSkinFraction
                    load.torsion *= 0.02; load.flap *= 0.02; load.lag *= 0.02
                    load.axial *= skin; load.shearNormal *= skin; load.shearChord *= skin
                }
                let total = load + preloads[j]
                let residual = joint.residual * (joint.state == .hinged ? s.material.retainedSkinFraction : 1)
                joints[j].peak = max(joints[j].peak, s.utilisation(of: total, residual: residual))
                if s.forceUtilisation(of: total, residual: residual) >= 1 {
                    joints[j].state = .separated
                    joints[j].fractureTime = joints[j].fractureTime ?? Float(time)
                    topologyChanged = true
                    continue
                }
                let material = s.material
                let capacity = max(0.001, material.plasticRotationCapacity)
                if joint.state == .hinged {
                    // The fold follows whatever still turns it; the skin tears through past
                    // the tear rotation.
                    let freeRotation = SIMD3<Float>(g.bottom) - joint.plastic
                    if simd_length(freeRotation) > 0.02 {
                        joints[j].plastic += freeRotation * 0.9
                        joints[j].spent += simd_length(freeRotation) * 0.9
                    }
                    if joints[j].spent > capacity + StructuralJointResponse.tearRotation {
                        joints[j].state = .separated
                        topologyChanged = true
                    }
                    continue
                }
                let momentUse = s.momentUtilisation(of: total, residual: residual)
                let yield = material.yieldRatio
                let currentYield = yield + (1 - yield) * min(1, joint.spent / capacity)
                guard momentUse > currentYield else { continue }
                // Return mapping on the bilinear hinge: the plastic rotation that brings the
                // load back onto the hardening line, Δθ = (u − y) / (k + H) in utilisation
                // units, turned the way the load pushes.
                let flapCapacity = max(1e-3, (total.flap >= 0 ? s.flapUltimateNm : s.flapNegativeUltimateNm) * residual)
                let lagCapacity = max(1e-3, s.lagUltimateNm * residual)
                let torsionCapacity = max(1e-3, s.torsionUltimateNm * residual)
                let mf = total.flap / flapCapacity, ml = total.lag / lagCapacity, mt = total.torsion / torsionCapacity
                let norm2 = max(1e-9, mf * mf + ml * ml + mt * mt)
                let elastic = (mf * mf * k.flap / flapCapacity + ml * ml * k.lag / lagCapacity
                    + mt * mt * k.torsion / torsionCapacity) / norm2
                let hardening = (1 - yield) / capacity
                let increment = (momentUse - currentYield) / max(1e-6, elastic + hardening)
                joints[j].plastic += StructuralJointResponse.hingeDirection(section: s, load: total) * increment
                joints[j].spent += increment
                if joints[j].spent >= capacity {
                    // Bending rupture. The torn skin keeps the child on unless the shear or
                    // tension it still carries is beyond it.
                    let skinUse = s.forceUtilisation(of: total, residual: joint.residual * material.retainedSkinFraction)
                    joints[j].state = skinUse >= 1 ? .separated : .hinged
                    joints[j].fractureTime = joints[j].fractureTime ?? Float(time)
                    topologyChanged = true
                }
            }
            if topologyChanged {
                stiffnessBlocks = assemble()
                revision += 1
            }

            // End of event: out of contact for half the member's period — long enough for
            // the member's own response to peak and for any re-contact to have happened.
            switch mode {
            case .open:
                if everContact && time - lastContact > settle { break integration }
                if !everContact && time > pulse * 2 { break integration }
                if everContact && time - lastContact > pulse {
                    let coarse = max(fineStep, Double(max(1e-4, firstPeriod)) / 40)
                    if coarse > dt * 1.5 { dt = coarse }
                }
            case .crushing:
                dt = fineStep * 3
            case .elastic:
                dt = fineStep
            }
        }

        // Results.
        var jointResults: [JointResult] = []
        for joint in joints {
            let connection = joint.connection
            let fracture: VehicleJointFracture = joint.state == .separated ? .separated
                : joint.state == .hinged ? .hinged : .intact
            let previous = graph.component(id: connection.childComponentID)?.deformation.bendRadians ?? .zero
            let capacity = max(0.001, joint.section.material.plasticRotationCapacity)
            let loss = joint.section.material.strengthLossPerPlasticCapacity * min(1, joint.spent / capacity)
            let residual: Float
            switch fracture {
            case .separated: residual = 0
            case .hinged: residual = joint.section.material.retainedSkinFraction * max(0.016, connection.residualStrength)
            case .intact:
                residual = max(min(connection.residualStrength, 1 - loss), min(connection.residualStrength, joint.peak))
            }
            let changed = fracture != connection.fracture || simd_length_squared(joint.plastic) > 1e-10
            jointResults.append(JointResult(
                stationID: connection.childComponentID,
                outcome: .init(
                    plasticRotationBody: previous + joint.plastic,
                    plasticRotationSpent: changed ? joint.spent : connection.plasticRotationSpent,
                    residualStrength: changed ? residual : connection.residualStrength,
                    stiffnessScale: fracture == .intact
                        ? min(connection.stiffnessScale, max(0.2, 1 - 0.6 * min(1, joint.spent / capacity))) : 0.02,
                    fracture: fracture,
                    utilisation: joint.peak),
                peakUtilisation: joint.peak,
                timeOfFracture: joint.fractureTime))
        }

        // Pieces: each separated joint starts a fragment that runs out to the next one. The
        // retained aircraft keeps the momentum and angular momentum of what stays attached.
        var fragments: [Fragment] = []
        var retainedMomentum = SIMD3<Float>(v[0].top) * properties[0].totalMassKg
        var retainedMass = properties[0].totalMassKg
        var retainedBodies = [0]
        var index = 0
        var attachedToBody = true
        while index < n {
            if joints[index].state == .separated {
                attachedToBody = false
                var end = index + 1
                while end < n && joints[end].state != .separated { end += 1 }
                var momentum = SIMD3<Float>.zero, total: Float = 0
                for b in (index + 1)...end {
                    momentum += SIMD3<Float>(v[b].top) * properties[b].totalMassKg
                    total += properties[b].totalMassKg
                }
                fragments.append(Fragment(
                    rootStationID: input.memberStationIDs[index],
                    velocityBody: momentum / max(1e-4, total),
                    angularVelocityBody: SIMD3<Float>(v[index + 1].bottom)))
                index = end
            } else {
                if attachedToBody {
                    retainedMomentum += SIMD3<Float>(v[index + 1].top) * properties[index + 1].totalMassKg
                    retainedMass += properties[index + 1].totalMassKg
                    retainedBodies.append(index + 1)
                }
                index += 1
            }
        }
        let retainedVelocity = retainedMomentum / max(1e-4, retainedMass)
        var retainedCenter = SIMD3<Float>.zero
        for b in retainedBodies { retainedCenter += centers[b] * properties[b].totalMassKg }
        retainedCenter /= max(1e-4, retainedMass)
        // Angular momentum of the retained assembly about its own centre, over its inertia.
        var angularMomentum = SIMD3<Float>.zero
        var inertia = SIMD3<Float>.zero
        for b in retainedBodies {
            let r = centers[b] - retainedCenter
            let m = properties[b].totalMassKg
            let own = properties[b].inertiaDiagonal
            angularMomentum += own * SIMD3<Float>(v[b].bottom) + simd_cross(r, (SIMD3<Float>(v[b].top) - retainedVelocity) * m)
            inertia += own + SIMD3<Float>(r.y * r.y + r.z * r.z, r.x * r.x + r.z * r.z, r.x * r.x + r.y * r.y) * m
        }

        if Self.debugLog {
            print("[MemberImpact] stations=\(n) struck=\(contact.stationIndex) steps=\(step) t=\(String(format: "%.4f", time)) "
                + "T1=\(String(format: "%.3f", firstPeriod)) kc=\(String(format: "%.3g", kc)) crushF=\(String(format: "%.3g", crushLimit)) "
                + "crushed=\(String(format: "%.3f", crushed))/\(String(format: "%.3f", crushDepthLimit)) cut=\(cutThrough) "
                + "J=\(String(format: "%.1f", normalImpulse)) fracture=\(joints.enumerated().filter { $0.element.state != .intact }.map { "\($0.offset):\($0.element.state)@\(String(format: "%.4f", $0.element.fractureTime ?? -1))" })")
        }
        return Result(
            joints: jointResults,
            fragments: fragments,
            retainedVelocityBody: retainedVelocity,
            retainedAngularVelocityBody: angularMomentum / simd_max(inertia, SIMD3<Float>(repeating: 1e-6)),
            normalImpulse: Float(normalImpulse),
            contactDissipatedEnergy: Float(dissipated),
            frictionWork: Float(frictionWork),
            contactDuration: Float(max(lastContact, dt)),
            crushDepth: Float(crushed),
            crushEnergy: Float(crushEnergy),
            cutThrough: cutThrough,
            obstacleGaveWay: obstacleGaveWay,
            obstacleWork: Float(obstacleWork),
            bodyAccelerationHistory: history,
            peakStationAcceleration: Dictionary(uniqueKeysWithValues: zip(input.memberStationIDs, peakStation).map { ($0.0, $0.1) }),
            steps: step)
    }

    private func outer(_ axis: SIMD3<Double>, _ k: Double) -> simd_double3x3 {
        simd_double3x3(columns: (axis * (axis.x * k), axis * (axis.y * k), axis * (axis.z * k)))
    }

    private func skew(_ d: SIMD3<Double>) -> simd_double3x3 {
        // [d]× with columns: [d]× · x = d × x.
        simd_double3x3(columns: (SIMD3<Double>(0, d.z, -d.y), SIMD3<Double>(-d.z, 0, d.x), SIMD3<Double>(d.y, -d.x, 0)))
    }

    private func blockMultiply(_ blocks: (diag: [Block6], lower: [Block6]), _ x: [Vec6]) -> [Vec6] {
        let count = blocks.diag.count
        var result = [Vec6](repeating: .zero, count: count)
        for b in 0..<count {
            result[b] = result[b] + blocks.diag[b] * x[b]
            if b > 0 {
                result[b] = result[b] + blocks.lower[b] * x[b - 1]
                result[b - 1] = result[b - 1] + blocks.lower[b].transposed * x[b]
            }
        }
        return result
    }
}

// MARK: - Acceleration history and shock response

/// The retained body's acceleration over an impact, sampled at the solver's steps.
struct StructuralAccelerationHistory {
    private(set) var times: [Float] = []
    private(set) var linear: [SIMD3<Float>] = []
    private(set) var angular: [SIMD3<Float>] = []

    mutating func append(time: Float, linear a: SIMD3<Float>, angular alpha: SIMD3<Float>) {
        times.append(time); linear.append(a); angular.append(alpha)
    }

    var duration: Float { times.last ?? 0 }

    /// A half-sine pulse of the given peak and duration, for rigid-body contacts.
    static func halfSine(peakLinear: SIMD3<Float>, peakAngular: SIMD3<Float>, duration: Float) -> StructuralAccelerationHistory {
        var history = StructuralAccelerationHistory()
        let samples = 48
        for index in 0...samples {
            let t = duration * Float(index) / Float(samples)
            let shape = sin(Float.pi * t / max(1e-5, duration))
            history.append(time: t, linear: peakLinear * shape, angular: peakAngular * shape)
        }
        return history
    }

    /// Peak pseudo-acceleration of an oscillator of the given period driven by this history
    /// — the shock response spectrum at that period, as a vector at its largest instant.
    /// A member that responds slowly sees a filtered, smaller load; one near resonance with
    /// the pulse sees up to about twice it. Free vibration after the pulse is followed for
    /// one more period so a late peak is not missed.
    func shockResponse(period: Float, damping: Float) -> (linear: SIMD3<Float>, angular: SIMD3<Float>) {
        guard times.count > 1, period > 1e-5 else { return (linear.last ?? .zero, angular.last ?? .zero) }
        // An oscillator much quicker than the history's own sampling follows it: its peak is
        // the input's peak, with no need to integrate at its period.
        let sampleStep = duration / Float(max(1, times.count - 1))
        if period < 4 * sampleStep {
            var peakIndex = 0
            var peakMagnitude: Float = -1
            for index in linear.indices where simd_length_squared(linear[index]) > peakMagnitude {
                peakMagnitude = simd_length_squared(linear[index]); peakIndex = index
            }
            return (linear[peakIndex], angular[peakIndex])
        }
        let omega = 2 * Float.pi / period
        var x = SIMD3<Float>.zero, v = SIMD3<Float>.zero
        var xa = SIMD3<Float>.zero, va = SIMD3<Float>.zero
        var peak = (linear: SIMD3<Float>.zero, angular: SIMD3<Float>.zero)
        var peakMagnitude: Float = 0
        let end = (times.last ?? 0) + period
        var t: Float = 0
        var sample = 0
        let dt = max(period / 24, sampleStep / 4)
        while t < end {
            while sample + 1 < times.count && times[sample + 1] <= t { sample += 1 }
            let inputLinear = t <= (times.last ?? 0) ? linear[sample] : .zero
            let inputAngular = t <= (times.last ?? 0) ? angular[sample] : .zero
            // x'' + 2ζωx' + ω²x = input; the static response to `input` is input/ω².
            let accel = inputLinear - x * (omega * omega) - v * (2 * damping * omega)
            v += accel * dt; x += v * dt
            let accelA = inputAngular - xa * (omega * omega) - va * (2 * damping * omega)
            va += accelA * dt; xa += va * dt
            let pseudo = x * (omega * omega)
            if simd_length(pseudo) > peakMagnitude {
                peakMagnitude = simd_length(pseudo)
                peak = (pseudo, xa * (omega * omega))
            }
            t += dt
        }
        return peak
    }
}

// MARK: - Small dense linear algebra (allocation-free 6-vectors and 6×6 blocks)

struct Vec6 {
    var top: SIMD3<Double>
    var bottom: SIMD3<Double>
    static let zero = Vec6(top: .zero, bottom: .zero)
    static func + (lhs: Vec6, rhs: Vec6) -> Vec6 { Vec6(top: lhs.top + rhs.top, bottom: lhs.bottom + rhs.bottom) }
    static func - (lhs: Vec6, rhs: Vec6) -> Vec6 { Vec6(top: lhs.top - rhs.top, bottom: lhs.bottom - rhs.bottom) }
    static func * (lhs: Vec6, rhs: Double) -> Vec6 { Vec6(top: lhs.top * rhs, bottom: lhs.bottom * rhs) }
    /// Element-wise product (diagonal mass times a vector).
    static func * (lhs: Vec6, rhs: Vec6) -> Vec6 { Vec6(top: lhs.top * rhs.top, bottom: lhs.bottom * rhs.bottom) }
    func dot(_ other: Vec6) -> Double { simd_dot(top, other.top) + simd_dot(bottom, other.bottom) }
}

extension simd_double3x3 {
    static let zero3 = simd_double3x3()
}

struct Block6 {
    var tl: simd_double3x3
    var tr: simd_double3x3
    var bl: simd_double3x3
    var br: simd_double3x3
    static let zero = Block6(tl: .zero3, tr: .zero3, bl: .zero3, br: .zero3)

    static func outer(_ a: Vec6, _ b: Vec6) -> Block6 {
        func o(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> simd_double3x3 {
            simd_double3x3(columns: (x * y.x, x * y.y, x * y.z))
        }
        return Block6(tl: o(a.top, b.top), tr: o(a.top, b.bottom), bl: o(a.bottom, b.top), br: o(a.bottom, b.bottom))
    }
    var transposed: Block6 { Block6(tl: tl.transpose, tr: bl.transpose, bl: tr.transpose, br: br.transpose) }
    static func + (lhs: Block6, rhs: Block6) -> Block6 {
        Block6(tl: lhs.tl + rhs.tl, tr: lhs.tr + rhs.tr, bl: lhs.bl + rhs.bl, br: lhs.br + rhs.br)
    }
    static func - (lhs: Block6, rhs: Block6) -> Block6 {
        Block6(tl: lhs.tl - rhs.tl, tr: lhs.tr - rhs.tr, bl: lhs.bl - rhs.bl, br: lhs.br - rhs.br)
    }
    static func * (lhs: Block6, rhs: Double) -> Block6 {
        Block6(tl: lhs.tl * rhs, tr: lhs.tr * rhs, bl: lhs.bl * rhs, br: lhs.br * rhs)
    }
    static func * (lhs: Block6, rhs: Block6) -> Block6 {
        Block6(tl: lhs.tl * rhs.tl + lhs.tr * rhs.bl, tr: lhs.tl * rhs.tr + lhs.tr * rhs.br,
               bl: lhs.bl * rhs.tl + lhs.br * rhs.bl, br: lhs.bl * rhs.tr + lhs.br * rhs.br)
    }
    static func * (lhs: Block6, rhs: Vec6) -> Vec6 {
        Vec6(top: lhs.tl * rhs.top + lhs.tr * rhs.bottom, bottom: lhs.bl * rhs.top + lhs.br * rhs.bottom)
    }
    func addingDiagonal(_ d: Vec6) -> Block6 {
        var copy = self
        copy.tl = tl + simd_double3x3(diagonal: d.top)
        copy.br = br + simd_double3x3(diagonal: d.bottom)
        return copy
    }

    /// Cholesky factor of an SPD 6×6 block together with its inverse (both lower-
    /// triangular), nil when not positive definite.
    func choleskyWithInverse() -> (factor: Block6, inverse: Block6)? {
        guard let l11 = Block6.cholesky3(tl) else { return nil }
        let l11Inverse = Block6.lowerInverse3(l11)
        let l21 = bl * l11Inverse.transpose
        let schur = br - l21 * l21.transpose
        guard let l22 = Block6.cholesky3(schur) else { return nil }
        let l22Inverse = Block6.lowerInverse3(l22)
        let factor = Block6(tl: l11, tr: .zero3, bl: l21, br: l22)
        let inverse = Block6(tl: l11Inverse, tr: .zero3, bl: (l22Inverse * l21 * l11Inverse) * -1, br: l22Inverse)
        return (factor, inverse)
    }

    private static func cholesky3(_ m: simd_double3x3) -> simd_double3x3? {
        // m[column][row]
        let a00 = m[0][0], a10 = m[0][1], a20 = m[0][2]
        let a11 = m[1][1], a21 = m[1][2], a22 = m[2][2]
        guard a00 > 1e-300 else { return nil }
        let l00 = a00.squareRoot()
        let l10 = a10 / l00, l20 = a20 / l00
        let d1 = a11 - l10 * l10
        guard d1 > 1e-300 else { return nil }
        let l11 = d1.squareRoot()
        let l21 = (a21 - l20 * l10) / l11
        let d2 = a22 - l20 * l20 - l21 * l21
        guard d2 > 1e-300 else { return nil }
        let l22 = d2.squareRoot()
        return simd_double3x3(columns: (SIMD3<Double>(l00, l10, l20), SIMD3<Double>(0, l11, l21), SIMD3<Double>(0, 0, l22)))
    }

    private static func lowerInverse3(_ l: simd_double3x3) -> simd_double3x3 {
        let l00 = l[0][0], l10 = l[0][1], l20 = l[0][2], l11 = l[1][1], l21 = l[1][2], l22 = l[2][2]
        let i00 = 1 / l00, i11 = 1 / l11, i22 = 1 / l22
        let i10 = -l10 * i00 * i11
        let i21 = -l21 * i11 * i22
        let i20 = -(l20 * i00 + l21 * i10) * i22
        return simd_double3x3(columns: (SIMD3<Double>(i00, i10, i20), SIMD3<Double>(0, i11, i21), SIMD3<Double>(0, 0, i22)))
    }
}

/// Cholesky factorisation of a symmetric positive-definite block-tridiagonal matrix with
/// 6×6 blocks: `diag[i]` on the diagonal and `lower[i] = K(i, i−1)` below it.
struct BlockTridiagonalCholesky {
    private var inverses: [Block6]
    /// W_i = K(i, i−1) · L_{i−1}^−T
    private var coupling: [Block6]

    init?(diag: [Block6], lower: [Block6]) {
        guard !diag.isEmpty, lower.count == diag.count else { return nil }
        inverses = []
        inverses.reserveCapacity(diag.count)
        coupling = [Block6](repeating: .zero, count: diag.count)
        for i in diag.indices {
            var block = diag[i]
            if i > 0 {
                let w = lower[i] * inverses[i - 1].transposed
                coupling[i] = w
                block = block - w * w.transposed
            }
            guard let factor = block.choleskyWithInverse() else { return nil }
            inverses.append(factor.inverse)
        }
    }

    func solve(_ b: [Vec6]) -> [Vec6] {
        let count = inverses.count
        var y = [Vec6](repeating: .zero, count: count)
        for i in 0..<count {
            var rhs = b[i]
            if i > 0 { rhs = rhs - coupling[i] * y[i - 1] }
            y[i] = inverses[i] * rhs
        }
        var x = [Vec6](repeating: .zero, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            var rhs = y[i]
            if i < count - 1 { rhs = rhs - coupling[i + 1].transposed * x[i + 1] }
            x[i] = inverses[i].transposed * rhs
        }
        return x
    }
}
