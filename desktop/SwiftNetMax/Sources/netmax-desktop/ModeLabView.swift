//
//  ModeLabView.swift
//  netmax-desktop
//
//  L3-A — Mode Lab: run ALL 10 engine modes from the UI with parameters.
//
//  Contracts honored here:
//    • C1/L2: engine invocation goes exclusively through `EngineClient.run(_:args:)`.
//      Args are forwarded as CLI flags (--streams N / --seconds N / --count N);
//      `engine_bridge.py` MODE_FLAGS whitelists them per mode, and this view
//      mirrors that table so controls are enabled only where the engine accepts them.
//    • P1: persisted defaults are read via `AppPreferences` ONLY (never
//      UserDefaults directly). NOTE: AppPreferences.swift is owned by Lane C;
//      this file consumes its contracted surface (`shared`,
//      `defaultStreams`/`defaultSeconds`/`defaultCount`) and does not modify it.
//    • P2: every successful run is appended via `HistoryStore.shared`
//      (`append(mode:params:raw:)`). HistoryStore.swift is owned by Lane B.
//    • P3: this view is tab-hosted by ATLAS post-delivery; RootView/App/
//      MenuBarView are not edited here.
//      (ALPHA-A4-06 attaches the A2-09 addendum at that host — see
//      RootView.swift.)
//    • ALPHA-A4-06: applied A2-09's three DEFERRED (Lane A) fixes in-file:
//      stepper rows keep the Stepper individually adjustable (row-level
//      .accessibilityElement(children: .ignore) removed), the decorative
//      header icon is hidden from VoiceOver, and run completion/failure is
//      announced via the NSAccessibility announcement channel.
//

import AppKit
import SwiftUI

// MARK: - Model

/// The tunable parameters the engine accepts across its modes.
/// Spelling matches `engine_bridge.py` `_FLAG_SPELLING` (CLI: --streams/--seconds/--count).
private enum ModeParameter: String, CaseIterable {
    case streams
    case seconds
    case count

    var cliFlag: String { "--\(rawValue)" }

    var label: String { rawValue.capitalized }

    /// Inclusive stepper range per the L3-A mission brief.
    /// (Tighter than the engine's own server-side validation — always valid.)
    var range: ClosedRange<Int> {
        switch self {
        case .streams: 2...16
        case .seconds: 5...30
        case .count: 5...50
        }
    }

    var accessibilityHint: String {
        switch self {
        case .streams: "Number of parallel connections used by this mode"
        case .seconds: "Duration of the test in seconds"
        case .count: "Number of probe samples"
        }
    }
}

/// One selectable engine mode. `flags` mirrors `engine_bridge.py` MODE_FLAGS:
/// only these parameters are ever sent for the mode; the rest stay disabled.
private struct ModeDefinition: Identifiable, Hashable {
    let id: String            // mode name passed to `run <mode>`
    let summary: String       // one-line description
    let flags: Set<ModeParameter>

    func supports(_ parameter: ModeParameter) -> Bool { flags.contains(parameter) }
}

private enum ModeCatalog {
    /// All ten C1 modes, in engine order, with one-line descriptions.
    static let modes: [ModeDefinition] = [
        ModeDefinition(id: "baseline", summary: "Single-stream download throughput.",
                       flags: [.seconds]),
        ModeDefinition(id: "turbo", summary: "N parallel streams — bigger share under load.",
                       flags: [.streams, .seconds]),
        ModeDefinition(id: "boost", summary: "Baseline vs turbo with gain percent.",
                       flags: [.streams, .seconds]),
        ModeDefinition(id: "dns", summary: "Ranks DNS resolvers by response time.",
                       flags: []),
        ModeDefinition(id: "bloat", summary: "Bufferbloat: latency under load, graded.",
                       flags: [.streams, .seconds]),
        ModeDefinition(id: "full", summary: "Everything — full suite plus verdict.",
                       flags: [.streams, .seconds]),
        ModeDefinition(id: "upload", summary: "Upload-speed probe (Mbps up).",
                       flags: [.seconds]),
        ModeDefinition(id: "loss", summary: "Packet-loss percent over repeated probes.",
                       flags: [.count]),
        ModeDefinition(id: "jitter", summary: "Jitter: mean consecutive RTT delta.",
                       flags: [.count]),
        ModeDefinition(id: "wifi", summary: "Wi-Fi RSSI, noise, and channel snapshot.",
                       flags: []),
    ]

    static func definition(for id: String) -> ModeDefinition {
        modes.first { $0.id == id } ?? modes[0]
    }
}

// MARK: - View

/// Mode Lab: pick one of the 10 engine modes, tune its supported parameters,
/// run it through the engine bridge, and inspect the JSON result payload.
struct ModeLabView: View {
    @State private var client = EngineClient()

    @State private var selectedModeID: String = ModeCatalog.modes[0].id
    @State private var streams = 8
    @State private var seconds = 10
    @State private var count = 10

    @State private var status: RunStatus = .idle
    @State private var resultText = ""

    private var selectedMode: ModeDefinition { ModeCatalog.definition(for: selectedModeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            modePicker
            Text(selectedMode.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Mode description")
                .accessibilityValue(selectedMode.summary)

            Divider()

            parameterSection

            runButton

            Divider()

            resultArea

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 520)
        .onAppear(perform: seedDefaultsFromPreferences)
        // ALPHA-A4-06 (A2-09 finding 12): idle→running→done/error was silent
        // to VoiceOver; announce terminal outcomes. (Single-parameter onChange
        // matches this package's macOS 13 platform floor.)
        .onChange(of: status) { newStatus in
            handleStatusAnnouncement(newStatus)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "dial.max.fill")
                .foregroundStyle(.blue)
                // ALPHA-A4-06 (A2-09 finding 2): purely decorative.
                .accessibilityHidden(true)
            Text("Mode Lab")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(status.label)
    }

    // MARK: Mode selection

    private var modePicker: some View {
        Picker("Mode", selection: $selectedModeID) {
            ForEach(ModeCatalog.modes) { mode in
                Text(mode.id).tag(mode.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(status == .running)
        .accessibilityLabel("Engine mode")
        .accessibilityValue(selectedModeID)
        .accessibilityHint("Choose one of the ten NetMax engine modes")
    }

    // MARK: Parameters

    /// Controls stay visible but are DISABLED for parameters the selected
    /// mode does not accept (mirrors engine_bridge.py MODE_FLAGS semantics),
    /// so layout is stable and unsupported knobs read clearly as inert.
    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            parameterStepper(.streams, value: $streams)
            parameterStepper(.seconds, value: $seconds)
            parameterStepper(.count, value: $count)
        }
    }

    private func parameterStepper(_ parameter: ModeParameter,
                                  value: Binding<Int>) -> some View {
        let supported = selectedMode.supports(parameter)
        let rowHint = supported
            ? parameter.accessibilityHint
            : "\(parameter.label) is not used by mode \(selectedMode.id)"
        return HStack {
            HStack {
                Text(parameter.label)
                    .frame(width: 70, alignment: .leading)
                Text("\(value.wrappedValue)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            // ALPHA-A4-06 (A2-09 finding 6, P0): the collapse-to-one-element
            // now covers ONLY the two static texts. The Stepper sits OUTSIDE
            // it, so VoiceOver keeps a separate adjustable element whose
            // increment/decrement actions work (previously the row-level
            // .ignore stripped them). Same label/value/hint contract as the
            // old collapsed row.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(parameter.label) value")
            .accessibilityValue("\(value.wrappedValue)")
            .accessibilityHint(rowHint)
            Stepper("\(parameter.label): \(value.wrappedValue)",
                    value: value,
                    in: parameter.range)
                .labelsHidden()
                .disabled(!supported || status == .running)
                .accessibilityHint(rowHint)
            if !supported {
                Text("not used by \(selectedMode.id)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // ALPHA-A4-06 (A2-09 finding 7): stays silent; the fact is
                    // conveyed by rowHint above.
                    .accessibilityHidden(true)
            }
        }
        .opacity(supported ? 1 : 0.55)
    }

    // MARK: Run

    private var runButton: some View {
        Button {
            runSelectedMode()
        } label: {
            Label(status == .running ? "Running…" : "Run",
                  systemImage: "play.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(status == .running)
        .accessibilityLabel("Run \(selectedModeID)")
        .accessibilityHint("Starts the selected engine mode with the chosen parameters and shows results below")
    }

    // MARK: Results

    private var resultArea: some View {
        TextEditor(text: Binding(
            get: { resultText.isEmpty ? "No results yet." : resultText },
            set: { _ in /* engine output — intentionally read-only */ }
        ))
        .font(.system(.caption, design: .monospaced))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .cornerRadius(6)
        .frame(minHeight: 200)
        .accessibilityLabel("Mode Lab results")
        .accessibilityValue(resultText.isEmpty ? "No results yet" : resultText)
    }

    // MARK: Actions

    private func runSelectedMode() {
        guard status != .running else { return }
        let mode = selectedMode
        let args = mappedArgs(for: mode)

        status = .running
        resultText = ""
        Task {
            do {
                let output = try await client.run(mode.id, args: args)
                await MainActor.run {
                    resultText = output
                    status = .done
                    appendHistory(mode: mode.id, params: parameterValues(for: mode), raw: output)
                }
            } catch {
                await MainActor.run {
                    // Surfaces the envelope's error string verbatim
                    // (EngineClientError.errorDescription).
                    resultText = "Error: \(error.localizedDescription)"
                    status = .error
                }
            }
        }
    }

    /// ALPHA-A4-06 (A2-09 finding 12): VoiceOver announcements for terminal
    /// run states. Public NSAccessibility surface only — no private state,
    /// no persistence (P1 still honored).
    private func handleStatusAnnouncement(_ newStatus: RunStatus) {
        switch newStatus {
        case .done:
            announceForVoiceOver("Mode Lab run finished successfully.")
        case .error:
            announceForVoiceOver("Mode Lab run failed. \(resultText)")
        case .idle, .running:
            break // start/idle transitions stay silent
        }
    }

    private func announceForVoiceOver(_ message: String) {
        guard let element = NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: element,
            // .announcement is macOS 14+; the package floors at macOS 13,
            // where the same announcement ships as .announcementRequested.
            notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
        )
    }

    /// CLI flags for the mode — only parameters its MODE_FLAGS entry allows.
    private func mappedArgs(for mode: ModeDefinition) -> [String] {
        var args: [String] = []
        if mode.supports(.streams) { args += [ModeParameter.streams.cliFlag, "\(streams)"] }
        if mode.supports(.seconds) { args += [ModeParameter.seconds.cliFlag, "\(seconds)"] }
        if mode.supports(.count) { args += [ModeParameter.count.cliFlag, "\(count)"] }
        return args
    }

    /// Structured params recorded alongside the raw payload (contract P2 shape).
    private func parameterValues(for mode: ModeDefinition) -> [String: Int] {
        var params: [String: Int] = [:]
        if mode.supports(.streams) { params["streams"] = streams }
        if mode.supports(.seconds) { params["seconds"] = seconds }
        if mode.supports(.count) { params["count"] = count }
        return params
    }

    /// Contract P2: every successful run is appended locally by the shared
    /// store (Lane B owns HistoryStore.swift); views only consume it here.
    private func appendHistory(mode: String, params: [String: Int], raw: String) {
        HistoryStore.shared.append(mode: mode, params: params, raw: raw)
    }

    /// Contract P1: seed the steppers from persisted preferences via
    /// AppPreferences ONLY (Lane C owns AppPreferences.swift — never touch
    /// UserDefaults directly from this file). Clamped defensively into the
    /// mission's stepper ranges so an out-of-band stored value can't wedge UI.
    private func seedDefaultsFromPreferences() {
        let prefs = AppPreferences.shared
        streams = min(max(prefs.defaultStreams, 2), 16)
        seconds = min(max(prefs.defaultSeconds, 5), 30)
        count = min(max(prefs.defaultCount, 5), 50)
    }
}

// MARK: - Status

/// File-private so it cannot collide with MenuBarView's RunStatus.
private enum RunStatus {
    case idle, running, done, error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running…"
        case .done: "Done"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: .gray
        case .running: .orange
        case .done: .green
        case .error: .red
        }
    }
}

#Preview("Mode Lab") {
    ModeLabView()
}
