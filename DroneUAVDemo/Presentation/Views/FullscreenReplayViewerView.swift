import AppKit
import SceneKit
import simd

// MARK: - Keyboard-routing window

final class FullscreenReplayWindow: NSWindow {
    weak var keyboardHandler: FullscreenReplayWindowHost?

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            if keyboardHandler?.intercept(event) == true { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

// MARK: - SCNView with drag/scroll callbacks

final class ReplayInteractiveSCNView: SCNView {
    var onDrag:   ((Float, Float) -> Void)?
    var onScroll: ((Float) -> Void)?

    override func mouseDragged(with event: NSEvent) {
        if let h = onDrag {
            h(Float(event.deltaX), Float(event.deltaY))
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let h = onScroll {
            let delta = Self.normalizedScrollDelta(from: event)
            guard abs(delta) >= 0.002 else { return }
            h(delta)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private static func normalizedScrollDelta(from event: NSEvent) -> Float {
        let raw = Float(event.scrollingDeltaY)
        let clamped = max(-8, min(8, raw))
        return clamped * 0.05
    }
}

// MARK: - Fullscreen replay host (pure AppKit, no SwiftUI inside)

final class FullscreenReplayWindowHost: NSObject, NSWindowDelegate {

    static var current: FullscreenReplayWindowHost?

    // Owned resources
    private var window:    FullscreenReplayWindow?
    private var sceneView: ReplayInteractiveSCNView?
    private let sceneController = MissionReplaySceneController()
    private let player          = MissionReplayPlayer()
    private var session:        MissionReplaySession?

    // UI elements
    private var topBar:           NSView?
    private var bottomBar:        NSView?
    private var titleLabel:       NSTextField?
    private var subtitleLabel:    NSTextField?
    private var qualityBadge:     NSTextField?
    private var cameraModeLabel:  NSTextField?
    private var cameraModePopup:  NSPopUpButton?
    private var topDownHeightLabel: NSTextField?
    private var topDownHeightSlider: NSSlider?
    private var frameInfoLabel:   NSTextField?
    private var playPauseButton:  NSButton?
    private var stopButton:       NSButton?
    private var slowDownButton:   NSButton?
    private var speedUpButton:    NSButton?
    private var speedLabel:       NSTextField?
    private var slider:           NSSlider?
    private var timeLabel:        NSTextField?
    private var showUIButton:     NSButton?

    // Timers / state
    private var playbackTimer: Timer?
    private var wasdTimer:     Timer?
    private var lastWASDTime:  TimeInterval = 0
    private var pressedKeys:   Set<UInt16> = []
    private var shiftActive    = false
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var isClosing      = false

    // MARK: - Public API

    static func open(session: MissionReplaySession,
                     report: MissionReport?,
                     availableDroneProfiles: [DroneModelProfile],
                     initialTime: TimeInterval,
                     initialCameraMode: ReplayCameraMode = .freeObserver,
                     selectedEvent: MissionReplayEvent? = nil) {
        current?.requestClose()

        let host = FullscreenReplayWindowHost()
        current = host
        host.build(
            session: session,
            report:  report,
            availableDroneProfiles: availableDroneProfiles,
            initialTime: initialTime,
            initialCameraMode: initialCameraMode,
            selectedEvent: selectedEvent
        )
    }

    // MARK: - Build

    private func build(session: MissionReplaySession,
                       report: MissionReport?,
                       availableDroneProfiles: [DroneModelProfile],
                       initialTime: TimeInterval,
                       initialCameraMode: ReplayCameraMode,
                       selectedEvent: MissionReplayEvent?) {
        self.session = session

        // Load data
        let events = report?.events ?? session.events
        player.load(session: session)
        if initialTime > 0 { player.seek(to: initialTime) }
        sceneController.loadSession(
            session,
            availableDroneProfiles: availableDroneProfiles,
            events: events
        )
        sceneController.update(frame: player.currentFrame)
        sceneController.setSelectedEvent(selectedEvent ?? events.first)
        sceneController.setCameraMode(initialCameraMode)
        sceneController.update(frame: player.currentFrame)

        // Window
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let win = FullscreenReplayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor   = .black
        win.isOpaque          = true
        win.hasShadow         = false
        win.animationBehavior = .none
        win.level             = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false
        win.keyboardHandler   = self
        win.delegate          = self
        window = win

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        win.contentView = root

        // SCNView at full size as background
        let scnView = ReplayInteractiveSCNView(frame: root.bounds)
        scnView.scene                    = sceneController.scene
        scnView.pointOfView              = sceneController.cameraNode
        scnView.backgroundColor          = NSColor(white: 0.07, alpha: 1.0)
        scnView.antialiasingMode         = .multisampling2X
        scnView.rendersContinuously      = true
        scnView.preferredFramesPerSecond = 60
        scnView.allowsCameraControl      = false
        scnView.autoresizingMask         = [.width, .height]
        scnView.onDrag = { [weak self] dx, dy in
            self?.sceneController.handleDragInput(dx: dx, dy: dy)
        }
        scnView.onScroll = { [weak self] delta in
            self?.sceneController.handleScrollInput(delta: delta)
        }
        root.addSubview(scnView)
        sceneView = scnView

        // Overlays
        buildTopBar(in: root)
        buildBottomBar(in: root)
        buildShowUIButton(in: root)

        // Initial UI state
        updateUI()

        // Start timers
        startPlaybackTimer()
        startWASDTimer()

        // Present
        previousPresentationOptions = NSApp.presentationOptions
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    private func buildTopBar(in parent: NSView) {
        let bar = NSView(frame: NSRect(
            x: 0, y: parent.bounds.height - 56,
            width: parent.bounds.width, height: 56
        ))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        parent.addSubview(bar)
        topBar = bar

        let title = NSTextField(labelWithString: "Black Box Replay")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 16, y: 30, width: 260, height: 18)
        bar.addSubview(title)
        titleLabel = title

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.60)
        subtitle.frame = NSRect(x: 16, y: 10, width: 360, height: 14)
        bar.addSubview(subtitle)
        subtitleLabel = subtitle

        let cameraLabel = NSTextField(labelWithString: "Camera: \(sceneController.cameraMode.displayName)")
        cameraLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        cameraLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        cameraLabel.frame = NSRect(
            x: bar.bounds.width - 640, y: 20,
            width: 170, height: 16
        )
        cameraLabel.autoresizingMask = [.minXMargin]
        bar.addSubview(cameraLabel)
        cameraModeLabel = cameraLabel

        let cameraPopup = NSPopUpButton(frame: NSRect(
            x: bar.bounds.width - 465, y: 14,
            width: 150, height: 26
        ))
        cameraPopup.bezelStyle = .rounded
        cameraPopup.font = .systemFont(ofSize: 11, weight: .medium)
        for mode in availableCameraModes {
            cameraPopup.addItem(withTitle: mode.displayName)
            cameraPopup.lastItem?.representedObject = mode.rawValue
        }
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraModeChanged(_:))
        cameraPopup.autoresizingMask = [.minXMargin]
        bar.addSubview(cameraPopup)
        cameraModePopup = cameraPopup

        let heightLabel = NSTextField(labelWithString: "Top height: \(Int(sceneController.topDownHeight)) m")
        heightLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        heightLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        heightLabel.frame = NSRect(x: 392, y: 30, width: 130, height: 16)
        heightLabel.autoresizingMask = [.maxXMargin]
        bar.addSubview(heightLabel)
        topDownHeightLabel = heightLabel

        let heightSlider = NSSlider(
            value: Double(sceneController.topDownHeight),
            minValue: 30,
            maxValue: 400,
            target: self,
            action: #selector(topDownHeightChanged(_:))
        )
        heightSlider.frame = NSRect(x: 392, y: 8, width: 210, height: 20)
        heightSlider.autoresizingMask = [.maxXMargin]
        bar.addSubview(heightSlider)
        topDownHeightSlider = heightSlider

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .green
        badge.alignment = .right
        badge.frame = NSRect(
            x: bar.bounds.width - 320, y: 20,
            width: 100, height: 16
        )
        badge.autoresizingMask = [.minXMargin]
        bar.addSubview(badge)
        qualityBadge = badge

        let hideBtn = NSButton(title: "Hide UI", target: self, action: #selector(hideOverlay))
        hideBtn.bezelStyle = .rounded
        hideBtn.font = .systemFont(ofSize: 11, weight: .medium)
        hideBtn.frame = NSRect(
            x: bar.bounds.width - 200, y: 16,
            width: 90, height: 24
        )
        hideBtn.autoresizingMask = [.minXMargin]
        bar.addSubview(hideBtn)

        if let xImg = NSImage(systemSymbolName: "xmark.circle.fill",
                              accessibilityDescription: "Close") {
            let closeBtn = NSButton(image: xImg, target: self, action: #selector(closeRequested))
            closeBtn.isBordered = false
            closeBtn.contentTintColor = NSColor.white.withAlphaComponent(0.70)
            closeBtn.frame = NSRect(
                x: bar.bounds.width - 44, y: 16,
                width: 28, height: 24
            )
            closeBtn.autoresizingMask = [.minXMargin]
            bar.addSubview(closeBtn)
        }
    }

    private func buildBottomBar(in parent: NSView) {
        let bar = NSView(frame: NSRect(x: 0, y: 0,
                                       width: parent.bounds.width, height: 116))
        bar.autoresizingMask = [.width]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        parent.addSubview(bar)
        bottomBar = bar

        // Frame info strip (top)
        let info = NSTextField(labelWithString: "")
        info.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        info.textColor = NSColor.white.withAlphaComponent(0.85)
        info.frame = NSRect(x: 16, y: 86, width: bar.bounds.width - 32, height: 20)
        info.autoresizingMask = [.width]
        bar.addSubview(info)
        frameInfoLabel = info

        // Slider
        let s = NSSlider(value: 0, minValue: 0, maxValue: 1,
                         target: self, action: #selector(sliderChanged(_:)))
        s.frame = NSRect(x: 16, y: 58, width: bar.bounds.width - 32, height: 22)
        s.autoresizingMask = [.width]
        bar.addSubview(s)
        slider = s

        // Transport row
        var x: CGFloat = 16
        let stop = makeIconButton(symbol: "stop.fill", action: #selector(stopAction))
        stop.frame = NSRect(x: x, y: 16, width: 32, height: 30)
        bar.addSubview(stop)
        stopButton = stop
        x += 38

        let play = makeIconButton(symbol: "play.fill", action: #selector(playPauseAction))
        play.frame = NSRect(x: x, y: 16, width: 32, height: 30)
        play.contentTintColor = NSColor(red: 0.28, green: 0.65, blue: 1.0, alpha: 1.0)
        bar.addSubview(play)
        playPauseButton = play
        x += 44

        let slowDown = makeIconButton(symbol: "backward.fill", action: #selector(slowDownAction))
        slowDown.frame = NSRect(x: x, y: 16, width: 32, height: 30)
        bar.addSubview(slowDown)
        slowDownButton = slowDown
        x += 36

        let spd = NSTextField(labelWithString: "1×")
        spd.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        spd.textColor = NSColor(red: 0.28, green: 0.65, blue: 1.0, alpha: 1.0)
        spd.alignment = .center
        spd.frame = NSRect(x: x, y: 22, width: 46, height: 18)
        bar.addSubview(spd)
        speedLabel = spd
        x += 50

        let speedUp = makeIconButton(symbol: "forward.fill", action: #selector(speedUpAction))
        speedUp.frame = NSRect(x: x, y: 16, width: 32, height: 30)
        bar.addSubview(speedUp)
        speedUpButton = speedUp

        // Hint label (right of speed up, below time label)
        let hint = NSTextField(labelWithString:
            "WASD move · Q/E vertical · Drag look · Scroll zoom · Space play/pause · R reset · Esc close")
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = NSColor.white.withAlphaComponent(0.38)
        hint.alignment = .right
        hint.frame = NSRect(
            x: bar.bounds.width - 560, y: 4,
            width: 544, height: 12
        )
        hint.autoresizingMask = [.minXMargin]
        bar.addSubview(hint)

        // Time label (right)
        let t = NSTextField(labelWithString: "0.0s / 0.0s")
        t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        t.textColor = NSColor.white.withAlphaComponent(0.72)
        t.alignment = .right
        t.frame = NSRect(
            x: bar.bounds.width - 200, y: 22,
            width: 184, height: 18
        )
        t.autoresizingMask = [.minXMargin]
        bar.addSubview(t)
        timeLabel = t
    }

    private func makeIconButton(symbol: String, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                  ?? NSImage()
        let btn = NSButton(image: img, target: self, action: action)
        btn.isBordered = false
        btn.contentTintColor = .white
        btn.imageScaling = .scaleProportionallyDown
        return btn
    }

    private func buildShowUIButton(in parent: NSView) {
        guard let eye = NSImage(systemSymbolName: "eye.fill",
                                accessibilityDescription: "Show UI") else { return }
        let btn = NSButton(image: eye, target: self, action: #selector(showOverlay))
        btn.isBordered = false
        btn.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        btn.frame = NSRect(
            x: parent.bounds.width - 50, y: parent.bounds.height - 50,
            width: 34, height: 34
        )
        btn.autoresizingMask = [.minXMargin, .minYMargin]
        btn.isHidden = true
        parent.addSubview(btn)
        showUIButton = btn
    }

    // MARK: - Timers

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            self.player.update(deltaTime: 1.0 / 60.0)
            self.sceneController.update(frame: self.player.currentFrame)
            self.updateUI()
        }
        RunLoop.main.add(t, forMode: .common)
        playbackTimer = t
    }

    private func startWASDTimer() {
        wasdTimer?.invalidate()
        lastWASDTime = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.applyWASDMovement()
        }
        RunLoop.main.add(t, forMode: .common)
        wasdTimer = t
    }

    private func applyWASDMovement() {
        let now = CACurrentMediaTime()
        let dt  = Float(now - lastWASDTime)
        lastWASDTime = now
        guard !isClosing, !pressedKeys.isEmpty else { return }
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
            sceneController.moveCamera(localDelta: (delta / len) * speed * dt)
        }
    }

    // MARK: - UI update

    private func updateUI() {
        guard let session else { return }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        subtitleLabel?.stringValue = fmt.string(from: session.startedAt)

        let q = sceneController.reconstructionStatus.quality
        let color: NSColor
        switch q {
        case .full:     color = .green
        case .partial:  color = .yellow
        case .fallback: color = NSColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1.0)
        }
        qualityBadge?.stringValue = "● " + q.rawValue.uppercased()
        qualityBadge?.textColor   = color
        cameraModeLabel?.stringValue = "Camera: \(sceneController.cameraMode.displayName)"
        selectCameraPopupMode(sceneController.cameraMode)
        topDownHeightLabel?.stringValue = "Top height: \(Int(sceneController.topDownHeight)) m"
        topDownHeightSlider?.doubleValue = Double(sceneController.topDownHeight)
        let isTopDown = sceneController.cameraMode == .topDown
        topDownHeightLabel?.isHidden = !isTopDown
        topDownHeightSlider?.isHidden = !isTopDown

        if let frame = player.currentFrame {
            let vel   = frame.velocity.simd
            let speed = (vel.x * vel.x + vel.y * vel.y + vel.z * vel.z).squareRoot()
            let bat   = frame.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—"
            let ap    = frame.autopilotDescription ?? "—"
            var text  = String(format:
                "X %.1f   Y %.1f m   Z %.1f   Spd %.1f m/s   Mode %@   AP %@   Bat %@",
                frame.position.x, frame.position.y, frame.position.z, speed,
                frame.flightModeDescription, ap, bat)
            if frame.warningCount > 0 {
                text += "   ⚠ \(frame.warningCount)"
            }
            frameInfoLabel?.stringValue = text
        }

        if player.isLoaded, player.duration > 0 {
            slider?.maxValue = player.duration
            slider?.doubleValue = player.currentTime
            slider?.isEnabled = true
        } else {
            slider?.isEnabled = false
        }

        if let btn = playPauseButton {
            let symbol = player.isPlaying ? "pause.fill" : "play.fill"
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            btn.isEnabled = player.isLoaded
        }
        stopButton?.isEnabled     = player.isLoaded
        slowDownButton?.isEnabled = player.isLoaded &&
            player.playbackSpeed > (MissionReplayPlayer.allowedSpeeds.first ?? 0)
        speedUpButton?.isEnabled  = player.isLoaded &&
            player.playbackSpeed < (MissionReplayPlayer.allowedSpeeds.last ?? 0)

        speedLabel?.stringValue = speedLabelText(player.playbackSpeed)

        if player.isLoaded {
            timeLabel?.stringValue =
                "\(fmtTime(player.currentTime)) / \(fmtTime(player.duration))"
        }
    }

    private func speedLabelText(_ s: Double) -> String {
        switch s {
        case 0.25: return "0.25×"
        case 0.5:  return "0.5×"
        case 1.0:  return "1×"
        case 2.0:  return "2×"
        case 4.0:  return "4×"
        case 8.0:  return "8×"
        default:   return String(format: "%.2f×", s)
        }
    }

    private func fmtTime(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        let ms    = Int((t - Double(total)) * 10)
        if total < 60 { return String(format: "%d.%ds", total, ms) }
        return String(format: "%dm%02ds", total / 60, total % 60)
    }

    // MARK: - Button / slider actions

    @objc private func playPauseAction() {
        player.togglePlayPause()
        updateUI()
    }

    @objc private func stopAction() {
        player.stop()
        sceneController.update(frame: player.currentFrame)
        updateUI()
    }

    @objc private func slowDownAction() {
        player.slowDown()
        updateUI()
    }

    @objc private func speedUpAction() {
        player.speedUp()
        updateUI()
    }

    @objc private func cameraModeChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = ReplayCameraMode(rawValue: rawValue) else { return }
        setCameraMode(mode)
    }

    @objc private func topDownHeightChanged(_ sender: NSSlider) {
        sceneController.setTopDownHeight(Float(sender.doubleValue))
        sceneController.update(frame: player.currentFrame)
        updateUI()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        player.seek(to: sender.doubleValue)
        sceneController.update(frame: player.currentFrame)
        updateUI()
    }

    @objc private func hideOverlay() {
        topBar?.isHidden        = true
        bottomBar?.isHidden     = true
        showUIButton?.isHidden  = false
    }

    @objc private func showOverlay() {
        topBar?.isHidden        = false
        bottomBar?.isHidden     = false
        showUIButton?.isHidden  = true
    }

    private func setCameraMode(_ mode: ReplayCameraMode) {
        if mode != .freeObserver {
            pressedKeys.removeAll()
        }
        sceneController.setCameraMode(mode)
        sceneController.update(frame: player.currentFrame)
        updateUI()
    }

    private func selectCameraPopupMode(_ mode: ReplayCameraMode) {
        guard let popup = cameraModePopup else { return }
        let selectedRaw = popup.selectedItem?.representedObject as? String
        guard selectedRaw != mode.rawValue else { return }
        for item in popup.itemArray where item.representedObject as? String == mode.rawValue {
            popup.select(item)
            break
        }
    }

    private var availableCameraModes: [ReplayCameraMode] {
        var modes: [ReplayCameraMode] = [.freeObserver, .chase, .orbit, .topDown, .fpvApproximation]
        let events = session?.events ?? []
        if events.contains(where: { $0.type == .payloadReleased || $0.type == .payloadImpact }) {
            modes.append(.payloadFollow)
        }
        if !events.isEmpty {
            modes.append(.cinematicEvent)
        }
        return modes
    }

    @objc private func closeRequested() {
        // Defer one runloop tick so the click event finishes processing first.
        DispatchQueue.main.async { [weak self] in
            self?.requestClose()
        }
    }

    // MARK: - Keyboard interception

    fileprivate func intercept(_ event: NSEvent) -> Bool {
        guard !isClosing else { return false }
        switch event.type {
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            let kc = event.keyCode
            pressedKeys.remove(kc)
            shiftActive = event.modifierFlags.contains(.shift)
            return [53, 49, 15, 18, 19, 20, 21, 23, 22, 26, 13, 1, 0, 2, 12, 14].contains(Int(kc))
        case .flagsChanged:
            shiftActive = event.modifierFlags.contains(.shift)
            return false
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let kc = event.keyCode
        switch kc {
        case 53:                                                   // Esc
            if !event.isARepeat {
                pressedKeys.removeAll()
                DispatchQueue.main.async { [weak self] in self?.requestClose() }
            }
            return true
        case 49:                                                   // Space
            if !event.isARepeat { playPauseAction() }
            return true
        case 15:                                                   // R
            if !event.isARepeat { sceneController.resetCamera() }
            return true
        case 18:                                                   // 1
            if !event.isARepeat { setCameraMode(.freeObserver) }
            return true
        case 19:                                                   // 2
            if !event.isARepeat { setCameraMode(.chase) }
            return true
        case 20:                                                   // 3
            if !event.isARepeat { setCameraMode(.orbit) }
            return true
        case 21:                                                   // 4
            if !event.isARepeat { setCameraMode(.topDown) }
            return true
        case 23:                                                   // 5
            if !event.isARepeat { setCameraMode(.fpvApproximation) }
            return true
        case 22:                                                   // 6
            if !event.isARepeat, availableCameraModes.contains(.payloadFollow) { setCameraMode(.payloadFollow) }
            return true
        case 26:                                                   // 7
            if !event.isARepeat, availableCameraModes.contains(.cinematicEvent) { setCameraMode(.cinematicEvent) }
            return true
        case 13, 1, 0, 2, 12, 14:                                  // W S A D Q E
            pressedKeys.insert(kc)
            shiftActive = event.modifierFlags.contains(.shift)
            return true
        default:
            return false
        }
    }

    // MARK: - Close

    private func requestClose() {
        guard !isClosing else { return }
        closeNow()
    }

    /// Synchronous, ordered teardown. Safe to call from anywhere on the main
    /// thread. Releases the host via `Self.current = nil` after the window is
    /// closed.
    private func closeNow() {
        guard !isClosing else { return }
        isClosing = true

        playbackTimer?.invalidate(); playbackTimer = nil
        wasdTimer?.invalidate();     wasdTimer = nil
        pressedKeys.removeAll()
        if let previousPresentationOptions {
            NSApp.presentationOptions = previousPresentationOptions
            self.previousPresentationOptions = nil
        }

        sceneView?.isPlaying = false
        sceneView?.rendersContinuously = false
        sceneView?.delegate = nil
        sceneView?.onDrag = nil
        sceneView?.onScroll = nil

        if let win = window {
            win.keyboardHandler = nil
            win.delegate        = nil
            win.close()
        }
        window    = nil
        sceneView = nil

        if Self.current === self {
            let closingHost = self
            DispatchQueue.main.async {
                if Self.current === closingHost {
                    Self.current = nil
                }
            }
        }
    }

    // X button / Cmd+W path. Keep all close requests on the same staged path.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        DispatchQueue.main.async { [weak self] in self?.requestClose() }
        return false
    }

    deinit {
        playbackTimer?.invalidate()
        wasdTimer?.invalidate()
    }
}
