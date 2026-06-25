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
            id: "dji-mavic-3t",
            displayName: "DJI Mavic 3T",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .micro,
            specConfidence: .verified,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: 0.3355,
            maxPayloadMass: nil,
            maxTakeoffMass: 1.05,
            dimensions: UAVDimensions(
                foldedMillimeters: DroneDimensionsMM(x: 221.0, y: 96.3, z: 90.3),
                unfoldedMillimeters: DroneDimensionsMM(x: 347.5, y: 283.0, z: 107.7),
                diagonalWheelbaseMillimeters: 380.1
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.065, 0.085),
            visualPreset: .djiMavic4Pro,
            shortDescription: "Compact enterprise thermal quadcopter with wide, telephoto, and thermal cameras.",
            notes: "DJI Mavic 3 Enterprise specifications list Mavic 3T at 920 g with propellers, 1,050 g maximum takeoff weight, 347.5×283×107.7 mm unfolded dimensions, 45-minute flight time, 38-minute hover time, 21 m/s maximum horizontal speed in Sport mode, 12 m/s wind resistance, a 335.5 g battery, 56× hybrid zoom, and a thermal camera with spot and area temperature measurement.",
            missionRole: "Fire hotspot search, roof inspection, night SAR, smoke search, quick DFR scene assessment, and live video before crews arrive",
            nominalFlightTimeSec: 2700,
            nominalCruiseSpeedMps: 9.0,
            nominalMaxRangeM: 32000,
            nominalLinkRangeM: 15000
        ),
        UAVProfile(
            id: "dji-matrice-4t",
            displayName: "DJI Matrice 4T",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .light,
            specConfidence: .verified,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: 0.401,
            maxPayloadMass: 0.20,
            maxTakeoffMass: 1.42,
            dimensions: UAVDimensions(
                foldedMillimeters: DroneDimensionsMM(x: 260.6, y: 113.7, z: 138.4),
                unfoldedMillimeters: DroneDimensionsMM(x: 307.0, y: 387.5, z: 149.5),
                diagonalWheelbaseMillimeters: 438.8
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.075, 0.095),
            visualPreset: .djiMavic4Pro,
            shortDescription: "Compact public-safety thermal platform with wide, medium tele, tele, thermal, and laser rangefinder sensors.",
            notes: "DJI Matrice 4 Series specifications list 1,219 g standard takeoff weight, 1,420 g maximum takeoff weight, 200 g maximum payload, 307.0×387.5×149.5 mm unfolded dimensions, 438.8 mm diagonal wheelbase, 49-minute flight time, 42-minute hover time, 21 m/s maximum horizontal speed, and a 99.5 Wh / 401 g battery.",
            missionRole: "Thermal search, SAR overwatch, public-safety DFR reconnaissance, close-range fire assessment, and laser range checks",
            nominalFlightTimeSec: 2940,
            nominalCruiseSpeedMps: 14.0,
            nominalMaxRangeM: 35000,
            nominalLinkRangeM: 12000
        ),
        UAVProfile(
            id: "dji-matrice-30t",
            displayName: "DJI Matrice 30T",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .medium,
            specConfidence: .verified,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: 1.37,
            maxPayloadMass: nil,
            maxTakeoffMass: 4.069,
            dimensions: UAVDimensions(
                foldedMillimeters: DroneDimensionsMM(x: 365.0, y: 215.0, z: 195.0),
                unfoldedMillimeters: DroneDimensionsMM(x: 470.0, y: 585.0, z: 215.0),
                diagonalWheelbaseMillimeters: 668.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.12, 0.06),
            visualPreset: .djiMatrice350RTK,
            shortDescription: "Rugged folding thermal enterprise drone for fire, emergency response, and public-safety overwatch.",
            notes: "DJI Matrice 30 Series specifications list 470×585×215 mm unfolded dimensions, 365×215×195 mm folded dimensions, 3,770±10 g weight with two batteries, 4,069 g maximum takeoff weight, 23 m/s maximum horizontal speed, 41-minute flight time, 36-minute hover time, 12 m/s wind resistance, and two 685 g / 131.6 Wh TB30 batteries.",
            missionRole: "Fire overwatch in bad weather, thermal mapping, roof and upper-floor inspection, night search, and incident-command live video",
            nominalFlightTimeSec: 2460,
            nominalCruiseSpeedMps: 15.0,
            nominalMaxRangeM: 21000,
            nominalLinkRangeM: 15000
        ),
        UAVProfile(
            id: "dji-matrice-400",
            displayName: "DJI Matrice 400",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .verified,
            payloadCapabilityMode: .modular,
            baseMass: 5.02,
            batteryMass: 4.72,
            maxPayloadMass: 6.0,
            maxTakeoffMass: 15.8,
            dimensions: UAVDimensions(
                foldedMillimeters: DroneDimensionsMM(x: 490.0, y: 490.0, z: 480.0),
                unfoldedMillimeters: DroneDimensionsMM(x: 980.0, y: 760.0, z: 480.0),
                diagonalWheelbaseMillimeters: 1070.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.22, 0.02),
            visualPreset: .djiMatrice350RTK,
            shortDescription: "Heavy enterprise platform for long-duration multi-payload public-safety and inspection missions.",
            notes: "DJI Matrice 400 specifications list 5,020±20 g without batteries, 9,740±40 g with batteries, 15.8 kg maximum takeoff weight, 980×760×480 mm unfolded dimensions, and 6 kg maximum payload.",
            missionRole: "Large-incident fire overwatch, thermal mapping with heavier payloads, laser range checks, and extended forest-fire monitoring",
            nominalFlightTimeSec: 3540,
            nominalCruiseSpeedMps: 17.0,
            nominalMaxRangeM: 49000,
            nominalLinkRangeM: 20000
        ),
        UAVProfile(
            id: "fotokite-sigma",
            displayName: "Fotokite Sigma",
            manufacturer: "Fotokite",
            countryOfOrigin: "Switzerland",
            vehicleType: .multicopter,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: 1.30,
            batteryMass: nil,
            maxPayloadMass: nil,
            maxTakeoffMass: nil,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 520.0, y: 520.0, z: 180.0)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.06, 0.06),
            visualPreset: .abstractCustom,
            shortDescription: "Actively tethered public-safety drone with thermal and wide/zoom color cameras.",
            notes: "Fotokite publishes the Sigma as an actively tethered first-responder UAS with a 1.3 kg carbon-fiber frame, 24+ hour operation, 45 m maximum altitude, IP55 rating, thermal camera, wide camera, zoom camera, and live streaming.",
            missionRole: "Persistent command-post overwatch, live thermal and visible video during urban fires, wildfires, SAR, and police incidents",
            nominalFlightTimeSec: 86400,
            nominalMaxRangeM: 45,
            nominalLinkRangeM: 45,
            estimatedDataQuality: .derived
        ),
        UAVProfile(
            id: "everdrone-first-on-scene",
            displayName: "Everdrone First on Scene",
            manufacturer: "Everdrone",
            countryOfOrigin: "Sweden",
            vehicleType: .multicopter,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            maxPayloadMass: nil,
            maxTakeoffMass: nil,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.12, 0.04),
            visualPreset: .djiMatrice350RTK,
            shortDescription: "Autonomous first-on-scene emergency drone system for AED, anti-bleeding kit, live view, and medical support.",
            notes: "Everdrone describes its system as autonomous Drone as First Responder support that delivers lifesaving medical equipment, including AEDs and anti-bleeding kits, and provides real-time situational awareness. Exact aircraft mass and dimensions are not publicly specified.",
            missionRole: "AED delivery, medical kit delivery, live video before ambulance arrival, and first-on-scene emergency assessment",
            estimatedDataQuality: .estimated
        ),
        UAVProfile(
            id: "zipline-platform-1",
            displayName: "Zipline Platform 1",
            manufacturer: "Zipline",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 2.0,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 1.80,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 20.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3350.0,
                fuselageLengthMillimeters: 1800.0,
                heightMillimeters: 420.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.06, 0.05),
            visualPreset: .lightFixedWingSurvey,
            shortDescription: "Long-range autonomous fixed-wing delivery drone for medical logistics and parachute-drop delivery.",
            notes: "Zipline publishes autonomous delivery drones that fly up to 70 mph and up to 155 miles roundtrip. Platform 1 mass, payload, and dimensions remain conservative estimates because current public Zipline material does not publish exact aircraft figures.",
            missionRole: "Blood, vaccine, medicine, lab-sample, and medical-consumable delivery over long rural routes",
            nominalFlightTimeSec: 7950,
            nominalCruiseSpeedMps: 31.3,
            nominalMaxRangeM: 249000,
            nominalLinkRangeM: 80000,
            estimatedDataQuality: .estimated
        ),
        UAVProfile(
            id: "wingcopter-198",
            displayName: "Wingcopter 198",
            manufacturer: "Wingcopter",
            countryOfOrigin: "Germany",
            vehicleType: .hybridVTOL,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 3.0,
            maxPayloadMass: 4.7,
            maxTakeoffMass: 25.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 1980.0,
                fuselageLengthMillimeters: 1520.0,
                heightMillimeters: 650.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.10, 0.10),
            visualPreset: .quantumSystemsTrinityPro,
            shortDescription: "Tilt-rotor eVTOL delivery drone with fixed-wing cruise and multi-drop medical logistics capability.",
            notes: "Wingcopter publishes the Wingcopter 198 with a 198×152×65 cm aircraft envelope, 25 kg maximum takeoff weight, 94 km maximum range, 90 km/h speed, 4.7 kg payload, eight motors, and two batteries. Battery-separated mass is still estimated until OEM mass breakdown is available.",
            missionRole: "Blood, laboratory sample, vaccine, and medicine delivery between hospitals, labs, and remote points",
            nominalFlightTimeSec: 3760,
            nominalCruiseSpeedMps: 25.0,
            nominalMaxRangeM: 94000,
            nominalLinkRangeM: 25000,
            estimatedDataQuality: .estimated
        ),
        UAVProfile(
            id: "matternet-m2",
            displayName: "Matternet M2",
            manufacturer: "Matternet",
            countryOfOrigin: "United States",
            vehicleType: .multicopter,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 1.20,
            maxPayloadMass: 2.0,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 12.0,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 720.0, y: 720.0, z: 320.0)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.12, 0.02),
            visualPreset: .abstractCustom,
            shortDescription: "Certified urban medical delivery quadcopter for small payload movement between care sites.",
            notes: "Matternet publishes the M2 as an FAA Type Certified healthcare delivery aircraft and states that the system carries payloads up to 2 kg over distances up to 20 km. Exact aircraft mass, speed, and dimensions remain modeled conservatively until manufacturer data is available.",
            missionRole: "Small medical cargo transfer between hospitals, laboratories, clinics, and hub stations",
            nominalMaxRangeM: 20000,
            estimatedDataQuality: .estimated
        ),
        UAVProfile(
            id: "skydio-x10",
            displayName: "Skydio X10",
            manufacturer: "Skydio",
            countryOfOrigin: "United States",
            vehicleType: .multicopter,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: 2.13,
            batteryMass: nil,
            estimatedBatteryMass: 0.70,
            maxPayloadMass: 0.385,
            maxTakeoffMass: nil,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 351.0, y: 351.0, z: 160.0)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.085, 0.085),
            visualPreset: .djiMavic4Pro,
            shortDescription: "AI-assisted public-safety quadcopter for autonomous inspection, thermal search, and DFR response.",
            notes: "Skydio publishes X10 with up to 45 mph maximum speed, 40-minute maximum flight time, IP55 protection, 28.6 mph gust handling, 7.5-mile range with Connect SL, thermal sensor packages, attachment bays rated to 385 g, and aircraft weight under 4.7 lb. Full width, height, and battery mass remain estimated.",
            missionRole: "Police and medical DFR, SAR thermal search, low-light scene assessment, roof search, and remote live video",
            nominalFlightTimeSec: 2400,
            nominalCruiseSpeedMps: 14.0,
            nominalMaxRangeM: 12000,
            nominalLinkRangeM: 12000,
            estimatedDataQuality: .derived
        ),
        UAVProfile(
            id: "dji-matrice-4td-dock-3",
            displayName: "DJI Matrice 4TD + Dock 3",
            manufacturer: "DJI",
            countryOfOrigin: "China",
            vehicleType: .multicopter,
            massCategory: .light,
            specConfidence: .verified,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: 0.640,
            maxPayloadMass: nil,
            maxTakeoffMass: 2.09,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 377.7, y: 416.2, z: 212.5),
                diagonalWheelbaseMillimeters: 498.5
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.09, 0.10),
            visualPreset: .djiMavic4Pro,
            shortDescription: "Dock-launched thermal DFR drone for autonomous public-safety, fire, SAR, and inspection response.",
            notes: "DJI Dock 3 specifications list the supported Matrice 4D/4TD aircraft at 1,850 g, 2,090 g maximum takeoff weight, 377.7×416.2×212.5 mm dimensions, 54-minute maximum flight time, 47-minute hover time, IP55 rating, 149.9 Wh / 640 g battery, and thermal-camera variant data for Matrice 4TD. DJI notes Dock 3 only supports Normal mode, so runtime speed is capped to the Normal-mode figure.",
            missionRole: "Autonomous dock-start response to police, fire, SAR, and medical calls before crews arrive",
            nominalFlightTimeSec: 3240,
            nominalCruiseSpeedMps: 15.0,
            nominalMaxRangeM: 43000,
            nominalLinkRangeM: 10000
        ),
        UAVProfile(
            id: "brinc-lemur-2",
            displayName: "BRINC Lemur 2",
            manufacturer: "BRINC",
            countryOfOrigin: "United States",
            vehicleType: .multicopter,
            massCategory: .micro,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: 1.50,
            batteryMass: nil,
            maxPayloadMass: 0.45,
            maxTakeoffMass: nil,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 406.4, y: 330.2, z: 101.6)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.04, 0.05),
            visualPreset: .djiNeo,
            shortDescription: "Indoor tactical public-safety drone for room clearing, communication, and dangerous indoor situations.",
            notes: "BRINC publishes Lemur 2 at 3.3 lb / 1.5 kg, 20-minute flight time, 16×13×4 in dimensions, 4K visual camera, night vision, thermal sensor, 360-degree position hold, real-time floor plans, glass breaker, two-way communications, live stream, and mesh capability. Public BRINC specs do not publish a numeric maximum speed.",
            missionRole: "Police indoor reconnaissance, hazardous room inspection, two-way communication, and commands to people inside buildings",
            nominalFlightTimeSec: 1200,
            estimatedDataQuality: .derived
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
            specConfidence: .verified,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: 0.045,
            estimatedBatteryMass: nil,
            maxPayloadMass: nil,
            maxTakeoffMass: 0.135,
            dimensions: UAVDimensions(
                unfoldedMillimeters: DroneDimensionsMM(x: 130, y: 157, z: 48.5)
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.035, 0.04),
            visualPreset: .djiNeo,
            shortDescription: "Ultra-compact protected-prop multicopter designed as a lightweight personal flying camera.",
            notes: "DJI official specifications list 135 g takeoff weight, 130×157×48.5 mm aircraft dimensions, 18-minute flight and hover time, 7 km flight distance, 10 km FCC transmission distance, 8 m/s wind resistance, 45 g / 10.5 Wh battery, 3 m/s maximum ascent speed in Sport mode, and 16 m/s maximum horizontal speed in Manual mode.",
            missionRole: "Personal aerial video capture",
            nominalFlightTimeSec: 1080,
            nominalCruiseSpeedMps: 8.0,
            nominalMaxRangeM: 7000,
            nominalLinkRangeM: 10000,
            estimatedDataQuality: .official
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
            visualPreset: .lightFixedWingSurvey,
            shortDescription: "Compact hand-launch tactical mapping wing with a lightweight survey payload bay.",
            notes: "Conservative estimated configuration based on public eBee TAC family data. Launch semantics are modeled as hand launch with modest climb corridor and aircraft-like fly-by turns.",
            missionRole: "Short-range tactical mapping and reconnaissance"
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
        case "dji-mavic-3t":
            return URL(string: "https://enterprise.dji.com/mavic-3-enterprise/specs")
        case "dji-matrice-4t":
            return URL(string: "https://enterprise.dji.com/matrice-4-series/specs")
        case "dji-matrice-30t":
            return URL(string: "https://enterprise.dji.com/matrice-30/specs")
        case "dji-matrice-400":
            return URL(string: "https://enterprise.dji.com/matrice-400/specs")
        case "fotokite-sigma":
            return URL(string: "https://fotokite.com/")
        case "everdrone-first-on-scene":
            return URL(string: "https://everdrone.com/")
        case "zipline-platform-1":
            return URL(string: "https://www.zipline.com/technology")
        case "wingcopter-198":
            return URL(string: "https://wingcopter.com/wingcopter-198")
        case "matternet-m2":
            return URL(string: "https://www.matternet.com/our-system")
        case "skydio-x10":
            return URL(string: "https://www.skydio.com/x10")
        case "dji-matrice-4td-dock-3":
            return URL(string: "https://enterprise.dji.com/dock-3/specs")
        case "brinc-lemur-2":
            return URL(string: "https://brincdrones.com/lemur-2/")
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
        case "sensefly-ebee-tac":
            return URL(string: "https://ageagle.com/drone-sensors/ebee-tac/")
        case "rq-21-integrator":
            return URL(string: "https://www.insitu.com/products/integrator")
        default:
            return nil
        }
    }
}
