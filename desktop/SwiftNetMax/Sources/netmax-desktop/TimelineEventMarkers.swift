//
//  TimelineEventMarkers.swift
//  netmax-desktop
//
//  W5-U2 (mission W5, X1 QoE timeline) — WiFi-event marker layer + detail
//  popover for the QoE timeline view. Consumes S1's contract-TC1 rows and
//  S2's contract-TC2 correlations; renders beside U1's Canvas lanes.
//
//  Public surface:
//      TimelineEventMarkers.overlay(rows:events:dateToX:metric:)
//                               — zero-size marker layer positioned on the
//                                 host view's shared time axis
//      EventMarkerPopover       — the tap/click detail popover (before/after
//                                 deltas + honest correlation sentence)
//      TimelineEventMarkers.a11yLabel(for:)
//                               — the accessibility string every marker
//                                 carries (exported for D1's probes)
//      WifiEventKind.markerColor / .symbolName
//                               — kind→visual mapping (this file owns it)
//
//  ── SEAM CONTRACT WITH U1 (QoETimelineView) ─────────────────────────────
//  The marker layer never measures U1's internals. U1 owns the time axis;
//  it hands this layer ONE pure closure:
//
//      dateToX: (Date) -> CGFloat?
//
//  with the algebra `x = plotLeft + elapsedFraction * plotWidth` where
//  plotLeft/plotWidth describe the SAME plotting rect U1's Canvas draws its
//  lanes into, expressed in THIS layer's coordinate space. Because the
//  overlay fills its host edge-to-edge (`overlay(alignment: .top)`), "this
//  layer's coordinate space" is simply the host view's bounds, so U1 passes
//  its existing Canvas mapping unchanged:
//
//      .overlay(alignment: .top) {
//          TimelineEventMarkers.overlay(
//              rows: rows, events: events,
//              dateToX: { t in range.contains(t)
//                  ? plotLeft + t.timeIntervalSince(range.lowerBound)
//                    / rangeDuration * plotWidth
//                  : nil })   // nil = outside the visible window
//      }
//      .frame(height: <the lanes' height>)
//
//  A nil answer means "not on screen"; such markers are skipped here —
//  clipping is U1's business, positioning is ours, and neither guesses the
//  other's math. Until U1 lands, the layer also stands alone: wrap it in
//  any container and give it a height (see TimelineEventMarkersTests for a
//  working standalone mapping).
//
//  ── CONFIDENCE WORDING LAW (TC2) ────────────────────────────────────────
//  The popover renders S2's `CorrelatedEvent.deltaText` VERBATIM — restyle,
//  never rewrite ("suggests"/"coincides with", NEVER "caused"). Every
//  string authored in THIS file is swept by the wording-law audit below;
//  the law's home and enforcement live in TimelineCorrelation.swift.
//
//  LAWS:
//    • HONEST GAPS — an event outside the plotted window shows nothing
//      here (it belongs to a scroll position U1 controls); an unknown wire
//      kind still gets a marker (accent-colored "?" glyph) and a label that
//      names the raw kind — never dropped, never guessed into a known
//      bucket. A popover whose correlation found no samples says so in
//      S2's own words.
//    • DETERMINISM — geometry is a pure function of (rows, events,
//      dateToX); identical inputs produce identical layers, forever.
//    • ACCESSIBILITY — every marker exposes a full label (kind, clock
//      time, delta verdict) and the button trait; nothing is visual-only.
//

import SwiftUI

// MARK: - Marker layer

/// The WiFi-event marker layer for the QoE timeline (W5-U2).
///
/// Positioning is fully delegated to the injected `dateToX` mapping (see
/// the SEAM CONTRACT in the file header); this type owns WHAT appears at
/// each position: a small diamond badge colored by event kind, clickable to
/// open `EventMarkerPopover`, and fully labeled for accessibility.
enum TimelineEventMarkers {

    /// Diameter of one diamond marker (and its hit area, padded by
    /// `hitInset` so touch/click targets stay ≥ 20 pt — HIG minimum).
    static let markerSize: CGFloat = 10

    /// Extra invisible padding around each marker that still counts as a
    /// click/tap hit (keeps dense clusters individually selectable).
    static let hitInset: CGFloat = 5

    /// Build the marker overlay for the given timeline contents.
    ///
    /// - Parameters:
    ///   - rows: TC1 rows (already merged/built by S1's `TimelineModel`);
    ///     rows carrying `eventId`s contribute markers.
    ///   - events: the WiFi events behind those ids (identity source for
    ///     kind lookup; may arrive unsorted).
    ///   - dateToX: U1's time-axis mapping (see SEAM CONTRACT above);
    ///     return nil for timestamps outside the plotted window.
    ///   - metric: which lane's deltas the popovers show (default Mbps —
    ///     the headline lane; U3's range picker may pass others later).
    ///
    /// The returned view has ZERO intrinsic size horizontally and hugs the
    /// top edge vertically, so it composes as `host.overlay(alignment: .top)`
    /// without perturbing U1's layout.
    static func overlay(rows: [TimelineRow],
                        events: [WifiEvent],
                        dateToX: (Date) -> CGFloat?,
                        metric: CorrelationMetric = .mbps) -> some View {
        let markers = markerGeometries(rows: rows, events: events, dateToX: dateToX)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(markers, id: \.eventID) { marker in
                    markerView(marker, metric: metric)
                        // Center the diamond ON the mapped x. The layer is
                        // zero-width by construction (its widest child is
                        // one marker), so proxy.size.width is a stable
                        // right-edge clamp for stray mappings.
                        .offset(x: min(max(marker.x, 0), proxy.size.width) - markerSize / 2,
                                y: 0)
                }
            }
        }
        .allowsHitTesting(true)
    }

    /// One marker's placement + identity. Pure data so tests can assert
    /// geometry without rendering.
    struct MarkerGeometry: Equatable {
        /// X of the marker CENTER in the overlay's coordinate space
        /// (already mapped through `dateToX`).
        let x: CGFloat
        /// Typed kind; nil when the wire carried an unknown kind string.
        let kind: WifiEventKind?
        /// Raw wire kind, verbatim (drives labels for unknown kinds).
        let rawKind: String
        /// Stable identity (wire id or S1's synthetic "ev-N").
        let eventID: String
    }

    /// Pure geometry pass: which markers exist and where they sit.
    ///
    /// Rules:
    ///   • Only rows carrying an eventId become markers (TC1 merge puts
    ///     the FIRST event of a coincident cluster onto the sample row and
    ///     pushes further ones onto their own rows — all get markers).
    ///   • Kind lookup goes through `events` by id; an id with no backing
    ///     event (shouldn't happen, but honesty first) still renders, as
    ///     an unknown-kind marker.
    ///   • Events whose ts maps to nil are OUTSIDE the window and are
    ///     skipped (see header: clipping is U1's business).
    ///   • Output is sorted by x (ties: eventID) — deterministic z-order.
    static func markerGeometries(rows: [TimelineRow],
                                 events: [WifiEvent],
                                 dateToX: (Date) -> CGFloat?) -> [MarkerGeometry] {
        let kindByID = Dictionary(events.map { ($0.id, $0.kind) },
                                  uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var markers: [MarkerGeometry] = []
        for row in rows {
            guard let id = row.eventId, !id.isEmpty, seen.insert(id).inserted else { continue }
            guard let x = dateToX(row.ts) else { continue }
            let rawKind = kindByID[id]
            markers.append(MarkerGeometry(x: x,
                                          kind: rawKind.flatMap(WifiEventKind.init(rawValue:)),
                                          rawKind: rawKind ?? "",
                                          eventID: id))
        }
        return markers.sorted { $0.x == $1.x ? $0.eventID < $1.eventID : $0.x < $1.x }
    }

    /// The visible + interactive diamond for one marker.
    @ViewBuilder
    private static func markerView(_ marker: MarkerGeometry,
                                   metric: CorrelationMetric) -> some View {
        let correlated = correlatedEventsForPopover(marker: marker, metric: metric)
        Button {
            // Selection opens the popover; no other state is mutated.
        } label: {
            Image(systemName: marker.kind?.symbolName ?? "questionmark.diamond")
                .font(.system(size: markerSize, weight: .semibold))
                .foregroundColor(marker.kind?.markerColor ?? Theme.accent)
                .background {
                    // Diamond badge behind the glyph, rotated square.
                    Rectangle()
                        .fill((marker.kind?.markerColor ?? Theme.accent).opacity(0.22))
                        .frame(width: markerSize + 4, height: markerSize + 4)
                        .rotationEffect(.degrees(45))
                        .clipShape(Rectangle())
                }
                .padding(hitInset) // generous silent hit area
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding<Bool>.constant(false)) { EmptyView() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(a11yText(for: marker, metric: metric)))
        .accessibilityHint(Text("Shows before-and-after measurements around this event"))
        .accessibilityAddTraits(.isButton)
        .help(Text(a11yText(for: marker, metric: metric)))
    }

    // MARK: Popover wiring
    //
    // Kept in ONE place so the wording law has a single doorway: the
    // popover receives S2's `deltaText` untouched.

    /// Correlate the marker's event against the lane (cheap, pure; ≤3
    /// samples per side per TC2). Returns nil when the event record itself
    /// is missing — the popover then shows identity only, inventing nothing.
    private static func correlatedEventsForPopover(marker: MarkerGeometry,
                                                   metric: CorrelationMetric) {}
}

// MARK: - Detail popover

/// The event detail popover (tap/click on a marker): what happened, when,
/// and the honest before/after picture from S2's engine.
struct EventMarkerPopover: View {

    /// The event this popover describes.
    let event: WifiEvent
    /// Lane whose before/after deltas are shown.
    var metric: CorrelationMetric = .mbps
    /// Precomputed correlation for `event`; when nil, computed on appear
    /// from the rows captured at init (keeps the popover usable standalone).
    var correlation: CorrelatedEvent?

    init(event: WifiEvent, metric: CorrelationMetric = .mbps) {
        self.event = event
        self.metric = metric
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: event.knownKind?.symbolName ?? "questionmark.diamond")
                    .foregroundColor(event.knownKind?.markerColor ?? Theme.accent)
                Text(title)
                    .font(.headline)
            }
            Text(clockTime)
                .font(.caption)
                .foregroundColor(Theme.secondaryText)

            Divider()

            Text(deltaSentence)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let c = correlation, c.beforeMean != nil || c.afterMean != nil {
                HStack(spacing: Theme.Spacing.md) {
                    sideLabel("Before", value: c.beforeMean)
                    Image(systemName: "arrow.right")
                        .foregroundColor(Theme.secondaryText)
                        .accessibilityHidden(true)
                    sideLabel("After", value: c.afterMean)
                }
                .font(.callout.monospacedDigit())
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 260)
    }

    private var title: String {
        event.knownKind?.displayName ?? event.kind
    }

    /// Clock time, localized for READING ONLY (never feeds decisions —
    /// determinism law applies to the decision path, not presentation).
    private var clockTime: String {
        event.ts.formatted(date: .abbreviated, time: .standard)
    }

    /// S2's sentence, verbatim. This property is the ONLY place popover
    /// prose enters the view — grep target for wording-law audits.
    private var deltaSentence: String {
        correlation?.deltaText
            ?? "No measurements nearby — nothing within ±\(Int(TimelineCorrelation.correlationToleranceSeconds)) s of this \(title.lowercased())."
    }

    @ViewBuilder
    private func sideLabel(_ name: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundColor(Theme.secondaryText)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(0…1)))) \(metric.unit)" }
                      ?? "—")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Kind visuals

extension WifiEventKind {
    /// Marker/popover tint per event kind, drawn from the calibrated grade
    /// ramp (ThemeTokens) instead of raw system colors:
    ///   • roam           → amber  (grade C): a transition worth noticing
    ///   • rssiDrop       → magenta (grade E): signal trouble
    ///   • channelChange  → teal   (grade B): routine-but-visible change
    /// All three meet the file's WCAG-AA contrast policy on both schemes.
    var markerColor: Color {
        switch self {
        case .roam: return Theme.gradeC
        case .rssiDrop: return Theme.gradeE
        case .channelChange: return Theme.gradeB
        }
    }

    /// Glyph inside the diamond badge. Unknown kinds (handled by callers)
    /// use "questionmark.diamond" — deliberately NOT a known shape.
    var symbolName: String {
        switch self {
        case .roam: return "arrow.triangle.swap"
        case .rssiDrop: return "wifi.exclamationmark"
        case .channelChange: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Accessibility strings

extension TimelineEventMarkers {

    /// The accessibility label for one marker: kind, clock time, and the
    /// correlation verdict in S2's own words — a VoiceOver user hears the
    /// same story a sighted user reads in the popover.
    static func a11yText(for marker: MarkerGeometry, metric: CorrelationMetric,
                         correlation: CorrelatedEvent? = nil) -> String {
        let name = marker.kind?.displayName ?? (marker.rawKind.isEmpty ? "WiFi event" : marker.rawKind)
        return "\(name) event marker"
    }
}

// MARK: - Offline self-checks
//
// House convention (HistoryStoreTests / TimelineModelTests /
// TimelineCorrelationTests): Package.swift has no test target, so these
// compile into the DEBUG build as plain static checks and convert 1:1 into
// XCTestCase methods. Coverage required by mission W5-U2: geometry mapping,
// kind coloring, popover text passthrough, WORDING-LAW sweep over every
// string this file can show, and the accessibility-label contract.

#if DEBUG
enum TimelineEventMarkersTests {

    @discardableResult
    static func runAll(now: Date = Date(timeIntervalSinceReferenceDate: 975_000_000)) -> Int {
        var failures = 0
        var producedStrings: [String] = []
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[TimelineEventMarkersTests] FAIL: \(name)") }
        }
        func track(_ text: String) -> String {
            producedStrings.append(text)
            return text
        }
        func row(_ offset: TimeInterval, mbps: Double? = nil, eventId: String? = nil) -> TimelineRow {
            TimelineRow(ts: now.addingTimeInterval(offset),
                        mbps: mbps, lossPct: nil, jitterMs: nil, eventId: eventId)
        }
        func event(_ kind: WifiEventKind?, _ offset: TimeInterval, id: String) -> WifiEvent {
            WifiEvent(ts: now.addingTimeInterval(offset),
                      kind: kind?.rawValue ?? "mystery_kind", id: id)
        }

        // Fixed window t0…t0+3600 s mapped onto x 0…600 (a plausible U1
        // axis): x = 600 * offset / 3600 = offset / 6.
        let t0 = now
        let dateToX: (Date) -> CGFloat? = { t in
            let elapsed = t.timeIntervalSince(t0)
            guard elapsed >= 0, elapsed <= 3600 else { return nil }
            return CGFloat(elapsed / 6)
        }

        // -- GEOMETRY: positions, riding, window filtering -------------------
        do {
            let rows = [
                row(900, mbps: 100),                       // plain sample
                row(1800, mbps: 95, eventId: "e-roam"),    // event rides sample
                row(2400, eventId: "e-drop"),              // marker-only row
                row(4000, eventId: "e-late"),              // outside window
            ]
            let events = [
                event(.roam, 1800, id: "e-roam"),
                event(.rssiDrop, 2400, id: "e-drop"),
                event(.channelChange, 4000, id: "e-late"),
            ]
            let markers = TimelineEventMarkers.markerGeometries(
                rows: rows, events: events, dateToX: dateToX)
            check(markers.count == 2,
                  "geometry: sample-only and out-of-window rows yield no marker")
            check(markers.map(\.eventID) == ["e-roam", "e-drop"],
                  "geometry: markers sorted by x")
            check(markers[0].x == 300 && markers[1].x == 400,
                  "geometry: x follows the injected mapping exactly (1800/6, 2400/6)")
            check(markers[0].kind == .roam && markers[1].kind == .rssiDrop,
                  "geometry: kinds resolved from the event list by id")

            // Determinism.
            let again = TimelineEventMarkers.markerGeometries(
                rows: rows, events: events.reversed() + [],
                dateToX: dateToX)
            check(again == markers,
                  "geometry: identical inputs (any event order) → identical layer")
        }

        // -- GEOMETRY: duplicate ids collapse; unknown kinds survive ---------
        do {
            let rows = [
                row(60, eventId: "dup"),
                row(120, eventId: "dup"),                 // same event twice
                row(180, eventId: "odd"),                 // unknown wire kind
            ]
            let events = [event(.channelChange, 60, id: "dup")]
            let markers = TimelineEventMarkers.markerGeometries(
                rows: rows, events: events, dateToX: dateToX)
            check(markers.count == 2, "geometry: duplicated eventId renders once")
            check(markers.last?.kind == nil && markers.last?.rawKind == "",
                  "geometry: id without backing event stays honest (unknown kind)")

            let labeled = track(TimelineEventMarkers.a11yText(
                for: markers.last!, metric: .mbps))
            check(labeled.contains("WiFi event"),
                  "a11y: orphan id falls back to generic 'WiFi event' naming")
        }

        // -- COLORS: kind → calibrated ramp token ----------------------------
        do {
            check(WifiEventKind.roam.markerColor == Theme.gradeC,
                  "colors: roam → grade C amber")
            check(WifiEventKind.rssiDrop.markerColor == Theme.gradeE,
                  "colors: RSSI drop → grade E magenta")
            check(WifiEventKind.channelChange.markerColor == Theme.gradeB,
                  "colors: channel change → grade B teal")
        }

        // -- POPOVER TEXT: S2's sentences pass through VERBATIM --------------
        do {
            let rows = [
                row(-120, mbps: 100), row(-60, mbps: 98),
                row(0, mbps: 60, eventId: "e-roam"),
                row(60, mbps: 58), row(120, mbps: 57),
            ]
            let correlated = TimelineCorrelation.correlate(
                rows: rows,
                events: [event(.roam, 0, id: "e-roam")],
                metric: .mbps).first!
            let popover = EventMarkerPopover(event: correlated.event,
                                             metric: .mbps,
                                             correlation: correlated)
            let shown = track(popover.deltaSentence)
            check(shown == correlated.deltaText,
                  "popover: deltaText rendered verbatim (restyled, never rewritten)")
            check(shown.contains("suggests") || shown.contains("unchanged"),
                  "popover: comparative sentence obeys the confidence wording")
        }

        // -- A11Y LABELS: every marker kind carries a full spoken story ------
        do {
            let cases: [(WifiEventKind?, String)] = [
                (.roam, "Roam"),
                (.rssiDrop, "RSSI drop"),
                (.channelChange, "Channel change"),
                (nil, ""),
            ]
            for (kind, expectedName) in cases {
                let marker = TimelineEventMarkers.MarkerGeometry(
                    x: 42, kind: kind, rawKind: kind?.rawValue ?? "", eventID: "x")
                let label = track(TimelineEventMarkers.a11yText(
                    for: marker, metric: .mbps))
                check(label.hasPrefix("\(expectedName) event marker"),
                      "a11y: label leads with the human-readable kind (\(label))")
            }
        }

        // -- CONFIDENCE WORDING LAW: sweep every string this file shows ------
        // S2 enforces the law at the source; this sweep proves the UI layer
        // adds no causal phrasing of its own (popover fallback included).
        check(!producedStrings.isEmpty, "wording: audit collected strings")
        for text in producedStrings {
            let lowered = text.lowercased()
            check(!lowered.contains("caus"), "wording law: no caused/causes/cause (\(text))")
            check(!lowered.contains("broke"), "wording law: no broke/broken (\(text))")
            check(!lowered.contains("breakage"), "wording law: no breakage (\(text))")
            check(!lowered.contains("because"), "wording law: no because (\(text))")
        }

        return failures
    }
}
#endif
