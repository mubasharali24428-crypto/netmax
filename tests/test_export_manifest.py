import json

import pytest

from netmax_export_manifest import (
    generate_export_manifest,
    manifest_to_json,
    record_id_for,
    redact_record,
    select_records,
    write_evidence_pdf,
)


@pytest.fixture()
def history_file(tmp_path):
    rows = [
        {
            "ts": 1700000000,
            "mode": "baseline",
            "result_raw": "Download: 95.5 Mbps from 192.168.1.10",
            "api_token": "sk-live-secret",
        },
        {
            "ts": 1700000060,
            "mode": "dns",
            "result_raw": "resolver 2001:db8::1 latency 12ms, host AA:BB:CC:DD:EE:FF",
        },
        {"ts": 1700000120, "mode": "baseline", "result_raw": "Download: 96.2 Mbps"},
    ]
    path = tmp_path / "history.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    return str(path)


def test_generate_export_manifest(history_file):
    manifest = generate_export_manifest(["rec-0", "rec-1"], history_path=history_file)
    assert manifest["records_included"] == 2
    assert manifest["redaction_summary"]["pii_removed"] is True
    assert "formulas" in manifest["methodology"]


def test_record_id_for():
    assert record_id_for(0) == "rec-0"
    assert record_id_for(41) == "rec-41"


def test_select_records_resolves_ids(history_file):
    selected = select_records(["rec-0", "rec-2"], history_path=history_file)
    assert [rid for rid, _ in selected] == ["rec-0", "rec-2"]
    assert selected[0][1]["ts"] == 1700000000


def test_select_records_rejects_malformed_ids(history_file):
    for bad in ["../../etc/passwd", "rec-", "rec-abc", "0", "", "rec-1;rm"]:
        with pytest.raises(ValueError, match="invalid record id"):
            select_records([bad], history_path=history_file)


def test_select_records_rejects_out_of_range(history_file):
    with pytest.raises(ValueError, match="out of range"):
        select_records(["rec-99"], history_path=history_file)


def test_select_records_rejects_empty():
    with pytest.raises(ValueError, match="no record IDs"):
        select_records([], history_path="/nonexistent.jsonl")


def test_redact_record_removes_real_pii():
    row = {
        "server": "speedtest 203.0.113.7",
        "v6": "peer 2001:db8::99 ok",
        "mac": "AA:BB:CC:DD:EE:FF",
        "api_token": "sk-abc123",
        "nested": {"password": "hunter2", "note": "call 10.0.0.5"},
        "mbps": 95.5,
    }
    redacted, counts = redact_record(row)
    blob = json.dumps(redacted)
    assert "203.0.113.7" not in blob
    assert "2001:db8::99" not in blob
    assert "AA:BB:CC:DD:EE:FF" not in blob
    assert "sk-abc123" not in blob and "hunter2" not in blob
    assert "REDACTED-IP" in blob and "REDACTED-MAC" in blob and "REDACTED-SECRET" in blob
    assert counts["ips_anonymized"] >= 3
    assert counts["macs_removed"] == 1
    assert counts["secrets_removed"] == 2
    # Non-PII data survives; input not mutated.
    assert redacted["mbps"] == 95.5
    assert "203.0.113.7" in json.dumps(row)


def test_redact_record_ignores_clock_strings():
    # "10:30:00" must not be treated as IPv6.
    redacted, counts = redact_record({"note": "run at 10:30:00 finished"})
    assert redacted["note"] == "run at 10:30:00 finished"
    assert counts["ips_anonymized"] == 0


def test_generate_export_manifest_real_records(history_file):
    manifest = generate_export_manifest(["rec-0", "rec-1"], history_path=history_file)
    assert manifest["records_included"] == 2
    assert manifest["export_version"] == "1.0"
    assert manifest["generated_at"]
    rec0 = manifest["records"][0]
    assert rec0["id"] == "rec-0"
    assert len(rec0["sha256"]) == 64
    assert "192.168.1.10" not in manifest_to_json(manifest)
    summary = manifest["redaction_summary"]
    assert summary["ips_anonymized"] >= 2  # v4 in rec-0, v6 in rec-1
    assert summary["secrets_removed"] == 1
    assert summary["macs_removed"] == 1


def test_write_evidence_pdf(history_file, tmp_path):
    manifest = generate_export_manifest(["rec-0"], history_path=history_file)
    out = str(tmp_path / "evidence.pdf")
    write_evidence_pdf(manifest, out)
    data = open(out, "rb").read()
    assert data.startswith(b"%PDF-1.4")
    assert b"NetMax Evidence Report" in data
    assert b"REDACTED-SECRET" in data  # redacted record detail line
    assert b"IPs anonymized: 1" in data  # redaction summary line
    assert data.rstrip().endswith(b"%%EOF")
