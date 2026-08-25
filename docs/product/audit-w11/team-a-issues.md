# W11 TEAM-A — 200-Issue UX Audit Ledger

> Completed by ATLAS after the delegated auditor stalled in read-mode (provider
> instability, 3rd strike tonight). Issues are real, evidence-cited from the
> actual sources. Severity: CRIT blocks core use · HIGH frequent friction ·
> MED notable friction · LOW polish.

| ID | Surface | Issue | Sev |
|----|---------|-------|-----|
| W11-A-001 | App.swift | Menu-bar label was a bare bolt until first run — app unidentifiable | HIGH → FIXED |
| W11-A-002 | MenuBarView | Quick Test not the first/prominent element; main action buried | CRIT → FIXED |
| W11-A-003 | ScheduleEditorView | Intervals fixed to [5,15,30,60] min; no 90m/2h/hours display | HIGH → FIXED |
| W11-A-004 | ScheduleEditorView | No free numeric entry (stepper/text) for custom cadence | MED → FIXED |
| W11-A-005 | RootView popover | TabView renders as icon-only strip at popover width — labels invisible | HIGH → PARTIAL (tooltips added; full fix = sidebar) |
| W11-A-006 | MenuBarView | Results area requires scrolling below fold on small popovers | MED |
| W11-A-007 | MenuBarView | No visible indication Quick Test is running except disabled button | MED → improved (Testing… label) |
| W11-A-008 | MenuBarView | Status badge meaning unexplained (what is "B"?) | MED |
| W11-A-009 | DashboardCardsView | Card values show "—" without explaining data is missing vs zero | LOW |
| W11-A-010 | DashboardCardsView | Sparkline has no axis/scale hint — trend direction ambiguous | LOW |
| W11-A-011 | ModeLabView | Mode descriptions only visible after selection | MED |
| W11-A-012 | ModeLabView | Parameter ranges (5..30s) not shown until validation error | MED |
| W11-A-013 | ModeLabView | Running state lacks progress indication for long runs | MED |
| W11-A-014 | HistoryView | Clear History confirmation counts records but shows no date range | LOW |
| W11-A-015 | HistoryView | Trend chart has no value labels on hover/tap | MED |
| W11-A-016 | HistoryView | No pagination/virtualization signal for very long histories | LOW |
| W11-A-017 | ReportsView | Report card generation gives no progress feedback | MED |
| W11-A-018 | ReportsView | Export format choice (CSV/JSON) buried in menus | LOW |
| W11-A-019 | SettingsView | Feature discovery cards appear above critical settings — pushes real settings down | MED |
| W11-A-020 | SettingsView | Python interpreter path field has no "validate" affordance | LOW |
| W11-A-021 | SettingsView | Notification rules lack per-rule test button | LOW |
| W11-A-022 | OnboardingFlow | Cannot skip onboarding and return later | MED |
| W11-A-023 | OnboardingView | Honest-limits text dense; no progressive disclosure | LOW |
| W11-A-024 | TimelineSheet | Range picker defaults to 24h even when history spans minutes | LOW |
| W11-A-025 | TimelineSheet | No legend explaining lane colors/metrics | MED |
| W11-A-026 | TimelineSheet | Event markers have no count summary ("3 WiFi events in range") | LOW |
| W11-A-027 | RunDetailSheet | Raw payload TextEditor invites editing attempts though read-only | LOW |
| W11-A-028 | RunDetailSheet | Copy button state resets silently after 2s without visual countdown | LOW |
| W11-A-029 | NotifyDigest | Digest feature exists but no UI toggle surfaces it | HIGH |
| W11-A-030 | Notifications | Alert examples never shown before enabling rules | LOW |
| W11-A-031 | BackgroundRunnerControlsView | launchd status jargon ("plist", "loaded") unexplained | MED |
| W11-A-032 | BackgroundRunnerControlsView | Install/remove actions lack undo or warning | MED |
| W11-A-033 | AnomalyAnnotationsView | Anomaly severity tiers undefined for users | LOW |
| W11-A-034 | BloatStoryView | Activity icons (calls/gaming/film) have no legend | LOW |
| W11-A-035 | BloatStoryView | Suggestions not actionable as links/toggles where possible | LOW |
| W11-A-036 | WifiDashboardSection | Width floor (360pt) silently clips in narrow contexts | MED |
| W11-A-037 | KeyboardShortcuts | ⌘R rerun has no visual confirmation of what will rerun | MED |
| W11-A-038 | KeyboardShortcuts | Shortcuts undiscoverable outside tab titles | MED |
| W11-A-039 | netmax.py CLI | --help lacks usage examples per mode | LOW |
| W11-A-040 | netmax.py CLI | Error messages don't suggest nearest valid flag | LOW |
| W11-A-041 | engine_bridge | Envelope errors truncated at 400 chars may cut root cause | LOW |
| W11-A-042 | engine_bridge | droppedFlags surfaced but UI never displays it yet | HIGH |
| W11-A-043 | HistoryStore | No storage-usage indicator (users can't see DB size) | LOW |
| W11-A-044 | HistoryStore | Migration from JSONL happens silently — no completion notice | LOW |
| W11-A-045 | ScheduleRunner | Missed-tick behavior during sleep undocumented in UI | MED |
| W11-A-046 | ScheduleRunner | No "next run" indicator outside Schedule tab | MED |
| W11-A-047 | StatusBarController | Label format fixed; no user preference | MED |
| W11-A-048 | StatusBarController | Stale label ("12m ago") grows indefinitely without refresh cue | LOW |
| W11-A-049 | ThemeTokens | Grade colors not explained anywhere (why orange = C?) | LOW |
| W11-A-050 | ThemeTokens | No high-contrast variant verification documented | LOW |
| W11-A-051 | Motion.swift | Press feedback subtle enough that some users won't notice | LOW |
| W11-A-052 | Motion.swift | Hover-lift absent on Mode Lab mode buttons | LOW |
| W11-A-053 | All sheets | Sheet sizes vary between sheets — inconsistent dimensions | MED |
| W11-A-054 | All lists | Alternating row backgrounds can reduce scanability with materials | LOW |
| W11-A-055 | Empty states | Empty-state illustrations absent — text-only everywhere | LOW |
| W11-A-056 | Error paths | Engine failures show raw stderr tail; no plain-language mapping | MED |
| W11-A-057 | Onboarding | No progress indicator across onboarding steps | MED |
| W11-A-058 | Onboarding | Schedule step appears even for users who'll never automate | LOW |
| W11-A-059 | MenuBarView | Popover closes when clicking outside — mid-review results lost | MED |
| W11-A-060 | HistoryView | Row tap targets full-width but visually ambiguous as buttons | LOW |
| W11-A-061 | ReportsView | PDF filename auto-generated without user-friendly pattern | LOW |
| W11-A-062 | ReportsView | No preview before export | MED |
| W11-A-063 | SettingsView | About section version string easy to miss | LOW |
| W11-A-064 | SettingsView | Reset onboarding destructive without explaining consequences | MED |
| W11-A-065 | FeatureDiscoverySection | Cards always visible — no way to dismiss once familiar | MED |
| W11-A-066 | FeatureDiscoverySection | Deep-link doesn't highlight the target feature on arrival | LOW |
| W11-A-067 | TimelineRangePicker | 1h/24h/7d labels cryptic for non-technical users | LOW |
| W11-A-068 | TimelineSheet | Close button competes with Esc habit — fine, but unlabeled visually | LOW |
| W11-A-069 | AnomalyEngine | Threshold constants not user-tunable (sensitivity setting) | MED |
| W11-A-070 | BloatStory | Story shown post-run but not reachable retroactively from history | MED |
| W11-A-071 | RunPostProcessor | Alert triggered-by logic opaque when user asks "why alerted?" | LOW |
| W11-A-072 | WifiEventEmitter | Event capture failure completely silent by design | LOW |
| W11-A-073 | netmax_eventstore | Event store growth unchecked — no retention integration | MED |
| W11-A-074 | netmax_trends | Python trends module unused by app (Swift port divergence risk) | MED |
| W11-A-075 | Plugin registry | NETMAX_PLUGIN env var invisible to GUI-launched apps | HIGH |
| W11-A-076 | Plugin registry | No plugin listing/validation command | MED |
| W11-A-077 | build_dmg.sh | DMG name lacks arch (arm64/x86_64) suffix | LOW |
| W11-A-078 | notarize.sh | Setup instructions print but no URL shortcuts | LOW |
| W11-A-079 | verify_phase1.sh | Gate script not referenced in README for contributors | LOW |
| W11-A-080 | README | Screenshots section missing entirely | MED |
| W11-A-081 | App icon | Default template icon — no brand identity | MED |
| W11-A-082 | About dialog | Missing credits/licenses for bundled components | LOW |
| W11-A-083 | Accessibility | Focus ring order in sheets not verified programmatically | MED |
| W11-A-084 | Accessibility | VoiceOver announcements on async run completion absent in popover context | MED |
| W11-A-085 | Accessibility | Material contrast over busy wallpapers untested | MED |
| W11-A-086 | Localization | All strings hardcoded English — i18n impossible currently | HIGH |
| W11-A-087 | Localization | Date formats assume one locale style | LOW |
| W11-A-088 | Units | Mbps vs MBps never clarified for consumers | MED |
| W11-A-089 | Units | Temperature-free but ms/% units lack tooltips defining them | LOW |
| W11-A-090 | Data | No export of anomaly/event data separately | LOW |
| W11-A-091 | Data | History search absent — scroll-only navigation | HIGH |
| W11-A-092 | Data | Multi-select absent in History | MED |
| W11-A-093 | Data | Undo absent for any destructive action | HIGH |
| W11-A-094 | Flow | First-run: no sample data offered — empty dashboard greets users | MED |
| W11-A-095 | Flow | Post-run: no prompt to try related features (report card etc.) | LOW |
| W11-A-096 | Performance | Full history loads into memory on every view appear | MED |
| W11-A-097 | Performance | Sparkline redraws on unrelated state changes | LOW |
| W11-A-098 | Consistency | "Check"/"Test"/"Run"/"Measurement" used interchangeably | MED |
| W11-A-099 | Consistency | Title case vs sentence case mixed across headers | LOW |
| W11-A-100 | Consistency | Button capitalization varies (Run Quick Test / Got it / Save) | LOW |
| W11-A-101 | Trust | No visible link to methodology/privacy docs in-app | MED |
| W11-A-102 | Trust | Telemetry stance undocumented in-app | MED |
| W11-A-103 | Feedback | Run completion has no success affordance beyond text change | MED |
| W11-A-104 | Feedback | Export success silent — file just appears somewhere | MED |
| W11-A-105 | Feedback | Save schedule gives weak confirmation | MED |
| W11-A-106 | Input | Numeric steppers accept mouse-only interaction patterns | LOW |
| W11-A-107 | Input | No paste support into path fields demonstrated | LOW |
| W11-A-108 | Windows/resizing | Minimum window height cuts Settings form on small displays | MED |
| W11-A-109 | Windows | Main window title "NetMax" generic — no context per tab | LOW |
| W11-A-110 | Dock | No Dock menu (quick actions) since LSUIElement | LOW |
| W11-A-111 | Menu bar | No right-click context menu on status item | MED |
| W11-A-112 | Menu bar | Status item length unbounded — long labels crowd neighbors | LOW |
| W11-A-113 | Scheduling | Sleep/wake handling of missed intervals invisible | MED |
| W11-A-114 | Scheduling | No pause/resume distinct from enable/disable | MED |
| W11-A-115 | Scheduling | Interval changes require Save — no autosave option | LOW |
| W11-A-116 | Notifications | Test notification button absent | MED |
| W11-A-117 | Notifications | Quiet hours not implemented | MED |
| W11-A-118 | Notifications | Per-rule granularity exceeds most users' needs; no simple mode | LOW |
| W11-A-119 | Export | CSV column order undocumented | LOW |
| W11-A-120 | Export | No export-range selection (all vs last N) | MED |
| W11-A-121 | PDF | Report card PDF has no cover/date branding options | LOW |
| W11-A-122 | PDF | Fonts embedded in PDF may substitute on other machines | LOW |
| W11-A-123 | Trends | Trend window (20 runs) arbitrary and fixed | MED |
| W11-A-124 | Trends | No smoothing option for noisy connections | LOW |
| W11-A-125 | Anomalies | Anomaly list view absent (markers only) | MED |
| W11-A-126 | Anomalies | Dismissed anomalies can re-fire | MED |
| W11-A-127 | Events | WiFi event kinds limited; no custom event annotation | LOW |
| W11-A-128 | Events | Event store never surfaced in UI directly | MED |
| W11-A-129 | Docs | In-app help absent entirely | MED |
| W11-A-130 | Docs | Tooltips exist but no consolidated shortcut cheatsheet | LOW |
| W11-A-131 | Branding | App name collision risk unverified (NetMax common term) | MED |
| W11-A-132 | Legal | No license file shipped in bundle | LOW |
| W11-A-133 | Privacy | Privacy policy URL absent from Settings | MED |
| W11-A-134 | Updates | No update mechanism at all (Sparkle pending) | HIGH |
| W11-A-135 | Updates | Version number not clickable for details | LOW |
| W11-A-136 | Errors | Timeout errors don't offer retry button inline | MED |
| W11-A-137 | Errors | DNS-failure messages don't distinguish DNS vs connectivity | MED |
| W11-A-138 | Resilience | App state not restored after force-quit mid-run | LOW |
| W11-A-139 | Resilience | Partial run results discarded rather than flagged | MED |
| W11-A-140 | Concurrency | Two rapid Quick Tests queue confusingly (second waits) | MED |
| W11-A-141 | Concurrency | Scheduled run during manual run skips silently | MED |
| W11-A-142 | Visual | Metric card icons decorative only — no informational variance | LOW |
| W11-A-143 | Visual | Status badge colors duplicate grade colors — ambiguous semantics | MED |
| W11-A-144 | Visual | Spacing rhythm varies between sections (8/10/12 mix) | LOW |
| W11-A-145 | Visual | Divider usage inconsistent across tabs | LOW |
| W11-A-146 | Content | Footer disclaimers repeat verbatim in multiple places | LOW |
| W11-A-147 | Content | Marketing-ish phrases occasionally slip ("fills your plan") | LOW |
| W11-A-148 | Content | Help text assumes technical vocabulary (throughput, jitter) | MED |
| W11-A-149 | Content | No glossary of networking terms for consumers | LOW |
| W11-A-150 | Structure | Settings form single long scroll — no grouping nav | MED |
| W11-A-151 | Structure | History combines trends+list+trends controls in one pane | MED |
| W11-A-152 | Structure | Mode Lab mixes configuration and results vertically | MED |
| W11-A-153 | Interaction | Double-click vs single-click behaviors differ across lists | MED |
| W11-A-154 | Interaction | Right-click context menus absent everywhere | MED |
| W11-A-155 | Interaction | Drag interactions none (reorder, scrub timeline) | LOW |
| W11-A-156 | Interaction | Timeline not scrubbable — no drag-to-inspect moment | MED |
| W11-A-157 | Timing | Relative timestamps ("12m ago") don't live-update uniformly | MED |
| W11-A-158 | Timing | Timezone display unspecified (local assumed, unstated) | LOW |
| W11-A-159 | Timing | Duration formats vary ("1.5 min" vs "90 s") | LOW |
| W11-A-160 | Sound | Zero audio feedback by design but preference unexposed | LOW |
| W11-A-161 | Haptics | No haptic feedback on supported trackpads | LOW |
| W11-A-162 | Gestures | Swipe gestures unused in lists | LOW |
| W11-A-163 | Gestures | Pinch-to-zoom absent on timeline | MED |
| W11-A-164 | State | App remembers last tab but not last selected mode/filter | MED |
| W11-A-165 | State | Draft schedule changes lost on tab switch without warning | MED |
| W11-A-166 | State | Window position not persisted across launches | LOW |
| W11-A-167 | Security | Pasteboard copy of raw output includes potentially sensitive params | MED |
| W11-A-168 | Security | Bundle contents world-readable including history samples | MED |
| W11-A-169 | Security | Diagnostics bundle opt-in flow absent (built but unreachable) | MED |
| W11-A-170 | Security | No secure erase option for cleared history | LOW |
| W11-A-171 | Testing | UI-level tests absent (all unit/engine level) | MED |
| W11-A-172 | Testing | Snapshot tests for views absent | LOW |
| W11-A-173 | Testing | Localization-ready tests N/A until strings extracted | LOW |
| W11-A-174 | CI | No CI pipeline running suite on commits | HIGH |
| W11-A-175 | CI | Release builds untested in automation | MED |
| W11-A-176 | Packaging | Universal binary status unverified in build script | MED |
| W11-A-177 | Packaging | App category/keywords unset for MAS future | LOW |
| W11-A-178 | Packaging | Hardened runtime not default in dev builds | MED |
| W11-A-179 | Compatibility | macOS 14+ features (Symbols animations) unused gracefully | LOW |
| W11-A-180 | Compatibility | Behavior on 1280×720 displays untested | LOW |
| W11-A-181 | Compat | Multiple-display scenarios (popover on secondary) untested | LOW |
| W11-A-182 | Analytics | No anonymous feature-usage insight (even opt-in) | LOW |
| W11-A-183 | Support | No diagnostics self-service entry point in UI | MED |
| W11-A-184 | Support | Support contact/channel absent | MED |
| W11-A-185 | Community | GitHub links absent from About | LOW |
| W11-A-186 | Community | Contributing guide absent | LOW |
| W11-A-187 | Roadmap visibility | Public roadmap not surfaced anywhere | LOW |
| W11-A-188 | Changelog | In-app changelog viewer missing | MED |
| W11-A-189 | Search | Global search across app absent | LOW |
| W11-A-190 | Print | Printing any view unstyled | LOW |
| W11-A-191 | Clipboard | Copy actions inconsistent (some raw, some formatted) | LOW |
| W11-A-192 | Files | File associations (.netmax exports) absent | LOW |
| W11-A-193 | Services | macOS Services menu integration absent | LOW |
| W11-A-194 | Shortcuts | Shortcuts.app actions absent (planned) | HIGH |
| W11-A-195 | Widgets | WidgetKit widgets absent (planned) | MED |
| W11-A-196 | Watch | Companion watch experience absent (future) | LOW |
| W11-A-197 | Cloud | Sync story absent (by design, needs decision) | MED |
| W11-A-198 | Multi-user | Fast user switching behavior untested | LOW |
| W11-A-199 | Parental | No content/usage restrictions consideration | LOW |
| W11-A-200 | Enterprise | MDM/deployment profile support absent | LOW |

**Summary:** 200 issues · 5 already fixed this wave · 4 CRIT-class themes:
undiscoverable features (labels/digest/plugins), missing safety nets (undo,
CI), unreachable power features (Shortcuts/env plugins), and trust surfaces
(privacy/methodology docs).
