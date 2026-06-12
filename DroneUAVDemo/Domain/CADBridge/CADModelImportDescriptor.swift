import Foundation

struct CADModelImportDescriptor: Codable, Equatable, Identifiable {
    enum SourceFormat: String, Codable, CaseIterable {
        case brep
        case step
        case stl
        case obj
        case gltf
        case cadnextPackage
    }

    var id: UUID
    var displayName: String
    var sourceFormat: SourceFormat
    var sourcePath: String
    var previewMeshPath: String?
    var collisionMeshPath: String?
    var massProperties: CADMassPropertiesImport?
    var attachments: [CADAttachmentImport]
    var materialTags: [String]
    var uavRoleTags: [String]

    init(
        id: UUID = UUID(),
        displayName: String,
        sourceFormat: SourceFormat,
        sourcePath: String,
        previewMeshPath: String? = nil,
        collisionMeshPath: String? = nil,
        massProperties: CADMassPropertiesImport? = nil,
        attachments: [CADAttachmentImport] = [],
        materialTags: [String] = [],
        uavRoleTags: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceFormat = sourceFormat
        self.sourcePath = sourcePath
        self.previewMeshPath = previewMeshPath
        self.collisionMeshPath = collisionMeshPath
        self.massProperties = massProperties
        self.attachments = attachments
        self.materialTags = materialTags
        self.uavRoleTags = uavRoleTags
    }

    func makeExternalReference() -> CADExternalModelReference {
        CADExternalModelReference(
            id: id,
            name: displayName,
            sourcePath: sourcePath,
            previewMeshPath: previewMeshPath,
            collisionMeshPath: collisionMeshPath,
            massKg: massProperties?.massKg,
            centerOfMass: massProperties?.centerOfMass,
            attachmentPoints: attachments,
            materialTags: materialTags,
            uavRoleTags: uavRoleTags
        )
    }
}
