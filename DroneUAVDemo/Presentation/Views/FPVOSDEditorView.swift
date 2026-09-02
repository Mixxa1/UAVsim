import AppKit
import CoreGraphics
import SwiftUI

/// Operator-facing OSD editor.
///
/// Everything here is expressed in semantic elements — "battery voltage", "link quality" — never
/// in MAX7456 character indices, and every preview pixel comes from the selected font's real
/// atlas through the same composer the analog compositor uses. An element the installed
/// equipment cannot feed is shown disabled with the reason rather than silently dropped.
struct FPVOSDEditorView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedElement: OSDElement?
    @State private var dragAnchor: (x: Int, y: Int)?
    @State private var atlases: [FPVFontPreset: FPVFontAtlas] = [:]
    @State private var failedFonts: Set<FPVFontPreset> = []

    private var layout: OSDLayoutConfiguration { viewModel.osdLayout }
    private var availability: OSDElementAvailability { viewModel.osdElementAvailability }
    private var activeAtlas: FPVFontAtlas? { atlases[viewModel.fpvFontPreset] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            HStack(alignment: .top, spacing: 0) {
                fontColumn
                Divider().overlay(Color.white.opacity(0.08))
                previewColumn
                Divider().overlay(Color.white.opacity(0.08))
                elementColumn
            }
        }
        .frame(minWidth: 1040, idealWidth: 1120, minHeight: 620, idealHeight: 680)
        .background(GroundControlPalette.panel)
        .task { loadAtlas(viewModel.fpvFontPreset) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("osd.editor.title")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text("osd.editor.subtitle")
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            Spacer(minLength: 12)

            Button("osd.editor.done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Fonts

    private var fontColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("osd.editor.section.font")

                ForEach(FPVFontPreset.allCases) { preset in
                    fontRow(preset)
                        .task { loadAtlas(preset) }
                }
            }
            .padding(14)
        }
        .frame(width: 264)
    }

    private func fontRow(_ preset: FPVFontPreset) -> some View {
        let isSelected = viewModel.fpvFontPreset == preset
        let failed = failedFonts.contains(preset)
        return Button {
            guard !failed else { return }
            viewModel.setFPVFontPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(preset.titleKey))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(GroundControlPalette.accent)
                    }
                }

                if failed {
                    Text("osd.editor.font_failed")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.danger)
                } else if let atlas = atlases[preset] {
                    glyphStrip(text: "BAT 16.8V LQ100", atlas: atlas, cellHeight: 17)
                } else {
                    Text("osd.editor.font_loading")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? GroundControlPalette.accent.opacity(0.16)
                          : GroundControlPalette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected
                            ? GroundControlPalette.accent.opacity(0.7)
                            : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// A single line of real glyphs from the given font.
    private func glyphStrip(text: String, atlas: FPVFontAtlas, cellHeight: CGFloat) -> some View {
        let glyphs = text.utf8.map { OSDGlyphIndex($0 < 128 ? $0 : 63) }
        let cellWidth = cellHeight * CGFloat(FPVGlyphBitmap.width) / CGFloat(FPVGlyphBitmap.height)
        return HStack(spacing: 0) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                if glyph == 32 {
                    Color.clear.frame(width: cellWidth, height: cellHeight)
                } else if let image = atlas.glyphImage(for: glyph) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: cellWidth, height: cellHeight)
                } else {
                    Color.clear.frame(width: cellWidth, height: cellHeight)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
    }

    // MARK: Preview / grid editor

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("osd.editor.section.grid")
            Text("osd.editor.grid_hint")
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geometry in
                let frame = previewFrame(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    gridLines(frame: frame)
                    composedPreview(frame: frame)
                    elementHandles(frame: frame)
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            if let selectedElement {
                selectedElementControls(selectedElement)
            } else {
                Text("osd.editor.no_selection")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(height: 42, alignment: .center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
    }

    /// The grid keeps the character cell's own 12:18 aspect, so the preview's proportions match
    /// what the compositor draws into the 720x480 analog frame.
    private func previewFrame(in available: CGSize) -> CGSize {
        let aspect = CGFloat(layout.columns * FPVGlyphBitmap.width)
            / CGFloat(max(1, layout.rows * FPVGlyphBitmap.height))
        let byWidth = CGSize(width: available.width, height: available.width / aspect)
        if byWidth.height <= available.height { return byWidth }
        return CGSize(width: available.height * aspect, height: available.height)
    }

    private func gridLines(frame: CGSize) -> some View {
        Canvas { context, size in
            let cellWidth = size.width / CGFloat(layout.columns)
            let cellHeight = size.height / CGFloat(layout.rows)
            var path = Path()
            for column in 1..<layout.columns {
                let x = CGFloat(column) * cellWidth
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1..<layout.rows {
                let y = CGFloat(row) * cellHeight
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.055)), lineWidth: 0.5)
        }
        .frame(width: frame.width, height: frame.height)
    }

    private func composedPreview(frame: CGSize) -> some View {
        Group {
            if let atlas = activeAtlas,
               let image = OSDPreviewRasterizer.image(
                   grid: FPVOSDComposer().compose(
                       state: Self.sampleState,
                       layout: layout,
                       availability: availability,
                       symbolMap: atlas.symbolMap,
                       blankGlyphs: atlas.blankGlyphs
                   ),
                   atlas: atlas
               ) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: frame.width, height: frame.height)
            } else {
                Color.clear.frame(width: frame.width, height: frame.height)
            }
        }
    }

    private func elementHandles(frame: CGSize) -> some View {
        let cellWidth = frame.width / CGFloat(layout.columns)
        let cellHeight = frame.height / CGFloat(layout.rows)
        return ForEach(OSDElement.allCases) { element in
            let placement = layout.placement(for: element)
            if placement.isEnabled, availability.isAvailable(element) {
                let isSelected = selectedElement == element
                Rectangle()
                    .fill(isSelected
                          ? GroundControlPalette.accent.opacity(0.20)
                          : Color.white.opacity(0.001))
                    .overlay(
                        Rectangle().stroke(
                            isSelected
                                ? GroundControlPalette.accent
                                : Color.white.opacity(0.18),
                            lineWidth: isSelected ? 1.4 : 0.6
                        )
                    )
                    .frame(
                        width: CGFloat(placement.width) * cellWidth,
                        height: cellHeight
                    )
                    .offset(
                        x: CGFloat(placement.x) * cellWidth,
                        y: CGFloat(placement.y) * cellHeight
                    )
                    .gesture(dragGesture(
                        for: element,
                        cellWidth: cellWidth,
                        cellHeight: cellHeight
                    ))
                    .onTapGesture { selectedElement = element }
            }
        }
    }

    private func dragGesture(
        for element: OSDElement,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if selectedElement != element { selectedElement = element }
                let anchor: (x: Int, y: Int)
                if let dragAnchor {
                    anchor = dragAnchor
                } else {
                    let placement = layout.placement(for: element)
                    anchor = (placement.x, placement.y)
                    dragAnchor = anchor
                }
                let deltaX = Int((value.translation.width / max(1, cellWidth)).rounded())
                let deltaY = Int((value.translation.height / max(1, cellHeight)).rounded())
                viewModel.moveOSDElement(
                    element,
                    toX: anchor.x + deltaX,
                    y: anchor.y + deltaY
                )
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private func selectedElementControls(_ element: OSDElement) -> some View {
        let placement = layout.placement(for: element)
        return HStack(spacing: 12) {
            Text(LocalizedStringKey(element.titleKey))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)

            Text(String(format: "X %d  Y %d", placement.x, placement.y))
                .font(.caption2.monospaced())
                .foregroundStyle(GroundControlPalette.textSecondary)

            if !element.isGraphical {
                Toggle("osd.editor.right_aligned", isOn: Binding(
                    get: { placement.rightAligned },
                    set: { viewModel.setOSDElementRightAligned($0, for: element) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption2)
            }

            Spacer(minLength: 4)

            Button("osd.editor.hide_element") {
                viewModel.setOSDElementEnabled(false, for: element)
                selectedElement = nil
            }
            .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 7).fill(GroundControlPalette.panelRaised))
    }

    // MARK: Elements and presets

    private var elementColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("osd.editor.section.presets")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(OSDLayoutPreset.allCases) { preset in
                        Button {
                            viewModel.applyOSDPreset(preset)
                            selectedElement = nil
                        } label: {
                            Text(LocalizedStringKey(preset.titleKey))
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                sectionTitle("osd.editor.section.crosshair")
                Picker("", selection: Binding(
                    get: { layout.resolvedCrosshairStyle },
                    set: { viewModel.setOSDCrosshairStyle($0) }
                )) {
                    ForEach(OSDCrosshairStyle.allCases) { style in
                        Text(LocalizedStringKey(style.titleKey)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("osd.editor.crosshair_hint")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                sectionTitle("osd.editor.section.elements")
                ForEach(OSDElementGroup.allCases) { group in
                    let elements = OSDElement.allCases.filter { $0.group == group }
                    if !elements.isEmpty {
                        Text(LocalizedStringKey(group.titleKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                            .padding(.top, 2)
                        ForEach(elements) { element in
                            elementRow(element)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 300)
    }

    private func elementRow(_ element: OSDElement) -> some View {
        let isAvailable = availability.isAvailable(element)
        let reasonKey = availability.unavailableReasonKey(for: element)
        let missingGlyphs = isAvailable && missesGlyphs(element)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { isAvailable && layout.isEnabled(element) },
                set: { viewModel.setOSDElementEnabled($0, for: element) }
            )) {
                Text(LocalizedStringKey(element.titleKey))
                    .font(.caption)
                    .foregroundStyle(isAvailable
                                     ? GroundControlPalette.textPrimary
                                     : GroundControlPalette.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!isAvailable)

            if let reasonKey {
                Text(LocalizedStringKey(reasonKey))
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if missingGlyphs {
                Text("osd.editor.font_missing_glyphs")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if isAvailable, layout.isEnabled(element) { selectedElement = element }
        }
    }

    /// Flags only an element the font genuinely cannot draw.
    ///
    /// An empty side slot is not a defect: several fonts ship a deliberately light crosshair that
    /// fills the centre cell alone — Mainframe's own description calls it "a very light crosshair
    /// design" — and treating that as a broken font was simply wrong. Only a missing centre
    /// glyph, or a horizon with no bars at all, leaves nothing on screen.
    private func missesGlyphs(_ element: OSDElement) -> Bool {
        guard let atlas = activeAtlas else { return false }
        switch element {
        case .aircraftReference:
            return atlas.isGlyphBlank(atlas.symbolMap.artificialHorizonCenter)
        case .artificialHorizon:
            return (0..<atlas.symbolMap.artificialHorizonSymbolCount).allSatisfy {
                atlas.isGlyphBlank(atlas.symbolMap.artificialHorizonBarStart + OSDGlyphIndex($0))
            }
        default:
            return false
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(GroundControlPalette.textSecondary)
            .textCase(.uppercase)
    }

    private func loadAtlas(_ preset: FPVFontPreset) {
        guard atlases[preset] == nil, !failedFonts.contains(preset) else { return }
        do {
            atlases[preset] = try FPVFontAtlasStore.shared.atlas(for: preset)
        } catch {
            failedFonts.insert(preset)
        }
    }

    /// Representative values, with the link deliberately degraded and one reading stale so the
    /// warning elements are visible while they are being positioned.
    private static let sampleState = FPVOSDState(
        voltage: .stale(16.8),
        batteryPercent: .live(78),
        rssi: .live(-72),
        linkQuality: .live(64),
        snr: .live(39),
        altitude: .live(156),
        speed: .live(12.4),
        satellites: .live(14),
        rollDegrees: .live(-9),
        pitchDegrees: .live(4),
        headingDegrees: .live(284),
        throttlePercent: .live(46),
        distanceToHome: .live(432),
        flightDistance: .live(653),
        flightSeconds: .live(252),
        armed: true,
        flightMode: .angle,
        linkState: .degraded
    )
}

/// Rasterizes a composed grid at the font's native cell size. Displayed with nearest-neighbour
/// scaling, so the preview stays as crisp as the character generator it imitates.
enum OSDPreviewRasterizer {
    static func image(grid: OSDGrid, atlas: FPVFontAtlas) -> CGImage? {
        let cellWidth = FPVGlyphBitmap.width
        let cellHeight = FPVGlyphBitmap.height
        let width = grid.columns * cellWidth
        let height = grid.rows * cellHeight
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .none
        for cell in grid.cells where cell.glyph != 32 {
            guard let glyph = atlas.glyphImage(for: cell.glyph) else { continue }
            context.draw(glyph, in: CGRect(
                x: cell.x * cellWidth,
                // CGContext counts rows from the bottom; the grid counts them from the top.
                y: height - (cell.y + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            ))
        }
        return context.makeImage()
    }
}
