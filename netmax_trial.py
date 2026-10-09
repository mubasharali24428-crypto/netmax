#!/usr/bin/env python3
"""Hardware-bound trial fingerprinting for NETMAX-APP (stdlib only).

PRIVACY RULE: the raw hardware UUID NEVER leaves the machine. The only
value ever transmitted, logged, or persisted off-device is its SHA-256 hex
digest (the "machine fingerprint"). This module has no network code at all —
it just derives the fingerprint and a best-effort VM signal.

The matching Swift track (TrialManager) implements activation, the signed
trial token, Keychain/DPAPI persistence, and offline grace. The shared
contract is:

    fingerprint = SHA-256 hex (64 lowercase chars) of the hardware UUID string
    token       = HMAC-SHA256(secret, f"{fp}|{trial_start}|{trial_end}")

Timestamps are UTC ISO ``YYYY-MM-DDTHH:MM:SSZ``.

All subprocess calls go through the injectable ``_run`` helper (and an
explicit ``plat`` override) so tests can drive every code path with fakes.
"""

from __future__ import annotations

import hashlib
import re
import subprocess
import sys
from typing import Callable, Optional

RunFn = Callable[[list], Optional[str]]

_IOREG_UUID_RE = re.compile(r'"IOPlatformUUID"\s*=\s*"([^"]+)"')
_WMIC_UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
                           r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

# Substrings that mark a machine as (probably) virtual. Matched
# case-insensitively against the platform's hardware model/vendor strings.
VM_MARKERS = (
    "vmware",
    "virtualbox",
    "parallels",
    "qemu",
    "kvm",
    "xen",
    "hyper-v",
    "bhyve",
)


def _run(argv: list) -> Optional[str]:
    """Run ``argv`` and return stdout stripped, or None on any failure."""
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def _macos_uuid(run: RunFn = _run) -> Optional[str]:
    out = run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
    if not out:
        return None
    match = _IOREG_UUID_RE.search(out)
    if not match:
        return None
    return match.group(1).strip() or None


def _windows_machine_guid(plat: str) -> Optional[str]:
    """HKLM\\SOFTWARE\\Microsoft\\Cryptography\\MachineGuid (wmic fallback)."""
    if plat != "win32":
        return None
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography"
        ) as key:
            value, _ = winreg.QueryValueEx(key, "MachineGuid")
        return str(value).strip() or None
    except Exception:
        return None


def _windows_uuid(run: RunFn = _run, plat: str = "win32") -> Optional[str]:
    out = run(["wmic", "csproduct", "get", "uuid"])
    if out:
        for line in out.splitlines():
            candidate = line.strip()
            if _WMIC_UUID_RE.match(candidate):
                return candidate
    return _windows_machine_guid(plat)


def hardware_uuid(
    run: RunFn = _run, plat: Optional[str] = None
) -> Optional[str]:
    """Return the platform hardware UUID string, or None if unavailable.

    macOS: parsed from ``ioreg -rd1 -c IOPlatformExpertDevice``
    (``IOPlatformUUID``). Windows: parsed from ``wmic csproduct get uuid``,
    falling back to the ``MachineGuid`` registry value.
    """
    plat = sys.platform if plat is None else plat
    if plat == "darwin":
        return _macos_uuid(run)
    if plat == "win32":
        return _windows_uuid(run, plat)
    # Linux and friends: no stable, stdlib-readable hardware UUID source.
    return None


def machine_fingerprint(
    run: RunFn = _run, plat: Optional[str] = None
) -> Optional[str]:
    """SHA-256 hex digest of the hardware UUID string (64 lowercase chars).

    This is the ONLY machine-identifying value that may leave the device.
    Returns None when no hardware UUID is available.
    """
    uuid = hardware_uuid(run=run, plat=plat)
    if not uuid:
        return None
    return hashlib.sha256(uuid.encode("utf-8")).hexdigest()


def _macos_vm(run: RunFn) -> bool:
    model = (run(["sysctl", "-n", "hw.model"]) or "").lower()
    if any(marker in model for marker in VM_MARKERS):
        return True
    hv_vmm = (run(["sysctl", "-n", "kern.hv_vmm_present"]) or "").strip()
    return hv_vmm == "1"


def _windows_bios_manufacturer(plat: str) -> Optional[str]:
    if plat != "win32":
        return None
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\BIOS"
        ) as key:
            value, _ = winreg.QueryValueEx(key, "SystemManufacturer")
        return str(value).strip().lower() or None
    except Exception:
        return None


def _windows_vm(run: RunFn, plat: str) -> bool:
    blobs = []
    for argv in (
        ["wmic", "computersystem", "get", "manufacturer,model"],
        ["wmic", "csproduct", "get", "vendor"],
    ):
        out = run(argv)
        if out:
            blobs.append(out.lower())
    blob = "\n".join(blobs)
    if any(marker in blob for marker in VM_MARKERS):
        return True
    bios = _windows_bios_manufacturer(plat)
    return bios is not None and any(marker in bios for marker in VM_MARKERS)


def _linux_vm(run: RunFn) -> bool:
    out = (run(["systemd-detect-virt"]) or "").strip().lower()
    return bool(out) and out != "none"


def vm_suspected(
    run: RunFn = _run, plat: Optional[str] = None
) -> bool:
    """Best-effort VM detection. True when the machine looks virtual.

    macOS: ``hw.model`` markers plus ``kern.hv_vmm_present``. Windows:
    ``wmic`` manufacturer/model/vendor markers plus the BIOS
    SystemManufacturer registry value. Linux: ``systemd-detect-virt``.
    Never raises; returns False when the signals are unavailable.
    """
    plat = sys.platform if plat is None else plat
    try:
        if plat == "darwin":
            return _macos_vm(run)
        if plat == "win32":
            return _windows_vm(run, plat)
        return _linux_vm(run)
    except Exception:
        return False
