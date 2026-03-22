import Foundation

enum PayloadMountState: Hashable {
    case unavailable
    case ready
    case occupied

    var title: String {
        switch self {
        case .unavailable:
            return NSLocalizedString("payload.mount.unavailable", comment: "")
        case .ready:
            return NSLocalizedString("payload.mount.ready", comment: "")
        case .occupied:
            return NSLocalizedString("payload.mount.occupied", comment: "")
        }
    }
}
