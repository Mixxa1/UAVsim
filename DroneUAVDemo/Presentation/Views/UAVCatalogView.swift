import SwiftUI

struct UAVCatalogView: View {
    let selectionState: UAVSelectionState
    let filterState: UAVFilterState
    let onVehicleTypeChange: (UAVVehicleTypeFilter) -> Void
    let onMassCategoryChange: (UAVMassCategoryFilter) -> Void
    let onSelectEntry: (UAVCatalogEntry) -> Void
    let onEditAbstract: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("uav.catalog.title")
                .font(.caption.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)

            UAVFilterBarView(
                filterState: filterState,
                selectedModelOutsideCurrentFilter: selectionState.selectedModelOutsideCurrentFilter,
                onVehicleTypeChange: onVehicleTypeChange,
                onMassCategoryChange: onMassCategoryChange
            )

            if selectionState.filteredEntries.isEmpty {
                Text("uav.catalog.empty")
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(selectionState.filteredEntries) { entry in
                        catalogCard(
                            entry: entry,
                            isSelected: selectionState.activeEntry?.id == entry.id
                        )
                    }
                }
            }

            if selectionState.activeEntry?.isCustom == true {
                Button("uav.catalog.edit_abstract") {
                    onEditAbstract()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func catalogCard(entry: UAVCatalogEntry, isSelected: Bool) -> some View {
        Button {
            onSelectEntry(entry)
        } label: {
            UAVSelectionCardView(
                name: entry.profile.localizedDisplayName,
                manufacturer: entry.profile.localizedManufacturer,
                previewProfile: entry.profile,
                massKg: entry.profile.payloadDataResolution.maxTakeoffMass ?? entry.profile.payloadDataResolution.baseMass,
                speedMps: entry.profile.nominalCruiseSpeedMps,
                flightTimeSec: entry.profile.nominalFlightTimeSec,
                rangeMeters: entry.profile.nominalMaxRangeM,
                badgeText: entry.isCustom ? localized("uav.badge.custom") : entry.profile.specConfidence.catalogTitle.uppercased(),
                badgeTint: entry.isCustom ? .orange : badgeTint(for: entry.profile.specConfidence),
                isSelected: isSelected
            ) {
                if isSelected {
                    UAVProfileExtraSpecsView(entry: entry)
                }
            }
        }
        .buttonStyle(.plain)
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

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
