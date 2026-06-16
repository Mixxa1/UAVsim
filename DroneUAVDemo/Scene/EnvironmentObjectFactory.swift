import SceneKit

enum EnvironmentVisualQuality: Equatable {
    case detailed
    case simplified
}

enum EnvironmentObjectFactory {
    private static var pineTrees = 0
    private static var proceduralFallbackTrees = 0
    private static var placeholdersHidden = 0
    private static var grassMaterialKind = "generic_grass"

    static func resetDiagnostics() {
        pineTrees = 0
        proceduralFallbackTrees = 0
        placeholdersHidden = 0
    }

    static func printDiagnostics() {
        print("[Environment] visuals pineTrees=\(pineTrees) proceduralFallbackTrees=\(proceduralFallbackTrees) placeholdersHidden=\(placeholdersHidden) grassMaterial=\(grassMaterialKind)")
    }

    static func makeNode(
        for descriptor: EnvironmentObjectDescriptor,
        quality: EnvironmentVisualQuality = .detailed
    ) -> SCNNode {
        switch descriptor.kind {
        case .tree:
            return makeTreeNode(descriptor: descriptor, quality: quality)
        case .pole, .rock, .crate, .marker:
            if EnvironmentDebugOptions.showPlaceholderObjects {
                return EnvironmentProceduralVisualFactory.makeNode(for: descriptor, quality: quality)
            }
            placeholdersHidden += 1
            return emptyNode(for: descriptor)
        case .building, .distantBelt:
            return EnvironmentProceduralVisualFactory.makeNode(for: descriptor, quality: quality)
        }
    }

    private static func makeTreeNode(
        descriptor: EnvironmentObjectDescriptor,
        quality: EnvironmentVisualQuality
    ) -> SCNNode {
        let targetHeight = descriptor.size.y.clamped(to: 8.0...34.0)
        let yaw = descriptor.yawRadians

        if let pine = PineTreeAssetLoader.shared.makeTreeNode(targetHeightMeters: targetHeight, yaw: yaw) {
            pine.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
            pineTrees += 1
            return pine
        }

        proceduralFallbackTrees += 1
        return EnvironmentProceduralVisualFactory.makeNode(for: descriptor, quality: quality)
    }

    private static func emptyNode(for descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let node = SCNNode()
        node.name = "placeholder_hidden_\(descriptor.kind.rawValue)_\(descriptor.id.uuidString)"
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        return node
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
