# Upgrade Patch Code Dump

## DroneUAVDemo/Domain/CameraConfiguration.swift
```swift
import Foundation
import simd

enum CameraMode: String, CaseIterable, Identifiable {
    case free
    case follow
    case fpv
    case orbit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free:
            return "Free"
        case .follow:
            return "Follow"
        case .fpv:
            return "FPV"
        case .orbit:
            return "Orbit"
        }
    }

    var titleKey: String {
        switch self {
        case .free:
            return "camera.mode.free"
        case .follow:
            return "camera.mode.follow"
        case .fpv:
            return "camera.mode.fpv"
        case .orbit:
            return "camera.mode.orbit"
        }
    }

    func next() -> CameraMode {
        switch self {
        case .free:
            return .follow
        case .follow:
            return .fpv
        case .fpv:
            return .orbit
        case .orbit:
            return .free
        }
    }
}

struct FreeCameraState {
    var moveSpeed: Float
    var zoomSensitivity: Float
    var distance: Float
    var minDistance: Float
    var maxDistance: Float
}

struct FollowCameraState {
    var distance: Float
    var height: Float
    var lateralOffset: Float
    var minDistance: Float
    var maxDistance: Float
}

struct OrbitCameraState {
    var distance: Float
    var height: Float
    var angularSpeed: Float
    var minDistance: Float
    var maxDistance: Float
}

struct FPVCameraState {
    var stabilization: Float
    var shake: Float
    var yawLimitDeg: Float
    var pitchLimitDeg: Float
    var nearClip: Float
    var mountOffset: SIMD3<Float>
    var hideObstructingParts: Bool
}

struct CameraConfiguration {
    var mode: CameraMode
    var fov: Float
    var sensitivity: Float
    var smoothing: Float

    var free: FreeCameraState
    var follow: FollowCameraState
    var orbit: OrbitCameraState
    var fpv: FPVCameraState

    // MARK: Backward-compatible accessors
    var orbitDistance: Float {
        get { orbit.distance }
        set { orbit.distance = newValue.clamped(to: orbit.minDistance...orbit.maxDistance) }
    }

    var followOffset: SIMD3<Float> {
        get { SIMD3<Float>(follow.lateralOffset, follow.height, follow.distance) }
        set {
            follow.lateralOffset = newValue.x
            follow.height = newValue.y
            follow.distance = newValue.z.clamped(to: follow.minDistance...follow.maxDistance)
        }
    }

    var fpvStabilization: Float {
        get { fpv.stabilization }
        set { fpv.stabilization = newValue.clamped(to: 0.0...1.0) }
    }

    var fpvShake: Float {
        get { fpv.shake }
        set { fpv.shake = newValue.clamped(to: 0.0...0.5) }
    }

    var cameraDistance: Float {
        switch mode {
        case .free:
            return free.distance
        case .follow:
            return follow.distance
        case .orbit:
            return orbit.distance
        case .fpv:
            return 0.0
        }
    }

    mutating func setCameraDistance(_ value: Float) {
        switch mode {
        case .free:
            free.distance = value.clamped(to: free.minDistance...free.maxDistance)
        case .follow:
            follow.distance = value.clamped(to: follow.minDistance...follow.maxDistance)
        case .orbit:
            orbit.distance = value.clamped(to: orbit.minDistance...orbit.maxDistance)
        case .fpv:
            break
        }
    }

    static let `default` = CameraConfiguration(
        mode: .follow,
        fov: 56.0,
        sensitivity: 1.0,
        smoothing: 0.72,
        free: FreeCameraState(
            moveSpeed: 4.0,
            zoomSensitivity: 1.0,
            distance: 14.0,
            minDistance: 2.0,
            maxDistance: 80.0
        ),
        follow: FollowCameraState(
            distance: 6.8,
            height: 2.4,
            lateralOffset: 0.0,
            minDistance: 2.0,
            maxDistance: 24.0
        ),
        orbit: OrbitCameraState(
            distance: 6.8,
            height: 2.4,
            angularSpeed: 0.42,
            minDistance: 2.0,
            maxDistance: 28.0
        ),
        fpv: FPVCameraState(
            stabilization: 0.45,
            shake: 0.07,
            yawLimitDeg: 24.0,
            pitchLimitDeg: 18.0,
            nearClip: 0.02,
            mountOffset: SIMD3<Float>(0.0, 0.012, 0.040),
            hideObstructingParts: true
        )
    )
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
```

## DroneUAVDemo/Input/KeyboardInputService.swift
```swift
import AppKit
import Foundation

struct KeyboardAxisInput {
    var forward: Float
    var strafe: Float
    var vertical: Float
    var speedBoost: Bool

    static let zero = KeyboardAxisInput(forward: 0.0, strafe: 0.0, vertical: 0.0, speedBoost: false)
}

enum KeyBindingCategory: String, CaseIterable, Identifiable {
    case flight
    case camera
    case ui
    case debug

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .flight:
            return "keybind.category.flight"
        case .camera:
            return "keybind.category.camera"
        case .ui:
            return "keybind.category.ui"
        case .debug:
            return "keybind.category.debug"
        }
    }
}

enum InputProcessingMode {
    case flight
    case editing
}

enum KeyboardCommand: String, CaseIterable, Identifiable {
    case moveForward
    case moveBackward
    case moveLeft
    case moveRight
    case descend
    case ascend
    case accelerate

    case hover
    case resetDrone

    case toggleFPV
    case cycleCameraMode
    case zoomIn
    case zoomOut

    case toggleControlPanel
    case toggleTelemetryHUD
    case toggleDamageOverlay
    case toggleThermalOverlay

    var id: String { rawValue }

    var category: KeyBindingCategory {
        switch self {
        case .moveForward, .moveBackward, .moveLeft, .moveRight, .descend, .ascend, .accelerate, .hover, .resetDrone:
            return .flight
        case .toggleFPV, .cycleCameraMode, .zoomIn, .zoomOut:
            return .camera
        case .toggleControlPanel, .toggleTelemetryHUD:
            return .ui
        case .toggleDamageOverlay, .toggleThermalOverlay:
            return .debug
        }
    }

    var isContinuous: Bool {
        switch self {
        case .moveForward, .moveBackward, .moveLeft, .moveRight, .descend, .ascend, .accelerate:
            return true
        case .hover, .resetDrone, .toggleFPV, .cycleCameraMode, .zoomIn, .zoomOut, .toggleControlPanel, .toggleTelemetryHUD, .toggleDamageOverlay, .toggleThermalOverlay:
            return false
        }
    }

    var titleKey: String {
        switch self {
        case .moveForward:
            return "keybind.flight.forward"
        case .moveBackward:
            return "keybind.flight.backward"
        case .moveLeft:
            return "keybind.flight.left"
        case .moveRight:
            return "keybind.flight.right"
        case .descend:
            return "keybind.flight.descend"
        case .ascend:
            return "keybind.flight.ascend"
        case .accelerate:
            return "keybind.flight.accelerate"
        case .hover:
            return "keybind.flight.hover"
        case .resetDrone:
            return "keybind.flight.reset"
        case .toggleFPV:
            return "keybind.camera.toggle_fpv"
        case .cycleCameraMode:
            return "keybind.camera.cycle_mode"
        case .zoomIn:
            return "keybind.camera.zoom_in"
        case .zoomOut:
            return "keybind.camera.zoom_out"
        case .toggleControlPanel:
            return "keybind.ui.toggle_panel"
        case .toggleTelemetryHUD:
            return "keybind.ui.toggle_hud"
        case .toggleDamageOverlay:
            return "keybind.debug.toggle_damage"
        case .toggleThermalOverlay:
            return "keybind.debug.toggle_thermal"
        }
    }
}

struct KeyBindingDescriptor: Identifiable, Hashable {
    let command: KeyboardCommand
    var keyCode: UInt16
    var keyLabel: String

    var id: String { command.rawValue }
    var category: KeyBindingCategory { command.category }
}

struct KeyBindingProfile {
    var bindings: [KeyboardCommand: KeyBindingDescriptor]

    init(bindings: [KeyboardCommand: KeyBindingDescriptor]) {
        self.bindings = bindings
    }

    static let `default` = KeyBindingProfile(
        bindings: [
            .moveForward: KeyBindingDescriptor(command: .moveForward, keyCode: 13, keyLabel: "W"),
            .moveBackward: KeyBindingDescriptor(command: .moveBackward, keyCode: 1, keyLabel: "S"),
            .moveLeft: KeyBindingDescriptor(command: .moveLeft, keyCode: 0, keyLabel: "A"),
            .moveRight: KeyBindingDescriptor(command: .moveRight, keyCode: 2, keyLabel: "D"),
            .descend: KeyBindingDescriptor(command: .descend, keyCode: 12, keyLabel: "Q"),
            .ascend: KeyBindingDescriptor(command: .ascend, keyCode: 14, keyLabel: "E"),
            .accelerate: KeyBindingDescriptor(command: .accelerate, keyCode: 56, keyLabel: "Shift"),
            .hover: KeyBindingDescriptor(command: .hover, keyCode: 49, keyLabel: "Space"),
            .resetDrone: KeyBindingDescriptor(command: .resetDrone, keyCode: 15, keyLabel: "R"),
            .toggleFPV: KeyBindingDescriptor(command: .toggleFPV, keyCode: 3, keyLabel: "F"),
            .cycleCameraMode: KeyBindingDescriptor(command: .cycleCameraMode, keyCode: 8, keyLabel: "C"),
            .zoomIn: KeyBindingDescriptor(command: .zoomIn, keyCode: 6, keyLabel: "Z"),
            .zoomOut: KeyBindingDescriptor(command: .zoomOut, keyCode: 7, keyLabel: "X"),
            .toggleControlPanel: KeyBindingDescriptor(command: .toggleControlPanel, keyCode: 48, keyLabel: "Tab"),
            .toggleTelemetryHUD: KeyBindingDescriptor(command: .toggleTelemetryHUD, keyCode: 17, keyLabel: "T"),
            .toggleDamageOverlay: KeyBindingDescriptor(command: .toggleDamageOverlay, keyCode: 4, keyLabel: "H"),
            .toggleThermalOverlay: KeyBindingDescriptor(command: .toggleThermalOverlay, keyCode: 5, keyLabel: "G")
        ]
    )

    func descriptor(for command: KeyboardCommand) -> KeyBindingDescriptor? {
        bindings[command]
    }

    func command(for keyCode: UInt16) -> KeyboardCommand? {
        bindings.values.first(where: { $0.keyCode == keyCode })?.command
    }

    mutating func rebind(command: KeyboardCommand, keyCode: UInt16, keyLabel: String) {
        bindings[command] = KeyBindingDescriptor(command: command, keyCode: keyCode, keyLabel: keyLabel)
    }

    func groupedBindings() -> [KeyBindingCategory: [KeyBindingDescriptor]] {
        Dictionary(grouping: bindings.values, by: \.category).mapValues {
            $0.sorted { $0.command.rawValue < $1.command.rawValue }
        }
    }

    func conflicts() -> [String] {
        let grouped = Dictionary(grouping: bindings.values, by: \.keyCode)
        var conflicts: [String] = []
        for entry in grouped where entry.value.count > 1 {
            let commandKeys = entry.value.map { $0.command.titleKey }.sorted()
            let keyName = entry.value.first?.keyLabel ?? String(entry.key)
            conflicts.append("\(keyName): \(commandKeys.joined(separator: ", "))")
        }
        return conflicts.sorted()
    }
}

enum KeyboardAction {
    case requestHover
    case requestReset
    case toggleFPV
    case toggleThermalOverlay
    case toggleDamageOverlay
    case cycleCameraMode
    case toggleControlPanel
    case toggleTelemetryHUD
    case zoomInCamera
    case zoomOutCamera
}

protocol KeyboardInputProviding {
    func start()
    func stop()
    func currentAxisInput() -> KeyboardAxisInput
    func consumeActions() -> [KeyboardAction]
    func setInputProcessingMode(_ mode: InputProcessingMode)
    func currentBindingProfile() -> KeyBindingProfile
    func currentBindingConflicts() -> [String]
}

final class KeyboardInputService: KeyboardInputProviding {
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var localFlagsChangedMonitor: Any?

    private var pressedContinuous: Set<KeyboardCommand> = []
    private var pendingActions: [KeyboardAction] = []

    private var processingMode: InputProcessingMode = .flight
    private var profile: KeyBindingProfile

    init(profile: KeyBindingProfile = .default) {
        self.profile = profile
    }

    func start() {
        guard localKeyDownMonitor == nil, localKeyUpMonitor == nil else {
            return
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }

        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }

        localFlagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    func stop() {
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        if let localKeyUpMonitor {
            NSEvent.removeMonitor(localKeyUpMonitor)
            self.localKeyUpMonitor = nil
        }

        if let localFlagsChangedMonitor {
            NSEvent.removeMonitor(localFlagsChangedMonitor)
            self.localFlagsChangedMonitor = nil
        }

        pressedContinuous.removeAll()
        pendingActions.removeAll()
    }

    func currentAxisInput() -> KeyboardAxisInput {
        let forward: Float = (pressedContinuous.contains(.moveForward) ? 1.0 : 0.0) - (pressedContinuous.contains(.moveBackward) ? 1.0 : 0.0)
        let strafe: Float = (pressedContinuous.contains(.moveRight) ? 1.0 : 0.0) - (pressedContinuous.contains(.moveLeft) ? 1.0 : 0.0)
        let vertical: Float = (pressedContinuous.contains(.ascend) ? 1.0 : 0.0) - (pressedContinuous.contains(.descend) ? 1.0 : 0.0)
        let speedBoost = pressedContinuous.contains(.accelerate)

        return KeyboardAxisInput(
            forward: forward,
            strafe: strafe,
            vertical: vertical,
            speedBoost: speedBoost
        )
    }

    func consumeActions() -> [KeyboardAction] {
        defer {
            pendingActions.removeAll(keepingCapacity: true)
        }
        return pendingActions
    }

    func setInputProcessingMode(_ mode: InputProcessingMode) {
        processingMode = mode
    }

    func currentBindingProfile() -> KeyBindingProfile {
        profile
    }

    func currentBindingConflicts() -> [String] {
        profile.conflicts()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            return event
        }

        guard let command = profile.command(for: event.keyCode) else {
            return event
        }

        if processingMode == .editing, command.category == .flight {
            return event
        }

        if command.isContinuous {
            pressedContinuous.insert(command)
            return nil
        }

        if !event.isARepeat {
            mapCommandToAction(command)
        }
        return nil
    }

    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard let command = profile.command(for: event.keyCode), command.isContinuous else {
            return event
        }
        pressedContinuous.remove(command)
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        // Shift has independent key codes for left/right variants, so keep it mirrored from modifier flags.
        if event.modifierFlags.contains(.shift) {
            pressedContinuous.insert(.accelerate)
        } else {
            pressedContinuous.remove(.accelerate)
        }
        return event
    }

    private func mapCommandToAction(_ command: KeyboardCommand) {
        switch command {
        case .hover:
            pendingActions.append(.requestHover)
        case .resetDrone:
            pendingActions.append(.requestReset)
        case .toggleFPV:
            pendingActions.append(.toggleFPV)
        case .cycleCameraMode:
            pendingActions.append(.cycleCameraMode)
        case .zoomIn:
            pendingActions.append(.zoomInCamera)
        case .zoomOut:
            pendingActions.append(.zoomOutCamera)
        case .toggleControlPanel:
            pendingActions.append(.toggleControlPanel)
        case .toggleTelemetryHUD:
            pendingActions.append(.toggleTelemetryHUD)
        case .toggleDamageOverlay:
            pendingActions.append(.toggleDamageOverlay)
        case .toggleThermalOverlay:
            pendingActions.append(.toggleThermalOverlay)
        case .moveForward, .moveBackward, .moveLeft, .moveRight, .descend, .ascend, .accelerate:
            break
        }
    }
}
```

## DroneUAVDemo/Domain/TerrainModel.swift
```swift
import Foundation
import simd

enum TerrainPreset: String, CaseIterable, Identifiable {
    case gridDemo
    case field
    case forest
    case city

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gridDemo:
            return "Grid Demo"
        case .field:
            return "Field"
        case .forest:
            return "Forest"
        case .city:
            return "City"
        }
    }

    var titleKey: String {
        switch self {
        case .gridDemo:
            return "terrain.grid_demo"
        case .field:
            return "terrain.field"
        case .forest:
            return "terrain.forest"
        case .city:
            return "terrain.city"
        }
    }

    var defaultDensity: Float {
        switch self {
        case .gridDemo:
            return 0.35
        case .field:
            return 0.24
        case .forest:
            return 0.72
        case .city:
            return 0.82
        }
    }

    var defaultObjectKinds: [EnvironmentObjectKind] {
        switch self {
        case .gridDemo:
            return [.marker, .pole, .crate]
        case .field:
            return [.tree, .rock, .crate]
        case .forest:
            return [.tree, .tree, .tree, .rock, .pole]
        case .city:
            return [.building, .building, .building, .pole, .crate]
        }
    }

    var worldHalfExtent: Float {
        switch self {
        case .gridDemo:
            return 72.0
        case .field:
            return 96.0
        case .forest:
            return 110.0
        case .city:
            return 96.0
        }
    }
}

enum EnvironmentObjectKind: String {
    case tree
    case building
    case pole
    case crate
    case rock
    case marker
    case distantBelt
}

struct TerrainConfiguration {
    var preset: TerrainPreset
    var density: Float
    var seed: UInt64
    var safeSpawnRadius: Float

    static let `default` = TerrainConfiguration(
        preset: .gridDemo,
        density: TerrainPreset.gridDemo.defaultDensity,
        seed: 42,
        safeSpawnRadius: 8.0
    )
}

struct EnvironmentObjectDescriptor: Identifiable {
    let id: UUID
    let kind: EnvironmentObjectKind
    let biome: TerrainPreset
    let position: SIMD3<Float>
    let size: SIMD3<Float>
    let boundingRadius: Float
    let isCollidable: Bool
}
```

## DroneUAVDemo/Scene/ScenePopulationService.swift
```swift
import Foundation
import SceneKit
import simd

final class ScenePopulationService {
    private let containerNode = SCNNode()

    init(rootNode: SCNNode) {
        containerNode.name = "environmentContainer"
        rootNode.addChildNode(containerNode)
    }

    @discardableResult
    func populate(with terrain: TerrainConfiguration) -> ([EnvironmentObjectDescriptor], [UUID: SCNNode]) {
        containerNode.childNodes.forEach { $0.removeFromParentNode() }

        var generator = SeededRandomGenerator(seed: terrain.seed)
        let density = terrain.density.clamped(to: 0.0...1.0)

        var collidableDescriptors: [EnvironmentObjectDescriptor] = []

        switch terrain.preset {
        case .gridDemo:
            collidableDescriptors = generateGridDemo(density: density, safeSpawn: terrain.safeSpawnRadius, generator: &generator)
        case .field:
            collidableDescriptors = generateField(density: density, safeSpawn: terrain.safeSpawnRadius, extent: terrain.preset.worldHalfExtent, generator: &generator)
        case .forest:
            collidableDescriptors = generateForest(density: density, safeSpawn: terrain.safeSpawnRadius, extent: terrain.preset.worldHalfExtent, generator: &generator)
        case .city:
            collidableDescriptors = generateCity(density: density, safeSpawn: terrain.safeSpawnRadius, extent: terrain.preset.worldHalfExtent, generator: &generator)
        }

        let beltDescriptors = generateBoundaryBelt(
            extent: terrain.preset.worldHalfExtent,
            terrain: terrain.preset,
            generator: &generator
        )
        let allDescriptors = collidableDescriptors + beltDescriptors

        var nodesByID: [UUID: SCNNode] = [:]
        for descriptor in allDescriptors {
            let node = EnvironmentObjectFactory.makeNode(for: descriptor)
            nodesByID[descriptor.id] = node
            containerNode.addChildNode(node)
        }

        return (allDescriptors, nodesByID)
    }

    private func generateGridDemo(
        density: Float,
        safeSpawn: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []

        let spacing: Float = 10.0
        let halfCells = 7

        for ix in -halfCells...halfCells {
            for iz in -halfCells...halfCells {
                if abs(ix) <= 1, abs(iz) <= 1 { continue }
                if Float.random(in: 0...1, using: &generator) > density + 0.18 { continue }

                let x = Float(ix) * spacing
                let z = Float(iz) * spacing
                let startDistance = simd_length(SIMD2<Float>(x, z))
                if startDistance < safeSpawn { continue }

                let kind: EnvironmentObjectKind = (abs(ix + iz) % 3 == 0) ? .marker : ((abs(ix) % 2 == 0) ? .pole : .crate)
                let size = sizeForKind(kind, terrain: .gridDemo, generator: &generator)
                descriptors.append(makeDescriptor(kind: kind, biome: .gridDemo, position: SIMD3<Float>(x, 0, z), size: size, collidable: true))
            }
        }

        return descriptors
    }

    private func generateField(
        density: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        let count = max(36, Int(120 * density))
        return scatterObjects(
            count: count,
            extent: extent,
            safeSpawn: safeSpawn,
            overlapPadding: 1.2,
            terrain: .field,
            generator: &generator
        ) { rng in
            let pick = Float.random(in: 0...1, using: &rng)
            if pick < 0.55 { return .tree }
            if pick < 0.78 { return .rock }
            if pick < 0.92 { return .crate }
            return .pole
        }
    }

    private func generateForest(
        density: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        let count = max(180, Int(560 * density))
        return scatterObjects(
            count: count,
            extent: extent,
            safeSpawn: safeSpawn,
            overlapPadding: 1.0,
            terrain: .forest,
            generator: &generator
        ) { rng in
            let pick = Float.random(in: 0...1, using: &rng)
            if pick < 0.78 { return .tree }
            if pick < 0.92 { return .rock }
            if pick < 0.97 { return .pole }
            return .crate
        }
    }

    private func generateCity(
        density: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        var occupied: [(SIMD2<Float>, Float)] = []

        let blockSpacing: Float = 18.0
        let blockCount = Int((extent * 2) / blockSpacing)
        let centerOffset = Float(blockCount - 1) * blockSpacing * 0.5

        for ix in 0..<blockCount {
            for iz in 0..<blockCount {
                let x = Float(ix) * blockSpacing - centerOffset
                let z = Float(iz) * blockSpacing - centerOffset

                let axisRoad = (ix % 3 == 0) || (iz % 3 == 0)
                if axisRoad { continue }
                if Float.random(in: 0...1, using: &generator) > density + 0.08 { continue }
                if simd_length(SIMD2<Float>(x, z)) < safeSpawn + 8.0 { continue }

                let width = Float.random(in: 8.0...18.0, using: &generator)
                let depth = Float.random(in: 8.0...18.0, using: &generator)
                let height = Float.random(in: 18.0...64.0, using: &generator)
                let position = SIMD3<Float>(x + Float.random(in: -2.8...2.8, using: &generator), 0.0, z + Float.random(in: -2.8...2.8, using: &generator))

                let radius = max(width, depth) * 0.58
                if overlaps(position: SIMD2<Float>(position.x, position.z), radius: radius, occupied: occupied, padding: 1.25) {
                    continue
                }

                descriptors.append(makeDescriptor(
                    kind: .building,
                    biome: .city,
                    position: position,
                    size: SIMD3<Float>(width, height, depth),
                    collidable: true
                ))
                occupied.append((SIMD2<Float>(position.x, position.z), radius))

                if Float.random(in: 0...1, using: &generator) < 0.55 {
                    let poleOffset = SIMD3<Float>(Float.random(in: -5.0...5.0, using: &generator), 0, Float.random(in: -5.0...5.0, using: &generator))
                    let polePos = position + poleOffset
                    if simd_length(SIMD2<Float>(polePos.x, polePos.z)) > safeSpawn {
                        descriptors.append(makeDescriptor(
                            kind: .pole,
                            biome: .city,
                            position: polePos,
                            size: sizeForKind(.pole, terrain: .city, generator: &generator),
                            collidable: true
                        ))
                    }
                }
            }
        }

        return descriptors
    }

    private func scatterObjects(
        count: Int,
        extent: Float,
        safeSpawn: Float,
        overlapPadding: Float,
        terrain: TerrainPreset,
        generator: inout SeededRandomGenerator,
        pickKind: (inout SeededRandomGenerator) -> EnvironmentObjectKind
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        descriptors.reserveCapacity(count)
        var occupied: [(SIMD2<Float>, Float)] = []
        var attempts = 0

        while descriptors.count < count, attempts < count * 20 {
            attempts += 1

            let x = Float.random(in: -extent...extent, using: &generator)
            let z = Float.random(in: -extent...extent, using: &generator)
            let startDistance = simd_length(SIMD2<Float>(x, z))
            if startDistance < safeSpawn { continue }

            let kind = pickKind(&generator)
            let size = sizeForKind(kind, terrain: terrain, generator: &generator)
            let radius = max(size.x, size.z) * 0.56
            let pos2 = SIMD2<Float>(x, z)

            if overlaps(position: pos2, radius: radius, occupied: occupied, padding: overlapPadding) {
                continue
            }

            descriptors.append(makeDescriptor(
                kind: kind,
                biome: terrain,
                position: SIMD3<Float>(x, 0.0, z),
                size: size,
                collidable: true
            ))
            occupied.append((pos2, radius))
        }

        return descriptors
    }

    private func generateBoundaryBelt(
        extent: Float,
        terrain: TerrainPreset,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        let baseRadius = extent + 26.0
        let segmentCount = 96

        for index in 0..<segmentCount {
            let theta = (Float(index) / Float(segmentCount)) * (.pi * 2)
            let radialJitter = Float.random(in: -6.0...8.0, using: &generator)
            let x = cos(theta) * (baseRadius + radialJitter)
            let z = sin(theta) * (baseRadius + radialJitter)

            switch terrain {
            case .forest:
                let size = SIMD3<Float>(
                    Float.random(in: 2.2...5.4, using: &generator),
                    Float.random(in: 10.0...24.0, using: &generator),
                    Float.random(in: 2.2...5.4, using: &generator)
                )
                descriptors.append(makeDescriptor(
                    kind: .tree,
                    biome: .forest,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: size,
                    collidable: false
                ))

            case .city:
                let width = Float.random(in: 9.0...20.0, using: &generator)
                let depth = Float.random(in: 8.0...18.0, using: &generator)
                let height = Float.random(in: 28.0...90.0, using: &generator)
                descriptors.append(makeDescriptor(
                    kind: .building,
                    biome: .city,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: SIMD3<Float>(width, height, depth),
                    collidable: false
                ))

            case .field:
                let kind: EnvironmentObjectKind = Float.random(in: 0...1, using: &generator) < 0.76 ? .distantBelt : .tree
                let size = kind == .distantBelt
                    ? SIMD3<Float>(Float.random(in: 14.0...32.0, using: &generator), Float.random(in: 4.0...11.0, using: &generator), Float.random(in: 5.0...13.0, using: &generator))
                    : SIMD3<Float>(Float.random(in: 1.8...3.8, using: &generator), Float.random(in: 6.0...14.0, using: &generator), Float.random(in: 1.8...3.8, using: &generator))
                descriptors.append(makeDescriptor(
                    kind: kind,
                    biome: .field,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: size,
                    collidable: false
                ))

            case .gridDemo:
                let width = Float.random(in: 10.0...18.0, using: &generator)
                let depth = Float.random(in: 6.0...12.0, using: &generator)
                let height = Float.random(in: 16.0...32.0, using: &generator)
                descriptors.append(makeDescriptor(
                    kind: .distantBelt,
                    biome: .gridDemo,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: SIMD3<Float>(width, height, depth),
                    collidable: false
                ))
            }
        }

        return descriptors
    }

    private func makeDescriptor(kind: EnvironmentObjectKind, biome: TerrainPreset, position: SIMD3<Float>, size: SIMD3<Float>, collidable: Bool) -> EnvironmentObjectDescriptor {
        EnvironmentObjectDescriptor(
            id: UUID(),
            kind: kind,
            biome: biome,
            position: position,
            size: size,
            boundingRadius: max(size.x, max(size.y, size.z)) * 0.55,
            isCollidable: collidable
        )
    }

    private func overlaps(position: SIMD2<Float>, radius: Float, occupied: [(SIMD2<Float>, Float)], padding: Float) -> Bool {
        for entry in occupied {
            let distance = simd_distance(entry.0, position)
            if distance < (entry.1 + radius) * padding {
                return true
            }
        }
        return false
    }

    private func sizeForKind(_ kind: EnvironmentObjectKind, terrain: TerrainPreset, generator: inout SeededRandomGenerator) -> SIMD3<Float> {
        switch kind {
        case .tree:
            return SIMD3<Float>(
                Float.random(in: 1.8...4.8, using: &generator),
                Float.random(in: 7.0...18.0, using: &generator),
                Float.random(in: 1.8...4.8, using: &generator)
            )
        case .building:
            return SIMD3<Float>(
                Float.random(in: 8.0...24.0, using: &generator),
                Float.random(in: 18.0...72.0, using: &generator),
                Float.random(in: 8.0...24.0, using: &generator)
            )
        case .pole:
            return SIMD3<Float>(
                Float.random(in: 0.4...0.9, using: &generator),
                Float.random(in: 8.0...18.0, using: &generator),
                Float.random(in: 0.4...0.9, using: &generator)
            )
        case .crate:
            return SIMD3<Float>(
                Float.random(in: 1.0...3.0, using: &generator),
                Float.random(in: 1.0...3.5, using: &generator),
                Float.random(in: 1.0...3.0, using: &generator)
            )
        case .rock:
            return SIMD3<Float>(
                Float.random(in: 1.2...3.2, using: &generator),
                Float.random(in: 0.8...2.2, using: &generator),
                Float.random(in: 1.2...3.2, using: &generator)
            )
        case .marker:
            return SIMD3<Float>(
                Float.random(in: 0.8...1.6, using: &generator),
                Float.random(in: 1.5...3.2, using: &generator),
                Float.random(in: 0.8...1.6, using: &generator)
            )
        case .distantBelt:
            return SIMD3<Float>(16.0, 32.0, 8.0)
        }
    }
}

private struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xCAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
```

## DroneUAVDemo/Scene/EnvironmentObjectFactory.swift
```swift
import AppKit
import SceneKit
import simd

enum EnvironmentObjectFactory {
    static func makeNode(for descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        switch descriptor.kind {
        case .tree:
            return makeTreeNode(descriptor: descriptor)
        case .building:
            return makeBuildingNode(descriptor: descriptor)
        case .pole:
            return makePoleNode(descriptor: descriptor)
        case .crate:
            return makeCrateNode(descriptor: descriptor)
        case .rock:
            return makeRockNode(descriptor: descriptor)
        case .marker:
            return makeMarkerNode(descriptor: descriptor)
        case .distantBelt:
            return makeDistantMaskNode(descriptor: descriptor)
        }
    }

    private static func makeTreeNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))
        let archetype = TreeArchetype.allCases[Int(rng.nextFloat() * Float(TreeArchetype.allCases.count)) % TreeArchetype.allCases.count]

        let parent = SCNNode()
        parent.name = "obstacle_tree_\(descriptor.id.uuidString)"
        parent.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        parent.eulerAngles = SCNVector3(0, rng.nextFloat() * .pi * 2.0, 0)

        let baseHeight = descriptor.size.y.clamped(to: 5.0...24.0)
        let baseWidth = descriptor.size.x.clamped(to: 1.4...6.4)
        let trunkHeight = baseHeight * archetype.trunkHeightFactor * (0.92 + rng.nextFloat() * 0.16)
        let trunkRadius = max(0.08, baseWidth * archetype.trunkRadiusFactor * (0.92 + rng.nextFloat() * 0.16))
        let crownScale = (baseWidth * archetype.crownScaleFactor).clamped(to: 1.2...8.0)

        let bark = EnvironmentMaterialRegistry.barkMaterial(variant: Int(rng.next() % 4))
        let leaf = EnvironmentMaterialRegistry.leafMaterial(variant: Int(rng.next() % 4), biome: descriptor.biome)

        let trunk = SCNNode(geometry: SCNCylinder(radius: CGFloat(trunkRadius), height: CGFloat(trunkHeight)))
        trunk.position = SCNVector3(0, trunkHeight * 0.5, 0)
        trunk.geometry?.materials = [bark]
        parent.addChildNode(trunk)

        switch archetype {
        case .oak:
            let crownA = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.42)))
            crownA.position = SCNVector3(0, trunkHeight + crownScale * 0.36, 0)
            crownA.scale = SCNVector3(1.10, 0.82, 1.08)
            crownA.geometry?.materials = [leaf]

            let crownB = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.28)))
            crownB.position = SCNVector3(crownScale * 0.14, trunkHeight + crownScale * 0.58, -crownScale * 0.10)
            crownB.geometry?.materials = [leaf]

            parent.addChildNode(crownA)
            parent.addChildNode(crownB)

        case .pine:
            let crownLower = SCNNode(geometry: SCNCone(topRadius: 0.08, bottomRadius: CGFloat(crownScale * 0.38), height: CGFloat(crownScale * 1.1)))
            crownLower.position = SCNVector3(0, trunkHeight + crownScale * 0.40, 0)
            crownLower.geometry?.materials = [leaf]

            let crownUpper = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: CGFloat(crownScale * 0.26), height: CGFloat(crownScale * 0.9)))
            crownUpper.position = SCNVector3(0, trunkHeight + crownScale * 0.92, 0)
            crownUpper.geometry?.materials = [leaf]

            parent.addChildNode(crownLower)
            parent.addChildNode(crownUpper)

        case .birch:
            let crown = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.34)))
            crown.scale = SCNVector3(1.0, 1.24, 0.95)
            crown.position = SCNVector3(0, trunkHeight + crownScale * 0.48, 0)
            crown.geometry?.materials = [leaf]
            parent.addChildNode(crown)

        case .acacia:
            let canopy = SCNNode(geometry: SCNCylinder(radius: CGFloat(crownScale * 0.46), height: CGFloat(crownScale * 0.18)))
            canopy.position = SCNVector3(0, trunkHeight + crownScale * 0.62, 0)
            canopy.geometry?.materials = [leaf]

            let canopyLobe = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.24)))
            canopyLobe.position = SCNVector3(crownScale * 0.22, trunkHeight + crownScale * 0.64, -crownScale * 0.12)
            canopyLobe.geometry?.materials = [leaf]

            parent.addChildNode(canopy)
            parent.addChildNode(canopyLobe)
        }

        return parent
    }

    private static func makeBuildingNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))
        let facadeFamily = pickFacadeFamily(for: descriptor.biome, random: rng.nextFloat())
        let roofFamily = pickRoofFamily(random: rng.nextFloat())

        let facadeMaterial = EnvironmentMaterialRegistry.facadeMaterial(family: facadeFamily, variant: Int(rng.next() % 4))
        let roofMaterial = EnvironmentMaterialRegistry.roofMaterial(family: roofFamily, variant: Int(rng.next() % 3))

        let width = max(6.0, descriptor.size.x)
        let depth = max(6.0, descriptor.size.z)
        let height = max(9.0, descriptor.size.y)

        let root = SCNNode()
        root.name = "obstacle_building_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, rng.nextFloat() * .pi * 2.0, 0)

        let body = SCNNode(geometry: SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(depth),
            chamferRadius: CGFloat(min(width, depth) * 0.02)
        ))
        body.position = SCNVector3(0, height * 0.5, 0)
        body.geometry?.materials = [facadeMaterial]

        let roofHeight = max(0.5, min(2.4, height * 0.05))
        let roof = SCNNode(geometry: SCNBox(
            width: CGFloat(width * 1.02),
            height: CGFloat(roofHeight),
            length: CGFloat(depth * 1.02),
            chamferRadius: 0.0
        ))
        roof.position = SCNVector3(0, height + roofHeight * 0.5, 0)
        roof.geometry?.materials = [roofMaterial]

        root.addChildNode(body)
        root.addChildNode(roof)
        return root
    }

    private static func makePoleNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNCylinder(radius: CGFloat(descriptor.size.x * 0.28), height: CGFloat(descriptor.size.y))
        geometry.materials = [EnvironmentMaterialRegistry.utilityPoleMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_pole_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeCrateNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNBox(
            width: CGFloat(descriptor.size.x),
            height: CGFloat(descriptor.size.y),
            length: CGFloat(descriptor.size.z),
            chamferRadius: CGFloat(min(descriptor.size.x, descriptor.size.z) * 0.06)
        )
        geometry.materials = [EnvironmentMaterialRegistry.crateMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_crate_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeRockNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNSphere(radius: CGFloat(descriptor.size.x * 0.46))
        geometry.materials = [EnvironmentMaterialRegistry.rockMaterial]

        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(1.0, descriptor.size.y / max(0.01, descriptor.size.x), 1.0)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y * 0.45, descriptor.position.z)
        node.name = "obstacle_rock_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeMarkerNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNCone(topRadius: 0.0, bottomRadius: CGFloat(descriptor.size.x * 0.55), height: CGFloat(descriptor.size.y))
        geometry.materials = [EnvironmentMaterialRegistry.markerMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_marker_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeDistantMaskNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))

        let root = SCNNode()
        root.name = "distant_mask_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, rng.nextFloat() * .pi * 2.0, 0)

        switch descriptor.biome {
        case .forest:
            for index in 0..<3 {
                let cone = SCNNode(geometry: SCNCone(
                    topRadius: 0.02,
                    bottomRadius: CGFloat(descriptor.size.x * (0.32 + Float(index) * 0.10)),
                    height: CGFloat(descriptor.size.y * (0.34 + Float(index) * 0.18))
                ))
                cone.position = SCNVector3(
                    Float(index - 1) * descriptor.size.x * 0.18,
                    descriptor.size.y * (0.16 + Float(index) * 0.20),
                    0
                )
                cone.geometry?.materials = [EnvironmentMaterialRegistry.farForestMaterial]
                root.addChildNode(cone)
            }

        case .city:
            for _ in 0..<3 {
                let width = descriptor.size.x * (0.26 + rng.nextFloat() * 0.18)
                let depth = descriptor.size.z * (0.24 + rng.nextFloat() * 0.22)
                let height = descriptor.size.y * (0.62 + rng.nextFloat() * 0.48)
                let block = SCNNode(geometry: SCNBox(
                    width: CGFloat(width),
                    height: CGFloat(height),
                    length: CGFloat(depth),
                    chamferRadius: 0.0
                ))
                block.position = SCNVector3(
                    (rng.nextFloat() - 0.5) * descriptor.size.x * 0.65,
                    height * 0.5,
                    (rng.nextFloat() - 0.5) * descriptor.size.z * 0.45
                )
                block.geometry?.materials = [EnvironmentMaterialRegistry.farCityMaterial]
                root.addChildNode(block)
            }

        case .field, .gridDemo:
            let mound = SCNNode(geometry: SCNBox(
                width: CGFloat(descriptor.size.x),
                height: CGFloat(max(1.2, descriptor.size.y * 0.45)),
                length: CGFloat(descriptor.size.z),
                chamferRadius: CGFloat(descriptor.size.x * 0.08)
            ))
            mound.position = SCNVector3(0, max(1.2, descriptor.size.y * 0.45) * 0.5, 0)
            mound.geometry?.materials = [EnvironmentMaterialRegistry.farFieldMaterial]
            root.addChildNode(mound)
        }

        return root
    }

    private static func descriptorSeed(_ descriptor: EnvironmentObjectDescriptor) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(descriptor.position.x.bitPattern)
        hasher.combine(descriptor.position.y.bitPattern)
        hasher.combine(descriptor.position.z.bitPattern)
        hasher.combine(descriptor.size.x.bitPattern)
        hasher.combine(descriptor.size.y.bitPattern)
        hasher.combine(descriptor.size.z.bitPattern)
        hasher.combine(descriptor.kind.rawValue)
        hasher.combine(descriptor.biome.rawValue)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private static func pickFacadeFamily(for biome: TerrainPreset, random: Float) -> BuildingFacadeFamily {
        let value = random.clamped(to: 0.0...1.0)
        switch biome {
        case .city:
            if value < 0.30 { return .concretePanel }
            if value < 0.52 { return .brick }
            if value < 0.76 { return .plaster }
            return .glassAccent
        case .field:
            if value < 0.46 { return .brick }
            if value < 0.78 { return .plaster }
            return .concretePanel
        case .forest:
            if value < 0.34 { return .brick }
            if value < 0.78 { return .plaster }
            return .concretePanel
        case .gridDemo:
            if value < 0.5 { return .concretePanel }
            return .brick
        }
    }

    private static func pickRoofFamily(random: Float) -> BuildingRoofFamily {
        random < 0.42 ? .tile : .flatMetal
    }
}

enum EnvironmentMaterialRegistry {
    static func groundMaterial(for terrain: TerrainPreset) -> SCNMaterial {
        switch terrain {
        case .gridDemo:
            return terrainMaterial(
                albedo: ["Assets/Terrain/Field/field_ground_01"],
                detail: ["Assets/Terrain/Field/field_dirt_01"],
                fallback: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1.0),
                roughness: 0.88,
                metalness: 0.04
            )
        case .field:
            return terrainMaterial(
                albedo: ["Assets/Terrain/Field/field_ground_01", "Assets/Terrain/Field/field_ground_02"],
                detail: ["Assets/Terrain/Field/field_dirt_01"],
                fallback: NSColor(calibratedRed: 0.24, green: 0.31, blue: 0.20, alpha: 1.0),
                roughness: 0.94,
                metalness: 0.02
            )
        case .forest:
            return terrainMaterial(
                albedo: ["Assets/Terrain/Forest/forest_ground_01", "Assets/Terrain/Forest/forest_ground_02"],
                detail: ["Assets/Terrain/Forest/forest_leaf_scatter_01"],
                fallback: NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.14, alpha: 1.0),
                roughness: 0.96,
                metalness: 0.01
            )
        case .city:
            return terrainMaterial(
                albedo: ["Assets/Terrain/City/city_ground_asphalt_01", "Assets/Terrain/City/city_ground_concrete_01"],
                detail: ["Assets/Terrain/City/city_ground_pavement_01"],
                fallback: NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.23, alpha: 1.0),
                roughness: 0.78,
                metalness: 0.08
            )
        }
    }

    static func barkMaterial(variant: Int) -> SCNMaterial {
        pbrMaterial(
            textureCandidates: [barkTextureSlots[variant % barkTextureSlots.count]],
            fallbackColor: barkFallbacks[variant % barkFallbacks.count],
            roughness: 0.88,
            metalness: 0.02
        )
    }

    static func leafMaterial(variant: Int, biome: TerrainPreset) -> SCNMaterial {
        let tone: NSColor
        switch biome {
        case .forest:
            tone = NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.20, alpha: 1.0)
        case .field:
            tone = NSColor(calibratedRed: 0.33, green: 0.52, blue: 0.24, alpha: 1.0)
        case .city:
            tone = NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.22, alpha: 1.0)
        case .gridDemo:
            tone = NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.28, alpha: 1.0)
        }

        let material = pbrMaterial(
            textureCandidates: [leafTextureSlots[variant % leafTextureSlots.count]],
            fallbackColor: tone,
            roughness: 0.84,
            metalness: 0.0
        )
        material.isDoubleSided = true
        material.transparencyMode = SCNTransparencyMode.dualLayer
        return material
    }

    fileprivate static func facadeMaterial(family: BuildingFacadeFamily, variant: Int) -> SCNMaterial {
        let slots = facadeTextureSlots[family] ?? facadeTextureSlots[.concretePanel]!
        let fallbacks = facadeFallbacks[family] ?? [NSColor(calibratedWhite: 0.52, alpha: 1.0)]
        return pbrMaterial(
            textureCandidates: [slots[variant % slots.count]],
            fallbackColor: fallbacks[variant % fallbacks.count],
            roughness: 0.70,
            metalness: family == .glassAccent ? 0.22 : 0.08
        )
    }

    fileprivate static func roofMaterial(family: BuildingRoofFamily, variant: Int) -> SCNMaterial {
        let slots = roofTextureSlots[family] ?? roofTextureSlots[.flatMetal]!
        let fallbacks = roofFallbacks[family] ?? [NSColor(calibratedWhite: 0.34, alpha: 1.0)]
        return pbrMaterial(
            textureCandidates: [slots[variant % slots.count]],
            fallbackColor: fallbacks[variant % fallbacks.count],
            roughness: family == .flatMetal ? 0.56 : 0.74,
            metalness: family == .flatMetal ? 0.24 : 0.06
        )
    }

    static let utilityPoleMaterial = pbrMaterial(
        textureCandidates: [["Assets/Buildings/Facades/facade_concrete_01"]],
        fallbackColor: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.70, alpha: 1.0),
        roughness: 0.58,
        metalness: 0.18
    )
    static let crateMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/Field/field_dirt_01"]],
        fallbackColor: NSColor(calibratedRed: 0.35, green: 0.27, blue: 0.20, alpha: 1.0),
        roughness: 0.79,
        metalness: 0.02
    )
    static let rockMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/Forest/forest_ground_02"]],
        fallbackColor: NSColor(calibratedRed: 0.38, green: 0.39, blue: 0.40, alpha: 1.0),
        roughness: 0.92,
        metalness: 0.0
    )
    static let markerMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/City/city_ground_pavement_01"]],
        fallbackColor: NSColor.systemOrange,
        roughness: 0.56,
        metalness: 0.04
    )
    static let farForestMaterial = pbrMaterial(
        textureCandidates: [["Assets/Trees/Leaves/leaf_forest_02"]],
        fallbackColor: NSColor(calibratedRed: 0.14, green: 0.25, blue: 0.16, alpha: 1.0),
        roughness: 0.95,
        metalness: 0.0
    )
    static let farCityMaterial = pbrMaterial(
        textureCandidates: [["Assets/Buildings/Facades/facade_concrete_02"]],
        fallbackColor: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.27, alpha: 0.96),
        roughness: 0.82,
        metalness: 0.06
    )
    static let farFieldMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/Field/field_ground_02"]],
        fallbackColor: NSColor(calibratedRed: 0.20, green: 0.28, blue: 0.18, alpha: 0.95),
        roughness: 0.90,
        metalness: 0.0
    )

    private static let barkTextureSlots: [[String]] = [
        ["Assets/Trees/Bark/bark_01", "bark_01"],
        ["Assets/Trees/Bark/bark_02", "bark_02"],
        ["Assets/Trees/Bark/bark_03", "bark_03"],
        ["Assets/Trees/Bark/bark_04", "bark_04"]
    ]
    private static let barkFallbacks: [NSColor] = [
        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.18, alpha: 1.0),
        NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.20, alpha: 1.0),
        NSColor(calibratedRed: 0.48, green: 0.36, blue: 0.24, alpha: 1.0),
        NSColor(calibratedRed: 0.39, green: 0.29, blue: 0.19, alpha: 1.0)
    ]

    private static let leafTextureSlots: [[String]] = [
        ["Assets/Trees/Leaves/leaf_forest_01", "leaf_forest_01"],
        ["Assets/Trees/Leaves/leaf_forest_02", "leaf_forest_02"],
        ["Assets/Trees/Leaves/leaf_field_01", "leaf_field_01"],
        ["Assets/Trees/Leaves/leaf_city_01", "leaf_city_01"]
    ]

    private static let facadeTextureSlots: [BuildingFacadeFamily: [[String]]] = [
        .brick: [
            ["Assets/Buildings/Facades/facade_brick_01", "facade_brick_01"],
            ["Assets/Buildings/Facades/facade_brick_02", "facade_brick_02"],
            ["Assets/Buildings/Facades/facade_brick_03", "facade_brick_03"],
            ["Assets/Buildings/Facades/facade_brick_04", "facade_brick_04"]
        ],
        .plaster: [
            ["Assets/Buildings/Facades/facade_plaster_01", "facade_plaster_01"],
            ["Assets/Buildings/Facades/facade_plaster_02", "facade_plaster_02"],
            ["Assets/Buildings/Facades/facade_plaster_03", "facade_plaster_03"],
            ["Assets/Buildings/Facades/facade_plaster_04", "facade_plaster_04"]
        ],
        .concretePanel: [
            ["Assets/Buildings/Facades/facade_concrete_01", "facade_concrete_01"],
            ["Assets/Buildings/Facades/facade_concrete_02", "facade_concrete_02"],
            ["Assets/Buildings/Facades/facade_concrete_03", "facade_concrete_03"],
            ["Assets/Buildings/Facades/facade_concrete_04", "facade_concrete_04"]
        ],
        .glassAccent: [
            ["Assets/Buildings/Facades/facade_glass_01", "facade_glass_01"],
            ["Assets/Buildings/Facades/facade_glass_02", "facade_glass_02"],
            ["Assets/Buildings/Facades/facade_glass_03", "facade_glass_03"],
            ["Assets/Buildings/Facades/facade_glass_04", "facade_glass_04"]
        ]
    ]

    private static let facadeFallbacks: [BuildingFacadeFamily: [NSColor]] = [
        .brick: [
            NSColor(calibratedRed: 0.52, green: 0.32, blue: 0.28, alpha: 1.0),
            NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.31, alpha: 1.0)
        ],
        .plaster: [
            NSColor(calibratedRed: 0.72, green: 0.70, blue: 0.64, alpha: 1.0),
            NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.62, alpha: 1.0)
        ],
        .concretePanel: [
            NSColor(calibratedRed: 0.52, green: 0.55, blue: 0.58, alpha: 1.0),
            NSColor(calibratedRed: 0.46, green: 0.50, blue: 0.54, alpha: 1.0)
        ],
        .glassAccent: [
            NSColor(calibratedRed: 0.40, green: 0.47, blue: 0.56, alpha: 1.0),
            NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.52, alpha: 1.0)
        ]
    ]

    private static let roofTextureSlots: [BuildingRoofFamily: [[String]]] = [
        .tile: [
            ["Assets/Buildings/Roofs/roof_tile_01", "roof_tile_01"],
            ["Assets/Buildings/Roofs/roof_tile_02", "roof_tile_02"],
            ["Assets/Buildings/Roofs/roof_tile_03", "roof_tile_03"]
        ],
        .flatMetal: [
            ["Assets/Buildings/Roofs/roof_metal_01", "roof_metal_01"],
            ["Assets/Buildings/Roofs/roof_metal_02", "roof_metal_02"],
            ["Assets/Buildings/Roofs/roof_metal_03", "roof_metal_03"]
        ]
    ]

    private static let roofFallbacks: [BuildingRoofFamily: [NSColor]] = [
        .tile: [
            NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.20, alpha: 1.0),
            NSColor(calibratedRed: 0.48, green: 0.29, blue: 0.22, alpha: 1.0)
        ],
        .flatMetal: [
            NSColor(calibratedRed: 0.28, green: 0.30, blue: 0.33, alpha: 1.0),
            NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.38, alpha: 1.0)
        ]
    ]

    private static func terrainMaterial(
        albedo: [String],
        detail: [String],
        fallback: NSColor,
        roughness: CGFloat,
        metalness: CGFloat
    ) -> SCNMaterial {
        let material = pbrMaterial(
            textureCandidates: [albedo + detail],
            fallbackColor: fallback,
            roughness: roughness,
            metalness: metalness
        )
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(24.0, 24.0, 1.0)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        return material
    }

    private static func pbrMaterial(
        textureCandidates: [[String]],
        fallbackColor: NSColor,
        roughness: CGFloat,
        metalness: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = resolveTexture(textureCandidates) ?? fallbackColor
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        return material
    }

    private static func resolveTexture(_ candidates: [[String]]) -> NSImage? {
        for entry in candidates {
            for name in entry {
                if let image = image(named: name) {
                    return image
                }
            }
        }
        return nil
    }

    private static func image(named name: String) -> NSImage? {
        if let direct = NSImage(named: NSImage.Name(name)) {
            return direct
        }
        if let shortName = name.split(separator: "/").last {
            return NSImage(named: NSImage.Name(String(shortName)))
        }
        return nil
    }
}

private enum TreeArchetype: CaseIterable {
    case oak
    case pine
    case birch
    case acacia

    var trunkHeightFactor: Float {
        switch self {
        case .oak: return 0.58
        case .pine: return 0.52
        case .birch: return 0.68
        case .acacia: return 0.64
        }
    }

    var trunkRadiusFactor: Float {
        switch self {
        case .oak: return 0.14
        case .pine: return 0.11
        case .birch: return 0.09
        case .acacia: return 0.12
        }
    }

    var crownScaleFactor: Float {
        switch self {
        case .oak: return 0.86
        case .pine: return 0.78
        case .birch: return 0.70
        case .acacia: return 0.82
        }
    }
}

fileprivate enum BuildingFacadeFamily {
    case brick
    case plaster
    case concretePanel
    case glassAccent
}

fileprivate enum BuildingRoofFamily {
    case tile
    case flatMetal
}

private struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xBEEF_BABE : seed
    }

    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }

    mutating func nextFloat() -> Float {
        Float(next() & 0xFFFF) / Float(0xFFFF)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
```

## DroneUAVDemo/Scene/DroneSceneController.swift
```swift
import AppKit
import SceneKit
import simd

private struct WingmanVisual {
    var rootNode: SCNNode
    var propellerNodes: [SCNNode]
    var spinDirections: [Float]
    var spinAngles: [Float]
}

final class DroneSceneController {
    let scene: SCNScene

    private let freeCameraNode: SCNNode
    private let followCameraNode = SCNNode()
    private let fpvYawNode = SCNNode()
    private let fpvPitchNode = SCNNode()
    private let fpvCameraNode = SCNNode()
    private let orbitCameraNode = SCNNode()

    private let sunLightNode: SCNNode
    private let gridNode: SCNNode
    private let axesNode: SCNNode
    private let groundNode: SCNNode

    private let weatherNode = SCNNode()
    private var rainSystem: SCNParticleSystem?
    private var snowSystem: SCNParticleSystem?
    private var thunderPulse: Float = 0.0
    private var cameraNoisePhase: Float = 0.0

    private let scenePopulationService: ScenePopulationService

    private var droneNode: SCNNode
    private var fpvAnchorNode: SCNNode
    private var propellerNodes: [SCNNode]
    private var spinDirections: [Float]
    private var spinAngles: [Float]
    private var componentNodes: [DamageComponent: [SCNNode]]
    private var fpvObstructionHidingActive: Bool = false

    private var obstacleMap: [UUID: SCNNode] = [:]
    private(set) var environmentObstacles: [CollisionObstacle] = []
    private var dynamicObstacleCenters: [UUID: SIMD3<Float>] = [:]
    private var wingmanVisuals: [UUID: WingmanVisual] = [:]

    private var orbitAngle: Float = 0.0
    private var activeProfile: DroneModelProfile
    private var currentWeather: WeatherModel = .normal

    init(initialProfile: DroneModelProfile) {
        self.activeProfile = initialProfile

        let setup = SceneFactory.makeScene()
        self.scene = setup.scene
        self.freeCameraNode = setup.cameraNode
        self.sunLightNode = setup.sunLightNode
        self.gridNode = setup.gridNode
        self.axesNode = setup.axesNode
        self.groundNode = setup.groundNode

        let droneVisual = DroneModelBuilder.build(profile: initialProfile)
        self.droneNode = droneVisual.rootNode
        self.fpvAnchorNode = droneVisual.fpvAnchorNode
        self.propellerNodes = droneVisual.propellerNodes
        self.spinDirections = droneVisual.propellerSpinDirections
        self.spinAngles = Array(repeating: 0.0, count: droneVisual.propellerNodes.count)
        self.componentNodes = droneVisual.componentNodes

        scene.rootNode.addChildNode(droneNode)

        self.scenePopulationService = ScenePopulationService(rootNode: scene.rootNode)

        configureCameraNode(followCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(fpvCameraNode, fov: initialProfile.cameraPreset.fpvFov)
        configureCameraNode(orbitCameraNode, fov: initialProfile.cameraPreset.fpvFov)

        scene.rootNode.addChildNode(followCameraNode)
        scene.rootNode.addChildNode(orbitCameraNode)

        fpvYawNode.name = "fpvYawMount"
        fpvPitchNode.name = "fpvPitchMount"
        fpvYawNode.addChildNode(fpvPitchNode)
        fpvPitchNode.addChildNode(fpvCameraNode)
        fpvAnchorNode.addChildNode(fpvYawNode)

        weatherNode.name = "weatherNode"
        scene.rootNode.addChildNode(weatherNode)

        applyTerrainVisualStyle(.gridDemo)
    }

    func pointOfView(for mode: CameraMode) -> SCNNode {
        switch mode {
        case .free:
            return freeCameraNode
        case .follow:
            return followCameraNode
        case .fpv:
            return fpvCameraNode
        case .orbit:
            return orbitCameraNode
        }
    }

    func dollyFreeCamera(by step: Float) {
        let forward = simd_normalize(simd_act(freeCameraNode.simdOrientation, SIMD3<Float>(0, 0, -1)))
        freeCameraNode.simdPosition += forward * step
    }

    func setDroneProfile(_ profile: DroneModelProfile) {
        activeProfile = profile

        droneNode.removeFromParentNode()

        let droneVisual = DroneModelBuilder.build(profile: profile)
        droneNode = droneVisual.rootNode
        fpvAnchorNode = droneVisual.fpvAnchorNode
        propellerNodes = droneVisual.propellerNodes
        spinDirections = droneVisual.propellerSpinDirections
        componentNodes = droneVisual.componentNodes
        spinAngles = Array(repeating: 0.0, count: propellerNodes.count)

        scene.rootNode.addChildNode(droneNode)
        fpvAnchorNode.addChildNode(fpvYawNode)
    }

    func regenerateEnvironment(_ terrain: TerrainConfiguration) {
        let (descriptors, nodesByID) = scenePopulationService.populate(with: terrain)

        obstacleMap = [:]
        for descriptor in descriptors where descriptor.isCollidable {
            if let node = nodesByID[descriptor.id] {
                obstacleMap[descriptor.id] = node
            }
        }

        environmentObstacles = descriptors
            .filter(\.isCollidable)
            .map {
                CollisionObstacle(id: $0.id, center: $0.position, radius: $0.boundingRadius)
            }

        applyTerrainVisualStyle(terrain.preset)
    }

    func applyWeatherVisual(_ weather: WeatherModel) {
        currentWeather = weather

        let factors = weather.effectiveFactors
        scene.fogStartDistance = CGFloat(32.0 * factors.visibilityFactor + 4.0)
        scene.fogEndDistance = CGFloat(260.0 * factors.visibilityFactor + 24.0)
        scene.fogDensityExponent = CGFloat(0.75 + (1.0 - factors.visibilityFactor) * 2.7)

        let fogColor: NSColor
        switch weather.preset {
        case .rain:
            fogColor = NSColor(calibratedRed: 0.38, green: 0.42, blue: 0.49, alpha: 1.0)
        case .snow:
            fogColor = NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.90, alpha: 1.0)
        case .fog:
            fogColor = NSColor(calibratedWhite: 0.84, alpha: 1.0)
        case .smog:
            fogColor = NSColor(calibratedRed: 0.56, green: 0.54, blue: 0.50, alpha: 1.0)
        case .thunderstorm:
            fogColor = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.29, alpha: 1.0)
        case .wind, .normal:
            fogColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 1.0)
        }

        scene.fogColor = fogColor
        updateWeatherParticles(weather)
    }

    func update(
        with state: DroneState,
        camera: CameraConfiguration,
        damage: DamageState,
        thermal: ThermalState,
        diagnosticMode: DiagnosticOverlayMode,
        deltaTime: Float
    ) {
        droneNode.position = SCNVector3(state.position.x, state.position.y, state.position.z)
        let droneOrientation = orientationQuaternion(from: state.orientation)
        droneNode.simdOrientation = droneOrientation

        fpvObstructionHidingActive = (camera.mode == .fpv) && camera.fpv.hideObstructingParts

        rotatePropellers(throttle: state.throttle, deltaTime: deltaTime)
        applyComponentOverlays(damage: damage, thermal: thermal, mode: diagnosticMode)
        updateCameras(state: state, droneOrientation: droneOrientation, settings: camera, deltaTime: deltaTime)
        updateWeatherAnimation(deltaTime: deltaTime, weather: currentWeather)
    }

    func updateCollisionDebug(risk: CollisionAnalysisSnapshot, enabled: Bool) {
        guard enabled else {
            obstacleMap.values.forEach { clearEmission(on: $0) }
            wingmanVisuals.values.forEach { clearEmission(on: $0.rootNode) }
            return
        }

        let highlightColor: NSColor
        switch risk.emergencyAction {
        case .none:
            highlightColor = .clear
        case .slowDown:
            highlightColor = NSColor.systemYellow.withAlphaComponent(0.55)
        case .hover, .avoid:
            highlightColor = NSColor.systemOrange.withAlphaComponent(0.58)
        case .emergencyStop:
            highlightColor = NSColor.systemRed.withAlphaComponent(0.62)
        }

        let nearestID = risk.nearestObstacleID

        for (id, node) in obstacleMap {
            if id == nearestID {
                applyEmission(on: node, color: highlightColor)
            } else {
                clearEmission(on: node)
            }
        }

        for (id, visual) in wingmanVisuals {
            if id == nearestID {
                applyEmission(on: visual.rootNode, color: highlightColor)
            } else {
                clearEmission(on: visual.rootNode)
            }
        }
    }

    func obstacleCenter(for id: UUID) -> SIMD3<Float>? {
        if let center = dynamicObstacleCenters[id] {
            return center
        }
        return environmentObstacles.first(where: { $0.id == id })?.center
    }

    func updateFleetWingmen(
        _ wingmen: [DroneEntity],
        profile: DroneModelProfile,
        throttle: Float,
        deltaTime: Float
    ) {
        let incomingIDs = Set(wingmen.map(\.id))
        let obsoleteIDs = wingmanVisuals.keys.filter { !incomingIDs.contains($0) }

        for id in obsoleteIDs {
            if let visual = wingmanVisuals[id] {
                visual.rootNode.removeFromParentNode()
            }
            wingmanVisuals[id] = nil
            dynamicObstacleCenters[id] = nil
        }

        for wingman in wingmen {
            if wingmanVisuals[wingman.id] == nil {
                wingmanVisuals[wingman.id] = makeWingmanVisual(profile: profile)
                if let root = wingmanVisuals[wingman.id]?.rootNode {
                    scene.rootNode.addChildNode(root)
                }
            }

            guard var visual = wingmanVisuals[wingman.id] else {
                continue
            }

            visual.rootNode.simdPosition = wingman.position
            let velocityMagnitude = simd_length(wingman.velocity)
            if velocityMagnitude > 0.1 {
                let yaw = atan2(wingman.velocity.x, wingman.velocity.z)
                visual.rootNode.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0.0, 1.0, 0.0))
            }

            rotateWingmanPropellers(visual: &visual, throttle: throttle, deltaTime: deltaTime)
            wingmanVisuals[wingman.id] = visual
            dynamicObstacleCenters[wingman.id] = wingman.position
        }
    }

    private func configureCameraNode(_ node: SCNNode, fov: Float) {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fov)
        camera.zNear = 0.01
        camera.zFar = 900
        node.camera = camera
    }

    private func updateCameras(
        state: DroneState,
        droneOrientation: simd_quatf,
        settings: CameraConfiguration,
        deltaTime: Float
    ) {
        let blend = (1.0 - settings.smoothing.clamped(to: 0.0...0.95)) * deltaTime * 8.0
        let response = blend.clamped(to: 0.05...1.0)

        let dronePos = state.position
        let yawOnly = simd_quatf(angle: state.orientation.z, axis: SIMD3<Float>(0, 1, 0))

        let followOffset = SIMD3<Float>(
            settings.follow.lateralOffset,
            settings.follow.height,
            settings.follow.distance
        )
        let followOffsetWorld = simd_act(yawOnly, followOffset)
        let followTargetPos = dronePos + followOffsetWorld
        followCameraNode.simdPosition = simd_mix(followCameraNode.simdPosition, followTargetPos, SIMD3<Float>(repeating: response))
        followCameraNode.simdLook(at: dronePos, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        orbitAngle += deltaTime * settings.orbit.angularSpeed.clamped(to: 0.05...2.0)
        let orbitDistance = settings.orbit.distance.clamped(to: settings.orbit.minDistance...settings.orbit.maxDistance)
        let orbitPos = SIMD3<Float>(
            dronePos.x + cos(orbitAngle) * orbitDistance,
            dronePos.y + settings.orbit.height,
            dronePos.z + sin(orbitAngle) * orbitDistance
        )
        orbitCameraNode.simdPosition = simd_mix(orbitCameraNode.simdPosition, orbitPos, SIMD3<Float>(repeating: response))
        orbitCameraNode.simdLook(at: dronePos, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        cameraNoisePhase += deltaTime * 5.6
        let shake = settings.fpv.shake.clamped(to: 0.0...0.3)
        let sway = SIMD3<Float>(
            sin(cameraNoisePhase * 2.7) * 0.015 * shake,
            sin(cameraNoisePhase * 1.9 + 0.5) * 0.010 * shake,
            0.0
        )
        fpvPitchNode.simdPosition = settings.fpv.mountOffset + sway

        let velocityYaw = atan2(state.velocity.x, max(0.001, state.velocity.z))
        let relativeYaw = (velocityYaw - state.orientation.z).clamped(
            to: (-settings.fpv.yawLimitDeg.degreesToRadians)...(settings.fpv.yawLimitDeg.degreesToRadians)
        ) * 0.24
        fpvYawNode.eulerAngles.y = CGFloat(relativeYaw)

        let gimbalPitch = (-state.velocity.y * 0.05).clamped(
            to: (-settings.fpv.pitchLimitDeg.degreesToRadians)...(settings.fpv.pitchLimitDeg.degreesToRadians)
        )
        let stabilizer = settings.fpv.stabilization.clamped(to: 0.0...1.0)
        let localPitch = (-state.orientation.y * stabilizer * 0.30) + gimbalPitch
        let localRoll = -state.orientation.x * stabilizer * 0.30
        fpvPitchNode.eulerAngles = SCNVector3(localPitch, 0.0, localRoll)

        let fov = CGFloat(settings.fov.clamped(to: 30.0...110.0))
        followCameraNode.camera?.fieldOfView = fov
        orbitCameraNode.camera?.fieldOfView = fov
        fpvCameraNode.camera?.fieldOfView = fov
        freeCameraNode.camera?.fieldOfView = fov
        fpvCameraNode.camera?.zNear = CGFloat(settings.fpv.nearClip.clamped(to: 0.005...0.25))
        freeCameraNode.camera?.zNear = 0.01

        _ = droneOrientation
    }

    private func rotatePropellers(throttle: Float, deltaTime: Float) {
        let profileFactor = (activeProfile.maxHorizontalSpeedMps / 20.0).clamped(to: 0.55...1.2)
        let idleSpeed: Float = 8.0
        let maxAdditionalSpeed: Float = 132.0 * profileFactor
        let spinSpeed = idleSpeed + maxAdditionalSpeed * throttle

        for index in propellerNodes.indices {
            spinAngles[index] += spinDirections[index] * spinSpeed * deltaTime
            propellerNodes[index].eulerAngles.y = CGFloat(spinAngles[index])
        }
    }

    private func rotateWingmanPropellers(visual: inout WingmanVisual, throttle: Float, deltaTime: Float) {
        let profileFactor = (activeProfile.maxHorizontalSpeedMps / 20.0).clamped(to: 0.55...1.2)
        let idleSpeed: Float = 6.4
        let maxAdditionalSpeed: Float = 114.0 * profileFactor
        let spinSpeed = idleSpeed + maxAdditionalSpeed * throttle

        for index in visual.propellerNodes.indices {
            visual.spinAngles[index] += visual.spinDirections[index] * spinSpeed * deltaTime
            visual.propellerNodes[index].eulerAngles.y = CGFloat(visual.spinAngles[index])
        }
    }

    private func makeWingmanVisual(profile: DroneModelProfile) -> WingmanVisual {
        let model = DroneModelBuilder.build(profile: profile)
        model.rootNode.opacity = 0.74
        model.rootNode.scale = SCNVector3(0.86, 0.86, 0.86)
        tintWingmanNode(model.rootNode)

        return WingmanVisual(
            rootNode: model.rootNode,
            propellerNodes: model.propellerNodes,
            spinDirections: model.propellerSpinDirections,
            spinAngles: Array(repeating: 0.0, count: model.propellerNodes.count)
        )
    }

    private func tintWingmanNode(_ node: SCNNode) {
        if let geometry = node.geometry {
            geometry.materials.forEach {
                $0.multiply.contents = NSColor(calibratedRed: 0.70, green: 0.90, blue: 1.0, alpha: 1.0)
            }
        }

        for child in node.childNodes {
            tintWingmanNode(child)
        }
    }

    private func applyTerrainVisualStyle(_ terrain: TerrainPreset) {
        let background: NSColor
        switch terrain {
        case .gridDemo:
            background = NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)
            gridNode.isHidden = false
            axesNode.isHidden = false
        case .field:
            background = NSColor(calibratedRed: 0.22, green: 0.27, blue: 0.20, alpha: 1.0)
            gridNode.isHidden = true
            axesNode.isHidden = true
        case .forest:
            background = NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.12, alpha: 1.0)
            gridNode.isHidden = true
            axesNode.isHidden = true
        case .city:
            background = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
            gridNode.isHidden = true
            axesNode.isHidden = true
        }

        scene.background.contents = background

        if let geometry = groundNode.geometry {
            geometry.materials = [EnvironmentMaterialRegistry.groundMaterial(for: terrain)]
        }
    }

    private func applyComponentOverlays(damage: DamageState, thermal: ThermalState, mode: DiagnosticOverlayMode) {
        let fpvHidden: Set<DamageComponent> = [
            .propellerFL, .propellerFR, .propellerRL, .propellerRR,
            .armFL, .armFR
        ]

        for component in DamageComponent.allCases {
            let nodes = componentNodes[component] ?? []
            let hidden = damage.hiddenComponents.contains(component) || (fpvObstructionHidingActive && fpvHidden.contains(component))
            let selected = damage.selectedComponent == component

            for node in nodes {
                node.isHidden = hidden

                switch mode {
                case .normal:
                    if selected {
                        applyEmission(on: node, color: NSColor.systemCyan.withAlphaComponent(0.78))
                    } else {
                        clearEmission(on: node)
                    }
                case .thermal:
                    let color = temperatureColor(thermal.temperature(for: component), selected: selected)
                    applyEmission(on: node, color: color)
                case .damage:
                    let warning = damage.warningState(for: component, temperature: thermal.temperature(for: component))
                    let color = warningColor(warning, selected: selected)
                    applyEmission(on: node, color: color)
                }
            }
        }
    }

    private func applyEmission(on node: SCNNode, color: NSColor) {
        if let geometry = node.geometry {
            geometry.materials.forEach { $0.emission.contents = color }
        }
        for child in node.childNodes {
            applyEmission(on: child, color: color)
        }
    }

    private func clearEmission(on node: SCNNode) {
        applyEmission(on: node, color: .clear)
    }

    private func warningColor(_ state: ComponentWarningState, selected: Bool) -> NSColor {
        let base: NSColor
        switch state {
        case .nominal:
            base = NSColor.systemGreen.withAlphaComponent(0.32)
        case .warning:
            base = NSColor.systemYellow.withAlphaComponent(0.52)
        case .critical:
            base = NSColor.systemRed.withAlphaComponent(0.72)
        }

        if selected {
            return base.blended(withFraction: 0.42, of: .systemCyan) ?? base
        }
        return base
    }

    private func temperatureColor(_ temperature: Float, selected: Bool) -> NSColor {
        let t = ((temperature - 28.0) / 65.0).clamped(to: 0.0...1.0)
        let red = CGFloat(t)
        let blue = CGFloat(1.0 - t)
        let green = CGFloat(max(0.0, 1.0 - abs(t - 0.52) * 2.0))
        let alpha: CGFloat = selected ? 0.84 : 0.66
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func updateWeatherParticles(_ weather: WeatherModel) {
        let intensity = weather.normalizedIntensity

        if weather.preset == .rain || weather.preset == .thunderstorm {
            if rainSystem == nil {
                rainSystem = makeRainSystem()
                weatherNode.addParticleSystem(rainSystem!)
            }
            let rate = CGFloat(260 + 2100 * intensity)
            rainSystem?.birthRate = rate
            rainSystem?.particleVelocity = CGFloat(18 + 24 * intensity)
            rainSystem?.acceleration = SCNVector3(
                weather.windVector.x * 1.6,
                -34.0,
                weather.windVector.z * 1.6
            )
        } else if let rainSystem {
            weatherNode.removeParticleSystem(rainSystem)
            self.rainSystem = nil
        }

        if weather.preset == .snow {
            if snowSystem == nil {
                snowSystem = makeSnowSystem()
                weatherNode.addParticleSystem(snowSystem!)
            }
            let rate = CGFloat(120 + 780 * intensity)
            snowSystem?.birthRate = rate
            snowSystem?.particleVelocity = CGFloat(4.0 + 4.5 * intensity)
            snowSystem?.acceleration = SCNVector3(
                weather.windVector.x * 0.9,
                -6.0,
                weather.windVector.z * 0.9
            )
        } else if let snowSystem {
            weatherNode.removeParticleSystem(snowSystem)
            self.snowSystem = nil
        }
    }

    private func updateWeatherAnimation(deltaTime: Float, weather: WeatherModel) {
        let baseSun = CGFloat(1200 * (0.65 + weather.effectiveFactors.visibilityFactor * 0.5))
        var intensity = baseSun

        if weather.preset == .thunderstorm {
            thunderPulse -= deltaTime
            if thunderPulse <= 0.0 {
                thunderPulse = Float.random(in: 0.6...2.2)
                if Float.random(in: 0...1) < weather.normalizedIntensity * 0.5 + 0.2 {
                    intensity += CGFloat(Float.random(in: 900...2600) * weather.normalizedIntensity)
                }
            }
        }

        sunLightNode.light?.intensity = intensity
    }

    private func makeRainSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedWhite: 0.85, alpha: 0.55)
        system.particleSize = 0.018
        system.birthRate = 0
        system.particleLifeSpan = 2.2
        system.particleLifeSpanVariation = 0.6
        system.emitterShape = SCNBox(width: 260, height: 1, length: 260, chamferRadius: 0)
        system.spreadingAngle = 2
        system.particleVelocity = 22
        system.particleVelocityVariation = 4
        system.acceleration = SCNVector3(0, -32, 0)
        system.isAffectedByGravity = false
        system.loops = true
        weatherNode.position = SCNVector3(0, 45, 0)
        return system
    }

    private func makeSnowSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedWhite: 0.95, alpha: 0.9)
        system.particleSize = 0.042
        system.birthRate = 0
        system.particleLifeSpan = 8.0
        system.particleLifeSpanVariation = 2.0
        system.emitterShape = SCNBox(width: 260, height: 1, length: 260, chamferRadius: 0)
        system.spreadingAngle = 8
        system.particleVelocity = 5.0
        system.particleVelocityVariation = 1.6
        system.acceleration = SCNVector3(0, -6.0, 0)
        system.isAffectedByGravity = false
        system.loops = true
        weatherNode.position = SCNVector3(0, 45, 0)
        return system
    }

    private func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
        let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1, 0, 0))
        let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0, 0, 1))
        return yaw * pitch * roll
    }
}

private extension Float {
    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
```

## DroneUAVDemo/Scene/SceneFactory.swift
```swift
import AppKit
import SceneKit

struct SceneSetup {
    let scene: SCNScene
    let cameraNode: SCNNode
    let sunLightNode: SCNNode
    let groundNode: SCNNode
    let gridNode: SCNNode
    let axesNode: SCNNode
}

enum SceneFactory {
    static func makeScene() -> SceneSetup {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.14, alpha: 1.0)

        let cameraNode = makeCameraNode()
        let sunLightNode = makeDirectionalLightNode()
        let groundNode = makeGroundNode()
        let gridNode = makeGridNode()
        let axesNode = makeAxesNode()

        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(makeAmbientLightNode())
        scene.rootNode.addChildNode(sunLightNode)
        scene.rootNode.addChildNode(makeFillLightNode())
        scene.rootNode.addChildNode(groundNode)
        scene.rootNode.addChildNode(gridNode)
        scene.rootNode.addChildNode(axesNode)

        return SceneSetup(
            scene: scene,
            cameraNode: cameraNode,
            sunLightNode: sunLightNode,
            groundNode: groundNode,
            gridNode: gridNode,
            axesNode: axesNode
        )
    }

    private static func makeCameraNode() -> SCNNode {
        let node = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 52
        camera.zNear = 0.01
        camera.zFar = 800
        node.camera = camera
        node.position = SCNVector3(0, 12.0, 24.0)
        node.eulerAngles = SCNVector3(-0.38, 0, 0)
        return node
    }

    private static func makeAmbientLightNode() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .ambient
        light.intensity = 380
        light.color = NSColor(calibratedWhite: 0.82, alpha: 1.0)
        node.light = light
        return node
    }

    private static func makeDirectionalLightNode() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .directional
        light.intensity = 1300
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowRadius = 2.4
        light.shadowColor = NSColor.black.withAlphaComponent(0.35)
        node.light = light
        node.position = SCNVector3(18, 35, 14)
        node.eulerAngles = SCNVector3(-0.92, 0.85, 0)
        return node
    }

    private static func makeFillLightNode() -> SCNNode {
        let node = SCNNode()
        let light = SCNLight()
        light.type = .omni
        light.intensity = 260
        light.color = NSColor(calibratedRed: 0.68, green: 0.77, blue: 1.0, alpha: 1.0)
        node.light = light
        node.position = SCNVector3(-20, 16, -12)
        return node
    }

    private static func makeGroundNode() -> SCNNode {
        let plane = SCNPlane(width: 440, height: 440)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.16, alpha: 1.0)
        material.roughness.contents = 0.92
        material.metalness.contents = 0.10
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, -0.003, 0)
        node.name = "groundPlane"
        return node
    }

    private static func makeGridNode() -> SCNNode {
        let parent = SCNNode()
        parent.name = "gridGuide"

        let half: Float = 96
        let spacing: Float = 6

        for index in stride(from: -half, through: half, by: spacing) {
            let majorLine = abs(index.truncatingRemainder(dividingBy: 24)) < 0.001
            let thickness: CGFloat = majorLine ? 0.09 : 0.04
            let alpha: CGFloat = majorLine ? 0.22 : 0.10

            let xLine = SCNNode(geometry: SCNBox(width: CGFloat(half * 2), height: 0.0004, length: thickness, chamferRadius: 0.0))
            xLine.position = SCNVector3(0, 0, index)
            xLine.geometry?.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(alpha)

            let zLine = SCNNode(geometry: SCNBox(width: thickness, height: 0.0004, length: CGFloat(half * 2), chamferRadius: 0.0))
            zLine.position = SCNVector3(index, 0, 0)
            zLine.geometry?.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(alpha)

            parent.addChildNode(xLine)
            parent.addChildNode(zLine)
        }

        return parent
    }

    private static func makeAxesNode() -> SCNNode {
        let parent = SCNNode()
        parent.name = "axesGuide"
        let length: CGFloat = 8.0
        let radius: CGFloat = 0.03

        let xAxis = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
        xAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.88)
        xAxis.position = SCNVector3(Float(length / 2), 0.05, 0)
        xAxis.eulerAngles = SCNVector3(0, 0, Float.pi / 2)

        let yAxis = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
        yAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.88)
        yAxis.position = SCNVector3(0, Float(length / 2), 0)

        let zAxis = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
        zAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.88)
        zAxis.position = SCNVector3(0, 0.05, Float(length / 2))
        zAxis.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)

        parent.addChildNode(xAxis)
        parent.addChildNode(yAxis)
        parent.addChildNode(zAxis)

        return parent
    }
}
```

## DroneUAVDemo/Presentation/ViewModels/DroneSimulationViewModel.swift
```swift
import Foundation
import QuartzCore
import SceneKit
import SwiftUI
import simd

struct TelemetryExportAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

struct KeyBindingSection: Identifiable {
    let category: KeyBindingCategory
    let bindings: [KeyBindingDescriptor]

    var id: String { category.id }
}

@MainActor
final class DroneSimulationViewModel: ObservableObject {
    @Published private(set) var controlValues: DroneControlValues
    @Published private(set) var telemetry: TelemetrySnapshot
    @Published private(set) var mode: DroneFlightMode
    @Published private(set) var isSimulationRunning: Bool

    @Published private(set) var availableDroneProfiles: [DroneModelProfile]
    @Published private(set) var selectedDroneProfile: DroneModelProfile
    @Published private(set) var abstractParameters: AbstractDroneParameters

    @Published private(set) var weather: WeatherModel
    @Published private(set) var terrain: TerrainConfiguration
    @Published private(set) var cameraConfiguration: CameraConfiguration

    @Published private(set) var batteryState: BatteryState
    @Published private(set) var collisionAnalysis: CollisionAnalysisSnapshot
    @Published private(set) var damageState: DamageState
    @Published private(set) var thermalState: ThermalState
    @Published private(set) var fleetStatus: FleetStatus

    @Published private(set) var warnings: [String]
    @Published var collisionDebugEnabled: Bool
    @Published var showBatteryDepletedDialog: Bool
    @Published var diagnosticMode: DiagnosticOverlayMode
    @Published var isControlPanelCollapsed: Bool
    @Published var isCompactTelemetryHUDEnabled: Bool
    @Published var telemetryExportAlert: TelemetryExportAlert?
    @Published private(set) var keyBindingSections: [KeyBindingSection]
    @Published private(set) var keyBindingConflicts: [String]

    var scene: SCNScene {
        sceneController.scene
    }

    var activeCameraNode: SCNNode {
        sceneController.pointOfView(for: cameraConfiguration.mode)
    }

    private let physicsEngine: DronePhysicsEngine
    private let sceneController: DroneSceneController
    private let keyboardInputService: KeyboardInputProviding
    private let collisionService: CollisionAnalysisService
    private let batteryThermalService: BatteryThermalSimulationService
    private let telemetryExporter: TelemetryExporting
    private let fleetManager: DroneFleetManager
    private let autoPathPlanner: AutoPathPlannerService

    private var state: DroneState
    private var simulationTimer: Timer?
    private var lastTimestamp: CFTimeInterval?
    private var simulationTime: Float = 0.0
    private var telemetrySamplingAccumulator: Float = 0.0
    private var collisionCooldown: Float = 0.0
    private var homePosition = SIMD3<Float>(0.0, 0.0, 0.0)
    private var wingmen: [DroneEntity] = []
    private let fleetLeaderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var collisionDebugAccumulator: Float = 0.0

    init(
        physicsEngine: DronePhysicsEngine = SimpleDronePhysicsEngine(),
        keyboardInputService: KeyboardInputProviding = KeyboardInputService(),
        collisionService: CollisionAnalysisService = CollisionAnalysisService(),
        batteryThermalService: BatteryThermalSimulationService = BatteryThermalSimulationService(),
        telemetryExporter: TelemetryExporting = TelemetryExportService(),
        fleetManager: DroneFleetManager = DroneFleetManager(),
        autoPathPlanner: AutoPathPlannerService = AutoPathPlannerService()
    ) {
        self.physicsEngine = physicsEngine
        self.keyboardInputService = keyboardInputService
        self.collisionService = collisionService
        self.batteryThermalService = batteryThermalService
        self.telemetryExporter = telemetryExporter
        self.fleetManager = fleetManager
        self.autoPathPlanner = autoPathPlanner

        let abstract = AbstractDroneParameters.default
        self.abstractParameters = abstract
        let models = DJIDroneModelRepository(abstractParameters: abstract).allProfiles

        let selectedProfile = models[1]
        self.selectedDroneProfile = selectedProfile
        self.availableDroneProfiles = models

        self.sceneController = DroneSceneController(initialProfile: selectedProfile)

        let initialState = DroneState.initial
        self.state = initialState
        self.controlValues = DroneControlValues(
            x: Double(initialState.position.x),
            y: Double(initialState.position.y),
            z: Double(initialState.position.z),
            roll: 0.0,
            pitch: 0.0,
            yaw: 0.0,
            throttle: Double(initialState.throttle)
        )

        self.mode = .manual
        self.isSimulationRunning = true

        self.weather = .normal
        self.terrain = .default
        self.cameraConfiguration = CameraConfiguration(
            mode: .follow,
            fov: selectedProfile.cameraPreset.fpvFov,
            sensitivity: 1.0,
            smoothing: 0.72,
            free: FreeCameraState(
                moveSpeed: 4.2,
                zoomSensitivity: 1.0,
                distance: 14.0,
                minDistance: 2.0,
                maxDistance: 80.0
            ),
            follow: FollowCameraState(
                distance: selectedProfile.cameraPreset.followDistance,
                height: selectedProfile.cameraPreset.followHeight,
                lateralOffset: 0.0,
                minDistance: 2.0,
                maxDistance: 26.0
            ),
            orbit: OrbitCameraState(
                distance: selectedProfile.cameraPreset.followDistance,
                height: selectedProfile.cameraPreset.followHeight,
                angularSpeed: 0.42,
                minDistance: 2.0,
                maxDistance: 32.0
            ),
            fpv: FPVCameraState(
                stabilization: 0.45,
                shake: 0.07,
                yawLimitDeg: 24.0,
                pitchLimitDeg: 18.0,
                nearClip: 0.02,
                mountOffset: SIMD3<Float>(0.0, 0.012, 0.040),
                hideObstructingParts: true
            )
        )

        self.batteryState = .full
        self.collisionAnalysis = .safe
        self.damageState = .pristine
        self.thermalState = .nominal
        self.fleetStatus = .disabled

        self.warnings = []
        self.collisionDebugEnabled = false
        self.showBatteryDepletedDialog = false
        self.diagnosticMode = .normal
        self.isControlPanelCollapsed = false
        self.isCompactTelemetryHUDEnabled = true
        self.telemetryExportAlert = nil
        self.keyBindingSections = []
        self.keyBindingConflicts = []
        self.telemetry = .zero

        sceneController.regenerateEnvironment(terrain)
        sceneController.applyWeatherVisual(weather)
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )

        telemetry = buildTelemetrySnapshot()

        refreshKeyBindingDiagnostics()
        keyboardInputService.setInputProcessingMode(.flight)
        keyboardInputService.start()
        startSimulationLoop()
    }

    deinit {
        simulationTimer?.invalidate()
        keyboardInputService.stop()
        telemetryExporter.finalizeSession()
    }

    // MARK: - Controls

    func setX(_ value: Double) { updateControlValues({ $0.x = value }, markManual: true) }
    func setY(_ value: Double) { updateControlValues({ $0.y = value }, markManual: true) }
    func setZ(_ value: Double) { updateControlValues({ $0.z = value }, markManual: true) }
    func setRoll(_ value: Double) { updateControlValues({ $0.roll = value }, markManual: true) }
    func setPitch(_ value: Double) { updateControlValues({ $0.pitch = value }, markManual: true) }
    func setYaw(_ value: Double) { updateControlValues({ $0.yaw = value }, markManual: true) }
    func setThrottle(_ value: Double) { updateControlValues({ $0.throttle = value }, markManual: true) }

    func reset() {
        mode = .manual
        state = DroneState.initial
        controlValues = DroneControlValues()
        batteryState = .full
        damageState = .pristine
        thermalState = .nominal
        diagnosticMode = .normal
        collisionAnalysis = .safe
        wingmen.removeAll()
        fleetStatus.interDroneRisk = 0.0
        fleetStatus.nearestInterDroneDistance = .infinity
        showBatteryDepletedDialog = false
        homePosition = SIMD3<Float>(0.0, 0.0, 0.0)
        simulationTime = 0.0
        autoPathPlanner.invalidate()

        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: 0.0
        )
        sceneController.updateFleetWingmen([], profile: selectedDroneProfile, throttle: 0.0, deltaTime: 0.0)

        warnings = []
        telemetry = buildTelemetrySnapshot()
        telemetryExporter.append(snapshot: telemetry)
    }

    func takeoff() {
        mode = .takeoff
        updateControlValues({ values in
            values.y = max(values.y, 3.0)
            values.roll = 0.0
            values.pitch = 0.0
            values.throttle = max(values.throttle, 0.68)
        }, markManual: false)
    }

    func land() {
        mode = .landing
        updateControlValues({ values in
            values.y = 0.0
            values.roll = 0.0
            values.pitch = 0.0
            values.throttle = min(values.throttle, 0.35)
        }, markManual: false)
    }

    func hover() {
        mode = .hover
        lockControlsToCurrentState(overrideThrottle: 0.54)
    }

    func activateAutoPath() {
        mode = .autoPath
        autoPathPlanner.invalidate()
    }

    func activateReturnHome() {
        mode = .returnHome
    }

    func activateEmergencyStop() {
        mode = .emergencyStop
        lockControlsToCurrentState(overrideThrottle: 0.0)
    }

    func toggleSimulation() {
        isSimulationRunning.toggle()
        lastTimestamp = nil
    }

    func toggleControlPanel() {
        isControlPanelCollapsed.toggle()
    }

    // MARK: - Drone models

    func selectDroneModel(id: String) {
        guard let profile = availableDroneProfiles.first(where: { $0.id == id }) else {
            return
        }

        selectedDroneProfile = profile
        sceneController.setDroneProfile(profile)

        cameraConfiguration.fov = profile.cameraPreset.fpvFov
        cameraConfiguration.orbitDistance = profile.cameraPreset.followDistance
        cameraConfiguration.followOffset = SIMD3<Float>(0.0, profile.cameraPreset.followHeight, profile.cameraPreset.followDistance)

        batteryState = .full
        reset()
    }

    func applyAbstractParameters(_ parameters: AbstractDroneParameters) {
        abstractParameters = parameters
        let abstractProfile = DJIDroneModelRepository.abstractProfile(from: parameters)

        if let index = availableDroneProfiles.firstIndex(where: { $0.id == abstractProfile.id }) {
            availableDroneProfiles[index] = abstractProfile
        } else {
            availableDroneProfiles.append(abstractProfile)
        }

        if selectedDroneProfile.id == abstractProfile.id {
            selectDroneModel(id: abstractProfile.id)
        }
    }

    // MARK: - Camera

    func setCameraMode(_ mode: CameraMode) { cameraConfiguration.mode = mode }
    func cycleCameraMode() { cameraConfiguration.mode = cameraConfiguration.mode.next() }
    func setCameraFov(_ value: Double) { cameraConfiguration.fov = Float(value) }
    func setCameraSensitivity(_ value: Double) { cameraConfiguration.sensitivity = Float(value) }
    func setCameraSmoothing(_ value: Double) { cameraConfiguration.smoothing = Float(value) }
    func setOrbitDistance(_ value: Double) { cameraConfiguration.orbit.distance = Float(value).clamped(to: cameraConfiguration.orbit.minDistance...cameraConfiguration.orbit.maxDistance) }
    func setFollowOffsetX(_ value: Double) { cameraConfiguration.follow.lateralOffset = Float(value) }
    func setFollowOffsetY(_ value: Double) { cameraConfiguration.follow.height = Float(value) }
    func setFollowOffsetZ(_ value: Double) { cameraConfiguration.follow.distance = Float(value).clamped(to: cameraConfiguration.follow.minDistance...cameraConfiguration.follow.maxDistance) }
    func setFPVStabilization(_ value: Double) { cameraConfiguration.fpv.stabilization = Float(value).clamped(to: 0.0...1.0) }
    func setFPVShake(_ value: Double) { cameraConfiguration.fpv.shake = Float(value).clamped(to: 0.0...0.4) }
    func setFPVYawLimit(_ value: Double) { cameraConfiguration.fpv.yawLimitDeg = Float(value).clamped(to: 2.0...60.0) }
    func setFPVPitchLimit(_ value: Double) { cameraConfiguration.fpv.pitchLimitDeg = Float(value).clamped(to: 2.0...45.0) }
    func setFPVNearClip(_ value: Double) { cameraConfiguration.fpv.nearClip = Float(value).clamped(to: 0.005...0.25) }
    func setFPVMountOffsetX(_ value: Double) { cameraConfiguration.fpv.mountOffset.x = Float(value) }
    func setFPVMountOffsetY(_ value: Double) { cameraConfiguration.fpv.mountOffset.y = Float(value) }
    func setFPVMountOffsetZ(_ value: Double) { cameraConfiguration.fpv.mountOffset.z = Float(value) }
    func setFPVHideObstructions(_ value: Bool) { cameraConfiguration.fpv.hideObstructingParts = value }
    func setFreeCameraMoveSpeed(_ value: Double) { cameraConfiguration.free.moveSpeed = Float(value).clamped(to: 0.5...16.0) }
    func setCameraZoomSensitivity(_ value: Double) { cameraConfiguration.free.zoomSensitivity = Float(value).clamped(to: 0.2...3.0) }

    func setActiveCameraDistance(_ value: Double) {
        cameraConfiguration.setCameraDistance(Float(value))
    }

    func toggleCompactTelemetryHUD() {
        isCompactTelemetryHUDEnabled.toggle()
    }

    var supportsDistanceControl: Bool {
        cameraConfiguration.mode != .fpv
    }

    var activeCameraDistance: Double {
        Double(cameraConfiguration.cameraDistance)
    }

    var activeCameraDistanceRange: ClosedRange<Double> {
        switch cameraConfiguration.mode {
        case .free:
            return Double(cameraConfiguration.free.minDistance)...Double(cameraConfiguration.free.maxDistance)
        case .follow:
            return Double(cameraConfiguration.follow.minDistance)...Double(cameraConfiguration.follow.maxDistance)
        case .orbit:
            return Double(cameraConfiguration.orbit.minDistance)...Double(cameraConfiguration.orbit.maxDistance)
        case .fpv:
            return 0.0...0.0
        }
    }

    // MARK: - Weather and terrain

    func setWeatherPreset(_ preset: WeatherPreset) {
        weather.preset = preset
        if preset == .normal {
            weather.intensity = 0.0
            weather.windSpeedMps = 0.0
            weather.gusts = 0.0
        }
    }

    func setWeatherIntensity(_ value: Double) { weather.intensity = Float(value) }
    func setWindDirection(_ value: Double) { weather.windDirectionDeg = Float(value) }
    func setWindSpeed(_ value: Double) { weather.windSpeedMps = Float(value) }
    func setWindGusts(_ value: Double) { weather.gusts = Float(value) }

    func setTerrainPreset(_ preset: TerrainPreset) {
        terrain.preset = preset
        terrain.density = preset.defaultDensity
        terrain.safeSpawnRadius = 8.0
        regenerateEnvironment()
    }

    func setTerrainDensity(_ value: Double) {
        terrain.density = Float(value)
        regenerateEnvironment()
    }

    func setTerrainSeed(_ value: UInt64) {
        terrain.seed = value
        regenerateEnvironment()
    }

    // MARK: - Diagnostics

    func setDiagnosticMode(_ mode: DiagnosticOverlayMode) {
        diagnosticMode = mode
    }

    func toggleThermalOverlay() {
        diagnosticMode = diagnosticMode == .thermal ? .normal : .thermal
    }

    func toggleDamageOverlay() {
        diagnosticMode = diagnosticMode == .damage ? .normal : .damage
    }

    func setComponentHidden(_ component: DamageComponent, hidden: Bool) {
        damageState = damageState.withHidden(component, hidden: hidden)
    }

    func selectComponent(_ component: DamageComponent?) {
        damageState = damageState.withSelected(component)
    }

    func resetDamageState() {
        damageState = .pristine
        thermalState = .nominal
        diagnosticMode = .normal
    }

    // MARK: - Fleet

    func toggleFleetEnabled() {
        fleetStatus.enabled.toggle()
        if !fleetStatus.enabled {
            fleetStatus.mode = .off
            fleetStatus.interDroneRisk = 0.0
            fleetStatus.nearestInterDroneDistance = .infinity
            wingmen.removeAll()
            sceneController.updateFleetWingmen([], profile: selectedDroneProfile, throttle: state.throttle, deltaTime: 0.0)
        } else if fleetStatus.mode == .off {
            fleetStatus.mode = .line
        }
    }

    func setFormationMode(_ mode: FormationMode) { fleetStatus.mode = mode }
    func setSeparationDistance(_ value: Double) { fleetStatus.separationDistance = Float(value) }

    func setFleetWingmanCount(_ value: Int) {
        fleetStatus.wingmanCount = max(1, min(value, 5))
        if wingmen.count > fleetStatus.wingmanCount {
            wingmen = Array(wingmen.prefix(fleetStatus.wingmanCount))
        }
    }

    // MARK: - Battery and telemetry

    func chargeDroneAndContinue() {
        batteryState.chargePercent = 100
        showBatteryDepletedDialog = false
        mode = .hover
        lockControlsToCurrentState(overrideThrottle: 0.54)
    }

    func simulateAgainFromStart() {
        showBatteryDepletedDialog = false
        reset()
    }

    func exportTelemetry() {
        let metadata = TelemetrySessionMetadata(
            modelID: selectedDroneProfile.id,
            modelName: selectedDroneProfile.displayName,
            manufacturer: selectedDroneProfile.manufacturer,
            isAbstractModel: selectedDroneProfile.isAbstract,
            abstractParametersSummary: selectedDroneProfile.isAbstract ? abstractParametersSummary : "n/a",
            weatherPreset: weather.preset.title,
            weatherIntensity: weather.intensity,
            terrainPreset: terrain.preset.title,
            terrainDensity: terrain.density,
            cameraMode: cameraConfiguration.mode.title
        )

        switch telemetryExporter.exportNow(metadata: metadata) {
        case let .success(url):
            telemetryExportAlert = TelemetryExportAlert(
                titleKey: "telemetry.export.success",
                message: url.path
            )
        case let .failure(error):
            telemetryExportAlert = TelemetryExportAlert(
                titleKey: "telemetry.export.failure",
                message: error.localizedDescription
            )
        }
    }

    private func refreshKeyBindingDiagnostics() {
        let profile = keyboardInputService.currentBindingProfile()
        keyBindingSections = KeyBindingCategory.allCases.compactMap { category in
            let bindings = profile.groupedBindings()[category] ?? []
            if bindings.isEmpty {
                return nil
            }
            return KeyBindingSection(category: category, bindings: bindings)
        }
        keyBindingConflicts = keyboardInputService.currentBindingConflicts()
    }

    private func regenerateEnvironment() {
        autoPathPlanner.invalidate()
        sceneController.regenerateEnvironment(terrain)
    }

    private func startSimulationLoop() {
        simulationTimer?.invalidate()
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }

        if let simulationTimer {
            RunLoop.main.add(simulationTimer, forMode: .common)
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard let lastTimestamp else {
            self.lastTimestamp = now
            return
        }

        let dt = Float(max(1.0 / 240.0, min(now - lastTimestamp, 1.0 / 20.0)))
        self.lastTimestamp = now
        simulationTime += dt

        guard isSimulationRunning else {
            return
        }

        collisionCooldown = max(0.0, collisionCooldown - dt)

        applyKeyboardControls(deltaTime: dt)
        processKeyboardActions()
        updateAutopilotTargets(deltaTime: dt)

        let fleetObstacles = updateFleetStatus(deltaTime: dt)

        collisionAnalysis = collisionService.analyze(
            input: CollisionAnalysisInput(
                dronePosition: state.position,
                droneVelocity: state.velocity,
                droneRadius: selectedDroneProfile.collisionRadius,
                obstacles: sceneController.environmentObstacles + fleetObstacles,
                weather: weather
            )
        )

        handleAutoCollisionInterventions()

        let control = buildControlInput(from: controlValues)
        let context = DroneSimulationContext(
            profile: selectedDroneProfile,
            weather: weather,
            damageState: damageState,
            batteryState: batteryState,
            collisionRisk: collisionAnalysis.riskScore,
            windVector: weather.windVector
        )

        state = physicsEngine.step(
            state: state,
            control: control,
            context: context,
            deltaTime: dt
        )

        if collisionAnalysis.nearestObstacleDistance <= 0.0, collisionCooldown <= 0.0 {
            applyCollisionDamage()
            collisionCooldown = 0.7
        }

        handleModeTransitions()

        let maneuverAggressiveness = (abs(Float(controlValues.roll)) + abs(Float(controlValues.pitch))) / 120.0
        batteryState = batteryThermalService.updateBattery(
            current: batteryState,
            input: BatteryComputationInput(
                droneProfile: selectedDroneProfile,
                weather: weather,
                damageState: damageState,
                speedMps: simd_length(state.velocity),
                verticalSpeedMps: abs(state.velocity.y),
                throttle: state.throttle,
                maneuverAggressiveness: maneuverAggressiveness
            ),
            deltaTime: dt
        )

        thermalState = batteryThermalService.updateThermal(
            current: thermalState,
            throttle: state.throttle,
            weather: weather,
            damageState: damageState,
            collisionRisk: collisionAnalysis.riskScore,
            maneuverAggressiveness: maneuverAggressiveness,
            deltaTime: dt
        )

        if batteryState.isDepleted {
            mode = .emergencyStop
            updateControlValues({ values in
                values.throttle = 0.0
            }, markManual: false)
            if !showBatteryDepletedDialog {
                showBatteryDepletedDialog = true
            }
        }

        sceneController.applyWeatherVisual(weather)
        sceneController.update(
            with: state,
            camera: cameraConfiguration,
            damage: damageState,
            thermal: thermalState,
            diagnosticMode: diagnosticMode,
            deltaTime: dt
        )
        sceneController.updateFleetWingmen(
            wingmen,
            profile: selectedDroneProfile,
            throttle: state.throttle,
            deltaTime: dt
        )

        collisionDebugAccumulator += dt
        if collisionDebugAccumulator > 0.12 || !collisionDebugEnabled {
            sceneController.updateCollisionDebug(risk: collisionAnalysis, enabled: collisionDebugEnabled)
            collisionDebugAccumulator = 0.0
        }

        warnings = buildWarnings()
        telemetry = buildTelemetrySnapshot()

        telemetrySamplingAccumulator += dt
        if telemetrySamplingAccumulator >= 0.2 {
            telemetryExporter.append(snapshot: telemetry)
            telemetrySamplingAccumulator = 0.0
        }
    }

    private func applyCollisionDamage() {
        let impact = simd_length(state.velocity)
        damageState = damageState.applyingCollisionDamage(impactEnergy: impact)

        state.velocity *= SIMD3<Float>(-0.18, -0.05, -0.18)
        if impact > 4.5 {
            mode = .emergencyStop
            updateControlValues({ values in
                values.throttle = min(values.throttle, 0.25)
            }, markManual: false)
        }
    }

    private func handleAutoCollisionInterventions() {
        guard mode.isAutoControlled else {
            return
        }

        switch collisionAnalysis.emergencyAction {
        case .none, .slowDown:
            return
        case .hover:
            mode = .hover
            lockControlsToCurrentState(overrideThrottle: Double(max(0.45, state.throttle)))
        case .avoid:
            guard let obstacleID = collisionAnalysis.nearestObstacleID,
                  let obstacle = sceneController.obstacleCenter(for: obstacleID) else {
                return
            }

            let away = simd_normalize(state.position - obstacle)
            updateControlValues({ values in
                values.x += Double(away.x * 1.4)
                values.z += Double(away.z * 1.4)
                values.y = max(values.y, Double(state.position.y + 0.45))
                values.throttle = max(values.throttle, 0.56)
            }, markManual: false)
        case .emergencyStop:
            activateEmergencyStop()
        }
    }

    private func applyKeyboardControls(deltaTime: Float) {
        let axis = keyboardInputService.currentAxisInput()
        guard abs(axis.forward) > 0.001 || abs(axis.strafe) > 0.001 || abs(axis.vertical) > 0.001 else {
            return
        }

        mode = .manual

        let yaw = Float(controlValues.yaw).degreesToRadians
        let forward = SIMD3<Float>(sin(yaw), 0.0, cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0.0, -sin(yaw))

        let speed: Float = axis.speedBoost ? 9.0 : 4.8
        let planarDirection = forward * axis.forward + right * axis.strafe
        let movement = planarDirection * speed * deltaTime
        let climb = axis.vertical * (axis.speedBoost ? 4.2 : 2.2) * deltaTime

        updateControlValues({ values in
            values.x += Double(movement.x)
            values.z += Double(movement.z)
            values.y = (values.y + Double(climb)).clamped(to: 0.0...38.0)
            values.throttle = (values.throttle + Double(axis.vertical) * 0.22 * Double(deltaTime)).clamped(to: 0.0...1.0)

            values.pitch = Double((axis.forward * 11.5).clamped(to: -30.0...30.0))
            values.roll = Double((-axis.strafe * 11.5).clamped(to: -30.0...30.0))
        }, markManual: false)
    }

    private func processKeyboardActions() {
        let actions = keyboardInputService.consumeActions()
        for action in actions {
            switch action {
            case .requestHover:
                hover()
            case .requestReset:
                reset()
            case .toggleFPV:
                cameraConfiguration.mode = cameraConfiguration.mode == .fpv ? .follow : .fpv
            case .toggleThermalOverlay:
                toggleThermalOverlay()
            case .toggleDamageOverlay:
                toggleDamageOverlay()
            case .cycleCameraMode:
                cycleCameraMode()
            case .toggleControlPanel:
                toggleControlPanel()
            case .toggleTelemetryHUD:
                toggleCompactTelemetryHUD()
            case .zoomInCamera:
                adjustCameraZoom(inward: true)
            case .zoomOutCamera:
                adjustCameraZoom(inward: false)
            }
        }
    }

    private func adjustCameraZoom(inward: Bool) {
        let sign: Float = inward ? -1.0 : 1.0
        let zoomStep = 0.9 * cameraConfiguration.free.zoomSensitivity

        switch cameraConfiguration.mode {
        case .free:
            cameraConfiguration.free.distance = (cameraConfiguration.free.distance + sign * zoomStep)
                .clamped(to: cameraConfiguration.free.minDistance...cameraConfiguration.free.maxDistance)
            sceneController.dollyFreeCamera(by: sign * zoomStep)
        case .follow, .orbit:
            cameraConfiguration.setCameraDistance(cameraConfiguration.cameraDistance + sign * zoomStep)
        case .fpv:
            cameraConfiguration.fov = (cameraConfiguration.fov + sign * 1.2).clamped(to: 30.0...110.0)
        }
    }

    private func updateAutopilotTargets(deltaTime: Float) {
        switch mode {
        case .autoPath:
            autoPathPlanner.prepareIfNeeded(
                center: homePosition,
                terrain: terrain,
                obstacles: sceneController.environmentObstacles
            )

            let target = autoPathPlanner.nextTarget(currentPosition: state.position)
            let headingVector = SIMD2<Float>(target.x - state.position.x, target.z - state.position.z)
            let yaw = atan2(-headingVector.x, headingVector.y)

            updateControlValues({ values in
                values.x = Double(target.x)
                values.y = Double(max(target.y, state.position.y - 0.3))
                values.z = Double(target.z)
                values.roll = Double((-headingVector.x * 1.2).clamped(to: -10.0...10.0))
                values.pitch = Double((headingVector.y * 1.2).clamped(to: -10.0...10.0))
                values.yaw = Double(yaw.radiansToDegrees)
                values.throttle = max(values.throttle, 0.56)
            }, markManual: false)

        case .returnHome:
            updateControlValues({ values in
                values.x = Double(homePosition.x)
                values.z = Double(homePosition.z)
                values.y = max(1.8, Double(homePosition.y + 2.0))
                values.yaw = 0.0
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(values.throttle, 0.54)
            }, markManual: false)

        case .hover:
            updateControlValues({ values in
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(0.50, min(values.throttle, 0.62))
            }, markManual: false)

        case .emergencyStop:
            updateControlValues({ values in
                values.x = Double(state.position.x)
                values.y = max(0.0, Double(state.position.y - 0.02))
                values.z = Double(state.position.z)
                values.roll = 0.0
                values.pitch = 0.0
                values.throttle = max(0.0, values.throttle - 0.02)
            }, markManual: false)

        case .manual, .takeoff, .landing:
            break
        }

        _ = deltaTime
    }

    private func handleModeTransitions() {
        if mode == .takeoff {
            let targetAltitude = Float(controlValues.y)
            if state.position.y >= targetAltitude - 0.08 && abs(state.velocity.y) < 0.45 {
                mode = .hover
                lockControlsToCurrentState(overrideThrottle: 0.54)
            }
        }

        if mode == .landing,
           state.position.y <= 0.05,
           abs(state.velocity.y) < 0.18 {
            mode = .manual
            updateControlValues({ values in
                values.y = 0.0
                values.throttle = 0.0
                values.roll = 0.0
                values.pitch = 0.0
            }, markManual: false)
        }

        if mode == .returnHome {
            let horizontalDistance = simd_length(SIMD2<Float>(state.position.x - homePosition.x, state.position.z - homePosition.z))
            if horizontalDistance < 0.45 && state.position.y <= homePosition.y + 1.8 {
                mode = .hover
                lockControlsToCurrentState(overrideThrottle: 0.54)
            }
        }
    }

    private func updateFleetStatus(deltaTime: Float) -> [CollisionObstacle] {
        guard fleetStatus.enabled, fleetStatus.mode != .off else {
            fleetStatus.interDroneRisk = 0.0
            fleetStatus.nearestInterDroneDistance = .infinity
            wingmen.removeAll()
            return []
        }

        let leader = DroneEntity(
            id: fleetLeaderID,
            position: state.position,
            velocity: state.velocity,
            collisionRadius: selectedDroneProfile.collisionRadius
        )

        wingmen = fleetManager.stepWingmen(
            current: wingmen,
            leaderPosition: state.position,
            leaderVelocity: state.velocity,
            leaderYaw: state.orientation.z,
            mode: fleetStatus.mode,
            requestedCount: fleetStatus.wingmanCount,
            separation: fleetStatus.separationDistance,
            radius: selectedDroneProfile.collisionRadius,
            deltaTime: deltaTime
        )

        let interDrone = fleetManager.interDroneCollisionSnapshot(
            leader: leader,
            wingmen: wingmen
        )

        fleetStatus.interDroneRisk = interDrone.riskScore
        fleetStatus.nearestInterDroneDistance = interDrone.nearestSeparation

        return fleetManager.collisionObstacles(for: wingmen)
    }

    private func lockControlsToCurrentState(overrideThrottle: Double) {
        updateControlValues({ values in
            values.x = Double(state.position.x)
            values.y = Double(state.position.y)
            values.z = Double(state.position.z)
            values.roll = Double(state.orientation.x.radiansToDegrees)
            values.pitch = Double(state.orientation.y.radiansToDegrees)
            values.yaw = Double(state.orientation.z.radiansToDegrees)
            values.throttle = overrideThrottle
        }, markManual: false)
    }

    private func buildControlInput(from controls: DroneControlValues) -> DroneControlInput {
        DroneControlInput(
            targetPosition: SIMD3<Float>(Float(controls.x), Float(controls.y), Float(controls.z)),
            targetOrientation: SIMD3<Float>(
                Float(controls.roll).degreesToRadians,
                Float(controls.pitch).degreesToRadians,
                Float(controls.yaw).degreesToRadians
            ),
            throttle: Float(controls.throttle),
            mode: mode
        )
    }

    private func buildWarnings() -> [String] {
        var output: [String] = []

        if collisionAnalysis.riskScore >= 0.65 { output.append("warning.collision_high") }
        if weather.severityScore >= 0.7 { output.append("warning.weather_severe") }
        if batteryState.chargePercent <= 20 { output.append("warning.battery_low") }
        if damageState.averageHealth <= 0.70 { output.append("warning.integrity_low") }
        if fleetStatus.enabled, fleetStatus.interDroneRisk >= 0.5 { output.append("warning.fleet_risk") }
        if fleetStatus.enabled, fleetStatus.nearestInterDroneDistance.isFinite, fleetStatus.nearestInterDroneDistance < 1.5 {
            output.append("warning.interdrone_critical")
        }
        if mode == .emergencyStop { output.append("warning.emergency") }

        return output
    }

    private func buildTelemetrySnapshot() -> TelemetrySnapshot {
        let speed = simd_length(state.velocity)
        let iso = Self.isoFormatter.string(from: Date())
        let flight = flightState(speed: speed)

        return TelemetrySnapshot(
            timestampISO8601: iso,
            droneModelID: selectedDroneProfile.id,
            droneModelName: selectedDroneProfile.displayName,
            droneManufacturer: selectedDroneProfile.manufacturer,
            isAbstractModel: selectedDroneProfile.isAbstract,
            abstractParametersSummary: selectedDroneProfile.isAbstract ? abstractParametersSummary : "n/a",
            terrainPreset: terrain.preset.title,
            terrainDensity: Double(terrain.density),
            cameraMode: cameraConfiguration.mode.title,
            x: Double(state.position.x),
            y: Double(state.position.y),
            z: Double(state.position.z),
            velocityX: Double(state.velocity.x),
            velocityY: Double(state.velocity.y),
            velocityZ: Double(state.velocity.z),
            roll: Double(state.orientation.x.radiansToDegrees),
            pitch: Double(state.orientation.y.radiansToDegrees),
            yaw: Double(state.orientation.z.radiansToDegrees),
            speed: Double(speed),
            throttle: Double(state.throttle),
            modeTitle: mode.title,
            modeKey: mode.titleKey,
            flightState: flight.title,
            flightStateKey: flight.key,
            batteryPercent: Double(batteryState.chargePercent),
            batteryHealthPercent: Double(batteryState.healthPercent),
            powerDrawW: Double(batteryState.powerDrawW),
            estimatedRemainingMin: Double(batteryState.remainingTimeSec / 60.0),
            weatherPreset: weather.preset.title,
            weatherPresetKey: weather.preset.titleKey,
            weatherIntensity: Double(weather.normalizedIntensity),
            collisionRisk: Double(collisionAnalysis.riskScore),
            nearestObstacleDistance: Double(collisionAnalysis.nearestObstacleDistance),
            emergencyAction: collisionAnalysis.emergencyAction.title,
            emergencyActionKey: collisionAnalysis.emergencyAction.titleKey,
            damageSummary: damageState.summary,
            thermalSummary: thermalState.summary,
            fleetMode: fleetStatus.mode.title,
            fleetModeKey: fleetStatus.mode.titleKey,
            wingmanCount: fleetStatus.enabled ? wingmen.count : 0,
            interDroneRisk: Double(fleetStatus.interDroneRisk),
            nearestInterDroneDistance: Double(fleetStatus.nearestInterDroneDistance)
        )
    }

    private func flightState(speed: Float) -> (title: String, key: String) {
        if state.position.y < 0.03 && state.throttle < 0.10 {
            return ("On Ground", "flight_state.on_ground")
        }

        if batteryState.isDepleted {
            return ("Battery Depleted", "flight_state.battery_depleted")
        }

        if mode == .takeoff {
            return ("Ascending", "flight_state.ascending")
        }

        if mode == .landing {
            return ("Descending", "flight_state.descending")
        }

        if mode == .emergencyStop {
            return ("Emergency", "flight_state.emergency")
        }

        if speed < 0.25 {
            return ("Stable", "flight_state.stable")
        }

        if state.velocity.y > 0.2 {
            return ("Climbing", "flight_state.climbing")
        }

        if state.velocity.y < -0.2 {
            return ("Descending", "flight_state.descending")
        }

        return ("Cruise", "flight_state.cruise")
    }

    private var abstractParametersSummary: String {
        "mass=\(String(format: "%.2f", abstractParameters.massKg))kg,dim=\(Int(abstractParameters.unfoldedMm.x))x\(Int(abstractParameters.unfoldedMm.y))x\(Int(abstractParameters.unfoldedMm.z))mm,batt=\(String(format: "%.1f", abstractParameters.batteryEnergyWh))Wh,max=\(String(format: "%.1f", abstractParameters.maxHorizontalSpeedMps))mps"
    }

    private func updateControlValues(
        _ mutate: (inout DroneControlValues) -> Void,
        markManual: Bool
    ) {
        var next = controlValues
        mutate(&next)

        next.y = next.y.clamped(to: 0.0...52.0)
        next.throttle = next.throttle.clamped(to: 0.0...1.0)
        next.roll = next.roll.clamped(to: -70.0...70.0)
        next.pitch = next.pitch.clamped(to: -70.0...70.0)
        next.yaw = next.yaw.clamped(to: -180.0...180.0)

        if next == controlValues {
            return
        }

        controlValues = next
        if markManual {
            mode = .manual
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension DroneFlightMode {
    var isAutoControlled: Bool {
        switch self {
        case .autoPath, .returnHome:
            return true
        case .manual, .hover, .emergencyStop, .takeoff, .landing:
            return false
        }
    }
}

private extension Float {
    var radiansToDegrees: Float {
        self * 180.0 / .pi
    }

    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
```

## DroneUAVDemo/Presentation/Views/SceneViewportView.swift
```swift
import SwiftUI

struct SceneViewportView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            DroneSceneViewRepresentable(
                scene: viewModel.scene,
                pointOfView: viewModel.activeCameraNode,
                cameraMode: viewModel.cameraConfiguration.mode,
                cameraSensitivity: viewModel.cameraConfiguration.sensitivity,
                freeMoveSpeed: viewModel.cameraConfiguration.free.moveSpeed
            )
            .ignoresSafeArea()

            if viewModel.isControlPanelCollapsed || viewModel.isCompactTelemetryHUDEnabled {
                CompactTelemetryHUDView(
                    telemetry: viewModel.telemetry,
                    warningKeys: viewModel.warnings
                )
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("hud.title")
                        .font(.caption.weight(.semibold))
                    Text("\(localized("hud.camera")): \(localized(viewModel.cameraConfiguration.mode.titleKey)) | \(localized("hud.drone")): \(localized(viewModel.selectedDroneProfile.displayNameKey))")
                        .font(.caption2)
                    if let warningKey = viewModel.warnings.first {
                        Text(LocalizedStringKey(warningKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
        }
        .background(Color.black)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
```

## DroneUAVDemo/Presentation/Views/DroneSceneViewRepresentable.swift
```swift
import AppKit
import SceneKit
import SwiftUI

private final class FocusableSCNView: SCNView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

struct DroneSceneViewRepresentable: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode
    let cameraMode: CameraMode
    let cameraSensitivity: Float
    let freeMoveSpeed: Float

    func makeNSView(context: Context) -> SCNView {
        let view = FocusableSCNView()
        view.scene = scene
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black
        view.isPlaying = true
        view.allowsCameraControl = cameraMode != .fpv

        configureCameraControl(on: view)

        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== scene {
            view.scene = scene
        }

        view.pointOfView = pointOfView
        configureCameraControl(on: view)
    }

    private func configureCameraControl(on view: SCNView) {
        let supportsUserControl = cameraMode != .fpv
        let isFreeMode = cameraMode == .free
        view.allowsCameraControl = supportsUserControl

        let sensitivity = CGFloat(cameraSensitivity.clamped(to: 0.2...2.5))
        let cameraConfig = view.cameraControlConfiguration
        cameraConfig.allowsTranslation = isFreeMode
        cameraConfig.autoSwitchToFreeCamera = false
        cameraConfig.flyModeVelocity = CGFloat(freeMoveSpeed.clamped(to: 0.5...16.0))
        cameraConfig.panSensitivity = sensitivity
        cameraConfig.truckSensitivity = sensitivity
        cameraConfig.rotationSensitivity = sensitivity
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
```

## DroneUAVDemo/Presentation/Views/ControlPanelView.swift
```swift
import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Binding var appLanguage: AppLanguage

    @State private var showAbstractEditor: Bool = false

    private static let coordinateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let angleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let throttleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                languageSection
                keybindSection
                modelSection
                commandsSection
                positionSection
                orientationSection
                throttleSection
                cameraSection
                weatherSection
                terrainSection
                diagnosticsSection
                fleetSection
                damageSection
                warningsSection
                telemetrySection
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAbstractEditor) {
            AbstractModelEditorView(initial: viewModel.abstractParameters) { updated in
                viewModel.applyAbstractParameters(updated)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("panel.title")
                .font(.title3.weight(.semibold))
            Text("panel.keyboard_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("language.section")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("language.section", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.titleKey)).tag(language)
                    }
                }

                Button("panel.toggle_collapse") {
                    viewModel.toggleControlPanel()
                }
                .buttonStyle(.bordered)

                Button("ui.toggle_telemetry_hud") {
                    viewModel.toggleCompactTelemetryHUD()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
    }

    private var keybindSection: some View {
        GroupBox(LocalizedStringKey("keybind.section.title")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.keyBindingSections) { section in
                    Text(LocalizedStringKey(section.category.titleKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(section.bindings) { binding in
                        HStack {
                            Text(LocalizedStringKey(binding.command.titleKey))
                                .font(.caption)
                            Spacer()
                            Text(binding.keyLabel)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                if !viewModel.keyBindingConflicts.isEmpty {
                    Divider()
                    ForEach(viewModel.keyBindingConflicts, id: \.self) { issue in
                        Text("⚠︎ \(issue)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var modelSection: some View {
        GroupBox(LocalizedStringKey("panel.drone_profile")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("panel.model", selection: Binding(
                    get: { viewModel.selectedDroneProfile.id },
                    set: { viewModel.selectDroneModel(id: $0) }
                )) {
                    ForEach(viewModel.availableDroneProfiles, id: \.id) { profile in
                        Text(localized(profile.displayNameKey)).tag(profile.id)
                    }
                }

                if viewModel.selectedDroneProfile.isAbstract {
                    Button("abstract.edit") {
                        showAbstractEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                modelRow("panel.mass", String(format: "%.3f kg", viewModel.selectedDroneProfile.massKg))
                modelRow("panel.max_flight", String(format: "%.0f min", viewModel.selectedDroneProfile.maxFlightTimeMin))
                modelRow("panel.max_wind", String(format: "%.1f m/s", viewModel.selectedDroneProfile.maxWindResistanceMps))
                modelRow("panel.camera_layout", localized(viewModel.selectedDroneProfile.cameraLayoutKey))
                modelRow("panel.visual_class", localized(viewModel.selectedDroneProfile.visualClass.titleKey))
            }
            .padding(.top, 4)
        }
    }

    private func modelRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key))
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private var commandsSection: some View {
        GroupBox(LocalizedStringKey("panel.commands")) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button("command.reset") { viewModel.reset() }
                    Button("command.takeoff") { viewModel.takeoff() }
                    Button("command.land") { viewModel.land() }
                }

                HStack(spacing: 8) {
                    Button("command.hover") { viewModel.hover() }
                    Button("command.auto_path") { viewModel.activateAutoPath() }
                    Button("command.return_home") { viewModel.activateReturnHome() }
                }

                HStack(spacing: 8) {
                    Button("command.emergency_stop") { viewModel.activateEmergencyStop() }
                        .foregroundStyle(.red)
                    Spacer()
                    Button(viewModel.isSimulationRunning ? String(localized: "command.stop_animation") : String(localized: "command.start_animation")) {
                        viewModel.toggleSimulation()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
    }

    private var positionSection: some View {
        GroupBox(LocalizedStringKey("panel.position")) {
            VStack(spacing: 10) {
                SliderControlRow(title: String(localized: "axis.x"), value: binding(get: { viewModel.controlValues.x }, set: viewModel.setX), range: -120.0...120.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "axis.y"), value: binding(get: { viewModel.controlValues.y }, set: viewModel.setY), range: 0.0...52.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "axis.z"), value: binding(get: { viewModel.controlValues.z }, set: viewModel.setZ), range: -120.0...120.0, step: 0.1, formatter: Self.coordinateFormatter)
            }
            .padding(.top, 4)
        }
    }

    private var orientationSection: some View {
        GroupBox(LocalizedStringKey("panel.orientation")) {
            VStack(spacing: 10) {
                SliderControlRow(title: String(localized: "axis.roll"), value: binding(get: { viewModel.controlValues.roll }, set: viewModel.setRoll), range: -70.0...70.0, step: 0.5, formatter: Self.angleFormatter)
                SliderControlRow(title: String(localized: "axis.pitch"), value: binding(get: { viewModel.controlValues.pitch }, set: viewModel.setPitch), range: -70.0...70.0, step: 0.5, formatter: Self.angleFormatter)
                SliderControlRow(title: String(localized: "axis.yaw"), value: binding(get: { viewModel.controlValues.yaw }, set: viewModel.setYaw), range: -180.0...180.0, step: 1.0, formatter: Self.angleFormatter)
            }
            .padding(.top, 4)
        }
    }

    private var throttleSection: some View {
        GroupBox(LocalizedStringKey("panel.throttle")) {
            SliderControlRow(
                title: String(localized: "panel.throttle"),
                value: binding(get: { viewModel.controlValues.throttle }, set: viewModel.setThrottle),
                range: 0.0...1.0,
                step: 0.01,
                formatter: Self.throttleFormatter
            )
            .padding(.top, 4)
        }
    }

    private var cameraSection: some View {
        GroupBox(LocalizedStringKey("panel.camera")) {
            VStack(spacing: 10) {
                Picker("panel.camera_mode", selection: Binding(
                    get: { viewModel.cameraConfiguration.mode },
                    set: { viewModel.setCameraMode($0) }
                )) {
                    ForEach(CameraMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                    }
                }

                SliderControlRow(title: String(localized: "camera.fov"), value: binding(get: { Double(viewModel.cameraConfiguration.fov) }, set: viewModel.setCameraFov), range: 30.0...110.0, step: 1.0, formatter: Self.angleFormatter)
                SliderControlRow(title: String(localized: "camera.sensitivity"), value: binding(get: { Double(viewModel.cameraConfiguration.sensitivity) }, set: viewModel.setCameraSensitivity), range: 0.2...2.5, step: 0.05, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.smoothing"), value: binding(get: { Double(viewModel.cameraConfiguration.smoothing) }, set: viewModel.setCameraSmoothing), range: 0.0...0.95, step: 0.01, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.zoom_sensitivity"), value: binding(get: { Double(viewModel.cameraConfiguration.free.zoomSensitivity) }, set: viewModel.setCameraZoomSensitivity), range: 0.2...3.0, step: 0.05, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.free_speed"), value: binding(get: { Double(viewModel.cameraConfiguration.free.moveSpeed) }, set: viewModel.setFreeCameraMoveSpeed), range: 0.5...16.0, step: 0.1, formatter: Self.coordinateFormatter)

                if viewModel.supportsDistanceControl {
                    SliderControlRow(
                        title: String(localized: "camera.distance"),
                        value: binding(get: { viewModel.activeCameraDistance }, set: viewModel.setActiveCameraDistance),
                        range: viewModel.activeCameraDistanceRange,
                        step: 0.1,
                        formatter: Self.coordinateFormatter
                    )
                }

                SliderControlRow(title: String(localized: "camera.orbit_distance"), value: binding(get: { Double(viewModel.cameraConfiguration.orbitDistance) }, set: viewModel.setOrbitDistance), range: 2.0...22.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "camera.follow_x"), value: binding(get: { Double(viewModel.cameraConfiguration.followOffset.x) }, set: viewModel.setFollowOffsetX), range: -8.0...8.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "camera.follow_y"), value: binding(get: { Double(viewModel.cameraConfiguration.followOffset.y) }, set: viewModel.setFollowOffsetY), range: 0.2...12.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "camera.follow_z"), value: binding(get: { Double(viewModel.cameraConfiguration.followOffset.z) }, set: viewModel.setFollowOffsetZ), range: 1.0...24.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_stabilization"), value: binding(get: { Double(viewModel.cameraConfiguration.fpvStabilization) }, set: viewModel.setFPVStabilization), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_shake"), value: binding(get: { Double(viewModel.cameraConfiguration.fpvShake) }, set: viewModel.setFPVShake), range: 0.0...0.3, step: 0.01, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_yaw_limit"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.yawLimitDeg) }, set: viewModel.setFPVYawLimit), range: 2.0...60.0, step: 1.0, formatter: Self.angleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_pitch_limit"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.pitchLimitDeg) }, set: viewModel.setFPVPitchLimit), range: 2.0...45.0, step: 1.0, formatter: Self.angleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_near_clip"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.nearClip) }, set: viewModel.setFPVNearClip), range: 0.005...0.25, step: 0.005, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_mount_x"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.x) }, set: viewModel.setFPVMountOffsetX), range: -0.08...0.08, step: 0.001, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_mount_y"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.y) }, set: viewModel.setFPVMountOffsetY), range: -0.02...0.12, step: 0.001, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "camera.fpv_mount_z"), value: binding(get: { Double(viewModel.cameraConfiguration.fpv.mountOffset.z) }, set: viewModel.setFPVMountOffsetZ), range: 0.005...0.20, step: 0.001, formatter: Self.throttleFormatter)

                Toggle("camera.fpv_hide_obstructing", isOn: Binding(
                    get: { viewModel.cameraConfiguration.fpv.hideObstructingParts },
                    set: { viewModel.setFPVHideObstructions($0) }
                ))
            }
            .padding(.top, 4)
        }
    }

    private var weatherSection: some View {
        GroupBox(LocalizedStringKey("panel.weather")) {
            VStack(spacing: 10) {
                Picker("panel.weather", selection: Binding(
                    get: { viewModel.weather.preset },
                    set: { viewModel.setWeatherPreset($0) }
                )) {
                    ForEach(WeatherPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }

                SliderControlRow(title: String(localized: "weather.intensity"), value: binding(get: { Double(viewModel.weather.intensity) }, set: viewModel.setWeatherIntensity), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)
                SliderControlRow(title: String(localized: "weather.wind_direction"), value: binding(get: { Double(viewModel.weather.windDirectionDeg) }, set: viewModel.setWindDirection), range: -180.0...180.0, step: 1.0, formatter: Self.angleFormatter)
                SliderControlRow(title: String(localized: "weather.wind_speed"), value: binding(get: { Double(viewModel.weather.windSpeedMps) }, set: viewModel.setWindSpeed), range: 0.0...30.0, step: 0.1, formatter: Self.coordinateFormatter)
                SliderControlRow(title: String(localized: "weather.gusts"), value: binding(get: { Double(viewModel.weather.gusts) }, set: viewModel.setWindGusts), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)
            }
            .padding(.top, 4)
        }
    }

    private var terrainSection: some View {
        GroupBox(LocalizedStringKey("panel.terrain")) {
            VStack(spacing: 10) {
                Picker("panel.terrain", selection: Binding(
                    get: { viewModel.terrain.preset },
                    set: { viewModel.setTerrainPreset($0) }
                )) {
                    ForEach(TerrainPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }

                SliderControlRow(title: String(localized: "terrain.density"), value: binding(get: { Double(viewModel.terrain.density) }, set: viewModel.setTerrainDensity), range: 0.0...1.0, step: 0.01, formatter: Self.throttleFormatter)

                HStack {
                    Text("terrain.seed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { Int(viewModel.terrain.seed) },
                            set: { viewModel.setTerrainSeed(UInt64(max(0, $0))) }
                        ),
                        in: 0...999_999
                    ) {
                        Text("\(viewModel.terrain.seed)")
                            .font(.caption.monospacedDigit())
                    }
                    .frame(width: 150)
                }
            }
            .padding(.top, 4)
        }
    }

    private var diagnosticsSection: some View {
        GroupBox(LocalizedStringKey("panel.diagnostics")) {
            VStack(spacing: 8) {
                Picker("diagnostic.mode", selection: Binding(
                    get: { viewModel.diagnosticMode },
                    set: { viewModel.setDiagnosticMode($0) }
                )) {
                    ForEach(DiagnosticOverlayMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                    }
                }

                Toggle("diagnostic.collision_debug", isOn: $viewModel.collisionDebugEnabled)
                Toggle("diagnostic.fleet_mode", isOn: Binding(
                    get: { viewModel.fleetStatus.enabled },
                    set: { _ in viewModel.toggleFleetEnabled() }
                ))
            }
            .padding(.top, 4)
        }
    }

    private var fleetSection: some View {
        GroupBox(LocalizedStringKey("panel.fleet")) {
            VStack(spacing: 10) {
                Picker("fleet.formation", selection: Binding(
                    get: { viewModel.fleetStatus.mode },
                    set: { viewModel.setFormationMode($0) }
                )) {
                    ForEach(FormationMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                    }
                }

                SliderControlRow(title: String(localized: "fleet.separation"), value: binding(get: { Double(viewModel.fleetStatus.separationDistance) }, set: viewModel.setSeparationDistance), range: 1.0...20.0, step: 0.1, formatter: Self.coordinateFormatter)

                HStack {
                    Text("fleet.wingmen")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { viewModel.fleetStatus.wingmanCount },
                            set: { viewModel.setFleetWingmanCount($0) }
                        ),
                        in: 1...5
                    ) {
                        Text("\(viewModel.fleetStatus.wingmanCount)")
                            .font(.caption.monospacedDigit())
                    }
                    .frame(width: 120)
                }
                .font(.caption)

                fleetMetric("fleet.risk", String(format: "%.0f %%", viewModel.fleetStatus.interDroneRisk * 100.0))
                fleetMetric("fleet.nearest", viewModel.fleetStatus.nearestInterDroneDistance.isFinite ? String(format: "%.2f m", viewModel.fleetStatus.nearestInterDroneDistance) : localized("common.na"))
            }
            .padding(.top, 4)
        }
    }

    private func fleetMetric(_ key: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key))
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private var damageSection: some View {
        GroupBox(LocalizedStringKey("panel.damage")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("damage.reset") {
                        viewModel.resetDamageState()
                    }
                    Spacer()
                    Button("damage.clear_selection") {
                        viewModel.selectComponent(nil)
                    }
                }

                ForEach(DamageComponent.allCases) { component in
                    HStack(spacing: 8) {
                        Button {
                            viewModel.selectComponent(component)
                        } label: {
                            Text(LocalizedStringKey(component.titleKey))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("\(Int(viewModel.damageState.health(for: component) * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)

                        Text("\(Int(viewModel.thermalState.temperature(for: component)))°C")
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)

                        Text(LocalizedStringKey(viewModel.damageState.warningState(for: component, temperature: viewModel.thermalState.temperature(for: component)).titleKey))
                            .font(.caption2)
                            .foregroundStyle(warningColor(component: component))
                            .frame(width: 58, alignment: .trailing)

                        Toggle("damage.hide", isOn: Binding(
                            get: { viewModel.damageState.hiddenComponents.contains(component) },
                            set: { viewModel.setComponentHidden(component, hidden: $0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(viewModel.damageState.selectedComponent == component ? Color.accentColor.opacity(0.16) : .clear)
                    )
                }
            }
            .padding(.top, 4)
        }
    }

    private func warningColor(component: DamageComponent) -> Color {
        let state = viewModel.damageState.warningState(
            for: component,
            temperature: viewModel.thermalState.temperature(for: component)
        )

        switch state {
        case .nominal:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    private var warningsSection: some View {
        GroupBox(LocalizedStringKey("panel.warnings")) {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.warnings.isEmpty {
                    Text("warnings.none")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.warnings, id: \.self) { warning in
                        Text("• \(localized(warning))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var telemetrySection: some View {
        GroupBox(LocalizedStringKey("panel.telemetry")) {
            VStack(spacing: 8) {
                TelemetryPanelView(telemetry: viewModel.telemetry)

                Button("telemetry.export") {
                    viewModel.exportTelemetry()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 4)
        }
    }

    private func binding(get: @escaping () -> Double, set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private struct SliderControlRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let formatter: NumberFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(title, value: value, formatter: formatter)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            Slider(value: value, in: range, step: step)
        }
    }
}
```

## DroneUAVDemo/Resources/en.lproj/Localizable.strings
```swift
"common.ok" = "OK";
"common.cancel" = "Cancel";
"common.save" = "Save";
"common.na" = "N/A";
"app.language" = "app.language";

"language.section" = "Language";
"language.system" = "System";
"language.english" = "English";
"language.russian" = "Russian";

"panel.title" = "UAV Digital Twin Simulator";
"panel.keyboard_hint" = "WASD/QE fly, Shift boost, Space hover, F FPV, G thermal, H damage, Tab collapse";
"panel.toggle_collapse" = "Collapse/Expand Control Panel";
"panel.drone_profile" = "UAV Profile";
"panel.model" = "Model";
"panel.mass" = "Mass";
"panel.max_flight" = "Max flight";
"panel.max_wind" = "Wind resistance";
"panel.camera_layout" = "Camera layout";
"panel.visual_class" = "Visual class";
"panel.commands" = "Commands";
"panel.position" = "Position";
"panel.orientation" = "Orientation";
"panel.throttle" = "Throttle";
"panel.camera" = "Camera";
"panel.camera_mode" = "Camera mode";
"panel.weather" = "Weather";
"panel.terrain" = "Terrain";
"panel.diagnostics" = "Diagnostics";
"panel.fleet" = "Fleet";
"panel.damage" = "Damage & Health";
"panel.warnings" = "Warnings";
"panel.telemetry" = "Telemetry";

"axis.x" = "X";
"axis.y" = "Y";
"axis.z" = "Z";
"axis.roll" = "Roll";
"axis.pitch" = "Pitch";
"axis.yaw" = "Yaw";

"camera.mode.free" = "Free";
"camera.mode.follow" = "Follow";
"camera.mode.fpv" = "FPV";
"camera.mode.orbit" = "Orbit";
"camera.fov" = "FOV";
"camera.sensitivity" = "Sensitivity";
"camera.smoothing" = "Smoothing";
"camera.orbit_distance" = "Orbit distance";
"camera.follow_x" = "Follow offset X";
"camera.follow_y" = "Follow offset Y";
"camera.follow_z" = "Follow offset Z";
"camera.fpv_stabilization" = "FPV stabilization";
"camera.fpv_shake" = "FPV shake";

"command.reset" = "Reset";
"command.takeoff" = "Takeoff";
"command.land" = "Land";
"command.hover" = "Hover";
"command.auto_path" = "Auto Path";
"command.return_home" = "Return Home";
"command.emergency_stop" = "Emergency Stop";
"command.start_animation" = "Start Simulation";
"command.stop_animation" = "Stop Simulation";

"weather.normal" = "Normal";
"weather.wind" = "Wind";
"weather.rain" = "Rain";
"weather.snow" = "Snow";
"weather.fog" = "Fog";
"weather.smog" = "Smog";
"weather.thunderstorm" = "Thunderstorm";
"weather.intensity" = "Intensity";
"weather.wind_direction" = "Wind direction";
"weather.wind_speed" = "Wind speed";
"weather.gusts" = "Gusts";

"terrain.grid_demo" = "Grid Demo";
"terrain.field" = "Field";
"terrain.forest" = "Forest";
"terrain.city" = "City";
"terrain.density" = "Object density";
"terrain.seed" = "Seed";

"diagnostic.mode" = "Diagnostic mode";
"diagnostic.mode.normal" = "Normal view";
"diagnostic.mode.thermal" = "Thermal / Load";
"diagnostic.mode.damage" = "Damage / Integrity";
"diagnostic.collision_debug" = "Collision debug";
"diagnostic.fleet_mode" = "Enable fleet";

"fleet.formation" = "Formation";
"fleet.mode.off" = "Off";
"fleet.mode.line" = "Line";
"fleet.mode.triangle" = "Triangle";
"fleet.separation" = "Separation";
"fleet.wingmen" = "Wingmen";
"fleet.risk" = "Inter-drone risk";
"fleet.nearest" = "Nearest separation";

"damage.reset" = "Reset damage";
"damage.clear_selection" = "Clear selection";
"damage.hide" = "Hide";

"component.battery" = "Battery";
"component.gimbal" = "Front camera / gimbal";
"component.fc_core" = "Flight controller core";
"component.motor_fl" = "Motor FL";
"component.motor_fr" = "Motor FR";
"component.motor_rl" = "Motor RL";
"component.motor_rr" = "Motor RR";
"component.propeller_fl" = "Propeller FL";
"component.propeller_fr" = "Propeller FR";
"component.propeller_rl" = "Propeller RL";
"component.propeller_rr" = "Propeller RR";
"component.arm_fl" = "Arm FL";
"component.arm_fr" = "Arm FR";
"component.arm_rl" = "Arm RL";
"component.arm_rr" = "Arm RR";
"component.esc_power" = "ESC / power electronics";

"warning.nominal" = "OK";
"warning.warning" = "Warn";
"warning.critical" = "Crit";
"warning.collision_high" = "High collision risk";
"warning.weather_severe" = "Severe weather conditions";
"warning.battery_low" = "Low battery";
"warning.integrity_low" = "Structural integrity low";
"warning.fleet_risk" = "Fleet separation risk";
"warning.interdrone_critical" = "Critical inter-drone proximity";
"warning.emergency" = "Emergency mode active";
"warnings.none" = "No active warnings";
"summary.damage.none" = "No critical damage";

"telemetry.position" = "Position";
"telemetry.velocity" = "Velocity";
"telemetry.attitude" = "Attitude";
"telemetry.speed" = "Speed";
"telemetry.throttle" = "Throttle";
"telemetry.mode" = "Mode";
"telemetry.state" = "State";
"telemetry.battery" = "Battery";
"telemetry.power" = "Power draw";
"telemetry.remaining" = "Remaining time";
"telemetry.weather" = "Weather";
"telemetry.collision_risk" = "Collision risk";
"telemetry.nearest_obstacle" = "Nearest obstacle";
"telemetry.emergency" = "Emergency action";
"telemetry.damage" = "Damage";
"telemetry.thermal" = "Thermal";
"telemetry.fleet" = "Fleet mode";
"telemetry.fleet_risk" = "Fleet risk";
"telemetry.nearest_interdrone" = "Nearest inter-drone";
"telemetry.export" = "Export Telemetry";
"telemetry.export.success" = "Telemetry exported";
"telemetry.export.failure" = "Telemetry export failed";

"hud.title" = "Telemetry HUD";
"hud.telemetry" = "Telemetry";
"hud.camera" = "Camera";
"hud.drone" = "Drone";

"mode.manual" = "Manual";
"mode.auto_path" = "Auto Path";
"mode.return_home" = "Return Home";
"mode.hover" = "Hover";
"mode.emergency_stop" = "Emergency Stop";
"mode.takeoff" = "Takeoff";
"mode.landing" = "Landing";

"flight_state.on_ground" = "On ground";
"flight_state.battery_depleted" = "Battery depleted";
"flight_state.ascending" = "Ascending";
"flight_state.descending" = "Descending";
"flight_state.emergency" = "Emergency";
"flight_state.stable" = "Stable";
"flight_state.climbing" = "Climbing";
"flight_state.cruise" = "Cruise";

"emergency.none" = "None";
"emergency.slow_down" = "Slow down";
"emergency.hover" = "Hover";
"emergency.avoid" = "Avoid";
"emergency.stop" = "Emergency stop";

"battery.depleted.title" = "Battery depleted";
"battery.depleted.message" = "Battery is fully depleted. Choose how to continue simulation.";
"battery.depleted.charge" = "Charge drone";
"battery.depleted.restart" = "Restart scenario";

"abstract.edit" = "Edit Parameters";
"abstract.editor.title" = "Abstract UAV Parameters";
"abstract.editor.mass" = "Mass";
"abstract.editor.dimensions" = "Dimensions";
"abstract.editor.energy" = "Energy and Limits";
"abstract.editor.control" = "Control";
"abstract.validation.vertical" = "Ascent/descent speeds are too low.";
"abstract.validation.speed" = "Horizontal speed must be >= ascent/descent speeds.";
"abstract.validation.radius" = "Collision radius is too large for selected dimensions.";

"drone.model.mini4pro" = "DJI Mini 4 Pro";
"drone.model.air3s" = "DJI Air 3S";
"drone.model.mavic3pro" = "DJI Mavic 3 Pro";
"drone.model.abstract" = "Abstract UAV";

"drone.visual.mini" = "Light compact quadcopter";
"drone.visual.air" = "Mid-size dual-camera quadcopter";
"drone.visual.mavic" = "Larger professional quadcopter";
"drone.visual.abstract" = "Custom abstract profile";

"drone.camera.single_compact" = "Single compact front gimbal";
"drone.camera.dual_front" = "Dual front camera module";
"drone.camera.triple_front" = "Triple front camera module";
"drone.camera.custom" = "Custom editable camera module";

"ui.toggle_telemetry_hud" = "Toggle compact telemetry HUD";

"camera.zoom_sensitivity" = "Zoom sensitivity";
"camera.free_speed" = "Free camera speed";
"camera.distance" = "Camera distance";
"camera.fpv_yaw_limit" = "FPV yaw limit";
"camera.fpv_pitch_limit" = "FPV pitch limit";
"camera.fpv_near_clip" = "FPV near clip";
"camera.fpv_mount_x" = "FPV mount X";
"camera.fpv_mount_y" = "FPV mount Y";
"camera.fpv_mount_z" = "FPV mount Z";
"camera.fpv_hide_obstructing" = "Hide obstructing drone parts in FPV";

"keybind.section.title" = "Key bindings";
"keybind.category.flight" = "Flight controls";
"keybind.category.camera" = "Camera controls";
"keybind.category.ui" = "UI controls";
"keybind.category.debug" = "Debug / overlays";
"keybind.flight.forward" = "Forward";
"keybind.flight.backward" = "Backward";
"keybind.flight.left" = "Left";
"keybind.flight.right" = "Right";
"keybind.flight.descend" = "Descend";
"keybind.flight.ascend" = "Ascend";
"keybind.flight.accelerate" = "Accelerate";
"keybind.flight.hover" = "Hover / stabilize";
"keybind.flight.reset" = "Reset drone";
"keybind.camera.toggle_fpv" = "Toggle FPV";
"keybind.camera.cycle_mode" = "Cycle camera mode";
"keybind.camera.zoom_in" = "Zoom in";
"keybind.camera.zoom_out" = "Zoom out";
"keybind.ui.toggle_panel" = "Collapse / expand panel";
"keybind.ui.toggle_hud" = "Toggle telemetry HUD";
"keybind.debug.toggle_damage" = "Toggle damage overlay";
"keybind.debug.toggle_thermal" = "Toggle thermal overlay";
```

## DroneUAVDemo/Resources/ru.lproj/Localizable.strings
```swift
"common.ok" = "ОК";
"common.cancel" = "Отмена";
"common.save" = "Сохранить";
"common.na" = "н/д";
"app.language" = "app.language";

"language.section" = "Язык";
"language.system" = "Системный";
"language.english" = "Английский";
"language.russian" = "Русский";

"panel.title" = "Симулятор цифрового двойника БПЛА";
"panel.keyboard_hint" = "WASD/QE полет, Shift ускорение, Space зависание, F FPV, G термо, H повреждения, Tab свернуть";
"panel.toggle_collapse" = "Свернуть/развернуть панель";
"panel.drone_profile" = "Профиль БПЛА";
"panel.model" = "Модель";
"panel.mass" = "Масса";
"panel.max_flight" = "Макс. полет";
"panel.max_wind" = "Сопротивление ветру";
"panel.camera_layout" = "Камерный модуль";
"panel.visual_class" = "Визуальный класс";
"panel.commands" = "Команды";
"panel.position" = "Положение";
"panel.orientation" = "Ориентация";
"panel.throttle" = "Тяга";
"panel.camera" = "Камера";
"panel.camera_mode" = "Режим камеры";
"panel.weather" = "Погода";
"panel.terrain" = "Местность";
"panel.diagnostics" = "Диагностика";
"panel.fleet" = "Группа";
"panel.damage" = "Повреждения и состояние";
"panel.warnings" = "Предупреждения";
"panel.telemetry" = "Телеметрия";

"axis.x" = "X";
"axis.y" = "Y";
"axis.z" = "Z";
"axis.roll" = "Крен";
"axis.pitch" = "Тангаж";
"axis.yaw" = "Рыскание";

"camera.mode.free" = "Свободная";
"camera.mode.follow" = "Следование";
"camera.mode.fpv" = "FPV";
"camera.mode.orbit" = "Орбита";
"camera.fov" = "Угол обзора";
"camera.sensitivity" = "Чувствительность";
"camera.smoothing" = "Сглаживание";
"camera.orbit_distance" = "Дистанция орбиты";
"camera.follow_x" = "Смещение следования X";
"camera.follow_y" = "Смещение следования Y";
"camera.follow_z" = "Смещение следования Z";
"camera.fpv_stabilization" = "FPV стабилизация";
"camera.fpv_shake" = "FPV дрожание";

"command.reset" = "Сброс";
"command.takeoff" = "Взлет";
"command.land" = "Посадка";
"command.hover" = "Зависнуть";
"command.auto_path" = "Авто-маршрут";
"command.return_home" = "Возврат домой";
"command.emergency_stop" = "Аварийная остановка";
"command.start_animation" = "Запустить симуляцию";
"command.stop_animation" = "Остановить симуляцию";

"weather.normal" = "Норма";
"weather.wind" = "Ветер";
"weather.rain" = "Дождь";
"weather.snow" = "Снег";
"weather.fog" = "Туман";
"weather.smog" = "Смог";
"weather.thunderstorm" = "Гроза";
"weather.intensity" = "Интенсивность";
"weather.wind_direction" = "Направление ветра";
"weather.wind_speed" = "Скорость ветра";
"weather.gusts" = "Порывы";

"terrain.grid_demo" = "Сетка (демо)";
"terrain.field" = "Поле";
"terrain.forest" = "Лес";
"terrain.city" = "Город";
"terrain.density" = "Плотность объектов";
"terrain.seed" = "Сид";

"diagnostic.mode" = "Режим диагностики";
"diagnostic.mode.normal" = "Обычный вид";
"diagnostic.mode.thermal" = "Тепло / Нагрузка";
"diagnostic.mode.damage" = "Повреждения / Целостность";
"diagnostic.collision_debug" = "Отладка коллизий";
"diagnostic.fleet_mode" = "Включить группу";

"fleet.formation" = "Построение";
"fleet.mode.off" = "Выкл";
"fleet.mode.line" = "Линия";
"fleet.mode.triangle" = "Треугольник";
"fleet.separation" = "Интервал";
"fleet.wingmen" = "Ведомые";
"fleet.risk" = "Риск между дронами";
"fleet.nearest" = "Минимальная дистанция";

"damage.reset" = "Сбросить повреждения";
"damage.clear_selection" = "Снять выбор";
"damage.hide" = "Скрыть";

"component.battery" = "Батарея";
"component.gimbal" = "Передняя камера / подвес";
"component.fc_core" = "Ядро полетного контроллера";
"component.motor_fl" = "Мотор FL";
"component.motor_fr" = "Мотор FR";
"component.motor_rl" = "Мотор RL";
"component.motor_rr" = "Мотор RR";
"component.propeller_fl" = "Пропеллер FL";
"component.propeller_fr" = "Пропеллер FR";
"component.propeller_rl" = "Пропеллер RL";
"component.propeller_rr" = "Пропеллер RR";
"component.arm_fl" = "Луч FL";
"component.arm_fr" = "Луч FR";
"component.arm_rl" = "Луч RL";
"component.arm_rr" = "Луч RR";
"component.esc_power" = "ESC / силовая электроника";

"warning.nominal" = "Норма";
"warning.warning" = "Внимание";
"warning.critical" = "Критично";
"warning.collision_high" = "Высокий риск столкновения";
"warning.weather_severe" = "Сложные погодные условия";
"warning.battery_low" = "Низкий заряд батареи";
"warning.integrity_low" = "Низкая структурная целостность";
"warning.fleet_risk" = "Риск в построении группы";
"warning.interdrone_critical" = "Критическое сближение дронов";
"warning.emergency" = "Активирован аварийный режим";
"warnings.none" = "Активных предупреждений нет";
"summary.damage.none" = "Критичных повреждений нет";

"telemetry.position" = "Координаты";
"telemetry.velocity" = "Скорость (вектор)";
"telemetry.attitude" = "Ориентация";
"telemetry.speed" = "Скорость";
"telemetry.throttle" = "Тяга";
"telemetry.mode" = "Режим";
"telemetry.state" = "Состояние";
"telemetry.battery" = "Батарея";
"telemetry.power" = "Потребление";
"telemetry.remaining" = "Осталось";
"telemetry.weather" = "Погода";
"telemetry.collision_risk" = "Риск столкновения";
"telemetry.nearest_obstacle" = "Ближайшее препятствие";
"telemetry.emergency" = "Аварийное действие";
"telemetry.damage" = "Повреждения";
"telemetry.thermal" = "Тепловая сводка";
"telemetry.fleet" = "Режим группы";
"telemetry.fleet_risk" = "Риск группы";
"telemetry.nearest_interdrone" = "Ближайший междроновый";
"telemetry.export" = "Экспорт телеметрии";
"telemetry.export.success" = "Телеметрия экспортирована";
"telemetry.export.failure" = "Ошибка экспорта телеметрии";

"hud.title" = "HUD телеметрии";
"hud.telemetry" = "Телеметрия";
"hud.camera" = "Камера";
"hud.drone" = "Дрон";

"mode.manual" = "Ручной";
"mode.auto_path" = "Авто-маршрут";
"mode.return_home" = "Возврат домой";
"mode.hover" = "Зависание";
"mode.emergency_stop" = "Аварийная остановка";
"mode.takeoff" = "Взлет";
"mode.landing" = "Посадка";

"flight_state.on_ground" = "На земле";
"flight_state.battery_depleted" = "Батарея разряжена";
"flight_state.ascending" = "Набор высоты";
"flight_state.descending" = "Снижение";
"flight_state.emergency" = "Авария";
"flight_state.stable" = "Стабильно";
"flight_state.climbing" = "Подъем";
"flight_state.cruise" = "Крейсерский";

"emergency.none" = "Нет";
"emergency.slow_down" = "Снизить скорость";
"emergency.hover" = "Зависнуть";
"emergency.avoid" = "Обход";
"emergency.stop" = "Аварийная остановка";

"battery.depleted.title" = "Батарея разряжена";
"battery.depleted.message" = "Заряд полностью исчерпан. Выберите действие для продолжения.";
"battery.depleted.charge" = "Зарядить дрон";
"battery.depleted.restart" = "Перезапустить сценарий";

"abstract.edit" = "Редактировать параметры";
"abstract.editor.title" = "Параметры Abstract UAV";
"abstract.editor.mass" = "Масса";
"abstract.editor.dimensions" = "Габариты";
"abstract.editor.energy" = "Энергия и ограничения";
"abstract.editor.control" = "Управляемость";
"abstract.validation.vertical" = "Скорость набора/снижения слишком мала.";
"abstract.validation.speed" = "Горизонтальная скорость должна быть >= вертикальных.";
"abstract.validation.radius" = "Радиус коллизии слишком велик для выбранных габаритов.";

"drone.model.mini4pro" = "DJI Mini 4 Pro";
"drone.model.air3s" = "DJI Air 3S";
"drone.model.mavic3pro" = "DJI Mavic 3 Pro";
"drone.model.abstract" = "Abstract UAV";

"drone.visual.mini" = "Легкий компактный квадрокоптер";
"drone.visual.air" = "Средний квадрокоптер с двумя камерами";
"drone.visual.mavic" = "Крупный профессиональный квадрокоптер";
"drone.visual.abstract" = "Пользовательский абстрактный профиль";

"drone.camera.single_compact" = "Один компактный фронтальный подвес";
"drone.camera.dual_front" = "Двойной фронтальный камерный модуль";
"drone.camera.triple_front" = "Тройной фронтальный камерный модуль";
"drone.camera.custom" = "Пользовательский редактируемый модуль";

"ui.toggle_telemetry_hud" = "Переключить компактный HUD";

"camera.zoom_sensitivity" = "Чувствительность зума";
"camera.free_speed" = "Скорость свободной камеры";
"camera.distance" = "Дистанция камеры";
"camera.fpv_yaw_limit" = "Лимит FPV рыскания";
"camera.fpv_pitch_limit" = "Лимит FPV тангажа";
"camera.fpv_near_clip" = "FPV ближняя отсечка";
"camera.fpv_mount_x" = "FPV крепление X";
"camera.fpv_mount_y" = "FPV крепление Y";
"camera.fpv_mount_z" = "FPV крепление Z";
"camera.fpv_hide_obstructing" = "Скрывать мешающие части дрона в FPV";

"keybind.section.title" = "Назначения клавиш";
"keybind.category.flight" = "Управление полетом";
"keybind.category.camera" = "Управление камерой";
"keybind.category.ui" = "Управление интерфейсом";
"keybind.category.debug" = "Отладка / оверлеи";
"keybind.flight.forward" = "Вперед";
"keybind.flight.backward" = "Назад";
"keybind.flight.left" = "Влево";
"keybind.flight.right" = "Вправо";
"keybind.flight.descend" = "Снижение";
"keybind.flight.ascend" = "Набор высоты";
"keybind.flight.accelerate" = "Ускорение";
"keybind.flight.hover" = "Зависание / стабилизация";
"keybind.flight.reset" = "Сброс дрона";
"keybind.camera.toggle_fpv" = "Переключить FPV";
"keybind.camera.cycle_mode" = "Смена режима камеры";
"keybind.camera.zoom_in" = "Приблизить";
"keybind.camera.zoom_out" = "Отдалить";
"keybind.ui.toggle_panel" = "Свернуть / развернуть панель";
"keybind.ui.toggle_hud" = "Переключить HUD телеметрии";
"keybind.debug.toggle_damage" = "Переключить оверлей повреждений";
"keybind.debug.toggle_thermal" = "Переключить тепловой оверлей";
```

