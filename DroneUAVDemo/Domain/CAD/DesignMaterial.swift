import Foundation

enum DesignMaterial: String, Codable, CaseIterable, Identifiable {
    case plastic
    case carbonFiber
    case aluminum
    case steel
    case composite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plastic: return NSLocalizedString("cad.material.plastic", comment: "")
        case .carbonFiber: return NSLocalizedString("cad.material.carbon_fiber", comment: "")
        case .aluminum: return NSLocalizedString("cad.material.aluminum", comment: "")
        case .steel: return NSLocalizedString("cad.material.steel", comment: "")
        case .composite: return NSLocalizedString("cad.material.composite", comment: "")
        }
    }

    var densityKgPerM3: Double {
        switch self {
        case .plastic: return 1200.0
        case .carbonFiber: return 1600.0
        case .aluminum: return 2700.0
        case .steel: return 7800.0
        case .composite: return 1400.0
        }
    }

    var previewColorRGB: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .plastic: return (0.85, 0.85, 0.90)
        case .carbonFiber: return (0.12, 0.12, 0.14)
        case .aluminum: return (0.76, 0.78, 0.82)
        case .steel: return (0.55, 0.57, 0.60)
        case .composite: return (0.28, 0.32, 0.38)
        }
    }
}
