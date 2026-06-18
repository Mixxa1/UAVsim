import Foundation

enum AbandonedCityBuildingKind: String, CaseIterable {
    case shopOldHouse
    case aspectHouse
    case sengchorHouse
}

struct AbandonedCityBuildingAsset {
    let kind: AbandonedCityBuildingKind
    let resourceName: String
    let targetHeightRange: ClosedRange<Float>
    let groundSinkMeters: Float
}

enum AbandonedCityAssetCatalog {
    static let modelSubdirectory = "Models/Urban/Abandoned"
    static let textureSubdirectory = "Textures/Urban/Abandoned"

    static let brittleStoneModelName = "Seamless_Brittle_Stone"
    static let brittleStoneAlbedoName = "brittle_stone_albedo"

    static let buildings: [AbandonedCityBuildingKind: AbandonedCityBuildingAsset] = [
        .shopOldHouse: AbandonedCityBuildingAsset(
            kind: .shopOldHouse,
            resourceName: "Abandoned_Shop_Old_House",
            targetHeightRange: 7.0...10.0,
            groundSinkMeters: 0.0
        ),
        .aspectHouse: AbandonedCityBuildingAsset(
            kind: .aspectHouse,
            resourceName: "Abandoned_House_AspectStudios",
            targetHeightRange: 6.0...9.0,
            groundSinkMeters: 0.0
        ),
        .sengchorHouse: AbandonedCityBuildingAsset(
            kind: .sengchorHouse,
            resourceName: "Abandoned_House_Sengchor",
            targetHeightRange: 6.0...9.0,
            groundSinkMeters: 0.0
        )
    ]

    static func buildingAsset(for kind: AbandonedCityBuildingKind) -> AbandonedCityBuildingAsset {
        buildings[kind]!
    }

    static func bundleURL(
        resourceName: String,
        extension resourceExtension: String,
        subdirectory: String
    ) -> URL? {
        Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: subdirectory
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        )
    }
}
