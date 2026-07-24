import Foundation

/// Per-return surface classification, using ASPRS LAS class codes where one exists so an exported
/// cloud lands in standard tooling with the numbering analysts already expect.
///
/// The class is not guessed from geometry: it comes from the world that owns the triangle the beam
/// hit (see `FlyableWorld.surfaceClass(forTriangle:)`), which knows whether it built that triangle
/// as ground, a building wall, a road surface, a bridge deck, a tree or a support tower. Worlds
/// without that provenance — a photogrammetric mesh is a single textured surface with no semantics —
/// return `unclassified`, which is the honest answer rather than a plausible-looking invention.
enum LidarSurfaceClass: UInt8, CaseIterable, Codable, Sendable {
    case unclassified = 1
    case ground = 2
    case vegetation = 5
    case building = 6
    case water = 9
    case road = 11
    case bridgeDeck = 17
    /// Bridge pylons, anchorages and piers — LAS reserves 64+ for user definitions.
    case structure = 64

    var label: String {
        switch self {
        case .unclassified: return "unclassified"
        case .ground: return "ground"
        case .vegetation: return "vegetation"
        case .building: return "building"
        case .water: return "water"
        case .road: return "road"
        case .bridgeDeck: return "bridge"
        case .structure: return "structure"
        }
    }

    /// Distinct, high-contrast palette for reading the classification itself.
    var semanticColor: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .unclassified: return (150, 150, 155)
        case .ground: return (168, 120, 70)
        case .vegetation: return (60, 190, 75)
        case .building: return (235, 120, 90)
        case .water: return (60, 140, 235)
        case .road: return (185, 185, 195)
        case .bridgeDeck: return (245, 200, 70)
        case .structure: return (215, 105, 220)
        }
    }

    /// What the surface actually looks like, for the "real material colour" view — asphalt reads
    /// dark, foliage green, masonry warm grey.
    var materialColor: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .unclassified: return (140, 140, 140)
        case .ground: return (110, 112, 88)
        case .vegetation: return (46, 96, 44)
        case .building: return (168, 154, 140)
        case .water: return (32, 68, 92)
        case .road: return (58, 58, 62)
        case .bridgeDeck: return (72, 72, 76)
        case .structure: return (150, 140, 126)
        }
    }

    /// Diffuse reflectance at the sensor's wavelength, scaling the returned intensity. These follow
    /// the usual near-infrared ordering: fresh asphalt is dark, vegetation and dry ground are bright,
    /// and water is near-black because it reflects the beam away from the sensor.
    var reflectance: Float {
        switch self {
        case .unclassified: return 0.45
        case .ground: return 0.55
        case .vegetation: return 0.62
        case .building: return 0.50
        case .water: return 0.06
        case .road: return 0.22
        case .bridgeDeck: return 0.28
        case .structure: return 0.45
        }
    }
}

/// How the point cloud is coloured, both on screen and in the exported RGB channel.
enum LidarColorMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case height
    case intensity
    case material
    case semantic

    var id: String { rawValue }

    var shortLabelKey: String {
        switch self {
        case .height: return "lidar.color.height"
        case .intensity: return "lidar.color.intensity"
        case .material: return "lidar.color.material"
        case .semantic: return "lidar.color.semantic"
        }
    }
}

/// Voxel edge lengths offered for the survey filter. 0.1 m resolves window reveals and railings;
/// 1.0 m is a fast massing pass.
enum LidarVoxelSize: Float, CaseIterable, Codable, Sendable, Identifiable {
    case fine = 0.1
    case medium = 0.25
    case coarse = 0.5
    case massing = 1.0

    var id: String { String(rawValue) }

    var label: String {
        switch self {
        case .fine: return "0.1"
        case .medium: return "0.25"
        case .coarse: return "0.5"
        case .massing: return "1.0"
        }
    }
}
