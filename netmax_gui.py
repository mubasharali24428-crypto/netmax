#!/usr/bin/env python3
"""NetMax GUI — Tkinter desktop wrapper around the netmax CLI.

Design: the engine (netmax.py) runs as a subprocess so a hung network
measurement can never freeze the UI. Output is streamed back over thread-safe
callbacks and marshalled onto the Tk main loop via `root.after`.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
import time as _time
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

# ── theme (light page, dark header, purple accent — user's standard palette) ──
PAGE_BG = "#F4F5F7"
HEADER_BG = "#1F2635"
ACCENT = "#7C5A9B"
CARD_BG = "#FFFFFF"
TEXT_FG = "#1F2635"
MUTED_FG = "#6B7280"
MONO_FONT = ("Menlo", 11)

WINDOW_TITLE = "NetMax — Bandwidth Maximizer"

DISCLAIMER = (
    "No tool can exceed your ISP-provisioned cap — NetMax unlocks the "
    "speed your plan already pays for."
)

MODES = ("baseline", "turbo", "boost", "dns", "bloat", "full")

MODE_HELP = {
    "baseline": "Single-stream throughput — what ordinary apps get.",
    "turbo": "N parallel streams — bigger share under contention.",
    "boost": "Baseline + turbo + headroom verdict.",
    "dns": "Rank public DNS resolvers by latency.",
    "bloat": "Bufferbloat: latency increase under load, graded A+–F.",
    "full": "Everything above + TCP tuning notes.",
}

# Extra CLI-only v0.4 modes surfaced in a dropdown-adjacent menu label.
CLI_ONLY_MODES = {
    "upload": "Upload-speed probe (Mbps up).",
    "loss": "Packet-loss percent.",
    "jitter": "Jitter — mean consecutive RTT delta.",
    "wifi": "WiFi RSSI / noise / channel.",
    "export": "Export newest run as CSV/JSON.",
    "watch": "Continuous monitor (bloat+DNS per cycle).",
}

SCRIPT_PATH = Path(__file__).resolve().parent / "netmax.py"

STREAMS_MIN, STREAMS_MAX = 1, 32
SECONDS_MIN, SECONDS_MAX = 5, 30


def _python_executable() -> str:
    """Resolve engine interpreter: NETMAX_PYTHON env > known-good path > sys.

    The chosen interpreter is logged by the app on every Run (see on_run).
    """
    env = os.environ.get("NETMAX_PYTHON")
    if env and Path(env).exists():
        return env
    preferred = "/Users/user/1/bin/python"
    if Path(preferred).exists():
        return preferred
    return sys.executable


def _curl_available() -> bool:
    return shutil.which("curl") is not None


def build_command(mode: str, streams: int, seconds: int) -> list[str]:
    """Build the netmax.py argv for one run; validate all inputs first."""
    if mode not in MODES:
        raise ValueError(f"unknown mode {mode!r}; expected one of {MODES}")
    if not STREAMS_MIN <= streams <= STREAMS_MAX:
        raise ValueError(f"streams must be {STREAMS_MIN}..{STREAMS_MAX}, got {streams}")
    if not SECONDS_MIN <= seconds <= SECONDS_MAX:
        raise ValueError(f"seconds must be {SECONDS_MIN}..{SECONDS_MAX}, got {seconds}")

    cmd = [_python_executable(), str(SCRIPT_PATH), mode]
    if mode in ("turbo", "boost", "bloat", "full"):
        cmd += ["--streams", str(streams)]
    if mode != "dns":
        cmd += ["--seconds", str(seconds)]
    return cmd


RESULTS_DIR = Path(__file__).resolve().parent / "results"


def newest_results_json(results_dir: Path | None = None) -> Path | None:
    """Newest results/<ts>/results.json under results_dir, or None."""
    base = RESULTS_DIR if results_dir is None else results_dir
    try:
        candidates = sorted(
            (d for d in base.iterdir() if d.is_dir()),
            key=lambda d: d.name,
        )
    except OSError:
        return None
    for d in reversed(candidates):
        candidate = d / "results.json"
        if candidate.is_file():
            return candidate
    return None


def format_elapsed(seconds: int) -> str:
    """Window-title elapsed counter, e.g. 'elapsed 42s' / 'elapsed 1m 05s'."""
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"elapsed {seconds}s"
    return f"elapsed {seconds // 60}m {seconds % 60:02d}s"


def summarize_results_json(path: Path) -> str:
    """Short human-readable summary of a results.json for the export dialog."""
    import json

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return f"{path}\n\n(could not parse: {exc})"
    lines = [str(path), ""]
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, (dict, list)):
                value = f"<{type(value).__name__} with {len(value)} entries>"
            lines.append(f"{key}: {value}")
    else:
        lines.append(repr(data)[:2000])
    return "\n".join(lines[:40])


class NetMaxRunner(threading.Thread):
    """Runs one subprocess at a time; streams lines to callbacks.

    Callbacks fire on the runner's own threads — Tk callers must marshal
    back to the main loop themselves (the app below does, via root.after).
    """

    def __init__(
        self,
        on_stdout,
        on_stderr,
        on_done,
    ) -> None:
        super().__init__(daemon=True)
        self._on_stdout = on_stdout
        self._on_stderr = on_stderr
        self._on_done = on_done
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()
        self._stop_requested = False
        self._reported_proc = None
        # The runner whose worker loop currently owns any child. After a
        # thread hand-off this points at the replacement, so busy-checks,
        # stop(), and output attribution follow the live worker.
        self._active: "NetMaxRunner" = self

    # ── lifecycle ─────────────────────────────────────────────────────────────
    def _busy(self) -> bool:
        active = self._active
        return active._proc is not None and active._proc.poll() is None

    def start_command(self, argv: list[str]) -> None:
        replacement = None
        with self._lock:
            if self._busy():
                raise RuntimeError("a command is already running")
            proc = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            if self.is_alive():
                self._proc = proc
                self._stop_requested = False
            else:
                # A Thread object can only be started once; if the worker loop
                # exited after a prior stop(), hand off to a fresh runner.
                replacement = NetMaxRunner(self._on_stdout, self._on_stderr, self._on_done)
                replacement._proc = proc
                replacement._lock = threading.Lock()  # fresh lock for fresh worker
                self._active = replacement
        if replacement is not None:
            replacement.start()

    def stop(self) -> None:
        """Kill the running child (reported as negative exit code)."""
        with self._lock:
            active = self._active
            active._stop_requested = True
            proc = active._proc
        if proc is not None and proc.poll() is None:
            proc.kill()

    def join_active(self, timeout: float | None = None) -> None:
        """Join whichever worker thread currently owns the child."""
        with self._lock:
            active = self._active
        if active.is_alive():
            active.join(timeout)

    def is_running(self) -> bool:
        with self._lock:
            return self._busy()

    def _finish_once(self, code: int, proc) -> None:
        """Report completion exactly once per child process.

        Keyed on the proc instance, not a boolean flag — a stale worker's late
        completion must never be reported for a newer run (and must never
        swallow the new run's own completion).
        """
        with self._lock:
            if getattr(self, "_reported_proc", None) is proc:
                return
            if self._proc is not proc and self._active is not self:
                # this worker no longer owns the current child
                return
            self._reported_proc = proc
        self._on_done(code)

    # ── worker ────────────────────────────────────────────────────────────────
    def run(self) -> None:
        while True:
            with self._lock:
                proc = self._proc
                stopping = self._stop_requested
            if proc is None or stopping:
                return
            readers = [
                threading.Thread(target=self._pump, args=(proc.stdout, self._on_stdout), daemon=True),
                threading.Thread(target=self._pump, args=(proc.stderr, self._on_stderr), daemon=True),
            ]
            for t in readers:
                t.start()
            code = proc.wait()
            for t in readers:
                t.join(5)
            self._finish_once(code, proc)
            # If pumps are still draining, wait for them BEFORE clearing
            # _proc, so late lines stay attributed to this run.
            for t in readers:
                if t.is_alive():
                    t.join(10)
            with self._lock:
                if self._proc is proc:
                    self._proc = None
            if not self._wait_for_work():
                return

    @staticmethod
    def _pump(stream, sink) -> None:
        try:
            for line in stream:
                sink(line.rstrip("\n"))
        finally:
            stream.close()

    def _wait_for_work(self) -> bool:
        """Sleep until a new command arrives; quit only if idle and stopping."""
        import time as _time
        while True:
            with self._lock:
                if self._proc is not None:
                    return True
                if self._stop_requested:
                    return False
            _time.sleep(0.2)


class NetMaxApp:
    """Tk front-end: mode picker, streams/seconds spinners, live log."""

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self._user_stopped = False
        self._running = False
        self._elapsed_start = None
        root.title(WINDOW_TITLE)
        root.configure(bg=PAGE_BG)
        root.geometry("760x560")

        self.runner = NetMaxRunner(
            on_stdout=lambda line: root.after(0, self._append_out, line),
            on_stderr=lambda line: root.after(0, self._append_err, line),
            on_done=lambda code: root.after(0, self._on_done, code),
        )

        self._build_header()
        self._build_controls()
        self._build_progress()
        self._build_log()

    def _build_progress(self) -> None:
        """Determinate progress bar under the controls card.

        We get no real progress events from the engine, so the bar animates
        via a root.after ticker (pulse-style sweep) while a run is live.
        """
        bar_frame = tk.Frame(self.root, bg=PAGE_BG, padx=16)
        bar_frame.pack(fill="x", pady=(8, 0))
        self.progress = ttk.Progressbar(
            bar_frame, mode="determinate", maximum=100, value=0
        )
        self.progress.pack(fill="x")
        self.progress.set(0)

    # ── progress / elapsed ticker ─────────────────────────────────────────────
    def _start_progress(self) -> None:
        if self._running:
            return
        self._running = True
        self._elapsed_start = _time.monotonic()
        self.progress.configure(value=0)
        self._tick_progress()

    def _stop_progress(self) -> None:
        self._running = False
        self._elapsed_start = None
        self.progress.stop()
        self.progress.configure(value=100)
        self.root.title(WINDOW_TITLE)

    def _tick_progress(self) -> None:
        """root.after ticker: advance bar + elapsed-seconds in title."""
        if not self._running or self._elapsed_start is None:
            return
        elapsed = int(_time.monotonic() - self._elapsed_start)
        self.root.title(f"{WINDOW_TITLE} — {format_elapsed(elapsed)}")
        # No real progress events: sweep determinately up to 90% asymptotically.
        value = 90 * (1 - 2 ** (-elapsed / 5))
        self.progress.configure(value=value)
        self.root.after(250, self._tick_progress)

    def _build_header(self) -> None:
        header = tk.Frame(self.root, bg=HEADER_BG, padx=20, pady=14)
        header.pack(fill="x")
        tk.Label(
            header, text="⚡ NetMax", font=("Helvetica", 18, "bold"),
            bg=HEADER_BG, fg="#FFFFFF",
        ).pack(anchor="w")
        tk.Label(
            header, text=DISCLAIMER, wraplength=720, justify="left",
            bg=HEADER_BG, fg="#A9B2C3", font=("Helvetica", 10),
        ).pack(anchor="w", pady=(4, 0))

    def _build_controls(self) -> None:
        card = tk.Frame(self.root, bg=CARD_BG, padx=16, pady=12)
        card.pack(fill="x", padx=16, pady=(12, 0))

        tk.Label(card, text="Mode", bg=CARD_BG, fg=MUTED_FG).grid(row=0, column=0, sticky="w")
        self.mode_var = tk.StringVar(value="boost")
        self.mode_box = ttk.Combobox(
            card, textvariable=self.mode_var, values=list(MODES),
            state="readonly", width=12,
        )
        self.mode_box.grid(row=1, column=0, padx=(0, 24), sticky="w")
        self.mode_box.bind("<<ComboboxSelected>>", lambda _e: self._sync_mode_hint())

        tk.Label(card, text="Streams", bg=CARD_BG, fg=MUTED_FG).grid(row=0, column=1, sticky="w")
        self.streams_var = tk.IntVar(value=8)
        tk.Spinbox(
            card, from_=STREAMS_MIN, to=STREAMS_MAX, textvariable=self.streams_var, width=6
        ).grid(row=1, column=1, padx=(0, 24), sticky="w")

        tk.Label(card, text="Seconds", bg=CARD_BG, fg=MUTED_FG).grid(row=0, column=2, sticky="w")
        self.seconds_var = tk.IntVar(value=10)
        tk.Spinbox(
            card, from_=SECONDS_MIN, to=SECONDS_MAX, textvariable=self.seconds_var, width=6
        ).grid(row=1, column=2, sticky="w")

        self.run_btn = tk.Button(
            card, text="Run", command=self.on_run,
            bg=ACCENT, fg="#FFFFFF", activebackground="#6A4A85",
            relief="flat", padx=22, pady=4, font=("Helvetica", 11, "bold"),
        )
        self.run_btn.grid(row=1, column=3, padx=(24, 0), sticky="e")
        self.stop_btn = tk.Button(
            card, text="Stop", command=self.on_stop, state="disabled",
            bg=PAGE_BG, fg=TEXT_FG, relief="flat", padx=16,
        )
        self.stop_btn.grid(row=1, column=4, padx=(8, 0))
        self.export_btn = tk.Button(
            card, text="Export last result", command=self.on_export_last_result,
            bg=PAGE_BG, fg=TEXT_FG, relief="flat", padx=16,
        )
        self.export_btn.grid(row=1, column=5, padx=(8, 0))

        self.hint = tk.Label(card, text="", bg=CARD_BG, fg=MUTED_FG, wraplength=680, justify="left")
        self.hint.grid(row=2, column=0, columnspan=5, sticky="w", pady=(8, 0))
        self._sync_mode_hint()

    def _build_log(self) -> None:
        frame = tk.Frame(self.root, bg=CARD_BG, padx=8, pady=8)
        frame.pack(fill="both", expand=True, padx=16, pady=12)
        self.log = tk.Text(
            frame, bg="#10141D", fg="#D7DEEA", insertbackground="#FFFFFF",
            font=MONO_FONT, state="disabled", height=18, relief="flat",
        )
        scroll = ttk.Scrollbar(frame, command=self.log.yview)
        self.log.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.log.pack(fill="both", expand=True)

    def _append_out(self, line: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", line + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _append_err(self, line: str) -> None:
        self._append_out("[stderr] " + line)

    def _sync_mode_hint(self) -> None:
        self.hint.configure(text=MODE_HELP.get(self.mode_var.get(), ""))

    def _set_running(self, running: bool) -> None:
        self.run_btn.configure(state="disabled" if running else "normal")
        self.stop_btn.configure(state="normal" if running else "disabled")

    def on_run(self) -> None:
        if not _curl_available():
            self._append_out("netmax: curl not found on PATH — cannot measure.\n")
            return
        try:
            cmd = build_command(
                self.mode_var.get(), int(self.streams_var.get()), int(self.seconds_var.get())
            )
        except ValueError as exc:
            self._append_out(f"netmax: {exc}\n")
            return
        try:
            self.runner.start_command(cmd)
        except RuntimeError as exc:
            self._append_out(f"netmax: {exc}\n")
            return
        self._user_stopped = False
        self._set_running(True)
        self._start_progress()
        self._append_out(f"$ interpreter {cmd[0]}\n$ " + " ".join(cmd[2:]) + "\n")

    def on_export_last_result(self) -> None:
        path = newest_results_json()
        if path is None:
            messagebox.showinfo(
                "NetMax — Export last result",
                f"No results found under {RESULTS_DIR}.\nRun a measurement first.",
            )
            return
        messagebox.showinfo("NetMax — Export last result", summarize_results_json(path))

    def on_stop(self) -> None:
        self.runner.stop()
        self._user_stopped = True

    def _on_done(self, code: int) -> None:
        self._set_running(False)
        self._stop_progress()
        if getattr(self, "_user_stopped", False):
            self._user_stopped = False
            tail = "stopped by user"
        else:
            tail = "done" if code == 0 else f"exited ({code})"
        self._append_out(f"— {tail} —\n")

    def run(self) -> None:
        self.root.mainloop()


def main() -> None:
    root = tk.Tk()
    NetMaxApp(root).run()


if __name__ == "__main__":
    main()
