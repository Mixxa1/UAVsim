import AppKit
import SceneKit
import simd

/// The bundled launcher exteriors, picked by what the aircraft weighs.
///
/// Four launchers ship in `Resources/Models/Launchers`, and the collection declares its
/// own class boundaries — "Мини-БВС · условно до 5 кг", "Лёгкие БВС · условно 5–15 кг",
/// and so on. Those boundaries are the selection rule; nothing here invents a threshold.
/// Two aircraft in the catalogue land on L and five on XL, and the heaviest — a 951 kg
/// Firebee — is far past the XL band's 120 kg, so it takes the largest launcher there is
/// rather than none at all.
///
/// The launch *physics* is untouched. `FixedWingParameters` owns the rail: its length is
/// derived from the aircraft's own exit speed and acceleration limit, and the flight
/// model launches along it. The launcher is scenery fitted to that rail, which is why it
/// is scaled to the rail rather than the rail to it — a shuttle that stopped short of
/// where the aircraft left the rail would read as a bug in the launch, not in the model.
enum CatapultAssetConstants {
    static let bundleFolder = "Launchers"
    static let manifestFile = "manifest.json"
    /// Node the scene animates. `DroneSceneController.updateLaunchAssetPresentation`
    /// writes `simdPosition.z = -railLengthMeters * progress` onto it, so it has to be
    /// unscaled and aligned with the rail.
    static let carriageNodeName = "catapult_carriage"
    /// Empty node the loader parks on the carriage's cradle pads, at the height an
    /// aircraft's belly rests. Read it rather than assuming a deck height: the four
    /// launchers are different sizes, and the built node is scaled to the aircraft's
    /// own rail length and re-pitched to its rail angle, so the only honest answer
    /// comes from measuring the assembly that was actually built.
    static let cradleAnchorNodeName = "catapult_cradle_anchor"
}

struct CatapultManifest: Decodable {
    struct Animation: Decodable {
        /// Where the carriage travels over the file's own display loop, metres.
        let translationVectorM: [Float]
    }

    struct Entry: Decodable {
        let id: String
        let name: String
        /// Human-readable class, e.g. "Средние БВС · условно 15–60 кг".
        let classLabel: String
        let file: String
        let animation: Animation?

        /// Travel length the carriage has in the file as authored, metres.
        var travelLength: Float {
            guard let v = animation?.translationVectorM, v.count == 3 else { return 0 }
            return simd_length(SIMD3<Float>(v[0], v[1], v[2]))
        }

        /// Rail pitch the model is built at, radians — the angle its own carriage
        /// travel rises at.
        var railPitch: Float {
            guard let v = animation?.translationVectorM, v.count == 3 else { return 0 }
            let horizontal = sqrt(v[0] * v[0] + v[2] * v[2])
            return horizontal > 0.0001 ? atan2(v[1], horizontal) : 0
        }
    }

    let models: [Entry]
}

final class CatapultAssetLoader {
    static let shared = CatapultAssetLoader(
        directory: Bundle.main.url(
            forResource: CatapultAssetConstants.bundleFolder,
            withExtension: nil
        )
    )

    /// Upper mass bound of each class, kg, in the order the collection lists them. Taken
    /// from the manifest's own `class_label` text: до 5 / 5–15 / 15–60 / 60–120.
    private static let classCeilings: [Float] = [5, 15, 60, .greatestFiniteMagnitude]

    private let rootURL: URL?
    private let entries: [CatapultManifest.Entry]
    private var templates: [String: SCNNode] = [:]
    private var didWarn = false

    init(directory: URL?) {
        guard let root = directory,
              let data = try? Data(contentsOf: root.appendingPathComponent(CatapultAssetConstants.manifestFile))
        else {
            rootURL = directory
            entries = []
            return
        }
        rootURL = root
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        entries = (try? decoder.decode(CatapultManifest.self, from: data))?.models ?? []
    }

    /// Which launcher this aircraft is launched from.
    func entry(forTakeoffMassKg mass: Float) -> CatapultManifest.Entry? {
        guard !entries.isEmpty else { return nil }
        for (index, ceiling) in Self.classCeilings.enumerated() where mass <= ceiling {
            if index < entries.count { return entries[index] }
        }
        return entries.last
    }

    /// The launcher, built to sit on the ground with its rail running toward −Z and
    /// rising at the aircraft's own rail angle.
    ///
    /// Returns `nil` when the collection is absent or the aircraft's class has no model,
    /// and `DroneSceneController` then draws its procedural rig — the launcher is
    /// scenery, and a missing file must not stop a launch.
    func makeLauncherNode(
        takeoffMassKg: Float,
        railLengthMeters: Float,
        railAngleDegrees: Float,
        deckHeight: Float
    ) -> SCNNode? {
        guard let entry = entry(forTakeoffMassKg: takeoffMassKg),
              let template = template(for: entry) else {
            warnOnce()
            return nil
        }

        let railPitch = railAngleDegrees * Float.pi / 180.0
        let travel = entry.travelLength
        guard travel > 0.05 else { return nil }
        // Fit the model's stroke to the rail the flight model actually uses.
        let scale = max(0.2, min(4.0, railLengthMeters / travel))

        let root = SCNNode()
        root.name = "catapult.\(entry.id)"

        let model = template.clone()
        CatapultAssetLoader.giveInstanceItsOwnMaterials(model)
        guard let carriage = model.childNode(withName: "Carriage", recursively: true) else { return nil }

        // The file's rail runs toward +Z; the scene's runs toward −Z, the way the
        // aircraft's nose does once `DroneModelBuilder` has yawed it.
        let body = SCNNode()
        body.name = "catapultBody"
        body.eulerAngles = SCNVector3(
            CGFloat(railPitch - entry.railPitch),
            CGFloat.pi,
            0.0
        )
        body.simdScale = SIMD3<Float>(repeating: scale)
        body.addChildNode(model)
        root.addChildNode(body)

        // The carriage rides in its own unscaled frame, because the scene writes metres
        // of rail travel straight onto it.
        let railFrame = SCNNode()
        railFrame.name = "catapultRailFrame"
        railFrame.simdPosition = SIMD3<Float>(0.0, deckHeight, 0.0)
        railFrame.eulerAngles = SCNVector3(CGFloat(railPitch), 0.0, 0.0)
        root.addChildNode(railFrame)

        let carriageNode = SCNNode()
        carriageNode.name = CatapultAssetConstants.carriageNodeName
        railFrame.addChildNode(carriageNode)

        // Move the authored carriage out of the scaled body and under the travel node,
        // keeping exactly the pose it had — so at rest the launcher looks untouched.
        let restTransform = root.simdConvertTransform(matrix_identity_float4x4, from: carriage)
        carriage.removeFromParentNode()
        carriageNode.addChildNode(carriage)
        carriage.simdTransform = carriageNode.simdConvertTransform(restTransform, from: root)

        CatapultAssetLoader.addCradleAnchor(to: carriageNode, measuredAgainst: root)
        CatapultAssetLoader.enableShadows(root)
        return root
    }

    /// Parks an empty node where the aircraft rests: on top of the carriage's cradle pads,
    /// on the rail centreline.
    ///
    /// ⚠️ Measured, not assumed. The scene used to seat every aircraft at a fixed 0.62 m
    /// deck height, which was right for the procedural rig it was written for and wrong for
    /// all four authored launchers — their pads sit at 0.99, 1.24, 1.58 and 2.12 m at
    /// authored scale, so the aircraft appeared sunk into the launcher by up to a metre and
    /// a half, worst on the biggest one. Scaling to the aircraft's rail length and
    /// re-pitching to its rail angle move the pads again, so the height is taken from the
    /// assembled node rather than from the manifest.
    ///
    /// It is parented to the travelling carriage node, so it stays the cradle point for the
    /// whole stroke rather than only at rest.
    private static func addCradleAnchor(to carriageNode: SCNNode, measuredAgainst root: SCNNode) {
        var padTop = -Float.greatestFiniteMagnitude
        var padCentre = SIMD3<Float>(repeating: 0.0)
        var padCount: Float = 0.0
        carriageNode.enumerateHierarchy { node, _ in
            guard let name = node.name, name.contains("CradlePad"), node.geometry != nil else { return }
            let box = node.boundingBox
            let corners = [
                SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z)),
                SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            ]
            for corner in corners {
                let inRoot = root.simdConvertPosition(corner, from: node)
                padTop = max(padTop, inRoot.y)
                padCentre += inRoot
                padCount += 1.0
            }
        }
        // Falling back to the carriage's own box keeps a launcher whose pads are named
        // differently from seating its aircraft in the dirt.
        if padCount < 1.0 {
            let box = carriageNode.boundingBox
            let high = root.simdConvertPosition(
                SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z)),
                from: carriageNode
            )
            padTop = high.y
            padCentre = high
            padCount = 1.0
        }
        let centre = padCentre / padCount
        let anchor = SCNNode()
        anchor.name = CatapultAssetConstants.cradleAnchorNodeName
        anchor.simdPosition = carriageNode.simdConvertPosition(
            SIMD3<Float>(centre.x, padTop, centre.z),
            from: root
        )
        carriageNode.addChildNode(anchor)
    }

    private func template(for entry: CatapultManifest.Entry) -> SCNNode? {
        if let cached = templates[entry.id] { return cached }
        guard let rootURL else { return nil }
        let url = rootURL.appendingPathComponent((entry.file as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = SCNSceneSource(url: url, options: nil),
              // No `.preserveOriginalTopology: false` — it gamma-mangles authored colours.
              // See `UAVModelAssetLibrary.template(for:)`, where that was measured.
              let scene = source.scene(options: [
                  .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay,
                  .checkConsistency: false
              ]) else {
            return nil
        }
        let template = SCNNode()
        template.name = "catapultTemplate.\(entry.id)"
        for child in scene.rootNode.childNodes { template.addChildNode(child) }
        // The file's own carriage loop is a viewing aid; the launch sequence owns it here.
        template.enumerateHierarchy { node, _ in
            node.removeAllAnimations()
            node.removeAllActions()
        }
        templates[entry.id] = template
        return template
    }

    private func warnOnce() {
        guard !didWarn else { return }
        didWarn = true
        print("[Launchers] no bundled catapult for this class — drawing the procedural rig")
    }

    private static func giveInstanceItsOwnMaterials(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            node.geometry = copy
        }
    }

    private static func enableShadows(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in node.castsShadow = true }
    }
}
