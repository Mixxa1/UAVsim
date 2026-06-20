import Foundation
import SceneKit

private enum ProjectAssetLicense {
    case creativeCommonsAttribution

    var isEligible: Bool {
        self == .creativeCommonsAttribution
    }
}

private struct CargoContainerAssetDefinition {
    let resourceName: String
    let sourceURL: String
    let license: ProjectAssetLicense
    let isolatedNodeName: String?
}

final class CargoContainerAssetLoader {
    static let shared = CargoContainerAssetLoader()

    private struct Template {
        let node: SCNNode
        let sourceMinimum: SCNVector3
        let sourceSize: SCNVector3
        let rotateLengthToX: Bool
    }

    private static let modelSubdirectory = "Models/Environment/Cargo"

    private static let definitions: [CargoContainerAssetKind: CargoContainerAssetDefinition] = [
        .container18MB: CargoContainerAssetDefinition(
            resourceName: "Container_18_MB",
            sourceURL: "https://skfb.ly/p8pR6",
            license: .creativeCommonsAttribution,
            // The source file bundles two containers as RootNode's only two children: "_1"
            // (doors closed) and "_2_2" (doors swung open). Isolate the open one — using the
            // whole scene meant the collision box spanned both at once.
            isolatedNodeName: "_2_2"
        ),
        .freeShipContainer: CargoContainerAssetDefinition(
            resourceName: "Free_Ship_Container",
            sourceURL: "https://skfb.ly/oxyBn",
            license: .creativeCommonsAttribution,
            isolatedNodeName: nil
        ),
        .shippingContainerOpen: CargoContainerAssetDefinition(
            resourceName: "Shipping_Containers",
            sourceURL: "https://skfb.ly/oKY9G",
            license: .creativeCommonsAttribution,
            isolatedNodeName: "ShippingContainerMain"
        ),
        .seaCargoContainer: CargoContainerAssetDefinition(
            resourceName: "Sea_cargo_container_-_LegendaryGameDev",
            sourceURL: "https://skfb.ly/oGUqJ",
            license: .creativeCommonsAttribution,
            isolatedNodeName: nil
        ),
        .containersCluster: CargoContainerAssetDefinition(
            resourceName: "Containers",
            sourceURL: "https://skfb.ly/6CNsu",
            license: .creativeCommonsAttribution,
            isolatedNodeName: nil
        )
    ]

    private var cachedTemplateVariants: [CargoContainerAssetKind: [Template]] = [:]
    private var attemptedKinds: Set<CargoContainerAssetKind> = []
    private var warnedKinds: Set<CargoContainerAssetKind> = []

    private init() {}

    func makeNode(
        for descriptor: EnvironmentObjectDescriptor,
        quality: EnvironmentVisualQuality
    ) -> SCNNode? {
        guard descriptor.kind == .cargoContainer,
              let assetKind = descriptor.cargoAsset,
              let definition = Self.definitions[assetKind],
              definition.license.isEligible else {
            return nil
        }
        let variants = templateVariants(for: assetKind, definition: definition)
        guard !variants.isEmpty else {
            return nil
        }
        let variantIndex = stableVariantIndex(for: descriptor.id, count: variants.count)
        let template = variants[variantIndex]

        let sourceX = Float(template.sourceSize.x)
        let sourceY = Float(template.sourceSize.y)
        let sourceZ = Float(template.sourceSize.z)
        let orientedX = template.rotateLengthToX ? sourceZ : sourceX
        let orientedZ = template.rotateLengthToX ? sourceX : sourceZ

        let visual = template.node.clone()
        visual.position = SCNVector3(
            -(template.sourceMinimum.x + template.sourceSize.x * 0.5),
            -template.sourceMinimum.y,
            -(template.sourceMinimum.z + template.sourceSize.z * 0.5)
        )

        let oriented = SCNNode()
        if template.rotateLengthToX {
            oriented.eulerAngles.y = .pi * 0.5
        }
        oriented.addChildNode(visual)

        let normalized = SCNNode()
        normalized.scale = SCNVector3(
            CGFloat(descriptor.size.x / max(orientedX, 0.001)),
            CGFloat(descriptor.size.y / max(sourceY, 0.001)),
            CGFloat(descriptor.size.z / max(orientedZ, 0.001))
        )
        normalized.addChildNode(oriented)

        let root = SCNNode()
        root.name = "environment.cargo.\(assetKind.rawValue).\(descriptor.id.uuidString)"
        root.simdPosition = descriptor.position
        root.eulerAngles.y = CGFloat(descriptor.yawRadians)
        root.addChildNode(normalized)

        let castsShadow = quality == .detailed
        root.enumerateChildNodes { node, _ in
            node.castsShadow = castsShadow
            node.physicsBody = nil
        }
        return root
    }

    private func stableVariantIndex(for id: UUID, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(into: 0) { $0 += Int($1) }
        return sum % count
    }

    private func templateVariants(
        for kind: CargoContainerAssetKind,
        definition: CargoContainerAssetDefinition
    ) -> [Template] {
        if let cached = cachedTemplateVariants[kind] {
            return cached
        }
        if attemptedKinds.contains(kind) {
            return []
        }
        attemptedKinds.insert(kind)

        guard definition.license.isEligible,
              let url = bundleURL(resourceName: definition.resourceName) else {
            warnOnce(kind, definition: definition, reason: "asset unavailable or license rejected")
            return []
        }

        do {
            let scene = try SCNScene(url: url, options: [
                .checkConsistency: false,
                .preserveOriginalTopology: false
            ])
            let sourceRoot = SCNNode()
            for child in scene.rootNode.childNodes {
                sourceRoot.addChildNode(child.clone())
            }
            sanitize(sourceRoot)

            var candidates: [(node: SCNNode, bounds: (min: SCNVector3, max: SCNVector3))] = []
            if kind == .shippingContainerOpen {
                candidates = makeOpenShippingContainerTemplates(from: sourceRoot)
            } else if let isolatedNodeName = definition.isolatedNodeName,
                      let isolated = sourceRoot.childNode(withName: isolatedNodeName, recursively: true) {
                let clone = clonePreservingWorldTransform(isolated)
                let templateNode = SCNNode()
                templateNode.addChildNode(clone)
                candidates = [(templateNode, templateNode.boundingBox)]
            } else {
                candidates = [(sourceRoot, sourceRoot.boundingBox)]
            }

            let built: [Template] = candidates.compactMap { candidate in
                let bounds = candidate.bounds
                let size = SCNVector3(
                    bounds.max.x - bounds.min.x,
                    bounds.max.y - bounds.min.y,
                    bounds.max.z - bounds.min.z
                )
                guard size.x.isFinite, size.y.isFinite, size.z.isFinite,
                      size.x > 0.001, size.y > 0.001, size.z > 0.001 else {
                    return nil
                }
                return Template(
                    node: candidate.node,
                    sourceMinimum: bounds.min,
                    sourceSize: size,
                    rotateLengthToX: size.z > size.x
                )
            }

            guard !built.isEmpty else {
                warnOnce(kind, definition: definition, reason: "invalid model bounds")
                return []
            }

            cachedTemplateVariants[kind] = built
            return built
        } catch {
            warnOnce(kind, definition: definition, reason: error.localizedDescription)
            return []
        }
    }

    private func sanitize(_ node: SCNNode) {
        node.physicsBody = nil
        node.camera = nil
        node.light = nil
        node.particleSystems?.forEach { node.removeParticleSystem($0) }
        for child in node.childNodes {
            sanitize(child)
        }
    }

    private func makeOpenShippingContainerTemplates(
        from sourceRoot: SCNNode
    ) -> [(node: SCNNode, bounds: (min: SCNVector3, max: SCNVector3))] {
        let mainVariants = indexedNodes(named: "ShippingContainerMain", in: sourceRoot)
        guard !mainVariants.isEmpty else {
            return []
        }

        return mainVariants.map { main in
            let root = SCNNode()
            root.addChildNode(clonePreservingWorldTransform(main))
            return (root, root.boundingBox)
        }
    }

    private func indexedNodes(named baseName: String, in root: SCNNode) -> [SCNNode] {
        var results: [SCNNode] = []
        if let first = root.childNode(withName: baseName, recursively: true) {
            results.append(first)
        }
        var index = 1
        while let node = root.childNode(
            withName: "\(baseName)_\(String(format: "%03d", index))",
            recursively: true
        ) {
            results.append(node)
            index += 1
        }
        return results
    }

    private func clonePreservingWorldTransform(_ node: SCNNode) -> SCNNode {
        let clone = node.clone()
        clone.transform = node.worldTransform
        return clone
    }

    private func bundleURL(resourceName: String) -> URL? {
        Bundle.main.url(
            forResource: resourceName,
            withExtension: "usdz",
            subdirectory: Self.modelSubdirectory
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: "usdz"
        )
    }

    private func warnOnce(
        _ kind: CargoContainerAssetKind,
        definition: CargoContainerAssetDefinition,
        reason: String
    ) {
        guard !warnedKinds.contains(kind) else {
            return
        }
        warnedKinds.insert(kind)
        print(
            "[Cargo] \(definition.resourceName).usdz rejected: \(reason); " +
            "source=\(definition.sourceURL)"
        )
    }
}
