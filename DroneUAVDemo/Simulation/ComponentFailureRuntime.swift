import Foundation

/// Control-surface channels a structural failure can seize.
enum FlightSurfaceChannel: String, Hashable, CaseIterable {
    case aileron
    case elevator
    case rudder
}

/// One active failure attached to a component.
struct ActiveComponentFailure: Hashable {
    let componentID: String
    let mode: ComponentFailureMode
    /// Frozen deflection for jammed/held control surfaces.
    var frozenSurfaceValue: Float?
    /// Telegraph state for intermittent failures.
    var intermittentActive: Bool = false
    var intermittentTimer: Float = 0.0
}

/// Assigns and ticks component failure modes ("Повреждение двигателя или
/// серво": снижение мощности, заклинивание, перебои, фиксация на последней
/// команде, полный отказ). Failures are assigned when an impact pushes a
/// component's integrity across a threshold; they persist until reset (a
/// jammed servo doesn't heal itself mid-flight).
final class ComponentFailureRuntime {
    private(set) var failures: [String: ActiveComponentFailure] = [:]

    func reset() {
        failures.removeAll()
    }

    var isEmpty: Bool { failures.isEmpty }

    // MARK: - Assignment

    /// Rolls for new failures after an impact changed integrity. Returns
    /// human-readable descriptions of newly assigned failures for the log.
    @discardableResult
    func noteDamage(
        entries: [VehicleComponentGraph.ImpactDamageEntry],
        graph: VehicleComponentGraph,
        currentAileron: Float,
        currentElevator: Float,
        currentRudder: Float
    ) -> [String] {
        var assigned: [String] = []

        for entry in entries {
            guard failures[entry.componentID] == nil,
                  let component = graph.component(id: entry.componentID) else {
                continue
            }

            let crossed: (Float) -> Bool = { threshold in
                entry.integrityBefore > threshold && entry.integrityAfter <= threshold
            }

            var mode: ComponentFailureMode?
            if crossed(0.0001) || entry.integrityAfter <= 0.0001 {
                mode = component.failureModes.contains(.totalFailure) ? .totalFailure : nil
            } else if crossed(0.25) {
                let serious = component.failureModes.filter { $0 == .jam || $0 == .holdLastCommand || $0 == .intermittent }
                if let pick = serious.randomElement(), Float.random(in: 0.0...1.0) < 0.6 {
                    mode = pick
                }
            } else if crossed(0.5) {
                let light = component.failureModes.filter { $0 == .efficiencyLoss || $0 == .intermittent }
                if let pick = light.randomElement(), Float.random(in: 0.0...1.0) < 0.35 {
                    mode = pick
                }
            }

            guard let mode else { continue }

            var frozen: Float?
            if mode == .jam || mode == .holdLastCommand,
               let channel = Self.surfaceChannel(forComponentID: entry.componentID) {
                switch channel {
                case .aileron: frozen = currentAileron
                case .elevator: frozen = currentElevator
                case .rudder: frozen = currentRudder
                }
            }

            failures[entry.componentID] = ActiveComponentFailure(
                componentID: entry.componentID,
                mode: mode,
                frozenSurfaceValue: frozen
            )
            assigned.append("\(entry.componentID):\(mode.rawValue)")
        }

        return assigned
    }

    // MARK: - Tick

    func tick(deltaTime: Float) {
        guard !failures.isEmpty else { return }
        for (id, var failure) in failures where failure.mode == .intermittent {
            failure.intermittentTimer -= deltaTime
            if failure.intermittentTimer <= 0.0 {
                failure.intermittentActive.toggle()
                // Working stretches run longer than dropouts.
                failure.intermittentTimer = failure.intermittentActive
                    ? Float.random(in: 0.8...2.0)
                    : Float.random(in: 0.25...0.8)
            }
            failures[id] = failure
        }
    }

    // MARK: - Outputs

    /// Multiplicative thrust factor of the failure (not integrity — that's
    /// already in the rotor model) for `motor.<slot>`.
    func motorFailureFactor(slot: String) -> Float {
        guard let failure = failures["motor.\(slot)"] else { return 1.0 }
        switch failure.mode {
        case .efficiencyLoss:
            return 0.55
        case .intermittent:
            return failure.intermittentActive ? 1.0 : 0.15
        case .jam, .totalFailure:
            return 0.0
        case .holdLastCommand:
            return 1.0
        }
    }

    /// Surfaces currently seized (jam) or frozen at the last command
    /// (holdLastCommand) — the engine holds these deflections, bypassing
    /// pilot/autopilot input and servo slew.
    func jammedSurfaces() -> [FlightSurfaceChannel: Float] {
        var result: [FlightSurfaceChannel: Float] = [:]
        for failure in failures.values {
            guard failure.mode == .jam || failure.mode == .holdLastCommand,
                  let frozen = failure.frozenSurfaceValue,
                  let channel = Self.surfaceChannel(forComponentID: failure.componentID) else {
                continue
            }
            result[channel] = frozen
        }
        return result
    }

    /// Structural section -> control-surface mapping: ailerons ride the
    /// outer wing sections, elevator the horizontal tail, rudder the fin.
    static func surfaceChannel(forComponentID id: String) -> FlightSurfaceChannel? {
        switch id {
        case "wing.left.outer", "wing.right.outer":
            return .aileron
        case "tail.horizontal":
            return .elevator
        case "tail.vertical":
            return .rudder
        default:
            return nil
        }
    }
}
