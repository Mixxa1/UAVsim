import SwiftUI

/// The shell's movement, in one place: every screen outside the 3D viewport takes its timing from
/// here, so the interface moves the same way everywhere and is retuned by editing this file.
///
/// Nothing here is applied over the viewport. A view redrawn every simulation tick must not carry
/// an implicit animation, and a half-transparent layer over the 3D view is composited every frame.
enum Motion {
    /// Pointer over a control. Short enough to read as the control answering, not as a movement.
    static let hover = Animation.easeOut(duration: 0.12)
    /// A control going down under the pointer.
    static let press = Animation.easeOut(duration: 0.09)
    /// A released control coming back — the one place a little overshoot is wanted.
    static let release = Animation.spring(response: 0.26, dampingFraction: 0.72)
    /// One panel replacing another inside a screen. Settles without a visible bounce.
    static let panel = Animation.spring(response: 0.36, dampingFraction: 0.88)
    /// The curtain lifting off a new screen.
    static let screen = Animation.easeOut(duration: 0.30)

    /// Delay between neighbours appearing in a cascade.
    static let cascadeStep: Double = 0.04
    /// How far an appearing element travels.
    static let rise: CGFloat = 12
}

extension AnyTransition {
    /// A panel taking another's place: the new one rises into position, the old one sinks back.
    static var panelSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: Motion.rise)),
            removal: .opacity.combined(with: .scale(scale: 0.985))
        )
    }
}

// MARK: - Buttons

/// Hover and press feedback for the shell's own drawn buttons. The label keeps its look; the style
/// adds a highlight over it and a small change of size.
struct ShellButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    /// Highlight colour: white over the dark panels, `.primary` over system backgrounds.
    var tint: Color = .white
    var hoverScale: CGFloat = 1.015

    func makeBody(configuration: Configuration) -> some View {
        ShellButtonBody(configuration: configuration, cornerRadius: cornerRadius, tint: tint, hoverScale: hoverScale)
    }
}

private struct ShellButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let tint: Color
    let hoverScale: CGFloat

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if configuration.isPressed { return 0.975 }
        return isHovered ? hoverScale : 1
    }

    private var highlight: Double {
        if configuration.isPressed { return 0.12 }
        return isHovered ? 0.06 : 0
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .overlay(shape.fill(tint.opacity(highlight)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(tint.opacity(isHovered ? 0.30 : 0), lineWidth: 1).allowsHitTesting(false))
            .contentShape(shape)
            .scaleEffect(scale)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
            .animation(Motion.hover, value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }
}

// MARK: - Modifiers

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay(shape.fill(tint.opacity(isHovered ? 0.06 : 0)).allowsHitTesting(false))
            .overlay(shape.stroke(tint.opacity(isHovered ? 0.22 : 0), lineWidth: 1).allowsHitTesting(false))
            .animation(Motion.hover, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct CascadeAppear: ViewModifier {
    let index: Int
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : Motion.rise)
            .onAppear {
                withAnimation(Motion.panel.delay(Double(index) * Motion.cascadeStep)) {
                    isShown = true
                }
            }
    }
}

/// The shell colour laid over a screen that has just replaced another, fading away. Keyed by the
/// screen, so each change starts a fresh, opaque curtain; the screen underneath is not animated.
private struct ScreenCurtain<Screen: Hashable>: ViewModifier {
    let screen: Screen

    func body(content: Content) -> some View {
        content.overlay {
            CurtainFade()
                .id(screen)
                .allowsHitTesting(false)
        }
    }
}

private struct CurtainFade: View {
    @State private var opacity: Double = 1
    @State private var isLifted = false

    var body: some View {
        // Gone once faded: nothing stays layered over the viewport afterwards.
        if !isLifted {
            GroundControlPalette.shell
                .opacity(opacity)
                .ignoresSafeArea()
                .onAppear {
                    withAnimation(Motion.screen) {
                        opacity = 0
                    } completion: {
                        isLifted = true
                    }
                }
        }
    }
}

extension View {
    /// A highlight that follows the pointer, for rows and cards that are not themselves buttons.
    func hoverHighlight(cornerRadius: CGFloat, tint: Color = .primary) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, tint: tint))
    }

    /// Fades and lifts the view in when it first appears, `index` steps after the first of its group.
    func cascadeAppear(_ index: Int) -> some View {
        modifier(CascadeAppear(index: index))
    }

    /// Covers each change of `screen` with a curtain that fades away.
    func screenCurtain<Screen: Hashable>(for screen: Screen) -> some View {
        modifier(ScreenCurtain(screen: screen))
    }
}
