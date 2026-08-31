import Foundation
import simd

// MARK: - Placed element

/// One piece of equipment placed on a track.
///
/// `position` is the world point the element's base sits on, matching the frame
/// `RacingEquipmentAssetLoader` normalises every model into (origin on the ground, +Z the way the
/// pilot flies through). A gate raised off the ground — a hoop to dive through, a tower on a
/// hill — carries that in `position.y`.
struct RaceTrackElement: Identifiable, Codable, Hashable {
    var id: UUID
    var catalogID: String
    var position: SIMD3<Float>
    var yawRadians: Float
    var scale: Float
    /// Place in the racing line, 0-based. `nil` for scenery and the start pad: the pilot never
    /// has to fly through those, and numbering them would make the line ambiguous.
    var gateOrder: Int?
    /// Which of the element's openings this placement uses (index into `descriptor.apertures`).
    var apertureIndex: Int

    init(
        id: UUID = UUID(),
        catalogID: String,
        position: SIMD3<Float>,
        yawRadians: Float = 0.0,
        scale: Float = 1.0,
        gateOrder: Int? = nil,
        apertureIndex: Int = 0
    ) {
        self.id = id
        self.catalogID = catalogID
        self.position = position
        self.yawRadians = yawRadians
        self.scale = scale
        self.gateOrder = gateOrder
        self.apertureIndex = apertureIndex
    }

    /// Hand-written so tracks saved before passages existed still load — a missing key means the
    /// element uses its primary opening, which is what those tracks were flown with.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        catalogID = try container.decode(String.self, forKey: .catalogID)
        position = try container.decode(SIMD3<Float>.self, forKey: .position)
        yawRadians = try container.decode(Float.self, forKey: .yawRadians)
        scale = try container.decode(Float.self, forKey: .scale)
        gateOrder = try container.decodeIfPresent(Int.self, forKey: .gateOrder)
        apertureIndex = try container.decodeIfPresent(Int.self, forKey: .apertureIndex) ?? 0
    }

    /// The opening this placement is flown through.
    var aperture: RacingElementAperture? {
        descriptor?.aperture(at: apertureIndex)
    }

    var descriptor: RacingElementDescriptor? {
        RacingElementCatalog.descriptor(id: catalogID)
    }

    var isScorable: Bool {
        gateOrder != nil && (descriptor?.role.isScorable ?? false)
    }
}

// MARK: - Track

/// A complete track: the equipment, the racing line implied by the gate numbering, and whatever
/// personal best has been flown on it.
struct RaceTrack: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var elements: [RaceTrackElement]
    var laps: Int
    var createdAt: Date
    var updatedAt: Date
    var bestLapSeconds: Double?
    var bestTotalSeconds: Double?
    /// Set when the track came out of the generator rather than the editor, so the UI can say so.
    var isGenerated: Bool

    init(
        id: UUID = UUID(),
        name: String,
        elements: [RaceTrackElement] = [],
        laps: Int = 3,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        bestLapSeconds: Double? = nil,
        bestTotalSeconds: Double? = nil,
        isGenerated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.elements = elements
        self.laps = max(1, laps)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.bestLapSeconds = bestLapSeconds
        self.bestTotalSeconds = bestTotalSeconds
        self.isGenerated = isGenerated
    }

    /// Gates in racing order. Numbering gaps are tolerated — the editor lets a gate be deleted out
    /// of the middle, and renumbering everything behind it would be a surprise, so order is by
    /// value rather than by index.
    var orderedGates: [RaceTrackElement] {
        elements
            .filter { $0.isScorable }
            .sorted { ($0.gateOrder ?? 0) < ($1.gateOrder ?? 0) }
    }

    var gateCount: Int { orderedGates.count }

    var startPad: RaceTrackElement? {
        elements.first { $0.descriptor?.role == .startPad }
    }

    /// A track needs at least two gates to define a direction of travel, and a lap needs to close
    /// back onto the first gate.
    var isFlyable: Bool { gateCount >= 2 }

    /// Where the aircraft is put down before the race: the start pad if one was placed, otherwise
    /// backed off behind the first gate along its approach.
    var spawnPosition: SIMD3<Float>? {
        if let pad = startPad {
            return pad.position
        }
        guard let first = orderedGates.first, let descriptor = first.descriptor else { return nil }
        let normal = SIMD3<Float>(sin(first.yawRadians), 0, cos(first.yawRadians))
        let backOff = max(8.0, descriptor.sizeMeters.z * 3.0)
        return first.position - normal * backOff
    }

    /// Heading the aircraft faces on the pad: straight at the first gate.
    var spawnYawRadians: Float {
        guard let first = orderedGates.first, let spawn = spawnPosition else { return 0.0 }
        let delta = first.position - spawn
        return atan2(delta.x, delta.z)
    }

    /// Total length of the racing line, gate to gate and back to the first — the honest "how big
    /// is this track" number for the picker.
    var lapLengthMeters: Float {
        let gates = orderedGates
        guard gates.count >= 2 else { return 0.0 }
        var length: Float = 0.0
        for index in gates.indices {
            let next = gates[(index + 1) % gates.count]
            length += simd_distance(gates[index].position, next.position)
        }
        return length
    }
}

// MARK: - Race settings

/// How a race is flown.
enum RaceMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// Ordered gates, laps, a clock and a personal best.
    case timed
    /// The track is there to fly; gates still light up as they are taken, nothing is scored.
    case free

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .timed:
            return "race.mode.timed"
        case .free:
            return "race.mode.free"
        }
    }

    var subtitleKey: String {
        switch self {
        case .timed:
            return "race.mode.timed.subtitle"
        case .free:
            return "race.mode.free.subtitle"
        }
    }

    var iconSystemName: String {
        switch self {
        case .timed:
            return "stopwatch"
        case .free:
            return "infinity"
        }
    }
}

// MARK: - Runtime gate geometry

/// A gate's aperture in world space, handed from the scene layer to the runtime.
///
/// The runtime deliberately never touches SceneKit: it is given the plane (centre + normal), the
/// two in-plane axes, and the half-extents, and everything it decides follows from those.
struct RaceGateGeometry: Equatable {
    var elementID: UUID
    var order: Int
    var centre: SIMD3<Float>
    /// Unit normal — the direction a correct pass travels in.
    var normal: SIMD3<Float>
    /// In-plane axes: `lateral` across the opening, `vertical` up it.
    var lateral: SIMD3<Float>
    var vertical: SIMD3<Float>
    var halfWidth: Float
    var halfHeight: Float
    /// A tower flown through vertically; its plane is horizontal, which only matters for the HUD
    /// wording and the approach arrow, not for the crossing maths.
    var isVertical: Bool

    /// Turns a placed element into the world-space plane the runtime scores against.
    ///
    /// This is pure geometry, so it lives here rather than in the scene layer: the conversion is
    /// the single place where the loader's normalised frame (+Z through the gate, +X across the
    /// opening, +Y up, origin on the ground) is interpreted, and it has to be checkable without
    /// a renderer.
    static func make(from element: RaceTrackElement) -> RaceGateGeometry? {
        guard let descriptor = element.descriptor,
              let order = element.gateOrder,
              descriptor.role.isScorable else {
            return nil
        }
        let scale = max(0.05, element.scale)
        let cosYaw = cos(element.yawRadians)
        let sinYaw = sin(element.yawRadians)

        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(
                v.x * cosYaw + v.z * sinYaw,
                v.y,
                -v.x * sinYaw + v.z * cosYaw
            )
        }

        // Whichever opening this placement was set to — the front of a gate, one pentagon of a
        // cluster, a side window of a tower — carries its own plane and axes with it.
        let aperture = descriptor.aperture(at: element.apertureIndex)
        return RaceGateGeometry(
            elementID: element.id,
            order: order,
            centre: element.position + rotate(aperture.centre * scale),
            normal: rotate(aperture.normal),
            lateral: rotate(aperture.lateral),
            vertical: rotate(aperture.vertical),
            halfWidth: aperture.halfExtents.x * scale,
            halfHeight: aperture.halfExtents.y * scale,
            isVertical: aperture.isVertical
        )
    }
}

extension RaceTrack {
    /// Every scorable gate on this track as a world-space plane, in racing order.
    var gateGeometry: [RaceGateGeometry] {
        orderedGates.compactMap(RaceGateGeometry.make(from:))
    }
}

// MARK: - Collision shape

/// One solid box of a placed element, in the element's own frame (+Z through the gate, +Y up,
/// origin on the ground).
struct RaceElementCollisionBox: Equatable {
    var localCenter: SIMD3<Float>
    var size: SIMD3<Float>
}

extension RaceTrackElement {
    /// The element's solid parts, scaled and positioned for this placement.
    ///
    /// The shape itself comes from the mesh (`RacingEquipmentAssetLoader.collisionBoxes`), because
    /// a gate is a thin frame around a large hole and nothing about that can be inferred from a
    /// bounding box. This only applies the instance's own size.
    func collisionBoxes(from prototype: [RaceElementCollisionBox]) -> [RaceElementCollisionBox] {
        let scale = max(0.05, self.scale)
        guard scale != 1.0 else { return prototype }
        return prototype.map { box in
            RaceElementCollisionBox(
                localCenter: box.localCenter * scale,
                size: box.size * scale
            )
        }
    }
}

// MARK: - Gate visual state

/// What a gate should look like right now. Colours live in `RacingMaterialPalette`.
enum RaceGateVisualState: String, Equatable {
    case idle
    case next
    case passed
    case wrongWay
}

// MARK: - Race events + outcome

enum RaceEvent: Equatable {
    case gatePassed(order: Int, elapsed: Double)
    case gateWrongWay(order: Int)
    case lapCompleted(lap: Int, lapSeconds: Double, isBestLap: Bool)
    case raceFinished(totalSeconds: Double, bestLapSeconds: Double)
    case countdownTick(secondsRemaining: Int)
    case started
}

enum RaceObjectiveState: String, Equatable {
    case countdown
    case armed
    case racing
    case finished
}
