import Foundation

/// What a test reads and which other tests' results it builds on (spec §4 TestDefinition).
///
/// The spec's §10 lists, change by change, which results a change invalidates. That table is
/// not maintained anywhere in code. It falls out of these declarations — a change touches
/// categories, categories reach the tests that read them, and staleness then travels down
/// the upstream edges — and `Tools/EngineeringValidationProbe` pins the outcome to the §10
/// scenarios. Where the result disagrees with the spec's table, the disagreement is written
/// down in the probe next to the scenario, with the physics that causes it.
struct EngineeringTestDefinition: Hashable {
    struct Upstream: Hashable {
        let test: EngineeringTestType
        /// Airframes for which the calculation has no meaningful input without this result.
        /// For the rest the upstream is optional: used when present, and a record computed
        /// without it stays valid when it later appears — it says what it was computed from.
        let requiredFor: Set<EngineeringAirframeKind>
    }

    let type: EngineeringTestType
    /// Bumped when the declared inputs or the meaning of the outputs change; every record
    /// stamped with an older version becomes outdated.
    let definitionVersion: Int
    let inputs: Set<EngineeringInputCategory>
    let upstream: [Upstream]
    let appliesTo: Set<EngineeringAirframeKind>
    /// Part of the minimum first complete version (spec appendix B) for these airframes.
    let requiredForReadinessOn: Set<EngineeringAirframeKind>
    let rationale: String

    func applies(to airframe: EngineeringAirframeKind) -> Bool { appliesTo.contains(airframe) }

    func isRequiredForReadiness(on airframe: EngineeringAirframeKind) -> Bool {
        requiredForReadinessOn.contains(airframe)
    }
}

enum EngineeringTestCatalog {
    /// Version of the rules that turn metrics into PASS/WARNING/FAIL. Recorded with every
    /// result so a verdict that changes after an update can be traced to the update (§17).
    static let validationRulesVersion = 1

    private static let all: Set<EngineeringAirframeKind> = Set(EngineeringAirframeKind.allCases)
    private static let lifting: Set<EngineeringAirframeKind> = [.fixedWing, .vtol]
    private static let rotorborne: Set<EngineeringAirframeKind> = [.multicopter, .vtol]

    static let definitions: [EngineeringTestDefinition] = [
        EngineeringTestDefinition(
            type: .geometryAssembly,
            definitionVersion: 1,
            inputs: [.outerGeometry, .structuralGeometry, .joints, .componentLayout],
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "Clearance and intersection are a property of shapes and where they sit."),
        EngineeringTestDefinition(
            type: .massProperties,
            definitionVersion: 1,
            inputs: [.outerGeometry, .structuralGeometry, .materials, .componentLayout],
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "Volume × density for the airframe, point and box masses for parts."),
        EngineeringTestDefinition(
            type: .propulsionBench,
            definitionVersion: 1,
            inputs: [.motorCharacteristics, .propellerCharacteristics, .batteryElectrical, .escCharacteristics],
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "Motor + propeller + ESC + battery as one bench; airspeed is a run setting."),
        EngineeringTestDefinition(
            type: .aerodynamics,
            definitionVersion: 1,
            inputs: [.outerGeometry, .controlSurfaceGeometry],
            // Optional for everyone: an AoA sweep of the clean airframe is the normal case;
            // with rotor slipstream it becomes a different, propulsion-dependent result.
            upstream: [EngineeringTestDefinition.Upstream(test: .propulsionBench, requiredFor: [])],
            appliesTo: all,
            requiredForReadinessOn: lifting,
            rationale: "Coefficients belong to the shape. Mass and CG do not enter: Cm is stored about a declared reference point and transferred to the CG by the consumer."),
        EngineeringTestDefinition(
            type: .structuralStatic,
            definitionVersion: 1,
            inputs: [.structuralGeometry, .materials, .joints],
            upstream: [
                // Every load case accelerates the masses: n·g on each part.
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: all),
                // Motor mounts and arms carry thrust; there is no load case without it.
                EngineeringTestDefinition.Upstream(test: .propulsionBench, requiredFor: all),
                // Wing bending comes from the lift distribution of a lifting airframe.
                EngineeringTestDefinition.Upstream(test: .aerodynamics, requiredFor: lifting),
            ],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "Stiffness from geometry, materials and joints; loads from mass, thrust and lift."),
        EngineeringTestDefinition(
            type: .modalVibration,
            definitionVersion: 2,
            inputs: [.structuralGeometry, .materials, .joints],
            upstream: [
                // Both edges are optional, and that is a correction: they were required while this
                // test meant "natural modes against the rotor band" and nothing else. It now also
                // holds sine sweeps and random spectra, and a shaker case brings its own excitation
                // — it never reads the bench, and without equipment it never reads the masses, so
                // requiring them would leave such a case permanently "computed without a required
                // input". The guard that matters did not move: the modal solver itself says
                // «полосы возбуждения не заданы — резонанс не проверен» when there is nothing to
                // compare the modes against, which is the same warning in the place where it is true.
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: []),
                EngineeringTestDefinition.Upstream(test: .propulsionBench, requiredFor: []),
            ],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "K and M give the modes; the propulsion RPM range gives the excitation."),
        EngineeringTestDefinition(
            type: .mechanicalShock,
            definitionVersion: 1,
            inputs: [.structuralGeometry, .materials, .joints],
            upstream: [
                // The equipment a face carries through the pulse comes from the mass properties; the
                // pulse itself is the user's (a catapult stroke, a landing, a drop), so nothing else
                // is read. A case of bare geometry without equipment stays valid.
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: []),
            ],
            appliesTo: all,
            // Not part of appendix B's minimum first version: a shock case exists only where the
            // airframe is actually shocked (catapult, hand launch, hard landing), and the spec does
            // not ask for it on every aircraft. It is required when the user declares the case.
            requiredForReadinessOn: [],
            rationale: "One event, one pulse: modes and damping give the response, the limit-load rules give the verdict."),
        EngineeringTestDefinition(
            type: .climatic,
            definitionVersion: 1,
            inputs: [.structuralGeometry, .materials, .componentLayout, .avionicsAndPayload],
            // The standard's air and the sun are the load; the equipment's own heat and limits are
            // typed in per case, because the component library carries no temperature limits and
            // inventing them would be worse than asking.
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: [],
            rationale: "MIL-STD-810H air, sun and the part's own heat; the verdict is equipment limits and thermal stress."),
        EngineeringTestDefinition(
            type: .fireResistance,
            definitionVersion: 1,
            inputs: [.structuralGeometry, .materials, .componentLayout, .avionicsAndPayload],
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: [],
            rationale: "ISO 2685 / AC 20-135 flame on named faces: integrity, strength when hot, the equipment's function."),
        EngineeringTestDefinition(
            type: .lightningDirect,
            definitionVersion: 1,
            inputs: [.structuralGeometry, .materials, .componentLayout, .avionicsAndPayload],
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: [],
            rationale: "SAE ARP5412 current through the part: where it spreads, what the arc heats, whether it burns through."),
        EngineeringTestDefinition(
            type: .radiatedSusceptibility,
            definitionVersion: 1,
            // The enclosure's shape and what it is made of decide what gets in; where the equipment
            // sits decides what it sees there.
            inputs: [.structuralGeometry, .materials, .componentLayout, .avionicsAndPayload],
            upstream: [],
            appliesTo: all,
            requiredForReadinessOn: [],
            rationale: "MIL-STD-461G RS103: the standard's field arrives as a plane wave, the question is how much reaches the equipment."),
        EngineeringTestDefinition(
            type: .icing,
            definitionVersion: 1,
            // Ice grows on the outer shape and depends on the material's heat, not on what is inside.
            inputs: [.outerGeometry, .materials],
            upstream: [],
            // Lifting surfaces only, and that is about the method rather than about the weather: a
            // multicopter's arms and blades ice up too, but the solver cuts aerofoil sections across
            // a span and computes collection on them. An icing answer for a quadcopter's arm would
            // be a number without a method behind it.
            appliesTo: lifting,
            requiredForReadinessOn: [],
            rationale: "14 CFR 25 App. C droplets: where they land, how thick the ice gets, what it takes to keep the surface clear."),
        EngineeringTestDefinition(
            type: .flutter,
            definitionVersion: 1,
            inputs: [.outerGeometry, .structuralGeometry, .materials, .joints],
            upstream: [
                // Mass on a lifting surface moves its modes and its centre of gravity, which is what
                // flutter is about; a case without declared equipment reads nothing.
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: []),
            ],
            appliesTo: lifting,
            requiredForReadinessOn: [],
            rationale: "14 CFR 25.629: at what speed the air stops damping the part's own bending and torsion."),
        EngineeringTestDefinition(
            type: .birdStrike,
            definitionVersion: 1,
            inputs: [.outerGeometry, .structuralGeometry, .materials, .joints],
            upstream: [
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: []),
            ],
            appliesTo: all,
            requiredForReadinessOn: [],
            rationale: "14 CFR 25.571(e): the bird's own pressure history on a face, through the part's modes."),
        EngineeringTestDefinition(
            type: .mechanism,
            definitionVersion: 1,
            inputs: [.structuralGeometry, .joints, .servoCharacteristics, .controlSurfaceGeometry],
            upstream: [EngineeringTestDefinition.Upstream(test: .aerodynamics, requiredFor: lifting)],
            appliesTo: lifting,
            requiredForReadinessOn: [],
            rationale: "Travel and self-collision from geometry; hinge moment from surface loads."),
        EngineeringTestDefinition(
            type: .thermalLimits,
            definitionVersion: 1,
            inputs: [.motorCharacteristics, .batteryElectrical, .escCharacteristics, .avionicsAndPayload],
            upstream: [EngineeringTestDefinition.Upstream(test: .propulsionBench, requiredFor: all)],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "Heat sources are the propulsion losses the bench produces plus avionics draw."),
        EngineeringTestDefinition(
            type: .controlAuthority,
            definitionVersion: 1,
            inputs: [.servoCharacteristics, .controlSurfaceGeometry],
            upstream: [
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: all),
                EngineeringTestDefinition.Upstream(test: .aerodynamics, requiredFor: lifting),
                // Differential thrust is the control law of anything that hovers.
                EngineeringTestDefinition.Upstream(test: .propulsionBench, requiredFor: rotorborne),
            ],
            appliesTo: all,
            requiredForReadinessOn: all,
            rationale: "Available moment against the inertia it has to turn."),
        EngineeringTestDefinition(
            type: .systemEndurance,
            definitionVersion: 1,
            inputs: [.batteryElectrical, .avionicsAndPayload, .servoCharacteristics],
            upstream: [
                EngineeringTestDefinition.Upstream(test: .propulsionBench, requiredFor: all),
                EngineeringTestDefinition.Upstream(test: .massProperties, requiredFor: all),
                EngineeringTestDefinition.Upstream(test: .aerodynamics, requiredFor: lifting),
            ],
            appliesTo: all,
            requiredForReadinessOn: [],
            rationale: "Energy over the power the weight (hover) or the drag (cruise) demands."),
    ]

    static func definition(_ type: EngineeringTestType) -> EngineeringTestDefinition {
        guard let definition = definitions.first(where: { $0.type == type }) else {
            preconditionFailure("no definition for \(type)")
        }
        return definition
    }

    /// Upstream before downstream; ties broken by declaration order so the result is stable.
    /// `nil` if the declarations contain a cycle or reference a test with no definition.
    static func topologicalOrder(_ definitions: [EngineeringTestDefinition] = definitions) -> [EngineeringTestType]? {
        let declared = Set(definitions.map(\.type))
        var remaining = definitions
        var ordered: [EngineeringTestType] = []
        var placed: Set<EngineeringTestType> = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { definition in
                definition.upstream.allSatisfy { declared.contains($0.test) && placed.contains($0.test) }
            }) else {
                return nil
            }
            let next = remaining.remove(at: index)
            ordered.append(next.type)
            placed.insert(next.type)
        }
        return ordered
    }

    /// Every test that directly or transitively builds on `type`.
    static func downstream(of type: EngineeringTestType) -> Set<EngineeringTestType> {
        var result: Set<EngineeringTestType> = []
        var frontier: [EngineeringTestType] = [type]
        while let current = frontier.popLast() {
            for definition in definitions where definition.upstream.contains(where: { $0.test == current }) {
                if result.insert(definition.type).inserted {
                    frontier.append(definition.type)
                }
            }
        }
        return result
    }
}
