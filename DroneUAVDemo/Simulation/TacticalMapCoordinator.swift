import Foundation
import simd

final class TacticalMapCoordinator {
    private struct BuildKey: Equatable {
        let isVisible: Bool
        let mode: TacticalMapMode
        let viewport: MapViewportState
        let committedDraft: MissionDraft
        let workingDraft: MissionDraft
        let airframeClass: AirframeClass
        let fixedWingParameters: FixedWingParameters?
        let supportedLaunchModes: [LaunchMode]
    }

    private let previewBuilder: MissionPreviewBuilder
    private let validator: MissionDraftValidator
    private var cachedBuildKey: BuildKey?
    private var cachedBuildState: TacticalMapState?

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
        workingDraft: MissionDraft,
        airframeClass: AirframeClass,
        fixedWingParameters: FixedWingParameters?,
        supportedLaunchModes: [LaunchMode]
    ) -> TacticalMapState {
        let key = BuildKey(
            isVisible: isVisible,
            mode: mode,
            viewport: viewport,
            committedDraft: committedDraft,
            workingDraft: workingDraft,
            airframeClass: airframeClass,
            fixedWingParameters: fixedWingParameters,
            supportedLaunchModes: supportedLaunchModes
        )
        if cachedBuildKey == key,
           let cachedBuildState {
            return cachedBuildState
        }

        let previewRoute = previewBuilder.buildPreview(
            draft: workingDraft,
            viewport: viewport,
            airframeClass: airframeClass,
            fixedWingParameters: fixedWingParameters
        )
        let launchPreview = previewBuilder.buildLaunchPreview(
            draft: workingDraft,
            viewport: viewport,
            fixedWingParameters: fixedWingParameters,
            supportedLaunchModes: supportedLaunchModes
        )
        let draftStatus = validator.validate(
            draft: workingDraft,
            previewRoute: previewRoute,
            launchPreview: launchPreview,
            viewport: viewport,
            fixedWingParameters: fixedWingParameters,
            supportedLaunchModes: supportedLaunchModes
        )
        let isDraftDirty = committedDraft != workingDraft

        let nextState = TacticalMapState(
            isVisible: isVisible,
            mode: mode,
            viewport: viewport,
            committedDraft: committedDraft,
            workingDraft: workingDraft,
            launchPreview: launchPreview,
            previewRoute: previewRoute,
            draftStatus: draftStatus,
            isDraftDirty: isDraftDirty
        )
        cachedBuildKey = key
        cachedBuildState = nextState
        return nextState
    }
}
