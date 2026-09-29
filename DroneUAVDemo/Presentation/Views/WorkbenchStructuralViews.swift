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
    @State private var spectrumHz: Double?
    @State private var spectrumValue: Double?
    @State private var componentName = ""
    @State private var componentPowerW: Double?
    @State private var componentMinimumC: Double?
    @State private var componentMaximumC: Double?
    @State private var probeOffsetMM: Double?
    @State private var probeImmunityVm: Double?

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
                } else if case let .shock(shock) = loadCase.analysis {
                    dynamicItems(loadCase, equipment: shock.equipment, probe: shock.probeFaceID, excitation: nil,
                                 removeEquipment: { index in editShock(loadCase) { $0.equipment.remove(at: index) } },
                                 clearProbe: { editShock(loadCase) { $0.probeFaceID = nil } }, clearExcitation: {})
                    shockControls(loadCase, shock: shock)
                    meshFields(loadCase)
                } else if case let .sine(sine) = loadCase.analysis {
                    dynamicItems(loadCase, equipment: sine.equipment, probe: sine.probeFaceID, excitation: sine.faceID,
                                 removeEquipment: { index in editSine(loadCase) { $0.equipment.remove(at: index) } },
                                 clearProbe: { editSine(loadCase) { $0.probeFaceID = nil } },
                                 clearExcitation: { editSine(loadCase) { $0.faceID = nil } })
                    sineControls(loadCase, sine: sine)
                    meshFields(loadCase)
                } else if case let .random(random) = loadCase.analysis {
                    dynamicItems(loadCase, equipment: random.equipment, probe: random.probeFaceID, excitation: nil,
                                 removeEquipment: { index in editRandom(loadCase) { $0.equipment.remove(at: index) } },
                                 clearProbe: { editRandom(loadCase) { $0.probeFaceID = nil } }, clearExcitation: {})
                    randomControls(loadCase, random: random)
                    meshFields(loadCase)
                } else if case let .climate(climate) = loadCase.analysis {
                    climateItems(loadCase, climate: climate)
                    climateControls(loadCase, climate: climate)
                    meshFields(loadCase)
                } else if case let .fire(fire) = loadCase.analysis {
                    fireItems(loadCase, fire: fire)
                    fireControls(loadCase, fire: fire)
                    // A fire case is loaded mechanically while it burns: the static editors apply.
                    addControls(loadCase)
                    numbers(loadCase)
                } else if case let .lightning(lightning) = loadCase.analysis {
                    lightningItems(loadCase, lightning: lightning)
                    lightningControls(loadCase, lightning: lightning)
                    meshFields(loadCase)
                } else if case let .emc(emc) = loadCase.analysis {
                    emcItems(loadCase, emc: emc)
                    emcControls(loadCase, emc: emc)
                    meshFields(loadCase)
                } else if case let .icing(icing) = loadCase.analysis {
                    icingControls(loadCase, icing: icing)
                    meshFields(loadCase)
                } else if case let .flutter(flutter) = loadCase.analysis {
                    flutterItems(loadCase)
                    flutterControls(loadCase, flutter: flutter)
                    meshFields(loadCase)
                } else if case let .bird(bird) = loadCase.analysis {
                    dynamicItems(loadCase, equipment: bird.equipment, probe: nil, excitation: bird.impactFaceID,
                                 removeEquipment: { index in editBird(loadCase) { $0.equipment.remove(at: index) } },
                                 clearProbe: {}, clearExcitation: { editBird(loadCase) { $0.impactFaceID = nil } })
                    birdControls(loadCase, bird: bird)
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
                if let run = status.run, let url = viewModel.structuralResultURL(for: run),
                   FileManager.default.fileExists(atPath: url.path) {
                    Button(L10n.s("structural.open_result")) { CADNextLauncherService.shared.openStructuralResult(at: url) }
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
        // A menu, not segments: the kinds are five now and will be twelve, and their names do not
        // fit a side panel as segments.
        Picker("", selection: Binding(
            get: { loadCase.kind },
            set: { kind in
                guard kind != loadCase.kind else { return }
                viewModel.updateStructuralCase(loadCase.id) { edited in
                    switch kind {
                    case .strength: edited.analysis = .strength
                    case .modal: edited.analysis = .modal(WorkbenchStructuralCase.ModalSettings())
                    case .sine: edited.analysis = .sine(WorkbenchStructuralCase.SineSettings())
                    case .random: edited.analysis = .random(WorkbenchStructuralCase.RandomSettings())
                    case .shock: edited.analysis = .shock(WorkbenchStructuralCase.ShockSettings())
                    case .climate: edited.analysis = .climate(WorkbenchStructuralCase.ClimateSettings())
                    case .fire: edited.analysis = .fire(WorkbenchStructuralCase.FireSettings())
                    case .lightning: edited.analysis = .lightning(WorkbenchStructuralCase.LightningSettings())
                    case .emc: edited.analysis = .emc(WorkbenchStructuralCase.EmcSettings())
                    case .icing: edited.analysis = .icing(WorkbenchStructuralCase.IcingSettings())
                    case .flutter: edited.analysis = .flutter(WorkbenchStructuralCase.FlutterSettings())
                    case .bird: edited.analysis = .bird(WorkbenchStructuralCase.BirdSettings())
                    }
                }
            })) {
            ForEach(WorkbenchStructuralCase.Kind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.menu)
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

    // MARK: Shock case

    /// Faces a dynamic case has assigned: supports, equipment riding along, exclusion zones, the
    /// sensor face and (sine only) the face the excitation acts on. One list for every kind, because
    /// a user reads them the same way.
    private func dynamicItems(
        _ loadCase: WorkbenchStructuralCase,
        equipment: [WorkbenchStructuralCase.Equipment],
        probe: String?,
        excitation: String?,
        removeEquipment: @escaping (Int) -> Void,
        clearProbe: @escaping () -> Void,
        clearExcitation: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(loadCase.supports.enumerated()), id: \.offset) { index, support in
                itemRow(support.fixed.count == 3 ? "Заделка · \(support.faceID)"
                        : "Опора \(support.fixed.map(\.rawValue).sorted().joined().uppercased()) · \(support.faceID)",
                        color: GroundControlPalette.accent) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.supports.remove(at: index) }
                }
            }
            ForEach(Array(equipment.enumerated()), id: \.offset) { index, item in
                itemRow(String(format: "Оборудование %.0f × %@ · %@", item.count, item.kind.displayName, item.faceID),
                        color: GroundControlPalette.textSecondary) { removeEquipment(index) }
            }
            ForEach(Array(loadCase.exclusions.enumerated()), id: \.offset) { index, item in
                itemRow(String(format: "Исключение %.0f мм · %@", item.distanceM * 1e3, item.faceID),
                        color: GroundControlPalette.textSecondary) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.exclusions.remove(at: index) }
                }
            }
            if let excitation {
                itemRow("Возбуждение · \(excitation)", color: GroundControlPalette.warning) { clearExcitation() }
            }
            if let probe {
                itemRow("Датчик · \(probe)", color: GroundControlPalette.textSecondary) { clearProbe() }
            }
        }
    }

    /// Supports, exclusion zones and equipment: the same three things every dynamic case assigns.
    private func dynamicAddControls(_ loadCase: WorkbenchStructuralCase, equipmentHelp: String) -> some View {
        let equipment = WorkbenchBuild.slotKinds.filter { viewModel.build.spec(for: $0) != nil && $0 != .propeller }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Заделка") { viewModel.beginFacePick(.support([.x, .y, .z]), for: loadCase.id) }
                Menu("По оси") {
                    ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                        Button(axis.displayName) { viewModel.beginFacePick(.support([axis]), for: loadCase.id) }
                    }
                }
                numberField("мм", value: $exclusionMM, width: 44)
                Button("Исключить") {
                    guard let mm = exclusionMM, mm > 0 else { return }
                    viewModel.beginFacePick(.exclusion(mm / 1e3), for: loadCase.id)
                }
                .disabled((exclusionMM ?? 0) <= 0)
                .help("Зона у заделки, где напряжение — особенность идеализированного крепления, а не деталь")
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
                .help(equipmentHelp)
            }
            .controlSize(.small)
        }
    }

    /// Modes, damping and the sensor face: asked by every dynamic case in the same words.
    private func dynamicModeFields(
        modeCount: Binding<Double?>, dampingPercent: Binding<Double?>, pickProbe: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                fieldRow("Число мод") { numberField("не задано", value: modeCount, width: 56) }
                fieldRow("ζ, %") { numberField("не задано", value: dampingPercent, width: 56) }
            }
            HStack(spacing: 6) {
                Button("Грань датчика") { pickProbe() }
                    .help("Ускорение и перемещение этой грани записываются, как их видел бы датчик на оснастке")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
    }

    /// One (frequency, value) list: a sine amplitude curve or a PSD, entered as the schedules write them.
    private func spectrumEditor(
        _ points: [WorkbenchStructuralCase.SpectrumPoint], unit: String,
        add: @escaping (WorkbenchStructuralCase.SpectrumPoint) -> Void, remove: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                itemRow(String(format: "%.4g Гц · %.4g %@", point.frequencyHz, point.value, unit),
                        color: GroundControlPalette.textSecondary) { remove(index) }
            }
            HStack(spacing: 4) {
                numberField("Гц", value: $spectrumHz, width: 56)
                numberField(unit, value: $spectrumValue, width: 56)
                Button("+ Точка") {
                    guard let hz = spectrumHz, let value = spectrumValue else { return }
                    add(.init(frequencyHz: hz, value: value))
                    spectrumHz = nil
                    spectrumValue = nil
                }
                .disabled(spectrumHz == nil || spectrumValue == nil)
            }
            .controlSize(.small)
        }
    }

    private func sineControls(_ loadCase: WorkbenchStructuralCase, sine: WorkbenchStructuralCase.SineSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            dynamicAddControls(loadCase, equipmentHelp: "Оборудование трясётся вместе с деталью: его масса берётся из результата масс")
            fieldRow("Возбуждение") {
                Menu(sine.excitation.displayName) {
                    ForEach(WorkbenchStructuralCase.SineSettings.Excitation.allCases, id: \.self) { kind in
                        Button(kind.displayName) { editSine(loadCase) { $0.excitation = kind } }
                    }
                }
                .controlSize(.small)
                .frame(width: 150)
            }
            fieldRow("Направление") {
                Menu(axisName(sine.direction)) {
                    ForEach(directions, id: \.0) { name, vector in
                        Button(name) { editSine(loadCase) { $0.direction = vector } }
                    }
                }
                .controlSize(.small)
                .frame(width: 110)
            }
            if sine.excitation != .base {
                HStack(spacing: 6) {
                    Button("Грань возбуждения") { viewModel.beginFacePick(.excitationFace, for: loadCase.id) }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            if sine.excitation == .imbalance {
                fieldRow("Дисбаланс, г·мм") {
                    numberField("не задан", value: Binding(
                        get: { sine.imbalanceGmm },
                        set: { value in editSine(loadCase) { $0.imbalanceGmm = value } }), width: 62)
                }
            } else {
                spectrumEditor(sine.amplitude, unit: sine.excitation == .base ? "g" : "Н",
                               add: { point in editSine(loadCase) { $0.amplitude.append(point); $0.amplitude.sort { $0.frequencyHz < $1.frequencyHz } } },
                               remove: { index in editSine(loadCase) { $0.amplitude.remove(at: index) } })
                note("Одна точка — постоянная амплитуда на всём диапазоне; несколько задают кривую.")
            }
            HStack(spacing: 4) {
                fieldRow("Развёртка от, Гц") {
                    numberField("не задана", value: Binding(
                        get: { sine.fromHz },
                        set: { value in editSine(loadCase) { $0.fromHz = value } }), width: 56)
                }
                fieldRow("до, Гц") {
                    numberField("не задана", value: Binding(
                        get: { sine.toHz },
                        set: { value in editSine(loadCase) { $0.toHz = value } }), width: 56)
                }
            }
            dynamicModeFields(
                modeCount: Binding(get: { sine.modeCount.map(Double.init) },
                                   set: { value in editSine(loadCase) { $0.modeCount = value.map { Int($0.rounded()) } } }),
                dampingPercent: Binding(get: { sine.dampingRatio.map { $0 * 100 } },
                                        set: { value in editSine(loadCase) { $0.dampingRatio = value.map { $0 / 100 } } }),
                pickProbe: { viewModel.beginFacePick(.probe, for: loadCase.id) })
            note("Синус ищет резонанс на развёртке: вердикт по напряжению на худшей частоте. "
                 + "Усталость этим расчётом не оценивается.")
        }
    }

    private func randomControls(_ loadCase: WorkbenchStructuralCase, random: WorkbenchStructuralCase.RandomSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            dynamicAddControls(loadCase, equipmentHelp: "Оборудование трясётся вместе с деталью: его масса берётся из результата масс")
            fieldRow("Направление") {
                Menu(axisName(random.direction)) {
                    ForEach(directions, id: \.0) { name, vector in
                        Button(name) { editRandom(loadCase) { $0.direction = vector } }
                    }
                }
                .controlSize(.small)
                .frame(width: 110)
            }
            spectrumEditor(random.psd, unit: "g²/Гц",
                           add: { point in editRandom(loadCase) { $0.psd.append(point); $0.psd.sort { $0.frequencyHz < $1.frequencyHz } } },
                           remove: { index in editRandom(loadCase) { $0.psd.remove(at: index) } })
            note("Спектр как в расписании вибраций: не меньше двух точек, между ними лог-лог, вне — ноль.")
            dynamicModeFields(
                modeCount: Binding(get: { random.modeCount.map(Double.init) },
                                   set: { value in editRandom(loadCase) { $0.modeCount = value.map { Int($0.rounded()) } } }),
                dampingPercent: Binding(get: { random.dampingRatio.map { $0 * 100 } },
                                        set: { value in editRandom(loadCase) { $0.dampingRatio = value.map { $0 / 100 } } }),
                pickProbe: { viewModel.beginFacePick(.probe, for: loadCase.id) })
            note("Вердикт по 3σ напряжения (Сегалман): случайный отклик не имеет одного положения.")
        }
    }

    private func editSine(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.SineSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .sine(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .sine(settings)
        }
    }

    private func editRandom(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.RandomSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .random(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .random(settings)
        }
    }

    private func shockControls(_ loadCase: WorkbenchStructuralCase, shock: WorkbenchStructuralCase.ShockSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            dynamicAddControls(loadCase, equipmentHelp: "Оборудование едет через удар вместе с деталью: его масса берётся из результата масс")
            fieldRow("Удар направлен") {
                Menu(axisName(shock.direction)) {
                    ForEach(directions, id: \.0) { name, vector in
                        Button(name) { editShock(loadCase) { $0.direction = vector } }
                    }
                }
                .controlSize(.small)
                .frame(width: 110)
            }
            fieldRow("Форма импульса") {
                Menu(shock.shape.displayName) {
                    ForEach(WorkbenchStructuralCase.PulseShape.allCases, id: \.self) { shape in
                        Button(shape.displayName) { editShock(loadCase) { $0.shape = shape } }
                    }
                }
                .controlSize(.small)
                .frame(width: 110)
            }
            HStack(spacing: 4) {
                fieldRow("Амплитуда, g") {
                    numberField("не задана", value: Binding(
                        get: { shock.peakG },
                        set: { value in editShock(loadCase) { $0.peakG = value } }), width: 56)
                }
                fieldRow("Длительность, мс") {
                    numberField("не задана", value: Binding(
                        get: { shock.durationMs },
                        set: { value in editShock(loadCase) { $0.durationMs = value } }), width: 56)
                }
            }
            if shock.shape == .trapezoid {
                HStack(spacing: 4) {
                    fieldRow("Фронт, мс") {
                        numberField("0", value: Binding(
                            get: { shock.riseMs },
                            set: { value in editShock(loadCase) { $0.riseMs = value ?? 0 } }), width: 56)
                    }
                    fieldRow("Спад, мс") {
                        numberField("0", value: Binding(
                            get: { shock.fallMs },
                            set: { value in editShock(loadCase) { $0.fallMs = value ?? 0 } }), width: 56)
                    }
                }
            }
            dynamicModeFields(
                modeCount: Binding(get: { shock.modeCount.map(Double.init) },
                                   set: { value in editShock(loadCase) { $0.modeCount = value.map { Int($0.rounded()) } } }),
                dampingPercent: Binding(get: { shock.dampingRatio.map { $0 * 100 } },
                                        set: { value in editShock(loadCase) { $0.dampingRatio = value.map { $0 / 100 } } }),
                pickProbe: { viewModel.beginFacePick(.probe, for: loadCase.id) })
            note("Удар — одно событие: вердикт выносится по правилам эксплуатационной и расчётной нагрузки, "
                 + "усталость не оценивается. Демпфирование и число мод умолчаний не имеют.")
        }
    }

    // MARK: Thermal cases (climate, fire, lightning)

    /// Equipment rows of a thermal case, with what it survives.
    private func componentRows(_ components: [WorkbenchStructuralCase.ThermalComponent], remove: @escaping (Int) -> Void) -> some View {
        ForEach(Array(components.enumerated()), id: \.offset) { index, item in
            itemRow(item.name + " · " + item.faceID + " · "
                    + String(format: "%.1f Вт", item.powerW)
                    + (item.minimumC.map { String(format: ", от %.0f °C", $0) } ?? "")
                    + (item.maximumC.map { String(format: ", до %.0f °C", $0) } ?? ""),
                    color: GroundControlPalette.textSecondary) { remove(index) }
        }
    }

    /// Entering a piece of equipment: its name, heat and limits, then a face to put it on.
    private func componentEditor(_ loadCase: WorkbenchStructuralCase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("оборудование", text: $componentName).textFieldStyle(.plain).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 3).frame(width: 96)
                    .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 4))
                numberField("Вт", value: $componentPowerW, width: 44)
                numberField("от °C", value: $componentMinimumC, width: 50)
                numberField("до °C", value: $componentMaximumC, width: 50)
            }
            HStack(spacing: 6) {
                Button("+ На грань") {
                    let name = componentName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, componentMinimumC != nil || componentMaximumC != nil else { return }
                    viewModel.beginFacePick(.thermalComponent(name: name, powerW: componentPowerW ?? 0,
                                                              minimumC: componentMinimumC, maximumC: componentMaximumC),
                                            for: loadCase.id)
                    componentName = ""
                    componentPowerW = nil
                    componentMinimumC = nil
                    componentMaximumC = nil
                }
                .disabled(componentName.trimmingCharacters(in: .whitespaces).isEmpty
                          || (componentMinimumC == nil && componentMaximumC == nil))
                .help("Пределы температуры берутся из паспорта прибора: библиотека их не хранит, а придуманный предел хуже отсутствующего")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
    }

    private func climateItems(_ loadCase: WorkbenchStructuralCase, climate: WorkbenchStructuralCase.ClimateSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(loadCase.supports.enumerated()), id: \.offset) { index, support in
                itemRow("Опора · \(support.faceID)", color: GroundControlPalette.accent) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.supports.remove(at: index) }
                }
            }
            componentRows(climate.components) { index in editClimate(loadCase) { $0.components.remove(at: index) } }
        }
    }

    private func climateControls(_ loadCase: WorkbenchStructuralCase, climate: WorkbenchStructuralCase.ClimateSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Опора") { viewModel.beginFacePick(.support([.x, .y, .z]), for: loadCase.id) }
                    .help("Без опор деталь расширяется свободно: тепловых напряжений тогда почти нет, и это законный вариант")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            fieldRow("Среда") {
                Menu(climate.environment.displayName) {
                    ForEach(WorkbenchStructuralCase.ClimateSettings.Environment.allCases, id: \.self) { value in
                        Button(value.displayName) { editClimate(loadCase) { $0.environment = value } }
                    }
                }
                .controlSize(.small).frame(width: 110)
            }
            if climate.environment == .hot {
                fieldRow("Категория") {
                    Menu(climate.hotCategory.displayName) {
                        ForEach(WorkbenchStructuralCase.ClimateSettings.HotCategory.allCases, id: \.self) { value in
                            Button(value.displayName) { editClimate(loadCase) { $0.hotCategory = value } }
                        }
                    }
                    .controlSize(.small).frame(width: 175)
                }
                fieldRow("Выдержка") {
                    Menu(climate.hotExposure.displayName) {
                        ForEach(WorkbenchStructuralCase.ClimateSettings.HotExposure.allCases, id: \.self) { value in
                            Button(value.displayName) { editClimate(loadCase) { $0.hotExposure = value } }
                        }
                    }
                    .controlSize(.small).frame(width: 175)
                }
            } else {
                fieldRow("Категория") {
                    Menu(climate.coldCategory.displayName) {
                        ForEach(WorkbenchStructuralCase.ClimateSettings.ColdCategory.allCases, id: \.self) { value in
                            Button(value.displayName) { editClimate(loadCase) { $0.coldCategory = value } }
                        }
                    }
                    .controlSize(.small).frame(width: 175)
                }
                fieldRow("Выдержка") {
                    Menu(climate.coldExposure.displayName) {
                        ForEach(WorkbenchStructuralCase.ClimateSettings.ColdExposure.allCases, id: \.self) { value in
                            Button(value.displayName) { editClimate(loadCase) { $0.coldExposure = value } }
                        }
                    }
                    .controlSize(.small).frame(width: 175)
                }
            }
            fieldRow("Обдув") {
                Menu(climate.airflow.displayName) {
                    ForEach(WorkbenchStructuralCase.ClimateSettings.Airflow.allCases, id: \.self) { value in
                        Button(value.displayName) { editClimate(loadCase) { $0.airflow = value } }
                    }
                }
                .controlSize(.small).frame(width: 150)
            }
            HStack(spacing: 4) {
                fieldRow("Скорость, м/с") {
                    numberField("не задана", value: Binding(
                        get: { climate.airSpeedMps },
                        set: { value in editClimate(loadCase) { $0.airSpeedMps = value } }), width: 56)
                }
                fieldRow("Высота, м") {
                    numberField("0", value: Binding(
                        get: { climate.altitudeM },
                        set: { value in editClimate(loadCase) { $0.altitudeM = value } }), width: 56)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Верх") {
                    Menu(axisName(climate.up)) {
                        ForEach(directions, id: \.0) { name, vector in
                            Button(name) { editClimate(loadCase) { $0.up = vector } }
                        }
                    }
                    .controlSize(.small).frame(width: 96)
                }
                fieldRow("Поток") {
                    Menu(axisName(climate.flow)) {
                        ForEach(directions, id: \.0) { name, vector in
                            Button(name) { editClimate(loadCase) { $0.flow = vector } }
                        }
                    }
                    .controlSize(.small).frame(width: 96)
                }
            }
            HStack(spacing: 4) {
                fieldRow("α солнца") {
                    numberField("не задано", value: Binding(
                        get: { climate.solarAbsorptance },
                        set: { value in editClimate(loadCase) { $0.solarAbsorptance = value } }), width: 50)
                }
                fieldRow("ε") {
                    numberField("не задано", value: Binding(
                        get: { climate.emissivity },
                        set: { value in editClimate(loadCase) { $0.emissivity = value } }), width: 50)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Сборка, °C") {
                    numberField("не задана", value: Binding(
                        get: { climate.assemblyC },
                        set: { value in editClimate(loadCase) { $0.assemblyC = value } }), width: 56)
                }
                fieldRow("Шаг, с") {
                    numberField("не задан", value: Binding(
                        get: { climate.stepS },
                        set: { value in editClimate(loadCase) { $0.stepS = value } }), width: 56)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Материал от, °C") {
                    numberField("нет", value: Binding(
                        get: { climate.materialMinimumC },
                        set: { value in editClimate(loadCase) { $0.materialMinimumC = value } }), width: 56)
                }
                fieldRow("до, °C") {
                    numberField("нет", value: Binding(
                        get: { climate.materialMaximumC },
                        set: { value in editClimate(loadCase) { $0.materialMaximumC = value } }), width: 56)
                }
            }
            Toggle("Оборудование работает", isOn: Binding(
                get: { climate.operating },
                set: { value in editClimate(loadCase) { $0.operating = value } }))
                .controlSize(.small).font(.system(size: 10))
            componentEditor(loadCase)
            note("Условия и температуры — из MIL-STD-810H по выбранной категории. Тепловые напряжения считаются от температуры сборки.")
        }
    }

    private func fireItems(_ loadCase: WorkbenchStructuralCase, fire: WorkbenchStructuralCase.FireSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            itemsList(loadCase)
            ForEach(Array(fire.flameFaceIDs.enumerated()), id: \.offset) { index, face in
                itemRow("Пламя · \(face)", color: GroundControlPalette.warning) {
                    editFire(loadCase) { $0.flameFaceIDs.remove(at: index) }
                }
            }
            componentRows(fire.components) { index in editFire(loadCase) { $0.components.remove(at: index) } }
        }
    }

    private func fireControls(_ loadCase: WorkbenchStructuralCase, fire: WorkbenchStructuralCase.FireSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Грань под пламенем") { viewModel.beginFacePick(.flameFace, for: loadCase.id) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            fieldRow("Стандарт") {
                Menu(fire.standard.displayName) {
                    ForEach(WorkbenchStructuralCase.FireSettings.Standard.allCases, id: \.self) { value in
                        Button(value.displayName) { editFire(loadCase) { $0.standard = value } }
                    }
                }
                .controlSize(.small).frame(width: 110)
            }
            fieldRow("Длительность") {
                Menu(fire.durationS.map { String(format: "%.0f с", $0) } ?? "не задана") {
                    Button("300 с — огнестойкость") { editFire(loadCase) { $0.durationS = 300 } }
                    Button("900 с — огнепрочность") { editFire(loadCase) { $0.durationS = 900 } }
                }
                .controlSize(.small).frame(width: 150)
            }
            HStack(spacing: 4) {
                fieldRow("ε поверхности") {
                    numberField("не задано", value: Binding(
                        get: { fire.surfaceEmissivity },
                        set: { value in editFire(loadCase) { $0.surfaceEmissivity = value } }), width: 50)
                }
                fieldRow("Шаг, с") {
                    numberField("не задан", value: Binding(
                        get: { fire.stepS },
                        set: { value in editFire(loadCase) { $0.stepS = value } }), width: 50)
                }
            }
            note("EN 1999-1-2 §2.2: ε ≈ 0.3 для чистого металла, 0.7 для окрашенной поверхности.")
            Toggle("Оборудование работает", isOn: Binding(
                get: { fire.operating },
                set: { value in editFire(loadCase) { $0.operating = value } }))
                .controlSize(.small).font(.system(size: 10))
            componentEditor(loadCase)
            note("Пожарный вариант нагружает деталь механически: силы, давления и перегрузка ниже — это нагрузки пожарной ситуации.")
        }
    }

    private func lightningItems(_ loadCase: WorkbenchStructuralCase, lightning: WorkbenchStructuralCase.LightningSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lightning.attachmentFaceIDs.enumerated()), id: \.offset) { index, face in
                itemRow("Привязка дуги · \(face)", color: GroundControlPalette.warning) {
                    editLightning(loadCase) { $0.attachmentFaceIDs.remove(at: index) }
                }
            }
            ForEach(Array(lightning.groundFaceIDs.enumerated()), id: \.offset) { index, face in
                itemRow("Связь с конструкцией · \(face)", color: GroundControlPalette.accent) {
                    editLightning(loadCase) { $0.groundFaceIDs.remove(at: index) }
                }
            }
            componentRows(lightning.equipment) { index in editLightning(loadCase) { $0.equipment.remove(at: index) } }
        }
    }

    private func lightningControls(_ loadCase: WorkbenchStructuralCase, lightning: WorkbenchStructuralCase.LightningSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Привязка дуги") { viewModel.beginFacePick(.attachmentFace, for: loadCase.id) }
                Button("Связь с конструкцией") { viewModel.beginFacePick(.groundFace, for: loadCase.id) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Компоненты тока").font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
                ForEach(WorkbenchStructuralCase.LightningSettings.Component.allCases, id: \.self) { component in
                    Toggle(component.displayName, isOn: Binding(
                        get: { lightning.components.contains(component) },
                        set: { on in
                            editLightning(loadCase) { settings in
                                if on {
                                    if !settings.components.contains(component) { settings.components.append(component) }
                                } else {
                                    settings.components.removeAll { $0 == component }
                                }
                            }
                        }))
                        .controlSize(.small).font(.system(size: 10))
                }
            }
            fieldRow("Полярность") {
                Menu(lightning.polarity.displayName) {
                    ForEach(WorkbenchStructuralCase.LightningSettings.Polarity.allCases, id: \.self) { value in
                        Button(value.displayName) { editLightning(loadCase) { $0.polarity = value } }
                    }
                }
                .controlSize(.small).frame(width: 175)
            }
            HStack(spacing: 4) {
                fieldRow("Ток C, А") {
                    numberField("400", value: Binding(
                        get: { lightning.continuingCurrentA },
                        set: { value in editLightning(loadCase) { $0.continuingCurrentA = value ?? 400 } }), width: 56)
                }
                fieldRow("ε поверхности") {
                    numberField("не задано", value: Binding(
                        get: { lightning.surfaceEmissivity },
                        set: { value in editLightning(loadCase) { $0.surfaceEmissivity = value } }), width: 50)
                }
            }
            fieldRow("Шагов на компонент") {
                numberField("400", value: Binding(
                    get: { Double(lightning.stepsPerComponent) },
                    set: { value in editLightning(loadCase) { $0.stepsPerComponent = Int((value ?? 400).rounded()) } }), width: 56)
            }
            componentEditor(loadCase)
            note("SAE ARP5412: продолжающийся ток компонента C по стандарту 200…800 А. Опоры здесь не нужны — считается растекание тока и нагрев.")
        }
    }

    // MARK: EMC, icing, flutter, bird

    private func emcItems(_ loadCase: WorkbenchStructuralCase, emc: WorkbenchStructuralCase.EmcSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(emc.equipment.enumerated()), id: \.offset) { index, point in
                itemRow(String(format: "%@ · [%.3f, %.3f, %.3f] м · %.0f В/м", point.name, point.x, point.y, point.z, point.immunityVm),
                        color: GroundControlPalette.textSecondary) {
                    editEmc(loadCase) { $0.equipment.remove(at: index) }
                }
            }
        }
    }

    private func emcControls(_ loadCase: WorkbenchStructuralCase, emc: WorkbenchStructuralCase.EmcSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow("Уровень") {
                Menu(emc.levelID.map { id in
                    id.hasSuffix("20") ? "RS103, 20 В/м" : id.hasSuffix("50") ? "RS103, 50 В/м" : "RS103, 200 В/м"
                } ?? "своё поле") {
                    Button("RS103, 20 В/м — внутренние отсеки") { editEmc(loadCase) { $0.levelID = "mil461g-rs103-20"; $0.fieldVm = nil } }
                    Button("RS103, 50 В/м — наземная техника") { editEmc(loadCase) { $0.levelID = "mil461g-rs103-50"; $0.fieldVm = nil } }
                    Button("RS103, 200 В/м — внешние поверхности") { editEmc(loadCase) { $0.levelID = "mil461g-rs103-200"; $0.fieldVm = nil } }
                    Button("Своё поле") { editEmc(loadCase) { $0.levelID = nil } }
                }
                .controlSize(.small).frame(width: 175)
            }
            if emc.levelID == nil {
                fieldRow("Поле, В/м") {
                    numberField("не задано", value: Binding(
                        get: { emc.fieldVm },
                        set: { value in editEmc(loadCase) { $0.fieldVm = value } }), width: 56)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Приход волны") {
                    Menu(emc.incidence.displayName) {
                        ForEach(WorkbenchStructuralCase.EmcSettings.Incidence.allCases, id: \.self) { value in
                            Button(value.displayName) { editEmc(loadCase) { $0.incidence = value } }
                        }
                    }
                    .controlSize(.small).frame(width: 70)
                }
                fieldRow("Поляризация") {
                    Menu(emc.polarization.displayName) {
                        ForEach(WorkbenchStructuralCase.EmcSettings.Polarization.allCases, id: \.self) { value in
                            Button(value.displayName) { editEmc(loadCase) { $0.polarization = value } }
                        }
                    }
                    .controlSize(.small).frame(width: 60)
                }
            }
            HStack(spacing: 4) {
                fieldRow("от, МГц") {
                    numberField("не задано", value: Binding(
                        get: { emc.lowMHz },
                        set: { value in editEmc(loadCase) { $0.lowMHz = value } }), width: 56)
                }
                fieldRow("до, МГц") {
                    numberField("не задано", value: Binding(
                        get: { emc.highMHz },
                        set: { value in editEmc(loadCase) { $0.highMHz = value } }), width: 56)
                }
                fieldRow("точек") {
                    numberField("8", value: Binding(
                        get: { Double(emc.points) },
                        set: { value in editEmc(loadCase) { $0.points = Int((value ?? 8).rounded()) } }), width: 40)
                }
            }
            fieldRow("Элемент поверхности, мм") {
                numberField("не задан", value: Binding(
                    get: { emc.surfaceElementSizeM.map { $0 * 1e3 } },
                    set: { value in editEmc(loadCase) { $0.surfaceElementSizeM = value.map { $0 / 1e3 } } }), width: 56)
            }
            HStack(spacing: 4) {
                numberField("вглубь, мм", value: $probeOffsetMM, width: 70)
                numberField("В/м", value: $probeImmunityVm, width: 50)
                TextField("прибор", text: $componentName).textFieldStyle(.plain).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 3).frame(width: 76)
                    .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 4))
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Button("+ Точка от грани") {
                    let name = componentName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, let offset = probeOffsetMM, let immunity = probeImmunityVm, immunity > 0 else { return }
                    viewModel.beginFacePick(.emcProbe(name: name, offsetMm: offset, immunityVm: immunity), for: loadCase.id)
                    componentName = ""
                    probeOffsetMM = nil
                    probeImmunityVm = nil
                }
                .disabled(componentName.trimmingCharacters(in: .whitespaces).isEmpty || probeOffsetMM == nil || (probeImmunityVm ?? 0) <= 0)
                .help("Точка ставится в центре выбранной грани и уводится внутрь корпуса на заданное расстояние")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            note("MIL-STD-461G RS103. Опоры и нагрузки здесь не нужны: считается, сколько поля доходит внутрь корпуса. "
                 + "«Размер грубой сетки» ниже — это шаг ячейки FDTD, а не конечного элемента.")
        }
    }

    private func icingControls(_ loadCase: WorkbenchStructuralCase, icing: WorkbenchStructuralCase.IcingSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                fieldRow("Поток вдоль") {
                    Menu(icing.flowAxis.displayName) {
                        ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                            Button(axis.displayName) { editIcing(loadCase) { $0.flowAxis = axis } }
                        }
                    }
                    .controlSize(.small).frame(width: 96)
                }
                fieldRow("Размах вдоль") {
                    Menu(icing.spanAxis.displayName) {
                        ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                            Button(axis.displayName) { editIcing(loadCase) { $0.spanAxis = axis } }
                        }
                    }
                    .controlSize(.small).frame(width: 96)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Угол атаки, °") {
                    numberField("0", value: Binding(
                        get: { icing.angleOfAttackDeg },
                        set: { value in editIcing(loadCase) { $0.angleOfAttackDeg = value ?? 0 } }), width: 50)
                }
                fieldRow("Сечений") {
                    numberField("3", value: Binding(
                        get: { Double(icing.stations) },
                        set: { value in editIcing(loadCase) { $0.stations = Int((value ?? 3).rounded()) } }), width: 40)
                }
                fieldRow("Элемент, мм") {
                    numberField("не задан", value: Binding(
                        get: { icing.surfaceElementSizeM.map { $0 * 1e3 } },
                        set: { value in editIcing(loadCase) { $0.surfaceElementSizeM = value.map { $0 / 1e3 } } }), width: 56)
                }
            }
            Toggle("Взлётное обледенение (14 CFR 25 Прил. C)", isOn: Binding(
                get: { icing.useTakeoffMaximum },
                set: { value in editIcing(loadCase) { $0.useTakeoffMaximum = value } }))
                .controlSize(.small).font(.system(size: 10))
            HStack(spacing: 4) {
                fieldRow("Скорость, м/с") {
                    numberField("не задана", value: Binding(
                        get: { icing.airspeedMps },
                        set: { value in editIcing(loadCase) { $0.airspeedMps = value } }), width: 56)
                }
                fieldRow("Время, мин") {
                    numberField("не задано", value: Binding(
                        get: { icing.durationMin },
                        set: { value in editIcing(loadCase) { $0.durationMin = value } }), width: 56)
                }
            }
            if !icing.useTakeoffMaximum {
                HStack(spacing: 4) {
                    fieldRow("t, °C") {
                        numberField("не задано", value: Binding(
                            get: { icing.temperatureC },
                            set: { value in editIcing(loadCase) { $0.temperatureC = value } }), width: 50)
                    }
                    fieldRow("вода, г/м³") {
                        numberField("не задано", value: Binding(
                            get: { icing.lwcGm3 },
                            set: { value in editIcing(loadCase) { $0.lwcGm3 = value } }), width: 50)
                    }
                    fieldRow("капли, мкм") {
                        numberField("не задано", value: Binding(
                            get: { icing.dropletMicrons },
                            set: { value in editIcing(loadCase) { $0.dropletMicrons = value } }), width: 50)
                    }
                }
            }
            HStack(spacing: 4) {
                fieldRow("Обогрев до, °C") {
                    numberField("нет", value: Binding(
                        get: { icing.antiIceTargetC },
                        set: { value in editIcing(loadCase) { $0.antiIceTargetC = value } }), width: 50)
                }
                fieldRow("бюджет, Вт") {
                    numberField("нет", value: Binding(
                        get: { icing.antiIceBudgetW },
                        set: { value in editIcing(loadCase) { $0.antiIceBudgetW = value } }), width: 50)
                }
                fieldRow("лёд до, мм") {
                    numberField("нет", value: Binding(
                        get: { icing.maximumIceThicknessMm },
                        set: { value in editIcing(loadCase) { $0.maximumIceThicknessMm = value } }), width: 50)
                }
            }
            note("Лёд растёт на внешней обшивке: опоры и нагрузки не нужны. Без допустимой толщины вердикт не выше WARNING.")
        }
    }

    private func flutterItems(_ loadCase: WorkbenchStructuralCase) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(loadCase.supports.enumerated()), id: \.offset) { index, support in
                itemRow("Корень · \(support.faceID)", color: GroundControlPalette.accent) {
                    viewModel.updateStructuralCase(loadCase.id) { $0.supports.remove(at: index) }
                }
            }
        }
    }

    private func flutterControls(_ loadCase: WorkbenchStructuralCase, flutter: WorkbenchStructuralCase.FlutterSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Корень (заделка)") { viewModel.beginFacePick(.support([.x, .y, .z]), for: loadCase.id) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                fieldRow("Поток вдоль") {
                    Menu(flutter.flowAxis.displayName) {
                        ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                            Button(axis.displayName) { editFlutter(loadCase) { $0.flowAxis = axis } }
                        }
                    }
                    .controlSize(.small).frame(width: 96)
                }
                fieldRow("Размах вдоль") {
                    Menu(flutter.spanAxis.displayName) {
                        ForEach(WorkbenchModelAxis.allCases, id: \.self) { axis in
                            Button(axis.displayName) { editFlutter(loadCase) { $0.spanAxis = axis } }
                        }
                    }
                    .controlSize(.small).frame(width: 96)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Плотность, кг/м³") {
                    numberField("1.225", value: Binding(
                        get: { flutter.airDensityKgM3 },
                        set: { value in editFlutter(loadCase) { $0.airDensityKgM3 = value ?? 1.225 } }), width: 56)
                }
                fieldRow("V_D, м/с") {
                    numberField("не задана", value: Binding(
                        get: { flutter.diveSpeedMps },
                        set: { value in editFlutter(loadCase) { $0.diveSpeedMps = value } }), width: 56)
                }
            }
            HStack(spacing: 4) {
                fieldRow("Развёртка от") {
                    numberField("10", value: Binding(
                        get: { flutter.lowSpeedMps },
                        set: { value in editFlutter(loadCase) { $0.lowSpeedMps = value ?? 10 } }), width: 50)
                }
                fieldRow("до, м/с") {
                    numberField("400", value: Binding(
                        get: { flutter.highSpeedMps },
                        set: { value in editFlutter(loadCase) { $0.highSpeedMps = value ?? 400 } }), width: 50)
                }
                fieldRow("полос") {
                    numberField("12", value: Binding(
                        get: { Double(flutter.stations) },
                        set: { value in editFlutter(loadCase) { $0.stations = Int((value ?? 12).rounded()) } }), width: 40)
                }
            }
            fieldRow("Конструкционное g") {
                numberField("0", value: Binding(
                    get: { flutter.structuralDamping },
                    set: { value in editFlutter(loadCase) { $0.structuralDamping = value ?? 0 } }), width: 50)
            }
            note("25.629: аппарат должен быть свободен от флаттера до 1.15·V_D. Нужна пара мод изгиб + кручение: на бруске без них расчёт откажется.")
        }
    }

    private func birdControls(_ loadCase: WorkbenchStructuralCase, bird: WorkbenchStructuralCase.BirdSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            dynamicAddControls(loadCase, equipmentHelp: "Оборудование едет через удар вместе с деталью: его масса берётся из результата масс")
            HStack(spacing: 6) {
                Button("Грань удара") { viewModel.beginFacePick(.impactFace, for: loadCase.id) }
                    .help("Давление птицы распределяется по всей этой грани: грань заметно больше птицы занижает местное напряжение, и расчёт об этом скажет")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            fieldRow("Направление удара") {
                Menu(axisName(bird.direction)) {
                    ForEach(directions, id: \.0) { name, vector in
                        Button(name) { editBird(loadCase) { $0.direction = vector } }
                    }
                }
                .controlSize(.small).frame(width: 110)
            }
            HStack(spacing: 4) {
                fieldRow("Масса, кг") {
                    numberField("1.81", value: Binding(
                        get: { bird.massKg },
                        set: { value in editBird(loadCase) { $0.massKg = value ?? 1.81 } }), width: 50)
                }
                fieldRow("Скорость, м/с") {
                    numberField("не задана", value: Binding(
                        get: { bird.speedMps },
                        set: { value in editBird(loadCase) { $0.speedMps = value } }), width: 56)
                }
                fieldRow("Угол, °") {
                    numberField("90", value: Binding(
                        get: { bird.obliquityDeg },
                        set: { value in editBird(loadCase) { $0.obliquityDeg = value ?? 90 } }), width: 44)
                }
            }
            dynamicModeFields(
                modeCount: Binding(get: { bird.modeCount.map(Double.init) },
                                   set: { value in editBird(loadCase) { $0.modeCount = value.map { Int($0.rounded()) } } }),
                dampingPercent: Binding(get: { bird.dampingRatio.map { $0 * 100 } },
                                        set: { value in editBird(loadCase) { $0.dampingRatio = value.map { $0 / 100 } } }),
                pickProbe: {})
            note("25.571(e): 1.81 кг (4 фунта) на планер, 3.63 кг (8 фунтов) на оперение. Модель линейно-упругая: за пределом текучести она говорит о необходимости испытания, а не о величине напряжения.")
        }
    }

    private func editEmc(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.EmcSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .emc(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .emc(settings)
        }
    }

    private func editIcing(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.IcingSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .icing(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .icing(settings)
        }
    }

    private func editFlutter(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.FlutterSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .flutter(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .flutter(settings)
        }
    }

    private func editBird(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.BirdSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .bird(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .bird(settings)
        }
    }

    private func editClimate(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.ClimateSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .climate(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .climate(settings)
        }
    }

    private func editFire(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.FireSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .fire(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .fire(settings)
        }
    }

    private func editLightning(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.LightningSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .lightning(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .lightning(settings)
        }
    }

    private func editShock(_ loadCase: WorkbenchStructuralCase, _ mutation: @escaping (inout WorkbenchStructuralCase.ShockSettings) -> Void) {
        viewModel.updateStructuralCase(loadCase.id) { edited in
            guard case var .shock(settings) = edited.analysis else { return }
            mutation(&settings)
            edited.analysis = .shock(settings)
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
