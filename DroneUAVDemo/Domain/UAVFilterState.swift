import Foundation

enum UAVVehicleTypeFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case multicopters
    case helicopters
    case fixedWing
    case hybridVTOL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.s("uav.filter.vehicle.all")
        case .multicopters:
            return L10n.s("uav.filter.vehicle.multicopters")
        case .helicopters:
            return L10n.s("uav.filter.vehicle.helicopters")
        case .fixedWing:
            return L10n.s("uav.filter.vehicle.fixed_wing")
        case .hybridVTOL:
            return L10n.s("uav.filter.vehicle.hybrid_vtol")
        }
    }

    func matches(_ profile: UAVProfile) -> Bool {
        switch self {
        case .all:
            return true
        case .multicopters:
            return profile.vehicleType == .multicopter
        case .helicopters:
            return profile.vehicleType == .helicopter
        case .fixedWing:
            return profile.vehicleType == .fixedWing
        case .hybridVTOL:
            return profile.vehicleType == .hybridVTOL
        }
    }
}

enum UAVMassCategoryFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case nano
    case micro
    case light
    case medium
    case heavy
    case superheavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.s("uav.filter.mass.all")
        case .nano:
            return L10n.s("uav.filter.mass.nano")
        case .micro:
            return L10n.s("uav.filter.mass.micro")
        case .light:
            return L10n.s("uav.filter.mass.light")
        case .medium:
            return L10n.s("uav.filter.mass.medium")
        case .heavy:
            return L10n.s("uav.filter.mass.heavy")
        case .superheavy:
            return L10n.s("uav.filter.mass.superheavy")
        }
    }

    func matches(_ profile: UAVProfile) -> Bool {
        switch self {
        case .all:
            return true
        case .nano:
            return profile.massCategory == .nano
        case .micro:
            return profile.massCategory == .micro
        case .light:
            return profile.massCategory == .light
        case .medium:
            return profile.massCategory == .medium
        case .heavy:
            return profile.massCategory == .heavy
        case .superheavy:
            return profile.massCategory == .superheavy
        }
    }
}

struct UAVFilterState: Hashable {
    var vehicleType: UAVVehicleTypeFilter = .all
    var massCategory: UAVMassCategoryFilter = .all
}

extension UAVVehicleType {
    var catalogTitle: String {
        switch self {
        case .multicopter:
            return L10n.s("uav.vehicle.multicopter")
        case .fixedWing:
            return L10n.s("uav.vehicle.fixed_wing")
        case .hybridVTOL:
            return L10n.s("uav.vehicle.hybrid_vtol")
        case .helicopter:
            return L10n.s("uav.vehicle.helicopter")
        case .custom:
            return L10n.s("uav.vehicle.custom")
        }
    }
}

extension UAVMassCategory {
    var catalogTitle: String {
        switch self {
        case .nano:
            return L10n.s("uav.mass.nano")
        case .micro:
            return L10n.s("uav.mass.micro")
        case .light:
            return L10n.s("uav.mass.light")
        case .medium:
            return L10n.s("uav.mass.medium")
        case .heavy:
            return L10n.s("uav.mass.heavy")
        case .superheavy:
            return L10n.s("uav.mass.superheavy")
        case .custom:
            return L10n.s("uav.mass.custom")
        }
    }
}

extension UAVSpecConfidence {
    var catalogTitle: String {
        switch self {
        case .verified:
            return L10n.s("uav.spec.verified")
        case .partial:
            return L10n.s("uav.spec.partial")
        case .custom:
            return L10n.s("uav.spec.custom")
        }
    }
}
