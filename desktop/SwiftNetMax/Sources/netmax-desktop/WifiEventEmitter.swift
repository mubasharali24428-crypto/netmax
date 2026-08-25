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
    private static var pythonPath: String = {
        Bundle.main.resourcePath.map { $0 + "/engine" }.map { engineDir in
            let candidate = engineDir + "/python/bin/python3"
            return FileManager.default.fileExists(atPath: candidate) ? candidate : "python3"
        } ?? "python3"
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
        // persisted state file and appends new events to the event store.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [pythonPath, "--once"]
        proc.currentDirectoryURL = engineWorkDir()
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
