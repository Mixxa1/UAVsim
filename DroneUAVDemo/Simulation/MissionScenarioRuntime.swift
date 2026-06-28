import Foundation

/// Detection thresholds for a scenario, derived from the chosen payload.
struct MissionDetectionTuning: Equatable {
    var maxRangeMeters: Float
    var coneHalfAngleDegrees: Float
    /// Continuous observation time required before the target counts as detected.
    var dwellSeconds: Double

    static func make(for payload: PayloadType) -> MissionDetectionTuning {
        // Must comfortably exceed the largest search-sector radius (320 m on hard difficulty) —
        // the payload camera zooms up to 50x specifically to resolve targets at that range (the
        // optics HUD's own FOCUS/TARGET readout routinely shows 200+ m as a normal, expected
        // operating distance), so a short hard cap made "hard" missions undetectable by design.
        switch payload {
        case .thermalCamera:
            // Thermal: a warm body stands out, so a generous cone and long effective range.
            return MissionDetectionTuning(maxRangeMeters: 380.0, coneHalfAngleDegrees: 24.0, dwellSeconds: 0.7)
        case .cameraGimbal:
            // Optical: longer reach, tighter cone, slightly longer confirmation in daylight.
            return MissionDetectionTuning(maxRangeMeters: 420.0, coneHalfAngleDegrees: 20.0, dwellSeconds: 0.8)
        default:
            return MissionDetectionTuning(maxRangeMeters: 400.0, coneHalfAngleDegrees: 22.0, dwellSeconds: 0.8)
        }
    }
}

/// Pure scenario logic: counts down the time budget and confirms a detection once the payload
/// camera holds the target within range + cone + line of sight for the dwell duration.
///
/// Holds no SceneKit state — the simulation view model feeds it a `MissionTargetDetectionSample`
/// each tick (or `nil` when the target isn't currently sampleable).
struct MissionScenarioRuntime {
    let configuration: MissionScenarioConfiguration
    let placement: MissionScenarioPlacement
    let tuning: MissionDetectionTuning

    private(set) var objectiveState: MissionScenarioObjectiveState = .searching
    private(set) var outcome: MissionScenarioOutcome?
    private(set) var remainingSeconds: Double
    private(set) var elapsedSeconds: Double = 0.0
    private var dwellAccumulator: Double = 0.0

    init(configuration: MissionScenarioConfiguration, placement: MissionScenarioPlacement) {
        self.configuration = configuration
        self.placement = placement
        self.tuning = MissionDetectionTuning.make(for: configuration.payloadType)
        self.remainingSeconds = configuration.parameters.timeLimitSeconds
    }

    var isActive: Bool { outcome == nil }

    /// 0...1 progress of the current continuous lock-on (for HUD feedback). Resets when the
    /// target leaves the detection envelope.
    var detectionProgress: Double {
        guard tuning.dwellSeconds > 0 else { return dwellAccumulator > 0 ? 1.0 : 0.0 }
        return min(1.0, dwellAccumulator / tuning.dwellSeconds)
    }

    var remainingClampedSeconds: Double { max(0.0, remainingSeconds) }

    /// Whether the target is currently inside the detection envelope (range + cone + LOS).
    func sampleInsideEnvelope(_ sample: MissionTargetDetectionSample?) -> Bool {
        guard let sample else { return false }
        return sample.lineOfSightClear
            && sample.distanceMeters <= tuning.maxRangeMeters
            && sample.angleFromCameraAxisDegrees <= tuning.coneHalfAngleDegrees
    }

    mutating func tick(deltaTime: Double, sample: MissionTargetDetectionSample?) {
        guard isActive, objectiveState == .searching, deltaTime > 0 else { return }

        elapsedSeconds += deltaTime
        remainingSeconds -= deltaTime

        if sampleInsideEnvelope(sample) {
            dwellAccumulator += deltaTime
            if dwellAccumulator >= tuning.dwellSeconds {
                objectiveState = .detected
                outcome = .success(detectionElapsedSeconds: elapsedSeconds)
                return
            }
        } else {
            dwellAccumulator = 0.0
        }

        if remainingSeconds <= 0.0 {
            remainingSeconds = 0.0
            objectiveState = .failedTimeout
            outcome = .failureTimeout
        }
    }

    /// Marks the mission aborted (e.g. operator exits early) if it hasn't already concluded.
    mutating func abort() {
        guard isActive else { return }
        outcome = .aborted
    }
}
