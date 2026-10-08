import XCTest
import SwiftUI
@testable import netmax_desktop

final class SettingsDesignTests: XCTestCase {
    func testSettingsViewInstantiates() {
        let view = SettingsView()
        XCTAssertNotNil(view)
    }
}
