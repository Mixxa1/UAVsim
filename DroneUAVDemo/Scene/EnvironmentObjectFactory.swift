import SceneKit

enum EnvironmentObjectFactory {
    static func makeNode(for descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        EnvironmentProceduralVisualFactory.makeNode(for: descriptor)
    }
}
