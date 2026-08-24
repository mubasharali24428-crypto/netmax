//
//  TimelineEventMarkers.swift
//  netmax-desktop
//
//  W5-U2 (mission W5, X1 QoE timeline) — WiFi-event marker layer + detail
//  popover for the QoE timeline. Consumes S1's contract-TC1 rows
//  (TimelineModel.swift) and S2's contract-TC2 correlations
//  (TimelineCorrelation.swift); renders beside U1's Canvas lanes.
//
//  Public surface:
//      TimelineEventMarkers.overlay(rows:events:dateToX:metric:)
//                               — zero-size marker layer positioned on the
//                                 host view's shared time axis
//      EventMarkerPopover       — the click/tap detail popover (before/after
//                                 deltas + honest correlation sentence)
//      TimelineEventMarkers.a11yLabel(for:correlation:)
//                               — the accessibility string every marker
//                                 carries (exported for D1's probes)
//      WifiEventKind.markerColor / .symbolName
//                               — kind→visual mapping (this file owns it)
//
//
//  ── SEAM CONTRACT WITH U1 (QoETimelineView) ─────────────────────────────
//
//  The marker layer never measures U1's internals. U1 owns the time axis;
//  it hands this layer ONE pure closure:
//
//      dateToX: (Date) -> CGFloat?
//
//  with the algebra   x = plotLeft + elapsedFraction * plotWidth   where
//  plotLeft/plotWidth describe the SAME plotting rect U1's Canvas draws its
//  lanes into, expressed in THIS layer's coordinate space. Because the
//  overlay fills its host edge-to-edge, "this layer's space" is simply the
//  host view's bounds, so U1 passes its existing Canvas mapping unchanged:
//
//      .overlay(alignment: .top) {
//          TimelineEventMarkers.overlay(
//              rows: rows, events: events,
//              dateToX: { t in
//                  range.contains(t)
//                      ? plotLeft + t.timeIntervalSince(range.lowerBound)
//                        / rangeDuration * plotWidth
//                      : nil   // nil = outside the visible window
//              })
//      }
//      .frame(height: <total lanes height>)
//
//  A nil answer means "not on screen"; such markers are skipped HERE —
//  clipping is U1's business, positioning is ours, and neither guesses the
//  other's math. The closure is called once per event row per layout pass
//  (pure O(events)); nothing is cached, so U1 can resize freely.
//
//  Until U1 lands, the layer also stands alone: wrap it in any container
//  and give it a height (see TimelineEventMarkersTests.runAll for a working
//  standalone mapping).
//
//
//  ── CONFIDENCE WORDING LAW (TC2) ────────────────────────────────────────
//
//  The popover renders S2's `CorrelatedEvent.deltaText` VERBATIM — restyle,
//  never rewrite ("suggests"/"coincides", NEVER "caused"). The law's home
//  and enforcement live in TimelineCorrelation.swift; every string AUTHORED
//  in THIS file is swept by the wording-law audit below so the UI layer can
//  never smuggle causation in around the engine.
//
//  LAWS:
//    • HONEST GAPS — an event outside the plotted window shows nothing
//      here (it belongs to a scroll position U1 controls). An unknown wire
//      kind still gets a marker (accent "?" glyph) labeled with its raw
//      kind — never dropped, never guessed into a known bucket. An event
//      id with no backing record renders honestly as "WiFi event". A
//      correlation that found no samples says so in S2's own words.
//    • DETERMINISM — geometry is a pure function of (rows, events,
//      dateToX); identical inputs produce identical layers, forever.
//    • ACCESSIBILITY — every marker exposes a full spoken label (kind,
//      clock time, correlation verdict), the button trait, and a tooltip;
//      nothing is visual-only.
//

import SwiftUI

// MARK: - Factory

enum TimelineEventMarkers {

    /// Diameter of one diamond badge; padded by `hitInset` on every side
    /// so the silent click target stays comfortably above 20 pt.
    static let markerSize: CGFloat = 12

    /// Extra invisible padding around each marker that still counts as a
    /// hit (keeps dense clusters individually selectable).
    static let hitInset: CGFloat = 6

    /// Build the WiFi-event marker overlay for the given timeline contents.
    ///
    /// - Parameters:
    ///   - rows: TC1 rows (already merged/built by S1's `TimelineModel`);
    ///     rows carrying an `eventId` contribute markers.
    ///   - events: the WiFi events behind those ids (identity source for
    ///     kind lookup; may arrive unsorted).
    ///   - dateToX: U1's time-axis mapping (see SEAM CONTRACT in header);
    ///     return nil for timestamps outside the plotted window.
    ///   - metric: which lane's deltas the popovers show (default Mbps —
    ///     the headline lane; U3's range picker may pass others later).
    ///
    /// The returned view hugs its host's top edge and has zero intrinsic
    /// width impact, composing as `host.overlay(alignment: .top)`.
    static func overlay(rows: [TimelineRow],
                        events: [WifiEvent],
                        dateToX: @escaping (Date) -> CGFloat?,
                        metric: CorrelationMetric = .mbps) -> some View {
        MarkerOverlayView(rows: rows, events: events,
                          dateToX: dateToX, metric: metric)
    }

    // MARK: Geometry

    /// One marker's placement + identity. Pure data so tests can assert
    /// geometry without rendering.
    struct MarkerGeometry: Equatable {
        /// X of the marker CENTER in the overlay's coordinate space
        /// (already mapped through `dateToX`).
        let x: CGFloat
        /// Row timestamp the marker sits at (popover identity fallback).
        let ts: Date
        /// Typed kind; nil when the wire carried an unknown kind string.
        let kind: WifiEventKind?
        /// Raw wire kind, verbatim (labels unknown kinds honestly).
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
    ///     event still renders, as an unknown-kind marker (honest gap).
    ///   • Rows whose ts maps to nil are OUTSIDE the window and skipped
    ///     (header: clipping is U1's business).
    ///   • Output sorted by x (ties: eventID) — deterministic z-order.
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
            markers.append(MarkerGeometry(x: x, ts: row.ts,
                                          kind: rawKind.flatMap(WifiEventKind.init(rawValue:)),
                                          rawKind: rawKind ?? "",
                                          eventID: id))
        }
        return markers.sorted { $0.x == $1.x ? $0.eventID < $1.eventID : $0.x < $1.x }
    }

    // MARK: Accessibility

    /// The accessibility label for one marker: kind, clock time, and the
    /// correlation verdict in S2's own words — a VoiceOver user hears the
    /// same story a sighted user reads in the popover.
    static func a11yLabel(for marker: MarkerGeometry,
                          metric: CorrelationMetric,
                          correlation: CorrelatedEvent?,
                          now: Date? = nil) -> String {
        let name = marker.kind?.displayName
            ?? (marker.rawKind.isEmpty ? "WiFi" : marker.rawKind)
        let time = marker.ts.formatted(date: .omitted, time: .standard)
        let verdict = correlation.map { "\($0.deltaText)" }
            ?? "No measurements nearby."
        return "\(name) event marker, \(time). \(verdict)"
    }
}

// MARK: - Marker layer view

/// The interactive marker layer returned by `TimelineEventMarkers.overlay`.
/// State is exactly one optional selection (which marker's popover is open);
/// everything else is recomputed purely from the captured timeline inputs.
private struct MarkerOverlayView: View {

    let rows: [TimelineRow]
    let events: [WifiEvent]
    let dateToX: (Date) -> CGFloat?
    let metric: CorrelationMetric

    @State private var selection: Selection?

    /// What a presented popover is about: geometry + the backing event
    /// record when one exists (orphans pop over with identity only).
    private struct Selection: Identifiable {
        let geometry: TimelineEventMarkers.MarkerGeometry
        let event: WifiEvent?
        var id: String { geometry.eventID }
    }

    /// Event records by id (first wins; ids are unique per load in S1).
    private var eventByID: [String: WifiEvent] {
        Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// One correlation per event id, computed in a single pass (S2's engine
    /// is pure and cheap: binary search + ≤3-sample means). Popovers and
    /// accessibility labels both read from this — one doorway, one truth.
    private var correlationByEventID: [String: CorrelatedEvent] {
        Dictionary(
            TimelineCorrelation.correlate(rows: rows, events: events, metric: metric)
                .map { ($0.event.id, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Per-marker popover binding: each Button carries its own `.popover`,
    /// anchored at the diamond; the shared selection state decides which
    /// (if any) is presented.
    private func popoverBinding(for id: String) -> Binding<Selection?> {
        Binding(get: { selection?.id == id ? selection : nil },
                set: { selection = $0 })
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(markers, id: \.eventID) { marker in
                    markerView(marker)
                        // Center the diamond ON the mapped x. Clamping to
                        // the host bounds keeps a stray mapping from pushing
                        // a marker into nowhere; window filtering already
                        // removed everything U1 considers off-screen.
                        .offset(x: min(max(marker.x, 0), proxy.size.width)
                                   - TimelineEventMarkers.markerSize / 2,
                                y: 0)
                }
            }
        }
    }

    private var markers: [TimelineEventMarkers.MarkerGeometry] {
        TimelineEventMarkers.markerGeometries(rows: rows, events: events,
                                              dateToX: dateToX)
    }

    // MARK: One marker

    private func markerView(_ marker: TimelineEventMarkers.MarkerGeometry) -> some View {
        let color = marker.kind?.markerColor ?? Theme.accent
        let symbol = marker.kind?.symbolName ?? "questionmark.diamond"
        let correlations = correlationByEventID
        return Button {
            selection = Selection(geometry: marker, event: eventByID[marker.eventID])
        } label: {
            ZStack {
                // The diamond badge: small rotated rounded square.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(color.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(color, lineWidth: 1))
                    .frame(width: TimelineEventMarkers.markerSize,
                           height: TimelineEventMarkers.markerSize)
                    .rotationEffect(.degrees(45))
                Image(systemName: symbol)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(color)
            }
            .padding(TimelineEventMarkers.hitInset) // generous silent hit area
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(item: popoverBinding(for: marker.eventID)) { picked in
            popoverContent(for: picked)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(TimelineEventMarkers.a11yLabel(
            for: marker, metric: metric, correlation: correlations[marker.eventID])))
        .accessibilityHint(Text("Shows before-and-after measurements around this event"))
        .accessibilityAddTraits(.isButton)
        .help(Text(marker.kind?.displayName ?? (marker.rawKind.isEmpty
                ? "WiFi event" : marker.rawKind)))
    }

    /// The ONE place popover prose enters the UI: S2's sentence verbatim.
    private func popoverContent(for picked: Selection) -> some View {
        EventMarkerPopover(
            event: picked.event ?? WifiEvent(ts: picked.geometry.ts,
                                             kind: picked.geometry.rawKind,
                                             id: picked.geometry.eventID),
            metric: metric,
            correlation: correlationByEventID[picked.geometry.eventID])
    }
}

// MARK: - Detail popover

/// The event detail popover (click/tap a marker): what happened, when, and
/// the honest before/after picture from S2's correlation engine.
struct EventMarkerPopover: View {

    /// The event this popover describes.
    let event: WifiEvent
    /// Lane whose before/after deltas are shown.
    var metric: CorrelationMetric = .mbps
    /// Precomputed correlation for `event`; nil shows the honest
    /// no-measurements sentence (identity only — nothing invented).
    var correlation: CorrelatedEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: event.knownKind?.symbolName ?? "questionmark.diamond")
                    .foregroundColor(event.knownKind?.markerColor ?? Theme.accent)
                Text(title)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)

            Text(verbatim: clockTime)
                .font(.caption)
                .foregroundColor(Theme.secondaryText)

            Divider()

            Text(verbatim: deltaSentence)
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
        .frame(width: 264, alignment: .leading)
    }

    /// Human-readable kind; unknown wire kinds show their raw string.
    private var title: String {
        event.knownKind?.displayName ?? event.kind
    }

    /// Clock time, localized for READING ONLY (never feeds decisions — the
    /// determinism law governs the decision path, not presentation).
    private var clockTime: String {
        event.ts.formatted(date: .abbreviated, time: .standard)
    }

    /// S2's sentence, verbatim. This property is the ONLY author of popover
    /// prose besides S2 itself — grep target for wording-law audits. The
    /// fallback mirrors S2's no-sample sentence for the orphan-id case.
    var deltaSentence: String {
        correlation?.deltaText
            ?? "No measurements nearby — nothing within ±\(Int(TimelineCorrelation.correlationToleranceSeconds)) s of this \(title.lowercased())."
    }

    @ViewBuilder
    private func sideLabel(_ name: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundColor(Theme.secondaryText)
            Text(verbatim: value.map {
                "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)"
            } ?? "—")
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
    /// All three meet ThemeTokens' WCAG-AA contrast policy on both schemes.
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

// MARK: - Offline self-checks
//
// House convention (HistoryStoreTests / TimelineModelTests /
// TimelineCorrelationTests): Package.swift has no test target, so these
// compile into the DEBUG build as plain static checks and convert 1:1 into
// XCTestCase methods. Coverage required by mission W5-U2: geometry mapping,
// kind coloring, verbatim popover passthrough, WORDING-LAW sweep over every
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
        func row(_ offset: TimeInterval, mbps: Double? = nil,
                 eventId: String? = nil) -> TimelineRow {
            TimelineRow(ts: now.addingTimeInterval(offset),
                        mbps: mbps, lossPct: nil, jitterMs: nil, eventId: eventId)
        }
        func event(_ kind: WifiEventKind?, _ offset: TimeInterval,
                   id: String) -> WifiEvent {
            WifiEvent(ts: now.addingTimeInterval(offset),
                      kind: kind?.rawValue ?? "mystery_kind", id: id)
        }

        // Fixed window t0…t0+3600 s mapped onto x 0…600 (a plausible U1
        // axis): x = offset / 6.
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

            // Determinism under shuffled event input.
            let again = TimelineEventMarkers.markerGeometries(
                rows: rows, events: events.reversed(), dateToX: dateToX)
            check(again == markers,
                  "geometry: identical inputs (any event order) → identical layer")
        }

        // -- GEOMETRY: duplicate ids collapse; unknown kinds survive ---------
        do {
            let rows = [
                row(60, eventId: "dup"),
                row(120, eventId: "dup"),                  // same event twice
                row(180, eventId: "odd"),                  // unknown wire kind
            ]
            let events = [event(.channelChange, 60, id: "dup")]
            let markers = TimelineEventMarkers.markerGeometries(
                rows: rows, events: events, dateToX: dateToX)
            check(markers.count == 2, "geometry: duplicated eventId renders once")
            check(markers.last?.kind == nil && markers.last?.rawKind == "",
                  "geometry: id without backing event stays honest (unknown kind)")

            let labeled = track(TimelineEventMarkers.a11yLabel(
                for: markers.last!, metric: .mbps, correlation: nil))
            check(labeled.hasPrefix("WiFi event marker"),
                  "a11y: orphan id falls back to generic 'WiFi' naming (\(labeled))")
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

        // -- POPOVER FALLBACK: orphan id gets the honest no-sample line ------
        do {
            let orphan = EventMarkerPopover(
                event: WifiEvent(ts: now, kind: "mystery_kind", id: "odd"),
                metric: .mbps, correlation: nil)
            let shown = track(orphan.deltaSentence)
            check(shown.lowercased().contains("no measurements nearby"),
                  "popover: orphan id admits no measurements nearby")
            check(shown.contains("±90"),
                  "popover: fallback quotes TC2 tolerance (±90 s)")
        }

        // -- A11Y LABELS: every marker kind carries a full spoken story ------
        do {
            let correlated = TimelineCorrelation.correlate(
                rows: [
                    row(-120, mbps: 100), row(-60, mbps: 98),
                    row(0, mbps: 60, eventId: "e-roam"),
                    row(60, mbps: 58), row(120, mbps: 57),
                ],
                events: [event(.roam, 0, id: "e-roam")], metric: .mbps).first!
            let cases: [(WifiEventKind?, String)] = [
                (.roam, "Roam"),
                (.rssiDrop, "RSSI drop"),
                (.channelChange, "Channel change"),
                (nil, ""),
            ]
            for (kind, expectedName) in cases {
                let marker = TimelineEventMarkers.MarkerGeometry(
                    x: 42, ts: now.addingTimeInterval(30), kind: kind,
                    rawKind: kind?.rawValue ?? "", eventID: "x")
                let label = track(TimelineEventMarkers.a11yLabel(
                    for: marker, metric: .mbps,
                    correlation: kind == .roam ? correlated : nil))
                let expectedPrefix = expectedName.isEmpty
                    ? "WiFi event marker, "
                    : "\(expectedName) event marker, "
                check(label.hasPrefix(expectedPrefix),
                      "a11y: label leads with the human-readable kind (\(label))")
                if kind == .roam {
                    check(label.contains(correlated.deltaText),
                          "a11y: correlated markers speak the engine's verdict")
                } else {
                    check(label.hasSuffix("No measurements nearby."),
                          "a11y: uncorrelated markers admit it plainly")
                }
            }
        }

        // -- CONFIDENCE WORDING LAW: sweep every string this file shows ------
        // S2 enforces the law at the source; this sweep proves the UI layer
        // adds no causal phrasing of its own (fallbacks included).
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
