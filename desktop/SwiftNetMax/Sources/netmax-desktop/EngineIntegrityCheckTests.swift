//
//  EngineIntegrityCheckTests.swift
//  netmax-desktop
//
//  W18 / audit F2 follow-up: offline checks for the engine-integrity
//  verdict logic. Follows the HistoryStoreTests convention: Package.swift
//  has a single executable target and no test target, so this file is a
//  plain enum harness (compiled into the DEBUG build as dead code; the
//  checks run via this API from a snippet or future CI lane). If a test
//  target is ever added, each body converts 1:1 into an XCTest method.
//
import Foundation

enum EngineIntegrityCheckTests {
    /// Run all checks; returns number of failures (0 == pass).
    @discardableResult
    static func runAll() -> Int {
        var failures = 0

        func expect(_ condition: Bool, _ label: String) {
            if condition { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
        }

        // Clean modes are ok — nothing writable beyond the owner.
        do {
            let v = evaluateEngineIntegrity(dirMode: 0o755, fileModes: [0o644, 0o600, 0o444])
            expect(v.status == .ok && v.message == nil, "clean modes are ok")
        }

        // Group-writable directory warns and names the offender.
        do {
            let v = evaluateEngineIntegrity(dirMode: 0o775, fileModes: [0o644])
            expect(v.status == .warn && v.message?.contains("engine directory") == true,
                   "group-writable dir warns")
        }

        // World-writable file warns and names the file index.
        do {
            let v = evaluateEngineIntegrity(dirMode: 0o755, fileModes: [0o644, 0o666])
            expect(v.status == .warn && v.message?.contains("engine file #2") == true,
                   "world-writable file warns with index")
        }

        // Setuid/setgid/sticky bits outside 0o777 are ignored.
        do {
            let v = evaluateEngineIntegrity(dirMode: 0o4755, fileModes: [0o644])
            expect(v.status == .ok, "setuid bits ignored")
        }

        // Empty file list is ok (dev layouts with no bundled engine).
        do {
            let v = evaluateEngineIntegrity(dirMode: 0o755, fileModes: [])
            expect(v.status == .ok, "empty file list ok")
        }

        if failures == 0 { print("engine-integrity: all checks passed") }
        return failures
    }
}
