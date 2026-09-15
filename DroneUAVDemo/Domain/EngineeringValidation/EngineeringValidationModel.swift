import Foundation

// Engineering Validation — data model (spec §3–§5, §17).
//
// Three separate axes, kept separate on purpose. The technical spec draws its passport with
// VERIFIED / CONDITIONAL and its records with PASS / WARNING / FAIL / OUTDATED, and mixing
// them is how a screen ends up calling a stale factory result "verified":
//   - `EngineeringTestOutcome` is what a solver concluded, stored with the record, immutable;
//   - `EngineeringTestStatus` is what that record means *for the configuration now*, derived
//     every time and never stored — a file cannot go stale if staleness is not written to it;
//   - `EngineeringResultSource` says where the numbers came from.

enum EngineeringTestType: String, Codable, CaseIterable, Hashable, Identifiable {
    case geometryAssembly
    case massProperties
    case structuralStatic
    case modalVibration
    case mechanism
    case propulsionBench
    case thermalLimits
    case aerodynamics
    case controlAuthority
    case systemEndurance

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .geometryAssembly: return "Геометрия и сборка"
        case .massProperties: return "Масса, ЦТ, инерция"
        case .structuralStatic: return "Статическая прочность"
        case .modalVibration: return "Модальный анализ и вибрации"
        case .mechanism: return "Механизмы"
        case .propulsionBench: return "Стенд силовой установки"
        case .thermalLimits: return "Тепловые пределы"
        case .aerodynamics: return "Аэродинамика / CFD"
        case .controlAuthority: return "Управляемость"
        case .systemEndurance: return "Энергетика и продолжительность"
        }
    }
}

/// What a solver concluded. `error` is a technical failure of the calculation, never an
/// engineering verdict (spec §16) — a crashed mesher says nothing about the wing.
enum EngineeringTestOutcome: String, Codable, Hashable {
    case pass
    case warning
    case fail
    case error
}

enum EngineeringTestStatus: String, Codable, Hashable {
    case notRun
    case running
    case pass
    case warning
    case fail
    case outdated
    case error

    /// The record describes the configuration as it is now, whatever it concluded.
    var isCurrent: Bool {
        switch self {
        case .pass, .warning, .fail: return true
        case .notRun, .running, .outdated, .error: return false
        }
    }
}

enum EngineeringResultSource: String, Codable, Hashable {
    /// Shipped with a stock aircraft (spec §13). A simulator profile, not a manufacturer's
    /// certification.
    case factory
    /// Produced by a solver for this configuration.
    case computed
    /// Arrived inside an imported `.uavbuild`.
    case imported
    /// No calculation: the closed-form model the simulator had before this subsystem.
    case fallback
}

enum EngineeringReadiness: String, Codable, Hashable {
    case ready
    case conditional
    case notReady
    /// Nothing required has a current result. Distinct from `conditional`: a configuration
    /// nobody has calculated is not "ready with caveats", it is unknown.
    case notValidated
    /// A crash or hard landing happened since the last check (spec §15). Dominates everything.
    case inspectionRequired

    var displayName: String {
        switch self {
        case .ready: return "Допущен"
        case .conditional: return "Условно"
        case .notReady: return "Не допущен"
        case .notValidated: return "Не проверен"
        case .inspectionRequired: return "Требуется осмотр"
        }
    }
}

/// Categories of configuration data a test can depend on (spec §10, "dependency granularity").
///
/// Split along the lines a calculation actually reads, which is what makes invalidation
/// precise: a battery of the same mass but different cells changes `batteryElectrical` and
/// leaves `componentLayout` — and therefore mass properties and CFD — untouched.
enum EngineeringInputCategory: String, Codable, CaseIterable, Hashable {
    /// The wetted shape the air sees. Propellers and motors are *not* part of it: aerodynamics
    /// takes the rotors from the propulsion bench (as actuator disks) or not at all.
    case outerGeometry
    /// Load-carrying geometry: frame plates, arms, spars, landing gear.
    case structuralGeometry
    /// Movable surfaces and their actuation points.
    case controlSurfaceGeometry
    case materials
    /// Connections and mounting points: where loads enter the structure.
    case joints
    /// Mass, position and envelope of every part.
    case componentLayout
    case motorCharacteristics
    case propellerCharacteristics
    case batteryElectrical
    case escCharacteristics
    case servoCharacteristics
    /// Flight controller, radio, cameras, sensors and payload functions: power and heat.
    case avionicsAndPayload

    var displayName: String {
        switch self {
        case .outerGeometry: return "внешняя геометрия"
        case .structuralGeometry: return "силовая геометрия"
        case .controlSurfaceGeometry: return "рулевые поверхности"
        case .materials: return "материалы"
        case .joints: return "соединения и точки крепления"
        case .componentLayout: return "масса и размещение компонентов"
        case .motorCharacteristics: return "характеристики моторов"
        case .propellerCharacteristics: return "характеристики винтов"
        case .batteryElectrical: return "электрика АКБ"
        case .escCharacteristics: return "характеристики ESC"
        case .servoCharacteristics: return "характеристики сервоприводов"
        case .avionicsAndPayload: return "авионика и нагрузка"
        }
    }
}

/// Airframe classes as far as validation cares: which tests apply and which are required.
enum EngineeringAirframeKind: String, Codable, CaseIterable, Hashable {
    case multicopter
    case fixedWing
    case vtol

    init(_ architecture: WorkbenchVehicleArchitecture) {
        switch architecture {
        case .multicopter: self = .multicopter
        case .fixedWing: self = .fixedWing
        case .liftCruiseVTOL: self = .vtol
        }
    }
}

// MARK: - Frame convention

/// Axes and units a snapshot's numbers are expressed in.
///
/// ⚠️ Not decorative. Workbench model space has the nose along **+Z**; the flight engine has it
/// along **−Z**; OCCT solids in CADNext are Z-up millimetres. A pitching moment or a CG
/// offset that crosses one of those boundaries without saying which space it was in arrives
/// with its sign flipped, and nothing downstream can tell.
struct EngineeringFrameConvention: Codable, Hashable {
    enum Axis: String, Codable, Hashable {
        case plusX = "+x", minusX = "-x", plusY = "+y", minusY = "-y", plusZ = "+z", minusZ = "-z"

        var vector: SIMD3<Int> {
            switch self {
            case .plusX: return SIMD3(1, 0, 0)
            case .minusX: return SIMD3(-1, 0, 0)
            case .plusY: return SIMD3(0, 1, 0)
            case .minusY: return SIMD3(0, -1, 0)
            case .plusZ: return SIMD3(0, 0, 1)
            case .minusZ: return SIMD3(0, 0, -1)
            }
        }
    }

    var name: String
    var forward: Axis
    var up: Axis
    var right: Axis
    var lengthUnit: String
    var massUnit: String

    /// right × up = backward in a right-handed frame, i.e. forward = up × right.
    var isRightHanded: Bool {
        let u = up.vector, r = right.vector
        let cross = SIMD3(u.y * r.z - u.z * r.y, u.z * r.x - u.x * r.z, u.x * r.y - u.y * r.x)
        return cross == forward.vector
    }

    /// SceneKit node space of the Workbench: +Y lift, +Z forward (see `WorkbenchFrameSpec`).
    /// SceneKit is right-handed, so facing +Z with +Y up puts +X on the aircraft's *left*.
    static let workbenchModel = EngineeringFrameConvention(
        name: "workbench-model", forward: .plusZ, up: .plusY, right: .minusX,
        lengthUnit: "m", massUnit: "kg")

    /// Flight engine body axes: X right, Y up, nose along −Z (see `FixedWingAerodynamics`).
    static let flightBody = EngineeringFrameConvention(
        name: "flight-body", forward: .minusZ, up: .plusY, right: .plusX,
        lengthUnit: "m", massUnit: "kg")
}

// MARK: - Snapshot

/// Immutable engineering description of one configuration (spec §3).
///
/// Holds canonical *values*, not only their hashes, so a changed result can say what changed
/// ("battery: capacityMah 1500 → 1800") and so a solver can be handed the snapshot it is
/// stamped against. Heavy geometry enters by reference — a mesh contributes its content
/// fingerprint and counts, never its vertices.
///
/// Identity fields (name, description, revision counter, timestamps) are outside the
/// fingerprint: renaming a build must not make its strength result stale.
struct EngineeringConfigurationSnapshot: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var vehicleID: String
    var displayName: String
    var revision: Int
    var parentSnapshotID: String?
    var createdAt: Date
    var airframe: EngineeringAirframeKind
    var frameConvention: EngineeringFrameConvention
    /// category rawValue → item key → value.
    var categories: [String: [String: EngineeringCanonicalValue]]

    func items(_ category: EngineeringInputCategory) -> [String: EngineeringCanonicalValue] {
        categories[category.rawValue] ?? [:]
    }

    func itemFingerprints(_ category: EngineeringInputCategory) -> [String: String] {
        items(category).mapValues(\.fingerprint)
    }

    func fingerprint(of category: EngineeringInputCategory) -> String {
        EngineeringFingerprint.combine(itemFingerprints(category))
    }

    /// Identity of the engineering content (spec §3 "stable hash"). Per-test decisions use
    /// category fingerprints instead — this one changes whenever anything does.
    var snapshotID: String {
        var parts: [String: String] = [
            "schema": String(schemaVersion),
            "airframe": airframe.rawValue,
            "frame": frameConvention.name,
        ]
        for category in EngineeringInputCategory.allCases {
            parts["category." + category.rawValue] = fingerprint(of: category)
        }
        return EngineeringFingerprint.combine(parts)
    }
}

// MARK: - Records

struct EngineeringMetric: Codable, Hashable {
    var value: Double
    var unit: String
    /// Estimated numerical error of `value`, same unit — for a mesh-based solver the
    /// grid-convergence band. `nil` when the solver has no estimate, which the UI must show
    /// as "unknown", never as zero.
    var numericalUncertainty: Double?

    init(_ value: Double, unit: String, numericalUncertainty: Double? = nil) {
        self.value = value
        self.unit = unit
        self.numericalUncertainty = numericalUncertainty
    }
}

/// An accepted FAIL (spec §4: usable "only with explicit override").
struct EngineeringOverride: Codable, Hashable {
    var reason: String
    var acceptedAt: Date
}

/// One calculation of one test against one snapshot (spec §4 TestRecord).
///
/// Stores what it *consumed*, at item level: the input values' fingerprints and the output
/// fingerprints of the upstream results it read. Staleness is then a comparison, and the
/// reason for it can name the part.
struct EngineeringTestRecord: Codable, Hashable, Identifiable {
    static let currentSchemaVersion = 1

    var id: UUID
    var schemaVersion: Int
    var testType: EngineeringTestType
    var definitionVersion: Int
    var validationRulesVersion: Int
    var outcome: EngineeringTestOutcome
    var source: EngineeringResultSource
    var vehicleID: String
    var snapshotID: String
    /// category rawValue → item key → fingerprint. Only the categories the definition reads.
    /// String keys rather than enum keys so a record from a newer schema still decodes.
    var inputs: [String: [String: String]]
    /// upstream test rawValue → output fingerprint it read. An optional upstream the solver
    /// ran without is simply absent.
    var upstream: [String: String]
    var settingsFingerprint: String
    /// Engineering outputs only. Anything that varies between identical runs (wall time,
    /// iteration counts of an adaptive solver) belongs in the solver log, not here — it would
    /// make every downstream result stale after a re-run that changed nothing.
    var metrics: [String: EngineeringMetric]
    var warnings: [String]
    var failureReasons: [String]
    var solverID: String
    var solverVersion: String
    var createdAt: Date
    var reportRef: String?
    var override: EngineeringOverride?

    /// What downstream tests compare against: the numbers, not the verdict or the prose.
    var outputFingerprint: String {
        EngineeringCanonicalValue.object(metrics.mapValues { metric in
            var fields: [String: EngineeringCanonicalValue] = [
                "value": .number(metric.value),
                "unit": .string(metric.unit),
            ]
            if let uncertainty = metric.numericalUncertainty {
                fields["uncertainty"] = .number(uncertainty)
            }
            return .object(fields)
        }).fingerprint
    }
}
