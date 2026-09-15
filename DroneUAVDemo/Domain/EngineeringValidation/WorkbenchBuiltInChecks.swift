import Foundation

/// The checks the Workbench could already make before this subsystem, as test records.
///
/// All three are `.fallback` — none is the calculation its test stands for:
///   - geometry and assembly: catalogue compatibility rules, not clearance or intersection;
///   - mass properties: a sum of catalogue point masses and their centre, no inertia tensor;
///   - propulsion bench: the motors' datasheet thrust, power and KV, not a bench model.
/// Readiness treats fallback results accordingly: they can block (a FAIL is a FAIL), they
/// cannot make a configuration «Допущен» or even «проверен».
///
/// Records are rebuilt from the blueprint on every evaluation and never stored: they are pure
/// functions of the build, so they cannot go stale. What downstream results (a stored strength
/// record) consumed is their output fingerprint, so a changed mass still outdates those.
enum WorkbenchBuiltInChecks {
    static let solverID = "uavsim.workbench.builtin"
    static let solverVersion = "1"

    /// Metric carrying the total mass of one kind of mounted part (all its units), read by strength
    /// load cases that put that equipment's weight on a face.
    static func componentMassKey(_ kind: WorkbenchComponentKind) -> String {
        "componentMassKg." + kind.rawValue
    }

    /// How many units of a part the build carries: one per motor mount for motors and propellers, one
    /// per control-surface station for servos, one otherwise.
    static func componentUnits(_ kind: WorkbenchComponentKind, build: WorkbenchBuild) -> Int {
        let frame = build.resolvedFrame
        switch kind {
        case .motor, .propeller: return max(frame.motorMounts.count, 1)
        case .servo where !frame.servoMounts.isEmpty:
            guard let spec = build.spec(for: .servo) else { return 1 }
            return max(WorkbenchBuildAnalyzer.resolvedServoPositions(frame: frame, spec: spec).count, 1)
        default: return 1
        }
    }

    static func records(
        for build: WorkbenchBuild,
        snapshot: EngineeringConfigurationSnapshot
    ) -> [EngineeringTestRecord] {
        let stats = WorkbenchBuildAnalyzer.analyze(build)
        let frame = build.resolvedFrame
        var records: [EngineeringTestRecord] = []
        func stamp(
            _ type: EngineeringTestType,
            outcome: EngineeringTestOutcome,
            metrics: [String: EngineeringMetric],
            warnings: [String] = [],
            failures: [String] = []
        ) {
            let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
            records.append(EngineeringValidationEngine.makeRecord(
                type, snapshot: snapshot, state: state, outcome: outcome, metrics: metrics,
                source: .fallback, solverID: solverID, solverVersion: solverVersion,
                warnings: warnings, failureReasons: failures,
                // Older than anything a solver writes: a computed record of the same test wins.
                createdAt: .distantPast))
        }

        // Geometry and assembly: compatibility rules of the parts with the frame. RF issues are
        // left out — the radio link is outside every engineering input category.
        let issues = WorkbenchCompatibility.check(build)
        let errors = issues.filter { $0.severity == .error }.map(\.message)
        let cautions = issues.filter { $0.severity == .warning }.map(\.message)
        stamp(.geometryAssembly,
              outcome: errors.isEmpty ? (cautions.isEmpty ? .pass : .warning) : .fail,
              metrics: [
                  "compatibilityErrors": EngineeringMetric(Double(errors.count), unit: "1"),
                  "compatibilityWarnings": EngineeringMetric(Double(cautions.count), unit: "1"),
              ],
              warnings: cautions + ["Проверена совместимость деталей; зазоры и пересечения не проверялись"],
              failures: errors)

        // Mass properties. The centre of mass is in Workbench model space (+Z forward, +Y up).
        var massWarnings = ["Тензор инерции не рассчитан: точечные массы из каталога"]
        if WorkbenchBuildAnalyzer.isCenterOfMassOutsideSafeArea(stats.centerOfMass, frame: frame) {
            massWarnings.insert("Центр масс смещён за безопасную область рамы", at: 0)
        }
        var massMetrics: [String: EngineeringMetric] = [
            "massKg": EngineeringMetric(stats.totalMassKg, unit: "kg"),
            "centerOfMassX": EngineeringMetric(stats.centerOfMass.x, unit: "m"),
            "centerOfMassY": EngineeringMetric(stats.centerOfMass.y, unit: "m"),
            "centerOfMassZ": EngineeringMetric(stats.centerOfMass.z, unit: "m"),
        ]
        // Per kind of mounted part, units counted as the analyzer counts them.
        for kind in WorkbenchBuild.slotKinds {
            guard let spec = build.spec(for: kind) else { continue }
            massMetrics[componentMassKey(kind)] = EngineeringMetric(spec.massKg * Double(componentUnits(kind, build: build)), unit: "kg")
        }
        stamp(.massProperties,
              outcome: massWarnings.count > 1 ? .warning : .pass,
              metrics: massMetrics,
              warnings: massWarnings)

        // Propulsion bench: only what the bench's own inputs determine. Thrust-to-weight needs the
        // mass, which the bench does not read — recorded here it would change with the payload
        // without this record ever becoming outdated.
        let p = WorkbenchComponentSpec.ParamKey.self
        if let motor = build.spec(for: .motor), build.spec(for: .propeller) != nil {
            let units = Double(max(frame.motorMounts.count, 1))
            let thrust = (motor.param(p.motorMaxThrustN) ?? 0) * units
            let power = (motor.param(p.motorMaxPowerW) ?? 0) * units
            var metrics: [String: EngineeringMetric] = [
                "maxThrustN": EngineeringMetric(thrust, unit: "N"),
                "maxElectricalPowerW": EngineeringMetric(power, unit: "W"),
            ]
            if stats.maxRPM > 0 { metrics["maxRPM"] = EngineeringMetric(stats.maxRPM, unit: "rpm") }
            if let blades = build.spec(for: .propeller)?.param(p.propBladeCount), blades >= 1 {
                metrics["bladeCount"] = EngineeringMetric(blades, unit: "1")
            }
            metrics["units"] = EngineeringMetric(units, unit: "1")
            var missing: [String] = []
            if thrust <= 0 { missing.append("нет паспортной тяги мотора") }
            if power <= 0 { missing.append("нет паспортной мощности мотора") }
            if stats.maxRPM <= 0 { missing.append("обороты не определены: нет KV или АКБ") }
            stamp(.propulsionBench,
                  outcome: missing.isEmpty ? .pass : .warning,
                  metrics: metrics,
                  warnings: missing + ["Паспортные данные мотора, не стендовая модель винта"])
        }
        return records
    }
}
