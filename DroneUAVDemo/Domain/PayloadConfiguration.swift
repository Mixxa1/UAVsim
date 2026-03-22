import Foundation

struct PayloadConfiguration: Hashable {
    var payloadType: PayloadType
    var customName: String
    var payloadMass: Float
    var visualPreset: PayloadVisualPreset
    var isAttached: Bool

    init(
        payloadType: PayloadType = .cameraGimbal,
        customName: String = "",
        payloadMass: Float? = nil,
        visualPreset: PayloadVisualPreset? = nil,
        isAttached: Bool = false
    ) {
        self.payloadType = payloadType
        self.customName = customName
        self.payloadMass = payloadMass ?? payloadType.defaultMass
        self.visualPreset = visualPreset ?? payloadType.defaultVisualPreset
        self.isAttached = isAttached
    }

    var resolvedName: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if payloadType == .custom, trimmed.isEmpty == false {
            return trimmed
        }
        return payloadType.title
    }
}
