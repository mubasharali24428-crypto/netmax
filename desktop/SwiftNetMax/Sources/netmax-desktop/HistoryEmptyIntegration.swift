// AUDIT M9: not mounted in production — wire or remove deliberately.

//
//  HistoryEmptyIntegration.swift
//  netmax-desktop
//
//  ALPHA-A3-10 — Empty-state integration for the History tab, delivered as a
//  ViewModifier so HistoryView.swift itself stays untouched (lane rule).
//
//  Public surface (this file):
//      .historyEmptyOverlay(reader:opaqueBackground:emptyContent:)
//                                  — full control: supply your own empty UI
//                                    and your own record-count reader.
//      .historyEmptyOverlay(buttonTitle:action:)
//                                  — one-line adoption: renders the shipped
//                                    `EmptyStateView.noHistory` preset.
//      Notification.Name.netmaxHistoryDidChange
//                                  — posted whenever the history JSONL changes;
//                                    adopting views can reload on it.
//
//  How emptiness is detected WITHOUT editing HistoryView: both the modifier
//  and HistoryView derive their data from `HistoryStore.shared`, whose backing
//  file URL is public (`HistoryStore.defaultFileURL`). A lightweight vnode
//  watcher (DispatchSource) observes that file — plus a polling fallback while
//  the file does not exist yet — and flips the overlay on/off. The overlay is
//  therefore always in sync with what HistoryView's next `reload()` will see.
//
//  Adoption order safety: until Lane A swaps HistoryView's body per the
//  snippet below, History still draws its own inline "No measurements yet"
//  rows. `opaqueBackground: true` (default) paints the overlay with the
//  window background so those legacy rows are hidden, not doubled. The
//  toolbar (Clear/Refresh) sits OUTSIDE the overlaid content and stays
//  interactive — intentional, so Refresh remains reachable on an empty log.
//
//  ─────────────────────────────────────────────────────────────────────────
//  LANE ADOPTION SNIPPET — HistoryView (drop-in replacement body).
//  Marked here per mission rules; DO NOT apply from this file. Paste into
//  HistoryView.body, replacing ONLY the `List { trendsSection runsSection }`
//  expression; every other modifier below stays attached to the new root:
//
//      var body: some View {
//          Group {
//              if records.isEmpty {
//                  EmptyStateView.noHistory {
//                      // Switch to Mode Lab (tag 1). RootView owns the
//                      // TabView selection; forward via preference/binding
//                      // when wiring, e.g. `onRunRequest()` → selection = 1.
//                  }
//                  .framedForPane()
//              } else {
//                  List {
//                      trendsSection
//                      runsSection
//                  }
//                  .listStyle(.inset(alternatesRowBackgrounds: true))
//              }
//          }
//          .navigationTitle("History")
//          .toolbar { …existing toolbar unchanged… }
//          .confirmationDialog(…unchanged…)
//          .sheet(item: $selectedRun) { …unchanged… }
//          .onAppear(perform: reload)
//          // Optional live refresh: reload whenever the store file changes.
//          .onReceive(NotificationCenter.default.publisher(for: .netmaxHistoryDidChange)) { _ in
//              reload()
//          }
//      }
//  ─────────────────────────────────────────────────────────────────────────
//

import SwiftUI
import Darwin

/// Posted on the main queue whenever the shared history file changes on disk
/// (append, clear, delete/recreate). Object is `nil`. Adopting views may use
/// it to reload; the empty-state overlays below already react to it.
extension Notification.Name {
    static let netmaxHistoryDidChange = Notification.Name("netmax.history.didChange")
}

/// Observes the shared history store and publishes whether it is empty.
///
/// Detection strategy, cheapest-first:
/// 1. vnode `DispatchSource` on `HistoryStore.defaultFileURL` (event-driven,
///    zero CPU while idle),
/// 2. a 2 s polling timer while the file does not exist yet (or after it is
///    deleted/recreated), swapping back to the vnode source once it appears.
///
/// All callbacks marshal onto the main queue, so `isEmpty` is always read on
/// the thread that created this object (SwiftUI's main actor in practice).
final class HistoryEmptinessMonitor: ObservableObject {

    /// True when `readCount()` reports zero readable records.
    @Published private(set) var isEmpty: Bool = true

    private let readCount: () -> Int
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var changeToken: NSObjectProtocol?

    /// - Parameter readCount: Injectable so previews/tests stay deterministic.
    ///   Production default counts exactly what `HistoryStore.shared.loadAll()`
    ///   would return (same silent-skip-of-corrupt-lines semantics).
    init(readCount: @escaping () -> Int = { HistoryStore.shared.loadAll().count }) {
        self.readCount = readCount
        refresh()

        changeToken = NotificationCenter.default.addObserver(
            forName: .netmaxHistoryDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }

        startWatching()
    }

    deinit {
        source?.cancel()          // cancel handler closes the fd
        pollTimer?.invalidate()
        debounce?.cancel()
        if let token = changeToken { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: Watching

    private func startWatching() {
        let fd = open(HistoryStore.defaultFileURL.path, O_EVTONLY)
        guard fd >= 0 else { startPolling(); return }   // no file yet → poll

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self, weak src] in
            // libdispatch handlers receive no arguments; the fired flags are
            // on `data` as a DispatchSource.FileSystemEvent raw value.
            guard let self, let src else { return }
            let event = DispatchSource.FileSystemEvent(rawValue: src.data)
            self.scheduleRefresh()
            if event.contains(.delete) || event.contains(.rename) {
                // File went away or was swapped (e.g. Clear History): fall back
                // to polling until it reappears, then resume vnode watching.
                self.source?.cancel()
                self.source = nil
                self.startPolling()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            if self.source == nil,
               FileManager.default.fileExists(atPath: HistoryStore.defaultFileURL.path) {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.startWatching()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Coalesce bursts of writes (append storms, clear+recreate) into one read.
    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    private func refresh() {
        isEmpty = readCount() == 0
    }
}

// MARK: - Modifier

/// Overlays the History empty state on a view whenever the shared history
/// store holds no records. See the file header for usage and the adoption
/// snippet for the long-term Lane A replacement.
struct HistoryEmptyOverlayModifier<EmptyContent: View>: ViewModifier {

    private let opaqueBackground: Bool
    @ViewBuilder private let emptyContent: () -> EmptyContent

    @StateObject private var monitor: HistoryEmptinessMonitor

    init(
        readCount: @escaping () -> Int,
        opaqueBackground: Bool,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent
    ) {
        self.opaqueBackground = opaqueBackground
        self.emptyContent = emptyContent
        _monitor = StateObject(wrappedValue: HistoryEmptinessMonitor(readCount: readCount))
    }

    func body(content: Content) -> some View {
        content.overlay {
            if monitor.isEmpty {
                Group {
                    emptyContent()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(overlayBackground)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("empty.history.overlay")
            }
        }
    }

    @ViewBuilder
    private var overlayBackground: some View {
        if opaqueBackground {
            // Hides the legacy inline placeholders still drawn by the
            // unmodified HistoryView until Lane A adopts the snippet above.
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Color.clear
        }
    }
}

// MARK: - View API

extension View {

    /// Full-control variant: overlay `emptyContent` while the shared history
    /// store is empty. `readCount` is injected explicitly to keep call sites
    /// unambiguous with the preset overload below (and previews honest).
    ///
    ///     HistoryView()
    ///         .historyEmptyOverlay(readCount: { HistoryStore.shared.loadAll().count }) {
    ///             EmptyStateView.noHistory { goToModeLab() }.framedForPane()
    ///         }
    func historyEmptyOverlay(
        readCount: @escaping () -> Int,
        opaqueBackground: Bool = true,
        @ViewBuilder emptyContent: @escaping () -> some View
    ) -> some View {
        modifier(HistoryEmptyOverlayModifier(
            readCount: readCount,
            opaqueBackground: opaqueBackground,
            emptyContent: emptyContent
        ))
    }

    /// One-line adoption: renders the shipped `EmptyStateView.noHistory`
    /// preset (headline, illustration, single CTA) while history is empty.
    ///
    ///     HistoryView()
    ///         .historyEmptyOverlay(buttonTitle: "Run Your First Measurement") {
    ///             goToModeLab()
    ///         }
    ///
    /// - Parameters:
    ///   - buttonTitle: Override for the preset's default CTA title.
    ///   - action: Invoked by the CTA; typically switches to Mode Lab.
    func historyEmptyOverlay(
        buttonTitle: String = "Run Your First Measurement",
        action: @escaping () -> Void
    ) -> some View {
        historyEmptyOverlay(readCount: { HistoryStore.shared.loadAll().count }) {
            EmptyStateView.noHistory(buttonTitle: buttonTitle, action: action)
                .framedForPane()
        }
    }
}

#if DEBUG
#Preview("Overlay over legacy empty History") {
    // Deterministic: injected reader pretends the store is empty, so the
    // overlay covers whatever the list would draw.
    List {
        Section("Trends") { Text("legacy placeholder").foregroundStyle(.secondary) }
        Section("Past Runs") { Text("legacy placeholder").foregroundStyle(.secondary) }
    }
    .listStyle(.inset(alternatesRowBackgrounds: true))
    .navigationTitle("History")
    .frame(width: 480, height: 420)
    .historyEmptyOverlay(readCount: { 0 }) {
        EmptyStateView.noHistory {}
            .framedForPane()
    }
}

#Preview("Non-empty store → no overlay") {
    List {
        Section("Past Runs") { Text("baseline · 2m ago").foregroundStyle(.secondary) }
    }
    .frame(width: 480, height: 300)
    .historyEmptyOverlay(readCount: { 3 }) {
        EmptyStateView.noHistory {}
    }
}
#endif
