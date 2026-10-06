import AppKit

// Only these UI symbols share the app's entry-point object. The headless probe omits that
// object and provides inert replacements; reaching a window command is itself a test failure.
@MainActor
enum WindowFullscreenController {
    static func toggle(preferredWindow: NSWindow? = nil) { preconditionFailure("No UI in the scene probe") }
    static func markTransitionFinished(for window: NSWindow) { preconditionFailure("No UI in the scene probe") }
}

extension Notification.Name {
    static let uavsimCarrierRelease = Notification.Name("uavsim.carrier.release")
}
