from netmax_export_manifest import generate_export_manifest

def test_generate_export_manifest():
    manifest = generate_export_manifest(["rec-123", "rec-456"])
    assert manifest["records_included"] == 2
    assert manifest["redaction_summary"]["pii_removed"] is True
    assert "formulas" in manifest["methodology"]
