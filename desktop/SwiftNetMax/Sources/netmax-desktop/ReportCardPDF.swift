//
//  ReportCardPDF.swift
//  netmax-desktop
//
//  ALPHA-A1-07 — Report-card PDF renderer (roadmap N7, feeds N5).
//
//  Renders a one-page network "report card" (title, date range, big overall
//  grade letter, sectioned metric rows with 0…1 score bars, honest-limits
//  footer) into PDF bytes via a raw Core Graphics PDF context. Text is laid
//  out with bare CoreText lines — no CTFramesetter, no attributed-string
//  layout gymnastics.
//
//  Input model: this file deliberately defines its OWN plain-data input
//  (`Content`/`Section`/`Row`) instead of importing the canonical
//  report-card model, so it compiles stand-alone regardless of lane order.
//  When wiring UI, map from the canonical `ReportCard` struct at the call
//  site (memberwise init below makes that a three-line shim).
//
//  Pure Foundation + CoreGraphics + CoreText — no AppKit, no SwiftUI — so
//  the renderer is unit-testable headlessly.
//

import Foundation
import CoreGraphics
import CoreText

// MARK: - Renderer

enum ReportCardPDF {

    // MARK: Page geometry (US Letter)

    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 54
    private static let contentWidth: CGFloat = pageRect.width - 2 * margin // 504
    /// Vertical space reserved at the page bottom for the honest-limits footer.
    private static let footerReserve: CGFloat = 56
    /// Where content starts on a fresh page (top margin).
    private static let contentTop: CGFloat = pageRect.height - 66
    /// Score-bar geometry: bar occupies the right edge of the content area.
    private static let barWidth: CGFloat = 170
    private static let barHeight: CGFloat = 8
    private static let columnGap: CGFloat = 12
    /// Right edge where the value column ends (bars live to its right).
    private static var valueRightX: CGFloat {
        margin + contentWidth - barWidth - columnGap
    }
    private static var barX: CGFloat { valueRightX + columnGap }

    // MARK: Palette (fixed sRGB — PDFs must not follow the OS theme)

    private static let inkColor = CGColor(gray: 0.10, alpha: 1)
    private static let secondaryColor = CGColor(gray: 0.42, alpha: 1)
    private static let hairlineColor = CGColor(gray: 0.78, alpha: 1)
    private static let barTrackColor = CGColor(gray: 0.88, alpha: 1)
    private static let barFillColor = CGColor(
        srgbRed: 0.16, green: 0.47, blue: 0.94, alpha: 1)
    private static let paperColor = CGColor(gray: 1, alpha: 1)

    // MARK: Input model

    /// Everything the renderer draws. All fields are preformatted display
    /// strings — grading/mapping logic belongs to the caller.
    struct Content {
        var title: String
        /// Human-readable period the card summarizes, e.g. "Aug 16 – Aug 23, 2026".
        var dateRangeText: String
        /// Big letter shown front-and-center, e.g. "A-", "B+".
        var overallGrade: String
        var sections: [Section]
        /// Single-line honest-limits disclaimer drawn at the page foot.
        var limitsFooter: String

        struct Section {
            var heading: String
            var rows: [Row]
        }

        struct Row {
            /// Left-column metric label, e.g. "Download".
            var metric: String
            /// Preformatted value cell, e.g. "812 Mbps".
            var value: String
            /// Normalized 0…1 quality score driving the bar fill; `nil`
            /// hides the bar (metric measured but not scored).
            var score: Double?
        }

        init(
            title: String,
            dateRangeText: String,
            overallGrade: String,
            sections: [Section],
            limitsFooter: String =
                "Honest limits: results reflect this device and link at the "
                    + "times measured — not an ISP's maximum capability."
        ) {
            self.title = title
            self.dateRangeText = dateRangeText
            self.overallGrade = overallGrade
            self.sections = sections
            self.limitsFooter = limitsFooter
        }
    }

    // MARK: Entry points

    /// Render the card into PDF bytes.
    static func render(_ content: Content) -> Data {
        let mutable = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = makeContext(consumer: consumer, title: content.title)
        else { return Data() }

        var page = Page(ctx: ctx, footerText: content.limitsFooter)
        page.begin()

        drawHeader(content, on: &page)
        drawOverallGrade(content.overallGrade, below: page.y, on: &page)
        for section in content.sections {
            drawSection(section, on: &page)
        }

        ctx.endPDFPage()
        ctx.closePDF()
        return mutable as Data
    }

    /// Render and write atomically to `url`. Returns the destination URL.
    @discardableResult
    static func write(_ content: Content, to url: URL) throws -> URL {
        let data = render(content)
        guard !data.isEmpty else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSLocalizedDescriptionKey:
                    "Report card PDF could not be generated."]
            )
        }
        try data.write(to: url, options: [.atomic])
        return url
    }

    // MARK: Context

    private static func makeContext(
        consumer: CGDataConsumer, title: String
    ) -> CGContext? {
        var mediaBox = pageRect
        let aux: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "SwiftNetMax",
        ]
        // Swift-overlay form: the auxiliary-info dictionary is the unlabeled
        // trailing argument (label drift across SDKs; verified against this
        // toolchain's error notes).
        return CGContext(consumer: consumer, mediaBox: &mediaBox, aux as CFDictionary)
    }

    // MARK: Layout blocks

    private static func drawHeader(_ content: Content, on page: inout Page) {
        let titleLine = fitted(
            content.title, font: Fonts.title, maxWidth: contentWidth)
        page.draw(line: titleLine, at: CGPoint(x: margin, y: page.y))
        page.y -= 20

        let rangeLine = fitted(
            content.dateRangeText, font: Fonts.caption, maxWidth: contentWidth)
        page.draw(line: rangeLine, at: CGPoint(x: margin, y: page.y))
        page.y -= 14

        page.strokeRule(
            from: CGPoint(x: margin, y: page.y),
            to: CGPoint(x: margin + contentWidth, y: page.y))
        page.y -= 26
    }

    private static func drawOverallGrade(
        _ grade: String, below top: CGFloat, on page: inout Page
    ) {
        let blockHeight: CGFloat = 168
        page.ensureSpace(blockHeight)

        let label = fitted(
            "OVERALL GRADE", font: Fonts.label,
            maxWidth: contentWidth, aligning: .center)
        let labelWidth = width(of: label)
        page.draw(
            line: label,
            at: CGPoint(x: (pageRect.width - labelWidth) / 2, y: page.y))
        page.y -= 128

        let letter = fitted(
            grade, font: Fonts.gradeLetter,
            maxWidth: contentWidth, aligning: .center)
        let letterWidth = width(of: letter)
        page.draw(
            line: letter,
            at: CGPoint(x: (pageRect.width - letterWidth) / 2, y: page.y))
        page.y -= 34
    }

    private static func drawSection(_ section: Content.Section, on page: inout Page) {
        guard !section.rows.isEmpty || !section.heading.isEmpty else { return }

        let heading = fitted(section.heading, font: Fonts.sectionHeading, maxWidth: contentWidth)
        page.ensureSpace(30 + CGFloat(section.rows.count) * rowHeight)
        page.draw(line: heading, at: CGPoint(x: margin, y: page.y))
        page.y -= 10
        page.strokeRule(
            from: CGPoint(x: margin, y: page.y),
            to: CGPoint(x: margin + contentWidth, y: page.y))
        page.y -= rowHeight

        for row in section.rows {
            page.ensureSpace(rowHeight)
            drawRow(row, on: &page)
            page.y -= rowHeight
        }
        page.y -= 8 // breathing room between sections
    }

    private static let rowHeight: CGFloat = 21

    private static func drawRow(_ row: Content.Row, on page: inout Page) {
        let baseline = page.y

        // Metric label (left column).
        let metricWidth = valueRightX - margin - columnGap * 2
        let metric = fitted(row.metric, font: Fonts.body, maxWidth: metricWidth)
        page.draw(line: metric, at: CGPoint(x: margin, y: baseline))

        // Value cell (right-aligned against the bar column).
        if !row.value.isEmpty {
            let maxValue = barWidth + columnGap * 2
            let value = fitted(row.value, font: Fonts.body, maxWidth: maxValue)
            let x = valueRightX - width(of: value)
            page.draw(line: value, at: CGPoint(x: x, y: baseline))
        }

        // Score bar (right column). Nil/unclamped-out scores leave just track.
        if let score = row.score.map({ min(max($0, 0), 1) }) {
            let track = CGRect(
                x: barX, y: baseline - 2, width: barWidth, height: barHeight)
            page.roundedFill(track, color: barTrackColor)
            let fill = CGRect(
                x: barX, y: baseline - 2,
                width: barWidth * CGFloat(score), height: barHeight)
            if fill.width >= 1 {
                page.roundedFill(fill, color: barFillColor)
            }
        }
    }

    // MARK: Canonical-model bridge

    /// Map lane A1-06's canonical `ReportCard` onto this renderer's input.
    /// Kept as a single function so upstream model drift is contained here:
    /// scores arrive as 0–100 points and are normalized to the bar's 0–1;
    /// `.incomplete` renders as an em-dash rather than a fake letter; each
    /// section's one-line summary becomes the row's value cell verbatim
    /// (it cites only measured numbers — house style).
    static func content(
        from card: ReportCard,
        title: String,
        dateRangeText: String,
        limitsFooter: String =
            "Honest limits: results reflect this device and link at the "
                + "times measured — not an ISP's maximum capability."
    ) -> Content {
        let gradeDisplay = card.overall == .incomplete ? "—" : card.overall.rawValue
        return Content(
            title: title,
            dateRangeText: dateRangeText,
            overallGrade: gradeDisplay,
            sections: card.sections.map { section in
                .init(
                    heading: section.metric.rawValue,
                    rows: [
                        .init(
                            metric: section.grade.rawValue,
                            value: section.summary,
                            score: section.score.map { min(max($0 / 100, 0), 1) }
                        )
                    ]
                )
            },
            limitsFooter: limitsFooter
        )
    }

    // MARK: CoreText plumbing

    private struct Fonts {
        static let title = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
        static let caption = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        static let label = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        static let gradeLetter = CTFontCreateWithName("Helvetica-Bold" as CFString, 120, nil)
        static let sectionHeading = CTFontCreateWithName("Helvetica-Bold" as CFString, 14, nil)
        static let body = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        static let footer = CTFontCreateWithName("Helvetica-Oblique" as CFString, 9, nil)
    }

    /// Horizontal alignment hint applied when fitting text.
    private enum Fitting {
        case leading
        case center
    }

    /// Build a CoreText line, trimming the tail with an ellipsis until it
    /// fits `maxWidth`. Center alignment trims symmetrically instead.
    private static func fitted(
        _ text: String, font: CTFont,
        maxWidth: CGFloat, aligning: Fitting = .leading
    ) -> CTLine {
        var text = text
        var line = makeLine(text, font: font)

        switch aligning {
        case .center where width(of: line) <= maxWidth:
            return line
        case .center:
            // Shave characters alternately off both ends, then ellipsize.
            while !text.isEmpty && width(of: makeLine("…" + text + "…", font: font)) > maxWidth {
                if text.count <= 2 { text.removeAll(); break }
                text.removeFirst()
                text.removeLast()
            }
            line = makeLine(text.isEmpty ? "" : "…" + text + "…", font: font)
            return line
        case .leading:
            while width(of: line) > maxWidth && !text.isEmpty {
                text.removeLast()
                line = makeLine(text + (text.isEmpty ? "" : "…"), font: font)
            }
            return line
        }
    }

    private static func makeLine(_ text: String, font: CTFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): inkColor,
        ]
        let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
        return CTLineCreateWithAttributedString(attributed!)
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: Page cursor

    /// Per-document drawing state: wraps the CGContext, tracks the vertical
    /// cursor, and paginates when content runs past the footer reserve.
    private struct Page {
        let ctx: CGContext
        let footerText: String
        var y: CGFloat

        init(ctx: CGContext, footerText: String) {
            self.ctx = ctx
            self.footerText = footerText
            self.y = Self.contentStartY
        }

        static var contentStartY: CGFloat { contentTop }

        mutating func begin() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            // Explicit white ground: keeps the card readable in dark-mode viewers.
            ctx.setFillColor(ReportCardPDF.paperColor)
            ctx.fill(pageRect)
            drawFooter()
            y = Self.contentStartY
        }

        /// Flip to a fresh page when `needed` points would cross the footer.
        mutating func ensureSpace(_ needed: CGFloat) {
            if y - needed < ReportCardPDF.footerReserve {
                ctx.endPDFPage()
                begin()
            }
        }

        mutating func draw(line: CTLine, at point: CGPoint) {
            // Unflipped PDF context: place the line by translating the text
            // matrix to the baseline origin, then restore identity.
            ctx.textMatrix = CGAffineTransform(
                translationX: point.x, y: point.y)
            CTLineDraw(line, ctx)
            ctx.textMatrix = .identity
        }

        mutating func strokeRule(from: CGPoint, to: CGPoint) {
            ctx.setStrokeColor(ReportCardPDF.hairlineColor)
            ctx.setLineWidth(0.75)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
        }

        mutating func roundedFill(_ rect: CGRect, color: CGColor) {
            ctx.setFillColor(color)
            ctx.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                transform: nil))
            ctx.fillPath()
        }

        /// Honest-limits line pinned above the physical page bottom.
        ///
        /// Drawn with its own secondary-color line (the shared `makeLine`
        /// bakes ink color in), tail-truncated to the content width.
        mutating func drawFooter() {
            guard !footerText.isEmpty else { return }
            let baseline: CGFloat = 30
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ReportCardPDF.Fonts.footer,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ReportCardPDF.secondaryColor,
            ]
            var footerText = self.footerText
            var footerLine = CTLineCreateWithAttributedString(CFAttributedStringCreate(
                nil, footerText as CFString, attributes as CFDictionary)!)
            while ReportCardPDF.width(of: footerLine) > ReportCardPDF.contentWidth
                    && !footerText.isEmpty {
                footerText.removeLast()
                let suffix = footerText + "…"
                if let a = CFAttributedStringCreate(
                    nil, suffix as CFString, attributes as CFDictionary) {
                    footerLine = CTLineCreateWithAttributedString(a)
                }
            }
            ctx.textMatrix = CGAffineTransform(
                translationX: ReportCardPDF.margin, y: baseline)
            CTLineDraw(footerLine, ctx)
            ctx.textMatrix = .identity
            // Hairline above the footer to separate it from the body.
            strokeRule(
                from: CGPoint(x: ReportCardPDF.margin, y: baseline + 14),
                to: CGPoint(x: ReportCardPDF.margin + ReportCardPDF.contentWidth, y: baseline + 14))
        }
    }
}
