import AppKit
import Foundation
import QuotaWire
import QuotaPresentation
import Testing

@testable import QuotaBar

@Test @MainActor
func loadsBundledProviderBrandSVGs() throws {
  for provider in ProviderID.allCases {
    let url = try #require(ProviderBrandAssets.resourceURL(for: provider))
    #expect(url.pathExtension == "svg")
    #expect(NSImage(contentsOf: url) != nil)
  }
  for assetName in ["azureai", "bedrock", "vertexai", "opencode", "pi"] {
    let url = try #require(ProviderBrandAssets.resourceURL(named: assetName))
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

private func usagePeriodJSON(cost: String) -> String {
  """
  {
    "totals": {
      "total_tokens": 1200,
      "input_tokens": 1000,
      "output_tokens": 200,
      "cache_read_input_tokens": 100,
      "cache_write_input_tokens": 0,
      "reasoning_tokens": 50,
      "messages": 1
    },
    "cost": \(cost),
    "partial": false,
    "agents": []
  }
  """
}

private let completeCostJSON = """
  {
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
  """

private func accountSummaryJSON() -> Data {
  Data(
    """
    {
      "protocol_version": 6,
      "account": {
        "account_id": "account_01",
        "display_label": "octocat",
        "created_at": "2026-07-01T00:00:00Z"
      },
      "devices": [{
        "id": "device_01",
        "display_name": "Kitchen Mac",
        "platform": "macos",
        "last_seen_at": "2026-08-02T01:00:00Z",
        "last_observed_at": "2026-08-02T00:30:00Z"
      }],
      "subscriptions": [],
      "usage": {
        "today": \(usagePeriodJSON(cost: completeCostJSON)),
        "last_7_days": \(usagePeriodJSON(cost: completeCostJSON)),
        "last_30_days": \(usagePeriodJSON(cost: completeCostJSON)),
        "all": \(usagePeriodJSON(cost: completeCostJSON))
      },
      "pricing_revision": "pricing_1",
      "model_catalog_revision": "models_1"
    }
    """.utf8
  )
}

@Test
func decodesAccountSummaryWithUsageCost() throws {
  let data = accountSummaryJSON()
  let summary = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: data)

  #expect(summary.protocolVersion == WireCodec.managedDataProtocolVersion)
  #expect(summary.devices.first?.id == "device_01")
  #expect(summary.usage.today.cost.amountMicrousd == "3138")
  #expect(summary.pricingRevision == "pricing_1")

  var expandedObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var expandedUsage = try #require(expandedObject["usage"] as? [String: Any])
  var today = try #require(expandedUsage["today"] as? [String: Any])
  var expandedCost = try #require(today["cost"] as? [String: Any])
  expandedCost["status"] = "partial"
  expandedCost["unpriced_rows"] = 1
  expandedCost["unpriced_truncated"] = true
  today["cost"] = expandedCost
  let structuredTotals: [String: Any] = [
    "total_tokens": 1200,
    "input_tokens": 1000,
    "output_tokens": 200,
    "cache_read_input_tokens": 100,
    "cache_write_input_tokens": 0,
    "reasoning_tokens": 50,
    "messages": 1,
  ]
  today["agents"] = [
    [
      "agent": "codex",
      "providers": [
        [
          "provider": "openai",
          "models": [
            ["model": "gpt-5.6-sol", "totals": structuredTotals, "cost": expandedCost]
          ],
        ]
      ],
    ]
  ]
  expandedUsage["today"] = today
  expandedObject["usage"] = expandedUsage
  let expandedData = try JSONSerialization.data(withJSONObject: expandedObject)
  let expanded = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: expandedData)
  #expect(expanded.usage.today.hasTruncatedDetails)
  #expect(expanded.usage.today.cost.unpricedRows == 1)
  #expect(
    expanded.usage.today.agents.first?.providers.first?.models.first?.model == "gpt-5.6-sol")

  var falseCostMarkerObject = expandedObject
  var falseCostMarkerUsage = try #require(falseCostMarkerObject["usage"] as? [String: Any])
  var falseCostMarkerToday = try #require(falseCostMarkerUsage["today"] as? [String: Any])
  var falseCostMarker = try #require(falseCostMarkerToday["cost"] as? [String: Any])
  falseCostMarker["unpriced_truncated"] = false
  falseCostMarkerToday["cost"] = falseCostMarker
  falseCostMarkerUsage["today"] = falseCostMarkerToday
  falseCostMarkerObject["usage"] = falseCostMarkerUsage
  let falseCostMarkerData = try JSONSerialization.data(withJSONObject: falseCostMarkerObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: falseCostMarkerData)
  }

  let missingRequiredNull = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: #""catalog_revision": "pricing_1","#,
      with: ""
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: missingRequiredNull)
  }

  // A Relay newer than this build can name a field anywhere in a read, at any depth.
  var nestedExtraObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var nestedExtraUsage = try #require(nestedExtraObject["usage"] as? [String: Any])
  nestedExtraUsage["settled_at"] = "2026-08-02T02:00:00Z"
  nestedExtraObject["usage"] = nestedExtraUsage
  let tolerated = try QuotaWireCodec.makeDecoder().decode(
    AccountSummary.self,
    from: try JSONSerialization.data(withJSONObject: nestedExtraObject)
  )
  #expect(tolerated.usage.today.cost.catalogRevision == "pricing_1")
}

@Test
func accountDeviceActivityUsesTheNewerOfLastSeenAndLastReading() throws {
  let now = try #require(ISO8601DateFormatter().date(from: "2026-08-15T08:10:00Z"))
  func decodeDevice(
    lastSeenAt: Any = "2026-08-15T08:00:05Z",
    lastObservedAt: Any = NSNull(),
    extra: [String: Any] = [:]
  ) throws -> AccountDevice {
    var value: [String: Any] = [
      "id": "device_01",
      "display_name": "Studio Mac",
      "platform": "macos",
      "last_seen_at": lastSeenAt,
      "last_observed_at": lastObservedAt,
    ]
    for (key, item) in extra {
      value[key] = item
    }
    return try QuotaWireCodec.makeDecoder().decode(
      AccountDevice.self,
      from: JSONSerialization.data(withJSONObject: value)
    )
  }

  // A field the contract retired reads as any other field this build does not name: ignored.
  let withRetiredField = try decodeDevice(extra: ["health": NSNull(), "status": "active"])
  #expect(withRetiredField.id == "device_01")

  // The verdict itself is `DeviceActivityTests`; what a decoded device owes it is both
  // witnessed instants, so a device quiet for a day but reporting minutes ago is still active.
  #expect(try decodeDevice().activity(now: now).status == .active)
  #expect(
    try decodeDevice(lastSeenAt: "2026-08-14T08:00:00Z", lastObservedAt: "2026-08-15T08:05:00Z")
      .activity(now: now).status == .active)
  #expect(try decodeDevice(lastSeenAt: NSNull()).activity(now: now).status == .notReporting)
}

@Test
func rejectsUnknownNestedLocalServiceStateFields() throws {
  let data = Data(
    #"""
    {
      "ipc_version": 1,
      "revision": 0,
      "usage_upload_enabled": true,
      "quota_refresh_interval_seconds": 300,
      "usage_periods": {"local": {}, "account": {}},
      "quota": {
        "status": "unavailable",
        "value": null,
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "usage": {
        "status": "unavailable",
        "value": null,
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "account": {
        "status": "signed_out",
        "value": {
          "auth_status": "signed_out",
          "account_id": null,
          "device_id": null,
          "device_generation": null,
          "account_summary": null
        },
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "pricing": {
        "status": "ready",
        "value": {
          "protocol_version": 2,
          "revision": "pricing_test",
          "published_at": "2026-08-10T00:00:00Z",
          "entries": []
        },
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "providers": [],
      "provider_browser_sessions": [],
      "overview": [],
      "cache": {
        "rebuilding": false,
        "reset_at": null
      }
    }
    """#.utf8
  )

  let state = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: data)
  #expect(state.pricing.value?.revision == "pricing_test")
  #expect(state.usageUploadEnabled)
  #expect(!state.cache.rebuilding)
  #expect(state.cache.resetAt == nil)

  let pricingExtra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"entries\": []",
      with: "\"entries\": [],\n      \"future_key\": {\"nested\": true}"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: pricingExtra)
  }

  let nestedExtra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"quota\": {\n    \"status\"",
      with: "\"quota\": {\n    \"extra\": true,\n    \"status\""
    ).utf8
  )
  #expect(String(decoding: nestedExtra, as: UTF8.self).contains("\"extra\""))
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: nestedExtra)
  }
}

@Test
func decodesCacheStateAndRejectsUnknownKeys() throws {
  let data = Data(
    #"""
    {
      "rebuilding": true,
      "reset_at": "2026-08-17T01:00:00Z"
    }
    """#.utf8
  )
  let cache = try QuotaWireCodec.makeDecoder().decode(LocalServiceCacheState.self, from: data)
  #expect(cache.rebuilding)
  #expect(cache.resetAt == Date(timeIntervalSince1970: 1_786_928_400))

  let extra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"reset_at\": \"2026-08-17T01:00:00Z\"",
      with: "\"reset_at\": \"2026-08-17T01:00:00Z\",\n      \"seq\": 4"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceCacheState.self, from: extra)
  }
}

@Test
func decodesABlockedDiagnosticReport() throws {
  let data = Data(
    #"""
    {
      "schema_version": 3,
      "generated_at": "2026-08-17T00:00:00Z",
      "client": { "name": "QuotaBar", "version": "0.0.17" },
      "summary": { "operation": "blocked", "attention": "required" },
      "surfaces": [
        { "id": "quota_overview", "status": "blocked", "data": "empty", "last_success_at": null,
          "message": "No quota has been read yet.", "recovery": "reinstall" },
        { "id": "usage_this_device", "status": "blocked", "data": "empty",
          "last_success_at": null, "message": "No Usage records yet.", "recovery": "reinstall" },
        { "id": "usage_account", "status": "inactive", "data": "empty", "last_success_at": null,
          "message": "Usage sync is off.", "recovery": "none" },
        { "id": "account", "status": "inactive", "data": "empty", "last_success_at": null,
          "message": "Not signed in.", "recovery": "none" }
      ],
      "sources": [
        {
          "subject": "local_state",
          "source_id": null,
          "status": "blocked",
          "last_attempt_at": "2026-08-17T00:00:00Z",
          "last_success_at": null,
          "code": "local_identity_reset",
          "message": "Local identity could not be read and was reset. Sign in again.",
          "recovery": "login"
        }
      ],
      "recent": []
    }
    """#.utf8
  )
  let report = try QuotaWireCodec.makeDecoder().decode(
    LocalServiceDiagnosticReport.self, from: data)
  #expect(report.isValid)
  #expect(report.summary.operation == .blocked)
  #expect(report.summary.attention == .required)
  #expect(
    report.surfaces.map(\.id)
      == ["quota_overview", "usage_this_device", "usage_account", "account"])
  #expect(report.sources.count == 1)
  #expect(report.sources[0].code == "local_identity_reset")
  #expect(report.sources[0].recovery == .login)
  #expect(report.textReport.contains("local_state"))
}

@Test
func decodesUnifiedDiagnosticsAndRejectsUnknownFields() throws {
  let data = Data(
    #"""
    {
      "schema_version":3,
      "generated_at":"2026-08-11T00:00:00Z",
      "client":{"name":"QuotaBar","version":"0.0.7"},
      "summary":{"operation":"healthy","attention":"required"},
      "surfaces":[
        {"id":"quota_overview","status":"ok","data":"current","last_success_at":"2026-08-11T00:00:00Z","message":"1 subscription shown.","recovery":"none"},
        {"id":"usage_this_device","status":"ok","data":"partial","last_success_at":null,"message":"Some Usage is incomplete.","recovery":"none"},
        {"id":"usage_account","status":"inactive","data":"empty","last_success_at":null,"message":"Usage sync is off.","recovery":"none"},
        {"id":"account","status":"ok","data":"current","last_success_at":"2026-08-11T00:00:00Z","message":"Signed in.","recovery":"none"}
      ],
      "sources":[{"subject":"agent:cursor","source_id":null,"status":"degraded","last_attempt_at":"2026-08-11T00:00:00Z","last_success_at":null,"code":"malformed_json","message":"Invalid Usage records were skipped and the valid ones were kept.","recovery":"update_source"}],
      "recent":[{"kind":"usage_scan","subject":"agent:cursor","started_at":"2026-08-11T00:00:00Z","duration_ms":12,"outcome":"partial","code":"malformed_data"}]
    }
    """#.utf8
  )
  let report = try QuotaWireCodec.makeDecoder().decode(
    LocalServiceDiagnosticReport.self, from: data)
  #expect(report.summary.operation == .healthy)
  #expect(report.surfaces.count == 4)
  #expect(report.sources.first?.subject == "agent:cursor")
  #expect(report.textReport.contains("agent:cursor"))
  #expect(report.textReport.contains("usage_scan/agent:cursor"))
  #expect(!report.textReport.contains("/Users/"))

  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object["future_key"] = true
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: object))
  }

  // A report whose surfaces are not the four fixed ones, in order, is not this contract.
  var reordered = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var surfaces = try #require(reordered["surfaces"] as? [[String: Any]])
  surfaces.reverse()
  reordered["surfaces"] = surfaces
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: reordered))
  }

  var missingMessage = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var missingMessageSources = try #require(missingMessage["sources"] as? [[String: Any]])
  missingMessageSources[0].removeValue(forKey: "message")
  missingMessage["sources"] = missingMessageSources
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: missingMessage))
  }

  // A subject is a catalog-owned name or nothing; a path can never reach the page.
  var unsafe = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var unsafeSources = try #require(unsafe["sources"] as? [[String: Any]])
  unsafeSources[0]["subject"] = "agent:/Users/private"
  unsafe["sources"] = unsafeSources
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: unsafe))
  }
}

@Test
func decodesLocalUsageReportShape() throws {
  let report = LocalUsageReport(
    generatedAt: Date(timeIntervalSince1970: 1_754_080_000),
    aggregationTimezone: nil,
    range: UsageDateRange(from: "2026-08-01", to: "2026-08-02"),
    status: .unavailable,
    coverage: []
  )
  let data = try QuotaWireCodec.makeEncoder().encode(report)
  let encodedText = String(decoding: data, as: UTF8.self)
  #expect(!encodedText.contains("\"today\""))
  #expect(!encodedText.contains("\"usage\""))
  let decoded = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: data)
  #expect(decoded.status == .unavailable)

  var missingRevisionObject = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any])
  missingRevisionObject.removeValue(forKey: "model_catalog_revision")
  let missingRevision = try JSONSerialization.data(withJSONObject: missingRevisionObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: missingRevision)
  }

  // The report states its coverage window by window; a marker for windows it left out is not
  // part of the contract, because one agent contributes one window and none are ever dropped.
  var retiredMarkerObject = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any])
  retiredMarkerObject["coverage_truncated"] = true
  let retiredMarker = try JSONSerialization.data(withJSONObject: retiredMarkerObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: retiredMarker)
  }
}

@Test
func decodesLocalUsagePeriodClientProviderModelSummary() throws {
  let summaryTotals = UsageSummaryTotals(
    totalTokens: 130,
    inputTokens: 100,
    outputTokens: 30,
    cacheReadInputTokens: 20,
    cacheWriteInputTokens: 0,
    reasoningTokens: 10,
    messages: 1
  )
  let cost = UsageCostOutcome(
    mode: .calculate,
    basis: .calculated,
    status: .complete,
    amountMicrousd: "0",
    catalogRevision: "pricing_1",
    calculatedRows: 1,
    reportedRows: 0,
    unpricedRows: 0,
    assumptions: [],
    unpriced: []
  )
  let model = LocalUsageModelSummary(
    model: "gpt-5.5",
    totals: summaryTotals,
    cost: cost
  )
  let provider = LocalUsageProviderSummary(
    provider: .openai,
    totals: summaryTotals,
    cost: cost,
    models: [model]
  )
  let client = LocalUsageAgentSummary(
    agent: .codex,
    totals: summaryTotals,
    cost: cost,
    providers: [provider]
  )
  let summary = LocalUsagePeriodSummary(
    totals: summaryTotals,
    cost: cost,
    agents: [client]
  )
  let data = try QuotaWireCodec.makeEncoder().encode(summary)
  let decoded = try QuotaWireCodec.makeDecoder().decode(LocalUsagePeriodSummary.self, from: data)
  #expect(decoded.totals == summaryTotals)
  #expect(decoded.agents.first?.agent == .codex)
  #expect(decoded.agents.first?.providers.first?.provider == .openai)
  #expect(decoded.agents.first?.providers.first?.models.first?.model == "gpt-5.5")
  #expect(decoded.agents.first?.providers.first?.models.first?.totals.messages == 1)

  var modelObject = try #require(
    JSONSerialization.jsonObject(with: QuotaWireCodec.makeEncoder().encode(model))
      as? [String: Any])
  modelObject["client"] = "codex"
  let retiredName = try JSONSerialization.data(withJSONObject: modelObject)
  let readAnyway = try QuotaWireCodec.makeDecoder().decode(
    LocalUsageModelSummary.self, from: retiredName)
  #expect(readAnyway.model == model.model)

  var nestedExtraObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  nestedExtraObject["extra"] = true
  let nestedExtra = try JSONSerialization.data(withJSONObject: nestedExtraObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsagePeriodSummary.self, from: nestedExtra)
  }
}

@Test
func decodesCursorBillingAgent() throws {
  let decoded = try QuotaWireCodec.makeDecoder().decode(
    BillingAgent.self,
    from: Data(#""cursor""#.utf8)
  )
  #expect(decoded == .cursor)
}

@Test
func decodesCollectionReportAndCalculatesRemainingQuota() throws {
  let data = Data(
    #"""
    {
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
          "status": "available",
          "observed_at": "2026-08-02T01:00:00Z"
        }],
        "source": "chatgpt_usage_api",
        "sources": [
          {"source_id": "chatgpt_usage_api", "outcome": "success", "category": "success"}
        ]
      }, {
        "provider": "cursor",
        "outcome": "auth_required",
        "snapshots": [],
        "message": "Sign in to Cursor again.",
        "sources": [
          {
            "source_id": "cursor_app_auth",
            "outcome": "auth_required",
            "category": "auth_required"
          },
          {"source_id": "browser_session", "outcome": "auth_required",
           "category": "auth_required"}
        ]
      }]
    }
    """#.utf8
  )

  let report = try QuotaWireCodec.makeDecoder().decode(QuotaCollectionReport.self, from: data)

  #expect(report.results.first?.snapshots.first?.windows.first?.remainingPercent == 84)
  #expect(report.results.first?.snapshots.first?.account.fingerprintScope == .source)
  #expect(report.results.last?.outcome == .authRequired)
  // Every rung is named, and the last one to fail is the one the reader is sent to.
  #expect(report.results.last?.sources.map(\.sourceID) == [
    "cursor_app_auth", "browser_session",
  ])
  #expect(report.results.last?.failingSource?.displayName == "Browser session")
  #expect(report.results.first?.failingSource == nil)
}

@Test
func rejectsCollectionResultWithoutSnapshots() {
  let data = Data(
    #"""
    {
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

/// One agent's rescanned hours, as QuotaBar restates the contract it uploads.
@Test
func decodesUsageUploadAndConservesTokenSubsets() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 6,
      "generation": 3,
      "agent": "codex",
      "hours": [{
        "bucket_start_utc": "2026-08-02T12:00:00Z",
        "scan_version": 7,
        "partial": false,
        "rows": [{
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
      }]
    }
    """#.utf8
  )

  let upload = try QuotaWireCodec.makeDecoder().decode(UsageUpload.self, from: data)
  #expect(upload.protocolVersion == WireCodec.managedDataProtocolVersion)
  #expect(upload.hours.first?.scanVersion == 7)
  #expect(upload.hours.first?.rows.first?.inputTokens == 1000)

  // An hour with nothing left in it is how a device says a scan found none.
  var emptyObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var emptyHours = try #require(emptyObject["hours"] as? [[String: Any]])
  emptyHours[0]["rows"] = []
  emptyHours[0]["partial"] = true
  emptyObject["hours"] = emptyHours
  let empty = try QuotaWireCodec.makeDecoder().decode(
    UsageUpload.self, from: try JSONSerialization.data(withJSONObject: emptyObject))
  #expect(empty.hours.first?.rows.isEmpty == true)
  #expect(empty.hours.first?.partial == true)

  var modelBoundaryObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var boundaryHours = try #require(modelBoundaryObject["hours"] as? [[String: Any]])
  var boundaryRows = try #require(boundaryHours[0]["rows"] as? [[String: Any]])
  boundaryRows[0]["model"] = String(repeating: "\u{1F600}", count: 128)
  boundaryHours[0]["rows"] = boundaryRows
  modelBoundaryObject["hours"] = boundaryHours
  _ = try QuotaWireCodec.makeDecoder().decode(
    UsageUpload.self, from: try JSONSerialization.data(withJSONObject: modelBoundaryObject))

  boundaryRows[0]["model"] = String(repeating: "\u{1F600}", count: 129)
  boundaryHours[0]["rows"] = boundaryRows
  modelBoundaryObject["hours"] = boundaryHours
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      UsageUpload.self, from: try JSONSerialization.data(withJSONObject: modelBoundaryObject))
  }

  let invalid = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: #""cache_read_tokens": 100"#,
      with: #""cache_read_tokens": 1001"#
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageUpload.self, from: invalid)
  }

  let invalidHour = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "2026-08-02T12:00:00Z",
      with: "2023-02-29T00:00:00Z"
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageUpload.self, from: invalidHour)
  }

  // Two rows with one identity are two answers to the same question.
  var duplicatedObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var duplicatedHours = try #require(duplicatedObject["hours"] as? [[String: Any]])
  var duplicatedRows = try #require(duplicatedHours[0]["rows"] as? [[String: Any]])
  duplicatedRows.append(try #require(duplicatedRows.first))
  duplicatedHours[0]["rows"] = duplicatedRows
  duplicatedObject["hours"] = duplicatedHours
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      UsageUpload.self, from: try JSONSerialization.data(withJSONObject: duplicatedObject))
  }

  // One hour named twice is not an hour this upload can replace.
  var repeatedObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var repeatedHours = try #require(repeatedObject["hours"] as? [[String: Any]])
  repeatedHours.append(try #require(repeatedHours.first))
  repeatedObject["hours"] = repeatedHours
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      UsageUpload.self, from: try JSONSerialization.data(withJSONObject: repeatedObject))
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
