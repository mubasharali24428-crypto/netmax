import Foundation

/// Launchd-backed background test runner (dev feature — direct-download
/// builds only).
///
/// Manages a per-user launchd agent (Label `com.netmax.desktop.runner`) that
/// periodically invokes the bundled engine bridge in the background:
///
///     <python> -B <engine_bridge.py> run boost --seconds 10
///
/// The agent definition is generated as plist XML, installed under
/// `~/Library/LaunchAgents/`, and loaded/unloaded via `/bin/launchctl`.
/// Every path is derived at runtime (`NSHomeDirectory`,
/// `NSSearchPathForDirectoriesInDomains`) — no user directories are
/// hardcoded anywhere in this file.
///
/// SANDBOX / APP STORE [UNCERTAIN]: a sandboxed (Mac App Store) build cannot
/// write into ~/Library/LaunchAgents nor exec /bin/launchctl, so this helper
/// must stay gated behind direct-download/dev distributions. Callers should
/// verify the app is non-sandboxed before exposing install controls in UI.
enum BackgroundRunner {

    // MARK: Identity

    /// Stable reverse-DNS launchd label for the agent.
    static let agentLabel = "com.netmax.desktop.runner"

    /// Engine mode + duration the agent runs on each fire (fixed per spec;
    /// the firing cadence is controlled separately by StartInterval).
    private static let engineMode = "boost"
    private static let measurementSeconds = 10

    // MARK: Errors

    /// User-presentable failure carrying the failing operation's detail.
    struct RunnerError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Runtime-derived paths

    /// `~/Library/LaunchAgents` (created on demand at install time).
    static var agentsDirectory: String {
        let library = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library")
        return (library as NSString).appendingPathComponent("LaunchAgents")
    }

    /// Agent plist path: `~/Library/LaunchAgents/<label>.plist`.
    static var plistPath: String {
        (agentsDirectory as NSString).appendingPathComponent("\(agentLabel).plist")
    }

    /// Agent stdio sink: `~/Library/Logs/<label>.<out|err>.log`.
    static func logPath(stream: String) -> String {
        let logs = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first
            .map { ($0 as NSString).appendingPathComponent("Logs") }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
        return (logs as NSString).appendingPathComponent("\(agentLabel).\(stream).log")
    }

    // MARK: Job definition

    /// Interpreter argv, mirroring EngineClient's C1/L2-C1 resolution rules
    /// (that helper is file-private, so they are restated here): the
    /// `NETMAX_PYTHON` env override wins; a value containing `/` is one argv
    /// element with spaces intact; a bare name rides through `/usr/bin/env`.
    static func pythonArgv(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let fallback = ["/usr/bin/env", "python3"]
        guard let override = environment["NETMAX_PYTHON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty else { return fallback }
        return override.contains("/")
            ? [override]
            : ["/usr/bin/env", override]
    }

    /// Full `ProgramArguments` array for the agent job.
    ///
    /// Uses the shared bridge locator (bundled `Resources/engine/` copy
    /// preferred, repo-relative dev fallback next) so the agent always runs
    /// the same script the foreground app would.
    static func programArguments(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String] {
        guard let bridge = EngineClient.locateBridgeScript() else {
            throw RunnerError("Engine bridge not found (looked in bundle Resources/engine and ./bridge).")
        }
        return pythonArgv(environment: environment)
            + ["-B", bridge, "run", engineMode, "--seconds", String(measurementSeconds)]
    }

    /// Generate the launchd agent plist XML for the given `StartInterval`.
    /// - Parameter interval: seconds between automatic runs; must be >= 1.
    ///
    /// `RunAtLoad` stays off: the job is purely interval-driven, so loading
    /// it does not immediately kick off a measurement.
    static func makePlistXML(
        interval: TimeInterval,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard interval >= 1 else {
            throw RunnerError("StartInterval must be >= 1 second (got \(interval)).")
        }
        let arguments = try programArguments(environment: environment)

        var body = ""
        func emit(key: String, value: String) {
            body += "\t<key>\(key)</key>\n\t\(value)\n"
        }

        emit(key: "Label", value: "<string>\(xmlEscape(agentLabel))</string>")

        // Carry a configured interpreter override into the agent's
        // environment; launchd jobs otherwise see launchd's sparse PATH.
        if let override = environment["NETMAX_PYTHON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            let envDict = "<dict>\n"
                + "\t\t\t<key>NETMAX_PYTHON</key>\n"
                + "\t\t\t<string>\(xmlEscape(override))</string>\n"
                + "\t\t</dict>"
            emit(key: "EnvironmentVariables", value: envDict)
        }

        let argumentLines = arguments
            .map { "\t\t<string>\(xmlEscape($0))</string>" }
            .joined(separator: "\n")
        emit(key: "ProgramArguments", value: "<array>\n\(argumentLines)\n\t\t</array>")
        emit(key: "StartInterval", value: "<integer>\(Int(interval.rounded()))</integer>")
        emit(key: "RunAtLoad", value: "<false/>")
        emit(key: "ProcessType", value: "<string>Background</string>")
        emit(key: "StandardOutPath", value: "<string>\(xmlEscape(logPath(stream: "out")))</string>")
        emit(key: "StandardErrorPath", value: "<string>\(xmlEscape(logPath(stream: "err")))</string>")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)</dict>
        </plist>
        """
    }

    // MARK: Install / uninstall

    /// Install the agent plist and register it with launchd.
    ///
    /// Idempotent: a previously loaded job is booted out first so interval
    /// edits take effect, then the fresh plist is bootstrapped.
    ///
    /// [UNCERTAIN] On hardened-runtime direct-download builds this triggers
    /// no extra Gatekeeper prompt (we only write a plist and exec
    /// /bin/launchctl), but behavior under MDM profiles that restrict
    /// LaunchAgent registration was not verified.
    ///
    /// - Returns: the plist path that was installed.
    @discardableResult
    static func install(interval: TimeInterval) async throws -> String {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: agentsDirectory) {
            try fileManager.createDirectory(atPath: agentsDirectory, withIntermediateDirectories: true)
        }
        try makePlistXML(interval: interval)
            .write(toFile: plistPath, atomically: true, encoding: .utf8)

        // Replace any live registration so the new interval applies.
        if await isLoaded() {
            try? await unloadFromLaunchd()
        }

        do {
            _ = try await bootstrapIntoSession()
        } catch {
            // Legacy fallback for environments lacking the bootstrap verb.
            _ = try await launchctl(["load", "-w", plistPath])
        }
        return plistPath
    }

    /// Unregister the agent (if loaded) and delete its plist.
    /// Uninstalling an uninstalled agent succeeds quietly.
    static func uninstall() async throws {
        if await isLoaded() {
            try? await unloadFromLaunchd()
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: plistPath) {
            try fileManager.removeItem(atPath: plistPath)
        }
    }

    /// Stop scheduling the job without deleting its plist.
    static func unload() async throws {
        try await unloadFromLaunchd()
    }

    // MARK: Status

    /// Snapshot of the agent's on-disk and launchd state.
    struct Status: Equatable, CustomStringConvertible {
        /// Plist present under `~/Library/LaunchAgents`.
        let plistInstalled: Bool
        /// Job currently registered with the user's launchd session.
        let loaded: Bool
        /// PID while a measurement is actively running, else `nil`.
        let activePID: Int32?
        /// Where the plist lives (or would live).
        let plistPath: String

        var description: String {
            var lines = [
                "plist: \(plistInstalled ? "installed" : "missing") (\(plistPath))",
                "launchd: \(loaded ? "loaded" : "not loaded")"
            ]
            if let pid = activePID { lines.append("running: pid \(pid)") }
            return lines.joined(separator: "\n")
        }
    }

    /// Query launchd for the agent's current state.
    ///
    /// Never throws: a missing/unregistered job simply reads back as
    /// `loaded == false` (`launchctl print` exits nonzero for those).
    static func status() async -> Status {
        let installed = FileManager.default.fileExists(atPath: plistPath)
        guard let report = try? await launchctl(["print", "gui/\(getuid())/\(agentLabel)"]) else {
            return Status(plistInstalled: installed, loaded: false, activePID: nil, plistPath: plistPath)
        }
        var pid: Int32?
        for line in report.split(whereSeparator: \.isNewline) {
            // launchctl print renders e.g. "\tpid = 48213".
            guard let match = line.range(of: #"pid\s*=\s*(\d+)"#, options: .regularExpression) else {
                continue
            }
            let digits = line[match].filter(\.isNumber)
            pid = Int32(String(digits))
        }
        return Status(plistInstalled: installed, loaded: true, activePID: pid, plistPath: plistPath)
    }

    /// Whether launchd currently has the job registered.
    static func isLoaded() async -> Bool {
        await status().loaded
    }

    // MARK: launchctl plumbing

    /// Register the freshly-written plist into the caller's GUI session
    /// domain (the modern replacement for `launchctl load`, macOS 10.11+).
    private static func bootstrapIntoSession() async throws {
        _ = try await launchctl(["bootstrap", "gui/\(getuid())", plistPath])
    }

    /// Unload via `bootout`, falling back to the legacy `unload` verb.
    private static func unloadFromLaunchd() async throws {
        do {
            _ = try await launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        } catch {
            _ = try await launchctl(["unload", plistPath])
        }
    }

    /// Run `/bin/launchctl`; return stdout on success, throw with stderr
    /// detail otherwise.
    private static func launchctl(_ arguments: [String]) async throws -> String {
        let result = await Process.netmaxRun(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments
        )
        let stdout = String(data: result.out ?? Data(), encoding: .utf8) ?? ""
        let stderr = String(data: result.err ?? Data(), encoding: .utf8) ?? ""
        guard result.status == 0 else {
            let detail = stderr.isEmpty ? stdout : stderr
            throw RunnerError("""
            launchctl \(arguments.first ?? "") failed (exit \(result.status)): \
            \(detail.trimmingCharacters(in: .whitespacesAndNewlines))
            """)
        }
        return stdout
    }

    /// Escape text for inclusion in plist XML character data.
    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension Process {
    /// Run a process to completion off the main actor, capturing stdio.
    /// (Local twin of the file-private helper in EngineClient.swift, kept
    /// separate so this file stays self-contained.)
    static func netmaxRun(
        executableURL: URL,
        arguments: [String]
    ) async -> (out: Data?, err: Data?, status: Int32) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            do {
                process.terminationHandler = { finished in
                    // Drain after exit so no data races with the writers.
                    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (out, err, finished.terminationStatus))
                }
                try process.run()
            } catch {
                continuation.resume(returning: (
                    nil,
                    Data(error.localizedDescription.utf8),
                    -1
                ))
            }
        }
    }
}
