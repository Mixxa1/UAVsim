import Foundation

enum CADPayloadHandoffError: LocalizedError {
    case unreadable
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return NSLocalizedString("cad.mount_editor.launch_failed", comment: "")
        case let .decodingFailed(error):
            return "\(NSLocalizedString("cad.mount_editor.launch_failed", comment: "")): \(error.localizedDescription)"
        }
    }
}

@MainActor
final class CADPayloadHandoffService {
    static let handoffFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("uavsim_cad_payload_handoff.json")

    private let fileManager: FileManager
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, decoder: JSONDecoder = JSONDecoder()) {
        self.fileManager = fileManager
        self.decoder = decoder
    }

    func consumePendingLaunchConfiguration() -> Result<SimulationLaunchConfiguration, Error>? {
        let url = Self.handoffFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        defer {
            try? fileManager.removeItem(at: url)
        }

        guard let data = try? Data(contentsOf: url) else {
            return .failure(CADPayloadHandoffError.unreadable)
        }

        do {
            return .success(try decoder.decode(SimulationLaunchConfiguration.self, from: data))
        } catch {
            return .failure(CADPayloadHandoffError.decodingFailed(error))
        }
    }
}
