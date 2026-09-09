# Exhausted checks (do not redo blindly this engagement)

| Check | When | Result |
|---|---|---|
| pytest -q | round 1 | 192 passed |
| bridge selftest | round 1 | 3/3 |
| codesign -dv / -v --deep (build) | round 1 | adhoc, seal VALID |
| spctl assess | prior audit + round 1 | rejected (expected pre-notarization) |
| appdata perms ls | round 1 | all 0600 |
| pycache-in-bundle scan | round 1 | 0 found |
