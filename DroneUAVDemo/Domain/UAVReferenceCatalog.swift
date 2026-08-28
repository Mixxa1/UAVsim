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
            // Explicit tuning, decoupled from Quantum Trinity Pro's shared
            // catalogDefault(visualPreset:) numbers now that this airframe is
            // a mechanically-simulated true tilt-rotor (AirframeClass.hybridVTOL
            // in DroneModelProfile), not a lift+cruise hybrid like Trinity.
            flightTuningProfile: UAVFlightTuningProfile.hybridVTOL(
                referenceMass: 20.3,
                hoverThrottleBaseline: 0.62,
                transitionThrottleBaseline: 0.57,
                cruiseThrottleBaseline: 0.44,
                verticalResponseFactor: 0.85,
                transitionResponseFactor: 0.78,
                payloadThrustCompensationFactor: 0.36,
                source: .estimated
            ),
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
            id: "wildfire-ember-40",
            displayName: "Wildfire Robotics Ember 40",
            manufacturer: "Wildfire Robotics",
            countryOfOrigin: "United States",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: 13.0,
            batteryMass: 7.5,
            maxPayloadMass: 28.0,
            maxTakeoffMass: 48.5,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.20, 0.0),
            visualPreset: .wildfireEmber40,
            shortDescription: "Compact hexacopter built for narrow-diameter forestry hose lines at medium-lift altitudes.",
            notes: "Composite/representative platform (not a real product) — modeled as the entry point of a firefighting hose-lift family, sized for lightweight foldable hose up to its full narrow-diameter rigging range.",
            missionRole: "Light aerial firefighting hose lift"
        ),
        UAVProfile(
            id: "pyrolift-talon-60",
            displayName: "Pyrolift Systems Talon 60",
            manufacturer: "Pyrolift Systems",
            countryOfOrigin: "United States",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: 24.0,
            batteryMass: 14.0,
            maxPayloadMass: 62.0,
            maxTakeoffMass: 100.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.30, 0.0),
            visualPreset: .pyroliftTalon60,
            shortDescription: "Reinforced hexacopter with an integrated hose-reel deck, rated for standard-diameter attack lines at short range.",
            notes: "Composite/representative platform (not a real product) — the mid-tier of a firefighting hose-lift family, able to run the narrow hose class end-to-end or a standard attack line for shorter operating heights.",
            missionRole: "Medium aerial firefighting hose lift"
        ),
        UAVProfile(
            id: "colossus-ca8-vulcan",
            displayName: "Colossus Aerial CA-8 Vulcan",
            manufacturer: "Colossus Aerial",
            countryOfOrigin: "Germany",
            vehicleType: .multicopter,
            massCategory: .superheavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: 65.0,
            batteryMass: 35.0,
            maxPayloadMass: 225.0,
            maxTakeoffMass: 325.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.40, 0.0),
            visualPreset: .colossusCA8Vulcan,
            shortDescription: "Boxy industrial octocopter (4 arms, coaxial rotor pairs) built to lift a full standard-diameter attack line to high-rise operating altitudes.",
            notes: "Composite/representative platform (not a real product) — a superheavy-class firefighting hose-lift airframe, comfortably running a standard hose up to roughly 120m.",
            missionRole: "Heavy aerial firefighting hose lift"
        ),
        UAVProfile(
            id: "colossus-ca12-atlas",
            displayName: "Colossus Aerial CA-12 Atlas",
            manufacturer: "Colossus Aerial",
            countryOfOrigin: "Germany",
            vehicleType: .multicopter,
            massCategory: .superheavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: 92.0,
            batteryMass: 53.0,
            maxPayloadMass: 300.0,
            maxTakeoffMass: 445.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.50, 0.0),
            visualPreset: .colossusCA12Atlas,
            shortDescription: "Flagship 6-arm coaxial (12-rotor) heavy-lift platform with a flatbed hose-reel deck and a forward monitor-nozzle turret stub, rated for the full 150m standard hose class.",
            notes: "Composite/representative platform (not a real product) — the top of a firefighting hose-lift family, sized to comfortably carry the longest standard-diameter attack line in the catalog with margin to spare.",
            missionRole: "Superheavy aerial firefighting hose lift"
        ),
        UAVProfile(
            id: "agrowing-titan-at40",
            displayName: "AgroWing Titan AT-40",
            manufacturer: "AgroWing Systems",
            countryOfOrigin: "Netherlands",
            vehicleType: .multicopter,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .cargo,
            baseMass: 65.0,
            batteryMass: 20.0,
            maxPayloadMass: 90.0,
            maxTakeoffMass: 175.0,
            dimensions: UAVDimensions(),
            payloadMountOffset: SIMD3<Float>(0.0, -0.42, 0.0),
            visualPreset: .agroWingTitanAT40,
            shortDescription: "Flagship agricultural spray octocopter with a large belly tank, boom arms, and a wide-swath nozzle bar — noticeably bigger and slower than the survey/inspection multirotors in this catalog.",
            notes: "Composite/representative platform (not a real product), sized in the spirit of real DJI Agras-class spray drones but scaled up to a flagship-tier heavy-lift tank capacity.",
            missionRole: "Agricultural spraying and crop treatment"
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
        ),

        // MARK: - Fuel-burning and research airframes
        //
        // The first entries in this catalogue that are not battery-electric.
        // Their `powerplant` block carries the real engine and tank figures;
        // the runtime still draws energy from the battery model until the fuel
        // subsystem exists, so nothing here changes how they fly today.
        // Where a figure is genuinely not published (most usable-fuel masses,
        // which manufacturers rarely release), the derivation is stated in
        // `notes` rather than presented as a specification.

        UAVProfile(
            id: "aerosonde-mk-4-7",
            displayName: "Aerosonde Mk 4.7",
            manufacturer: "Textron Systems",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: 23.3,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 4.5,
            maxTakeoffMass: 36.3,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3600.0,
                fuselageLengthMillimeters: 1900.0,
                heightMillimeters: 500.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.06, 0.08),
            visualPreset: .aerosondeMk47,
            shortDescription: "Small heavy-fuel expeditionary ISR aircraft with a twin-boom inverted-V tail and a rear pusher propeller.",
            notes: "Textron Systems and Naval Technology publish a 3.6 m wingspan, 10 lb (4.5 kg) payload, more than 12 hours endurance at full payload, 50-60 kt cruise with a 62-80 kt dash, a 4,500 m density-altitude ceiling, and a single-cylinder air-cooled direct-injected spark-ignited Lycoming EL-005 running jet fuel. Lycoming rates the EL-005 at 4 hp (about 3 kW) at 5,500 rpm with a 6.25 kg dry weight. Gross weight is taken as the widely published 80 lb (36.3 kg) figure. Usable fuel mass is NOT published: 8.5 kg is derived here from the endurance and a small heavy-fuel two-stroke's typical specific consumption, and should be treated as an estimate.",
            missionRole: "Long-endurance expeditionary ISR, maritime patrol, and persistent overwatch from unprepared sites",
            nominalFlightTimeSec: 50400,
            nominalCruiseSpeedMps: 28.0,
            nominalMaxRangeM: 1400000,
            nominalLinkRangeM: 139000,
            estimatedDataQuality: .derived,
            powerplant: UAVPowerplantSpec(
                engineType: .pistonTwoStroke,
                engineDesignation: "Lycoming EL-005",
                ratedShaftPowerKW: 3.0,
                propellerPlacement: .pusher,
                propellerDiameterM: 0.46,
                ratedShaftRPM: 5500.0,
                propellerBladeCount: 2,
                starter: .electricStarter,
                startPolicy: .groundStartBeforeLaunch,
                fuel: UAVFuelSpec(
                    fuelType: .heavyFuel,
                    usableFuelMassKg: 8.5,
                    reserveFraction: 0.18
                )
            )
        ),
        UAVProfile(
            id: "rq-7b-shadow",
            displayName: "RQ-7B Shadow 200",
            manufacturer: "Textron Systems (AAI)",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: 77.0,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 27.0,
            maxTakeoffMass: 170.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 4270.0,
                fuselageLengthMillimeters: 3410.0,
                heightMillimeters: 1000.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.10, 0.10),
            visualPreset: .rq7bShadow,
            shortDescription: "Tactical twin-boom rotary-engine pusher launched from a pneumatic rail and recovered into an arresting wire.",
            notes: "Directory of U.S. Military Rockets and Missiles lists the RQ-7B at a 4.27 m wingspan, 170 kg maximum weight, 194 km/h maximum and 111 km/h loiter speed, a 4,570 m ceiling, seven hours endurance, and a UEL AR-741 rotary engine of 28.3 kW (38 hp); the RQ-7A length of 3.41 m and height of 1.0 m carry over. The RQ-7B's defining change is a longer wet wing holding up to 44 litres of fuel, which at gasoline density is about 31.7 kg. Later RQ-7Bv2 aircraft fly a 6.1 m wing at over 209 kg gross weight — this entry models the baseline RQ-7B.",
            missionRole: "Brigade-level tactical reconnaissance, surveillance, target acquisition, and battle damage assessment",
            nominalFlightTimeSec: 25200,
            nominalCruiseSpeedMps: 31.0,
            nominalMaxRangeM: 700000,
            nominalLinkRangeM: 125000,
            estimatedDataQuality: .derived,
            powerplant: UAVPowerplantSpec(
                engineType: .wankelRotary,
                engineDesignation: "UEL AR-741",
                ratedShaftPowerKW: 28.3,
                propellerPlacement: .pusher,
                propellerDiameterM: 0.71,
                ratedShaftRPM: 6000.0,
                propellerBladeCount: 2,
                starter: .electricStarter,
                startPolicy: .groundStartBeforeLaunch,
                fuel: UAVFuelSpec(
                    fuelType: .gasoline,
                    usableFuelLiters: 44.0,
                    reserveFraction: 0.20
                )
            )
        ),
        UAVProfile(
            id: "mq-9a-reaper",
            displayName: "MQ-9A Reaper",
            manufacturer: "General Atomics Aeronautical Systems",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .heavy,
            specConfidence: .verified,
            payloadCapabilityMode: .modular,
            baseMass: 2223.0,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 1746.0,
            maxTakeoffMass: 4763.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 20100.0,
                fuselageLengthMillimeters: 11000.0,
                heightMillimeters: 3810.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.18, 0.28),
            visualPreset: .mq9bSkyGuardian,
            shortDescription: "Turboprop MALE hunter-killer with a V-tail, rear pusher propeller, and multi-hardpoint stores capacity.",
            notes: "The U.S. Air Force fact sheet lists a 66 ft (20.1 m) wingspan, 36 ft (11 m) length, 4,000 lb (1,814 kg / 602 gal) fuel capacity, and a ceiling up to 50,000 ft (15,240 m). Published aggregate data give 2,223 kg empty weight, 4,763 kg maximum takeoff weight, 482 km/h maximum and 313 km/h cruise speed, and 1,900 km range. GA-ASI states over 27 hours endurance, 240 KTAS maximum airspeed, 3,850 lb (1,746 kg) total payload of which 3,000 lb (1,361 kg) is external stores, and a Honeywell TPE331-10 turboprop with digital electronic engine control.",
            missionRole: "Armed persistent ISR, strike coordination, and long-endurance hunter-killer patrol",
            armamentCapabilityNote: "Seven external hardpoints rated for up to 1,361 kg of stores alongside the internal sensor payload.",
            nominalFlightTimeSec: 97200,
            nominalCruiseSpeedMps: 87.0,
            nominalMaxRangeM: 1900000,
            nominalLinkRangeM: 370000,
            estimatedDataQuality: .official,
            powerplant: UAVPowerplantSpec(
                engineType: .turboprop,
                engineDesignation: "Honeywell TPE331-10",
                ratedShaftPowerKW: 671.0,
                propellerPlacement: .pusher,
                propellerDiameterM: 2.3,
                ratedShaftRPM: 1591.0,
                propellerBladeCount: 3,
                starter: .electricStarter,
                startPolicy: .groundStartBeforeLaunch,
                fuel: UAVFuelSpec(
                    fuelType: .turbineKerosene,
                    usableFuelMassKg: 1814.0,
                    reserveFraction: 0.15,
                    tankCount: 3
                )
            )
        ),
        UAVProfile(
            id: "iai-harpy",
            displayName: "IAI Harpy",
            manufacturer: "Israel Aerospace Industries",
            countryOfOrigin: "Israel",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: 83.0,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 32.0,
            maxTakeoffMass: 135.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 2100.0,
                fuselageLengthMillimeters: 2700.0,
                heightMillimeters: 550.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.05, 0.16),
            visualPreset: .deltaLoiteringMunition,
            shortDescription: "Tailless delta anti-radiation loitering munition with a rear Wankel pusher and canister launch from a ground vehicle.",
            notes: "Published data give a 2.7 m length, 2.1 m wingspan, 135 kg gross weight, a single UEL AR731 Wankel rotary engine of 28 kW (38 hp), 185 km/h maximum speed, 200 km range, and a 32 kg high-explosive warhead in a tailless delta with a single pusher propeller. Endurance and usable fuel mass are not published; the 2.5 h loiter and 20 kg fuel load modelled here are derived from the published range and engine class. This is the first aircraft in the catalogue to use the delta aerodynamic family.",
            missionRole: "Suppression of enemy air defences — autonomous radar search, loiter, and terminal attack",
            armamentCapabilityNote: "Fixed 32 kg high-explosive warhead; the airframe is expended on the target rather than recovered.",
            nominalFlightTimeSec: 9000,
            nominalCruiseSpeedMps: 40.0,
            nominalMaxRangeM: 200000,
            nominalLinkRangeM: 200000,
            estimatedDataQuality: .derived,
            powerplant: UAVPowerplantSpec(
                engineType: .wankelRotary,
                engineDesignation: "UEL AR731",
                ratedShaftPowerKW: 28.0,
                propellerPlacement: .pusher,
                propellerDiameterM: 0.60,
                ratedShaftRPM: 6000.0,
                propellerBladeCount: 2,
                starter: .electricStarter,
                startPolicy: .airStartAfterBoost,
                fuel: UAVFuelSpec(
                    fuelType: .gasoline,
                    usableFuelMassKg: 20.0,
                    reserveFraction: 0.10
                )
            )
        ),
        UAVProfile(
            id: "iai-harop",
            displayName: "IAI Harop",
            manufacturer: "Israel Aerospace Industries",
            countryOfOrigin: "Israel",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: 89.0,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 16.0,
            maxTakeoffMass: 135.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3000.0,
                fuselageLengthMillimeters: 2500.0,
                heightMillimeters: 600.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.05, 0.16),
            visualPreset: .canardDeltaLoiteringMunition,
            shortDescription: "Canard delta man-in-the-loop loitering munition with electro-optical terminal guidance and a Wankel pusher.",
            notes: "Published data give a 2.5 m length, 3.0 m wingspan, delta wing with canards, a single Wankel pusher engine, 417 km/h maximum speed, 200 km range, more than 6 hours endurance, a 4,600 m service ceiling, a radar cross-section under 0.5 m², a 16 kg warhead with sub-metre CEP, man-in-the-loop control, and canister launch from vehicles or ships. Gross weight is the commonly published 135 kg. Engine power and usable fuel mass are not published; the 30 kg fuel load modelled here is derived from the endurance and the engine class.",
            missionRole: "Man-in-the-loop loitering attack against static and moving targets, and armed reconnaissance",
            armamentCapabilityNote: "16 kg warhead with sub-metre circular error probable; the mission can be aborted and the aircraft re-tasked before terminal dive.",
            nominalFlightTimeSec: 21600,
            nominalCruiseSpeedMps: 42.0,
            nominalMaxRangeM: 200000,
            nominalLinkRangeM: 200000,
            estimatedDataQuality: .derived,
            powerplant: UAVPowerplantSpec(
                engineType: .wankelRotary,
                engineDesignation: "Wankel rotary (designation not published)",
                ratedShaftPowerKW: 37.0,
                propellerPlacement: .pusher,
                propellerDiameterM: 0.62,
                ratedShaftRPM: 6000.0,
                propellerBladeCount: 2,
                starter: .electricStarter,
                startPolicy: .airStartAfterBoost,
                fuel: UAVFuelSpec(
                    fuelType: .gasoline,
                    usableFuelMassKg: 30.0,
                    reserveFraction: 0.10
                )
            )
        ),
        UAVProfile(
            id: "iai-harpy-ng",
            displayName: "IAI Harpy NG",
            manufacturer: "Israel Aerospace Industries",
            countryOfOrigin: "Israel",
            vehicleType: .fixedWing,
            massCategory: .medium,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: 103.0,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 15.0,
            maxTakeoffMass: 160.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 3000.0,
                fuselageLengthMillimeters: 2500.0,
                heightMillimeters: 600.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.05, 0.16),
            visualPreset: .canardDeltaLoiteringMunition,
            shortDescription: "Long-loiter anti-radiation development of the Harop airframe with a wider-band seeker and a Wankel pusher.",
            notes: "Public material describes Harpy NG as an anti-radiation loitering weapon combining the Harop airframe with the Harpy's SEAD role, quoting 9 hours airborne time, a seeker band widened from 2-18 GHz to 0.8-18 GHz, ground-vehicle launch, and improvements in loiter time, range, altitude, maintenance and training. Reported total weight is about 160 kg with roughly 15 kg of explosive. Dimensions are inherited from the Harop airframe and engine power and fuel mass are not published — this entry is deliberately marked as estimated.",
            missionRole: "Extended-loiter suppression of enemy air defences against intermittently radiating emitters",
            armamentCapabilityNote: "Roughly 15 kg high-explosive warhead; fire-and-forget anti-radiation engagement.",
            nominalFlightTimeSec: 32400,
            nominalCruiseSpeedMps: 43.0,
            nominalMaxRangeM: 250000,
            nominalLinkRangeM: 250000,
            estimatedDataQuality: .estimated,
            powerplant: UAVPowerplantSpec(
                engineType: .wankelRotary,
                engineDesignation: "Wankel rotary (designation not published)",
                ratedShaftPowerKW: 37.0,
                propellerPlacement: .pusher,
                propellerDiameterM: 0.62,
                ratedShaftRPM: 6000.0,
                propellerBladeCount: 2,
                starter: .electricStarter,
                startPolicy: .airStartAfterBoost,
                fuel: UAVFuelSpec(
                    fuelType: .gasoline,
                    usableFuelMassKg: 42.0,
                    reserveFraction: 0.10
                )
            )
        ),
        UAVProfile(
            id: "epfl-delta-wing-uav",
            displayName: "EPFL Delta-Wing UAV",
            manufacturer: "EPFL (Environmental Sensing Observatory)",
            countryOfOrigin: "Switzerland",
            vehicleType: .fixedWing,
            massCategory: .micro,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: nil,
            batteryMass: nil,
            estimatedBatteryMass: 0.45,
            maxPayloadMass: nil,
            estimatedMaxPayloadMass: 0.60,
            maxTakeoffMass: nil,
            estimatedMaxTakeoffMass: 2.6,
            dimensions: UAVDimensions(
                wingspanMillimeters: 1245.0,
                fuselageLengthMillimeters: 780.0,
                heightMillimeters: 220.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.03, 0.04),
            visualPreset: .researchDeltaWing,
            shortDescription: "Small electric research delta built to identify a delta-wing aerodynamic model for vehicle-dynamic-model navigation.",
            notes: "EPFL's Environmental Sensing Observatory describes a custom delta-wing UAV whose wings come from a Multiplex Xeno Electric airframe while the fuselage was redesigned for a larger payload and the power-train uprated for the added weight; the platform is used to identify a delta-wing aerodynamic model from combined wind-tunnel and in-flight data for model-based navigation in GNSS-denied conditions. Multiplex publishes the donor airframe at a 1,245 mm wingspan, 32 dm² (0.32 m²) wing area and 650-690 g all-up electric weight. The modified aircraft's mass, payload and airspeeds are not published — the figures here are estimates for the modified configuration and are marked accordingly. This aircraft is electric: it is in this group as an aerodynamic reference for the delta family, not as a fuel-burning platform.",
            missionRole: "Aerodynamic model identification, model-based navigation research, and delta-wing handling reference",
            nominalFlightTimeSec: 2400,
            nominalCruiseSpeedMps: 18.0,
            nominalMaxRangeM: 30000,
            nominalLinkRangeM: 5000,
            estimatedDataQuality: .estimated,
            powerplant: UAVPowerplantSpec(
                engineType: .electricMotor,
                engineDesignation: "Brushless outrunner (uprated from donor airframe)",
                propellerPlacement: .tractor,
                propellerDiameterM: 0.20,
                ratedShaftRPM: 9000.0,
                propellerBladeCount: 2,
                starter: UAVEngineStarterKind.none,
                fuel: nil
            )
        ),
        UAVProfile(
            id: "ncstate-bwb-delta",
            displayName: "NC State BWB DELTA",
            manufacturer: "North Carolina State University",
            countryOfOrigin: "United States",
            vehicleType: .fixedWing,
            massCategory: .light,
            specConfidence: .partial,
            payloadCapabilityMode: .sensor,
            baseMass: 13.6,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 6.8,
            maxTakeoffMass: 19.05,
            dimensions: UAVDimensions(
                wingspanMillimeters: 2859.0,
                fuselageLengthMillimeters: 1473.0,
                heightMillimeters: 450.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.04, 0.06),
            visualPreset: .blendedWingBodyTestbed,
            shortDescription: "Turbojet blended wing-body flight-controls testbed with a segmented trailing-edge effector array in place of conventional surfaces.",
            notes: "NASA-funded NC State research (Barnwell MS thesis, 2003, and AIAA 2004-5114) describes the UAV BWB DELTA — designed, built and flight tested at NC State, sharing its planform with the NASA blended wing-body design — with a NACA 0015 section, 58 in (1.473 m) root chord tapering to a 5.25 in tip, 34.3 in (0.871 m) mean aerodynamic chord, 17.77 ft² (1.651 m²) wing area over a 9.38 ft (2.859 m) wingspan, 30 lb (13.6 kg) dry weight with a 15 lb (6.8 kg) payload capacity, and an AMT mini-turbojet rated at 15-18 lbf static thrust. Published speeds are 120 ft/s (36.6 m/s) cruise and 45 ft/s (13.7 m/s) stall, with the MESA test configuration listed at 42 lb (19.05 kg) takeoff weight, 117 ft/s cruise and 44 ft/s stall. The aircraft has no landing gear: it is dolly-launched and skid-recovered. Endurance is not published; the figure here reflects a mini-turbojet's typical fuel fraction and is an estimate.",
            missionRole: "Distributed actuation and sensing research, flight-control law development, and blended wing-body handling reference",
            nominalFlightTimeSec: 720,
            nominalCruiseSpeedMps: 35.7,
            nominalMaxRangeM: 25000,
            nominalLinkRangeM: 8000,
            estimatedDataQuality: .derived,
            powerplant: UAVPowerplantSpec(
                engineType: .turbojet,
                engineDesignation: "AMT AT-180 mini-turbojet",
                ratedThrustN: 66.7,
                propellerPlacement: nil,
                propellerDiameterM: nil,
                ratedShaftRPM: 120000.0,
                starter: .electricStarter,
                startPolicy: .groundStartBeforeLaunch,
                fuel: UAVFuelSpec(
                    fuelType: .turbineKerosene,
                    usableFuelMassKg: 2.0,
                    reserveFraction: 0.20
                )
            )
        ),
        UAVProfile(
            id: "hesa-karrar",
            displayName: "HESA Karrar",
            manufacturer: "HESA",
            countryOfOrigin: "Iran",
            vehicleType: .fixedWing,
            massCategory: .heavy,
            specConfidence: .partial,
            payloadCapabilityMode: .modular,
            baseMass: 263.0,
            batteryMass: nil,
            estimatedBatteryMass: 0.0,
            maxPayloadMass: 227.0,
            maxTakeoffMass: 700.0,
            dimensions: UAVDimensions(
                wingspanMillimeters: 2500.0,
                fuselageLengthMillimeters: 4000.0,
                heightMillimeters: 950.0
            ),
            payloadMountOffset: SIMD3<Float>(0.0, -0.10, 0.10),
            visualPreset: .jetTargetDrone,
            shortDescription: "Turbojet cropped-delta drone with a dorsal intake and underwing hardpoints, rocket-boosted off a rail and recovered by parachute.",
            notes: "Published data list a 4 m length, 2.5 m wingspan, 700 kg maximum takeoff weight, 227 kg payload, one Tolloue-5 or Microturbo TRI 60-5 turbojet of an estimated 4.2-4.4 kN thrust, 900 km/h maximum speed, 1,000 km range with a 500 km combat radius, three hardpoints, a rocket-assist system for takeoff and parachute recovery. Service ceiling, endurance and fuel capacity are not published. The 210 kg fuel load and one-hour endurance modelled here are derived together from the engine's rated thrust and a turbojet's specific consumption, so that tank, engine and endurance agree with each other rather than being three independent guesses; they are estimates, not specifications. Rocket-assisted launch and parachute recovery are not modelled, so this aircraft uses the standard start like the other runway-class aircraft in the catalogue.",
            missionRole: "High-speed target presentation, reconnaissance, and strike carriage",
            armamentCapabilityNote: "Three hardpoints for missiles, bombs, or torpedoes depending on configuration.",
            nominalFlightTimeSec: 3600,
            nominalCruiseSpeedMps: 170.0,
            nominalMaxRangeM: 1000000,
            nominalLinkRangeM: 250000,
            estimatedDataQuality: .derived,
            powerplant: UAVPowerplantSpec(
                engineType: .turbojet,
                engineDesignation: "Tolloue-5 / Microturbo TRI 60-5",
                ratedThrustN: 4200.0,
                propellerPlacement: nil,
                propellerDiameterM: nil,
                ratedShaftRPM: 30000.0,
                starter: .pyrotechnicCartridge,
                startPolicy: .groundStartBeforeLaunch,
                fuel: UAVFuelSpec(
                    fuelType: .turbineKerosene,
                    usableFuelMassKg: 210.0,
                    reserveFraction: 0.12,
                    tankCount: 2
                )
            )
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
        case "aerosonde-mk-4-7":
            return URL(string: "https://www.naval-technology.com/projects/aerosonde-mark-47-small-unmanned-aircraft-system-suas/")
        case "rq-7b-shadow":
            return URL(string: "https://www.designation-systems.net/dusrm/app2/q-7.html")
        case "mq-9a-reaper":
            return URL(string: "https://www.ga-asi.com/remotely-piloted-aircraft/mq-9a")
        case "iai-harpy":
            return URL(string: "https://en.wikipedia.org/wiki/IAI_Harpy")
        case "iai-harop":
            return URL(string: "https://en.wikipedia.org/wiki/IAI_Harop")
        case "iai-harpy-ng":
            return URL(string: "https://en.wikipedia.org/wiki/IAI_Harpy_NG")
        case "epfl-delta-wing-uav":
            return URL(string: "https://link.springer.com/article/10.1007/s13272-024-00727-9")
        case "ncstate-bwb-delta":
            return URL(string: "https://ntrs.nasa.gov/citations/20050169564")
        case "hesa-karrar":
            return URL(string: "https://en.wikipedia.org/wiki/HESA_Karrar")
        default:
            return nil
        }
    }
}
