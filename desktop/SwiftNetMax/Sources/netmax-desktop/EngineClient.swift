import Foundation

/// Client for the NetMax engine bridge (contract C1).
///
/// Locates `engine_bridge.py` (bundled at `Resources/engine/`, or `../bridge`
/// relative fallback for dev runs) and invokes:
///   `<python> <script> run <mode> [--args...] --json-out <tmpfile>`
/// The bridge writes `{"success": Bool, "mode": ..., "data": {...}, "error": String?}`
/// and exits 0/nonzero accordingly; this client surfaces the parsed envelope.
/// W16 Stop support: live engine process handle (main-actor isolated).
@MainActor fileprivate var engineCurrentProcess: Process?

struct EngineClient {
    /// Python interpreter resolution per C1: env override, then system default.
    ///
    /// Whitespace-safe (L2-C1): the override is treated as a single logical
    /// interpreter spec, not a blindly-split word list. A value containing a
    /// path separator (`/`) is one argv element — spaces are part of the path
    /// (e.g. `/Users/me/My Tools/venv/bin/python`); no `/usr/bin/env` hop,
    /// since env would re-split it. Only a bare interpreter name
    /// ("python3", "py") goes through `/usr/bin/env <name>`, which resolves
    /// via PATH exactly like before.
    /// Resolution order (F13/F11 fixes from the security audit):
    ///   1. NETMAX_PYTHON env var (dev override — unchanged behavior)
    ///   2. AppPreferences.pythonOverride — the Settings field that was
    ///      previously persisted but never consumed (dead UI, F13)
    ///   3. /usr/bin/python3 — absolute system interpreter; the old
    ///      /usr/bin/env PATH hop let a hostile PATH entry silently
    ///      substitute the interpreter (F11)
    private var pythonArgv: [String] {
        if let override = ProcessInfo.processInfo.environment["NETMAX_PYTHON"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.contains("/")
                    ? [trimmed]                   // path-like: one argv element
                    : ["/usr/bin/env", trimmed]   // bare name: resolve via PATH
            }
        }
        // F13: honor the Settings interpreter override (AppPreferences)
        let pref = AppPreferences.shared.pythonOverride
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pref.isEmpty {
            return pref.contains("/")
                ? [pref]
                : ["/usr/bin/env", pref]
        }
        return ["/usr/bin/python3"]
    }

    /// Locate the bridge script. Prefers a bundled copy; falls back to the
    /// repo-relative dev location (`desktop/bridge/engine_bridge.py`).
    static func locateBridgeScript() -> String? {
        // Bundled layout per C1: <bundle>/Resources/engine/engine_bridge.py
        // (url(forResource:) only sees the bundle root, so probe subdir too).
        if let base = Bundle.main.resourceURL {
            let subdir = base.appendingPathComponent("engine/engine_bridge.py").path
            if FileManager.default.fileExists(atPath: subdir) { return subdir }
        }
        if let bundled = Bundle.main.url(forResource: "engine_bridge", withExtension: "py") {
            return bundled.path
        }
        // Dev-run fallback: walk up from cwd looking for desktop/bridge/.
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            (cwd as NSString).appendingPathComponent("bridge/engine_bridge.py"),
            (cwd as NSString).appendingPathComponent("desktop/bridge/engine_bridge.py")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Run the engine bridge synchronously on a background executor.
    /// - Parameters:
    ///   - mode: engine mode name passed to `run <mode>` (one of the C1 modes:
    ///     baseline/turbo/boost/dns/bloat/full/upload/loss/jitter/wifi).
    ///   - args: extra CLI flags, e.g. ["--streams", "4", "--seconds", "5"].
    /// - Returns: pretty-printed `data` payload from the JSON envelope.
    /// - Throws: `EngineClientError` with a user-presentable message.
    /// W16 — user-requested Stop: SIGTERM the running engine, escalate to
    /// SIGKILL after a grace period. Safe to call when idle.
    @MainActor static func stopCurrent() {
        guard let process = engineCurrentProcess, process.isRunning else { return }
        process.terminate() // SIGTERM — engine shuts down cleanly
        // Escalate if it ignores TERM for 3 s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run(_ mode: String, args: [String] = []) async throws -> String {
        guard let script = Self.locateBridgeScript() else {
            throw EngineClientError("Engine bridge not found (looked in bundle Resources/engine and ./bridge).")
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-engine-\(UUID().uuidString).json")

        // Whitespace-safe argv assembly (L2-C1): see pythonArgv — path-like
        // overrides stay a single element; bare names ride through env.
        let argv = pythonArgv
            + ["-B"]                                  // no .pyc writes — keeps the bundle's code signature intact
            + [script, "run", mode]
            + args
            + ["--json-out", tmpURL.path]

        let result: (output: Data?, error: Data?, status: Int32)
        do {
            result = try await Process.spawn(argv: argv)
        } catch is CancellationError {
            throw EngineClientError("Test stopped.")
        } catch let underlying as EngineClientError {
            throw underlying
        } catch {
            throw EngineClientError("Could not launch engine: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let stdout = String(data: result.output ?? Data(), encoding: .utf8) ?? ""
        let stderr = String(data: result.error ?? Data(), encoding: .utf8) ?? ""

        guard let raw = try? Data(contentsOf: tmpURL),
              let envelope = try? JSONSerialization.jsonObject(with: raw),
              let obj = envelope as? [String: Any] else {
            let detail = stderr.isEmpty ? stdout : stderr
            throw EngineClientError(detail.isEmpty
                ? "Engine produced no JSON output (exit \(result.status))."
                : "Engine failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if obj["success"] as? Bool == true,
           let data = obj["data"] {
            return Self.prettyPrinted(data)
        }

        let message = (obj["error"] as? String)
            ?? "Unknown engine failure (exit \(result.status))."
        throw EngineClientError(message)
    }

    private static func prettyPrinted(_ value: Any) -> String {
        if let jsonData = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: jsonData, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}

/// User-presentable failure carrying the engine's error string.
struct EngineClientError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Process {
    /// Run a process to completion off the main actor, capturing stdio.
    /// Registers the live handle so EngineClient.stopCurrent() can kill it.
    static func spawn(argv: [String]) async throws -> (Data?, Data?, Int32) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        // argv[0] is already absolute (pythonArgv resolution) — exec it
        // directly, no /usr/bin/env PATH hop. Env is scrubbed so engine
        // children never write .pyc into the sealed bundle (F12 residue:
        // a PATH-first uv python did exactly that) and never see a stale
        // PYTHONPATH/PYTHONHOME.
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        process.environment = env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                process.terminationHandler = { proc in
                    Task { @MainActor in engineCurrentProcess = nil }
                    // Drain after exit so no data races with the writer.
                    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (out, err, proc.terminationStatus))
                }
                try process.run()
                Task { @MainActor in engineCurrentProcess = process }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
