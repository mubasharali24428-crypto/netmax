import XCTest
@testable import netmax_desktop

final class RemoteAISettingsTests: XCTestCase {
    func testProviderLabelMatchesConfiguredProviderPrecedence() {
        XCTAssertEqual(RemoteAIProviderLabel.resolve([:]), "OpenAI (default)")
        XCTAssertEqual(RemoteAIProviderLabel.resolve([
            "NETMAX_AI_PROVIDER": "  ClAuDe  ",
            "NETMAX_AI_BASE": "https://private.example/v1",
        ]), "Anthropic")
        XCTAssertEqual(RemoteAIProviderLabel.resolve([
            "NETMAX_AI_BASE": "http://127.0.0.1:1234/v1/chat/completions",
        ]), "Custom endpoint")
        XCTAssertEqual(RemoteAIProviderLabel.resolve([
            "NETMAX_AI_PROVIDER": "lmstudio",
        ]), "LM Studio local server")
    }

    func testSettingsDisclosureExactlyMatchesPayloadContract() {
        XCTAssertEqual(RemoteAISettingsDisclosure.metricsFields, [
            "mode", "streams", "duration_seconds", "download_mbps", "upload_mbps",
            "latency_ms", "jitter_ms", "packet_loss_percent", "bufferbloat_grade",
            "sample_count", "dns_latency_ms",
        ])
        XCTAssertTrue(RemoteAISettingsDisclosure.payloadSummary.hasPrefix(
            "schema_version, analysis_id, and metrics:"))
        XCTAssertTrue(RemoteAISettingsDisclosure.mcpConsent.contains("cannot enable or override"))
        XCTAssertTrue(RemoteAISettingsDisclosure.mcpConsent.contains("Local analysis remains available"))
    }
}
