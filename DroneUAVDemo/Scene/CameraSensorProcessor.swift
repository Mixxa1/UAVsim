import Accelerate
import CoreGraphics
import Foundation

/// How a camera renders colour. Separate from the thermal path: a long-wave core already gets its
/// look from the thermal scene render, so forcing grey on top of it would destroy the palette.
enum CameraColorRendering: String, Hashable, Sendable {
    /// Ordinary colour, or whatever the scene render already produced (thermal included).
    case native
    /// A multispectral head records discrete narrow bands and previews one at a time. What comes
    /// off it is a single-band greyscale image, not an RGB picture.
    case narrowBand
}

/// What a specific camera does to the picture, independent of the radio link carrying it.
///
/// Field of view already came from the module's optics, but that alone left every camera looking
/// identical: a 640x512 thermal core and a 42 MP full-frame produced the same crisp, clean frame.
/// These are the properties that actually separate them by eye, and each is read straight off the
/// module rather than chosen as a "look".
struct CameraSensorParameters: Equatable, Sendable {
    /// Which device this is. Everything else here changes while the same camera keeps running —
    /// zoom moves the coverage, the lens toggle moves the bow — and only a genuine change of
    /// camera should restart the exposure loop.
    var cameraIdentity: String
    /// The sensor's own pixel count. Detail beyond it cannot exist in the feed.
    var horizontalResolution: Int
    var verticalResolution: Int
    /// Relative luminance noise at base sensitivity, 0...1. Small pixels are noisier.
    var noise: Double
    /// Stops of dynamic range. Fewer stops clip highlights sooner.
    var dynamicRangeStops: Double
    var colorRendering: CameraColorRendering
    /// How far the lens departs from rectilinear at the current focal length, 0...1.
    var barrelDistortion: Double
    /// Half-angle the frame currently covers, degrees — the lens remap needs the coverage it is
    /// bending, and that changes with zoom.
    var lensHalfAngleDegrees: Double
    /// Time the sensor takes to read the frame out, seconds. Zero for a global shutter, which
    /// exposes every line at once and therefore cannot skew.
    var rollingShutterReadoutSeconds: Double
    var autoExposure: CameraAutoExposure
    var color: CameraColorResponse

    static let clean = CameraSensorParameters(
        cameraIdentity: "",
        horizontalResolution: .max,
        verticalResolution: .max,
        noise: 0,
        dynamicRangeStops: 20,
        colorRendering: .native,
        barrelDistortion: 0,
        lensHalfAngleDegrees: 30,
        rollingShutterReadoutSeconds: 0,
        autoExposure: .manual,
        color: .neutral
    )

    /// Whether this camera departs from a clean render enough to be worth a pass. The lens runs
    /// inside the same pass, so its bow counts too.
    ///
    /// The thresholds are deliberately not zero: a camera that clears all of them is shown as the
    /// untouched render, which is both the correct look for good glass and sharper than anything
    /// routed through the working buffer. Rolling shutter is not on this list — its lean is worth
    /// applying to a frame already being processed, but not worth resampling a clean frame for.
    var requiresProcessing: Bool {
        horizontalResolution < 2560
            || noise > 0.06
            || dynamicRangeStops < 13.0
            || colorRendering != .native
            || requiresLensPass
            || autoExposure.gainUpStops + autoExposure.gainDownStops > 0.01
            || color != .neutral
    }

    /// Whether the barrel bow is worth remapping for. The remap works at its own resolution, so
    /// running it for a bow nobody can see costs sharpness and buys nothing.
    var requiresLensPass: Bool {
        barrelDistortion > 0.06
    }
}

/// Applies a camera module's sensor and ISP characteristics to a rendered frame.
///
/// The pass follows the order the real chain runs in: light lands on the sensor grid, the readout
/// skews it and adds its own noise, the ISP applies a colour matrix, then detail enhancement, then
/// exposure gain, white balance and the tone curve. Doing exposure before noise, for instance,
/// would hide the most characteristic thing a camera does — gaining up in the dark makes its noise
/// worse, and that is why a small-pixel camera falls apart in shade and a full-frame does not.
///
/// The per-channel stages run through Accelerate. Written as a scalar loop they cost 11 ms on a
/// 1.7 Mpx frame, which forced the working buffer down to a resolution that visibly softened every
/// camera equally and undid the point of modelling sensor resolution at all.
final class CameraSensorProcessor: @unchecked Sendable {
    /// Cap on the working buffer. Generous, because the expensive stages are now vectorised and
    /// the sensor's own resolution is usually the tighter limit anyway.
    private static let maximumWorkingWidth = 2048
    /// A whip-pan must not tear the frame in half. Real skew is a few pixels; this only stops the
    /// model running away when the gimbal is slewed hard.
    private static let maximumSkewFraction = 0.06

    /// Where the auto-exposure loop currently sits, as a linear gain. Carried between frames — the
    /// whole point of the loop is that it takes time to get there.
    private var exposureGain: Double = 1

    private var workingBuffer: [UInt8] = []
    /// Only used when the sensor out-resolves nothing — that is, when the feed has to be scaled up
    /// from the sensor grid to the display.
    private var matrixBuffer: [UInt8] = []
    /// Tone curves, one per colour channel: exposure gain, white balance, black lift and the
    /// highlight roll-off composed into a single 256-entry lookup.
    private var toneRed = [UInt8](repeating: 0, count: 256)
    private var toneGreen = [UInt8](repeating: 0, count: 256)
    private var toneBlue = [UInt8](repeating: 0, count: 256)
    private var toneAlpha = [UInt8](repeating: 0, count: 256)

    init() {
        for index in 0..<256 {
            toneAlpha[index] = UInt8(index)
        }
    }

    func reset() {
        exposureGain = 1
    }

    func process(
        sourceImage: CGImage,
        parameters: CameraSensorParameters,
        yawRateRadiansPerSecond: Double,
        deltaTime: Double,
        frameIndex: UInt64
    ) -> CGImage? {
        guard parameters.requiresProcessing else { return sourceImage }

        // Two separate size limits, and conflating them was wrong: the working buffer is a cost
        // cap, while the sensor's own pixel count is a real ceiling on how much detail the feed can
        // carry. Running everything at the sensor size made a 42 MP full-frame come out no sharper
        // than a 1.2 MP FPV camera.
        let aspect = Double(sourceImage.height) / Double(max(1, sourceImage.width))
        let costLimitedWidth = max(32, min(Self.maximumWorkingWidth, max(1, sourceImage.width)))
        let costLimitedHeight = max(24, Int((Double(costLimitedWidth) * aspect).rounded()))

        // Everything the camera does happens on its own grid: the readout skews sensor lines, noise
        // is generated at the photosite, and the ISP sharpens what the sensor gave it.
        //
        // The finished frame is then handed over at that resolution and scaled once, by the view.
        // It used to be resampled up to the display width first, with no smoothing — but that ratio
        // is rarely a whole number (1920 into 2048 is 1.067x), so nearest-neighbour there did not
        // show "the pixels it has", it duplicated an irregular one column in fifteen and then let
        // the view resample the result again. Two extra resamples, both pure loss, and a visible
        // part of why the picture read as soft.
        let sensorLimited = parameters.horizontalResolution < costLimitedWidth
        let width = sensorLimited ? max(16, parameters.horizontalResolution) : costLimitedWidth
        let height = sensorLimited
            ? max(12, min(
                max(1, parameters.verticalResolution),
                Int((Double(width) * aspect).rounded())
            ))
            : costLimitedHeight

        guard draw(
            sourceImage,
            into: &workingBuffer,
            width: width,
            height: height,
            // The one resample the pass owns, so it is worth filtering properly: Core Graphics
            // costs a fraction of a millisecond here next to the per-pixel work that follows.
            interpolation: .high
        ) else {
            return sourceImage
        }

        applyRollingShutter(
            width: width,
            height: height,
            parameters: parameters,
            yawRateRadiansPerSecond: yawRateRadiansPerSecond
        )
        applyNoise(
            to: &workingBuffer,
            width: width,
            height: height,
            amount: parameters.noise,
            frameIndex: frameIndex
        )

        // Metered before any gain is applied, so the loop is measuring the light rather than its
        // own previous correction.
        updateAutoExposure(
            pixels: workingBuffer,
            width: width,
            height: height,
            parameters: parameters,
            deltaTime: deltaTime
        )

        applyColorMatrix(width: width, height: height, parameters: parameters)
        applyToneCurves(width: width, height: height, parameters: parameters)
        // Sharpening last, as an ISP does it: on the finished picture, at sensor resolution.
        applyEdgeEnhancement(width: width, height: height, amount: parameters.color.edgeEnhancement)

        return makeImage(from: &workingBuffer, width: width, height: height) ?? sourceImage
    }

    // MARK: - Buffers

    private func draw(
        _ image: CGImage,
        into buffer: inout [UInt8],
        width: Int,
        height: Int,
        interpolation: CGInterpolationQuality
    ) -> Bool {
        let bytesPerRow = width * 4
        let count = height * bytesPerRow
        if buffer.count != count {
            buffer = [UInt8](repeating: 0, count: count)
        }
        return buffer.withUnsafeMutableBytes { raw -> Bool in
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
            context.interpolationQuality = interpolation
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
    }

    private func makeImage(from buffer: inout [UInt8], width: Int, height: Int) -> CGImage? {
        buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return nil
            }
            return context.makeImage()
        }
    }

    // MARK: - Sensor readout

    /// A rolling shutter reads the frame line by line, so every line sees the scene from a slightly
    /// different camera heading. Panning therefore leans vertical edges over. A global shutter
    /// exposes the whole frame at once and skips this entirely.
    private func applyRollingShutter(
        width: Int,
        height: Int,
        parameters: CameraSensorParameters,
        yawRateRadiansPerSecond: Double
    ) {
        let readout = parameters.rollingShutterReadoutSeconds
        guard readout > 0.0001, height > 1 else { return }
        let halfAngle = max(1.0, parameters.lensHalfAngleDegrees) * .pi / 180.0
        // Pixels per radian across the frame, from the coverage the frame actually has.
        let pixelsPerRadian = Double(width) / (2 * halfAngle)
        let span = -yawRateRadiansPerSecond * readout * pixelsPerRadian
        let limit = Double(width) * Self.maximumSkewFraction
        let clampedSpan = min(limit, max(-limit, span))
        guard abs(clampedSpan) >= 0.5 else { return }

        let bytesPerRow = width * 4
        workingBuffer.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for y in 0..<height {
                // Bitmap row 0 is the bottom of the image, and a sensor reads the top line first —
                // so the bottom row is the one read last. Phase is measured from the middle of the
                // readout, which makes this a pure shear: taken from the first line instead, the
                // whole frame also slid sideways by half the span, and that slide jumped about with
                // the rate estimate rather than leaning the picture.
                let readPhase = 0.5 - Double(y) / Double(height - 1)
                let shift = Int((clampedSpan * readPhase).rounded())
                guard shift != 0, abs(shift) < width else { continue }
                let row = base + y * bytesPerRow
                // Every pixel in a row moves by the same amount, so the row is one block move and
                // the edge it uncovers is filled by repeating the pixel it ran off.
                if shift > 0 {
                    let kept = width - shift
                    memmove(row, row + shift * 4, kept * 4)
                    for x in kept..<width {
                        memcpy(row + x * 4, row + (kept - 1) * 4, 4)
                    }
                } else {
                    let gap = -shift
                    let kept = width - gap
                    memmove(row + gap * 4, row, kept * 4)
                    for x in 0..<gap {
                        memcpy(row + x * 4, row + gap * 4, 4)
                    }
                }
            }
        }
    }

    /// Sensor noise, added on the sensor's own grid and before any gain — so that a camera forced
    /// to gain up in shade shows the noise it gained up with.
    private func applyNoise(
        to pixels: inout [UInt8],
        width: Int,
        height: Int,
        amount: Double,
        frameIndex: UInt64
    ) {
        // `noise` is the sensor's figure at base sensitivity, so this scale is what it looks like
        // in good light. It stays low on purpose: the noise goes in ahead of the exposure gain, so
        // a camera forced to gain up in shade amplifies it on its own, which is where a small
        // sensor actually falls apart. Scaling it for the dark case instead made bright daylight
        // look like a broken feed.
        let amplitude = min(1.0, max(0.0, amount)) * 22.0
        guard amplitude > 0.5 else { return }
        // Fixed point, and a shift rather than a divide. The divide that used to be here cost more
        // than every other stage of the pass put together.
        let scale = Int32((amplitude * 2).rounded())

        // ⚠️ The noise cannot be larger than the signal it sits on. Applied flat, the negative half
        // of the distribution was clamped away at zero and the mean rose with it — +26 % on a
        // signal of 3/255 and +56 % on 2/255, which is exactly where a night ground sits. That
        // lift, not the exposure loop, was what kept black from being black.
        //
        // The guard is deliberately *only* a guard. An earlier attempt scaled the amplitude by the
        // square root of the level, on the grounds that shot noise grows that way — true in linear
        // light, but these values are gamma-encoded, and carrying the same shot noise through the
        // encoding leaves it very nearly flat across the range. That version made a bright daylight
        // frame about a third noisier than it had been, for no physical reason. Midtones and
        // highlights are therefore left exactly as they were, and only levels the clamp would
        // actually bite into are held back.
        //
        // A real sensor solves the same problem with its black level, which is why a composite
        // camera has a pedestal at all: it keeps the noise off the clip.
        var levelScale = [Int32](repeating: 0, count: 256)
        for level in 0..<256 {
            let headroom = min(1.0, Double(level) / max(1.0, amplitude))
            levelScale[level] = Int32((Double(scale) * headroom).rounded())
        }

        var state = frameIndex &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
        let count = width * height
        pixels.withUnsafeMutableBufferPointer { buffer in
        levelScale.withUnsafeBufferPointer { levels in
            for pixel in 0..<count {
                let index = pixel * 4
                state = state &* 6364136223846793005 &+ 1442695040888963407
                // One luminance-correlated sample per pixel: sensor noise is not three independent
                // colour channels dancing separately.
                let sample = Int32(truncatingIfNeeded: state >> 56) - 128
                // Green carries most of the luminance, so it stands in for the signal level.
                let offset = (sample &* levels[Int(buffer[index + 1])]) >> 8
                buffer[index] = clampByte(Int32(buffer[index]) &+ offset)
                buffer[index + 1] = clampByte(Int32(buffer[index + 1]) &+ offset)
                buffer[index + 2] = clampByte(Int32(buffer[index + 2]) &+ offset)
            }
        }
        }
    }



    // MARK: - Auto exposure

    /// Meters the frame and walks the exposure gain toward what the metering asks for.
    ///
    /// Closed loop on the delivered picture: the gain that would land the measured mean on the
    /// camera's target is the goal, the camera's own range decides how much of it is reachable, and
    /// its response time decides how long getting there takes. A camera whose range runs out stays
    /// blown, or stays dark, which is what happens on the real thing.
    private func updateAutoExposure(
        pixels: [UInt8],
        width: Int,
        height: Int,
        parameters: CameraSensorParameters,
        deltaTime: Double
    ) {
        let settings = parameters.autoExposure
        guard settings.gainUpStops + settings.gainDownStops > 0.01 else {
            exposureGain = 1
            return
        }

        // Centre-weighted, and subsampled: metering does not need every pixel, and this runs on
        // every delivered frame.
        var weighted = 0.0
        var weight = 0.0
        let step = max(1, min(width, height) / 96)
        let centreX = Double(width - 1) * 0.5
        let centreY = Double(height - 1) * 0.5
        let radius = max(1.0, (centreX * centreX + centreY * centreY).squareRoot())
        pixels.withUnsafeBufferPointer { source in
            var y = 0
            while y < height {
                var x = 0
                let dy = (Double(y) - centreY) / radius
                while x < width {
                    let index = (y * width + x) * 4
                    let luma = 0.2126 * Double(source[index])
                        + 0.7152 * Double(source[index + 1])
                        + 0.0722 * Double(source[index + 2])
                    let dx = (Double(x) - centreX) / radius
                    let w = 1.0 - 0.65 * min(1.0, (dx * dx + dy * dy).squareRoot())
                    weighted += luma / 255.0 * w
                    weight += w
                    x += step
                }
                y += step
            }
        }
        guard weight > 0 else { return }
        let measured = max(0.004, weighted / weight)

        // A rendered frame is already a correctly exposed picture. A loop that drives every frame
        // to a fixed mid-grey therefore *re-exposes* it, and in ordinary daylight that came out as
        // a flat, dull image where the camera had quietly pulled the whole scene down toward 42 %
        // grey for no reason. Real metering has a dead band for the same reason: a camera that is
        // close enough does not hunt. Outside the band the loop pulls only as far as its edge.
        let floorLevel = settings.targetLevel * 0.62
        let ceilingLevel = settings.targetLevel * 1.55
        let desired: Double
        if measured < floorLevel {
            desired = floorLevel / measured
        } else if measured > ceilingLevel {
            desired = ceilingLevel / measured
        } else {
            desired = 1
        }
        let target = min(
            pow(2.0, settings.gainUpStops),
            max(1.0 / pow(2.0, settings.gainDownStops), desired)
        )
        // First-order lag, framed in real time so the loop behaves the same however often frames
        // are delivered.
        let tau = max(0.02, settings.responseSeconds)
        let alpha = deltaTime > 0 ? 1 - exp(-deltaTime / tau) : 1
        exposureGain += (target - exposureGain) * alpha
    }

    // MARK: - ISP

    /// The colour matrix: chroma gain, or the single-band collapse of a multispectral head. Both
    /// are cross-channel, which is exactly what a matrix is for.
    private func applyColorMatrix(
        width: Int,
        height: Int,
        parameters: CameraSensorParameters
    ) {
        let narrowBand = parameters.colorRendering == .narrowBand
        // Colour is the first thing a camera loses in the dark: chroma signal-to-noise falls with
        // sensitivity, and an ISP answers by cutting chroma gain rather than amplifying colour
        // noise along with the picture. Without this, a night scene the exposure loop had gained up
        // came out as saturated daylight.
        let chromaRetention = Float(max(0.35, 1.0 / (1.0 + max(0, exposureGain - 1) * 0.35)))
        let saturation = Double(chromaRetention) * parameters.color.saturation
        guard narrowBand || abs(saturation - 1) > 0.001 else { return }

        // Column-major by source channel, in the buffer's own RGBA order: entry [4*j + i] is the
        // contribution of source channel j to destination channel i. Verified against a scalar
        // reference in Tools rather than trusted from the header.
        let divisor: Int32 = 4096
        var matrix = [Int16](repeating: 0, count: 16)
        if narrowBand {
            // One band at a time is what the head delivers. The red band is the one these cameras
            // are flown for, and the only one this render can honestly supply — there is no
            // near-infrared in the scene to invent a vegetation index from.
            for destination in 0..<3 {
                matrix[destination] = Int16(divisor)
            }
        } else {
            let luma = [0.2126, 0.7152, 0.0722]
            for source in 0..<3 {
                for destination in 0..<3 {
                    let identity = source == destination ? 1.0 : 0.0
                    let value = luma[source] + (identity - luma[source]) * saturation
                    matrix[4 * source + destination] = Int16((value * Double(divisor)).rounded())
                }
            }
        }
        matrix[15] = Int16(divisor)   // alpha passes through

        let bytesPerRow = width * 4
        if matrixBuffer.count != workingBuffer.count {
            matrixBuffer = [UInt8](repeating: 0, count: workingBuffer.count)
        }
        workingBuffer.withUnsafeMutableBufferPointer { source in
            matrixBuffer.withUnsafeMutableBufferPointer { destination in
                var input = vImage_Buffer(
                    data: source.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var output = vImage_Buffer(
                    data: destination.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                _ = matrix.withUnsafeBufferPointer { coefficients in
                    vImageMatrixMultiply_ARGB8888(
                        &input,
                        &output,
                        coefficients.baseAddress!,
                        divisor,
                        nil,
                        nil,
                        vImage_Flags(kvImageNoFlags)
                    )
                }
            }
        }
        swap(&workingBuffer, &matrixBuffer)
    }

    /// Edge enhancement: the detail the ISP puts back after its own low-pass. Analog FPV cameras
    /// sharpen hard, a thermal core's detail enhancement does the same to its AGC output, and a
    /// stills camera barely touches it.
    private func applyEdgeEnhancement(width: Int, height: Int, amount: Double) {
        guard amount > 0.02, width > 2, height > 2 else { return }

        // out = (1 + a)*in - a*blur, with the blur being the usual 1-2-1 kernel. Written out as a
        // single 3x3 whose taps sum to the divisor, so the average brightness is untouched and only
        // the detail the blur would have removed is put back.
        //
        // vImage convolves each channel independently rather than luma only, which is what a real
        // ISP sharpens. On a near-neutral picture the difference is not visible, and three separate
        // planar passes over a full frame cost several times what this one call does.
        let scaled = Int16((amount * 256).rounded())
        let centre = Int16(4096 + 12 * Int(scaled))
        let kernel: [Int16] = [
            -scaled, -2 * scaled, -scaled,
            -2 * scaled, centre, -2 * scaled,
            -scaled, -2 * scaled, -scaled,
        ]

        let bytesPerRow = width * 4
        if matrixBuffer.count != workingBuffer.count {
            matrixBuffer = [UInt8](repeating: 0, count: workingBuffer.count)
        }
        workingBuffer.withUnsafeMutableBufferPointer { source in
            matrixBuffer.withUnsafeMutableBufferPointer { destination in
                var input = vImage_Buffer(
                    data: source.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var output = vImage_Buffer(
                    data: destination.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                _ = kernel.withUnsafeBufferPointer { taps in
                    vImageConvolve_ARGB8888(
                        &input,
                        &output,
                        nil,
                        0,
                        0,
                        taps.baseAddress!,
                        3,
                        3,
                        4096,
                        nil,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }
        swap(&workingBuffer, &matrixBuffer)
    }

    /// Exposure gain, white balance, black lift and the highlight roll-off, composed into one
    /// lookup per channel. All four are per-channel scalar functions, so there is no reason to
    /// evaluate them per pixel — and composing them in float means the gain never clips on its way
    /// into the tone curve.
    private func applyToneCurves(
        width: Int,
        height: Int,
        parameters: CameraSensorParameters
    ) {
        let color = parameters.color
        let gain = Float(exposureGain)
        // Warm bias lifts red and drops blue; green is the reference, as it is in any
        // white-balance gain pair. A narrow-band feed has no colour left to balance.
        let neutral = parameters.colorRendering == .narrowBand
        let redGain = neutral ? 1 : Float(1.0 + color.whiteBalanceBias * 0.40)
        let blueGain = neutral ? 1 : Float(1.0 - color.whiteBalanceBias * 0.40)
        let lift = Float(color.blackLift)
        let liftScale = 1 - lift

        // A narrow-latitude sensor runs out of headroom early, so bright sky and sunlit surfaces
        // compress together instead of holding separation.
        let stops = max(4.0, min(20.0, parameters.dynamicRangeStops))
        let knee = Float(min(0.98, 0.42 + (stops - 4.0) / 16.0 * 0.52))
        let headroom = max(0.0001, 1 - knee)
        let normaliser = Float(1.0 - exp(-2.2))

        func curve(_ channelGain: Float, into table: inout [UInt8]) {
            for index in 0..<256 {
                var value = Float(index) * (1.0 / 255.0) * gain * channelGain
                value = lift + value * liftScale
                if value > knee {
                    value = knee + headroom * (1 - expf(-2.2 * (value - knee) / headroom)) / normaliser
                }
                table[index] = UInt8(max(0, min(255, (value * 255).rounded())))
            }
        }
        curve(redGain, into: &toneRed)
        curve(1, into: &toneGreen)
        curve(blueGain, into: &toneBlue)

        let bytesPerRow = width * 4
        workingBuffer.withUnsafeMutableBufferPointer { pixels in
            var buffer = vImage_Buffer(
                data: pixels.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            // The ARGB8888 name is positional, not a claim about channel order: the four tables are
            // applied to buffer channels 0...3, which here are R, G, B and A.
            toneRed.withUnsafeBufferPointer { red in
                toneGreen.withUnsafeBufferPointer { green in
                    toneBlue.withUnsafeBufferPointer { blue in
                        toneAlpha.withUnsafeBufferPointer { alpha in
                            _ = vImageTableLookUp_ARGB8888(
                                &buffer,
                                &buffer,
                                red.baseAddress!,
                                green.baseAddress!,
                                blue.baseAddress!,
                                alpha.baseAddress!,
                                vImage_Flags(kvImageNoFlags)
                            )
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private func clampByte(_ value: Int32) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }
}

extension CameraChannelSpec {
    /// Video readout time for a rolling shutter, seconds. Manufacturers do not publish this, so one
    /// representative video-mode figure is used for every rolling-shutter head rather than a
    /// per-module invention; a global shutter has none by definition.
    private static let rollingShutterReadoutSeconds = 1.0 / 60.0

    /// Sensor behaviour of this channel at the current zoom setting.
    ///
    /// Zoom matters here because barrel distortion belongs to the wide end of a lens: a 34x turret
    /// racked all the way in is effectively rectilinear, and bowing that frame would be wrong.
    func sensorParameters(
        identity: String,
        zoomLevel: Double,
        currentFieldOfViewDegrees: Double
    ) -> CameraSensorParameters {
        let zoom = max(1.0, zoomLevel)
        return CameraSensorParameters(
            cameraIdentity: identity,
            horizontalResolution: horizontalResolution,
            verticalResolution: verticalResolution,
            noise: baseNoise,
            dynamicRangeStops: dynamicRangeStops,
            colorRendering: spectrum == .multispectral ? .narrowBand : .native,
            barrelDistortion: barrelDistortion / zoom,
            lensHalfAngleDegrees: max(1.0, currentFieldOfViewDegrees) / 2,
            rollingShutterReadoutSeconds: shutter == .rolling
                ? Self.rollingShutterReadoutSeconds
                : 0,
            autoExposure: autoExposure,
            color: colorResponse
        )
    }
}
