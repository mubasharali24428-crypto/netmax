import SwiftUI

/// W8 TEAM-A — Apple-design motion system (skill: apple-design).
///
/// Law applied:
/// - Default UI motion = critically damped spring (no overshoot): the
///   interface moves like a physical object, not a cartoon.
/// - Feedback fires on press-DOWN, not release (§1 Response).
/// - Every animation respects Reduce Motion → opacity cross-fade instead
///   of movement (§14).
enum NetMaxMotion {
    /// Default for state changes, selections, chrome. No overshoot.
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// For momentum-driven interactions only (flick, drag release).
    static let momentum = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// Reduced-motion substitute: short cross-fade, no movement.
    static let crossFade = Animation.easeInOut(duration: 0.18)
}

/// Press-down feedback per apple-design §1: scale on press, spring back.
struct NetMaxPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? NetMaxMotion.crossFade : NetMaxMotion.standard,
                       value: configuration.isPressed)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

// MARK: - W9 G3/G2 modifiers (top-level: Swift forbids nesting types in
// protocol extensions)

/// Hover lift: slight scale + deepened shadow on pointer-over. Springs from
/// current value; Reduce Motion swaps scale for shadow-only.
struct NetMaxHoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.01 : 1.0)
            .shadow(
                color: .black.opacity(hovering ? 0.18 : 0.08),
                radius: hovering ? 10 : 5,
                y: hovering ? 4 : 2
            )
            .animation(reduceMotion ? NetMaxMotion.crossFade : NetMaxMotion.standard,
                       value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func netMaxHoverLift() -> some View {
        modifier(NetMaxHoverLift())
    }
}

/// Staggered appear: fade + slight rise, spring standard.
/// Reduce Motion → opacity-only cross-fade.
struct NetMaxStaggeredAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .animation(
                reduceMotion ? NetMaxMotion.crossFade
                             : NetMaxMotion.standard.delay(Double(index) * 0.06),
                value: shown
            )
            .onAppear { shown = true }
    }
}

extension View {
    func netMaxStaggeredAppear(index: Int) -> some View {
        modifier(NetMaxStaggeredAppear(index: index))
    }
}
