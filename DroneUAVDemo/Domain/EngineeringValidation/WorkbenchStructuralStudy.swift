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

    /// MIL-STD-461G RS103: the standard's field arrives as a plane wave and the question is how much
    /// of it reaches the equipment inside.
    struct EmcSettings: Codable, Hashable {
        /// Where the wave comes from, in CAD axes as the solver names them.
        enum Incidence: String, Codable, Hashable, CaseIterable {
            case plusX = "+x", minusX = "-x", plusY = "+y", minusY = "-y", plusZ = "+z", minusZ = "-z"
            var displayName: String { rawValue.uppercased() }
        }
        enum Polarization: String, Codable, Hashable, CaseIterable {
            case x, y, z
            var displayName: String { rawValue.uppercased() }
        }
        /// A point inside the enclosure, in the part's own coordinates (metres), and what it survives.
        struct ProbePoint: Codable, Hashable {
            var name: String
            var x: Double
            var y: Double
            var z: Double
            var immunityVm: Double
        }

        var incidence: Incidence = .plusX
        var polarization: Polarization = .z
        /// One of the standard's levels, or nil with a field of your own.
        var levelID: String? = "mil461g-rs103-200"
        var fieldVm: Double?
        var lowMHz: Double?
        var highMHz: Double?
        var points: Int = 8
        /// Required: how finely the enclosure's surface is voxelised.
        var surfaceElementSizeM: Double?
        var pmlCells: Int = 8
        var marginCells: Int = 4
        var equipment: [ProbePoint] = []
    }

    /// 14 CFR 25 Appendix C icing.
    struct IcingSettings: Codable, Hashable {
        var flowAxis: WorkbenchModelAxis = .z
        var spanAxis: WorkbenchModelAxis = .x
        var angleOfAttackDeg: Double = 0
        var stations: Int = 3
        var panels: Int = 240
        var trajectories: Int = 200
        var refinementFactor: Double = 1.5
        /// Required: the surface element size the panels are built on.
        var surfaceElementSizeM: Double?
        /// The regulation's takeoff maximum, computed from the flight below; otherwise the numbers
        /// are the user's own cloud.
        var useTakeoffMaximum = true
        var airspeedMps: Double?
        var durationMin: Double?
        var temperatureC: Double?
        var lwcGm3: Double?
        var dropletMicrons: Double?
        var altitudeM: Double?
        var antiIceTargetC: Double?
        var antiIceBudgetW: Double?
        var maximumIceThicknessMm: Double?
    }

    /// 14 CFR 25.629 flutter.
    struct FlutterSettings: Codable, Hashable {
        var flowAxis: WorkbenchModelAxis = .z
        var spanAxis: WorkbenchModelAxis = .x
        var stations: Int = 12
        var airDensityKgM3: Double = 1.225
        var structuralDamping: Double = 0
        /// Without it the verdict cannot rise above WARNING: there is nothing to compare against.
        var diveSpeedMps: Double?
        var marginFactor: Double = 1.15
        var lowSpeedMps: Double = 10
        var highSpeedMps: Double = 400
        var speeds: Int = 300
    }

    /// 14 CFR 25.571(e) bird strike.
    struct BirdSettings: Codable, Hashable {
        var modeCount: Int?
        var dampingRatio: Double?
        var impactFaceID: String?
        /// Where the bird pushes, in model axes.
        var direction: CodableVector3D = CodableVector3D(x: 0, y: 0, z: -1)
        /// 1.81 kg is the 4 lb of the regulation; 3.63 kg is the 8 lb for the empennage.
        var massKg: Double = 1.81
        var speedMps: Double?
        var obliquityDeg: Double = 90
        var equipment: [Equipment] = []
    }

    /// A piece of equipment in a thermal case: its own heat and the temperatures it survives. Typed
    /// in rather than read from the library, which carries no temperature limits — a made-up limit
    /// would be the quietest wrong verdict in a climate or fire test.
    struct ThermalComponent: Codable, Hashable {
        var name: String
        var faceID: String
        var powerW: Double = 0
        /// °C as the datasheets are written; absent means the component has no limit on that side.
        var minimumC: Double?
        var maximumC: Double?
    }

    /// MIL-STD-810H climate: the standard's air, the sun and the part's own heat.
    struct ClimateSettings: Codable, Hashable {
        enum Environment: String, Codable, Hashable, CaseIterable {
            case hot, cold
            var displayName: String { self == .hot ? "Жара" : "Холод" }
        }
        /// Hot categories of the standard: A1 hot-dry, A2 basic hot.
        enum HotCategory: String, Codable, Hashable, CaseIterable {
            case a1 = "A1", a2 = "A2"
            var displayName: String { self == .a1 ? "A1 — жаркая сухая" : "A2 — основная жаркая" }
        }
        enum HotExposure: String, Codable, Hashable, CaseIterable {
            case sun, shade, induced
            var displayName: String {
                switch self {
                case .sun: return "На солнце"
                case .shade: return "В тени"
                case .induced: return "Наведённая (в отсеке)"
                }
            }
        }
        /// Cold categories: C1 basic cold, C2 cold, C3 severe cold.
        enum ColdCategory: String, Codable, Hashable, CaseIterable {
            case c1 = "C1", c2 = "C2", c3 = "C3"
            var displayName: String {
                switch self {
                case .c1: return "C1 — основная холодная"
                case .c2: return "C2 — холодная"
                case .c3: return "C3 — очень холодная"
                }
            }
        }
        enum ColdExposure: String, Codable, Hashable, CaseIterable {
            case ambient, induced
            var displayName: String { self == .ambient ? "Наружная" : "Наведённая (в отсеке)" }
        }
        enum Airflow: String, Codable, Hashable, CaseIterable {
            case chamber, flight
            var displayName: String { self == .chamber ? "Камера (обдува нет)" : "Полёт" }
        }

        var environment: Environment = .hot
        var hotCategory: HotCategory = .a1
        var hotExposure: HotExposure = .sun
        var coldCategory: ColdCategory = .c2
        var coldExposure: ColdExposure = .ambient
        var airflow: Airflow = .chamber
        /// Required: still air in a chamber is a speed too (the standard's 1.5 m/s), and zero is a
        /// different calculation from 1.5.
        var airSpeedMps: Double?
        var altitudeM: Double?
        var up: CodableVector3D = CodableVector3D(x: 0, y: 1, z: 0)
        var flow: CodableVector3D = CodableVector3D(x: 0, y: 0, z: 1)
        /// Required: the surface decides how much sun it takes and how much it radiates back.
        var solarAbsorptance: Double?
        var emissivity: Double?
        /// Required: the temperature the part was assembled at, from which thermal stress is counted.
        var assemblyC: Double?
        var operating = true
        var components: [ThermalComponent] = []
        var materialMinimumC: Double?
        var materialMaximumC: Double?
        var convectionBand: Double = 0.25
        /// Required: the time step of the day's transient.
        var stepS: Double?
    }

    /// ISO 2685 / AC 20-135 flame on chosen faces.
    struct FireSettings: Codable, Hashable {
        enum Standard: String, Codable, Hashable, CaseIterable {
            case iso2685, ac20135
            var displayName: String { self == .iso2685 ? "ISO 2685" : "AC 20-135" }
        }

        var standard: Standard = .iso2685
        /// Required: 300 s fire resistant, 900 s fireproof — the choice is the test, not a detail.
        var durationS: Double?
        var flameFaceIDs: [String] = []
        /// Required (EN 1999-1-2 §2.2: 0.3 clean metal, 0.7 painted).
        var surfaceEmissivity: Double?
        var stepS: Double?
        var operating = true
        var components: [ThermalComponent] = []
    }

    /// SAE ARP5412 current through the part.
    struct LightningSettings: Codable, Hashable {
        enum Component: String, Codable, Hashable, CaseIterable {
            case a = "A", b = "B", c = "C", d = "D"
            var displayName: String {
                switch self {
                case .a: return "A — первый удар, 200 кА"
                case .b: return "B — промежуточный, 2 кА"
                case .c: return "C — продолжающийся ток"
                case .d: return "D — повторный удар, 100 кА"
                }
            }
        }
        enum Polarity: String, Codable, Hashable, CaseIterable {
            case anode, cathode
            var displayName: String { self == .anode ? "Анод (деталь — анод)" : "Катод (деталь — катод)" }
        }

        /// In the order of the standard's waveform; A, B, C is the usual zone 1A sequence.
        var components: [Component] = [.a, .b, .c]
        var attachmentFaceIDs: [String] = []
        var groundFaceIDs: [String] = []
        var polarity: Polarity = .anode
        /// 200–800 A by the standard.
        var continuingCurrentA: Double = 400
        var surfaceEmissivity: Double?
        var stepsPerComponent: Int = 400
        var equipment: [ThermalComponent] = []
    }

    /// One point of a vibration spectrum as the standards write them: a frequency and a value
    /// whose unit depends on what is being described (g for a shaker, newtons for a force,
    /// g²/Hz for a power spectral density).
    struct SpectrumPoint: Codable, Hashable {
        var frequencyHz: Double
        var value: Double
    }

    /// Sine vibration on the fixture: a shaker, a force on a face, or a rotor imbalance, swept over
    /// a frequency range.
    struct SineSettings: Codable, Hashable {
        enum Excitation: String, Codable, Hashable, CaseIterable {
            case base, force, imbalance

            var displayName: String {
                switch self {
                case .base: return "Вибростенд (g)"
                case .force: return "Сила на грань (Н)"
                case .imbalance: return "Дисбаланс винта (г·мм)"
                }
            }
        }

        var modeCount: Int?
        var dampingRatio: Double?
        var excitation: Excitation = .base
        var direction: CodableVector3D = CodableVector3D(x: 0, y: 1, z: 0)
        /// Amplitude as entered: g for the shaker, newtons for a force. One point means flat over
        /// the whole range; several must rise in frequency.
        var amplitude: [SpectrumPoint] = []
        /// Rotor imbalance in g·mm, in place of an amplitude (the two are mutually exclusive).
        var imbalanceGmm: Double?
        /// Where a force or an imbalance acts; unused by the shaker.
        var faceID: String?
        var fromHz: Double?
        var toHz: Double?
        var sweepPoints: Int = 200
        var equipment: [Equipment] = []
        var probeFaceID: String?
    }

    /// Random vibration: a power spectral density on the fixture, as a vibration schedule states it.
    struct RandomSettings: Codable, Hashable {
        var modeCount: Int?
        var dampingRatio: Double?
        var direction: CodableVector3D = CodableVector3D(x: 0, y: 1, z: 0)
        /// (Hz, g²/Hz) — at least two points, rising in frequency; log–log between them, zero outside.
        var psd: [SpectrumPoint] = []
        var equipment: [Equipment] = []
        var probeFaceID: String?
    }

    /// Shape of the acceleration pulse, named as `cadnext_structural` reads it.
    enum PulseShape: String, Codable, Hashable, CaseIterable {
        case halfSine, sawtooth, trapezoid

        var displayName: String {
            switch self {
            case .halfSine: return "Полусинус"
            case .sawtooth: return "Пила (пик в конце)"
            case .trapezoid: return "Трапеция"
            }
        }
    }

    /// One shock event on the fixture: a base acceleration pulse along a model direction. Nothing
    /// has a default that could pass for an answer — modes, damping, the peak and the duration are
    /// all the user's, because a shock invented by the program would be the quietest wrong verdict
    /// here.
    struct ShockSettings: Codable, Hashable {
        var modeCount: Int?
        /// Fraction of critical, 0 < ζ < 1.
        var dampingRatio: Double?
        var shape: PulseShape = .halfSine
        /// Peak of the pulse in g.
        var peakG: Double?
        var durationMs: Double?
        /// Trapezoid only; together they must fit inside the duration.
        var riseMs: Double = 0
        var fallMs: Double = 0
        /// Where the fixture pushes, in model axes (normalised on use).
        var direction: CodableVector3D = CodableVector3D(x: 0, y: 1, z: 0)
        /// Equipment riding through the pulse; its mass comes from the mass properties.
        var equipment: [Equipment] = []
        /// Optional face whose motion is reported as a sensor would see it.
        var probeFaceID: String?
    }

    enum Analysis: Codable, Hashable {
        case strength
        case modal(ModalSettings)
        case sine(SineSettings)
        case random(RandomSettings)
        case shock(ShockSettings)
        case climate(ClimateSettings)
        case fire(FireSettings)
        case lightning(LightningSettings)
        case emc(EmcSettings)
        case icing(IcingSettings)
        case flutter(FlutterSettings)
        case bird(BirdSettings)
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

    /// Kind of case, as the panel offers them. Several kinds share one `EngineeringTestType`
    /// (modes, sine and random are all vibration), so the picker needs its own name for them.
    enum Kind: String, Codable, Hashable, CaseIterable, Identifiable {
        case strength, modal, sine, random, shock, climate, fire, lightning, emc, icing, flutter, bird
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .strength: return "Прочность"
            case .modal: return "Частоты и резонанс"
            case .sine: return "Вибрация (синус)"
            case .random: return "Случайная вибрация"
            case .shock: return "Удар"
            case .climate: return "Климат"
            case .fire: return "Огонь"
            case .lightning: return "Молния"
            case .emc: return "ЭМС"
            case .icing: return "Обледенение"
            case .flutter: return "Флаттер"
            case .bird: return "Удар птицы"
            }
        }
    }

    var kind: Kind {
        switch analysis {
        case .strength: return .strength
        case .modal: return .modal
        case .sine: return .sine
        case .random: return .random
        case .shock: return .shock
        case .climate: return .climate
        case .fire: return .fire
        case .lightning: return .lightning
        case .emc: return .emc
        case .icing: return .icing
        case .flutter: return .flutter
        case .bird: return .bird
        }
    }

    var testType: EngineeringTestType {
        switch analysis {
        // The solver files modes, sine and random alike under modalVibration: one test, three kinds
        // of case. A verdict on vibration is not complete without all three where they apply.
        case .modal, .sine, .random: return .modalVibration
        case .shock: return .mechanicalShock
        case .climate: return .climatic
        case .fire: return .fireResistance
        case .lightning: return .lightningDirect
        case .emc: return .radiatedSusceptibility
        case .icing: return .icing
        case .flutter: return .flutter
        case .bird: return .birdStrike
        case .strength: return .structuralStatic
        }
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
        if case let .sine(sine) = loadCase.analysis {
            return prepareSine(loadCase, sine: sine, build: build, body: body, frame: frame, state: state)
        }
        if case let .random(random) = loadCase.analysis {
            return prepareRandom(loadCase, random: random, build: build, body: body, frame: frame, state: state)
        }
        if case let .shock(shock) = loadCase.analysis {
            return prepareShock(loadCase, shock: shock, build: build, body: body, frame: frame, state: state)
        }
        if case let .climate(climate) = loadCase.analysis {
            return prepareClimate(loadCase, climate: climate, body: body, frame: frame)
        }
        if case let .fire(fire) = loadCase.analysis {
            return prepareFire(loadCase, fire: fire, body: body, frame: frame, build: build, state: state)
        }
        if case let .lightning(lightning) = loadCase.analysis {
            return prepareLightning(loadCase, lightning: lightning, body: body, frame: frame)
        }
        if case let .emc(emc) = loadCase.analysis {
            return prepareEmc(loadCase, emc: emc, body: body)
        }
        if case let .icing(icing) = loadCase.analysis {
            return prepareIcing(loadCase, icing: icing, body: body, frame: frame)
        }
        if case let .flutter(flutter) = loadCase.analysis {
            return prepareFlutter(loadCase, flutter: flutter, body: body, frame: frame)
        }
        if case let .bird(bird) = loadCase.analysis {
            return prepareBird(loadCase, bird: bird, build: build, body: body, frame: frame, state: state)
        }
        let resolved: ResolvedLoads
        switch resolveLoads(loadCase, build: build, body: body, frame: frame, state: state) {
        case let .failure(error): return .failure(error)
        case let .success(value): resolved = value
        }
        guard !loadCase.forces.isEmpty || !loadCase.pressures.isEmpty || simd_length(loadCase.ownLoadFactorG.simd) > 0 else {
            return .failure(.noLoad)
        }
        let size = loadCase.coarseElementSizeM!

        let job: [String: Any] = [
            "schema": schema,
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": resolved.loadCaseJSON(named: loadCase.name),
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        var canonical = resolved.canonicalLoadCase
        canonical["case"] = .string(loadCase.id.uuidString.lowercased())
        canonical["body"] = .string(body.id)
        canonical["brepSha256"] = .string(body.geometry.sha256)
        canonical["material"] = .string(body.materialId)
        canonical["coarseElementSizeM"] = .number(size)
        canonical["refinementFactor"] = .number(loadCase.refinementFactor)
        canonical["factorOfSafety"] = .number(loadCase.factorOfSafety)
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .structuralStatic, body: body, jobJSON: data,
            consumedUpstream: resolved.consumed, settings: .object(canonical)))
    }

    /// Supports, forces, pressures, acceleration and exclusion zones of a load case, resolved into
    /// what the solver reads: upstream values in (one motor's thrust from the bench, equipment weight
    /// from the mass properties), directions in CAD axes. Shared by the static case and the fire
    /// case, which loads the part mechanically while it burns.
    private struct ResolvedLoads {
        var supports: [[String: Any]] = []
        var forces: [[String: Any]] = []
        var pressures: [[String: Any]] = []
        var exclusions: [[String: Any]] = []
        var accelerationCAD: [Double] = [0, 0, 0]
        var canonicalForces: [EngineeringCanonicalValue] = []
        var canonicalSupports: [EngineeringCanonicalValue] = []
        var canonicalPressures: [EngineeringCanonicalValue] = []
        var canonicalExclusions: [EngineeringCanonicalValue] = []
        var consumed: Set<EngineeringTestType> = []

        func loadCaseJSON(named name: String) -> [String: Any] {
            [
                "name": name,
                "supports": supports,
                "forces": forces,
                "pressures": pressures,
                "bodyAccelerationMps2": accelerationCAD,
                "stressExclusions": exclusions,
            ]
        }

        var canonicalLoadCase: [String: EngineeringCanonicalValue] {
            [
                "supports": .array(canonicalSupports),
                "forces": .array(canonicalForces),
                "pressures": .array(canonicalPressures),
                "exclusions": .array(canonicalExclusions),
                "bodyAccelerationMps2": .array(accelerationCAD.map { .number($0) }),
            ]
        }
    }

    private static func resolveLoads(
        _ loadCase: WorkbenchStructuralCase,
        build: WorkbenchBuild,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        state: EngineeringValidationState
    ) -> Result<ResolvedLoads, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        let usedFaces = loadCase.supports.map(\.faceID) + loadCase.forces.map(\.faceID)
            + loadCase.pressures.map(\.faceID) + loadCase.exclusions.map(\.faceID)
        if let missing = usedFaces.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard !loadCase.supports.isEmpty else { return .failure(.noSupport) }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        _ = size
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }

        var result = ResolvedLoads()
        func vector(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
        func unit(_ v: CodableVector3D) -> SIMD3<Double>? {
            let s = v.simd
            let length = simd_length(s)
            return length > 0 ? s / length : nil
        }

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
                result.consumed.insert(.propulsionBench)
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
                result.consumed.insert(.massProperties)
            }
            guard simd_length(model) > 0 else { return .failure(.zeroForce(force.faceID)) }
            let cad = frame.modelToCAD(model)
            result.forces.append(["face": force.faceID, "totalForceN": vector(cad)])
            result.canonicalForces.append(.object(["face": .string(force.faceID), "totalForceN": .vector(cad)]))
        }

        result.supports = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        result.canonicalSupports = result.supports.map {
            .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
        }
        result.pressures = loadCase.pressures.map { ["face": $0.faceID, "pressurePa": $0.pressurePa] }
        result.canonicalPressures = loadCase.pressures.map { .object(["face": .string($0.faceID), "pressurePa": .number($0.pressurePa)]) }
        result.exclusions = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        result.canonicalExclusions = loadCase.exclusions.map { .object(["face": .string($0.faceID), "distanceM": .number($0.distanceM)]) }
        result.accelerationCAD = vector(frame.modelToCAD(loadCase.ownLoadFactorG.simd * standardGravity))
        return .success(result)
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
        switch attachedMasses(modal.equipment, build: build, state: state, consumed: &consumed) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (masses, resolvedMasses) = resolved
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
            "output": ["result": resultFileName, "field": fieldFileName],
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

    /// Mass of the equipment a face carries, read from the mass properties: `count` units of a
    /// part, its mass divided by how many the build has. Used by the modal and the shock case
    /// alike — the same equipment must weigh the same in both.
    private static func attachedMasses(
        _ equipment: [WorkbenchStructuralCase.Equipment],
        build: WorkbenchBuild,
        state: EngineeringValidationState,
        consumed: inout Set<EngineeringTestType>
    ) -> Result<([[String: Any]], [EngineeringCanonicalValue]), WorkbenchStructuralError> {
        var masses: [[String: Any]] = []
        var resolved: [EngineeringCanonicalValue] = []
        for item in equipment {
            guard item.count > 0 else { return .failure(.equipmentMissing(item.kind)) }
            guard let evaluation = state.evaluation(.massProperties), evaluation.status.isCurrent,
                  let total = evaluation.record?.metrics[WorkbenchBuiltInChecks.componentMassKey(item.kind)]?.value else {
                return state.evaluation(.massProperties)?.status.isCurrent == true
                    ? .failure(.equipmentMissing(item.kind)) : .failure(.upstreamNotCurrent(.massProperties))
            }
            let mass = total / Double(WorkbenchBuiltInChecks.componentUnits(item.kind, build: build)) * item.count
            masses.append(["face": item.faceID, "massKg": mass])
            resolved.append(.object(["face": .string(item.faceID), "massKg": .number(mass)]))
            consumed.insert(.massProperties)
        }
        return .success((masses, resolved))
    }

    /// MIL-STD-461G RS103. Nothing is supported and nothing is loaded: a field arrives and the
    /// question is what reaches the points inside. The probe points are in the part's own
    /// coordinates, so no frame conversion applies to them.
    private static func prepareEmc(
        _ loadCase: WorkbenchStructuralCase,
        emc: WorkbenchStructuralCase.EmcSettings,
        body: WorkbenchConstruction.Body
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard let surface = emc.surfaceElementSizeM, surface > 0 else { return .failure(.noSurfaceElementSize) }
        let hasLevel = !(emc.levelID ?? "").isEmpty
        guard hasLevel || (emc.fieldVm ?? 0) > 0 else { return .failure(.noField) }
        guard let low = emc.lowMHz, let high = emc.highMHz, low > 0, high > low, emc.points >= 1 else { return .failure(.noSweep) }
        guard emc.pmlCells >= 1, emc.marginCells >= 1 else { return .failure(.noSweep) }

        var block: [String: Any] = [
            "incidence": emc.incidence.rawValue,
            "polarization": emc.polarization.rawValue,
            "lowHz": low * 1e6,
            "highHz": high * 1e6,
            "points": emc.points,
            "surfaceElementSizeM": surface,
            "pmlCells": emc.pmlCells,
            "marginCells": emc.marginCells,
            "equipment": emc.equipment.map { ["name": $0.name, "x": $0.x, "y": $0.y, "z": $0.z, "immunityVm": $0.immunityVm] },
        ]
        var canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("emc"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "incidence": .string(emc.incidence.rawValue),
            "polarization": .string(emc.polarization.rawValue),
            "lowHz": .number(low * 1e6),
            "highHz": .number(high * 1e6),
            "points": .number(Double(emc.points)),
            "surfaceElementSizeM": .number(surface),
            "pmlCells": .number(Double(emc.pmlCells)),
            "marginCells": .number(Double(emc.marginCells)),
            "equipment": .array(emc.equipment.map {
                .object(["name": .string($0.name), "x": .number($0.x), "y": .number($0.y), "z": .number($0.z),
                         "immunityVm": .number($0.immunityVm)])
            }),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
        ]
        if hasLevel {
            block["level"] = emc.levelID!
            canonical["level"] = .string(emc.levelID!)
        } else {
            block["fieldVm"] = emc.fieldVm!
            canonical["fieldVm"] = .number(emc.fieldVm!)
        }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "emc",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name],
            "emc": block,
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .radiatedSusceptibility, body: body, jobJSON: data,
            consumedUpstream: [], settings: .object(canonical)))
    }

    /// 14 CFR 25 Appendix C icing. The cloud is either the regulation's takeoff maximum computed
    /// from the flight, or the numbers the user states — never a mixture.
    private static func prepareIcing(
        _ loadCase: WorkbenchStructuralCase,
        icing: WorkbenchStructuralCase.IcingSettings,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard icing.flowAxis != icing.spanAxis else { return .failure(.sameAxes) }
        guard let surface = icing.surfaceElementSizeM, surface > 0 else { return .failure(.noSurfaceElementSize) }
        guard icing.stations >= 1, icing.panels >= 60, icing.trajectories >= 20, icing.refinementFactor >= 1.2 else {
            return .failure(.noCloud)
        }

        var condition: Any
        var canonicalCondition: EngineeringCanonicalValue
        var flight: [String: Any]?
        if icing.useTakeoffMaximum {
            guard let speed = icing.airspeedMps, speed > 0, let minutes = icing.durationMin, minutes > 0 else { return .failure(.noCloud) }
            condition = "takeoffMaximum"
            canonicalCondition = .string("takeoffMaximum")
            flight = ["airspeedMps": speed, "durationS": minutes * 60]
        } else {
            guard let temperature = icing.temperatureC, let water = icing.lwcGm3, water > 0,
                  let droplet = icing.dropletMicrons, droplet > 0,
                  let speed = icing.airspeedMps, speed > 0,
                  let minutes = icing.durationMin, minutes > 0 else { return .failure(.noCloud) }
            var numbers: [String: Any] = [
                "temperatureC": temperature, "lwcGm3": water, "dropletMicrons": droplet,
                "airspeedMps": speed, "durationS": minutes * 60,
            ]
            var canonicalNumbers: [String: EngineeringCanonicalValue] = [
                "temperatureC": .number(temperature), "lwcGm3": .number(water), "dropletMicrons": .number(droplet),
                "airspeedMps": .number(speed), "durationS": .number(minutes * 60),
            ]
            if let altitude = icing.altitudeM {
                numbers["altitudeM"] = altitude
                canonicalNumbers["altitudeM"] = .number(altitude)
            }
            condition = numbers
            canonicalCondition = .object(canonicalNumbers)
        }

        var block: [String: Any] = [
            "flowAxis": frame.cadAxisLetter(icing.flowAxis),
            "spanAxis": frame.cadAxisLetter(icing.spanAxis),
            "angleOfAttackDeg": icing.angleOfAttackDeg,
            "stations": icing.stations,
            "panels": icing.panels,
            "trajectories": icing.trajectories,
            "refinementFactor": icing.refinementFactor,
            "surfaceElementSizeM": surface,
            "condition": condition,
        ]
        if let flight { block["flight"] = flight }
        var canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("icing"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "flowAxis": .string(frame.cadAxisLetter(icing.flowAxis)),
            "spanAxis": .string(frame.cadAxisLetter(icing.spanAxis)),
            "angleOfAttackDeg": .number(icing.angleOfAttackDeg),
            "stations": .number(Double(icing.stations)),
            "panels": .number(Double(icing.panels)),
            "trajectories": .number(Double(icing.trajectories)),
            "refinementFactor": .number(icing.refinementFactor),
            "surfaceElementSizeM": .number(surface),
            "condition": canonicalCondition,
            "coarseElementSizeM": .number(size),
            "meshRefinementFactor": .number(loadCase.refinementFactor),
        ]
        if let flight {
            canonical["flight"] = .object([
                "airspeedMps": .number(flight["airspeedMps"] as! Double),
                "durationS": .number(flight["durationS"] as! Double),
            ])
        }
        for (key, value) in [("antiIceTargetC", icing.antiIceTargetC), ("antiIceBudgetW", icing.antiIceBudgetW),
                             ("maximumIceThicknessMm", icing.maximumIceThicknessMm)] {
            if let value {
                block[key] = value
                canonical[key] = .number(value)
            }
        }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "icing",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name],
            "icing": block,
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .icing, body: body, jobJSON: data,
            consumedUpstream: [], settings: .object(canonical)))
    }

    /// 14 CFR 25.629 flutter. The supports are the root; the load case carries no loads.
    private static func prepareFlutter(
        _ loadCase: WorkbenchStructuralCase,
        flutter: WorkbenchStructuralCase.FlutterSettings,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        if let missing = loadCase.supports.map(\.faceID).first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard !loadCase.supports.isEmpty else { return .failure(.noSupport) }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard flutter.flowAxis != flutter.spanAxis else { return .failure(.sameAxes) }
        guard flutter.airDensityKgM3 > 0 else { return .failure(.noCloud) }
        guard flutter.highSpeedMps > flutter.lowSpeedMps, flutter.lowSpeedMps > 0, flutter.speeds >= 2 else { return .failure(.noSweep) }
        guard flutter.stations >= 4 else { return .failure(.noCloud) }
        guard let dive = flutter.diveSpeedMps, dive > 0 else { return .failure(.noDiveSpeed) }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "flutter",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports],
            "flutter": [
                "flowAxis": frame.cadAxisLetter(flutter.flowAxis),
                "spanAxis": frame.cadAxisLetter(flutter.spanAxis),
                "stations": flutter.stations,
                "airDensityKgM3": flutter.airDensityKgM3,
                "structuralDamping": flutter.structuralDamping,
                "diveSpeedMps": dive,
                "marginFactor": flutter.marginFactor,
                "lowSpeedMps": flutter.lowSpeedMps,
                "highSpeedMps": flutter.highSpeedMps,
                "speeds": flutter.speeds,
            ],
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        let canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("flutter"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map {
                .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
            }),
            "flowAxis": .string(frame.cadAxisLetter(flutter.flowAxis)),
            "spanAxis": .string(frame.cadAxisLetter(flutter.spanAxis)),
            "stations": .number(Double(flutter.stations)),
            "airDensityKgM3": .number(flutter.airDensityKgM3),
            "structuralDamping": .number(flutter.structuralDamping),
            "diveSpeedMps": .number(dive),
            "marginFactor": .number(flutter.marginFactor),
            "lowSpeedMps": .number(flutter.lowSpeedMps),
            "highSpeedMps": .number(flutter.highSpeedMps),
            "speeds": .number(Double(flutter.speeds)),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
        ]
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .flutter, body: body, jobJSON: data,
            consumedUpstream: [], settings: .object(canonical)))
    }

    /// 14 CFR 25.571(e) bird strike.
    private static func prepareBird(
        _ loadCase: WorkbenchStructuralCase,
        bird: WorkbenchStructuralCase.BirdSettings,
        build: WorkbenchBuild,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        var used = loadCase.supports.map(\.faceID) + loadCase.exclusions.map(\.faceID) + bird.equipment.map(\.faceID)
        if let face = bird.impactFaceID { used.append(face) }
        if let missing = used.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard !loadCase.supports.isEmpty else { return .failure(.noSupport) }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard let modes = bird.modeCount, modes >= 1 else { return .failure(.noModeCount) }
        guard let zeta = bird.dampingRatio, zeta > 0, zeta < 1 else { return .failure(.noDamping) }
        guard let face = bird.impactFaceID, !face.isEmpty else { return .failure(.noImpactFace) }
        guard let speed = bird.speedMps, speed > 0 else { return .failure(.noBirdSpeed) }
        guard bird.massKg > 0 else { return .failure(.noBirdSpeed) }
        guard bird.obliquityDeg > 0, bird.obliquityDeg <= 90 else { return .failure(.zeroDirection) }
        let modelDirection = bird.direction.simd
        guard simd_length(modelDirection) > 0 else { return .failure(.zeroDirection) }
        let direction = simd_normalize(frame.modelToCAD(modelDirection))

        var consumed: Set<EngineeringTestType> = []
        var masses: [[String: Any]] = []
        var resolvedMasses: [EngineeringCanonicalValue] = []
        switch attachedMasses(bird.equipment, build: build, state: state, consumed: &consumed) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (masses, resolvedMasses) = resolved
        }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let exclusions: [[String: Any]] = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        let birdBlock: [String: Any] = [
            "massKg": bird.massKg,
            "speedMps": speed,
            "obliquityDeg": bird.obliquityDeg,
            "densityKgM3": 950,
            "lengthToDiameter": 2,
            "shockSpeedMps": 1480,
            "shockSlope": 2,
        ]
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "bird",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports, "stressExclusions": exclusions],
            "bird": [
                "modeCount": modes,
                "dampingRatio": zeta,
                "impactFace": face,
                "direction": [direction.x, direction.y, direction.z],
                "bird": birdBlock,
                "attachedMasses": masses,
            ],
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        let canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("bird"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map {
                .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
            }),
            "stressExclusions": .array(loadCase.exclusions.map {
                .object(["face": .string($0.faceID), "distanceM": .number($0.distanceM)])
            }),
            "modeCount": .number(Double(modes)),
            "dampingRatio": .number(zeta),
            "impactFace": .string(face),
            "direction": .vector(direction),
            "bird": .object([
                "massKg": .number(bird.massKg), "speedMps": .number(speed), "obliquityDeg": .number(bird.obliquityDeg),
            ]),
            "attachedMasses": .array(resolvedMasses),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ]
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .birdStrike, body: body, jobJSON: data,
            consumedUpstream: consumed, settings: .object(canonical)))
    }

    /// Equipment of a thermal case: °C as the datasheets are written → kelvin as the solver reads.
    /// A component with neither limit is refused: it would be carried through the whole calculation
    /// and then judged against nothing.
    private static func thermalComponents(_ items: [WorkbenchStructuralCase.ThermalComponent], faceIDs: Set<String>)
        -> Result<([[String: Any]], [EngineeringCanonicalValue]), WorkbenchStructuralError> {
        var json: [[String: Any]] = []
        var canonical: [EngineeringCanonicalValue] = []
        for item in items {
            guard faceIDs.contains(item.faceID) else { return .failure(.faceMissing(item.faceID)) }
            guard item.minimumC != nil || item.maximumC != nil else { return .failure(.componentWithoutLimits(item.name)) }
            var object: [String: Any] = ["name": item.name, "face": item.faceID, "powerW": item.powerW]
            var fields: [String: EngineeringCanonicalValue] = [
                "name": .string(item.name), "face": .string(item.faceID), "powerW": .number(item.powerW),
            ]
            if let minimum = item.minimumC {
                object["minimumK"] = minimum + 273.15
                fields["minimumK"] = .number(minimum + 273.15)
            }
            if let maximum = item.maximumC {
                object["maximumK"] = maximum + 273.15
                fields["maximumK"] = .number(maximum + 273.15)
            }
            json.append(object)
            canonical.append(.object(fields))
        }
        return .success((json, canonical))
    }

    /// MIL-STD-810H climate. The load case holds supports and exclusion zones only: the solver
    /// refuses a climate job that also brings static loads, because temperature is the load.
    private static func prepareClimate(
        _ loadCase: WorkbenchStructuralCase,
        climate: WorkbenchStructuralCase.ClimateSettings,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        let used = loadCase.supports.map(\.faceID) + loadCase.exclusions.map(\.faceID)
        if let missing = used.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard let airSpeed = climate.airSpeedMps, airSpeed >= 0 else { return .failure(.noAirSpeed) }
        guard let absorptance = climate.solarAbsorptance, absorptance > 0, absorptance <= 1,
              let emissivity = climate.emissivity, emissivity > 0, emissivity <= 1 else { return .failure(.noSurfaceProperties) }
        guard let assemblyC = climate.assemblyC else { return .failure(.noAssemblyTemperature) }
        guard let step = climate.stepS, step > 0 else { return .failure(.noTimeStep) }
        guard simd_length(climate.up.simd) > 0, simd_length(climate.flow.simd) > 0 else { return .failure(.zeroDirection) }

        var components: [[String: Any]] = []
        var canonicalComponents: [EngineeringCanonicalValue] = []
        switch thermalComponents(climate.components, faceIDs: faceIDs) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (components, canonicalComponents) = resolved
        }

        let up = simd_normalize(frame.modelToCAD(climate.up.simd))
        let flow = simd_normalize(frame.modelToCAD(climate.flow.simd))
        let hot = climate.environment == .hot
        var block: [String: Any] = [
            "environment": climate.environment.rawValue,
            "category": hot ? climate.hotCategory.rawValue : climate.coldCategory.rawValue,
            "exposure": hot ? climate.hotExposure.rawValue : climate.coldExposure.rawValue,
            "airflow": climate.airflow.rawValue,
            "airSpeedMps": airSpeed,
            "upDirection": [up.x, up.y, up.z],
            "flowDirection": [flow.x, flow.y, flow.z],
            "solarAbsorptance": absorptance,
            "emissivity": emissivity,
            "stressFreeK": assemblyC + 273.15,
            "operating": climate.operating,
            "components": components,
            "convectionBand": climate.convectionBand,
            "stepS": step,
        ]
        if let altitude = climate.altitudeM { block["altitudeM"] = altitude }
        if let minimum = climate.materialMinimumC { block["materialMinimumK"] = minimum + 273.15 }
        if let maximum = climate.materialMaximumC { block["materialMaximumK"] = maximum + 273.15 }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let exclusions: [[String: Any]] = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "climate",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports, "stressExclusions": exclusions],
            "climate": block,
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        var canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("climate"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map {
                .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
            }),
            "environment": .string(climate.environment.rawValue),
            "category": .string(hot ? climate.hotCategory.rawValue : climate.coldCategory.rawValue),
            "exposure": .string(hot ? climate.hotExposure.rawValue : climate.coldExposure.rawValue),
            "airflow": .string(climate.airflow.rawValue),
            "airSpeedMps": .number(airSpeed),
            "upDirection": .vector(up),
            "flowDirection": .vector(flow),
            "solarAbsorptance": .number(absorptance),
            "emissivity": .number(emissivity),
            "stressFreeK": .number(assemblyC + 273.15),
            "operating": .bool(climate.operating),
            "components": .array(canonicalComponents),
            "convectionBand": .number(climate.convectionBand),
            "stepS": .number(step),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ]
        if let altitude = climate.altitudeM { canonical["altitudeM"] = .number(altitude) }
        if let minimum = climate.materialMinimumC { canonical["materialMinimumK"] = .number(minimum + 273.15) }
        if let maximum = climate.materialMaximumC { canonical["materialMaximumK"] = .number(maximum + 273.15) }
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .climatic, body: body, jobJSON: data,
            consumedUpstream: [], settings: .object(canonical)))
    }

    /// ISO 2685 / AC 20-135 flame. Unlike climate, a fire case carries the mechanical load of the
    /// fire situation: the part is judged hot and loaded at once.
    private static func prepareFire(
        _ loadCase: WorkbenchStructuralCase,
        fire: WorkbenchStructuralCase.FireSettings,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        build: WorkbenchBuild,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        let resolved: ResolvedLoads
        switch resolveLoads(loadCase, build: build, body: body, frame: frame, state: state) {
        case let .failure(error): return .failure(error)
        case let .success(value): resolved = value
        }
        let size = loadCase.coarseElementSizeM!
        guard let duration = fire.durationS, duration > 0 else { return .failure(.noDuration) }
        guard !fire.flameFaceIDs.isEmpty else { return .failure(.noFlameFace) }
        if let missing = fire.flameFaceIDs.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard let emissivity = fire.surfaceEmissivity, emissivity > 0, emissivity <= 1 else { return .failure(.noSurfaceProperties) }
        guard let step = fire.stepS, step > 0 else { return .failure(.noTimeStep) }

        var components: [[String: Any]] = []
        var canonicalComponents: [EngineeringCanonicalValue] = []
        switch thermalComponents(fire.components, faceIDs: faceIDs) {
        case let .failure(error): return .failure(error)
        case let .success(value): (components, canonicalComponents) = value
        }

        let job: [String: Any] = [
            "schema": schema,
            "analysis": "fire",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": resolved.loadCaseJSON(named: loadCase.name),
            "fire": [
                "standard": fire.standard.rawValue,
                "durationS": duration,
                "flameFaces": fire.flameFaceIDs,
                "surfaceEmissivity": emissivity,
                "stepS": step,
                "operating": fire.operating,
                "components": components,
            ],
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        var canonical = resolved.canonicalLoadCase
        canonical["analysis"] = .string("fire")
        canonical["case"] = .string(loadCase.id.uuidString.lowercased())
        canonical["body"] = .string(body.id)
        canonical["brepSha256"] = .string(body.geometry.sha256)
        canonical["material"] = .string(body.materialId)
        canonical["standard"] = .string(fire.standard.rawValue)
        canonical["durationS"] = .number(duration)
        canonical["flameFaces"] = .array(fire.flameFaceIDs.map { .string($0) })
        canonical["surfaceEmissivity"] = .number(emissivity)
        canonical["stepS"] = .number(step)
        canonical["operating"] = .bool(fire.operating)
        canonical["components"] = .array(canonicalComponents)
        canonical["coarseElementSizeM"] = .number(size)
        canonical["refinementFactor"] = .number(loadCase.refinementFactor)
        canonical["factorOfSafety"] = .number(loadCase.factorOfSafety)
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .fireResistance, body: body, jobJSON: data,
            consumedUpstream: resolved.consumed, settings: .object(canonical)))
    }

    /// SAE ARP5412 current through the part. Nothing is supported and nothing is loaded here: the
    /// current enters at the attachment face and leaves through the faces bonded to the structure.
    private static func prepareLightning(
        _ loadCase: WorkbenchStructuralCase,
        lightning: WorkbenchStructuralCase.LightningSettings,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        guard !lightning.components.isEmpty else { return .failure(.noLightningComponents) }
        guard !lightning.attachmentFaceIDs.isEmpty, !lightning.groundFaceIDs.isEmpty else { return .failure(.noAttachmentFace) }
        let used = lightning.attachmentFaceIDs + lightning.groundFaceIDs
        if let missing = used.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard let emissivity = lightning.surfaceEmissivity, emissivity > 0, emissivity <= 1 else { return .failure(.noSurfaceProperties) }
        guard lightning.continuingCurrentA >= 200, lightning.continuingCurrentA <= 800 else {
            return .failure(.currentOutOfRange(lightning.continuingCurrentA))
        }
        guard lightning.stepsPerComponent >= 1 else { return .failure(.noTimeStep) }

        var equipment: [[String: Any]] = []
        var canonicalEquipment: [EngineeringCanonicalValue] = []
        switch thermalComponents(lightning.equipment, faceIDs: faceIDs) {
        case let .failure(error): return .failure(error)
        case let .success(value): (equipment, canonicalEquipment) = value
        }

        // In the order of the standard's waveform, without repeats: A, B, C, D.
        let ordered = WorkbenchStructuralCase.LightningSettings.Component.allCases.filter { lightning.components.contains($0) }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "lightning",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name],
            "lightning": [
                "components": ordered.map(\.rawValue),
                "attachmentFaces": lightning.attachmentFaceIDs,
                "groundFaces": lightning.groundFaceIDs,
                "polarity": lightning.polarity.rawValue,
                "continuingCurrentA": lightning.continuingCurrentA,
                "surfaceEmissivity": emissivity,
                "stepsPerComponent": lightning.stepsPerComponent,
                "equipment": equipment,
            ],
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        let canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("lightning"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "components": .array(ordered.map { .string($0.rawValue) }),
            "attachmentFaces": .array(lightning.attachmentFaceIDs.map { .string($0) }),
            "groundFaces": .array(lightning.groundFaceIDs.map { .string($0) }),
            "polarity": .string(lightning.polarity.rawValue),
            "continuingCurrentA": .number(lightning.continuingCurrentA),
            "surfaceEmissivity": .number(emissivity),
            "stepsPerComponent": .number(Double(lightning.stepsPerComponent)),
            "equipment": .array(canonicalEquipment),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ]
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .lightningDirect, body: body, jobJSON: data,
            consumedUpstream: [], settings: .object(canonical)))
    }

    /// Common checks of a vibration case: faces that still exist, modes, damping, mesh. What differs
    /// between sine and random is the excitation, not the part.
    private static func vibrationPreflight(
        _ loadCase: WorkbenchStructuralCase,
        body: WorkbenchConstruction.Body,
        faces: [String?],
        modeCount: Int?,
        dampingRatio: Double?
    ) -> WorkbenchStructuralError? {
        let faceIDs = Set(body.faces.map(\.id))
        let used = loadCase.supports.map(\.faceID) + loadCase.exclusions.map(\.faceID) + faces.compactMap { $0 }
        if let missing = used.first(where: { !faceIDs.contains($0) }) { return .faceMissing(missing) }
        if loadCase.supports.isEmpty { return .noSupport }
        guard let modes = modeCount, modes >= 1 else { return .noModeCount }
        guard let zeta = dampingRatio, zeta > 0, zeta < 1 else { return .noDamping }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .noElementSize }
        _ = size
        if loadCase.refinementFactor < 1.3 { return .refinementTooSmall }
        return nil
    }

    /// Spectrum points as the solver reads them: rising in frequency, positive, scaled from the unit
    /// the standards are written in to SI.
    private static func spectrum(_ points: [WorkbenchStructuralCase.SpectrumPoint], scale: Double, minimum: Int)
        -> Result<([[Double]], [EngineeringCanonicalValue]), WorkbenchStructuralError> {
        guard points.count >= minimum else { return .failure(.noSpectrum) }
        var previous = -Double.infinity
        for point in points {
            guard point.frequencyHz > 0, point.value > 0, point.frequencyHz > previous else { return .failure(.noSpectrum) }
            previous = point.frequencyHz
        }
        let pairs = points.map { [$0.frequencyHz, $0.value * scale] }
        let canonical = pairs.map { EngineeringCanonicalValue.array([.number($0[0]), .number($0[1])]) }
        return .success((pairs, canonical))
    }

    /// Sine vibration: a shaker, a force or a rotor imbalance over a frequency range.
    private static func prepareSine(
        _ loadCase: WorkbenchStructuralCase,
        sine: WorkbenchStructuralCase.SineSettings,
        build: WorkbenchBuild,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        if let error = vibrationPreflight(loadCase, body: body, faces: [sine.faceID, sine.probeFaceID],
                                          modeCount: sine.modeCount, dampingRatio: sine.dampingRatio) {
            return .failure(error)
        }
        let modes = sine.modeCount!, zeta = sine.dampingRatio!, size = loadCase.coarseElementSizeM!
        guard let from = sine.fromHz, let to = sine.toHz, from > 0, to > from else { return .failure(.noRange) }
        guard sine.sweepPoints >= 2 else { return .failure(.noRange) }
        let modelDirection = sine.direction.simd
        guard simd_length(modelDirection) > 0 else { return .failure(.zeroDirection) }
        let direction = simd_normalize(frame.modelToCAD(modelDirection))
        if sine.excitation != .base, sine.faceID == nil { return .failure(.noExcitationFace) }

        var consumed: Set<EngineeringTestType> = []
        var masses: [[String: Any]] = []
        var resolvedMasses: [EngineeringCanonicalValue] = []
        switch attachedMasses(sine.equipment, build: build, state: state, consumed: &consumed) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (masses, resolvedMasses) = resolved
        }

        var excitation: [String: Any] = [
            "kind": sine.excitation == .base ? "base" : "force",
            "direction": [direction.x, direction.y, direction.z],
        ]
        var canonicalExcitation: [String: EngineeringCanonicalValue] = [
            "kind": .string(sine.excitation == .base ? "base" : "force"),
            "direction": .array([.number(direction.x), .number(direction.y), .number(direction.z)]),
        ]
        if sine.excitation != .base, let face = sine.faceID {
            excitation["face"] = face
            canonicalExcitation["face"] = .string(face)
        }
        if sine.excitation == .imbalance {
            guard let imbalance = sine.imbalanceGmm, imbalance > 0 else { return .failure(.noSpectrum) }
            // g·mm as a balancing machine reports it → kg·m as the solver reads it.
            excitation["imbalanceKgM"] = imbalance * 1e-6
            canonicalExcitation["imbalanceKgM"] = .number(imbalance * 1e-6)
        } else {
            // A shaker is specified in g, a force in newtons.
            let scale = sine.excitation == .base ? standardGravity : 1.0
            switch spectrum(sine.amplitude, scale: scale, minimum: 1) {
            case let .failure(error): return .failure(error)
            case let .success((pairs, canonical)):
                excitation["amplitude"] = pairs
                canonicalExcitation["amplitude"] = .array(canonical)
            }
        }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let exclusions: [[String: Any]] = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        var block: [String: Any] = [
            "modeCount": modes,
            "dampingRatio": zeta,
            "excitation": excitation,
            "frequencyRangeHz": [from, to],
            "sweepPoints": sine.sweepPoints,
            "attachedMasses": masses,
        ]
        if let probe = sine.probeFaceID { block["probeFace"] = probe }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "harmonic",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports, "stressExclusions": exclusions],
            "harmonic": block,
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        var canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("harmonic"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map {
                .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
            }),
            "stressExclusions": .array(loadCase.exclusions.map {
                .object(["face": .string($0.faceID), "distanceM": .number($0.distanceM)])
            }),
            "modeCount": .number(Double(modes)),
            "dampingRatio": .number(zeta),
            "excitation": .object(canonicalExcitation),
            "frequencyRangeHz": .array([.number(from), .number(to)]),
            "sweepPoints": .number(Double(sine.sweepPoints)),
            "attachedMasses": .array(resolvedMasses),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ]
        if let probe = sine.probeFaceID { canonical["probeFace"] = .string(probe) }
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .modalVibration, body: body, jobJSON: data,
            consumedUpstream: consumed, settings: .object(canonical)))
    }

    /// Random vibration: an acceleration PSD on the fixture.
    private static func prepareRandom(
        _ loadCase: WorkbenchStructuralCase,
        random: WorkbenchStructuralCase.RandomSettings,
        build: WorkbenchBuild,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        if let error = vibrationPreflight(loadCase, body: body, faces: [random.probeFaceID],
                                          modeCount: random.modeCount, dampingRatio: random.dampingRatio) {
            return .failure(error)
        }
        let modes = random.modeCount!, zeta = random.dampingRatio!, size = loadCase.coarseElementSizeM!
        let modelDirection = random.direction.simd
        guard simd_length(modelDirection) > 0 else { return .failure(.zeroDirection) }
        let direction = simd_normalize(frame.modelToCAD(modelDirection))

        var consumed: Set<EngineeringTestType> = []
        var masses: [[String: Any]] = []
        var resolvedMasses: [EngineeringCanonicalValue] = []
        switch attachedMasses(random.equipment, build: build, state: state, consumed: &consumed) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (masses, resolvedMasses) = resolved
        }
        // A schedule is written in g²/Hz; the solver reads (m/s²)²/Hz. Two points at least: one
        // point is not a spectrum, it is a number.
        var psd: [[Double]] = []
        var canonicalPsd: [EngineeringCanonicalValue] = []
        switch spectrum(random.psd, scale: standardGravity * standardGravity, minimum: 2) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (psd, canonicalPsd) = resolved
        }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let exclusions: [[String: Any]] = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        var block: [String: Any] = [
            "modeCount": modes,
            "dampingRatio": zeta,
            "direction": [direction.x, direction.y, direction.z],
            "accelerationPsd": psd,
            "attachedMasses": masses,
        ]
        if let probe = random.probeFaceID { block["probeFace"] = probe }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "random",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports, "stressExclusions": exclusions],
            "random": block,
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        var canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("random"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map {
                .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
            }),
            "stressExclusions": .array(loadCase.exclusions.map {
                .object(["face": .string($0.faceID), "distanceM": .number($0.distanceM)])
            }),
            "modeCount": .number(Double(modes)),
            "dampingRatio": .number(zeta),
            "direction": .array([.number(direction.x), .number(direction.y), .number(direction.z)]),
            "accelerationPsd": .array(canonicalPsd),
            "attachedMasses": .array(resolvedMasses),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ]
        if let probe = random.probeFaceID { canonical["probeFace"] = .string(probe) }
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .modalVibration, body: body, jobJSON: data,
            consumedUpstream: consumed, settings: .object(canonical)))
    }

    /// One acceleration pulse on the fixture. The load case carries supports and exclusion zones
    /// only: `cadnext_structural` refuses a shock job that also brings static loads, because a
    /// shock is the load.
    private static func prepareShock(
        _ loadCase: WorkbenchStructuralCase,
        shock: WorkbenchStructuralCase.ShockSettings,
        build: WorkbenchBuild,
        body: WorkbenchConstruction.Body,
        frame: WorkbenchCADFrame,
        state: EngineeringValidationState
    ) -> Result<WorkbenchStructuralJob, WorkbenchStructuralError> {
        let faceIDs = Set(body.faces.map(\.id))
        var usedFaces = loadCase.supports.map(\.faceID) + shock.equipment.map(\.faceID) + loadCase.exclusions.map(\.faceID)
        if let probe = shock.probeFaceID { usedFaces.append(probe) }
        if let missing = usedFaces.first(where: { !faceIDs.contains($0) }) { return .failure(.faceMissing(missing)) }
        guard !loadCase.supports.isEmpty else { return .failure(.noSupport) }
        guard let modes = shock.modeCount, modes >= 1 else { return .failure(.noModeCount) }
        guard let zeta = shock.dampingRatio, zeta > 0, zeta < 1 else { return .failure(.noDamping) }
        guard let peakG = shock.peakG, peakG > 0, let durationMs = shock.durationMs, durationMs > 0 else { return .failure(.noPulse) }
        if shock.shape == .trapezoid {
            guard shock.riseMs > 0, shock.fallMs > 0, shock.riseMs + shock.fallMs <= durationMs else { return .failure(.invalidTrapezoid) }
        }
        guard let size = loadCase.coarseElementSizeM, size > 0 else { return .failure(.noElementSize) }
        guard loadCase.refinementFactor >= 1.3 else { return .failure(.refinementTooSmall) }
        let modelDirection = shock.direction.simd
        guard simd_length(modelDirection) > 0 else { return .failure(.zeroDirection) }
        let direction = simd_normalize(frame.modelToCAD(modelDirection))

        var consumed: Set<EngineeringTestType> = []
        var masses: [[String: Any]] = []
        var resolvedMasses: [EngineeringCanonicalValue] = []
        switch attachedMasses(shock.equipment, build: build, state: state, consumed: &consumed) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): (masses, resolvedMasses) = resolved
        }

        let peak = peakG * standardGravity
        let duration = durationMs / 1e3
        var pulse: [String: Any] = ["shape": shock.shape.rawValue, "peakMps2": peak, "durationS": duration]
        var canonicalPulse: [String: EngineeringCanonicalValue] = [
            "shape": .string(shock.shape.rawValue), "peakMps2": .number(peak), "durationS": .number(duration),
        ]
        if shock.shape == .trapezoid {
            pulse["riseS"] = shock.riseMs / 1e3
            pulse["fallS"] = shock.fallMs / 1e3
            canonicalPulse["riseS"] = .number(shock.riseMs / 1e3)
            canonicalPulse["fallS"] = .number(shock.fallMs / 1e3)
        }

        let supports: [[String: Any]] = loadCase.supports.map { support in
            ["face": support.faceID, "fix": Array(Set(support.fixed.map(frame.cadAxisLetter))).sorted()]
        }
        let exclusions: [[String: Any]] = loadCase.exclusions.map { ["face": $0.faceID, "distanceM": $0.distanceM] }
        var shockBlock: [String: Any] = [
            "modeCount": modes,
            "dampingRatio": zeta,
            "direction": [direction.x, direction.y, direction.z],
            "pulse": pulse,
            "attachedMasses": masses,
        ]
        if let probe = shock.probeFaceID { shockBlock["probeFace"] = probe }
        let job: [String: Any] = [
            "schema": schema,
            "analysis": "shock",
            "geometry": ["format": "brep", "path": partFileName],
            "material": body.materialId,
            "factorOfSafety": loadCase.factorOfSafety,
            "mesh": ["coarseElementSizeM": size, "refinementFactor": loadCase.refinementFactor],
            "loadCase": ["name": loadCase.name, "supports": supports, "stressExclusions": exclusions],
            "shock": shockBlock,
            "output": ["result": resultFileName, "field": fieldFileName],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.encodingFailed)
        }
        var canonical: [String: EngineeringCanonicalValue] = [
            "analysis": .string("shock"),
            "case": .string(loadCase.id.uuidString.lowercased()),
            "body": .string(body.id),
            "brepSha256": .string(body.geometry.sha256),
            "material": .string(body.materialId),
            "supports": .array(supports.map {
                .object(["face": .string($0["face"] as! String), "fix": .array(($0["fix"] as! [String]).map { .string($0) })])
            }),
            "stressExclusions": .array(loadCase.exclusions.map {
                .object(["face": .string($0.faceID), "distanceM": .number($0.distanceM)])
            }),
            "modeCount": .number(Double(modes)),
            "dampingRatio": .number(zeta),
            "direction": .array([.number(direction.x), .number(direction.y), .number(direction.z)]),
            "pulse": .object(canonicalPulse),
            "attachedMasses": .array(resolvedMasses),
            "coarseElementSizeM": .number(size),
            "refinementFactor": .number(loadCase.refinementFactor),
            "factorOfSafety": .number(loadCase.factorOfSafety),
        ]
        if let probe = shock.probeFaceID { canonical["probeFace"] = .string(probe) }
        return .success(WorkbenchStructuralJob(
            caseID: loadCase.id, testType: .mechanicalShock, body: body, jobJSON: data,
            consumedUpstream: consumed, settings: .object(canonical)))
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
    case noDamping
    case noSpectrum
    case noRange
    case noExcitationFace
    case noAirSpeed
    case noSurfaceProperties
    case noAssemblyTemperature
    case noTimeStep
    case noDuration
    case noFlameFace
    case noAttachmentFace
    case noLightningComponents
    case noField
    case noSweep
    case noSurfaceElementSize
    case noCloud
    case sameAxes
    case noDiveSpeed
    case noImpactFace
    case noBirdSpeed
    case currentOutOfRange(Double)
    case componentWithoutLimits(String)
    case noPulse
    case invalidTrapezoid
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
        case .noDamping: return "Не задано модальное демпфирование (доля критического, 0 < ζ < 1): у него нет разумного умолчания."
        case .noSpectrum: return "Не задан спектр: нужны точки (частота, значение), возрастающие по частоте и положительные."
        case .noRange: return "Не задан диапазон частот развёртки."
        case .noExcitationFace: return "Не задана грань, к которой приложено возбуждение."
        case .noAirSpeed: return "Не задана скорость обдува: неподвижный воздух в камере — это тоже скорость (1.5 м/с по стандарту), и ноль даёт другой расчёт."
        case .noSurfaceProperties: return "Не заданы свойства поверхности: поглощение солнца α и излучательная способность ε (0 < значение ≤ 1)."
        case .noAssemblyTemperature: return "Не задана температура сборки: от неё считаются тепловые напряжения."
        case .noTimeStep: return "Не задан шаг по времени."
        case .noDuration: return "Не задана длительность воздействия."
        case .noFlameFace: return "Не выбрано ни одной грани под пламенем."
        case .noAttachmentFace: return "Не выбрана грань привязки дуги и грань, связанная с конструкцией."
        case .noLightningComponents: return "Не выбран ни один компонент тока молнии."
        case .noField: return "Не задано поле: выберите уровень стандарта или укажите своё значение в В/м."
        case .noSweep: return "Не задана развёртка по частоте: от, до и число точек."
        case .noSurfaceElementSize: return "Не задан размер элемента поверхности."
        case .noCloud: return "Не заданы параметры облака: температура, водность, диаметр капель, скорость и время."
        case .sameAxes: return "Ось потока и ось размаха совпадают: они должны различаться."
        case .noDiveSpeed: return "Не задана скорость пикирования V_D: без неё запас по 25.629 не с чем сравнивать."
        case .noImpactFace: return "Не задана грань удара птицы."
        case .noBirdSpeed: return "Не задана скорость встречи с птицей."
        case let .currentOutOfRange(value):
            return String(format: "Продолжающийся ток %.0f А вне диапазона стандарта 200…800 А.", value)
        case let .componentWithoutLimits(name): return "У оборудования «\(name)» не задан ни один предел температуры."
        case .noPulse: return "Не задан импульс удара: нужны амплитуда в g и длительность."
        case .invalidTrapezoid: return "Трапеция: фронт и спад должны быть больше нуля и вместе не длиннее импульса."
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
