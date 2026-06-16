import Foundation
import Network

final class NetworkLANSessionTransport: LANSessionTransport {
    var onMessage: ((LANSessionMessage) -> Void)?
    var onConnectionStateChanged: ((LANConnectionState, String?) -> Void)?

    private let queue = DispatchQueue(label: "uavsim.lan.session.transport")
    private var listener: NWListener?
    private var clientConnection: NWConnection?
    private var connections: [NWConnection] = []
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var isStopping = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // TCP noDelay prevents Nagle buffering of small JSON snapshot packets,
    // reducing bursty delivery that causes stutter in remote replica movement.
    private static let lanParameters: NWParameters = {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }()

    func startHost(port: UInt16) throws {
        stopTransport(notify: false)
        isStopping = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LANSessionTransportError.invalidPort
        }

        let listener = try NWListener(using: NetworkLANSessionTransport.lanParameters, on: nwPort)
        self.listener = listener
        notifyState(.hosting)

        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }
        listener.start(queue: queue)
    }

    func connect(to host: String, port: UInt16) throws {
        stopTransport(notify: false)
        isStopping = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LANSessionTransportError.invalidPort
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: NetworkLANSessionTransport.lanParameters
        )
        clientConnection = connection
        notifyState(.joining)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            self?.handleConnectionState(state, connection: connection, isClientConnection: true)
        }
        connection.start(queue: queue)
        receiveLoop(for: connection)
    }

    func send(_ message: LANSessionMessage) {
        queue.async {
            guard let payload = self.encodedPayload(for: message) else { return }

            if let clientConnection = self.clientConnection {
                self.send(payload, on: clientConnection)
            } else {
                self.connections.forEach { self.send(payload, on: $0) }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopTransport(notify: true)
        }
    }

    private func acceptConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connections.append(connection)
            self.receiveBuffers[ObjectIdentifier(connection)] = Data()
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                self?.handleConnectionState(state, connection: connection, isClientConnection: false)
            }
            connection.start(queue: self.queue)
            self.receiveLoop(for: connection)
        }
    }

    private func receiveLoop(for connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                self.appendAndDecode(data, for: connection)
            }

            if let error {
                self.remove(connection)
                guard !self.isStopping else { return }
                self.notifyState(.failed, message: error.localizedDescription)
                return
            }

            if isComplete {
                self.remove(connection)
                return
            }

            self.receiveLoop(for: connection)
        }
    }

    private func appendAndDecode(_ data: Data, for connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = receiveBuffers[key] ?? Data()
        buffer.append(data)

        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let line = buffer[..<newlineRange.lowerBound]
            buffer.removeSubrange(..<newlineRange.upperBound)

            guard !line.isEmpty else { continue }
            do {
                let message = try decoder.decode(LANSessionMessage.self, from: Data(line))
                DispatchQueue.main.async { [weak self] in
                    self?.onMessage?(message)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.onConnectionStateChanged?(.failed, error.localizedDescription)
                }
            }
        }

        receiveBuffers[key] = buffer
    }

    private func encodedPayload(for message: LANSessionMessage) -> Data? {
        guard var data = try? encoder.encode(message) else { return nil }
        data.append(0x0A)
        return data
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, let error else { return }
            self.remove(connection)
            guard !self.isStopping else { return }
            self.notifyState(.failed, message: error.localizedDescription)
        })
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            notifyState(.hosting)
        case let .failed(error):
            stopTransport(notify: false)
            notifyState(.failed, message: error.localizedDescription)
        case .cancelled:
            if !isStopping {
                notifyState(.disconnected)
            }
        case .setup, .waiting(_):
            break
        @unknown default:
            break
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection: NWConnection,
        isClientConnection: Bool
    ) {
        switch state {
        case .ready:
            notifyState(isClientConnection ? .connected : .hosting)
        case let .failed(error):
            remove(connection)
            guard !isStopping else { return }
            notifyState(.failed, message: error.localizedDescription)
        case .cancelled:
            remove(connection)
            if isClientConnection {
                clientConnection = nil
                if !isStopping {
                    notifyState(.disconnected)
                }
            }
        case .setup, .preparing:
            break
        case .waiting(_):
            notifyState(.joining)
        @unknown default:
            break
        }
    }

    private func remove(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        receiveBuffers[key] = nil
        connections.removeAll { $0 === connection }

        if clientConnection === connection {
            clientConnection = nil
        }
    }

    private func stopTransport(notify: Bool) {
        isStopping = true
        listener?.cancel()
        listener = nil

        clientConnection?.cancel()
        clientConnection = nil

        connections.forEach { $0.cancel() }
        connections.removeAll()
        receiveBuffers.removeAll()

        if notify {
            notifyState(.disconnected)
        }
    }

    private func notifyState(_ state: LANConnectionState, message: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChanged?(state, message)
        }
    }
}

enum LANSessionTransportError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Некорректный порт LAN-сессии."
        }
    }
}
