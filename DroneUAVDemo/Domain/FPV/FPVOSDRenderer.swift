import Foundation
import SpriteKit

struct FPVOSDComposer {
    func compose(
        state: FPVOSDState,
        layout: OSDLayout,
        symbolMap: FPVOSDSymbolMap = .betaflight
    ) -> OSDGrid {
        var grid = OSDGrid(columns: layout.columns, rows: layout.rows)
        place("BAT \(number(state.voltage, decimals: 1))V", at: layout.battery, in: &grid)
        place("BAT \(integer(state.batteryPercent))%", at: layout.batteryPercent, in: &grid)
        place("LQ \(integer(state.linkQuality))", at: layout.linkQuality, in: &grid)

        let radio = "R\(integer(state.rssi)) S\(integer(state.snr))"
        place(radio, at: layout.radioDetail, in: &grid)
        placeArtificialHorizon(state: state, at: layout.reticle, symbols: symbolMap, in: &grid)
        placeAircraftReference(at: layout.reticle, symbols: symbolMap, in: &grid)
        place("ALT \(integer(state.altitude))m", at: layout.altitude, in: &grid)
        place("SPD \(number(state.speed, decimals: 1))", at: layout.speed, in: &grid)
        place("GPS \(integer(state.satellites))", at: layout.satellites, in: &grid)

        let armCode = state.armed ? "ARM" : "DIS"
        place("\(armCode) \(state.flightMode.rawValue)", at: layout.flightMode, in: &grid)

        switch state.linkState {
        case .excellent, .good:
            break
        case .degraded:
            placeCentered("LINK", at: layout.linkWarning, in: &grid)
        case .critical:
            placeCentered("LINK LOW", at: layout.linkWarning, in: &grid)
        case .lost:
            placeCentered("LINK LOST", at: layout.linkWarning, in: &grid)
        }
        if state.containsStaleData {
            placeCentered("DATA STALE", at: layout.staleWarning, in: &grid)
        }
        return grid
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
        in grid: inout OSDGrid
    ) {
        let centerX = position.x + position.width / 2
        grid[centerX - 1, position.y] = symbols.artificialHorizonCenterLine
        grid[centerX, position.y] = symbols.artificialHorizonCenter
        grid[centerX + 1, position.y] = symbols.artificialHorizonCenterLineRight
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

    private func place(_ text: String, at position: OSDPosition, in grid: inout OSDGrid) {
        grid.write(
            text,
            x: position.x,
            y: position.y,
            width: position.width,
            rightAligned: position.rightAligned
        )
    }

    private func placeCentered(_ text: String, at position: OSDPosition, in grid: inout OSDGrid) {
        let clippedCount = min(position.width, text.utf8.count)
        let centeredX = position.x + max(0, (position.width - clippedCount) / 2)
        grid.write(text, x: centeredX, y: position.y, width: clippedCount)
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
        layout: OSDLayout,
        viewportSize: CGSize
    ) {
        let size = CGSize(width: max(1, viewportSize.width), height: max(1, viewportSize.height))
        if scene.size != size { scene.size = size }
        prepareNodes(columns: layout.columns, rows: layout.rows)
        let grid = composer.compose(state: state, layout: layout, symbolMap: fontAtlas.symbolMap)

        let horizontalInset = size.width * 0.035
        let verticalInset = size.height * 0.045
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
