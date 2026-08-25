//
//  ScheduleEditorView.swift
//  netmax-desktop
//
//  ALPHA-A1-02 (wave-1) — schedule editor UI.
//
//  Edits the scheduled auto-test settings persisted under the lane-private
//  `netmax.schedule.*` keys (owned by Scheduler.swift, ALPHA-A1-01):
//
//      netmax.schedule.enabled          Bool    default false
//      netmax.schedule.intervalMinutes  Int     default 60, clamped 5...1440
//
//  Coupling policy (mission A1-02): this view consumes ONLY `Scheduler.shared`'s
//  small public surface (`isEnabled`, `intervalMinutes`, `config`,
//  `nextFireDate`) — no protocol, no direct UserDefaults access, matching
//  Scheduler.swift's rule that sibling lanes go through the facade. Editing
//  happens on local draft state; **Save** is what commits (and therefore what
//  writes the two keys above via Scheduler's persisting didSet).
//
//  UX follows the L3 conventions (SettingsView/ModeLabView): grouped Form,
//  honest-limits footers, semantic colors only. Every control carries an
//  accessibilityLabel (+ hint where the effect isn't obvious) and stable
//  accessibility identifiers. The summary line refreshes itself on a 30 s
//  timeline so a parked window never shows a stale countdown.
//

import SwiftUI

struct ScheduleEditorView: View {

    /// Facade over `netmax.schedule.*`; assignments here persist immediately
    /// and re-clamp, so Save only ever writes valid values.
    @ObservedObject private var scheduler = Scheduler.shared

    // MARK: Draft state (committed only on Save)

    @State private var draftEnabled = false
    @State private var draftIntervalMinutes = ScheduleFallbacks.intervalMinutes

    /// Seeded exactly once per presentation so re-appearing (tab switches,
    /// sheet re-present) shows persisted truth instead of stale edits.
    @State private var seededFromScheduler = false

    // MARK: Constants

    /// Cadence choices offered by the picker (minutes). All inside
    /// `ScheduleLimits.intervalMinutes` (5...1440).
    private static let intervalChoices = [5, 15, 30, 60]

    // MARK: Body

    var body: some View {
        Form {
            enableSection
            intervalSection
            summarySection
            glossarySection
            commitSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360)
        .accessibilityIdentifier("schedule.editor")
        .onAppear(perform: seedDraftFromSchedulerIfNeeded)
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle("Scheduled checks", isOn: $draftEnabled)
                .accessibilityLabel(Text("Scheduled checks"))
                .accessibilityValue(Text(draftEnabled ? "On" : "Off"))
                .accessibilityHint(Text("When on, a connection test runs automatically at the chosen interval."))
                .accessibilityIdentifier("schedule.enableToggle")
        } header: {
            Text("Automatic Testing")
        } footer: {
            Text("NetMax runs one measurement pass in the background on this cadence.")
        }
    }

    private var intervalSection: some View {
        Section {
            // W11 fix #4: presets + fine-tune stepper with human units.
            // Covers 5 min…24 h so "every 90 minutes" or "every 2 hours"
            // needs no workaround.
            Picker("Check every", selection: $draftIntervalMinutes) {
                ForEach(Self.intervalChoices, id: \.self) { minutes in
                    Text(Self.intervalLabel(minutes)).tag(minutes)
                }
                if !Self.intervalChoices.contains(draftIntervalMinutes) {
                    Text(Self.intervalLabel(draftIntervalMinutes)).tag(draftIntervalMinutes)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Check interval"))
            .accessibilityValue(Text(Self.intervalLabel(draftIntervalMinutes)))
            .accessibilityHint(Text("How often the automatic check runs. Applies when you press Save."))
            .accessibilityIdentifier("schedule.intervalPicker")

            Stepper {
                Text("Custom: \(Self.intervalLabel(draftIntervalMinutes))")
                    .font(.callout)
            } onIncrement: {
                draftIntervalMinutes = min(draftIntervalMinutes + 5, 1440)
            } onDecrement: {
                draftIntervalMinutes = max(draftIntervalMinutes - 5, 5)
            }
            .accessibilityLabel(Text("Fine-tune interval in 5-minute steps"))
        } header: {
            Text("Cadence")
        } footer: {
            Text("Presets and the stepper set any cadence from 5 minutes to 24 hours. After enabling, the first check waits one full interval — nothing fires the moment you save.")
        }
    }

    /// W11 fix #4: human units — hours shown as hours, never "1440 minutes".
    private static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "1 hour"
        case 90: return "1½ hours"
        case let m where m >= 60 && m % 60 == 0:
            return "\(m / 60) hours"
        case let m where m >= 60:
            let h = m / 60, rem = m % 60
            return rem == 30 ? "\(h)½ hours" : "\(h) h \(rem) m"
        default:
            return "\(minutes) minutes"
        }
    }

    /// Live countdown against the SAVED schedule (not the draft), kept fresh
    /// by a 30 s timeline tick; the underlying next-fire instant is fixed,
    /// so re-rendering alone keeps the "~Nm" figure accurate.
    private var summarySection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(scheduler.isEnabled ? .primary : .secondary)
                    .accessibilityLabel(Text(summaryText))
                    .accessibilityIdentifier("schedule.summary")
            }
        } header: {
            Text("Status")
        }
    }

    /// T2-d (W11-A-031/032): the background runner speaks launchd — "plist",
    /// "loaded", "unload" are macOS plumbing jargon. This glossary lives in
    /// the same Schedule tab so the terms decode where users meet them.
    /// (BackgroundRunnerControlsView.swift itself is outside this lane's
    /// owned paths; these rows cover its vocabulary.)
    private var glossarySection: some View {
        Section {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("plist").font(.callout)
                    Text("A settings file launchd reads to know what to run and when.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help("plist: a small settings file on disk. NetMax installs one so "
                + "launchd can relaunch the background checker even after a reboot.")

            HStack {
                Image(systemName: "bolt.horizontal")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loaded / unloaded status").font(.callout)
                    Text("Whether macOS has registered (loaded) the agent right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help("Loaded means macOS launchd currently has the agent registered "
                + "and will honor its schedule; not loaded means it is installed "
                + "on disk but dormant until you press Update Agent.")

            HStack {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install / remove").font(.callout)
                    Text("Installs or deletes that plist file; removing stops automatic runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help("Install writes the plist and registers it with launchd "
                + "(idempotent — safe to press again). Remove unloads the agent "
                + "and deletes the file; scheduled checks stop until reinstalled.")
        } header: {
            Text("Background runner terms")
        } footer: {
            Text("Hover any row for details. The agent itself is managed under Background Test Runner.")
        }
    }

    private var commitSection: some View {
        Section {
            if hasUnsavedChanges {
                Label("Unsaved changes", systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Unsaved changes"))
            }
            Button {
                save()
            } label: {
                Text(hasUnsavedChanges ? "Save" : "Saved")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges)
            .accessibilityLabel(Text("Save schedule"))
            .accessibilityHint(Text("Writes the enabled flag and interval for scheduled checks."))
            .accessibilityIdentifier("schedule.saveButton")
        }
    }

    // MARK: - Derived state

    /// True when the draft differs from the persisted schedule.
    private var hasUnsavedChanges: Bool {
        draftEnabled != scheduler.isEnabled ||
        draftIntervalMinutes != scheduler.intervalMinutes
    }

    /// Human summary of the persisted schedule, e.g. "Next check in ~12m".
    /// Disabled (or no known fire time yet) reads plainly instead.
    private var summaryText: String {
        guard scheduler.isEnabled, let next = scheduler.nextFireDate else {
            return "Scheduled checks are off."
        }
        let minutes = max(1, Int((next.timeIntervalSinceNow / 60).rounded(.up)))
        return "Next check in ~\(minutes)m"
    }

    // MARK: - Actions

    /// Copy persisted truth into the draft (once per presentation).
    private func seedDraftFromSchedulerIfNeeded() {
        guard !seededFromScheduler else { return }
        seededFromScheduler = true
        draftEnabled = scheduler.isEnabled
        draftIntervalMinutes = Self.nearestChoice(to: scheduler.intervalMinutes)
    }

    /// Persisted intervals may sit outside the picker's four choices (the
    /// store allows 5...1440); snap the draft to the nearest offered cadence
    /// so the picker never shows a blank selection.
    private static func nearestChoice(to minutes: Int) -> Int {
        intervalChoices.min(by: { abs($0 - minutes) < abs($1 - minutes) })
            ?? ScheduleFallbacks.intervalMinutes
    }

    /// COMMIT POINT: pushes the draft through `Scheduler.shared`, whose
    /// persisting didSet writes exactly
    /// `netmax.schedule.enabled` and `netmax.schedule.intervalMinutes`.
    /// Interval first, so enabling lands with its final cadence.
    private func save() {
        scheduler.intervalMinutes = ScheduleConfig.clampedInterval(draftIntervalMinutes)
        scheduler.isEnabled = draftEnabled
    }
}

#if DEBUG
struct ScheduleEditorView_Previews: PreviewProvider {
    static var previews: some View {
        ScheduleEditorView()
    }
}
#endif
