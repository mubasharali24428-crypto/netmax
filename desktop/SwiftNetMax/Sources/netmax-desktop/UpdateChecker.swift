//
//  UpdateChecker.swift
//  netmax-desktop
//
//  Real GitHub Releases update check (task 2). Compares the installed
//  CFBundleShortVersionString against the latest release tag_name on the
//  public repo. Button-triggered only — no background polling, no telemetry.
//  Offline / network failures surface honestly (never claim "up to date"
//  when the check did not complete).
//

import Foundation

enum UpdateChecker {
    /// Canonical release locations for THIS repo (single source of truth).
    static let repoSlug = "mubasharali24428-crypto/netmax"
    static let releasesPageURL = "https://github.com/mubasharali24428-crypto/netmax/releases"
    static let feedbackPageURL = "https://github.com/mubasharali24428-crypto/netmax/discussions"
    static let apiURL = "https://api.github.com/repos/mubasharali24428-crypto/netmax/releases/latest"

    /// Result of one check — pure data, unit-testable via `compare`.
    struct Outcome: Equatable {
        let currentVersion: String
        /// Latest tag with a leading `v` stripped (e.g. "1.0.6"), nil when unknown.
        let latestVersion: String?
        /// True only when both versions parse and latest > current.
        let updateAvailable: Bool
        /// Release page to open when an update is available / for "view releases".
        let htmlURL: String?
        /// Non-nil when the network/API check failed (offline, rate limit, …).
        let errorMessage: String?
    }

    /// Installed app version from the bundle ("?" outside a real bundle).
    static func currentVersion(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> String {
        info["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Compare two dotted version strings. Returns true when `latest` is
    /// strictly greater than `current`. Non-numeric components compare as 0;
    /// either unparsable → false (never claim an update on garbage).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let l = normalize(latest).split(separator: ".").compactMap { Int($0) }
        let c = normalize(current).split(separator: ".").compactMap { Int($0) }
        guard !l.isEmpty, !c.isEmpty,
              normalize(latest).split(separator: ".").count == l.count,
              normalize(current).split(separator: ".").count == c.count
        else { return false }
        let n = max(l.count, c.count)
        for i in 0..<n {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    /// Strip a leading `v`/`V` and whitespace for tag → version comparison.
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 1, t.first == "v" || t.first == "V" {
            t = String(t.dropFirst())
        }
        return t
    }

    /// Pure outcome from versions alone (used by tests and by the network path).
    static func compare(
        current: String,
        latestTag: String?,
        htmlURL: String?,
        errorMessage: String?
    ) -> Outcome {
        let latest = latestTag.map { normalize($0) }
        let canCompare = latest != nil && current != "?"
        let available = canCompare && isNewer(latest!, than: current)
        return Outcome(
            currentVersion: current,
            latestVersion: latest,
            updateAvailable: available,
            htmlURL: htmlURL,
            errorMessage: errorMessage
        )
    }

    /// Perform the network check (button-triggered). On any failure returns
    /// an Outcome with `errorMessage` set and `updateAvailable == false`.
    static func check(timeout: TimeInterval = 15) async -> Outcome {
        let current = currentVersion()
        guard let url = URL(string: apiURL) else {
            return compare(current: current, latestTag: nil, htmlURL: nil,
                           errorMessage: "Invalid update URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NetMaxDesktop", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
                return compare(
                    current: current, latestTag: nil, htmlURL: nil,
                    errorMessage: "GitHub API returned HTTP \(http.statusCode). \(body)"
                )
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return compare(current: current, latestTag: nil, htmlURL: nil,
                               errorMessage: "Could not parse GitHub release JSON.")
            }
            let tag = obj["tag_name"] as? String
            let html = obj["html_url"] as? String ?? releasesPageURL
            return compare(current: current, latestTag: tag, htmlURL: html,
                           errorMessage: tag == nil ? "No release tag found." : nil)
        } catch {
            return compare(current: current, latestTag: nil, htmlURL: nil,
                           errorMessage: "Network error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Offline self-checks

#if DEBUG
enum UpdateCheckerTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ cond: Bool) { failures += cond ? 0 : 1 }

        // Tag normalization.
        check(UpdateChecker.normalize("v1.0.6") == "1.0.6")
        check(UpdateChecker.normalize(" V1.2 ") == "1.2")
        check(UpdateChecker.normalize("1.0.0") == "1.0.0")

        // isNewer: numeric order, missing parts = 0, equal = false.
        check(UpdateChecker.isNewer("1.0.7", than: "1.0.6"))
        check(UpdateChecker.isNewer("v1.1.0", than: "1.0.6"))
        check(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        check(!UpdateChecker.isNewer("1.0.6", than: "1.0.6"))
        check(!UpdateChecker.isNewer("1.0.5", than: "1.0.6"))
        check(!UpdateChecker.isNewer("abc", than: "1.0.6"))
        check(!UpdateChecker.isNewer("1.0.6", than: "?"))

        // compare(): update / no-update / error paths.
        let up = UpdateChecker.compare(
            current: "1.0.6", latestTag: "v1.0.7",
            htmlURL: UpdateChecker.releasesPageURL, errorMessage: nil)
        check(up.updateAvailable && up.latestVersion == "1.0.7")

        let same = UpdateChecker.compare(
            current: "1.0.6", latestTag: "v1.0.6",
            htmlURL: nil, errorMessage: nil)
        check(!same.updateAvailable && same.latestVersion == "1.0.6")

        let offline = UpdateChecker.compare(
            current: "1.0.6", latestTag: nil, htmlURL: nil,
            errorMessage: "Network error: offline")
        check(!offline.updateAvailable && offline.errorMessage != nil)

        // Canonical URLs point at the real repo (was github.com/netmax/…).
        check(UpdateChecker.releasesPageURL.contains("mubasharali24428-crypto/netmax"))
        check(UpdateChecker.feedbackPageURL.contains("mubasharali24428-crypto/netmax"))
        check(UpdateChecker.apiURL.contains("api.github.com/repos/mubasharali24428-crypto/netmax"))

        return failures
    }
}
#endif
