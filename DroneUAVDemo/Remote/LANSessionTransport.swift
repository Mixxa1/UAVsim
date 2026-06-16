import Foundation

protocol LANSessionTransport: AnyObject {
    var onMessage: ((LANSessionMessage) -> Void)? { get set }
    var onConnectionStateChanged: ((LANConnectionState, String?) -> Void)? { get set }

    func startHost(port: UInt16) throws
    func connect(to host: String, port: UInt16) throws
    func send(_ message: LANSessionMessage)
    func stop()
}
