import Foundation
import AppKit

/// W6-C1b — WiFi-event emission for the QoE timeline.
///
/// Polls the wifi snapshot once per scheduler tick (cheap: one
/// `system_profiler` invocation) and appends any detected change to the
/// event store via `netmax_wifievents`. Runs on a background queue — never
/// blocks the tick loop. Failures are swallowed by design: timeline events
/// are enrichment, not critical path.
enum WifiEventEmitter {
    private static let queue = DispatchQueue(label: "netmax.wifievents", qos: .utility)
    private static var lastSnapshot: [String: Any]? = nil as [String: Any]?  // parsed shape
    /// Interpreter resolution, mirroring EngineClient/BackgroundRunner
    /// (F11/F12 residue fixed here): never a bare "python3" PATH lookup —
    /// the inherited PATH can surface an unexpected interpreter (a uv-
    /// managed 3.13 was resolving first and writing .pyc files INTO the
    /// sealed bundle, breaking the code signature). Order: bundled private
    /// python → NETMAX_PYTHON env → Settings override → /usr/bin/python3.
    private static var pythonPath: String = {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = resourcePath + "/engine/python/bin/python3"
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        if let override = ProcessInfo.processInfo.environment["NETMAX_PYTHON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let pref = AppPreferences.shared.pythonOverride
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pref.isEmpty, pref.hasPrefix("/") { return pref }
        return "/usr/bin/python3"
    }()

    /// Called from ScheduleRunner after each run completes (and safe to call
    /// ad hoc). Fire-and-forget; one flight at a time.
    private static var inFlight = false

    static func captureNow() {
        guard !inFlight else { return }
        inFlight = true
        queue.async {
            defer { inFlight = false }
            runOnce()
        }
    }

    private static func runOnce() {
        // One poll cycle of the existing detector: it diffs against its own
        // in-process state and appends new events to the event store.
        // F3 FIX: the old argv was [python, "--once"] — the SCRIPT NAME was
        // missing, so this spawned `python --once` (a CLI error) and the
        // wifi-event timeline never produced a single event. Pass the
        // bundled detector script explicitly.
        let workDir = engineWorkDir()
        let script = workDir.appendingPathComponent("netmax_wifievents.py").path
        guard FileManager.default.fileExists(atPath: script) else { return }
        let proc = Process()
        // Direct absolute invocation (no /usr/bin/env hop) + a scrubbed
        // env so no child ever writes .pyc into the sealed bundle.
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [script, "--once"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        proc.environment = env
        proc.currentDirectoryURL = workDir
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return // enrichment only — silent skip is honest here
        }
        proc.waitUntilExit()
    }

    private static func engineWorkDir() -> URL {
        // netmax_wifievents.py lives beside netmax.py in the engine dir,
        // both bundled and in-repo.
        if let resource = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resource + "/engine")
            if FileManager.default.fileExists(atPath: bundled.path + "/netmax_wifievents.py") {
                return bundled
            }
        }
        return URL(fileURLWithPath: ".")
    }
}
