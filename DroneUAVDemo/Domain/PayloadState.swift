import Foundation

enum PayloadState: String, Hashable {
    case noPayload
    case attached
    case removed

    var title: String {
        switch self {
        case .noPayload:
            return NSLocalizedString("payload.state.no_payload", comment: "")
        case .attached:
            return NSLocalizedString("payload.state.attached", comment: "")
        case .removed:
            return NSLocalizedString("payload.state.removed", comment: "")
        }
    }
}
