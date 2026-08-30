import Foundation
import simd

enum UAVEstimatedDataQuality: String, Hashable {
    case official
    case derived
    case estimated
}

// MARK: - Energy source / powerplant descriptors
//
// Data-only for now. The flight model still draws every aircraft's energy from
// `BatteryState`, exactly as before — nothing here is read by the physics step.
// These fields exist so a fuel-burning airframe carries its *real* propulsion and
// tank figures in the catalogue instead of them being flattened into an invented
// battery capacity, and so the later fuel/propulsion subsystem has a source of
// truth to read rather than a table to invent. Every field is optional and
// defaulted, so all pre-existing profiles stay literally unchanged and keep
// reporting `.battery`.

enum UAVEnergySourceType: String, Hashable {
    case battery
    case fuel
}

enum UAVFuelType: String, Hashable {
    /// AvGas / MoGas burned by a spark-ignition piston or rotary engine.
    case gasoline
    /// JP-5 / JP-8 / Jet-A burned by a *piston* engine (heavy-fuel engine, HFE).
    case heavyFuel
    /// Jet-A / JP-8 burned by a turbine (turboprop or turbojet).
    case turbineKerosene

    /// Lower heating value, Wh per kg. Used to convert a published tank size into
    /// an energy figure; it is chemical energy in the fuel, not shaft or
    /// propulsive energy, so any consumer must still apply an efficiency.
    var energyDensityWhPerKg: Float {
        switch self {
        case .gasoline: return 12_200.0
        case .heavyFuel, .turbineKerosene: return 11_900.0
        }
    }

    /// Typical density at 15 °C, kg per litre — for tanks published as a volume.
    var densityKgPerLiter: Float {
        switch self {
        case .gasoline: return 0.72
        case .heavyFuel, .turbineKerosene: return 0.80
        }
    }

    var localizationKey: String { "uav.fuel.type.\(rawValue)" }
}

enum UAVEngineType: String, Hashable {
    case electricMotor
    case pistonTwoStroke
    case pistonFourStroke
    case wankelRotary
    case turboprop
    case turbojet
    /// Ram compression only — no compressor, no turbine, no moving parts in the gas
    /// path at all.
    ///
    /// The one engine here that cannot be started. It has nothing to compress the air
    /// but the aircraft's own speed, so on the ground it makes no thrust whatsoever and
    /// there is no throttle setting that changes that. Something else has to deliver it
    /// to its operating Mach first — which is why every ramjet aircraft ever built was
    /// either air-launched or sat on top of a booster.
    case ramjet

    /// Does this engine burn fuel that has to be carried as consumable mass?
    var consumesFuel: Bool { self != .electricMotor }

    /// Can this engine produce useful thrust standing still?
    ///
    /// False only for the ramjet, and the distinction is load-bearing rather than
    /// descriptive: a launch sequence that waits for a running engine before releasing
    /// the aircraft would wait for ever.
    var producesStaticThrust: Bool { self != .ramjet }

    var localizationKey: String { "uav.engine.type.\(rawValue)" }
}

/// What is in front of the engine.
///
/// Not cosmetic, and not a detail that can be folded into a single thrust number. Above
/// Mach 1 the intake decides how much of the free stream's total pressure ever reaches
/// the engine, and the answer differs by a factor of two between a plain hole and a
/// variable ramp. It is most of why one supersonic aircraft tops out at Mach 1.6 and
/// another with a similar engine reaches Mach 3.
enum UAVInletType: String, Hashable, Codable, CaseIterable {
    /// No intake to model — anything driving a propeller.
    case none
    /// A plain forward-facing opening. Swallows one normal shock, which is cheap to
    /// build and expensive to fly: past about Mach 1.6 most of the total pressure is
    /// lost across that single shock and the engine is being starved.
    case pitot
    /// A fixed cone, wedge or splitter plate that stages the compression through
    /// oblique shocks. Very good at the Mach it was shaped for and progressively worse
    /// away from it, in both directions.
    case fixedRamp
    /// Moving ramps or a translating spike, scheduled with flight condition. The only
    /// arrangement that holds good recovery across a wide Mach range, and the reason
    /// aircraft designed for Mach 2 and above carry the mechanism's weight and
    /// complexity.
    case variableRamp

    var localizationKey: String { "uav.inlet.type.\(rawValue)" }
}

enum UAVPropellerPlacement: String, Hashable {
    case tractor
    case pusher
}

/// Where the engine is started from.
///
/// Not a cosmetic distinction. A canister-launched loitering munition does not
/// start its engine on the ground at all: it is ejected by a rocket booster,
/// unfolds its wings, and only then lights the piston engine. Modelling that as a
/// ground start would let the operator run the engine inside a sealed tube.
enum UAVEngineStartPolicy: String, Hashable {
    /// Started and stabilised before the aircraft is launched — runway, catapult,
    /// rail or dolly.
    case groundStartBeforeLaunch
    /// Started in flight once the booster has separated and the airframe has
    /// flying speed.
    case airStartAfterBoost

    var localizationKey: String { "uav.engine.start_policy.\(rawValue)" }
}

/// How the engine is cranked. Determines whether a start can be attempted at all
/// and how the crank phase behaves.
enum UAVEngineStarterKind: String, Hashable {
    /// No starter — an electric motor is simply commanded.
    case none
    /// Electric starter or starter-generator, the usual small-UAV installation.
    case electricStarter
    /// Bleed/air motor, typical of a turbine on a ground cart.
    case airTurbineStarter
    /// Single-use pyrotechnic cartridge — one attempt, then the engine must
    /// windmill-start or the launch is lost.
    case pyrotechnicCartridge

    var localizationKey: String { "uav.engine.starter.\(rawValue)" }

    /// A cartridge is expended on use; everything else can be re-attempted.
    var supportsRestart: Bool { self != .pyrotechnicCartridge }
}

/// One aircraft's published fuel installation.
struct UAVFuelSpec: Hashable {
    let fuelType: UAVFuelType
    /// Usable fuel mass at full tanks, kg. The authoritative figure — volume is
    /// derived from it when a source only publishes one of the two.
    let usableFuelMassKg: Float
    /// Fraction of usable fuel a mission planner should hold back as reserve.
    let reserveFraction: Float
    /// Number of separate tanks in the real installation. Kept even though the
    /// runtime models a single quantity, so a later multi-tank/crossfeed model
    /// does not have to re-source this.
    let tankCount: Int

    init(
        fuelType: UAVFuelType,
        usableFuelMassKg: Float? = nil,
        usableFuelLiters: Float? = nil,
        reserveFraction: Float = 0.20,
        tankCount: Int = 1
    ) {
        self.fuelType = fuelType
        if let usableFuelMassKg {
            self.usableFuelMassKg = max(0.0, usableFuelMassKg)
        } else if let usableFuelLiters {
            self.usableFuelMassKg = max(0.0, usableFuelLiters) * fuelType.densityKgPerLiter
        } else {
            self.usableFuelMassKg = 0.0
        }
        self.reserveFraction = reserveFraction.clampedFraction(to: 0.0...0.5)
        self.tankCount = max(1, tankCount)
    }

    var usableFuelLiters: Float {
        usableFuelMassKg / fuelType.densityKgPerLiter
    }

    /// Chemical energy in a full usable load, Wh.
    var usableFuelEnergyWh: Float {
        usableFuelMassKg * fuelType.energyDensityWhPerKg
    }
}

/// One aircraft's published propulsion installation.
struct UAVPowerplantSpec: Hashable {
    let engineType: UAVEngineType
    /// Manufacturer designation, e.g. "Lycoming EL-005", "UEL AR-741".
    let engineDesignation: String?
    let engineCount: Int
    /// Rated shaft power per engine, kW — piston, rotary and turboprop.
    let ratedShaftPowerKW: Float?
    /// Rated static thrust per engine, N — turbojet.
    let ratedThrustN: Float?
    let propellerPlacement: UAVPropellerPlacement?
    let propellerDiameterM: Float?
    /// Propeller-shaft speed at rated power, rev/min — the *output* shaft, so it is
    /// already through any reduction gearbox. This is what sizes the propeller: a
    /// 5,500 rpm two-stroke and a 1,591 rpm turboprop shaft need very different
    /// discs to absorb their power.
    let ratedShaftRPM: Float?
    /// Blade count. Only used to shape the propeller's power coefficient.
    let propellerBladeCount: Int
    let starter: UAVEngineStarterKind
    let startPolicy: UAVEngineStartPolicy
    let fuel: UAVFuelSpec?
    /// Intake arrangement. Defaults to `.none` for anything driving a propeller and to
    /// `.pitot` for a jet, which is what every jet already in the catalogue has — so no
    /// existing profile changes by gaining this field.
    let inletType: UAVInletType
    /// Free-stream Mach the intake is shaped for. Only meaningful for a ramp inlet: a
    /// fixed ramp is cut for one condition and pays for being anywhere else.
    let inletDesignMach: Float

    init(
        engineType: UAVEngineType,
        engineDesignation: String? = nil,
        engineCount: Int = 1,
        ratedShaftPowerKW: Float? = nil,
        ratedThrustN: Float? = nil,
        propellerPlacement: UAVPropellerPlacement? = nil,
        propellerDiameterM: Float? = nil,
        ratedShaftRPM: Float? = nil,
        propellerBladeCount: Int = 2,
        starter: UAVEngineStarterKind? = nil,
        startPolicy: UAVEngineStartPolicy = .groundStartBeforeLaunch,
        fuel: UAVFuelSpec? = nil,
        inletType: UAVInletType? = nil,
        inletDesignMach: Float = 2.0
    ) {
        self.engineType = engineType
        self.engineDesignation = engineDesignation
        self.engineCount = max(1, engineCount)
        self.ratedShaftPowerKW = ratedShaftPowerKW
        self.ratedThrustN = ratedThrustN
        self.propellerPlacement = propellerPlacement
        self.propellerDiameterM = propellerDiameterM
        self.ratedShaftRPM = ratedShaftRPM
        self.propellerBladeCount = max(1, propellerBladeCount)
        self.starter = starter ?? (engineType == .electricMotor ? .none : .electricStarter)
        self.startPolicy = startPolicy
        self.fuel = fuel
        self.inletType = inletType ?? {
            switch engineType {
            case .turbojet, .ramjet:
                // A plain pitot intake is what every jet already catalogued has, and it
                // is the honest default: assuming a variable ramp would hand an
                // uncharacterised aircraft the Mach 3 capability that mechanism buys.
                return .pitot
            case .electricMotor, .pistonTwoStroke, .pistonFourStroke, .wankelRotary, .turboprop:
                return .none
            }
        }()
        self.inletDesignMach = max(1.0, inletDesignMach)
    }

    /// True for anything that drives a propeller — piston, rotary and turboprop.
    var drivesPropeller: Bool {
        engineType != .turbojet && propellerDiameterM != nil
    }

    /// True where the propeller is governed — its blade angle changes to hold a
    /// commanded shaft speed instead of the shaft speed floating to wherever a
    /// fixed blade angle happens to balance the engine.
    ///
    /// This is not a cosmetic distinction. A fixed-pitch disc absorbs power with
    /// the cube of shaft speed, so an engine that makes little power at low speed
    /// settles at whatever low speed the disc will let it reach — for the MQ-9A's
    /// TPE331 that equilibrium was 840 rpm of a rated 1,591 and 84 kW of a rated
    /// 671, which is why it needed three kilometres of ground roll to reach flying
    /// speed. A governed disc coarsens as the aircraft accelerates, so the engine
    /// is at rated speed and full power from brake release, which is precisely
    /// what makes a turboprop takeoff possible.
    var hasConstantSpeedPropeller: Bool {
        drivesPropeller && engineType == .turboprop
    }

    var energySource: UAVEnergySourceType {
        engineType.consumesFuel && fuel != nil ? .fuel : .battery
    }

    var totalRatedShaftPowerKW: Float? {
        ratedShaftPowerKW.map { $0 * Float(engineCount) }
    }

    var totalRatedThrustN: Float? {
        ratedThrustN.map { $0 * Float(engineCount) }
    }
}

private extension Float {
    func clampedFraction(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
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
    /// Altitude the aircraft normally works at, m.
    ///
    /// Added with the supersonic aircraft because their endurance figures stop making
    /// sense without it. A turbojet's fuel flow follows ambient pressure, so the same
    /// throttle burns six times as much at 1.5 km as it does at 14 km — and every
    /// published turbojet endurance is a high-altitude figure. Judged down low, a Firebee
    /// II empties its tanks in twenty-eight minutes against a published seventy-three,
    /// which is a statement about where the measurement was taken rather than about the
    /// aircraft. `nil` means the aircraft works low, which is true of everything that
    /// predates this field.
    let nominalCruiseAltitudeMeters: Float?
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
    let navigationCapability: NavigationCapability?
    let autonomyLevel: AutonomyLevel?
    let linkLossPolicy: LinkLossPolicy?
    /// Published propulsion + fuel installation. `nil` means "not catalogued yet",
    /// which resolves to battery-electric — the assumption every profile in this
    /// catalogue was written under before fuel aircraft existed.
    let powerplant: UAVPowerplantSpec?

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
        nominalCruiseAltitudeMeters: Float? = nil,
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
        estimatedDataQuality: UAVEstimatedDataQuality? = nil,
        navigationCapability: NavigationCapability? = nil,
        autonomyLevel: AutonomyLevel? = nil,
        linkLossPolicy: LinkLossPolicy? = nil,
        powerplant: UAVPowerplantSpec? = nil
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
        self.nominalCruiseAltitudeMeters = nominalCruiseAltitudeMeters
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
        self.navigationCapability = navigationCapability
        self.autonomyLevel = autonomyLevel
        self.linkLossPolicy = linkLossPolicy
        self.powerplant = powerplant
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
    /// Which kind of stored energy this aircraft actually flies on. Battery for
    /// every profile that predates the fuel catalogue work, since `powerplant`
    /// defaults to nil.
    var energySource: UAVEnergySourceType {
        powerplant?.energySource ?? .battery
    }

    var isFuelPowered: Bool { energySource == .fuel }

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
        case "Iran":
            return localizedCatalogString(key: "country.iran", fallback: countryOfOrigin)
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
