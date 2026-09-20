import Foundation

enum PayloadMountState: Hashable {
    case unavailable
    case ready
    case occupied

    var title: String {
        switch self {
        case .unavailable:
            return L10n.s("payload.mount.unavailable")
        case .ready:
            return L10n.s("payload.mount.ready")
        case .occupied:
            return L10n.s("payload.mount.occupied")
        }
    }
}
