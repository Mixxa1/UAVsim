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

            UAVFlightCardSection(profile: entry.runtimeProfile)

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

/// The airframe's flight card inside its catalogue card: each figure the entry declares beside
/// the one the solver produces when the aircraft is flown for it.
///
/// Flown when the card is opened, off the main thread, and once: a card takes a tenth of a second
/// in a release build and a second or two in a debug one, and eighty of them at launch is not a
/// cost a list of airframes should have.
struct UAVFlightCardSection: View {
    let profile: DroneModelProfile
    @State private var card: AirframeFlightCard?
    @State private var isFlown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L10n.s("uav.card.flight_card"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 4)
                if !isFlown { ProgressView().controlSize(.mini) }
            }
            if let card {
                ForEach(card.lines, id: \.quantity) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(WorkbenchFlightPassportText.name(line.quantity, airframeClass: card.airframeClass))
                            .font(.caption2)
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Spacer(minLength: 6)
                        Text(WorkbenchFlightPassportText.pair(line))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                        Circle()
                            .fill(WorkbenchFlightPassportText.color(line.verdict))
                            .frame(width: 6, height: 6)
                    }
                    .help(WorkbenchFlightPassportText.band(line.quantity))
                }
            } else if isFlown {
                Text(L10n.s("uav.card.flight_card.none"))
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .task(id: profile.id) {
            isFlown = false
            card = await AirframeFlightCardCache.shared.card(for: profile)
            isFlown = true
        }
    }
}
