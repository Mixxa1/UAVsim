import Foundation
import simd

// MARK: - Component identity

enum VehicleBodySide: String, Hashable {
    case left
    case right
}

enum VehicleWingSegment: String, Hashable {
    case root
    case outer
}

/// Structural/functional role of a component inside the airframe graph.
/// Slots are free-form strings ("FL", "M5", "gearL"...) so the same model
/// covers quads, hexes, fixed-wing and arbitrary workbench builds.
enum VehicleComponentKind: Hashable {
    case frame
    case fuselage
    case arm(slot: String)
    case motor(slot: String)
    case propeller(slot: String)
    case battery
    case flightController
    case esc
    case radio
    case cameraGimbal
    case payloadMount
    case wingSection(side: VehicleBodySide, segment: VehicleWingSegment)
    case tailSection
    case horizontalTail
    case verticalTail
    case elevator
    case rudder
    case landingGear(slot: String)

    /// Structural components carry contact geometry and shed impact energy;
    /// internal ones (battery, FC, radio...) are damaged through proximity.
    var isStructural: Bool {
        switch self {
        case .frame, .fuselage, .arm, .propeller, .wingSection, .tailSection,
             .horizontalTail, .verticalTail, .elevator, .rudder,
             .landingGear, .motor:
            return true
        case .battery, .flightController, .esc, .radio, .cameraGimbal, .payloadMount:
            return false
        }
    }
}

/// Failure behaviors a component can exhibit. Only `totalFailure`
/// (integrity == 0) is acted on by the impact phase; the rest are declared
/// now so the damage->flight-physics and internal-failure phases can attach
/// behavior without reshaping the graph.
enum ComponentFailureMode: String, Hashable {
    case efficiencyLoss
    case jam
    case intermittent
    case holdLastCommand
    case totalFailure
}

/// Structural attachment is intentionally independent from component
/// integrity: an intact wing can leave the aircraft because its root joint
/// failed, while a badly cracked fairing can remain attached.
enum VehicleAttachmentState: String, Hashable, Codable {
    case attached
    case loosened
    case partiallyDetached
    case detached
}

enum VehicleConnectionType: String, Hashable, Codable {
    case rigid
    case bolted
    case bonded
    case hinge
    case compositeTransition
    case shaft
    case suspended
    case landingMount
    case payloadRelease
}

struct VehicleComponentDeformation: Hashable {
    /// Permanent rotations in the body frame. These are deliberately small
    /// angles; the visual and propulsion layers consume them as transforms.
    var bendRadians: SIMD3<Float> = .zero
    var translationMeters: SIMD3<Float> = .zero
    var vibrationScale: Float = 0.0

    static let none = VehicleComponentDeformation()
}

struct VehicleComponentPerformance: Hashable {
    var forceScale: Float = 1.0
    var torqueScale: Float = 1.0
    var efficiencyScale: Float = 1.0
    var responseSpeedScale: Float = 1.0
    var rangeScale: Float = 1.0
    var dragScale: Float = 1.0
    var vibrationScale: Float = 0.0

    static let nominal = VehicleComponentPerformance()
}

/// A joint has its own limits and damage state. This is the key distinction
/// between merely losing component efficiency and physically shedding a
/// connected subtree of the vehicle.
struct VehicleStructuralConnection: Hashable {
    let id: String
    let parentComponentID: String
    let childComponentID: String
    let connectionType: VehicleConnectionType
    let tensileLimitN: Float
    let shearLimitN: Float
    let bendingLimitNm: Float
    let torsionLimitNm: Float
    var residualStrength: Float = 1.0
    var stiffnessScale: Float = 1.0
    var state: VehicleAttachmentState = .attached
    /// Where the joint is, which way it is loaded, and what it can take. Every connection
    /// built by the graph has one; see `VehicleJointSection`.
    var section: VehicleJointSection?
    /// Whether the joint's bending capacity is gone (a hanging, folded panel) or the child
    /// has separated.
    var fracture: VehicleJointFracture = .intact
    /// Miner's sum of cyclic damage (1 = fatigue rupture).
    var fatigueDamage: Float = 0
    /// Plastic hinge rotation already spent, radians (equivalent magnitude). Drives the
    /// strength lost to yielding and the remaining rotation before rupture.
    var plasticRotationSpent: Float = 0
}

// MARK: - Contact geometry

/// One collision proxy sphere, body-frame (physics convention: +Y up,
/// -Z forward), positioned relative to the same origin as
/// the original visual body frame. A fixed rest offset relates that frame
/// to `DroneState.position`, the original ground/gear reference point.
/// One outside part of the airframe as the air sees it when the airframe turns: its box,
/// where it sits and which way it faces, in the body frame, deformation included.
struct RotationalDragElement: Hashable {
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
    let rotation: simd_quatf
}

extension VehicleComponentGraph {
    /// The attached outside parts, placed as deformed. Batteries, controllers, ESCs and radios
    /// sit inside the skin and meet no air of their own.
    func rotationalDragElements() -> [RotationalDragElement] {
        let transforms = deformationTransforms()
        return attachedComponents.compactMap { component in
            switch component.kind {
            case .battery, .flightController, .esc, .radio: return nil
            default: break
            }
            let transform = transforms[component.id] ?? matrix_identity_float4x4
            let p = transform * SIMD4<Float>(component.localPosition, 1)
            return RotationalDragElement(center: SIMD3<Float>(p.x, p.y, p.z),
                                         halfExtents: component.boundingHalfExtents,
                                         rotation: simd_quatf(transform))
        }
    }
}

struct VehicleContactSphere: Hashable {
    let componentID: String
    let offset: SIMD3<Float>
    let radius: Float
    var isGroundSupport: Bool = false
    var supportIntegrity: Float = 1

    func worldCenter(position: SIMD3<Float>, orientation: simd_quatf) -> SIMD3<Float> {
        position + simd_act(orientation, offset)
    }
}

/// The aircraft's physical contact profile: the sphere set replacing the
/// single legacy `collisionRadius` sphere for narrow-phase contact (ground
/// and obstacles). `boundingRadius` also gives navigation a conservative full-airframe envelope.
struct VehicleContactProfile: Hashable {
    let spheres: [VehicleContactSphere]
    /// Radius of the sphere (centered at the state origin) that encloses all
    /// contact spheres — used to pad spatial queries.
    let boundingRadius: Float
    /// Immutable offset from the original gear reference to the body frame.
    /// Removing a support changes the body's resting height, not its origin.
    var referenceGroundOffset: Float? = nil

    static let empty = VehicleContactProfile(spheres: [], boundingRadius: 0.0)

    var isEmpty: Bool { spheres.isEmpty }

    /// Lowest point (world Y) of the profile at the given pose. The legacy
    /// ground clamp compared `position.y` against the support height; the
    /// contact-aware clamp compares this instead, so a rolled airframe rests
    /// on its wingtip/prop rather than sinking to the gear reference.
    func lowestPointY(position: SIMD3<Float>, orientation: simd_quatf) -> Float {
        guard !spheres.isEmpty else { return position.y }
        var lowest = Float.greatestFiniteMagnitude
        for sphere in spheres {
            let bottom = sphere.worldCenter(position: position, orientation: orientation).y - sphere.radius
            if bottom < lowest {
                lowest = bottom
            }
        }
        return lowest
    }

    /// How far below the state origin the profile reaches at this attitude
    /// (>= 0). `position.y - supportY >= penetrationDepth` keeps every sphere
    /// clear of the support plane.
    func lowestPointOffset(orientation: simd_quatf) -> Float {
        max(0.0, -lowestPointY(position: .zero, orientation: orientation))
    }

    /// The airframe's ground-rest attitude: identity for everything except a
    /// tailsitter, which stands nose-up (pitch +90°) on its tail.
    static func restOrientation(for style: AirframeStyle) -> simd_quatf {
        guard style == .tailsitterVTOL else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1.0, 0.0, 0.0))
    }

    /// Position of the original gear reference when the surviving geometry
    /// touches the surface. It can become negative after losing the gear;
    /// recomputing the reference from surviving parts creates phantom support.
    func groundClearanceOffset(orientation: simd_quatf, restOrientation: simd_quatf) -> Float {
        if let referenceGroundOffset, !isEmpty {
            return -lowestPointY(position: .zero, orientation: orientation) - referenceGroundOffset
        }
        return max(0.0, lowestPointOffset(orientation: orientation) - lowestPointOffset(orientation: restOrientation))
    }

    func lowestContact(
        position: SIMD3<Float>,
        orientation: simd_quatf
    ) -> (sphere: VehicleContactSphere, point: SIMD3<Float>)? {
        var result: (VehicleContactSphere, SIMD3<Float>)?
        var lowestY = Float.greatestFiniteMagnitude
        for sphere in spheres {
            let center = sphere.worldCenter(position: position, orientation: orientation)
            let point = center - SIMD3<Float>(0.0, sphere.radius, 0.0)
            if point.y < lowestY {
                lowestY = point.y
                result = (sphere, point)
            }
        }
        return result
    }

    /// Structural detachment also removes the corresponding collision
    /// proxies from the parent vehicle. The detached body's own SceneKit
    /// rigid body receives separate collision geometry.
    func removing(componentIDs: Set<String>) -> VehicleContactProfile {
        let remaining = spheres.filter { !componentIDs.contains($0.componentID) }
        guard !remaining.isEmpty else { return .empty }
        let radius = remaining.reduce(Float(0.0)) { partial, sphere in
            max(partial, simd_length(sphere.offset) + sphere.radius)
        }
        return VehicleContactProfile(spheres: remaining, boundingRadius: radius,
            referenceGroundOffset: referenceGroundOffset)
    }

    func applyingDeformations(from graph: VehicleComponentGraph) -> VehicleContactProfile {
        guard !spheres.isEmpty else { return self }
        let transforms = graph.deformationTransforms()
        let deformed = spheres.map { sphere -> VehicleContactSphere in
            guard let component = graph.component(id: sphere.componentID), component.isAttached else {
                return sphere
            }
            let p = (transforms[component.id] ?? matrix_identity_float4x4) * SIMD4<Float>(sphere.offset, 1)
            return VehicleContactSphere(
                componentID: sphere.componentID,
                offset: SIMD3<Float>(p.x, p.y, p.z),
                radius: sphere.radius,
                isGroundSupport: sphere.isGroundSupport,
                supportIntegrity: min(component.integrity, component.stiffnessScale, component.residualStrength)
            )
        }
        let radius = deformed.reduce(Float(0.0)) {
            max($0, simd_length($1.offset) + $1.radius)
        }
        return VehicleContactProfile(spheres: deformed, boundingRadius: max(boundingRadius, radius),
            referenceGroundOffset: referenceGroundOffset)
    }
}

// MARK: - Component

struct VehicleComponent: Hashable {
    let id: String
    let kind: VehicleComponentKind
    let parentID: String?
    let massKg: Float
    /// Body-frame center of the component, meters, relative to the state
    /// origin (ground/gear reference — NOT the visual bounds center).
    let localPosition: SIMD3<Float>
    /// Half-extents of the component's own bounding box, for inertia and
    /// damage-proximity queries.
    let boundingHalfExtents: SIMD3<Float>
    /// Impact energy (J) that takes this component from pristine to
    /// destroyed in a single hit. Accumulated wear lowers the effective
    /// residual threshold through `residualStrength`.
    let strengthJ: Float
    var integrity: Float
    var residualStrength: Float = 1.0
    var stiffnessScale: Float = 1.0
    var deformation: VehicleComponentDeformation = .none
    var attachmentState: VehicleAttachmentState = .attached
    var performance: VehicleComponentPerformance = .nominal
    /// Projection into the legacy `DamageComponent` enum so the existing
    /// damage overlay / diagnostics / thermal model keep working unchanged.
    let legacyComponent: DamageComponent?
    /// Components that stop functioning when this one fails (by id).
    let functionalDependencies: [String]
    let failureModes: [ComponentFailureMode]

    var isDestroyed: Bool { integrity <= 0.0001 }
    var isAttached: Bool { attachmentState != .detached }

    /// Reference area and stalling force coefficient, if this component is a lifting
    /// surface at all. `nil` for everything that does not make lift.
    ///
    /// This lives on the component because two places need the same answer and must not
    /// be allowed to drift: `UAVStructuralLoadSolver` charges each surface its share of
    /// the airframe's lift, and `makeConnections` sizes the joint that has to hold that
    /// share. When the two disagree, joints are sized for a load the solver never applies
    /// and surfaces fail with nothing to hit.
    var liftingSurface: (area: Float, maximumCoefficient: Float)? {
        let half = boundingHalfExtents
        switch kind {
        case .wingSection:
            return (max(0.005, half.x * half.z * 4.0), 1.15)
        case .horizontalTail:
            return (max(0.003, half.x * half.z * 4.0), 0.72)
        case .verticalTail:
            return (max(0.003, half.y * half.z * 4.0), 0.72)
        case .elevator:
            return (max(0.002, half.x * half.z * 4.0), 0.48)
        case .rudder:
            return (max(0.002, half.y * half.z * 4.0), 0.48)
        case .motor, .propeller, .frame, .fuselage, .arm, .tailSection, .battery,
             .flightController, .esc, .radio, .cameraGimbal, .payloadMount, .landingGear:
            return nil
        }
    }
}

// MARK: - Mass properties

/// Rigid-body summary the physics engine consumes: total mass, CoM offset
/// from the state origin, and a diagonal inertia tensor about the CoM in
/// body axes. Recomputed whenever deformation or attachment changes.
struct VehicleMassProperties: Hashable {
    let totalMassKg: Float
    let centerOfMassOffset: SIMD3<Float>
    let inertiaDiagonal: SIMD3<Float>

    static let fallback = VehicleMassProperties(
        totalMassKg: 1.0,
        centerOfMassOffset: .zero,
        inertiaDiagonal: SIMD3<Float>(repeating: 0.02)
    )
}

struct VehicleDetachedSubtree: Hashable {
    let rootComponentID: String
    let components: [VehicleComponent]
    let massProperties: VehicleMassProperties
    let localBoundsCenter: SIMD3<Float>
    let localBoundsHalfExtents: SIMD3<Float>

    var componentIDs: Set<String> { Set(components.map(\.id)) }
    var legacyComponents: Set<DamageComponent> {
        Set(components.compactMap(\.legacyComponent))
    }
}

// MARK: - Graph

struct VehicleComponentGraph: Hashable {
    /// Largest permanent hinge rotation a joint can hold, radians. A panel folded past this
    /// has torn free; the fracture solver separates it before it gets here.
    static let maximumHingeRotation: Float = 170 * .pi / 180

    /// The joint about which a component's permanent rotation pivots: its connection's
    /// section anchor, or — for a graph restored without sections — its parent's centre.
    func hingeAnchor(for component: VehicleComponent) -> SIMD3<Float> {
        if let anchor = connection(childComponentID: component.id)?.section?.anchor { return anchor }
        return component.parentID.flatMap { self.component(id: $0)?.localPosition } ?? component.localPosition
    }

    private func localDeformation(of current: VehicleComponent) -> simd_float4x4 {
        let bend = current.deformation.bendRadians
        let angle = simd_length(bend)
        let rotation = angle > 0.0001
            ? simd_quatf(angle: min(Self.maximumHingeRotation, angle), axis: bend / angle)
            : simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let anchor = hingeAnchor(for: current)
        var local = simd_float4x4(rotation)
        local.columns.3 = SIMD4<Float>(anchor - simd_act(rotation, anchor) + current.deformation.translationMeters, 1)
        return local
    }

    /// Permanent body-frame transform, including every ancestor on the load
    /// path. A motor on a bent wing moves with that wing in both physics and
    /// rendering. Each bend pivots at its own joint, not the world origin.
    func deformationTransform(for componentID: String) -> simd_float4x4 {
        var chain: [VehicleComponent] = []
        var cursor = component(id: componentID)
        var visited: Set<String> = []
        while let current = cursor, visited.insert(current.id).inserted {
            chain.append(current)
            cursor = current.parentID.flatMap { component(id: $0) }
        }
        var result = matrix_identity_float4x4
        for current in chain.reversed() {
            result = result * localDeformation(of: current)
        }
        return result
    }

    /// Every component's deformation transform in one pass — parents are composed once and
    /// reused by their children, instead of re-walking the chain per component.
    func deformationTransforms() -> [String: simd_float4x4] {
        var result: [String: simd_float4x4] = [:]
        result.reserveCapacity(components.count)
        func resolve(_ component: VehicleComponent, depth: Int) -> simd_float4x4 {
            if let known = result[component.id] { return known }
            let parentTransform: simd_float4x4
            if depth < 64, let parentID = component.parentID, let parent = self.component(id: parentID) {
                parentTransform = resolve(parent, depth: depth + 1)
            } else {
                parentTransform = matrix_identity_float4x4
            }
            let transform = parentTransform * localDeformation(of: component)
            result[component.id] = transform
            return transform
        }
        for component in components { _ = resolve(component, depth: 0) }
        return result
    }

    var hasDeformation: Bool {
        components.contains {
            simd_length_squared($0.deformation.bendRadians) > 1e-10 ||
                simd_length_squared($0.deformation.translationMeters) > 1e-12
        }
    }

    func deformedPosition(_ point: SIMD3<Float>, attachedTo id: String) -> SIMD3<Float> {
        let p = deformationTransform(for: id) * SIMD4<Float>(point, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    private(set) var components: [VehicleComponent]
    private(set) var structuralConnections: [VehicleStructuralConnection]
    private(set) var massPropertiesRevision: UInt64
    private var indexByID: [String: Int]
    private var connectionIndexByChildID: [String: Int]

    static let empty = VehicleComponentGraph(components: [])

    init(
        components: [VehicleComponent],
        structuralConnections: [VehicleStructuralConnection]? = nil,
        massPropertiesRevision: UInt64 = 0,
        /// The aircraft's takeoff mass, for sizing the joints that carry flight loads.
        ///
        /// ⚠️ Not the same number as the components add up to, and the difference is not
        /// small: the graph's own budget leaves out fuel and payload, so an RQ-7B whose
        /// components total 77 kg is a 170 kg aircraft and an MQ-9B's 2,650 kg of structure
        /// belongs to a 5,670 kg one. Sizing a mount off the structural budget would size
        /// it for half an aircraft. Zero means "not supplied" and the mount keeps the
        /// strength its impact energy gives it.
        designTakeoffMassKg: Float = 0.0,
        /// Designed sections of discretised members (wing, tail, boom, arm stations), keyed
        /// by child component id. Every other joint gets an attachment section derived from
        /// its scalar limits.
        sections: [String: VehicleJointSection] = [:],
        material: VehicleStructuralMaterial = .aluminium
    ) {
        self.components = components
        self.massPropertiesRevision = massPropertiesRevision
        var index: [String: Int] = [:]
        index.reserveCapacity(components.count)
        for (offset, component) in components.enumerated() {
            index[component.id] = offset
        }
        self.indexByID = index

        let resolvedConnections = structuralConnections
            ?? Self.makeConnections(for: components, designTakeoffMassKg: designTakeoffMassKg,
                                    sections: sections, material: material)
        self.structuralConnections = resolvedConnections
        var connectionIndex: [String: Int] = [:]
        connectionIndex.reserveCapacity(resolvedConnections.count)
        for (offset, connection) in resolvedConnections.enumerated() {
            // Malformed/custom topology must degrade deterministically rather
            // than trap in Dictionary(uniqueKeysWithValues:).
            if connectionIndex[connection.childComponentID] == nil {
                connectionIndex[connection.childComponentID] = offset
            }
        }
        self.connectionIndexByChildID = connectionIndex
    }

    var isEmpty: Bool { components.isEmpty }

    func component(id: String) -> VehicleComponent? {
        indexByID[id].map { components[$0] }
    }

    func integrity(id: String) -> Float {
        guard let component = component(id: id) else { return 1.0 }
        return component.isAttached ? component.integrity : 0.0
    }

    var attachedComponents: [VehicleComponent] {
        components.filter(\.isAttached)
    }

    func connection(childComponentID: String) -> VehicleStructuralConnection? {
        connectionIndexByChildID[childComponentID].map { structuralConnections[$0] }
    }

    mutating func setIntegrity(_ value: Float, id: String) {
        guard let index = indexByID[id] else { return }
        components[index].integrity = value.clamped(to: 0.0...1.0)
    }

    mutating func applyRuntimeState(from previous: VehicleComponentGraph) {
        for index in components.indices {
            guard let old = previous.component(id: components[index].id) else { continue }
            components[index].integrity = old.integrity
            components[index].residualStrength = old.residualStrength
            components[index].stiffnessScale = old.stiffnessScale
            components[index].deformation = old.deformation
            components[index].attachmentState = old.attachmentState
            components[index].performance = old.performance
        }
        for index in structuralConnections.indices {
            guard let old = previous.connection(childComponentID: structuralConnections[index].childComponentID) else {
                continue
            }
            structuralConnections[index].residualStrength = old.residualStrength
            structuralConnections[index].stiffnessScale = old.stiffnessScale
            structuralConnections[index].state = old.state
            structuralConnections[index].fracture = old.fracture
            structuralConnections[index].fatigueDamage = old.fatigueDamage
            structuralConnections[index].plasticRotationSpent = old.plasticRotationSpent
        }
        massPropertiesRevision = previous.massPropertiesRevision
    }

    mutating func restoreComponentRuntime(
        id: String,
        integrity: Float,
        residualStrength: Float,
        stiffnessScale: Float,
        deformation: VehicleComponentDeformation,
        attachmentState: VehicleAttachmentState,
        performance: VehicleComponentPerformance
    ) {
        guard let index = indexByID[id] else { return }
        components[index].integrity = integrity.clamped(to: 0.0...1.0)
        components[index].residualStrength = residualStrength.clamped(to: 0.0...1.0)
        components[index].stiffnessScale = stiffnessScale.clamped(to: 0.05...1.0)
        components[index].deformation = deformation
        components[index].attachmentState = attachmentState
        components[index].performance = performance
    }

    mutating func restoreConnectionRuntime(
        childComponentID: String,
        residualStrength: Float,
        stiffnessScale: Float,
        state: VehicleAttachmentState
    ) {
        guard let index = connectionIndexByChildID[childComponentID] else { return }
        structuralConnections[index].residualStrength = residualStrength.clamped(to: 0.0...1.0)
        structuralConnections[index].stiffnessScale = stiffnessScale.clamped(to: 0.0...1.0)
        structuralConnections[index].state = state
        // Snapshots predate the fracture field: a joint saved as partially detached with
        // strength left was a folded panel; one with none had come apart.
        if state == .detached || residualStrength <= 0.015 {
            structuralConnections[index].fracture = .separated
        } else if state == .partiallyDetached {
            structuralConnections[index].fracture = .hinged
        }
    }

    mutating func restoreMassPropertiesRevision(_ revision: UInt64) {
        massPropertiesRevision = revision
    }

    func components(within radius: Float, of point: SIMD3<Float>) -> [VehicleComponent] {
        attachedComponents.filter { component in
            // Distance to the component's bounding box, not just its center —
            // a wing's center can be a meter away from a wingtip strike that
            // clearly belongs to it.
            let delta = simd_abs(point - component.localPosition) - component.boundingHalfExtents
            let outside = simd_max(delta, SIMD3<Float>(repeating: 0.0))
            return simd_length(outside) <= radius
        }
    }

    // MARK: Mass properties

    var massProperties: VehicleMassProperties {
        Self.massProperties(for: attachedComponents, transforms: deformationTransforms())
    }

    /// Rigid-body properties of the still-attached airframe after excluding
    /// a subtree that is about to separate during the current impact.  The
    /// graph is intentionally not mutated here: the impact solver needs both
    /// bodies' properties before the presentation layer performs the actual
    /// detach operation.
    func massProperties(excludingComponentIDs excludedIDs: Set<String>) -> VehicleMassProperties {
        Self.massProperties(
            for: attachedComponents.filter { !excludedIDs.contains($0.id) }, transforms: deformationTransforms()
        )
    }

    /// Rigid-body properties of an arbitrary set of this graph's components.
    func massProperties(of componentIDs: Set<String>) -> VehicleMassProperties {
        Self.massProperties(for: components.filter { componentIDs.contains($0.id) },
                            transforms: deformationTransforms())
    }

    private static func massProperties(for components: [VehicleComponent],
                                       transforms: [String: simd_float4x4]) -> VehicleMassProperties {
        guard !components.isEmpty else { return .fallback }

        var totalMass: Float = 0.0
        var weightedPosition = SIMD3<Float>(repeating: 0.0)
        func position(_ component: VehicleComponent) -> SIMD3<Float> {
            let p = (transforms[component.id] ?? matrix_identity_float4x4) * SIMD4<Float>(component.localPosition, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        for component in components {
            totalMass += component.massKg
            weightedPosition += position(component) * component.massKg
        }
        guard totalMass > 0.0001 else { return .fallback }
        let centerOfMass = weightedPosition / totalMass

        var inertia = SIMD3<Float>(repeating: 0.0)
        for component in components {
            let m = component.massKg
            let d = position(component) - centerOfMass
            let h = component.boundingHalfExtents
            let matrix = transforms[component.id] ?? matrix_identity_float4x4
            let localInertia = SIMD3<Float>(h.y * h.y + h.z * h.z, h.x * h.x + h.z * h.z, h.x * h.x + h.y * h.y) * (m / 3)
            let x = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
            let y = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
            let z = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            let rotatedInertia = x * x * localInertia.x + y * y * localInertia.y + z * z * localInertia.z
            // Parallel-axis point-mass term + the component's own box inertia
            // (1/12·m·(a²+b²) with full extents a=2h → m/3·(h²+h²)).
            inertia += SIMD3<Float>(d.y * d.y + d.z * d.z, d.x * d.x + d.z * d.z, d.x * d.x + d.y * d.y) * m + rotatedInertia
        }
        // Floor keeps the contact-impulse denominator finite for degenerate
        // (tiny/single-component) graphs.
        let floorValue = max(0.0005, totalMass * 0.0004)
        inertia = simd_max(inertia, SIMD3<Float>(repeating: floorValue))

        return VehicleMassProperties(
            totalMassKg: totalMass,
            centerOfMassOffset: centerOfMass,
            inertiaDiagonal: inertia
        )
    }

    // MARK: Damage

    struct ImpactDamageEntry {
        let componentID: String
        let legacyComponent: DamageComponent?
        let integrityBefore: Float
        let integrityAfter: Float
        let residualStrengthBefore: Float
        let residualStrengthAfter: Float
        let stiffnessBefore: Float
        let stiffnessAfter: Float
    }

    struct ConnectionDamageEntry {
        let connectionID: String
        let childComponentID: String
        let residualStrengthBefore: Float
        let residualStrengthAfter: Float
        let stateBefore: VehicleAttachmentState
        let stateAfter: VehicleAttachmentState
    }

    /// Localized damage: the struck component absorbs the full normalized
    /// energy; neighbors inside `spreadRadius` take a distance-falloff share.
    /// Accumulated damage lowers the effective threshold — an already-cracked
    /// part fails from a smaller hit. Returns the per-component deltas so the
    /// caller can log/report them.
    mutating func applyImpact(
        primaryComponentID: String,
        energyJ: Float,
        damageFactor: Float,
        spreadRadius: Float,
        contactPointBody: SIMD3<Float>? = nil,
        elasticReserveScale: Float = 1.0,
        impulseBody: SIMD3<Float> = .zero
    ) -> [ImpactDamageEntry] {
        guard energyJ > 0.0, damageFactor > 0.0,
              let primary = component(id: primaryComponentID) else {
            return []
        }

        var entries: [ImpactDamageEntry] = []
        let impactPoint = contactPointBody ?? primary.localPosition
        var neighbors = components(within: max(0.0, spreadRadius), of: impactPoint)
        if !neighbors.contains(where: { $0.id == primary.id }) {
            neighbors.append(primary)
        }
        let weightedTargets: [(VehicleComponent, Float)] = neighbors.compactMap { target in
            let weight: Float
            if target.id == primaryComponentID {
                weight = 1.0
            } else {
                let delta = simd_abs(impactPoint - target.localPosition) - target.boundingHalfExtents
                let distance = simd_length(simd_max(delta, SIMD3<Float>(repeating: 0.0)))
                let falloff = 1.0 - (distance / max(0.05, spreadRadius)).clamped(to: 0.0...1.0)
                // Internal components sit inside structure that absorbs part
                // of the hit; structural neighbors take the larger share.
                weight = falloff * (target.kind.isStructural ? 0.45 : 0.30)
            }
            return weight > 0.001 ? (target, weight) : nil
        }
        let totalWeight = max(0.001, weightedTargets.reduce(Float(0.0)) { $0 + $1.1 })

        for (target, weight) in weightedTargets {
            // A single impact has one energy budget. Normalizing prevents a
            // core hit overlapping frame+battery+FC+ESC from manufacturing
            // two or three times the incoming energy.
            let share = weight / totalWeight

            let before = target.integrity
            let residualBefore = target.residualStrength
            let stiffnessBefore = target.stiffnessScale
            let absorbedEnergy = energyJ * damageFactor * share
            // Elastic energy is recovered without permanent damage. Cracks reduce
            // that reserve; abrasion callers pass accumulated work separately.
            let elasticReserve = target.strengthJ * 0.012 * target.residualStrength * elasticReserveScale.clamped(to: 0...1)
            let normalized = max(0, absorbedEnergy - elasticReserve) / max(0.5, target.strengthJ)
            let brittleness = 1.0 + (1.0 - before) * 0.5
            let after = (before - normalized * brittleness).clamped(to: 0.0...1.0)
            guard after < before - 0.000001 else { continue }

            guard let targetIndex = indexByID[target.id] else { continue }
            components[targetIndex].integrity = after
            components[targetIndex].residualStrength = (
                residualBefore - normalized * (0.75 + (1.0 - before) * 0.65)
            ).clamped(to: 0.0...1.0)
            components[targetIndex].stiffnessScale = (
                stiffnessBefore - normalized * 0.55
            ).clamped(to: 0.08...1.0)
            let performanceScale = pow(after, target.kind.isStructural ? 0.55 : 0.85)
            components[targetIndex].performance.forceScale = performanceScale
            components[targetIndex].performance.torqueScale = performanceScale
            components[targetIndex].performance.efficiencyScale = performanceScale
            components[targetIndex].performance.responseSpeedScale = (0.25 + performanceScale * 0.75).clamped(to: 0.0...1.0)
            components[targetIndex].performance.dragScale = 1.0 + (1.0 - after) * 0.8
            if target.kind.isStructural {
                components[targetIndex].deformation.vibrationScale = max(target.deformation.vibrationScale, (1 - after) * after)
                // Bending and folding belong to the joint solvers, which rotate the part
                // about its own attachment. What local crushing can do on its own is push a
                // small, stiffly mounted part back into its mount — a gear leg collapsing,
                // a motor driven into its pod. Translating a whole wing station or fuselage
                // that way would open a gap in the rendered structure.
                switch target.kind {
                case .landingGear, .motor:
                    let direction = simd_length_squared(impulseBody) > 1e-10
                        ? simd_normalize(impulseBody)
                        : -simd_normalize(simd_length_squared(impactPoint - target.localPosition) > 1e-10
                            ? impactPoint - target.localPosition : SIMD3<Float>(0, -1, 0))
                    let crush = min(0.6, normalized * 0.5)
                    let limit = simd_length(target.boundingHalfExtents) * 0.8
                    var translation = components[targetIndex].deformation.translationMeters
                        + direction * simd_length(target.boundingHalfExtents) * crush
                    if simd_length(translation) > limit { translation = simd_normalize(translation) * limit }
                    components[targetIndex].deformation.translationMeters = translation
                default:
                    break
                }
            }
            entries.append(
                ImpactDamageEntry(
                    componentID: target.id,
                    legacyComponent: target.legacyComponent,
                    integrityBefore: before,
                    integrityAfter: after,
                    residualStrengthBefore: residualBefore,
                    residualStrengthAfter: components[targetIndex].residualStrength,
                    stiffnessBefore: stiffnessBefore,
                    stiffnessAfter: components[targetIndex].stiffnessScale
                )
            )
        }

        return entries
    }

    /// Records what a structural solver decided for one joint. The plastic rotation is the
    /// joint's new *total* permanent rotation (body frame, about its section anchor) and is
    /// mirrored onto the child as `bendRadians`, so geometry, contacts, mass properties and
    /// aerodynamics all see the same bent or folded part.
    ///
    /// ⚠️ Nothing here erodes a joint over time. A load either exceeds what the section can
    /// carry — and then it yields or breaks in that event — or it does not, and then it does
    /// nothing. The only slow mechanism is `fatigueDamage`, which the solvers accumulate
    /// from real load cycles.
    @discardableResult
    mutating func applyJointOutcome(
        childComponentID: String,
        plasticRotationBody: SIMD3<Float>,
        plasticRotationSpent: Float,
        residualStrength: Float,
        stiffnessScale: Float,
        fracture: VehicleJointFracture,
        fatigueDamage: Float? = nil
    ) -> ConnectionDamageEntry? {
        guard let index = connectionIndexByChildID[childComponentID],
              structuralConnections[index].state != .detached else { return nil }
        let before = structuralConnections[index]
        var rotation = plasticRotationBody
        let angle = simd_length(rotation)
        if angle > Self.maximumHingeRotation { rotation *= Self.maximumHingeRotation / angle }

        var updated = before
        updated.fracture = fracture
        updated.plasticRotationSpent = max(before.plasticRotationSpent, plasticRotationSpent)
        if let fatigueDamage { updated.fatigueDamage = max(before.fatigueDamage, fatigueDamage) }
        switch fracture {
        case .separated:
            updated.residualStrength = 0
            updated.stiffnessScale = 0
            updated.state = .partiallyDetached
        case .hinged:
            updated.residualStrength = min(before.residualStrength, residualStrength.clamped(to: 0.016...1.0))
            updated.stiffnessScale = min(before.stiffnessScale, stiffnessScale.clamped(to: 0.0...1.0))
            updated.state = .partiallyDetached
        case .intact:
            updated.residualStrength = min(before.residualStrength, residualStrength.clamped(to: 0.016...1.0))
            updated.stiffnessScale = min(before.stiffnessScale, stiffnessScale.clamped(to: 0.05...1.0))
            updated.state = Self.attachmentState(residualStrength: updated.residualStrength)
        }
        let rotationChanged = simd_distance(rotation, components[indexByID[childComponentID] ?? 0].deformation.bendRadians) > 1e-5
        guard updated != before || rotationChanged else { return nil }
        structuralConnections[index] = updated
        if let componentIndex = indexByID[childComponentID] {
            components[componentIndex].deformation.bendRadians = rotation
            components[componentIndex].residualStrength = min(
                components[componentIndex].residualStrength, max(0.016, updated.residualStrength))
            components[componentIndex].stiffnessScale = min(
                components[componentIndex].stiffnessScale, max(0.05, updated.stiffnessScale))
            components[componentIndex].attachmentState = updated.state
        }
        return ConnectionDamageEntry(
            connectionID: before.id,
            childComponentID: childComponentID,
            residualStrengthBefore: before.residualStrength,
            residualStrengthAfter: updated.residualStrength,
            stateBefore: before.state,
            stateAfter: updated.state
        )
    }

    /// Raises every joint to carry at least `envelope × factor` — the design floor that makes
    /// a pristine airframe survive its own design cases however its sections were first sized.
    mutating func raiseSectionCapacities(to envelopes: [String: VehicleJointEnvelope], factor: Float) {
        for index in structuralConnections.indices {
            let connection = structuralConnections[index]
            guard let section = connection.section, let envelope = envelopes[connection.childComponentID] else { continue }
            let raised = section.raised(to: envelope, factor: factor)
            guard raised != section else { continue }
            var updated = VehicleStructuralConnection(
                id: connection.id,
                parentComponentID: connection.parentComponentID,
                childComponentID: connection.childComponentID,
                connectionType: connection.connectionType,
                tensileLimitN: max(connection.tensileLimitN, raised.axialUltimateN),
                shearLimitN: max(connection.shearLimitN, raised.shearUltimateN),
                bendingLimitNm: max(connection.bendingLimitNm, raised.flapUltimateNm),
                torsionLimitNm: max(connection.torsionLimitNm, raised.torsionUltimateNm),
                section: raised)
            updated.residualStrength = connection.residualStrength
            updated.stiffnessScale = connection.stiffnessScale
            updated.state = connection.state
            updated.fracture = connection.fracture
            updated.fatigueDamage = connection.fatigueDamage
            updated.plasticRotationSpent = connection.plasticRotationSpent
            structuralConnections[index] = updated
        }
    }

    /// Depth of every component below the root, in one pass.
    func depths() -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(components.count)
        func resolve(_ component: VehicleComponent, guardDepth: Int) -> Int {
            if let known = result[component.id] { return known }
            let depth: Int
            if guardDepth < 64, let parentID = component.parentID, let parent = self.component(id: parentID) {
                depth = resolve(parent, guardDepth: guardDepth + 1) + 1
            } else {
                depth = 0
            }
            result[component.id] = depth
            return depth
        }
        for component in components { _ = resolve(component, guardDepth: 0) }
        return result
    }

    /// Mass and mass-weighted centre of every attached component's subtree, in one pass.
    func subtreeMass(transforms: [String: simd_float4x4]) -> [String: (mass: Float, center: SIMD3<Float>)] {
        let depthMap = depths()
        var mass: [String: Float] = [:]
        var moment: [String: SIMD3<Float>] = [:]
        for component in attachedComponents.sorted(by: { (depthMap[$0.id] ?? 0) > (depthMap[$1.id] ?? 0) }) {
            let p = (transforms[component.id] ?? matrix_identity_float4x4) * SIMD4<Float>(component.localPosition, 1)
            let ownMass = mass[component.id, default: 0] + component.massKg
            let ownMoment = moment[component.id, default: .zero] + SIMD3<Float>(p.x, p.y, p.z) * component.massKg
            mass[component.id] = ownMass
            moment[component.id] = ownMoment
            if let parent = component.parentID {
                mass[parent, default: 0] += ownMass
                moment[parent, default: .zero] += ownMoment
            }
        }
        return mass.reduce(into: [:]) { result, entry in
            result[entry.key] = (entry.value, (moment[entry.key] ?? .zero) / max(1e-6, entry.value))
        }
    }

    /// Depth of a component below the root, for ordering nested fractures.
    func depth(of componentID: String) -> Int {
        var depth = 0
        var cursor = component(id: componentID)?.parentID
        while let parent = cursor, depth < 64 {
            depth += 1
            cursor = component(id: parent)?.parentID
        }
        return depth
    }

    /// Joints that have come apart and whose subtrees are still on the aircraft, deepest
    /// first. Two breaks on one wing are two pieces: the tip is taken off as its own body
    /// before the panel it was attached to, so each keeps its own motion.
    var failedConnectionRootIDs: [String] {
        structuralConnections.compactMap { connection -> String? in
            guard connection.state != .detached,
                  connection.fracture == .separated || connection.residualStrength <= 0.015,
                  component(id: connection.childComponentID)?.isAttached == true else { return nil }
            return connection.childComponentID
        }.sorted { lhs, rhs in
            let l = depth(of: lhs), r = depth(of: rhs)
            return l == r ? lhs < rhs : l > r
        }
    }

    /// The ids of the stations of every discretised member, root → tip, keyed by member.
    var memberChains: [String: [String]] {
        var chains: [String: [String]] = [:]
        for connection in structuralConnections {
            guard let section = connection.section, section.isMemberStation, !section.memberID.isEmpty else { continue }
            chains[section.memberID, default: []].append(connection.childComponentID)
        }
        return chains.mapValues { ids in ids.sorted { depth(of: $0) < depth(of: $1) } }
    }

    /// Returns the complete attached subtree and its rigid-body properties
    /// without changing attachment state. This lets an impact be resolved as
    /// two bodies as soon as a joint fails, rather than first bouncing the
    /// still-intact aircraft and detaching it one stage later.
    func detachedSubtreePreview(rootComponentID: String) -> VehicleDetachedSubtree? {
        guard let root = component(id: rootComponentID),
              root.parentID != nil,
              root.isAttached else { return nil }

        var pending = [rootComponentID]
        var ids: Set<String> = []
        while let current = pending.popLast() {
            guard ids.insert(current).inserted else { continue }
            pending.append(contentsOf: components.compactMap { $0.parentID == current ? $0.id : nil })
        }
        let detached = components.filter { ids.contains($0.id) && $0.isAttached }
        guard !detached.isEmpty else { return nil }

        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        let transforms = deformationTransforms()
        for component in detached {
            let transform = transforms[component.id] ?? matrix_identity_float4x4
            for x: Float in [-1, 1] { for y: Float in [-1, 1] { for z: Float in [-1, 1] {
                let corner = transform * SIMD4<Float>(
                    component.localPosition + component.boundingHalfExtents * SIMD3<Float>(x, y, z), 1)
                let point = SIMD3<Float>(corner.x, corner.y, corner.z)
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            } } }
        }

        return VehicleDetachedSubtree(
            rootComponentID: rootComponentID,
            components: detached,
            massProperties: Self.massProperties(for: detached, transforms: transforms),
            localBoundsCenter: (minimum + maximum) * 0.5,
            localBoundsHalfExtents: simd_max((maximum - minimum) * 0.5, SIMD3<Float>(repeating: 0.01))
        )
    }

    /// Detaches a joint's entire dependent subtree and returns the rigid-body
    /// properties needed by the visual/physics detached-part manager.
    /// Takes every joint on the airframe to zero, so `failedConnectionRootIDs` reports the whole
    /// structure as having come apart.
    ///
    /// Integrity and joint strength are separate: `setIntegrity(0, …)` on every component leaves
    /// the connections untouched, which is how an aircraft could be reported destroyed and still
    /// be sitting on screen in one piece. Anything that means "this airframe is no longer an
    /// airframe" has to say so here as well.
    mutating func failAllConnections() {
        // The major assemblies part from the airframe root. Failing every nested station
        // too would scatter each wing into a dozen pieces for what is a single decision
        // that the airframe is finished.
        let rootIDs = Set(components.filter { $0.parentID == nil }.map(\.id))
        for index in structuralConnections.indices
        where structuralConnections[index].state != .detached
            && rootIDs.contains(structuralConnections[index].parentComponentID) {
            structuralConnections[index].residualStrength = 0
            structuralConnections[index].stiffnessScale = 0
            structuralConnections[index].fracture = .separated
        }
    }

    mutating func detachSubtree(rootComponentID: String) -> VehicleDetachedSubtree? {
        guard let detachedPart = detachedSubtreePreview(rootComponentID: rootComponentID) else {
            return nil
        }

        for id in detachedPart.componentIDs {
            if let index = indexByID[id] {
                components[index].attachmentState = .detached
            }
            if let connectionIndex = connectionIndexByChildID[id] {
                structuralConnections[connectionIndex].state = .detached
                structuralConnections[connectionIndex].residualStrength = 0.0
                structuralConnections[connectionIndex].stiffnessScale = 0.0
            }
        }
        massPropertiesRevision &+= 1
        return detachedPart
    }

    // MARK: Legacy projection

    /// Min-aggregates graph integrity into the legacy per-component
    /// `DamageState` (several graph components can map onto one legacy slot,
    /// e.g. wing root + wing outer -> armFL). Non-damage UI state
    /// (hidden/selected) is carried over from `base`.
    func projectedLegacyDamageState(base: DamageState) -> DamageState {
        var health: [DamageComponent: Float] = [:]
        for component in components {
            guard let legacy = component.legacyComponent else { continue }
            let current = health[legacy] ?? 1.0
            health[legacy] = min(current, component.isAttached ? component.integrity : 0.0)
        }

        var projected = base
        for (legacy, value) in health {
            projected.healthByComponent[legacy] = value
        }
        return projected
    }


    /// Compatibility bridge for old project snapshots and non-contact
    /// hazards that still publish the legacy diagnostic state. Physical
    /// models are then rebuilt from the graph, preventing UI damage from
    /// leaving propulsion/aerodynamics pristine.
    mutating func applyLegacyDamageState(_ state: DamageState) {
        for index in components.indices {
            guard let legacy = components[index].legacyComponent else { continue }
            let health = state.health(for: legacy).clamped(to: 0.0...1.0)
            components[index].integrity = min(components[index].integrity, health)
            components[index].residualStrength = min(
                components[index].residualStrength,
                (0.18 + health * 0.82).clamped(to: 0.0...1.0)
            )
            components[index].stiffnessScale = min(
                components[index].stiffnessScale,
                (0.12 + health * 0.88).clamped(to: 0.0...1.0)
            )
        }
    }

    /// Load factor every airframe's lifting joints are sized to carry, and the factor
    /// between that and outright failure.
    ///
    /// ⚠️ Without these, nothing in the strength chain knows what a joint is *for*.
    /// `strengthJ` is an impact energy — the joules that destroy a component in one hit —
    /// and the connection limits were derived from it by dividing by the component's
    /// largest half-extent. That is dimensionally a force, but its magnitude is an
    /// accident of the part's shape: the X-10's wing root is 5.4 m deep in chord, so the
    /// division left it able to hold 156 kN while its own wing carries 168 kN in a 2.5 g
    /// turn. Measured across the fleet, the resulting margins ranged from 1.8 g to over
    /// 8 g with no pattern — the large-chord and large-span aircraft were the weak ones.
    ///
    /// 2.5 g is the limit load factor for the transport category (CS-25/FAR-25) — the
    /// lowest in civil use, so it is the conservative choice for a mixed fleet, and the
    /// light-aircraft categories are stressed higher still. 1.5 is the standard factor
    /// between limit load and ultimate load. Together they are a *floor*: an airframe
    /// whose joints already come out stronger keeps its own numbers, so the fleet's
    /// spread survives and only the aircraft that could not hold their own weight move.
    private static let designLimitLoadFactor: Float = 2.5
    private static let ultimateLoadFactor: Float = 1.5

    private static func makeConnections(
        for components: [VehicleComponent],
        designTakeoffMassKg: Float = 0.0,
        sections: [String: VehicleJointSection] = [:],
        material: VehicleStructuralMaterial = .aluminium
    ) -> [VehicleStructuralConnection] {
        let byID = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        let totalMass = max(0.05, components.reduce(Float(0.0)) { $0 + $1.massKg })
        let totalLiftingArea = components.reduce(Float(0.0)) { $0 + ($1.liftingSurface?.area ?? 0.0) }

        /// What one rotor mount has to hold before it fails.
        ///
        /// ⚠️ A propeller mount that cannot carry its own engine's thrust is not a weak
        /// mount, it is a contradiction: transmitting that thrust to the airframe is the
        /// only thing the mount is for. It was derived from impact energy like every other
        /// joint, and measured standing still on the runway with the throttle up and
        /// nothing hit, the fleet came out at: RQ-7B 1,370 N of thrust against a 1,062 N
        /// mount, MQ-9A 14,465 against 13,181, MQ-9B 14,857 against 14,188, with the three
        /// IAI loitering munitions at 0.88–0.93 of their limit. The operator's MQ-9B threw
        /// its propeller onto the runway at zero airspeed — which is exactly where a
        /// propeller makes its greatest thrust, and the one condition the flight probes
        /// had never covered.
        ///
        /// Sized at the aircraft's full takeoff weight per rotor, times the same 1.5
        /// ultimate factor the lifting joints use. That is a static thrust-to-weight of 1.0
        /// at limit load, comfortably above anything in the catalogue — the measured spread
        /// is 0.27 (MQ-9B) to 0.82 (RQ-7B) — and generous on purpose, because this is a
        /// floor whose job is to stop a mount being weaker than its own engine.
        let designRotorLoad: Float = {
            guard designTakeoffMassKg > 0.05 else { return 0.0 }
            let rotors = components.reduce(Float(0.0)) { total, component in
                if case .propeller = component.kind { return total + 1.0 }
                return total
            }
            guard rotors >= 1.0 else { return 0.0 }
            return Self.ultimateLoadFactor * designTakeoffMassKg * 9.81 / rotors
        }()

        /// The flight load this joint has to carry at the design load factor: the lift its
        /// subtree's share of the airframe's lifting area is charged, plus the subtree's own
        /// inertia. This mirrors `UAVStructuralLoadSolver`'s `force` term by construction —
        /// same area shares, same mass, same load factor — which is the point: the joint is
        /// sized for the load the solver will actually put through it.
        func designFlightLoad(for child: VehicleComponent) -> (force: Float, lever: Float)? {
            guard totalLiftingArea > 0.0001 else { return nil }
            var subtree: [VehicleComponent] = []
            for candidate in components {
                var cursor: VehicleComponent? = candidate
                var depth = 0
                while let current = cursor, depth < 16 {
                    if current.id == child.id { subtree.append(candidate); break }
                    cursor = current.parentID.flatMap { byID[$0] }
                    depth += 1
                }
            }
            let liftingArea = subtree.reduce(Float(0.0)) { $0 + ($1.liftingSurface?.area ?? 0.0) }
            guard liftingArea > 0.0001 else { return nil }
            let subtreeMass = max(0.001, subtree.reduce(Float(0.0)) { $0 + $1.massKg })
            let centre = subtree.reduce(SIMD3<Float>(repeating: 0.0)) {
                $0 + $1.localPosition * $1.massKg
            } / subtreeMass
            guard let parentID = child.parentID, let parent = byID[parentID] else { return nil }
            let lever = max(0.01, simd_distance(centre, parent.localPosition))
            let carried = totalMass * (liftingArea / totalLiftingArea) + subtreeMass
            let force = Self.ultimateLoadFactor * Self.designLimitLoadFactor * 9.81 * carried
            return (force, lever)
        }

        return components.compactMap { child in
            guard let parentID = child.parentID, let parent = byID[parentID] else { return nil }
            let span = max(0.025, simd_distance(parent.localPosition, child.localPosition))
            let characteristic = max(0.025, max(child.boundingHalfExtents.x, child.boundingHalfExtents.y, child.boundingHalfExtents.z))
            var baseForce = max(8.0, child.strengthJ / characteristic)
            var bendingLimit = max(0.4, child.strengthJ * min(1.5, span / characteristic))
            if let design = designFlightLoad(for: child) {
                // `shearLimitN` is the smaller of the two force limits, so it is the one
                // that has to clear the design load for the joint to hold.
                baseForce = max(baseForce, design.force / 0.82)
                bendingLimit = max(bendingLimit, design.force * design.lever)
            }
            switch child.kind {
            case .propeller, .motor:
                // A motor carries its own propeller's thrust through to the airframe, so
                // both joints in that chain are sized for it.
                if designRotorLoad > 0.0 {
                    baseForce = max(baseForce, designRotorLoad / 0.82)
                    bendingLimit = max(bendingLimit, designRotorLoad * span)
                }
            case .wingSection, .horizontalTail, .verticalTail, .elevator, .rudder, .frame,
                 .fuselage, .arm, .tailSection, .battery, .flightController, .esc, .radio,
                 .cameraGimbal, .payloadMount, .landingGear:
                break
            }
            let connectionType: VehicleConnectionType
            switch child.kind {
            case .propeller, .motor:
                connectionType = .shaft
            case .wingSection, .tailSection:
                connectionType = .compositeTransition
            case .horizontalTail, .verticalTail:
                connectionType = .bonded
            case .elevator, .rudder:
                connectionType = .hinge
            case .landingGear:
                connectionType = .landingMount
            case .payloadMount:
                connectionType = .payloadRelease
            case .arm:
                connectionType = .bolted
            default:
                connectionType = .rigid
            }
            // ⚠️ No two joints are equally strong, and here that is the difference
            // between a failure and a stunt.
            //
            // A left and a right wing root are built from mirrored numbers, so under a
            // symmetric load their ratios cross 1.0 on the same tick and the aircraft
            // sheds both wings in one event — the operator's log read
            // `parts=[wing.left.root,wing.right.root]`, and on screen the two panels
            // slid out together as though pulled. Real structures do not do that: build
            // scatter decides which side goes first, the load transfers to what is left,
            // and the second failure follows.
            //
            // ±4% is the spread, which is at the tight end of what is published for
            // bonded composite joints (5–10% coefficient of variation is typical) —
            // deliberately conservative, because its job is to break the tie rather than
            // to make aircraft fragile. It is derived from the connection's own id, so a
            // given airframe always fails the same way and a replay stays a replay.
            let scatter = 1.0 + 0.04 * Self.unitJitter(for: "connection.\(parentID)->\(child.id)")
            if let designed = sections[child.id] {
                // A designed station keeps its own section; the scalar limits mirror it so
                // any reader of the legacy fields sees the same strength.
                return VehicleStructuralConnection(
                    id: "connection.\(parentID)->\(child.id)",
                    parentComponentID: parentID,
                    childComponentID: child.id,
                    connectionType: connectionType,
                    tensileLimitN: designed.axialUltimateN,
                    shearLimitN: designed.shearUltimateN,
                    bendingLimitNm: designed.flapUltimateNm,
                    torsionLimitNm: designed.torsionUltimateNm,
                    section: designed
                )
            }
            let tensile = baseForce * 1.15 * scatter
            let shear = baseForce * 0.82 * scatter
            let bending = bendingLimit * scatter
            let torsion = max(0.25, child.strengthJ * 0.65) * scatter
            return VehicleStructuralConnection(
                id: "connection.\(parentID)->\(child.id)",
                parentComponentID: parentID,
                childComponentID: child.id,
                connectionType: connectionType,
                tensileLimitN: tensile,
                shearLimitN: shear,
                bendingLimitNm: bending,
                torsionLimitNm: torsion,
                section: VehicleSectionDesign.attachment(
                    parent: parent, child: child,
                    tensileLimitN: tensile, shearLimitN: shear,
                    bendingLimitNm: bending, torsionLimitNm: torsion,
                    material: material)
            )
        }
    }

    /// A stable −1...1 drawn from a string, so build scatter is a property of the
    /// airframe rather than of when it happened to be built. FNV-1a, because the point
    /// is reproducibility, not cryptography.
    private static func unitJitter(for key: String) -> Float {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Float(Double(hash % 20_001) / 10_000.0 - 1.0)
    }

    private static func attachmentState(residualStrength: Float) -> VehicleAttachmentState {
        switch residualStrength {
        case ...0.015: return .partiallyDetached
        case ...0.22: return .partiallyDetached
        case ...0.58: return .loosened
        default: return .attached
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }

    var degreesToRadians: Float { self * .pi / 180.0 }
}
