import SwiftUI

/// Compact aircraft "dossier" card shared by Mission Setup's platform picker and the sidebar UAV
/// Catalog module — live 3D preview on top, name/manufacturer, a handful of headline specs, and a
/// confidence/custom badge. Deliberately presentation-only (plain values in, no `DroneModelProfile`
/// or `UAVCatalogEntry` coupling) so both screens can feed it from their own domain types.
///
/// `expandedContent` is appended inside the SAME card box, only meant to be non-empty for the
/// currently-selected card (see `UAVCatalogView`'s `UAVProfileExtraSpecsView` usage) — keeps the
/// extra detail visually part of one card rather than a disconnected panel below it.
struct UAVSelectionCardView<ExpandedContent: View>: View {
    let name: String
    let manufacturer: String?
    let previewProfile: UAVProfile?
    let runtimePreviewProfile: DroneModelProfile?
    let massKg: Float?
    let speedMps: Float?
    let flightTimeSec: Float?
    let rangeMeters: Float?
    let badgeText: String
    let badgeTint: Color
    let isSelected: Bool
    @ViewBuilder var expandedContent: () -> ExpandedContent

    init(
        name: String,
        manufacturer: String?,
        previewProfile: UAVProfile?,
        runtimePreviewProfile: DroneModelProfile? = nil,
        massKg: Float?,
        speedMps: Float?,
        flightTimeSec: Float?,
        rangeMeters: Float?,
        badgeText: String,
        badgeTint: Color,
        isSelected: Bool,
        @ViewBuilder expandedContent: @escaping () -> ExpandedContent = { EmptyView() }
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.previewProfile = previewProfile
        self.runtimePreviewProfile = runtimePreviewProfile
        self.massKg = massKg
        self.speedMps = speedMps
        self.flightTimeSec = flightTimeSec
        self.rangeMeters = rangeMeters
        self.badgeText = badgeText
        self.badgeTint = badgeTint
        self.isSelected = isSelected
        self.expandedContent = expandedContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UAVLivePreviewView(profile: previewProfile, runtimeProfile: runtimePreviewProfile)
                .frame(height: 108)
                .background(GroundControlPalette.shell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    badge
                }

                if let manufacturer {
                    Text(manufacturer)
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let massKg {
                        specRow(String(format: "%.1f kg", massKg))
                    }
                    if let speedMps {
                        specRow(String(format: "%.0f km/h", speedMps * 3.6))
                    }
                    if let flightTimeSec, flightTimeSec > 0 {
                        specRow(String(format: "%.0f min", flightTimeSec / 60.0))
                    }
                    if let rangeMeters, rangeMeters > 0 {
                        specRow(rangeMeters >= 1000
                            ? String(format: "%.1f km", rangeMeters / 1000.0)
                            : String(format: "%.0f m", rangeMeters))
                    }
                }
                .padding(.top, 2)
            }

            expandedContent()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? GroundControlPalette.accent.opacity(0.65) : GroundControlPalette.border, lineWidth: 1.0)
        )
    }

    private func specRow(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(GroundControlPalette.textSecondary)
    }

    private var badge: some View {
        Text(badgeText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(badgeTint.opacity(0.18)))
            .foregroundStyle(badgeTint)
    }
}
