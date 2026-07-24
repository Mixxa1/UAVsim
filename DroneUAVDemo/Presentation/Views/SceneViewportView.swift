import AppKit
import SwiftUI
import simd

struct SceneViewportView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    var trialPhase: LANTrialPhase = .running
    var recentSharedEvents: [OnlineSharedEvent] = []
    var onEndTrial: (() -> Void)? = nil
    var onLeaveTrial: (() -> Void)? = nil
    @StateObject private var tabObserver = TabKeyObserver()

    var body: some View {
        let overlayInset = viewModel.isParametersPanelVisible ? 18.0 : 12.0
        let payloadOpticsActive = viewModel.cameraConfiguration.mode == .payloadOptics
        let payloadOpticsState = viewModel.payloadCameraOpticsState
        let rangefinderOpticsState = viewModel.rangefinderOpticsState
        let rangefinderOpticsActive = payloadOpticsActive && !payloadOpticsState.isAvailable && rangefinderOpticsState.isAvailable
        let hoseOpticsState = viewModel.hoseOpticsState
        let hoseOpticsActive = payloadOpticsActive && !payloadOpticsState.isAvailable && !rangefinderOpticsState.isAvailable && hoseOpticsState.isAvailable
        // Aircraft-camera "digital viewfinder" OSD replaces the default instrument HUD + PFD compass
        // while the pilot is looking through the FPV camera, so the feed reads like a camera feed.
        let fpvHUDActive = viewModel.cameraConfiguration.mode == .fpv && !viewModel.isSpectatorMode && !payloadOpticsActive
        let capsuleState = viewModel.capsuleState
        let capsuleOpticsActive = payloadOpticsActive && !payloadOpticsState.isAvailable && !rangefinderOpticsState.isAvailable && !hoseOpticsState.isAvailable && capsuleState.isAvailable
        // Visual counterpart to the radio link-quality HUD — fiber isn't a radio concern at all
        // (bypasses `updateSignalLossSequence` entirely), so this only ever applies to `.radio`.
        let radioStaticIntensity: Double = {
            guard viewModel.activeControlLinkType == .radio else { return 0.0 }
            let status = viewModel.missionStatusSnapshot.operationalStatus
            guard status.isInWarningLinkZone else { return 0.0 }
            return Double(min(max(1.0 - status.currentLinkQuality, 0.0), 1.0))
        }()

        ZStack(alignment: .topLeading) {
            DroneSceneViewRepresentable(
                scene: viewModel.scene,
                pointOfView: viewModel.activeCameraNode,
                cameraMode: viewModel.cameraConfiguration.mode,
                cameraSensitivity: viewModel.cameraConfiguration.sensitivity,
                freeMoveSpeed: viewModel.cameraConfiguration.free.moveSpeed,
                activityState: viewModel.performancePolicy.activityState,
                wantsWeatherDepthOfField: viewModel.wantsWeatherDepthOfField,
                isHandLaunchPOV: viewModel.isHandLaunchPOVActive,
                onLookDelta: { dx, dy in
                    viewModel.handlePointerLook(deltaX: dx, deltaY: dy)
                },
                onRenderFrame: { time, mode in
                    viewModel.handleSceneRenderFrame(atTime: time, cameraMode: mode)
                }
            )
            .blur(radius: payloadOpticsActive ? min(max(payloadOpticsState.blurRadius, 0.0), 8.0) : 0.0)
            .ignoresSafeArea()

            if radioStaticIntensity > 0.02 {
                RadioLinkStaticOverlayView(intensity: radioStaticIntensity)
            }

            if payloadOpticsActive, payloadOpticsState.isAvailable {
                PayloadOpticsViewportOverlayView(
                    state: payloadOpticsState,
                    thermalState: viewModel.payloadThermalState
                )
                .ignoresSafeArea()
            }

            if rangefinderOpticsActive {
                RangefinderOpticsViewportOverlayView(state: rangefinderOpticsState)
                    .ignoresSafeArea()
            }

            if hoseOpticsActive {
                HoseAimViewportOverlayView(
                    state: hoseOpticsState,
                    burningCount: viewModel.fireResponseBurningCount,
                    totalCount: viewModel.fireResponseTotalCount,
                    isTetherActive: viewModel.isHoseTetherActive,
                    isTetherTaut: viewModel.isHoseTetherTaut,
                    tetherDistanceMeters: viewModel.hoseTetherDistanceMeters,
                    tetherLimitMeters: viewModel.hoseTetherLimitMeters
                )
                .ignoresSafeArea()
            }

            if capsuleOpticsActive {
                CapsuleBombardierOpticsOverlayView(state: capsuleState)
                    .ignoresSafeArea()
            }

            // The LiDAR survey is flown like a normal sortie — the cloud builds in the main 3-D
            // view — so its control panel sits in the corner rather than replacing the viewport.
            if viewModel.lidarOpticsState.isAvailable {
                LidarModuleView(
                    state: viewModel.lidarOpticsState,
                    onToggleScan: { viewModel.toggleLidarScanning() },
                    onPitchDelta: { viewModel.adjustLidarGimbal(pitchDeltaDegrees: $0) },
                    onVoxelSize: { viewModel.setLidarVoxelSize($0) },
                    onRawMode: { viewModel.setLidarRawMode($0) },
                    onColorMode: { viewModel.setLidarColorMode($0) },
                    onClear: { viewModel.clearLidarCloud() },
                    onExport: { viewModel.exportLidarCloud() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(16)
            }

            // Kept visible in every OTHER camera mode too (not just the bombardier view) — the
            // ground-projected blast-radius reticle (`DroneSceneController.setFireCapsuleTargetReticle`)
            // is real 3D scene geometry, visible from any camera, so ammo/rig status shouldn't be
            // hidden just because the operator isn't using the dedicated bombardier camera right now.
            if capsuleState.isAvailable, !capsuleOpticsActive {
                FireCapsuleStatusHUDView(state: capsuleState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, overlayInset + 10)
                    .allowsHitTesting(false)
            }

            if viewModel.agriculturalSprayerState.isAvailable {
                AgriculturalSprayerStatusHUDView(state: viewModel.agriculturalSprayerState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, overlayInset + 10)
                    .allowsHitTesting(false)
            }

            if viewModel.isFiberSpoolAttached, viewModel.fiberLinkState.status != .broken {
                FiberOpticTetherStatusHUDView(
                    remainingLengthMeters: viewModel.fiberLinkState.remainingLengthMeters,
                    usableLengthMeters: viewModel.fiberLinkState.usableLengthMeters,
                    snagRiskLevel: viewModel.fiberLinkState.snagRiskLevel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, overlayInset + 10)
                .allowsHitTesting(false)
            }

            // Dedicated to the fiber-severance failsafe — deliberately not the generic
            // signal-loss overlay (`UAVSignalState`), since the aircraft is actively flying
            // itself through named stages here, not frozen.
            if viewModel.controlLinkFailsafeStage.isActive {
                ControlLinkFailsafeStageHUDView(
                    stage: viewModel.controlLinkFailsafeStage,
                    trigger: viewModel.controlLinkFailsafeTrigger
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, overlayInset + 10)
                    .allowsHitTesting(false)
            }

            // Grounded + blocked is the only time this matters (arm only applies while
            // disarmed/on the ground) — a landing ends the aircraft's motion, not the reason
            // control was lost, so this can outlive the failsafe banner above by a long margin
            // (e.g. a severed fiber blocks re-arm indefinitely, until the spool is replaced).
            if viewModel.physicalState.isGroundRestState, viewModel.armBlockReason != .none {
                ArmBlockedHUDView(reason: viewModel.armBlockReason)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, overlayInset + 10)
                    .allowsHitTesting(false)
            }

            if payloadOpticsActive, payloadOpticsState.isAvailable, payloadOpticsState.mode == .thermalStub {
                ThermalScaleBarView(thermalState: viewModel.payloadThermalState)
                    .padding(.trailing, overlayInset + 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .allowsHitTesting(false)
            }

            if payloadOpticsActive,
               payloadOpticsState.isAvailable,
               payloadOpticsState.mode == .thermalStub,
               viewModel.payloadThermalState.showDiagnostics {
                ThermalDiagnosticsOverlayView(thermalState: viewModel.payloadThermalState)
                    .padding(.leading, overlayInset)
                    .padding(.bottom, overlayInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }

            if viewModel.isSpectatorMode || payloadOpticsActive {
                EmptyView()
            } else if fpvHUDActive {
                FPVViewportOverlayView(
                    telemetry: viewModel.telemetry,
                    flightControlMode: viewModel.flightControlMode,
                    compass: viewModel.compassViewModel,
                    leftStick: viewModel.fpvLeftStick,
                    rightStick: viewModel.fpvRightStick,
                    isRecording: viewModel.isOnboardRecording
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else if !viewModel.isParametersPanelVisible || viewModel.isCompactTelemetryHUDEnabled {
                CompactTelemetryHUDView(
                    telemetry: viewModel.telemetry,
                    warningKeys: viewModel.warnings
                )
                .padding(.leading, overlayInset)
                .padding(.top, overlayInset)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let activeModule = viewModel.activeControlModule {
                        HStack(spacing: 8) {
                            Image(systemName: activeModule.iconSystemName)
                            Text(LocalizedStringKey(activeModule.titleKey))
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    } else {
                        Text("hud.title")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }

                    Text("\(localized("hud.camera")): \(localized(viewModel.cameraConfiguration.mode.titleKey)) | \(localized("hud.drone")): \(viewModel.selectedDroneProfile.uiDisplayName)")
                        .font(.caption2.monospaced())
                    if let warningKey = viewModel.warnings.first {
                        Text(LocalizedStringKey(warningKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.warning)
                    }
                }
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                )
                .frame(maxWidth: 296, alignment: .leading)
                .padding(.leading, overlayInset)
                .padding(.top, overlayInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if !viewModel.isSpectatorMode, viewModel.isCompassVisible, !payloadOpticsActive, !fpvHUDActive {
                    CompassOverlayView(
                        viewModel: viewModel.compassViewModel,
                        telemetry: viewModel.telemetry
                    )
                }

                if viewModel.onlineTrialContext != nil {
                    OnlineTrialRuntimeOverlay(
                        context: viewModel.onlineTrialContext,
                        fleetState: viewModel.onlineFleetState,
                        remoteStates: viewModel.onlineInterpolatedRemoteStates,
                        snapshotTargetHz: 10,
                        isExpanded: tabObserver.isTabHeld,
                        trialPhase: trialPhase,
                        participantCount: viewModel.onlineTrialContext?.launchDescriptor.assignments.count ?? 0,
                        staleCount: viewModel.onlineTrialStaleRemoteCount,
                        damageState: viewModel.onlineDamageState,
                        recentSharedEvents: recentSharedEvents,
                        diagnostics: viewModel.onlineRuntimeDiagnostics,
                        onEndTrial: onEndTrial,
                        onLeaveTrial: onLeaveTrial
                    )
                    .animation(.easeInOut(duration: 0.12), value: tabObserver.isTabHeld)
                }

                if !viewModel.isSpectatorMode {
                    if viewModel.isTerrainMapVisible, !viewModel.isMissionMapVisible {
                        TerrainMapOverlayView(
                            snapshot: viewModel.terrainMapSnapshot,
                            telemetry: viewModel.telemetry,
                            targetMarker: viewModel.targetMarkerState,
                            dropZone: viewModel.missionPlanState.dropZone,
                            onSelectTarget: { viewModel.setTargetMarker(at: $0) },
                            onClearTarget: { viewModel.clearTargetMarker() }
                        )
                    }

                    if viewModel.cameraConfiguration.mode == .payload, viewModel.payloadCameraStatus.isActive {
                        PayloadCameraStatusOverlayView(status: viewModel.payloadCameraStatus)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .background(Color.black)
        .onAppear { tabObserver.start(viewModel: viewModel) }
        .onDisappear { tabObserver.stop() }
    }
}

// MARK: – Tab-hold key observer for the online detail panel

private final class TabKeyObserver: ObservableObject {
    @Published var isTabHeld = false
    private var monitor: Any?

    func start(viewModel: DroneSimulationViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak viewModel] event in
            guard let self, viewModel?.onlineTrialContext != nil else { return event }
            guard event.keyCode == 48 else { return event } // Tab
            if event.type == .keyDown, !event.isARepeat {
                self.isTabHeld = true
                return nil
            } else if event.type == .keyUp {
                self.isTabHeld = false
                return nil
            }
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isTabHeld = false
    }

    deinit { stop() }
}

private struct PayloadCameraStatusOverlayView: View {
    let status: PayloadCameraStatus

    private var altitudeText: String {
        String(format: "%06.1f m", max(0.0, status.altitude))
    }

    private var verticalSpeedText: String {
        String(format: "%+06.1f m/s", status.verticalSpeed)
    }

    private var elapsedTimeText: String {
        String(format: "%05.1f s", max(0.0, status.elapsedTime))
    }

    private var stateColor: Color {
        switch status.state {
        case .impact:
            return GroundControlPalette.warning
        case .rest:
            return GroundControlPalette.success
        case .falling:
            return GroundControlPalette.textPrimary
        case .inactive:
            return GroundControlPalette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("overlay.payload_view.title")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
            metricRow(label: localized("overlay.payload_view.metric.alt"), value: altitudeText, color: GroundControlPalette.textSecondary)
            metricRow(label: localized("overlay.payload_view.metric.vertical_speed"), value: verticalSpeedText, color: GroundControlPalette.textSecondary)
            metricRow(label: localized("overlay.payload_view.metric.time"), value: elapsedTimeText, color: GroundControlPalette.textSecondary)
            metricRow(label: localized("overlay.payload_view.metric.state"), value: status.state.title, color: stateColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 248, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GroundControlPalette.panel.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metricRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 38, alignment: .leading)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(color)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PayloadOpticsViewportOverlayView: View {
    let state: PayloadCameraOpticsState
    var thermalState: PayloadThermalState = .default

    private var feedLabel: String {
        state.mode == .thermalStub ? thermalState.palette.feedLabel : state.feedLabel
    }

    private var targetText: String {
        guard let target = state.targetDistanceMeters else {
            return "-- m"
        }
        return String(format: "%.1f m", target)
    }

    private var zoomText: String {
        String(format: "%.1fx", state.zoomLevel)
    }

    private var focusText: String {
        String(format: "%.1f m", state.focusDistanceMeters)
    }

    private var fovText: String {
        String(format: "%.1f°", state.currentFieldOfViewDegrees)
    }

    private var reticleOpacity: Double {
        0.22 + state.focusLockPulse * 0.78
    }

    private var reticleScale: Double {
        1.08 - state.focusLockPulse * 0.18
    }

    private var reticleColor: Color {
        if state.focusLockPulse > 0.05 {
            return Color.white.opacity(0.96)
        }
        return overlayTint.opacity(0.8)
    }

    private var overlayTint: Color {
        state.isPowered ? Color(red: 0.78, green: 0.94, blue: 1.0) : Color.white.opacity(0.62)
    }

    var body: some View {
        ZStack {
            if !state.isPowered {
                Color.black.opacity(0.34)
            }

            PayloadOpticsCornerFrame()
                .stroke(overlayTint.opacity(0.95), style: StrokeStyle(lineWidth: 2.0, lineCap: .square))
                .padding(22)

            payloadFocusReticle
                .scaleEffect(reticleScale)
                .opacity(reticleOpacity)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feedLabel)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                        Text("ZOOM \(zoomText)")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    }

                    Spacer()

                    if state.isRecording {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                            Text("REC")
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.red.opacity(0.96))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                Spacer()

                if !state.isPowered {
                    statusPill(titleKey: "payload.camera.powered_off", tint: GroundControlPalette.warning)
                } else if !state.isAvailable {
                    statusPill(titleKey: "payload.camera.unavailable", tint: GroundControlPalette.warning)
                }

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FOCUS \(focusText)")
                        Text("TARGET \(targetText)")
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        if state.autofocusEnabled {
                            Text("AF")
                        }
                        Text("FOV \(fovText)")
                    }
                }
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
            }
            .foregroundStyle(overlayTint)
        }
        .allowsHitTesting(false)
    }

    private func statusPill(titleKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.56), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.45), lineWidth: 1)
            )
    }

    private var payloadFocusReticle: some View {
        ZStack {
            CrosshairShape()
                .stroke(reticleColor.opacity(0.92), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 116, height: 116)
                .shadow(color: reticleColor.opacity(state.focusLockPulse * 0.55), radius: 18)
        }
        .allowsHitTesting(false)
    }
}

private struct RangefinderOpticsViewportOverlayView: View {
    let state: PayloadRangefinderOpticsState

    private var distanceText: String {
        guard let distance = state.measuredDistanceMeters else {
            return "-- m"
        }
        return String(format: "%.1f m", distance)
    }

    private var zoomText: String {
        String(format: "%.1fx", state.zoomLevel)
    }

    private var overlayTint: Color {
        state.isPowered ? Color(red: 1.0, green: 0.82, blue: 0.78) : Color.white.opacity(0.62)
    }

    private var reticleColor: Color {
        state.isArmed ? Color.red.opacity(0.9) : overlayTint.opacity(0.8)
    }

    var body: some View {
        ZStack {
            if !state.isPowered {
                Color.black.opacity(0.34)
            }

            PayloadOpticsCornerFrame()
                .stroke(overlayTint.opacity(0.95), style: StrokeStyle(lineWidth: 2.0, lineCap: .square))
                .padding(22)

            CrosshairShape()
                .stroke(reticleColor.opacity(0.92), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 116, height: 116)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.feedLabel)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                        Text("ZOOM \(zoomText)")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    }

                    Spacer()

                    if state.isArmed {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                            Text("LASER")
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.red.opacity(0.96))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                Spacer()

                if !state.isPowered {
                    statusPill(titleKey: "payload.rangefinder.powered_off", tint: GroundControlPalette.warning)
                } else if !state.isAvailable {
                    statusPill(titleKey: "payload.rangefinder.unavailable", tint: GroundControlPalette.warning)
                }

                Spacer()

                Text("RANGE \(distanceText)")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 28)
            }
            .foregroundStyle(overlayTint)
        }
        .allowsHitTesting(false)
    }

    private func statusPill(titleKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.56), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct HoseAimViewportOverlayView: View {
    let state: PayloadFireHoseOpticsState
    let burningCount: Int
    let totalCount: Int
    let isTetherActive: Bool
    let isTetherTaut: Bool
    let tetherDistanceMeters: Float
    let tetherLimitMeters: Float

    private var overlayTint: Color {
        state.isPowered ? Color(red: 0.80, green: 0.92, blue: 1.0) : Color.white.opacity(0.62)
    }

    private var reticleColor: Color {
        state.isSpraying ? Color.white.opacity(0.95) : Color(red: 0.35, green: 0.85, blue: 0.95).opacity(0.85)
    }

    private var isOnTarget: Bool { state.aimedFireTreeIndex != nil }

    var body: some View {
        ZStack {
            if !state.isPowered {
                Color.black.opacity(0.34)
            }

            // A plain aim bead for the nozzle, not a camera viewfinder — this is manual hand-eye
            // aiming of a physical stream, not an optical device that locks onto a target for you.
            Circle()
                .stroke(reticleColor, lineWidth: isOnTarget ? 2.2 : 1.6)
                .frame(width: isOnTarget ? 22 : 16, height: isOnTarget ? 22 : 16)
            Circle()
                .fill(reticleColor)
                .frame(width: 3, height: 3)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.feedLabel)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                        Text(String(
                            format: NSLocalizedString("payload.hose.throw_distance", comment: ""),
                            state.nozzleThrowMeters
                        ))
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        if isTetherActive {
                            Text(String(
                                format: NSLocalizedString("payload.hose.tether_distance", comment: ""),
                                tetherDistanceMeters,
                                tetherLimitMeters
                            ))
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isTetherTaut ? Color.red.opacity(0.95) : overlayTint)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        if state.isSpraying {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 12, height: 12)
                                Text(LocalizedStringKey("payload.hose.spraying_status"))
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.96))
                            }
                        }
                        if isTetherTaut {
                            Text(LocalizedStringKey("payload.hose.tether_taut"))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.85), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                Spacer()

                if !state.isPowered {
                    statusPill(titleKey: "payload.hose.powered_off", tint: GroundControlPalette.warning)
                } else if !state.isAvailable {
                    statusPill(titleKey: "payload.hose.unavailable", tint: GroundControlPalette.warning)
                }

                Spacer()

                Text(String(format: NSLocalizedString("mission.hud.fires_remaining", comment: ""), burningCount, totalCount))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 28)
            }
            .foregroundStyle(overlayTint)
        }
        .allowsHitTesting(false)
    }

    private func statusPill(titleKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.56), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.45), lineWidth: 1)
            )
    }
}

/// Small always-visible ammo/rig status panel for the fire-capsule launcher, shown in every camera
/// mode except the dedicated bombardier camera (which has its own, richer readout). Styled to match
/// the rest of the sim's instrument HUD (`CompactTelemetryHUDView`, `MissionScenarioHUDView`) —
/// a plain dark panel with a thin border and small monospace text, not a bold colorful game-style
/// ammo badge.
private struct FireCapsuleStatusHUDView: View {
    let state: PayloadFireCapsuleState

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: NSLocalizedString("payload.capsule.remaining", comment: ""), state.remainingCapsules))
                .foregroundStyle(state.remainingCapsules > 0 ? GroundControlPalette.textPrimary : GroundControlPalette.danger)

            Text(LocalizedStringKey(state.capsuleSize.titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)

            Text(String(format: "%.0f m", state.capsuleSize.blastRadiusMeters))
                .foregroundStyle(GroundControlPalette.textSecondary)

            if state.isRecharging {
                Text(String(
                    format: NSLocalizedString("payload.capsule.recharge_countdown", comment: ""),
                    state.rechargeSecondsRemaining
                ))
                .foregroundStyle(GroundControlPalette.warning)
            }
        }
        .font(.caption.weight(.semibold).monospaced())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }
}

/// Always-visible-when-mounted tank readout — no dedicated optics view for the sprayer (it has
/// no aim/gimbal), so this is the only place the operator sees remaining liquid, matching
/// `FireCapsuleStatusHUDView`'s instrument-panel look above.
private struct AgriculturalSprayerStatusHUDView: View {
    let state: PayloadAgriculturalSprayerState

    var body: some View {
        HStack(spacing: 12) {
            Text(String(
                format: NSLocalizedString("payload.sprayer.tank_remaining", comment: ""),
                state.tankRemainingLiters,
                state.tankCapacityLiters
            ))
            .foregroundStyle(state.tankRemainingLiters > 0.5 ? GroundControlPalette.textPrimary : GroundControlPalette.danger)

            if state.isSpraying {
                Text(LocalizedStringKey("payload.sprayer.spraying"))
                    .foregroundStyle(GroundControlPalette.warning)
            }
        }
        .font(.caption.weight(.semibold).monospaced())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }
}

/// No dedicated optics view (no aim/gimbal) — remaining fiber (in km, path-length budget not
/// straight-line distance) and entanglement risk are only ever visible here.
private struct FiberOpticTetherStatusHUDView: View {
    let remainingLengthMeters: Float
    let usableLengthMeters: Float
    let snagRiskLevel: Float

    var body: some View {
        HStack(spacing: 12) {
            Text(String(
                format: NSLocalizedString("payload.fiber.remaining", comment: ""),
                remainingLengthMeters / 1000.0,
                usableLengthMeters / 1000.0
            ))
            .foregroundStyle(remainingLengthMeters > 50.0 ? GroundControlPalette.textPrimary : GroundControlPalette.danger)

            if snagRiskLevel > 0.05 {
                Text(String(
                    format: NSLocalizedString("payload.fiber.snag_risk", comment: ""),
                    snagRiskLevel * 100.0
                ))
                .foregroundStyle(snagRiskLevel > 0.6 ? GroundControlPalette.danger : GroundControlPalette.warning)
            }
        }
        .font(.caption.weight(.semibold).monospaced())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }
}

/// Deterministic per-frame "tick" generator for the radio-static overlay below — reseeded from a
/// coarse time bucket (not the shared gameplay RNG) so the noise reads as flickering static at a
/// fixed rate rather than a smooth animation, without needing to store any state across frames.
private struct StaticNoiseTickGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(tick: Int) {
        let seeded = UInt64(bitPattern: Int64(tick)) &* 2862933555777941757 &+ 3037000493
        state = seeded == 0 ? 0xDEAD_BEEF : seeded
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}

/// Visual counterpart to the radio link-quality HUD text — a lightweight, SwiftUI-only static/
/// interference effect over the camera feed. Deliberately not a second `SCNTechnique`:
/// `SCNView.technique` only holds one technique at a time and that slot is already claimed by
/// `WeatherDepthOfFieldTechnique`, so layering a real shader-based effect on top would require
/// merging passes into that technique rather than adding an independent one. `intensity` is
/// `(1 - currentLinkQuality)`, already thresholded by the caller to only appear at/above the
/// radio link's warning zone.
private struct RadioLinkStaticOverlayView: View {
    let intensity: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                guard intensity > 0.01 else { return }
                let time = timeline.date.timeIntervalSinceReferenceDate

                let flicker = 0.05 + 0.03 * sin(time * 37.0)
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color.white.opacity(intensity * flicker))
                )

                // Re-seeded ~12 times a second so the snow reads as flickering static, not a
                // continuously-drifting pattern.
                var rng = StaticNoiseTickGenerator(tick: Int(time * 12.0))
                let lineCount = Int(6.0 + intensity * 26.0)
                for _ in 0..<lineCount {
                    let y = CGFloat(Double.random(in: 0...Double(size.height), using: &rng))
                    let lineWidth = CGFloat(Double.random(in: Double(size.width) * 0.05...Double(size.width) * 0.4, using: &rng))
                    let x = CGFloat(Double.random(in: 0...Double(size.width - lineWidth), using: &rng))
                    let alpha = Double.random(in: 0.06...0.22, using: &rng) * intensity
                    context.fill(
                        Path(CGRect(x: x, y: y, width: lineWidth, height: 1.4)),
                        with: .color(Color.white.opacity(alpha))
                    )
                }

                // Occasional full-width dropout band, only once the link is genuinely bad — reads
                // as a signal glitch rather than just grain.
                if intensity > 0.55, Double.random(in: 0...1, using: &rng) < 0.12 {
                    let bandHeight = CGFloat(Double.random(in: 6...22, using: &rng))
                    let y = CGFloat(Double.random(in: 0...Double(size.height) - bandHeight, using: &rng))
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: bandHeight)),
                        with: .color(Color.black.opacity(0.35))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Top-of-screen banner for the named control-link-loss failsafe stages (fiber severance or a
/// radio link lost on an autopilot-equipped aircraft) — deliberately distinct from the
/// bottom-aligned equipment HUDs above and from the generic signal-loss overlay, since this
/// reflects the aircraft actively flying itself through a recovery sequence, not a frozen
/// "signal lost" state.
private struct ControlLinkFailsafeStageHUDView: View {
    let stage: ControlLinkFailsafeStage
    let trigger: ControlLinkFailsafeTrigger

    var body: some View {
        Text(LocalizedStringKey(stage.titleKey(trigger: trigger)))
            .font(.caption.weight(.bold).monospaced())
            .textCase(.uppercase)
            .foregroundStyle(GroundControlPalette.danger)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GroundControlPalette.danger.opacity(0.7), lineWidth: 1)
            )
    }
}

/// Shown whenever the aircraft is grounded and `resolveArmAuthorization()` currently refuses to
/// arm — the runtime gate itself lives in `DroneSimulationViewModel.arm()`/
/// `resolveArmAuthorization()`, this is purely the "why" surfaced to the player before they even
/// try, so a severed fiber or an unrecovered radio link doesn't read as an unresponsive button.
private struct ArmBlockedHUDView: View {
    let reason: ArmBlockReason

    var body: some View {
        VStack(spacing: 4) {
            Text("arm_block.title")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.7))
            Text(LocalizedStringKey(reason.titleKey))
                .font(.caption.weight(.bold).monospaced())
        }
        .foregroundStyle(GroundControlPalette.danger)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.danger.opacity(0.7), lineWidth: 1)
        )
    }
}

/// Bombardier camera reticle for the fire-capsule launcher — a scope-style aiming view (circular
/// vignette, mil-ruler ticks scaled to the rigged capsule's blast radius, center crosshair) shown
/// through `DroneSceneController`'s fixed nadir `capsuleCameraNode`. Unlike the hose/rangefinder
/// overlays, there's no aim state to reflect (no yaw/pitch, no lock-on) — the crosshair is always
/// exactly the true impact point, since the capsule's fall has zero forward-throw. This is the
/// direct answer to "improve the capsule marker": a dedicated aiming view instead of only the
/// ground-projected ring (which stays, visible from every other camera mode too). The status
/// readout at the bottom matches the sim's own instrument-panel look (see `FireCapsuleStatusHUDView`
/// above), not a game-style HUD badge.
private struct CapsuleBombardierOpticsOverlayView: View {
    let state: PayloadFireCapsuleState

    private var blastRadius: Float { max(0.1, state.capsuleSize.blastRadiusMeters) }
    private var tickMultipliers: [Float] { [-2.0, -1.0, 0.0, 1.0, 2.0] }

    var body: some View {
        GeometryReader { geometry in
            let shortSide = min(geometry.size.width, geometry.size.height)
            let vignetteDiameter = shortSide * 0.92
            let rulerHalfWidth = shortSide * 0.32
            let maxRadius = max(geometry.size.width, geometry.size.height) * 0.75
            let edgeFraction = Double((vignetteDiameter / 2.0) / maxRadius)

            ZStack {
                // Circular vignette: fully clear inside the ring so the scene reads normally, then
                // a quick ramp to near-opaque black right at the ring's edge and beyond — a real
                // scope/binocular view, not just a soft darkening toward the corners.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: min(0.97, edgeFraction * 0.94)),
                        .init(color: Color.black.opacity(0.97), location: min(0.985, edgeFraction * 1.06)),
                        .init(color: Color.black.opacity(0.97), location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: maxRadius
                )
                .allowsHitTesting(false)

                Circle()
                    .stroke(Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.75), lineWidth: 2.0)
                    .frame(width: vignetteDiameter, height: vignetteDiameter)

                // Horizontal mil-ruler, ticks scaled to the rigged capsule's actual blast radius so
                // the operator can visually judge whether nearby trees fall inside the burst.
                ZStack {
                    Rectangle()
                        .fill(Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.6))
                        .frame(width: rulerHalfWidth * 2.0, height: 1.5)

                    ForEach(Array(tickMultipliers.enumerated()), id: \.offset) { _, multiplier in
                        let x = CGFloat(multiplier / 2.0) * rulerHalfWidth
                        VStack(spacing: 2) {
                            Rectangle()
                                .fill(Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.85))
                                .frame(width: 1.5, height: multiplier == 0.0 ? 16 : 10)
                            Text(String(format: "%.0fm", multiplier * blastRadius))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.85))
                        }
                        .offset(x: x)
                    }
                }

                CrosshairShape()
                    .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                    .frame(width: 40, height: 40)

                VStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: NSLocalizedString("payload.capsule.remaining", comment: ""), state.remainingCapsules))
                            .foregroundStyle(state.remainingCapsules > 0 ? GroundControlPalette.textPrimary : GroundControlPalette.danger)
                        Text(LocalizedStringKey(state.capsuleSize.titleKey))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                        Text(String(format: "%.0f m", state.capsuleSize.blastRadiusMeters))
                            .foregroundStyle(GroundControlPalette.textSecondary)

                        if state.isRecharging {
                            Text(String(
                                format: NSLocalizedString("payload.capsule.recharge_countdown", comment: ""),
                                state.rechargeSecondsRemaining
                            ))
                            .foregroundStyle(GroundControlPalette.warning)

                            ProgressView(value: state.rechargeProgress01)
                                .frame(width: 140)
                                .tint(GroundControlPalette.warning)
                        }
                    }
                    .font(.caption.weight(.semibold).monospaced())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                    )
                    .padding(.bottom, 40)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct ThermalDiagnosticsOverlayView: View {
    let thermalState: PayloadThermalState

    private var diag: ThermalDiagnosticsSnapshot { thermalState.diagnostics }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("overlay.thermal_diagnostics.title")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.78, green: 0.94, blue: 1.0))

            row("AMBIENT", String(format: "%.1f C", diag.ambientTemperatureCelsius))
            row("WEATHER", diag.weatherKind.uppercased())
            row("PROFILE", localized(thermalState.resolvedProfile.titleKey).uppercased())
            row("RANGE", String(format: "%.0f...%.0f C", diag.displayMinCelsius, diag.displayMaxCelsius))

            Divider().background(Color.white.opacity(0.2))

            if let temp = diag.centerTemperatureCelsius {
                row("CENTER T", String(format: "%.1f C", temp))
            } else {
                row("CENTER T", "--")
            }
            if let cls = diag.centerMaterialClass {
                row("CENTER", localized(cls.titleKey).uppercased())
            } else {
                row("CENTER", "--")
            }
            if let name = diag.centerNodeName {
                row("NODE", name)
            }

            Divider().background(Color.white.opacity(0.2))

            row("SUN", String(format: "%.0f%%", diag.sunExposure * 100.0))
            row("RAIN/SNOW", String(format: "%.0f / %.0f%%", diag.rainIntensity * 100.0, diag.snowIntensity * 100.0))
            row("FOG/CLOUD", String(format: "%.0f / %.0f%%", diag.fogDensity * 100.0, diag.cloudiness * 100.0))
            row("WIND", String(format: "%.1f m/s", diag.windSpeedMps))
        }
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .frame(maxWidth: 280, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 92, alignment: .leading)
            Text(value)
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

/// Permanent thermal HUD legend (matches a real IR camera's on-screen scale bar) — a continuous
/// palette gradient from `displayMin` (bottom) to `displayMax` (top) with evenly spaced °C ticks.
/// Always visible while thermal is active, independent of the diagnostics toggle.
private struct ThermalScaleBarView: View {
    let thermalState: PayloadThermalState

    private let tickCount = 6
    private let sampleCount = 48
    private let barHeight: CGFloat = 220

    private var diag: ThermalDiagnosticsSnapshot { thermalState.diagnostics }

    private var span: Double {
        max(0.5, diag.displayMaxCelsius - diag.displayMinCelsius)
    }

    private var gradientStops: [Gradient.Stop] {
        (0...sampleCount).map { index in
            let fraction = Double(index) / Double(sampleCount)
            let temperature = diag.displayMinCelsius + fraction * span
            let color = ThermalPaletteMapper.color(
                forTemperature: temperature,
                displayMin: diag.displayMinCelsius,
                displayMax: diag.displayMaxCelsius,
                palette: thermalState.palette,
                contrast: thermalState.contrast,
                brightness: thermalState.brightness
            )
            return Gradient.Stop(color: Color(nsColor: color), location: fraction)
        }
    }

    /// Tick temperatures, highest first (so the first label lines up with the top of the bar).
    private var tickValues: [Double] {
        (0..<tickCount).reversed().map { index in
            let fraction = Double(index) / Double(tickCount - 1)
            return diag.displayMinCelsius + fraction * span
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(spacing: 0) {
                ForEach(Array(tickValues.enumerated()), id: \.offset) { _, value in
                    Text(String(format: "%.0f°", value))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(height: barHeight)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: gradientStops),
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: 14, height: barHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1)
                )
        }
        .padding(8)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}

private struct PayloadOpticsCornerFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.0
        let length: CGFloat = 34.0

        var path = Path()

        path.move(to: CGPoint(x: inset, y: inset + length))
        path.addLine(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: inset + length, y: inset))

        path.move(to: CGPoint(x: rect.maxX - inset - length, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset + length))

        path.move(to: CGPoint(x: inset, y: rect.maxY - inset - length))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset + length, y: rect.maxY - inset))

        path.move(to: CGPoint(x: rect.maxX - inset - length, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - length))

        return path
    }
}

private struct CrosshairShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        let midY = rect.midY
        let arm: CGFloat = min(rect.width, rect.height) * 0.5

        path.move(to: CGPoint(x: midX - arm, y: midY))
        path.addLine(to: CGPoint(x: midX + arm, y: midY))

        path.move(to: CGPoint(x: midX, y: midY - arm))
        path.addLine(to: CGPoint(x: midX, y: midY + arm))

        return path
    }
}

private struct TerrainMapOverlayView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let telemetry: TelemetrySnapshot
    let targetMarker: TargetMarkerState?
    let dropZone: DropZoneState?
    let onSelectTarget: (SIMD2<Float>) -> Void
    let onClearTarget: () -> Void

    private var headingDegreesText: String {
        String(format: "%03.0f", bodyHeadingDegrees(fromYawRadians: snapshot.droneYawRadians))
    }

    private var mapSpanText: String {
        String(format: "%.0f m", snapshot.worldHalfExtent * 2.0)
    }

    private var signalRadiusText: String {
        String(format: "%.0f / %.0f m", snapshot.linkQualityRadius, snapshot.degradedLinkRadius)
    }

    private var autoNavigationLabel: String {
        telemetry.autoNavigationActive ? localized("telemetry.auto_nav.active") : localized("telemetry.auto_nav.inactive")
    }

    private var targetMetricsText: String {
        guard telemetry.targetDistanceMeters.isFinite, telemetry.targetBearingDegrees.isFinite else {
            return localized("overlay.terrain_map.target_metrics.empty")
        }

        return String(
            format: localized("overlay.terrain_map.target_metrics.format"),
            telemetry.targetDistanceMeters,
            telemetry.targetBearingDegrees
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("overlay.terrain_map.title")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text("overlay.terrain_map.subtitle")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if targetMarker != nil {
                        Button(action: onClearTarget) {
                            Text("overlay.terrain_map.clear")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(GroundControlPalette.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(GroundControlPalette.inset, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("M")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(GroundControlPalette.inset, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                        )
                }
            }

            ZStack {
                TerrainMapCanvas(
                    snapshot: snapshot,
                    routeTargetPosition: targetMarker?.position,
                    dropZone: dropZone,
                    highlightDropZone: telemetry.inDropZone
                )

                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0.0, coordinateSpace: .local)
                                .onEnded { value in
                                    let projection = TerrainMapProjection(snapshot: snapshot, size: geometry.size)
                                    guard let planarPoint = projection.unproject(value.location) else {
                                        return
                                    }
                                    onSelectTarget(planarPoint)
                                }
                        )
                }
            }
            .frame(width: 288, height: 288)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    String(
                        format: localized("overlay.terrain_map.heading_alt_objects.format"),
                        headingDegreesText,
                        snapshot.droneAltitude,
                        snapshot.objects.count
                    )
                )
                Text(
                    String(
                        format: localized("overlay.terrain_map.position_map.format"),
                        telemetry.x,
                        telemetry.z,
                        mapSpanText
                    )
                )
                Text(
                    String(
                        format: localized("overlay.terrain_map.status.format"),
                        signalRadiusText,
                        autoNavigationLabel
                    )
                )
                Text(targetMetricsText)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .padding(12)
        .frame(width: 332, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(GroundControlPalette.panel.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, y: 10)
    }
}

struct TerrainMapCanvas: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let routeTargetPosition: SIMD2<Float>?
    let dropZone: DropZoneState?
    let highlightDropZone: Bool
    var zoomFactor: CGFloat = 1.0
    @ObservedObject private var basemapStore = TerrainMapBasemapStore.shared

    var body: some View {
        let basemapImage = basemapStore.image(for: snapshot)

        Canvas(rendersAsynchronously: true) { context, size in
            let projection = TerrainMapProjection(
                snapshot: snapshot,
                size: size,
                zoomFactor: zoomFactor
            )

            drawMapBase(in: &context, projection: projection)
            context.clip(to: Path(projection.mapRect))
            drawBasemap(
                in: &context,
                projection: projection,
                geographicImage: basemapImage
            )
            drawSceneTerrainDetails(in: &context, projection: projection)
            for object in snapshot.objects {
                drawObject(object, in: &context, projection: projection)
            }
            drawGrid(in: &context, projection: projection)
            drawOperationalEnvelope(in: &context, projection: projection)
            drawTrail(in: &context, projection: projection)
            if let dropZone {
                drawDropZone(dropZone, in: &context, projection: projection)
            }
            drawMissionRoute(in: &context, projection: projection)
            drawActiveLeg(in: &context, projection: projection)
            drawPredictedPath(in: &context, projection: projection)
            drawMissionWaypoints(in: &context, projection: projection)

            if let targetMarkerPosition = routeTargetPosition ?? snapshot.targetMarkerPosition {
                drawTargetLink(to: targetMarkerPosition, in: &context, projection: projection)
            }

            drawDock(in: &context, projection: projection)
            if let targetMarkerPosition = routeTargetPosition ?? snapshot.targetMarkerPosition {
                drawTargetMarker(at: targetMarkerPosition, in: &context, projection: projection)
            }
            drawDrone(in: &context, projection: projection)

            context.stroke(
                Path(projection.mapRect),
                with: .color(GroundControlPalette.borderStrong),
                lineWidth: 1.2
            )
        }
        .task(id: TerrainMapBasemapStore.requestKey(for: snapshot)) {
            basemapStore.request(for: snapshot)
        }
    }

    private func drawMapBase(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let rect = projection.mapRect
        context.fill(Path(rect), with: .color(mapBackgroundColor.opacity(0.98)))

        context.fill(
            Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.55)),
            with: .color(Color.white.opacity(0.025))
        )
        context.fill(
            Path(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height * 0.5)),
            with: .color(Color.black.opacity(0.06))
        )
    }

    private var mapBackgroundColor: Color {
        switch snapshot.preset {
        case .city:
            return Color(red: 0.10, green: 0.12, blue: 0.15)
        case .cargoYard:
            return Color(red: 0.16, green: 0.15, blue: 0.13)
        case .forest:
            return Color(red: 0.10, green: 0.15, blue: 0.11)
        case .field:
            return Color(red: 0.13, green: 0.16, blue: 0.11)
        case .gridDemo:
            return GroundControlPalette.inset
        }
    }

    private func drawBasemap(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection,
        geographicImage: CGImage?
    ) {
        let texture = geographicImage
            ?? TerrainMapSatelliteTextureProvider.texture(for: snapshot.preset)
        let image = Image(decorative: texture, scale: 1.0, orientation: .up)
        let halfExtent = max(1.0, snapshot.worldHalfExtent)
        let worldRect = projection.projectedRect(
            origin: SIMD2<Float>(-halfExtent, -halfExtent),
            size: SIMD2<Float>(halfExtent * 2.0, halfExtent * 2.0)
        )
        context.draw(image, in: worldRect.integral.insetBy(dx: -0.5, dy: -0.5))
        context.fill(
            Path(projection.mapRect),
            with: .color(basemapColorGrade.opacity(basemapColorGradeOpacity))
        )
    }

    private var basemapColorGradeOpacity: Double {
        guard let reference = snapshot.geographicReference else {
            return 0.18
        }

        switch reference.style {
        case .standard:
            return 0.08
        case .satellite:
            return 0.13
        }
    }

    private var basemapColorGrade: Color {
        guard let reference = snapshot.geographicReference else {
            return satelliteColorGrade
        }

        switch reference.style {
        case .standard:
            return Color(red: 0.03, green: 0.08, blue: 0.12)
        case .satellite:
            return Color.black
        }
    }

    private var satelliteColorGrade: Color {
        switch snapshot.preset {
        case .city:
            return Color(red: 0.10, green: 0.11, blue: 0.10)
        case .cargoYard:
            return Color(red: 0.08, green: 0.09, blue: 0.09)
        case .forest:
            return Color(red: 0.03, green: 0.10, blue: 0.04)
        case .field:
            return Color(red: 0.06, green: 0.12, blue: 0.04)
        case .gridDemo:
            return Color(red: 0.05, green: 0.07, blue: 0.06)
        }
    }

    private func drawSceneTerrainDetails(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.preset == .field || snapshot.preset == .forest else {
            return
        }

        let coverageScale = max(1.0, snapshot.worldHalfExtent / 96.0)
        let detailScale = max(0.9, snapshot.mapScale.populationBudgetFactor * 0.58 + coverageScale * 0.42)
        let halfExtent = snapshot.worldHalfExtent * 0.92
        let isForest = snapshot.preset == .forest
        let primaryCount = isForest
            ? max(14, Int(12.0 + detailScale * 5.0))
            : max(5, Int(4.0 + detailScale * 1.8))
        let accentCount = isForest
            ? max(7, Int(5.0 + detailScale * 2.4))
            : max(2, Int(1.0 + detailScale * 0.8))
        let shadowCount = isForest
            ? max(8, Int(6.0 + detailScale * 2.2))
            : 0
        let seedOffset: UInt64 = isForest ? 0xF057 : 0xF13D
        var generator = TerrainMapTerrainDetailRandom(seed: snapshot.terrainSeed &+ seedOffset)

        for index in 0..<primaryCount {
            drawTerrainDetailPatch(
                width: Float.random(in: isForest ? 10.0...24.0 : 14.0...30.0, using: &generator),
                height: Float.random(in: isForest ? 8.0...20.0 : 10.0...22.0, using: &generator),
                halfExtent: halfExtent,
                color: index % 4 == 0 ? terrainAccentColor(isForest: isForest) : terrainPrimaryColor(isForest: isForest),
                projection: projection,
                generator: &generator,
                context: &context
            )
        }

        for _ in 0..<accentCount {
            drawTerrainDetailPatch(
                width: Float.random(in: 8.0...18.0, using: &generator),
                height: Float.random(in: 7.0...16.0, using: &generator),
                halfExtent: halfExtent,
                color: terrainAccentColor(isForest: isForest),
                projection: projection,
                generator: &generator,
                context: &context
            )
        }

        for _ in 0..<shadowCount {
            drawTerrainDetailPatch(
                width: Float.random(in: 5.0...11.0, using: &generator),
                height: Float.random(in: 4.0...10.0, using: &generator),
                halfExtent: halfExtent,
                color: Color.black.opacity(0.16),
                projection: projection,
                generator: &generator,
                context: &context
            )
        }
    }

    private func drawTerrainDetailPatch(
        width: Float,
        height: Float,
        halfExtent: Float,
        color: Color,
        projection: TerrainMapProjection,
        generator: inout TerrainMapTerrainDetailRandom,
        context: inout GraphicsContext
    ) {
        let position = SIMD2<Float>(
            Float.random(in: -halfExtent...halfExtent, using: &generator),
            Float.random(in: -halfExtent...halfExtent, using: &generator)
        )
        let rotation = CGFloat(Float.random(in: 0.0...(.pi * 2.0), using: &generator))
        let center = projection.project(position)
        let size = projection.projectedSize(for: SIMD2<Float>(width, height))
        let rect = CGRect(
            x: -size.width * 0.5,
            y: -size.height * 0.5,
            width: size.width,
            height: size.height
        )
        let path = Path(ellipseIn: rect)
            .applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation))
        context.fill(path, with: .color(color))
    }

    private func terrainPrimaryColor(isForest: Bool) -> Color {
        isForest
            ? Color(red: 0.18, green: 0.17, blue: 0.11).opacity(0.18)
            : Color(red: 0.45, green: 0.40, blue: 0.21).opacity(0.12)
    }

    private func terrainAccentColor(isForest: Bool) -> Color {
        isForest
            ? Color(red: 0.18, green: 0.24, blue: 0.12).opacity(0.15)
            : Color(red: 0.38, green: 0.44, blue: 0.20).opacity(0.10)
    }

    private func drawGrid(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let divisions = max(1, MapViewportState.tacticalSectorDivisions)
        let halfExtent = max(1.0, snapshot.worldHalfExtent)
        let sectorStep = (halfExtent * 2.0) / Float(divisions)
        let subdivisionCount = gridSubdivisionCount(for: sectorStep, projection: projection)
        let minorStep = sectorStep / Float(subdivisionCount)
        let lineCount = divisions * subdivisionCount
        var minorPath = Path()
        var majorPath = Path()

        for index in 0...lineCount {
            let worldCoordinate = -halfExtent + Float(index) * minorStep
            if index % subdivisionCount == 0 {
                appendGridLine(coordinate: worldCoordinate, halfExtent: halfExtent, to: &majorPath, projection: projection)
            } else {
                appendGridLine(coordinate: worldCoordinate, halfExtent: halfExtent, to: &minorPath, projection: projection)
            }
        }

        context.stroke(
            minorPath,
            with: .color(Color.white.opacity(0.075)),
            lineWidth: 0.5
        )
        context.stroke(
            majorPath,
            with: .color(Color.white.opacity(0.25)),
            lineWidth: 0.85
        )
    }

    private func appendGridLine(
        coordinate: Float,
        halfExtent: Float,
        to path: inout Path,
        projection: TerrainMapProjection
    ) {
        path.move(to: projection.project(SIMD2<Float>(coordinate, -halfExtent)))
        path.addLine(to: projection.project(SIMD2<Float>(coordinate, halfExtent)))
        path.move(to: projection.project(SIMD2<Float>(-halfExtent, coordinate)))
        path.addLine(to: projection.project(SIMD2<Float>(halfExtent, coordinate)))
    }

    private func gridSubdivisionCount(
        for sectorStep: Float,
        projection: TerrainMapProjection
    ) -> Int {
        let origin = projection.project(.zero)
        let next = projection.project(SIMD2<Float>(sectorStep, 0.0))
        let projectedStep = abs(next.x - origin.x)
        if projectedStep > 200.0 {
            return 4
        }
        if projectedStep > 110.0 {
            return 2
        }
        return 1
    }

    private func drawTrail(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.trail.count > 1 else {
            return
        }

        var trailPath = Path()
        trailPath.move(to: projection.project(snapshot.trail[0]))
        for point in snapshot.trail.dropFirst() {
            trailPath.addLine(to: projection.project(point))
        }

        context.stroke(
            trailPath,
            with: .color(GroundControlPalette.warning.opacity(0.64)),
            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawOperationalEnvelope(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(snapshot.dockPosition)
        drawRadius(snapshot.hardWorldBoundsRadius, color: GroundControlPalette.danger.opacity(0.36), style: StrokeStyle(lineWidth: 0.9, dash: [3, 6]), center: center, projection: projection, context: &context)
        drawRadius(snapshot.degradedLinkRadius, color: GroundControlPalette.warning.opacity(0.52), style: StrokeStyle(lineWidth: 1.0, dash: [5, 4]), center: center, projection: projection, context: &context)
        drawRadius(snapshot.linkQualityRadius, color: Color(red: 0.37, green: 0.73, blue: 0.96).opacity(0.78), style: StrokeStyle(lineWidth: 1.15, dash: [5, 4]), center: center, projection: projection, context: &context)
        drawRadius(snapshot.operationalRadius, color: GroundControlPalette.success.opacity(0.54), style: StrokeStyle(lineWidth: 1.0, dash: [2, 4]), center: center, projection: projection, context: &context)
    }

    private func drawRadius(
        _ radiusMeters: Float,
        color: Color,
        style: StrokeStyle,
        center: CGPoint,
        projection: TerrainMapProjection,
        context: inout GraphicsContext
    ) {
        guard radiusMeters > 0.01 else {
            return
        }
        let radius = projection.projectedRadius(for: radiusMeters)
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )

        context.stroke(
            Path(ellipseIn: rect),
            with: .color(color),
            style: style
        )
    }

    private func drawTargetLink(
        to targetMarker: SIMD2<Float>,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        var path = Path()
        path.move(to: projection.project(snapshot.dronePosition))
        path.addLine(to: projection.project(targetMarker))

        context.stroke(
            path,
            with: .color(GroundControlPalette.warning.opacity(0.82)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 3])
        )
    }

    private func drawMissionRoute(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.missionRoutePoints.count > 1 else {
            return
        }

        var routePath = Path()
        routePath.move(to: projection.project(snapshot.missionRoutePoints[0]))
        for point in snapshot.missionRoutePoints.dropFirst() {
            routePath.addLine(to: projection.project(point))
        }

        context.stroke(
            routePath,
            with: .color(GroundControlPalette.accent.opacity(0.78)),
            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawMissionWaypoints(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for waypoint in snapshot.missionWaypoints {
            let center = projection.project(waypoint.position)
            let tint: Color = {
                if waypoint.isCompleted {
                    return GroundControlPalette.success
                }
                if waypoint.isAssistSelected {
                    return GroundControlPalette.warning
                }
                if waypoint.isActive {
                    return GroundControlPalette.warning
                }
                return GroundControlPalette.accent
            }()
            let acceptanceRadius = projection.projectedRadius(for: waypoint.acceptanceRadius)
            let acceptanceRect = CGRect(
                x: center.x - acceptanceRadius,
                y: center.y - acceptanceRadius,
                width: acceptanceRadius * 2.0,
                height: acceptanceRadius * 2.0
            )
            context.fill(Path(ellipseIn: acceptanceRect), with: .color(tint.opacity(waypoint.isActive || waypoint.isAssistSelected ? 0.11 : 0.07)))
            context.stroke(
                Path(ellipseIn: acceptanceRect),
                with: .color(tint.opacity(waypoint.isActive || waypoint.isAssistSelected ? 0.9 : 0.58)),
                style: StrokeStyle(lineWidth: waypoint.isActive || waypoint.isAssistSelected ? 1.7 : 1.15, dash: [5.0, 3.0])
            )

            let rect = CGRect(x: center.x - 6.0, y: center.y - 6.0, width: 12.0, height: 12.0)
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.92)))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(0.40)),
                lineWidth: 0.8
            )

            if waypoint.isAssistSelected {
                let outerRingRect = rect.insetBy(dx: -4.5, dy: -4.5)
                context.stroke(
                    Path(ellipseIn: outerRingRect),
                    with: .color(GroundControlPalette.warning.opacity(0.94)),
                    lineWidth: 1.2
                )
            } else if waypoint.isActive {
                let ringRect = rect.insetBy(dx: -3.5, dy: -3.5)
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(GroundControlPalette.warning.opacity(0.88)),
                    lineWidth: 1.0
                )
            }

            context.draw(
                Text(waypoint.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white),
                at: CGPoint(x: center.x, y: center.y - 13.5),
                anchor: .center
            )
        }
    }

    private func drawActiveLeg(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.activeLegPoints.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: projection.project(snapshot.activeLegPoints[0]))
        for point in snapshot.activeLegPoints.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.warning.opacity(0.92)),
            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawPredictedPath(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.predictedPathPoints.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: projection.project(snapshot.predictedPathPoints[0]))
        for point in snapshot.predictedPathPoints.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.borderStrong.opacity(0.86)),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [4.0, 3.0])
        )
    }

    private func drawDropZone(
        _ dropZone: DropZoneState,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(dropZone.center)
        let radius = projection.projectedRadius(for: dropZone.radius)
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )

        context.fill(
            Path(ellipseIn: rect),
            with: .color(GroundControlPalette.warning.opacity(highlightDropZone ? 0.18 : 0.10))
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(highlightDropZone ? GroundControlPalette.danger : GroundControlPalette.warning),
            style: StrokeStyle(lineWidth: highlightDropZone ? 2.2 : 1.4, dash: [6, 4])
        )
    }

    private func drawObject(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(object.position)
        let size = projection.projectedSize(for: object.footprint)
        let rect = CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )

        switch object.kind {
        case .building:
            let path = Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous)
            context.fill(
                Path(roundedRect: rect.offsetBy(dx: 1.0, dy: 1.3), cornerRadius: 1.5, style: .continuous),
                with: .color(Color.black.opacity(0.30))
            )
            context.fill(path, with: .color(Color(red: 0.58, green: 0.60, blue: 0.56).opacity(0.76)))
            context.stroke(path, with: .color(Color.white.opacity(0.14)), lineWidth: 0.6)
        case .tree:
            drawMapTree(object, center: center, size: size, context: &context)
        case .rock:
            let rockRect = rect.insetBy(dx: -0.4, dy: 0.2)
            let path = Path(ellipseIn: rockRect)
            context.fill(path, with: .color(Color(red: 0.64, green: 0.66, blue: 0.68).opacity(0.70)))
            context.stroke(path, with: .color(Color.black.opacity(0.18)), lineWidth: 0.6)
        case .crate:
            let path = Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.68, green: 0.52, blue: 0.24).opacity(0.76)))
            context.stroke(path, with: .color(Color.black.opacity(0.22)), lineWidth: 0.6)
        case .cargoContainer:
            let path = Path(roundedRect: rect, cornerRadius: 1.2, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.72, green: 0.34, blue: 0.18).opacity(0.82)))
            context.stroke(path, with: .color(Color.black.opacity(0.30)), lineWidth: 0.8)
        case .pole:
            let poleRect = CGRect(
                x: center.x - 1.3,
                y: center.y - max(3.2, size.height * 0.5),
                width: 2.6,
                height: max(6.4, size.height)
            )
            let path = Path(roundedRect: poleRect, cornerRadius: 1.0, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.80, green: 0.67, blue: 0.28).opacity(0.84)))
        case .marker:
            var path = Path()
            path.move(to: CGPoint(x: center.x, y: center.y - size.height * 0.5))
            path.addLine(to: CGPoint(x: center.x + size.width * 0.5, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + size.height * 0.5))
            path.addLine(to: CGPoint(x: center.x - size.width * 0.5, y: center.y))
            path.closeSubpath()
            context.fill(path, with: .color(Color(red: 0.31, green: 0.73, blue: 0.86).opacity(0.80)))
            context.stroke(path, with: .color(Color.black.opacity(0.20)), lineWidth: 0.6)
        }
    }

    private func drawMapTree(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        center: CGPoint,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let isForest = snapshot.preset == .forest
        let width = max(isForest ? 5.5 : 3.0, size.width * (isForest ? 1.15 : 0.58))
        let height = max(isForest ? 5.0 : 3.0, size.height * (isForest ? 1.05 : 0.52))
        let baseRect = CGRect(
            x: center.x - width * 0.5,
            y: center.y - height * 0.5,
            width: width,
            height: height
        )
        let shadowRect = baseRect.offsetBy(
            dx: 0.8 + treeNoise(object, salt: 17.0) * 0.8,
            dy: 1.0 + treeNoise(object, salt: 31.0) * 0.8
        )
        context.fill(
            Path(ellipseIn: shadowRect),
            with: .color(Color.black.opacity(isForest ? 0.20 : 0.12))
        )
        context.fill(
            Path(ellipseIn: baseRect),
            with: .color(Color(red: 0.04, green: 0.13, blue: 0.05).opacity(isForest ? 0.42 : 0.22))
        )
    }

    private func treeNoise(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        salt: CGFloat
    ) -> CGFloat {
        let value = sin(
            CGFloat(object.position.x) * 12.9898
                + CGFloat(object.position.y) * 78.233
                + CGFloat(object.footprint.x) * 37.719
                + salt
        ) * 43758.5453
        return value - floor(value)
    }

    private func drawDock(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(snapshot.dockPosition)
        let dockRect = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
        let dockPath = Path(roundedRect: dockRect, cornerRadius: 1.5, style: .continuous)
        context.stroke(dockPath, with: .color(GroundControlPalette.warning), lineWidth: 1.4)

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - 8, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 8, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 8))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 8))
        context.stroke(crosshair, with: .color(GroundControlPalette.warning.opacity(0.82)), lineWidth: 1.0)
    }

    private func drawTargetMarker(
        at targetMarker: SIMD2<Float>,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(targetMarker)
        let outerRect = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
        let innerRect = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)

        context.stroke(Path(ellipseIn: outerRect), with: .color(GroundControlPalette.warning), lineWidth: 1.6)
        context.fill(Path(ellipseIn: innerRect), with: .color(GroundControlPalette.warning))

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - 10, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 10, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 10))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 10))
        context.stroke(crosshair, with: .color(GroundControlPalette.warning.opacity(0.78)), lineWidth: 1.0)
    }

    private func drawDrone(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(snapshot.dronePosition)
        let forward = projection.headingVector(forYawRadians: snapshot.droneYawRadians)
        // Keep the marker orientation consistent for every airframe.
        let markerForward = CGVector(dx: -forward.dx, dy: -forward.dy)
        let right = CGVector(dx: -markerForward.dy, dy: markerForward.dx)

        func point(_ origin: CGPoint, offset: CGVector, scale: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + offset.dx * scale, y: origin.y + offset.dy * scale)
        }

        let nose = point(center, offset: markerForward, scale: 10)
        let tail = point(center, offset: markerForward, scale: -5.5)
        let left = point(tail, offset: right, scale: 4.8)
        let rightPoint = point(tail, offset: right, scale: -4.8)

        var dronePath = Path()
        dronePath.move(to: nose)
        dronePath.addLine(to: left)
        dronePath.addLine(to: center)
        dronePath.addLine(to: rightPoint)
        dronePath.closeSubpath()

        context.fill(dronePath, with: .color(GroundControlPalette.danger))
        context.stroke(dronePath, with: .color(Color.white.opacity(0.36)), lineWidth: 0.9)

        let bodyRect = CGRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)
        context.fill(Path(ellipseIn: bodyRect), with: .color(Color.white.opacity(0.92)))
    }
}

struct TerrainMapProjection {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let size: CGSize
    let zoomFactor: CGFloat
    let panOffset: CGSize
    let fillsAvailableSpace: Bool
    // Imported worlds are georeferenced: +X is east and +Z is north. Keeping north at the
    // top makes the satellite/standard basemap, overlays, mini-map and tap conversion share
    // one orientation instead of silently mirroring the real city. Procedural presets retain
    // their established operator-facing orientation because they have no real north.
    private var transform: TerrainMapTransform {
        snapshot.geographicReference == nil
            ? .mirroredHorizontally
            : .defaultNorthUp
    }

    init(
        snapshot: DroneSimulationViewModel.TerrainMapSnapshot,
        size: CGSize,
        zoomFactor: CGFloat = 1.0,
        panOffset: CGSize = .zero,
        fillsAvailableSpace: Bool = false
    ) {
        self.snapshot = snapshot
        self.size = size
        self.zoomFactor = min(6.0, max(1.0, zoomFactor))
        self.panOffset = panOffset
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    var outerRect: CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
    }

    var mapRect: CGRect {
        guard !fillsAvailableSpace else {
            return outerRect
        }

        let side = min(outerRect.width, outerRect.height)
        return CGRect(
            x: outerRect.midX - side * 0.5,
            y: outerRect.midY - side * 0.5,
            width: side,
            height: side
        )
    }

    func project(_ point: SIMD2<Float>) -> CGPoint {
        CGPoint(
            x: projectionCenter.x + CGFloat(point.x) * xScale * transform.xAxisSign,
            y: projectionCenter.y + CGFloat(point.y) * yScale * transform.yAxisSign
        )
    }

    func unproject(_ point: CGPoint) -> SIMD2<Float>? {
        guard mapRect.contains(point) else {
            return nil
        }

        guard xScale > 0.0001, yScale > 0.0001 else {
            return nil
        }

        return SIMD2<Float>(
            Float((point.x - projectionCenter.x) / (xScale * transform.xAxisSign)),
            Float((point.y - projectionCenter.y) / (yScale * transform.yAxisSign))
        )
    }

    func projectedSize(for footprint: SIMD2<Float>) -> CGSize {
        return CGSize(
            width: max(3.0, CGFloat(footprint.x) * xScale),
            height: max(3.0, CGFloat(footprint.y) * yScale)
        )
    }

    func projectedRadius(for radius: Float) -> CGFloat {
        max(6.0, CGFloat(radius) * min(xScale, yScale))
    }

    func projectedRadiusSize(for radius: Float) -> CGSize {
        CGSize(
            width: max(6.0, CGFloat(radius) * xScale),
            height: max(6.0, CGFloat(radius) * yScale)
        )
    }

    func headingVector(forYawRadians yawRadians: Float) -> CGVector {
        transform.headingVector(
            yawRadians: yawRadians,
            projection: self
        )
    }

    private var projectionCenter: CGPoint {
        CGPoint(
            x: mapRect.midX + panOffset.width,
            y: mapRect.midY + panOffset.height
        )
    }

    private var projectedExtent: CGFloat {
        CGFloat(max(1.0, snapshot.worldHalfExtent / Float(zoomFactor)))
    }

    private var xScale: CGFloat {
        projectionScale
    }

    private var yScale: CGFloat {
        projectionScale
    }

    private var projectionScale: CGFloat {
        let fillDimension = fillsAvailableSpace
            ? max(mapRect.width, mapRect.height)
            : min(mapRect.width, mapRect.height)
        return fillDimension / max(1.0, projectedExtent * 2.0)
    }
}

private struct TerrainMapTransform {
    var xAxisSign: CGFloat
    var yAxisSign: CGFloat

    static let defaultNorthUp = TerrainMapTransform(xAxisSign: 1.0, yAxisSign: -1.0)
    static let rotated180 = TerrainMapTransform(xAxisSign: -1.0, yAxisSign: 1.0)
    static let mirroredHorizontally = TerrainMapTransform(xAxisSign: 1.0, yAxisSign: 1.0)

    func project(
        _ point: SIMD2<Float>,
        mapRect: CGRect,
        scale: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: mapRect.midX + CGFloat(point.x) * scale * xAxisSign,
            y: mapRect.midY + CGFloat(point.y) * scale * yAxisSign
        )
    }

    func unproject(
        _ point: CGPoint,
        mapRect: CGRect,
        scale: CGFloat
    ) -> SIMD2<Float> {
        SIMD2<Float>(
            Float((point.x - mapRect.midX) / (scale * xAxisSign)),
            Float((point.y - mapRect.midY) / (scale * yAxisSign))
        )
    }

    func headingVector(
        yawRadians: Float,
        projection: TerrainMapProjection
    ) -> CGVector {
        let origin = projection.project(SIMD2<Float>(repeating: 0.0))
        let forwardWorld = SIMD2<Float>(
            sin(yawRadians),
            cos(yawRadians)
        )
        let tip = projection.project(forwardWorld)
        let delta = CGVector(
            dx: tip.x - origin.x,
            dy: tip.y - origin.y
        )
        let length = sqrt(delta.dx * delta.dx + delta.dy * delta.dy)
        guard length > 0.0001 else {
            return CGVector(dx: 0.0, dy: -1.0)
        }
        return CGVector(dx: delta.dx / length, dy: delta.dy / length)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// MARK: – FPV camera "digital viewfinder" OSD

/// On-screen display for the aircraft-mounted camera view (`CameraMode.fpv`), styled after a real
/// drone/goggle DVR overlay — thin monochrome glyphs painted straight onto the live feed — rather
/// than the sim's dark-panel instrument HUD (`CompactTelemetryHUDView`/`CompassOverlayView`), which
/// `SceneViewportView.body` suppresses while this is up so the feed reads like a camera feed. The
/// only non-white accents are functional and standard for real OSDs: a low-battery tint and the red
/// record dot. Purely presentational; hit-testing is disabled by the caller.
struct FPVViewportOverlayView: View {
    let telemetry: TelemetrySnapshot
    let flightControlMode: FlightControlMode
    @ObservedObject var compass: CompassViewModel
    let leftStick: CGPoint
    let rightStick: CGPoint
    let isRecording: Bool

    private var altitudeText: String { String(format: "%.0f", max(0.0, telemetry.y)) }
    private var speedText: String { String(format: "%.1f", max(0.0, telemetry.speed)) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                FPVReticleView()
                FPVHorizonLine(rollDegrees: telemetry.roll, pitchDegrees: telemetry.pitch)

                // Top-left — flight mode + battery.
                VStack(alignment: .leading, spacing: 9) {
                    FPVModeBadge(mode: flightControlMode)
                    FPVBatteryGauge(percent: telemetry.batteryPercent, voltage: telemetry.batteryVoltage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 22)
                .padding(.top, 18)

                // Top-right — altitude + ground speed.
                VStack(alignment: .trailing, spacing: 10) {
                    FPVReadout(label: localized("hud.fpv.metric.altitude"), unit: localized("hud.fpv.unit.altitude"), value: altitudeText)
                    FPVReadout(label: localized("hud.fpv.metric.speed"), unit: localized("hud.fpv.unit.speed"), value: speedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 22)
                .padding(.top, 18)

                // Top-center — heading tape.
                FPVCompassStrip(headingDegrees: compass.headingDegrees)
                    .frame(width: min(max(geo.size.width * 0.42, 240.0), 380.0), height: 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)

                // Bottom-center — transmitter sticks.
                HStack(spacing: 10) {
                    FPVStickIndicator(position: leftStick)
                    FPVStickIndicator(position: rightStick)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)

                // Bottom-left — DVR record tag.
                FPVRecordingTag(isRecording: isRecording)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 20)
                    .padding(.bottom, 20)
            }
            .shadow(color: Color.black.opacity(0.5), radius: 1.5, x: 0, y: 1)
        }
    }
}

private struct FPVModeBadge: View {
    let mode: FlightControlMode

    private var codeKey: String {
        switch mode {
        case .acro: return "hud.fpv.mode.acro"
        case .stabilized: return "hud.fpv.mode.angle"
        case .hoverAssist: return "hud.fpv.mode.hover_assist"
        }
    }

    var body: some View {
        Text(LocalizedStringKey(codeKey))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 1.4)
            )
    }
}

private struct FPVBatteryGauge: View {
    let percent: Double
    let voltage: Double

    private var fraction: CGFloat { CGFloat(min(max(percent / 100.0, 0.0), 1.0)) }

    private var tint: Color {
        switch percent {
        case ..<15.0: return Color(red: 0.95, green: 0.30, blue: 0.24)
        case ..<35.0: return Color(red: 0.95, green: 0.70, blue: 0.26)
        default: return .white.opacity(0.95)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(.white.opacity(0.85), lineWidth: 1.3)
                        .frame(width: 34, height: 16)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint)
                        .frame(width: max(2.0, 28.0 * fraction), height: 10)
                        .padding(.leading, 3)
                }
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 3, height: 7)
            }
            Text(String(format: "%.0f%%", max(0.0, percent)))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            if voltage > 0.1 {
                Text(String(format: "%.1fV", voltage))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

private struct FPVReadout: View {
    let label: String
    let unit: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: -1) {
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .textCase(.uppercase)
                Text(unit)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .frame(minWidth: 46, alignment: .trailing)
        }
        .foregroundStyle(.white.opacity(0.95))
    }
}

private struct FPVCompassStrip: View {
    let headingDegrees: Double

    /// Scrolling ticker matching the reference OSD: a wide (~240°) window so 3–4 cardinal letters
    /// are in view at once and visibly slide as `headingDegrees` changes, with dot ticks marking
    /// the 30°/60° steps in between — cardinal-only labels (no intercardinals), like the reference.
    private static let visibleSpanDegrees = 240.0
    private static let tickStepDegrees = 30.0

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let centerX = rect.midX
            let baselineY = rect.maxY - 7.0
            let pixelsPerDegree = rect.width / Self.visibleSpanDegrees

            let halfSpan = Self.visibleSpanDegrees / 2.0
            let start = (headingDegrees / Self.tickStepDegrees).rounded(.down) * Self.tickStepDegrees - halfSpan
            stride(from: start, through: start + Self.visibleSpanDegrees, by: Self.tickStepDegrees).forEach { absolute in
                let value = fpvNormalizedHeading(absolute)
                let delta = fpvShortestHeadingDelta(from: headingDegrees, to: value)
                let x = centerX + delta * pixelsPerDegree
                guard x >= rect.minX - 10, x <= rect.maxX + 10 else { return }

                if let label = fpvCardinalLabel(value) {
                    context.draw(
                        Text(label)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(value == 0.0 ? 1.0 : 0.82)),
                        at: CGPoint(x: x, y: baselineY - 6),
                        anchor: .center
                    )
                } else {
                    let dot = Path(ellipseIn: CGRect(x: x - 1.0, y: baselineY - 8.0, width: 2.0, height: 2.0))
                    context.fill(dot, with: .color(.white.opacity(0.55)))
                }
            }

            var caret = Path()
            caret.move(to: CGPoint(x: centerX, y: baselineY + 2))
            caret.addLine(to: CGPoint(x: centerX - 4, y: baselineY + 9))
            caret.addLine(to: CGPoint(x: centerX + 4, y: baselineY + 9))
            caret.closeSubpath()
            context.fill(caret, with: .color(.white.opacity(0.95)))
        }
    }
}

/// Center gunsight reticle plus the dotted viewfinder rails (two static vertical dashes framing
/// the shot), echoing the reference OSD's bracket look. Purely decorative/fixed — the reference's
/// actual *dynamic* center element is the roll/pitch tick-line drawn separately by
/// `FPVHorizonLine`, not these rails.
private struct FPVReticleView: View {
    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2.0
            let cy = size.height / 2.0
            let shading = GraphicsContext.Shading.color(.white.opacity(0.85))
            let dashed = StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1.6, 5.0])

            let railHalf = min(size.height * 0.26, 260.0)
            let railX = min(size.width * 0.20, 340.0)
            let railTop = cy - railHalf
            let railBot = cy + railHalf

            for x in [cx - railX, cx + railX] {
                var rail = Path()
                rail.move(to: CGPoint(x: x, y: railTop))
                rail.addLine(to: CGPoint(x: x, y: railBot))
                context.stroke(rail, with: shading, style: dashed)
            }

            // Center gunsight: ring + four short radial ticks + a center dot.
            let ring = 9.0
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - ring, y: cy - ring, width: ring * 2, height: ring * 2)),
                with: shading,
                lineWidth: 1.4
            )
            let tickInner = ring + 2.0
            let tickOuter = ring + 7.0
            for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
                var tick = Path()
                tick.move(to: CGPoint(x: cx + dx * tickInner, y: cy + dy * tickInner))
                tick.addLine(to: CGPoint(x: cx + dx * tickOuter, y: cy + dy * tickOuter))
                context.stroke(tick, with: shading, lineWidth: 1.4)
            }
            context.fill(
                Path(ellipseIn: CGRect(x: cx - 1.5, y: cy - 1.5, width: 3.0, height: 3.0)),
                with: .color(.white.opacity(0.95))
            )
        }
    }
}

/// The reference OSD's actual dynamic center element: a short dotted tick-line through the
/// reticle that behaves like a minimal artificial horizon — it rotates with bank angle and
/// shifts vertically with pitch, exactly like `AttitudeDirectorView`'s horizon in the PFD
/// (`CompassOverlayView.swift`), just rendered as a plain tick-line instead of a filled sky/ground
/// split. Unlike the static rails/gunsight in `FPVReticleView`, this one genuinely moves every
/// frame as the aircraft maneuvers.
private struct FPVHorizonLine: View {
    let rollDegrees: Double
    let pitchDegrees: Double

    private var boundedRoll: Double {
        let value = rollDegrees.isFinite ? rollDegrees : 0.0
        return min(max(value, -60.0), 60.0)
    }

    private var boundedPitch: Double {
        let value = pitchDegrees.isFinite ? pitchDegrees : 0.0
        return min(max(value, -35.0), 35.0)
    }

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2.0
            let cy = size.height / 2.0
            let halfLength = min(size.width * 0.10, 150.0)
            let pitchPixelsPerDegree = 2.4

            var world = context
            world.translateBy(x: cx, y: cy)
            world.rotate(by: .degrees(-boundedRoll))
            world.translateBy(x: -cx, y: -cy)

            let lineY = cy + boundedPitch * pitchPixelsPerDegree
            let dashed = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.6, 5.0])
            var line = Path()
            line.move(to: CGPoint(x: cx - halfLength, y: lineY))
            line.addLine(to: CGPoint(x: cx + halfLength, y: lineY))
            world.stroke(line, with: .color(.white.opacity(0.85)), style: dashed)
        }
    }
}

private struct FPVStickIndicator: View {
    let position: CGPoint   // −1...1 per axis, y = +1 at top

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.0, dy: 1.0)
            let panel = Path(roundedRect: rect, cornerRadius: 3.0)
            context.fill(panel, with: .color(.black.opacity(0.32)))
            context.stroke(
                panel,
                with: .color(.white.opacity(0.7)),
                lineWidth: 1.0
            )

            let dashed = StrokeStyle(lineWidth: 1.0, dash: [2.0, 3.0])
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: rect.minX + 3, y: rect.midY))
            horizontal.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
            context.stroke(horizontal, with: .color(.white.opacity(0.34)), style: dashed)
            var vertical = Path()
            vertical.move(to: CGPoint(x: rect.midX, y: rect.minY + 3))
            vertical.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3))
            context.stroke(vertical, with: .color(.white.opacity(0.34)), style: dashed)

            let clampedX = min(max(position.x, -1.0), 1.0)
            let clampedY = min(max(position.y, -1.0), 1.0)
            let px = rect.midX + CGFloat(clampedX) * (rect.width / 2.0 - 5.0)
            let py = rect.midY - CGFloat(clampedY) * (rect.height / 2.0 - 5.0)
            let dot = 5.0
            context.stroke(
                Path(ellipseIn: CGRect(x: px - dot, y: py - dot, width: dot * 2, height: dot * 2)),
                with: .color(.white.opacity(0.95)),
                lineWidth: 1.4
            )
        }
        .frame(width: 58, height: 42)
    }
}

private struct FPVRecordingTag: View {
    let isRecording: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { timeline in
            let blinkOn = Int(timeline.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            HStack(spacing: 6) {
                Circle()
                    .fill(isRecording ? Color(red: 0.95, green: 0.24, blue: 0.20) : .white.opacity(0.45))
                    .frame(width: 9, height: 9)
                    .opacity(isRecording ? (blinkOn ? 1.0 : 0.25) : 0.55)
                Text(LocalizedStringKey(isRecording ? "hud.fpv.recording" : "hud.fpv.standby"))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

private func fpvNormalizedHeading(_ value: Double) -> Double {
    let wrapped = value.truncatingRemainder(dividingBy: 360.0)
    return wrapped >= 0.0 ? wrapped : wrapped + 360.0
}

private func fpvShortestHeadingDelta(from source: Double, to target: Double) -> CGFloat {
    let raw = (fpvNormalizedHeading(target) - fpvNormalizedHeading(source)).truncatingRemainder(dividingBy: 360.0)
    if raw > 180.0 { return CGFloat(raw - 360.0) }
    if raw < -180.0 { return CGFloat(raw + 360.0) }
    return CGFloat(raw)
}

private func fpvCardinalLabel(_ heading: Double) -> String? {
    switch Int(fpvNormalizedHeading(heading).rounded()) {
    case 0, 360: return localized("overlay.compass.metric.north")
    case 90: return localized("overlay.compass.metric.east")
    case 180: return localized("overlay.compass.metric.south")
    case 270: return localized("overlay.compass.metric.west")
    default: return nil
    }
}
