import Foundation

struct WorkbenchTuning: Codable, Hashable {
    var rate: Double = 1.0
    var expo: Double = 0.2

    static let `default` = WorkbenchTuning()
}

enum WorkbenchMountSurface: String, Codable, CaseIterable, Hashable, Identifiable {
    case automatic
    /// Protected avionics/battery compartment.  On an open multicopter this
    /// means the volume between the lower and upper deck; on lifting
    /// airframes it is the radio-transparent fuselage bay under the hatch.
    case internalBay
    case top
    case bottom
    case front
    case rear
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Автоматически"
        case .internalBay: return "Внутри корпуса"
        case .top: return "Сверху"
        case .bottom: return "Снизу"
        case .front: return "Спереди"
        case .rear: return "Сзади"
        case .left: return "Слева"
        case .right: return "Справа"
        }
    }
}

/// User-selected mounting intent. The layout resolver may move a part along
/// the chosen surface just enough to keep physical envelopes from intersecting.
struct WorkbenchComponentPlacement: Codable, Hashable {
    var surface: WorkbenchMountSurface
    var offset: CodableVector3D

    init(
        surface: WorkbenchMountSurface = .automatic,
        offset: CodableVector3D = CodableVector3D(x: 0, y: 0, z: 0)
    ) {
        self.surface = surface
        self.offset = offset
    }
}

/// Portable Workbench blueprint. Built-in parts are referenced by stable IDs;
/// imported CADNext components and meshes are embedded so opening a blueprint
/// on another machine never produces a visually incomplete drone.
struct WorkbenchBuild: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var buildDescription: String
    var frame: WorkbenchFrameSource
    var vehicleArchitecture: WorkbenchVehicleArchitecture

    var motorSpecID: String?
    var propSpecID: String?
    var batterySpecID: String?
    var escSpecID: String?
    var servoSpecID: String?
    var flightControllerSpecID: String?
    var receiverSpecID: String?
    var cameraSpecID: String?
    var gpsSpecID: String?
    var sensorSpecID: String?
    var payloadSpecID: String?
    var landingGearSpecID: String?

    var customComponents: [WorkbenchComponentSpec]
    var componentPlacements: [String: WorkbenchComponentPlacement]
    var rfSystem: RFSystemConfiguration
    var tuning: WorkbenchTuning
    var revision: Int

    init(
        id: UUID = UUID(),
        name: String,
        buildDescription: String = "",
        frame: WorkbenchFrameSource,
        vehicleArchitecture: WorkbenchVehicleArchitecture = .multicopter,
        motorSpecID: String? = nil,
        propSpecID: String? = nil,
        batterySpecID: String? = nil,
        escSpecID: String? = nil,
        servoSpecID: String? = nil,
        flightControllerSpecID: String? = nil,
        receiverSpecID: String? = nil,
        cameraSpecID: String? = nil,
        gpsSpecID: String? = nil,
        sensorSpecID: String? = nil,
        payloadSpecID: String? = nil,
        landingGearSpecID: String? = nil,
        customComponents: [WorkbenchComponentSpec] = [],
        componentPlacements: [String: WorkbenchComponentPlacement] = [:],
        rfSystem: RFSystemConfiguration? = nil,
        tuning: WorkbenchTuning = .default,
        revision: Int = 0
    ) {
        self.id = id
        self.name = name
        self.buildDescription = buildDescription
        self.frame = frame
        // A built-in frame owns its flight architecture: treating a survey
        // wing as a multicopter (or a quad plate as a fixed wing) leaves the
        // renderer, compatibility rules and runtime physics disagreeing about
        // the same blueprint. Imported CAD frames remain explicitly assignable
        // by the user in the import sheet.
        self.vehicleArchitecture = Self.normalizedArchitecture(
            vehicleArchitecture,
            for: frame)
        self.motorSpecID = motorSpecID
        self.propSpecID = propSpecID
        self.batterySpecID = batterySpecID
        self.escSpecID = escSpecID
        self.servoSpecID = servoSpecID
        self.flightControllerSpecID = flightControllerSpecID
        self.receiverSpecID = receiverSpecID
        self.cameraSpecID = cameraSpecID
        self.gpsSpecID = gpsSpecID
        self.sensorSpecID = sensorSpecID
        self.payloadSpecID = payloadSpecID
        self.landingGearSpecID = landingGearSpecID
        self.customComponents = customComponents
        self.componentPlacements = componentPlacements
        let receiver = receiverSpecID.flatMap { id in
            customComponents.first(where: { $0.id == id }) ?? WorkbenchComponentLibrary.spec(id: id)
        }
        self.rfSystem = rfSystem ?? RFCompatibilityPreset.make(
            receiver: receiver,
            hasVideo: cameraSpecID != nil,
            videoMode: cameraSpecID?.hasPrefix("camera-fpv") == true ? .analog : .digital
        )
        self.tuning = tuning
        self.revision = revision
    }

    var resolvedFrame: WorkbenchResolvedFrame {
        frame.resolve(architecture: vehicleArchitecture)
    }

    static func defaultQuad() -> WorkbenchBuild {
        WorkbenchBuild(
            name: "Apex 5 — базовая сборка",
            buildDescription: "Сбалансированный 5-дюймовый квадрокоптер для фристайла.",
            frame: .library(id: WorkbenchFrameLibrary.fiveInch.id),
            vehicleArchitecture: .multicopter,
            motorSpecID: "motor-2207-1900kv",
            propSpecID: "prop-5x4.3",
            batterySpecID: "battery-4s-1500",
            escSpecID: "esc-4in1-45a",
            flightControllerSpecID: "fc-f7",
            receiverSpecID: "rx-elrs",
            cameraSpecID: "camera-fpv",
            gpsSpecID: "gps-m10")
    }

    static func defaultFixedWing() -> WorkbenchBuild {
        WorkbenchBuild(
            name: "Surveyor S1 — базовая сборка",
            buildDescription: "Электрический самолёт для картографирования и длительных маршрутных полётов.",
            frame: .library(id: WorkbenchFrameLibrary.surveyFixedWing.id),
            vehicleArchitecture: .fixedWing,
            motorSpecID: "motor-3520-620kv",
            propSpecID: "prop-12x6-folding",
            batterySpecID: "battery-6s-5000",
            escSpecID: "esc-wing-80a",
            servoSpecID: "servo-17g-metal",
            flightControllerSpecID: "fc-autopilot-h7",
            receiverSpecID: "rx-elrs-915",
            cameraSpecID: "camera-mapping-24mp",
            gpsSpecID: "gps-m10-compass",
            landingGearSpecID: "gear-skid")
    }

    static func defaultVTOL() -> WorkbenchBuild {
        WorkbenchBuild(
            name: "Aquila LC-4 — базовая сборка",
            buildDescription: "Lift+cruise VTOL с четырьмя подъёмными моторами и самолётным крейсерским режимом.",
            frame: .library(id: WorkbenchFrameLibrary.liftCruiseVTOL.id),
            vehicleArchitecture: .liftCruiseVTOL,
            motorSpecID: "motor-3110-900kv",
            propSpecID: "prop-10x4.5",
            batterySpecID: "battery-8s-6000",
            escSpecID: "esc-powerhub-5x80a-vtol",
            servoSpecID: "servo-25g-lowprofile",
            flightControllerSpecID: "fc-autopilot-h7",
            receiverSpecID: "rx-redundant-868",
            cameraSpecID: "camera-mapping-24mp",
            gpsSpecID: "gps-rtk-dual",
            landingGearSpecID: "gear-retractable")
    }

    func specID(for kind: WorkbenchComponentKind) -> String? {
        switch kind {
        case .motor: return motorSpecID
        case .propeller: return propSpecID
        case .battery: return batterySpecID
        case .esc: return escSpecID
        case .servo: return servoSpecID
        case .flightController: return flightControllerSpecID
        case .receiver: return receiverSpecID
        case .camera: return cameraSpecID
        case .gps: return gpsSpecID
        case .sensor: return sensorSpecID
        case .payload: return payloadSpecID
        case .landingGear: return landingGearSpecID
        }
    }

    mutating func setSpec(_ id: String?, for kind: WorkbenchComponentKind) {
        switch kind {
        case .motor: motorSpecID = id
        case .propeller: propSpecID = id
        case .battery: batterySpecID = id
        case .esc: escSpecID = id
        case .servo: servoSpecID = id
        case .flightController: flightControllerSpecID = id
        case .receiver: receiverSpecID = id
        case .camera: cameraSpecID = id
        case .gps: gpsSpecID = id
        case .sensor: sensorSpecID = id
        case .payload: payloadSpecID = id
        case .landingGear: landingGearSpecID = id
        }
        if rfSystem.isAutoGenerated, kind == .receiver || kind == .camera {
            rfSystem = RFCompatibilityPreset.make(for: self)
        }
        revision += 1
    }

    mutating func installImportedComponent(_ component: WorkbenchComponentSpec) {
        if let index = customComponents.firstIndex(where: { $0.id == component.id }) {
            customComponents[index] = component
        } else {
            customComponents.append(component)
        }
        setSpec(component.id, for: component.kind)
    }

    func placement(for kind: WorkbenchComponentKind) -> WorkbenchComponentPlacement {
        componentPlacements[kind.rawValue] ?? WorkbenchComponentPlacement()
    }

    mutating func setMountSurface(_ surface: WorkbenchMountSurface, for kind: WorkbenchComponentKind) {
        var placement = placement(for: kind)
        placement.surface = surface
        componentPlacements[kind.rawValue] = placement
        revision += 1
    }

    func spec(for kind: WorkbenchComponentKind) -> WorkbenchComponentSpec? {
        guard let id = specID(for: kind) else { return nil }
        return customComponents.first(where: { $0.id == id })
            ?? WorkbenchComponentLibrary.spec(id: id)
    }

    func availableComponents(for kind: WorkbenchComponentKind) -> [WorkbenchComponentSpec] {
        WorkbenchComponentLibrary.components(of: kind)
            + customComponents.filter { $0.kind == kind }
    }

    /// Categories are intentionally ordered like a physical build flow and
    /// the Liftoff editor rail.
    static let slotKinds: [WorkbenchComponentKind] = [
        .battery, .motor, .propeller, .esc, .servo, .flightController,
        .receiver, .camera, .gps, .sensor, .payload, .landingGear,
    ]

    // MARK: Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, buildDescription, frame, vehicleArchitecture
        case motorSpecID, propSpecID, batterySpecID, escSpecID, servoSpecID
        case flightControllerSpecID, receiverSpecID, cameraSpecID, gpsSpecID
        case sensorSpecID, payloadSpecID, landingGearSpecID
        case customComponents, componentPlacements, rfSystem, tuning, revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Без имени"
        buildDescription = try c.decodeIfPresent(String.self, forKey: .buildDescription) ?? ""
        frame = try c.decode(WorkbenchFrameSource.self, forKey: .frame)
        let decodedArchitecture = try c.decodeIfPresent(
            WorkbenchVehicleArchitecture.self,
            forKey: .vehicleArchitecture
        ) ?? Self.inferredArchitecture(from: frame)
        vehicleArchitecture = Self.normalizedArchitecture(decodedArchitecture, for: frame)
        motorSpecID = try c.decodeIfPresent(String.self, forKey: .motorSpecID)
        propSpecID = try c.decodeIfPresent(String.self, forKey: .propSpecID)
        batterySpecID = try c.decodeIfPresent(String.self, forKey: .batterySpecID)
        escSpecID = try c.decodeIfPresent(String.self, forKey: .escSpecID)
        servoSpecID = try c.decodeIfPresent(String.self, forKey: .servoSpecID)
        flightControllerSpecID = try c.decodeIfPresent(String.self, forKey: .flightControllerSpecID)
        let decodedReceiverSpecID = try c.decodeIfPresent(String.self, forKey: .receiverSpecID)
        receiverSpecID = decodedReceiverSpecID
        let decodedCameraSpecID = try c.decodeIfPresent(String.self, forKey: .cameraSpecID)
        cameraSpecID = decodedCameraSpecID
        gpsSpecID = try c.decodeIfPresent(String.self, forKey: .gpsSpecID)
        sensorSpecID = try c.decodeIfPresent(String.self, forKey: .sensorSpecID)
        payloadSpecID = try c.decodeIfPresent(String.self, forKey: .payloadSpecID)
        landingGearSpecID = try c.decodeIfPresent(String.self, forKey: .landingGearSpecID)
        let decodedCustomComponents = try c.decodeIfPresent(
            [WorkbenchComponentSpec].self,
            forKey: .customComponents
        ) ?? []
        customComponents = decodedCustomComponents
        componentPlacements = try c.decodeIfPresent(
            [String: WorkbenchComponentPlacement].self,
            forKey: .componentPlacements) ?? [:]
        let decodedRFSystem = try c.decodeIfPresent(RFSystemConfiguration.self, forKey: .rfSystem)
        let receiver = decodedReceiverSpecID.flatMap { id in
            decodedCustomComponents.first(where: { $0.id == id }) ?? WorkbenchComponentLibrary.spec(id: id)
        }
        if let decodedRFSystem, !decodedRFSystem.isAutoGenerated {
            rfSystem = decodedRFSystem
        } else {
            // Compatibility presets are derived data. Rebuild them on load so an older project
            // with an FPV camera picks up the analog-video pipeline, while authored RF systems
            // (including an intentionally selected digital link) remain untouched.
            rfSystem = RFCompatibilityPreset.make(
                receiver: receiver,
                hasVideo: decodedCameraSpecID != nil,
                videoMode: decodedCameraSpecID?.hasPrefix("camera-fpv") == true ? .analog : .digital
            )
        }
        tuning = try c.decodeIfPresent(WorkbenchTuning.self, forKey: .tuning) ?? .default
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    private static func inferredArchitecture(
        from frame: WorkbenchFrameSource
    ) -> WorkbenchVehicleArchitecture {
        guard case let .library(id) = frame,
              let spec = WorkbenchFrameLibrary.spec(id: id) else {
            return .multicopter
        }
        return spec.architecture
    }

    private static func normalizedArchitecture(
        _ requested: WorkbenchVehicleArchitecture,
        for frame: WorkbenchFrameSource
    ) -> WorkbenchVehicleArchitecture {
        guard case let .library(id) = frame else {
            return requested
        }
        return (WorkbenchFrameLibrary.spec(id: id) ?? WorkbenchFrameLibrary.defaultFrame).architecture
    }
}
