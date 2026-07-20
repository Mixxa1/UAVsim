import SceneKit
import CoreGraphics
import AppKit
import simd

/// Procedural PBR facades, driven by the construction class resolved at import.
///
/// This is the deliberate answer to the fact that photographic facades for a whole city are not
/// obtainable as redistributable offline data. Real geometry carries recognisability from the
/// air — a block is identified by its footprint, height and roofline — and the facade's job is
/// to make each building read as the *right kind* of building at closer range. A prewar brick
/// walk-up, a postwar concrete slab and a glass tower differ in window rhythm, storey height,
/// colour and reflectivity far more than they differ in any individual photographic detail.
///
/// Textures are generated once per class and shared by every building of that class, so the
/// whole city costs a handful of textures rather than one per building.
enum UAVWorldFacadeMaterialFactory {

    /// The real-world size of one texture tile, and how the class is drawn.
    ///
    /// Storey heights here are the facade's *visual* rhythm and intentionally match the
    /// assumptions in `UAVWorldBuildingClassifier` — if the classifier converts floors to metres
    /// at 3.9 m for commercial buildings, the facade must draw a floor line every 3.9 m or the
    /// window count will not match the stated storey count.
    private struct FacadeStyle {
        let bayWidthMeters: CGFloat
        let floorHeightMeters: CGFloat
        /// Fraction of the bay occupied by glazing, horizontally and vertically.
        let windowWidthFraction: CGFloat
        let windowHeightFraction: CGFloat
        let wallColor: NSColor
        let wallVariation: CGFloat
        let windowColor: NSColor
        let trimColor: NSColor
        /// Drawn as a continuous horizontal band rather than discrete punched openings — the
        /// defining visual difference between curtain wall and load-bearing masonry.
        let isRibbonGlazing: Bool
        let roughness: CGFloat
        let metalness: CGFloat
        /// Horizontal floor-line emphasis, 0…1.
        let floorBandStrength: CGFloat
    }

    private static func style(for facadeClass: UAVWorldFacadeClass) -> FacadeStyle {
        switch facadeClass {
        case .brickPrewar:
            return FacadeStyle(
                bayWidthMeters: 3.0,
                floorHeightMeters: 3.1,
                windowWidthFraction: 0.42,
                windowHeightFraction: 0.55,
                wallColor: NSColor(calibratedRed: 0.44, green: 0.25, blue: 0.19, alpha: 1),
                wallVariation: 0.10,
                windowColor: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.70, green: 0.67, blue: 0.62, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.88,
                metalness: 0.0,
                floorBandStrength: 0.10
            )

        case .stoneMasonry:
            return FacadeStyle(
                bayWidthMeters: 3.4,
                floorHeightMeters: 3.6,
                windowWidthFraction: 0.38,
                windowHeightFraction: 0.58,
                wallColor: NSColor(calibratedRed: 0.66, green: 0.63, blue: 0.57, alpha: 1),
                wallVariation: 0.07,
                windowColor: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.19, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.76, green: 0.73, blue: 0.68, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.80,
                metalness: 0.0,
                floorBandStrength: 0.18
            )

        case .concretePostwar:
            return FacadeStyle(
                bayWidthMeters: 3.6,
                floorHeightMeters: 3.5,
                windowWidthFraction: 0.62,
                windowHeightFraction: 0.46,
                wallColor: NSColor(calibratedRed: 0.60, green: 0.59, blue: 0.56, alpha: 1),
                wallVariation: 0.06,
                windowColor: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.22, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.52, green: 0.51, blue: 0.49, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.75,
                metalness: 0.0,
                floorBandStrength: 0.30
            )

        case .glassCurtainWall:
            return FacadeStyle(
                bayWidthMeters: 1.5,
                floorHeightMeters: 3.9,
                windowWidthFraction: 0.92,
                windowHeightFraction: 0.80,
                wallColor: NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.32, alpha: 1),
                wallVariation: 0.03,
                windowColor: NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.38, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.39, alpha: 1),
                isRibbonGlazing: true,
                roughness: 0.16,
                metalness: 0.55,
                floorBandStrength: 0.22
            )

        case .metalPanel:
            return FacadeStyle(
                bayWidthMeters: 1.8,
                floorHeightMeters: 3.7,
                windowWidthFraction: 0.78,
                windowHeightFraction: 0.52,
                wallColor: NSColor(calibratedRed: 0.29, green: 0.29, blue: 0.31, alpha: 1),
                wallVariation: 0.05,
                windowColor: NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.21, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.40, green: 0.40, blue: 0.42, alpha: 1),
                isRibbonGlazing: true,
                roughness: 0.34,
                metalness: 0.75,
                floorBandStrength: 0.34
            )

        case .stucco:
            return FacadeStyle(
                bayWidthMeters: 3.2,
                floorHeightMeters: 3.0,
                windowWidthFraction: 0.36,
                windowHeightFraction: 0.50,
                wallColor: NSColor(calibratedRed: 0.78, green: 0.74, blue: 0.66, alpha: 1),
                wallVariation: 0.05,
                windowColor: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.20, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.85, green: 0.82, blue: 0.76, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.90,
                metalness: 0.0,
                floorBandStrength: 0.08
            )

        case .industrial:
            return FacadeStyle(
                bayWidthMeters: 2.4,
                floorHeightMeters: 5.4,
                windowWidthFraction: 0.30,
                windowHeightFraction: 0.22,
                wallColor: NSColor(calibratedRed: 0.51, green: 0.52, blue: 0.50, alpha: 1),
                wallVariation: 0.08,
                windowColor: NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.26, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.44, green: 0.45, blue: 0.44, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.70,
                metalness: 0.30,
                floorBandStrength: 0.06
            )

        case .residentialLowRise:
            return FacadeStyle(
                bayWidthMeters: 2.8,
                floorHeightMeters: 3.0,
                windowWidthFraction: 0.40,
                windowHeightFraction: 0.48,
                wallColor: NSColor(calibratedRed: 0.63, green: 0.55, blue: 0.46, alpha: 1),
                wallVariation: 0.09,
                windowColor: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.80, green: 0.78, blue: 0.74, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.86,
                metalness: 0.0,
                floorBandStrength: 0.10
            )

        case .unknown:
            return FacadeStyle(
                bayWidthMeters: 3.2,
                floorHeightMeters: 3.3,
                windowWidthFraction: 0.45,
                windowHeightFraction: 0.48,
                wallColor: NSColor(calibratedRed: 0.58, green: 0.57, blue: 0.55, alpha: 1),
                wallVariation: 0.05,
                windowColor: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.22, alpha: 1),
                trimColor: NSColor(calibratedRed: 0.62, green: 0.61, blue: 0.59, alpha: 1),
                isRibbonGlazing: false,
                roughness: 0.82,
                metalness: 0.0,
                floorBandStrength: 0.12
            )
        }
    }

    // MARK: - Public API

    private static var facadeCache: [UAVWorldFacadeClass: SCNMaterial] = [:]
    private static var roofCache: [UAVWorldFacadeClass: SCNMaterial] = [:]
    private static let cacheLock = NSLock()

    /// Materials for a building, in the slot order `UAVWorldBuildingGeometryFactory` emits:
    /// walls first, then roof.
    static func materials(for facadeClass: UAVWorldFacadeClass) -> [SCNMaterial] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let facade: SCNMaterial
        if let cached = facadeCache[facadeClass] {
            facade = cached
        } else {
            facade = makeFacadeMaterial(for: facadeClass)
            facadeCache[facadeClass] = facade
        }

        let roof: SCNMaterial
        if let cached = roofCache[facadeClass] {
            roof = cached
        } else {
            roof = makeRoofMaterial(for: facadeClass)
            roofCache[facadeClass] = roof
        }

        return [facade, roof]
    }

    static func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        facadeCache.removeAll()
        roofCache.removeAll()
    }

    // MARK: - Material construction

    private static func makeFacadeMaterial(for facadeClass: UAVWorldFacadeClass) -> SCNMaterial {
        let style = style(for: facadeClass)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = makeFacadeTexture(style: style, facadeClass: facadeClass)
        material.roughness.contents = style.roughness
        material.metalness.contents = style.metalness
        material.isDoubleSided = false

        // Wall UVs are in metres, so the texture must be scaled by the tile's real size to make
        // one tile cover one bay by one storey. This is what keeps window rhythm physically
        // correct across buildings of wildly different width.
        let transform = SCNMatrix4MakeScale(
            1.0 / style.bayWidthMeters,
            1.0 / style.floorHeightMeters,
            1.0
        )
        for property in [material.diffuse, material.roughness, material.metalness] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.contentsTransform = transform
            // Facades are seen at a grazing angle from a UAV, where anisotropic filtering is the
            // difference between legible window lines and a grey smear.
            property.mipFilter = .linear
            property.maxAnisotropy = 8
        }
        return material
    }

    private static func makeRoofMaterial(for facadeClass: UAVWorldFacadeClass) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased

        // Roofs are what a UAV actually looks at most of the time, and real ones are not the
        // same colour as the walls: tar, gravel, membrane and mechanical plant, almost always
        // darker and rougher than the facade.
        let base: NSColor
        switch facadeClass {
        case .glassCurtainWall, .metalPanel:
            base = NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.33, alpha: 1)
        case .industrial:
            base = NSColor(calibratedRed: 0.42, green: 0.43, blue: 0.42, alpha: 1)
        case .brickPrewar, .residentialLowRise, .stucco:
            base = NSColor(calibratedRed: 0.26, green: 0.25, blue: 0.24, alpha: 1)
        default:
            base = NSColor(calibratedRed: 0.33, green: 0.33, blue: 0.32, alpha: 1)
        }

        material.diffuse.contents = makeRoofTexture(base: base)
        material.roughness.contents = 0.93
        material.metalness.contents = 0.0
        material.isDoubleSided = false

        // Roof UVs are plan-projected metres; a 4 m tile keeps gravel/membrane grain plausible.
        let transform = SCNMatrix4MakeScale(0.25, 0.25, 1.0)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = transform
        material.diffuse.mipFilter = .linear
        material.diffuse.maxAnisotropy = 8
        return material
    }

    // MARK: - Texture generation

    private static let tilePixels = 256

    /// Draws one bay × one storey, tiling seamlessly.
    ///
    /// Seamlessness is achieved by construction rather than by blending: the window is centred
    /// in the tile and never drawn across an edge, and the floor band sits at the tile's bottom
    /// edge where it meets its own copy from the tile below.
    private static func makeFacadeTexture(
        style: FacadeStyle,
        facadeClass: UAVWorldFacadeClass
    ) -> NSImage {
        let size = tilePixels
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        let dimension = CGFloat(size)

        // Deterministic per class, so a rebuild produces identical textures and two runs of the
        // same world look the same.
        var generator = SeededGenerator(seed: UInt64(facadeClass.hashValue & 0x7FFF_FFFF) &+ 0x9E37)

        // 1. Base wall with fine tonal variation.
        style.wallColor.setFill()
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

        let grainCells = 32
        let cellSize = dimension / CGFloat(grainCells)
        for row in 0..<grainCells {
            for column in 0..<grainCells {
                let delta = (CGFloat(generator.nextUnit()) - 0.5) * 2.0 * style.wallVariation
                let shade = NSColor(
                    calibratedWhite: 0.5 + delta,
                    alpha: abs(delta) * 1.6
                )
                shade.setFill()
                context.fill(
                    CGRect(
                        x: CGFloat(column) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize + 1,
                        height: cellSize + 1
                    )
                )
            }
        }

        // 2. Floor band along the bottom edge, meeting its own copy from the tile below.
        if style.floorBandStrength > 0.01 {
            let bandHeight = dimension * 0.06
            NSColor(calibratedWhite: 0.0, alpha: style.floorBandStrength * 0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: dimension, height: bandHeight))
            NSColor(calibratedWhite: 1.0, alpha: style.floorBandStrength * 0.30).setFill()
            context.fill(CGRect(x: 0, y: bandHeight, width: dimension, height: bandHeight * 0.35))
        }

        // 3. Glazing.
        let windowWidth = dimension * style.windowWidthFraction
        let windowHeight = dimension * style.windowHeightFraction
        let windowRect = CGRect(
            x: (dimension - windowWidth) * 0.5,
            y: (dimension - windowHeight) * 0.5 + dimension * 0.04,
            width: windowWidth,
            height: windowHeight
        )

        if style.isRibbonGlazing {
            // Curtain wall: the glazing runs the full width of the tile, so adjacent bays form a
            // continuous horizontal ribbon with only a mullion between them.
            let ribbon = CGRect(
                x: 0,
                y: windowRect.minY,
                width: dimension,
                height: windowHeight
            )
            style.windowColor.setFill()
            context.fill(ribbon)

            // Vertical mullion at the tile edge, drawn as two half-widths so it tiles.
            let mullionWidth = dimension * 0.05
            style.trimColor.setFill()
            context.fill(CGRect(x: 0, y: ribbon.minY, width: mullionWidth * 0.5, height: ribbon.height))
            context.fill(CGRect(x: dimension - mullionWidth * 0.5, y: ribbon.minY,
                                width: mullionWidth * 0.5, height: ribbon.height))

            // A faint sky gradient in the glass so a tower is not a flat slab of colour.
            NSColor(calibratedWhite: 1.0, alpha: 0.09).setFill()
            context.fill(CGRect(x: 0, y: ribbon.maxY - ribbon.height * 0.3,
                                width: dimension, height: ribbon.height * 0.3))
        } else {
            // Punched opening with a lintel and sill — the signature of load-bearing masonry.
            style.trimColor.setFill()
            context.fill(windowRect.insetBy(dx: -dimension * 0.022, dy: -dimension * 0.022))

            style.windowColor.setFill()
            context.fill(windowRect)

            // Per-pane split, so windows read as windows rather than dark rectangles.
            let muntin = max(dimension * 0.008, 1.0)
            NSColor(calibratedWhite: 0.55, alpha: 0.45).setFill()
            context.fill(CGRect(x: windowRect.midX - muntin * 0.5, y: windowRect.minY,
                                width: muntin, height: windowRect.height))
            context.fill(CGRect(x: windowRect.minX, y: windowRect.midY - muntin * 0.5,
                                width: windowRect.width, height: muntin))

            // Reflected sky in the upper portion of the glass.
            NSColor(calibratedWhite: 1.0, alpha: 0.13).setFill()
            context.fill(CGRect(x: windowRect.minX, y: windowRect.maxY - windowRect.height * 0.35,
                                width: windowRect.width, height: windowRect.height * 0.35))
        }

        return image
    }

    private static func makeRoofTexture(base: NSColor) -> NSImage {
        let size = 128
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        let dimension = CGFloat(size)

        base.setFill()
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

        // Gravel/membrane speckle. Deterministic so roofs do not shimmer between runs.
        var generator = SeededGenerator(seed: 0x524F_4F46)
        for _ in 0..<900 {
            let x = CGFloat(generator.nextUnit()) * dimension
            let y = CGFloat(generator.nextUnit()) * dimension
            let radius = CGFloat(generator.nextUnit()) * 1.6 + 0.4
            let brightness = 0.35 + CGFloat(generator.nextUnit()) * 0.45
            NSColor(calibratedWhite: brightness, alpha: 0.30).setFill()
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }

        return image
    }

    /// SplitMix64, matching the generator style already used elsewhere in the project.
    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        mutating func nextUnit() -> Double {
            Double(next() >> 11) * (1.0 / 9007199254740992.0)
        }
    }
}
