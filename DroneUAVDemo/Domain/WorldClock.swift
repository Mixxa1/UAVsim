import Foundation

/// Named stretches of the day, in the order they occur. These are *labels for the operator* —
/// the lighting is driven by the sun's elevation, not by which case this returns, so a phase
/// boundary never produces a visible step.
enum DayPhase: String, CaseIterable, Identifiable, Hashable {
    case dawn
    case morning
    case day
    case sunset
    case evening
    case night

    var id: String { rawValue }

    var titleKey: String { "world.day_phase.\(rawValue)" }

    var iconSystemName: String {
        switch self {
        case .dawn: return "sunrise"
        case .morning: return "sun.min"
        case .day: return "sun.max"
        case .sunset: return "sunset"
        case .evening: return "moon.haze"
        case .night: return "moon.stars"
        }
    }
}

/// How fast the world runs relative to real time.
///
/// This accelerates the **world**, not the aircraft: the airframe still flies its own dynamics at
/// its own rate, and the day, the mission timers and the autopilot's own clocks all speed up with
/// it. Nothing downstream is given a multiplier to apply — the simulation is simply stepped more
/// often, which is the only way to run a fixed-step integrator faster without changing what it
/// computes.
enum SimulationTimeScale: Int, CaseIterable, Identifiable, Hashable {
    case realtime = 1
    case x2 = 2
    case x4 = 4
    case x8 = 8
    case x16 = 16
    case x32 = 32
    case x64 = 64

    var id: Int { rawValue }

    /// Simulation ticks to run per rendered frame.
    var stepsPerFrame: Int { rawValue }

    var label: String { self == .realtime ? "1×" : "\(rawValue)×" }
}

/// The simulation world's own clock.
///
/// One source of truth for what time it is in the world, derived from accumulated *simulation*
/// time rather than the wall clock. That is the whole point: when the simulation is fast-forwarded
/// it advances more simulated seconds per real second, and the day advances with it for free —
/// time acceleration is a property of the world, not of the aircraft, so nothing here needs to
/// know a multiplier exists.
///
/// A full day takes `secondsPerDay` of simulated time: 24 minutes, so one simulated second is one
/// minute of the day and a whole day passes in the time a long sortie takes.
struct WorldClock: Equatable {
    /// Simulated seconds in one 24-hour day. 1440 s = 24 min.
    static let secondsPerDay: Double = 1440.0

    /// Peak solar elevation at local noon. A mid-latitude figure — high enough that midday
    /// shadows are short and low enough that they still have a direction.
    static let peakSunElevationDegrees: Double = 58.0

    /// Hour the world starts at, 0..<24.
    var startHour: Double

    /// Accumulated simulated seconds since the run began.
    var elapsedSimulatedSeconds: Double

    init(startHour: Double = 12.0, elapsedSimulatedSeconds: Double = 0.0) {
        self.startHour = startHour.wrappedIntoDay
        self.elapsedSimulatedSeconds = elapsedSimulatedSeconds
    }

    /// Seeded from the scenario's coarse choice so an operator who picked "night" starts at night.
    init(timeOfDay: TimeOfDay) {
        self.init(startHour: timeOfDay.timeOfDayHours)
    }

    // MARK: - Time

    /// Hours since midnight, 0..<24, as a continuous value.
    var hourOfDay: Double {
        let daysElapsed = elapsedSimulatedSeconds / Self.secondsPerDay
        return (startHour + daysElapsed * 24.0).wrappedIntoDay
    }

    var hour: Int { Int(hourOfDay) }

    var minute: Int {
        // Floor rather than round: rounding makes the display show 13:60.
        min(59, Int((hourOfDay - Double(hour)) * 60.0))
    }

    /// `HH:MM`, zero-padded.
    var formattedTime: String { String(format: "%02d:%02d", hour, minute) }

    /// Whole days completed. Useful for a sortie that outlasts one night.
    var dayNumber: Int { Int((startHour + elapsedSimulatedSeconds / Self.secondsPerDay * 24.0) / 24.0) }

    // MARK: - Sun

    /// Solar elevation above the horizon, in degrees, negative when the sun is down.
    ///
    /// A single sine through the day: zero at 06:00, peak at noon, zero again at 18:00 and lowest
    /// at midnight. Continuous and periodic by construction, so no phase boundary can produce a
    /// lighting step, and it needs no latitude — which matters because the procedural worlds do
    /// not have one.
    var sunElevationDegrees: Double {
        Self.peakSunElevationDegrees * sin(2.0 * .pi * (hourOfDay - 6.0) / 24.0)
    }

    /// Compass bearing of the sun, degrees. East at dawn, south at noon, west at dusk.
    var sunAzimuthDegrees: Double {
        ((hourOfDay - 6.0) / 24.0 * 360.0 + 90.0).truncatingRemainder(dividingBy: 360.0)
    }

    var isSunUp: Bool { sunElevationDegrees > 0.0 }

    // MARK: - Lighting

    /// Direct sunlight, 0 when the sun is below the horizon and 1 once it is well up.
    ///
    /// The band straddles the horizon rather than cutting at it: the sun still lights the world
    /// for a while after it sets, and a hard cut at zero elevation reads as a light switch.
    var sunIntensityMultiplier: Double {
        smoothstep(from: -4.0, to: 10.0, value: sunElevationDegrees)
    }

    /// Ambient/IBL exposure. Never reaches zero — night is meant to be dark enough that thermal
    /// and searchlight equipment is the point, but a literal zero has caused trouble before.
    var ambientIntensityMultiplier: Double {
        let nightFloor = 0.015
        return nightFloor + (1.0 - nightFloor) * smoothstep(from: -8.0, to: 6.0, value: sunElevationDegrees)
    }

    /// How strongly the sun is reddened by its own low angle, 0 (high, neutral) to 1 (on the
    /// horizon). Golden hour falls out of this rather than being a special case.
    var sunWarmth: Double {
        1.0 - smoothstep(from: 0.0, to: 22.0, value: sunElevationDegrees)
    }

    /// Brightness for surfaces drawn with a constant lighting model, which no lamp reaches.
    ///
    /// These exist for cost — the simplified/LOD environment layer is drawn unlit so it can be
    /// batched — but "unlit" is not "self-luminous", and without this they kept their full daylight
    /// colour all night. The floor is above the ambient floor because a flat multiply has no
    /// specular or bounce to fall back on; taken to zero these objects vanish rather than
    /// silhouette.
    var unlitSurfaceBrightness: Double {
        let nightFloor = 0.055
        return nightFloor + (1.0 - nightFloor) * smoothstep(from: -8.0, to: 6.0, value: sunElevationDegrees)
    }

    /// How far the *sky* has gone over to night, 0 (full daylight gradient) to 1 (night).
    ///
    /// Spans civil twilight rather than cutting at the horizon: the sky keeps light in it for a
    /// good while after the sun has set, and the band is deliberately wider than the one the sun
    /// lamp uses so the ground darkens slightly ahead of the sky, the way dusk actually reads.
    var nightBlend: Double {
        1.0 - smoothstep(from: -12.0, to: 4.0, value: sunElevationDegrees)
    }

    // MARK: - Phase

    /// The named stretch of day, by clock hour. Deliberately *not* derived from elevation: these
    /// are the words an operator expects next to the time, and "утро" is a time of day, not a sun
    /// angle.
    var phase: DayPhase {
        switch hourOfDay {
        case 5.0..<7.0: return .dawn
        case 7.0..<11.0: return .morning
        case 11.0..<16.0: return .day
        case 16.0..<19.0: return .sunset
        case 19.0..<21.0: return .evening
        default: return .night
        }
    }

    /// The coarse three-way value the rest of the app already speaks.
    ///
    /// Everything built before this clock — the thermal pipeline, the scenario setup, the scene's
    /// own night handling — asks for a `TimeOfDay`, so the continuous clock answers in their
    /// language rather than requiring all of them to change at once. Keyed on the sun, because
    /// that is what those consumers actually care about.
    var legacyTimeOfDay: TimeOfDay {
        let elevation = sunElevationDegrees
        if elevation < -6.0 { return .night }
        if elevation < 8.0 { return .dusk }
        return .day
    }

    var isNight: Bool { legacyTimeOfDay == .night }

    // MARK: - Advancing

    mutating func advance(bySimulatedSeconds seconds: Double) {
        guard seconds.isFinite, seconds > 0.0 else { return }
        elapsedSimulatedSeconds += seconds
    }
}

// MARK: - Helpers

private func smoothstep(from edge0: Double, to edge1: Double, value: Double) -> Double {
    guard edge1 > edge0 else { return value >= edge1 ? 1.0 : 0.0 }
    let t = ((value - edge0) / (edge1 - edge0)).clampedToUnitRange
    return t * t * (3.0 - 2.0 * t)
}

private extension Double {
    var clampedToUnitRange: Double { Swift.max(0.0, Swift.min(1.0, self)) }

    /// Wraps any hour value into 0..<24, including negatives.
    var wrappedIntoDay: Double {
        guard isFinite else { return 0.0 }
        let wrapped = truncatingRemainder(dividingBy: 24.0)
        return wrapped < 0.0 ? wrapped + 24.0 : wrapped
    }
}
