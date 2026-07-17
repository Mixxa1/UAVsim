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

        switch frame.architecture {
        case .multicopter:
            if frame.motorMounts.count < 3 {
                issues.append(.init(
                    severity: .error,
                    message: "Для мультиротора требуется минимум три моторных крепления."))
            }
        case .fixedWing:
            if frame.motorMounts.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Для самолёта требуется маршевое моторное крепление."))
            }
            if build.spec(for: .servo) == nil {
                issues.append(.init(
                    severity: .error,
                    message: "Для самолёта нужны сервоприводы рулевых поверхностей."))
            }
            if frame.servoMounts.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "На самолётной раме не заданы точки крепления рулевых сервоприводов."))
            }
            if frame.wingAreaM2 <= 0 {
                issues.append(.init(
                    severity: .error,
                    message: "Для самолёта не задана несущая площадь крыла."))
            }
            if frame.propulsionAxes.contains(where: { abs($0.z) < 0.65 }) {
                issues.append(.init(
                    severity: .error,
                    message: "Маршевые двигатели самолёта должны быть ориентированы вдоль фюзеляжа."))
            }
        case .liftCruiseVTOL:
            if frame.liftMotorCount < 3 {
                issues.append(.init(
                    severity: .error,
                    message: "VTOL требует минимум три подъёмных двигателя."))
            }
            if frame.motorMounts.count <= frame.liftMotorCount {
                issues.append(.init(
                    severity: .error,
                    message: "VTOL требует отдельный маршевый двигатель для крейсерского полёта."))
            }
            if build.spec(for: .servo) == nil {
                issues.append(.init(
                    severity: .error,
                    message: "Для VTOL нужны сервоприводы рулевых поверхностей."))
            }
            if frame.servoMounts.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "На VTOL-раме не заданы точки крепления рулевых сервоприводов."))
            }
            if frame.wingAreaM2 <= 0 {
                issues.append(.init(
                    severity: .error,
                    message: "Для Lift+Cruise VTOL не задана несущая площадь крыла."))
            }
            let liftAxes = frame.propulsionAxes.prefix(frame.liftMotorCount)
            if liftAxes.contains(where: { $0.y < 0.65 }) {
                issues.append(.init(
                    severity: .error,
                    message: "Подъёмные двигатели VTOL должны быть ориентированы вверх."))
            }
            let cruiseAxes = frame.propulsionAxes.dropFirst(frame.liftMotorCount)
            if cruiseAxes.contains(where: { abs($0.z) < 0.65 }) {
                issues.append(.init(
                    severity: .error,
                    message: "Маршевый двигатель VTOL должен быть ориентирован вдоль фюзеляжа."))
            }
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

        // Placement guardrails are repeated here for imported and older
        // Blueprints. The layout resolver safely normalises these values, and
        // the warning explains why the rendered position differs from the
        // stored legacy intent.
        if build.spec(for: .gps) != nil {
            let surface = build.placement(for: .gps).surface
            if surface != .automatic && surface != .top {
                issues.append(.init(
                    severity: .warning,
                    message: "GNSS перенесён в верхнюю чистую зону: снизу и рядом с силовой проводкой спутниковый приём ненадёжен."))
            }
        }
        if frame.architecture != .multicopter,
           build.spec(for: .battery) != nil {
            let surface = build.placement(for: .battery).surface
            if surface != .automatic && surface != .internalBay {
                issues.append(.init(
                    severity: .warning,
                    message: "АКБ самолётного аппарата перенесён во внутренний CG-отсек под сервисным люком."))
            }
        }
        for kind in [WorkbenchComponentKind.receiver, .flightController, .esc] {
            guard build.spec(for: kind) != nil else { continue }
            let surface = build.placement(for: kind).surface
            if surface != .automatic && surface != .internalBay {
                issues.append(.init(
                    severity: .warning,
                    message: "\(kind.displayName) перенесён в защищённый внутренний отсек с реальным креплением."))
            }
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

        if let motor = build.spec(for: .motor) {
            let singleThrust = motor.param(p.motorMaxThrustN) ?? 0
            let aircraftWeight = estimatedInstalledMass(build, frame: frame) * 9.80665
            switch frame.architecture {
            case .fixedWing:
                let cruiseThrust = singleThrust * Double(frame.motorMounts.count)
                if cruiseThrust < max(aircraftWeight * 0.28, 0.8) {
                    issues.append(.init(
                        severity: .error,
                        message: "Маршевой тяги недостаточно для устойчивого самолётного полёта."))
                }
            case .liftCruiseVTOL:
                let liftThrust = singleThrust * Double(frame.liftMotorCount)
                let cruiseMotorCount = max(frame.motorMounts.count - frame.liftMotorCount, 0)
                let cruiseThrust = singleThrust * Double(cruiseMotorCount)
                let liftRatio = aircraftWeight > 0 ? liftThrust / aircraftWeight : 0
                if liftRatio < 1.0 {
                    issues.append(.init(
                        severity: .error,
                        message: String(
                            format: "Подъёмной тяги VTOL недостаточно для взлёта (%.2f к весу).",
                            liftRatio)))
                } else if liftRatio < 1.55 {
                    issues.append(.init(
                        severity: .warning,
                        message: String(
                            format: "Малый запас подъёмной тяги VTOL: %.2f к весу.",
                            liftRatio)))
                }
                if cruiseThrust < max(aircraftWeight * 0.18, 0.8) {
                    issues.append(.init(
                        severity: .error,
                        message: "Маршевой тяги VTOL недостаточно для крейсерского полёта."))
                }
            case .multicopter:
                break
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
            if let esc = build.spec(for: .esc) {
                let minCells = esc.param(p.escMinCells) ?? 1
                let maxCells = esc.param(p.escMaxCells) ?? 12
                if cells < minCells || cells > maxCells {
                    issues.append(.init(
                        severity: .error,
                        message: String(format: "ESC рассчитан на %.0f–%.0fS, выбран аккумулятор %.0fS.",
                                        minCells, maxCells, cells)))
                }
            }

            let recommended: ClosedRange<Double>
            switch frame.propMaxInch {
            case ...2.0: recommended = 1...2
            case ...3.0: recommended = 2...4
            case ...4.0: recommended = 3...4
            case ...8.5: recommended = 4...6
            default: recommended = 6...12
            }
            if !recommended.contains(cells) {
                issues.append(.init(
                    severity: .warning,
                    message: String(format: "%.0fS нетипична для этой рамы (обычно %.0f–%.0fS).",
                                    cells, recommended.lowerBound, recommended.upperBound)))
            }

            checkCurrentBudget(build, battery: battery, cells: cells, issues: &issues)

            let packLengthMm = battery.param(p.batteryLengthMm)
                ?? battery.proxy.size.x * 1000
            let trayLengthMm = batteryTrayLengthLimitMeters(frame) * 1000
            if packLengthMm > trayLengthMm * 1.20 {
                issues.append(.init(
                    severity: .error,
                    message: String(format: "АКБ длиной %.0f мм не помещается на площадке рамы (до %.0f мм).",
                                    packLengthMm, trayLengthMm)))
            } else if packLengthMm > trayLengthMm {
                issues.append(.init(
                    severity: .warning,
                    message: String(format: "АКБ %.0f мм будет заметно выступать за площадку %.0f мм.",
                                    packLengthMm, trayLengthMm)))
            }
        }

        let boardLimit = avionicsBoardLimitMm(frame)
        if let flightController = build.spec(for: .flightController),
           let mount = flightController.param(p.flightControllerMountMm),
           mount > boardLimit + 0.1 {
            issues.append(.init(
                severity: .error,
                message: String(format: "Монтаж FC %.1f мм не помещается в отсек рамы (до %.1f мм).",
                                mount, boardLimit)))
        }
        if let esc = build.spec(for: .esc) {
            let boardSizeMm = max(esc.proxy.size.x, esc.proxy.size.z) * 1000
            if boardSizeMm > boardLimit + 4 {
                issues.append(.init(
                    severity: .error,
                    message: String(format: "Плата ESC %.0f мм шире отсека рамы (до %.0f мм).",
                                boardSizeMm, boardLimit + 4)))
            }
            if let channelCapacity = escChannelCapacity(esc),
               channelCapacity < frame.motorMounts.count {
                issues.append(.init(
                    severity: .error,
                    message: "ESC имеет \(channelCapacity) канал(а), а силовая установка требует \(frame.motorMounts.count)."))
            }
        }

        return issues
    }

    private static func batteryTrayLengthLimitMeters(_ frame: WorkbenchResolvedFrame) -> Double {
        let factor: Double
        switch frame.propMaxInch {
        case ...2.0: factor = 1.55
        case ...3.0: factor = 1.35
        case ...4.0: factor = 1.18
        case ...6.2: factor = 1.05
        case ...8.5: factor = 0.95
        default: factor = 0.78
        }
        return frame.armLengthM * factor
    }

    /// Mirrors the Workbench mass model without calling the analyzer (which
    /// itself consumes compatibility issues). Repeated motors, propellers and
    /// wing servos must all contribute to the thrust requirements above.
    private static func estimatedInstalledMass(
        _ build: WorkbenchBuild,
        frame: WorkbenchResolvedFrame
    ) -> Double {
        var mass = max(frame.massKg, 0)
        let propulsionCount = frame.motorMounts.count
        if let motor = build.spec(for: .motor) {
            mass += motor.massKg * Double(propulsionCount)
        }
        if let propeller = build.spec(for: .propeller) {
            mass += propeller.massKg * Double(propulsionCount)
        }
        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard let spec = build.spec(for: kind) else { continue }
            let count = kind == .servo && !frame.servoMounts.isEmpty
                ? frame.servoMounts.count
                : 1
            mass += spec.massKg * Double(count)
        }
        return mass
    }

    private static func avionicsBoardLimitMm(_ frame: WorkbenchResolvedFrame) -> Double {
        switch frame.propMaxInch {
        case ...2.0: return 25.5
        case ...3.0: return 30.5
        case ...4.0: return 36
        case ...6.2: return 45
        case ...8.5: return 55
        default: return 90
        }
    }

    private static func escChannelCapacity(_ esc: WorkbenchComponentSpec) -> Int? {
        let identity = "\(esc.id) \(esc.displayName)".lowercased()
        if identity.contains("5x") || identity.contains("5×") { return 5 }
        if identity.contains("4in1") || identity.contains("4-в-1")
            || identity.contains("4x") || identity.contains("4×") {
            return 4
        }
        if identity.contains("wing esc") || identity.contains("одноосевой") { return 1 }
        return nil
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
