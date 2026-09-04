import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct AlertCoordinatorTests {
  @Test func successfulRefreshDeliversOnePassAndARepeatDoesNotFireAgain() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    IOSAlertRulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let store = InMemoryIOSAlertStateStore()
    let sink = RecordingAlertSink()
    let coordinator = AlertCoordinator(
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
      stateStore: store,
      sink: sink,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let body = try alertSummaryJSON(usedPercent: 88)
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [
        .init(status: 200, body: body),
        .init(status: 200, body: body),
      ],
      alertCoordinator: coordinator
    )

    #expect(await model.refresh())
    #expect(sink.events.count == 1)
    #expect(
      sink.events
        == [
          .thresholdCrossed(
            selector: "ccfc96629357",
            windowID: "weekly",
            threshold: 20,
            remainingPercent: 12,
            resetsAt: Fixtures.date("2026-08-18T00:00:00Z")
          )
        ]
    )
    #expect(try store.load().fired.count == 1)

    #expect(await model.refresh())
    #expect(sink.events.count == 1)
  }

  @Test func logoutClearsAlertDedupStateAndLeavesRules() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    let rules = AlertRules(enabled: true, resetReminders: true)
    IOSAlertRulesStore(defaults: defaults.store).save(rules)
    let store = InMemoryIOSAlertStateStore(
      state: AlertDedupState(
        fired: [
          AlertDedupKey(
            selector: "ccfc96629357", windowID: "weekly", resetsAt: nil, threshold: 20)
        ],
        readings: [
          AlertStoredReading(
            selector: "ccfc96629357", windowID: "weekly", remainingPercent: 18, resetsAt: nil)
        ]
      )
    )
    let coordinator = AlertCoordinator(
      rulesStore: IOSAlertRulesStore(defaults: defaults.store),
      stateStore: store,
      sink: RecordingAlertSink(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: try WireCodec.decode(AccountSummary.self, from: try alertSummaryJSON()),
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [.init(status: 204, body: Data())],
      alertCoordinator: coordinator
    )

    #expect(try store.load().fired.count == 1)
    await model.logout()
    #expect(try store.load() == .empty)
    let loaded = IOSAlertRulesStore(defaults: defaults.store).load()
    #expect(loaded.enabled)
    #expect(loaded.resetReminders)
  }
}

final class RecordingAlertSink: AlertSink, @unchecked Sendable {
  var events: [AlertEvent] = []

  func deliver(_ events: [AlertEvent]) {
    self.events.append(contentsOf: events)
  }
}

struct IsolatedAlertDefaults {
  let name: String
  let store: UserDefaults

  func tearDown() {
    store.removePersistentDomain(forName: name)
  }
}

func isolatedAlertDefaults() -> IsolatedAlertDefaults {
  let name = "QuotaTests.AlertRules.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: name)!
  store.removePersistentDomain(forName: name)
  return IsolatedAlertDefaults(name: name, store: store)
}

func alertSummaryJSON(usedPercent: Double = 88, resetsAt: String = "2026-08-18T00:00:00Z")
  throws -> Data
{
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
        "account_id": "account_01",
        "display_label": "octocat",
        "created_at": "2026-07-01T00:00:00Z",
      ],
      "devices": [],
      "subscriptions": [
        [
          "key": "codex|account_test|global|",
          "provider": "codex",
          "snapshot": [
            "provider": "codex",
            "account": [
              "fingerprint": "account_test",
              "fingerprint_scope": "global",
            ],
            "windows": [
              [
                "id": "weekly",
                "title": "Weekly",
                "used_percent": usedPercent,
                "resets_at": resetsAt,
                "primary_cadence": "weekly",
              ]
            ],
            "status": "available",
            "observed_at": "2026-08-14T15:00:00Z",
          ],
          "sources": [["device_id": "device_01", "observed_at": "2026-08-14T15:00:00Z"]],
        ]
      ],
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
