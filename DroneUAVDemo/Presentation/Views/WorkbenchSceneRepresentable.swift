import AppKit
import SceneKit
import SwiftUI
import simd

/// Interactive workshop viewport. The drone sits on a finite cutting mat,
/// surrounded by a restrained workshop set that matches the simulator's
/// Ground Control UI instead of reading as a glowing CAD void.
struct WorkbenchSceneRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: WorkbenchViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> WorkbenchSCNView {
        let view = WorkbenchSCNView(frame: .zero)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(deviceRed: 0.16, green: 0.16, blue: 0.15, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.coordinator = context.coordinator
        context.coordinator.scnView = view

        let scene = WorkbenchWorkshopSceneFactory.makeScene()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(
            withName: WorkbenchWorkshopSceneFactory.cameraName,
            recursively: false)
        view.defaultCameraController.pointOfView = view.pointOfView
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
        context.coordinator.rebuild(in: scene, fitsCamera: true)
        return view
    }

    func updateNSView(_ nsView: WorkbenchSCNView, context: Context) {
        context.coordinator.viewModel = viewModel
        if let scene = nsView.scene { context.coordinator.syncIfNeeded(in: scene) }
    }

    @MainActor
    final class Coordinator {
        var viewModel: WorkbenchViewModel
        weak var scnView: WorkbenchSCNView?
        private var aircraft: SCNNode?
        private var lastRevision = -1
        private var lastCameraResetToken = -1
        private var lastCategory: WorkbenchCategory?

        init(viewModel: WorkbenchViewModel) { self.viewModel = viewModel }

        func rebuild(in scene: SCNScene, fitsCamera: Bool) {
            aircraft?.removeFromParentNode()
            let node = WorkbenchModelBuilder.aircraftNode(
                for: viewModel.build,
                selectedCategory: viewModel.selectedCategory)
            scene.rootNode.addChildNode(node)
            aircraft = node
            lastRevision = viewModel.build.revision
            lastCategory = viewModel.selectedCategory
            lastCameraResetToken = viewModel.cameraResetToken
            if fitsCamera { fitCamera(to: node, in: scene) }
        }

        func syncIfNeeded(in scene: SCNScene) {
            let changedBuild = viewModel.build.revision != lastRevision
            let changedCategory = viewModel.selectedCategory != lastCategory
            let resetCamera = viewModel.cameraResetToken != lastCameraResetToken
            if changedBuild || changedCategory {
                rebuild(in: scene, fitsCamera: changedBuild || resetCamera)
            } else if resetCamera, let aircraft {
                fitCamera(to: aircraft, in: scene)
                lastCameraResetToken = viewModel.cameraResetToken
            }
        }

        func handleClick(at point: CGPoint) {
            guard let view = scnView else { return }
            let hits = view.hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
            ])
            for hit in hits {
                if let category = category(of: hit.node) {
                    viewModel.selectedCategory = category
                    return
                }
            }
        }

        private func category(of node: SCNNode) -> WorkbenchCategory? {
            var current: SCNNode? = node
            while let candidate = current {
                guard let name = candidate.name else {
                    current = candidate.parent
                    continue
                }
                if name == WorkbenchModelBuilder.frameNodeName
                    || name == WorkbenchModelBuilder.hotspotNodePrefix + "frame" {
                    return .frame
                }
                for prefix in [WorkbenchModelBuilder.slotNodePrefix,
                               WorkbenchModelBuilder.hotspotNodePrefix] where name.hasPrefix(prefix) {
                    let suffix = name.dropFirst(prefix.count)
                    let raw = suffix.split(separator: ".").first.map(String.init) ?? String(suffix)
                    if let kind = WorkbenchComponentKind(rawValue: raw) { return .slot(kind) }
                }
                current = candidate.parent
            }
            return nil
        }

        private func fitCamera(to node: SCNNode, in scene: SCNScene) {
            guard let camera = scene.rootNode.childNode(
                withName: WorkbenchWorkshopSceneFactory.cameraName,
                recursively: false) else { return }
            let bounds = node.boundingBox
            let minimum = SIMD3<Float>(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z))
            let maximum = SIMD3<Float>(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z))
            let center = (minimum + maximum) * Float(0.5)
            let size = maximum - minimum
            let extent = max(size.x, size.z, size.y * 2.8, Float(0.18))
            let target = center + SIMD3<Float>(extent * 0.09, -extent * 0.045, 0)
            camera.simdPosition = center + SIMD3<Float>(extent * 0.84, extent * 0.62, extent * 1.18)
            camera.look(at: SCNVector3(target.x, target.y, target.z))
            scnView?.defaultCameraController.pointOfView = camera
            scnView?.defaultCameraController.automaticTarget = false
            scnView?.defaultCameraController.target = SCNVector3(target.x, target.y, target.z)
        }
    }
}

final class WorkbenchSCNView: SCNView {
    weak var coordinator: WorkbenchSceneRepresentable.Coordinator?
    private var downPoint: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseUp(with: event)
        if hypot(point.x - downPoint.x, point.y - downPoint.y) < 4 {
            coordinator?.handleClick(at: point)
        }
    }
}

enum WorkbenchWorkshopSceneFactory {
    static let cameraName = "workbench.camera"

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor(deviceRed: 0.18, green: 0.18, blue: 0.17, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 0.003
        camera.zFar = 40
        camera.fieldOfView = 34
        camera.wantsHDR = true
        camera.exposureOffset = -0.8
        camera.minimumExposure = -3
        camera.maximumExposure = 1
        camera.averageGray = 0.18
        camera.whitePoint = 1
        camera.bloomIntensity = 0
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0.34, 0.23, 0.40)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        cameraNode.name = cameraName
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(workshopEnvironment())
        addLighting(to: scene)
        return scene
    }

    private static func addLighting(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(deviceRed: 0.76, green: 0.75, blue: 0.71, alpha: 1)
        ambient.light?.intensity = 75
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(deviceRed: 1.0, green: 0.94, blue: 0.84, alpha: 1)
        key.light?.intensity = 300
        key.light?.castsShadow = true
        key.light?.shadowRadius = 5
        key.light?.shadowColor = NSColor.black.withAlphaComponent(0.38)
        key.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.eulerAngles = SCNVector3(-0.82, 0.58, -0.34)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.color = NSColor(deviceRed: 0.76, green: 0.84, blue: 0.94, alpha: 1)
        fill.light?.intensity = 55
        fill.position = SCNVector3(-0.42, 0.30, 0.36)
        scene.rootNode.addChildNode(fill)

        let benchLamp = SCNNode()
        benchLamp.light = SCNLight()
        benchLamp.light?.type = .spot
        benchLamp.light?.color = NSColor(deviceRed: 1.0, green: 0.83, blue: 0.63, alpha: 1)
        benchLamp.light?.intensity = 75
        benchLamp.light?.spotInnerAngle = 34
        benchLamp.light?.spotOuterAngle = 68
        benchLamp.position = SCNVector3(-0.48, 0.44, 0.12)
        benchLamp.look(at: SCNVector3(-0.08, 0, 0))
        scene.rootNode.addChildNode(benchLamp)
    }

    private static func workshopEnvironment() -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.environment"

        let tabletop = SCNBox(width: 1.8, height: 0.07, length: 1.15, chamferRadius: 0.015)
        tabletop.materials = [woodMaterial()]
        let tabletopNode = SCNNode(geometry: tabletop)
        tabletopNode.position = SCNVector3(0, -0.06, -0.02)
        root.addChildNode(tabletopNode)

        let mat = SCNBox(width: 0.68, height: 0.010, length: 0.48, chamferRadius: 0.008)
        mat.materials = [cuttingMatMaterial()]
        let matNode = SCNNode(geometry: mat)
        matNode.name = "workbench.cutting-mat"
        matNode.position = SCNVector3(-0.02, -0.016, 0.01)
        root.addChildNode(matNode)

        let wall = SCNBox(width: 1.75, height: 0.78, length: 0.045, chamferRadius: 0.006)
        wall.materials = [plainMaterial(
            NSColor(deviceRed: 0.25, green: 0.25, blue: 0.24, alpha: 1),
            roughness: 0.94)]
        let wallNode = SCNNode(geometry: wall)
        wallNode.position = SCNVector3(0, 0.31, -0.68)
        root.addChildNode(wallNode)

        let board = SCNBox(width: 1.08, height: 0.47, length: 0.024, chamferRadius: 0.010)
        board.materials = [pegboardMaterial()]
        let boardNode = SCNNode(geometry: board)
        boardNode.position = SCNVector3(-0.08, 0.31, -0.646)
        root.addChildNode(boardNode)

        let shelf = SCNBox(width: 0.66, height: 0.022, length: 0.14, chamferRadius: 0.004)
        shelf.materials = [plainMaterial(
            NSColor(deviceRed: 0.30, green: 0.31, blue: 0.31, alpha: 1),
            metalness: 0.18, roughness: 0.66)]
        let shelfNode = SCNNode(geometry: shelf)
        shelfNode.position = SCNVector3(0.24, 0.105, -0.59)
        root.addChildNode(shelfNode)

        addStorageBins(to: root)
        addWallTools(to: root)
        addBenchLampBody(to: root)
        return root
    }

    private static func addStorageBins(to root: SCNNode) {
        let colors = [
            NSColor(deviceRed: 0.24, green: 0.36, blue: 0.48, alpha: 1),
            NSColor(deviceRed: 0.45, green: 0.34, blue: 0.22, alpha: 1),
            NSColor(deviceRed: 0.29, green: 0.40, blue: 0.34, alpha: 1),
        ]
        for index in 0..<3 {
            let bin = SCNBox(width: 0.15, height: 0.078, length: 0.11, chamferRadius: 0.008)
            bin.materials = [plainMaterial(colors[index], roughness: 0.72)]
            let node = SCNNode(geometry: bin)
            node.position = SCNVector3(0.07 + CGFloat(index) * 0.18, 0.155, -0.57)
            root.addChildNode(node)

            let label = SCNBox(width: 0.065, height: 0.022, length: 0.002, chamferRadius: 0.002)
            label.materials = [plainMaterial(
                NSColor(deviceRed: 0.82, green: 0.80, blue: 0.71, alpha: 1),
                roughness: 0.90)]
            let labelNode = SCNNode(geometry: label)
            labelNode.position = SCNVector3(0.07 + CGFloat(index) * 0.18, 0.152, -0.512)
            root.addChildNode(labelNode)
        }
    }

    private static func addWallTools(to root: SCNNode) {
        let steel = plainMaterial(
            NSColor(deviceRed: 0.66, green: 0.68, blue: 0.69, alpha: 1),
            metalness: 0.62, roughness: 0.34)
        let handle = SCNCapsule(capRadius: 0.012, height: 0.085)
        handle.materials = [plainMaterial(
            NSColor(deviceRed: 0.72, green: 0.31, blue: 0.19, alpha: 1),
            roughness: 0.64)]
        let handleNode = SCNNode(geometry: handle)
        handleNode.position = SCNVector3(-0.36, 0.29, -0.615)
        root.addChildNode(handleNode)

        let shaft = SCNCylinder(radius: 0.003, height: 0.12)
        shaft.materials = [steel]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.position = SCNVector3(-0.36, 0.39, -0.615)
        root.addChildNode(shaftNode)

        let wrenchHandle = SCNBox(width: 0.018, height: 0.15, length: 0.007, chamferRadius: 0.006)
        wrenchHandle.materials = [steel]
        let wrenchNode = SCNNode(geometry: wrenchHandle)
        wrenchNode.position = SCNVector3(-0.20, 0.33, -0.614)
        wrenchNode.eulerAngles.z = -0.12
        root.addChildNode(wrenchNode)

        let wrenchHead = SCNTorus(ringRadius: 0.025, pipeRadius: 0.006)
        wrenchHead.materials = [steel]
        let wrenchHeadNode = SCNNode(geometry: wrenchHead)
        wrenchHeadNode.position = SCNVector3(-0.209, 0.407, -0.614)
        wrenchHeadNode.eulerAngles.x = .pi / 2
        root.addChildNode(wrenchHeadNode)

        for index in 0..<3 {
            let hex = SCNCylinder(radius: 0.018, height: 0.006)
            hex.radialSegmentCount = 6
            hex.materials = [steel]
            let node = SCNNode(geometry: hex)
            node.position = SCNVector3(-0.03 + CGFloat(index) * 0.07, 0.35, -0.615)
            node.eulerAngles.x = .pi / 2
            root.addChildNode(node)
        }
    }

    private static func addBenchLampBody(to root: SCNNode) {
        let darkMetal = plainMaterial(
            NSColor(deviceRed: 0.19, green: 0.20, blue: 0.20, alpha: 1),
            metalness: 0.46, roughness: 0.42)
        let base = SCNCylinder(radius: 0.055, height: 0.015)
        base.materials = [darkMetal]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(-0.53, -0.012, -0.33)
        root.addChildNode(baseNode)

        let lowerArm = beam(from: SIMD3<Float>(-0.53, 0, -0.33),
                            to: SIMD3<Float>(-0.58, 0.23, -0.39),
                            radius: 0.009, material: darkMetal)
        root.addChildNode(lowerArm)
        let upperArm = beam(from: SIMD3<Float>(-0.58, 0.23, -0.39),
                            to: SIMD3<Float>(-0.47, 0.39, -0.30),
                            radius: 0.008, material: darkMetal)
        root.addChildNode(upperArm)

        let shade = SCNCone(topRadius: 0.028, bottomRadius: 0.065, height: 0.09)
        shade.materials = [darkMetal]
        let shadeNode = SCNNode(geometry: shade)
        shadeNode.position = SCNVector3(-0.45, 0.385, -0.275)
        shadeNode.eulerAngles.z = -0.78
        root.addChildNode(shadeNode)
    }

    private static func beam(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) * 0.5
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        return node
    }

    private static func plainMaterial(
        _ color: NSColor,
        metalness: CGFloat = 0.04,
        roughness: CGFloat = 0.78
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.metalness.contents = NSNumber(value: Double(metalness))
        material.roughness.contents = NSNumber(value: Double(roughness))
        return material
    }

    private static func woodMaterial() -> SCNMaterial {
        let material = plainMaterial(
            NSColor(deviceRed: 0.38, green: 0.28, blue: 0.20, alpha: 1),
            roughness: 0.72)
        material.diffuse.contents = woodTexture()
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
        return material
    }

    private static func cuttingMatMaterial() -> SCNMaterial {
        let material = plainMaterial(
            NSColor(deviceRed: 0.20, green: 0.29, blue: 0.26, alpha: 1),
            roughness: 0.86)
        material.diffuse.contents = cuttingMatTexture()
        return material
    }

    private static func pegboardMaterial() -> SCNMaterial {
        let material = plainMaterial(
            NSColor(deviceRed: 0.36, green: 0.31, blue: 0.25, alpha: 1),
            roughness: 0.90)
        material.diffuse.contents = pegboardTexture()
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(6, 3, 1)
        return material
    }

    private static func woodTexture() -> NSImage {
        let size = NSSize(width: 512, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceRed: 0.39, green: 0.29, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        for index in 0..<32 {
            let y = CGFloat(index) * 4 + CGFloat(index % 3)
            let path = NSBezierPath()
            path.lineWidth = index.isMultiple(of: 5) ? 1.4 : 0.65
            path.move(to: NSPoint(x: 0, y: y))
            path.curve(to: NSPoint(x: 512, y: y + CGFloat((index % 5) - 2)),
                       controlPoint1: NSPoint(x: 160, y: y + 5),
                       controlPoint2: NSPoint(x: 360, y: y - 4))
            NSColor(deviceRed: 0.25, green: 0.17, blue: 0.12,
                    alpha: index.isMultiple(of: 5) ? 0.28 : 0.15).setStroke()
            path.stroke()
        }
        image.unlockFocus()
        return image
    }

    private static func cuttingMatTexture() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceRed: 0.20, green: 0.29, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        for index in 0...16 {
            let coordinate = CGFloat(index) * 32
            let path = NSBezierPath()
            path.lineWidth = index.isMultiple(of: 4) ? 1.15 : 0.55
            path.move(to: NSPoint(x: coordinate, y: 0))
            path.line(to: NSPoint(x: coordinate, y: 512))
            path.move(to: NSPoint(x: 0, y: coordinate))
            path.line(to: NSPoint(x: 512, y: coordinate))
            NSColor(deviceWhite: 0.88,
                    alpha: index.isMultiple(of: 4) ? 0.24 : 0.11).setStroke()
            path.stroke()
        }
        image.unlockFocus()
        return image
    }

    private static func pegboardTexture() -> NSImage {
        let size = NSSize(width: 96, height: 96)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceRed: 0.36, green: 0.31, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(deviceWhite: 0.08, alpha: 0.82).setFill()
        for x in stride(from: 12, through: 84, by: 18) {
            for y in stride(from: 12, through: 84, by: 18) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 4, height: 4)).fill()
            }
        }
        image.unlockFocus()
        return image
    }
}

/// Live 3D thumbnails share the same component factory as the assembled UAV,
/// but use deterministic neutral product lighting for readable silhouettes.
struct WorkbenchPartPreview: NSViewRepresentable {
    var frame: WorkbenchFrameSpec?
    var component: WorkbenchComponentSpec?

    init(frame: WorkbenchFrameSpec) {
        self.frame = frame
        component = nil
    }

    init(component: WorkbenchComponentSpec) {
        frame = nil
        self.component = component
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.scene = thumbnailScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: "preview.camera", recursively: false)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = thumbnailScene()
        nsView.pointOfView = nsView.scene?.rootNode.childNode(withName: "preview.camera", recursively: false)
    }

    private func thumbnailScene() -> SCNScene {
        let scene = SCNScene()
        let model = frame.map { WorkbenchModelBuilder.previewNode(for: $0) }
            ?? component.map { WorkbenchModelBuilder.previewNode(for: $0) }
            ?? SCNNode()
        prepareMaterialsForPreview(in: model)
        scene.rootNode.addChildNode(model)

        let bounds = model.boundingBox
        let lo = SIMD3<Float>(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z))
        let hi = SIMD3<Float>(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z))
        let center = (lo + hi) * Float(0.5)
        let extent = max(simd_length(hi - lo), Float(0.025))

        let camera = SCNCamera()
        camera.fieldOfView = 31
        camera.zNear = 0.001
        camera.zFar = 20
        camera.wantsHDR = false
        camera.bloomIntensity = 0
        let cameraNode = SCNNode()
        cameraNode.name = "preview.camera"
        cameraNode.camera = camera
        cameraNode.simdPosition = center + SIMD3<Float>(extent * 0.70, extent * 0.48, extent * 1.03)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(deviceWhite: 0.86, alpha: 1)
        ambient.light?.intensity = 90
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(deviceRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
        key.light?.intensity = 260
        key.eulerAngles = SCNVector3(-0.72, 0.48, -0.30)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.color = NSColor(deviceRed: 0.82, green: 0.84, blue: 0.86, alpha: 1)
        fill.light?.intensity = 45
        fill.simdPosition = center + SIMD3<Float>(-extent, extent * 0.4, extent * 0.7)
        scene.rootNode.addChildNode(fill)
        return scene
    }

    private func prepareMaterialsForPreview(in node: SCNNode) {
        func prepare(_ geometry: SCNGeometry?) {
            geometry?.materials.forEach { material in
                // Card previews must not inherit the exposure-sensitive PBR setup
                // used by the full workshop scene. Blinn keeps catalogue colours
                // stable even when the window or card size changes.
                material.lightingModel = .blinn
                material.emission.contents = NSColor.black
                material.multiply.contents = NSColor.white
                material.specular.contents = NSColor(deviceWhite: 0.30, alpha: 1)
                material.shininess = 0.22
            }
        }

        prepare(node.geometry)
        node.enumerateChildNodes { child, _ in
            prepare(child.geometry)
        }
    }
}
