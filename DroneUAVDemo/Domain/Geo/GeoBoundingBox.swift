import Foundation
import simd

/// An axis-aligned latitude/longitude rectangle — how a user picks the patch of the real world
/// to turn into a flyable map, and how the importer bounds every source query.
///
/// Deliberately *not* antimeridian-aware. A box that wraps ±180° would silently invert every
/// containment test, so `init` rejects it outright rather than producing a world with its
/// contents mirrored. Regions that genuinely straddle the antimeridian (Fiji, Chukotka) need a
/// split-box representation; that is a real limitation, recorded here rather than discovered in
/// the field.
struct GeoBoundingBox: Codable, Hashable, Sendable {
    let minimumLatitudeDegrees: Double
    let minimumLongitudeDegrees: Double
    let maximumLatitudeDegrees: Double
    let maximumLongitudeDegrees: Double

    init?(
        minimumLatitudeDegrees: Double,
        minimumLongitudeDegrees: Double,
        maximumLatitudeDegrees: Double,
        maximumLongitudeDegrees: Double
    ) {
        guard minimumLatitudeDegrees.isFinite, maximumLatitudeDegrees.isFinite,
              minimumLongitudeDegrees.isFinite, maximumLongitudeDegrees.isFinite else {
            return nil
        }
        guard minimumLatitudeDegrees < maximumLatitudeDegrees,
              minimumLongitudeDegrees < maximumLongitudeDegrees else {
            return nil
        }
        guard (-90.0...90.0).contains(minimumLatitudeDegrees),
              (-90.0...90.0).contains(maximumLatitudeDegrees),
              (-180.0...180.0).contains(minimumLongitudeDegrees),
              (-180.0...180.0).contains(maximumLongitudeDegrees) else {
            return nil
        }
        self.minimumLatitudeDegrees = minimumLatitudeDegrees
        self.minimumLongitudeDegrees = minimumLongitudeDegrees
        self.maximumLatitudeDegrees = maximumLatitudeDegrees
        self.maximumLongitudeDegrees = maximumLongitudeDegrees
    }

    /// The usual authoring entry point: "give me a square of N metres centred here".
    ///
    /// The longitude half-width is divided by cos(latitude), so the result is square *in metres*
    /// rather than in degrees — at New York's latitude a naive equal-degree box would come out
    /// about 24% narrower east-west than it is tall.
    init?(center: GeoCoordinate, sideLengthMeters: Double) {
        guard center.isPlausible, sideLengthMeters > 0.0 else { return nil }

        let halfSide = sideLengthMeters * 0.5
        let latitudeRadians = center.latitudeRadians
        let sinLatitude = sin(latitudeRadians)
        let denominator = pow(1.0 - WGS84.eccentricitySquared * sinLatitude * sinLatitude, 1.5)
        let meridionalRadius =
            WGS84.semiMajorAxis * (1.0 - WGS84.eccentricitySquared) / denominator
        let primeVertical = WGS84.primeVerticalRadius(latitudeRadians: latitudeRadians)

        let latitudeSpan = (halfSide / meridionalRadius) * 180.0 / .pi
        let cosLatitude = max(cos(latitudeRadians), 1e-9)
        let longitudeSpan = (halfSide / (primeVertical * cosLatitude)) * 180.0 / .pi

        self.init(
            minimumLatitudeDegrees: center.latitudeDegrees - latitudeSpan,
            minimumLongitudeDegrees: center.longitudeDegrees - longitudeSpan,
            maximumLatitudeDegrees: center.latitudeDegrees + latitudeSpan,
            maximumLongitudeDegrees: center.longitudeDegrees + longitudeSpan
        )
    }

    var centerCoordinate: GeoCoordinate {
        GeoCoordinate(
            latitudeDegrees: (minimumLatitudeDegrees + maximumLatitudeDegrees) * 0.5,
            longitudeDegrees: (minimumLongitudeDegrees + maximumLongitudeDegrees) * 0.5
        )
    }

    func contains(_ coordinate: GeoCoordinate) -> Bool {
        coordinate.latitudeDegrees >= minimumLatitudeDegrees
            && coordinate.latitudeDegrees <= maximumLatitudeDegrees
            && coordinate.longitudeDegrees >= minimumLongitudeDegrees
            && coordinate.longitudeDegrees <= maximumLongitudeDegrees
    }

    /// Grown by a margin in metres. Used to over-fetch source data slightly past the playable
    /// area so buildings straddling the edge are not clipped in half.
    func expanded(byMeters margin: Double) -> GeoBoundingBox {
        guard margin > 0.0 else { return self }
        let center = centerCoordinate
        let latitudeRadians = center.latitudeRadians
        let primeVertical = WGS84.primeVerticalRadius(latitudeRadians: latitudeRadians)
        let latitudeSpan = (margin / primeVertical) * 180.0 / .pi
        let cosLatitude = max(cos(latitudeRadians), 1e-9)
        let longitudeSpan = (margin / (primeVertical * cosLatitude)) * 180.0 / .pi

        return GeoBoundingBox(
            minimumLatitudeDegrees: max(-90.0, minimumLatitudeDegrees - latitudeSpan),
            minimumLongitudeDegrees: max(-180.0, minimumLongitudeDegrees - longitudeSpan),
            maximumLatitudeDegrees: min(90.0, maximumLatitudeDegrees + latitudeSpan),
            maximumLongitudeDegrees: min(180.0, maximumLongitudeDegrees + longitudeSpan)
        ) ?? self
    }

    /// Approximate ground dimensions, for UI ("2.0 × 2.0 км") and for sanity-checking that a
    /// requested region is not so large the tangent-plane approximation starts to bend it.
    func approximateSizeMeters() -> (width: Double, height: Double) {
        let center = centerCoordinate
        let origin = GeoOrigin(coordinate: center)
        let southWest = origin.localMeters(
            of: GeoCoordinate(
                latitudeDegrees: minimumLatitudeDegrees,
                longitudeDegrees: minimumLongitudeDegrees
            )
        )
        let northEast = origin.localMeters(
            of: GeoCoordinate(
                latitudeDegrees: maximumLatitudeDegrees,
                longitudeDegrees: maximumLongitudeDegrees
            )
        )
        return (abs(northEast.x - southWest.x), abs(northEast.z - southWest.z))
    }

    /// Local-metre extent relative to a given origin, as (minXZ, maxXZ). The scene needs this to
    /// size ground geometry and to bound the spatial index.
    func localExtent(relativeTo origin: GeoOrigin) -> (minimum: SIMD2<Double>, maximum: SIMD2<Double>) {
        // All four corners, because the tangent-plane projection does not keep a lat/lon
        // rectangle perfectly axis-aligned in local metres.
        let corners = [
            (minimumLatitudeDegrees, minimumLongitudeDegrees),
            (minimumLatitudeDegrees, maximumLongitudeDegrees),
            (maximumLatitudeDegrees, minimumLongitudeDegrees),
            (maximumLatitudeDegrees, maximumLongitudeDegrees)
        ].map { latitude, longitude in
            origin.localMeters(
                of: GeoCoordinate(latitudeDegrees: latitude, longitudeDegrees: longitude)
            )
        }

        var minimum = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maximum = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for corner in corners {
            minimum.x = min(minimum.x, corner.x)
            minimum.y = min(minimum.y, corner.z)
            maximum.x = max(maximum.x, corner.x)
            maximum.y = max(maximum.y, corner.z)
        }
        return (minimum, maximum)
    }

    /// Overpass and most OGC services want `south,west,north,east`.
    var overpassBoundsString: String {
        String(
            format: "%.7f,%.7f,%.7f,%.7f",
            minimumLatitudeDegrees,
            minimumLongitudeDegrees,
            maximumLatitudeDegrees,
            maximumLongitudeDegrees
        )
    }
}
