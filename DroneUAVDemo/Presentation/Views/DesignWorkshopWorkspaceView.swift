import SwiftUI

private enum SketchLineEndpoint: Equatable {
    case start
    case end
}

struct DesignWorkshopWorkspaceView: View {
    @ObservedObject var viewModel: CADWorkshopViewModel
    var onExitToSimulation: () -> Void

    // Numeric fallback line creation fields
    @State private var draftLineStartU: Double = 0
    @State private var draftLineStartV: Double = 0
    @State private var draftLineEndU: Double = 100
    @State private var draftLineEndV: Double = 0
    // Parametric tool input drafts (live-editable during construction)
    @State private var draftLineLengthText: String = ""
    @State private var draftLineAngleText: String = ""
    @State private var draftRectWidthText: String = ""
    @State private var draftRectHeightText: String = ""
    @State private var draftCircleRadiusText: String = ""
    @State private var draftCircleDiamText: String = ""
    // Project tree expansion state
    @State private var planesExpanded = true
    @State private var axesExpanded = false
    @State private var sketchesExpanded = true
    @State private var elementsExpanded = true
    @State private var extrudedExpanded = false
    @State private var templatesPopoverShown = false
    @State private var trimExtendDistanceMM: String = ""

    var body: some View {
        VStack(spacing: 0) {
            workshopTopBar
            Divider()
            HStack(spacing: 0) {
                leftProjectTreePanel
                    .frame(width: 220)
                Divider()
                centerCanvas
                Divider()
                rightContextPanel
                    .frame(width: 288)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            workshopStatusBar
        }
        .frame(minWidth: 880, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(GroundControlPalette.shell)
    }

    // MARK: - Top Command Bar  (Stage 1.16A — Two-level ribbon)

    private var workshopTopBar: some View {
        VStack(spacing: 0) {
            // ── Title row ─────────────────────────────────────────────────
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.accent)
                    Text(LocalizedStringKey("cad.workspace.title"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 10)

                Spacer()

                if viewModel.selectedAsset != nil {
                    compactStatusBadge
                    topBarDivider.padding(.horizontal, 6)
                }

                topBarButton(icon: "chevron.left", titleKey: "cad.workspace.back_to_simulation",
                             isActive: false, action: onExitToSimulation)
                    .padding(.trailing, 8)
            }
            .frame(height: Self.tbH + 2)
            .background(GroundControlPalette.panel)

            Divider().background(GroundControlPalette.border)

            // ── CAD Ribbon — scrollable groups, overflow-safe ──
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {

                // Эскиз: Выбор (row 1, always) + sketch tools (rows 1-2, when sketch open)
                ribbonGroup("cad.ribbon.group.sketch") {
                    HStack(spacing: Self.tbItemSpacing) {
                        ribbonBtn(icon: "cursorarrow", titleKey: "cad.tool.select",
                                  isActive: viewModel.activeToolMode == .select) {
                            viewModel.setToolMode(.select)
                        }
                        if viewModel.selectedSketch != nil {
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchLine.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchLine.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchLine) {
                                viewModel.setToolMode(.sketchLine)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchRectangle.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchRectangle.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchRectangle) {
                                viewModel.setToolMode(.sketchRectangle)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchCircle.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchCircle.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchCircle) {
                                viewModel.setToolMode(.sketchCircle)
                            }
                        }
                    }
                    if viewModel.selectedSketch != nil {
                        HStack(spacing: Self.tbItemSpacing) {
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchArc.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchArc.titleKey,
                                      tooltipKey: "cad.tool.arc.tooltip",
                                      isActive: viewModel.activeToolMode == .sketchArc) {
                                viewModel.setToolMode(.sketchArc)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchAutoline.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchAutoline.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchAutoline) {
                                viewModel.setToolMode(.sketchAutoline)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchConstruction.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchConstruction.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchConstruction) {
                                viewModel.setToolMode(.sketchConstruction)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchEdit.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchEdit.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchEdit) {
                                viewModel.setToolMode(.sketchEdit)
                            }
                        }
                    }
                }

                // Изменить эскиз: row1 = Move/Copy/Parallel/Perp, row2 = Split/Trim/Extend
                if viewModel.selectedSketch != nil {
                    ribbonGroup("cad.ribbon.group.modify") {
                        HStack(spacing: Self.tbItemSpacing) {
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchMove.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchMove.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchMove) {
                                viewModel.setToolMode(.sketchMove)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchCopy.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchCopy.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchCopy) {
                                viewModel.setToolMode(.sketchCopy)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchParallel.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchParallel.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchParallel) {
                                viewModel.setToolMode(.sketchParallel)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchPerpendicular.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchPerpendicular.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchPerpendicular) {
                                viewModel.setToolMode(.sketchPerpendicular)
                            }
                        }
                        HStack(spacing: Self.tbItemSpacing) {
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchSplit.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchSplit.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchSplit) {
                                viewModel.setToolMode(.sketchSplit)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchTrim.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchTrim.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchTrim) {
                                viewModel.setToolMode(.sketchTrim)
                            }
                            ribbonBtn(icon: DesignWorkshopToolMode.sketchExtend.iconName,
                                      titleKey: DesignWorkshopToolMode.sketchExtend.titleKey,
                                      isActive: viewModel.activeToolMode == .sketchExtend) {
                                viewModel.setToolMode(.sketchExtend)
                            }
                        }
                    }
                }

                // Элементы тела: row1 = Выдавить + Вырезать; row2 = Скругление + Фаска (stubs)
                ribbonGroup("cad.ribbon.group.body") {
                    HStack(spacing: Self.tbItemSpacing) {
                        let canExtrude = viewModel.canApplyExtrudeFeature
                        Button {
                            viewModel.featureOperation = .extrudeNewBody
                            viewModel.applyFeatureOperation()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.3.layers.3d")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(LocalizedStringKey("cad.extrude.action"))
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(canExtrude ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: Self.ribbonBtnH)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(canExtrude ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.70)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(canExtrude ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canExtrude)
                        .help(canExtrude
                            ? NSLocalizedString("cad.extrude.action", comment: "")
                            : NSLocalizedString("cad.extrude.contour_open", comment: ""))

                        let canCut = viewModel.canPreviewCutV2Feature
                        Button {
                            viewModel.featureOperation = .cutRemoveMaterialV2
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "minus.square")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(LocalizedStringKey("cad.feature.op.cut"))
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(canCut ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: Self.ribbonBtnH)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(canCut ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.70)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(canCut ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(canCut
                            ? NSLocalizedString("cad.cut_v2.preview.ready", comment: "")
                            : NSLocalizedString("cad.cut_v2.reason.cut_tool_does_not_intersect_body", comment: ""))
                    }
                    HStack(spacing: Self.tbItemSpacing) {
                        ribbonStubBtn(icon: "cylinder.split.1x2", titleKey: "cad.op.fillet",
                                      helpKey: "cad.op.fillet_future")
                        ribbonStubBtn(icon: "square.slash", titleKey: "cad.op.chamfer",
                                      helpKey: "cad.op.chamfer_future")
                    }
                }

                // Вид: row1 = XY/XZ/YZ/Изо; row2 = К эскизу (conditional)
                ribbonGroup("cad.ribbon.group.view") {
                    HStack(spacing: Self.tbItemSpacing) {
                        ForEach(SketchPlane.allCases) { plane in ribbonPlaneBtn(plane) }
                        ribbonBtn(icon: CADCameraMode.iso.systemImage, titleKey: "cad.camera.iso",
                                  isActive: viewModel.viewportState.orientation == .iso) {
                            viewModel.applyCameraMode(.iso)
                        }
                    }
                    if viewModel.selectedSketch != nil && viewModel.viewportState.viewMode != .sketch2D {
                        HStack(spacing: Self.tbItemSpacing) {
                            ribbonBtn(icon: "viewfinder.circle",
                                      titleKey: "cad.camera.normal_to_sketch",
                                      isActive: false) {
                                viewModel.setViewNormalToSketch()
                            }
                        }
                    }
                }

                // Отображение: icon toggles in 2 rows
                ribbonGroup("cad.ribbon.group.display") {
                    HStack(spacing: Self.tbItemSpacing) {
                        ribbonIconBtn(icon: "grid", titleKey: "cad.canvas.grid",
                                      tooltipKey: "cad.canvas.grid.tooltip",
                                      isOn: viewModel.canvasOptions.showGrid) {
                            viewModel.setShowGrid(!viewModel.canvasOptions.showGrid)
                        }
                        ribbonIconBtn(icon: "square.on.square.dashed",
                                      titleKey: "cad.canvas.reference_planes",
                                      tooltipKey: "cad.canvas.planes.tooltip",
                                      isOn: viewModel.canvasOptions.showReferencePlanes) {
                            viewModel.setShowReferencePlanes(!viewModel.canvasOptions.showReferencePlanes)
                        }
                        ribbonIconBtn(icon: "arrow.3.trianglepath",
                                      titleKey: "cad.canvas.axes",
                                      tooltipKey: "cad.canvas.axes.tooltip",
                                      isOn: viewModel.canvasOptions.showAxes) {
                            viewModel.setShowAxes(!viewModel.canvasOptions.showAxes)
                        }
                    }
                    HStack(spacing: Self.tbItemSpacing) {
                        ribbonIconBtn(icon: "square.dashed",
                                      titleKey: "cad.canvas.active_plane",
                                      isOn: viewModel.canvasOptions.showActivePlaneOverlay) {
                            viewModel.setShowActivePlaneOverlay(!viewModel.canvasOptions.showActivePlaneOverlay)
                        }
                        ribbonIconBtn(icon: "point.3.connected.trianglepath.dotted",
                                      titleKey: "cad.canvas.attachment_points",
                                      tooltipKey: "cad.canvas.points.tooltip",
                                      isOn: viewModel.canvasOptions.showAttachmentPoints) {
                            viewModel.setShowAttachmentPoints(!viewModel.canvasOptions.showAttachmentPoints)
                        }
                        ribbonIconBtn(icon: "equal.square",
                                      titleKey: "cad.canvas.constraint_glyphs",
                                      isOn: viewModel.canvasOptions.showConstraintGlyphs) {
                            viewModel.setShowConstraintGlyphs(!viewModel.canvasOptions.showConstraintGlyphs)
                        }
                    }
                }

                // Привязки: snap (row 1) + grid step (row 2)
                ribbonGroup("cad.ribbon.group.snap") {
                    ribbonSnapMenu
                    ribbonGridMenu
                }

                // Шаблоны
                ribbonGroup("cad.ribbon.group.templates") {
                    ribbonBtn(icon: "rectangle.stack.badge.plus",
                              titleKey: "cad.templates.button",
                              isActive: templatesPopoverShown) {
                        templatesPopoverShown.toggle()
                    }
                    .popover(isPresented: $templatesPopoverShown, arrowEdge: .bottom) {
                        templatesPopover
                    }
                }

            }
            .padding(.horizontal, 6)
            }
            .frame(height: Self.ribbonRowH)
            .background(GroundControlPalette.panel)
        }
    }

    // MARK: Toolbar groups

    // Group A: Выбор + sketch drawing tools (when sketch open) + Выдавить
    @ViewBuilder
    private var commandStripToolGroup: some View {
        // Выбор — always visible
        topBarButton(icon: "cursorarrow", titleKey: "cad.tool.select",
                     isActive: viewModel.activeToolMode == .select) {
            viewModel.setToolMode(.select)
        }

        if viewModel.selectedSketch != nil {
            Rectangle()
                .fill(GroundControlPalette.border.opacity(0.6))
                .frame(width: 1, height: 22)

            // Labeled sketch tools: Линия, Прямоугольник, Окружность, Дуга
            topBarButton(icon: DesignWorkshopToolMode.sketchLine.iconName,
                         titleKey: DesignWorkshopToolMode.sketchLine.titleKey,
                         isActive: viewModel.activeToolMode == .sketchLine) {
                viewModel.setToolMode(.sketchLine)
            }
            topBarButton(icon: DesignWorkshopToolMode.sketchRectangle.iconName,
                         titleKey: DesignWorkshopToolMode.sketchRectangle.titleKey,
                         isActive: viewModel.activeToolMode == .sketchRectangle) {
                viewModel.setToolMode(.sketchRectangle)
            }
            topBarButton(icon: DesignWorkshopToolMode.sketchCircle.iconName,
                         titleKey: DesignWorkshopToolMode.sketchCircle.titleKey,
                         isActive: viewModel.activeToolMode == .sketchCircle) {
                viewModel.setToolMode(.sketchCircle)
            }
            // Arc: labeled with tooltip (Stage 1.16A)
            topBarButton(icon: DesignWorkshopToolMode.sketchArc.iconName,
                         titleKey: DesignWorkshopToolMode.sketchArc.titleKey,
                         tooltipKey: "cad.tool.arc.tooltip",
                         isActive: viewModel.activeToolMode == .sketchArc) {
                viewModel.setToolMode(.sketchArc)
            }

            // Autoline + Edit: icon-only
            tbIconBtn(icon: DesignWorkshopToolMode.sketchAutoline.iconName,
                      isActive: viewModel.activeToolMode == .sketchAutoline,
                      tooltip: DesignWorkshopToolMode.sketchAutoline.titleKey) {
                viewModel.setToolMode(.sketchAutoline)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchEdit.iconName,
                      isActive: viewModel.activeToolMode == .sketchEdit,
                      tooltip: DesignWorkshopToolMode.sketchEdit.titleKey) {
                viewModel.setToolMode(.sketchEdit)
            }

            // Вспомогательная (construction)
            topBarButton(icon: "circle.dashed", titleKey: "cad.tool.construction",
                         isActive: viewModel.activeToolMode == .sketchConstruction) {
                viewModel.setToolMode(.sketchConstruction)
            }

            // Modify tools: Move/Copy + Parallel/Perp + Split/Trim/Extend
            Rectangle()
                .fill(GroundControlPalette.border.opacity(0.6))
                .frame(width: 1, height: 22)

            tbIconBtn(icon: DesignWorkshopToolMode.sketchMove.iconName,
                      isActive: viewModel.activeToolMode == .sketchMove,
                      tooltip: DesignWorkshopToolMode.sketchMove.titleKey) {
                viewModel.setToolMode(.sketchMove)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchCopy.iconName,
                      isActive: viewModel.activeToolMode == .sketchCopy,
                      tooltip: DesignWorkshopToolMode.sketchCopy.titleKey) {
                viewModel.setToolMode(.sketchCopy)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchParallel.iconName,
                      isActive: viewModel.activeToolMode == .sketchParallel,
                      tooltip: DesignWorkshopToolMode.sketchParallel.titleKey) {
                viewModel.setToolMode(.sketchParallel)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchPerpendicular.iconName,
                      isActive: viewModel.activeToolMode == .sketchPerpendicular,
                      tooltip: DesignWorkshopToolMode.sketchPerpendicular.titleKey) {
                viewModel.setToolMode(.sketchPerpendicular)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchSplit.iconName,
                      isActive: viewModel.activeToolMode == .sketchSplit,
                      tooltip: DesignWorkshopToolMode.sketchSplit.titleKey) {
                viewModel.setToolMode(.sketchSplit)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchTrim.iconName,
                      isActive: viewModel.activeToolMode == .sketchTrim,
                      tooltip: DesignWorkshopToolMode.sketchTrim.titleKey) {
                viewModel.setToolMode(.sketchTrim)
            }
            tbIconBtn(icon: DesignWorkshopToolMode.sketchExtend.iconName,
                      isActive: viewModel.activeToolMode == .sketchExtend,
                      tooltip: DesignWorkshopToolMode.sketchExtend.titleKey) {
                viewModel.setToolMode(.sketchExtend)
            }
        }

        // Sub-divider before operations
        Rectangle()
            .fill(GroundControlPalette.border.opacity(0.6))
            .frame(width: 1, height: 22)

        // Выдавить / Вырезать — active only when each operation validation passes.
        let canApply = viewModel.canApplyExtrudeFeature
        Button {
            viewModel.featureOperation = .extrudeNewBody
            viewModel.applyFeatureOperation()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey("cad.extrude.action"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(canApply ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: Self.tbPrimaryMinW).frame(height: Self.tbH)
            .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .fill(canApply ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.70)))
            .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .stroke(canApply ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canApply)
        .help(canApply
            ? NSLocalizedString("cad.extrude.action", comment: "")
            : NSLocalizedString("cad.extrude.contour_open", comment: ""))

        let canCut = viewModel.canPreviewCutV2Feature
        Button {
            viewModel.featureOperation = .cutRemoveMaterialV2
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "minus.square")
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey("cad.feature.op.cut"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(canCut ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: Self.tbPrimaryMinW).frame(height: Self.tbH)
            .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .fill(canCut ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.70)))
            .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .stroke(canCut ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(canCut
            ? NSLocalizedString("cad.cut_v2.preview.ready", comment: "")
            : NSLocalizedString("cad.cut_v2.reason.cut_tool_does_not_intersect_body", comment: ""))
    }

    // Group C: display toggles — icon-only, uniform size
    @ViewBuilder
    private var displayGroup: some View {
        // Сетка
        topBarToggle(icon: "grid", titleKey: "cad.canvas.grid",
                     tooltipKey: "cad.canvas.grid.tooltip",
                     isOn: viewModel.canvasOptions.showGrid) {
            viewModel.setShowGrid(!viewModel.canvasOptions.showGrid)
        }
        // Плоскости
        topBarToggle(icon: "square.on.square.dashed", titleKey: "cad.canvas.reference_planes",
                     tooltipKey: "cad.canvas.planes.tooltip",
                     isOn: viewModel.canvasOptions.showReferencePlanes) {
            viewModel.setShowReferencePlanes(!viewModel.canvasOptions.showReferencePlanes)
        }
        // Оси
        topBarToggle(icon: "arrow.3.trianglepath", titleKey: "cad.canvas.axes",
                     tooltipKey: "cad.canvas.axes.tooltip",
                     isOn: viewModel.canvasOptions.showAxes) {
            viewModel.setShowAxes(!viewModel.canvasOptions.showAxes)
        }
        // Активная плоскость (overlay)
        topBarToggle(icon: "square.dashed", titleKey: "cad.canvas.active_plane",
                     isOn: viewModel.canvasOptions.showActivePlaneOverlay) {
            viewModel.setShowActivePlaneOverlay(!viewModel.canvasOptions.showActivePlaneOverlay)
        }
        // Точки привязки
        topBarToggle(icon: "point.3.connected.trianglepath.dotted", titleKey: "cad.canvas.attachment_points",
                     tooltipKey: "cad.canvas.points.tooltip",
                     isOn: viewModel.canvasOptions.showAttachmentPoints) {
            viewModel.setShowAttachmentPoints(!viewModel.canvasOptions.showAttachmentPoints)
        }
        // Глифы ограничений
        topBarToggle(icon: "equal.square", titleKey: "cad.canvas.constraint_glyphs",
                     isOn: viewModel.canvasOptions.showConstraintGlyphs) {
            viewModel.setShowConstraintGlyphs(!viewModel.canvasOptions.showConstraintGlyphs)
        }
    }

    // Group F (right): drawing-mode commit/cancel + status badge + simulation exit
    @ViewBuilder
    private var rightActionsGroup: some View {
        // Drawing mode commit / cancel — shown only during active line / autoline tool
        if viewModel.activeToolMode == .sketchLine || viewModel.activeToolMode == .sketchAutoline {
            tbFinishBtn {
                if viewModel.activeToolMode == .sketchAutoline {
                    viewModel.commitAutolineTool(close: false)
                } else {
                    viewModel.finishLineCommand()
                }
            }
            tbCancelBtn {
                if viewModel.activeToolMode == .sketchAutoline {
                    viewModel.cancelAutolineTool()
                } else {
                    viewModel.cancelLineTool()
                }
            }
            topBarDivider
        } else if viewModel.activeToolMode == .sketchArc && viewModel.arcToolState.isActive {
            tbCancelBtn { viewModel.cancelArcTool() }
            topBarDivider
        } else if viewModel.activeToolMode == .sketchConstruction && viewModel.constructionToolState.firstPoint != nil {
            tbCancelBtn { viewModel.cancelConstructionTool() }
            topBarDivider
        } else if viewModel.activeToolMode == .sketchMove || viewModel.activeToolMode == .sketchCopy {
            tbCancelBtn { viewModel.setToolMode(.select) }
            topBarDivider
        } else if viewModel.activeToolMode == .sketchParallel || viewModel.activeToolMode == .sketchPerpendicular {
            tbCancelBtn { viewModel.setToolMode(.select) }
            topBarDivider
        } else if viewModel.activeToolMode == .sketchSplit || viewModel.activeToolMode == .sketchTrim || viewModel.activeToolMode == .sketchExtend {
            tbCancelBtn { viewModel.setToolMode(.select) }
            topBarDivider
        }

        // Compact status badge + divider — shown only when an asset is selected
        if viewModel.selectedAsset != nil {
            compactStatusBadge
            topBarDivider
        }

        // Симуляция — primary labeled exit button
        topBarButton(icon: "chevron.left", titleKey: "cad.workspace.back_to_simulation",
                     isActive: false, action: onExitToSimulation)
    }

    @ViewBuilder
    private var viewsGroup: some View {
        // Sketch plane selectors — short labeled, uniform size
        ForEach(SketchPlane.allCases) { plane in
            planeSelectorButton(plane)
        }
        // Изо
        viewIsoButton
        // К эскизу — only when sketch selected AND not already in sketch2D view
        if viewModel.selectedSketch != nil && viewModel.viewportState.viewMode != .sketch2D {
            viewNormalToSketchButton
        }
    }

    private func planeSelectorButton(_ plane: SketchPlane) -> some View {
        let isLocked = viewModel.isSelectedSketchPlaneLocked
        let isActive = planeIsActive(plane, isLocked: isLocked)
        let tooltip = isLocked
            ? "\(plane.viewName) · \(NSLocalizedString("cad.canvas.view_only", comment: ""))"
            : "\(plane.displayName) · \(plane.viewName)"
        return Button { viewModel.selectSketchPlane(plane) } label: {
            Text(plane.displayName)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .padding(.horizontal, 6)
                .frame(minWidth: Self.tbIconW).frame(height: Self.tbH)
                .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .fill(isActive ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.50)))
                .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .stroke(isActive ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func planeIsActive(_ plane: SketchPlane, isLocked: Bool) -> Bool {
        if isLocked {
            switch viewModel.viewportState.orientation {
            case .top:   return plane == .xz
            case .front: return plane == .xy
            case .side:  return plane == .yz
            default:     return false
            }
        }
        return viewModel.activeSketchPlane == plane
    }

    private var viewIsoButton: some View {
        let isActive = viewModel.viewportState.orientation == .iso
        return Button { viewModel.applyCameraMode(.iso) } label: {
            HStack(spacing: 4) {
                Image(systemName: CADCameraMode.iso.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey("cad.camera.iso"))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.tbH)
            .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .fill(isActive ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.50)))
            .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .stroke(isActive ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("cad.camera.iso.tooltip", comment: ""))
    }

    private var viewNormalToSketchButton: some View {
        let isActive = viewModel.viewportState.viewMode == .sketch2D
        return Button { viewModel.setViewNormalToSketch() } label: {
            HStack(spacing: 4) {
                Image(systemName: "viewfinder.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey("cad.camera.normal_to_sketch"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.tbH)
            .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .fill(isActive ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.50)))
            .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .stroke(isActive ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("cad.camera.normal_to_sketch", comment: ""))
    }

    private var templatesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey("cad.templates.title"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider().background(GroundControlPalette.border)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    templateButton("cad.kind.basic_wing",    icon: "airplane.circle")    { viewModel.createBasicWing() }
                    templateButton("cad.kind.frame_plate",   icon: "rectangle.fill")     { viewModel.createFramePlate() }
                    templateButton("cad.kind.beam",          icon: "minus.rectangle.fill") { viewModel.createBeam() }
                    templateButton("cad.kind.tube",          icon: "cylinder")            { viewModel.createTube() }
                    templateButton("cad.kind.mount_bracket", icon: "angle")              { viewModel.createMountBracket() }
                    templateButton("cad.kind.payload_box",   icon: "shippingbox")        { viewModel.createPayloadBox() }
                }
                .padding(10)
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 240)
        .background(GroundControlPalette.panel)
    }

    private func templateButton(_ titleKey: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            templatesPopoverShown = false
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(titleKey)).font(.system(size: 9, weight: .semibold))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            }
            .foregroundStyle(GroundControlPalette.accent)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(GroundControlPalette.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(GroundControlPalette.accent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar layout tokens  (Stage 1.15F / 1.16A-FIX-6)
    private static let tbH: CGFloat = 34
    private static let tbR: CGFloat = 8
    private static let tbIconW: CGFloat = 34
    private static let tbItemSpacing: CGFloat = 5
    private static let tbGroupPad: CGFloat = 8
    private static let tbPrimaryMinW: CGFloat = 80
    // Ribbon dimensions — multi-row compact layout (reference: KOMPAS-3D)
    private static let ribbonRowH: CGFloat = 96        // total ribbon command area height
    private static let ribbonLabelH: CGFloat = 14      // group label row height
    private static let ribbonGroupR: CGFloat = 6       // group background corner radius
    private static let ribbonGroupPadV: CGFloat = 4    // top+bottom padding around group block
    private static let ribbonGroupPadH: CGFloat = 8    // left+right padding inside group
    private static let ribbonBtnH: CGFloat = 28        // compact ribbon button height (2-row layout)
    private static let ribbonBtnGap: CGFloat = 3       // gap between button rows inside group

    private var topBarDivider: some View {
        Rectangle()
            .fill(GroundControlPalette.border)
            .frame(width: 1, height: 26)
    }

    // Ribbon group: content is a VStack of rows (HStacks). Each row = one HStack of ribbonBtn/ribbonIconBtn.
    @ViewBuilder
    private func ribbonGroup<Content: View>(_ titleKey: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Self.ribbonBtnGap) {
                content()
            }
            .padding(.horizontal, Self.ribbonGroupPadH)
            .padding(.top, 5)
            .padding(.bottom, 4)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Rectangle()
                .fill(GroundControlPalette.border.opacity(0.30))
                .frame(height: 1)
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(height: Self.ribbonLabelH)
        }
        .frame(height: Self.ribbonRowH - Self.ribbonGroupPadV * 2)
        .background(
            RoundedRectangle(cornerRadius: Self.ribbonGroupR, style: .continuous)
                .fill(GroundControlPalette.panelRaised.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.ribbonGroupR, style: .continuous)
                .stroke(GroundControlPalette.border.opacity(0.55), lineWidth: 1)
        )
        .padding(.vertical, Self.ribbonGroupPadV)
        .frame(height: Self.ribbonRowH)
    }

    private var ribbonSeparator: some View {
        Rectangle()
            .fill(GroundControlPalette.border.opacity(0.40))
            .frame(width: 1, height: Self.ribbonRowH * 0.50)
    }

    private func topBarButton(icon: String, titleKey: String, tooltipKey: String? = nil,
                              isActive: Bool, minWidth: CGFloat = Self.tbPrimaryMinW,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth).frame(height: Self.tbH)
            .background(
                RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .fill(isActive ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .stroke(isActive ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(tooltipKey ?? titleKey, comment: ""))
    }

    // MARK: - Ribbon button components (Stage 1.16A-FIX-6, reference: KOMPAS-3D)

    // Compact labeled button for ribbon rows — 28pt tall, natural width
    private func ribbonBtn(icon: String, titleKey: String, tooltipKey: String? = nil,
                           isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.ribbonBtnH)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.70)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(tooltipKey ?? titleKey, comment: ""))
    }

    // Square icon-only ribbon toggle — 28×28pt
    private func ribbonIconBtn(icon: String, titleKey: String, tooltipKey: String? = nil,
                               isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                .frame(width: Self.ribbonBtnH, height: Self.ribbonBtnH)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.50)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isOn ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(tooltipKey ?? titleKey, comment: ""))
    }

    // Disabled placeholder ribbon button — future feature stub
    private func ribbonStubBtn(icon: String, titleKey: String, helpKey: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.42))
        .padding(.horizontal, 8)
        .frame(height: Self.ribbonBtnH)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(GroundControlPalette.panelRaised.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(GroundControlPalette.border.opacity(0.35), lineWidth: 1))
        .help(NSLocalizedString(helpKey, comment: ""))
        .allowsHitTesting(false)
    }

    // Compact plane selector for ribbon Вид group — 28pt tall, monospaced
    private func ribbonPlaneBtn(_ plane: SketchPlane) -> some View {
        let isLocked = viewModel.isSelectedSketchPlaneLocked
        let active = planeIsActive(plane, isLocked: isLocked)
        let tip = isLocked
            ? "\(plane.viewName) · \(NSLocalizedString("cad.canvas.view_only", comment: ""))"
            : "\(plane.displayName) · \(plane.viewName)"
        return Button { viewModel.selectSketchPlane(plane) } label: {
            Text(plane.displayName)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(active ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: Self.ribbonBtnH)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.50)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(active ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // Compact snap dropdown for ribbon — uses ribbonBtnH
    private var ribbonSnapMenu: some View {
        let options = viewModel.canvasOptions.snapOptions
        return Menu {
            Button { viewModel.setSnapEnabled(!options.isEnabled) } label: {
                HStack {
                    Text(LocalizedStringKey("cad.canvas.snap"))
                    Spacer()
                    if options.isEnabled { Image(systemName: "checkmark") }
                }
            }
            Divider()
            snapOptionButton(titleKey: "cad.snap.option.grid",
                             isOn: options.snapToGrid,
                             action: { viewModel.setSnapToGrid(!options.snapToGrid) })
            snapOptionButton(titleKey: "cad.snap.option.sketch_vertices",
                             isOn: options.snapToSketchVertices,
                             action: { viewModel.setSnapToSketchVertices(!options.snapToSketchVertices) })
            snapOptionButton(titleKey: "cad.snap.option.body_vertices",
                             isOn: options.snapToBodyVertices,
                             action: { viewModel.setSnapToBodyVertices(!options.snapToBodyVertices) })
            snapOptionButton(titleKey: "cad.snap.option.body_edges",
                             isOn: options.snapToBodyEdges,
                             action: { viewModel.setSnapToBodyEdges(!options.snapToBodyEdges) })
            snapOptionButton(titleKey: "cad.snap.option.edge_midpoints",
                             isOn: options.snapToEdgeMidpoints,
                             action: { viewModel.setSnapToEdgeMidpoints(!options.snapToEdgeMidpoints) })
            Divider()
            snapOptionButton(titleKey: "cad.snap.option.construction_points",
                             isOn: options.snapToConstructionPoints,
                             action: { viewModel.setSnapToConstructionPoints(!options.snapToConstructionPoints) })
            snapOptionButton(titleKey: "cad.snap.option.construction_lines",
                             isOn: options.snapToConstructionLines,
                             action: { viewModel.setSnapToConstructionLines(!options.snapToConstructionLines) })
            snapOptionButton(titleKey: "cad.snap.option.construction_intersections",
                             isOn: options.snapToConstructionIntersections,
                             action: { viewModel.setSnapToConstructionIntersections(!options.snapToConstructionIntersections) })
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(options.isEnabled ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                Text(LocalizedStringKey("cad.canvas.snap"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.ribbonBtnH)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(options.isEnabled ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.70)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(options.isEnabled ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("cad.canvas.snap_options", comment: ""))
    }

    // Compact grid step dropdown for ribbon — uses ribbonBtnH
    private var ribbonGridMenu: some View {
        Menu {
            Button { viewModel.setGridStepMeters(0.01) } label: { Text("10 mm") }
            Button { viewModel.setGridStepMeters(0.025) } label: { Text("25 mm") }
            Button { viewModel.setGridStepMeters(0.05) } label: { Text("50 mm") }
            Button { viewModel.setGridStepMeters(0.10) } label: { Text("100 mm") }
        } label: {
            HStack(spacing: 4) {
                Text("\(formatDimensionMM(viewModel.canvasOptions.gridStepMeters)) mm")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.ribbonBtnH)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(GroundControlPalette.panelRaised.opacity(0.70)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("cad.canvas.grid_step", comment: ""))
    }

    private func topBarToggle(icon: String, titleKey: String, tooltipKey: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                .frame(width: Self.tbIconW, height: Self.tbH)
                .background(
                    RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                        .fill(isOn ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.50))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                        .stroke(isOn ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(tooltipKey ?? titleKey, comment: ""))
    }

    private func tbIconBtn(icon: String, isActive: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .frame(width: Self.tbIconW, height: Self.tbH)
                .background(
                    RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                        .fill(isActive ? GroundControlPalette.accent.opacity(0.24) : GroundControlPalette.panelRaised.opacity(0.50))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                        .stroke(isActive ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(tooltip, comment: ""))
    }

    private func tbFinishBtn(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text(LocalizedStringKey("cad.tool.finish"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(GroundControlPalette.success)
            .padding(.horizontal, 10)
            .frame(height: Self.tbH)
            .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .fill(GroundControlPalette.success.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .stroke(GroundControlPalette.success.opacity(0.40), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("cad.tool.finish", comment: ""))
    }

    private func tbCancelBtn(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GroundControlPalette.danger)
                .frame(width: Self.tbIconW, height: Self.tbH)
                .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .fill(GroundControlPalette.danger.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("cad.tool.cancel", comment: ""))
    }

    private var snapOptionsControl: some View {
        let options = viewModel.canvasOptions.snapOptions
        return Menu {
            Button { viewModel.setSnapEnabled(!options.isEnabled) } label: {
                HStack {
                    Text(LocalizedStringKey("cad.canvas.snap"))
                    Spacer()
                    if options.isEnabled { Image(systemName: "checkmark") }
                }
            }
            Divider()
            snapOptionButton(titleKey: "cad.snap.option.grid",
                             isOn: options.snapToGrid,
                             action: { viewModel.setSnapToGrid(!options.snapToGrid) })
            snapOptionButton(titleKey: "cad.snap.option.sketch_vertices",
                             isOn: options.snapToSketchVertices,
                             action: { viewModel.setSnapToSketchVertices(!options.snapToSketchVertices) })
            snapOptionButton(titleKey: "cad.snap.option.body_vertices",
                             isOn: options.snapToBodyVertices,
                             action: { viewModel.setSnapToBodyVertices(!options.snapToBodyVertices) })
            snapOptionButton(titleKey: "cad.snap.option.body_edges",
                             isOn: options.snapToBodyEdges,
                             action: { viewModel.setSnapToBodyEdges(!options.snapToBodyEdges) })
            snapOptionButton(titleKey: "cad.snap.option.edge_midpoints",
                             isOn: options.snapToEdgeMidpoints,
                             action: { viewModel.setSnapToEdgeMidpoints(!options.snapToEdgeMidpoints) })
            Divider()
            snapOptionButton(titleKey: "cad.snap.option.construction_points",
                             isOn: options.snapToConstructionPoints,
                             action: { viewModel.setSnapToConstructionPoints(!options.snapToConstructionPoints) })
            snapOptionButton(titleKey: "cad.snap.option.construction_lines",
                             isOn: options.snapToConstructionLines,
                             action: { viewModel.setSnapToConstructionLines(!options.snapToConstructionLines) })
            snapOptionButton(titleKey: "cad.snap.option.construction_intersections",
                             isOn: options.snapToConstructionIntersections,
                             action: { viewModel.setSnapToConstructionIntersections(!options.snapToConstructionIntersections) })
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(options.isEnabled ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.tbH)
            .background(
                RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .fill(options.isEnabled ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised.opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .stroke(options.isEnabled ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("cad.canvas.snap_options", comment: ""))
    }

    private func snapOptionButton(titleKey: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(titleKey))
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var gridStepMenu: some View {
        Menu {
            Button { viewModel.setGridStepMeters(0.01) } label: { Text("10 mm") }
            Button { viewModel.setGridStepMeters(0.025) } label: { Text("25 mm") }
            Button { viewModel.setGridStepMeters(0.05) } label: { Text("50 mm") }
            Button { viewModel.setGridStepMeters(0.10) } label: { Text("100 mm") }
        } label: {
            HStack(spacing: 3) {
                Text("\(formatDimensionMM(viewModel.canvasOptions.gridStepMeters)) mm")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.tbH)
            .background(
                RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .fill(GroundControlPalette.panelRaised.opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("cad.canvas.grid_step", comment: ""))
    }

    // Compact status badge: shown only when an asset is selected; single-line, no text wrapping
    @ViewBuilder
    private var compactStatusBadge: some View {
        if let asset = viewModel.selectedAsset {
            HStack(spacing: 4) {
                Image(systemName: isSketchAsset(asset) ? "pencil.and.outline" : "scalemass")
                    .font(.system(size: 11, weight: .semibold))
                Text(assetMassLabel(asset))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: Self.tbH)
            .background(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .fill(GroundControlPalette.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: Self.tbR, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1))
        }
    }

    // MARK: - Active Command Block (Left Sidebar)

    @ViewBuilder
    private var activeCommandBlock: some View {
        if viewModel.activeToolMode.isSketchDrawingTool {
            let mode = viewModel.activeToolMode
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.accent)
                    Text(LocalizedStringKey(mode.titleKey))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }

                Text(commandBlockPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if commandBlockCanFinish {
                        Button { commitActiveCommand() } label: {
                            Label(LocalizedStringKey("cad.tool.finish"), systemImage: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(GroundControlPalette.success)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(GroundControlPalette.success.opacity(0.15)))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(GroundControlPalette.success.opacity(0.40), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    Button { cancelActiveCommand() } label: {
                        Label(LocalizedStringKey("cad.tool.cancel"), systemImage: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GroundControlPalette.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(GroundControlPalette.danger.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(GroundControlPalette.danger.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(GroundControlPalette.inset)

            Divider().background(GroundControlPalette.border)
        }
    }

    private var commandBlockPhaseLabel: String {
        switch viewModel.activeToolMode {
        case .sketchLine:         return lineToolPhaseLabel
        case .sketchRectangle:    return rectangleToolPhaseLabel
        case .sketchCircle:       return cmdCirclePhaseLabel
        case .sketchArc:          return arcToolPhaseLabel
        case .sketchAutoline:     return cmdAutolinePhaseLabel
        case .sketchEdit:         return NSLocalizedString("cad.tool.edit", comment: "")
        case .sketchConstruction: return constructionToolPhaseLabel
        default: return ""
        }
    }

    private var cmdCirclePhaseLabel: String {
        switch viewModel.circleToolState.phase {
        case .idle, .waitingForCenter: return NSLocalizedString("cad.circle.set_center", comment: "")
        case .waitingForRadius:        return NSLocalizedString("cad.circle.set_radius", comment: "")
        }
    }

    private var cmdAutolinePhaseLabel: String {
        let count = viewModel.autolineToolState.segmentCount
        if count == 0 { return NSLocalizedString("cad.autoline.idle", comment: "") }
        return String(format: NSLocalizedString("cad.autoline.segment_count", comment: ""), count)
    }

    private var commandBlockCanFinish: Bool {
        viewModel.activeToolMode == .sketchLine || viewModel.activeToolMode == .sketchAutoline
    }

    private func commitActiveCommand() {
        switch viewModel.activeToolMode {
        case .sketchLine:     viewModel.finishLineCommand()
        case .sketchAutoline: viewModel.commitAutolineTool(close: false)
        default: break
        }
    }

    private func cancelActiveCommand() {
        switch viewModel.activeToolMode {
        case .sketchLine:         viewModel.cancelLineTool()
        case .sketchAutoline:     viewModel.cancelAutolineTool()
        case .sketchArc:          viewModel.cancelArcTool()
        case .sketchConstruction: viewModel.cancelConstructionTool()
        default:                  viewModel.setToolMode(.select)
        }
    }

    // MARK: - Left Project Tree

    private var leftProjectTreePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Active command block — shows when any sketch drawing tool is active
            activeCommandBlock

            // Tree header
            HStack {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Text(LocalizedStringKey("cad.tree.part"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Spacer()
                if !viewModel.document.assets.isEmpty {
                    Button(role: .destructive) { viewModel.resetDocument() } label: {
                        Text(LocalizedStringKey("cad.action.clear_all"))
                            .font(.caption2)
                            .foregroundStyle(GroundControlPalette.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().background(GroundControlPalette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // Origin
                    treeLeaf(icon: "plus.circle", name: NSLocalizedString("cad.tree.origin", comment: ""), level: 0, isSelected: false) {}

                    // Planes folder
                    treeFolder(icon: "square.on.square.dashed", name: NSLocalizedString("cad.tree.planes", comment: ""), isExpanded: planesExpanded) {
                        planesExpanded.toggle()
                    }
                    if planesExpanded {
                        ForEach(SketchPlane.allCases) { plane in
                            treeLeaf(
                                icon: planeIcon(plane),
                                name: plane.displayName,
                                level: 1,
                                isSelected: viewModel.selectedWorkPlane == .canonical(plane)
                                    || (viewModel.selectedWorkPlane == nil && viewModel.activeSketchPlane == plane)
                            ) {
                                viewModel.selectSketchPlane(plane)
                            }
                        }
                    }

                    // Axes folder
                    treeFolder(icon: "arrow.3.trianglepath", name: NSLocalizedString("cad.tree.axes", comment: ""), isExpanded: axesExpanded) {
                        axesExpanded.toggle()
                    }
                    if axesExpanded {
                        treeLeaf(icon: "minus", name: "X", level: 1, isSelected: false, tint: Color(red: 0.92, green: 0.22, blue: 0.20)) {}
                        treeLeaf(icon: "minus", name: "Y", level: 1, isSelected: false, tint: Color(red: 0.22, green: 0.80, blue: 0.30)) {}
                        treeLeaf(icon: "minus", name: "Z", level: 1, isSelected: false, tint: Color(red: 0.22, green: 0.48, blue: 1.00)) {}
                    }

                    // Sketches folder
                    treeFolder(icon: "pencil.and.outline", name: NSLocalizedString("cad.tree.sketches", comment: ""), count: sketchAssets.count, isExpanded: sketchesExpanded) {
                        sketchesExpanded.toggle()
                    }
                    if sketchesExpanded {
                        ForEach(sketchAssets) { asset in
                            treeLeaf(
                                icon: "pencil.and.outline",
                                name: asset.name,
                                level: 1,
                                isSelected: viewModel.selectedAssetID == asset.id
                            ) {
                                viewModel.selectSketchAndEnterNative(asset.id)
                            }
                            .contextMenu {
                                Button(NSLocalizedString("cad.action.duplicate", comment: "")) {
                                    viewModel.selectAsset(asset.id)
                                    viewModel.duplicateSelectedAsset()
                                }
                                Divider()
                                Button(NSLocalizedString("cad.action.delete", comment: ""), role: .destructive) {
                                    viewModel.selectAsset(asset.id)
                                    viewModel.deleteSelectedAsset()
                                }
                            }
                        }
                        Menu {
                            ForEach(SketchPlane.allCases) { plane in
                                Button {
                                    viewModel.createSketch(on: plane)
                                } label: {
                                    Text("\(NSLocalizedString("cad.sketch.new_on_plane", comment: "")) \(plane.displayName)")
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                Text(LocalizedStringKey("cad.sketch.new")).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(GroundControlPalette.accent)
                            .padding(.leading, 28)
                            .padding(.vertical, 4)
                        }
                        .menuStyle(.borderlessButton)
                    }

                    // Elements folder
                    treeFolder(icon: "cube", name: NSLocalizedString("cad.tree.elements", comment: ""), count: solidAssets.count, isExpanded: elementsExpanded) {
                        elementsExpanded.toggle()
                    }
                    if elementsExpanded {
                        ForEach(solidAssets) { asset in
                            treeLeaf(
                                icon: asset.kind.iconName,
                                name: asset.name,
                                level: 1,
                                isSelected: viewModel.selectedAssetID == asset.id
                            ) {
                                viewModel.selectAsset(asset.id)
                                if viewModel.activeToolMode == .sketchLine {
                                    viewModel.finishLineCommand()
                                }
                            }
                            .contextMenu {
                                Button(NSLocalizedString("cad.action.duplicate", comment: "")) {
                                    viewModel.selectAsset(asset.id)
                                    viewModel.duplicateSelectedAsset()
                                }
                                Divider()
                                Button(NSLocalizedString("cad.action.delete", comment: ""), role: .destructive) {
                                    viewModel.selectAsset(asset.id)
                                    viewModel.deleteSelectedAsset()
                                }
                            }
                        }
                        // Templates moved to toolbar "Templates" popover
                    }

                    // Extruded folder
                    treeFolder(icon: "square.3.layers.3d", name: NSLocalizedString("cad.tree.extruded", comment: ""), count: extrudedAssets.count, isExpanded: extrudedExpanded) {
                        extrudedExpanded.toggle()
                    }
                    if extrudedExpanded {
                        if extrudedAssets.isEmpty {
                            Text(LocalizedStringKey("cad.tree.extruded_empty"))
                                .font(.caption2)
                                .foregroundStyle(GroundControlPalette.textSecondary)
                                .padding(.leading, 28)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(extrudedAssets) { asset in
                                treeLeaf(
                                    icon: asset.kind.iconName,
                                    name: asset.name,
                                    level: 1,
                                    isSelected: viewModel.selectedAssetID == asset.id
                                ) {
                                    viewModel.selectAsset(asset.id)
                                }
                                .contextMenu {
                                    Button(NSLocalizedString("cad.action.duplicate", comment: "")) {
                                        viewModel.selectAsset(asset.id)
                                        viewModel.duplicateSelectedAsset()
                                    }
                                    Divider()
                                    Button(NSLocalizedString("cad.action.delete", comment: ""), role: .destructive) {
                                        viewModel.selectAsset(asset.id)
                                        viewModel.deleteSelectedAsset()
                                    }
                                }
                                if case let .extrudedSolid(parameters) = asset.kind {
                                    ForEach(parameters.boxBlindCutFeatures.indices, id: \.self) { index in
                                        treeLeaf(
                                            icon: "minus.square",
                                            name: String(format: NSLocalizedString("cad.tree.cut_extrude_feature", comment: ""), index + 1),
                                            level: 2,
                                            isSelected: false
                                        ) {
                                            viewModel.selectAsset(asset.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GroundControlPalette.panel)
    }

    private var sketchAssets: [DesignAsset] {
        viewModel.document.assets.filter { if case .sketch2D = $0.kind { return true } else { return false } }
    }

    private var solidAssets: [DesignAsset] {
        viewModel.document.assets.filter {
            if case .sketch2D      = $0.kind { return false }
            if case .extrudedSolid = $0.kind { return false }
            return true
        }
    }

    private var extrudedAssets: [DesignAsset] {
        viewModel.document.assets.filter { if case .extrudedSolid = $0.kind { return true } else { return false } }
    }

    private func treeLeaf(
        icon: String,
        name: String,
        level: Int,
        isSelected: Bool,
        tint: Color = GroundControlPalette.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(level * 14))
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? GroundControlPalette.accent : tint)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(GroundControlPalette.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? GroundControlPalette.accent.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func treeFolder(
        icon: String,
        name: String,
        count: Int? = nil,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(width: 10)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(GroundControlPalette.inset))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func createButton(_ titleKey: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 9, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(GroundControlPalette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(GroundControlPalette.accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(GroundControlPalette.accent.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func planeIcon(_ plane: SketchPlane) -> String {
        switch plane {
        case .xy: return "square"
        case .xz: return "rectangle.landscape"
        case .yz: return "rectangle.portrait"
        }
    }

    // MARK: - Center Canvas

    private var centerCanvas: some View {
        ZStack {
            DesignPreviewSceneViewRepresentable(
                document: viewModel.document,
                viewportState: viewModel.viewportState,
                cameraCommand: viewModel.pendingCameraCommand,
                lineToolState: viewModel.lineToolState,
                rectangleToolState: viewModel.rectangleToolState,
                circleToolState: viewModel.circleToolState,
                arcToolState: viewModel.arcToolState,
                autolineToolState: viewModel.autolineToolState,
                constructionToolState: viewModel.constructionToolState,
                sketchMoveToolState: viewModel.sketchMoveToolState,
                sketchParallelToolState: viewModel.sketchParallelToolState,
                sketchSplitToolState: viewModel.sketchSplitToolState,
                onMouseMoved: { result in viewModel.handleCanvasMouseMoved(result) },
                onMouseDown: { result in viewModel.handleCanvasClick(result) },
                onSketchLineSelected: { id in viewModel.selectSketchLine(id) },
                onSolidFaceSelected: { id in viewModel.selectPlanarFace(id) },
                onWorkPlaneHovered: { plane in viewModel.hoverWorkPlane(plane) },
                onWorkPlaneSelected: { plane, point, isContext in
                    viewModel.selectWorkPlane(plane, at: point, showQuickActions: plane != nil || isContext)
                },
                onKeyCode: { kc, ch in viewModel.handleCanvasKeyCode(kc, character: ch) },
                onEntityDragBegan: { id in viewModel.beginEntityDrag(entityID: id) },
                onEntityDragMoved: { delta in viewModel.updateEntityDrag(totalDelta: delta) },
                onEntityDragEnded: { delta in viewModel.endEntityDrag(totalDelta: delta) },
                onEntityDragCanceled: { viewModel.cancelEntityDrag() },
                onSketchEntityShiftSelected: { id in viewModel.toggleSketchEntitySelection(id) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.06, green: 0.08, blue: 0.10))

            // Cursor hint overlay — follows cursor, shows live dimensions
            cursorHintOverlay

            // Coordinate overlay (bottom-left, visible only in Line Tool mode)
            if viewModel.activeToolMode == .sketchLine {
                VStack {
                    Spacer()
                    HStack {
                        coordinateOverlay
                            .padding(.leading, 12)
                            .padding(.bottom, 10)
                        Spacer()
                    }
                }
            }

            if let quickAction = viewModel.workPlaneQuickAction {
                workPlaneQuickToolbar(quickAction)
            }

            // View Orientation Widget — bottom-right corner
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ViewOrientationWidget(currentMode: viewModel.viewportState.orientation) { mode in
                        viewModel.applyCameraMode(mode)
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var coordinateOverlay: some View {
        let reference = viewModel.activeCoordinateReference
        let pt = viewModel.lineToolState.cursorPoint
        let uName = reference.uAxisName
        let vName = reference.vAxisName
        let uVal = formatDimensionMM(abs(pt.u)) + (pt.u < 0 ? " (−)" : "")
        let vVal = formatDimensionMM(abs(pt.v)) + (pt.v < 0 ? " (−)" : "")
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(uName): \(formatCoord(pt.u)) mm")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text("\(vName): \(formatCoord(pt.v)) mm")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            let _ = (uVal, vVal) // suppress unused warning
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(GroundControlPalette.shell.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    // MARK: - Cursor Hint Overlay

    @ViewBuilder
    private var cursorHintOverlay: some View {
        let pos = viewModel.cursorScreenPosition
        let mode = viewModel.activeToolMode
        if mode.isSketchTool && pos != .zero {
            cursorHintContent(for: mode, at: pos)
        }
    }

    @ViewBuilder
    private func cursorHintContent(for mode: DesignWorkshopToolMode, at pos: CGPoint) -> some View {
        switch mode {
        case .sketchLine:
            let state = viewModel.lineToolState
            let hasStart = state.phantomStart != nil
            if hasStart, let len = state.currentLengthMeters, let angle = state.currentAngleDegrees {
                let snap = snapHintText(state.snapResult)
                let lines: [String] = snap.isEmpty
                    ? ["L: \(formatCoord(len * 1000)) mm", "A: \(formatCoord(angle))°"]
                    : ["L: \(formatCoord(len * 1000)) mm", "A: \(formatCoord(angle))°", "⊙ \(snap)"]
                cursorHintLabel(lines: lines, at: pos)
            } else {
                cursorHintLabel(lines: [snapHintText(state.snapResult)], at: pos)
            }

        case .sketchRectangle:
            let state = viewModel.rectangleToolState
            if let w = state.widthMeters, let h = state.heightMeters {
                let snap = snapHintText(state.snapResult)
                let lines: [String] = snap.isEmpty
                    ? ["W: \(formatCoord(w * 1000)) mm", "H: \(formatCoord(h * 1000)) mm"]
                    : ["W: \(formatCoord(w * 1000)) mm", "H: \(formatCoord(h * 1000)) mm", "⊙ \(snap)"]
                cursorHintLabel(lines: lines, at: pos)
            } else {
                cursorHintLabel(lines: [snapHintText(state.snapResult)], at: pos)
            }

        case .sketchCircle:
            let state = viewModel.circleToolState
            if let r = state.radiusMeters {
                let snap = snapHintText(state.snapResult)
                let lines: [String] = snap.isEmpty
                    ? ["R: \(formatCoord(r * 1000)) mm", "Ø: \(formatCoord(r * 2000)) mm"]
                    : ["R: \(formatCoord(r * 1000)) mm", "Ø: \(formatCoord(r * 2000)) mm", "⊙ \(snap)"]
                cursorHintLabel(lines: lines, at: pos)
            } else {
                cursorHintLabel(lines: [snapHintText(state.snapResult)], at: pos)
            }

        case .sketchArc:
            let state = viewModel.arcToolState
            if let chord = state.chordLengthMeters {
                cursorHintLabel(lines: ["chord: \(formatCoord(chord * 1000)) mm"], at: pos)
            } else {
                cursorHintLabel(lines: [snapHintText(state.snapResult)], at: pos)
            }

        case .sketchAutoline:
            let state = viewModel.autolineToolState
            if let len = state.currentLengthMeters {
                cursorHintLabel(lines: [
                    "seg: \(formatCoord(len * 1000)) mm",
                    "\(state.segmentCount) segs"
                ], at: pos)
            } else {
                cursorHintLabel(lines: [snapHintText(state.snapResult)], at: pos)
            }

        case .sketchConstruction:
            let state = viewModel.constructionToolState
            if state.firstPoint != nil, let (start, end) = state.phantomEndpoints {
                let len = sqrt(pow(end.u - start.u, 2) + pow(end.v - start.v, 2))
                cursorHintLabel(lines: ["L: \(formatCoord(len * 1000)) mm"], at: pos)
            } else {
                cursorHintLabel(lines: [snapHintText(state.snapResult)], at: pos)
            }

        case .sketchMove, .sketchCopy:
            let state = viewModel.sketchMoveToolState
            let snap = snapHintText(state.snapResult)
            if case let .waitingForDestination(grab, _) = state.phase {
                let du = state.cursorPoint.u - grab.u
                let dv = state.cursorPoint.v - grab.v
                let lines: [String] = snap.isEmpty
                    ? ["Δu: \(formatCoord(du * 1000)) mm", "Δv: \(formatCoord(dv * 1000)) mm"]
                    : ["Δu: \(formatCoord(du * 1000)) mm", "Δv: \(formatCoord(dv * 1000)) mm", "⊙ \(snap)"]
                cursorHintLabel(lines: lines, at: pos)
            } else {
                let hint = NSLocalizedString(viewModel.activeToolMode == .sketchCopy
                    ? "cad.copy.phase.select_entity" : "cad.move.phase.select_entity", comment: "")
                cursorHintLabel(lines: [hint], at: pos)
            }

        case .sketchParallel, .sketchPerpendicular:
            let state = viewModel.sketchParallelToolState
            let snap = snapHintText(state.snapResult)
            let isPerp = viewModel.activeToolMode == .sketchPerpendicular
            let phaseHint: String = {
                if case .waitingForThroughPoint = state.phase {
                    return NSLocalizedString(isPerp ? "cad.perpendicular.phase.set_through" : "cad.parallel.phase.set_through", comment: "")
                }
                return NSLocalizedString(isPerp ? "cad.perpendicular.phase.select_line" : "cad.parallel.phase.select_line", comment: "")
            }()
            let lines: [String] = snap.isEmpty ? [phaseHint] : [phaseHint, "⊙ \(snap)"]
            cursorHintLabel(lines: lines, at: pos)

        case .sketchSplit:
            let snap = snapHintText(viewModel.sketchSplitToolState.snapResult)
            let hint = NSLocalizedString("cad.split.phase.click_to_split", comment: "")
            cursorHintLabel(lines: snap.isEmpty ? [hint] : [hint, "⊙ \(snap)"], at: pos)

        case .sketchTrim:
            let snap = snapHintText(viewModel.sketchSplitToolState.snapResult)
            let hint: String = viewModel.trimExtendOpState != nil
                ? NSLocalizedString("cad.trim.phase.preview_active", comment: "")
                : NSLocalizedString("cad.trim.phase.select_endpoint", comment: "")
            cursorHintLabel(lines: snap.isEmpty ? [hint] : [hint, "⊙ \(snap)"], at: pos)

        case .sketchExtend:
            let snap = snapHintText(viewModel.sketchSplitToolState.snapResult)
            let hint: String = viewModel.trimExtendOpState != nil
                ? NSLocalizedString("cad.extend.phase.preview_active", comment: "")
                : NSLocalizedString("cad.extend.phase.select_endpoint", comment: "")
            cursorHintLabel(lines: snap.isEmpty ? [hint] : [hint, "⊙ \(snap)"], at: pos)

        default:
            EmptyView()
        }
    }

    private func cursorHintLabel(lines: [String], at pos: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .position(x: min(pos.x + 80, (NSScreen.main?.frame.width ?? 1200) - 60),
                  y: pos.y + 22)
        .allowsHitTesting(false)
    }

    private func snapHintText(_ result: CADSnapResult?) -> String {
        guard let result, let name = result.displayName, result.kind != nil else { return "" }
        return name
    }

    // MARK: - Right Context Panel

    private var rightContextPanel: some View {
        Group {
            if viewModel.activeToolMode == .sketchLine {
                lineToolPanel
            } else if viewModel.activeToolMode == .sketchRectangle {
                rectangleToolPanel
            } else if viewModel.activeToolMode == .sketchCircle {
                circleToolPanel
            } else if viewModel.activeToolMode == .sketchArc {
                arcToolPanel
            } else if viewModel.activeToolMode == .sketchAutoline {
                autolineToolPanel
            } else if viewModel.activeToolMode == .sketchConstruction {
                constructionToolPanel
            } else if viewModel.activeToolMode == .sketchMove || viewModel.activeToolMode == .sketchCopy {
                moveToolPanel
            } else if viewModel.activeToolMode == .sketchParallel || viewModel.activeToolMode == .sketchPerpendicular {
                parallelToolPanel
            } else if viewModel.activeToolMode == .sketchSplit || viewModel.activeToolMode == .sketchTrim || viewModel.activeToolMode == .sketchExtend {
                splitTrimExtendPanel
            } else if let asset = viewModel.selectedAsset {
                assetInspectorPanel(asset)
            } else if let workPlane = viewModel.selectedWorkPlane {
                workPlaneInspector(workPlane)
            } else {
                emptyInspector
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GroundControlPalette.panel)
    }

    private func workPlaneQuickToolbar(_ quickAction: CADWorkPlaneQuickAction) -> some View {
        let point = quickAction.screenPoint
        let x = max(130, point.x)
        let y = max(44, point.y - 42)
        return HStack(spacing: 6) {
            Button {
                viewModel.createSketch(on: quickAction.workPlane)
            } label: {
                quickToolbarLabel(icon: "pencil.and.outline", titleKey: "cad.workplane.create_sketch")
            }
            .buttonStyle(.plain)

            Button {
                viewModel.setViewNormalTo(workPlane: quickAction.workPlane)
            } label: {
                quickToolbarLabel(icon: "viewfinder.circle", titleKey: "cad.workplane.normal")
            }
            .buttonStyle(.plain)

            Button {
                viewModel.closeWorkPlaneQuickAction()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(GroundControlPalette.panel.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
        .position(x: x, y: y)
    }

    private func quickToolbarLabel(icon: String, titleKey: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(GroundControlPalette.accent.opacity(0.18))
        )
    }

    // MARK: Line Tool Panel

    private var lineToolPanel: some View {
        VStack(spacing: 0) {
            lineToolHeader
            Divider().background(GroundControlPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    lineParametersSection
                    numericLineCreationSection
                }
                .padding(12)
            }
        }
    }

    private var lineToolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.diagonal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("cad.tool.line"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(lineToolPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            Button { viewModel.cancelLineTool() } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var lineToolPhaseLabel: String {
        switch viewModel.lineToolState.phase {
        case .idle: return NSLocalizedString("cad.line.idle", comment: "")
        case .waitingForStart: return NSLocalizedString("cad.line.set_start", comment: "")
        case .waitingForEnd: return NSLocalizedString("cad.line.set_end", comment: "")
        }
    }

    private var lineParametersSection: some View {
        let state = viewModel.lineToolState
        let reference = viewModel.activeCoordinateReference
        let isWaiting = state.phantomStart != nil

        return ModuleSection(titleKey: "cad.section.line_params") {
            VStack(alignment: .leading, spacing: 10) {
                // Start point
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey("cad.line.start_point"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isWaiting ? GroundControlPalette.textSecondary : GroundControlPalette.accent)
                        if isWaiting {
                            Spacer()
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                    }
                    if let start = state.phantomStart {
                        HStack(spacing: 6) {
                            lineCoordReadout(label: reference.uAxisName, value: start.u)
                            lineCoordReadout(label: reference.vAxisName, value: start.v)
                        }
                    } else {
                        HStack(spacing: 6) {
                            lineCoordReadout(label: reference.uAxisName, value: state.cursorPoint.u)
                            lineCoordReadout(label: reference.vAxisName, value: state.cursorPoint.v)
                        }
                        .opacity(0.55)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.activeParameter == .startPoint
                            ? GroundControlPalette.accent.opacity(0.13)
                            : GroundControlPalette.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(state.activeParameter == .startPoint
                            ? GroundControlPalette.accent.opacity(0.45)
                            : GroundControlPalette.border, lineWidth: 1)
                )

                // End point
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("cad.line.end_point"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isWaiting ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.cursorPoint.v)
                    }
                    .opacity(isWaiting ? 1.0 : 0.45)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.activeParameter == .endPoint && isWaiting
                            ? GroundControlPalette.accent.opacity(0.13)
                            : GroundControlPalette.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(state.activeParameter == .endPoint && isWaiting
                            ? GroundControlPalette.accent.opacity(0.45)
                            : GroundControlPalette.border, lineWidth: 1)
                )

                // Length and angle (live editable, when phantom exists)
                if isWaiting {
                    HStack(spacing: 8) {
                        parametricInputField(
                            labelKey: "cad.line.length",
                            isActive: state.activeParameter == .length,
                            placeholder: "\(formatCoord((state.currentLengthMeters ?? 0) * 1000)) mm",
                            text: $draftLineLengthText
                        ) { mm in
                            viewModel.setActiveLineLength(mm / 1000.0)
                        }

                        parametricInputField(
                            labelKey: "cad.line.angle",
                            isActive: state.activeParameter == .angle,
                            placeholder: "\(formatCoord(state.currentAngleDegrees ?? 0))°",
                            text: $draftLineAngleText,
                            allowNegative: true
                        ) { deg in
                            viewModel.setActiveLineAngle(deg)
                        }
                    }
                }

                // Keyboard hints
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tab — параметр · Enter — подтвердить · Esc — отменить")
                        .font(.system(size: 9))
                        .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func lineCoordReadout(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text("\(formatCoord(value * 1000)) mm")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Editable parametric field used during sketch construction.
    /// `apply` is called on every valid keystroke (live preview) AND on Enter (commit).
    /// `allowNegative` should be true for angle fields.
    @ViewBuilder
    private func parametricInputField(
        labelKey: String,
        isActive: Bool,
        placeholder: String,
        text: Binding<String>,
        allowNegative: Bool = false,
        apply: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(labelKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isActive ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
            TextField(placeholder, text: text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .textFieldStyle(.plain)
                .onChange(of: text.wrappedValue) { newValue in
                    let cleaned = newValue.replacingOccurrences(of: ",", with: ".")
                    if let val = Double(cleaned), (allowNegative ? val.isFinite : val > 0) {
                        apply(val)
                    }
                }
                .onSubmit {
                    let cleaned = text.wrappedValue.replacingOccurrences(of: ",", with: ".")
                    if let val = Double(cleaned), (allowNegative ? val.isFinite : val > 0) {
                        apply(val)
                    }
                    text.wrappedValue = ""
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? GroundControlPalette.accent.opacity(0.13) : GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1)
        )
    }

    private var numericLineCreationSection: some View {
        guard let sketch = viewModel.selectedSketch else {
            return AnyView(
                ModuleSection(titleKey: "cad.section.sketch_line_create") {
                    Text(LocalizedStringKey("cad.line.select_sketch_first"))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            )
        }
        let reference = sketch.reference
        return AnyView(
            ModuleSection(titleKey: "cad.section.sketch_line_create") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        sketchDraftField(label: "\(reference.uAxisName)1", value: $draftLineStartU)
                        sketchDraftField(label: "\(reference.vAxisName)1", value: $draftLineStartV)
                    }
                    HStack(spacing: 6) {
                        sketchDraftField(label: "\(reference.uAxisName)2", value: $draftLineEndU)
                        sketchDraftField(label: "\(reference.vAxisName)2", value: $draftLineEndV)
                    }
                    Button {
                        viewModel.addSketchLine(
                            start: SketchPoint2D(
                                u: clampFinite(draftLineStartU, to: -10000...10000) / 1000,
                                v: clampFinite(draftLineStartV, to: -10000...10000) / 1000
                            ),
                            end: SketchPoint2D(
                                u: clampFinite(draftLineEndU, to: -10000...10000) / 1000,
                                v: clampFinite(draftLineEndV, to: -10000...10000) / 1000
                            )
                        )
                        draftLineStartU = draftLineEndU
                        draftLineStartV = draftLineEndV
                        draftLineEndU = clampFinite(draftLineEndU + 100, to: -10000...10000)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text(LocalizedStringKey("cad.sketch.add_line")).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(GroundControlPalette.accent)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.34), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        )
    }

    private func sketchDraftField(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 4) {
                TextField(label, value: value, formatter: WorkshopNumberFormatter.decimal)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text(LocalizedStringKey("cad.unit.mm"))
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }

    // MARK: Rectangle Tool Panel

    private var rectangleToolPanel: some View {
        VStack(spacing: 0) {
            rectangleToolHeader
            Divider().background(GroundControlPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    rectangleInputModeSection
                    rectangleCoordSection
                }
                .padding(12)
            }
        }
    }

    private var rectangleToolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("cad.tool.rectangle"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(rectangleToolPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            Button { viewModel.setToolMode(.select) } label: {
                Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var rectangleToolPhaseLabel: String {
        switch viewModel.rectangleToolState.phase {
        case .idle, .waitingForFirstCorner: return NSLocalizedString("cad.rectangle.set_first_corner", comment: "")
        case .waitingForOppositeCorner: return NSLocalizedString("cad.rectangle.set_opposite_corner", comment: "")
        }
    }

    private var rectangleInputModeSection: some View {
        ModuleSection(titleKey: "cad.section.rectangle_params") {
            VStack(spacing: 4) {
                ForEach(RectangleInputMode.allCases) { mode in
                    Button { viewModel.rectangleInputMode = mode } label: {
                        HStack(spacing: 8) {
                            Image(systemName: mode.iconName).font(.system(size: 11, weight: .semibold)).frame(width: 16)
                            Text(LocalizedStringKey(mode.titleKey)).font(.caption.weight(.semibold))
                            Spacer()
                            if viewModel.rectangleInputMode == mode {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(GroundControlPalette.accent)
                            }
                        }
                        .foregroundStyle(viewModel.rectangleInputMode == mode ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(viewModel.rectangleInputMode == mode ? GroundControlPalette.accent.opacity(0.14) : GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(viewModel.rectangleInputMode == mode ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rectangleCoordSection: some View {
        let state = viewModel.rectangleToolState
        let reference = viewModel.activeCoordinateReference
        let hasFirst = state.firstCorner != nil
        return ModuleSection(titleKey: "cad.section.line_params") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey("cad.rectangle.first_corner"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(hasFirst ? GroundControlPalette.textSecondary : GroundControlPalette.accent)
                        if hasFirst { Spacer(); Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary) }
                    }
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.firstCorner?.u ?? state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.firstCorner?.v ?? state.cursorPoint.v)
                    }
                    .opacity(hasFirst ? 1.0 : 0.55)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("cad.rectangle.opposite_corner"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(hasFirst ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.cursorPoint.v)
                    }
                    .opacity(hasFirst ? 1.0 : 0.45)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hasFirst ? GroundControlPalette.accent.opacity(0.10) : GroundControlPalette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hasFirst ? GroundControlPalette.accent.opacity(0.40) : GroundControlPalette.border, lineWidth: 1))

                if hasFirst, let w = state.widthMeters, let h = state.heightMeters {
                    HStack(spacing: 8) {
                        parametricInputField(
                            labelKey: "cad.rectangle.width",
                            isActive: false,
                            placeholder: "\(formatCoord(w * 1000)) mm",
                            text: $draftRectWidthText
                        ) { mm in
                            viewModel.setActiveRectangleWidth(mm / 1000.0)
                        }

                        parametricInputField(
                            labelKey: "cad.rectangle.height",
                            isActive: false,
                            placeholder: "\(formatCoord(h * 1000)) mm",
                            text: $draftRectHeightText
                        ) { mm in
                            viewModel.setActiveRectangleHeight(mm / 1000.0)
                        }
                    }
                }

                Text("Esc — cancel").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary.opacity(0.65))
            }
        }
    }

    // MARK: Circle Tool Panel

    private var circleToolPanel: some View {
        VStack(spacing: 0) {
            circleToolHeader
            Divider().background(GroundControlPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    circleInputModeSection
                    circleCoordSection
                }
                .padding(12)
            }
        }
    }

    private var circleToolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("cad.tool.circle"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(circleToolPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            Button { viewModel.setToolMode(.select) } label: {
                Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var circleToolPhaseLabel: String {
        switch viewModel.circleToolState.phase {
        case .idle, .waitingForCenter: return NSLocalizedString("cad.circle.set_center", comment: "")
        case .waitingForRadius: return NSLocalizedString("cad.circle.set_radius", comment: "")
        }
    }

    private var circleInputModeSection: some View {
        ModuleSection(titleKey: "cad.section.circle_params") {
            VStack(spacing: 4) {
                ForEach(CircleInputMode.allCases) { mode in
                    Button { viewModel.circleInputMode = mode } label: {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(mode.titleKey)).font(.caption.weight(.semibold))
                            Spacer()
                            if viewModel.circleInputMode == mode {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(GroundControlPalette.accent)
                            }
                        }
                        .foregroundStyle(viewModel.circleInputMode == mode ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(viewModel.circleInputMode == mode ? GroundControlPalette.accent.opacity(0.14) : GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(viewModel.circleInputMode == mode ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var circleCoordSection: some View {
        let state = viewModel.circleToolState
        let reference = viewModel.activeCoordinateReference
        let hasCenter = state.center != nil
        return ModuleSection(titleKey: "cad.section.line_params") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey("cad.circle.center"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(hasCenter ? GroundControlPalette.textSecondary : GroundControlPalette.accent)
                        if hasCenter { Spacer(); Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary) }
                    }
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.center?.u ?? state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.center?.v ?? state.cursorPoint.v)
                    }
                    .opacity(hasCenter ? 1.0 : 0.55)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))

                if hasCenter, let r = state.radiusMeters {
                    HStack(spacing: 8) {
                        parametricInputField(
                            labelKey: "cad.circle.radius",
                            isActive: false,
                            placeholder: "R \(formatCoord(r * 1000)) mm",
                            text: $draftCircleRadiusText
                        ) { mm in
                            viewModel.setActiveCircleRadius(mm / 1000.0)
                        }

                        parametricInputField(
                            labelKey: "cad.circle.diameter",
                            isActive: false,
                            placeholder: "Ø \(formatCoord(r * 2000)) mm",
                            text: $draftCircleDiamText
                        ) { mm in
                            viewModel.setActiveCircleDiameter(mm / 1000.0)
                        }
                    }
                }

                Text("Esc — cancel").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary.opacity(0.65))
            }
        }
    }

    // MARK: Arc Tool Panel

    private var arcToolPanel: some View {
        VStack(spacing: 0) {
            arcToolHeader
            Divider().background(GroundControlPalette.border)
            ScrollView {
                arcCoordSection.padding(12)
            }
        }
    }

    private var arcToolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arc")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("cad.tool.arc"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(arcToolPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            Button { viewModel.cancelArcTool() } label: {
                Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var arcToolPhaseLabel: String {
        switch viewModel.arcToolState.phase {
        case .idle, .waitingForStart: return NSLocalizedString("cad.arc.set_start", comment: "")
        case .waitingForEnd:          return NSLocalizedString("cad.arc.set_end", comment: "")
        case .waitingForMid:          return NSLocalizedString("cad.arc.set_mid", comment: "")
        }
    }

    private var arcCoordSection: some View {
        let state = viewModel.arcToolState
        let reference = viewModel.activeCoordinateReference
        return ModuleSection(titleKey: "cad.section.arc_params") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey("cad.line.start_point"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(state.startPoint != nil ? GroundControlPalette.textSecondary : GroundControlPalette.accent)
                        if state.startPoint != nil { Spacer(); Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary) }
                    }
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.startPoint?.u ?? state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.startPoint?.v ?? state.cursorPoint.v)
                    }
                    .opacity(state.startPoint != nil ? 1.0 : 0.55)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey("cad.line.end_point"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                state.endPoint != nil ? GroundControlPalette.textSecondary :
                                state.startPoint != nil ? GroundControlPalette.accent :
                                GroundControlPalette.textSecondary
                            )
                        if state.endPoint != nil { Spacer(); Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary) }
                    }
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.endPoint?.u ?? state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.endPoint?.v ?? state.cursorPoint.v)
                    }
                    .opacity(state.endPoint != nil ? 1.0 : state.startPoint != nil ? 1.0 : 0.45)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(state.startPoint != nil && state.endPoint == nil
                        ? GroundControlPalette.accent.opacity(0.10) : GroundControlPalette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(state.startPoint != nil && state.endPoint == nil
                        ? GroundControlPalette.accent.opacity(0.40) : GroundControlPalette.border, lineWidth: 1))

                if state.endPoint != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("cad.arc.mid_point"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.accent)
                        HStack(spacing: 6) {
                            lineCoordReadout(label: reference.uAxisName, value: state.cursorPoint.u)
                            lineCoordReadout(label: reference.vAxisName, value: state.cursorPoint.v)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.40), lineWidth: 1))

                    if let chord = state.chordLengthMeters {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey("cad.arc.chord_length")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textSecondary)
                            Text("\(formatCoord(chord * 1000)) mm").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(GroundControlPalette.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                    }
                }

                Text("Esc — step back · Esc×2 — cancel").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary.opacity(0.65))
            }
        }
    }

    // MARK: Autoline Tool Panel

    private var autolineToolPanel: some View {
        VStack(spacing: 0) {
            autolineToolHeader
            Divider().background(GroundControlPalette.border)
            ScrollView {
                autolineCoordSection.padding(12)
            }
        }
    }

    private var autolineToolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("cad.tool.autoline"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(autolineToolPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            Button { viewModel.cancelAutolineTool() } label: {
                Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var autolineToolPhaseLabel: String {
        let state = viewModel.autolineToolState
        let n = state.segmentCount
        if n > 0 { return String(format: NSLocalizedString("cad.autoline.segment_count", comment: ""), n) }
        return NSLocalizedString("cad.autoline.idle", comment: "")
    }

    private var autolineCoordSection: some View {
        let state = viewModel.autolineToolState
        let reference = viewModel.activeCoordinateReference
        return ModuleSection(titleKey: "cad.section.autoline_params") {
            VStack(alignment: .leading, spacing: 10) {
                if let last = state.lastPoint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("cad.autoline.last_point"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        HStack(spacing: 6) {
                            lineCoordReadout(label: reference.uAxisName, value: last.u)
                            lineCoordReadout(label: reference.vAxisName, value: last.v)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("cad.autoline.next_point"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.accent)
                    HStack(spacing: 6) {
                        lineCoordReadout(label: reference.uAxisName, value: state.cursorPoint.u)
                        lineCoordReadout(label: reference.vAxisName, value: state.cursorPoint.v)
                    }
                    if let len = state.currentLengthMeters {
                        Text("\(formatCoord(len * 1000)) mm").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(GroundControlPalette.textSecondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.40), lineWidth: 1))

                if state.points.count >= 2 {
                    VStack(spacing: 6) {
                        Button { viewModel.commitAutolineTool(close: false) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                Text(LocalizedStringKey("cad.autoline.finish")).font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(GroundControlPalette.textPrimary)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.22)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.50), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        if state.points.count >= 3 {
                            Button { viewModel.commitAutolineTool(close: true) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .bold))
                                    Text(LocalizedStringKey("cad.autoline.finish_close")).font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .foregroundStyle(GroundControlPalette.accent)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Enter — finish · Esc — cancel").font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary.opacity(0.65))
            }
        }
    }

    // MARK: Construction Tool Panel

    private var constructionToolPanel: some View {
        VStack(spacing: 0) {
            constructionToolHeader
            Divider().background(GroundControlPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    constructionSubModeSection
                    constructionInfoNote
                }
                .padding(12)
            }
        }
    }

    private var constructionToolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("cad.tool.construction"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text(constructionToolPhaseLabel)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            Button { viewModel.cancelConstructionTool() } label: {
                Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var constructionToolPhaseLabel: String {
        viewModel.constructionToolState.firstPoint != nil
            ? NSLocalizedString("cad.construction.phase_hint.set_end", comment: "")
            : NSLocalizedString("cad.construction.phase_hint.set_start", comment: "")
    }

    private var constructionSubModeSection: some View {
        ModuleSection(titleKey: "cad.construction.mode") {
            VStack(spacing: 4) {
                ForEach(ConstructionToolSubMode.allCases) { subMode in
                    Button { viewModel.setConstructionToolSubMode(subMode) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: subMode.iconName)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 16)
                            Text(LocalizedStringKey(subMode.titleKey))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if viewModel.constructionToolState.subMode == subMode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(GroundControlPalette.accent)
                            }
                        }
                        .foregroundStyle(viewModel.constructionToolState.subMode == subMode
                            ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(viewModel.constructionToolState.subMode == subMode
                                ? GroundControlPalette.accent.opacity(0.14) : GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(viewModel.constructionToolState.subMode == subMode
                                ? GroundControlPalette.accent.opacity(0.45) : GroundControlPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.constructionToolState.subMode == .pointAndAngle {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(LocalizedStringKey("cad.construction.angle"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        HStack(spacing: 4) {
                            TextField("0", value: Binding(
                                get: { viewModel.constructionToolState.angleDegrees },
                                set: { viewModel.setConstructionAngle($0) }
                            ), formatter: WorkshopNumberFormatter.decimal)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            Text(LocalizedStringKey("cad.unit.deg"))
                                .font(.caption2)
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var constructionInfoNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(LocalizedStringKey("cad.construction.info"))
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: - Move / Copy Tool Panel

    private var moveToolPanel: some View {
        let isCopy = viewModel.activeToolMode == .sketchCopy
        let selectedCount = viewModel.selectedSketchEntityIDs.isEmpty
            ? (viewModel.selectedSketchEntityID != nil ? 1 : 0)
            : viewModel.selectedSketchEntityIDs.count
        let hasSelection = selectedCount > 0
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isCopy ? DesignWorkshopToolMode.sketchCopy.iconName : DesignWorkshopToolMode.sketchMove.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(isCopy ? "cad.tool.copy" : "cad.tool.move"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text(hasSelection
                         ? NSLocalizedString(isCopy ? "cad.copy.phase.set_destination" : "cad.move.phase.set_destination", comment: "")
                         : NSLocalizedString(isCopy ? "cad.copy.phase.select_entity" : "cad.move.phase.select_entity", comment: ""))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                Spacer()
                Button { viewModel.setToolMode(.select) } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider().background(GroundControlPalette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if hasSelection {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(GroundControlPalette.accent)
                            Text(selectedCount == 1
                                 ? NSLocalizedString("cad.move.selected_one", comment: "")
                                 : String(format: NSLocalizedString("cad.move.selected_many", comment: ""), selectedCount))
                                .font(.caption2)
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GroundControlPalette.border, lineWidth: 1))
                    }
                    modifyInfoNote(isCopy ? "cad.copy.phase.select_entity" : "cad.move.drag_hint")
                }
                .padding(12)
            }
        }
    }

    // MARK: - Parallel / Perpendicular Tool Panel

    private var parallelToolPanel: some View {
        let isPerp = viewModel.activeToolMode == .sketchPerpendicular
        let state = viewModel.sketchParallelToolState
        let phaseKey: String = {
            if case .waitingForThroughPoint = state.phase {
                return isPerp ? "cad.perpendicular.phase.set_through" : "cad.parallel.phase.set_through"
            }
            return isPerp ? "cad.perpendicular.phase.select_line" : "cad.parallel.phase.select_line"
        }()
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isPerp ? DesignWorkshopToolMode.sketchPerpendicular.iconName : DesignWorkshopToolMode.sketchParallel.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(isPerp ? "cad.tool.perpendicular" : "cad.tool.parallel"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text(NSLocalizedString(phaseKey, comment: ""))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                Spacer()
                Button { viewModel.setToolMode(.select) } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider().background(GroundControlPalette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    modifyInfoNote(isPerp ? "cad.perpendicular.phase.select_line" : "cad.parallel.phase.select_line")
                }
                .padding(12)
            }
        }
    }

    // MARK: - Split / Trim / Extend Tool Panel

    private var splitTrimExtendPanel: some View {
        let mode = viewModel.activeToolMode
        let isTrimExtend = mode == .sketchTrim || mode == .sketchExtend
        let (titleKey, icon): (String, String) = {
            switch mode {
            case .sketchSplit:  return ("cad.tool.split",  DesignWorkshopToolMode.sketchSplit.iconName)
            case .sketchTrim:   return ("cad.tool.trim",   DesignWorkshopToolMode.sketchTrim.iconName)
            default:            return ("cad.tool.extend", DesignWorkshopToolMode.sketchExtend.iconName)
            }
        }()
        let op = viewModel.trimExtendOpState
        let phaseKey: String = {
            guard isTrimExtend else { return "cad.split.phase.click_to_split" }
            if op != nil { return mode == .sketchTrim ? "cad.trim.phase.preview_active" : "cad.extend.phase.preview_active" }
            return mode == .sketchTrim ? "cad.trim.phase.select_endpoint" : "cad.extend.phase.select_endpoint"
        }()

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(titleKey))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text(NSLocalizedString(phaseKey, comment: ""))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                Spacer()
                Button { viewModel.setToolMode(.select) } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 14)).foregroundStyle(GroundControlPalette.danger)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider().background(GroundControlPalette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    modifyInfoNote(phaseKey)

                    if isTrimExtend {
                        if let op {
                            trimExtendOperationPanel(op: op, mode: mode)
                        } else {
                            // Phase 1: no endpoint locked yet — show hover hint only.
                            trimExtendPhase1Hint(mode: mode)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func trimExtendPhase1Hint(mode: DesignWorkshopToolMode) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 11))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(NSLocalizedString(
                mode == .sketchTrim ? "cad.trim.hint.click_endpoint" : "cad.extend.hint.click_endpoint",
                comment: ""
            ))
            .font(.caption2)
            .foregroundStyle(GroundControlPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(GroundControlPalette.inset))
    }

    @ViewBuilder
    private func trimExtendOperationPanel(op: TrimExtendOperationState, mode: DesignWorkshopToolMode) -> some View {
        let isTrim = mode == .sketchTrim
        let lineLenMM = op.anchorPoint.distance(to: op.oppositePoint) * 1000
        let previewLenMM: Double? = op.isPreviewActive
            ? op.previewAnchorPoint.map { $0.distance(to: op.oppositePoint) * 1000 }
            : nil
        let deltaMM: Double? = previewLenMM.map { $0 - lineLenMM }

        // --- Line info row ---
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("cad.trim_extend.selected_line", comment: ""))
                .font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
            HStack {
                Text(NSLocalizedString(op.fromStart ? "cad.trim_extend.endpoint_start" : "cad.trim_extend.endpoint_end", comment: ""))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                Spacer()
                Text(String(format: NSLocalizedString("cad.trim_extend.line_length_mm", comment: ""), lineLenMM))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GroundControlPalette.border, lineWidth: 1))

        // --- Mode + target type + validation ---
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: op.mode == .target ? "scope" : "textformat.123")
                    .font(.system(size: 10))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Text(NSLocalizedString(op.mode == .target ? "cad.trim_extend.mode_target" : "cad.trim_extend.mode_numeric", comment: ""))
                    .font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                let statusColor: Color = op.validation == .valid ? .green
                    : (op.validation == .noTarget ? GroundControlPalette.accent : GroundControlPalette.danger)
                Text(NSLocalizedString(op.validation.labelKey, comment: ""))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(statusColor)
            }
            if op.mode == .target, op.targetType != .none {
                HStack(spacing: 4) {
                    Image(systemName: op.targetType.iconName)
                        .font(.system(size: 9))
                        .foregroundStyle(GroundControlPalette.accent)
                    Text(NSLocalizedString(op.targetType.labelKey, comment: ""))
                        .font(.system(size: 9)).foregroundStyle(GroundControlPalette.accent)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(GroundControlPalette.inset))

        // --- Preview metrics ---
        if let previewMM = previewLenMM, let delta = deltaMM {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(NSLocalizedString("cad.trim_extend.preview_length", comment: ""))
                        .font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
                    Spacer()
                    Text(String(format: "%.2f мм", previewMM))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green)
                }
                HStack {
                    Text(NSLocalizedString("cad.trim_extend.delta", comment: ""))
                        .font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
                    Spacer()
                    let deltaStr = delta >= 0
                        ? String(format: "+%.2f мм", delta)
                        : String(format: "%.2f мм", delta)
                    Text(deltaStr)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(delta >= 0 ? GroundControlPalette.accent : GroundControlPalette.danger)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(GroundControlPalette.inset))
        }

        // --- Numeric distance input ---
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(isTrim ? "cad.trim_extend.trim_distance_label" : "cad.trim_extend.extend_distance_label", comment: ""))
                .font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 6) {
                TextField(
                    NSLocalizedString("cad.trim_extend.distance_placeholder", comment: ""),
                    text: $trimExtendDistanceMM
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity)
                .onChange(of: trimExtendDistanceMM) { _, newVal in
                    let normalized = newVal.replacingOccurrences(of: ",", with: ".")
                    if let v = Double(normalized), v > 0 {
                        viewModel.setTrimExtendNumericDistance(v)
                    } else if newVal.isEmpty {
                        // Field cleared → return to target mode, preview stays.
                        viewModel.setTrimExtendNumericDistance(0)
                    }
                }
                .onSubmit { applyTrimExtendDistance() }

                Button { applyTrimExtendDistance() } label: {
                    Text(NSLocalizedString("cad.trim_extend.apply", comment: ""))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(op.isPreviewActive ? GroundControlPalette.accent : GroundControlPalette.textSecondary))
                }
                .buttonStyle(.plain)
                .disabled(!op.isPreviewActive)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GroundControlPalette.border, lineWidth: 1))

        // --- Action buttons ---
        HStack(spacing: 8) {
            Button {
                viewModel.cancelTrimExtendOperation()
                trimExtendDistanceMM = ""
            } label: {
                Text(NSLocalizedString("cad.trim_extend.cancel", comment: ""))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.danger)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(GroundControlPalette.inset))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(GroundControlPalette.danger.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button { applyTrimExtendDistance() } label: {
                Text(NSLocalizedString("cad.trim_extend.enter_to_apply", comment: ""))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(op.isPreviewActive ? .white : GroundControlPalette.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(op.isPreviewActive ? GroundControlPalette.accent : GroundControlPalette.inset))
            }
            .buttonStyle(.plain)
            .disabled(!op.isPreviewActive)
        }
    }

    private func applyTrimExtendDistance() {
        if let val = Double(trimExtendDistanceMM.replacingOccurrences(of: ",", with: ".")), val > 0 {
            viewModel.setTrimExtendNumericDistance(val)
            viewModel.applyTrimExtendOperation()
            trimExtendDistanceMM = ""
        } else {
            // No numeric input: apply target-mode preview via Enter key equivalent.
            viewModel.applyTrimExtendOperation()
        }
    }

    private func modifyInfoNote(_ hintKey: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(NSLocalizedString(hintKey, comment: ""))
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: - Asset Inspector Panel

    private func assetInspectorPanel(_ asset: DesignAsset) -> some View {
        VStack(spacing: 0) {
            inspectorHeader(asset)
            Divider().background(GroundControlPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    assetNameEditor(asset)
                    transformSection(asset)
                    if isSketchAsset(asset) {
                        sketchInspector(asset)
                    } else if case let .extrudedSolid(parameters) = asset.kind {
                        extrudedSolidInspector(asset, parameters: parameters)
                    } else {
                        materialPicker(asset)
                        kindParameters(asset)
                        massInfoSection(asset)
                        attachmentPointsSection(asset)
                    }
                }
                .padding(12)
            }
        }
    }

    private func inspectorHeader(_ asset: DesignAsset) -> some View {
        HStack(spacing: 10) {
            Image(systemName: asset.kind.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GroundControlPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .lineLimit(1)
                Text(asset.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button { viewModel.duplicateSelectedAsset() } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(GroundControlPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("cad.action.duplicate", comment: ""))
                Button { viewModel.deleteSelectedAsset() } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(GroundControlPalette.danger)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("cad.action.delete", comment: ""))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyInspector: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.45))
            Text(LocalizedStringKey("cad.selection.empty"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey("cad.selection.empty_hint"))
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func workPlaneInspector(_ workPlane: CADWorkPlane) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: workPlane.isCanonical ? "square.on.square.dashed" : "square.dashed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("cad.workplane.inspector_title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text(workPlane.displayName)
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(GroundControlPalette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ModuleSection(titleKey: "cad.workplane.selected") {
                        VStack(alignment: .leading, spacing: 8) {
                            WorkshopMetricCell(
                                labelKey: "cad.extrude.source_plane",
                                value: workPlane.reference.displayName
                            )
                            WorkshopMetricCell(
                                labelKey: "cad.metric.bounding",
                                value: "\(formatDimensionMM(workPlane.focusRadius * 2000)) \(NSLocalizedString("cad.unit.mm", comment: ""))"
                            )
                            Button {
                                viewModel.createSketch(on: workPlane)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "pencil.and.outline")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(LocalizedStringKey("cad.workplane.create_sketch"))
                                        .font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(GroundControlPalette.textPrimary)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.22)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.50), lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.setViewNormalTo(workPlane: workPlane)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "viewfinder.circle")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(LocalizedStringKey("cad.workplane.normal"))
                                        .font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(GroundControlPalette.accent)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Inspector Sections

    private func assetNameEditor(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.identity") {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey("cad.field.name"))
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                TextField(
                    "",
                    text: Binding(
                        get: { asset.name },
                        set: { viewModel.updateSelectedAssetName($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func transformSection(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.transform") {
            VStack(alignment: .leading, spacing: 10) {
                transformRow(
                    titleKey: "cad.transform.position",
                    unit: NSLocalizedString("cad.unit.mm", comment: ""),
                    bindings: [
                        ("X", positionBinding(\.positionX)),
                        ("Y", positionBinding(\.positionY)),
                        ("Z", positionBinding(\.positionZ)),
                    ]
                )
                transformRow(
                    titleKey: "cad.transform.rotation",
                    unit: NSLocalizedString("cad.unit.deg", comment: ""),
                    bindings: [
                        ("X", rotationBinding(\.rotationX)),
                        ("Y", rotationBinding(\.rotationY)),
                        ("Z", rotationBinding(\.rotationZ)),
                    ]
                )
            }
        }
    }

    private func transformRow(titleKey: String, unit: String, bindings: [(String, Binding<Double>)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 6) {
                ForEach(bindings, id: \.0) { item in
                    numericTransformField(axis: item.0, unit: unit, value: item.1)
                }
            }
        }
    }

    private func numericTransformField(axis: String, unit: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(axis)
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 4) {
                TextField(axis, value: value, formatter: WorkshopNumberFormatter.decimal)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 48)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(width: 22, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func positionBinding(_ keyPath: WritableKeyPath<DesignTransform, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let transform = viewModel.selectedAsset?.transform else { return 0 }
                return clampFinite(transform[keyPath: keyPath] * 1000, to: -10000...10000)
            },
            set: { newValue in
                guard var transform = viewModel.selectedAsset?.transform else { return }
                transform[keyPath: keyPath] = clampFinite(newValue, to: -10000...10000) / 1000
                viewModel.updateSelectedAssetTransform(transform)
            }
        )
    }

    private func rotationBinding(_ keyPath: WritableKeyPath<DesignTransform, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let transform = viewModel.selectedAsset?.transform else { return 0 }
                return clampFinite(transform[keyPath: keyPath] * 180 / Double.pi, to: -360...360)
            },
            set: { newValue in
                guard var transform = viewModel.selectedAsset?.transform else { return }
                transform[keyPath: keyPath] = clampFinite(newValue, to: -360...360) * Double.pi / 180
                viewModel.updateSelectedAssetTransform(transform)
            }
        )
    }

    private func materialPicker(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.material") {
            VStack(spacing: 6) {
                ForEach(DesignMaterial.allCases) { material in
                    materialButton(material, selectedMaterial: asset.material)
                }
            }
        }
    }

    private func materialButton(_ material: DesignMaterial, selectedMaterial: DesignMaterial) -> some View {
        let isSelected = material == selectedMaterial
        let rgb = material.previewColorRGB
        return Button {
            viewModel.updateSelectedAssetMaterial(material)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b)))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(GroundControlPalette.borderStrong, lineWidth: 1))
                Text(material.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                Spacer()
                Text(formatDensity(material.densityKgPerM3))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? GroundControlPalette.accent.opacity(0.62) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func kindParameters(_ asset: DesignAsset) -> some View {
        switch asset.kind {
        case let .basicWing(p):    basicWingEditor(p)
        case let .framePlate(p):   framePlateEditor(p)
        case let .beam(p):         beamEditor(p)
        case let .tube(p):         tubeEditor(p)
        case let .mountBracket(p): mountBracketEditor(p)
        case let .payloadBox(p):   payloadBoxEditor(p)
        case .sketch2D:            EmptyView()
        case let .extrudedSolid(p): extrudedSolidInfo(asset, parameters: p)
        }
    }

    @ViewBuilder
    private func extrudedSolidInspector(_ asset: DesignAsset, parameters: ExtrudedSolidParameters) -> some View {
        materialPicker(asset)
        extrudedSolidInfo(asset, parameters: parameters)
        massInfoSection(asset)
        attachmentPointsSection(asset)
    }

    private func extrudedSolidInfo(_ asset: DesignAsset, parameters p: ExtrudedSolidParameters) -> some View {
        ModuleSection(titleKey: "cad.section.extruded_solid") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    WorkshopMetricCell(labelKey: "cad.extrude.source", value: viewModel.sourceSketchDisplayName(for: p))
                    WorkshopMetricCell(labelKey: "cad.extrude.source_plane", value: p.sourceReference.displayName)
                    WorkshopMetricCell(labelKey: "cad.extrude.profile_points", value: "\(p.profilePoints.count)")
                    WorkshopMetricCell(labelKey: "cad.extrude.volume", value: formatVolume(p.volumeMeters3))
                }

                mmSlider("cad.extrude.depth", value: p.depthMeters, range: 0.001...5.0) { depth in
                    viewModel.updateSelectedExtrudedSolidDepth(depth)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey("cad.extrude.direction"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Picker("", selection: Binding(
                        get: { p.direction },
                        set: { viewModel.updateSelectedExtrudedSolidDirection($0) }
                    )) {
                        ForEach(ExtrudeDirection.allCases) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    WorkshopMetricCell(labelKey: "cad.metric.bounding", value: "\(formatDimensions(asset.massProperties)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                    WorkshopMetricCell(labelKey: "cad.metric.material", value: asset.material.displayName)
                }

                Divider().background(GroundControlPalette.border)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(LocalizedStringKey("cad.face.list"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                        Spacer()
                        Text("\(p.faces.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }
                    if p.faces.isEmpty {
                        warningCallout("cad.face.none")
                    } else {
                        VStack(spacing: 5) {
                            ForEach(p.faces) { face in
                                faceRow(face)
                            }
                        }
                        if let face = viewModel.selectedPlanarFace {
                            HStack(spacing: 6) {
                                Image(systemName: "square.dashed")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(GroundControlPalette.accent)
                                Text(String(format: NSLocalizedString("cad.face.selected", comment: ""), face.name))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(GroundControlPalette.textPrimary)
                                Spacer()
                            }
                            Button {
                                viewModel.createSketchOnSelectedFace()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "pencil.and.outline")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(LocalizedStringKey("cad.face.new_sketch"))
                                        .font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(GroundControlPalette.textPrimary)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.22)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.50), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            Button {
                                viewModel.setViewNormalTo(workPlane: .face(face))
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "viewfinder.circle")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(LocalizedStringKey("cad.workplane.normal"))
                                        .font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(GroundControlPalette.accent)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(LocalizedStringKey("cad.face.select_hint"))
                                .font(.caption2)
                                .foregroundStyle(GroundControlPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func faceRow(_ face: DesignPlanarFace) -> some View {
        let isSelected = viewModel.selectedFaceID == face.id
        return Button {
            viewModel.selectPlanarFace(face.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                    .frame(width: 14)
                Text(face.name)
                    .font(.caption.weight(isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(GroundControlPalette.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? GroundControlPalette.accent.opacity(0.16) : GroundControlPalette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func massInfoSection(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.mass_info") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                WorkshopMetricCell(labelKey: "cad.metric.mass", value: formatMass(asset.massProperties.massKg))
                WorkshopMetricCell(labelKey: "cad.metric.material", value: asset.material.displayName)
                WorkshopMetricCell(labelKey: "cad.metric.bounding", value: "\(formatDimensions(asset.massProperties)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                WorkshopMetricCell(labelKey: "cad.metric.attach_pts", value: "\(asset.attachmentPoints.count)")
            }
        }
    }

    @ViewBuilder
    private func attachmentPointsSection(_ asset: DesignAsset) -> some View {
        ModuleSection(titleKey: "cad.section.attachment_points") {
            VStack(alignment: .leading, spacing: 8) {
                attachmentPointToolbar(asset)
                if asset.attachmentPoints.isEmpty {
                    attachmentPointEmptyState
                } else {
                    VStack(spacing: 5) {
                        ForEach(asset.attachmentPoints) { point in
                            attachmentPointRow(point)
                        }
                    }
                }
                ForEach(viewModel.attachmentPointWarningKeys(for: asset), id: \.self) { key in
                    warningCallout(key)
                }
                if let point = viewModel.selectedAttachmentPoint {
                    Divider().background(GroundControlPalette.border).padding(.vertical, 2)
                    attachmentPointEditor(point)
                } else if !asset.attachmentPoints.isEmpty {
                    attachmentPointNoSelectionState
                }
            }
        }
    }

    private func attachmentPointToolbar(_ asset: DesignAsset) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("cad.attachment.count", comment: ""), asset.attachmentPoints.count))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                Button {
                    viewModel.setShowAttachmentPoints(!viewModel.canvasOptions.showAttachmentPoints)
                } label: {
                    Image(systemName: viewModel.canvasOptions.showAttachmentPoints ? "eye" : "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(viewModel.canvasOptions.showAttachmentPoints ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                }
                .buttonStyle(.plain)
                Button {
                    viewModel.addAttachmentPoint()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text(LocalizedStringKey("cad.attachment.add_short")).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(GroundControlPalette.accent)
                }
                .buttonStyle(.plain)
            }
            Button { viewModel.resetSelectedAssetSystemAttachmentPoints() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
                    Text(LocalizedStringKey("cad.attachment.reset_system")).font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var attachmentPointEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey("cad.attachment.empty"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)
            HStack(spacing: 8) {
                Button { viewModel.addAttachmentPoint() } label: {
                    Text(LocalizedStringKey("cad.attachment.add")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.accent)
                }
                .buttonStyle(.plain)
                Button { viewModel.resetSelectedAssetSystemAttachmentPoints() } label: {
                    Text(LocalizedStringKey("cad.attachment.reset_system")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
    }

    private var attachmentPointNoSelectionState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey("cad.attachment.no_selection")).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button { viewModel.addAttachmentPoint() } label: {
                Text(LocalizedStringKey("cad.attachment.add")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func attachmentPointRow(_ point: AttachmentPoint) -> some View {
        let isSelected = viewModel.selectedAttachmentPointID == point.id
        let color = attachmentRoleColor(point.role)
        return Button { viewModel.selectAttachmentPoint(point.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(color.opacity(point.isEnabled ? 1.0 : 0.35)).frame(width: 8, height: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(point.name).font(.caption.weight(.semibold))
                        .foregroundStyle(point.isEnabled ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary.opacity(0.65)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(point.role.displayName)
                        Text("·")
                        Text(point.isSystem ? NSLocalizedString("cad.attachment.system", comment: "") : NSLocalizedString("cad.attachment.custom", comment: ""))
                    }
                    .font(.caption2).foregroundStyle(GroundControlPalette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !point.isEnabled { Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold)).foregroundStyle(GroundControlPalette.textSecondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? GroundControlPalette.accent.opacity(0.16) : GroundControlPalette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func attachmentPointEditor(_ point: AttachmentPoint) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                attachmentBadge(point.isSystem ? NSLocalizedString("cad.attachment.system", comment: "") : NSLocalizedString("cad.attachment.custom", comment: ""))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.selectedAttachmentPoint?.isEnabled ?? false },
                    set: { _ in viewModel.toggleSelectedAttachmentPointEnabled() }
                ))
                .labelsHidden().toggleStyle(.checkbox)
                Text(LocalizedStringKey("cad.attachment.enabled")).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey("cad.field.name")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textSecondary)
                TextField("", text: Binding(
                    get: { viewModel.selectedAttachmentPoint?.name ?? point.name },
                    set: { viewModel.updateSelectedAttachmentPointName($0) }
                ))
                .textFieldStyle(.roundedBorder).disabled(point.isSystem).opacity(point.isSystem ? 0.65 : 1.0)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey("cad.attachment.role")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textSecondary)
                Picker("", selection: Binding(
                    get: { viewModel.selectedAttachmentPoint?.role ?? point.role },
                    set: { viewModel.updateSelectedAttachmentPointRole($0) }
                )) {
                    ForEach(AttachmentRole.allCases) { role in Text(role.displayName).tag(role) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
            pointVectorEditor(titleKey: "cad.transform.position", unit: NSLocalizedString("cad.unit.mm", comment: ""), bindings: [
                ("X", attachmentPositionBinding(\.x)),
                ("Y", attachmentPositionBinding(\.y)),
                ("Z", attachmentPositionBinding(\.z)),
            ])
            pointVectorEditor(titleKey: "cad.transform.rotation", unit: NSLocalizedString("cad.unit.deg", comment: ""), bindings: [
                ("X", attachmentRotationBinding(\.x)),
                ("Y", attachmentRotationBinding(\.y)),
                ("Z", attachmentRotationBinding(\.z)),
            ])
            Button(role: point.isSystem ? nil : .destructive) { viewModel.deleteSelectedAttachmentPoint() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                    Text(point.isSystem ? LocalizedStringKey("cad.attachment.system_delete_disabled") : LocalizedStringKey("cad.attachment.delete")).font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(point.isSystem ? GroundControlPalette.textSecondary : GroundControlPalette.danger)
            .disabled(point.isSystem)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
        }
    }

    private func pointVectorEditor(titleKey: String, unit: String, bindings: [(String, Binding<Double>)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey)).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 6) { ForEach(bindings, id: \.0) { numericTransformField(axis: $0.0, unit: unit, value: $0.1) } }
        }
    }

    private func attachmentPositionBinding(_ keyPath: WritableKeyPath<DesignVector3, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let pt = viewModel.selectedAttachmentPoint else { return 0 }
                return clampFinite(pt.localPosition[keyPath: keyPath] * 1000, to: -10000...10000)
            },
            set: { newValue in
                guard var pos = viewModel.selectedAttachmentPoint?.localPosition else { return }
                pos[keyPath: keyPath] = clampFinite(newValue, to: -10000...10000) / 1000
                viewModel.updateSelectedAttachmentPointPosition(pos)
            }
        )
    }

    private func attachmentRotationBinding(_ keyPath: WritableKeyPath<DesignVector3, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let pt = viewModel.selectedAttachmentPoint else { return 0 }
                return clampFinite(pt.localRotation[keyPath: keyPath] * 180 / Double.pi, to: -360...360)
            },
            set: { newValue in
                guard var rot = viewModel.selectedAttachmentPoint?.localRotation else { return }
                rot[keyPath: keyPath] = clampFinite(newValue, to: -360...360) * Double.pi / 180
                viewModel.updateSelectedAttachmentPointRotation(rot)
            }
        )
    }

    private func attachmentBadge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(GroundControlPalette.textSecondary).textCase(.uppercase)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(GroundControlPalette.inset))
            .overlay(Capsule(style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: Sketch Inspector

    @ViewBuilder
    private func sketchInspector(_ asset: DesignAsset) -> some View {
        if case let .sketch2D(parameters) = asset.kind {
            sketchSummarySection(parameters)
            selectedSketchLineSection(parameters)
            selectedSketchRectangleSection(parameters)
            selectedSketchCircleSection(parameters)
            sketchLinesSection(parameters)
            sketchShapesSection(parameters)
        }
    }

    private func sketchSummarySection(_ parameters: SketchAssetParameters) -> some View {
        let profileGraph = viewModel.sketchProfileGraph
        let profileCount = profileGraph?.count ?? 0
        let validationIssue: ExtrudeValidationIssue? = profileCount == 0
            ? parameters.sketch.extrudeValidationIssue()
            : nil
        let isCanonicalReference = parameters.sketch.reference.isCanonical
        return ModuleSection(titleKey: "cad.section.sketch") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    ForEach(SketchPlane.allCases) { plane in
                        let isActive = parameters.sketch.plane == plane
                        let isLocked = !isCanonicalReference || (parameters.sketch.hasGeometry && !isActive)
                        Button {
                            viewModel.selectSketchPlane(plane)
                        } label: {
                            Text(plane.displayName)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isActive ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(isActive ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isLocked)
                        .opacity(isLocked ? 0.45 : 1.0)
                    }
                }
                if parameters.sketch.hasGeometry {
                    warningCallout("cad.warning.sketch_plane_locked_hint")
                }
                if isCanonicalReference {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("cad.sketch.plane_offset")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textSecondary)
                        HStack(spacing: 4) {
                            TextField("0", value: Binding(
                                get: { clampFinite(parameters.planeOffsetMeters * 1000, to: -10000...10000) },
                                set: { viewModel.updateSelectedSketchPlaneOffset(clampFinite($0, to: -10000...10000) / 1000) }
                            ), formatter: WorkshopNumberFormatter.decimal)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced)).textFieldStyle(.roundedBorder)
                            .disabled(parameters.sketch.hasGeometry)
                            .opacity(parameters.sketch.hasGeometry ? 0.65 : 1.0)
                            Text(LocalizedStringKey("cad.unit.mm")).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GroundControlPalette.accent)
                        Text(LocalizedStringKey("cad.sketch.face_reference"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.30), lineWidth: 1))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    WorkshopMetricCell(labelKey: "cad.sketch.metric.lines", value: "\(parameters.sketch.entityCount)")
                    WorkshopMetricCell(labelKey: "cad.sketch.metric.contour", value: sketchContourText(parameters.sketch))
                    WorkshopMetricCell(labelKey: "cad.sketch.metric.plane", value: parameters.sketch.reference.displayName)
                    WorkshopMetricCell(labelKey: "cad.sketch.metric.status", value: parameters.sketch.definitionState.displayName)
                }

                Toggle(isOn: Binding(
                    get: { viewModel.canvasOptions.showActivePlaneOverlay },
                    set: { viewModel.setShowActivePlaneOverlay($0) }
                )) {
                    Text(LocalizedStringKey("cad.canvas.active_plane"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                .toggleStyle(.checkbox)

                if let warningKey = viewModel.sketchWarningKey {
                    warningCallout(warningKey)
                }

                Divider().background(GroundControlPalette.border)

                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey("cad.section.extrude"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GroundControlPalette.textPrimary)

                    sketchProfileStatusView(
                        profileGraph: profileGraph,
                        profileCount: profileCount,
                        validationIssue: validationIssue
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("cad.feature.operation"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Picker("", selection: Binding(
                            get: { viewModel.featureOperation },
                            set: { viewModel.featureOperation = $0 }
                        )) {
                            ForEach(CADFeatureOperation.activeWorkshopOperations) { operation in
                                Text(LocalizedStringKey(operation.displayNameKey)).tag(operation)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if viewModel.featureOperation == .cutRemoveMaterialV2 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("cad.feature.depth_mode"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                            Picker("", selection: Binding(
                                get: { viewModel.featureDepthMode },
                                set: { viewModel.featureDepthMode = $0 }
                            )) {
                                Text(LocalizedStringKey("cad.feature.depth.distance")).tag(DepthMode.distance)
                                Text(LocalizedStringKey("cad.feature.depth.through_all")).tag(DepthMode.throughAll)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    HStack(spacing: 8) {
                        if viewModel.featureOperation == .extrudeNewBody || viewModel.featureDepthMode == .distance {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey("cad.extrude.depth"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(GroundControlPalette.textSecondary)
                                HStack(spacing: 4) {
                                    TextField("20", value: Binding(
                                        get: { viewModel.featureDepthMM },
                                        set: { viewModel.featureDepthMM = $0 }
                                    ), formatter: WorkshopNumberFormatter.decimal)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(viewModel.featureOperation == .cutRemoveMaterialV2 && viewModel.featureDepthMode == .throughAll)
                                    Text(LocalizedStringKey("cad.unit.mm"))
                                        .font(.caption2)
                                        .foregroundStyle(GroundControlPalette.textSecondary)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("cad.extrude.direction"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                            Picker("", selection: Binding(
                                get: { viewModel.featureDirection },
                                set: { viewModel.featureDirection = $0 }
                            )) {
                                let directions: [ExtrudeDirection] = viewModel.featureOperation == .cutRemoveMaterialV2
                                    ? [.positiveNormal, .negativeNormal]
                                    : ExtrudeDirection.allCases
                                ForEach(directions) { dir in
                                    Text(dir.displayName).tag(dir)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden()
                        }
                    }

                    if viewModel.featureOperation == .cutRemoveMaterialV2 {
                        cutV2InspectorDetails
                    }

                    if viewModel.featureOperation == .extrudeNewBody {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("cad.extrude.material"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                            Picker("", selection: Binding(
                                get: { viewModel.featureMaterial },
                                set: { viewModel.featureMaterial = $0 }
                            )) {
                                ForEach(DesignMaterial.allCases) { material in
                                    Text(material.displayName).tag(material)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    // Validation feedback (pre-apply)
                    if let msgKey = viewModel.featureValidation.messageKey {
                        warningCallout(msgKey)
                    }
                    if let msgKey = viewModel.featureApplyFailureReason?.messageKey {
                        warningCallout(msgKey)
                    }
                    // Preview state indicator
                    if viewModel.featurePreviewState != nil {
                        HStack(spacing: 5) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(GroundControlPalette.accent)
                            Text(LocalizedStringKey(viewModel.featureOperation == .cutRemoveMaterialV2
                                ? "cad.cut_v2.preview_active"
                                : "cad.feature.preview_active"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.accent)
                        }
                    }
                    if viewModel.featureOperation == .cutRemoveMaterialV2,
                       viewModel.featureValidation.isValid,
                       viewModel.featureDepthMode == .throughAll {
                        statusCallout("cad.cut_v2.reason.through_all_circle_cut_apply_not_ready")
                    }
                    if viewModel.featureOperation == .cutRemoveMaterialV2,
                       viewModel.featureValidation.isValid,
                       viewModel.featureDepthMode == .distance,
                       !viewModel.cutV2ApplyValidation.isValid,
                       let msgKey = viewModel.cutV2ApplyValidation.messageKey {
                        warningCallout(msgKey)
                    }

                    // Apply + Cancel buttons
                    let canApply = viewModel.featureOperation == .cutRemoveMaterialV2
                        ? viewModel.canApplyCutV2Feature
                        : viewModel.featureValidation.isValid
                    HStack(spacing: 6) {
                        Button {
                            viewModel.applyFeatureOperation()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text(LocalizedStringKey("cad.feature.apply"))
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(canApply ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(canApply ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(canApply ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canApply)

                        if viewModel.featurePreviewState != nil {
                            Button {
                                viewModel.cancelFeaturePreview()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(LocalizedStringKey("cad.feature.cancel"))
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .foregroundStyle(GroundControlPalette.textSecondary)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let warningKey = viewModel.extrudeWarningKey {
                        warningCallout(warningKey)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cutV2InspectorDetails: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.selected_profile", value: viewModel.cutV2SelectedProfileDisplayName)
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.profile_type", value: viewModel.cutV2ProfileTypeDisplayName)
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.target_body", value: viewModel.cutV2TargetBodyDisplayName)
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.sketch_plane", value: viewModel.cutV2SketchPlaneDisplayName)
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.direction", value: viewModel.featureDirection.displayName)
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.depth_mode", value: NSLocalizedString(viewModel.featureDepthMode.displayNameKey, comment: ""))
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.preview_state", value: viewModel.cutV2PreviewStateDisplayName)
            WorkshopMetricCell(labelKey: "cad.cut_v2.inspector.apply_state", value: viewModel.cutV2ApplyStateDisplayName)
        }
    }

    @ViewBuilder
    private func sketchProfileStatusView(
        profileGraph: SketchProfileGraph?,
        profileCount: Int,
        validationIssue: ExtrudeValidationIssue?
    ) -> some View {
        if profileCount == 0 {
            if let validationIssue {
                warningCallout(validationIssue.messageKey)
            }
        } else if profileCount == 1 {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                Text(LocalizedStringKey("cad.extrude.contour_closed"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.30), lineWidth: 1))
        } else {
            // Multiple profiles: show count + list with selection
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.accent)
                    Text(String(format: NSLocalizedString("cad.profile.area_count", comment: ""), profileCount))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                }
                if viewModel.selectedProfileAreaID == nil {
                    Text(LocalizedStringKey("cad.profile.select_area_hint"))
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let graph = profileGraph {
                    ForEach(Array(graph.areas.enumerated()), id: \.element.id) { idx, area in
                        let isSelected = viewModel.selectedProfileAreaID == area.id
                        Button {
                            viewModel.selectProfileArea(area.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(isSelected ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                                Text(String(format: NSLocalizedString("cad.profile.area_index", comment: ""), idx + 1))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                                Spacer()
                                Text(String(format: "%.1f mm²", area.areaMM2))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(GroundControlPalette.textSecondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? GroundControlPalette.accent.opacity(0.14) : GroundControlPalette.inset))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? GroundControlPalette.accent.opacity(0.40) : GroundControlPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedSketchLineSection(_ parameters: SketchAssetParameters) -> some View {
        if let line = viewModel.selectedSketchLine {
            let reference = parameters.sketch.reference
            ModuleSection(titleKey: "cad.section.selected_sketch_line") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text(String(format: NSLocalizedString("cad.sketch.line_title", comment: ""), viewModel.selectedSketchLineNumber ?? 1))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                        Spacer()
                        Button {
                            viewModel.selectNextSketchLine()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(LocalizedStringKey("cad.sketch.select_next_line"))
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        sketchLineField(label: "\(reference.uAxisName)1", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .start, keyPath: \.u))
                        sketchLineField(label: "\(reference.vAxisName)1", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .start, keyPath: \.v))
                    }
                    HStack(spacing: 6) {
                        sketchLineField(label: "\(reference.uAxisName)2", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .end, keyPath: \.u))
                        sketchLineField(label: "\(reference.vAxisName)2", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .end, keyPath: \.v))
                    }

                    HStack(spacing: 6) {
                        sketchLineField(label: NSLocalizedString("cad.line.length", comment: ""), value: selectedLineLengthBinding(line.id))
                        sketchLineField(label: NSLocalizedString("cad.line.angle", comment: ""), value: selectedLineAngleBinding(line.id), unitKey: "cad.unit.deg")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("cad.section.constraints"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            sketchConstraintButton(kind: .horizontal, icon: "arrow.left.and.right")
                            sketchConstraintButton(kind: .vertical, icon: "arrow.up.and.down")
                            sketchConstraintButton(kind: .fixedStart, icon: "pin.fill")
                            sketchConstraintButton(kind: .fixedEnd, icon: "pin")
                            sketchConstraintButton(kind: .parallel, icon: "equal")
                            sketchConstraintButton(kind: .perpendicular, icon: "arrow.up.left.and.arrow.down.right")
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("cad.section.dimensions"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            sketchDimensionButton(kind: .lineLength, icon: "ruler", entityID: line.id) {
                                viewModel.addDimensionForSelectedLine(kind: .lineLength)
                            }
                            sketchDimensionButton(kind: .lineAngle, icon: "angle", entityID: line.id) {
                                viewModel.addDimensionForSelectedLine(kind: .lineAngle)
                            }
                            sketchDimensionButton(kind: .horizontalDistance, icon: "arrow.left.and.right", entityID: line.id) {
                                viewModel.addDimensionForSelectedLine(kind: .horizontalDistance)
                            }
                            sketchDimensionButton(kind: .verticalDistance, icon: "arrow.up.and.down", entityID: line.id) {
                                viewModel.addDimensionForSelectedLine(kind: .verticalDistance)
                            }
                        }
                        sketchDimensionList(entityID: line.id, sketch: parameters.sketch)
                    }

                    HStack(spacing: 8) {
                        Button(role: .destructive) {
                            viewModel.deleteSketchLine(line.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(LocalizedStringKey("cad.sketch.delete_line"))
                                    .font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(GroundControlPalette.danger)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                    }

                    if let warningKey = viewModel.sketchWarningKey {
                        warningCallout(warningKey)
                    }
                }
            }
        }
    }

    // MARK: - Selected Entity Sections (Rectangle / Circle)

    @ViewBuilder
    private func selectedSketchRectangleSection(_ parameters: SketchAssetParameters) -> some View {
        if let rectangle = viewModel.selectedSketchRectangle {
            let reference = parameters.sketch.reference
            let index = parameters.sketch.entities.firstIndex { $0.id == rectangle.id }.map { $0 + 1 } ?? 1
            ModuleSection(titleKey: "cad.section.selected_sketch_rectangle") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text(String(format: NSLocalizedString("cad.rectangle.title", comment: ""), index))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        sketchLineField(label: "\(reference.uAxisName)1", value: rectangleCornerBinding(rectangle.id, cornerIndex: 0, keyPath: \.u))
                        sketchLineField(label: "\(reference.vAxisName)1", value: rectangleCornerBinding(rectangle.id, cornerIndex: 0, keyPath: \.v))
                    }
                    HStack(spacing: 6) {
                        sketchLineField(label: "\(reference.uAxisName)2", value: rectangleCornerBinding(rectangle.id, cornerIndex: 2, keyPath: \.u))
                        sketchLineField(label: "\(reference.vAxisName)2", value: rectangleCornerBinding(rectangle.id, cornerIndex: 2, keyPath: \.v))
                    }
                    HStack(spacing: 6) {
                        sketchLineField(label: NSLocalizedString("cad.rectangle.width", comment: ""), value: rectangleSizeBinding(rectangle.id, isWidth: true))
                        sketchLineField(label: NSLocalizedString("cad.rectangle.height", comment: ""), value: rectangleSizeBinding(rectangle.id, isWidth: false))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("cad.section.dimensions"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            sketchDimensionButton(kind: .rectangleWidth, icon: "arrow.left.and.right", entityID: rectangle.id) {
                                viewModel.addDimensionForSelectedRectangle(kind: .rectangleWidth)
                            }
                            sketchDimensionButton(kind: .rectangleHeight, icon: "arrow.up.and.down", entityID: rectangle.id) {
                                viewModel.addDimensionForSelectedRectangle(kind: .rectangleHeight)
                            }
                        }
                        sketchDimensionList(entityID: rectangle.id, sketch: parameters.sketch)
                    }

                    Button(role: .destructive) {
                        viewModel.deleteSketchEntity(rectangle.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                            Text(LocalizedStringKey("cad.sketch.delete_entity")).font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(GroundControlPalette.danger)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func selectedSketchCircleSection(_ parameters: SketchAssetParameters) -> some View {
        if let circle = viewModel.selectedSketchCircle {
            let reference = parameters.sketch.reference
            let index = parameters.sketch.entities.firstIndex { $0.id == circle.id }.map { $0 + 1 } ?? 1
            ModuleSection(titleKey: "cad.section.selected_sketch_circle") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text(String(format: NSLocalizedString("cad.circle.title", comment: ""), index))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        sketchLineField(label: "\(reference.uAxisName)c", value: circleCenterBinding(circle.id, keyPath: \.u))
                        sketchLineField(label: "\(reference.vAxisName)c", value: circleCenterBinding(circle.id, keyPath: \.v))
                    }
                    HStack(spacing: 6) {
                        sketchLineField(label: NSLocalizedString("cad.circle.radius", comment: ""), value: circleRadiusBinding(circle.id))
                        sketchLineField(label: NSLocalizedString("cad.circle.diameter", comment: ""), value: circleDiameterBinding(circle.id))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey("cad.section.dimensions"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            sketchDimensionButton(kind: .circleRadius, icon: "circle", entityID: circle.id) {
                                viewModel.addDimensionForSelectedCircle(kind: .circleRadius)
                            }
                            sketchDimensionButton(kind: .circleDiameter, icon: "circle.dashed", entityID: circle.id) {
                                viewModel.addDimensionForSelectedCircle(kind: .circleDiameter)
                            }
                        }
                        sketchDimensionList(entityID: circle.id, sketch: parameters.sketch)
                    }

                    Button(role: .destructive) {
                        viewModel.deleteSketchEntity(circle.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                            Text(LocalizedStringKey("cad.sketch.delete_entity")).font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(GroundControlPalette.danger)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Shapes Section (non-line entities list)

    @ViewBuilder
    private func sketchShapesSection(_ parameters: SketchAssetParameters) -> some View {
        let shapes = parameters.sketch.entities.filter { $0.rectangle != nil || $0.circle != nil }
        if !shapes.isEmpty {
            let reference = parameters.sketch.reference
            ModuleSection(titleKey: "cad.section.sketch_shapes") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shapes.enumerated()), id: \.element.id) { index, entity in
                        if let rectangle = entity.rectangle {
                            sketchRectangleRow(rectangle, index: index, reference: reference)
                        } else if let circle = entity.circle {
                            sketchCircleRow(circle, index: index, reference: reference)
                        }
                    }
                }
            }
        }
    }

    private func sketchRectangleRow(_ rectangle: SketchRectangle, index: Int, reference: SketchReference) -> some View {
        let isSelected = viewModel.selectedSketchEntityID == rectangle.id
        return VStack(alignment: .leading, spacing: 4) {
            Button { viewModel.selectSketchEntity(rectangle.id) } label: {
                HStack {
                    Image(systemName: "rectangle").font(.system(size: 10, weight: .semibold))
                    Text(String(format: NSLocalizedString("cad.rectangle.title", comment: ""), index + 1))
                        .font(.caption.weight(.bold)).foregroundStyle(GroundControlPalette.textPrimary)
                    Spacer()
                    Text("\(formatDimensionMM(rectangle.widthMeters))×\(formatDimensionMM(rectangle.heightMeters)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .buttonStyle(.plain)
            Button(role: .destructive) { viewModel.deleteSketchEntity(rectangle.id) } label: {
                Text(LocalizedStringKey("cad.sketch.delete_entity")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? GroundControlPalette.accent.opacity(0.13) : GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? GroundControlPalette.accent.opacity(0.48) : GroundControlPalette.border, lineWidth: 1))
    }

    private func sketchCircleRow(_ circle: SketchCircle, index: Int, reference: SketchReference) -> some View {
        let isSelected = viewModel.selectedSketchEntityID == circle.id
        return VStack(alignment: .leading, spacing: 4) {
            Button { viewModel.selectSketchEntity(circle.id) } label: {
                HStack {
                    Image(systemName: "circle").font(.system(size: 10, weight: .semibold))
                    Text(String(format: NSLocalizedString("cad.circle.title", comment: ""), index + 1))
                        .font(.caption.weight(.bold)).foregroundStyle(GroundControlPalette.textPrimary)
                    Spacer()
                    Text("R \(formatDimensionMM(circle.radiusMeters)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .buttonStyle(.plain)
            Button(role: .destructive) { viewModel.deleteSketchEntity(circle.id) } label: {
                Text(LocalizedStringKey("cad.sketch.delete_entity")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? GroundControlPalette.accent.opacity(0.13) : GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? GroundControlPalette.accent.opacity(0.48) : GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: - Bindings for Rectangle / Circle

    private func rectangleCornerBinding(_ id: UUID, cornerIndex: Int, keyPath: WritableKeyPath<SketchPoint2D, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let rect = viewModel.selectedSketch?.rectangles.first(where: { $0.id == id }) else { return 0 }
                let corners = rect.corners
                guard cornerIndex < corners.count else { return 0 }
                return clampFinite(corners[cornerIndex][keyPath: keyPath] * 1000, to: -10000...10000)
            },
            set: { newValue in
                guard let rect = viewModel.selectedSketch?.rectangles.first(where: { $0.id == id }) else { return }
                var first = rect.firstCorner
                var opposite = rect.oppositeCorner
                let mm = clampFinite(newValue, to: -10000...10000) / 1000
                if cornerIndex == 0 { first[keyPath: keyPath] = mm }
                else { opposite[keyPath: keyPath] = mm }
                viewModel.updateSketchRectangle(id, firstCorner: first, oppositeCorner: opposite)
            }
        )
    }

    private func rectangleSizeBinding(_ id: UUID, isWidth: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard let rect = viewModel.selectedSketch?.rectangles.first(where: { $0.id == id }) else { return 0 }
                return clampFinite((isWidth ? rect.widthMeters : rect.heightMeters) * 1000, to: 0...10000)
            },
            set: { newValue in
                guard let rect = viewModel.selectedSketch?.rectangles.first(where: { $0.id == id }) else { return }
                let updated = isWidth ? rect.withWidth(clampFinite(newValue, to: 0.5...10000) / 1000)
                                      : rect.withHeight(clampFinite(newValue, to: 0.5...10000) / 1000)
                viewModel.updateSketchRectangle(id, firstCorner: updated.firstCorner, oppositeCorner: updated.oppositeCorner)
            }
        )
    }

    private func circleCenterBinding(_ id: UUID, keyPath: WritableKeyPath<SketchPoint2D, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let circle = viewModel.selectedSketch?.circles.first(where: { $0.id == id }) else { return 0 }
                return clampFinite(circle.center[keyPath: keyPath] * 1000, to: -10000...10000)
            },
            set: { newValue in
                guard let circle = viewModel.selectedSketch?.circles.first(where: { $0.id == id }) else { return }
                var center = circle.center
                center[keyPath: keyPath] = clampFinite(newValue, to: -10000...10000) / 1000
                viewModel.updateSketchCircle(id, center: center, radiusMeters: circle.radiusMeters)
            }
        )
    }

    private func circleRadiusBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: {
                guard let circle = viewModel.selectedSketch?.circles.first(where: { $0.id == id }) else { return 0 }
                return clampFinite(circle.radiusMeters * 1000, to: 0.5...10000)
            },
            set: { newValue in
                guard let circle = viewModel.selectedSketch?.circles.first(where: { $0.id == id }) else { return }
                viewModel.updateSketchCircle(id, center: circle.center, radiusMeters: clampFinite(newValue, to: 0.5...10000) / 1000)
            }
        )
    }

    private func circleDiameterBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: {
                guard let circle = viewModel.selectedSketch?.circles.first(where: { $0.id == id }) else { return 0 }
                return clampFinite(circle.diameterMeters * 1000, to: 1...20000)
            },
            set: { newValue in
                guard let circle = viewModel.selectedSketch?.circles.first(where: { $0.id == id }) else { return }
                viewModel.updateSketchCircle(id, center: circle.center, radiusMeters: clampFinite(newValue, to: 1...20000) / 2000)
            }
        )
    }

    private func sketchLinesSection(_ parameters: SketchAssetParameters) -> some View {
        ModuleSection(titleKey: "cad.section.sketch_lines") {
            VStack(alignment: .leading, spacing: 8) {
                if parameters.sketch.lines.isEmpty {
                    Text(LocalizedStringKey("cad.sketch.lines.empty")).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(parameters.sketch.lines.enumerated()), id: \.element.id) { index, line in
                        sketchLineEditor(line, index: index, reference: parameters.sketch.reference)
                    }
                }
            }
        }
    }

    private func sketchLineEditor(_ line: SketchLine, index: Int, reference: SketchReference) -> some View {
        let isSelected = viewModel.selectedSketchLineID == line.id
        return VStack(alignment: .leading, spacing: 7) {
            Button { viewModel.selectSketchLine(line.id) } label: {
                HStack {
                    Text(String(format: NSLocalizedString("cad.sketch.line_title", comment: ""), index + 1)).font(.caption.weight(.bold)).foregroundStyle(GroundControlPalette.textPrimary)
                    Spacer()
                    Text("\(formatDimensionMM(line.lengthMeters)) \(NSLocalizedString("cad.unit.mm", comment: ""))").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                sketchLineField(label: "\(reference.uAxisName)1", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .start, keyPath: \.u))
                sketchLineField(label: "\(reference.vAxisName)1", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .start, keyPath: \.v))
            }
            HStack(spacing: 6) {
                sketchLineField(label: "\(reference.uAxisName)2", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .end, keyPath: \.u))
                sketchLineField(label: "\(reference.vAxisName)2", value: sketchLineCoordinateBinding(lineID: line.id, endpoint: .end, keyPath: \.v))
            }
            Button(role: .destructive) { viewModel.deleteSketchLine(line.id) } label: {
                Text(LocalizedStringKey("cad.sketch.delete_line")).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? GroundControlPalette.accent.opacity(0.13) : GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? GroundControlPalette.accent.opacity(0.48) : GroundControlPalette.border, lineWidth: 1))
    }

    private func sketchLineField(label: String, value: Binding<Double>, unitKey: String = "cad.unit.mm") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 4) {
                TextField(label, value: value, formatter: WorkshopNumberFormatter.decimal)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).textFieldStyle(.roundedBorder)
                Text(LocalizedStringKey(unitKey)).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }

    private func sketchConstraintButton(kind: SketchConstraintKind, icon: String) -> some View {
        let isActive = viewModel.selectedSketchLineHasConstraint(kind)
        return Button {
            viewModel.setSelectedSketchLineConstraint(kind, enabled: !isActive)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(isActive ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isActive ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isActive ? GroundControlPalette.accent.opacity(0.50) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func sketchDimensionButton(kind: SketchDimensionKind, icon: String, entityID: UUID, action: @escaping () -> Void) -> some View {
        let hasIt = viewModel.selectedSketch?.hasDimension(kind, lineID: entityID) == true
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(hasIt ? Color.yellow : GroundControlPalette.textSecondary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hasIt ? Color.yellow.opacity(0.12) : GroundControlPalette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(hasIt ? Color.yellow.opacity(0.40) : GroundControlPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(hasIt)
    }

    @ViewBuilder
    private func sketchDimensionList(entityID: UUID, sketch: DesignSketch) -> some View {
        let dims = sketch.dimensions.filter { $0.lineID == entityID }
        if !dims.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(dims) { dim in
                    HStack(spacing: 6) {
                        Text(dim.kind.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Spacer()
                        Text(formattedDimValue(dim))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.yellow)
                        Button {
                            viewModel.removeSketchDimension(dim.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(GroundControlPalette.inset))
                }
            }
        }
    }

    private func formattedDimValue(_ dim: SketchDimension) -> String {
        switch dim.kind {
        case .lineAngle:
            return String(format: "%.1f°", dim.value)
        case .circleRadius:
            return String(format: "R%.1f mm", dim.value * 1000)
        case .circleDiameter:
            return String(format: "⌀%.1f mm", dim.value * 1000)
        default:
            return String(format: "%.1f mm", dim.value * 1000)
        }
    }

    private func selectedLineLengthBinding(_ lineID: UUID) -> Binding<Double> {
        Binding(
            get: {
                guard let line = viewModel.selectedSketch?.lines.first(where: { $0.id == lineID }) else { return 0 }
                return clampFinite(line.lengthMeters * 1000, to: 0...20000)
            },
            set: { newValue in
                viewModel.updateSelectedSketchLineLength(clampFinite(newValue, to: 1...20000) / 1000)
            }
        )
    }

    private func selectedLineAngleBinding(_ lineID: UUID) -> Binding<Double> {
        Binding(
            get: {
                guard let line = viewModel.selectedSketch?.lines.first(where: { $0.id == lineID }) else { return 0 }
                return clampFinite(line.angleDegrees, to: -360...360)
            },
            set: { newValue in
                viewModel.updateSelectedSketchLineAngle(clampFinite(newValue, to: -360...360))
            }
        )
    }

    private func sketchLineCoordinateBinding(lineID: UUID, endpoint: SketchLineEndpoint, keyPath: WritableKeyPath<SketchPoint2D, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let line = viewModel.selectedSketch?.lines.first(where: { $0.id == lineID }) else { return 0 }
                let point = endpoint == .start ? line.start : line.end
                return clampFinite(point[keyPath: keyPath] * 1000, to: -10000...10000)
            },
            set: { newValue in
                guard let line = viewModel.selectedSketch?.lines.first(where: { $0.id == lineID }) else { return }
                var start = line.start
                var end = line.end
                if endpoint == .start { start[keyPath: keyPath] = clampFinite(newValue, to: -10000...10000) / 1000 }
                else { end[keyPath: keyPath] = clampFinite(newValue, to: -10000...10000) / 1000 }
                viewModel.updateSketchLine(lineID, start: start, end: end)
            }
        )
    }

    // MARK: - Parameter Editors

    private func basicWingEditor(_ p: BasicWingParameters) -> some View {
        VStack(spacing: 10) {
            ModuleSection(titleKey: "cad.param.construction") {
                Picker("", selection: Binding(get: { p.constructionType }, set: { ct in var q = p; q.constructionType = ct; viewModel.updateSelectedAssetKind(.basicWing(q)) })) {
                    ForEach(WingConstructionType.allCases) { ct in Text(ct.displayName).tag(ct) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            ModuleSection(titleKey: "cad.section.dimensions") {
                VStack(spacing: 8) {
                    mmSlider("cad.param.span", value: p.spanMeters, range: 0.1...3.0) { v in var q = p; q.spanMeters = v; viewModel.updateSelectedAssetKind(.basicWing(q)) }
                    mmSlider("cad.param.root_chord", value: p.rootChordMeters, range: 0.05...0.6) { v in var q = p; q.rootChordMeters = v; viewModel.updateSelectedAssetKind(.basicWing(q)) }
                    mmSlider("cad.param.tip_chord", value: p.tipChordMeters, range: 0.02...0.4) { v in var q = p; q.tipChordMeters = v; viewModel.updateSelectedAssetKind(.basicWing(q)) }
                    mmSlider("cad.param.thickness", value: p.thicknessMeters, range: 0.005...0.1) { v in var q = p; q.thicknessMeters = v; viewModel.updateSelectedAssetKind(.basicWing(q)) }
                    degSlider("cad.param.sweep", value: p.sweepDegrees, range: -30...45) { v in var q = p; q.sweepDegrees = v; viewModel.updateSelectedAssetKind(.basicWing(q)) }
                    degSlider("cad.param.dihedral", value: p.dihedralDegrees, range: -15...30) { v in var q = p; q.dihedralDegrees = v; viewModel.updateSelectedAssetKind(.basicWing(q)) }
                }
            }
        }
    }

    private func framePlateEditor(_ p: FramePlateParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.width", value: p.widthMeters, range: 0.05...1.0) { v in var q = p; q.widthMeters = v; viewModel.updateSelectedAssetKind(.framePlate(q)) }
                mmSlider("cad.param.depth", value: p.depthMeters, range: 0.05...1.0) { v in var q = p; q.depthMeters = v; viewModel.updateSelectedAssetKind(.framePlate(q)) }
                mmSlider("cad.param.thickness", value: p.thicknessMeters, range: 0.001...0.05) { v in var q = p; q.thicknessMeters = v; viewModel.updateSelectedAssetKind(.framePlate(q)) }
            }
        }
    }

    private func beamEditor(_ p: BeamParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.length", value: p.lengthMeters, range: 0.05...2.0) { v in var q = p; q.lengthMeters = v; viewModel.updateSelectedAssetKind(.beam(q)) }
                mmSlider("cad.param.width", value: p.widthMeters, range: 0.005...0.1) { v in var q = p; q.widthMeters = v; viewModel.updateSelectedAssetKind(.beam(q)) }
                mmSlider("cad.param.height", value: p.heightMeters, range: 0.005...0.1) { v in var q = p; q.heightMeters = v; viewModel.updateSelectedAssetKind(.beam(q)) }
            }
        }
    }

    private func tubeEditor(_ p: TubeParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.length", value: p.lengthMeters, range: 0.05...2.0) { v in var q = p; q.lengthMeters = v; viewModel.updateSelectedAssetKind(.tube(q)) }
                mmSlider("cad.param.outer_radius", value: p.outerRadiusMeters, range: 0.002...0.1) { v in var q = p; q.outerRadiusMeters = max(v, p.innerRadiusMeters + 0.001); viewModel.updateSelectedAssetKind(.tube(q)) }
                mmSlider("cad.param.inner_radius", value: p.innerRadiusMeters, range: 0.001...0.09) { v in var q = p; q.innerRadiusMeters = min(v, p.outerRadiusMeters - 0.001); viewModel.updateSelectedAssetKind(.tube(q)) }
                if p.outerRadiusMeters - p.innerRadiusMeters <= 0.0011 { warningCallout("cad.warning.tube_radius") }
            }
        }
    }

    private func mountBracketEditor(_ p: MountBracketParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.plate_width", value: p.plateWidthMeters, range: 0.02...0.3) { v in var q = p; q.plateWidthMeters = v; viewModel.updateSelectedAssetKind(.mountBracket(q)) }
                mmSlider("cad.param.plate_depth", value: p.plateDepthMeters, range: 0.02...0.3) { v in var q = p; q.plateDepthMeters = v; viewModel.updateSelectedAssetKind(.mountBracket(q)) }
                mmSlider("cad.param.plate_thickness", value: p.plateThicknessMeters, range: 0.001...0.02) { v in var q = p; q.plateThicknessMeters = v; viewModel.updateSelectedAssetKind(.mountBracket(q)) }
                mmSlider("cad.param.arm_length", value: p.armLengthMeters, range: 0.01...0.3) { v in var q = p; q.armLengthMeters = v; viewModel.updateSelectedAssetKind(.mountBracket(q)) }
                mmSlider("cad.param.arm_thickness", value: p.armThicknessMeters, range: 0.001...0.02) { v in var q = p; q.armThicknessMeters = v; viewModel.updateSelectedAssetKind(.mountBracket(q)) }
            }
        }
    }

    private func payloadBoxEditor(_ p: PayloadBoxParameters) -> some View {
        ModuleSection(titleKey: "cad.section.dimensions") {
            VStack(spacing: 8) {
                mmSlider("cad.param.width", value: p.widthMeters, range: 0.02...0.5) { v in var q = p; q.widthMeters = v; viewModel.updateSelectedAssetKind(.payloadBox(q)) }
                mmSlider("cad.param.height", value: p.heightMeters, range: 0.02...0.4) { v in var q = p; q.heightMeters = v; viewModel.updateSelectedAssetKind(.payloadBox(q)) }
                mmSlider("cad.param.depth", value: p.depthMeters, range: 0.02...0.4) { v in var q = p; q.depthMeters = v; viewModel.updateSelectedAssetKind(.payloadBox(q)) }
            }
        }
    }

    private func mmSlider(_ titleKey: String, value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) -> some View {
        let safeValue = clampFinite(value, to: range)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(titleKey)).font(.caption).foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    TextField("", value: Binding(get: { safeValue * 1000 }, set: { onChange(clampFinite($0 / 1000, to: range)) }), formatter: WorkshopNumberFormatter.decimal)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 58)
                    Text(LocalizedStringKey("cad.unit.mm")).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            Slider(value: Binding(get: { safeValue }, set: { onChange(clampFinite($0, to: range)) }), in: range).tint(GroundControlPalette.accent)
        }
    }

    private func degSlider(_ titleKey: String, value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) -> some View {
        let safeValue = clampFinite(value, to: range)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(titleKey)).font(.caption).foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    TextField("", value: Binding(get: { safeValue }, set: { onChange(clampFinite($0, to: range)) }), formatter: WorkshopNumberFormatter.decimal)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 58)
                    Text(LocalizedStringKey("cad.unit.deg")).font(.caption2).foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
            Slider(value: Binding(get: { safeValue }, set: { onChange(clampFinite($0, to: range)) }), in: range).tint(GroundControlPalette.accent)
        }
    }

    private func warningCallout(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(GroundControlPalette.warning)
            Text(LocalizedStringKey(key)).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.warning.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.warning.opacity(0.32), lineWidth: 1))
    }

    private func statusCallout(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(GroundControlPalette.accent)
            Text(LocalizedStringKey(key)).font(.caption2.weight(.semibold)).foregroundStyle(GroundControlPalette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(GroundControlPalette.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.28), lineWidth: 1))
    }

    private func attachmentRoleColor(_ role: AttachmentRole) -> Color {
        let rgb = role.markerRGB
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    // MARK: - Bottom Status Bar

    private var workshopStatusBar: some View {
        HStack(spacing: 0) {
            statusContent
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(GroundControlPalette.panel)
    }

    @ViewBuilder
    private var statusContent: some View {
        if viewModel.activeToolMode == .sketchLine {
            lineToolStatusBar
        } else if viewModel.activeToolMode == .sketchRectangle {
            rectangleToolStatusBar
        } else if viewModel.activeToolMode == .sketchCircle {
            circleToolStatusBar
        } else if viewModel.activeToolMode == .sketchArc {
            arcToolStatusBar
        } else if viewModel.activeToolMode == .sketchAutoline {
            autolineToolStatusBar
        } else if let asset = viewModel.selectedAsset {
            if case let .sketch2D(parameters) = asset.kind {
                if let line = viewModel.selectedSketchLine {
                    selectedLineStatusBar(line: line, sketch: parameters.sketch)
                } else if let rectangle = viewModel.selectedSketchRectangle {
                    selectedRectangleStatusBar(rectangle: rectangle, sketch: parameters.sketch)
                } else if let circle = viewModel.selectedSketchCircle {
                    selectedCircleStatusBar(circle: circle, sketch: parameters.sketch)
                } else {
                    sketchStatusBar(asset: asset, parameters: parameters)
                }
            } else {
                solidStatusBar(asset: asset)
            }
        } else {
            defaultStatusBar
        }
    }

    private var lineToolStatusBar: some View {
        let state = viewModel.lineToolState
        let reference = viewModel.activeCoordinateReference
        let phaseStr: String
        switch state.phase {
        case .idle, .waitingForStart: phaseStr = NSLocalizedString("cad.line.set_start", comment: "")
        case .waitingForEnd: phaseStr = NSLocalizedString("cad.line.set_end", comment: "")
        }
        let lenStr = state.currentLengthMeters.map { "L: \(formatCoord($0 * 1000)) mm" } ?? ""
        let angStr = state.currentAngleDegrees.map { "A: \(formatCoord($0))°" } ?? ""
        let cursorStr = "\(reference.uAxisName): \(formatCoord(state.cursorPoint.u * 1000)) mm \(reference.vAxisName): \(formatCoord(state.cursorPoint.v * 1000)) mm"
        let snapLabel = snapStatusLabel(result: state.snapResult, options: viewModel.canvasOptions.snapOptions)
        return HStack(spacing: 5) {
            statusChip(NSLocalizedString("cad.tool.line", comment: ""), icon: "line.diagonal")
            Text("·").font(.caption2)
            statusChip(reference.displayName, icon: "square.on.square.dashed")
            Text("·").font(.caption2)
            Text(phaseStr).font(.caption2.weight(.semibold))
            Text("·").font(.caption2)
            Text(cursorStr).font(.system(size: 10, design: .monospaced))
            if !lenStr.isEmpty { Text("·").font(.caption2); Text(lenStr).font(.system(size: 10, design: .monospaced)) }
            if !angStr.isEmpty { Text("·").font(.caption2); Text(angStr).font(.system(size: 10, design: .monospaced)) }
            Text("·").font(.caption2)
            Text(snapLabel).font(.system(size: 10, design: .monospaced))
        }
    }

    private var rectangleToolStatusBar: some View {
        let state = viewModel.rectangleToolState
        let reference = viewModel.activeCoordinateReference
        let phaseStr: String
        switch state.phase {
        case .idle, .waitingForFirstCorner: phaseStr = NSLocalizedString("cad.rectangle.set_first_corner", comment: "")
        case .waitingForOppositeCorner: phaseStr = NSLocalizedString("cad.rectangle.set_opposite_corner", comment: "")
        }
        let cursorStr = "\(reference.uAxisName): \(formatCoord(state.cursorPoint.u * 1000)) mm \(reference.vAxisName): \(formatCoord(state.cursorPoint.v * 1000)) mm"
        let wStr = state.widthMeters.map { "W: \(formatCoord($0 * 1000)) mm" } ?? ""
        let hStr = state.heightMeters.map { "H: \(formatCoord($0 * 1000)) mm" } ?? ""
        let snapLabel = snapStatusLabel(result: state.snapResult, options: viewModel.canvasOptions.snapOptions)
        return HStack(spacing: 5) {
            statusChip(NSLocalizedString("cad.tool.rectangle", comment: ""), icon: "rectangle")
            Text("·").font(.caption2)
            statusChip(reference.displayName, icon: "square.on.square.dashed")
            Text("·").font(.caption2)
            Text(phaseStr).font(.caption2.weight(.semibold))
            Text("·").font(.caption2)
            Text(cursorStr).font(.system(size: 10, design: .monospaced))
            if !wStr.isEmpty { Text("·").font(.caption2); Text(wStr).font(.system(size: 10, design: .monospaced)) }
            if !hStr.isEmpty { Text("·").font(.caption2); Text(hStr).font(.system(size: 10, design: .monospaced)) }
            Text("·").font(.caption2)
            Text(snapLabel).font(.system(size: 10, design: .monospaced))
        }
    }

    private var circleToolStatusBar: some View {
        let state = viewModel.circleToolState
        let reference = viewModel.activeCoordinateReference
        let phaseStr: String
        switch state.phase {
        case .idle, .waitingForCenter: phaseStr = NSLocalizedString("cad.circle.set_center", comment: "")
        case .waitingForRadius: phaseStr = NSLocalizedString("cad.circle.set_radius", comment: "")
        }
        let cursorStr = "\(reference.uAxisName): \(formatCoord(state.cursorPoint.u * 1000)) mm \(reference.vAxisName): \(formatCoord(state.cursorPoint.v * 1000)) mm"
        let rStr = state.radiusMeters.map { "R: \(formatCoord($0 * 1000)) mm" } ?? ""
        let snapLabel = snapStatusLabel(result: state.snapResult, options: viewModel.canvasOptions.snapOptions)
        return HStack(spacing: 5) {
            statusChip(NSLocalizedString("cad.tool.circle", comment: ""), icon: "circle")
            Text("·").font(.caption2)
            statusChip(reference.displayName, icon: "square.on.square.dashed")
            Text("·").font(.caption2)
            Text(phaseStr).font(.caption2.weight(.semibold))
            Text("·").font(.caption2)
            Text(cursorStr).font(.system(size: 10, design: .monospaced))
            if !rStr.isEmpty { Text("·").font(.caption2); Text(rStr).font(.system(size: 10, design: .monospaced)) }
            Text("·").font(.caption2)
            Text(snapLabel).font(.system(size: 10, design: .monospaced))
        }
    }

    private var arcToolStatusBar: some View {
        let state = viewModel.arcToolState
        let reference = viewModel.activeCoordinateReference
        let phaseStr: String
        switch state.phase {
        case .idle, .waitingForStart: phaseStr = NSLocalizedString("cad.arc.set_start", comment: "")
        case .waitingForEnd:          phaseStr = NSLocalizedString("cad.arc.set_end", comment: "")
        case .waitingForMid:          phaseStr = NSLocalizedString("cad.arc.set_mid", comment: "")
        }
        let cursorStr = "\(reference.uAxisName): \(formatCoord(state.cursorPoint.u * 1000)) mm \(reference.vAxisName): \(formatCoord(state.cursorPoint.v * 1000)) mm"
        let chordStr = state.chordLengthMeters.map { "chord: \(formatCoord($0 * 1000)) mm" } ?? ""
        let snapLabel = snapStatusLabel(result: state.snapResult, options: viewModel.canvasOptions.snapOptions)
        return HStack(spacing: 5) {
            statusChip(NSLocalizedString("cad.tool.arc", comment: ""), icon: "arc")
            Text("·").font(.caption2)
            statusChip(reference.displayName, icon: "square.on.square.dashed")
            Text("·").font(.caption2)
            Text(phaseStr).font(.caption2.weight(.semibold))
            Text("·").font(.caption2)
            Text(cursorStr).font(.system(size: 10, design: .monospaced))
            if !chordStr.isEmpty { Text("·").font(.caption2); Text(chordStr).font(.system(size: 10, design: .monospaced)) }
            Text("·").font(.caption2)
            Text(snapLabel).font(.system(size: 10, design: .monospaced))
        }
    }

    private var autolineToolStatusBar: some View {
        let state = viewModel.autolineToolState
        let reference = viewModel.activeCoordinateReference
        let phaseStr = state.segmentCount > 0
            ? String(format: NSLocalizedString("cad.autoline.segment_count", comment: ""), state.segmentCount)
            : NSLocalizedString("cad.autoline.idle", comment: "")
        let cursorStr = "\(reference.uAxisName): \(formatCoord(state.cursorPoint.u * 1000)) mm \(reference.vAxisName): \(formatCoord(state.cursorPoint.v * 1000)) mm"
        let lenStr = state.currentLengthMeters.map { "seg: \(formatCoord($0 * 1000)) mm" } ?? ""
        let snapLabel = snapStatusLabel(result: state.snapResult, options: viewModel.canvasOptions.snapOptions)
        return HStack(spacing: 5) {
            statusChip(NSLocalizedString("cad.tool.autoline", comment: ""), icon: "scribble.variable")
            Text("·").font(.caption2)
            statusChip(reference.displayName, icon: "square.on.square.dashed")
            Text("·").font(.caption2)
            Text(phaseStr).font(.caption2.weight(.semibold))
            Text("·").font(.caption2)
            Text(cursorStr).font(.system(size: 10, design: .monospaced))
            if !lenStr.isEmpty { Text("·").font(.caption2); Text(lenStr).font(.system(size: 10, design: .monospaced)) }
            Text("·").font(.caption2)
            Text(snapLabel).font(.system(size: 10, design: .monospaced))
        }
    }

    private func selectedRectangleStatusBar(rectangle: SketchRectangle, sketch: DesignSketch) -> some View {
        let index = sketch.entities.firstIndex { $0.id == rectangle.id }.map { $0 + 1 } ?? 1
        return HStack(spacing: 5) {
            Image(systemName: "rectangle").font(.system(size: 10, weight: .semibold))
            Text(String(format: NSLocalizedString("cad.rectangle.title", comment: ""), index))
                .font(.caption.weight(.semibold))
            Text("·").font(.caption2)
            Text("W \(formatCoord(rectangle.widthMeters * 1000)) × H \(formatCoord(rectangle.heightMeters * 1000)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text("·").font(.caption2)
            Text(sketch.reference.displayName).font(.caption2.weight(.semibold))
        }
    }

    private func selectedCircleStatusBar(circle: SketchCircle, sketch: DesignSketch) -> some View {
        let index = sketch.entities.firstIndex { $0.id == circle.id }.map { $0 + 1 } ?? 1
        return HStack(spacing: 5) {
            Image(systemName: "circle").font(.system(size: 10, weight: .semibold))
            Text(String(format: NSLocalizedString("cad.circle.title", comment: ""), index))
                .font(.caption.weight(.semibold))
            Text("·").font(.caption2)
            Text("R \(formatCoord(circle.radiusMeters * 1000)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text("·").font(.caption2)
            Text(sketch.reference.displayName).font(.caption2.weight(.semibold))
        }
    }

    private func sketchStatusBar(asset: DesignAsset, parameters: SketchAssetParameters) -> some View {
        let snapLabel = snapStatusLabel(result: nil, options: viewModel.canvasOptions.snapOptions)
        return HStack(spacing: 5) {
            Text(asset.name).font(.caption.weight(.semibold))
            Text("·").font(.caption2)
            Text(parameters.sketch.reference.displayName).font(.caption2.weight(.semibold))
            Text("·").font(.caption2)
            Text("\(parameters.sketch.entityCount) \(NSLocalizedString("cad.sketch.metric.lines", comment: "").lowercased())").font(.caption2)
            Text("·").font(.caption2)
            Text(sketchContourText(parameters.sketch)).font(.caption2)
            Text("·").font(.caption2)
            Text(snapLabel).font(.system(size: 10, design: .monospaced))
            if !viewModel.canvasOptions.showActivePlaneOverlay {
                Text("·").font(.caption2)
                Text(LocalizedStringKey("cad.canvas.active_plane_hidden")).font(.caption2)
            }
            if !parameters.sketch.isClosed {
                Text("·").font(.caption2)
                Text(LocalizedStringKey("cad.extrude.unavailable_status")).font(.caption2)
            }
        }
    }

    private func snapStatusLabel(result: CADSnapResult?, options: CADSnapOptions) -> String {
        guard options.isEnabled else {
            return NSLocalizedString("cad.status.snap_off", comment: "")
        }
        if let name = result?.displayName, result?.kind != nil {
            return String(format: NSLocalizedString("cad.status.snap_named", comment: ""), name)
        }
        if options.snapToGrid {
            return String(
                format: NSLocalizedString("cad.status.snap_grid_step", comment: ""),
                formatDimensionMM(options.gridStepMeters)
            )
        }
        return NSLocalizedString("cad.status.snap_grid_off", comment: "")
    }

    private func selectedLineStatusBar(line: SketchLine, sketch: DesignSketch) -> some View {
        let index = viewModel.selectedSketchLineNumber ?? 1
        let activeConstraint = selectedLineConstraintStatus(lineID: line.id)
        return HStack(spacing: 5) {
            Text(String(format: NSLocalizedString("cad.sketch.line_title", comment: ""), index))
                .font(.caption.weight(.semibold))
            Text("·").font(.caption2)
            if !activeConstraint.isEmpty {
                Text(activeConstraint).font(.caption2.weight(.semibold))
                Text("·").font(.caption2)
            }
            Text("L \(formatCoord(line.lengthMeters * 1000)) \(NSLocalizedString("cad.unit.mm", comment: ""))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text("·").font(.caption2)
            Text("A \(formatCoord(line.angleDegrees))°")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text("·").font(.caption2)
            Text(sketch.reference.displayName).font(.caption2.weight(.semibold))
            if !viewModel.canvasOptions.showActivePlaneOverlay {
                Text("·").font(.caption2)
                Text(LocalizedStringKey("cad.canvas.active_plane_hidden")).font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func solidStatusBar(asset: DesignAsset) -> some View {
        if case let .extrudedSolid(parameters) = asset.kind {
            HStack(spacing: 5) {
                Image(systemName: asset.kind.iconName).font(.system(size: 10, weight: .semibold))
                Text(asset.name).font(.caption.weight(.semibold))
                Text("·").font(.caption2)
                Text("\(formatDimensionMM(parameters.depthMeters)) \(NSLocalizedString("cad.unit.mm", comment: ""))").font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text("·").font(.caption2)
                Text(asset.material.displayName).font(.caption2)
                if let face = viewModel.selectedPlanarFace {
                    Text("·").font(.caption2)
                    Text(String(format: NSLocalizedString("cad.face.selected", comment: ""), face.name)).font(.caption2.weight(.semibold))
                }
                Text("·").font(.caption2)
                Text(formatMass(asset.massProperties.massKg)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text("·").font(.caption2)
                Text("\(formatDimensions(asset.massProperties)) \(NSLocalizedString("cad.unit.mm", comment: ""))").font(.system(size: 10, design: .monospaced))
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: asset.kind.iconName).font(.system(size: 10, weight: .semibold))
                Text(asset.name).font(.caption.weight(.semibold))
                Text("·").font(.caption2)
                Text(formatMass(asset.massProperties.massKg)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text("·").font(.caption2)
                Text(asset.material.displayName).font(.caption2)
                Text("·").font(.caption2)
                Text(elementCountLabel(viewModel.document.assets.count)).font(.caption2)
            }
        }
    }

    private var defaultStatusBar: some View {
        HStack(spacing: 5) {
            Text(NSLocalizedString("cad.status.no_selection", comment: "")).font(.caption2)
            Text("·").font(.caption2)
            Text(elementCountLabel(viewModel.document.assets.count)).font(.caption2)
        }
    }

    private func statusChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.caption2.weight(.semibold))
        }
    }

    private func selectedLineConstraintStatus(lineID: UUID) -> String {
        if viewModel.selectedSketchLineHasConstraint(.horizontal) {
            return SketchConstraintKind.horizontal.displayName
        }
        if viewModel.selectedSketchLineHasConstraint(.vertical) {
            return SketchConstraintKind.vertical.displayName
        }
        if viewModel.selectedSketchLineHasConstraint(.fixedStart) && viewModel.selectedSketchLineHasConstraint(.fixedEnd) {
            return "\(SketchConstraintKind.fixedStart.displayName) / \(SketchConstraintKind.fixedEnd.displayName)"
        }
        if viewModel.selectedSketchLineHasConstraint(.fixedStart) {
            return SketchConstraintKind.fixedStart.displayName
        }
        if viewModel.selectedSketchLineHasConstraint(.fixedEnd) {
            return SketchConstraintKind.fixedEnd.displayName
        }
        return ""
    }

    // MARK: - Helpers

    private func isSketchAsset(_ asset: DesignAsset) -> Bool {
        if case .sketch2D = asset.kind { return true }
        return false
    }

    private func assetMassLabel(_ asset: DesignAsset) -> String {
        if isSketchAsset(asset) { return NSLocalizedString("cad.sketch.massless", comment: "") }
        return formatMass(asset.massProperties.massKg)
    }

    private func sketchContourText(_ sketch: DesignSketch) -> String {
        sketch.isClosed
            ? NSLocalizedString("cad.sketch.contour.closed", comment: "")
            : NSLocalizedString("cad.sketch.contour.open", comment: "")
    }

    private func formatMass(_ massKg: Double) -> String {
        guard massKg.isFinite, massKg >= 0 else { return "0 \(NSLocalizedString("cad.unit.grams", comment: ""))" }
        let grams = massKg * 1000
        if grams < 1000 { return "\(formatNumber(grams)) \(NSLocalizedString("cad.unit.grams", comment: ""))" }
        return String(format: "%.2f %@", massKg, NSLocalizedString("cad.unit.kg", comment: ""))
    }

    private func formatDensity(_ density: Double) -> String {
        guard density.isFinite else { return "0 kg/m3" }
        return String(format: "%.0f kg/m3", density)
    }

    private func formatDimensions(_ massProperties: DesignMassProperties) -> String {
        [formatDimensionMM(massProperties.boundingWidth), formatDimensionMM(massProperties.boundingHeight), formatDimensionMM(massProperties.boundingDepth)].joined(separator: "×")
    }

    private func formatVolume(_ volumeMeters3: Double) -> String {
        guard volumeMeters3.isFinite, volumeMeters3 >= 0 else { return "0 cm³" }
        let cubicCentimeters = volumeMeters3 * 1_000_000
        if cubicCentimeters < 1_000_000 {
            return "\(formatNumber(cubicCentimeters)) cm³"
        }
        return String(format: "%.3f m³", volumeMeters3)
    }

    private func formatDimensionMM(_ meters: Double) -> String {
        formatNumber(clampFinite(meters, to: 0...100) * 1000)
    }

    private func formatCoord(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 { return String(format: "%.0f", rounded) }
        return String(format: "%.1f", value)
    }

    private func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 { return String(format: "%.0f", rounded) }
        return String(format: "%.1f", value)
    }

    private func elementCountLabel(_ count: Int) -> String {
        String(format: NSLocalizedString("cad.status.elements", comment: ""), count)
    }

    private func clampFinite(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - ViewOrientationWidget

private struct ViewOrientationWidget: View {
    let currentMode: CADCameraMode
    let onSelectMode: (CADCameraMode) -> Void

    var body: some View {
        VStack(spacing: 1) {
            widgetButton(label: "Y", mode: .top)
            HStack(spacing: 1) {
                widgetButton(label: "X", mode: .side)
                widgetButton(label: "⌂", mode: .iso)
                widgetButton(label: "Z", mode: .front)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.07, green: 0.09, blue: 0.12).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func widgetButton(label: String, mode: CADCameraMode) -> some View {
        let isActive = currentMode == mode
        return Button { onSelectMode(mode) } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? GroundControlPalette.accent : GroundControlPalette.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? GroundControlPalette.accent.opacity(0.22) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(mode.labelKey, comment: ""))
    }
}

// MARK: - WorkshopMetricCell

private struct WorkshopMetricCell: View {
    let labelKey: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(labelKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GroundControlPalette.inset))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }
}

private enum WorkshopNumberFormatter {
    static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        return f
    }()
}
