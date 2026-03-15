import AppKit
import SceneKit

struct SceneSetup {
    let scene: SCNScene
    let cameraNode: SCNNode
    let sunLightNode: SCNNode
    let groundNode: SCNNode
    let gridNode: SCNNode
    let axesNode: SCNNode
}

enum SceneFactory {
    static func makeScene() -> SceneSetup {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.14, alpha: 1.0)

        let cameraNode = makeCameraNode()
        let sunLightNode = makeDirectionalLightNode()
        let groundNode = makeGroundNode()
        let gridNode = makeGridNode()
        let axesNode = makeAxesNode()

        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(makeAmbientLightNode())
        scene.rootNode.addChildNode(sunLightNode)
        scene.rootNode.addChildNode(makeFillLightNode())
        scene.rootNode.addChildNode(groundNode)
        scene.rootNode.addChildNode(gridNode)
        scene.rootNode.addChildNode(axesNode)

        return SceneSetup(
            scene: scene,
            cameraNode: cameraNode,
            sunLightNode: sunLightNode,
            groundNode: groundNode,
            gridNode: gridNode,
            axesNode: axesNode
        )
    }

    private static func makeCameraNode() -> SCNNode {
        let node = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 52
        camera.zNear = 0.01
        camera.zFar = 800
        node.camera = camera
        node.position = SCNVector3(0, 12.0, 24.0)
        node.eulerAngles = SCNVector3(-0.38, 0, 0)
        return node
    }

    private static func makeAmbientLightNode() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .ambient
        light.intensity = 380
        light.color = NSColor(calibratedWhite: 0.82, alpha: 1.0)
        node.light = light
        return node
    }

    private static func makeDirectionalLightNode() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .directional
        light.intensity = 1300
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowRadius = 1.4
        light.shadowSampleCount = 8
        light.shadowMapSize = CGSize(width: 1024, height: 1024)
        light.shadowColor = NSColor.black.withAlphaComponent(0.35)
        node.light = light
        node.position = SCNVector3(18, 35, 14)
        node.eulerAngles = SCNVector3(-0.92, 0.85, 0)
        return node
    }

    private static func makeFillLightNode() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .omni
        light.intensity = 260
        light.color = NSColor(calibratedRed: 0.68, green: 0.77, blue: 1.0, alpha: 1.0)
        node.light = light
        node.position = SCNVector3(-20, 16, -12)
        return node
    }

    private static func makeGroundNode() -> SCNNode {
        let plane = SCNPlane(width: 440, height: 440)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.16, alpha: 1.0)
        material.roughness.contents = 0.92
        material.metalness.contents = 0.10
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, -0.003, 0)
        node.name = "groundPlane"
        return node
    }

    private static func makeGridNode() -> SCNNode {
        let parent = SCNNode()
        parent.name = "gridGuide"

        let half: Float = 96
        let spacing: Float = 6

        for index in stride(from: -half, through: half, by: spacing) {
            let majorLine = abs(index.truncatingRemainder(dividingBy: 24)) < 0.001
            let thickness: CGFloat = majorLine ? 0.09 : 0.04
            let alpha: CGFloat = majorLine ? 0.22 : 0.10

            let xLine = SCNNode(geometry: SCNBox(width: CGFloat(half * 2), height: 0.0004, length: thickness, chamferRadius: 0.0))
            xLine.position = SCNVector3(0, 0, index)
            xLine.geometry?.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(alpha)

            let zLine = SCNNode(geometry: SCNBox(width: thickness, height: 0.0004, length: CGFloat(half * 2), chamferRadius: 0.0))
            zLine.position = SCNVector3(index, 0, 0)
            zLine.geometry?.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(alpha)

            parent.addChildNode(xLine)
            parent.addChildNode(zLine)
        }

        return parent
    }

    private static func makeAxesNode() -> SCNNode {
        let parent = SCNNode()
        parent.name = "axesGuide"
        let length: CGFloat = 8.0
        let radius: CGFloat = 0.03

        let xAxis = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
        xAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.88)
        xAxis.position = SCNVector3(Float(length / 2), 0.05, 0)
        xAxis.eulerAngles = SCNVector3(0, 0, Float.pi / 2)

        let yAxis = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
        yAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.88)
        yAxis.position = SCNVector3(0, Float(length / 2), 0)

        let zAxis = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
        zAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.88)
        zAxis.position = SCNVector3(0, 0.05, Float(length / 2))
        zAxis.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)

        parent.addChildNode(xAxis)
        parent.addChildNode(yAxis)
        parent.addChildNode(zAxis)

        return parent
    }
}
