import Foundation

enum PayloadState: String, Hashable {
    case noPayload
    case attached
    case removed
    case released
    case falling
    case landed
    case cleanedUp

    var title: String {
        switch self {
        case .noPayload:
            return NSLocalizedString("payload.state.no_payload", comment: "")
        case .attached:
            return NSLocalizedString("payload.state.attached", comment: "")
        case .removed:
            return NSLocalizedString("payload.state.removed", comment: "")
        case .released:
            return NSLocalizedString("payload.state.released", comment: "")
        case .falling:
            return NSLocalizedString("payload.state.falling", comment: "")
        case .landed:
            return NSLocalizedString("payload.state.landed", comment: "")
        case .cleanedUp:
            return NSLocalizedString("payload.state.cleaned_up", comment: "")
        }
    }
}
