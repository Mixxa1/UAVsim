import Foundation

struct WorkbenchTuning: Codable, Hashable {
    var rate: Double = 1.0
    var expo: Double = 0.2

    static let `default` = WorkbenchTuning()
}

/// Portable Workbench blueprint. Built-in parts are referenced by stable IDs;
/// imported CADNext components and meshes are embedded so opening a blueprint
/// on another machine never produces a visually incomplete drone.
struct WorkbenchBuild: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var buildDescription: String
    var frame: WorkbenchFrameSource

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
    var tuning: WorkbenchTuning
    var revision: Int

    init(
        id: UUID = UUID(),
        name: String,
        buildDescription: String = "",
        frame: WorkbenchFrameSource,
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
        tuning: WorkbenchTuning = .default,
        revision: Int = 0
    ) {
        self.id = id
        self.name = name
        self.buildDescription = buildDescription
        self.frame = frame
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
        self.tuning = tuning
        self.revision = revision
    }

    var resolvedFrame: WorkbenchResolvedFrame { frame.resolve() }

    static func defaultQuad() -> WorkbenchBuild {
        WorkbenchBuild(
            name: "Apex 5 — базовая сборка",
            buildDescription: "Сбалансированный 5-дюймовый квадрокоптер для фристайла.",
            frame: .library(id: WorkbenchFrameLibrary.fiveInch.id),
            motorSpecID: "motor-2207-1900kv",
            propSpecID: "prop-5x4.3",
            batterySpecID: "battery-4s-1500",
            escSpecID: "esc-4in1-45a",
            flightControllerSpecID: "fc-f7",
            receiverSpecID: "rx-elrs",
            cameraSpecID: "camera-fpv",
            gpsSpecID: "gps-m10")
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
        case id, name, buildDescription, frame
        case motorSpecID, propSpecID, batterySpecID, escSpecID, servoSpecID
        case flightControllerSpecID, receiverSpecID, cameraSpecID, gpsSpecID
        case sensorSpecID, payloadSpecID, landingGearSpecID
        case customComponents, tuning, revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Без имени"
        buildDescription = try c.decodeIfPresent(String.self, forKey: .buildDescription) ?? ""
        frame = try c.decode(WorkbenchFrameSource.self, forKey: .frame)
        motorSpecID = try c.decodeIfPresent(String.self, forKey: .motorSpecID)
        propSpecID = try c.decodeIfPresent(String.self, forKey: .propSpecID)
        batterySpecID = try c.decodeIfPresent(String.self, forKey: .batterySpecID)
        escSpecID = try c.decodeIfPresent(String.self, forKey: .escSpecID)
        servoSpecID = try c.decodeIfPresent(String.self, forKey: .servoSpecID)
        flightControllerSpecID = try c.decodeIfPresent(String.self, forKey: .flightControllerSpecID)
        receiverSpecID = try c.decodeIfPresent(String.self, forKey: .receiverSpecID)
        cameraSpecID = try c.decodeIfPresent(String.self, forKey: .cameraSpecID)
        gpsSpecID = try c.decodeIfPresent(String.self, forKey: .gpsSpecID)
        sensorSpecID = try c.decodeIfPresent(String.self, forKey: .sensorSpecID)
        payloadSpecID = try c.decodeIfPresent(String.self, forKey: .payloadSpecID)
        landingGearSpecID = try c.decodeIfPresent(String.self, forKey: .landingGearSpecID)
        customComponents = try c.decodeIfPresent([WorkbenchComponentSpec].self, forKey: .customComponents) ?? []
        tuning = try c.decodeIfPresent(WorkbenchTuning.self, forKey: .tuning) ?? .default
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}
