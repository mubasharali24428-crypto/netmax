//
//  EngineParameterRanges.swift
//  netmax-desktop
//
//  M3 — single source of truth for engine-accepted parameter ranges.
//  Mirrors `desktop/bridge/engine_bridge.py` `RANGE_BOUNDS`
//  (streams 1...50, seconds 5...21600, count 1...100). UI clamps and seed
//  catalogs read from here; when engine bounds change, update RANGE_BOUNDS
//  first, then this file — never the reverse. `AppPreferences.Limits`
//  remains the contract-P1 *storage* clamp for default prefs (documented
//  separately) and points at this catalog for engine-facing work.
//

import Foundation

enum EngineParameterRanges {
    /// Engine-accepted bounds (engine_bridge.py RANGE_BOUNDS).
    static let streams = 1...50
    static let seconds = 5...21_600
    static let count = 1...100

    /// Mode Lab quick band / seed catalog — a tighter *subset* of the engine
    /// ranges so steppers always stay valid without hitting long-run bounds.
    static let quickSeconds = 5...30
    static let seedStreams = 2...16
    static let seedCount = 5...50
}
