import Foundation
import Combine

@MainActor
final class BindingsViewModel: ObservableObject {
    @Published var isPresented: Bool = false
    @Published private(set) var sections: [KeyBindingSection] = []
    @Published private(set) var conflicts: [String] = []
    @Published var preferredControllerSurfaceID: String = "keybindings-sheet"
    @Published var focusedSectionID: String?
    @Published private(set) var opensKeyBindingsPage = false

    private let store: InputBindingsStore
    let captureCoordinator: InputCaptureCoordinator

    init(
        store: InputBindingsStore,
        captureCoordinator: InputCaptureCoordinator
    ) {
        self.store = store
        self.captureCoordinator = captureCoordinator
        refresh()
    }

    func present(startWithKeys: Bool = false) {
        opensKeyBindingsPage = startWithKeys
        isPresented = true
        refresh()
    }

    func dismiss() {
        isPresented = false
        captureCoordinator.endCapture(restoreTo: .flight)
    }

    func beginCapture(for command: KeyboardCommand) {
        captureCoordinator.beginCapture(for: command)
    }

    func endCapture() {
        captureCoordinator.endCapture(restoreTo: isPresented ? .editing : .flight)
    }

    func rebindCurrentCommand(keyCode: UInt16, keyLabel: String, requiresShift: Bool = false) {
        guard let activeCommand = captureCoordinator.activeCommand else {
            return
        }
        store.rebind(activeCommand, keyCode: keyCode, keyLabel: keyLabel, requiresShift: requiresShift)
        refresh()
        endCapture()
    }

    func resetToDefaults() {
        endCapture()
        store.resetToDefaults()
        refresh()
    }

    func descriptor(for command: KeyboardCommand) -> KeyBindingDescriptor? {
        sections.lazy.flatMap(\.bindings).first { $0.command == command }
    }

    func refresh() {
        sections = store.sections()
        conflicts = store.conflicts()
        if focusedSectionID == nil {
            focusedSectionID = sections.first?.id
        }
    }
}
