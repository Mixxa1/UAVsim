import Foundation

/// What the aircraft hit, in the terms an impact sound needs.
///
/// Deliberately not `ImpactSurfaceMaterial`. That type describes how a surface *behaves* —
/// restitution, friction, how much energy it swallows — and two materials can behave almost
/// identically and sound nothing alike: wet soil and old snow absorb comparable energy and are
/// not remotely the same noise. Keeping them apart also means a change to how concrete bounces
/// cannot silently change what concrete sounds like.
enum AcousticSurfaceMaterial: String, CaseIterable, Hashable, Codable {
    case concrete
    case asphalt
    case metal
    case glass
    case treeTrunk
    case foliage
    case soil
    case grass
    case snow
    case ice
    case water
    case rock
    /// Worked timber — a crate, a fence, a deck. Not a living trunk, which rings differently.
    case wood
    case generic

    /// Whether this surface can shatter, and therefore whether a hard enough contact should
    /// add a breakage layer on top of the impact.
    var isBrittle: Bool {
        switch self {
        case .glass, .ice: return true
        case .concrete, .asphalt, .metal, .treeTrunk, .foliage, .soil, .grass,
             .snow, .water, .rock, .wood, .generic: return false
        }
    }

    /// Whether sliding along this surface can produce a sustained scrape.
    ///
    /// Water and canopy cannot: there is nothing rigid to drag against. Snow and soil can,
    /// but faintly — the scrape gain law handles that, this only decides whether the loop
    /// exists at all.
    var supportsScrape: Bool {
        switch self {
        case .water, .foliage: return false
        case .concrete, .asphalt, .metal, .glass, .treeTrunk, .soil, .grass,
             .snow, .ice, .rock, .wood, .generic: return true
        }
    }

    var localizationKey: String { "audio.surface.\(rawValue)" }

    /// Last-resort classification from an obstacle's provenance string.
    ///
    /// The real answer comes from whoever built the obstacle — a building collider knows it is
    /// glass, a world runtime knows its triangle is water — and that answer travels on
    /// `CollisionObstacle.acousticSurface`. This is what happens when nobody said: a keyword
    /// match, and the reason five of the eleven physical materials in this project were
    /// unreachable for years is that a keyword match was the *only* mechanism.
    ///
    /// The token list is tuned to the strings this project actually produces —
    /// `ground.field`, `container.wall.left`, `tree.canopy`, `abandonedBuilding.bounds` — and
    /// not to a general vocabulary. Order matters: specific before general.
    static func fromObstacleSource(_ source: String?) -> AcousticSurfaceMaterial {
        guard let source = source?.lowercased() else { return .generic }
        func has(_ needles: String...) -> Bool { needles.contains { source.contains($0) } }

        // Vegetation before anything that could match a generic ground word.
        if has("canopy", "foliage", "leaves", "leaf", "branch", "bush") { return .foliage }
        if has("trunk", "bark") { return .treeTrunk }
        if has("tree", "spruce", "pine") { return .treeTrunk }

        if has("glass", "window", "glazing") { return .glass }
        if has("water", "river", "lake", "sea.", "ocean", "pond") { return .water }
        if has("snow") { return .snow }
        if has("ice", "frost") { return .ice }
        if has("asphalt", "runway", "road", "tarmac", "pavement", "street") { return .asphalt }
        if has("rock", "boulder", "stone", "cliff") { return .rock }
        if has("crate", "pallet", "plank", "timber") { return .wood }
        // Containers, poles, trucks and vehicles are the project's metal objects.
        if has("container", "truck", "vehicle", "metal", "pole", "pylon", "antenna", "mast") { return .metal }
        if has("building", "wall", "facade", "structure", "concrete", "brick", "house", "roof") { return .concrete }
        if has("sand", "dirt", "soil", "mud") { return .soil }
        if has("grass", "meadow", "lawn", "turf") { return .grass }
        if has("ground", "terrain") { return .soil }
        return .generic
    }

    /// What a catalogued environment object is made of.
    ///
    /// The scene builds these from a known kind, so this is real provenance rather than a
    /// guess — a cargo container is steel because the thing placing it knows it placed a
    /// cargo container.
    static func fromEnvironmentKind(_ kind: EnvironmentObjectKind) -> AcousticSurfaceMaterial {
        switch kind {
        case .tree: return .treeTrunk
        case .building: return .concrete
        case .pole: return .metal
        case .crate: return .wood
        case .cargoContainer: return .metal
        case .rock: return .rock
        case .marker: return .generic
        }
    }

    /// The best answer available for one collision part.
    ///
    /// The part's own name wins when it says something specific — a tree's parts are named
    /// `tree.trunk` and `tree.canopy`, and those are genuinely different sounds that the
    /// object's kind alone cannot separate. The kind is the fallback for a part whose name
    /// carries nothing.
    static func resolve(source: String?, kind: EnvironmentObjectKind) -> AcousticSurfaceMaterial {
        let fromName = fromObstacleSource(source)
        return fromName == .generic ? fromEnvironmentKind(kind) : fromName
    }

    /// What the ground is, where the aircraft is standing on it.
    ///
    /// Terrain in this project is a biome preset plus weather, and both matter: the same field
    /// is soil in summer and snow in winter, and landing on either must not produce the same
    /// thump. Water is decided by the caller, which is the only thing that knows whether the
    /// column under the aircraft is a lake.
    static func fromTerrain(
        preset: TerrainPreset,
        isSnowCovered: Bool,
        isOverWater: Bool,
        isPavedSurface: Bool
    ) -> AcousticSurfaceMaterial {
        if isOverWater { return .water }
        if isSnowCovered { return .snow }
        if isPavedSurface { return .asphalt }
        switch preset {
        case .field, .forest: return .grass
        case .city: return .asphalt
        case .cargoYard: return .concrete
        case .gridDemo: return .soil
        }
    }
}

/// What the *aircraft* is made of at the point of contact.
///
/// The plan is specific that the same concrete wall must not sound the same against a plastic
/// cover, an aluminium leg, a steel motor and a composite wing, so the resolver is handed both
/// sides of the contact. This project has no per-component material — components carry mass
/// and strength, not composition — so it is derived from what a component *is* plus what the
/// airframe's skin is made of, which between them are enough to be right about the sound.
enum VehicleAcousticMaterial: String, CaseIterable, Hashable, Codable {
    case composite
    case aluminum
    case steel
    case plastic
    case rubber
    case wood

    var localizationKey: String { "audio.vehicle.material.\(rawValue)" }

    /// The airframe's own skin, mapped onto the acoustic set.
    ///
    /// Titanium and stainless steel both land on `steel`: they differ enormously in how much
    /// heat they survive, which is why the flight model keeps them apart, and hardly at all in
    /// what a wing panel made of either sounds like against a wall.
    static func fromSkin(_ skin: UAVSkinMaterial) -> VehicleAcousticMaterial {
        switch skin {
        case .composite: return .composite
        case .aluminium: return .aluminum
        case .titanium, .stainlessSteel: return .steel
        }
    }

    /// The material of the component that actually made contact.
    ///
    /// Structure follows the skin. Everything else follows its function: a motor is a lump of
    /// steel and magnets whatever the airframe is wrapped in, a landing gear leg meets the
    /// ground through rubber, an avionics box is a plastic case.
    static func resolve(componentKind: VehicleComponentKind, skin: UAVSkinMaterial) -> VehicleAcousticMaterial {
        switch componentKind {
        case .motor, .esc:
            return .steel
        case .propeller:
            // Almost every propeller in this catalogue is moulded composite or reinforced
            // nylon; either way it is not the skin's material and it is not metal.
            return .composite
        case .landingGear:
            return .rubber
        case .battery, .flightController, .radio, .cameraGimbal, .payloadMount:
            return .plastic
        case .frame, .fuselage, .arm, .tailSection, .wingSection,
             .horizontalTail, .verticalTail, .elevator, .rudder:
            return fromSkin(skin)
        }
    }
}
