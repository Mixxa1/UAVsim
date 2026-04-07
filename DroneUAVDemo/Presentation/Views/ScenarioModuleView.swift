import SwiftUI

struct ScenarioModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @State private var showWeatherTuning = false

    private static let angleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let scalarFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let speedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private let tileColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleSection(
                titleKey: "module.scenario.weather",
                subtitleKey: "module.scenario.weather.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: tileColumns, spacing: 8) {
                        ForEach(WeatherPreset.allCases) { preset in
                            ModuleModeTile(
                                titleKey: preset.titleKey,
                                subtitle: preset == viewModel.weather.preset ? localized("module.scenario.active_preset") : nil,
                                iconSystemName: weatherIcon(for: preset),
                                isActive: viewModel.weather.preset == preset
                            ) {
                                viewModel.setWeatherPreset(preset)
                            }
                        }
                    }

                    ModuleSliderRow(
                        titleKey: "weather.intensity",
                        value: Binding(
                            get: { Double(viewModel.weather.intensity) },
                            set: { viewModel.setWeatherIntensity($0) }
                        ),
                        range: 0.0...1.0,
                        step: 0.01,
                        formatter: Self.scalarFormatter
                    )
                    ModuleSliderRow(
                        titleKey: "weather.wind_speed",
                        value: Binding(
                            get: { Double(viewModel.weather.windSpeedMps) },
                            set: { viewModel.setWindSpeed($0) }
                        ),
                        range: 0.0...30.0,
                        step: 0.1,
                        formatter: Self.speedFormatter
                    )

                    DisclosureGroup(
                        isExpanded: $showWeatherTuning,
                        content: {
                            VStack(alignment: .leading, spacing: 10) {
                                ModuleSliderRow(
                                    titleKey: "weather.wind_direction",
                                    value: Binding(
                                        get: { Double(viewModel.weather.windDirectionDeg) },
                                        set: { viewModel.setWindDirection($0) }
                                    ),
                                    range: -180.0...180.0,
                                    step: 1.0,
                                    formatter: Self.angleFormatter
                                )
                                ModuleSliderRow(
                                    titleKey: "weather.gusts",
                                    value: Binding(
                                        get: { Double(viewModel.weather.gusts) },
                                        set: { viewModel.setWindGusts($0) }
                                    ),
                                    range: 0.0...1.0,
                                    step: 0.01,
                                    formatter: Self.scalarFormatter
                                )
                            }
                            .padding(.top, 10)
                        },
                        label: {
                            Text(showWeatherTuning ? "module.scenario.hide_weather_tuning" : "module.scenario.show_weather_tuning")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.textPrimary)
                        }
                    )
                    .tint(GroundControlPalette.accent)
                }
            }

            ModuleSection(
                titleKey: "module.scenario.terrain",
                subtitleKey: "module.scenario.terrain.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("panel.terrain", selection: Binding(
                        get: { viewModel.terrain.preset },
                        set: { viewModel.setTerrainPreset($0) }
                    )) {
                        ForEach(TerrainPreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("terrain.scale", selection: Binding(
                        get: { viewModel.terrain.mapScale },
                        set: { viewModel.setTerrainMapScale($0) }
                    )) {
                        ForEach(MapScale.allCases) { scale in
                            Text(LocalizedStringKey(scale.titleKey)).tag(scale)
                        }
                    }
                    .pickerStyle(.menu)

                    ModuleSliderRow(
                        titleKey: "terrain.density",
                        value: Binding(
                            get: { Double(viewModel.terrain.density) },
                            set: { viewModel.setTerrainDensity($0) }
                        ),
                        range: 0.0...1.0,
                        step: 0.01,
                        formatter: Self.scalarFormatter,
                        onEditingChanged: viewModel.setTerrainDensityEditing,
                        onCommit: viewModel.commitTerrainDensityChange
                    )

                    Toggle("environment.boundary_barrier_visible", isOn: Binding(
                        get: { viewModel.isBoundaryBarrierVisible },
                        set: { viewModel.setBoundaryBarrierVisible($0) }
                    ))
                    .toggleStyle(.switch)
                    .foregroundStyle(GroundControlPalette.textPrimary)
                }
            }
        }
    }

    private func weatherIcon(for preset: WeatherPreset) -> String {
        switch preset {
        case .normal:
            return "sun.max"
        case .wind:
            return "wind"
        case .rain:
            return "cloud.rain"
        case .snow:
            return "snowflake"
        case .fog:
            return "cloud.fog"
        case .smog:
            return "aqi.medium"
        case .thunderstorm:
            return "cloud.bolt.rain"
        }
    }

    private func terrainIcon(for preset: TerrainPreset) -> String {
        switch preset {
        case .gridDemo:
            return "square.grid.3x3"
        case .field:
            return "leaf"
        case .forest:
            return "tree"
        case .cargoYard:
            return "shippingbox"
        case .city:
            return "building.2"
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
