"""Offline tests for netmax_retry — jittered exponential backoff."""

import pytest

import netmax_retry as nr


class TestBackoff:
    def test_first_attempt_uses_base_cap_window(self):
        # attempt=1 → raw = base * 2^0 = base; rng(0, base)
        assert nr.backoff(1, base=0.5, cap=8.0, rng=lambda lo, hi: hi) == 0.5

    def test_exponential_growth_until_cap(self):
        assert nr.backoff(2, base=0.5, cap=8.0, rng=lambda lo, hi: hi) == 1.0
        assert nr.backoff(3, base=0.5, cap=8.0, rng=lambda lo, hi: hi) == 2.0
        assert nr.backoff(4, base=0.5, cap=8.0, rng=lambda lo, hi: hi) == 4.0
        assert nr.backoff(5, base=0.5, cap=8.0, rng=lambda lo, hi: hi) == 8.0
        assert nr.backoff(6, base=0.5, cap=8.0, rng=lambda lo, hi: hi) == 8.0

    def test_jitter_draws_within_raw(self):
        for _ in range(20):
            v = nr.backoff(3, base=0.5, cap=8.0, rng=__import__("random").uniform)
            assert 0.0 <= v <= 2.0


class TestRetry:
    def test_success_first_try_no_sleep(self):
        sleeps = []
        assert nr.retry(lambda: 42, sleep=sleeps.append) == 42
        assert sleeps == []

    def test_retries_until_success(self):
        calls = {"n": 0}
        sleeps = []

        def flaky():
            calls["n"] += 1
            if calls["n"] < 3:
                raise ValueError("nope")
            return "ok"

        assert nr.retry(flaky, attempts=5, sleep=sleeps.append) == "ok"
        assert calls["n"] == 3
        assert len(sleeps) == 2

    def test_raises_after_budget_exhausted(self):
        sleeps = []

        def always_fail():
            raise RuntimeError("boom")

        with pytest.raises(RuntimeError, match="boom"):
            nr.retry(always_fail, attempts=3, sleep=sleeps.append)
        assert len(sleeps) == 2  # no sleep after final attempt

    def test_attempts_below_one_rejected(self):
        with pytest.raises(ValueError, match="attempts"):
            nr.retry(lambda: 1, attempts=0)
