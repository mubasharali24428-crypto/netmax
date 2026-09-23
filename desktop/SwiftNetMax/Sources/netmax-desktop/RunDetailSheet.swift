//
//  RunDetailSheet.swift
//  netmax-desktop
//
//  ALPHA-A2-04 — Run detail sheet: full-record inspector for one saved
//  measurement (contract P2 `HistoryRecord`).
//
//  Shows the mode badge, every recorded parameter, the exact run timestamp,
//  and the engine's raw result payload (`result_raw`) in a monospaced,
//  scrollable, read-only `TextEditor` with a one-click Copy button backed by
//  `NSPasteboard.general`.
//
//  Presentation: self-contained `.sheet` content — any parent can host it:
//
//      @State private var selectedRun: IdentifiedRun?
//
//      .sheet(item: $selectedRun) { run in
//          RunDetailSheet(record: run.record)
//      }
//
//  Keyboard: Esc dismisses. Covered twice on purpose —
//  `.keyboardShortcut(.cancelAction)` on the Close button handles Esc when
//  the focus ring is outside the output editor, and `.onExitCommand` on the
//  sheet root handles Esc pressed *inside* the `TextEditor` (where button
//  shortcuts don't reach).
//
//  Ownership: consumes Lane B's `HistoryStore`/`HistoryRecord` surface
//  read-only; touches no other file.
//

import AppKit
import SwiftUI

// MARK: - Presentation shim

/// `HistoryRecord` (owned by Lane B) deliberately carries no identity, so it
/// cannot drive `.sheet(item:)` directly. This tiny value-type box adds the
/// missing `id` without touching the shared model. `ts` matches the identity
/// `HistoryView` already uses for its list rows.
struct IdentifiedRun: Identifiable, Equatable {
    let record: HistoryRecord

    var id: Date { record.ts }
}

// MARK: - Sheet

struct RunDetailSheet: View {
    let record: HistoryRecord

    @Environment(\.dismiss) private var dismiss
    @State private var copiedToPasteboard = false
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            summaryGrid
            // M9: human story for bufferbloat records between summary and raw.
            if record.mode == "bloat",
               let g = MetricExtractor.latestBloatGrade(in: record.resultRaw),
               let story = BloatStory.make(fromGrade: g.letter, deltaMs: g.deltaMs) {
                Divider()
                BloatStoryView(story: story)
            }
            Divider()
            outputSection
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 540,
               minHeight: 380, idealHeight: 470)
        .onExitCommand { dismiss() } // Esc closes even from inside the output editor
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.blue)
            Text("Run Details")
                .font(.title2.weight(.semibold))
                .kerning(-0.3) // W8 B1: display-size tracking
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(NetMaxPressStyle()) // W8 A1: press-down feedback
            .keyboardShortcut(.cancelAction) // standard Esc binding
            .accessibilityLabel(Text("Close"))
            .help("Close (Esc)")
        }
    }

    // MARK: Record summary (mode · started · params)

    private var summaryGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                summaryTitle("Mode")
                Text(record.mode)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Mode")
                    .accessibilityValue(record.mode)
            }

            GridRow {
                summaryTitle("Started")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.absoluteFormatter.string(from: record.ts))
                        .help(Self.isoFormatter.string(from: record.ts))
                    Text(Self.relativeFormatter.localizedString(
                        for: record.ts, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Started")
                .accessibilityValue(Self.absoluteFormatter.string(from: record.ts))
            }

            parameterRows
        }
    }

    /// One row per recorded parameter, key-sorted (same order as the
    /// History list summaries). Empty params collapse to one honest row.
    @ViewBuilder
    private var parameterRows: some View {
        let sorted = record.params.sorted { $0.key < $1.key }
        if sorted.isEmpty {
            GridRow {
                summaryTitle("Parameters")
                Text("None recorded")
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Parameters")
                    .accessibilityValue("None recorded")
            }
        } else {
            ForEach(sorted, id: \.key) { key, value in
                GridRow {
                    summaryTitle(key.capitalized)
                    Text("\(value)")
                        .font(.system(.body, design: .monospaced))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(key.capitalized)
                        .accessibilityValue("\(value)")
                }
            }
        }
    }

    private func summaryTitle(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(minWidth: 76, alignment: .leading)
    }

    // MARK: Raw output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Raw Output")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                copyButton
            }

            TextEditor(text: Binding(
                get: { outputText },
                set: { _ in /* engine payload — intentionally read-only */ }
            ))
            .font(.system(.caption, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .cornerRadius(6)
            .frame(minHeight: 170)
            .accessibilityLabel("Raw run output")
            .accessibilityValue(outputText)
            .accessibilityHint("Scrollable, read-only engine output")
        }
    }

    private var copyButton: some View {
        Button {
            copyOutput()
        } label: {
            Label(copiedToPasteboard ? "Copied" : "Copy",
                  systemImage: copiedToPasteboard ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(NetMaxPressStyle()) // W8 A1
        .disabled(outputIsMissing)
        .accessibilityLabel("Copy raw output to the clipboard")
        .accessibilityValue(copiedToPasteboard ? "Copied" : "")
        .help("Copy the raw result payload to the clipboard")
    }

    // MARK: Actions

    /// Copies the verbatim `result_raw` payload onto the general pasteboard
    /// (as plain `.string`) and flashes the button state back after 2s.
    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.resultRaw, forType: .string)
        copiedToPasteboard = true

        revertTask?.cancel()
        revertTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedToPasteboard = false
        }
    }

    // MARK: Derived data

    private var outputIsMissing: Bool { record.resultRaw.isEmpty }

    /// Placeholder-substituted text shown in the editor (never editable).
    private var outputText: String {
        outputIsMissing ? "No output recorded." : record.resultRaw
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    /// Contract P2 wire format (`2026-08-23T12:34:56Z`) — surfaced as the
    /// timestamp row's tooltip for exactness.
    private static let isoFormatter = ISO8601DateFormatter()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

#Preview("Run detail") {
    RunDetailSheet(
        record: HistoryRecord(
            ts: Date(),
            mode: "turbo",
            params: ["streams": 8, "seconds": 10],
            resultRaw: """
            {
              "mode": "turbo",
              "download_mbps": 742.18,
              "streams": 8,
              "seconds": 10,
              "verdict": "healthy"
            }
            """
        )
    )
    .frame(width: 540, height: 470)
}

#Preview("Empty output") {
    RunDetailSheet(
        record: HistoryRecord(ts: Date(), mode: "wifi", params: [:], resultRaw: "")
    )
    .frame(width: 540, height: 470)
}
