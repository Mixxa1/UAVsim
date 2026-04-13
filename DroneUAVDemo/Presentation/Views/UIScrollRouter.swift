import AppKit
import SwiftUI

private struct RegisteredScrollTarget {
    let id: String
    let surfaceID: String
    var frame: CGRect
    var isPrimary: Bool
    var scrollHandler: ((CGFloat) -> Bool)?
}

private struct ControllerScrollTargetFrame: Equatable, Identifiable {
    let id: String
    let frame: CGRect
}

final class UIScrollRouter: ObservableObject {
    private enum Tuning {
        static let scrollDeadzone: Double = 0.14
        static let baseScrollSpeed: CGFloat = 880.0
        static let triggerBoostSpeed: CGFloat = 1440.0
    }

    @Published private(set) var activeTargetID: String?
    @Published private(set) var preferredTargetID: String?

    private var surfaceStack: [String] = []
    private var targets: [String: RegisteredScrollTarget] = [:]
    private var cursorPosition: CGPoint = .zero
    private var cursorVisible: Bool = false

    private var activeSurfaceID: String? {
        surfaceStack.last
    }

    func activateSurface(_ id: String) {
        surfaceStack.removeAll { $0 == id }
        surfaceStack.append(id)
        refreshTargetSelection()
    }

    func deactivateSurface(_ id: String) {
        surfaceStack.removeAll { $0 == id }
        targets = targets.filter { $0.value.surfaceID != id }
        refreshTargetSelection()
    }

    func updateFrame(
        id: String,
        surfaceID: String,
        frame: CGRect,
        isPrimary: Bool
    ) {
        var target = targets[id] ?? RegisteredScrollTarget(
            id: id,
            surfaceID: surfaceID,
            frame: frame,
            isPrimary: isPrimary,
            scrollHandler: nil
        )
        target.frame = frame
        target.isPrimary = isPrimary
        targets[id] = target
        refreshTargetSelection()
    }

    func registerHandler(
        id: String,
        surfaceID: String,
        isPrimary: Bool,
        handler: @escaping (CGFloat) -> Bool
    ) {
        var target = targets[id].flatMap { existing -> RegisteredScrollTarget? in
            guard existing.surfaceID == surfaceID else {
                return nil
            }
            return existing
        } ?? RegisteredScrollTarget(
            id: id,
            surfaceID: surfaceID,
            frame: .zero,
            isPrimary: isPrimary,
            scrollHandler: handler
        )
        target.isPrimary = isPrimary
        target.scrollHandler = handler
        targets[id] = target
        refreshTargetSelection()
    }

    func unregisterTarget(
        id: String,
        surfaceID: String
    ) {
        guard targets[id]?.surfaceID == surfaceID else {
            return
        }

        targets[id] = nil
        refreshTargetSelection()
    }

    func updateCursor(
        position: CGPoint,
        isVisible: Bool
    ) {
        cursorPosition = position
        cursorVisible = isVisible
        refreshTargetSelection()
    }

    func routeScroll(
        verticalAxis: Double,
        triggerAxis: Double,
        behavior: ControllerScrollBehavior,
        deltaTime: TimeInterval
    ) -> Bool {
        guard let target = resolvedActiveTarget() else {
            return false
        }

        let scrollMagnitude = normalizedMagnitude(for: verticalAxis)
        let triggerMagnitude = behavior == .rightStickWithTriggerBoost
            ? normalizedMagnitude(for: triggerAxis)
            : 0.0

        guard abs(scrollMagnitude) > 0.001 || abs(triggerMagnitude) > 0.001 else {
            return false
        }

        let baseDelta = CGFloat(scrollMagnitude) * Tuning.baseScrollSpeed * CGFloat(max(0.0, deltaTime))
        let triggerDelta = CGFloat(triggerMagnitude) * Tuning.triggerBoostSpeed * CGFloat(max(0.0, deltaTime))
        let combinedDelta = baseDelta + triggerDelta

        guard abs(combinedDelta) > 0.5 else {
            return false
        }

        return target.scrollHandler?(combinedDelta) ?? false
    }

    private func normalizedMagnitude(for value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude > Tuning.scrollDeadzone else {
            return 0.0
        }

        let normalized = (magnitude - Tuning.scrollDeadzone) / (1.0 - Tuning.scrollDeadzone)
        return value.sign == .minus ? -normalized : normalized
    }

    private func refreshTargetSelection() {
        let target = resolvedActiveTarget()
        activeTargetID = target?.id
        preferredTargetID = target?.id
    }

    private func resolvedActiveTarget() -> RegisteredScrollTarget? {
        guard let activeSurfaceID else {
            return nil
        }

        let surfaceTargets = targets.values
            .filter { $0.surfaceID == activeSurfaceID && !$0.frame.isEmpty && $0.scrollHandler != nil }

        guard !surfaceTargets.isEmpty else {
            return nil
        }

        if cursorVisible,
           let hovered = surfaceTargets
            .filter({ $0.frame.contains(cursorPosition) })
            .min(by: { $0.frame.area < $1.frame.area }) {
            return hovered
        }

        if let preferredTargetID,
           let preferred = surfaceTargets.first(where: { $0.id == preferredTargetID }) {
            return preferred
        }

        if let primary = surfaceTargets
            .filter(\.isPrimary)
            .sorted(by: Self.targetOrdering(lhs:rhs:))
            .first {
            return primary
        }

        return surfaceTargets.sorted(by: Self.targetOrdering(lhs:rhs:)).first
    }

    private static func targetOrdering(
        lhs: RegisteredScrollTarget,
        rhs: RegisteredScrollTarget
    ) -> Bool {
        if abs(lhs.frame.minY - rhs.frame.minY) > 2.0 {
            return lhs.frame.minY < rhs.frame.minY
        }
        return lhs.frame.minX < rhs.frame.minX
    }
}

private struct ControllerScrollRouterEnvironmentKey: EnvironmentKey {
    static let defaultValue: UIScrollRouter? = nil
}

private struct ControllerSurfaceIDEnvironmentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var controllerScrollRouter: UIScrollRouter? {
        get { self[ControllerScrollRouterEnvironmentKey.self] }
        set { self[ControllerScrollRouterEnvironmentKey.self] = newValue }
    }

    var controllerSurfaceID: String? {
        get { self[ControllerSurfaceIDEnvironmentKey.self] }
        set { self[ControllerSurfaceIDEnvironmentKey.self] = newValue }
    }
}

private struct ControllerScrollTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [ControllerScrollTargetFrame] = []

    static func reduce(
        value: inout [ControllerScrollTargetFrame],
        nextValue: () -> [ControllerScrollTargetFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct ControllerScrollTargetGeometry: View {
    let id: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ControllerScrollTargetPreferenceKey.self,
                value: [
                    ControllerScrollTargetFrame(
                        id: id,
                        frame: proxy.frame(in: .named(ControllerUIBridge.coordinateSpaceName))
                    )
                ]
            )
        }
    }
}

private struct ControllerScrollProbe: NSViewRepresentable {
    let targetID: String
    let surfaceID: String
    let isPrimary: Bool
    let axes: Axis.Set
    let scrollRouter: UIScrollRouter

    func makeCoordinator() -> Coordinator {
        Coordinator(
            targetID: targetID,
            surfaceID: surfaceID,
            axes: axes,
            scrollRouter: scrollRouter
        )
    }

    func makeNSView(context: Context) -> ScrollProbeView {
        let view = ScrollProbeView()
        view.onResolveScrollView = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.attach(scrollView: scrollView, isPrimary: isPrimary)
        }
        return view
    }

    func updateNSView(_ nsView: ScrollProbeView, context: Context) {
        context.coordinator.targetID = targetID
        context.coordinator.surfaceID = surfaceID
        context.coordinator.axes = axes
        nsView.onResolveScrollView = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.attach(scrollView: scrollView, isPrimary: isPrimary)
        }
        nsView.resolveEnclosingScrollView()
    }

    static func dismantleNSView(_ nsView: ScrollProbeView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.onResolveScrollView = nil
    }

    final class Coordinator {
        var targetID: String
        var surfaceID: String
        var axes: Axis.Set

        private weak var scrollView: NSScrollView?
        private let scrollRouter: UIScrollRouter

        init(
            targetID: String,
            surfaceID: String,
            axes: Axis.Set,
            scrollRouter: UIScrollRouter
        ) {
            self.targetID = targetID
            self.surfaceID = surfaceID
            self.axes = axes
            self.scrollRouter = scrollRouter
        }

        func attach(
            scrollView: NSScrollView?,
            isPrimary: Bool
        ) {
            self.scrollView = scrollView
            scrollRouter.registerHandler(
                id: targetID,
                surfaceID: surfaceID,
                isPrimary: isPrimary
            ) { [weak self] delta in
                self?.scroll(delta: delta) ?? false
            }
        }

        func detach() {
            scrollRouter.unregisterTarget(id: targetID, surfaceID: surfaceID)
            scrollView = nil
        }

        private func scroll(delta: CGFloat) -> Bool {
            guard axes.contains(.vertical),
                  let scrollView,
                  let documentView = scrollView.documentView else {
                return false
            }

            let viewportHeight = scrollView.contentView.bounds.height
            let documentHeight = max(documentView.bounds.height, documentView.frame.height)
            let maxOffsetY = max(0.0, documentHeight - viewportHeight)
            guard maxOffsetY > 1.0 else {
                return false
            }

            var origin = scrollView.contentView.bounds.origin
            let nextOffsetY = min(max(0.0, origin.y + delta), maxOffsetY)
            guard abs(origin.y - nextOffsetY) > 0.5 else {
                return false
            }

            origin.y = nextOffsetY
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        }
    }
}

private final class ScrollProbeView: NSView {
    var onResolveScrollView: ((NSScrollView?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveEnclosingScrollView()
    }

    override func layout() {
        super.layout()
        resolveEnclosingScrollView()
    }

    func resolveEnclosingScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.onResolveScrollView?(self.enclosingScrollView)
        }
    }
}

struct ControllerScrollableRegion<Content: View>: View {
    let id: String
    var axes: Axis.Set = .vertical
    var showsIndicators: Bool = false
    var isPrimary: Bool = false
    @ViewBuilder let content: Content

    @Environment(\.controllerScrollRouter) private var controllerScrollRouter
    @Environment(\.controllerSurfaceID) private var controllerSurfaceID

    init(
        id: String,
        axes: Axis.Set = .vertical,
        showsIndicators: Bool = false,
        isPrimary: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.isPrimary = isPrimary
        self.content = content()
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
                .background(scrollProbe)
        }
        .background(ControllerScrollTargetGeometry(id: id))
        .onPreferenceChange(ControllerScrollTargetPreferenceKey.self) { frames in
            guard let controllerScrollRouter,
                  let controllerSurfaceID,
                  let targetFrame = frames.first(where: { $0.id == id }) else {
                return
            }

            controllerScrollRouter.updateFrame(
                id: id,
                surfaceID: controllerSurfaceID,
                frame: targetFrame.frame,
                isPrimary: isPrimary
            )
        }
        .onDisappear {
            guard let controllerScrollRouter,
                  let controllerSurfaceID else {
                return
            }

            controllerScrollRouter.unregisterTarget(
                id: id,
                surfaceID: controllerSurfaceID
            )
        }
    }

    @ViewBuilder
    private var scrollProbe: some View {
        if let controllerScrollRouter,
           let controllerSurfaceID {
            ControllerScrollProbe(
                targetID: id,
                surfaceID: controllerSurfaceID,
                isPrimary: isPrimary,
                axes: axes,
                scrollRouter: controllerScrollRouter
            )
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }
}
