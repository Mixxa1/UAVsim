import CoreGraphics
import Foundation

/// Barrel distortion for the FPV camera lens, applied to the scene frame before anything is
/// composited on top of it.
///
/// The model is a projection change rather than a hand-tuned polynomial. A rectilinear render
/// places an object at angle `t` at radius `tan(t)`; a fisheye places it at a radius proportional
/// to `t` itself. Converting between those two projections is the entire effect, and it takes one
/// physical parameter — the lens half-angle — plus how far to blend toward it.
///
/// The radius is normalised on the half-diagonal, so the destination corner is radius 1.0 and the
/// frame always stays covered. Normalising on the short axis instead asks for scene beyond the
/// corner of a rectilinear render, which is simply not there and appears as black corners.
///
/// Order matters: on a real aircraft the lens distorts what the sensor sees, while the OSD is
/// drawn afterwards by the flight controller and stays straight. So this runs on the camera frame
/// and the character grid is composited on the result, never through it.
final class FisheyeLensProcessor: @unchecked Sendable {
    /// The remap runs per pixel on the video queue, and the analog path resamples to 720x480
    /// straight afterwards, so there is nothing to gain from warping a full-resolution snapshot.
    private static let maximumWorkingWidth = 1024

    private struct TableKey: Equatable {
        var width: Int
        var height: Int
        var strength: Double
        var halfAngleDegrees: Double
    }

    private var tableKey: TableKey?
    /// Source coordinates per destination pixel, in pixels. Rebuilt only when the shape changes.
    private var sourceX: [Float] = []
    private var sourceY: [Float] = []

    func process(
        sourceImage: CGImage,
        strength: Double,
        halfAngleDegrees: Double
    ) -> CGImage? {
        let clampedStrength = min(1, max(0, strength))
        guard clampedStrength > 0.001 else { return sourceImage }

        let (width, height) = workingSize(for: sourceImage)
        guard width > 1, height > 1 else { return sourceImage }
        let bytesPerRow = width * 4
        var source = [UInt8](repeating: 0, count: height * bytesPerRow)
        let drawn = source.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return sourceImage }

        rebuildTableIfNeeded(
            width: width,
            height: height,
            strength: clampedStrength,
            halfAngleDegrees: halfAngleDegrees
        )

        var destination = [UInt8](repeating: 0, count: height * bytesPerRow)
        source.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                sourceX.withUnsafeBufferPointer { mapX in
                    sourceY.withUnsafeBufferPointer { mapY in
                        remap(
                            source: src,
                            destination: dst,
                            mapX: mapX,
                            mapY: mapY,
                            width: width,
                            height: height
                        )
                    }
                }
            }
        }

        var result: CGImage?
        destination.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return
            }
            result = context.makeImage()
        }
        return result ?? sourceImage
    }

    func reset() {
        tableKey = nil
        sourceX = []
        sourceY = []
    }

    private func workingSize(for image: CGImage) -> (width: Int, height: Int) {
        let width = image.width
        let height = image.height
        guard width > Self.maximumWorkingWidth, width > 0 else {
            return (width, height)
        }
        let scale = Double(Self.maximumWorkingWidth) / Double(width)
        return (Self.maximumWorkingWidth, max(1, Int((Double(height) * scale).rounded())))
    }

    private func rebuildTableIfNeeded(
        width: Int,
        height: Int,
        strength: Double,
        halfAngleDegrees: Double
    ) {
        let key = TableKey(
            width: width,
            height: height,
            strength: strength,
            halfAngleDegrees: halfAngleDegrees
        )
        guard tableKey != key else { return }

        let centerX = Double(width) / 2
        let centerY = Double(height) / 2
        let norm = (centerX * centerX + centerY * centerY).squareRoot()
        let theta = min(max(halfAngleDegrees, 5), 80) * .pi / 180
        let tanTheta = tan(theta)
        var mapX = [Float](repeating: 0, count: width * height)
        var mapY = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let dy = (Double(y) + 0.5 - centerY) / norm
            for x in 0..<width {
                let dx = (Double(x) + 0.5 - centerX) / norm
                let radius = (dx * dx + dy * dy).squareRoot()
                var scale = 1.0
                if radius > 1e-6 {
                    let fisheye = tan(radius * theta) / tanTheta
                    scale = (radius + (fisheye - radius) * strength) / radius
                }
                let index = y * width + x
                mapX[index] = Float(centerX + dx * norm * scale)
                mapY[index] = Float(centerY + dy * norm * scale)
            }
        }
        sourceX = mapX
        sourceY = mapY
        tableKey = key
    }

    private func remap(
        source: UnsafeBufferPointer<UInt8>,
        destination: UnsafeMutableBufferPointer<UInt8>,
        mapX: UnsafeBufferPointer<Float>,
        mapY: UnsafeBufferPointer<Float>,
        width: Int,
        height: Int
    ) {
        let maximumX = Float(width - 2)
        let maximumY = Float(height - 2)
        for index in 0..<(width * height) {
            let sx = mapX[index]
            let sy = mapY[index]
            let out = index * 4
            guard sx >= 0, sy >= 0, sx <= maximumX, sy <= maximumY else {
                destination[out] = 0
                destination[out + 1] = 0
                destination[out + 2] = 0
                destination[out + 3] = 255
                continue
            }
            let x0 = Int(sx)
            let y0 = Int(sy)
            let fx = sx - Float(x0)
            let fy = sy - Float(y0)
            let row0 = (y0 * width + x0) * 4
            let row1 = row0 + width * 4
            for channel in 0..<4 {
                let i00 = Float(source[row0 + channel])
                let i10 = Float(source[row0 + 4 + channel])
                let i01 = Float(source[row1 + channel])
                let i11 = Float(source[row1 + 4 + channel])
                let top = i00 + (i10 - i00) * fx
                let bottom = i01 + (i11 - i01) * fx
                destination[out + channel] = UInt8(max(0, min(255, top + (bottom - top) * fy)))
            }
        }
    }
}
