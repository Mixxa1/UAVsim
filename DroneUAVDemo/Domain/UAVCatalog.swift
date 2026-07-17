import Foundation

enum UAVCatalogSource: Hashable {
    case builtIn
    case abstract
    case workbench(UUID)
}

struct UAVCatalogEntry: Identifiable, Hashable {
    let runtimeProfile: DroneModelProfile
    let profile: UAVProfile
    let source: UAVCatalogSource

    var id: String { runtimeProfile.id }
    var isCustom: Bool { profile.specConfidence == .custom }
    var isWorkbench: Bool {
        if case .workbench = source { return true }
        return false
    }
    var isAbstract: Bool {
        if case .abstract = source { return true }
        return false
    }
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
            let source: UAVCatalogSource
            if let build = runtimeProfile.workbenchBuild {
                source = .workbench(build.id)
            } else if runtimeProfile.isAbstract {
                source = .abstract
            } else {
                source = .builtIn
            }
            return UAVCatalogEntry(runtimeProfile: runtimeProfile, profile: profile, source: source)
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
