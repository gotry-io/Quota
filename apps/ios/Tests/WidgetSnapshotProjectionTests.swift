import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWire
import Testing

@testable import Quota

struct WidgetSnapshotProjectionTests {
  @Test
  func projectsOneItemPerSubscriptionAndKeepsTheNewestObservation() throws {
    // One account collected on two Macs. The reading each device took decides which one
    // speaks, not the order Relay happened to write the rows in: the device that wrote
    // last here is the one holding the older reading.
    let older = observation(
      provider: "codex",
      fingerprint: "fp_codex_01",
      windowID: "weekly",
      title: "Weekly",
      usedPercent: 40,
      observedAt: "2026-08-14T15:00:00Z",
      deviceID: "device_01"
    )
    let newer = observation(
      provider: "codex",
      fingerprint: "fp_codex_01",
      windowID: "weekly",
      title: "Weekly",
      usedPercent: 10,
      observedAt: "2026-08-14T16:00:00Z",
      deviceID: "device_02"
    )
    let otherFingerprint = observation(
      provider: "codex",
      fingerprint: "fp_codex_02",
      windowID: "weekly",
      title: "Weekly",
      usedPercent: 50,
    )
    let summary = try decodeSummary(quota: [older, newer, otherFingerprint])
    let items = WidgetSnapshotProjection.projectItems(
      from: summary.quota,
      now: date("2026-08-14T16:05:00Z")
    )
    #expect(items.count == 2)
    #expect(items.map(\.remainingPercent).sorted() == [50, 90])
    #expect(items.allSatisfy { $0.providerID == "codex" })
    #expect(items.allSatisfy { $0.providerDisplayName == "Codex" })
  }

  @Test
  func sortsPercentageLowestRemainingThenProviderThenBalanceOnly() throws {
    let summary = try decodeSummary(
      quota: [
        observation(
          provider: "claude",
          fingerprint: "fp_claude",
          windowID: "weekly",
          title: "Weekly",
          usedPercent: 20,
        ),
        observation(
          provider: "codex",
          fingerprint: "fp_codex",
          windows: [
            (id: "5h", title: "5h", usedPercent: 80),
            (id: "weekly", title: "Weekly", usedPercent: 80),
          ],
        ),
        observation(
          provider: "grok",
          fingerprint: "fp_grok",
          windowID: "balance",
          title: "Wallet",
          usedPercent: 0,
          remainingValue: 12.5,
          valueUnit: "usd",
          limitValue: nil,
        ),
      ]
    )
    let items = WidgetSnapshotProjection.projectItems(from: summary.quota)
    #expect(items.count == 4)
    // Percentage first: lowest remainingPercent, then provider sortOrder, then title.
    #expect(items[0].providerID == "codex")
    #expect(items[0].remainingPercent == 20)
    #expect(items[0].windowTitle == "5h")
    #expect(items[1].providerID == "codex")
    #expect(items[1].windowTitle == "Weekly")
    #expect(items[2].providerID == "claude")
    #expect(items[2].remainingPercent == 80)
    // Balance-only last with Balance title from RemainingQuotaFormat.
    #expect(items[3].providerID == "grok")
    #expect(items[3].windowTitle == "Balance")
    #expect(items[3].remainingValue == 12.5)
    #expect(items[3].unit == .usd)
    #expect(items[3].hasLimit == false)
  }

  @Test
  func sortsDeterministicallyWithFingerprintAndWindowIdTieBreaks() throws {
    // One account reporting several windows is one observation carrying all of them, so
    // the tie-breaks have to order windows within a subscription as well as across them.
    let summary = try decodeSummary(
      quota: [
        observation(
          provider: "codex",
          fingerprint: "fp_b",
          windows: [(id: "weekly", title: "Weekly", usedPercent: 40)],
        ),
        observation(
          provider: "codex",
          fingerprint: "fp_a",
          windows: [
            (id: "weekly", title: "Weekly", usedPercent: 40),
            (id: "daily", title: "Daily", usedPercent: 40),
            (id: "hourly", title: "Daily", usedPercent: 40),
          ],
        ),
      ]
    )
    let items = WidgetSnapshotProjection.projectItems(from: summary.quota)
    #expect(items.count == 4)
    // Same remaining percent and provider: title, then fingerprint, then window id.
    #expect(items.map(\.windowTitle) == ["Daily", "Daily", "Weekly", "Weekly"])
    // Fingerprint is not published; order is still stable across runs.
    let again = WidgetSnapshotProjection.projectItems(from: summary.quota)
    #expect(items == again)
  }

  @Test
  func keepsSourceScopedSubscriptionsApartAndOrdersThemDeterministically() throws {
    // A source-scoped fingerprint means nothing outside its source, so two Macs collecting
    // the same provider share it. The source is what tells the two subscriptions apart.
    let observation = { (deviceID: String, usedPercent: Double) in
      [
        "device_id": deviceID,
        "snapshot": [
          "provider": "litellm",
          "account": ["fingerprint": "fp_source", "fingerprint_scope": "source"],
          "windows": [
            ["id": "weekly", "title": "Weekly", "used_percent": usedPercent] as [String: Any]
          ],
          "status": "available",
          "observed_at": "2026-08-14T15:00:00Z",
        ] as [String: Any],
      ] as [String: Any]
    }
    let summary = try decodeSummary(quota: [observation("device_b", 40), observation("device_a", 40)])

    let items = WidgetSnapshotProjection.projectItems(
      from: summary.quota,
      now: date("2026-08-14T15:05:00Z")
    )

    #expect(items.count == 2)
    #expect(
      WidgetSnapshotProjection.projectItems(
        from: summary.quota,
        now: date("2026-08-14T15:05:00Z")
      ) == items
    )
  }

  @Test
  func capsAtSixteenItems() throws {
    let quota = (0..<20).map { index in
      observation(
        provider: "codex",
        fingerprint: "fp_\(index)",
        windowID: "w\(index)",
        title: String(format: "W%02d", index),
        usedPercent: Double(index),
      )
    }
    let summary = try decodeSummary(quota: quota)
    let items = WidgetSnapshotProjection.projectItems(from: summary.quota)
    #expect(items.count == 16)
  }

  @Test
  func mapsTodayCostAndTheReportedState() throws {
    let summary = try decodeSummary(
      quota: [
        observation(
          provider: "codex",
          fingerprint: "fp_codex_01",
          windowID: "weekly",
          title: "Weekly",
          usedPercent: 29,
          status: "stale",
        )
      ]
    )
    let snapshot = WidgetSnapshotProjection.make(
      summary: summary,
      fetchedAt: date("2026-08-14T16:00:00Z")
    )
    #expect(snapshot.items.first?.state == .stale)
    #expect(snapshot.today.inputTokens == 1000)
    #expect(snapshot.today.outputTokens == 200)
    #expect(snapshot.today.cost.status == .complete)
    #expect(snapshot.today.cost.amountMicrousd == "3138")
  }

  @Test
  func carriesTheFreshnessFactsSoTheWidgetCanJudgeAtRenderTime() throws {
    let summary = try decodeSummary(
      quota: [
        observation(
          provider: "codex",
          fingerprint: "fp_codex_01",
          windowID: "weekly",
          title: "Weekly",
          usedPercent: 29,
          resetsAt: "2026-08-14T16:00:00Z",
        )
      ]
    )
    let item = try #require(WidgetSnapshotProjection.projectItems(from: summary.quota).first)

    #expect(item.state == .available)
    #expect(item.validUntil == date("2026-08-14T16:00:00Z"))
    // The widget re-renders long after the app published this.
    #expect(item.stateLabel(now: date("2026-08-14T16:00:01Z")) == "Stale")
    #expect(item.stateLabel(now: date("2026-08-14T15:59:59Z")) == nil)
  }

  @Test
  func aReportedFailureReachesTheWidgetAsItsOwnWord() throws {
    let summary = try decodeSummary(
      quota: [
        observation(
          provider: "codex",
          fingerprint: "fp_codex_01",
          windowID: "monthly",
          title: "Monthly",
          usedPercent: 0,
          status: "auth_required",
        )
      ]
    )
    let item = try #require(WidgetSnapshotProjection.projectItems(from: summary.quota).first)

    // The wire status, the payload state, and the shared vocabulary have to agree; the
    // reading has not aged out, so only what the source reported can say otherwise.
    #expect(item.state == .signInNeeded)
    #expect(item.observedState(now: date("2026-08-14T16:00:00Z")) == .signInNeeded)
  }

  @Test
  func encodedProjectionOmitsFixtureSecrets() throws {
    let summary = try decodeSummary(
      quota: [
        observation(
          provider: "codex",
          fingerprint: "fp_codex_01",
          windowID: "weekly",
          title: "Weekly",
          usedPercent: 29,
          deviceID: "device_01",
          source: "chatgpt"
        )
      ],
      accountID: "account_01"
    )
    let snapshot = WidgetSnapshotProjection.make(
      summary: summary,
      fetchedAt: date("2026-08-14T16:00:00Z")
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    try store.save(snapshot)
    let encoded = try String(contentsOf: store.fileURL, encoding: .utf8)

    let forbiddenValues = [
      "account_01",
      "fp_codex_01",
      "device_01",
      "chatgpt",
      "\"sequence\"",
    ]
    for value in forbiddenValues {
      #expect(!encoded.contains(value), "projection must not contain \(value)")
    }
    #expect(!encoded.contains("fingerprint"))
    #expect(!encoded.contains("account_id"))
    #expect(!encoded.contains("device_id"))
    #expect(!encoded.contains("\"source\""))
  }

  private func decodeSummary(
    quota: [[String: Any]],
    accountID: String = "account_01"
  ) throws -> AccountSummary {
    let data = try accountSummaryJSON(accountID: accountID, quota: quota)
    return try WireCodec.decode(AccountSummary.self, from: data)
  }

  private func observation(
    provider: String,
    fingerprint: String,
    windows: [(id: String, title: String, usedPercent: Double)],
    deviceID: String = "device_01",
    observedAt: String = "2026-08-14T15:00:00Z"
  ) -> [String: Any] {
    [
      "device_id": deviceID,
      "snapshot": [
        "provider": provider,
        "account": [
          "fingerprint": fingerprint,
          "fingerprint_scope": "global",
        ],
        "windows": windows.map {
          ["id": $0.id, "title": $0.title, "used_percent": $0.usedPercent] as [String: Any]
        },
        "status": "available",
        "observed_at": observedAt,
      ] as [String: Any],
    ]
  }

  private func observation(
    provider: String,
    fingerprint: String,
    windowID: String,
    title: String,
    usedPercent: Double,
    remainingValue: Double? = nil,
    valueUnit: String? = nil,
    limitValue: Double? = nil,
    status: String = "available",
    resetsAt: String? = nil,
    observedAt: String = "2026-08-14T15:00:00Z",
    deviceID: String = "device_01",
    source: String = "chatgpt"
  ) -> [String: Any] {
    var window: [String: Any] = [
      "id": windowID,
      "title": title,
      "used_percent": usedPercent,
    ]
    if let remainingValue {
      window["remaining_value"] = remainingValue
    }
    if let valueUnit {
      window["value_unit"] = valueUnit
    }
    if let limitValue {
      window["limit_value"] = limitValue
    }
    if let resetsAt {
      window["resets_at"] = resetsAt
    }
    var snapshot: [String: Any] = [
      "provider": provider,
      "account": [
        "fingerprint": fingerprint,
        "fingerprint_scope": "global",
      ],
      "windows": [window],
      "status": status,
      "observed_at": observedAt,
    ]
    return ["device_id": deviceID, "snapshot": snapshot]
  }

  private func accountSummaryJSON(
    accountID: String,
    quota: [[String: Any]]
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "protocol_version": 4,
        "account": [
          "account_id": accountID,
          "display_label": "octocat",
          "created_at": "2026-07-01T00:00:00Z",
        ],
        "devices": [],
        "quota": quota,
        "usage": [
          "range": ["from": "2026-08-14", "to": "2026-08-14"],
          "totals": [
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
          ],
          "cost": [
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
          ],
          "coverage": [],
          "breakdowns": [],
        ],
      ]
    )
  }

  private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }
}
