//
//  ModeLabErrorView.swift
//  netmax-desktop
//
//  A4-04 — Friendly error presentation for Mode Lab failures.
//
//  Takes the RAW engine/bridge error string (the C1 envelope's `error`
//  field, as surfaced by EngineClientError.errorDescription) and renders
//  ErrorAdvisor.advice output: a severity-tinted icon, the mapped headline,
//  one actionable advice sentence, the verbatim technical details behind a
//  collapsible DisclosureGroup, and a Copy Details button that puts
//  ErrorAdvisor.displayText(for:) on the clipboard (advice first, details
//  last — diagnostics are never hidden, only de-emphasized).
//
//  DROP-IN REPLACEMENT for ModeLabView's error branch (for the wiring lane;
//  this lane does NOT modify ModeLabView.swift):
//
//      // 1) In ModeLabView state, alongside resultText:
//      @State private var lastErrorText: String?
//
//      // 2) Replace the catch body:
//      } catch {
//          await MainActor.run {
//              lastErrorText = error.localizedDescription   // raw envelope string,
//                                                           // NOT the "Error: "-prefixed
//                                                           // resultText
//              status = .error
//          }
//      }
//
//      // 3) In resultArea, branch on status:
//      if status == .error, let lastErrorText {
//          ModeLabErrorView(rawError: lastErrorText)
//      } else {
//          /* existing TextEditor(resultText) */
//      }
//
//  Passing `error.localizedDescription` directly keeps the haystack identical
//  to what ErrorAdvisor's rules were written against (netmax.py NetMaxError
//  messages / bridge stderr tails); stripping the legacy "Error: " prefix is
//  unnecessary — matching is case-insensitive substring based.
//
//  Pure presentation: no engine access, no I/O beyond the pasteboard copy.
//

import SwiftUI
import AppKit

/// Severity-styled presentation of one engine failure, powered by
/// `ErrorAdvisor`. Unknown failures fall through to the advisor's honest
/// generic fallback (headline "Unexpected error", warning styling), so this
/// view never fabricates a cause.
struct ModeLabErrorView: View {

    /// The raw error string from the C1 failure envelope. Nil/empty renders
    /// the generic fallback rather than crashing or guessing.
    let rawError: String?

    @State private var showsDetails = false
    @State private var didCopy = false

    private var advice: EngineErrorAdvice { ErrorAdvisor.advice(for: rawError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(advice.headline)
                        .font(.headline)
                        .foregroundStyle(tint)
                        .accessibilityAddTraits(.isHeader)
                    Text(advice.advice)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Test failed: \(advice.headline)")
            .accessibilityValue(advice.advice)

            Divider()

            DisclosureGroup(isExpanded: $showsDetails) {
                Text(technicalDetails)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } label: {
                Label("Technical details", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Technical details")
            .accessibilityHint("Shows or hides the raw engine error text")

            HStack(spacing: 8) {
                Button {
                    copyDetails()
                } label: {
                    Label(didCopy ? "Copied" : "Copy Details",
                          systemImage: didCopy ? "checkmark.circle" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(didCopy)
                .accessibilityLabel("Copy error details")
                .accessibilityHint("Copies the advice and technical details to the clipboard")

                Spacer()

                if !advice.isKnown {
                    Text("Unrecognized failure — report welcome")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.35))
        )
        .onChange(of: rawError) { _ in
            didCopy = false
            showsDetails = false
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Derived presentation

    private var iconName: String {
        switch advice.severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch advice.severity {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    /// Verbatim engine text for the disclosure; never rewritten or truncated.
    private var technicalDetails: String {
        let raw = rawError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "(no technical details were provided by the engine.)" : raw
    }

    private func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ErrorAdvisor.displayText(for: rawError),
                                       forType: .string)
        didCopy = true
    }
}

#if DEBUG
#Preview("Known · out of range") {
    ModeLabErrorView(rawError: "--seconds must be 5..30, got 99")
        .padding()
}

#Preview("Known · DNS down") {
    ModeLabErrorView(rawError: "no DNS resolver reachable")
        .padding()
}

#Preview("Unknown fallback") {
    ModeLabErrorView(rawError: "weird unexpected stack trace 0xDEADBEEF")
        .padding()
}

#Preview("Empty input") {
    ModeLabErrorView(rawError: nil)
        .padding()
}
#endif
