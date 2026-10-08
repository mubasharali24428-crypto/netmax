import XCTest
@testable import netmax_desktop

final class AppPreferencesRemoteAITests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "netmax-remote-ai-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshStoreDefaultsRemoteAIToFalse() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.allowRemoteAI)
        XCTAssertNil(defaults.object(forKey: AppPreferences.Keys.allowRemoteAI))
    }

    func testRemoteAIChoicePersistsTrueAndFalse() {
        let first = AppPreferences(defaults: defaults)
        first.allowRemoteAI = true
        XCTAssertTrue(defaults.bool(forKey: AppPreferences.Keys.allowRemoteAI))

        let second = AppPreferences(defaults: defaults)
        XCTAssertTrue(second.allowRemoteAI)
        second.allowRemoteAI = false
        XCTAssertFalse(defaults.bool(forKey: AppPreferences.Keys.allowRemoteAI))
        XCTAssertFalse(AppPreferences(defaults: defaults).allowRemoteAI)
    }

    func testOnlyTheConsentKeyChanges() {
        defaults.set("preserve", forKey: "netmax.tests.sentinel")
        let preferences = AppPreferences(defaults: defaults)
        preferences.allowRemoteAI = true

        XCTAssertEqual(defaults.string(forKey: "netmax.tests.sentinel"), "preserve")
        XCTAssertEqual(defaults.dictionaryRepresentation()["netmax.tests.sentinel"] as? String,
                       "preserve")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.Keys.allowRemoteAI) as? Bool,
                       true)
    }

    func testMalformedStoredValueDefaultsToFalse() {
        defaults.set("enabled", forKey: AppPreferences.Keys.allowRemoteAI)
        XCTAssertFalse(AppPreferences(defaults: defaults).allowRemoteAI)
    }
}
