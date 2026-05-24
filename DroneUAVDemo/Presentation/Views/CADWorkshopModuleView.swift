import SwiftUI

struct CADWorkshopModuleView: View {
    @StateObject private var viewModel = CADWorkshopViewModel()

    var body: some View {
        VStack(spacing: 0) {
            assetListPanel
            Divider()
                .background(GroundControlPalette.border)
            parameterPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Asset list + create buttons

    private var assetListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            assetCreateBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider().background(GroundControlPalette.border)

            if viewModel.document.assets.isEmpty {
                Text("cad.assets.empty")
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(viewModel.document.assets) { asset in
                            assetRow(asset)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(GroundControlPalette.panel)
    }

    private var assetCreateBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("cad.section.create")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                if !viewModel.document.assets.isEmpty {
                    Button(role: .destructive) {
                        viewModel.resetDocument()
                    } label: {
                        Text("cad.action.clear_all")
                            .font(.caption2)
                            .foregroundStyle(GroundControlPalette.danger)
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6),
                ],
                spacing: 6
            ) {
                createButton("cad.kind.basic_wing", icon: "airplane.circle") { viewModel.createBasicWing() }
                createButton("cad.kind.frame_plate", icon: "rectangle.fill") { viewModel.createFramePlate() }
                createButton("cad.kind.beam", icon: "minus.rectangle.fill") { viewModel.createBeam() }
                createButton("cad.kind.tube", icon: "cylinder") { viewModel.createTube() }
                createButton("cad.kind.mount_bracket", icon: "angle") { viewModel.createMountBracket() }
                createButton("cad.kind.payload_box", icon: "shippingbox") { viewModel.createPayloadBox() }
            }
        }
    }

    private func createButton(_ titleKey: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 9.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(GroundControlPalette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(GroundControlPalette.accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(GroundControlPalette.accent.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func assetRow(_ asset: DesignAsset) -> some View {
        let isSelected = viewModel.selectedAssetID == asset.id
        return HStack(spacing: 8) {
            Image(systemName: asset.kind.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                    .lineLimit(1)
                Text(asset.kind.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(String(format: "%.1f g", asset.massProperties.massKg * 1000))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? GroundControlPalette.accent.opacity(0.16) : GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1)
        )
        .onTapGesture {
            viewModel.selectAsset(asset.id)
        }
        .contextMenu {
            Button("cad.action.duplicate") { viewModel.duplicateSelectedAsset() }
            Divider()
            Button("cad.action.delete", role: .destructive) {
                viewModel.selectAsset(asset.id)
                viewModel.deleteSelectedAsset()
            }
        }
    }

    // MARK: Parameter panel + 3D preview

    private var parameterPanel: some View {
        Group {
            if let asset = viewModel.selectedAsset {
                VStack(spacing: 0) {
                    selectedAssetHeader(asset)
                    Divider().background(GroundControlPalette.border)
                    previewArea
                    Divider().background(GroundControlPalette.border)
                    parameterEditor(asset)
                }
            } else {
                emptySelectionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func selectedAssetHeader(_ asset: DesignAsset) -> some View {
        HStack(spacing: 10) {
            Image(systemName: asset.kind.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .lineLimit(1)
                Text(asset.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    viewModel.duplicateSelectedAsset()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("cad.action.duplicate", comment: ""))

                Button {
                    viewModel.deleteSelectedAsset()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(GroundControlPalette.danger)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("cad.action.delete", comment: ""))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var previewArea: some View {
        DesignPreviewSceneViewRepresentable(
            document: viewModel.document,
            viewportState: viewModel.viewportState
        )
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(Color(red: 0.06, green: 0.08, blue: 0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(GroundControlPalette.border, lineWidth: 0)
        )
    }

    private func parameterEditor(_ asset: DesignAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                kindParameters(asset)
                if case .sketch2D = asset.kind {
                    sketchInfoRow(asset)
                } else {
                    materialPicker(asset)
                    massInfoRow(asset)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func materialPicker(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.material") {
            Picker("", selection: Binding(
                get: { asset.material },
                set: { viewModel.updateSelectedAssetMaterial($0) }
            )) {
                ForEach(DesignMaterial.allCases) { mat in
                    Text(mat.displayName).tag(mat)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func kindParameters(_ asset: DesignAsset) -> some View {
        switch asset.kind {
        case let .basicWing(p):
            basicWingEditor(p)
        case let .framePlate(p):
            framePlateEditor(p)
        case let .beam(p):
            beamEditor(p)
        case let .tube(p):
            tubeEditor(p)
        case let .mountBracket(p):
            mountBracketEditor(p)
        case let .payloadBox(p):
            payloadBoxEditor(p)
        case let .sketch2D(parameters):
            ModuleSection(titleKey: "cad.section.sketch") {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    ModuleMetricCell(labelKey: "cad.sketch.metric.lines", value: "\(parameters.sketch.lineCount)")
                    ModuleMetricCell(
                        labelKey: "cad.sketch.metric.contour",
                        value: parameters.sketch.isClosed
                            ? NSLocalizedString("cad.sketch.contour.closed", comment: "")
                            : NSLocalizedString("cad.sketch.contour.open", comment: "")
                    )
                }
            }
        case let .extrudedSolid(p):
            ModuleSection(titleKey: "cad.section.dimensions") {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    ModuleMetricCell(labelKey: "cad.extrude.depth",
                                     value: String(format: "%.0f mm", p.depthMeters * 1000))
                    ModuleMetricCell(labelKey: "cad.extrude.direction", value: p.direction.displayName)
                }
            }
        }
    }

    // MARK: Kind parameter editors

    private func basicWingEditor(_ p: BasicWingParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.span", value: p.spanMeters, range: 0.1...3.0) { newVal in
                    var q = p; q.spanMeters = newVal
                    viewModel.updateSelectedAssetKind(.basicWing(q))
                }
                mmSlider("cad.param.root_chord", value: p.rootChordMeters, range: 0.05...0.6) { newVal in
                    var q = p; q.rootChordMeters = newVal
                    viewModel.updateSelectedAssetKind(.basicWing(q))
                }
                mmSlider("cad.param.tip_chord", value: p.tipChordMeters, range: 0.02...0.4) { newVal in
                    var q = p; q.tipChordMeters = newVal
                    viewModel.updateSelectedAssetKind(.basicWing(q))
                }
                mmSlider("cad.param.thickness", value: p.thicknessMeters, range: 0.005...0.1) { newVal in
                    var q = p; q.thicknessMeters = newVal
                    viewModel.updateSelectedAssetKind(.basicWing(q))
                }
                degSlider("cad.param.sweep", value: p.sweepDegrees, range: -30...45) { newVal in
                    var q = p; q.sweepDegrees = newVal
                    viewModel.updateSelectedAssetKind(.basicWing(q))
                }
                degSlider("cad.param.dihedral", value: p.dihedralDegrees, range: -15...30) { newVal in
                    var q = p; q.dihedralDegrees = newVal
                    viewModel.updateSelectedAssetKind(.basicWing(q))
                }
            }
        }
    }

    private func framePlateEditor(_ p: FramePlateParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.width", value: p.widthMeters, range: 0.05...1.0) { newVal in
                    var q = p; q.widthMeters = newVal
                    viewModel.updateSelectedAssetKind(.framePlate(q))
                }
                mmSlider("cad.param.depth", value: p.depthMeters, range: 0.05...1.0) { newVal in
                    var q = p; q.depthMeters = newVal
                    viewModel.updateSelectedAssetKind(.framePlate(q))
                }
                mmSlider("cad.param.thickness", value: p.thicknessMeters, range: 0.001...0.05) { newVal in
                    var q = p; q.thicknessMeters = newVal
                    viewModel.updateSelectedAssetKind(.framePlate(q))
                }
            }
        }
    }

    private func beamEditor(_ p: BeamParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.length", value: p.lengthMeters, range: 0.05...2.0) { newVal in
                    var q = p; q.lengthMeters = newVal
                    viewModel.updateSelectedAssetKind(.beam(q))
                }
                mmSlider("cad.param.width", value: p.widthMeters, range: 0.005...0.1) { newVal in
                    var q = p; q.widthMeters = newVal
                    viewModel.updateSelectedAssetKind(.beam(q))
                }
                mmSlider("cad.param.height", value: p.heightMeters, range: 0.005...0.1) { newVal in
                    var q = p; q.heightMeters = newVal
                    viewModel.updateSelectedAssetKind(.beam(q))
                }
            }
        }
    }

    private func tubeEditor(_ p: TubeParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.length", value: p.lengthMeters, range: 0.05...2.0) { newVal in
                    var q = p; q.lengthMeters = newVal
                    viewModel.updateSelectedAssetKind(.tube(q))
                }
                mmSlider("cad.param.outer_radius", value: p.outerRadiusMeters, range: 0.002...0.1) { newVal in
                    var q = p; q.outerRadiusMeters = max(newVal, p.innerRadiusMeters + 0.001)
                    viewModel.updateSelectedAssetKind(.tube(q))
                }
                mmSlider("cad.param.inner_radius", value: p.innerRadiusMeters, range: 0.001...0.09) { newVal in
                    var q = p; q.innerRadiusMeters = min(newVal, p.outerRadiusMeters - 0.001)
                    viewModel.updateSelectedAssetKind(.tube(q))
                }
            }
        }
    }

    private func mountBracketEditor(_ p: MountBracketParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.plate_width", value: p.plateWidthMeters, range: 0.02...0.3) { newVal in
                    var q = p; q.plateWidthMeters = newVal
                    viewModel.updateSelectedAssetKind(.mountBracket(q))
                }
                mmSlider("cad.param.plate_depth", value: p.plateDepthMeters, range: 0.02...0.3) { newVal in
                    var q = p; q.plateDepthMeters = newVal
                    viewModel.updateSelectedAssetKind(.mountBracket(q))
                }
                mmSlider("cad.param.plate_thickness", value: p.plateThicknessMeters, range: 0.001...0.02) { newVal in
                    var q = p; q.plateThicknessMeters = newVal
                    viewModel.updateSelectedAssetKind(.mountBracket(q))
                }
                mmSlider("cad.param.arm_length", value: p.armLengthMeters, range: 0.01...0.3) { newVal in
                    var q = p; q.armLengthMeters = newVal
                    viewModel.updateSelectedAssetKind(.mountBracket(q))
                }
                mmSlider("cad.param.arm_thickness", value: p.armThicknessMeters, range: 0.001...0.02) { newVal in
                    var q = p; q.armThicknessMeters = newVal
                    viewModel.updateSelectedAssetKind(.mountBracket(q))
                }
            }
        }
    }

    private func payloadBoxEditor(_ p: PayloadBoxParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.width", value: p.widthMeters, range: 0.02...0.5) { newVal in
                    var q = p; q.widthMeters = newVal
                    viewModel.updateSelectedAssetKind(.payloadBox(q))
                }
                mmSlider("cad.param.height", value: p.heightMeters, range: 0.02...0.4) { newVal in
                    var q = p; q.heightMeters = newVal
                    viewModel.updateSelectedAssetKind(.payloadBox(q))
                }
                mmSlider("cad.param.depth", value: p.depthMeters, range: 0.02...0.4) { newVal in
                    var q = p; q.depthMeters = newVal
                    viewModel.updateSelectedAssetKind(.payloadBox(q))
                }
            }
        }
    }

    // MARK: Mass info

    private func sketchInfoRow(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.mass_info") {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ModuleMetricCell(
                    labelKey: "cad.metric.mass",
                    value: NSLocalizedString("cad.sketch.massless", comment: "")
                )
                ModuleMetricCell(
                    labelKey: "cad.metric.attach_pts",
                    value: "\(asset.attachmentPoints.count)"
                )
            }
        }
    }

    private func massInfoRow(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.mass_info") {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ModuleMetricCell(
                    labelKey: "cad.metric.mass",
                    value: String(format: "%.1f g", asset.massProperties.massKg * 1000)
                )
                ModuleMetricCell(
                    labelKey: "cad.metric.material",
                    value: asset.material.displayName
                )
                ModuleMetricCell(
                    labelKey: "cad.metric.bounding",
                    value: String(
                        format: "%.0f×%.0f×%.0f mm",
                        asset.massProperties.boundingWidth * 1000,
                        asset.massProperties.boundingHeight * 1000,
                        asset.massProperties.boundingDepth * 1000
                    )
                )
                ModuleMetricCell(
                    labelKey: "cad.metric.attach_pts",
                    value: "\(asset.attachmentPoints.count)"
                )
            }
        }
    }

    // MARK: Empty state

    private var emptySelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.5))
            Text("cad.selection.empty")
                .font(.caption)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Slider helpers

    private func mmSlider(
        _ titleKey: String,
        value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(titleKey))
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                Text(String(format: "%.1f mm", value * 1000))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
            .tint(GroundControlPalette.accent)
        }
    }

    private func degSlider(
        _ titleKey: String,
        value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(titleKey))
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                Text(String(format: "%.1f°", value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
            .tint(GroundControlPalette.accent)
        }
    }
}
