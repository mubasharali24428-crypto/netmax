"""Evidence export (Gate G-03): the "prove it" step of the paid workflow.

Selects real measurement records from the canonical NetMax history, redacts
PII (IP addresses, MAC addresses, secrets), and bundles them as a JSON
manifest and/or a human-readable PDF evidence report.

Record IDs are deterministic: ``rec-<index>`` where <index> is the row's
position in the canonical history file.
"""

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

EXPORT_VERSION = "1.0"

RECORD_ID_RE = re.compile(r"^rec-(\d+)$")

_IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
# IPv6: full 8-group form, or any form containing "::" (compressed). Requiring
# "::" keeps clock strings like "10:30:00" from matching.
_IPV6_RE = re.compile(
    r"(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|\b[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4})*::[0-9a-fA-F:]*\b"
)
_MAC_RE = re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b")
_SECRET_KEY_PARTS = ("token", "secret", "password", "auth", "api_key", "apikey")


def canonical_history_path() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "NetMaxDesktop"
        / "history.jsonl"
    )


def read_history_rows(history_path: Optional[str] = None) -> List[Dict[str, Any]]:
    """Read history JSONL rows leniently (skip blank / malformed lines)."""
    path = Path(history_path) if history_path else canonical_history_path()
    rows: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict):
                rows.append(record)
    return rows


def record_id_for(index: int) -> str:
    return f"rec-{index}"


def select_records(
    record_ids: List[str], history_path: Optional[str] = None
) -> List[Tuple[str, Dict[str, Any]]]:
    """Resolve record IDs to (id, row) pairs. Raises ValueError on any bad ID."""
    if not record_ids:
        raise ValueError("no record IDs supplied")
    rows = read_history_rows(history_path)
    selected: List[Tuple[str, Dict[str, Any]]] = []
    for rid in record_ids:
        match = RECORD_ID_RE.match(str(rid))
        if not match:
            raise ValueError(
                f"invalid record id {rid!r}: expected 'rec-<index>'"
            )
        index = int(match.group(1))
        if index >= len(rows):
            raise ValueError(
                f"record id {rid!r} out of range: history holds {len(rows)} records"
            )
        selected.append((rid, rows[index]))
    return selected


def _is_secret_key(key: str) -> bool:
    lowered = key.lower()
    return any(part in lowered for part in _SECRET_KEY_PARTS)


def _redact_string(value: str, counts: Dict[str, int]) -> str:
    new_value, n = _IPV4_RE.subn("REDACTED-IP", value)
    counts["ips_anonymized"] += n
    new_value, n = _IPV6_RE.subn("REDACTED-IP", new_value)
    counts["ips_anonymized"] += n
    new_value, n = _MAC_RE.subn("REDACTED-MAC", new_value)
    counts["macs_removed"] += n
    return new_value


def _redact_value(value: Any, counts: Dict[str, int]) -> Any:
    if isinstance(value, str):
        return _redact_string(value, counts)
    if isinstance(value, dict):
        redacted: Dict[str, Any] = {}
        for key, item in value.items():
            if _is_secret_key(str(key)) and isinstance(item, str):
                redacted[key] = "REDACTED-SECRET"
                counts["secrets_removed"] += 1
            else:
                redacted[key] = _redact_value(item, counts)
        return redacted
    if isinstance(value, list):
        return [_redact_value(item, counts) for item in value]
    return value


def redact_record(row: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, int]]:
    """Return (redacted_copy, counts). The input row is never mutated."""
    counts = {"ips_anonymized": 0, "macs_removed": 0, "secrets_removed": 0}
    redacted = _redact_value(dict(row), counts)
    return redacted, counts


def _record_blob(record: Dict[str, Any]) -> str:
    return json.dumps(record, sort_keys=True, separators=(",", ":"))


def generate_export_manifest(
    record_ids: List[str], history_path: Optional[str] = None
) -> Dict[str, Any]:
    """Build the evidence manifest for the selected records."""
    selected = select_records(record_ids, history_path)
    totals = {"ips_anonymized": 0, "macs_removed": 0, "secrets_removed": 0}
    records = []
    for rid, row in selected:
        redacted, counts = redact_record(row)
        for key in totals:
            totals[key] += counts[key]
        blob = _record_blob(redacted)
        records.append(
            {
                "id": rid,
                "sha256": hashlib.sha256(blob.encode("utf-8")).hexdigest(),
                "record": redacted,
            }
        )
    return {
        "export_version": EXPORT_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "tool": "netmax evidence_export",
        "records_included": len(records),
        "records": records,
        "redaction_summary": {
            "pii_removed": True,
            "ips_anonymized": totals["ips_anonymized"],
            "macs_removed": totals["macs_removed"],
            "secrets_removed": totals["secrets_removed"],
            "synthetic_secrets_removed": totals["secrets_removed"] > 0,
            "ip_addresses_anonymized": totals["ips_anonymized"] > 0,
        },
        "methodology": {
            "formulas": [
                "median: middle value of sorted samples (mean of two middles for even n)",
                "p95: nearest-rank, ceil(0.95*n)-1 over sorted samples",
                "throughput CV: std/mean with sample variance (n-1)",
            ],
            "units": {"latency": "ms", "throughput": "Mbps"},
            "trust_rule": "trust reports require exactly 10 samples",
        },
    }


def manifest_to_json(manifest: Dict[str, Any]) -> str:
    return json.dumps(manifest, sort_keys=True, separators=(",", ":"))


# ── Minimal pure-stdlib PDF writer ──────────────────────────────────────────

def _pdf_escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    )


def _pdf_page_stream(lines: List[str]) -> bytes:
    ops = ["BT /F1 10 Tf 50 750 Td 13 TL"]
    for line in lines:
        ops.append(f"({_pdf_escape(line[:110])}) Tj T*")
    ops.append("ET")
    return "\n".join(ops).encode("latin-1", errors="replace")


def write_evidence_pdf(manifest: Dict[str, Any], out_path: str) -> str:
    """Write a human-readable evidence report PDF (pure stdlib)."""
    summary = manifest["redaction_summary"]
    body: List[str] = [
        "NetMax Evidence Report",
        f"Generated: {manifest['generated_at']}",
        f"Export version: {manifest['export_version']}",
        f"Records included: {manifest['records_included']}",
        "",
        "Records:",
    ]
    for entry in manifest["records"]:
        record = entry["record"]
        metrics = ", ".join(
            f"{k}={record[k]}" for k in ("mbps", "jitter_ms", "loss_pct") if k in record
        )
        body.append(f"  {entry['id']}  sha256:{entry['sha256'][:16]}...  {metrics}")
        body.append(f"    redacted: {_record_blob(record)[:160]}")
    body += [
        "",
        "Redaction summary:",
        f"  IPs anonymized: {summary['ips_anonymized']}",
        f"  MACs removed: {summary['macs_removed']}",
        f"  Secrets removed: {summary['secrets_removed']}",
        "",
        "Methodology:",
    ]
    for formula in manifest["methodology"]["formulas"]:
        body.append(f"  - {formula}")
    body.append(f"  Units: {manifest['methodology']['units']}")
    body.append(f"  Trust rule: {manifest['methodology']['trust_rule']}")

    per_page = 50
    pages = [body[i : i + per_page] for i in range(0, len(body), per_page)] or [[]]

    objects: List[bytes] = []
    objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    kid_refs = " ".join(f"{4 + i * 2} 0 R" for i in range(len(pages)))
    objects.append(f"<< /Type /Pages /Kids [{kid_refs}] /Count {len(pages)} >>".encode())
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for page_lines in pages:
        stream = _pdf_page_stream(page_lines)
        page_obj = len(objects) + 1
        content_obj = page_obj + 1
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {content_obj} 0 R >>".encode()
        )
        objects.append(
            f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream"
        )

    pdf = b"%PDF-1.4\n"
    offsets = []
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(pdf))
        pdf += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref_at = len(pdf)
    pdf += f"xref\n0 {len(objects) + 1}\n".encode()
    pdf += b"0000000000 65535 f \n"
    for off in offsets:
        pdf += f"{off:010d} 00000 n \n".encode()
    pdf += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_at}\n%%EOF\n"
    ).encode()

    Path(out_path).write_bytes(pdf)
    return out_path
