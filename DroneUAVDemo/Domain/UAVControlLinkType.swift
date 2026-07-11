import Foundation

/// What actually carries commands/video/telemetry to and from the airframe. Gates whether the
/// existing world-boundary/geofence signal-loss machinery (`UAVSignalState`) applies at all:
/// radio is subject to it, fiber-optic bypasses it entirely in favor of its own link-state
/// machine (`FiberLinkState`) — a physical fiber isn't affected by distance from the map center.
enum UAVControlLinkType: Equatable {
    case radio
    case fiberOptic
}
