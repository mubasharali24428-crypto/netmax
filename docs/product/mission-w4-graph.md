# Mission W4 — X6 + X5 + N1: Insight & Distribution

Base: netmax-app @ `fdb7bd2` (wave-3 complete, 6-tab app, automation live).
Dispatch: 19-slot concurrency. **3 ALEX teams (builders) + 3 verifier teams** run
side-by-side per the user-mandated pipelining (verify starts when a team lands,
never after the whole wave).

## Team → mission map

| Team | Mission | Effort | Key constraint |
|---|---|---|---|
| **TEAM-1 "Explainer"** | X6 bufferbloat storytelling | S | Pure data→copy mapping; house honest-voice |
| **TEAM-2 "Oracle"** | X5 anomaly detection | M | Rule-based first; plain-language; no false promises |
| **TEAM-3 "Notary"** | N1 distribution prep | — | $99 acct NOT available yet → build everything short of the paid call |

## TEAM-1 lanes (X6)
| Lane | Task | Owns |
|---|---|---|
| T1-a | BloatStory model: grade letter → {cause text, activity impact (calls/gaming/calls), one actionable suggestion} from real measured delta_ms bands in netmax.py:270 | `BloatStory.swift` |
| T1-b | Bloat story card UI embedded under Mode Lab result + History detail sheet hook | `BloatStoryView.swift` |

## TEAM-2 lanes (X5)
| Lane | Task | Owns |
|---|---|---|
| T2-a | Anomaly engine Swift port: rolling median + MAD flags over HistoryStore records (mbps/loss/jitter), confidence wording ("unusual", never "broken"), min-data gate (<10 runs → quiet) | `AnomalyEngine.swift` |
| T2-b | Anomaly annotations on History trend section + Dashboard badge when recent anomaly | `AnomalyAnnotationsView.swift` |

## TEAM-3 lanes (N1)
| Lane | Task | Owns |
|---|---|---|
| T3-a | Notarization pipeline script: entitlements.plist, hardened-runtime build variant, `notarytool submit --wait` + `stapler staple` steps (script EXITS with clear "requires APPLE_DEV_ID" gate when identity absent — never fakes) | `scripts/notarize.sh`, `scripts/entitlements.plist` |
| T3-b | DMG builder: pretty background, drag-to-Applications layout via create-dmg-style AppleScript, signed+notarized-ready | `scripts/build_dmg.sh` |
| T3-c | Distribution README: step-by-step paid-account setup → cert creation → first notarized release checklist | rewrite of `desktop/README.md` distribution section |

## Verifier teams (fire on team completion, pipelined)

| V-Team | Audits | Gate |
|---|---|---|
| V1 | TEAM-1: story copy matches measured bands (no invented fixes), UI builds | swift build + copy-vs-rubric diff probe |
| V2 | TEAM-2: injected anomaly flagged / clean series silent / <10-run quiet gate holds | engine unit probes pasted |
| V3 | TEAM-3: script refuses to fake-notarize without cert; DMG dry-run structure; README accuracy vs scripts | bash -n + dry-run execution |

## Merge law
ATLAS merges per-team as verifier verdicts land (pipelined). Single commit per
team-vertical. Final wave commit after all three. Rollback = revert team commits.
