import Foundation
import AppKit
import SceneKit
import simd

private struct AbandonedCityBuildingTemplate {
    let kind: AbandonedCityBuildingKind
    let templateNode: SCNNode
    let sourceMinimum: SCNVector3
    let sourceBounds: SCNVector3
    let sourceGroundY: Float
    let sourceTriangleBounds: [AbandonedCitySourceTriangleBounds]
}

private struct AbandonedCitySourceTriangleBounds {
    let point0: SIMD3<Float>
    let point1: SIMD3<Float>
    let point2: SIMD3<Float>
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let normal: SIMD3<Float>
    let role: BuildingColliderRole
    let sourceName: String
}

private enum AbandonedCitySurfaceAxis: String, Hashable, Comparable {
    case horizontal
    case thinX
    case thinZ

    static func < (lhs: AbandonedCitySurfaceAxis, rhs: AbandonedCitySurfaceAxis) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct AbandonedCitySupportSurfaceKey: Hashable, Comparable {
    let x: Int
    let z: Int
    let y: Int
    let normalX: Int
    let normalY: Int
    let normalZ: Int
    let role: BuildingColliderRole

    static func < (lhs: AbandonedCitySupportSurfaceKey, rhs: AbandonedCitySupportSurfaceKey) -> Bool {
        if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.z != rhs.z { return lhs.z < rhs.z }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.normalX != rhs.normalX { return lhs.normalX < rhs.normalX }
        if lhs.normalY != rhs.normalY { return lhs.normalY < rhs.normalY }
        return lhs.normalZ < rhs.normalZ
    }
}

private struct AbandonedCitySupportSurfaceCandidate {
    let key: AbandonedCitySupportSurfaceKey
    let localCenter: SIMD3<Float>
    let halfExtents: SIMD2<Float>
    let normal: SIMD3<Float>
}

final class AbandonedCityBuildingLoader {
    static let shared = AbandonedCityBuildingLoader()

    private var templates: [AbandonedCityBuildingKind: AbandonedCityBuildingTemplate] = [:]
    private var attemptedKinds: Set<AbandonedCityBuildingKind> = []
    private var warnedKinds: Set<AbandonedCityBuildingKind> = []

    private init() {}

    func isAvailable(_ kind: AbandonedCityBuildingKind) -> Bool {
        template(for: kind) != nil
    }

    func normalizedSize(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float
    ) -> SIMD3<Float>? {
        guard let template = template(for: kind) else {
            return nil
        }
        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        return SIMD3<Float>(
            Float(template.sourceBounds.x) * scale,
            Float(template.sourceBounds.y) * scale,
            Float(template.sourceBounds.z) * scale
        )
    }

    func makeBuildingNode(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float,
        yaw: Float
    ) -> SCNNode? {
        guard let template = template(for: kind) else {
            return nil
        }

        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        let visual = template.templateNode.clone()
        let sceneScale = CGFloat(scale)
        visual.scale = SCNVector3(sceneScale, sceneScale, sceneScale)
        visual.position = SCNVector3(
            -((template.sourceMinimum.x + template.sourceBounds.x * 0.5) * sceneScale),
            -(CGFloat(template.sourceGroundY) * sceneScale) - CGFloat(asset.groundSinkMeters),
            -((template.sourceMinimum.z + template.sourceBounds.z * 0.5) * sceneScale)
        )

        let root = SCNNode()
        root.name = "environment.abandonedCity.visual.\(kind.rawValue)"
        root.eulerAngles.y = CGFloat(yaw)
        root.addChildNode(visual)

        #if DEBUG
        print(
            "[AbandonedCity] normalized \(kind.rawValue) " +
            "sourceHeight=\(formatted(Float(template.sourceBounds.y))) " +
            "targetHeight=\(formatted(targetHeightMeters)) " +
            "scale=\(formatted(scale))"
        )
        #endif

        return root
    }

    func supportSurfaceParts(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float
    ) -> [EnvironmentSupportSurfacePart] {
        guard let template = template(for: kind) else {
            return []
        }
        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        return makeSupportSurfaceParts(
            triangles: template.sourceTriangleBounds,
            scale: scale,
            groundSinkMeters: asset.groundSinkMeters
        )
    }

    func collisionMeshParts(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float
    ) -> [EnvironmentCollisionMeshPart] {
        guard let template = template(for: kind) else {
            return []
        }
        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        let triangles = template.sourceTriangleBounds.compactMap { triangle in
            scaledCollisionMeshTriangle(
                triangle,
                scale: scale,
                groundSinkMeters: asset.groundSinkMeters
            )
        }
        guard !triangles.isEmpty else {
            return []
        }
        return [
            EnvironmentCollisionMeshPart(
                triangles: triangles,
                source: "building.mesh.\(kind.rawValue)"
            )
        ]
    }

    func supportSurfaceTriangleParts(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float
    ) -> [EnvironmentSupportSurfaceTrianglePart] {
        guard let template = template(for: kind) else {
            return []
        }
        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        let sourceHeight = template.sourceTriangleBounds.reduce(Float.zero) { max($0, $1.maximum.y) }
        return template.sourceTriangleBounds.enumerated().compactMap { index, triangle in
            guard shouldUseAsSupportSurface(triangle, sourceHeight: sourceHeight),
                  abs(triangle.normal.y) > 0.14 else {
                return nil
            }
            var normal = simd_normalize(triangle.normal)
            if normal.y < 0.0 {
                normal = -normal
            }
            return EnvironmentSupportSurfaceTrianglePart(
                point0: scaledLocalPoint(
                    triangle.point0,
                    scale: scale,
                    groundSinkMeters: asset.groundSinkMeters
                ),
                point1: scaledLocalPoint(
                    triangle.point1,
                    scale: scale,
                    groundSinkMeters: asset.groundSinkMeters
                ),
                point2: scaledLocalPoint(
                    triangle.point2,
                    scale: scale,
                    groundSinkMeters: asset.groundSinkMeters
                ),
                normal: normal,
                source: "building.support.mesh.\(triangle.role.rawValue).\(index)"
            )
        }
    }

    func makeCollisionShape(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float
    ) -> SCNPhysicsShape? {
        guard let template = template(for: kind) else {
            return nil
        }

        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        let sceneScale = CGFloat(scale)
        let mesh = template.templateNode.clone()
        sanitizeCollisionMesh(mesh, kind: kind)
        mesh.scale = SCNVector3(sceneScale, sceneScale, sceneScale)
        mesh.position = SCNVector3(
            -((template.sourceMinimum.x + template.sourceBounds.x * 0.5) * sceneScale),
            -(CGFloat(template.sourceGroundY) * sceneScale) - CGFloat(asset.groundSinkMeters),
            -((template.sourceMinimum.z + template.sourceBounds.z * 0.5) * sceneScale)
        )

        let shapeRoot = SCNNode()
        shapeRoot.addChildNode(mesh)
        return SCNPhysicsShape(
            node: shapeRoot,
            options: [
                SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.concavePolyhedron,
                SCNPhysicsShape.Option.keepAsCompound: true
            ]
        )
    }

    func makeCollisionDebugNode(
        kind: AbandonedCityBuildingKind,
        targetHeightMeters: Float
    ) -> SCNNode? {
        guard let template = template(for: kind) else {
            return nil
        }

        let scale = normalizedScale(
            sourceHeight: Float(template.sourceBounds.y),
            targetHeightMeters: targetHeightMeters
        )
        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        let sceneScale = CGFloat(scale)
        let mesh = template.templateNode.clone()
        sanitizeCollisionMesh(mesh, kind: kind)
        mesh.scale = SCNVector3(sceneScale, sceneScale, sceneScale)
        mesh.position = SCNVector3(
            -((template.sourceMinimum.x + template.sourceBounds.x * 0.5) * sceneScale),
            -(CGFloat(template.sourceGroundY) * sceneScale) - CGFloat(asset.groundSinkMeters),
            -((template.sourceMinimum.z + template.sourceBounds.z * 0.5) * sceneScale)
        )
        applyCollisionDebugMaterial(to: mesh)

        let root = SCNNode()
        root.name = "environment.abandonedCity.collisionDebugMesh.\(kind.rawValue)"
        root.isHidden = true
        root.addChildNode(mesh)
        return root
    }

    private func template(for kind: AbandonedCityBuildingKind) -> AbandonedCityBuildingTemplate? {
        if let cached = templates[kind] {
            return cached
        }
        if attemptedKinds.contains(kind) {
            return nil
        }
        attemptedKinds.insert(kind)

        let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
        guard let url = AbandonedCityAssetCatalog.bundleURL(
            resourceName: asset.resourceName,
            extension: "usdz",
            subdirectory: AbandonedCityAssetCatalog.modelSubdirectory
        ) else {
            warnMissing(kind)
            return nil
        }

        do {
            let scene = try SCNScene(url: url, options: nil)
            let templateNode = SCNNode()
            for child in scene.rootNode.childNodes {
                templateNode.addChildNode(child.clone())
            }
            sanitize(templateNode, kind: kind)

            let bounds = templateNode.boundingBox
            let size = SCNVector3(
                bounds.max.x - bounds.min.x,
                bounds.max.y - bounds.min.y,
                bounds.max.z - bounds.min.z
            )
            guard size.x.isFinite, size.y.isFinite, size.z.isFinite,
                  size.x > 0.001, size.y > 0.001, size.z > 0.001 else {
                warnMissing(kind, reason: "invalid bounds")
                return nil
            }
            let sourceGroundY = transformedStructuralGroundY(
                of: templateNode,
                kind: kind
            ) ?? transformedRenderableBounds(of: templateNode)?.min.y ?? bounds.min.y
            let sourceTriangleBounds = makeSourceTriangleBounds(
                kind: kind,
                root: templateNode,
                sourceMinimum: bounds.min,
                sourceBounds: size,
                sourceGroundY: Float(sourceGroundY)
            )

            let template = AbandonedCityBuildingTemplate(
                kind: kind,
                templateNode: templateNode,
                sourceMinimum: bounds.min,
                sourceBounds: size,
                sourceGroundY: Float(sourceGroundY),
                sourceTriangleBounds: sourceTriangleBounds
            )
            templates[kind] = template
            return template
        } catch {
            warnMissing(kind, reason: error.localizedDescription)
            return nil
        }
    }

    private func makeSourceTriangleBounds(
        kind: AbandonedCityBuildingKind,
        root: SCNNode,
        sourceMinimum: SCNVector3,
        sourceBounds: SCNVector3,
        sourceGroundY: Float
    ) -> [AbandonedCitySourceTriangleBounds] {
        let sourcePlanarCenter = SIMD2<Float>(
            Float(sourceMinimum.x + sourceBounds.x * 0.5),
            Float(sourceMinimum.z + sourceBounds.z * 0.5)
        )
        var triangles: [AbandonedCitySourceTriangleBounds] = []
        collectSourceTriangleBounds(
            node: root,
            kind: kind,
            root: root,
            sourcePlanarCenter: sourcePlanarCenter,
            sourceGroundY: sourceGroundY,
            sourceBounds: SIMD3<Float>(
                Float(sourceBounds.x),
                Float(sourceBounds.y),
                Float(sourceBounds.z)
            ),
            triangles: &triangles
        )
        return triangles
    }

    private func collectSourceTriangleBounds(
        node: SCNNode,
        kind: AbandonedCityBuildingKind,
        root: SCNNode,
        sourcePlanarCenter: SIMD2<Float>,
        sourceGroundY: Float,
        sourceBounds: SIMD3<Float>,
        triangles: inout [AbandonedCitySourceTriangleBounds]
    ) {
        if shouldIgnoreCollisionMeshNode(node, kind: kind) {
            return
        }

        if let geometry = node.geometry {
            appendTriangleBounds(
                from: geometry,
                node: node,
                root: root,
                sourcePlanarCenter: sourcePlanarCenter,
                sourceGroundY: sourceGroundY,
                sourceBounds: sourceBounds,
                triangles: &triangles
            )
        }

        for child in node.childNodes {
            collectSourceTriangleBounds(
                node: child,
                kind: kind,
                root: root,
                sourcePlanarCenter: sourcePlanarCenter,
                sourceGroundY: sourceGroundY,
                sourceBounds: sourceBounds,
                triangles: &triangles
            )
        }
    }

    private func appendTriangleBounds(
        from geometry: SCNGeometry,
        node: SCNNode,
        root: SCNNode,
        sourcePlanarCenter: SIMD2<Float>,
        sourceGroundY: Float,
        sourceBounds: SIMD3<Float>,
        triangles: inout [AbandonedCitySourceTriangleBounds]
    ) {
        guard let vertexSource = geometry.sources(for: .vertex).first,
              let vertices = vertices(from: vertexSource) else {
            return
        }

        for elementIndex in 0..<geometry.elementCount {
            let element = geometry.element(at: elementIndex)
            appendElementTriangleBounds(
                element,
                vertices: vertices,
                node: node,
                root: root,
                sourcePlanarCenter: sourcePlanarCenter,
                sourceGroundY: sourceGroundY,
                sourceBounds: sourceBounds,
                triangles: &triangles
            )
        }
    }

    private func appendElementTriangleBounds(
        _ element: SCNGeometryElement,
        vertices: [SCNVector3],
        node: SCNNode,
        root: SCNNode,
        sourcePlanarCenter: SIMD2<Float>,
        sourceGroundY: Float,
        sourceBounds: SIMD3<Float>,
        triangles: inout [AbandonedCitySourceTriangleBounds]
    ) {
        switch element.primitiveType {
        case .triangles:
            for primitiveIndex in 0..<element.primitiveCount {
                appendTriangle(
                    index0: primitiveIndex * 3,
                    index1: primitiveIndex * 3 + 1,
                    index2: primitiveIndex * 3 + 2,
                    element: element,
                    vertices: vertices,
                    node: node,
                    root: root,
                    sourcePlanarCenter: sourcePlanarCenter,
                    sourceGroundY: sourceGroundY,
                    sourceBounds: sourceBounds,
                    triangles: &triangles
                )
            }

        case .triangleStrip:
            for primitiveIndex in 0..<element.primitiveCount {
                let index0 = primitiveIndex
                let index1 = primitiveIndex + 1
                let index2 = primitiveIndex + 2
                appendTriangle(
                    index0: primitiveIndex.isMultiple(of: 2) ? index0 : index1,
                    index1: primitiveIndex.isMultiple(of: 2) ? index1 : index0,
                    index2: index2,
                    element: element,
                    vertices: vertices,
                    node: node,
                    root: root,
                    sourcePlanarCenter: sourcePlanarCenter,
                    sourceGroundY: sourceGroundY,
                    sourceBounds: sourceBounds,
                    triangles: &triangles
                )
            }

        default:
            return
        }
    }

    private func appendTriangle(
        index0: Int,
        index1: Int,
        index2: Int,
        element: SCNGeometryElement,
        vertices: [SCNVector3],
        node: SCNNode,
        root: SCNNode,
        sourcePlanarCenter: SIMD2<Float>,
        sourceGroundY: Float,
        sourceBounds: SIMD3<Float>,
        triangles: inout [AbandonedCitySourceTriangleBounds]
    ) {
        guard let vertexIndex0 = geometryIndex(at: index0, element: element),
              let vertexIndex1 = geometryIndex(at: index1, element: element),
              let vertexIndex2 = geometryIndex(at: index2, element: element),
              vertexIndex0 < vertices.count,
              vertexIndex1 < vertices.count,
              vertexIndex2 < vertices.count else {
            return
        }

        let point0 = sourceLocalPoint(
            vertices[vertexIndex0],
            node: node,
            root: root,
            sourcePlanarCenter: sourcePlanarCenter,
            sourceGroundY: sourceGroundY
        )
        let point1 = sourceLocalPoint(
            vertices[vertexIndex1],
            node: node,
            root: root,
            sourcePlanarCenter: sourcePlanarCenter,
            sourceGroundY: sourceGroundY
        )
        let point2 = sourceLocalPoint(
            vertices[vertexIndex2],
            node: node,
            root: root,
            sourcePlanarCenter: sourcePlanarCenter,
            sourceGroundY: sourceGroundY
        )

        let rawNormal = simd_cross(point1 - point0, point2 - point0)
        let normal = simd_length_squared(rawNormal) > 0.000001
            ? simd_normalize(rawNormal)
            : SIMD3<Float>(0.0, 1.0, 0.0)
        let minimum = simd_min(simd_min(point0, point1), point2)
        let maximum = simd_max(simd_max(point0, point1), point2)
        let size = maximum - minimum
        guard isFinite(minimum),
              isFinite(maximum),
              simd_length_squared(size) > 0.000001,
              isWithinCollisionSourceBounds(minimum: minimum, maximum: maximum, sourceBounds: sourceBounds) else {
            return
        }

        triangles.append(AbandonedCitySourceTriangleBounds(
            point0: point0,
            point1: point1,
            point2: point2,
            minimum: minimum,
            maximum: maximum,
            normal: normal,
            role: roleForTriangle(
                point0,
                point1,
                point2,
                normal: normal,
                nodeName: node.name,
                sourceHeight: sourceBounds.y
            ),
            sourceName: node.name ?? ""
        ))
    }

    private func vertices(from source: SCNGeometrySource) -> [SCNVector3]? {
        guard source.componentsPerVector >= 3 else {
            return nil
        }

        let data = source.data as NSData
        return (0..<source.vectorCount).map { index in
            let base = source.dataOffset + index * source.dataStride
            return SCNVector3(
                readGeometryComponent(data, at: base, source: source),
                readGeometryComponent(data, at: base + source.bytesPerComponent, source: source),
                readGeometryComponent(data, at: base + source.bytesPerComponent * 2, source: source)
            )
        }
    }

    private func readGeometryComponent(
        _ data: NSData,
        at offset: Int,
        source: SCNGeometrySource
    ) -> Float {
        guard source.usesFloatComponents else {
            return 0.0
        }

        if source.bytesPerComponent == 4 {
            var value = Float.zero
            data.getBytes(&value, range: NSRange(location: offset, length: 4))
            return value
        }

        if source.bytesPerComponent == 8 {
            var value = Double.zero
            data.getBytes(&value, range: NSRange(location: offset, length: 8))
            return Float(value)
        }

        return 0.0
    }

    private func geometryIndex(
        at indexOffset: Int,
        element: SCNGeometryElement
    ) -> Int? {
        let byteOffset = indexOffset * element.bytesPerIndex
        let data = element.data as NSData
        guard byteOffset >= 0,
              byteOffset + element.bytesPerIndex <= data.length else {
            return nil
        }

        switch element.bytesPerIndex {
        case 1:
            var value = UInt8.zero
            data.getBytes(&value, range: NSRange(location: byteOffset, length: 1))
            return Int(value)
        case 2:
            var value = UInt16.zero
            data.getBytes(&value, range: NSRange(location: byteOffset, length: 2))
            return Int(value)
        case 4:
            var value = UInt32.zero
            data.getBytes(&value, range: NSRange(location: byteOffset, length: 4))
            return Int(value)
        default:
            return nil
        }
    }

    private func sourceLocalPoint(
        _ point: SCNVector3,
        node: SCNNode,
        root: SCNNode,
        sourcePlanarCenter: SIMD2<Float>,
        sourceGroundY: Float
    ) -> SIMD3<Float> {
        let rootPoint = node.convertPosition(point, to: root)
        return SIMD3<Float>(
            Float(rootPoint.x) - sourcePlanarCenter.x,
            Float(rootPoint.y) - sourceGroundY,
            Float(rootPoint.z) - sourcePlanarCenter.y
        )
    }

    private func roleForTriangle(
        _ point0: SIMD3<Float>,
        _ point1: SIMD3<Float>,
        _ point2: SIMD3<Float>,
        normal: SIMD3<Float>,
        nodeName: String?,
        sourceHeight: Float
    ) -> BuildingColliderRole {
        let name = nodeName?.lowercased() ?? ""
        if name.contains("glass") {
            return .glass
        }
        if name.contains("iron") {
            return .beam
        }
        if (name.contains("roof") || name.contains("shingle") || name.contains("tile")),
           abs(normal.y) > 0.18 {
            return .roof
        }

        if normal.y > 0.35 {
            let centerY = (point0.y + point1.y + point2.y) / 3.0
            return centerY < sourceHeight * 0.16 ? .floor : .roof
        }
        return .wall
    }

    private func isWithinCollisionSourceBounds(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        sourceBounds: SIMD3<Float>
    ) -> Bool {
        let planarLimit = max(sourceBounds.x, sourceBounds.z) * 1.8
        let lowerY = -sourceBounds.y * 0.35
        let upperY = sourceBounds.y * 1.35
        return minimum.x >= -planarLimit &&
            maximum.x <= planarLimit &&
            minimum.z >= -planarLimit &&
            maximum.z <= planarLimit &&
            minimum.y >= lowerY &&
            maximum.y <= upperY
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func scaledCollisionMeshTriangle(
        _ triangle: AbandonedCitySourceTriangleBounds,
        scale: Float,
        groundSinkMeters: Float
    ) -> EnvironmentCollisionMeshTriangle? {
        let point0 = scaledLocalPoint(
            triangle.point0,
            scale: scale,
            groundSinkMeters: groundSinkMeters
        )
        let point1 = scaledLocalPoint(
            triangle.point1,
            scale: scale,
            groundSinkMeters: groundSinkMeters
        )
        let point2 = scaledLocalPoint(
            triangle.point2,
            scale: scale,
            groundSinkMeters: groundSinkMeters
        )
        let edge0 = point1 - point0
        let edge1 = point2 - point0
        guard isFinite(point0),
              isFinite(point1),
              isFinite(point2),
              simd_length_squared(simd_cross(edge0, edge1)) > 0.000001 else {
            return nil
        }
        return EnvironmentCollisionMeshTriangle(
            point0: point0,
            point1: point1,
            point2: point2
        )
    }

    private func scaledLocalPoint(
        _ point: SIMD3<Float>,
        scale: Float,
        groundSinkMeters: Float
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            point.x * scale,
            point.y * scale - groundSinkMeters,
            point.z * scale
        )
    }

    private func makeSupportSurfaceParts(
        triangles: [AbandonedCitySourceTriangleBounds],
        scale: Float,
        groundSinkMeters: Float
    ) -> [EnvironmentSupportSurfacePart] {
        guard !triangles.isEmpty else {
            return []
        }

        let cellSizeMeters: Float = 3.0
        let cellSizeSource = max(0.001, cellSizeMeters / max(scale, 0.001))
        let heightStepSource = max(0.001, 0.18 / max(scale, 0.001))
        let sourceHeight = triangles.reduce(Float.zero) { max($0, $1.maximum.y) }
        var occupied: [AbandonedCitySupportSurfaceKey: AbandonedCitySupportSurfaceCandidate] = [:]

        for triangle in triangles {
            switch triangle.role {
            case .roof, .floor, .landingSurface:
                break
            case .wall, .beam, .railing, .door, .glass, .debris:
                continue
            }
            guard shouldUseAsSupportSurface(triangle, sourceHeight: sourceHeight) else {
                continue
            }
            guard abs(triangle.normal.y) > 0.14 else {
                continue
            }

            var normal = simd_normalize(triangle.normal)
            if normal.y < 0.0 {
                normal = -normal
            }

            let xRange = cellRange(triangle.minimum.x, triangle.maximum.x, cellSizeSource)
            let zRange = cellRange(triangle.minimum.z, triangle.maximum.z, cellSizeSource)
            var inserted = false

            for z in zRange {
                for x in xRange {
                    let center = SIMD2<Float>(
                        (Float(x) + 0.5) * cellSizeSource,
                        (Float(z) + 0.5) * cellSizeSource
                    )
                    guard projectedPoint(
                        center,
                        isInsideTriangle: triangle,
                        projection: .horizontal
                    ) else {
                        continue
                    }
                    let surfaceY = heightOnTriangle(triangle, x: center.x, z: center.y)
                    addSupportSurfaceCandidate(
                        role: triangle.role,
                        x: x,
                        z: z,
                        sourceY: surfaceY,
                        sourceXZ: center,
                        normal: normal,
                        cellSizeMeters: cellSizeMeters,
                        heightStepSource: heightStepSource,
                        scale: scale,
                        groundSinkMeters: groundSinkMeters,
                        occupied: &occupied
                    )
                    inserted = true
                }
            }

            if !inserted {
                let center3D = (triangle.point0 + triangle.point1 + triangle.point2) / 3.0
                addSupportSurfaceCandidate(
                    role: triangle.role,
                    x: Int(floor(center3D.x / cellSizeSource)),
                    z: Int(floor(center3D.z / cellSizeSource)),
                    sourceY: center3D.y,
                    sourceXZ: SIMD2<Float>(center3D.x, center3D.z),
                    normal: normal,
                    cellSizeMeters: min(cellSizeMeters, max(0.35, simd_length(triangle.maximum - triangle.minimum) * scale)),
                    heightStepSource: heightStepSource,
                    scale: scale,
                    groundSinkMeters: groundSinkMeters,
                    occupied: &occupied
                )
            }
        }

        return occupied.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .enumerated()
            .map { index, candidate in
                EnvironmentSupportSurfacePart(
                    localCenter: candidate.localCenter,
                    halfExtents: candidate.halfExtents,
                    yawRadians: 0.0,
                    normal: candidate.normal,
                    source: "building.support.\(candidate.key.role.rawValue).\(index)"
                )
            }
    }

    private func shouldUseAsSupportSurface(
        _ triangle: AbandonedCitySourceTriangleBounds,
        sourceHeight: Float
    ) -> Bool {
        let name = triangle.sourceName.lowercased()
        if name.contains("roof") || name.contains("shingle") || name.contains("tile") {
            return true
        }
        if name.contains("wood") ||
            name.contains("plank") ||
            name.contains("handle") ||
            name.contains("glass") ||
            name.contains("environment") ||
            name.contains("iron") ||
            name.contains("ground") {
            return false
        }

        let centerY = (triangle.point0.y + triangle.point1.y + triangle.point2.y) / 3.0
        switch triangle.role {
        case .roof, .landingSurface:
            return centerY > sourceHeight * 0.50
        case .floor:
            return centerY > sourceHeight * 0.45
        case .wall, .beam, .railing, .door, .glass, .debris:
            return false
        }
    }

    private func addSupportSurfaceCandidate(
        role: BuildingColliderRole,
        x: Int,
        z: Int,
        sourceY: Float,
        sourceXZ: SIMD2<Float>,
        normal: SIMD3<Float>,
        cellSizeMeters: Float,
        heightStepSource: Float,
        scale: Float,
        groundSinkMeters: Float,
        occupied: inout [AbandonedCitySupportSurfaceKey: AbandonedCitySupportSurfaceCandidate]
    ) {
        guard sourceY.isFinite, sourceY >= -0.02 else {
            return
        }

        let localY = sourceY * scale - groundSinkMeters
        guard localY > 0.18 || role == .roof || role == .landingSurface else {
            return
        }

        let key = AbandonedCitySupportSurfaceKey(
            x: x,
            z: z,
            y: Int(round(sourceY / heightStepSource)),
            normalX: Int(round(normal.x * 16.0)),
            normalY: Int(round(normal.y * 16.0)),
            normalZ: Int(round(normal.z * 16.0)),
            role: role
        )
        guard occupied[key] == nil else {
            return
        }

        let localCenter = SIMD3<Float>(
            sourceXZ.x * scale,
            localY,
            sourceXZ.y * scale
        )
        occupied[key] = AbandonedCitySupportSurfaceCandidate(
            key: key,
            localCenter: localCenter,
            halfExtents: SIMD2<Float>(repeating: cellSizeMeters * 0.5),
            normal: normal
        )
    }

    private func cellRange(
        _ minimum: Float,
        _ maximum: Float,
        _ cellSize: Float
    ) -> ClosedRange<Int> {
        let lower = Int(floor(minimum / cellSize))
        let upper = Int(floor(maximum / cellSize))
        return min(lower, upper)...max(lower, upper)
    }

    private func projectedPoint(
        _ point: SIMD2<Float>,
        isInsideTriangle triangle: AbandonedCitySourceTriangleBounds,
        projection: AbandonedCitySurfaceAxis
    ) -> Bool {
        let p0 = projectedPoint(triangle.point0, projection: projection)
        let p1 = projectedPoint(triangle.point1, projection: projection)
        let p2 = projectedPoint(triangle.point2, projection: projection)
        return pointInsideTriangle2D(point, p0, p1, p2)
    }

    private func projectedPoint(
        _ point: SIMD3<Float>,
        projection: AbandonedCitySurfaceAxis
    ) -> SIMD2<Float> {
        switch projection {
        case .horizontal:
            return SIMD2<Float>(point.x, point.z)
        case .thinX:
            return SIMD2<Float>(point.z, point.y)
        case .thinZ:
            return SIMD2<Float>(point.x, point.y)
        }
    }

    private func pointInsideTriangle2D(
        _ point: SIMD2<Float>,
        _ vertex0: SIMD2<Float>,
        _ vertex1: SIMD2<Float>,
        _ vertex2: SIMD2<Float>
    ) -> Bool {
        let area = edge(vertex0, vertex1, vertex2)
        guard abs(area) > 0.000001 else {
            return false
        }
        let w0 = edge(vertex1, vertex2, point) / area
        let w1 = edge(vertex2, vertex0, point) / area
        let w2 = edge(vertex0, vertex1, point) / area
        let tolerance: Float = -0.04
        return w0 >= tolerance && w1 >= tolerance && w2 >= tolerance
    }

    private func edge(
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>
    ) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private func heightOnTriangle(
        _ triangle: AbandonedCitySourceTriangleBounds,
        x: Float,
        z: Float
    ) -> Float {
        guard abs(triangle.normal.y) > 0.0001 else {
            return (triangle.point0.y + triangle.point1.y + triangle.point2.y) / 3.0
        }
        return triangle.point0.y -
            (triangle.normal.x * (x - triangle.point0.x) +
             triangle.normal.z * (z - triangle.point0.z)) / triangle.normal.y
    }

    private func sanitize(_ node: SCNNode, kind: AbandonedCityBuildingKind) {
        node.physicsBody = nil
        node.particleSystems?.forEach { node.removeParticleSystem($0) }

        // The shop USDZ contains its own display plane. City terrain is provided by
        // the shared ground node, so repeated asset-local ground planes are removed.
        if kind == .shopOldHouse,
           node.name?.localizedCaseInsensitiveContains("Plane_Ground") == true {
            node.removeFromParentNode()
            return
        }

        for child in node.childNodes {
            sanitize(child, kind: kind)
        }
    }

    private func sanitizeCollisionMesh(_ node: SCNNode, kind: AbandonedCityBuildingKind) {
        node.physicsBody = nil
        node.particleSystems?.forEach { node.removeParticleSystem($0) }

        for child in node.childNodes {
            if shouldIgnoreCollisionMeshNode(child, kind: kind) {
                child.removeFromParentNode()
            } else {
                sanitizeCollisionMesh(child, kind: kind)
            }
        }
    }

    private func shouldIgnoreCollisionMeshNode(
        _ node: SCNNode,
        kind: AbandonedCityBuildingKind
    ) -> Bool {
        let name = node.name?.lowercased() ?? ""
        if name.contains("plane_ground") {
            return true
        }
        if kind == .shopOldHouse,
           name.contains("environments") {
            return true
        }
        return false
    }

    private func applyCollisionDebugMaterial(to node: SCNNode) {
        if let geometry = node.geometry?.copy() as? SCNGeometry {
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.62)
            material.lightingModel = .constant
            material.fillMode = .lines
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            geometry.materials = [material]
            node.geometry = geometry
        }

        for child in node.childNodes {
            applyCollisionDebugMaterial(to: child)
        }
    }

    private func transformedStructuralGroundY(
        of node: SCNNode,
        kind: AbandonedCityBuildingKind
    ) -> CGFloat? {
        transformedRenderableBounds(of: node) { candidate in
            self.isStructuralGroundNode(candidate, kind: kind)
        }?.min.y
    }

    private func isStructuralGroundNode(
        _ node: SCNNode,
        kind: AbandonedCityBuildingKind
    ) -> Bool {
        let name = node.name?.lowercased() ?? ""
        if name.contains("plane_ground") ||
            name.contains("ground") ||
            name.contains("roof") ||
            name.contains("shingle") ||
            name.contains("tile") ||
            name.contains("glass") ||
            name.contains("handle") {
            return false
        }
        if kind == .shopOldHouse,
           name.contains("environments") || name.contains("iron") {
            return false
        }
        return true
    }

    private func normalizedScale(
        sourceHeight: Float,
        targetHeightMeters: Float
    ) -> Float {
        min(10.0, max(0.01, targetHeightMeters / max(sourceHeight, 0.001)))
    }

    private func transformedRenderableBounds(
        of node: SCNNode,
        includeNode: ((SCNNode) -> Bool)? = nil
    ) -> (min: SCNVector3, max: SCNVector3)? {
        var hasBounds = false
        var aggregateMin = SCNVector3Zero
        var aggregateMax = SCNVector3Zero
        accumulateRenderableBounds(
            node,
            root: node,
            includeNode: includeNode,
            aggregateMin: &aggregateMin,
            aggregateMax: &aggregateMax,
            hasBounds: &hasBounds
        )
        guard hasBounds else {
            return nil
        }
        return (aggregateMin, aggregateMax)
    }

    private func accumulateRenderableBounds(
        _ node: SCNNode,
        root: SCNNode,
        includeNode: ((SCNNode) -> Bool)?,
        aggregateMin: inout SCNVector3,
        aggregateMax: inout SCNVector3,
        hasBounds: inout Bool
    ) {
        if let geometry = node.geometry,
           geometry.firstMaterial != nil,
           includeNode?(node) ?? true {
            let bounds = node.boundingBox
            let corners = boundingBoxCorners(min: bounds.min, max: bounds.max)
            for corner in corners {
                let transformed = node.convertPosition(corner, to: root)
                if hasBounds {
                    aggregateMin.x = min(aggregateMin.x, transformed.x)
                    aggregateMin.y = min(aggregateMin.y, transformed.y)
                    aggregateMin.z = min(aggregateMin.z, transformed.z)
                    aggregateMax.x = max(aggregateMax.x, transformed.x)
                    aggregateMax.y = max(aggregateMax.y, transformed.y)
                    aggregateMax.z = max(aggregateMax.z, transformed.z)
                } else {
                    aggregateMin = transformed
                    aggregateMax = transformed
                    hasBounds = true
                }
            }
        }

        for child in node.childNodes {
            accumulateRenderableBounds(
                child,
                root: root,
                includeNode: includeNode,
                aggregateMin: &aggregateMin,
                aggregateMax: &aggregateMax,
                hasBounds: &hasBounds
            )
        }
    }

    private func boundingBoxCorners(min: SCNVector3, max: SCNVector3) -> [SCNVector3] {
        [
            SCNVector3(min.x, min.y, min.z),
            SCNVector3(min.x, min.y, max.z),
            SCNVector3(min.x, max.y, min.z),
            SCNVector3(min.x, max.y, max.z),
            SCNVector3(max.x, min.y, min.z),
            SCNVector3(max.x, min.y, max.z),
            SCNVector3(max.x, max.y, min.z),
            SCNVector3(max.x, max.y, max.z)
        ]
    }

    private func warnMissing(
        _ kind: AbandonedCityBuildingKind,
        reason: String? = nil
    ) {
        guard warnedKinds.insert(kind).inserted else {
            return
        }
        let suffix = reason.map { " reason=\($0)" } ?? ""
        print("[AbandonedCity] WARNING missing asset kind=\(kind.rawValue)\(suffix)")
    }

    private func formatted(_ value: Float) -> String {
        String(format: "%.4f", value)
    }
}
