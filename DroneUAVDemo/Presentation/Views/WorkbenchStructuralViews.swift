import AppKit
import SwiftUI

// Strength load cases in the Workbench: authored on the frame's exact solids, faces picked on the 3D
// model, calculated by cadnext_structural, results kept per run.
//
// Nothing here has a silent default that decides a result: no element size, no load factor for
// equipment weight, no support. The panel says what is still missing instead.

struct WorkbenchStructuralPanel: View {
    @ObservedObject var viewModel: WorkbenchViewModel

    @State private var manualForce: [Double?] = [nil, nil, nil]
    @State private var pressureKPa: Double?
    @State private var exclusionMM: Double?
    @State private var equipmentFactorG: Double?
    @State private var equipmentCount: Double?
    @State private var bandName = ""
    @State private var bandMinimum: Double?
    @State private var bandMaximum: Double?

    private let raised = GroundControlPalette.panelRaised
    private let inset = GroundControlPalette.inset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ПРОЧНОСТЬ ПО ТОЧНОЙ ГЕОМЕТРИИ", systemImage: "cube.transparent")
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            if viewModel.exactBodies.isEmpty {
                note("У рамы нет точной геометрии. В CADNext: «Файл → Экспорт в Мастерскую (.uavframe)», затем импортируйте файл как раму.")
            } else {
                toolRow
                bodiesList
                if let pick = viewModel.facePick {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill").foregroundStyle(GroundControlPalette.accent)
                        Text("Кликните грань на модели, чтобы назначить \(pick.displayName).")
                            .font(.system(size: 10, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Отмена") { viewModel.cancelFacePick() }.controlSize(.small)
                    }
                    .padding(8)
                    .background(GroundControlPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }
                let statuses = viewModel.structuralCaseStatuses()
                ForEach(statuses, id: \.loadCase.id) { status in
                    caseCard(status)
                }
            }
        }
        .padding(12)
        .background(raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: Header

    private var toolRow: some View {
        HStack(spacing: 6) {
            if let tool = viewModel.structuralTool {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(GroundControlPalette.success)
                Text("Решатель: \(tool.lastPathComponent)").help(tool.path)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GroundControlPalette.warning)
                Text("cadnext_structural не найден (нужна сборка CADNext с Netgen)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Указать…") { chooseTool() }.controlSize(.small)
        }
        .font(.system(size: 10))
    }

    private var bodiesList: some View {
        let statuses = viewModel.structuralCaseStatuses()
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(viewModel.exactBodies) { body in
                let current = statuses.contains { $0.loadCase.bodyID == body.id && $0.isCurrent }
                let any = statuses.contains { $0.loadCase.bodyID == body.id }
                HStack(spacing: 6) {
                    Image(systemName: current ? "checkmark.seal.fill" : (any ? "clock.arrow.circlepath" : "circle.dashed"))
                        .foregroundStyle(current ? GroundControlPalette.success : (any ? GroundControlPalette.warning : GroundControlPalette.textSecondary))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(body.name).font(.system(size: 11, weight: .semibold))
                        Text("\(body.materialId) · \(WorkbenchValidationText.format(body.massKg, unit: "kg"))")
                            .font(.system(size: 9))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        viewModel.addStructuralCase(bodyID: body.id)
                    } label: {
                        Label("Вариант", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Case

    private func caseCard(_ status: WorkbenchStructuralAggregate.CaseStatus) -> some View {
        let loadCase = status.loadCase
        let selected = viewModel.selectedStructuralCaseID == loadCase.id
        let running = viewModel.runningStructuralCaseID == loadCase.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Название", text: Binding(
                    get: { loadCase.name },
                    set: { value in viewModel.updateStructuralCase(loadCase.id, undoable: false) { $0.name = value } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                Spacer(minLength: 4)
                Button {
                    viewModel.selectedStructuralCaseID = selected ? nil : loadCase.id
                } label: {
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help(selected ? "Свернуть" : "Открыть и подсветить грани на модели")
            }
            resultLine(status, running: running)
            if selected {
                analysisPicker(loadCase)
                if case let .modal(modal) = loadCase.analysis {
                    modalItems(loadCase, modal: modal)
                    modalControls(loadCase, modal: modal)
                    meshFields(loadCase)
                } else {
                    itemsList(loadCase)
                    addControls(loadCase)
                    numbers(loadCase)
                }
                actions(status, running: running)
            }
        }
        .padding(10)
        .background(inset, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? GroundControlPalette.accent.opacity(0.7) : GroundControlPalette.border))
    }

    @ViewBuilder
    private func resultLine(_ status: WorkbenchStructuralAggregate.CaseStatus, running: Bool) -> some View {
        if running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(viewModel.structuralProgress ?? "Расчёт…").font(.system(size: 10))
                Spacer()
                Button("Отменить") { viewModel.cancelStructuralRun() }.controlSize(.small)
            }
        } else if let run = status.run {
            let record = run.record
            let color = WorkbenchValidationText.color(status.isCurrent ? statusOf(record.outcome) : .outdated)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(status.isCurrent ? record.outcome.rawValue.uppercased() : "УСТАРЕЛ")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(color)
                    if let reserve = record.metrics["reserveFactor"] {
                        Text("запас \(WorkbenchValidationText.value(reserve)) \(WorkbenchValidationText.uncertainty(reserve, source: record.source))")
                            .font(.system(size: 10))
                    }
                    Spacer(minLength: 0)
                }
                ForEach(status.staleReasons, id: \.self) { reason in
                    Text(reason).font(.system(size: 9)).foregroundStyle(WorkbenchValidationText.color(.outdated))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(record.failureReasons + record.warnings, id: \.self) { line in
                    Text("• " + line).font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("Не рассчитывался").font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
        }
    }

    private func itemsList(_ loadCase: WorkbenchStructuralCase) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(loadCase.supports.enumerated()), id: \.offset) { index, support in
                itemRow(support.fixed.count == 3 ? "Заделка · \(support.faceID)"
                        : "Опора \(support.fixed.map(\.rawValue).sorted().joined().uppercased()) · \(support.faceID)",
                        color: GroundControlPalette.accent) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.supports.remove(at: index) }
                }
            }
            ForEach(Array(loadCase.forces.enumerated()), id: \.offset) { index, force in
                itemRow(describe(force), color: GroundControlPalette.warning) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.forces.remove(at: index) }
                }
            }
            ForEach(Array(loadCase.pressures.enumerated()), id: \.offset) { index, pressure in
                itemRow(String(format: "Давление %.1f кПа · %@", pressure.pressurePa / 1000, pressure.faceID), color: .yellow) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.pressures.remove(at: index) }
                }
            }
            ForEach(Array(loadCase.exclusions.enumerated()), id: \.offset) { index, exclusion in
                itemRow(String(format: "Исключить ближе %.1f мм · %@", exclusion.distanceM * 1000, exclusion.faceID), color: .gray) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.exclusions.remove(at: index) }
                }
            }
            if loadCase.supports.isEmpty && loadCase.forces.isEmpty && loadCase.pressures.isEmpty {
                note("Опор и нагрузок пока нет.")
            }
        }
    }

    private func addControls(_ loadCase: WorkbenchStructuralCase) -> some View {
        let equipment = WorkbenchBuild.slotKinds.filter { viewModel.build.spec(for: $0) != nil && $0 != .motor && $0 != .propeller }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Заделка") { viewModel.beginFacePick(.support([.x, .y, .z]), for: loadCase.id) }
                Menu("По оси") {
                    ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                        Button(axis.displayName) { viewModel.beginFacePick(.support([axis]), for: loadCase.id) }
                    }
                }
                Menu("Тяга мотора") {
                    ForEach(directions, id: \.0) { name, vector in
                        Button("1 мотор, \(name)") {
                            viewModel.beginFacePick(.force(.motorThrust(motors: 1, direction: vector)), for: loadCase.id)
                        }
                    }
                }
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                numberField("n, g", value: $equipmentFactorG, width: 52)
                Menu("Вес оборудования ↓") {
                    ForEach(equipment, id: \.self) { kind in
                        Button(kind.displayName) {
                            guard let factor = equipmentFactorG else { return }
                            viewModel.beginFacePick(.force(.equipmentWeight(kinds: [kind], loadFactorG: factor,
                                                                            direction: CodableVector3D(x: 0, y: -1, z: 0))),
                                                    for: loadCase.id)
                        }
                    }
                }
                .disabled(equipmentFactorG == nil)
                .help(equipmentFactorG == nil ? "Сначала задайте перегрузку n: у веса оборудования нет перегрузки по умолчанию" : "Вес × n вниз (−Y модели) на выбранную грань")
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                numberField("Fx", value: $manualForce[0], width: 44)
                numberField("Fy", value: $manualForce[1], width: 44)
                numberField("Fz", value: $manualForce[2], width: 44)
                Button("Сила, Н") {
                    let force = CodableVector3D(x: manualForce[0] ?? 0, y: manualForce[1] ?? 0, z: manualForce[2] ?? 0)
                    viewModel.beginFacePick(.force(.manual(force)), for: loadCase.id)
                }
                .disabled(manualForce.allSatisfy { ($0 ?? 0) == 0 })
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                numberField("кПа", value: $pressureKPa, width: 52)
                Button("Давление") { if let value = pressureKPa { viewModel.beginFacePick(.pressure(value * 1000), for: loadCase.id) } }
                    .disabled((pressureKPa ?? 0) == 0)
                numberField("мм", value: $exclusionMM, width: 44)
                Button("Зона искл.") { if let value = exclusionMM { viewModel.beginFacePick(.exclusion(value / 1000), for: loadCase.id) } }
                    .disabled((exclusionMM ?? 0) <= 0)
            }
            .controlSize(.small)
            note("Оси модели: X — влево, Y — вверх, Z — вперёд. Тяга и вес читают стенд и массы: их изменение сделает результат устаревшим.")
        }
    }

    private func numbers(_ loadCase: WorkbenchStructuralCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Своя масса × n").font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 2)
                ForEach(0..<3, id: \.self) { component in
                    numberField(["nX", "nY", "nZ"][component], value: Binding(
                        get: { [loadCase.ownLoadFactorG.x, loadCase.ownLoadFactorG.y, loadCase.ownLoadFactorG.z][component] },
                        set: { value in
                            viewModel.updateStructuralCase(loadCase.id) { edited in
                                let old = edited.ownLoadFactorG
                                let v = value ?? 0
                                edited.ownLoadFactorG = CodableVector3D(x: component == 0 ? v : old.x,
                                                                        y: component == 1 ? v : old.y,
                                                                        z: component == 2 ? v : old.z)
                            }
                        }), width: 40)
                }
            }
            meshFields(loadCase)
        }
    }

    private func meshFields(_ loadCase: WorkbenchStructuralCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Сетка h, мм").font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 2)
                numberField("не задан", value: Binding(
                    get: { loadCase.coarseElementSizeM.map { $0 * 1000 } },
                    set: { value in viewModel.updateStructuralCase(loadCase.id) { $0.coarseElementSizeM = value.map { $0 / 1000 } } }),
                    width: 62)
                Button("Предложить") {
                    if let size = viewModel.suggestedElementSize(bodyID: loadCase.bodyID) {
                        viewModel.updateStructuralCase(loadCase.id) { $0.coarseElementSizeM = size }
                    }
                }
                .controlSize(.small)
                .help("1/10 габарита детали — отправная точка; достаточна ли сетка, покажет сходимость по трём уровням")
            }
            HStack(spacing: 4) {
                Text("Измельчение (≥ 1.3)").font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 2)
                numberField("", value: Binding(
                    get: { loadCase.refinementFactor },
                    set: { value in if let value { viewModel.updateStructuralCase(loadCase.id) { $0.refinementFactor = value } } }),
                    width: 50)
            }
        }
    }

    private func actions(_ status: WorkbenchStructuralAggregate.CaseStatus, running: Bool) -> some View {
        let problem = viewModel.structuralPrepareProblem(status.loadCase.id)
        return VStack(alignment: .leading, spacing: 5) {
            if let problem, !running {
                Text(problem).font(.system(size: 9)).foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button {
                    viewModel.runStructuralCase(status.loadCase.id)
                } label: {
                    Label("Рассчитать", systemImage: "play.fill")
                }
                .disabled(problem != nil || viewModel.runningStructuralCaseID != nil || viewModel.structuralTool == nil)
                if let run = status.run, let url = viewModel.structuralReportURL(for: run),
                   FileManager.default.fileExists(atPath: url.path) {
                    Button("Отчёт") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button(role: .destructive) {
                    viewModel.removeStructuralCase(status.loadCase.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Удалить вариант (результаты расчётов остаются в папке прогонов)")
            }
            .controlSize(.small)
        }
    }

    // MARK: Modal case

    private func analysisPicker(_ loadCase: WorkbenchStructuralCase) -> some View {
        Picker("", selection: Binding(
            get: { loadCase.testType == .modalVibration },
            set: { modal in
                viewModel.updateStructuralCase(loadCase.id) { edited in
                    if modal, edited.testType != .modalVibration {
                        edited.analysis = .modal(WorkbenchStructuralCase.ModalSettings())
                    } else if !modal {
                        edited.analysis = .strength
                    }
                }
            })) {
            Text("Прочность").tag(false)
            Text("Частоты и резонанс").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    private func modalItems(_ loadCase: WorkbenchStructuralCase, modal: WorkbenchStructuralCase.ModalSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(loadCase.supports.enumerated()), id: \.offset) { index, support in
                itemRow(support.fixed.count == 3 ? "Заделка · \(support.faceID)"
                        : "Опора \(support.fixed.map(\.rawValue).sorted().joined().uppercased()) · \(support.faceID)",
                        color: GroundControlPalette.accent) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.supports.remove(at: index) }
                }
            }
            ForEach(Array(modal.equipment.enumerated()), id: \.offset) { index, item in
                itemRow("Масса: \(item.kind.displayName.lowercased()) × \(String(format: "%g", item.count)) · \(item.faceID)",
                        color: GroundControlPalette.warning) {
                    editModal(loadCase) { $0.equipment.remove(at: index) }
                }
            }
            ForEach(Array(modal.bands.enumerated()), id: \.offset) { index, band in
                itemRow(String(format: "Полоса «%@» %.0f–%.0f Гц", band.name, band.minimumHz, band.maximumHz), color: .purple) {
                    editModal(loadCase) { $0.bands.remove(at: index) }
                }
            }
            if loadCase.supports.isEmpty {
                note("Без опор деталь считается свободной (как планер в полёте): шесть мод движения как целого не показываются.")
            }
            if !loadCase.forces.isEmpty || !loadCase.pressures.isEmpty {
                note("Силы и давления варианта в модальном расчёте не используются.")
            }
        }
    }

    private func modalControls(_ loadCase: WorkbenchStructuralCase, modal: WorkbenchStructuralCase.ModalSettings) -> some View {
        let equipment = WorkbenchBuild.slotKinds.filter { viewModel.build.spec(for: $0) != nil && $0 != .propeller }
        let bench = viewModel.validation.evaluation(.propulsionBench)?.record
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Заделка") { viewModel.beginFacePick(.support([.x, .y, .z]), for: loadCase.id) }
                Menu("По оси") {
                    ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                        Button(axis.displayName) { viewModel.beginFacePick(.support([axis]), for: loadCase.id) }
                    }
                }
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                numberField("шт.", value: $equipmentCount, width: 44)
                Menu("Масса оборудования на грань") {
                    ForEach(equipment, id: \.self) { kind in
                        Button(kind.displayName) {
                            guard let count = equipmentCount, count > 0 else { return }
                            viewModel.beginFacePick(.equipment(kind: kind, count: count), for: loadCase.id)
                        }
                    }
                }
                .disabled((equipmentCount ?? 0) <= 0)
                .help("Масса выбранных деталей (из результата масс) распределяется по грани: мотор на конце луча, АКБ на плите")
            }
            .controlSize(.small)
            fieldRow("Число мод") {
                numberField("не задано", value: Binding(
                    get: { modal.modeCount.map(Double.init) },
                    set: { value in editModal(loadCase) { $0.modeCount = value.map { Int($0.rounded()) } } }), width: 62)
            }
            fieldRow(bench?.metrics["maxRPM"].map { String(format: "Обороты винта от (до %.0f по стенду)", $0.value) } ?? "Обороты винта от") {
                numberField("об/мин", value: Binding(
                    get: { modal.rotorMinimumRPM },
                    set: { value in editModal(loadCase) { $0.rotorMinimumRPM = value } }), width: 62)
            }
            if let blades = bench?.metrics["bladeCount"]?.value {
                note(String(format: "Полосы 1P и %.0fP строятся от этих оборотов до максимальных по стенду; без минимума полос винта нет.", blades))
            }
            fieldRow("Запас по частоте, %") {
                numberField("0", value: Binding(
                    get: { modal.separationMargin * 100 },
                    set: { value in editModal(loadCase) { $0.separationMargin = (value ?? 0) / 100 } }), width: 50)
            }
            HStack(spacing: 4) {
                TextField("полоса", text: $bandName).textFieldStyle(.plain).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 3).frame(width: 70)
                    .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 4))
                numberField("от Гц", value: $bandMinimum, width: 48)
                numberField("до Гц", value: $bandMaximum, width: 48)
                Button("+ Полоса") {
                    guard let minimum = bandMinimum, let maximum = bandMaximum else { return }
                    let name = bandName.trimmingCharacters(in: .whitespaces)
                    editModal(loadCase) { $0.bands.append(.init(name: name, minimumHz: minimum, maximumHz: maximum)) }
                    bandName = ""
                    bandMinimum = nil
                    bandMaximum = nil
                }
                .disabled(bandName.trimmingCharacters(in: .whitespaces).isEmpty || bandMinimum == nil || bandMaximum == nil)
            }
            .controlSize(.small)
        }
    }

    private func editModal(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.ModalSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .modal(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .modal(settings)
        }
    }

    private func fieldRow<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            field()
        }
    }

    // MARK: Helpers

    private let directions: [(String, CodableVector3D)] = [
        ("вверх (+Y)", CodableVector3D(x: 0, y: 1, z: 0)), ("вниз (−Y)", CodableVector3D(x: 0, y: -1, z: 0)),
        ("вперёд (+Z)", CodableVector3D(x: 0, y: 0, z: 1)), ("назад (−Z)", CodableVector3D(x: 0, y: 0, z: -1)),
        ("влево (+X)", CodableVector3D(x: 1, y: 0, z: 0)), ("вправо (−X)", CodableVector3D(x: -1, y: 0, z: 0)),
    ]

    private func describe(_ force: WorkbenchStructuralCase.Force) -> String {
        switch force.source {
        case let .manual(v): return String(format: "Сила [%.1f, %.1f, %.1f] Н · %@", v.x, v.y, v.z, force.faceID)
        case let .motorThrust(motors, direction):
            return String(format: "Тяга %.0f мот. %@ · %@", motors, axisName(direction), force.faceID)
        case let .equipmentWeight(kinds, factor, direction):
            return "Вес \(kinds.map(\.displayName).joined(separator: ", ")) × \(String(format: "%.2g", factor)) g \(axisName(direction)) · \(force.faceID)"
        }
    }

    private func axisName(_ v: CodableVector3D) -> String {
        directions.first { $0.1 == v }.map { $0.0 } ?? String(format: "[%.2f, %.2f, %.2f]", v.x, v.y, v.z)
    }

    private func statusOf(_ outcome: EngineeringTestOutcome) -> EngineeringTestStatus {
        switch outcome {
        case .pass: return .pass
        case .warning: return .warning
        case .fail: return .fail
        case .error: return .error
        }
    }

    private func itemRow(_ text: String, color: Color, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(GroundControlPalette.textSecondary)
        }
    }

    private func numberField(_ placeholder: String, value: Binding<Double?>, width: CGFloat) -> some View {
        TextField(placeholder, value: value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 3)
            .frame(width: width)
            .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 4))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.title = "cadnext_structural"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Укажите cadnext_structural из сборки CADNext с CADNEXT_WITH_NETGEN=ON (обычно fea/occt/cadnext_structural)"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: WorkbenchStructuralToolLocator.defaultsKey)
            viewModel.objectWillChange.send()
        }
    }
}
