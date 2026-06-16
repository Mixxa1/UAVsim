import SwiftUI
import AppKit

private final class CreditsWindowController: NSWindowController {
    static let shared = CreditsWindowController()

    init() {
        let view = NSHostingView(rootView: CreditsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("credits.title", comment: "")
        window.contentView = view
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum WindowFullscreenController {
    private static var transitioningWindowIDs: Set<ObjectIdentifier> = []

    static func toggle(preferredWindow: NSWindow? = nil) {
        guard let window = preferredWindow ?? NSApp.mainWindow ?? NSApp.keyWindow else {
            return
        }
        guard !(window is FullscreenReplayWindow) else {
            return
        }
        guard window.styleMask.contains(.titled) || window.styleMask.contains(.resizable) else {
            return
        }

        let id = ObjectIdentifier(window)
        guard !transitioningWindowIDs.contains(id) else {
            return
        }

        transitioningWindowIDs.insert(id)
        window.toggleFullScreen(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            transitioningWindowIDs.remove(id)
        }
    }

    static func markTransitionFinished(for window: NSWindow) {
        transitioningWindowIDs.remove(ObjectIdentifier(window))
    }
}

@main
struct DroneUAVDemoApp: App {
    var body: some Scene {
        WindowGroup {
            LegalGateRootView()
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("window.fullscreen") {
                    WindowFullscreenController.toggle()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandMenu("cadnext.menu.title") {
                Button("cadnext.menu.open") {
                    CADNextLauncherService.shared.openCADNext()
                }
            }
            CommandGroup(after: .help) {
                Button(LocalizedStringKey("credits.menu")) {
                    CreditsWindowController.shared.show()
                }
            }
        }
    }
}
