import Foundation
import SwiftUI

enum WorkbenchCategory: Hashable, Identifiable {
    case overview
    case blueprints
    case frame
    case radio
    case slot(WorkbenchComponentKind)

    var id: String {
        switch self {
        case .overview: return "overview"
        case .blueprints: return "blueprints"
        case .frame: return "frame"
        case .radio: return "radio"
        case let .slot(kind): return "slot.\(kind.rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .overview: return "Сборка"
        case .blueprints: return "Пользовательские"
        case .frame: return "Рама"
        case .radio: return "RF-система"
        case let .slot(kind): return kind.shortName
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "list.bullet.rectangle"
        case .blueprints: return "square.stack.3d.up.fill"
        case .frame: return "square.on.square.intersection.dashed"
        case .radio: return "antenna.radiowaves.left.and.right"
        case let .slot(kind): return kind.symbolName
        }
    }
}

enum WorkbenchAssemblyRole: Hashable, Identifiable {
    case frame
    case component(WorkbenchComponentKind)

    var id: String {
        switch self {
        case .frame: return "frame"
        case let .component(kind): return "component.\(kind.rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .frame: return "Рама аппарата"
        case let .component(kind): return kind.displayName
        }
    }

    var symbolName: String {
        switch self {
        case .frame: return "square.on.square.intersection.dashed"
        case let .component(kind): return kind.symbolName
        }
    }

    static let all: [WorkbenchAssemblyRole] = [.frame]
        + WorkbenchComponentKind.allCases.map { .component($0) }
}

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published private(set) var build: WorkbenchBuild
    @Published private(set) var stats: WorkbenchBuildStats
    @Published var selectedCategory: WorkbenchCategory = .overview
    @Published var statusMessage = "Выберите категорию или нажмите на деталь в 3D-сцене."
    @Published private(set) var blueprints: [WorkbenchBlueprintSummary] = []
    @Published private(set) var cameraResetToken = 0
    @Published var pendingImport: WorkbenchConstructionImport?
    @Published var selectedRFLinkKind: LogicalLinkKind = .control

    private var undoStack: [Data] = []
    private let undoDepth = 50

    init(build: WorkbenchBuild = .defaultQuad()) {
        self.build = build
        stats = Self.resolvedStats(for: build)
        refreshBlueprints()
    }

    var frameName: String { build.resolvedFrame.name }

    var selectedLibraryFrameID: String? {
        if case let .library(id) = build.frame { return id }
        return nil
    }

    var selectedComponent: WorkbenchComponentSpec? {
        guard case let .slot(kind) = selectedCategory else { return nil }
        return build.spec(for: kind)
    }

    var selectedCategoryTitle: String { selectedCategory.displayName }

    var canUndo: Bool { !undoStack.isEmpty }

    var rfConfigurationIssues: [RFConfigurationIssue] {
        RFSystemConfigurationValidator().validate(build.rfSystem)
    }

    var selectedRFLink: RFLinkConfiguration? {
        build.rfSystem.logicalLinks.link(for: selectedRFLinkKind)
    }

    var activeRFQoS: RFQoSConfiguration {
        build.rfSystem.qos ?? .migrationDefault
    }

    func rfDevice(id: String) -> RFDeviceInstance? {
        build.rfSystem.devices.first(where: { $0.id == id })
    }

    func rfAntenna(id: String) -> RFAntennaInstance? {
        build.rfSystem.antennas.first(where: { $0.id == id })
    }

    func groundRFDevice(for kind: LogicalLinkKind) -> RFDeviceInstance? {
        guard let link = build.rfSystem.logicalLinks.link(for: kind) else { return nil }
        return [link.transmitterDeviceID, link.receiverDeviceID]
            .compactMap { rfDevice(id: $0) }
            .first(where: { $0.endpoint == .ground || $0.endpoint == .relay })
    }

    func rfSupportedBandwidths(for kind: LogicalLinkKind) -> [Double] {
        guard let link = build.rfSystem.logicalLinks.link(for: kind),
              let transmitter = rfDevice(id: link.transmitterDeviceID),
              let receiver = rfDevice(id: link.receiverDeviceID) else { return [] }
        if transmitter.profile.supportedBandwidthsHz.isEmpty {
            return receiver.profile.supportedBandwidthsHz.sorted()
        }
        if receiver.profile.supportedBandwidthsHz.isEmpty {
            return transmitter.profile.supportedBandwidthsHz.sorted()
        }
        return transmitter.profile.supportedBandwidthsHz.filter { bandwidth in
            receiver.profile.supportedBandwidthsHz.contains(where: {
                abs($0 - bandwidth) <= max(1, bandwidth * 0.001)
            })
        }.sorted()
    }

    func components(for kind: WorkbenchComponentKind) -> [WorkbenchComponentSpec] {
        build.availableComponents(for: kind)
    }

    func selectedSpecID(for kind: WorkbenchComponentKind) -> String? {
        build.specID(for: kind)
    }

    func mountSurface(for kind: WorkbenchComponentKind) -> WorkbenchMountSurface {
        // Reflect the actually resolved physical zone. This keeps a legacy
        // Blueprint that requested an unsafe GPS/RX/battery face from leaving
        // a SwiftUI Picker with a value that is no longer offered by the UI.
        WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)[kind]?.surface
            ?? build.placement(for: kind).surface
    }

    // MARK: Mutations

    func selectRFLink(_ kind: LogicalLinkKind) {
        selectedRFLinkKind = kind
        statusMessage = "Выбран RF-канал \(kind.rawValue.uppercased())."
    }

    func resetRFCompatibilityPreset() {
        pushUndo()
        build.rfSystem = RFCompatibilityPreset.make(for: build)
        build.revision += 1
        recompute()
        statusMessage = "RF-система восстановлена из compatibility preset."
    }

    func setRFFrequencyMHz(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("Частота \(kind.rawValue.uppercased()) обновлена.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            let frequencyHz = max(0, value) * 1_000_000
            for id in [link.transmitterDeviceID, link.receiverDeviceID] {
                guard let index = configuration.devices.firstIndex(where: { $0.id == id }) else { continue }
                configuration.devices[index].centerFrequencyHz = frequencyHz
            }
        }
    }

    func setRFBandwidthHz(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("Полоса \(kind.rawValue.uppercased()) обновлена.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            for id in [link.transmitterDeviceID, link.receiverDeviceID] {
                guard let index = configuration.devices.firstIndex(where: { $0.id == id }) else { continue }
                configuration.devices[index].bandwidthHz = max(1, value)
            }
        }
    }

    func setRFTxPowerDBm(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("Мощность TX \(kind.rawValue.uppercased()) обновлена.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind),
                  let index = configuration.devices.firstIndex(where: {
                      $0.id == link.transmitterDeviceID
                  }) else { return }
            let maximum = configuration.devices[index].profile.maxTxPowerDBm ?? value
            configuration.devices[index].txPowerDBm = min(maximum, value)
        }
    }

    func setRFNominalBitrateBPS(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("Bitrate \(kind.rawValue.uppercased()) обновлён.") { configuration in
            configuration.mutateLink(kind) { link in
                link.qualityProfile.nominalBitrateBps = max(1, value)
            }
        }
    }

    func setRFRequiredSINRDB(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("SINR threshold \(kind.rawValue.uppercased()) обновлён.") { configuration in
            configuration.mutateLink(kind) { link in
                link.qualityProfile.requiredSINRDB = value
            }
        }
    }

    func setRFVideoMode(_ mode: RFVideoTransmissionMode) {
        mutateRF("Режим видеолинка обновлён: \(mode.rawValue).") { configuration in
            configuration.mutateLink(.video) { $0.videoMode = mode }
        }
    }

    func setRFAntennaGainDBi(
        _ value: Double,
        for kind: LogicalLinkKind,
        transmitter: Bool
    ) {
        mutateRF("Усиление антенны обновлено.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            let id = transmitter ? link.transmitterAntennaID : link.receiverAntennaID
            guard let index = configuration.antennas.firstIndex(where: { $0.id == id }) else { return }
            configuration.antennas[index].profile.peakGainDBi = value
        }
    }

    func setRFAntennaPolarization(
        _ value: RFPolarization,
        for kind: LogicalLinkKind,
        transmitter: Bool
    ) {
        mutateRF("Поляризация антенны обновлена.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            let id = transmitter ? link.transmitterAntennaID : link.receiverAntennaID
            guard let index = configuration.antennas.firstIndex(where: { $0.id == id }) else { return }
            configuration.antennas[index].profile.polarization = value
        }
    }

    func setRFAntennaDamage(
        _ value: Double,
        for kind: LogicalLinkKind,
        transmitter: Bool
    ) {
        mutateRF("Состояние антенны обновлено.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            let id = transmitter ? link.transmitterAntennaID : link.receiverAntennaID
            guard let index = configuration.antennas.firstIndex(where: { $0.id == id }) else { return }
            configuration.antennas[index].damageFraction = min(1, max(0, value))
        }
    }

    func setRFAntennaTransform(
        x: Double? = nil,
        y: Double? = nil,
        z: Double? = nil,
        yawDegrees: Double? = nil,
        pitchDegrees: Double? = nil,
        rollDegrees: Double? = nil,
        for kind: LogicalLinkKind,
        transmitter: Bool
    ) {
        mutateRF("Физический transform антенны обновлён.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            let id = transmitter ? link.transmitterAntennaID : link.receiverAntennaID
            guard let index = configuration.antennas.firstIndex(where: { $0.id == id }) else { return }
            if let x { configuration.antennas[index].mountPositionM.x = x }
            if let y { configuration.antennas[index].mountPositionM.y = y }
            if let z { configuration.antennas[index].mountPositionM.z = z }
            if let yawDegrees { configuration.antennas[index].orientation.yawDegrees = yawDegrees }
            if let pitchDegrees { configuration.antennas[index].orientation.pitchDegrees = pitchDegrees }
            if let rollDegrees { configuration.antennas[index].orientation.rollDegrees = rollDegrees }
        }
    }

    func setRFQoSDynamicReservation(_ enabled: Bool) {
        mutateRF("Динамическое QoS-резервирование обновлено.") { configuration in
            var qos = configuration.qos ?? .migrationDefault
            qos.dynamicReservationEnabled = enabled
            configuration.qos = qos
        }
    }

    func setRFQoSBorrowing(_ enabled: Bool) {
        mutateRF("QoS borrowing обновлён.") { configuration in
            var qos = configuration.qos ?? .migrationDefault
            qos.reservationBorrowingEnabled = enabled
            configuration.qos = qos
        }
    }

    func setRFQoSControlBoostAge(_ seconds: Double) {
        mutateRF("Порог CONTROL boost обновлён.") { configuration in
            var qos = configuration.qos ?? .migrationDefault
            qos.controlBoostCommandAgeSeconds = max(0, seconds)
            configuration.qos = qos
        }
    }

    func setRFQoSControlBoostMultiplier(_ multiplier: Double) {
        mutateRF("Множитель CONTROL boost обновлён.") { configuration in
            var qos = configuration.qos ?? .migrationDefault
            qos.controlBoostMultiplier = max(1, multiplier)
            configuration.qos = qos
        }
    }

    func setRFQoSPriority(_ priority: Int, for kind: LogicalLinkKind) {
        mutateRF("QoS priority \(kind.rawValue.uppercased()) обновлён.") { configuration in
            configuration.mutateQoSPolicy(kind) { $0.priority = max(0, priority) }
        }
    }

    func setRFQoSReserveBPS(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("QoS reserve \(kind.rawValue.uppercased()) обновлён.") { configuration in
            configuration.mutateQoSPolicy(kind) {
                $0.minimumReservedBitrateBPS = max(0, value)
            }
        }
    }

    func setRFQoSMaximumShare(_ value: Double, for kind: LogicalLinkKind) {
        mutateRF("QoS share \(kind.rawValue.uppercased()) обновлён.") { configuration in
            configuration.mutateQoSPolicy(kind) {
                $0.maximumShareFraction = min(1, max(0, value))
            }
        }
    }

    func setRFGroundPlacement(
        x: Double? = nil,
        y: Double? = nil,
        z: Double? = nil,
        yawDegrees: Double? = nil,
        for kind: LogicalLinkKind
    ) {
        mutateRF("Положение наземной RF-станции обновлено.") { configuration in
            guard let link = configuration.logicalLinks.link(for: kind) else { return }
            let deviceID = [link.transmitterDeviceID, link.receiverDeviceID]
                .compactMap { id in configuration.devices.first(where: { $0.id == id }) }
                .first(where: { $0.endpoint == .ground || $0.endpoint == .relay })?.id
            guard let deviceID else { return }
            var placements = configuration.endpointPlacements ?? [:]
            var placement = placements[deviceID] ?? .atHome
            if let x { placement.offsetFromHomeM.x = x }
            if let y { placement.offsetFromHomeM.y = max(0, y) }
            if let z { placement.offsetFromHomeM.z = z }
            if let yawDegrees { placement.orientation.yawDegrees = yawDegrees }
            placements[deviceID] = placement
            configuration.endpointPlacements = placements
        }
    }

    private func mutateRF(
        _ message: String,
        mutation: (inout RFSystemConfiguration) -> Void
    ) {
        pushUndo()
        var configuration = build.rfSystem
        mutation(&configuration)
        configuration.origin = .authored
        if configuration.qos == nil { configuration.qos = .migrationDefault }
        build.rfSystem = configuration
        build.revision += 1
        recompute()
        statusMessage = message
    }

    func selectLibraryFrame(_ id: String) {
        guard selectedLibraryFrameID != id else { return }
        pushUndo()
        build.frame = .library(id: id)
        if let frame = WorkbenchFrameLibrary.spec(id: id) {
            build.vehicleArchitecture = frame.architecture
        }
        build.revision += 1
        recompute()
        statusMessage = "Установлена рама «\(build.resolvedFrame.name)»."
    }

    func setSpec(_ id: String?, for kind: WorkbenchComponentKind) {
        guard build.specID(for: kind) != id else { return }
        pushUndo()
        build.setSpec(id, for: kind)
        recompute()
        if let spec = build.spec(for: kind) {
            statusMessage = "\(kind.displayName): \(spec.displayName)."
        } else {
            statusMessage = "\(kind.displayName): слот освобождён."
        }
    }

    func setMountSurface(_ surface: WorkbenchMountSurface, for kind: WorkbenchComponentKind) {
        guard build.placement(for: kind).surface != surface else { return }
        pushUndo()
        build.setMountSurface(surface, for: kind)
        recompute()
        statusMessage = "\(kind.displayName): монтаж — \(surface.displayName.lowercased())."
    }

    func rename(_ name: String) {
        guard build.name != name else { return }
        build.name = name
    }

    func setDescription(_ description: String) {
        guard build.buildDescription != description else { return }
        build.buildDescription = description
    }

    func newBuild(_ architecture: WorkbenchVehicleArchitecture = .multicopter) {
        pushUndo()
        switch architecture {
        case .multicopter: build = .defaultQuad()
        case .fixedWing: build = .defaultFixedWing()
        case .liftCruiseVTOL: build = .defaultVTOL()
        }
        build.id = UUID()
        build.revision += 1
        selectedCategory = .overview
        recompute()
        statusMessage = "Создан новый аппарат: \(architecture.displayName)."
    }

    func undo() {
        guard let data = undoStack.popLast(),
              var restored = WorkbenchBuildStore.restore(from: data) else { return }
        restored.revision = build.revision + 1
        build = restored
        recompute()
        statusMessage = "Последнее изменение отменено."
    }

    func resetCamera() {
        cameraResetToken += 1
        statusMessage = "Камера возвращена к сборке."
    }

    private func recompute() {
        stats = Self.resolvedStats(for: build)
    }

    /// Analyzer totals retain every propulsion unit for electrical sizing.
    /// In a lift+cruise aircraft the forward propeller cannot contribute to
    /// hover, so the inspector/readiness values must use only lift rotors.
    private static func resolvedStats(for build: WorkbenchBuild) -> WorkbenchBuildStats {
        var result = WorkbenchBuildAnalyzer.analyze(build)
        let frame = build.resolvedFrame
        guard frame.architecture == .liftCruiseVTOL else { return result }

        let p = WorkbenchComponentSpec.ParamKey.self
        let singleThrust = build.spec(for: .motor)?.param(p.motorMaxThrustN) ?? 0
        result.totalMaxThrustN = singleThrust * Double(frame.liftMotorCount)
        let weight = result.totalMassKg * 9.80665
        result.thrustToWeight = weight > 0 ? result.totalMaxThrustN / weight : 0

        if result.batteryEnergyWh > 0,
           let motorPower = build.spec(for: .motor)?.param(p.motorMaxPowerW),
           motorPower > 0,
           frame.liftMotorCount > 0,
           result.thrustToWeight > 0 {
            let hoverThrottle = sqrt(min(1, 1 / result.thrustToWeight))
            let hoverPower = motorPower * Double(frame.liftMotorCount)
                * pow(hoverThrottle, 1.55)
            result.estimatedHoverTimeMin = result.batteryEnergyWh
                / max(hoverPower, 1) * 60 * 0.82
        }
        return result
    }

    private func pushUndo() {
        if let data = WorkbenchBuildStore.snapshot(build) {
            undoStack.append(data)
            if undoStack.count > undoDepth { undoStack.removeFirst() }
        }
    }

    // MARK: CAD import and role assignment

    func prepareImport(from url: URL) {
        do {
            pendingImport = try WorkbenchConstruction.load(from: url)
            statusMessage = "3D-сборка загружена. Назначьте ей роль в аппарате."
        } catch {
            pendingImport = nil
            statusMessage = "Не удалось открыть CAD-сборку: \(error.localizedDescription)"
        }
    }

    func applyPendingImport(
        as role: WorkbenchAssemblyRole,
        frameArchitecture: WorkbenchVehicleArchitecture? = nil
    ) {
        guard let imported = pendingImport else { return }
        pushUndo()
        switch role {
        case .frame:
            if let frameArchitecture {
                build.vehicleArchitecture = frameArchitecture
            }
            build.frame = .imported(imported.construction)
            build.revision += 1
            selectedCategory = .frame
            statusMessage = "Сборка «\(imported.construction.name)» назначена рамой."
        case let .component(kind):
            let component = makeComponent(from: imported.construction, kind: kind,
                                          sourceName: imported.sourceURL.lastPathComponent)
            build.installImportedComponent(component)
            selectedCategory = .slot(kind)
            statusMessage = "CAD-сборка назначена как «\(kind.displayName)»."
        }
        if let notice = imported.notice { statusMessage += " \(notice)" }
        pendingImport = nil
        recompute()
    }

    func cancelPendingImport() { pendingImport = nil }

    private func makeComponent(
        from construction: WorkbenchConstruction,
        kind: WorkbenchComponentKind,
        sourceName: String
    ) -> WorkbenchComponentSpec {
        let cadSize = construction.dimensionsMeters
        let sceneSize = CodableVector3D(
            x: max(cadSize.x, 0.005),
            y: max(cadSize.z, 0.005),
            z: max(cadSize.y, 0.005))
        return WorkbenchComponentSpec(
            id: "cad-\(kind.rawValue)-\(UUID().uuidString)",
            kind: kind,
            brand: "CADNext",
            displayName: construction.name.isEmpty ? sourceName : construction.name,
            summary: "Импортировано из \(sourceName)",
            massKg: max(construction.massKg, 0.001),
            proxy: WorkbenchComponentProxy(shape: .box, size: sceneSize,
                                           colorHex: color(for: kind)),
            importedMesh: construction.mesh,
            params: [:])
    }

    private func color(for kind: WorkbenchComponentKind) -> String {
        switch kind {
        case .motor: return "#39434F"
        case .propeller: return "#23272D"
        case .battery: return "#3AA675"
        case .camera, .sensor, .gps: return "#366889"
        case .payload: return "#6D7784"
        default: return "#637180"
        }
    }

    // MARK: Blueprints

    func saveFavorite() {
        do {
            _ = try WorkbenchBuildStore.saveToLibrary(build)
            refreshBlueprints()
            statusMessage = "Модель «\(build.name)» сохранена в каталог «Пользовательские»."
        } catch {
            statusMessage = "Не удалось сохранить чертёж: \(error.localizedDescription)"
        }
    }

    func refreshBlueprints() {
        blueprints = WorkbenchBuildStore.listLibrary()
    }

    func loadBlueprint(_ summary: WorkbenchBlueprintSummary) {
        loadBlueprint(from: summary.url)
    }

    func deleteBlueprint(_ summary: WorkbenchBlueprintSummary) {
        do {
            try WorkbenchBuildStore.deleteFromLibrary(summary)
            refreshBlueprints()
            statusMessage = "Модель удалена из каталога «Пользовательские»."
        } catch {
            statusMessage = "Не удалось удалить чертёж: \(error.localizedDescription)"
        }
    }

    func save(to url: URL) {
        do {
            try WorkbenchBuildStore.save(build, to: url)
            statusMessage = "Чертёж экспортирован: \(url.lastPathComponent)."
        } catch {
            statusMessage = "Не удалось экспортировать: \(error.localizedDescription)"
        }
    }

    func loadBlueprint(from url: URL) {
        do {
            var loaded = try WorkbenchBuildStore.load(from: url)
            pushUndo()
            loaded.revision = build.revision + 1
            build = loaded
            recompute()
            selectedCategory = .overview
            statusMessage = "Открыт чертёж «\(loaded.name)»."
        } catch {
            statusMessage = "Не удалось открыть чертёж: \(error.localizedDescription)"
        }
    }
}

private extension RFSystemConfiguration {
    mutating func mutateLink(
        _ kind: LogicalLinkKind,
        mutation: (inout RFLinkConfiguration) -> Void
    ) {
        switch kind {
        case .control:
            guard var link = logicalLinks.control else { return }
            mutation(&link)
            logicalLinks.control = link
        case .video:
            guard var link = logicalLinks.video else { return }
            mutation(&link)
            logicalLinks.video = link
        case .telemetry:
            guard var link = logicalLinks.telemetry else { return }
            mutation(&link)
            logicalLinks.telemetry = link
        case .payloadData:
            guard var link = logicalLinks.payloadData else { return }
            mutation(&link)
            logicalLinks.payloadData = link
        }
    }

    mutating func mutateQoSPolicy(
        _ kind: LogicalLinkKind,
        mutation: (inout RFQoSLinkPolicy) -> Void
    ) {
        var updatedQoS = qos ?? .migrationDefault
        if let index = updatedQoS.linkPolicies.firstIndex(where: { $0.kind == kind }) {
            mutation(&updatedQoS.linkPolicies[index])
        } else {
            var policy = updatedQoS.policy(for: kind)
            mutation(&policy)
            updatedQoS.linkPolicies.append(policy)
        }
        qos = updatedQoS
    }
}
