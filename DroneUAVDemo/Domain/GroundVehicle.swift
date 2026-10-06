import Foundation
import simd

enum GroundVehicleModel: String, CaseIterable, Codable, Identifiable {
    case cabover = "harop-cabover-6x6-transport"
    case bonnet = "harpy-bonnet-6x6-transport"
    var id: String { rawValue }
    var titleKey: String { "ground.model.\(self == .cabover ? "cabover" : "bonnet")" }
}

/// Simulation tuning for an unoccupied road vehicle, independent of UAV propulsion and damage.
struct GroundVehicleProfile {
    var massKg: Float = 11000
    var size = SIMD3<Float>(3.39, 3.34, 8.43)
    var wheelbase: Float = 6.2
    var trackWidth: Float = 2.3
    var wheelRadius: Float = 0.62
    var maxSpeed: Float = 20
    var reverseSpeed: Float = 3.5
    var acceleration: Float = 2.3
    var brakeDeceleration: Float = 7
    var maximumSteering: Float = 0.58
    var steeringRate: Float = 0.9
    var tyreFriction: Float = 0.8

    var clearance: Float { size.x * 0.5 + 0.4 }
}

enum GroundVehiclePart: String, CaseIterable, Hashable {
    case body, engine, steering, brakes, suspension
    case wheelFrontLeft, wheelFrontRight, wheelMiddleLeft, wheelMiddleRight, wheelRearLeft, wheelRearRight

    var isWheel: Bool { rawValue.hasPrefix("wheel") }
    var titleKey: String { "ground.part.\(rawValue)" }
    var massFraction: Float {
        switch self {
        case .body: return 0.72
        case .engine: return 0.16
        case .steering: return 0.012
        case .brakes: return 0.018
        case .suspension: return 0.03
        default: return 0.01
        }
    }

    func position(in p: GroundVehicleProfile) -> SIMD3<Float> {
        switch self {
        case .body: return SIMD3<Float>(0, p.size.y * 0.55, 0)
        case .engine: return SIMD3<Float>(0, p.size.y * 0.45, -p.size.z * 0.34)
        case .steering: return SIMD3<Float>(0, p.wheelRadius, -p.wheelbase * 0.5)
        case .brakes: return SIMD3<Float>(0, p.wheelRadius, 0)
        case .suspension: return SIMD3<Float>(0, p.wheelRadius + 0.15, 0)
        case .wheelFrontLeft: return SIMD3<Float>(-p.trackWidth * 0.5, p.wheelRadius, -p.wheelbase * 0.5)
        case .wheelFrontRight: return SIMD3<Float>(p.trackWidth * 0.5, p.wheelRadius, -p.wheelbase * 0.5)
        case .wheelMiddleLeft: return SIMD3<Float>(-p.trackWidth * 0.5, p.wheelRadius, p.wheelbase * (1.6 / 6.2))
        case .wheelMiddleRight: return SIMD3<Float>(p.trackWidth * 0.5, p.wheelRadius, p.wheelbase * (1.6 / 6.2))
        case .wheelRearLeft: return SIMD3<Float>(-p.trackWidth * 0.5, p.wheelRadius, p.wheelbase * 0.5)
        case .wheelRearRight: return SIMD3<Float>(p.trackWidth * 0.5, p.wheelRadius, p.wheelbase * 0.5)
        }
    }
}

struct GroundVehicleDamageSite {
    let point: SIMD3<Float>
    var severity: Float
    var heat: Float
    var tearsPanels: Bool
}

struct GroundVehicleDamage {
    private(set) var integrity: [GroundVehiclePart: Float] = [:]
    private(set) var rolledOver = false
    private(set) var burning = false
    private(set) var firePoint: SIMD3<Float>?
    private(set) var sites: [GroundVehicleDamageSite] = []

    func condition(_ part: GroundVehiclePart) -> Float { integrity[part] ?? 1 }
    var wheelFactor: Float { GroundVehiclePart.allCases.filter(\.isWheel).map(condition).reduce(0, +) / 6 }
    var powerFactor: Float { condition(.engine) }
    var steeringFactor: Float { min(condition(.steering), condition(.suspension)) }
    var brakeFactor: Float { condition(.brakes) * max(0.25, wheelFactor) }
    var steeringBias: Float {
        (condition(.wheelFrontRight) - condition(.wheelFrontLeft)) * 0.12
    }
    var functionalState: InterceptFunctionalState {
        if burning || condition(.body) < 0.08 { return .destroyed }
        if rolledOver || powerFactor < 0.08 || wheelFactor < 0.25 || steeringFactor < 0.08 { return .disabled }
        let worst = GroundVehiclePart.allCases.map(condition).min() ?? 1
        return worst < 0.45 ? .degraded : worst < 0.97 ? .damaged : .nominal
    }

    /// Localised contact damage. Panels absorb most of a body strike; a struck wheel loses
    /// grip and bends its suspension. There are no rotor, lift or flight-controller failures.
    mutating func impact(energyJ: Float, bodyPoint: SIMD3<Float>, profile: GroundVehicleProfile) {
        guard energyJ.isFinite, energyJ > 0, bodyPoint.x.isFinite, bodyPoint.y.isFinite, bodyPoint.z.isFinite else { return }
        let scale = max(0.5, profile.massKg / 1800)
        mark(point: bodyPoint, severity: min(1, energyJ / (70_000 * scale)), heat: 0,
             tearsPanels: energyJ > 100_000 * scale)
        let nearestWheel = GroundVehiclePart.allCases.filter(\.isWheel)
            .min { simd_distance($0.position(in: profile), bodyPoint) < simd_distance($1.position(in: profile), bodyPoint) }!
        let wheelHit = simd_distance(nearestWheel.position(in: profile), bodyPoint) < profile.wheelRadius * 1.8
        degrade(.body, by: energyJ / (180_000 * scale))
        if wheelHit {
            degrade(nearestWheel, by: energyJ / (9_000 * scale))
            degrade(.suspension, by: energyJ / (55_000 * scale))
            degrade(.brakes, by: energyJ / (100_000 * scale))
            if nearestWheel == .wheelFrontLeft || nearestWheel == .wheelFrontRight {
                degrade(.steering, by: energyJ / (40_000 * scale))
            }
        } else if bodyPoint.z < -profile.wheelbase * 0.35 {
            degrade(.engine, by: energyJ / (65_000 * scale))
            degrade(.steering, by: energyJ / (100_000 * scale))
        }
        if condition(.body) < 0.12, condition(.engine) < 0.1 {
            ignite(at: GroundVehiclePart.engine.position(in: profile))
        }
    }

    /// Contact-module effects remain game rules. A net can foul road wheels; it cannot
    /// magically destroy a heavy chassis by applying the aircraft's rotor failure recipe.
    mutating func applyModule(_ effect: AttachedPayloadProfile, at point: SIMD3<Float>, profile: GroundVehicleProfile) {
        switch effect {
        case .contactOnly: break
        case .equipmentDisruption:
            guard point.y < profile.wheelRadius * 2.2 else { return }
            let wheel = GroundVehiclePart.allCases.filter(\.isWheel)
                .min { simd_distance($0.position(in: profile), point) < simd_distance($1.position(in: profile), point) }!
            degrade(wheel, by: 0.7)
        case .kineticPenetration: impact(energyJ: 35_000, bodyPoint: point, profile: profile)
        case .structuralDestruction: detonation(exposure: 1, bodyPoint: point, profile: profile)
        }
    }

    /// A charge damages the chassis and nearby running gear separately from a road impact.
    /// Location matters: a rear strike does not ignite the engine at the opposite end.
    mutating func detonation(exposure: Float, bodyPoint: SIMD3<Float>, profile: GroundVehicleProfile) {
        guard exposure.isFinite, exposure > 0,
              bodyPoint.x.isFinite, bodyPoint.y.isFinite, bodyPoint.z.isFinite else { return }
        let strength = min(1, exposure)
        // Visual damage follows the actual strike. A severe tyre/bed strike can burn there
        // while the engine at the other end of the truck remains intact.
        mark(point: bodyPoint, severity: strength, heat: strength, tearsPanels: strength > 0.65)
        degrade(.body, by: strength * 0.96)
        for part in GroundVehiclePart.allCases where part != .body {
            let distance = simd_distance(part.position(in: profile), bodyPoint)
            let local = max(0, 1 - distance / 4)
            let susceptibility: Float = part.isWheel ? 1.5 : part == .engine ? 1.2 : 1.1
            degrade(part, by: strength * (0.12 + local * susceptibility))
        }
        if condition(.engine) < 0.08, condition(.body) < 0.3 {
            ignite(at: GroundVehiclePart.engine.position(in: profile))
        } else if strength > 0.8 {
            let nearestWheel = GroundVehiclePart.allCases.filter(\.isWheel).min {
                simd_distance($0.position(in: profile), bodyPoint) < simd_distance($1.position(in: profile), bodyPoint)
            }!
            if condition(nearestWheel) < 0.12 {
                ignite(at: nearestWheel.position(in: profile))
            }
        }
    }

    mutating func overturn() { rolledOver = true }
    private mutating func ignite(at point: SIMD3<Float>) {
        burning = true
        if firePoint == nil { firePoint = point }
    }
    private mutating func mark(point: SIMD3<Float>, severity: Float, heat: Float, tearsPanels: Bool) {
        guard severity > 0.015 else { return }
        if let index = sites.firstIndex(where: { simd_distance($0.point, point) < 0.8 }) {
            sites[index].severity = min(1, sites[index].severity + severity * 0.5)
            sites[index].heat = max(sites[index].heat, heat)
            sites[index].tearsPanels = sites[index].tearsPanels || tearsPanels
        } else if sites.count < 8 {
            sites.append(GroundVehicleDamageSite(point: point, severity: severity, heat: heat, tearsPanels: tearsPanels))
        }
    }
    private mutating func degrade(_ part: GroundVehiclePart, by amount: Float) {
        integrity[part] = max(0, condition(part) - max(0, amount))
    }
}
