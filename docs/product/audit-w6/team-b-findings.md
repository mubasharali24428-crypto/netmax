# W6 Team-B Findings — Product & Scale Audit

> ATLAS-authored after two delegated attempts died on provider 500s with zero
> writes. Compressed audit executed directly; evidence paths cited inline.

## Findings

### B-F1 · MED — Tooltip discoverability is near-zero
- `grep -rc '.help(' desktop/SwiftNetMax/Sources/netmax-desktop/*.swift` → only
  a handful of hits across ~45 files. ⌘1–6/⌘R shortcuts (KeyboardShortcuts.swift)
  are wired but never surfaced in UI.
- **Fix applied:** none yet (needs RootView edit — queued for wiring pass).
- **Recommendation:** add `.help("⌘1")`-style tooltips on tab labels; add a
  Shortcuts row in Settings.

### B-F2 · PASS — Data-at-rest inventory clean
- `~/Library/Application Support/NetMaxDesktop/`: history.jsonl, wifi_events.jsonl,
  results dirs. All local-only, user-controlled. No cloud egress found.
- Network calls: engine hits public speed-test endpoints + DNS resolvers only
  (`netmax.py` fetch targets); app-side URLSession limited to EngineClient bridge.
- No hardcoded secrets anywhere in Sources/ or netmax*.py (grep clean).

### B-F3 · PASS — Bundle redaction still holds
- `netmax_bundle.sanitize` probe: `/Users/x/y`→`~user`, ssid/password/env keys
  redacted/dropped. W4 adversarial findings remain fixed.

### B-F4 · LOW — Notarization gate intact, blocked only on $99 account
- `scripts/notarize.sh` syntax-clean; exits 2 with setup instructions sans cert;
  hardened-runtime path ready when identity exists.

## Architecture seams (B-S3)
- **Multi-device:** event store (netmax_eventstore.py) is already a generic JSONL
  append log — a second device's events can land in the same schema. Missing:
  LAN discovery + pairing consent UI.
- **Plugin modes:** netmax.py registers modes via explicit functions + MODES
  table; a registry pattern (decorator-based) would let third parties add modes
  without touching core dispatch.
- **Cloud sync:** history.jsonl is append-only and ts-keyed — syncable as-is via
  CRDT-ish last-writer merge or simple rsync; privacy gate = explicit opt-in +
  anonymization layer (per roadmap L2).

## Growth/distribution (B-S4)
- Distribution path exists end-to-end except the paid Apple cert ($99) — the
  single blocker to public distribution.
- Website needs: landing page w/ honest-limits positioning, download link
  (post-notarization), FEATURES.md as content base.
- Pricing: honest-limits brand argues against subscription for a local-only
  tool; one-time purchase or free+paid-report-tier fits better (N10 decision).
