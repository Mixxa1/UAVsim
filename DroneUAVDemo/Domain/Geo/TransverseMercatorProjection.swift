import Foundation

/// Transverse Mercator projection, in both directions, using the Krüger series.
///
/// Needed because open geodata is very often *not* in latitude/longitude. Finnish national data —
/// including Helsinki's 3D city model and reality mesh — is published in ETRS-GK25 (EPSG:3879),
/// a Gauss-Krüger plane system whose coordinates are metres, not degrees. Loading it without
/// projecting would place the city millions of metres from the origin and silently distort it.
///
/// The Krüger n-series implemented here is accurate to well under a millimetre within a few
/// degrees of the central meridian, which comfortably covers any single-zone national grid. It is
/// not valid far from the central meridian; `GaussKrugerZone` therefore carries its own meridian
/// rather than letting callers reuse one zone's parameters for another's data.
struct TransverseMercatorProjection: Sendable {
    /// Semi-major axis of the reference ellipsoid.
    let semiMajorAxis: Double
    let flattening: Double
    /// Central meridian, degrees.
    let centralMeridianDegrees: Double
    let scaleFactor: Double
    let falseEastingMeters: Double
    let falseNorthingMeters: Double

    // Precomputed series coefficients.
    private let n: Double
    private let rectifyingRadius: Double
    private let alpha: (Double, Double, Double, Double)
    private let beta: (Double, Double, Double, Double)
    private let delta: (Double, Double, Double, Double)

    init(
        semiMajorAxis: Double,
        flattening: Double,
        centralMeridianDegrees: Double,
        scaleFactor: Double,
        falseEastingMeters: Double,
        falseNorthingMeters: Double
    ) {
        self.semiMajorAxis = semiMajorAxis
        self.flattening = flattening
        self.centralMeridianDegrees = centralMeridianDegrees
        self.scaleFactor = scaleFactor
        self.falseEastingMeters = falseEastingMeters
        self.falseNorthingMeters = falseNorthingMeters

        // Third flattening.
        let n = flattening / (2.0 - flattening)
        self.n = n
        let n2 = n * n
        let n3 = n2 * n
        let n4 = n3 * n

        // Radius of the rectifying sphere.
        self.rectifyingRadius = semiMajorAxis / (1.0 + n)
            * (1.0 + n2 / 4.0 + n4 / 64.0)

        // Forward (geodetic → plane) series.
        self.alpha = (
            n / 2.0 - 2.0 * n2 / 3.0 + 5.0 * n3 / 16.0 + 41.0 * n4 / 180.0,
            13.0 * n2 / 48.0 - 3.0 * n3 / 5.0 + 557.0 * n4 / 1440.0,
            61.0 * n3 / 240.0 - 103.0 * n4 / 140.0,
            49561.0 * n4 / 161280.0
        )

        // Inverse (plane → geodetic) series.
        self.beta = (
            n / 2.0 - 2.0 * n2 / 3.0 + 37.0 * n3 / 96.0 - n4 / 360.0,
            n2 / 48.0 + n3 / 15.0 - 437.0 * n4 / 1440.0,
            17.0 * n3 / 480.0 - 37.0 * n4 / 840.0,
            4397.0 * n4 / 161280.0
        )

        // Conformal latitude → geodetic latitude.
        self.delta = (
            2.0 * n - 2.0 * n2 / 3.0 - 2.0 * n3 + 116.0 * n4 / 45.0,
            7.0 * n2 / 3.0 - 8.0 * n3 / 5.0 - 227.0 * n4 / 45.0,
            56.0 * n3 / 15.0 - 136.0 * n4 / 35.0,
            4279.0 * n4 / 630.0
        )
    }

    // MARK: - Geodetic → plane

    func project(
        latitudeDegrees: Double,
        longitudeDegrees: Double
    ) -> (easting: Double, northing: Double) {
        let latitude = latitudeDegrees * .pi / 180.0
        let deltaLongitude = (longitudeDegrees - centralMeridianDegrees) * .pi / 180.0

        let eccentricity = (flattening * (2.0 - flattening)).squareRoot()
        let sinLatitude = sin(latitude)

        // Conformal latitude.
        let t = sinh(
            atanh(sinLatitude)
                - eccentricity * atanh(eccentricity * sinLatitude)
        )
        let xi = atan(t / cos(deltaLongitude))
        let eta = atanh(sin(deltaLongitude) / (1.0 + t * t).squareRoot())

        var xiSum = xi
        var etaSum = eta
        let coefficients = [alpha.0, alpha.1, alpha.2, alpha.3]
        for (index, coefficient) in coefficients.enumerated() {
            let j = Double(index + 1) * 2.0
            xiSum += coefficient * sin(j * xi) * cosh(j * eta)
            etaSum += coefficient * cos(j * xi) * sinh(j * eta)
        }

        return (
            easting: falseEastingMeters + scaleFactor * rectifyingRadius * etaSum,
            northing: falseNorthingMeters + scaleFactor * rectifyingRadius * xiSum
        )
    }

    // MARK: - Plane → geodetic

    func unproject(
        easting: Double,
        northing: Double
    ) -> (latitudeDegrees: Double, longitudeDegrees: Double) {
        let xi = (northing - falseNorthingMeters) / (scaleFactor * rectifyingRadius)
        let eta = (easting - falseEastingMeters) / (scaleFactor * rectifyingRadius)

        var xiPrime = xi
        var etaPrime = eta
        let coefficients = [beta.0, beta.1, beta.2, beta.3]
        for (index, coefficient) in coefficients.enumerated() {
            let j = Double(index + 1) * 2.0
            xiPrime -= coefficient * sin(j * xi) * cosh(j * eta)
            etaPrime -= coefficient * cos(j * xi) * sinh(j * eta)
        }

        // Conformal latitude, then the series back to geodetic latitude.
        let conformalLatitude = asin(
            (sin(xiPrime) / cosh(etaPrime)).clampedToUnitRange()
        )
        var latitude = conformalLatitude
        let latitudeCoefficients = [delta.0, delta.1, delta.2, delta.3]
        for (index, coefficient) in latitudeCoefficients.enumerated() {
            let j = Double(index + 1) * 2.0
            latitude += coefficient * sin(j * conformalLatitude)
        }

        let longitude = centralMeridianDegrees * .pi / 180.0
            + atan(sinh(etaPrime) / cos(xiPrime))

        return (
            latitudeDegrees: latitude * 180.0 / .pi,
            longitudeDegrees: longitude * 180.0 / .pi
        )
    }
}

private extension Double {
    /// `asin` is undefined outside [-1, 1], and rounding in the series above can push the
    /// argument a few ULPs past the boundary at extreme latitudes.
    func clampedToUnitRange() -> Double {
        Swift.min(1.0, Swift.max(-1.0, self))
    }
}

// MARK: - Named national grids

/// Projected coordinate systems this project can read directly, identified by EPSG code.
///
/// Each entry exists because some open-data provider publishes in it. Adding a country's data
/// usually means adding its grid here rather than touching any of the loading code — which is
/// what keeps the importer a constructor rather than a per-city special case.
enum ProjectedCRS: String, Codable, Sendable, CaseIterable {
    /// ETRS89 / GK25FIN — Helsinki and southern Finland. The city's 3D model, reality mesh and
    /// elevation model are all published in this system.
    case etrsGK25FIN = "EPSG:3879"

    var epsgCode: Int {
        switch self {
        case .etrsGK25FIN:
            return 3879
        }
    }

    var projection: TransverseMercatorProjection {
        switch self {
        case .etrsGK25FIN:
            // GRS80 ellipsoid. ETRS89 and WGS84 agree to within a metre at present epoch —
            // they are drifting apart at roughly 2.5 cm/year through plate motion, so the
            // difference is around 0.9 m in 2026. That is below the 20 cm-per-point accuracy
            // claimed for the mesh only in the sense that it is a bulk offset rather than
            // noise; it is recorded here rather than silently ignored, because a datum shift is
            // exactly the sort of thing that is invisible until someone compares a simulated
            // waypoint against a real GNSS fix.
            return TransverseMercatorProjection(
                semiMajorAxis: 6_378_137.0,
                flattening: 1.0 / 298.257222101,
                centralMeridianDegrees: 25.0,
                scaleFactor: 1.0,
                falseEastingMeters: 25_500_000.0,
                falseNorthingMeters: 0.0
            )
        }
    }

    func geographic(easting: Double, northing: Double) -> GeoCoordinate {
        let result = projection.unproject(easting: easting, northing: northing)
        return GeoCoordinate(
            latitudeDegrees: result.latitudeDegrees,
            longitudeDegrees: result.longitudeDegrees
        )
    }

    func projected(_ coordinate: GeoCoordinate) -> (easting: Double, northing: Double) {
        projection.project(
            latitudeDegrees: coordinate.latitudeDegrees,
            longitudeDegrees: coordinate.longitudeDegrees
        )
    }
}
