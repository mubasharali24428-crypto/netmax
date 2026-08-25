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
//    • W13B TEAM-UB / UB-1 (S-013 + S-027): named presets ({name, mode,
//      streams, seconds, count} in the UserDefaults array `netmax.presets`,
//      saved through an NSAlert text input, loaded via the picker row) and
//      a boost→bloat Sequence toggle whose queued chain persists in
//      `netmax.sequences`. Cross-lane seam: W13B UA-1 added the network-
//      context probe below (`NetContextProbe`) and the UA-2 `network:` tag
//      on appendHistory — both left untouched here.
//

import AppKit
import SwiftUI

// MARK: - Presets & sequences (W13B UB-1)

/// One saved Mode Lab configuration (S-013).
/// Stored as JSON in the UserDefaults array `netmax.presets`; `count` rides
/// along so a preset restores the full working state.
struct ModePreset: Codable, Equatable, Identifiable {
    let name: String
    let mode: String
    var streams: Int
    var seconds: Int
    var count: Int

    var id: String { name }
}

/// Persistence behind UB-1: presets list + queued-sequence chain.
/// Foundation-only and pure over injected defaults so the round-trips are
/// self-checkable offline (see ModeLabTests at the bottom of this file).
enum PresetStore {
    static let presetsKey = "netmax.presets"
    /// Queued chains, e.g. [["boost","bloat"]] — a non-empty array means a
    /// sequence is armed and survives relaunch (S-027 "persist sequences").
    static let sequencesKey = "netmax.sequences"

    static func loadPresets(_ defaults: UserDefaults = .standard) -> [ModePreset] {
        guard let data = defaults.data(forKey: presetsKey),
              let presets = try? JSONDecoder().decode([ModePreset].self, from: data)
        else { return [] }
        return presets
    }

    static func savePresets(_ presets: [ModePreset], _ defaults: UserDefaults = .standard) {
        defaults.set((try? JSONEncoder().encode(presets)) ?? Data(), forKey: presetsKey)
    }

    /// The queued sequence chain (empty = no sequence armed).
    static func loadSequence(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: sequencesKey) ?? []
    }

    static func saveSequence(_ modes: [String], _ defaults: UserDefaults = .standard) {
        defaults.set(modes.isEmpty ? nil : modes, forKey: sequencesKey)
    }
}

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

    // W12 T4-c (audits 164/165): last session's mode + streams/seconds,
    // restored across launches. Key spellings come straight from the W12
    // brief (`netmax.state.lastMode/lastStreams/lastSeconds`); `count`
    // stays preference-seeded — it is not part of those keys.
    @AppStorage("netmax.state.lastMode") private var storedModeID = ""
    @AppStorage("netmax.state.lastStreams") private var storedStreams = 0
    @AppStorage("netmax.state.lastSeconds") private var storedSeconds = 0

    @State private var status: RunStatus = .idle
    @State private var resultText = ""

    // W13B UA-1 (S-048/S-049): honest network context, probed once when the
    // view appears and re-checked before each run. VPN/offline show a note
    // instead of letting the run produce misleading numbers or raw errors.
    @State private var netContext = NetContext(online: true, vpn: false)

    private var selectedMode: ModeDefinition { ModeCatalog.definition(for: selectedModeID) }

    /// W12 T4-b (audit 152): at this window width configuration and results
    /// sit side by side; below it they stack (the previous single-column look).
    static let sideBySideWidth: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 12) {
                header

                if geo.size.width >= Self.sideBySideWidth {
                    HStack(alignment: .top, spacing: 16) {
                        configColumn
                        Divider()
                        resultsColumn
                    }
                } else {
                    configColumn
                    Divider()
                    resultsColumn
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            seedDefaultsFromPreferences()
            // W13B UA-1: probe network context when Mode Lab opens…
            netContext = NetContextProbe.detect()
        }
        // ALPHA-A4-06 (A2-09 finding 12): idle→running→done/error was silent
        // to VoiceOver; announce terminal outcomes. (Single-parameter onChange
        // matches this package's macOS 13 platform floor.)
        .onChange(of: status) { newStatus in
            handleStatusAnnouncement(newStatus)
        }
        // W12 T4-c: persist the working mode + parameters for next launch.
        .onChange(of: selectedModeID) { storedModeID = $0 }
        .onChange(of: streams) { storedStreams = $0 }
        .onChange(of: seconds) { storedSeconds = $0 }
    }

    // MARK: Layout columns (W12 T4-b)

    /// Mode choice, parameters and Run button — left/top column in both
    /// layouts. Members unchanged from the single-column version.
    private var configColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            modeSummary
            networkContextNote // W13B UA-1
            Divider()
            parameterSection
            runButton
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// W13B UA-1 (S-048/S-049): amber VPN note or offline notice, shown in
    /// place of the Run affordance's blind spot — before any run starts.
    @ViewBuilder
    private var networkContextNote: some View {
        if !netContext.online {
            Label("You appear to be offline — measurement modes need a network connection.",
                  systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundColor(.red)
                .accessibilityLabel(Text("You appear to be offline"))
        } else if netContext.vpn {
            Label("VPN detected — results may reflect VPN routing.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundColor(.orange)
                .accessibilityLabel(Text("VPN detected"))
                .accessibilityValue(Text("Results may reflect VPN routing"))
        }
    }

    /// Engine output — right/bottom column in both layouts.
    private var resultsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            resultArea
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeSummary: some View {
        Text(selectedMode.summary)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Mode description")
            .accessibilityValue(selectedMode.summary)
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
        // T2-b (W11-A-011): descriptions are visible immediately under the
        // picker (pre-selection AND pre-run); the tooltip additionally makes
        // each mode's summary browsable without committing a selection.
        .help("Description of \(selectedMode.id): \(selectedMode.summary)")
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
        // T2-b (W11-A-012): the accepted range is printed right on the row,
        // before any validation error can teach it.
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
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
            Text(rangeCaption(for: parameter))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true) // range is already in rowHint above
        }
        .opacity(supported ? 1 : 0.55)
    }

    /// T2-b (W11-A-012): human range caption per parameter ("5–30 seconds").
    private func rangeCaption(for parameter: ModeParameter) -> String {
        switch parameter {
        case .streams:
            "\(parameter.range.lowerBound)–\(parameter.range.upperBound) parallel streams"
        case .seconds:
            "\(parameter.range.lowerBound)–\(parameter.range.upperBound) seconds"
        case .count:
            "\(parameter.range.lowerBound)–\(parameter.range.upperBound) probes"
        }
    }

    // MARK: Run

    private var runButton: some View {
        VStack(spacing: 6) {
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

            // T2-b (W11-A-013): long runs (the seconds parameter can reach
            // 30 s) get a visible in-progress cue instead of a silent wait.
            if status == .running && selectedMode.supports(.seconds) && seconds > 10 {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Run in progress")
            }
        }
    }

    // MARK: Results

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !droppedFlagNames.isEmpty {
                // W12 T1-d (W11-A-042): the bridge surfaces unsupported
                // per-mode flags in the envelope's `droppedFlags`; show an
                // honest inline note instead of leaving them invisible.
                Label(
                    "Measured without unsupported flags: \(droppedFlagNames.map { "--\($0)" }.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundColor(.orange)
                .accessibilityLabel(Text("Measured without unsupported flags"))
                .accessibilityValue(Text(droppedFlagNames.joined(separator: ", ")))
            }
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
    }

    /// W12 T1-d: flag names from the envelope's `droppedFlags` array, when
    /// `resultText` IS that envelope JSON. Any parse problem (non-JSON text,
    /// wrong shape, unexpected types) yields an empty array — the note stays
    /// silent rather than ever guessing. (Static + pure so it can be
    /// self-checked offline.)
    static func droppedFlags(in resultJSON: String) -> [String] {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let flags = dict["droppedFlags"] else { return [] }
        guard let names = flags as? [String] else { return [] }
        return names.filter { !$0.isEmpty }
    }

    /// Names to show for the current result payload.
    private var droppedFlagNames: [String] {
        status == .done ? Self.droppedFlags(in: resultText) : []
    }

    // MARK: Actions

    private func runSelectedMode() {
        guard status != .running else { return }
        // W13B UA-1: fresh probe right before running, so a network drop
        // since onAppear is caught. Offline ⇒ honest note instead of raw
        // engine errors; VPN ⇒ the amber note refreshes for this run.
        netContext = NetContextProbe.detect()
        guard netContext.online else {
            resultText = "You appear to be offline — reconnect and try again."
            status = .error
            return
        }
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
    /// W13B UA-2: the run is tagged with its network name when it can be
    /// determined — nil otherwise, so nothing is ever guessed.
    private func appendHistory(mode: String, params: [String: Int], raw: String) {
        HistoryStore.shared.append(mode: mode, params: params, raw: raw,
                                   network: NetContextProbe.currentNetworkName())
    }

    /// Contract P1: seed the steppers from persisted preferences via
    /// AppPreferences ONLY (Lane C owns AppPreferences.swift — never touch
    /// UserDefaults directly from this file). Clamped defensively into the
    /// mission's stepper ranges so an out-of-band stored value can't wedge UI.
    ///
    /// W12 T4-c: on top of the preference defaults, the last working state is
    /// restored — mode from `netmax.state.lastMode`, streams/seconds from
    /// `lastStreams`/`lastSeconds` (validated against the catalog/ranges so a
    /// stale key can't select an unknown mode or wedge a stepper).
    private func seedDefaultsFromPreferences() {
        let prefs = AppPreferences.shared
        streams = min(max(prefs.defaultStreams, 2), 16)
        seconds = min(max(prefs.defaultSeconds, 5), 30)
        count = min(max(prefs.defaultCount, 5), 50)

        if storedStreams >= 2 && storedStreams <= 16 {
            streams = storedStreams
        }
        if storedSeconds >= 5 && storedSeconds <= 30 {
            seconds = storedSeconds
        }
        if ModeCatalog.modes.contains(where: { $0.id == storedModeID }) {
            selectedModeID = storedModeID
        }
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
