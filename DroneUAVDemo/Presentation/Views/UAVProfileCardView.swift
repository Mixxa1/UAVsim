import SwiftUI

/// Extra spec detail shown appended inline inside the currently-selected card in the UAV Catalog's
/// grid (`UAVCatalogView`) — the fields NOT already promoted to `UAVSelectionCardView`'s compact
/// summary (name/manufacturer/mass/speed/flight-time/range/badge). Kept as a separate view rather
/// than folded into the compact card so every OTHER card in the grid stays uncluttered.
struct UAVProfileExtraSpecsView: View {
    let entry: UAVCatalogEntry

    var body: some View {
        let payloadData = entry.profile.payloadDataResolution

        VStack(alignment: .leading, spacing: 6) {
            if !entry.profile.localizedShortDescription.isEmpty {
                Text(entry.profile.localizedShortDescription)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            infoRow(localized("uav.card.country"), entry.profile.localizedCountryOfOrigin ?? localized("common.not_specified"))
            infoRow(localized("uav.card.type"), entry.profile.vehicleType.catalogTitle)
            infoRow(localized("uav.card.mass_class"), entry.profile.massCategory?.catalogTitle ?? localized("common.not_specified"))
            infoRow(localized("uav.card.base_mass"), massText(payloadData.baseMass))
            infoRow(localized("uav.card.mtow"), massText(payloadData.maxTakeoffMass))
            infoRow(localized("uav.card.role"), entry.profile.localizedMissionRole ?? localized("common.not_specified"))
            infoRow(localized("uav.card.status"), entry.profile.specConfidence.catalogTitle)

            if let armamentCapabilityNote = entry.profile.localizedArmamentCapabilityNote {
                VStack(alignment: .leading, spacing: 4) {
                    Text("uav.card.armament_note")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Text(armamentCapabilityNote)
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
    }

    private func massText(_ value: Float?) -> String {
        guard let value else {
            return localized("common.not_specified")
        }
        if value >= 10.0 {
            return String(format: "%.1f kg", value)
        }
        return String(format: "%.2f kg", value)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
