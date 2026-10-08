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
        /// Exact release tag name from GitHub Releases (e.g. "v1.0.6").
        let latestTag: String?
        /// True only when both versions parse and latest > current.
        let updateAvailable: Bool
        /// Verified release page URL constructed from the fixed repo and release tag.
        let releaseURL: URL?
        /// Non-nil when the network/API check failed (offline, rate limit, …).
        let errorMessage: String?

        var htmlURL: String? {
            releaseURL?.absoluteString
        }

        init(
            currentVersion: String,
            latestVersion: String?,
            latestTag: String? = nil,
            updateAvailable: Bool,
            releaseURL: URL? = nil,
            htmlURL: String? = nil,
            errorMessage: String?
        ) {
            self.currentVersion = currentVersion
            self.latestVersion = latestVersion
            self.latestTag = latestTag
            self.updateAvailable = updateAvailable
            if let r = releaseURL {
                self.releaseURL = r
            } else if let t = latestTag, let constructed = UpdateChecker.releaseURL(for: t) {
                self.releaseURL = constructed
            } else if let h = htmlURL, let u = URL(string: h), UpdateChecker.isValidReleaseURL(u) {
                self.releaseURL = u
            } else {
                self.releaseURL = nil
            }
            self.errorMessage = errorMessage
        }
    }

    /// Construct a verified release URL from the fixed repo owner/name and release tag.
    static func releaseURL(for tag: String?) -> URL? {
        guard let rawTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTag.isEmpty else {
            return nil
        }
        guard !rawTag.contains("/"), !rawTag.contains("\\"), !rawTag.contains(".."),
              !rawTag.contains("?"), !rawTag.contains("#") else {
            return nil
        }
        guard let encodedTag = rawTag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repoSlug)/releases/tag/\(encodedTag)"
        guard let url = components.url else { return nil }
        guard isValidReleaseURL(url, expectedTag: rawTag) else { return nil }
        return url
    }

    /// Validate that a URL strictly points to this repository's release tag on github.com.
    static func isValidReleaseURL(_ url: URL, expectedTag: String? = nil) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard components.scheme == "https" else { return false }
        guard components.host == "github.com" else { return false }
        guard components.port == nil else { return false }
        guard components.user == nil && components.password == nil else { return false }
        guard components.query == nil && components.fragment == nil else { return false }

        let expectedPrefix = "/\(repoSlug)/releases/tag/"
        guard components.path.hasPrefix(expectedPrefix) else { return false }
        let tagPart = String(components.path.dropFirst(expectedPrefix.count))
        guard !tagPart.isEmpty && !tagPart.contains("/") else { return false }

        if let expectedTag = expectedTag {
            guard let decoded = tagPart.removingPercentEncoding, decoded == expectedTag else {
                return false
            }
        }
        return true
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
        releaseURL: URL? = nil,
        htmlURL: String? = nil,
        errorMessage: String?
    ) -> Outcome {
        let latest = latestTag.map { normalize($0) }
        let canCompare = latest != nil && current != "?"
        let available = canCompare && isNewer(latest!, than: current)
        let resolvedURL = releaseURL ?? latestTag.flatMap { UpdateChecker.releaseURL(for: $0) }
        return Outcome(
            currentVersion: current,
            latestVersion: latest,
            latestTag: latestTag,
            updateAvailable: available,
            releaseURL: resolvedURL,
            htmlURL: htmlURL,
            errorMessage: errorMessage
        )
    }

    /// Perform the network check (button-triggered). On any failure returns
    /// an Outcome with `errorMessage` set and `updateAvailable == false`.
    static func check(timeout: TimeInterval = 15) async -> Outcome {
        let current = currentVersion()
        guard let url = URL(string: apiURL) else {
            return compare(current: current, latestTag: nil, releaseURL: nil,
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
                    current: current, latestTag: nil, releaseURL: nil,
                    errorMessage: "GitHub API returned HTTP \(http.statusCode). \(body)"
                )
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return compare(current: current, latestTag: nil, releaseURL: nil,
                               errorMessage: "Could not parse GitHub release JSON.")
            }
            let tag = obj["tag_name"] as? String
            // D-03: Never use API-returned html_url as destination. Construct strictly from fixed repo and tag.
            let constructedURL = releaseURL(for: tag)
            return compare(current: current, latestTag: tag, releaseURL: constructedURL,
                           errorMessage: tag == nil ? "No release tag found." : nil)
        } catch {
            return compare(current: current, latestTag: nil, releaseURL: nil,
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
