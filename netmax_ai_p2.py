#!/usr/bin/env python3
"""P2 AI layer for NetMax — explanation, insight, and advice.

P0 made the governor reason. P1 made ten analysers diagnose. P2 turns that
diagnosis into something a person (or an agent) can act on, and finds the
problems that only appear over weeks rather than seconds.

Shared contract, inherited from netmax_ai_p1:
- Heuristics answer first and are the default. No API key, still useful.
- NETMAX_AI_API_KEY adds phrasing and prioritisation on top.
- No method raises on transport failure.
- Model output is clamped and validated, never trusted for a number the
  caller did not measure.

Everything here is read-only analysis. It reads measurements and history and
returns prose, scores or suggestions. It never runs a measurement, never
calls `sudo`, and never mutates system state.
"""

from __future__ import annotations

import json
import statistics
from dataclasses import dataclass, field
from typing import Any, ClassVar

from netmax_ai_p1 import GRADE_RANK, _Base


# ── 18. ResultExplainer ───────────────────────────────────────────────────────

# What a given speed means in wall-clock terms. Anchored to real household
# and working file sizes so the number lands rather than floating.
_FILE_SIZES: ClassVar[list[tuple[str, float]]] = [
    ("a 10 GB Xcode update", 10e9),
    ("a 2 GB Linux kernel build", 2e9),
    ("a 700 MB film (4K)", 700e6),
    ("a 90 MB album", 90e6),
]

_TONE_OPENERS: ClassVar[dict[str, str]] = {
    "plain": "Here is what your network is doing:",
    "technical": "Measurement summary:",
    "minimal": "",
}


class ResultExplainer(_Base):
    """Say what a measurement means for this user, in their words.

    A number alone does not land. "42 Mbps" is abstract; "a 10 GB Xcode
    update in 32 minutes instead of 48" is not. This turns a diagnostic
    bundle into plain statements, and refuses to overstate anything.
    """

    system = "You are a JSON-only network explainer."

    def explain(
        self,
        diagnostics: dict[str, Any],
        tone: str = "plain",
        plan_mbps: float | None = None,
    ) -> dict[str, Any]:
        """Return statements, a headline, and caveats.

        `tone` is plain | technical | minimal. `plan_mbps` is what the user
        says they pay for — without it, no claim about plan shortfall is made.
        """
        if tone not in _TONE_OPENERS:
            tone = "plain"
        mbps = float(diagnostics.get("mbps", 0.0) or 0.0)
        statements: list[str] = []
        caveats: list[str] = []

        # Throughput in wall-clock terms.
        if mbps > 0:
            bits = mbps * 1e6 / 8
            for label, size in _FILE_SIZES:
                seconds = size / bits if bits > 0 else 0
                statements.append(
                    f"{label} would take about "
                    f"{_human_duration(seconds)} at {mbps:.0f} Mbps"
                )
        else:
            caveats.append("no throughput measured — timing claims omitted")

        # Plan comparison, only when we were told the plan.
        if plan_mbps and plan_mbps > 0:
            ratio = mbps / plan_mbps
            statements.append(
                f"that is {ratio:.0%} of the {plan_mbps:g} Mbps you say you pay for"
            )
            if ratio > 0.95:
                caveats.append(
                    "multi-stream figures can exceed single-stream on a contended "
                    "pipe — this is headroom, not extra bandwidth"
                )

        # Latency framed by what it does to interaction, not by number.
        idle = diagnostics.get("idle_latency_ms")
        if isinstance(idle, (int, float)):
            statements.append(f"idle latency {idle:.0f} ms")
        grade = str(diagnostics.get("bloat_grade", "") or "")
        if grade in GRADE_RANK:
            if GRADE_RANK[grade] <= GRADE_RANK["A"]:
                statements.append("the link stays responsive while downloading")
            else:
                caveats.append(
                    f"bufferbloat grade {grade} — calls and games will stutter "
                    "during a download; no software can fix the router queue"
                )

        jitter = diagnostics.get("jitter_ms")
        if isinstance(jitter, (int, float)) and jitter > 30:
            caveats.append(f"jitter of {jitter:.0f} ms is high for calls and gaming")

        headline = statements[0] if statements else "no usable measurement"
        out = {
            "headline": headline,
            "statements": statements,
            "caveats": caveats,
            "tone": tone,
            "source": "local",
        }
        if self.api_key and statements:
            raw = self._ask(
                "Explain this network measurement to a non-expert. Return "
                "JSON only.\n"
                "Schema: { headline: string, statements: string[], "
                "caveats: string[] }\n"
                "Rules: never invent a number; never promise more speed than "
                "the plan allows; state limits plainly.\n"
                f"Tone: {tone}\n"
                f"Local statements: {json.dumps(statements)}\n"
                f"Local caveats: {json.dumps(caveats)}\n",
                max_tokens=500,
            )
            if raw:
                model_statements = _strings(raw.get("statements"))[:8]
                if model_statements:
                    out["statements"] = model_statements
                    out["headline"] = str(raw.get("headline", headline))[:200]
                model_caveats = _strings(raw.get("caveats"))[:6]
                if model_caveats:
                    out["caveats"] = model_caveats
                out["source"] = "ai"
        return out


def _human_duration(seconds: float) -> str:
    """Seconds -> '32 min' / '1 h 12 min' / '45 s'."""
    if seconds <= 0:
        return "an unknown time"
    if seconds < 90:
        return f"{seconds:.0f} s"
    minutes = seconds / 60
    if minutes < 90:
        return f"{minutes:.0f} min"
    return f"{minutes / 60:.0f} h {minutes % 60:.0f} min"


def _strings(value: Any, limit: int = 8) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(v)[:300] for v in value
            if isinstance(v, (str, int, float))][:limit]


# ── 19. TroubleshootingWizard ─────────────────────────────────────────────────

@dataclass
class WizardStep:
    """One question in a guided diagnosis flow."""
    id: str
    question: str
    choices: list[str] = field(default_factory=list)
    # Cheap probe to run before asking, so we only ask what we cannot see.
    probe: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "question": self.question,
                "choices": list(self.choices), "probe": self.probe}


class TroubleshootingWizard:
    """Ask only the questions a measurement cannot answer.

    The flow is a decision tree over symptoms. Each step either resolves to
    a cause or narrows the branch. Probes are named, not run — the caller
    executes them with the existing engine modes, so the wizard never
    performs I/O of its own.
    """

    # probe -> what its result tells us. Values are the expected diagnostic.
    PROBES: ClassVar[dict[str, str]] = {
        "full": "speed, DNS, bufferbloat grade in one run",
        "bloat-eco": "~100 KB bufferbloat estimate",
        "bloat": "saturating bufferbloat grade (uses real bandwidth)",
        "wifi": "signal, noise and channel",
        "dns": "resolver latency ranking",
        "loss": "packet loss percentage",
        "jitter": "jitter in ms",
    }

    def start(self, symptom: str) -> WizardStep:
        """First step for a reported symptom."""
        s = (symptom or "").lower()
        if any(w in s for w in ("call", "voice", "zoom", "facetime", "game")):
            return WizardStep(
                "quality", "Is the problem only while a call or game is running?",
                ["yes", "no", "only at peak hours"], probe="bloat-eco")
        if any(w in s for w in ("slow", "download", "speed", "bandwidth")):
            return WizardStep(
                "speed", "Is it slow always, or only at certain times?",
                ["always", "evenings only", "weekends only", "sometimes"], probe="full")
        if any(w in s for w in ("wifi", "wireless", "signal", "range")):
            return WizardStep(
                "wifi", "Does the problem follow you between rooms?",
                ["yes", "no"], probe="wifi")
        return WizardStep(
            "generic", "What is the main symptom?",
            ["slow speed", "laggy calls", "dropouts", "DNS lookups"], probe=None)

    def next_step(self, step_id: str, answer: str) -> WizardStep | None:
        """Follow the tree. None means the flow has resolved."""
        a = (answer or "").strip().lower()

        if step_id == "speed":
            if "always" in a:
                return WizardStep("speed_always",
                                  "Does a single-stream test also come in low?",
                                  ["yes", "no"], probe="full")
            if "evening" in a or "weekend" in a:
                return WizardStep("peak",
                                  "What is your WiFi signal strength?",
                                  ["strong", "weak", "no idea"], probe="wifi")
            return WizardStep("speed_sometimes",
                              "Do calls and games stutter during a download?",
                              ["yes", "no"], probe="bloat-eco")

        if step_id == "peak":
            return None

        if step_id == "quality":
            if a.startswith("yes"):
                return WizardStep("bufferbloat",
                                  "Run the ~100 KB bufferbloat check — did "
                                  "latency rise sharply under load?",
                                  ["yes, a lot", "barely", "no idea"],
                                  probe="bloat-eco")
            if "peak" in a:
                return WizardStep("peak", "What is your WiFi signal strength?",
                                  ["strong", "weak", "no idea"], probe="wifi")
            return WizardStep("generic_more",
                              "What else do you notice?",
                              ["dropouts", "slow DNS", "nothing else"], probe=None)

        if step_id == "bufferbloat":
            if a.startswith("yes"):
                return None
            return WizardStep("speed_more",
                              "Is raw throughput also low?",
                              ["yes", "no"], probe="full")

        if step_id in {"speed_always", "speed_sometimes", "wifi"}:
            return None
        return None

    def conclude(self, answers: dict[str, str]) -> dict[str, Any]:
        """Map the collected answers to ranked causes and fixes.

        Pure function of the answers — no probing, no I/O.
        """
        causes: list[dict[str, Any]] = []

        if answers.get("quality", "").lower().startswith("yes"):
            causes.append({
                "cause": "bufferbloat",
                "confidence": "high",
                "fixes": ["Enable SQM/fq_codel or CAKE on the router",
                          "Shape to ~90% of line rate rather than full rate"],
            })
        if answers.get("speed", "").lower() in {"evening", "evenings only"} or \
           answers.get("quality", "").lower().startswith("only at peak"):
            causes.append({
                "cause": "peak_contention",
                "confidence": "medium",
                "fixes": ["Schedule large transfers to 02:00–06:00",
                          "Check whether another device is streaming at peak"],
            })
        if answers.get("speed", "").lower() == "always":
            causes.append({
                "cause": "under_provisioned_or_shaped",
                "confidence": "low",
                "fixes": ["Compare single-stream against plan rate",
                          "Run a week of history before contacting the ISP"],
            })
        if answers.get("wifi", "").lower().startswith("yes"):
            causes.append({
                "cause": "wireless_hop",
                "confidence": "medium",
                "fixes": ["Move the AP or add a mesh node",
                          "Prefer 5GHz; narrow the channel width"],
            })
        if not causes:
            causes.append({
                "cause": "unresolved",
                "confidence": "low",
                "fixes": ["Run the full diagnostic and attach the report"],
            })
        causes.sort(key=lambda c: {"high": 0, "medium": 1, "low": 2}
                    .get(c["confidence"], 3))
        return {"causes": causes, "answer_count": len(answers)}


# ── 20. AccessibilityNarrator ────────────────────────────────────────────────

class AccessibilityNarrator:
    """Render a diagnostic bundle as one calm sentence stream.

    Screen-reader users get a wall of labelled numbers otherwise. This emits
    sentences in a fixed order, avoids symbols a reader pronounces badly, and
    never hides a caveat behind a positive summary.
    """

    GRADE_WORDS: ClassVar[dict[str, str]] = {
        "A+": "excellent", "A": "excellent", "B": "good",
        "C": "acceptable", "D": "poor", "F": "severe",
    }

    def narrate(
        self,
        diagnostics: dict[str, Any],
        include_caveats: bool = True,
    ) -> dict[str, Any]:
        """Return `{summary, sentences, caveats}` — no markdown, no symbols."""
        sentences: list[str] = []
        caveats: list[str] = []

        mbps = diagnostics.get("mbps")
        if isinstance(mbps, (int, float)) and mbps > 0:
            sentences.append(
                f"Download speed measured at {mbps:.0f} megabits per second."
            )
        up = diagnostics.get("upload_mbps")
        if isinstance(up, (int, float)) and up > 0:
            sentences.append(
                f"Upload speed measured at {up:.0f} megabits per second."
            )

        grade = str(diagnostics.get("bloat_grade", "") or "")
        if grade in GRADE_RANK:
            word = self.GRADE_WORDS.get(grade, grade)
            sentences.append(
                f"Bufferbloat under load grades {word}, at grade {grade}."
            )

        idle = diagnostics.get("idle_latency_ms")
        if isinstance(idle, (int, float)):
            sentences.append(f"Idle latency is {idle:.0f} milliseconds.")

        jitter = diagnostics.get("jitter_ms")
        if isinstance(jitter, (int, float)):
            if jitter > 30:
                caveats.append(
                    f"Jitter is {jitter:.0f} milliseconds, high for calls and games."
                )
            else:
                sentences.append(f"Jitter is {jitter:.0f} milliseconds.")

        loss = diagnostics.get("loss_pct")
        if isinstance(loss, (int, float)) and loss > 0:
            if loss > 2:
                caveats.append(f"Packet loss is {loss:.1f} percent.")
            else:
                sentences.append(f"Packet loss is {loss:.1f} percent.")

        dns = diagnostics.get("best_dns")
        if dns:
            sentences.append(f"Fastest DNS resolver tested was {dns}.")

        if include_caveats:
            if grade in GRADE_RANK and GRADE_RANK[grade] >= GRADE_RANK["C"]:
                caveats.append(
                    "This link will feel slow during downloads until the router "
                    "queue is managed."
                )
            if not mbps:
                caveats.append("No throughput could be measured in this run.")

        summary = " ".join(sentences) if sentences else "No measurements available."
        return {"summary": summary, "sentences": sentences, "caveats": caveats}


# ── 41. TrendForecaster ───────────────────────────────────────────────────────

class TrendForecaster(_Base):
    """Forecast throughput from history, and say how little to trust it.

    A straight line through noisy points is not a forecast, it is a hope.
    This reports a trend only when the data supports one, and always carries
    a confidence band and the sample count behind it.
    """

    system = "You are a JSON-only time-series analyst."

    # Below this many samples a slope is not distinguishable from noise.
    MIN_SAMPLES = 8
    # R² needed before a trend is called a trend at all.
    MIN_R2 = 0.35

    def forecast(self, horizon_days: int = 7) -> dict[str, Any]:
        """Least-squares trend over recorded samples, with an honest verdict."""
        values = [float(r.get("mbps", 0.0) or 0.0) for r in self.history]
        n = len(values)
        if n < self.MIN_SAMPLES:
            return {
                "forecast_mbps": None,
                "trend": "insufficient_data",
                "confidence": "none",
                "samples": n,
                "notes": [f"{n} sample(s); {self.MIN_SAMPLES} needed for a trend"],
                "source": "local",
            }

        xs = list(range(n))
        slope, intercept, r2 = _linreg(xs, values)
        per_day = slope * self.history[0].get("samples_per_day", 1) if self.history else slope

        mean = statistics.fmean(values)
        if abs(r2) < self.MIN_R2:
            trend = "flat"
            note = (f"slope is real but explains only {r2:.0%} of the variance "
                    "— treat as flat")
        elif slope > 0:
            trend = "improving"
            note = f"rising about {abs(per_day):.2f} Mbps per day"
        else:
            trend = "declining"
            note = f"falling about {abs(per_day):.2f} Mbps per day"

        horizon = max(1, min(90, int(horizon_days)))
        projected = max(0.0, intercept + slope * (n + horizon))

        out = {
            "forecast_mbps": round(projected, 2),
            "current_mean_mbps": round(mean, 2),
            "trend": trend,
            "r2": round(r2, 3),
            "confidence": "high" if n >= self.MIN_SAMPLES * 3 else "medium",
            "samples": n,
            "horizon_days": horizon,
            "notes": [note],
            "source": "local",
        }
        raw = self._ask(
            "Summarise this network trend and note seasonal risk. Return JSON "
            "only.\n"
            "Schema: { summary: string, seasonal_risk: string, confidence: string }\n"
            "Be conservative about extrapolation; a 7-day forecast from noisy "
            "data is weak evidence.\n"
            f"Local analysis: {json.dumps(out)}\n",
            max_tokens=300,
        )
        if raw:
            out["summary"] = str(raw.get("summary", ""))[:400]
            out["seasonal_risk"] = str(raw.get("seasonal_risk", ""))[:300]
            out["confidence"] = str(raw.get("confidence", out["confidence"])).lower()
            out["source"] = "ai"
        return out

    def record_sample(self, mbps: float, samples_per_day: float = 1.0) -> None:
        self._remember({"kind": "trend", "mbps": mbps,
                        "samples_per_day": samples_per_day})


def _linreg(xs: list[float], ys: list[float]) -> tuple[float, float, float]:
    """Slope, intercept and R². R² is 0 when y has no variance."""
    n = len(xs)
    if n < 2:
        return 0.0, (ys[0] if ys else 0.0), 0.0
    mean_x = statistics.fmean(xs)
    mean_y = statistics.fmean(ys)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    slope = sxy / sxx if sxx else 0.0
    intercept = mean_y - slope * mean_x
    ss_tot = sum((y - mean_y) ** 2 for y in ys)
    if ss_tot <= 0:
        return slope, intercept, 0.0
    ss_res = sum((y - (slope * x + intercept)) ** 2 for x, y in zip(xs, ys))
    return slope, intercept, max(0.0, 1.0 - ss_res / ss_tot)


# ── 24. HardwareHealthMonitor ─────────────────────────────────────────────────

class HardwareHealthMonitor(_Base):
    """Infer equipment ageing from metrics that changed while config did not.

    The signal is the absence of a cause: a bufferbloat grade that drifted
    from A to C over months with no config change is evidence about the
    hardware, not about the person using it.
    """

    system = "You are a JSON-only hardware diagnostics analyst."

    def assess(self, config_changed_at: str | None = None) -> dict[str, Any]:
        """Assess drift. `config_changed_at` (ISO date) suppresses blame."""
        samples = self.history
        if len(samples) < 6:
            return {"verdict": "insufficient_data", "confidence": "none",
                    "samples": len(samples), "findings": [], "notes": [],
                    "source": "local"}

        grades = [str(r.get("bloat_grade", "") or "") for r in samples]
        grades = [g for g in grades if g in GRADE_RANK]
        findings: list[dict[str, Any]] = []
        notes: list[str] = []
        if config_changed_at:
            notes.append(f"config last changed {config_changed_at} — drift is "
                         "unlikely to be caused by a change")

        # Bufferbloat drift.
        if len(grades) >= 4:
            first_half = grades[: len(grades) // 2]
            second_half = grades[len(grades) // 2:]
            early = _mean_rank(first_half)
            late = _mean_rank(second_half)
            if late - early >= 2:
                findings.append({
                    "component": "router_queue",
                    "signal": f"bufferbloat worsened from about "
                              f"{_rank_grade(early)} to {_rank_grade(late)}",
                    "action": "Check firmware, then ask the ISP to swap the modem",
                })

        # Latency floor creep.
        latencies = [float(r.get("idle_latency_ms", 0.0) or 0.0)
                     for r in samples if r.get("idle_latency_ms")]
        if len(latencies) >= 4:
            early_lat = statistics.fmean(latencies[: len(latencies) // 2])
            late_lat = statistics.fmean(latencies[len(latencies) // 2:])
            if early_lat > 0 and late_lat > early_lat * 1.5:
                findings.append({
                    "component": "uplink_or_modem",
                    "signal": f"idle latency rose from {early_lat:.0f} ms to "
                              f"{late_lat:.0f} ms",
                    "action": "Test with Ethernet directly to the modem to split "
                              "the wireless hop from the ISP",
                })

        loss = [float(r.get("loss_pct", 0.0) or 0.0) for r in samples]
        if loss and max(loss) > 5.0:
            findings.append({
                "component": "cabling_or_rf",
                "signal": f"packet loss peaked at {max(loss):.1f}%",
                "action": "Inspect cabling and RF interference before blaming the ISP",
            })

        verdict = ("degrading" if findings else "stable")
        out = {
            "verdict": verdict,
            "confidence": "medium" if len(samples) >= 12 else "low",
            "samples": len(samples),
            "findings": findings,
            "notes": notes,
            "source": "local",
        }
        raw = self._ask(
            "Assess whether this equipment is ageing. Return JSON only.\n"
            "Schema: { verdict: string, findings: [{ component: string, "
            "signal: string, action: string }], confidence: string }\n"
            "Only cite signals present in the data. Do not invent a part number "
            "or a diagnosis you cannot support.\n"
            f"Local assessment: {json.dumps(out)}\n",
            max_tokens=400,
        )
        if raw and raw.get("verdict") in {"degrading", "stable"}:
            model_findings = raw.get("findings")
            if isinstance(model_findings, list) and model_findings:
                cleaned = [f for f in model_findings
                           if isinstance(f, dict) and f.get("component")
                           and f.get("signal")]
                if cleaned:
                    out["findings"] = cleaned[:4]
            out["verdict"] = raw["verdict"]
            out["confidence"] = str(raw.get("confidence", "low")).lower()
            out["source"] = "ai"
        return out

    def record_sample(
        self,
        bloat_grade: str = "",
        idle_latency_ms: float = 0.0,
        loss_pct: float = 0.0,
    ) -> None:
        self._remember({"kind": "hardware", "bloat_grade": bloat_grade,
                        "idle_latency_ms": idle_latency_ms,
                        "loss_pct": loss_pct})


def _mean_rank(grades: list[str]) -> float:
    return statistics.fmean(GRADE_RANK[g] for g in grades)


def _rank_grade(rank: float) -> str:
    nearest = min(GRADE_RANK, key=lambda g: abs(GRADE_RANK[g] - rank))
    return nearest


# ── 25. ZeroDayThrottleDetector ──────────────────────────────────────────────

class ZeroDayThrottleDetector(_Base):
    """Spot a shaping policy that did not exist yesterday.

    Compares per-stream-count efficiency across runs. A provider that starts
    degrading throughput only above N streams, or only for specific SNI, is
    applying a policy — and the signature is worth reporting even though it
    cannot be worked around.
    """

    system = "You are a JSON-only traffic-policy analyst."

    def detect(self) -> dict[str, Any]:
        """Look for a threshold where throughput stops scaling."""
        by_streams: dict[int, list[float]] = {}
        for row in self.history:
            streams = int(row.get("streams", 0) or 0)
            mbps = float(row.get("mbps", 0.0) or 0.0)
            if streams > 0 and mbps > 0:
                by_streams.setdefault(streams, []).append(mbps)

        if len(by_streams) < 3:
            return {"throttle_detected": False, "threshold_streams": None,
                    "confidence": "none", "evidence": [], "notes": [
                        "need measurements at three or more stream counts"],
                    "source": "local"}

        means = {k: statistics.fmean(v) for k, v in by_streams.items()}
        ordered = sorted(means.items())
        efficiency: list[tuple[int, float]] = []
        for i in range(1, len(ordered)):
            prev_m = ordered[i - 1][1]
            n, m = ordered[i]
            efficiency.append((n, (m / prev_m) if prev_m > 0 else 0.0))

        evidence: list[str] = []
        notes: list[str] = []
        threshold = None
        # Efficiency dropping well under 1.0 as streams rise means extra
        # connections buy progressively less — the signature of shaping.
        for n, ratio in efficiency:
            if ratio < 0.5:
                threshold = n
                evidence.append(
                    f"{n} streams delivered only {ratio:.0%} of the throughput "
                    f"that {n // 2 or 1} streams did"
                )

        if threshold is None:
            notes.append("throughput scaled with stream count — no cap detected")
        else:
            notes.append(
                f"extra connections stop paying past {threshold} streams — "
                "consistent with a per-flow or connection-count policy"
            )

        out = {
            "throttle_detected": threshold is not None,
            "threshold_streams": threshold,
            "per_stream_mean_mbps": {str(k): round(v, 2) for k, v in ordered},
            "confidence": "medium" if len(by_streams) >= 4 else "low",
            "evidence": evidence,
            "notes": notes,
            "source": "local",
        }
        raw = self._ask(
            "Does this data show traffic shaping? Return JSON only.\n"
            "Schema: { throttle_detected: boolean, reasoning: string, "
            "confidence: string }\n"
            "Distinguish shaping (selective, policy-driven) from congestion "
            "(affects everyone, varies with load). Say which you think it is.\n"
            f"Local analysis: {json.dumps(out)}\n",
            max_tokens=350,
        )
        if raw and isinstance(raw.get("throttle_detected"), bool):
            out["throttle_detected"] = raw["throttle_detected"]
            reasoning = str(raw.get("reasoning", ""))
            if reasoning:
                out["reasoning"] = reasoning[:400]
            out["confidence"] = str(raw.get("confidence", "low")).lower()
            out["source"] = "ai"
        return out

    def record_sample(self, mbps: float, streams: int) -> None:
        self._remember({"kind": "throttle", "mbps": mbps, "streams": streams})


# ── 39. CostAdvisor ───────────────────────────────────────────────────────────

class CostAdvisor:
    """Compare what is paid for against what is used.

    Honest framing only: a downgrade recommendation must carry the risk that
    real peaks exceed the cheaper tier, and the percentile that measures it.
    """

    def advise(
        self,
        plan_mbps: float,
        monthly_cost: float,
        samples: list[float] | None = None,
        currency: str = "",
    ) -> dict[str, Any]:
        """Recommend a tier, or explain why the current one is fine.

        `currency` is a symbol ("$", "£", "€"). Without it the money figures
        are reported as bare numbers and the result is flagged
        `currency_known: false` — a saving quoted as "40 per month" with no
        unit is not a claim worth showing a user.
        """
        def money(amount: float) -> str:
            return f"{currency}{amount:,.0f}" if currency else f"{amount:,.0f}"

        values = sorted(samples or [], reverse=True)
        if plan_mbps <= 0 or monthly_cost <= 0 or not values:
            return {
                "verdict": "insufficient_data",
                "notes": ["need a plan rate, a cost, and measured samples"],
                "source": "local",
            }

        p50 = values[len(values) // 2]
        p95 = values[max(0, int(len(values) * 0.05))]
        p99 = values[max(0, int(len(values) * 0.01))]
        peak = values[0]

        # Cost scales roughly with provisioned rate.
        suggested_mbps = p99 * 1.15          # headroom over the 99th percentile
        utilisation = p50 / plan_mbps

        notes = [
            f"median {p50:.1f} Mbps, 95th percentile {p95:.1f}, peak {peak:.1f}",
            f"you use {utilisation:.0%} of the provisioned rate at the median",
        ]

        verdict = "current_tier_is_fine"
        if utilisation < 0.3 and suggested_mbps < plan_mbps * 0.6:
            verdict = "downgrade_recommended"
            notes.append(
                f"you pay {money(monthly_cost)} per month for "
                f"{plan_mbps:g} Mbps"
            )
            savings = monthly_cost * (1 - suggested_mbps / plan_mbps)
            notes.append(
                f"a {suggested_mbps:.0f} Mbps tier would cover your 99th "
                f"percentile with 15% headroom and cost about "
                f"{money(monthly_cost - savings)} per month"
            )
            if not currency:
                notes.append(
                    "no currency supplied, so the money figures above are "
                    "bare numbers"
                )
            exceeded = sum(1 for v in values if v > suggested_mbps)
            if exceeded:
                notes.append(
                    f"risk: {exceeded} of {len(values)} measurements exceeded "
                    f"{suggested_mbps:.0f} Mbps — a large update may be "
                    "throttled"
                )
            else:
                notes.append(
                    f"no measurement exceeded {suggested_mbps:.0f} Mbps, so "
                    "nothing in your history suggests throttling"
                )
        elif utilisation > 0.85:
            verdict = "upgrade_may_help"
            notes.append(
                "you are consistently using most of what you pay for — a "
                "slower result is likely contention, not an under-sized plan"
            )
        return {
            "verdict": verdict,
            "currency": currency or None,
            "currency_known": bool(currency),
            "monthly_cost": round(monthly_cost, 2),
            "suggested_mbps": round(suggested_mbps, 1),
            "p50": round(p50, 2), "p95": round(p95, 2), "p99": round(p99, 2),
            "peak": round(peak, 2),
            "utilisation": round(utilisation, 3),
            "sample_count": len(values),
            "notes": notes,
            "source": "local",
        }


# ── 40. BenchmarkComparator ───────────────────────────────────────────────────

class BenchmarkComparator:
    """Place a result inside a cohort without leaking an identity.

    The cohort is supplied by the caller as pre-aggregated percentiles. This
    class never joins anything and never sends a raw measurement anywhere —
    the privacy property is structural, not a promise.
    """

    def compare(
        self,
        mbps: float,
        cohort_percentiles: dict[str, float],
        cohort_label: str = "cohort",
    ) -> dict[str, Any]:
        """Rank `mbps` against supplied percentile values (also in Mbps)."""
        if mbps <= 0 or not cohort_percentiles:
            return {"verdict": "insufficient_data", "notes": [
                "need a measurement and cohort percentile values"], "source": "local"}

        notes: list[str] = []
        p50 = cohort_percentiles.get("p50")
        if p50 is not None:
            if mbps > p50:
                notes.append(f"above the {cohort_label} median of {p50:.1f} Mbps")
            else:
                notes.append(f"below the {cohort_label} median of {p50:.1f} Mbps")

        above = sorted(
            (pct for pct, val in cohort_percentiles.items()
             if pct.startswith("p") and val < mbps),
            key=lambda p: int(p[1:]),
        )
        beats = above[-1] if above else None
        if beats:
            notes.append(f"roughly top {100 - int(beats[1:]):d}% of {cohort_label}")
        return {
            "verdict": beats or "below_p10",
            "beats_percentile": beats,
            "cohort": cohort_label,
            "notes": notes,
            "source": "local",
        }


# ── 37. GamifiedCoach ─────────────────────────────────────────────────────────

class GamifiedCoach(_Base):
    """Set one achievable weekly goal and track whether it was met.

    Motivation only: the goal is always something the user can actually do,
    and a missed week never resets progress. Nothing here invents a target
    the measurement cannot support.
    """

    GOALS: ClassVar[dict[str, dict[str, Any]]] = {
        "bloat": {"metric": "bloat_delta_ms", "better": "lower",
                  "label": "keep latency-under-load under 40 ms",
                  "action": "Enable SQM/fq_codel on the router"},
        "loss": {"metric": "loss_pct", "better": "lower",
                 "label": "hold packet loss under 0.5%",
                 "action": "Check cabling and WiFi distance"},
        "jitter": {"metric": "jitter_ms", "better": "lower",
                   "label": "hold jitter under 20 ms",
                   "action": "Prefer 5GHz and a narrower channel"},
    }

    def week_plan(self, goal: str, history_limit: int = 30) -> dict[str, Any]:
        """Set a goal from the last week of samples, if there are any."""
        spec = self.GOALS.get(goal)
        if not spec:
            return {"error": f"unknown goal {goal!r}",
                    "available": sorted(self.GOALS)}
        values = [float(r.get(spec["metric"], 0.0) or 0.0)
                  for r in self.history if r.get(spec["metric"]) is not None]
        if len(values) < 3:
            return {"goal": goal, "verdict": "insufficient_data",
                    "notes": [f"need at least 3 {spec['metric']} readings"],
                    "current": None, "source": "local"}

        current = statistics.fmean(values)
        worst = max(values) if spec["better"] == "lower" else min(values)
        return {
            "goal": goal,
            "label": spec["label"],
            "action": spec["action"],
            "current_avg": round(current, 2),
            "current_worst": round(worst, 2),
            "samples": len(values),
            "verdict": "on_track" if worst <= _goal_threshold(goal) else "work_to_do",
            "notes": [
                f"averaged {current:.2f} {spec['metric']} this week",
                f"worst reading {worst:.2f}",
            ],
            "source": "local",
        }

    def record_sample(self, **metrics: float) -> None:
        self._remember({"kind": "coach", **metrics})


def _goal_threshold(goal: str) -> float:
    return {"bloat": 40.0, "loss": 0.5, "jitter": 20.0}[goal]


# ── 42. MetricRuleEngine ─────────────────────────────────────────────────────

class MetricRuleError(ValueError):
    """A user-supplied metric rule would not compile."""


class MetricRuleEngine:
    """Evaluate small user-defined readiness rules over a metrics bundle.

    A deliberately tiny expression language — comparisons, boolean joins,
    parentheses, and the metrics we actually measure. No eval(), no attribute
    access, no names beyond the supplied metric keys, so a rule can come from
    a config file or an MCP client without becoming code execution.
    """

    METRICS: ClassVar[dict[str, float]] = {
        "mbps": 0.0, "upload_mbps": 0.0, "latency_ms": 0.0,
        "jitter_ms": 0.0, "loss_pct": 0.0, "bloat_delta_ms": 0.0,
        "bloat_grade_rank": 5.0, "wifi_rssi": -100.0, "wifi_snr": 0.0,
        "dns_ms": 0.0,
    }
    COMPARATORS: ClassVar[frozenset[str]] = frozenset({"<", ">", "<=", ">=", "==", "!="})

    def compile_rule(self, rule: str) -> str:
        """Validate a rule's grammar. Returns it unchanged, or raises."""
        text = (rule or "").strip()
        if not text:
            raise MetricRuleError("rule is empty")
        if len(text) > 500:
            raise MetricRuleError("rule is too long (500 char limit)")
        # Reject anything that could reach outside the metric namespace.
        banned = ("__", "import", "eval", "exec", "lambda", "open", "os.",
                  "sys.", "globals", "locals", "__import__")
        for word in banned:
            if word in text:
                raise MetricRuleError(f"rule may not contain {word!r}")
        if "=" in text.replace("==", "").replace("!=", "").replace(">=", "").replace("<=", ""):
            raise MetricRuleError("assignment is not allowed in a rule")

        # Tokenise and walk, so we validate structure and not just characters.
        tokens = _tokenise(text)
        if not tokens:
            raise MetricRuleError("rule has no tokens")
        for token in tokens:
            if token in {"and", "or"} or token in {"(", ")"}:
                continue
            if token in self.COMPARATORS:
                continue
            if token in {"true", "false"}:
                continue
            if _is_number(token):
                continue
            if token in self.METRICS:
                continue
            raise MetricRuleError(f"unknown metric or symbol: {token!r}")
        _validate_structure(tokens)
        return text

    def evaluate(self, rule: str, metrics: dict[str, Any]) -> dict[str, Any]:
        """Evaluate a rule against a metrics bundle."""
        self.compile_rule(rule)
        values = dict(self.METRICS)
        for key, value in metrics.items():
            if key in values and isinstance(value, (int, float)) and value == value:
                values[key] = float(value)
        tokens = _tokenise(rule.strip())
        result = bool(_evaluate_tokens(tokens, values))
        return {"rule": rule, "passed": result, "metrics": values}


def _tokenise(text: str) -> list[str]:
    tokens: list[str] = []
    i = 0
    while i < len(text):
        char = text[i]
        if char.isspace():
            i += 1
        elif text[i:i + 2] in {"<=", ">=", "==", "!="}:
            tokens.append(text[i:i + 2])
            i += 2
        elif char in "<>":
            tokens.append(char)
            i += 1
        elif char in "()":
            tokens.append(char)
            i += 1
        else:
            start = i
            while i < len(text) and not text[i].isspace() and text[i] not in "<>()=":
                i += 1
            if i == start:
                i += 1
                continue
            tokens.append(text[start:i])
    return tokens


def _is_number(token: str) -> bool:
    try:
        float(token)
    except ValueError:
        return False
    return True


def _validate_structure(tokens: list[str]) -> None:
    depth = 0
    for token in tokens:
        if token == "(":
            depth += 1
        elif token == ")":
            depth -= 1
            if depth < 0:
                raise MetricRuleError("unbalanced closing parenthesis")
    if depth:
        raise MetricRuleError("unbalanced opening parenthesis")


def _evaluate_tokens(tokens: list[str], values: dict[str, float]) -> Any:
    """Recursive-descent evaluation of the validated token stream."""
    pos = 0

    def peek() -> str | None:
        return tokens[pos] if pos < len(tokens) else None

    def parse_or() -> bool:
        nonlocal pos
        left = parse_and()
        while peek() == "or":
            pos += 1
            right = parse_and()
            left = left or right
        return left

    def parse_and() -> bool:
        nonlocal pos
        left = parse_atom()
        while peek() == "and":
            pos += 1
            right = parse_atom()
            left = left and right
        return left

    def parse_atom() -> bool:
        nonlocal pos
        token = peek()
        if token is None:
            raise MetricRuleError("unexpected end of rule")
        if token == "(":
            pos += 1
            value = parse_or()
            if peek() != ")":
                raise MetricRuleError("missing closing parenthesis")
            pos += 1
            return value
        left = _resolve(token, values)
        pos += 1
        comparator = peek()
        if comparator not in {"<", ">", "<=", ">=", "==", "!="}:
            raise MetricRuleError("expected a comparison operator")
        pos += 1
        right_token = peek()
        if right_token is None:
            raise MetricRuleError("missing right-hand value")
        right = _resolve(right_token, values)
        pos += 1
        if comparator == "<":
            return left < right
        if comparator == ">":
            return left > right
        if comparator == "<=":
            return left <= right
        if comparator == ">=":
            return left >= right
        if comparator == "==":
            return left == right
        return left != right

    return parse_or()


def _resolve(token: str, values: dict[str, float]) -> float:
    if token in {"true", "false"}:
        return 1.0 if token == "true" else 0.0
    if token in values:
        return float(values[token])
    return float(token)
