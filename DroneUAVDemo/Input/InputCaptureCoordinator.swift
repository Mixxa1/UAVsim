import Foundation
import Combine

@MainActor
final class InputCaptureCoordinator: ObservableObject {
    @Published private(set) var isCapturingBinding: Bool = false
    @Published private(set) var activeCommand: KeyboardCommand?

    private let keyboardInputService: KeyboardInputProviding
    private let inputManager: InputManager

    init(
        keyboardInputService: KeyboardInputProviding,
        inputManager: InputManager
    ) {
        self.keyboardInputService = keyboardInputService
        self.inputManager = inputManager
    }

    func beginCapture(for command: KeyboardCommand) {
        activeCommand = command
        isCapturingBinding = true
        keyboardInputService.setInputProcessingMode(.bindingCapture)
        inputManager.reset()
    }

    func endCapture(restoreTo mode: InputProcessingMode = .flight) {
        activeCommand = nil
        isCapturingBinding = false
        keyboardInputService.setInputProcessingMode(mode)
        inputManager.reset()
    }
}
