import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InterfaceScaleContainer<Content: View>: View {
    @AppStorage(AppGraphicsSettings.interfaceScaleKey) private var storedScale = 1.0
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { proxy in
            let scale = min(1.5, max(0.75, storedScale.isFinite ? storedScale : 1))
            let width = max(1080, proxy.size.width / scale)
            let height = max(720, proxy.size.height / scale)
            ScrollView([.horizontal, .vertical]) {
                content().frame(width: width, height: height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: height * scale, alignment: .topLeading)
            }.scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Sheets use a separate hosting window. Keep enlarged controls scrollable on small displays.
struct ScaledSettingsPanel<Content: View>: View {
    var minimumSize = CGSize(width: 720, height: 560)
    @AppStorage(AppGraphicsSettings.interfaceScaleKey) private var storedScale = 1.0
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { proxy in
            let scale = min(1.5, max(0.75, storedScale.isFinite ? storedScale : 1))
            let width = max(minimumSize.width, proxy.size.width / scale)
            let height = max(minimumSize.height, proxy.size.height / scale)
            ScrollView([.horizontal, .vertical]) {
                content().frame(width: width, height: height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: height * scale, alignment: .topLeading)
            }
        }
    }
}

/// The same editor can be opened before a simulation is constructed.
@MainActor
final class OSDEditorModel: ObservableObject {
    @Published var osdLayout: OSDLayoutConfiguration
    @Published var fpvFontPreset: FPVFontPreset
    let osdElementAvailability: OSDElementAvailability
    private weak var simulation: DroneSimulationViewModel?
    init(simulation: DroneSimulationViewModel?) {
        self.simulation = simulation
        osdLayout = simulation?.osdLayout ?? UserDefaults.standard.data(forKey: DroneSimulationViewModel.osdLayoutKey)
            .flatMap { try? JSONDecoder().decode(OSDLayoutConfiguration.self, from: $0) }?.normalized() ?? .corners
        fpvFontPreset = simulation?.fpvFontPreset ?? FPVFontPreset(rawValue: UserDefaults.standard.string(forKey: "fpvOSD.fontPreset") ?? "") ?? .betaflight
        osdElementAvailability = simulation?.osdElementAvailability ?? OSDElementAvailability(hasRadioLink: true, hasSatelliteNavigation: true)
    }
    func setOSDLayout(_ layout: OSDLayoutConfiguration) {
        osdLayout = layout.normalized()
        simulation?.setOSDLayout(osdLayout)
        if let data = try? JSONEncoder().encode(osdLayout) { UserDefaults.standard.set(data, forKey: DroneSimulationViewModel.osdLayoutKey) }
    }
    func setFPVFontPreset(_ preset: FPVFontPreset) {
        fpvFontPreset = preset; simulation?.setFPVFontPreset(preset)
        UserDefaults.standard.set(preset.rawValue, forKey: "fpvOSD.fontPreset")
    }
    func applyOSDPreset(_ preset: OSDLayoutPreset) { setOSDLayout(preset.configuration) }
    func setOSDElementEnabled(_ enabled: Bool, for element: OSDElement) {
        var layout = osdLayout; layout.setEnabled(enabled, for: element); setOSDLayout(layout)
    }
    func moveOSDElement(_ element: OSDElement, toX x: Int, y: Int) {
        var layout = osdLayout; layout.move(element, toX: x, y: y); setOSDLayout(layout)
    }
    func setOSDCrosshairStyle(_ style: OSDCrosshairStyle) {
        var layout = osdLayout; layout.crosshairStyle = style; setOSDLayout(layout)
    }
    func setOSDElementRightAligned(_ aligned: Bool, for element: OSDElement) {
        var layout = osdLayout; var p = layout.placement(for: element); p.rightAligned = aligned
        layout.setPlacement(p, for: element); setOSDLayout(layout)
    }
}

enum SettingsFileIO {
    @MainActor static func export(_ data: Data, name: String) throws {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
    @MainActor static func read() throws -> Data? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw ControlProfileError.invalid("Файл слишком большой") }
        return try Data(contentsOf: url)
    }
}

struct OSDFileConfiguration: Codable {
    var version = 1
    var layout: OSDLayoutConfiguration
    var font: FPVFontPreset
}
