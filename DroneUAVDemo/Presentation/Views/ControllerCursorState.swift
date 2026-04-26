import SwiftUI

enum ControllerFocusDirection {
    case up
    case down
    case left
    case right
}

struct ControllerCursorState {
    var isVisible: Bool
    var position: CGPoint
    var velocity: CGPoint
    var containerSize: CGSize
    var speedMultiplier: CGFloat
    var activeTargetID: String?
    var hoveredElementID: String?
    var preferredScrollTargetID: String?

    static let hidden = ControllerCursorState(
        isVisible: false,
        position: .zero,
        velocity: .zero,
        containerSize: .zero,
        speedMultiplier: 1.0,
        activeTargetID: nil,
        hoveredElementID: nil,
        preferredScrollTargetID: nil
    )

    mutating func setContainerSize(_ size: CGSize) {
        containerSize = size
        clampToBounds()
    }

    mutating func center(on frame: CGRect) {
        position = CGPoint(x: frame.midX, y: frame.midY)
        clampToBounds()
    }

    mutating func move(dx: CGFloat, dy: CGFloat) {
        position.x += dx
        position.y += dy
        clampToBounds()
    }

    mutating func updateVelocity(
        target: CGPoint,
        blend: CGFloat
    ) {
        velocity.x += (target.x - velocity.x) * blend
        velocity.y += (target.y - velocity.y) * blend
    }

    mutating func clampToBounds() {
        guard containerSize.width > 0.0, containerSize.height > 0.0 else {
            position = .zero
            return
        }

        position.x = min(max(0.0, position.x), containerSize.width)
        position.y = min(max(0.0, position.y), containerSize.height)
    }
}

struct ControllerInteractionTargetFrame: Equatable, Identifiable {
    let id: String
    let frame: CGRect
    let isEnabled: Bool
}

private struct RegisteredControllerTarget {
    enum Kind {
        case action(() -> Void)
        case pointAction((CGPoint) -> Void)
        case textInput(
            title: String,
            placeholder: String,
            currentText: () -> String,
            onCommit: (String) -> Void
        )
    }

    let kind: Kind
}

private struct ControllerSurfaceState {
    var targetFrames: [String: ControllerInteractionTargetFrame] = [:]
    var size: CGSize = .zero
    var secondaryAction: (() -> Void)?
}

private struct AnalogNavigationState {
    var cooldown: TimeInterval = 0.0
    var lastDirection: ControllerFocusDirection?
}

@MainActor
final class ControllerUIBridge: ObservableObject {
    static let coordinateSpaceName = "controller-ui-surface"

    private static let baseCursorSpeed: CGFloat = 880.0
    private static let cursorResponse: CGFloat = 14.0
    private static let analogStepInitialDelay: TimeInterval = 0.22
    private static let analogStepRepeatDelay: TimeInterval = 0.12
    private static let analogStepThreshold: Double = 0.68

    @Published private(set) var cursorState: ControllerCursorState = .hidden
    @Published private(set) var activeTargetFrame: CGRect?
    @Published private(set) var textInputSession: ControllerTextInputSession?

    let scrollRouter: UIScrollRouter

    private var activeMode: ControllerInteractionMode = .flight
    private var controllerConnected: Bool = false
    private let settingsStore: ControllerSettingsStore
    private var surfaceStack: [String] = []
    private var surfaceStates: [String: ControllerSurfaceState] = [:]
    private var registeredTargets: [String: RegisteredControllerTarget] = [:]
    private var cursorEnabled: Bool = false

    private var textCommitHandler: ((String) -> Void)?
    private var textCancelHandler: (() -> Void)?
    private var textAnalogNavigation = AnalogNavigationState()

    init(
        settingsStore: ControllerSettingsStore,
        scrollRouter: UIScrollRouter = UIScrollRouter()
    ) {
        self.settingsStore = settingsStore
        self.scrollRouter = scrollRouter
    }

    var isTextInputPresented: Bool {
        textInputSession != nil
    }

    private var activeSurfaceID: String? {
        surfaceStack.last
    }

    func activateSurface(_ id: String) {
        surfaceStack.removeAll { $0 == id }
        surfaceStack.append(id)
        scrollRouter.activateSurface(id)
        refreshActiveSurfaceState(resetCursor: true)
    }

    func deactivateSurface(_ id: String) {
        surfaceStack.removeAll { $0 == id }
        surfaceStates[id] = nil
        scrollRouter.deactivateSurface(id)
        if textInputSession?.surfaceID == id {
            cancelTextInput()
        } else {
            refreshActiveSurfaceState(resetCursor: true)
        }
    }

    func setSurfaceSize(_ size: CGSize, for surfaceID: String) {
        var state = surfaceStates[surfaceID] ?? ControllerSurfaceState()
        state.size = size
        state.targetFrames = Dictionary(
            uniqueKeysWithValues: filteredTargetFrames(
                Array(state.targetFrames.values),
                in: size
            ).map { ($0.id, $0) }
        )
        surfaceStates[surfaceID] = state

        if activeSurfaceID == surfaceID {
            cursorState.setContainerSize(size)
        }
    }

    func updateTargetFrames(_ frames: [ControllerInteractionTargetFrame], for surfaceID: String) {
        var state = surfaceStates[surfaceID] ?? ControllerSurfaceState()
        state.targetFrames = Dictionary(
            uniqueKeysWithValues: filteredTargetFrames(
                frames,
                in: state.size
            ).map { ($0.id, $0) }
        )
        surfaceStates[surfaceID] = state

        if activeSurfaceID == surfaceID {
            refreshPublishedTargetFrame(resetCursorIfNeeded: false)
        }
    }

    func clearSurfaceTargets(_ surfaceID: String) {
        guard var state = surfaceStates[surfaceID] else {
            return
        }

        state.targetFrames = Dictionary(
            uniqueKeysWithValues: filteredTargetFrames(
                Array(state.targetFrames.values),
                in: state.size
            ).map { ($0.id, $0) }
        )
        surfaceStates[surfaceID] = state

        guard activeSurfaceID == surfaceID else {
            return
        }

        cursorState.activeTargetID = nil
        cursorState.hoveredElementID = nil
        activeTargetFrame = nil
        refreshPublishedTargetFrame(resetCursorIfNeeded: true)
    }

    func invalidateSurfaceLayout(_ surfaceID: String, resetCursor: Bool = true) {
        guard var state = surfaceStates[surfaceID] else {
            return
        }

        state.targetFrames = Dictionary(
            uniqueKeysWithValues: filteredTargetFrames(
                Array(state.targetFrames.values),
                in: state.size
            ).map { ($0.id, $0) }
        )
        surfaceStates[surfaceID] = state

        if activeSurfaceID == surfaceID {
            refreshActiveSurfaceState(resetCursor: resetCursor)
        }
    }

    func setSecondaryAction(_ action: (() -> Void)?, for surfaceID: String) {
        var state = surfaceStates[surfaceID] ?? ControllerSurfaceState()
        state.secondaryAction = action
        surfaceStates[surfaceID] = state
    }

    func registerActionTarget(id: String, action: @escaping () -> Void) {
        registeredTargets[id] = RegisteredControllerTarget(kind: .action(action))
    }

    func registerPointTarget(id: String, action: @escaping (CGPoint) -> Void) {
        registeredTargets[id] = RegisteredControllerTarget(kind: .pointAction(action))
    }

    func registerTextInputTarget(
        id: String,
        title: String,
        placeholder: String,
        currentText: @escaping () -> String,
        onCommit: @escaping (String) -> Void
    ) {
        registeredTargets[id] = RegisteredControllerTarget(
            kind: .textInput(
                title: title,
                placeholder: placeholder,
                currentText: currentText,
                onCommit: onCommit
            )
        )
    }

    func unregisterTarget(id: String) {
        registeredTargets[id] = nil
    }

    func update(
        from controlState: ResolvedControlState,
        mode: ControllerInteractionMode,
        cursorEnabled: Bool,
        controllerConnected: Bool,
        deltaTime: TimeInterval
    ) {
        let controllerConnectionChanged = self.controllerConnected != controllerConnected
        self.controllerConnected = controllerConnected
        let cursorVisibilityChanged = self.cursorEnabled != cursorEnabled
        self.cursorEnabled = cursorEnabled
        cursorState.speedMultiplier = CGFloat(settingsStore.cursorSpeedMultiplier)

        if activeMode != mode || controllerConnectionChanged || cursorVisibilityChanged {
            activeMode = mode
            updateCursorVisibility()
        }

        guard controllerConnected else {
            if cursorState.isVisible {
                cursorState = .hidden
                activeTargetFrame = nil
                debugLog("Cursor hidden: no connected controller")
            }
            scrollRouter.updateCursor(position: cursorState.position, isVisible: false)
            return
        }

        switch mode {
        case .flight:
            break
        case .uiNavigation:
            updateCursorMovement(
                horizontal: controlState.uiPointerX,
                vertical: controlState.uiPointerY,
                deltaTime: deltaTime
            )
            handleDirectionalActions(controlState)
            if controlState.uiPrimaryTriggered {
                activateCurrentTarget()
            }
            if controlState.uiSecondaryTriggered {
                surfaceStates[activeSurfaceID ?? ""]?.secondaryAction?()
            }
        case .textInput:
            handleTextInputDirectionalInput(controlState, deltaTime: deltaTime)
            if controlState.uiPrimaryTriggered {
                applySelectedKeyboardKey()
            }
            if controlState.uiSecondaryTriggered {
                cancelTextInput()
            }
        }

        scrollRouter.updateCursor(
            position: cursorState.position,
            isVisible: cursorState.isVisible
        )
        cursorState.preferredScrollTargetID = scrollRouter.preferredTargetID
    }

    func routeScroll(
        from controlState: ResolvedControlState,
        mode: ControllerInteractionMode,
        deltaTime: TimeInterval
    ) {
        guard mode == .uiNavigation else {
            return
        }

        let didScroll = scrollRouter.routeScroll(
            verticalAxis: controlState.uiScrollY,
            triggerAxis: controlState.throttle,
            behavior: settingsStore.scrollBehavior,
            deltaTime: deltaTime
        )

        if didScroll {
            cursorState.preferredScrollTargetID = scrollRouter.preferredTargetID
        }
    }

    private func updateCursorVisibility() {
        let shouldShowCursor = controllerConnected &&
            cursorEnabled &&
            activeMode == .uiNavigation &&
            textInputSession == nil
        guard cursorState.isVisible != shouldShowCursor else {
            if shouldShowCursor {
                refreshPublishedTargetFrame(resetCursorIfNeeded: false)
            }
            return
        }

        cursorState.isVisible = shouldShowCursor
        if shouldShowCursor {
            refreshActiveSurfaceState(resetCursor: true)
            debugLog("Cursor shown")
        } else {
            cursorState.velocity = .zero
            activeTargetFrame = nil
            debugLog("Cursor hidden")
        }
    }

    private func refreshActiveSurfaceState(resetCursor: Bool) {
        let size = surfaceStates[activeSurfaceID ?? ""]?.size ?? .zero
        cursorState.setContainerSize(size)
        refreshPublishedTargetFrame(resetCursorIfNeeded: resetCursor)
    }

    private func refreshPublishedTargetFrame(resetCursorIfNeeded: Bool) {
        guard let activeSurfaceID,
              let state = surfaceStates[activeSurfaceID] else {
            activeTargetFrame = nil
            cursorState.activeTargetID = nil
            cursorState.hoveredElementID = nil
            return
        }

        if resetCursorIfNeeded || cursorState.activeTargetID == nil || state.targetFrames[cursorState.activeTargetID ?? ""] == nil {
            focusInitialTarget(in: state)
            return
        }

        activeTargetFrame = state.targetFrames[cursorState.activeTargetID ?? ""]?.frame
    }

    private func focusInitialTarget(in state: ControllerSurfaceState) {
        let frames = state.targetFrames.values.filter(\.isEnabled)
        guard let firstFrame = frames.sorted(by: Self.targetOrdering(lhs:rhs:)).first else {
            activeTargetFrame = nil
            cursorState.activeTargetID = nil
            cursorState.hoveredElementID = nil
            return
        }

        cursorState.activeTargetID = firstFrame.id
        cursorState.hoveredElementID = firstFrame.id
        cursorState.center(on: firstFrame.frame)
        activeTargetFrame = firstFrame.frame
    }

    private func updateCursorMovement(
        horizontal: Double,
        vertical: Double,
        deltaTime: TimeInterval
    ) {
        guard cursorState.isVisible else {
            return
        }

        let magnitude = max(abs(horizontal), abs(vertical))
        let acceleration = 1.0 + CGFloat(magnitude) * 0.34
        let targetVelocity = CGPoint(
            x: CGFloat(horizontal) * Self.baseCursorSpeed * cursorState.speedMultiplier * acceleration,
            y: CGFloat(vertical) * Self.baseCursorSpeed * cursorState.speedMultiplier * acceleration
        )
        let blend = min(1.0, CGFloat(max(0.0, deltaTime)) * Self.cursorResponse)
        cursorState.updateVelocity(target: targetVelocity, blend: blend)

        let dx = cursorState.velocity.x * CGFloat(max(0.0, deltaTime))
        let dy = cursorState.velocity.y * CGFloat(max(0.0, deltaTime))

        guard abs(dx) > 0.01 || abs(dy) > 0.01 else {
            return
        }

        cursorState.move(dx: dx, dy: dy)
        updateHoveredTarget(at: cursorState.position)
    }

    private func updateHoveredTarget(at point: CGPoint) {
        guard let state = surfaceStates[activeSurfaceID ?? ""] else {
            return
        }

        let frames = state.targetFrames.values.filter(\.isEnabled)
        if let containingFrame = frames
            .filter({ $0.frame.contains(point) })
            .min(by: { $0.frame.area < $1.frame.area }) {
            cursorState.activeTargetID = containingFrame.id
            cursorState.hoveredElementID = containingFrame.id
            activeTargetFrame = containingFrame.frame
            return
        }

        cursorState.hoveredElementID = nil
        activeTargetFrame = state.targetFrames[cursorState.activeTargetID ?? ""]?.frame
    }

    private func handleDirectionalActions(_ controlState: ResolvedControlState) {
        if controlState.uiFocusLeftTriggered {
            moveFocus(in: .left)
        }
        if controlState.uiFocusRightTriggered {
            moveFocus(in: .right)
        }
        if controlState.uiFocusUpTriggered {
            moveFocus(in: .up)
        }
        if controlState.uiFocusDownTriggered {
            moveFocus(in: .down)
        }
    }

    private func moveFocus(in direction: ControllerFocusDirection) {
        guard let state = surfaceStates[activeSurfaceID ?? ""] else {
            return
        }

        let frames = state.targetFrames.values.filter(\.isEnabled)
        guard !frames.isEmpty else {
            return
        }

        guard let currentTargetID = cursorState.activeTargetID,
              let currentFrame = state.targetFrames[currentTargetID] else {
            focusInitialTarget(in: state)
            return
        }

        let currentCenter = currentFrame.frame.center
        let candidates = frames.filter { candidate in
            switch direction {
            case .left:
                return candidate.frame.midX < currentCenter.x - 1.0
            case .right:
                return candidate.frame.midX > currentCenter.x + 1.0
            case .up:
                return candidate.frame.midY < currentCenter.y - 1.0
            case .down:
                return candidate.frame.midY > currentCenter.y + 1.0
            }
        }

        let nextTarget = candidates.min { lhs, rhs in
            directionalScore(from: currentCenter, to: lhs.frame.center, direction: direction) <
                directionalScore(from: currentCenter, to: rhs.frame.center, direction: direction)
        } ?? frames.sorted(by: Self.targetOrdering(lhs:rhs:)).first

        guard let nextTarget else {
            return
        }

        cursorState.activeTargetID = nextTarget.id
        cursorState.hoveredElementID = nextTarget.id
        cursorState.center(on: nextTarget.frame)
        activeTargetFrame = nextTarget.frame
    }

    private func activateCurrentTarget() {
        let currentTargetID = cursorState.hoveredElementID ?? cursorState.activeTargetID
        guard let currentTargetID,
              let targetFrame = surfaceStates[activeSurfaceID ?? ""]?.targetFrames[currentTargetID],
              targetFrame.isEnabled,
              let target = registeredTargets[currentTargetID] else {
            return
        }

        switch target.kind {
        case let .action(action):
            action()
        case let .pointAction(action):
            let localPoint = CGPoint(
                x: max(0.0, min(cursorState.position.x - targetFrame.frame.minX, targetFrame.frame.width)),
                y: max(0.0, min(cursorState.position.y - targetFrame.frame.minY, targetFrame.frame.height))
            )
            action(localPoint)
        case let .textInput(title, placeholder, currentText, onCommit):
            beginTextInput(
                title: title,
                placeholder: placeholder,
                currentText: currentText(),
                surfaceID: activeSurfaceID ?? "",
                onCommit: onCommit
            )
        }
    }

    private func beginTextInput(
        title: String,
        placeholder: String,
        currentText: String,
        surfaceID: String,
        onCommit: @escaping (String) -> Void
    ) {
        textCommitHandler = onCommit
        textCancelHandler = nil
        textAnalogNavigation = AnalogNavigationState()
        textInputSession = .make(
            title: title,
            placeholder: placeholder,
            text: currentText,
            surfaceID: surfaceID
        )
        updateCursorVisibility()
        debugLog("Virtual keyboard opened: \(title)")
    }

    func cancelTextInput() {
        guard textInputSession != nil else {
            return
        }

        textCancelHandler?()
        textCommitHandler = nil
        textCancelHandler = nil
        textInputSession = nil
        textAnalogNavigation = AnalogNavigationState()
        updateCursorVisibility()
        debugLog("Virtual keyboard closed")
    }

    private func confirmTextInput() {
        guard let session = textInputSession else {
            return
        }

        textCommitHandler?(session.text)
        textCommitHandler = nil
        textCancelHandler = nil
        textInputSession = nil
        textAnalogNavigation = AnalogNavigationState()
        updateCursorVisibility()
        debugLog("Virtual keyboard committed")
    }

    private func handleTextInputDirectionalInput(
        _ controlState: ResolvedControlState,
        deltaTime: TimeInterval
    ) {
        if controlState.uiFocusLeftTriggered {
            moveKeyboardSelection(.left)
        }
        if controlState.uiFocusRightTriggered {
            moveKeyboardSelection(.right)
        }
        if controlState.uiFocusUpTriggered {
            moveKeyboardSelection(.up)
        }
        if controlState.uiFocusDownTriggered {
            moveKeyboardSelection(.down)
        }

        guard let analogDirection = analogDirection(
            horizontal: controlState.uiPointerX,
            vertical: controlState.uiPointerY
        ) else {
            textAnalogNavigation.cooldown = 0.0
            textAnalogNavigation.lastDirection = nil
            return
        }

        textAnalogNavigation.cooldown = max(0.0, textAnalogNavigation.cooldown - deltaTime)
        let isRepeatedDirection = textAnalogNavigation.lastDirection == analogDirection

        guard textAnalogNavigation.cooldown <= 0.0 else {
            return
        }

        moveKeyboardSelection(analogDirection)
        textAnalogNavigation.cooldown = isRepeatedDirection
            ? Self.analogStepRepeatDelay
            : Self.analogStepInitialDelay
        textAnalogNavigation.lastDirection = analogDirection
    }

    private func analogDirection(horizontal: Double, vertical: Double) -> ControllerFocusDirection? {
        let horizontalMagnitude = abs(horizontal)
        let verticalMagnitude = abs(vertical)
        guard max(horizontalMagnitude, verticalMagnitude) >= Self.analogStepThreshold else {
            return nil
        }

        if horizontalMagnitude > verticalMagnitude {
            return horizontal < 0.0 ? .left : .right
        }

        return vertical < 0.0 ? .up : .down
    }

    private func moveKeyboardSelection(_ direction: ControllerFocusDirection) {
        guard var session = textInputSession,
              let currentIndex = keyboardPosition(for: session.selectedKeyID) else {
            return
        }

        var row = currentIndex.row
        var column = currentIndex.column

        switch direction {
        case .left:
            column = max(0, column - 1)
        case .right:
            column = min(ControllerKeyboardKey.defaultRows[row].count - 1, column + 1)
        case .up:
            row = max(0, row - 1)
            column = min(column, ControllerKeyboardKey.defaultRows[row].count - 1)
        case .down:
            row = min(ControllerKeyboardKey.defaultRows.count - 1, row + 1)
            column = min(column, ControllerKeyboardKey.defaultRows[row].count - 1)
        }

        session.selectedKeyID = ControllerKeyboardKey.defaultRows[row][column].id
        textInputSession = session
    }

    private func applySelectedKeyboardKey() {
        guard var session = textInputSession,
              let key = ControllerKeyboardKey.defaultRows
                .flatMap({ $0 })
                .first(where: { $0.id == session.selectedKeyID }) else {
            return
        }

        switch key.kind {
        case let .character(character):
            session.text.append(character)
            textInputSession = session
        case .space:
            session.text.append(" ")
            textInputSession = session
        case .backspace:
            if !session.text.isEmpty {
                session.text.removeLast()
                textInputSession = session
            }
        case .confirm:
            confirmTextInput()
        case .cancel:
            cancelTextInput()
        }
    }

    private func keyboardPosition(for keyID: String) -> (row: Int, column: Int)? {
        for (rowIndex, row) in ControllerKeyboardKey.defaultRows.enumerated() {
            if let columnIndex = row.firstIndex(where: { $0.id == keyID }) {
                return (rowIndex, columnIndex)
            }
        }
        return nil
    }

    private func directionalScore(
        from origin: CGPoint,
        to candidate: CGPoint,
        direction: ControllerFocusDirection
    ) -> CGFloat {
        let deltaX = candidate.x - origin.x
        let deltaY = candidate.y - origin.y

        switch direction {
        case .left, .right:
            return abs(deltaX) + abs(deltaY) * 1.75
        case .up, .down:
            return abs(deltaY) + abs(deltaX) * 1.75
        }
    }

    private static func targetOrdering(
        lhs: ControllerInteractionTargetFrame,
        rhs: ControllerInteractionTargetFrame
    ) -> Bool {
        if abs(lhs.frame.minY - rhs.frame.minY) > 2.0 {
            return lhs.frame.minY < rhs.frame.minY
        }
        return lhs.frame.minX < rhs.frame.minX
    }

    private func filteredTargetFrames(
        _ frames: [ControllerInteractionTargetFrame],
        in size: CGSize
    ) -> [ControllerInteractionTargetFrame] {
        let surfaceRect = CGRect(origin: .zero, size: size)
        guard surfaceRect.isFiniteGeometry else {
            return []
        }

        return frames.compactMap { frame in
            guard frame.frame.isFiniteGeometry else {
                return nil
            }

            let clippedFrame = frame.frame.standardized.intersection(surfaceRect)
            guard clippedFrame.isFiniteGeometry,
                  clippedFrame.width >= 4.0,
                  clippedFrame.height >= 4.0 else {
                return nil
            }

            return ControllerInteractionTargetFrame(
                id: frame.id,
                frame: clippedFrame,
                isEnabled: frame.isEnabled
            )
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[ControllerUIBridge] \(message)")
        #endif
    }
}

private struct ControllerUIBridgeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ControllerUIBridge? = nil
}

extension EnvironmentValues {
    var controllerUIBridge: ControllerUIBridge? {
        get { self[ControllerUIBridgeEnvironmentKey.self] }
        set { self[ControllerUIBridgeEnvironmentKey.self] = newValue }
    }
}

private struct ControllerInteractionTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [ControllerInteractionTargetFrame] = []

    static func reduce(
        value: inout [ControllerInteractionTargetFrame],
        nextValue: () -> [ControllerInteractionTargetFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct ControllerInteractionTargetGeometry: View {
    let id: String
    let isEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ControllerInteractionTargetPreferenceKey.self,
                value: [
                    ControllerInteractionTargetFrame(
                        id: id,
                        frame: proxy.frame(in: .named(ControllerUIBridge.coordinateSpaceName)),
                        isEnabled: isEnabled
                    )
                ]
            )
        }
    }
}

private struct ControllerButtonTargetModifier: ViewModifier {
    @Environment(\.controllerUIBridge) private var controllerUIBridge
    @Environment(\.isEnabled) private var isEnabled

    let id: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .background(ControllerInteractionTargetGeometry(id: id, isEnabled: isEnabled))
            .onAppear {
                controllerUIBridge?.registerActionTarget(id: id, action: action)
            }
            .onDisappear {
                controllerUIBridge?.unregisterTarget(id: id)
            }
    }
}

private struct ControllerTextInputTargetModifier: ViewModifier {
    @Environment(\.controllerUIBridge) private var controllerUIBridge
    @Environment(\.isEnabled) private var isEnabled

    let id: String
    let title: String
    let placeholder: String
    let currentText: () -> String
    let onCommit: (String) -> Void

    func body(content: Content) -> some View {
        content
            .background(ControllerInteractionTargetGeometry(id: id, isEnabled: isEnabled))
            .onAppear {
                controllerUIBridge?.registerTextInputTarget(
                    id: id,
                    title: title,
                    placeholder: placeholder,
                    currentText: currentText,
                    onCommit: onCommit
                )
            }
            .onDisappear {
                controllerUIBridge?.unregisterTarget(id: id)
            }
    }
}

private struct ControllerPointTargetModifier: ViewModifier {
    @Environment(\.controllerUIBridge) private var controllerUIBridge
    @Environment(\.isEnabled) private var isEnabled

    let id: String
    let action: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content
            .background(ControllerInteractionTargetGeometry(id: id, isEnabled: isEnabled))
            .onAppear {
                controllerUIBridge?.registerPointTarget(id: id, action: action)
            }
            .onDisappear {
                controllerUIBridge?.unregisterTarget(id: id)
            }
    }
}

extension View {
    func controllerButtonTarget(
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        modifier(ControllerButtonTargetModifier(id: id, action: action))
    }

    func controllerTextInputTarget(
        id: String,
        title: String,
        placeholder: String = "",
        currentText: @escaping () -> String,
        onCommit: @escaping (String) -> Void
    ) -> some View {
        modifier(
            ControllerTextInputTargetModifier(
                id: id,
                title: title,
                placeholder: placeholder,
                currentText: currentText,
                onCommit: onCommit
            )
        )
    }

    func controllerPointTarget(
        id: String,
        action: @escaping (CGPoint) -> Void
    ) -> some View {
        modifier(ControllerPointTargetModifier(id: id, action: action))
    }
}

struct ControllerInteractionSurface<Content: View>: View {
    @ObservedObject var bridge: ControllerUIBridge
    let surfaceID: String
    let secondaryAction: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        bridge: ControllerUIBridge,
        surfaceID: String,
        secondaryAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.bridge = bridge
        self.surfaceID = surfaceID
        self.secondaryAction = secondaryAction
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .environment(\.controllerUIBridge, bridge)
                .environment(\.controllerScrollRouter, bridge.scrollRouter)
                .environment(\.controllerSurfaceID, surfaceID)
                .coordinateSpace(name: ControllerUIBridge.coordinateSpaceName)
                .onAppear {
                    bridge.activateSurface(surfaceID)
                    bridge.setSurfaceSize(proxy.size, for: surfaceID)
                    bridge.setSecondaryAction(secondaryAction, for: surfaceID)
                }
                .onDisappear {
                    bridge.clearSurfaceTargets(surfaceID)
                    bridge.deactivateSurface(surfaceID)
                }
                .onChange(of: proxy.size) { _, size in
                    bridge.setSurfaceSize(size, for: surfaceID)
                }
                .onPreferenceChange(ControllerInteractionTargetPreferenceKey.self) { frames in
                    bridge.setSurfaceSize(proxy.size, for: surfaceID)
                    bridge.updateTargetFrames(frames, for: surfaceID)
                }
                .overlay {
                    ControllerCursorOverlay(
                        state: bridge.cursorState,
                        activeTargetFrame: bridge.activeTargetFrame
                    )
                }
                .overlay(alignment: .bottom) {
                    VirtualKeyboardView(bridge: bridge)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 20)
                }
        }
    }
}

extension NumberFormatter {
    func controllerDouble(from rawText: String) -> Double? {
        let sanitized = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: decimalSeparator ?? ".")
        guard !sanitized.isEmpty else {
            return nil
        }

        if let number = number(from: sanitized) {
            return number.doubleValue
        }

        return Double(sanitized)
    }
}

private extension CGRect {
    var isFiniteGeometry: Bool {
        !isNull &&
        !isInfinite &&
        origin.x.isFinite &&
        origin.y.isFinite &&
        width.isFinite &&
        height.isFinite &&
        width > 0.0 &&
        height > 0.0
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        width * height
    }
}
