import AppKit
import SceneKit

/// Training targets are visual markers, never physical obstacles.
final class FlightTrainingSceneLayer {
    private let root = SCNNode()
    private var nodes: [SCNNode] = []
    private var installedSpheres: [TrainingSphere] = []
    private var passedCount = -1

    func update(spheres: [TrainingSphere], passed: Int, parent: SCNNode) {
        if root.parent == nil {
            root.name = "instructor.spheres"
            parent.addChildNode(root)
        }
        if installedSpheres != spheres {
            root.childNodes.forEach { $0.removeFromParentNode() }
            nodes = spheres.map(makeSphere)
            nodes.forEach(root.addChildNode)
            installedSpheres = spheres
            passedCount = -1
        }
        guard passedCount != passed else { return }
        passedCount = passed
        for (index, node) in nodes.enumerated() {
            let color: NSColor = index < passed ? .systemGreen : index == passed ? .systemCyan : .systemGray
            node.opacity = index < passed ? 0.25 : index == passed ? 1 : 0.45
            node.enumerateChildNodes { child, _ in
                for material in child.geometry?.materials ?? [] {
                    material.diffuse.contents = color
                    material.emission.contents = color
                }
            }
        }
    }

    func clear() {
        root.removeFromParentNode()
        root.childNodes.forEach { $0.removeFromParentNode() }
        nodes.removeAll()
        installedSpheres.removeAll()
        passedCount = -1
    }

    private func makeSphere(_ target: TrainingSphere) -> SCNNode {
        let node = SCNNode()
        node.name = "instructor.sphere.\(target.id)"
        node.position = SCNVector3(target.center.x, target.center.y, target.center.z)
        let sphere = SCNSphere(radius: CGFloat(target.radius))
        sphere.segmentCount = 20
        let wire = SCNMaterial()
        wire.lightingModel = .constant
        wire.transparency = 0.055
        wire.blendMode = .alpha
        wire.isDoubleSided = true
        wire.writesToDepthBuffer = false
        let shell = SCNNode(geometry: sphere)
        shell.geometry?.materials = [wire]
        shell.castsShadow = false
        node.addChildNode(shell)

        // Three great circles make the volume legible without filling the flight path.
        for axis in 0..<3 {
            let ring = SCNTorus(ringRadius: CGFloat(target.radius), pipeRadius: 0.055)
            let material = SCNMaterial()
            material.lightingModel = .constant
            ring.materials = [material]
            let ringNode = SCNNode(geometry: ring)
            if axis == 1 { ringNode.eulerAngles.x = .pi / 2 }
            if axis == 2 { ringNode.eulerAngles.z = .pi / 2 }
            ringNode.castsShadow = false
            node.addChildNode(ringNode)
        }

        let text = SCNText(string: "\(target.id + 1)", extrusionDepth: 0)
        text.font = .systemFont(ofSize: 2, weight: .bold)
        text.flatness = 0.2
        let textMaterial = SCNMaterial()
        textMaterial.lightingModel = .constant
        text.materials = [textMaterial]
        let label = SCNNode(geometry: text)
        label.position = SCNVector3(-0.6, target.radius + 0.8, 0)
        label.constraints = [SCNBillboardConstraint()]
        label.castsShadow = false
        node.addChildNode(label)
        return node
    }
}
