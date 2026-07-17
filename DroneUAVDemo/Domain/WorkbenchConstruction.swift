import Foundation
import simd

/// Flattened CAD construction consumed by the Workbench. Exact exports use
/// the `.uavframe` schema; `.cadasm` files may embed the same object in a
/// `bakedFrame` field.
struct WorkbenchConstruction: Codable, Hashable {
    struct Mesh: Codable, Hashable {
        var vertices: [Float]
        var indices: [UInt32]

        var isRenderable: Bool {
            vertices.count >= 9 && vertices.count % 3 == 0
                && indices.count >= 3 && indices.count % 3 == 0
        }
    }

    struct CollisionProxy: Codable, Hashable {
        var type: String
        var center: CodableVector3D
        var size: CodableVector3D
    }

    struct AttachmentPoint: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var role: String
        var position: CodableVector3D
        var rotation: CodableVector3D

        var resolvedRole: CADAttachmentImport.Role {
            CADAttachmentImport.Role(rawValue: role) ?? .generic
        }
    }

    var format: String
    var version: Int
    var id: String
    var name: String
    var massKg: Double
    var centerOfMass: CodableVector3D
    var boundsMin: CodableVector3D
    var boundsMax: CodableVector3D
    var collisionProxy: CollisionProxy
    var mesh: Mesh
    var attachmentPoints: [AttachmentPoint]

    var isValid: Bool { format == "uavframe" && mesh.isRenderable }

    var dimensionsMeters: SIMD3<Double> {
        SIMD3(abs(boundsMax.x - boundsMin.x),
              abs(boundsMax.y - boundsMin.y),
              abs(boundsMax.z - boundsMin.z))
    }
}

struct WorkbenchConstructionImport: Hashable {
    var construction: WorkbenchConstruction
    var sourceURL: URL
    var isApproximate: Bool
    var notice: String?
}

extension WorkbenchConstruction {
    /// Opens an exact `.uavframe` or a CADNext `.cadasm`. Modern CADNext files
    /// carry `bakedFrame`; older assemblies get an explicit placement-based 3D
    /// proxy so they are still openable and can be assigned a Workbench role.
    static func load(from url: URL) throws -> WorkbenchConstructionImport {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if ext == "uavframe" {
            let construction = try decoder.decode(WorkbenchConstruction.self, from: data)
            guard construction.isValid else { throw WorkbenchConstructionError.invalidFrame }
            return WorkbenchConstructionImport(
                construction: construction, sourceURL: url,
                isApproximate: false, notice: nil)
        }

        guard ext == "cadasm" else { throw WorkbenchConstructionError.unsupportedExtension }
        let envelope = try decoder.decode(CadasmEnvelope.self, from: data)
        guard envelope.format == "cadasm" else { throw WorkbenchConstructionError.notACadasm }

        if let baked = envelope.bakedFrame, baked.isValid {
            return WorkbenchConstructionImport(
                construction: baked, sourceURL: url,
                isApproximate: false, notice: nil)
        }

        // CADNext can also write a sidecar exact export next to an older
        // assembly. Prefer it before creating the compatibility proxy.
        let sidecar = url.deletingPathExtension().appendingPathExtension("uavframe")
        if FileManager.default.fileExists(atPath: sidecar.path),
           let exact = try? load(from: sidecar) {
            return WorkbenchConstructionImport(
                construction: exact.construction, sourceURL: url,
                isApproximate: false,
                notice: "Использована точная 3D-геометрия из \(sidecar.lastPathComponent).")
        }

        guard !envelope.components.isEmpty else {
            throw WorkbenchConstructionError.noBakedFrame
        }
        let proxy = makeAssemblyProxy(envelope: envelope, sourceURL: url)
        return WorkbenchConstructionImport(
            construction: proxy, sourceURL: url,
            isApproximate: true,
            notice: "Сборка открыта в режиме 3D-прокси. Для точной геометрии экспортируйте .uavframe из CADNext или пересохраните сборку новой версией CADNext.")
    }

    static func loadFromCadasm(url: URL) throws -> WorkbenchConstruction {
        try load(from: url).construction
    }

    private struct CadasmEnvelope: Decodable {
        struct Component: Decodable {
            struct Placement: Decodable {
                var tx: Double
                var ty: Double
                var tz: Double
            }

            var id: String
            var name: String
            var placement: Placement
            var visible: Bool?
            var suppressed: Bool?
        }

        var format: String?
        var version: Int?
        var id: String?
        var name: String?
        var bakedFrame: WorkbenchConstruction?
        var components: [Component]

        private enum CodingKeys: String, CodingKey {
            case format, version, id, name, bakedFrame, components
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decodeIfPresent(String.self, forKey: .format)
            version = try c.decodeIfPresent(Int.self, forKey: .version)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            bakedFrame = try c.decodeIfPresent(WorkbenchConstruction.self, forKey: .bakedFrame)
            components = try c.decodeIfPresent([Component].self, forKey: .components) ?? []
        }
    }

    private static func makeAssemblyProxy(
        envelope: CadasmEnvelope,
        sourceURL: URL
    ) -> WorkbenchConstruction {
        let visible = envelope.components.filter { $0.visible != false && $0.suppressed != true }
        let components = visible.isEmpty ? envelope.components : visible
        let positions = components.map {
            SIMD3<Double>($0.placement.tx, $0.placement.ty, $0.placement.tz)
        }
        let span = placementSpan(positions)
        // The proxy part size adapts to assembly spacing and remains visible
        // even when every component is at the origin.
        let componentSize = max(0.018, min(0.085, max(span.x, span.y, span.z) * 0.12))

        var vertices: [Float] = []
        var indices: [UInt32] = []
        for position in positions {
            appendBox(center: position, size: componentSize,
                      vertices: &vertices, indices: &indices)
        }
        if vertices.isEmpty {
            appendBox(center: .zero, size: 0.05, vertices: &vertices, indices: &indices)
        }

        let half = componentSize * 0.5
        let minPoint = positions.reduce(SIMD3<Double>(repeating: .infinity)) {
            simd_min($0, $1 - SIMD3<Double>(repeating: half))
        }
        let maxPoint = positions.reduce(SIMD3<Double>(repeating: -.infinity)) {
            simd_max($0, $1 + SIMD3<Double>(repeating: half))
        }
        let safeMin = minPoint.x.isFinite ? minPoint : SIMD3<Double>(repeating: -half)
        let safeMax = maxPoint.x.isFinite ? maxPoint : SIMD3<Double>(repeating: half)
        let center = (safeMin + safeMax) * 0.5
        let size = safeMax - safeMin
        let estimatedMass = max(0.05, Double(components.count) * 0.025)

        return WorkbenchConstruction(
            format: "uavframe", version: 1,
            id: envelope.id ?? UUID().uuidString,
            name: (envelope.name?.isEmpty == false ? envelope.name : nil)
                ?? sourceURL.deletingPathExtension().lastPathComponent,
            massKg: estimatedMass,
            centerOfMass: CodableVector3D(x: center.x, y: center.y, z: center.z),
            boundsMin: CodableVector3D(x: safeMin.x, y: safeMin.y, z: safeMin.z),
            boundsMax: CodableVector3D(x: safeMax.x, y: safeMax.y, z: safeMax.z),
            collisionProxy: CollisionProxy(
                type: "box",
                center: CodableVector3D(x: center.x, y: center.y, z: center.z),
                size: CodableVector3D(x: size.x, y: size.y, z: size.z)),
            mesh: Mesh(vertices: vertices, indices: indices),
            attachmentPoints: [])
    }

    private static func placementSpan(_ points: [SIMD3<Double>]) -> SIMD3<Double> {
        guard let first = points.first else { return .zero }
        var lo = first
        var hi = first
        for point in points.dropFirst() {
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        return hi - lo
    }

    private static func appendBox(
        center: SIMD3<Double>,
        size: Double,
        vertices: inout [Float],
        indices: inout [UInt32]
    ) {
        let h = size * 0.5
        let corners = [
            SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
            SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h),
        ].map { $0 + center }
        let base = UInt32(vertices.count / 3)
        for p in corners {
            vertices.append(contentsOf: [Float(p.x), Float(p.y), Float(p.z)])
        }
        let faces: [UInt32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2,
            0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
        ]
        indices.append(contentsOf: faces.map { $0 + base })
    }
}

enum WorkbenchConstructionError: LocalizedError {
    case unsupportedExtension
    case notACadasm
    case noBakedFrame
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension:
            return "Поддерживаются сборки .cadasm и конструкции .uavframe."
        case .notACadasm:
            return "Файл не является сборкой CADNext (.cadasm)."
        case .noBakedFrame:
            return "В сборке нет отображаемой геометрии. Экспортируйте конструкцию .uavframe из CADNext."
        case .invalidFrame:
            return "Конструкция .uavframe повреждена или не содержит треугольной сетки."
        }
    }
}
