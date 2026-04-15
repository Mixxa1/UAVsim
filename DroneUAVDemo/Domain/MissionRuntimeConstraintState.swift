import Foundation

struct MissionRuntimeConstraintState: Equatable {
    var hasValidatedPlan: Bool
    var hasExecutionContour: Bool
    var hasMissionTarget: Bool
    var hasRuntimeDistance: Bool
    var targetBindingAvailable: Bool
    var batterySafeToStart: Bool
    var batterySafeToContinue: Bool
    var returnSafe: Bool
    var missionSafe: Bool
    var collisionSafe: Bool
    var thermalSafe: Bool
    var signalSafe: Bool
    var mapScaleSuitable: Bool
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
        returnSafe &&
        missionSafe &&
        collisionSafe &&
        thermalSafe &&
        signalSafe &&
        mapScaleSuitable &&
        routeHealthy &&
        adapterHealthy
    }

    var isSafeToContinue: Bool {
        hasValidatedPlan &&
        hasExecutionContour &&
        hasMissionTarget &&
        batterySafeToContinue &&
        returnSafe &&
        collisionSafe &&
        thermalSafe &&
        signalSafe &&
        mapScaleSuitable &&
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
        returnSafe: false,
        missionSafe: false,
        collisionSafe: true,
        thermalSafe: true,
        signalSafe: true,
        mapScaleSuitable: true,
        routeHealthy: false,
        progressHealthy: true,
        adapterHealthy: true
    )
}
