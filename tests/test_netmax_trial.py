"""Tests for netmax_trial (hardware-bound trial fingerprinting).

Every platform interaction is driven by fake ``run`` callables plus an
explicit ``plat`` override — no real subprocess calls, no real registry reads.
"""

import hashlib
import re

from netmax_trial import hardware_uuid, machine_fingerprint, vm_suspected

UUID_A = "A1B2C3D4-E5F6-4789-ABCD-EF0123456789"
UUID_B = "00112233-4455-6677-8899-AABBCCDDEEFF"

IOREG_SAMPLE = """\
+-o IOPlatformExpertDevice  <class IOPlatformExpertDevice, id 0x10000010f, registered, matched, active, busy 0 (0 ms), retain 43>
  {
    "IOPlatformUUID" = "A1B2C3D4-E5F6-4789-ABCD-EF0123456789"
    "IOPlatformSerialNumber" = "C02XG0ABCD1234"
  }
"""

WMIC_SAMPLE = "UUID  \r\nA1B2C3D4-E5F6-4789-ABCD-EF0123456789  \r\n\r\n"


def make_fake(mapping):
    """Fake ``run``: argv joined by spaces -> canned stdout (or None)."""

    def fake(argv):
        return mapping.get(" ".join(argv))

    return fake


# ---------------------------------------------------------------------------
# hardware_uuid
# ---------------------------------------------------------------------------


def test_macos_uuid_parses_ioreg():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": IOREG_SAMPLE})
    assert hardware_uuid(run=run, plat="darwin") == UUID_A


def test_macos_uuid_none_when_ioreg_missing():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": None})
    assert hardware_uuid(run=run, plat="darwin") is None


def test_macos_uuid_none_when_no_uuid_line():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": "no uuid here"})
    assert hardware_uuid(run=run, plat="darwin") is None


def test_windows_uuid_parses_wmic_second_line():
    run = make_fake({"wmic csproduct get uuid": WMIC_SAMPLE})
    assert hardware_uuid(run=run, plat="win32") == UUID_A


def test_windows_uuid_none_when_wmic_empty():
    run = make_fake({"wmic csproduct get uuid": "UUID\n\n"})
    assert hardware_uuid(run=run, plat="win32") is None


def test_unsupported_platform_returns_none():
    assert hardware_uuid(run=make_fake({}), plat="linux") is None


# ---------------------------------------------------------------------------
# machine_fingerprint
# ---------------------------------------------------------------------------


def test_fingerprint_is_64_lowercase_hex():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": IOREG_SAMPLE})
    fp = machine_fingerprint(run=run, plat="darwin")
    assert re.fullmatch(r"[0-9a-f]{64}", fp)


def test_fingerprint_is_deterministic():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": IOREG_SAMPLE})
    assert machine_fingerprint(run=run, plat="darwin") == machine_fingerprint(
        run=run, plat="darwin"
    )


def test_fingerprint_matches_sha256_of_uuid_string():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": IOREG_SAMPLE})
    expected = hashlib.sha256(UUID_A.encode("utf-8")).hexdigest()
    assert machine_fingerprint(run=run, plat="darwin") == expected


def test_different_uuids_give_different_fingerprints():
    ioreg_b = IOREG_SAMPLE.replace(UUID_A, UUID_B)
    run_a = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": IOREG_SAMPLE})
    run_b = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": ioreg_b})
    assert machine_fingerprint(run=run_a, plat="darwin") != machine_fingerprint(
        run=run_b, plat="darwin"
    )


def test_raw_uuid_never_present_in_fingerprint():
    run = make_fake({"ioreg -rd1 -c IOPlatformExpertDevice": IOREG_SAMPLE})
    fp = machine_fingerprint(run=run, plat="darwin")
    assert UUID_A not in fp
    assert fp != UUID_A


def test_fingerprint_none_when_uuid_unavailable():
    assert machine_fingerprint(run=make_fake({}), plat="darwin") is None


# ---------------------------------------------------------------------------
# vm_suspected
# ---------------------------------------------------------------------------


def _macos_run(model, hv_vmm):
    return make_fake(
        {
            "sysctl -n hw.model": model,
            "sysctl -n kern.hv_vmm_present": hv_vmm,
        }
    )


def test_vm_suspected_macos_bare_metal():
    run = _macos_run("MacBookPro18,3", "0")
    assert vm_suspected(run=run, plat="darwin") is False


def test_vm_suspected_macos_vmware_model():
    run = _macos_run("VMware7,1", "0")
    assert vm_suspected(run=run, plat="darwin") is True


def test_vm_suspected_macos_hypervisor_present():
    run = _macos_run("MacBookPro18,3", "1")
    assert vm_suspected(run=run, plat="darwin") is True


def _windows_run(manufacturer_model, vendor):
    return make_fake(
        {
            "wmic computersystem get manufacturer,model": manufacturer_model,
            "wmic csproduct get vendor": vendor,
        }
    )


def test_vm_suspected_windows_bare_metal():
    run = _windows_run("Manufacturer  Model  \nLENOVO  20XWCTO1WW  \n\n", "Vendor  \nLENOVO  \n\n")
    assert vm_suspected(run=run, plat="win32") is False


def test_vm_suspected_windows_vmware():
    run = _windows_run(
        "Manufacturer  Model  \nVMware, Inc.  VMware Virtual Platform  \n\n",
        "Vendor  \nVMware, Inc.  \n\n",
    )
    assert vm_suspected(run=run, plat="win32") is True


def test_vm_suspected_linux_none_is_bare_metal():
    run = make_fake({"systemd-detect-virt": "none"})
    assert vm_suspected(run=run, plat="linux") is False


def test_vm_suspected_linux_kvm():
    run = make_fake({"systemd-detect-virt": "kvm"})
    assert vm_suspected(run=run, plat="linux") is True


def test_vm_suspected_graceful_when_commands_fail():
    run = make_fake({})
    assert vm_suspected(run=run, plat="darwin") is False
    assert vm_suspected(run=run, plat="win32") is False
    assert vm_suspected(run=run, plat="linux") is False


def test_vm_suspected_never_raises():
    def boom(argv):
        raise OSError("nope")

    for plat in ("darwin", "win32", "linux"):
        assert vm_suspected(run=boom, plat=plat) is False
