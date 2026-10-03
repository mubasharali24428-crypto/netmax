import Foundation

/// Offline self-checks for the AI analysis surface.
///
/// Pure: no engine spawn, no network. These pin the parts that can rot
/// silently — the catalogue drifting from the engine, and the result
/// readers quietly returning nothing when a key changes shape.
enum AIAnalysisTests {

    @discardableResult
    static func runAll() -> Int {
        var failures = 0

        func expect(_ condition: Bool, _ label: String) {
            if condition { print("PASS \(label)") }
            else { failures += 1; print("FAIL \(label)") }
        }

        // ── catalogue ──────────────────────────────────────────────────────
        do {
            let names = AIAnalysis.catalogue.map(\.name)
            expect(!names.isEmpty, "catalogue is not empty")
            expect(Set(names).count == names.count, "catalogue names are unique")
            expect(AIAnalysis.catalogue.allSatisfy { !$0.blurb.isEmpty },
                   "every entry has a blurb")
            expect(AIAnalysis.catalogue.allSatisfy { !$0.title.isEmpty },
                   "every entry has a title")
        }

        do {
            // An entry that needs history must not be in the one-shot UI
            // catalogue — that was the whole point of the split.
            expect(AIAnalysis.catalogue.allSatisfy { !$0.needsHistory },
                   "no history-only analysis is offered in the UI")
        }

        do {
            expect(AIAnalysis.entry(named: "root_cause")?.title == "Why is it slow?",
                   "lookup by name works")
            expect(AIAnalysis.entry(named: "nope") == nil,
                   "unknown name returns nil")
        }

        // ── input encoding ─────────────────────────────────────────────────
        do {
            let json = try? AIAnalysis.encode(["mbps": 42.0, "bloat_grade": "D"])
            expect(json?.contains("42") == true, "input encodes a double")
        }

        do {
            let json = try? AIAnalysis.encode(["events": [["lost": true]]])
            expect(json?.contains("events") == true, "nested input encodes")
        }

        do {
            // A non-JSON object must fail loudly rather than emit "{}".
            let bad: [String: Any] = ["when": Date()]
            expect((try? AIAnalysis.encode(bad)) == nil,
                   "non-serialisable input is refused")
        }

        // ── result parsing ─────────────────────────────────────────────────
        do {
            let parsed = try? AIAnalysis.parse("{\"headline\":\"hi\"}")
            expect(parsed?["headline"] as? String == "hi", "parses a result")
        }

        do {
            expect((try? AIAnalysis.parse("not json")) == nil,
                   "unparseable result is refused")
        }

        // ── readers ────────────────────────────────────────────────────────
        do {
            let r: [String: Any] = ["headline": "top line"]
            expect(AIAnalysis.headline(r) == "top line", "reads headline")
        }

        do {
            let r: [String: Any] = ["summary": "fallback"]
            expect(AIAnalysis.headline(r) == "fallback", "headline falls back to summary")
        }

        do {
            expect(AIAnalysis.headline([:]) == nil, "no headline returns nil")
        }

        do {
            let r: [String: Any] = ["statements": ["a", "b"], "caveats": ["c"]]
            expect(AIAnalysis.bullets(r) == ["a", "b"], "bullets read statements")
            expect(AIAnalysis.caveats(r) == ["c"], "caveats are kept separate")
        }

        do {
            // Merging across keys is deliberate, but must not duplicate.
            let r: [String: Any] = ["notes": ["n"], "fixes": ["f"]]
            expect(AIAnalysis.bullets(r) == ["n", "f"], "bullets merge keys in order")
        }

        do {
            let r: [String: Any] = ["causes": [["cause": "bufferbloat", "severity": "high"]]]
            expect(AIAnalysis.causes(r).count == 1, "causes decode")
            expect(AIAnalysis.causes([:]).isEmpty, "missing causes are empty")
        }

        do {
            expect(AIAnalysis.source(["source": "ai"]) == "ai", "source reads ai")
            expect(AIAnalysis.source([:]) == "local", "source defaults to local")
        }

        // ── metrics bundle ─────────────────────────────────────────────
        do {
            let m = DashboardMetrics(
                speed: MetricValue(value: 42, mode: "baseline", date: Date()),
                bloatGrade: GradeValue(letter: "D", deltaMs: 180, mode: "bloat", date: Date()),
                loss: MetricValue(value: 0.2, mode: "loss", date: Date()),
                statusWord: "Good")
            let b = AIAnalysis.metricsBundle(from: m)
            expect(b["mbps"] as? Double == 42, "bundle carries speed")
            expect(b["loss_pct"] as? Double == 0.2, "bundle carries loss")
            expect(b["bloat_grade"] as? String == "D", "bundle carries grade")
            expect(b["bloat_delta_ms"] as? Double == 180, "bundle carries bloat delta")
        }

        do {
            // The important one: a missing value must be ABSENT, not zero.
            // "jitter 0 ms" and "jitter not measured" are opposite claims,
            // and the analyser's own rules branch on presence.
            let m = DashboardMetrics(
                speed: MetricValue(value: 42, mode: "baseline", date: Date()),
                bloatGrade: nil, loss: nil, statusWord: nil)
            let b = AIAnalysis.metricsBundle(from: m)
            expect(b["mbps"] as? Double == 42, "present value survives")
            expect(b["loss_pct"] == nil, "absent loss is omitted, not zeroed")
            expect(b["bloat_grade"] == nil, "absent grade is omitted, not blank")
            expect(b.keys.count == 1, "only measured keys are included")
        }

        do {
            let empty = DashboardMetrics(speed: nil, bloatGrade: nil,
                                         loss: nil, statusWord: nil)
            expect(AIAnalysis.isEmpty(AIAnalysis.metricsBundle(from: empty)),
                   "no measurements yields an empty bundle")
            expect(AIAnalysis.isEmpty([:]), "an empty bundle is empty")
        }

        // ── honesty about inconclusive results ────────────────────────────
        do {
            expect(AIAnalysis.isInconclusive(["verdict": "insufficient_data"]),
                   "insufficient_data is inconclusive")
            expect(AIAnalysis.isInconclusive(["confidence": "none"]),
                   "confidence none is inconclusive")
            expect(!AIAnalysis.isInconclusive(["verdict": "degrading"]),
                   "a real verdict is not inconclusive")
            expect(!AIAnalysis.isInconclusive(["causes": [["cause": "x"]]]),
                   "causes present means conclusive")
        }

        do {
            // The one that matters: an empty verdict must never render as
            // a confident-looking empty card.
            expect(AIAnalysis.isInconclusive([:]), "an empty result is inconclusive")
        }

        return failures
    }
}