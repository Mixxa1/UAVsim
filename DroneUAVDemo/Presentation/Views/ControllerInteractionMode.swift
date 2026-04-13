import Foundation

enum ControllerInteractionMode: String {
    case flight
    case uiNavigation
    case textInput

    var blocksFlightControls: Bool {
        self != .flight
    }

    var showsCursor: Bool {
        self == .uiNavigation
    }
}

struct ControllerKeyboardKey: Identifiable, Hashable {
    enum Kind: Hashable {
        case character(String)
        case space
        case backspace
        case confirm
        case cancel
    }

    let id: String
    let title: String
    let kind: Kind

    static let defaultRows: [[ControllerKeyboardKey]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map {
            ControllerKeyboardKey(id: "char-\($0)", title: $0, kind: .character($0))
        },
        ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"].map {
            ControllerKeyboardKey(id: "char-\($0)", title: $0, kind: .character($0))
        },
        ["A", "S", "D", "F", "G", "H", "J", "K", "L"].map {
            ControllerKeyboardKey(id: "char-\($0)", title: $0, kind: .character($0))
        },
        ["Z", "X", "C", "V", "B", "N", "M"].map {
            ControllerKeyboardKey(id: "char-\($0)", title: $0, kind: .character($0))
        },
        [
            ControllerKeyboardKey(id: "space", title: "Space", kind: .space),
            ControllerKeyboardKey(id: "backspace", title: "Backspace", kind: .backspace),
            ControllerKeyboardKey(id: "confirm", title: "OK", kind: .confirm),
            ControllerKeyboardKey(id: "cancel", title: "Cancel", kind: .cancel)
        ]
    ]
}

struct ControllerTextInputSession: Identifiable {
    let id = UUID()
    let title: String
    let placeholder: String
    let surfaceID: String
    var text: String
    var selectedKeyID: String

    static func make(
        title: String,
        placeholder: String,
        text: String,
        surfaceID: String
    ) -> ControllerTextInputSession {
        ControllerTextInputSession(
            title: title,
            placeholder: placeholder,
            surfaceID: surfaceID,
            text: text,
            selectedKeyID: ControllerKeyboardKey.defaultRows.first?.first?.id ?? "char-Q"
        )
    }
}

extension ResolvedControlState {
    func applyingInteractionMode(
        _ mode: ControllerInteractionMode,
        controllerSnapshot: InputSnapshot?
    ) -> ResolvedControlState {
        guard mode.blocksFlightControls,
              let controllerSnapshot,
              controllerSnapshot.isConnected else {
            return self
        }

        let controllerActions = Set(controllerSnapshot.actions)
        var next = self

        if dominantSource == .gameController {
            next.yaw = 0.0
            next.pitch = 0.0
            next.roll = 0.0
            next.throttle = 0.0
            next.cameraPan = 0.0
            next.cameraTilt = 0.0
            next.precisionMode = false
            next.boostMode = false
        }

        next.actions = actions.filter { action in
            !controllerActions.contains(action) || action.isControllerUIAction
        }

        return next
    }
}
