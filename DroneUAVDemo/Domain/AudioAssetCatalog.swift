import Foundation

/// What the simulation is allowed to ask for, by name.
///
/// The physics layer must never learn a file name — an impact resolver that says
/// `"concrete_hit.wav"` has hard-coded one sound pack into the collision solver, and swapping
/// the pack then means editing physics. It asks for `.concreteHit`; what that resolves to,
/// how many variants it has and how loud it starts is the pack's business.
///
/// The raw values are the runtime IDs from the audio plan and match `AudioPack.json` exactly.
enum AudioAssetID: String, CaseIterable, Hashable {
    // Vehicle — continuous and start/stop cues for the aircraft itself.
    case uavSmallHover = "uav_small_hover"
    case uavSmallSpinup = "uav_small_spinup"
    case uavHeavyHoverLoop = "uav_heavy_hover_loop"
    case uavHexFlight = "uav_hex_flight"
    case fpvFlightLoop = "fpv_flight_loop"
    case fpvElectronicsBoot = "fpv_electronics_boot"
    /// A heavy multirotor starting up. Its own recording, slowed — a 25 kg machine does not
    /// spin up like a 249 g one.
    case uavHeavySpinup = "uav_heavy_spinup"
    /// An FPV quad's rev — sharp and short, where a camera drone's is a slow rise.
    case fpvSpinup = "fpv_spinup"
    /// The electric fixed wing's two halves: the motor itself, and the propeller in front of
    /// it. Kept apart because they do not move together — the plan asks for "motor whine +
    /// propeller + airflow" and a single recording of all three cannot be driven separately.
    case fixedWingElectricMotor = "fixedwing_electric_motor"
    case fixedWingPropellerLoop = "fixedwing_propeller_loop"
    /// A helicopter's main rotor. Large, slow and multi-bladed — a different sound from any
    /// number of small fast propellers, which is why it cannot be a multirotor loop.
    case helicopterRotorLoop = "helicopter_rotor_loop"
    case pistonEngineLoop = "piston_engine_loop"
    case pistonEngineStart = "piston_engine_start"
    case turbopropLoop = "turboprop_loop"
    case turbopropStart = "turboprop_start"
    case turbojetLoop = "turbojet_loop"
    case turbojetStart = "turbojet_start"
    /// Control-surface servos. Not a loop: this project's source is a set of discrete servo
    /// moves, which is what a control surface actually makes — a step, not a drone.
    case mechanismServo = "mechanism_servo"

    /// Airflow over the airframe.
    ///
    /// Supplied by the pack when it has a recording, and generated when it does not — the
    /// service registers a synthesised bed under this same id only if the manifest has no
    /// entry for it. Either way the runtime asks for one thing, and a build with a missing
    /// pack still has wind.
    case airflowLoop = "airflow_loop"

    // Impact — the first contact, by what was struck.
    case impactMechanicalShort = "impact_mechanical_short"
    case impactMetalHeavy = "impact_metal_heavy"
    case concreteHit = "concrete_hit"
    case scrapeMetalConcrete = "scrape_metal_concrete"
    case treeTrunkImpact = "tree_trunk_impact"
    case foliageBranchImpact = "foliage_branch_impact"
    case groundDirtThud = "ground_dirt_thud"
    case glassShatter = "glass_shatter"
    case waterImpact = "water_impact"

    // Damage — what the structure does after the contact.
    case damageMetalBend = "damage_metal_bend"
    case treeWoodCrack = "tree_wood_crack"
    case buildingDebris = "building_debris"
    case damageStoneCrash = "damage_stone_crash"
    case damageCompositeBreak = "damage_composite_break"
}

enum AudioAssetCategory: String, Codable, Hashable {
    case vehicle
    case impact
    case damage
    case aero
}

/// One entry in the pack: where the clips are, how many variants exist, and the level the
/// pack was authored at.
///
/// `defaultGainDb` is not a mixing afterthought. The clips are peak-normalised, deliberately
/// *not* loudness-normalised — loudness normalisation would make a snapping twig and a wing
/// hitting a wall the same size, which is the one distinction the impact resolver exists to
/// draw. This field is where the intended relative loudness lives, so it is a stated decision
/// rather than a property of how each contributor happened to record their sample.
struct AudioAssetDescriptor: Codable, Hashable {
    let id: String
    let category: AudioAssetCategory
    /// Path relative to the bundled `Audio/` directory, without variant suffix or extension.
    let path: String
    /// How many interchangeable takes exist. 1 means a single clip at `path.wav`; more means
    /// `path_1.wav` … `path_N.wav`.
    let variants: Int
    let loop: Bool
    let durationSeconds: Double
    let defaultGainDb: Float

    /// The file for one variant. `variant` is 1-based and clamped, so a caller asking for a
    /// variant that does not exist gets a real clip rather than silence.
    func relativePath(variant: Int) -> String {
        guard variants > 1 else { return "\(path).wav" }
        let index = min(max(1, variant), variants)
        return "\(path)_\(index).wav"
    }

    var allRelativePaths: [String] {
        guard variants > 1 else { return [relativePath(variant: 1)] }
        return (1...variants).map { relativePath(variant: $0) }
    }
}

/// An asset the plan calls for that this pack cannot supply yet.
///
/// Kept in the manifest rather than omitted, so a missing sound reports itself as missing
/// instead of being quietly substituted with something made of the wrong material.
struct AudioAssetGap: Codable, Hashable {
    let id: String
    let category: AudioAssetCategory
    let reason: String
}

struct AudioPackManifest: Codable {
    let schemaVersion: Int
    let sampleRate: Int
    let channels: Int
    let assets: [AudioAssetDescriptor]
    let unavailable: [AudioAssetGap]

    static let empty = AudioPackManifest(
        schemaVersion: 1,
        sampleRate: 48_000,
        channels: 1,
        assets: [],
        unavailable: []
    )
}

/// The sound pack as data.
///
/// Built by `Tools/audio-pack.sh` from the raw CC0 downloads and read here. Nothing in this
/// type touches an audio API — it is the lookup the simulation and the resolver share, and it
/// compiles into the headless probes along with the rest of `Domain/`.
struct AudioAssetCatalog {
    let manifest: AudioPackManifest
    private let byID: [String: AudioAssetDescriptor]
    private let gapsByID: [String: AudioAssetGap]
    /// Directory the clip paths are relative to. `nil` for a catalog built without a bundle
    /// (a probe, a test) — descriptors still resolve, files simply cannot be opened.
    let rootURL: URL?

    static let empty = AudioAssetCatalog(manifest: .empty, rootURL: nil)

    init(manifest: AudioPackManifest, rootURL: URL?) {
        self.manifest = manifest
        self.rootURL = rootURL
        byID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        gapsByID = Dictionary(uniqueKeysWithValues: manifest.unavailable.map { ($0.id, $0) })
    }

    /// Reads `Audio/AudioPack.json` out of a bundle.
    ///
    /// A missing or malformed manifest yields an empty catalog rather than a crash: an
    /// aircraft that flies silently is a defect, an aircraft that refuses to fly because a
    /// sound pack is absent is a worse one.
    static func load(from bundle: Bundle = .main) -> AudioAssetCatalog {
        guard let root = bundle.url(forResource: "Audio", withExtension: nil) else {
            return .empty
        }
        let manifestURL = root.appendingPathComponent("AudioPack.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AudioPackManifest.self, from: data) else {
            return .empty
        }
        return AudioAssetCatalog(manifest: manifest, rootURL: root)
    }

    func descriptor(for id: AudioAssetID) -> AudioAssetDescriptor? { byID[id.rawValue] }

    func isAvailable(_ id: AudioAssetID) -> Bool { byID[id.rawValue] != nil }

    /// Why an asset the plan lists is not in the pack, when the pack says so itself.
    func gapReason(for id: AudioAssetID) -> String? { gapsByID[id.rawValue]?.reason }

    func fileURL(for id: AudioAssetID, variant: Int) -> URL? {
        guard let descriptor = byID[id.rawValue], let rootURL else { return nil }
        return rootURL.appendingPathComponent(descriptor.relativePath(variant: variant))
    }

    var isEmpty: Bool { byID.isEmpty }

    /// Every clip in the pack, for preloading.
    var allClipURLs: [(id: String, variant: Int, url: URL)] {
        guard let rootURL else { return [] }
        return manifest.assets.flatMap { descriptor -> [(String, Int, URL)] in
            (1...max(1, descriptor.variants)).map { variant in
                (descriptor.id, variant, rootURL.appendingPathComponent(descriptor.relativePath(variant: variant)))
            }
        }
    }

    /// Which take to use for a given event.
    ///
    /// Derived from the event's own identity rather than from a random number generator, for
    /// one specific reason: a replay of the same flight has to sound like the flight. The
    /// simulation already numbers its damage events, so the same contact picks the same take
    /// on every playback, while two different contacts a tenth of a second apart still pick
    /// different ones. SplitMix64's finaliser is used because consecutive seeds — which is
    /// exactly what a sequence number gives — must not produce consecutive variants.
    static func variantIndex(seed: UInt64, variants: Int) -> Int {
        guard variants > 1 else { return 1 }
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Int(z % UInt64(variants)) + 1
    }

    /// Pitch and gain jitter for one event, from the same deterministic seed.
    ///
    /// Small on purpose. The plan's range is ±4 % pitch and roughly −1.5…+1 dB: enough that
    /// two hits in a row are not the same recording twice, not enough to change what the
    /// material sounds like. A wider spread does not read as variety, it reads as the wrong
    /// object.
    static func jitter(seed: UInt64) -> (pitchRatio: Float, gainDb: Float) {
        var z = seed &+ 0x2545_F491_4F6C_DD1D
        z = (z ^ (z >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        z = (z ^ (z >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        z = z ^ (z >> 33)
        let a = Float(z & 0xFFFF) / Float(0xFFFF)
        let b = Float((z >> 16) & 0xFFFF) / Float(0xFFFF)
        return (0.96 + a * 0.08, -1.5 + b * 2.5)
    }
}
