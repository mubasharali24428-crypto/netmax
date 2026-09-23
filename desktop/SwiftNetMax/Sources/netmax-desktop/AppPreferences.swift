//
//  AppPreferences.swift
//  netmax-desktop
//
//  L3-C — Contract P1 owner: every persisted user preference.
//
//  Rules encoded here (other lanes must not bypass):
//  - UserDefaults keys are prefixed `netmax.prefs.` and spelled EXACTLY as
//    fixed in docs/product/mission-l3-graph.md — lanes A/B/D depend on them.
//  - Other lanes read/write ONLY through `AppPreferences.shared`; direct
//    UserDefaults access to these keys violates contract P1.
//  - Every numeric assignment is clamped to a sane range regardless of
//    source (settings UI, restored backup, future importer):
//        streams 1...50 · seconds 1...60 · count 1...200.
//
//  Storage notes:
//  - Values are mirrored in `@Published` properties so SwiftUI views can
//    observe them; each mirror persists back to UserDefaults on change.
//  - Missing keys fall back to the documented defaults; out-of-range stored
//    values are pulled back into range at load time, never surfaced raw.
//

import Foundation
import Combine

final class AppPreferences: ObservableObject {

    /// Process-wide instance. Mutate on the main thread (SwiftUI rules);
    /// reads are safe anywhere.
    static let shared = AppPreferences()

    // MARK: Keys — exact spellings, part of the shared contract.

    enum Keys {
        static let defaultStreams = "netmax.prefs.defaultStreams"   // Int,    default 8
        static let defaultSeconds = "netmax.prefs.defaultSeconds"   // Int,    default 10
        static let defaultCount   = "netmax.prefs.defaultCount"     // Int,    default 10
        static let pythonOverride = "netmax.prefs.pythonOverride"   // String, default ""
        static let launchWindow   = "netmax.prefs.launchWindow"     // Bool,   default true (lane C-owned)
    }

    // MARK: Sane ranges enforced on every set.
    //
    // M3 — STORAGE clamps only for these default prefs (contract P1). The
    // engine-facing SSOT is `EngineParameterRanges` (mirrors
    // `engine_bridge.py` RANGE_BOUNDS: streams 1...50, seconds 5...21600,
    // count 1...100). When tightening or widening anything here, reconcile
    // against EngineParameterRanges / RANGE_BOUNDS first, never the reverse.

    enum Limits {
        static let streams = 1...50
        static let seconds = 1...60
        static let count   = 1...200
    }

    // MARK: Documented fallbacks (used when a key was never written).

    enum Fallbacks {
        static let streams        = 8
        static let seconds        = 10
        static let count          = 10
        static let pythonOverride = ""
        static let launchWindow   = true
    }

    // MARK: Observed, self-persisting values

    /// Default stream count offered in Mode Lab (clamped to 1...32).
    @Published var defaultStreams: Int {
        didSet {
            let clamped = Self.clamp(defaultStreams, to: Limits.streams)
            if clamped != defaultStreams {
                defaultStreams = clamped   // re-enters didSet exactly once, then converges
            } else if oldValue != defaultStreams {
                defaults.set(defaultStreams, forKey: Keys.defaultStreams)
            }
        }
    }

    /// Default capture seconds offered in Mode Lab (clamped to 1...60).
    @Published var defaultSeconds: Int {
        didSet {
            let clamped = Self.clamp(defaultSeconds, to: Limits.seconds)
            if clamped != defaultSeconds {
                defaultSeconds = clamped
            } else if oldValue != defaultSeconds {
                defaults.set(defaultSeconds, forKey: Keys.defaultSeconds)
            }
        }
    }

    /// Default result count offered in Mode Lab (clamped to 1...200).
    @Published var defaultCount: Int {
        didSet {
            let clamped = Self.clamp(defaultCount, to: Limits.count)
            if clamped != defaultCount {
                defaultCount = clamped
            } else if oldValue != defaultCount {
                defaults.set(defaultCount, forKey: Keys.defaultCount)
            }
        }
    }

    /// Full path to the Python 3 interpreter the engine should use.
    /// Empty string means "resolve `python3` on PATH at run time".
    @Published var pythonOverride: String {
        didSet {
            if oldValue != pythonOverride {
                defaults.set(pythonOverride, forKey: Keys.pythonOverride)
            }
        }
    }

    /// Whether the main window opens automatically at app start
    /// (the menu-bar bolt icon stays available either way).
    @Published var launchWindow: Bool {
        didSet {
            if oldValue != launchWindow {
                defaults.set(launchWindow, forKey: Keys.launchWindow)
            }
        }
    }

    // MARK: Setup

    private let defaults: UserDefaults

    /// Injectable backing store for tests/proof snippets; production code
    /// uses `shared`, which reads `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let streams = (defaults.object(forKey: Keys.defaultStreams) as? Int)
            .map { Self.clamp($0, to: Limits.streams) } ?? Fallbacks.streams
        let seconds = (defaults.object(forKey: Keys.defaultSeconds) as? Int)
            .map { Self.clamp($0, to: Limits.seconds) } ?? Fallbacks.seconds
        let count = (defaults.object(forKey: Keys.defaultCount) as? Int)
            .map { Self.clamp($0, to: Limits.count) } ?? Fallbacks.count
        let python = defaults.string(forKey: Keys.pythonOverride) ?? Fallbacks.pythonOverride
        let launch = (defaults.object(forKey: Keys.launchWindow) as? Bool) ?? Fallbacks.launchWindow

        _defaultStreams = Published(initialValue: streams)
        _defaultSeconds = Published(initialValue: seconds)
        _defaultCount   = Published(initialValue: count)
        _pythonOverride = Published(initialValue: python)
        _launchWindow   = Published(initialValue: launch)
    }

    // MARK: Helpers for non-UI consumers (lanes A/B/D)

    /// Pull `value` into `range`. Out-of-range inputs land on the nearest
    /// bound; there are no sentinel error values by design.
    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
