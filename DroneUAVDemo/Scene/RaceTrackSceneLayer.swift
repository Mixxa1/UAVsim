import AppKit
import SceneKit

/// Owns the racing equipment in the flying scene: spawns a track, keeps each gate's colour in
/// step with the runtime, and carries the translucent ghost the in-scene builder aims with.
///
/// Purely visual. The aperture a gate is scored against is geometry, not rendering, and lives on
/// `RaceGateGeometry` in the domain instead — which is what lets the scoring rules be checked
/// without a renderer at all.
final class RaceTrackSceneLayer {
    private let rootNode = SCNNode()
    private var nodesByElementID: [UUID: SCNNode] = [:]
    private var elementsByID: [UUID: RaceTrackElement] = [:]
    private var gateLabels: [UUID: SCNNode] = [:]
    private var appliedStates: [UUID: RaceGateVisualState] = [:]
    private var isAttached = false
    private var showsGateNumbers = false
    private var portalNodes: [UUID: SCNNode] = [:]
    private var ghostNode: SCNNode?
    private var ghostPortalNode: SCNNode?
    private var ghostCatalogID: String?
    private var ghostScale: Float?

    // MARK: Attach / clear

    func attach(to parent: SCNNode) {
        guard !isAttached || rootNode.parent == nil else { return }
        rootNode.name = "race.track"
        parent.addChildNode(rootNode)
        isAttached = true
    }

    func clear() {
        rootNode.childNodes.forEach { $0.removeFromParentNode() }
        nodesByElementID.removeAll()
        elementsByID.removeAll()
        gateLabels.removeAll()
        portalNodes.removeAll()
        appliedStates.removeAll()
        ghostPortalNode = nil
        ghostNode = nil
        ghostCatalogID = nil
        ghostScale = nil
    }

    /// The scene node of a placed element, so the controller can hang collision proxies on it.
    func node(for elementID: UUID) -> SCNNode? {
        nodesByElementID[elementID]
    }

    /// Placed element nearest a point, for the builder's "delete what I am looking at".
    func nearestElement(to point: SIMD3<Float>, within radius: Float) -> UUID? {
        var bestID: UUID?
        var bestDistance = radius
        for (id, element) in elementsByID {
            let distance = simd_distance(element.position, point)
            if distance < bestDistance {
                bestDistance = distance
                bestID = id
            }
        }
        return bestID
    }

    func detach() {
        clear()
        rootNode.removeFromParentNode()
        isAttached = false
    }

    // MARK: Building

    /// Replaces everything on the track with `track`'s elements.
    func build(track: RaceTrack, into parent: SCNNode, showsGateNumbers: Bool) {
        attach(to: parent)
        clear()
        self.showsGateNumbers = showsGateNumbers
        for element in track.elements {
            add(element: element)
        }
    }

    @discardableResult
    func add(element: RaceTrackElement) -> SCNNode? {
        guard let descriptor = element.descriptor else { return nil }
        let node = RacingEquipmentAssetLoader.shared.makeElementNode(
            descriptor: descriptor,
            scale: element.scale,
            yaw: element.yawRadians
        )
        node.position = SCNVector3(element.position.x, element.position.y, element.position.z)
        rootNode.addChildNode(node)
        nodesByElementID[element.id] = node
        elementsByID[element.id] = element

        if showsGateNumbers, let order = element.gateOrder, descriptor.role.isScorable {
            let label = makeGateNumberNode(order: order + 1, descriptor: descriptor, scale: element.scale)
            node.addChildNode(label)
            gateLabels[element.id] = label
        }

        if descriptor.role.isScorable {
            let portal = makePortalNode(
                aperture: descriptor.aperture(at: element.apertureIndex),
                scale: element.scale
            )
            applyPortalColour(portal, state: appliedStates[element.id] ?? .idle)
            node.addChildNode(portal)
            portalNodes[element.id] = portal
        }
        return node
    }

    /// Direction chevrons beside the opening: three arrowheads a side, pointing the way the
    /// pilot is meant to fly through.
    ///
    /// This is how a real course marks a gate — arrows on the panels, the arrow's vector along the
    /// line of flight — and it says something a coloured frame cannot: not just *which* gate is
    /// next, but which *way* through it. It also leaves the opening clear. Filling the aperture, or
    /// repainting the whole frame, puts brightness exactly where the pilot is trying to look.
    private func makePortalNode(aperture: RacingElementAperture, scale: Float) -> SCNNode {
        let halfWidth = aperture.halfExtents.x * scale
        let node = SCNNode()
        node.name = "race.portal"
        node.castsShadow = false

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.emission.contents = RacingMaterialPalette.nextGate
        material.diffuse.contents = RacingMaterialPalette.nextGate

        // Sized off the opening so a whoop gate and an open cube both read the same.
        let armLength = Float(max(0.26, min(0.55, halfWidth * 0.38)))
        let thickness = CGFloat(max(0.05, min(0.10, halfWidth * 0.07)))
        let spacing = armLength * 1.5
        let sideOffset = halfWidth + armLength * 0.7

        // A flat "V" is only a V from one side: seen down the line of flight it collapses to a
        // dash. Four arms make an arrowhead instead — it reads as an arrow head-on, from above and
        // from the side, which is the whole point of putting a direction on a gate.
        let spread: Float = 0.72
        let armDirections: [SIMD3<Float>] = [
            simd_normalize(SIMD3<Float>(sin(spread), 0, -cos(spread))),
            simd_normalize(SIMD3<Float>(-sin(spread), 0, -cos(spread))),
            simd_normalize(SIMD3<Float>(0, sin(spread), -cos(spread))),
            simd_normalize(SIMD3<Float>(0, -sin(spread), -cos(spread)))
        ]

        for side in [Float(-1.0), 1.0] {
            for step in 0..<3 {
                let chevron = SCNNode()
                // Stacked along the direction of travel, so they read as ">>>" from the side and
                // as a funnel of arrowheads on the approach.
                chevron.position = SCNVector3(
                    side * sideOffset,
                    0.0,
                    Float(step - 1) * spacing
                )
                let tip = SIMD3<Float>(0, 0, armLength * 0.5)
                for direction in armDirections {
                    let box = SCNBox(
                        width: thickness,
                        height: thickness,
                        length: CGFloat(armLength),
                        chamferRadius: 0
                    )
                    box.firstMaterial = material
                    let bar = SCNNode(geometry: box)
                    bar.castsShadow = false
                    bar.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: direction)
                    let centre = tip + direction * (armLength * 0.5)
                    bar.position = SCNVector3(centre.x, centre.y, centre.z)
                    chevron.addChildNode(bar)
                }
                node.addChildNode(chevron)
            }
        }

        node.position = SCNVector3(
            aperture.centre.x * scale,
            aperture.centre.y * scale,
            aperture.centre.z * scale
        )
        // Built around +Z, so aiming the node's +Z along the aperture's normal points every
        // chevron the right way — including a tower's, which then point down through the top.
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: aperture.normal)
        return node
    }

    private func applyPortalColour(_ node: SCNNode, state: RaceGateVisualState) {
        let (tint, alpha): (NSColor, CGFloat) = {
            switch state {
            case .idle:
                return (RacingMaterialPalette.frameColor, 0.55)
            case .next:
                return (RacingMaterialPalette.nextGate, 1.0)
            case .passed:
                return (RacingMaterialPalette.passedGate, 0.85)
            case .wrongWay:
                return (RacingMaterialPalette.missedGate, 1.0)
            }
        }()
        node.enumerateHierarchy { child, _ in
            guard let material = child.geometry?.firstMaterial else { return }
            material.emission.contents = tint.withAlphaComponent(alpha)
            material.diffuse.contents = tint
        }
    }

    // MARK: Highlighting

    /// Repaints only the gates whose state actually changed — the runtime publishes every tick,
    /// and walking every material of every gate sixty times a second would be pure waste.
    func applyGateStates(_ states: [UUID: RaceGateVisualState]) {
        for (id, state) in states {
            guard appliedStates[id] != state, let node = nodesByElementID[id] else { continue }
            appliedStates[id] = state
            // The chevrons say which gate is next and which way through it; the frame only picks
            // up enough of the colour to be findable at distance. Repainting the whole structure
            // turned the course into a wall of solid green.
            let colour: NSColor?
            let intensity: Float
            switch state {
            case .idle:
                colour = nil
                intensity = 0.0
            case .next:
                colour = RacingMaterialPalette.nextGate
                intensity = 0.32
            case .passed:
                colour = RacingMaterialPalette.passedGate
                intensity = 0.14
            case .wrongWay:
                colour = RacingMaterialPalette.missedGate
                intensity = 0.5
            }
            RacingEquipmentAssetLoader.shared.applyHighlight(node, color: colour, intensity: intensity)

            if let portal = portalNodes[id] {
                applyPortalColour(portal, state: state)
            }
        }
    }

    // MARK: Ghost preview (track builder)

    /// The translucent element that follows the builder's aim point before it is committed.
    /// Rebuilt only when the *kind* of element changes; a move or a turn just re-poses it, which
    /// is what keeps dragging a gate around from re-loading a model sixty times a second.
    func updateGhost(element: RaceTrackElement) {
        attachGhostIfNeeded()
        if ghostCatalogID != element.catalogID || ghostScale != element.scale {
            ghostNode?.childNodes.forEach { $0.removeFromParentNode() }
            guard let descriptor = element.descriptor else { return }
            let node = RacingEquipmentAssetLoader.shared.makeElementNode(
                descriptor: descriptor,
                scale: element.scale,
                yaw: 0.0
            )
            applyGhostAppearance(node)
            ghostNode?.addChildNode(node)
            ghostCatalogID = element.catalogID
            ghostScale = element.scale
            ghostPortalNode = nil
        }
        // The chosen opening is part of what is being placed, so the ghost shows it as well.
        if let descriptor = element.descriptor, descriptor.role.isScorable {
            let aperture = descriptor.aperture(at: element.apertureIndex)
            if ghostPortalNode?.name != "race.ghost.portal.\(element.apertureIndex)" {
                ghostPortalNode?.removeFromParentNode()
                let portal = makePortalNode(aperture: aperture, scale: element.scale)
                portal.name = "race.ghost.portal.\(element.apertureIndex)"
                applyPortalColour(portal, state: .next)
                ghostNode?.addChildNode(portal)
                ghostPortalNode = portal
            }
        } else {
            ghostPortalNode?.removeFromParentNode()
            ghostPortalNode = nil
        }
        ghostNode?.position = SCNVector3(element.position.x, element.position.y, element.position.z)
        ghostNode?.eulerAngles = SCNVector3(0, element.yawRadians, 0)
        ghostNode?.isHidden = false
    }

    func clearGhost() {
        ghostNode?.removeFromParentNode()
        ghostNode = nil
        ghostCatalogID = nil
        ghostScale = nil
        ghostPortalNode = nil
    }

    private func attachGhostIfNeeded() {
        guard ghostNode == nil else { return }
        let node = SCNNode()
        node.name = "race.ghost"
        rootNode.addChildNode(node)
        ghostNode = node
    }

    private func applyGhostAppearance(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            child.castsShadow = false
            guard let geometry = child.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .constant
                material.diffuse.contents = RacingMaterialPalette.nextGate.withAlphaComponent(0.45)
                material.emission.contents = RacingMaterialPalette.nextGate.withAlphaComponent(0.35)
                material.transparency = 0.55
                material.writesToDepthBuffer = false
                material.isDoubleSided = true
            }
        }
    }

    // MARK: Gate numbers

    /// A floating number over each gate, so the racing line is readable while building and while
    /// walking the track before a run.
    private func makeGateNumberNode(
        order: Int,
        descriptor: RacingElementDescriptor,
        scale: Float
    ) -> SCNNode {
        let text = SCNText(string: "\(order)", extrusionDepth: 0.6)
        text.font = NSFont.systemFont(ofSize: 4.0, weight: .bold)
        text.flatness = 0.2
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.emission.contents = RacingMaterialPalette.startFinish
        material.lightingModel = .constant
        text.materials = [material]

        let node = SCNNode(geometry: text)
        let (minBB, maxBB) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (minBB.x + maxBB.x) * 0.5,
            (minBB.y + maxBB.y) * 0.5,
            0
        )
        let labelScale: Float = 0.32
        node.scale = SCNVector3(labelScale, labelScale, labelScale)
        node.position = SCNVector3(
            0,
            CGFloat((descriptor.sizeMeters.y * scale) + 1.2),
            0
        )
        node.castsShadow = false
        // Always legible from the cockpit, whatever heading the gate was placed at.
        node.constraints = [SCNBillboardConstraint()]
        return node
    }
}
