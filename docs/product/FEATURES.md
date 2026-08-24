# NetMax Desktop — Feature Guide

A macOS menu-bar app that measures what your internet connection actually
delivers, keeps the evidence in a local history you control, and grades your
ISP's performance — without ever promising more than physics and your plan
allow.

**The honest part first:** NetMax cannot raise your ISP cap. No software can —
the cap is enforced on the provider's side of the line. What NetMax *can* do is
measure precisely, explain why things feel slow, show you when your connection
degrades, and hand you shareable evidence for the conversation with your
provider. Anyone promising to "10x your speed" is selling scamware; this app
will never make that claim.

Everything below runs locally. Your measurement history stays on your Mac;
nothing is uploaded anywhere by default.

---

## Dashboard

The at-a-glance home. Metric cards summarize your most recent run — download,
upload, latency, packet loss, jitter — with a sparkline tracing recent trend,
plus a WiFi section showing signal strength (RSSI), noise, and channel as read
from your Mac's airport hardware. Cards are empty until your first test runs;
the app says so plainly instead of showing zeros.

## Mode Lab

Every engine mode in one place, with adjustable parameters:

- **Baseline** — true single-stream throughput, the honest floor of your plan.
- **Turbo** — N parallel TCP streams claiming a larger per-flow share of a
  *contended* WiFi pipe (standard fairness, no tricks). Gains appear only when
  other devices are pulling traffic; on an idle line baseline already *is* your
  plan.
- **Boost** — baseline vs turbo back-to-back, with a measured gain percentage.
- **DNS** — ranks public resolvers by real latency.
- **Bloat** — bufferbloat grade on the A+–F rubric, measured under load.
- **Full** — everything above plus upload, loss, jitter, and WiFi, with an
  overall verdict.
- **Upload / Loss / Jitter / WiFi** — the individual diagnostics.

Each mode exposes its parameter steppers (streams, duration). If a run fails —
say, the network drops mid-test — you get a plain-language error card with
suggested next steps, not a stack trace. Zero-throughput windows are reported
as real dropouts; the app does not invent flattering numbers.

## History

Every run lands here, stored locally in SQLite. Trend bars chart throughput
across days or weeks; click any run for a detail sheet with the full result
set. The anomaly engine reads your own history and flags statistically notable
shifts — a sudden median drop, rising loss, jitter creep — annotated directly
on the timeline with plain-language wording ("unusual," not "broken") and a
confidence qualifier. Anomalies are hints worth investigating, not diagnoses.

## Schedule

Set automatic tests — hourly, every few hours, daily at a time — from the
editor. Scheduled runs go into history tagged as scheduled, skip silently when
you're offline, and feed the degradation alerts below. Behind the scenes the
app manages a macOS launchd agent so tests fire even when no window is open;
the tab gives you start/stop controls and shows the runner's live state.
Battery note: frequent background tests wake the network stack; if you're on
battery, prefer longer intervals.

## Reports

Your evidence kit. Export any run — or a trend window — as CSV or JSON for
your own records, and generate the **ISP report card**: a single-page PDF that
sets your plan's advertised tier next to what was actually measured, letter-
grades the result including bufferbloat, and carries an explicit honest-limits
footer. One click hands the PDF to the macOS share sheet (AirDrop, Mail,
Messages). Reports are informational documents built only from measured data —
they are not certified audit artifacts, and they don't pretend to be.

## Bufferbloat storytelling

A raw A+–F grade doesn't tell most people anything, so the bloat page explains
itself through activities: how video calls, gaming, and streaming behave at
your measured latency-under-load, plus one actionable suggestion. It links the
story back to the actual numbers. It never promises fixes it can't perform —
if the fix is "call your ISP or upgrade your router," it says that.

## Automation & notifications

When scheduled tests detect sustained degradation versus your recent norm —
significantly below your trailing median across consecutive runs, by default —
NetMax posts a local notification with one-tap access to the report. Normal
results stay silent, and a minimum gap between alerts prevents spam. All of it
runs on-device; there is no push service and no telemetry.

## Settings

Interpreter override (`NETMAX_PYTHON`), notification thresholds and quiet
gaps, schedule preferences, launch-window behavior, and a "Reset tour" that
replays the honest-limits onboarding shown at first launch.

---

## What NetMax will not do

- Exceed your ISP cap, ever — impossible from the client side.
- Promise speed gains on an idle line; gains exist under contention only.
- Touch your router configuration; router-side QoS overrides everything here.
- Phone home. Data is local-first; exports leave only when you share them.

*Requirements: macOS 13+, bundled Python runtime. Distribution today is
ad-hoc signed — see RELEASE-NOTES.md for what that means.*
