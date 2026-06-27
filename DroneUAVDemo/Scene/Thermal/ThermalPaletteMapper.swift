import AppKit

/// Maps a temperature (via the shared display range) to a palette colour. The palette only
/// decides presentation — normalization + the temperature model decide *what* is hot/cold.
enum ThermalPaletteMapper {

    /// Normalize a temperature to 0...1 across the display range, with contrast/brightness and a
    /// gentle filmic tone curve (keeps mid-tone detail instead of hard-clamping).
    static func normalized(
        temperatureCelsius: Double,
        displayMin: Double,
        displayMax: Double,
        contrast: Double,
        brightness: Double
    ) -> Double {
        let span = max(0.5, displayMax - displayMin)
        var t = (temperatureCelsius - displayMin) / span
        t = min(1.0, max(0.0, t))

        // Contrast around mid-grey, then brightness offset.
        t = (t - 0.5) * contrast + 0.5 + brightness
        t = min(1.0, max(0.0, t))

        // Soft S-curve so extremes don't crush.
        return t * t * (3.0 - 2.0 * t)
    }

    static func color(
        forNormalized value: Double,
        palette: ThermalPalette
    ) -> NSColor {
        let t = min(1.0, max(0.0, value))
        switch palette {
        case .whiteHot:
            let g = 0.03 + 0.95 * t
            return NSColor(calibratedRed: CGFloat(g), green: CGFloat(g), blue: CGFloat(g), alpha: 1.0)
        case .blackHot:
            let g = 0.98 - 0.95 * t
            return NSColor(calibratedRed: CGFloat(g), green: CGFloat(g), blue: CGFloat(g), alpha: 1.0)
        case .iron:
            let c = ironRamp(t)
            return NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: 1.0)
        }
    }

    static func color(
        forTemperature temperatureCelsius: Double,
        displayMin: Double,
        displayMax: Double,
        palette: ThermalPalette,
        contrast: Double,
        brightness: Double
    ) -> NSColor {
        let n = normalized(
            temperatureCelsius: temperatureCelsius,
            displayMin: displayMin,
            displayMax: displayMax,
            contrast: contrast,
            brightness: brightness
        )
        return color(forNormalized: n, palette: palette)
    }

    // Iron / "ironbow" ramp: deep navy → purple → magenta → red → orange → yellow → near-white.
    // Deliberately no green/cyan stop, so it reads as a thermal palette and not a debug heatmap.
    private static let ironStops: [(t: Double, r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (0.00, 0.03, 0.03, 0.16),
        (0.18, 0.16, 0.06, 0.36),
        (0.36, 0.45, 0.10, 0.45),
        (0.52, 0.74, 0.16, 0.34),
        (0.66, 0.91, 0.34, 0.14),
        (0.80, 0.98, 0.62, 0.12),
        (0.92, 1.00, 0.86, 0.30),
        (1.00, 1.00, 0.98, 0.86)
    ]

    private static func ironRamp(_ t: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let stops = ironStops
        if t <= stops.first!.t { return (stops.first!.r, stops.first!.g, stops.first!.b) }
        if t >= stops.last!.t { return (stops.last!.r, stops.last!.g, stops.last!.b) }

        for index in 1..<stops.count {
            let upper = stops[index]
            if t <= upper.t {
                let lower = stops[index - 1]
                let span = upper.t - lower.t
                let f = span > 0 ? CGFloat((t - lower.t) / span) : 0
                return (
                    lower.r + (upper.r - lower.r) * f,
                    lower.g + (upper.g - lower.g) * f,
                    lower.b + (upper.b - lower.b) * f
                )
            }
        }
        return (stops.last!.r, stops.last!.g, stops.last!.b)
    }
}
