import Foundation
import Network

final class NetworkRemoteHost: RemoteTransport {
    var packetHandler: ((RemoteControlPacket) -> Void)?
    var disconnectHandler: (() -> Void)?

    private let port: UInt16
    private let queue: DispatchQueue
    private let decoder = RemotePacketDecoder()

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var isRunning: Bool = false

    init(
        port: UInt16 = 7777,
        queue: DispatchQueue = DispatchQueue(label: "DroneUAVDemo.remote.host")
    ) {
        self.port = port
        self.queue = queue
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else {
                return
            }

            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                self.debugLog("Invalid TCP port \(self.port)")
                return
            }

            do {
                let listener = try NWListener(using: .tcp, on: nwPort)
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleNewConnection(connection)
                }

                self.listener = listener
                self.isRunning = true
                listener.start(queue: self.queue)
            } catch {
                self.debugLog("Failed to start listener on port \(self.port): \(error)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.cancelActiveConnection(reason: "listener stopped")
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.decoder.reset()
            self.isRunning = false
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .setup:
            break
        case .waiting(let error):
            debugLog("Listener waiting: \(error)")
        case .ready:
            debugLog("Listening for remote packets on TCP \(port)")
        case .failed(let error):
            debugLog("Listener failed: \(error)")
            stop()
        case .cancelled:
            debugLog("Listener cancelled")
        @unknown default:
            debugLog("Listener entered unknown state")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        if activeConnection != nil {
            debugLog("Replacing active remote client connection")
            cancelActiveConnection(reason: "replaced by a new client")
        }

        decoder.reset()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }

            self.handleConnectionState(state, for: connection)
        }

        connection.start(queue: queue)
        receiveNextChunk(on: connection)
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        guard activeConnection === connection else {
            return
        }

        switch state {
        case .setup:
            break
        case .preparing:
            break
        case .waiting(let error):
            debugLog("Client waiting: \(error)")
        case .ready:
            debugLog("Remote client connected")
        case .failed(let error):
            debugLog("Client connection failed: \(error)")
            cancelActiveConnection(reason: "connection failed")
        case .cancelled:
            debugLog("Remote client disconnected")
            clearActiveConnection()
        @unknown default:
            debugLog("Client entered unknown state")
        }
    }

    private func receiveNextChunk(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }

            guard self.activeConnection === connection else {
                return
            }

            if let data, !data.isEmpty {
                let packets = self.decoder.append(data) { [weak self] decodeError in
                    self?.debugLog("Packet decode failed: \(decodeError)")
                }

                for packet in packets {
                    self.packetHandler?(packet)
                }
            }

            if let error {
                self.debugLog("Receive error: \(error)")
                self.cancelActiveConnection(reason: "receive error")
                return
            }

            if isComplete {
                self.debugLog("Remote client closed the stream")
                self.cancelActiveConnection(reason: "stream completed")
                return
            }

            self.receiveNextChunk(on: connection)
        }
    }

    private func cancelActiveConnection(reason: String) {
        if let activeConnection {
            activeConnection.stateUpdateHandler = nil
            activeConnection.cancel()
            debugLog("Closing active connection: \(reason)")
        }

        clearActiveConnection()
    }

    private func clearActiveConnection() {
        let hadConnection = activeConnection != nil
        activeConnection = nil
        decoder.reset()
        if hadConnection {
            disconnectHandler?()
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[NetworkRemoteHost] \(message)")
        #endif
    }
}
