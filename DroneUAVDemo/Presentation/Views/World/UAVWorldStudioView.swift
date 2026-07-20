import SwiftUI

/// Single home for real-world map building.
///
/// The two paths belong side by side because they answer the same question with different data,
/// and choosing between them is the user's main decision. Building from open vector data works
/// anywhere on Earth but invents facades and, where a region is thinly mapped, heights too.
/// A photogrammetric mesh is genuinely photographic but exists only where a city has published
/// one and costs gigabytes per tile. Seeing both in one window makes that trade concrete —
/// Helsinki can be built either way and compared street for street.
struct UAVWorldStudioView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case openData
        case photogrammetry

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .openData:
                return "world.studio.mode.open_data"
            case .photogrammetry:
                return "world.studio.mode.photogrammetry"
            }
        }
    }

    @State private var mode: Mode = .openData

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            // Both are kept alive rather than swapped out: rebuilding the mesh browser would drop
            // a loaded tile and its streaming cache, and rebuilding the map builder would discard
            // an import the user just waited for.
            ZStack {
                UAVWorldPreviewView()
                    .opacity(mode == .openData ? 1 : 0)
                    .allowsHitTesting(mode == .openData)
                UAVWorldMeshBrowserView()
                    .opacity(mode == .photogrammetry ? 1 : 0)
                    .allowsHitTesting(mode == .photogrammetry)
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
    }
}
