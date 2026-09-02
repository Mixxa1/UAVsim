import AppKit
import CoreGraphics
import SceneKit
import SwiftUI

/// SceneKit owns delegate callbacks; view mutation is dispatched to main and all video processing
/// runs on one serial queue, so stateful stale-frame/decoder behavior remains ordered.
final class SceneRenderCoordinator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    var cameraMode: CameraMode
    var onRenderFrame: (TimeInterval, CameraMode) -> Void
    var fpvFontPreset: FPVFontPreset?
    var fpvFontAtlas: FPVFontAtlas?
    var failedFPVFontPreset: FPVFontPreset?

    private let analogNTSCProcessor = AnalogNTSCProcessor()
    private let digitalVideoProcessor = DigitalVideoProcessor()
    private let fiberVideoProcessor = FiberVideoProcessor()
    private let videoProcessingQueue = DispatchQueue(
        label: "com.uavsim.video-postprocess",
        qos: .userInitiated
    )
    private weak var sceneView: FocusableSCNView?
    private var fpvPipelineActive = false
    private var postProcessingRequired = false
    private var pipelineRevision: UInt64 = 0
    private var fpvVideoMode: RFVideoTransmissionMode?
    private var videoPresentationState: RFVideoPresentationState?
    private var fpvOSDState: FPVOSDState?
    private var osdLayout: OSDLayoutConfiguration = .corners
    private var osdAvailability: OSDElementAvailability = .all
    private var analogParameters: AnalogNTSCParameters?
    private var digitalParameters: DigitalVideoParameters = .clean
    private var fiberParameters: FiberVideoParameters = .clean
    private var isProcessingFrame = false
    private var lastCaptureTime: TimeInterval = -.infinity

    init(
        cameraMode: CameraMode,
        onRenderFrame: @escaping (TimeInterval, CameraMode) -> Void
    ) {
        self.cameraMode = cameraMode
        self.onRenderFrame = onRenderFrame
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        onRenderFrame(time, cameraMode)
    }

    func renderer(
        _ renderer: any SCNSceneRenderer,
        didRenderScene scene: SCNScene,
        atTime time: TimeInterval
    ) {
        // SceneKit may invoke its delegate on a render thread. Snapshotting and AppKit view
        // mutation stay on main; expensive RGB/composite processing stays on one serial worker.
        DispatchQueue.main.async { [weak self] in
            self?.captureFPVFrameIfNeeded(atTime: time)
        }
    }

    @MainActor
    fileprivate func attach(to view: FocusableSCNView) {
        sceneView = view
    }

    @MainActor
    fileprivate func configureFPVPipeline(
        mode: RFVideoTransmissionMode,
        presentationState: RFVideoPresentationState,
        osdState: FPVOSDState?,
        osdLayout: OSDLayoutConfiguration,
        osdAvailability: OSDElementAvailability,
        analogParameters: AnalogNTSCParameters?,
        digitalParameters: DigitalVideoParameters,
        fiberParameters: FiberVideoParameters
    ) {
        let nextPostProcessingRequired: Bool
        switch mode {
        case .analog:
            nextPostProcessingRequired = true
        case .digital:
            nextPostProcessingRequired = digitalParameters.requiresPostProcessing
        case .fiber:
            nextPostProcessingRequired = fiberParameters.requiresPostProcessing
        }
        let pipelineChanged = fpvVideoMode != mode
            || postProcessingRequired != nextPostProcessingRequired
        if pipelineChanged {
            pipelineRevision &+= 1
            sceneView?.processedFPVImageView.image = nil
            sceneView?.processedFPVImageView.isHidden = true
            lastCaptureTime = -.infinity
            let analog = analogNTSCProcessor
            let digital = digitalVideoProcessor
            let fiber = fiberVideoProcessor
            videoProcessingQueue.async {
                analog.reset()
                digital.reset()
                fiber.reset()
            }
        }
        fpvPipelineActive = true
        postProcessingRequired = nextPostProcessingRequired
        fpvVideoMode = mode
        videoPresentationState = presentationState
        fpvOSDState = osdState
        self.osdLayout = osdLayout
        self.osdAvailability = osdAvailability
        self.analogParameters = analogParameters
        self.digitalParameters = digitalParameters
        self.fiberParameters = fiberParameters
        switch mode {
        case .analog:
            sceneView?.videoFrameRateOverrideFPS = 30
        case .digital:
            sceneView?.videoFrameRateOverrideFPS = max(
                1,
                Int(digitalParameters.targetFrameRateFPS.rounded())
            )
        case .fiber:
            sceneView?.videoFrameRateOverrideFPS = 60
        }
    }

    @MainActor
    fileprivate func deactivateFPVPipeline() {
        guard fpvPipelineActive || sceneView?.processedFPVImageView.image != nil else { return }
        fpvPipelineActive = false
        postProcessingRequired = false
        pipelineRevision &+= 1
        fpvVideoMode = nil
        videoPresentationState = nil
        fpvOSDState = nil
        analogParameters = nil
        digitalParameters = .clean
        fiberParameters = .clean
        lastCaptureTime = -.infinity
        sceneView?.processedFPVImageView.image = nil
        sceneView?.processedFPVImageView.isHidden = true
        sceneView?.videoFrameRateOverrideFPS = nil
        let analog = analogNTSCProcessor
        let digital = digitalVideoProcessor
        let fiber = fiberVideoProcessor
        videoProcessingQueue.async {
            analog.reset()
            digital.reset()
            fiber.reset()
        }
    }

    @MainActor
    private func captureFPVFrameIfNeeded(atTime time: TimeInterval) {
        guard fpvPipelineActive,
              postProcessingRequired,
              !isProcessingFrame,
              let mode = fpvVideoMode,
              let presentationState = videoPresentationState,
              time - lastCaptureTime >= minimumCaptureInterval(for: mode),
              let view = sceneView,
              view.window != nil,
              view.bounds.width > 1,
              view.bounds.height > 1 else {
            return
        }

        // Digital/fiber loss retains the last complete frame. Analog never enters this branch: its
        // lost state continues producing noise/sync damage rather than freezing a packet frame.
        if presentationState.isFrozen, view.processedFPVImageView.image != nil {
            return
        }

        var proposedRect = view.bounds
        let snapshot = view.snapshot()
        guard let sourceImage = snapshot.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: [.interpolation: NSImageInterpolation.high]
        ) else {
            return
        }

        lastCaptureTime = time
        isProcessingFrame = true
        let analog = analogNTSCProcessor
        let digital = digitalVideoProcessor
        let fiber = fiberVideoProcessor
        let osdState = fpvOSDState
        let layout = osdLayout
        let availability = osdAvailability
        let analogControls = analogParameters
        let digitalControls = digitalParameters
        let fiberControls = fiberParameters
        let atlas = fpvFontAtlas
        let revision = pipelineRevision
        videoProcessingQueue.async {
            autoreleasepool {
                let output: CGImage?
                switch mode {
                case .analog:
                    if let osdState, let analogControls, let atlas {
                        output = analog.process(
                            sourceImage: sourceImage,
                            state: osdState,
                            fontAtlas: atlas,
                            layout: layout,
                            availability: availability,
                            parameters: analogControls
                        )
                    } else {
                        output = nil
                    }
                case .digital:
                    output = digital.process(
                        sourceImage: sourceImage,
                        parameters: digitalControls
                    )
                case .fiber:
                    output = fiber.process(
                        sourceImage: sourceImage,
                        parameters: fiberControls
                    )
                }
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self else { return }
                    defer { self.isProcessingFrame = false }
                    guard self.fpvPipelineActive,
                          self.postProcessingRequired,
                          self.fpvVideoMode == mode,
                          self.pipelineRevision == revision,
                          let view,
                          let output else {
                        return
                    }
                    view.processedFPVImageView.image = NSImage(
                        cgImage: output,
                        size: view.bounds.size
                    )
                    view.processedFPVImageView.isHidden = false
                }
            }
        }
    }

    private func minimumCaptureInterval(for mode: RFVideoTransmissionMode) -> TimeInterval {
        switch mode {
        case .analog: return 1.0 / 29.97
        case .digital: return 1.0 / max(1, digitalParameters.targetFrameRateFPS)
        case .fiber: return 1.0 / 60.0
        }
    }
}

/// Visual-only child: all keyboard and mouse events continue to hit `FocusableSCNView`.
private final class FPVProcessedFrameImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FocusableSCNView: SCNView {
    let processedFPVImageView = FPVProcessedFrameImageView()
    var onLookDelta: ((Float, Float) -> Void)?
    var usesUnboundedMouseLook: Bool = false {
        didSet {
            if usesUnboundedMouseLook {
                window?.acceptsMouseMovedEvents = true
                if capturesMouseOnEntry {
                    captureMouseLookIfPossible()
                }
            } else {
                releaseMouseLook()
            }
        }
    }
    /// Spectator hijacks the cursor the moment it enters the viewport; the
    /// hand-launch POV instead waits for a click (UI panels stay usable) and
    /// releases on Esc, like a regular FPS capture.
    var capturesMouseOnEntry: Bool = true
    var renderPolicy: SceneRenderPolicy = .policy(for: .interacting) {
        didSet {
            applyRenderPolicy()
        }
    }
    var videoFrameRateOverrideFPS: Int? {
        didSet { applyRenderPolicy() }
    }

    private var lastDragPoint: NSPoint?
    private var trackingArea: NSTrackingArea?
    private var isMouseLookCaptured = false
    private var isCursorHidden = false
    private static let suppressedSceneControlKeyCodes: Set<UInt16> = [37, 38] // L / J

    // v1.4.5: direct notification observers that apply render-pause without going through SwiftUI.
    // SwiftUI suspends body evaluations for minimized windows, so updateNSView is never called
    // while the window is minimized — isPlaying would stay true and SceneKit keeps rendering.
    // Subscribing to NSWindow notifications here bypasses that gap entirely.
    private var miniaturizeObserver: Any?
    private var deminiaturizeObserver: Any?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        configureProcessedFrameView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureProcessedFrameView()
    }

    private func configureProcessedFrameView() {
        processedFPVImageView.frame = bounds
        processedFPVImageView.autoresizingMask = [.width, .height]
        processedFPVImageView.imageScaling = .scaleAxesIndependently
        processedFPVImageView.isHidden = true
        addSubview(processedFPVImageView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            releaseMouseLook()
        } else if usesUnboundedMouseLook, capturesMouseOnEntry {
            captureMouseLookIfPossible()
        }
        subscribeToWindowRenderPause()
    }

    private func subscribeToWindowRenderPause() {
        let nc = NotificationCenter.default
        miniaturizeObserver.map { nc.removeObserver($0) }
        deminiaturizeObserver.map { nc.removeObserver($0) }
        miniaturizeObserver = nil
        deminiaturizeObserver = nil
        guard let window else { return }
        miniaturizeObserver = nc.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.preferredFramesPerSecond = 1
            self.rendersContinuously = false
            #if DEBUG
            print("[PERF] apply SceneRenderPolicy visibility=minimized fps=1 playing=false")
            #endif
        }
        deminiaturizeObserver = nc.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyRenderPolicy()
            #if DEBUG
            print("[PERF] apply SceneRenderPolicy visibility=active fps=\(self.renderPolicy.preferredFPS) playing=\(self.renderPolicy.isPlaying) (deminiaturize)")
            #endif
        }
    }

    private func applyRenderPolicy() {
        if let videoFrameRateOverrideFPS, renderPolicy.preferredFPS >= 30 {
            // An active FPV decoder owns cadence. `activeIdle` is a UI-idleness policy, not a
            // reason to force a documented 60-fps video link down to 30. Background/minimized
            // policies still cap it below this branch.
            preferredFramesPerSecond = videoFrameRateOverrideFPS
        } else {
            preferredFramesPerSecond = min(
                renderPolicy.preferredFPS,
                videoFrameRateOverrideFPS ?? renderPolicy.preferredFPS
            )
        }
        isPlaying = renderPolicy.isPlaying
        rendersContinuously = renderPolicy.rendersContinuously
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        if usesUnboundedMouseLook, capturesMouseOnEntry {
            captureMouseLookIfPossible()
        }
        super.mouseEntered(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if usesUnboundedMouseLook {
            captureMouseLookIfPossible()
            return
        }
        lastDragPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if usesUnboundedMouseLook {
            captureMouseLookIfPossible()
            return
        }
        lastDragPoint = event.locationInWindow
        super.rightMouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard usesUnboundedMouseLook, isMouseLookCaptured else {
            super.mouseMoved(with: event)
            return
        }
        handleUnboundedLook(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if usesUnboundedMouseLook {
            handleUnboundedLook(event)
            return
        }
        handleLookDrag(event)
        super.mouseDragged(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if usesUnboundedMouseLook {
            handleUnboundedLook(event)
            return
        }
        handleLookDrag(event)
        super.rightMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        super.mouseUp(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        lastDragPoint = nil
        super.rightMouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if usesUnboundedMouseLook, event.keyCode == 53 {
            releaseMouseLook()
            return
        }
        guard !Self.suppressedSceneControlKeyCodes.contains(event.keyCode) else {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !Self.suppressedSceneControlKeyCodes.contains(event.keyCode) else {
            return
        }
        super.keyUp(with: event)
    }

    private func handleLookDrag(_ event: NSEvent) {
        let point = event.locationInWindow
        let previous = lastDragPoint ?? point
        lastDragPoint = point

        let dx = Float(point.x - previous.x)
        let dy = Float(point.y - previous.y)

        guard abs(dx) > 0.01 || abs(dy) > 0.01 else {
            return
        }

        onLookDelta?(dx, -dy)
    }

    private func handleUnboundedLook(_ event: NSEvent) {
        let dx = Float(event.deltaX)
        let dy = Float(event.deltaY)
        guard abs(dx) > 0.01 || abs(dy) > 0.01 else {
            return
        }

        onLookDelta?(dx, -dy)
    }

    private func captureMouseLookIfPossible() {
        guard usesUnboundedMouseLook, !isMouseLookCaptured, window != nil else {
            return
        }

        window?.makeFirstResponder(self)
        if CGAssociateMouseAndMouseCursorPosition(0) == .success {
            isMouseLookCaptured = true
            if !isCursorHidden {
                NSCursor.hide()
                isCursorHidden = true
            }
        }
    }

    private func releaseMouseLook() {
        guard isMouseLookCaptured || isCursorHidden else {
            return
        }

        _ = CGAssociateMouseAndMouseCursorPosition(1)
        isMouseLookCaptured = false
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
    }

    deinit {
        let nc = NotificationCenter.default
        miniaturizeObserver.map { nc.removeObserver($0) }
        deminiaturizeObserver.map { nc.removeObserver($0) }
        releaseMouseLook()
    }
}

// MARK: - SceneRenderPolicy

struct SceneRenderPolicy: Equatable {
    var preferredFPS: Int
    var isPlaying: Bool
    var rendersContinuously: Bool
}

extension SceneRenderPolicy {
    static func policy(for state: RuntimeActivityState) -> SceneRenderPolicy {
        switch state {
        case .interacting:
            return SceneRenderPolicy(preferredFPS: 60, isPlaying: true, rendersContinuously: true)
        case .activeIdle:
            return SceneRenderPolicy(preferredFPS: 30, isPlaying: true, rendersContinuously: true)
        case .backgroundIdle:
            return SceneRenderPolicy(preferredFPS: 15, isPlaying: true, rendersContinuously: true)
        case .minimized, .hidden:
            return SceneRenderPolicy(preferredFPS: 1, isPlaying: false, rendersContinuously: false)
        }
    }
}

struct DroneSceneViewRepresentable: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode
    let cameraMode: CameraMode
    let cameraSensitivity: Float
    let freeMoveSpeed: Float
    var activityState: RuntimeActivityState = .interacting
    var wantsWeatherDepthOfField: Bool = false
    var renderPolicyOverride: SceneRenderPolicy? = nil
    var isInteractive: Bool = true
    /// First-person hand-launch hold: mouse-drag look must reach the view
    /// model even though the underlying camera mode stays e.g. `.follow`
    /// while the POV camera temporarily overrides the viewpoint.
    var isHandLaunchPOV: Bool = false
    /// The race track builder aims with the mouse itself — moved, not dragged — so it takes the
    /// same captured-cursor look the spectator camera uses.
    var usesBuilderMouseLook: Bool = false
    /// The installed VIDEO logical link is the sole selector for the presentation processor.
    var fpvVideoMode: RFVideoTransmissionMode? = nil
    var fpvVideoPresentationState: RFVideoPresentationState? = nil
    /// Non-nil only for analog. The glyph grid is composited into the NTSC processor's RGB input.
    var analogFPVOSDState: FPVOSDState? = nil
    var analogNTSCParameters: AnalogNTSCParameters? = nil
    var digitalVideoParameters: DigitalVideoParameters = .clean
    var fiberVideoParameters: FiberVideoParameters = .clean
    var fpvFontPreset: FPVFontPreset = .betaflight
    /// Operator-authored OSD layout and what the installed equipment can actually feed it.
    var osdLayout: OSDLayoutConfiguration = .corners
    var osdAvailability: OSDElementAvailability = .all
    let onLookDelta: (Float, Float) -> Void
    let onRenderFrame: (TimeInterval, CameraMode) -> Void

    func makeCoordinator() -> SceneRenderCoordinator {
        SceneRenderCoordinator(cameraMode: cameraMode, onRenderFrame: onRenderFrame)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = FocusableSCNView(frame: .zero)
        let quality = AppGraphicsSettings.quality
        view.scene = scene
        view.antialiasingMode = quality.antialiasingMode
        let policy = renderPolicyOverride ?? SceneRenderPolicy.policy(for: activityState)
        view.renderPolicy = policy
        view.backgroundColor = .black
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        view.onLookDelta = isInteractive && (cameraMode == .fpv || cameraMode == .spectator || isHandLaunchPOV || usesBuilderMouseLook) ? onLookDelta : nil
        view.capturesMouseOnEntry = cameraMode == .spectator
        view.usesUnboundedMouseLook = isInteractive && (cameraMode == .spectator || isHandLaunchPOV || usesBuilderMouseLook)
        applyRenderScale(to: view)

        configureCameraControl(on: view)
        configurePostProcessing(on: view, coordinator: context.coordinator)

        if isInteractive {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let quality = AppGraphicsSettings.quality
        if view.antialiasingMode != quality.antialiasingMode {
            view.antialiasingMode = quality.antialiasingMode
        }
        applyRenderScale(to: view)

        if view.scene !== scene {
            view.scene = scene
        }

        context.coordinator.cameraMode = cameraMode
        context.coordinator.onRenderFrame = onRenderFrame
        if let focusableView = view as? FocusableSCNView {
            context.coordinator.attach(to: focusableView)
        }
        view.pointOfView = pointOfView

        let policy = renderPolicyOverride ?? SceneRenderPolicy.policy(for: activityState)
        if let view = view as? FocusableSCNView {
            view.renderPolicy = policy
            view.onLookDelta = isInteractive && (cameraMode == .fpv || cameraMode == .spectator || isHandLaunchPOV || usesBuilderMouseLook) ? onLookDelta : nil
            view.capturesMouseOnEntry = cameraMode == .spectator
            view.usesUnboundedMouseLook = isInteractive && (cameraMode == .spectator || isHandLaunchPOV || usesBuilderMouseLook)
        } else {
            if view.preferredFramesPerSecond != policy.preferredFPS {
                view.preferredFramesPerSecond = policy.preferredFPS
            }
            view.isPlaying = policy.isPlaying
            view.rendersContinuously = policy.rendersContinuously
        }
        configureCameraControl(on: view)
        configurePostProcessing(on: view, coordinator: context.coordinator)
    }

    private func configurePostProcessing(
        on view: SCNView,
        coordinator: SceneRenderCoordinator
    ) {
        let wantsWeatherDOF = wantsWeatherDepthOfField
            && AppGraphicsSettings.quality.weatherDepthOfFieldEnabled
        guard let mode = fpvVideoMode,
              let presentationState = fpvVideoPresentationState else {
            coordinator.deactivateFPVPipeline()
            let desiredTechnique = wantsWeatherDOF ? WeatherDepthOfFieldTechnique.shared : nil
            if view.technique !== desiredTechnique {
                view.technique = desiredTechnique
            }
            return
        }

        do {
            if mode == .analog {
                guard analogFPVOSDState != nil, analogNTSCParameters != nil else {
                    coordinator.deactivateFPVPipeline()
                    return
                }
                if coordinator.fpvFontPreset != fpvFontPreset || coordinator.fpvFontAtlas == nil {
                    coordinator.fpvFontAtlas = try FPVFontAtlasStore.shared.atlas(for: fpvFontPreset)
                    coordinator.fpvFontPreset = fpvFontPreset
                    coordinator.failedFPVFontPreset = nil
                }
                guard coordinator.fpvFontAtlas != nil else { return }
            }
            coordinator.configureFPVPipeline(
                mode: mode,
                presentationState: presentationState,
                osdState: analogFPVOSDState,
                osdLayout: osdLayout,
                osdAvailability: osdAvailability,
                analogParameters: analogNTSCParameters,
                digitalParameters: digitalVideoParameters,
                fiberParameters: fiberVideoParameters
            )
            // The native processor owns the displayed FPV frame. The SceneKit technique slot is
            // left available for weather capture, and no clean SpriteKit overlay is attached.
            view.overlaySKScene = nil
            let desiredTechnique = wantsWeatherDOF ? WeatherDepthOfFieldTechnique.shared : nil
            if view.technique !== desiredTechnique {
                view.technique = desiredTechnique
            }
        } catch {
            coordinator.deactivateFPVPipeline()
            let fallback = wantsWeatherDOF ? WeatherDepthOfFieldTechnique.shared : nil
            if view.technique !== fallback {
                view.technique = fallback
            }
            if coordinator.failedFPVFontPreset != fpvFontPreset {
                coordinator.failedFPVFontPreset = fpvFontPreset
                #if DEBUG
                print("[FPV OSD] Could not load \(fpvFontPreset.resourceName).mcm: \(error)")
                #endif
            }
        }
    }

    /// Best-effort internal render scale: drops the backing layer's contentsScale below the
    /// screen's native factor so the GPU renders fewer pixels and upscales — a direct fill/heat
    /// lever. Public SCNView has no dedicated render-scale API, so this rides on the Metal layer's
    /// contentsScale; if a future macOS/SceneKit version ignores it, it degrades harmlessly to
    /// native resolution (the reliable graphics levers are AA/shadows/tree-count/DOF).
    private func applyRenderScale(to view: SCNView) {
        let scale = CGFloat(min(1.0, max(0.5, AppGraphicsSettings.renderScale)))
        let backing = view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 2.0
        let target = backing * scale
        if let layer = view.layer, abs(layer.contentsScale - target) > 0.001 {
            layer.contentsScale = target
        }
    }

    private func configureCameraControl(on view: SCNView) {
        let isFreeMode = isInteractive && cameraMode == .free
        view.allowsCameraControl = isFreeMode

        let sensitivity = CGFloat(cameraSensitivity.clamped(to: 0.2...2.5))
        let cameraConfig = view.cameraControlConfiguration
        cameraConfig.allowsTranslation = isFreeMode
        cameraConfig.autoSwitchToFreeCamera = false
        cameraConfig.flyModeVelocity = CGFloat(freeMoveSpeed.clamped(to: 0.5...16.0))
        cameraConfig.panSensitivity = sensitivity
        cameraConfig.truckSensitivity = sensitivity
        cameraConfig.rotationSensitivity = sensitivity
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
