import AppKit
import SceneKit

enum EnvironmentProceduralMaterials {
    static func groundMaterial(for terrain: TerrainPreset) -> SCNMaterial {
        if let cached = groundMaterialCache[terrain] {
            return cached
        }

        let material = baseMaterial(
            diffuse: groundBaseColor(for: terrain),
            roughness: (terrain == .city || terrain == .cargoYard) ? 0.78 : 0.94,
            metalness: (terrain == .city || terrain == .cargoYard) ? 0.06 : 0.02
        )
        material.multiply.contents = groundNoiseImage(for: terrain)
        material.multiply.intensity = terrain == .city ? 0.38 : (terrain == .cargoYard ? 0.32 : 0.24)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.multiply.wrapS = .repeat
        material.multiply.wrapT = .repeat

        groundMaterialCache[terrain] = material
        return material
    }

    static func barkMaterial(variant: Int) -> SCNMaterial {
        let normalizedVariant = variant % barkPalette.count
        if let cached = barkMaterialCache[normalizedVariant] {
            return cached
        }

        let tone = barkPalette[normalizedVariant]
        let material = baseMaterial(diffuse: tone, roughness: 0.90, metalness: 0.02)
        material.multiply.contents = barkStripeImage(tone: tone)
        material.multiply.intensity = 0.26
        barkMaterialCache[normalizedVariant] = material
        return material
    }

    static func leafMaterial(variant: Int, biome: TerrainPreset) -> SCNMaterial {
        let cacheKey = "\(biome.rawValue)-\(variant % 3)"
        if let cached = leafMaterialCache[cacheKey] {
            return cached
        }

        let tone = leafTone(for: biome, variant: variant)
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = tone
        material.ambient.contents = tone
        material.roughness.contents = 0.92
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        material.transparency = 1.0
        material.transparencyMode = .singleLayer
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        material.emission.contents = tone.withAlphaComponent(0.18)
        material.emission.intensity = biome == .forest ? 0.62 : 0.48
        leafMaterialCache[cacheKey] = material
        return material
    }

    static func buildingFacadeMaterials(
        biome: TerrainPreset,
        width: Float,
        depth: Float,
        height: Float,
        seed: UInt64
    ) -> [SCNMaterial] {
        let family = facadeFamily(for: biome, seed: seed)
        let frontMaterial = facadeMaterial(family: family, variant: Int(seed & 0x3))
        configureBuildingFacade(frontMaterial, family: family, faceWidth: width, faceHeight: height, seed: seed &+ 0x11)

        let sideMaterial = facadeMaterial(family: family, variant: Int((seed >> 2) & 0x3))
        configureBuildingFacade(sideMaterial, family: family, faceWidth: depth, faceHeight: height, seed: seed &+ 0x27)

        let capMaterial = facadeMaterial(family: family, variant: Int((seed >> 4) & 0x3))
        capMaterial.multiply.contents = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        capMaterial.multiply.intensity = 0.08
        capMaterial.emission.contents = NSColor.clear
        capMaterial.emission.intensity = 0.0

        return [
            frontMaterial,
            sideMaterial,
            frontMaterial.copy() as? SCNMaterial ?? frontMaterial,
            sideMaterial.copy() as? SCNMaterial ?? sideMaterial,
            capMaterial,
            capMaterial.copy() as? SCNMaterial ?? capMaterial
        ]
    }

    static func roofMaterial(height: Float, seed: UInt64) -> SCNMaterial {
        let family = roofFamily(for: seed)
        let tone = roofPalette[family]?[Int(seed & 0x1)] ?? roofPalette[.flatMetal]![0]
        let material = baseMaterial(diffuse: tone, roughness: family == .flatMetal ? 0.60 : 0.76, metalness: family == .flatMetal ? 0.22 : 0.04)
        material.multiply.contents = roofPatternImage(tone: tone, family: family)
        material.multiply.intensity = height > 22.0 ? 0.20 : 0.12
        return material
    }

    static var utilityPoleMaterial: SCNMaterial {
        if let cached = staticMaterialCache["pole"] {
            return cached
        }
        let material = baseMaterial(
            diffuse: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.70, alpha: 1.0),
            roughness: 0.58,
            metalness: 0.18
        )
        staticMaterialCache["pole"] = material
        return material
    }

    static var crateMaterial: SCNMaterial {
        if let cached = staticMaterialCache["crate"] {
            return cached
        }
        let material = baseMaterial(
            diffuse: NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.20, alpha: 1.0),
            roughness: 0.82,
            metalness: 0.01
        )
        material.multiply.contents = cratePlankImage()
        material.multiply.intensity = 0.22
        staticMaterialCache["crate"] = material
        return material
    }

    static var rockMaterial: SCNMaterial {
        if let cached = staticMaterialCache["rock"] {
            return cached
        }
        let material = baseMaterial(
            diffuse: NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.46, alpha: 1.0),
            roughness: 0.96,
            metalness: 0.0
        )
        material.multiply.contents = rockSpeckleImage()
        material.multiply.intensity = 0.20
        staticMaterialCache["rock"] = material
        return material
    }

    static var markerMaterial: SCNMaterial {
        if let cached = staticMaterialCache["marker"] {
            return cached
        }
        let material = baseMaterial(
            diffuse: NSColor.systemOrange,
            roughness: 0.52,
            metalness: 0.06
        )
        material.emission.contents = NSColor.systemOrange.withAlphaComponent(0.18)
        material.emission.intensity = 0.42
        staticMaterialCache["marker"] = material
        return material
    }

    private static func cachedStaticMaterial(
        key: String,
        diffuse: NSColor,
        roughness: CGFloat,
        metalness: CGFloat
    ) -> SCNMaterial {
        if let cached = staticMaterialCache[key] {
            return cached
        }
        let material = baseMaterial(diffuse: diffuse, roughness: roughness, metalness: metalness)
        staticMaterialCache[key] = material
        return material
    }

    private static func baseMaterial(
        diffuse: Any,
        roughness: CGFloat,
        metalness: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        return material
    }

    private static func groundBaseColor(for terrain: TerrainPreset) -> NSColor {
        switch terrain {
        case .gridDemo:
            return NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.26, alpha: 1.0)
        case .field:
            return NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.22, alpha: 1.0)
        case .forest:
            return NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.11, alpha: 1.0)
        case .cargoYard:
            return NSColor(calibratedRed: 0.31, green: 0.31, blue: 0.28, alpha: 1.0)
        case .city:
            return NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.26, alpha: 1.0)
        }
    }

    private static func leafTone(for biome: TerrainPreset, variant: Int) -> NSColor {
        let tones: [TerrainPreset: [NSColor]] = [
            .forest: [
                NSColor(calibratedRed: 0.17, green: 0.43, blue: 0.19, alpha: 1.0),
                NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.17, alpha: 1.0),
                NSColor(calibratedRed: 0.22, green: 0.47, blue: 0.23, alpha: 1.0)
            ],
            .field: [
                NSColor(calibratedRed: 0.29, green: 0.50, blue: 0.22, alpha: 1.0),
                NSColor(calibratedRed: 0.34, green: 0.56, blue: 0.24, alpha: 1.0),
                NSColor(calibratedRed: 0.26, green: 0.44, blue: 0.18, alpha: 1.0)
            ],
            .cargoYard: [
                NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.21, alpha: 1.0),
                NSColor(calibratedRed: 0.21, green: 0.35, blue: 0.19, alpha: 1.0),
                NSColor(calibratedRed: 0.28, green: 0.44, blue: 0.24, alpha: 1.0)
            ],
            .city: [
                NSColor(calibratedRed: 0.25, green: 0.44, blue: 0.22, alpha: 1.0),
                NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.20, alpha: 1.0),
                NSColor(calibratedRed: 0.31, green: 0.49, blue: 0.25, alpha: 1.0)
            ],
            .gridDemo: [
                NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.28, alpha: 1.0),
                NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.26, alpha: 1.0),
                NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.32, alpha: 1.0)
            ]
        ]
        return tones[biome]?[variant % 3] ?? NSColor.systemGreen
    }

    private static func facadeFamily(for biome: TerrainPreset, seed: UInt64) -> BuildingFacadeFamily {
        let roll = Int(seed % 100)
        switch biome {
        case .city:
            if roll < 22 { return .glassAccent }
            if roll < 52 { return .concretePanel }
            if roll < 76 { return .brick }
            return .plaster
        case .cargoYard:
            if roll < 68 { return .concretePanel }
            if roll < 88 { return .brick }
            return .plaster
        case .field, .forest:
            if roll < 42 { return .brick }
            if roll < 70 { return .plaster }
            return .concretePanel
        case .gridDemo:
            return .concretePanel
        }
    }

    private static func roofFamily(for seed: UInt64) -> BuildingRoofFamily {
        (seed & 0x1) == 0 ? .tile : .flatMetal
    }

    private static func facadeMaterial(family: BuildingFacadeFamily, variant: Int) -> SCNMaterial {
        let color = facadePalette[family]?[variant % 4] ?? facadePalette[.concretePanel]![0]
        let material = baseMaterial(
            diffuse: color,
            roughness: family == .glassAccent ? 0.48 : 0.76,
            metalness: family == .glassAccent ? 0.16 : 0.04
        )
        material.multiply.contents = facadeSurfacePattern(family: family, tone: color)
        material.multiply.intensity = family == .glassAccent ? 0.18 : 0.24
        return material
    }

    private static func configureBuildingFacade(
        _ material: SCNMaterial,
        family: BuildingFacadeFamily,
        faceWidth: Float,
        faceHeight: Float,
        seed: UInt64
    ) {
        let tileX = CGFloat(max(1.0, faceWidth / (family == .glassAccent ? 5.6 : 4.8)))
        let tileY = CGFloat(max(1.0, faceHeight / (family == .glassAccent ? 4.8 : 3.8)))
        let transform = SCNMatrix4MakeScale(tileX, tileY, 1.0)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = transform
        material.multiply.wrapS = .repeat
        material.multiply.wrapT = .repeat
        material.multiply.contentsTransform = transform
        material.emission.contents = facadeWindowOverlay(
            family: family,
            faceWidth: faceWidth,
            faceHeight: faceHeight,
            seed: seed
        )
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp
        material.emission.contentsTransform = SCNMatrix4Identity
        material.emission.intensity = family == .glassAccent ? 1.16 : 1.08
    }

    private static func facadeWindowOverlay(
        family: BuildingFacadeFamily,
        faceWidth: Float,
        faceHeight: Float,
        seed: UInt64
    ) -> NSImage {
        let columns: Int
        let rows: Int
        switch family {
        case .glassAccent:
            columns = max(2, min(5, Int((faceWidth / 5.2).rounded())))
            rows = max(3, min(18, Int((faceHeight / 4.2).rounded())))
        case .brick, .plaster, .concretePanel:
            columns = max(2, min(6, Int((faceWidth / 4.8).rounded())))
            rows = max(3, min(16, Int((faceHeight / 3.9).rounded())))
        }

        let cacheKey = "\(family.rawValue)-\(columns)x\(rows)-\(seed & 0x1F)"
        if let cached = facadeWindowOverlayCache[cacheKey] {
            return cached
        }

        let canvasSize = NSSize(width: 512, height: 512)
        let image = NSImage(size: canvasSize)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

        let marginX = canvasSize.width * 0.08
        let marginY = canvasSize.height * 0.08
        let cellWidth = (canvasSize.width - marginX * 2.0) / CGFloat(max(columns, 1))
        let cellHeight = (canvasSize.height - marginY * 2.0) / CGFloat(max(rows, 1))
        let windowWidth = max(20.0, min(cellWidth * (family == .glassAccent ? 0.76 : 0.58), 72.0))
        let windowHeight = max(30.0, min(cellHeight * (family == .glassAccent ? 0.88 : 0.74), 96.0))
        let cornerRadius = min(windowWidth, windowHeight) * (family == .glassAccent ? 0.18 : 0.10)
        let mullionColor = NSColor(calibratedWhite: 1.0, alpha: family == .glassAccent ? 0.045 : 0.06)
        let dimColor = family == .glassAccent
            ? NSColor(calibratedRed: 0.26, green: 0.36, blue: 0.46, alpha: 0.20)
            : NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.28, alpha: 0.12)
        let litPalette: [NSColor] = family == .glassAccent
            ? [
                NSColor(calibratedRed: 0.68, green: 0.86, blue: 1.0, alpha: 0.74),
                NSColor(calibratedRed: 0.54, green: 0.76, blue: 0.98, alpha: 0.68)
            ]
            : [
                NSColor(calibratedRed: 0.98, green: 0.92, blue: 0.74, alpha: 0.70),
                NSColor(calibratedRed: 0.76, green: 0.86, blue: 1.0, alpha: 0.60)
            ]
        var rng = MaterialDeterministicRNG(seed: seed &+ UInt64(columns * 37 + rows * 17))

        for row in 0..<rows {
            let bandY = marginY + CGFloat(row) * cellHeight
            let bandRect = NSRect(x: marginX * 0.66, y: bandY - 1.0, width: canvasSize.width - marginX * 1.32, height: max(1.0, cellHeight * 0.06))
            mullionColor.setFill()
            NSBezierPath(roundedRect: bandRect, xRadius: 1.2, yRadius: 1.2).fill()

            for column in 0..<columns {
                let originX = marginX + CGFloat(column) * cellWidth + (cellWidth - windowWidth) * 0.5
                let originY = marginY + CGFloat(row) * cellHeight + (cellHeight - windowHeight) * 0.5
                let rect = NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight)
                let isLit = rng.nextFloat() < (family == .glassAccent ? 0.72 : 0.54)
                let fillColor = isLit ? litPalette[Int(rng.next() % UInt64(litPalette.count))] : dimColor
                fillColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

                if family == .glassAccent {
                    let mullionWidth = max(1.6, rect.width * 0.07)
                    let mullionRect = NSRect(
                        x: rect.midX - mullionWidth * 0.5,
                        y: rect.minY,
                        width: mullionWidth,
                        height: rect.height
                    )
                    mullionColor.setFill()
                    NSBezierPath(roundedRect: mullionRect, xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
        }

        image.unlockFocus()
        facadeWindowOverlayCache[cacheKey] = image
        return image
    }

    private static func facadeSurfacePattern(family: BuildingFacadeFamily, tone: NSColor) -> NSImage {
        let cacheKey = "surface-\(family.rawValue)-\(tone.hash)"
        if let cached = generatedImageCache[cacheKey] {
            return cached
        }

        let size = NSSize(width: 160, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        tone.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let lineAlpha: CGFloat = family == .glassAccent ? 0.06 : 0.10
        NSColor(calibratedWhite: 1.0, alpha: lineAlpha).setStroke()
        let verticalStep: CGFloat = family == .glassAccent ? 40 : 28
        let horizontalStep: CGFloat = family == .glassAccent ? 26 : 20

        for x in stride(from: CGFloat(0), through: size.width, by: verticalStep) {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: size.height))
            path.lineWidth = 1.0
            path.stroke()
        }
        for y in stride(from: CGFloat(0), through: size.height, by: horizontalStep) {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: size.width, y: y))
            path.lineWidth = family == .glassAccent ? 0.8 : 1.1
            path.stroke()
        }

        image.unlockFocus()
        generatedImageCache[cacheKey] = image
        return image
    }

    private static func roofPatternImage(tone: NSColor, family: BuildingRoofFamily) -> NSImage {
        let cacheKey = "roof-\(family.rawValue)-\(tone.hash)"
        if let cached = generatedImageCache[cacheKey] {
            return cached
        }

        let size = NSSize(width: 192, height: 192)
        let image = NSImage(size: size)
        image.lockFocus()
        tone.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(calibratedWhite: 1.0, alpha: family == .tile ? 0.12 : 0.08).setStroke()

        let step: CGFloat = family == .tile ? 22 : 30
        for y in stride(from: CGFloat(0), through: size.height, by: step) {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: size.width, y: y))
            path.lineWidth = 1.0
            path.stroke()
        }
        if family == .tile {
            for x in stride(from: CGFloat(0), through: size.width, by: step * 0.5) {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x, y: 0))
                path.line(to: CGPoint(x: x, y: size.height))
                path.lineWidth = 0.6
                path.stroke()
            }
        }

        image.unlockFocus()
        generatedImageCache[cacheKey] = image
        return image
    }

    private static func barkStripeImage(tone: NSColor) -> NSImage {
        proceduralImage(cacheKey: "bark-\(tone.hash)", size: NSSize(width: 96, height: 256)) { size in
            tone.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            NSColor(calibratedWhite: 0.05, alpha: 0.14).setStroke()
            for x in stride(from: CGFloat(4), through: size.width, by: 14) {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x, y: 0))
                path.curve(
                    to: CGPoint(x: x + 6, y: size.height),
                    controlPoint1: CGPoint(x: x - 4, y: size.height * 0.35),
                    controlPoint2: CGPoint(x: x + 8, y: size.height * 0.72)
                )
                path.lineWidth = 2.2
                path.stroke()
            }
        }
    }

    private static func cratePlankImage() -> NSImage {
        proceduralImage(cacheKey: "crate-planks", size: NSSize(width: 160, height: 160)) { size in
            NSColor(calibratedRed: 0.32, green: 0.24, blue: 0.18, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            NSColor(calibratedWhite: 1.0, alpha: 0.10).setStroke()
            for y in stride(from: CGFloat(0), through: size.height, by: 24) {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: 0, y: y))
                path.line(to: CGPoint(x: size.width, y: y))
                path.lineWidth = 1.2
                path.stroke()
            }
        }
    }

    private static func rockSpeckleImage() -> NSImage {
        proceduralImage(cacheKey: "rock-speckle", size: NSSize(width: 96, height: 96)) { size in
            NSColor(calibratedRed: 0.43, green: 0.45, blue: 0.47, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            for index in 0..<48 {
                let radius = CGFloat((index % 4) + 1)
                let x = CGFloat((index * 17) % 92)
                let y = CGFloat((index * 29) % 92)
                let color = index % 3 == 0
                    ? NSColor(calibratedWhite: 1.0, alpha: 0.08)
                    : NSColor(calibratedWhite: 0.0, alpha: 0.08)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius * 2.0, height: radius * 2.0)).fill()
            }
        }
    }

    private static func groundNoiseImage(for terrain: TerrainPreset) -> NSImage {
        proceduralImage(cacheKey: "ground-\(terrain.rawValue)", size: NSSize(width: 192, height: 192)) { size in
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

            let accent: NSColor
            switch terrain {
            case .field:
                accent = NSColor(calibratedRed: 0.34, green: 0.28, blue: 0.12, alpha: 0.18)
            case .forest:
                accent = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.06, alpha: 0.22)
            case .cargoYard:
                accent = NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.08, alpha: 0.18)
            case .city:
                accent = NSColor(calibratedWhite: 0.0, alpha: 0.12)
            case .gridDemo:
                accent = NSColor(calibratedWhite: 0.0, alpha: 0.10)
            }

            for index in 0..<54 {
                let width = CGFloat(8 + (index % 5) * 6)
                let height = CGFloat(8 + (index % 4) * 5)
                let x = CGFloat((index * 31) % 176)
                let y = CGFloat((index * 23) % 176)
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: width, height: height)).fill()
            }

            switch terrain {
            case .field:
                NSColor(calibratedRed: 0.42, green: 0.35, blue: 0.18, alpha: 0.10).setStroke()
                for x in stride(from: CGFloat(12), through: size.width, by: 34) {
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.curve(
                        to: CGPoint(x: x + 10, y: size.height),
                        controlPoint1: CGPoint(x: x - 4, y: size.height * 0.32),
                        controlPoint2: CGPoint(x: x + 14, y: size.height * 0.74)
                    )
                    path.lineWidth = 1.2
                    path.stroke()
                }
            case .forest:
                NSColor(calibratedWhite: 0.0, alpha: 0.12).setFill()
                for index in 0..<22 {
                    let radius = CGFloat(10 + (index % 4) * 4)
                    let x = CGFloat((index * 43) % 168)
                    let y = CGFloat((index * 37) % 168)
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius * 1.8, height: radius)).fill()
                }
            case .cargoYard:
                NSColor(calibratedRed: 0.70, green: 0.58, blue: 0.20, alpha: 0.10).setStroke()
                for y in stride(from: CGFloat(16), through: size.height, by: 42) {
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.line(to: CGPoint(x: size.width, y: y))
                    path.lineWidth = 1.4
                    path.stroke()
                }
            case .city, .gridDemo:
                break
            }
        }
    }

    private static func proceduralImage(
        cacheKey: String,
        size: NSSize,
        draw: (NSSize) -> Void
    ) -> NSImage {
        if let cached = generatedImageCache[cacheKey] {
            return cached
        }
        let image = NSImage(size: size)
        image.lockFocus()
        draw(size)
        image.unlockFocus()
        generatedImageCache[cacheKey] = image
        return image
    }

    private static let barkPalette: [NSColor] = [
        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.18, alpha: 1.0),
        NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.20, alpha: 1.0),
        NSColor(calibratedRed: 0.48, green: 0.36, blue: 0.24, alpha: 1.0)
    ]

    private static let facadePalette: [BuildingFacadeFamily: [NSColor]] = [
        .brick: [
            NSColor(calibratedRed: 0.55, green: 0.34, blue: 0.29, alpha: 1.0),
            NSColor(calibratedRed: 0.62, green: 0.38, blue: 0.33, alpha: 1.0),
            NSColor(calibratedRed: 0.49, green: 0.31, blue: 0.27, alpha: 1.0),
            NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.29, alpha: 1.0)
        ],
        .plaster: [
            NSColor(calibratedRed: 0.74, green: 0.72, blue: 0.66, alpha: 1.0),
            NSColor(calibratedRed: 0.68, green: 0.67, blue: 0.62, alpha: 1.0),
            NSColor(calibratedRed: 0.77, green: 0.73, blue: 0.68, alpha: 1.0),
            NSColor(calibratedRed: 0.70, green: 0.69, blue: 0.64, alpha: 1.0)
        ],
        .concretePanel: [
            NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.61, alpha: 1.0),
            NSColor(calibratedRed: 0.50, green: 0.54, blue: 0.58, alpha: 1.0),
            NSColor(calibratedRed: 0.58, green: 0.60, blue: 0.63, alpha: 1.0),
            NSColor(calibratedRed: 0.48, green: 0.52, blue: 0.56, alpha: 1.0)
        ],
        .glassAccent: [
            NSColor(calibratedRed: 0.34, green: 0.44, blue: 0.56, alpha: 1.0),
            NSColor(calibratedRed: 0.28, green: 0.38, blue: 0.50, alpha: 1.0),
            NSColor(calibratedRed: 0.38, green: 0.48, blue: 0.60, alpha: 1.0),
            NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.52, alpha: 1.0)
        ]
    ]

    private static let roofPalette: [BuildingRoofFamily: [NSColor]] = [
        .tile: [
            NSColor(calibratedRed: 0.43, green: 0.25, blue: 0.20, alpha: 1.0),
            NSColor(calibratedRed: 0.49, green: 0.30, blue: 0.22, alpha: 1.0)
        ],
        .flatMetal: [
            NSColor(calibratedRed: 0.28, green: 0.30, blue: 0.33, alpha: 1.0),
            NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.39, alpha: 1.0)
        ]
    ]

    private static var groundMaterialCache: [TerrainPreset: SCNMaterial] = [:]
    private static var barkMaterialCache: [Int: SCNMaterial] = [:]
    private static var leafMaterialCache: [String: SCNMaterial] = [:]
    private static var facadeWindowOverlayCache: [String: NSImage] = [:]
    private static var generatedImageCache: [String: NSImage] = [:]
    private static var staticMaterialCache: [String: SCNMaterial] = [:]
}

private enum BuildingFacadeFamily: String {
    case brick
    case plaster
    case concretePanel
    case glassAccent
}

private enum BuildingRoofFamily: String {
    case tile
    case flatMetal
}

private struct MaterialDeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xCAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }

    mutating func nextFloat() -> Float {
        Float(next() & 0xFFFF) / Float(0xFFFF)
    }
}
