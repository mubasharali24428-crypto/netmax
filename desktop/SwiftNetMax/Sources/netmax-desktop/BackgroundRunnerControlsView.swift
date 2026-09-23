// AUDIT M9: not mounted in production — wire or remove deliberately.

//
//  BackgroundRunnerControlsView.swift
//  netmax-desktop
//
//  ALPHA-A4-03 (wave-3 W3c) — system-level background test runner controls.
//
//  A single GroupBox section exposing `BackgroundRunner` (launchd agent,
//  label `com.netmax.desktop.runner`) to the user:
//
//      • status line   — installed / not installed plus the live launchd
//                        load state (and PID while a run is active), from
//                        `BackgroundRunner.status()`;
//      • Install/Update— writes the plist and bootstraps it into the user's
//                        GUI launchd session using the SAVED cadence,
//                        `Scheduler.shared.intervalMinutes`, read at press
//                        time;
//      • Remove        — unloads the job and deletes its plist, behind a
//                        confirmation dialog;
//      • last-error    — the most recent failure, verbatim and selectable.
//
//  Every mutating path is async with a busy indicator; buttons disable for
//  the duration so operations cannot stack. Nothing is persisted here — the
//  view is pure control surface over BackgroundRunner + Scheduler.
//
//  INTEGRATION (Schedule tab wiring lane): drop-in section control. Place it
//  below `ScheduleEditorView` inside the tab's grouped Form:
//
//      Form {
//          ScheduleEditorView()
//          BackgroundRunnerControlsView()
//      }
//      .formStyle(.grouped)
//
//  It is self-contained (own status polling via .task, busy flags, error
//  surface) and needs no parameters. Install always uses the committed
//  schedule, not any unsaved editor draft — save cadence edits first so the
//  agent matches what the editor displays. Dev/direct-download builds only:
//  per BackgroundRunner's sandbox note, a sandboxed app cannot register
//  LaunchAgents, so gate exposure on non-sandboxed distribution.
//
//  UX follows the L3 conventions (ScheduleEditorView): semantic colors only,
//  every control carries an accessibilityLabel (+ hint where the effect
//  isn't obvious) and a stable accessibility identifier under "runner.*".
//

import SwiftUI

struct BackgroundRunnerControlsView: View {

    /// Read-only consumption of the saved cadence (`netmax.schedule.*`,
    /// owned by Scheduler.swift); observed so the hints track edits made in
    /// `ScheduleEditorView` on the same screen.
    @ObservedObject private var scheduler = Scheduler.shared

    // MARK: State

    /// Latest snapshot from `BackgroundRunner.status()`; nil until the first
    /// poll completes (buttons stay disabled meanwhile).
    @State private var status: BackgroundRunner.Status?

    /// User-presentable detail for the most recent failed operation.
    @State private var lastError: String?

    /// The long-running operation currently in flight, if any.
    @State private var busyOperation: Operation?

    /// Presents the remove confirmation dialog.
    @State private var showingRemoveConfirmation = false

    /// Mutations this view performs, used to key busy indicators.
    private enum Operation {
        case installing
        case removing
    }

    // MARK: Body

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                statusSection
                actionSection
                if let lastError {
                    errorSection(lastError)
                }
                cadenceFootnote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Background Test Runner", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Background test runner controls"))
        .accessibilityIdentifier("runner.controls")
        .task { await refreshStatus() }
        .confirmationDialog(
            "Remove the background test runner?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await performRemove() }
            }
            .accessibilityIdentifier("runner.removeConfirmButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent is unloaded from launchd and its plist is deleted. Automatic background checks stop until you install it again.")
        }
    }

    // MARK: - Sections

    /// Installed / loaded line with a semantic status glyph; shows a spinner
    /// until the first status poll lands.
    @ViewBuilder
    private var statusSection: some View {
        if let status {
            HStack(spacing: 6) {
                Image(systemName: statusGlyph(for: status).icon)
                    .foregroundStyle(statusGlyph(for: status).color)
                Text(statusLine(for: status))
                    .font(.callout)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(statusLine(for: status)))
            .accessibilityIdentifier("runner.status")
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking agent status…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Checking agent status"))
            .accessibilityIdentifier("runner.status")
        }
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            Button {
                Task { await performInstall() }
            } label: {
                if busyOperation == .installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installing…")
                    }
                } else {
                    Text(installTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || status == nil)
            .accessibilityLabel(Text(installTitle == "Update Agent"
                                     ? "Update background runner"
                                     : "Install background runner"))
            .accessibilityHint(Text(installHint))
            .accessibilityIdentifier("runner.installButton")

            Button(role: .destructive) {
                showingRemoveConfirmation = true
            } label: {
                if busyOperation == .removing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Removing…")
                    }
                } else {
                    Text("Remove")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || !isRemovable)
            .accessibilityLabel(Text("Remove background runner"))
            .accessibilityHint(Text("Asks for confirmation, then unloads the launchd agent and deletes its plist."))
            .accessibilityIdentifier("runner.removeButton")

            Spacer()
        }
    }

    /// The failing operation's own detail, kept selectable so support can
    /// copy it out of the window.
    private func errorSection(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Last error: \(message)"))
        .accessibilityIdentifier("runner.lastError")
    }

    private var cadenceFootnote: some View {
        Text("Runs one connection test every \(scheduler.intervalMinutes) minutes via launchd, using the saved schedule cadence.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("runner.cadenceFootnote")
    }

    // MARK: - Derived state

    /// Any mutation in flight disables the whole action row.
    private var isBusy: Bool { busyOperation != nil }

    /// There is something to remove only if a plist or a live registration
    /// exists (uninstall of neither succeeds quietly anyway).
    private var isRemovable: Bool {
        guard let status else { return false }
        return status.plistInstalled || status.loaded
    }

    /// Fresh installs say Install; an existing plist means the button
    /// replaces the current registration (idempotent reinstall).
    private var installTitle: String {
        (status?.plistInstalled ?? false) ? "Update Agent" : "Install Agent"
    }

    private var installHint: String {
        installTitle == "Update Agent"
            ? "Replaces the installed launchd agent so the new \(scheduler.intervalMinutes)-minute cadence applies."
            : "Installs a launchd agent that runs a connection test every \(scheduler.intervalMinutes) minutes."
    }

    private func statusLine(for status: BackgroundRunner.Status) -> String {
        var parts = [
            status.plistInstalled ? "Agent installed" : "Agent not installed",
            status.loaded ? "loaded in launchd" : "not loaded"
        ]
        if let pid = status.activePID { parts.append("running (pid \(pid))") }
        return parts.joined(separator: ", ") + "."
    }

    private func statusGlyph(
        for status: BackgroundRunner.Status
    ) -> (icon: String, color: Color) {
        if status.loaded {
            return ("checkmark.circle.fill", .green)
        }
        if status.plistInstalled {
            // On disk but not registered — likely needs Update to reload.
            return ("exclamationmark.triangle", .orange)
        }
        return ("circle.slash", .secondary)
    }

    // MARK: - Actions

    /// Re-read launchd/on-disk truth into the status line.
    private func refreshStatus() async {
        status = await BackgroundRunner.status()
    }

    /// Install (or idempotently replace) the agent at the SAVED cadence.
    /// Busy flag spans the operation and the follow-up status refresh.
    private func performInstall() async {
        busyOperation = .installing
        defer { busyOperation = nil }
        do {
            _ = try await BackgroundRunner.install(
                interval: TimeInterval(scheduler.intervalMinutes) * 60
            )
            lastError = nil
        } catch {
            record(error)
        }
        await refreshStatus()
    }

    /// Unload + delete the agent. Removing an absent agent succeeds quietly
    /// (mirrors BackgroundRunner.uninstall).
    private func performRemove() async {
        busyOperation = .removing
        defer { busyOperation = nil }
        do {
            try await BackgroundRunner.uninstall()
            lastError = nil
        } catch {
            record(error)
        }
        await refreshStatus()
    }

    private func record(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}

#if DEBUG
struct BackgroundRunnerControlsView_Previews: PreviewProvider {
    static var previews: some View {
        BackgroundRunnerControlsView()
            .padding()
    }
}
#endif
