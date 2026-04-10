import Foundation
import simd

final class TacticalMapCoordinator {
    private let previewBuilder: MissionPreviewBuilder
    private let validator: MissionDraftValidator

    init(
        previewBuilder: MissionPreviewBuilder = MissionPreviewBuilder(),
        validator: MissionDraftValidator = MissionDraftValidator()
    ) {
        self.previewBuilder = previewBuilder
        self.validator = validator
    }

    func buildState(
        isVisible: Bool,
        mode: TacticalMapMode,
        viewport: MapViewportState,
        committedDraft: MissionDraft,
        workingDraft: MissionDraft
    ) -> TacticalMapState {
        let previewRoute = previewBuilder.buildPreview(
            draft: workingDraft,
            viewport: viewport
        )
        let draftStatus = validator.validate(
            draft: workingDraft,
            previewRoute: previewRoute,
            viewport: viewport
        )
        let isDraftDirty = committedDraft != workingDraft

        return TacticalMapState(
            isVisible: isVisible,
            mode: mode,
            viewport: viewport,
            committedDraft: committedDraft,
            workingDraft: workingDraft,
            previewRoute: previewRoute,
            draftStatus: draftStatus,
            isDraftDirty: isDraftDirty
        )
    }
}
