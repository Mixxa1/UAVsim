import AppKit
import SceneKit
import simd

/// Independent presentation constraints must compose: a fleet refresh must not
/// reveal an enclosed aircraft, and a camera refresh must not reveal a spectator.
struct LocalAircraftPresentationVisibility {
    var enclosed = false
    var spectator = false
    var isHidden: Bool { enclosed || spectator }
}

/// Authored container-launch transports: a 6×6 truck carrying the launch module, one per
/// aircraft that is launched from a canister.
///
/// The launcher is scenery — a missing file must never stop a launch — so every failure
/// path here returns `nil` and `DroneSceneController` draws its procedural rig instead.
///
/// ⚠️ Everything positional is measured from the model at load time rather than written
/// down as a constant. The catapult collection was connected by assuming a deck height,
/// and every aircraft ended up seated a metre or more below the cradle it was supposed to
/// be resting on, worst on the biggest launcher. These modules sit at different heights
/// again (Harpy's cells at 2.98–4.02 m, Harop's at 2.40–3.77 m), and they do not even fire
/// the same way: the Harpy's containers point along the truck, the Harop's point across it,
/// which is how it is photographed. So the loader finds the launch cell, reads which way it
/// faces, and turns the truck to suit.
enum CanisterAssetConstants {
    static let bundleFolder = "CanisterLaunchers"
    static let manifestFile = "manifest.json"
    /// The cell the round leaves from. `DroneSceneController` reads this to seat the
    /// airframe inside its own launcher rather than beside or beneath it.
    static let launchCellAnchorNodeName = "canister_launch_cell"
    /// Muzzle of that cell — where the booster plume belongs and where the round clears.
    static let muzzleAnchorNodeName = "canister_muzzle_anchor"
}

struct CanisterLauncherManifest: Decodable {
    struct Entry: Decodable {
        let id: String
        let file: String
        /// Aircraft this launcher belongs to. A profile with no entry has no authored
        /// launcher, which is not an error — it draws the procedural one.
        let profileIds: [String]
        /// Name of the cell the round leaves from, as authored.
        let launchCell: String
        let coverAnimation: Bool
    }
    let models: [Entry]
}

final class CanisterAssetLoader {
    static let shared = CanisterAssetLoader(
        directory: Bundle.main.url(
            forResource: CanisterAssetConstants.bundleFolder,
            withExtension: nil
        )
    )

    private let rootURL: URL?
    private let entries: [CanisterLauncherManifest.Entry]
    private var templates: [String: SCNNode] = [:]
    private var warned = false

    init(directory: URL?) {
        rootURL = directory
        guard let directory,
              let data = try? Data(
                contentsOf: directory.appendingPathComponent(CanisterAssetConstants.manifestFile)
              )
        else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        entries = (try? decoder.decode(CanisterLauncherManifest.self, from: data))?.models ?? []
    }

    /// Whether this aircraft has an authored transport at all.
    func hasLauncher(profileID: String) -> Bool { entry(for: profileID) != nil }

    private func entry(for profileID: String) -> CanisterLauncherManifest.Entry? {
        entries.first { $0.profileIds.contains(profileID) }
    }

    /// The truck, standing on the ground with its launch cell aimed along −Z — the
    /// direction the scene's launch heading points once it is applied to the parent node,
    /// and the direction the aircraft's nose faces after `DroneModelBuilder` has yawed it.
    ///
    /// `elevationDegrees` tilts the module on its bed, nose-up. The truck stays level: it
    /// is standing on its wheels.
    func makeLauncherNode(profileID: String, elevationDegrees: Float) -> SCNNode? {
        guard let entry = entry(for: profileID), let template = template(for: entry) else {
            warnOnce()
            return nil
        }
        let model = template.clone()
        CanisterAssetLoader.giveInstanceItsOwnMaterials(model)

        let root = SCNNode()
        root.name = "canisterLauncher.\(entry.id)"

        // Which way this launcher fires, in the model's own frame. The cover panels sit on
        // the muzzle face, so the vector from the cell's body to its cover is the answer —
        // and it differs between the two trucks, so it has to be asked rather than assumed.
        guard let facing = CanisterAssetLoader.firingDirection(ofCell: entry.launchCell, in: model)
        else {
            warnOnce()
            return nil
        }

        // Turn the truck about its own vertical axis until the cell fires along −Z. It
        // comes out a quarter turn for the cabover and a half turn for the bonnet — the
        // measured difference between a module that fires along the truck and one that
        // fires across it, rather than a per-model constant.
        //
        // ⚠️ The signs are `atan2(x, -z)`, not `atan2(-x, -z)`. A yaw of θ about +Y sends
        // (x, z) to (x·cosθ + z·sinθ, −x·sinθ + z·cosθ), so solving for −Z gives this pair.
        // The wrong pair still turns a +Z launcher correctly — it needs a half turn either
        // way — and quietly turns a +X one a half turn backwards: the cabover came out with
        // its covers pointing away from the launch heading, firing through its own bed.
        let yaw = atan2(facing.x, -facing.z)
        let truck = SCNNode()
        truck.name = "canisterTransport"
        truck.eulerAngles = SCNVector3(0.0, CGFloat(yaw), 0.0)
        truck.addChildNode(model)
        root.addChildNode(truck)

        // Elevation, applied to the module alone so the truck keeps its wheels on the
        // ground. The pivot is the launch cell's own centre, which keeps the cell where it
        // is and swings its muzzle up, the way a trunnion does.
        if let module = model.childNode(withName: "ContainerModule", recursively: true),
           let seated = CanisterAssetLoader.groupBounds(
            prefix: entry.launchCell, in: root, coversOnly: false
           ),
           abs(elevationDegrees) > 0.05 {
            // ⚠️ Re-parent first, restore the pose, and only then turn the pivot. Doing it
            // the other way round — the order the catapult's carriage uses, where the point
            // is to leave the carriage looking untouched — writes the module's original
            // world transform back on top of the rotation and cancels it exactly. Measured:
            // the launcher came out identical at 0° and at 18°.
            let pivot = SCNNode()
            pivot.name = "canisterElevationPivot"
            pivot.simdPosition = (seated.min + seated.max) * 0.5
            let moduleRest = root.simdConvertTransform(matrix_identity_float4x4, from: module)
            module.removeFromParentNode()
            root.addChildNode(pivot)
            pivot.addChildNode(module)
            module.simdTransform = pivot.simdConvertTransform(moduleRest, from: root)
            // ⚠️ Positive, not negative. A rotation of α about +X sends a point at (0, 0, −L)
            // — forward, where the muzzle is — to y = L·sin α, so a positive angle raises
            // the muzzle and a negative one buries it. Measured both ways rather than
            // reasoned: the first version depressed the launcher, and the cover on the
            // Harop's launch cell dropped from 3.09 m to 2.63 m as the elevation went up.
            pivot.eulerAngles = SCNVector3(CGFloat(elevationDegrees * Float.pi / 180.0), 0.0, 0.0)
        }

        CanisterAssetLoader.addLaunchAnchors(to: root, cellName: entry.launchCell)
        CanisterAssetLoader.enableShadows(root)
        return root
    }

    // MARK: - Measurement

    /// A cell is a group of parts sharing the `Cell_R_C` name prefix rather than a single
    /// node, so everything positional about it comes from the group's combined bounds.
    private static func groupBounds(
        prefix: String,
        in model: SCNNode,
        coversOnly: Bool
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        model.enumerateHierarchy { node, _ in
            guard let name = node.name, name.hasPrefix(prefix), node.geometry != nil else { return }
            if coversOnly, !(name.contains("Cover") || name.contains("Door")) { return }
            let box = node.boundingBox
            let lo = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let hi = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            for corner in [lo, hi,
                           SIMD3<Float>(lo.x, lo.y, hi.z), SIMD3<Float>(lo.x, hi.y, lo.z),
                           SIMD3<Float>(hi.x, lo.y, lo.z), SIMD3<Float>(lo.x, hi.y, hi.z),
                           SIMD3<Float>(hi.x, lo.y, hi.z), SIMD3<Float>(hi.x, hi.y, lo.z)] {
                let inModel = model.simdConvertPosition(corner, from: node)
                low = simd_min(low, inModel)
                high = simd_max(high, inModel)
            }
            found = true
        }
        return found ? (low, high) : nil
    }

    /// The direction the named cell fires, as a unit vector in the model's frame: from the
    /// cell's body toward its cover, snapped to the dominant axis so a millimetre of
    /// modelling asymmetry cannot turn the truck the wrong way.
    private static func firingDirection(ofCell cellName: String, in model: SCNNode) -> SIMD3<Float>? {
        guard let all = groupBounds(prefix: cellName, in: model, coversOnly: false),
              let cover = groupBounds(prefix: cellName, in: model, coversOnly: true)
        else { return nil }
        let delta = ((cover.min + cover.max) - (all.min + all.max)) * 0.5
        if abs(delta.x) >= abs(delta.z) {
            return SIMD3<Float>(delta.x >= 0 ? 1.0 : -1.0, 0.0, 0.0)
        }
        return SIMD3<Float>(0.0, 0.0, delta.z >= 0 ? 1.0 : -1.0)
    }

    /// Parks the two anchors the scene launches from, and gives the launch cell's cover the
    /// name the presentation already animates.
    ///
    /// Measured after the truck has been turned and the module elevated, so the anchors
    /// describe the assembly that was actually built.
    private static func addLaunchAnchors(to root: SCNNode, cellName: String) {
        guard let cell = groupBounds(prefix: cellName, in: root, coversOnly: false) else { return }
        let centre = (cell.min + cell.max) * 0.5
        // The truck has been turned so the cell fires along −Z; its muzzle is therefore its
        // own most-negative Z, whichever axis it was authored along.
        let muzzle = SIMD3<Float>(centre.x, centre.y, cell.min.z)

        let seat = SCNNode()
        seat.name = CanisterAssetConstants.launchCellAnchorNodeName
        // A third of the way in from the muzzle, matching where the launch physics puts a
        // sealed round: inside the cell it is fired from, not standing at its mouth.
        seat.simdPosition = SIMD3<Float>(
            centre.x,
            centre.y,
            cell.min.z + (cell.max.z - cell.min.z) * 0.32
        )
        root.addChildNode(seat)

        let muzzleAnchor = SCNNode()
        muzzleAnchor.name = CanisterAssetConstants.muzzleAnchorNodeName
        muzzleAnchor.simdPosition = muzzle
        root.addChildNode(muzzleAnchor)

        // `updateLaunchAssetPresentation` fades a node called `canister_muzzle_cap` at
        // commit, and it fades exactly one: `childNode(withName:)` returns the first match.
        // An authored cover is nine or ten separate parts — panel, rim, seal, stiffeners,
        // handle, door — so giving them all that name would fade one rim and leave the
        // cover standing. They are gathered under a single node instead, and it carries the
        // name. The other cells keep their own covers and stay shut, which is right: only
        // the cell being fired from opens.
        var coverParts: [SCNNode] = []
        root.enumerateHierarchy { node, _ in
            guard let name = node.name, name.hasPrefix(cellName),
                  name.contains("Cover") || name.contains("Door") else { return }
            coverParts.append(node)
        }
        guard let coverParent = coverParts.first?.parent else { return }
        let cap = SCNNode()
        cap.name = "canister_muzzle_cap"
        coverParent.addChildNode(cap)
        for part in coverParts {
            let world = cap.simdConvertTransform(part.simdTransform, from: part.parent ?? coverParent)
            part.removeFromParentNode()
            cap.addChildNode(part)
            part.simdTransform = world
        }
    }

    // MARK: - Loading

    private func template(for entry: CanisterLauncherManifest.Entry) -> SCNNode? {
        if let cached = templates[entry.id] { return cached }
        guard let rootURL else { return nil }
        let url = rootURL.appendingPathComponent((entry.file as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = SCNSceneSource(url: url, options: nil),
              // No `.preserveOriginalTopology: false` — it gamma-mangles authored colours.
              // See `UAVModelAssetLibrary.template(for:)`, where that was measured.
              let scene = source.scene(options: [
                .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay
              ])
        else { return nil }
        let node = scene.rootNode.clone()
        // The cover loop in the file is a viewing aid; the launch sequence owns the cover.
        node.enumerateHierarchy { child, _ in
            child.removeAllAnimations()
        }
        templates[entry.id] = node
        return node
    }

    private static func giveInstanceItsOwnMaterials(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry else { return }
            let copy = geometry.copy() as! SCNGeometry
            copy.materials = geometry.materials.map { $0.copy() as! SCNMaterial }
            child.geometry = copy
        }
    }

    private static func enableShadows(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            child.castsShadow = child.geometry != nil
        }
    }

    private func warnOnce() {
        guard !warned else { return }
        warned = true
        print("[CanisterAssets] No authored transport available; drawing the procedural rig.")
    }
}
