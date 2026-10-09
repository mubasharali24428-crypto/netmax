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

// MARK: - Phase 5: Color-blind Friendly Palette

/// Color-blind friendly palette: blue/orange instead of red/green.
extension Color {
    static let badgeSafe = DesignTokens.info     // Blue
    static let badgeWarning = DesignTokens.warning  // Orange
    static let badgeDanger = DesignTokens.error   // Red (errors only)
    static let badgeInfo = DesignTokens.focus     // Lavender-purple (universal)
    static let badgeSuccess = DesignTokens.success  // Emerald (NetMax brand)
}

// MARK: - Section anchors (W12 T4-a, audit 150)

/// Jump targets for the settings section picker. `id` doubles as the
/// ScrollViewReader anchor id attached to each Form section.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case discovery
    case modeLabDefaults
    case interpreter
    case remoteAI
    case startup
    case historyRetention
    case notifications
    case onboarding
    case license
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discovery: "Feature Discovery"
        case .modeLabDefaults: "Mode Lab Defaults"
        case .interpreter: "Python Interpreter"
        case .remoteAI: "Remote AI"
        case .startup: "Startup"
        case .historyRetention: "History Housekeeping"
        case .notifications: "Notifications"
        case .onboarding: "Onboarding"
        case .license: "License"
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
    /// owned by NotificationPreferences; Settings binds through it only.
    @ObservedObject private var notifyPrefs = NotificationPreferences.shared

    /// W12 T4-a (audit 150): picker row at the top that jumps to a section.
    /// Stays empty between jumps so re-choosing the same entry fires again.
    @State private var jumpTarget: SettingsSection?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                // Phase 5: Theme selector
                themeSelector
                sectionPicker
                planCapSection
                featureDiscovery
                modeLabDefaults
                interpreter
                remoteAIConsent
                startup
                historyRetention // W13B UB-4
                notifications
                onboardingReset
                licenseSection
                about
                // Phase 5: New sections
                testimonialsSection
                analyticsSection
                changelogSection
                backupSection
                subscriptionSection
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
            .onAppear {
                // W12 T1-c: re-read the digest gate so a value flipped
                // elsewhere (or in a previous session) is what's shown.
                digestOn = NotifyDigest.isEnabled
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

    // MARK: - Phase 5: Theme Selector

    /// Theme selector — switch between 8 design themes.
    @AppStorage("netmax.theme") private var selectedTheme: String = "dark"

    private var themeSelector: some View {
        Section {
            Picker("Theme", selection: $selectedTheme) {
                ForEach(ThemeVariation.allCases, id: \.self) { theme in
                    Text(theme.name).tag(theme.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Select UI theme"))
            .accessibilityHint(Text("Choose from 8 design themes: dark, light, cinematic, minimalist, enterprise, playful, fintech, terminal"))
        } header: {
            Label("Appearance", systemImage: "paintpalette")
        } footer: {
            Text("Current theme: \(selectedTheme.capitalized). Matches \(ThemeVariation.allCases.count) design systems from awesome-design-md.")
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
                        .foregroundColor(DesignTokens.secondaryText)
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
                    .foregroundColor(DesignTokens.secondaryText)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(value.wrappedValue)"))
        .accessibilityHint(Text(hint))
    }

    // MARK: - Python interpreter

    /// True when the override is empty (default /usr/bin/python3) or names
    /// an executable file.
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
                .accessibilityHint(Text("Full path to the Python 3 interpreter the engine should use. Leave empty to use /usr/bin/python3."))

            if !prefs.pythonOverride.isEmpty {
                if overrideLooksValid {
                    Label("Executable found", systemImage: "checkmark.circle.fill")
                        .foregroundColor(DesignTokens.success)
                        .font(.caption)
                        .accessibilityLabel(Text("Interpreter override looks valid"))
                } else {
                    Label("No executable at this path — run will fall back to /usr/bin/python3", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(DesignTokens.warning)
                        .font(.caption)
                        .accessibilityLabel(Text("Interpreter override path not found"))
                }
            }
        } header: {
            Text("Python Interpreter")
        } footer: {
            Text("/usr/bin/python3 or a full path — leave empty to use /usr/bin/python3.")
        }
        .id(SettingsSection.interpreter.id) // T4-a anchor
    }

    // MARK: - Remote AI consent

    private var remoteAIConsent: some View {
        Section {
            Toggle("Allow remote AI analysis", isOn: $prefs.allowRemoteAI)
                .accessibilityLabel(Text("Allow remote AI analysis"))
                .accessibilityHint(Text("When enabled, approved measurement fields may be sent to the configured AI provider. MCP cannot change this setting."))
                .accessibilityIdentifier("settings.remoteAIConsent")

            LabeledContent("Provider", value: RemoteAIProviderLabel.current)
                .accessibilityIdentifier("settings.remoteAIProvider")

            VStack(alignment: .leading, spacing: 4) {
                Text("Data sent when enabled")
                    .font(.subheadline.weight(.semibold))
                Text(RemoteAISettingsDisclosure.payloadSummary)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(RemoteAISettingsDisclosure.accessibilitySummary))
            }

            Text(RemoteAISettingsDisclosure.mcpConsent)
                .font(.caption)
                .foregroundColor(DesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(RemoteAISettingsDisclosure.mcpConsent))
        } header: {
            Label("Remote AI Privacy", systemImage: "network.badge.shield.half.filled")
        } footer: {
            Text("Off by default. Provider API keys and endpoint URLs are not displayed here.")
        }
        .id(SettingsSection.remoteAI.id)
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

    /// Task 3: auto-triage opt-in — bound to AutoTriage.enabledKey.
    /// When a degradation alert fires, NetMax runs one extra `full` engine
    /// pass (rate-capped at 1/30 min) to gather deeper evidence for the
    /// ISP report. Default OFF.
    @AppStorage(AutoTriage.enabledKey) private var autoTriageEnabled = false

    /// Notification Form sections: master toggle + per-rule rows bound to
    /// NotificationPreferences.shared (same keys/ids as the old prefs Form).
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

            // W12 T1-c (W11-A-029): surface W7-1's existing digest batching,
            // which previously had no UI. Bound to the exact shared key
            // `netmax.notify.digest` via NotifyDigest.digestGateKey.
            Section {
                Toggle("Daily digest instead of individual alerts", isOn: digestGateBinding)
                    .accessibilityLabel(Text("Daily digest instead of individual alerts"))
                    .accessibilityHint(Text("Collects degradation alerts and delivers them as one daily summary instead of posting each alert immediately."))
                    .accessibilityIdentifier("notifications.digest")
            } header: {
                Text("Delivery")
            } footer: {
                Text(digestOn
                     ? "Alerts accumulate quietly and arrive as ONE summary roughly every 24 hours."
                     : "Each matching alert is posted as soon as it fires.")
            }

            // Task 3: auto-triage toggle under Alert Rules.
            Section {
                Toggle("Auto-triage on degradation alerts", isOn: $autoTriageEnabled)
                    .accessibilityLabel(Text("Auto-triage on degradation alerts"))
                    .accessibilityHint(Text("When an alert fires, run one extra full diagnostic pass (at most once every 30 minutes) to enrich the ISP evidence packet."))
                    .accessibilityIdentifier("notifications.autoTriage")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Adds a `full` engine run after a degradation alert so your ISP evidence packet has deeper data. Rate-capped to one pass every 30 minutes. Default off.")
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

            // M6 — quiet hours (netmax.notify.quiet*): hold delivery inside
            // a local-time window; may wrap midnight (e.g. 22:00–07:30).
            Section {
                Stepper {
                    Text(String(format: "Start: %02d:%02d",
                                notifyPrefs.quietStartHour,
                                notifyPrefs.quietStartMinute))
                } onIncrement: {
                    bumpQuietStart()
                } onDecrement: {
                    dropQuietStart()
                }
                .accessibilityLabel(Text("Quiet hours start"))
                .accessibilityHint(Text("When to stop delivering notifications immediately. Increments by 5 minutes; wraps through midnight."))
                .accessibilityIdentifier("notifications.quietStart")

                Stepper {
                    Text(String(format: "End: %02d:%02d",
                                notifyPrefs.quietEndHour,
                                notifyPrefs.quietEndMinute))
                } onIncrement: {
                    bumpQuietEnd()
                } onDecrement: {
                    dropQuietEnd()
                }
                .accessibilityLabel(Text("Quiet hours end"))
                .accessibilityHint(Text("When held notifications may deliver. Increments by 5 minutes; wraps through midnight."))
                .accessibilityIdentifier("notifications.quietEnd")
            } header: {
                Text("Quiet Hours")
            } footer: {
                Text("Alerts that fire inside this window wait until it ends. Default 22:00–07:30.")
            }
            .disabled(!notifyPrefs.notificationsEnabled)
            .opacity(notifyPrefs.notificationsEnabled ? 1 : 0.55)
        }
        .id(SettingsSection.notifications.id) // T4-a anchor
    }

    // M6 quiet-hours steppers: ±5 minutes with hour wrap (0…23 / 0…59).

    private func bumpQuietStart() {
        var m = notifyPrefs.quietStartMinute + 5
        var h = notifyPrefs.quietStartHour
        if m > 59 { m = 0; h = h >= 23 ? 0 : h + 1 }
        notifyPrefs.quietStartMinute = m
        notifyPrefs.quietStartHour = h
    }

    private func dropQuietStart() {
        var m = notifyPrefs.quietStartMinute - 5
        var h = notifyPrefs.quietStartHour
        if m < 0 { m = 55; h = h <= 0 ? 23 : h - 1 }
        notifyPrefs.quietStartMinute = m
        notifyPrefs.quietStartHour = h
    }

    private func bumpQuietEnd() {
        var m = notifyPrefs.quietEndMinute + 5
        var h = notifyPrefs.quietEndHour
        if m > 59 { m = 0; h = h >= 23 ? 0 : h + 1 }
        notifyPrefs.quietEndMinute = m
        notifyPrefs.quietEndHour = h
    }

    private func dropQuietEnd() {
        var m = notifyPrefs.quietEndMinute - 5
        var h = notifyPrefs.quietEndHour
        if m < 0 { m = 55; h = h <= 0 ? 23 : h - 1 }
        notifyPrefs.quietEndMinute = m
        notifyPrefs.quietEndHour = h
    }

    /// W12 T1-c state mirror: true while the digest gate (`netmax.notify.digest`)
    /// is on. Seeded from the shared key when the view appears; writes go
    /// straight back to that key so `NotifyDigest.isEnabled` sees them.
    @State private var digestOn = NotifyDigest.isEnabled

    /// Binding for the digest toggle. Writes go to the EXACT shared key via
    /// `NotifyDigest.digestGateKey`; the mirror updates synchronously so the
    /// footer text follows the switch without waiting for a KVO round-trip.
    private var digestGateBinding: Binding<Bool> {
        Binding(
            get: { digestOn },
            set: { newValue in
                digestOn = newValue
                UserDefaults.standard.set(newValue, forKey: NotifyDigest.digestGateKey)
            }
        )
    }

    /// Standard rule row: title + one-line effect, bound toggle on the
    /// trailing edge.
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
                    .foregroundColor(DesignTokens.secondaryText)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("notifications.rule.\(kind.rawValue)")
    }

    // MARK: - History housekeeping (W13B TEAM-UB / UB-4)

    /// "Keep history for N days" — enforced by HistoryStore.loadAll, which
    /// moves older records to archive-history.jsonl instead of destroying
    /// them. 0 = keep forever (default). Bound to the EXACT shared key
    /// `netmax.history.retentionDays` via HistoryStore.retentionDaysKey.
    @AppStorage(HistoryStore.retentionDaysKey) private var retentionDays = 0

    private var historyRetention: some View {
        Section {
            Stepper(value: $retentionDays, in: 0...365) {
                HStack {
                    Text("Keep history for")
                    Spacer()
                    Text(retentionDays == 0
                         ? "Forever"
                         : "\(retentionDays) day\(retentionDays == 1 ? "" : "s")")
                        .foregroundColor(DesignTokens.secondaryText)
                        .monospacedDigit()
                }
            }
            .accessibilityLabel(Text("Keep history for N days"))
            .accessibilityValue(Text(retentionDays == 0
                                     ? "Forever" : "\(retentionDays) days"))
            .accessibilityHint(Text(
                "Runs older than this move to an archive file on disk rather than being deleted. Zero keeps everything forever."))
        } header: {
            Text("History Housekeeping")
        } footer: {
            Text(retentionDays == 0
                 ? "All runs are kept forever."
                 : "Runs older than \(retentionDays) day\(retentionDays == 1 ? "" : "s") move to archive-history.jsonl — nothing is ever silently destroyed.")
        }
        .id(SettingsSection.historyRetention.id) // M2: unique anchor (was reusing startup)
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

    // MARK: - License (H8)

    /// H8: the trial never auto-starts — the user presses "Start trial"
    /// (or a future gated-feature first use calls `startTrial`). Key field
    /// activates Pro offline (structural 5x4 check only).
    @ObservedObject private var license = LicenseGate.shared

    private var licenseSection: some View {
        Section {
            HStack {
                Text("Current tier")
                Spacer()
                Text(tierLabel)
                    .foregroundColor(DesignTokens.secondaryText)
                    .accessibilityLabel(Text("Current license tier: \(tierLabel)"))
            }

            switch LicenseGate.effectiveTier(license) {
            case .Pro:
                Label("Pro — activated", systemImage: "checkmark.seal.fill")
                    .foregroundColor(DesignTokens.success)
                    .accessibilityLabel(Text("Pro tier activated"))
                Button("Deactivate key") { license.deactivate() }
                    .accessibilityLabel(Text("Deactivate license key"))
                    .accessibilityHint(Text("Removes the stored key and returns to Free (or active trial)."))
            case .Trial:
                let ends = license.trialEndsAt
                Label("Trial active until \(ends)", systemImage: "clock.badge.checkmark")
                    .foregroundColor(DesignTokens.accent)
                    .accessibilityLabel(Text("Trial active until \(ends)"))
            case .Free:
                if license.trialNeedsConnection {
                    Label("Couldn't reach the trial server — check your connection and try again.", systemImage: "wifi.exclamationmark")
                        .foregroundColor(DesignTokens.secondaryText)
                        .accessibilityLabel(Text("Couldn't reach the trial server."))
                    Button("Start 14-day trial") { license.startTrial() }
                        .accessibilityLabel(Text("Start 14-day free trial"))
                        .accessibilityIdentifier("license.startTrial")
                } else if let denial = LicenseGate.trialDenialMessage(for: license.trialDenialReason) {
                    Label(denial, systemImage: "lock.fill")
                        .foregroundColor(DesignTokens.secondaryText)
                        .accessibilityLabel(Text(denial))
                } else if license.trialStartedAt.isEmpty && license.trialEndsAt.isEmpty {
                    Button("Start 14-day trial") { license.startTrial() }
                        .accessibilityLabel(Text("Start 14-day free trial"))
                        .accessibilityHint(Text("Unlocks Pro features for 14 days. Starts once — cannot be restarted after it expires."))
                        .accessibilityIdentifier("license.startTrial")
                } else {
                    Label("Trial expired — enter a key for Pro", systemImage: "lock.fill")
                        .foregroundColor(DesignTokens.secondaryText)
                        .accessibilityLabel(Text("Trial expired. Enter a license key for Pro."))
                }
                HStack {
                    TextField("ABCD-EF12-GH34-IJ56-KL78", text: $license.licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit { _ = license.activate(license.licenseKey) }
                        .accessibilityLabel(Text("License key"))
                        .accessibilityHint(Text("Five groups of four uppercase letters or digits, e.g. ABCD-EF12-GH34-IJ56-KL78."))
                        .accessibilityIdentifier("license.keyField")
                    Button("Activate") { _ = license.activate(license.licenseKey) }
                        .disabled(!LicenseGate.isWellFormedKey(license.licenseKey))
                        .accessibilityLabel(Text("Activate license key"))
                        .accessibilityIdentifier("license.activate")
                }
            }
        } header: {
            Text("License")
        } footer: {
            Text("FREE keeps every current feature. PRO unlocks scheduled reports, PDF report cards, and exports. Trials are bound to this Mac and verified online (internet needed to start). License keys validate offline.")
        }
        .id(SettingsSection.license.id)
        .onAppear { license.refreshTrialStatusInBackground() }
    }

    private var tierLabel: String {
        switch LicenseGate.effectiveTier(license) {
        case .Pro: "PRO"
        case .Trial: "TRIAL"
        case .Free: "FREE"
        }
    }

    // MARK: - About

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "NetMax Desktop \(version) (\(build))"
    }

    // MARK: Updates (task 2 — real GitHub Releases check)

    /// Release page the "Check for Updates…" row opens. Single source of
    /// truth lives on UpdateChecker (real repo, not the old github.com/netmax
    /// placeholder).
    static let releasesPageURL = UpdateChecker.releasesPageURL

    /// Build date from Info.plist (`NetMaxBuildDate`, stamped by
    /// build_app.sh). Falls back to the bundle version when the key is
    /// absent (dev runs via `swift run` have no generated plist).
    private var buildDateLine: String {
        let info = Bundle.main.infoDictionary
        if let raw = (info?["NetMaxBuildDate"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty {
            return "Built \(raw)"
        }
        if let build = info?["CFBundleVersion"] as? String, build != "?" {
            return "Build \(build)"
        }
        return "Development build"
    }

    /// Opens the releases page in the user's default browser.
    static func openReleasesPage() {
        if let url = URL(string: releasesPageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Update-check state (task 2)

    @State private var updateStatusMessage: String?
    @State private var updateStatusIsError = false
    @State private var isCheckingUpdate = false
    @State private var updateButtonTitle = "Check for Updates…"

    /// Button-triggered GitHub Releases check. Never claims "up to date"
    /// when the request failed — surfaces the error instead.
    private func checkForUpdates() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        updateButtonTitle = "Checking…"
        updateStatusMessage = nil
        Task {
            let outcome = await UpdateChecker.check()
            await MainActor.run {
                isCheckingUpdate = false
                updateButtonTitle = "Check for Updates…"
                if let err = outcome.errorMessage {
                    updateStatusMessage = err
                    updateStatusIsError = true
                } else if outcome.updateAvailable {
                    updateStatusMessage =
                        "Update available: \(outcome.latestVersion ?? "?") "
                        + "(you have \(outcome.currentVersion))."
                    updateStatusIsError = false
                    if let u = outcome.releaseURL ?? UpdateChecker.releaseURL(for: outcome.latestTag) {
                        NSWorkspace.shared.open(u)
                    }
                } else {
                    updateStatusMessage =
                        "You're up to date (\(outcome.currentVersion))."
                    updateStatusIsError = false
                }
            }
        }
    }

    /// W13B TEAM-UB / UB-5 (S-100): discussions board the feedback row
    /// opens. Real repo (was github.com/netmax/discussions placeholder).
    static let feedbackPageURL = UpdateChecker.feedbackPageURL

    /// Opens the GitHub Discussions page in the user's default browser.
    static func openFeedbackPage() {
        if let url = URL(string: feedbackPageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private var about: some View {
        Section {
            Text(versionLine)
                .font(.callout)
                .accessibilityLabel(Text(versionLine))

            Text("engine: 192 offline tests")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("engine: 192 offline tests"))

            // T3-c (W11-A-102): telemetry stance, stated in-app. Task 2
            // adds ONE optional network path: the button-triggered GitHub
            // Releases check below (no background polling).
            Text("Privacy: All data stays on this Mac. No telemetry. Updates check GitHub only when you press the button.")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("Privacy: all data stays on this Mac. No telemetry. Updates check GitHub only when you press the button."))

            // W13B UA-4 (S-079/S-080): the full "What leaves your Mac"
            // statement, as user-facing rows under a visible heading.
            //
            // AUDIT PROOF (grep counts, W13B honest-context wave; re-run to
            // re-verify and keep this honest):
            //   grep -rn "URLSession\|dataTask\|URLRequest" Sources/ \
            //     | grep -v SettingsView.swift | wc -l
            //     → 1 hit: UpdateChecker's button-triggered GitHub API call
            //       (no background polling, no telemetry).
            //   grep -rln "urlopen\|requests\." netmax.py netmetrics.py \
            //     netmax_netcontext.py | wc -l
            //     → 0: no Python HTTP client libraries anywhere.
            //   Engine outbound traffic lives in netmax.py: `curl` downloads
            //   from the speed-test endpoint list at the top of that file
            //   (speed.cloudflare.com, proof.ovh.net) and UDP DNS probes for
            //   the dns mode — exactly the endpoints a run tests against.
            Text("Your Privacy")
                .font(.caption.weight(.semibold))
                .accessibilityLabel(Text("Your Privacy"))
            Text("All measurement data stays on this Mac.")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("All measurement data stays on this Mac"))
            Text("No telemetry, no analytics, no tracking calls.")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("No telemetry, no analytics, no tracking calls"))
            Text("Only outbound connections: the speed-test and upload-test endpoints a run tests against (proof.ovh.net, speed.cloudflare.com for downloads; httpbin.org / postman-echo.com only when you run an upload probe), plus GitHub's Releases API when you press “Check for Updates…”.")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("Only outbound connections are the speed-test endpoints you choose to test against, plus GitHub Releases when you check for updates"))

            // T3-c (W11-A-101): grading rubric surfaced in-app.
            Text("Methodology: Grades use Waveform/DSLReports-style latency-under-load rubric.")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("Methodology: grades use a Waveform/DSLReports-style latency-under-load rubric."))

            // T3-c (W11-A-132): license posture, stated in-app.
            Text("Licenses: SwiftUI · Apple engines · no third-party runtime deps")
                .font(.callout)
                .foregroundColor(DesignTokens.secondaryText)
                .accessibilityLabel(Text("Licenses: SwiftUI, Apple engines, no third-party runtime dependencies"))

            // Task 2: real GitHub Releases check (button-triggered; no
            // background polling). Shows latest tag + opens the release page
            // when an update is available; honest error text when offline.
            Button {
                checkForUpdates()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateButtonTitle)
                        Text(buildDateLine)
                            .font(.caption)
                            .foregroundColor(DesignTokens.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .buttonStyle(.plain)
            .help("Queries GitHub Releases for the latest NetMax version (only when pressed)")
            .accessibilityLabel(Text("Check for updates"))
            .accessibilityHint(Text("Checks the NetMax GitHub Releases page for a newer version. Makes one network request only when pressed."))
            .accessibilityIdentifier("settings.checkForUpdates")

            if let msg = updateStatusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(updateStatusIsError ? DesignTokens.warning : DesignTokens.secondaryText)
                    .accessibilityLabel(Text(msg))
            }

            // W13B TEAM-UB / UB-5 (S-100): feedback link — Help-menu-style
            // row in About, opening GitHub Discussions in the browser.
            Button {
                Self.openFeedbackPage()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send Feedback…")
                        Text("Opens GitHub Discussions in your browser")
                            .font(.caption)
                            .foregroundColor(DesignTokens.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "envelope")
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .buttonStyle(.plain)
            .help("Share ideas or report issues on the NetMax discussions board")
            .accessibilityLabel(Text("Send feedback"))
            .accessibilityHint(Text("Opens the NetMax GitHub Discussions page in your browser so you can share ideas or report issues."))
            .accessibilityIdentifier("settings.sendFeedback")

            // N9: sanitized support bundle for crash/bug reports.
            Button {
                _ = SupportBundle.export()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export Support Bundle…")
                        Text("Zip with last 10 runs + versions — sanitized (no history dump, no SSID, no env)")
                            .font(.caption)
                            .foregroundColor(DesignTokens.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "archivebox")
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .buttonStyle(.plain)
            .help("Writes a sanitized diagnostics zip you can attach to a bug report")
            .accessibilityLabel(Text("Export support bundle"))
            .accessibilityHint(Text("Saves a zip containing the last 10 runs, app version, and platform info. Absolute paths, SSIDs, and secrets are redacted."))
            .accessibilityIdentifier("settings.exportSupportBundle")
        } header: {
            Text("About")
        } footer: {
            Text("Results reflect what your connection delivers right now — they vary with network conditions and don't guarantee peak speed.")
                .accessibilityLabel(Text("Honest limits: results reflect current conditions, vary with the network, and don't guarantee peak speed."))
        }
        .id(SettingsSection.about.id) // T4-a anchor
    }
    
    // Phase 5: Testimonials
    @ViewBuilder
    private var testimonialsSection: some View {
        Section {
            TestimonialsView()
        } header: {
            Label("Testimonials", systemImage: "bubble.left")
        }
    }
    
    // Phase 5: Analytics Dashboard
    @ViewBuilder
    private var analyticsSection: some View {
        Section {
            AnalyticsDashboard()
        } header: {
            Label("Analytics", systemImage: "chart.bar")
        }
    }
    
    // Phase 5: Changelog
    @ViewBuilder
    private var changelogSection: some View {
        Section {
            ChangelogView()
        } header: {
            Label("What's New", systemImage: "doc.text")
        }
    }
    
    // Phase 5: Backup & Recovery
    @ViewBuilder
    private var backupSection: some View {
        Section {
            BackupRecoveryView()
        } header: {
            Label("Backup & Recovery", systemImage: "externaldrive")
        }
    }
    
    // Phase 5: Subscription Management
    @ViewBuilder
    private var subscriptionSection: some View {
        Section {
            SubscriptionView()
        } header: {
            Label("Subscription", systemImage: "cart")
        }
    }
}

enum RemoteAIProviderLabel {
    static var current: String { resolve(ProcessInfo.processInfo.environment) }

    static func resolve(_ environment: [String: String]) -> String {
        switch environment["NETMAX_AI_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "claude": return "Anthropic"
        case "gemini": return "Gemini"
        case "deepseek": return "DeepSeek"
        case "groq": return "Groq"
        case "mistral": return "Mistral"
        case "openrouter": return "OpenRouter"
        case "ollama", "local": return "Ollama-compatible local server"
        case "llamacpp": return "llama.cpp local server"
        case "lmstudio": return "LM Studio local server"
        case "self-hosted": return "Self-hosted local server"
        default:
            let base = environment["NETMAX_AI_BASE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return base.isEmpty ? "OpenAI (default)" : "Custom endpoint"
        }
    }
}

enum RemoteAISettingsDisclosure {
    static let metricsFields = [
        "mode", "streams", "duration_seconds", "download_mbps", "upload_mbps",
        "latency_ms", "jitter_ms", "packet_loss_percent", "bufferbloat_grade",
        "sample_count", "dns_latency_ms",
    ]
    static var payloadSummary: String {
        "schema_version, analysis_id, and metrics: \(metricsFields.joined(separator: ", "))."
    }
    static let accessibilitySummary = "Exact remote AI fields: schema version, analysis identifier, " +
        "mode, stream count, duration, download and upload rates, latency, jitter, packet loss, " +
        "bufferbloat grade, sample count, and DNS latency."
    static let mcpConsent = "MCP clients cannot enable or override this preference. " +
        "Local analysis remains available when remote AI is off."
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
