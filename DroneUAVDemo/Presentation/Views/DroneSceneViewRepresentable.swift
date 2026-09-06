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
    /// Which pass currently owns the processed-frame image view. The FPV chain and the payload
    /// sensor chain share one display surface, and without an owner the FPV teardown — which runs
    /// on every `updateNSView` while the payload view is open — kept clearing the payload pass's
    /// frame, so the feed blinked between the processed image and the raw render.
    private enum ProcessedFrameOwner {
        case none
        case fpv
        case payloadSensor
    }

    private weak var sceneView: FocusableSCNView?
    private var processedFrameOwner: ProcessedFrameOwner = .none
    private var fpvPipelineActive = false
    private var postProcessingRequired = false
    private var pipelineRevision: UInt64 = 0
    private var observationSourceIdentity = "player"
    private var fpvVideoMode: RFVideoTransmissionMode?
    private var videoPresentationState: RFVideoPresentationState?
    private var fpvOSDState: FPVOSDState?
    private let fisheyeLensProcessor = FisheyeLensProcessor()
    private let cameraSensorProcessor = CameraSensorProcessor()
    /// The pilot's camera keeps its own exposure loop: it is a different device from the payload's
    /// and must not inherit its gain when the operator switches views.
    private let fpvSensorProcessor = CameraSensorProcessor()
    private var fpvSensorParameters: CameraSensorParameters?
    private var fpvSensorFrameIndex: UInt64 = 0
    private var lastFPVCameraYaw: Double?
    private var smoothedFPVYawRate: Double = 0
    /// Payload video is delivered at 30 fps, matching both real downlinked camera video and the
    /// rate the analog FPV chain already runs at.
    private static let payloadCaptureFrameRate: Double = 30
    /// Sensor characteristics of the camera feeding the payload view, when one is fitted.
    private var payloadSensorParameters: CameraSensorParameters?
    private var payloadSensorFrameIndex: UInt64 = 0
    private var payloadSensorActive = false
    private var payloadSensorRevision: UInt64 = 0
    private var lastPayloadCaptureTime: TimeInterval = -.infinity
    /// Camera heading at the previous capture, for the rolling-shutter lean. Measured from the
    /// node actually being rendered rather than from the airframe, because a gimbal decouples the
    /// two and it is the sensor's own motion that skews the readout.
    private var lastPayloadCameraYaw: Double?
    /// The raw frame-to-frame heading difference is a noisy estimate, and feeding it straight into
    /// the shear made the picture twitch. The lean follows a filtered rate instead.
    private var smoothedPayloadYawRate: Double = 0
    private var lensStrength: Double = 0
    private var lensHalfAngleDegrees: Double = 50
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
            self?.capturePayloadSensorFrameIfNeeded(atTime: time)
        }
    }

    @MainActor
    fileprivate func attach(to view: FocusableSCNView) {
        sceneView = view
    }

    /// Clears the shared frame only when the pass asking for it is the one showing it.
    @MainActor
    private func clearProcessedFrame(owner: ProcessedFrameOwner) {
        guard processedFrameOwner == owner else { return }
        processedFrameOwner = .none
        sceneView?.processedFPVImageView.image = nil
        sceneView?.processedFPVImageView.isHidden = true
    }

    @MainActor
    fileprivate func configureFPVPipeline(
        sourceIdentity: String,
        mode: RFVideoTransmissionMode,
        presentationState: RFVideoPresentationState,
        osdState: FPVOSDState?,
        lensStrength: Double,
        lensHalfAngleDegrees: Double,
        osdLayout: OSDLayoutConfiguration,
        osdAvailability: OSDElementAvailability,
        fpvSensorParameters: CameraSensorParameters?,
        analogParameters: AnalogNTSCParameters?,
        digitalParameters: DigitalVideoParameters,
        fiberParameters: FiberVideoParameters
    ) {
        // The lens alone is reason enough to run the pipeline: on a clean digital or fibre link
        // there would otherwise be nothing to post-process and the frame would stay rectilinear.
        // So is the camera itself — a bolted-in analog FPV camera is never a clean picture.
        let lensActive = lensStrength > 0.001
        let sensorActive = fpvSensorParameters?.requiresProcessing ?? false
        let nextPostProcessingRequired: Bool
        switch mode {
        case .analog:
            nextPostProcessingRequired = true
        case .digital:
            nextPostProcessingRequired = digitalParameters.requiresPostProcessing || lensActive || sensorActive
        case .fiber:
            nextPostProcessingRequired = fiberParameters.requiresPostProcessing || lensActive || sensorActive
        }
        // Only a different camera restarts the exposure loop. Keying this on the whole parameter
        // block meant every zoom step and every lens toggle reset the gain to 1 and let the loop
        // converge again from scratch, which is what the second-long flashes were.
        let sourceChanged = observationSourceIdentity != sourceIdentity
        observationSourceIdentity = sourceIdentity
        let cameraChanged = sourceChanged || self.fpvSensorParameters?.cameraIdentity != fpvSensorParameters?.cameraIdentity
        let pipelineChanged = sourceChanged || fpvVideoMode != mode
            || postProcessingRequired != nextPostProcessingRequired
        if pipelineChanged {
            pipelineRevision &+= 1
            clearProcessedFrame(owner: .fpv)
            lastCaptureTime = -.infinity
            let analog = analogNTSCProcessor
            let digital = digitalVideoProcessor
            let fiber = fiberVideoProcessor
            let lens = fisheyeLensProcessor
            lastFPVCameraYaw = nil
            smoothedFPVYawRate = 0
            fpvSensorFrameIndex = 0
            videoProcessingQueue.async {
                analog.reset()
                digital.reset()
                fiber.reset()
                lens.reset()
            }
        }
        if cameraChanged {
            // A different camera starts its own exposure loop rather than inheriting the gain the
            // previous one had settled on. Nothing else is torn down: the frame on screen stays.
            let sensor = fpvSensorProcessor
            videoProcessingQueue.async { sensor.reset() }
        }
        fpvPipelineActive = true
        postProcessingRequired = nextPostProcessingRequired
        fpvVideoMode = mode
        videoPresentationState = presentationState
        fpvOSDState = osdState
        self.lensStrength = lensStrength
        self.lensHalfAngleDegrees = lensHalfAngleDegrees
        self.osdLayout = osdLayout
        self.osdAvailability = osdAvailability
        self.fpvSensorParameters = fpvSensorParameters
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
        guard fpvPipelineActive || processedFrameOwner == .fpv else { return }
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
        clearProcessedFrame(owner: .fpv)
        sceneView?.videoFrameRateOverrideFPS = nil
        let analog = analogNTSCProcessor
        let digital = digitalVideoProcessor
        let fiber = fiberVideoProcessor
        let lens = fisheyeLensProcessor
        videoProcessingQueue.async {
            analog.reset()
            digital.reset()
            fiber.reset()
            lens.reset()
        }
    }

    /// The payload view renders straight from SceneKit, so without this pass every module looked
    /// identical apart from its field of view. Runs only when the FPV pipeline is idle: the two
    /// share one display surface, and only one camera is ever on screen.
    @MainActor
    fileprivate func configurePayloadSensorPipeline(parameters: CameraSensorParameters?) {
        let next = (parameters?.requiresProcessing ?? false) ? parameters : nil
        // Zoom changes these values continuously, so the parameters are simply replaced. Only
        // switching the pass on or off resets the capture clock — resetting it on every value
        // change would defeat the frame-rate throttle for the whole duration of a zoom.
        let cameraChanged = payloadSensorParameters?.cameraIdentity != next?.cameraIdentity
        payloadSensorParameters = next
        let shouldBeActive = next != nil
        if cameraChanged, shouldBeActive, payloadSensorActive {
            let sensor = cameraSensorProcessor
            videoProcessingQueue.async { sensor.reset() }
        }
        guard shouldBeActive != payloadSensorActive else { return }
        payloadSensorActive = shouldBeActive
        payloadSensorRevision &+= 1
        payloadSensorFrameIndex = 0
        // The exposure loop carries state between frames; a new camera starts its own.
        let sensor = cameraSensorProcessor
        videoProcessingQueue.async { sensor.reset() }
        lastPayloadCaptureTime = -.infinity
        lastPayloadCameraYaw = nil
        if !shouldBeActive {
            clearProcessedFrame(owner: .payloadSensor)
        }
    }

    @MainActor
    fileprivate func deactivatePayloadSensorPipeline() {
        guard payloadSensorActive || payloadSensorParameters != nil else { return }
        payloadSensorActive = false
        payloadSensorParameters = nil
        payloadSensorRevision &+= 1
        lastPayloadCaptureTime = -.infinity
        lastPayloadCameraYaw = nil
        smoothedPayloadYawRate = 0
        clearProcessedFrame(owner: .payloadSensor)
    }

    /// Yaw rate of the rendered camera, radians per second, signed. Returns zero on the first
    /// frame and whenever the elapsed time is not usable.
    @MainActor
    private func cameraYawRate(
        elapsed: TimeInterval,
        previous: inout Double?,
        smoothed: inout Double
    ) -> Double {
        guard let node = sceneView?.pointOfView else {
            previous = nil
            return 0
        }
        let forward = node.presentation.simdWorldTransform.columns.2
        let yaw = Double(atan2(forward.x, forward.z))
        defer { previous = yaw }
        guard let last = previous,
              elapsed > 0.0001,
              elapsed < 0.5 else {
            return 0
        }
        var delta = yaw - last
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        smoothed += (delta / elapsed - smoothed) * 0.35
        return smoothed
    }

    @MainActor
    private func capturePayloadSensorFrameIfNeeded(atTime time: TimeInterval) {
        guard payloadSensorActive,
              !fpvPipelineActive,
              !isProcessingFrame,
              let parameters = payloadSensorParameters,
              time - lastPayloadCaptureTime >= 1.0 / Self.payloadCaptureFrameRate,
              let view = sceneView,
              view.window != nil,
              view.bounds.width > 1,
              view.bounds.height > 1 else {
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

        let elapsed = lastPayloadCaptureTime.isFinite ? time - lastPayloadCaptureTime : 0
        let yawRate = cameraYawRate(
            elapsed: elapsed,
            previous: &lastPayloadCameraYaw,
            smoothed: &smoothedPayloadYawRate
        )
        lastPayloadCaptureTime = time
        isProcessingFrame = true
        payloadSensorFrameIndex &+= 1
        let sensor = cameraSensorProcessor
        let lens = fisheyeLensProcessor
        let frameIndex = payloadSensorFrameIndex
        let revision = payloadSensorRevision
        videoProcessingQueue.async {
            autoreleasepool {
                // The lens sits ahead of the sensor on a real camera, so the barrel bow is applied
                // to the rendered frame first and the readout, resolution and noise act on what
                // the lens delivered.
                let lensed = parameters.requiresLensPass
                    ? (lens.process(
                        sourceImage: sourceImage,
                        strength: parameters.barrelDistortion,
                        halfAngleDegrees: parameters.lensHalfAngleDegrees
                    ) ?? sourceImage)
                    : sourceImage
                let output = sensor.process(
                    sourceImage: lensed,
                    parameters: parameters,
                    yawRateRadiansPerSecond: yawRate,
                    deltaTime: elapsed,
                    frameIndex: frameIndex
                )
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self else { return }
                    defer { self.isProcessingFrame = false }
                    guard self.payloadSensorActive,
                          self.payloadSensorRevision == revision,
                          let view,
                          let output else {
                        return
                    }
                    self.processedFrameOwner = .payloadSensor
                    view.processedFPVImageView.image = NSImage(
                        cgImage: output,
                        size: view.bounds.size
                    )
                    view.processedFPVImageView.isHidden = false
                }
            }
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
        if presentationState.isFrozen, processedFrameOwner == .fpv, view.processedFPVImageView.image != nil {
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

        let elapsed = lastCaptureTime.isFinite ? time - lastCaptureTime : 0
        let yawRate = cameraYawRate(
            elapsed: elapsed,
            previous: &lastFPVCameraYaw,
            smoothed: &smoothedFPVYawRate
        )
        lastCaptureTime = time
        isProcessingFrame = true
        fpvSensorFrameIndex &+= 1
        let sensor = fpvSensorProcessor
        let sensorParameters = fpvSensorParameters
        let sensorFrameIndex = fpvSensorFrameIndex
        let analog = analogNTSCProcessor
        let digital = digitalVideoProcessor
        let fiber = fiberVideoProcessor
        let lens = fisheyeLensProcessor
        let lensStrength = self.lensStrength
        let lensHalfAngle = self.lensHalfAngleDegrees
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
                // The lens belongs to the camera, so it runs once on the captured frame and
                // before any link-specific processing — and, for analog, before the OSD is
                // composited, exactly as a real lens sits ahead of the character generator.
                let lensed = lensStrength > 0.001
                    ? (lens.process(
                        sourceImage: sourceImage,
                        strength: lensStrength,
                        halfAngleDegrees: lensHalfAngle
                    ) ?? sourceImage)
                    : sourceImage
                // The pilot's camera sits between the lens and the transmitter, so its sensor and
                // ISP act on the bent frame and the link then carries whatever they produced. The
                // OSD is composited after all of it, by the flight controller.
                let sourceImage: CGImage
                if let sensorParameters, sensorParameters.requiresProcessing {
                    sourceImage = sensor.process(
                        sourceImage: lensed,
                        parameters: sensorParameters,
                        yawRateRadiansPerSecond: yawRate,
                        deltaTime: elapsed,
                        frameIndex: sensorFrameIndex
                    ) ?? lensed
                } else {
                    sourceImage = lensed
                }
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
                    self.processedFrameOwner = .fpv
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
    /// Which aircraft's camera the feed is coming from. A change means a different physical
    /// camera, so the exposure loop and the video processor start over instead of carrying the
    /// previous one's state across the cut.
    var observationSourceIdentity: String = "player"
    var fpvVideoPresentationState: RFVideoPresentationState? = nil
    /// Non-nil only for analog. The glyph grid is composited into the NTSC processor's RGB input.
    var analogFPVOSDState: FPVOSDState? = nil
    var analogNTSCParameters: AnalogNTSCParameters? = nil
    var digitalVideoParameters: DigitalVideoParameters = .clean
    var fiberVideoParameters: FiberVideoParameters = .clean
    var fpvFontPreset: FPVFontPreset = .betaflight
    /// Operator-authored OSD layout and what the installed equipment can actually feed it.
    var osdLayout: OSDLayoutConfiguration = .corners
    /// Wide-angle lens applied to the camera frame before anything is composited onto it.
    var fpvLensStrength: Double = 0
    var fpvLensHalfAngleDegrees: Double = 50
    var osdAvailability: OSDElementAvailability = .all
    /// Sensor characteristics of the camera the pilot flies from, when the FPV view is open.
    var fpvSensorParameters: CameraSensorParameters? = nil
    /// Sensor characteristics of the camera feeding the payload view, when that view is open.
    var payloadSensorParameters: CameraSensorParameters? = nil
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
            coordinator.configurePayloadSensorPipeline(parameters: payloadSensorParameters)
            let desiredTechnique = wantsWeatherDOF ? WeatherDepthOfFieldTechnique.shared : nil
            if view.technique !== desiredTechnique {
                view.technique = desiredTechnique
            }
            return
        }
        coordinator.deactivatePayloadSensorPipeline()

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
                sourceIdentity: observationSourceIdentity,
                mode: mode,
                presentationState: presentationState,
                osdState: analogFPVOSDState,
                lensStrength: fpvLensStrength,
                lensHalfAngleDegrees: fpvLensHalfAngleDegrees,
                osdLayout: osdLayout,
                osdAvailability: osdAvailability,
                fpvSensorParameters: fpvSensorParameters,
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
