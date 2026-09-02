import AppKit
import CoreGraphics
import Foundation

/// Live adapter for kdkd/Analog-NTSC's upstream `rf2::NtscProcessor`.
///
/// The source scene is reduced to the library's native 720x480 RGB frame, the dynamic MAX7456
/// grid is composited into that same frame, and only then is it passed across the Objective-C++
/// bridge. Consequently camera pixels and OSD pixels share the exact encode -> composite IRE
/// effects -> decode path. UAVsim's SwiftUI chrome is outside this class and remains clean.
/// Access is serialized by `SceneRenderCoordinator`'s dedicated processing queue.
final class AnalogNTSCProcessor: @unchecked Sendable {
    static let frameWidth = 720
    static let frameHeight = 480

    private let nativeBridge = UAVAnalogNTSCNativeBridge()
    private let osdComposer = FPVOSDComposer()

    func process(
        sourceImage: CGImage,
        state: FPVOSDState,
        fontAtlas: FPVFontAtlas,
        layout: OSDLayoutConfiguration,
        availability: OSDElementAvailability,
        parameters: AnalogNTSCParameters
    ) -> CGImage? {
        let grid = osdComposer.compose(
            state: state,
            layout: layout,
            availability: availability,
            symbolMap: fontAtlas.symbolMap,
            blankGlyphs: fontAtlas.blankGlyphs
        )
        guard let input = makeRGBFrame(
            sourceImage: sourceImage,
            grid: grid,
            fontAtlas: fontAtlas,
            layout: layout
        ), let output = nativeBridge.processRGBFrame(
            input,
            noiseStandardDeviationIRE: Float(parameters.noiseStandardDeviationIRE),
            multipathGain: Float(parameters.multipathGain),
            multipathDelayPixels: Float(parameters.multipathDelayPixels),
            multipathEnsemble: Float(parameters.multipathEnsemble),
            impulseNoise: Float(parameters.impulseNoise),
            burstNoiseIRE: Float(parameters.burstNoiseIRE),
            horizontalSyncInstability: Float(parameters.horizontalSyncInstability),
            verticalSyncInstability: Float(parameters.verticalSyncInstability),
            chromaFlutter: Float(parameters.chromaFlutter),
            signalLoss: Float(parameters.signalLoss)
        ) else {
            return nil
        }
        return Self.makeRGBImage(data: output)
    }

    func reset() {
        nativeBridge.reset()
    }

    /// Produces upstream's packed RGB888 input. The CGContext is deliberately 720x480 and uses
    /// nearest-neighbour glyph sampling; no pre-rendered HUD/state image exists anywhere here.
    private func makeRGBFrame(
        sourceImage: CGImage,
        grid: OSDGrid,
        fontAtlas: FPVFontAtlas,
        layout: OSDLayoutConfiguration
    ) -> Data? {
        let width = Self.frameWidth
        let height = Self.frameHeight
        let bytesPerRow = width * 4
        var rgba = Data(repeating: 0, count: height * bytesPerRow)

        let didDraw = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            // Keep Core Graphics' native bottom-left bitmap orientation. Applying the usual
            // AppKit top-left flip here reverses the actual packed scanline order, and the native
            // NTSC processor quite correctly preserves that reversal all the way to the monitor.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(sourceImage, in: Self.aspectFillRect(
                sourceWidth: sourceImage.width,
                sourceHeight: sourceImage.height,
                targetWidth: width,
                targetHeight: height
            ))

            let horizontalInset = CGFloat(width) * CGFloat(layout.horizontalMarginFraction)
            let verticalInset = CGFloat(height) * CGFloat(layout.verticalMarginFraction)
            let gridWidth = CGFloat(width) - horizontalInset * 2
            let gridHeight = CGFloat(height) - verticalInset * 2
            let cellWidth = gridWidth / CGFloat(layout.columns)
            let cellHeight = gridHeight / CGFloat(layout.rows)
            context.interpolationQuality = .none

            for cell in grid.cells where cell.glyph != 32 {
                // Crop through the atlas itself so a two-bank INAV font, whose atlas is twice as
                // tall, addresses the same way a single-bank Betaflight one does.
                guard let glyphImage = fontAtlas.glyphImage(for: cell.glyph) else {
                    continue
                }
                let destinationRect = CGRect(
                    x: horizontalInset + CGFloat(cell.x) * cellWidth,
                    // OSDGrid rows are top-down while Core Graphics drawing coordinates are
                    // bottom-up. Convert the cell coordinate without flipping the framebuffer.
                    y: CGFloat(height) - verticalInset - CGFloat(cell.y + 1) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                context.draw(glyphImage, in: destinationRect)
            }
            return true
        }
        guard didDraw else { return nil }

        var rgb = Data(repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBytes { destination in
            rgba.withUnsafeBytes { source in
                guard let sourceBytes = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBytes = destination.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }
                for pixel in 0..<(width * height) {
                    let sourceOffset = pixel * 4
                    let destinationOffset = pixel * 3
                    destinationBytes[destinationOffset] = sourceBytes[sourceOffset]
                    destinationBytes[destinationOffset + 1] = sourceBytes[sourceOffset + 1]
                    destinationBytes[destinationOffset + 2] = sourceBytes[sourceOffset + 2]
                }
            }
        }
        return rgb
    }

    private static func aspectFillRect(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect {
        let sourceAspect = CGFloat(max(1, sourceWidth)) / CGFloat(max(1, sourceHeight))
        let targetAspect = CGFloat(targetWidth) / CGFloat(targetHeight)
        if sourceAspect > targetAspect {
            let drawWidth = CGFloat(targetHeight) * sourceAspect
            return CGRect(
                x: (CGFloat(targetWidth) - drawWidth) * 0.5,
                y: 0,
                width: drawWidth,
                height: CGFloat(targetHeight)
            )
        }
        let drawHeight = CGFloat(targetWidth) / sourceAspect
        return CGRect(
            x: 0,
            y: (CGFloat(targetHeight) - drawHeight) * 0.5,
            width: CGFloat(targetWidth),
            height: drawHeight
        )
    }

    private static func makeRGBImage(data: Data) -> CGImage? {
        let expectedCount = frameWidth * frameHeight * 3
        guard data.count == expectedCount,
              let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        return CGImage(
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: frameWidth * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
