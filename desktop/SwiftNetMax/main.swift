// W5-U2 offline harness — exercises TimelineEventMarkersTests.runAll()
// (and re-runs the S1/S2/D1 batteries) against the real compiled objects.
import Foundation

let failures =
    TimelineEventMarkersTests.runAll()
    + TimelineModelTests.runAll()
    + TimelineCorrelationTests.runAll()
    + TimelineTests.runAll()
print("U2_HARNESS_TOTAL_FAILURES=\(failures)")
if failures > 0 { exit(1) }
