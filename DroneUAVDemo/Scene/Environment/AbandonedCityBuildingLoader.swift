import Foundation
import SceneKit

struct AbandonedCityBuildingTemplate {
    let kind: AbandonedCityBuildingKind
    let templateNode: SCNNode
    let sourceMinimum: SCNVector3
    let sourceBounds: SCNVector3
    let sourceGroundY: Float
    let normalizedScale: Float
    let collisionSize: SCNVector3
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
            let sourceGroundY = transformedRenderableBounds(of: templateNode)?.min.y ?? bounds.min.y

            let defaultHeight = (asset.targetHeightRange.lowerBound + asset.targetHeightRange.upperBound) * 0.5
            let defaultScale = normalizedScale(
                sourceHeight: Float(size.y),
                targetHeightMeters: defaultHeight
            )
            let sceneScale = CGFloat(defaultScale)
            let template = AbandonedCityBuildingTemplate(
                kind: kind,
                templateNode: templateNode,
                sourceMinimum: bounds.min,
                sourceBounds: size,
                sourceGroundY: Float(sourceGroundY),
                normalizedScale: defaultScale,
                collisionSize: SCNVector3(
                    size.x * sceneScale,
                    size.y * sceneScale,
                    size.z * sceneScale
                )
            )
            templates[kind] = template
            return template
        } catch {
            warnMissing(kind, reason: error.localizedDescription)
            return nil
        }
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

    private func normalizedScale(
        sourceHeight: Float,
        targetHeightMeters: Float
    ) -> Float {
        min(10.0, max(0.01, targetHeightMeters / max(sourceHeight, 0.001)))
    }

    private func transformedRenderableBounds(of node: SCNNode) -> (min: SCNVector3, max: SCNVector3)? {
        var hasBounds = false
        var aggregateMin = SCNVector3Zero
        var aggregateMax = SCNVector3Zero
        accumulateRenderableBounds(
            node,
            parentTransform: SCNMatrix4Identity,
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
        parentTransform: SCNMatrix4,
        aggregateMin: inout SCNVector3,
        aggregateMax: inout SCNVector3,
        hasBounds: inout Bool
    ) {
        let worldTransform = SCNMatrix4Mult(parentTransform, node.transform)

        if let geometry = node.geometry, geometry.firstMaterial != nil {
            let bounds = node.boundingBox
            let corners = boundingBoxCorners(min: bounds.min, max: bounds.max)
            for corner in corners {
                let transformed = transform(point: corner, by: worldTransform)
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
                parentTransform: worldTransform,
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

    private func transform(point: SCNVector3, by matrix: SCNMatrix4) -> SCNVector3 {
        SCNVector3(
            matrix.m11 * point.x + matrix.m21 * point.y + matrix.m31 * point.z + matrix.m41,
            matrix.m12 * point.x + matrix.m22 * point.y + matrix.m32 * point.z + matrix.m42,
            matrix.m13 * point.x + matrix.m23 * point.y + matrix.m33 * point.z + matrix.m43
        )
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
