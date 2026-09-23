"""Headless tests for netmax_gui.

These tests deliberately avoid creating Tk widgets so they run without a
display. Widget construction/layout is verified separately by a manual GUI
smoke run, which may fail in headless environments.
"""
import os
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import netmax_gui


class ThemeConstantsTest(unittest.TestCase):
    """Pin the palette/texts mandated by the spec."""

    def test_palette_values(self):
        self.assertEqual(netmax_gui.PAGE_BG, "#F4F5F7")
        self.assertEqual(netmax_gui.HEADER_BG, "#1F2635")
        self.assertEqual(netmax_gui.ACCENT, "#7C5A9B")
        self.assertEqual(netmax_gui.CARD_BG, "#FFFFFF")

    def test_title_text(self):
        self.assertEqual(netmax_gui.WINDOW_TITLE, "NetMax — Bandwidth Maximizer")

    def test_disclaimer_text_exact(self):
        self.assertEqual(
            netmax_gui.DISCLAIMER,
            "No tool can exceed your ISP-provisioned cap — NetMax unlocks the "
            "speed your plan already pays for.",
        )

    def test_modes_match_cli_subcommands(self):
        self.assertEqual(
            set(netmax_gui.MODES),
            {"baseline", "turbo", "boost", "dns", "bloat", "full"},
        )


class BuildCommandTest(unittest.TestCase):
    """build_command must produce argv netmax.py's argparse accepts."""

    def test_turbo_includes_both_flags(self):
        cmd = netmax_gui.build_command("turbo", 8, 10)
        self.assertEqual(cmd[-5:], ["turbo", "--streams", "8", "--seconds", "10"])

    def test_full_includes_both_flags(self):
        cmd = netmax_gui.build_command("full", 12, 25)
        self.assertEqual(cmd[-5:], ["full", "--streams", "12", "--seconds", "25"])

    def test_baseline_accepts_seconds_but_not_streams(self):
        cmd = netmax_gui.build_command("baseline", 8, 10)
        self.assertEqual(cmd[-3:], ["baseline", "--seconds", "10"])
        self.assertNotIn("--streams", cmd)

    def test_dns_has_no_value_flags(self):
        cmd = netmax_gui.build_command("dns", 8, 10)
        self.assertEqual(cmd[-1], "dns")
        self.assertNotIn("--streams", cmd)
        self.assertNotIn("--seconds", cmd)

    def test_unknown_mode_rejected(self):
        with self.assertRaises(ValueError):
            netmax_gui.build_command("warp", 8, 10)

    def test_streams_out_of_range_rejected(self):
        for bad in (0, -1, 51, 100):
            with self.assertRaises(ValueError):
                netmax_gui.build_command("turbo", bad, 10)

    def test_streams_boundaries_accepted(self):
        for ok in (1, 50):
            cmd = netmax_gui.build_command("turbo", ok, 10)  # must not raise
            self.assertIn(str(ok), cmd)

    def test_seconds_out_of_range_rejected(self):
        for bad in (0, 4, 31):
            with self.assertRaises(ValueError):
                netmax_gui.build_command("boost", 8, bad)

    def test_seconds_boundaries_accepted(self):
        for ok in (5, 30):
            netmax_gui.build_command("baseline", 8, ok)  # must not raise


class RunnerPlumbingTest(unittest.TestCase):
    """NetMaxRunner: threaded subprocess piping, no Tk involved.

    A NetMaxRunner thread object can only be started once; every command here
    gets a fresh runner so the hand-off path in start_command stays exercised.
    """

    PY = sys.executable

    def _make_runner(self):
        out, err, done = [], [], []
        finished = threading.Event()

        def on_done(rc):
            done.append(rc)
            finished.set()

        runner = netmax_gui.NetMaxRunner(
            on_stdout=out.append, on_stderr=err.append, on_done=on_done
        )
        return runner, out, err, done, finished

    def _cleanup(self, runner):
        runner.stop()
        if runner.is_alive():
            runner.join(5)

    def test_stdout_lines_delivered_verbatim_in_order(self):
        runner, out, err, done, finished = self._make_runner()
        try:
            runner.start_command(
                [self.PY, "-c", "print('alpha'); print('beta'); print('gamma')"]
            )
            self.assertTrue(finished.wait(20), "on_done was not called")
            self.assertEqual(out, ["alpha", "beta", "gamma"])
            self.assertEqual(err, [])
            self.assertEqual(done, [0])
        finally:
            self._cleanup(runner)

    def test_stderr_routed_to_distinct_callback(self):
        runner, out, err, done, finished = self._make_runner()
        try:
            runner.start_command(
                [
                    self.PY,
                    "-c",
                    "import sys; print('to-out'); sys.stderr.write('to-err\\n')",
                ]
            )
            self.assertTrue(finished.wait(20), "on_done was not called")
            self.assertEqual(out, ["to-out"])
            self.assertEqual(err, ["to-err"])
            self.assertEqual(done, [0])
        finally:
            self._cleanup(runner)

    def test_nonzero_exit_code_reported(self):
        runner, _out, _err, done, finished = self._make_runner()
        try:
            runner.start_command([self.PY, "-c", "import sys; sys.exit(3)"])
            self.assertTrue(finished.wait(20), "on_done was not called")
            self.assertEqual(done, [3])
        finally:
            self._cleanup(runner)

    def test_on_done_called_exactly_once_on_success(self):
        runner, _out, _err, done, finished = self._make_runner()
        try:
            runner.start_command([self.PY, "-c", "print('x')"])
            self.assertTrue(finished.wait(20))
            time.sleep(0.3)  # no late duplicate callbacks
            self.assertEqual(len(done), 1)
        finally:
            self._cleanup(runner)

    def test_second_start_while_alive_rejected(self):
        runner, _out, _err, _done, _finished = self._make_runner()
        try:
            runner.start_command(
                [self.PY, "-c", "import time; time.sleep(30)"]
            )
            with self.assertRaises(RuntimeError):
                runner.start_command([self.PY, "-c", "print('nope')"])
        finally:
            self._cleanup(runner)

    def test_restart_after_stop_works(self):
        """The HIGH review finding: after stop(), a new command must run."""
        runner, out, _err, done, finished = self._make_runner()
        runner.start_command([self.PY, "-c", "import time; time.sleep(60)"])
        deadline = time.time() + 5
        while not out and time.time() < deadline:
            time.sleep(0.02)
        runner.stop()
        self.assertTrue(finished.wait(10), "stop() did not complete first child")

        # second command on the SAME runner object — the original bug scenario
        out.clear(); done.clear(); finished.clear()
        try:
            runner.start_command([self.PY, "-c", "print('second')"])
            self.assertTrue(finished.wait(20), "restart after stop failed")
            self.assertIn("second", out)
            self.assertEqual(done, [0])
        finally:
            self._cleanup(runner)

    def test_stop_terminates_running_child_quickly(self):
        runner, out, _err, done, finished = self._make_runner()
        try:
            runner.start_command(
                [self.PY, "-c", "print('started', flush=True); import time; time.sleep(60)"]
            )
            deadline = time.time() + 10
            while not out and time.time() < deadline:
                time.sleep(0.02)
            self.assertTrue(out, "child never produced output")

            stopped_at = time.monotonic()
            runner.stop()
            self.assertTrue(finished.wait(10), "stop() did not lead to completion")
            elapsed = time.monotonic() - stopped_at
            self.assertLess(elapsed, 8, f"stop() took {elapsed:.1f}s")
            self.assertLess(done[0], 0, "child should have died by signal, not exited 0")
        finally:
            self._cleanup(runner)


class PythonExecutableTest(unittest.TestCase):
    """_python_executable: NETMAX_PYTHON env > /usr/bin/python3 > sys.executable."""

    def setUp(self):
        self._saved = os.environ.pop("NETMAX_PYTHON", None)

    def tearDown(self):
        if self._saved is not None:
            os.environ["NETMAX_PYTHON"] = self._saved
        else:
            os.environ.pop("NETMAX_PYTHON", None)

    def test_env_override_wins_when_path_exists(self):
        with tempfile.NamedTemporaryFile() as tmp:
            os.environ["NETMAX_PYTHON"] = tmp.name
            self.assertEqual(netmax_gui._python_executable(), tmp.name)

    def test_env_ignored_when_path_missing(self):
        os.environ["NETMAX_PYTHON"] = "/nonexistent/python-nowhere"
        # falls through to /usr/bin/python3 when present, else sys.executable
        result = netmax_gui._python_executable()
        if Path("/usr/bin/python3").exists():
            self.assertEqual(result, "/usr/bin/python3")
        else:
            self.assertEqual(result, sys.executable)

    def test_no_env_preferred_path(self):
        os.environ.pop("NETMAX_PYTHON", None)
        result = netmax_gui._python_executable()
        if Path("/usr/bin/python3").exists():
            self.assertEqual(result, "/usr/bin/python3")
        else:
            self.assertEqual(result, sys.executable)


class BuildCommandUsesPythonExecutable(unittest.TestCase):
    def test_build_command_first_arg_is_resolved_python(self):
        cmd = netmax_gui.build_command("baseline", 8, 10)
        self.assertEqual(cmd[0], netmax_gui._python_executable())
        self.assertTrue(cmd[1].endswith("netmax.py"))


class RunnerHandoffOfflineTest(unittest.TestCase):
    """_active pointer hand-off, exercised without spawning any process."""

    @staticmethod
    def _fake_proc(alive=True):
        proc = unittest.mock.MagicMock()
        proc.poll.return_value = 0 if not alive else None
        return proc

    def test_busy_follows_active_pointer(self):
        runner = netmax_gui.NetMaxRunner(lambda l: None, lambda l: None, lambda c: None)
        # no child → not busy
        self.assertFalse(runner.is_running())

        replacement = netmax_gui.NetMaxRunner(
            runner._on_stdout, runner._on_stderr, runner._on_done
        )
        fake = self._fake_proc(alive=True)
        replacement._proc = fake
        old = runner._active
        runner._active = replacement
        try:
            self.assertTrue(runner.is_running())          # busy via new active
            fake.poll.return_value = 0                    # child exited
            self.assertFalse(runner.is_running())         # no longer busy
        finally:
            runner._active = old

    def test_stop_targets_active_runner_child(self):
        runner = netmax_gui.NetMaxRunner(lambda l: None, lambda l: None, lambda c: None)
        replacement = netmax_gui.NetMaxRunner(
            runner._on_stdout, runner._on_stderr, runner._on_done
        )
        fake = self._fake_proc(alive=True)
        replacement._proc = fake
        old = runner._active
        runner._active = replacement
        try:
            runner.stop()
            fake.kill.assert_called_once()
            self.assertTrue(replacement._stop_requested)
            self.assertFalse(old._stop_requested)         # stale worker untouched
        finally:
            runner._active = old

    def test_join_active_joins_current_worker(self):
        runner = netmax_gui.NetMaxRunner(lambda l: None, lambda l: None, lambda c: None)
        target = unittest.mock.MagicMock()
        target.is_alive.return_value = True
        old = runner._active
        runner._active = target
        try:
            runner.join_active(timeout=0.01)
            target.join.assert_called_once_with(0.01)
        finally:
            runner._active = old

    def test_start_command_hands_off_to_fresh_runner_when_thread_dead(self):
        """Dead worker thread + start → _active repointed at a fresh runner."""
        runner = netmax_gui.NetMaxRunner(
            lambda l: None, lambda l: None, lambda c: None
        )
        # Never started ⇒ is_alive() is False ⇒ start_command must build a
        # replacement runner and repoint _active at it.
        import io
        fake_proc = unittest.mock.MagicMock()
        fake_proc.stdout = io.StringIO("second\n")
        fake_proc.stderr = io.StringIO("")
        fake_proc.wait.return_value = 0
        fake_proc.poll.return_value = 0

        with unittest.mock.patch.object(
            netmax_gui.subprocess, "Popen", return_value=fake_proc
        ) as popen:
            runner.start_command(["python", "netmax.py", "baseline"])
            popen.assert_called_once()

        active = runner._active
        try:
            self.assertIsNot(active, runner)              # hand-off happened
            self.assertTrue(active.is_alive())            # replacement running
            self.assertEqual(active._proc, fake_proc)
            active.stop()                                 # end its idle wait loop
            self.assertTrue(active.join(5) is None)
            self.assertFalse(active.is_alive())
            fake_proc.wait.assert_called()
        finally:
            runner.stop()

    def test_finish_once_fires_on_done_exactly_once(self):
        calls = []
        runner = netmax_gui.NetMaxRunner(
            lambda l: None, lambda l: None, lambda c: calls.append(c)
        )
        sentinel = object()  # stand-in for this runner's child proc
        runner._proc = sentinel
        runner._finish_once(0, sentinel)
        runner._finish_once(0, sentinel)                  # duplicate suppressed
        self.assertEqual(calls, [0])

    def test_finish_once_ignores_stale_worker(self):
        """A worker that no longer owns the current proc must not report done."""
        calls = []
        runner = netmax_gui.NetMaxRunner(
            lambda l: None, lambda l: None, lambda c: calls.append(c)
        )
        stale_proc, _new_proc = object(), object()
        # hand-off scenario: _active moved to a replacement, old proc still set
        replacement = netmax_gui.NetMaxRunner(lambda l: None, lambda l: None, lambda c: None)
        runner._active = replacement
        runner._finish_once(0, stale_proc)                # stale → swallowed
        self.assertEqual(calls, [])


class BuildCommandMatchesRealParser(unittest.TestCase):
    """Every generated argv must be accepted by netmax.py's argparse.

    Uses --help (parses args, exits 0) so no network measurement runs.
    """

    def test_all_modes_parse_with_real_argparse(self):
        import subprocess

        script = str(HERE / "netmax.py")
        cases = [
            netmax_gui.build_command("baseline", 8, 10),
            netmax_gui.build_command("turbo", 8, 10),
            netmax_gui.build_command("boost", 8, 10),
            netmax_gui.build_command("dns", 8, 10),
            netmax_gui.build_command("full", 8, 10),
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                help_argv = argv[:1] + [script] + argv[2:] + ["--help"]
                # argv layout: [python, script, mode, ...flags]; --help parses
                # args for that subcommand and exits 0 without measuring.
                proc = subprocess.run(help_argv, capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)


class BuildCommandUnchangedRegressionTest(unittest.TestCase):
    """D4 lane: build_command argv layout must be unchanged by GUI additions."""

    def test_turbo_layout_exact(self):
        cmd = netmax_gui.build_command("turbo", 8, 10)
        self.assertEqual(cmd[0], netmax_gui._python_executable())
        self.assertTrue(cmd[1].endswith("netmax.py"))
        self.assertEqual(cmd[2:], ["turbo", "--streams", "8", "--seconds", "10"])

    def test_dns_layout_exact(self):
        cmd = netmax_gui.build_command("dns", 8, 10)
        self.assertEqual(cmd[2:], ["dns"])

    def test_invalid_inputs_still_rejected(self):
        for args in (("warp", 8, 10), ("turbo", 99, 10), ("turbo", 8, 99)):
            with self.assertRaises(ValueError):
                netmax_gui.build_command(*args)


class FormatElapsedTest(unittest.TestCase):
    def test_under_a_minute(self):
        self.assertEqual(netmax_gui.format_elapsed(0), "elapsed 0s")
        self.assertEqual(netmax_gui.format_elapsed(42), "elapsed 42s")

    def test_minutes(self):
        self.assertEqual(netmax_gui.format_elapsed(65), "elapsed 1m 05s")
        self.assertEqual(netmax_gui.format_elapsed(600), "elapsed 10m 00s")

    def test_negative_clamped_to_zero(self):
        self.assertEqual(netmax_gui.format_elapsed(-3), "elapsed 0s")


class NewestResultsJsonTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _make_ts_dir(self, name):
        d = self.base / name
        d.mkdir(parents=True)
        return d

    def test_picks_lexically_newest_timestamp_dir(self):
        self._make_ts_dir("20260820_100000") / "results.json"
        (self._make_ts_dir("20260821_120000") / "results.json").write_text("{}")
        (self._make_ts_dir("20260819_090000") / "results.json").write_text("{}")
        got = netmax_gui.newest_results_json(self.base)
        self.assertIsNotNone(got)
        self.assertEqual(got.parent.name, "20260821_120000")

    def test_skips_dirs_without_results_json(self):
        self._make_ts_dir("20260822_010000")          # empty, no results.json
        good = self._make_ts_dir("20260820_100000")
        (good / "results.json").write_text("{}")
        got = netmax_gui.newest_results_json(self.base)
        self.assertEqual(got, good / "results.json")

    def test_missing_base_dir_returns_none(self):
        self.assertIsNone(netmax_gui.newest_results_json(self.base / "nope"))

    def test_no_dirs_returns_none(self):
        self.assertIsNone(netmax_gui.newest_results_json(self.base))


class SummarizeResultsJsonTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "results.json"

    def tearDown(self):
        self._tmp.cleanup()

    def test_flat_dict_summary_includes_keys_and_values(self):
        self.path.write_text('{"mode": "boost", "down_mbps": 940.2}')
        text = netmax_gui.summarize_results_json(self.path)
        self.assertIn("mode: boost", text)
        self.assertIn("down_mbps: 940.2", text)
        self.assertIn(str(self.path), text)

    def test_nested_values_are_counted_not_dumped(self):
        self.path.write_text('{"samples": [1, 2, 3], "meta": {"a": 1}}')
        text = netmax_gui.summarize_results_json(self.path)
        self.assertIn("list with 3 entries", text)
        self.assertIn("dict with 1 entries", text)
        self.assertNotIn("[1, 2, 3]", text)

    def test_invalid_json_reports_error_without_raising(self):
        self.path.write_text("{not json")
        text = netmax_gui.summarize_results_json(self.path)
        self.assertIn("could not parse", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
