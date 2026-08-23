import Foundation

/// Client for the NetMax engine bridge (contract C1).
///
/// Locates `engine_bridge.py` (bundled at `Resources/engine/`, or `../bridge`
/// relative fallback for dev runs) and invokes:
///   `<python> <script> run <mode> [--args...] --json-out <tmpfile>`
/// The bridge writes `{"success": Bool, "mode": ..., "data": {...}, "error": String?}`
/// and exits 0/nonzero accordingly; this client surfaces the parsed envelope.
struct EngineClient {
    /// Python interpreter resolution per C1: env override, then system default.
    private var python: String {
        if let override = ProcessInfo.processInfo.environment["NETMAX_PYTHON"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        return "/usr/bin/env python3"
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
    func run(_ mode: String, args: [String] = []) async throws -> String {
        guard let script = Self.locateBridgeScript() else {
            throw EngineClientError("Engine bridge not found (looked in bundle Resources/engine and ./bridge).")
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmax-engine-\(UUID().uuidString).json")

        // `/usr/bin/env python3` is two words — split argv safely.
        let argv = python.split(separator: " ").map(String.init)
            + [script, "run", mode]
            + args
            + ["--json-out", tmpURL.path]

        let result: (output: Data?, error: Data?, status: Int32)
        do {
            result = try await Process.spawn(argv: argv)
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
    static func spawn(argv: [String]) async throws -> (Data?, Data?, Int32) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                process.terminationHandler = { proc in
                    // Drain after exit so no data races with the writer.
                    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (out, err, proc.terminationStatus))
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
