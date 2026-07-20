import Foundation
import simd

/// The anchor that ties the simulator's local metre-space to the real Earth.
///
/// Local simulation coordinates follow the convention already canonical in this project (see
/// `MissionLaunchGeometry`): **+X = east, +Y = up, +Z = north**. That maps onto a geodetic
/// east-north-up tangent plane with no axis flips and no sign corrections — a rare piece of luck
/// worth stating explicitly, because a silent sign error here rotates an entire imported city.
///
/// The tangent-plane approximation is exact at the origin and degrades with distance as the
/// plane departs from the curved surface. The error is ~0.8 cm at 1 km, ~2 m at 16 km and ~78 m
/// at 100 km, so it is irrelevant for the tile sizes this simulator loads and would only matter
/// for a world spanning hundreds of kilometres. `planarErrorMeters(atRangeMeters:)` reports it
/// rather than leaving the limit implicit.
struct GeoOrigin: Codable, Hashable, Sendable {
    /// Where local (0, 0, 0) sits on Earth. Local Y is measured up from this point's MSL
    /// altitude, so an origin placed at the terrain's launch elevation makes local Y read as
    /// height above launch — which is what the existing physics and HUD already assume.
    let coordinate: GeoCoordinate

    /// Height of the geoid (MSL datum) above the WGS84 ellipsoid at this location, in metres.
    /// Negative across most of the continental US — about -32 m around New York. Stored per
    /// world rather than computed, because doing it properly needs an EGM96/EGM2008 grid, and a
    /// single constant is exact enough over one tile while being honest about what it is.
    let geoidSeparationMeters: Double

    // Cached tangent-plane trigonometry. Recomputing sin/cos of the origin latitude and
    // longitude on every conversion would be wasteful when this runs per waypoint, per building
    // vertex on import, and potentially per telemetry sample.
    private let sinLatitude: Double
    private let cosLatitude: Double
    private let sinLongitude: Double
    private let cosLongitude: Double
    private let originECEF: ECEFPosition

    private enum CodingKeys: String, CodingKey {
        case coordinate
        case geoidSeparationMeters
    }

    init(
        coordinate: GeoCoordinate,
        geoidSeparationMeters: Double = 0.0
    ) {
        self.coordinate = coordinate
        self.geoidSeparationMeters = geoidSeparationMeters

        let latitudeRadians = coordinate.latitudeRadians
        let longitudeRadians = coordinate.longitudeRadians
        self.sinLatitude = sin(latitudeRadians)
        self.cosLatitude = cos(latitudeRadians)
        self.sinLongitude = sin(longitudeRadians)
        self.cosLongitude = cos(longitudeRadians)
        self.originECEF = ECEFPosition.fromGeodetic(
            latitudeRadians: latitudeRadians,
            longitudeRadians: longitudeRadians,
            heightMeters: coordinate.altitudeMetersMSL + geoidSeparationMeters
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let coordinate = try container.decode(GeoCoordinate.self, forKey: .coordinate)
        let separation = try container.decodeIfPresent(
            Double.self,
            forKey: .geoidSeparationMeters
        ) ?? 0.0
        self.init(coordinate: coordinate, geoidSeparationMeters: separation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coordinate, forKey: .coordinate)
        try container.encode(geoidSeparationMeters, forKey: .geoidSeparationMeters)
    }

    // MARK: - Geographic → local

    /// Full-precision conversion. Returns local metres as `Double`; use `localPosition(of:)` for
    /// the `SIMD3<Float>` the scene and physics work in.
    func localMeters(of coordinate: GeoCoordinate) -> SIMD3<Double> {
        localMeters(
            latitudeRadians: coordinate.latitudeRadians,
            longitudeRadians: coordinate.longitudeRadians,
            altitudeMetersMSL: coordinate.altitudeMetersMSL
        )
    }

    func localMeters(
        latitudeRadians: Double,
        longitudeRadians: Double,
        altitudeMetersMSL: Double
    ) -> SIMD3<Double> {
        let target = ECEFPosition.fromGeodetic(
            latitudeRadians: latitudeRadians,
            longitudeRadians: longitudeRadians,
            heightMeters: altitudeMetersMSL + geoidSeparationMeters
        )
        let dx = target.x - originECEF.x
        let dy = target.y - originECEF.y
        let dz = target.z - originECEF.z

        let east = -sinLongitude * dx + cosLongitude * dy
        let north = -sinLatitude * cosLongitude * dx
            - sinLatitude * sinLongitude * dy
            + cosLatitude * dz
        let up = cosLatitude * cosLongitude * dx
            + cosLatitude * sinLongitude * dy
            + sinLatitude * dz

        // East → +X, up → +Y, north → +Z.
        return SIMD3<Double>(east, up, north)
    }

    /// Simulation-space position, in the units and axis convention the scene graph uses.
    func localPosition(of coordinate: GeoCoordinate) -> SIMD3<Float> {
        let meters = localMeters(of: coordinate)
        return SIMD3<Float>(Float(meters.x), Float(meters.y), Float(meters.z))
    }

    // MARK: - Local → geographic

    func geographic(ofLocalMeters localMeters: SIMD3<Double>) -> GeoCoordinate {
        let east = localMeters.x
        let up = localMeters.y
        let north = localMeters.z

        // Transpose of the ENU rotation applied above.
        let dx = -sinLongitude * east
            - sinLatitude * cosLongitude * north
            + cosLatitude * cosLongitude * up
        let dy = cosLongitude * east
            - sinLatitude * sinLongitude * north
            + cosLatitude * sinLongitude * up
        let dz = cosLatitude * north + sinLatitude * up

        let target = ECEFPosition(
            x: originECEF.x + dx,
            y: originECEF.y + dy,
            z: originECEF.z + dz
        )
        let geodetic = target.toGeodetic()

        return GeoCoordinate(
            latitudeDegrees: geodetic.latitudeRadians * 180.0 / .pi,
            longitudeDegrees: geodetic.longitudeRadians * 180.0 / .pi,
            altitudeMetersMSL: geodetic.heightMeters - geoidSeparationMeters
        )
    }

    /// The conversion the telemetry, replay and geotagging paths call: sim position in, real
    /// GPS fix out.
    func geographic(ofLocalPosition position: SIMD3<Float>) -> GeoCoordinate {
        geographic(
            ofLocalMeters: SIMD3<Double>(
                Double(position.x),
                Double(position.y),
                Double(position.z)
            )
        )
    }

    // MARK: - Diagnostics

    /// Horizontal error introduced by treating the tangent plane as flat, at a given range from
    /// the origin. Exposed so world-authoring code can warn when a requested region is large
    /// enough for the approximation to matter instead of discovering it as drift.
    func planarErrorMeters(atRangeMeters range: Double) -> Double {
        guard range > 0.0 else { return 0.0 }
        let earthRadius = WGS84.semiMajorAxis
        return range * range / (2.0 * earthRadius)
    }
}
