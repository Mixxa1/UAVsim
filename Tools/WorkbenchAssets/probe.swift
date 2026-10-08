import AppKit
import SceneKit
import Foundation
import simd

// Scene-only stand-ins keep the headless probe independent of the app UI.
enum WorkbenchCategory: Hashable {
    case overview, validation, blueprints, frame, radio
    case slot(WorkbenchComponentKind)
}
struct DroneVisualModel {
    let rootNode: SCNNode
    let propellerNodes: [SCNNode]
    let propellerSpinDirections: [Float]
    let componentNodes: [DamageComponent: [SCNNode]]
    let fpvAnchorNode: SCNNode
    let payloadMountNode: SCNNode
}

struct Manifest: Decodable {
    struct Entry: Decodable {
        let id: String
        let kind: String
        let catalogSizeM: [Double]
        let boundsMinM: [Double]
        let boundsMaxM: [Double]
    }
    let models: [Entry]
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func geometries(_ node: SCNNode) -> [SCNGeometry] {
    var result: [SCNGeometry] = node.geometry.map { [$0] } ?? []
    node.enumerateChildNodes { n, _ in if let g = n.geometry { result.append(g) } }
    return result
}
func approx(_ a: Float, _ b: Double) -> Bool { abs(Double(a) - b) < 0.00001 }

@main
enum WorkbenchAssetProbe {
static func main() throws {
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
let library = WorkbenchModelAssetLibrary.shared
let ids = Set(WorkbenchComponentLibrary.all.map(\.id) + WorkbenchFrameLibrary.all.map(\.id))
let extraIDs = Set(WorkbenchFrameLibrary.all.filter { $0.architecture != .multicopter }
    .flatMap { [$0.id + "-wing", $0.id + "-fuselage"] })
require(library.coveredIDs == ids.union(extraIDs), "Missing/extra native catalog models")
require(manifest.models.count == library.coveredIDs.count, "Manifest mismatch")
var totalMeshes = 0
var textureTypes: Set<String> = []
for entry in manifest.models {
    autoreleasepool {
        guard let node = library.node(for: entry.id) else { fatalError("Cannot import \(entry.id)") }
        let b = node.boundingBox
        let lo = [Float(b.min.x), Float(b.min.y), Float(b.min.z)]
        let hi = [Float(b.max.x), Float(b.max.y), Float(b.max.z)]
        require(zip(lo, entry.boundsMinM).allSatisfy { approx($0, $1) }, "Incorrect minimum/scale: \(entry.id)")
        require(zip(hi, entry.boundsMaxM).allSatisfy { approx($0, $1) }, "Incorrect maximum/scale: \(entry.id)")
        let gs = geometries(node)
        require(!gs.isEmpty, "Empty native model \(entry.id)")
        totalMeshes += gs.count
        for g in gs {
            require(g.sources(for: .normal).first != nil, "Missing imported normals \(entry.id)")
            for mat in g.materials {
                require(mat.lightingModel == .physicallyBased, "Non-PBR material \(entry.id)")
                if let contents = mat.diffuse.contents { textureTypes.insert(String(describing: type(of: contents))) }
            }
        }
        if let spec = WorkbenchComponentLibrary.spec(id: entry.id) {
            let actual = [spec.proxy.size.x, spec.proxy.size.y, spec.proxy.size.z]
            require(actual == entry.catalogSizeM, "Python/native component dimension mismatch \(entry.id)")
            require(WorkbenchModelBuilder.componentNode(spec).name?.hasPrefix("workbench.asset.") == true,
                    "Factory did not use USDZ: \(entry.id)")
        } else if let spec = WorkbenchFrameLibrary.spec(id: entry.id) {
            let actual = [spec.sizeMeters.x, spec.sizeMeters.y, spec.sizeMeters.z]
            require(actual == entry.catalogSizeM, "Python/native frame dimension mismatch \(entry.id)")
            require(WorkbenchModelBuilder.previewNode(for: spec).name?.hasPrefix("workbench.asset.") == true,
                    "Frame preview did not use USDZ: \(entry.id)")
        }
    }
}

// A highlight on one instance cannot change a cached template or another model.
let motor = WorkbenchComponentLibrary.components(of: .motor)[7]
let a = library.componentNode(for: motor)!
let b = library.componentNode(for: motor)!
let ga = geometries(a)[0], gb = geometries(b)[0]
require(ga !== gb && ga.materials[0] !== gb.materials[0], "Instances share mutable geometry/materials")
let original = gb.materials[0].emission.contents
ga.materials[0].emission.contents = NSColor.red
require(!(gb.materials[0].emission.contents as AnyObject === NSColor.red), "Highlight leaked between instances")
gb.materials[0].emission.contents = original
var resized = motor
resized.proxy.size = CodableVector3D(x: resized.proxy.size.x * 1.1, y: resized.proxy.size.y, z: resized.proxy.size.z)
require(library.componentNode(for: resized) == nil, "Resized part incorrectly uses catalog USDZ")
var retuned = motor
retuned.params[WorkbenchComponentSpec.ParamKey.motorStatorMm] = 42
require(library.componentNode(for: retuned) == nil, "Custom parameters incorrectly use catalog USDZ")
var imported = motor
imported.importedMesh = .init(vertices: [0, 0, 0, 0.1, 0, 0, 0, 0.1, 0], indices: [0, 1, 2])
require(library.componentNode(for: imported) == nil, "CAD part incorrectly uses catalog USDZ")
require(WorkbenchModelAssetLibrary(directory: nil).node(for: motor.id) == nil, "Missing-library fallback broken")

for build in [WorkbenchBuild.defaultQuad(), .defaultFixedWing(), .defaultVTOL()] {
    let assembled = WorkbenchModelBuilder.aircraftNode(for: build, showsHotspots: false)
    let motors = assembled.childNodes.filter { $0.name?.hasPrefix("workbench.slot.motor.") == true }
    var motorCount = motors.count, propCount = 0
    assembled.enumerateChildNodes { n, _ in
        if n.name?.hasPrefix("workbench.slot.propeller.") == true { propCount += 1 }
        if build.resolvedFrame.architecture != .multicopter,
           n.name?.hasPrefix("workbench.slot.motor.") == true { motorCount += 1 }
    }
    require(motorCount == build.resolvedFrame.motorMounts.count, "Motor mount count changed")
    require(propCount == build.resolvedFrame.motorMounts.count, "Propeller pivot count changed")
    require(assembled.childNode(withName: "workbench.frame", recursively: true) != nil, "Frame slot missing")
}

print("PASS: \(manifest.models.count) USDZ assets match the native catalog; \(totalMeshes) meshes imported at metre scale.")
print("PASS: catalog factory uses USDZ; imported/custom fallback and independent materials work.")
print("PASS: quad, fixed-wing and VTOL assembly motor/propeller slot contracts preserved.")
print("Native diffuse content types: \(textureTypes.sorted())")
}
}
