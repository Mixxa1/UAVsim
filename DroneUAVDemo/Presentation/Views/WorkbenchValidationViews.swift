import SwiftUI

// Engineering validation in the Workbench (spec §4, §11): the readiness of the build and, per
// test, what it concluded, where the numbers came from and — when it no longer holds — why.
//
// Honesty rules shared with the CADNext report and window:
//   - a number is shown with its numerical uncertainty, or says there is none, never bare;
//   - an estimate is labelled as one and never reads as a calculation;
//   - an outdated result names what changed instead of a grey badge.

enum WorkbenchValidationText {
    static func status(_ status: EngineeringTestStatus) -> String {
        switch status {
        case .pass: return "PASS"
        case .warning: return "WARNING"
        case .fail: return "FAIL"
        case .error: return "ERROR"
        case .outdated: return "УСТАРЕЛ"
        case .notRun: return "НЕ ВЫПОЛНЯЛОСЬ"
        case .running: return "ИДЁТ"
        }
    }

    static func color(_ status: EngineeringTestStatus) -> Color {
        switch status {
        case .pass: return GroundControlPalette.success
        case .warning: return GroundControlPalette.warning
        case .fail: return GroundControlPalette.danger
        case .outdated: return Color(red: 0.62, green: 0.58, blue: 0.40)
        case .error, .notRun, .running: return Color.white.opacity(0.35)
        }
    }

    static func color(_ readiness: EngineeringReadiness) -> Color {
        switch readiness {
        case .ready: return GroundControlPalette.success
        case .conditional: return GroundControlPalette.warning
        case .notReady, .inspectionRequired: return GroundControlPalette.danger
        case .notValidated: return Color.white.opacity(0.45)
        }
    }

    static func explanation(_ readiness: EngineeringReadiness) -> String {
        switch readiness {
        case .ready:
            return "Все обязательные испытания пройдены по расчёту."
        case .conditional:
            return "Среди обязательных испытаний есть предупреждения, устаревшие, невыполненные или держащиеся только на оценке."
        case .notReady:
            return "Обязательное испытание не пройдено."
        case .notValidated:
            return "Ни одно обязательное испытание не рассчитано. Оценки Мастерской показаны ниже, но проверкой не считаются."
        case .inspectionRequired:
            return "После удара или жёсткой посадки нужен осмотр."
        }
    }

    static func source(_ source: EngineeringResultSource) -> String {
        switch source {
        case .fallback: return "оценка Мастерской"
        case .computed: return "расчёт"
        case .factory: return "заводской профиль"
        case .imported: return "импорт"
        }
    }

    /// What it takes to run a test that has no result yet — so «не выполнялось» is not a dead end.
    static func availability(_ type: EngineeringTestType) -> String {
        switch type {
        case .structuralStatic:
            return "Считается в Мастерской по точной геометрии рамы: варианты нагрузок задаются в панели «Прочность по точной геометрии»."
        case .modalVibration:
            return "Решатель есть в CADNext («Анализ → Прочность и частоты детали»); запуск из Мастерской в разработке."
        case .aerodynamics:
            return "CFD в разработке."
        case .geometryAssembly, .massProperties, .propulsionBench:
            return "Нужны рама и детали силовой установки."
        case .mechanism, .thermalLimits, .controlAuthority, .systemEndurance:
            return "Решатель ещё не реализован."
        }
    }

    static func metricName(_ key: String) -> String {
        if key.hasPrefix("componentMassKg."), let kind = WorkbenchComponentKind(rawValue: String(key.dropFirst("componentMassKg.".count))) {
            return "Масса: " + kind.displayName.lowercased()
        }
        return [
            "compatibilityErrors": "Ошибок совместимости",
            "compatibilityWarnings": "Предупреждений совместимости",
            "massKg": "Масса",
            "centerOfMassX": "ЦТ, X",
            "centerOfMassY": "ЦТ, Y",
            "centerOfMassZ": "ЦТ, Z (вперёд)",
            "maxThrustN": "Макс. тяга",
            "maxElectricalPowerW": "Макс. мощность",
            "maxRPM": "Макс. обороты",
            "maxVonMisesPa": "Макс. σ Мизеса",
            "maxDisplacementM": "Макс. перемещение",
            "reserveFactor": "Коэффициент запаса",
            "ultimateMargin": "Запас по разрушению",
            "yieldMargin": "Запас по текучести",
            "firstFrequencyHz": "Первая частота",
            "minimumBandSeparation": "Мин. отстройка от полос",
            "checkedBodies": "Проверено деталей",
            "totalBodies": "Деталей в раме",
        ][key] ?? key
    }

    /// Metrics in the order an engineer reads them: the verdict-carrying number first.
    static func orderedMetricKeys(_ metrics: [String: EngineeringMetric]) -> [String] {
        let priority = [
            "reserveFactor", "maxVonMisesPa", "firstFrequencyHz", "minimumBandSeparation",
            "massKg", "maxThrustN", "maxElectricalPowerW", "maxRPM",
            "compatibilityErrors", "compatibilityWarnings",
            "centerOfMassX", "centerOfMassY", "centerOfMassZ",
            "maxDisplacementM", "yieldMargin", "ultimateMargin",
        ]
        return metrics.keys.sorted { a, b in
            let ia = priority.firstIndex(of: a) ?? priority.count
            let ib = priority.firstIndex(of: b) ?? priority.count
            return ia == ib ? a < b : ia < ib
        }
    }

    static func value(_ metric: EngineeringMetric) -> String {
        format(metric.value, unit: metric.unit)
    }

    static func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "kg": return value < 1 ? String(format: "%.0f г", value * 1000) : String(format: "%.3f кг", value)
        case "m": return String(format: "%.1f мм", value * 1000)
        case "N": return String(format: "%.1f Н", value)
        case "W": return String(format: "%.0f Вт", value)
        case "rpm": return String(format: "%.0f об/мин", value)
        case "Pa": return String(format: "%.2f МПа", value / 1e6)
        case "Hz": return String(format: "%.2f Гц", value)
        case "1": return value == value.rounded() && abs(value) < 1e6 ? String(format: "%.0f", value) : String(format: "%.3f", value)
        default: return String(format: "%.4g %@", value, unit)
        }
    }

    static func uncertainty(_ metric: EngineeringMetric, source: EngineeringResultSource) -> String {
        if let band = metric.numericalUncertainty { return "± " + format(band, unit: metric.unit) }
        return source == .fallback ? "оценка, без погрешности" : "погрешность не оценена"
    }
}

struct WorkbenchReadinessChip: View {
    let state: EngineeringValidationState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 11, weight: .bold))
            Text(state.readiness.displayName)
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .foregroundStyle(WorkbenchValidationText.color(state.readiness))
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkbenchValidationText.color(state.readiness).opacity(0.6)))
    }
}

struct WorkbenchValidationShelf: View {
    let state: EngineeringValidationState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            WorkbenchValidationCards(state: state)
        }
    }
}

/// One card per applicable test, in dependency order.
struct WorkbenchValidationCards: View {
    let state: EngineeringValidationState

    var body: some View {
        HStack(spacing: 10) {
            ForEach(state.evaluations, id: \.type) { evaluation in
                card(evaluation)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func card(_ evaluation: EngineeringTestEvaluation) -> some View {
        let color = WorkbenchValidationText.color(evaluation.status)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(WorkbenchValidationText.status(evaluation.status))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                if evaluation.isRequiredForReadiness {
                    Text("обяз.")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            Text(evaluation.type.displayName)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let record = evaluation.record {
                Text(WorkbenchValidationText.source(record.source))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(record.source == .fallback ? GroundControlPalette.warning : GroundControlPalette.accent)
                ForEach(WorkbenchValidationText.orderedMetricKeys(record.metrics).prefix(2), id: \.self) { key in
                    if let metric = record.metrics[key] {
                        HStack {
                            Text(WorkbenchValidationText.metricName(key))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                            Spacer(minLength: 4)
                            Text(WorkbenchValidationText.value(metric))
                        }
                        .font(.system(size: 9))
                        .lineLimit(1)
                    }
                }
            } else {
                Text(WorkbenchValidationText.availability(evaluation.type))
                    .font(.system(size: 9))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 190, height: 150, alignment: .topLeading)
        .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 9))
        // An estimate keeps its status colour in the text but not in the frame: a green-framed card
        // reads as a validated result at a glance.
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
            evaluation.record?.source == .fallback ? GroundControlPalette.borderStrong
                : color.opacity(evaluation.status == .notRun ? 0.2 : 0.55)))
    }
}

struct WorkbenchValidationInspector: View {
    let state: EngineeringValidationState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            ForEach(state.evaluations, id: \.type) { evaluation in
                detail(evaluation)
            }
            Text("Статус выводится заново при каждом изменении сборки: результат не хранит «устарел», устаревание — это сравнение того, что расчёт прочитал, с тем, что есть сейчас.")
                .font(.system(size: 9))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        section {
            HStack(spacing: 8) {
                Circle().fill(WorkbenchValidationText.color(state.readiness)).frame(width: 9, height: 9)
                Text(state.readiness.displayName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            Text(WorkbenchValidationText.explanation(state.readiness))
                .font(.system(size: 10))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let counts: [(String, Int)] = [
                ("PASS", state.count(.pass)), ("WARNING", state.count(.warning)), ("FAIL", state.count(.fail)),
                ("устарело", state.count(.outdated)), ("не выполнено", state.count(.notRun)),
            ]
            Text(counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
    }

    private func detail(_ evaluation: EngineeringTestEvaluation) -> some View {
        let color = WorkbenchValidationText.color(evaluation.status)
        return section {
            HStack(alignment: .firstTextBaseline) {
                Text(evaluation.type.displayName)
                    .font(.system(size: 12, weight: .bold))
                Spacer(minLength: 6)
                Text(WorkbenchValidationText.status(evaluation.status))
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .foregroundStyle(color)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.7)))
            }
            Text(evaluation.isRequiredForReadiness ? "Обязательное для допуска" : "Не входит в минимальный набор допуска")
                .font(.system(size: 9))
                .foregroundStyle(GroundControlPalette.textSecondary)

            if let record = evaluation.record {
                Text("Источник: \(WorkbenchValidationText.source(record.source)) · \(record.solverID) (\(record.solverVersion))")
                    .font(.system(size: 9))
                    .foregroundStyle(record.source == .fallback ? GroundControlPalette.warning : GroundControlPalette.textSecondary)
                ForEach(WorkbenchValidationText.orderedMetricKeys(record.metrics), id: \.self) { key in
                    if let metric = record.metrics[key] {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(WorkbenchValidationText.metricName(key))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(WorkbenchValidationText.value(metric)).fontWeight(.semibold)
                                Text(WorkbenchValidationText.uncertainty(metric, source: record.source))
                                    .font(.system(size: 8))
                                    .foregroundStyle(GroundControlPalette.textSecondary)
                            }
                        }
                        .font(.system(size: 10))
                    }
                }
                ForEach(evaluation.reasons, id: \.self) { reason in
                    line(reason.displayText, icon: "clock.arrow.circlepath", color: WorkbenchValidationText.color(.outdated))
                }
                ForEach(record.failureReasons, id: \.self) { line($0, icon: "xmark.octagon.fill", color: GroundControlPalette.danger) }
                ForEach(record.warnings, id: \.self) { line($0, icon: "exclamationmark.triangle.fill", color: GroundControlPalette.warning) }
            } else {
                Text(WorkbenchValidationText.availability(evaluation.type))
                    .font(.system(size: 10))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 9)).padding(.top, 1)
            Text(text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }
}
