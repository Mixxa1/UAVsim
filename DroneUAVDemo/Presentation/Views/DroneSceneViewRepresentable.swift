import AppKit
import CoreGraphics
import SceneKit
import SwiftUI

final class SceneRenderCoordinator: NSObject, SCNSceneRendererDelegate {
    var cameraMode: CameraMode
    var onRenderFrame: (TimeInterval, CameraMode) -> Void

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
}

private final class FocusableSCNView: SCNView {
    var onLookDelta: ((Float, Float) -> Void)?
    var usesUnboundedMouseLook: Bool = false {
        didSet {
            if usesUnboundedMouseLook {
                window?.acceptsMouseMovedEvents = true
                captureMouseLookIfPossible()
            } else {
                releaseMouseLook()
            }
        }
    }
    var renderPolicy: SceneRenderPolicy = .policy(for: .interacting) {
        didSet {
            applyRenderPolicy()
        }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            releaseMouseLook()
        } else if usesUnboundedMouseLook {
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
        preferredFramesPerSecond = renderPolicy.preferredFPS
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
        if usesUnboundedMouseLook {
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
    let onLookDelta: (Float, Float) -> Void
    let onRenderFrame: (TimeInterval, CameraMode) -> Void

    func makeCoordinator() -> SceneRenderCoordinator {
        SceneRenderCoordinator(cameraMode: cameraMode, onRenderFrame: onRenderFrame)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = FocusableSCNView()
        let quality = AppGraphicsSettings.quality
        view.scene = scene
        view.antialiasingMode = quality.antialiasingMode
        let policy = renderPolicyOverride ?? SceneRenderPolicy.policy(for: activityState)
        view.renderPolicy = policy
        view.backgroundColor = .black
        view.delegate = context.coordinator
        view.onLookDelta = isInteractive && (cameraMode == .fpv || cameraMode == .spectator) ? onLookDelta : nil
        view.usesUnboundedMouseLook = isInteractive && cameraMode == .spectator
        // DOF post-process honors both the weather request and the graphics tier (low disables it).
        view.technique = (wantsWeatherDepthOfField && quality.weatherDepthOfFieldEnabled)
            ? WeatherDepthOfFieldTechnique.shared : nil
        applyRenderScale(to: view)

        configureCameraControl(on: view)

        if isInteractive {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let quality = AppGraphicsSettings.quality
        let wantsTechnique = wantsWeatherDepthOfField && quality.weatherDepthOfFieldEnabled
        if wantsTechnique != (view.technique != nil) {
            view.technique = wantsTechnique ? WeatherDepthOfFieldTechnique.shared : nil
        }
        if view.antialiasingMode != quality.antialiasingMode {
            view.antialiasingMode = quality.antialiasingMode
        }
        applyRenderScale(to: view)

        if view.scene !== scene {
            view.scene = scene
        }

        context.coordinator.cameraMode = cameraMode
        context.coordinator.onRenderFrame = onRenderFrame
        view.pointOfView = pointOfView

        let policy = renderPolicyOverride ?? SceneRenderPolicy.policy(for: activityState)
        if let view = view as? FocusableSCNView {
            view.renderPolicy = policy
            view.onLookDelta = isInteractive && (cameraMode == .fpv || cameraMode == .spectator) ? onLookDelta : nil
            view.usesUnboundedMouseLook = isInteractive && cameraMode == .spectator
        } else {
            if view.preferredFramesPerSecond != policy.preferredFPS {
                view.preferredFramesPerSecond = policy.preferredFPS
            }
            view.isPlaying = policy.isPlaying
            view.rendersContinuously = policy.rendersContinuously
        }
        configureCameraControl(on: view)
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
