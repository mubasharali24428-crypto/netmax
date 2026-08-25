//
//  NetContext.swift
//  netmax-desktop
//
//  W13B UA-1 (S-048/S-049): Swift-side network context probe.
//
//  Mirrors netmax_netcontext.py (engine side) with the same rules:
//  - VPN: a utun/ipsec/ppp/tun/tap interface that reports `status: active`
//    AND carries at least one route in `netstat -rn` (macOS keeps several
//    idle utuns around; they must not read as VPN).
//  - Offline: no non-loopback interface has an IPv4/IPv6 address or an
//    active link status. Loopback never counts.
//
//  Pure parse + two Process calls; any probe failure degrades to
//  (online: true, vpn: false) so a broken probe can never block a run —
//  honesty about the network must not require the network.
//

import Foundation

struct NetContext: Equatable {
    let online: Bool
    let vpn: Bool
}

enum NetContextProbe {
    static func detect() -> NetContext {
        let ifconfig = run("/sbin/ifconfig", ["-a"])
        let netstat = run("/usr/sbin/netstat", ["-rn"])
        return NetContext(
            online: isOnline(ifconfig),
            vpn: hasActiveRoutedTunnel(ifconfig: ifconfig, routes: netstat)
        )
    }

    // MARK: - Parsing (static + pure for offline self-checks)

    /// {iface: (addresses, status)} from `ifconfig -a` stdout.
    static func parseInterfaces(_ text: String) -> [String: (inet: [String], status: String)] {
        var interfaces: [String: (inet: [String], status: String)] = [:]
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first != "\t", first != " ", let name = line.split(separator: ":", maxSplits: 1).first {
                current = String(name)
                interfaces[current!] = ([], "")
                continue
            }
            guard let iface = current else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") || trimmed.hasPrefix("inet6 ") {
                let addr = trimmed.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                // Loopback addresses prove nothing about connectivity.
                if addr != "127.0.0.1" && addr != "::1" && !addr.isEmpty {
                    interfaces[iface]?.inet.append(addr)
                }
            } else if trimmed.hasPrefix("status:") {
                interfaces[iface]?.status = trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return interfaces
    }

    /// Interface names that carry at least one route in `netstat -rn`.
    static func parseRoutedInterfaces(_ text: String) -> Set<String> {
        var routed: Set<String> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 4, let last = parts.last {
                routed.insert(String(last))
            }
        }
        return routed
    }

    static func tunnelName(_ name: String) -> Bool {
        for prefix in ["utun", "ipsec", "ppp", "tun", "tap"] {
            if name.hasPrefix(prefix), name.dropFirst(prefix.count).allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    private static func isOnline(_ ifconfig: String) -> Bool {
        for (name, entry) in parseInterfaces(ifconfig) where name != "lo0" {
            if !entry.inet.isEmpty || entry.status == "active" { return true }
        }
        return false
    }

    private static func hasActiveRoutedTunnel(ifconfig: String, routes: String) -> Bool {
        let routed = parseRoutedInterfaces(routes)
        for (name, entry) in parseInterfaces(ifconfig) {
            if tunnelName(name), entry.status == "active", routed.contains(name) {
                return true
            }
        }
        return false
    }

    // MARK: - Process

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "" // degrade honestly-empty; caller treats as "unknown"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Network name (W13B UA-2)

    /// Current network name for tagging runs, or nil when it can't be
    /// determined. macOS hides SSIDs from sandboxed/unsigned apps (the
    /// airport binary is gone and CoreWLAN needs entitlements), so this uses
    /// the service order via `networksetup`: the first hardware port whose
    /// network service is connected supplies its name — which equals the
    /// Wi-Fi SSID on standard home setups. Any failure yields nil; the run
    /// simply records without a network tag (nothing is guessed).
    static func currentNetworkName() -> String? {
        // Prefer the Wi-Fi service name when one exists.
        let services = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard let wifiService = services
            .split(separator: "\n")
            .dropFirst() // header line: "An asterisk (*) denotes..."
            .first(where: { $0.lowercased().contains("wi-fi") })
        else { return nil }
        guard !wifiService.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let info = run("/usr/sbin/networksetup",
                       ["-getairportnetwork", wifiService.trimmingCharacters(in: .whitespaces)])
        // Shape: "Current Wi-Fi Network: HomeNet\n" — nil unless it parses.
        guard let range = info.range(of: "Current Wi-Fi Network:") else { return nil }
        let name = info[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

#if DEBUG
extension NetContextProbe {
    /// Offline self-checks over canned output; returns failure count.
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL"): \(name)")
            if !cond { failures += 1 }
        }
        let lo = "lo0: flags=8049<UP,LOOPBACK,RUNNING> mtu 16384\n\tinet 127.0.0.1\n\tstatus: active\n"
        let en0 = "en0: flags=8863<UP> mtu 1500\n\tinet 192.168.1.23\n\tstatus: active\n"
        let idleUtan = "utun3: flags=8051<UP,POINTOPOINT> mtu 1380\n\tstatus: inactive\n"
        let liveUtan = "utun5: flags=8051<UP,POINTOPOINT> mtu 1380\n\tinet 10.8.0.2\n\tstatus: active\n"

        check("online home wifi, idle utun",
              detectIf(lo + en0 + idleUtan, routes: "") == NetContext(online: true, vpn: false))
        check("offline when only loopback",
              detectIf(lo + idleUtan, routes: "") == NetContext(online: false, vpn: false))
        check("routed active utun ⇒ VPN",
              detectIf(lo + en0 + liveUtan, routes: "default 10.8.0.1 UGSc 0 0 utun5")
                  == NetContext(online: true, vpn: true))
        check("idle utun without route ⇒ no VPN",
              detectIf(lo + en0 + liveUtan, routes: "default 192.168.1.1 UGSc 0 0 en0")
                  == NetContext(online: true, vpn: false))
        return failures
    }

    private static func detectIf(_ ifconfig: String, routes: String) -> NetContext {
        NetContext(online: isOnline(ifconfig), vpn: hasActiveRoutedTunnel(ifconfig: ifconfig, routes: routes))
    }
}
#endif
