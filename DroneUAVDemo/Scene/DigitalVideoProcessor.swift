import CoreGraphics
import Foundation

/// Packet-video presentation. A healthy frame is returned untouched. Under delivery pressure the
/// decoder first loses spatial detail, then reuses regions from the last delivered image, drops
/// complete frames and finally holds the last frame. It deliberately contains no analog noise,
/// chroma carrier, ghosting or synchronization effects.
final class DigitalVideoProcessor: @unchecked Sendable {
    private var previousDeliveredFrame: CGImage?
    private var frameIndex: UInt64 = 0

    func process(
        sourceImage: CGImage,
        parameters: DigitalVideoParameters
    ) -> CGImage? {
        frameIndex &+= 1
        var random = VideoArtifactRandom(seed: frameIndex ^ 0xD161_7A1D_5EED)

        // If FPV is opened after the link has already failed there is no previous decoded image
        // yet. Retain this one captured frame so raw live SceneKit cannot leak through the loss.
        if parameters.isFrozen {
            let retained = previousDeliveredFrame ?? sourceImage
            previousDeliveredFrame = retained
            return retained
        }
        guard random.unit > parameters.frameDropProbability else {
            return nil
        }

        if parameters == .clean {
            previousDeliveredFrame = sourceImage
            return sourceImage
        }

        let outputSize = cappedOutputSize(for: sourceImage)
        guard let base = detailReducedImage(
            sourceImage,
            width: outputSize.width,
            height: outputSize.height,
            detailScale: parameters.detailScale
        ), let context = makeContext(width: outputSize.width, height: outputSize.height) else {
            return nil
        }

        context.interpolationQuality = .none
        let fullRect = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        context.draw(base, in: fullRect)

        let staleSource = previousDeliveredFrame ?? base
        let artifactCount = Int((parameters.packetArtifactIntensity * 18).rounded(.up))
        if artifactCount > 0 {
            for _ in 0..<artifactCount {
                let block = macroblockRect(
                    width: outputSize.width,
                    height: outputSize.height,
                    intensity: parameters.packetArtifactIntensity,
                    random: &random
                )
                let horizontalSlip = CGFloat(random.signedUnit)
                    * CGFloat(8 + 42 * parameters.packetArtifactIntensity)
                context.saveGState()
                context.clip(to: block)
                context.draw(
                    staleSource,
                    in: fullRect.offsetBy(dx: horizontalSlip, dy: 0)
                )
                context.restoreGState()
            }
        }

        // Packet loss commonly leaves slices/regions from an older decoded frame. These are
        // image-derived stale areas, never solid colored rectangles painted over the viewport.
        let staleCount = Int((parameters.staleRegionIntensity * 7).rounded(.up))
        if staleCount > 0 {
            for _ in 0..<staleCount {
                let bandHeight = CGFloat(16 + Int(random.unit * 64))
                let maximumY = max(0, CGFloat(outputSize.height) - bandHeight)
                let y = CGFloat(random.unit) * maximumY
                let band = CGRect(
                    x: 0,
                    y: y,
                    width: CGFloat(outputSize.width),
                    height: bandHeight
                )
                let slip = CGFloat(random.signedUnit)
                    * CGFloat(12 + 70 * parameters.staleRegionIntensity)
                context.saveGState()
                context.clip(to: band)
                context.draw(staleSource, in: fullRect.offsetBy(dx: slip, dy: 0))
                context.restoreGState()
            }
        }

        guard let output = context.makeImage() else { return nil }
        previousDeliveredFrame = output
        return output
    }

    func reset() {
        previousDeliveredFrame = nil
        frameIndex = 0
    }

    private func detailReducedImage(
        _ source: CGImage,
        width: Int,
        height: Int,
        detailScale: Double
    ) -> CGImage? {
        let scale = min(1, max(0.20, detailScale))
        let reducedWidth = max(64, Int(Double(width) * scale))
        let reducedHeight = max(36, Int(Double(height) * scale))
        guard let reduced = makeContext(width: reducedWidth, height: reducedHeight) else {
            return nil
        }
        reduced.interpolationQuality = scale > 0.72 ? .medium : .low
        reduced.draw(source, in: CGRect(x: 0, y: 0, width: reducedWidth, height: reducedHeight))
        guard let reducedImage = reduced.makeImage(),
              let expanded = makeContext(width: width, height: height) else {
            return nil
        }
        expanded.interpolationQuality = .none
        expanded.draw(reducedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return expanded.makeImage()
    }

    private func cappedOutputSize(for source: CGImage) -> (width: Int, height: Int) {
        let scale = min(
            1,
            min(1280.0 / Double(max(1, source.width)), 720.0 / Double(max(1, source.height)))
        )
        return (
            max(64, Int(Double(source.width) * scale)),
            max(36, Int(Double(source.height) * scale))
        )
    }

    private func macroblockRect(
        width: Int,
        height: Int,
        intensity: Double,
        random: inout VideoArtifactRandom
    ) -> CGRect {
        let blockSize = 16
        let maximumColumns = max(1, width / blockSize)
        let maximumRows = max(1, height / blockSize)
        let blockColumns = 1 + Int(random.unit * (2 + intensity * 7))
        let blockRows = 1 + Int(random.unit * (1 + intensity * 4))
        let xColumn = Int(random.unit * Double(maximumColumns))
        let yRow = Int(random.unit * Double(maximumRows))
        return CGRect(
            x: min(width - blockSize, xColumn * blockSize),
            y: min(height - blockSize, yRow * blockSize),
            width: min(width, blockColumns * blockSize),
            height: min(height, blockRows * blockSize)
        )
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

/// Clean wired transport with deterministic whole-frame delivery gaps only.
final class FiberVideoProcessor: @unchecked Sendable {
    private var frameIndex: UInt64 = 0

    func process(
        sourceImage: CGImage,
        parameters: FiberVideoParameters
    ) -> CGImage? {
        frameIndex &+= 1
        var random = VideoArtifactRandom(seed: frameIndex ^ 0xF1BE_2D0A_5EED)
        // The coordinator holds this first captured frame for the remainder of a hard loss.
        if parameters.isFrozen {
            return sourceImage
        }
        guard random.unit > parameters.frameDropProbability else {
            return nil
        }
        return sourceImage
    }

    func reset() {
        frameIndex = 0
    }
}

private struct VideoArtifactRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    var unit: Double {
        mutating get {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    var signedUnit: Double {
        mutating get { unit * 2 - 1 }
    }
}
