import Foundation
import simd

// Strength calculations run from the Workbench (spec §6.1) on the exact solids a `.uavframe` v2
// brought from CADNext.
//
// A load case belongs to one solid and lives in the blueprint: it is part of how the aircraft is
// meant to be checked, and travels with it. Loads can be typed in, or read from upstream results —
// the thrust of one motor from the propulsion bench, the weight of mounted equipment from the mass
// properties. A case's record is stamped with exactly the upstream it read, so a case of typed
// forces alone stays honest about what it did not consider.

/// Axes of Workbench model space, the only frame a user picks directions in.
enum WorkbenchModelAxis: String, Codable, CaseIterable, Hashable {
    case x, y, z

    var displayName: String {
        switch self {
        case .x: return "X (влево)"
        case .y: return "Y (вверх)"
        case .z: return "Z (вперёд)"
        }
    }
}

struct WorkbenchStructuralCase: Codable, Hashable, Identifiable {
    struct Support: Codable, Hashable {
        var faceID: String
        /// Held at zero along these model axes; all three is a clamp.
        var fixed: Set<WorkbenchModelAxis>
    }

    enum ForceSource: Codable, Hashable {
        /// Newtons along model axes.
        case manual(CodableVector3D)
        /// `motors` × the bench's thrust of one motor, along a model direction (normalised on use).
        case motorThrust(motors: Double, direction: CodableVector3D)
        /// Mass of the listed mounted parts × `loadFactorG` × g, along a model direction — equipment
        /// bearing on this face.
        case equipmentWeight(kinds: [WorkbenchComponentKind], loadFactorG: Double, direction: CodableVector3D)
    }

    struct Force: Codable, Hashable {
        var faceID: String
        var source: ForceSource
    }

    struct Pressure: Codable, Hashable {
        var faceID: String
        var pressurePa: Double
    }

    struct Exclusion: Codable, Hashable {
        var faceID: String
        var distanceM: Double
    }

    /// Equipment carried by a face in a modal case: `count` units of a part, their mass read from
    /// the mass properties (a motor on an arm tip is one of the build's motors).
    struct Equipment: Codable, Hashable {
        var faceID: String
        var kind: WorkbenchComponentKind
        var count: Double
    }

    struct ExcitationBand: Codable, Hashable {
        var name: String
        var minimumHz: Double
        var maximumHz: Double
    }

    struct ModalSettings: Codable, Hashable {
        /// Required; too few modes is reported by the result (bands above the last mode).
        var modeCount: Int?
        /// The rotor's lowest speed in flight. Required for the 1P/NP bands — the bench gives the
        /// maximum speed and the blade count, not how slowly the rotor turns.
        var rotorMinimumRPM: Double?
        var bands: [ExcitationBand] = []
        var separationMargin: Double = 0
        var equipment: [Equipment] = []
    }

    enum Analysis: Codable, Hashable {
        case strength
        case modal(ModalSettings)
    }

    var id: UUID
    var name: String
    var bodyID: String
    var supports: [Support]
    var forces: [Force]
    var pressures: [Pressure]
    var exclusions: [Exclusion]
    /// The solid's own mass accelerated by n along model axes (g); no upstream is read for it.
    var ownLoadFactorG: CodableVector3D
    /// Required; there is no good default for how fine a part must be meshed.
    var coarseElementSizeM: Double?
    /// ≥ 1.3 (Celik et al. 2008); 1.6 is CADNext's panel default.
    var refinementFactor: Double
    /// CS-23.303.
    var factorOfSafety: Double
    var analysis: Analysis

    var testType: EngineeringTestType {
        if case .modal = analysis { return .modalVibration }
        return .structuralStatic
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bodyID, supports, forces, pressures, exclusions, ownLoadFactorG
        case coarseElementSizeM, refinementFactor, factorOfSafety, analysis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bodyID = try c.decode(String.self, forKey: .bodyID)
        supports = try c.decodeIfPresent([Support].self, forKey: .supports) ?? []
        forces = try c.decodeIfPresent([Force].self, forKey: .forces) ?? []
        pressures = try c.decodeIfPresent([Pressure].self, forKey: .pressures) ?? []
        exclusions = try c.decodeIfPresent([Exclusion].self, forKey: .exclusions) ?? []
        ownLoadFactorG = try c.decodeIfPresent(CodableVector3D.self, forKey: .ownLoadFactorG) ?? CodableVector3D(x: 0, y: 0, z: 0)
        coarseElementSizeM = try c.decodeIfPresent(Double.self, forKey: .coarseElementSizeM)
        refinementFactor = try c.decodeIfPresent(Double.self, forKey: .refinementFactor) ?? 1.6
        factorOfSafety = try c.decodeIfPresent(Double.self, forKey: .factorOfSafety) ?? 1.5
        // Cases written before modal cases existed are strength cases.
        analysis = try c.decodeIfPresent(Analysis.self, forKey: .analysis) ?? .strength
    }

    init(id: UUID = UUID(), name: String, bodyID: String, analysis: Analysis = .strength) {
        self.analysis = analysis
        self.id = id
        self.name = name
        self.bodyID = bodyID
        supports = []
        forces = []
        pressures = []
        exclusions = []
        ownLoadFactorG = CodableVector3D(x: 0, y: 0, z: 0)
        coarseElementSizeM = nil
        refinementFactor = 1.6
        factorOfSafety = 1.5
    }
}

/// Signed CAD axes of a `.uavframe` v2 and the model ↔ CAD conversions (the Swift twin of
/// `cadnext::bridge::cadToModel`; the probe pins both to the Workbench importer's (x, z, −y)).
struct WorkbenchCADFrame: Hashable {
    let forward: SIMD3<Double>
    let up: SIMD3<Double>
    let left: SIMD3<Double>

    init?(_ axes: WorkbenchConstruction.CADAxes) {
        guard let forward = Self.axis(axes.forward), let up = Self.axis(axes.up), simd_dot(forward, up) == 0 else { return nil }
        self.forward = forward
        self.up = up
        left = simd_cross(up, forward)
    }

    func cadToModel(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(simd_dot(p, left), simd_dot(p, up), simd_dot(p, forward))
    }

    func modelToCAD(_ m: SIMD3<Double>) -> SIMD3<Double> {
        left * m.x + up * m.y + forward * m.z
    }

    /// The CAD axis letter a model axis runs along (sign does not matter for a support).
    func cadAxisLetter(_ axis: WorkbenchModelAxis) -> String {
        let direction: SIMD3<Double>
        switch axis {
        case .x: direction = left
        case .y: direction = up
        case .z: direction = forward
        }
        if direction.x != 0 { return "x" }
        if direction.y != 0 { return "y" }
        return "z"
    }

    private static func axis(_ text: String) -> SIMD3<Double>? {
        guard text.count == 2, let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let s: Double = sign == "+" ? 1 : -1
        switch text.last {
        case "x": return SIMD3(s, 0, 0)
        case "y": return SIMD3(0, s, 0)
        case "z": return SIMD3(0, 0, s)
        default: return nil
        }
    }
}

/// A case turned into what `cadnext_structural` reads, with what it consumed.
struct WorkbenchStructuralJob {
    static let schema = "cadnext-structural-job/1"

    let caseID: UUID
    let testType: EngineeringTestType
    let body: WorkbenchConstruction.Body
    /// `cadnext-structural-job/1`, paths relative to the run folder.
    let jobJSON: Data
    let consumedUpstream: Set<EngineeringTestType>
    /// Canonical case definition as resolved (upstream values in, directions in CAD axes): what the
    /// result depends on besides the snapshot.
    let settings: EngineeringCanonicalValue

    static let partFileName = "part.brep"
    static let resultFileName = "result.json"
    static let fieldFileName = "field.json"
    static let reportFileName = "report.html"

    static func prepare(
        _ loadCase: WorkbenchStructuralCase,
        build: WorkbenchBuild,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        guard case let .imported(construction) = build.frame, let bodies = construction.bodies, !bodies.isEmpty,
              let axes = construction.cadAxes else {
            return .failure(.noExactGeometry)
        }
        guard let frame = WorkbenchCADFrame(axes) else { return .failure(.invalidAxes) }
        guard let body = bodies.first(where: { $0.id == loadCase.bodyID }) else { return .failure(.bodyMissing(loadCase.bodyID)) }
        if case let .modal(modal) = loadCase.analysis {
            return prepareModal(loadCase, modal: modal, build: build, body: body, frame: frame, state: state)
        }
        let faceIDs = Set(body.faces.map(\.id))
        let usedFaces = loadCase.supports.map(\.faceID) + loadCase.forces.map(\.faceID)
            + loadCase.pressures.map(\.faceID) + loadCase.exclusions.map(\.faceID)
        if let missing = usedFaces.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard !loadCase.supports.isEmpty else { return .failure(.noSupport) }
        let own = loadCase.ownLoadFactorG.simd
        guard !loadCase.forces.isEmpty || !loadCase.pressures.isEmpty || simd_length(own) > 0 else { return .failure(.noLoad) }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }

        var consumed: Set<EngineeringTestType> = []
        func vector(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
        func unit(_ v: CodableVector3D) -> SIMD3<Double>? {
            let s = v.simd
            let length = simd_length(s)
            return length > 0 ? s / length : nil
        }

        var forces: [[String: Any]] = []
        var resolvedForces: [EngineeringCanonicalValue] = []
        for force in loadCase.forces {
            let model: SIMD3<Double>
            switch force.source {
            case let .manual(value):
                model = value.simd
            case let .motorThrust(motors, direction):
                guard let evaluation = state.evaluation(.propulsionBench), evaluation.status.isCurrent,
                      let thrust = evaluation.record?.metrics["maxThrustN"]?.value else {
                    return .failure(.upstreamNotCurrent(.propulsionBench))
                }
                guard let axis = unit(direction) else { return .failure(.zeroDirection) }
                let units = Double(max(build.resolvedFrame.motorMounts.count, 1))
                model = axis * (thrust / units * motors)
                consumed.insert(.propulsionBench)
            case let .equipmentWeight(kinds, loadFactorG, direction):
                guard let evaluation = state.evaluation(.massProperties), evaluation.status.isCurrent,
                      let record = evaluation.record else {
                    return .failure(.upstreamNotCurrent(.massProperties))
                }
                guard let axis = unit(direction) else { return .failure(.zeroDirection) }
                var mass = 0.0
                for kind in kinds {
                    guard let part = record.metrics[WorkbenchBuiltInChecks.componentMassKey(kind)] else {
                        return .failure(.equipmentMissing(kind))
                    }
                    mass += part.value
                }
                model = axis * (mass * loadFactorG * WorkbenchStructuralJob.standardGravity)
                consumed.insert(.massProperties)
            }
            guard simd_length(model) > 0 else { return .failure(.zeroForce(force.faceID)) }
            let cad = frame.modelToCAD(model)
            forces.append(["face": force.faceID, "totalForceN": vector(cad)])
            resolvedForces.append(.object(["face": .string(force.faceID), "totalForceN": .vector(cad)]))
        }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let pressures: [[String: Any]] = loadCase.pressures.map { ["face": $0.faceID, "pressurePa": $0.pressurePa] }
        let exclusions: [[String: Any]] = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        let acceleration = frame.modelToCAD(own * standardGravity)

        let job: [String: Any] = [
            "schema": schema,
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": [
                "name": loadCase.name,
                "supports": supports,
                "forces": forces,
                "pressures": pressures,
                "bodyAccelerationMps2": vector(acceleration),
                "stressExclusions": exclusions,
            ],
            "output": ["result": resultFileName, "field": fieldFileName, "report": reportFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        let settings = EngineeringCanonicalValue.object([
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map { .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })]) }),
            "forces": .array(resolvedForces),
            "pressures": .array(loadCase.pressures.map { .object(["face": .string($0.faceID), "pressurePa": .number($0.pressurePa)]) }),
            "exclusions": .array(loadCase.exclusions.map { .object(["face": .string($0.faceID), "distanceM": .number($0.distanceM)]) }),
            "bodyAccelerationMps2": .vector(acceleration),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ])
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .structuralStatic, body: body, jobJSON: data, consumedUpstream: consumed, settings: settings))
    }

    private static func prepareModal(
        _ loadCase: WorkbenchStructuralCase,
        modal: WorkbenchStructuralCase.ModalSettings,
        build: WorkbenchBuild,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        let usedFaces = loadCase.supports.map(\.faceID) + modal.equipment.map(\.faceID)
        if let missing = usedFaces.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard let modes = modal.modeCount, modes >= 1 else { return .failure(.noModeCount) }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard modal.separationMargin >= 0 else { return .failure(.negativeMargin) }
        for band in modal.bands where !(band.minimumHz >= 0 && band.maximumHz >= band.minimumHz) || band.name.isEmpty {
            return .failure(.invalidBand(band.name))
        }

        var consumed: Set<EngineeringTestType> = []
        var rotors: [[String: Any]] = []
        var resolvedRotors: [EngineeringCanonicalValue] = []
        if let minimum = modal.rotorMinimumRPM {
            guard let evaluation = state.evaluation(.propulsionBench), evaluation.status.isCurrent, let record = evaluation.record,
                  let maximum = record.metrics["maxRPM"]?.value, let blades = record.metrics["bladeCount"]?.value else {
                return .failure(.upstreamNotCurrent(.propulsionBench))
            }
            guard minimum > 0, minimum <= maximum else { return .failure(.rotorRange(minimum: minimum, maximum: maximum)) }
            rotors.append(["name": "винт", "minimumRpm": minimum, "maximumRpm": maximum, "bladeCount": Int(blades.rounded())])
            resolvedRotors.append(.object(["minimumRpm": .number(minimum), "maximumRpm": .number(maximum), "bladeCount": .number(blades.rounded())]))
            consumed.insert(.propulsionBench)
        }

        var masses: [[String: Any]] = []
        var resolvedMasses: [EngineeringCanonicalValue] = []
        for item in modal.equipment {
            guard item.count > 0 else { return .failure(.equipmentMissing(item.kind)) }
            guard let evaluation = state.evaluation(.massProperties), evaluation.status.isCurrent,
                  let total = evaluation.record?.metrics[WorkbenchBuiltInChecks.componentMassKey(item.kind)]?.value else {
                return state.evaluation(.massProperties)?.status.isCurrent == true
                    ? .failure(.equipmentMissing(item.kind)) : .failure(.upstreamNotCurrent(.massProperties))
            }
            let mass = total / Double(WorkbenchBuiltInChecks.componentUnits(item.kind, build: build)) * item.count
            masses.append(["face": item.faceID, "massKg": mass])
            resolvedMasses.append(.object(["face": .string(item.faceID), "massKg": .number(mass)]))
            consumed.insert(.massProperties)
        }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "modal",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports],
            "modal": [
                "modeCount": modes,
                "rotors": rotors,
                "bands": modal.bands.map { ["name": $0.name, "minimumHz": $0.minimumHz, "maximumHz": $0.maximumHz] },
                "separationMargin": modal.separationMargin,
                "attachedMasses": masses,
            ],
            "output": ["result": resultFileName, "field": fieldFileName, "report": reportFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        let settings = EngineeringCanonicalValue.object([
            "analysis": .string("modal"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map { .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })]) }),
            "modeCount": .number(Double(modes)),
            "rotors": .array(resolvedRotors),
            "bands": .array(modal.bands.map { .object(["name": .string($0.name), "minimumHz": .number($0.minimumHz), "maximumHz": .number($0.maximumHz)]) }),
            "separationMargin": .number(modal.separationMargin),
            "attachedMasses": .array(resolvedMasses),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
        ])
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .modalVibration, body: body, jobJSON: data, consumedUpstream: consumed, settings: settings))
    }

    static let standardGravity = 9.80665
}

enum WorkbenchStructuralError: Error, Equatable, CustomStringConvertible {
    case noExactGeometry
    case invalidAxes
    case bodyMissing(String)
    case faceMissing(String)
    case noSupport
    case noLoad
    case noElementSize
    case refinementTooSmall
    case upstreamNotCurrent(EngineeringTestType)
    case equipmentMissing(WorkbenchComponentKind)
    case zeroDirection
    case zeroForce(String)
    case encodingFailed
    case noModeCount
    case negativeMargin
    case invalidBand(String)
    case rotorRange(minimum: Double, maximum: Double)
    case toolNotFound
    case launchFailed(String)
    case solverFailed(String)
    case resultUnreadable(String)

    var description: String {
        switch self {
        case .noExactGeometry: return "У рамы нет точной геометрии: экспортируйте её из CADNext («Файл → Экспорт в Мастерскую»)."
        case .invalidAxes: return "Оси CAD в файле рамы некорректны."
        case let .bodyMissing(id): return "Тела \(id) больше нет в раме — вариант относится к прежней геометрии."
        case let .faceMissing(face): return "Грани \(face) нет у тела — деталь изменилась, переназначьте нагрузку."
        case .noSupport: return "Нет опор: деталь нужно закрепить хотя бы на одной грани."
        case .noLoad: return "Нет нагрузок: добавьте силу, давление или перегрузку."
        case .noElementSize: return "Не задан размер грубой сетки."
        case .refinementTooSmall: return "Коэффициент измельчения меньше 1.3 (Celik et al. 2008)."
        case let .upstreamNotCurrent(test): return "Нагрузка читает «\(test.displayName)», а у него нет актуального результата."
        case let .equipmentMissing(kind): return "В сборке нет детали «\(kind.displayName)», чей вес указан в нагрузке."
        case .zeroDirection: return "Не задано направление нагрузки."
        case let .zeroForce(face): return "Нулевая сила на грани \(face)."
        case .encodingFailed: return "Не удалось записать задание."
        case .noModeCount: return "Не задано число мод."
        case .negativeMargin: return "Запас по частоте не может быть отрицательным."
        case let .invalidBand(name): return "Полоса возбуждения «\(name)»: нужно название и 0 ≤ от ≤ до."
        case let .rotorRange(minimum, maximum):
            return String(format: "Минимальные обороты винта %.0f должны быть больше нуля и не выше максимальных по стенду (%.0f об/мин).", minimum, maximum)
        case .toolNotFound: return "Расчётный модуль cadnext_structural не найден."
        case let .launchFailed(reason): return "Расчётный модуль не запустился: \(reason)"
        case let .solverFailed(reason): return "Расчёт не выполнен: \(reason)"
        case let .resultUnreadable(reason): return "Результат расчёта не прочитан: \(reason)"
        }
    }
}
