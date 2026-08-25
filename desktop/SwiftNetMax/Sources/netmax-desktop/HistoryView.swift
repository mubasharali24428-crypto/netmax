import SwiftUI

/// History tab (contract P2): past runs newest-first plus per-mode trends.
///
/// Layout:
/// - **Hint bar**: one-time Quality Timeline tip (dismissable).
/// - **Undo banner** (W12 T1-a): shown for 30 s after Clear History — one tap
///   restores the cleared batch from the holding bin.
/// - **Search bar** (W12 T1-b): live filter over mode / verdict / date text.
/// - **Trends** section: last ≤20 runs of one mode rendered as simple HStack
///   bar chart (heights scaled to the series min/max). No third-party or
///   Charts dependency needed — plain shapes work on macOS 13.
/// - **Runs** section: every record with a mode badge, relative timestamp,
///   and params summary.
/// - Toolbar: Quality Timeline, Refresh, Restore Last Clear (enabled while a
///   holding bin exists), Clear History (trailing; the only destructive
///   dialogs — destructive-only rule, §16 agency).
struct HistoryView: View {
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    /// One-time feature-discovery flag: set once the user acknowledges the
    /// Quality Timeline hint bar below (persisted across launches).
    @AppStorage("netmax.hints.timelineShown")
    private var timelineHintShown = false

    @State private var records: [HistoryRecord] = []
    @State private var trendMode: String?
    @State private var showingClearConfirmation = false
    @State private var selectedRun: IdentifiedRun?
    @State private var showingTimeline = false
    @State private var timelineRange: TimelineRange = .oneDay

    /// W12 T1-b (audit 091): live search text filtering Past Runs by mode,
    /// verdict/result_raw content, or date substring.
    @State private var searchText = ""

    /// W12 T1-a (audit 093): true for 30 s after a Clear so the undo banner
    /// stays up; tapping Undo restores the holding bin immediately.
    @State private var showingUndoBanner = false

    /// W12 T1-a: owns the banner's auto-dismiss so a second Clear restarts
    /// (rather than stacks) the 30-second window.
    @State private var undoBannerTask: Task<Void, Never>?

    /// W12 T1-a: mirrors whether a restorable cleared batch exists on disk;
    /// drives the "Restore Last Clear" toolbar item's enabled state.
    @State private var holdingBinAvailable = false

    /// W12 T4-a (audit 151): Trends section starts collapsed once the log
    /// grows past 50 runs. User toggles win until the view is recreated.
    @State private var trendsExpanded = false

    /// W12 T4-b (audit 154): run queued by "Delete This Run" in the row
    /// context menu, confirmed through the destructive-only dialog rule.
    @State private var pendingDelete: HistoryRecord?

    // MARK: W13B UB-2 (S-014) — Compare selection mode

    /// Compare mode on/off ("Select to Compare" toolbar toggle). In this
    /// mode every Past Runs row shows a checkbox instead of opening details.
    @State private var compareMode = false
    /// Selected runs' identity keys (max 2), keyed like the store's own
    /// ts+mode dedupe identity so selection survives reloads of equal data.
    @State private var compareSelection: Set<String> = []
    /// Presents the side-by-side comparison sheet once exactly 2 are picked.
    @State private var showingCompare = false

    // MARK: W13B UB-4 (S-034/S-035) — multi-select bulk delete

    /// Bulk-edit mode ("Edit" toolbar toggle). Rows gain checkboxes; the
    /// destructive "Delete Selected" item appears once anything is checked.
    @State private var bulkEditMode = false
    /// Keys of the runs queued for bulk deletion (ts+mode identity).
    @State private var bulkSelection: Set<String> = []
    /// Presents the bulk-delete confirmation (destructive-only rule).
    @State private var showingBulkDeleteConfirmation = false

    /// W12 T4-a (audit 151): collapse threshold for the Trends section.
    static let trendsCollapseThreshold = 50

    /// W12 T1-a (audit 093): how long the post-Clear undo banner stays up.
    static let undoWindow: TimeInterval = 30

    /// W12 T4-a (audit 151): set the first time the user expands Trends; a
    /// manual expand wins over reload-time re-collapse for this visit.
    @State private var userExpandedTrends = false

    /// W12 T4-a (audit 151): true once the user toggles Trends themselves;
    /// reloads then stop overriding their choice for the rest of the visit.
    @State private var userTouchedTrends = false

    /// W13B UA-3 (S-028): run queued for "Add Note…" in the row context menu;
    /// hosts the NSAlert text-input prompt.
    @State private var pendingNoteRecord: HistoryRecord?

    /// W13B UA-3: draft text for the Add Note prompt.
    @State private var noteDraft = ""

    // MARK: W13B UA-2 (S-098) — network change banner

    /// One-time banner state, keyed per network name so a LATER switch
    /// (OfficeNet → HomeNet) can show it again; dismissing "HomeNet" only
    /// suppresses HomeNet announcements. `nil` when there's nothing new.
    @AppStorage("netmax.history.dismissedNetworkBanner")
    private var dismissedNetworkBanner = ""

    /// True while the newest run's network differs from the previous
    /// newest run's AND the user hasn't dismissed this network's banner.
    var networkChangedBannerVisible: Bool {
        guard let newest = newestFirst.first, let previous = newestFirst.dropFirst().first else {
            return false
        }
        return newest.network != previous.network && dismissedNetworkBanner != newest.network
    }

    var body: some View {
        List {
            if networkChangedBannerVisible {
                networkChangeBanner
            }
            if records.count >= 3, !timelineHintShown {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Tip: new Quality Timeline feature")
                    Text("New: see your runs as a timeline with WiFi events — try the Quality Timeline button.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Got it") {
                        timelineHintShown = true
                    }
                    .buttonStyle(NetMaxPressStyle()) // W8 A1
                    .help("Hide this tip permanently")
                    .accessibilityLabel("Got it — dismiss the Quality Timeline hint")
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    // W8 design law #4: the hint reads as a soft material
                    // chip; radius comes from Theme.Radius (control tier).
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(hintFill)
                )
                .listRowSeparator(.hidden)
            }
            if showingUndoBanner {
                undoBanner
            }
            searchBar
            trendsSection
            runsSection
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button {
                    showingTimeline = true
                } label: {
                    Label("Quality Timeline", systemImage: "chart.dots.scatter")
                }
                .disabled(records.isEmpty)
                .help("Open the QoE timeline (throughput, loss, jitter + WiFi events)")
            }
            ToolbarItem {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload history from disk")
            }
            // W12 T1-a (audit 093): Trash-style restore of the LAST cleared
            // batch; enabled exactly while the holding bin holds records.
            ToolbarItem {
                Button {
                    HistoryStore.restoreLastClear()
                    reload()
                } label: {
                    Label("Restore Last Clear", systemImage: "tray.and.arrow.down")
                }
                .disabled(!holdingBinAvailable)
                .help("Bring back the runs removed by the most recent clear")
                .accessibilityIdentifier("history.restoreLastClear")
            }
            ToolbarItem {
                Button {
                    compareMode.toggle()
                    // Leaving the mode clears any half-made selection.
                    if !compareMode { compareSelection = [] }
                    // The two selection modes are mutually exclusive.
                    if compareMode && bulkEditMode { bulkEditMode = false }
                } label: {
                    Label(compareMode ? "Done Comparing" : "Select to Compare",
                          systemImage: compareMode
                              ? "checkmark.square.fill" : "plus.square.on.square")
                }
                .disabled(records.count < 2)
                .help("Pick two runs and see their metrics side by side")
                .accessibilityLabel(Text("Compare runs"))
                .accessibilityValue(Text(compareMode ? "on" : "off"))
            }
            // W13B UB-4 (S-034): Edit toggles multi-select mode for bulk
            // deletion — the standard iOS/macOS "Edit" convention.
            ToolbarItem {
                Button {
                    bulkEditMode.toggle()
                    if !bulkEditMode { bulkSelection = [] }
                    if bulkEditMode && compareMode { compareMode = false }
                } label: {
                    Label(bulkEditMode ? "Done" : "Edit",
                          systemImage: bulkEditMode ? "checkmark.circle.fill" : "pencil")
                }
                .disabled(records.isEmpty)
                .help("Select multiple runs to delete them in one go")
                .accessibilityLabel(Text("Edit history"))
                .accessibilityValue(Text(bulkEditMode ? "on" : "off"))
                .accessibilityIdentifier("history.bulkEdit")
            }
            // §16 wayfinding/familiarity: the destructive action sits at
            // the trailing edge, away from the read-only controls it could
            // be mis-clicked against (macOS puts destructive last).
            ToolbarItem {
                Button {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear history", systemImage: "trash")
                }
                .disabled(records.isEmpty)
                .help("Delete all saved runs")
            }
            // W13B UB-4 (S-035): bulk delete — destructive-only confirmation.
            if bulkEditMode {
                ToolbarItem {
                    Button {
                        showingBulkDeleteConfirmation = true
                    } label: {
                        Label("Delete Selected", systemImage: "trash.fill")
                    }
                    .disabled(bulkSelection.isEmpty)
                    .help("Delete the checked runs (they cannot be restored)")
                    .accessibilityIdentifier("history.bulkDelete")
                }
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete all history", role: .destructive) {
                performClear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(records.count) saved run(s) from this Mac — Undo stays available for \(Int(Self.undoWindow)) seconds.")
        }
        // W12 T4-b (audit 154): per-run destructive action goes through the
        // same confirmation pattern as Clear History (destructive-only rule).
        .confirmationDialog(
            "Delete this run?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete This Run", role: .destructive) {
                if let record = pendingDelete {
                    HistoryStore.shared.delete(record)
                }
                pendingDelete = nil
                reload()
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { record in
                "Removes the \(record.mode) run from \(Self.relativeStamp(record.ts)) from this Mac."
            } ?? "")
        }
        // W13B UB-4 (S-035): bulk delete confirmation — one destructive pass.
        .confirmationDialog(
            "Delete selected runs?",
            isPresented: $showingBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(bulkSelection.count) Run\(bulkSelection.count == 1 ? "" : "s")",
                   role: .destructive) {
                performBulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(bulkSelection.count) saved run\(bulkSelection.count == 1 ? "" : "s") from this Mac. Unlike Clear History, this selection cannot be undone.")
        }
        .sheet(item: $selectedRun) { run in
            RunDetailSheet(record: run.record)
        }
        .alert(
            "Add Note",
            isPresented: Binding(
                get: { pendingNoteRecord != nil },
                set: { if !$0 { pendingNoteRecord = nil } }
            ),
            presenting: pendingNoteRecord
        ) { record in
            // W13B UA-3 (S-028): NSAlert-style text-input prompt; empty text
            // clears the note.
            TextField("Note", text: $noteDraft)
            Button("Save") {
                HistoryStore.shared.updateNote(noteDraft, for: record)
                noteDraft = ""
                pendingNoteRecord = nil
                reload()
            }
            Button("Cancel", role: .cancel) {
                noteDraft = ""
                pendingNoteRecord = nil
            }
        } message: { record in
            Text("A short annotation shown with this \(record.mode) run (e.g. “moved router”).")
        }
        .sheet(isPresented: $showingTimeline) {
            TimelineSheet(rows: TimelineModel.build(
                historyFileURL: HistoryStore.defaultFileURL,
                eventsFileURL: WifiEventsReader.defaultFileURL
            ))
        }
        // W13B UB-2 (S-014): side-by-side comparison of the two picked runs.
        .sheet(isPresented: $showingCompare) {
            if let pair = comparePair {
                RunCompareSheet(older: pair.older, newer: pair.newer)
            } else {
                Text("Pick exactly two runs to compare.")
                    .padding(24)
            }
        }
        .onAppear(perform: reload)
    }

    /// UB-2: the two currently selected records, oldest-first for the sheet
    /// (left column = earlier run, right = newer). Nil until exactly two
    /// distinct stored records match the selection keys.
    private var comparePair: (older: HistoryRecord, newer: HistoryRecord)? {
        let picked = records.filter { compareSelection.contains(Self.compareKey(of: $0)) }
        guard picked.count == 2 else { return nil }
        let ordered = picked.sorted { $0.ts < $1.ts }
        return (ordered[0], ordered[1])
    }

    /// Selection identity — the same ts+mode pair the store round-trips
    /// losslessly and uses for its own merge/dedupe.
    static func compareKey(of record: HistoryRecord) -> String {
        "\(record.ts.timeIntervalSince1970)|\(record.mode)"
    }

    /// Honest counter line under Compare mode ("0 selected", …).
    static func compareStatusText(selected: Int) -> String {
        switch selected {
        case 0: "Select two runs to compare"
        case 1: "1 run selected — pick one more"
        default: "2 runs selected"
        }
    }

    // MARK: - Sections

    /// W13B UA-2 (S-098): one-time banner when the newest run was measured
    /// on a different network than the one before it. Dismiss persists via
    /// @AppStorage keyed per network, so a later switch re-shows it.
    private var networkChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("Network changed — comparisons now use \(newestFirst.first?.network ?? "the new network") runs only.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Got it") {
                dismissedNetworkBanner = newestFirst.first?.network ?? ""
            }
            .buttonStyle(NetMaxPressStyle())
            .help("Hide this notice for this network")
            .accessibilityLabel(Text("Dismiss the network-change notice"))
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(hintFill)
        )
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    /// W12 T1-a (audit 093): 30-second undo window right after a Clear —
    /// one tap moves the holding bin back into history.
    private var undoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("History cleared")
                .font(.callout)
            Spacer()
            Button("Undo") {
                showingUndoBanner = false
                HistoryStore.restoreLastClear()
                reload()
            }
            .buttonStyle(NetMaxPressStyle())
            .help("Restore the runs that were just cleared")
            .accessibilityLabel("Undo — restore the cleared history")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(hintFill)
        )
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    /// W12 T1-b (audit 091): live filter field directly under the toolbar.
    /// Matches mode names, verdict/result_raw content, and date text.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search mode, verdict, or date…", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(Text("Search history"))
                .accessibilityHint(Text("Filters past runs by mode, verdict text, or date."))
                .accessibilityIdentifier("history.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(hintFill)
        )
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var trendsSection: some View {
        // W12 T4-a (audit 151): with a long log, Trends starts collapsed so
        // Past Runs are reachable without scrolling past the chart.
        Section("Trends") {
            DisclosureGroup(isExpanded: $trendsExpanded) {
                trendsContent
            } label: {
                Label(
                    trendsExpanded ? "Hide trend chart" : "Show trend chart",
                    systemImage: "chart.bar"
                )
                .font(.callout)
            }
            .accessibilityLabel(Text("Trends"))
            .accessibilityValue(Text(trendsExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text(
                records.count > Self.trendsCollapseThreshold
                    ? "Starts collapsed once history grows past \(Self.trendsCollapseThreshold) runs."
                    : "Shows the per-mode mini bar chart."
            ))
            // W12 T4-a (audit 151): a user toggle sticks — reloads triggered
            // by appends/deletes no longer re-collapse (or re-expand) it.
            .onChange(of: trendsExpanded) { _ in
                userTouchedTrends = true
                if trendsExpanded { userExpandedTrends = true }
            }
        }
    }

    /// Previous Trends body, unchanged except for living inside the group.
    @ViewBuilder
    private var trendsContent: some View {
        if let mode = effectiveTrendMode {
            TrendChart(records: Self.trendSeries(for: mode, in: records))
                .padding(.vertical, 4)
        } else {
            Text("Measure to see its trend here.")
                .foregroundStyle(.secondary)
        }
        if availableModes.count > 1 {
            Picker("Mode", selection: $trendMode) {
                ForEach(availableModes, id: \.self) { Text($0) }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var runsSection: some View {
        Section("Past Runs") {
            if records.isEmpty {
                // §16 simplicity: empty states answer "what do I do next"
                // with one specific action, in an honest voice.
                Text("No runs yet. Measure in Mode Lab and they will be saved here.")
                    .foregroundStyle(.secondary)
            } else if filteredRuns.isEmpty {
                // W12 T1-b: honest empty state for an active filter.
                Text("No runs match “\(trimmedQuery)”.")
                    .foregroundStyle(.secondary)
            } else {
                if isFiltering {
                    // W12 T1-b (audit 091): always show how much the filter
                    // narrowed the list.
                    Text("\(filteredRuns.count) of \(records.count) runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(
                            "\(filteredRuns.count) of \(records.count) runs match the search"
                        ))
                }
                // W13B UB-2 (S-014): honest selection counter while comparing.
                if compareMode {
                    Text(Self.compareStatusText(selected: compareSelection.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Runs selected for comparison"))
                        .accessibilityValue(Text(
                            Self.compareStatusText(selected: compareSelection.count)))
                }
                ForEach(newestFilteredFirst, id: \.ts) { record in
                    // W13B UB-2/UB-4: in Compare or bulk-Edit mode rows carry
                    // a checkbox instead of opening details on click.
                    if compareMode || bulkEditMode {
                        HStack(spacing: 8) {
                            selectionToggle(for: record)
                            HistoryRow(record: record, allRecords: records)
                        }
                    } else {
                        Button {
                            selectedRun = IdentifiedRun(record: record)
                        } label: {
                            HistoryRow(record: record, allRecords: records)
                        }
                        .buttonStyle(NetMaxPressStyle()) // W8 A1: press feedback
                        .netMaxHoverLift() // W9 G3
                        // W12 T4-b (audits 152/154): right-click shortcuts for the
                        // three per-run actions; same targets as the visible UI.
                        .contextMenu {
                            Button("Open Details") {
                                selectedRun = IdentifiedRun(record: record)
                            }
                            Button("Copy Result") {
                                copyResult(of: record)
                            }
                            // W13B UA-3 (S-028): annotate a run ("moved router").
                            Button(record.note == nil ? "Add Note…" : "Edit Note…") {
                                pendingNoteRecord = record
                            }
                            Button("Delete This Run", role: .destructive) {
                                pendingDelete = record
                            }
                        }
                    }
                }
            }
        }
    }

    /// W13B UB-2/UB-4: the row checkbox shared by Compare mode (caps at 2
    /// and auto-opens the sheet) and bulk-edit mode (unbounded selection).
    private func selectionToggle(for record: HistoryRecord) -> some View {
        let isCompare = compareMode
        return Toggle(isOn: Binding(
            get: {
                (isCompare ? compareSelection : bulkSelection)
                    .contains(Self.compareKey(of: record))
            },
            set: { on in
                let key = Self.compareKey(of: record)
                if isCompare {
                    if on {
                        // Cap at two: the oldest pick falls off.
                        if compareSelection.count >= 2 {
                            compareSelection.removeFirst()
                        }
                        compareSelection.insert(key)
                    } else {
                        compareSelection.remove(key)
                    }
                    showingCompare = compareSelection.count == 2
                } else {
                    if on {
                        bulkSelection.insert(key)
                    } else {
                        bulkSelection.remove(key)
                    }
                }
            }
        )) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(Text(isCompare
            ? "Select this \(record.mode) run for comparison"
            : "Select this \(record.mode) run for deletion"))
    }

    /// W13B UB-4: one destructive pass over the checked runs.
    private func performBulkDelete() {
        let doomedKeys = bulkSelection
        let doomed = records.filter { doomedKeys.contains(Self.compareKey(of: $0)) }
        HistoryStore.shared.deleteMany(doomed)
        bulkSelection = []
        reload()
    }

    // MARK: - Derived data

    /// Newest-first view of the log (file itself stays oldest-first).
    private var newestFirst: [HistoryRecord] {
        records.sorted { $0.ts > $1.ts }
    }

    /// W12 T1-b: runs surviving the live search filter (file order kept).
    private var filteredRuns: [HistoryRecord] {
        records.filter { Self.matches(trimmedQuery, record: $0) }
    }

    /// Newest-first view of the filtered log.
    private var newestFilteredFirst: [HistoryRecord] {
        filteredRuns.sorted { $0.ts > $1.ts }
    }

    /// Search text without stray whitespace; "" means "no filter".
    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the search field currently narrows the list.
    private var isFiltering: Bool {
        !trimmedQuery.isEmpty
    }

    /// W12 T1-b (audit 091): one predicate for the whole feature — case-
    /// insensitive substring match on mode, verdict/result_raw content, or
    /// any of the run's date renderings (ISO-8601 UTC stamp, local date,
    /// local time). Empty query matches everything. Static + pure so it can
    /// be self-checked offline.
    static func matches(_ query: String, record: HistoryRecord) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return record.mode.localizedCaseInsensitiveContains(needle)
            || record.resultRaw.localizedCaseInsensitiveContains(needle)
            || dateTexts(of: record.ts).contains {
                $0.localizedCaseInsensitiveContains(needle)
            }
    }

    /// The date strings a user might type against a run's timestamp.
    static func dateTexts(of date: Date) -> [String] {
        [
            ISO8601DateFormatter().string(from: date),
            localDateFormatter.string(from: date),
            localTimeFormatter.string(from: date),
        ]
    }

    private static let localDateFormatter: DateFormatter = makeLocalFormatter("yyyy-MM-dd")
    private static let localTimeFormatter: DateFormatter = makeLocalFormatter("HH:mm:ss")

    private static func makeLocalFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    private var availableModes: [String] {
        Array(Set(records.map(\.mode))).sorted()
    }

    /// Mode shown in the trends section: user pick, else most recent mode.
    private var effectiveTrendMode: String? {
        if let trendMode, availableModes.contains(trendMode) { return trendMode }
        return newestFirst.first?.mode
    }

    /// Last ≤20 runs of `mode`, oldest-first so the chart reads left→right.
    static func trendSeries(for mode: String, in records: [HistoryRecord]) -> [HistoryRecord] {
        let matching = records.filter { $0.mode == mode }.sorted { $0.ts < $1.ts }
        return Array(matching.suffix(20))
    }

    private func reload() {
        records = HistoryStore.shared.loadAll()
        // W12 T1-a: keep the Restore item's enabled state honest across
        // appends, deletes, clears, restores, and other windows' actions.
        holdingBinAvailable = HistoryStore.shared.holdingBinExists()
        if let current = trendMode, !availableModes.contains(current) {
            trendMode = nil // cleared history or unknown mode → fall back
        }
        applyTrendsCollapseDefault()
    }

    /// W12 T1-a (audit 093): Clear now soft-deletes into the holding bin;
    /// open a 30-second undo window afterwards. A second Clear replaces the
    /// bin AND restarts this window (the task handle keeps them from stacking).
    private func performClear() {
        HistoryStore.shared.clear()
        reload()
        undoBannerTask?.cancel()
        showingUndoBanner = true
        undoBannerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.undoWindow * 1_000_000_000))
            if !Task.isCancelled {
                showingUndoBanner = false
            }
        }
    }

    /// W12 T4-a (audit 151): re-collapse Trends on reload once the log passes
    /// the threshold, unless the user expanded it during this visit.
    private func applyTrendsCollapseDefault() {
        if records.count > Self.trendsCollapseThreshold {
            trendsExpanded = userExpandedTrends
        } else if !userTouchedTrends {
            trendsExpanded = true
        }
    }

    /// Clipboard payload for "Copy Result": the engine's raw result text.
    private func copyResult(of record: HistoryRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.resultRaw, forType: .string)
    }

    /// Short relative stamp used in the delete confirmation message.
    private static func relativeStamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Hint-bar fill: `.ultraThinMaterial` chip per W8 law #4; users with
    /// Reduce Transparency get an opaque surface instead of blur (skill
    /// §14) so the tip text never loses legibility.
    private var hintFill: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            : AnyShapeStyle(.ultraThinMaterial)
    }
}

// MARK: - One row

private struct HistoryRow: View {
    let record: HistoryRecord

    /// W13B UA-3 (S-057): full log, used only to judge sample thinness for
    /// this record's mode (<5 total runs ⇒ "low n" tag).
    var allRecords: [HistoryRecord] = []

    /// W13B UA-3: true when the record's mode has fewer than
    /// `ReportCardModel.lowSampleThreshold` total samples in the log.
    var isLowSample: Bool {
        !allRecords.isEmpty && ReportCardModel.isLowSample(mode: record.mode, records: allRecords)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.mode)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                if isLowSample {
                    // W13B UA-3 (S-057): honest confidence tag for sparse data.
                    Text("low n")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                        .accessibilityLabel(Text("fewer than \(ReportCardModel.lowSampleThreshold) samples — low confidence"))
                        .help("Fewer than \(ReportCardModel.lowSampleThreshold) runs of this mode — treat the result as low-confidence")
                }
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: record.ts, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(paramsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let note = record.note, !note.isEmpty {
                // W13B UA-3 (S-028): the run's user annotation.
                Text(note)
                    .font(.caption.italic())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Compact `key=value` summary of the run parameters.
    private var paramsSummary: String {
        record.params.isEmpty
            ? "no parameters"
            : record.params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
    }
}

// MARK: - Run comparison sheet (W13B UB-2, S-014)

/// Side-by-side metrics table for two picked history runs. Rows are the
/// shared dashboard metrics (speed / loss / bloat grade + delta) plus mode
/// and timestamp; "—" honestly marks what a payload never carried. Parsing
/// goes through MetricExtractor so this table can never disagree with the
/// dashboard cards or the monthly summary.
struct RunCompareSheet: View {
    let older: HistoryRecord
    let newer: HistoryRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "plus.square.on.square")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Compare Runs")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("\(Self.stamp(older.ts))  →  \(Self.stamp(newer.ts))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Comparing an earlier run to a newer run"))

            // Metrics table: label column + one value column per run.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("").gridCellAnchor(.leading)
                    columnHeader(mode: older.mode,
                                 time: Self.relative(older.ts))
                    columnHeader(mode: newer.mode,
                                 time: Self.relative(newer.ts))
                }
                Divider().gridCellUnsizedAxes([.horizontal])
                compareRow(label: "Speed (Mbps)",
                           older: Self.speedText(older), newer: Self.speedText(newer))
                compareRow(label: "Packet loss (%)",
                           older: Self.lossText(older), newer: Self.lossText(newer))
                compareRow(label: "Bufferbloat grade",
                           older: Self.gradeText(older), newer: Self.gradeText(newer))
                compareRow(label: "Loaded latency Δ",
                           older: Self.deltaText(older), newer: Self.deltaText(newer))
            }
            .accessibilityElement(children: .contain)

            Spacer(minLength: 0)

            Text("Only values each run actually measured are shown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 320, idealHeight: 360)
        .accessibilityIdentifier("history.compareSheet")
    }

    private func columnHeader(mode: String, time: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mode)
                .font(.subheadline.weight(.semibold))
            Text(time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .gridCellAnchor(.leading)
    }

    /// One metric row: honest per-run cells; when both runs carry the value,
    /// a delta line rides under the label.
    private func compareRow(label: String, older: String, newer: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.medium))
                .gridCellAnchor(.leading)
            Text(older).monospacedDigit()
            Text(newer).monospacedDigit()
        }
    }

    // MARK: Cell formatting (shared extractor, honest dashes)

    static func speedText(_ record: HistoryRecord) -> String {
        MetricExtractor.latestSpeedMbps(in: record.resultRaw)
            .map { String(format: "%.1f", $0) } ?? "—"
    }

    static func lossText(_ record: HistoryRecord) -> String {
        MetricExtractor.latestPacketLossPercent(in: record.resultRaw)
            .map { String(format: "%.1f", $0) } ?? "—"
    }

    static func gradeText(_ record: HistoryRecord) -> String {
        MetricExtractor.latestBloatGrade(in: record.resultRaw)?.letter ?? "—"
    }

    static func deltaText(_ record: HistoryRecord) -> String {
        guard let delta = MetricExtractor.latestBloatGrade(in: record.resultRaw)?.deltaMs
        else { return "—" }
        return String(format: "%+.1f ms", delta)
    }

    static func stamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#if DEBUG
// MARK: - Offline self-checks (W13B UB-2 comparison side)
enum HistoryCompareTests {
    @discardableResult
    static func runAll() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[HistoryCompareTests] FAIL: \(name)") }
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fast = HistoryRecord(ts: base, mode: "turbo", params: [:],
                                 resultRaw: "{\"mbps\": 120}\npacket loss: 0.5%")
        let slow = HistoryRecord(ts: base.addingTimeInterval(3600), mode: "baseline",
                                 params: [:],
                                 resultRaw: "{\"mbps\": 60}\ngrade: C")
        // Cells cite only what each payload carried — no cross-contamination.
        check(RunCompareSheet.speedText(fast) == "120.0"
                  && RunCompareSheet.lossText(fast) == "0.5",
              "speed/loss read from the same payload shapes as cards")
        check(RunCompareSheet.gradeText(slow) == "C"
                  && RunCompareSheet.lossText(slow) == "—",
              "missing metric renders an honest dash")
        check(RunCompareSheet.deltaText(fast) == "—",
              "absent loaded-latency delta says so")

        // Selection identity is ts+mode and stable across re-sorts.
        check(HistoryView.compareKey(of: fast)
                  == HistoryView.compareKey(of: HistoryRecord(
                      ts: fast.ts, mode: "turbo", params: [:], resultRaw: "x")),
              "compare key ignores payload text")
        check(HistoryView.compareStatusText(selected: 1)
                  .contains("one more"), "status text guides toward two picks")

        return failures
    }
}
#endif

// MARK: - Trends mini-chart

/// Plain-SwiftUI bar chart: one capsule per run, height scaled between the
/// series' min and max numeric value (first number found in `result_raw`).
private struct TrendChart: View {
    let records: [HistoryRecord]

    var body: some View {
        if let values = values {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(height: barHeight(normalized: normalize(value)))
                    }
                }
                .frame(height: 64, alignment: .bottom)
                .frame(maxWidth: .infinity)

                caption
            }
        } else {
            Text("No numeric result found yet for this mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: some View {
        let count = values?.count ?? 0
        let range = values.map { series in
            "min \(Self.trim(series.min() ?? 0)) – max \(Self.trim(series.max() ?? 0))"
        } ?? ""
        return Text("\(count) run\(count == 1 ? "" : "s") \(range)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    /// Numeric series extracted from each record's raw payload, oldest-first.
    private var values: [Double]? {
        let parsed = records.compactMap { Self.firstNumber(in: $0.resultRaw) }
        return parsed.isEmpty ? nil : parsed
    }

    private func normalize(_ value: Double) -> Double {
        guard let lo = values?.min(), let hi = values?.max(), hi > lo else { return 0.5 }
        return (value - lo) / (hi - lo) // 0...1; constant series reads as mid-height
    }

    private func barHeight(normalized n: Double) -> CGFloat {
        8 + CGFloat(n) * 56 // floor of 8pt so tiny values stay visible
    }

    /// First number (int or decimal) appearing anywhere in the raw payload.
    /// Good enough for trend purposes regardless of exact engine schema.
    static func firstNumber(in raw: String) -> Double? {
        guard let match = raw.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(raw[match])
    }

    private static func trim(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2f", d)
    }
}

#if DEBUG
#endif  // (Offline self-checks for HistoryStore live in HistoryStoreTests.swift.)
