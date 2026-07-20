import Foundation

/// A point on the real Earth, in the terms an operator and an autopilot both speak.
///
/// Altitude is **mean sea level**, not the ellipsoidal height GNSS receivers report natively —
/// that's the number shown on a GCS, printed on a chart and used by mission planners, so it is
/// the one the simulator treats as canonical. The conversion to ellipsoidal height happens in
/// `GeoOrigin`, which carries the local geoid separation.
///
/// All geodesy in this project runs in `Double`. That is not a style preference: ECEF magnitudes
/// are ~6.4e6 m, and `Float`'s ~7 significant digits leave roughly metre-scale quantisation
/// before any local maths even begins. `Float` appears only after the value has been reduced to
/// local metres near the origin, where it is precise again.
struct GeoCoordinate: Codable, Hashable, Sendable {
    var latitudeDegrees: Double
    var longitudeDegrees: Double
    var altitudeMetersMSL: Double

    init(
        latitudeDegrees: Double,
        longitudeDegrees: Double,
        altitudeMetersMSL: Double = 0.0
    ) {
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.altitudeMetersMSL = altitudeMetersMSL
    }

    var latitudeRadians: Double { latitudeDegrees * .pi / 180.0 }
    var longitudeRadians: Double { longitudeDegrees * .pi / 180.0 }

    /// `true` when the pair is a usable fix rather than a default-initialised or corrupt record.
    /// The null island check is deliberate — (0, 0) is the single most common signature of a
    /// dropped or unparsed coordinate, and silently building a world there wastes a lot of time.
    var isPlausible: Bool {
        guard latitudeDegrees.isFinite, longitudeDegrees.isFinite, altitudeMetersMSL.isFinite else {
            return false
        }
        guard (-90.0...90.0).contains(latitudeDegrees),
              (-180.0...180.0).contains(longitudeDegrees) else {
            return false
        }
        return abs(latitudeDegrees) > 0.000001 || abs(longitudeDegrees) > 0.000001
    }

    /// Formatted the way a GCS shows a waypoint: six decimals is ~0.1 m, finer than any source
    /// dataset this simulator imports.
    var displayString: String {
        let latHemisphere = latitudeDegrees >= 0.0 ? "N" : "S"
        let lonHemisphere = longitudeDegrees >= 0.0 ? "E" : "W"
        return String(
            format: "%.6f°%@ %.6f°%@",
            abs(latitudeDegrees),
            latHemisphere,
            abs(longitudeDegrees),
            lonHemisphere
        )
    }
}

/// WGS84 reference ellipsoid — the datum every source this project imports is expressed in
/// (OSM, national open-data portals, GNSS itself), so no datum shift is needed on import.
enum WGS84 {
    /// Semi-major axis.
    static let semiMajorAxis: Double = 6_378_137.0
    static let flattening: Double = 1.0 / 298.257223563
    /// Semi-minor axis.
    static let semiMinorAxis: Double = semiMajorAxis * (1.0 - flattening)
    /// First eccentricity squared.
    static let eccentricitySquared: Double = flattening * (2.0 - flattening)
    /// Second eccentricity squared, used by Bowring's closed-form inverse.
    static let secondEccentricitySquared: Double =
        (semiMajorAxis * semiMajorAxis - semiMinorAxis * semiMinorAxis) /
        (semiMinorAxis * semiMinorAxis)

    /// Radius of curvature in the prime vertical at the given latitude.
    static func primeVerticalRadius(latitudeRadians: Double) -> Double {
        let sinLatitude = sin(latitudeRadians)
        return semiMajorAxis / (1.0 - eccentricitySquared * sinLatitude * sinLatitude).squareRoot()
    }
}

/// Earth-centred, Earth-fixed cartesian position in metres. An intermediate representation only —
/// geodetic coordinates go in, local tangent-plane metres come out, and this sits between them.
struct ECEFPosition: Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Geodetic → ECEF. `heightMeters` is height above the *ellipsoid*, not MSL; callers holding
    /// a `GeoCoordinate` should go through `GeoOrigin`, which applies geoid separation first.
    static func fromGeodetic(
        latitudeRadians: Double,
        longitudeRadians: Double,
        heightMeters: Double
    ) -> ECEFPosition {
        let sinLatitude = sin(latitudeRadians)
        let cosLatitude = cos(latitudeRadians)
        let sinLongitude = sin(longitudeRadians)
        let cosLongitude = cos(longitudeRadians)
        let primeVertical = WGS84.primeVerticalRadius(latitudeRadians: latitudeRadians)

        return ECEFPosition(
            x: (primeVertical + heightMeters) * cosLatitude * cosLongitude,
            y: (primeVertical + heightMeters) * cosLatitude * sinLongitude,
            z: (primeVertical * (1.0 - WGS84.eccentricitySquared) + heightMeters) * sinLatitude
        )
    }

    /// ECEF → geodetic via Bowring's closed-form solution. Accurate to well under a millimetre
    /// for any altitude a UAV will ever occupy, and unlike the naive fixed-point iteration it
    /// needs no convergence loop, so it is safe to call per simulation tick.
    func toGeodetic() -> (latitudeRadians: Double, longitudeRadians: Double, heightMeters: Double) {
        let distanceFromAxis = (x * x + y * y).squareRoot()
        let longitudeRadians = atan2(y, x)

        // Degenerate case: exactly on the polar axis, where `atan2` below has no meaningful
        // argument and `cos(latitude)` is zero, which would divide by zero in the height step.
        guard distanceFromAxis > 1e-9 else {
            let latitudeRadians = z >= 0.0 ? Double.pi / 2.0 : -Double.pi / 2.0
            let heightMeters = abs(z) - WGS84.semiMinorAxis
            return (latitudeRadians, longitudeRadians, heightMeters)
        }

        let parametricLatitude = atan2(
            z * WGS84.semiMajorAxis,
            distanceFromAxis * WGS84.semiMinorAxis
        )
        let sinParametric = sin(parametricLatitude)
        let cosParametric = cos(parametricLatitude)

        let latitudeRadians = atan2(
            z + WGS84.secondEccentricitySquared * WGS84.semiMinorAxis *
                sinParametric * sinParametric * sinParametric,
            distanceFromAxis - WGS84.eccentricitySquared * WGS84.semiMajorAxis *
                cosParametric * cosParametric * cosParametric
        )

        let primeVertical = WGS84.primeVerticalRadius(latitudeRadians: latitudeRadians)
        let heightMeters = distanceFromAxis / cos(latitudeRadians) - primeVertical

        return (latitudeRadians, longitudeRadians, heightMeters)
    }
}
