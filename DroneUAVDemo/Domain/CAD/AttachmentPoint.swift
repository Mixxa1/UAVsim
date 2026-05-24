import Foundation

struct DesignVector3: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = DesignVector3(x: 0, y: 0, z: 0)
}

extension DesignVector3 {
    static let xAxis = DesignVector3(x: 1, y: 0, z: 0)
    static let yAxis = DesignVector3(x: 0, y: 1, z: 0)
    static let zAxis = DesignVector3(x: 0, y: 0, z: 1)

    static func + (lhs: DesignVector3, rhs: DesignVector3) -> DesignVector3 {
        DesignVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: DesignVector3, rhs: DesignVector3) -> DesignVector3 {
        DesignVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func * (lhs: DesignVector3, rhs: Double) -> DesignVector3 {
        DesignVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func * (lhs: Double, rhs: DesignVector3) -> DesignVector3 {
        rhs * lhs
    }

    func dot(_ other: DesignVector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: DesignVector3) -> DesignVector3 {
        DesignVector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    var length: Double {
        sqrt(dot(self))
    }

    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    func normalized(fallback: DesignVector3 = .zAxis) -> DesignVector3 {
        let len = length
        guard len > 1e-9 else { return fallback }
        return DesignVector3(x: x / len, y: y / len, z: z / len)
    }
}

enum AttachmentRole: String, Codable, CaseIterable, Identifiable {
    case frame
    case wing
    case payload
    case camera
    case sensor
    case landingGear
    case motor
    case battery
    case antenna
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frame: return NSLocalizedString("cad.role.frame", comment: "")
        case .wing: return NSLocalizedString("cad.role.wing", comment: "")
        case .payload: return NSLocalizedString("cad.role.payload", comment: "")
        case .camera: return NSLocalizedString("cad.role.camera", comment: "")
        case .sensor: return NSLocalizedString("cad.role.sensor", comment: "")
        case .landingGear: return NSLocalizedString("cad.role.landing_gear", comment: "")
        case .motor: return NSLocalizedString("cad.role.motor", comment: "")
        case .battery: return NSLocalizedString("cad.role.battery", comment: "")
        case .antenna: return NSLocalizedString("cad.role.antenna", comment: "")
        case .generic: return NSLocalizedString("cad.role.generic", comment: "")
        }
    }

    var markerRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .frame: return (0.30, 0.85, 0.40)
        case .wing: return (0.30, 0.75, 1.00)
        case .payload: return (1.00, 0.60, 0.20)
        case .camera: return (0.72, 0.45, 1.00)
        case .sensor: return (1.00, 0.90, 0.25)
        case .landingGear: return (0.62, 0.64, 0.68)
        case .motor: return (1.00, 0.32, 0.26)
        case .battery: return (0.18, 0.86, 0.78)
        case .antenna: return (0.94, 0.96, 1.00)
        case .generic: return (0.60, 0.60, 0.62)
        }
    }
}

struct AttachmentPoint: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var localPosition: DesignVector3
    var localRotation: DesignVector3
    var role: AttachmentRole
    var isSystem: Bool
    var isEnabled: Bool

    var localX: Double {
        get { localPosition.x }
        set { localPosition.x = newValue }
    }

    var localY: Double {
        get { localPosition.y }
        set { localPosition.y = newValue }
    }

    var localZ: Double {
        get { localPosition.z }
        set { localPosition.z = newValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        localX: Double,
        localY: Double,
        localZ: Double,
        role: AttachmentRole,
        isSystem: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.localPosition = DesignVector3(x: localX, y: localY, z: localZ)
        self.localRotation = .zero
        self.role = role
        self.isSystem = isSystem
        self.isEnabled = isEnabled
    }

    init(
        id: UUID = UUID(),
        name: String,
        localPosition: DesignVector3,
        localRotation: DesignVector3 = .zero,
        role: AttachmentRole,
        isSystem: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.localPosition = localPosition
        self.localRotation = localRotation
        self.role = role
        self.isSystem = isSystem
        self.isEnabled = isEnabled
    }
}

extension AttachmentPoint {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case localPosition
        case localRotation
        case role
        case isSystem
        case isEnabled
        case localX
        case localY
        case localZ
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        role = try container.decodeIfPresent(AttachmentRole.self, forKey: .role) ?? .generic
        isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

        if let position = try container.decodeIfPresent(DesignVector3.self, forKey: .localPosition) {
            localPosition = position
        } else {
            localPosition = DesignVector3(
                x: try container.decodeIfPresent(Double.self, forKey: .localX) ?? 0,
                y: try container.decodeIfPresent(Double.self, forKey: .localY) ?? 0,
                z: try container.decodeIfPresent(Double.self, forKey: .localZ) ?? 0
            )
        }

        localRotation = try container.decodeIfPresent(DesignVector3.self, forKey: .localRotation) ?? .zero
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(localPosition, forKey: .localPosition)
        try container.encode(localRotation, forKey: .localRotation)
        try container.encode(role, forKey: .role)
        try container.encode(isSystem, forKey: .isSystem)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}
