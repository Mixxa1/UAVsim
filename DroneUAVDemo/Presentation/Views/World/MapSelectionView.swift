import SwiftUI
import AppKit

/// What the user chose to fly in.
enum MapSelection: Equatable {
    /// One of the procedurally generated presets.
    case standard(TerrainPreset)
    /// An installed photogrammetric world, identified by its tile directory.
    case photogrammetric(tileKey: String, directory: URL)
}

/// Map picker shown when a project is created.
///
/// The split is not cosmetic. The two kinds of world are built by entirely different pipelines and
/// cost entirely different amounts — a preset is generated in milliseconds from a seed, while a
/// photogrammetric tile is gigabytes on disk and takes tens of seconds to index the first time.
/// Choosing between them *before* the scene is constructed lets each path build only what it
/// needs, instead of a mesh world being bolted onto a scene already populated with procedural
/// objects, boundary belts and ground materials it will never show.
struct MapSelectionView: View {
    enum Family: String, CaseIterable, Identifiable {
        case standard
        case photogrammetric

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .standard: return "map.family.standard"
            case .photogrammetric: return "map.family.real_geo"
            }
        }
    }

    let airframeClass: AirframeClass
    let onConfirm: (MapSelection) -> Void
    let onCancel: () -> Void

    @State private var family: Family = .standard
    @State private var highlightedPreset: TerrainPreset?
    @State private var highlightedWorld: InstalledWorld?
    @State private var installedWorlds: [InstalledWorld] = []
    @State private var showingCatalog = false

    struct InstalledWorld: Identifiable, Equatable, Hashable {
        let key: String
        let directory: URL
        let sizeBytes: Int64
        var id: String { key }
    }

    private var availablePresets: [TerrainPreset] {
        TerrainPreset.available(for: airframeClass)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $family) {
                ForEach(Family.allCases) { family in
                    Text(LocalizedStringKey(family.titleKey)).tag(family)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                switch family {
                case .standard:
                    standardGrid
                case .photogrammetric:
                    photogrammetricList
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 620)
        .onAppear(perform: refreshInstalledWorlds)
        .sheet(isPresented: $showingCatalog) {
            MeshTileCatalogSheet(
                onClose: {
                    showingCatalog = false
                    refreshInstalledWorlds()
                }
            )
        }
    }

    // MARK: - Standard presets

    private var standardGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16)],
            spacing: 16
        ) {
            ForEach(availablePresets) { preset in
                MapPresetCard(
                    preset: preset,
                    isSelected: highlightedPreset == preset
                )
                .onTapGesture { highlightedPreset = preset }
                // A double-click is the familiar "pick and go" for a card grid; the footer
                // button remains for anyone who does not expect it.
                .onTapGesture(count: 2) { onConfirm(.standard(preset)) }
            }
        }
        .padding(20)
    }

    // MARK: - Photogrammetric worlds

    private var photogrammetricList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("map.real_geo.explainer")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if installedWorlds.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("map.real_geo.none_installed")
                        .foregroundStyle(.secondary)
                    Button("map.real_geo.browse") { showingCatalog = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 30)
            } else {
                ForEach(installedWorlds) { world in
                    InstalledWorldRow(world: world, isSelected: highlightedWorld == world)
                        .onTapGesture { highlightedWorld = world }
                        .onTapGesture(count: 2) {
                            onConfirm(.photogrammetric(tileKey: world.key, directory: world.directory))
                        }
                }
                Button("map.real_geo.browse") { showingCatalog = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(selectionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("map.select.cancel", action: onCancel)
            Button("map.select.confirm") {
                switch family {
                case .standard:
                    if let highlightedPreset { onConfirm(.standard(highlightedPreset)) }
                case .photogrammetric:
                    if let highlightedWorld {
                        onConfirm(.photogrammetric(tileKey: highlightedWorld.key,
                                                   directory: highlightedWorld.directory))
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasSelection)
        }
        .padding(16)
    }

    private var hasSelection: Bool {
        switch family {
        case .standard: return highlightedPreset != nil
        case .photogrammetric: return highlightedWorld != nil
        }
    }

    private var selectionSummary: String {
        switch family {
        case .standard:
            guard let highlightedPreset else { return L10n.s("map.select.prompt") }
            return NSLocalizedString(highlightedPreset.titleKey, comment: "")
        case .photogrammetric:
            guard let highlightedWorld else { return L10n.s("map.select.prompt_world") }
            return "\(highlightedWorld.key) — \(highlightedWorld.sizeBytes.formattedByteSize)"
        }
    }

    private func refreshInstalledWorlds() {
        let store = MeshTileStore()
        let source = MeshTileSource.helsinki2017
        store.refreshInstalled(source: source)
        installedWorlds = store.installedKeys.sorted().map { key in
            InstalledWorld(
                key: key,
                directory: store.tileDirectory(for: source, key: key),
                sizeBytes: store.installedBytes(source: source, key: key)
            )
        }
        if highlightedWorld == nil { highlightedWorld = installedWorlds.first }
    }
}

// MARK: - Cards

private struct MapPresetCard: View {
    let preset: TerrainPreset
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let image = MapCardArtwork.image(for: preset) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Until the artwork is supplied the card still has to be usable, so it falls
                    // back to a legible placeholder rather than an empty box.
                    MapCardArtwork.placeholder(for: preset)
                }
            }
            .frame(height: 150)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(preset.titleKey))
                    .font(.headline)
                Text(LocalizedStringKey(MapCardArtwork.descriptionKey(for: preset)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.18),
                              lineWidth: isSelected ? 3 : 1)
        )
    }
}

private struct InstalledWorldRow: View {
    let world: MapSelectionView.InstalledWorld
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe.europe.africa.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(world.key)
                    .font(.headline)
                Text(L10n.f("map.real_geo.row_detail", world.sizeBytes.formattedByteSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.18),
                              lineWidth: isSelected ? 3 : 1)
        )
    }
}

/// Card artwork, loaded from the app bundle by preset.
///
/// Deliberately file-based rather than an asset catalogue entry: these are screenshots of the
/// simulator's own presets, so they are expected to be replaced whenever a preset's look changes,
/// and dropping a new file in is less friction than editing a catalogue.
enum MapCardArtwork {
    /// Expected in the bundle as `map-card-<preset>.jpg` (or `.png`).
    static func image(for preset: TerrainPreset) -> NSImage? {
        let name = "map-card-\(preset.rawValue)"
        for ext in ["jpg", "jpeg", "png"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    static func descriptionKey(for preset: TerrainPreset) -> String {
        "map.card.description.\(preset.rawValue)"
    }

    @ViewBuilder
    static func placeholder(for preset: TerrainPreset) -> some View {
        LinearGradient(
            colors: placeholderColors(for: preset),
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.55))
        )
    }

    private static func placeholderColors(for preset: TerrainPreset) -> [Color] {
        switch preset {
        case .field:
            return [Color(red: 0.55, green: 0.72, blue: 0.35), Color(red: 0.36, green: 0.52, blue: 0.24)]
        case .forest:
            return [Color(red: 0.29, green: 0.49, blue: 0.28), Color(red: 0.16, green: 0.30, blue: 0.18)]
        case .cargoYard:
            return [Color(red: 0.48, green: 0.50, blue: 0.53), Color(red: 0.28, green: 0.30, blue: 0.33)]
        case .city:
            return [Color(red: 0.72, green: 0.60, blue: 0.40), Color(red: 0.42, green: 0.34, blue: 0.24)]
        case .gridDemo:
            return [Color(red: 0.30, green: 0.36, blue: 0.46), Color(red: 0.18, green: 0.22, blue: 0.30)]
        }
    }
}

/// Wraps the existing mesh browser so a world can be downloaded without leaving map selection.
private struct MeshTileCatalogSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            UAVWorldMeshBrowserView()
            Divider()
            HStack {
                Spacer()
                Button("map.real_geo.done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 1000, minHeight: 680)
    }
}
