import Foundation

enum PayloadDataQualitySource: String, Hashable {
    case verified
    case estimated
    case custom

    var title: String {
        switch self {
        case .verified:
            return L10n.s("payload.data.verified")
        case .estimated:
            return L10n.s("payload.data.estimated")
        case .custom:
            return L10n.s("payload.data.custom")
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
