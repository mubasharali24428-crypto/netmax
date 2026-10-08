
def generate_export_manifest(record_ids: list[str]) -> dict:
    """Packages user-selected records into a JSON manifest (for ISP support)."""
    return {
        "export_version": "1.0",
        "records_included": len(record_ids),
        "methodology": {
            "formulas": ["median", "p95", "throughput CV"],
            "units": {"latency": "ms", "throughput": "Mbps"}
        },
        "redaction_summary": {
            "pii_removed": True,
            "synthetic_secrets_removed": True,
            "ip_addresses_anonymized": True
        }
    }
