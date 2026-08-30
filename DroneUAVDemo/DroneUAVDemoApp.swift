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

/// Authoring window for real-world map packages. Follows `CreditsWindowController`'s pattern: a
/// standalone window with no connection to the simulation, so the map builder can be used and
/// judged without touching the flight path.
private final class WorldBuilderWindowController: NSWindowController {
    static let shared = WorldBuilderWindowController()

    init() {
        let view = NSHostingView(rootView: UAVWorldStudioView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("world.preview.title", comment: "")
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
    init() {
        // Coefficient tables dropped into the bundle replace the ones compiled in. Done at
        // launch, before any aircraft is built, because a table participates in calibrating
        // the wing area — arriving later would leave an airframe flying one curve with a
        // wing sized for another.
        MachCoefficientDatabase.importBundledTables()
    }

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
            CommandMenu("carrier.menu.title") {
                Button("carrier.menu.release") {
                    NotificationCenter.default.post(name: .uavsimCarrierRelease, object: nil)
                }
                // Cmd+E rather than a plain key: E on its own is the climb control, and the
                // flight window grabs unmodified keys through its own monitor before SwiftUI
                // sees them. A menu item is also the only way an operator finds out the
                // shortcut exists.
                .keyboardShortcut("e", modifiers: .command)
            }
            CommandMenu("cadnext.menu.title") {
                Button("cadnext.menu.open") {
                    CADNextLauncherService.shared.openCADNext()
                }
                Divider()
                Button("world.preview.menu") {
                    WorldBuilderWindowController.shared.show()
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

extension Notification.Name {
    /// Posted by the Carrier menu's release item. A notification rather than a direct call
    /// because SwiftUI's `.commands` block has no route to the running simulation's view
    /// model, and threading one through the whole scene hierarchy to deliver one keystroke
    /// would be a worse trade than a named message.
    static let uavsimCarrierRelease = Notification.Name("uavsim.carrier.release")
}
