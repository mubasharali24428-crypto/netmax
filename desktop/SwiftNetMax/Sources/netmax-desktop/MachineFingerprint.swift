//  MachineFingerprint.swift — hardware-bound machine identity for trial gating.
//
//  The canonical fingerprint is the SHA-256 hex of the hardware UUID
//  (macOS: IOPlatformUUID from IOKit — stable across app reinstalls and OS
//  reinstalls, unlike anything stored in UserDefaults or the app container).
//
//  PRIVACY: the raw UUID is NEVER logged, printed, or transmitted. Only the
//  hash leaves the machine, and only to the trial registry server the user
//  opted into by pressing "Start trial".
//
//  The UUID source is injectable (uuidProvider) so tests are deterministic
//  without touching IOKit. Save/restore the provider around tests that swap it.

import Foundation
import CryptoKit
import IOKit

enum MachineFingerprint {

    /// Injectable hardware-UUID source. Production reads IOPlatformUUID via
    /// IOKit; tests swap in a fixed string.
    static var uuidProvider: () -> String? = { readPlatformUUID() }

    /// 64-char lowercase hex SHA-256 of the hardware UUID, or nil when the
    /// UUID is unavailable (callers treat nil as "cannot fingerprint").
    static func fingerprint() -> String? {
        guard let uuid = uuidProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(uuid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// IOKit read of the stable hardware UUID. Private on purpose: callers
    /// go through `fingerprint()` so the raw value never escapes this file.
    private static func readPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service,
                                                        "IOPlatformUUID" as CFString,
                                                        kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? String
    }
}
