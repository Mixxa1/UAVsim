import Foundation

struct MissionRuntimeConstraintState: Equatable {
    var hasValidatedPlan: Bool
    var hasExecutionContour: Bool
    var hasMissionTarget: Bool
    var hasRuntimeDistance: Bool
    var targetBindingAvailable: Bool
    var batterySafeToStart: Bool
    var batterySafeToContinue: Bool
    var collisionSafe: Bool
    var thermalSafe: Bool
    var signalSafe: Bool
    var routeHealthy: Bool
    var progressHealthy: Bool
    var adapterHealthy: Bool

    var isSafeToStart: Bool {
        hasValidatedPlan &&
        hasExecutionContour &&
        hasMissionTarget &&
        hasRuntimeDistance &&
        targetBindingAvailable &&
        batterySafeToStart &&
        collisionSafe &&
        thermalSafe &&
        signalSafe &&
        routeHealthy &&
        adapterHealthy
    }

    var isSafeToContinue: Bool {
        hasValidatedPlan &&
        hasExecutionContour &&
        hasMissionTarget &&
        batterySafeToContinue &&
        collisionSafe &&
        thermalSafe &&
        signalSafe &&
        routeHealthy &&
        progressHealthy &&
        adapterHealthy
    }

    static let idle = MissionRuntimeConstraintState(
        hasValidatedPlan: false,
        hasExecutionContour: false,
        hasMissionTarget: false,
        hasRuntimeDistance: false,
        targetBindingAvailable: false,
        batterySafeToStart: false,
        batterySafeToContinue: false,
        collisionSafe: true,
        thermalSafe: true,
        signalSafe: true,
        routeHealthy: false,
        progressHealthy: true,
        adapterHealthy: true
    )
}
