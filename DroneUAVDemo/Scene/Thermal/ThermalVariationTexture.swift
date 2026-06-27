import AppKit

/// Cached grayscale `multiply` textures that give each surface class real, *stable* internal
/// thermal texture (sampled through the mesh's own UVs). Multi-octave tileable value noise — fine
/// grain plus medium soft patches — so a ground plane or canopy reads like a real thermal surface
/// instead of one flat block, while never being per-frame RGB-noise mash. Values stay in
/// `[low, 1.0]` (multiply can only darken), so brighter areas keep the class temperature and
/// patches read as slightly cooler; `low` deepens as `noiseAmount` rises.
enum ThermalVariationTexture {
    private struct Key: Hashable {
        let cls: ThermalMaterialClass
        let noiseBucket: Int
    }

    private static var cache: [Key: NSImage] = [:]
    private static let size = 256

    static func texture(for cls: ThermalMaterialClass, noiseAmount: Double) -> NSImage? {
        let amount = min(1.0, max(0.0, noiseAmount))
        if amount < 0.02 { return nil }
        let bucket = Int((amount * 20.0).rounded())
        let key = Key(cls: cls, noiseBucket: bucket)
        if let cached = cache[key] { return cached }
        let image = render(cls: cls, noiseAmount: Double(bucket) / 20.0)
        cache[key] = image
        return image
    }

    private static func render(cls: ThermalMaterialClass, noiseAmount: Double) -> NSImage {
        let size = self.size
        // Strong enough that surfaces visibly break up rather than reading as flat colour.
        let low = 1.0 - 0.62 * noiseAmount
        let verticalBias = verticalGradient(for: cls)
        let seed = UInt64(0x7F_AB_C0_DE) &+ UInt64(bitPattern: Int64(cls.hashValue))

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .calibratedWhite,
            bytesPerRow: size,
            bitsPerPixel: 8
        )!
        let data = rep.bitmapData!

        // Octave periods all divide `size` so the texture tiles seamlessly.
        let octaves: [(period: Int, amp: Double)] = [
            (4, 0.50), (8, 0.27), (16, 0.15), (32, 0.08)
        ]

        for y in 0..<size {
            for x in 0..<size {
                var n = 0.0
                for octave in octaves {
                    n += valueNoise(x: x, y: y, period: octave.period, seed: seed) * octave.amp
                }
                // n ≈ [0.15, 0.85]; stretch toward [0,1] then map into [low, 1].
                let stretched = min(1.0, max(0.0, (n - 0.15) / 0.70))
                var v = low + (1.0 - low) * stretched

                if verticalBias > 0.001 {
                    // Cooler toward the top (canopy / upper trunk) on single-mesh asset trees.
                    let topFactor = Double(size - 1 - y) / Double(size - 1)
                    v -= verticalBias * 0.16 * topFactor
                }

                v = min(1.0, max(0.0, v))
                data[y * size + x] = UInt8(v * 255.0)
            }
        }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        image.cacheMode = .always
        return image
    }

    /// Tileable value noise in [0,1] at the given lattice `period` (cells wrap, so edges match).
    private static func valueNoise(x: Int, y: Int, period: Int, seed: UInt64) -> Double {
        let scale = Double(period) / Double(size)
        let fx = Double(x) * scale
        let fy = Double(y) * scale
        let x0 = Int(floor(fx)) % period
        let y0 = Int(floor(fy)) % period
        let x1 = (x0 + 1) % period
        let y1 = (y0 + 1) % period
        let tx = smoothstep(fx - floor(fx))
        let ty = smoothstep(fy - floor(fy))

        let v00 = hash(x0, y0, period: period, seed: seed)
        let v10 = hash(x1, y0, period: period, seed: seed)
        let v01 = hash(x0, y1, period: period, seed: seed)
        let v11 = hash(x1, y1, period: period, seed: seed)

        let top = v00 + (v10 - v00) * tx
        let bottom = v01 + (v11 - v01) * tx
        return top + (bottom - top) * ty
    }

    private static func smoothstep(_ t: Double) -> Double {
        t * t * (3.0 - 2.0 * t)
    }

    private static func hash(_ x: Int, _ y: Int, period: Int, seed: UInt64) -> Double {
        var h = seed
        h = h &+ UInt64(bitPattern: Int64(x &* 374_761_393))
        h = h &+ UInt64(bitPattern: Int64(y &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65535.0
    }

    /// Top-to-bottom cooling baked in for trunks/foliage (no per-vertex thermal data on assets).
    private static func verticalGradient(for cls: ThermalMaterialClass) -> Double {
        switch cls {
        case .treeTrunk: return 0.55
        case .foliage: return 0.45
        case .building, .roof: return 0.25
        default: return 0.0
        }
    }
}
