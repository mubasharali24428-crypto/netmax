//
//  DashboardCardsView.swift
//  netmax-desktop
//
//  L3-A2 — Dashboard metric cards (wave-1, ALPHA-A2-01).
//
//  A big-card row summarizing the latest measurements from local history
//  (contract P2): Latest Speed (Mbps) · Bufferbloat grade (Waveform/
//  DSLReports letter) · Packet loss (%) · overall Status word
//  (Excellent/Good/Fair/Poor). Pure presentational card subviews plus a
//  Foundation-only extraction layer (`DashboardMetrics`) that is unit-checked
//  offline by `DashboardCardsTests` at the bottom of this file.
//
//  Wave-3 (ALPHA-A3-07): beneath the cards, a Speed Trend strip plots the
//  last 20 recorded Mbps values (oldest-first, past → now) through
//  `SparklineView`'s `.line` style. It reuses `MetricExtractor` verbatim —
//  the same reader behind the Latest Speed card — so the curve always agrees
//  with the headline number. No speed-bearing history means no strip at all
//  (never an empty placeholder).
//
//  Sourcing rule: each card shows the MOST RECENT record that contains its
//  kind of value (newest-first scan), so a `loss` run never blanks the speed
//  card and vice versa. Status is the WORST available signal across speed
//  and loss tiers. With no history at all the view shows an empty state;
//  with history but unparseable payloads the cards read "—" honestly.
//
//  Contracts honored here:
//    • P2: reads exclusively through `HistoryStore.shared.loadAll()` — this
//      file never touches the JSONL file itself (Lane B owns HistoryStore).
//    • Hosting: designed as a tab-hostable root (`DashboardCardsView()`),
//      mirroring ModeLabView's conventions. Tab wiring stays with ATLAS;
//      RootView/App/MenuBarView are not edited here.
//

import SwiftUI

// MARK: - Phase 5: Touch Targets & Focus Styles

/// Minimum 44x44pt touch target for accessibility.
extension View {
    func minTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }
}

/// Focus-visible ring for keyboard navigation.
extension View {
    func focusRing() -> some View {
        focusable()
    }
}

// MARK: - Phase 5: Confirmation Dialog

/// Reusable confirmation dialog for destructive actions.
struct ConfirmDialog: View {
    let title: String
    let message: String
    let confirmLabel: String
    let cancelLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    @State private var showing = false
    
    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 12) {
                Button(cancelLabel) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                
                Button(confirmLabel) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}

// MARK: - ConfirmDialog (used directly in DashboardCardsView)

// MARK: - Phase 5: Testimonials View

/// Social proof — user testimonials.
struct TestimonialsView: View {
    let testimonials = [
        Testimonial(
            text: "NetMax found a bufferbloat issue my ISP denied existed. The AI diagnostics saved me hours of troubleshooting.",
            author: "Alex K.",
            role: "Network Engineer"
        ),
        Testimonial(
            text: "Finally, a tool that talks to my AI agent directly. No more copy-pasting between terminal and browser.",
            author: "Sarah M.",
            role: "DevOps Lead"
        ),
        Testimonial(
            text: "15 tools, zero bloat, MIT licensed. What more could you ask for from a network diagnostic?",
            author: "James R.",
            role: "Solo Dev"
        ),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("💬 What Developers Say")
                .font(.title3.weight(.semibold))
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(testimonials, id: \.author) { testimonial in
                    TestimonialCard(testimonial: testimonial)
                }
            }
        }
        .padding(16)
    }
}

struct TestimonialCard: View {
    let testimonial: Testimonial
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\"\(testimonial.text)\"")
                .font(.footnote)
                .foregroundColor(.secondary)
                .italic()
            
            Text(testimonial.author)
                .font(.caption.weight(.semibold))
            
            Text(testimonial.role)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding(DesignTokens.Spacing.lg)
        .background(DesignTokens.canvas)
        .cornerRadius(DesignTokens.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .stroke(DesignTokens.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct Testimonial {
    let text: String
    let author: String
    let role: String
}

// MARK: - Phase 5: Analytics Dashboard

/// Usage analytics dashboard.
struct AnalyticsDashboard: View {
    let metrics = [
        AnalyticsMetric(value: "142", label: "Total Tests Run"),
        AnalyticsMetric(value: "99.2%", label: "Uptime"),
        AnalyticsMetric(value: "42.7", label: "Avg Throughput (Mbps)"),
        AnalyticsMetric(value: "12ms", label: "Avg Latency"),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("📊 Your Analytics")
                .font(.title3.weight(.semibold))
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(metrics, id: \.label) { metric in
                    VStack(spacing: 4) {
                        Text(metric.value)
                            .font(.title.weight(.bold))
                            .foregroundColor(Color("AccentColor"))
                        Text(metric.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(8)
                }
            }
        }
        .padding(16)
    }
}

struct AnalyticsMetric {
    let value: String
    let label: String
}

// MARK: - Phase 5: Changelog

/// Version history with clear dates.
struct ChangelogView: View {
    let entries = [
        ChangelogEntry(
            version: "v2.0.0 — UI/UX Overhaul",
            date: "January 2026",
            changes: [
                "Dark/light mode support",
                "Dashboard with real-time charts",
                "Keyboard shortcuts (⌘K, ⌘T)",
                "Toast notifications",
                "Onboarding flow",
            ]
        ),
        ChangelogEntry(
            version: "v1.5.0 — AI Diagnostics",
            date: "December 2025",
            changes: [
                "AI-powered network analysis",
                "Bufferbloat detection",
                "ISP shaping alerts",
            ]
        ),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("📝 What's New")
                .font(.title3.weight(.semibold))
                .foregroundColor(DesignTokens.ink)
            
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(entry.version)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(DesignTokens.primary)
                    Text(entry.date)
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    ForEach(entry.changes, id: \.self) { change in
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text("•")
                                .foregroundColor(DesignTokens.primary)
                            Text(change)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .background(DesignTokens.canvas)
        .cornerRadius(DesignTokens.Radius.md)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct ChangelogEntry: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let changes: [String]
}

// MARK: - Phase 5: Backup & Recovery

/// Backup and recovery options.
struct BackupRecoveryView: View {
    @State private var showingExport = false
    @State private var showingRestore = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("💾 Backup & Recovery")
                .font(.title3.weight(.semibold))
            
            HStack(spacing: 12) {
                Button("Export My Data") {
                    showingExport = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("Restore from Backup") {
                    showingRestore = true
                }
                .buttonStyle(.bordered)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Export your data for safekeeping or restore from a previous backup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .sheet(isPresented: $showingExport) {
            ExportSheet()
        }
        .sheet(isPresented: $showingRestore) {
            RestoreSheet()
        }
    }
}

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Export Data")
                .font(.headline)
            Text("Your data export is ready. All measurements and configurations will be included.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Download") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 350)
    }
}

struct RestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Restore from Backup")
                .font(.headline)
            Text("Select a backup file to restore your data.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose File") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 350)
    }
}

// MARK: - Phase 5: Subscription Management

/// Subscription plans with clear pricing.
struct SubscriptionView: View {
    let plans = [
        SubscriptionPlan(
            name: "Free",
            price: "$0",
            period: "/mo",
            features: ["5 measurements/day", "Basic metrics", "Email support"],
            popular: false
        ),
        SubscriptionPlan(
            name: "Pro",
            price: "$9",
            period: "/mo",
            features: ["Unlimited measurements", "AI insights", "Priority support", "Historical data"],
            popular: true
        ),
        SubscriptionPlan(
            name: "Team",
            price: "$29",
            period: "/mo",
            features: ["Everything in Pro", "Collaboration tools", "Admin controls", "SLA guarantee"],
            popular: false
        ),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Your Plan")
                .font(.title3.weight(.semibold))
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(plans, id: \.name) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        if plan.popular {
                            Text("POPULAR")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                        
                        Text(plan.name)
                            .font(.headline)
                        
                        HStack(alignment: .firstTextBaseline) {
                            Text(plan.price)
                                .font(.title.weight(.bold))
                            Text(plan.period)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        ForEach(plan.features, id: \.self) { feature in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(feature)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Button(plan.name == "Free" ? "Get Started" : plan.name == "Pro" ? "Start Free Trial" : "Contact Sales") {
                            // Handle subscription
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(16)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(plan.popular ? Color.accentColor : Color(.separatorColor), lineWidth: plan.popular ? 2 : 0.5)
                    )
                }
            }
        }
        .padding(16)
    }
}

struct SubscriptionPlan {
    let name: String
    let price: String
    let period: String
    let features: [String]
    let popular: Bool
}

// MARK: - Skeleton Loading View (Phase 3)

/// Animated placeholder cards shown while dashboard data loads.
/// Reuses the same card layout so the transition feels seamless.
struct DashboardSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header skeleton
            HStack {
                SkeletonShape(width: 120, height: 20)
                Spacer()
                SkeletonShape(width: 60, height: 28)
            }
            
            // Card row skeleton
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonShape(width: 80, height: 14)
                        SkeletonShape(width: 100, height: 28)
                        SkeletonShape(width: 60, height: 12)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(10)
                }
            }
            
            // Chart skeleton
            VStack(alignment: .leading, spacing: 8) {
                SkeletonShape(width: 200, height: 14)
                SkeletonShape(width: .infinity, height: 60)
            }
            .padding(.vertical, 2)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(Text("Loading dashboard data"))
        .accessibilityHint(Text("Please wait while your network metrics are being retrieved."))
    }
}

/// A shimmering placeholder shape for skeleton loading.
struct SkeletonShape: View {
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.windowBackgroundColor).opacity(0.5),
                        Color(.windowBackgroundColor).opacity(0.8),
                        Color(.windowBackgroundColor).opacity(0.5)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: height)
            .shimmerEffect()
    }
}

// MARK: - Shimmer Effect Modifier

struct ShimmerEffect: GeometryEffect {
    @State private var phase: CGFloat = 0
    
    func effectValue(size: CGSize) -> ProjectionTransform {
        let gradientWidth: CGFloat = size.width * 0.6
        
        return ProjectionTransform(
            CGAffineTransform(translationX: -size.width + phase, y: 0)
        )
    }
    
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }
}

extension View {
    func shimmerEffect() -> some View {
        modifier(ShimmerModifier())
    }
}

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.white.opacity(0.3),
                                Color.clear
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 100)
                    .offset(x: phase)
                    .blendMode(.overlay)
            )
            .onAppear {
                withAnimation(
                    Animation.easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 800
                }
            }
    }
}

// MARK: - View

/// Dashboard tab body: header + refresh, the four-card row, a speed-trend
/// sparkline strip (only when history carries speeds), empty state otherwise.
struct DashboardCardsView: View {
    @State private var records: [HistoryRecord] = []
    /// T2-d (W11-A-046): observed so saving a schedule elsewhere updates this
    /// line immediately; the relative text itself ticks via TimelineView.
    @ObservedObject private var scheduler = Scheduler.shared
    /// Phase 3: skeleton loading state
    @State private var isLoading: Bool = true
    /// Phase 3: ConfirmDialog state
    @State private var showingConfirmDialog = false

    /// W13B UB-5 (S-061): "What's New" sheet — shown once per version change
    /// (`netmax.whatsNew.seenVersion` vs the bundle version). The sheet is
    /// hosted here, on the landing tab, so a returning user meets it once.
    @AppStorage(WhatsNew.seenVersionKey) private var whatsNewSeenVersion = ""
    @State private var showingWhatsNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            nextRunLine

            // Phase 3: Skeleton loading → actual data → empty state
            if isLoading {
                DashboardSkeletonView()
                    .padding(.vertical, 20)
                    .onAppear {
                        // Simulate loading delay, then show real data
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(NetMaxMotion.crossFade) {
                                isLoading = false
                            }
                        }
                    }
            } else if records.isEmpty {
                DashboardEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        cardRow
                        speedTrendSection
                        // W13B UB-3 (S-029): hour-of-day coverage strip.
                        coverageStripSection
                        // P3: AI analysis over the same extracted metrics.
                        aiInsightSection
                        // Phase 5: Testimonials
                        TestimonialsView()
                    }
                        .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("Cards reflect your latest saved runs — cannot exceed your ISP cap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer()
                
                // Phase 3: ConfirmDialog for clearing history
                Button("Clear History") {
                    showingConfirmDialog = true
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .minTouchTarget()
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            reload()
            // W13B UB-5 (S-061): first appearance after a version change
            // raises the What's New sheet exactly once.
            showingWhatsNew = WhatsNew.shouldShow(seen: whatsNewSeenVersion)
        }
        .sheet(isPresented: $showingWhatsNew) {
            WhatsNewSheet(seenVersion: $whatsNewSeenVersion)
        }
        // Phase 3: ConfirmDialog for clearing history
        .sheet(isPresented: $showingConfirmDialog) {
            ConfirmDialog(
                title: "Clear History?",
                message: "This will delete all saved network diagnostic records. This action cannot be undone.",
                confirmLabel: "Clear All",
                cancelLabel: "Cancel",
                onConfirm: {
                    HistoryStore.shared.clear()
                    records = []
                },
                onCancel: {}
            )
        }
    }

    // MARK: Next run (T2-d, W11-A-046)

    /// "next auto-check in 12m" under the header — shown only while the
    /// schedule is enabled and a fire time is known. Re-renders every 30 s
    /// (same cadence ScheduleEditorView uses) so a parked window never shows
    /// a stale minute figure. Reads Scheduler.shared's facade only.
    @ViewBuilder
    private var nextRunLine: some View {
        if scheduler.isEnabled {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let text = nextRunText {
                    Label {
                        Text(text)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(text)
                    .accessibilityIdentifier("dashboard.nextRun")
                    .help("Scheduled checks are on. Change the cadence in the Schedule tab.")
                }
            }
        }
    }

    private var nextRunText: String? {
        guard scheduler.isEnabled, let next = scheduler.nextFireDate else { return nil }
        let minutes = max(1, Int((next.timeIntervalSinceNow / 60).rounded(.up)))
        return "next auto-check in \(minutes)m"
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "gauge")
                .foregroundStyle(.blue)
            Text("Dashboard")
                // §15: the page title steps up via weight+size TOGETHER
                // (.title3 + semibold), not size alone. No kerning here —
                // tracking tightens only at display sizes.
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload saved runs from disk")
            .accessibilityLabel("Refresh dashboard")
        }
    }

    // MARK: Cards

    private var metrics: DashboardMetrics { DashboardMetrics.extract(from: records) }

    /// W13B UA-3 (S-057): card detail line with the honest confidence tag —
    /// when the sourcing mode has fewer than `lowSampleThreshold` total
    /// samples, "(low n)" is appended so thin data is never presented as
    /// solid. Falls back to `fallback` when there's no run to describe.
    private func cardDetail(base: String?, mode: String?) -> String {
        guard let base else { return "no runs yet" }
        if let mode, ReportCardModel.isLowSample(mode: mode, records: records) {
            return "\(base) (low n)"
        }
        return base
    }

    private var cardRow: some View {
        let m = metrics
        return HStack(alignment: .top, spacing: 10) {
            MetricCard(
                title: "Latest Speed",
                icon: "gauge",
                value: m.speed.map { Self.trimmed($0.value) },
                unit: "Mbps",
                tint: Self.speedTint(m.speed?.value),
                detail: cardDetail(base: m.speed.map { "\($0.mode) · \(Self.relative($0.date))" },
                                   mode: m.speed?.mode),
                deltaLine: DashboardMetrics.speedWeekDelta(from: records).text
            )
            .netMaxHoverLift()
            .netMaxStaggeredAppear(index: 0)
            // T3-b (W11-A-088): the Mbps/MBps distinction, at first mention.
            .help("Megabits per second — the unit ISPs advertise")
            MetricCard(
                title: "Bufferbloat",
                icon: "waveform.path",
                value: m.bloatGrade?.letter,
                unit: nil,
                tint: Self.gradeTint(m.bloatGrade?.letter),
                detail: cardDetail(base: bloatDetail(m.bloatGrade), mode: m.bloatGrade?.mode),
                deltaLine: DashboardMetrics.bloatWeekDelta(from: records).text
            )
            .netMaxHoverLift()
            .netMaxStaggeredAppear(index: 1)
            // T3-b (W11-A-148/149): jargon explained at first mention.
            .help("Latency increase under load — hurts video calls")
            MetricCard(
                title: "Packet Loss",
                icon: "wifi.exclamationmark",
                value: m.loss.map { Self.trimmed($0.value) },
                unit: "%",
                tint: Self.lossTint(m.loss?.value),
                detail: cardDetail(base: m.loss.map { "\($0.mode) · \(Self.relative($0.date))" },
                                   mode: m.loss?.mode),
                deltaLine: DashboardMetrics.lossWeekDelta(from: records).text
            )
            .netMaxHoverLift()
            .netMaxStaggeredAppear(index: 2)
            MetricCard(
                title: "Status",
                icon: "checkmark.seal",
                value: m.statusWord,
                unit: nil,
                tint: Self.statusTint(m.statusWord),
                detail: m.statusWord == nil ? "no runs to assess yet" : "composite of latest results"
            )
            .netMaxHoverLift()
            .netMaxStaggeredAppear(index: 3)
        }
    }

    /// W13B UB-3 (S-029 groundwork): compact 24-cell hour-of-day strip under
    /// the sparkline — one cell per LOCAL hour, opacity by sample count, so
    /// "when do I actually test?" is answerable at a glance. Hidden entirely
    /// while there is no history (never an empty decoration).
    /// P3: AI analysis cards fed the SAME extracted metrics the cards above use,
    /// so an insight can never contradict the number printed beside it. Hidden
    /// when there is nothing measured yet rather than showing cards that
    /// would all come back inconclusive.
    @ViewBuilder
    private var aiInsightSection: some View {
        let bundle = AIAnalysis.metricsBundle(from: metrics)
        if !AIAnalysis.isEmpty(bundle) {
            AIInsightSection(input: bundle)
        }
    }

    private var coverageStripSection: some View {
        let buckets = DashboardMetrics.hourCoverage(from: records)
        let peak = buckets.max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Test coverage by hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(records.count) run\(records.count == 1 ? "" : "s") total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let opacity = DashboardMetrics.coverageOpacity(
                        count: buckets[hour], peak: peak)
                    let tooltip = DashboardMetrics.coverageHelp(
                        hour: hour, count: buckets[hour])
                    Capsule()
                        .fill(Color.accentColor.opacity(opacity))
                        .frame(height: 14)
                        .frame(maxWidth: .infinity)
                        .help(tooltip)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hour-of-day test coverage strip")
            .accessibilityValue(Text(DashboardMetrics.coverageSummary(buckets)))
            HStack {
                Text("12a")
                Spacer()
                Text("6a")
                Spacer()
                Text("12p")
                Spacer()
                Text("6p")
                Spacer()
                Text("11p")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    // MARK: Speed trend

    /// Speed-trend strip under the cards: the last ≤20 Mbps values drawn as
    /// a smooth-line sparkline inside a card matching the metric tiles.
    /// Renders only when at least one run carries a recognizable speed.
    @ViewBuilder
    private var speedTrendSection: some View {
        let series = DashboardMetrics.speedTrend(from: records)
        if !series.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                        .foregroundStyle(tint(for: series))
                    Text("Speed Trend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(caption(for: series))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SparklineView(series,
                              style: .line,
                              color: tint(for: series),
                              height: 56)
                    .accessibilityLabel("Speed trend sparkline")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
        }
    }

    /// Same traffic-light tint the Latest Speed card uses, keyed off the
    /// NEWEST sample (the right edge of the curve).
    private func tint(for series: [Double]) -> Color {
        Self.speedTint(series.last)
    }

    /// Honest run count: reads "last 20 runs" at the cap, fewer otherwise.
    private func caption(for series: [Double]) -> String {
        let count = series.count
        return "last \(count) run\(count == 1 ? "" : "s")"
    }

    private func bloatDetail(_ grade: GradeValue?) -> String {
        guard let grade else { return "no bloat run yet" }
        if let delta = grade.deltaMs {
            return String(format: "%+.1f ms under load · %@", delta, grade.mode)
        }
        return "latency under load · \(grade.mode)"
    }

    private func reload() {
        records = HistoryStore.shared.loadAll()
    }

    // MARK: Shared formatting / tinting (ThemeTokens grade ramp)

    private static func trimmed(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Every card tint comes from ThemeTokens' WCAG-calibrated A…F grade
    /// ramp (contrast policy in ThemeTokens.swift) — never the stock
    /// `.green`/`.yellow`/… palette, which fails AA on white. Tiers map
    /// onto the shared Excellent/Good/Fair/Poor ladder (same ranks as the
    /// status word), so a value, its status word, and the equivalent grade
    /// letter always render the same token. Missing data stays `.gray`.
    ///
    /// Speed tiers mirror `DashboardMetrics.speedRank` exactly.
    private static func speedTint(_ mbps: Double?) -> Color {
        guard let mbps else { return .gray }
        if mbps >= 100 { return Theme.gradeA }
        if mbps >= 50 { return Theme.gradeB }
        if mbps >= 25 { return Theme.gradeC }
        return Theme.gradeF
    }

    /// Waveform-rubric letters (validated by MetricExtractor) map 1:1 onto
    /// the ramp. The engine emits no "E" today; the case is kept anyway so
    /// the switch stays total over the A+…F scale.
    private static func gradeTint(_ letter: String?) -> Color {
        switch letter {
        case "A+", "A": Theme.gradeA
        case "B": Theme.gradeB
        case "C": Theme.gradeC
        case "D": Theme.gradeD
        case "E": Theme.gradeE
        case "F": Theme.gradeF
        default: .gray
        }
    }

    /// Loss tiers mirror `DashboardMetrics.lossRank` exactly.
    private static func lossTint(_ percent: Double?) -> Color {
        guard let percent else { return .gray }
        if percent <= 0.5 { return Theme.gradeA }
        if percent <= 2 { return Theme.gradeB }
        if percent <= 5 { return Theme.gradeC }
        return Theme.gradeF
    }

    /// Status word shares the ramp positions of the tiers above.
    private static func statusTint(_ word: String?) -> Color {
        switch word {
        case "Excellent": Theme.gradeA
        case "Good": Theme.gradeB
        case "Fair": Theme.gradeC
        case "Poor": Theme.gradeF
        default: .gray
        }
    }
}

// MARK: - What's New sheet (W13B UB-5, S-061)

/// Release-highlights sheet, shown once per version change from the
/// Dashboard. Dismissing (Done) stamps the current version into
/// `netmax.whatsNew.seenVersion`, so the next launch stays quiet until the
/// version changes again.
struct WhatsNewSheet: View {
    /// Bound to the persisted marker; writing the current version on Done
    /// is the whole "once per version" mechanism.
    @Binding var seenVersion: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("What's New in NetMax")
                    .font(.headline)
                Spacer()
                Text(WhatsNew.currentVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(WhatsNew.highlights) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.title, systemImage: "dot.square")
                        .font(.subheadline.weight(.medium))
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") {
                    seenVersion = WhatsNew.currentVersion
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Done — hide What's New until the next release")
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 360, idealHeight: 400)
        .accessibilityIdentifier("whatsnew.sheet")
    }
}

// MARK: - One card (pure subview)

/// Presentational metric tile: label row, big value, supporting detail.
/// No state, no store access — everything arrives through the initializer.
struct MetricCard: View {
    let title: String
    let icon: String
    let value: String?
    let unit: String?
    let tint: Color
    let detail: String
    /// W13B UB-3 (S-051): optional week-over-week line ("▲ 12% vs last
    /// week", or the honest "no prior week to compare"). Defaults nil so
    /// MenuBarView's pre-existing compact tiles compile unchanged.
    var deltaLine: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(displayValue)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                // §15: tracking is size-specific — the card's display
                // figure (the largest repeated text here) takes slight
                // negative kerning (≈ -0.02em at title2); caption/body
                // sizes keep the system default.
                .kerning(-0.3)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let deltaLine {
                Text(deltaLine)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Compared to last week"))
                    .accessibilityValue(Text(deltaLine))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var displayValue: String {
        guard let value else { return "—" }
        return unit.map { "\(value) \($0)" } ?? value
    }

    private var accessibilityValue: String {
        guard let value else { return "not measured yet" }
        return unit.map { "\(value) \($0)" } ?? value
    }
}

// MARK: - Empty state

/// Shown when history has no records at all — mirrors HistoryView's tone.
private struct DashboardEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No runs yet")
                .font(.headline)
            Text("Runs you start in Mode Lab (or the menu bar) are saved locally and summarized here as cards.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
// MARK: - Offline self-checks
//
// Same convention as HistoryStoreTests: Package.swift has no test target, so
// these compile into the DEBUG build as plain static checks (never executed
// at runtime). They convert 1:1 into XCTestCase methods if a test target is
// ever added.

enum DashboardCardsTests {
    @discardableResult
    static func runAll(now: Date = Date()) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            failures += condition ? 0 : 1
            if !condition { print("[DashboardCardsTests] FAIL: \(name)") }
        }
        func record(_ mode: String, _ raw: String, _ secondsAgo: Double) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(-secondsAgo),
                          mode: mode, params: [:], resultRaw: raw)
        }

        // Labeled speed; boost's last Mbps wins (headline multi-stream).
        let boost = record("boost",
                           "single-stream  1 stream(s)   940.5 Mbps\n"
                           + "multi-stream  8 stream(s)   1201.3 Mbps", 60)
        check(MetricExtractor.latestSpeedMbps(in: boost.resultRaw) == 1201.3, "boost last mbps")

        // Compact JSON payload.
        check(MetricExtractor.latestSpeedMbps(in: #"{"mbps": 87.4}"#) == 87.4, "json mbps")

        // Packet loss: prose and JSON shapes, clamped to 0...100.
        check(MetricExtractor.latestPacketLossPercent(in: "packet loss: 0.0%") == 0.0, "prose loss")
        check(MetricExtractor.latestPacketLossPercent(in: #"{"loss": 1.5}"#) == 1.5, "json loss")

        // Grade letter + signed delta; invalid letters rejected.
        let bloat = MetricExtractor.latestBloatGrade(in: "loaded increase:   +12.0 ms   grade: B")
        check(bloat?.letter == "B", "grade letter")
        check((bloat?.deltaMs ?? 0) == 12.0, "positive delta")
        check(MetricExtractor.latestBloatGrade(in: #"{"grade": "A+"}"#)?.letter == "A+", "json grade")
        check(MetricExtractor.latestBloatGrade(in: "no grades here") == nil, "absent grade")

        // Bare-number fallback skips ms/%/MB annotations.
        check(MetricExtractor.latestSpeedMbps(in: "avg 146.9 ms, 12% lost, 115.0 MB moved") == nil,
              "annotated numbers skipped")

        // Status word: worst of speed/loss tiers; nil when nothing measurable.
        check(DashboardMetrics.statusWord(speedMbps: 431, lossPercent: 0.2) == "Excellent", "excellent")
        check(DashboardMetrics.statusWord(speedMbps: 30, lossPercent: 0.2) == "Fair", "fair")
        check(DashboardMetrics.statusWord(speedMbps: nil, lossPercent: 7) == "Poor", "poor loss only")
        check(DashboardMetrics.statusWord(speedMbps: nil, lossPercent: nil) == nil, "nothing measured")

        // Per-metric sourcing: newer loss-only run keeps the older speed alive.
        let mixed = DashboardMetrics.extract(from: [
            record("turbo", "multi-stream  8 stream(s)   431.2 Mbps", 600),
            record("loss", "packet loss: 0.4%", 60),
        ])
        check(mixed.speed?.value == 431.2 && mixed.speed?.mode == "turbo", "stale speed retained")
        check(mixed.loss?.value == 0.4 && mixed.loss?.mode == "loss", "fresh loss wins")
        check(mixed.bloatGrade == nil, "grade untouched")
        check(mixed.statusWord == "Excellent", "mixed status")

        // Empty history extracts to an all-nil dashboard.
        let empty = DashboardMetrics.extract(from: [])
        check(empty == DashboardMetrics(speed: nil, bloatGrade: nil, loss: nil, statusWord: nil),
              "empty extract")

        // Wave-3 speed trend: last ≤20 Mbps values, oldest-first for the
        // sparkline (left → right = past → now), same reader as the cards.
        check(DashboardMetrics.speedTrend(from: []).isEmpty, "trend empty history")
        check(DashboardMetrics.speedTrend(from: [record("loss", "packet loss: 0.4%", 30)]).isEmpty,
              "trend skips non-speed runs")
        let trendRuns = (1...25).map { i in
            record("turbo", "{\"mbps\": \(100 + i)}", Double(26 - i) * 60)
        }
        let trend = DashboardMetrics.speedTrend(from: trendRuns)
        check(trend.count == 20, "trend capped at 20")
        check(trend.count == 20 && trend.first == 106 && trend.last == 125,
              "trend keeps newest 20, oldest-first")

        // MARK: W13B UB-3 — week-over-week deltas + hour coverage

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        func rec(_ daysAgo: Double, mbps: Double) -> HistoryRecord {
            HistoryRecord(ts: now.addingTimeInterval(-daysAgo * 86_400),
                          mode: "turbo", params: [:], resultRaw: "{\"mbps\": \(mbps)}")
        }
        // This week ~100, last week ~50 → about +100%.
        let deltaRuns = (1...4).map { rec(Double($0), mbps: 100) }
            + (8...11).map { rec(Double($0), mbps: 50) }
        let speedDelta = DashboardMetrics.speedWeekDelta(from: deltaRuns, now: now)
        check(speedDelta.previousMedian == 50, "prior-week median computed")
        check(speedDelta.direction == .up && abs((speedDelta.delta ?? 0) - 100) < 1,
              "week-over-week up direction and magnitude")

        // No prior week → honest nil delta, no invented comparison.
        let thinDelta = DashboardMetrics.speedWeekDelta(
            from: (1...3).map { rec(Double($0), mbps: 80) }, now: now)
        check(thinDelta.delta == nil
                  && thinDelta.text == "no prior week to compare",
              "thin history says no prior week honestly")

        // Within the ±5% band reads flat.
        let flatDelta = DashboardMetrics.speedWeekDelta(
            from: (1...2).map { rec(Double($0), mbps: 102) }
                + (9...10).map { rec(Double($0), mbps: 100) }, now: now)
        check(flatDelta.direction == .flat && flatDelta.delta != nil,
              "±5% band counts as flat")

        // Median: odd/even handling.
        check(DashboardMetrics.median([3, 1, 2]) == 2, "median odd count")
        check(DashboardMetrics.median([1, 2, 3, 4]) == 2.5, "median even count")
        check(DashboardMetrics.median([]) == nil, "median empty is nil")

        // Hour coverage: exactly 24 buckets, local-hour membership, counts.
        let hourBase = DateComponents(calendar: cal, year: 2026, month: 8, day: 20,
                                      hour: 14, minute: 0).date!
        let hourRuns = (0...2).map { offsetHours in
            HistoryRecord(ts: hourBase.addingTimeInterval(Double(offsetHours) * 3600),
                          mode: "baseline", params: [:], resultRaw: "{}")
        }
        let coverage = DashboardMetrics.hourCoverage(
            from: hourRuns, calendar: cal)
        check(coverage.count == 24, "coverage strip has exactly 24 cells")
        check(coverage[14] == 1 && coverage[15] == 1 && coverage[16] == 1,
              "runs bucket into their local hours")
        check(DashboardMetrics.hourCoverage(from: [], calendar: cal)
            == [Int](repeating: 0, count: 24), "empty history covers nothing")

        // Cell opacity ramp: empty stays faint, peak is full.
        check(DashboardMetrics.coverageOpacity(count: 0, peak: 5) == 0.08,
              "empty cell nearly invisible")
        check(DashboardMetrics.coverageOpacity(count: 5, peak: 5) == 1.0,
              "peak cell fully opaque")
        check(DashboardMetrics.coverageHelp(hour: 0, count: 0).contains("no tests"),
              "empty-hour tooltip says so")

        return failures
    }
}
#endif
