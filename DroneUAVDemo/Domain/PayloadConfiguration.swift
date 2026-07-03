import Foundation

struct PayloadConfiguration: Hashable {
    var payloadType: PayloadType
    var customName: String
    var payloadMass: Float
    var visualPreset: PayloadVisualPreset
    var isAttached: Bool
    /// Only meaningful when `payloadType == .fireHose` — the rigged hose's diameter class and
    /// length, which together determine `payloadMass` (see `FireHoseDiameterClass.massForLength`)
    /// and, at runtime, the drone's tether distance limit from the fire truck.
    var fireHoseDiameterClass: FireHoseDiameterClass
    var fireHoseLengthMeters: Float

    init(
        payloadType: PayloadType = .cameraGimbal,
        customName: String = "",
        payloadMass: Float? = nil,
        visualPreset: PayloadVisualPreset? = nil,
        isAttached: Bool = false,
        fireHoseDiameterClass: FireHoseDiameterClass = .standard,
        fireHoseLengthMeters: Float = 30.0
    ) {
        self.payloadType = payloadType
        self.customName = customName
        self.fireHoseDiameterClass = fireHoseDiameterClass
        self.fireHoseLengthMeters = fireHoseLengthMeters
        self.payloadMass = payloadMass ?? (
            payloadType == .fireHose
                ? fireHoseDiameterClass.massForLength(fireHoseLengthMeters)
                : payloadType.defaultMass
        )
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
