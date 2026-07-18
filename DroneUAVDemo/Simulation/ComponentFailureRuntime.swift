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
    private static let defaultSeed: UInt64 = 0x4641_494C_5552_4553

    private(set) var failures: [String: ActiveComponentFailure] = [:]
    private var seed: UInt64
    private var generator: ComponentFailureSeededGenerator

    init(seed: UInt64 = ComponentFailureRuntime.defaultSeed) {
        self.seed = seed
        self.generator = ComponentFailureSeededGenerator(seed: seed)
    }

    func reset() {
        reset(seed: seed)
    }

    /// Starts a pristine, repeatable failure sequence. Supplying the same
    /// seed and the same damage/tick inputs produces the same assigned modes
    /// and intermittent working/dropout intervals.
    func reset(seed: UInt64) {
        failures.removeAll()
        self.seed = seed
        generator = ComponentFailureSeededGenerator(seed: seed)
    }

    var isEmpty: Bool { failures.isEmpty }
    var persistenceSeed: UInt64 { seed }
    var persistenceGeneratorState: UInt64 { generator.rawState }

    func restore(
        failures restoredFailures: [ActiveComponentFailure],
        seed: UInt64,
        generatorState: UInt64
    ) {
        self.seed = seed
        generator = ComponentFailureSeededGenerator(rawState: generatorState)
        failures.removeAll(keepingCapacity: true)
        for failure in restoredFailures.sorted(by: { $0.componentID < $1.componentID }) {
            failures[failure.componentID] = failure
        }
    }

    func removeFailures(componentIDs: Set<String>) {
        for id in componentIDs {
            failures.removeValue(forKey: id)
        }
    }

    /// Deterministic probability roll shared with failure effects that live
    /// outside this type (for example impact-triggered radio link loss).
    func chance(probability: Float) -> Bool {
        guard probability > 0.0 else { return false }
        guard probability < 1.0 else { return true }
        return nextUnitFloat() < probability
    }

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
            guard let component = graph.component(id: entry.componentID) else {
                continue
            }
            let existing = failures[entry.componentID]

            let crossed: (Float) -> Bool = { threshold in
                entry.integrityBefore > threshold && entry.integrityAfter <= threshold
            }

            var mode: ComponentFailureMode?
            if crossed(0.0001) || entry.integrityAfter <= 0.0001 {
                mode = component.failureModes.contains(.totalFailure) ? .totalFailure : nil
            } else if crossed(0.25) {
                let serious = component.failureModes.filter { $0 == .jam || $0 == .holdLastCommand || $0 == .intermittent }
                if let pick = randomElement(in: serious), chance(probability: 0.6) {
                    mode = pick
                }
            } else if crossed(0.5) {
                let light = component.failureModes.filter { $0 == .efficiencyLoss || $0 == .intermittent }
                if let pick = randomElement(in: light), chance(probability: 0.35) {
                    mode = pick
                }
            }

            guard let mode else { continue }
            if let existing, Self.severityRank(existing.mode) >= Self.severityRank(mode) {
                continue
            }

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
        // Dictionary iteration order is process-randomized. Sorting IDs keeps
        // assignment of RNG samples to intermittent components repeatable.
        let intermittentIDs = failures.keys
            .filter { failures[$0]?.mode == .intermittent }
            .sorted()
        for id in intermittentIDs {
            guard var failure = failures[id] else { continue }
            failure.intermittentTimer -= deltaTime
            if failure.intermittentTimer <= 0.0 {
                failure.intermittentActive.toggle()
                // Working stretches run longer than dropouts.
                failure.intermittentTimer = failure.intermittentActive
                    ? randomFloat(in: 0.8...2.0)
                    : randomFloat(in: 0.25...0.8)
            }
            failures[id] = failure
        }
    }

    // MARK: - Outputs

    /// Multiplicative thrust factor of the failure (not integrity — that's
    /// already in the rotor model) for `motor.<slot>`.
    func motorFailureFactor(slot: String) -> Float {
        functionalFactor(componentID: "motor.\(slot)")
    }

    func functionalFactor(componentID: String) -> Float {
        guard let failure = failures[componentID] else { return 1.0 }
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
        for id in failures.keys.sorted() {
            guard let failure = failures[id] else { continue }
            guard failure.mode == .jam || failure.mode == .holdLastCommand,
                  let frozen = failure.frozenSurfaceValue,
                  let channel = Self.surfaceChannel(forComponentID: failure.componentID) else {
                continue
            }
            result[channel] = frozen
        }
        return result
    }

    private static func severityRank(_ mode: ComponentFailureMode) -> Int {
        switch mode {
        case .efficiencyLoss: return 1
        case .intermittent: return 2
        case .jam, .holdLastCommand: return 3
        case .totalFailure: return 4
        }
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

    // MARK: - Seeded random helpers

    private func nextUnitFloat() -> Float {
        // Float has 24 bits of precision. Taking the high 24 generator bits
        // gives stable values in [0, 1) without relying on stdlib RNG helpers.
        let sample = generator.next() >> 40
        return Float(sample) / 16_777_216.0
    }

    private func randomFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnitFloat()
    }

    private func randomElement<Element>(in elements: [Element]) -> Element? {
        guard !elements.isEmpty else { return nil }
        let count = UInt64(elements.count)
        // Rejection removes modulo bias while retaining a stable mapping from
        // generator output to a uniformly selected element.
        let rejectionThreshold = (0 &- count) % count
        var sample = generator.next()
        while sample < rejectionThreshold {
            sample = generator.next()
        }
        return elements[Int(sample % count)]
    }
}

/// Small local SplitMix64 generator so failure behavior is reproducible and
/// independent of process-global randomness. Every UInt64 seed, including
/// zero, is valid.
private struct ComponentFailureSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    var rawState: UInt64 { state }

    init(seed: UInt64) {
        state = seed
    }

    init(rawState: UInt64) {
        state = rawState
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var sample = state
        sample = (sample ^ (sample >> 30)) &* 0xBF58_476D_1CE4_E5B9
        sample = (sample ^ (sample >> 27)) &* 0x94D0_49BB_1331_11EB
        return sample ^ (sample >> 31)
    }
}
