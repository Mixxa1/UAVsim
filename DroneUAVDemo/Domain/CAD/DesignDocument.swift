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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case units
        case assets
        case selectedAssetID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        units = try container.decode(DesignUnits.self, forKey: .units)
        selectedAssetID = try container.decodeIfPresent(UUID.self, forKey: .selectedAssetID)
        assets = try container.decode([DesignAsset].self, forKey: .assets).map(Self.normalizedLoadedAsset)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(units, forKey: .units)
        try container.encode(assets, forKey: .assets)
        try container.encodeIfPresent(selectedAssetID, forKey: .selectedAssetID)
    }

    private static func normalizedLoadedAsset(_ asset: DesignAsset) -> DesignAsset {
        guard case var .extrudedSolid(params) = asset.kind else { return asset }

        params.refreshFaces(assetID: asset.id)
        if !params.stableCutFeatures.isEmpty {
            params.kernelResultSolid = nil
            params.kernelVisualMesh = nil
            if let build = CADCutMeshRebuilder.rebuildBodyMesh(
                bodyID: asset.id,
                bodyParams: params
            ) {
                params.kernelVisualMesh = build.mesh
            }
        }

        var normalized = asset
        normalized.kind = .extrudedSolid(params)
        normalized.updateDerivedProperties()
        return normalized
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
