import SwiftUI

/// The interception mission's controls: which feed the operator is watching, whether an approach
/// is being flown deliberately, and how to start the run over.
///
/// A panel rather than part of `MissionScenarioHUDView`, for the same reason the race builder is
/// one: the scenario HUD is drawn over the viewport with hit testing off so it cannot swallow a
/// mouse-look drag, and a control nobody can click is worse than no control at all.
struct InterceptMissionPanelView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private var state: InterceptMissionHUDState { viewModel.interceptHUD }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourceRow
            approachRow
            hint
        }
        .padding(14)
        .frame(width: 260)
        .background(GroundControlPalette.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(GroundControlPalette.accent)
            Text("intercept.panel.title")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: - Observation source

    /// Selecting a source never moves an aircraft — it only changes which existing camera the
    /// operator is looking through. A source with no usable picture is offered as unavailable
    /// rather than silently doing nothing.
    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("intercept.panel.source")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 6) {
                sourceButton(InterceptCallsign.attacker, isEnabled: true)
                sourceButton(InterceptCallsign.observer, isEnabled: state.observerAvailable)
            }
        }
    }

    private func sourceButton(_ callsign: String, isEnabled: Bool) -> some View {
        let isActive = state.sourceID == callsign
        return Button {
            viewModel.selectInterceptObservation(callsign)
        } label: {
            Text(callsign)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(isActive ? .white : .white.opacity(isEnabled ? 0.7 : 0.3))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? GroundControlPalette.accent.opacity(0.35) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isActive ? GroundControlPalette.accent : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Approach

    private var approachRow: some View {
        VStack(spacing: 6) {
            if state.result == nil {
                if state.phase == .attackRun {
                    actionButton("intercept.abort", tint: GroundControlPalette.warning, isEnabled: true) {
                        viewModel.abortInterceptAttempt()
                    }
                } else {
                    actionButton("intercept.begin", tint: GroundControlPalette.accent, isEnabled: state.canAttempt) {
                        viewModel.beginInterceptAttempt()
                    }
                }
            }
            actionButton("intercept.restart", tint: GroundControlPalette.textSecondary, isEnabled: true) {
                viewModel.restartInterceptMission()
            }
        }
    }

    private func actionButton(
        _ titleKey: String,
        tint: Color,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(isEnabled ? 0.28 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var hint: some View {
        Text("intercept.panel.hint")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}


/// What the operator sees on the feed itself as the link goes.
///
/// The stage plan is explicit that this has to read as a video system, not as a cut. The
/// degradation and the freeze are drawn by the RF video processor on the picture; what is left
/// for this view is the caption over it — a receiver's status panel with the numbers the operator
/// would actually judge the link by, and the way across to the other camera.
///
/// Instrument colours, not alarm colours: this is a downlink reporting its own state, and painting
/// it red says "you are about to crash" rather than "the picture is gone".
struct InterceptFeedOverlayView: View {
    let state: InterceptMissionHUDState
    let isFeedCamera: Bool
    let onSelectObserver: () -> Void

    /// A lost picture is a statement of fact, not an alarm: plain instrument grey. Amber is kept
    /// for the caution that the link is still *going*, which is the one the operator can still act
    /// on, and red is reserved for losing the aircraft itself.
    private static let lostTint = Color.white.opacity(0.82)
    private static let cautionTint = GroundControlPalette.warning

    var body: some View {
        if isFeedCamera {
            switch state.observationPhase {
            case .attackerLinkDegrading:
                degradingBadge
            case .noSignal, .unavailable:
                lostPanel
            case .observationHandoff:
                handoffPanel
            case .watchingObserver:
                observerFrame
            case .watchingAttacker:
                EmptyView()
            }
        }
    }

    // MARK: - Degrading

    /// A corner caution, not a full-screen card: the picture is still usable, and covering it
    /// while the operator is still flying on it would be worse than the interference.
    private var degradingBadge: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("intercept.feed.degrading")
                        .font(.caption2.weight(.bold))
                    linkReadout
                }
                .foregroundStyle(Self.cautionTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(Self.cautionTint.opacity(0.45), lineWidth: 1))
                .padding(.trailing, 18)
                .padding(.top, 74)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Lost

    private var lostPanel: some View {
        panel {
            VStack(spacing: 10) {
                statusLine(icon: "video.slash.fill", titleKey: "intercept.feed.no_image", tint: Self.lostTint, pulses: false)
                Text(String(
                    format: NSLocalizedString("intercept.feed.lost_from", comment: ""),
                    state.sourceID
                ))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                linkReadout

                if state.observerAvailable, !state.isObservingObserver {
                    Button(action: onSelectObserver) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 11, weight: .semibold))
                            Text(String(
                                format: NSLocalizedString("intercept.feed.switch_to", comment: ""),
                                InterceptCallsign.observer
                            ))
                            .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(GroundControlPalette.accent.opacity(0.85))
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("intercept.feed.no_observer")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
            }
        }
    }

    // MARK: - Handoff

    private var handoffPanel: some View {
        panel {
            VStack(spacing: 8) {
                statusLine(icon: "arrow.triangle.swap", titleKey: "intercept.feed.handoff", tint: Self.lostTint, pulses: false)
                Text(String(
                    format: NSLocalizedString("intercept.feed.handoff_to", comment: ""),
                    InterceptCallsign.observer
                ))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    // MARK: - Observer feed

    /// An observation downlink from another aircraft, framed as one: corner brackets, the source
    /// and what it is looking at, and a gimbal cross where the camera is pointed. Deliberately not
    /// the pilot's FPV overlay — nobody is flying this aircraft, so an artificial horizon and a
    /// throttle readout would be describing a machine the operator has no stick on.
    private var observerFrame: some View {
        ZStack {
            CornerBrackets()
                .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                .padding(28)

            GimbalCross()
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                .frame(width: 46, height: 46)

            VStack {
                HStack(spacing: 10) {
                    Text("intercept.feed.observer_title")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                    Text(state.sourceID)
                        .font(.caption.weight(.bold).monospaced())
                    Spacer()
                    Text(LocalizedStringKey(
                        state.sourceHasTargetInView
                            ? "intercept.feed.tracking"
                            : "intercept.feed.searching"
                    ))
                    .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 34)
                .padding(.top, 34)

                Spacer()

                HStack(spacing: 18) {
                    if !state.hidesRanges {
                        readout(String(format: NSLocalizedString("intercept.feed.altitude", comment: ""), Double(state.sourceAltitude)))
                        readout(String(format: NSLocalizedString("intercept.feed.range", comment: ""), Double(state.sourceToTargetRange)))
                    }
                    Spacer()
                    readout(String(format: "%@ %@", InterceptCallsign.target, NSLocalizedString(state.targetState.targetTitleKey, comment: "")))
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 34)
            }
        }
        .allowsHitTesting(false)
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
    }

    // MARK: - Pieces

    /// A dark instrument panel in the same register as the rest of the sim's HUD. Deliberately not
    /// a big red word on the sky.
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(GroundControlPalette.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }

    private func statusLine(icon: String, titleKey: String, tint: Color, pulses: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { timeline in
            let beat = 0.62 + abs(sin(timeline.date.timeIntervalSinceReferenceDate * 3.0)) * 0.38
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(titleKey))
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(2)
            }
            .foregroundStyle(tint)
            .opacity(pulses ? beat : 1)
        }
    }

    private var linkReadout: some View {
        HStack(spacing: 10) {
            Text(state.sourceRSSIDBm.map { String(format: "RSSI %.0f dBm", $0) } ?? "RSSI ---")
            Text(state.sourceLinkQuality.map { "LQ \($0)%" } ?? "LQ ---")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
    }
}

/// Four corner brackets, the way a surveillance downlink frames its picture.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.08
        var path = Path()
        for corner in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                       (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            let (x, y, dx, dy) = corner
            path.move(to: CGPoint(x: x + length * dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + length * dy))
        }
        return path
    }
}

/// Where the observer's gimbal is aimed. Open in the middle so it never hides the thing it marks.
private struct GimbalCross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let gap = rect.width * 0.24
        path.move(to: CGPoint(x: rect.midX - rect.width / 2, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX - gap, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX + gap, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width / 2, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - rect.height / 2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY - gap))
        path.move(to: CGPoint(x: rect.midX, y: rect.midY + gap))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + rect.height / 2))
        return path
    }
}
