import AppKit
import SwiftUI

final class ReplayCenterWindowHost: NSObject, NSWindowDelegate {
    private static var current: ReplayCenterWindowHost?
    private var window: NSWindow?

    static func open(viewModel: ReplayLibraryViewModel,
                     availableDroneProfiles: [DroneModelProfile] = []) {
        current?.closeWindow()
        let host = ReplayCenterWindowHost()
        current = host
        host.open(viewModel: viewModel, availableDroneProfiles: availableDroneProfiles)
    }

    private func open(viewModel: ReplayLibraryViewModel,
                      availableDroneProfiles: [DroneModelProfile]) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = min(screen.visibleFrame.width  - 40, 1600)
        let h = min(screen.visibleFrame.height - 40, 960)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Бортовой самописец"
        win.minSize = NSSize(width: 960, height: 680)
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win

        let content = ReplayCenterView(
            viewModel: viewModel,
            availableDroneProfiles: availableDroneProfiles,
            onDismiss: { [weak self] in self?.closeWindow() }
        )
        win.contentViewController = NSHostingController(rootView: content)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
