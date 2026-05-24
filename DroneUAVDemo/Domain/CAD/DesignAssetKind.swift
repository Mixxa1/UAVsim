import Foundation

// MARK: - Wing Construction

enum WingConstructionType: String, Codable, CaseIterable, Identifiable {
    case solid
    case foamCore
    case hollowComposite
    case ribAndSkin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solid:            return NSLocalizedString("cad.construction.solid", comment: "")
        case .foamCore:         return NSLocalizedString("cad.construction.foam_core", comment: "")
        case .hollowComposite:  return NSLocalizedString("cad.construction.hollow_composite", comment: "")
        case .ribAndSkin:       return NSLocalizedString("cad.construction.rib_and_skin", comment: "")
        }
    }

    // Fraction of solid volume used in mass estimate
    var constructionFactor: Double {
        switch self {
        case .solid:            return 1.00
        case .foamCore:         return 0.12
        case .hollowComposite:  return 0.18
        case .ribAndSkin:       return 0.22
        }
    }
}

// MARK: - Parameter structs

struct BasicWingParameters: Codable, Equatable {
    var spanMeters: Double = 1.0
    var rootChordMeters: Double = 0.20
    var tipChordMeters: Double = 0.12
    var thicknessMeters: Double = 0.025
    var sweepDegrees: Double = 5.0
    var dihedralDegrees: Double = 3.0
    var constructionType: WingConstructionType = .hollowComposite
}

struct FramePlateParameters: Codable, Equatable {
    var widthMeters: Double = 0.30
    var depthMeters: Double = 0.20
    var thicknessMeters: Double = 0.004
}

struct BeamParameters: Codable, Equatable {
    var lengthMeters: Double = 0.40
    var widthMeters: Double = 0.020
    var heightMeters: Double = 0.020
}

struct TubeParameters: Codable, Equatable {
    var lengthMeters: Double = 0.40
    var outerRadiusMeters: Double = 0.012
    var innerRadiusMeters: Double = 0.009
}

struct MountBracketParameters: Codable, Equatable {
    var plateWidthMeters: Double = 0.080
    var plateDepthMeters: Double = 0.080
    var plateThicknessMeters: Double = 0.003
    var armLengthMeters: Double = 0.060
    var armThicknessMeters: Double = 0.005
}

struct PayloadBoxParameters: Codable, Equatable {
    var widthMeters: Double = 0.10
    var heightMeters: Double = 0.06
    var depthMeters: Double = 0.08
}

// MARK: - Sketch

enum SketchPlane: String, Codable, CaseIterable, Identifiable {
    case xy
    case xz
    case yz

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xy: return "XY"
        case .xz: return "XZ"
        case .yz: return "YZ"
        }
    }

    var viewName: String {
        switch self {
        case .xy: return NSLocalizedString("cad.sketch.plane.xy_view", comment: "")
        case .xz: return NSLocalizedString("cad.sketch.plane.xz_view", comment: "")
        case .yz: return NSLocalizedString("cad.sketch.plane.yz_view", comment: "")
        }
    }

    var uAxisName: String {
        switch self {
        case .xy, .xz: return "X"
        case .yz: return "Z"
        }
    }

    var vAxisName: String {
        switch self {
        case .xy, .yz: return "Y"
        case .xz: return "Z"
        }
    }

    func point3D(from point: SketchPoint2D, planeOffsetMeters: Double) -> DesignVector3 {
        sketchPointToWorld(point, reference: .canonicalPlane(self, offsetMeters: planeOffsetMeters))
    }

    func point2D(from point: DesignVector3, planeOffsetMeters: Double) -> SketchPoint2D {
        worldPointToSketch(point, reference: .canonicalPlane(self, offsetMeters: planeOffsetMeters))
    }
}

struct PlanarFaceReference: Codable, Equatable {
    var sourceAssetID: UUID
    var faceID: UUID
    /// Coordinate anchor — first vertex of the face (used for U/V math and ray-plane intersection).
    var origin: DesignVector3
    var normal: DesignVector3
    var uAxis: DesignVector3
    var vAxis: DesignVector3
    /// Geometric center of the face (used for camera target and plane overlay placement).
    var faceCenter: DesignVector3

    init(
        sourceAssetID: UUID,
        faceID: UUID,
        origin: DesignVector3,
        normal: DesignVector3,
        uAxis: DesignVector3,
        vAxis: DesignVector3,
        faceCenter: DesignVector3? = nil
    ) {
        self.sourceAssetID = sourceAssetID
        self.faceID = faceID
        self.origin = origin
        self.normal = normal
        self.uAxis = uAxis
        self.vAxis = vAxis
        self.faceCenter = faceCenter ?? origin
    }

    private enum CodingKeys: String, CodingKey {
        case sourceAssetID, faceID, origin, normal, uAxis, vAxis, faceCenter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceAssetID = try c.decode(UUID.self, forKey: .sourceAssetID)
        faceID        = try c.decode(UUID.self, forKey: .faceID)
        origin        = try c.decode(DesignVector3.self, forKey: .origin)
        normal        = try c.decode(DesignVector3.self, forKey: .normal)
        uAxis         = try c.decode(DesignVector3.self, forKey: .uAxis)
        vAxis         = try c.decode(DesignVector3.self, forKey: .vAxis)
        faceCenter    = try c.decodeIfPresent(DesignVector3.self, forKey: .faceCenter) ?? origin
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceAssetID, forKey: .sourceAssetID)
        try c.encode(faceID,        forKey: .faceID)
        try c.encode(origin,        forKey: .origin)
        try c.encode(normal,        forKey: .normal)
        try c.encode(uAxis,         forKey: .uAxis)
        try c.encode(vAxis,         forKey: .vAxis)
        try c.encode(faceCenter,    forKey: .faceCenter)
    }
}

enum SketchReference: Codable, Equatable {
    case canonicalPlane(SketchPlane, offsetMeters: Double)
    case planarFace(PlanarFaceReference)

    var plane: SketchPlane {
        switch self {
        case let .canonicalPlane(plane, _):
            return plane
        case let .planarFace(face):
            return SketchReference.closestCanonicalPlane(to: face.normal)
        }
    }

    var planeOffsetMeters: Double {
        switch self {
        case let .canonicalPlane(_, offsetMeters):
            return offsetMeters
        case let .planarFace(face):
            return face.origin.dot(normalVector(for: self))
        }
    }

    var displayName: String {
        switch self {
        case let .canonicalPlane(plane, _):
            return plane.displayName
        case .planarFace:
            return NSLocalizedString("cad.sketch.reference.face", comment: "")
        }
    }

    var uAxisName: String {
        switch self {
        case let .canonicalPlane(plane, _):
            return plane.uAxisName
        case .planarFace:
            return "U"
        }
    }

    var vAxisName: String {
        switch self {
        case let .canonicalPlane(plane, _):
            return plane.vAxisName
        case .planarFace:
            return "V"
        }
    }

    var isCanonical: Bool {
        if case .canonicalPlane = self { return true }
        return false
    }

    private static func closestCanonicalPlane(to normal: DesignVector3) -> SketchPlane {
        let n = normal.normalized()
        let candidates: [(SketchPlane, Double)] = [
            (.xy, abs(n.dot(.zAxis))),
            (.xz, abs(n.dot(.yAxis))),
            (.yz, abs(n.dot(.xAxis))),
        ]
        return candidates.max(by: { $0.1 < $1.1 })?.0 ?? .xz
    }
}

func originForSketchReference(_ reference: SketchReference) -> DesignVector3 {
    switch reference {
    case let .canonicalPlane(plane, offsetMeters):
        switch plane {
        case .xy:
            return DesignVector3(x: 0, y: 0, z: offsetMeters)
        case .xz:
            return DesignVector3(x: 0, y: offsetMeters, z: 0)
        case .yz:
            return DesignVector3(x: offsetMeters, y: 0, z: 0)
        }
    case let .planarFace(face):
        return face.origin
    }
}

func axesForSketchReference(
    _ reference: SketchReference
) -> (u: DesignVector3, v: DesignVector3, normal: DesignVector3) {
    switch reference {
    case let .canonicalPlane(plane, _):
        switch plane {
        case .xy:
            return (.xAxis, .yAxis, .zAxis)
        case .xz:
            return (.xAxis, .zAxis, .yAxis)
        case .yz:
            return (.zAxis, .yAxis, .xAxis)
        }
    case let .planarFace(face):
        let normal = face.normal.normalized(fallback: .zAxis)
        let u = face.uAxis.normalized(fallback: .xAxis)
        let v = face.vAxis.normalized(fallback: normal.cross(u).normalized(fallback: .yAxis))
        return (u, v, normal)
    }
}

func normalVector(for reference: SketchReference) -> DesignVector3 {
    axesForSketchReference(reference).normal
}

func sketchPointToWorld(
    _ point: SketchPoint2D,
    reference: SketchReference
) -> DesignVector3 {
    let origin = originForSketchReference(reference)
    let axes = axesForSketchReference(reference)
    return origin + axes.u * point.u + axes.v * point.v
}

func worldPointToSketch(
    _ point: DesignVector3,
    reference: SketchReference
) -> SketchPoint2D {
    let origin = originForSketchReference(reference)
    let axes = axesForSketchReference(reference)
    let delta = point - origin
    return SketchPoint2D(u: delta.dot(axes.u), v: delta.dot(axes.v))
}

func offsetWorldPoint(
    _ point: SketchPoint2D,
    reference: SketchReference,
    normalOffsetMeters: Double
) -> DesignVector3 {
    sketchPointToWorld(point, reference: reference) + normalVector(for: reference) * normalOffsetMeters
}

struct DesignFaceBounds: Codable, Equatable {
    var minU: Double
    var maxU: Double
    var minV: Double
    var maxV: Double
}

struct DesignPlanarFace: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var assetID: UUID
    var origin: DesignVector3
    var normal: DesignVector3
    var uAxis: DesignVector3
    var vAxis: DesignVector3
    var bounds: DesignFaceBounds

    /// Geometric center of the face in world space.
    var center: DesignVector3 {
        let uMid: Double = (bounds.minU + bounds.maxU) / 2
        let vMid: Double = (bounds.minV + bounds.maxV) / 2
        let uOffset: DesignVector3 = uAxis * uMid
        let vOffset: DesignVector3 = vAxis * vMid
        return origin + uOffset + vOffset
    }

    var reference: PlanarFaceReference {
        PlanarFaceReference(
            sourceAssetID: assetID,
            faceID: id,
            origin: origin,
            normal: normal,
            uAxis: uAxis,
            vAxis: vAxis,
            faceCenter: center
        )
    }
}

enum CADWorkPlane: Identifiable, Equatable {
    case canonical(SketchPlane)
    case face(DesignPlanarFace)

    var id: String {
        switch self {
        case let .canonical(plane):
            return "canonical:\(plane.rawValue)"
        case let .face(face):
            return "face:\(face.assetID.uuidString):\(face.id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case let .canonical(plane):
            return String(
                format: NSLocalizedString("cad.workplane.canonical_name", comment: ""),
                plane.displayName
            )
        case let .face(face):
            return face.name
        }
    }

    var reference: SketchReference {
        switch self {
        case let .canonical(plane):
            return .canonicalPlane(plane, offsetMeters: 0)
        case let .face(face):
            return .planarFace(face.reference)
        }
    }

    var origin: DesignVector3 {
        switch self {
        case .canonical:
            return originForSketchReference(reference)
        case let .face(face):
            return face.origin
        }
    }

    var normal: DesignVector3 {
        switch self {
        case .canonical:
            return normalVector(for: reference)
        case let .face(face):
            return face.normal.normalized(fallback: .zAxis)
        }
    }

    var uAxis: DesignVector3 {
        switch self {
        case .canonical:
            return axesForSketchReference(reference).u
        case let .face(face):
            return face.uAxis.normalized(fallback: .xAxis)
        }
    }

    var vAxis: DesignVector3 {
        switch self {
        case .canonical:
            return axesForSketchReference(reference).v
        case let .face(face):
            return face.vAxis.normalized(fallback: .yAxis)
        }
    }

    var bounds: DesignFaceBounds {
        switch self {
        case .canonical:
            return DesignFaceBounds(minU: -0.65, maxU: 0.65, minV: -0.65, maxV: 0.65)
        case let .face(face):
            return face.bounds
        }
    }

    var center: DesignVector3 {
        switch self {
        case .canonical:
            return origin
        case let .face(face):
            return face.center
        }
    }

    var focusRadius: Double {
        let width = abs(bounds.maxU - bounds.minU)
        let height = abs(bounds.maxV - bounds.minV)
        return max(width, height, 0.35) / 2
    }

    var isCanonical: Bool {
        if case .canonical = self { return true }
        return false
    }
}

struct SketchPoint2D: Codable, Equatable {
    var u: Double
    var v: Double

    static let zero = SketchPoint2D(u: 0, v: 0)

    func distance(to other: SketchPoint2D) -> Double {
        let du = u - other.u
        let dv = v - other.v
        return sqrt(du * du + dv * dv)
    }
}

enum SketchEntityStyle: String, Codable, CaseIterable, Identifiable {
    case main
    case construction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main: return NSLocalizedString("cad.sketch.style.main", comment: "")
        case .construction: return NSLocalizedString("cad.sketch.style.construction", comment: "")
        }
    }
}

enum CADLineStyle: String, Codable, CaseIterable, Identifiable {
    case main
    case thin
    case center
    case hidden
    case thick
    case breakLine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main:      return NSLocalizedString("cad.line_style.main", comment: "")
        case .thin:      return NSLocalizedString("cad.line_style.thin", comment: "")
        case .center:    return NSLocalizedString("cad.line_style.center", comment: "")
        case .hidden:    return NSLocalizedString("cad.line_style.hidden", comment: "")
        case .thick:     return NSLocalizedString("cad.line_style.thick", comment: "")
        case .breakLine: return NSLocalizedString("cad.line_style.break_line", comment: "")
        }
    }
}

enum SketchDimensionKind: String, Codable, CaseIterable, Identifiable {
    case lineLength
    case lineAngle
    case horizontalDistance
    case verticalDistance
    case rectangleWidth
    case rectangleHeight
    case circleRadius
    case circleDiameter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lineLength:         return NSLocalizedString("cad.dim.line_length", comment: "")
        case .lineAngle:          return NSLocalizedString("cad.dim.line_angle", comment: "")
        case .horizontalDistance: return NSLocalizedString("cad.dim.horizontal_distance", comment: "")
        case .verticalDistance:   return NSLocalizedString("cad.dim.vertical_distance", comment: "")
        case .rectangleWidth:     return NSLocalizedString("cad.dim.rectangle_width", comment: "")
        case .rectangleHeight:    return NSLocalizedString("cad.dim.rectangle_height", comment: "")
        case .circleRadius:       return NSLocalizedString("cad.dim.circle_radius", comment: "")
        case .circleDiameter:     return NSLocalizedString("cad.dim.circle_diameter", comment: "")
        }
    }

    var unit: String {
        switch self {
        case .lineAngle: return "°"
        default: return "mm"
        }
    }
}

struct SketchDimension: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: SketchDimensionKind
    var lineID: UUID
    var value: Double
    var isDriving: Bool
    var displayOffset: SketchPoint2D

    init(id: UUID = UUID(), kind: SketchDimensionKind, lineID: UUID, value: Double = 0, isDriving: Bool = true, displayOffset: SketchPoint2D = SketchPoint2D(u: 0, v: 0.02)) {
        self.id = id
        self.kind = kind
        self.lineID = lineID
        self.value = value
        self.isDriving = isDriving
        self.displayOffset = displayOffset
    }

    // Backward-compatible decoding: old documents omit value/isDriving/displayOffset
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SketchDimensionKind.self, forKey: .kind)
        lineID = try c.decode(UUID.self, forKey: .lineID)
        value = (try? c.decode(Double.self, forKey: .value)) ?? 0
        isDriving = (try? c.decode(Bool.self, forKey: .isDriving)) ?? true
        displayOffset = (try? c.decode(SketchPoint2D.self, forKey: .displayOffset)) ?? SketchPoint2D(u: 0, v: 0.02)
    }
}

enum SketchConstraintKind: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case vertical
    case fixedStart
    case fixedEnd
    case coincident
    case equalLength
    case parallel
    case perpendicular

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .horizontal:    return NSLocalizedString("cad.constraint.horizontal", comment: "")
        case .vertical:      return NSLocalizedString("cad.constraint.vertical", comment: "")
        case .fixedStart:    return NSLocalizedString("cad.constraint.fixed_start", comment: "")
        case .fixedEnd:      return NSLocalizedString("cad.constraint.fixed_end", comment: "")
        case .coincident:    return NSLocalizedString("cad.constraint.coincident", comment: "")
        case .equalLength:   return NSLocalizedString("cad.constraint.equal_length", comment: "")
        case .parallel:      return NSLocalizedString("cad.constraint.parallel", comment: "")
        case .perpendicular: return NSLocalizedString("cad.constraint.perpendicular", comment: "")
        }
    }

    var requiresTarget: Bool {
        switch self {
        case .parallel, .perpendicular, .coincident, .equalLength: return true
        default: return false
        }
    }
}

struct SketchConstraint: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: SketchConstraintKind
    var lineID: UUID
    var targetIDs: [UUID]

    init(id: UUID = UUID(), kind: SketchConstraintKind, lineID: UUID, targetIDs: [UUID] = []) {
        self.id = id
        self.kind = kind
        self.lineID = lineID
        self.targetIDs = targetIDs
    }

    // Backward-compatible decoding: old documents omit targetIDs
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SketchConstraintKind.self, forKey: .kind)
        lineID = try c.decode(UUID.self, forKey: .lineID)
        targetIDs = (try? c.decode([UUID].self, forKey: .targetIDs)) ?? []
    }
}

enum SketchDefinitionState: String, Codable, Equatable {
    case underDefined
    case constrained
    case conflicting

    var displayName: String {
        switch self {
        case .underDefined: return NSLocalizedString("cad.sketch.definition.under_defined", comment: "")
        case .constrained: return NSLocalizedString("cad.sketch.definition.constrained", comment: "")
        case .conflicting: return NSLocalizedString("cad.sketch.definition.conflicting", comment: "")
        }
    }
}

enum ExtrudeValidationIssue: Error, Equatable {
    case contourOpen
    case disconnectedLines
    case duplicatePoints
    case insufficientPoints
    case areaTooSmall
    case selfIntersecting
    case unsupportedContour
    case multipleProfilesUnsupported

    var messageKey: String {
        switch self {
        case .contourOpen:        return "cad.extrude.contour_open"
        case .disconnectedLines:  return "cad.extrude.disconnected_lines"
        case .duplicatePoints:    return "cad.extrude.duplicate_points"
        case .insufficientPoints: return "cad.extrude.insufficient_points"
        case .areaTooSmall:       return "cad.extrude.area_too_small"
        case .selfIntersecting:   return "cad.extrude.self_intersections"
        case .unsupportedContour: return "cad.extrude.unsupported_contour"
        case .multipleProfilesUnsupported: return "cad.extrude.multiple_profiles"
        }
    }
}

typealias SketchValidationError = ExtrudeValidationIssue

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

struct SketchLine: Codable, Identifiable, Equatable {
    var id: UUID
    var start: SketchPoint2D
    var end: SketchPoint2D
    var constructionStyle: SketchEntityStyle
    var lineStyle: CADLineStyle

    init(
        id: UUID = UUID(),
        start: SketchPoint2D,
        end: SketchPoint2D,
        constructionStyle: SketchEntityStyle = .main,
        lineStyle: CADLineStyle = .main
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.constructionStyle = constructionStyle
        self.lineStyle = lineStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, constructionStyle, lineStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(SketchPoint2D.self, forKey: .start)
        end = try c.decode(SketchPoint2D.self, forKey: .end)
        constructionStyle = try c.decodeIfPresent(SketchEntityStyle.self, forKey: .constructionStyle) ?? .main
        lineStyle = try c.decodeIfPresent(CADLineStyle.self, forKey: .lineStyle) ?? .main
    }

    var lengthMeters: Double {
        start.distance(to: end)
    }

    var angleDegrees: Double {
        let du = end.u - start.u
        let dv = end.v - start.v
        guard abs(du) > 1e-9 || abs(dv) > 1e-9 else { return 0 }
        return atan2(dv, du) * 180.0 / Double.pi
    }

    func withLength(_ lengthMeters: Double) -> SketchLine {
        let safeLength = max(0, lengthMeters)
        let currentLength = self.lengthMeters
        let angle = currentLength > 1e-9 ? atan2(end.v - start.v, end.u - start.u) : 0
        return SketchLine(
            id: id,
            start: start,
            end: SketchPoint2D(
                u: start.u + cos(angle) * safeLength,
                v: start.v + sin(angle) * safeLength
            )
        )
    }

    func withAngleDegrees(_ angleDegrees: Double) -> SketchLine {
        let length = lengthMeters
        let radians = angleDegrees * Double.pi / 180.0
        return SketchLine(
            id: id,
            start: start,
            end: SketchPoint2D(
                u: start.u + cos(radians) * length,
                v: start.v + sin(radians) * length
            )
        )
    }
}



struct SketchRectangle: Codable, Identifiable, Equatable {
    var id: UUID
    var firstCorner: SketchPoint2D
    var oppositeCorner: SketchPoint2D
    var constructionStyle: SketchEntityStyle
    var lineStyle: CADLineStyle

    init(
        id: UUID = UUID(),
        firstCorner: SketchPoint2D,
        oppositeCorner: SketchPoint2D,
        constructionStyle: SketchEntityStyle = .main,
        lineStyle: CADLineStyle = .main
    ) {
        self.id = id
        self.firstCorner = firstCorner
        self.oppositeCorner = oppositeCorner
        self.constructionStyle = constructionStyle
        self.lineStyle = lineStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, firstCorner, oppositeCorner, constructionStyle, lineStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        firstCorner = try c.decode(SketchPoint2D.self, forKey: .firstCorner)
        oppositeCorner = try c.decode(SketchPoint2D.self, forKey: .oppositeCorner)
        constructionStyle = try c.decodeIfPresent(SketchEntityStyle.self, forKey: .constructionStyle) ?? .main
        lineStyle = try c.decodeIfPresent(CADLineStyle.self, forKey: .lineStyle) ?? .main
    }

    var widthMeters: Double {
        abs(oppositeCorner.u - firstCorner.u)
    }

    var heightMeters: Double {
        abs(oppositeCorner.v - firstCorner.v)
    }

    var corners: [SketchPoint2D] {
        [
            firstCorner,
            SketchPoint2D(u: oppositeCorner.u, v: firstCorner.v),
            oppositeCorner,
            SketchPoint2D(u: firstCorner.u, v: oppositeCorner.v),
        ]
    }

    var isValidProfile: Bool {
        widthMeters > 0.0005 && heightMeters > 0.0005
    }

    func withWidth(_ widthMeters: Double) -> SketchRectangle {
        var copy = self
        let sign = oppositeCorner.u >= firstCorner.u ? 1.0 : -1.0
        copy.oppositeCorner.u = firstCorner.u + max(widthMeters, 0) * sign
        return copy
    }

    func withHeight(_ heightMeters: Double) -> SketchRectangle {
        var copy = self
        let sign = oppositeCorner.v >= firstCorner.v ? 1.0 : -1.0
        copy.oppositeCorner.v = firstCorner.v + max(heightMeters, 0) * sign
        return copy
    }
}

struct SketchCircle: Codable, Identifiable, Equatable {
    var id: UUID
    var center: SketchPoint2D
    var radiusMeters: Double
    var constructionStyle: SketchEntityStyle
    var lineStyle: CADLineStyle
    var showCenterlines: Bool

    init(
        id: UUID = UUID(),
        center: SketchPoint2D,
        radiusMeters: Double,
        constructionStyle: SketchEntityStyle = .main,
        lineStyle: CADLineStyle = .main,
        showCenterlines: Bool = false
    ) {
        self.id = id
        self.center = center
        self.radiusMeters = radiusMeters
        self.constructionStyle = constructionStyle
        self.lineStyle = lineStyle
        self.showCenterlines = showCenterlines
    }

    private enum CodingKeys: String, CodingKey {
        case id, center, radiusMeters, constructionStyle, lineStyle, showCenterlines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        center = try c.decode(SketchPoint2D.self, forKey: .center)
        radiusMeters = try c.decode(Double.self, forKey: .radiusMeters)
        constructionStyle = try c.decodeIfPresent(SketchEntityStyle.self, forKey: .constructionStyle) ?? .main
        lineStyle = try c.decodeIfPresent(CADLineStyle.self, forKey: .lineStyle) ?? .main
        showCenterlines = try c.decodeIfPresent(Bool.self, forKey: .showCenterlines) ?? false
    }

    var diameterMeters: Double {
        radiusMeters * 2
    }

    var isValidProfile: Bool {
        radiusMeters > 0.0005 && radiusMeters.isFinite
    }

    func profilePoints(segments: Int = 64) -> [SketchPoint2D] {
        let count = max(segments, 12)
        return (0..<count).map { index in
            let t = (Double(index) / Double(count)) * Double.pi * 2
            return SketchPoint2D(
                u: center.u + cos(t) * radiusMeters,
                v: center.v + sin(t) * radiusMeters
            )
        }
    }
}

struct SketchPolyline: Codable, Identifiable, Equatable {
    var id: UUID
    var points: [SketchPoint2D]
    var isClosed: Bool
    var constructionStyle: SketchEntityStyle
    var lineStyle: CADLineStyle

    init(
        id: UUID = UUID(),
        points: [SketchPoint2D],
        isClosed: Bool = false,
        constructionStyle: SketchEntityStyle = .main,
        lineStyle: CADLineStyle = .main
    ) {
        self.id = id
        self.points = points
        self.isClosed = isClosed
        self.constructionStyle = constructionStyle
        self.lineStyle = lineStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, points, isClosed, constructionStyle, lineStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        points = try c.decode([SketchPoint2D].self, forKey: .points)
        isClosed = try c.decodeIfPresent(Bool.self, forKey: .isClosed) ?? false
        constructionStyle = try c.decodeIfPresent(SketchEntityStyle.self, forKey: .constructionStyle) ?? .main
        lineStyle = try c.decodeIfPresent(CADLineStyle.self, forKey: .lineStyle) ?? .main
    }
}

struct SketchArc: Codable, Identifiable, Equatable {
    var id: UUID
    var start: SketchPoint2D
    var end: SketchPoint2D
    var midPoint: SketchPoint2D
    var constructionStyle: SketchEntityStyle
    var lineStyle: CADLineStyle

    init(
        id: UUID = UUID(),
        start: SketchPoint2D,
        end: SketchPoint2D,
        midPoint: SketchPoint2D,
        constructionStyle: SketchEntityStyle = .main,
        lineStyle: CADLineStyle = .main
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.midPoint = midPoint
        self.constructionStyle = constructionStyle
        self.lineStyle = lineStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, midPoint, constructionStyle, lineStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(SketchPoint2D.self, forKey: .start)
        end = try c.decode(SketchPoint2D.self, forKey: .end)
        midPoint = try c.decode(SketchPoint2D.self, forKey: .midPoint)
        constructionStyle = try c.decodeIfPresent(SketchEntityStyle.self, forKey: .constructionStyle) ?? .main
        lineStyle = try c.decodeIfPresent(CADLineStyle.self, forKey: .lineStyle) ?? .main
    }

    var circumcenter: SketchPoint2D? {
        let ax = start.u, ay = start.v
        let bx = midPoint.u, by = midPoint.v
        let cx = end.u, cy = end.v
        let D = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        guard abs(D) > 1e-12 else { return nil }
        let a2 = ax*ax + ay*ay, b2 = bx*bx + by*by, c2 = cx*cx + cy*cy
        let ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / D
        let uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / D
        return SketchPoint2D(u: ux, v: uy)
    }

    var circleRadius: Double? {
        guard let center = circumcenter else { return nil }
        return center.distance(to: start)
    }

    func approximationPoints(segments: Int = 32) -> [SketchPoint2D] {
        guard let center = circumcenter,
              let radius = circleRadius,
              radius > 1e-9 else { return [start, end] }

        let startAngle = atan2(start.v - center.v, start.u - center.u)
        let endAngle   = atan2(end.v   - center.v, end.u   - center.u)
        let midAngle   = atan2(midPoint.v - center.v, midPoint.u - center.u)

        // Determine which arc direction passes through midPoint
        func normaliseAngle(_ a: Double) -> Double { a < 0 ? a + 2 * .pi : a }
        let sa = normaliseAngle(startAngle)
        let ea = normaliseAngle(endAngle)
        let ma = normaliseAngle(midAngle)

        let cwSpan: Double = {
            let span = sa >= ma ? sa - ma : sa + 2 * .pi - ma
            return span
        }()
        let ccwSpan: Double = {
            let span = ma >= sa ? ma - sa : ma + 2 * .pi - sa
            return span
        }()
        let cwTotal: Double = {
            let span = sa >= ea ? sa - ea : sa + 2 * .pi - ea
            return span
        }()
        let ccwTotal: Double = {
            let span = ea >= sa ? ea - sa : ea + 2 * .pi - sa
            return span
        }()
        // mid is "on" the arc if the span to mid is less than the total span
        let goCounterClockwise: Bool = (ccwSpan < ccwTotal) || (cwSpan > cwTotal)

        let totalAngle: Double = goCounterClockwise ? ccwTotal : cwTotal
        let safeSegments = max(segments, 6)
        var points: [SketchPoint2D] = []
        for i in 0...safeSegments {
            let t = Double(i) / Double(safeSegments)
            let angle: Double = goCounterClockwise
                ? startAngle + totalAngle * t
                : startAngle - totalAngle * t
            points.append(SketchPoint2D(u: center.u + cos(angle) * radius, v: center.v + sin(angle) * radius))
        }
        return points
    }
}

enum SketchEntity: Codable, Identifiable, Equatable {
    case line(SketchLine)
    case rectangle(SketchRectangle)
    case circle(SketchCircle)
    case polyline(SketchPolyline)
    case arc(SketchArc)

    var id: UUID {
        switch self {
        case let .line(line):         return line.id
        case let .rectangle(rect):    return rect.id
        case let .circle(circle):     return circle.id
        case let .polyline(polyline): return polyline.id
        case let .arc(arc):           return arc.id
        }
    }

    var line: SketchLine? {
        if case let .line(line) = self { return line }; return nil
    }
    var rectangle: SketchRectangle? {
        if case let .rectangle(r) = self { return r }; return nil
    }
    var circle: SketchCircle? {
        if case let .circle(c) = self { return c }; return nil
    }
    var polyline: SketchPolyline? {
        if case let .polyline(p) = self { return p }; return nil
    }
    var arc: SketchArc? {
        if case let .arc(a) = self { return a }; return nil
    }
    var constructionStyle: SketchEntityStyle {
        switch self {
        case let .line(line):      return line.constructionStyle
        case let .rectangle(r):   return r.constructionStyle
        case let .circle(c):      return c.constructionStyle
        case let .polyline(p):    return p.constructionStyle
        case let .arc(a):         return a.constructionStyle
        }
    }

    var lineStyle: CADLineStyle {
        switch self {
        case let .line(line):      return line.lineStyle
        case let .rectangle(r):   return r.lineStyle
        case let .circle(c):      return c.lineStyle
        case let .polyline(p):    return p.lineStyle
        case let .arc(a):         return a.lineStyle
        }
    }

    func translated(by delta: SketchPoint2D) -> SketchEntity {
        switch self {
        case var .line(l):
            l.start = SketchPoint2D(u: l.start.u + delta.u, v: l.start.v + delta.v)
            l.end   = SketchPoint2D(u: l.end.u   + delta.u, v: l.end.v   + delta.v)
            return .line(l)
        case var .rectangle(r):
            r.firstCorner    = SketchPoint2D(u: r.firstCorner.u    + delta.u, v: r.firstCorner.v    + delta.v)
            r.oppositeCorner = SketchPoint2D(u: r.oppositeCorner.u + delta.u, v: r.oppositeCorner.v + delta.v)
            return .rectangle(r)
        case var .circle(c):
            c.center = SketchPoint2D(u: c.center.u + delta.u, v: c.center.v + delta.v)
            return .circle(c)
        case var .polyline(p):
            p.points = p.points.map { SketchPoint2D(u: $0.u + delta.u, v: $0.v + delta.v) }
            return .polyline(p)
        case var .arc(a):
            a.start    = SketchPoint2D(u: a.start.u    + delta.u, v: a.start.v    + delta.v)
            a.end      = SketchPoint2D(u: a.end.u      + delta.u, v: a.end.v      + delta.v)
            a.midPoint = SketchPoint2D(u: a.midPoint.u + delta.u, v: a.midPoint.v + delta.v)
            return .arc(a)
        }
    }

    func withNewID() -> SketchEntity {
        switch self {
        case var .line(l):      l.id = UUID(); return .line(l)
        case var .rectangle(r): r.id = UUID(); return .rectangle(r)
        case var .circle(c):    c.id = UUID(); return .circle(c)
        case var .polyline(p):  p.id = UUID(); return .polyline(p)
        case var .arc(a):       a.id = UUID(); return .arc(a)
        }
    }
}

struct DesignSketch: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var plane: SketchPlane
    var planeOffsetMeters: Double
    var reference: SketchReference
    var entities: [SketchEntity]
    var isClosed: Bool
    var dimensions: [SketchDimension]
    var constraints: [SketchConstraint]

    init(
        id: UUID = UUID(),
        name: String = NSLocalizedString("cad.sketch.default_name", comment: ""),
        plane: SketchPlane = .xz,
        planeOffsetMeters: Double = 0,
        reference: SketchReference? = nil,
        entities: [SketchEntity] = [],
        dimensions: [SketchDimension] = [],
        constraints: [SketchConstraint] = []
    ) {
        self.id = id
        self.name = name
        let resolvedReference = reference ?? .canonicalPlane(plane, offsetMeters: planeOffsetMeters)
        self.reference = resolvedReference
        self.plane = resolvedReference.plane
        self.planeOffsetMeters = resolvedReference.planeOffsetMeters
        self.entities = entities
        self.isClosed = DesignSketch.detectClosedContour(in: entities)
        self.dimensions = dimensions
        self.constraints = constraints
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case plane
        case planeOffsetMeters
        case reference
        case entities
        case isClosed
        case dimensions
        case constraints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        planeOffsetMeters = try container.decodeIfPresent(Double.self, forKey: .planeOffsetMeters) ?? 0
        reference = try container.decodeIfPresent(SketchReference.self, forKey: .reference)
            ?? .canonicalPlane(plane, offsetMeters: planeOffsetMeters)
        plane = reference.plane
        planeOffsetMeters = reference.planeOffsetMeters
        entities = try container.decode([SketchEntity].self, forKey: .entities)
        dimensions = try container.decodeIfPresent([SketchDimension].self, forKey: .dimensions) ?? []
        constraints = try container.decodeIfPresent([SketchConstraint].self, forKey: .constraints) ?? []
        isClosed = try container.decodeIfPresent(Bool.self, forKey: .isClosed)
            ?? DesignSketch.detectClosedContour(in: entities)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(plane, forKey: .plane)
        try container.encode(planeOffsetMeters, forKey: .planeOffsetMeters)
        try container.encode(reference, forKey: .reference)
        try container.encode(entities, forKey: .entities)
        try container.encode(isClosed, forKey: .isClosed)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(constraints, forKey: .constraints)
    }

    var lines: [SketchLine] {
        entities.compactMap(\.line)
    }

    var rectangles: [SketchRectangle] {
        entities.compactMap(\.rectangle)
    }

    var circles: [SketchCircle] {
        entities.compactMap(\.circle)
    }

    var polylines: [SketchPolyline] {
        entities.compactMap(\.polyline)
    }

    var arcs: [SketchArc] {
        entities.compactMap(\.arc)
    }

    var lineCount: Int {
        lines.count
    }

    var entityCount: Int {
        entities.count
    }

    var hasGeometry: Bool {
        !entities.isEmpty
    }

    func entity(with id: UUID) -> SketchEntity? {
        entities.first { $0.id == id }
    }

    func snapVertices(toleranceMeters: Double = 0.000001) -> [SketchPoint2D] {
        var vertices: [SketchPoint2D] = []
        for entity in entities {
            switch entity {
            case let .line(line):
                DesignSketch.appendUnique(line.start, to: &vertices, toleranceMeters: toleranceMeters)
                DesignSketch.appendUnique(line.end, to: &vertices, toleranceMeters: toleranceMeters)
            case let .rectangle(rectangle):
                for corner in rectangle.corners {
                    DesignSketch.appendUnique(corner, to: &vertices, toleranceMeters: toleranceMeters)
                }
            case let .circle(circle):
                DesignSketch.appendUnique(circle.center, to: &vertices, toleranceMeters: toleranceMeters)
            case let .polyline(polyline):
                for point in polyline.points {
                    DesignSketch.appendUnique(point, to: &vertices, toleranceMeters: toleranceMeters)
                }
            case let .arc(arc):
                DesignSketch.appendUnique(arc.start, to: &vertices, toleranceMeters: toleranceMeters)
                DesignSketch.appendUnique(arc.end, to: &vertices, toleranceMeters: toleranceMeters)
                DesignSketch.appendUnique(arc.midPoint, to: &vertices, toleranceMeters: toleranceMeters)
            }
        }
        return vertices
    }

    mutating func setCanonicalPlane(_ plane: SketchPlane, offsetMeters: Double) {
        self.plane = plane
        self.planeOffsetMeters = offsetMeters
        self.reference = .canonicalPlane(plane, offsetMeters: offsetMeters)
    }

    mutating func setReference(_ reference: SketchReference) {
        self.reference = reference
        self.plane = reference.plane
        self.planeOffsetMeters = reference.planeOffsetMeters
    }

    var definitionState: SketchDefinitionState {
        if hasConstraintConflict {
            return .conflicting
        }
        if dimensions.isEmpty && constraints.isEmpty {
            return .underDefined
        }
        return .constrained
    }

    var hasConstraintConflict: Bool {
        for line in lines {
            let lineConstraints = constraints.filter { $0.lineID == line.id }
            let hasHorizontal = lineConstraints.contains { $0.kind == .horizontal }
            let hasVertical = lineConstraints.contains { $0.kind == .vertical }
            let hasFixedStart = lineConstraints.contains { $0.kind == .fixedStart }
            let hasFixedEnd = lineConstraints.contains { $0.kind == .fixedEnd }
            if hasHorizontal && hasVertical && line.lengthMeters > 0.0005 {
                return true
            }
            if hasHorizontal && hasFixedStart && hasFixedEnd && abs(line.start.v - line.end.v) > 0.0005 {
                return true
            }
            if hasVertical && hasFixedStart && hasFixedEnd && abs(line.start.u - line.end.u) > 0.0005 {
                return true
            }
        }
        return false
    }

    func constraints(for lineID: UUID) -> [SketchConstraint] {
        constraints.filter { $0.lineID == lineID }
    }

    func hasConstraint(_ kind: SketchConstraintKind, lineID: UUID) -> Bool {
        constraints.contains { $0.kind == kind && $0.lineID == lineID }
    }

    func hasDimension(_ kind: SketchDimensionKind, lineID: UUID) -> Bool {
        dimensions.contains { $0.kind == kind && $0.lineID == lineID }
    }

    mutating func refreshClosedStatus() {
        isClosed = DesignSketch.detectClosedContour(in: entities)
    }

    static func detectClosedContour(in entities: [SketchEntity], toleranceMeters: Double = 0.005) -> Bool {
        return extractSingleClosedProfile(
            from: entities,
            toleranceMeters: toleranceMeters,
            minAreaMeters2: 0
        ).isSuccess
    }

    func orderedPolylinePoints(toleranceMeters: Double = 0.005) -> [SketchPoint2D] {
        DesignSketch.orderedPolylinePointsForDisplay(from: lines, toleranceMeters: toleranceMeters)
    }

    func isClosed(toleranceMeters: Double = 0.005) -> Bool {
        DesignSketch.detectClosedContour(in: entities, toleranceMeters: toleranceMeters)
    }

    func profilePointsForExtrude(toleranceMeters: Double = 0.005) -> [SketchPoint2D]? {
        try? orderedProfilePointsForExtrude(toleranceMeters: toleranceMeters).get()
    }

    func orderedProfilePointsForExtrude(
        toleranceMeters: Double = 0.005,
        minAreaMeters2: Double = 0.000001
    ) -> Result<[SketchPoint2D], SketchValidationError> {
        DesignSketch.extractSingleClosedProfile(
            from: entities,
            toleranceMeters: toleranceMeters,
            minAreaMeters2: minAreaMeters2
        )
    }

    func extrudeValidationIssue(
        toleranceMeters: Double = 0.005,
        minAreaMeters2: Double = 0.000001
    ) -> ExtrudeValidationIssue? {
        switch orderedProfilePointsForExtrude(
            toleranceMeters: toleranceMeters,
            minAreaMeters2: minAreaMeters2
        ) {
        case .success:
            return nil
        case let .failure(error):
            return error
        }
    }

    static func polygonSignedAreaMeters2(_ points: [SketchPoint2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for i in 0..<points.count {
            let j = (i + 1) % points.count
            area += points[i].u * points[j].v - points[j].u * points[i].v
        }
        return area / 2
    }

    static func polygonAreaMeters2(_ points: [SketchPoint2D]) -> Double {
        abs(polygonSignedAreaMeters2(points))
    }

    static func appendUnique(
        _ point: SketchPoint2D,
        to points: inout [SketchPoint2D],
        toleranceMeters: Double
    ) {
        guard !points.contains(where: { $0.distance(to: point) <= toleranceMeters }) else { return }
        points.append(point)
    }

    private static func extractSingleClosedProfile(
        from entities: [SketchEntity],
        toleranceMeters: Double,
        minAreaMeters2: Double
    ) -> Result<[SketchPoint2D], SketchValidationError> {
        let mainEntities = entities.filter { entity in
            switch entity {
            case let .line(line):
                return line.constructionStyle == .main
            case let .rectangle(rectangle):
                return rectangle.constructionStyle == .main
            case let .circle(circle):
                return circle.constructionStyle == .main
            case let .polyline(polyline):
                return polyline.constructionStyle == .main
            case .arc:
                return false  // arcs don't participate in extrude profile v1
            }
        }
        guard !mainEntities.isEmpty else { return .failure(.insufficientPoints) }

        if mainEntities.allSatisfy({ $0.line != nil }) {
            return orderedProfilePointsForExtrude(
                lines: mainEntities.compactMap(\.line),
                toleranceMeters: toleranceMeters,
                minAreaMeters2: minAreaMeters2
            )
        }

        guard mainEntities.count == 1 else { return .failure(.multipleProfilesUnsupported) }
        switch mainEntities[0] {
        case .line:
            return .failure(.insufficientPoints)
        case let .rectangle(rectangle):
            guard rectangle.isValidProfile else { return .failure(.areaTooSmall) }
            return validateProfilePoints(
                rectangle.corners,
                toleranceMeters: toleranceMeters,
                minAreaMeters2: minAreaMeters2
            )
        case let .circle(circle):
            guard circle.isValidProfile else { return .failure(.areaTooSmall) }
            return validateProfilePoints(
                circle.profilePoints(),
                toleranceMeters: toleranceMeters,
                minAreaMeters2: minAreaMeters2
            )
        case let .polyline(polyline):
            let endpointDistance = polyline.points.first?.distance(to: polyline.points.last ?? .zero) ?? .infinity
            guard polyline.isClosed || endpointDistance <= toleranceMeters else {
                return .failure(.contourOpen)
            }
            var points = polyline.points
            if points.count >= 2,
               let first = points.first,
               let last = points.last,
               first.distance(to: last) <= toleranceMeters {
                points.removeLast()
            }
            return validateProfilePoints(
                points,
                toleranceMeters: toleranceMeters,
                minAreaMeters2: minAreaMeters2
            )
        case .arc:
            return .failure(.unsupportedContour)
        }
    }

    private static func validateProfilePoints(
        _ points: [SketchPoint2D],
        toleranceMeters: Double,
        minAreaMeters2: Double
    ) -> Result<[SketchPoint2D], SketchValidationError> {
        guard points.count >= 3 else { return .failure(.insufficientPoints) }
        var uniquePoints: [SketchPoint2D] = []
        for point in points {
            if uniquePoints.contains(where: { $0.distance(to: point) <= toleranceMeters }) {
                return .failure(.duplicatePoints)
            }
            uniquePoints.append(point)
        }
        guard uniquePoints.count >= 3 else { return .failure(.insufficientPoints) }
        guard polygonAreaMeters2(uniquePoints) > minAreaMeters2 else { return .failure(.areaTooSmall) }
        guard !hasSelfIntersections(uniquePoints, toleranceMeters: toleranceMeters) else {
            return .failure(.selfIntersecting)
        }
        return .success(uniquePoints)
    }

    private static func orderedPolylinePointsForDisplay(
        from lines: [SketchLine],
        toleranceMeters: Double
    ) -> [SketchPoint2D] {
        guard let first = lines.first else { return [] }
        var points: [SketchPoint2D] = [first.start, first.end]
        var remaining = Array(lines.dropFirst())

        while !remaining.isEmpty {
            guard let last = points.last else { break }
            if let index = remaining.firstIndex(where: { $0.start.distance(to: last) <= toleranceMeters }) {
                points.append(remaining.remove(at: index).end)
            } else if let index = remaining.firstIndex(where: { $0.end.distance(to: last) <= toleranceMeters }) {
                points.append(remaining.remove(at: index).start)
            } else {
                break
            }
        }

        return points
    }

    private static func orderedProfilePointsForExtrude(
        lines: [SketchLine],
        toleranceMeters: Double,
        minAreaMeters2: Double
    ) -> Result<[SketchPoint2D], SketchValidationError> {
        guard lines.count >= 3 else { return .failure(.insufficientPoints) }
        guard let first = lines.first else { return .failure(.insufficientPoints) }

        var points: [SketchPoint2D] = [first.start, first.end]
        var remaining = Array(lines.dropFirst())
        while !remaining.isEmpty {
            guard let last = points.last else { return .failure(.disconnectedLines) }
            if let index = remaining.firstIndex(where: { $0.start.distance(to: last) <= toleranceMeters }) {
                points.append(remaining.remove(at: index).end)
            } else if let index = remaining.firstIndex(where: { $0.end.distance(to: last) <= toleranceMeters }) {
                points.append(remaining.remove(at: index).start)
            } else {
                return .failure(.disconnectedLines)
            }
        }

        guard let firstPoint = points.first,
              let lastPoint = points.last,
              lastPoint.distance(to: firstPoint) <= toleranceMeters else {
            return .failure(.contourOpen)
        }
        points.removeLast()

        var uniquePoints: [SketchPoint2D] = []
        for point in points {
            if uniquePoints.contains(where: { $0.distance(to: point) <= toleranceMeters }) {
                return .failure(.duplicatePoints)
            }
            uniquePoints.append(point)
        }

        guard uniquePoints.count >= 3 else { return .failure(.insufficientPoints) }
        guard polygonAreaMeters2(uniquePoints) > minAreaMeters2 else { return .failure(.areaTooSmall) }
        guard !hasSelfIntersections(uniquePoints, toleranceMeters: toleranceMeters) else {
            return .failure(.selfIntersecting)
        }

        return .success(uniquePoints)
    }

    private static func hasSelfIntersections(
        _ points: [SketchPoint2D],
        toleranceMeters: Double
    ) -> Bool {
        let count = points.count
        guard count >= 4 else { return false }

        for i in 0..<count {
            let iNext = (i + 1) % count
            for j in (i + 1)..<count {
                let jNext = (j + 1) % count
                if i == j || iNext == j || jNext == i { continue }
                if segmentsIntersect(
                    points[i],
                    points[iNext],
                    points[j],
                    points[jNext],
                    toleranceMeters: toleranceMeters
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ a: SketchPoint2D,
        _ b: SketchPoint2D,
        _ c: SketchPoint2D,
        _ d: SketchPoint2D,
        toleranceMeters: Double
    ) -> Bool {
        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)

        if abs(o1) <= toleranceMeters, point(c, liesOn: a, b, toleranceMeters: toleranceMeters) { return true }
        if abs(o2) <= toleranceMeters, point(d, liesOn: a, b, toleranceMeters: toleranceMeters) { return true }
        if abs(o3) <= toleranceMeters, point(a, liesOn: c, d, toleranceMeters: toleranceMeters) { return true }
        if abs(o4) <= toleranceMeters, point(b, liesOn: c, d, toleranceMeters: toleranceMeters) { return true }

        return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0)
    }

    private static func orientation(_ a: SketchPoint2D, _ b: SketchPoint2D, _ c: SketchPoint2D) -> Double {
        (b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u)
    }

    private static func point(
        _ p: SketchPoint2D,
        liesOn a: SketchPoint2D,
        _ b: SketchPoint2D,
        toleranceMeters: Double
    ) -> Bool {
        p.u >= min(a.u, b.u) - toleranceMeters
            && p.u <= max(a.u, b.u) + toleranceMeters
            && p.v >= min(a.v, b.v) - toleranceMeters
            && p.v <= max(a.v, b.v) + toleranceMeters
    }

    func bounds3D() -> (width: Double, height: Double, depth: Double) {
        let points = boundsPoints2D()
        guard !points.isEmpty else {
            return (0.2, 0.001, 0.2)
        }

        let worldPoints = points.map { sketchPointToWorld($0, reference: reference) }
        let minX = worldPoints.map(\.x).min() ?? 0
        let maxX = worldPoints.map(\.x).max() ?? 0
        let minY = worldPoints.map(\.y).min() ?? 0
        let maxY = worldPoints.map(\.y).max() ?? 0
        let minZ = worldPoints.map(\.z).min() ?? 0
        let maxZ = worldPoints.map(\.z).max() ?? 0

        return (
            max(maxX - minX, 0.001),
            max(maxY - minY, 0.001),
            max(maxZ - minZ, 0.001)
        )
    }

    func centroid3D() -> DesignVector3 {
        let points = boundsPoints2D()
        guard !points.isEmpty else { return .zero }
        let worldPoints = points.map { sketchPointToWorld($0, reference: reference) }
        let count = Double(worldPoints.count)
        return DesignVector3(
            x: worldPoints.map(\.x).reduce(0, +) / count,
            y: worldPoints.map(\.y).reduce(0, +) / count,
            z: worldPoints.map(\.z).reduce(0, +) / count
        )
    }

    private func boundsPoints2D() -> [SketchPoint2D] {
        var points: [SketchPoint2D] = []
        for entity in entities {
            switch entity {
            case let .line(line):
                points += [line.start, line.end]
            case let .rectangle(rectangle):
                points += rectangle.corners
            case let .circle(circle):
                let r = circle.radiusMeters
                points += [
                    SketchPoint2D(u: circle.center.u - r, v: circle.center.v),
                    SketchPoint2D(u: circle.center.u + r, v: circle.center.v),
                    SketchPoint2D(u: circle.center.u, v: circle.center.v - r),
                    SketchPoint2D(u: circle.center.u, v: circle.center.v + r),
                ]
            case let .polyline(polyline):
                points += polyline.points
            case let .arc(arc):
                points += [arc.start, arc.end, arc.midPoint]
            }
        }
        return points
    }
}

struct SketchAssetParameters: Codable, Equatable {
    var sketch: DesignSketch
    var planeOffsetMeters: Double

    init(
        sketch: DesignSketch = DesignSketch(),
        planeOffsetMeters: Double = 0
    ) {
        self.sketch = sketch
        self.planeOffsetMeters = planeOffsetMeters
        if case let .canonicalPlane(plane, _) = self.sketch.reference {
            self.sketch.setCanonicalPlane(plane, offsetMeters: planeOffsetMeters)
        }
    }

    mutating func syncPlaneOffset() {
        if case let .canonicalPlane(plane, _) = sketch.reference {
            sketch.setCanonicalPlane(plane, offsetMeters: planeOffsetMeters)
        }
    }
}

// MARK: - Extruded Solid

enum ExtrudeDirection: String, Codable, CaseIterable, Identifiable {
    case positiveNormal
    case negativeNormal
    case symmetric

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .positiveNormal: return NSLocalizedString("cad.extrude.dir.positive", comment: "")
        case .negativeNormal: return NSLocalizedString("cad.extrude.dir.negative", comment: "")
        case .symmetric:      return NSLocalizedString("cad.extrude.dir.symmetric", comment: "")
        }
    }

    func offsets(depth: Double) -> (front: Double, back: Double) {
        switch self {
        case .positiveNormal: return (depth, 0)
        case .negativeNormal: return (0, -depth)
        case .symmetric:      return (depth / 2, -(depth / 2))
        }
    }
}

struct ExtrudedSolidParameters: Codable, Equatable {
    var sourceSketchID: UUID
    var sourceSketchName: String
    var profilePoints: [SketchPoint2D]  // CCW contour, last point does NOT repeat first
    var holes: [[SketchPoint2D]]        // inner contours removed from the body
    var holeDepths: [Double]            // cut depth per hole, parallel to holes; full-body depth = through cut
    var cutFeatures: [ExtrudedSolidCutFeature]
    var boxBlindCutFeatures: [ExtrudedSolidBoxBlindCutFeature]
    var sourcePlane: SketchPlane
    var planeOffsetMeters: Double
    var sourceReference: SketchReference
    var depthMeters: Double
    var direction: ExtrudeDirection
    var material: DesignMaterial
    var faces: [DesignPlanarFace]
    var featureRecord: CADFeatureRecord?

    init(
        assetID: UUID,
        sourceSketchID: UUID,
        sourceSketchName: String,
        profilePoints: [SketchPoint2D],
        holes: [[SketchPoint2D]] = [],
        holeDepths: [Double] = [],
        cutFeatures: [ExtrudedSolidCutFeature] = [],
        boxBlindCutFeatures: [ExtrudedSolidBoxBlindCutFeature] = [],
        sourceReference: SketchReference,
        depthMeters: Double,
        direction: ExtrudeDirection,
        material: DesignMaterial,
        featureRecord: CADFeatureRecord? = nil
    ) {
        self.sourceSketchID = sourceSketchID
        self.sourceSketchName = sourceSketchName
        self.profilePoints = profilePoints
        self.holes = holes
        self.holeDepths = holeDepths
        self.cutFeatures = cutFeatures
        self.boxBlindCutFeatures = boxBlindCutFeatures
        self.sourceReference = sourceReference
        self.sourcePlane = sourceReference.plane
        self.planeOffsetMeters = sourceReference.planeOffsetMeters
        self.depthMeters = depthMeters
        self.direction = direction
        self.material = material
        self.featureRecord = featureRecord
        self.faces = DesignPlanarFace.faces(
            assetID: assetID,
            profilePoints: profilePoints,
            reference: sourceReference,
            depthMeters: depthMeters,
            direction: direction
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourceSketchID
        case sourceSketchName
        case profilePoints
        case holes
        case holeDepths
        case cutFeatures
        case boxBlindCutFeatures
        case sourcePlane
        case planeOffsetMeters
        case sourceReference
        case depthMeters
        case direction
        case material
        case faces
        case featureRecord
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSketchID = try container.decode(UUID.self, forKey: .sourceSketchID)
        sourceSketchName = try container.decodeIfPresent(String.self, forKey: .sourceSketchName) ?? ""
        profilePoints = try container.decode([SketchPoint2D].self, forKey: .profilePoints)
        holes = try container.decodeIfPresent([[SketchPoint2D]].self, forKey: .holes) ?? []
        holeDepths = try container.decodeIfPresent([Double].self, forKey: .holeDepths) ?? []
        cutFeatures = try container.decodeIfPresent([ExtrudedSolidCutFeature].self, forKey: .cutFeatures) ?? []
        boxBlindCutFeatures = try container.decodeIfPresent(
            [ExtrudedSolidBoxBlindCutFeature].self,
            forKey: .boxBlindCutFeatures
        ) ?? []
        sourcePlane = try container.decode(SketchPlane.self, forKey: .sourcePlane)
        planeOffsetMeters = try container.decodeIfPresent(Double.self, forKey: .planeOffsetMeters) ?? 0
        sourceReference = try container.decodeIfPresent(SketchReference.self, forKey: .sourceReference)
            ?? .canonicalPlane(sourcePlane, offsetMeters: planeOffsetMeters)
        sourcePlane = sourceReference.plane
        planeOffsetMeters = sourceReference.planeOffsetMeters
        depthMeters = try container.decode(Double.self, forKey: .depthMeters)
        direction = try container.decode(ExtrudeDirection.self, forKey: .direction)
        material = try container.decodeIfPresent(DesignMaterial.self, forKey: .material) ?? .carbonFiber
        faces = try container.decodeIfPresent([DesignPlanarFace].self, forKey: .faces) ?? []
        featureRecord = try container.decodeIfPresent(CADFeatureRecord.self, forKey: .featureRecord)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceSketchID, forKey: .sourceSketchID)
        try container.encode(sourceSketchName, forKey: .sourceSketchName)
        try container.encode(profilePoints, forKey: .profilePoints)
        try container.encode(holes, forKey: .holes)
        try container.encode(holeDepths, forKey: .holeDepths)
        try container.encode(cutFeatures, forKey: .cutFeatures)
        try container.encode(boxBlindCutFeatures, forKey: .boxBlindCutFeatures)
        try container.encode(sourcePlane, forKey: .sourcePlane)
        try container.encode(planeOffsetMeters, forKey: .planeOffsetMeters)
        try container.encode(sourceReference, forKey: .sourceReference)
        try container.encode(depthMeters, forKey: .depthMeters)
        try container.encode(direction, forKey: .direction)
        try container.encode(material, forKey: .material)
        try container.encode(faces, forKey: .faces)
        try container.encodeIfPresent(featureRecord, forKey: .featureRecord)
    }

    // Shoelace formula — positive when CCW
    var signedAreaMeters2: Double {
        DesignSketch.polygonSignedAreaMeters2(profilePoints)
    }

    var areaMeters2: Double { abs(signedAreaMeters2) }

    var volumeMeters3: Double {
        let baseVolume = areaMeters2 * depthMeters
        let legacyCutVolume = zip(holes, resolvedLegacyHoleDepths()).reduce(0.0) { total, entry in
            total + abs(DesignSketch.polygonSignedAreaMeters2(entry.0)) * min(abs(entry.1), depthMeters)
        }
        let cutV2Volume = cutFeatures.reduce(0.0) { total, feature in
            total + abs(DesignSketch.polygonSignedAreaMeters2(feature.profilePoints)) * feature.depthMeters
        }
        let boxBlindCutVolume = boxBlindCutFeatures.reduce(0.0) { total, feature in
            total + abs(DesignSketch.polygonSignedAreaMeters2(feature.profilePoints)) * feature.depthMeters
        }
        return max(baseVolume - legacyCutVolume - cutV2Volume - boxBlindCutVolume, 0)
    }

    func vertices() -> [DesignVector3] {
        let normal = normalVector(for: sourceReference)
        let (frontOff, backOff) = direction.offsets(depth: depthMeters)
        return profilePoints.flatMap { point in
            let base = sketchPointToWorld(point, reference: sourceReference)
            return [
                base + normal * frontOff,
                base + normal * backOff,
            ]
        }
    }

    mutating func refreshFaces(assetID: UUID) {
        sourcePlane = sourceReference.plane
        planeOffsetMeters = sourceReference.planeOffsetMeters
        faces = DesignPlanarFace.faces(
            assetID: assetID,
            profilePoints: profilePoints,
            reference: sourceReference,
            depthMeters: depthMeters,
            direction: direction
        )
    }

    func resolvedLegacyHoleDepths() -> [Double] {
        var depths = holeDepths
        while depths.count < holes.count { depths.append(depthMeters) }
        return depths
    }
}

// MARK: - Geometry helpers

func closestPointOnSegment(from p: SketchPoint2D, segA: SketchPoint2D, segB: SketchPoint2D) -> SketchPoint2D {
    let dx = segB.u - segA.u, dy = segB.v - segA.v
    let lenSq = dx * dx + dy * dy
    guard lenSq > 1e-18 else { return segA }
    let t = max(0, min(1, ((p.u - segA.u) * dx + (p.v - segA.v) * dy) / lenSq))
    return SketchPoint2D(u: segA.u + t * dx, v: segA.v + t * dy)
}

func segmentsIntersect(
    a1: SketchPoint2D, a2: SketchPoint2D,
    b1: SketchPoint2D, b2: SketchPoint2D
) -> SketchPoint2D? {
    let dx1 = a2.u - a1.u, dy1 = a2.v - a1.v
    let dx2 = b2.u - b1.u, dy2 = b2.v - b1.v
    let denom = dx1 * dy2 - dy1 * dx2
    guard abs(denom) > 1e-12 else { return nil }
    let t = ((b1.u - a1.u) * dy2 - (b1.v - a1.v) * dx2) / denom
    let u = ((b1.u - a1.u) * dy1 - (b1.v - a1.v) * dx1) / denom
    guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
    return SketchPoint2D(u: a1.u + t * dx1, v: a1.v + t * dy1)
}

func raySegmentIntersect(
    origin: SketchPoint2D, direction rayDir: SketchPoint2D,
    segA: SketchPoint2D, segB: SketchPoint2D
) -> SketchPoint2D? {
    let dx = segB.u - segA.u, dy = segB.v - segA.v
    let denom = rayDir.u * dy - rayDir.v * dx
    guard abs(denom) > 1e-12 else { return nil }
    let t = ((segA.u - origin.u) * dy - (segA.v - origin.v) * dx) / denom
    let u = ((segA.u - origin.u) * rayDir.v - (segA.v - origin.v) * rayDir.u) / denom
    guard t >= 0, u >= 0, u <= 1 else { return nil }
    return SketchPoint2D(u: origin.u + t * rayDir.u, v: origin.v + t * rayDir.v)
}

extension DesignPlanarFace {
    static func faces(
        assetID: UUID,
        profilePoints: [SketchPoint2D],
        reference: SketchReference,
        depthMeters: Double,
        direction: ExtrudeDirection
    ) -> [DesignPlanarFace] {
        guard profilePoints.count >= 3 else { return [] }

        let axes = axesForSketchReference(reference)
        let normal = axes.normal.normalized(fallback: .zAxis)
        let (frontOff, backOff) = direction.offsets(depth: depthMeters)
        let basePoints = profilePoints.map { sketchPointToWorld($0, reference: reference) }
        let frontPoints = basePoints.map { $0 + normal * frontOff }
        let backPoints = basePoints.map { $0 + normal * backOff }
        let signedArea = DesignSketch.polygonSignedAreaMeters2(profilePoints)
        let frontNormal = signedArea >= 0 ? normal : normal * -1
        let backNormal = frontNormal * -1

        var result: [DesignPlanarFace] = []
        result.append(
            DesignPlanarFace(
                id: UUID(),
                name: NSLocalizedString("cad.face.front", comment: ""),
                assetID: assetID,
                origin: frontPoints[0],
                normal: frontNormal,
                uAxis: axes.u,
                vAxis: axes.v,
                bounds: bounds(for: frontPoints, origin: frontPoints[0], uAxis: axes.u, vAxis: axes.v)
            )
        )
        result.append(
            DesignPlanarFace(
                id: UUID(),
                name: NSLocalizedString("cad.face.back", comment: ""),
                assetID: assetID,
                origin: backPoints[0],
                normal: backNormal,
                uAxis: axes.u,
                vAxis: axes.v,
                bounds: bounds(for: backPoints, origin: backPoints[0], uAxis: axes.u, vAxis: axes.v)
            )
        )

        for index in 0..<profilePoints.count {
            let next = (index + 1) % profilePoints.count
            let f0 = frontPoints[index]
            let f1 = frontPoints[next]
            let b0 = backPoints[index]
            let b1 = backPoints[next]
            let edge = (f1 - f0).normalized(fallback: axes.u)
            let depthAxis = (b0 - f0).normalized(fallback: normal * -1)
            let sideNormal = edge.cross(depthAxis).normalized(fallback: normal)
            let points = [f0, f1, b1, b0]
            result.append(
                DesignPlanarFace(
                    id: UUID(),
                    name: String(
                        format: NSLocalizedString("cad.face.side_n", comment: ""),
                        index + 1
                    ),
                    assetID: assetID,
                    origin: f0,
                    normal: sideNormal,
                    uAxis: edge,
                    vAxis: depthAxis,
                    bounds: bounds(for: points, origin: f0, uAxis: edge, vAxis: depthAxis)
                )
            )
        }

        return result
    }

    private static func bounds(
        for points: [DesignVector3],
        origin: DesignVector3,
        uAxis: DesignVector3,
        vAxis: DesignVector3
    ) -> DesignFaceBounds {
        let us = points.map { ($0 - origin).dot(uAxis) }
        let vs = points.map { ($0 - origin).dot(vAxis) }
        return DesignFaceBounds(
            minU: us.min() ?? 0,
            maxU: us.max() ?? 0,
            minV: vs.min() ?? 0,
            maxV: vs.max() ?? 0
        )
    }
}

// MARK: - Kind enum

enum DesignAssetKind: Codable, Equatable {
    case basicWing(BasicWingParameters)
    case framePlate(FramePlateParameters)
    case beam(BeamParameters)
    case tube(TubeParameters)
    case mountBracket(MountBracketParameters)
    case payloadBox(PayloadBoxParameters)
    case sketch2D(SketchAssetParameters)
    case extrudedSolid(ExtrudedSolidParameters)

    var displayName: String {
        switch self {
        case .basicWing:      return NSLocalizedString("cad.kind.basic_wing", comment: "")
        case .framePlate:     return NSLocalizedString("cad.kind.frame_plate", comment: "")
        case .beam:           return NSLocalizedString("cad.kind.beam", comment: "")
        case .tube:           return NSLocalizedString("cad.kind.tube", comment: "")
        case .mountBracket:   return NSLocalizedString("cad.kind.mount_bracket", comment: "")
        case .payloadBox:     return NSLocalizedString("cad.kind.payload_box", comment: "")
        case .sketch2D:       return NSLocalizedString("cad.kind.sketch", comment: "")
        case .extrudedSolid:  return NSLocalizedString("cad.kind.extruded_solid", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .basicWing:     return "airplane.circle"
        case .framePlate:    return "rectangle.fill"
        case .beam:          return "minus.rectangle.fill"
        case .tube:          return "cylinder"
        case .mountBracket:  return "angle"
        case .payloadBox:    return "shippingbox"
        case .sketch2D:      return "pencil.and.outline"
        case .extrudedSolid: return "square.3.layers.3d"
        }
    }
}
