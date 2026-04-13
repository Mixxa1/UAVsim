import Foundation

struct RemoteControlPacket: Codable {
    var seq: Int
    var timestamp: TimeInterval

    var yaw: Double
    var pitch: Double
    var roll: Double
    var throttle: Double
    var cameraPan: Double
    var cameraTilt: Double

    var precisionMode: Bool
    var boostMode: Bool

    var armPressed: Bool
    var disarmPressed: Bool
    var toggleFPVPressed: Bool
    var toggleTopViewPressed: Bool
    var toggleMapPressed: Bool
    var togglePayloadPressed: Bool
    var dropPayloadPressed: Bool
    var returnHomePressed: Bool
    var pauseMissionPressed: Bool
    var resumeMissionPressed: Bool

    init(
        seq: Int,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        yaw: Double = 0.0,
        pitch: Double = 0.0,
        roll: Double = 0.0,
        throttle: Double = 0.0,
        cameraPan: Double = 0.0,
        cameraTilt: Double = 0.0,
        precisionMode: Bool = false,
        boostMode: Bool = false,
        armPressed: Bool = false,
        disarmPressed: Bool = false,
        toggleFPVPressed: Bool = false,
        toggleTopViewPressed: Bool = false,
        toggleMapPressed: Bool = false,
        togglePayloadPressed: Bool = false,
        dropPayloadPressed: Bool = false,
        returnHomePressed: Bool = false,
        pauseMissionPressed: Bool = false,
        resumeMissionPressed: Bool = false
    ) {
        self.seq = seq
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.throttle = throttle
        self.cameraPan = cameraPan
        self.cameraTilt = cameraTilt
        self.precisionMode = precisionMode
        self.boostMode = boostMode
        self.armPressed = armPressed
        self.disarmPressed = disarmPressed
        self.toggleFPVPressed = toggleFPVPressed
        self.toggleTopViewPressed = toggleTopViewPressed
        self.toggleMapPressed = toggleMapPressed
        self.togglePayloadPressed = togglePayloadPressed
        self.dropPayloadPressed = dropPayloadPressed
        self.returnHomePressed = returnHomePressed
        self.pauseMissionPressed = pauseMissionPressed
        self.resumeMissionPressed = resumeMissionPressed
    }
}
