import Foundation
import SpriteKit

struct FPVOSDComposer {
    func compose(
        state: FPVOSDState,
        layout: OSDLayoutConfiguration,
        availability: OSDElementAvailability = .all,
        symbolMap: FPVOSDSymbolMap = .betaflight,
        blankGlyphs: Set<UInt8> = []
    ) -> OSDGrid {
        var grid = OSDGrid(columns: layout.columns, rows: layout.rows)
        for entry in layout.orderedPlacements(availability: availability) {
            let position = OSDPosition(
                x: entry.placement.x,
                y: entry.placement.y,
                width: entry.placement.width,
                rightAligned: entry.placement.rightAligned
            )
            switch entry.element {
            case .artificialHorizon:
                placeArtificialHorizon(state: state, at: position, symbols: symbolMap, in: &grid)
            case .aircraftReference:
                placeAircraftReference(
                    at: position,
                    symbols: symbolMap,
                    style: layout.resolvedCrosshairStyle,
                    in: &grid
                )
            case .artificialHorizonSidebars:
                placeHorizonSidebars(at: position, symbols: symbolMap, in: &grid)
            case .compassRibbon:
                placeCompassRibbon(state: state, at: position, in: &grid)
            default:
                guard let run = glyphs(
                    for: entry.element,
                    state: state,
                    symbols: symbolMap,
                    blankGlyphs: blankGlyphs
                ) else { continue }
                if entry.element.isCentred {
                    placeCentered(run, at: position, in: &grid)
                } else {
                    place(run, at: position, in: &grid)
                }
            }
        }
        return grid
    }

    /// Builds the glyph run for one element.
    ///
    /// Labels and units are MAX7456 pictograms rather than spelled-out ASCII — the battery,
    /// "LQ" with its bars, "ALT", the metre mark, the home pin — which is what gives a real
    /// analog OSD its look and lets each font style the same layout its own way. A font that
    /// ever leaves one of those slots empty falls back to a text label instead of a blank cell.
    /// Returns nil when the element has nothing to say this frame — a healthy link posts no link
    /// warning, and fresh data posts no stale warning.
    func glyphs(
        for element: OSDElement,
        state: FPVOSDState,
        symbols: FPVOSDSymbolMap,
        blankGlyphs: Set<UInt8>
    ) -> [UInt8]? {
        func icon(_ glyph: UInt8, fallback: String) -> [UInt8] {
            blankGlyphs.contains(glyph) ? ascii(fallback) : [glyph]
        }

        switch element {
        case .batteryVoltage:
            return batteryIcon(state: state, symbols: symbols, blankGlyphs: blankGlyphs)
                + ascii(number(state.voltage, decimals: 1))
                + icon(symbols.voltIcon, fallback: "V")
        case .batteryCapacity:
            // Deliberately not a second battery label: voltage and remaining capacity are
            // different readings, and labelling both the same way made the rows look duplicated.
            return ascii("CAP \(integer(state.batteryPercent))%")
        case .linkQuality:
            return icon(symbols.linkQualityIcon, fallback: "LQ ")
                + ascii(integer(state.linkQuality))
        case .rssi:
            return icon(symbols.rssiIcon, fallback: "RSSI ") + ascii(integer(state.rssi))
        case .snr:
            return ascii("SNR \(integer(state.snr))")
        case .altitude:
            return icon(symbols.altitudeIcon, fallback: "ALT ")
                + ascii(integer(state.altitude))
                + icon(symbols.metreIcon, fallback: "M")
        case .speed:
            return ascii(number(state.speed, decimals: 1))
                + icon(symbols.metresPerSecondIcon, fallback: " M/S")
        case .satellites:
            return icon(symbols.satelliteLeftIcon, fallback: "G")
                + icon(symbols.satelliteRightIcon, fallback: "PS ")
                + ascii(integer(state.satellites))
        case .flightMode:
            return ascii("\(state.armed ? "ARM" : "DIS") \(state.flightMode.rawValue)")
        case .linkWarning:
            switch state.linkState {
            case .excellent, .good: return nil
            case .degraded: return ascii("LINK")
            case .critical: return ascii("LINK LOW")
            case .lost: return ascii("LINK LOST")
            }
        case .staleWarning:
            return state.containsStaleData ? ascii("DATA STALE") : nil
        case .heading:
            return ascii("HDG \(integer(state.headingDegrees))")
        case .throttle:
            return icon(symbols.throttleIcon, fallback: "THR ")
                + ascii("\(integer(state.throttlePercent))%")
        case .distanceToHome:
            return homeArrowIcon(state: state, symbols: symbols, blankGlyphs: blankGlyphs)
                + icon(symbols.homeIcon, fallback: "HOME ")
                + ascii(integer(state.distanceToHome))
                + icon(symbols.metreIcon, fallback: "M")
        case .flightDistance:
            return ascii("DST \(integer(state.flightDistance))")
                + icon(symbols.metreIcon, fallback: "M")
        case .flightTimer:
            let text: String
            if let seconds = state.flightSeconds.value, seconds.isFinite, seconds >= 0 {
                let whole = Int(seconds)
                text = String(format: "%02d:%02d", whole / 60, whole % 60)
            } else {
                text = "--:--"
            }
            return icon(symbols.flightTimerIcon, fallback: "TIM ") + ascii(text)
        case .artificialHorizon, .aircraftReference, .artificialHorizonSidebars, .compassRibbon:
            return nil
        }
    }

    /// Betaflight's sidebars: a short ladder of ticks either side of the horizon centre with a
    /// level arrow on each. Column offset and half-height match upstream's AH_SIDEBAR constants.
    private func placeHorizonSidebars(
        at position: OSDPosition,
        symbols: FPVOSDSymbolMap,
        in grid: inout OSDGrid
    ) {
        let centerX = position.x + position.width / 2
        let centerY = position.y
        let columnOffset = 7
        let halfHeight = 3
        for row in (centerY - halfHeight)...(centerY + halfHeight) {
            grid[centerX - columnOffset, row] = symbols.sidebarTick
            grid[centerX + columnOffset, row] = symbols.sidebarTick
        }
        // Arrows point inward, toward the horizon. Betaflight's own naming reads the other way
        // round (SYM_AH_LEFT on the left sidebar), but that glyph is the one whose apex faces
        // left, which puts both arrows pointing away from the aircraft reference.
        grid[centerX - columnOffset, centerY] = symbols.sidebarRightArrow
        grid[centerX + columnOffset, centerY] = symbols.sidebarLeftArrow
    }

    /// Heading ribbon. Cardinal letters land on the cell whose bearing they fall in, and the
    /// remaining cells carry a light tick — deliberately built from plain ASCII so it renders in
    /// every bundled font rather than depending on font-specific ribbon artwork.
    private func placeCompassRibbon(
        state: FPVOSDState,
        at position: OSDPosition,
        in grid: inout OSDGrid
    ) {
        guard let heading = state.headingDegrees.value, heading.isFinite else { return }
        let width = max(1, position.width)
        let visibleSpanDegrees = 180.0
        let degreesPerCell = visibleSpanDegrees / Double(width)
        let cardinals: [(bearing: Double, glyph: UInt8)] = [
            (0, 78),    // N
            (90, 69),   // E
            (180, 83),  // S
            (270, 87),  // W
        ]
        for column in 0..<width {
            let offsetFraction = (Double(column) + 0.5) / Double(width) - 0.5
            let bearing = heading + offsetFraction * visibleSpanDegrees
            let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
            var glyph: UInt8 = column.isMultiple(of: 2) ? 46 : 32
            for cardinal in cardinals {
                var delta = abs(normalized - cardinal.bearing)
                if delta > 180 { delta = 360 - delta }
                if delta <= degreesPerCell / 2 { glyph = cardinal.glyph }
            }
            grid[position.x + column, position.y] = glyph
        }
    }

    /// Betaflight-compatible character-grid artificial horizon. The MCM stores nine sub-cell
    /// horizontal bar glyphs (0x80...0x88); roll chooses a different vertical position for each
    /// of nine columns and pitch moves the complete horizon up/down. The aircraft reference stays
    /// fixed, exactly as it does on a real MAX7456 OSD.
    private func placeArtificialHorizon(
        state: FPVOSDState,
        at position: OSDPosition,
        symbols: FPVOSDSymbolMap,
        in grid: inout OSDGrid
    ) {
        guard let roll = state.rollDegrees.value,
              let pitch = state.pitchDegrees.value,
              roll.isFinite,
              pitch.isFinite else { return }

        let maxRollDegrees = 40.0
        let maxPitchDegrees = 20.0
        let rollDecidegrees = Int((min(max(roll, -maxRollDegrees), maxRollDegrees) * 10).rounded())
        // Betaflight's pitch convention is positive nose-down; UAVsim is positive nose-up.
        let betaflightPitchDecidegrees = Int((
            -min(max(pitch, -maxPitchDegrees), maxPitchDegrees) * 10
        ).rounded())
        var pitchSubcellOffset = (betaflightPitchDecidegrees * 25) / Int(maxPitchDegrees * 10)
        pitchSubcellOffset -= 41

        let centerX = position.x + position.width / 2
        let anchorY = position.y - 4
        for xOffset in -4...4 {
            let y = ((-rollDecidegrees * xOffset) / 64) - pitchSubcellOffset
            guard y >= 0, y <= 81 else { continue }
            let row = anchorY + y / symbols.artificialHorizonSymbolCount
            guard row >= 0, row < grid.rows else { continue }
            grid[centerX + xOffset, row] = symbols.artificialHorizonBarStart
                + UInt8(y % symbols.artificialHorizonSymbolCount)
        }
    }

    private func placeAircraftReference(
        at position: OSDPosition,
        symbols: FPVOSDSymbolMap,
        style: OSDCrosshairStyle,
        in grid: inout OSDGrid
    ) {
        let centerX = position.x + position.width / 2
        let sides: (left: UInt8, right: UInt8)
        switch style {
        case .standard:
            sides = (symbols.artificialHorizonCenterLine, symbols.artificialHorizonCenterLineRight)
        case .aircraft:
            sides = (symbols.aircraftWingLeft, symbols.aircraftWingRight)
        }
        grid[centerX - 1, position.y] = sides.left
        grid[centerX, position.y] = symbols.artificialHorizonCenter
        grid[centerX + 1, position.y] = sides.right
    }

    private func number(_ value: TelemetryValue<Double>, decimals: Int) -> String {
        guard let value = value.value, value.isFinite else { return "---" }
        return String(format: "%.*f", decimals, value)
    }

    private func integer(_ value: TelemetryValue<Double>) -> String {
        guard let value = value.value, value.isFinite else { return "---" }
        return String(format: "%.0f", value)
    }

    private func integer(_ value: TelemetryValue<Int>) -> String {
        value.value.map(String.init) ?? "---"
    }

    private func ascii(_ text: String) -> [UInt8] {
        text.utf8.map { $0 < 128 ? $0 : 63 }
    }

    /// Battery pictogram chosen by remaining capacity, full first — the same seven-step ramp
    /// Betaflight uses. Without a reading it falls back to the empty end rather than guessing.
    private func batteryIcon(
        state: FPVOSDState,
        symbols: FPVOSDSymbolMap,
        blankGlyphs: Set<UInt8>
    ) -> [UInt8] {
        guard symbols.batteryLevelCount > 0,
              !blankGlyphs.contains(symbols.batteryLevelStart) else {
            return ascii("BAT ")
        }
        let steps = symbols.batteryLevelCount
        guard let percent = state.batteryPercent.value, percent.isFinite else {
            return [symbols.batteryLevelStart + UInt8(steps - 1)]
        }
        let fraction = min(1, max(0, percent / 100))
        let index = Int(((1 - fraction) * Double(steps - 1)).rounded())
        return [symbols.batteryLevelStart + UInt8(min(steps - 1, max(0, index)))]
    }

    /// One of sixteen arrows pointing at home, relative to the nose. Index 8 is straight ahead
    /// and the ramp runs anticlockwise, matching the order the glyphs sit in the font.
    private func homeArrowIcon(
        state: FPVOSDState,
        symbols: FPVOSDSymbolMap,
        blankGlyphs: Set<UInt8>
    ) -> [UInt8] {
        guard let bearing = state.homeBearingDegrees.value, bearing.isFinite,
              !blankGlyphs.contains(symbols.directionArrowStart) else {
            return []
        }
        let step = (bearing / 22.5).rounded()
        let index = (8 - Int(step)) & 15
        return [symbols.directionArrowStart + UInt8(index)]
    }

    private func place(_ run: [UInt8], at position: OSDPosition, in grid: inout OSDGrid) {
        grid.write(
            glyphs: run,
            x: position.x,
            y: position.y,
            width: position.width,
            rightAligned: position.rightAligned
        )
    }

    private func placeCentered(_ run: [UInt8], at position: OSDPosition, in grid: inout OSDGrid) {
        let clippedCount = min(position.width, run.count)
        let centeredX = position.x + max(0, (position.width - clippedCount) / 2)
        grid.write(glyphs: run, x: centeredX, y: position.y, width: clippedCount)
    }
}

/// SpriteKit renderer attached directly to `SCNView.overlaySKScene`. It intentionally owns a fixed
/// pool of 30×16 sprite nodes: rendering a new telemetry sample changes textures/visibility only,
/// with no per-frame node allocation and no pre-rendered state images.
final class FPVOSDRenderer {
    let scene: SKScene

    private let composer = FPVOSDComposer()
    private var glyphNodes: [SKSpriteNode] = []
    private var currentGridShape: (columns: Int, rows: Int)?

    init() {
        scene = SKScene(size: CGSize(width: 1, height: 1))
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.isUserInteractionEnabled = false
    }

    func render(
        state: FPVOSDState,
        fontAtlas: FPVFontAtlas,
        layout: OSDLayoutConfiguration,
        availability: OSDElementAvailability = .all,
        viewportSize: CGSize
    ) {
        let size = CGSize(width: max(1, viewportSize.width), height: max(1, viewportSize.height))
        if scene.size != size { scene.size = size }
        prepareNodes(columns: layout.columns, rows: layout.rows)
        let grid = composer.compose(
            state: state,
            layout: layout,
            availability: availability,
            symbolMap: fontAtlas.symbolMap,
            blankGlyphs: fontAtlas.blankGlyphs
        )

        let horizontalInset = size.width * CGFloat(layout.horizontalMarginFraction)
        let verticalInset = size.height * CGFloat(layout.verticalMarginFraction)
        let gridWidth = max(1, size.width - horizontalInset * 2)
        let gridHeight = max(1, size.height - verticalInset * 2)
        let cellWidth = gridWidth / CGFloat(layout.columns)
        let cellHeight = gridHeight / CGFloat(layout.rows)

        for cell in grid.cells {
            let index = cell.y * layout.columns + cell.x
            let node = glyphNodes[index]
            node.position = CGPoint(
                x: horizontalInset + (CGFloat(cell.x) + 0.5) * cellWidth,
                y: size.height - verticalInset - (CGFloat(cell.y) + 0.5) * cellHeight
            )
            node.size = CGSize(width: cellWidth, height: cellHeight)
            node.isHidden = cell.glyph == 32
            if !node.isHidden {
                node.texture = fontAtlas.texture(for: cell.glyph)
                node.texture?.filteringMode = .nearest
            }
        }
    }

    private func prepareNodes(columns: Int, rows: Int) {
        guard currentGridShape?.columns != columns
                || currentGridShape?.rows != rows
                || glyphNodes.count != columns * rows else { return }
        scene.removeAllChildren()
        glyphNodes = (0..<(columns * rows)).map { _ in
            let node = SKSpriteNode()
            node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            node.color = .clear
            node.colorBlendFactor = 0
            node.blendMode = .alpha
            node.zPosition = 100
            scene.addChild(node)
            return node
        }
        currentGridShape = (columns, rows)
    }
}
