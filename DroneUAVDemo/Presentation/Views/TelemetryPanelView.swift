import SwiftUI

struct TelemetryPanelView: View {
    let telemetry: TelemetrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(titleKey: "telemetry.position", value: String(format: "x %.2f | y %.2f | z %.2f m", telemetry.x, telemetry.y, telemetry.z))
            row(titleKey: "telemetry.velocity", value: String(format: "vx %.2f | vy %.2f | vz %.2f m/s", telemetry.velocityX, telemetry.velocityY, telemetry.velocityZ))

            Divider()

            row(titleKey: "telemetry.attitude", value: String(format: "R %.1f° | P %.1f° | Y %.1f°", telemetry.roll, telemetry.pitch, telemetry.yaw))
            row(titleKey: "telemetry.speed", value: String(format: "%.2f m/s", telemetry.speed))
            row(titleKey: "telemetry.throttle", value: String(format: "%.0f %%", telemetry.throttle * 100.0))
            row(titleKey: "telemetry.mode", valueKey: telemetry.modeKey)
            row(titleKey: "telemetry.control_mode", valueKey: telemetry.controlModeKey)
            row(titleKey: "telemetry.arm_state", valueKey: telemetry.armStateKey)
            row(titleKey: "telemetry.state", valueKey: telemetry.flightStateKey)

            Divider()

            row(titleKey: "telemetry.battery", value: String(format: "%.1f %%", telemetry.batteryPercent))
            row(titleKey: "telemetry.power", value: String(format: "%.1f W", telemetry.powerDrawW))
            row(titleKey: "telemetry.remaining", value: String(format: "%.1f min", telemetry.estimatedRemainingMin))
            row(titleKey: "telemetry.weather", value: "\(localized(telemetry.weatherPresetKey)) (\(String(format: "%.2f", telemetry.weatherIntensity)))")
            row(titleKey: "telemetry.collision_risk", value: String(format: "%.0f %%", telemetry.collisionRisk * 100.0))
            row(titleKey: "telemetry.nearest_obstacle", value: telemetry.nearestObstacleDistance.isFinite ? String(format: "%.2f m", telemetry.nearestObstacleDistance) : localized("common.na"))
            row(titleKey: "telemetry.nearest_obstacle_source", value: telemetry.nearestObstacleSource)
            row(titleKey: "telemetry.path_status", value: localizedPathStatus(telemetry.pathStatus))
            row(titleKey: "telemetry.waypoint", value: String(format: localized("telemetry.waypoint.value"), telemetry.currentWaypointIndex, telemetry.remainingWaypoints))
            row(titleKey: "telemetry.path_remaining", value: String(format: "%.2f / %.2f m", telemetry.pathRemainingDistanceMeters, telemetry.pathLengthMeters))
            row(titleKey: "telemetry.emergency", valueKey: telemetry.emergencyActionKey)
            row(titleKey: "telemetry.damage", value: telemetry.damageSummary)
            row(titleKey: "telemetry.thermal", value: telemetry.thermalSummary)
            row(titleKey: "telemetry.fleet", value: "\(localized(telemetry.fleetModeKey)) (\(telemetry.wingmanCount))")
            row(titleKey: "telemetry.fleet_risk", value: String(format: "%.0f %%", telemetry.interDroneRisk * 100.0))
            row(titleKey: "telemetry.nearest_interdrone", value: telemetry.nearestInterDroneDistance.isFinite ? String(format: "%.2f m", telemetry.nearestInterDroneDistance) : localized("common.na"))

            Divider()

            row(titleKey: "telemetry.frame_time", value: String(format: "%.2f ms", telemetry.frameTimeMs))
            row(titleKey: "telemetry.physics_time", value: String(format: "%.2f ms", telemetry.physicsTimeMs))
            row(titleKey: "telemetry.render_time", value: String(format: "%.2f ms", telemetry.renderTimeMs))
            row(titleKey: "telemetry.path_time", value: String(format: "%.2f ms", telemetry.pathfindingTimeMs))
            row(titleKey: "telemetry.active_objects", value: String(telemetry.activeObjectCount))
            row(titleKey: "telemetry.active_physics_bodies", value: String(telemetry.activePhysicsBodyCount))
            row(titleKey: "telemetry.particle_count", value: String(telemetry.activeParticleCount))
        }
        .font(.system(size: 12.0, weight: .regular, design: .monospaced))
    }

    private func row(titleKey: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
    }

    private func row(titleKey: String, valueKey: String) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(.secondary)
            Spacer()
            Text(LocalizedStringKey(valueKey))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
    }

    private func localizedPathStatus(_ status: String) -> String {
        switch status {
        case "idle":
            return localized("telemetry.path_status.idle")
        case "valid":
            return localized("telemetry.path_status.valid")
        case "recomputing":
            return localized("telemetry.path_status.recomputing")
        case "blocked":
            return localized("telemetry.path_status.blocked")
        default:
            return status
        }
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
