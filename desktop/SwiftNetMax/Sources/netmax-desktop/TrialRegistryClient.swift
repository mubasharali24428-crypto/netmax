//  TrialRegistryClient.swift — hardware-bound trial activation against the
//  NetMax trial registry server (see trial_server/).
//
//  Protocol (must match trial_server/server.py):
//    POST /v1/trial/activate  {fingerprint_sha256, app_version, vm_suspected}
//      -> 200 {ok, trial_start, trial_end, token}
//      -> 403 {ok:false, error: trial_already_consumed | vm_not_allowed}
//    GET /v1/trial/status?fp=<hex>&token=<hex>
//      -> 200 {ok, active, trial_start, trial_end} | 403/404 unknownOrConsumed
//
//  token = HMAC-SHA256(secret, "<fp>|<start>|<end>") hex. The client verifies
//  the token locally so any edit of the cached window breaks the signature
//  (tamper-evident cache). SECURITY NOTE: the embedded secret is extractable
//  from the binary by a determined attacker — accepted per the project's
//  threat model ("a determined pirate wins"); the server is authoritative
//  whenever online. The secret MUST equal the server's NETMAX_TRIAL_HMAC_SECRET.
//
//  The transport is injectable: production does a synchronous URLSession call,
//  tests stub it. Nothing here does I/O at init.

import Foundation
import CryptoKit
import Security

// MARK: - Token

/// Server-issued trial token, HMAC-bound to (fingerprint, start, end).
enum TrialToken {

    static func make(fingerprint: String, start: String, end: String, secret: String) -> String {
        let message = "\(fingerprint)|\(start)|\(end)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(token: String, fingerprint: String, start: String, end: String, secret: String) -> Bool {
        constantTimeEqual(token, make(fingerprint: fingerprint, start: start, end: end, secret: secret))
    }

    /// Constant-time compare: no early exit on first mismatch.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ad = Array(a.utf8), bd = Array(b.utf8)
        guard ad.count == bd.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(ad, bd) { diff |= x ^ y }
        return diff == 0
    }
}

// MARK: - Outcomes

enum TrialDenialReason: String {
    case alreadyConsumed = "trial_already_consumed"
    case vmNotAllowed = "vm_not_allowed"
}

enum TrialActivationOutcome {
    case activated(start: String, end: String, token: String)
    case denied(TrialDenialReason)
    case unreachable(Error)
}

enum TrialStatusOutcome {
    case current(start: String, end: String, active: Bool)
    case unknownOrConsumed
    case unreachable(Error)
}

enum TrialRegistryError: Error {
    case notConfigured   // defaultBaseURLString still holds the placeholder
    case badResponse
    case tokenMismatch
    case serverError(Int)
}

// MARK: - Token store

/// Trial token persistence. Keychain in production (survives app deletion and
/// UserDefaults wipes; ThisDeviceOnly so it never roams via iCloud Keychain);
/// in-memory stub in tests (never touches the real keychain).
protocol TrialTokenStore {
    func save(start: String, end: String, token: String)
    func load() -> (start: String, end: String, token: String)?
    func clear()
}

final class KeychainTrialTokenStore: TrialTokenStore {
    private let service = "netmax.trial"
    private let account = "trial-token"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(start: String, end: String, token: String) {
        let dict = ["start": start, "end": end, "token": token]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        // ThisDeviceOnly: a trial bound to THIS Mac must not roam to another.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func load() -> (start: String, end: String, token: String)? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let start = dict["start"], let end = dict["end"], let token = dict["token"],
              !start.isEmpty, !end.isEmpty, !token.isEmpty else {
            return nil
        }
        return (start, end, token)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

final class InMemoryTrialTokenStore: TrialTokenStore {
    private var bundle: (start: String, end: String, token: String)?
    func save(start: String, end: String, token: String) { bundle = (start, end, token) }
    func load() -> (start: String, end: String, token: String)? { bundle }
    func clear() { bundle = nil }
}

// MARK: - Client

struct TrialRegistryClient {

    /// MAX: set this to the deployed registry host before shipping trials.
    /// While the placeholder is present, activation short-circuits to
    /// .unreachable (fail-closed — no network to a bogus host).
    static var defaultBaseURLString = "https://REPLACE-WITH-TRIAL-REGISTRY-HOST"

    /// Offline grace: the cached server window is honored this long past its
    /// end without a successful revalidation, then Free until online again.
    static let offlineGraceInterval: TimeInterval = 72 * 3600

    /// HMAC secret shared with the registry server (server mints, client
    /// verifies). Must equal the server's NETMAX_TRIAL_HMAC_SECRET.
    /// Replace at build time before shipping.
    static let embeddedHMACSecret = "REPLACE-WITH-DEPLOYED-HMAC-SECRET"

    var baseURLString: String = TrialRegistryClient.defaultBaseURLString
    var hmacSecret: String = TrialRegistryClient.embeddedHMACSecret
    var appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"

    /// Injectable transport. Production: synchronous URLSession. Tests: stub.
    var transport: (URLRequest) throws -> (Data, HTTPURLResponse) = TrialRegistryClient.liveTransport

    static func isPlaceholder(_ s: String) -> Bool { s.contains("REPLACE-WITH") }

    static func liveTransport(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        var result: Result<(Data, HTTPURLResponse), Error>?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, resp, err in
            if let err = err {
                result = .failure(err)
            } else if let data = data, let http = resp as? HTTPURLResponse {
                result = .success((data, http))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try result!.get()
    }

    // MARK: Activate

    func activate(fingerprint: String, vmSuspected: Bool) -> TrialActivationOutcome {
        guard !Self.isPlaceholder(baseURLString),
              let url = URL(string: baseURLString + "/v1/trial/activate") else {
            return .unreachable(TrialRegistryError.notConfigured)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "fingerprint_sha256": fingerprint,
            "app_version": appVersion,
            "vm_suspected": vmSuspected,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try transport(req)
        } catch {
            return .unreachable(error)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable(TrialRegistryError.badResponse)
        }
        switch resp.statusCode {
        case 200:
            guard json["ok"] as? Bool == true,
                  let start = json["trial_start"] as? String, !start.isEmpty,
                  let end = json["trial_end"] as? String, !end.isEmpty,
                  let token = json["token"] as? String, !token.isEmpty else {
                return .unreachable(TrialRegistryError.badResponse)
            }
            guard TrialToken.verify(token: token, fingerprint: fingerprint,
                                    start: start, end: end, secret: hmacSecret) else {
                return .unreachable(TrialRegistryError.tokenMismatch)
            }
            return .activated(start: start, end: end, token: token)
        case 403:
            let err = json["error"] as? String ?? ""
            if let reason = TrialDenialReason(rawValue: err) {
                return .denied(reason)
            }
            return .unreachable(TrialRegistryError.badResponse)
        default:
            return .unreachable(TrialRegistryError.serverError(resp.statusCode))
        }
    }

    // MARK: Status (revalidation)

    func status(fingerprint: String, token: String) -> TrialStatusOutcome {
        guard !Self.isPlaceholder(baseURLString) else {
            return .unreachable(TrialRegistryError.notConfigured)
        }
        var comps = URLComponents(string: baseURLString + "/v1/trial/status")
        comps?.queryItems = [
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = comps?.url else {
            return .unreachable(TrialRegistryError.badResponse)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15

        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try transport(req)
        } catch {
            return .unreachable(error)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable(TrialRegistryError.badResponse)
        }
        switch resp.statusCode {
        case 200 where json["ok"] as? Bool == true:
            return .current(start: json["trial_start"] as? String ?? "",
                            end: json["trial_end"] as? String ?? "",
                            active: json["active"] as? Bool ?? false)
        case 403, 404:
            return .unknownOrConsumed
        default:
            return .unreachable(TrialRegistryError.serverError(resp.statusCode))
        }
    }
}
