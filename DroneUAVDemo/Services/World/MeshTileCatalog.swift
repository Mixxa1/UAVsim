import Foundation
import simd

/// A publisher of photogrammetric mesh tiles, described generically enough that adding another
/// city means adding a value here rather than new code.
struct MeshTileSource: Sendable {
    let identifier: String
    let displayName: String
    let attribution: UAVWorldAttribution
    /// Browsable directory index listing the tile archives.
    let listingURL: URL
    /// Coordinate system the tiles are georeferenced in.
    let crs: ProjectedCRS
    /// Side length of one tile, in metres.
    let tileSideMeters: Double
    /// Regular expression capturing (filename, tile key) from the directory listing.
    let filePattern: String
    /// Vintage of the imagery, shown to the user — a 2017 survey has 2017's buildings, cars and
    /// ships permanently baked into it.
    let captureYear: Int

    /// Helsinki's 2017 reality mesh: aerial photogrammetry, ~7.5 cm ground sample distance,
    /// stated 20 cm dimensional accuracy, published under CC BY 4.0 with a directly browsable
    /// download index — no API key, no interactive picker, no terms forbidding offline use.
    static let helsinki2017 = MeshTileSource(
        identifier: "helsinki-2017-mesh",
        displayName: "Helsinki 3D — reality mesh 2017",
        attribution: UAVWorldAttribution(
            datasetIdentifier: "helsinki-3d-mesh-2017",
            displayName: "City of Helsinki",
            license: "CC BY 4.0",
            sourceURL: "https://hri.fi/data/en_GB/dataset/helsingin-3d-kaupunkimalli"
        ),
        // HTTPS, not the plain HTTP the publisher's own index links use: App Transport Security
        // blocks unencrypted connections outright, and the host serves the identical listing over
        // TLS, so this is a straight fix rather than a reason to weaken the app's ATS policy.
        listingURL: URL(
            string: "https://3d.hel.ninja/data/mesh/Helsinki3D-MESH_2017_OBJ_2km-250m_ZIP/"
        )!,
        crs: .etrsGK25FIN,
        tileSideMeters: 2000,
        filePattern: #"(Helsinki3D_2017_OBJ_(\d{6})x2\.zip)"#,
        captureYear: 2017
    )

    func downloadURL(forKey key: String) -> URL {
        listingURL.appendingPathComponent("Helsinki3D_2017_OBJ_\(key)x2.zip")
    }

    /// Tile keys encode position as `<northing_km><easting_km>`, each three digits.
    ///
    /// Decoded from the data rather than documentation: tile `670508` was measured to span
    /// easting 25,508,000–25,509,750 and northing 6,670,500–6,672,000, which fixes both halves.
    func projectedOrigin(forKey key: String) -> (easting: Double, northing: Double)? {
        guard key.count == 6,
              let northingKilometres = Double(key.prefix(3)),
              let eastingKilometres = Double(key.suffix(3)) else {
            return nil
        }
        // The easting key omits the leading "25" of the zone-prefixed false easting.
        return (
            easting: 25_000_000 + eastingKilometres * 1_000,
            northing: northingKilometres * 1_000 + 6_000_000
        )
    }
}

/// One downloadable tile, with everything the user needs to decide whether they want it.
struct MeshTileDescriptor: Identifiable, Sendable {
    let key: String
    let downloadURL: URL
    let compressedBytes: Int64
    let centerCoordinate: GeoCoordinate
    let sideMeters: Double

    var id: String { key }

    /// Extraction ratio measured on the central Helsinki tile: 1.85 GB archived became 4.5 GB on
    /// disk. Stated as an estimate because it varies with how much of a tile is water.
    var estimatedExtractedBytes: Int64 {
        Int64(Double(compressedBytes) * 2.45)
    }

    var totalDiskBytes: Int64 {
        compressedBytes + estimatedExtractedBytes
    }

    func distanceMeters(to coordinate: GeoCoordinate) -> Double {
        let origin = GeoOrigin(coordinate: coordinate)
        let local = origin.localMeters(of: centerCoordinate)
        let east: Double = local.x
        let north: Double = local.z
        return (east * east + north * north).squareRoot()
    }
}

/// Reads a mesh publisher's directory index.
///
/// Deliberately a plain HTTP directory listing rather than an API: that is what the data is
/// actually served from, and it means the catalogue is always whatever the publisher currently
/// has rather than a list baked into this app that silently goes stale.
struct MeshTileCatalog {

    enum CatalogError: LocalizedError {
        case unreachable(String)
        case unreadableListing
        case empty

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail):
                return L10n.f("world.mesh.catalog.error.unreachable", detail)
            case .unreadableListing:
                return L10n.s("world.mesh.catalog.error.unreadable")
            case .empty:
                return L10n.s("world.mesh.catalog.error.empty")
            }
        }
    }

    let source: MeshTileSource
    private let session: URLSession

    init(source: MeshTileSource, session: URLSession = .shared) {
        self.source = source
        self.session = session
    }

    func fetch() async throws -> [MeshTileDescriptor] {
        var request = URLRequest(url: source.listingURL)
        request.timeoutInterval = 45
        request.setValue("UAVsim/1.0 (flight simulator world importer)", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            let (payload, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw CatalogError.unreachable("HTTP \(http.statusCode)")
            }
            data = payload
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.unreachable(error.localizedDescription)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw CatalogError.unreadableListing
        }

        let descriptors = Self.parse(listing: html, source: source)
        guard !descriptors.isEmpty else { throw CatalogError.empty }
        return descriptors
    }

    /// Extracts tile names and byte sizes from an nginx/Apache-style index.
    ///
    /// The size is the point of the whole exercise — a user asked to approve a download is owed
    /// the actual number, and these range from 4 MB for open water to 3.4 GB for dense centre.
    static func parse(listing html: String, source: MeshTileSource) -> [MeshTileDescriptor] {
        guard let fileRegex = try? NSRegularExpression(pattern: source.filePattern) else {
            return []
        }

        var result: [MeshTileDescriptor] = []
        html.enumerateLines { line, _ in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = fileRegex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 3,
                  let keyRange = Range(match.range(at: 2), in: line) else {
                return
            }
            let key = String(line[keyRange])

            // The byte size is the run of digits at the very end of the line. Digits only — an
            // earlier version also accepted spaces while scanning backwards, which jumped the
            // column gap and swallowed the minutes off the timestamp ("37␣␣␣10895783"), so every
            // line failed to parse.
            let trailingDigits = line.reversed().prefix { $0.isNumber }
            let sizeText = String(trailingDigits.reversed())
            guard let bytes = Int64(sizeText), bytes > 0 else { return }

            guard let origin = source.projectedOrigin(forKey: key) else { return }
            let centerEasting = origin.easting + source.tileSideMeters * 0.5
            let centerNorthing = origin.northing + source.tileSideMeters * 0.5
            let center = source.crs.geographic(
                easting: centerEasting,
                northing: centerNorthing
            )

            result.append(
                MeshTileDescriptor(
                    key: key,
                    downloadURL: source.downloadURL(forKey: key),
                    compressedBytes: bytes,
                    centerCoordinate: center,
                    sideMeters: source.tileSideMeters
                )
            )
        }
        return result
    }
}

// MARK: - Formatting

extension Int64 {
    /// Sizes shown to the user before they approve a download. Uses decimal GB, matching how
    /// storage and bandwidth are normally quoted.
    var formattedByteSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: self)
    }
}
