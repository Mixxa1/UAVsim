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
    case horizontalTail
    case verticalTail
    case landingGear(slot: String)

    /// Structural components carry contact geometry and shed impact energy;
    /// internal ones (battery, FC, radio...) are damaged through proximity.
    var isStructural: Bool {
        switch self {
        case .frame, .fuselage, .arm, .propeller, .wingSection,
             .horizontalTail, .verticalTail, .landingGear, .motor:
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
/// and obstacles). Broad-phase, avoidance and path planning keep using the
/// legacy bounding sphere.
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
    /// destroyed in a single hit. Wear (a later phase) will lower it.
    let strengthJ: Float
    var integrity: Float
    /// Projection into the legacy `DamageComponent` enum so the existing
    /// damage overlay / diagnostics / thermal model keep working unchanged.
    let legacyComponent: DamageComponent?
    /// Components that stop functioning when this one fails (by id).
    let functionalDependencies: [String]
    let failureModes: [ComponentFailureMode]

    var isDestroyed: Bool { integrity <= 0.0001 }
}

// MARK: - Mass properties

/// Rigid-body summary the physics engine consumes: total mass, CoM offset
/// from the state origin, and a diagonal inertia tensor about the CoM in
/// body axes. Recomputed whenever the graph changes (Phase 4 will change it
/// on detachment).
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

// MARK: - Graph

struct VehicleComponentGraph: Hashable {
    private(set) var components: [VehicleComponent]
    private var indexByID: [String: Int]

    static let empty = VehicleComponentGraph(components: [])

    init(components: [VehicleComponent]) {
        self.components = components
        var index: [String: Int] = [:]
        index.reserveCapacity(components.count)
        for (offset, component) in components.enumerated() {
            index[component.id] = offset
        }
        self.indexByID = index
    }

    var isEmpty: Bool { components.isEmpty }

    func component(id: String) -> VehicleComponent? {
        indexByID[id].map { components[$0] }
    }

    func integrity(id: String) -> Float {
        component(id: id)?.integrity ?? 1.0
    }

    mutating func setIntegrity(_ value: Float, id: String) {
        guard let index = indexByID[id] else { return }
        components[index].integrity = value.clamped(to: 0.0...1.0)
    }

    func components(within radius: Float, of point: SIMD3<Float>) -> [VehicleComponent] {
        components.filter { component in
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
        guard !components.isEmpty else { return .fallback }

        var totalMass: Float = 0.0
        var weightedPosition = SIMD3<Float>(repeating: 0.0)
        for component in components {
            totalMass += component.massKg
            weightedPosition += component.localPosition * component.massKg
        }
        guard totalMass > 0.0001 else { return .fallback }
        let centerOfMass = weightedPosition / totalMass

        var inertia = SIMD3<Float>(repeating: 0.0)
        for component in components {
            let m = component.massKg
            let d = component.localPosition - centerOfMass
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
        spreadRadius: Float
    ) -> [ImpactDamageEntry] {
        guard energyJ > 0.0, damageFactor > 0.0,
              let primary = component(id: primaryComponentID) else {
            return []
        }

        var entries: [ImpactDamageEntry] = []
        let neighbors = components(within: max(0.0, spreadRadius), of: primary.localPosition)

        for target in neighbors {
            let share: Float
            if target.id == primaryComponentID {
                share = 1.0
            } else {
                let distance = simd_distance(target.localPosition, primary.localPosition)
                let falloff = 1.0 - (distance / max(0.05, spreadRadius)).clamped(to: 0.0...1.0)
                // Internal components sit inside structure that absorbs part
                // of the hit; structural neighbors take the larger share.
                share = falloff * (target.kind.isStructural ? 0.45 : 0.30)
            }
            guard share > 0.001 else { continue }

            let before = target.integrity
            let normalized = energyJ * damageFactor * share / max(0.5, target.strengthJ)
            let brittleness = 1.0 + (1.0 - before) * 0.5
            let after = (before - normalized * brittleness).clamped(to: 0.0...1.0)
            guard after < before - 0.0005 else { continue }

            setIntegrity(after, id: target.id)
            entries.append(
                ImpactDamageEntry(
                    componentID: target.id,
                    legacyComponent: target.legacyComponent,
                    integrityBefore: before,
                    integrityAfter: after
                )
            )
        }

        return entries
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
            health[legacy] = min(current, component.integrity)
        }

        var projected = base
        for (legacy, value) in health {
            projected.healthByComponent[legacy] = value
        }
        return projected
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
