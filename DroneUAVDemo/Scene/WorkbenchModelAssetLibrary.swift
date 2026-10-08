import AppKit
import SceneKit

/// Original, metre-scale USDZ parts used by catalog previews and assembled
/// Workbench vehicles. Geometry alone comes from these files; engineering
/// dimensions, mass, electrical properties and CAD imports stay in the domain.
final class WorkbenchModelAssetLibrary {
    static let shared = WorkbenchModelAssetLibrary(
        directory: Bundle.main.url(forResource: "WorkbenchParts", withExtension: nil))

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let id: String
            let file: String
        }
        let models: [Entry]
    }

    private let directory: URL?
    private let entries: [String: Manifest.Entry]
    private let cache = NSCache<NSString, SCNNode>()
    private let lock = NSRecursiveLock()

    init(directory: URL?) {
        self.directory = directory
        cache.countLimit = 20
        cache.totalCostLimit = 800_000
        if let directory,
           let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            entries = Dictionary(manifest.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            entries = [:]
        }
    }

    var coveredIDs: Set<String> { Set(entries.keys) }

    func componentNode(for spec: WorkbenchComponentSpec) -> SCNNode? {
        // An edited or imported component must retain its authored geometry.
        // The catalog id alone cannot establish that its size/shape is unchanged.
        guard spec.importedMesh == nil,
              let canonical = WorkbenchComponentLibrary.spec(id: spec.id),
              spec.kind == canonical.kind,
              spec.proxy == canonical.proxy,
              spec.params == canonical.params else { return nil }
        return node(for: spec.id)
    }

    func frameNode(for frame: WorkbenchResolvedFrame) -> SCNNode? {
        guard frame.importedMesh == nil,
              let canonical = WorkbenchFrameLibrary.all.first(where: {
                  WorkbenchFrameSource.library(id: $0.id).resolve() == frame
              }) else { return nil }
        return node(for: canonical.id)
    }

    /// Also exposes the separate wing/fuselage assets to inspection tools.
    func node(for id: String) -> SCNNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], let directory else { return nil }
        let key = id as NSString
        if let template = cache.object(forKey: key) { return independentClone(template) }
        // The bundle flattens models/ into its folder reference.
        let filename = (entry.file as NSString).lastPathComponent
        guard filename.hasSuffix(".usdz"),
              let scene = try? SCNScene(url: directory.appendingPathComponent(filename), options: [.checkConsistency: true]) else {
            return nil
        }
        let root = SCNNode()
        root.name = "workbench.asset.\(id)"
        for child in scene.rootNode.childNodes { root.addChildNode(child) }
        var vertexCost = 0
        var hasMesh = false
        root.enumerateChildNodes { node, _ in
            node.removeAllAnimations()
            // Preserve the existing Scene-layer names used to inspect airframes.
            switch node.name {
            case "Wing": node.name = "workbench.airframe.wing"
            case "Fuselage": node.name = "workbench.airframe.fuselage"
            case "Nose": node.name = "workbench.airframe.nose"
            case "AvionicsHatch": node.name = "workbench.airframe.avionicsHatch"
            case "Tail": node.name = "workbench.airframe.tail"
            case "VTOLBoomLeft": node.name = "workbench.airframe.vtolBoom.left"
            case "VTOLBoomRight": node.name = "workbench.airframe.vtolBoom.right"
            default: break
            }
            if let geometry = node.geometry {
                hasMesh = true
                vertexCost += geometry.sources(for: .vertex).first?.vectorCount ?? 0
            }
        }
        guard hasMesh else { return nil }
        cache.setObject(root, forKey: key, cost: vertexCost)
        return independentClone(root)
    }

    private func independentClone(_ template: SCNNode) -> SCNNode {
        let root = template.clone()
        // Selection and thermal/damage overlays modify materials in place.
        // SceneKit clone() shares them unless the geometry is also copied.
        func detach(_ node: SCNNode) {
            guard let geometry = node.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            node.geometry = geometry
        }
        detach(root)
        root.enumerateChildNodes { node, _ in detach(node) }
        return root
    }
}
