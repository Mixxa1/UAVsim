import Foundation
import simd

enum UAVReferenceCatalog {
    static let realProfiles: [UAVProfile] = [
        UAVProfile(
            id: "dji-matrice-350-rtk",
            displayName: "DJI Matrice 350 RTK",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .medium,
            specConfidence: .verified,
            payloadCapabilityMode: .modular,
            baseMass: 3.77,
            batteryMass: 2.70,
            maxPayloadMass: 0.96,
            maxTakeoffMass: 9.2,
            dimensions: UAVDimensions(
                foldedMillimeters: DroneDimensionsMM(x: 430, y: 420, z: 430),
                unfoldedMillimeters: DroneDimensionsMM(x: 810, y: 670, z: 430)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.18, 0.02),
            visualPreset: .djiMatrice350RTK,
            shortDescription: "Enterprise quadcopter with landing gear, central gimbal bay, and modular payload support.",
            notes: "DJI enterprise specifications list 3.77 kg without batteries, 6.47 kg with two TB65 batteries, 960 g single downward payload, and 9.2 kg max takeoff weight.",
            missionRole: "Enterprise inspection, mapping, and public-safety operations"
        ),
        UAVProfile(
            id: "dji-flycart-30",
            displayName: "DJI FlyCart 30",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .verified,
            payloadCapabilityMode: .cargo,
            baseMass: 42.5,
            batteryMass: 22.5,
            maxPayloadMass: 30.0,
            maxTakeoffMass: 95.0,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 2800, y: 3085, z: 947)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.34, 0.0),
            visualPreset: .djiFlyCart30,
            shortDescription: "Heavy cargo multicopter with coaxial lift groups and a central underslung freight bay.",
            notes: "DJI lists 42.5 kg aircraft weight without batteries, 65.0 kg with batteries, 30.0 kg payload in dual-battery mode, 40.0 kg in single-battery mode, and 95.0 kg max takeoff weight. Baseline keeps 30.0 kg as the safe standard payload limit.",
            missionRole: "Cargo transport and logistics"
        ),
        UAVProfile(
            id: "dji-mavic-4-pro",
            displayName: "DJI Mavic 4 Pro",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .micro,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.33,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 0.10,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 1.15,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.07, 0.09),
            visualPreset: .djiMavic4Pro,
            shortDescription: "Foldable consumer camera multicopter with a triple-camera forward gimbal section.",
            notes: "DJI official materials confirm a 1,063 g takeoff weight, 51-minute maximum flight time, and a 6,654 mAh intelligent flight battery. No official airframe-only base mass is inferred here.",
            missionRole: "Consumer aerial imaging and creator capture"
        ),
        UAVProfile(
            id: "dji-neo",
            displayName: "DJI Neo",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .nano,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: 0.045,
            estimatedBatteryMass: nil,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 0.02,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 0.155,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 130, y: 157, z: 48.5)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.035, 0.04),
            visualPreset: .djiNeo,
            shortDescription: "Ultra-compact protected-prop multicopter designed as a lightweight personal flying camera.",
            notes: "DJI official specifications list 135 g takeoff weight, 130×157×48.5 mm aircraft dimensions, and a 45 g intelligent flight battery. Base mass is left optional because DJI publishes ready-to-fly weight rather than a battery-separated airframe mass.",
            missionRole: "Personal aerial video capture"
        ),
        UAVProfile(
            id: "dji-phantom-3-standard",
            displayName: "DJI Phantom 3 Standard",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .micro,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.365,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 0.15,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 1.35,
            dimensions: UAVDimensions(
                diagonalWheelbaseMillimeters: 350
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.14, 0.08),
            visualPreset: .djiPhantom3Standard,
            shortDescription: "Classic Phantom consumer quadcopter with integrated landing gear and a front gimbal camera bay.",
            notes: "DJI official support materials list 1,216 g aircraft weight with battery and propellers and a 350 mm diagonal size. Battery-separated base mass and maximum payload figures are intentionally left unset.",
            missionRole: "Consumer aerial imaging"
        ),
        UAVProfile(
            id: "freefly-alta-x",
            displayName: "Freefly Alta X",
            manufacturer: "Freefly Systems",
            countryOfOrigin: "United States",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .verified,
            payloadCapabilityMode: .modular,
            baseMass: 10.86,
            batteryMass: nil,
            estimatedBatteryMass: 8.94,
            maxPayloadMass: 15.06,
            maxTakeoffMass: 34.86,
            dimensions: UAVDimensions(
                foldedMillimeters: DroneDimensionsMM(x: 877, y: 877, z: 387),
                unfoldedMillimeters: DroneDimensionsMM(x: 2273, y: 2273, z: 387)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.24, 0.0),
            visualPreset: .freeflyAltaX,
            shortDescription: "Heavy-lift open-frame cinema and industrial multirotor with a central underslung payload section.",
            notes: "Freefly specifications list 10.86 kg standard empty weight, 15.06 kg maximum payload, and 34.86 kg maximum gross takeoff weight.",
            missionRole: "Heavy-lift cinema and industrial payload carriage"
        ),
        UAVProfile(
            id: "griff-30",
            displayName: "Griff 30",
            manufacturer: "Griff Aviation",
            countryOfOrigin: "Norway",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 8.0,
            maxPayloadMass: 30.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 48.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.32, 0.0),
            visualPreset: .griff30,
            shortDescription: "Heavy-lift cargo UAV with a large transport frame and an underslung load zone.",
            notes: "Official Griff Aviation product materials confirm 30 kg maximum payload capacity. Other mass and size values are left optional rather than inferred.",
            missionRole: "Heavy-lift cargo transport"
        ),
        UAVProfile(
            id: "griff-60",
            displayName: "Griff 60",
            manufacturer: "Griff Aviation",
            countryOfOrigin: "Norway",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 14.0,
            maxPayloadMass: 60.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 92.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.42, 0.0),
            visualPreset: .griff60,
            shortDescription: "Large heavy-lift cargo UAV with a higher-capacity airframe than Griff 30.",
            notes: "Official Griff Aviation materials confirm an eight-rotor configuration and 60 kg maximum payload capacity. Additional mass figures are intentionally left optional.",
            missionRole: "Heavy-lift cargo transport"
        ),
        UAVProfile(
            id: "avidrone-490tl",
            displayName: "Avidrone 490TL",
            manufacturer: "Avidrone Aerospace",
            countryOfOrigin: "Canada",
            vehicleType: .helicopter,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 10.0,
            maxPayloadMass: 23.0,
            maxTakeoffMass: 57.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.30, 0.02),
            visualPreset: .avidrone490TL,
            shortDescription: "Tandem-rotor cargo UAV with a long central fuselage and underslung freight position.",
            notes: "Avidrone official fleet data lists 23 kg useful payload and 57 kg gross weight. The platform is modeled as a tandem-rotor cargo helicopter without inferring missing dimensions.",
            missionRole: "Cargo transport and utility lift"
        ),
        UAVProfile(
            id: "wingtraone-gen-ii",
            displayName: "WingtraOne GEN II",
            manufacturer: "Wingtra",
            countryOfOrigin: "Switzerland",
            vehicleType: .hybridVTOL,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.85,
            maxPayloadMass: 0.8,
            maxTakeoffMass: 4.5,
            dimensions: UAVDimensions(
                wingspanMillimeters: 1250
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.08, 0.06),
            visualPreset: .wingtraOneGenII,
            shortDescription: "Hybrid VTOL mapping aircraft with a belly survey compartment and fixed-wing cruise layout.",
            notes: "Wingtra official technical specifications confirm 4.5 kg maximum takeoff weight, 800 g payload capacity, and 125 cm wingspan.",
            missionRole: "Survey mapping and photogrammetry"
        ),
        UAVProfile(
            id: "quantum-systems-trinity-pro",
            displayName: "Quantum Systems Trinity Pro",
            manufacturer: "Quantum Systems",
            countryOfOrigin: "Germany",
            vehicleType: .hybridVTOL,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 1.25,
            maxPayloadMass: 1.0,
            maxTakeoffMass: 5.75,
            dimensions: UAVDimensions(
                wingspanMillimeters: 2394,
                fuselageLengthMillimeters: 1491
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.10, 0.14),
            visualPreset: .quantumSystemsTrinityPro,
            shortDescription: "Long-span eVTOL survey aircraft with a central sensor compartment under the fuselage.",
            notes: "Quantum Systems official materials confirm 5.75 kg maximum takeoff mass, 1.0 kg payload capacity, 2.394 m wingspan, and 1.491 m fuselage length.",
            missionRole: "Survey mapping and corridor inspection"
        ),
        UAVProfile(
            id: "mq-9b-skyguardian",
            displayName: "MQ-9B SkyGuardian",
            manufacturer: "General Atomics Aeronautical Systems",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 2177.0,
            maxTakeoffMass: 5670.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 24000,
                fuselageLengthMillimeters: 11700
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.18, 0.30),
            visualPreset: .mq9bSkyGuardian,
            shortDescription: "Large MALE fixed-wing platform with long wings, nose sensor architecture, and multi-hardpoint payload capacity.",
            notes: "GA-ASI official MQ-9B technical material lists 24 m wingspan, 11.7 m length, 5,670 kg max gross takeoff weight, and 2,177 kg payload capacity across nine hardpoints.",
            missionRole: "Long-endurance ISR and multi-mission patrol"
        ),
        UAVProfile(
            id: "hermes-900",
            displayName: "Hermes 900",
            manufacturer: "Elbit Systems",
            countryOfOrigin: "Israel",
            vehicleType: .fixedWing,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 350.0,
            maxTakeoffMass: 1180.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 15000
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.16, 0.22),
            visualPreset: .hermes900,
            shortDescription: "Multi-role MALE UAV with a long wing, pusher layout, and sensor stations under the nose and fuselage.",
            notes: "Elbit official material confirms a 15 m wingspan, 1,180 kg maximum takeoff weight, and payload capability up to 350 kg.",
            missionRole: "Multi-role MALE ISR and maritime patrol"
        ),
        UAVProfile(
            id: "ft5-los",
            displayName: "FT5 Łoś",
            manufacturer: "WB Group",
            countryOfOrigin: "Poland",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: 85.0,
            batteryMass: nil,
            estimatedBatteryMass: 5.0,
            maxPayloadMass: 30.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 120.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 6400,
                fuselageLengthMillimeters: 3100
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.12, 0.10),
            visualPreset: .ft5Los,
            shortDescription: "Twin-engine tactical fixed-wing platform with a compact surveillance airframe and modular payload integration.",
            notes: "WB Group official FT-5 brochure lists 85 kg weight, 30 kg payload, 6.4 m wingspan, and 3.1 m length. No separate official max takeoff mass was inferred.",
            missionRole: "Tactical reconnaissance and ISTAR"
        ),
        UAVProfile(
            id: "flyeye",
            displayName: "FlyEye",
            manufacturer: "WB Group",
            countryOfOrigin: "Poland",
            vehicleType: .fixedWing,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 1.6,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 1.2,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 12.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3600,
                fuselageLengthMillimeters: 1800
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.05, 0.06),
            visualPreset: .flyEye,
            shortDescription: "Lightweight fixed-wing observation UAV with a compact fuselage and underbelly electro-optical payload zone.",
            notes: "WB Group official FlyEye technical details confirm a 3.6 m wingspan and 1.8 m length. Other mass fields remain optional rather than inferred from system-level carry data.",
            missionRole: "Close-range reconnaissance and observation"
        ),
        UAVProfile(
            id: "sensefly-ebee-tac",
            displayName: "senseFly eBee TAC",
            manufacturer: "AgEagle senseFly",
            countryOfOrigin: "Switzerland",
            vehicleType: .fixedWing,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.45,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 0.35,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 1.7,
            dimensions: UAVDimensions(
                wingspanMillimeters: 1160,
                fuselageLengthMillimeters: 700
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.04, 0.05),
            visualPreset: .flyEye,
            shortDescription: "Compact hand-launch tactical mapping wing with a lightweight survey payload bay.",
            notes: "Conservative estimated configuration based on public eBee TAC family data. Launch semantics are modeled as hand launch with modest climb corridor and aircraft-like fly-by turns.",
            missionRole: "Short-range tactical mapping and reconnaissance"
        ),
        UAVProfile(
            id: "delair-ux11",
            displayName: "Delair UX11",
            manufacturer: "Delair",
            countryOfOrigin: "France",
            vehicleType: .fixedWing,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.42,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 0.40,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 1.6,
            dimensions: UAVDimensions(
                wingspanMillimeters: 1100,
                fuselageLengthMillimeters: 650
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.04, 0.05),
            visualPreset: .flyEye,
            shortDescription: "Portable hand-launch fixed-wing mapping aircraft with a compact belly sensor bay.",
            notes: "Conservative estimated configuration using public UX11 family references where official mass split data is incomplete. Launch semantics remain realistic hand launch rather than runway behavior.",
            missionRole: "Corridor mapping and inspection"
        ),
        UAVProfile(
            id: "scaneagle",
            displayName: "ScanEagle",
            manufacturer: "Insitu",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 1.8,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 3.5,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 22.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3100,
                fuselageLengthMillimeters: 1700
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.07, 0.07),
            visualPreset: .flyEye,
            shortDescription: "Long-endurance catapult-launched ISR aircraft with a slim fuselage and nose sensor payload.",
            notes: "Conservative estimated mode based on public ScanEagle specifications. Launch semantics are modeled as catapult with controlled exit corridor and initial climb before route capture.",
            missionRole: "Persistent ISR and maritime observation"
        ),
        UAVProfile(
            id: "rq-21-integrator",
            displayName: "RQ-21 Integrator",
            manufacturer: "Insitu",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 3.8,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 10.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 61.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 4900,
                fuselageLengthMillimeters: 2800
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.09, 0.08),
            visualPreset: .ft5Los,
            shortDescription: "Medium tactical catapult-launched ISR platform with modular payload stations and runway-free launch concept.",
            notes: "Conservative estimated mode based on public RQ-21 family references. Launch semantics are intentionally catapult-biased with rail heading and protected initial climb.",
            missionRole: "Tactical ISR and expeditionary surveillance"
        ),
        UAVProfile(
            id: "tekever-ar3-evo",
            displayName: "TEKEVER AR3 EVO",
            manufacturer: "TEKEVER",
            countryOfOrigin: "Portugal",
            vehicleType: .hybridVTOL,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 2.4,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 4.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 25.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3500,
                fuselageLengthMillimeters: 2200
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.08, 0.10),
            visualPreset: .quantumSystemsTrinityPro,
            shortDescription: "Flexible tactical aircraft profile supporting catapult or VTOL-style launch semantics with long-endurance cruise.",
            notes: "Partial public-data profile. Conservative estimated mode keeps both catapult and VTOL launch semantics available without overstating exact manufacturer-only parameters.",
            missionRole: "Maritime and overland ISR"
        ),
        UAVProfile(
            id: "uav-factory-penguin-b",
            displayName: "UAV Factory Penguin B",
            manufacturer: "UAV Factory",
            countryOfOrigin: "Latvia",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 2.3,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 4.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 26.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3400,
                fuselageLengthMillimeters: 2290
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.08, 0.08),
            visualPreset: .ft5Los,
            shortDescription: "Runway-capable tactical fixed-wing UAV with a pusher layout and modular ISR payload section.",
            notes: "Conservative estimated mode built from public Penguin B family references. Runway launch semantics include align, roll, rotation, and protected initial climb corridor.",
            missionRole: "Tactical ISR and survey"
        )
    ]

    static let allProfiles = realProfiles
    static let defaultProfileID = "dji-matrice-350-rtk"
    static let abstractProfileID = "abstract-uav"

    static func abstractProfile(from parameters: AbstractDroneParameters = .default) -> UAVProfile {
        UAVProfile(
            id: abstractProfileID,
            displayName: "Abstract UAV",
            manufacturer: "Custom",
            countryOfOrigin: "User Defined",
            vehicleType: .custom,
            massCategory: nil,
            specConfidence: .custom,
            payloadCapabilityMode: .modular,
            baseMass: parameters.massKg,
            batteryMass: nil,
            maxPayloadMass: nil,
            maxTakeoffMass: nil,
            dimensions: UAVDimensions(
                unfoldedMillimeters: parameters.unfoldedMm
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.08, 0.0),
            visualPreset: .abstractCustom,
            shortDescription: "User-defined custom UAV profile kept for future parameter tuning.",
            notes: "Custom editable baseline profile. Real-world manufacturer specifications do not apply.",
            missionRole: "User-defined custom mission"
        )
    }

    static func profile(id: String) -> UAVProfile? {
        if let realProfile = realProfiles.first(where: { $0.id == id }) {
            return realProfile
        }

        guard id == abstractProfileID else {
            return nil
        }

        return abstractProfile()
    }

    static func sourceURL(for id: String) -> URL? {
        switch id {
        case "dji-matrice-350-rtk":
            return URL(string: "https://enterprise.dji.com/matrice-350-rtk/specs")
        case "dji-flycart-30":
            return URL(string: "https://www.dji.com/flycart-30/specs")
        case "dji-mavic-4-pro":
            return URL(string: "https://store.dji.com/product/dji-mavic-4-pro")
        case "dji-neo":
            return URL(string: "https://www.dji.com/neo/specs")
        case "dji-phantom-3-standard":
            return URL(string: "https://www.dji.com/phantom-3-standard/info#specs")
        case "freefly-alta-x":
            return URL(string: "https://freeflysystems.com/alta-x/specs")
        case "griff-30":
            return URL(string: "https://www.griffaviation.com/drones/griff-30")
        case "griff-60":
            return URL(string: "https://www.griffaviation.com/drones/griff-60")
        case "avidrone-490tl":
            return URL(string: "https://avidrone.com/fleet")
        case "wingtraone-gen-ii":
            return URL(string: "https://wingtra.com/mapping-drone-wingtraone/technical-specifications/")
        case "quantum-systems-trinity-pro":
            return URL(string: "https://helpdesk.quantum-systems.com/trinity/")
        case "mq-9b-skyguardian":
            return URL(string: "https://www.ga-asi.com/remotely-piloted-aircraft/skyguardian")
        case "hermes-900":
            return URL(string: "https://elbitsystems.com/product/hermes-900/")
        case "ft5-los":
            return URL(string: "https://www.wbgroup.pl/app/uploads/2017/06/ft5_eng_21q03.pdf")
        case "flyeye":
            return URL(string: "https://www.wbgroup.pl/en/produkt/flyeye-unmanned-aerial-system/")
        case "sensefly-ebee-tac":
            return URL(string: "https://ageagle.com/drone-sensors/ebee-tac/")
        case "delair-ux11":
            return URL(string: "https://delair.aero/ux11/")
        case "scaneagle":
            return URL(string: "https://www.insitu.com/products/scaneagle")
        case "rq-21-integrator":
            return URL(string: "https://www.insitu.com/products/integrator")
        case "tekever-ar3-evo":
            return URL(string: "https://www.tekever.com/ar3/")
        case "uav-factory-penguin-b":
            return URL(string: "https://www.uavfactory.com/product/penguin-b/")
        default:
            return nil
        }
    }
}
