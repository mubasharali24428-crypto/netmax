import SwiftUI

/// W5-U3/U1 — compact time-range selector for the QoE timeline.
struct TimelineRangePicker: View {
    let selection: Binding<TimelineRange>

    var body: some View {
        Picker("Range", selection: selection) {
            Text("1h").tag(TimelineRange.oneHour)
            Text("24h").tag(TimelineRange.oneDay)
            Text("7d").tag(TimelineRange.sevenDays)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Timeline range")
        .accessibilityHint("How far back the timeline shows measurements")
    }
}

enum TimelineRange: String, CaseIterable, Identifiable {
    case oneHour
    case oneDay
    case sevenDays

    var id: String { rawValue }

    /// Lookback in seconds.
    var seconds: TimeInterval {
        switch self {
        case .oneHour: return 3600
        case .oneDay: return 86_400
        case .sevenDays: return 604_800
        }
    }

    var displayName: String {
        switch self {
        case .oneHour: return "Last hour"
        case .oneDay: return "Last 24 hours"
        case .sevenDays: return "Last 7 days"
        }
    }

    #if DEBUG
    static func selfCheck() -> Bool {
        TimelineRange.allCases.allSatisfy { $0.seconds > 0 }
    }
    #endif
}
