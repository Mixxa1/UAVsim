import Foundation

struct DesignAsset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: DesignAssetKind
    var transform: DesignTransform
    var material: DesignMaterial
    var attachmentPoints: [AttachmentPoint]
    var massProperties: DesignMassProperties

    init(
        id: UUID = UUID(),
        name: String,
        kind: DesignAssetKind,
        transform: DesignTransform = .identity,
        material: DesignMaterial = .carbonFiber
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.transform = transform
        self.material = material
        self.attachmentPoints = DesignAsset.defaultAttachmentPoints(for: kind)
        self.massProperties = DesignAsset.computeMassProperties(kind: kind, material: material)
    }

    mutating func updateDerivedProperties() {
        massProperties = DesignAsset.computeMassProperties(kind: kind, material: material)
        syncSystemAttachmentPoints()
    }

    mutating func resetSystemAttachmentPoints() {
        syncSystemAttachmentPoints(resetSystemMetadata: true)
    }

    mutating func syncSystemAttachmentPoints(resetSystemMetadata: Bool = false) {
        let currentPoints = attachmentPoints
        let customPoints = currentPoints.filter { !$0.isSystem }
        let currentSystemByName = Dictionary(
            uniqueKeysWithValues: currentPoints.filter(\.isSystem).map { ($0.name, $0) }
        )

        let syncedSystemPoints = DesignAsset.defaultAttachmentPoints(for: kind).map { generated -> AttachmentPoint in
            guard let existing = currentSystemByName[generated.name] else {
                return generated
            }

            var point = generated
            point.id = existing.id
            point.isEnabled = existing.isEnabled
            if !resetSystemMetadata {
                point.role = existing.role
            }
            return point
        }

        attachmentPoints = syncedSystemPoints + customPoints
    }

    static func defaultAttachmentPoints(for kind: DesignAssetKind) -> [AttachmentPoint] {
        switch kind {
        case let .basicWing(p):
            // CAD coordinate system: X=span, Y=thickness, Z=chord
            let hs = p.spanMeters / 2
            let ht = p.thicknessMeters / 2
            let rootCenterZ = p.rootChordMeters / 2
            let tipCenterZ = (hs * tan(p.sweepDegrees * .pi / 180.0)) + p.tipChordMeters / 2
            let tipY = hs * tan(p.dihedralDegrees * .pi / 180.0)
            return [
                AttachmentPoint(name: "wing_root_center",       localX: 0,       localY: 0,          localZ: rootCenterZ, role: .wing),
                AttachmentPoint(name: "wing_tip_left",          localX: -hs,     localY: tipY,       localZ: tipCenterZ,  role: .wing),
                AttachmentPoint(name: "wing_tip_right",         localX: hs,      localY: tipY,       localZ: tipCenterZ,  role: .wing),
                AttachmentPoint(name: "underwing_left_optional", localX: -hs * 0.35, localY: -ht - 0.01, localZ: rootCenterZ, role: .payload),
                AttachmentPoint(name: "underwing_right_optional", localX: hs * 0.35, localY: -ht - 0.01, localZ: rootCenterZ, role: .payload),
            ]
        case let .framePlate(p):
            let hw = p.widthMeters / 2
            let hd = p.depthMeters / 2
            let ht = p.thicknessMeters / 2
            return [
                AttachmentPoint(name: "top_center",    localX: 0,   localY: ht,  localZ: 0,   role: .frame),
                AttachmentPoint(name: "bottom_center", localX: 0,   localY: -ht, localZ: 0,   role: .frame),
                AttachmentPoint(name: "front_edge",    localX: 0,   localY: 0,   localZ: -hd, role: .frame),
                AttachmentPoint(name: "rear_edge",     localX: 0,   localY: 0,   localZ: hd,  role: .frame),
                AttachmentPoint(name: "left_edge",     localX: -hw, localY: 0,   localZ: 0,   role: .frame),
                AttachmentPoint(name: "right_edge",    localX: hw,  localY: 0,   localZ: 0,   role: .frame),
            ]
        case let .beam(p):
            let hl = p.lengthMeters / 2
            return [
                AttachmentPoint(name: "start",  localX: -hl, localY: 0, localZ: 0, role: .frame),
                AttachmentPoint(name: "end",    localX: hl,  localY: 0, localZ: 0, role: .frame),
                AttachmentPoint(name: "center", localX: 0,   localY: 0, localZ: 0, role: .frame),
            ]
        case let .tube(p):
            // Tube lies along X axis (length = width)
            let hl = p.lengthMeters / 2
            return [
                AttachmentPoint(name: "start",  localX: -hl, localY: 0, localZ: 0, role: .frame),
                AttachmentPoint(name: "end",    localX: hl,  localY: 0, localZ: 0, role: .frame),
                AttachmentPoint(name: "center", localX: 0,   localY: 0, localZ: 0, role: .frame),
            ]
        case let .mountBracket(p):
            let halfHeight = (p.plateThicknessMeters + p.armLengthMeters) / 2
            return [
                AttachmentPoint(name: "top_mount",           localX: 0, localY: halfHeight,  localZ: 0, role: .frame),
                AttachmentPoint(name: "bottom_mount",        localX: 0, localY: -halfHeight, localZ: 0, role: .frame),
                AttachmentPoint(name: "side_mount_optional", localX: p.plateWidthMeters / 2, localY: 0, localZ: 0, role: .frame),
            ]
        case let .payloadBox(p):
            let hh = p.heightMeters / 2
            let hd = p.depthMeters / 2
            return [
                AttachmentPoint(name: "top_mount",                   localX: 0, localY: hh,  localZ: 0,   role: .payload),
                AttachmentPoint(name: "bottom_mount",                localX: 0, localY: -hh, localZ: 0,   role: .payload),
                AttachmentPoint(name: "front_sensor_mount_optional", localX: 0, localY: 0,   localZ: -hd, role: .sensor),
                AttachmentPoint(name: "rear_mount_optional",         localX: 0, localY: 0,   localZ: hd,  role: .payload),
            ]
        case .sketch2D:
            return []

        case .extrudedSolid:
            return []
        }
    }

    static func computeMassProperties(kind: DesignAssetKind, material: DesignMaterial) -> DesignMassProperties {
        let density = material.densityKgPerM3
        let volume: Double
        // bw = X extent (span/width), bh = Y extent (thickness/height), bd = Z extent (chord/depth)
        let bw: Double
        let bh: Double
        let bd: Double

        switch kind {
        case let .basicWing(p):
            let trapezoidArea = p.spanMeters * (p.rootChordMeters + p.tipChordMeters) / 2.0
            let solidVolume = trapezoidArea * p.thicknessMeters
            volume = solidVolume * p.constructionType.constructionFactor
            bw = p.spanMeters
            bh = p.thicknessMeters
            bd = p.rootChordMeters

        case let .framePlate(p):
            volume = p.widthMeters * p.depthMeters * p.thicknessMeters
            bw = p.widthMeters
            bh = p.thicknessMeters
            bd = p.depthMeters

        case let .beam(p):
            volume = p.lengthMeters * p.widthMeters * p.heightMeters
            bw = p.lengthMeters
            bh = p.heightMeters
            bd = p.widthMeters

        case let .tube(p):
            let outerArea = Double.pi * p.outerRadiusMeters * p.outerRadiusMeters
            let innerArea = Double.pi * p.innerRadiusMeters * p.innerRadiusMeters
            volume = (outerArea - innerArea) * p.lengthMeters
            bw = p.lengthMeters
            bh = p.outerRadiusMeters * 2
            bd = p.outerRadiusMeters * 2

        case let .mountBracket(p):
            let plateVol = p.plateWidthMeters * p.plateDepthMeters * p.plateThicknessMeters
            let armVol = p.armLengthMeters * p.armThicknessMeters * p.armThicknessMeters
            volume = plateVol + armVol
            bw = p.plateWidthMeters
            bh = p.armLengthMeters + p.plateThicknessMeters
            bd = p.plateDepthMeters

        case let .payloadBox(p):
            let wallT = 0.003
            let outerVol = p.widthMeters * p.heightMeters * p.depthMeters
            let innerVol = max(0, (p.widthMeters - wallT * 2) * (p.heightMeters - wallT * 2) * (p.depthMeters - wallT * 2))
            volume = outerVol - innerVol
            bw = p.widthMeters
            bh = p.heightMeters
            bd = p.depthMeters

        case let .sketch2D(p):
            let bounds = p.sketch.bounds3D()
            let centroid = p.sketch.centroid3D()
            return DesignMassProperties(
                massKg: 0,
                centerOfMassX: centroid.x,
                centerOfMassY: centroid.y,
                centerOfMassZ: centroid.z,
                boundingWidth: bounds.width,
                boundingHeight: bounds.height,
                boundingDepth: bounds.depth,
                dragPenalty: 0,
                structuralRating: 1.0
            )

        case let .extrudedSolid(p):
            let vol = p.volumeMeters3
            let mass = max(0, vol * density)
            guard let bounds = extrudedSolidBounds(p) else {
                return DesignMassProperties(massKg: mass, centerOfMassX: 0, centerOfMassY: 0, centerOfMassZ: 0,
                                            boundingWidth: 0.1, boundingHeight: 0.1, boundingDepth: 0.1, dragPenalty: 0, structuralRating: 1.0)
            }
            let ew = max(bounds.maximum.x - bounds.minimum.x, 0.001)
            let eh = max(bounds.maximum.y - bounds.minimum.y, 0.001)
            let ed = max(bounds.maximum.z - bounds.minimum.z, 0.001)
            return DesignMassProperties(
                massKg: mass,
                centerOfMassX: bounds.center.x,
                centerOfMassY: bounds.center.y,
                centerOfMassZ: bounds.center.z,
                boundingWidth: ew, boundingHeight: eh, boundingDepth: ed,
                dragPenalty: min(1.0, ew * eh * 0.1), structuralRating: 1.0
            )
        }

        let mass = max(0.001, volume * density)
        let dragPenalty = min(1.0, bw * bh * 0.1)

        return DesignMassProperties(
            massKg: mass,
            centerOfMassX: 0,
            centerOfMassY: 0,
            centerOfMassZ: 0,
            boundingWidth: bw,
            boundingHeight: bh,
            boundingDepth: bd,
            dragPenalty: dragPenalty,
            structuralRating: 1.0
        )
    }

    private static func extrudedSolidVertices(_ p: ExtrudedSolidParameters) -> [DesignVector3] {
        if let meshVertices = p.kernelVisualMesh?.vertices,
           !meshVertices.isEmpty {
            return meshVertices
        }
        return p.vertices()
    }

    private static func extrudedSolidBounds(
        _ p: ExtrudedSolidParameters
    ) -> (minimum: DesignVector3, maximum: DesignVector3, center: DesignVector3)? {
        let vertices = extrudedSolidVertices(p)
        guard !vertices.isEmpty else { return nil }

        let minX = vertices.map(\.x).min() ?? 0
        let maxX = vertices.map(\.x).max() ?? 0
        let minY = vertices.map(\.y).min() ?? 0
        let maxY = vertices.map(\.y).max() ?? 0
        let minZ = vertices.map(\.z).min() ?? 0
        let maxZ = vertices.map(\.z).max() ?? 0
        let center = DesignVector3(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2,
            z: (minZ + maxZ) / 2
        )
        return (
            minimum: DesignVector3(x: minX, y: minY, z: minZ),
            maximum: DesignVector3(x: maxX, y: maxY, z: maxZ),
            center: center
        )
    }
}
