import Foundation
import simd

enum UAVEstimatedDataQuality: String, Hashable {
    case official
    case derived
    case estimated
}

struct UAVProfile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let manufacturer: String
    let countryOfOrigin: String?
    let vehicleType: UAVVehicleType
    let massCategory: UAVMassCategory?
    let specConfidence: UAVSpecConfidence
    let payloadCapabilityMode: UAVPayloadCapabilityMode
    let baseMass: Float?
    let batteryMass: Float?
    let estimatedBatteryMass: Float?
    let maxPayloadMass: Float?
    let estimatedMaxPayloadMass: Float?
    let maxTakeoffMass: Float?
    let estimatedMaxTakeoffMass: Float?
    let dimensions: UAVDimensions
    let payloadMountOffset: SIMD3<Float>
    let visualPreset: UAVVisualPreset
    let shortDescription: String
    let notes: String
    let missionRole: String?
    let armamentCapabilityNote: String?
    let flightTuningProfile: UAVFlightTuningProfile
    let nominalFlightTimeSec: Float?
    let nominalCruiseSpeedMps: Float?
    let nominalMaxRangeM: Float?
    let nominalLinkRangeM: Float?
    let batteryReserveFraction: Float?
    let payloadRangePenaltyPerKg: Float?
    let climbConsumptionMultiplier: Float?
    let hoverConsumptionMultiplier: Float?
    let turnConsumptionMultiplier: Float?
    let loiterConsumptionMultiplier: Float?
    let minSafeAirspeedMps: Float?
    let preferredMapScaleMin: MapScale?
    let preferredMapScaleMax: MapScale?
    let estimatedDataQuality: UAVEstimatedDataQuality

    init(
        id: String,
        displayName: String,
        manufacturer: String,
        countryOfOrigin: String? = nil,
        vehicleType: UAVVehicleType,
        massCategory: UAVMassCategory?,
        specConfidence: UAVSpecConfidence,
        payloadCapabilityMode: UAVPayloadCapabilityMode,
        baseMass: Float?,
        batteryMass: Float?,
        estimatedBatteryMass: Float? = nil,
        maxPayloadMass: Float?,
        estimatedMaxPayloadMass: Float? = nil,
        maxTakeoffMass: Float?,
        estimatedMaxTakeoffMass: Float? = nil,
        dimensions: UAVDimensions,
        payloadMountOffset: SIMD3<Float>,
        visualPreset: UAVVisualPreset,
        shortDescription: String,
        notes: String,
        missionRole: String? = nil,
        armamentCapabilityNote: String? = nil,
        flightTuningProfile: UAVFlightTuningProfile? = nil,
        nominalFlightTimeSec: Float? = nil,
        nominalCruiseSpeedMps: Float? = nil,
        nominalMaxRangeM: Float? = nil,
        nominalLinkRangeM: Float? = nil,
        batteryReserveFraction: Float? = nil,
        payloadRangePenaltyPerKg: Float? = nil,
        climbConsumptionMultiplier: Float? = nil,
        hoverConsumptionMultiplier: Float? = nil,
        turnConsumptionMultiplier: Float? = nil,
        loiterConsumptionMultiplier: Float? = nil,
        minSafeAirspeedMps: Float? = nil,
        preferredMapScaleMin: MapScale? = nil,
        preferredMapScaleMax: MapScale? = nil,
        estimatedDataQuality: UAVEstimatedDataQuality? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.countryOfOrigin = countryOfOrigin
        self.vehicleType = vehicleType
        self.massCategory = massCategory
        self.specConfidence = specConfidence
        self.payloadCapabilityMode = payloadCapabilityMode
        self.baseMass = baseMass
        self.batteryMass = batteryMass
        self.estimatedBatteryMass = estimatedBatteryMass
        self.maxPayloadMass = maxPayloadMass
        self.estimatedMaxPayloadMass = estimatedMaxPayloadMass
        self.maxTakeoffMass = maxTakeoffMass
        self.estimatedMaxTakeoffMass = estimatedMaxTakeoffMass
        self.dimensions = dimensions
        self.payloadMountOffset = payloadMountOffset
        self.visualPreset = visualPreset
        self.shortDescription = shortDescription
        self.notes = notes
        self.missionRole = missionRole
        self.armamentCapabilityNote = armamentCapabilityNote
        self.nominalFlightTimeSec = nominalFlightTimeSec
        self.nominalCruiseSpeedMps = nominalCruiseSpeedMps
        self.nominalMaxRangeM = nominalMaxRangeM
        self.nominalLinkRangeM = nominalLinkRangeM
        self.batteryReserveFraction = batteryReserveFraction
        self.payloadRangePenaltyPerKg = payloadRangePenaltyPerKg
        self.climbConsumptionMultiplier = climbConsumptionMultiplier
        self.hoverConsumptionMultiplier = hoverConsumptionMultiplier
        self.turnConsumptionMultiplier = turnConsumptionMultiplier
        self.loiterConsumptionMultiplier = loiterConsumptionMultiplier
        self.minSafeAirspeedMps = minSafeAirspeedMps
        self.preferredMapScaleMin = preferredMapScaleMin
        self.preferredMapScaleMax = preferredMapScaleMax
        self.estimatedDataQuality = estimatedDataQuality ?? {
            switch specConfidence {
            case .verified:
                return .derived
            case .partial:
                return .derived
            case .custom:
                return .estimated
            }
        }()
        self.flightTuningProfile = flightTuningProfile ?? UAVFlightTuningProfile.catalogDefault(
            vehicleType: vehicleType,
            specConfidence: specConfidence,
            baseMass: baseMass,
            batteryMass: batteryMass,
            estimatedBatteryMass: estimatedBatteryMass,
            maxPayloadMass: maxPayloadMass,
            estimatedMaxPayloadMass: estimatedMaxPayloadMass,
            maxTakeoffMass: maxTakeoffMass,
            estimatedMaxTakeoffMass: estimatedMaxTakeoffMass,
            visualPreset: visualPreset
        )
    }
}

extension UAVProfile {
    var localizedDisplayName: String {
        localizedCatalogString(key: "uav.profile.\(id).display_name", fallback: displayName)
    }

    var localizedManufacturer: String {
        switch manufacturer {
        case "Custom":
            return localizedCatalogString(key: "uav.manufacturer.custom", fallback: manufacturer)
        default:
            return manufacturer
        }
    }

    var localizedCountryOfOrigin: String? {
        guard let countryOfOrigin else {
            return nil
        }

        switch countryOfOrigin {
        case "China":
            return localizedCatalogString(key: "country.china", fallback: countryOfOrigin)
        case "United States":
            return localizedCatalogString(key: "country.united_states", fallback: countryOfOrigin)
        case "Norway":
            return localizedCatalogString(key: "country.norway", fallback: countryOfOrigin)
        case "Switzerland":
            return localizedCatalogString(key: "country.switzerland", fallback: countryOfOrigin)
        case "Germany":
            return localizedCatalogString(key: "country.germany", fallback: countryOfOrigin)
        case "Sweden":
            return localizedCatalogString(key: "country.sweden", fallback: countryOfOrigin)
        case "Israel":
            return localizedCatalogString(key: "country.israel", fallback: countryOfOrigin)
        case "Poland":
            return localizedCatalogString(key: "country.poland", fallback: countryOfOrigin)
        case "Canada":
            return localizedCatalogString(key: "country.canada", fallback: countryOfOrigin)
        case "User Defined":
            return localizedCatalogString(key: "country.user_defined", fallback: countryOfOrigin)
        default:
            return countryOfOrigin
        }
    }

    var localizedShortDescription: String {
        localizedCatalogString(key: "uav.profile.\(id).short_description", fallback: shortDescription)
    }

    var localizedMissionRole: String? {
        guard let missionRole else {
            return nil
        }

        return localizedCatalogString(key: "uav.profile.\(id).mission_role", fallback: missionRole)
    }

    var localizedArmamentCapabilityNote: String? {
        guard let armamentCapabilityNote, armamentCapabilityNote.isEmpty == false else {
            return nil
        }

        return localizedCatalogString(key: "uav.profile.\(id).armament_note", fallback: armamentCapabilityNote)
    }

    var payloadDataResolution: PayloadDataResolution {
        let resolvedBatteryMass = batteryMass ?? estimatedBatteryMass
        let resolvedMaxPayloadMass = maxPayloadMass ?? estimatedMaxPayloadMass
        let resolvedMaxTakeoffMass = maxTakeoffMass ?? estimatedMaxTakeoffMass

        let derivedBaseMass: Float?
        if baseMass == nil,
           let resolvedBatteryMass,
           let resolvedMaxPayloadMass,
           let resolvedMaxTakeoffMass {
            let inferred = resolvedMaxTakeoffMass - resolvedBatteryMass - resolvedMaxPayloadMass
            derivedBaseMass = inferred > 0.01 ? inferred : nil
        } else {
            derivedBaseMass = nil
        }

        let usesEstimatedValues = estimatedBatteryMass != nil && batteryMass == nil ||
            estimatedMaxPayloadMass != nil && maxPayloadMass == nil ||
            estimatedMaxTakeoffMass != nil && maxTakeoffMass == nil ||
            derivedBaseMass != nil && baseMass == nil

        let sourceQuality: PayloadDataQualitySource
        if specConfidence == .custom {
            sourceQuality = .custom
        } else if usesEstimatedValues {
            sourceQuality = .estimated
        } else {
            sourceQuality = .verified
        }

        return PayloadDataResolution(
            baseMass: baseMass ?? derivedBaseMass,
            batteryMass: resolvedBatteryMass,
            maxPayloadMass: resolvedMaxPayloadMass,
            maxTakeoffMass: resolvedMaxTakeoffMass,
            sourceQuality: sourceQuality,
            usesEstimatedValues: usesEstimatedValues
        )
    }
}

private func localizedCatalogString(key: String, fallback: String) -> String {
    let localized = NSLocalizedString(key, comment: "")
    return localized == key ? fallback : localized
}
