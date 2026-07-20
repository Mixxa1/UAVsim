import SceneKit
import simd

/// Assembles an imported world into a SceneKit node tree.
///
/// Kept free of any dependency on the simulation's own scene controller: this produces a plain
/// subtree that the preview window can show today and the flight scene can adopt later, without
/// the two sharing state. That separation is what allows the real-city geometry to be built and
/// inspected before anything in the flight path is touched.
enum UAVWorldSceneAssembler {

    static let rootNodeName = "world.imported.root"

    struct AssemblyStatistics {
        var buildingNodes = 0
        var skippedGeometryFailures = 0
        var triangles = 0
        var collisionTriangles = 0
        /// Extent of the assembled geometry in local metres, for framing the camera.
        var minimum = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var tallestMeters: Float = 0

        var spanMeters: Float {
            guard minimum.x < maximum.x else { return 1000 }
            return max(maximum.x - minimum.x, maximum.y - minimum.y)
        }
    }

    struct Assembly {
        let root: SCNNode
        let statistics: AssemblyStatistics
    }

    /// Builds the node tree. `includeCollisionProxies` attaches static physics bodies; the
    /// preview leaves them off, since nothing there needs to collide and skipping them keeps
    /// assembly of a five-hundred-building world instant.
    static func assemble(
        buildings: [UAVWorldBuilding],
        includeCollisionProxies: Bool = false
    ) -> Assembly {
        let root = SCNNode()
        root.name = rootNodeName

        var statistics = AssemblyStatistics()

        // One node per building, grouped by facade class so SceneKit sees runs of identical
        // materials. Buildings of a class share a single cached material instance, which is
        // what keeps a whole city down to a handful of texture bindings.
        var classContainers: [UAVWorldFacadeClass: SCNNode] = [:]

        for building in buildings {
            guard let geometry = UAVWorldBuildingGeometryFactory.makeGeometry(for: building) else {
                statistics.skippedGeometryFailures += 1
                continue
            }

            geometry.materials = UAVWorldFacadeMaterialFactory.materials(for: building.facadeClass)

            let node = SCNNode(geometry: geometry)
            let centroid = building.centroid
            node.simdPosition = SIMD3<Float>(centroid.x, 0, centroid.y)
            node.name = "world.building.\(building.provenance.featureIdentifier)"

            // Buildings never move, so let SceneKit bake and cull them aggressively.
            node.castsShadow = true

            if includeCollisionProxies {
                let triangles = UAVWorldBuildingGeometryFactory.makeCollisionTriangles(for: building)
                statistics.collisionTriangles += triangles.count
            }

            let container: SCNNode
            if let existing = classContainers[building.facadeClass] {
                container = existing
            } else {
                let created = SCNNode()
                created.name = "world.class.\(building.facadeClass.rawValue)"
                root.addChildNode(created)
                classContainers[building.facadeClass] = created
                container = created
            }
            container.addChildNode(node)

            statistics.buildingNodes += 1
            for element in geometry.elements {
                statistics.triangles += element.primitiveCount
            }

            let bounds = building.planarBounds
            statistics.minimum = simd_min(statistics.minimum, bounds.minimum)
            statistics.maximum = simd_max(statistics.maximum, bounds.maximum)
            statistics.tallestMeters = max(statistics.tallestMeters, building.totalHeightMeters)
        }

        return Assembly(root: root, statistics: statistics)
    }

    /// Sun light configured for a city-scale scene.
    ///
    /// The settings here are not defaults-with-taste; they are the fix for a specific failure.
    /// A directional light covering a 1.2 km city at SceneKit's default shadow-map size works
    /// out to roughly 0.6 m per shadow texel, and against 300 m towers that is far too coarse:
    /// whole facades self-shadow and render **pure black**. The first render of this city showed
    /// exactly that, and it was misdiagnosed as missing ambient light until rendering with
    /// shadows disabled proved the geometry and materials were fine all along.
    ///
    /// Three things together make it correct: a large shadow map, cascades so near geometry gets
    /// a much finer slice than distant geometry, and a depth bias sized for the scene rather
    /// than left at a default tuned for room-scale content.
    static func makeSunNode(spanMeters: Float) -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.intensity = 950
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowMapSize = CGSize(width: 4096, height: 4096)
        light.shadowCascadeCount = 4
        light.shadowCascadeSplittingFactor = 0.4
        light.shadowSampleCount = 16
        light.shadowRadius = 3.0
        // Acne scales with how much world each texel covers, so the bias has to scale with the
        // scene rather than being a constant.
        light.shadowBias = Double(max(spanMeters, 100) * 0.004)
        light.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.55)
        light.orthographicScale = Double(max(spanMeters * 0.62, 100))
        light.zNear = 1.0
        light.zFar = Double(spanMeters * 3 + 1200)
        light.maximumShadowDistance = CGFloat(spanMeters * 1.4)

        let node = SCNNode()
        node.light = light
        node.name = "world.sun"
        node.eulerAngles = SCNVector3(-Double.pi / 3.2, Double.pi / 4.5, 0)
        return node
    }

    /// Equirectangular sky/ground gradient for `SCNScene.lightingEnvironment`.
    ///
    /// Required, not decorative. With `.physicallyBased` materials SceneKit takes its ambient
    /// term from the lighting environment, and an `SCNLight` of type `.ambient` contributes
    /// almost nothing — so a scene lit only by a directional sun renders every shadowed facade
    /// **pure black**, which is exactly what the first render of this city showed. Supplying an
    /// environment is what makes a wall facing away from the sun read as being in shade rather
    /// than as a hole in the world.
    ///
    /// The vertical gradient also makes the ambient directional: brighter from the sky above,
    /// darker from the ground below, which is how real diffuse skylight behaves.
    static func makeSkyEnvironment() -> NSImage {
        let width = 256
        let height = 128
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }

        let zenith = NSColor(calibratedRed: 0.52, green: 0.62, blue: 0.78, alpha: 1)
        let horizon = NSColor(calibratedRed: 0.68, green: 0.71, blue: 0.74, alpha: 1)
        let ground = NSColor(calibratedRed: 0.24, green: 0.23, blue: 0.22, alpha: 1)

        // Equirectangular: v = 0 is the bottom of the sphere, v = 1 the top. Drawing bottom-up
        // in Core Graphics coordinates matches that directly.
        if let gradient = NSGradient(
            colors: [ground, ground, horizon, zenith],
            atLocations: [0.0, 0.42, 0.52, 1.0],
            colorSpace: .deviceRGB
        ) {
            gradient.draw(
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                angle: 90
            )
        } else {
            horizon.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }

        return image
    }

    /// Flat ground sized to the assembled extent. A placeholder until a real elevation layer
    /// exists — named so, because a ground plane that silently pretends to be terrain is exactly
    /// the sort of thing that gets mistaken for finished work.
    static func makePlaceholderGround(spanMeters: Float) -> SCNNode {
        let side = CGFloat(max(spanMeters * 1.6, 200))
        let plane = SCNPlane(width: side, height: side)

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.21, alpha: 1)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.name = "world.ground.placeholder"
        node.eulerAngles.x = -.pi / 2
        node.position.y = -0.05
        return node
    }
}
