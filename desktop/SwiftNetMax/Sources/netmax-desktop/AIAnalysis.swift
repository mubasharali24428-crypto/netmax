import Foundation

/// Catalogue and invocation for the engine's AI analysis layer.
///
/// The engine exposes 22 analysers via `netmax ai --analysis NAME --input JSON`
/// and the bridge forwards that as `run ai --analysis ... --input ...`. This
/// type owns three things: which analyses are worth surfacing to a person,
/// how to encode their input, and how to read the result back.
///
/// Decoding note: results are parsed with `JSONSerialization` rather than
/// `Decodable` structs. The analysers return deliberately different shapes
/// per analysis, and a typed struct per shape would be a second schema to
/// keep in step with the Python side — the wrong place to add a hard
/// failure for a UI that only needs to display the result.
enum AIAnalysis {

    // MARK: - Catalogue

    /// One user-facing analysis.
    // Not Hashable: `makeInput` is a closure. Identifiable is enough
    // for ForEach, and SwiftUI does not require value equality here.
    struct Entry: Identifiable {
        let name: String
        let title: String
        let blurb: String
        /// Builds the `--input` object from measurements the app already has.
        let makeInput: ([String: Any]) -> [String: Any]
        /// Analyses that need more than a metrics bundle are excluded here;
        /// they are reachable from `netmax ai` and the MCP `ai_analyze` tool.
        let needsHistory: Bool

        var id: String { name }
    }

    /// The analyses offered in the UI, in display order.
    ///
    /// Deliberately a subset of the engine's 22: these are the ones that
    /// answer a question from a single run's measurements. Anything needing
    /// a multi-day history, a cohort, or a plan rate belongs behind an
    /// explicit control rather than firing off a request.
    static let catalogue: [Entry] = [
        Entry(
            name: "root_cause",
            title: "Why is it slow?",
            blurb: "Ranks the likely causes and what to do about each.",
            makeInput: { $0 },
            needsHistory: false
        ),
        Entry(
            name: "explain",
            title: "What this means",
            blurb: "Puts the numbers in wall-clock terms, in plain words.",
            makeInput: { $0 },
            needsHistory: false
        ),
        Entry(
            name: "loss_pattern",
            title: "Loss pattern",
            blurb: "Random, burst or periodic — each has a different fix.",
            makeInput: { ["events": ($0["loss_events"] as? [[String: Any]]) ?? []] },
            needsHistory: false
        ),
        Entry(
            name: "jitter_attribution",
            title: "Jitter source",
            blurb: "Splits jitter across the WiFi hop, the ISP path and the endpoint.",
            makeInput: { [
                "gateway_ms": $0["gateway_latency_ms"] ?? NSNull(),
                "internet_ms": $0["internet_latency_ms"] ?? NSNull(),
            ] },
            needsHistory: false
        ),
        Entry(
            name: "wifi_advice",
            title: "WiFi tuning",
            blurb: "Channel, band and placement advice from the current reading.",
            makeInput: { $0 },
            needsHistory: false
        ),
        Entry(
            name: "dns_strategy",
            title: "DNS strategy",
            blurb: "Ranks resolvers on latency and notes what switching is worth.",
            makeInput: { ["resolvers": ($0["resolvers"] as? [[String: Any]]) ?? []] },
            needsHistory: false
        ),
    ]

    static func entry(named name: String) -> Entry? {
        catalogue.first { $0.name == name }
    }

    // MARK: - Invocation

    enum Failure: LocalizedError {
        case badInput(String)
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .badInput(let detail): return detail
            case .engine(let detail): return detail
            }
        }
    }

    /// Encode an input object for `--input`. Failure here is a programming
    /// error in `makeInput`, not user error, so it is surfaced plainly.
    static func encode(_ input: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input),
              let text = String(data: data, encoding: .utf8)
        else {
            throw Failure.badInput("Could not encode the analysis input.")
        }
        return text
    }

    /// Run one analysis through the bridge and return the parsed result.
    static func run(_ entry: Entry,
                    input: [String: Any],
                    client: EngineClient = EngineClient()) async throws -> [String: Any] {
        let payload = try encode(entry.makeInput(input))
        let raw = try await client.run("ai", args: [
            "--analysis", entry.name,
            "--input", payload,
        ])
        return try parse(raw)
    }

    /// Parse the engine's pretty-printed data object.
    static func parse(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            throw Failure.engine("The analysis returned something unreadable.")
        }
        return dict
    }

    // MARK: - Metrics bundle

    /// Build the analysis input from what the dashboard already extracted.
    ///
    /// Only values we actually measured are included — a key that is absent
    /// is passed as absent, not as zero. The analyser's own rules check for
    /// presence, so a missing jitter must not read as "0 ms jitter".
    static func metricsBundle(from m: DashboardMetrics) -> [String: Any] {
        var bundle: [String: Any] = [:]
        if let mbps = m.speed?.value { bundle["mbps"] = mbps }
        if let percent = m.loss?.value { bundle["loss_pct"] = percent }
        if let grade = m.bloatGrade {
            bundle["bloat_grade"] = grade.letter
            if let delta = grade.deltaMs { bundle["bloat_delta_ms"] = delta }
        }
        return bundle
    }

    /// True when there is nothing to analyse yet.
    static func isEmpty(_ input: [String: Any]) -> Bool {
        input.isEmpty
    }

    // MARK: - Result reading

    /// Headline sentence, whichever key this analysis happens to use.
    static func headline(_ result: [String: Any]) -> String? {
        for key in ["headline", "summary", "verdict", "dominant", "pattern",
                    "recommended", "goal"] {
            if let text = result[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// Bullet lines, merged across the keys the analysers use.
    static func bullets(_ result: [String: Any]) -> [String] {
        var out: [String] = []
        for key in ["statements", "notes", "advice", "evidence", "fixes"] {
            if let list = result[key] as? [Any] {
                out += list.compactMap { $0 as? String }
            }
        }
        if let single = result["reasoning"] as? String, !single.isEmpty {
            out.append(single)
        }
        return out
    }

    /// Caveats the analyser flagged — things the user must not miss.
    static func caveats(_ result: [String: Any]) -> [String] {
        (result["caveats"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Ranked causes, when the result carries them.
    static func causes(_ result: [String: Any]) -> [[String: Any]] {
        (result["causes"] as? [[String: Any]]) ?? []
    }

    /// Whether the analysis came from the model or from local heuristics.
    static func source(_ result: [String: Any]) -> String {
        (result["source"] as? String) ?? "local"
    }

    /// True when the engine refused to attribute a cause, or ran on too
    /// little data. The UI says so rather than showing an empty verdict.
    static func isInconclusive(_ result: [String: Any]) -> Bool {
        let markers = ["insufficient_data", "unknown", "unresolved", "none"]
        if let verdict = result["verdict"] as? String, markers.contains(verdict) {
            return true
        }
        if let confidence = result["confidence"] as? String, confidence == "none" {
            return true
        }
        // A result carrying no answer at all is the dangerous case: it
        // would otherwise render as a confident, empty card. Anything with
        // a headline or a ranked cause is a real answer.
        let causes = (result["causes"] as? [[String: Any]]) ?? []
        let hasAnswer = result["headline"] != nil
            || result["summary"] != nil
            || result["verdict"] != nil
            || result["confidence"] != nil
            || !causes.isEmpty
        return !hasAnswer
    }
}