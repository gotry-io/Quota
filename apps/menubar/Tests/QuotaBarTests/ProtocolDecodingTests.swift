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
  guard
    case .content(let providers, _) = model.overviewState(
      enabledProviders: Set(ProviderID.allCases)
    )
  else {
    Issue.record("Expected Grok quota content")
    return
  }
  #expect(providers.map(\.provider) == [.grok])
  #expect(model.overviewState(enabledProviders: [.codex]) == .empty(refreshWarning: nil))
  #expect(model.overviewState(enabledProviders: [.claude]) == .empty(refreshWarning: nil))
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

@Test @MainActor
func overviewStateDisplaysEveryAccountAndDerivesExpiredSnapshotsAsStale() async throws {
  let now = Date(timeIntervalSince1970: 1_754_112_000)
  let report = QuotaCollectionReport(
    schemaVersion: 1,
    capturedAt: now,
    results: [
      QuotaCollectionResult(
        provider: .codex,
        outcome: .success,
        snapshots: [
          sampleSnapshot(
            provider: .codex,
            fingerprint: "account_current",
            validUntil: now.addingTimeInterval(300)
          ),
          sampleSnapshot(
            provider: .codex,
            fingerprint: "account_expired",
            validUntil: now.addingTimeInterval(-1)
          ),
        ],
        source: "chatgpt_usage_api",
        message: nil
      )
    ]
  )
  let model = MenuBarViewModel(
    collector: StubLocalQuotaCollector(report: report),
    reportCache: nil,
    startsAutomatically: false
  )

  await model.refresh()

  guard
    case .content(let providers, let refreshWarning) = model.overviewState(
      enabledProviders: [.codex],
      now: now
    )
  else {
    Issue.record("Expected quota content")
    return
  }
  #expect(refreshWarning == nil)
  #expect(providers.count == 1)
  #expect(providers.first?.accounts.count == 2)
  #expect(providers.first?.accounts.map(\.isStale) == [false, true])
}

@Test @MainActor
func emptyOverviewPreservesARefreshFailureWarning() async throws {
  let suiteName = "QuotaBarTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let cache = LocalQuotaReportCache(defaults: defaults)
  cache.save(report: sampleCollectionReport(), refreshedAt: .distantPast)
  let model = MenuBarViewModel(
    collector: FailingLocalQuotaCollector(),
    reportCache: cache,
    startsAutomatically: false
  )

  await model.refresh()

  guard case .empty(let refreshWarning) = model.overviewState(enabledProviders: [.codex]) else {
    Issue.record("Expected an empty overview")
    return
  }
  #expect(refreshWarning == "Synthetic collection failure.")
}

@Test @MainActor
func refreshCancellationDoesNotBecomeAUserVisibleError() async {
  let model = MenuBarViewModel(
    collector: CancellingLocalQuotaCollector(),
    reportCache: nil,
    startsAutomatically: false
  )

  await model.refresh()

  #expect(model.errorMessage == nil)
  #expect(!model.isRefreshing)
}

private struct StubLocalQuotaCollector: LocalQuotaCollecting {
  let report: QuotaCollectionReport

  func collect() async throws -> QuotaCollectionReport {
    report
  }
}

private struct FailingLocalQuotaCollector: LocalQuotaCollecting {
  func collect() async throws -> QuotaCollectionReport {
    throw SyntheticCollectionError()
  }
}

private struct CancellingLocalQuotaCollector: LocalQuotaCollecting {
  func collect() async throws -> QuotaCollectionReport {
    throw CancellationError()
  }
}

private struct SyntheticCollectionError: LocalizedError {
  var errorDescription: String? { "Synthetic collection failure." }
}

private func sampleSnapshot(
  provider: ProviderID,
  fingerprint: String,
  validUntil: Date?
) -> QuotaSnapshot {
  QuotaSnapshot(
    provider: provider,
    account: QuotaAccount(fingerprint: fingerprint, label: nil, plan: "Pro"),
    windows: [
      QuotaWindow(
        id: "weekly",
        title: "Weekly",
        usedPercent: 25,
        resetsAt: nil,
        durationSeconds: nil
      )
    ],
    source: "synthetic",
    status: .available,
    observedAt: Date(timeIntervalSince1970: 1_754_112_000),
    validUntil: validUntil
  )
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
