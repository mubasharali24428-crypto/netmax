import SwiftUI

/// W16 — user-requested navigation + run control.
///
/// 1. `BackToDashboardButton`: a labeled back arrow shown on every non-dashboard
///    tab's header. Tapping returns to tab 0 (Dashboard) with the standard
///    spring. VoiceOver: "Back to Dashboard, button".
///
/// 2. Stop support lives in EngineClient.stopCurrent() (SIGTERM→SIGKILL);
///    `StopRunButton` wraps it with running-state awareness and posts
///    .netmaxRunStopped so views can reset their status without waiting for
///    the engine envelope.

extension Notification.Name {
    /// Posted after the user presses Stop; payload nil. Views listening
    /// reset their local status to .idle/.error with a stopped message.
    static let netmaxRunStopped = Notification.Name("netmax.run.stopped")
}

struct BackToDashboardButton: View {
    /// Binding to the root TabView selection (0 = Dashboard).
    let selection: Binding<Int>

    var body: some View {
        Button {
            withAnimation(NetMaxMotion.standard) {
                selection.wrappedValue = 0
            }
        } label: {
            Label("Back", systemImage: "chevron.left")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(NetMaxPressStyle())
        .help("Return to the Dashboard")
        .accessibilityLabel(Text("Back to Dashboard"))
    }
}

struct StopRunButton: View {
    /// Reflects whether a run is active; disabled when idle.
    let isRunning: Bool
    var onStop: (() -> Void)? = nil

    var body: some View {
        Button(role: .destructive) {
            EngineClient.stopCurrent()
            NotificationCenter.default.post(name: .netmaxRunStopped, object: nil)
            onStop?()
        } label: {
            Label(isRunning ? "Stop" : "Stop (idle)",
                  systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(!isRunning)
        .opacity(isRunning ? 1 : 0.5)
        .help(isRunning
              ? "Stop the running test (the engine is asked to terminate cleanly)"
              : "No test is currently running")
        .accessibilityLabel(Text("Stop the running test"))
    }
}
