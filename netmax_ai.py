#!/usr/bin/env python3
"""AI-assisted speed governor for NetMax limit mode.

Design:
- Optional: if NETMAX_AI_API_KEY is set, asks a model for governor decisions.
- Fallback: if API is missing/unavailable, returns None so the hardcoded
  closed-loop governor still runs unchanged.
- Output contract mirrors the internal governor state so the caller can
  override per-stream pace, stream count, or both.
"""

from __future__ import annotations

import json
import math
import os
import time
from dataclasses import dataclass, field
from typing import Any

import netmax_ai_provider as provider_mod


@dataclass
class GovernorDecision:
    """One governor step decision."""
    streams: int | None = None
    pace_bps: float | None = None
    reasoning: str = ""
    confidence: str = "low"
    raw: dict[str, Any] = field(default_factory=dict)


DEFAULT_AI_MODEL = "gpt-4o-mini"
DEFAULT_AI_BASE = "https://api.openai.com/v1/chat/completions"


def _chat_json(
    prompt: str,
    *,
    api_key: str,
    model: str = DEFAULT_AI_MODEL,
    api_base: str = DEFAULT_AI_BASE,
    timeout_s: float = 6.0,
    max_tokens: int = 120,
    system: str = "You are a JSON-only network assistant.",
) -> dict[str, Any]:
    """POST a chat completion and return the parsed JSON object.

    Delegates to netmax_ai_provider so the whole AI layer picks up
    NETMAX_AI_PROVIDER / NETMAX_AI_BASE / NETMAX_AI_MODEL — including a
    keyless local server, and providers that reject `response_format`.

    api_key / model / api_base still win when passed explicitly, so every
    existing caller and test behaves exactly as before.

    Raises on any transport/protocol problem — callers decide whether that
    means "fall back to heuristics" (best-effort callers) or "fail".
    """
    provider = provider_mod.Provider(
        name="inline",
        base=(api_base or DEFAULT_AI_BASE),
        model=(model or DEFAULT_AI_MODEL),
        requires_key=bool(api_key),
        supports_json_mode=True,
        auth_style="bearer" if api_key else "none",
        api_key=api_key or None,
    )
    return provider_mod.chat_json(
        prompt, system=system, max_tokens=max_tokens, provider=provider)


class PredictiveAdjustment:
    """Dataclass for storing predictive adjustment parameters."""
    
    def __init__(
        self,
        streams_adjustment: float = 0.0,
        pace_adjustment: float = 0.0,
        reasoning: str = "",
        confidence: str = "low",
    ):
        self.streams_adjustment = streams_adjustment
        self.pace_adjustment = pace_adjustment
        self.reasoning = reasoning
        self.confidence = confidence
    
    def to_dict(self) -> dict[str, Any]:
        return {
            "streams_adjustment": self.streams_adjustment,
            "pace_adjustment": self.pace_adjustment,
            "reasoning": self.reasoning,
            "confidence": self.confidence,
        }
    
    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "PredictiveAdjustment":
        return cls(
            streams_adjustment=data.get("streams_adjustment", 0.0),
            pace_adjustment=data.get("pace_adjustment", 0.0),
            reasoning=data.get("reasoning", ""),
            confidence=data.get("confidence", "low"),
        )


class PredictiveShaper:
    """Predictive shaping based on historical network data.

    Local heuristics answer first (fast, free, offline). When
    NETMAX_AI_API_KEY is set and the heuristics abstain, the model is asked
    for a nudge and any failure falls back to "no adjustment".
    """

    def __init__(
        self,
        history_limit: int = 20,
        *,
        api_key: str | None = None,
        model: str = DEFAULT_AI_MODEL,
        api_base: str = DEFAULT_AI_BASE,
        timeout_s: float = 6.0,
    ):
        self.history_limit = history_limit
        self.history: list[dict[str, Any]] = []
        self.api_key = (
            api_key if api_key is not None
            else os.environ.get("NETMAX_AI_API_KEY", "")
        )
        self.model = model
        self.api_base = api_base
        self.timeout_s = timeout_s
    
    def record_interval(
        self,
        mbps: float,
        streams: int,
        target_mbps: float,
        latency_ms: float = 0.0,
        jitter_ms: float = 0.0,
        loss_pct: float = 0.0,
    ) -> None:
        """Record a network interval for predictive analysis."""
        self.history.append({
            "ts": time.time(),
            "mbps": mbps,
            "streams": streams,
            "target_mbps": target_mbps,
            "latency_ms": latency_ms,
            "jitter_ms": jitter_ms,
            "loss_pct": loss_pct,
            "error_pct": ((mbps / target_mbps) - 1.0) * 100.0 if target_mbps else 0.0,
        })
        self.history[:] = self.history[-self.history_limit :]
    
    def _local_suggestion(
        self,
        current_mbps: float,
        target_mbps: float,
        latency_ms: float,
        jitter_ms: float,
        loss_pct: float,
        streams: int,
    ) -> dict[str, Any]:
        """Generate a local adjustment suggestion based on current conditions.
        
        Implements P0 feature for three scenarios:
        1. High jitter or loss - conservative adjustment
        2. Sustained negative trend - reduction recommendation  
        3. Running above target - no change recommendation
        """
        suggestions = []
        
        # Scenario 1: High jitter or loss - conservative adjustment
        if jitter_ms > 50 or loss_pct > 1.0:
            suggestions.append({
                "type": "high_jitter_loss",
                "streams_adjustment": -1,
                "pace_adjustment": -0.1,
                "reasoning": f"High jitter ({jitter_ms}ms) and loss ({loss_pct}%) detected - reducing streams and pace",
                "confidence": "high" if (jitter_ms > 100 or loss_pct > 3.0) else "medium",
            })
        
        # Scenario 2: Sustained negative trend - reduction recommendation
        if len(self.history) >= 5:
            recent_mbps = [h["mbps"] for h in self.history[-5:]]
            trend = (recent_mbps[-1] - recent_mbps[0]) / len(recent_mbps) if recent_mbps[0] > 0 else 0
            if trend < -1.0:  # 10% sustained decline
                suggestions.append({
                    "type": "sustained_negative_trend",
                    "streams_adjustment": -1,
                    "pace_adjustment": -0.15,
                    "reasoning": f"Sustained negative trend: {trend:.2f} Mbps/period - proactive reduction",
                    "confidence": "medium" if trend > -5.0 else "high",
                })
        
        # Scenario 3: Running above target - no change recommendation
        if current_mbps > target_mbps * 1.1:  # 10% above target
            suggestions.append({
                "type": "running_above_target",
                "streams_adjustment": 0,
                "pace_adjustment": 0.0,
                "reasoning": f"Running above target ({current_mbps:.1f} > {target_mbps:.1f}) - maintaining current settings",
                "confidence": "low",
            })
        
        # Default suggestion if no specific scenario matches
        if not suggestions:
            suggestions.append({
                "type": "maintain_current",
                "streams_adjustment": 0,
                "pace_adjustment": 0.0,
                "reasoning": "Current conditions within acceptable range",
                "confidence": "low",
            })
        
        # Return the best suggestion based on confidence
        suggestions.sort(key=lambda x: {"high": 3, "medium": 2, "low": 1}.get(x["confidence"], 0), reverse=True)
        return suggestions[0]
    
    def suggest(
        self,
        current_mbps: float,
        target_mbps: float,
        latency_ms: float = 0.0,
        jitter_ms: float = 0.0,
        loss_pct: float = 0.0,
        streams: int = 1,
    ) -> dict[str, Any]:
        """Generate a predictive suggestion based on history and current state."""
        
        # P0 feature: return empty dict when history is empty
        if not self.history:
            return {}
        
        # Apply local suggestion
        suggestion = self._local_suggestion(
            current_mbps, target_mbps, latency_ms, jitter_ms, loss_pct, streams
        )

        # Heuristics abstain (type == "maintain_current") and a key is set —
        # ask the model. Any transport/protocol failure keeps the local answer.
        if suggestion.get("type") == "maintain_current" and self.api_key:
            try:
                suggestion = self._ai_suggestion(
                    current_mbps, target_mbps,
                    latency_ms, jitter_ms, loss_pct, streams,
                )
            except (OSError, ValueError, TypeError, KeyError):
                pass
        
        # Add predictive analysis
        if len(self.history) >= 3:
            recent_mbps = [h["mbps"] for h in self.history[-3:]]
            recent_trend = (recent_mbps[-1] - recent_mbps[0]) / (len(recent_mbps) - 1) if len(recent_mbps) > 1 else 0
            
            suggestion.update({
                "recent_trend": recent_trend,
                "historical_avg": sum(h["mbps"] for h in self.history) / len(self.history),
                "stability": self._calculate_stability(recent_mbps),
            })
        
        return suggestion
    
    def _ai_suggestion(
        self,
        current_mbps: float,
        target_mbps: float,
        latency_ms: float,
        jitter_ms: float,
        loss_pct: float,
        streams: int,
    ) -> dict[str, Any]:
        """Model-proposed adjustment; same shape as _local_suggestion."""
        series = [round(h["mbps"], 2) for h in self.history[-10:]]
        prompt = (
            "You are a conservative bandwidth shaper for a macOS network tool.\n"
            "Return JSON only.\n"
            "Schema: { type: string, streams_adjustment: number, "
            "pace_adjustment: number, reasoning: string, confidence: string }\n"
            "- type must be one of: maintain_current, high_jitter_loss, "
            "sustained_negative_trend, running_above_target.\n"
            "- streams_adjustment is an integer delta (-3..3).\n"
            "- pace_adjustment is a fractional delta (-0.3..0.3).\n"
            "- Be conservative: never propose a large correction on thin evidence.\n\n"
            f"Target: {target_mbps:g} Mbps\n"
            f"Current: {current_mbps:g} Mbps over {streams} stream(s)\n"
            f"Latency: {latency_ms:g} ms, jitter: {jitter_ms:g} ms, "
            f"loss: {loss_pct:g}%\n"
            f"Recent interval series (Mbps): {series}\n"
        )
        raw = _chat_json(
            prompt,
            api_key=self.api_key,
            model=self.model,
            api_base=self.api_base,
            timeout_s=self.timeout_s,
            max_tokens=140,
            system="You are a JSON-only bandwidth shaper.",
        )
        try:
            streams_adj = int(raw.get("streams_adjustment", 0) or 0)
        except (TypeError, ValueError):
            streams_adj = 0
        try:
            pace_adj = float(raw.get("pace_adjustment", 0.0) or 0.0)
        except (TypeError, ValueError):
            pace_adj = 0.0
        return {
            "type": str(raw.get("type", "maintain_current")),
            # Clamp: a model must not be able to command an unbounded move.
            "streams_adjustment": max(-3, min(3, streams_adj)),
            "pace_adjustment": max(-0.3, min(0.3, pace_adj)),
            "reasoning": str(raw.get("reasoning", ""))[:300],
            "confidence": str(raw.get("confidence", "low")).lower(),
            "source": "ai",
        }

    def _calculate_stability(self, recent_mbps: list[float]) -> float:
        """Calculate stability metric for recent throughput values."""
        if len(recent_mbps) < 2:
            return 0.0
        
        avg = sum(recent_mbps) / len(recent_mbps)
        if avg == 0:
            return 0.0
        
        variance = sum((x - avg) ** 2 for x in recent_mbps) / len(recent_mbps)
        return max(0.0, 1.0 - (variance ** 0.5 / avg))


class EndpointStrategySelector:
    """Select the best endpoint strategy based on historical performance.

    Ranks endpoints locally first (free, offline). With NETMAX_AI_API_KEY set,
    the ranking is handed to the model for a second opinion on which endpoint
    to favour and why; any failure keeps the local ranking.
    """

    def __init__(
        self,
        history_limit: int = 20,
        *,
        api_key: str | None = None,
        model: str = DEFAULT_AI_MODEL,
        api_base: str = DEFAULT_AI_BASE,
        timeout_s: float = 6.0,
    ):
        self.history_limit = history_limit
        self.history: list[dict[str, Any]] = []
        self.api_key = (
            api_key if api_key is not None
            else os.environ.get("NETMAX_AI_API_KEY", "")
        )
        self.model = model
        self.api_base = api_base
        self.timeout_s = timeout_s
    
    def record_result(
        self,
        endpoint: str,
        mbps: float,
        latency_ms: float,
        jitter_ms: float,
        loss_pct: float,
        success: bool = True,
    ) -> None:
        """Record an endpoint test result."""
        self.history.append({
            "ts": time.time(),
            "endpoint": endpoint,
            "mbps": mbps,
            "latency_ms": latency_ms,
            "jitter_ms": jitter_ms,
            "loss_pct": loss_pct,
            "success": success,
        })
        self.history[:] = self.history[-self.history_limit :]
    
    def _ai_pick_endpoint(
        self,
        current_endpoint: str,
        candidates: list[dict[str, Any]],
    ) -> list[dict[str, Any]] | None:
        """Re-rank measured endpoints with the model.

        Returns the re-ordered candidate list, or None to keep the local
        ranking. The chosen endpoint MUST be one we measured — an unknown
        host from the model is discarded rather than trusted.
        """
        allowed = {c["endpoint"] for c in candidates}
        table = [
            {
                "endpoint": c["endpoint"],
                "success_rate": round(c["success_rate"], 3),
                "avg_mbps": round(c["avg_mbps"], 2),
                "avg_latency_ms": round(c["avg_latency"], 2),
                "avg_jitter_ms": round(c["avg_jitter"], 2),
                "avg_loss_pct": round(c["avg_loss"], 3),
                "samples": c["test_count"],
            }
            for c in candidates
        ]
        prompt = (
            "You pick the best CDN endpoint for a throughput test on macOS.\n"
            "Return JSON only.\n"
            "Schema: { order: string[], reasoning: string, confidence: string }\n"
            "- `order` must list every endpoint exactly once, best first.\n"
            "- Only use endpoint names present in the table.\n"
            "- Prefer high throughput AND low latency/loss; a fast endpoint "
            "that 429s is worse than a slightly slower reliable one.\n\n"
            f"Current endpoint: {current_endpoint}\n"
            f"Measured endpoints: {json.dumps(table)}\n"
        )
        raw = _chat_json(
            prompt,
            api_key=self.api_key,
            model=self.model,
            api_base=self.api_base,
            timeout_s=self.timeout_s,
            max_tokens=200,
            system="You are a JSON-only network endpoint selector.",
        )
        order = raw.get("order")
        if not isinstance(order, list) or not order:
            return None
        # Validate: every name known, no dupes, full coverage. A partial or
        # hallucinated order is discarded outright.
        if set(order) != allowed or len(order) != len(allowed):
            return None
        by_name = {c["endpoint"]: c for c in candidates}
        ranked = [by_name[name] for name in order]
        best = ranked[0]
        if best["endpoint"] != candidates[0]["endpoint"]:
            best = dict(best)
            best["ai_reasoning"] = str(raw.get("reasoning", ""))[:300]
            ranked[0] = best
        return ranked

    def suggest(
        self,
        current_endpoint: str,
        min_success_rate: float = 0.8,
        min_avg_mbps: float = 10.0,
    ) -> dict[str, Any]:
        """Suggest the best endpoint strategy.
        
        P0 feature: returns empty dict when history is empty.
        Preference logic:
        1. Prefer endpoints with success rate >= min_success_rate
        2. Among those, prefer higher average Mbps
        3. Break ties by preferring endpoints with lower latency
        4. Default to current endpoint if no better option found
        """
        
        # P0 feature: return empty dict when history is empty
        if not self.history:
            return {}
        
        # Group results by endpoint
        endpoint_stats: dict[str, list[dict[str, Any]]] = {}
        for result in self.history:
            if result["endpoint"] not in endpoint_stats:
                endpoint_stats[result["endpoint"]] = []
            endpoint_stats[result["endpoint"]].append(result)
        
        # Calculate metrics for each endpoint
        candidate_endpoints = []
        
        for endpoint, results in endpoint_stats.items():
            success_count = sum(1 for r in results if r["success"])
            success_rate = success_count / len(results) if results else 0.0
            
            if success_rate < min_success_rate:
                continue
            
            avg_mbps = sum(r["mbps"] for r in results) / len(results)
            avg_latency = sum(r["latency_ms"] for r in results) / len(results)
            avg_jitter = sum(r["jitter_ms"] for r in results) / len(results)
            avg_loss = sum(r["loss_pct"] for r in results) / len(results)
            
            candidate_endpoints.append({
                "endpoint": endpoint,
                "success_rate": success_rate,
                "avg_mbps": avg_mbps,
                "avg_latency": avg_latency,
                "avg_jitter": avg_jitter,
                "avg_loss": avg_loss,
                "test_count": len(results),
            })
        
        # Sort candidates by preference: higher Mbps, lower latency, then jitter/loss
        candidate_endpoints.sort(
            key=lambda x: (
                x["avg_mbps"],
                -x["avg_latency"],  # Negative for ascending order
                x["avg_jitter"],
                x["avg_loss"],
            ),
            reverse=True,
        )
        
        if not candidate_endpoints:
            return {"reasoning": "No endpoints meet minimum requirements", "keep_current": True}
        
        best_endpoint = candidate_endpoints[0]
        
        # Model second opinion on the locally-ranked shortlist. Bounded to
        # endpoints we actually measured, so the model cannot invent a host.
        if provider_mod.has_provider(api_key=self.api_key) and len(candidate_endpoints) > 1:
            try:
                ai_pick = self._ai_pick_endpoint(
                    current_endpoint, candidate_endpoints
                )
                if ai_pick is not None:
                    candidate_endpoints = ai_pick
                    best_endpoint = candidate_endpoints[0]
            except (OSError, ValueError, TypeError, KeyError):
                pass
        
        ai_reasoning = str(best_endpoint.get("ai_reasoning", "") or "")

        # If current endpoint is best, suggest keeping it
        if current_endpoint == best_endpoint["endpoint"]:
            return {
                "endpoint": current_endpoint,
                "streams_adjustment": 0,
                "pace_adjustment": 0.0,
                "reasoning": ai_reasoning or f"Current endpoint '{current_endpoint}' is optimal",
                "confidence": "high" if best_endpoint["test_count"] >= 5 else "medium",
                "source": "ai" if ai_reasoning else "local",
            }
        
        # Suggest switching to better endpoint
        streams_adjustment = 1 if best_endpoint["endpoint"] != current_endpoint else 0
        
        return {
            "endpoint": best_endpoint["endpoint"],
            "streams_adjustment": streams_adjustment,
            "pace_adjustment": 0.0,
            "reasoning": ai_reasoning or f"Switch from '{current_endpoint}' to '{best_endpoint['endpoint']}' (higher Mbps: {best_endpoint['avg_mbps']:.1f} vs current)",
            "confidence": "high" if best_endpoint["test_count"] >= 5 else "medium",
            "source": "ai" if ai_reasoning else "local",
            "metrics": {
                "success_rate": best_endpoint["success_rate"],
                "avg_mbps": best_endpoint["avg_mbps"],
                "avg_latency": best_endpoint["avg_latency"],
                "avg_jitter": best_endpoint["avg_jitter"],
                "avg_loss": best_endpoint["avg_loss"],
            },
        }


class AISpeedGovernor:
    """Best-effort AI governor helper.

    It never raises on API failure; callers check `decide(...)` return value.
    """

    def __init__(
        self,
        *,
        api_key: str | None = None,
        model: str = "gpt-4o-mini",
        api_base: str = "https://api.openai.com/v1/chat/completions",
        timeout_s: float = 6.0,
        history_limit: int = 20,
    ) -> None:
        self.api_key = api_key or os.environ.get("NETMAX_AI_API_KEY", "")
        self.model = model
        self.api_base = api_base.rstrip("/")
        self.timeout_s = timeout_s
        self.history_limit = history_limit
        self.history: list[dict[str, Any]] = []

    # ── public ────────────────────────────────────────────────────────────────

    def decide(
        self,
        target_mbps: float,
        telemetry: dict[str, Any],
    ) -> GovernorDecision | None:
        """Return an AI decision, or None if API is unavailable."""
        if not provider_mod.has_provider(api_key=self.api_key):
            return None
        try:
            payload = self._build_payload(target_mbps, telemetry)
            raw = self._call_api(payload)
            return self._parse(raw, target_mbps=target_mbps)
        except (OSError, ValueError, TypeError, KeyError):
            return None

    def record_interval(self, mbps: float, streams: int, target_mbps: float) -> None:
        self.history.append(
            {
                "ts": time.time(),
                "mbps": mbps,
                "streams": streams,
                "target_mbps": target_mbps,
                "error_pct": ((mbps / target_mbps) - 1.0) * 100.0 if target_mbps else 0.0,
            }
        )
        self.history[:] = self.history[-self.history_limit :]

    # ── internals ─────────────────────────────────────────────────────────────

    def _build_payload(self, target_mbps: float, telemetry: dict[str, Any]) -> dict[str, Any]:
        prompt = (
            "You are a conservative bandwidth governor.\n"
            "Goal: keep aggregate download throughput as close to target as possible, "
            "without exceeding it for long. Prefer fewer streams when latency/loss is "
            "high or endpoint is flaky.\n"
            "Constraints:\n"
            f"- Target aggregate: {target_mbps:g} Mbps\n"
            "- Return JSON only.\n"
            "- `streams` must be an integer in 1..50 if provided.\n"
            "- `pace_bps` is bytes/s aggregate if provided, else null.\n"
            "- `confidence`: low/medium/high.\n"
            "- `reasoning`: one short sentence.\n"
            "Schema:\n"
            "{ streams?: number, pace_bps?: number | null, reasoning: string, confidence: string }\n\n"
            "Telemetry:\n"
            f"- current_mbps: {telemetry.get('mbps', 0):g}\n"
            f"- latency_ms: {telemetry.get('latency_ms', 0):g}\n"
            f"- jitter_ms: {telemetry.get('jitter_ms', 0):g}\n"
            f"- loss_pct: {telemetry.get('loss_pct', 0):g}\n"
            f"- streams: {telemetry.get('streams', 1)}\n"
            f"- endpoint: {telemetry.get('endpoint', 'unknown')}\n"
            f"- endpoint_health: {telemetry.get('endpoint_health', {})}\n"
            f"- wifi_rssi: {telemetry.get('rssi', 'unknown')}\n"
            f"- wifi_noise: {telemetry.get('noise', 'unknown')}\n"
            f"- wifi_channel: {telemetry.get('channel', 'unknown')}\n"
        )
        if self.history:
            recent = [f"{h['mbps']:.2f} Mbps @ {h['streams']} streams" for h in self.history[-8:]]
            prompt += "\nRecent intervals:\n" + "\n".join(recent) + "\n"

        return {
            "model": self.model,
            "temperature": 0.1,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": "You are a JSON-only network governor."},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": 120,
        }

    def _call_api(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Send a prepared governor payload through the shared provider path.

        Kept as a method taking the already-built payload so the prompt
        assembly above stays exactly as it was, but the transport is now
        the SAME one every other class uses — so the governor honours
        NETMAX_AI_BASE / NETMAX_AI_PROVIDER and works against a local or
        non-OpenAI-shaped endpoint instead of being quietly OpenAI-only.
        """
        provider = provider_mod.Provider(
            name="governor",
            base=(self.api_base or DEFAULT_AI_BASE),
            model=(self.model or DEFAULT_AI_MODEL),
            requires_key=bool(self.api_key),
            supports_json_mode=True,
            auth_style="bearer",
            api_key=self.api_key or None,
        )
        user_prompt = next(
            (m["content"] for m in payload.get("messages", [])
             if m.get("role") == "user"), "")
        system = next(
            (m["content"] for m in payload.get("messages", [])
             if m.get("role") == "system"),
            "You are a JSON-only network governor.")
        try:
            return provider_mod.chat_json(
                user_prompt, system=system,
                max_tokens=int(payload.get("max_tokens", 120)),
                provider=provider,
                max_response_bytes=1_048_576,
                max_json_depth=16)
        except (ValueError, TypeError):
            # The governor is a best-effort caller: a model that answers in
            # prose must degrade to "keep the current pace", not abort the
            # run. The hardcoded governor takes over on a None decision.
            return {"reasoning": "model reply was not JSON"}


    @staticmethod
    def _parse(
        raw: dict[str, Any], *, target_mbps: float | None = None
    ) -> GovernorDecision:
        if not isinstance(raw, dict):
            raise TypeError("non-dict governor response")
        allowed = {"streams", "pace_bps", "reasoning", "confidence"}
        if raw.keys() - allowed:
            raise ValueError("unknown governor response key")
        streams = raw.get("streams")
        if streams is not None:
            if isinstance(streams, bool) or not isinstance(streams, int):
                raise ValueError("streams must be an integer")
            if not 1 <= streams <= 50:
                raise ValueError(f"streams out of range: {streams}")
        pace_bps = raw.get("pace_bps")
        if pace_bps is not None:
            if isinstance(pace_bps, bool) or not isinstance(pace_bps, (int, float)):
                raise ValueError("pace_bps must be numeric")
            pace_bps = float(pace_bps)
            if not math.isfinite(pace_bps) or pace_bps < 0:
                raise ValueError("pace_bps must be finite and non-negative")
            if target_mbps is not None:
                ceiling = target_mbps * 1_000_000 / 8 * 1.5
                if pace_bps > ceiling:
                    raise ValueError("pace_bps exceeds target ceiling")
        reasoning = raw.get("reasoning", "")
        confidence = raw.get("confidence", "low")
        if not isinstance(reasoning, str) or not isinstance(confidence, str):
            raise ValueError("reasoning and confidence must be strings")
        if confidence.lower() not in {"low", "medium", "high"}:
            raise ValueError("invalid confidence")
        return GovernorDecision(
            streams=streams,
            pace_bps=pace_bps,
            reasoning=reasoning[:300],
            confidence=confidence.lower(),
            raw={k: raw[k] for k in allowed if k in raw},
        )
