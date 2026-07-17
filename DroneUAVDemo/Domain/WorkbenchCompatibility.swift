import Foundation

/// Mechanical and electrical compatibility checks. Errors prevent a flight
/// test; warnings are shown immediately but leave experimentation possible.
enum WorkbenchCompatibility {
    struct Issue: Hashable, Identifiable {
        enum Severity: String { case error, warning }

        var id: String { severity.rawValue + message }
        var severity: Severity
        var message: String
    }

    static func check(_ build: WorkbenchBuild) -> [Issue] {
        var issues: [Issue] = []
        let frame = build.resolvedFrame
        let p = WorkbenchComponentSpec.ParamKey.self

        if frame.motorMounts.count < 3 {
            issues.append(.init(severity: .error,
                                message: "Для мультиротора требуется минимум три моторных крепления."))
        }
        if build.spec(for: .motor) == nil {
            issues.append(.init(severity: .error, message: "Не выбраны двигатели."))
        }
        if build.spec(for: .propeller) == nil {
            issues.append(.init(severity: .error, message: "Не выбраны пропеллеры."))
        }
        if build.spec(for: .battery) == nil {
            issues.append(.init(severity: .error, message: "Не выбран аккумулятор."))
        }
        if build.spec(for: .esc) == nil {
            issues.append(.init(severity: .error, message: "Не выбран регулятор ESC."))
        }
        if build.spec(for: .flightController) == nil {
            issues.append(.init(severity: .warning, message: "Не выбран полётный контроллер."))
        }
        if build.spec(for: .receiver) == nil {
            issues.append(.init(severity: .warning, message: "Нет приёмника управления."))
        }

        let propDiameter = build.spec(for: .propeller)?.param(p.propDiameterInch)
        if let diameter = propDiameter {
            if diameter > frame.propMaxInch + 0.05 {
                issues.append(.init(
                    severity: .error,
                    message: String(format: "Пропеллер %.1f\" пересекает раму (допустимо до %.1f\").",
                                    diameter, frame.propMaxInch)))
            } else if diameter < max(1.0, frame.propMaxInch - 2.5) {
                issues.append(.init(
                    severity: .warning,
                    message: String(format: "Пропеллер %.1f\" мал для этой рамы (она рассчитана до %.1f\").",
                                    diameter, frame.propMaxInch)))
            }
        }

        if let motor = build.spec(for: .motor) {
            if let stator = motor.param(p.motorStatorMm),
               stator > frame.motorStatorMaxMm + 0.5 {
                issues.append(.init(
                    severity: .error,
                    message: String(format: "Статор %.0f мм не помещается на моторной площадке (до %.0f мм).",
                                    stator, frame.motorStatorMaxMm)))
            }
            if let diameter = propDiameter,
               let minimum = motor.param(p.motorPropMinInch), diameter < minimum - 0.05 {
                issues.append(.init(
                    severity: .warning,
                    message: String(format: "Для этого мотора рекомендуется пропеллер не меньше %.1f\".", minimum)))
            }
            if let diameter = propDiameter,
               let maximum = motor.param(p.motorPropMaxInch), diameter > maximum + 0.05 {
                issues.append(.init(
                    severity: .error,
                    message: String(format: "Мотор не рассчитан на пропеллеры больше %.1f\".", maximum)))
            }
        }

        if let battery = build.spec(for: .battery),
           let cells = battery.param(p.batteryCells) {
            if let motor = build.spec(for: .motor) {
                let minimum = motor.param(p.motorMinCells) ?? 1
                let maximum = motor.param(p.motorMaxCells) ?? 12
                if cells < minimum || cells > maximum {
                    issues.append(.init(
                        severity: .error,
                        message: String(format: "Двигатель рассчитан на %.0f–%.0fS, выбран аккумулятор %.0fS.",
                                        minimum, maximum, cells)))
                }
            }
            if let esc = build.spec(for: .esc),
               let maxCells = esc.param(p.escMaxCells), cells > maxCells {
                issues.append(.init(
                    severity: .error,
                    message: String(format: "ESC поддерживает до %.0fS, выбран аккумулятор %.0fS.",
                                    maxCells, cells)))
            }

            let recommended: ClosedRange<Double>
            switch frame.frameClass {
            case .tinyWhoop: recommended = 1...2
            case .fiveInch: recommended = 4...6
            case .sevenInch: recommended = 4...6
            case .cinematic: recommended = 4...8
            }
            if !recommended.contains(cells) {
                issues.append(.init(
                    severity: .warning,
                    message: String(format: "%.0fS нетипична для этой рамы (обычно %.0f–%.0fS).",
                                    cells, recommended.lowerBound, recommended.upperBound)))
            }

            checkCurrentBudget(build, battery: battery, cells: cells, issues: &issues)
        }

        return issues
    }

    private static func checkCurrentBudget(
        _ build: WorkbenchBuild,
        battery: WorkbenchComponentSpec,
        cells: Double,
        issues: inout [Issue]
    ) {
        let p = WorkbenchComponentSpec.ParamKey.self
        guard let motor = build.spec(for: .motor),
              let motorPower = motor.param(p.motorMaxPowerW) else { return }
        let voltage = cells * 3.7
        let motorCurrent = motorPower / max(voltage, 1)

        if let esc = build.spec(for: .esc),
           let escCurrent = esc.param(p.escMaxCurrentA),
           motorCurrent > escCurrent * 1.08 {
            issues.append(.init(
                severity: .error,
                message: String(format: "Расчётный ток мотора %.0f A превышает предел ESC %.0f A.",
                                motorCurrent, escCurrent)))
        }

        if let capacity = battery.param(p.batteryCapacityMah),
           let cRating = battery.param(p.batteryContinuousC) {
            let available = capacity / 1000 * cRating
            let demanded = motorCurrent * Double(max(build.resolvedFrame.motorMounts.count, 1)) * 0.72
            if demanded > available * 1.08 {
                issues.append(.init(
                    severity: .warning,
                    message: String(format: "АКБ отдаёт около %.0f A, сборке требуется до %.0f A.",
                                    available, demanded)))
            }
        }
    }
}
