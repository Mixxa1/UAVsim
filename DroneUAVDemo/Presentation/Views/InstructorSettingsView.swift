import SwiftUI

/// The only repeat-training entry point: flight practice and app navigation are separate choices.
struct InstructorSettingsView: View {
    let completed: Bool
    var isEnabled = true
    let onFlight: () -> Void
    let onTour: () -> Void
    var animateEntrance = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "graduationcap.fill").font(.system(size: 26, weight: .light))
                    .foregroundStyle(GroundControlPalette.accent)
                    .frame(width: 54, height: 54)
                    .background(GroundControlPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 7) {
                    Text("settings.page.training").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("instructor.settings.detail").font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.modifier(TrainingSettingsReveal(enabled: animateEntrance, index: 0))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    flightCard(height: 360).frame(width: 320)
                    tourCard(height: 360).frame(width: 320)
                }
                VStack(spacing: 16) { flightCard(); tourCard() }
            }.modifier(TrainingSettingsReveal(enabled: animateEntrance, index: 1))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard").font(.system(size: 19)).foregroundStyle(GroundControlPalette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("instructor.settings.controls_title").font(.system(size: 12, weight: .semibold))
                    Text("instructor.settings.controls_detail").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12))
                .modifier(TrainingSettingsReveal(enabled: animateEntrance, index: 2))
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .accessibilityIdentifier("instructor.trainingSettings")
    }

    private func flightCard(height: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("instructor.settings.practice", systemImage: "airplane").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GroundControlPalette.accent)
                Spacer()
                if completed { Image(systemName: "checkmark.seal.fill").foregroundStyle(GroundControlPalette.success) }
            }
            InstructorJourneyView(compact: true).padding(.vertical, 10)
            Text("instructor.start_flight").font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text("instructor.settings.flight_detail").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("instructor.settings.flight_finish", systemImage: "circle.grid.cross")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
            launchButton(title: completed ? "instructor.settings.repeat" : "instructor.settings.begin", action: onFlight)
                .accessibilityIdentifier("instructor.startFlight")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(GroundControlPalette.accent.opacity(0.23)))
            .hoverHighlight(cornerRadius: 16, tint: GroundControlPalette.accent)
    }

    private func tourCard(height: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("instructor.settings.navigation", systemImage: "cursorarrow.click").font(.system(size: 10, weight: .bold))
                .foregroundStyle(GroundControlPalette.accent)
            windowSketch.frame(height: 52).padding(.vertical, 10)
            Text("instructor.start_tour").font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text("instructor.settings.tour_detail").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("instructor.settings.tour_finish", systemImage: "arrow.up.left")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
            launchButton(title: "instructor.settings.show", action: onTour)
                .accessibilityIdentifier("instructor.startTour")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(GroundControlPalette.borderStrong))
            .hoverHighlight(cornerRadius: 16, tint: GroundControlPalette.accent)
    }

    private var windowSketch: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)).frame(width: 19)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(GroundControlPalette.accent.opacity(0.3)).frame(height: 12)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.15))
                        RoundedRectangle(cornerRadius: 3).stroke(GroundControlPalette.accent, lineWidth: 1.5)
                    }
                }
            }.padding(7).frame(width: 115).background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GroundControlPalette.borderStrong))
            Image(systemName: "arrow.up.left").font(.system(size: 24, weight: .light)).foregroundStyle(GroundControlPalette.accent)
        }.frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
    }

    private func launchButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .bold))
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
            }.padding(.horizontal, 13).padding(.vertical, 11).foregroundStyle(.white)
                .background(GroundControlPalette.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(ShellButtonStyle(cornerRadius: 9)).disabled(!isEnabled)
    }
}

private struct TrainingSettingsReveal: ViewModifier {
    let enabled: Bool
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        let shown = visible || !enabled || reduceMotion
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : Motion.rise)
            .onAppear {
                guard enabled, !reduceMotion else { visible = true; return }
                withAnimation(Motion.panel.delay(Double(index) * Motion.cascadeStep)) { visible = true }
            }
    }
}
