import Foundation

final class BuildingColliderPresetLoader {
    static let shared = BuildingColliderPresetLoader()

    private var cached: BuildingColliderPresetFile?
    private var loaded = false

    func load() -> BuildingColliderPresetFile? {
        if loaded { return cached }
        loaded = true

        guard let url = Bundle.main.url(
            forResource: "abandoned_building_colliders",
            withExtension: "json"
        ) else {
            #if DEBUG
            print("[BuildingPhysics] WARNING abandoned_building_colliders.json not found in bundle")
            #endif
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            #if DEBUG
            print("[BuildingPhysics] WARNING failed to read abandoned_building_colliders.json")
            #endif
            return nil
        }

        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(BuildingColliderPresetFile.self, from: data) else {
            #if DEBUG
            print("[BuildingPhysics] WARNING failed to decode abandoned_building_colliders.json")
            #endif
            return nil
        }

        cached = file
        #if DEBUG
        print("[BuildingPhysics] presetLoaded=true shopOldHouse=\(file.shopOldHouse.count) aspectHouse=\(file.aspectHouse.count) sengchorHouse=\(file.sengchorHouse.count)")
        #endif
        return file
    }

    func parts(for kind: AbandonedCityBuildingKind) -> [BuildingColliderPart] {
        guard let file = load() else { return [] }
        switch kind {
        case .shopOldHouse:  return file.shopOldHouse
        case .aspectHouse:   return file.aspectHouse
        case .sengchorHouse: return file.sengchorHouse
        }
    }
}
