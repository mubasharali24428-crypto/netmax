# Mission W9 — GLASSMORPHISM + NATIVE TRANSITIONS (apple-design deep pass)

Base: netmax-app @ `f89afdc`. Skill: apple-design (§12 Materials, §4 Springs,
§14 Reduced-motion — binding).

## Design law for this pass
- **Glass = material hierarchy:** `.ultraThinMaterial`/`.regularMaterial` on
  floating chrome (sheet headers, toolbars, hint bar, popovers); content stays
  opaque. Never light-on-light stacking. `saturate(180%)` feel via vibrancy.
- **Smooth transitions:** every state change animates with NetMaxMotion
  springs from current value; sheets keep AppKit-native slide; in-view changes
  use `.animation(NetMaxMotion.standard, value:)`.
- **Native-feel transitions:** sidebar/list selection highlights animate;
  card hover lift (scale 1.01 + shadow) on pointer-over; grade letters
  count/appear with opacity+slight-scale; sparkline draws in.
- **Reduce motion/transparency:** all of the above degrade to cross-fades and
  solid surfaces.

## Lanes (ATLAS executes directly — provider instability continues)

| Lane | Task | Owns |
|---|---|---|
| G1 | Glass chrome: sheet headers (TimelineSheet, RunDetailSheet) get material bars w/ bottom hairline; MenuBarView popover header glass; hint bar → regularMaterial pill w/ Theme.Radius | those files |
| G2 | Transition polish: dashboard cards appear with staggered spring fade+rise on data load; grade letter scale-in; tab-content cross-fade via .transaction; list row insert/remove animations | DashboardCardsView, HistoryView |
| G3 | Hover/lift system: .netMaxHoverLift() modifier (scale 1.01 + shadow deepen on hover, spring standard); applied to metric cards, history rows, mode buttons; reduce-motion = shadow-only | Motion.swift + apply |

## Gate
Build release + suite green + bundle + live probe per batch. Single W9 commit.
