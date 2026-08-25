//
//  SettingsView.swift
//  netmax-desktop
//
//  L3-C — Form-based settings pane over contract P1 preferences.
//
//  Every control is bound to `AppPreferences.shared` (never UserDefaults
//  directly), carries an accessibilityLabel (+ hint where the effect isn't
//  obvious), and persists immediately — there is no separate Save button,
//  matching macOS settings-pane convention.
//
//  Sections: Mode Lab defaults · Python interpreter · Startup · Notifications
//  · Onboarding reset · About (version, engine test count, honest-limits
//  note).
//

import AppKit
import SwiftUI

// MARK: - Section anchors (W12 T4-a, audit 150)

/// Jump targets for the settings section picker. `id` doubles as the
/// ScrollViewReader anchor id attached to each Form section.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case discovery
    case modeLabDefaults
    case interpreter
    case startup
    case notifications
    case onboarding
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discovery: "Feature Discovery"
        case .modeLabDefaults: "Mode Lab Defaults"
        case .interpreter: "Python Interpreter"
        case .startup: "Startup"
        case .notifications: "Notifications"
        case .onboarding: "Onboarding"
        case .about: "About"
        }
    }
}

struct SettingsView: View {
    /// W10-4: lets the feature-discovery cards switch the root tab.
    var onOpenTab: (Int) -> Void = { _ in }

    /// Single source of truth per contract P1; writes persist via its
    /// property observers.
    @ObservedObject private var prefs = AppPreferences.shared

    /// Set while the Reset Onboarding confirmation is up.
    @State private var confirmingOnboardingReset = false

    /// W12 USER-IDEA: plan cap shared with TargetSpeedView (same key).
    @AppStorage("netmax.plan.mbps") private var planMbps: Double = 100

    /// Self-persisting store behind the notification rules (`netmax.notify.*`),
    /// owned by NotificationPreferences; this view binds through it exactly as
    /// NotificationPrefsView does so both surfaces share live state.
    @ObservedObject private var notifyPrefs = NotificationPreferences.shared

    /// W12 T4-a (audit 150): picker row at the top that jumps to a section.
    /// Stays empty between jumps so re-choosing the same entry fires again.
    @State private var jumpTarget: SettingsSection?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                sectionPicker
                planCapSection
                featureDiscovery
                modeLabDefaults
                interpreter
                startup
                notifications
                onboardingReset
                about
            }
            .formStyle(.grouped)
            .frame(minWidth: 420, idealWidth: 460, minHeight: 520)
            .accessibilityIdentifier("settings.root")
            .onChange(of: jumpTarget) { target in
                guard let target else { return }
                withAnimation {
                    proxy.scrollTo(target.id, anchor: .top)
                }
                // Reset so picking the SAME section again jumps again.
                jumpTarget = nil
            }
        }
    }

    // MARK: - Section picker (W12 T4-a)

    /// "Grouped nav" for the long settings pane: pick a name, the form
    /// scrolls to that anchor (audit 150).
    private var sectionPicker: some View {
        Section {
            Picker("Go to", selection: $jumpTarget) {
                Text("All Sections").tag(SettingsSection?.none)
                ForEach(SettingsSection.allCases) { section in
                    Text(section.title).tag(Optional(section))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Jump to settings section"))
            .accessibilityHint(Text("Scrolls the settings list to the chosen section."))
            .accessibilityIdentifier("settings.sectionPicker")
        }
    }

    // MARK: - Plan cap (W12 USER-IDEA: target-speed mode needs the plan)

    /// The user's stated plan cap in Mbps. TargetSpeedView offers targets
    /// only within this; both surfaces share the same AppStorage key.
    private var planCapSection: some View {
        Section {
            Stepper(value: $planMbps, in: 5...1000, step: 5) {
                HStack {
                    Text("My plan speed")
                    Spacer()
                    Text(planMbps >= 1000
                         ? "1 Gbps"
                         : "\(Int(planMbps)) Mbps")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(Text("Your internet plan's advertised speed"))
            .accessibilityHint(Text("Target Speed offers goals at or below this"))
        } header: {
            Text("My Internet Plan")
        } footer: {
            Text("Used by Target Speed mode — it only suggests speeds within your plan and tells you honestly if the line can't reach the target.")
        }
    }

    // MARK: - Feature discovery (W10-4)

    private var featureDiscovery: some View {
        FeatureDiscoverySection(openTab: onOpenTab)
            .id(SettingsSection.discovery.id) // T4-a anchor
    }

    // MARK: - Mode Lab defaults

    private var modeLabDefaults: some View {
        Section {
            stepperRow(
                label: "Default streams",
                value: $prefs.defaultStreams,
                range: AppPreferences.Limits.streams,
                hint: "Number of parallel measurement streams preselected in Mode Lab."
            )
            stepperRow(
                label: "Default seconds",
                value: $prefs.defaultSeconds,
                range: AppPreferences.Limits.seconds,
                hint: "Duration in seconds preselected for each Mode Lab run."
            )
            stepperRow(
                label: "Default result count",
                value: $prefs.defaultCount,
                range: AppPreferences.Limits.count,
                hint: "How many results Mode Lab shows per run."
            )
        } header: {
            Text("Mode Lab Defaults")
        } footer: {
            Text("Used when you open Mode Lab — change them there any time.")
        }
        .id(SettingsSection.modeLabDefaults.id) // T4-a anchor
    }

    private func stepperRow(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        hint: String
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(value.wrappedValue)"))
        .accessibilityHint(Text(hint))
    }

    // MARK: - Python interpreter

    /// True when the override is empty (resolve on PATH) or names an
    /// executable file.
    private var overrideLooksValid: Bool {
        let trimmed = prefs.pythonOverride
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return FileManager.default.isExecutableFile(atPath: trimmed)
    }

    private var interpreter: some View {
        Section {
            TextField("/usr/bin/python3", text: $prefs.pythonOverride, prompt: Text(verbatim: "/usr/bin/python3"))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .accessibilityLabel(Text("Python interpreter override"))
                .accessibilityHint(Text("Full path to the Python 3 interpreter the engine should use. Leave empty to resolve python3 on PATH."))

            if !prefs.pythonOverride.isEmpty {
                if overrideLooksValid {
                    Label("Executable found", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                        .accessibilityLabel(Text("Interpreter override looks valid"))
                } else {
                    Label("No executable at this path — run will fall back to python3 on PATH", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                        .accessibilityLabel(Text("Interpreter override path not found"))
                }
            }
        } header: {
            Text("Python Interpreter")
        } footer: {
            Text("/usr/bin/python3 or full path — leave empty to use python3 from PATH.")
        }
        .id(SettingsSection.interpreter.id) // T4-a anchor
    }

    // MARK: - Startup

    private var startup: some View {
        Section {
            Toggle("Launch main window at startup", isOn: $prefs.launchWindow)
                .accessibilityLabel(Text("Launch main window at startup"))
                .accessibilityHint(Text("When enabled, the dashboard window opens automatically. The menu-bar bolt icon stays available either way."))
        } header: {
            Text("Startup")
        }
        .id(SettingsSection.startup.id) // T4-a anchor
    }

    // MARK: - Notifications

    /// NotificationPrefsView's content expressed as native Form sections.
    /// That view is a top-level `Form` (with its own grouped style + frame),
    /// which cannot nest cleanly inside this settings Form, so its master
    /// toggle and per-rule rows are mirrored here — same store
    /// (`NotificationPreferences.shared`), same keys, same accessibility
    /// identifiers — instead of embedding it as a sub-Form.
    private var notifications: some View {
        Group {
            Section {
                Toggle("Enable notifications", isOn: $notifyPrefs.notificationsEnabled)
                    .accessibilityLabel(Text("Enable notifications"))
                    .accessibilityHint(Text("Master switch. When off, no notification fires regardless of the individual rules below."))
                    .accessibilityIdentifier("notifications.master")
            } header: {
                Text("Notifications")
            } footer: {
                Text(notifyPrefs.notificationsEnabled
                     ? "NetMax will alert you when any enabled rule matches."
                     : "Notifications are off — individual rules are kept but ignored.")
            }

            Section {
                notificationRuleRow(
                    title: "Grade drop",
                    subtitle: "Bufferbloat grade falls ≥ 2 letters between runs (e.g. B → D).",
                    isOn: $notifyPrefs.gradeDropEnabled,
                    kind: .bloatGradeDrop,
                    hint: "Alerts when a run's bufferbloat grade drops sharply compared to the previous run."
                )
                notificationRuleRow(
                    title: "High loss",
                    subtitle: "Packet loss climbs above the healthy 3% threshold.",
                    isOn: $notifyPrefs.highLossEnabled,
                    kind: .packetLossSpike,
                    hint: "Alerts when measured packet loss crosses the high-loss threshold."
                )
                notificationRuleRow(
                    title: "Run failed",
                    subtitle: "A run fails right after a successful one.",
                    isOn: $notifyPrefs.failureEnabled,
                    kind: .successToFailure,
                    hint: "Alerts when the connection appears to drop out — a failed run following a successful one."
                )
            } header: {
                Text("Alert Rules")
            } footer: {
                Text("Rules apply to every run while the master switch is on.")
            }
            .disabled(!notifyPrefs.notificationsEnabled)
            .opacity(notifyPrefs.notificationsEnabled ? 1 : 0.55)
        }
        .id(SettingsSection.notifications.id) // T4-a anchor
    }

    /// NotificationPrefsView's standard rule row: title + one-line effect,
    /// bound toggle on the trailing edge.
    private func notificationRuleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        kind: DegradationAlert.Kind,
        hint: String
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("notifications.rule.\(kind.rawValue)")
    }

    // MARK: - Onboarding

    private var onboardingReset: some View {
        Section {
            Button(role: .destructive) {
                confirmingOnboardingReset = true
            } label: {
                Text("Reset onboarding")
            }
            .confirmationDialog(
                "Show the intro again on next launch?",
                isPresented: $confirmingOnboardingReset,
                titleVisibility: .visible
            ) {
                Button("Reset onboarding", role: .destructive) {
                    resetOnboarding()
                }
            }
            .accessibilityLabel(Text("Reset onboarding"))
            .accessibilityHint(Text("Shows the four-step introduction again next launch. Your settings and history are kept."))
        } header: {
            Text("Onboarding")
        } footer: {
            Text("Replays the four-step intro next time you open NetMax. Your settings and history are kept.")
        }
        .id(SettingsSection.onboarding.id) // T4-a anchor
    }

    /// Flips the exact shared key B1's shell watches (`netmax.onboarding.complete`)
    /// so both windows' `@AppStorage` pick it up live.
    private func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: OnboardingConstants.completionKey)
    }

    // MARK: - About

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "NetMax Desktop \(version) (\(build))"
    }

    private var about: some View {
        Section {
            Text(versionLine)
                .font(.callout)
                .accessibilityLabel(Text(versionLine))

            Text("engine: 157 offline tests")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityLabel(Text("engine: 157 offline tests"))

            // T3-c (W11-A-102): telemetry stance, stated in-app.
            Text("Privacy: All data stays on this Mac. The app makes no telemetry calls.")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityLabel(Text("Privacy: all data stays on this Mac. The app makes no telemetry calls."))

            // T3-c (W11-A-101): grading rubric surfaced in-app.
            Text("Methodology: Grades use Waveform/DSLReports-style latency-under-load rubric.")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityLabel(Text("Methodology: grades use a Waveform/DSLReports-style latency-under-load rubric."))

            // T3-c (W11-A-132): license posture, stated in-app.
            Text("Licenses: SwiftUI · Apple engines · no third-party runtime deps")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityLabel(Text("Licenses: SwiftUI, Apple engines, no third-party runtime dependencies"))
        } header: {
            Text("About")
        } footer: {
            Text("Results reflect what your connection delivers right now — they vary with network conditions and don't guarantee peak speed.")
                .accessibilityLabel(Text("Honest limits: results reflect current conditions, vary with the network, and don't guarantee peak speed."))
        }
        .id(SettingsSection.about.id) // T4-a anchor
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
