import XCTest
import SwiftUI
@testable import netmax_desktop

final class EmptyStateDesignTests: XCTestCase {
    func testEmptyStateViewInstantiates() {
        let view = EmptyStateView.noHistory {}
        XCTAssertNotNil(view)
    }
}
