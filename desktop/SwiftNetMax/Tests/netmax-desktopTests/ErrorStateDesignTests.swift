import XCTest
import SwiftUI
@testable import netmax_desktop

final class ErrorStateDesignTests: XCTestCase {
    func testModeLabErrorViewInstantiates() {
        let view = ModeLabErrorView(rawError: "Mock error")
        XCTAssertNotNil(view)
    }
}
