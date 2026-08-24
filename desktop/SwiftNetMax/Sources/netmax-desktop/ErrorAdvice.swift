import Foundation

/// Maps engine failure strings (contract C1 envelopes, `error` field) to
/// human-readable advice + severity.
///
/// The bridge (`desktop/bridge/engine_bridge.py`) puts a ≤400-char stderr
/// tail into every failure envelope's `error` field; the engine itself
/// (`netmax.py`) raises `NetMaxError` messages that land there verbatim.
/// This file is a PURE mapper over those strings — no I/O, no engine, no
/// process spawning — so it is trivially unit-testable offline.
///
/// Known families (first match wins, case-insensitive substring):
///   1. Timeout kill        "engine timed out after Ns and was killed"   (bridge :199)
///   2. Argument range      "--seconds must be 5..30, got 99"            (netmax.py _checked)
///   3. Argument syntax     "invalid arguments: …"                       (bridge argparse :353)
///   4. Interpreter missing "[Errno 2] No such file or directory: …"     (bridge FileNotFoundError)
///   5. Endpoint blocked    "… returned error: 403", "Forbidden"         (CDN bot filtering)
///   6. DNS resolver down   "resolver unreachable/timed out/unfit",
///                          "no DNS resolver reachable"                  (netmax.py resolver probes)
///   7. Network unreachable "Could not resolve host", "Connection refused",
///                          "all speed endpoints failed", …              (curl / OS errors)
///   8. Slow endpoint       "curl exit 28"                               (time cap expired)
///
/// Anything unmatched gets an honest generic fallback asking the user to
/// send us the report — we never pretend to know what went wrong.

/// Coarse alarm level for a surfaced engine failure; meant for UI tinting.
enum AdviceSeverity: String, Equatable {
    /// User-fixable input or expected behavior — calm presentation.
    case info
    /// Environmental trouble (network, remote servers) — cautionary tone.
    case warning
    /// Local installation problem — nothing will run until it is fixed.
    case critical
}

/// One mapped diagnosis for an engine failure string.
struct EngineErrorAdvice: Equatable {
    /// Short category label, e.g. "Invalid setting".
    let headline: String
    /// One actionable, jargon-free sentence telling the user what to do.
    let advice: String
    /// How alarmed the UI should be.
    let severity: AdviceSeverity
    /// True when a known pattern matched; false for the generic fallback.
    let isKnown: Bool
    /// The literal substring that triggered the match (debug/test aid).
    let matchedOn: String?
}

enum ErrorAdvisor {

    // MARK: - Public API

    /// Map a raw engine/bridge error string to advice. Pure function.
    ///
    /// Accepts the C1 envelope's `error` value directly; nil/empty input
    /// yields the generic fallback rather than crashing or guessing.
    static func advice(for rawError: String?) -> EngineErrorAdvice {
        let haystack = (rawError ?? "").lowercased()
        guard !haystack.isEmpty else { return fallback() }

        for rule in rules {
            guard let hit = rule.keywords.first(where: { haystack.contains($0) }) else {
                continue
            }
            var suffix = ""
            if rule.parsesRange, let bounds = allowedRange(in: haystack) {
                suffix = " Allowed range: \(bounds.low)–\(bounds.high)."
            }
            return EngineErrorAdvice(
                headline: rule.headline,
                advice: rule.advice + suffix,
                severity: rule.severity,
                isKnown: true,
                matchedOn: hit
            )
        }
        return fallback()
    }

    /// Ready-to-display multi-line text: advice first, verbatim details last.
    ///
    /// Keeps the original error visible (never hides diagnostics) while
    /// leading with something a human can act on.
    static func displayText(for rawError: String?) -> String {
        let result = advice(for: rawError)
        var text = "\(result.headline) — \(result.advice)"
        if let raw = rawError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            text += "\n\nTechnical details: \(raw)"
        }
        return text
    }

    // MARK: - Rules (order matters: specific before general)

    private struct Rule {
        let id: String
        let keywords: [String]
        let headline: String
        let advice: String
        let severity: AdviceSeverity
        /// When true, extract a "low..high" range and append it to the advice.
        var parsesRange: Bool = false
    }

    private static let rules: [Rule] = [
        Rule(
            id: "timeout-kill",
            keywords: ["engine timed out after"],
            headline: "Test ran too long",
            advice: "The measurement engine hit its internal time limit and was "
                + "stopped. Try again, or use fewer streams or a shorter "
                + "duration so it can finish in time.",
            severity: .warning
        ),
        Rule(
            id: "arg-range",
            keywords: ["must be"],
            headline: "Setting out of range",
            advice: "One of the numeric fields is outside its allowed limits "
                + "(shown in the details). Adjust the value and run again.",
            severity: .info,
            parsesRange: true
        ),
        Rule(
            id: "arg-syntax",
            keywords: ["invalid arguments", "invalid choice", "usage:"],
            headline: "Invalid options",
            advice: "The options sent to the measurement engine were malformed. "
                + "This is usually a bug in the app — please report it if you "
                + "did not change any settings.",
            severity: .info
        ),
        Rule(
            id: "interpreter-missing",
            keywords: ["no such file or directory", "[errno 2]",
                       "could not launch engine"],
            headline: "Python not found",
            advice: "NetMax could not start its measurement engine because no "
                + "Python 3 interpreter was found. Install Python 3 (for "
                + "example from python.org or Homebrew), or point NetMax at an "
                + "existing interpreter in Settings.",
            severity: .critical
        ),
        Rule(
            id: "endpoint-blocked",
            keywords: ["403", "forbidden", "access denied", "blocked"],
            headline: "Test server refused us",
            advice: "A speed-test server is rejecting automated requests (CDN "
                + "bot filters do this). It usually clears on retry; trying a "
                + "different network or disabling a VPN can also help.",
            severity: .warning
        ),
        Rule(
            id: "dns-resolver-down",
            keywords: ["resolver timed out", "resolver unreachable",
                       "resolver unfit", "no dns resolver reachable"],
            headline: "Name lookup failed",
            advice: "None of the configured DNS resolvers answered, so domain "
                + "names can't be tested. Check your DNS settings and internet "
                + "connection, then run the test again.",
            severity: .warning
        ),
        Rule(
            id: "network-unreachable",
            keywords: ["unreachable", "could not resolve host",
                       "temporary failure in name resolution",
                       "failed to connect", "connection refused",
                       "network is down", "no route to host",
                       "all speed endpoints failed"],
            headline: "Network unreachable",
            advice: "Your Mac currently has no working route to the internet. "
                + "Check Wi-Fi or Ethernet, then run the test again.",
            severity: .warning
        ),
        Rule(
            id: "slow-endpoint",
            keywords: ["curl exit 28"],
            headline: "Servers too slow",
            advice: "Every test server stayed silent for the whole download "
                + "window. This can happen on very congested links — try again, "
                + "or pick a shorter duration.",
            severity: .info
        ),
    ]

    /// Honest fallback for unrecognized errors — never fabricates a cause.
    private static func fallback() -> EngineErrorAdvice {
        EngineErrorAdvice(
            headline: "Unexpected error",
            advice: "NetMax doesn't recognize this failure yet. The technical "
                + "details are kept below — if it keeps happening, please send "
                + "us this report so we can fix it.",
            severity: .warning,
            isKnown: false,
            matchedOn: nil
        )
    }

    // MARK: - Helpers

    /// First "low..high" integer pair in the text, for arg-range advice.
    private static let rangePattern = try! NSRegularExpression(
        pattern: "(\\d+)\\.\\.(\\d+)"
    )

    private static func allowedRange(in text: String) -> (low: Int, high: Int)? {
        let ns = text as NSString
        guard let match = rangePattern.firstMatch(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 3,
        let low = Int(ns.substring(with: match.range(at: 1))),
        let high = Int(ns.substring(with: match.range(at: 2))) else {
            return nil
        }
        return (low, high)
    }
}
