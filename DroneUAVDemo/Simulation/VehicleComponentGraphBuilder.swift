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
        case .horizontalTail, .verticalTail: return 25.0
        case .flightController, .radio: return 30.0
        case .arm: return 30.0
        case .esc, .payloadMount: return 35.0
        case .landingGear: return 40.0
        case .motor, .battery: return 45.0
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
        case .horizontalTail: return 0.045
        case .verticalTail: return 0.035
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
        case .wingSection(_, .outer), .horizontalTail, .verticalTail:
            return [.efficiencyLoss, .jam, .holdLastCommand, .totalFailure]
        case .wingSection(_, .root), .arm, .frame, .fuselage, .landingGear, .payloadMount:
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

        var drafts: [ComponentDraft]
        let rotorSlots: [RotorSlotPair]
        switch profile.airframeClass {
        case .multirotor:
            (drafts, rotorSlots) = multirotorDrafts(geometry: geometry)
        case .fixedWing:
            (drafts, rotorSlots) = fixedWingDrafts(geometry: geometry, includeLiftRotors: false, profile: profile)
        case .hybridVTOL:
            (drafts, rotorSlots) = fixedWingDrafts(geometry: geometry, includeLiftRotors: true, profile: profile)
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
        // (known-real) mass, preserving the weight ratios.
        let weightedDrafts = drafts.filter { $0.fixedMass == nil }
        let totalWeight = weightedDrafts.reduce(Float(0.0)) { $0 + massWeight(for: $1.kind) }
        let massPerWeight = structuralBudget / max(0.0001, totalWeight)

        var components: [VehicleComponent] = []
        components.reserveCapacity(drafts.count)
        let strengthReferenceMass = max(0.20, totalMass - payloadMass)
        for draft in drafts {
            let mass = draft.fixedMass ?? massWeight(for: draft.kind) * massPerWeight
            components.append(
                VehicleComponent(
                    id: draft.id,
                    kind: draft.kind,
                    parentID: draft.parentID,
                    massKg: max(0.001, mass),
                    localPosition: draft.position,
                    boundingHalfExtents: simd_max(draft.halfExtents, SIMD3<Float>(repeating: 0.005)),
                    strengthJ: strengthJPerKg(for: draft.kind) * strengthReferenceMass,
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

        let graph = VehicleComponentGraph(components: components)
        let contactProfile = contactProfile(
            for: profile,
            geometry: geometry,
            drafts: drafts
        )
        return Output(
            graph: graph,
            contactProfile: contactProfile,
            rotorModel: rotorModel(from: rotorSlots, massProperties: graph.massProperties)
        )
    }

    private static func rotorModel(
        from rotorSlots: [RotorSlotPair],
        massProperties: VehicleMassProperties
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
        return VehicleRotorModel(rotors: rotors, torqueToThrustRatio: kappa)
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

        init(
            kind: VehicleComponentKind,
            position: SIMD3<Float>,
            halfExtents: SIMD3<Float>,
            parentID: String?,
            legacy: DamageComponent?,
            fixedMass: Float? = nil,
            idSuffix: String? = nil
        ) {
            self.kind = kind
            self.position = position
            self.halfExtents = halfExtents
            self.parentID = parentID
            self.legacy = legacy
            self.fixedMass = fixedMass
            self.id = Self.identifier(for: kind, suffix: idSuffix)
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
            case .horizontalTail: base = "tail.horizontal"
            case .verticalTail: base = "tail.vertical"
            case .landingGear(let slot): base = "gear.\(slot)"
            }
            if let suffix { return "\(base).\(suffix)" }
            return base
        }
    }

    /// Quadrant naming in the physics body frame: nose toward -Z, +X right.
    private static func quadrantSlot(
        of position: SIMD3<Float>,
        center: SIMD3<Float>,
        index: Int
    ) -> (slot: String, motor: DamageComponent, propeller: DamageComponent, arm: DamageComponent) {
        let front = position.z < center.z
        let left = position.x < center.x
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
    ) -> (drafts: [ComponentDraft], rotorSlots: [RotorSlotPair]) {
        let center = geometry.boundsCenter
        let size = geometry.boundsSize
        var drafts: [ComponentDraft] = []
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
            var quadrant = quadrantSlot(of: prop.center, center: center, index: index)
            if usedSlots.contains(quadrant.slot) {
                while usedSlots.contains("M\(nextExtraSlot)") {
                    nextExtraSlot += 1
                }
                quadrant = ("M\(nextExtraSlot)", quadrant.motor, quadrant.propeller, quadrant.arm)
                nextExtraSlot += 1
            }
            usedSlots.insert(quadrant.slot)
            rotorSlots.append((quadrant.slot, prop))

            let armVector = prop.center - center
            let armMid = center + armVector * 0.55
            drafts.append(ComponentDraft(
                kind: .arm(slot: quadrant.slot),
                position: SIMD3<Float>(armMid.x, prop.center.y - 0.01, armMid.z),
                halfExtents: SIMD3<Float>(
                    max(0.01, abs(armVector.x) * 0.5),
                    max(0.008, size.y * 0.06),
                    max(0.01, abs(armVector.z) * 0.5)
                ),
                parentID: frame.id,
                legacy: quadrant.arm
            ))
            drafts.append(ComponentDraft(
                kind: .motor(slot: quadrant.slot),
                position: prop.center - SIMD3<Float>(0.0, 0.015, 0.0),
                halfExtents: SIMD3<Float>(repeating: max(0.012, prop.radius * 0.18)),
                parentID: ComponentDraft.identifier(for: .arm(slot: quadrant.slot), suffix: nil),
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

        return (drafts, rotorSlots)
    }

    private static func fixedWingDrafts(
        geometry: DroneVisualGeometrySample,
        includeLiftRotors: Bool,
        profile: DroneModelProfile
    ) -> (drafts: [ComponentDraft], rotorSlots: [RotorSlotPair]) {
        let center = geometry.boundsCenter
        let size = geometry.boundsSize
        var drafts: [ComponentDraft] = []
        var rotorSlots: [RotorSlotPair] = []

        let fuselage = ComponentDraft(
            kind: .fuselage,
            position: center,
            halfExtents: SIMD3<Float>(
                max(0.03, size.x * 0.07),
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
        let wingCenter = wingBounds?.center ?? center
        let wingHalfSpan = wingBounds?.halfExtents.x ?? size.x * 0.5
        let wingHalfChord = max(0.03, wingBounds?.halfExtents.z ?? size.z * 0.16)
        let wingHalfThickness = max(0.008, wingBounds?.halfExtents.y ?? size.y * 0.06)

        for side in [VehicleBodySide.left, .right] {
            let sign: Float = side == .left ? -1.0 : 1.0
            let rootCenter = SIMD3<Float>(
                wingCenter.x + sign * wingHalfSpan * 0.25,
                wingCenter.y,
                wingCenter.z
            )
            let outerCenter = SIMD3<Float>(
                wingCenter.x + sign * wingHalfSpan * 0.75,
                wingCenter.y,
                wingCenter.z
            )
            let sectionHalf = SIMD3<Float>(wingHalfSpan * 0.25, wingHalfThickness, wingHalfChord)
            let legacy: DamageComponent = side == .left ? .armFL : .armFR
            let root = ComponentDraft(
                kind: .wingSection(side: side, segment: .root),
                position: rootCenter,
                halfExtents: sectionHalf,
                parentID: fuselage.id,
                legacy: legacy
            )
            drafts.append(root)
            drafts.append(ComponentDraft(
                kind: .wingSection(side: side, segment: .outer),
                position: outerCenter,
                halfExtents: sectionHalf,
                parentID: root.id,
                legacy: legacy
            ))
        }

        // Tail group at the rear extreme (+Z in the body frame — nose is -Z).
        let tailZ = center.z + size.z * 0.42
        drafts.append(ComponentDraft(
            kind: .horizontalTail,
            position: SIMD3<Float>(center.x, center.y, tailZ),
            halfExtents: SIMD3<Float>(size.x * 0.18, max(0.008, size.y * 0.05), max(0.03, size.z * 0.08)),
            parentID: fuselage.id,
            legacy: .armRL
        ))
        drafts.append(ComponentDraft(
            kind: .verticalTail,
            position: SIMD3<Float>(center.x, center.y + size.y * 0.25, tailZ),
            halfExtents: SIMD3<Float>(max(0.008, size.x * 0.02), size.y * 0.25, max(0.03, size.z * 0.08)),
            parentID: fuselage.id,
            legacy: .armRR
        ))

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
                let quadrant = quadrantSlot(of: prop.center, center: center, index: index)
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
                motorLegacy = .motorFL
                propLegacy = .propellerFL
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

        return (drafts, rotorSlots)
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

        var boundingRadius: Float = profile.collisionRadius
        for sphere in spheres {
            boundingRadius = max(boundingRadius, simd_length(sphere.offset) + sphere.radius)
        }

        return VehicleContactProfile(spheres: spheres, boundingRadius: boundingRadius)
    }
}
