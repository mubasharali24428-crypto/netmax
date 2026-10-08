import XCTest
@testable import netmax_desktop

final class UpdateCheckerTests: XCTestCase {
    private let expectedSlug = "mubasharali24428-crypto/netmax"

    func testValidReleaseTagProducesExactGitHubURL() {
        guard let url = UpdateChecker.releaseURL(for: "v1.0.7") else {
            return XCTFail("Expected valid URL for v1.0.7")
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/\(expectedSlug)/releases/tag/v1.0.7")
        XCTAssertNil(url.port)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertTrue(UpdateChecker.isValidReleaseURL(url, expectedTag: "v1.0.7"))
    }

    func testReleaseURLRejectsEmptyAndInvalidTags() {
        XCTAssertNil(UpdateChecker.releaseURL(for: nil))
        XCTAssertNil(UpdateChecker.releaseURL(for: ""))
        XCTAssertNil(UpdateChecker.releaseURL(for: "   "))
        XCTAssertNil(UpdateChecker.releaseURL(for: "../traversal"))
        XCTAssertNil(UpdateChecker.releaseURL(for: "tag/with/slashes"))
        XCTAssertNil(UpdateChecker.releaseURL(for: "tag\\backslash"))
        XCTAssertNil(UpdateChecker.releaseURL(for: "tag?query=1"))
        XCTAssertNil(UpdateChecker.releaseURL(for: "tag#fragment"))
    }

    func testRejectsInsecureOrNonHTTPSchemes() {
        let insecure = [
            "http://github.com/\(expectedSlug)/releases/tag/v1.0.7",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,evil",
            "ftp://github.com/\(expectedSlug)/releases/tag/v1.0.7"
        ]
        for raw in insecure {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(UpdateChecker.isValidReleaseURL(url), "Should reject \(raw)")
        }
    }

    func testRejectsUnrelatedAndLookalikeHosts() {
        let badHosts = [
            "https://evil.com/\(expectedSlug)/releases/tag/v1.0.7",
            "https://github.com.evil.com/\(expectedSlug)/releases/tag/v1.0.7",
            "https://evil-github.com/\(expectedSlug)/releases/tag/v1.0.7",
            "https://api.github.com/\(expectedSlug)/releases/tag/v1.0.7",
            "https://raw.githubusercontent.com/\(expectedSlug)/releases/tag/v1.0.7"
        ]
        for raw in badHosts {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(UpdateChecker.isValidReleaseURL(url), "Should reject \(raw)")
        }
    }

    func testRejectsUserinfoAndNonDefaultPorts() {
        let tricked = [
            "https://user:pass@github.com/\(expectedSlug)/releases/tag/v1.0.7",
            "https://attacker@github.com/\(expectedSlug)/releases/tag/v1.0.7",
            "https://github.com:8080/\(expectedSlug)/releases/tag/v1.0.7",
            "https://github.com:4430/\(expectedSlug)/releases/tag/v1.0.7",
            "https://github.com:80/\(expectedSlug)/releases/tag/v1.0.7"
        ]
        for raw in tricked {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(UpdateChecker.isValidReleaseURL(url), "Should reject \(raw)")
        }
    }

    func testRejectsPathPrefixAndSuffixTricks() {
        let badPaths = [
            "https://github.com/other-owner/netmax/releases/tag/v1.0.7",
            "https://github.com/\(expectedSlug)/releases/tag/v1.0.7/evil",
            "https://github.com/\(expectedSlug)/releases/tag/",
            "https://github.com/\(expectedSlug)/releases",
            "https://github.com/\(expectedSlug)/releases/tag/v1.0.7?redirect=evil.com",
            "https://github.com/\(expectedSlug)/releases/tag/v1.0.7#payload"
        ]
        for raw in badPaths {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(UpdateChecker.isValidReleaseURL(url), "Should reject \(raw)")
        }
    }

    func testCompareIgnoresExternalHtmlURLAndConstructsSafeURL() {
        let outcome = UpdateChecker.compare(
            current: "1.0.6",
            latestTag: "v1.0.7",
            htmlURL: "https://evil.com/fake-release",
            errorMessage: nil
        )
        XCTAssertTrue(outcome.updateAvailable)
        XCTAssertEqual(outcome.latestVersion, "1.0.7")
        XCTAssertNotNil(outcome.releaseURL)
        XCTAssertEqual(outcome.releaseURL?.host, "github.com")
        XCTAssertEqual(outcome.releaseURL?.path, "/\(expectedSlug)/releases/tag/v1.0.7")
        XCTAssertEqual(outcome.htmlURL, outcome.releaseURL?.absoluteString)
    }
}
