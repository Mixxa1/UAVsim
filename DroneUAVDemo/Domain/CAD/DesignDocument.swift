import Foundation

enum DesignUnits: String, Codable, CaseIterable {
    case metric
    case imperial

    var displayName: String {
        switch self {
        case .metric: return "м (метры)"
        case .imperial: return "in (дюймы)"
        }
    }
}

struct DesignDocument: Codable, Equatable {
    let id: UUID
    var name: String
    var units: DesignUnits
    var assets: [DesignAsset]
    var selectedAssetID: UUID?

    init(
        id: UUID = UUID(),
        name: String = NSLocalizedString("cad.document.default_name", comment: ""),
        units: DesignUnits = .metric
    ) {
        self.id = id
        self.name = name
        self.units = units
        self.assets = []
        self.selectedAssetID = nil
    }

    var selectedAsset: DesignAsset? {
        guard let assetID = selectedAssetID else { return nil }
        return assets.first { $0.id == assetID }
    }

    mutating func selectAsset(_ id: UUID?) {
        selectedAssetID = id
    }

    mutating func addAsset(_ asset: DesignAsset) {
        assets.append(asset)
        selectedAssetID = asset.id
    }

    mutating func removeAsset(id: UUID) {
        guard let idx = assets.firstIndex(where: { $0.id == id }) else { return }
        assets.remove(at: idx)
        if selectedAssetID == id {
            selectedAssetID = idx < assets.count ? assets[idx].id : assets.last?.id
        }
    }

    mutating func updateAsset(_ updated: DesignAsset) {
        guard let idx = assets.firstIndex(where: { $0.id == updated.id }) else { return }
        assets[idx] = updated
    }
}
