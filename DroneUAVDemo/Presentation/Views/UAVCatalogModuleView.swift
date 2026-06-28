import SwiftUI

struct UAVCatalogModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    @State private var showAbstractEditor = false

    var body: some View {
        let selectionState = viewModel.uavCatalogSelectionState

        VStack(alignment: .leading, spacing: 14) {
            if viewModel.hasMissionScenario {
                MissionLockBanner(messageKey: "module.uav_catalog.locked_by_mission")
            }

            ModuleSection(
                titleKey: "module.uav_catalog.selection",
                subtitleKey: "module.uav_catalog.selection.subtitle"
            ) {
                ModuleMetricGrid {
                    ModuleMetricCell(
                        labelKey: "module.uav_catalog.metric.active",
                        value: selectionState.activeEntry?.profile.localizedDisplayName ?? localized("common.na")
                    )
                    ModuleMetricCell(
                        labelKey: "module.uav_catalog.metric.filtered",
                        value: "\(selectionState.filteredEntries.count)"
                    )
                    ModuleMetricCell(
                        labelKey: "module.uav_catalog.metric.type",
                        value: selectionState.activeEntry?.profile.vehicleType.catalogTitle ?? localized("common.na")
                    )
                    ModuleMetricCell(
                        labelKey: "module.uav_catalog.metric.mass",
                        value: selectionState.activeEntry?.profile.massCategory?.catalogTitle ?? localized("common.not_specified")
                    )
                }
            }

            ModuleSection(
                titleKey: "uav.catalog.title",
                subtitleKey: "module.uav_catalog.list.subtitle"
            ) {
                UAVCatalogView(
                    selectionState: selectionState,
                    filterState: viewModel.uavCatalogFilterState,
                    onVehicleTypeChange: viewModel.setUAVVehicleTypeFilter,
                    onMassCategoryChange: viewModel.setUAVMassCategoryFilter,
                    onSelectEntry: { entry in
                        viewModel.selectDroneModel(id: entry.id)
                    },
                    onEditAbstract: {
                        showAbstractEditor = true
                    }
                )
                // The aircraft is locked in at mission setup; switching mid-mission would silently
                // invalidate whatever briefed conditions (payload compatibility, performance) the
                // mission was set up around.
                .disabled(viewModel.hasMissionScenario)
            }
        }
        .sheet(isPresented: $showAbstractEditor) {
            AbstractModelEditorView(initial: viewModel.abstractParameters) { updated in
                viewModel.applyAbstractParameters(updated)
            }
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
