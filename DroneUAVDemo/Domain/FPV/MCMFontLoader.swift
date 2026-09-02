import CoreGraphics
import Foundation
import SpriteKit

enum MCMFontLoaderError: Error, Equatable {
    case unreadableFile
    case invalidHeader(String)
    case invalidPayloadLine(index: Int, value: String)
    case invalidByteCount(expected: Int, actual: Int)
    case imageCreationFailed
}

struct FPVGlyphBitmap: Equatable, Sendable {
    static let width = 12
    static let height = 18

    let glyph: UInt8
    /// RGBA8, top row first. Opaque black/white and transparent are preserved from MAX7456.
    let rgbaPixels: Data

    func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return nil }
        let offset = (y * Self.width + x) * 4
        guard offset + 3 < rgbaPixels.count else { return nil }
        return (
            rgbaPixels[offset],
            rgbaPixels[offset + 1],
            rgbaPixels[offset + 2],
            rgbaPixels[offset + 3]
        )
    }
}

struct FPVFontAtlas {
    static let glyphCount = 256
    static let columns = 16
    static let rows = 16

    let sourceName: String
    let symbolMap: FPVOSDSymbolMap
    let glyphBitmaps: [FPVGlyphBitmap]
    /// Slots this font leaves fully transparent, so the composer can substitute a text label
    /// instead of writing an invisible cell.
    let blankGlyphs: Set<UInt8>
    /// CPU-side atlas used by the analog-video compositor. Keeping the same image as the
    /// SpriteKit textures guarantees preset switching cannot select a different glyph source.
    let atlasImage: CGImage
    let atlasTexture: SKTexture
    let glyphTextures: [SKTexture]
    let pixelSize: CGSize

    func texture(for glyph: UInt8) -> SKTexture {
        glyphTextures[Int(glyph)]
    }

    /// Crops one glyph out of the atlas for AppKit/SwiftUI. The OSD editor draws the same pixels
    /// the analog compositor does, so a preview can never disagree with the flown frame.
    func glyphImage(for glyph: UInt8) -> CGImage? {
        let index = Int(glyph)
        let glyphWidth = atlasImage.width / Self.columns
        let glyphHeight = atlasImage.height / Self.rows
        guard glyphWidth > 0, glyphHeight > 0 else { return nil }
        return atlasImage.cropping(to: CGRect(
            x: (index % Self.columns) * glyphWidth,
            y: (index / Self.columns) * glyphHeight,
            width: glyphWidth,
            height: glyphHeight
        ))
    }

    /// True when the font leaves this slot entirely transparent. Community MCM fonts do not all
    /// fill the same semantic slots — several bundled ones have no crosshair halves — and the
    /// editor warns about that instead of silently drawing nothing.
    func isGlyphBlank(_ glyph: UInt8) -> Bool {
        let index = Int(glyph)
        guard index < glyphBitmaps.count else { return true }
        let pixels = glyphBitmaps[index].rgbaPixels
        var offset = 3
        while offset < pixels.count {
            if pixels[offset] != 0 { return false }
            offset += 4
        }
        return true
    }
}

struct MCMFontLoader {
    static let header = "MAX7456"
    static let bytesPerGlyph = 64
    static let pixelBytesPerGlyph = 54

    func load(from url: URL) throws -> FPVFontAtlas {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MCMFontLoaderError.unreadableFile
        }
        return try load(text: text, sourceName: url.deletingPathExtension().lastPathComponent)
    }

    func load(text: String, sourceName: String = "memory") throws -> FPVFontAtlas {
        let lines = text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else {
            throw MCMFontLoaderError.invalidHeader("")
        }
        guard first == Self.header else {
            throw MCMFontLoaderError.invalidHeader(first)
        }

        let payloadLines = Array(lines.dropFirst())
        let expectedByteCount = FPVFontAtlas.glyphCount * Self.bytesPerGlyph
        // MAX7456 exposes 256 addressable character slots. Some community "full" files append
        // a second complete 256-glyph bank for other tooling; UAVsim intentionally loads the
        // first hardware bank while still rejecting truncated or non-glyph-aligned payloads.
        guard payloadLines.count >= expectedByteCount,
              payloadLines.count.isMultiple(of: Self.bytesPerGlyph) else {
            throw MCMFontLoaderError.invalidByteCount(
                expected: expectedByteCount,
                actual: payloadLines.count
            )
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(payloadLines.count)
        for (index, line) in payloadLines.enumerated() {
            guard line.count == 8,
                  line.allSatisfy({ $0 == "0" || $0 == "1" }),
                  let byte = UInt8(line, radix: 2) else {
                throw MCMFontLoaderError.invalidPayloadLine(index: index, value: line)
            }
            bytes.append(byte)
        }

        let glyphs = (0..<FPVFontAtlas.glyphCount).map { glyphIndex in
            decodeGlyph(
                UInt8(glyphIndex),
                bytes: bytes,
                byteOffset: glyphIndex * Self.bytesPerGlyph
            )
        }
        return try makeAtlas(sourceName: sourceName, glyphs: glyphs)
    }

    private func decodeGlyph(
        _ glyph: UInt8,
        bytes: [UInt8],
        byteOffset: Int
    ) -> FPVGlyphBitmap {
        var rgba = Data(repeating: 0, count: FPVGlyphBitmap.width * FPVGlyphBitmap.height * 4)
        for characterByteIndex in 0..<Self.pixelBytesPerGlyph {
            let byte = bytes[byteOffset + characterByteIndex]
            let y = characterByteIndex / 3
            let fourPixelBlock = characterByteIndex % 3
            for pixelInBlock in 0..<4 {
                let x = fourPixelBlock * 4 + pixelInBlock
                let shift = 6 - pixelInBlock * 2
                let value = (byte >> shift) & 0b11
                let pixelOffset = (y * FPVGlyphBitmap.width + x) * 4
                switch value {
                case 0b00: // Opaque black
                    rgba[pixelOffset] = 0
                    rgba[pixelOffset + 1] = 0
                    rgba[pixelOffset + 2] = 0
                    rgba[pixelOffset + 3] = 255
                case 0b10: // Opaque white
                    rgba[pixelOffset] = 255
                    rgba[pixelOffset + 1] = 255
                    rgba[pixelOffset + 2] = 255
                    rgba[pixelOffset + 3] = 255
                default: // 01 and 11 are transparent in external-sync/video-overlay mode
                    rgba[pixelOffset] = 0
                    rgba[pixelOffset + 1] = 0
                    rgba[pixelOffset + 2] = 0
                    rgba[pixelOffset + 3] = 0
                }
            }
        }
        return FPVGlyphBitmap(glyph: glyph, rgbaPixels: rgba)
    }

    private func makeAtlas(
        sourceName: String,
        glyphs: [FPVGlyphBitmap]
    ) throws -> FPVFontAtlas {
        let atlasWidth = FPVFontAtlas.columns * FPVGlyphBitmap.width
        let atlasHeight = FPVFontAtlas.rows * FPVGlyphBitmap.height
        let rowByteCount = atlasWidth * 4
        var atlasPixels = Data(repeating: 0, count: atlasHeight * rowByteCount)

        for glyph in glyphs {
            let glyphIndex = Int(glyph.glyph)
            let atlasColumn = glyphIndex % FPVFontAtlas.columns
            let atlasRow = glyphIndex / FPVFontAtlas.columns
            for y in 0..<FPVGlyphBitmap.height {
                let sourceOffset = y * FPVGlyphBitmap.width * 4
                let destinationOffset = ((atlasRow * FPVGlyphBitmap.height + y) * atlasWidth
                    + atlasColumn * FPVGlyphBitmap.width) * 4
                atlasPixels.replaceSubrange(
                    destinationOffset..<(destinationOffset + FPVGlyphBitmap.width * 4),
                    with: glyph.rgbaPixels[sourceOffset..<(sourceOffset + FPVGlyphBitmap.width * 4)]
                )
            }
        }

        guard let provider = CGDataProvider(data: atlasPixels as CFData),
              let image = CGImage(
                width: atlasWidth,
                height: atlasHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowByteCount,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw MCMFontLoaderError.imageCreationFailed
        }

        let atlasTexture = SKTexture(cgImage: image)
        atlasTexture.filteringMode = .nearest
        var textures: [SKTexture] = []
        textures.reserveCapacity(FPVFontAtlas.glyphCount)
        for glyphIndex in 0..<FPVFontAtlas.glyphCount {
            let column = glyphIndex % FPVFontAtlas.columns
            let topDownRow = glyphIndex / FPVFontAtlas.columns
            let bottomUpRow = FPVFontAtlas.rows - topDownRow - 1
            let rect = CGRect(
                x: CGFloat(column) / CGFloat(FPVFontAtlas.columns),
                y: CGFloat(bottomUpRow) / CGFloat(FPVFontAtlas.rows),
                width: 1 / CGFloat(FPVFontAtlas.columns),
                height: 1 / CGFloat(FPVFontAtlas.rows)
            )
            let texture = SKTexture(rect: rect, in: atlasTexture)
            texture.filteringMode = .nearest
            textures.append(texture)
        }

        var blankGlyphs: Set<UInt8> = []
        for glyph in glyphs {
            let pixels = glyph.rgbaPixels
            var offset = pixels.startIndex + 3
            var isBlank = true
            while offset < pixels.endIndex {
                if pixels[offset] != 0 {
                    isBlank = false
                    break
                }
                offset += 4
            }
            if isBlank { blankGlyphs.insert(glyph.glyph) }
        }
        return FPVFontAtlas(
            sourceName: sourceName,
            symbolMap: .forFont(named: sourceName),
            glyphBitmaps: glyphs,
            blankGlyphs: blankGlyphs,
            atlasImage: image,
            atlasTexture: atlasTexture,
            glyphTextures: textures,
            pixelSize: CGSize(width: atlasWidth, height: atlasHeight)
        )
    }
}

@MainActor
final class FPVFontAtlasStore {
    static let shared = FPVFontAtlasStore()

    private var cache: [FPVFontPreset: FPVFontAtlas] = [:]
    private let loader = MCMFontLoader()

    func atlas(for preset: FPVFontPreset, bundle: Bundle = .main) throws -> FPVFontAtlas {
        if let cached = cache[preset] { return cached }
        guard let url = bundle.url(forResource: preset.resourceName, withExtension: "mcm") else {
            throw MCMFontLoaderError.unreadableFile
        }
        let atlas = try loader.load(from: url)
        cache[preset] = atlas
        return atlas
    }
}
