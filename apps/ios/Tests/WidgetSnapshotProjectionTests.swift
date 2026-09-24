import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWidgetProjection
import QuotaWidgetViews
import QuotaWire
import Testing

@testable import Quota

struct WidgetSnapshotProjectionTests {
  private let testSalt = Data(repeating: 0x5a, count: 32)
  /// The instant the fixtures were read — `2026-08-14T16:00:00Z`, what every observation in
  /// this file is stamped with — so a projected pace is the same on every run.
  private let testNow = Date(timeIntervalSince1970: 1_786_723_200)

  /// Rows that tie on remaining percent rank by title, then fingerprint, source, and window id,
  /// so the widget shows the same order whatever order Relay listed them in. A source-scoped
  /// fingerprint is shared by two Macs collecting the same provider; the source is what tells
  /// those two subscriptions apart.
  @Test
  func equalReadingsRankTheSameWhateverOrderTheyArriveIn() throws {
    let summary = try decodeSummary(
      subscriptions: [
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
    let items = WidgetSnapshotProjection.projectItems(
      from: summary.subscriptions, salt: testSalt, now: testNow)
    #expect(items.map(\.windowTitle) == ["Daily", "Daily", "Weekly", "Weekly"])
    #expect(
      WidgetSnapshotProjection.projectItems(
        from: Array(summary.subscriptions.reversed()), salt: testSalt, now: testNow) == items
    )

    let sourceScoped = { (deviceID: String) in
      self.subscriptionPayload(
        provider: "litellm",
        fingerprint: "fp_source",
        scope: "source",
        windows: [["id": "weekly", "title": "Weekly", "used_percent": 40.0] as [String: Any]],
        status: "available",
        observedAt: "2026-08-14T15:00:00Z",
        deviceID: deviceID
      )
    }
    let twoMacs = try decodeSummary(
      subscriptions: [sourceScoped("device_b"), sourceScoped("device_a")])
    let macItems = WidgetSnapshotProjection.projectItems(
      from: twoMacs.subscriptions, salt: testSalt, now: testNow)
    #expect(macItems.count == 2)
    #expect(Set(macItems.map(\.selectionID)).count == 2)
    #expect(
      WidgetSnapshotProjection.projectItems(
        from: Array(twoMacs.subscriptions.reversed()), salt: testSalt, now: testNow) == macItems
    )
  }

  @Test
  func capsAtSixteenItems() throws {
    let subscriptions = (0..<20).map { index in
      observation(
        provider: "codex",
        fingerprint: "fp_\(index)",
        windowID: "w\(index)",
        title: String(format: "W%02d", index),
        usedPercent: Double(index),
      )
    }
    let summary = try decodeSummary(subscriptions: subscriptions)
    let items = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt, now: testNow)
    #expect(items.count == 16)
  }

  @Test
  func carriesTheFreshnessFactsSoTheWidgetCanJudgeAtRenderTime() throws {
    let summary = try decodeSummary(
      subscriptions: [
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
    let item = try #require(WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt, now: testNow).first)

    #expect(item.state == .available)
    #expect(item.validUntil == date("2026-08-14T16:00:00Z"))
    // The widget re-renders long after the app published this.
    #expect(item.stateLabel(now: date("2026-08-14T16:00:01Z")) == "Not current")
    #expect(item.stateLabel(now: date("2026-08-14T15:59:59Z")) == nil)
  }

  @Test
  func encodedProjectionOmitsFixtureSecrets() throws {
    let summary = try decodeSummary(
      subscriptions: [
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
      subscriptions: summary.subscriptions,
      today: summary.usage.today,
      fetchedAt: date("2026-08-14T16:00:00Z"),
      salt: testSalt
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProtectedFileWidgetSnapshotStore(directory: directory)
    try store.save(snapshot)
    let encoded = try String(contentsOf: store.fileURL, encoding: .utf8)

    let unsaltedSelector = SubscriptionSelector.make(
      provider: "codex",
      fingerprint: "fp_codex_01",
      fingerprintScope: "global",
      sourceID: nil
    )
    let expectedID = SelectionIDs.make(selector: unsaltedSelector, salt: testSalt)
    #expect(snapshot.items.first?.selectionID == expectedID)
    #expect(expectedID != unsaltedSelector)

    let forbiddenValues = [
      "account_01",
      "fp_codex_01",
      "device_01",
      "chatgpt",
      "octocat",
      unsaltedSelector,
      "\"sequence\"",
    ]
    for value in forbiddenValues {
      #expect(!encoded.contains(value), "projection must not contain \(value)")
    }
    #expect(!encoded.contains("fingerprint"))
    #expect(!encoded.contains("account_id"))
    #expect(!encoded.contains("device_id"))
    #expect(!encoded.contains("display_label"))
    #expect(!encoded.contains("\"source\""))
    #expect(encoded.contains("selection_id"))
    #expect(encoded.contains(expectedID))
  }

  private func decodeSummary(
    subscriptions: [[String: Any]],
    accountID: String = "account_01"
  ) throws -> AccountSummary {
    let data = try accountSummaryJSON(accountID: accountID, subscriptions: subscriptions)
    return try WireCodec.decode(AccountSummary.self, from: data)
  }

  private func observation(
    provider: String,
    fingerprint: String,
    windows: [(id: String, title: String, usedPercent: Double)],
    deviceID: String = "device_01",
    observedAt: String = "2026-08-14T15:00:00Z"
  ) -> [String: Any] {
    subscriptionPayload(
      provider: provider,
      fingerprint: fingerprint,
      scope: "global",
      windows: windows.map {
        ["id": $0.id, "title": $0.title, "used_percent": $0.usedPercent] as [String: Any]
      },
      status: "available",
      observedAt: observedAt,
      deviceID: deviceID
    )
  }

  /// One subscription, as Relay already resolved it.
  private func subscriptionPayload(
    provider: String,
    fingerprint: String,
    scope: String,
    windows: [[String: Any]],
    status: String,
    observedAt: String,
    deviceID: String
  ) -> [String: Any] {
    [
      "key": "\(provider)|\(fingerprint)|\(scope)|\(scope == "source" ? deviceID : "")",
      "provider": provider,
      "snapshot": [
        "provider": provider,
        "account": ["fingerprint": fingerprint, "fingerprint_scope": scope],
        "windows": windows,
        "status": status,
        "observed_at": observedAt,
      ] as [String: Any],
      "sources": [["device_id": deviceID, "observed_at": observedAt]],
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
    return subscriptionPayload(
      provider: provider,
      fingerprint: fingerprint,
      scope: "global",
      windows: [window],
      status: status,
      observedAt: observedAt,
      deviceID: deviceID
    )
  }

  private func accountSummaryJSON(
    accountID: String,
    subscriptions: [[String: Any]]
  ) throws -> Data {
    let period: [String: Any] = [
      "totals": [
        "total_tokens": 1200,
        "input_tokens": 1000,
        "output_tokens": 200,
        "cache_read_input_tokens": 100,
        "cache_write_input_tokens": 0,
        "reasoning_tokens": 50,
        "messages": 1,
      ] as [String: Any],
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
      ] as [String: Any],
      "cache_saved": [
        "amount_microusd": "0",
        "status": "complete",
        "unpriced_rows": 0,
      ] as [String: Any],
      "partial": false,
      "agents": [],
    ]
    return try JSONSerialization.data(
      withJSONObject: [
        "protocol_version": 6,
        "account": [
          "account_id": accountID,
          "display_label": "octocat",
          "created_at": "2026-07-01T00:00:00Z",
        ],
        "devices": [],
        "subscriptions": subscriptions,
        "usage": [
          "today": period,
          "last_7_days": period,
          "last_30_days": period,
          "all": period,
        ],
        "pricing_revision": "pricing_1",
        "model_catalog_revision": "models_1",
      ] as [String: Any]
    )
  }

  private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }
}
