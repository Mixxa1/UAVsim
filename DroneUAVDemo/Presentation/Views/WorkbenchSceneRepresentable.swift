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
        let cameraController = view.defaultCameraController
        cameraController.pointOfView = view.pointOfView
        cameraController.interactionMode = .orbitTurntable
        cameraController.automaticTarget = false
        cameraController.target = SCNVector3(0, 0, 0)
        cameraController.worldUp = SCNVector3(0, 1, 0)
        cameraController.inertiaEnabled = true
        cameraController.inertiaFriction = 0.12
        // A generous front-workshop orbit: enough to inspect every side of the
        // aircraft without crossing behind the scenery or underneath the bench.
        cameraController.minimumHorizontalAngle = -65
        cameraController.maximumHorizontalAngle = 65
        cameraController.minimumVerticalAngle = 8
        cameraController.maximumVerticalAngle = 68
        context.coordinator.rebuild(in: scene, fitsCamera: true)
        // `allowsCameraControl` performs its own controller setup when the view is
        // attached to a window. Re-apply the aircraft framing on the next run-loop
        // turn so a large environment asset can never become the framing target.
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let scene = view.scene else { return }
            coordinator?.refitCamera(in: scene)
        }
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
        private var cameraOrbitTarget = SIMD3<Float>.zero
        private var minimumCameraDistance: Float = 0.34
        private var maximumCameraDistance: Float = 1.05

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

        func refitCamera(in scene: SCNScene) {
            guard let aircraft else { return }
            fitCamera(to: aircraft, in: scene)
        }

        func zoomCamera(byLogScale logScale: Float) {
            guard let view = scnView,
                  let camera = view.scene?.rootNode.childNode(
                    withName: WorkbenchWorkshopSceneFactory.cameraName,
                    recursively: false) else { return }

            var offset = camera.simdPosition - cameraOrbitTarget
            let distance = simd_length(offset)
            guard distance > 0.001 else { return }
            // A multiplicative dolly feels consistent at every distance. Clamp
            // each event as well as the final radius, so a high-resolution wheel
            // can never jump through the target and emerge behind the scenery.
            let safeLogScale = min(max(logScale, -0.30), 0.30)
            let proposedDistance = distance * exp(safeLogScale)
            let clampedDistance = min(
                max(proposedDistance, minimumCameraDistance),
                maximumCameraDistance)
            guard abs(clampedDistance - distance) > 0.0001 else { return }
            offset *= clampedDistance / distance
            camera.simdPosition = cameraOrbitTarget + offset
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
            cameraOrbitTarget = target
            minimumCameraDistance = max(extent * 1.0, 0.34)
            maximumCameraDistance = min(max(extent * 2.25, 0.86), 1.02)
            let initialDistance = min(max(extent * 1.9, 0.78), maximumCameraDistance)
            let viewingDirection = simd_normalize(SIMD3<Float>(0.84, 0.62, 1.18))
            camera.simdPosition = target + viewingDirection * initialDistance
            camera.look(at: SCNVector3(target.x, target.y, target.z))
            scnView?.pointOfView = camera
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

    override func scrollWheel(with event: NSEvent) {
        // Do not call SceneKit's unbounded dolly: a large wheel delta can cross
        // the orbit target in one frame and place the camera behind the room.
        coordinator?.zoomCamera(byLogScale: -Float(event.scrollingDeltaY) * 0.025)
    }

    override func magnify(with event: NSEvent) {
        coordinator?.zoomCamera(byLogScale: -Float(event.magnification) * 1.2)
    }

    // Keep the editor centred on the aircraft. Left-drag/trackpad orbit remains
    // available, while secondary-button panning cannot move the target outside
    // the finite workshop set.
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
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
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -1.65
        camera.minimumExposure = -3
        camera.maximumExposure = 0
        camera.averageGray = 0.18
        // Preserve headroom in white workshop materials. At 1.0 SceneKit clips
        // the pegboard and tape atlas to display white before their surface
        // texture and soft shadows can remain visible.
        camera.whitePoint = 2.0
        camera.screenSpaceAmbientOcclusionIntensity = 0.75
        camera.screenSpaceAmbientOcclusionRadius = 0.035
        camera.screenSpaceAmbientOcclusionBias = 0.002
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.18
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
        ambient.light?.intensity = 22
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(deviceRed: 1.0, green: 0.94, blue: 0.84, alpha: 1)
        key.light?.intensity = 72
        key.light?.castsShadow = true
        key.light?.shadowRadius = 9
        key.light?.shadowColor = NSColor.black.withAlphaComponent(0.24)
        key.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.eulerAngles = SCNVector3(-0.82, 0.58, -0.34)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.color = NSColor(deviceRed: 0.76, green: 0.84, blue: 0.94, alpha: 1)
        fill.light?.intensity = 10
        fill.position = SCNVector3(-0.42, 0.30, 0.36)
        scene.rootNode.addChildNode(fill)

        // No local spotlight: the supplied workbench albedo already contains
        // worn bright patches, and a spot source turned them into hard hotspots.
    }

    private static func workshopEnvironment() -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.environment"

        let assetWorkbench = makeWorkbenchAssetNode()
        if let assetWorkbench {
            root.addChildNode(assetWorkbench)
        } else {
            // Keep the editor usable when an app bundle is incomplete or a resource
            // cannot be decoded on an older macOS version.
            let tabletop = SCNBox(width: 1.8, height: 0.07, length: 1.15, chamferRadius: 0.015)
            tabletop.materials = [woodMaterial()]
            let tabletopNode = SCNNode(geometry: tabletop)
            tabletopNode.position = SCNVector3(0, -0.06, -0.02)
            root.addChildNode(tabletopNode)
        }

        let mat = SCNBox(width: 1.16, height: 0.004, length: 0.34, chamferRadius: 0.006)
        mat.materials = [cuttingMatMaterial()]
        let matNode = SCNNode(geometry: mat)
        matNode.name = "workbench.cutting-mat"
        // The imported tabletop is at y = -0.012 in normalized scene space.
        // A 2 mm clearance prevents z-fighting/occlusion, while the inset Z
        // dimensions keep the mat inside both the front and rear table edges.
        matNode.position = SCNVector3(-0.06, -0.008, -0.02)
        root.addChildNode(matNode)

        addRoomBackdrop(to: root)

        if assetWorkbench == nil {
            // The imported model already contains its own pegboard, shelves,
            // cabinets and tools. These procedural props only belong to the
            // lightweight fallback; rendering both creates a duplicated workshop.
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
        }
        return root
    }

    /// Three-sided room shell plus a textured floor. It is deliberately larger
    /// than the visible camera frustum so constrained orbiting never reveals the
    /// empty SceneKit background around the workshop asset.
    private static func addRoomBackdrop(to root: SCNNode) {
        let brick = brickWallMaterial()

        let backWall = SCNPlane(width: 3.4, height: 2.0)
        backWall.materials = [brick]
        let backNode = SCNNode(geometry: backWall)
        backNode.name = "workbench.brick-background"
        backNode.position = SCNVector3(0, 0.05, -0.26)
        root.addChildNode(backNode)

        let sideDepth: CGFloat = 1.82
        let leftWall = SCNPlane(width: sideDepth, height: 2.0)
        leftWall.materials = [brick]
        let leftNode = SCNNode(geometry: leftWall)
        leftNode.name = "workbench.brick-wall.left"
        leftNode.position = SCNVector3(-1.70, 0.05, 0.65)
        leftNode.eulerAngles.y = .pi / 2
        root.addChildNode(leftNode)

        let rightWall = SCNPlane(width: sideDepth, height: 2.0)
        rightWall.materials = [brick]
        let rightNode = SCNNode(geometry: rightWall)
        rightNode.name = "workbench.brick-wall.right"
        rightNode.position = SCNVector3(1.70, 0.05, 0.65)
        rightNode.eulerAngles.y = -.pi / 2
        root.addChildNode(rightNode)

        let floor = SCNPlane(width: 3.4, height: sideDepth)
        let floorMaterial = woodMaterial()
        floorMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(6, 4, 1)
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "workbench.floor"
        floorNode.position = SCNVector3(0, -0.60, 0.65)
        floorNode.eulerAngles.x = -.pi / 2
        root.addChildNode(floorNode)
    }

    /// Loads the attributed Sketchfab workbench and aligns its actual work surface
    /// with the procedural cutting mat. The source mesh uses centimetre-like units
    /// and contains legs below the work surface plus a raised rear section, so
    /// centring the complete bounding box on Y would make the UAV float.
    private static func makeWorkbenchAssetNode() -> SCNNode? {
        guard let url = Bundle.main.url(forResource: "Workbench", withExtension: "usdz"),
              let assetScene = try? SCNScene(url: url, options: nil) else {
            #if DEBUG
            print("[Workbench] Workbench.usdz unavailable; using procedural table")
            #endif
            return nil
        }

        let content = SCNNode()
        for child in assetScene.rootNode.childNodes {
            content.addChildNode(child.clone())
        }

        let bounds = content.boundingBox
        let nativeWidth = Float(bounds.max.x - bounds.min.x)
        let nativeHeight = Float(bounds.max.y - bounds.min.y)
        guard nativeWidth > 0.001, nativeHeight > 0.001 else { return nil }

        let centerX = Float(bounds.min.x + bounds.max.x) * 0.5
        let centerZ = Float(bounds.min.z + bounds.max.z) * 0.5
        // Measured from the supplied asset: the broad bench top is 53.6% up
        // the complete model bounds (the remainder is legs and the rear riser).
        let workSurfaceY = Float(bounds.min.y) + nativeHeight * 0.536
        content.simdPosition = SIMD3<Float>(-centerX, -workSurfaceY, -centerZ)

        let wrapper = SCNNode()
        wrapper.name = "workbench.environment.asset"
        wrapper.addChildNode(content)
        let scale = Float(2.10) / nativeWidth
        wrapper.simdScale = SIMD3<Float>(repeating: scale)
        // The source asset contains a raised red tool chest near its centre.
        // Shifting the furniture (not the aircraft) keeps the UAV on the broad
        // worktop while moving that chest clear of the cutting mat. Moving the
        // model slightly rearward also seats its pegboard against the brick wall.
        wrapper.simdPosition = SIMD3<Float>(0.34, -0.025, -0.02)

        // The Sketchfab asset includes three loose fasteners on the centre of
        // the tabletop. They read as broken UAV parts once the cutting mat is
        // added. Remove only disconnected mesh islands fully contained in that
        // narrow work-area volume; broad tabletop faces and the tool chest can
        // never satisfy this test and therefore remain untouched.
        removeLooseTabletopParts(from: wrapper)

        var tonedAlbedo: CGImage?
        wrapper.enumerateChildNodes { node, _ in
            node.castsShadow = true
            node.geometry?.materials.forEach { material in
                if tonedAlbedo == nil {
                    tonedAlbedo = highlightCompressedImage(from: material.diffuse.contents)
                }
                if let tonedAlbedo {
                    material.diffuse.contents = tonedAlbedo
                }
                // Keep PBR's readable diffuse response at the deliberately soft
                // light levels, but flatten the reflective lobe responsible for
                // angle-dependent white hotspots in the source material.
                material.lightingModel = .physicallyBased
                material.emission.contents = NSColor.black
                material.specular.contents = NSColor.black
                material.reflective.contents = NSColor.black
                material.metalness.contents = NSNumber(value: 0.0)
                material.roughness.contents = NSNumber(value: 1.0)
                material.clearCoat.contents = NSNumber(value: 0.0)
                material.diffuse.intensity = 0.48
                material.normal.intensity = 0.82
                material.readsFromDepthBuffer = true
                material.writesToDepthBuffer = true
            }
        }
        return wrapper
    }

    private struct MeshIslandBounds {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        mutating func include(_ point: SIMD3<Float>) {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }

        func isContained(between lower: SIMD3<Float>, and upper: SIMD3<Float>) -> Bool {
            minimum.x >= lower.x && minimum.y >= lower.y && minimum.z >= lower.z
                && maximum.x <= upper.x && maximum.y <= upper.y && maximum.z <= upper.z
        }
    }

    private final class MeshIslandSet {
        private var parents: [Int]

        init(count: Int) {
            parents = Array(0..<count)
        }

        func root(of index: Int) -> Int {
            var root = index
            while parents[root] != root {
                root = parents[root]
            }

            var current = index
            while parents[current] != current {
                let next = parents[current]
                parents[current] = root
                current = next
            }
            return root
        }

        func join(_ first: Int, _ second: Int) {
            let firstRoot = root(of: first)
            let secondRoot = root(of: second)
            if firstRoot != secondRoot {
                parents[secondRoot] = firstRoot
            }
        }
    }

    private static func removeLooseTabletopParts(from wrapper: SCNNode) {
        let cleanupVolumes: [(minimum: SIMD3<Float>, maximum: SIMD3<Float>)] = [
            (
                SIMD3<Float>(-0.365, -0.013, -0.023),
                SIMD3<Float>(-0.310, 0.008, 0.018)),
            (
                SIMD3<Float>(-0.245, -0.013, -0.031),
                SIMD3<Float>(-0.219, -0.003, 0.005)),
            (
                SIMD3<Float>(-0.192, -0.013, -0.024),
                SIMD3<Float>(-0.159, -0.003, 0.006)),
        ]

        wrapper.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry,
                  let vertexSource = geometry.sources(for: .vertex).first,
                  vertexSource.usesFloatComponents,
                  vertexSource.componentsPerVector >= 3,
                  [4, 8].contains(vertexSource.bytesPerComponent) else { return }

            let worldVertices = (0..<vertexSource.vectorCount).map { index in
                node.simdConvertPosition(vertex(at: index, in: vertexSource), to: nil)
            }
            var filteredElements: [SCNGeometryElement] = []
            var changedGeometry = false

            for element in geometry.elements {
                guard element.primitiveType == .triangles,
                      [1, 2, 4].contains(element.bytesPerIndex) else {
                    filteredElements.append(element)
                    continue
                }

                let indexCount = element.primitiveCount * 3
                let indices = (0..<indexCount).map { index in
                    geometryIndex(
                        in: element.data,
                        at: index * element.bytesPerIndex,
                        byteCount: element.bytesPerIndex)
                }
                guard indices.allSatisfy({ worldVertices.indices.contains($0) }) else {
                    filteredElements.append(element)
                    continue
                }

                let islands = MeshIslandSet(count: vertexSource.vectorCount)
                for corner in stride(from: 0, to: indexCount, by: 3) {
                    islands.join(indices[corner], indices[corner + 1])
                    islands.join(indices[corner], indices[corner + 2])
                }

                var islandBounds: [Int: MeshIslandBounds] = [:]
                for index in Set(indices) {
                    let root = islands.root(of: index)
                    islandBounds[root, default: MeshIslandBounds()].include(worldVertices[index])
                }
                let removableIslands = Set(islandBounds.compactMap { root, bounds in
                    cleanupVolumes.contains { volume in
                        bounds.isContained(between: volume.minimum, and: volume.maximum)
                    }
                        ? root
                        : nil
                })
                guard !removableIslands.isEmpty else {
                    filteredElements.append(element)
                    continue
                }

                var filteredData = Data()
                let bytesPerTriangle = element.bytesPerIndex * 3
                filteredData.reserveCapacity(element.data.count)
                var keptTriangleCount = 0
                for triangle in 0..<element.primitiveCount {
                    let firstCorner = triangle * 3
                    let island = islands.root(of: indices[firstCorner])
                    guard !removableIslands.contains(island) else { continue }
                    let byteOffset = triangle * bytesPerTriangle
                    filteredData.append(
                        element.data.subdata(in: byteOffset..<(byteOffset + bytesPerTriangle)))
                    keptTriangleCount += 1
                }

                let filteredElement = SCNGeometryElement(
                    data: filteredData,
                    primitiveType: .triangles,
                    primitiveCount: keptTriangleCount,
                    bytesPerIndex: element.bytesPerIndex)
                filteredElements.append(filteredElement)
                changedGeometry = true
            }

            guard changedGeometry else { return }
            let filteredGeometry = SCNGeometry(
                sources: geometry.sources,
                elements: filteredElements)
            filteredGeometry.name = geometry.name
            filteredGeometry.materials = geometry.materials
            filteredGeometry.subdivisionLevel = geometry.subdivisionLevel
            filteredGeometry.wantsAdaptiveSubdivision = geometry.wantsAdaptiveSubdivision
            filteredGeometry.tessellator = geometry.tessellator
            node.geometry = filteredGeometry
        }
    }

    private static func vertex(
        at index: Int,
        in source: SCNGeometrySource
    ) -> SIMD3<Float> {
        let offset = source.dataOffset + index * source.dataStride
        return source.data.withUnsafeBytes { rawBuffer in
            if source.bytesPerComponent == 4 {
                return SIMD3<Float>(
                    rawBuffer.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    rawBuffer.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                    rawBuffer.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
            }
            return SIMD3<Float>(
                Float(rawBuffer.loadUnaligned(fromByteOffset: offset, as: Double.self)),
                Float(rawBuffer.loadUnaligned(fromByteOffset: offset + 8, as: Double.self)),
                Float(rawBuffer.loadUnaligned(fromByteOffset: offset + 16, as: Double.self)))
        }
    }

    private static func geometryIndex(
        in data: Data,
        at offset: Int,
        byteCount: Int
    ) -> Int {
        var value: UInt32 = 0
        for byte in 0..<byteCount {
            value |= UInt32(data[data.startIndex + offset + byte]) << UInt32(byte * 8)
        }
        return Int(value)
    }

    /// Sketchfab exposes images embedded in USDZ as a file URL plus byte range.
    /// Decode that atlas once and gently clamp only its brightest pixels. Unlike
    /// a geometry overlay this follows every pegboard hole and tool silhouette,
    /// so the board cannot turn into a uniformly glowing rectangle.
    private static func highlightCompressedImage(from contents: Any?) -> CGImage? {
        guard let embeddedURL = contents as? URL,
              let components = URLComponents(
                url: embeddedURL,
                resolvingAgainstBaseURL: false),
              let offsetText = components.queryItems?.first(where: { $0.name == "offset" })?.value,
              let sizeText = components.queryItems?.first(where: { $0.name == "size" })?.value,
              let offset = Int(offsetText),
              let size = Int(sizeText),
              offset >= 0,
              size > 0,
              let archive = try? Data(
                contentsOf: URL(fileURLWithPath: embeddedURL.path),
                options: .mappedIfSafe),
              offset + size <= archive.count else { return nil }

        let imageData = archive.subdata(in: offset..<(offset + size))
        guard let bitmap = NSBitmapImageRep(data: imageData),
              !bitmap.isPlanar,
              bitmap.bitsPerSample == 8,
              bitmap.bitsPerPixel >= 24,
              let pixels = bitmap.bitmapData else { return nil }

        let bytesPerPixel = bitmap.bitsPerPixel / 8
        for y in 0..<bitmap.pixelsHigh {
            let row = pixels.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<bitmap.pixelsWide {
                let pixel = row.advanced(by: x * bytesPerPixel)
                let red = Float(pixel[0]) / 255
                let green = Float(pixel[1]) / 255
                let blue = Float(pixel[2]) / 255
                let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
                guard luminance > 0.58 else { continue }

                // Smoothly roll highlights down by at most 38%, preserving hue
                // and all mid-tone wood/metal detail in the shared atlas.
                let linearAmount = min((luminance - 0.58) / 0.42, 1)
                let smoothAmount = linearAmount * linearAmount * (3 - 2 * linearAmount)
                let scale = 1 - 0.38 * smoothAmount
                pixel[0] = UInt8(min(red * scale * 255, 255))
                pixel[1] = UInt8(min(green * scale * 255, 255))
                pixel[2] = UInt8(min(blue * scale * 255, 255))
            }
        }
        return bitmap.cgImage
    }

    /// Reuses every available PBR channel embedded in Brick_Material.usdz and
    /// retargets it to the workshop wall. Its geometry is intentionally ignored.
    private static func brickWallMaterial() -> SCNMaterial {
        guard let url = Bundle.main.url(forResource: "Brick_Material", withExtension: "usdz"),
              let materialScene = try? SCNScene(url: url, options: nil),
              let source = firstMaterial(in: materialScene.rootNode),
              let material = source.copy() as? SCNMaterial else {
            #if DEBUG
            print("[Workbench] Brick_Material.usdz unavailable; using fallback wall material")
            #endif
            return plainMaterial(
                NSColor(deviceRed: 0.34, green: 0.22, blue: 0.17, alpha: 1),
                roughness: 0.92)
        }

        material.name = "workbench.brick-wall"
        material.lightingModel = .physicallyBased
        material.emission.contents = NSColor.black
        material.specular.contents = NSColor.black
        material.reflective.contents = NSColor.black
        material.metalness.contents = NSNumber(value: 0.0)
        material.roughness.contents = NSNumber(value: 1.0)
        material.clearCoat.contents = NSNumber(value: 0.0)
        material.diffuse.intensity = 0.50
        material.isDoubleSided = false
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true

        let tiledProperties = [
            material.diffuse,
            material.normal,
            material.roughness,
            material.metalness,
            material.ambientOcclusion,
        ]
        for property in tiledProperties {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.contentsTransform = SCNMatrix4MakeScale(3.2, 1.8, 1)
        }
        material.normal.intensity = 0.72
        return material
    }

    private static func firstMaterial(in node: SCNNode) -> SCNMaterial? {
        if let material = node.geometry?.materials.first { return material }
        for child in node.childNodes {
            if let material = firstMaterial(in: child) { return material }
        }
        return nil
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
        material.diffuse.intensity = 0.62
        material.metalness.contents = NSNumber(value: 0.0)
        material.roughness.contents = NSNumber(value: 1.0)
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
