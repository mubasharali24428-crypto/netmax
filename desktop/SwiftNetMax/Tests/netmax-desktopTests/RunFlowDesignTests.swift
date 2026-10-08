import XCTest
import SwiftUI
@testable import netmax_desktop

final class RunFlowDesignTests: XCTestCase {
    func testModeLabViewInstantiates() {
        let view = ModeLabView()
        XCTAssertNotNil(view)
    }
}
