import Foundation

/// Functional roles available in the Workbench. A role describes how a part
/// participates in the aircraft; it is also offered when a CAD assembly is
/// imported so the same `.cadasm` can be used as a frame, payload or module.
enum WorkbenchComponentKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case motor
    case propeller
    case battery
    case esc
    case servo
    case flightController
    case receiver
    case camera
    case gps
    case sensor
    case payload
    case landingGear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .motor: return "Двигатели"
        case .propeller: return "Пропеллеры"
        case .battery: return "Аккумулятор"
        case .esc: return "Регулятор ESC"
        case .servo: return "Сервопривод"
        case .flightController: return "Полётный контроллер"
        case .receiver: return "Приёмник"
        case .camera: return "Камера"
        case .gps: return "GPS"
        case .sensor: return "Датчик"
        case .payload: return "Полезная нагрузка"
        case .landingGear: return "Шасси"
        }
    }

    var shortName: String {
        switch self {
        case .motor: return "Моторы"
        case .propeller: return "Пропы"
        case .battery: return "АКБ"
        case .esc: return "ESC"
        case .servo: return "Серво"
        case .flightController: return "FC"
        case .receiver: return "RX"
        case .camera: return "Камера"
        case .gps: return "GPS"
        case .sensor: return "Датчик"
        case .payload: return "Payload"
        case .landingGear: return "Шасси"
        }
    }

    var symbolName: String {
        switch self {
        case .motor: return "circle.hexagongrid.fill"
        case .propeller: return "fanblades.fill"
        case .battery: return "battery.75percent"
        case .esc: return "bolt.square.fill"
        case .servo: return "dial.medium.fill"
        case .flightController: return "cpu.fill"
        case .receiver: return "antenna.radiowaves.left.and.right"
        case .camera: return "camera.fill"
        case .gps: return "location.fill"
        case .sensor: return "sensor.fill"
        case .payload: return "shippingbox.fill"
        case .landingGear: return "arrow.down.to.line.compact"
        }
    }

    var preferredMountRole: CADAttachmentImport.Role {
        switch self {
        case .motor, .propeller: return .motor
        case .battery, .esc: return .battery
        case .flightController, .receiver, .gps, .sensor, .servo: return .sensor
        case .camera: return .camera
        case .payload: return .payload
        case .landingGear: return .landingGear
        }
    }
}

/// SceneKit-renderable fallback representation. Imported CAD parts carry a
/// triangle mesh, while built-in catalog parts use these detailed procedural
/// proxies. Sizes are full extents in metres.
struct WorkbenchComponentProxy: Codable, Hashable {
    enum Shape: String, Codable { case box, cylinder, sphere }

    var shape: Shape
    var size: CodableVector3D
    var colorHex: String

    static func box(_ x: Double, _ y: Double, _ z: Double, _ color: String) -> Self {
        Self(shape: .box, size: CodableVector3D(x: x, y: y, z: z), colorHex: color)
    }

    static func cylinder(diameter: Double, height: Double, _ color: String) -> Self {
        Self(shape: .cylinder,
             size: CodableVector3D(x: diameter, y: height, z: diameter),
             colorHex: color)
    }
}

/// A real or fictional catalog part. `params` deliberately remains a flat
/// numeric dictionary: blueprints stay Codable while compatibility rules can
/// evolve without a migration for every new electrical/mechanical property.
struct WorkbenchComponentSpec: Codable, Hashable, Identifiable {
    var id: String
    var kind: WorkbenchComponentKind
    var brand: String
    var displayName: String
    var summary: String
    var massKg: Double
    var proxy: WorkbenchComponentProxy
    var importedMesh: WorkbenchConstruction.Mesh?
    var params: [String: Double]

    init(
        id: String,
        kind: WorkbenchComponentKind,
        brand: String = "UAVSim",
        displayName: String,
        summary: String = "",
        massKg: Double,
        proxy: WorkbenchComponentProxy,
        importedMesh: WorkbenchConstruction.Mesh? = nil,
        params: [String: Double] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.brand = brand
        self.displayName = displayName
        self.summary = summary
        self.massKg = massKg
        self.proxy = proxy
        self.importedMesh = importedMesh
        self.params = params
    }

    enum ParamKey {
        static let motorKv = "kv"
        static let motorMaxThrustN = "maxThrustN"
        static let motorMaxPowerW = "maxPowerW"
        static let motorStatorMm = "statorMm"
        static let motorMinCells = "motorMinCells"
        static let motorMaxCells = "motorMaxCells"
        static let motorPropMinInch = "motorPropMinInch"
        static let motorPropMaxInch = "motorPropMaxInch"
        static let batteryCells = "cells"
        static let batteryCapacityMah = "capacityMah"
        static let batteryEnergyWh = "energyWh"
        static let batteryContinuousC = "continuousC"
        static let propDiameterInch = "diameterInch"
        static let propPitchInch = "pitchInch"
        static let propBladeCount = "bladeCount"
        static let escMaxCurrentA = "escMaxCurrentA"
        static let escMaxCells = "escMaxCells"
        static let servoTorqueNm = "torqueNm"
        static let cameraFovDegrees = "cameraFovDegrees"
    }

    func param(_ key: String) -> Double? { params[key] }

    var sourceBadge: String { importedMesh == nil ? brand : "CADNext" }
}

/// Built-in catalog. Every entry has a procedural 3D model; imported CADNext
/// parts supplement this list per blueprint and retain their own mesh.
enum WorkbenchComponentLibrary {
    private typealias P = WorkbenchComponentSpec.ParamKey

    static let all: [WorkbenchComponentSpec] = motors + propellers + batteries
        + escs + servos + avionics + cameras + payloads + landingGears

    static func spec(id: String) -> WorkbenchComponentSpec? {
        all.first { $0.id == id }
    }

    static func components(of kind: WorkbenchComponentKind) -> [WorkbenchComponentSpec] {
        all.filter { $0.kind == kind }
    }

    private static let motors: [WorkbenchComponentSpec] = [
        .init(
            id: "motor-0802-19000kv", kind: .motor, brand: "NanoLab",
            displayName: "0802 19000KV", summary: "Лёгкий мотор для 65–75 мм whoop",
            massKg: 0.0022, proxy: .cylinder(diameter: 0.010, height: 0.010, "#C9CDD2"),
            params: [P.motorKv: 19_000, P.motorMaxThrustN: 0.42, P.motorMaxPowerW: 28,
                     P.motorStatorMm: 8, P.motorMinCells: 1, P.motorMaxCells: 2,
                     P.motorPropMinInch: 1.2, P.motorPropMaxInch: 1.8]),
        .init(
            id: "motor-1404-3800kv", kind: .motor, brand: "RotorForge",
            displayName: "1404 3800KV", summary: "Micro long-range / toothpick",
            massKg: 0.011, proxy: .cylinder(diameter: 0.018, height: 0.017, "#52606D"),
            params: [P.motorKv: 3800, P.motorMaxThrustN: 4.0, P.motorMaxPowerW: 150,
                     P.motorStatorMm: 14, P.motorMinCells: 2, P.motorMaxCells: 4,
                     P.motorPropMinInch: 2.5, P.motorPropMaxInch: 4.0]),
        .init(
            id: "motor-2207-1900kv", kind: .motor, brand: "RotorForge",
            displayName: "2207 1900KV", summary: "Универсальный 5-дюймовый мотор",
            massKg: 0.032, proxy: .cylinder(diameter: 0.028, height: 0.032, "#30343B"),
            params: [P.motorKv: 1900, P.motorMaxThrustN: 12.0, P.motorMaxPowerW: 360,
                     P.motorStatorMm: 22, P.motorMinCells: 4, P.motorMaxCells: 6,
                     P.motorPropMinInch: 4.5, P.motorPropMaxInch: 5.5]),
        .init(
            id: "motor-2806-1300kv", kind: .motor, brand: "LongHaul",
            displayName: "2806 1300KV", summary: "Экономичный мотор для 7-дюймовых рам",
            massKg: 0.055, proxy: .cylinder(diameter: 0.034, height: 0.038, "#343B46"),
            params: [P.motorKv: 1300, P.motorMaxThrustN: 18.0, P.motorMaxPowerW: 520,
                     P.motorStatorMm: 28, P.motorMinCells: 4, P.motorMaxCells: 6,
                     P.motorPropMinInch: 6.0, P.motorPropMaxInch: 8.0]),
        .init(
            id: "motor-5010-360kv", kind: .motor, brand: "HeavyLift",
            displayName: "5010 360KV", summary: "Низкооборотный двигатель для тяжёлых платформ",
            massKg: 0.092, proxy: .cylinder(diameter: 0.056, height: 0.030, "#2B3038"),
            params: [P.motorKv: 360, P.motorMaxThrustN: 26.0, P.motorMaxPowerW: 720,
                     P.motorStatorMm: 50, P.motorMinCells: 6, P.motorMaxCells: 8,
                     P.motorPropMinInch: 10.0, P.motorPropMaxInch: 15.0]),
    ]

    private static let propellers: [WorkbenchComponentSpec] = [
        .init(id: "prop-1.6x1.6", kind: .propeller, brand: "GemFan",
              displayName: "1.6×1.6 Tri", summary: "Трёхлопастной whoop-пропеллер",
              massKg: 0.0005, proxy: .box(0.040, 0.003, 0.008, "#F05A5A"),
              params: [P.propDiameterInch: 1.6, P.propPitchInch: 1.6, P.propBladeCount: 3]),
        .init(id: "prop-3x2", kind: .propeller, brand: "HQProp",
              displayName: "3×2 Tri", summary: "Плавный пропеллер для лёгких сборок",
              massKg: 0.0018, proxy: .box(0.076, 0.004, 0.012, "#56C7B2"),
              params: [P.propDiameterInch: 3, P.propPitchInch: 2, P.propBladeCount: 3]),
        .init(id: "prop-5x4.3", kind: .propeller, brand: "HQProp",
              displayName: "5×4.3 Tri", summary: "Фристайл, высокая отзывчивость",
              massKg: 0.004, proxy: .box(0.127, 0.006, 0.020, "#23272E"),
              params: [P.propDiameterInch: 5, P.propPitchInch: 4.3, P.propBladeCount: 3]),
        .init(id: "prop-7x4", kind: .propeller, brand: "LongHaul",
              displayName: "7×4 Bi", summary: "Эффективный дальнолётный пропеллер",
              massKg: 0.008, proxy: .box(0.178, 0.007, 0.024, "#384B72"),
              params: [P.propDiameterInch: 7, P.propPitchInch: 4, P.propBladeCount: 2]),
        .init(id: "prop-10x4.5", kind: .propeller, brand: "HeavyLift",
              displayName: "10×4.5 Bi", summary: "Грузовая двухлопастная пара",
              massKg: 0.013, proxy: .box(0.254, 0.008, 0.028, "#22262B"),
              params: [P.propDiameterInch: 10, P.propPitchInch: 4.5, P.propBladeCount: 2]),
    ]

    private static let batteries: [WorkbenchComponentSpec] = [
        .init(id: "battery-2s-450", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 2S 450", summary: "7,4 В · 80C · XT30",
              massKg: 0.030, proxy: .box(0.046, 0.016, 0.025, "#4D72DB"),
              params: [P.batteryCells: 2, P.batteryCapacityMah: 450,
                       P.batteryEnergyWh: 3.33, P.batteryContinuousC: 80]),
        .init(id: "battery-3s-850", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 3S 850", summary: "11,1 В · 75C · XT30",
              massKg: 0.072, proxy: .box(0.060, 0.025, 0.030, "#D44F48"),
              params: [P.batteryCells: 3, P.batteryCapacityMah: 850,
                       P.batteryEnergyWh: 9.44, P.batteryContinuousC: 75]),
        .init(id: "battery-4s-1500", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 4S 1500", summary: "14,8 В · 100C · XT60",
              massKg: 0.185, proxy: .box(0.075, 0.035, 0.030, "#35B66F"),
              params: [P.batteryCells: 4, P.batteryCapacityMah: 1500,
                       P.batteryEnergyWh: 22.2, P.batteryContinuousC: 100]),
        .init(id: "battery-6s-1300", kind: .battery, brand: "RaceCell",
              displayName: "LiPo 6S 1300", summary: "22,2 В · 120C · XT60",
              massKg: 0.220, proxy: .box(0.078, 0.042, 0.036, "#5D4FD4"),
              params: [P.batteryCells: 6, P.batteryCapacityMah: 1300,
                       P.batteryEnergyWh: 28.86, P.batteryContinuousC: 120]),
        .init(id: "battery-6s-5000", kind: .battery, brand: "LongHaul",
              displayName: "Li-Ion 6S 5000", summary: "22,2 В · дальнолётный пакет",
              massKg: 0.680, proxy: .box(0.145, 0.050, 0.045, "#526574"),
              params: [P.batteryCells: 6, P.batteryCapacityMah: 5000,
                       P.batteryEnergyWh: 111.0, P.batteryContinuousC: 20]),
    ]

    private static let escs: [WorkbenchComponentSpec] = [
        .init(id: "esc-4in1-25a", kind: .esc, brand: "Bluejay",
              displayName: "4-в-1 25A", summary: "2–4S, DShot600",
              massKg: 0.009, proxy: .box(0.030, 0.006, 0.030, "#236B63"),
              params: [P.escMaxCurrentA: 25, P.escMaxCells: 4]),
        .init(id: "esc-4in1-45a", kind: .esc, brand: "Bluejay",
              displayName: "4-в-1 45A", summary: "3–6S, телеметрия тока",
              massKg: 0.014, proxy: .box(0.040, 0.006, 0.040, "#292D33"),
              params: [P.escMaxCurrentA: 45, P.escMaxCells: 6]),
        .init(id: "esc-4in1-65a", kind: .esc, brand: "HeavyLift",
              displayName: "4-в-1 65A", summary: "4–8S, увеличенный радиатор",
              massKg: 0.026, proxy: .box(0.050, 0.009, 0.050, "#3E444C"),
              params: [P.escMaxCurrentA: 65, P.escMaxCells: 8]),
    ]

    private static let servos: [WorkbenchComponentSpec] = [
        .init(id: "servo-9g", kind: .servo, brand: "MicroMotion",
              displayName: "Серво 9 г", summary: "Компактный цифровой привод",
              massKg: 0.009, proxy: .box(0.023, 0.024, 0.012, "#B9C2CB"),
              params: [P.servoTorqueNm: 0.17]),
    ]

    private static let avionics: [WorkbenchComponentSpec] = [
        .init(id: "fc-f4-mini", kind: .flightController, brand: "NavCore",
              displayName: "F4 Mini 20×20", summary: "Betaflight · барометр",
              massKg: 0.005, proxy: .box(0.026, 0.005, 0.026, "#206C83")),
        .init(id: "fc-f7", kind: .flightController, brand: "NavCore",
              displayName: "F7 Pro 30×30", summary: "Blackbox · 8 UART · OSD",
              massKg: 0.008, proxy: .box(0.036, 0.005, 0.036, "#124E68")),
        .init(id: "rx-elrs", kind: .receiver, brand: "LinkOne",
              displayName: "ELRS 2.4 ГГц", summary: "Nano RX · diversity",
              massKg: 0.002, proxy: .box(0.015, 0.003, 0.020, "#7A4FB3")),
        .init(id: "rx-crossfire", kind: .receiver, brand: "LinkOne",
              displayName: "Long Range 868", summary: "Дальняя связь · diversity",
              massKg: 0.004, proxy: .box(0.025, 0.004, 0.016, "#8B3F58")),
        .init(id: "gps-m10", kind: .gps, brand: "NavCore",
              displayName: "GPS M10", summary: "GPS/GLONASS/Galileo",
              massKg: 0.010, proxy: .box(0.020, 0.006, 0.020, "#D5A93B")),
        .init(id: "gps-m10-compass", kind: .gps, brand: "NavCore",
              displayName: "GPS M10 + Compass", summary: "Магнитометр и резервный барометр",
              massKg: 0.016, proxy: .cylinder(diameter: 0.028, height: 0.009, "#D8B14B")),
    ]

    private static let cameras: [WorkbenchComponentSpec] = [
        .init(id: "camera-fpv", kind: .camera, brand: "VisionLab",
              displayName: "FPV Nano 1200TVL", summary: "Широкоугольная аналоговая камера",
              massKg: 0.008, proxy: .box(0.019, 0.019, 0.019, "#181A1E"),
              params: [P.cameraFovDegrees: 145]),
        .init(id: "camera-hd", kind: .camera, brand: "VisionLab",
              displayName: "HD Link Camera", summary: "Цифровое видео 1080p/120",
              massKg: 0.024, proxy: .box(0.028, 0.025, 0.026, "#303842"),
              params: [P.cameraFovDegrees: 155]),
        .init(id: "camera-action", kind: .camera, brand: "ActionCam",
              displayName: "Action 4K", summary: "Стабилизация · 4K/60",
              massKg: 0.074, proxy: .box(0.051, 0.038, 0.028, "#26282C"),
              params: [P.cameraFovDegrees: 130]),
    ]

    private static let payloads: [WorkbenchComponentSpec] = [
        .init(id: "sensor-range-mini", kind: .sensor, brand: "SenseWorks",
              displayName: "Range Mini", summary: "Лидар высоты до 40 м",
              massKg: 0.012, proxy: .box(0.022, 0.012, 0.020, "#6C8EA4")),
        .init(id: "payload-camera-gimbal", kind: .payload, brand: "VisionLab",
              displayName: "Micro Gimbal", summary: "Двухосевой подвес камеры",
              massKg: 0.095, proxy: .sphere(0.032, 0.032, 0.032, "#2F3339")),
    ]

    private static let landingGears: [WorkbenchComponentSpec] = [
        .init(id: "gear-skid", kind: .landingGear, brand: "UAVSim",
              displayName: "Шасси-лыжи", summary: "Карбоновые опоры для высокой посадки",
              massKg: 0.040, proxy: .box(0.20, 0.08, 0.02, "#40454B")),
    ]
}

private extension WorkbenchComponentProxy {
    static func sphere(_ x: Double, _ y: Double, _ z: Double, _ color: String) -> Self {
        Self(shape: .sphere, size: CodableVector3D(x: x, y: y, z: z), colorHex: color)
    }
}
