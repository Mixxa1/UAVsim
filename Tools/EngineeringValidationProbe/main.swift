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
// mechanicalShock joins the mass edge: a shock case reads the mass of the equipment a face carries,
// so a record that carried equipment depends on that result (a case without equipment stamps nothing
// and stays current — the edge is optional, `requiredFor: []`).
check(EngineeringTestCatalog.downstream(of: .massProperties)
      == [.structuralStatic, .modalVibration, .mechanicalShock, .flutter, .birdStrike, .controlAuthority, .systemEndurance],
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

// The last four follow from their declarations the same way: EMC reads where the equipment sits; the
// bird and flutter carry the optional mass edge (a case with equipment stamps it); icing reads only the
// outer shape and the material, so it goes stale with an external payload or a material change and
// with nothing internal. Icing and flutter apply to lifting surfaces, so the quad never lists them.
//
// The three environment tests (climate, fire, lightning) read where the equipment sits: the layout
// decides what stands next to what, what the flame reaches and where the current passes. So every
// scenario that moves or swaps a component outdates them too. Their own typed-in numbers (a
// component's power and limits) are part of the case and outdate it through the settings fingerprint.
section("3. Spec §10 change table — fixed wing (clean-airframe CFD)")
let wing = WorkbenchBuild.defaultFixedWing()

// Spec: Mass & CG, structural (if load changed), endurance.
// Also outdated here, deliberately:
//   geometryAssembly — clearances are a function of where the pack sits;
//   modalVibration   — the mass matrix changed;
//   controlAuthority — the same moment now turns a different inertia about a different CG.
scenario("battery moved inside the bay", base: wing,
         expected: [.geometryAssembly, .massProperties, .structuralStatic, .modalVibration,
                    .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .flutter, .controlAuthority, .systemEndurance]) { build in
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
                    .modalVibration, .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .flutter, .thermalLimits, .controlAuthority, .systemEndurance]) { build in
    let current = build.propSpecID
    build.setSpec(library(.propeller, otherThan: current).id, for: .propeller)
}

// Spec: mechanism, control authority, power budget.
// Also outdated: mass/geometry (servo mass and envelope) and what reads mass.
scenario("servo changed", base: wing,
         expected: [.geometryAssembly, .massProperties, .mechanism, .structuralStatic,
                    .modalVibration, .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .flutter, .controlAuthority, .systemEndurance]) { build in
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
                    .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .flutter, .controlAuthority, .systemEndurance]) { build in
    build.componentPlacements[WorkbenchComponentKind.payload.rawValue] = WorkbenchComponentPlacement(
        surface: .internalBay, offset: CodableVector3D(x: 0, y: 0, z: 0.03))
}
var wingWithPodPayload = wingWithPayload
wingWithPodPayload.componentPlacements[WorkbenchComponentKind.payload.rawValue] =
    WorkbenchComponentPlacement(surface: .bottom)
scenario("external payload moved", base: wingWithPodPayload,
         expected: [.geometryAssembly, .massProperties, .structuralStatic, .modalVibration,
                    .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .flutter, .icing, .controlAuthority, .systemEndurance, .aerodynamics, .mechanism]) { build in
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
    // A material change reaches the thermal tests too: they read the material's own properties.
    let expected: Set<EngineeringTestType> = [.massProperties, .structuralStatic, .modalVibration,
                                              .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .flutter, .icing, .controlAuthority, .systemEndurance]
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
                    .mechanicalShock, .climatic, .fireResistance, .lightningDirect, .radiatedSusceptibility, .birdStrike, .controlAuthority, .systemEndurance, .aerodynamics]) { build in
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

// MARK: - CFD tables and runtime
section("14. CFD: interpolation, provenance, axes, portable history and physics")
do {
    var build = WorkbenchBuild.defaultFixedWing()
    let alphas = [-10.0, 0, 10, 20], betas = [-10.0, 0, 10]
    let table = EngineeringAeroTable(schema: "uavsim-aerodynamics/1", frame: "flight-body-rhu",
        reference: .init(areaM2: 2, spanM: 4, chordM: 0.5, momentCenterModelM: [0, 0, 0]),
        speedMps: 20, densityKgM3: 1.225, viscosityPaS: 1.7894e-5, model: "imported", alphaDeg: alphas, betaDeg: betas,
        points: alphas.flatMap { a in betas.map { b in .init(alphaDeg: a, betaDeg: b, cl: 0.2 + 0.1*a + 0.02*b,
            cd: 0.04 + 0.001*a*a, cm: -0.01*a, cy: -0.02*b, cRoll: -0.003*b, cYaw: 0.005*b) } })
    check(table.problem == nil && table.usableForFlight, "a complete finite alpha/beta map is usable")
    check(table.possibleStallBracketDeg == nil, "a monotonically increasing polar makes no stall claim")
    var stalled = table
    for i in stalled.points.indices where stalled.points[i].alphaDeg == 20 { stalled.points[i].cl = 0.9 }
    check(stalled.possibleStallBracketDeg == 10.0...20.0, "the measured lift peak and decline bracket possible stall")
    let mid = table.sample(alphaRad: 5 * .pi / 180, betaRad: 5 * .pi / 180)
    check(mid != nil && abs(mid!.cl - 0.8) < 1e-10 && abs(mid!.cd - 0.09) < 1e-10 && abs(mid!.cy + 0.1) < 1e-10,
          "bilinear interpolation uses both axes and retains the polar shape")
    check(table.sample(alphaRad: 30 * .pi / 180, betaRad: 0) == nil, "no extrapolation beyond the alpha envelope")
    check(table.sample(alphaRad: 0, betaRad: 20 * .pi / 180) == nil, "no extrapolation beyond the beta envelope")
    var malformed = table; malformed.points.removeLast()
    check(malformed.problem != nil, "partial Cartesian product is rejected")
    malformed = table; malformed.points.swapAt(0, 1)
    check(malformed.problem != nil, "misordered or duplicate points are rejected")
    malformed = table; malformed.points[0].cl = .nan
    check(malformed.problem != nil, "nonfinite coefficients are rejected")
    malformed = table; malformed.points[0].cd = -0.01
    check(malformed.problem != nil, "negative drag is rejected")
    malformed = table; malformed.reference.chordM = 0
    check(malformed.problem != nil, "zero reference chord is rejected")
    malformed = table; malformed.frame = "CAD"
    check(malformed.problem != nil, "undeclared axes cannot enter runtime")
    malformed = table; malformed.model = "euler"
    check(!malformed.usableForFlight, "Euler is diagnostic only: no viscous drag or stall claim")
    check(EngineeringAeroTable.solverModels.allSatisfy { model in var solved = table; solved.model = model; return solved.problem == nil },
          "every flow model a run can be launched with is a readable table model")
    var unsteadyTable = table; unsteadyTable.model = "urans_sst"
    check(unsteadyTable.usableForFlight, "a time-averaged URANS polar is viscous and may fly")
    malformed = table; malformed.model = "rans"
    check(malformed.problem != nil, "an undeclared flow model is rejected")
    let imported = try WorkbenchAeroRunner.importTable(JSONEncoder().encode(table), build: build)
    build.aerodynamicRuns = [imported]
    let runtime = EngineeringAeroRuntime.resolve(build: build)
    check(runtime != nil, "a current imported table resolves to the runtime profile")
    let stored = try JSONDecoder().decode(WorkbenchBuild.self, from: JSONEncoder().encode(build))
    check(stored.aerodynamicRuns == build.aerodynamicRuns && EngineeringAeroRuntime.resolve(build: stored) != nil,
          ".uavbuild round-trip carries history and coefficients without solver artifacts")
    var modified = imported.record
    modified.aerodynamicTable!.points[0].cm += 0.01
    check(modified.outputFingerprint != imported.record.outputFingerprint, "a curve change invalidates downstream even when scalar metrics match")
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    var changed = build; changed.frame = .library(id: "different-airframe")
    check(EngineeringAeroRuntime.resolve(build: changed) == nil, "changed external geometry cannot fly an old table")
    changed = build; changed.name = "Renamed only"
    check(EngineeringAeroRuntime.resolve(build: changed) != nil, "a rename preserves the aerodynamic result")
    modified = imported.record; modified.outcome = .error; modified.createdAt = Date().addingTimeInterval(10); modified.aerodynamicTable = nil
    changed = build; changed.aerodynamicRuns.append(.init(record: modified, settings: nil, artifactDirectory: nil))
    check(EngineeringAeroRuntime.resolve(build: changed) == nil, "a newer ERROR prevents silent reuse of an older successful run")
    modified = imported.record; modified.outcome = .fail
    changed = build; changed.aerodynamicRuns = [.init(record: modified, settings: nil, artifactDirectory: nil)]
    check(EngineeringAeroRuntime.resolve(build: changed) == nil, "FAIL cannot enter runtime without an override")
    modified = imported.record; modified.aerodynamicTable!.points.removeLast()
    let evaluation = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: [modified]).evaluation(.aerodynamics)
    check(evaluation?.status == .error, "a corrupted portable table produces ERROR, not a current PASS/WARNING")
    modified.aerodynamicTable = nil
    check(EngineeringValidationEngine.evaluate(snapshot: snapshot, records: [modified]).evaluation(.aerodynamics)?.status == .error,
          "a successful CFD record with a missing portable table cannot remain current")
    let atOrigin = EngineeringAeroRuntime(table: table, centerOfMassModelM: .zero, source: .computed, solverVersion: "test")
    var forwardCG = atOrigin; forwardCG.centerOfMassModelM.z = 0.1
    let centered = atOrigin.sample(alphaRad: 0)!, shifted = forwardCG.sample(alphaRad: 0)!
    check(abs(shifted.cm - centered.cm + 0.04) < 1e-10, "forward CG shifts pitching moment nose-down via r × F")
    var rightCG = atOrigin; rightCG.centerOfMassModelM.x = -0.1
    let rolled = rightCG.sample(alphaRad: 0)!
    check(abs(rolled.cRoll - centered.cRoll + 0.005) < 1e-10, "rightward CG shifts roll about aft with the simulator sign")
    check(atOrigin.sample(alphaRad: 0, mach: 0.5) == nil, "incompressible CFD is not used above Mach 0.3")
    let aero = FixedWingAerodynamics.build(family: .conventionalSurvey, massKg: 3, wingSpanM: 2, fuselageLengthM: 1,
        heightM: 0.2, turnAuthority: 1, minSustainableSpeedMps: 10, engineering: atOrigin)
    check(aero.wingArea == 2 && aero.wingSpan == 4 && aero.meanChord == 0.5, "physics uses table reference dimensions, not inferred wing area")
    let ld = aero.liftDrag(alphaRad: 5 * .pi / 180, betaRad: 5 * .pi / 180)
    check(abs(ld.cl - 0.8) < 1e-5 && abs(ld.cd - 0.09) < 1e-5, "lift/drag physics consumes the 2D table")
    check(abs(aero.pitchMoment(alphaRad: 5 * .pi / 180, elevatorFraction: 0, qHat: 0, betaRad: 5 * .pi / 180) + 0.05) < 1e-5,
          "pitch physics consumes measured Cm instead of the family slope")
    check(abs(aero.sideForce(alphaRad: 0, betaRad: 5 * .pi / 180) + 0.1) < 1e-5, "side force physics consumes beta sweep")
    check(abs(aero.rollMoment(alphaRad: 0, betaRad: 5 * .pi / 180, aileronFraction: 0, pHat: 0) + 0.015) < 1e-5,
          "roll physics consumes beta moment with correct reference span")
    check(abs(aero.yawMoment(alphaRad: 0, betaRad: 5 * .pi / 180, rudderFraction: 0, rHat: 0) - 0.025) < 1e-5,
          "yaw physics consumes beta moment")
    check(!aero.usesEngineeringTable(alphaRad: 1.0), "out-of-envelope physics explicitly falls back")
    var alphaOnly = table; alphaOnly.betaDeg = [0]; alphaOnly.points = table.points.filter { $0.betaDeg == 0 }
    let alphaRuntime = EngineeringAeroRuntime(table: alphaOnly, centerOfMassModelM: .zero, source: .computed, solverVersion: "test")
    let alphaAero = FixedWingAerodynamics.build(family: .conventionalSurvey, massKg: 3, wingSpanM: 2, fuselageLengthM: 1,
        heightM: 0.2, turnAuthority: 1, minSustainableSpeedMps: 10, engineering: alphaRuntime)
    check(abs(alphaAero.sideForce(alphaRad: 0, betaRad: 0.1) - alphaAero.cyBeta * 0.1) < 1e-6,
          "alpha-only sweep preserves the explicitly unmeasured lateral profile")
    var single = alphaOnly; single.alphaDeg = [0]; single.points = alphaOnly.points.filter { $0.alphaDeg == 0 }
    check(!single.usableForFlight, "single point cannot replace the flight polar")
    let profile = UAVBuildProfileSynthesizer.synthesizeProfile(for: build)
    check(profile.engineeringAerodynamics != nil, "synthesized runtime profile carries the validated map")

    if let bytes = try? Data(contentsOf: URL(fileURLWithPath: "CADNext/cfd/schema/aerodynamics-result.example.json")) {
        let result = try EngineeringSolverResult.decode(bytes, expecting: .aerodynamics)
        check(result.outcome == .warning && result.aeroTable?.problem == nil, "actual C++ CFD output decodes through the shared Swift envelope")
        check(!result.solverVersion.contains("unknown"), "actual solver and adapter versions survive transport")
    } else { check(false, "committed real SU2 result fixture exists") }
}


// MARK: - Workbench CFD execution
section("15. Workbench CFD: immutable jobs, real solver, cancellation and durable history")
do {
    let fixture = URL(fileURLWithPath: "CADNext/cfd/schema/sphere.uavframe")
    let construction = try WorkbenchConstruction.load(from: fixture).construction
    var build = WorkbenchBuild.defaultFixedWing()
    build.frame = .imported(construction)
    for kind in WorkbenchBuild.slotKinds { build.setSpec(nil, for: kind) }
    let example = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/cfd/schema/aerodynamics-job.example.json"))) as! [String: Any]
    let settings = try JSONDecoder().decode(WorkbenchAeroSettings.self, from: JSONSerialization.data(withJSONObject: example["settings"]!))
    guard let tool = WorkbenchAeroToolLocator.adapter, let solver = WorkbenchAeroToolLocator.solver else {
        check(false, "cadnext_cfd and SU2_CFD found (build the Netgen-enabled CLI first)"); exit(1)
    }
    // Near-wall sizing must match the solver's own formulas, and the model must match the Reynolds
    // number before a run is ever launched.
    do {
        var air = WorkbenchAeroSettings()
        air.reference = .init(areaM2: 0.48, spanM: 1.2, chordM: 0.4, momentCenterModelM: [0, 0, 0])
        air.speedMps = 20
        air.wallSizeM = 0.4 / 60
        air.farfieldSizeM = 1.2
        let reynolds = WorkbenchWallLayers.reynolds(speedMps: air.speedMps, lengthM: air.reference.chordM,
                                                    densityKgM3: air.densityKgM3, viscosityPaS: air.viscosityPaS)
        check(abs(reynolds - 5.48e5) / 5.48e5 < 0.01, "Reynolds number of a 0.4 m chord at 20 m/s")
        let resolved = WorkbenchWallLayers.plan(wallTreatment: "resolved", speedMps: air.speedMps, lengthM: air.reference.chordM,
                                                densityKgM3: air.densityKgM3, viscosityPaS: air.viscosityPaS)
        let functions = WorkbenchWallLayers.plan(wallTreatment: "functions", speedMps: air.speedMps, lengthM: air.reference.chordM,
                                                 densityKgM3: air.densityKgM3, viscosityPaS: air.viscosityPaS)
        // The same numbers the C++ side produces for this case: 16.5 µm × 27 layers, 0.82 mm × 7.
        check(abs((resolved.first ?? 0) - 1.6461e-5) < 1e-8 && resolved.count == 27,
              "resolved stack matches the solver's sizing", "\(resolved.first ?? 0) × \(resolved.count)")
        check(abs((functions.first ?? 0) - 8.23e-4) < 1e-6 && functions.count == 7,
              "wall-function stack matches the solver's sizing", "\(functions.first ?? 0) × \(functions.count)")
        air.model = "laminar"; air.layerHeightsM = resolved
        check(air.problem?.contains("Ламинарная") == true, "laminar flow at Re = 5.5·10^5 is refused before the run starts")
        air.model = "sst"; air.wallTreatment = "functions"; air.layerHeightsM = functions
        check(air.problem == nil, "SST with wall functions is a valid setup")
        air.model = "laminar"
        check(air.problem != nil, "wall functions are refused for a laminar model")
        air.model = "sst"; air.transition = "lm"
        check(air.problem?.contains("разрешённый") == true, "γ-Reθ transition is refused on a wall-function mesh")
        air.wallTreatment = "resolved"; air.layerHeightsM = resolved
        check(air.problem == nil, "SST with γ-Reθ transition on a resolved wall is a valid setup")
        air.model = "laminar"
        check(air.problem?.contains("SST") == true, "γ-Reθ transition is refused without a turbulence model")
        air.model = "sst"; air.turbulenceIntensity = 0
        check(air.problem != nil, "zero free-stream turbulence is refused")
        // The time-accurate model the panel offers has to pass the gate the panel shows.
        air.turbulenceIntensity = 0.01; air.transition = "none"; air.model = "urans_sst"
        check(air.problem == nil, "URANS SST on a resolved wall is a valid setup", air.problem ?? "")
        air.averagingSteps = air.timeSteps / 2 + 1
        check(air.problem?.contains("URANS") == true, "an averaging window longer than half the run is refused")
        air.averagingSteps = 80; air.timeStepSeconds = 0
        check(air.problem?.contains("URANS") == true, "URANS without a physical time step is refused")
        air.model = "sst"
        check(air.problem == nil, "the time-accurate fields of a steady run do not block it")
        // The per-point limit follows the model between its two defaults and leaves a typed one alone.
        var limited = WorkbenchAeroSettings()
        limited.selectModel("urans_sst")
        check(limited.model == "urans_sst" && limited.timeoutSeconds == 28_800, "selecting URANS raises the default time limit to eight hours")
        limited.selectModel("sst")
        check(limited.model == "sst" && limited.timeoutSeconds == 3600, "returning to a steady model restores the steady hour")
        limited.timeoutSeconds = 7200; limited.selectModel("urans_sst")
        check(limited.timeoutSeconds == 7200, "a time limit the analyst set survives a model change")
        // Settings saved before a field existed still open, with that field at its default.
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkbenchAeroSettings())) as! [String: Any]
        for key in ["wallTreatment", "transition", "turbulenceIntensity", "timeSteps", "innerIterations", "averagingSteps", "timeStepSeconds"] {
            saved.removeValue(forKey: key)
        }
        let old = try? JSONDecoder().decode(WorkbenchAeroSettings.self, from: JSONSerialization.data(withJSONObject: saved))
        check(old?.wallTreatment == "resolved" && old?.transition == "none" && old?.turbulenceIntensity == 0.01,
              "settings saved before the wall and transition options still decode")
        check(old?.timeSteps == 240 && old?.innerIterations == 25 && old?.averagingSteps == 80 && old?.timeStepSeconds == 0.001,
              "settings saved before the URANS fields decode with the adapter's own defaults")
    }
    // The model list Swift validates against is the adapter's own, not a copy that can drift.
    do {
        let process = Process(), pipe = Pipe()
        process.executableURL = tool; process.arguments = ["--capabilities"]; process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let declared = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["models"] as? [String]
        check(declared.map(Set.init) == Set(EngineeringAeroTable.solverModels),
              "Swift accepts exactly the flow models the adapter declares", "\(declared ?? [])")
    }
    let prepared = try WorkbenchAeroRunner.prepare(build: build, settings: settings, solver: solver)
    let job = try JSONSerialization.jsonObject(with: prepared.job) as! [String: Any]
    let geometry = job["geometry"] as! [[String: String]]
    check(geometry.count == 1 && geometry[0]["sha256"] == construction.bodies![0].geometry.sha256,
          "prepared job pins the exact BRep fingerprint")
    check((job["proxies"] as! [[String: Any]]).isEmpty, "empty component slots introduce no hidden equipment")
    var withEquipment = WorkbenchBuild.defaultFixedWing(); withEquipment.frame = .imported(construction)
    let equipmentJob = try WorkbenchAeroRunner.prepare(build: withEquipment, settings: settings, solver: solver)
    let equipmentObject = try JSONSerialization.jsonObject(with: equipmentJob.job) as! [String: Any]
    let external = WorkbenchEngineeringSnapshot.make(from: withEquipment).items(.outerGeometry).keys.filter { $0 != "frame" && $0 != "cadAxes" }
    check((equipmentObject["proxies"] as! [[String: Any]]).count == external.count && !external.isEmpty,
          "every external component is represented by an explicit geometry envelope")
    final class CFDOutcomes: @unchecked Sendable {
        var runs: [WorkbenchAeroRun] = []
        let lock = NSLock()
        var stages: [String] = []
        var cancelSeconds = 0.0
        func progress(_ value: String) { lock.lock(); stages.append(value); lock.unlock() }
    }
    let outcome = CFDOutcomes(), semaphore = DispatchSemaphore(value: 0)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-cfd-" + UUID().uuidString)
    let immutableBuild = build
    Task.detached {
        outcome.runs.append(await WorkbenchAeroRunner.run(build: immutableBuild, settings: settings, tool: tool,
            solver: solver, root: root, progress: { outcome.progress($0) }))
        let start = Date()
        let cancelRun = Task { await WorkbenchAeroRunner.run(build: immutableBuild, settings: settings, tool: tool, solver: solver, root: root) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        cancelRun.cancel()
        outcome.runs.append(await cancelRun.value)
        outcome.cancelSeconds = Date().timeIntervalSince(start)
        let alreadyCancelled = Task { await WorkbenchAeroRunner.run(build: immutableBuild, settings: settings, tool: tool, solver: solver, root: root) }
        alreadyCancelled.cancel()
        outcome.runs.append(await alreadyCancelled.value)
        semaphore.signal()
    }
    semaphore.wait()
    let run = outcome.runs[0]
    check(run.record.outcome == .warning && run.record.aerodynamicTable?.points.count == 1,
          "Workbench runs actual BRep → Netgen → laminar SU2 → verified result", run.record.failureReasons.joined(separator: "; "))
    check(run.record.source == .computed && run.record.upstream.isEmpty, "clean-airframe run records computed provenance without invented dependencies")
    check(outcome.stages.contains { $0.contains("mesh") } && outcome.stages.contains { $0.contains("solve") },
          "native progress reaches the Workbench callback")
    check(FileManager.default.fileExists(atPath: run.record.reportRef ?? ""), "report reference resolves to the real run artifact")
    check(outcome.runs.dropFirst().allSatisfy { $0.record.outcome == .error && $0.record.aerodynamicTable == nil && $0.record.failureReasons.contains("Расчёт отменён.") },
          "cancellation before and during execution leaves ERROR and no runtime table")
    check(outcome.cancelSeconds < 10, "cancellation interrupts native work promptly", String(format: "%.2f s", outcome.cancelSeconds))
    check(Set(outcome.runs.compactMap(\.artifactDirectory)).count == 3, "every attempt owns a new immutable directory")
    for saved in outcome.runs {
        let url = URL(fileURLWithPath: saved.artifactDirectory!).appendingPathComponent("aero-run.json")
        let decoded = try JSONDecoder().decode(WorkbenchAeroRun.self, from: Data(contentsOf: url))
        check(decoded == saved, "completed/cancelled run survives local history reload")
    }
    // The time-accurate path, end to end: the model the panel offers must launch, come back and be
    // read. A sphere at Re = 20 settles to a steady wake, so sixty physical steps reach an accepted
    // mean. The coefficient itself is not a claim: SST has no business at this Reynolds number.
    var unsteady = settings
    unsteady.model = "urans_sst"; unsteady.timeSteps = 60; unsteady.innerIterations = 25
    unsteady.averagingSteps = 20; unsteady.timeStepSeconds = 0.05
    final class UnsteadyOutcome: @unchecked Sendable { var run: WorkbenchAeroRun? }
    let unsteadyOutcome = UnsteadyOutcome(), unsteadyDone = DispatchSemaphore(value: 0)
    let unsteadySettings = unsteady
    Task.detached {
        unsteadyOutcome.run = await WorkbenchAeroRunner.run(build: immutableBuild, settings: unsteadySettings, tool: tool,
                                                            solver: solver, root: root)
        unsteadyDone.signal()
    }
    unsteadyDone.wait()
    let unsteadyRecord = unsteadyOutcome.run?.record
    check(unsteadyRecord?.outcome == .warning && unsteadyRecord?.aerodynamicTable?.model == "urans_sst"
            && unsteadyRecord?.aerodynamicTable?.points.count == 1,
          "Workbench runs URANS SST through the same adapter and reads its time-averaged table",
          unsteadyRecord?.failureReasons.joined(separator: "; ") ?? "no run")
}

// MARK: - 16. One shock event from the Workbench

// The Swift half of the shock test: what the panel collects must arrive at cadnext_structural in the
// units the schema declares, along the axis the user pointed at, and the answer must come back as a
// mechanicalShock record.
//
// Criteria, fixed before the first run:
//   1. Refusals first: no damping, no pulse and an impossible trapezoid are each named before any
//      mesh is built. A shock with a default ζ would be the quietest wrong verdict here.
//   2. Units and axis: the job carries peak × g in m/s² and the duration in seconds, and its
//      direction is the CAD axis the frame declares as "up" — the fixture's is +z.
//   3. The quasi-static limit, end to end: a half-sine fifty first periods long cannot be told from
//      a static load of the same g. The shock run's peak stress must match the static run's maximum
//      von Mises within 5 % — far above the +0.29 % the C++ core measures for this limit on a plate,
//      far below the 9.8× a g ↔ m/s² mix-up would give, which is the mistake this checks for.
//   4. Bookkeeping: a case without equipment reads no upstream, the result files under
//      mechanicalShock, and the aircraft's record carries the peak stress of the governing case.

section("16. A Workbench shock case: the pulse as entered, the response against the static limit")
do {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame-16.uavframe")
    try? FileManager.default.removeItem(at: temporary)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: "CADNext/bridge/schema/uavframe-v2.example.json"), to: temporary)
    guard let construction = try? WorkbenchConstruction.load(from: temporary).construction,
          let arm = construction.bodies?.first(where: { $0.id == "arm" }),
          let axes = construction.cadAxes,
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
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let builtIn = WorkbenchBuiltInChecks.records(for: build, snapshot: snapshot)
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)

    let loadFactorG = 20.0
    var base = WorkbenchStructuralCase(name: "луч, удар вверх", bodyID: arm.id, analysis: .shock(.init()))
    base.supports = [.init(faceID: root.id, fixed: [.x, .y, .z])]
    base.coarseElementSizeM = 0.02

    // --- 1. Refusals, each for its own reason.
    func refusal(_ mutate: (inout WorkbenchStructuralCase.ShockSettings) -> Void) -> String {
        var settings = WorkbenchStructuralCase.ShockSettings()
        mutate(&settings)
        var probeCase = base
        probeCase.analysis = .shock(settings)
        if case let .failure(error) = WorkbenchStructuralJob.prepare(probeCase, build: build, state: state) { return error.description }
        return "приняли без отказа"
    }
    let noModes = refusal { _ in }
    let noDamping = refusal { $0.modeCount = 3 }
    let noPulse = refusal { $0.modeCount = 3; $0.dampingRatio = 0.02 }
    let badTrapezoid = refusal {
        $0.modeCount = 3; $0.dampingRatio = 0.02; $0.peakG = loadFactorG; $0.durationMs = 10
        $0.shape = .trapezoid; $0.riseMs = 7; $0.fallMs = 7
    }
    check(noModes.contains("мод") && noDamping.contains("демпфирование") && noPulse.contains("импульс")
            && badTrapezoid.contains("Трапеция"),
          "no modes, no damping, no pulse and an impossible trapezoid are each refused by name",
          [noModes, noDamping, noPulse, badTrapezoid].joined(separator: " | "))

    // --- The first period decides how long a pulse counts as slow, so it is measured, not assumed.
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("probe-shock-runs")
    try? FileManager.default.removeItem(at: storeRoot)
    let store = WorkbenchStructuralRunStore(root: storeRoot)
    func run(_ loadCase: WorkbenchStructuralCase) -> WorkbenchStructuralRun? {
        final class Box: @unchecked Sendable { var run: WorkbenchStructuralRun?; var error: String = "" }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let buildToRun = build
        Task.detached {
            switch await WorkbenchStructuralRunner.run(loadCase, build: buildToRun, snapshot: snapshot, state: state, store: store, tool: tool) {
            case let .success(value): box.run = value
            case let .failure(error): box.error = error.description
            }
            semaphore.signal()
        }
        semaphore.wait()
        if box.run == nil { print("  не выполнено: \(box.error)") }
        return box.run
    }

    var modalSettings = WorkbenchStructuralCase.ModalSettings()
    modalSettings.modeCount = 3
    var modalCase = WorkbenchStructuralCase(name: "луч, частоты", bodyID: arm.id, analysis: .modal(modalSettings))
    modalCase.supports = base.supports
    modalCase.coarseElementSizeM = base.coarseElementSizeM
    guard let modalRun = run(modalCase), let firstHz = modalRun.record.metrics["firstFrequencyHz"]?.value, firstHz > 0 else {
        check(false, "the arm's first frequency is measured for the pulse length")
        exit(1)
    }

    var settings = WorkbenchStructuralCase.ShockSettings()
    settings.modeCount = 3
    settings.dampingRatio = 0.02
    settings.peakG = loadFactorG
    settings.durationMs = 50 * 1e3 / firstHz   // fifty first periods: as static as a pulse gets
    settings.direction = CodableVector3D(x: 0, y: 1, z: 0)
    settings.probeFaceID = tip.id
    var shockCase = base
    shockCase.analysis = .shock(settings)

    // --- 2. Units and axis, in the job itself.
    guard case let .success(job) = WorkbenchStructuralJob.prepare(shockCase, build: build, state: state) else {
        check(false, "shock case prepares", String(describing: WorkbenchStructuralJob.prepare(shockCase, build: build, state: state)))
        exit(1)
    }
    let jobObject = try! JSONSerialization.jsonObject(with: job.jobJSON) as! [String: Any]
    let shockBlock = jobObject["shock"] as! [String: Any]
    let pulse = shockBlock["pulse"] as! [String: Any]
    let direction = shockBlock["direction"] as! [Double]
    let expected: [Double] = axes.up == "+z" ? [0, 0, 1] : []
    check(jobObject["analysis"] as? String == "shock"
            && abs((pulse["peakMps2"] as! Double) - loadFactorG * 9.80665) < 1e-9
            && abs((pulse["durationS"] as! Double) - settings.durationMs! / 1e3) < 1e-12
            && pulse["shape"] as? String == "halfSine"
            && direction.count == 3 && zip(direction, expected).allSatisfy({ abs($0 - $1) < 1e-12 }),
          "the job carries peak × g in m/s², the duration in seconds and «вверх» as the frame's own up axis",
          "direction \(direction), up \(axes.up)")
    check(job.testType == .mechanicalShock && job.consumedUpstream.isEmpty,
          "a shock case without equipment reads no upstream result")
    let example = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/shock-job.example.json"))) as! [String: Any]
    check(Set(jobObject.keys) == Set(example.keys)
            && Set(shockBlock.keys) == Set((example["shock"] as! [String: Any]).keys),
          "shock job keys match the C++ shock job example",
          "наши \(Set(jobObject.keys).sorted()) | пример \(Set(example.keys).sorted())")

    // --- 3, 4. The run, against the same load applied statically.
    var staticCase = WorkbenchStructuralCase(name: "луч, те же g статикой", bodyID: arm.id)
    staticCase.supports = base.supports
    staticCase.coarseElementSizeM = base.coarseElementSizeM
    staticCase.ownLoadFactorG = CodableVector3D(x: 0, y: loadFactorG, z: 0)
    guard let shockRun = run(shockCase), let staticRun = run(staticCase),
          let peak = shockRun.record.metrics["peakStressPa"]?.value,
          let statically = staticRun.record.metrics["maxVonMisesPa"]?.value, statically > 0 else {
        check(false, "the shock case and the static case both run")
        exit(1)
    }
    print(String(format: "  arm: f1 %.2f Hz → полусинус %.0f мс при %.0f g; пик %.4f МПа против статики %.4f МПа (%+.3f %%)",
                 firstHz, settings.durationMs!, loadFactorG, peak / 1e6, statically / 1e6, 100 * (peak / statically - 1)))
    check(shockRun.record.testType == .mechanicalShock, "the result files under mechanicalShock")
    check(abs((shockRun.record.metrics["peakInputAccelerationMps2"]?.value ?? 0) - loadFactorG * 9.80665) <= 1e-6 * loadFactorG * 9.80665,
          "the solver echoes the input peak as the g the user entered, in m/s²")
    check(abs(peak / statically - 1) <= 0.05,
          "a pulse fifty first periods long gives the static answer, so the units survived the whole path",
          String(format: "%.4f МПа против %.4f МПа", peak / 1e6, statically / 1e6))

    // The aircraft's record is assembled from the cases the blueprint carries, so they go in it —
    // the load cases are not part of the snapshot, which is why this can happen after the runs.
    build.structuralCases = [modalCase, shockCase, staticCase]
    let record = WorkbenchStructuralAggregate.record(
        .mechanicalShock, build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
    let evaluated = record.map { EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn + [$0]) }
    check(record != nil && evaluated?.evaluation(.mechanicalShock)?.status.isCurrent == true
            && record!.metrics["peakStressPa"] != nil && record!.warnings.contains { $0.contains("определяющий вариант") },
          "the aircraft's shock record is current, carries the peak stress and names the governing case",
          record.map { $0.metrics.keys.sorted().joined(separator: ", ") } ?? "nil")
    check(WorkbenchStructuralAggregate.record(.structuralStatic, build: build, snapshot: snapshot, upstreamRecords: builtIn,
                                              runs: store.runs(vehicleID: snapshot.vehicleID))?.metrics["peakStressPa"] == nil,
          "the shock run does not leak into the static strength record")

    let fixture = try! Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/shock-result.example.json"))
    let decoded = try? EngineeringSolverResult.decode(fixture, expecting: .mechanicalShock)
    check(decoded?.schema == "cadnext-shock-result/1" && decoded?.metrics["peakStressPa"] != nil,
          "schema/shock-result.example.json decodes as a mechanicalShock result")
}

// MARK: - 17. Sine and random vibration from the Workbench

// The two remaining vibration kinds. They share the modes' test, so the point here is that each
// arrives at the solver in its own units and that one verdict on vibration can hold all three kinds.
//
// Criteria, fixed before the first run:
//   1. Units: a shaker entered in g arrives as m/s², a schedule in g²/Hz arrives as (m/s²)²/Hz, and
//      an imbalance in g·mm arrives as kg·m. The solver echoes the input, so a mix-up shows up as a
//      factor of 9.8 (or 9.8² = 96) and not as something plausible.
//   2. Refusals: no spectrum, a spectrum that does not rise in frequency, no sweep range, and a force
//      without a face are each named. A single-point amplitude is legal (flat) — two-point PSD is the
//      minimum, because one point is a number, not a spectrum.
//   3. A flat shaker spectrum through the sweep must give a peak stress near the resonance of the
//      part: the reported frequency of the peak must sit within 10 % of the first natural frequency
//      the modal case measured. Ten percent is the half-power width at ζ = 2 % with room to spare,
//      so this catches a sweep that missed the mode, not a solver that is slightly off.
//   4. All three kinds file under one test, and the aircraft's vibration record is governed by a
//      stressed case (a reserve factor) rather than by the modal case that has none.

section("17. Sine and random vibration: units, refusals, resonance and one verdict for three kinds")
do {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame-17.uavframe")
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
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let builtIn = WorkbenchBuiltInChecks.records(for: build, snapshot: snapshot)
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)

    var base = WorkbenchStructuralCase(name: "луч", bodyID: arm.id)
    base.supports = [.init(faceID: root.id, fixed: [.x, .y, .z])]
    base.coarseElementSizeM = 0.02

    // --- 2. Refusals.
    func refusal(_ analysis: WorkbenchStructuralCase.Analysis) -> String {
        var probeCase = base
        probeCase.analysis = analysis
        if case let .failure(error) = WorkbenchStructuralJob.prepare(probeCase, build: build, state: state) { return error.description }
        return "приняли без отказа"
    }
    var sine = WorkbenchStructuralCase.SineSettings()
    sine.modeCount = 6
    sine.dampingRatio = 0.02
    var withRange = sine
    withRange.fromHz = 5
    withRange.toHz = 600
    let noSpectrum = refusal(.sine(withRange))
    var descending = sine
    descending.fromHz = 5
    descending.toHz = 600
    descending.amplitude = [.init(frequencyHz: 100, value: 2), .init(frequencyHz: 50, value: 2)]
    let notRising = refusal(.sine(descending))
    var noRange = sine
    noRange.amplitude = [.init(frequencyHz: 5, value: 2)]
    let missingRange = refusal(.sine(noRange))
    var forceWithoutFace = noRange
    forceWithoutFace.excitation = .force
    forceWithoutFace.fromHz = 5
    forceWithoutFace.toHz = 600
    let noFace = refusal(.sine(forceWithoutFace))
    var onePoint = WorkbenchStructuralCase.RandomSettings()
    onePoint.modeCount = 6
    onePoint.dampingRatio = 0.03
    onePoint.psd = [.init(frequencyHz: 20, value: 0.01)]
    let singlePointPsd = refusal(.random(onePoint))
    check(noSpectrum.contains("спектр") && notRising.contains("спектр") && missingRange.contains("диапазон")
            && noFace.contains("грань") && singlePointPsd.contains("спектр"),
          "no spectrum, a falling spectrum, no sweep range, a force without a face and a one-point PSD are refused",
          [noSpectrum, notRising, missingRange, noFace, singlePointPsd].joined(separator: " | "))

    // --- 1. Units, in the jobs themselves.
    let shakerG = 2.0
    sine.amplitude = [.init(frequencyHz: 5, value: shakerG), .init(frequencyHz: 600, value: shakerG)]
    sine.fromHz = 5
    sine.toHz = 600
    sine.sweepPoints = 240
    sine.probeFaceID = tip.id
    var sineCase = base
    sineCase.id = UUID()
    sineCase.name = "луч на вибростенде"
    sineCase.analysis = .sine(sine)

    let psdG2 = 0.04
    var random = WorkbenchStructuralCase.RandomSettings()
    random.modeCount = 6
    random.dampingRatio = 0.03
    random.psd = [.init(frequencyHz: 20, value: psdG2), .init(frequencyHz: 2000, value: psdG2)]
    random.probeFaceID = tip.id
    var randomCase = base
    randomCase.id = UUID()
    randomCase.name = "луч по спектру"
    randomCase.analysis = .random(random)

    var imbalance = sine
    imbalance.excitation = .imbalance
    imbalance.amplitude = []
    imbalance.imbalanceGmm = 500
    imbalance.faceID = tip.id
    var imbalanceCase = base
    imbalanceCase.id = UUID()
    imbalanceCase.name = "луч с дисбалансом винта"
    imbalanceCase.analysis = .sine(imbalance)

    func jobObject(_ loadCase: WorkbenchStructuralCase) -> [String: Any]? {
        guard case let .success(job) = WorkbenchStructuralJob.prepare(loadCase, build: build, state: state) else { return nil }
        return try? JSONSerialization.jsonObject(with: job.jobJSON) as? [String: Any]
    }
    guard let sineJob = jobObject(sineCase), let randomJob = jobObject(randomCase), let imbalanceJob = jobObject(imbalanceCase) else {
        check(false, "the three vibration jobs prepare",
              String(describing: WorkbenchStructuralJob.prepare(sineCase, build: build, state: state)))
        exit(1)
    }
    let excitation = (sineJob["harmonic"] as! [String: Any])["excitation"] as! [String: Any]
    let amplitude = (excitation["amplitude"] as! [[Double]])
    let psd = ((randomJob["random"] as! [String: Any])["accelerationPsd"] as! [[Double]])
    let imbalanceKgM = ((imbalanceJob["harmonic"] as! [String: Any])["excitation"] as! [String: Any])["imbalanceKgM"] as! Double
    check(sineJob["analysis"] as? String == "harmonic" && randomJob["analysis"] as? String == "random"
            && amplitude.allSatisfy({ abs($0[1] - shakerG * 9.80665) < 1e-9 })
            && psd.allSatisfy({ abs($0[1] - psdG2 * 9.80665 * 9.80665) < 1e-9 })
            && abs(imbalanceKgM - 500 * 1e-6) < 1e-15
            && (excitation["amplitude"] != nil) && (excitation["imbalanceKgM"] == nil),
          "g → m/s², g²/Hz → (m/s²)²/Hz, g·mm → kg·m, and amplitude and imbalance never travel together",
          "амплитуда \(amplitude), PSD \(psd), дисбаланс \(imbalanceKgM)")
    for (name, object) in [("harmonic", sineJob), ("random", randomJob)] {
        let example = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/\(name)-job.example.json"))) as! [String: Any]
        check(Set(object.keys) == Set(example.keys)
                && Set((object[name] as! [String: Any]).keys) == Set((example[name] as! [String: Any]).keys),
              "\(name) job keys match the C++ \(name) job example",
              "наши \(Set((object[name] as! [String: Any]).keys).sorted()) | пример \(Set((example[name] as! [String: Any]).keys).sorted())")
    }

    // --- 3, 4. The runs.
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("probe-vibration-runs")
    try? FileManager.default.removeItem(at: storeRoot)
    let store = WorkbenchStructuralRunStore(root: storeRoot)
    func run(_ loadCase: WorkbenchStructuralCase) -> WorkbenchStructuralRun? {
        final class Box: @unchecked Sendable { var run: WorkbenchStructuralRun?; var error: String = "" }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let buildToRun = build
        Task.detached {
            switch await WorkbenchStructuralRunner.run(loadCase, build: buildToRun, snapshot: snapshot, state: state, store: store, tool: tool) {
            case let .success(value): box.run = value
            case let .failure(error): box.error = error.description
            }
            semaphore.signal()
        }
        semaphore.wait()
        if box.run == nil { print("  не выполнено: \(box.error)") }
        return box.run
    }

    var modalSettings = WorkbenchStructuralCase.ModalSettings()
    modalSettings.modeCount = 6
    var modalCase = base
    modalCase.id = UUID()
    modalCase.name = "луч, частоты"
    modalCase.analysis = .modal(modalSettings)
    guard let modalRun = run(modalCase), let firstHz = modalRun.record.metrics["firstFrequencyHz"]?.value,
          let sineRun = run(sineCase), let randomRun = run(randomCase),
          let peakHz = sineRun.record.metrics["peakStressFrequencyHz"]?.value,
          let sineReserve = sineRun.record.metrics["reserveFactor"]?.value,
          let threeSigma = randomRun.record.metrics["threeSigmaStressPa"]?.value else {
        check(false, "the modal, sine and random cases all run")
        exit(1)
    }
    print(String(format: "  arm: f1 %.2f Гц; пик синуса на %.2f Гц (%+.2f %%), запас %.2f; 3σ спектра %.3f МПа",
                 firstHz, peakHz, 100 * (peakHz / firstHz - 1), sineReserve, threeSigma / 1e6))
    check(abs(peakHz / firstHz - 1) <= 0.10,
          "a flat sweep peaks at the part's own first frequency, so the excitation reached the mode",
          String(format: "%.2f Гц против %.2f Гц", peakHz, firstHz))
    check(sineRun.record.testType == .modalVibration && randomRun.record.testType == .modalVibration
            && modalRun.record.testType == .modalVibration,
          "modes, sine and random all file under one vibration test")
    check(abs((sineRun.record.metrics["peakProbeAccelerationMps2"]?.value ?? 0)) > shakerG * 9.80665,
          "the tip of a resonating cantilever moves harder than the shaker that drives it")

    build.structuralCases = [modalCase, sineCase, randomCase]
    let record = WorkbenchStructuralAggregate.record(
        .modalVibration, build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
    check(record?.metrics["reserveFactor"] != nil && record!.warnings.contains { $0.contains("определяющий вариант") },
          "the aircraft's vibration record is governed by a stressed case, not by the modal one that has no stress",
          record.map { $0.metrics.keys.sorted().joined(separator: ", ") } ?? "nil")
    for schema in ["harmonic", "random"] {
        let fixture = try! Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/\(schema)-result.example.json"))
        check((try? EngineeringSolverResult.decode(fixture, expecting: .modalVibration))?.schema == "cadnext-\(schema)-result/1",
              "schema/\(schema)-result.example.json decodes as a modalVibration result")
    }
}

// MARK: - 18. Climate, fire and lightning from the Workbench

// The three environment tests. Their inputs are read from standards rather than typed as forces, so
// what has to be checked here is that the standard's own numbers survive the trip: °C to kelvin, a
// category to the right envelope, faces to the right role.
//
// Criteria, fixed before the first run:
//   1. Units and roles: temperatures entered in °C arrive in kelvin, the assembly temperature becomes
//      stressFreeK, a hot case sends its hot category and a cold one its cold category, and the
//      lightning components travel in the standard's order however they were toggled.
//   2. Refusals: a climate case without air speed, surface properties, assembly temperature or step;
//      a fire case without flame faces or duration; a lightning case without an attachment face,
//      without components, or with a continuing current outside the standard's 200…800 A; equipment
//      with no temperature limit at all.
//   3. The runs: each files under its own test, and each result decodes from the schema example.
//   4. The physics the solver already proved is not re-proved here — but one end-to-end number is
//      checked per test, because a Swift-side unit slip would show up in it: the climate case's peak
//      temperature must sit inside the category's envelope, the fire case must reach the flame's own
//      temperature, and the lightning case must pass the current it was given.

section("18. Climate, fire and lightning: standards in, kelvin out, one number each")
do {
    // The fixture's plate is 7075-T6 and its arm is CFRP; the material database has a full thermal
    // set only for 6061-T6 (it has no expansion coefficient for 7075 and nothing thermal for CFRP,
    // and says so instead of inventing it). So the probe writes its own variant of the frame with the
    // plate in 6061-T6 — the geometry is untouched, only the material tag changes.
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame-18.uavframe")
    try? FileManager.default.removeItem(at: temporary)
    do {
        let source = try! Data(contentsOf: URL(fileURLWithPath: "CADNext/bridge/schema/uavframe-v2.example.json"))
        var object = try! JSONSerialization.jsonObject(with: source) as! [String: Any]
        var bodies = object["bodies"] as! [[String: Any]]
        for index in bodies.indices where bodies[index]["id"] as? String == "plate" {
            bodies[index]["materialId"] = "al_6061_t6"
        }
        object["bodies"] = bodies
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: temporary)
    }
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
    let armRoot = arm.faces.min { forwardOf($0) < forwardOf($1) }!
    let armTip = arm.faces.max { forwardOf($0) < forwardOf($1) }!
    // These three tests need thermal and electrical material data. The arm is CFRP and the database
    // has none for it — the solver says «нет данных» and refuses, which is checked below — so the
    // cases themselves run on the aluminium plate.
    guard let plate = construction.bodies?.first(where: { $0.id == "plate" }), plate.faces.count >= 2 else {
        check(false, "the fixture has an aluminium plate to heat")
        exit(1)
    }
    let root = plate.faces[0]
    let tip = plate.faces[1]

    var build = WorkbenchBuild.defaultQuad()
    build.frame = .imported(construction)
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let builtIn = WorkbenchBuiltInChecks.records(for: build, snapshot: snapshot)
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)

    var base = WorkbenchStructuralCase(name: "плита", bodyID: plate.id)
    base.supports = [.init(faceID: root.id, fixed: [.x, .y, .z])]
    base.coarseElementSizeM = 0.02

    func refusal(_ analysis: WorkbenchStructuralCase.Analysis) -> String {
        var probeCase = base
        probeCase.id = UUID()
        probeCase.analysis = analysis
        if case let .failure(error) = WorkbenchStructuralJob.prepare(probeCase, build: build, state: state) { return error.description }
        return "приняли без отказа"
    }

    // --- 2. Refusals.
    var climate = WorkbenchStructuralCase.ClimateSettings()
    let noAir = refusal(.climate(climate))
    climate.airSpeedMps = 1.5
    let noSurface = refusal(.climate(climate))
    climate.solarAbsorptance = 0.6
    climate.emissivity = 0.8
    let noAssembly = refusal(.climate(climate))
    climate.assemblyC = 20
    let noStep = refusal(.climate(climate))
    climate.stepS = 900
    var withBadComponent = climate
    withBadComponent.components = [.init(name: "контроллер", faceID: tip.id, powerW: 5, minimumC: nil, maximumC: nil)]
    let noLimits = refusal(.climate(withBadComponent))

    var fire = WorkbenchStructuralCase.FireSettings()
    let noDuration = refusal(.fire(fire))
    // 300 s at 5 s steps: the standard's fire-resistant duration, and sixty steps instead of nine
    // hundred — this probe checks the path, and the C++ tests check the transient itself.
    fire.durationS = 300
    let noFlame = refusal(.fire(fire))
    fire.flameFaceIDs = [tip.id]
    fire.surfaceEmissivity = 0.7
    fire.stepS = 5

    var lightning = WorkbenchStructuralCase.LightningSettings()
    lightning.components = []
    let noComponents = refusal(.lightning(lightning))
    lightning.components = [.a, .b, .c]
    let noAttachment = refusal(.lightning(lightning))
    lightning.attachmentFaceIDs = [tip.id]
    lightning.groundFaceIDs = [root.id]
    lightning.surfaceEmissivity = 0.3
    var wildCurrent = lightning
    wildCurrent.continuingCurrentA = 1500
    let badCurrent = refusal(.lightning(wildCurrent))
    check(noAir.contains("скорость обдува") && noSurface.contains("поверхности") && noAssembly.contains("температура сборки")
            && noStep.contains("шаг") && noLimits.contains("предел") && noDuration.contains("длительность")
            && noFlame.contains("пламен") && noComponents.contains("компонент") && noAttachment.contains("дуги")
            && badCurrent.contains("200…800"),
          "each missing or impossible input of the three tests is refused by name",
          [noAir, noSurface, noAssembly, noStep, noLimits, noDuration, noFlame, noComponents, noAttachment, badCurrent].joined(separator: " | "))

    // --- 1. Units and roles.
    climate.components = [.init(name: "контроллер", faceID: tip.id, powerW: 5, minimumC: -40, maximumC: 85)]
    var climateCase = base
    climateCase.id = UUID()
    climateCase.name = "плита на солнце"
    climateCase.analysis = .climate(climate)

    var fireCase = base
    fireCase.id = UUID()
    fireCase.name = "плита в пламени"
    fireCase.ownLoadFactorG = CodableVector3D(x: 0, y: 1, z: 0)
    fireCase.analysis = .fire(fire)

    // Toggled out of order on purpose: the job must still carry A, B, C.
    var shuffled = lightning
    shuffled.components = [.c, .a, .b]
    var lightningCase = base
    lightningCase.id = UUID()
    lightningCase.name = "законцовка, зона 1A"
    lightningCase.analysis = .lightning(shuffled)

    func jobObject(_ loadCase: WorkbenchStructuralCase) -> [String: Any]? {
        guard case let .success(job) = WorkbenchStructuralJob.prepare(loadCase, build: build, state: state) else { return nil }
        return try? JSONSerialization.jsonObject(with: job.jobJSON) as? [String: Any]
    }
    guard let climateJob = jobObject(climateCase), let fireJob = jobObject(fireCase), let lightningJob = jobObject(lightningCase) else {
        check(false, "the three jobs prepare", String(describing: WorkbenchStructuralJob.prepare(climateCase, build: build, state: state)))
        exit(1)
    }
    let climateBlock = climateJob["climate"] as! [String: Any]
    let component = (climateBlock["components"] as! [[String: Any]])[0]
    let fireBlock = fireJob["fire"] as! [String: Any]
    let lightningBlock = lightningJob["lightning"] as! [String: Any]
    check(abs((climateBlock["stressFreeK"] as! Double) - 293.15) < 1e-9
            && abs((component["maximumK"] as! Double) - 358.15) < 1e-9
            && abs((component["minimumK"] as! Double) - 233.15) < 1e-9
            && climateBlock["environment"] as? String == "hot" && climateBlock["category"] as? String == "A1"
            && (lightningBlock["components"] as! [String]) == ["A", "B", "C"]
            && fireBlock["standard"] as? String == "iso2685" && abs((fireBlock["durationS"] as! Double) - fire.durationS!) < 1e-9,
          "°C → K everywhere, the hot category travels as A1, and the current components in the standard's order",
          "сборка \(climateBlock["stressFreeK"]!), компонент \(component), молния \(lightningBlock["components"]!)")
    check((climateJob["loadCase"] as! [String: Any])["forces"] == nil
            && ((fireJob["loadCase"] as! [String: Any])["bodyAccelerationMps2"] as! [Double])[2] != 0,
          "climate sends no static load at all, while fire carries the load of the fire situation",
          "огонь: \((fireJob["loadCase"] as! [String: Any])["bodyAccelerationMps2"]!)")
    for (name, object) in [("climate", climateJob), ("fire", fireJob), ("lightning", lightningJob)] {
        let example = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/\(name)-job.example.json"))) as! [String: Any]
        check(Set((object[name] as! [String: Any]).keys) == Set((example[name] as! [String: Any]).keys),
              "\(name) job block keys match the C++ \(name) job example",
              "наши \(Set((object[name] as! [String: Any]).keys).sorted()) | пример \(Set((example[name] as! [String: Any]).keys).sorted())")
    }

    // --- 3, 4. The runs.
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("probe-environment-runs")
    try? FileManager.default.removeItem(at: storeRoot)
    let store = WorkbenchStructuralRunStore(root: storeRoot)
    func run(_ loadCase: WorkbenchStructuralCase) -> WorkbenchStructuralRun? {
        final class Box: @unchecked Sendable { var run: WorkbenchStructuralRun?; var error: String = "" }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let buildToRun = build
        Task.detached {
            switch await WorkbenchStructuralRunner.run(loadCase, build: buildToRun, snapshot: snapshot, state: state, store: store, tool: tool) {
            case let .success(value): box.run = value
            case let .failure(error): box.error = error.description
            }
            semaphore.signal()
        }
        semaphore.wait()
        if box.run == nil { print("  не выполнено: \(box.error)") }
        return box.run
    }

    // The same case on the CFRP arm: the solver has no thermal expansion for that material and says
    // so. An ERROR is a failure of the calculation, never an engineering verdict (spec §16), and the
    // reason must reach the record instead of being rounded to a number.
    var cfrpCase = climateCase
    cfrpCase.id = UUID()
    cfrpCase.bodyID = arm.id
    cfrpCase.supports = [.init(faceID: armRoot.id, fixed: [.x, .y, .z])]
    var cfrpClimate = climate
    cfrpClimate.components = [.init(name: "контроллер", faceID: armTip.id, powerW: 5, minimumC: -40, maximumC: 85)]
    cfrpCase.analysis = .climate(cfrpClimate)
    let cfrpRun = run(cfrpCase)
    check(cfrpRun?.record.outcome == .error
            && cfrpRun?.record.failureReasons.contains(where: { $0.contains("нет данных") }) == true,
          "a material without the thermal data it needs gives ERROR with «нет данных», not a verdict",
          cfrpRun?.record.failureReasons.joined(separator: " | ") ?? "нет прогона")

    // Each case runs once, and what it said travels into the failure message: a solver that refuses
    // for a reason is more useful than a check that only says "no".
    let climateRun = run(climateCase)
    let fireRun = run(fireCase)
    let lightningRun = run(lightningCase)
    func report(_ run: WorkbenchStructuralRun?) -> String {
        guard let run else { return "нет прогона" }
        return run.record.outcome.rawValue + ": " + run.record.metrics.keys.sorted().joined(separator: ", ")
            + (run.record.failureReasons.isEmpty ? "" : " | " + run.record.failureReasons.joined(separator: "; "))
    }
    guard let peakK = climateRun?.record.metrics["peakTemperatureK"]?.value,
          let firePeakK = fireRun?.record.metrics["peakTemperatureK"]?.value,
          let arcEnergy = lightningRun?.record.metrics["arcEnergyJ"]?.value,
          let climateRun, let fireRun, let lightningRun else {
        check(false, "the climate, fire and lightning cases all run",
              [report(climateRun), report(fireRun), report(lightningRun)].joined(separator: " || "))
        exit(1)
    }
    print(String(format: "  плита: климат %.1f °C (жара A1 на солнце); пламя %.0f °C; дуга %.4g Дж, прожог %@",
                 peakK - 273.15, firePeakK - 273.15, arcEnergy,
                 lightningRun.record.metrics["burnThroughTimeS"].map { String(format: "%.4g с", $0.value) } ?? "нет"))
    check(climateRun.record.testType == .climatic && fireRun.record.testType == .fireResistance
            && lightningRun.record.testType == .lightningDirect,
          "each result files under its own test")
    // A1 hot-dry in the sun: the standard's air reaches 49 °C and a sunlit surface goes above it, but
    // a part in air cannot pass the ~90 °C an absorbing surface reaches in still air.
    check(peakK - 273.15 > 49 && peakK - 273.15 < 120,
          "the climate peak sits above the category's air temperature and below what a sunlit surface can reach",
          String(format: "%.1f °C", peakK - 273.15))
    // The flame itself, from the result the solver wrote. This file first asked the part to pass
    // 500 °C, and that was a claim about the fixture, not about the path: a big aluminium plate
    // heated on one small face for 300 s reaches 120 °C and conducts the rest away, which is
    // physically right. What belongs here is that the standard's flame arrived — ISO 2685's
    // 1100 °C — and that the part did get hotter than the air it started in.
    let fireResult = (try? JSONSerialization.jsonObject(
        with: Data(contentsOf: store.root.appendingPathComponent(fireRun.directory).appendingPathComponent("result.json")))) as? [String: Any]
    let flame = fireResult?["flame"] as? [String: Any]
    let flameK = flame?["temperatureK"] as? Double ?? 0
    let requiredS = fireRun.record.metrics["requiredDurationS"]?.value ?? 0
    check(abs(flameK - 1373.15) < 1.0 && firePeakK > 293.15 && abs(requiredS - fire.durationS!) < 1e-9,
          "the solver burnt the part with the standard's own flame (1100 °C) for the time it was given",
          String(format: "пламя %.2f K, деталь %.0f °C, требуемая длительность %.0f с", flameK, firePeakK - 273.15, requiredS))
    check(arcEnergy > 0, "the arc delivered energy to the part")

    build.structuralCases = [climateCase, fireCase, lightningCase]
    for test in [EngineeringTestType.climatic, .fireResistance, .lightningDirect] {
        let record = WorkbenchStructuralAggregate.record(
            test, build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
        let evaluated = record.map { EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn + [$0]) }
        check(record != nil && evaluated?.evaluation(test)?.status.isCurrent == true,
              "the aircraft's \(test.rawValue) record is current",
              record.map { $0.metrics.keys.sorted().joined(separator: ", ") } ?? "nil")
    }
    for (schema, test) in [("climate", EngineeringTestType.climatic), ("fire", .fireResistance), ("lightning", .lightningDirect)] {
        let fixture = try! Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/\(schema)-result.example.json"))
        check((try? EngineeringSolverResult.decode(fixture, expecting: test))?.schema == "cadnext-\(schema)-result/1",
              "schema/\(schema)-result.example.json decodes as a \(test.rawValue) result")
    }
}

// MARK: - 19. EMC, icing, flutter and the bird from the Workbench

// The last four. Their solvers are validated on the C++ side; what this section checks is the Swift
// path into them — the units of the standards they read, the axes they are told to use, and the
// refusals. One of them runs end to end (the bird, which needs no material data the fixture lacks),
// because a mechanical analysis with a new block is worth proving through the process.
//
// Criteria, fixed before the first run:
//   1. Units and axes: megahertz become hertz, minutes become seconds, a model axis becomes the CAD
//      letter the solver expects, and the bird's direction becomes a unit vector in CAD axes.
//   2. Refusals: no field and no level; no sweep; the same axis for flow and span; no cloud; no dive
//      speed; no impact face; a bird with no speed.
//   3. Key sets match the C++ job examples block for block.
//   4. Each result schema decodes as its own test.
//   5. The bird runs on the CFRP arm and comes back as a birdStrike record whose patch ratio is the
//      geometry's: the struck face over the bird's own midsection, which is what decides whether the
//      verdict may stay PASS.

section("19. EMC, icing, flutter and the bird: standards in, axes right, one run through")
do {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("probe-frame-19.uavframe")
    try? FileManager.default.removeItem(at: temporary)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: "CADNext/bridge/schema/uavframe-v2.example.json"), to: temporary)
    guard let construction = try? WorkbenchConstruction.load(from: temporary).construction,
          let arm = construction.bodies?.first(where: { $0.id == "arm" }),
          let axes = construction.cadAxes, let frame = WorkbenchCADFrame(axes),
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

    // Icing and flutter apply to lifting surfaces, so those cases live on a fixed-wing blueprint.
    var build = WorkbenchBuild.defaultFixedWing()
    build.frame = .imported(construction)
    let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
    let builtIn = WorkbenchBuiltInChecks.records(for: build, snapshot: snapshot)
    let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: builtIn)

    var base = WorkbenchStructuralCase(name: "луч", bodyID: arm.id)
    base.supports = [.init(faceID: root.id, fixed: [.x, .y, .z])]
    base.coarseElementSizeM = 0.02

    func refusal(_ analysis: WorkbenchStructuralCase.Analysis) -> String {
        var probeCase = base
        probeCase.id = UUID()
        probeCase.analysis = analysis
        if case let .failure(error) = WorkbenchStructuralJob.prepare(probeCase, build: build, state: state) { return error.description }
        return "приняли без отказа"
    }
    func jobObject(_ loadCase: WorkbenchStructuralCase) -> [String: Any]? {
        guard case let .success(job) = WorkbenchStructuralJob.prepare(loadCase, build: build, state: state) else { return nil }
        return try? JSONSerialization.jsonObject(with: job.jobJSON) as? [String: Any]
    }

    // --- 2. Refusals.
    var emc = WorkbenchStructuralCase.EmcSettings()
    let noSurfaceSize = refusal(.emc(emc))
    emc.surfaceElementSizeM = 0.004
    var withoutField = emc
    withoutField.levelID = nil
    let noField = refusal(.emc(withoutField))
    let noSweep = refusal(.emc(emc))
    emc.lowMHz = 500
    emc.highMHz = 2000
    emc.points = 8

    var icing = WorkbenchStructuralCase.IcingSettings()
    icing.flowAxis = .z
    icing.spanAxis = .z
    let sameAxes = refusal(.icing(icing))
    icing.spanAxis = .x
    icing.surfaceElementSizeM = 0.025
    let noCloud = refusal(.icing(icing))
    icing.airspeedMps = 60
    icing.durationMin = 10
    icing.maximumIceThicknessMm = 5
    icing.antiIceTargetC = 2
    icing.antiIceBudgetW = 400

    var flutter = WorkbenchStructuralCase.FlutterSettings()
    flutter.flowAxis = .z
    flutter.spanAxis = .x
    let noDive = refusal(.flutter(flutter))
    flutter.diveSpeedMps = 90

    var bird = WorkbenchStructuralCase.BirdSettings()
    bird.modeCount = 12
    bird.dampingRatio = 0.02
    bird.speedMps = 60
    let noImpactFace = refusal(.bird(bird))
    bird.impactFaceID = tip.id
    var stillBird = bird
    stillBird.speedMps = nil
    let noBirdSpeed = refusal(.bird(stillBird))
    check(noField.contains("поле") && noSurfaceSize.contains("элемента поверхности") && noSweep.contains("развёртка")
            && sameAxes.contains("различаться") && noCloud.contains("облака") && noDive.contains("V_D")
            && noImpactFace.contains("грань удара") && noBirdSpeed.contains("скорость"),
          "no field, no surface size, no sweep, coincident axes, no cloud, no dive speed, no impact face and a still bird are each refused",
          [noField, noSurfaceSize, noSweep, sameAxes, noCloud, noDive, noImpactFace, noBirdSpeed].joined(separator: " | "))

    // --- 1, 3. Units, axes and key sets.
    var emcCase = base
    emcCase.id = UUID()
    emcCase.name = "корпус, RS103"
    emc.equipment = [.init(name: "блок авионики", x: 0.048, y: 0.048, z: 0.048, immunityVm: 20)]
    emcCase.analysis = .emc(emc)

    var icingCase = base
    icingCase.id = UUID()
    icingCase.name = "консоль, взлётное обледенение"
    icingCase.analysis = .icing(icing)

    var flutterCase = base
    flutterCase.id = UUID()
    flutterCase.name = "консоль, флаттер"
    flutterCase.analysis = .flutter(flutter)

    var birdCase = base
    birdCase.id = UUID()
    birdCase.name = "носок, птица 1.81 кг"
    birdCase.analysis = .bird(bird)

    guard let emcJob = jobObject(emcCase), let icingJob = jobObject(icingCase),
          let flutterJob = jobObject(flutterCase), let birdJob = jobObject(birdCase) else {
        check(false, "the four jobs prepare",
              [String(describing: WorkbenchStructuralJob.prepare(emcCase, build: build, state: state)),
               String(describing: WorkbenchStructuralJob.prepare(icingCase, build: build, state: state)),
               String(describing: WorkbenchStructuralJob.prepare(flutterCase, build: build, state: state)),
               String(describing: WorkbenchStructuralJob.prepare(birdCase, build: build, state: state))].joined(separator: " || "))
        exit(1)
    }
    let emcBlock = emcJob["emc"] as! [String: Any]
    let icingBlock = icingJob["icing"] as! [String: Any]
    let flutterBlock = flutterJob["flutter"] as! [String: Any]
    let birdBlock = birdJob["bird"] as! [String: Any]
    let birdDirection = birdBlock["direction"] as! [Double]
    // Model −Z is "back" in the Workbench, which on this frame (forward +x) is CAD −x.
    let expectedDirection = frame.modelToCAD(SIMD3(0, 0, -1))
    check(abs((emcBlock["lowHz"] as! Double) - 500e6) < 1 && abs((emcBlock["highHz"] as! Double) - 2000e6) < 1
            && abs(((icingBlock["flight"] as! [String: Any])["durationS"] as! Double) - 600) < 1e-9
            && icingBlock["flowAxis"] as? String == frame.cadAxisLetter(.z)
            && icingBlock["spanAxis"] as? String == frame.cadAxisLetter(.x)
            && flutterBlock["flowAxis"] as? String == frame.cadAxisLetter(.z)
            && zip(birdDirection, [expectedDirection.x, expectedDirection.y, expectedDirection.z]).allSatisfy({ abs($0 - $1) < 1e-12 }),
          "MHz → Hz, minutes → seconds, model axes → the CAD letters, and the bird's direction in CAD axes",
          "ЭМС \(emcBlock["lowHz"]!)…\(emcBlock["highHz"]!), лёд \(icingBlock["flowAxis"]!)/\(icingBlock["spanAxis"]!), птица \(birdDirection)")
    for (name, object) in [("emc", emcJob), ("icing", icingJob), ("flutter", flutterJob), ("bird", birdJob)] {
        let example = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/\(name)-job.example.json"))) as! [String: Any]
        check(Set((object[name] as! [String: Any]).keys) == Set((example[name] as! [String: Any]).keys),
              "\(name) job block keys match the C++ \(name) job example",
              "наши \(Set((object[name] as! [String: Any]).keys).sorted()) | пример \(Set((example[name] as! [String: Any]).keys).sorted())")
    }

    // --- 4. Result schemas.
    for (schema, test) in [("emc", EngineeringTestType.radiatedSusceptibility), ("icing", .icing),
                           ("flutter", .flutter), ("bird", .birdStrike)] {
        let fixture = try! Data(contentsOf: URL(fileURLWithPath: "CADNext/fea/schema/\(schema)-result.example.json"))
        check((try? EngineeringSolverResult.decode(fixture, expecting: test))?.schema == "cadnext-\(schema)-result/1",
              "schema/\(schema)-result.example.json decodes as a \(test.rawValue) result")
    }

    // --- 5. The bird, end to end.
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("probe-bird-runs")
    try? FileManager.default.removeItem(at: storeRoot)
    let store = WorkbenchStructuralRunStore(root: storeRoot)
    final class Box: @unchecked Sendable { var run: WorkbenchStructuralRun?; var error: String = "" }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    let buildToRun = build
    Task.detached {
        switch await WorkbenchStructuralRunner.run(birdCase, build: buildToRun, snapshot: snapshot, state: state, store: store, tool: tool) {
        case let .success(value): box.run = value
        case let .failure(error): box.error = error.description
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let birdRun = box.run, let patchRatio = birdRun.record.metrics["patchRatio"]?.value,
          let faceArea = birdRun.record.metrics["impactFaceAreaM2"]?.value,
          let birdArea = birdRun.record.metrics["birdAreaM2"]?.value else {
        check(false, "the bird case runs", box.error.isEmpty ? (box.run.map { $0.record.failureReasons.joined(separator: "; ") } ?? "нет прогона") : box.error)
        exit(1)
    }
    print(String(format: "  луч: птица 1.81 кг при 60 м/с в грань %.2f см² (мидель %.2f см²), отношение %.3f, вердикт %@",
                 faceArea * 1e4, birdArea * 1e4, patchRatio, birdRun.record.outcome.rawValue))
    check(birdRun.record.testType == .birdStrike, "the bird result files under birdStrike")
    check(abs(patchRatio - faceArea / birdArea) <= 1e-9,
          "the reported patch ratio is the struck face over the bird's own midsection",
          String(format: "%.6f против %.6f", patchRatio, faceArea / birdArea))
    build.structuralCases = [birdCase]
    let record = WorkbenchStructuralAggregate.record(
        .birdStrike, build: build, snapshot: snapshot, upstreamRecords: builtIn, runs: store.runs(vehicleID: snapshot.vehicleID))
    check(record?.metrics["patchRatio"] != nil, "the aircraft's bird record carries the patch ratio the verdict hinges on",
          record.map { $0.metrics.keys.sorted().joined(separator: ", ") } ?? "nil")
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
