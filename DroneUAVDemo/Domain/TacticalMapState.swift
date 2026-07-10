import Foundation
import simd

struct TacticalMapState: Equatable {
    var isVisible: Bool
    var mode: TacticalMapMode
    var viewport: MapViewportState
    var committedDraft: MissionDraft
    var workingDraft: MissionDraft
    var launchPreview: MissionLaunchPreview?
    var previewRoute: MissionPreviewRoute?
    var draftStatus: MissionDraftStatus
    var isDraftDirty: Bool

    static let empty = TacticalMapState(
        isVisible: false,
        mode: .waypoint,
        viewport: .empty,
        committedDraft: .empty,
        workingDraft: .empty,
        launchPreview: nil,
        previewRoute: nil,
        draftStatus: .empty,
        isDraftDirty: false
    )
}
