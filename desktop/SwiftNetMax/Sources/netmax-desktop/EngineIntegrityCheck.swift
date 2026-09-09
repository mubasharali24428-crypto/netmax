//
//  EngineIntegrityCheck.swift
//  netmax-desktop
//
//  W18 / audit F2 follow-up: startup engine-directory integrity check.
//
//  Threat (from NETMAXDESKTOP-SECURITY-AUDIT.md, F2): the bundled Python
//  engine files under Contents/Resources/engine/ are re-executed on every
//  measurement. If the app is shared ad-hoc (pre-notarization, F1), a local
//  process running as this user can rewrite an engine file and have its
//  code executed automatically by scheduled runs — a persistence channel.
//  Notarization (F1) makes tamper detectable via the seal; until the
//  Developer ID exists, this check narrows the window by refusing to run
//  engine code when the bundle's engine dir is group/world-writable.
//
//  Pure logic (testable offline): evaluateEngineIntegrity(_:) maps POSIX
//  permission bits to a verdict; EngineIntegrityCheck.check() gathers the
//  bits from the bundle and posts a warning notification when warranted.
//

import Foundation
import UserNotifications

// MARK: - Verdict (pure)

/// Result of evaluating engine-dir permission bits.
struct EngineIntegrityVerdict: Equatable {
    enum Status: String { case ok, warn }
    let status: Status
    /// Nil when status == .ok. Human-readable, ready to show as-is.
    let message: String?
}

/// Evaluate engine-integrity from POSIX mode bits (pure, offline-testable).
///
/// Bits outside 0o777 are ignored (setuid/setgid/sticky don't matter here).
/// Writable-by-group/world on EITHER the engine directory or any .py file
/// inside it is a warn — the engine is re-executed, so write access to it
/// is effectively code execution.
func evaluateEngineIntegrity(dirMode: Int, fileModes: [Int]) -> EngineIntegrityVerdict {
    func groupWorldWritable(_ m: Int) -> Bool { m & 0o022 != 0 }

    var offenders: [String] = []
    if groupWorldWritable(dirMode) { offenders.append("engine directory") }
    for (i, m) in fileModes.enumerated() where groupWorldWritable(m) {
        offenders.append("engine file #\(i + 1)")
    }
    if offenders.isEmpty {
        return EngineIntegrityVerdict(status: .ok, message: nil)
    }
    let list = offenders.joined(separator: ", ")
    return EngineIntegrityVerdict(
        status: .warn,
        message: "NetMax found the bundled engine writable by users other than you (\(list)). "
            + "For safety, automatic runs stay paused until the app is reinstalled from a "
            + "trusted copy. Manual runs still work.")
}

// MARK: - Bundle probe (impure)

enum EngineIntegrityCheck {
    static func check() -> EngineIntegrityVerdict {
        guard let base = Bundle.main.resourceURL else {
            // No bundle (dev run via swift run): nothing to check.
            return EngineIntegrityVerdict(status: .ok, message: nil)
        }
        let engineDir = base.appendingPathComponent("engine")
        let fm = FileManager.default
        guard fm.fileExists(atPath: engineDir.path) else {
            // Dev layout: engine lives in the repo, outside any bundle.
            return EngineIntegrityVerdict(status: .ok, message: nil)
        }
        let dirMode = (try? fm.attributesOfItem(atPath: engineDir.path)[.posixPermissions] as? Int) ?? 0
        var fileModes: [Int] = []
        if let files = try? fm.contentsOfDirectory(atPath: engineDir.path) {
            for f in files where f.hasSuffix(".py") {
                let p = engineDir.appendingPathComponent(f).path
                if let m = try? fm.attributesOfItem(atPath: p)[.posixPermissions] as? Int {
                    fileModes.append(m)
                }
            }
        }
        return evaluateEngineIntegrity(dirMode: dirMode, fileModes: fileModes)
    }

    /// Convenience: run at startup; post a user notification on warn.
    static func runAtStartup() {
        let verdict = check()
        guard verdict.status == .warn, let message = verdict.message else { return }
        let content = UNMutableNotificationContent()
        content.title = "NetMax engine integrity warning"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "netmax.engine-integrity",
            content: content,
            trigger: nil
        )
        // If notifications are not authorized the request is dropped silently —
        // acceptable: the check is defense-in-depth, not the primary control.
        UNUserNotificationCenter.current().add(request)
    }
}
