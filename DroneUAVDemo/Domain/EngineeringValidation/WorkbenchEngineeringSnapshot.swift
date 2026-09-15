import CryptoKit
import Foundation

/// Projects a Workbench blueprint onto engineering input categories (spec §3).
///
/// A projection, not a second model: the blueprint stays the one thing the user edits, and
/// this decides which of its fields each calculation reads. Every assignment below is an
/// engineering claim about what a solver depends on, so each non-obvious one says why.
///
/// Deliberately outside every category: name, description, the revision counter, flight
/// controller tuning (rate/expo) and the RF link — none of them enters a strength, mass,
/// propulsion, thermal or aerodynamic calculation.
enum WorkbenchEngineeringSnapshot {
    static func make(
        from build: WorkbenchBuild,
        parentSnapshotID: String? = nil,
        createdAt: Date = Date()
    ) -> EngineeringConfigurationSnapshot {
        let frame = build.resolvedFrame
        let airframe = EngineeringAirframeKind(frame.architecture)
        let layout = WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)
        var categories: [EngineeringInputCategory: [String: EngineeringCanonicalValue]] = [:]
        func put(_ category: EngineeringInputCategory, _ key: String, _ value: EngineeringCanonicalValue) {
            categories[category, default: [:]][key] = value
        }

        // MARK: Frame

        // A library frame's shape is procedural and authored per identifier, so there the
        // identifier *is* the geometry reference. An imported frame is identified by its mesh
        // content alone: re-exporting the same body under a new id changes nothing physical.
        //
        // A frame exported with its exact solids is identified by them instead: the display mesh is
        // derived from the BRep by a mesher whose version may change, and a finer triangulation of the
        // same solid must not outdate its strength result.
        let exactBodies: [WorkbenchConstruction.Body]
        if case let .imported(construction) = build.frame, let bodies = construction.bodies, !bodies.isEmpty {
            exactBodies = bodies.sorted { $0.id < $1.id }
        } else {
            exactBodies = []
        }
        let frameMesh: EngineeringCanonicalValue
        if !exactBodies.isEmpty {
            frameMesh = .array(exactBodies.map { body in
                .object(["id": .string(body.id), "brepSha256": .string(body.geometry.sha256)])
            })
        } else {
            frameMesh = frame.importedMesh.map(meshReference) ?? .string("procedural")
        }
        let frameSource: String
        switch build.frame {
        case let .library(id): frameSource = "library:" + id
        case .imported: frameSource = "cadnext"
        }
        let shape: [String: EngineeringCanonicalValue] = [
            "source": .string(frameSource),
            "mesh": frameMesh,
            "sizeMeters": .vector(frame.sizeMeters),
            "frameClass": .string(frame.frameClass.rawValue),
            "wingAreaM2": .number(frame.wingAreaM2),
            "armLengthM": .number(frame.armLengthM),
            "planform": .string(frame.fixedWingPlanform?.rawValue ?? "none"),
            "inlet": .string(frame.inletType?.rawValue ?? "none"),
        ]
        put(.outerGeometry, "frame", .object(shape))
        put(.structuralGeometry, "frame", .object(shape))
        put(.materials, "frame.skin", .string(frame.skinMaterial?.rawValue ?? "unspecified"))
        // Per solid, so a changed material names the part it changed on.
        for body in exactBodies {
            put(.materials, "frame.body." + body.id, .object([
                "materialId": .string(body.materialId),
                "densityKgPerM3": .number(body.densityKgPerM3),
            ]))
        }

        var frameMass: [String: EngineeringCanonicalValue] = ["massKg": .number(frame.massKg)]
        if case let .imported(construction) = build.frame {
            frameMass["centerOfMass"] = .vector(construction.centerOfMass)
            put(.joints, "frame.attachments", .array(construction.attachmentPoints
                .sorted { $0.id < $1.id }
                .map { point in
                    .object([
                        "id": .string(point.id),
                        "role": .string(point.role),
                        "position": .vector(point.position),
                        "rotation": .vector(point.rotation),
                    ])
                }))
        }
        put(.componentLayout, "frame", .object(frameMass))

        put(.joints, "frame.motorMounts", .object([
            "positions": .array(frame.motorMounts.map { .vector($0) }),
            "axes": .array(frame.propulsionAxes.map { .vector($0) }),
            "liftMotorCount": .number(Double(frame.liftMotorCount)),
        ]))
        put(.joints, "frame.bays", .object([
            "batteryTray": .vector(frame.batteryTray),
            "flightControllerBay": .vector(frame.fcBay),
            "cameraMount": .vector(frame.cameraMount),
        ]))
        // Until CAD defines movable surfaces, the servo stations and the wing they sit in are
        // the only description of the control geometry there is.
        put(.controlSurfaceGeometry, "frame", .object([
            "servoMounts": .array(frame.servoMounts.map { .vector($0) }),
            "wingAreaM2": .number(frame.wingAreaM2),
            "planform": .string(frame.fixedWingPlanform?.rawValue ?? "none"),
        ]))

        // MARK: Components

        for kind in WorkbenchBuild.slotKinds {
            guard let spec = build.spec(for: kind) else { continue }
            let key = kind.rawValue
            let placement = layout[kind]
            let count: Int
            switch kind {
            case .motor, .propeller: count = max(frame.motorMounts.count, 1)
            case .servo: count = max(frame.servoMounts.count, 1)
            default: count = 1
            }
            let partMesh: EngineeringCanonicalValue = spec.importedMesh.map(meshReference) ?? .string("proxy")

            // No catalogue identifiers in physical categories: two parts with the same mass,
            // envelope and parameters are the same part to every solver, and a swap between
            // them must not invalidate anything (spec §10, "battery: model only, same mass").
            // Rotors and control-surface servos are not placed by the layout resolver: they sit
            // at the frame's mounts, one per station, so their mass is distributed there.
            let stations: [SIMD3<Float>]?
            switch kind {
            case .motor, .propeller: stations = frame.motorMounts
            case .servo where !frame.servoMounts.isEmpty:
                stations = WorkbenchBuildAnalyzer.resolvedServoPositions(frame: frame, spec: spec)
            default: stations = nil
            }
            let position: EngineeringCanonicalValue
            if let stations {
                position = .array(stations.map { .vector($0) })
            } else {
                position = placement.map { .vector($0.position) } ?? .string("unplaced")
            }
            put(.componentLayout, key, .object([
                "massKg": .number(spec.massKg),
                "count": .number(Double(count)),
                "position": position,
                "envelope": placement.map { .vector($0.size) } ?? .vector(spec.proxy.size),
                "surface": .string(stations != nil ? "stations" : (placement?.surface.rawValue ?? "unplaced")),
            ]))

            // The unit count is a characteristic, not only a layout fact: the bench draws
            // `count` motors from one pack (sag, total current), and the power budget feeds
            // every servo.
            let characteristics = EngineeringCanonicalValue.object([
                "params": .numbers(spec.params.filter { !envelopeParamKeys.contains($0.key) }),
                "units": .number(Double(count)),
            ])
            switch kind {
            case .motor: put(.motorCharacteristics, key, characteristics)
            case .propeller: put(.propellerCharacteristics, key, characteristics)
            case .battery: put(.batteryElectrical, key, characteristics)
            case .esc: put(.escCharacteristics, key, characteristics)
            case .servo: put(.servoCharacteristics, key, characteristics)
            case .flightController, .receiver, .camera, .gps, .sensor, .payload:
                put(.avionicsAndPayload, key, characteristics)
            case .landingGear:
                put(.structuralGeometry, key, .object([
                    "mesh": partMesh,
                    "envelope": .vector(spec.proxy.size),
                    "params": .numbers(spec.params),
                ]))
            }

            if isWetted(kind: kind, surface: placement?.surface, airframe: airframe) {
                put(.outerGeometry, key, .object([
                    "mesh": partMesh,
                    "shape": .string(spec.proxy.shape.rawValue),
                    "envelope": placement.map { .vector($0.size) } ?? .vector(spec.proxy.size),
                    "position": placement.map { .vector($0.position) } ?? .string("unplaced"),
                ]))
            }
        }

        return EngineeringConfigurationSnapshot(
            schemaVersion: EngineeringConfigurationSnapshot.currentSchemaVersion,
            vehicleID: build.id.uuidString.lowercased(),
            displayName: build.name,
            revision: build.revision,
            parentSnapshotID: parentSnapshotID,
            createdAt: createdAt,
            airframe: airframe,
            frameConvention: .workbenchModel,
            categories: Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value) }))
    }

    /// Battery pack dimensions are its envelope, already carried by the layout. Keeping them
    /// out of `batteryElectrical` is what lets a pack of the same size and chemistry but a
    /// different shape leave the propulsion bench alone.
    private static let envelopeParamKeys: Set<String> = [
        WorkbenchComponentSpec.ParamKey.batteryLengthMm,
        WorkbenchComponentSpec.ParamKey.batteryWidthMm,
        WorkbenchComponentSpec.ParamKey.batteryHeightMm,
    ]

    /// Whether the air sees this part.
    ///
    /// - Motors and propellers: no. The airframe's aerodynamics are computed clean; rotors
    ///   enter through the propulsion bench (spec §10: a propeller or motor change does not
    ///   invalidate CFD).
    /// - Servos: no. They are recessed into pockets at the control-surface stations; only
    ///   flange, horn and pushrod stand above the skin (`resolvedServoPositions`), which is
    ///   below the geometric resolution any airframe CFD mesh here resolves (spec §10: a servo
    ///   change invalidates mechanism, authority and power, not CFD).
    /// - Inside the bay of a lifting airframe: no — it is behind the hatch (spec §10: moving a
    ///   part inside a closed hull keeps CFD valid).
    /// - Inside the "bay" of a multicopter: **yes**. On an open frame that bay is the gap
    ///   between two plates (`WorkbenchMountSurface.internalBay`), in the airstream.
    private static func isWetted(
        kind: WorkbenchComponentKind,
        surface: WorkbenchMountSurface?,
        airframe: EngineeringAirframeKind
    ) -> Bool {
        if kind == .motor || kind == .propeller || kind == .servo { return false }
        if surface == .internalBay && airframe != .multicopter { return false }
        return true
    }

    private static func meshReference(_ mesh: WorkbenchConstruction.Mesh) -> EngineeringCanonicalValue {
        var hasher = SHA256()
        mesh.vertices.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        mesh.indices.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .object([
            "sha256": .string(digest),
            "vertexCount": .number(Double(mesh.vertices.count / 3)),
            "triangleCount": .number(Double(mesh.indices.count / 3)),
        ])
    }
}
