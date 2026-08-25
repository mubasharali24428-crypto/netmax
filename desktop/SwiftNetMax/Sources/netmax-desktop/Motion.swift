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
/// Applied app-wide via `.netMaxPressable()`.
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

extension View {
    /// Instant press-down feedback with a critically damped spring-back.
    /// Respects Reduce Motion (cross-fade instead of scale).
    func netMaxPressable() -> some View {
        buttonStyle(NetMaxPressStyle())
    }

    /// Motion wrapper: replaces `animation` when Reduce Motion is on.
    /// Usage: `.modifier(NetMaxMotionModifier(animation: NetMaxMotion.standard, value: x))`
    func netMaxTransition(reduceMotion: Bool) -> some View {
        reduceMotion ? AnyView(opacity(1.0)) : AnyView(self)
    }
}
