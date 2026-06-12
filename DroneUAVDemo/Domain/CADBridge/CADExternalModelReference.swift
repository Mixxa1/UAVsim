import Foundation

struct CADBridgeVector3: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = CADBridgeVector3(x: 0, y: 0, z: 0)
}

struct CADExternalModelReference: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var sourcePath: String
    var previewMeshPath: String?
    var collisionMeshPath: String?
    var massKg: Double?
    var centerOfMass: CADBridgeVector3?
    var attachmentPoints: [CADAttachmentImport]
    var materialTags: [String]
    var uavRoleTags: [String]

    init(
        id: UUID = UUID(),
        name: String,
        sourcePath: String,
        previewMeshPath: String? = nil,
        collisionMeshPath: String? = nil,
        massKg: Double? = nil,
        centerOfMass: CADBridgeVector3? = nil,
        attachmentPoints: [CADAttachmentImport] = [],
        materialTags: [String] = [],
        uavRoleTags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.previewMeshPath = previewMeshPath
        self.collisionMeshPath = collisionMeshPath
        self.massKg = massKg
        self.centerOfMass = centerOfMass
        self.attachmentPoints = attachmentPoints
        self.materialTags = materialTags
        self.uavRoleTags = uavRoleTags
    }
}
