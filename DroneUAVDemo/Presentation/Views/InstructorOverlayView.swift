import SwiftUI

struct InstructorTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func instructorTarget(_ id: String) -> some View {
        anchorPreference(key: InstructorTargetPreferenceKey.self, value: .bounds) { [id: $0] }
            .id(id)
    }
}

/// Placement and leader geometry are independent of animation and flight telemetry.
enum InstructorOverlayLayout {
    static func frame(size: CGSize, canvas: CGSize, viewport: CGRect? = nil,
                      target: CGRect? = nil, hero: Bool = false, trailing: Bool = false) -> CGRect {
        let bounds = CGRect(x: 20, y: 20, width: max(1, canvas.width - 40), height: max(1, canvas.height - 40))
        let clipped = (viewport ?? bounds).intersection(bounds)
        let area = clipped.isNull || clipped.isEmpty ? bounds : clipped
        let width = min(size.width, max(1, area.width - 24))
        let height = min(size.height, bounds.height)
        var x = hero ? area.midX - width / 2 : trailing ? area.maxX - width - 12 : area.minX + 12
        var y = hero ? area.midY - height / 2 : area.maxY - height - 16
        if !hero, let target {
            if target.maxX <= area.minX + 24 {
                x = area.minX + 12
                // Keep the viewport's upper-left instrument cluster readable during actions.
                y = max(target.midY - height * 0.3, area.minY + 128)
            } else {
                let candidates = [
                    CGRect(x: target.maxX + 34, y: target.midY - height / 2, width: width, height: height),
                    CGRect(x: target.minX - width - 34, y: target.midY - height / 2, width: width, height: height),
                    CGRect(x: target.midX - width / 2, y: target.maxY + 32, width: width, height: height),
                    CGRect(x: target.midX - width / 2, y: target.minY - height - 32, width: width, height: height)
                ]
                let clamped = candidates.map { candidate in
                    CGRect(x: min(bounds.maxX - width, max(bounds.minX, candidate.minX)),
                           y: min(bounds.maxY - height, max(bounds.minY, candidate.minY)), width: width, height: height)
                }
                if let candidate = clamped.first(where: { !$0.intersects(target.insetBy(dx: -8, dy: -8)) }) {
                    x = candidate.minX; y = candidate.minY
                }
            }
        }
        x = min(bounds.maxX - width, max(bounds.minX, x))
        y = min(bounds.maxY - height, max(bounds.minY, y))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func connector(card: CGRect, target: CGRect) -> (start: CGPoint, end: CGPoint) {
        if card.minX >= target.maxX {
            return (CGPoint(x: card.minX - 3, y: min(card.maxY - 24, max(card.minY + 24, target.midY))),
                    CGPoint(x: target.maxX + 7, y: target.midY))
        }
        if card.maxX <= target.minX {
            return (CGPoint(x: card.maxX + 3, y: min(card.maxY - 24, max(card.minY + 24, target.midY))),
                    CGPoint(x: target.minX - 7, y: target.midY))
        }
        if card.minY >= target.maxY {
            return (CGPoint(x: min(card.maxX - 24, max(card.minX + 24, target.midX)), y: card.minY - 3),
                    CGPoint(x: target.midX, y: target.maxY + 7))
        }
        return (CGPoint(x: min(card.maxX - 24, max(card.minX + 24, target.midX)), y: card.maxY + 3),
                CGPoint(x: target.midX, y: target.minY - 7))
    }
}

private struct InstructorCardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct InstructorCardAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// Entrance motion is finite, keyed to a lesson/phase, never to a simulation tick.
private struct InstructorEntrance: ViewModifier {
    let enabled: Bool
    var horizontal = false
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || !enabled || reduceMotion
        content.opacity(visible ? 1 : 0)
            .offset(x: horizontal && !visible ? -Motion.rise : 0, y: !horizontal && !visible ? Motion.rise : 0)
            .onAppear {
                guard enabled, !reduceMotion else { shown = true; return }
                withAnimation(Motion.panel.delay(delay)) { shown = true }
            }
    }
}

private struct InstructorSpotlight: View {
    let rect: CGRect?
    var dimBackground = false

    var body: some View {
        GeometryReader { geometry in
            if dimBackground {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    if let rect { path.addRoundedRect(in: rect.insetBy(dx: -8, dy: -8), cornerSize: CGSize(width: 14, height: 14)) }
                }.fill(Color.black.opacity(0.66), style: FillStyle(eoFill: true))
            }
            if let rect {
                RoundedRectangle(cornerRadius: 12).fill(GroundControlPalette.accent.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(GroundControlPalette.accent.opacity(0.35), lineWidth: 1))
                    .frame(width: rect.width + 12, height: rect.height + 12)
                    .position(x: rect.midX, y: rect.midY)
                FocusCorners().stroke(GroundControlPalette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: rect.width + 18, height: rect.height + 18)
                    .position(x: rect.midX, y: rect.midY)
            }
        }.allowsHitTesting(false)
    }
}

private struct FocusCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(18, min(rect.width, rect.height) / 3)
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, CGFloat(1), CGFloat(1)),
                              (rect.maxX, rect.minY, CGFloat(-1), CGFloat(1)),
                              (rect.minX, rect.maxY, CGFloat(1), CGFloat(-1)),
                              (rect.maxX, rect.maxY, CGFloat(-1), CGFloat(-1))] {
            path.move(to: CGPoint(x: x, y: y + length * dy))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length * dx, y: y))
        }
        return path
    }
}

private struct InstructorLeader: View {
    let card: CGRect
    let target: CGRect
    let animateEntrance: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    var body: some View {
        let points = InstructorOverlayLayout.connector(card: card, target: target)
        let progress: CGFloat = animateEntrance && !reduceMotion ? drawn : 1
        ZStack(alignment: .topLeading) {
            leader(from: points.start, to: points.end).trim(from: 0, to: progress)
                .stroke(GroundControlPalette.accent.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            arrow(at: points.end, from: points.start).fill(GroundControlPalette.accent)
                .opacity(Double(progress))
        }
        .allowsHitTesting(false)
        .onAppear {
            guard animateEntrance, !reduceMotion else { drawn = 1; return }
            withAnimation(Motion.panel.delay(Motion.cascadeStep)) { drawn = 1 }
        }
    }

    private func leader(from start: CGPoint, to end: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            if card.minX >= target.maxX || card.maxX <= target.minX {
                let gutter = card.minX >= target.maxX
                    ? min(start.x - 10, target.maxX + 16)
                    : max(start.x + 10, target.minX - 16)
                // Route through the empty gutter between the sidebar and the viewport. A direct
                // diagonal crosses the neighbouring command row and makes the pointer look as if
                // it belongs to a different button while the sidebar scrolls.
                path.addLine(to: CGPoint(x: gutter, y: start.y))
                path.addCurve(to: CGPoint(x: gutter, y: end.y),
                              control1: CGPoint(x: gutter, y: start.y + (end.y - start.y) * 0.45),
                              control2: CGPoint(x: gutter, y: end.y - (end.y - start.y) * 0.25))
                path.addLine(to: end)
            } else {
                let gutter = card.minY >= target.maxY
                    ? min(start.y - 10, target.maxY + 16)
                    : max(start.y + 10, target.minY - 16)
                path.addLine(to: CGPoint(x: start.x, y: gutter))
                path.addCurve(to: CGPoint(x: end.x, y: gutter),
                              control1: CGPoint(x: start.x + (end.x - start.x) * 0.45, y: gutter),
                              control2: CGPoint(x: end.x - (end.x - start.x) * 0.25, y: gutter))
                path.addLine(to: end)
            }
        }
    }

    private func arrow(at tip: CGPoint, from start: CGPoint) -> Path {
        let direction: CGPoint
        if card.minX >= target.maxX { direction = CGPoint(x: -1, y: 0) }
        else if card.maxX <= target.minX { direction = CGPoint(x: 1, y: 0) }
        else { direction = CGPoint(x: 0, y: card.minY >= target.maxY ? -1 : 1) }
        let base = CGPoint(x: tip.x - direction.x * 9, y: tip.y - direction.y * 9)
        return Path { path in
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x - direction.y * 4.5, y: base.y + direction.x * 4.5))
            path.addLine(to: CGPoint(x: base.x + direction.y * 4.5, y: base.y - direction.x * 4.5))
            path.closeSubpath()
        }
    }
}

struct InstructorProgressBar: View {
    let value: Double
    var color = GroundControlPalette.accent
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: geometry.size.width * CGFloat(min(1, max(0, value))))
            }
        }.frame(height: 4)
            .accessibilityLabel(Text("instructor.progress"))
            .accessibilityValue(Text("\(Int(min(1, max(0, value)) * 100))%"))
    }
}

struct InstructorJourneyView: View {
    var selected: TrainingAircraft? = nil
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 7 : 12) {
            ForEach(Array([TrainingAircraft.copter, .airplane, .vtol, .examination].enumerated()), id: \.offset) { index, aircraft in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.25)) }
                VStack(spacing: 6) {
                    Image(systemName: symbol(aircraft)).font(.system(size: compact ? 15 : 23, weight: .medium))
                        .frame(width: compact ? 32 : 46, height: compact ? 32 : 46)
                        .background(selected == aircraft ? GroundControlPalette.accent.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == aircraft ? GroundControlPalette.accent.opacity(0.7) : GroundControlPalette.border))
                    if !compact {
                        // This key is assembled from the enum value at runtime. Passing it
                        // through LocalizedStringKey's interpolation can make SwiftUI treat the
                        // identifier as display text and even hyphenate it in the card. Resolve
                        // the localized value explicitly so the journey never shows the key.
                        Text(verbatim: L10n.s("instructor.journey.\(aircraft.rawValue)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }.foregroundStyle(selected == aircraft ? GroundControlPalette.accent : .white.opacity(0.72))
            }
        }
    }

    private func symbol(_ aircraft: TrainingAircraft) -> String {
        switch aircraft { case .copter: return "fanblades"; case .airplane: return "airplane"; case .vtol: return "arrow.triangle.2.circlepath"; case .examination: return "circle.grid.cross" }
    }
}

private struct InstructorAircraftSketch: View {
    let aircraft: TrainingAircraft
    var body: some View {
        ZStack {
            Circle().stroke(GroundControlPalette.accent.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: 112, height: 112)
            if aircraft == .copter {
                Path { path in
                    path.move(to: CGPoint(x: 30, y: 24)); path.addLine(to: CGPoint(x: 130, y: 86))
                    path.move(to: CGPoint(x: 130, y: 24)); path.addLine(to: CGPoint(x: 30, y: 86))
                }.stroke(GroundControlPalette.accent.opacity(0.65), lineWidth: 3)
                RoundedRectangle(cornerRadius: 7).fill(GroundControlPalette.accent.opacity(0.25)).frame(width: 30, height: 42)
                ForEach(0..<4, id: \.self) { index in
                    Image(systemName: "fanblades").font(.system(size: 27, weight: .light))
                        .position(x: index % 2 == 0 ? 30 : 130, y: index < 2 ? 24 : 86)
                }
            } else if aircraft == .vtol {
                HStack(spacing: 12) {
                    Image(systemName: "fanblades").font(.system(size: 31, weight: .light))
                    Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold))
                    Image(systemName: "airplane").font(.system(size: 36, weight: .light))
                }
            } else if aircraft == .examination {
                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { index in
                        Circle().stroke(GroundControlPalette.accent.opacity(index == 0 ? 1 : 0.4), lineWidth: 2)
                            .frame(width: index == 0 ? 25 : 18, height: index == 0 ? 25 : 18)
                            .overlay(Text("\(index + 1)").font(.system(size: 9, weight: .bold)))
                    }
                }
            } else {
                Image(systemName: "airplane").font(.system(size: 60, weight: .light)).rotationEffect(.degrees(-25))
                Image(systemName: "arrow.turn.up.right").font(.system(size: 24, weight: .light)).offset(x: 45, y: -33)
            }
        }.foregroundStyle(GroundControlPalette.accent).frame(width: 160, height: 112).allowsHitTesting(false)
    }
}

enum InstructorCombinationKind: Equatable { case sequence, simultaneous, alternatives }
struct InstructorControlCombination {
    let kind: InstructorCombinationKind
    let commands: [KeyboardCommand]
}

extension FlightTrainingStep {
    var controlCombinations: [InstructorControlCombination] {
        func sequence(_ commands: [KeyboardCommand]) -> InstructorControlCombination { .init(kind: .sequence, commands: commands) }
        func together(_ commands: [KeyboardCommand]) -> InstructorControlCombination { .init(kind: .simultaneous, commands: commands) }
        func choice(_ commands: [KeyboardCommand]) -> InstructorControlCombination { .init(kind: .alternatives, commands: commands) }
        switch self {
        case .copterIntro, .vtolIntro, .vtolTakeoff: return [sequence([.armAircraft, .takeoff, .ascend])]
        case .flightPanel: return [sequence([.openFlightPanel])]
        case .arm: return [sequence([.armAircraft])]
        case .copterTakeoff: return [sequence([.takeoff, .ascend])]
        case .instruments: return [sequence([.toggleTelemetryHUD])]
        case .simulationPanels: return [choice([.openFlightPanel, .openCameraPanel, .toggleMissionMap])]
        case .copterManual: return [together([.moveForward, .ascend]), choice([.moveLeft, .moveRight, .descend])]
        case .copterHover: return [sequence([.hover])]
        case .cameraPanel: return [sequence([.openCameraPanel])]
        case .cameraView: return [choice([.cameraModeOrbit, .cameraModeFPV, .cameraModeTop])]
        case .missionMap: return [sequence([.toggleMissionMap])]
        case .copterAutopilot: return [sequence([.openFlightPanel, .autoPath])]
        case .copterReturn: return [sequence([.returnHome])]
        case .airplaneIntro, .airplaneTakeoff: return [sequence([.armAircraft, .takeoff])]
        case .airplaneManual: return [together([.moveRight, .ascend]), choice([.moveForward, .moveBackward])]
        case .airplaneAutopilot: return [sequence([.altitudeHold])]
        case .vtolForward: return [sequence([.descend]), together([.vtolTransitionForward, .moveForward])]
        case .vtolBack: return [choice([.vtolTransitionBack, .hover])]
        case .vtolAutopilot: return [sequence([.autoPath])]
        case .examinationIntro: return [sequence([.armAircraft, .takeoff, .manualControl])]
        case .examination: return [together([.moveForward, .ascend]), choice([.moveLeft, .moveRight, .moveBackward, .descend])]
        }
    }

    var isChapterIntroduction: Bool { [.copterIntro, .airplaneIntro, .vtolIntro, .examinationIntro].contains(self) }
}

struct InstructorKeycap: View {
    let label: String
    var active = false
    var body: some View {
        Text(label).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            .frame(minWidth: 25, minHeight: 27).padding(.horizontal, 5)
            .foregroundStyle(active ? .white : GroundControlPalette.textPrimary)
            .background(active ? GroundControlPalette.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? GroundControlPalette.accent : .white.opacity(0.18)))
            .overlay(alignment: .bottom) { Color.white.opacity(active ? 0.25 : 0.12).frame(height: 2).padding(.horizontal, 5).padding(.bottom, 2) }
            .animation(Motion.press, value: active)
    }
}

private struct InstructorCombinationRow: View {
    let combination: InstructorControlCombination
    let bindings: [KeyBindingDescriptor]
    let pressed: Set<KeyboardCommand>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(kindKey), systemImage: kindSymbol)
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(GroundControlPalette.textSecondary)
            HStack(alignment: .top, spacing: 7) {
                ForEach(Array(combination.commands.enumerated()), id: \.offset) { index, command in
                    if index > 0 {
                        Text(separator).font(.system(size: 14, weight: .medium)).foregroundStyle(GroundControlPalette.accent)
                            .frame(height: 27)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if let binding = bindings.first(where: { $0.command == command }), binding.keyCode != UInt16.max {
                            HStack(spacing: 3) {
                                if binding.requiresShift { InstructorKeycap(label: "⇧", active: pressed.contains(.accelerate)) }
                                InstructorKeycap(label: binding.requiresShift && binding.keyLabel.hasPrefix("⇧") ? String(binding.keyLabel.dropFirst()) : binding.keyLabel,
                                                 active: pressed.contains(command))
                            }
                        } else { InstructorKeycap(label: "—") }
                        Text(LocalizedStringKey(command.titleKey)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var kindKey: String { switch combination.kind { case .sequence: return "instructor.combo.sequence"; case .simultaneous: return "instructor.combo.together"; case .alternatives: return "instructor.combo.choice" } }
    private var kindSymbol: String { switch combination.kind { case .sequence: return "arrow.right"; case .simultaneous: return "plus"; case .alternatives: return "arrow.left.arrow.right" } }
    private var separator: String { switch combination.kind { case .sequence: return "→"; case .simultaneous: return "+"; case .alternatives: return "/" } }
}

private struct InstructorPrimaryButton: View {
    let titleKey: String
    let action: () -> Void
    var disabled = false
    var color = GroundControlPalette.accent
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(LocalizedStringKey(titleKey)).font(.system(size: 13, weight: .bold))
                Spacer(minLength: 5)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
            }.padding(.horizontal, 14).padding(.vertical, 11)
                .foregroundStyle(.white).background(color, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(ShellButtonStyle(cornerRadius: 10)).disabled(disabled).keyboardShortcut(.defaultAction)
    }
}

struct InstructorTourOverlayView: View {
    let step: InstructorTourStep
    let targets: [String: Anchor<CGRect>]
    let onBack: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void
    let onOpenTraining: () -> Void
    var animateEntrance = true
    @State private var measured = CGSize(width: 440, height: 400)

    private var index: Int { InstructorTourStep.allCases.firstIndex(of: step) ?? 0 }
    private var hero: Bool { step == .welcome || step == .ready }

    var body: some View {
        GeometryReader { geometry in
            let rect = step.target.flatMap { targets[$0] }.map { geometry[$0] }
            let size = CGSize(width: min(hero ? 550 : 390, geometry.size.width - 48), height: measured.height)
            let frame = InstructorOverlayLayout.frame(size: size, canvas: geometry.size, target: rect, hero: hero)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture {}
                InstructorSpotlight(rect: rect, dimBackground: true)
                if let rect {
                    InstructorLeader(card: frame, target: rect, animateEntrance: animateEntrance)
                        .id(step)
                }
                tourCard.frame(width: frame.width)
                    .background(GeometryReader { proxy in Color.clear.preference(key: InstructorCardSizeKey.self, value: proxy.size) })
                    .position(x: frame.midX, y: frame.midY)
                    .id(step).modifier(InstructorEntrance(enabled: animateEntrance, horizontal: !hero))
            }.onPreferenceChange(InstructorCardSizeKey.self) { if $0.height > 0 && abs($0.height - measured.height) > 0.5 { measured = $0 } }
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .accessibilityElement(children: .contain).accessibilityIdentifier("instructor.appTour")
    }

    private var tourCard: some View {
        VStack(alignment: .leading, spacing: hero ? 20 : 14) {
            HStack {
                Label("instructor.tour.heading", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(GroundControlPalette.accent)
                Spacer()
                Text("\(index + 1) / \(InstructorTourStep.allCases.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if hero { InstructorJourneyView().frame(maxWidth: .infinity).padding(.vertical, 4) }
            Text(LocalizedStringKey(step.titleKey)).font(.system(size: hero ? 27 : 20, weight: .bold, design: .rounded))
            Text(LocalizedStringKey(step.detailKey)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            InstructorProgressBar(value: Double(index + 1) / Double(InstructorTourStep.allCases.count))
            HStack(spacing: 12) {
                if index > 0 { Button("instructor.back", action: onBack).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary) }
                InstructorPrimaryButton(titleKey: step == .ready ? "instructor.open_training" : "instructor.next", action: step == .ready ? onOpenTraining : onNext)
            }
            Button(LocalizedStringKey(step == .ready ? "instructor.finish_tour" : "instructor.skip_tour"), action: onDismiss)
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(hero ? 26 : 20)
            .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: hero ? 22 : 16))
            .overlay(RoundedRectangle(cornerRadius: hero ? 22 : 16).stroke(GroundControlPalette.accent.opacity(0.2)))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }
}

struct FlightInstructorOverlayView: View {
    @SimulationObservedObject var viewModel: DroneSimulationViewModel
    @ObservedObject private var bindings: BindingsViewModel
    let targets: [String: Anchor<CGRect>]
    let onExit: () -> Void
    var animateEntrance: Bool
    @State private var measured = CGSize(width: 390, height: 520)

    init(viewModel: DroneSimulationViewModel, targets: [String: Anchor<CGRect>], onExit: @escaping () -> Void,
         animateEntrance: Bool = true) {
        _viewModel = SimulationObservedObject(wrappedValue: viewModel)
        _bindings = ObservedObject(wrappedValue: viewModel.bindingsViewModel)
        self.targets = targets; self.onExit = onExit; self.animateEntrance = animateEntrance
    }

    var body: some View {
        if let progress = viewModel.flightTrainingProgress {
            GeometryReader { geometry in
                let viewport = targets["simulation.viewport"].map { geometry[$0] }
                let rect = target(progress).map { geometry[$0] }
                let hero = (progress.step.isChapterIntroduction && progress.phase == .briefing) || progress.phase == .completed
                let feedback = progress.phase == .checkpoint || progress.phase == .failed
                let width: CGFloat = hero ? 530 : feedback ? 330 : 390
                let frame = InstructorOverlayLayout.frame(size: CGSize(width: width, height: measured.height), canvas: geometry.size,
                    viewport: viewport, target: feedback ? nil : rect, hero: hero,
                    trailing: progress.step == .examination)
                let identity = "\(progress.step.rawValue).\(progress.phase)"
                ZStack(alignment: .topLeading) {
                    if !feedback, !hero, let rect {
                        InstructorSpotlight(rect: rect)
                    }
                    card(progress, hero: hero, feedback: feedback).frame(width: frame.width)
                        .background(GeometryReader { proxy in Color.clear.preference(key: InstructorCardSizeKey.self, value: proxy.size) })
                        .anchorPreference(key: InstructorCardAnchorKey.self, value: .bounds) { $0 }
                        .position(x: frame.midX, y: frame.midY)
                        .id(identity).modifier(InstructorEntrance(enabled: animateEntrance, horizontal: !hero))
                }
                .overlayPreferenceValue(InstructorCardAnchorKey.self) { anchor in
                    if !feedback, !hero, let rect, let anchor {
                        GeometryReader { overlay in
                            InstructorLeader(card: overlay[anchor], target: rect,
                                             animateEntrance: animateEntrance).id(identity)
                        }.allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(InstructorCardSizeKey.self) { if $0.height > 0 && abs($0.height - measured.height) > 0.5 { measured = $0 } }
            }
            .overlay {
                if viewModel.isPreparingFlightTraining {
                    InstructorPreparationOverlay()
                        .transition(.opacity)
                }
            }
            .animation(Motion.press, value: viewModel.isPreparingFlightTraining)
            .accessibilityIdentifier("instructor.flightCourse")
        }
    }

    private func target(_ progress: FlightTrainingProgress) -> Anchor<CGRect>? {
        guard let id = progress.step.spotlightTarget else { return nil }
        // If a module has not mounted its exact target yet, wait for the next layout pass instead
        // of pointing at a broad parent panel. A broad fallback is what produced apparently random
        // arrows after a sidebar scroll or while a conditional assist row was being inserted.
        return targets[id]
    }

    private func card(_ progress: FlightTrainingProgress, hero: Bool, feedback: Bool) -> some View {
        VStack(alignment: .leading, spacing: hero ? 18 : 13) {
            header(progress)
            if hero && progress.phase != .completed {
                HStack(spacing: 20) {
                    InstructorAircraftSketch(aircraft: progress.step.aircraft)
                        .modifier(InstructorEntrance(enabled: animateEntrance, delay: Motion.cascadeStep))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(LocalizedStringKey(progress.step.aircraft.titleKey)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(LocalizedStringKey(progress.step.titleKey)).font(.system(size: 25, weight: .bold, design: .rounded))
                    }
                }
                if progress.step.aircraft != .examination { InstructorJourneyView(selected: progress.step.aircraft, compact: true) }
            } else if feedback || progress.phase == .completed {
                feedbackTitle(progress)
            } else {
                Text(LocalizedStringKey(progress.step.titleKey)).font(.system(size: 19, weight: .bold, design: .rounded))
            }
            if progress.phase != .checkpoint {
                Text(LocalizedStringKey(progress.phase == .flying ? "instructor.action.\(progress.step.rawValue)" : detailKey(progress)))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(L10n.s(detailKey(progress)))
            }
            if progress.phase == .briefing || progress.phase == .flying {
                combinations(progress)
            }
            if progress.step.aircraft == .examination { spheres(progress) }
            if progress.phase == .flying { objective(progress) }
            footer(progress)
        }
        .padding(hero ? 24 : 18)
        .foregroundStyle(GroundControlPalette.textPrimary)
        .background(GroundControlPalette.panelRaised.opacity(0.98), in: RoundedRectangle(cornerRadius: hero ? 20 : 15))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(statusColor(progress)).frame(width: 3).padding(.vertical, 17)
        }
        .overlay(RoundedRectangle(cornerRadius: hero ? 20 : 15).stroke(statusColor(progress).opacity(0.23)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 5)
    }

    private func header(_ progress: FlightTrainingProgress) -> some View {
        HStack {
            Label("instructor.heading", systemImage: "graduationcap.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(statusColor(progress))
            Spacer()
            Text("\(progress.stepNumber) / \(progress.stepCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func feedbackTitle(_ progress: FlightTrainingProgress) -> some View {
        HStack(spacing: 14) {
            Image(systemName: progress.phase == .failed ? "arrow.counterclockwise" : progress.phase == .completed ? "rosette" : "checkmark")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(statusColor(progress))
                .frame(width: 48, height: 48).background(statusColor(progress).opacity(0.12), in: Circle())
                .modifier(InstructorEntrance(enabled: animateEntrance))
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(progress.phase == .checkpoint ? "instructor.checkpoint.title" : progress.phase == .failed ? "instructor.failed.title" : "instructor.completed.title"))
                    .font(.system(size: progress.phase == .completed ? 23 : 19, weight: .bold, design: .rounded))
                if progress.phase == .checkpoint {
                    Text(LocalizedStringKey(progress.step.titleKey)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func combinations(_ progress: FlightTrainingProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(displayedCombinations(progress).enumerated()), id: \.offset) { _, combination in
                InstructorCombinationRow(combination: combination, bindings: bindings.sections.flatMap(\.bindings), pressed: viewModel.instructorPressedCommands)
            }
            if displayedCombinations(progress).contains(where: { $0.kind == .simultaneous }) {
                Text("instructor.combo.short_inputs").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Button { viewModel.setBindingsPanelVisible(true, showKeys: true) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("instructor.configure_keys")
                    Spacer()
                    Text("⌘K").font(.system(size: 10, design: .monospaced))
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(GroundControlPalette.accent)
            }.buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("instructor.configureKeys")
        }.padding(12).background(GroundControlPalette.inset.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }

    private func displayedCombinations(_ progress: FlightTrainingProgress) -> [InstructorControlCombination] {
        if progress.step == .examination, !viewModel.isArmed || viewModel.physicalState.isGroundRestState {
            return [.init(kind: .sequence, commands: [.armAircraft, .takeoff, .manualControl])]
        }
        return progress.step.controlCombinations
    }

    private func spheres(_ progress: FlightTrainingProgress) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { index in
                if index > 0 { Capsule().fill(index <= progress.spheresPassed ? GroundControlPalette.success : .white.opacity(0.12)).frame(height: 2) }
                Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 28, height: 28)
                    .background(index < progress.spheresPassed ? GroundControlPalette.success.opacity(0.25) :
                        index == progress.spheresPassed ? GroundControlPalette.accent.opacity(0.25) : Color.white.opacity(0.04), in: Circle())
                    .overlay(Circle().stroke(index < progress.spheresPassed ? GroundControlPalette.success :
                        index == progress.spheresPassed ? GroundControlPalette.accent : .white.opacity(0.15)))
                    .animation(Motion.release, value: progress.spheresPassed)
            }
        }.padding(.vertical, 3)
    }

    private func objective(_ progress: FlightTrainingProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if progress.objectiveProgress > 0 {
                HStack {
                    Text("instructor.objective_progress").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress.objectiveProgress * 100))%").font(.system(size: 10, design: .monospaced))
                }
                InstructorProgressBar(value: progress.objectiveProgress)
            }
            if progress.manualControlRequired {
                Label("instructor.manual_required", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(GroundControlPalette.warning)
                Button("instructor.manual_handover", action: viewModel.takeManualControl).font(.caption).buttonStyle(.bordered)
            }
        }
    }

    private func footer(_ progress: FlightTrainingProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if progress.phase == .completed {
                InstructorPrimaryButton(titleKey: "instructor.finish_course", action: onExit, color: GroundControlPalette.success)
            } else if progress.phase == .failed {
                InstructorPrimaryButton(titleKey: "instructor.retry", action: { viewModel.restartFlightTrainingLesson() }, color: GroundControlPalette.warning)
            } else if progress.canContinue {
                HStack(spacing: 10) {
                    InstructorPrimaryButton(titleKey: progress.phase == .briefing ? "instructor.continue" : "instructor.next", action: { viewModel.continueFlightTraining() })
                    InstructorKeycap(label: "↵")
                }
            } else {
                Label("instructor.practice_now", systemImage: "keyboard").font(.system(size: 10, weight: .medium)).foregroundStyle(GroundControlPalette.accent)
            }
            HStack {
                if progress.phase == .flying {
                    Button("instructor.retry", action: { viewModel.restartFlightTrainingLesson() }).font(.system(size: 10)).buttonStyle(.plain)
                }
                Spacer()
                if progress.phase != .completed { Button("instructor.exit_course", action: onExit).font(.system(size: 10)).buttonStyle(.plain) }
            }.foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ progress: FlightTrainingProgress) -> Color {
        switch progress.phase { case .checkpoint, .completed: return GroundControlPalette.success; case .failed: return GroundControlPalette.warning; default: return GroundControlPalette.accent }
    }
    private func detailKey(_ progress: FlightTrainingProgress) -> String {
        switch progress.phase { case .completed: return "instructor.completed.detail"; case .failed: return "instructor.failed.detail"; default: return progress.step.detailKey }
    }
}

private struct InstructorPreparationOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(GroundControlPalette.accent)
                Text("instructor.preparing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text("instructor.preparing.detail")
                    .font(.system(size: 10))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(GroundControlPalette.accent.opacity(0.25)))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        .allowsHitTesting(true)
    }
}
