import AppKit
import SceneKit
import SwiftUI

private final class FocusableSCNView: SCNView {
    var onLookDelta: ((Float, Float) -> Void)?

    private var lastDragPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        lastDragPoint = event.locationInWindow
        super.rightMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleLookDrag(event)
        super.mouseDragged(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
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
}

struct DroneSceneViewRepresentable: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode
    let cameraMode: CameraMode
    let cameraSensitivity: Float
    let freeMoveSpeed: Float
    let onLookDelta: (Float, Float) -> Void

    func makeNSView(context: Context) -> SCNView {
        let view = FocusableSCNView()
        view.scene = scene
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 45
        view.rendersContinuously = false
        view.backgroundColor = .black
        view.isPlaying = true
        view.onLookDelta = onLookDelta

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

        view.pointOfView = pointOfView
        if let view = view as? FocusableSCNView {
            view.onLookDelta = onLookDelta
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
