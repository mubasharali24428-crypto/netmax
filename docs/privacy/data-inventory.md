# NetMax Data Inventory & Local-History Retention Contract

This document provides a complete inventory of all persisted data categories created or maintained by NetMax Desktop, including locations, permissions, purpose, retention behavior, outbound telemetry status, and explicit deletion/erase mechanisms.

## Summary of Persisted Data

| Data Category | Path / Storage Location | Permissions | Purpose | Retention Behavior (`retentionDays`) | Outbound Status | Deletion & Erase Action |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Active History (JSONL)** | `~/Library/Application Support/NetMaxDesktop/history.jsonl` | 0600 (User-only) | Stores local network measurement logs | If `retentionDays > 0`, records older than N days are archived to `archive-history.jsonl`. If `0`, kept indefinitely. | None (100% on-device) | Reversible "Clear History" moves to `cleared-history.jsonl`. Permanent erase unlinks file. |
| **History Database (SQLite)** | `~/Library/Application Support/NetMaxDesktop/history.db` (plus `-wal`, `-shm` sidecars) | 0600 (User-only) | Indexed SQLite query store for fast desktop history browsing | Mirrors `history.jsonl` entries. | None (100% on-device) | Checkpointed, closed, and permanently unlinked during permanent erase. |
| **Archive History (JSONL)** | `~/Library/Application Support/NetMaxDesktop/archive-history.jsonl` | 0600 (User-only) | Holding store for historical records rotated out by retention rules | Preserves rows older than `retentionDays` without showing them in the live view. | None (100% on-device) | Unlinked by permanent erase. |
| **Cleared History Holding** | `~/Library/Application Support/NetMaxDesktop/cleared-history.jsonl` | 0600 (User-only) | Safety undo holding bin when the user clears history | Preserved until explicitly emptied or overwritten by next Clear. | None (100% on-device) | Restored via "Undo" or permanently unlinked by permanent erase. |
| **Application Preferences** | `~/Library/Preferences/com.netmax.desktop.plist` (UserDefaults) | 0600 (User-only) | App settings, dark mode, `netmax.prefs.allowRemoteAI`, etc. | Persisted indefinitely across app updates. | None | Managed in macOS System Settings / App Settings. Not affected by history erase. |
| **Diagnostic Logs** | `~/Library/Logs/NetMaxDesktop/` and `~/.netmax/logs/*.log` | 0600 (User-only) | Debugging and operational error logs | Rotated locally, capped. | None | Deleted manually or pruned via OS log rotation. Not affected by history erase. |
| **Support Bundles** | User-selected destination (e.g., `~/Downloads/netmax-diagnostics.zip`) | 0600 (User-only) | Sanitized diagnostic export for user bug reports | Created only on-demand by explicit user export. | None (user must manually attach) | Deleted manually by user. Not affected by history erase. |

---

## Retention Contract

1. **Indefinite Retention Default (`retentionDays = 0`)**:
   When `netmax.history.retentionDays` is `0`, all measurement history is kept indefinitely.
2. **Archival on Pruning (`retentionDays > 0`)**:
   When set to a positive integer `N`, measurements older than `N` days are **not** silently destroyed. Instead, they are moved to `archive-history.jsonl` to ensure accidental data loss never occurs.
3. **Reversible Clear vs Permanent Erase**:
   - **Reversible Clear History**: Moves `history.jsonl` to `cleared-history.jsonl`. Can be undone by the user.
   - **Permanent Erase**: An explicit, irreversible destructive operation that removes:
     - `history.jsonl` (live JSONL)
     - `history.db`, `history.db-wal`, `history.db-shm` (SQLite database and WAL/SHM sidecars)
     - `archive-history.jsonl` (retention archive)
     - `cleared-history.jsonl` (cleared history holding bin)
   - Permanent erase requires explicit user confirmation in the UI.
   - Permanent erase does **not** delete user preferences, log files, or manually exported support bundles/CSVs.
   - No data is ever transmitted outbound during or as a result of permanent erase.
