//
//  BloatStory.swift
//  netmax-desktop
//
//  TEAM-1 T1-a — Bufferbloat storytelling model (pure, offline).
//
//  Translates the engine's measured `loaded increase` (delta_ms) into a
//  human story: what caused it, how it affects real activities, and ONE
//  honest, user-side suggestion. This file mirrors the rubric in
//  `netmax.py` BLOAT_GRADES (lines 270–272) EXACTLY:
//
//      BLOAT_GRADES = [(5, "A+"), (30, "A"), (60, "B"), (200, "C"), (400, "D")]
//      … first band whose limit exceeds delta wins; ≥ 400 falls through to "F".
//      Comparison in the engine is strict `<`.
//
//  House voice rules honored here:
//    · Copy describes the MEASUREMENT and USER-SIDE actions only.
//    · Suggestions never promise NetMax will fix the link — queue
//      management lives on the router, and we say so.
//    · D/F suggestions deliberately echo the engine's own printed advice
//      (`netmax.py` run_bloat: SQM/fq_codel/CAKE or shaper below line rate),
//      so UI and CLI never disagree about what to do next.
//
//  Purity contract: no I/O, no engine, no process spawning — trivially
//  unit-testable offline (see BloatStorySelfCheck and the /tmp harness).
//

import Foundation

/// One per-activity consequence of the measured buffering delay.
struct ActivityStory: Equatable {
    /// Short activity name, e.g. "Video calls".
    let title: String
    /// SF Symbol shown next to the story in `BloatStoryView`.
    let symbolName: String
    /// One plain sentence about THIS activity at THIS grade.
    let impact: String
}

/// The full story for one bufferbloat measurement.
struct BloatStory: Equatable {

    // MARK: - Stored properties

    /// Engine grade letter ("A+" … "F"), verbatim from `bloat_grade()`.
    let gradeLetter: String
    /// Measured latency increase under load, in milliseconds.
    let deltaMs: Double?
    /// Why the number looks the way it does (one sentence).
    let cause: String
    /// Impact on the three activities users actually care about.
    let activityImpact: [ActivityStory]
    /// ONE actionable, honest, user-side suggestion. Never "NetMax will fix it".
    let suggestion: String

    // MARK: - Factories

    /// Builds the story for a measured latency increase, matching the
    /// engine's band table exactly (`netmax.py` `bloat_grade`: strict `<`
    /// against 5 / 30 / 60 / 200 / 400 ms, else "F").
    static func make(from deltaMs: Double) -> BloatStory {
        let story = uncheckedMake(from: deltaMs)
        #if DEBUG
        noteFirstUse()
        #endif
        return story
    }

    /// Builds a story from a payload that recorded only the grade letter
    /// (history entries whose raw output carried no parsable delta).
    /// `deltaMs` stays nil and is simply omitted from display copy.
    /// Returns nil for unknown letters — callers decide fallback UX;
    /// we never invent a grade.
    static func make(fromGrade letter: String, deltaMs: Double?) -> BloatStory? {
        guard let band = Band(letter: letter) else { return nil }
        #if DEBUG
        noteFirstUse()
        #endif
        return BloatStory(
            gradeLetter: band.letter,
            deltaMs: deltaMs,
            cause: band.cause,
            activityImpact: band.activities,
            suggestion: band.suggestion
        )
    }

    /// Internal build path WITHOUT the DEBUG parity hook. The hook's own
    /// verifier constructs stories through this so its first run can't
    /// re-enter `verifiedOnce` (recursive lazy-static init would trap).
    static func uncheckedMake(from deltaMs: Double) -> BloatStory {
        let band = Band(deltaMs: deltaMs)
        return BloatStory(
            gradeLetter: band.letter,
            deltaMs: deltaMs,
            cause: band.cause,
            activityImpact: band.activities,
            suggestion: band.suggestion
        )
    }

    #if DEBUG
    /// Fires the boundary self-check exactly once per DEBUG process, the
    /// first time any public factory runs — so a future edit that breaks
    /// band parity with `netmax.py` traps loudly in development builds.
    private static func noteFirstUse() {
        _ = verifiedOnce
    }

    private static let verifiedOnce: Bool = {
        let failures = BloatStorySelfCheck.verify()
        assert(failures.isEmpty,
               "BloatStory bands drifted from netmax.py BLOAT_GRADES: \(failures)")
        return true
    }()
    #endif

    // MARK: - Bands (mirror of netmax.py BLOAT_GRADES)

    /// Internal band table. `upperLimit` is EXCLUSIVE, matching the
    /// engine's `if delta_ms < limit` comparison; `F` has none.
    /// Internal (not private) so the DEBUG self-check can probe bands
    /// directly without touching the hooked public factories.
    enum Band {
        case aPlus, a, b, c, d, f

        init(deltaMs: Double) {
            switch deltaMs {
            case ..<5:      self = .aPlus
            case ..<30:     self = .a
            case ..<60:     self = .b
            case ..<200:    self = .c
            case ..<400:    self = .d
            default:        self = .f
            }
        }

        init?(letter: String) {
            switch letter {
            case "A+":  self = .aPlus
            case "A":   self = .a
            case "B":   self = .b
            case "C":   self = .c
            case "D":   self = .d
            case "F":   self = .f
            default:    return nil
            }
        }

        var letter: String {
            switch self {
            case .aPlus: "A+"
            case .a: "A"
            case .b: "B"
            case .c: "C"
            case .d: "D"
            case .f: "F"
            }
        }

        var cause: String {
            switch self {
            case .aPlus:
                "Loaded latency rose by less than 5 ms — your line stays responsive even at full tilt."
            case .a:
                "Loaded latency rose by under 30 ms — your link absorbs everyday load well."
            case .b:
                "Under load, your router briefly queues packets instead of dropping them, adding up to 60 ms of delay."
            case .c:
                "Under load, your router buffers packets instead of dropping them, so delays of 60–200 ms pile up."
            case .d:
                "Load adds a fifth of a second or more of delay — packets sit queued in your router instead of moving."
            case .f:
                "Latency jumps by around half a second or worse under load — the connection practically freezes while saturated."
            }
        }

        var activities: [ActivityStory] {
            let calls = ActivityStory(
                title: "Video calls",
                symbolName: "video.fill",
                impact: callsImpact
            )
            let gaming = ActivityStory(
                title: "Gaming",
                symbolName: "gamecontroller",
                impact: gamingImpact
            )
            let streaming = ActivityStory(
                title: "Video streaming",
                symbolName: "film",
                impact: streamingImpact
            )
            return [calls, gaming, streaming]
        }

        private var callsImpact: String {
            switch self {
            case .aPlus:
                "Calls stay smooth even while big downloads are running."
            case .a:
                "Calls hold up even while others are downloading."
            case .b:
                "Brief stutters are possible when someone starts a large download."
            case .c:
                "Video calls may freeze momentarily when someone else downloads."
            case .d:
                "Calls visibly freeze and lag whenever the line gets busy."
            case .f:
                "Calls drop frames and freeze badly during any sustained download."
            }
        }

        private var gamingImpact: String {
            switch self {
            case .aPlus:
                "Ping holds steady mid-match, whatever else the network is doing."
            case .a:
                "Only small ping bumps during heavy transfers — easy to miss."
            case .b:
                "Ping drifts up roughly 30–60 ms while other devices are busy."
            case .c:
                "Expect ping spikes of 60–200 ms whenever uploads or downloads run."
            case .d:
                "Rubber-banding and delayed inputs during any heavy transfer."
            case .f:
                "Effectively unplayable while anything else uses the connection."
            }
        }

        private var streamingImpact: String {
            switch self {
            case .aPlus:
                "Streams start immediately and don't stall under load."
            case .a:
                "No practical effect; playback starts fast and holds."
            case .b:
                "Start-up takes a beat longer while the network is loaded."
            case .c:
                "Quality may drop or briefly re-buffer during heavy use."
            case .d:
                "Playback stalls and re-buffers while other devices use bandwidth."
            case .f:
                "Constant re-buffering whenever another device competes for bandwidth."
            }
        }

        var suggestion: String {
            switch self {
            case .aPlus:
                "Nothing to fix. Re-run the bloat test now and then — grades drift when new devices join the network."
            case .a:
                "Nothing needs fixing. Keeping backups and big downloads off peak hours preserves this headroom for free."
            case .b:
                "Check your router's QoS settings page — most routers can give calls and games priority over bulk traffic."
            case .c:
                "Run speed-sensitive things when others aren't streaming, and look for the QoS page in your router's settings to prioritize real-time traffic."
            case .d:
                "If your router supports it, enable smart queueing (SQM / fq_codel / CAKE) on its QoS page, or set its shaper slightly below your line rate. NetMax can measure the result — the queueing itself is configured on the router."
            case .f:
                "Worth fixing today: enable SQM / fq_codel / CAKE on your router (OpenWrt and pfSense support it), or lower its shaper just below line rate. Until then, avoid competing traffic while you're on calls."
            }
        }
    }

    // (DEBUG self-check hook lives near the factories above; the verifier
    // itself is `BloatStorySelfCheck` below.)
}

#if DEBUG
/// Offline parity checks between this model and the engine rubric.
enum BloatStorySelfCheck {

    /// Every band edge plus interior probes. Boundaries flip STRICTLY:
    /// e.g. 4.9 → "A+" but 5.0 → "A", matching `delta_ms < limit` in
    /// `netmax.py::bloat_grade`.
    static let boundaryCases: [(deltaMs: Double, letter: String)] = [
        (0.0, "A+"), (4.9, "A+"),
        (5.0, "A"), (29.9, "A"),
        (30.0, "B"), (59.9, "B"),
        (60.0, "C"), (199.9, "C"),
        (200.0, "D"), (399.9, "D"),
        (400.0, "F"), (1_000.0, "F"),
    ]

    /// Verifies every case maps to the expected letter and every story
    /// carries complete copy (3 activities, non-empty strings).
    /// Returns failure descriptions; empty means all green.
    ///
    /// Builds via `uncheckedMake(from:)` so this verifier can run before
    /// (and during) `verifiedOnce` without re-entering its lazy init.
    @discardableResult
    static func verify() -> [String] {
        var failures: [String] = []

        for sample in boundaryCases {
            let story = BloatStory.uncheckedMake(from: sample.deltaMs)
            if story.gradeLetter != sample.letter {
                failures.append(
                    "delta \(sample.deltaMs) ms → \"\(story.gradeLetter)\", expected \"\(sample.letter)\"")
            }
        }

        // Letter-keyed factory agrees with the delta-keyed one everywhere.
        // Probed at Band level (not via make(fromGrade:)) so this verifier
        // never re-enters verifiedOnce's own lazy init — that recursion
        // is exactly what lazy statics refuse to do.
        for sample in boundaryCases {
            guard let band = BloatStory.Band(letter: sample.letter),
                  band.letter == sample.letter else {
                failures.append("Band(letter:) round-trip failed for \"\(sample.letter)\"")
                continue
            }
        }

        // Unknown letters are refused, never guessed.
        if BloatStory.Band(letter: "E") != nil {
            failures.append("unknown letter \"E\" should map to nil")
        }

        // Copy completeness across all six bands (hook-free path).
        for delta in boundaryCases.map(\.deltaMs) {
            let story = BloatStory.uncheckedMake(from: delta)
            if story.cause.isEmpty || story.suggestion.isEmpty {
                failures.append("incomplete copy at delta \(delta) ms")
            }
            if story.activityImpact.count != 3 {
                failures.append("expected 3 activity impacts at delta \(delta) ms, got \(story.activityImpact.count)")
            }
            for activity in story.activityImpact where activity.impact.isEmpty || activity.symbolName.isEmpty {
                failures.append("empty activity story at delta \(delta) ms (\(activity.title))")
            }
        }

        return failures
    }
}
#endif
