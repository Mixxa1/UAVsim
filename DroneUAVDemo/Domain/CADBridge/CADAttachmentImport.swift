import Foundation

struct CADAttachmentImport: Codable, Equatable, Identifiable {
    enum Role: String, Codable, CaseIterable {
        case frame
        case wing
        case payload
        case camera
        case sensor
        case landingGear
        case motor
        case battery
        case antenna
        case generic
    }

    var id: UUID
    var name: String
    var localPosition: CADBridgeVector3
    var localRotation: CADBridgeVector3
    var role: Role
    var isEnabled: Bool
    var materialTags: [String]
    var uavRoleTags: [String]

    init(
        id: UUID = UUID(),
        name: String,
        localPosition: CADBridgeVector3 = .zero,
        localRotation: CADBridgeVector3 = .zero,
        role: Role = .generic,
        isEnabled: Bool = true,
        materialTags: [String] = [],
        uavRoleTags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.localPosition = localPosition
        self.localRotation = localRotation
        self.role = role
        self.isEnabled = isEnabled
        self.materialTags = materialTags
        self.uavRoleTags = uavRoleTags
    }
}
