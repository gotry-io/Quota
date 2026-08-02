import AppKit
import Foundation
import Testing

@testable import QuotaBar

@Test @MainActor
func loadsBundledProviderBrandSVGs() throws {
  for provider in ProviderID.allCases {
    let url = try #require(ProviderBrandAssets.resourceURL(for: provider))
    #expect(url.pathExtension == "svg")
    #expect(NSImage(contentsOf: url) != nil)
  }
}

@Test
func decodesRelayCapabilities() throws {
  let data = Data(
    #"""
    {
      "instance_id": "self-hosted-primary",
      "mode": "self_hosted",
      "version": "0.1.0",
      "api_versions": [1],
      "auth_methods": [],
      "capabilities": {
        "realtime": false,
        "persistent_snapshots": false,
        "instant_device_revocation": false,
        "history": false,
        "multi_tenant": false
      }
    }
    """#.utf8
  )

  let relayInfo = try QuotaWireCodec.makeDecoder().decode(RelayInfo.self, from: data)

  #expect(relayInfo.mode == .selfHosted)
  #expect(!relayInfo.capabilities.persistentSnapshots)
}

@Test
func decodesQuotaSnapshotEnvelope() throws {
  let data = Data(
    #"""
    {
      "schema_version": 1,
      "device_id": "device_01",
      "sequence": 1,
      "captured_at": "2026-08-02T01:00:00Z",
      "snapshots": [{
        "provider": "codex",
        "account": { "fingerprint": "account_01" },
        "windows": [{
          "id": "five_hour",
          "title": "5 hour",
          "used_percent": 20
        }],
        "source": "codex_api",
        "status": "available",
        "observed_at": "2026-08-02T01:00:00Z"
      }]
    }
    """#.utf8
  )

  let envelope = try QuotaWireCodec.makeDecoder().decode(QuotaSnapshotEnvelope.self, from: data)

  #expect(envelope.deviceID == "device_01")
  #expect(envelope.snapshots.first?.provider == .codex)
}

@Test
func decodesCollectionReportAndCalculatesRemainingQuota() throws {
  let data = Data(
    #"""
    {
      "schema_version": 1,
      "captured_at": "2026-08-02T01:00:00Z",
      "results": [{
        "provider": "codex",
        "outcome": "success",
        "snapshots": [{
          "provider": "codex",
          "account": {
            "fingerprint": "account_01",
            "label": "ad***@example.com",
            "plan": "pro"
          },
          "windows": [{
            "id": "weekly",
            "title": "Weekly",
            "used_percent": 16,
            "resets_at": "2026-08-08T01:00:00Z"
          }],
          "source": "chatgpt_usage_api",
          "status": "available",
          "observed_at": "2026-08-02T01:00:00Z"
        }],
        "source": "chatgpt_usage_api"
      }, {
        "provider": "claude",
        "outcome": "auth_required",
        "snapshots": [],
        "message": "Run `claude auth login`."
      }]
    }
    """#.utf8
  )

  let report = try QuotaWireCodec.makeDecoder().decode(QuotaCollectionReport.self, from: data)

  #expect(report.schemaVersion == 1)
  #expect(report.results.first?.snapshots.first?.windows.first?.remainingPercent == 84)
  #expect(report.results.last?.outcome == .authRequired)
}

@Test
func rejectsCollectionResultWithoutSnapshots() {
  let data = Data(
    #"""
    {
      "schema_version": 1,
      "captured_at": "2026-08-02T01:00:00Z",
      "results": [{
        "provider": "claude",
        "outcome": "auth_required"
      }]
    }
    """#.utf8
  )

  #expect(throws: DecodingError.self) {
    try QuotaWireCodec.makeDecoder().decode(QuotaCollectionReport.self, from: data)
  }
}

@Test @MainActor
func refreshesMenuBarModelFromLocalCollector() async throws {
  let report = sampleCollectionReport()
  let model = MenuBarViewModel(
    collector: StubLocalQuotaCollector(report: report),
    reportCache: nil,
    startsAutomatically: false
  )

  await model.refresh()

  #expect(model.report == report)
  #expect(model.result(for: .grok)?.outcome == .success)
  #expect(model.displayedProviders(enabledProviders: Set(ProviderID.allCases)) == [.grok])
  #expect(model.displayedProviders(enabledProviders: [.codex]).isEmpty)
  #expect(model.displayedProviders(enabledProviders: [.claude]).isEmpty)
  #expect(model.errorMessage == nil)
  #expect(model.refreshedAt != nil)
}

@Test @MainActor
func restoresTheLastNormalizedReportBeforeRefreshing() async throws {
  let suiteName = "QuotaBarTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let cache = LocalQuotaReportCache(defaults: defaults)
  let report = sampleCollectionReport()
  let collector = StubLocalQuotaCollector(report: report)
  let firstModel = MenuBarViewModel(
    collector: collector,
    reportCache: cache,
    startsAutomatically: false
  )

  await firstModel.refresh()

  let restoredModel = MenuBarViewModel(
    collector: collector,
    reportCache: cache,
    startsAutomatically: false
  )
  #expect(restoredModel.report == report)
  #expect(restoredModel.refreshedAt != nil)
}

private struct StubLocalQuotaCollector: LocalQuotaCollecting {
  let report: QuotaCollectionReport

  func collect() async throws -> QuotaCollectionReport {
    report
  }
}

private func sampleCollectionReport() -> QuotaCollectionReport {
  QuotaCollectionReport(
    schemaVersion: 1,
    capturedAt: Date(timeIntervalSince1970: 1_754_112_000),
    results: [
      QuotaCollectionResult(
        provider: .codex,
        outcome: .authRequired,
        snapshots: [],
        source: nil,
        message: "Run `codex` to log in."
      ),
      QuotaCollectionResult(
        provider: .claude,
        outcome: .unavailable,
        snapshots: [],
        source: "claude_oauth_usage_api",
        message: "The usage endpoint is temporarily unavailable."
      ),
      QuotaCollectionResult(
        provider: .grok,
        outcome: .success,
        snapshots: [
          QuotaSnapshot(
            provider: .grok,
            account: QuotaAccount(fingerprint: "account_grok", label: nil, plan: "SuperGrok"),
            windows: [
              QuotaWindow(
                id: "monthly",
                title: "Monthly",
                usedPercent: 25,
                resetsAt: Date(timeIntervalSince1970: 1_754_716_800),
                durationSeconds: nil
              )
            ],
            source: "grok_billing_api",
            status: .available,
            observedAt: Date(timeIntervalSince1970: 1_754_112_000),
            validUntil: nil
          )
        ],
        source: "grok_billing_api",
        message: nil
      ),
    ]
  )
}
