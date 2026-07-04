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
    /// Only meaningful when `payloadType == .fireCapsuleLauncher` — the rigged capsule size and
    /// count, which together determine `payloadMass` (see `FireCapsuleTuning.totalMass`) and, at
    /// runtime, the launcher's starting ammo count and each capsule's blast radius.
    var fireCapsuleSize: FireCapsuleSize
    var fireCapsuleCount: Int

    init(
        payloadType: PayloadType = .cameraGimbal,
        customName: String = "",
        payloadMass: Float? = nil,
        visualPreset: PayloadVisualPreset? = nil,
        isAttached: Bool = false,
        fireHoseDiameterClass: FireHoseDiameterClass = .standard,
        fireHoseLengthMeters: Float = 30.0,
        fireCapsuleSize: FireCapsuleSize = .medium,
        fireCapsuleCount: Int = 2
    ) {
        self.payloadType = payloadType
        self.customName = customName
        self.fireHoseDiameterClass = fireHoseDiameterClass
        self.fireHoseLengthMeters = fireHoseLengthMeters
        self.fireCapsuleSize = fireCapsuleSize
        let clampedCapsuleCount = min(max(fireCapsuleCount, FireCapsuleTuning.countRange.lowerBound), FireCapsuleTuning.countRange.upperBound)
        self.fireCapsuleCount = clampedCapsuleCount
        self.payloadMass = payloadMass ?? {
            switch payloadType {
            case .fireHose:
                return fireHoseDiameterClass.massForLength(fireHoseLengthMeters)
            case .fireCapsuleLauncher:
                return FireCapsuleTuning.totalMass(size: fireCapsuleSize, count: clampedCapsuleCount)
            default:
                return payloadType.defaultMass
            }
        }()
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
