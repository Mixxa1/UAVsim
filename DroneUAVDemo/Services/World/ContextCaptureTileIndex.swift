import Foundation
import simd

/// Index over a Bentley ContextCapture OBJ export — the format several cities use to publish
/// photogrammetric reality meshes as open data (Helsinki's 2017 mesh among them).
///
/// The export is a quadtree: a node at level `L` covers a square, and its four children at
/// `L+1` cover its quadrants at twice the resolution. That structure is the reason this format
/// is worth targeting at all — the LOD a renderer needs is already baked into the data, so a
/// city can be drawn at full photographic detail underfoot and cheap silhouettes on the horizon
/// without generating anything.
///
/// File layout, per sub-tile directory:
/// ```
/// Tile_+079_+015_L13.obj              level 13, root
/// Tile_+079_+015_L14_0.obj            level 14, child 0
/// Tile_+079_+015_L15_00.obj           level 15, child 0 of child 0
/// …
/// Tile_+079_+015_L21_00022300.obj     level 21, eight levels down
/// ```
/// with a matching `.mtl` and one or more `_N.jpg` textures alongside.
struct ContextCaptureTileIndex {

    /// One quadtree node: a single OBJ with its material and texture.
    struct Node {
        let level: Int
        /// Quadrant path from the root, one digit (0…3) per level below the root. Empty at the
        /// root. Two nodes are ancestor/descendant exactly when one path prefixes the other.
        let quadPath: String
        let objectURL: URL
        let materialURL: URL?
        /// Sub-tile directory this node belongs to, e.g. `671508b1`.
        let group: String
        /// Prefix shared by the node's files, e.g. `Tile_+079_+015`.
        let namePrefix: String

        var isRoot: Bool { quadPath.isEmpty }

        func isAncestor(of other: Node) -> Bool {
            other.level > level && other.quadPath.hasPrefix(quadPath)
        }
    }

    /// Georeferencing declared by the export's `metadata.xml`.
    struct Georeference {
        /// Raw SRS string, e.g. `EPSG:3879+5773` — a compound of a projected horizontal CRS and
        /// a vertical one.
        let rawSRS: String
        /// Offset added to every vertex to recover full projected coordinates. ContextCapture
        /// subtracts it so vertices stay small enough for single precision, which is also why
        /// the simulator can keep them in `Float` once re-anchored to its own origin.
        let originEasting: Double
        let originNorthing: Double
        let originHeight: Double

        /// Horizontal CRS parsed out of the compound string, when recognised.
        var horizontalCRS: ProjectedCRS? {
            let horizontal = rawSRS.split(separator: "+").first.map(String.init) ?? rawSRS
            return ProjectedCRS(rawValue: horizontal.trimmingCharacters(in: .whitespaces))
        }
    }

    let rootURL: URL
    let georeference: Georeference
    let nodes: [Node]

    /// Human-readable CRS resolution result, for diagnostics: an unrecognised projected system
    /// means the tile cannot be georeferenced and must be reported rather than silently placed
    /// at the origin.
    var horizontalCRSDescription: String {
        georeference.horizontalCRS.map { "\($0.rawValue) (EPSG:\($0.epsgCode))" }
            ?? "unrecognised: \(georeference.rawSRS)"
    }

    var levelRange: ClosedRange<Int> {
        let levels = nodes.map(\.level)
        return (levels.min() ?? 0)...(levels.max() ?? 0)
    }

    // MARK: - Loading

    enum IndexError: LocalizedError {
        case missingMetadata(URL)
        case unreadableMetadata(String)
        case noTiles(URL)

        var errorDescription: String? {
            switch self {
            case .missingMetadata(let url):
                return L10n.f("world.mesh.error.metadata", url.lastPathComponent)
            case .unreadableMetadata(let detail):
                return L10n.f("world.mesh.error.metadata_parse", detail)
            case .noTiles(let url):
                return L10n.f("world.mesh.error.no_tiles", url.lastPathComponent)
            }
        }
    }

    /// Scans an extracted tile directory. Cheap — it reads file names and one small XML, never
    /// any geometry, so a multi-gigabyte tile can be indexed instantly and loaded on demand.
    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        self.georeference = try Self.readGeoreference(rootURL: rootURL, fileManager: fileManager)

        var nodes: [Node] = []
        let groups = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for groupURL in groups {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: groupURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let files = (try? fileManager.contentsOfDirectory(
                at: groupURL,
                includingPropertiesForKeys: nil
            )) ?? []

            for fileURL in files where fileURL.pathExtension.lowercased() == "obj" {
                guard let parsed = Self.parseNodeName(fileURL.deletingPathExtension().lastPathComponent)
                else { continue }
                let materialURL = fileURL.deletingPathExtension().appendingPathExtension("mtl")
                nodes.append(
                    Node(
                        level: parsed.level,
                        quadPath: parsed.quadPath,
                        objectURL: fileURL,
                        materialURL: fileManager.fileExists(atPath: materialURL.path)
                            ? materialURL
                            : nil,
                        group: groupURL.lastPathComponent,
                        namePrefix: parsed.prefix
                    )
                )
            }
        }

        guard !nodes.isEmpty else { throw IndexError.noTiles(rootURL) }
        self.nodes = nodes
    }

    /// `Tile_+079_+015_L21_00022300` → level 21, path "00022300".
    /// `Tile_+055_+000_L13` → level 13, empty path (a root node).
    static func parseNodeName(_ name: String) -> (prefix: String, level: Int, quadPath: String)? {
        // Find the `_L<digits>` marker; everything before it is the tile prefix, everything
        // after the level (and an underscore) is the quadrant path.
        guard let range = name.range(of: "_L", options: .backwards) else { return nil }
        let prefix = String(name[name.startIndex..<range.lowerBound])
        let remainder = name[range.upperBound...]

        let levelDigits = remainder.prefix { $0.isNumber }
        guard !levelDigits.isEmpty, let level = Int(levelDigits) else { return nil }

        var quadPath = String(remainder.dropFirst(levelDigits.count))
        if quadPath.hasPrefix("_") { quadPath.removeFirst() }
        // Anything that is not a quadrant digit means this is not a geometry node (a texture's
        // `_0` suffix, for instance, is stripped before this is called).
        guard quadPath.allSatisfy({ ("0"..."3").contains(String($0)) }) else { return nil }

        return (prefix, level, quadPath)
    }

    private static func readGeoreference(
        rootURL: URL,
        fileManager: FileManager
    ) throws -> Georeference {
        let metadataURL = rootURL.appendingPathComponent("metadata.xml")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw IndexError.missingMetadata(metadataURL)
        }
        guard let text = try? String(contentsOf: metadataURL, encoding: .utf8) else {
            throw IndexError.unreadableMetadata(metadataURL.lastPathComponent)
        }

        func value(of tag: String) -> String? {
            guard let start = text.range(of: "<\(tag)>"),
                  let end = text.range(of: "</\(tag)>"),
                  start.upperBound <= end.lowerBound else {
                return nil
            }
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let srs = value(of: "SRS") else {
            throw IndexError.unreadableMetadata("SRS")
        }
        // `SRSOrigin` is a comma-separated triple; without it every vertex is metres from an
        // unknown point and the tile cannot be georeferenced at all.
        guard let originText = value(of: "SRSOrigin") else {
            throw IndexError.unreadableMetadata("SRSOrigin")
        }
        let parts = originText.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count >= 2 else {
            throw IndexError.unreadableMetadata("SRSOrigin=\(originText)")
        }

        return Georeference(
            rawSRS: srs,
            originEasting: parts[0],
            originNorthing: parts[1],
            originHeight: parts.count > 2 ? parts[2] : 0.0
        )
    }

    // MARK: - Selection

    /// The coarsest complete covering of the tile — every root node, one per sub-tile directory.
    /// Useful as a cheap first draw while finer levels stream in.
    func rootNodes() -> [Node] {
        var lowestByGroup: [String: Node] = [:]
        for node in nodes {
            let key = "\(node.group)/\(node.namePrefix)"
            if let existing = lowestByGroup[key], existing.level <= node.level { continue }
            lowestByGroup[key] = node
        }
        return Array(lowestByGroup.values)
    }

    /// Every node at exactly `level`. Loading a single level gives a uniform-detail model, which
    /// is the simplest thing that can work and the right way to measure cost per level before
    /// wiring distance-based switching.
    func nodes(atLevel level: Int) -> [Node] {
        nodes.filter { $0.level == level }
    }

    /// Nodes forming a complete covering at `level`, falling back to the deepest available
    /// ancestor where the quadtree does not reach that deep. Sparse areas (water, forest) stop
    /// subdividing early, so asking for level 21 everywhere would leave holes.
    func covering(level: Int) -> [Node] {
        var byKey: [String: [Node]] = [:]
        for node in nodes {
            byKey["\(node.group)/\(node.namePrefix)", default: []].append(node)
        }

        var result: [Node] = []
        for (_, group) in byKey {
            // Leaves of the subtree pruned at `level`: a node is selected when it is at or below
            // the requested level and has no child that is also at or below it.
            let candidates = group.filter { $0.level <= level }
            let selected = candidates.filter { candidate in
                !candidates.contains { other in
                    other.level > candidate.level && candidate.isAncestor(of: other)
                }
            }
            result.append(contentsOf: selected)
        }
        return result
    }
}
