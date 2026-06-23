import AppKit
import QuartzCore
import SceneKit
import SwiftUI
import simd

struct MissionReplaySceneViewRepresentable: NSViewRepresentable {
    let sceneController: MissionReplaySceneController
    let cameraMode: ReplayCameraMode
    /// When non-nil the view is in fullscreen mode. Keyboard is handled at the
    /// `FullscreenReplayWindow` level (sendEvent override) — the SCNView only
    /// processes mouse drag/scroll here.
    var onClose: (() -> Void)? = nil
    /// Reserved for parity with the fullscreen view API.
    var onPlayPause: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReplaySCNView {
        let view = ReplaySCNView()
        view.scene                    = sceneController.scene
        view.pointOfView              = sceneController.cameraNode
        view.backgroundColor          = NSColor(white: 0.07, alpha: 1.0)
        view.antialiasingMode         = .multisampling2X
        view.showsStatistics          = false
        view.rendersContinuously      = true
        view.preferredFramesPerSecond = 60
        view.technique                = sceneController.wantsWeatherDepthOfField ? WeatherDepthOfFieldTechnique.shared : nil

        let cfg = view.cameraControlConfiguration
        cfg.allowsTranslation       = true
        cfg.autoSwitchToFreeCamera  = false
        cfg.flyModeVelocity         = 6.0
        cfg.panSensitivity          = 0.9
        cfg.rotationSensitivity     = 0.8

        configureInput(for: view)
        applyMode(cameraMode, to: view)
        return view
    }

    func updateNSView(_ nsView: ReplaySCNView, context: Context) {
        if nsView.scene !== sceneController.scene {
            nsView.scene = sceneController.scene
        }
        nsView.pointOfView = sceneController.cameraNode
        let wantsTechnique = sceneController.wantsWeatherDepthOfField
        if wantsTechnique != (nsView.technique != nil) {
            nsView.technique = wantsTechnique ? WeatherDepthOfFieldTechnique.shared : nil
        }
        configureInput(for: nsView)
        applyMode(cameraMode, to: nsView)
    }

    static func dismantleNSView(_ nsView: ReplaySCNView, coordinator: Coordinator) {
        nsView.onDragDelta   = nil
        nsView.onScrollDelta = nil
        nsView.onMoveDelta = nil
        nsView.isFreeObserverActive = nil
        nsView.clearInputState()
        nsView.rendersContinuously = false
        // Leave scene / pointOfView alone — the controller still references
        // them and ARC will release the chain when the engine deinits.
    }

    // MARK: - Mode application

    private func configureInput(for view: ReplaySCNView) {
        let ctrl = sceneController
        view.isFreeObserverActive = { ctrl.cameraMode == .freeObserver }
        view.onMoveDelta = { delta in ctrl.moveCamera(localDelta: delta) }
    }

    private func applyMode(_ mode: ReplayCameraMode, to view: ReplaySCNView) {
        let ctrl = sceneController
        view.allowsCameraControl = false
        view.onDragDelta  = { dx, dy  in ctrl.handleDragInput(dx: dx, dy: dy) }
        view.onScrollDelta = { delta   in ctrl.handleScrollInput(delta: delta) }
    }

    final class Coordinator: NSObject {}
}

// MARK: - SCNView

final class ReplaySCNView: SCNView {

    var onDragDelta:   ((Float, Float) -> Void)?
    var onScrollDelta: ((Float) -> Void)?
    var onMoveDelta: ((SIMD3<Float>) -> Void)?
    var isFreeObserverActive: (() -> Bool)?

    private let movementKeyCodes: Set<UInt16> = [13, 1, 0, 2, 12, 14]
    private var pressedKeys: Set<UInt16> = []
    private var shiftActive = false
    private var movementTimer: Timer?
    private var lastMovementTime = CACurrentMediaTime()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMovementTimer()
            clearInputState()
        } else {
            startMovementTimer()
        }
    }

    // MARK: - Mouse / trackpad

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let handler = onDragDelta {
            handler(Float(event.deltaX), Float(event.deltaY))
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let handler = onScrollDelta {
            let delta = Self.normalizedScrollDelta(from: event)
            guard abs(delta) >= 0.002 else { return }
            handler(delta)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Keyboard movement

    override func keyDown(with event: NSEvent) {
        guard movementKeyCodes.contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        shiftActive = event.modifierFlags.contains(.shift)
        guard isFreeObserverActive?() == true else { return }
        pressedKeys.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        guard movementKeyCodes.contains(event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        pressedKeys.remove(event.keyCode)
        shiftActive = event.modifierFlags.contains(.shift)
    }

    override func flagsChanged(with event: NSEvent) {
        shiftActive = event.modifierFlags.contains(.shift)
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        clearInputState()
        return super.resignFirstResponder()
    }

    func clearInputState() {
        pressedKeys.removeAll()
        shiftActive = false
    }

    private func startMovementTimer() {
        guard movementTimer == nil else { return }
        lastMovementTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.applyMovement()
        }
        RunLoop.main.add(timer, forMode: .common)
        movementTimer = timer
    }

    private func stopMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = nil
    }

    private func applyMovement() {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastMovementTime)
        lastMovementTime = now
        guard !pressedKeys.isEmpty else { return }
        guard isFreeObserverActive?() == true else {
            clearInputState()
            return
        }
        guard dt > 0, dt < 0.2 else { return }

        let speed: Float = shiftActive ? 48.0 : 16.0
        var delta = SIMD3<Float>.zero
        if pressedKeys.contains(13) { delta.z -= 1 }   // W
        if pressedKeys.contains(1)  { delta.z += 1 }   // S
        if pressedKeys.contains(0)  { delta.x -= 1 }   // A
        if pressedKeys.contains(2)  { delta.x += 1 }   // D
        if pressedKeys.contains(12) { delta.y -= 1 }   // Q
        if pressedKeys.contains(14) { delta.y += 1 }   // E

        let len = simd_length(delta)
        if len > 0.001 {
            onMoveDelta?((delta / len) * speed * dt)
        }
    }

    private static func normalizedScrollDelta(from event: NSEvent) -> Float {
        let raw = Float(event.scrollingDeltaY)
        let clamped = max(-8, min(8, raw))
        return clamped * 0.05
    }
}
