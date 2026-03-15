import SwiftUI
import AppKit

@main
struct DroneUAVDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("window.fullscreen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}
