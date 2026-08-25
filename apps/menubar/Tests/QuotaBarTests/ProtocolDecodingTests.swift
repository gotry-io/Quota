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

@Test
func decodesAccountSummaryWithUsageCost() throws {
  let data = Data(
    #"""
    {
      "protocol_version": 5,
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
        "coverage": "complete",
        "breakdowns": []
      }
    }
    """#.utf8
  )

  let summary = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: data)

  #expect(summary.protocolVersion == WireCodec.managedDataProtocolVersion)
  #expect(summary.devices.first?.deviceGeneration == 3)
  #expect(summary.usage.cost.amountMicrousd == "3138")

  var expandedObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var expandedUsage = try #require(expandedObject["usage"] as? [String: Any])
  var expandedCost = try #require(expandedUsage["cost"] as? [String: Any])
  expandedCost["status"] = "partial"
  expandedCost["unpriced_rows"] = 1
  expandedCost["unpriced_truncated"] = true
  expandedUsage["cost"] = expandedCost
  expandedUsage["breakdowns_truncated"] = true
  let structuredTotals: [String: Any] = [
    "total_tokens": 1200,
    "input_tokens": 1000,
    "output_tokens": 200,
    "cache_read_input_tokens": 100,
    "cache_write_input_tokens": 0,
    "reasoning_tokens": 50,
    "messages": 1,
  ]
  expandedUsage["agents"] = [
    [
      "agent": "codex",
      "totals": structuredTotals,
      "cost": expandedCost,
      "providers": [
        [
          "provider": "openai",
          "totals": structuredTotals,
          "cost": expandedCost,
          "models": [
            [
              "model": "gpt-5.6-sol",
              "totals": structuredTotals,
              "cost": expandedCost,
            ]
          ],
        ]
      ],
    ]
  ]
  expandedObject["usage"] = expandedUsage
  let expandedData = try JSONSerialization.data(withJSONObject: expandedObject)
  let expanded = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: expandedData)
  #expect(expanded.usage.hasTruncatedDetails)
  #expect(expanded.usage.cost.hasUnpricedTruncatedDetails)
  #expect(expanded.usage.cost.unpricedRows == 1)
  #expect(expanded.usage.agents?.first?.providers.first?.models.first?.model == "gpt-5.6-sol")

  var falseMarkerObject = expandedObject
  var falseMarkerUsage = try #require(falseMarkerObject["usage"] as? [String: Any])
  falseMarkerUsage["breakdowns_truncated"] = false
  falseMarkerObject["usage"] = falseMarkerUsage
  let falseMarkerData = try JSONSerialization.data(withJSONObject: falseMarkerObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: falseMarkerData)
  }

  var falseCostMarkerObject = expandedObject
  var falseCostMarkerUsage = try #require(falseCostMarkerObject["usage"] as? [String: Any])
  var falseCostMarker = try #require(falseCostMarkerUsage["cost"] as? [String: Any])
  falseCostMarker["unpriced_truncated"] = false
  falseCostMarkerUsage["cost"] = falseCostMarker
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

  let nestedExtra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"usage\": {\n    \"range\"",
      with: "\"usage\": {\n    \"extra\": true,\n    \"range\""
    ).utf8
  )
  #expect(String(decoding: nestedExtra, as: UTF8.self).contains("\"extra\""))
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: nestedExtra)
  }
}

@Test
func accountDeviceActivityUsesTheNewerOfLastSeenAndLastReading() throws {
  let now = try #require(ISO8601DateFormatter().date(from: "2026-08-15T08:10:00Z"))
  func decodeDevice(
    status: String = "active",
    lastSeenAt: Any = "2026-08-15T08:00:05Z"
  ) throws -> AccountDevice {
    let value: [String: Any] = [
      "device_id": "device_01",
      "display_name": "Studio Mac",
      "platform": "macos",
      "device_generation": 1,
      "status": status,
      "created_at": "2026-08-01T00:00:00Z",
      "last_login_at": "2026-08-15T08:00:00Z",
      "last_seen_at": lastSeenAt,
      "signed_out_at": status == "signed_out" ? "2026-08-15T08:05:00Z" : NSNull(),
    ]
    return try QuotaWireCodec.makeDecoder().decode(
      AccountDevice.self,
      from: JSONSerialization.data(withJSONObject: value)
    )
  }

  // A device carrying an assertion about its own health is not part of the wire any more.
  var withHealth: [String: Any] = [
    "device_id": "device_01",
    "display_name": "Studio Mac",
    "platform": "macos",
    "device_generation": 1,
    "status": "active",
    "created_at": "2026-08-01T00:00:00Z",
    "last_login_at": "2026-08-15T08:00:00Z",
    "last_seen_at": "2026-08-15T08:00:05Z",
    "signed_out_at": NSNull(),
  ]
  withHealth["health"] = NSNull()
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      AccountDevice.self, from: JSONSerialization.data(withJSONObject: withHealth))
  }

  #expect(
    AccountDeviceActivity.status(for: try decodeDevice(), lastReadingAt: nil, now: now) == .active)
  #expect(
    AccountDeviceActivity.status(
      for: try decodeDevice(lastSeenAt: "2026-08-14T08:00:00Z"),
      lastReadingAt: try #require(ISO8601DateFormatter().date(from: "2026-08-15T08:05:00Z")),
      now: now) == .active)
  #expect(
    AccountDeviceActivity.status(
      for: try decodeDevice(lastSeenAt: "2026-08-15T05:00:00Z"), lastReadingAt: nil, now: now)
      == .idle)
  #expect(
    AccountDeviceActivity.status(
      for: try decodeDevice(lastSeenAt: "2026-08-12T05:00:00Z"), lastReadingAt: nil, now: now)
      == .notReporting)
  #expect(
    AccountDeviceActivity.status(
      for: try decodeDevice(lastSeenAt: NSNull()), lastReadingAt: nil, now: now) == .notReporting)
  #expect(
    AccountDeviceActivity.status(
      for: try decodeDevice(status: "signed_out"), lastReadingAt: nil, now: now) == .signedOut)
}

@Test
func validatesUsageBreakdownKeysByDimension() throws {
  let totals: [String: Any] = [
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
    "source_cost_microusd": NSNull(),
    "source_cost_covered_requests": 0,
  ]
  let cost: [String: Any] = [
    "mode": "calculate",
    "basis": "calculated",
    "status": "complete",
    "amount_microusd": "3138",
    "catalog_revision": "pricing_1",
    "calculated_rows": 1,
    "reported_rows": 0,
    "unpriced_rows": 0,
    "assumptions": ["agent_default_channel"],
    "unpriced": [],
  ]

  func decode(_ dimension: String, key: String) throws -> UsageBreakdown {
    let object: [String: Any] = [
      "dimension": dimension,
      "key": key,
      "totals": totals,
      "cost": cost,
    ]
    return try QuotaWireCodec.makeDecoder().decode(
      UsageBreakdown.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
  }

  let exactModel = try decode("model", key: "GPT-5.5[1m]")
  #expect(exactModel.key == "GPT-5.5[1m]")
  _ = try decode("agent", key: "codex")

  _ = try decode("model", key: String(repeating: "😀", count: 128))
  #expect(throws: DecodingError.self) {
    _ = try decode("model", key: String(repeating: "😀", count: 129))
  }
  #expect(throws: DecodingError.self) {
    _ = try decode("model", key: "GPT-5.5\n1m")
  }
}

@Test
func rejectsUnknownNestedLocalServiceStateFields() throws {
  let data = Data(
    #"""
    {
      "ipc_version": 1,
      "revision": 0,
      "usage_upload_enabled": true,
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
  let totals = UsageTokenTotals(
    inputTokens: 100,
    cacheReadTokens: 20,
    cacheWrite5mTokens: 0,
    cacheWrite1hTokens: 0,
    cacheWriteInferredTokens: 0,
    outputTokens: 30,
    reasoningTokens: 10,
    requests: 1,
    webSearchRequests: 0,
    webFetchRequests: 0,
    sourceCostMicrousd: "0",
    sourceCostCoveredRequests: 1
  )
  let summaryTotals = UsageSummaryTotals(totals)
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
  let duplicatedContext = try JSONSerialization.data(withJSONObject: modelObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalUsageModelSummary.self, from: duplicatedContext)
  }

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
        "provider": "claude",
        "outcome": "auth_required",
        "snapshots": [],
        "message": "Open Claude Code to refresh the sign-in.",
        "sources": [
          {
            "source_id": "anthropic_oauth_usage_api",
            "outcome": "auth_required",
            "category": "auth_required"
          },
          {"source_id": "claude_web_usage_api", "outcome": "auth_required",
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
    "anthropic_oauth_usage_api", "claude_web_usage_api",
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
      "protocol_version": 5,
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

  let submission = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: data)

  #expect(submission.protocolVersion == WireCodec.managedDataProtocolVersion)
  #expect(submission.rows.first?.inputTokens == 1000)

  var multipartObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var partialCoverage = try #require(multipartObject["coverage"] as? [String: Any])
  partialCoverage["status"] = "partial"
  multipartObject["coverage"] = partialCoverage
  multipartObject["write_mode"] = "merge_partial"
  multipartObject["multipart"] = [
    "batch_id": "batch_01",
    "part_index": 0,
    "part_count": 2,
  ]
  let multipartData = try JSONSerialization.data(withJSONObject: multipartObject)
  let multipart = try QuotaWireCodec.makeDecoder().decode(
    UsageSubmission.self, from: multipartData)
  #expect(multipart.writeMode == .mergePartial)
  #expect(multipart.multipart?.partIndex == 0)

  var modelBoundaryObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var modelBoundaryRows = try #require(modelBoundaryObject["rows"] as? [[String: Any]])
  modelBoundaryRows[0]["model"] = String(repeating: "😀", count: 128)
  modelBoundaryObject["rows"] = modelBoundaryRows
  let modelBoundaryData = try JSONSerialization.data(withJSONObject: modelBoundaryObject)
  _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: modelBoundaryData)

  modelBoundaryRows[0]["model"] = String(repeating: "😀", count: 129)
  modelBoundaryObject["rows"] = modelBoundaryRows
  let oversizedModelData = try JSONSerialization.data(withJSONObject: modelBoundaryObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: oversizedModelData)
  }

  var invalidMultipartObject = multipartObject
  invalidMultipartObject["multipart"] = [
    "batch_id": "batch_01",
    "part_index": 2,
    "part_count": 2,
  ]
  let invalidMultipartData = try JSONSerialization.data(withJSONObject: invalidMultipartObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: invalidMultipartData)
  }

  let invalid = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: #""cache_read_tokens": 100"#,
      with: #""cache_read_tokens": 1001"#
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: invalid)
  }

  let invalidHour = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "2026-08-02T12:00:00Z",
      with: "2023-02-29T00:00:00Z"
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: invalidHour)
  }

  var duplicatedObject = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  var duplicatedRows = try #require(duplicatedObject["rows"] as? [[String: Any]])
  duplicatedRows.append(try #require(duplicatedRows.first))
  duplicatedObject["rows"] = duplicatedRows
  let duplicatedData = try JSONSerialization.data(withJSONObject: duplicatedObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmission.self, from: duplicatedData)
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
