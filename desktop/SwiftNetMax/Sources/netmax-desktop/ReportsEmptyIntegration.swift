//
//  ReportsEmptyIntegration.swift
//  netmax-desktop
//
//  ALPHA-A3-10 — Empty-state integration for the Reports tab, delivered as a
//  ViewModifier so ReportsView.swift itself stays untouched (lane rule).
//
//  Public surface (this file):
//      .reportsEmptyOverlay(store:buttonTitle:action:)
//                                  — one-line adoption over any store seam;
//                                    renders the shipped
//                                    `EmptyStateView.noResultsToExport` preset.
//      .reportsEmptyOverlay(store:isEmpty:emptyContent:)
//                                  — full control for previews/tests/custom UI.
//
//  Why a modifier is possible here: ReportsView already exposes its emptiness
//  indirectly — `HistoryStoreProviding.loadAll()` is public and the production
//  default (`ReportsView()`) resolves to `SystemHistoryStore` →
//  `HistoryStore.shared`, i.e. the same file this package watches elsewhere.
//  The modifier re-reads through that same seam on appear/scenePhase-active
//  and on `.netmaxHistoryDidChange`, so the overlay tracks exactly what
//  ReportsView's own `.task { reload() }` will show.
//
//  Adoption-order safety: until Lane B swaps ReportsView's inline
//  `emptyState` per the snippet below, both blocks could render at once.
//  Default `opaqueBackground: true` paints over the legacy block so users
//  never see them doubled. The header row ("Reports" + "Last run:") and the
//  export-status footer stay OUTSIDE the overlay by design; pass
//  `opaqueBackground: false` if a lane prefers a see-through variant.
//
//  ─────────────────────────────────────────────────────────────────────────
//  LANE B ADOPTION SNIPPET — ReportsView (drop-in replacement).
//  Marked here per mission rules; DO NOT apply from this file.
//
//  Step 1 — replace the ENTIRE `private var emptyState: some View { … }`
//  computed property in ReportsView.swift with:
//
//      /// Shipped empty-state block (ALPHA-A2-05) with one CTA. RootView owns
//      /// the TabView selection; forward `action` via preference/binding when
//      /// wiring so the button can switch to Mode Lab (tag 1).
//      private var emptyState: some View {
//          EmptyStateView.noResultsToExport {
//              // switchToModeLab() once tab-selection forwarding lands
//          }
//          .framedForPane()
//      }
//
//  Step 2 — delete the now-dead local icon/caption code that lived inside the
//  old property body (nothing else references those pieces).
//  No other line of ReportsView changes: the `if let record = lastRecord`
//  branch keeps choosing resultSummary/exportButtons vs emptyState.
//  ─────────────────────────────────────────────────────────────────────────
//

import SwiftUI

/// Overlays the Reports empty state whenever the viewed store holds no saved
/// results. See the file header for rationale and the Lane B adoption snippet.
struct ReportsEmptyOverlayModifier<EmptyContent: View>: ViewModifier {

    private let store: HistoryStoreProviding
    private let opaqueBackground: Bool
    @ViewBuilder private let emptyContent: () -> EmptyContent

    @State private var isEmpty = true
    @Environment(\.scenePhase) private var scenePhase

    init(
        store: HistoryStoreProviding,
        opaqueBackground: Bool,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent
    ) {
        self.store = store
        self.opaqueBackground = opaqueBackground
        self.emptyContent = emptyContent
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isEmpty {
                    Group {
                        emptyContent()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(overlayBackground)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("empty.export.overlay")
                }
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: .netmaxHistoryDidChange)) { _ in
                refresh()
            }
            // Re-read when the app/tab becomes active again — mirrors
            // ReportsView's own `.onAppear { reload() }` cadence.
            .onChange(of: scenePhase) { phase in
                if phase == .active { refresh() }
            }
    }

    private func refresh() {
        isEmpty = store.loadAll().isEmpty
    }

    @ViewBuilder
    private var overlayBackground: some View {
        if opaqueBackground {
            // Hides the legacy inline "No results yet" block still drawn by
            // the unmodified ReportsView until Lane B adopts the snippet above.
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Color.clear
        }
    }
}

// MARK: - View API

extension View {

    /// Full-control variant: overlay `emptyContent` while `store` reads empty.
    ///
    ///     ReportsView()
    ///         .reportsEmptyOverlay(store: SystemHistoryStore()) {
    ///             EmptyStateView.noResultsToExport {}.framedForPane()
    ///         }
    func reportsEmptyOverlay(
        store: HistoryStoreProviding,
        opaqueBackground: Bool = true,
        @ViewBuilder emptyContent: @escaping () -> some View
    ) -> some View {
        modifier(ReportsEmptyOverlayModifier(
            store: store,
            opaqueBackground: opaqueBackground,
            emptyContent: emptyContent
        ))
    }

    /// One-line adoption over an explicit store (production callers pass
    /// `HistoryStore.shared`-backed `SystemHistoryStore()` or rely on the
    /// convenience below). Renders the shipped
    /// `EmptyStateView.noResultsToExport` preset while no result is saved.
    ///
    ///     ReportsView()
    ///         .reportsEmptyOverlay(buttonTitle: "Run a Measurement") {
    ///             goToModeLab()
    ///         }
    ///
    /// - Parameters:
    ///   - store: The same seam ReportsView was initialized with, so both
    ///     agree on emptiness. Previews/tests should inject the same fake.
    ///   - buttonTitle: Override for the preset's default CTA title.
    ///   - action: Invoked by the CTA; typically switches to Mode Lab.
    func reportsEmptyOverlay(
        store: HistoryStoreProviding,
        buttonTitle: String = "Run a Measurement",
        action: @escaping () -> Void
    ) -> some View {
        reportsEmptyOverlay(store: store) {
            EmptyStateView.noResultsToExport(buttonTitle: buttonTitle, action: action)
                .framedForPane()
        }
    }

    /// Convenience for the stock tab: watches `HistoryStore.shared` — the
    /// exact backing `ReportsView()` uses by default.
    func reportsEmptyOverlay(
        buttonTitle: String = "Run a Measurement",
        action: @escaping () -> Void
    ) -> some View {
        reportsEmptyOverlay(store: SystemHistoryStore(), buttonTitle: buttonTitle, action: action)
    }
}

#if DEBUG
#Preview("Overlay covers legacy empty Reports") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Reports").font(.headline)
        Divider()
        Text("legacy 'No results yet' placeholder")
            .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Text("status footer stays visible").font(.footnote).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 420, height: 380)
    .reportsEmptyOverlay(store: PreviewEmptyStore()) {
        EmptyStateView.noResultsToExport {}
            .framedForPane()
    }
}

#Preview("Saved result → no overlay") {
    VStack {
        Text("result summary would be here").foregroundStyle(.secondary)
    }
    .frame(width: 420, height: 300)
    .reportsEmptyOverlay(store: PreviewFullStore()) {
        EmptyStateView.noResultsToExport {}
    }
}

/// Preview doubles for the two stores above (file-local, DEBUG-only).
private struct PreviewEmptyStore: HistoryStoreProviding {
    func loadAll() -> [HistoryRecord] { [] }
}

private struct PreviewFullStore: HistoryStoreProviding {
    func loadAll() -> [HistoryRecord] {
        [HistoryRecord(
            ts: Date(),
            mode: "baseline",
            params: ["streams": 8],
            resultRaw: "{\"throughput\": 940.5}"
        )]
    }
}
#endif
