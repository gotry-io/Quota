import Foundation
import QuotaPresentation
import QuotaWire
import Testing

@testable import QuotaBar

@Test
func decodesQuotaHistorySamplesAndRejectsUnknownKeys() throws {
  let data = Data(
    #"""
    {
      "samples_by_subscription": {
        "ccfc96629357": {
          "five_hour": [
            {
              "resets_at": "2026-09-05T12:00:00Z",
              "observed_at": "2026-09-05T09:30:00Z",
              "used_percent": 40.0
            }
          ]
        }
      },
      "utc_offset_seconds": -25200
    }
    """#.utf8
  )
  let history = try QuotaWireCodec.makeDecoder().decode(LocalServiceQuotaHistory.self, from: data)
  #expect(history.utcOffsetSeconds == -25_200)
  #expect(history.samplesBySubscription["ccfc96629357"]?["five_hour"]?.count == 1)
  #expect(history.samplesBySubscription["ccfc96629357"]?["five_hour"]?.first?.usedPercent == 40)

  let extra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"utc_offset_seconds\": -25200",
      with: "\"utc_offset_seconds\": -25200,\n      \"extra\": true"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceQuotaHistory.self, from: extra)
  }
}

@Test
func rejectsUnknownNestedLocalServiceStateFields() throws {
  let data = Data(
    #"""
    {
      "ipc_version": 4,
      "revision": 0,
      "usage_upload_enabled": true,
      "group_usage_by_project": true,
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
      "provider_status": [],
      "provider_browser_sessions": [],
      "browser_scan_enabled": [],
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

  #expect(state.accountSettings == nil)
  #expect(state.historySync == nil)
}

@Test
func decodesAccountSettingsWhenPresentAndIgnoresUnknownDocumentKeys() throws {
  let data = Data(
    #"""
    {
      "ipc_version": 4,
      "revision": 0,
      "usage_upload_enabled": true,
      "group_usage_by_project": true,
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
        "status": "ready",
        "value": {
          "auth_status": "signed_in",
          "account_id": "account_1",
          "device_id": "device_1",
          "device_generation": 1,
          "account_summary": null
        },
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "account_settings": {
        "document": {
          "protocol_version": 2,
          "revision": 1,
          "updated_at": "2026-09-21T10:00:00Z",
          "alerts": {
            "reset_reminders": true,
            "pace_alerts": true,
            "thresholds": { "a1b2c3d4e5f6": [20, 10] },
            "quiet_hours": { "from": "22:00" }
          },
          "budget": { "amount_usd": "250.00", "alerts": true, "currency": "USD" },
          "experiment": true
        },
        "revision": 1
      },
      "history_sync": {"enabled": true, "last_upload_at": "2026-09-22T10:00:00Z", "last_error": null},
      "pricing": {
        "status": "unavailable",
        "value": null,
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "providers": [],
      "provider_status": [],
      "provider_browser_sessions": [],
      "browser_scan_enabled": [],
      "overview": [],
      "cache": { "rebuilding": false, "reset_at": null }
    }
    """#.utf8
  )
  let state = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: data)
  let settings = try #require(state.accountSettings)
  #expect(settings.revision == 1)
  #expect(settings.document.revision == 1)
  #expect(settings.document.alerts.resetReminders)
  #expect(settings.document.alerts.thresholds == ["a1b2c3d4e5f6": [20, 10]])
  #expect(settings.document.budget.amountUSD == Decimal(250))
  #expect(settings.ifMatch == "\"1\"")
  let sync = try #require(state.historySync)
  #expect(sync.enabled)
  #expect(sync.lastError == nil)
  let uploaded = try #require(sync.lastUploadAt)
  #expect(sync.statusLine(now: uploaded.addingTimeInterval(180)) == "Last uploaded 3m ago")

  let errored = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"last_error\": null}",
      with: "\"last_error\": \"network\"}"
    ).utf8
  )
  let erroredState = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: errored)
  #expect(erroredState.historySync?.statusLine(now: uploaded) == "Could not reach your Account.")

  let extraHistory = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"enabled\": true",
      with: "\"enabled\": true, \"extra\": true"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: extraHistory)
  }

  let extraEnvelope = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"account_settings\": {",
      with: "\"account_settings\": { \"future_field\": true,"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: extraEnvelope)
  }
}

@Test
func rejectsUnknownProviderStatusIndicators() {
  let data = Data(
    #"""
    {
      "ipc_version": 1,
      "revision": 0,
      "usage_upload_enabled": true,
      "group_usage_by_project": true,
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
        "status": "unavailable",
        "value": null,
        "updated_at": null,
        "last_error": null,
        "refreshing": false
      },
      "providers": [],
      "provider_status": [
        {
          "provider": "claude",
          "indicator": "maintenance",
          "description": "Scheduled",
          "checked_at": "2026-09-06T00:00:00Z"
        }
      ],
      "provider_browser_sessions": [],
      "browser_scan_enabled": [],
      "overview": [],
      "cache": { "rebuilding": false, "reset_at": null }
    }
    """#.utf8
  )
  #expect(throws: DecodingError.self) {
    try QuotaWireCodec.makeDecoder().decode(LocalServiceState.self, from: data)
  }
}

@Test
func decodesLoginResultIncludingAuthorizeURL() throws {
  let data = Data(
    #"""
    {
      "status": "logging_in",
      "account_id": null,
      "device_id": null,
      "device_generation": null,
      "authorize_url": "http://127.0.0.1:9/callback"
    }
    """#.utf8
  )
  let result = try QuotaWireCodec.makeDecoder().decode(LocalServiceLoginResult.self, from: data)
  #expect(result.status == .loggingIn)
  #expect(result.authorizeURL == "http://127.0.0.1:9/callback")

  let extra = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"authorize_url\": \"http://127.0.0.1:9/callback\"",
      with: "\"authorize_url\": \"http://127.0.0.1:9/callback\",\n      \"extra\": true"
    ).utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalServiceLoginResult.self, from: extra)
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
  #expect(encodedText.contains("\"sessions\""))
  #expect(!encodedText.contains("\"usage\""))
  #expect(!encodedText.contains("\"last_7_days\""))
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
func decodesLocalUsageSessions() throws {
  let now = Date(timeIntervalSince1970: 1_754_080_000)
  let cost = UsageCostOutcome(
    mode: .auto,
    basis: .reported,
    status: .complete,
    amountMicrousd: "12",
    catalogRevision: nil,
    calculatedRows: 0,
    reportedRows: 1,
    unpricedRows: 0,
    assumptions: [.sourceReported],
    unpriced: []
  )
  let report = LocalUsageReport(
    generatedAt: now,
    aggregationTimezone: "UTC",
    range: UsageDateRange(from: "2026-08-01", to: "2026-08-02"),
    status: .complete,
    modelCatalogRevision: nil,
    coverage: [
      LocalUsageCoverage(
        agent: .codex,
        startAt: "2026-08-01T00:00:00Z",
        endAt: "2026-08-03T00:00:00Z",
        status: .complete
      )
    ],
    sessions: LocalUsageSessions(
      active: 1,
      today: 1,
      recent: [
        LocalUsageSession(
          agent: .codex,
          projectKey: "Quota",
          startedAt: now.addingTimeInterval(-600),
          lastActivityAt: now.addingTimeInterval(-30),
          messages: 4,
          tokens: 1300,
          cost: cost,
          topModel: "gpt-5",
          isActive: true
        )
      ]
    )
  )
  let data = try QuotaWireCodec.makeEncoder().encode(report)
  let encodedText = String(decoding: data, as: UTF8.self)
  #expect(encodedText.contains("\"sessions\""))
  #expect(!encodedText.contains("source_file_id"))
  let decoded = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: data)
  #expect(decoded.sessions.active == 1)
  #expect(decoded.sessions.recent[0].projectKey == "Quota")

  func mutateRecent(_ mutate: (inout [[String: Any]]) throws -> Void) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var sessions = try #require(object["sessions"] as? [String: Any])
    var recent = try #require(sessions["recent"] as? [[String: Any]])
    try mutate(&recent)
    sessions["recent"] = recent
    object["sessions"] = sessions
    return try JSONSerialization.data(withJSONObject: object)
  }

  let pathData = try mutateRecent { $0[0]["project_key"] = "src/app" }
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: pathData)
  }

  let fileData = try mutateRecent { $0[0]["source_file_id"] = "abc" }
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: fileData)
  }

  let tooManyData = try mutateRecent { recent in
    let row = try #require(recent.first)
    recent = Array(repeating: row, count: 21)
  }
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(LocalUsageReport.self, from: tooManyData)
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
  let namedProject = LocalUsageProjectSummary(
    projectKey: "Quota",
    totalTokens: 130,
    cost: cost,
    messages: 1,
    topModel: "gpt-5.5"
  )
  let otherProject = LocalUsageProjectSummary(
    projectKey: "other",
    totalTokens: 10,
    cost: cost,
    messages: 1,
    topModel: "gpt-5.5"
  )
  let summary = LocalUsagePeriodSummary(
    totals: summaryTotals,
    cost: cost,
    cacheSaved: UsageCacheSaved(amountMicrousd: "0", status: .complete, unpricedRows: 0),
    agents: [client],
    projects: [namedProject, otherProject],
    days: [LocalUsageDay(date: "2026-08-10", totals: summaryTotals, cost: cost)],
    hoursOfDay: (0..<24).map {
      LocalUsageHourOfDay(hour: $0, totalTokens: $0 == 12 ? 1 : 0, costMicrousd: nil)
    }
  )
  let data = try QuotaWireCodec.makeEncoder().encode(summary)
  let decoded = try QuotaWireCodec.makeDecoder().decode(LocalUsagePeriodSummary.self, from: data)
  #expect(decoded.totals == summaryTotals)
  #expect(decoded.agents.first?.agent == .codex)
  #expect(decoded.agents.first?.providers.first?.provider == .openai)
  #expect(decoded.agents.first?.providers.first?.models.first?.model == "gpt-5.5")
  #expect(decoded.agents.first?.providers.first?.models.first?.totals.messages == 1)
  #expect(decoded.cacheSaved.status == .complete)
  #expect(decoded.projects?.map(\.projectKey) == ["Quota", "other"])
  #expect(decoded.projects?.map(\.displayName) == ["Quota", "Other"])
  #expect(decoded.days?.map(\.date) == ["2026-08-10"])
  #expect(decoded.hoursOfDay?.count == 24)
  #expect(decoded.hoursOfDay?[12].totalTokens == 1)

  // An Account period may carry hours without the per-day table.
  var hoursOnlyObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  hoursOnlyObject.removeValue(forKey: "days")
  let hoursOnly = try JSONSerialization.data(withJSONObject: hoursOnlyObject)
  let decodedHoursOnly = try QuotaWireCodec.makeDecoder().decode(
    LocalUsagePeriodSummary.self, from: hoursOnly)
  #expect(decodedHoursOnly.days == nil)
  #expect(decodedHoursOnly.hoursOfDay?.count == 24)

  var shortHours = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  shortHours["hours_of_day"] = (0..<23).map {
    ["hour": $0, "total_tokens": 0, "cost_microusd": NSNull()]
  }
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(
      LocalUsagePeriodSummary.self,
      from: try JSONSerialization.data(withJSONObject: shortHours)
    )
  }

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

/// The cases every runtime answers are `wire-conformance.json` (`WireConformanceTests`); these
/// are the two edges of QuotaBar's own restatement the fixture does not name.
@Test
func aModelNameOver128CharactersOrAnImpossibleHourIsRefused() throws {
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

  let invalidHour = Data(
    String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "2026-08-02T12:00:00Z",
      with: "2023-02-29T00:00:00Z"
    ).utf8)
  #expect(throws: DecodingError.self) {
    _ = try QuotaWireCodec.makeDecoder().decode(UsageUpload.self, from: invalidHour)
  }
}

/// The Account read answers a period without `projects`: attribution stays on the Mac that made
/// it (ADR 0039), so the key is absent rather than empty, and the state that carries such a
/// period still decodes — a signed-in QuotaBar reads one on every refresh.
@Test
func anAccountPeriodWithoutProjectsDecodes() throws {
  let json = """
    {
      "totals": {"total_tokens": 0, "input_tokens": 0, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_write_input_tokens": 0, "reasoning_tokens": 0,
        "messages": 0},
      "cost": {"amount_microusd": null, "basis": "none", "mode": "auto", "status": "complete",
        "catalog_revision": "official-2026-09-06-1", "calculated_rows": 0, "reported_rows": 0,
        "unpriced_rows": 0, "unpriced": [], "assumptions": []},
      "cache_saved": {"amount_microusd": "0", "status": "complete", "unpriced_rows": 0},
      "agents": []
    }
    """
  let decoded = try QuotaWireCodec.makeDecoder().decode(
    LocalUsagePeriodSummary.self, from: Data(json.utf8))
  #expect(decoded.projects == nil)
  #expect(decoded.days == nil)
  #expect(decoded.isValid)
}
