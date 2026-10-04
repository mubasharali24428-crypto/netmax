#!/usr/bin/env python3
"""P1 AI-assisted diagnostics for NetMax.

Ten analysers that turn raw measurements into an explanation and a fix. The
shared contract with netmax_ai.py:

- Local heuristics answer first and are the DEFAULT. They are free, offline
  and deterministic, so every class below works with no API key at all.
- NETMAX_AI_API_KEY opts into model reasoning for the cases heuristics
  cannot settle (ambiguous attribution, prose diagnosis, intent parsing).
- No analyser ever raises on transport failure: `_ask` returns None and the
  caller keeps its local answer.
- Model output is CLAMPED and VALIDATED. A model can rank, name and
  explain, but it cannot widen a numeric bound or invent a measurement the
  caller did not supply.

This is an analysis layer only — it reads measurements and returns advice.
It never issues `sudo`, never mutates system config, and never runs a
measurement of its own.
"""

from __future__ import annotations

import json
import os
import re
import statistics
import time
from dataclasses import dataclass, field
from typing import Any, ClassVar

import netmax_ai_provider as provider_mod
from netmax_ai import DEFAULT_AI_BASE, DEFAULT_AI_MODEL, _chat_json

# Grade ordering mirrors netmax.py's BLOAT_GRADES rubric so callers can
# compare a P1 verdict against the engine's own A+..F scale.
GRADE_RANK = {"A+": 0, "A": 1, "B": 2, "C": 3, "D": 4, "F": 5}


class _Base:
    """Shared history + opt-in model plumbing.

    Subclasses implement `analyze()`; this base owns the API-key plumbing,
    the history ring buffer and the never-raise guarantee.
    """

    system = "You are a JSON-only network diagnostician."

    def __init__(
        self,
        history_limit: int = 40,
        *,
        api_key: str | None = None,
        model: str = DEFAULT_AI_MODEL,
        api_base: str = DEFAULT_AI_BASE,
        timeout_s: float = 6.0,
    ) -> None:
        self.history_limit = history_limit
        self.history: list[dict[str, Any]] = []
        self.api_key = (
            api_key if api_key is not None
            else os.environ.get("NETMAX_AI_API_KEY", "")
        )
        self.model = model
        self.api_base = api_base
        self.timeout_s = timeout_s

    # ── history ───────────────────────────────────────────────────────────────

    def _remember(self, row: dict[str, Any]) -> None:
        row.setdefault("ts", time.time())
        self.history.append(row)
        self.history[:] = self.history[-self.history_limit:]

    # ── model plumbing ────────────────────────────────────────────────────────

    def _ask(self, prompt: str, *, max_tokens: int = 300) -> dict[str, Any] | None:
        """JSON-mode model call, or None on any failure. Never raises."""
        if not provider_mod.has_provider(api_key=self.api_key):
            return None
        try:
            return _chat_json(
                prompt,
                api_key=self.api_key,
                model=self.model,
                api_base=self.api_base,
                timeout_s=self.timeout_s,
                max_tokens=max_tokens,
                system=self.system,
            )
        except (OSError, ValueError, TypeError, KeyError):
            return None

    @staticmethod
    def _clamp(value: float, low: float, high: float,
               fallback: float = 0.0) -> float:
        try:
            v = float(value)
        except (TypeError, ValueError):
            return fallback
        if v != v:  # NaN
            return fallback
        return max(low, min(high, v))

    @staticmethod
    def _first_float(raw: dict[str, Any], *keys: str) -> float | None:
        for k in keys:
            if k in raw:
                try:
                    return float(raw[k])
                except (TypeError, ValueError):
                    continue
        return None

    @staticmethod
    def _str_list(raw: dict[str, Any], key: str) -> list[str]:
        val = raw.get(key)
        if not isinstance(val, list):
            return []
        return [str(v) for v in val if isinstance(v, (str, int, float))]


# ── 3. MultiObjectiveOptimizer ────────────────────────────────────────────────

@dataclass
class ObjectiveWeights:
    """Relative importance of each objective. Higher = care more."""
    throughput: float = 1.0
    latency: float = 1.0
    jitter: float = 0.5
    fairness: float = 0.5

    def normalised(self) -> dict[str, float]:
        total = (self.throughput + self.latency
                 + self.jitter + self.fairness)
        if total <= 0:
            return {"throughput": 1.0, "latency": 0.0,
                    "jitter": 0.0, "fairness": 0.0}
        return {
            "throughput": self.throughput / total,
            "latency": self.latency / total,
            "jitter": self.jitter / total,
            "fairness": self.fairness / total,
        }


class MultiObjectiveOptimizer(_Base):
    """Score stream-count options on a throughput/latency/jitter/fairness mix.

    The scalar "hold 5 Mbps" target hides a real trade-off: more streams buy
    aggregate throughput on a contended pipe but cost per-flow latency and
    fairness to other devices. This scores each candidate stream count and
    returns the best one under the caller's weights.
    """

    system = "You are a JSON-only network trade-off analyst."

    @staticmethod
    def _score(option: dict[str, Any], weights: ObjectiveWeights) -> float:
        """Scalar utility in [0, 1]. Higher is better."""
        norm = weights.normalised()
        throughput = min(1.0, option.get("throughput_mbps", 0.0) / 100.0)
        # Latency/jitter invert: 0 ms -> 1.0, 200 ms -> 0.0
        latency = 1.0 - min(1.0, option.get("latency_ms", 0.0) / 200.0)
        jitter = 1.0 - min(1.0, option.get("jitter_ms", 0.0) / 100.0)
        fairness = min(1.0, max(0.0, option.get("fairness", 0.5)))
        return (norm["throughput"] * throughput
                + norm["latency"] * latency
                + norm["jitter"] * jitter
                + norm["fairness"] * fairness)

    def optimize(
        self,
        options: list[dict[str, Any]],
        weights: ObjectiveWeights | None = None,
    ) -> dict[str, Any] | None:
        """Pick the best option under `weights`. None when there is nothing."""
        w = weights or ObjectiveWeights()
        if not options:
            return None
        scored = sorted(
            (
                {**opt, "score": round(self._score(opt, w), 4)}
                for opt in options
            ),
            key=lambda o: o["score"],
            reverse=True,
        )
        best = scored[0]
        self._remember({"kind": "optimize", "n_options": len(options)})
        if provider_mod.has_provider(api_key=self.api_key) and len(scored) > 1:
            raw = self._ask(
                "Pick the best network configuration from these scored "
                "options. Return JSON only.\n"
                "Schema: { pick_streams: number, reasoning: string, "
                "confidence: string }\n"
                "Trade-off rule: if an interactive session (call/game) is "
                "active, latency outranks raw throughput. Otherwise favour "
                "throughput. Never pick outside the offered stream counts.\n"
                f"Offered (already scored 0..1): {json.dumps(scored)}\n",
                max_tokens=200,
            )
            allowed = {int(o.get("streams", 0)) for o in scored}
            pick = self._first_float(raw or {}, "pick_streams", "streams")
            if pick is not None and int(pick) in allowed:
                for opt in scored:
                    if int(opt.get("streams", -1)) == int(pick):
                        return {**opt, "reasoning": str(raw.get("reasoning", ""))[:300],
                                "source": "ai"}
        return {**best, "source": "local"}


# ── 5. AdaptiveChunkSizer ─────────────────────────────────────────────────────

# Byte-range chunk bounds. Small enough that a retry after loss is cheap,
# large enough that per-chunk HTTP overhead stays negligible.
CHUNK_MIN_BYTES = 256 * 1024
CHUNK_MAX_BYTES = 16 * 1024 * 1024
CHUNK_DEFAULT_BYTES = 4 * 1024 * 1024


class AdaptiveChunkSizer(_Base):
    """Choose a byte-range chunk size from observed round-trip behaviour.

    High jitter means a chunk in flight is likely to be lost, and the wasted
    work scales with chunk size — so shrink. A stable low-RTT link can carry
    far larger chunks before the per-request overhead dominates.
    """

    system = "You are a JSON-only download tuner."

    def __init__(self, *args, min_bytes: int = CHUNK_MIN_BYTES,
                 max_bytes: int = CHUNK_MAX_BYTES, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.min_bytes = min_bytes
        self.max_bytes = max_bytes

    def suggest_chunk_bytes(
        self,
        rtt_ms: float,
        jitter_ms: float = 0.0,
        loss_pct: float = 0.0,
        throughput_mbps: float = 100.0,
    ) -> dict[str, Any]:
        """Return a chunk size in bytes plus why.

        Banding is derived from the bandwidth-delay product: a chunk should
        stay near one RTT of pipe so a loss costs ~1 RTT of work, not more.
        `throughput_mbps` is the observed pipe rate — it sets the BDP, so a
        wrong guess scales every chunk proportionally.
        """
        self._remember({
            "kind": "chunk", "rtt_ms": rtt_ms,
            "jitter_ms": jitter_ms, "loss_pct": loss_pct,
        })

        rtt = max(1.0, self._clamp(rtt_ms, 0.0, 10_000.0, 50.0))
        jitter = self._clamp(jitter_ms, 0.0, 10_000.0, 0.0)
        loss = self._clamp(loss_pct, 0.0, 100.0, 0.0)
        mbps = self._clamp(throughput_mbps, 0.5, 10_000.0, 100.0)

        est_bps = mbps * 1e6 / 8
        chunk = int(rtt / 1000.0 * est_bps)

        # Instability shrinks the chunk so a lost chunk wastes less work.
        instability = (jitter / rtt) + (loss / 10.0)
        chunk = int(chunk / (1.0 + 4.0 * instability))

        chunk = max(self.min_bytes, min(self.max_bytes, chunk))
        reason = (
            f"rtt {rtt:.0f}ms, jitter {jitter:.0f}ms, loss {loss:.1f}% "
            f"-> instability {instability:.2f}"
        )
        result = {"chunk_bytes": chunk, "reasoning": reason, "source": "local"}

        raw = self._ask(
            "Choose a byte-range chunk size in bytes for a parallel HTTP "
            "download. Return JSON only.\n"
            f"Schema: {{ chunk_bytes: number, reasoning: string }}\n"
            f"Hard bounds: min {self.min_bytes}, max {self.max_bytes}.\n"
            f"Observed: {reason}\n",
            max_tokens=120,
        )
        picked = self._first_float(raw or {}, "chunk_bytes")
        if picked is not None:
            clamped = int(max(self.min_bytes, min(self.max_bytes, picked)))
            result = {"chunk_bytes": clamped,
                      "reasoning": str(raw.get("reasoning", reason))[:300],
                      "source": "ai"}
        return result


# ── 6. CrossStreamCoordinator ─────────────────────────────────────────────────

class CrossStreamCoordinator(_Base):
    """Split one aggregate cap unevenly across streams by measured health.

    The hardcoded governor divides the cap evenly (`target / streams`), which
    is wrong when streams do not share the same path quality. This keeps the
    aggregate fixed while giving each stream a share proportional to how well
    it has actually been delivering.
    """

    system = "You are a JSON-only stream allocation planner."

    def allocate(
        self,
        streams: int,
        aggregate_bps: float,
        per_stream_bps: list[float] | None = None,
    ) -> dict[str, Any] | None:
        """Return per-stream byte/s shares that sum to `aggregate_bps`.

        `per_stream_bps` is each stream's recent achieved rate. Streams that
        have delivered more get more; a stream that delivered nothing is held
        at a minimal trickle rather than given an equal slice it cannot use.
        """
        if streams <= 0 or aggregate_bps <= 0:
            return None

        if not per_stream_bps or len(per_stream_bps) != streams:
            shares = [aggregate_bps / streams] * streams
            self._remember({"kind": "allocate", "streams": streams, "even": True})
            return {"shares_bps": shares, "reasoning": "no per-stream data — even split",
                    "source": "local"}

        rates = [max(0.0, float(r)) for r in per_stream_bps]
        total = sum(rates)
        if total <= 0:
            shares = [aggregate_bps / streams] * streams
            return {"shares_bps": shares,
                    "reasoning": "no stream delivered anything — even split",
                    "source": "local"}

        # Proportional to delivered rate, with a floor so a slow stream still
        # makes progress instead of being starved to zero.
        floor = aggregate_bps * 0.02
        weights = [floor + r for r in rates]
        wsum = sum(weights)
        shares = [aggregate_bps * w / wsum for w in weights]

        # Absorb float drift into the largest share so the sum is exact.
        drift = aggregate_bps - sum(shares)
        if abs(drift) > 1e-9 and shares:
            top = max(range(len(shares)), key=lambda i: shares[i])
            shares[top] += drift

        spread = (max(shares) / min(shares)) if min(shares) > 0 else float("inf")
        out = {
            "shares_bps": shares,
            "reasoning": (
                f"weighted by delivered rate; slowest/fastest spread "
                f"{spread:.2f}x, sum pinned to aggregate"
            ),
            "source": "local",
        }
        self._remember({"kind": "allocate", "streams": streams, "spread": spread})
        return out


# ── 8. RootCauseClassifier ────────────────────────────────────────────────────

# Ordered by diagnostic weight: a hard failure outranks a soft signal.
_ROOT_CAUSE_RULES: list[tuple[str, str]] = [
    ("dead_link", "no bytes moved at all — the link is down or the endpoint is unreachable"),
    ("severe_loss", "packet loss above 5% dominates — retransmits are eating the throughput"),
    ("bufferbloat", "bufferbloat grade C or worse — the link queues under load and latency collapses"),
    ("high_jitter", "jitter above 30ms — delay is unstable, which stalls interactive traffic"),
    ("poor_wifi", "WiFi signal is weak or the channel is congested — the last wireless hop is the bottleneck"),
    ("dns_slow", "a public resolver beats the system default by a wide margin — name lookups are adding latency"),
    ("endpoint_issue", "endpoints failed or were rate-limited — the measurement path is suspect, not the link"),
    ("under_target", "throughput is below the requested target"),
]


@dataclass
class RootCause:
    """One ranked cause with the evidence that produced it."""
    cause: str
    severity: str = "low"
    evidence: list[str] = field(default_factory=list)
    fixes: list[str] = field(default_factory=list)
    confidence: str = "low"
    source: str = "local"

    def to_dict(self) -> dict[str, Any]:
        return {
            "cause": self.cause, "severity": self.severity,
            "evidence": self.evidence, "fixes": self.fixes,
            "confidence": self.confidence, "source": self.source,
        }


class RootCauseClassifier(_Base):
    """Answer "why is my internet slow?" from a diagnostics bundle.

    Rules fire locally and deterministically so the tool always explains
    itself; the model is consulted only to phrase and prioritise when the
    local ranking is thin or the evidence is genuinely ambiguous.
    """

    system = "You are a JSON-only network fault analyst."

    _FIXES: ClassVar[dict[str, list[str]]] = {
        "dead_link": ["Check the interface is up and the link has an IP",
                      "networksetup -listallhardwareports"],
        "severe_loss": ["Check cabling and WiFi distance from the AP",
                        "Test on Ethernet to isolate the wireless hop"],
        "bufferbloat": ["Enable SQM/fq_codel or CAKE on the router",
                        "Shape slightly below line rate, e.g. 90%"],
        "high_jitter": ["Check for 2.4GHz congestion or a busy channel",
                        "Prefer 5GHz; inspect channel width"],
        "poor_wifi": ["Move closer to the AP or reduce channel width",
                      "Check for neighbouring APs on the same channel"],
        "dns_slow": ["Set the faster resolver in System Settings > Network > DNS"],
        "endpoint_issue": ["Retry when the CDN rate limit clears",
                           "Trust a second endpoint before believing the number"],
        "under_target": ["Add parallel streams to claim more of a contended pipe",
                         "Compare single-stream vs multi-stream to size the headroom"],
    }

    def classify(self, diagnostics: dict[str, Any]) -> dict[str, Any]:
        """Rank causes from a `full_diagnostics`-shaped bundle."""
        causes = self._local_causes(diagnostics)
        self._remember({"kind": "classify", "n_causes": len(causes)})

        if provider_mod.has_provider(api_key=self.api_key) and causes:
            raw = self._ask(
                "Explain why this network is slow. Return JSON only.\n"
                "Schema: { causes: [{ cause: string, severity: string, "
                "evidence: string[], fixes: string[], confidence: string }], "
                "summary: string }\n"
                "Rules: only cite numbers present in the evidence; never "
                "invent a measurement; rank most-actionable cause first.\n"
                f"Local ranking (trustworthy, do not contradict): "
                f"{json.dumps([c.to_dict() for c in causes])}\n"
                f"Diagnostics: {json.dumps(diagnostics, default=str)[:2500]}\n",
                max_tokens=700,
            )
            parsed = self._validate_causes(raw)
            if parsed:
                return {"summary": str(raw.get("summary", ""))[:400],
                        "causes": parsed, "source": "ai"}

        return {
            "summary": f"{len(causes)} issue(s) detected",
            "causes": [c.to_dict() for c in causes],
            "source": "local",
        }

    def _local_causes(self, d: dict[str, Any]) -> list[RootCause]:
        found: list[RootCause] = []

        def add(cause: str, evidence: str, severity: str) -> None:
            found.append(RootCause(
                cause=cause, severity=severity, evidence=[evidence],
                fixes=list(self._FIXES.get(cause, [])),
                confidence="high",
            ))

        if d.get("total_bytes") == 0 or d.get("mbps", 1.0) <= 0.5:
            add("dead_link", "throughput floor — no usable data moved", "critical")

        loss = float(d.get("loss_pct", 0.0) or 0.0)
        if loss > 5.0:
            add("severe_loss", f"loss {loss:.1f}%", "high")
        elif loss > 1.0:
            add("severe_loss", f"loss {loss:.1f}% (moderate)", "medium")

        grade = str(d.get("bloat_grade", "") or "")
        if grade in GRADE_RANK and GRADE_RANK[grade] >= GRADE_RANK["B"]:
            delta = d.get("bloat_delta_ms")
            detail = (f" (+{delta} ms under load)"
                      if isinstance(delta, (int, float)) else "")
            add("bufferbloat", f"bufferbloat grade {grade}{detail}",
                "high" if GRADE_RANK[grade] >= GRADE_RANK["D"] else "medium")

        jitter = float(d.get("jitter_ms", 0.0) or 0.0)
        if jitter > 30.0:
            add("high_jitter", f"jitter {jitter:.1f} ms", "medium")

        rssi = d.get("rssi")
        if isinstance(rssi, (int, float)) and rssi < -67:
            add("poor_wifi", f"RSSI {rssi} dBm", "high" if rssi < -75 else "medium")

        best_dns = d.get("best_dns")
        sys_dns = d.get("system_dns_ms")
        best_ms = d.get("best_dns_ms")
        if (best_dns and isinstance(sys_dns, (int, float))
                and isinstance(best_ms, (int, float))
                and sys_dns - best_ms >= 20):
            add("dns_slow",
                f"{best_dns} is {sys_dns - best_ms:.0f} ms faster than system default",
                "low")

        if d.get("endpoint_problems"):
            add("endpoint_issue",
                "; ".join(str(p) for p in d["endpoint_problems"][:3]), "medium")

        target = d.get("target_mbps")
        if isinstance(target, (int, float)) and target > 0:
            got = float(d.get("mbps", 0.0) or 0.0)
            if got < target * 0.9:
                add("under_target",
                    f"{got:.1f} Mbps against a {target:g} Mbps target", "medium")

        severity_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3}
        found.sort(key=lambda c: severity_rank.get(c.severity, 9))
        return found

    def _validate_causes(self, raw: dict[str, Any] | None) -> list[dict[str, Any]] | None:
        """Keep only well-formed causes with recognised names and severities."""
        if not raw:
            return None
        items = raw.get("causes")
        if not isinstance(items, list) or not items:
            return None
        known = {name for name, _ in _ROOT_CAUSE_RULES}
        out: list[dict[str, Any]] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            cause = str(item.get("cause", ""))
            if cause not in known:
                continue           # hallucinated cause name -> drop
            severity = str(item.get("severity", "low")).lower()
            if severity not in {"critical", "high", "medium", "low"}:
                severity = "low"
            fixes = [str(f) for f in item.get("fixes", [])
                     if isinstance(f, (str, int, float))][:4]
            if not fixes:
                fixes = list(self._FIXES.get(cause, []))
            out.append({
                "cause": cause, "severity": severity,
                "evidence": [str(e) for e in item.get("evidence", [])
                             if isinstance(e, (str, int, float))][:4],
                "fixes": fixes,
                "confidence": str(item.get("confidence", "low")).lower(),
                "source": "ai",
            })
        return out or None


# ── 9. ISPBehaviorFingerprinter ───────────────────────────────────────────────

@dataclass
class ISPProfile:
    """What repeated measurements imply about the provider's network."""
    shaping_detected: bool = False
    peak_hours: list[int] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    evidence: list[str] = field(default_factory=list)
    confidence: str = "low"
    source: str = "local"

    def to_dict(self) -> dict[str, Any]:
        return {
            "shaping_detected": self.shaping_detected,
            "peak_hours": self.peak_hours, "notes": self.notes,
            "evidence": self.evidence, "confidence": self.confidence,
            "source": self.source,
        }


class ISPBehaviorFingerprinter(_Base):
    """Detect ISP shaping from a run history rather than a single test.

    Shaping shows up as a repeatable pattern — throughput that tracks the
    clock rather than the link. Requires a multi-day history to claim, and
    says so plainly when there is not enough.
    """

    system = "You are a JSON-only ISP traffic analyst."

    # A sustained drop of this fraction during evening hours counts as a
    # candidate shaping signal; one bad evening never does.
    SHAPING_DROP_RATIO = 0.25
    MIN_SAMPLES_FOR_CONFIDENCE = 12

    def fingerprint(self) -> dict[str, Any]:
        """Profile the recorded history. Needs `record_sample` calls first."""
        if not self.history:
            return {"shaping_detected": False, "notes": ["no history recorded"],
                    "evidence": [], "peak_hours": [], "confidence": "none",
                    "source": "local"}

        hours: dict[int, list[float]] = {}
        for row in self.history:
            mb = float(row.get("mbps", 0.0) or 0.0)
            hour = int(row.get("hour", row.get("ts", 0) // 3600 % 24))
            hours.setdefault(hour, []).append(mb)

        means = {h: statistics.fmean(v) for h, v in hours.items() if v}
        evidence: list[str] = []
        notes: list[str] = []

        # Busiest measured hour vs quietest — a wide gap under a quiet-hour
        # baseline suggests time-of-day shaping rather than a bad link.
        if len(means) >= 2:
            best_hour = max(means, key=lambda h: means[h])
            worst_hour = min(means, key=lambda h: means[h])
            best, worst = means[best_hour], means[worst_hour]
            if worst > 0:
                drop = (best - worst) / worst
                if drop >= self.SHAPING_DROP_RATIO:
                    evidence.append(
                        f"mean {worst:.1f} Mbps at {worst_hour:02d}:00 vs "
                        f"{best:.1f} Mbps at {best_hour:02d}:00 ({drop:+.0%})"
                    )
                    notes.append(
                        f"throughput varies {drop:+.0%} by time of day — "
                        "consistent with congestion or shaping"
                    )

        n = len(self.history)
        confidence = ("high" if n >= self.MIN_SAMPLES_FOR_CONFIDENCE * 2
                      else "medium" if n >= self.MIN_SAMPLES_FOR_CONFIDENCE
                      else "low")
        if n < self.MIN_SAMPLES_FOR_CONFIDENCE:
            notes.append(
                f"only {n} sample(s) — treat any shaping claim as provisional"
            )

        # Peak-congestion hours are the WORST throughput hours — the hours a
        # user would call "peak". Ranking these by highest Mbps would report
        # the quiet overnight hours, which is the opposite of the intent.
        peak_hours = sorted(h for h, _ in sorted(means.items(), key=lambda kv: kv[1])[:3])
        profile = ISPProfile(
            shaping_detected=bool(evidence),
            peak_hours=peak_hours, notes=notes, evidence=evidence,
            confidence=confidence,
        )

        if provider_mod.has_provider(api_key=self.api_key) and n >= self.MIN_SAMPLES_FOR_CONFIDENCE:
            raw = self._ask(
                "Assess whether this ISP shows evidence of shaping or "
                "congestion. Return JSON only.\n"
                "Schema: { shaping_detected: boolean, peak_hours: number[], "
                "notes: string[], confidence: string }\n"
                "Rule: with few samples, prefer shaping_detected false and "
                "say why. Congestion and shaping are NOT the same thing — "
                "congestion affects everyone equally, shaping is selective.\n"
                f"Local evidence: {json.dumps(profile.to_dict())}\n"
                f"Samples: {json.dumps(self.history[-40:], default=str)[:2500]}\n",
                max_tokens=400,
            )
            if raw is not None:
                detected = raw.get("shaping_detected")
                if isinstance(detected, bool):
                    profile.shaping_detected = detected
                hours = [int(h) for h in self._str_list(raw, "peak_hours")
                         if str(h).isdigit() and 0 <= int(h) <= 23]
                if hours:
                    profile.peak_hours = hours[:5]
                notes = [str(x)[:200] for x in raw.get("notes", [])
                         if isinstance(x, (str, int, float))][:5]
                if notes:
                    profile.notes = notes
                profile.confidence = str(raw.get("confidence", "low")).lower()
                profile.source = "ai"
        return profile.to_dict()

    def record_sample(self, mbps: float, hour: int | None = None) -> None:
        """Record one throughput sample; `hour` is local time 0..23."""
        if hour is None:
            hour = time.localtime().tm_hour
        self._remember({"kind": "isp", "mbps": mbps, "hour": int(hour)})


# ── 11. WiFiOptimizationAdvisor ───────────────────────────────────────────────

class WiFiOptimizationAdvisor(_Base):
    """Advise channel/band/placement from a WiFi scan reading."""

    system = "You are a JSON-only WiFiRF adviser."

    _NON_OVERLAPPING_24G: ClassVar[frozenset[int]] = frozenset({1, 6, 11})

    def advise(self, wifi: dict[str, Any]) -> dict[str, Any]:
        """Recommend concrete changes from `netmetrics.wifi_info()` output."""
        advice: list[str] = []
        evidence: list[str] = []
        rssi = wifi.get("rssi")
        noise = wifi.get("noise")
        channel = wifi.get("channel")
        snr = None
        if isinstance(rssi, (int, float)) and isinstance(noise, (int, float)):
            snr = rssi - noise

        if isinstance(snr, (int, float)):
            evidence.append(f"SNR {snr:.0f} dB (RSSI {rssi} dBm, noise {noise} dBm)")
            if snr < 15:
                advice.append("SNR is poor — move closer to the AP or add a mesh node")
            elif snr < 25:
                advice.append("SNR is usable but not clean — prefer 5GHz if in range")
        if isinstance(rssi, (int, float)) and rssi < -70:
            advice.append(f"RSSI {rssi} dBm is weak — 2.4GHz will stall under load")

        if isinstance(channel, (int, int)) and channel <= 14:
            if channel in self._NON_OVERLAPPING_24G:
                advice.append(f"channel {channel} is a clean 2.4GHz choice")
            else:
                advice.append(
                    f"channel {channel} overlaps neighbours — move to 1, 6 or 11"
                )
        elif isinstance(channel, int):
            advice.append(f"on 5GHz channel {channel}; 80MHz widens it but "
                          "increases interference risk in dense areas")

        if wifi.get("bandwidth_mhz") == 160:
            advice.append("160MHz channel width is fragile — 80MHz is more reliable")

        result = {
            "advice": advice,
            "evidence": evidence,
            "snr_db": round(snr, 1) if isinstance(snr, (int, float)) else None,
            "confidence": "high" if len(evidence) else "low",
            "source": "local",
        }
        raw = self._ask(
            "Give concrete WiFi optimisation advice. Return JSON only.\n"
            "Schema: { advice: string[], confidence: string }\n"
            "Ground every recommendation in the reading; never invent a "
            "channel number or signal value that is not given.\n"
            f"Reading: {json.dumps(wifi, default=str)}\n"
            f"Local advice: {json.dumps(advice)}\n",
            max_tokens=300,
        )
        model_advice = [str(a)[:200] for a in raw.get("advice", [])
                        if isinstance(a, (str, int, float))][:6] if raw else []
        if model_advice:
            result["advice"] = model_advice
            result["confidence"] = str(raw.get("confidence", "low")).lower()
            result["source"] = "ai"
        return result


# ── 12. DNSStrategyOptimizer ──────────────────────────────────────────────────

class DNSStrategyOptimizer(_Base):
    """Go past raw resolver latency to a usable DNS strategy.

    Latency alone is a poor guide: a resolver can be fast and still return
    stale TTLs or refuse EDNS. This reports the fastest resolver alongside
    freshness and privacy posture.
    """

    system = "You are a JSON-only DNS strategy adviser."

    def advise(self, resolvers: list[dict[str, Any]]) -> dict[str, Any] | None:
        """Rank resolvers and describe the recommended configuration."""
        rows = [r for r in resolvers
                if isinstance(r, dict) and isinstance(r.get("latency_ms"), (int, float))]
        if not rows:
            return None
        self._remember({"kind": "dns", "n": len(rows)})

        ranked = sorted(rows, key=lambda r: r["latency_ms"])
        fastest = ranked[0]
        privacy = {"Cloudflare 1.1.1.1", "Quad9 9.9.9.9"}
        encrypted = [r for r in ranked if r.get("doh") or r.get("dot")]

        notes: list[str] = []
        if fastest.get("name") in privacy:
            notes.append(
                f"{fastest['name']} is fastest ({fastest['latency_ms']:.0f} ms) "
                "and does not sell browsing data"
            )
        if len(ranked) > 1:
            spread = ranked[-1]["latency_ms"] - ranked[0]["latency_ms"]
            notes.append(f"resolver spread is {spread:.0f} ms end to end")
            if spread < 10:
                notes.append("spread is small — switching resolver will not "
                             "noticeably change page load times")
        if encrypted:
            names = ", ".join(str(r.get("name", "?")) for r in encrypted[:3])
            notes.append(f"encrypted transports available: {names}")

        out = {
            "recommended": fastest.get("name"),
            "ranking": [
                {"name": r.get("name"), "latency_ms": r.get("latency_ms")}
                for r in ranked
            ],
            "notes": notes,
            "source": "local",
        }
        raw = self._ask(
            "Recommend a DNS strategy. Return JSON only.\n"
            "Schema: { recommended: string, notes: string[], confidence: string }\n"
            "Weigh freshness and privacy alongside raw latency; a 5 ms "
            "difference is rarely worth changing resolver for.\n"
            f"Measured: {json.dumps(ranked, default=str)[:1500]}\n",
            max_tokens=300,
        )
        names = {str(r.get("name")) for r in ranked}
        pick = raw.get("recommended") if raw else None
        if pick in names:            # only trust a resolver we measured
            out["recommended"] = pick
            model_notes = [str(n)[:200] for n in raw.get("notes", [])
                           if isinstance(n, (str, int, float))][:4]
            if model_notes:
                out["notes"] = model_notes
            out["confidence"] = str(raw.get("confidence", "low")).lower()
            out["source"] = "ai"
        return out


# ── 13. PacketLossPatternRecognizer ───────────────────────────────────────────

# Mean consecutive-run length expected under independent (random) loss at
# rate p. Observed runs far above this indicate clustering, not randomness.
def _expected_random_run(p: float) -> float:
    return (1.0 - p) / p if p > 0 else float("inf")


class PacketLossPatternRecognizer(_Base):
    """Tell random loss apart from burst and periodic loss.

    The distinction decides the fix: random loss points at RF or a bad cable,
    burst loss at a queue or retransmit storm, and periodic loss at
    something on a timer — a backup, a DHCP renew, an ARP storm.
    """

    system = "You are a JSON-only packet-loss analyst."

    # Longest consecutive loss run must exceed this multiple of the run
    # length expected under independent loss before the loss counts as
    # bursty rather than random. 4x was too strict — a 7-in-a-row inside
    # 23% loss is 2.1x the independent expectation and is plainly not
    # random.
    BURST_FACTOR = 1.5
    # ...but a short run is never evidence on its own.
    BURST_MIN_RUN = 4
    # Coefficient of variation below this on the inter-loss spacing means
    # the losses land on a clock rather than by chance.
    PERIODIC_CV = 0.15

    def classify(self, events: list[dict[str, Any]]) -> dict[str, Any]:
        """Classify loss from `[{index, lost: bool, ts?}, ...]` samples."""
        if not events:
            return {"pattern": "unknown", "loss_pct": 0.0, "confidence": "none",
                    "evidence": [], "source": "local", "fixes": []}

        lost_idx = [i for i, e in enumerate(events) if e.get("lost")]
        n = len(events)
        loss_pct = len(lost_idx) / n * 100.0
        evidence = [f"{len(lost_idx)}/{n} samples lost ({loss_pct:.1f}%)"]

        if not lost_idx:
            return {"pattern": "none", "loss_pct": 0.0, "confidence": "high",
                    "evidence": evidence, "source": "local",
                    "fixes": ["no loss observed in this window"]}

        # Longest run of consecutive losses. Iterating sample positions (not
        # the lost-index list) keeps the contiguity test exact.
        longest = current = 0
        previous_lost_at = -2
        for index, event in enumerate(events):
            if not event.get("lost"):
                continue
            current = current + 1 if index == previous_lost_at + 1 else 1
            longest = max(longest, current)
            previous_lost_at = index
        evidence.append(f"longest consecutive loss run: {longest}")

        # Inter-arrival spacing from timestamps, if provided.
        gaps: list[float] = []
        stamps = [e.get("ts") for e in events if e.get("ts") is not None]
        for a, b in zip(stamps, stamps[1:]):
            gaps.append(float(b) - float(a))

        p = loss_pct / 100.0
        expected_run = _expected_random_run(p)

        pattern = "random"
        confidence = "medium"
        if longest >= max(float(self.BURST_MIN_RUN),
                          expected_run * self.BURST_FACTOR):
            pattern, confidence = "burst", "high"
            evidence.append(
                f"run of {longest} vs {expected_run:.1f} expected under "
                f"independent {loss_pct:.1f}% loss"
            )
        elif gaps:
            mean_gap = statistics.fmean(gaps)
            if mean_gap > 0:
                spread = (statistics.pstdev(gaps) / mean_gap
                          if len(gaps) > 1 and mean_gap else 0.0)
                evidence.append(
                    f"mean spacing {mean_gap:.2f}s, coefficient of variation {spread:.2f}"
                )
                # Timestamps that land on a near-constant cadence are periodic.
                if len(gaps) > 2 and spread < self.PERIODIC_CV:
                    pattern, confidence = "periodic", "high"
                    evidence.append(f"loss recurs on a ~{mean_gap:.1f}s timer")

        out = {
            "pattern": pattern, "loss_pct": round(loss_pct, 2),
            "evidence": evidence, "confidence": confidence,
            "source": "local",
            "fixes": _LOSS_FIXES.get(pattern, []),
        }
        raw = self._ask(
            "Classify this packet-loss pattern. Return JSON only.\n"
            "Schema: { pattern: string, reasoning: string, fixes: string[], "
            "confidence: string }\n"
            "pattern must be one of: random, burst, periodic.\n"
            "Each pattern has a different fix — do not blur them.\n"
            f"Local analysis: {json.dumps(out)}\n",
            max_tokens=300,
        )
        model_pattern = str(raw.get("pattern", "")) if raw else ""
        if model_pattern in {"random", "burst", "periodic"}:
            fixes = [str(f)[:200] for f in raw.get("fixes", [])
                     if isinstance(f, (str, int, float))][:4]
            out.update({
                "pattern": model_pattern,
                "reasoning": str(raw.get("reasoning", ""))[:300],
                "fixes": fixes or _LOSS_FIXES.get(model_pattern, []),
                "confidence": str(raw.get("confidence", "low")).lower(),
                "source": "ai",
            })
        return out


_LOSS_FIXES = {
    "random": ["Check cabling and WiFi distance from the AP",
               "Test on Ethernet to isolate the wireless hop"],
    "burst": ["Look for a queue or retransmit storm — check bufferbloat",
              "Inspect router CPU during the loss window"],
    "periodic": ["Find the timer: DHCP renew, backup job, or ARP storm",
                 "Correlate the period with scheduled jobs on the LAN"],
}


# ── 14. JitterSourceAttributor ────────────────────────────────────────────────

class JitterSourceAttributor(_Base):
    """Split observed jitter into per-layer contributions.

    Each hop contributes independently, so the biggest one is where the fix
    lives. Probes are aggregated locally; the model phrases the conclusion.
    """

    system = "You are a JSON-only latency analyst."

    def attribute(
        self,
        gateway_ms: float | None,
        internet_ms: float | None,
        endpoint_ms: float | None = None,
    ) -> dict[str, Any]:
        """Attribute jitter across local / ISP / endpoint hops.

        `gateway_ms` and `internet_ms` are median RTTS to the LAN gateway and
        to a public host. Each is treated as an upper bound on the jitter
        contributed by the hops below it.
        """
        hops: list[dict[str, Any]] = []
        if isinstance(gateway_ms, (int, float)):
            hops.append({"hop": "local_wifi", "rtt_ms": gateway_ms})
        if isinstance(internet_ms, (int, float)):
            hops.append({"hop": "isp_path", "rtt_ms": internet_ms})
        if isinstance(endpoint_ms, (int, float)):
            hops.append({"hop": "endpoint", "rtt_ms": endpoint_ms})
        if not hops:
            return {"dominant": "unknown", "hops": [], "source": "local",
                    "confidence": "none"}

        # Marginal contribution: a hop's own jitter is bounded by the
        # difference between it and the hop above it.
        hops.sort(key=lambda h: h["rtt_ms"])
        for prev, cur in zip(hops, hops[1:]):
            cur["marginal_ms"] = max(0.0, cur["rtt_ms"] - prev["rtt_ms"])
        hops[0]["marginal_ms"] = float(hops[0]["rtt_ms"])

        dominant = max(hops, key=lambda h: h["marginal_ms"])
        total = max(1e-9, float(hops[-1]["rtt_ms"]))
        for h in hops:
            h["share"] = round(h["marginal_ms"] / total, 3)

        advice = {
            "local_wifi": "Fix the wireless hop first — channel, band, placement",
            "isp_path": "The ISP path dominates — SQM on the router, or report it",
            "endpoint": "Only the endpoint is jittery — try a different mirror",
        }.get(dominant["hop"], "Re-measure with more samples")

        out = {
            "dominant": dominant["hop"],
            "dominant_share": dominant["share"],
            "hops": hops,
            "advice": advice,
            "confidence": "medium" if len(hops) > 1 else "low",
            "source": "local",
        }
        raw = self._ask(
            "Explain this jitter attribution. Return JSON only.\n"
            "Schema: { dominant: string, advice: string, confidence: string }\n"
            "dominant must be one of the hop names already present.\n"
            f"Measured: {json.dumps(out, default=str)}\n",
            max_tokens=250,
        )
        pick = str(raw.get("dominant", "")) if raw else ""
        allowed = {h["hop"] for h in hops}
        if pick in allowed:
            out["dominant"] = pick
            out["advice"] = str(raw.get("advice", advice))[:300]
            out["confidence"] = str(raw.get("confidence", "low")).lower()
            out["source"] = "ai"
        return out


# ── 15. NaturalLanguageCLI ────────────────────────────────────────────────────

_DURATION_UNITS = {
    "second": 1, "seconds": 1, "sec": 1, "secs": 1, "s": 1,
    "minute": 60, "minutes": 60, "min": 60, "mins": 60, "m": 60,
    "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600, "h": 3600,
}

_DURATION_WORDS = {
    "a minute": 60, "an hour": 3600, "half an hour": 1800,
    "forever": 21_600, "all day": 21_600,
}


class NaturalLanguageCLI(_Base):
    """Turn a plain request into a runnable netmax argv.

    Deterministic parsing first — a regex handles the common phrasings
    without a network call. The model is used only for the shapes regex
    cannot reach, and its output is restricted to the allow-listed commands
    and validated ranges, never executed blindly.
    """

    system = "You are a JSON-only command translator for a CLI."

    # Commands the translator is permitted to emit.
    ALLOWED_COMMANDS: ClassVar[frozenset[str]] = frozenset({
        "baseline", "turbo", "boost", "dns", "bloat", "bloat-eco",
        "upload", "loss", "jitter", "wifi", "full", "limit", "export",
    })
    DURATION_MIN_S = 5
    DURATION_MAX_S = 21_600

    def parse(self, text: str) -> dict[str, Any]:
        """Return `{argv, reasoning, confidence, source}` or `{error: ...}`."""
        raw = (text or "").strip()
        if not raw:
            return {"error": "empty request", "source": "local"}

        argv = self._regex_parse(raw)
        if argv is not None:
            return {"argv": argv, "reasoning": "matched a known phrasing",
                    "confidence": "high", "source": "local"}

        if not provider_mod.has_provider(api_key=self.api_key):
            return {"error": "could not parse that offline — set NETMAX_AI_API_KEY "
                             "or use the explicit flags (see --help)",
                    "source": "local"}

        raw_reply = self._ask(
            "Translate this request into netmax CLI arguments. Return JSON "
            "only.\n"
            "Schema: { command: string, mbps: number, streams: number, "
            "seconds: number, reasoning: string }\n"
            f"Allowed commands: {sorted(self.ALLOWED_COMMANDS)}\n"
            f"mbps range 0.5..10000, streams 1..50, seconds "
            f"{self.DURATION_MIN_S}..{self.DURATION_MAX_S}.\n"
            "Omit a field the request does not mention.\n"
            f"Request: {raw}\n",
            max_tokens=250,
        )
        if raw_reply is None:
            return {"error": "model unavailable and no known phrasing matched",
                    "source": "local"}

        cmd = str(raw_reply.get("command", "")).strip()
        if cmd not in self.ALLOWED_COMMANDS:
            return {"error": f"refused unrecognised command {cmd!r}",
                    "source": "ai"}

        argv = [cmd]
        if cmd == "limit":
            mbps = self._first_float(raw_reply, "mbps")
            if mbps is None:
                return {"error": "a speed limit needs a Mbps value",
                        "source": "ai"}
            argv += ["--mbps", str(self._clamp(mbps, 0.5, 10_000.0))]
        streams = self._first_float(raw_reply, "streams")
        if streams is not None:
            argv += ["--streams", str(int(self._clamp(streams, 1, 50)))]
        seconds = self._first_float(raw_reply, "seconds")
        if seconds is not None:
            argv += ["--seconds",
                     str(int(self._clamp(seconds, self.DURATION_MIN_S,
                                          self.DURATION_MAX_S)))]
        return {"argv": argv,
                "reasoning": str(raw_reply.get("reasoning", ""))[:300],
                "confidence": str(raw_reply.get("confidence", "low")).lower(),
                "source": "ai"}

    def _regex_parse(self, text: str) -> list[str] | None:
        """Handle the phrasings we can match without a model."""
        low = text.lower()

        seconds = self._extract_duration(low)

        mbps = None
        m = re.search(r"(\d+(?:\.\d+)?)\s*mbps", low)
        if m:
            mbps = float(m.group(1))
        elif re.search(r"\b(limit|cap|hold|throttle|restrict)\w*\b", low):
            m = re.search(r"(\d+(?:\.\d+)?)\s*(?:g|gbps)", low)
            if m:
                mbps = float(m.group(1)) * 1000.0

        if mbps is not None:
            if not 0.5 <= mbps <= 10_000.0:
                return None
            argv = ["limit", "--mbps", f"{mbps:g}"]
            if seconds is not None:
                argv += ["--seconds", str(seconds)]
            return argv

        if re.search(r"\bbufferbloat\b|\bbloat\b", low):
            argv = ["bloat"]
        elif re.search(r"\bdns\b|\bresolver\b", low):
            argv = ["dns"]
        elif re.search(r"\bwifi\b|\bwireless\b|\bsignal\b", low):
            argv = ["wifi"]
        elif re.search(r"\bjitter\b", low):
            argv = ["jitter"]
        elif re.search(r"\bloss\b|\bpacket loss\b", low):
            argv = ["loss"]
        elif re.search(r"\bupload\b", low):
            argv = ["upload"]
        elif re.search(r"\bboost\b|\bheadroom\b", low):
            argv = ["boost"]
        elif re.search(r"\bturbo\b|\bparallel\b", low):
            argv = ["turbo"]
        elif re.search(r"\bfull\b|\beverything\b|\ball\b|\bdiagnos", low):
            argv = ["full"]
        elif re.search(r"\bbaseline\b|\bspeed\b|\bthroughput\b|\btest\b", low):
            argv = ["baseline"]
        else:
            return None

        if seconds is not None and argv[0] in {
                "baseline", "turbo", "boost", "bloat", "full", "upload"}:
            argv += ["--seconds", str(seconds)]
        return argv

    def _extract_duration(self, low: str) -> int | None:
        """Find a duration in seconds, or None."""
        for phrase, secs in _DURATION_WORDS.items():
            if phrase in low:
                return min(self.DURATION_MAX_S, secs)

        m = re.search(r"(\d+(?:\.\d+)?)\s*(second|seconds|sec|secs|s|"
                      r"minute|minutes|min|mins|m|hour|hours|hr|hrs|h)\b",
                      low)
        if not m:
            return None
        try:
            value = float(m.group(1))
        except ValueError:
            return None
        unit = _DURATION_UNITS.get(m.group(2))
        if unit is None:
            return None
        total = int(value * unit)
        return max(self.DURATION_MIN_S, min(self.DURATION_MAX_S, total))
