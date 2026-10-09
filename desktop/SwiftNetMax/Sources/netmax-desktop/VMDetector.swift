//  VMDetector.swift — best-effort virtual-machine detection.
//
//  Heuristics (macOS):
//    1. `hw.model` sysctl matched (case-insensitive) against known
//       hypervisor markers.
//    2. `kern.hv_vmm_present` == 1 (set when running under a hypervisor on
//       Apple Silicon; 0 on bare metal — verified on real hardware).
//
//  Best-effort by design: a determined attacker spoofs these. The flag is
//  sent to the trial registry server, which records it and enforces the
//  policy (DENY_VM_TRIALS) — the client never grants itself a trial on the
//  basis of this check.
//
//  Both providers are injectable so tests are deterministic.

import Foundation

enum VMDetector {

    /// Hypervisor markers matched (case-insensitive) against `hw.model`.
    static let hypervisorModelMarkers = [
        "vmware", "virtualbox", "parallels", "qemu", "kvm", "xen", "hyper-v", "bhyve",
    ]

    /// Injectable for tests. Production reads the sysctls.
    static var modelProvider: () -> String = { readSysctlString("hw.model") ?? "" }
    static var hypervisorFlagProvider: () -> Bool = { readSysctlString("kern.hv_vmm_present") == "1" }

    /// True when the machine looks virtualized by either heuristic.
    static func isVirtualMachine() -> Bool {
        let model = modelProvider().lowercased()
        if hypervisorModelMarkers.contains(where: { model.contains($0) }) {
            return true
        }
        return hypervisorFlagProvider()
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
