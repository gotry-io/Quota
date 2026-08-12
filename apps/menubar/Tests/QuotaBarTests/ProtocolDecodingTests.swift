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

  var expandedObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var expandedUsage = try #require(expandedObject["usage"] as? [String: Any])
  var expandedCost = try #require(expandedUsage["cost"] as? [String: Any])
  expandedCost["status"] = "partial"
  expandedCost["unpriced_rows"] = 1
  expandedCost["unpriced_truncated"] = true
  expandedUsage["cost"] = expandedCost
  expandedUsage["coverage_truncated"] = true
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
  expandedUsage["clients"] = [[
    "client": "codex",
    "totals": structuredTotals,
    "cost": expandedCost,
    "providers": [[
      "provider": "openai",
      "totals": structuredTotals,
      "cost": expandedCost,
      "models": [[
        "model": "gpt-5.6-sol",
        "totals": structuredTotals,
        "cost": expandedCost,
      ]],
    ]],
  ]]
  expandedObject["usage"] = expandedUsage
  let expandedData = try JSONSerialization.data(withJSONObject: expandedObject)
  let expanded = try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: expandedData)
  #expect(expanded.usage.hasTruncatedDetails)
  #expect(expanded.usage.cost.hasUnpricedTruncatedDetails)
  #expect(expanded.usage.cost.unpricedRows == 1)
  #expect(expanded.usage.clients?.first?.providers.first?.models.first?.model == "gpt-5.6-sol")

  var falseMarkerObject = expandedObject
  var falseMarkerUsage = try #require(falseMarkerObject["usage"] as? [String: Any])
  falseMarkerUsage["coverage_truncated"] = false
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
      "overview": []
    }
    """#.utf8
  )

  let state = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: data)
  #expect(state.pricing.value?.revision == "pricing_test")
  #expect(state.usageUploadEnabled)

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
func decodesUnifiedDiagnosticsAndRejectsUnknownFields() throws {
  let data = Data(
    #"""
    {
      "schema_version": 1,
      "status": "healthy",
      "generated_at": "2026-08-11T00:00:00Z",
      "client": {"name": "QuotaBar", "version": "0.0.7"},
      "components": [
        {"name": "providers", "status": "ready", "message": null, "metrics": {}},
        {"name": "quota", "status": "ready", "message": null, "metrics": {}},
        {"name": "usage", "status": "ready", "message": "safe source note", "metrics": {"files": 1}},
        {"name": "pricing", "status": "ready", "message": null, "metrics": {}},
        {"name": "account", "status": "ready", "message": null, "metrics": {}},
        {"name": "sync", "status": "ready", "message": null, "metrics": {}}
      ],
      "issues": []
    }
    """#.utf8
  )

  let report = try QuotaWireCodec.makeDecoder().decode(
    LocalServiceDiagnosticReport.self, from: data
  )
  #expect(report.status == .healthy)
  #expect(report.components.count == 6)
  #expect(report.components.first(where: { $0.name == "usage" })?.metrics["files"] == 1)
  #expect(report.textReport.contains("Diagnostics: healthy"))
  #expect(report.textReport.contains("usage\tready"))
  #expect(report.textReport.contains("safe source note"))
  #expect(report.textReport.contains("files=1"))
  #expect(report.jsonReport.contains("\"schema_version\":1"))
  #expect(!report.jsonReport.contains("/Users/"))

  var issueObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  issueObject["status"] = "degraded"
  issueObject["issues"] = [
    [
      "component": "usage",
      "code": "scan_partial",
      "severity": "warning",
      "count": 2,
      "message": "some sources are incomplete",
    ]
  ]
  let issueData = try JSONSerialization.data(withJSONObject: issueObject)
  let issueReport = try QuotaWireCodec.makeDecoder().decode(
    LocalServiceDiagnosticReport.self, from: issueData
  )
  #expect(issueReport.textReport.contains("usage/scan_partial (2)"))
  #expect(issueReport.textReport.contains("some sources are incomplete"))

  let extra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"issues\": []",
      with: "\"issues\": [], \"future_key\": true"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceDiagnosticReport.self, from: extra)
  }

  var invalidStatus = issueObject
  var invalidStatusComponents = try #require(invalidStatus["components"] as? [[String: Any]])
  invalidStatusComponents[0]["status"] = "unknown"
  invalidStatus["components"] = invalidStatusComponents
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: invalidStatus)
    )
  }

  var invalidMetric = issueObject
  var invalidMetricComponents = try #require(invalidMetric["components"] as? [[String: Any]])
  invalidMetricComponents[2]["metrics"] = ["files": 1_000_001]
  invalidMetric["components"] = invalidMetricComponents
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: invalidMetric)
    )
  }

  var invalidCount = issueObject
  var invalidIssues = try #require(invalidCount["issues"] as? [[String: Any]])
  invalidIssues[0]["count"] = 0
  invalidCount["issues"] = invalidIssues
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: invalidCount)
    )
  }

  var unsafeMessage = issueObject
  var unsafeMessageComponents = try #require(unsafeMessage["components"] as? [[String: Any]])
  unsafeMessageComponents[2]["message"] = "safe\nspoof"
  unsafeMessage["components"] = unsafeMessageComponents
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalServiceDiagnosticReport.self,
      from: JSONSerialization.data(withJSONObject: unsafeMessage)
    )
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
        "agent": "grok",
        "billing_channel": "xai_direct",
        "channel_source": "agent_default",
        "model": "grok-4.5",
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
        "agent": "grok",
        "start_at": "2026-08-02T12:00:00Z",
        "end_at": "2026-08-02T13:00:00Z",
        "status": "complete"
      }],
      "coverage_truncated": true,
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
  #expect(response.facts.first?.fact.agent == .grok)
  #expect(response.facts.first?.fact.billingChannel == .xaiDirect)
  #expect(response.facts.first?.aggregationTimezone == "Asia/Singapore")
  #expect(response.cost.calculatedRows == response.facts.count)
  #expect(response.coverageTruncated == true)
}

@Test
func decodesLocalUsageTruncationFields() throws {
  let report = LocalUsageReport(
    generatedAt: Date(timeIntervalSince1970: 1_754_080_000),
    aggregationTimezone: nil,
    range: UsageDateRange(from: "2026-08-01", to: "2026-08-02"),
    status: .unavailable,
    coverage: [],
    coverageTruncated: true
  )
  let data = try QuotaWireCodec.makeEncoder().encode(report)
  let encodedText = String(decoding: data, as: UTF8.self)
  #expect(!encodedText.contains("\"today\""))
  #expect(!encodedText.contains("\"usage\""))
  let decoded = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: data)
  #expect(decoded.coverageTruncated == true)

  var missingRevisionObject = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any])
  missingRevisionObject.removeValue(forKey: "model_catalog_revision")
  let missingRevision = try JSONSerialization.data(withJSONObject: missingRevisionObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: missingRevision)
  }

  let falseMarker = LocalUsageReport(
    generatedAt: report.generatedAt,
    aggregationTimezone: nil,
    range: report.range,
    status: .unavailable,
    coverage: [],
    coverageTruncated: false
  )
  let falseMarkerData = try QuotaWireCodec.makeEncoder().encode(falseMarker)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: falseMarkerData)
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
  let client = LocalUsageClientSummary(
    client: .codex,
    totals: summaryTotals,
    cost: cost,
    providers: [provider]
  )
  let summary = LocalUsagePeriodSummary(
    totals: summaryTotals,
    cost: cost,
    clients: [client]
  )
  let data = try QuotaWireCodec.makeEncoder().encode(summary)
  let decoded = try QuotaWireCodec.makeDecoder().decode(LocalUsagePeriodSummary.self, from: data)
  #expect(decoded.totals == summaryTotals)
  #expect(decoded.clients.first?.client == .codex)
  #expect(decoded.clients.first?.providers.first?.provider == .openai)
  #expect(decoded.clients.first?.providers.first?.models.first?.model == "gpt-5.5")
  #expect(decoded.clients.first?.providers.first?.models.first?.totals.messages == 1)

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

  #expect(report.protocolVersion == 2)
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
    UsageSubmissionV2.self, from: multipartData)
  #expect(multipart.writeMode == .mergePartial)
  #expect(multipart.multipart?.partIndex == 0)

  var modelBoundaryObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var modelBoundaryRows = try #require(modelBoundaryObject["rows"] as? [[String: Any]])
  modelBoundaryRows[0]["model"] = String(repeating: "😀", count: 128)
  modelBoundaryObject["rows"] = modelBoundaryRows
  let modelBoundaryData = try JSONSerialization.data(withJSONObject: modelBoundaryObject)
  _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: modelBoundaryData)

  modelBoundaryRows[0]["model"] = String(repeating: "😀", count: 129)
  modelBoundaryObject["rows"] = modelBoundaryRows
  let oversizedModelData = try JSONSerialization.data(withJSONObject: modelBoundaryObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: oversizedModelData)
  }

  var invalidMultipartObject = multipartObject
  invalidMultipartObject["multipart"] = [
    "batch_id": "batch_01",
    "part_index": 2,
    "part_count": 2,
  ]
  let invalidMultipartData = try JSONSerialization.data(withJSONObject: invalidMultipartObject)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageSubmissionV2.self, from: invalidMultipartData)
  }

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
