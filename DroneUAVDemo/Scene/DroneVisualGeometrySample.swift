import SceneKit
import simd

/// Per-component AABB in the aircraft's physics body frame (the flight-root
/// node's space: +Y up, -Z forward, origin at the ground/gear reference —
/// including the legacy chase-camera yaw flip and the ground lift applied by
/// `DroneModelBuilder.wrapVisualModel`). Captured once per visual build; the
/// component graph builder consumes it so physics contact geometry always
/// matches the model actually being rendered (catalog, legacy and workbench
/// builds alike, at the displayed scale).
struct DroneVisualGeometryComponentBox: Hashable {
    let component: DamageComponent
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
}

struct DroneVisualGeometryPropeller: Hashable {
    let center: SIMD3<Float>
    let radius: Float
    /// +1 / -1 blade spin direction (from the visual rig's
    /// `propellerSpinDirections`, index-aligned with the propeller nodes).
    let spinDirection: Float
}

struct DroneVisualGeometrySample: Hashable {
    let componentBoxes: [DroneVisualGeometryComponentBox]
    let propellers: [DroneVisualGeometryPropeller]
    let boundsCenter: SIMD3<Float>
    let boundsSize: SIMD3<Float>
    let fpvAnchorPosition: SIMD3<Float>
    let payloadMountPosition: SIMD3<Float>

    static let empty = DroneVisualGeometrySample(
        componentBoxes: [],
        propellers: [],
        boundsCenter: .zero,
        boundsSize: SIMD3<Float>(repeating: 0.3),
        fpvAnchorPosition: .zero,
        payloadMountPosition: .zero
    )

    func boxes(for component: DamageComponent) -> [DroneVisualGeometryComponentBox] {
        componentBoxes.filter { $0.component == component }
    }

    /// Union AABB of every box mapped to `component`, if any geometry exists.
    func unionBox(for component: DamageComponent) -> DroneVisualGeometryComponentBox? {
        let boxes = boxes(for: component)
        guard !boxes.isEmpty else { return nil }
        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for box in boxes {
            minimum = simd_min(minimum, box.center - box.halfExtents)
            maximum = simd_max(maximum, box.center + box.halfExtents)
        }
        return DroneVisualGeometryComponentBox(
            component: component,
            center: (minimum + maximum) * 0.5,
            halfExtents: simd_max((maximum - minimum) * 0.5, SIMD3<Float>(repeating: 0.005))
        )
    }

    static func capture(from model: DroneVisualModel) -> DroneVisualGeometrySample {
        let bodyFrameNode = model.rootNode

        var boxes: [DroneVisualGeometryComponentBox] = []
        for (component, nodes) in model.componentNodes {
            for node in nodes {
                guard let aabb = accumulateBounds(of: node, in: bodyFrameNode) else { continue }
                boxes.append(
                    DroneVisualGeometryComponentBox(
                        component: component,
                        center: (aabb.min + aabb.max) * 0.5,
                        halfExtents: simd_max((aabb.max - aabb.min) * 0.5, SIMD3<Float>(repeating: 0.005))
                    )
                )
            }
        }

        var propellers: [DroneVisualGeometryPropeller] = []
        for (index, propNode) in model.propellerNodes.enumerated() {
            guard let aabb = accumulateBounds(of: propNode, in: bodyFrameNode) else { continue }
            let halfExtents = (aabb.max - aabb.min) * 0.5
            let spin = index < model.propellerSpinDirections.count
                ? model.propellerSpinDirections[index]
                : (index.isMultiple(of: 2) ? 1.0 : -1.0)
            propellers.append(
                DroneVisualGeometryPropeller(
                    center: (aabb.min + aabb.max) * 0.5,
                    radius: max(halfExtents.x, halfExtents.y, halfExtents.z, 0.02),
                    spinDirection: spin >= 0.0 ? 1.0 : -1.0
                )
            )
        }

        return DroneVisualGeometrySample(
            componentBoxes: boxes,
            propellers: propellers,
            boundsCenter: model.visualBoundsCenter,
            boundsSize: model.visualBoundsSize,
            fpvAnchorPosition: bodyFrameNode.simdConvertPosition(.zero, from: model.fpvAnchorNode),
            payloadMountPosition: bodyFrameNode.simdConvertPosition(.zero, from: model.payloadMountNode)
        )
    }

    private static func accumulateBounds(
        of node: SCNNode,
        in referenceNode: SCNNode
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var found = false
        accumulate(node: node, referenceNode: referenceNode, minimum: &minimum, maximum: &maximum, found: &found)
        return found ? (minimum, maximum) : nil
    }

    private static func accumulate(
        node: SCNNode,
        referenceNode: SCNNode,
        minimum: inout SIMD3<Float>,
        maximum: inout SIMD3<Float>,
        found: inout Bool
    ) {
        if node.geometry != nil {
            let box = node.boundingBox
            let localMin = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let localMax = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            for corner in corners(min: localMin, max: localMax) {
                let converted = referenceNode.simdConvertPosition(corner, from: node)
                minimum = simd_min(minimum, converted)
                maximum = simd_max(maximum, converted)
            }
            found = true
        }
        for child in node.childNodes {
            accumulate(node: child, referenceNode: referenceNode, minimum: &minimum, maximum: &maximum, found: &found)
        }
    }

    private static func corners(min: SIMD3<Float>, max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(min.x, min.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, min.z),
            SIMD3<Float>(min.x, max.y, max.z),
            SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(max.x, max.y, max.z)
        ]
    }
}
