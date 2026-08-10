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

@Test @MainActor
func loadsBundledQuotaBrandSVG() throws {
  let url = try #require(QuotaBrandAssets.menuBarResourceURL())
  #expect(url.pathExtension == "svg")
  let svg = try String(contentsOf: url, encoding: .utf8)
  #expect(svg.components(separatedBy: "<path").count == 3)
  #expect(!svg.contains("stroke-opacity"))
  let image = try #require(QuotaBrandAssets.menuBarTemplateImage())
  #expect(image.isTemplate)
  #expect(image.size == NSSize(width: 18, height: 18))
}

@Test
func decodesAccountSummaryWithUsageCost() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "generated_at": "2026-08-02T01:00:00Z",
      "account": {
        "account_id": "account_01",
        "display_label": "octocat",
        "created_at": "2026-07-01T00:00:00Z"
      },
      "devices": [{
        "device_id": "device_01",
        "display_name": "Kitchen Mac",
        "platform": "macos",
        "device_generation": 3,
        "status": "active",
        "created_at": "2026-07-01T00:00:00Z",
        "last_login_at": "2026-08-01T00:00:00Z",
        "last_seen_at": "2026-08-02T01:00:00Z",
        "signed_out_at": null
      }],
      "quota": [],
      "usage": {
        "range": { "from": "2026-08-01", "to": "2026-08-02" },
        "totals": {
          "input_tokens": 1000,
          "cache_read_tokens": 100,
          "cache_write_5m_tokens": 0,
          "cache_write_1h_tokens": 0,
          "cache_write_inferred_tokens": 0,
          "output_tokens": 200,
          "reasoning_tokens": 50,
          "requests": 1,
          "web_search_requests": 0,
          "web_fetch_requests": 0,
          "source_cost_microusd": null,
          "source_cost_covered_requests": 0
        },
        "cost": {
          "mode": "calculate",
          "basis": "calculated",
          "status": "complete",
          "amount_microusd": "3138",
          "catalog_revision": "pricing_1",
          "calculated_rows": 1,
          "reported_rows": 0,
          "unpriced_rows": 0,
          "assumptions": ["agent_default_channel"],
          "unpriced": []
        },
        "coverage": [],
        "breakdowns": []
      }
    }
    """#.utf8
  )

  let summary = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: data)

  #expect(summary.protocolVersion == 2)
  #expect(summary.devices.first?.deviceGeneration == 3)
  #expect(summary.usage.cost.amountMicrousd == "3138")

  let missingRequiredNull = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: #""catalog_revision": "pricing_1","#,
      with: ""
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: missingRequiredNull)
  }
}

@Test
func decodesStrictCLISyncOutcomeAndRejectsMissingAccountSummary() throws {
  let signedOut = Data(
    #"{"schema_version":2,"status":"signed_out","local_report":{"protocol_version":2,"captured_at":"2026-08-02T01:00:00Z","results":[]},"local_usage":{"protocol_version":2,"generated_at":"2026-08-02T01:00:00Z","aggregation_timezone":null,"range":{"from":"2026-07-04","to":"2026-08-02"},"status":"unavailable","totals":null,"cost":null,"coverage":[],"breakdowns":[]},"account_summary":null}"#
      .utf8
  )
  let output = try QuotaWireCodec.makeDecoder().decode(
    CLIAccountSyncOutput.self,
    from: signedOut
  )
  #expect(output.status == .signedOut)
  #expect(output.localReport.schemaVersion == 2)
  #expect(output.localUsage.status == .unavailable)

  let invalid = Data(
    #"{"schema_version":2,"status":"synced","local_report":{"protocol_version":2,"captured_at":"2026-08-02T01:00:00Z","results":[]},"local_usage":{"protocol_version":2,"generated_at":"2026-08-02T01:00:00Z","aggregation_timezone":null,"range":{"from":"2026-07-04","to":"2026-08-02"},"status":"unavailable","totals":null,"cost":null,"coverage":[],"breakdowns":[]},"account_summary":null}"#
      .utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(CLIAccountSyncOutput.self, from: invalid)
  }
}

@Test
func decodesAccountHourlyUsageResponse() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "start_at": "2026-08-02T12:00:00Z",
      "end_at": "2026-08-02T13:00:00Z",
      "facts": [{
        "device_id": "device_01",
        "aggregation_timezone": "Asia/Singapore",
        "bucket_start_utc": "2026-08-02T12:00:00Z",
        "usage_date": "2026-08-02",
        "usage_hour": 20,
        "agent": "codex",
        "billing_channel": "openai_direct",
        "channel_source": "agent_default",
        "model": "gpt-5",
        "context_bucket": "le_128k",
        "service_tier": "default",
        "speed": "standard",
        "inference_geo": "global",
        "input_tokens": 1000,
        "cache_read_tokens": 100,
        "cache_write_5m_tokens": 0,
        "cache_write_1h_tokens": 0,
        "cache_write_inferred_tokens": 0,
        "output_tokens": 200,
        "reasoning_tokens": 50,
        "requests": 1,
        "web_search_requests": 0,
        "web_fetch_requests": 0,
        "source_cost_covered_requests": 0
      }],
      "coverage": [{
        "device_id": "device_01",
        "agent": "codex",
        "start_at": "2026-08-02T12:00:00Z",
        "end_at": "2026-08-02T13:00:00Z",
        "status": "complete"
      }],
      "cost": {
        "mode": "calculate",
        "basis": "calculated",
        "status": "complete",
        "amount_microusd": "3138",
        "catalog_revision": "pricing_1",
        "calculated_rows": 1,
        "reported_rows": 0,
        "unpriced_rows": 0,
        "assumptions": ["agent_default_channel"],
        "unpriced": []
      }
    }
    """#.utf8
  )

  let response = try QuotaWireCodec.makeDecoder().decode(
    AccountUsageHourlyResponse.self,
    from: data
  )

  #expect(response.facts.first?.deviceID == "device_01")
  #expect(response.facts.first?.aggregationTimezone == "Asia/Singapore")
  #expect(response.cost.calculatedRows == response.facts.count)
}

@Test
func decodesQuotaSnapshotEnvelope() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "device_id": "device_01",
      "generation": 3,
      "sequence": 1,
      "captured_at": "2026-08-02T01:00:00Z",
      "snapshots": [{
        "provider": "codex",
        "account": {
          "fingerprint": "account_01",
          "fingerprint_scope": "global"
        },
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
  #expect(envelope.generation == 3)
  #expect(envelope.snapshots.first?.provider == .codex)
  #expect(envelope.snapshots.first?.account.fingerprintScope == .global)
}

@Test
func rejectsQuotaSnapshotWithoutFingerprintScope() {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "device_id": "device_01",
      "generation": 3,
      "sequence": 1,
      "captured_at": "2026-08-02T01:00:00Z",
      "snapshots": [{
        "provider": "codex",
        "account": { "fingerprint": "account_01" },
        "windows": [],
        "source": "codex_api",
        "status": "available",
        "observed_at": "2026-08-02T01:00:00Z"
      }]
    }
    """#.utf8
  )

  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(QuotaSnapshotEnvelope.self, from: data)
  }
}

@Test
func decodesCollectionReportAndCalculatesRemainingQuota() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "captured_at": "2026-08-02T01:00:00Z",
      "results": [{
        "provider": "codex",
        "outcome": "success",
        "snapshots": [{
          "provider": "codex",
          "account": {
            "fingerprint": "account_01",
            "fingerprint_scope": "source",
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

  #expect(report.schemaVersion == 2)
  #expect(report.results.first?.snapshots.first?.windows.first?.remainingPercent == 84)
  #expect(report.results.first?.snapshots.first?.account.fingerprintScope == .source)
  #expect(report.results.last?.outcome == .authRequired)
}

@Test
func rejectsCollectionResultWithoutSnapshots() {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
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

@Test
func rejectsLegacyQuotaEnvelopeVersionAndFieldName() {
  let data = Data(
    #"""
    {
      "schema_version": 1,
      "device_id": "device_01",
      "sequence": 1,
      "captured_at": "2026-08-02T01:00:00Z",
      "snapshots": []
    }
    """#.utf8
  )

  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(QuotaSnapshotEnvelope.self, from: data)
  }
}

@Test
func decodesIndependentQuotaAndUsageSyncSequences() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "account_id": "account_01",
      "device_id": "device_01",
      "device_generation": 3,
      "next_snapshot_sequence": 42,
      "next_usage_sequence": 8,
      "usage_deleted_before": null,
      "usage_sync_revision": 9
    }
    """#.utf8
  )

  let sync = try QuotaWireCodec.makeDecoder().decode(DeviceSyncResponse.self, from: data)
  #expect(sync.nextSnapshotSequence == 42)
  #expect(sync.nextUsageSequence == 8)
  #expect(sync.usageSyncRevision == 9)

  let missingWatermark = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: #""usage_deleted_before": null,"#,
      with: ""
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(DeviceSyncResponse.self, from: missingWatermark)
  }
}

@Test
func decodesUsageSubmissionAndConservesTokenSubsets() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "submission_id": "submission_01",
      "device_id": "device_01",
      "generation": 3,
      "sequence": 7,
      "parser_revision": "parser_1",
      "aggregation_timezone": "Asia/Singapore",
      "coverage": {
        "agent": "codex",
        "start_at": "2026-08-02T12:00:00Z",
        "end_at": "2026-08-02T13:00:00Z",
        "status": "complete"
      },
      "rows": [{
        "bucket_start_utc": "2026-08-02T12:00:00Z",
        "usage_date": "2026-08-02",
        "usage_hour": 20,
        "agent": "codex",
        "billing_channel": "openai_direct",
        "channel_source": "agent_default",
        "model": "gpt-5",
        "context_bucket": "le_128k",
        "service_tier": "default",
        "speed": "standard",
        "inference_geo": "global",
        "input_tokens": 1000,
        "cache_read_tokens": 100,
        "cache_write_5m_tokens": 0,
        "cache_write_1h_tokens": 0,
        "cache_write_inferred_tokens": 0,
        "output_tokens": 200,
        "reasoning_tokens": 50,
        "requests": 1,
        "web_search_requests": 0,
        "web_fetch_requests": 0,
        "source_cost_covered_requests": 0
      }]
    }
    """#.utf8
  )

  let submission = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: data)

  #expect(submission.protocolVersion == 2)
  #expect(submission.rows.first?.inputTokens == 1000)

  let invalid = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: #""cache_read_tokens": 100"#,
      with: #""cache_read_tokens": 1001"#
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: invalid)
  }

  let invalidHour = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "2026-08-02T12:00:00Z",
      with: "2023-02-29T00:00:00Z"
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: invalidHour)
  }

  var duplicatedObject = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  var duplicatedRows = try #require(duplicatedObject["rows"] as? [[String: Any]])
  duplicatedRows.append(try #require(duplicatedRows.first))
  duplicatedObject["rows"] = duplicatedRows
  let duplicatedData = try JSONSerialization.data(withJSONObject: duplicatedObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: duplicatedData)
  }
}

@Test
func decodesVersionedPricingCatalogWithoutRequiringBuiltInEntries() throws {
  let emptyData = Data(
    #"""
    {
      "protocol_version": 2,
      "revision": "pricing_empty",
      "published_at": "2026-08-02T00:00:00Z",
      "entries": []
    }
    """#.utf8
  )
  let empty = try QuotaWireCodec.makeDecoder().decode(PricingCatalog.self, from: emptyData)
  #expect(empty.entries.isEmpty)

  let data = Data(
    #"""
    {
      "protocol_version": 2,
      "revision": "pricing_1",
      "published_at": "2026-08-02T00:00:00Z",
      "entries": [{
        "entry_id": "openai_gpt_5_default",
        "billing_channel": "openai_direct",
        "model": "gpt-5",
        "aliases": ["gpt-5-latest"],
        "effective_from": "2026-08-01",
        "effective_to": null,
        "service_tier": "default",
        "speed": "standard",
        "inference_geo": "global",
        "context_bucket": "le_128k",
        "currency": "USD",
        "rates": {
          "uncached_input_per_million": "1.25",
          "cache_read_per_million": "0.125",
          "cache_write_5m_per_million": null,
          "cache_write_1h_per_million": null,
          "cache_write_inferred_per_million": null,
          "output_per_million": "10",
          "web_search_per_request": null,
          "web_fetch_per_request": null
        },
        "source_url": "https://example.com/pricing",
        "verified_at": "2026-08-02T00:00:00Z"
      }]
    }
    """#.utf8
  )

  let catalog = try QuotaWireCodec.makeDecoder().decode(PricingCatalog.self, from: data)
  #expect(catalog.entries.first?.rates.uncachedInputPerMillion == "1.25")
  #expect(catalog.entries.first?.sourceURL.scheme == "https")
}

@Test @MainActor
func refreshesMenuBarModelFromCLISync() async throws {
  let report = sampleCollectionReport()
  let model = MenuBarViewModel(
    client: StubLocalQuotaClient(report: report),
    reportCache: nil
  )

  await model.refresh()

  #expect(model.report == report)
  #expect(model.result(for: .grok)?.outcome == .success)
  guard
    case .content(let providers, _) = model.overviewState(
      enabledProviders: [.grok, .codex, .claude]
    )
  else {
    Issue.record("Expected Grok quota content")
    return
  }
  #expect(providers.map(\.provider) == [.grok, .codex, .claude])
  #expect(providers.first { $0.provider == .codex }?.status?.kind == .needsSignIn)
  #expect(providers.first { $0.provider == .codex }?.status?.detail == "Account setup required.")
  #expect(providers.first { $0.provider == .claude }?.status?.kind == .unavailable)
  #expect(
    providers.first { $0.provider == .claude }?.status?.detail
      == "The usage endpoint is temporarily unavailable."
  )
  #expect(providers.first { $0.provider == .grok }?.status == nil)
  #expect(providers.first { $0.provider == .grok }?.accounts.isEmpty == false)

  guard case .content(let codexOnly, _) = model.overviewState(enabledProviders: [.codex]) else {
    Issue.record("Expected Codex auth-required content")
    return
  }
  #expect(codexOnly.map(\.provider) == [.codex])
  #expect(codexOnly.first?.status?.kind == .needsSignIn)

  guard case .content(let claudeOnly, _) = model.overviewState(enabledProviders: [.claude]) else {
    Issue.record("Expected Claude unavailable content")
    return
  }
  #expect(claudeOnly.map(\.provider) == [.claude])
  #expect(model.errorMessage == nil)
  #expect(model.lastCheckedAt != nil)
}

@Test @MainActor
func restoresTheLastNormalizedReportBeforeRefreshing() async throws {
  let suiteName = "QuotaBarTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let cache = LocalQuotaReportCache(defaults: defaults)
  let report = sampleCollectionReport()
  let client = StubLocalQuotaClient(report: report)
  let firstModel = MenuBarViewModel(
    client: client,
    reportCache: cache
  )

  await firstModel.refresh()

  let restoredModel = MenuBarViewModel(
    client: client,
    reportCache: cache
  )
  #expect(restoredModel.report == report)
  #expect(restoredModel.lastCheckedAt != nil)
}

@Test @MainActor
func overviewStateDisplaysEveryAccountAndDerivesExpiredSnapshotsAsStale() async throws {
  let now = Date(timeIntervalSince1970: 1_754_112_000)
  let report = QuotaCollectionReport(
    schemaVersion: 2,
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
    client: StubLocalQuotaClient(report: report),
    reportCache: nil
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
func refreshFailureKeepsCachedAuthIssueAndShowsWarning() async throws {
  let suiteName = "QuotaBarTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let cache = LocalQuotaReportCache(defaults: defaults)
  cache.save(
    output: CLIAccountSyncOutput(
      status: .signedOut,
      localReport: sampleCollectionReport(),
      localUsage: sampleLocalUsageReport(),
      accountSummary: nil
    ),
    refreshedAt: .distantPast
  )
  let model = MenuBarViewModel(
    client: FailingLocalQuotaClient(),
    reportCache: cache
  )

  await model.refresh()

  guard
    case .content(let providers, let refreshWarning) = model.overviewState(enabledProviders: [
      .codex
    ])
  else {
    Issue.record("Expected cached auth-required content with a refresh warning")
    return
  }
  #expect(refreshWarning == "Synthetic collection failure.")
  #expect(providers.map(\.provider) == [.codex])
  #expect(providers.first?.status?.kind == .needsSignIn)
  #expect(providers.first?.status?.detail == "Account setup required.")
}

@Test @MainActor
func refreshCancellationDoesNotBecomeAUserVisibleError() async {
  let model = MenuBarViewModel(
    client: CancellingLocalQuotaClient(),
    reportCache: nil
  )

  await model.refresh()

  #expect(model.errorMessage == nil)
  #expect(!model.isRefreshing)
}

private struct StubLocalQuotaClient: LocalQuotaServing {
  let report: QuotaCollectionReport

  func sync() async throws -> CLIAccountSyncOutput {
    CLIAccountSyncOutput(
      status: .signedOut,
      localReport: report,
      localUsage: sampleLocalUsageReport(),
      accountSummary: nil
    )
  }

  func login() async throws -> CLIAccountAuthOutput { throw SyntheticCollectionError() }
  func logout() async throws -> CLIAccountAuthOutput { throw SyntheticCollectionError() }
  func accountSummary() async throws -> AccountSummary { throw SyntheticCollectionError() }
}

private struct FailingLocalQuotaClient: LocalQuotaServing {
  func sync() async throws -> CLIAccountSyncOutput {
    throw SyntheticCollectionError()
  }

  func login() async throws -> CLIAccountAuthOutput { throw SyntheticCollectionError() }
  func logout() async throws -> CLIAccountAuthOutput { throw SyntheticCollectionError() }
  func accountSummary() async throws -> AccountSummary { throw SyntheticCollectionError() }
}

private struct CancellingLocalQuotaClient: LocalQuotaServing {
  func sync() async throws -> CLIAccountSyncOutput {
    throw CancellationError()
  }

  func login() async throws -> CLIAccountAuthOutput { throw CancellationError() }
  func logout() async throws -> CLIAccountAuthOutput { throw CancellationError() }
  func accountSummary() async throws -> AccountSummary { throw CancellationError() }
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
    account: QuotaAccount(
      fingerprint: fingerprint,
      label: nil,
      plan: "Pro",
      fingerprintScope: .global
    ),
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

private func sampleLocalUsageReport() -> LocalUsageReport {
  LocalUsageReport(
    generatedAt: Date(timeIntervalSince1970: 1_754_112_000),
    aggregationTimezone: nil,
    range: UsageDateRange(from: "2026-07-04", to: "2026-08-02"),
    status: .unavailable,
    totals: nil,
    cost: nil,
    coverage: [],
    breakdowns: []
  )
}

private func sampleCollectionReport() -> QuotaCollectionReport {
  QuotaCollectionReport(
    schemaVersion: 2,
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
            account: QuotaAccount(
              fingerprint: "account_grok",
              label: nil,
              plan: "SuperGrok",
              fingerprintScope: .global
            ),
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
