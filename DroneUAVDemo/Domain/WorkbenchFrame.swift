import Foundation
import simd

enum WorkbenchFrameClass: String, Codable, CaseIterable, Hashable {
    case tinyWhoop
    case fiveInch
    case sevenInch
    case cinematic

    var displayName: String {
        switch self {
        case .tinyWhoop: return "Tiny Whoop"
        case .fiveInch: return "5\" фристайл"
        case .sevenInch: return "7\" дальнолёт"
        case .cinematic: return "Cinematic"
        }
    }
}

/// A frame from the built-in library: defines the mount slots (motor arms,
/// battery tray, FC bay, camera) that equipment snaps into, plus the size
/// and mass that drive physics. Geometry is built procedurally by
/// `WorkbenchModelBuilder` from `motorMounts` + `armLengthM`.
struct WorkbenchFrameSpec: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var frameClass: WorkbenchFrameClass
    var armCount: Int
    var motorMounts: [CodableVector3D] // frame space, metres
    var armLengthM: Double
    var propMaxInch: Double
    var motorStatorMaxMm: Double
    var batteryTray: CodableVector3D
    var fcBay: CodableVector3D
    var cameraMount: CodableVector3D
    var massKg: Double
    var sizeMeters: CodableVector3D
}

/// Where a build's frame comes from: the built-in library or an imported
/// CADNext assembly (baked geometry + mount points from attachment points).
enum WorkbenchFrameSource: Codable, Hashable {
    case library(id: String)
    case imported(WorkbenchConstruction)
}

/// A frame resolved to the uniform data the analyzer, model builder and
/// synthesizer consume — regardless of whether it is a library frame or an
/// imported CADNext airframe.
struct WorkbenchResolvedFrame: Hashable {
    var name: String
    var frameClass: WorkbenchFrameClass
    var motorMounts: [SIMD3<Float>]
    var armLengthM: Double
    var propMaxInch: Double
    var motorStatorMaxMm: Double
    var batteryTray: SIMD3<Float>
    var fcBay: SIMD3<Float>
    var cameraMount: SIMD3<Float>
    var massKg: Double
    var sizeMeters: SIMD3<Double>
    /// Present for imported CADNext frames (rendered as-is); nil for library
    /// frames (procedural geometry).
    var importedMesh: WorkbenchConstruction.Mesh?
}

extension WorkbenchFrameSource {
    func resolve() -> WorkbenchResolvedFrame {
        switch self {
        case let .library(id):
            let spec = WorkbenchFrameLibrary.spec(id: id) ?? WorkbenchFrameLibrary.defaultFrame
            return WorkbenchResolvedFrame(
                name: spec.name,
                frameClass: spec.frameClass,
                motorMounts: spec.motorMounts.map { $0.simdFloat },
                armLengthM: spec.armLengthM,
                propMaxInch: spec.propMaxInch,
                motorStatorMaxMm: spec.motorStatorMaxMm,
                batteryTray: spec.batteryTray.simdFloat,
                fcBay: spec.fcBay.simdFloat,
                cameraMount: spec.cameraMount.simdFloat,
                massKg: spec.massKg,
                sizeMeters: spec.sizeMeters.simd,
                importedMesh: nil)
        case let .imported(construction):
            // CADNext exports Z-up coordinates; SceneKit uses Y-up. Keep one
            // conversion here for all snap points and convert the mesh in the
            // model builder with the same mapping: (x, y, z) -> (x, z, -y).
            let motorPoints = construction.attachmentPoints
                .filter { $0.resolvedRole == .motor }
                .map { cadToScene($0.position.simdFloat) }
            let battery = construction.attachmentPoints.first { $0.resolvedRole == .battery }
            let camera = construction.attachmentPoints.first { $0.resolvedRole == .camera }
            let cadDims = construction.dimensionsMeters
            let dims = SIMD3<Double>(cadDims.x, cadDims.z, cadDims.y)
            let armLen = max(cadDims.x, cadDims.y) * 0.5
            let mounts = motorPoints.isEmpty
                ? defaultQuadMounts(arm: Float(max(armLen, 0.1)))
                : motorPoints
            let propMax = max(1.6, armLen * 39.37 * 0.92)
            let inferredClass: WorkbenchFrameClass
            if propMax <= 2.0 {
                inferredClass = .tinyWhoop
            } else if propMax <= 5.8 {
                inferredClass = .fiveInch
            } else if propMax <= 8.2 {
                inferredClass = .sevenInch
            } else {
                inferredClass = .cinematic
            }
            return WorkbenchResolvedFrame(
                name: construction.name.isEmpty ? "Импортированная рама" : construction.name,
                frameClass: inferredClass,
                motorMounts: mounts,
                armLengthM: armLen,
                propMaxInch: propMax,
                motorStatorMaxMm: propMax <= 2 ? 10 : propMax <= 6 ? 32 : 55,
                batteryTray: battery.map { cadToScene($0.position.simdFloat) }
                    ?? SIMD3<Float>(0, Float(max(dims.y * 0.18, 0.02)), 0),
                fcBay: SIMD3<Float>(0, 0, 0),
                cameraMount: camera.map { cadToScene($0.position.simdFloat) }
                    ?? SIMD3<Float>(0, 0.01, Float(dims.z) * 0.35),
                massKg: construction.massKg,
                sizeMeters: dims,
                importedMesh: construction.mesh.isRenderable ? construction.mesh : nil)
        }
    }

    private func defaultQuadMounts(arm: Float) -> [SIMD3<Float>] {
        let a = arm * 0.7071
        return [SIMD3(a, 0, a), SIMD3(-a, 0, a), SIMD3(-a, 0, -a), SIMD3(a, 0, -a)]
    }

    private func cadToScene(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.x, p.z, -p.y)
    }
}

enum WorkbenchFrameLibrary {
    static let all: [WorkbenchFrameSpec] = [fiveInch, sevenInch, tinyWhoop, cinematic]

    static func spec(id: String) -> WorkbenchFrameSpec? { all.first { $0.id == id } }

    static var defaultFrame: WorkbenchFrameSpec { fiveInch }

    private static func quadMounts(arm: Double) -> [CodableVector3D] {
        let a = arm * 0.7071
        return [
            CodableVector3D(x: a, y: 0, z: a), CodableVector3D(x: -a, y: 0, z: a),
            CodableVector3D(x: -a, y: 0, z: -a), CodableVector3D(x: a, y: 0, z: -a),
        ]
    }

    static let fiveInch = WorkbenchFrameSpec(
        id: "frame-5inch-freestyle", name: "5\" фристайл-рама", frameClass: .fiveInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.11), armLengthM: 0.11,
        propMaxInch: 5.1, motorStatorMaxMm: 24,
        batteryTray: CodableVector3D(x: 0, y: 0.02, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.006, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.012, z: 0.05),
        massKg: 0.11, sizeMeters: CodableVector3D(x: 0.22, y: 0.05, z: 0.22))

    static let sevenInch = WorkbenchFrameSpec(
        id: "frame-7inch-lr", name: "7\" дальнолёт-рама", frameClass: .sevenInch,
        armCount: 4, motorMounts: quadMounts(arm: 0.16), armLengthM: 0.16,
        propMaxInch: 7.1, motorStatorMaxMm: 30,
        batteryTray: CodableVector3D(x: 0, y: 0.028, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.008, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.016, z: 0.07),
        massKg: 0.16, sizeMeters: CodableVector3D(x: 0.32, y: 0.07, z: 0.32))

    static let tinyWhoop = WorkbenchFrameSpec(
        id: "frame-tinywhoop", name: "Tiny Whoop 65 мм", frameClass: .tinyWhoop,
        armCount: 4, motorMounts: quadMounts(arm: 0.031), armLengthM: 0.031,
        propMaxInch: 1.6, motorStatorMaxMm: 9,
        batteryTray: CodableVector3D(x: 0, y: 0.006, z: -0.01),
        fcBay: CodableVector3D(x: 0, y: 0.002, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.006, z: 0.015),
        massKg: 0.020, sizeMeters: CodableVector3D(x: 0.08, y: 0.03, z: 0.08))

    static let cinematic = WorkbenchFrameSpec(
        id: "frame-cine", name: "Cinematic 6\"", frameClass: .cinematic,
        armCount: 4, motorMounts: quadMounts(arm: 0.135), armLengthM: 0.135,
        propMaxInch: 6.1, motorStatorMaxMm: 32,
        batteryTray: CodableVector3D(x: 0, y: 0.03, z: 0),
        fcBay: CodableVector3D(x: 0, y: 0.008, z: 0),
        cameraMount: CodableVector3D(x: 0, y: 0.02, z: 0.06),
        massKg: 0.19, sizeMeters: CodableVector3D(x: 0.27, y: 0.08, z: 0.27))
}
