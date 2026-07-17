import Foundation
import simd

enum WorkbenchAirframeClass: String, Codable {
    case multicopter
    case custom
}

struct WorkbenchBuildStats: Hashable {
    var totalMassKg: Double = 0
    var centerOfMass: SIMD3<Double> = .zero
    var motorCount: Int = 0
    var batteryEnergyWh: Double = 0
    var batteryCells: Int = 0
    var batteryCapacityMah: Double = 0
    var nominalVoltage: Double = 0
    var totalMaxThrustN: Double = 0
    var thrustToWeight: Double = 0
    var maxRPM: Double = 0
    var maxElectricalPowerW: Double = 0
    var estimatedHoverTimeMin: Double = 0
    var estimatedMaxSpeedMps: Double = 0
    var inferredClass: WorkbenchAirframeClass = .multicopter
    var componentCount: Int = 0

    var errors: [String] = []
    var warnings: [String] = []

    var isFlightReady: Bool { errors.isEmpty && thrustToWeight >= 1.0 }
}

enum WorkbenchBuildAnalyzer {
    private static let gravity = 9.80665

    static func analyze(_ build: WorkbenchBuild) -> WorkbenchBuildStats {
        var stats = WorkbenchBuildStats()
        let frame = build.resolvedFrame
        let arms = frame.motorMounts.count
        let p = WorkbenchComponentSpec.ParamKey.self

        var mass = max(frame.massKg, 0)
        var weightedCoM = SIMD3<Double>.zero
        stats.componentCount = 1

        let motor = build.spec(for: .motor)
        let propeller = build.spec(for: .propeller)
        if motor != nil { stats.motorCount = arms }
        for mount in frame.motorMounts {
            let position = SIMD3<Double>(Double(mount.x), Double(mount.y), Double(mount.z))
            if let motor {
                mass += motor.massKg
                weightedCoM += position * motor.massKg
                stats.componentCount += 1
            }
            if let propeller {
                mass += propeller.massKg
                weightedCoM += position * propeller.massKg
                stats.componentCount += 1
            }
        }

        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard let spec = build.spec(for: kind) else { continue }
            let slot = slotPosition(kind, frame: frame)
            mass += spec.massKg
            weightedCoM += SIMD3<Double>(Double(slot.x), Double(slot.y), Double(slot.z)) * spec.massKg
            stats.componentCount += 1
            if kind == .battery {
                stats.batteryEnergyWh = spec.param(p.batteryEnergyWh) ?? 0
                stats.batteryCells = Int(spec.param(p.batteryCells) ?? 0)
                stats.batteryCapacityMah = spec.param(p.batteryCapacityMah) ?? 0
                stats.nominalVoltage = Double(stats.batteryCells) * 3.7
            }
        }
        stats.totalMassKg = mass
        stats.centerOfMass = mass > 1e-9 ? weightedCoM / mass : .zero

        if let motor {
            let singleThrust = motor.param(p.motorMaxThrustN) ?? 0
            stats.totalMaxThrustN = singleThrust * Double(arms)
            let motorPower = motor.param(p.motorMaxPowerW) ?? 0
            stats.maxElectricalPowerW = motorPower * Double(arms)
            let kv = motor.param(p.motorKv) ?? 0
            stats.maxRPM = kv * stats.nominalVoltage
        }
        let weightN = mass * gravity
        stats.thrustToWeight = weightN > 1e-6 ? stats.totalMaxThrustN / weightN : 0

        if let propeller {
            let pitch = propeller.param(p.propPitchInch) ?? 0
            let pitchSpeed = pitch * 0.0254 * stats.maxRPM / 60.0
            // Real slip is substantial; T/W adds a small authority benefit.
            stats.estimatedMaxSpeedMps = min(48, pitchSpeed * 0.68 * max(0.55, min(stats.thrustToWeight / 2.2, 1.15)))
        }
        if stats.batteryEnergyWh > 0, stats.maxElectricalPowerW > 0, stats.thrustToWeight > 0 {
            let hoverThrottle = sqrt(min(1, 1 / max(stats.thrustToWeight, 0.01)))
            let hoverPower = stats.maxElectricalPowerW * pow(hoverThrottle, 1.55)
            stats.estimatedHoverTimeMin = stats.batteryEnergyWh / max(hoverPower, 1) * 60 * 0.82
        }

        stats.inferredClass = arms >= 3 ? .multicopter : .custom
        for issue in WorkbenchCompatibility.check(build) {
            switch issue.severity {
            case .error: stats.errors.append(issue.message)
            case .warning: stats.warnings.append(issue.message)
            }
        }
        if stats.totalMaxThrustN > 0, stats.thrustToWeight < 1.0 {
            stats.errors.append(String(
                format: "Тяги недостаточно для взлёта (тяговооружённость %.2f).",
                stats.thrustToWeight))
        } else if stats.thrustToWeight > 0, stats.thrustToWeight < 1.8 {
            stats.warnings.append(String(
                format: "Низкая тяговооружённость %.2f — рекомендуем не меньше 2,0.",
                stats.thrustToWeight))
        }
        if stats.estimatedHoverTimeMin > 0, stats.estimatedHoverTimeMin < 2.5 {
            stats.warnings.append("Расчётное время висения меньше 2,5 минут.")
        }

        let horizontalLimit = max(frame.sizeMeters.x, frame.sizeMeters.z) * 0.6 + 0.04
        if simd_length(SIMD2(stats.centerOfMass.x, stats.centerOfMass.z)) > horizontalLimit {
            stats.warnings.append("Центр масс смещён за безопасную область рамы.")
        }
        return stats
    }

    static func slotPosition(
        _ kind: WorkbenchComponentKind,
        frame: WorkbenchResolvedFrame
    ) -> SIMD3<Float> {
        switch kind {
        case .battery: return frame.batteryTray
        case .camera: return frame.cameraMount
        case .payload: return SIMD3<Float>(0, -0.025, 0)
        case .landingGear: return SIMD3<Float>(0, -0.035, 0)
        case .gps: return frame.fcBay + SIMD3<Float>(0, 0.028, -0.025)
        case .receiver: return frame.fcBay + SIMD3<Float>(0.018, 0.012, -0.015)
        case .sensor: return frame.fcBay + SIMD3<Float>(-0.018, 0.012, -0.015)
        case .esc: return frame.fcBay + SIMD3<Float>(0, 0.004, 0)
        case .flightController: return frame.fcBay + SIMD3<Float>(0, 0.012, 0)
        case .servo: return frame.fcBay + SIMD3<Float>(-0.025, 0.010, 0)
        case .motor, .propeller: return .zero
        }
    }
}
