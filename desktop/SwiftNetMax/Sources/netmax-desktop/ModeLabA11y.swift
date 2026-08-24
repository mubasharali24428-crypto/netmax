//
//  ModeLabA11y.swift
//  netmax-desktop
//
//  ALPHA-A2-09 (ALEX-250 wave-1) — Mode Lab VoiceOver audit addendum.
//
//  PURPOSE
//    Accessibility improvements for ModeLabView.swift, applied EXCLUSIVELY
//    through wrapper APIs (.modifier / .accessibilityAction) so the audited
//    file itself stays untouched. The coordinator attaches this at the
//    hosting site (tab host / RootView composition — not owned here):
//
//        ModeLabView()
//            .modeLabAccessibilityAddendum()
//
//  CONTRACTS
//    • Owned path: desktop/SwiftNetMax/Sources/netmax-desktop/ModeLabA11y.swift.
//      ModeLabView.swift, AppPreferences.swift (Lane C), HistoryStore.swift
//      (Lane B) are consumed/read-only. No UserDefaults access (P1 honored
//      vacuously — nothing persisted here).
//    • Only public SwiftUI/AppKit surface; no private member access into
//      ModeLabView (its internals are `private`, and cross-file `private`
//      access would not compile anyway — by design, see DEFERRED items).
//

import SwiftUI
import AppKit

// MARK: - VoiceOver Audit Checklist (ALPHA-A2-09)
//
// Every item below was verified against ModeLabView.swift as of wave-1.
// Status legend:
//   PASS            — gap absent; control already labeled/hinted/traited well.
//   FIXED HERE      — mitigated by THIS file via wrapper APIs only.
//   OK BY DESIGN    — looks odd but is intentional and AX-safe.
//   DEFERRED (Lane A) — cannot be reached through wrapper APIs because the
//                       affected subviews are `private`; recorded here so the
//                       finding survives until an in-file follow-up lands.

/// Structured record of the audit, kept `internal` so the coordinator (and any
/// future debug pane or test) can enumerate findings instead of parsing prose.
enum ModeLabA11yAudit {

    enum Status: String {
        case pass = "PASS"
        case fixedHere = "FIXED HERE"
        case okByDesign = "OK BY DESIGN"
        case deferredToLaneA = "DEFERRED (Lane A)"
    }

    struct Finding: Identifiable {
        let id: Int
        /// Which control/area of ModeLabView.
        let area: String
        /// The checklist question this finding answers.
        let question: String
        let status: Status
        /// What was done here, or what Lane A should do in-file.
        let resolution: String
    }

    // Labels present? Hints? Traits? Grouping? — one finding per question mark.
    static let findings: [Finding] = [

        Finding(id: 1, area: "Header title Text(\"Mode Lab\")",
                question: "Label present?",
                status: .pass,
                resolution: "Plain Text renders as static text; announced verbatim."),

        Finding(id: 2, area: "Decorative Image(systemName: \"dial.max.fill\")",
                question: "Traits — is it silenced?",
                status: .deferredToLaneA,
                resolution: "Icon is decorative and may announce as 'dial max fill, image'. "
                    + "Not reachable from outside (private subview): add "
                    + ".accessibilityHidden(true) on the Image in-file. Mitigated "
                    + "contextually by the container grouping applied here."),

        Finding(id: 3, area: "statusBadge",
                question: "Grouping — one element or three?",
                status: .pass,
                resolution: "Already collapsed via .accessibilityElement(children: .ignore) "
                    + "with label \"Status\" and value = status label."),

        Finding(id: 4, area: "modePicker (Picker)",
                question: "Label present? Hint?",
                status: .pass,
                resolution: ".labelsHidden() removes the VISUAL label only; AX label "
                    + "\"Engine mode\", value = mode id, and hint are all set."),

        Finding(id: 5, area: "Selected-mode summary Text",
                question: "Label present? Value?",
                status: .pass,
                resolution: "Labeled \"Mode description\" with value = live summary string."),

        Finding(id: 6, area: "parameterStepper rows",
                question: "Labels? Hints? Adjustable trait?",
                status: .deferredToLaneA,
                resolution: "P0 FINDING. Each row applies .accessibilityElement(children: .ignore) "
                    + "at the HStack level, which collapses the Stepper INTO the row and strips "
                    + "the Stepper's own increment/decrement actions — VoiceOver reads label/value/"
                    + "hint correctly but likely cannot ADJUST the value. In-file fix (Lane A): keep "
                    + "the ignore-collapse on the two Texts only and leave the Stepper a separate "
                    + "adjustable element, or add .accessibilityAdjustableAction on the row. "
                    + "Keyboard users retain arrow-key stepping as a workaround today."),

        Finding(id: 7, area: "\"not used by <mode>\" captions",
                question: "Hidden from VO — intentional?",
                status: .okByDesign,
                resolution: "Captions sit inside the row's ignored element; the same fact is "
                    + "conveyed via the row's dynamic accessibilityHint."),

        Finding(id: 8, area: "runButton",
                question: "Label present? Hint? State?",
                status: .pass,
                resolution: "Label embeds the mode id (\"Run turbo\"), hint explains outcome, and "
                    + ".disabled(running) communicates busy state."),

        Finding(id: 9, area: "resultArea (TextEditor)",
                question: "Label? Value? Traits?",
                status: .fixedHere,
                resolution: "Label/value were present but the editor is a TextEditor, so VO offers "
                    + "text-editing affordances on engine output that is read-only by contract. "
                    + "This file adds named actions (Select all results / Copy results) so VO users "
                    + "can capture output without fighting edit affordances. Trait hardening "
                    + "(.isStaticText) must happen in-file."),

        Finding(id: 10, area: "Whole-view grouping",
                question: "Grouping — does VO get one navigable region?",
                status: .fixedHere,
                resolution: "This file wraps the view with .accessibilityElement(children: .contain) "
                    + "+ container label/hint, giving VoiceOver a named \"Mode Lab\" group whose "
                    + "children stay individually reachable."),

        Finding(id: 11, area: "Escape key",
                question: "Traits/behavior — does ESC behave locally?",
                status: .fixedHere,
                resolution: "Added a local no-op .accessibilityAction(.escape) so ESC used inside "
                    + "the Mode Lab group does not bubble outward and dismiss a hosting sheet/tab."),

        Finding(id: 12, area: "Status/result transitions",
                question: "Hints — is completion announced?",
                status: .deferredToLaneA,
                resolution: "idle→running→done/error and resultText changes are silent to VO. "
                    + "Wrapper APIs cannot observe the view's private @State; Lane A should post an "
                    + "AX announcement when a run completes (e.g. onChange(of: status))."),
    ]

    static var deferredFindings: [Finding] {
        findings.filter { $0.status == .deferredToLaneA }
    }

    /// One-line rollup for logs/debug panes.
    static var summary: String {
        let counts = Dictionary(grouping: findings, by: \.status.status)
            .map { "\($0.value.count) \($0.key)" }
            .sorted()
            .joined(separator: ", ")
        return "Mode Lab a11y audit: \(findings.count) findings (\(counts))"
    }
}

private extension ModeLabA11yAudit.Status {
    /// Stable token for the rollup string (avoids leaking rawValue punctuation).
    var status: String { rawValue }
}

// MARK: - Addendum Modifier

/// The entire addendum, attachable as a single modifier. Everything here uses
/// wrapper APIs only — ModeLabView.swift is never edited.
struct ModeLabAccessibilityAddendum: ViewModifier {

    func body(content: Content) -> some View {
        content
            // Finding 10: name the region; children remain individually reachable
            // (unlike .ignore/.combine, .contain preserves child elements).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mode Lab")
            .accessibilityHint(
                "Engine mode picker, parameter steppers, a run button, and a results area."
            )
            // Finding 11: keep ESC local to the group instead of bubbling outward.
            .accessibilityAction(.escape) {
                // Intentional no-op: consuming the event is the fix.
            }
            // Finding 9: give VoiceOver users direct routes to the engine output
            // through the standard responder-chain text actions, mirroring the
            // Edit menu (works on the results TextEditor once it is focused).
            .accessibilityAction(named: "Select all results") {
                Self.sendToFirstResponder(#selector(NSText.selectAll(_:)))
            }
            .accessibilityAction(named: "Copy results") {
                Self.sendToFirstResponder(#selector(NSText.copy(_:)))
            }
    }

    /// Dispatches a standard text action to the key window's first responder
    /// (normally the results NSTextView). Public AppKit surface only — no
    /// reaching into ModeLabView's private state.
    static func sendToFirstResponder(_ action: Selector) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSApp.sendAction(action, to: window.firstResponder, from: nil)
    }
}

// MARK: - Attachment API

extension View {

    /// Attaches the ALPHA-A2-09 Mode Lab accessibility addendum.
    ///
    /// Usage (hosting site, NOT inside ModeLabView.swift):
    ///
    ///     ModeLabView()
    ///         .modeLabAccessibilityAddendum()
    ///
    /// Idempotent-safe: applying twice simply re-wraps the same container
    /// semantics; prefer applying once at the tab host (P3 boundary).
    func modeLabAccessibilityAddendum() -> some View {
        modifier(ModeLabAccessibilityAddendum())
    }
}

#if DEBUG
// MARK: - Debug echo

/// Compile-time-visible audit rollup for the coordinator, e.g. from a debug
/// command or test: `print(ModeLabA11yAudit.summary)`.
@MainActor
func modeLabA11yAuditSummary() -> String {
    ModeLabA11yAudit.summary
        + "\nDeferred to Lane A: "
        + ModeLabA11yAudit.deferredFindings.map(\.area).joined(separator: "; ")
}
#endif
