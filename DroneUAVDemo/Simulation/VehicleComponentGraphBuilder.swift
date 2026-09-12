import Foundation
import simd

/// Builds the per-aircraft component graph and physical contact profile from
/// the profile/catalog data plus the geometry actually captured off the built
/// visual model (`DroneVisualGeometrySample`) — so the physics construction
/// always matches the rendered aircraft, for catalog, legacy and workbench
/// builds alike.
enum VehicleComponentGraphBuilder {
    struct Output {
        let graph: VehicleComponentGraph
        let contactProfile: VehicleContactProfile
        let rotorModel: VehicleRotorModel

        static let empty = Output(graph: .empty, contactProfile: .empty, rotorModel: .empty)
    }

    /// slot <-> propeller-geometry association carried out of the draft
    /// builders so the rotor model shares the graph's slot naming exactly.
    private typealias RotorSlotPair = (slot: String, propeller: DroneVisualGeometryPropeller)

    // MARK: - Strength table
    //
    // Impact energy (J per kg of aircraft mass) that destroys a pristine
    // component in one hit. Linear-in-mass keeps the *speed* threshold
    // constant across the fleet: destruction at roughly sqrt(2·J/kg) m/s of
    // normal contact speed regardless of aircraft size (prop ≈ 3.5 m/s,
    // arm ≈ 7.7 m/s, frame ≈ 13 m/s).
    private static func strengthJPerKg(for kind: VehicleComponentKind) -> Float {
        switch kind {
        case .propeller: return 6.0
        case .cameraGimbal: return 12.0
        case .wingSection(_, .outer): return 20.0
        case .elevator, .rudder: return 14.0
        case .horizontalTail, .verticalTail: return 25.0
        case .flightController, .radio: return 30.0
        case .arm: return 30.0
        case .esc, .payloadMount: return 35.0
        case .landingGear: return 40.0
        case .motor, .battery: return 45.0
        case .tailSection: return 50.0
        case .wingSection(_, .root): return 55.0
        case .fuselage: return 80.0
        case .frame: return 90.0
        }
    }

    /// Relative mass weight of the structural budget (total minus battery
    /// and payload). Normalized inside `build`, so only ratios matter.
    private static func massWeight(for kind: VehicleComponentKind) -> Float {
        switch kind {
        case .frame, .fuselage: return 0.42
        // Battery always carries a real (fixed) mass; listed only for exhaustiveness.
        case .battery: return 0.24
        case .arm: return 0.05
        case .motor: return 0.06
        case .propeller: return 0.008
        case .flightController: return 0.03
        case .esc: return 0.03
        case .radio: return 0.012
        case .cameraGimbal: return 0.06
        case .payloadMount: return 0.015
        case .wingSection(_, .root): return 0.11
        case .wingSection(_, .outer): return 0.07
        case .tailSection: return 0.055
        case .horizontalTail: return 0.045
        case .verticalTail: return 0.035
        case .elevator: return 0.014
        case .rudder: return 0.010
        case .landingGear: return 0.035
        }
    }

    private static func failureModes(for kind: VehicleComponentKind) -> [ComponentFailureMode] {
        switch kind {
        case .motor:
            return [.efficiencyLoss, .intermittent, .jam, .totalFailure]
        case .propeller:
            return [.efficiencyLoss, .totalFailure]
        case .battery, .esc:
            return [.efficiencyLoss, .intermittent, .totalFailure]
        case .flightController, .radio:
            return [.efficiencyLoss, .intermittent, .totalFailure]
        case .cameraGimbal:
            return [.intermittent, .totalFailure]
        case .wingSection(_, .outer), .horizontalTail, .verticalTail, .elevator, .rudder:
            return [.efficiencyLoss, .jam, .holdLastCommand, .totalFailure]
        case .wingSection(_, .root), .tailSection, .arm, .frame, .fuselage, .landingGear, .payloadMount:
            return [.efficiencyLoss, .totalFailure]
        }
    }

    // MARK: - Build

    static func build(
        profile: DroneModelProfile,
        vehicleMassModel: VehicleMassModel,
        geometry: DroneVisualGeometrySample
    ) -> Output {
        let totalMass = max(0.2, vehicleMassModel.resolvedCurrentTotalMass)
        let payloadMass = max(0.0, vehicleMassModel.payloadMass)
        let batteryMass = vehicleMassModel.batteryMass ?? totalMass * 0.24
        let structuralBudget = max(0.05, totalMass - payloadMass - batteryMass)
        let material = VehicleStructuralMaterial.resolve(profile: profile)

        var drafts: [ComponentDraft]
        var stations: [StationDraft]
        let rotorSlots: [RotorSlotPair]
        switch profile.airframeClass {
        case .multirotor:
            (drafts, rotorSlots, stations) = multirotorDrafts(geometry: geometry)
        case .fixedWing:
            (drafts, rotorSlots, stations) = fixedWingDrafts(geometry: geometry, includeLiftRotors: false, profile: profile)
        case .hybridVTOL:
            (drafts, rotorSlots, stations) = fixedWingDrafts(geometry: geometry, includeLiftRotors: true, profile: profile)
        }

        // Shared internals every airframe carries.
        let bodyCenter = geometry.boundsCenter
        drafts.append(ComponentDraft(
            kind: .battery,
            position: bodyCenter + SIMD3<Float>(0.0, -geometry.boundsSize.y * 0.10, 0.0),
            halfExtents: geometry.boundsSize * SIMD3<Float>(0.16, 0.12, 0.18),
            parentID: drafts.first?.id,
            legacy: .battery,
            fixedMass: batteryMass
        ))
        drafts.append(ComponentDraft(
            kind: .flightController,
            position: bodyCenter,
            halfExtents: SIMD3<Float>(repeating: max(0.015, geometry.boundsSize.y * 0.08)),
            parentID: drafts.first?.id,
            legacy: .flightControllerCore
        ))
        drafts.append(ComponentDraft(
            kind: .esc,
            position: bodyCenter + SIMD3<Float>(0.0, -geometry.boundsSize.y * 0.05, 0.0),
            halfExtents: SIMD3<Float>(repeating: max(0.012, geometry.boundsSize.y * 0.06)),
            parentID: drafts.first?.id,
            legacy: .escPower
        ))
        drafts.append(ComponentDraft(
            kind: .radio,
            position: bodyCenter + SIMD3<Float>(0.0, geometry.boundsSize.y * 0.12, geometry.boundsSize.z * 0.10),
            halfExtents: SIMD3<Float>(repeating: max(0.01, geometry.boundsSize.y * 0.05)),
            parentID: drafts.first?.id,
            legacy: nil
        ))
        drafts.append(ComponentDraft(
            kind: .cameraGimbal,
            position: geometry.fpvAnchorPosition,
            halfExtents: SIMD3<Float>(repeating: max(0.015, geometry.boundsSize.y * 0.10)),
            parentID: drafts.first?.id,
            legacy: .frontCameraGimbal
        ))
        drafts.append(ComponentDraft(
            kind: .payloadMount,
            position: geometry.payloadMountPosition,
            halfExtents: SIMD3<Float>(repeating: max(0.02, geometry.boundsSize.y * 0.10)),
            parentID: drafts.first?.id,
            legacy: nil,
            fixedMass: payloadMass > 0.0001 ? payloadMass : nil
        ))

        // Distribute the structural budget over every draft without a fixed
        // (known-real) mass, preserving the weight ratios. A station carries its
        // share of the member it was cut from.
        let weightedDrafts = drafts.filter { $0.fixedMass == nil }
        let totalWeight = weightedDrafts.reduce(Float(0.0)) { $0 + $1.massWeight }
        let massPerWeight = structuralBudget / max(0.0001, totalWeight)

        var components: [VehicleComponent] = []
        components.reserveCapacity(drafts.count)
        let strengthReferenceMass = max(0.20, totalMass - payloadMass)
        for draft in drafts {
            let mass = draft.fixedMass ?? draft.massWeight * massPerWeight
            components.append(
                VehicleComponent(
                    id: draft.id,
                    kind: draft.kind,
                    parentID: draft.parentID,
                    massKg: max(0.001, mass),
                    localPosition: draft.position,
                    boundingHalfExtents: simd_max(draft.halfExtents, SIMD3<Float>(repeating: 0.005)),
                    strengthJ: draft.strengthPerKg * strengthReferenceMass * profile.structuralQualityFactor,
                    integrity: 1.0,
                    legacyComponent: draft.legacy,
                    functionalDependencies: drafts
                        .filter { $0.parentID == draft.id }
                        .map(\.id)
                        .sorted(),
                    failureModes: failureModes(for: draft.kind)
                )
            )
        }

        // ⚠️ The catalogue's takeoff mass, not the live one and not the structural budget.
        // A mount is designed for the heaviest the aircraft is ever allowed to be, and
        // these three numbers are far apart: an RQ-7B's components add up to 77 kg, its
        // `resolvedCurrentTotalMass` is 78, and it is a 170 kg aircraft. Sizing from the
        // live mass left its propeller mount at 1,150 N against the 1,370 N of thrust its
        // own engine makes standing still, so it still threw the propeller.
        let designMass = max(totalMass, profile.takeoffMassKg)
        let limitLoadFactor = designLimitLoadFactor(profile: profile, designMassKg: designMass, stations: stations)
        let ultimateLoadFactor = limitLoadFactor * material.ultimateOverLimit
        let sections = designSections(
            stations: stations,
            components: components,
            designMassKg: designMass,
            maxThrustToWeight: maxThrustToWeight(profile: profile, vehicleMassModel: vehicleMassModel),
            rotorCount: max(1, rotorSlots.count),
            material: material,
            ultimateLoadFactor: ultimateLoadFactor,
            qualityFactor: profile.structuralQualityFactor
        )
        var graph = VehicleComponentGraph(
            components: components,
            designTakeoffMassKg: designMass,
            sections: sections,
            material: material
        )
        let contactProfile = contactProfile(
            for: profile,
            geometry: geometry,
            drafts: drafts
        )
        // Every joint is then floored at what the same load solver the aircraft will fly with
        // puts through it in the design cases. Sizing and loading can no longer disagree: a
        // pristine airframe carries its design loads, whatever path they take.
        let envelopes = designEnvelopes(
            graph: graph,
            profile: profile,
            designMassKg: designMass,
            maxThrustToWeight: maxThrustToWeight(profile: profile, vehicleMassModel: vehicleMassModel),
            ultimateLoadFactor: ultimateLoadFactor,
            ultimateOverLimit: material.ultimateOverLimit,
            contactProfile: contactProfile,
            wingAreaM2: 2 * stations.reduce(Float(0)) { total, station in
                guard case .wing = station.loading else { return total }
                return total + station.chord * station.length
            } / 2
        )
        graph.raiseSectionCapacities(to: envelopes, factor: max(1, profile.structuralQualityFactor))
        return Output(
            graph: graph,
            contactProfile: contactProfile,
            rotorModel: rotorModel(from: rotorSlots, massProperties: graph.massProperties,
                hasCyclic: profile.resolvedUAVProfile?.vehicleType == .helicopter)
        )
    }

    /// Limit load factor the airframe is designed to: the normal-category manoeuvre factor
    /// for its weight, or — for anything that flies on a wing — the 50 ft/s gust factor at
    /// cruise if that is larger. The gust case uses the wing loading the aerodynamics
    /// calibrates its wing area from (`½ρV_s²·CLmax`), so the two agree on the wing.
    private static func designLimitLoadFactor(
        profile: DroneModelProfile,
        designMassKg: Float,
        stations: [StationDraft]
    ) -> Float {
        let manoeuvre = VehicleSectionDesign.manoeuvreLimitLoadFactor(designMassKg: designMassKg)
        guard let wing = profile.fixedWingParameters else { return manoeuvre }
        let lift = FixedWingAerodynamics.designLiftCharacteristics(for: wing.family)
        let stall = max(3, wing.minSustainableSpeedMps)
        let loading = 0.5 * 1.225 * stall * stall * lift.maximumLift
        let wingStations = stations.filter { if case .wing = $0.loading { return true }; return false }
        let chord = wingStations.isEmpty ? 0.3
            : wingStations.reduce(Float(0)) { $0 + $1.chord } / Float(wingStations.count)
        let gust = VehicleSectionDesign.gustLimitLoadFactor(
            wingLoadingPa: loading, meanChordM: chord, liftSlopePerRad: lift.liftSlope,
            speedMps: max(wing.cruiseAirspeed, stall))
        return max(manoeuvre, gust)
    }

    /// Full-throttle thrust over weight. A rotor arm exists to carry its rotor's thrust, so
    /// it is sized for the most the propulsion can pull — on an FPV racer that is several
    /// times the aircraft's weight, far above any flight load factor.
    private static func maxThrustToWeight(profile: DroneModelProfile, vehicleMassModel: VehicleMassModel) -> Float {
        guard profile.airframeClass != .fixedWing else { return 0 }
        let baseline = FlightBaselineResolver.resolve(
            runtimeProfile: profile,
            activeUAVProfile: profile.resolvedUAVProfile,
            vehicleMassModel: vehicleMassModel,
            flightMode: .manual
        )
        return max(1.0, baseline.effectiveStabilizationThrust + baseline.effectiveThrottleAuthority * 0.35)
    }

    /// Designs every station section from the loads its member exists to carry.
    ///
    /// - Lifting surfaces carry the ultimate load factor times their share of the
    ///   aircraft's design weight. The main wing's share along the span follows Schrenk's
    ///   approximation (the mean of the planform and an ellipse over the full semi-span),
    ///   so the part hidden in the fuselage keeps its lift and the stations do not.
    /// - Tail surfaces and the fin take the ultimate load factor on their area share of the
    ///   airframe's lifting surface — the same rule the flight solver loads them with.
    /// - A boom carries the tail group at its end; an arm carries its rotor's thrust.
    private static func designSections(
        stations: [StationDraft],
        components: [VehicleComponent],
        designMassKg: Float,
        maxThrustToWeight: Float,
        rotorCount: Int,
        material: VehicleStructuralMaterial,
        ultimateLoadFactor: Float,
        qualityFactor: Float
    ) -> [String: VehicleJointSection] {
        guard !stations.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        let g: Float = 9.81
        let weight = designMassKg * g
        var children: [String: [String]] = [:]
        for component in components {
            if let parent = component.parentID { children[parent, default: []].append(component.id) }
        }
        let stationIDs = Set(stations.map(\.id))
        /// Mass and centre of a station plus everything mounted on it that is not itself a
        /// later station of a member.
        func lumped(_ id: String) -> (mass: Float, center: SIMD3<Float>) {
            var mass: Float = 0
            var moment = SIMD3<Float>(repeating: 0)
            var pending = [id]
            while let current = pending.popLast() {
                guard let component = byID[current] else { continue }
                mass += component.massKg
                moment += component.localPosition * component.massKg
                for child in children[current] ?? [] where !stationIDs.contains(child) { pending.append(child) }
            }
            return (max(0.0005, mass), moment / max(0.0005, mass))
        }
        let totalLiftingArea = components.reduce(Float(0)) { $0 + ($1.liftingSurface?.area ?? 0) }
        let wingArea = components.reduce(Float(0)) { total, component in
            if case .wingSection = component.kind { return total + (component.liftingSurface?.area ?? 0) }
            return total
        }
        let perRotorThrust = weight * max(maxThrustToWeight, ultimateLoadFactor / 1.5)
            / Float(rotorCount)

        var members: [String: [StationDraft]] = [:]
        for station in stations { members[station.memberID, default: []].append(station) }
        var result: [String: VehicleJointSection] = [:]
        for (memberID, memberStations) in members {
            let ordered = memberStations.sorted { $0.index < $1.index }
            let first = ordered[0]
            var designStations: [VehicleSectionDesign.Station] = []
            for station in ordered {
                let mass = lumped(station.id)
                let area = byID[station.id]?.liftingSurface?.area ?? 0
                var force: Float = 0
                var forceCenter = byID[station.id]?.localPosition ?? station.anchor
                switch station.loading {
                case .wing(let schrenkShare):
                    // Each half carries half the design lift; the wing, not the tail,
                    // carries the airframe in a manoeuvre.
                    force = ultimateLoadFactor * weight * 0.5 * schrenkShare
                case .liftingSurface:
                    let share = totalLiftingArea > 0.0001 ? area / totalLiftingArea : 0
                    force = ultimateLoadFactor * weight * share
                case .rotorTip:
                    force = 1.5 * perRotorThrust
                    forceCenter = station.tipPoint
                case .carriesTail(let tailArea, let tailCenter):
                    let share = totalLiftingArea > 0.0001 ? tailArea / totalLiftingArea : 0
                    force = ultimateLoadFactor * weight * share
                    forceCenter = tailCenter
                case .none:
                    force = 0
                }
                designStations.append(VehicleSectionDesign.Station(
                    id: station.id,
                    anchor: station.anchor,
                    spanAxis: station.spanAxis,
                    normalAxis: station.normalAxis,
                    length: station.length,
                    chord: station.chord,
                    depth: station.depth,
                    mass: mass.mass,
                    massCenter: mass.center,
                    designForce: force,
                    designForceCenter: forceCenter
                ))
            }
            _ = wingArea
            let designed = VehicleSectionDesign.sections(
                for: designStations,
                memberID: memberID,
                material: material,
                ultimateLoadFactor: ultimateLoadFactor,
                constantSection: first.constantSection,
                symmetricFlap: first.symmetricFlap,
                scatter: { id in (1.0 + 0.04 * unitJitter(for: "section.\(id)")) * max(1.0, qualityFactor) }
            )
            result.merge(designed) { $1 }
        }
        return result
    }

    /// Joint load envelope over the design cases, at ultimate (limit × `ultimateOverLimit`,
    /// which is 1.5 unless the material yields early):
    /// - symmetric pull at the ultimate factor, lift on the horizontal surfaces by area — or,
    ///   for anything that hovers, thrust at the lift rotors at the larger of that and
    ///   1.5 × its full-throttle thrust-to-weight;
    /// - push-over at −0.4 × that (the negative limit of the normal category);
    /// - side load of 0.75 g limit on the fins with 1 g lift (gust and rudder-kick cases);
    /// - landing at 2.67 g limit on the undercarriage with no lift, which is what bends a
    ///   wing down at touchdown (the landing load factor of CS-23.473);
    /// - emergency-landing inertia of every item of mass (already ultimate).
    private static func designEnvelopes(
        graph: VehicleComponentGraph,
        profile: DroneModelProfile,
        designMassKg: Float,
        maxThrustToWeight: Float,
        ultimateLoadFactor: Float,
        ultimateOverLimit: Float,
        contactProfile: VehicleContactProfile,
        wingAreaM2: Float
    ) -> [String: VehicleJointEnvelope] {
        let g: Float = 9.81
        let weight = designMassKg * g
        let properties = graph.massProperties
        let transforms = graph.deformationTransforms()
        func position(_ component: VehicleComponent) -> SIMD3<Float> {
            let p = (transforms[component.id] ?? matrix_identity_float4x4) * SIMD4<Float>(component.localPosition, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        let attached = graph.attachedComponents
        let horizontal = attached.filter { component in
            switch component.kind {
            case .wingSection, .horizontalTail, .elevator: return true
            default: return false
            }
        }
        let vertical = attached.filter { $0.kind == .verticalTail || $0.kind == .rudder }
        let motors = attached.filter { if case .motor = $0.kind { return true }; return false }
        let horizontalArea = horizontal.reduce(Float(0)) { $0 + ($1.liftingSurface?.area ?? 0) }
        let verticalArea = vertical.reduce(Float(0)) { $0 + ($1.liftingSurface?.area ?? 0) }
        let hovers = profile.airframeClass != .fixedWing
        let wingborne = profile.airframeClass != .multirotor && horizontalArea > 0.0001
        let gearID = attached.first { if case .landingGear = $0.kind { return true }; return false }?.id

        func lift(_ total: Float) -> [StructuralPointForce] {
            guard wingborne else { return [] }
            return horizontal.map { component in
                let share = (component.liftingSurface?.area ?? 0) / horizontalArea
                return StructuralPointForce(componentID: component.id, pointBody: position(component),
                                            forceBody: SIMD3<Float>(0, total * share, 0))
            }
        }
        func sideForces(_ total: Float) -> [StructuralPointForce] {
            guard verticalArea > 0.0001 else { return [] }
            return vertical.map { component in
                let share = (component.liftingSurface?.area ?? 0) / verticalArea
                return StructuralPointForce(componentID: component.id, pointBody: position(component),
                                            forceBody: SIMD3<Float>(total * share, 0, 0))
            }
        }
        func thrust(_ total: Float) -> [StructuralPointForce] {
            guard hovers, !motors.isEmpty else { return [] }
            return motors.map { motor in
                StructuralPointForce(componentID: motor.id, pointBody: position(motor),
                                     forceBody: SIMD3<Float>(0, total / Float(motors.count), 0))
            }
        }
        let n = ultimateLoadFactor
        let hoverFactor = max(n, 1.5 * maxThrustToWeight)
        let side = 0.75 * ultimateOverLimit
        var cases: [StructuralLoadCase] = []
        func add(_ factor: SIMD3<Float>, _ forces: [StructuralPointForce]) {
            cases.append(StructuralLoadCase(specificForceBody: factor * g,
                                            centerOfMass: properties.centerOfMassOffset, pointForces: forces))
        }
        if wingborne {
            add(SIMD3<Float>(0, n, 0), lift(n * weight))
            add(SIMD3<Float>(0, -VehicleSectionDesign.negativeFlapRatio * n, 0),
                lift(-VehicleSectionDesign.negativeFlapRatio * n * weight))
            for sign: Float in [-1, 1] {
                add(SIMD3<Float>(sign * side, 1, 0), lift(weight) + sideForces(sign * side * weight))
            }
        }
        if hovers {
            add(SIMD3<Float>(0, hoverFactor, 0), thrust(hoverFactor * weight))
        }
        let landing: Float = 2.67 * ultimateOverLimit
        if let gearID, let gear = graph.component(id: gearID) {
            add(SIMD3<Float>(0, landing, 0), [StructuralPointForce(
                componentID: gearID, pointBody: position(gear), forceBody: SIMD3<Float>(0, landing * weight, 0))])
        }
        // Emergency-landing inertia of every item of mass (CS-25.561, ultimate): 9 g forward,
        // 3 g sideward, 6 g down, 3 g up, 1.5 g aft. What these retain is equipment — a
        // battery, a gimbal, a control surface — through the deceleration of a crash that the
        // airframe itself survives. Body frame: the nose is −Z, so a forward inertia load is
        // the airframe decelerating toward +Z.
        for inertia in [SIMD3<Float>(0, 0, 9), SIMD3<Float>(3, 0, 0), SIMD3<Float>(-3, 0, 0),
                        SIMD3<Float>(0, 6, 0), SIMD3<Float>(0, -3, 0), SIMD3<Float>(0, 0, -1.5)] {
            add(inertia, [])
        }
        var envelopes: [String: VehicleJointEnvelope] = [:]
        for loadCase in cases {
            let loads = StructuralLoadField.jointLoads(graph: graph, loadCase: loadCase, transforms: transforms)
            for (id, load) in loads { envelopes[id, default: VehicleJointEnvelope()].include(load) }
        }

        // Equipment is qualified to MIL-STD-810 (Method 516): functional shock of 20 g with no
        // damage, and crash-hazard shock of 40 g that its mounts must still hold. Those are
        // the figures UAV equipment is bought against, and they are several times the 9 g
        // emergency-landing inertia of a transport cabin; with that as its only case a battery
        // strap let go when a pusher propeller touched the runway. Applied to the mounts of
        // equipment only — a wing is sized by what it flies, not by what its battery survives.
        let equipment = Set(graph.structuralConnections.compactMap { connection -> String? in
            guard let section = connection.section, !section.isMemberStation,
                  let child = graph.component(id: connection.childComponentID) else { return nil }
            if case .landingGear = child.kind { return nil }
            return child.id
        })
        let crashHazard = max(40, 20 * ultimateOverLimit)
        for axis in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0),
                     SIMD3<Float>(0, -1, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)] {
            let loadCase = StructuralLoadCase(specificForceBody: axis * crashHazard * g,
                                              centerOfMass: properties.centerOfMassOffset)
            let loads = StructuralLoadField.jointLoads(graph: graph, loadCase: loadCase, transforms: transforms)
            for (id, load) in loads where equipment.contains(id) {
                envelopes[id, default: VehicleJointEnvelope()].include(load)
            }
        }

        // The undercarriage is sized for the blow the contact solver will actually hand it: a
        // touchdown at the design sink speed of CS-23.473(d), V = 4.4·(W/S)^¼ ft/s held to
        // 7–10 ft/s, struck at each of its contact points with the impulse, pulse length and
        // lever the impact path uses. A static load at the middle of the gear, which is what it
        // had, is not the load it gets: a touchdown on one corner of it put a bending moment
        // through the mount the design had never seen, and a 2 m/s landing tore it off.
        if let gearID, let gear = graph.component(id: gearID) {
            let wingLoadingLbFt2 = wingAreaM2 > 0.01 ? weight / wingAreaM2 * 0.020_885 : 0
            let sinkFtS = wingLoadingLbFt2 > 0 ? min(10, max(7, 4.4 * pow(wingLoadingLbFt2, 0.25))) : 7
            let sink = sinkFtS * 0.3048
            let inertia = simd_max(properties.inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
            let up = SIMD3<Float>(0, 1, 0)
            let duration = ImpactResolutionService.contactDuration(component: gear, material: .asphalt, closingSpeed: sink)
            for sphere in contactProfile.spheres where sphere.componentID == gearID {
                let point = sphere.offset - up * sphere.radius
                let lever = point - properties.centerOfMassOffset
                let angularPerImpulse = simd_cross(lever, up) / inertia
                let inverseMass = 1 / designMassKg + simd_dot(simd_cross(angularPerImpulse, lever), up)
                let impulse = (1 + ImpactSurfaceMaterial.asphalt.restitution) * sink / max(1e-6, inverseMass)
                let force = up * impulse * Float.pi / (2 * max(0.001, duration)) * ultimateOverLimit
                // Wing lift equal to the weight through the touchdown (CS-23.473(e)): the
                // aircraft is at 1 g plus the blow, and the lift acts on the wing, not here.
                var loadCase = StructuralLoadCase(specificForceBody: force / designMassKg + up * g,
                                                  centerOfMass: properties.centerOfMassOffset,
                                                  pointForces: [StructuralPointForce(componentID: gearID, pointBody: point,
                                                                                      forceBody: force)])
                loadCase.angularAccelerationBody = simd_cross(lever, force) / inertia
                let loads = StructuralLoadField.jointLoads(graph: graph, loadCase: loadCase, transforms: transforms)
                if let load = loads[gearID] { envelopes[gearID, default: VehicleJointEnvelope()].include(load) }
            }
        }
        return envelopes
    }

    /// Stable −1...1 from a string (FNV-1a), so build scatter belongs to the airframe and a
    /// replay fails the same way.
    private static func unitJitter(for key: String) -> Float {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Float(Double(hash % 20_001) / 10_000.0 - 1.0)
    }

    private static func rotorModel(
        from rotorSlots: [RotorSlotPair],
        massProperties: VehicleMassProperties,
        hasCyclic: Bool
    ) -> VehicleRotorModel {
        guard !rotorSlots.isEmpty else { return .empty }

        // Geometry samples and graph components use the aircraft state
        // origin (the ground/gear reference), while `VehicleRotor.offsetBody`
        // is explicitly CoM-relative. Keep that convention literal: it makes
        // both the moment arm and VTOL nearest-mount lookup agree after a CoM
        // shift (the latter reconstructs origin-relative geometry by adding
        // the current center of mass back to the rotor offset).
        let centerOfMass = massProperties.centerOfMassOffset

        var rotors: [VehicleRotor] = []
        rotors.reserveCapacity(rotorSlots.count)
        var armSum: Float = 0.0
        for pair in rotorSlots {
            let offset = pair.propeller.center - centerOfMass
            armSum += simd_length(SIMD2<Float>(offset.x, offset.z))
            rotors.append(
                VehicleRotor(
                    slot: pair.slot,
                    offsetBody: offset,
                    spinSign: pair.propeller.spinDirection,
                    laneIndex: VehicleRotor.laneIndex(forSlot: pair.slot),
                    thrustFactor: 1.0,
                    vibration01: 0.0
                )
            )
        }
        let meanArm = armSum / Float(rotors.count)
        // κ scales with arm length so yaw authority stays proportionate
        // across airframe sizes (0.02 N·m/N at a typical 0.15 m arm).
        let kappa = max(0.004, 0.02 * meanArm / 0.15)
        return VehicleRotorModel(rotors: rotors, torqueToThrustRatio: kappa,
                                 cyclicTiltLimitRad: hasCyclic ? Float.pi / 12 : 0)
    }

    // MARK: - Drafts

    private struct ComponentDraft {
        let id: String
        let kind: VehicleComponentKind
        let position: SIMD3<Float>
        let halfExtents: SIMD3<Float>
        let parentID: String?
        let legacy: DamageComponent?
        let fixedMass: Float?
        /// Share of the structural budget (only ratios matter).
        let massWeight: Float
        /// Impact energy per kg of aircraft that destroys the part in one hit.
        let strengthPerKg: Float

        init(
            kind: VehicleComponentKind,
            position: SIMD3<Float>,
            halfExtents: SIMD3<Float>,
            parentID: String?,
            legacy: DamageComponent?,
            fixedMass: Float? = nil,
            idSuffix: String? = nil,
            id explicitID: String? = nil,
            massWeight: Float? = nil,
            strengthPerKg: Float? = nil
        ) {
            self.kind = kind
            self.position = position
            self.halfExtents = halfExtents
            self.parentID = parentID
            self.legacy = legacy
            self.fixedMass = fixedMass
            self.id = explicitID ?? Self.identifier(for: kind, suffix: idSuffix)
            self.massWeight = massWeight ?? VehicleComponentGraphBuilder.massWeight(for: kind)
            self.strengthPerKg = strengthPerKg ?? VehicleComponentGraphBuilder.strengthJPerKg(for: kind)
        }

        static func identifier(for kind: VehicleComponentKind, suffix: String?) -> String {
            let base: String
            switch kind {
            case .frame: base = "frame"
            case .fuselage: base = "fuselage"
            case .arm(let slot): base = "arm.\(slot)"
            case .motor(let slot): base = "motor.\(slot)"
            case .propeller(let slot): base = "propeller.\(slot)"
            case .battery: base = "battery"
            case .flightController: base = "flightController"
            case .esc: base = "esc"
            case .radio: base = "radio"
            case .cameraGimbal: base = "cameraGimbal"
            case .payloadMount: base = "payloadMount"
            case .wingSection(let side, let segment): base = "wing.\(side.rawValue).\(segment.rawValue)"
            case .tailSection: base = "tail.section"
            case .horizontalTail: base = "tail.horizontal"
            case .verticalTail: base = "tail.vertical"
            case .elevator: base = "tail.elevator"
            case .rudder: base = "tail.rudder"
            case .landingGear(let slot): base = "gear.\(slot)"
            }
            if let suffix { return "\(base).\(suffix)" }
            return base
        }
    }

    /// How a station is loaded when its section is designed.
    private enum StationLoading {
        /// Main-wing station with its Schrenk share of the half-wing's design lift.
        case wing(schrenkShare: Float)
        /// Tail surface or fin: area share of the airframe's lifting surface.
        case liftingSurface
        /// The outermost arm station carries its rotor's full thrust at the tip point.
        case rotorTip
        /// The outermost boom station carries the tail group's load at its end.
        case carriesTail(area: Float, center: SIMD3<Float>)
        case none
    }

    /// Geometry of one station of a discretised member, in the builder's body frame.
    private struct StationDraft {
        let id: String
        let memberID: String
        let index: Int
        /// Inboard joint on the elastic axis.
        let anchor: SIMD3<Float>
        let spanAxis: SIMD3<Float>
        let normalAxis: SIMD3<Float>
        let length: Float
        let chord: Float
        let depth: Float
        let loading: StationLoading
        let tipPoint: SIMD3<Float>
        let constantSection: Bool
        let symmetricFlap: Bool
    }

    /// Stations per member. Twelve per half-wing puts a possible break every ~8 % of the
    /// exposed span — finer than any real control-surface segment — while the chain solver
    /// stays a few thousand operations per impact. Tail surfaces, booms and arms are
    /// shorter and get four.
    private static let wingStationCount = 12
    private static let shortMemberStationCount = 4

    /// A straight chain of `count` stations from `root` along `axis` for `length`, each a box
    /// of the given cross-section. Returns drafts parented root→tip under `parentID`.
    private static func straightMember(
        memberID: String,
        kind: (Int) -> VehicleComponentKind,
        root: SIMD3<Float>,
        axis: SIMD3<Float>,
        normal: SIMD3<Float>,
        length: Float,
        count: Int,
        crossSection: SIMD2<Float>,
        parentID: String,
        legacy: DamageComponent?,
        totalMassWeight: Float,
        totalStrengthPerKg: Float,
        loading: (Int) -> StationLoading,
        constantSection: Bool,
        symmetricFlap: Bool
    ) -> (drafts: [ComponentDraft], stations: [StationDraft]) {
        let span = simd_normalize(axis)
        var normalAxis = normal - span * simd_dot(normal, span)
        if simd_length_squared(normalAxis) < 1e-6 { normalAxis = SIMD3<Float>(0, 1, 0) }
        normalAxis = simd_normalize(normalAxis)
        let chordAxis = simd_normalize(simd_cross(span, normalAxis))
        let step = max(0.002, length) / Float(count)
        var drafts: [ComponentDraft] = []
        var stations: [StationDraft] = []
        var parent = parentID
        for index in 0..<count {
            let anchor = root + span * (step * Float(index))
            let center = anchor + span * (step * 0.5)
            // Axis-aligned half extents of the oriented station box.
            let half = simd_abs(span) * (step * 0.5)
                + simd_abs(normalAxis) * (crossSection.y * 0.5)
                + simd_abs(chordAxis) * (crossSection.x * 0.5)
            let id = "\(memberID).s\(String(format: "%02d", index))"
            drafts.append(ComponentDraft(
                kind: kind(index),
                position: center,
                halfExtents: half,
                parentID: parent,
                legacy: legacy,
                id: id,
                massWeight: totalMassWeight / Float(count),
                strengthPerKg: totalStrengthPerKg / Float(count)
            ))
            stations.append(StationDraft(
                id: id, memberID: memberID, index: index,
                anchor: anchor, spanAxis: span, normalAxis: normalAxis,
                length: step, chord: crossSection.x, depth: crossSection.y,
                loading: loading(index), tipPoint: root + span * max(0.002, length),
                constantSection: constantSection, symmetricFlap: symmetricFlap))
            parent = id
        }
        return (drafts, stations)
    }

    /// Quadrant naming in the physics body frame: nose toward -Z, +X right.
    ///
    /// `size` is the airframe's bounding extent, and it is here only to set a dead band
    /// around the centreline. A part sitting *on* the axis — a tail pusher, a nose
    /// tractor, the middle motors of a hex — has no side, and the yaw flip the visual
    /// goes through leaves about half a micron of rounding on its x, so the comparison
    /// was picking a side out of floating-point noise. The visual makes the same call
    /// independently (`UAVModelAssetLibrary.corner`) and was landing on the other one,
    /// which is how a propeller ended up in a bucket holding no geometry. One part per
    /// thousand of span is three orders above that noise and two below any real motor
    /// offset; inside it both sides resolve to the same answer, right and rear.
    private static func quadrantSlot(
        of position: SIMD3<Float>,
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        index: Int
    ) -> (slot: String, motor: DamageComponent, propeller: DamageComponent, arm: DamageComponent) {
        let front = position.z - center.z < -max(1e-4, size.z * 1e-3)
        let left = position.x - center.x < -max(1e-4, size.x * 1e-3)
        if index < 4 {
            switch (front, left) {
            case (true, true): return ("FL", .motorFL, .propellerFL, .armFL)
            case (true, false): return ("FR", .motorFR, .propellerFR, .armFR)
            case (false, true): return ("RL", .motorRL, .propellerRL, .armRL)
            case (false, false): return ("RR", .motorRR, .propellerRR, .armRR)
            }
        }
        // Rotors beyond the classic four keep a unique slot but still project
        // onto the nearest legacy quadrant so the overlay shows something.
        switch (front, left) {
        case (true, true): return ("M\(index + 1)", .motorFL, .propellerFL, .armFL)
        case (true, false): return ("M\(index + 1)", .motorFR, .propellerFR, .armFR)
        case (false, true): return ("M\(index + 1)", .motorRL, .propellerRL, .armRL)
        case (false, false): return ("M\(index + 1)", .motorRR, .propellerRR, .armRR)
        }
    }

    private static func multirotorDrafts(
        geometry: DroneVisualGeometrySample
    ) -> (drafts: [ComponentDraft], rotorSlots: [RotorSlotPair], stations: [StationDraft]) {
        let center = geometry.boundsCenter
        let size = geometry.boundsSize
        var drafts: [ComponentDraft] = []
        var stations: [StationDraft] = []
        var rotorSlots: [RotorSlotPair] = []

        let frame = ComponentDraft(
            kind: .frame,
            position: center,
            halfExtents: size * SIMD3<Float>(0.28, 0.42, 0.30),
            parentID: nil,
            legacy: nil
        )
        drafts.append(frame)

        var usedSlots: Set<String> = []
        var nextExtraSlot = 5
        for (index, prop) in geometry.propellers.enumerated() {
            var quadrant = quadrantSlot(of: prop.center, center: center, size: size, index: index)
            if usedSlots.contains(quadrant.slot) {
                while usedSlots.contains("M\(nextExtraSlot)") {
                    nextExtraSlot += 1
                }
                quadrant = ("M\(nextExtraSlot)", quadrant.motor, quadrant.propeller, quadrant.arm)
                nextExtraSlot += 1
            }
            usedSlots.insert(quadrant.slot)
            rotorSlots.append((quadrant.slot, prop))

            // The arm is a tube from the edge of the central body to the motor. Its
            // stations let it crack at the clamp, buckle mid-length or lose its tip with
            // the motor, wherever the load actually peaks.
            var horizontal = prop.center - center
            horizontal.y = 0
            let armLength = simd_length(horizontal)
            let motorParent: String
            if armLength > 0.01 {
                let axis = horizontal / armLength
                let root = SIMD3<Float>(center.x, prop.center.y - 0.01, center.z) + axis * (armLength * 0.25)
                let length = armLength * 0.75
                let member = straightMember(
                    memberID: "arm.\(quadrant.slot)",
                    kind: { _ in .arm(slot: quadrant.slot) },
                    root: root,
                    axis: axis,
                    normal: SIMD3<Float>(0, 1, 0),
                    length: length,
                    count: shortMemberStationCount,
                    crossSection: SIMD2<Float>(max(0.016, armLength * 0.12), max(0.012, size.y * 0.10)),
                    parentID: frame.id,
                    legacy: quadrant.arm,
                    totalMassWeight: massWeight(for: .arm(slot: quadrant.slot)),
                    totalStrengthPerKg: strengthJPerKg(for: .arm(slot: quadrant.slot)),
                    loading: { $0 == shortMemberStationCount - 1 ? .rotorTip : .none },
                    constantSection: true,
                    symmetricFlap: true
                )
                drafts.append(contentsOf: member.drafts)
                stations.append(contentsOf: member.stations)
                motorParent = member.drafts.last?.id ?? frame.id
            } else {
                // A rotor on the hub (coaxial mast, single-rotor): no arm to break.
                motorParent = frame.id
            }
            drafts.append(ComponentDraft(
                kind: .motor(slot: quadrant.slot),
                position: prop.center - SIMD3<Float>(0.0, 0.015, 0.0),
                halfExtents: SIMD3<Float>(repeating: max(0.012, prop.radius * 0.18)),
                parentID: motorParent,
                legacy: quadrant.motor
            ))
            drafts.append(ComponentDraft(
                kind: .propeller(slot: quadrant.slot),
                position: prop.center,
                halfExtents: SIMD3<Float>(prop.radius, max(0.006, prop.radius * 0.08), prop.radius),
                parentID: ComponentDraft.identifier(for: .motor(slot: quadrant.slot), suffix: nil),
                legacy: quadrant.propeller
            ))
        }

        drafts.append(ComponentDraft(
            kind: .landingGear(slot: "main"),
            position: SIMD3<Float>(center.x, size.y * 0.06, center.z),
            halfExtents: SIMD3<Float>(size.x * 0.30, max(0.01, size.y * 0.08), size.z * 0.30),
            parentID: frame.id,
            legacy: nil
        ))

        return (drafts, rotorSlots, stations)
    }

    /// One half of the main wing, cut into stations along the real planform.
    ///
    /// The exposed wing starts at the side of the fuselage; inboard of that the wing box
    /// is carried through the body and its lift belongs to the body. Each station keeps the
    /// chord, sweep, depth and dihedral of the strip it was cut from, so a tapered tip is
    /// light and weak and a swept station sits aft of the one inboard of it.
    private static func wingMember(
        side: VehicleBodySide,
        geometry: DroneVisualGeometrySample,
        fallback: (center: SIMD3<Float>, halfExtents: SIMD3<Float>),
        parentID: String
    ) -> (drafts: [ComponentDraft], stations: [StationDraft]) {
        let centerX = fallback.center.x
        let sign: Float = side == .left ? -1 : 1
        var slices = geometry.wingPlanform.filter { ($0.centerX - centerX) * sign > 0 }
        if slices.count < 2 {
            // No sampled planform (procedural visual): a rectangle over the bucket boxes.
            let half = fallback.halfExtents
            let count = 24
            slices = (0..<count).map { index in
                let a = centerX + sign * half.x * Float(index) / Float(count)
                let b = centerX + sign * half.x * Float(index + 1) / Float(count)
                return DroneVisualGeometryPlanformSlice(
                    x0: min(a, b), x1: max(a, b),
                    leadingZ: fallback.center.z - half.z, trailingZ: fallback.center.z + half.z,
                    lowerY: fallback.center.y - half.y, upperY: fallback.center.y + half.y)
            }
        }
        slices.sort { abs($0.centerX - centerX) < abs($1.centerX - centerX) }
        let tipX = side == .left ? slices.map(\.x0).min()! : slices.map(\.x1).max()!
        let semiSpan = max(0.01, abs(tipX - centerX))
        let rootOffset = min(max(0, geometry.fuselageHalfWidth), semiSpan * 0.35)
        let rootX = centerX + sign * rootOffset
        let exposed = abs(tipX - rootX)
        guard exposed > 0.02 else { return ([], []) }

        func planform(at x: Float) -> DroneVisualGeometryPlanformSlice {
            slices.min { abs($0.centerX - x) < abs($1.centerX - x) }!
        }
        /// Overlap-weighted average of the strips between two span positions.
        func strip(_ a: Float, _ b: Float) -> DroneVisualGeometryPlanformSlice {
            let lo = min(a, b), hi = max(a, b)
            var weight: Float = 0, lead: Float = 0, trail: Float = 0, low: Float = 0, high: Float = 0
            for slice in slices {
                let overlap = min(hi, slice.x1) - max(lo, slice.x0)
                guard overlap > 0 else { continue }
                weight += overlap
                lead += slice.leadingZ * overlap; trail += slice.trailingZ * overlap
                low += slice.lowerY * overlap; high += slice.upperY * overlap
            }
            guard weight > 0 else { return planform(at: (a + b) * 0.5) }
            return DroneVisualGeometryPlanformSlice(x0: lo, x1: hi, leadingZ: lead / weight,
                trailingZ: trail / weight, lowerY: low / weight, upperY: high / weight)
        }
        // The spar is straight. Following each strip's own 35 % chord point instead let a
        // tail-boom root or an engine nacelle faired into the wing drag the axis 0.25 m
        // forward and back again: on the FT5 three stations came out swept ±48°, and a pure
        // lift moment read across such a kinked axis became torsion as large as a third of
        // the bending — enough to yield the root at 3.6 g. Theil–Sen (median of pairwise
        // slopes) fits the line through the strips and ignores up to ~29 % of them being
        // something other than wing, which a least-squares line does not.
        let axisSamples: [SIMD3<Float>] = (0...24).map { index in
            let x = rootX + sign * exposed * Float(index) / 24
            let slice = planform(at: x)
            return SIMD3<Float>(x, slice.midY, slice.leadingZ + slice.chord * 0.35)
        }
        func theilSen(_ value: (SIMD3<Float>) -> Float) -> (at: Float, slope: Float) {
            var slopes: [Float] = []
            for i in axisSamples.indices {
                for j in axisSamples.indices where j > i {
                    let dx = axisSamples[j].x - axisSamples[i].x
                    guard abs(dx) > 1e-5 else { continue }
                    slopes.append((value(axisSamples[j]) - value(axisSamples[i])) / dx)
                }
            }
            func median(_ values: [Float]) -> Float {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                    : 0.5 * (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2])
            }
            let slope = median(slopes)
            return (median(axisSamples.map { value($0) - slope * ($0.x - rootX) }), slope)
        }
        let axisY = theilSen { $0.y }
        let axisZ = theilSen { $0.z }
        func elasticAxis(at x: Float) -> SIMD3<Float> {
            SIMD3<Float>(x, axisY.at + axisY.slope * (x - rootX), axisZ.at + axisZ.slope * (x - rootX))
        }
        // Schrenk: the mean of the planform's own area distribution and an ellipse over the
        // full semi-span from the centreline.
        let semiArea = slices.reduce(Float(0)) { $0 + $1.chord * ($1.x1 - $1.x0) }
        func ellipse(_ u: Float) -> Float {
            let c = min(1, max(0, u))
            return 0.5 * (c * sqrt(max(0, 1 - c * c)) + asin(c))
        }

        let count = wingStationCount
        var drafts: [ComponentDraft] = []
        var stations: [StationDraft] = []
        var parent = parentID
        let areas: [Float] = (0..<count).map { index in
            let a = rootX + sign * exposed * Float(index) / Float(count)
            let b = rootX + sign * exposed * Float(index + 1) / Float(count)
            return strip(a, b).chord * abs(b - a)
        }
        let totalArea = max(1e-6, areas.reduce(0, +))
        let perSideWeight = massWeight(for: .wingSection(side: side, segment: .root))
            + massWeight(for: .wingSection(side: side, segment: .outer))
        let perSideStrength = strengthJPerKg(for: .wingSection(side: side, segment: .root))
            + strengthJPerKg(for: .wingSection(side: side, segment: .outer))
        let legacy: DamageComponent = side == .left ? .armFL : .armFR
        let tip = elasticAxis(at: tipX)
        for index in 0..<count {
            let a = rootX + sign * exposed * Float(index) / Float(count)
            let b = rootX + sign * exposed * Float(index + 1) / Float(count)
            let piece = strip(a, b)
            let anchor = elasticAxis(at: a)
            let next = index + 1 < count ? elasticAxis(at: b) : tip
            var spanAxis = next - anchor
            if simd_length_squared(spanAxis) < 1e-8 { spanAxis = SIMD3<Float>(sign, 0, 0) }
            spanAxis = simd_normalize(spanAxis)
            let up = SIMD3<Float>(0, 1, 0)
            let normal = simd_normalize(up - spanAxis * simd_dot(up, spanAxis))
            let segment: VehicleWingSegment = index < count / 2 ? .root : .outer
            let id = "wing.\(side.rawValue).\(segment.rawValue).s\(String(format: "%02d", index))"
            let share = areas[index] / totalArea
            drafts.append(ComponentDraft(
                kind: .wingSection(side: side, segment: segment),
                position: SIMD3<Float>((a + b) * 0.5, piece.midY, piece.leadingZ + piece.chord * 0.5),
                halfExtents: SIMD3<Float>(abs(b - a) * 0.5, piece.depth * 0.5, piece.chord * 0.5),
                parentID: parent,
                legacy: legacy,
                id: id,
                massWeight: perSideWeight * share,
                strengthPerKg: perSideStrength * share
            ))
            let u0 = abs(a - centerX) / semiSpan, u1 = abs(b - centerX) / semiSpan
            let schrenk = 0.5 * areas[index] / max(1e-6, semiArea)
                + 0.5 * (ellipse(u1) - ellipse(u0)) / (Float.pi / 4)
            stations.append(StationDraft(
                id: id, memberID: "wing.\(side.rawValue)", index: index,
                anchor: anchor, spanAxis: spanAxis, normalAxis: normal,
                length: simd_distance(anchor, next), chord: piece.chord, depth: piece.depth,
                loading: .wing(schrenkShare: schrenk), tipPoint: tip,
                constantSection: false, symmetricFlap: false))
            parent = id
        }
        return (drafts, stations)
    }

    private static func fixedWingDrafts(
        geometry: DroneVisualGeometrySample,
        includeLiftRotors: Bool,
        profile: DroneModelProfile
    ) -> (drafts: [ComponentDraft], rotorSlots: [RotorSlotPair], stations: [StationDraft]) {
        let center = geometry.boundsCenter
        let size = geometry.boundsSize
        var drafts: [ComponentDraft] = []
        var stations: [StationDraft] = []
        var rotorSlots: [RotorSlotPair] = []

        let fuselage = ComponentDraft(
            kind: .fuselage,
            position: center,
            halfExtents: SIMD3<Float>(
                max(0.03, max(size.x * 0.07, geometry.fuselageHalfWidth)),
                size.y * 0.42,
                size.z * 0.46
            ),
            parentID: nil,
            legacy: nil
        )
        drafts.append(fuselage)

        // The visual builders map the two wing halves onto .armFL/.armFR.
        // Merge *both* sets of boxes before splitting the resulting full-span
        // envelope; falling back from one side to the other silently modeled
        // only half a fixed wing whenever both mappings existed.
        let wingBoxes = geometry.boxes(for: .armFL) + geometry.boxes(for: .armFR)
        let wingBounds = unionBounds(of: wingBoxes)
        let fallback = (
            center: SIMD3<Float>(center.x, wingBounds?.center.y ?? center.y, wingBounds?.center.z ?? center.z),
            halfExtents: SIMD3<Float>(
                wingBounds?.halfExtents.x ?? size.x * 0.5,
                max(0.008, wingBounds?.halfExtents.y ?? size.y * 0.06),
                max(0.03, wingBounds?.halfExtents.z ?? size.z * 0.16)
            )
        )
        for side in [VehicleBodySide.left, .right] {
            let member = wingMember(side: side, geometry: geometry, fallback: fallback, parentID: fuselage.id)
            drafts.append(contentsOf: member.drafts)
            stations.append(contentsOf: member.stations)
        }

        // Tail group at the rear extreme (+Z in the body frame — nose is -Z): a boom carrying
        // a two-piece stabiliser and a fin, each a chain of stations that can crack or fold
        // anywhere along its length.
        //
        // ⚠️ Only if the aircraft has one. A flying wing's model draws no empennage, and the
        // generic tail used to be added regardless: it put contact spheres, mass and — now —
        // a load-bearing structure behind the trailing edge where nothing is drawn.
        let hasTail = profile.airframeStyle != .flyingWing
            && !(geometry.boxes(for: .armRL) + geometry.boxes(for: .armRR)).isEmpty
            || (geometry.componentBoxes.isEmpty && profile.airframeStyle != .flyingWing)
        if hasTail {
            let tailZ = center.z + size.z * 0.42
            let horizontalHalfChord = max(0.03, size.z * 0.08)
            let verticalHalfChord = max(0.03, size.z * 0.08)
            let horizontalArea = 0.36 * size.x * 1.4 * horizontalHalfChord
            let verticalArea = 0.5 * size.y * 1.4 * verticalHalfChord
            let tailCenter = SIMD3<Float>(center.x, center.y + size.y * 0.1, tailZ)
            let boom = straightMember(
                memberID: "tail.section",
                kind: { _ in .tailSection },
                root: SIMD3<Float>(center.x, center.y, center.z + size.z * 0.16),
                axis: SIMD3<Float>(0, 0, 1),
                normal: SIMD3<Float>(0, 1, 0),
                length: size.z * 0.28,
                count: shortMemberStationCount,
                crossSection: SIMD2<Float>(2 * max(0.018, size.x * 0.055), 2 * max(0.018, size.y * 0.12)),
                parentID: fuselage.id,
                legacy: nil,
                totalMassWeight: massWeight(for: .tailSection),
                totalStrengthPerKg: strengthJPerKg(for: .tailSection),
                loading: { index in
                    index == shortMemberStationCount - 1
                        ? .carriesTail(area: horizontalArea + verticalArea, center: tailCenter) : .none
                },
                constantSection: true,
                symmetricFlap: true
            )
            drafts.append(contentsOf: boom.drafts)
            stations.append(contentsOf: boom.stations)
            let tailRoot = boom.drafts.last?.id ?? fuselage.id

            for side in [VehicleBodySide.left, .right] {
                let sign: Float = side == .left ? -1 : 1
                let half = straightMember(
                    memberID: "tail.horizontal.\(side.rawValue)",
                    kind: { _ in .horizontalTail },
                    root: SIMD3<Float>(center.x, center.y, tailZ - horizontalHalfChord * 0.30),
                    axis: SIMD3<Float>(sign, 0, 0),
                    normal: SIMD3<Float>(0, 1, 0),
                    length: size.x * 0.18,
                    count: shortMemberStationCount,
                    crossSection: SIMD2<Float>(1.4 * horizontalHalfChord, 2 * max(0.008, size.y * 0.05)),
                    parentID: tailRoot,
                    legacy: .armRL,
                    totalMassWeight: massWeight(for: .horizontalTail) * 0.5,
                    totalStrengthPerKg: strengthJPerKg(for: .horizontalTail) * 0.5,
                    loading: { _ in .liftingSurface },
                    constantSection: false,
                    symmetricFlap: true
                )
                drafts.append(contentsOf: half.drafts)
                stations.append(contentsOf: half.stations)
            }
            drafts.append(ComponentDraft(
                kind: .elevator,
                position: SIMD3<Float>(center.x, center.y, tailZ + horizontalHalfChord * 0.70),
                halfExtents: SIMD3<Float>(size.x * 0.17, max(0.006, size.y * 0.04), horizontalHalfChord * 0.30),
                parentID: tailRoot,
                legacy: .armRL
            ))

            let fin = straightMember(
                memberID: "tail.vertical",
                kind: { _ in .verticalTail },
                root: SIMD3<Float>(center.x, center.y, tailZ - verticalHalfChord * 0.30),
                axis: SIMD3<Float>(0, 1, 0),
                normal: SIMD3<Float>(1, 0, 0),
                length: size.y * 0.5,
                count: shortMemberStationCount,
                crossSection: SIMD2<Float>(1.4 * verticalHalfChord, 2 * max(0.008, size.x * 0.02)),
                parentID: tailRoot,
                legacy: .armRR,
                totalMassWeight: massWeight(for: .verticalTail),
                totalStrengthPerKg: strengthJPerKg(for: .verticalTail),
                loading: { _ in .liftingSurface },
                constantSection: false,
                symmetricFlap: true
            )
            drafts.append(contentsOf: fin.drafts)
            stations.append(contentsOf: fin.stations)
            drafts.append(ComponentDraft(
                kind: .rudder,
                position: SIMD3<Float>(center.x, center.y + size.y * 0.25, tailZ + verticalHalfChord * 0.70),
                halfExtents: SIMD3<Float>(max(0.006, size.x * 0.015), size.y * 0.23, verticalHalfChord * 0.30),
                parentID: fin.drafts.first?.id ?? tailRoot,
                legacy: .armRR
            ))
        }

        // Propulsion from the actual propeller geometry (pusher/tractor and,
        // for hybrid VTOL, the lift rotors as well).
        var usedSlots: Set<String> = []
        var nextExtraSlot = 5
        for (index, prop) in geometry.propellers.enumerated() {
            let isLiftRotor = includeLiftRotors && abs(prop.center.y - center.y) < size.y * 0.5 &&
                abs(prop.center.x - center.x) > size.x * 0.10
            let isWingMounted = abs(prop.center.x - center.x) > size.x * 0.10
            let wingParentID: String? = isWingMounted
                ? drafts.compactMap { draft -> (String, Float)? in
                    guard case .wingSection = draft.kind else { return nil }
                    let delta = simd_abs(prop.center - draft.position) - draft.halfExtents
                    return (draft.id, simd_length(simd_max(delta, .zero)))
                }.min(by: { $0.1 < $1.1 })?.0
                : nil
            let slot: String
            let motorLegacy: DamageComponent?
            let propLegacy: DamageComponent?
            if isLiftRotor {
                let quadrant = quadrantSlot(of: prop.center, center: center, size: size, index: index)
                if usedSlots.contains(quadrant.slot) {
                    while usedSlots.contains("M\(nextExtraSlot)") {
                        nextExtraSlot += 1
                    }
                    slot = "M\(nextExtraSlot)"
                    nextExtraSlot += 1
                } else {
                    slot = quadrant.slot
                }
                motorLegacy = quadrant.motor
                propLegacy = quadrant.propeller
            } else {
                var cruiseSlot = "cruise\(index == 0 ? "" : String(index + 1))"
                var suffix = index + 2
                while usedSlots.contains(cruiseSlot) {
                    cruiseSlot = "cruise\(suffix)"
                    suffix += 1
                }
                slot = cruiseSlot
                // ⚠️ The legacy bucket comes from where the propeller actually is, not
                // from a fixed corner. It used to be hard-coded to .motorFL/.propellerFL,
                // and on a single-engine aeroplane whose propeller sits at the tail that
                // named a bucket holding no geometry at all: when the component detached,
                // `DroneSceneController` found nothing to clone and fell back to a bare
                // box with the red debris material, so a part that was never on the
                // aircraft dropped onto the runway while the real propeller stayed put.
                // The slot name stays "cruise" — that is what the rotor model and the
                // failure runtime key on.
                let quadrant = quadrantSlot(of: prop.center, center: center, size: size, index: index)
                motorLegacy = quadrant.motor
                propLegacy = quadrant.propeller
            }
            usedSlots.insert(slot)
            rotorSlots.append((slot, prop))

            drafts.append(ComponentDraft(
                kind: .motor(slot: slot),
                position: prop.center,
                halfExtents: SIMD3<Float>(repeating: max(0.015, prop.radius * 0.2)),
                parentID: wingParentID ?? fuselage.id,
                legacy: motorLegacy
            ))
            drafts.append(ComponentDraft(
                kind: .propeller(slot: slot),
                position: prop.center,
                halfExtents: SIMD3<Float>(prop.radius, max(0.006, prop.radius * 0.1), prop.radius),
                parentID: ComponentDraft.identifier(for: .motor(slot: slot), suffix: nil),
                legacy: propLegacy
            ))
        }

        drafts.append(ComponentDraft(
            kind: .landingGear(slot: "main"),
            position: SIMD3<Float>(center.x, size.y * 0.05, center.z),
            halfExtents: SIMD3<Float>(size.x * 0.10, max(0.01, size.y * 0.06), size.z * 0.25),
            parentID: fuselage.id,
            legacy: nil
        ))

        return (drafts, rotorSlots, stations)
    }

    // MARK: - Contact profile

    private static func unionBounds(
        of boxes: [DroneVisualGeometryComponentBox]
    ) -> (center: SIMD3<Float>, halfExtents: SIMD3<Float>)? {
        guard !boxes.isEmpty else { return nil }
        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for box in boxes {
            minimum = simd_min(minimum, box.center - box.halfExtents)
            maximum = simd_max(maximum, box.center + box.halfExtents)
        }
        return (
            center: (minimum + maximum) * 0.5,
            halfExtents: simd_max(
                (maximum - minimum) * 0.5,
                SIMD3<Float>(repeating: 0.005)
            )
        )
    }

    private static func contactProfile(
        for profile: DroneModelProfile,
        geometry: DroneVisualGeometrySample,
        drafts: [ComponentDraft]
    ) -> VehicleContactProfile {
        let center = geometry.boundsCenter
        let size = geometry.boundsSize
        let halfSize = size * 0.5
        let boundsMin = center - halfSize
        let boundsMax = center + halfSize
        var spheres: [VehicleContactSphere] = []

        func structuralComponentID(nearest point: SIMD3<Float>) -> String {
            var bestID = drafts.first?.id ?? "frame"
            var bestDistance = Float.greatestFiniteMagnitude
            for draft in drafts where draft.kind.isStructural {
                let delta = simd_abs(point - draft.position) - draft.halfExtents
                let outside = simd_max(delta, SIMD3<Float>(repeating: 0.0))
                let distance = simd_length(outside)
                if distance < bestDistance {
                    bestDistance = distance
                    bestID = draft.id
                }
            }
            return bestID
        }

        func addSphere(
            at point: SIMD3<Float>,
            radius: Float,
            componentID: String? = nil,
            preserveComponentMapping: Bool = false
        ) {
            let clampedRadius = max(0.02, radius)
            // Merge near-duplicates (e.g. a prop sphere landing on a wingtip).
            for existing in spheres where simd_distance(existing.offset, point) < clampedRadius * 0.5 {
                // Propulsion contacts are added first. Distinct coaxial or
                // closely spaced units must retain their component mapping;
                // optional structural samples may share either one sphere.
                if !preserveComponentMapping || existing.componentID == componentID {
                    return
                }
            }
            spheres.append(
                VehicleContactSphere(
                    componentID: componentID ?? structuralComponentID(nearest: point),
                    offset: point,
                    radius: clampedRadius
                )
            )
        }

        // Propeller disks (also covers multirotor arm/motor tips) are the
        // critical localized contacts. Add every mapped propulsion unit
        // before optional body samples so a static cap can never discard M8
        // on an octocopter or the later lift rotors on a hybrid VTOL.
        let propellerDrafts = drafts.filter {
            if case .propeller = $0.kind { return true }
            return false
        }
        for (index, prop) in geometry.propellers.enumerated() {
            let propID = index < propellerDrafts.count ? propellerDrafts[index].id : nil
            // Approximate the swept disc with a thin five-sphere pattern,
            // not one full-radius ball (which falsely collides a whole rotor
            // radius above/below the actual disc plane).
            let proxyRadius = max(0.02, prop.radius * 0.28)
            let ringRadius = max(0.0, prop.radius * 0.65)
            let isLiftDisc = profile.airframeClass == .multirotor ||
                (profile.airframeClass == .hybridVTOL &&
                    abs(prop.center.x - center.x) > size.x * 0.10)
            let discOffsets: [SIMD3<Float>] = isLiftDisc
                ? [
                    .zero,
                    SIMD3<Float>(ringRadius, 0.0, 0.0),
                    SIMD3<Float>(-ringRadius, 0.0, 0.0),
                    SIMD3<Float>(0.0, 0.0, ringRadius),
                    SIMD3<Float>(0.0, 0.0, -ringRadius)
                ]
                : [
                    .zero,
                    SIMD3<Float>(ringRadius, 0.0, 0.0),
                    SIMD3<Float>(-ringRadius, 0.0, 0.0),
                    SIMD3<Float>(0.0, ringRadius, 0.0),
                    SIMD3<Float>(0.0, -ringRadius, 0.0)
                ]
            for offset in discOffsets {
                addSphere(
                    at: prop.center + offset,
                    radius: proxyRadius,
                    componentID: propID,
                    preserveComponentMapping: true
                )
            }
        }

        // Fixed-wing lifting surfaces need continuous contact coverage, not
        // only one sphere at each visual extremity. Use compact grids across
        // their actual planes. A single bounding sphere would extend far
        // below a thin wing, producing false ground/roof contacts.
        if profile.airframeClass == .fixedWing || profile.airframeClass == .hybridVTOL {
            for draft in drafts {
                switch draft.kind {
                case .wingSection, .horizontalTail, .elevator:
                    addSurfaceContactGrid(
                        draft: draft,
                        primaryAxis: 0,
                        secondaryAxis: 2,
                        thicknessAxis: 1,
                        addSphere: addSphere
                    )
                case .verticalTail, .rudder:
                    addSurfaceContactGrid(
                        draft: draft,
                        primaryAxis: 1,
                        secondaryAxis: 2,
                        thicknessAxis: 0,
                        addSphere: addSphere
                    )
                case .tailSection:
                    let radius = max(
                        0.022,
                        sqrt(
                            draft.halfExtents.x * draft.halfExtents.x +
                            draft.halfExtents.y * draft.halfExtents.y
                        )
                    )
                    let count = min(4, max(1, Int((draft.halfExtents.z / radius).rounded(.up))))
                    let interval = draft.halfExtents.z * 2.0 / Float(count)
                    for index in 0..<count {
                        addSphere(
                            at: draft.position + SIMD3<Float>(
                                0.0,
                                0.0,
                                -draft.halfExtents.z + interval * (Float(index) + 0.5)
                            ),
                            radius: max(radius, interval * 0.52),
                            componentID: draft.id,
                            preserveComponentMapping: true
                        )
                    }
                case .frame, .fuselage, .arm, .motor, .propeller, .battery,
                     .flightController, .esc, .radio, .cameraGimbal,
                     .payloadMount, .landingGear:
                    break
                }
            }
        }
        let criticalSphereCount = spheres.count

        // Core body sphere.
        let bodyRadius = max(0.04, min(halfSize.x, halfSize.y, halfSize.z) * 0.9)
        addSphere(at: center, radius: bodyRadius)

        // Ground rest points: bottoms of the visual at the footprint corners
        // (the visual is ground-lifted, so the bottom sits at y == 0 at rest).
        let restRadius = max(0.02, size.y * 0.10)
        let footprintX = halfSize.x * 0.55
        let footprintZ = halfSize.z * 0.55
        let gearID = drafts.first(where: {
            if case .landingGear = $0.kind { return true }
            return false
        })?.id
        addSphere(
            at: SIMD3<Float>(center.x - footprintX, restRadius, center.z - footprintZ),
            radius: restRadius,
            componentID: gearID
        )
        addSphere(
            at: SIMD3<Float>(center.x + footprintX, restRadius, center.z - footprintZ),
            radius: restRadius,
            componentID: gearID
        )
        addSphere(
            at: SIMD3<Float>(center.x - footprintX, restRadius, center.z + footprintZ),
            radius: restRadius,
            componentID: gearID
        )
        addSphere(
            at: SIMD3<Float>(center.x + footprintX, restRadius, center.z + footprintZ),
            radius: restRadius,
            componentID: gearID
        )

        // Airframe extremities.
        if profile.airframeClass == .fixedWing || profile.airframeClass == .hybridVTOL {
            let wingY = drafts.first(where: {
                if case .wingSection = $0.kind { return true }
                return false
            })?.position.y ?? center.y
            let tipRadius = max(0.03, size.y * 0.12)
            addSphere(at: SIMD3<Float>(boundsMin.x + tipRadius, wingY, center.z), radius: tipRadius)
            addSphere(at: SIMD3<Float>(boundsMax.x - tipRadius, wingY, center.z), radius: tipRadius)
            let noseRadius = max(0.03, min(halfSize.x, halfSize.y) * 0.5)
            addSphere(at: SIMD3<Float>(center.x, center.y, boundsMin.z + noseRadius), radius: noseRadius)
            addSphere(at: SIMD3<Float>(center.x, center.y, boundsMax.z - noseRadius), radius: noseRadius)
        }

        // Bound only the optional body/gear/extremity budget. The total cap is
        // dynamic so every real propulsion contact remains represented while
        // narrow-phase work stays linear in a small constant beyond it.
        let maximumContactSpheres = criticalSphereCount + 12
        if spheres.count > maximumContactSpheres {
            spheres = Array(spheres.prefix(maximumContactSpheres))
        }

        for index in spheres.indices {
            guard let draft = drafts.first(where: { $0.id == spheres[index].componentID }) else { continue }
            switch draft.kind {
            case .landingGear: spheres[index].isGroundSupport = true
            case .tailSection, .horizontalTail, .verticalTail:
                spheres[index].isGroundSupport = profile.airframeStyle == .tailsitterVTOL
            default: break
            }
        }
        var boundingRadius: Float = profile.collisionRadius
        for sphere in spheres {
            boundingRadius = max(boundingRadius, simd_length(sphere.offset) + sphere.radius)
        }

        var contacts = VehicleContactProfile(spheres: spheres, boundingRadius: boundingRadius)
        contacts.referenceGroundOffset = contacts.lowestPointOffset(
            orientation: VehicleContactProfile.restOrientation(for: profile.airframeStyle))
        return contacts
    }

    private static func addSurfaceContactGrid(
        draft: ComponentDraft,
        primaryAxis: Int,
        secondaryAxis: Int,
        thicknessAxis: Int,
        addSphere: (SIMD3<Float>, Float, String?, Bool) -> Void
    ) {
        let primaryHalf = draft.halfExtents[primaryAxis]
        let secondaryHalf = draft.halfExtents[secondaryAxis]
        let thicknessHalf = draft.halfExtents[thicknessAxis]
        let radius = min(
            0.16,
            max(0.022, thicknessHalf * 1.5, min(primaryHalf, secondaryHalf) * 0.30)
        )
        // The cell diagonal must fit inside its contact sphere. A fixed 4×3
        // cap left metre-wide holes on large wings, while even 1.75r spacing
        // leaves gaps at cell corners. Keep coverage at every aircraft scale.
        let preferredSpacing = radius * 1.35
        let primaryCount = max(1, Int((primaryHalf * 2.0 / preferredSpacing).rounded(.up)))
        let secondaryCount = max(1, Int((secondaryHalf * 2.0 / preferredSpacing).rounded(.up)))
        let primaryInterval = primaryHalf * 2.0 / Float(primaryCount)
        let secondaryInterval = secondaryHalf * 2.0 / Float(secondaryCount)

        for primaryIndex in 0..<primaryCount {
            for secondaryIndex in 0..<secondaryCount {
                var point = draft.position
                point[primaryAxis] += -primaryHalf +
                    primaryInterval * (Float(primaryIndex) + 0.5)
                point[secondaryAxis] += -secondaryHalf +
                    secondaryInterval * (Float(secondaryIndex) + 0.5)
                addSphere(point, radius, draft.id, true)
            }
        }
    }
}
