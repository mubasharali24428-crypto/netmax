//
//  BloatStoryView.swift
//  netmax-desktop
//
//  TEAM-1 T1-b — Bufferbloat storytelling card UI.
//
//  Renders a `BloatStory` (T1-a's pure model) as a self-contained,
//  drop-in card: big grade letter tinted from the Theme grade ramp,
//  the cause sentence, three per-activity impact rows, and the single
//  honest suggestion in an accent-tinted callout.
//
//  INTEGRATION NOTES (wiring belongs to separate lanes — this file
//  touches nothing else):
//
//  · Mode Lab (`ModeLabView.swift`, result area): after a successful
//    `bloat` run, parse the payload and build a story, then insert the
//    card above or beside the raw `TextEditor`:
//
//        // delta from "loaded increase:  +123.4 ms", grade from "grade: C"
//        if let story = BloatStory.make(fromGrade: letter, deltaMs: delta) {
//            BloatStoryView(story: story)
//        }
//
//    When the payload carries the delta directly, prefer the exact-band
//    factory instead — the recomputed letter then matches the engine even
//    if copy ever drifts:
//
//        let story = BloatStory.make(from: delta)
//
//    Suggested host state: `@State private var bloatStory: BloatStory?`,
//    set inside the existing `MainActor.run` completion block, cleared on
//    a new run. Keep showing the raw payload too — the card explains the
//    measurement, it does not replace it.
//
//  · Run detail sheet (`RunDetailSheet.swift`): for records whose mode is
//    "bloat" (or "full"), reuse `MetricExtractor.latestBloatGrade(in:
//    record.resultRaw)` (DashboardCardsView.swift) for `(letter, deltaMs)`
//    and render the same card between `summaryGrid` and the raw section:
//
//        if record.mode == "bloat",
//           let g = MetricExtractor.latestBloatGrade(in: record.resultRaw),
//           let story = BloatStory.make(fromGrade: g.letter, deltaMs: g.deltaMs) {
//            Divider()
//            BloatStoryView(story: story)
//                .padding(.horizontal, 16)
//        }
//
//  Styling contract: colors come exclusively from `Theme` (ThemeTokens.swift),
//  spacing from the 4-pt rhythm tokens, radii from `Theme.Radius`. The
//  grade ramp supplies WCAG-checked pairs — never alias system .green/.red.
//

import SwiftUI

/// Drop-in card that tells the human story of one bufferbloat measurement.
///
///     BloatStoryView(story: BloatStory.make(from: 87.0))
///
struct BloatStoryView: View {

    // MARK: - Input

    let story: BloatStory

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            causeSentence

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Array(story.activityImpact.enumerated()), id: \.offset) { _, activity in
                    ActivityRow(activity: activity, tint: gradeColor)
                }
            }

            suggestionCallout
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.separator)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bufferbloat story")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: - Sections

    /// Big grade letter + measured delta + headline label.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            Text(story.gradeLetter)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(gradeColor)
                .accessibilityHidden(true) // letter is spoken via the value below

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Latency under load")
                    .font(.headline)
                if let delta = story.deltaMs {
                    Text("+\(delta.formatted(.number.precision(.fractionLength(1)))) ms")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityLabel("Loaded latency increase \(delta, format: .number.precision(.fractionLength(1))) milliseconds")
                } else {
                    Text("Grade \(story.gradeLetter)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private var causeSentence: some View {
        Text(story.cause)
            .font(.body)
            .foregroundStyle(Theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One honest suggestion, boxed in the brand accent tint.
    /// Copy is user-side action only — never a promise NetMax fixes the link.
    private var suggestionCallout: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("What you can do")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(story.suggestion)
                    .font(.callout)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Theme.Radius.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What you can do")
        .accessibilityValue(story.suggestion)
    }

    // MARK: - Styling helpers

    /// Engine grades map onto the Theme ramp; A+ shares gradeA's green.
    /// The engine never emits "E", but an unknown letter still renders
    /// legibly instead of crashing or guessing a hue.
    private var gradeColor: Color {
        switch story.gradeLetter {
        case "A+", "A": Theme.gradeA
        case "B":       Theme.gradeB
        case "C":       Theme.gradeC
        case "D":       Theme.gradeD
        case "F":       Theme.gradeF
        default:        Theme.secondaryText
        }
    }

    /// Single spoken summary when VoiceOver lands on the card container.
    private var accessibilitySummary: String {
        var parts = ["Grade \(story.gradeLetter)"]
        if let delta = story.deltaMs {
            let ms = delta.formatted(.number.precision(.fractionLength(1)))
            parts.append("\(ms) millisecond increase under load")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Activity row

/// One icon + activity + impact line.
private struct ActivityRow: View {
    let activity: ActivityStory
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: activity.symbolName)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(activity.impact)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.title)
        .accessibilityValue(activity.impact)
    }
}

#if DEBUG
#Preview("A+ — clean line") {
    BloatStoryView(story: BloatStory.make(from: 2.4))
        .padding()
}

#Preview("C — typical home router") {
    BloatStoryView(story: BloatStory.make(from: 120.0))
        .padding()
}

#Preview("F — saturated") {
    BloatStoryView(story: BloatStory.make(from: 650.0))
        .padding()
}

#Preview("Letter-only history entry") {
    BloatStoryView(story: BloatStory.make(fromGrade: "B", deltaMs: nil)!)
        .padding()
}
#endif
