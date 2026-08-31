import Foundation
import simd

/// Scoring and gate logic for a drone race. Pure logic, no SceneKit: the scene layer hands over
/// each gate's aperture as a plane plus two in-plane axes, and everything here follows from that.
///
/// Passes are detected by intersecting the *segment* the aircraft flew this tick with the gate
/// plane, never by proximity. A racing quad crosses a 2 m gate at 25 m/s; at 60 Hz that is 0.4 m
/// of travel per frame and a proximity test would have to be so loose that flying *past* a gate
/// would score, while a single dropped frame would let the aircraft teleport through the plane
/// untouched. The segment test is exact at any speed and any frame rate, and it also gives the
/// direction of travel for free — which is what makes "you took that gate backwards" possible to
/// say at all.
struct RaceRuntime {
    /// How long a wrong-way gate stays lit red before returning to its normal colour.
    private static let wrongWayFlashSeconds: Double = 1.2

    let mode: RaceMode
    let lapCount: Int
    let gates: [RaceGateGeometry]

    private(set) var objectiveState: RaceObjectiveState
    /// 1-based once the race is running; 0 before the first gate is taken.
    private(set) var currentLap: Int = 0
    private(set) var totalElapsedSeconds: Double = 0.0
    private(set) var currentLapSeconds: Double = 0.0
    private(set) var lapTimes: [Double] = []
    private(set) var bestLapSeconds: Double?
    /// Order number of the gate the pilot must take next; nil in free flight.
    private(set) var nextGateOrder: Int?
    private(set) var gateStates: [UUID: RaceGateVisualState] = [:]
    private(set) var gatesTakenThisLap: Int = 0

    private var pendingEvents: [RaceEvent] = []
    private var wrongWayTimers: [UUID: Double] = [:]

    init(mode: RaceMode, lapCount: Int, gates: [RaceGateGeometry]) {
        self.mode = mode
        self.lapCount = max(1, lapCount)
        self.gates = gates.sorted { $0.order < $1.order }
        self.objectiveState = mode == .timed ? .armed : .racing
        self.nextGateOrder = mode == .timed ? self.gates.first?.order : nil
        for gate in self.gates {
            gateStates[gate.elementID] = .idle
        }
        if mode == .timed, let first = self.gates.first {
            gateStates[first.elementID] = .next
        }
    }

    var isFinished: Bool { objectiveState == .finished }

    var totalGateCount: Int { gates.count }

    /// The gate the pilot is being sent to, for the HUD's distance/arrow readout.
    var nextGate: RaceGateGeometry? {
        guard let nextGateOrder else { return nil }
        return gates.first { $0.order == nextGateOrder }
    }

    mutating func drainEvents() -> [RaceEvent] {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return events
    }

    mutating func tick(
        deltaTime: Double,
        previousPosition: SIMD3<Float>,
        currentPosition: SIMD3<Float>
    ) {
        guard !isFinished, deltaTime > 0 else { return }

        if objectiveState == .racing {
            totalElapsedSeconds += deltaTime
            currentLapSeconds += deltaTime
        }
        expireWrongWayFlashes(deltaTime: deltaTime)

        for gate in gates {
            guard let direction = crossingDirection(
                gate: gate,
                from: previousPosition,
                to: currentPosition
            ) else { continue }
            handleCrossing(gate: gate, isForward: direction)
        }
    }

    mutating func abort() {
        guard !isFinished else { return }
        objectiveState = .finished
    }

    // MARK: Crossing

    /// Returns true for a pass in the gate's own direction, false for a pass against it, and nil
    /// when the segment did not go through the opening at all.
    private func crossingDirection(
        gate: RaceGateGeometry,
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) -> Bool? {
        let d0 = simd_dot(from - gate.centre, gate.normal)
        let d1 = simd_dot(to - gate.centre, gate.normal)
        // Both on the same side (or exactly in the plane at both ends): no crossing.
        guard (d0 < 0.0) != (d1 < 0.0) else { return nil }
        let denominator = d0 - d1
        guard abs(denominator) > 1e-6 else { return nil }

        let t = d0 / denominator
        guard t >= 0.0, t <= 1.0 else { return nil }
        let point = from + (to - from) * t
        let offset = point - gate.centre
        let u = simd_dot(offset, gate.lateral) / max(0.01, gate.halfWidth)
        let v = simd_dot(offset, gate.vertical) / max(0.01, gate.halfHeight)
        // Elliptical aperture: the pack's openings are hexagons, pentagons and arches, and an
        // inscribed ellipse is a fairer stand-in for all of them than the bounding rectangle,
        // which would score a pass through a corner the frame actually occupies.
        guard u * u + v * v <= 1.0 else { return nil }

        return d0 < 0.0
    }

    private mutating func handleCrossing(gate: RaceGateGeometry, isForward: Bool) {
        // A tower is a tube: diving through it and climbing out of it are both real lines, so
        // there is no wrong way through one. Every other gate has a face the pilot is meant to
        // meet, and taking it from behind is a miss, not a pass.
        guard isForward || gate.isVertical else {
            flagWrongWay(gate)
            return
        }

        switch mode {
        case .free:
            gateStates[gate.elementID] = .passed
            pendingEvents.append(.gatePassed(order: gate.order, elapsed: totalElapsedSeconds))
        case .timed:
            guard gate.order == nextGateOrder else {
                // Out of sequence: taking a later gate early is not a foul, it just does not
                // count. The line the pilot has to fly is still shown by the highlight, so there
                // is nothing to punish — the gate they skipped is waiting for them.
                return
            }
            advanceSequence(after: gate)
        }
    }

    /// A lap is the full circuit: the first gate both closes the lap that was running and opens
    /// the next one, exactly as a start/finish line does on a real circuit. Ending the lap on the
    /// *last* gate instead would leave the leg back to the start out of every lap time, which is
    /// the kind of quiet inaccuracy that makes a personal best meaningless.
    private mutating func advanceSequence(after gate: RaceGateGeometry) {
        let ordered = gates
        guard let index = ordered.firstIndex(where: { $0.order == gate.order }) else { return }
        let next = ordered[(index + 1) % ordered.count]

        func takeGate(resettingCount: Bool) {
            gatesTakenThisLap = resettingCount ? 1 : gatesTakenThisLap + 1
            gateStates[gate.elementID] = .passed
            nextGateOrder = next.order
            gateStates[next.elementID] = .next
            pendingEvents.append(.gatePassed(order: gate.order, elapsed: totalElapsedSeconds))
        }

        if objectiveState == .armed {
            // The clock starts on the first gate, not on takeoff: it is the pilot's own run that
            // is being timed, not how long they spent lining up on the pad.
            objectiveState = .racing
            currentLap = 1
            currentLapSeconds = 0.0
            totalElapsedSeconds = 0.0
            pendingEvents.append(.started)
            takeGate(resettingCount: true)
            return
        }

        let isLapClosing = gate.order == ordered.first?.order && gatesTakenThisLap >= ordered.count
        guard isLapClosing else {
            takeGate(resettingCount: false)
            return
        }

        completeLap()
        guard !isFinished else { return }
        // The same crossing that closed the lap opens the next one.
        for other in ordered {
            gateStates[other.elementID] = .idle
        }
        takeGate(resettingCount: true)
    }

    private mutating func completeLap() {
        let lapSeconds = currentLapSeconds
        lapTimes.append(lapSeconds)
        let isBest = bestLapSeconds.map { lapSeconds < $0 } ?? true
        if isBest {
            bestLapSeconds = lapSeconds
        }
        pendingEvents.append(.lapCompleted(lap: currentLap, lapSeconds: lapSeconds, isBestLap: isBest))

        if currentLap >= lapCount {
            objectiveState = .finished
            nextGateOrder = nil
            pendingEvents.append(.raceFinished(
                totalSeconds: totalElapsedSeconds,
                bestLapSeconds: bestLapSeconds ?? lapSeconds
            ))
            return
        }

        currentLap += 1
        currentLapSeconds = 0.0
    }

    private mutating func flagWrongWay(_ gate: RaceGateGeometry) {
        gateStates[gate.elementID] = .wrongWay
        wrongWayTimers[gate.elementID] = Self.wrongWayFlashSeconds
        pendingEvents.append(.gateWrongWay(order: gate.order))
    }

    private mutating func expireWrongWayFlashes(deltaTime: Double) {
        guard !wrongWayTimers.isEmpty else { return }
        for (id, remaining) in wrongWayTimers {
            let left = remaining - deltaTime
            if left <= 0.0 {
                wrongWayTimers.removeValue(forKey: id)
                gateStates[id] = (id == nextGate?.elementID) ? .next : .idle
            } else {
                wrongWayTimers[id] = left
            }
        }
    }
}
