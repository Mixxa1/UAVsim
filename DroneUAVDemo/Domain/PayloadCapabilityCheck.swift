import Foundation

enum PayloadCapabilityRejectReason: String, Hashable {
    case selectUAVFirst
    case payloadMassExceeded
    case totalMassExceeded
    case dataUnavailable
    case invalidPayloadMass

    var messageKey: String {
        switch self {
        case .selectUAVFirst:
            return "payload.message.select_uav"
        case .payloadMassExceeded:
            return "payload.message.payload_limit_exceeded"
        case .totalMassExceeded:
            return "payload.message.takeoff_limit_exceeded"
        case .dataUnavailable:
            return "payload.message.data_unavailable"
        case .invalidPayloadMass:
            return "payload.message.invalid_mass"
        }
    }
}

struct PayloadCapabilityCheck: Hashable {
    let isPayloadMassAllowed: Bool
    let isTakeoffMassAllowed: Bool
    let resultingTotalMass: Float?
    let rejectReason: PayloadCapabilityRejectReason?

    var isAllowed: Bool {
        isPayloadMassAllowed && isTakeoffMassAllowed && rejectReason == nil
    }

    static let unavailable = PayloadCapabilityCheck(
        isPayloadMassAllowed: false,
        isTakeoffMassAllowed: false,
        resultingTotalMass: nil,
        rejectReason: .dataUnavailable
    )
}
