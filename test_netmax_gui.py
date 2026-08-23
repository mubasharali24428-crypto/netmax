"""Headless tests for netmax_gui.

These tests deliberately avoid creating Tk widgets so they run without a
display. Widget construction/layout is verified separately by a manual GUI
smoke run, which may fail in headless environments.
"""
import sys
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import netmax_gui  # noqa: E402  (must import cleanly with NO display present)


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
            set(netmax_gui.MODES), {"baseline", "turbo", "boost", "dns", "full"}
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
        for bad in (0, -1, 33, 100):
            with self.assertRaises(ValueError):
                netmax_gui.build_command("turbo", bad, 10)

    def test_streams_boundaries_accepted(self):
        for ok in (1, 32):
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
        runner, out, err, done, finished = self._make_runner()
        try:
            runner.start_command([self.PY, "-c", "import sys; sys.exit(3)"])
            self.assertTrue(finished.wait(20), "on_done was not called")
            self.assertEqual(done, [3])
        finally:
            self._cleanup(runner)

    def test_on_done_called_exactly_once_on_success(self):
        runner, out, err, done, finished = self._make_runner()
        try:
            runner.start_command([self.PY, "-c", "print('x')"])
            self.assertTrue(finished.wait(20))
            time.sleep(0.3)  # no late duplicate callbacks
            self.assertEqual(len(done), 1)
        finally:
            self._cleanup(runner)

    def test_second_start_while_alive_rejected(self):
        runner, out, err, done, finished = self._make_runner()
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
        runner, out, err, done, finished = self._make_runner()
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
        runner, out, err, done, finished = self._make_runner()
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
