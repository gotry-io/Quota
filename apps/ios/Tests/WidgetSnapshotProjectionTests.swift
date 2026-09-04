import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWire
import Testing

@testable import Quota

struct WidgetSnapshotProjectionTests {
  private let testSalt = Data(repeating: 0x5a, count: 32)

  @Test
  func projectsOneItemPerWindowOfEachResolvedSubscription() throws {
    // Relay resolves an account's readings into one row per subscription, so the widget shows
    // one item per window of each row rather than one per reporting device.
    let subscription = observation(
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
    let summary = try decodeSummary(subscriptions: [subscription, otherFingerprint])
    let items = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt)
    #expect(items.count == 2)
    #expect(items.map(\.remainingPercent).sorted() == [50, 90])
    #expect(items.allSatisfy { $0.providerID == "codex" })
    #expect(items.allSatisfy { $0.providerDisplayName == "Codex" })
  }

  @Test
  func sortsPercentageLowestRemainingThenProviderThenBalanceOnly() throws {
    let summary = try decodeSummary(
      subscriptions: [
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
    let items = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt)
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
    let items = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt)
    #expect(items.count == 4)
    // Same remaining percent and provider: title, then fingerprint, then window id.
    #expect(items.map(\.windowTitle) == ["Daily", "Daily", "Weekly", "Weekly"])
    // Fingerprint is not published; order is still stable across runs.
    let again = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt)
    #expect(items == again)
  }

  @Test
  func keepsSourceScopedSubscriptionsApartAndOrdersThemDeterministically() throws {
    // A source-scoped fingerprint means nothing outside its source, so two Macs collecting
    // the same provider share it. The source is what tells the two subscriptions apart.
    let observation = { (deviceID: String, usedPercent: Double) in
      self.subscriptionPayload(
        provider: "litellm",
        fingerprint: "fp_source",
        scope: "source",
        windows: [
          ["id": "weekly", "title": "Weekly", "used_percent": usedPercent] as [String: Any]
        ],
        status: "available",
        observedAt: "2026-08-14T15:00:00Z",
        deviceID: deviceID
      )
    }
    let summary = try decodeSummary(
      subscriptions: [observation("device_b", 40), observation("device_a", 40)])

    let items = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt)

    #expect(items.count == 2)
    #expect(
      WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt) == items
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
    let items = WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt)
    #expect(items.count == 16)
  }

  @Test
  func mapsTodayCostAndTheReportedState() throws {
    let summary = try decodeSummary(
      subscriptions: [
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
      fetchedAt: date("2026-08-14T16:00:00Z"),
      salt: testSalt
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
    let item = try #require(WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt).first)

    #expect(item.state == .available)
    #expect(item.validUntil == date("2026-08-14T16:00:00Z"))
    // The widget re-renders long after the app published this.
    #expect(item.stateLabel(now: date("2026-08-14T16:00:01Z")) == "Not current")
    #expect(item.stateLabel(now: date("2026-08-14T15:59:59Z")) == nil)
  }

  @Test
  func aReportedFailureReachesTheWidgetAsItsOwnWord() throws {
    let summary = try decodeSummary(
      subscriptions: [
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
    let item = try #require(WidgetSnapshotProjection.projectItems(from: summary.subscriptions, salt: testSalt).first)

    // The wire status, the payload state, and the shared vocabulary have to agree; the
    // reading has not aged out, so only what the source reported can say otherwise.
    #expect(item.state == .signInNeeded)
    #expect(item.observedState(now: date("2026-08-14T16:00:00Z")) == .signInNeeded)
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
      summary: summary,
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

  @Test
  func selectionIDIsStableForTheSameSaltAndChangesWhenTheSaltDoes() throws {
    let summary = try decodeSummary(
      subscriptions: [
        observation(
          provider: "codex",
          fingerprint: "fp_codex_01",
          windowID: "weekly",
          title: "Weekly",
          usedPercent: 29
        )
      ]
    )
    let first = WidgetSnapshotProjection.projectItems(
      from: summary.subscriptions,
      salt: testSalt
    )
    let again = WidgetSnapshotProjection.projectItems(
      from: summary.subscriptions,
      salt: testSalt
    )
    #expect(first.map(\.selectionID) == again.map(\.selectionID))
    #expect(first.first?.selectionID.count == 12)

    let otherSalt = Data(repeating: 0xa5, count: 32)
    let rotated = WidgetSnapshotProjection.projectItems(
      from: summary.subscriptions,
      salt: otherSalt
    )
    #expect(first.map(\.selectionID) != rotated.map(\.selectionID))
    #expect(rotated.first?.selectionID.count == 12)
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
