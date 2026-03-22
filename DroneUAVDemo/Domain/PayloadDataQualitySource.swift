import Foundation

enum PayloadDataQualitySource: String, Hashable {
    case verified
    case estimated
    case custom

    var title: String {
        switch self {
        case .verified:
            return NSLocalizedString("payload.data.verified", comment: "")
        case .estimated:
            return NSLocalizedString("payload.data.estimated", comment: "")
        case .custom:
            return NSLocalizedString("payload.data.custom", comment: "")
        }
    }
}

struct PayloadDataResolution: Hashable {
    let baseMass: Float?
    let batteryMass: Float?
    let maxPayloadMass: Float?
    let maxTakeoffMass: Float?
    let sourceQuality: PayloadDataQualitySource
    let usesEstimatedValues: Bool

    var isAvailable: Bool {
        baseMass != nil &&
        batteryMass != nil &&
        maxPayloadMass != nil &&
        maxTakeoffMass != nil
    }
}
