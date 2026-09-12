import Foundation
import simd

/// A lifting panel retains its identity and geometry when it is damaged or
/// detached. Area fractions refer to the original wing, never the surviving
/// pieces: losing a panel cannot enlarge the remaining ones.
struct DamagedWingPanel: Hashable {
    let areaFraction: Float
    let spanPosition: Float // x / full span, +right
    /// Share of the panel's lift it still makes: its health times how much of it still
    /// faces the lift direction (a panel folded up 90° is edge-on and lifts nothing).
    let effectiveness: Float
    let stallScale: Float
    let incidenceRad: Float
    /// The panel's own structural condition, the hinged penalty included. Separate from
    /// `effectiveness` because drag follows the damage, not the fold: a panel folded up to
    /// a winglet is edge-on and clean, a torn one is rough however it is oriented.
    var health: Float = 1
    /// False once it has left the aircraft — it then neither lifts nor drags.
    var isPresent: Bool = true

    /// The same strip undamaged: what the pristine coefficients already account for.
    var undamaged: DamagedWingPanel {
        DamagedWingPanel(areaFraction: areaFraction, spanPosition: spanPosition,
                         effectiveness: 1, stallScale: 1, incidenceRad: 0)
    }

    /// Profile-drag increment of a section with its skin torn and its leading edge crushed,
    /// on the section's own area, at zero health. A clean section's profile drag is about
    /// 0.01; heavy roughness and open structure raise it by an order of magnitude (a fully
    /// rough section with an open, ragged leading edge measures 0.05–0.1), and a panel
    /// flapping on its skin is taken at the top of that range.
    static let damagedSectionDragIncrement: Float = 0.1
}

struct FixedWingAeroDamage: Hashable {
    var liftScale: Float = 1
    var cd0Extra: Float = 0
    var clRollOffset: Float = 0
    var cnYawOffset: Float = 0
    var aileronScale: Float = 1
    var elevatorScale: Float = 1
    var rudderScale: Float = 1
    var pitchStabilityScale: Float = 1
    var yawStabilityScale: Float = 1
    var panels: [DamagedWingPanel] = []

    /// Effectiveness of every lifting part (wing, tail and fin stations, elevator, rudder),
    /// 0...1: its own integrity, whether it is still on the aircraft, and how far it has
    /// turned away from the attitude it was built to fly at. The structural solver loads
    /// each surface with the same numbers the aerodynamics fly it with.
    var panelEffectiveness: [(String, Float)] = []

    static let pristine = FixedWingAeroDamage()
    var isPristine: Bool {
        liftScale > 0.999 && cd0Extra < 0.0001 && abs(clRollOffset) < 0.0001 && abs(cnYawOffset) < 0.0001 &&
            aileronScale > 0.999 && elevatorScale > 0.999 && rudderScale > 0.999 &&
            pitchStabilityScale > 0.999 && yawStabilityScale > 0.999 &&
            panels.allSatisfy { $0.effectiveness > 0.999 && $0.stallScale > 0.999 && abs($0.incidenceRad) < 0.0001 }
    }

    static func == (lhs: FixedWingAeroDamage, rhs: FixedWingAeroDamage) -> Bool {
        lhs.liftScale == rhs.liftScale && lhs.cd0Extra == rhs.cd0Extra && lhs.clRollOffset == rhs.clRollOffset &&
            lhs.cnYawOffset == rhs.cnYawOffset && lhs.aileronScale == rhs.aileronScale &&
            lhs.elevatorScale == rhs.elevatorScale && lhs.rudderScale == rhs.rudderScale &&
            lhs.pitchStabilityScale == rhs.pitchStabilityScale && lhs.yawStabilityScale == rhs.yawStabilityScale &&
            lhs.panels == rhs.panels
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(liftScale); hasher.combine(cd0Extra); hasher.combine(aileronScale)
        hasher.combine(elevatorScale); hasher.combine(rudderScale); hasher.combine(panels)
    }

    static func build(from graph: VehicleComponentGraph) -> FixedWingAeroDamage {
        guard !graph.isEmpty else { return .pristine }
        let transforms = graph.deformationTransforms()
        /// A part's own condition. Stations of one member no longer share their neighbours'
        /// integrity: a dent at the root does not take lift away from the tip. What the tip
        /// does lose is attachment — a detached ancestor removes it, and a broken (hinged)
        /// joint inboard leaves it flapping on its skin in separated flow.
        func health(_ component: VehicleComponent) -> Float {
            guard component.isAttached else { return 0 }
            var result = component.integrity
            var current = component
            var visited: Set<String> = [component.id]
            while visited.count < 64 {
                if let connection = graph.connection(childComponentID: current.id) {
                    if connection.fracture == .separated { return 0 }
                    if connection.fracture == .hinged { result *= 0.3 }
                }
                guard let parentID = current.parentID, visited.insert(parentID).inserted,
                      let parent = graph.component(id: parentID) else { break }
                if !parent.isAttached { return 0 }
                current = parent
            }
            return max(0, min(1, result))
        }
        /// Still on the aircraft: attached, and no ancestor gone or broken clean through.
        func present(_ component: VehicleComponent) -> Bool {
            guard component.isAttached else { return false }
            var current = component
            var visited: Set<String> = [component.id]
            while visited.count < 64 {
                if graph.connection(childComponentID: current.id)?.fracture == .separated { return false }
                guard let parentID = current.parentID, visited.insert(parentID).inserted,
                      let parent = graph.component(id: parentID) else { break }
                if !parent.isAttached { return false }
                current = parent
            }
            return true
        }
        func rotation(_ component: VehicleComponent) -> simd_quatf {
            simd_quatf(transforms[component.id] ?? matrix_identity_float4x4)
        }
        func designNormal(_ component: VehicleComponent) -> SIMD3<Float> {
            switch component.kind {
            case .verticalTail, .rudder: return SIMD3<Float>(1, 0, 0)
            default: return SIMD3<Float>(0, 1, 0)
            }
        }
        func effectiveness(_ component: VehicleComponent) -> Float {
            let normal = designNormal(component)
            return health(component) * max(0, simd_dot(simd_act(rotation(component), normal), normal))
        }
        func meanEffectiveness(_ members: [VehicleComponent]) -> Float {
            let area = members.reduce(Float(0)) { $0 + max(0.0001, $1.liftingSurface?.area ?? $1.massKg) }
            guard area > 0, !members.isEmpty else { return 1 } // no invented tail on a tailless build
            return members.reduce(Float(0)) { $0 + effectiveness($1) * max(0.0001, $1.liftingSurface?.area ?? $1.massKg) } / area
        }
        let wings = graph.components.filter { if case .wingSection = $0.kind { return true }; return false }
        let area = wings.reduce(Float(0)) { $0 + ($1.liftingSurface?.area ?? 0) }
        let minX = wings.map { $0.localPosition.x - $0.boundingHalfExtents.x }.min() ?? 0
        let maxX = wings.map { $0.localPosition.x + $0.boundingHalfExtents.x }.max() ?? 0
        let centerX = (minX + maxX) * 0.5
        let span = max(0.01, maxX - minX)
        let panels = wings.map { wing -> DamagedWingPanel in
            let h = health(wing)
            let turn = rotation(wing)
            let normal = simd_act(turn, SIMD3<Float>(0, 1, 0))
            let chord = simd_act(turn, SIMD3<Float>(0, 0, -1))
            let p = (transforms[wing.id] ?? matrix_identity_float4x4) * SIMD4<Float>(wing.localPosition, 1)
            return DamagedWingPanel(areaFraction: (wing.liftingSurface?.area ?? 0) / max(0.0001, area),
                spanPosition: (p.x - centerX) / span,
                effectiveness: h * max(0, normal.y),
                stallScale: max(0.45, 1 - (1 - h) * 0.35 - (1 - wing.stiffnessScale) * 0.15),
                incidenceRad: atan2(chord.y, -chord.z),
                health: h,
                isPresent: present(wing))
        }
        let horizontal = graph.components.filter { $0.kind == .horizontalTail }
        let vertical = graph.components.filter { $0.kind == .verticalTail }
        let hTail = meanEffectiveness(horizontal)
        let vTail = meanEffectiveness(vertical)
        let elevator = min(hTail, meanEffectiveness(graph.components.filter { $0.kind == .elevator }))
        let rudder = min(vTail, meanEffectiveness(graph.components.filter { $0.kind == .rudder }))
        let bodyHealth = meanEffectiveness(graph.components.filter { $0.kind == .fuselage || $0.kind == .frame })
        let lift = area > 0 ? panels.reduce(Float(0)) { $0 + $1.areaFraction * $1.effectiveness } : 1
        let rollAuthority = panels.reduce(Float(0)) { $0 + $1.areaFraction * abs($1.spanPosition) }
        let survivingRollAuthority = panels.reduce(Float(0)) { $0 + $1.areaFraction * abs($1.spanPosition) * $1.effectiveness }
        // The wing's own damage drag lives in its strips, where it also yaws the aircraft.
        var result = FixedWingAeroDamage(liftScale: lift,
            cd0Extra: (1 - hTail) * 0.012 + (1 - vTail) * 0.01 + (1 - bodyHealth) * 0.08,
            aileronScale: rollAuthority > 0 ? survivingRollAuthority / rollAuthority : 1,
            elevatorScale: elevator, rudderScale: rudder,
            pitchStabilityScale: 0.08 + 0.92 * hTail,
            yawStabilityScale: 0.10 + 0.90 * vTail, panels: panels)
        result.panelEffectiveness = graph.components.compactMap { component in
            component.liftingSurface == nil ? nil : (component.id, effectiveness(component))
        }
        return result
    }
}
