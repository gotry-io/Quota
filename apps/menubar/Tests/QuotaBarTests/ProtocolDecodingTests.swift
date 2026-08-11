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
func rejectsUnknownNestedLocalServiceStateFields() throws {
  let data = Data(
    #"""
    {
      "ipc_version": 1,
      "revision": 0,
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
