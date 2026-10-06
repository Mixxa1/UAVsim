import Foundation
import simd

/// Collision-triggered game event, independent of the contact's kinetic energy. These are
/// bounded gameplay effects, not explosive specifications or a physical blast solver.
struct ChargeDetonation {
    /// Includes the rolling soot after the brief flash, not a delayed second detonation.
    static let effectLifetime: TimeInterval = 4
    static let effectReach: Float = 9
    let position: SIMD3<Float>
    let normal: SIMD3<Float>

    init(position: SIMD3<Float>, normal: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) {
        self.position = position
        self.normal = simd_length_squared(normal).isFinite && simd_length_squared(normal) > 0.001
            ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
    }

    func exposure(at point: SIMD3<Float>) -> Float {
        let distance = simd_distance(position, point)
        guard distance.isFinite else { return 0 }
        let fraction = max(0, 1 - distance / Self.effectReach)
        return fraction * fraction
    }

    func apply(to graph: inout VehicleComponentGraph, state: DroneState,
               directHit: Bool, detach: Bool) {
        for component in graph.components where component.isAttached {
            let point = state.position + simd_act(state.attitudeQuat,
                graph.deformedPosition(component.localPosition, attachedTo: component.id))
            let amount = directHit ? Float(1) : exposure(at: point) * 1.7
            graph.setIntegrity(max(0, component.integrity - amount), id: component.id)
        }
        let coreLost = graph.components.contains {
            ($0.kind == .frame || $0.kind == .fuselage) && $0.isAttached && $0.integrity <= 0.001
        }
        guard directHit || coreLost else { return }
        graph.failAllConnections()
        if detach {
            for root in graph.failedConnectionRootIDs { _ = graph.detachSubtree(rootComponentID: root) }
        }
    }

    /// Playback crosses events only while advancing. Seeking and pausing do not make sounds;
    /// replaying the same interval again intentionally plays the detonation again.
    static func replayEffects(events: [MissionReplayEvent], after start: TimeInterval,
                              through end: TimeInterval) -> [InterceptWorldEffect] {
        guard end > start else { return [] }
        var seen = Set<String>()
        return events.sorted { $0.timestamp < $1.timestamp }.compactMap { event in
            guard event.timestamp > start, event.timestamp <= end,
                  case .effect(let effect) = event.interception?.kind,
                  effect.kind == .explosion,
                  seen.insert("\(effect.impactID)/\(effect.vehicleID)").inserted else { return nil }
            return effect
        }
    }
}
