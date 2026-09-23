//
//  WifiPanelView.swift
//  netmax-desktop
//
//  ALPHA-A2-03 — Wi-Fi context panel.
//
//  Contracts honored here:
//    • C1/L2: engine invocation goes exclusively through `EngineClient.run(_:args:)`;
//      the wifi mode takes no flags (engine_bridge.py MODE_FLAGS["wifi"] == ()).
//    • P2: every successful check is appended via `HistoryStore.shared`
//      (append(mode:params:raw:)) — the same persistence path Mode Lab uses —
//      and the panel displays the LATEST wifi-mode record's `result_raw`.
//      HistoryStore.swift is owned by Lane B; this file consumes it only.
//    • P3: tab-hosted by ATLAS post-delivery; RootView/App/MenuBarView are
//      not edited here.
//

import SwiftUI

// >>> VERBATIM-BEGIN (model + parser; sliced verbatim into the /tmp parse check)

// MARK: - Model

/// One Wi-Fi snapshot decoded from a `wifi`-mode `result_raw`.
///
/// The engine prints bare `key: value` lines (`netmax.py`, wifi branch):
///     rssi_dbm: -52
///     noise_dbm: -89
///     channel: 36
/// The bridge wraps non-JSON stdout as `{"raw": "…"}` inside its envelope, so
/// the stored/passed-around text is either those lines directly or a
/// pretty-printed JSON object carrying them under `"raw"`. Both parse.
struct WifiReading: Equatable {
    let ssid: String?
    let channel: String?
    let rssiDbm: Int?
    let noiseDbm: Int?

    static let empty = WifiReading(ssid: nil, channel: nil, rssiDbm: nil, noiseDbm: nil)

    var isEmpty: Bool {
        ssid == nil && channel == nil && rssiDbm == nil && noiseDbm == nil
    }

    /// Plain-language link quality from RSSI (dBm). Thresholds follow the
    /// usual consumer-Wi-Fi rule of thumb: −50 dBm superb … −75 dBm marginal.
    var quality: SignalQuality {
        guard let rssi = rssiDbm else { return .unknown }
        if rssi >= -50 { return .excellent }
        if rssi >= -60 { return .good }
        if rssi >= -67 { return .fair }
        if rssi >= -75 { return .weak }
        return .poor
    }

    /// Number of filled indicator bars (0…4).
    var barLevel: Int {
        switch quality {
        case .unknown: 0
        case .poor: 1
        case .weak: 2
        case .fair: 3
        case .good, .excellent: 4
        }
    }

    /// Signal-to-noise gap in dB, when both ends are known.
    var snrDb: Int? {
        guard let rssi = rssiDbm, let noise = noiseDbm else { return nil }
        return rssi - noise
    }
}

/// Qualitative Wi-Fi link quality. Kept SwiftUI-free so the parser region
/// can be compiled standalone by the offline parse check.
enum SignalQuality: String {
    case unknown
    case poor
    case weak
    case fair
    case good
    case excellent

    var label: String {
        switch self {
        case .unknown: "No signal data"
        case .poor: "Poor"
        case .weak: "Weak"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }
}

// MARK: - Parser

enum WifiReadingParser {
    /// Parse any wifi-mode `result_raw` text into a reading.
    ///
    /// Accepted shapes, most specific first:
    ///   1. Bridge-wrapped stdout: pretty-printed `{"raw" : "rssi_dbm: …\n…"}`.
    ///   2. Bare `key: value` lines straight from `netmax.py wifi`.
    ///   3. Defensive: a JSON object exposing the fields directly.
    /// Anything else yields `.empty` — the caller shows its empty state.
    static func parse(_ raw: String) -> WifiReading {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }

        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = object as? [String: Any] {
                if let inner = dictionary["raw"] as? String,
                   !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return parseKeyValues(inner)
                }
                return reading(dictionary: dictionary)
            }
            // Valid JSON of another shape: fall through to the line scan,
            // which simply matches nothing and returns `.empty`.
        }
        return parseKeyValues(text)
    }

    /// Scan `key: value` lines; keys are matched case-insensitively and
    /// unknown lines are ignored, so engine additions never break parsing.
    static func parseKeyValues(_ text: String) -> WifiReading {
        var ssid: String?
        var channel: String?
        var rssi: Int?
        var noise: Int?

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: false,
                                   whereSeparator: { $0 == ":" })
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "ssid", "network_name", "network":
                ssid = value
            case "channel":
                channel = value
            case "rssi_dbm", "rssi", "signal_dbm", "signal_strength":
                rssi = intValue(value)
            case "noise_dbm", "noise":
                noise = intValue(value)
            default:
                break
            }
        }
        return WifiReading(ssid: ssid, channel: channel, rssiDbm: rssi, noiseDbm: noise)
    }

    /// Defensive path: envelope `data` exposed as fields instead of `raw`.
    private static func reading(dictionary: [String: Any]) -> WifiReading {
        func string(_ key: String) -> String? {
            (dictionary[key] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        func number(_ key: String) -> Int? {
            if let int = dictionary[key] as? Int { return int }
            if let double = dictionary[key] as? Double { return Int(double) }
            if let string = dictionary[key] as? String { return intValue(string) }
            return nil
        }
        return WifiReading(
            ssid: string("ssid"),
            channel: string("channel"),
            rssiDbm: number("rssi_dbm"),
            noiseDbm: number("noise_dbm"))
    }

    /// Leading signed integer out of values like `-52`, `-52 dBm`, `-52dBm`.
    static func intValue(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let direct = Int(trimmed) { return direct }
        var candidate = ""
        for character in trimmed {
            let isLeadingSign = character == "-" && candidate.isEmpty
            if character.isNumber || isLeadingSign {
                candidate.append(character)
            } else if !candidate.isEmpty {
                break
            }
        }
        return Int(candidate)
    }
}
// <<< VERBATIM-END

// MARK: - View

/// Wi-Fi context panel: shows the latest `wifi`-mode snapshot (channel,
/// RSSI, noise, SSID when reported) with signal-strength bars and a
/// plain-language quality word, plus a one-tap fresh check.
struct WifiPanelView: View {
    @State private var client = EngineClient()

    private enum Phase: Equatable {
        case idle            // showing whatever history holds
        case loading         // engine check in flight
        case failed(String)  // engine error surfaced verbatim
    }

    @State private var phase: Phase = .idle
    @State private var latest: HistoryRecord?

    private static let measuredAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 300)
        .onAppear(perform: reloadLatest)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi")
                .foregroundStyle(.blue)
            Text("Wi-Fi")
                .font(.headline)
            Spacer()
            Text("Context for your measurements")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wi-Fi context panel")
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Measuring…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Wi-Fi check running")

        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                runButton
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .accessibilityElement(children: .contain)

        case .idle:
            if let record = latest {
                let reading = WifiReadingParser.parse(record.resultRaw)
                if reading.isEmpty {
                    unparsableState
                } else {
                    readingCard(reading, measuredAt: record.ts)
                }
            } else {
                emptyState
            }
        }
    }

    /// History holds wifi runs but the newest payload carried nothing usable.
    private var unparsableState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Last check returned no Wi‑Fi details")
                .font(.headline)
            Text("The stored result couldn't be parsed. Run another check.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            runButton
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }

    /// Graceful empty state: no wifi run has ever been recorded.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No Wi‑Fi reading yet")
                .font(.headline)
            Text("Run a check to capture your current network's signal quality.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            runButton
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }

    // MARK: Reading card

    private func readingCard(_ reading: WifiReading, measuredAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                SignalBars(level: reading.barLevel, tint: qualityColor(reading.quality))
                    .accessibilityValue(reading.quality.label)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading.quality.label)
                        .font(.title3.weight(.semibold))
                    Text(rssiText(reading))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                runButton
            }

            Divider()

            detailRow("Network", reading.ssid ?? "—")
            detailRow("Channel", reading.channel ?? "—")
            detailRow("Noise", noiseText(reading))
            detailRow("Signal − noise", snrText(reading))

            Text("Measured \(Self.measuredAtFormatter.string(from: measuredAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: Controls

    private var runButton: some View {
        Button(action: runWifiCheck) {
            Label(phase == .loading ? "Checking…" : "Check Now",
                  systemImage: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.borderedProminent)
        .disabled(phase == .loading)
        .accessibilityLabel("Run Wi‑Fi check")
        .accessibilityHint("Runs the engine's wifi mode and shows the latest reading")
    }

    // MARK: Actions

    /// Latest wifi-mode record from the shared store (contract P2 surface).
    private func reloadLatest() {
        latest = HistoryStore.shared.loadAll().last { $0.mode == "wifi" }
    }

    private func runWifiCheck() {
        guard phase != .loading else { return }
        phase = .loading
        Task {
            do {
                // Contract C1: engine access only through EngineClient;
                // the wifi mode accepts no flags.
                let output = try await client.run("wifi")
                await MainActor.run {
                    // Contract P2: persist exactly like Mode Lab runs, then
                    // render from the store — one source of truth.
                    // C4: process() refreshes menu-bar + posts history-change.
                    let record = HistoryStore.shared.append(
                        mode: "wifi", params: [:], raw: output)
                    phase = .idle
                    reloadLatest()
                    RunPostProcessor.process(record)
                }
            } catch {
                await MainActor.run {
                    // Surfaces the envelope's error string verbatim
                    // (e.g. "no Wi-Fi network associated (Wi-Fi off or Ethernet)").
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Presentation helpers

    private func qualityColor(_ quality: SignalQuality) -> Color {
        switch quality {
        case .excellent, .good: .green
        case .fair: .yellow
        case .weak: .orange
        case .poor: .red
        case .unknown: .gray
        }
    }

    private func rssiText(_ reading: WifiReading) -> String {
        guard let rssi = reading.rssiDbm else { return "RSSI unavailable" }
        return "\(rssi) dBm RSSI"
    }

    private func noiseText(_ reading: WifiReading) -> String {
        guard let noise = reading.noiseDbm else { return "—" }
        return "\(noise) dBm"
    }

    private func snrText(_ reading: WifiReading) -> String {
        guard let snr = reading.snrDb else { return "—" }
        return "\(snr) dB"
    }
}

/// Ascending four-bar signal-strength indicator.
private struct SignalBars: View {
    let level: Int   // 0…4
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < level ? tint : Color(nsColor: .separatorColor))
                    .frame(width: 6, height: CGFloat(7 + index * 5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength")
    }
}

#Preview("Wi-Fi panel") {
    WifiPanelView()
}
