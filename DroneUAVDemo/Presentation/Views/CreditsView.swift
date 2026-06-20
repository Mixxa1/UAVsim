import SwiftUI

private struct ThirdPartyAsset: Decodable, Identifiable {
    let id: String
    let title: String
    let author: String
    let sourceURL: String
    let licenseName: String
    let licenseURL: String
    let changes: String
}

private struct ThirdPartyAssetsFile: Decodable {
    let assets: [ThirdPartyAsset]
}

struct CreditsView: View {
    private let assets: [ThirdPartyAsset] = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyAssets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ThirdPartyAssetsFile.self, from: data) else {
            return []
        }
        return file.assets
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey("credits.third_party_assets"))
                .font(.headline)
                .padding(.bottom, 12)

            if assets.isEmpty {
                Text("No assets listed.")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(assets) { asset in
                            assetRow(asset)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 320)
    }

    @ViewBuilder
    private func assetRow(_ asset: ThirdPartyAsset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(asset.title)
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(alignment: .top, spacing: 4) {
                Text("credits.author", tableName: nil, bundle: nil, comment: "")
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(asset.author)
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 4) {
                Text("credits.license", tableName: nil, bundle: nil, comment: "")
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                if let url = URL(string: asset.licenseURL) {
                    Link(asset.licenseName, destination: url)
                } else {
                    Text(asset.licenseName)
                }
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 4) {
                Text("credits.source", tableName: nil, bundle: nil, comment: "")
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                if let url = URL(string: asset.sourceURL) {
                    Link(asset.sourceURL, destination: url)
                } else {
                    Text(asset.sourceURL)
                }
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 4) {
                Text("credits.changes", tableName: nil, bundle: nil, comment: "")
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(asset.changes)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        Divider()
    }
}
