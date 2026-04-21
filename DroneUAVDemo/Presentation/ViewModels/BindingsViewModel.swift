import Foundation
import Combine

@MainActor
final class BindingsViewModel: ObservableObject {
    @Published var isPresented: Bool = false
    @Published private(set) var sections: [KeyBindingSection] = []
    @Published private(set) var conflicts: [String] = []
    @Published var preferredControllerSurfaceID: String = "keybindings-sheet"
    @Published var focusedSectionID: String?

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

    func present() {
        isPresented = true
        refresh()
    }

    func dismiss() {
        captureCoordinator.endCapture(restoreTo: .flight)
        isPresented = false
    }

    func beginCapture(for command: KeyboardCommand) {
        captureCoordinator.beginCapture(for: command)
    }

    func endCapture() {
        captureCoordinator.endCapture(restoreTo: .flight)
    }

    func rebindCurrentCommand(keyCode: UInt16, keyLabel: String) {
        guard let activeCommand = captureCoordinator.activeCommand else {
            return
        }
        store.rebind(activeCommand, keyCode: keyCode, keyLabel: keyLabel)
        refresh()
        endCapture()
    }

    func resetToDefaults() {
        endCapture()
        store.resetToDefaults()
        refresh()
    }

    func refresh() {
        sections = store.sections()
        conflicts = store.conflicts()
        if focusedSectionID == nil {
            focusedSectionID = sections.first?.id
        }
    }
}
