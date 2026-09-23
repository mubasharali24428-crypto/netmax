import XCTest
@testable import netmax_desktop

/// SPM face of the house `runAll()` harnesses (see run_swift_selftests.sh).
///
/// Each enum returns a failure count (0 == pass). One XCTestCase wraps all
/// of them so `swift test` and the shell harness share the same checks.
/// Kept @MainActor because several harnesses touch SwiftUI/AppKit types.
final class SwiftHarnessTests: XCTestCase {

    @MainActor
    func testAllHarnesses() {
        var total = 0
        var ran = 0

        func run(_ name: String, _ body: () -> Int) {
            let n = body()
            ran += 1
            total += n
            if n == 0 {
                print("PASS \(name)")
            } else {
                print("FAIL \(name): \(n) failure(s)")
            }
        }

        run("AnomalyAnnotationsTests") { AnomalyAnnotationsTests.runAll() }
        run("AnomalyEngineTests") { AnomalyEngineTests.runAll() }
        run("DashboardCardsTests") { DashboardCardsTests.runAll() }
        run("EngineIntegrityCheckTests") { EngineIntegrityCheckTests.runAll() }
        run("HistoryStoreTests") { HistoryStoreTests.runAll() }
        run("HistoryCompareTests") { HistoryCompareTests.runAll() }
        run("LicenseGateTests") { LicenseGateTests.runAll() }
        run("ModeLabTests") { ModeLabTests.runAll() }
        run("NetContextProbe") { NetContextProbe.runAll() }
        run("NotificationsTests") { NotificationsTests.runAll() }
        run("ReportCardShareSelfCheck") { ReportCardShareSelfCheck.runAll() }
        run("ReportsMonthlyTests") { ReportsMonthlyTests.runAll() }
        run("RunPostProcessorSelfCheck") { RunPostProcessorSelfCheck.runAll() }
        run("ScheduleRunnerSelfCheck") { ScheduleRunnerSelfCheck.runAll() }
        run("StatusBarControllerSelfCheck") { StatusBarControllerSelfCheck.runAll() }
        run("StatusPublisherHookSelfCheck") { StatusPublisherHookSelfCheck.runAll() }
        run("TimelineCorrelationTests") { TimelineCorrelationTests.runAll() }
        run("TimelineEventMarkersTests") { TimelineEventMarkersTests.runAll() }
        run("TimelineModelTests") { TimelineModelTests.runAll(now: Date(timeIntervalSinceReferenceDate: 900_000_000)) }
        run("TimelineTests") { TimelineTests.runAll(now: Date(timeIntervalSinceReferenceDate: 1_000_000_000)) }

        XCTAssertEqual(ran, 20, "expected 20 harnesses")
        XCTAssertEqual(total, 0, "swift harness failures: \(total)")
    }
}
