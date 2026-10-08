# Measurement Repeatability Protocol (E-03-SPEC)

## Environment
- **Mac Model/Chip**: MacBook Pro (Apple Silicon M2)
- **macOS Build**: 14.0 (Sonoma)
- **Interface Type**: Wi-Fi (802.11ax)
- **Power**: AC Power connected, background tasks minimized.
- **Network Controls**: Direct connection to router, no active VPN.

## Endpoint
- **Endpoint Origin/IP**: Verified testing endpoint (e.g. `speed.cloudflare.com` / `1.1.1.1`).
- **Idle-Link Check**: Confirm < 1% background bandwidth utilization before starting.

## Protocol Execution
1. **Warmup**: Execute 2 initial warmup runs to prime connections and DNS.
2. **Sampling**: Execute exactly 10 samples per metric.
3. **Throughput Duration**: Each throughput sample (download/upload) runs for exactly 15 seconds.

## Metrics & Formulas
- **Throughput**: Measured in Mbps (Megabits per second, base-10). Formula: `(total_bytes * 8) / (duration_ms / 1000) / 1000000`.
- **Latency/Jitter**: Measured in milliseconds (ms). Median and spread (IQR) calculated.
- **Coefficient of Variation (CV)**: Calculated as standard deviation / mean for throughput. Target is ≤5%.

## Exclusions
- Do not collect or log SSID, public client IP, username, or home directory paths.
