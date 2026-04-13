import Foundation

final class MockRemoteTransport: RemoteTransport {
    var packetHandler: ((RemoteControlPacket) -> Void)?
    var disconnectHandler: (() -> Void)?

    private(set) var isRunning: Bool = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        disconnectHandler?()
    }

    func inject(packet: RemoteControlPacket) {
        guard isRunning else {
            return
        }

        packetHandler?(packet)
    }
}
