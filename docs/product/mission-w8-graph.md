# Mission W8 — APPLE-DESIGN UI PASS (ALEX-ELITE ×2 teams)

Base: netmax-app @ `3f6a3a5`. Skill: `apple-design` (loaded; principles below
are binding for every lane).

## Design law (from the skill — apply to SwiftUI, adapted)
1. **Response:** feedback on press-down (`.buttonStyle` w/ scale-on-press),
   never only on completion. No artificial delays on input paths.
2. **Interruptibility/springs:** all motion = springs from current value.
   Default `spring(response: 0.35, dampingFraction: 1.0)`; bounce
   (`dampingFraction ~0.8`) ONLY where momentum existed (sheet flick).
3. **Spatial consistency:** sheets enter/exit along the same path; popovers
   anchor to their trigger.
4. **Materials & depth:** toolbars/sheets read as materials — `.ultraThinMaterial`
   with content scrolling under; heavier material = structural, lighter =
   interactive. Never stack light-on-light.
5. **Typography:** SF Pro system font; size-specific tracking (tighten large);
   hierarchy via weight+size+leading as a set; Dynamic Type safe.
6. **Reduced motion/transparency:** `@Environment(\.accessibilityReduceMotion)`
   → cross-fades instead of slides; `.accessibilityReduceTransparency` → solid.
7. **Foundations:** purpose (cut what doesn't pay), familiarity (macOS close is
   top-left), craft (every value defensible), delight = result of the other 7.

## TEAM-A "Motion & Materials" lanes
| Lane | Task | Owns |
|---|---|---|
| A1 | ThemeTokens motion extension: standard spring constants + reduce-motion helpers; press-scale ButtonStyle ("NetMaxPressStyle": scale 0.97 on press-down, spring back) applied app-wide via root | ThemeTokens.swift + new Motion.swift |
| A2 | Sheet material pass: TimelineSheet + RunDetailSheet + ReportCard sheet → .ultraThinMaterial chrome bars, same-path enter/exit, anchored transitions; reduce-transparency fallbacks | those sheet files |

## TEAM-B "Type & Hierarchy" lanes
| Lane | Task | Owns |
|---|---|---|
| B1 | Typography audit+fix: headings tracking tightened at large sizes, weight-based hierarchy (not size-only), leading set per role; Dynamic Type check on dashboard cards | DashboardCardsView + BloatStoryView |
| B2 | Wayfinding & feedback polish: consistent toolbar placement, confirmation dialog only for destructive (audit current dialogs), empty-state copy tone pass (honest voice), hint bar visual refinement | HistoryView + MenuBarView small hunks |

## Rules
- Write-first protocol (provider unstable). Skeleton → probe → reconcile.
- NO redesign of layout structure; this is a craft pass on existing surfaces.
- Suite green or grows; every animation respects reduce-motion.
- ATLAS gates: build + suite + bundle + live probe per team; merges per team.
