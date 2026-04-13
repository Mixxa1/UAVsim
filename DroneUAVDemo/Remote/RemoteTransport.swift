import Foundation

protocol RemoteTransport: AnyObject {
    var packetHandler: ((RemoteControlPacket) -> Void)? { get set }
    var disconnectHandler: (() -> Void)? { get set }

    func start()
    func stop()
}
