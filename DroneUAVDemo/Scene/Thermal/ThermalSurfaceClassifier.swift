import SceneKit
import AppKit

/// Classifies an `SCNNode` / `SCNMaterial` into a `ThermalMaterialClass` from identity (node,
/// geometry, material, diffuse-texture names) with a colour fallback. Results are name-keyed and
/// cached by the renderer — this never samples pixels per frame, and never mutates anything.
///
/// Any node can force a class with `node.userData["thermalClass"] = "foliage"` (etc.).
enum ThermalSurfaceClassifier {

    /// Explicit per-node override via `userData["thermalClass"]`. SceneKit's `userData` isn't
    /// surfaced as a Swift property in this SDK, so it's read through KVC.
    static func override(for node: SCNNode) -> ThermalMaterialClass? {
        guard let userData = node.value(forKey: "userData") as? NSDictionary,
              let raw = userData["thermalClass"] as? String else {
            return nil
        }
        return ThermalMaterialClass(rawValue: raw)
    }

    /// Best-effort class from a node and its geometry/material identity.
    /// `contextHint` lets the caller bias an unnamed sub-mesh (e.g. a tree's foliage).
    static func classify(
        node: SCNNode,
        contextHint: ThermalMaterialClass? = nil
    ) -> ThermalMaterialClass {
        if let forced = override(for: node) {
            return forced
        }

        var tokens: [String] = []
        if let name = node.name { tokens.append(name) }
        if let geometry = node.geometry {
            if let gName = geometry.name { tokens.append(gName) }
            for material in geometry.materials {
                if let mName = material.name { tokens.append(mName) }
                if let texName = textureName(material.diffuse.contents) { tokens.append(texName) }
            }
        }

        for token in tokens {
            if let cls = classifyToken(token) {
                return cls
            }
        }

        if let hint = contextHint {
            return hint
        }

        if let geometry = node.geometry,
           let color = dominantColor(geometry.firstMaterial?.diffuse.contents),
           let byColor = classifyByColor(color) {
            return byColor
        }

        return contextHint ?? .generic
    }

    /// Keyword match against a single identity token. Order matters: more specific first.
    static func classifyToken(_ raw: String) -> ThermalMaterialClass? {
        let s = raw.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }

        // Vegetation must be checked before generic ground words.
        if has("trunk", "bark", "stem") { return .treeTrunk }
        if has("leaf", "leaves", "foliage", "canopy", "crown", "needle", "pine", "fir", "spruce") { return .foliage }
        if has("tree") { return .foliage }

        if has("snow_patch", "snow_footstep", "snowfall", "snow") { return .snow }
        if has("ice", "frost", "glacier") { return .ice }
        // "sea" deliberately excluded: a bare 3-letter substring collides with real, unrelated
        // assets in this project — "seaCargoContainer"/"Sea_cargo_container_...usdz" (a metal
        // shipping container, confirmed misclassified as water) and "Seamless_Brittle_Stone.usdz"
        // (the city's concrete texture, "**Sea**mless"). No real water asset exists in this
        // project (verified by search), so dropping it loses nothing.
        if has("water", "lake", "river", "ocean", "pond", "puddle") { return .water }

        if has("roof", "rooftop") { return .roof }
        if has("road", "asphalt", "street", "tarmac", "pavement") { return .asphalt }
        if has("concrete", "cement", "brittle_stone", "brittle stone") { return .concrete }
        if has("glass", "window") { return .glass }
        if has("metal", "steel", "aluminum", "aluminium", "container", "cargo", "crate", "pole", "pylon", "antenna") { return .metal }
        if has("building", "house", "wall", "facade", "structure", "tower", "hangar", "shed", "abandoned") { return .building }

        if has("rock", "stone", "boulder", "cliff", "mountain", "hill") { return .rock }
        if has("soil", "dirt", "mud", "bare") { return .bareSoil }
        if has("grass", "field", "meadow", "lawn", "turf", "vegetation") { return .grass }
        if has("ground", "terrain", "dock", "deck") { return .terrain }

        if has("sky", "cloud", "horizon") { return .sky }
        if has("shadow") { return .shadow }

        return nil
    }

    private static func textureName(_ contents: Any?) -> String? {
        switch contents {
        case let url as URL:
            return url.lastPathComponent
        case let nsURL as NSURL:
            return nsURL.lastPathComponent
        case let image as NSImage:
            return image.name()
        case let string as String:
            return string
        default:
            return nil
        }
    }

    private static func dominantColor(_ contents: Any?) -> NSColor? {
        contents as? NSColor
    }

    /// Weak colour fallback for genuinely unnamed flat-colour materials. Class still wins when a
    /// name matched — this only fires when nothing else did.
    private static func classifyByColor(_ color: NSColor) -> ThermalMaterialClass? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))

        // Strongly green → vegetation.
        if g > 0.30 && g >= r * 1.18 && g >= b * 1.18 { return .grass }
        // Near-white / very bright + low saturation → snow-like.
        if minC > 0.78 && (maxC - minC) < 0.12 { return .snow }
        // Strongly blue → water.
        if b > 0.32 && b >= r * 1.2 && b >= g * 1.05 { return .water }
        // Dark, desaturated → asphalt/road-ish.
        if maxC < 0.30 && (maxC - minC) < 0.12 { return .asphalt }
        return nil
    }
}
