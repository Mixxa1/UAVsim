import Foundation

struct InputSnapshot {
    var yaw: Double
    var pitch: Double
    var roll: Double
    var throttle: Double
    /// Non-nil when the source is reporting an absolute throttle setting (0…1) rather than a
    /// rate to add to the current one. A throttle stick reports this; the keyboard and the
    /// triggers do not, because a control that springs back to centre cannot mean "idle".
    var absoluteThrottle: Double?
    var cameraPan: Double
    var cameraTilt: Double
    var uiPointerX: Double
    var uiPointerY: Double
    var uiScrollX: Double
    var uiScrollY: Double

    var precisionMode: Bool
    var boostMode: Bool
    var isHoseSprayHeld: Bool
    var actions: [InputAction]

    var source: InputSourceKind
    var timestamp: TimeInterval
    var isConnected: Bool
    var activityScore: Double

    var armPressed: Bool { actions.contains(.armAircraft) }
    var disarmPressed: Bool { actions.contains(.disarmAircraft) }
    var toggleFPVPressed: Bool { actions.contains(.toggleFPV) }
    var toggleTopViewPressed: Bool { actions.contains(.toggleTopView) }
    var toggleMapPressed: Bool { actions.contains(.toggleMissionMap) }
    var togglePayloadPressed: Bool { actions.contains(.togglePayloadPanel) }
    var dropPayloadPressed: Bool { actions.contains(.dropPayload) }
    var returnHomePressed: Bool { actions.contains(.returnHome) }
    var pauseMissionPressed: Bool { actions.contains(.pauseMission) }
    var resumeMissionPressed: Bool { actions.contains(.resumeMission) }

    static func neutral(
        source: InputSourceKind,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        isConnected: Bool = false
    ) -> InputSnapshot {
        InputSnapshot(
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
            isHoseSprayHeld: false,
            actions: [],
            source: source,
            timestamp: timestamp,
            isConnected: isConnected,
            activityScore: 0.0
        )
    }
}
