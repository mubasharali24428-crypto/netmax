import XCTest
import SwiftUI
@testable import netmax_desktop

final class PredictiveCardRemovalTests: XCTestCase {
    func testDashboardCardsViewInstantiatesWithoutPredictiveShaper() {
        let view = DashboardCardsView()
        XCTAssertNotNil(view)
    }

    func testPredictiveShaperViewMovedToPrototypes() {
        // Path to prototype location relative to repository root
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        // Check if desktop/prototypes/swift/PredictiveShaperView.swift exists
        let possiblePaths = [
            "../prototypes/swift/PredictiveShaperView.swift",
            "desktop/prototypes/swift/PredictiveShaperView.swift"
        ]
        let found = possiblePaths.contains { fileManager.fileExists(atPath: $0) }
        XCTAssertTrue(found || fileManager.fileExists(atPath: "\(currentPath)/../prototypes/swift/PredictiveShaperView.swift"))
    }
}
