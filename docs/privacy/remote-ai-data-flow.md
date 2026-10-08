# Remote AI data flow

## Consent and default

Remote AI is disabled by default. The desktop toggle is **Settings → Remote AI
Privacy → Allow remote AI analysis**. It stores the Boolean preference
`netmax.prefs.allowRemoteAI` through `AppPreferences.shared`. The engine reads
that preference from the `com.netmax.desktop` defaults domain before constructing
a remote request. A missing, unreadable, malformed, or timed-out preference is
treated as off. Environment variables and MCP arguments cannot grant consent.

Turning this setting off prevents remote-provider requests; it does not disable
local heuristics or a model endpoint on exact loopback (`localhost` or a
loopback IP). Local endpoints use the existing prompt path and do not read the
remote-consent preference.

## Data sent by an approved remote request

The provider boundary accepts only this user-data envelope:

```json
{
  "schema_version": 1,
  "analysis_id": "registered analysis name",
  "metrics": {
    "mode": "registered mode",
    "streams": 4,
    "duration_seconds": 60,
    "download_mbps": 50.0,
    "upload_mbps": 10.0,
    "latency_ms": 12.5,
    "jitter_ms": 2.0,
    "packet_loss_percent": 0.1,
    "bufferbloat_grade": "A",
    "sample_count": 8,
    "dns_latency_ms": 15.0
  }
}
```

Metric fields are optional and validated individually. The accepted names are
`mode`, `streams`, `duration_seconds`, `download_mbps`, `upload_mbps`,
`latency_ms`, `jitter_ms`, `packet_loss_percent`, `bufferbloat_grade`,
`sample_count`, and `dns_latency_ms`. Values must have the documented enum,
integer, finite-number, and range types in the shared contract
[`mission-l3-graph.md`](../product/mission-l3-graph.md). Unknown keys and
non-finite/out-of-range values are rejected.

Raw history rows, timestamps, notes, free-text prompts, SSID/BSSID, hostnames,
IP addresses, usernames, paths, and secrets are not accepted in the remote
payload. Any useful history must first be reduced by its caller to the approved
aggregate metrics. The fixed system message instructs the model to treat the
JSON as data, not instructions; arbitrary caller prompt/system text is not sent.

The request also contains protocol metadata such as the configured model name,
token limit, JSON-mode setting where supported, and an authentication header.
The configured provider receives that request at its configured endpoint. API
keys are sent only in the provider's authentication header, not in the JSON
messages. NetMax makes no claim here about a provider's retention, training, or
regional processing; check the chosen provider's current terms before enabling
remote use.

## Current implementation boundary

The provider enforces consent and the strict payload contract. At this revision,
the existing measurement analyzers do not yet submit that structured envelope,
so their remote calls are rejected and their local fallback remains in use,
even when the toggle is on. The shipped explicit remote-payload call is provider
verification (`netmax model --verify`); it sends an empty metrics object. Remote
analysis adapters must be added and tested individually before analyzer data is
sent to a remote provider.

The MCP `ai_analyze` tool cannot enable or override consent. When remote egress
is denied, it may return a locally generated result labeled `source: local`.
Remote MCP transport and remote AI provider egress are separate settings and
trust boundaries.

## No unrelated telemetry

This provider flow is not analytics or phone-home telemetry. Measurement
requests continue to go only to the selected measurement endpoints. This
document does not promise that a configured AI provider retains no data.
