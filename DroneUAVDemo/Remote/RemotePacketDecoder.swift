import Foundation

final class RemotePacketDecoder {
    private enum DecodeError: Error {
        case bufferOverflow(limit: Int)
    }

    private let decoder = JSONDecoder()
    private let maxBufferedBytes: Int
    private var buffer = Data()

    init(maxBufferedBytes: Int = 64 * 1024) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    func append(_ data: Data, onError: (Error) -> Void) -> [RemoteControlPacket] {
        guard !data.isEmpty else {
            return []
        }

        buffer.append(data)
        if buffer.count > maxBufferedBytes {
            onError(DecodeError.bufferOverflow(limit: maxBufferedBytes))
            buffer.removeAll(keepingCapacity: false)
            return []
        }

        var packets: [RemoteControlPacket] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let rawLine = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)

            let payload = normalizedPayload(from: rawLine)
            guard !payload.isEmpty else {
                continue
            }

            do {
                packets.append(try decoder.decode(RemoteControlPacket.self, from: payload))
            } catch {
                onError(error)
            }
        }

        return packets
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func normalizedPayload(from line: Data) -> Data {
        var payload = line
        if payload.last == 0x0D {
            payload.removeLast()
        }
        return payload
    }
}
