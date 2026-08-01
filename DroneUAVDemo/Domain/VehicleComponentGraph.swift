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
}

// MARK: - Contact geometry

/// One collision proxy sphere, body-frame (physics convention: +Y up,
/// -Z forward), positioned relative to the same origin as
/// `DroneState.position` — the ground/gear reference point, so a gear
/// sphere's bottom sits at local y == 0 at rest attitude.
struct VehicleContactSphere: Hashable {
    let componentID: String
    let offset: SIMD3<Float>
    let radius: Float

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

    static let empty = VehicleContactProfile(spheres: [], boundingRadius: 0.0)

    var isEmpty: Bool { spheres.isEmpty }

    /// Lowest point (world Y) of the profile at the given pose. The legacy
    /// ground clamp compared `position.y` against the support height; the
    /// contact-aware clamp compares this instead, so a rolled airframe rests
    /// on its wingtip/prop rather than sinking to the gear reference.
    func lowestPointY(position: SIMD3<Float>, orientation: simd_quatf) -> Float {
        var lowest = position.y
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

    /// Rest-normalized ground clearance: how much higher than the legacy
    /// gear-reference the origin must sit at this attitude so no contact
    /// sphere penetrates the support plane. Normalizing against the rest
    /// attitude keeps `position.y == supportY` exactly at rest (including a
    /// tail-standing tailsitter), so every legacy ground/landing check keeps
    /// its meaning; only *non-rest* attitudes (bank near the ground, tumble)
    /// lift the origin so a wingtip/prop can't sink into the surface.
    func groundClearanceOffset(orientation: simd_quatf, restOrientation: simd_quatf) -> Float {
        max(0.0, lowestPointOffset(orientation: orientation) - lowestPointOffset(orientation: restOrientation))
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
        return VehicleContactProfile(spheres: remaining, boundingRadius: radius)
    }

    func applyingDeformations(from graph: VehicleComponentGraph) -> VehicleContactProfile {
        guard !spheres.isEmpty else { return self }
        let deformed = spheres.map { sphere -> VehicleContactSphere in
            guard let component = graph.component(id: sphere.componentID), component.isAttached else {
                return sphere
            }
            let bend = component.deformation.bendRadians
            let rawAngle = simd_length(bend)
            let rotatedOffset: SIMD3<Float>
            if rawAngle > 0.0001 {
                let angle = min(Float(25.0) * .pi / 180.0, rawAngle)
                let rotation = simd_quatf(angle: angle, axis: bend / rawAngle)
                rotatedOffset = component.localPosition + simd_act(
                    rotation,
                    sphere.offset - component.localPosition
                )
            } else {
                rotatedOffset = sphere.offset
            }
            return VehicleContactSphere(
                componentID: sphere.componentID,
                offset: rotatedOffset + component.deformation.translationMeters,
                radius: sphere.radius
            )
        }
        let radius = deformed.reduce(Float(0.0)) {
            max($0, simd_length($1.offset) + $1.radius)
        }
        return VehicleContactProfile(spheres: deformed, boundingRadius: max(boundingRadius, radius))
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
    private(set) var components: [VehicleComponent]
    private(set) var structuralConnections: [VehicleStructuralConnection]
    private(set) var massPropertiesRevision: UInt64
    private var indexByID: [String: Int]
    private var connectionIndexByChildID: [String: Int]

    static let empty = VehicleComponentGraph(components: [])

    init(
        components: [VehicleComponent],
        structuralConnections: [VehicleStructuralConnection]? = nil,
        massPropertiesRevision: UInt64 = 0
    ) {
        self.components = components
        self.massPropertiesRevision = massPropertiesRevision
        var index: [String: Int] = [:]
        index.reserveCapacity(components.count)
        for (offset, component) in components.enumerated() {
            index[component.id] = offset
        }
        self.indexByID = index

        let resolvedConnections = structuralConnections ?? Self.makeConnections(for: components)
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
        Self.massProperties(for: attachedComponents)
    }

    /// Rigid-body properties of the still-attached airframe after excluding
    /// a subtree that is about to separate during the current impact.  The
    /// graph is intentionally not mutated here: the impact solver needs both
    /// bodies' properties before the presentation layer performs the actual
    /// detach operation.
    func massProperties(excludingComponentIDs excludedIDs: Set<String>) -> VehicleMassProperties {
        Self.massProperties(
            for: attachedComponents.filter { !excludedIDs.contains($0.id) }
        )
    }

    private static func massProperties(for components: [VehicleComponent]) -> VehicleMassProperties {
        guard !components.isEmpty else { return .fallback }

        var totalMass: Float = 0.0
        var weightedPosition = SIMD3<Float>(repeating: 0.0)
        for component in components {
            totalMass += component.massKg
            weightedPosition += (component.localPosition + component.deformation.translationMeters) * component.massKg
        }
        guard totalMass > 0.0001 else { return .fallback }
        let centerOfMass = weightedPosition / totalMass

        var inertia = SIMD3<Float>(repeating: 0.0)
        for component in components {
            let m = component.massKg
            let d = component.localPosition + component.deformation.translationMeters - centerOfMass
            let h = component.boundingHalfExtents
            // Parallel-axis point-mass term + the component's own box inertia
            // (1/12·m·(a²+b²) with full extents a=2h → m/3·(h²+h²)).
            inertia.x += m * (d.y * d.y + d.z * d.z) + m / 3.0 * (h.y * h.y + h.z * h.z)
            inertia.y += m * (d.x * d.x + d.z * d.z) + m / 3.0 * (h.x * h.x + h.z * h.z)
            inertia.z += m * (d.x * d.x + d.y * d.y) + m / 3.0 * (h.x * h.x + h.y * h.y)
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
        contactPointBody: SIMD3<Float>? = nil
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
            let normalized = energyJ * damageFactor * share / max(0.5, target.strengthJ)
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

    /// Degrades the chain of joints carrying a local impact. Direction and
    /// lever arm matter independently from the scalar energy used for local
    /// component damage, so a wing-tip strike can fail the root joint before
    /// destroying the whole wing skin.
    mutating func applyConnectionImpact(
        primaryComponentID: String,
        contactPointBody: SIMD3<Float>,
        impulseBody: SIMD3<Float>,
        energyJ: Float,
        damageFactor: Float,
        contactDuration: Float
    ) -> [ConnectionDamageEntry] {
        guard energyJ > 0.0, simd_length_squared(impulseBody) > 0.000001 else { return [] }

        var entries: [ConnectionDamageEntry] = []
        var childID: String? = primaryComponentID
        var propagation: Float = 1.0
        var depth = 0
        while let currentChildID = childID, depth < 4 {
            guard let connectionIndex = connectionIndexByChildID[currentChildID],
                  let child = component(id: currentChildID),
                  let parent = component(id: structuralConnections[connectionIndex].parentComponentID) else {
                childID = component(id: currentChildID)?.parentID
                depth += 1
                propagation *= 0.55
                continue
            }

            let duration = max(0.004, contactDuration)
            let force = impulseBody / duration
            let lever = contactPointBody - parent.localPosition
            let moment = simd_cross(lever, force)
            let jointAxisRaw = child.localPosition - parent.localPosition
            let jointAxis = simd_length_squared(jointAxisRaw) > 0.000001
                ? simd_normalize(jointAxisRaw)
                : SIMD3<Float>(0.0, 1.0, 0.0)
            let tensileForce = abs(simd_dot(force, jointAxis))
            let shearForce = simd_length(force - jointAxis * simd_dot(force, jointAxis))
            let torsionalMoment = abs(simd_dot(moment, jointAxis))
            let bendingMoment = simd_length(moment - jointAxis * simd_dot(moment, jointAxis))
            let connection = structuralConnections[connectionIndex]
            let tensileRatio = tensileForce / max(0.01, connection.tensileLimitN)
            let shearRatio = shearForce / max(0.01, connection.shearLimitN)
            let bendingRatio = bendingMoment / max(0.01, connection.bendingLimitNm)
            let torsionRatio = torsionalMoment / max(0.01, connection.torsionLimitNm)
            let energyRatio = energyJ / max(0.5, child.strengthJ)
            let structuralRatio = max(tensileRatio, shearRatio, bendingRatio, torsionRatio)
            let residualCapacity = max(0.015, connection.residualStrength)
            // Structural force and moment travel through the whole load path.
            // Do not attenuate them while walking from a wing tip toward the
            // fuselage: the root sees the same impulse at a longer lever arm.
            // Energy spreading still decays with depth because skin/internal
            // damage is absorbed locally.
            let exceedsResidualCapacity = structuralRatio > residualCapacity
            let severity = max(
                structuralRatio / residualCapacity,
                energyRatio * 0.85 * damageFactor * propagation
            )
            // A joint that exceeds its residual load envelope fails in this
            // contact. Sub-limit contacts can still bend/loosen it and make a
            // later, smaller hit decisive.
            let loss = exceedsResidualCapacity
                ? connection.residualStrength
                : max(0.0, severity - 0.25) * 0.55

            if loss > 0.0005 {
                let residualBefore = connection.residualStrength
                let stateBefore = connection.state
                structuralConnections[connectionIndex].residualStrength = (
                    residualBefore - loss * (1.0 + (1.0 - residualBefore) * 0.6)
                ).clamped(to: 0.0...1.0)
                structuralConnections[connectionIndex].stiffnessScale = (
                    connection.stiffnessScale - loss * 0.6
                ).clamped(to: 0.05...1.0)
                structuralConnections[connectionIndex].state = Self.attachmentState(
                    residualStrength: structuralConnections[connectionIndex].residualStrength
                )

                if let componentIndex = indexByID[currentChildID] {
                    let bendAxis = simd_length_squared(moment) > 0.000001
                        ? simd_normalize(moment)
                        : SIMD3<Float>(1.0, 0.0, 0.0)
                    let bendMagnitude = min(Float(18.0).degreesToRadians, loss * Float(14.0).degreesToRadians)
                    components[componentIndex].deformation.bendRadians += bendAxis * bendMagnitude
                    components[componentIndex].deformation.bendRadians = simd_clamp(
                        components[componentIndex].deformation.bendRadians,
                        SIMD3<Float>(repeating: -Float(25.0).degreesToRadians),
                        SIMD3<Float>(repeating: Float(25.0).degreesToRadians)
                    )
                    components[componentIndex].residualStrength = min(
                        components[componentIndex].residualStrength,
                        structuralConnections[connectionIndex].residualStrength
                    )
                    components[componentIndex].stiffnessScale = min(
                        components[componentIndex].stiffnessScale,
                        structuralConnections[connectionIndex].stiffnessScale
                    )
                    components[componentIndex].attachmentState = structuralConnections[connectionIndex].state
                }

                entries.append(
                    ConnectionDamageEntry(
                        connectionID: connection.id,
                        childComponentID: currentChildID,
                        residualStrengthBefore: residualBefore,
                        residualStrengthAfter: structuralConnections[connectionIndex].residualStrength,
                        stateBefore: stateBefore,
                        stateAfter: structuralConnections[connectionIndex].state
                    )
                )
            }

            childID = child.parentID
            depth += 1
            propagation *= 0.55
        }
        return entries
    }

    /// Applies flight-load fatigue to one joint and mirrors the resulting
    /// loosened/partial state onto its child component.
    mutating func applyStructuralOverload(
        childComponentID: String,
        loadRatio: Float,
        deltaTime: Float
    ) -> ConnectionDamageEntry? {
        guard loadRatio > 1.0,
              let index = connectionIndexByChildID[childComponentID],
              structuralConnections[index].state != .detached else {
            return nil
        }
        let before = structuralConnections[index]
        // Constant loads below the certified limit do not irreversibly eat
        // the joint. Cycle fatigue needs its own accumulated cycle/range
        // state; treating 72–100% static load as damage creates runaway
        // self-weakening in an otherwise nominal flight.
        let rate = (loadRatio - 1.0) * 1.15
        let loss = max(0.0, rate * max(0.0, deltaTime))
        guard loss > 0.000001 else { return nil }

        structuralConnections[index].residualStrength = (
            before.residualStrength - loss * (1.0 + (1.0 - before.residualStrength))
        ).clamped(to: 0.0...1.0)
        structuralConnections[index].stiffnessScale = (
            before.stiffnessScale - loss * 0.55
        ).clamped(to: 0.05...1.0)
        structuralConnections[index].state = Self.attachmentState(
            residualStrength: structuralConnections[index].residualStrength
        )
        if let componentIndex = indexByID[childComponentID] {
            components[componentIndex].residualStrength = min(
                components[componentIndex].residualStrength,
                structuralConnections[index].residualStrength
            )
            components[componentIndex].stiffnessScale = min(
                components[componentIndex].stiffnessScale,
                structuralConnections[index].stiffnessScale
            )
            components[componentIndex].attachmentState = structuralConnections[index].state
        }
        return ConnectionDamageEntry(
            connectionID: before.id,
            childComponentID: childComponentID,
            residualStrengthBefore: before.residualStrength,
            residualStrengthAfter: structuralConnections[index].residualStrength,
            stateBefore: before.state,
            stateAfter: structuralConnections[index].state
        )
    }

    var failedConnectionRootIDs: [String] {
        let failedChildren: [String] = structuralConnections.compactMap { connection in
            guard connection.state != .detached,
                  connection.residualStrength <= 0.015 else { return nil }
            return connection.childComponentID
        }
        let candidates = Set(failedChildren)
        // If both an outer section and its root fail in the same impact,
        // detach the highest failed ancestor once. Otherwise the outer piece
        // would be spawned first and the remaining wing root as a second body.
        return candidates.filter { candidate in
            var parentID = component(id: candidate)?.parentID
            var depth = 0
            while let parent = parentID, depth < 32 {
                if candidates.contains(parent) { return false }
                parentID = component(id: parent)?.parentID
                depth += 1
            }
            return true
        }.sorted()
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
        for component in detached {
            minimum = simd_min(minimum, component.localPosition - component.boundingHalfExtents)
            maximum = simd_max(maximum, component.localPosition + component.boundingHalfExtents)
        }

        return VehicleDetachedSubtree(
            rootComponentID: rootComponentID,
            components: detached,
            massProperties: Self.massProperties(for: detached),
            localBoundsCenter: (minimum + maximum) * 0.5,
            localBoundsHalfExtents: simd_max((maximum - minimum) * 0.5, SIMD3<Float>(repeating: 0.01))
        )
    }

    /// Detaches a joint's entire dependent subtree and returns the rigid-body
    /// properties needed by the visual/physics detached-part manager.
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

    private static func makeConnections(for components: [VehicleComponent]) -> [VehicleStructuralConnection] {
        let byID = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        return components.compactMap { child in
            guard let parentID = child.parentID, let parent = byID[parentID] else { return nil }
            let span = max(0.025, simd_distance(parent.localPosition, child.localPosition))
            let characteristic = max(0.025, max(child.boundingHalfExtents.x, child.boundingHalfExtents.y, child.boundingHalfExtents.z))
            let baseForce = max(8.0, child.strengthJ / characteristic)
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
            return VehicleStructuralConnection(
                id: "connection.\(parentID)->\(child.id)",
                parentComponentID: parentID,
                childComponentID: child.id,
                connectionType: connectionType,
                tensileLimitN: baseForce * 1.15,
                shearLimitN: baseForce * 0.82,
                bendingLimitNm: max(0.4, child.strengthJ * min(1.5, span / characteristic)),
                torsionLimitNm: max(0.25, child.strengthJ * 0.65)
            )
        }
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
