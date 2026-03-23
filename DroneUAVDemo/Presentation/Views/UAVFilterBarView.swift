import SwiftUI

struct UAVFilterBarView: View {
    let filterState: UAVFilterState
    let selectedModelOutsideCurrentFilter: Bool
    let onVehicleTypeChange: (UAVVehicleTypeFilter) -> Void
    let onMassCategoryChange: (UAVMassCategoryFilter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("uav.filter.type", selection: Binding(
                    get: { filterState.vehicleType },
                    set: onVehicleTypeChange
                )) {
                    ForEach(UAVVehicleTypeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                Picker("uav.filter.mass", selection: Binding(
                    get: { filterState.massCategory },
                    set: onMassCategoryChange
                )) {
                    ForEach(UAVMassCategoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )

            if selectedModelOutsideCurrentFilter {
                Text("uav.catalog.selected_outside_filter")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }
}
