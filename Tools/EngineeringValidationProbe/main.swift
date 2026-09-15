import Foundation
import simd

// Engineering Validation — phase 0 gate.
//
// Everything a solver will later write goes through the machinery checked here: the snapshot
// a record is stamped against, the fingerprints that decide staleness, the dependency graph
// that carries it downstream, the readiness rules. None of it involves a solver, so all of it
// can be pinned exactly — no tolerances, no wall clock, no randomness.
//
// The heart of the probe is the change table of spec §10. Each scenario applies one change
// to a blueprint on which every applicable test is current, and compares the set of tests the
// engine calls OUTDATED with an expected set. Where the expected set differs from the spec's
// table, the scenario says what the spec omitted and why the physics requires it.
//
//   Tools/EngineeringValidationProbe/run.sh

var failures = 0
var checks = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  PASS  \(name)")
    } else {
        failures += 1
        let text = detail()
        print("  FAIL  \(name)\(text.isEmpty ? "" : " — " + text)")
    }
}

func section(_ title: String) {
    print("")
    print(title)
    print(String(repeating: "-", count: 96))
}

func names(_ tests: Set<EngineeringTestType>) -> String {
    tests.map(\.rawValue).sorted().joined(separator: ", ")
}

// MARK: - Harness

extension Result where Failure == WorkbenchStructuralError {
    func isFailure(_ expected: WorkbenchStructuralError) -> Bool {
        if case let .failure(error) = self { return error == expected }
        return false
    }
}

/// Deterministic record clock: each record one second after the previous.
var clock = Date(timeIntervalSince1970: 1_800_000_000)
func tick() -> Date {
    clock = clock.addingTimeInterval(1)
    return clock
}

func syntheticMetrics(_ type: EngineeringTestType, variant: Double = 0) -> [String: EngineeringMetric] {
    let index = Double(EngineeringTestType.allCases.firstIndex(of: type)!)
    return ["result": EngineeringMetric(100 + index + variant, unit: "u")]
}

/// Runs every applicable test in dependency order, as a solver pipeline would.
/// `clean` lists tests that must not consume their optional upstream results (a clean-airframe
/// AoA sweep ignores the propulsion bench).
func runAll(
    _ snapshot: EngineeringConfigurationSnapshot,
    clean: Set<EngineeringTestType> = [.aerodynamics]
) -> [EngineeringTestRecord] {
    var records: [EngineeringTestRecord] = []
    for type in EngineeringTestCatalog.topologicalOrder()! {
        let definition = EngineeringTestCatalog.definition(type)
        guard definition.applies(to: snapshot.airframe) else { continue }
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
        let consumed: Set<EngineeringTestType>? = clean.contains(type)
            ? Set(definition.upstream.filter { $0.requiredFor.contains(snapshot.airframe) }.map(\.test))
            : nil
        records.append(EngineeringValidationEngine.makeRecord(
            type, snapshot: snapshot, state: state, outcome: .pass,
            metrics: syntheticMetrics(type), solverID: "probe", solverVersion: "0",
            consumedUpstream: consumed, createdAt: tick()))
    }
    return records
}

func rerun(
    _ type: EngineeringTestType,
    _ snapshot: EngineeringConfigurationSnapshot,
    _ records: inout [EngineeringTestRecord],
    variant: Double = 0
) {
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
    records.append(EngineeringValidationEngine.makeRecord(
        type, snapshot: snapshot, state: state, outcome: .pass,
        metrics: syntheticMetrics(type, variant: variant), solverID: "probe", solverVersion: "0",
        consumedUpstream: type == .aerodynamics ? [] : nil, createdAt: tick()))
}

func outdated(_ snapshot: EngineeringConfigurationSnapshot, _ records: [EngineeringTestRecord]) -> Set<EngineeringTestType> {
    Set(EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records).outdatedTests)
}

func reasons(_ snapshot: EngineeringConfigurationSnapshot, _ records: [EngineeringTestRecord], _ type: EngineeringTestType) -> String {
    EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
        .evaluation(type)?.reasons.map(\.displayText).joined(separator: " | ") ?? "n/a"
}

/// Applies `change` to a blueprint whose tests are all current and checks the outdated set.
@discardableResult
func scenario(
    _ name: String,
    base: WorkbenchBuild,
    expected: Set<EngineeringTestType>,
    change: (inout WorkbenchBuild) -> Void
) -> (EngineeringConfigurationSnapshot, [EngineeringTestRecord]) {
    let before = WorkbenchEngineeringSnapshot.make(from: base)
    let records = runAll(before)
    let baseline = outdated(before, records)
    check(baseline.isEmpty, "\(name): baseline fully current", names(baseline))
    var changed = base
    change(&changed)
    let after = WorkbenchEngineeringSnapshot.make(from: changed)
    let result = outdated(after, records)
    check(result == expected, "\(name): outdated set",
          "got [\(names(result))], expected [\(names(expected))]; extra reasons: "
          + result.subtracting(expected).map { "\($0.rawValue): \(reasons(after, records, $0))" }.joined(separator: "; "))
    return (after, records)
}

func library(_ kind: WorkbenchComponentKind, otherThan id: String?, where predicate: (WorkbenchComponentSpec) -> Bool = { _ in true }) -> WorkbenchComponentSpec {
    WorkbenchComponentLibrary.components(of: kind).first { $0.id != id && predicate($0) }!
}

// MARK: - 1. Dependency graph

section("1. Dependency graph")
let order = EngineeringTestCatalog.topologicalOrder()
check(order != nil, "declarations are acyclic")
check(Set(order ?? []) == Set(EngineeringTestType.allCases), "every test type has exactly one definition")
if let order {
    let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let violations = EngineeringTestCatalog.definitions.flatMap { definition in
        definition.upstream.filter { position[$0.test]! >= position[definition.type]! }
            .map { "\($0.test.rawValue)→\(definition.type.rawValue)" }
    }
    check(violations.isEmpty, "topological order puts upstream first", violations.joined(separator: ", "))
}
// systemEndurance already reads massProperties; making massProperties read it back closes a loop.
var cyclic = EngineeringTestCatalog.definitions
let massIndex = cyclic.firstIndex { $0.type == .massProperties }!
cyclic[massIndex] = EngineeringTestDefinition(
    type: .massProperties, definitionVersion: 1, inputs: [],
    upstream: [.init(test: .systemEndurance, requiredFor: [])],
    appliesTo: [.multicopter], requiredForReadinessOn: [], rationale: "")
check(EngineeringTestCatalog.topologicalOrder(cyclic) == nil, "an injected cycle is detected")
check(EngineeringTestCatalog.downstream(of: .massProperties)
      == [.structuralStatic, .modalVibration, .controlAuthority, .systemEndurance],
      "downstream(massProperties)", names(EngineeringTestCatalog.downstream(of: .massProperties)))
check(EngineeringFrameConvention.workbenchModel.isRightHanded, "workbench model axes are right-handed")
check(EngineeringFrameConvention.flightBody.isRightHanded, "flight body axes are right-handed")

// MARK: - 2. Canonical form and fingerprints

section("2. Canonical form and fingerprints")
check(EngineeringCanonicalValue.number(-0.0).fingerprint == EngineeringCanonicalValue.number(0.0).fingerprint,
      "-0.0 and 0.0 fingerprint identically")
check(EngineeringCanonicalValue.number(.nan).canonicalString != EngineeringCanonicalValue.number(0).canonicalString,
      "NaN never canonicalises to a number")
check(EngineeringCanonicalValue.number(1).fingerprint != EngineeringCanonicalValue.string("1").fingerprint,
      "number 1 and string \"1\" differ")
var forward: [String: EngineeringCanonicalValue] = [:]
var backward: [String: EngineeringCanonicalValue] = [:]
let keys = (0..<64).map { "k\($0)" }
for (i, key) in keys.enumerated() { forward[key] = .number(Double(i)) }
for (i, key) in keys.enumerated().reversed() { backward[key] = .number(Double(i)) }
check(EngineeringCanonicalValue.object(forward).canonicalString == EngineeringCanonicalValue.object(backward).canonicalString,
      "object key order does not matter")
check(EngineeringCanonicalValue.array([.number(1), .number(2)]).fingerprint
      != EngineeringCanonicalValue.array([.number(2), .number(1)]).fingerprint,
      "array order does matter")
check(EngineeringCanonicalValue.vector(SIMD3<Float>(0.1, 0.2, 0.3)).fingerprint
      == EngineeringCanonicalValue.vector(CodableVector3D(SIMD3<Float>(0.1, 0.2, 0.3))).fingerprint,
      "Float vector and its CodableVector3D copy agree")

for base in [WorkbenchBuild.defaultQuad(), .defaultFixedWing(), .defaultVTOL()] {
    let snapshot = WorkbenchEngineeringSnapshot.make(from: base)
    let data = try! JSONEncoder().encode(base)
    let decoded = try! JSONDecoder().decode(WorkbenchBuild.self, from: data)
    check(WorkbenchEngineeringSnapshot.make(from: decoded).snapshotID == snapshot.snapshotID,
          "\(base.vehicleArchitecture.rawValue): blueprint JSON round trip keeps the snapshot id")
    var identityOnly = base
    identityOnly.name = "Переименован"
    identityOnly.buildDescription = "другое описание"
    identityOnly.revision += 7
    identityOnly.tuning = WorkbenchTuning(rate: 1.6, expo: 0.5)
    check(WorkbenchEngineeringSnapshot.make(from: identityOnly).snapshotID == snapshot.snapshotID,
          "\(base.vehicleArchitecture.rawValue): name/description/revision/tuning do not change the snapshot id")
    let snapshotData = try! JSONEncoder().encode(snapshot)
    let snapshotBack = try! JSONDecoder().decode(EngineeringConfigurationSnapshot.self, from: snapshotData)
    check(snapshotBack.snapshotID == snapshot.snapshotID,
          "\(base.vehicleArchitecture.rawValue): snapshot JSON round trip keeps its id")
}

// MARK: - 3. Spec §10 change table

section("3. Spec §10 change table — fixed wing (clean-airframe CFD)")
let wing = WorkbenchBuild.defaultFixedWing()

// Spec: Mass & CG, structural (if load changed), endurance.
// Also outdated here, deliberately:
//   geometryAssembly — clearances are a function of where the pack sits;
//   modalVibration   — the mass matrix changed;
//   controlAuthority — the same moment now turns a different inertia about a different CG.
scenario("battery moved inside the bay", base: wing,
         expected: [.geometryAssembly, .massProperties, .structuralStatic, .modalVibration,
                    .controlAuthority, .systemEndurance]) { build in
    build.componentPlacements[WorkbenchComponentKind.battery.rawValue] = WorkbenchComponentPlacement(
        surface: .internalBay, offset: CodableVector3D(x: 0, y: 0, z: -0.02))
    build.revision += 1
}

// Spec: power, endurance, thermal; CFD stays valid.
// Also outdated until the bench is re-run: structuralStatic, modalVibration, controlAuthority
// read the bench (thrust on the mounts, the excitation band). Section 4 shows they return to
// current on their own once the bench reproduces the same curves.
let sameMassBattery: (inout WorkbenchBuild) -> Void = { build in
    var pack = build.spec(for: .battery)!
    pack.id = "probe-battery-hv"
    pack.params[WorkbenchComponentSpec.ParamKey.batteryCapacityMah, default: 0] += 500
    pack.params[WorkbenchComponentSpec.ParamKey.batteryEnergyWh, default: 0] += 11
    build.installImportedComponent(pack)
}
let (hvSnapshot, hvRecords) = scenario(
    "battery model changed, same mass and envelope", base: wing,
    expected: [.propulsionBench, .thermalLimits, .systemEndurance,
               .structuralStatic, .modalVibration, .controlAuthority],
    change: sameMassBattery)

// Spec: propulsion, vibration, thermal, endurance.
// Also outdated: massProperties and geometryAssembly (a different propeller has a different
// mass and disc), and through them structuralStatic and controlAuthority.
scenario("propeller changed", base: wing,
         expected: [.geometryAssembly, .massProperties, .propulsionBench, .structuralStatic,
                    .modalVibration, .thermalLimits, .controlAuthority, .systemEndurance]) { build in
    let current = build.propSpecID
    build.setSpec(library(.propeller, otherThan: current).id, for: .propeller)
}

// Spec: mechanism, control authority, power budget.
// Also outdated: mass/geometry (servo mass and envelope) and what reads mass.
scenario("servo changed", base: wing,
         expected: [.geometryAssembly, .massProperties, .mechanism, .structuralStatic,
                    .modalVibration, .controlAuthority, .systemEndurance]) { build in
    let current = build.servoSpecID
    build.setSpec(library(.servo, otherThan: current).id, for: .servo)
}

// Spec: CFD only if the external geometry changed.
var wingWithPayload = wing
let payload = library(.payload, otherThan: nil)
wingWithPayload.setSpec(payload.id, for: .payload)
wingWithPayload.componentPlacements[WorkbenchComponentKind.payload.rawValue] =
    WorkbenchComponentPlacement(surface: .internalBay)
scenario("internal payload moved", base: wingWithPayload,
         expected: [.geometryAssembly, .massProperties, .structuralStatic, .modalVibration,
                    .controlAuthority, .systemEndurance]) { build in
    build.componentPlacements[WorkbenchComponentKind.payload.rawValue] = WorkbenchComponentPlacement(
        surface: .internalBay, offset: CodableVector3D(x: 0, y: 0, z: 0.03))
}
var wingWithPodPayload = wingWithPayload
wingWithPodPayload.componentPlacements[WorkbenchComponentKind.payload.rawValue] =
    WorkbenchComponentPlacement(surface: .bottom)
scenario("external payload moved", base: wingWithPodPayload,
         expected: [.geometryAssembly, .massProperties, .structuralStatic, .modalVibration,
                    .controlAuthority, .systemEndurance, .aerodynamics, .mechanism]) { build in
    build.componentPlacements[WorkbenchComponentKind.payload.rawValue] = WorkbenchComponentPlacement(
        surface: .bottom, offset: CodableVector3D(x: 0, y: 0, z: 0.05))
}

// Spec: Mass & CG (if density changed), structural, modal. Workbench has no material
// selector yet, so the change is applied to the snapshot itself.
do {
    let before = WorkbenchEngineeringSnapshot.make(from: wing)
    let records = runAll(before)
    var after = before
    after.categories[EngineeringInputCategory.materials.rawValue]?["frame.skin"] = .string("titanium")
    let result = outdated(after, records)
    let expected: Set<EngineeringTestType> = [.massProperties, .structuralStatic, .modalVibration,
                                              .controlAuthority, .systemEndurance]
    check(result == expected, "material changed: outdated set", "got [\(names(result))]")
    // Two independent reasons, both true: it reads materials itself, and it reads mass.
    check(reasons(after, records, .structuralStatic)
          == "Изменились материалы: frame.skin | Зависит от неактуального результата «Масса, ЦТ, инерция»",
          "material changed: reasons name the part and the stale upstream", reasons(after, records, .structuralStatic))
}

// Spec: Mass & CG, structural, CFD, control authority — and everything else the frame carries.
scenario("different airframe", base: wing,
         expected: Set(EngineeringTestType.allCases)) { build in
    build = WorkbenchBuild(
        id: build.id, name: build.name,
        frame: .library(id: WorkbenchFrameLibrary.liftCruiseVTOL.id),
        vehicleArchitecture: .liftCruiseVTOL,
        motorSpecID: build.motorSpecID, propSpecID: build.propSpecID,
        batterySpecID: build.batterySpecID, escSpecID: build.escSpecID,
        servoSpecID: build.servoSpecID, flightControllerSpecID: build.flightControllerSpecID,
        receiverSpecID: build.receiverSpecID, cameraSpecID: build.cameraSpecID,
        gpsSpecID: build.gpsSpecID, landingGearSpecID: build.landingGearSpecID)
}

scenario("identity-only edits", base: wing, expected: []) { build in
    build.name = "Surveyor S1 — копия"
    build.tuning = WorkbenchTuning(rate: 1.3, expo: 0.35)
    build.revision += 3
}

section("3b. Multicopter: an open frame has no closed bay")
// On a quad the "internal bay" is the gap between plates, in the airstream: moving the pack
// there changes what the air sees. Contrast with the fixed-wing scenario above.
scenario("quad: battery moved between the plates", base: .defaultQuad(),
         expected: [.geometryAssembly, .massProperties, .structuralStatic, .modalVibration,
                    .controlAuthority, .systemEndurance, .aerodynamics]) { build in
    build.componentPlacements[WorkbenchComponentKind.battery.rawValue] = WorkbenchComponentPlacement(
        surface: .internalBay, offset: CodableVector3D(x: 0, y: 0, z: 0.012))
}

// MARK: - 4. Re-running upstream

section("4. Staleness is decided by numbers, not by the fact of a re-run")
do {
    var records = hvRecords
    rerun(.propulsionBench, hvSnapshot, &records)
    let afterSame = outdated(hvSnapshot, records)
    check(afterSame == [.thermalLimits, .systemEndurance],
          "bench re-run with identical curves: only the tests that read the battery directly stay outdated",
          names(afterSame))
    rerun(.propulsionBench, hvSnapshot, &records, variant: 1)
    let afterChanged = outdated(hvSnapshot, records)
    check(afterChanged == [.thermalLimits, .systemEndurance, .structuralStatic, .modalVibration, .controlAuthority],
          "bench re-run with different curves: its readers go outdated again", names(afterChanged))
    check(reasons(hvSnapshot, records, .structuralStatic) == "Пересчитан «Стенд силовой установки», результат изменился",
          "…and say why", reasons(hvSnapshot, records, .structuralStatic))
    for type in [EngineeringTestType.structuralStatic, .modalVibration, .thermalLimits, .controlAuthority, .systemEndurance] {
        rerun(type, hvSnapshot, &records)
    }
    check(outdated(hvSnapshot, records).isEmpty, "after re-running the readers everything is current")
}

do {
    // CFD with rotor slipstream reads the bench; a clean sweep does not.
    let snapshot = WorkbenchEngineeringSnapshot.make(from: wing)
    let withPropwash = runAll(snapshot, clean: [])
    var changed = wing
    sameMassBattery(&changed)
    let after = WorkbenchEngineeringSnapshot.make(from: changed)
    check(outdated(after, withPropwash).contains(.aerodynamics),
          "CFD that consumed propwash follows the propulsion bench")
    var cleanOnly = runAll(snapshot)
    check(!outdated(after, cleanOnly).contains(.aerodynamics),
          "clean-airframe CFD ignores it")
    rerun(.propulsionBench, snapshot, &cleanOnly, variant: 3)
    check(!outdated(snapshot, cleanOnly).contains(.aerodynamics),
          "a later bench result does not invalidate CFD that never read one")
}

do {
    // A strength result computed without the lift distribution: untrustworthy on a wing, the
    // normal case on a quad, where aerodynamics is optional for structure.
    func structuralWithoutAero(_ build: WorkbenchBuild) -> EngineeringTestEvaluation? {
        let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
        var records = runAll(snapshot)
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
        records.append(EngineeringValidationEngine.makeRecord(
            .structuralStatic, snapshot: snapshot, state: state, outcome: .pass,
            metrics: syntheticMetrics(.structuralStatic), solverID: "probe", solverVersion: "0",
            consumedUpstream: [.massProperties, .propulsionBench], createdAt: tick()))
        return EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records).evaluation(.structuralStatic)
    }
    let onWing = structuralWithoutAero(wing)
    check(onWing?.status == .outdated && onWing?.reasons == [.requiredUpstreamMissing(.aerodynamics)],
          "fixed wing: structure computed without lift is not trusted",
          onWing?.reasons.map(\.displayText).joined(separator: " | ") ?? "nil")
    check(structuralWithoutAero(.defaultQuad())?.status == .pass,
          "quad: structure computed without aerodynamics is current")
}

// MARK: - 5. Readiness

section("5. Readiness")
do {
    let snapshot = WorkbenchEngineeringSnapshot.make(from: wing)
    func readiness(_ records: [EngineeringTestRecord], inspection: Bool = false) -> EngineeringReadiness {
        EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records, inspectionRequired: inspection).readiness
    }
    let all = runAll(snapshot)
    check(readiness([]) == .notValidated, "nothing calculated → notValidated")
    check(readiness(all) == .ready, "everything passes → ready")
    check(readiness(all, inspection: true) == .inspectionRequired, "inspection dominates")

    func replacing(_ type: EngineeringTestType, outcome: EngineeringTestOutcome, override: EngineeringOverride? = nil) -> [EngineeringTestRecord] {
        all.map { record in
            guard record.testType == type else { return record }
            var copy = record
            copy.outcome = outcome
            copy.override = override
            return copy
        }
    }
    check(readiness(replacing(.structuralStatic, outcome: .warning)) == .conditional, "a required WARNING → conditional")
    check(readiness(replacing(.structuralStatic, outcome: .fail)) == .notReady, "a required FAIL → notReady")
    check(readiness(replacing(.structuralStatic, outcome: .fail,
                              override: EngineeringOverride(reason: "probe", acceptedAt: clock))) == .conditional,
          "an overridden FAIL → conditional")
    check(readiness(replacing(.structuralStatic, outcome: .error)) == .conditional,
          "a solver ERROR is not an engineering failure → conditional")
    check(readiness(replacing(.systemEndurance, outcome: .fail)) == .ready,
          "a FAIL outside the appendix-B minimum set does not block readiness")
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: all, running: [.aerodynamics])
    check(state.evaluation(.aerodynamics)?.status == .running && state.readiness == .conditional,
          "a running required test → conditional")
    check(!EngineeringValidationEngine.evaluate(snapshot: WorkbenchEngineeringSnapshot.make(from: .defaultQuad()), records: [])
            .evaluations.contains { $0.type == .mechanism },
          "mechanism tests do not apply to a multicopter")
}

// MARK: - 6. Records on disk

section("6. Records on disk")
do {
    let snapshot = WorkbenchEngineeringSnapshot.make(from: .defaultVTOL())
    let records = runAll(snapshot)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(records)
    let back = try! JSONDecoder().decode([EngineeringTestRecord].self, from: data)
    check(back == records, "records survive a JSON round trip unchanged")
    check(outdated(snapshot, back).isEmpty, "decoded records are still current")

    var future = records[0]
    future.schemaVersion = EngineeringTestRecord.currentSchemaVersion + 1
    future.createdAt = tick()
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records + [future])
    check(state.evaluation(future.testType)?.status == .outdated
          && state.evaluation(future.testType)?.reasons.first == .schemaIncompatible(
            recorded: future.schemaVersion, supported: EngineeringTestRecord.currentSchemaVersion),
          "a record from a newer schema is reported incompatible, not trusted")

    var json = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(records[1])) as! [String: Any]
    var inputs = json["inputs"] as! [String: Any]
    inputs["someFutureCategory"] = ["item": "abc"]
    json["inputs"] = inputs
    let tolerant = try? JSONDecoder().decode(EngineeringTestRecord.self,
                                             from: JSONSerialization.data(withJSONObject: json))
    check(tolerant != nil, "an unknown input category from a newer build still decodes")

    var otherVehicle = records[0]
    otherVehicle.vehicleID = "someone-else"
    otherVehicle.outcome = .fail
    otherVehicle.createdAt = tick()
    check(EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records + [otherVehicle])
            .evaluation(otherVehicle.testType)?.status == .pass,
          "another vehicle's record is ignored")
}

// MARK: - 7. Aerodynamic tables reach the flight model

section("7. A per-airframe coefficient table is actually flown")
do {
    // ⚠️ Regression guard: until 2026-09-14 `FixedWingAerodynamics.build` looked tables up with
    // `profileID: nil`, so a table registered for one aircraft — the destination of every CFD
    // result this subsystem will produce — was loaded and never used.
    let seeded = FixedWingFamily.allCases.lazy
        .compactMap { MachCoefficientDatabase.table(profileID: nil, family: $0) }.first!
    let family = FixedWingFamily.allCases.first { MachCoefficientDatabase.table(profileID: nil, family: $0) == nil }!
    let marked = AeroCoefficientTable(
        alphaBreakpointsRad: seeded.alphaBreakpointsRad, machBreakpoints: seeded.machBreakpoints,
        liftCoefficient: seeded.liftCoefficient, dragCoefficient: seeded.dragCoefficient,
        pitchingMoment: seeded.pitchingMoment, provenance: "engineering-validation-probe")
    check(MachCoefficientDatabase.register(profileID: "probe-airframe", table: marked), "table registers")
    func aero(_ id: String?) -> FixedWingAerodynamics {
        FixedWingAerodynamics.build(
            family: family, massKg: 12, wingSpanM: 3, fuselageLengthM: 1.8, heightM: 0.4,
            turnAuthority: 0.7, minSustainableSpeedMps: 14, profileID: id)
    }
    check(aero("probe-airframe").coefficientTable?.provenance == "engineering-validation-probe",
          "the airframe's own table is used when its id is passed")
    check(aero(nil).coefficientTable == nil && aero("some-other-airframe").coefficientTable == nil,
          "other airframes of the family keep the closed-form model")
}

// MARK: - 8. Structural solver results enter as records

section("8. A cadnext_structural result becomes a TestRecord")
do {
    // The same file the C++ test matches key-for-key against what the solver writes.
    let fixtureURL = URL(fileURLWithPath: "CADNext/fea/schema/structural-result.example.json")
    guard let fixture = try? Data(contentsOf: fixtureURL) else {
        check(false, "structural result example is readable", fixtureURL.path)
        exit(1)
    }
    let decoded = try? EngineeringSolverResult.decode(fixture, expecting: .structuralStatic)
    check(decoded != nil, "the solver's example result decodes")
    if let result = decoded {
        check(result.metrics["maxVonMisesPa"]?.unit == "Pa" && result.metrics["maxVonMisesPa"]?.numericalUncertainty != nil,
              "stress metric keeps its unit and its mesh uncertainty")
        check(result.metrics["maxDisplacementM"]?.numericalUncertainty == nil,
              "a metric without an uncertainty estimate stays without one (never zero)")

        let snapshot = WorkbenchEngineeringSnapshot.make(from: wing)
        var records = runAll(snapshot).filter { $0.testType != .structuralStatic }
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
        let record = EngineeringValidationEngine.makeRecord(from: result, snapshot: snapshot, state: state, createdAt: tick())
        records.append(record)
        let evaluation = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records).evaluation(.structuralStatic)
        check(evaluation?.status == .pass, "stamped solver record is current and PASS")
        check(record.reportRef == result.fieldRef && record.solverVersion.contains("netgen"),
              "record carries the field reference and the mesher in its solver version")
        check(record.upstream.keys.contains(EngineeringTestType.massProperties.rawValue),
              "the engine, not the solver, stamped the upstream results")

        // A different load case is a different calculation.
        var json = try! JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        settings["factorOfSafety"] = 2.0
        json["settings"] = settings
        let other = try! EngineeringSolverResult.decode(JSONSerialization.data(withJSONObject: json), expecting: .structuralStatic)
        let otherRecord = EngineeringValidationEngine.makeRecord(from: other, snapshot: snapshot, state: state, createdAt: tick())
        check(otherRecord.settingsFingerprint != record.settingsFingerprint, "changed solver settings change the settings fingerprint")

        json["outcome"] = "error"
        json["metrics"] = [String: Any]()
        json["failureReasons"] = ["нет грани face-99 (сила)"]
        let failed = try! EngineeringSolverResult.decode(JSONSerialization.data(withJSONObject: json), expecting: .structuralStatic)
        let errorRecord = EngineeringValidationEngine.makeRecord(from: failed, snapshot: snapshot, state: state, createdAt: tick())
        let withError = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records + [errorRecord])
        check(withError.evaluation(.structuralStatic)?.status == .error && withError.readiness == .conditional,
              "a solver ERROR is recorded as ERROR and leaves readiness conditional, not failed")

        json["schema"] = "cadnext-structural-result/99"
        check((try? EngineeringSolverResult.decode(JSONSerialization.data(withJSONObject: json), expecting: .structuralStatic)) == nil,
              "an unknown result schema is refused")
        check((try? EngineeringSolverResult.decode(fixture, expecting: .modalVibration)) == nil,
              "a result for another test is refused")
    }
}

// MARK: - 9. Modal results enter as records

section("9. A cadnext_structural modal result becomes a TestRecord")
do {
    let fixtureURL = URL(fileURLWithPath: "CADNext/fea/schema/modal-result.example.json")
    guard let fixture = try? Data(contentsOf: fixtureURL) else {
        check(false, "modal result example is readable", fixtureURL.path)
        exit(1)
    }
    let decoded = try? EngineeringSolverResult.decode(fixture, expecting: .modalVibration)
    check(decoded != nil, "the solver's example modal result decodes")
    if let result = decoded {
        check(result.metrics["firstFrequencyHz"]?.unit == "Hz" && result.metrics["firstFrequencyHz"]?.numericalUncertainty != nil,
              "first frequency keeps its unit and its mesh uncertainty")
        check(result.outcome == .warning && result.warnings.contains { $0.contains("резонанс") },
              "the example's resonance overlap arrives as WARNING with its reason")

        let snapshot = WorkbenchEngineeringSnapshot.make(from: wing)
        var records = runAll(snapshot).filter { $0.testType != .modalVibration }
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records)
        let record = EngineeringValidationEngine.makeRecord(from: result, snapshot: snapshot, state: state, createdAt: tick())
        records.append(record)
        let evaluation = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: records).evaluation(.modalVibration)
        check(evaluation?.status == .warning, "stamped modal record is current and WARNING")
        check(record.upstream.keys.contains(EngineeringTestType.propulsionBench.rawValue),
              "the engine stamped the propulsion bench the excitation came from")

        // Rotor speeds are solver settings: another RPM range is another calculation.
        var json = try! JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        var settings = json["settings"] as! [String: Any]
        var modal = settings["modal"] as! [String: Any]
        modal["separationMargin"] = 0.1
        settings["modal"] = modal
        json["settings"] = settings
        let other = try! EngineeringSolverResult.decode(JSONSerialization.data(withJSONObject: json), expecting: .modalVibration)
        let otherRecord = EngineeringValidationEngine.makeRecord(from: other, snapshot: snapshot, state: state, createdAt: tick())
        check(otherRecord.settingsFingerprint != record.settingsFingerprint, "a changed separation margin changes the settings fingerprint")

        json["schema"] = "cadnext-structural-result/1"
        check((try? EngineeringSolverResult.decode(JSONSerialization.data(withJSONObject: json), expecting: .modalVibration)) == nil,
              "a modal result under the static schema is refused")
        check((try? EngineeringSolverResult.decode(fixture, expecting: .structuralStatic)) == nil,
              "a modal result is not accepted as a static strength result")
    }
}

// MARK: - 10. Built-in Workbench checks

section("10. Built-in Workbench checks are fallback records")
do {
    let snapshot = WorkbenchEngineeringSnapshot.make(from: wing)
    let builtIn = WorkbenchBuiltInChecks.records(for: wing, snapshot: snapshot)
    check(Set(builtIn.map(\.testType)) == [.geometryAssembly, .massProperties, .propulsionBench],
          "the wing gets geometry, mass and propulsion records", builtIn.map(\.testType.rawValue).joined(separator: ", "))
    check(builtIn.allSatisfy { $0.source == .fallback }, "all of them are marked fallback")
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)
    check(builtIn.allSatisfy { state.evaluation($0.testType)?.status.isCurrent == true },
          "built-in records are current for the build they were made from")
    check(state.readiness == .notValidated, "fallback estimates alone leave the build not validated",
          state.readiness.rawValue)

    // Fallback PASSes never make «Допущен»: every computed required test passing is not enough
    // while one required test rests on an estimate.
    let computed = runAll(snapshot).filter { $0.testType != .propulsionBench }
    var allRequired = computed + builtIn.filter { $0.testType == .propulsionBench }
    allRequired.sort { $0.createdAt < $1.createdAt }
    let mixed = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: allRequired)
    check(mixed.readiness == .conditional, "computed PASSes + a fallback PASS on a required test → conditional",
          mixed.readiness.rawValue)
    check(EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn + runAll(snapshot)).readiness == .ready,
          "a computed record of the same test outranks the fallback one → ready")

    // A fallback FAIL still blocks: an aeroplane without servos is not ready whatever computed.
    var noServo = wing
    noServo.setSpec(nil, for: .servo)
    let noServoSnapshot = WorkbenchEngineeringSnapshot.make(from: noServo)
    let noServoRecords = WorkbenchBuiltInChecks.records(for: noServo, snapshot: noServoSnapshot)
    check(noServoRecords.first { $0.testType == .geometryAssembly }?.outcome == .fail,
          "missing servos on an aeroplane: geometry and assembly FAIL")
    check(EngineeringValidationEngine.evaluate(snapshot: noServoSnapshot, records: noServoRecords).readiness == .notReady,
          "a fallback FAIL on a required test → notReady")

    // The bench record must not move with the mass: its inputs do not include it.
    let heavier = wingWithPayload
    let heavierSnapshot = WorkbenchEngineeringSnapshot.make(from: heavier)
    let benchBefore = builtIn.first { $0.testType == .propulsionBench }?.outputFingerprint
    let heavierRecords = WorkbenchBuiltInChecks.records(for: heavier, snapshot: heavierSnapshot)
    check(benchBefore != nil && heavierRecords.first { $0.testType == .propulsionBench }?.outputFingerprint == benchBefore,
          "adding a payload leaves the bench output unchanged (no thrust-to-weight in it)")
    check(heavierRecords.first { $0.testType == .massProperties }?.outputFingerprint
            != builtIn.first { $0.testType == .massProperties }?.outputFingerprint,
          "adding a payload changes the mass properties output")

    // A stored strength result that read the old mass becomes outdated through it.
    let strengthState = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)
    let strength = EngineeringValidationEngine.makeRecord(
        .structuralStatic, snapshot: snapshot, state: strengthState, outcome: .pass,
        metrics: ["reserveFactor": EngineeringMetric(2.0, unit: "1")], solverID: "probe", solverVersion: "0", createdAt: tick())
    let afterPayload = EngineeringValidationEngine.evaluate(snapshot: heavierSnapshot, records: heavierRecords + [strength])
    check(afterPayload.evaluation(.structuralStatic)?.status == .outdated
            && afterPayload.evaluation(.structuralStatic)?.reasons.contains(.upstreamResultChanged(.massProperties)) == true,
          "a strength record stamped on the old mass is outdated by the new built-in mass",
          afterPayload.evaluation(.structuralStatic)?.reasons.map(\.displayText).joined(separator: " | ") ?? "")
}

// MARK: - 11. Exact geometry from CADNext

section("11. A .uavframe v2 brings exact solids, and they drive invalidation")
do {
    let fixtureURL = URL(fileURLWithPath: "CADNext/bridge/schema/uavframe-v2.example.json")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame.uavframe")
    try? FileManager.default.removeItem(at: temporary)
    try? FileManager.default.copyItem(at: fixtureURL, to: temporary)
    let imported = try? WorkbenchConstruction.load(from: temporary)
    check(imported?.construction.hasExactGeometry == true && imported?.construction.bodies?.count == 2,
          "the C++ export decodes with both bodies and their exact geometry")
    guard let construction = imported?.construction, let bodies = construction.bodies else { exit(1) }
    check(construction.cadAxes?.forward == "+x" && construction.cadAxes?.up == "+z", "declared CAD axes arrive")
    check(abs(construction.massKg - bodies.reduce(0) { $0 + $1.massKg }) < 1e-12, "frame mass is the sum of the solids' exact masses")

    // A BRep that no longer matches its fingerprint is refused, not calculated on.
    var tampered = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
    var tamperedBodies = tampered["bodies"] as! [[String: Any]]
    var geometry = tamperedBodies[0]["geometry"] as! [String: Any]
    geometry["text"] = (geometry["text"] as! String).replacingOccurrences(of: "0.01", with: "0.02")
    tamperedBodies[0]["geometry"] = geometry
    tampered["bodies"] = tamperedBodies
    let tamperedURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-tampered.uavframe")
    try! JSONSerialization.data(withJSONObject: tampered).write(to: tamperedURL)
    var refusal = ""
    do { _ = try WorkbenchConstruction.load(from: tamperedURL) } catch { refusal = error.localizedDescription }
    check(refusal.contains("отпечатком"), "geometry that does not match its fingerprint is refused", refusal)

    var build = WorkbenchBuild.defaultQuad()
    build.frame = .imported(construction)
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let records = runAll(snapshot)
    check(outdated(snapshot, records).isEmpty, "exact frame: baseline fully current")

    // Material of one solid: everything that reads materials, named by the solid.
    var changedMaterial = construction
    changedMaterial.bodies![1].materialId = "pla_fdm"
    changedMaterial.bodies![1].densityKgPerM3 = 1240
    var materialBuild = build
    materialBuild.frame = .imported(changedMaterial)
    let materialSnapshot = WorkbenchEngineeringSnapshot.make(from: materialBuild)
    let materialOutdated = outdated(materialSnapshot, records)
    check(materialOutdated.isSuperset(of: [.massProperties, .structuralStatic, .modalVibration])
            && !materialOutdated.contains(.propulsionBench) && !materialOutdated.contains(.aerodynamics),
          "a solid's material outdates mass, strength and modes — not the bench or aerodynamics", names(materialOutdated))
    check(reasons(materialSnapshot, records, .structuralStatic).contains("frame.body." + bodies[1].id),
          "the reason names the solid whose material changed", reasons(materialSnapshot, records, .structuralStatic))

    // The same solids re-triangulated for display: nothing a solver reads changed.
    var retriangulated = construction
    var indices = retriangulated.mesh.indices
    for t in stride(from: 0, to: indices.count, by: 3) {
        (indices[t], indices[t + 1], indices[t + 2]) = (indices[t + 1], indices[t + 2], indices[t])
    }
    retriangulated.mesh.indices = indices
    var displayBuild = build
    displayBuild.frame = .imported(retriangulated)
    check(outdated(WorkbenchEngineeringSnapshot.make(from: displayBuild), records).isEmpty,
          "a different display triangulation of the same solids outdates nothing")

    // Changed solid geometry: strength and modes go outdated.
    var reshaped = construction
    reshaped.bodies![0].geometry.text += " "
    reshaped.bodies![0].geometry.sha256 = WorkbenchConstruction.sha256Hex(reshaped.bodies![0].geometry.text)
    var reshapedBuild = build
    reshapedBuild.frame = .imported(reshaped)
    let reshapedOutdated = outdated(WorkbenchEngineeringSnapshot.make(from: reshapedBuild), records)
    check(reshapedOutdated.isSuperset(of: [.structuralStatic, .modalVibration, .geometryAssembly]),
          "a changed solid outdates strength, modes and geometry", names(reshapedOutdated))
}

// MARK: - 12. Strength from the Workbench on exact solids

section("12. A Workbench load case runs cadnext_structural on the exact solid")
do {
    let fixtureURL = URL(fileURLWithPath: "CADNext/bridge/schema/uavframe-v2.example.json")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame-12.uavframe")
    try? FileManager.default.removeItem(at: temporary)
    try? FileManager.default.copyItem(at: fixtureURL, to: temporary)
    guard let construction = try? WorkbenchConstruction.load(from: temporary).construction,
          let bodies = construction.bodies, let axes = construction.cadAxes,
          let arm = bodies.first(where: { $0.id == "arm" }), let frameAxes = WorkbenchCADFrame(axes) else {
        check(false, "fixture frame loads")
        exit(1)
    }

    // Axes: Swift and the Workbench importer agree. With the importer's own convention (nose −Y, Z up)
    // model → CAD is the inverse of (x, y, z) → (x, z, −y).
    let native = WorkbenchCADFrame(.init(forward: "-y", up: "+z", lengthUnit: "m"))!
    let m = SIMD3<Double>(0.3, -1.7, 2.9)
    check(simd_length(native.modelToCAD(m) - SIMD3(m.x, -m.z, m.y)) < 1e-12, "model → CAD inverts the importer's (x, z, −y)")
    check(simd_length(frameAxes.modelToCAD(SIMD3(0, 0, 1)) - SIMD3(1, 0, 0)) < 1e-12
            && simd_length(frameAxes.modelToCAD(SIMD3(0, 1, 0)) - SIMD3(0, 0, 1)) < 1e-12,
          "fixture axes (+x forward, +z up): model forward → CAD +X, model up → CAD +Z")

    // Faces of the arm by where their triangles sit (export frame → model: z = −y).
    func centroidForward(_ face: WorkbenchConstruction.Body.FaceRange) -> Double {
        var sum = 0.0
        var count = 0
        for t in face.firstTriangle..<(face.firstTriangle + face.triangleCount) {
            for k in 0..<3 {
                let index = Int(construction.mesh.indices[3 * t + k])
                sum += -Double(construction.mesh.vertices[3 * index + 1])
                count += 1
            }
        }
        return sum / Double(count)
    }
    let root = arm.faces.min { centroidForward($0) < centroidForward($1) }!
    let tip = arm.faces.max { centroidForward($0) < centroidForward($1) }!

    var build = WorkbenchBuild.defaultQuad()
    build.frame = .imported(construction)
    var loadCase = WorkbenchStructuralCase(name: "тяга и АКБ на луче", bodyID: arm.id)
    loadCase.supports = [.init(faceID: root.id, fixed: [.x, .y, .z])]
    loadCase.forces = [
        .init(faceID: tip.id, source: .motorThrust(motors: 1, direction: CodableVector3D(x: 0, y: 1, z: 0))),
        .init(faceID: tip.id, source: .equipmentWeight(kinds: [.battery], loadFactorG: 3, direction: CodableVector3D(x: 0, y: -1, z: 0))),
    ]
    build.structuralCases = [loadCase]
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let builtIn = WorkbenchBuiltInChecks.records(for: build, snapshot: snapshot)
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)

    check(WorkbenchStructuralJob.prepare(loadCase, build: build, state: state).isFailure(.noElementSize),
          "no element size: refused before anything runs")
    loadCase.coarseElementSizeM = 0.02
    build.structuralCases = [loadCase]
    guard case let .success(job) = WorkbenchStructuralJob.prepare(loadCase, build: build, state: state) else {
        check(false, "complete case prepares")
        exit(1)
    }
    check(job.consumedUpstream == [.propulsionBench, .massProperties], "the job reads exactly the bench and the mass properties")

    let jobObject = try! JSONSerialization.jsonObject(with: job.jobJSON) as! [String: Any]
    let example = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/structural-job.example.json"))) as! [String: Any]
    check(Set(jobObject.keys) == Set(example.keys)
            && Set((jobObject["loadCase"] as! [String: Any]).keys) == Set((example["loadCase"] as! [String: Any]).keys),
          "job keys match the C++ job example")
    let bench = builtIn.first { $0.testType == .propulsionBench }!.metrics["maxThrustN"]!.value
    let units = Double(build.resolvedFrame.motorMounts.count)
    let battery = builtIn.first { $0.testType == .massProperties }!.metrics[WorkbenchBuiltInChecks.componentMassKey(.battery)]!.value
    let expectedZ = bench / units - battery * 3 * WorkbenchStructuralJob.standardGravity
    let forces = (jobObject["loadCase"] as! [String: Any])["forces"] as! [[String: Any]]
    let summedZ = forces.map { ($0["totalForceN"] as! [Double])[2] }.reduce(0, +)
    check(abs(summedZ - expectedZ) < 1e-9 * max(1, abs(expectedZ)),
          "forces: one motor's bench thrust up and 3 g of battery down, along CAD +Z", String(format: "%.4f vs %.4f N", summedZ, expectedZ))

    guard let tool = WorkbenchStructuralToolLocator.locate() else {
        check(false, "cadnext_structural found (set CADNEXT_STRUCTURAL_TOOL to a Netgen-enabled build)")
        exit(1)
    }
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("probe-engineering-runs")
    try? FileManager.default.removeItem(at: storeRoot)
    let store = WorkbenchStructuralRunStore(root: storeRoot)
    let semaphore = DispatchSemaphore(value: 0)
    final class Outcome: @unchecked Sendable { var value: Result<WorkbenchStructuralRun, WorkbenchStructuralError>? }
    let outcome = Outcome()
    let caseToRun = loadCase
    let buildToRun = build
    Task.detached {
        outcome.value = await WorkbenchStructuralRunner.run(caseToRun, build: buildToRun, snapshot: snapshot, state: state, store: store, tool: tool)
        semaphore.signal()
    }
    semaphore.wait()
    guard case let .success(run) = outcome.value else {
        check(false, "the case runs", String(describing: outcome.value))
        exit(1)
    }
    print("  run: \(run.record.outcome.rawValue), reserve \(run.record.metrics["reserveFactor"].map { String(format: "%.3f", $0.value) } ?? "—"); \(run.record.warnings.joined(separator: " | "))")
    check(run.record.source == .computed && run.record.metrics["maxVonMisesPa"] != nil, "the run is a computed record with its stress")
    check(Set(run.record.upstream.keys) == [EngineeringTestType.propulsionBench.rawValue, EngineeringTestType.massProperties.rawValue],
          "the run is stamped with the upstream it read")
    check(store.runs(vehicleID: snapshot.vehicleID).count == 1, "the run is stored and reads back")

    let freshStatuses = WorkbenchStructuralAggregate.caseStatuses(build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
    check(freshStatuses.count == 1 && freshStatuses[0].isCurrent, "the case just calculated counts as current",
          freshStatuses.first?.staleReasons.joined(separator: " | ") ?? "no status")
    let aggregate = WorkbenchStructuralAggregate.record(build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
    guard aggregate != nil else { exit(1) }
    check(aggregate != nil && aggregate!.warnings.contains { $0.contains("не проверены детали") && $0.contains("Центральная плита") }
            && aggregate!.outcome != .pass,
          "one solid of two calculated: the aircraft's strength names the unchecked plate and is not PASS",
          aggregate.map { "\($0.outcome.rawValue): \($0.warnings.joined(separator: " | "))" } ?? "nil")
    let evaluated = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn + [aggregate!])
    check(evaluated.evaluation(.structuralStatic)?.status.isCurrent == true, "the derived strength record is current for the build")

    // A heavier battery changes the mass properties the case read: the case drops out, with the reason.
    var heavier = build
    var pack = heavier.spec(for: .battery)!
    pack.id = "probe-heavy-battery"
    pack.massKg += 0.2
    heavier.installImportedComponent(pack)
    let heavierSnapshot = WorkbenchEngineeringSnapshot.make(from: heavier)
    let heavierBuiltIn = WorkbenchBuiltInChecks.records(for: heavier, snapshot: heavierSnapshot)
    let statuses = WorkbenchStructuralAggregate.caseStatuses(build: heavier, snapshot: heavierSnapshot, upstreamRecords: heavierBuiltIn, runs: store.runs(vehicleID: heavierSnapshot.vehicleID))
    check(statuses.count == 1 && !statuses[0].isCurrent && statuses[0].staleReasons.contains { $0.contains("Масса") },
          "a heavier battery outdates the case that carried its weight", statuses.first?.staleReasons.joined(separator: " | ") ?? "")
    check(WorkbenchStructuralAggregate.record(build: heavier, snapshot: heavierSnapshot, upstreamRecords: heavierBuiltIn,
                                              runs: store.runs(vehicleID: heavierSnapshot.vehicleID)) == nil,
          "with no current case the aircraft has no strength result (not a stale one shown as current)")
}

// MARK: - 13. Modes from the Workbench, with equipment mass and rotor bands

section("13. A Workbench modal case: equipment mass from the mass properties, rotor bands from the bench")
do {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame-13.uavframe")
    try? FileManager.default.removeItem(at: temporary)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: "CADNext/bridge/schema/uavframe-v2.example.json"), to: temporary)
    guard let construction = try? WorkbenchConstruction.load(from: temporary).construction,
          let arm = construction.bodies?.first(where: { $0.id == "arm" }),
          let tool = WorkbenchStructuralToolLocator.locate() else {
        check(false, "fixture frame and cadnext_structural available")
        exit(1)
    }
    func forwardOf(_ face: WorkbenchConstruction.Body.FaceRange) -> Double {
        var sum = 0.0
        for t in face.firstTriangle..<(face.firstTriangle + face.triangleCount) {
            for k in 0..<3 { sum -= Double(construction.mesh.vertices[3 * Int(construction.mesh.indices[3 * t + k]) + 1]) }
        }
        return sum / Double(3 * face.triangleCount)
    }
    let root = arm.faces.min { forwardOf($0) < forwardOf($1) }!
    let tip = arm.faces.max { forwardOf($0) < forwardOf($1) }!

    var build = WorkbenchBuild.defaultQuad()
    build.frame = .imported(construction)
    var settings = WorkbenchStructuralCase.ModalSettings()
    settings.modeCount = 2
    settings.rotorMinimumRPM = 3000
    var bare = WorkbenchStructuralCase(name: "луч без мотора", bodyID: arm.id, analysis: .modal(settings))
    bare.supports = [.init(faceID: root.id, fixed: [.x, .y, .z])]
    bare.coarseElementSizeM = 0.02
    settings.equipment = [.init(faceID: tip.id, kind: .motor, count: 1)]
    var loaded = WorkbenchStructuralCase(name: "луч с мотором", bodyID: arm.id, analysis: .modal(settings))
    loaded.supports = bare.supports
    loaded.coarseElementSizeM = 0.02
    build.structuralCases = [bare, loaded]

    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let builtIn = WorkbenchBuiltInChecks.records(for: build, snapshot: snapshot)
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)
    guard case let .success(job) = WorkbenchStructuralJob.prepare(loaded, build: build, state: state) else {
        check(false, "modal case prepares", String(describing: WorkbenchStructuralJob.prepare(loaded, build: build, state: state)))
        exit(1)
    }
    check(job.testType == .modalVibration && job.consumedUpstream == [.propulsionBench, .massProperties],
          "the modal job reads the bench (bands) and the mass properties (motor mass)")
    let jobObject = try! JSONSerialization.jsonObject(with: job.jobJSON) as! [String: Any]
    let example = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/modal-job.example.json"))) as! [String: Any]
    check(Set(jobObject.keys) == Set(example.keys)
            && Set((jobObject["modal"] as! [String: Any]).keys) == Set((example["modal"] as! [String: Any]).keys),
          "modal job keys match the C++ modal job example")
    let bench = builtIn.first { $0.testType == .propulsionBench }!
    let motorTotal = builtIn.first { $0.testType == .massProperties }!.metrics[WorkbenchBuiltInChecks.componentMassKey(.motor)]!.value
    let modal = jobObject["modal"] as! [String: Any]
    let rotor = (modal["rotors"] as! [[String: Any]])[0]
    let attached = (modal["attachedMasses"] as! [[String: Any]])[0]
    check(abs((rotor["maximumRpm"] as! Double) - bench.metrics["maxRPM"]!.value) < 1e-9
            && (rotor["bladeCount"] as! Int) == Int(bench.metrics["bladeCount"]!.value),
          "rotor band: maximum speed and blade count from the bench, minimum as entered")
    check(abs((attached["massKg"] as! Double) - motorTotal / Double(build.resolvedFrame.motorMounts.count)) < 1e-12,
          "one motor's mass on the tip: the build's motor mass over its motor count")

    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("probe-modal-runs")
    try? FileManager.default.removeItem(at: storeRoot)
    let store = WorkbenchStructuralRunStore(root: storeRoot)
    final class Box: @unchecked Sendable { var runs: [WorkbenchStructuralRun] = []; var errors: [String] = [] }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    let casesToRun = [bare, loaded]
    let buildToRun = build
    Task.detached {
        for loadCase in casesToRun {
            switch await WorkbenchStructuralRunner.run(loadCase, build: buildToRun, snapshot: snapshot, state: state, store: store, tool: tool) {
            case let .success(run): box.runs.append(run)
            case let .failure(error): box.errors.append(error.description)
            }
        }
        semaphore.signal()
    }
    semaphore.wait()
    check(box.runs.count == 2, "both modal cases run", box.errors.joined(separator: " | "))
    guard box.runs.count == 2, let fBare = box.runs[0].record.metrics["firstFrequencyHz"]?.value,
          let fLoaded = box.runs[1].record.metrics["firstFrequencyHz"]?.value else { exit(1) }
    print(String(format: "  arm: f1 %.2f Hz bare, %.2f Hz with a motor; %@", fBare, fLoaded, box.runs[1].record.warnings.joined(separator: " | ")))

    // Euler–Bernoulli cantilever with a tip mass: first root of
    // 1 + cos λ cosh λ + (M/m_b) λ (cos λ sinh λ − sin λ cosh λ) = 0.
    let ratioMass = (attached["massKg"] as! Double) / arm.massKg
    func characteristic(_ l: Double) -> Double {
        1 + cos(l) * cosh(l) + ratioMass * l * (cos(l) * sinh(l) - sin(l) * cosh(l))
    }
    var lo = 0.1, hi = 1.875104
    for _ in 0..<200 {
        let mid = (lo + hi) / 2
        if (characteristic(lo) > 0) == (characteristic(mid) > 0) { lo = mid } else { hi = mid }
    }
    let lambda = (lo + hi) / 2
    let theory = lambda * lambda / (1.875104 * 1.875104)
    check(abs(fLoaded / fBare - theory) <= 0.01 * theory,
          "the motor's mass lowers f1 as beam theory with a tip mass predicts (ratio within 1 %)",
          String(format: "%.4f vs %.4f", fLoaded / fBare, theory))

    // A solver that silently ignored the masses (built before version 2) must not pass as one that used them.
    var withoutMasses = try! JSONSerialization.jsonObject(with: Data(contentsOf: store.root.appendingPathComponent(box.runs[1].directory).appendingPathComponent("result.json"))) as! [String: Any]
    var echoedSettings = withoutMasses["settings"] as! [String: Any]
    var echoedModal = echoedSettings["modal"] as! [String: Any]
    echoedModal.removeValue(forKey: "attachedMasses")
    echoedSettings["modal"] = echoedModal
    withoutMasses["settings"] = echoedSettings
    check(WorkbenchStructuralRunner.unhonouredJobSettings(job: job.jobJSON, result: try! JSONSerialization.data(withJSONObject: withoutMasses))?.contains("устарел") == true,
          "a result that does not echo the attached masses is refused as from an outdated solver")
    check(WorkbenchStructuralRunner.unhonouredJobSettings(job: job.jobJSON, result: try! Data(contentsOf: store.root.appendingPathComponent(box.runs[1].directory).appendingPathComponent("result.json"))) == nil,
          "the current solver's result echoes them")

    let modalRecord = WorkbenchStructuralAggregate.record(.modalVibration, build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
    let evaluated = modalRecord.map { EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn + [$0]) }
    check(modalRecord != nil && evaluated?.evaluation(.modalVibration)?.status.isCurrent == true
            && modalRecord!.warnings.contains { $0.contains("не проверены детали") && $0.contains("Центральная плита") },
          "the aircraft's modal record is current and names the unchecked plate",
          modalRecord.map { $0.warnings.joined(separator: " | ") } ?? "nil")
    check(WorkbenchStructuralAggregate.record(.structuralStatic, build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID)) == nil,
          "modal runs do not become a strength result")

    // A heavier motor outdates the case that carried it, not the bare one.
    var heavier = build
    var motor = heavier.spec(for: .motor)!
    motor.id = "probe-heavy-motor"
    motor.massKg += 0.02
    heavier.installImportedComponent(motor)
    let heavierSnapshot = WorkbenchEngineeringSnapshot.make(from: heavier)
    let statuses = WorkbenchStructuralAggregate.caseStatuses(
        build: heavier, snapshot: heavierSnapshot,
        upstreamRecords: WorkbenchBuiltInChecks.records(for: heavier, snapshot: heavierSnapshot),
        runs: store.runs(vehicleID: heavierSnapshot.vehicleID), testType: .modalVibration)
    let bareStatus = statuses.first { $0.loadCase.id == bare.id }
    let loadedStatus = statuses.first { $0.loadCase.id == loaded.id }
    check(loadedStatus?.isCurrent == false && loadedStatus!.staleReasons.contains { $0.contains("Масса") },
          "a heavier motor outdates the case carrying its mass", loadedStatus?.staleReasons.joined(separator: " | ") ?? "")
    print("  bare case after the motor change: \(bareStatus?.staleReasons.joined(separator: " | ") ?? "current")")
}

// MARK: - Cost

section("Cost (informational, not a gate)")
do {
    let build = WorkbenchBuild.defaultVTOL()
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let records = runAll(snapshot)
    let iterations = 200
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        _ = EngineeringValidationEngine.evaluate(
            snapshot: WorkbenchEngineeringSnapshot.make(from: build), records: records)
    }
    let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1e6
    print(String(format: "  snapshot + evaluate: %.3f ms per call", perCall))
}

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
