import Foundation

struct ResolvedControlState {
    var yaw: Double
    var pitch: Double
    var roll: Double
    var throttle: Double
    var cameraPan: Double
    var cameraTilt: Double
    var uiPointerX: Double
    var uiPointerY: Double
    var uiScrollX: Double
    var uiScrollY: Double

    var precisionMode: Bool
    var boostMode: Bool
    var actions: [InputAction]
    var dominantSource: InputSourceKind?

    var armTriggered: Bool { actions.contains(.armAircraft) }
    var disarmTriggered: Bool { actions.contains(.disarmAircraft) }
    var toggleFPVTriggered: Bool { actions.contains(.toggleFPV) }
    var toggleTopViewTriggered: Bool { actions.contains(.toggleTopView) }
    var toggleMapTriggered: Bool { actions.contains(.toggleMissionMap) }
    var togglePayloadTriggered: Bool { actions.contains(.togglePayloadPanel) }
    var dropPayloadTriggered: Bool { actions.contains(.dropPayload) }
    var returnHomeTriggered: Bool { actions.contains(.returnHome) }
    var pauseMissionTriggered: Bool { actions.contains(.pauseMission) }
    var resumeMissionTriggered: Bool { actions.contains(.resumeMission) }
    var toggleControllerCursorTriggered: Bool { actions.contains(.toggleControllerCursor) }
    var openControllerHubTriggered: Bool { actions.contains(.openControllerHub) }
    var uiSectionPreviousTriggered: Bool { actions.contains(.uiSectionPrevious) }
    var uiSectionNextTriggered: Bool { actions.contains(.uiSectionNext) }
    var uiPrimaryTriggered: Bool { actions.contains(.uiPrimary) }
    var uiSecondaryTriggered: Bool { actions.contains(.uiSecondary) }
    var uiFocusUpTriggered: Bool { actions.contains(.uiFocusUp) }
    var uiFocusDownTriggered: Bool { actions.contains(.uiFocusDown) }
    var uiFocusLeftTriggered: Bool { actions.contains(.uiFocusLeft) }
    var uiFocusRightTriggered: Bool { actions.contains(.uiFocusRight) }

    static let neutral = ResolvedControlState(
        yaw: 0.0,
        pitch: 0.0,
        roll: 0.0,
        throttle: 0.0,
        cameraPan: 0.0,
        cameraTilt: 0.0,
        uiPointerX: 0.0,
        uiPointerY: 0.0,
        uiScrollX: 0.0,
        uiScrollY: 0.0,
        precisionMode: false,
        boostMode: false,
        actions: [],
        dominantSource: nil
    )
}

extension InputAction {
    var isControllerUIAction: Bool {
        switch self {
        case .toggleControllerCursor, .openControllerHub,
             .uiSectionPrevious, .uiSectionNext,
             .uiPrimary, .uiSecondary,
             .uiFocusUp, .uiFocusDown, .uiFocusLeft, .uiFocusRight:
            return true
        default:
            return false
        }
    }
}
