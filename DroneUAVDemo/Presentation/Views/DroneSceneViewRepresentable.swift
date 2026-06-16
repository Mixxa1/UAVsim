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

    private var lastDragPoint: NSPoint?
    private var trackingArea: NSTrackingArea?
    private var isMouseLookCaptured = false
    private var isCursorHidden = false
    private static let suppressedSceneControlKeyCodes: Set<UInt16> = [37, 38] // L / J

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
        releaseMouseLook()
    }
}

struct DroneSceneViewRepresentable: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode
    let cameraMode: CameraMode
    let cameraSensitivity: Float
    let freeMoveSpeed: Float
    var targetFPS: Int = 60
    var stopRendering: Bool = false
    let onLookDelta: (Float, Float) -> Void
    let onRenderFrame: (TimeInterval, CameraMode) -> Void

    func makeCoordinator() -> SceneRenderCoordinator {
        SceneRenderCoordinator(cameraMode: cameraMode, onRenderFrame: onRenderFrame)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = FocusableSCNView()
        view.scene = scene
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = targetFPS
        view.rendersContinuously = false
        view.backgroundColor = .black
        view.isPlaying = !stopRendering
        view.delegate = context.coordinator
        view.onLookDelta = (cameraMode == .fpv || cameraMode == .spectator) ? onLookDelta : nil
        view.usesUnboundedMouseLook = cameraMode == .spectator

        configureCameraControl(on: view)

        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== scene {
            view.scene = scene
        }

        context.coordinator.cameraMode = cameraMode
        context.coordinator.onRenderFrame = onRenderFrame
        view.pointOfView = pointOfView
        view.preferredFramesPerSecond = targetFPS
        view.isPlaying = !stopRendering
        if let view = view as? FocusableSCNView {
            view.onLookDelta = (cameraMode == .fpv || cameraMode == .spectator) ? onLookDelta : nil
            view.usesUnboundedMouseLook = cameraMode == .spectator
        }
        configureCameraControl(on: view)
    }

    private func configureCameraControl(on view: SCNView) {
        let isFreeMode = cameraMode == .free
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
