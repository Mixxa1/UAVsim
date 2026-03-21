import Foundation

struct UAVCatalogEntry: Identifiable, Hashable {
    let runtimeProfile: DroneModelProfile
    let profile: UAVProfile

    var id: String { runtimeProfile.id }
    var isCustom: Bool { profile.specConfidence == .custom }
}

enum UAVCatalog {
    static func buildEntries(
        from runtimeProfiles: [DroneModelProfile],
        abstractParameters: AbstractDroneParameters
    ) -> [UAVCatalogEntry] {
        runtimeProfiles.compactMap { runtimeProfile in
            guard let profile = resolveProfile(for: runtimeProfile, abstractParameters: abstractParameters) else {
                return nil
            }
            return UAVCatalogEntry(runtimeProfile: runtimeProfile, profile: profile)
        }
    }

    static func filter(
        entries: [UAVCatalogEntry],
        with filterState: UAVFilterState
    ) -> [UAVCatalogEntry] {
        entries.filter { entry in
            filterState.vehicleType.matches(entry.profile) &&
            filterState.massCategory.matches(entry.profile)
        }
    }

    static func selectionState(
        runtimeProfiles: [DroneModelProfile],
        selectedRuntimeProfileID: String,
        abstractParameters: AbstractDroneParameters,
        filterState: UAVFilterState
    ) -> UAVSelectionState {
        let entries = buildEntries(from: runtimeProfiles, abstractParameters: abstractParameters)
        let filteredEntries = filter(entries: entries, with: filterState)
        let activeEntry = entries.first(where: { $0.id == selectedRuntimeProfileID })
        let selectedOutsideCurrentFilter = activeEntry.map { entry in
            filteredEntries.contains(entry) == false
        } ?? false

        return UAVSelectionState(
            entries: entries,
            filteredEntries: filteredEntries,
            activeEntry: activeEntry,
            selectedModelOutsideCurrentFilter: selectedOutsideCurrentFilter
        )
    }

    private static func resolveProfile(
        for runtimeProfile: DroneModelProfile,
        abstractParameters: AbstractDroneParameters
    ) -> UAVProfile? {
        if runtimeProfile.isAbstract {
            return UAVReferenceCatalog.abstractProfile(from: abstractParameters)
        }

        return runtimeProfile.resolvedUAVProfile
    }
}
