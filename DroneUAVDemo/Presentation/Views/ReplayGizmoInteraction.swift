import AppKit
import SceneKit
import simd

/// Shared hit-testing and screen-space drag math for the onboard-mount gizmo, used by both
/// `ReplaySCNView` (windowed) and `ReplayInteractiveSCNView` (fullscreen) — kept in one place
/// since this is real geometry math, not display text, and the two views must behave identically.
enum ReplayGizmoInteraction {
    /// Tests a screen point against every gizmo axis handle, returning the first one hit (if any).
    /// Hidden nodes are excluded from hit-testing by SceneKit by default, so this is a no-op
    /// whenever the gizmo isn't currently shown.
    /// Move arrows and rotate rings are both live at once, so a hit could be either kind —
    /// try both and report which one actually matched.
    static func hitTestHandle(at point: CGPoint, in view: SCNView) -> (axis: ReplayGizmoAxis, kind: ReplayGizmoToolKind)? {
        let results = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for result in results {
            for kind: ReplayGizmoToolKind in [.move, .rotate] {
                if let axis = ReplayGizmoAxis.matching(nodeName: result.node.name, kind: kind) {
                    return (axis, kind)
                }
            }
        }
        return nil
    }

    /// Projects a 3D axis (given as a world-space origin + unit direction) into the view's screen
    /// space, then projects the 2D mouse-drag delta onto that screen-space direction to get how
    /// far along the axis (in world units) the drag corresponds to. Standard technique behind
    /// CAD/3D-tool translate gizmos: take one known-length step along the axis, see how many
    /// screen pixels that step covers at the current camera distance, then scale the mouse delta
    /// by the inverse of that to recover world units.
    static func axisDelta(
        view: SCNView,
        worldOrigin origin: SIMD3<Float>,
        worldDirection direction: SIMD3<Float>,
        mouseDeltaX: Float,
        mouseDeltaY: Float
    ) -> Float {
        let p0 = view.projectPoint(SCNVector3(origin.x, origin.y, origin.z))
        let stepped = origin + direction
        let p1 = view.projectPoint(SCNVector3(stepped.x, stepped.y, stepped.z))

        let screenDX = Float(p1.x - p0.x)
        let screenDY = Float(p1.y - p0.y)
        let screenLength = (screenDX * screenDX + screenDY * screenDY).squareRoot()
        guard screenLength > 0.0001 else { return 0 }

        let axisDirX = screenDX / screenLength
        let axisDirY = screenDY / screenLength
        // NSEvent's deltaY is positive when the pointer moves DOWN the screen, but SCNView's
        // (unflipped NSView) coordinate space — the same one projectPoint reports in — has Y
        // increasing UPWARD. Flip it here so "drag towards where the axis points on screen"
        // consistently gives a positive delta, regardless of that mismatch.
        let projectedPixels = mouseDeltaX * axisDirX + (-mouseDeltaY) * axisDirY
        // `direction` is a unit vector, so `screenLength` is exactly "pixels per 1 world unit"
        // along this axis at the gizmo's current distance from the camera.
        let rawDelta = projectedPixels / screenLength
        // Guards against a runaway jump if the axis is ever nearly edge-on to the camera (screenLength → 0).
        return max(-0.5, min(0.5, rawDelta))
    }
}
