import AppKit
import SceneKit

/// Resolves the **real** diffuse texture of a scene material into a grayscale luminance image
/// usable as a `multiply` channel on a thermal proxy. This is what makes thermal "texture-aware":
/// the actual bark / leaf / asphalt / building detail modulates the (correct, class-derived)
/// thermal colour instead of every surface being a flat block.
///
/// Every real `.usdz` model in this project stores its texture as a `URL` of the form
/// `file://….usdz?offset=N&size=M` (a byte range into the uncompressed usdz) — `NSImage(contentsOf:)`
/// fails on it (the query string), so the bytes are read directly via `FileHandle` (verified: the
/// embedded files are stored uncompressed and byte-range-addressable; the read yields a decodable
/// JPEG/PNG). Results are cached by URL string (SceneKit hands each cloned instance a distinct URL
/// *value* pointing at the same bytes, so identity caching would never hit).
enum ThermalRealTexture {
    private static var cache: [String: NSImage?] = [:]
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Grayscale luminance image (compressed to ~[0.5, 1.0] so it only shades) for the material's
    /// diffuse, or nil if the material has no real texture (flat `NSColor`).
    static func luminance(for diffuse: SCNMaterialProperty?) -> NSImage? {
        guard let diffuse else { return nil }

        switch diffuse.contents {
        case let url as URL:
            return luminanceFromURL(url)
        case let nsURL as NSURL:
            return luminanceFromURL(nsURL as URL)
        case let image as NSImage:
            return cached(key: "img:\(ObjectIdentifier(image))") { compress(ciImage(from: image)) }
        default:
            // NSColor / nil / anything else → no texture detail to show.
            return nil
        }
    }

    private static func luminanceFromURL(_ url: URL) -> NSImage? {
        cached(key: url.absoluteString) {
            guard let data = embeddedTextureData(for: url),
                  let ci = CIImage(data: data) else {
                return nil
            }
            return compress(ci)
        }
    }

    private static func cached(key: String, _ make: () -> NSImage?) -> NSImage? {
        if let hit = cache[key] { return hit }
        let result = make()
        cache[key] = result
        return result
    }

    /// Read the embedded texture bytes from a `…usdz?offset=N&size=M` URL.
    private static func embeddedTextureData(for url: URL) -> Data? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              let offStr = items.first(where: { $0.name == "offset" })?.value,
              let szStr = items.first(where: { $0.name == "size" })?.value,
              let offset = Int(offStr), let size = Int(szStr), size > 0 else {
            // No byte-range query — try a plain read as a fallback.
            return try? Data(contentsOf: URL(fileURLWithPath: url.path))
        }

        let bareURL = URL(fileURLWithPath: url.path)
        guard let handle = try? FileHandle(forReadingFrom: bareURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return nil
        }
        let data = handle.readData(ofLength: size)
        return data.isEmpty ? nil : data
    }

    private static func ciImage(from image: NSImage) -> CIImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return CIImage(cgImage: cg)
    }

    /// Desaturate to luminance and compress the range to ~[0.5, 1.0] so, used as a multiply, it
    /// only ever *shades* the thermal colour with the texture pattern (never blows past it).
    private static func compress(_ input: CIImage?) -> NSImage? {
        guard let input else { return nil }

        guard let mono = CIFilter(name: "CIColorControls") else { return nil }
        mono.setValue(input, forKey: kCIInputImageKey)
        mono.setValue(0.0, forKey: kCIInputSaturationKey)
        mono.setValue(1.05, forKey: kCIInputContrastKey)
        guard let desaturated = mono.outputImage else { return nil }

        guard let matrix = CIFilter(name: "CIColorMatrix") else { return nil }
        matrix.setValue(desaturated, forKey: kCIInputImageKey)
        let s: CGFloat = 0.5  // scale
        let b: CGFloat = 0.5  // bias → output in [0.5, 1.0]
        matrix.setValue(CIVector(x: s, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: s, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: s, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: b, y: b, z: b, w: 0), forKey: "inputBiasVector")
        guard let output = matrix.outputImage else { return nil }

        let extent = output.extent.isInfinite ? input.extent : output.extent
        guard !extent.isInfinite,
              let cg = ciContext.createCGImage(output, from: extent) else {
            return nil
        }
        return NSImage(cgImage: cg, size: extent.size)
    }
}
