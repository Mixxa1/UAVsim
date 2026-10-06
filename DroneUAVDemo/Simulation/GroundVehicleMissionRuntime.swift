import Foundation
import simd

/// Pursuit is sustained camera observation of an evading vehicle. Escort is safe proximity
/// throughout a journey to a destination. A contact or a disabled car never wins either task.
struct GroundVehicleMissionRuntime {
    enum Result: String {
        case tracked, arrived, vehicleLost, vehicleDisabled, playerLost, timeExpired
        var isSuccess: Bool { self == .tracked || self == .arrived }
        var titleKey: String { "ground.result.\(rawValue)" }
    }
    let escort: Bool
    let requiredObservation: Double
    let lossLimit: Double
    let route: [SIMD2<Float>]
    private(set) var routeIndex = 0
    private(set) var remaining: Double
    private(set) var observedSeconds: Double = 0
    private(set) var lostSeconds: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var result: Result?
    private var escortSeconds: Double = 0
    private var started = false
    var destination: SIMD2<Float>? { escort && routeIndex < route.count ? route[routeIndex] : nil }
    var progress: Double {
        escort ? Double(routeIndex) / Double(max(1, route.count)) : min(1, observedSeconds / requiredObservation)
    }

    init(escort: Bool, difficulty: MissionDifficulty, timeLimit: Double, route: [SIMD2<Float>]) {
        self.escort = escort; self.route = route; remaining = max(30, timeLimit)
        switch difficulty {
        case .easy: requiredObservation = 45; lossLimit = 30
        case .medium: requiredObservation = 75; lossLimit = 20
        case .hard: requiredObservation = 110; lossLimit = 12
        }
    }

    mutating func tick(deltaTime: Double, playerAirborne: Bool, playerLost: Bool,
                       carPosition: SIMD2<Float>, carCondition: InterceptFunctionalState,
                       distance: Float, inCamera: Bool, lineOfSight: Bool) {
        guard result == nil, deltaTime > 0, deltaTime.isFinite else { return }
        // Allow pre-flight setup; the vehicle starts travelling when the player takes off.
        started = started || playerAirborne
        guard started else { return }
        elapsed += deltaTime; remaining = max(0, remaining - deltaTime)
        if playerLost { result = .playerLost; return }
        if carCondition.isTerminal { result = .vehicleDisabled; return }
        let observed = distance >= 8 && distance <= (escort ? 140 : 300) && lineOfSight && (escort || inCamera)
        if observed {
            lostSeconds = 0
            if escort { escortSeconds += deltaTime } else { observedSeconds += deltaTime }
        } else { lostSeconds += deltaTime }
        if lostSeconds >= lossLimit { result = .vehicleLost; return }
        if escort, let destination, simd_distance(carPosition, destination) < 12 {
            routeIndex += 1
            if routeIndex == route.count {
                result = escortSeconds / max(1, elapsed) >= 0.7 ? .arrived : .vehicleLost
                return
            }
        } else if !escort, observedSeconds >= requiredObservation {
            result = .tracked; return
        }
        if remaining <= 0 { result = .timeExpired }
    }
}

struct GroundVehicleMissionHUD: Equatable {
    var remaining: Double = 0
    var progress: Double = 0
    var lostSeconds: Double = 0
    var lossLimit: Double = 20
    var distance: Float = 0
    var speed: Float = 0
    var condition: InterceptFunctionalState = .nominal
    var inCamera = false
    var result: GroundVehicleMissionRuntime.Result?
    var conditionTitleKey: String { "ground.condition.\(condition.rawValue)" }
}
