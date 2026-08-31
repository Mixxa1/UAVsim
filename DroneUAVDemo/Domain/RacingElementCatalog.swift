import Foundation
import simd

// MARK: - Element role

/// What a track element *does*, as opposed to what it looks like.
enum RacingElementRole: String, Codable, Hashable {
    /// Scored gate flown through horizontally; the pass plane is vertical.
    case gate
    /// Scored gate flown through vertically (a tower/chimney); the pass plane is horizontal.
    case verticalGate
    /// Start/finish pad — a launch mat, not something you fly through.
    case startPad
    /// Scenery: flags, slalom walls, markers. Placeable, never scored.
    case decor

    var isScorable: Bool { self == .gate || self == .verticalGate }
}

/// Which model-space axis the pilot flies along. The racing pack is authored Y-up with the
/// gate ring lying in the model's ZY plane, so nearly everything passes along model X; the
/// tower is the exception (vertical), and the open cube is authored along model Z.
enum RacingModelPassAxis: String, Codable, Hashable {
    case modelX
    case modelY
    case modelZ
}

// MARK: - Aperture

/// One way through a piece of equipment.
///
/// Expressed in the loader's normalised node frame (origin on the ground, +Z the primary
/// direction of travel, +Y up) at unit scale. Several pieces have more than one honest way
/// through them — an open cube can be taken on any of its three axes, a tower through the top or
/// either of its side windows — and which one a track uses is the designer's choice, not the
/// model's.
struct RacingElementAperture: Identifiable, Hashable {
    let id: String
    let titleKey: String
    let centre: SIMD3<Float>
    /// Unit normal: the direction a correct pass travels in.
    let normal: SIMD3<Float>
    /// In-plane axes of the opening.
    let lateral: SIMD3<Float>
    let vertical: SIMD3<Float>
    /// Half-extents along `lateral` and `vertical`.
    let halfExtents: SIMD2<Float>
    /// A tube taken vertically: either direction counts, and the HUD words it differently.
    var isVertical: Bool { abs(normal.y) > 0.5 }
}

// MARK: - Descriptor

/// One placeable piece of racing equipment.
///
/// All geometry figures are in metres, in **node space** — the frame `RacingEquipmentAssetLoader`
/// normalises every model into: origin on the ground under the element's centre, +Z pointing the
/// way the pilot flies through it, +Y up. Everything downstream (editor placement, pass
/// detection, HUD arrows) can therefore treat elements uniformly and never touch model space.
///
/// The aperture figures were measured off the meshes themselves, not eyeballed: a slab of rays
/// is cast through each model on every axis and the largest enclosed free region is taken as the
/// opening (see the aperture probe in the racing increment's notes). For the four open-bottomed
/// pieces — the arches and the two gates whose opening runs into their base plate — no *enclosed*
/// region exists by construction, and their figures come from the model's own bounding box
/// instead, deliberately on the conservative side.
struct RacingElementDescriptor: Identifiable, Hashable {
    let id: String
    let resourceName: String
    let role: RacingElementRole
    let titleKey: String
    let iconSystemName: String
    let passAxis: RacingModelPassAxis
    /// Bounding box at unit scale: (lateral, height, depth-along-pass).
    let sizeMeters: SIMD3<Float>
    /// Height of the aperture centre above the element's base.
    let apertureHeightMeters: Float
    /// Aperture half-extents: (lateral, vertical) for a gate, (lateral, lateral) for a tower.
    let apertureHalfExtents: SIMD2<Float>
    /// Lateral shift of the aperture centre away from the element's own centre line.
    let apertureLateralOffsetMeters: Float
    /// Further ways through this piece, beyond the primary one. Measured off the meshes.
    var extraApertures: [RacingElementAperture] = []

    /// Aperture centre in node space at unit scale.
    var apertureCentreMeters: SIMD3<Float> {
        SIMD3<Float>(apertureLateralOffsetMeters, apertureHeightMeters, 0.0)
    }

    /// The default way through: straight along +Z for a gate, down through the top for a tower.
    var primaryAperture: RacingElementAperture {
        let isTower = role == .verticalGate
        return RacingElementAperture(
            id: "primary",
            titleKey: isTower ? "race.aperture.top" : "race.aperture.front",
            centre: apertureCentreMeters,
            normal: isTower ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1),
            lateral: SIMD3<Float>(1, 0, 0),
            vertical: isTower ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0),
            halfExtents: apertureHalfExtents
        )
    }

    /// Every way through this piece, primary first.
    var apertures: [RacingElementAperture] {
        [primaryAperture] + extraApertures
    }

    func aperture(at index: Int) -> RacingElementAperture {
        let all = apertures
        guard index > 0, index < all.count else { return all[0] }
        return all[index]
    }

    /// Radius that comfortably contains the element, for editor spacing and overlap checks.
    var footprintRadiusMeters: Float {
        max(sizeMeters.x, sizeMeters.z) * 0.5
    }
}

// MARK: - Catalog

/// The sixteen pieces of `Drone racing equipment` (cityon360, CC-BY), split into individually
/// placeable elements.
enum RacingElementCatalog {
    static let all: [RacingElementDescriptor] = [
        RacingElementDescriptor(
            id: "gate_square",
            resourceName: "Gate_Square",
            role: .gate,
            titleKey: "race.element.gate_square",
            iconSystemName: "square",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(2.52, 2.43, 0.82),
            apertureHeightMeters: 1.22,
            apertureHalfExtents: SIMD2<Float>(1.00, 0.97),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_square_large",
            resourceName: "Gate_Square_Large",
            role: .gate,
            titleKey: "race.element.gate_square_large",
            iconSystemName: "square.dashed",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(4.93, 3.00, 1.99),
            apertureHeightMeters: 1.50,
            apertureHalfExtents: SIMD2<Float>(1.11, 1.16),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_square_banner",
            resourceName: "Gate_Square_Banner",
            role: .gate,
            titleKey: "race.element.gate_square_banner",
            iconSystemName: "rectangle.portrait",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(2.60, 2.46, 1.00),
            apertureHeightMeters: 1.27,
            apertureHalfExtents: SIMD2<Float>(0.92, 0.88),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_hexagon",
            resourceName: "Gate_Hexagon",
            role: .gate,
            titleKey: "race.element.gate_hexagon",
            iconSystemName: "hexagon",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(3.26, 2.68, 1.81),
            apertureHeightMeters: 1.37,
            apertureHalfExtents: SIMD2<Float>(1.13, 1.01),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_pentagon",
            resourceName: "Gate_Pentagon",
            role: .gate,
            titleKey: "race.element.gate_pentagon",
            iconSystemName: "pentagon",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(3.39, 3.00, 1.37),
            apertureHeightMeters: 1.47,
            apertureHalfExtents: SIMD2<Float>(1.25, 1.13),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_pentagon_cluster",
            resourceName: "Gate_Pentagon_Cluster",
            role: .gate,
            titleKey: "race.element.gate_pentagon_cluster",
            iconSystemName: "circle.hexagongrid",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(4.16, 3.00, 0.84),
            // Three pentagons in a cluster. Any of them is a real line through the piece, so all
            // three are offered; the upper one is the default because it is the one a pilot sees
            // first on the approach.
            apertureHeightMeters: 2.05,
            apertureHalfExtents: SIMD2<Float>(0.71, 0.70),
            apertureLateralOffsetMeters: 0.0,
            extraApertures: [
                RacingElementAperture(
                    id: "lower_left",
                    titleKey: "race.aperture.lower_left",
                    centre: SIMD3<Float>(-1.06, 0.92, 0.0),
                    normal: SIMD3<Float>(0, 0, 1),
                    lateral: SIMD3<Float>(1, 0, 0),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(0.76, 0.66)
                ),
                RacingElementAperture(
                    id: "lower_right",
                    titleKey: "race.aperture.lower_right",
                    centre: SIMD3<Float>(1.02, 0.92, 0.0),
                    normal: SIMD3<Float>(0, 0, 1),
                    lateral: SIMD3<Float>(1, 0, 0),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(0.71, 0.66)
                )
            ]
        ),
        RacingElementDescriptor(
            id: "gate_arch",
            resourceName: "Gate_Arch",
            role: .gate,
            titleKey: "race.element.gate_arch",
            iconSystemName: "arrow.up.and.down.circle",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(2.53, 1.46, 0.82),
            apertureHeightMeters: 0.62,
            apertureHalfExtents: SIMD2<Float>(0.95, 0.60),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_arch_base",
            resourceName: "Gate_Arch_Base",
            role: .gate,
            titleKey: "race.element.gate_arch_base",
            iconSystemName: "arrow.up.and.down.square",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(2.59, 1.48, 1.00),
            apertureHeightMeters: 0.62,
            apertureHalfExtents: SIMD2<Float>(1.00, 0.55),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "gate_cube",
            resourceName: "Gate_Cube",
            role: .gate,
            titleKey: "race.element.gate_cube",
            iconSystemName: "cube",
            passAxis: .modelZ,
            sizeMeters: SIMD3<Float>(3.00, 3.00, 3.00),
            apertureHeightMeters: 1.50,
            apertureHalfExtents: SIMD2<Float>(1.39, 1.39),
            apertureLateralOffsetMeters: 0.0,
            // An open cube is open on every axis; which pair of faces a track uses is the
            // designer's decision. Measured: the front/back opening is the full 2.78 m, the two
            // cross-axes are slightly narrower where the frame's corner posts intrude.
            extraApertures: [
                RacingElementAperture(
                    id: "across",
                    titleKey: "race.aperture.side",
                    centre: SIMD3<Float>(0.0, 1.50, 0.0),
                    normal: SIMD3<Float>(1, 0, 0),
                    lateral: SIMD3<Float>(0, 0, 1),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(1.17, 1.17)
                ),
                RacingElementAperture(
                    id: "vertical",
                    titleKey: "race.aperture.top",
                    centre: SIMD3<Float>(0.0, 1.50, 0.0),
                    normal: SIMD3<Float>(0, 1, 0),
                    lateral: SIMD3<Float>(1, 0, 0),
                    vertical: SIMD3<Float>(0, 0, 1),
                    halfExtents: SIMD2<Float>(1.17, 1.17)
                )
            ]
        ),
        RacingElementDescriptor(
            id: "gate_tower",
            resourceName: "Gate_Tower",
            role: .verticalGate,
            titleKey: "race.element.gate_tower",
            iconSystemName: "arrow.down.to.line",
            passAxis: .modelY,
            sizeMeters: SIMD3<Float>(1.51, 3.00, 1.51),
            apertureHeightMeters: 1.50,
            apertureHalfExtents: SIMD2<Float>(0.70, 0.70),
            apertureLateralOffsetMeters: 0.0,
            // The tower is an open two-storey frame, so besides the chimney it has four windows:
            // an upper and a lower one on each horizontal axis. Measured at 0.77 m and 2.24 m.
            extraApertures: [
                RacingElementAperture(
                    id: "window_low_front",
                    titleKey: "race.aperture.window_low",
                    centre: SIMD3<Float>(0.0, 0.77, 0.0),
                    normal: SIMD3<Float>(0, 0, 1),
                    lateral: SIMD3<Float>(1, 0, 0),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(0.59, 0.59)
                ),
                RacingElementAperture(
                    id: "window_high_front",
                    titleKey: "race.aperture.window_high",
                    centre: SIMD3<Float>(0.0, 2.24, 0.0),
                    normal: SIMD3<Float>(0, 0, 1),
                    lateral: SIMD3<Float>(1, 0, 0),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(0.59, 0.59)
                ),
                RacingElementAperture(
                    id: "window_low_side",
                    titleKey: "race.aperture.window_low_side",
                    centre: SIMD3<Float>(0.0, 0.77, 0.0),
                    normal: SIMD3<Float>(1, 0, 0),
                    lateral: SIMD3<Float>(0, 0, 1),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(0.59, 0.59)
                ),
                RacingElementAperture(
                    id: "window_high_side",
                    titleKey: "race.aperture.window_high_side",
                    centre: SIMD3<Float>(0.0, 2.24, 0.0),
                    normal: SIMD3<Float>(1, 0, 0),
                    lateral: SIMD3<Float>(0, 0, 1),
                    vertical: SIMD3<Float>(0, 1, 0),
                    halfExtents: SIMD2<Float>(0.59, 0.59)
                )
            ]
        ),
        RacingElementDescriptor(
            id: "start_pad",
            resourceName: "Pad_Start",
            role: .startPad,
            titleKey: "race.element.start_pad",
            iconSystemName: "flag.checkered",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(2.06, 0.01, 1.06),
            apertureHeightMeters: 0.0,
            apertureHalfExtents: SIMD2<Float>(1.03, 0.53),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "slalom_wall",
            resourceName: "Gate_Slalom_Wall",
            role: .decor,
            titleKey: "race.element.slalom_wall",
            iconSystemName: "square.grid.3x1.below.line.grid.1x2",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(3.02, 3.00, 4.29),
            apertureHeightMeters: 1.56,
            apertureHalfExtents: SIMD2<Float>(0.68, 0.70),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "flag_feather",
            resourceName: "Flag_Feather",
            role: .decor,
            titleKey: "race.element.flag_feather",
            iconSystemName: "flag",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(1.00, 2.39, 1.00),
            apertureHeightMeters: 0.0,
            apertureHalfExtents: SIMD2<Float>(0.5, 0.5),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "flag_drop",
            resourceName: "Flag_Drop",
            role: .decor,
            titleKey: "race.element.flag_drop",
            iconSystemName: "flag.fill",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(1.01, 2.47, 1.20),
            apertureHeightMeters: 0.0,
            apertureHalfExtents: SIMD2<Float>(0.5, 0.5),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "flag_sail",
            resourceName: "Flag_Sail",
            role: .decor,
            titleKey: "race.element.flag_sail",
            iconSystemName: "flag.slash",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(1.00, 2.51, 1.00),
            apertureHeightMeters: 0.0,
            apertureHalfExtents: SIMD2<Float>(0.5, 0.5),
            apertureLateralOffsetMeters: 0.0
        ),
        RacingElementDescriptor(
            id: "flag_blade",
            resourceName: "Flag_Blade",
            role: .decor,
            titleKey: "race.element.flag_blade",
            iconSystemName: "flag.2.crossed",
            passAxis: .modelX,
            sizeMeters: SIMD3<Float>(1.00, 2.46, 1.34),
            apertureHeightMeters: 0.0,
            apertureHalfExtents: SIMD2<Float>(0.5, 0.5),
            apertureLateralOffsetMeters: 0.0
        )
    ]

    static func descriptor(id: String) -> RacingElementDescriptor? {
        all.first { $0.id == id }
    }

    static var gates: [RacingElementDescriptor] {
        all.filter { $0.role.isScorable }
    }

    static var decorations: [RacingElementDescriptor] {
        all.filter { $0.role == .decor }
    }

    static var startPad: RacingElementDescriptor? {
        all.first { $0.role == .startPad }
    }
}
