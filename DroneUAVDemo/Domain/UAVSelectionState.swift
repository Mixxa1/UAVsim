import Foundation

struct UAVSelectionState: Hashable {
    let entries: [UAVCatalogEntry]
    let filteredEntries: [UAVCatalogEntry]
    let activeEntry: UAVCatalogEntry?
    let selectedModelOutsideCurrentFilter: Bool
}
