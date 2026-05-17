import SceneKit

enum EnvironmentVisualQuality: Equatable {
    case detailed
    case simplified
}

enum EnvironmentObjectFactory {
    static func makeNode(
        for descriptor: EnvironmentObjectDescriptor,
        quality: EnvironmentVisualQuality = .detailed
    ) -> SCNNode {
        EnvironmentProceduralVisualFactory.makeNode(for: descriptor, quality: quality)
    }
}
