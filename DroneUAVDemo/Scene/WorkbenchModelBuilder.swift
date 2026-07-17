import AppKit
import SceneKit
import simd

/// Shared 3D factory for the assembled drone and every catalog thumbnail.
/// Built-in parts are deliberately recognizable procedural models; CADNext
/// imports use their exact triangle mesh (or the explicit legacy proxy).
enum WorkbenchModelBuilder {
    static let slotNodePrefix = "workbench.slot."
    static let hotspotNodePrefix = "workbench.hotspot."
    static let frameNodeName = "workbench.frame"

    private static let importedGeometryCache: NSCache<NSString, SCNGeometry> = {
        let cache = NSCache<NSString, SCNGeometry>()
        cache.countLimit = 48
        cache.totalCostLimit = 180_000
        return cache
    }()

    static func aircraftNode(
        for build: WorkbenchBuild,
        selectedCategory: WorkbenchCategory? = nil,
        showsHotspots: Bool = true
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.aircraft"
        let frame = build.resolvedFrame

        let frameRoot = frameNode(frame)
        frameRoot.name = frameNodeName
        applySelection(selectedCategory == .frame, to: frameRoot)
        root.addChildNode(frameRoot)
        let componentLayout = WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)

        let armTopY: Float = frame.frameClass == .tinyWhoop ? 0.0014 : 0.0026
        var installedMotorHeight: Float = 0
        if let motor = build.spec(for: .motor) {
            let prototype = componentNode(motor)
            installedMotorHeight = Float(prototype.boundingBox.max.y)
            for (index, mount) in frame.motorMounts.enumerated() {
                let node = prototype.clone()
                node.name = "\(slotNodePrefix)motor.\(index)"
                applySelection(selectedCategory == .slot(.motor), to: node)
                if frame.architecture == .multicopter {
                    // Preserve the original quad layout byte-for-byte: the
                    // procedural motor is authored with its shaft along +Y.
                    node.simdPosition = mount + SIMD3<Float>(0, armTopY, 0)
                    root.addChildNode(node)
                } else {
                    let axis = propulsionAxis(for: frame, index: index)
                    let mountRoot = propulsionMountRoot(
                        at: mount,
                        axis: axis)
                    // Lift motors stand on the wing pad.  A cruise motor's
                    // local +Y is longitudinal, so adding the vertical arm
                    // clearance there created a visible gap at the firewall.
                    node.simdPosition.y = abs(axis.y) > 0.65 ? armTopY : 0
                    mountRoot.addChildNode(node)
                    root.addChildNode(mountRoot)
                }
            }
        }
        if let propeller = build.spec(for: .propeller) {
            let prototype = componentNode(propeller)
            for (index, mount) in frame.motorMounts.enumerated() {
                let node = prototype.clone()
                node.name = "\(slotNodePrefix)propeller.\(index)"
                node.eulerAngles.y = index.isMultiple(of: 2) ? 0.18 : -0.18
                applySelection(selectedCategory == .slot(.propeller), to: node)
                if frame.architecture == .multicopter {
                    node.simdPosition = mount + SIMD3<Float>(
                        0, armTopY + installedMotorHeight - 0.0005, 0)
                    root.addChildNode(node)
                } else {
                    // Keep the named propeller itself aligned to local +Y.
                    // SceneController spins that local axis; the unnamed
                    // parent carries the fixed lift/cruise orientation.
                    let axis = propulsionAxis(for: frame, index: index)
                    let mountRoot = propulsionMountRoot(at: mount, axis: axis)
                    let mountOffset = abs(axis.y) > 0.65 ? armTopY : 0
                    node.simdPosition.y = mountOffset + installedMotorHeight - 0.0005
                    mountRoot.addChildNode(node)
                    root.addChildNode(mountRoot)
                }
            }
        }

        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard let spec = build.spec(for: kind),
                  let placement = componentLayout[kind] else { continue }
            let hardware = mountingHardwareNode(
                for: kind, spec: spec, placement: placement, frame: frame)
            hardware.name = "workbench.mount.\(kind.rawValue)"
            root.addChildNode(hardware)
            let node = componentNode(spec)
            node.simdPosition = placement.position
            applyMountOrientation(
                to: node, kind: kind, spec: spec, placement: placement)
            node.name = "\(slotNodePrefix)\(kind.rawValue)"
            applySelection(selectedCategory == .slot(kind), to: node)
            root.addChildNode(node)
        }

        if let servo = build.spec(for: .servo), !frame.servoMounts.isEmpty {
            let positions = WorkbenchBuildAnalyzer.resolvedServoPositions(
                frame: frame, spec: servo)
            for (index, position) in positions.enumerated() {
                let hardware = servoMountingHardwareNode(
                    at: position,
                    size: servo.proxy.size.simdFloat,
                    frame: frame)
                hardware.name = "workbench.mount.servo.\(index)"
                root.addChildNode(hardware)

                let node = componentNode(servo)
                node.simdPosition = position
                node.name = "\(slotNodePrefix)servo.\(index)"
                applySelection(selectedCategory == .slot(.servo), to: node)
                root.addChildNode(node)
            }
        }

        // Wiring is part of the assembly, not part of a catalog thumbnail.
        // Route every visible lead to an actual endpoint and hold it against
        // the frame with clips instead of leaving loose cylinders in space.
        if let battery = componentLayout[.battery],
           let esc = componentLayout[.esc] {
            root.addChildNode(powerHarnessNode(
                battery: battery, esc: esc, frame: frame))
        }
        if let receiver = componentLayout[.receiver] {
            root.addChildNode(receiverAntennaHarnessNode(
                receiver: receiver, frame: frame))
        }
        if let controller = componentLayout[.flightController] {
            for kind in [WorkbenchComponentKind.gps, .sensor] {
                guard let peripheral = componentLayout[kind] else { continue }
                root.addChildNode(signalHarnessNode(
                    from: peripheral, to: controller, frame: frame))
            }
        }

        if showsHotspots {
            addHotspots(to: root, build: build, selectedCategory: selectedCategory)
        }
        return root
    }

    private static func applyMountOrientation(
        to node: SCNNode,
        kind: WorkbenchComponentKind,
        spec: WorkbenchComponentSpec,
        placement: WorkbenchResolvedComponentPlacement
    ) {
        guard placement.surface == .bottom else { return }
        switch kind {
        case .camera:
            // Mapping/landing cameras look through the belly aperture.
            node.eulerAngles.x = .pi / 2
        case .sensor:
            let identity = "\(spec.id) \(spec.displayName)".lowercased()
            // Optical-flow geometry is authored with its lens along -Y.
            // Radar/rangefinder faces are authored forward and must be turned
            // into a real downward-looking installation.
            if !identity.contains("optical-flow") {
                node.eulerAngles.x = .pi / 2
            }
        default:
            break
        }
    }

    private static func propulsionAxis(
        for frame: WorkbenchResolvedFrame,
        index: Int
    ) -> SIMD3<Float> {
        guard frame.propulsionAxes.indices.contains(index) else {
            return SIMD3<Float>(0, 1, 0)
        }
        let axis = frame.propulsionAxes[index]
        return simd_length_squared(axis) > 1e-8
            ? simd_normalize(axis)
            : SIMD3<Float>(0, 1, 0)
    }

    private static func propulsionMountRoot(
        at position: SIMD3<Float>,
        axis: SIMD3<Float>
    ) -> SCNNode {
        let root = SCNNode()
        root.simdPosition = position
        root.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: axis)
        return root
    }

    private static func servoMountingHardwareNode(
        at position: SIMD3<Float>,
        size: SIMD3<Float>,
        frame: WorkbenchResolvedFrame
    ) -> SCNNode {
        let root = SCNNode()
        let flange = SCNBox(
            width: CGFloat(size.x + 0.010),
            height: 0.0015,
            length: CGFloat(size.z + 0.008),
            chamferRadius: 0.0006)
        flange.materials = [carbonFiberMaterial()]
        let flangeNode = SCNNode(geometry: flange)
        flangeNode.simdPosition = SIMD3<Float>(
            position.x,
            position.y + size.y * 0.5 - 0.00075,
            position.z)
        root.addChildNode(flangeNode)

        let hardware = material("#89939D", metalness: 0.78, roughness: 0.24)
        for x in [-size.x * 0.5 - 0.0025, size.x * 0.5 + 0.0025] {
            let screw = SCNCylinder(radius: 0.0008, height: 0.0019)
            screw.radialSegmentCount = 14
            screw.materials = [hardware]
            let screwNode = SCNNode(geometry: screw)
            screwNode.simdPosition = SIMD3<Float>(
                position.x + x,
                position.y + size.y * 0.5 + 0.0002,
                position.z)
            root.addChildNode(screwNode)
        }

        // Short mechanical linkage to the matching trailing-edge surface.
        // It makes the actuator read as an installed servo rather than an
        // electronics brick left on top of the wing.
        let aircraftLength = max(Float(frame.sizeMeters.z), 0.36)
        let isTail = position.z < -aircraftLength * 0.22
        let linkageLength = isTail
            ? max(aircraftLength * 0.055, 0.028)
            : max(aircraftLength * 0.075, 0.034)
        let hornPoint = SIMD3<Float>(
            position.x + size.x * 0.22,
            position.y + size.y * 0.5 + 0.003,
            position.z)
        let controlPoint = SIMD3<Float>(
            position.x + (isTail ? 0 : (position.x < 0 ? -0.006 : 0.006)),
            hornPoint.y - 0.001,
            position.z - linkageLength)
        root.addChildNode(beamNode(
            from: hornPoint,
            to: controlPoint,
            radius: 0.00055,
            material: hardware))
        for point in [hornPoint, controlPoint] {
            let joint = SCNSphere(radius: 0.00125)
            joint.segmentCount = 14
            joint.materials = [hardware]
            let jointNode = SCNNode(geometry: joint)
            jointNode.simdPosition = point
            root.addChildNode(jointNode)
        }
        return root
    }

    private static func mountingHardwareNode(
        for kind: WorkbenchComponentKind,
        spec: WorkbenchComponentSpec,
        placement: WorkbenchResolvedComponentPlacement,
        frame: WorkbenchResolvedFrame
    ) -> SCNNode {
        let root = SCNNode()
        let size = placement.size
        let isBottom = placement.surface == .bottom
        let plateThickness: Float = frame.frameClass == .tinyWhoop ? 0.0008 : 0.0014
        let support = WorkbenchBuildAnalyzer.mountingEnvelope(for: frame)
        let plateMaterial = carbonFiberMaterial()
        let hardware = material("#89939D", metalness: 0.78, roughness: 0.24)
        let rubber = rubberMaterial("#1B2025")

        func plateNode(extraX: Float = 0.006, extraZ: Float = 0.006) -> SCNNode {
            let plate = SCNBox(
                width: CGFloat(size.x + extraX),
                height: CGFloat(plateThickness),
                length: CGFloat(size.z + extraZ),
                chamferRadius: CGFloat(min(plateThickness * 0.45, 0.001)))
            plate.materials = [plateMaterial]
            let node = SCNNode(geometry: plate)
            let contactY = placement.position.y
                + (isBottom ? size.y * 0.5 + plateThickness * 0.5
                            : -size.y * 0.5 - plateThickness * 0.5)
            node.simdPosition = SIMD3<Float>(placement.position.x, contactY, placement.position.z)
            return node
        }

        /// Connects the local mounting plate to the real deck/fuselage edge.
        /// A plate alone looked plausible from above but visibly floated as
        /// soon as the camera orbited to a side or underside view.
        func connectPlateToFrame(
            _ plate: SCNNode,
            extraX: Float = 0.006,
            extraZ: Float = 0.006
        ) {
            let platePosition = plate.simdPosition
            let halfPlateX = (size.x + extraX) * 0.5
            let halfPlateZ = (size.z + extraZ) * 0.5
            let connectorWidth: Float = frame.frameClass == .tinyWhoop ? 0.0018 : 0.0032

            switch placement.surface {
            case .internalBay:
                // Interior trays bolt to the belly/deck with real standoffs.
                // Keeping these inside the fuselage/central cage avoids the
                // former floating side shelves while preserving service gaps.
                let plateFaceY = platePosition.y - plateThickness * 0.5
                let frameFaceY = support.bottom
                let supportHeight = max(abs(plateFaceY - frameFaceY), 0.0025)
                let supportCenterY = min(plateFaceY, frameFaceY) + supportHeight * 0.5
                let xInset = max(halfPlateX - 0.003, 0.0015)
                let zInset = max(halfPlateZ - 0.003, 0.0015)
                for x in [-xInset, xInset] {
                    for z in [-zInset, zInset] {
                        let post = SCNCylinder(
                            radius: frame.frameClass == .tinyWhoop ? 0.0006 : 0.0010,
                            height: CGFloat(supportHeight))
                        post.radialSegmentCount = 14
                        post.materials = [kind == .flightController ? rubber : hardware]
                        let node = SCNNode(geometry: post)
                        node.simdPosition = SIMD3<Float>(
                            platePosition.x + x,
                            supportCenterY,
                            platePosition.z + z)
                        root.addChildNode(node)
                    }
                }

            case .top, .automatic, .bottom:
                let plateFaceY = platePosition.y
                    + (isBottom ? plateThickness * 0.5 : -plateThickness * 0.5)
                let frameFaceY = isBottom ? support.bottom : support.top
                let supportHeight = abs(frameFaceY - plateFaceY)
                guard supportHeight > 0.00025 else { return }
                let supportCenterY = (frameFaceY + plateFaceY) * 0.5
                let xInset = max(halfPlateX - 0.003, 0.0015)
                let zInset = max(halfPlateZ - 0.003, 0.0015)
                for x in [-xInset, xInset] {
                    for z in [-zInset, zInset] {
                        let post = SCNCylinder(
                            radius: frame.frameClass == .tinyWhoop ? 0.00065 : 0.00105,
                            height: CGFloat(supportHeight))
                        post.radialSegmentCount = 14
                        post.materials = [kind == .battery ? hardware : rubber]
                        let node = SCNNode(geometry: post)
                        node.simdPosition = SIMD3<Float>(
                            placement.position.x + x,
                            supportCenterY,
                            placement.position.z + z)
                        root.addChildNode(node)
                    }
                }

            case .left, .right:
                let isLeft = placement.surface == .left
                let plateInnerX = platePosition.x + (isLeft ? halfPlateX : -halfPlateX)
                let frameEdgeX: Float = (isLeft ? -1 : 1) * support.width * 0.5
                let beamY = platePosition.y
                for zOffset in [-halfPlateZ * 0.58, halfPlateZ * 0.58] {
                    root.addChildNode(flatBeamNode(
                        from: SIMD3<Float>(frameEdgeX, beamY, platePosition.z + zOffset),
                        to: SIMD3<Float>(plateInnerX, beamY, platePosition.z + zOffset),
                        width: connectorWidth,
                        height: plateThickness,
                        material: plateMaterial))
                }

            case .front, .rear:
                let isFront = placement.surface == .front
                let plateInnerZ = platePosition.z + (isFront ? -halfPlateZ : halfPlateZ)
                let frameEdgeZ = isFront ? support.frontZ : support.rearZ
                let beamY = platePosition.y
                for xOffset in [-halfPlateX * 0.58, halfPlateX * 0.58] {
                    root.addChildNode(flatBeamNode(
                        from: SIMD3<Float>(platePosition.x + xOffset, beamY, frameEdgeZ),
                        to: SIMD3<Float>(platePosition.x + xOffset, beamY, plateInnerZ),
                        width: connectorWidth,
                        height: plateThickness,
                        material: plateMaterial))
                }
            }
        }

        switch kind {
        case .battery:
            let plate = plateNode(extraX: 0.010, extraZ: 0.008)
            root.addChildNode(plate)
            connectPlateToFrame(plate, extraX: 0.010, extraZ: 0.008)
            let outerY = placement.position.y
                + (isBottom ? -size.y * 0.5 - 0.0007 : size.y * 0.5 + 0.0007)
            let innerY = placement.position.y
                + (isBottom ? size.y * 0.5 + 0.0002 : -size.y * 0.5 - 0.0002)
            for z in [-size.z * 0.24, size.z * 0.24] {
                // Two crosswise straps loop around the pack and terminate in
                // visible cam buckles. They work for both top and belly trays.
                let strap = SCNBox(
                    width: CGFloat(size.x + 0.010), height: 0.0013,
                    length: 0.006, chamferRadius: 0.0006)
                strap.materials = [wovenStrapMaterial("#B33A32")]
                let strapNode = SCNNode(geometry: strap)
                strapNode.simdPosition = SIMD3<Float>(
                    placement.position.x, outerY, placement.position.z + z)
                root.addChildNode(strapNode)

                let sideHeight = abs(outerY - innerY)
                for side: Float in [-1, 1] {
                    let leg = SCNBox(
                        width: 0.0014,
                        height: CGFloat(sideHeight),
                        length: 0.006,
                        chamferRadius: 0.0005)
                    leg.materials = [wovenStrapMaterial("#B33A32")]
                    let legNode = SCNNode(geometry: leg)
                    legNode.simdPosition = SIMD3<Float>(
                        placement.position.x + side * (size.x * 0.5 + 0.0037),
                        (outerY + innerY) * 0.5,
                        placement.position.z + z)
                    root.addChildNode(legNode)
                }

                let buckle = SCNBox(
                    width: 0.010, height: 0.0022, length: 0.0068,
                    chamferRadius: 0.0005)
                buckle.materials = [hardware]
                let buckleNode = SCNNode(geometry: buckle)
                buckleNode.simdPosition = SIMD3<Float>(
                    placement.position.x + size.x * 0.25,
                    outerY + (isBottom ? -0.0010 : 0.0010),
                    placement.position.z + z)
                root.addChildNode(buckleNode)

                let latch = SCNBox(
                    width: 0.0072, height: 0.0012, length: 0.0045,
                    chamferRadius: 0.00035)
                latch.materials = [rubber]
                let latchNode = SCNNode(geometry: latch)
                latchNode.simdPosition = SIMD3<Float>(
                    placement.position.x + size.x * 0.25,
                    outerY + (isBottom ? -0.0023 : 0.0023),
                    placement.position.z + z)
                root.addChildNode(latchNode)
            }
            for z in [-size.z * 0.5 - 0.003, size.z * 0.5 + 0.003] {
                let rail = SCNBox(
                    width: CGFloat(size.x + 0.008), height: 0.003,
                    length: 0.003, chamferRadius: 0.0007)
                rail.materials = [rubber]
                let railNode = SCNNode(geometry: rail)
                railNode.simdPosition = SIMD3<Float>(
                    placement.position.x,
                    placement.position.y + (isBottom ? size.y * 0.5 + 0.001 : -size.y * 0.5 - 0.001),
                    placement.position.z + z)
                root.addChildNode(railNode)
            }

            if isBottom {
                // A belly pack must never become the point on which the
                // aircraft rests. Two protective skids extend below it and
                // define the model's true table-contact plane.
                let packBottom = placement.position.y - size.y * 0.5
                let skidY = packBottom - 0.012
                let skidLength = max(size.z + 0.026, 0.085)
                for x: Float in [-1, 1] {
                    let skidX = placement.position.x
                        + x * (size.x * 0.5 + 0.010)
                    let skid = SCNCapsule(
                        capRadius: 0.0022,
                        height: CGFloat(skidLength))
                    skid.radialSegmentCount = 18
                    skid.capSegmentCount = 6
                    skid.materials = [rubber]
                    let skidNode = SCNNode(geometry: skid)
                    skidNode.eulerAngles.x = .pi / 2
                    skidNode.simdPosition = SIMD3<Float>(
                        skidX, skidY, placement.position.z)
                    root.addChildNode(skidNode)

                    for z: Float in [-1, 1] {
                        root.addChildNode(beamNode(
                            from: SIMD3<Float>(
                                placement.position.x
                                    + x * (size.x * 0.5 + 0.003),
                                support.bottom,
                                placement.position.z + z * size.z * 0.38),
                            to: SIMD3<Float>(
                                skidX,
                                skidY,
                                placement.position.z + z * size.z * 0.38),
                            radius: 0.0015,
                            material: hardware))
                    }
                }
            }

        case .gps:
            let plate = plateNode(extraX: 0.006, extraZ: 0.006)
            root.addChildNode(plate)
            let plateBottom = plate.simdPosition.y - plateThickness * 0.5
            let anchorY: Float
            if frame.architecture == .multicopter {
                anchorY = support.top
            } else {
                // Wing skin, not fuselage roof: the GNSS pad sits in the
                // clear RF zone selected by the layout resolver.
                let span = max(Float(frame.sizeMeters.x), 0.45)
                let length = max(Float(frame.sizeMeters.z), 0.36)
                let area = max(Float(frame.wingAreaM2), span * length * 0.18)
                let chord = min(max(area / span, length * 0.20), length * 0.52)
                anchorY = min(max(chord * 0.055, 0.010), 0.024) * 0.5
            }
            let mastHeight = max(plateBottom - anchorY, 0.003)
            let mast = SCNCylinder(
                radius: frame.frameClass == .tinyWhoop ? 0.0010 : 0.0022,
                height: CGFloat(mastHeight))
            mast.radialSegmentCount = 20
            mast.materials = [carbonFiberMaterial()]
            let mastNode = SCNNode(geometry: mast)
            mastNode.simdPosition = SIMD3<Float>(
                placement.position.x,
                anchorY + mastHeight * 0.5,
                placement.position.z)
            root.addChildNode(mastNode)

            let foot = SCNCylinder(
                radius: CGFloat(max(min(size.x * 0.36, 0.012), 0.005)),
                height: CGFloat(plateThickness))
            foot.radialSegmentCount = 24
            foot.materials = [plateMaterial]
            let footNode = SCNNode(geometry: foot)
            footNode.simdPosition = SIMD3<Float>(
                placement.position.x,
                anchorY + plateThickness * 0.5,
                placement.position.z)
            root.addChildNode(footNode)

        case .receiver:
            // RX body is retained inside the protected bay on a thin foam
            // cradle. Antennas are routed separately to external clips.
            let plate = plateNode(extraX: 0.004, extraZ: 0.004)
            plate.geometry?.materials = [rubber]
            root.addChildNode(plate)
            connectPlateToFrame(plate, extraX: 0.004, extraZ: 0.004)
            for z: Float in [-0.32, 0.32] {
                let tie = SCNBox(
                    width: CGFloat(size.x + 0.005),
                    height: 0.0008,
                    length: 0.0015,
                    chamferRadius: 0.00035)
                tie.materials = [wovenStrapMaterial("#30353B")]
                let tieNode = SCNNode(geometry: tie)
                tieNode.simdPosition = SIMD3<Float>(
                    placement.position.x,
                    placement.position.y + size.y * 0.5 + 0.0003,
                    placement.position.z + z * size.z)
                root.addChildNode(tieNode)
            }

        case .landingGear:
            // The five gear renderers do not share a proxy-box top: guards
            // meet the aircraft at the torus, bumpers at capsule caps, skids
            // at four beam ends and retracts at two pivot housings. Attach to
            // those authored hard-points and clamp the belly ends inside the
            // real central support envelope. This leaves the payload bay open
            // while making every visible leg trace back to structure.
            let attachments = WorkbenchBuildAnalyzer.landingGearAttachmentLayout(for: spec)
            let isMicro = frame.frameClass == .tinyWhoop
            let padWidth: Float = isMicro
                ? 0.0045
                : min(max(size.x * 0.055, 0.007), 0.016)
            let padLength: Float = isMicro
                ? 0.0055
                : min(max(size.z * 0.10, 0.009), 0.016)
            let braceRadius: Float = isMicro ? 0.00065 : 0.00115
            let supportHalfX = max(support.width * 0.5 - padWidth * 0.55, 0)
            let supportHalfZ = max((support.frontZ - support.rearZ) * 0.5, 0)
            let supportCenterZ = (support.frontZ + support.rearZ) * 0.5
            let supportInsetZ = min(padLength * 0.55, supportHalfZ * 0.72)
            let anchorMinZ = support.rearZ + supportInsetZ
            let anchorMaxZ = support.frontZ - supportInsetZ

            func clamp(_ value: Float, lower: Float, upper: Float) -> Float {
                guard lower <= upper else { return (lower + upper) * 0.5 }
                return min(max(value, lower), upper)
            }

            for (index, localRoot) in attachments.rootPoints.enumerated() {
                let gearRoot = placement.position + localRoot
                let anchorX = clamp(
                    gearRoot.x,
                    lower: -supportHalfX,
                    upper: supportHalfX)
                let anchorZ = supportHalfZ > 0
                    ? clamp(gearRoot.z, lower: anchorMinZ, upper: anchorMaxZ)
                    : supportCenterZ
                let bellyAnchor = SIMD3<Float>(
                    anchorX,
                    support.bottom - plateThickness * 0.5,
                    anchorZ)
                let rootAnchor = SIMD3<Float>(
                    gearRoot.x,
                    gearRoot.y + plateThickness * 0.5,
                    gearRoot.z)

                let bellyPad = SCNBox(
                    width: CGFloat(padWidth),
                    height: CGFloat(plateThickness),
                    length: CGFloat(padLength),
                    chamferRadius: CGFloat(min(plateThickness * 0.38, 0.0008)))
                bellyPad.materials = [plateMaterial]
                let bellyPadNode = SCNNode(geometry: bellyPad)
                bellyPadNode.name = "workbench.gear.bellyPad.\(index)"
                bellyPadNode.simdPosition = bellyAnchor
                root.addChildNode(bellyPadNode)

                let rootPad = SCNBox(
                    width: CGFloat(padWidth * 0.82),
                    height: CGFloat(plateThickness),
                    length: CGFloat(padLength * 0.82),
                    chamferRadius: CGFloat(min(plateThickness * 0.34, 0.0007)))
                rootPad.materials = [hardware]
                let rootPadNode = SCNNode(geometry: rootPad)
                rootPadNode.name = "workbench.gear.rootPad.\(index)"
                rootPadNode.simdPosition = rootAnchor
                root.addChildNode(rootPadNode)

                let brace = beamNode(
                    from: bellyAnchor,
                    to: rootAnchor,
                    radius: braceRadius,
                    material: hardware)
                brace.name = "workbench.gear.brace.\(index)"
                root.addChildNode(brace)
            }

        default:
            let plate = plateNode()
            root.addChildNode(plate)
            connectPlateToFrame(plate)

            if kind == .servo {
                for z in [-size.z * 0.5 - 0.003, size.z * 0.5 + 0.003] {
                    let ear = SCNBox(width: 0.007, height: 0.0016, length: 0.006, chamferRadius: 0.0004)
                    ear.materials = [hardware]
                    let node = SCNNode(geometry: ear)
                    node.simdPosition = SIMD3<Float>(
                        placement.position.x,
                        placement.position.y - size.y * 0.5 - 0.001,
                        placement.position.z + z)
                    root.addChildNode(node)
                }
            }
        }
        return root
    }

    private static func cablePolylineNode(
        _ points: [SIMD3<Float>],
        radius: Float,
        material cableMaterial: SCNMaterial
    ) -> SCNNode {
        let root = SCNNode()
        guard points.count >= 2 else { return root }
        for index in 0..<(points.count - 1) {
            guard simd_distance(points[index], points[index + 1]) > 0.0002 else { continue }
            root.addChildNode(beamNode(
                from: points[index],
                to: points[index + 1],
                radius: radius,
                material: cableMaterial))
        }
        return root
    }

    private static func powerHarnessNode(
        battery: WorkbenchResolvedComponentPlacement,
        esc: WorkbenchResolvedComponentPlacement,
        frame: WorkbenchResolvedFrame
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.harness.power"
        let support = WorkbenchBuildAnalyzer.mountingEnvelope(for: frame)
        let exitZ = battery.position.z - battery.size.z * 0.49
        let routeX = min(
            max(battery.size.x * 0.5 + 0.004, support.width * 0.34),
            max(support.width * 0.47, 0.014))
        let routeY: Float
        if battery.surface == .bottom {
            routeY = min(battery.position.y, esc.position.y) - 0.002
        } else if battery.surface == .internalBay {
            routeY = max(support.bottom + 0.005, min(battery.position.y, esc.position.y))
        } else {
            routeY = min(battery.position.y - battery.size.y * 0.35, support.top + 0.004)
        }

        let colors = ["#202327", "#C94A43"]
        for (index, color) in colors.enumerated() {
            let separation: Float = index == 0 ? -0.0018 : 0.0018
            let start = SIMD3<Float>(
                battery.position.x + separation,
                battery.position.y,
                exitZ)
            let channelX = battery.position.x + routeX + separation
            let points = [
                start,
                SIMD3<Float>(channelX, routeY, exitZ - 0.004),
                SIMD3<Float>(channelX, routeY, esc.position.z),
                SIMD3<Float>(esc.position.x + separation * 1.6,
                             esc.position.y,
                             esc.position.z),
            ]
            root.addChildNode(cablePolylineNode(
                points,
                radius: 0.00105,
                material: material(color, metalness: 0.01, roughness: 0.78)))
        }

        // Fixed XT holder: the connector is no longer a loose block at the
        // end of two unsupported wires.
        let connector = SCNBox(
            width: 0.012,
            height: 0.007,
            length: 0.009,
            chamferRadius: 0.0012)
        connector.materials = [material("#D8A52D", metalness: 0.05, roughness: 0.56)]
        let connectorNode = SCNNode(geometry: connector)
        connectorNode.simdPosition = SIMD3<Float>(
            battery.position.x,
            battery.position.y,
            exitZ - 0.002)
        root.addChildNode(connectorNode)

        for z in [exitZ - 0.004, esc.position.z] {
            let clip = SCNBox(
                width: 0.007,
                height: 0.0012,
                length: 0.003,
                chamferRadius: 0.0005)
            clip.materials = [rubberMaterial("#24292E")]
            let clipNode = SCNNode(geometry: clip)
            clipNode.simdPosition = SIMD3<Float>(
                battery.position.x + routeX,
                routeY - 0.001,
                z)
            root.addChildNode(clipNode)
        }
        return root
    }

    private static func receiverAntennaHarnessNode(
        receiver: WorkbenchResolvedComponentPlacement,
        frame: WorkbenchResolvedFrame
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.harness.receiver"
        let support = WorkbenchBuildAnalyzer.mountingEnvelope(for: frame)
        let coax = rubberMaterial("#22272C")
        let active = material("#C9C1AD", metalness: 0.08, roughness: 0.66)

        let firstStart: SIMD3<Float>
        let firstEnd: SIMD3<Float>
        let secondStart: SIMD3<Float>
        let secondEnd: SIMD3<Float>
        if frame.architecture == .multicopter {
            let y = max(support.bottom + 0.006, receiver.position.y)
            let rear = support.rearZ - 0.010
            firstStart = SIMD3<Float>(-support.width * 0.18, y, rear)
            firstEnd = SIMD3<Float>(-support.width * 0.18 - 0.030, y, rear)
            secondStart = SIMD3<Float>(support.width * 0.18, y, rear)
            secondEnd = SIMD3<Float>(support.width * 0.18, y, rear - 0.030)
        } else {
            let span = max(Float(frame.sizeMeters.x), 0.45)
            let length = max(Float(frame.sizeMeters.z), 0.36)
            let y = max(0.002, receiver.position.y)
            firstStart = SIMD3<Float>(-support.width * 0.52, y, -length * 0.22)
            firstEnd = SIMD3<Float>(-min(span * 0.24, 0.34), y, -length * 0.22)
            secondStart = SIMD3<Float>(support.width * 0.26, y, -length * 0.28)
            secondEnd = SIMD3<Float>(support.width * 0.26, y + 0.018, -length * 0.40)
        }

        let bodyExit = receiver.position + SIMD3<Float>(0, 0, -receiver.size.z * 0.45)
        for (index, pair) in [(firstStart, firstEnd), (secondStart, secondEnd)].enumerated() {
            let spread: Float = index == 0 ? -0.0015 : 0.0015
            let routeStart = bodyExit + SIMD3<Float>(spread, 0, 0)
            root.addChildNode(cablePolylineNode(
                [routeStart,
                 SIMD3<Float>(pair.0.x, routeStart.y, pair.0.z),
                 pair.0],
                radius: 0.00048,
                material: coax))
            root.addChildNode(cablePolylineNode(
                [pair.0, pair.1],
                radius: 0.00068,
                material: active))

            for point in [pair.0, pair.1] {
                let clip = SCNSphere(radius: 0.00125)
                clip.segmentCount = 12
                clip.materials = [rubberMaterial("#30363C")]
                let clipNode = SCNNode(geometry: clip)
                clipNode.simdPosition = point
                root.addChildNode(clipNode)
            }
        }
        return root
    }

    private static func signalHarnessNode(
        from peripheral: WorkbenchResolvedComponentPlacement,
        to controller: WorkbenchResolvedComponentPlacement,
        frame: WorkbenchResolvedFrame
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.harness.signal.\(peripheral.kind.rawValue)"
        let support = WorkbenchBuildAnalyzer.mountingEnvelope(for: frame)
        let surfaceY: Float
        switch peripheral.surface {
        case .bottom:
            surfaceY = support.bottom - 0.0015
        case .top, .automatic:
            surfaceY = frame.architecture == .multicopter ? support.top + 0.0015 : 0.008
        case .internalBay:
            surfaceY = peripheral.position.y
        case .front, .rear, .left, .right:
            surfaceY = min(peripheral.position.y, support.top)
        }
        let bodyEdgeX = peripheral.position.x == 0
            ? support.width * 0.34
            : copysignf(support.width * 0.48, peripheral.position.x)
        let points = [
            peripheral.position,
            SIMD3<Float>(bodyEdgeX, surfaceY, peripheral.position.z),
            SIMD3<Float>(bodyEdgeX, controller.position.y, controller.position.z),
            controller.position,
        ]
        root.addChildNode(cablePolylineNode(
            points,
            radius: 0.00050,
            material: material("#667787", metalness: 0.02, roughness: 0.76)))
        return root
    }

    static func previewNode(for frame: WorkbenchFrameSpec) -> SCNNode {
        frameNode(WorkbenchFrameSource.library(id: frame.id).resolve())
    }

    static func previewNode(for spec: WorkbenchComponentSpec) -> SCNNode {
        componentNode(spec)
    }

    /// Adapts the exact editor assembly to the simulation visual contract.
    /// SceneController can therefore animate the selected propellers, place
    /// cameras and apply damage without substituting an abstract airframe.
    static func simulationVisual(for build: WorkbenchBuild) -> DroneVisualModel {
        let root = aircraftNode(for: build, selectedCategory: nil, showsHotspots: false)
        root.name = "workbench.simulation.aircraft"

        func nodes(withPrefix prefix: String) -> [SCNNode] {
            var matches: [SCNNode] = []
            root.enumerateChildNodes { node, _ in
                if node.name?.hasPrefix(prefix) == true { matches.append(node) }
            }
            return matches.sorted { ($0.name ?? "") < ($1.name ?? "") }
        }

        let motorNodes = nodes(withPrefix: "\(slotNodePrefix)motor.")
        let propellerNodes = nodes(withPrefix: "\(slotNodePrefix)propeller.")
        let spinDirections = propellerNodes.indices.map { $0.isMultiple(of: 2) ? Float(1) : Float(-1) }
        var damageNodes: [DamageComponent: [SCNNode]] = [:]
        if let node = root.childNode(withName: "\(slotNodePrefix)battery", recursively: true) {
            damageNodes[.battery] = [node]
        }
        if let node = root.childNode(withName: "\(slotNodePrefix)camera", recursively: true) {
            damageNodes[.frontCameraGimbal] = [node]
        }
        if let node = root.childNode(withName: "\(slotNodePrefix)flightController", recursively: true) {
            damageNodes[.flightControllerCore] = [node]
        }
        if let node = root.childNode(withName: "\(slotNodePrefix)esc", recursively: true) {
            damageNodes[.escPower] = [node]
        }
        let motorDamage: [DamageComponent] = [.motorFL, .motorFR, .motorRL, .motorRR]
        let propDamage: [DamageComponent] = [.propellerFL, .propellerFR, .propellerRL, .propellerRR]
        for (index, node) in motorNodes.prefix(4).enumerated() {
            damageNodes[motorDamage[index]] = [node]
        }
        for (index, node) in propellerNodes.prefix(4).enumerated() {
            damageNodes[propDamage[index]] = [node]
        }

        let layout = WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)
        let fpvAnchor = SCNNode()
        fpvAnchor.name = "workbench.fpvAnchor"
        if let camera = layout[.camera] {
            fpvAnchor.simdPosition = camera.position + SIMD3<Float>(0, 0, camera.size.z * 0.58)
            // SceneKit cameras look down -Z; the physical Workbench lens is +Z.
            fpvAnchor.eulerAngles.y = .pi
        } else {
            fpvAnchor.simdPosition = build.resolvedFrame.cameraMount
            fpvAnchor.eulerAngles.y = .pi
        }
        root.addChildNode(fpvAnchor)

        let payloadMount = SCNNode()
        payloadMount.name = "workbench.payloadMount"
        if let payload = layout[.payload] {
            payloadMount.simdPosition = payload.position + SIMD3<Float>(0, -payload.size.y * 0.55, 0)
        } else {
            payloadMount.simdPosition = SIMD3<Float>(0, -0.025, 0)
        }
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellerNodes,
            propellerSpinDirections: spinDirections,
            componentNodes: damageNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMount)
    }

    // MARK: Frame

    static func frameNode(_ frame: WorkbenchResolvedFrame) -> SCNNode {
        let root = SCNNode()
        if let mesh = frame.importedMesh, let geometry = geometry(from: mesh, convertsCADCoordinates: true) {
            let importedMaterial = material("#7E8895", metalness: 0.45, roughness: 0.38)
            importedMaterial.isDoubleSided = true
            geometry.materials = [importedMaterial]
            root.addChildNode(SCNNode(geometry: geometry))
            return root
        }

        if frame.architecture != .multicopter {
            return liftingAirframeNode(frame)
        }

        let carbon = carbonFiberMaterial()
        let carbonEdge = material("#111419", metalness: 0.18, roughness: 0.56)
        let hardware = material("#9CA5AE", metalness: 0.82, roughness: 0.22)
        let accentHex: String
        switch frame.frameClass {
        case .tinyWhoop: accentHex = "#4F8DA1"
        case .fiveInch: accentHex = "#3E677F"
        case .sevenInch: accentHex = "#8B6A36"
        case .cinematic: accentHex = "#7B4040"
        case .fixedWing: accentHex = "#426E86"
        case .vtol: accentHex = "#5B6E47"
        }
        let accent = material(accentHex, metalness: 0.52, roughness: 0.30)

        let arm = Float(frame.armLengthM)
        let isMicro = frame.frameClass == .tinyWhoop
        let support = WorkbenchBuildAnalyzer.mountingEnvelope(for: frame)
        let deckWidth = CGFloat(isMicro ? max(arm * 0.78, 0.026) : min(max(arm * 0.54, 0.060), 0.092))
        let deckLength = CGFloat(isMicro ? max(arm * 0.92, 0.030) : min(max(arm * 0.68, 0.076), 0.116))
        let lowerPlate = SCNBox(
            width: deckWidth,
            height: isMicro ? 0.0022 : 0.0042,
            length: deckLength,
            chamferRadius: isMicro ? 0.002 : 0.005)
        lowerPlate.materials = [carbon]
        root.addChildNode(SCNNode(geometry: lowerPlate))

        let upperPlate = SCNBox(
            width: deckWidth * 0.84,
            height: isMicro ? 0.0018 : 0.0030,
            length: deckLength * 0.76,
            chamferRadius: isMicro ? 0.0015 : 0.004)
        upperPlate.materials = [carbonEdge]
        let upperNode = SCNNode(geometry: upperPlate)
        upperNode.simdPosition.y = support.top - Float(upperPlate.height) * 0.5
        root.addChildNode(upperNode)

        let armWidth = isMicro ? max(arm * 0.11, 0.0032) : max(arm * 0.095, 0.0090)
        let armHeight: Float = isMicro ? 0.0022 : 0.0045
        let motorPadRadius = max(0.007, Float(frame.motorStatorMaxMm / 2000) + 0.003)
        let wireRed = material("#B9463F", metalness: 0.02, roughness: 0.74)
        let wireBlack = material("#14171A", metalness: 0.02, roughness: 0.78)

        for mount in frame.motorMounts {
            let flatMount = SIMD3<Float>(mount.x, 0, mount.z)
            let direction = simd_normalize(flatMount)
            let inner = direction * Float(deckWidth * 0.34)
            root.addChildNode(flatBeamNode(
                from: inner,
                to: flatMount,
                width: armWidth,
                height: armHeight,
                material: carbon))

            let pad = SCNCylinder(radius: CGFloat(motorPadRadius), height: CGFloat(armHeight))
            pad.radialSegmentCount = 28
            pad.materials = [carbon]
            let padNode = SCNNode(geometry: pad)
            padNode.simdPosition = flatMount
            root.addChildNode(padNode)

            if !isMicro {
                let lateral = SIMD3<Float>(-direction.z, 0, direction.x) * 0.0014
                let wireStart = inner + direction * 0.006
                let wireEnd = flatMount - direction * (motorPadRadius * 0.65)
                root.addChildNode(beamNode(
                    from: wireStart + lateral + SIMD3<Float>(0, armHeight * 0.66, 0),
                    to: wireEnd + lateral + SIMD3<Float>(0, armHeight * 0.66, 0),
                    radius: 0.00055,
                    material: wireRed))
                root.addChildNode(beamNode(
                    from: wireStart - lateral + SIMD3<Float>(0, armHeight * 0.66, 0),
                    to: wireEnd - lateral + SIMD3<Float>(0, armHeight * 0.66, 0),
                    radius: 0.00055,
                    material: wireBlack))
            }

            for angle in stride(from: Float.pi * 0.25, to: Float.pi * 2, by: Float.pi * 0.5) {
                let screw = SCNCylinder(radius: isMicro ? 0.00055 : 0.0010,
                                        height: isMicro ? 0.0007 : 0.0010)
                screw.radialSegmentCount = 16
                screw.materials = [hardware]
                let screwNode = SCNNode(geometry: screw)
                screwNode.simdPosition = flatMount + SIMD3<Float>(
                    cos(angle) * motorPadRadius * 0.55,
                    armHeight * 0.62,
                    sin(angle) * motorPadRadius * 0.55)
                root.addChildNode(screwNode)
            }

            let hasPropGuards = frame.frameClass == .tinyWhoop
                || (frame.frameClass == .cinematic && frame.propMaxInch <= 3.5)
            if hasPropGuards {
                let propRadius = Float(frame.propMaxInch * 0.0254 * 0.5)
                let ductThickness: Float = isMicro ? 0.0015 : 0.0023
                let innerRadius = propRadius * 1.045
                let ductHeight: Float = isMicro ? 0.006 : 0.010
                let duct = SCNTube(
                    innerRadius: CGFloat(innerRadius),
                    outerRadius: CGFloat(innerRadius + ductThickness * 1.75),
                    height: CGFloat(ductHeight))
                duct.radialSegmentCount = 56
                duct.heightSegmentCount = 2
                duct.materials = [accent]
                let ductNode = SCNNode(geometry: duct)
                ductNode.simdPosition = flatMount + SIMD3<Float>(0, isMicro ? 0.018 : 0.021, 0)
                root.addChildNode(ductNode)
            }
        }

        // Four real stack standoffs and screw heads replace the former solid
        // silver block and give the frame a readable layered construction.
        let standoffHeight = CGFloat(max(
            support.top - Float(upperPlate.height),
            isMicro ? 0.006 : 0.018))
        for x in [-Float(deckWidth) * 0.31, Float(deckWidth) * 0.31] {
            for z in [-Float(deckLength) * 0.25, Float(deckLength) * 0.25] {
                let post = SCNCylinder(radius: isMicro ? 0.0007 : 0.00145,
                                       height: standoffHeight)
                post.radialSegmentCount = 18
                post.materials = [accent]
                let postNode = SCNNode(geometry: post)
                postNode.simdPosition = SIMD3<Float>(x, Float(standoffHeight * 0.5), z)
                root.addChildNode(postNode)

                let screw = SCNCylinder(radius: isMicro ? 0.0010 : 0.0020, height: 0.0010)
                screw.radialSegmentCount = 20
                screw.materials = [hardware]
                let screwNode = SCNNode(geometry: screw)
                screwNode.simdPosition = SIMD3<Float>(x, support.top + 0.0005, z)
                root.addChildNode(screwNode)
            }
        }

        // Camera cage. Battery retention belongs to the selected battery bay,
        // so an empty frame no longer carries a floating decorative strap.
        if !isMicro {
            for x in [-Float(deckWidth) * 0.34, Float(deckWidth) * 0.34] {
                let post = SCNCylinder(radius: 0.00155, height: 0.028)
                post.radialSegmentCount = 20
                post.materials = [accent]
                let postNode = SCNNode(geometry: post)
                postNode.simdPosition = SIMD3<Float>(x, 0.014, Float(deckLength) * 0.34)
                root.addChildNode(postNode)
            }
        }
        return root
    }

    /// Builds an aircraft-shaped lifting frame instead of stretching the quad
    /// deck/arm recipe over fixed-wing dimensions. +Z is the nose direction,
    /// matching `WorkbenchResolvedFrame.propulsionAxes`.
    private static func liftingAirframeNode(_ frame: WorkbenchResolvedFrame) -> SCNNode {
        let root = SCNNode()
        let span = max(Float(frame.sizeMeters.x), 0.45)
        let height = max(Float(frame.sizeMeters.y), 0.08)
        let length = max(Float(frame.sizeMeters.z), 0.36)
        let referenceArea = max(Float(frame.wingAreaM2), span * length * 0.18)
        let meanChord = min(max(referenceArea / span, length * 0.20), length * 0.52)
        let rootChord = min(meanChord * 1.28, length * 0.54)
        let tipChord = max(meanChord * 0.58, length * 0.12)
        let halfSpan = span * 0.5
        let bodyRadius = min(
            max(height * 0.23, span * 0.025),
            max(meanChord * 0.21, 0.038))
        let wingThickness = min(max(meanChord * 0.055, 0.010), 0.024)

        let skin = material("#C7CED4", metalness: 0.04, roughness: 0.64)
        skin.clearCoat.contents = NSNumber(value: 0.08)
        skin.clearCoatRoughness.contents = NSNumber(value: 0.52)
        let underside = material("#A9B3BC", metalness: 0.04, roughness: 0.70)
        let accentHex = frame.architecture == .liftCruiseVTOL ? "#607E72" : "#3E728F"
        let accent = material(accentHex, metalness: 0.12, roughness: 0.48)
        let carbon = carbonFiberMaterial()
        let hardware = material("#8D969E", metalness: 0.78, roughness: 0.25)

        // Main lifting surface: a tapered, swept planform derived from the
        // physical span and reference wing area, not a scaled quad plate.
        let leadingRoot = length * 0.16
        let leadingTip = length * 0.035
        let rootInset = max(bodyRadius * 0.70, 0.022)
        let wingPoints: [SIMD2<Float>] = [
            SIMD2(-halfSpan, leadingTip - tipChord),
            SIMD2(-halfSpan, leadingTip),
            SIMD2(-rootInset, leadingRoot),
            SIMD2(rootInset, leadingRoot),
            SIMD2(halfSpan, leadingTip),
            SIMD2(halfSpan, leadingTip - tipChord),
            SIMD2(rootInset, leadingRoot - rootChord),
            SIMD2(-rootInset, leadingRoot - rootChord),
        ]
        let wing = horizontalPlanformNode(
            points: wingPoints,
            thickness: wingThickness,
            material: skin)
        wing.name = "workbench.airframe.wing"
        root.addChildNode(wing)

        let wingSpar = SCNBox(
            width: CGFloat(span * 0.76),
            height: CGFloat(max(wingThickness * 0.24, 0.003)),
            length: CGFloat(max(meanChord * 0.075, 0.018)),
            chamferRadius: 0.0015)
        wingSpar.materials = [carbon]
        let wingSparNode = SCNNode(geometry: wingSpar)
        wingSparNode.simdPosition = SIMD3<Float>(
            0,
            wingThickness * 0.5 + max(wingThickness * 0.13, 0.0015),
            leadingRoot - rootChord * 0.39)
        wingSparNode.name = "workbench.airframe.wingSpar"
        root.addChildNode(wingSparNode)

        // Separate ailerons keep the aircraft readable as a controllable
        // fixed-wing vehicle, and visually relate to the outboard servos.
        for side: Float in [-1, 1] {
            let aileron = SCNBox(
                width: CGFloat(span * 0.205),
                height: CGFloat(max(wingThickness * 0.22, 0.0025)),
                length: CGFloat(max(tipChord * 0.16, 0.018)),
                chamferRadius: 0.0013)
            aileron.materials = [accent]
            let node = SCNNode(geometry: aileron)
            node.simdPosition = SIMD3<Float>(
                side * span * 0.34,
                wingThickness * 0.58,
                leadingTip - tipChord * 0.88)
            node.name = side < 0
                ? "workbench.airframe.aileron.left"
                : "workbench.airframe.aileron.right"
            root.addChildNode(node)
        }

        // Fuselage and nose are their own assembly, overlaid on the continuous
        // wing root. A shallow belly fairing leaves room for bottom-mounted
        // cameras and payloads resolved by the common placement engine.
        let fuselageLength = length * 0.78
        let fuselageCenterZ = -length * 0.015
        let fuselage = SCNCapsule(
            capRadius: CGFloat(bodyRadius),
            height: CGFloat(max(fuselageLength, bodyRadius * 2.15)))
        fuselage.radialSegmentCount = 36
        fuselage.capSegmentCount = 12
        fuselage.materials = [underside]
        let fuselageNode = SCNNode(geometry: fuselage)
        fuselageNode.eulerAngles.x = .pi / 2
        fuselageNode.simdPosition = SIMD3<Float>(0, bodyRadius * 0.12, fuselageCenterZ)
        fuselageNode.name = "workbench.airframe.fuselage"
        root.addChildNode(fuselageNode)

        // A tractor motor needs a flat firewall.  The former zero-radius cone
        // stopped several centimetres before the authored motor mount, leaving
        // the motor visibly balanced on an isolated point.  Extend a truncated
        // fairing to the real cruise mount and close it with a rigid bulkhead;
        // the motor's zero plane now lands directly on that front face.
        let cruiseMount = frame.motorMounts.enumerated()
            .filter { propulsionAxis(for: frame, index: $0.offset).z > 0.65 }
            .max { $0.element.z < $1.element.z }?
            .element
        let legacyNoseLength = max(length * 0.10, 0.055)
        let fallbackFirewallZ = fuselageCenterZ + fuselageLength * 0.5
            + legacyNoseLength * 0.92
        let firewallFrontZ = cruiseMount?.z ?? fallbackFirewallZ
        let firewallCenterY = cruiseMount?.y ?? bodyRadius * 0.12
        let firewallThickness = max(bodyRadius * 0.10, 0.0042)
        let noseFrontZ = firewallFrontZ - firewallThickness
        let fuselageFrontZ = fuselageCenterZ + fuselageLength * 0.5
        let noseRearZ = fuselageFrontZ - bodyRadius * 0.20
        let noseRearCenter = SIMD3<Float>(0, bodyRadius * 0.12, noseRearZ)
        let noseFrontCenter = SIMD3<Float>(0, firewallCenterY, noseFrontZ)
        let noseVector = noseFrontCenter - noseRearCenter
        let noseLength = max(simd_length(noseVector), 0.010)
        let firewallRadius = min(
            max(Float(frame.motorStatorMaxMm) * 0.0005 + 0.003, bodyRadius * 0.42),
            bodyRadius * 0.72)
        let nose = SCNCone(
            topRadius: CGFloat(firewallRadius * 0.94),
            bottomRadius: CGFloat(bodyRadius * 0.90),
            height: CGFloat(noseLength))
        nose.radialSegmentCount = 36
        nose.materials = [accent]
        let noseNode = SCNNode(geometry: nose)
        noseNode.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: simd_normalize(noseVector))
        noseNode.simdPosition = (noseRearCenter + noseFrontCenter) * 0.5
        noseNode.name = "workbench.airframe.nose"
        root.addChildNode(noseNode)

        let firewall = SCNCylinder(
            radius: CGFloat(firewallRadius),
            height: CGFloat(firewallThickness))
        firewall.radialSegmentCount = 36
        firewall.materials = [carbon]
        let firewallNode = SCNNode(geometry: firewall)
        firewallNode.eulerAngles.x = .pi / 2
        firewallNode.simdPosition = SIMD3<Float>(
            0,
            firewallCenterY,
            noseFrontZ + firewallThickness * 0.5)
        firewallNode.name = "workbench.airframe.motorFirewall"
        root.addChildNode(firewallNode)

        for angle in stride(from: Float.pi * 0.25, to: Float.pi * 2, by: Float.pi * 0.5) {
            let fastener = SCNCylinder(
                radius: CGFloat(max(firewallRadius * 0.045, 0.0011)),
                height: 0.0012)
            fastener.radialSegmentCount = 16
            fastener.materials = [hardware]
            let fastenerNode = SCNNode(geometry: fastener)
            fastenerNode.eulerAngles.x = .pi / 2
            fastenerNode.simdPosition = SIMD3<Float>(
                cos(angle) * firewallRadius * 0.72,
                firewallCenterY + sin(angle) * firewallRadius * 0.72,
                firewallFrontZ + 0.0006)
            root.addChildNode(fastenerNode)
        }

        let canopy = SCNSphere(radius: CGFloat(bodyRadius * 0.82))
        canopy.segmentCount = 32
        canopy.materials = [glassMaterial()]
        let canopyNode = SCNNode(geometry: canopy)
        canopyNode.simdScale = SIMD3<Float>(0.82, 0.46, 1.42)
        canopyNode.simdPosition = SIMD3<Float>(
            0,
            bodyRadius * 0.78,
            length * 0.105)
        canopyNode.name = "workbench.airframe.canopy"
        root.addChildNode(canopyNode)

        // Service hatch above the enclosed battery/avionics rail. The pack,
        // FC, ESC and RX remain inside the fuselage as on a real survey wing;
        // the exterior still communicates how those parts are accessed.
        let hatchLength = min(max(fuselageLength * 0.38, 0.19), 0.34)
        let hatch = SCNBox(
            width: CGFloat(bodyRadius * 1.48),
            height: 0.004,
            length: CGFloat(hatchLength),
            chamferRadius: 0.004)
        hatch.materials = [carbon]
        let hatchNode = SCNNode(geometry: hatch)
        hatchNode.simdPosition = SIMD3<Float>(
            0,
            bodyRadius * 1.105,
            -length * 0.095)
        hatchNode.name = "workbench.airframe.avionicsHatch"
        root.addChildNode(hatchNode)

        let hatchLabel = surfaceLabelNode(
            width: bodyRadius * 1.02,
            height: hatchLength * 0.46,
            title: "AVIONICS",
            subtitle: "BATTERY  •  CG RAIL",
            accentHex: "#D4DADE")
        hatchLabel.eulerAngles.x = -.pi / 2
        hatchLabel.simdPosition = SIMD3<Float>(
            0,
            hatchNode.simdPosition.y + 0.0022,
            hatchNode.simdPosition.z)
        root.addChildNode(hatchLabel)
        for x: Float in [-bodyRadius * 0.58, bodyRadius * 0.58] {
            for z: Float in [-hatchLength * 0.40, hatchLength * 0.40] {
                let fastener = SCNCylinder(radius: 0.00135, height: 0.0012)
                fastener.radialSegmentCount = 16
                fastener.materials = [hardware]
                let fastenerNode = SCNNode(geometry: fastener)
                fastenerNode.simdPosition = SIMD3<Float>(
                    x,
                    hatchNode.simdPosition.y + 0.0025,
                    hatchNode.simdPosition.z + z)
                root.addChildNode(fastenerNode)
            }
        }

        // Independent horizontal and vertical tail surfaces.
        let tailCenterZ = -length * 0.39
        let tailSpan = span * 0.31
        let tailChord = max(length * 0.145, 0.070)
        let tailPoints: [SIMD2<Float>] = [
            SIMD2(-tailSpan * 0.5, -tailChord * 0.48),
            SIMD2(-tailSpan * 0.5, tailChord * 0.30),
            SIMD2(-bodyRadius * 0.35, tailChord * 0.50),
            SIMD2(bodyRadius * 0.35, tailChord * 0.50),
            SIMD2(tailSpan * 0.5, tailChord * 0.30),
            SIMD2(tailSpan * 0.5, -tailChord * 0.48),
        ]
        let stabilizer = horizontalPlanformNode(
            points: tailPoints,
            thickness: max(wingThickness * 0.58, 0.006),
            material: skin)
        stabilizer.simdPosition.z = tailCenterZ
        stabilizer.name = "workbench.airframe.tail.horizontal"
        root.addChildNode(stabilizer)

        let elevator = SCNBox(
            width: CGFloat(tailSpan * 0.82),
            height: CGFloat(max(wingThickness * 0.16, 0.0022)),
            length: CGFloat(max(tailChord * 0.15, 0.012)),
            chamferRadius: 0.001)
        elevator.materials = [accent]
        let elevatorNode = SCNNode(geometry: elevator)
        elevatorNode.simdPosition = SIMD3<Float>(
            0,
            max(wingThickness * 0.40, 0.004),
            tailCenterZ - tailChord * 0.42)
        elevatorNode.name = "workbench.airframe.elevator"
        root.addChildNode(elevatorNode)

        let finHeight = max(height * 0.66, length * 0.105)
        let finPath = NSBezierPath()
        finPath.move(to: NSPoint(x: CGFloat(-tailChord * 0.48), y: 0))
        finPath.line(to: NSPoint(x: CGFloat(tailChord * 0.46), y: 0))
        finPath.line(to: NSPoint(x: CGFloat(tailChord * 0.08), y: CGFloat(finHeight)))
        finPath.line(to: NSPoint(x: CGFloat(-tailChord * 0.24), y: CGFloat(finHeight * 0.80)))
        finPath.close()
        let finThickness = max(wingThickness * 0.40, 0.004)
        let fin = SCNShape(path: finPath, extrusionDepth: CGFloat(finThickness))
        fin.chamferRadius = CGFloat(min(finThickness * 0.20, 0.0012))
        fin.materials = [skin]
        let finNode = SCNNode(geometry: fin)
        finNode.eulerAngles.y = -.pi / 2
        finNode.simdPosition = SIMD3<Float>(
            finThickness * 0.5,
            max(wingThickness * 0.35, 0.004),
            tailCenterZ)
        finNode.name = "workbench.airframe.tail.vertical"
        root.addChildNode(finNode)

        // The lift+cruise layout gets longitudinal carbon booms and real
        // motor firewalls. The cruise unit uses the same axis-aware pad and is
        // therefore perpendicular to +Z instead of sitting flat on the wing.
        if frame.architecture == .liftCruiseVTOL {
            let liftMounts = Array(frame.motorMounts.prefix(frame.liftMotorCount))
            for side: Float in [-1, 1] {
                let sideMounts = liftMounts
                    .filter { side < 0 ? $0.x < 0 : $0.x >= 0 }
                    .sorted { $0.z < $1.z }
                guard let first = sideMounts.first, let last = sideMounts.last else { continue }
                let boomY = min(first.y, last.y) - 0.006
                let boom = flatBeamNode(
                    from: SIMD3<Float>(first.x, boomY, first.z),
                    to: SIMD3<Float>(last.x, boomY, last.z),
                    width: max(span * 0.018, 0.020),
                    height: 0.012,
                    material: carbon)
                boom.name = side < 0
                    ? "workbench.airframe.vtolBoom.left"
                    : "workbench.airframe.vtolBoom.right"
                root.addChildNode(boom)
            }
        }

        let padRadius = max(Float(frame.motorStatorMaxMm / 2000) + 0.006, 0.017)
        for (index, mount) in frame.motorMounts.enumerated() {
            let pad = propulsionMountPadNode(
                at: mount,
                axis: propulsionAxis(for: frame, index: index),
                radius: padRadius,
                material: index < frame.liftMotorCount ? carbon : hardware)
            pad.name = "workbench.airframe.motorPad.\(index)"
            root.addChildNode(pad)
        }
        return root
    }

    private static func propulsionMountPadNode(
        at position: SIMD3<Float>,
        axis: SIMD3<Float>,
        radius: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let root = propulsionMountRoot(at: position, axis: axis)
        let thickness: Float = 0.006
        let pad = SCNCylinder(radius: CGFloat(radius), height: CGFloat(thickness))
        pad.radialSegmentCount = 30
        pad.materials = [material]
        let padNode = SCNNode(geometry: pad)
        padNode.simdPosition.y = -thickness * 0.5
        root.addChildNode(padNode)
        return root
    }

    // MARK: Components

    static func componentNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        if let mesh = spec.importedMesh,
           let geometry = geometry(from: mesh, convertsCADCoordinates: true) {
            let importedMaterial = material(spec.proxy.colorHex, metalness: 0.35, roughness: 0.38)
            importedMaterial.isDoubleSided = true
            geometry.materials = [importedMaterial]
            return SCNNode(geometry: geometry)
        }
        switch spec.kind {
        case .motor: return motorNode(spec)
        case .propeller: return propellerNode(spec)
        case .battery: return batteryNode(spec)
        case .esc: return circuitBoardNode(spec, boardColor: "#252A30", accent: "#D7A43B")
        case .flightController: return circuitBoardNode(spec, boardColor: "#0D5068", accent: "#79D9E8")
        case .receiver: return receiverNode(spec)
        case .camera: return cameraNode(spec)
        case .gps: return gpsNode(spec)
        case .sensor: return sensorNode(spec)
        case .payload: return payloadNode(spec)
        case .landingGear: return landingGearNode(spec)
        case .servo: return servoNode(spec)
        }
    }

    static func motorNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let diameter = CGFloat(spec.proxy.size.x)
        let height = max(CGFloat(spec.proxy.size.y), 0.009)
        let baseHeight = max(height * 0.16, 0.0024)
        let bellHeight = max(height * 0.62, 0.0065)
        let baseMaterial = material("#121519", metalness: 0.72, roughness: 0.30)
        let bellMaterial = anodizedMaterial(spec.proxy.colorHex)
        let steel = material("#AAB1B8", metalness: 0.92, roughness: 0.18)

        let base = SCNCylinder(radius: diameter * 0.54, height: baseHeight)
        base.radialSegmentCount = 32
        base.materials = [baseMaterial]
        let baseNode = SCNNode(geometry: base)
        baseNode.simdPosition.y = Float(baseHeight * 0.5)
        root.addChildNode(baseNode)

        let stator = SCNCylinder(radius: diameter * 0.43, height: max(height * 0.24, 0.003))
        stator.radialSegmentCount = 32
        stator.materials = [material("#8D4A26", metalness: 0.62, roughness: 0.28)]
        let statorNode = SCNNode(geometry: stator)
        statorNode.simdPosition.y = Float(baseHeight + height * 0.12)
        root.addChildNode(statorNode)

        let bell = SCNCone(
            topRadius: diameter * 0.40,
            bottomRadius: diameter * 0.49,
            height: bellHeight)
        bell.radialSegmentCount = 36
        bell.materials = [bellMaterial]
        let bellNode = SCNNode(geometry: bell)
        bellNode.simdPosition.y = Float(baseHeight + bellHeight * 0.52)
        root.addChildNode(bellNode)

        // Bell ventilation slots and visible copper beneath them keep the motor
        // readable even at thumbnail scale.
        for index in 0..<8 {
            let angle = Float(index) * (.pi * 2 / 8)
            let slot = SCNBox(
                width: max(diameter * 0.075, 0.0011),
                height: max(bellHeight * 0.34, 0.0025),
                length: 0.0008,
                chamferRadius: 0.00035)
            slot.materials = [material("#0A0C0F", metalness: 0.15, roughness: 0.64)]
            let slotNode = SCNNode(geometry: slot)
            let radius = Float(diameter * 0.485)
            slotNode.simdPosition = SIMD3<Float>(
                sin(angle) * radius,
                Float(baseHeight + bellHeight * 0.52),
                cos(angle) * radius)
            slotNode.eulerAngles.y = CGFloat(angle)
            root.addChildNode(slotNode)
        }

        let cap = SCNCylinder(radius: diameter * 0.345, height: 0.0018)
        cap.radialSegmentCount = 30
        cap.materials = [bellMaterial]
        let capNode = SCNNode(geometry: cap)
        capNode.simdPosition.y = Float(baseHeight + bellHeight + 0.0007)
        root.addChildNode(capNode)

        let bearing = SCNTorus(
            ringRadius: max(diameter * 0.115, 0.0013),
            pipeRadius: max(diameter * 0.035, 0.00045))
        bearing.ringSegmentCount = 24
        bearing.pipeSegmentCount = 8
        bearing.materials = [steel]
        let bearingNode = SCNNode(geometry: bearing)
        bearingNode.simdPosition.y = Float(baseHeight + bellHeight + 0.0018)
        root.addChildNode(bearingNode)

        let shaftHeight = max(height * 0.31, 0.006)
        let shaft = SCNCylinder(radius: max(0.0010, diameter * 0.068), height: shaftHeight)
        shaft.radialSegmentCount = 24
        shaft.materials = [steel]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition.y = Float(baseHeight + bellHeight + shaftHeight * 0.5)
        root.addChildNode(shaftNode)

        let lockNut = SCNCylinder(radius: max(0.0018, diameter * 0.12), height: 0.0022)
        lockNut.radialSegmentCount = 6
        lockNut.materials = [material("#343A41", metalness: 0.78, roughness: 0.25)]
        let lockNutNode = SCNNode(geometry: lockNut)
        lockNutNode.simdPosition.y = Float(baseHeight + bellHeight + shaftHeight + 0.0008)
        root.addChildNode(lockNutNode)
        return root
    }

    static func propellerNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let diameterInch = spec.param(WorkbenchComponentSpec.ParamKey.propDiameterInch) ?? 5
        let bladeCount = max(2, Int(spec.param(WorkbenchComponentSpec.ParamKey.propBladeCount) ?? 2))
        let isFolding = spec.id.contains("folding")
        let radius = Float(diameterInch) * 0.0254 * 0.5
        let propMaterial = material(spec.proxy.colorHex, metalness: 0.05, roughness: 0.46)
        let hubRadius = CGFloat(max(0.0032, radius * 0.078))
        let hub = SCNCylinder(radius: hubRadius, height: 0.0042)
        hub.radialSegmentCount = 28
        hub.materials = [propMaterial]
        root.addChildNode(SCNNode(geometry: hub))
        let washer = SCNTorus(ringRadius: hubRadius * 0.46, pipeRadius: hubRadius * 0.12)
        washer.ringSegmentCount = 24
        washer.pipeSegmentCount = 8
        washer.materials = [material("#818A94", metalness: 0.82, roughness: 0.22)]
        let washerNode = SCNNode(geometry: washer)
        washerNode.simdPosition.y = 0.0025
        root.addChildNode(washerNode)

        if isFolding {
            // A folding aircraft prop has a spinner and individual blade-root
            // pivots, not a one-piece quad hub. The hinges remain children of
            // the rotating prop node, so simulation animation stays exact.
            let spinner = SCNCone(
                topRadius: 0,
                bottomRadius: hubRadius * 1.12,
                height: CGFloat(max(radius * 0.13, 0.012)))
            spinner.radialSegmentCount = 32
            spinner.materials = [material("#D5DADF", metalness: 0.64, roughness: 0.24)]
            let spinnerNode = SCNNode(geometry: spinner)
            spinnerNode.simdPosition.y = max(radius * 0.065, 0.006)
            root.addChildNode(spinnerNode)
        }

        for index in 0..<bladeCount {
            let bladeNode = propellerBladeNode(
                radius: radius,
                pitchInch: Float(spec.param(WorkbenchComponentSpec.ParamKey.propPitchInch) ?? 3),
                material: propMaterial)
            let pivot = SCNNode()
            let fullTurn = Float.pi * 2
            let bladeAngle = fullTurn / Float(bladeCount)
            pivot.eulerAngles.y = CGFloat(Float(index) * bladeAngle)
            if isFolding {
                let hingeRadius = max(radius * 0.025, 0.0018)
                let hinge = SCNCylinder(radius: CGFloat(hingeRadius), height: 0.0052)
                hinge.radialSegmentCount = 22
                hinge.materials = [material("#8D969E", metalness: 0.86, roughness: 0.18)]
                let hingeNode = SCNNode(geometry: hinge)
                hingeNode.simdPosition = SIMD3<Float>(radius * 0.077, 0.0006, 0)
                pivot.addChildNode(hingeNode)

                let bladeClamp = SCNBox(
                    width: CGFloat(max(radius * 0.105, 0.007)),
                    height: 0.0034,
                    length: CGFloat(max(radius * 0.050, 0.004)),
                    chamferRadius: 0.001)
                bladeClamp.materials = [material("#30363D", metalness: 0.55, roughness: 0.28)]
                let clampNode = SCNNode(geometry: bladeClamp)
                clampNode.simdPosition = SIMD3<Float>(radius * 0.095, 0, 0)
                pivot.addChildNode(clampNode)
            }
            pivot.addChildNode(bladeNode)
            root.addChildNode(pivot)
        }
        return root
    }

    static func batteryNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let s = spec.proxy.size.simdFloat
        // Catalog battery dimensions are length × height × width. Mount the
        // long axis fore/aft so the pack and its strap read like a real LiPo,
        // not a broad transverse block across the frame.
        let packWidth = s.z
        let packLength = s.x
        let pack = SCNBox(
            width: CGFloat(packWidth),
            height: CGFloat(s.y),
            length: CGFloat(packLength),
            chamferRadius: CGFloat(min(min(packWidth, s.y), packLength) * 0.10))
        pack.materials = [heatShrinkMaterial(spec.proxy.colorHex)]
        root.addChildNode(SCNNode(geometry: pack))

        for z: Float in [-packLength * 0.47, packLength * 0.47] {
            let endBand = SCNBox(
                width: CGFloat(packWidth * 0.98),
                height: CGFloat(s.y * 0.96),
                length: CGFloat(max(packLength * 0.055, 0.0015)),
                chamferRadius: 0.001)
            endBand.materials = [material("#202329", metalness: 0.03, roughness: 0.76)]
            let endNode = SCNNode(geometry: endBand)
            endNode.simdPosition.z = z
            root.addChildNode(endNode)
        }

        let cells = Int(spec.param(WorkbenchComponentSpec.ParamKey.batteryCells) ?? 0)
        let capacity = Int(spec.param(WorkbenchComponentSpec.ParamKey.batteryCapacityMah) ?? 0)
        let label = surfaceLabelNode(
            width: packWidth * 0.72,
            height: packLength * 0.58,
            title: cells > 0 ? "\(cells)S  \(capacity)" : spec.displayName,
            subtitle: cells > 0 ? "mAh  •  \(spec.brand.uppercased())" : spec.brand.uppercased(),
            accentHex: "#E9EDF2")
        label.eulerAngles.x = -.pi / 2
        label.simdPosition = SIMD3<Float>(0, s.y * 0.5 + 0.00025, 0)
        root.addChildNode(label)

        let strap = SCNBox(
            width: CGFloat(packWidth * 1.035),
            height: 0.0014,
            length: CGFloat(max(packLength * 0.13, 0.005)),
            chamferRadius: 0.001)
        strap.materials = [wovenStrapMaterial("#252A30")]
        let strapNode = SCNNode(geometry: strap)
        strapNode.simdPosition = SIMD3<Float>(0, s.y * 0.525, 0)
        root.addChildNode(strapNode)

        // A recessed terminal is part of the pack. The actual red/black lead
        // is generated by `powerHarnessNode` only when the pack is installed,
        // so it always terminates at the selected ESC instead of dangling in
        // empty space (and thumbnails remain clean product views).
        let terminalWidth = max(min(packWidth * 0.44, 0.018), 0.008)
        let terminal = SCNBox(
            width: CGFloat(terminalWidth),
            height: CGFloat(max(s.y * 0.28, 0.005)),
            length: 0.0022,
            chamferRadius: 0.0007)
        terminal.materials = [material("#D8A52D", metalness: 0.04, roughness: 0.58)]
        let terminalNode = SCNNode(geometry: terminal)
        terminalNode.simdPosition = SIMD3<Float>(0, 0, -packLength * 0.505)
        root.addChildNode(terminalNode)
        for x: Float in [-terminalWidth * 0.20, terminalWidth * 0.20] {
            let socket = SCNCylinder(radius: 0.00115, height: 0.0025)
            socket.radialSegmentCount = 14
            socket.materials = [material(
                x < 0 ? "#202329" : "#C94943",
                metalness: 0.03,
                roughness: 0.70)]
            let socketNode = SCNNode(geometry: socket)
            socketNode.eulerAngles.x = .pi / 2
            socketNode.simdPosition = SIMD3<Float>(x, 0, -packLength * 0.515)
            root.addChildNode(socketNode)
        }
        return root
    }

    private static func circuitBoardNode(
        _ spec: WorkbenchComponentSpec,
        boardColor: String,
        accent: String
    ) -> SCNNode {
        let root = SCNNode()
        let s = spec.proxy.size.simdFloat
        let board = SCNBox(
            width: CGFloat(s.x),
            height: CGFloat(max(s.y * 0.58, 0.0018)),
            length: CGFloat(s.z),
            chamferRadius: 0.0012)
        board.materials = [pcbMaterial(boardColor)]
        root.addChildNode(SCNNode(geometry: board))
        let topY = max(s.y * 0.38, 0.0018)

        let chip = SCNBox(
            width: CGFloat(s.x * (spec.kind == .esc ? 0.22 : 0.34)),
            height: 0.0024,
            length: CGFloat(s.z * (spec.kind == .esc ? 0.18 : 0.34)),
            chamferRadius: 0.00045)
        chip.materials = [material("#0D1014", metalness: 0.22, roughness: 0.42)]
        let chipNode = SCNNode(geometry: chip)
        chipNode.simdPosition.y = topY
        root.addChildNode(chipNode)

        let solder = material(accent, metalness: 0.82, roughness: 0.20)
        for x: Float in [-s.x * 0.34, s.x * 0.34] {
            for z: Float in [-s.z * 0.34, s.z * 0.34] {
                let grommet = SCNTorus(
                    ringRadius: CGFloat(max(min(s.x, s.z) * 0.043, 0.0010)),
                    pipeRadius: CGFloat(max(min(s.x, s.z) * 0.013, 0.00032)))
                grommet.ringSegmentCount = 18
                grommet.pipeSegmentCount = 7
                grommet.materials = [solder]
                let grommetNode = SCNNode(geometry: grommet)
                grommetNode.simdPosition = SIMD3<Float>(x, topY + 0.0011, z)
                root.addChildNode(grommetNode)

                let damper = SCNCylinder(
                    radius: CGFloat(max(min(s.x, s.z) * 0.050, 0.0012)),
                    height: 0.0016)
                damper.radialSegmentCount = 18
                damper.materials = [rubberMaterial("#252A2F")]
                let damperNode = SCNNode(geometry: damper)
                damperNode.simdPosition = SIMD3<Float>(x, -s.y * 0.38, z)
                root.addChildNode(damperNode)
            }
        }

        if spec.kind == .esc {
            // Two MOSFET banks and the central current shunt distinguish the ESC
            // from a flight controller without relying on card labels.
            for row: Float in [-0.22, 0.22] {
                for column in -1...1 {
                    let fet = SCNBox(
                        width: CGFloat(s.x * 0.16),
                        height: 0.0018,
                        length: CGFloat(s.z * 0.15),
                        chamferRadius: 0.00025)
                    fet.materials = [material("#171A1E", metalness: 0.38, roughness: 0.36)]
                    let fetNode = SCNNode(geometry: fet)
                    fetNode.simdPosition = SIMD3<Float>(
                        Float(column) * s.x * 0.21,
                        topY,
                        row * s.z)
                    root.addChildNode(fetNode)
                }
            }
            let shunt = SCNBox(
                width: CGFloat(s.x * 0.28),
                height: 0.0014,
                length: CGFloat(s.z * 0.07),
                chamferRadius: 0.0002)
            shunt.materials = [material("#B7A57A", metalness: 0.70, roughness: 0.24)]
            let shuntNode = SCNNode(geometry: shunt)
            shuntNode.simdPosition = SIMD3<Float>(0, topY + 0.0002, -s.z * 0.34)
            root.addChildNode(shuntNode)
        } else {
            let gyro = SCNBox(
                width: CGFloat(s.x * 0.16),
                height: 0.0020,
                length: CGFloat(s.z * 0.16),
                chamferRadius: 0.00035)
            gyro.materials = [material("#222830", metalness: 0.28, roughness: 0.34)]
            let gyroNode = SCNNode(geometry: gyro)
            gyroNode.simdPosition = SIMD3<Float>(s.x * 0.23, topY + 0.0003, -s.z * 0.18)
            root.addChildNode(gyroNode)

            let usb = SCNBox(
                width: CGFloat(s.x * 0.22),
                height: 0.0027,
                length: 0.0042,
                chamferRadius: 0.00055)
            usb.materials = [material("#9DA5AD", metalness: 0.88, roughness: 0.18)]
            let usbNode = SCNNode(geometry: usb)
            usbNode.simdPosition = SIMD3<Float>(0, 0, s.z * 0.51)
            root.addChildNode(usbNode)
        }

        // Edge solder pads make even small 20×20 boards read as electronics.
        for index in -2...2 {
            for side: Float in [-1, 1] {
                let pad = SCNBox(
                    width: CGFloat(max(s.x * 0.075, 0.0012)),
                    height: 0.00055,
                    length: CGFloat(max(s.z * 0.045, 0.0008)),
                    chamferRadius: 0.00015)
                pad.materials = [solder]
                let padNode = SCNNode(geometry: pad)
                padNode.simdPosition = SIMD3<Float>(
                    Float(index) * s.x * 0.15,
                    topY + 0.0002,
                    side * s.z * 0.46)
                root.addChildNode(padNode)
            }
        }
        return root
    }

    static func receiverNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.0014)
        let s = spec.proxy.size.simdFloat
        let isSubGHz = spec.id.contains("868") || spec.id.contains("915")
            || spec.id.contains("crossfire") || spec.id.contains("redundant")
        let label = surfaceLabelNode(
            width: s.x * 0.68,
            height: s.z * 0.50,
            title: isSubGHz ? "SUB-G" : "2.4G",
            subtitle: spec.brand.uppercased(),
            accentHex: "#E8EBEF")
        label.eulerAngles.x = -.pi / 2
        label.simdPosition.y = s.y * 0.5 + 0.00025
        root.addChildNode(label)
        for x: Float in [-s.x * 0.30, s.x * 0.30] {
            let socket = SCNTorus(ringRadius: 0.0010, pipeRadius: 0.00028)
            socket.ringSegmentCount = 14
            socket.pipeSegmentCount = 6
            socket.materials = [material("#C2A75B", metalness: 0.72, roughness: 0.24)]
            let node = SCNNode(geometry: socket)
            node.eulerAngles.x = .pi / 2
            node.simdPosition = SIMD3<Float>(x, 0, -s.z * 0.51)
            root.addChildNode(node)
        }
        return root
    }

    static func cameraNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.003)
        let s = spec.proxy.size.simdFloat
        let barrelRadius = CGFloat(max(min(s.x, s.y) * 0.29, 0.004))
        let barrel = SCNCylinder(radius: barrelRadius,
                                 height: CGFloat(max(s.z * 0.42, 0.006)))
        barrel.radialSegmentCount = 32
        barrel.materials = [material("#111419", metalness: 0.55, roughness: 0.28)]
        let barrelNode = SCNNode(geometry: barrel)
        barrelNode.eulerAngles.x = .pi / 2
        barrelNode.simdPosition = SIMD3<Float>(0, 0, s.z * 0.61)
        root.addChildNode(barrelNode)

        let focusRing = SCNTorus(ringRadius: barrelRadius * 0.74, pipeRadius: barrelRadius * 0.11)
        focusRing.ringSegmentCount = 30
        focusRing.pipeSegmentCount = 8
        focusRing.materials = [material("#77818C", metalness: 0.76, roughness: 0.22)]
        let focusNode = SCNNode(geometry: focusRing)
        focusNode.eulerAngles.x = .pi / 2
        focusNode.simdPosition = SIMD3<Float>(0, 0, s.z * 0.85)
        root.addChildNode(focusNode)

        let lens = SCNSphere(radius: CGFloat(max(min(s.x, s.y) * 0.19, 0.003)))
        lens.materials = [glassMaterial()]
        let lensNode = SCNNode(geometry: lens)
        lensNode.simdScale.z = 0.34
        lensNode.simdPosition = SIMD3<Float>(0, 0, s.z * 0.84)
        root.addChildNode(lensNode)

        for x: Float in [-s.x * 0.52, s.x * 0.52] {
            let bracket = SCNBox(
                width: 0.0018,
                height: CGFloat(s.y * 0.72),
                length: CGFloat(s.z * 0.76),
                chamferRadius: 0.0007)
            bracket.materials = [carbonFiberMaterial()]
            let bracketNode = SCNNode(geometry: bracket)
            bracketNode.simdPosition.x = x
            root.addChildNode(bracketNode)

            let screw = SCNCylinder(radius: 0.00125, height: 0.0022)
            screw.radialSegmentCount = 16
            screw.materials = [material("#A1A9B1", metalness: 0.88, roughness: 0.18)]
            let screwNode = SCNNode(geometry: screw)
            screwNode.eulerAngles.z = .pi / 2
            screwNode.simdPosition = SIMD3<Float>(x, 0, 0)
            root.addChildNode(screwNode)
        }
        root.eulerAngles.x = -0.25
        return root
    }

    static func gpsNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root: SCNNode
        if spec.proxy.shape == .cylinder {
            root = proxyNode(spec.proxy)
        } else {
            root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.003)
        }
        let antenna = SCNCylinder(radius: CGFloat(spec.proxy.size.x * 0.32), height: 0.002)
        antenna.radialSegmentCount = 32
        antenna.materials = [ceramicMaterial()]
        let node = SCNNode(geometry: antenna)
        node.simdPosition.y = Float(spec.proxy.size.y * 0.56)
        root.addChildNode(node)

        let marker = SCNCone(topRadius: 0, bottomRadius: 0.0022, height: 0.0055)
        marker.radialSegmentCount = 3
        marker.materials = [material("#2A3036", metalness: 0.10, roughness: 0.64)]
        let markerNode = SCNNode(geometry: marker)
        markerNode.eulerAngles.z = .pi / 2
        markerNode.simdPosition = SIMD3<Float>(0, Float(spec.proxy.size.y * 0.68), 0)
        root.addChildNode(markerNode)
        return root
    }

    static func sensorNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let s = spec.proxy.size.simdFloat
        if spec.id.contains("air-quality") {
            let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.004)
            for row in -2...2 {
                for column in -2...2 {
                    let vent = SCNBox(width: 0.0014, height: 0.0011,
                                      length: 0.0012, chamferRadius: 0.0003)
                    vent.materials = [rubberMaterial("#1A2022")]
                    let node = SCNNode(geometry: vent)
                    node.simdPosition = SIMD3<Float>(
                        Float(column) * s.x * 0.12,
                        Float(row) * s.y * 0.12,
                        s.z * 0.51)
                    root.addChildNode(node)
                }
            }
            return root
        }

        if spec.id.contains("radar") {
            let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.003)
            for x: Float in [-s.x * 0.23, s.x * 0.23] {
                let patch = SCNBox(width: CGFloat(s.x * 0.31), height: CGFloat(s.y * 0.60),
                                   length: 0.0012, chamferRadius: 0.0015)
                patch.materials = [ceramicMaterial()]
                let node = SCNNode(geometry: patch)
                node.simdPosition = SIMD3<Float>(x, 0, s.z * 0.52)
                root.addChildNode(node)
            }
            return root
        }

        if spec.id.contains("lidar") || spec.id.contains("obstacle-array") {
            let root = proxyNode(spec.proxy)
            let lensCount = spec.id.contains("obstacle-array") ? 6 : 4
            let radius = max(s.x, s.z) * 0.51
            for index in 0..<lensCount {
                let angle = Float(index) / Float(lensCount) * .pi * 2
                let bezel = SCNCylinder(radius: CGFloat(max(s.y * 0.15, 0.0028)), height: 0.0025)
                bezel.radialSegmentCount = 20
                bezel.materials = [material("#15191E", metalness: 0.50, roughness: 0.30)]
                let node = SCNNode(geometry: bezel)
                node.eulerAngles.x = .pi / 2
                node.eulerAngles.y = CGFloat(angle)
                node.simdPosition = SIMD3<Float>(sin(angle) * radius, 0, cos(angle) * radius)
                root.addChildNode(node)
            }
            let cap = SCNCylinder(radius: CGFloat(max(s.x * 0.34, 0.008)), height: 0.002)
            cap.radialSegmentCount = 30
            cap.materials = [anodizedMaterial("#778690")]
            let capNode = SCNNode(geometry: cap)
            capNode.simdPosition.y = s.y * 0.55
            root.addChildNode(capNode)
            return root
        }

        if spec.id.contains("optical-flow") {
            let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.002)
            let bezel = SCNCylinder(radius: CGFloat(max(s.x * 0.24, 0.0035)), height: 0.0028)
            bezel.radialSegmentCount = 24
            bezel.materials = [material("#15191E", metalness: 0.52, roughness: 0.30)]
            let bezelNode = SCNNode(geometry: bezel)
            bezelNode.simdPosition.y = -s.y * 0.54
            root.addChildNode(bezelNode)
            let lens = SCNSphere(radius: CGFloat(max(s.x * 0.14, 0.0022)))
            lens.segmentCount = 24
            lens.materials = [glassMaterial()]
            let lensNode = SCNNode(geometry: lens)
            lensNode.simdScale.y = 0.36
            lensNode.simdPosition.y = -s.y * 0.65
            root.addChildNode(lensNode)
            return root
        }

        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.002)
        let lensOffsets: [Float] = [-s.x * 0.22, s.x * 0.22]
        for x in lensOffsets {
            let bezel = SCNCylinder(
                radius: CGFloat(max(s.y * 0.25, 0.0028)),
                height: 0.0028)
            bezel.radialSegmentCount = 24
            bezel.materials = [material("#15191E", metalness: 0.52, roughness: 0.30)]
            let bezelNode = SCNNode(geometry: bezel)
            bezelNode.eulerAngles.x = .pi / 2
            bezelNode.simdPosition = SIMD3<Float>(x, 0, s.z * 0.54)
            root.addChildNode(bezelNode)

            let eye = SCNSphere(radius: CGFloat(max(s.y * 0.16, 0.0018)))
            eye.segmentCount = 24
            eye.materials = [glassMaterial()]
            let eyeNode = SCNNode(geometry: eye)
            eyeNode.simdPosition = SIMD3<Float>(x, 0, s.z * 0.59)
            root.addChildNode(eyeNode)
        }
        return root
    }

    static func payloadNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        if spec.id.contains("lidar-survey") {
            let root = proxyNode(spec.proxy)
            let s = spec.proxy.size.simdFloat
            let crown = SCNCylinder(radius: CGFloat(s.x * 0.42), height: CGFloat(s.y * 0.30))
            crown.radialSegmentCount = 36
            crown.materials = [anodizedMaterial("#202931")]
            let crownNode = SCNNode(geometry: crown)
            crownNode.simdPosition.y = s.y * 0.48
            root.addChildNode(crownNode)
            for index in 0..<8 {
                let angle = Float(index) / 8 * .pi * 2
                let window = SCNBox(width: CGFloat(s.x * 0.15), height: CGFloat(s.y * 0.16),
                                    length: 0.0015, chamferRadius: 0.001)
                window.materials = [glassMaterial()]
                let node = SCNNode(geometry: window)
                node.eulerAngles.y = CGFloat(angle)
                node.simdPosition = SIMD3<Float>(sin(angle) * s.x * 0.49,
                                                  s.y * 0.16,
                                                  cos(angle) * s.x * 0.49)
                root.addChildNode(node)
            }
            return root
        }

        if spec.id.contains("multispectral") {
            let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.005)
            let s = spec.proxy.size.simdFloat
            for (index, tint) in ["#425A82", "#486A4C", "#7A4A42", "#5A3B70", "#4C5962"].enumerated() {
                let lens = SCNSphere(radius: CGFloat(max(s.y * 0.11, 0.004)))
                lens.segmentCount = 20
                lens.materials = [material(tint, metalness: 0.05, roughness: 0.12)]
                let node = SCNNode(geometry: lens)
                node.simdScale.z = 0.38
                node.simdPosition = SIMD3<Float>((Float(index) - 2) * s.x * 0.16, 0, s.z * 0.52)
                root.addChildNode(node)
            }
            return root
        }

        if spec.id.contains("cargo-release") {
            let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.004)
            let s = spec.proxy.size.simdFloat
            let axle = SCNCylinder(radius: 0.003, height: CGFloat(s.x * 0.58))
            axle.radialSegmentCount = 24
            axle.materials = [material("#9BA4AC", metalness: 0.88, roughness: 0.18)]
            let axleNode = SCNNode(geometry: axle)
            axleNode.eulerAngles.z = .pi / 2
            axleNode.simdPosition.y = -s.y * 0.54
            root.addChildNode(axleNode)
            let hook = SCNTorus(ringRadius: CGFloat(max(s.y * 0.33, 0.006)), pipeRadius: 0.0018)
            hook.ringSegmentCount = 28
            hook.pipeSegmentCount = 8
            hook.materials = [anodizedMaterial("#D39B36")]
            let hookNode = SCNNode(geometry: hook)
            hookNode.eulerAngles.x = .pi / 2
            hookNode.simdPosition.y = -s.y * 0.83
            root.addChildNode(hookNode)
            return root
        }

        if spec.id.contains("delivery-pod") {
            let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.018)
            let s = spec.proxy.size.simdFloat
            let lid = SCNBox(width: CGFloat(s.x * 0.92), height: 0.004,
                             length: CGFloat(s.z * 0.91), chamferRadius: 0.010)
            lid.materials = [material("#BAC1C2", metalness: 0.04, roughness: 0.58)]
            let lidNode = SCNNode(geometry: lid)
            lidNode.simdPosition.y = s.y * 0.52
            root.addChildNode(lidNode)
            let label = surfaceLabelNode(width: s.x * 0.55, height: s.y * 0.44,
                                         title: "EXPRESS", subtitle: spec.brand.uppercased(),
                                         accentHex: "#E1A93A")
            label.simdPosition.z = s.z * 0.505
            root.addChildNode(label)
            return root
        }

        if spec.id.contains("sprayer") {
            let root = SCNNode()
            let s = spec.proxy.size.simdFloat
            let tank = SCNCylinder(radius: CGFloat(s.x * 0.46), height: CGFloat(s.y * 0.82))
            tank.radialSegmentCount = 36
            tank.materials = [material(spec.proxy.colorHex, metalness: 0.0, roughness: 0.62)]
            root.addChildNode(SCNNode(geometry: tank))
            let cap = SCNCylinder(radius: CGFloat(s.x * 0.14), height: 0.007)
            cap.radialSegmentCount = 24
            cap.materials = [rubberMaterial("#315B3F")]
            let capNode = SCNNode(geometry: cap)
            capNode.simdPosition.y = s.y * 0.43
            root.addChildNode(capNode)
            let boomY = -s.y * 0.30
            root.addChildNode(beamNode(from: SIMD3<Float>(-s.x, boomY, 0),
                                       to: SIMD3<Float>(s.x, boomY, 0), radius: 0.0022,
                                       material: anodizedMaterial("#69747B")))
            for x: Float in [-s.x * 0.92, s.x * 0.92] {
                let nozzle = SCNCone(topRadius: 0.001, bottomRadius: 0.0045, height: 0.010)
                nozzle.radialSegmentCount = 18
                nozzle.materials = [material("#D6A132", metalness: 0.58, roughness: 0.24)]
                let node = SCNNode(geometry: nozzle)
                node.simdPosition = SIMD3<Float>(x, boomY - 0.005, 0)
                root.addChildNode(node)
            }
            return root
        }

        if spec.id.contains("searchlight") {
            let root = SCNNode()
            let s = spec.proxy.size.simdFloat
            let housing = SCNCylinder(radius: CGFloat(s.x * 0.48), height: CGFloat(s.y * 0.76))
            housing.radialSegmentCount = 36
            housing.materials = [anodizedMaterial("#303840")]
            let housingNode = SCNNode(geometry: housing)
            housingNode.eulerAngles.x = .pi / 2
            root.addChildNode(housingNode)
            let reflector = SCNCone(topRadius: CGFloat(s.x * 0.19), bottomRadius: CGFloat(s.x * 0.43),
                                    height: CGFloat(s.y * 0.20))
            reflector.radialSegmentCount = 36
            reflector.materials = [material("#E7D49A", metalness: 0.56, roughness: 0.18)]
            let reflectorNode = SCNNode(geometry: reflector)
            reflectorNode.eulerAngles.x = .pi / 2
            reflectorNode.simdPosition.z = s.y * 0.42
            root.addChildNode(reflectorNode)
            let lens = SCNCylinder(radius: CGFloat(s.x * 0.40), height: 0.002)
            lens.radialSegmentCount = 36
            lens.materials = [glassMaterial()]
            let lensNode = SCNNode(geometry: lens)
            lensNode.eulerAngles.x = .pi / 2
            lensNode.simdPosition.z = s.y * 0.52
            root.addChildNode(lensNode)
            return root
        }

        return gimbalPayloadNode(spec)
    }

    private static func gimbalPayloadNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let radius = CGFloat(max(spec.proxy.size.x * 0.50, 0.016))
        let yoke = SCNTorus(ringRadius: radius * 0.82, pipeRadius: max(0.0015, radius * 0.09))
        yoke.materials = [material("#69727D", metalness: 0.48, roughness: 0.34)]
        let yokeNode = SCNNode(geometry: yoke)
        yokeNode.eulerAngles.x = .pi / 2
        root.addChildNode(yokeNode)
        let camera = SCNSphere(radius: radius * 0.62)
        camera.segmentCount = 36
        camera.materials = [material(spec.proxy.colorHex, metalness: 0.32, roughness: 0.32)]
        root.addChildNode(SCNNode(geometry: camera))
        let lens = SCNSphere(radius: radius * 0.23)
        lens.segmentCount = 28
        lens.materials = [glassMaterial()]
        let lensNode = SCNNode(geometry: lens)
        lensNode.simdPosition.z = Float(radius * 0.56)
        root.addChildNode(lensNode)

        for x: Float in [-Float(radius) * 0.74, Float(radius) * 0.74] {
            let pivot = SCNCylinder(radius: radius * 0.13, height: radius * 0.18)
            pivot.radialSegmentCount = 24
            pivot.materials = [material("#A1A8B0", metalness: 0.82, roughness: 0.20)]
            let pivotNode = SCNNode(geometry: pivot)
            pivotNode.eulerAngles.z = .pi / 2
            pivotNode.simdPosition.x = x
            root.addChildNode(pivotNode)
        }
        return root
    }

    static func landingGearNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let s = spec.proxy.size.simdFloat

        if spec.id.contains("micro-guards") {
            let guardRing = SCNTorus(ringRadius: CGFloat(s.x * 0.42),
                                     pipeRadius: CGFloat(max(s.y * 0.10, 0.0015)))
            guardRing.ringSegmentCount = 48
            guardRing.pipeSegmentCount = 10
            guardRing.materials = [rubberMaterial(spec.proxy.colorHex)]
            root.addChildNode(SCNNode(geometry: guardRing))
            for angle in stride(from: Float(0), to: Float.pi * 2, by: Float.pi * 0.5) {
                let foot = SCNSphere(radius: CGFloat(max(s.y * 0.18, 0.0025)))
                foot.segmentCount = 18
                foot.materials = [rubberMaterial("#30363C")]
                let node = SCNNode(geometry: foot)
                node.simdPosition = SIMD3<Float>(sin(angle) * s.x * 0.42, -s.y * 0.34,
                                                  cos(angle) * s.x * 0.42)
                root.addChildNode(node)
            }
            return root
        }

        if spec.id.contains("cine-bumpers") {
            for x: Float in [-s.x * 0.34, s.x * 0.34] {
                for z: Float in [-s.z * 0.34, s.z * 0.34] {
                    let bumper = SCNCapsule(capRadius: CGFloat(max(s.y * 0.19, 0.004)),
                                            height: CGFloat(max(s.y * 0.82, 0.020)))
                    bumper.materials = [rubberMaterial(spec.proxy.colorHex)]
                    let node = SCNNode(geometry: bumper)
                    node.simdPosition = SIMD3<Float>(x, -s.y * 0.18, z)
                    root.addChildNode(node)
                }
            }
            return root
        }

        if spec.id.contains("retractable") {
            let pivotMaterial = anodizedMaterial("#69747E")
            for x: Float in [-s.x * 0.31, s.x * 0.31] {
                let pivot = SCNCylinder(radius: CGFloat(s.z * 0.16), height: CGFloat(s.x * 0.10))
                pivot.radialSegmentCount = 24
                pivot.materials = [pivotMaterial]
                let pivotNode = SCNNode(geometry: pivot)
                pivotNode.eulerAngles.z = .pi / 2
                pivotNode.simdPosition = SIMD3<Float>(x, s.y * 0.27, 0)
                root.addChildNode(pivotNode)
                root.addChildNode(beamNode(from: SIMD3<Float>(x, s.y * 0.22, 0),
                                           to: SIMD3<Float>(x * 1.18, -s.y * 0.38, 0),
                                           radius: max(s.z * 0.045, 0.0025),
                                           material: carbonFiberMaterial()))
                let foot = SCNCapsule(
                    capRadius: CGFloat(max(s.z * 0.055, 0.003)),
                    height: CGFloat(max(s.z * 0.62, 0.045)))
                foot.materials = [rubberMaterial("#24292E")]
                let footNode = SCNNode(geometry: foot)
                footNode.eulerAngles.x = .pi / 2
                footNode.simdPosition = SIMD3<Float>(x * 1.18, -s.y * 0.40, 0)
                root.addChildNode(footNode)
            }
            return root
        }
        for x: Float in [-s.x * 0.34, s.x * 0.34] {
            for zSign: Float in [-1, 1] {
                let upper = SIMD3<Float>(x, s.y * 0.45, zSign * s.z * 0.13)
                let lower = SIMD3<Float>(x, -s.y * 0.28, zSign * s.z * 0.34)
                root.addChildNode(beamNode(from: upper, to: lower, radius: 0.0023,
                                           material: carbonFiberMaterial()))
            }
            let skid = SCNCapsule(capRadius: 0.0025, height: CGFloat(max(s.z * 0.85, 0.055)))
            skid.materials = [material(spec.proxy.colorHex)]
            let node = SCNNode(geometry: skid)
            node.eulerAngles.x = .pi / 2
            node.simdPosition = SIMD3<Float>(x, -s.y * 0.30, 0)
            root.addChildNode(node)
        }
        return root
    }

    static func servoNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.002)
        let s = spec.proxy.size.simdFloat
        if spec.id.contains("linear") {
            let rail = SCNBox(width: CGFloat(s.x * 1.24), height: 0.0018,
                              length: CGFloat(s.z * 0.32), chamferRadius: 0.0007)
            rail.materials = [material("#A3ABB2", metalness: 0.88, roughness: 0.18)]
            let railNode = SCNNode(geometry: rail)
            railNode.simdPosition.y = s.y * 0.53
            root.addChildNode(railNode)
            let slider = SCNBox(width: CGFloat(s.x * 0.22), height: 0.0032,
                                length: CGFloat(s.z * 0.56), chamferRadius: 0.0008)
            slider.materials = [anodizedMaterial("#3F7D98")]
            let sliderNode = SCNNode(geometry: slider)
            sliderNode.simdPosition = SIMD3<Float>(s.x * 0.18, s.y * 0.63, 0)
            root.addChildNode(sliderNode)
            let rod = SCNCylinder(radius: 0.0008, height: CGFloat(s.x * 0.66))
            rod.radialSegmentCount = 14
            rod.materials = [material("#B7BEC5", metalness: 0.92, roughness: 0.14)]
            let rodNode = SCNNode(geometry: rod)
            rodNode.eulerAngles.z = .pi / 2
            rodNode.simdPosition = SIMD3<Float>(s.x * 0.52, s.y * 0.63, 0)
            root.addChildNode(rodNode)
            return root
        }

        let capHeight: Float = 0.0024
        let capY = s.y * 0.5 + capHeight * 0.5
        let cap = SCNCylinder(radius: CGFloat(max(s.z * 0.22, 0.0025)), height: 0.0024)
        cap.radialSegmentCount = 24
        cap.materials = [material("#30363D", metalness: 0.30, roughness: 0.42)]
        let capNode = SCNNode(geometry: cap)
        capNode.simdPosition = SIMD3<Float>(s.x * 0.23, capY, 0)
        root.addChildNode(capNode)
        let horn = SCNBox(width: CGFloat(s.x * 1.1), height: 0.0015,
                          length: 0.003, chamferRadius: 0.001)
        horn.materials = [material("#E6E8EA", metalness: 0.10, roughness: 0.40)]
        let node = SCNNode(geometry: horn)
        let hornY = capY + capHeight * 0.5 + 0.00075
        node.simdPosition = SIMD3<Float>(s.x * 0.23, hornY, 0)
        root.addChildNode(node)

        for x: Float in [-s.x * 0.34, 0, s.x * 0.34] {
            let hole = SCNCylinder(radius: 0.00055, height: 0.0018)
            hole.radialSegmentCount = 14
            hole.materials = [material("#68717A", metalness: 0.62, roughness: 0.25)]
            let holeNode = SCNNode(geometry: hole)
            holeNode.simdPosition = SIMD3<Float>(s.x * 0.23 + x, hornY + 0.0002, 0)
            root.addChildNode(holeNode)
        }
        return root
    }

    // MARK: Hotspots

    private static func addHotspots(
        to root: SCNNode,
        build: WorkbenchBuild,
        selectedCategory: WorkbenchCategory?
    ) {
        addHotspot(position: SIMD3<Float>(0, 0.022, 0), key: "frame",
                   selected: selectedCategory == .frame, to: root)
        let frame = build.resolvedFrame
        let componentLayout = WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)
        if build.spec(for: .motor) != nil {
            let markerLift = max(
                Float(build.spec(for: .motor)?.proxy.size.y ?? 0.012) + 0.010,
                0.018)
            for (index, position) in frame.motorMounts.enumerated() {
                addHotspot(position: position + SIMD3<Float>(0, markerLift, 0),
                           key: "motor.\(index)", selected: selectedCategory == .slot(.motor), to: root)
            }
        }
        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard let spec = build.spec(for: kind) else { continue }
            if kind == .servo, !frame.servoMounts.isEmpty {
                let positions = WorkbenchBuildAnalyzer.resolvedServoPositions(
                    frame: frame, spec: spec)
                let markerLift = max(Float(spec.proxy.size.y) * 0.5 + 0.006, 0.010)
                for (index, position) in positions.enumerated() {
                    addHotspot(
                        position: position + SIMD3<Float>(0, markerLift, 0),
                        key: "servo.\(index)",
                        selected: selectedCategory == .slot(.servo),
                        to: root)
                }
                continue
            }
            guard let placement = componentLayout[kind] else { continue }
            let markerLift = max(Float(spec.proxy.size.y) * 0.5 + 0.006, 0.010)
            let markerDirection: Float = placement.surface == .bottom ? -1 : 1
            let markerPosition: SIMD3<Float>
            if placement.surface == .internalBay {
                let support = WorkbenchBuildAnalyzer.mountingEnvelope(for: frame)
                markerPosition = SIMD3<Float>(
                    placement.position.x,
                    support.top + markerLift,
                    placement.position.z)
            } else {
                markerPosition = placement.position
                    + SIMD3<Float>(0, markerLift * markerDirection, 0)
            }
            addHotspot(position: markerPosition,
                       key: kind.rawValue, selected: selectedCategory == .slot(kind), to: root)
        }
    }

    private static func addHotspot(
        position: SIMD3<Float>, key: String, selected: Bool, to root: SCNNode
    ) {
        // Keep the hit target readable without letting the editor chrome
        // become the most prominent part of the aircraft.
        let marker = SCNTorus(ringRadius: selected ? 0.0048 : 0.0035,
                              pipeRadius: selected ? 0.00085 : 0.00062)
        let markerMaterial = SCNMaterial()
        let color = selected
            ? NSColor(deviceRed: 0.23, green: 0.59, blue: 0.94, alpha: 1)
            : NSColor(deviceWhite: 0.84, alpha: 0.82)
        markerMaterial.diffuse.contents = color
        markerMaterial.lightingModel = .constant
        marker.materials = [markerMaterial]
        let node = SCNNode(geometry: marker)
        node.name = hotspotNodePrefix + key
        node.simdPosition = position
        node.eulerAngles.x = .pi / 2
        root.addChildNode(node)
    }

    // MARK: Geometry helpers

    static func geometry(
        from mesh: WorkbenchConstruction.Mesh,
        convertsCADCoordinates: Bool
    ) -> SCNGeometry? {
        let count = mesh.vertices.count / 3
        guard count > 0, mesh.indices.count >= 3 else { return nil }
        let cacheKey = "\(convertsCADCoordinates ? 1 : 0).\(mesh.vertices.count).\(mesh.indices.count).\(mesh.hashValue)" as NSString
        if let cached = importedGeometryCache.object(forKey: cacheKey) {
            return cached.copy() as? SCNGeometry
        }
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(count)
        for index in 0..<count {
            let x = mesh.vertices[index * 3]
            let y = mesh.vertices[index * 3 + 1]
            let z = mesh.vertices[index * 3 + 2]
            let position = convertsCADCoordinates
                ? SIMD3<Float>(x, z, -y)
                : SIMD3<Float>(x, y, z)
            positions.append(position)
        }

        // CADNext stores positions and indices only. Build crease-aware normals:
        // neighbouring faces blend across shallow tessellation seams, while the
        // 42-degree threshold preserves machined plate and enclosure edges.
        var faces: [(Int, Int, Int)] = []
        var weightedFaceNormals: [SIMD3<Float>] = []
        var adjacentFaces = Array(repeating: [Int](), count: count)
        for corner in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let i0 = Int(mesh.indices[corner])
            let i1 = Int(mesh.indices[corner + 1])
            let i2 = Int(mesh.indices[corner + 2])
            guard positions.indices.contains(i0),
                  positions.indices.contains(i1),
                  positions.indices.contains(i2) else { continue }
            let normal = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            guard simd_length_squared(normal) > 1e-12 else { continue }
            let faceIndex = faces.count
            faces.append((i0, i1, i2))
            weightedFaceNormals.append(normal)
            adjacentFaces[i0].append(faceIndex)
            adjacentFaces[i1].append(faceIndex)
            adjacentFaces[i2].append(faceIndex)
        }
        guard !faces.isEmpty else { return nil }

        let creaseCosine: Float = 0.7431448 // cos(42°)
        var renderVertices: [SCNVector3] = []
        var renderNormals: [SCNVector3] = []
        renderVertices.reserveCapacity(faces.count * 3)
        renderNormals.reserveCapacity(faces.count * 3)
        for (faceIndex, face) in faces.enumerated() {
            let faceNormal = simd_normalize(weightedFaceNormals[faceIndex])
            for vertexIndex in [face.0, face.1, face.2] {
                var blended = SIMD3<Float>.zero
                for neighbour in adjacentFaces[vertexIndex] {
                    let neighbourWeighted = weightedFaceNormals[neighbour]
                    let neighbourNormal = simd_normalize(neighbourWeighted)
                    if simd_dot(faceNormal, neighbourNormal) >= creaseCosine {
                        blended += neighbourWeighted
                    }
                }
                let normal = simd_length_squared(blended) > 1e-12
                    ? simd_normalize(blended)
                    : faceNormal
                let position = positions[vertexIndex]
                renderVertices.append(SCNVector3(position.x, position.y, position.z))
                renderNormals.append(SCNVector3(normal.x, normal.y, normal.z))
            }
        }

        let renderIndices = (0..<renderVertices.count).map(UInt32.init)
        let vertexSource = SCNGeometrySource(vertices: renderVertices)
        let normalSource = SCNGeometrySource(normals: renderNormals)
        let indexData = renderIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.stride)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        if let cachedGeometry = geometry.copy() as? SCNGeometry {
            importedGeometryCache.setObject(
                cachedGeometry,
                forKey: cacheKey,
                cost: renderVertices.count)
        }
        return geometry
    }

    static func material(
        _ hex: String,
        metalness: CGFloat = 0.16,
        roughness: CGFloat = 0.48
    ) -> SCNMaterial {
        let result = SCNMaterial()
        result.diffuse.contents = color(hex: hex) ?? NSColor.gray
        result.lightingModel = .physicallyBased
        result.diffuse.intensity = 1
        result.roughness.contents = NSNumber(value: Double(roughness))
        result.metalness.contents = NSNumber(value: Double(metalness))
        result.fresnelExponent = 1.45
        result.isDoubleSided = false
        return result
    }

    static func color(hex: String) -> NSColor? {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        if string.count == 3 { string = string.map { "\($0)\($0)" }.joined() }
        guard string.count == 6, let value = Int(string, radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func glassMaterial() -> SCNMaterial {
        let result = material("#244E72", metalness: 0.02, roughness: 0.08)
        result.specular.contents = NSColor(deviceWhite: 0.96, alpha: 1)
        result.clearCoat.contents = NSNumber(value: 0.72)
        result.clearCoatRoughness.contents = NSNumber(value: 0.08)
        return result
    }

    private static func roundedBoxNode(
        _ size: CodableVector3D,
        color: String,
        radius: CGFloat
    ) -> SCNNode {
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y),
                         length: CGFloat(size.z), chamferRadius: radius)
        box.materials = [material(color, metalness: 0.04, roughness: 0.54)]
        return SCNNode(geometry: box)
    }

    private static func proxyNode(_ proxy: WorkbenchComponentProxy) -> SCNNode {
        let geometry: SCNGeometry
        switch proxy.shape {
        case .box:
            geometry = SCNBox(width: CGFloat(proxy.size.x), height: CGFloat(proxy.size.y),
                              length: CGFloat(proxy.size.z), chamferRadius: 0.002)
        case .cylinder:
            geometry = SCNCylinder(radius: CGFloat(proxy.size.x * 0.5),
                                   height: CGFloat(proxy.size.y))
        case .sphere:
            geometry = SCNSphere(radius: CGFloat(max(proxy.size.x, proxy.size.y, proxy.size.z) * 0.5))
        }
        geometry.materials = [material(proxy.colorHex)]
        return SCNNode(geometry: geometry)
    }

    private static func beamNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return SCNNode() }
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) * 0.5
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        return node
    }

    private static func flatBeamNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        width: Float,
        height: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let delta = end - start
        let horizontal = SIMD2<Float>(delta.x, delta.z)
        let length = simd_length(horizontal)
        guard length > 0.0001 else { return SCNNode() }
        let beam = SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(length),
            chamferRadius: CGFloat(min(height * 0.28, width * 0.10)))
        beam.materials = [material]
        let node = SCNNode(geometry: beam)
        node.simdPosition = (start + end) * 0.5
        node.eulerAngles.y = CGFloat(atan2(delta.x, delta.z))
        return node
    }

    /// Extrudes an X/Z planform into a thin Y-up lifting surface. SCNShape is
    /// authored in local X/Y and extrudes along +Z, so the +90° X rotation
    /// maps the path to the aircraft plane and centres the extrusion on Y=0.
    private static func horizontalPlanformNode(
        points: [SIMD2<Float>],
        thickness: Float,
        material: SCNMaterial
    ) -> SCNNode {
        guard let first = points.first, points.count >= 3 else { return SCNNode() }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(thickness))
        shape.chamferRadius = CGFloat(min(thickness * 0.18, 0.0015))
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        node.eulerAngles.x = .pi / 2
        node.simdPosition.y = thickness * 0.5
        return node
    }

    private static func propellerBladeNode(
        radius: Float,
        pitchInch: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let chord = max(radius * 0.19, 0.0052)
        let root = max(radius * 0.075, 0.0030)
        let tip = radius * 0.97
        let sweep = radius * min(max(pitchInch * 0.014, 0.035), 0.095)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: CGFloat(root), y: CGFloat(-chord * 0.32)))
        path.curve(
            to: NSPoint(x: CGFloat(tip), y: CGFloat(sweep - chord * 0.055)),
            controlPoint1: NSPoint(x: CGFloat(radius * 0.34), y: CGFloat(-chord * 0.52)),
            controlPoint2: NSPoint(x: CGFloat(radius * 0.79), y: CGFloat(sweep - chord * 0.18)))
        path.curve(
            to: NSPoint(x: CGFloat(tip * 0.965), y: CGFloat(sweep + chord * 0.10)),
            controlPoint1: NSPoint(x: CGFloat(tip * 1.01), y: CGFloat(sweep)),
            controlPoint2: NSPoint(x: CGFloat(tip), y: CGFloat(sweep + chord * 0.07)))
        path.curve(
            to: NSPoint(x: CGFloat(root), y: CGFloat(chord * 0.30)),
            controlPoint1: NSPoint(x: CGFloat(radius * 0.70), y: CGFloat(sweep + chord * 0.42)),
            controlPoint2: NSPoint(x: CGFloat(radius * 0.26), y: CGFloat(chord * 0.54)))
        path.close()

        let thickness = CGFloat(max(radius * 0.012, 0.00065))
        let shape = SCNShape(path: path, extrusionDepth: thickness)
        shape.chamferRadius = thickness * 0.24
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        let pitchAngle = CGFloat(min(max(pitchInch * 0.016, 0.035), 0.11))
        node.eulerAngles.x = -.pi / 2 + pitchAngle
        node.simdPosition.y = -Float(thickness * 0.5)
        return node
    }

    private static func carbonFiberMaterial() -> SCNMaterial {
        let result = material("#191D22", metalness: 0.12, roughness: 0.48)
        result.diffuse.contents = carbonFiberTexture
        result.diffuse.wrapS = .repeat
        result.diffuse.wrapT = .repeat
        result.diffuse.contentsTransform = SCNMatrix4MakeScale(7, 7, 1)
        result.normal.contents = carbonFiberNormalTexture
        result.normal.wrapS = .repeat
        result.normal.wrapT = .repeat
        result.normal.contentsTransform = SCNMatrix4MakeScale(7, 7, 1)
        result.normal.intensity = 0.32
        result.roughness.contents = carbonFiberRoughnessTexture
        result.roughness.wrapS = .repeat
        result.roughness.wrapT = .repeat
        result.roughness.contentsTransform = SCNMatrix4MakeScale(7, 7, 1)
        result.roughness.intensity = 0.70
        return result
    }

    private static func wovenStrapMaterial(_ accentHex: String) -> SCNMaterial {
        let result = material(accentHex, metalness: 0.02, roughness: 0.82)
        result.multiply.contents = strapWeaveTexture
        result.multiply.wrapS = .repeat
        result.multiply.wrapT = .repeat
        result.multiply.contentsTransform = SCNMatrix4MakeScale(10, 3, 1)
        result.normal.contents = strapNormalTexture
        result.normal.wrapS = .repeat
        result.normal.wrapT = .repeat
        result.normal.contentsTransform = SCNMatrix4MakeScale(10, 3, 1)
        result.normal.intensity = 0.28
        return result
    }

    private static func anodizedMaterial(_ colorHex: String) -> SCNMaterial {
        let result = material(colorHex, metalness: 0.72, roughness: 0.25)
        result.clearCoat.contents = NSNumber(value: 0.10)
        result.clearCoatRoughness.contents = NSNumber(value: 0.22)
        return result
    }

    private static func heatShrinkMaterial(_ colorHex: String) -> SCNMaterial {
        let result = material(colorHex, metalness: 0.02, roughness: 0.62)
        result.clearCoat.contents = NSNumber(value: 0.12)
        result.clearCoatRoughness.contents = NSNumber(value: 0.48)
        return result
    }

    private static func pcbMaterial(_ colorHex: String) -> SCNMaterial {
        let result = material(colorHex, metalness: 0.04, roughness: 0.37)
        result.clearCoat.contents = NSNumber(value: 0.20)
        result.clearCoatRoughness.contents = NSNumber(value: 0.28)
        return result
    }

    private static func rubberMaterial(_ colorHex: String) -> SCNMaterial {
        material(colorHex, metalness: 0.0, roughness: 0.88)
    }

    private static func ceramicMaterial() -> SCNMaterial {
        let result = material("#D8D2C4", metalness: 0.0, roughness: 0.58)
        result.clearCoat.contents = NSNumber(value: 0.08)
        return result
    }

    private static func surfaceLabelNode(
        width: Float,
        height: Float,
        title: String,
        subtitle: String,
        accentHex: String
    ) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(height))
        let labelMaterial = SCNMaterial()
        labelMaterial.lightingModel = .physicallyBased
        labelMaterial.diffuse.contents = labelTexture(
            title: title,
            subtitle: subtitle,
            accentHex: accentHex)
        labelMaterial.metalness.contents = NSNumber(value: 0.0)
        labelMaterial.roughness.contents = NSNumber(value: 0.72)
        labelMaterial.isDoubleSided = true
        plane.materials = [labelMaterial]
        return SCNNode(geometry: plane)
    }

    private static let carbonFiberTexture: NSImage = {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceRed: 0.075, green: 0.087, blue: 0.102, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        for offset in stride(from: -64, through: 64, by: 8) {
            let light = NSBezierPath()
            light.move(to: NSPoint(x: offset, y: 0))
            light.line(to: NSPoint(x: offset + 64, y: 64))
            light.lineWidth = 3
            NSColor(deviceWhite: 0.22, alpha: 0.44).setStroke()
            light.stroke()

            let dark = NSBezierPath()
            dark.move(to: NSPoint(x: offset + 4, y: 0))
            dark.line(to: NSPoint(x: offset - 60, y: 64))
            dark.lineWidth = 2
            NSColor(deviceWhite: 0.025, alpha: 0.70).setStroke()
            dark.stroke()
        }
        image.unlockFocus()
        return image
    }()

    private static let carbonFiberNormalTexture: NSImage = {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceRed: 0.50, green: 0.50, blue: 1.0, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for offset in stride(from: -64, through: 64, by: 8) {
            let rising = NSBezierPath()
            rising.move(to: NSPoint(x: offset, y: 0))
            rising.line(to: NSPoint(x: offset + 64, y: 64))
            rising.lineWidth = 2.4
            NSColor(deviceRed: 0.57, green: 0.43, blue: 0.99, alpha: 1).setStroke()
            rising.stroke()

            let falling = NSBezierPath()
            falling.move(to: NSPoint(x: offset + 4, y: 0))
            falling.line(to: NSPoint(x: offset - 60, y: 64))
            falling.lineWidth = 2.0
            NSColor(deviceRed: 0.43, green: 0.57, blue: 0.99, alpha: 1).setStroke()
            falling.stroke()
        }
        image.unlockFocus()
        return image
    }()

    private static let carbonFiberRoughnessTexture: NSImage = {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceWhite: 0.58, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for offset in stride(from: -64, through: 64, by: 8) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: offset, y: 0))
            path.line(to: NSPoint(x: offset + 64, y: 64))
            path.lineWidth = 3
            NSColor(deviceWhite: 0.38, alpha: 0.78).setStroke()
            path.stroke()
        }
        image.unlockFocus()
        return image
    }()

    private static let strapWeaveTexture: NSImage = {
        let size = NSSize(width: 48, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(deviceWhite: 0.58, alpha: 0.42).setStroke()
        for x in stride(from: 0, through: 48, by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + 12, y: 24))
            path.lineWidth = 1
            path.stroke()
        }
        NSColor(deviceWhite: 0.24, alpha: 0.24).setStroke()
        for y in stride(from: 2, through: 24, by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: 48, y: y))
            path.lineWidth = 1
            path.stroke()
        }
        image.unlockFocus()
        return image
    }()

    private static let strapNormalTexture: NSImage = {
        let size = NSSize(width: 48, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(deviceRed: 0.50, green: 0.50, blue: 1.0, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for x in stride(from: 0, through: 48, by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + 12, y: 24))
            path.lineWidth = 1.2
            NSColor(deviceRed: 0.56, green: 0.44, blue: 0.99, alpha: 1).setStroke()
            path.stroke()
        }
        image.unlockFocus()
        return image
    }()

    private static func labelTexture(
        title: String,
        subtitle: String,
        accentHex: String
    ) -> NSImage {
        let cacheKey = "\(title)|\(subtitle)|\(accentHex)"
        if let cached = labelTextureCache[cacheKey] {
            return cached
        }
        let size = NSSize(width: 384, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        let background = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                      xRadius: 24, yRadius: 24)
        NSColor(deviceWhite: 0.055, alpha: 0.92).setFill()
        background.fill()

        let accent = color(hex: accentHex) ?? .white
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 24, width: 8, height: 132),
                     xRadius: 4, yRadius: 4).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        (title as NSString).draw(
            in: NSRect(x: 52, y: 76, width: 306, height: 66),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 42, weight: .heavy),
                .foregroundColor: accent,
                .paragraphStyle: paragraph,
            ])
        (subtitle as NSString).draw(
            in: NSRect(x: 54, y: 32, width: 300, height: 40),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: NSColor(deviceWhite: 0.78, alpha: 1),
                .paragraphStyle: paragraph,
            ])
        image.unlockFocus()
        labelTextureCache[cacheKey] = image
        return image
    }

    private static var labelTextureCache: [String: NSImage] = [:]

    private static func applySelection(_ selected: Bool, to node: SCNNode) {
        guard selected else { return }
        let tint = NSColor(deviceRed: 0.82, green: 0.91, blue: 1.0, alpha: 1)
        node.enumerateChildNodes { child, _ in
            child.geometry?.materials.forEach {
                $0.multiply.contents = tint
            }
        }
        node.geometry?.materials.forEach {
            $0.multiply.contents = tint
        }
    }
}
