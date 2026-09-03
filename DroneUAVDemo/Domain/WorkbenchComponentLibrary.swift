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
        static let motorShaftMm = "motorShaftMm"
        static let motorMinCells = "motorMinCells"
        static let motorMaxCells = "motorMaxCells"
        static let motorPropMinInch = "motorPropMinInch"
        static let motorPropMaxInch = "motorPropMaxInch"
        static let batteryCells = "cells"
        static let batteryCapacityMah = "capacityMah"
        static let batteryEnergyWh = "energyWh"
        static let batteryContinuousC = "continuousC"
        static let batteryLengthMm = "batteryLengthMm"
        static let batteryWidthMm = "batteryWidthMm"
        static let batteryHeightMm = "batteryHeightMm"
        static let propDiameterInch = "diameterInch"
        static let propPitchInch = "pitchInch"
        static let propBladeCount = "bladeCount"
        static let escMaxCurrentA = "escMaxCurrentA"
        static let escMinCells = "escMinCells"
        static let escMaxCells = "escMaxCells"
        static let servoTorqueNm = "torqueNm"
        static let servoSpeedSec60 = "servoSpeedSec60"
        static let servoMinVolts = "servoMinVolts"
        static let servoMaxVolts = "servoMaxVolts"
        static let flightControllerMountMm = "flightControllerMountMm"
        static let flightControllerUartCount = "flightControllerUartCount"
        static let receiverFrequencyMHz = "receiverFrequencyMHz"
        static let receiverRangeKm = "receiverRangeKm"
        static let cameraFovDegrees = "cameraFovDegrees"
        static let cameraResolutionMP = "cameraResolutionMP"
        static let gpsAccuracyM = "gpsAccuracyM"
        static let gpsUpdateHz = "gpsUpdateHz"
        static let sensorRangeM = "sensorRangeM"
        static let sensorFovDegrees = "sensorFovDegrees"
        static let payloadPowerW = "payloadPowerW"
        static let landingGearClearanceMm = "landingGearClearanceMm"
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
            params: [P.motorKv: 19_000, P.motorMaxThrustN: 0.42, P.motorMaxPowerW: 18,
                     P.motorStatorMm: 8, P.motorMinCells: 1, P.motorMaxCells: 2,
                     P.motorPropMinInch: 1.2, P.motorPropMaxInch: 1.8]),
        .init(
            id: "motor-1002-22000kv", kind: .motor, brand: "NanoLab",
            displayName: "1002 22000KV", summary: "Высокооборотный мотор для 75-мм whoop",
            massKg: 0.0028, proxy: .cylinder(diameter: 0.012, height: 0.011, "#5A6F8A"),
            params: [P.motorKv: 22_000, P.motorMaxThrustN: 0.65, P.motorMaxPowerW: 38,
                     P.motorStatorMm: 10, P.motorShaftMm: 1.5,
                     P.motorMinCells: 1, P.motorMaxCells: 2,
                     P.motorPropMinInch: 1.4, P.motorPropMaxInch: 2.0]),
        .init(
            id: "motor-1103-8000kv", kind: .motor, brand: "RotorForge",
            displayName: "1103 8000KV", summary: "2S-мотор для тихих micro-сборок",
            massKg: 0.0052, proxy: .cylinder(diameter: 0.014, height: 0.013, "#68737F"),
            params: [P.motorKv: 8000, P.motorMaxThrustN: 1.25, P.motorMaxPowerW: 64,
                     P.motorStatorMm: 11, P.motorShaftMm: 1.5,
                     P.motorMinCells: 2, P.motorMaxCells: 3,
                     P.motorPropMinInch: 1.8, P.motorPropMaxInch: 2.5]),
        .init(
            id: "motor-1404-3800kv", kind: .motor, brand: "RotorForge",
            displayName: "1404 3800KV", summary: "Micro long-range / toothpick",
            massKg: 0.011, proxy: .cylinder(diameter: 0.018, height: 0.017, "#52606D"),
            params: [P.motorKv: 3800, P.motorMaxThrustN: 4.0, P.motorMaxPowerW: 150,
                     P.motorStatorMm: 14, P.motorMinCells: 2, P.motorMaxCells: 4,
                     P.motorPropMinInch: 2.5, P.motorPropMaxInch: 4.0]),
        .init(
            id: "motor-1505-3600kv", kind: .motor, brand: "RotorForge",
            displayName: "1505 3600KV", summary: "Лёгкий 3–4S мотор для 3-дюймовых рам",
            massKg: 0.0135, proxy: .cylinder(diameter: 0.019, height: 0.018, "#526B78"),
            params: [P.motorKv: 3600, P.motorMaxThrustN: 3.8, P.motorMaxPowerW: 145,
                     P.motorStatorMm: 15, P.motorShaftMm: 2,
                     P.motorMinCells: 3, P.motorMaxCells: 4,
                     P.motorPropMinInch: 2.5, P.motorPropMaxInch: 3.5]),
        .init(
            id: "motor-1804-2450kv", kind: .motor, brand: "AeroPulse",
            displayName: "1804 2450KV", summary: "Эффективный мотор для 3.5-дюймового ultralight",
            massKg: 0.018, proxy: .cylinder(diameter: 0.022, height: 0.020, "#4E5966"),
            params: [P.motorKv: 2450, P.motorMaxThrustN: 5.6, P.motorMaxPowerW: 210,
                     P.motorStatorMm: 18, P.motorShaftMm: 3,
                     P.motorMinCells: 3, P.motorMaxCells: 4,
                     P.motorPropMinInch: 3.0, P.motorPropMaxInch: 4.0]),
        .init(
            id: "motor-2004-3000kv", kind: .motor, brand: "CineMotion",
            displayName: "2004 3000KV", summary: "Плавная тяга для 4S cinewhoop",
            massKg: 0.021, proxy: .cylinder(diameter: 0.024, height: 0.021, "#78685B"),
            params: [P.motorKv: 3000, P.motorMaxThrustN: 7.0, P.motorMaxPowerW: 275,
                     P.motorStatorMm: 20, P.motorShaftMm: 3,
                     P.motorMinCells: 3, P.motorMaxCells: 4,
                     P.motorPropMinInch: 3.0, P.motorPropMaxInch: 4.5]),
        .init(
            id: "motor-2207-2450kv", kind: .motor, brand: "RaceCell",
            displayName: "2207 2450KV", summary: "Резкий 4S мотор для гоночной трассы",
            massKg: 0.031, proxy: .cylinder(diameter: 0.028, height: 0.031, "#9A3F3A"),
            params: [P.motorKv: 2450, P.motorMaxThrustN: 12.8, P.motorMaxPowerW: 480,
                     P.motorStatorMm: 22, P.motorShaftMm: 5,
                     P.motorMinCells: 3, P.motorMaxCells: 4,
                     P.motorPropMinInch: 4.5, P.motorPropMaxInch: 5.2]),
        .init(
            id: "motor-2207-1900kv", kind: .motor, brand: "RotorForge",
            displayName: "2207 1900KV", summary: "Универсальный 5-дюймовый мотор",
            massKg: 0.032, proxy: .cylinder(diameter: 0.028, height: 0.032, "#30343B"),
            params: [P.motorKv: 1900, P.motorMaxThrustN: 12.0, P.motorMaxPowerW: 360,
                     P.motorStatorMm: 22, P.motorMinCells: 4, P.motorMaxCells: 6,
                     P.motorPropMinInch: 4.5, P.motorPropMaxInch: 5.5]),
        .init(
            id: "motor-2306-1750kv", kind: .motor, brand: "RotorForge",
            displayName: "2306 1750KV", summary: "6S-мотор с запасом тяги для фристайла",
            massKg: 0.034, proxy: .cylinder(diameter: 0.029, height: 0.033, "#394B59"),
            params: [P.motorKv: 1750, P.motorMaxThrustN: 14.2, P.motorMaxPowerW: 520,
                     P.motorStatorMm: 23, P.motorShaftMm: 5,
                     P.motorMinCells: 4, P.motorMaxCells: 6,
                     P.motorPropMinInch: 4.8, P.motorPropMaxInch: 5.5]),
        .init(
            id: "motor-2507-1500kv", kind: .motor, brand: "LongHaul",
            displayName: "2507 1500KV", summary: "Усиленный мотор для 6-дюймового дальнолёта",
            massKg: 0.041, proxy: .cylinder(diameter: 0.031, height: 0.035, "#3B4652"),
            params: [P.motorKv: 1500, P.motorMaxThrustN: 16.8, P.motorMaxPowerW: 600,
                     P.motorStatorMm: 25, P.motorShaftMm: 5,
                     P.motorMinCells: 4, P.motorMaxCells: 6,
                     P.motorPropMinInch: 5.5, P.motorPropMaxInch: 6.5]),
        .init(
            id: "motor-2806-1300kv", kind: .motor, brand: "LongHaul",
            displayName: "2806 1300KV", summary: "Экономичный мотор для 7-дюймовых рам",
            massKg: 0.055, proxy: .cylinder(diameter: 0.034, height: 0.038, "#343B46"),
            params: [P.motorKv: 1300, P.motorMaxThrustN: 18.0, P.motorMaxPowerW: 520,
                     P.motorStatorMm: 28, P.motorMinCells: 4, P.motorMaxCells: 6,
                     P.motorPropMinInch: 6.0, P.motorPropMaxInch: 8.0]),
        .init(
            id: "motor-3110-900kv", kind: .motor, brand: "LongHaul",
            displayName: "3110 900KV", summary: "Тяговый двигатель для 8–10-дюймовых платформ",
            massKg: 0.086, proxy: .cylinder(diameter: 0.038, height: 0.042, "#303A45"),
            params: [P.motorKv: 900, P.motorMaxThrustN: 27.5, P.motorMaxPowerW: 850,
                     P.motorStatorMm: 31, P.motorShaftMm: 5,
                     P.motorMinCells: 6, P.motorMaxCells: 8,
                     P.motorPropMinInch: 8.0, P.motorPropMaxInch: 10.5]),
        .init(
            id: "motor-3520-620kv", kind: .motor, brand: "AeroCruise",
            displayName: "3520 620KV", summary: "Крейсерский двигатель для самолётов 1,4–2 м",
            massKg: 0.145, proxy: .cylinder(diameter: 0.045, height: 0.047, "#35414C"),
            params: [P.motorKv: 620, P.motorMaxThrustN: 38.0, P.motorMaxPowerW: 1_100,
                     P.motorStatorMm: 35, P.motorShaftMm: 5,
                     P.motorMinCells: 6, P.motorMaxCells: 8,
                     P.motorPropMinInch: 10.0, P.motorPropMaxInch: 13.0]),
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
        .init(id: "prop-1.9x1.9", kind: .propeller, brand: "GemFan",
              displayName: "1.9×1.9 Quad", summary: "Четырёхлопастной пропеллер для 75-мм whoop",
              massKg: 0.0007, proxy: .box(0.048, 0.003, 0.008, "#F2A65A"),
              params: [P.propDiameterInch: 1.9, P.propPitchInch: 1.9, P.propBladeCount: 4]),
        .init(id: "prop-2.5x2.3", kind: .propeller, brand: "CineMotion",
              displayName: "2.5×2.3 Quad", summary: "Тихий duct-пропеллер для cinewhoop",
              massKg: 0.0013, proxy: .box(0.064, 0.004, 0.010, "#D6E7F0"),
              params: [P.propDiameterInch: 2.5, P.propPitchInch: 2.3, P.propBladeCount: 4]),
        .init(id: "prop-3x2", kind: .propeller, brand: "HQProp",
              displayName: "3×2 Tri", summary: "Плавный пропеллер для лёгких сборок",
              massKg: 0.0018, proxy: .box(0.076, 0.004, 0.012, "#56C7B2"),
              params: [P.propDiameterInch: 3, P.propPitchInch: 2, P.propBladeCount: 3]),
        .init(id: "prop-3.5x2.8", kind: .propeller, brand: "AeroPulse",
              displayName: "3.5×2.8 Tri", summary: "Лёгкий ultralight-пропеллер с плавной серединой газа",
              massKg: 0.0024, proxy: .box(0.089, 0.004, 0.014, "#73A6D8"),
              params: [P.propDiameterInch: 3.5, P.propPitchInch: 2.8, P.propBladeCount: 3]),
        .init(id: "prop-4x2.5", kind: .propeller, brand: "HQProp",
              displayName: "4×2.5 Tri", summary: "Эффективный пропеллер для sub-250 сборок",
              massKg: 0.0031, proxy: .box(0.102, 0.005, 0.016, "#B9D6B2"),
              params: [P.propDiameterInch: 4, P.propPitchInch: 2.5, P.propBladeCount: 3]),
        .init(id: "prop-5.1x3.6-bi", kind: .propeller, brand: "RaceCell",
              displayName: "5.1×3.6 Bi", summary: "Малое сопротивление и высокая скорость на трассе",
              massKg: 0.0032, proxy: .box(0.130, 0.005, 0.018, "#E14B4B"),
              params: [P.propDiameterInch: 5.1, P.propPitchInch: 3.6, P.propBladeCount: 2]),
        .init(id: "prop-5x4.3", kind: .propeller, brand: "HQProp",
              displayName: "5×4.3 Tri", summary: "Фристайл, высокая отзывчивость",
              massKg: 0.004, proxy: .box(0.127, 0.006, 0.020, "#23272E"),
              params: [P.propDiameterInch: 5, P.propPitchInch: 4.3, P.propBladeCount: 3]),
        .init(id: "prop-5.1x3.5-cine", kind: .propeller, brand: "CineMotion",
              displayName: "5.1×3.5 Penta", summary: "Пять лопастей для плавного кинематографического полёта",
              massKg: 0.0065, proxy: .box(0.130, 0.006, 0.021, "#6879A8"),
              params: [P.propDiameterInch: 5.1, P.propPitchInch: 3.5, P.propBladeCount: 5]),
        .init(id: "prop-6x3.5", kind: .propeller, brand: "LongHaul",
              displayName: "6×3.5 Tri", summary: "Сбалансированный пропеллер для 6-дюймового дальнолёта",
              massKg: 0.0063, proxy: .box(0.152, 0.006, 0.022, "#455E78"),
              params: [P.propDiameterInch: 6, P.propPitchInch: 3.5, P.propBladeCount: 3]),
        .init(id: "prop-7x4", kind: .propeller, brand: "LongHaul",
              displayName: "7×4 Bi", summary: "Эффективный дальнолётный пропеллер",
              massKg: 0.008, proxy: .box(0.178, 0.007, 0.024, "#384B72"),
              params: [P.propDiameterInch: 7, P.propPitchInch: 4, P.propBladeCount: 2]),
        .init(id: "prop-8x4", kind: .propeller, brand: "LongHaul",
              displayName: "8×4 Bi", summary: "Крейсерский карбоновый пропеллер",
              massKg: 0.0105, proxy: .box(0.203, 0.007, 0.026, "#2D333A"),
              params: [P.propDiameterInch: 8, P.propPitchInch: 4, P.propBladeCount: 2]),
        .init(id: "prop-10x4.5", kind: .propeller, brand: "HeavyLift",
              displayName: "10×4.5 Bi", summary: "Грузовая двухлопастная пара",
              massKg: 0.013, proxy: .box(0.254, 0.008, 0.028, "#22262B"),
              params: [P.propDiameterInch: 10, P.propPitchInch: 4.5, P.propBladeCount: 2]),
        .init(id: "prop-10x3.8-tri", kind: .propeller, brand: "HeavyLift",
              displayName: "10×3.8 Tri", summary: "Трёхлопастной пропеллер с высокой статической тягой",
              massKg: 0.018, proxy: .box(0.254, 0.009, 0.030, "#3C424A"),
              params: [P.propDiameterInch: 10, P.propPitchInch: 3.8, P.propBladeCount: 3]),
        .init(id: "prop-12x6-folding", kind: .propeller, brand: "AeroCruise",
              displayName: "12×6 Folding", summary: "Складной двухлопастной пропеллер для самолёта",
              massKg: 0.025, proxy: .box(0.305, 0.009, 0.032, "#252B31"),
              params: [P.propDiameterInch: 12, P.propPitchInch: 6, P.propBladeCount: 2]),
    ]

    private static let batteries: [WorkbenchComponentSpec] = [
        .init(id: "battery-1s-300", kind: .battery, brand: "NanoLab",
              displayName: "LiPo 1S 300", summary: "3,7 В · 75C · BT2.0",
              massKg: 0.008, proxy: .box(0.032, 0.007, 0.013, "#5E86D6"),
              params: [P.batteryCells: 1, P.batteryCapacityMah: 300,
                       P.batteryEnergyWh: 1.11, P.batteryContinuousC: 75,
                       P.batteryLengthMm: 32, P.batteryWidthMm: 13, P.batteryHeightMm: 7]),
        .init(id: "battery-1s-550", kind: .battery, brand: "NanoLab",
              displayName: "LiPo 1S 550", summary: "3,7 В · 95C · BT2.0",
              massKg: 0.014, proxy: .box(0.045, 0.008, 0.017, "#6B91E0"),
              params: [P.batteryCells: 1, P.batteryCapacityMah: 550,
                       P.batteryEnergyWh: 2.04, P.batteryContinuousC: 95,
                       P.batteryLengthMm: 45, P.batteryWidthMm: 17, P.batteryHeightMm: 8]),
        .init(id: "battery-2s-450", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 2S 450", summary: "7,4 В · 80C · XT30",
              massKg: 0.030, proxy: .box(0.046, 0.016, 0.025, "#4D72DB"),
              params: [P.batteryCells: 2, P.batteryCapacityMah: 450,
                       P.batteryEnergyWh: 3.33, P.batteryContinuousC: 80,
                       P.batteryLengthMm: 46, P.batteryWidthMm: 25, P.batteryHeightMm: 16]),
        .init(id: "battery-2s-850", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 2S 850", summary: "7,4 В · 70C · XT30",
              massKg: 0.048, proxy: .box(0.058, 0.018, 0.028, "#456AC7"),
              params: [P.batteryCells: 2, P.batteryCapacityMah: 850,
                       P.batteryEnergyWh: 6.29, P.batteryContinuousC: 70,
                       P.batteryLengthMm: 58, P.batteryWidthMm: 28, P.batteryHeightMm: 18]),
        .init(id: "battery-3s-850", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 3S 850", summary: "11,1 В · 75C · XT30",
              massKg: 0.072, proxy: .box(0.060, 0.025, 0.030, "#D44F48"),
              params: [P.batteryCells: 3, P.batteryCapacityMah: 850,
                       P.batteryEnergyWh: 9.44, P.batteryContinuousC: 75,
                       P.batteryLengthMm: 60, P.batteryWidthMm: 30, P.batteryHeightMm: 25]),
        .init(id: "battery-4s-850", kind: .battery, brand: "RaceCell",
              displayName: "LiPo 4S 850", summary: "14,8 В · 95C · XT30",
              massKg: 0.101, proxy: .box(0.062, 0.030, 0.030, "#B7494B"),
              params: [P.batteryCells: 4, P.batteryCapacityMah: 850,
                       P.batteryEnergyWh: 12.58, P.batteryContinuousC: 95,
                       P.batteryLengthMm: 62, P.batteryWidthMm: 30, P.batteryHeightMm: 30]),
        .init(id: "battery-4s-1500", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 4S 1500", summary: "14,8 В · 100C · XT60",
              massKg: 0.185, proxy: .box(0.075, 0.035, 0.030, "#35B66F"),
              params: [P.batteryCells: 4, P.batteryCapacityMah: 1500,
                       P.batteryEnergyWh: 22.2, P.batteryContinuousC: 100,
                       P.batteryLengthMm: 75, P.batteryWidthMm: 30, P.batteryHeightMm: 35]),
        .init(id: "battery-4s-2200", kind: .battery, brand: "VoltEdge",
              displayName: "LiPo 4S 2200", summary: "14,8 В · 75C · XT60",
              massKg: 0.255, proxy: .box(0.105, 0.035, 0.034, "#2F9F63"),
              params: [P.batteryCells: 4, P.batteryCapacityMah: 2200,
                       P.batteryEnergyWh: 32.56, P.batteryContinuousC: 75,
                       P.batteryLengthMm: 105, P.batteryWidthMm: 34, P.batteryHeightMm: 35]),
        .init(id: "battery-liion-4s-3000", kind: .battery, brand: "LongHaul",
              displayName: "Li-Ion 4S 3000", summary: "14,8 В · энергоёмкий пакет 21700",
              massKg: 0.285, proxy: .box(0.075, 0.043, 0.043, "#516B73"),
              params: [P.batteryCells: 4, P.batteryCapacityMah: 3000,
                       P.batteryEnergyWh: 44.4, P.batteryContinuousC: 15,
                       P.batteryLengthMm: 75, P.batteryWidthMm: 43, P.batteryHeightMm: 43]),
        .init(id: "battery-6s-1100", kind: .battery, brand: "RaceCell",
              displayName: "LiPo 6S 1100", summary: "22,2 В · 120C · XT60",
              massKg: 0.190, proxy: .box(0.074, 0.039, 0.034, "#6957D7"),
              params: [P.batteryCells: 6, P.batteryCapacityMah: 1100,
                       P.batteryEnergyWh: 24.42, P.batteryContinuousC: 120,
                       P.batteryLengthMm: 74, P.batteryWidthMm: 34, P.batteryHeightMm: 39]),
        .init(id: "battery-6s-1300", kind: .battery, brand: "RaceCell",
              displayName: "LiPo 6S 1300", summary: "22,2 В · 120C · XT60",
              massKg: 0.220, proxy: .box(0.078, 0.042, 0.036, "#5D4FD4"),
              params: [P.batteryCells: 6, P.batteryCapacityMah: 1300,
                       P.batteryEnergyWh: 28.86, P.batteryContinuousC: 120,
                       P.batteryLengthMm: 78, P.batteryWidthMm: 36, P.batteryHeightMm: 42]),
        .init(id: "battery-6s-2200", kind: .battery, brand: "LongHaul",
              displayName: "LiPo 6S 2200", summary: "22,2 В · 75C · XT60",
              massKg: 0.355, proxy: .box(0.108, 0.046, 0.040, "#4D52B7"),
              params: [P.batteryCells: 6, P.batteryCapacityMah: 2200,
                       P.batteryEnergyWh: 48.84, P.batteryContinuousC: 75,
                       P.batteryLengthMm: 108, P.batteryWidthMm: 40, P.batteryHeightMm: 46]),
        .init(id: "battery-6s-5000", kind: .battery, brand: "LongHaul",
              displayName: "Li-Ion 6S 5000", summary: "22,2 В · дальнолётный пакет",
              massKg: 0.680, proxy: .box(0.145, 0.050, 0.045, "#526574"),
              params: [P.batteryCells: 6, P.batteryCapacityMah: 5000,
                       P.batteryEnergyWh: 111.0, P.batteryContinuousC: 20,
                       P.batteryLengthMm: 145, P.batteryWidthMm: 45, P.batteryHeightMm: 50]),
        .init(id: "battery-8s-6000", kind: .battery, brand: "HeavyLift",
              displayName: "LiPo 8S 6000", summary: "29,6 В · 35C · AS150",
              massKg: 1.080, proxy: .box(0.165, 0.063, 0.056, "#3F5362"),
              params: [P.batteryCells: 8, P.batteryCapacityMah: 6000,
                       P.batteryEnergyWh: 177.6, P.batteryContinuousC: 35,
                       P.batteryLengthMm: 165, P.batteryWidthMm: 56, P.batteryHeightMm: 63]),
    ]

    private static let escs: [WorkbenchComponentSpec] = [
        .init(id: "esc-aio-5a", kind: .esc, brand: "NanoLab",
              displayName: "AIO 4×5A", summary: "1–2S · встроен в whoop-плату",
              massKg: 0.0022, proxy: .box(0.026, 0.004, 0.026, "#2E6D58"),
              params: [P.escMaxCurrentA: 5, P.escMinCells: 1, P.escMaxCells: 2]),
        .init(id: "esc-4in1-12a", kind: .esc, brand: "Bluejay",
              displayName: "4-в-1 12A", summary: "1–2S · Bluejay · RPM-фильтр",
              massKg: 0.0045, proxy: .box(0.026, 0.005, 0.026, "#287761"),
              params: [P.escMaxCurrentA: 12, P.escMinCells: 1, P.escMaxCells: 2]),
        .init(id: "esc-4in1-20a", kind: .esc, brand: "Bluejay",
              displayName: "4-в-1 20A", summary: "2–4S · DShot600 · 20×20",
              massKg: 0.007, proxy: .box(0.030, 0.005, 0.030, "#246A5D"),
              params: [P.escMaxCurrentA: 20, P.escMinCells: 2, P.escMaxCells: 4]),
        .init(id: "esc-4in1-25a", kind: .esc, brand: "Bluejay",
              displayName: "4-в-1 25A", summary: "2–4S, DShot600",
              massKg: 0.009, proxy: .box(0.030, 0.006, 0.030, "#236B63"),
              params: [P.escMaxCurrentA: 25, P.escMinCells: 2, P.escMaxCells: 4]),
        .init(id: "esc-4in1-35a", kind: .esc, brand: "AeroPulse",
              displayName: "4-в-1 35A", summary: "3–6S · двусторонний DShot · 20×20",
              massKg: 0.010, proxy: .box(0.032, 0.006, 0.032, "#32383F"),
              params: [P.escMaxCurrentA: 35, P.escMinCells: 3, P.escMaxCells: 6]),
        .init(id: "esc-4in1-45a", kind: .esc, brand: "Bluejay",
              displayName: "4-в-1 45A", summary: "3–6S, телеметрия тока",
              massKg: 0.014, proxy: .box(0.040, 0.006, 0.040, "#292D33"),
              params: [P.escMaxCurrentA: 45, P.escMinCells: 3, P.escMaxCells: 6]),
        .init(id: "esc-4in1-55a", kind: .esc, brand: "RaceCell",
              displayName: "4-в-1 55A", summary: "3–6S · 128K PWM · 30×30",
              massKg: 0.018, proxy: .box(0.042, 0.007, 0.042, "#34353B"),
              params: [P.escMaxCurrentA: 55, P.escMinCells: 3, P.escMaxCells: 6]),
        .init(id: "esc-4in1-65a", kind: .esc, brand: "HeavyLift",
              displayName: "4-в-1 65A", summary: "4–8S, увеличенный радиатор",
              massKg: 0.026, proxy: .box(0.050, 0.009, 0.050, "#3E444C"),
              params: [P.escMaxCurrentA: 65, P.escMinCells: 4, P.escMaxCells: 8]),
        .init(id: "esc-wing-80a", kind: .esc, brand: "AeroCruise",
              displayName: "Wing ESC 80A HV", summary: "6–8S · одноосевой ESC с активным охлаждением",
              massKg: 0.075, proxy: .box(0.064, 0.019, 0.036, "#303942"),
              params: [P.escMaxCurrentA: 80, P.escMinCells: 6, P.escMaxCells: 8]),
        .init(id: "esc-powerhub-4x80a", kind: .esc, brand: "HeavyLift",
              displayName: "PowerHub 4×80A HV", summary: "4–12S · четыре канала · телеметрия",
              massKg: 0.152, proxy: .box(0.082, 0.016, 0.068, "#424A52"),
              params: [P.escMaxCurrentA: 80, P.escMinCells: 4, P.escMaxCells: 12]),
        .init(id: "esc-powerhub-5x80a-vtol", kind: .esc, brand: "HeavyLift",
              displayName: "VTOL PowerHub 5×80A", summary: "4–12S · 4 lift + cruise · CAN-телеметрия",
              massKg: 0.185, proxy: .box(0.092, 0.018, 0.074, "#3B464F"),
              params: [P.escMaxCurrentA: 80, P.escMinCells: 4, P.escMaxCells: 12]),
    ]

    private static let servos: [WorkbenchComponentSpec] = [
        .init(id: "servo-2g-linear", kind: .servo, brand: "MicroMotion",
              displayName: "Линейное серво 2 г", summary: "Сверхлёгкий привод камеры или заслонки",
              massKg: 0.0022, proxy: .box(0.015, 0.016, 0.007, "#D6D9DD"),
              params: [P.servoTorqueNm: 0.035, P.servoSpeedSec60: 0.09,
                       P.servoMinVolts: 3.7, P.servoMaxVolts: 5]),
        .init(id: "servo-9g", kind: .servo, brand: "MicroMotion",
              displayName: "Серво 9 г", summary: "Компактный цифровой привод",
              massKg: 0.009, proxy: .box(0.023, 0.024, 0.012, "#B9C2CB"),
              params: [P.servoTorqueNm: 0.17, P.servoSpeedSec60: 0.10,
                       P.servoMinVolts: 4.8, P.servoMaxVolts: 6]),
        .init(id: "servo-17g-metal", kind: .servo, brand: "MicroMotion",
              displayName: "Metal Gear 17 г", summary: "Металлический редуктор и двойной подшипник",
              massKg: 0.017, proxy: .box(0.030, 0.030, 0.014, "#85909A"),
              params: [P.servoTorqueNm: 0.34, P.servoSpeedSec60: 0.085,
                       P.servoMinVolts: 5, P.servoMaxVolts: 7.4]),
        .init(id: "servo-25g-lowprofile", kind: .servo, brand: "AeroPulse",
              displayName: "Low Profile 25 г", summary: "Быстрый привод подвеса и механизма сброса",
              massKg: 0.025, proxy: .box(0.035, 0.027, 0.016, "#59636E"),
              params: [P.servoTorqueNm: 0.58, P.servoSpeedSec60: 0.065,
                       P.servoMinVolts: 6, P.servoMaxVolts: 8.4]),
        .init(id: "servo-40g-hv", kind: .servo, brand: "HeavyLift",
              displayName: "HV Coreless 40 г", summary: "Высокомоментный привод для тяжёлой нагрузки",
              massKg: 0.040, proxy: .box(0.041, 0.039, 0.020, "#3E4852"),
              params: [P.servoTorqueNm: 1.15, P.servoSpeedSec60: 0.075,
                       P.servoMinVolts: 6, P.servoMaxVolts: 8.4]),
    ]

    private static let avionics: [WorkbenchComponentSpec] = [
        .init(id: "fc-f411-whoop-aio", kind: .flightController, brand: "NanoLab",
              displayName: "F411 Whoop AIO", summary: "25.5×25.5 · OSD · встроенный ELRS",
              massKg: 0.0038, proxy: .box(0.029, 0.005, 0.029, "#17677A"),
              params: [P.flightControllerMountMm: 25.5, P.flightControllerUartCount: 2]),
        .init(id: "fc-f4-mini", kind: .flightController, brand: "NavCore",
              displayName: "F4 Mini 20×20", summary: "Betaflight · барометр",
              massKg: 0.005, proxy: .box(0.026, 0.005, 0.026, "#206C83"),
              params: [P.flightControllerMountMm: 20, P.flightControllerUartCount: 4]),
        .init(id: "fc-f405", kind: .flightController, brand: "NavCore",
              displayName: "F405 Core 30×30", summary: "Blackbox 16 МБ · барометр · OSD",
              massKg: 0.007, proxy: .box(0.036, 0.005, 0.036, "#176078"),
              params: [P.flightControllerMountMm: 30.5, P.flightControllerUartCount: 5]),
        .init(id: "fc-f7", kind: .flightController, brand: "NavCore",
              displayName: "F7 Pro 30×30", summary: "Blackbox · 8 UART · OSD",
              massKg: 0.008, proxy: .box(0.036, 0.005, 0.036, "#124E68"),
              params: [P.flightControllerMountMm: 30.5, P.flightControllerUartCount: 8]),
        .init(id: "fc-h7-dual", kind: .flightController, brand: "NavCore",
              displayName: "H7 Dual IMU", summary: "Два IMU · 10 UART · 128 МБ blackbox",
              massKg: 0.011, proxy: .box(0.038, 0.007, 0.038, "#123D57"),
              params: [P.flightControllerMountMm: 30.5, P.flightControllerUartCount: 10]),
        .init(id: "fc-autopilot-h7", kind: .flightController, brand: "AeroNav",
              displayName: "Autopilot H7", summary: "ArduPilot · тройной IMU · Ethernet",
              massKg: 0.038, proxy: .box(0.052, 0.014, 0.052, "#274A5B"),
              params: [P.flightControllerMountMm: 45, P.flightControllerUartCount: 12]),
        .init(id: "rx-elrs", kind: .receiver, brand: "LinkOne",
              displayName: "ELRS 2.4 ГГц", summary: "Nano RX · diversity",
              massKg: 0.002, proxy: .box(0.015, 0.003, 0.020, "#7A4FB3"),
              params: [P.receiverFrequencyMHz: 2400, P.receiverRangeKm: 12]),
        .init(id: "rx-elrs-915", kind: .receiver, brand: "LinkOne",
              displayName: "ELRS 915 МГц", summary: "Long Range Nano · TCXO · diversity",
              massKg: 0.003, proxy: .box(0.022, 0.004, 0.014, "#69459D"),
              params: [P.receiverFrequencyMHz: 915, P.receiverRangeKm: 35]),
        .init(id: "rx-crossfire", kind: .receiver, brand: "LinkOne",
              displayName: "Long Range 868", summary: "Дальняя связь · diversity",
              massKg: 0.004, proxy: .box(0.025, 0.004, 0.016, "#8B3F58"),
              params: [P.receiverFrequencyMHz: 868, P.receiverRangeKm: 40]),
        .init(id: "rx-redundant-868", kind: .receiver, brand: "AeroNav",
              displayName: "Redundant RX 868", summary: "Два независимых канала и резервное питание",
              massKg: 0.012, proxy: .box(0.034, 0.007, 0.024, "#793D50"),
              params: [P.receiverFrequencyMHz: 868, P.receiverRangeKm: 55]),
        .init(id: "gps-m8-nano", kind: .gps, brand: "NavCore",
              displayName: "GPS M8 Nano", summary: "Лёгкий модуль для micro-сборок",
              massKg: 0.004, proxy: .box(0.015, 0.005, 0.015, "#C69B35"),
              params: [P.gpsAccuracyM: 2.5, P.gpsUpdateHz: 5]),
        .init(id: "gps-m10", kind: .gps, brand: "NavCore",
              displayName: "GPS M10", summary: "GPS/GLONASS/Galileo",
              massKg: 0.010, proxy: .box(0.020, 0.006, 0.020, "#D5A93B"),
              params: [P.gpsAccuracyM: 1.5, P.gpsUpdateHz: 10]),
        .init(id: "gps-m10-compass", kind: .gps, brand: "NavCore",
              displayName: "GPS M10 + Compass", summary: "Магнитометр и резервный барометр",
              massKg: 0.016, proxy: .cylinder(diameter: 0.028, height: 0.009, "#D8B14B"),
              params: [P.gpsAccuracyM: 1.3, P.gpsUpdateHz: 10]),
        .init(id: "gps-rtk-dual", kind: .gps, brand: "AeroNav",
              displayName: "RTK Dual Compass", summary: "Сантиметровое позиционирование и двойная антенна",
              massKg: 0.058, proxy: .box(0.060, 0.014, 0.028, "#C39A42"),
              params: [P.gpsAccuracyM: 0.025, P.gpsUpdateHz: 20]),
    ]

    private static let cameras: [WorkbenchComponentSpec] = [
        .init(id: "camera-fpv-micro", kind: .camera, brand: "VisionLab",
              displayName: "FPV Micro 1000TVL", summary: "14-мм аналоговая камера для whoop",
              massKg: 0.0035, proxy: .box(0.014, 0.014, 0.016, "#20242A"),
              params: [P.cameraFovDegrees: 146, P.cameraResolutionMP: 1.2]),
        .init(id: "camera-fpv", kind: .camera, brand: "VisionLab",
              displayName: "FPV Nano 1200TVL", summary: "Широкоугольная аналоговая камера",
              massKg: 0.008, proxy: .box(0.019, 0.019, 0.019, "#181A1E"),
              params: [P.cameraFovDegrees: 139, P.cameraResolutionMP: 1.2]),
        .init(id: "camera-fpv-lowlight", kind: .camera, brand: "VisionLab",
              displayName: "FPV Starlight", summary: "Высокая чувствительность для сумерек и помещений",
              massKg: 0.010, proxy: .box(0.021, 0.021, 0.020, "#202329"),
              params: [P.cameraFovDegrees: 135, P.cameraResolutionMP: 1.2]),
        .init(id: "camera-hd-mini", kind: .camera, brand: "VisionLab",
              displayName: "HD Link Mini", summary: "Цифровое видео 1080p/100 для micro-сборок",
              massKg: 0.012, proxy: .box(0.020, 0.020, 0.021, "#35404B"),
              params: [P.cameraFovDegrees: 128, P.cameraResolutionMP: 2.1]),
        .init(id: "camera-hd", kind: .camera, brand: "VisionLab",
              displayName: "HD Link Camera", summary: "Цифровое видео 1080p/120",
              massKg: 0.024, proxy: .box(0.028, 0.025, 0.026, "#303842"),
              params: [P.cameraFovDegrees: 110, P.cameraResolutionMP: 8.3]),
        .init(id: "camera-action-mini", kind: .camera, brand: "ActionCam",
              displayName: "Action Mini 4K", summary: "Лёгкая запись 4K/60 со стабилизацией",
              massKg: 0.035, proxy: .box(0.038, 0.030, 0.024, "#2B2D31"),
              params: [P.cameraFovDegrees: 99, P.cameraResolutionMP: 8.3]),
        .init(id: "camera-action", kind: .camera, brand: "ActionCam",
              displayName: "Action 4K", summary: "Стабилизация · 4K/60",
              massKg: 0.074, proxy: .box(0.051, 0.038, 0.028, "#26282C"),
              params: [P.cameraFovDegrees: 80, P.cameraResolutionMP: 8.3]),
        .init(id: "camera-mapping-24mp", kind: .camera, brand: "GeoVision",
              displayName: "Mapping 24 MP", summary: "Глобальный затвор и интервальная съёмка",
              massKg: 0.145, proxy: .box(0.052, 0.044, 0.040, "#39434A"),
              params: [P.cameraFovDegrees: 58, P.cameraResolutionMP: 24.0]),
    ]

    private static let payloads: [WorkbenchComponentSpec] = [
        .init(id: "sensor-range-mini", kind: .sensor, brand: "SenseWorks",
              displayName: "Range Mini", summary: "Лидар высоты до 40 м",
              massKg: 0.012, proxy: .box(0.022, 0.012, 0.020, "#6C8EA4"),
              params: [P.sensorRangeM: 40, P.sensorFovDegrees: 3]),
        .init(id: "sensor-optical-flow", kind: .sensor, brand: "SenseWorks",
              displayName: "Optical Flow Mini", summary: "Удержание позиции без GPS до 8 м",
              massKg: 0.006, proxy: .box(0.018, 0.010, 0.018, "#58798B"),
              params: [P.sensorRangeM: 8, P.sensorFovDegrees: 42]),
        .init(id: "sensor-lidar-200", kind: .sensor, brand: "SenseWorks",
              displayName: "LiDAR 200", summary: "Дальномер для картографии и облёта препятствий",
              massKg: 0.048, proxy: .cylinder(diameter: 0.042, height: 0.026, "#475D69"),
              params: [P.sensorRangeM: 200, P.sensorFovDegrees: 2]),
        .init(id: "sensor-radar-altimeter", kind: .sensor, brand: "AeroNav",
              displayName: "Radar Altimeter 120", summary: "Высотомер для дождя, пыли и слабой видимости",
              massKg: 0.085, proxy: .box(0.062, 0.018, 0.046, "#4A5962"),
              params: [P.sensorRangeM: 120, P.sensorFovDegrees: 24]),
        .init(id: "sensor-obstacle-array", kind: .sensor, brand: "SenseWorks",
              displayName: "Obstacle Array 360", summary: "Шесть ToF-секторов кругового обзора",
              massKg: 0.038, proxy: .cylinder(diameter: 0.050, height: 0.018, "#566B75"),
              params: [P.sensorRangeM: 30, P.sensorFovDegrees: 360]),
        .init(id: "sensor-air-quality", kind: .sensor, brand: "EnviroLab",
              displayName: "Air Quality Pod", summary: "PM2.5, CO₂, температура и влажность",
              massKg: 0.062, proxy: .box(0.055, 0.030, 0.038, "#6B817B"),
              params: [P.sensorRangeM: 0, P.payloadPowerW: 3.5]),
        .init(id: "payload-camera-gimbal", kind: .payload, brand: "VisionLab",
              displayName: "Micro Gimbal", summary: "Двухосевой подвес камеры",
              massKg: 0.095, proxy: .sphere(0.032, 0.032, 0.032, "#2F3339"),
              params: [P.payloadPowerW: 8]),
        .init(id: "payload-thermal-gimbal", kind: .payload, brand: "GeoVision",
              displayName: "Thermal Gimbal", summary: "Радиометрическая тепловизионная камера 640×512",
              massKg: 0.185, proxy: .sphere(0.052, 0.052, 0.052, "#34383E"),
              params: [P.cameraFovDegrees: 45, P.cameraResolutionMP: 0.33, P.payloadPowerW: 14]),
        .init(id: "payload-lidar-survey", kind: .payload, brand: "GeoVision",
              displayName: "Survey LiDAR", summary: "Лазерное сканирование 240 тыс. точек/с",
              massKg: 0.420, proxy: .cylinder(diameter: 0.090, height: 0.075, "#49545C"),
              params: [P.sensorRangeM: 300, P.sensorFovDegrees: 360, P.payloadPowerW: 28]),
        .init(id: "payload-multispectral", kind: .payload, brand: "AgroScan",
              displayName: "Multispectral 5-band", summary: "RGB + четыре спектральных канала для NDVI",
              massKg: 0.210, proxy: .box(0.085, 0.050, 0.060, "#3F5549"),
              params: [P.cameraFovDegrees: 70, P.cameraResolutionMP: 12, P.payloadPowerW: 11]),
        .init(id: "payload-cargo-release", kind: .payload, brand: "LiftWorks",
              displayName: "Cargo Release", summary: "Дублированный электромеханический замок до 2 кг",
              massKg: 0.125, proxy: .box(0.080, 0.035, 0.050, "#5C646B"),
              params: [P.payloadPowerW: 16]),
        .init(id: "payload-delivery-pod", kind: .payload, brand: "LiftWorks",
              displayName: "Delivery Pod 1.5 L", summary: "Защищённый контейнер для срочной доставки",
              massKg: 0.310, proxy: .box(0.180, 0.100, 0.110, "#D5D8D7"),
              params: [P.payloadPowerW: 2]),
        .init(id: "payload-sprayer-1l", kind: .payload, brand: "AgroScan",
              displayName: "Sprayer 1 L", summary: "Бак, насос и две регулируемые форсунки",
              massKg: 0.460, proxy: .cylinder(diameter: 0.120, height: 0.160, "#D8E2D8"),
              params: [P.payloadPowerW: 38]),
        .init(id: "payload-searchlight", kind: .payload, brand: "RescueTech",
              displayName: "Searchlight 40 W", summary: "Стабилизированный прожектор для поисковых работ",
              massKg: 0.235, proxy: .cylinder(diameter: 0.075, height: 0.090, "#E4C85A"),
              params: [P.payloadPowerW: 40]),
    ]

    private static let landingGears: [WorkbenchComponentSpec] = [
        .init(id: "gear-micro-guards", kind: .landingGear, brand: "NanoLab",
              displayName: "Micro Guards", summary: "Защита моторов и низкие посадочные опоры",
              massKg: 0.008, proxy: .box(0.085, 0.018, 0.085, "#5A626B"),
              params: [P.landingGearClearanceMm: 12]),
        .init(id: "gear-skid", kind: .landingGear, brand: "UAVSim",
              displayName: "Шасси-лыжи", summary: "Карбоновые опоры для высокой посадки",
              massKg: 0.040, proxy: .box(0.20, 0.08, 0.02, "#40454B"),
              params: [P.landingGearClearanceMm: 70]),
        .init(id: "gear-cine-bumpers", kind: .landingGear, brand: "CineMotion",
              displayName: "Cine Bumpers", summary: "Сменные TPU-опоры для мягкой посадки",
              massKg: 0.022, proxy: .box(0.13, 0.035, 0.13, "#4F5963"),
              params: [P.landingGearClearanceMm: 24]),
        .init(id: "gear-tall-carbon", kind: .landingGear, brand: "LiftWorks",
              displayName: "Tall Carbon Gear", summary: "Высокие карбоновые стойки под подвес",
              massKg: 0.115, proxy: .box(0.32, 0.18, 0.04, "#2E3338"),
              params: [P.landingGearClearanceMm: 155]),
        .init(id: "gear-retractable", kind: .landingGear, brand: "LiftWorks",
              displayName: "Retractable Gear", summary: "Складное шасси для кругового обзора камеры",
              massKg: 0.260, proxy: .box(0.38, 0.22, 0.05, "#343A40"),
              params: [P.landingGearClearanceMm: 190, P.payloadPowerW: 18]),
    ]
}

private extension WorkbenchComponentProxy {
    static func sphere(_ x: Double, _ y: Double, _ z: Double, _ color: String) -> Self {
        Self(shape: .sphere, size: CodableVector3D(x: x, y: y, z: z), colorHex: color)
    }
}
