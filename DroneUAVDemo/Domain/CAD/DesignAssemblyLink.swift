import Foundation

// Placeholder for a future attachment-point based assembly editor.
// Stage 1.3 keeps this disconnected from UI and simulation logic.
struct DesignAssemblyLink: Codable, Identifiable, Equatable {
    var id: UUID
    var parentAssetID: UUID
    var parentAttachmentPointID: UUID
    var childAssetID: UUID
    var childAttachmentPointID: UUID

    init(
        id: UUID = UUID(),
        parentAssetID: UUID,
        parentAttachmentPointID: UUID,
        childAssetID: UUID,
        childAttachmentPointID: UUID
    ) {
        self.id = id
        self.parentAssetID = parentAssetID
        self.parentAttachmentPointID = parentAttachmentPointID
        self.childAssetID = childAssetID
        self.childAttachmentPointID = childAttachmentPointID
    }
}
