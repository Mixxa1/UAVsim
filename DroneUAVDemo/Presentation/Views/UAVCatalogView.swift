import SwiftUI

struct UAVCatalogView: View {
    let selectionState: UAVSelectionState
    let filterState: UAVFilterState
    let onVehicleTypeChange: (UAVVehicleTypeFilter) -> Void
    let onMassCategoryChange: (UAVMassCategoryFilter) -> Void
    let onSelectEntry: (UAVCatalogEntry) -> Void
    let onEditAbstract: () -> Void

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

            VStack(alignment: .leading, spacing: 6) {
                ForEach(selectionState.filteredEntries) { entry in
                    catalogRow(
                        entry: entry,
                        isSelected: selectionState.activeEntry?.id == entry.id
                    )
                }

                if selectionState.filteredEntries.isEmpty {
                    Text("uav.catalog.empty")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .padding(.vertical, 6)
                }
            }

            if selectionState.activeEntry?.isCustom == true {
                Button("uav.catalog.edit_abstract") {
                    onEditAbstract()
                }
                .buttonStyle(.borderedProminent)
            }

            UAVProfileCardView(entry: selectionState.activeEntry)
        }
    }

    private func catalogRow(entry: UAVCatalogEntry, isSelected: Bool) -> some View {
        Button {
            onSelectEntry(entry)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.profile.localizedDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text("\(entry.profile.localizedManufacturer) / \(entry.profile.localizedCountryOfOrigin ?? localized("common.not_specified"))")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Text(entry.profile.localizedShortDescription)
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if entry.isCustom {
                    rowBadge(localized("uav.badge.custom"), tint: .orange)
                } else {
                    rowBadge(entry.profile.specConfidence.catalogTitle.uppercased(), tint: badgeTint(for: entry.profile.specConfidence))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? GroundControlPalette.accent.opacity(0.65) : GroundControlPalette.border, lineWidth: 1.0)
            )
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

    private func rowBadge(_ title: String, tint: Color) -> some View {
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
