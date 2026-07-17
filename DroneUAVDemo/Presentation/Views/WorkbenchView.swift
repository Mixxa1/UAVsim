import AppKit
import SwiftUI

/// Full-screen Liftoff-inspired editor: category rail on top, interactive
/// assembled model in the center, part carousel below and engineering inspector
/// at the right. All edits update the 3D model and flight estimate immediately.
struct WorkbenchView: View {
    @ObservedObject var viewModel: WorkbenchViewModel
    var onBuildAndTest: (WorkbenchBuild) -> Void
    var onClose: () -> Void

    @State private var importRole: WorkbenchAssemblyRole = .frame
    @State private var importArchitecture: WorkbenchVehicleArchitecture = .multicopter
    @State private var isInspectorVisible = true

    private let accent = GroundControlPalette.accent
    private let shell = GroundControlPalette.shell
    private let panel = GroundControlPalette.panel
    private let raised = GroundControlPalette.panelRaised
    private let inset = GroundControlPalette.inset

    var body: some View {
        ZStack {
            WorkbenchSceneRepresentable(viewModel: viewModel)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        bottomShelf
                            .padding(14)
                    }
                    if isInspectorVisible {
                        inspector
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .background(shell)
        .frame(minWidth: 1120, minHeight: 720)
        .sheet(isPresented: Binding(
            get: { viewModel.pendingImport != nil },
            set: { if !$0 { viewModel.cancelPendingImport() } }
        )) {
            importRoleSheet
        }
    }

    // MARK: Top rail

    private var categories: [WorkbenchCategory] {
        [.overview, .blueprints, .frame]
            + WorkbenchBuild.slotKinds.map { .slot($0) }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Закрыть Workbench")

                VStack(alignment: .leading, spacing: 1) {
                    Text("Мастерская")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("Сборка и проверка UAV")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Divider().frame(height: 30).overlay(Color.white.opacity(0.18))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(categories) { category in
                            categoryButton(category)
                        }
                    }
                }

                Spacer(minLength: 8)

                toolbarButton("square.and.arrow.down", help: "Импорт CADASM / UAVFrame") {
                    importCADAssembly()
                }
                toolbarButton("viewfinder", help: "Вернуть камеру к сборке") {
                    viewModel.resetCamera()
                }
                toolbarButton("sidebar.right", help: isInspectorVisible
                              ? "Скрыть параметры сборки"
                              : "Показать параметры сборки") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isInspectorVisible.toggle()
                    }
                }
                toolbarButton("arrow.uturn.backward", help: "Отменить") {
                    viewModel.undo()
                }
                .disabled(!viewModel.canUndo)

                Button {
                    onBuildAndTest(viewModel.build)
                } label: {
                    Label("Испытать", systemImage: "airplane.departure")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(viewModel.stats.isFlightReady ? accent : Color.gray.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.stats.isFlightReady)
                .help(viewModel.stats.isFlightReady ? "Собрать и запустить в симуляторе"
                      : "Сначала устраните ошибки совместимости")
            }
            .padding(.horizontal, 14)
            .frame(height: 66)

            Rectangle().fill(GroundControlPalette.borderStrong).frame(height: 1)
        }
        .foregroundStyle(.white)
        .background(shell)
        .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
    }

    private func categoryButton(_ category: WorkbenchCategory) -> some View {
        let selected = viewModel.selectedCategory == category
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { viewModel.selectedCategory = category }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                Text(category.displayName)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .white : GroundControlPalette.textSecondary)
            .frame(minWidth: 58, maxWidth: 72, minHeight: 47)
            .padding(.horizontal, 4)
            .background(selected ? accent.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? accent.opacity(0.72) : Color.clear, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(accent).frame(width: 24, height: 2).offset(y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(category.displayName)
    }

    private func toolbarButton(_ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GroundControlPalette.borderStrong))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Bottom shelf

    @ViewBuilder
    private var bottomShelf: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedCategoryTitle.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    Text(shelfSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                Spacer()
                if case .slot(let kind) = viewModel.selectedCategory,
                   viewModel.build.spec(for: kind) != nil {
                    Button("Снять деталь") { viewModel.setSpec(nil, for: kind) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider().overlay(GroundControlPalette.border)

            Group {
                switch viewModel.selectedCategory {
                case .overview:
                    overviewShelf
                case .blueprints:
                    blueprintsShelf
                case .frame:
                    frameShelf
                case let .slot(kind):
                    componentsShelf(kind)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 224)
        .background(panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
    }

    private var shelfSubtitle: String {
        switch viewModel.selectedCategory {
        case .overview: return "Полная комплектация и быстрые действия"
        case .blueprints: return "Сохранённые удачные сборки"
        case .frame: return "Выберите базовую геометрию аппарата"
        case let .slot(kind): return "Каждая карточка — отдельная 3D-модель · \(kind.displayName)"
        }
    }

    private var overviewShelf: some View {
        HStack(spacing: 12) {
            newAircraftMenu
            quickAction("square.stack.3d.up.fill", "В каталог", "Сохранить в «Пользовательские»") {
                viewModel.saveFavorite()
            }
            quickAction("doc.badge.arrow.up", "Экспорт", ".uavbuild с CAD-мешами") {
                exportBlueprint()
            }
            quickAction("folder", "Открыть файл", "Импорт Blueprint с диска") {
                openBlueprint()
            }
            Spacer()
        }
        .padding(16)
    }

    private var newAircraftMenu: some View {
        Menu {
            Button("Мультиротор", systemImage: "circle.grid.cross") {
                viewModel.newBuild(.multicopter)
            }
            Button("Самолёт", systemImage: "airplane") {
                viewModel.newBuild(.fixedWing)
            }
            Button("Lift + Cruise VTOL", systemImage: "airplane.circle") {
                viewModel.newBuild(.liftCruiseVTOL)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Новый аппарат").font(.system(size: 12, weight: .bold))
                    Text("Коптер · самолёт · VTOL")
                        .font(.system(size: 9))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 14)
            .frame(width: 190, height: 72, alignment: .leading)
            .background(raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(GroundControlPalette.borderStrong))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func quickAction(
        _ icon: String, _ title: String, _ subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .bold))
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 14)
            .frame(width: 190, height: 72, alignment: .leading)
            .background(raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(GroundControlPalette.borderStrong))
        }
        .buttonStyle(.plain)
    }

    private var frameShelf: some View {
        horizontalCards {
            ForEach(WorkbenchFrameLibrary.all) { frame in
                frameCard(frame)
            }
        }
    }

    private func componentsShelf(_ kind: WorkbenchComponentKind) -> some View {
        horizontalCards {
            ForEach(viewModel.components(for: kind)) { component in
                componentCard(component, kind: kind)
            }
            importCard(kind: kind)
        }
    }

    private func horizontalCards<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private func frameCard(_ frame: WorkbenchFrameSpec) -> some View {
        let selected = viewModel.selectedLibraryFrameID == frame.id
        let candidate = frameCandidateStats(frame)
        return Button { viewModel.selectLibraryFrame(frame.id) } label: {
            partCardShell(selected: selected, hasError: !candidate.errors.isEmpty) {
                WorkbenchPartPreview(frame: frame)
            } title: {
                Text(frame.name)
            } detail: {
                Text("\(frame.frameClass.displayName) · \(Int(frame.massKg * 1000)) г")
            }
        }
        .buttonStyle(.plain)
    }

    private func componentCard(
        _ component: WorkbenchComponentSpec,
        kind: WorkbenchComponentKind
    ) -> some View {
        let selected = viewModel.selectedSpecID(for: kind) == component.id
        let candidate = componentCandidateStats(component, kind: kind)
        return Button { viewModel.setSpec(component.id, for: kind) } label: {
            partCardShell(selected: selected, hasError: !candidate.errors.isEmpty) {
                WorkbenchPartPreview(component: component)
            } title: {
                Text(component.displayName)
            } detail: {
                Text("\(component.sourceBadge) · \(Int(component.massKg * 1000)) г")
            }
        }
        .buttonStyle(.plain)
    }

    private func partCardShell<Preview: View, Title: View, Detail: View>(
        selected: Bool,
        hasError: Bool,
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder title: () -> Title,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                inset
                preview().padding(8)
                Image(systemName: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hasError ? .orange : accent)
                    .padding(8)
            }
            .frame(height: 105)

            VStack(alignment: .leading, spacing: 3) {
                title().font(.system(size: 11, weight: .bold)).lineLimit(1)
                detail().font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .frame(width: 178, height: 158)
        .background(selected ? accent.opacity(0.16) : raised,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(selected ? accent : GroundControlPalette.borderStrong,
                    lineWidth: selected ? 2 : 1))
    }

    private func importCard(kind: WorkbenchComponentKind) -> some View {
        Button { importCADAssembly(preferredRole: .component(kind)) } label: {
            VStack(spacing: 9) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(accent)
                Text("Импорт CADNext")
                    .font(.caption.weight(.bold))
                Text(".cadasm / .uavframe")
                    .font(.system(size: 9))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .frame(width: 160, height: 156)
            .background(raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(accent.opacity(0.58), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }

    private var blueprintsShelf: some View {
        horizontalCards {
            Button { viewModel.saveFavorite() } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(accent)
                    Text("Сохранить в каталог")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(width: 160, height: 156)
                .background(raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(accent.opacity(0.58), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .buttonStyle(.plain)

            ForEach(viewModel.blueprints) { blueprint in
                blueprintCard(blueprint)
            }
        }
    }

    private func blueprintCard(_ blueprint: WorkbenchBlueprintSummary) -> some View {
        Button { viewModel.loadBlueprint(blueprint) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: [accent.opacity(0.16), inset],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(accent)
                }
                .frame(height: 82)
                Text(blueprint.name).font(.system(size: 11, weight: .bold)).lineLimit(1)
                Text("\(blueprint.frameName) · \(blueprint.componentCount) деталей")
                    .font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary).lineLimit(1)
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(9)
            .frame(width: 190, height: 158, alignment: .topLeading)
            .background(raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(GroundControlPalette.borderStrong))
            .contextMenu {
                Button("Удалить", role: .destructive) { viewModel.deleteBlueprint(blueprint) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Параметры сборки")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Text(viewModel.selectedCategoryTitle)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    readinessBadge
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isInspectorVisible = false
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(raised, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Скрыть параметры сборки")
                }

                switch viewModel.selectedCategory {
                case .overview, .blueprints:
                    buildInspector
                case .frame:
                    frameInspector
                case .slot:
                    componentInspector
                }

                compatibilityInspector

                Text(viewModel.statusMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(GroundControlPalette.textPrimary)
        .background(panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(GroundControlPalette.borderStrong).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 10, x: -4)
    }

    private var readinessBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(viewModel.stats.isFlightReady ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(viewModel.stats.isFlightReady ? "Готово" : "Проверка")
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(raised, in: Capsule())
        .overlay(Capsule().stroke(GroundControlPalette.borderStrong))
    }

    private var buildInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorSection("Название", icon: "pencil") {
                TextField("Название сборки", text: Binding(
                    get: { viewModel.build.name }, set: viewModel.rename))
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(inset, in: RoundedRectangle(cornerRadius: 6))

                TextField("Описание", text: Binding(
                    get: { viewModel.build.buildDescription }, set: viewModel.setDescription), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(inset, in: RoundedRectangle(cornerRadius: 6))
            }
            inspectorSection("Характеристики", icon: "gauge.with.dots.needle.67percent") {
                statRow("Тип аппарата", viewModel.build.vehicleArchitecture.displayName)
                statRow("Рама", viewModel.frameName)
                statRow("Взлётная масса", formatMass(viewModel.stats.totalMassKg))
                statRow("Макс. тяга", String(format: "%.1f Н", viewModel.stats.totalMaxThrustN))
                statRow("Тяга / вес", String(format: "%.2f", viewModel.stats.thrustToWeight))
                statRow("Макс. RPM", formatNumber(viewModel.stats.maxRPM))
                statRow("Расчётная скорость", String(format: "%.1f м/с", viewModel.stats.estimatedMaxSpeedMps))
                statRow(viewModel.build.vehicleArchitecture == .fixedWing
                        ? "Время полёта" : "Время висения",
                        String(format: "%.1f мин", viewModel.stats.estimatedHoverTimeMin))
            }
        }
    }

    private var frameInspector: some View {
        let frame = viewModel.build.resolvedFrame
        return inspectorSection("Установленная рама", icon: "square.on.square.intersection.dashed") {
            Text(frame.name).font(.system(size: 15, weight: .bold))
            statRow("Архитектура", frame.architecture.displayName)
            statRow("Класс", frame.frameClass.displayName)
            statRow("Силовых установок", "\(frame.motorMounts.count)")
            if frame.architecture == .liftCruiseVTOL {
                statRow("Подъёмных моторов", "\(frame.liftMotorCount)")
            }
            if !frame.servoMounts.isEmpty {
                statRow("Сервоприводов", "\(frame.servoMounts.count)")
            }
            statRow("Макс. пропеллер", String(format: "%.1f\"", frame.propMaxInch))
            statRow("Макс. статор", String(format: "%.0f мм", frame.motorStatorMaxMm))
            statRow("Масса", formatMass(frame.massKg))
            if case .imported = viewModel.build.frame {
                Label("3D-геометрия CADNext встроена в Blueprint", systemImage: "cube.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            }
        }
    }

    @ViewBuilder
    private var componentInspector: some View {
        if let component = viewModel.selectedComponent {
            inspectorSection(component.brand, icon: component.kind.symbolName) {
                Text(component.displayName).font(.system(size: 15, weight: .bold))
                if !component.summary.isEmpty {
                    Text(component.summary).font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
                }
                statRow("Масса", formatMass(component.massKg))
                VStack(alignment: .leading, spacing: 5) {
                    Text("МЕСТО УСТАНОВКИ")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    if component.kind == .motor || component.kind == .propeller {
                        Text("Повторяется во всех силовых точках выбранной рамы.")
                            .font(.system(size: 9))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    } else if component.kind == .servo,
                              !viewModel.build.resolvedFrame.servoMounts.isEmpty {
                        Text("Повторяется в \(viewModel.build.resolvedFrame.servoMounts.count) точках рулевых поверхностей.")
                            .font(.system(size: 9))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    } else {
                        Picker("Место установки", selection: Binding(
                            get: { viewModel.mountSurface(for: component.kind) },
                            set: { viewModel.setMountSurface($0, for: component.kind) }
                        )) {
                            ForEach(WorkbenchMountSurface.allCases) { surface in
                                Text(surface.displayName).tag(surface)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if component.kind == .battery {
                            Text("АКБ можно закрепить сверху или снизу; раскладчик добавит салазки, ремни и безопасный зазор.")
                                .font(.system(size: 9))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                    }
                }
                ForEach(componentProperties(component), id: \.0) { property in
                    statRow(property.0, property.1)
                }
                if component.importedMesh != nil {
                    Label("Точная 3D-модель CADNext", systemImage: "cube.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                }
            }
        } else {
            inspectorSection("Слот свободен", icon: "plus.circle") {
                Text("Выберите деталь в нижней карусели или импортируйте собственную сборку CADNext.")
                    .font(.system(size: 11)).foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }

    private var compatibilityInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Совместимость")
                .font(.caption.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            if viewModel.stats.errors.isEmpty && viewModel.stats.warnings.isEmpty {
                issueRow("Все детали совместимы", icon: "checkmark.seal.fill", color: .green)
            }
            ForEach(viewModel.stats.errors, id: \.self) {
                issueRow($0, icon: "xmark.octagon.fill", color: .red)
            }
            ForEach(viewModel.stats.warnings, id: \.self) {
                issueRow($0, icon: "exclamationmark.triangle.fill", color: .orange)
            }
        }
        .padding(12)
        .background(raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func inspectorSection<Content: View>(
        _ title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            content()
        }
        .padding(12)
        .background(raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(GroundControlPalette.textSecondary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 10, weight: .semibold)).multilineTextAlignment(.trailing)
        }
    }

    private func issueRow(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 11)).padding(.top, 1)
            Text(text).font(.system(size: 10, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Import role sheet

    private var importRoleSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 32)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Назначить роль CAD-сборке").font(.title2.bold())
                    Text(viewModel.pendingImport?.sourceURL.lastPathComponent ?? "CADNext")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let imported = viewModel.pendingImport {
                HStack(spacing: 14) {
                    Label(formatMass(imported.construction.massKg), systemImage: "scalemass")
                    Label("\(imported.construction.mesh.indices.count / 3) треугольников", systemImage: "triangle")
                    if imported.isApproximate {
                        Label("3D-прокси", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            Text("Роль определяет точку установки, расчёт массы и правила совместимости.")
                .font(.callout).foregroundStyle(.secondary)

            if importRole == .frame {
                Picker("Архитектура аппарата", selection: $importArchitecture) {
                    ForEach(WorkbenchVehicleArchitecture.allCases, id: \.self) { architecture in
                        Text(architecture.displayName).tag(architecture)
                    }
                }
                .pickerStyle(.segmented)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(WorkbenchAssemblyRole.all) { role in
                        Button { importRole = role } label: {
                            HStack(spacing: 9) {
                                Image(systemName: role.symbolName).frame(width: 20)
                                Text(role.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if role == importRole { Image(systemName: "checkmark.circle.fill") }
                            }
                            .padding(10)
                            .background(role == importRole ? accent.opacity(0.22) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(role == importRole ? accent : Color.primary.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)

            if let notice = viewModel.pendingImport?.notice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Отмена") { viewModel.cancelPendingImport() }
                Button("Добавить в сборку") {
                    viewModel.applyPendingImport(
                        as: importRole,
                        frameArchitecture: importRole == .frame ? importArchitecture : nil)
                }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(24)
        .frame(width: 620, height: 560)
    }

    // MARK: Helpers

    private func componentProperties(_ component: WorkbenchComponentSpec) -> [(String, String)] {
        let p = WorkbenchComponentSpec.ParamKey.self
        var result: [(String, String)] = []
        switch component.kind {
        case .motor:
            if let value = component.param(p.motorKv) { result.append(("KV", String(format: "%.0f", value))) }
            if let value = component.param(p.motorStatorMm) { result.append(("Статор", String(format: "%.0f мм", value))) }
            if let value = component.param(p.motorMaxPowerW) { result.append(("Мощность", String(format: "%.0f Вт", value))) }
            if let value = component.param(p.motorMaxThrustN) { result.append(("Тяга", String(format: "%.1f Н", value))) }
        case .propeller:
            if let diameter = component.param(p.propDiameterInch),
               let pitch = component.param(p.propPitchInch) {
                result.append(("Размер", String(format: "%.1f × %.1f\"", diameter, pitch)))
            }
            if let blades = component.param(p.propBladeCount) { result.append(("Лопасти", String(format: "%.0f", blades))) }
        case .battery:
            if let cells = component.param(p.batteryCells) { result.append(("Напряжение", String(format: "%.0fS · %.1f В", cells, cells * 3.7))) }
            if let capacity = component.param(p.batteryCapacityMah) { result.append(("Ёмкость", String(format: "%.0f мА·ч", capacity))) }
            if let energy = component.param(p.batteryEnergyWh) { result.append(("Энергия", String(format: "%.1f Вт·ч", energy))) }
            if let cRating = component.param(p.batteryContinuousC) { result.append(("Токоотдача", String(format: "%.0fC", cRating))) }
            if let length = component.param(p.batteryLengthMm),
               let width = component.param(p.batteryWidthMm),
               let height = component.param(p.batteryHeightMm) {
                result.append(("Габариты", String(format: "%.0f×%.0f×%.0f мм", length, width, height)))
            }
        case .esc:
            if let current = component.param(p.escMaxCurrentA) { result.append(("Макс. ток", String(format: "%.0f A", current))) }
            if let minimum = component.param(p.escMinCells),
               let maximum = component.param(p.escMaxCells) {
                result.append(("Питание", String(format: "%.0f–%.0fS", minimum, maximum)))
            }
        case .servo:
            if let torque = component.param(p.servoTorqueNm) { result.append(("Момент", String(format: "%.2f Н·м", torque))) }
            if let speed = component.param(p.servoSpeedSec60) { result.append(("Скорость", String(format: "%.3f с/60°", speed))) }
            if let minimum = component.param(p.servoMinVolts),
               let maximum = component.param(p.servoMaxVolts) {
                result.append(("Питание", String(format: "%.1f–%.1f В", minimum, maximum)))
            }
        case .flightController:
            if let mount = component.param(p.flightControllerMountMm) { result.append(("Монтаж", String(format: "%.1f×%.1f мм", mount, mount))) }
            if let uarts = component.param(p.flightControllerUartCount) { result.append(("UART", String(format: "%.0f", uarts))) }
        case .receiver:
            if let frequency = component.param(p.receiverFrequencyMHz) { result.append(("Частота", String(format: "%.0f МГц", frequency))) }
            if let range = component.param(p.receiverRangeKm) { result.append(("Дальность", String(format: "%.0f км", range))) }
        case .camera:
            if let fov = component.param(p.cameraFovDegrees) { result.append(("Угол обзора", String(format: "%.0f°", fov))) }
            if let resolution = component.param(p.cameraResolutionMP) { result.append(("Матрица", String(format: "%.1f Мп", resolution))) }
        case .gps:
            if let accuracy = component.param(p.gpsAccuracyM) { result.append(("Точность", String(format: "%.2f м", accuracy))) }
            if let frequency = component.param(p.gpsUpdateHz) { result.append(("Обновление", String(format: "%.0f Гц", frequency))) }
        case .sensor:
            if let range = component.param(p.sensorRangeM), range > 0 { result.append(("Дальность", String(format: "%.0f м", range))) }
            if let fov = component.param(p.sensorFovDegrees) { result.append(("Поле зрения", String(format: "%.0f°", fov))) }
        case .payload:
            if let power = component.param(p.payloadPowerW) { result.append(("Потребление", String(format: "%.1f Вт", power))) }
            if let range = component.param(p.sensorRangeM) { result.append(("Дальность", String(format: "%.0f м", range))) }
        case .landingGear:
            if let clearance = component.param(p.landingGearClearanceMm) { result.append(("Клиренс", String(format: "%.0f мм", clearance))) }
        }
        return result
    }

    private func componentCandidateStats(
        _ component: WorkbenchComponentSpec,
        kind: WorkbenchComponentKind
    ) -> WorkbenchBuildStats {
        var candidate = viewModel.build
        if WorkbenchComponentLibrary.spec(id: component.id) == nil,
           !candidate.customComponents.contains(where: { $0.id == component.id }) {
            candidate.customComponents.append(component)
        }
        candidate.setSpec(component.id, for: kind)
        return WorkbenchBuildAnalyzer.analyze(candidate)
    }

    private func frameCandidateStats(_ frame: WorkbenchFrameSpec) -> WorkbenchBuildStats {
        var candidate = viewModel.build
        candidate.frame = .library(id: frame.id)
        candidate.vehicleArchitecture = frame.architecture
        return WorkbenchBuildAnalyzer.analyze(candidate)
    }

    private func formatMass(_ kilograms: Double) -> String {
        kilograms < 1 ? String(format: "%.0f г", kilograms * 1000) : String(format: "%.2f кг", kilograms)
    }

    private func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private func importCADAssembly(preferredRole: WorkbenchAssemblyRole = .frame) {
        let panel = NSOpenPanel()
        panel.title = "Открыть 3D-сборку CADNext"
        panel.message = "Выберите .cadasm или точный экспорт .uavframe"
        panel.allowedFileTypes = ["cadasm", "uavframe"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRole = preferredRole
        importArchitecture = viewModel.build.vehicleArchitecture
        viewModel.prepareImport(from: url)
    }

    private func openBlueprint() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = [WorkbenchBuildStore.fileExtension]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { viewModel.loadBlueprint(from: url) }
    }

    private func exportBlueprint() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = viewModel.build.name + "." + WorkbenchBuildStore.fileExtension
        panel.allowedFileTypes = [WorkbenchBuildStore.fileExtension]
        if panel.runModal() == .OK, let url = panel.url { viewModel.save(to: url) }
    }
}
