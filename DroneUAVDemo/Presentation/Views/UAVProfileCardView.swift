import SwiftUI

struct UAVProfileCardView: View {
    let entry: UAVCatalogEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("uav.card.title")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let entry {
                let payloadData = entry.profile.payloadDataResolution

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.profile.localizedDisplayName)
                                .font(.headline)
                            Text(entry.profile.localizedShortDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if entry.isCustom {
                            badge(localized("uav.badge.custom"), tint: .orange)
                        } else {
                            badge(entry.profile.specConfidence.catalogTitle.uppercased(), tint: badgeTint(for: entry.profile.specConfidence))
                        }
                    }

                    infoRow(localized("uav.card.manufacturer"), entry.profile.localizedManufacturer)
                    infoRow(localized("uav.card.country"), entry.profile.localizedCountryOfOrigin ?? localized("common.not_specified"))
                    infoRow(localized("uav.card.type"), entry.profile.vehicleType.catalogTitle)
                    infoRow(localized("uav.card.mass_class"), entry.profile.massCategory?.catalogTitle ?? localized("common.not_specified"))
                    infoRow(localized("uav.card.base_mass"), massText(payloadData.baseMass))
                    infoRow(localized("uav.card.max_payload"), massText(payloadData.maxPayloadMass))
                    infoRow(localized("uav.card.mtow"), massText(payloadData.maxTakeoffMass))
                    infoRow(localized("uav.card.role"), entry.profile.localizedMissionRole ?? localized("common.not_specified"))
                    infoRow(localized("uav.card.status"), entry.profile.specConfidence.catalogTitle)
                    infoRow(localized("uav.card.payload_data_source"), payloadData.sourceQuality.title)

                    if let armamentCapabilityNote = entry.profile.localizedArmamentCapabilityNote {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("uav.card.armament_note")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(armamentCapabilityNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.05))
                )
            } else {
                Text("uav.card.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
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

    private func badgeTint(for confidence: UAVSpecConfidence) -> Color {
        switch confidence {
        case .verified:
            return .green
        case .partial:
            return .yellow
        case .custom:
            return .orange
        }
    }

    private func badgeTint(for quality: PayloadDataQualitySource) -> Color {
        switch quality {
        case .verified:
            return .green
        case .estimated:
            return .blue
        case .custom:
            return .orange
        }
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.18))
            )
            .foregroundStyle(tint)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
