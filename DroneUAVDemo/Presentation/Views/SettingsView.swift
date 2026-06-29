import SwiftUI
import AppKit

/// Application settings overlay reached from the start menu: graphics quality, resolution/window,
/// language, third-party credits and the legal documents. Persists through the same `@AppStorage`
/// keys the scene/render layers read via `AppGraphicsSettings` / `L10n`.
struct SettingsView: View {
    let onClose: () -> Void
    /// Applies a window-size preset through the app's bound main window (ContentView wires this to
    /// `AppShell.applyWindowSizePreset` — more reliable than reaching for `NSApp.mainWindow` here).
    var onApplyWindowSize: (WindowSizePreset) -> Void = { _ in }

    @AppStorage(AppGraphicsSettings.qualityKey) private var qualityRaw: String = GraphicsQualityPreset.high.rawValue
    @AppStorage(AppGraphicsSettings.renderScaleKey) private var renderScale: Double = 0.0
    @AppStorage(AppGraphicsSettings.windowSizeKey) private var windowSizeRaw: String = WindowSizePreset.native.rawValue
    @AppStorage("app.language") private var languageRaw: String = AppLanguage.system.rawValue

    private var quality: GraphicsQualityPreset {
        GraphicsQualityPreset(rawValue: qualityRaw) ?? .high
    }

    private var qualityBinding: Binding<GraphicsQualityPreset> {
        Binding(
            get: { GraphicsQualityPreset(rawValue: qualityRaw) ?? .high },
            set: { newValue in
                qualityRaw = newValue.rawValue
                // Render scale follows the tier default unless the user explicitly nudges it.
                renderScale = newValue.defaultRenderScale
            }
        )
    }

    private var windowSizeBinding: Binding<WindowSizePreset> {
        Binding(
            get: { WindowSizePreset(rawValue: windowSizeRaw) ?? .native },
            set: { newValue in
                windowSizeRaw = newValue.rawValue
                onApplyWindowSize(newValue)
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    videoSection
                    resolutionSection
                    languageSection
                    creditsSection
                }
                .padding(20)
            }

            footer
        }
        .frame(maxWidth: 760, maxHeight: 760)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            if renderScale <= 0.0 {
                renderScale = quality.defaultRenderScale
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.title")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("settings.subtitle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    private var videoSection: some View {
        sectionCard(titleKey: "settings.section.video") {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("settings.graphics.quality") {
                    Picker("", selection: qualityBinding) {
                        ForEach(GraphicsQualityPreset.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if quality.showsHeatWarning {
                    heatWarning
                }

                Text("settings.graphics.apply_note")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var heatWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "thermometer.sun.fill")
                .foregroundStyle(.orange)
            Text("settings.graphics.heat_warning")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var resolutionSection: some View {
        sectionCard(titleKey: "settings.section.resolution") {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("settings.window_size") {
                    Picker("", selection: windowSizeBinding) {
                        ForEach(WindowSizePreset.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("settings.render_scale")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.0f%%", renderScale * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                    Slider(value: $renderScale, in: 0.5...1.0, step: 0.05)
                    Text("settings.render_scale.hint")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }

                Button(action: { WindowFullscreenController.toggle() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("settings.fullscreen")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var languageSection: some View {
        sectionCard(titleKey: "settings.section.language") {
            Picker("", selection: languageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(LocalizedStringKey(language.titleKey)).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var creditsSection: some View {
        sectionCard(titleKey: "settings.section.credits") {
            VStack(alignment: .leading, spacing: 12) {
                Text("credits.copyright_line")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                CreditsView()
                    .frame(height: 320)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("common.done")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(GroundControlPalette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionCard<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func labeledRow<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }
}
