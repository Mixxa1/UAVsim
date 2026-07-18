import Foundation

enum DiagnosticOverlayMode: String, CaseIterable, Identifiable {
    case normal
    case thermal
    case damage

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .normal:
            return "diagnostic.mode.normal"
        case .thermal:
            return "diagnostic.mode.thermal"
        case .damage:
            return "diagnostic.mode.damage"
        }
    }
}

enum ComponentWarningState: String {
    case nominal
    case warning
    case critical

    var titleKey: String {
        switch self {
        case .nominal:
            return "warning.nominal"
        case .warning:
            return "warning.warning"
        case .critical:
            return "warning.critical"
        }
    }
}

enum DamageSeverity: String {
    case nominal
    case light
    case medium
    case critical

    var titleKey: String {
        switch self {
        case .nominal:
            return "damage.severity.nominal"
        case .light:
            return "damage.severity.light"
        case .medium:
            return "damage.severity.medium"
        case .critical:
            return "damage.severity.critical"
        }
    }
}

enum DamageComponent: String, CaseIterable, Identifiable {
    case battery
    case frontCameraGimbal
    case flightControllerCore
    case motorFL
    case motorFR
    case motorRL
    case motorRR
    case propellerFL
    case propellerFR
    case propellerRL
    case propellerRR
    case armFL
    case armFR
    case armRL
    case armRR
    case escPower

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .battery:
            return "component.battery"
        case .frontCameraGimbal:
            return "component.gimbal"
        case .flightControllerCore:
            return "component.fc_core"
        case .motorFL:
            return "component.motor_fl"
        case .motorFR:
            return "component.motor_fr"
        case .motorRL:
            return "component.motor_rl"
        case .motorRR:
            return "component.motor_rr"
        case .propellerFL:
            return "component.propeller_fl"
        case .propellerFR:
            return "component.propeller_fr"
        case .propellerRL:
            return "component.propeller_rl"
        case .propellerRR:
            return "component.propeller_rr"
        case .armFL:
            return "component.arm_fl"
        case .armFR:
            return "component.arm_fr"
        case .armRL:
            return "component.arm_rl"
        case .armRR:
            return "component.arm_rr"
        case .escPower:
            return "component.esc_power"
        }
    }

    var group: String {
        switch self {
        case .battery:
            return "power"
        case .frontCameraGimbal:
            return "sensor"
        case .flightControllerCore:
            return "control"
        case .motorFL, .motorFR, .motorRL, .motorRR:
            return "motor"
        case .propellerFL, .propellerFR, .propellerRL, .propellerRR:
            return "propeller"
        case .armFL, .armFR, .armRL, .armRR:
            return "structure"
        case .escPower:
            return "power"
        }
    }
}

struct DamageState {
    var healthByComponent: [DamageComponent: Float]
    var hiddenComponents: Set<DamageComponent>
    var selectedComponent: DamageComponent?

    init(
        healthByComponent: [DamageComponent: Float] = [:],
        hiddenComponents: Set<DamageComponent> = [],
        selectedComponent: DamageComponent? = nil
    ) {
        self.healthByComponent = healthByComponent
        self.hiddenComponents = hiddenComponents
        self.selectedComponent = selectedComponent

        for component in DamageComponent.allCases where self.healthByComponent[component] == nil {
            self.healthByComponent[component] = 1.0
        }
    }

    static let pristine = DamageState()

    func health(for component: DamageComponent) -> Float {
        healthByComponent[component] ?? 1.0
    }

    var averageHealth: Float {
        let values = DamageComponent.allCases.map { health(for: $0) }
        return values.reduce(0, +) / Float(values.count)
    }

    var controlAuthorityMultiplier: Float {
        let motorHealth = averageHealth(for: [.motorFL, .motorFR, .motorRL, .motorRR])
        let propHealth = averageHealth(for: [.propellerFL, .propellerFR, .propellerRL, .propellerRR])
        let frameHealth = averageHealth(for: [.armFL, .armFR, .armRL, .armRR])
        let controllerHealth = health(for: .flightControllerCore)

        let weighted = motorHealth * 0.34 + propHealth * 0.28 + frameHealth * 0.18 + controllerHealth * 0.20
        return weighted.clamped(to: 0.12...1.0)
    }

    var batteryPenaltyMultiplier: Float {
        let batteryHealth = health(for: .battery)
        let escHealth = health(for: .escPower)
        // Damaged propellers/motors force the healthy ones to compensate —
        // real current draw goes up with the same commanded flight.
        let propHealth = averageHealth(for: [.propellerFL, .propellerFR, .propellerRL, .propellerRR])
        let motorHealth = averageHealth(for: [.motorFL, .motorFR, .motorRL, .motorRR])
        let penalty = 1.0 + (1.0 - batteryHealth) * 0.6 + (1.0 - escHealth) * 0.35 +
            (1.0 - propHealth) * 0.35 + (1.0 - motorHealth) * 0.25
        return penalty.clamped(to: 1.0...2.2)
    }

    var severity: DamageSeverity {
        let minimumComponentHealth = DamageComponent.allCases.map { health(for: $0) }.min() ?? 1.0
        if averageHealth < 0.34 || minimumComponentHealth < 0.18 {
            return .critical
        }
        if averageHealth < 0.58 || minimumComponentHealth < 0.36 {
            return .medium
        }
        if averageHealth < 0.82 || minimumComponentHealth < 0.62 {
            return .light
        }
        return .nominal
    }

    var isFlightCritical: Bool {
        if severity == .critical {
            return true
        }

        let motorHealth = averageHealth(for: [.motorFL, .motorFR, .motorRL, .motorRR])
        let propHealth = averageHealth(for: [.propellerFL, .propellerFR, .propellerRL, .propellerRR])
        let frameHealth = averageHealth(for: [.armFL, .armFR, .armRL, .armRR])
        return motorHealth < 0.24 || propHealth < 0.20 || frameHealth < 0.18
    }

    func warningState(for component: DamageComponent, temperature: Float) -> ComponentWarningState {
        let health = health(for: component)
        if health < 0.35 || temperature > 86.0 {
            return .critical
        }
        if health < 0.72 || temperature > 72.0 {
            return .warning
        }
        return .nominal
    }

    func applyingCollisionDamage(impactEnergy: Float) -> DamageState {
        var updated = self
        let baseDamage = (impactEnergy * 0.055).clamped(to: 0.015...0.42)

        for component in DamageComponent.allCases {
            let bias: Float
            switch component.group {
            case "propeller":
                bias = 1.35
            case "motor":
                bias = 1.12
            case "structure":
                bias = 1.05
            case "sensor":
                bias = 0.82
            case "control":
                bias = 0.74
            case "power":
                bias = 0.95
            default:
                bias = 1.0
            }

            let health = updated.health(for: component)
            updated.healthByComponent[component] = (health - baseDamage * bias).clamped(to: 0.0...1.0)
        }

        return updated
    }

    func withHidden(_ component: DamageComponent, hidden: Bool) -> DamageState {
        var updated = self
        if hidden {
            updated.hiddenComponents.insert(component)
        } else {
            updated.hiddenComponents.remove(component)
        }
        return updated
    }

    func withSelected(_ component: DamageComponent?) -> DamageState {
        var updated = self
        updated.selectedComponent = component
        return updated
    }

    var summary: String {
        let damaged = DamageComponent.allCases.filter { health(for: $0) < 0.95 }
        guard !damaged.isEmpty else {
            return NSLocalizedString("summary.damage.none", comment: "")
        }

        let top = damaged
            .sorted { health(for: $0) < health(for: $1) }
            .prefix(3)
            .map { "\(NSLocalizedString($0.titleKey, comment: "")): \(Int(health(for: $0) * 100))%" }

        return top.joined(separator: ", ")
    }

    private func averageHealth(for components: [DamageComponent]) -> Float {
        guard !components.isEmpty else { return 1.0 }
        let sum = components.reduce(0.0) { partial, item in
            partial + health(for: item)
        }
        return sum / Float(components.count)
    }
}

struct ThermalState {
    var temperatureByComponent: [DamageComponent: Float]

    init(temperatureByComponent: [DamageComponent: Float] = [:]) {
        self.temperatureByComponent = temperatureByComponent
        for component in DamageComponent.allCases where self.temperatureByComponent[component] == nil {
            self.temperatureByComponent[component] = 33.0
        }
    }

    static let nominal = ThermalState()

    func temperature(for component: DamageComponent) -> Float {
        temperatureByComponent[component] ?? 33.0
    }

    var normalizedLoad: Float {
        let maxTemp = DamageComponent.allCases.map { temperature(for: $0) }.max() ?? 33.0
        return ((maxTemp - 30.0) / 60.0).clamped(to: 0.0...1.0)
    }

    var summary: String {
        let battery = Int(temperature(for: .battery))
        let fc = Int(temperature(for: .flightControllerCore))
        return "BAT:\(battery)C FC:\(fc)C"
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
