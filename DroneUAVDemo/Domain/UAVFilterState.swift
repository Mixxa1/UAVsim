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
            return NSLocalizedString("uav.filter.vehicle.all", comment: "")
        case .multicopters:
            return NSLocalizedString("uav.filter.vehicle.multicopters", comment: "")
        case .helicopters:
            return NSLocalizedString("uav.filter.vehicle.helicopters", comment: "")
        case .fixedWing:
            return NSLocalizedString("uav.filter.vehicle.fixed_wing", comment: "")
        case .hybridVTOL:
            return NSLocalizedString("uav.filter.vehicle.hybrid_vtol", comment: "")
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return NSLocalizedString("uav.filter.mass.all", comment: "")
        case .nano:
            return NSLocalizedString("uav.filter.mass.nano", comment: "")
        case .micro:
            return NSLocalizedString("uav.filter.mass.micro", comment: "")
        case .light:
            return NSLocalizedString("uav.filter.mass.light", comment: "")
        case .medium:
            return NSLocalizedString("uav.filter.mass.medium", comment: "")
        case .heavy:
            return NSLocalizedString("uav.filter.mass.heavy", comment: "")
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
            return NSLocalizedString("uav.vehicle.multicopter", comment: "")
        case .fixedWing:
            return NSLocalizedString("uav.vehicle.fixed_wing", comment: "")
        case .hybridVTOL:
            return NSLocalizedString("uav.vehicle.hybrid_vtol", comment: "")
        case .helicopter:
            return NSLocalizedString("uav.vehicle.helicopter", comment: "")
        case .custom:
            return NSLocalizedString("uav.vehicle.custom", comment: "")
        }
    }
}

extension UAVMassCategory {
    var catalogTitle: String {
        switch self {
        case .nano:
            return NSLocalizedString("uav.mass.nano", comment: "")
        case .micro:
            return NSLocalizedString("uav.mass.micro", comment: "")
        case .light:
            return NSLocalizedString("uav.mass.light", comment: "")
        case .medium:
            return NSLocalizedString("uav.mass.medium", comment: "")
        case .heavy:
            return NSLocalizedString("uav.mass.heavy", comment: "")
        case .custom:
            return NSLocalizedString("uav.mass.custom", comment: "")
        }
    }
}

extension UAVSpecConfidence {
    var catalogTitle: String {
        switch self {
        case .verified:
            return NSLocalizedString("uav.spec.verified", comment: "")
        case .partial:
            return NSLocalizedString("uav.spec.partial", comment: "")
        case .custom:
            return NSLocalizedString("uav.spec.custom", comment: "")
        }
    }
}
