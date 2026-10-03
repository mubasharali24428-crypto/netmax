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
        // L1: capture PID while we know this handle is live — reading it
        // after a possible exit widens the PID-recycle window.
        let pid = process.processIdentifier
        process.terminate() // SIGTERM — engine shuts down cleanly
        // Escalate if it ignores TERM for 3 s; re-check OUR handle first so
        // a recycled PID is never signalled.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            if process.isRunning { kill(pid, SIGKILL) }
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

    // MARK: Privileged runs (strict system-wide limit)

    /// Engine candidates for a DIRECT (non-bridge) call, in preference
    /// order: beside the bridge script (bundled layout), then the repo
    /// root relative to a dev-checkout bridge. Pure — the caller picks
    /// the first path that exists.
    static func enginePathCandidates(bridgePath: String) -> [String] {
        let dir = (bridgePath as NSString).deletingLastPathComponent
        let sameDir = (dir as NSString).appendingPathComponent("netmax.py")
        let repoRoot = ((dir as NSString).appendingPathComponent("../../netmax.py") as NSString).standardizingPath
        return [sameDir, repoRoot]
    }

    /// Single-quote a shell word (`/My Tools/x` stays one word; embedded
    /// quotes are escaped the POSIX way).
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Body of the temp script a privileged run executes. Every element is
    /// quoted at build time, so paths with spaces survive both the shell
    /// and the osascript hop without any runtime escaping.
    static func privilegedScriptText(python: [String], engine: String, args: [String]) -> String {
        "#!/bin/sh\n" + (python + [engine] + args).map(shellQuoted).joined(separator: " ") + "\n"
    }

    /// osascript argv running a script file with administrator privileges.
    /// The system owns the password dialog; the app never sees credentials.
    /// NOTE: Stop kills osascript, which ORPHANS the underlying root child
    /// until its window ends — the engine's finally-cleanup still removes
    /// the pf rules then, just not early. Callers must say so in the UI.
    static func osascriptArgv(scriptPath: String) -> [String] {
        ["/usr/bin/osascript", "-e",
         "do shell script " + shellQuoted(scriptPath) + " with administrator privileges"]
    }

    /// Run the engine ELEVATED (strict limit only): writes a temp script and
    /// executes it via osascript's administrator-privileges dialog.
    /// - Throws: `EngineClientError` (dialog cancelled, engine error, …).
    func runPrivileged(args: [String]) async throws -> String {
        guard let bridge = Self.locateBridgeScript() else {
            throw EngineClientError("Engine bridge not found (looked in bundle Resources/engine and ./bridge).")
        }
        guard let engine = Self.enginePathCandidates(bridgePath: bridge)
            .first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw EngineClientError("Engine (netmax.py) not found next to the bridge.")
        }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-priv-\(UUID().uuidString).sh")
        let body = Self.privilegedScriptText(python: pythonArgv + ["-B"], engine: engine, args: args)
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: scriptURL.path)
        } catch {
            throw EngineClientError("Could not stage privileged script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let argv = Self.osascriptArgv(scriptPath: scriptURL.path)
        let result: (output: Data?, error: Data?, status: Int32)
        do {
            result = try await Process.spawn(argv: argv)
        } catch is CancellationError {
            throw EngineClientError("Test stopped.")
        } catch {
            throw EngineClientError("Could not launch privileged run: \(error.localizedDescription)")
        }
        let stdout = String(data: result.output ?? Data(), encoding: .utf8) ?? ""
        let stderr = String(data: result.error ?? Data(), encoding: .utf8) ?? ""
        // osascript exit 1 with "User canceled" = dialog dismissed, not a bug.
        if result.status != 0 && stderr.contains("User canceled") {
            throw EngineClientError("Admin approval dismissed — no limit was installed.")
        }
        guard result.status == 0 else {
            let detail = stderr.isEmpty ? stdout : stderr
            throw EngineClientError(detail.isEmpty
                ? "Privileged run failed (exit \(result.status))."
                : "Privileged run failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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

#if DEBUG
/// Offline self-checks for the privileged strict-limit path.
enum StrictLimitTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[StrictLimitTests] FAIL: \(name)") }
        }

        let cands = EngineClient.enginePathCandidates(
            bridgePath: "/A/Resources/engine/engine_bridge.py")
        check(cands == ["/A/Resources/engine/netmax.py", "/A/netmax.py"],
              "bundled bridge maps to bundled engine, then repo root")

        check(EngineClient.shellQuoted("/My Tools/py") == "'/My Tools/py'",
              "spaces stay one word")
        check(EngineClient.shellQuoted("o'clock") == "'o'\\''clock'",
              "embedded quote escaped POSIX-style")

        let body = EngineClient.privilegedScriptText(
            python: ["/usr/bin/python3", "-B"],
            engine: "/A/Resources/engine/netmax.py",
            args: ["limit", "--mbps", "5", "--seconds", "60", "--strict"])
        check(body == "#!/bin/sh\n'/usr/bin/python3' '-B' "
              + "'/A/Resources/engine/netmax.py' 'limit' '--mbps' '5' "
              + "'--seconds' '60' '--strict'\n",
              "script body fully quoted, -B before engine")
        check(!body.contains("--streams"),
              "strict direct call carries no streams flag")

        let argv = EngineClient.osascriptArgv(scriptPath: "/tmp/netmax-priv-1.sh")
        check(argv == ["/usr/bin/osascript", "-e",
                       "do shell script '/tmp/netmax-priv-1.sh' with administrator privileges"],
              "osascript argv shape")

        return failures
    }
}
#endif

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
