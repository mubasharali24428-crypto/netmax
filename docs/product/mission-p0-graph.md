# Mission P0 — NetMax Desktop Phase 0: Signed Shell + Onboarding

Base: `8a6733b`. Goal: double-clickable macOS menu-bar app wrapping today's engine,
honest-limits onboarding, ad-hoc signed (notarization blocked on paid Apple Dev acct —
documented, not faked).

## Toolchain facts (measured 2026-08-23)
Python 3.13.13 @ /Users/user/1/bin/python · Swift 6.3.3 · Xcode 26.6 · py2app/briefcase ABSENT · NO signing identities → `codesign -s -` (ad-hoc) only.

## Layout (all new code under desktop/)
```
desktop/
  bridge/engine_bridge.py        # B2
  bridge/test_engine_bridge.py   # B2
  SwiftNetMax/Package.swift      # B1
  SwiftNetMax/Sources/netmax-desktop/*.swift   # B1 (shell) + B3 (Onboarding*.swift)
  scripts/build_app.sh           # B4
  scripts/verify_phase0.sh       # B4
```

## Contracts (ATLAS-fixed; changes require coordinator sign-off)
- **C1 bridge:** `engine_bridge.py run <mode> [--streams N] [--seconds N] [--count N] --json-out PATH`
  → exit 0 on success; PATH gets `{"success": true, "mode": "...", "data": {...}, "error": null}`;
  failures exit nonzero with `"success": false, "error": "<msg>"`. Interpreter resolution:
  env `NETMAX_PYTHON` → `sys.executable`. Tests are OFFLINE (mock subprocess); never hit network.
- **C2 onboarding:** `protocol OnboardingFlow { var isComplete: Bool { get } mutating func advance() }`;
  B3 owns `OnboardingFlow.swift` (+views) conforming; B1 calls it from shell. Copy carries the
  four honest-limits points from README (ISP cap, contention-only gains, router QoS, dropouts real).

## DAG
```
     [P0 ATLAS: fork-state + graph + contracts]  done
        |            |            |            |
      [B1]         [B2]         [B3]         [B4]
   swift shell  py bridge    onboarding    bundle+verify
        |            |            |            |
        +--[PairA: B1xB3 seam]----+            |
        +--[PairB: B2 alone]-------------------+
                     +--[PairC: B4 artifact]---+
                                |
                    [ATLAS merge: full suite + live probe + single commit]
```

## File ownership (violations void lane)
| Lane | Owns |
|---|---|
| B1 | Package.swift, Sources/netmax-desktop/{App.swift,MenuBarView.swift,EngineClient.swift} |
| B2 | bridge/* |
| B3 | Sources/netmax-desktop/Onboarding*.swift |
| B4 | scripts/*, desktop/README.md |

## Merge checklist
- [ ] swift build -c release green; pytest green; verify_phase0.sh green end-to-end
- [ ] .app exists, LSUIElement, launches, codesign -v passes (ad-hoc)
- [ ] footprint clean; single ATLAS commit; rollback = git revert

## Rollback
Revert the P0 mission commit(s); desktop/ is purely additive.
