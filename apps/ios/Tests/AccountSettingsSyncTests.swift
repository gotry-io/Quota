import Foundation
import Observation
import QuotaAccount
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaRelay
import Testing

@testable import Quota

@MainActor
struct AccountSettingsSyncTests {
  @Test func firstSyncSeedsNonDefaultLocalValues() async throws {
    let harness = SettingsSyncHarness()
    harness.rules.save(
      AlertRules(enabled: true, resetReminders: false, paceAlerts: true)
    )
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(
          status: 200,
          body: accountSettingsGETBody(
            revision: 1, resetReminders: false, amountUSD: nil
          ),
          headers: ["ETag": "\"1\""]
        ),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)

    await sync.refresh()

    #expect(harness.rules.load().resetReminders == false)
    #expect(harness.rules.load().enabled)
    #expect(transport.requests.compactMap(\.httpMethod) == ["GET", "PUT"])
    #expect(transport.requests.map { $0.url?.path } == [
      "/api/v2/account/settings",
      "/api/v2/account/settings",
    ])
    #expect(transport.requests[1].value(forHTTPHeaderField: "If-Match") == "\"0\"")
    #expect(harness.applied >= 1)
  }

  @Test func firstSyncAdoptsTheAccountRowAndMergesLocalSelectorsItDoesNotName() async throws {
    let harness = SettingsSyncHarness()
    var local = AlertRules(enabled: true, resetReminders: true, paceAlerts: true)
    local.setThresholds([30], for: "c3d4e5f6a1b2")
    harness.rules.save(local)
    let remote = accountSettingsGETBody(
      revision: 2,
      resetReminders: false,
      paceAlerts: false,
      thresholds: ["a1b2c3d4e5f6": [20, 10]],
      amountUSD: "250.00"
    )
    let written = accountSettingsGETBody(
      revision: 3,
      resetReminders: false,
      paceAlerts: false,
      thresholds: ["a1b2c3d4e5f6": [20, 10], "c3d4e5f6a1b2": [30]],
      amountUSD: "250.00"
    )
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: remote, headers: ["ETag": "\"2\""]),
        .init(status: 200, body: written, headers: ["ETag": "\"3\""]),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)

    await sync.refresh()

    let rules = harness.rules.load()
    #expect(rules.thresholds["c3d4e5f6a1b2"] == [30])
    #expect(rules.thresholds["a1b2c3d4e5f6"] == [20, 10])
    #expect(rules.enabled)
    #expect(!rules.resetReminders)
    #expect(!rules.paceAlerts)
    #expect(harness.budget.load().amountUSD == Decimal(250))
    #expect(transport.requests.compactMap(\.httpMethod) == ["GET", "PUT"])
  }

  @Test func historySyncOffLeavesAPendingOnEditAlone() async throws {
    let harness = SettingsSyncHarness()
    let transport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, history: false),
          headers: ["ETag": "\"1\""]
        ),
        .init(status: 500, body: Data()),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()

    await sync.apply(.setHistorySync(true))
    sync.noteHistorySyncOff()

    #expect(sync.historySync == true)
    #expect(sync.pending.map(\.edit) == [.setHistorySync(true)])
  }

  @Test func historySyncOffDropsTheFlagWhenNoEditNamesIt() async throws {
    let harness = SettingsSyncHarness()
    let transport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, history: true),
          headers: ["ETag": "\"1\""]
        ),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()

    #expect(sync.historySync == true)
    #expect(sync.pending.isEmpty)
    sync.noteHistorySyncOff()
    #expect(sync.historySync == false)
  }

  @Test func aStaleWriteReappliesOnceAndWrites() async throws {
    let harness = SettingsSyncHarness()
    let fresh = accountSettingsGETBody(
      revision: 2,
      resetReminders: true,
      amountUSD: "75.50"
    )
    let written = accountSettingsGETBody(
      revision: 3,
      resetReminders: false,
      amountUSD: "75.50"
    )
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 412, body: fresh, headers: ["ETag": "\"2\""]),
        .init(status: 200, body: written, headers: ["ETag": "\"3\""]),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()

    await sync.apply(.setResetReminders(false))

    #expect(harness.rules.load().resetReminders == false)
    #expect(harness.budget.load().amountUSD == Decimal(string: "75.50"))
    #expect(sync.pending.isEmpty)
    #expect(transport.requests.compactMap(\.httpMethod) == ["GET", "PUT", "PUT"])
    #expect(transport.requests.last?.value(forHTTPHeaderField: "If-Match") == "\"2\"")
    let retry = try settingsObject(transport.requests.last)
    #expect(alerts(retry)["reset_reminders"] as? Bool == false)
    #expect(budgetAmount(retry) == "75.50")
  }

  @Test func aSecond412LeavesTheLocalValueAndKeepsThePendingEdit() async throws {
    let harness = SettingsSyncHarness()
    let first = accountSettingsGETBody(revision: 2, resetReminders: true, amountUSD: "10.00")
    let second = accountSettingsGETBody(revision: 3, resetReminders: true, amountUSD: "20.00")
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 412, body: first, headers: ["ETag": "\"2\""]),
        .init(status: 412, body: second, headers: ["ETag": "\"3\""]),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()

    await sync.apply(.setResetReminders(false))

    #expect(harness.rules.load().resetReminders == false)
    #expect(harness.budget.load().amountUSD == Decimal(20))
    #expect(sync.pending.map(\.edit) == [.setResetReminders(false)])
  }

  @Test func anOfflineEditIsRetriedOnTheNextRefresh() async throws {
    let harness = SettingsSyncHarness()
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 503, body: Data()),
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, resetReminders: false),
          headers: ["ETag": "\"1\""]
        ),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()

    await sync.apply(.setResetReminders(false))
    #expect(harness.rules.load().resetReminders == false)
    #expect(sync.pending.map(\.edit) == [.setResetReminders(false)])

    await sync.refresh()
    #expect(sync.pending.isEmpty)
    #expect(harness.rules.load().resetReminders == false)
    #expect(transport.requests.compactMap(\.httpMethod) == ["GET", "PUT", "GET", "PUT"])
  }

  @Test func aSecondAccountGetsItsOwnFirstSync() async throws {
    let harness = SettingsSyncHarness()
    let firstAccount = MemoryAccountSessionStore(session: Fixtures.session(accountID: "account_01"))
    let firstTransport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 4, resetReminders: false),
          headers: ["ETag": "\"4\""]
        )
      ],
      autoAnswerAccountSettings: false
    )
    let first = harness.makeSync(
      client: harness.makeClient(transport: firstTransport, sessions: firstAccount)
    )
    await first.refresh()
    #expect(harness.rules.load().resetReminders == false)

    harness.rules.save(AlertRules(enabled: true, resetReminders: true, paceAlerts: true))
    let secondAccount = MemoryAccountSessionStore(
      session: Fixtures.session(accountID: "account_02")
    )
    let secondTransport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, resetReminders: true, paceAlerts: false),
          headers: ["ETag": "\"1\""]
        )
      ],
      autoAnswerAccountSettings: false
    )
    let second = harness.makeSync(
      client: harness.makeClient(transport: secondTransport, sessions: secondAccount)
    )
    await second.refresh()
    #expect(harness.rules.load().paceAlerts == false)
    #expect(harness.rules.load().enabled)
    #expect(secondTransport.requests.compactMap(\.httpMethod) == ["GET"])
  }

  @Test func localAndRemoteChangesBothRecompute() async throws {
    let harness = SettingsSyncHarness()
    let transport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, resetReminders: false),
          headers: ["ETag": "\"1\""]
        ),
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 2, resetReminders: false, paceAlerts: false),
          headers: ["ETag": "\"2\""]
        ),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()
    let afterRemote = harness.applied
    #expect(afterRemote >= 1)

    await sync.apply(.setPaceAlerts(false))
    #expect(harness.applied > afterRemote)
  }

  @Test func twoOfflineEditsToDifferentTargetsWriteInOnePUT() async throws {
    let harness = SettingsSyncHarness()
    let written = accountSettingsGETBody(
      revision: 2,
      thresholds: ["a1b2c3d4e5f6": [30]],
      amountUSD: "40.00"
    )
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 503, body: Data()),
        .init(status: 503, body: Data()),
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 200, body: written, headers: ["ETag": "\"2\""]),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()
    await sync.apply(.setThresholds(selector: "a1b2c3d4e5f6", [30]))
    await sync.apply(.setBudget(amount: 40, alerts: true))
    #expect(sync.pending.count == 2)

    await sync.refresh()

    #expect(sync.pending.isEmpty)
    #expect(harness.rules.load().thresholds["a1b2c3d4e5f6"] == [30])
    #expect(harness.budget.load().amountUSD == 40)
    let puts = transport.requests.filter { $0.httpMethod == "PUT" }
    #expect(puts.count == 3)
    let last = try settingsObject(puts.last)
    #expect(thresholds(last)["a1b2c3d4e5f6"] == [30])
    #expect(budgetAmount(last) == "40.00")
  }

  @Test func twoOfflineEditsToTheSameSelectorSendOnlyTheLaterValue() async throws {
    let harness = SettingsSyncHarness()
    let written = accountSettingsGETBody(
      revision: 1,
      thresholds: ["a1b2c3d4e5f6": [15]]
    )
    let transport = ScriptedHTTPTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 503, body: Data()),
        .init(status: 503, body: Data()),
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(status: 200, body: written, headers: ["ETag": "\"1\""]),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()
    await sync.apply(.setThresholds(selector: "a1b2c3d4e5f6", [30]))
    await sync.apply(.setThresholds(selector: "a1b2c3d4e5f6", [15]))
    #expect(sync.pending.map(\.edit) == [.setThresholds(selector: "a1b2c3d4e5f6", [15])])

    await sync.refresh()

    #expect(sync.pending.isEmpty)
    #expect(harness.rules.load().thresholds["a1b2c3d4e5f6"] == [15])
    let last = try settingsObject(transport.requests.last { $0.httpMethod == "PUT" })
    #expect(thresholds(last)["a1b2c3d4e5f6"] == [15])
    #expect(thresholds(last).count == 1)
  }

  @Test func aMovedRevisionKeepsPendingLocalValuesAndWritesThem() async throws {
    let harness = SettingsSyncHarness()
    let remote = accountSettingsGETBody(
      revision: 5,
      resetReminders: false,
      thresholds: ["a1b2c3d4e5f6": [20, 10]],
      amountUSD: "99.00"
    )
    let written = accountSettingsGETBody(
      revision: 6,
      resetReminders: false,
      thresholds: ["a1b2c3d4e5f6": [30]],
      amountUSD: "40.00"
    )
    let transport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1),
          headers: ["ETag": "\"1\""]
        ),
        .init(status: 503, body: Data()),
        .init(status: 503, body: Data()),
        .init(status: 200, body: remote, headers: ["ETag": "\"5\""]),
        .init(status: 200, body: written, headers: ["ETag": "\"6\""]),
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(transport: transport)
    await sync.refresh()
    await sync.apply(.setThresholds(selector: "a1b2c3d4e5f6", [30]))
    await sync.apply(.setBudget(amount: 40, alerts: true))

    await sync.refresh()

    #expect(harness.rules.load().resetReminders == false)
    #expect(harness.rules.load().thresholds["a1b2c3d4e5f6"] == [30])
    #expect(harness.budget.load().amountUSD == 40)
    #expect(sync.pending.isEmpty)
    let last = try settingsObject(transport.requests.last { $0.httpMethod == "PUT" })
    #expect(alerts(last)["reset_reminders"] as? Bool == false)
    #expect(thresholds(last)["a1b2c3d4e5f6"] == [30])
    #expect(budgetAmount(last) == "40.00")
  }

  @Test func anEditMadeWhileAWriteIsInFlightIsSentNext() async throws {
    let harness = SettingsSyncHarness()
    let transport = GatedSettingsTransport(
      [
        .init(status: 200, body: defaultAccountSettingsGETBody(), headers: ["ETag": "\"0\""]),
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, resetReminders: false),
          headers: ["ETag": "\"1\""]
        ),
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 2, resetReminders: false, amountUSD: "40.00"),
          headers: ["ETag": "\"2\""]
        ),
      ]
    )
    let sync = harness.makeSync(client: harness.makeClient(transport: transport))
    await sync.refresh()

    async let first = sync.apply(.setResetReminders(false))
    await transport.waitForFirstPUT()
    async let second = sync.apply(.setBudget(amount: 40, alerts: true))
    await waitUntil { sync.pending.count == 2 }
    await transport.releaseFirstPUT()
    await first
    #expect(sync.pending.map(\.edit) == [.setBudget(amount: 40, alerts: true)])
    await second
    #expect(sync.pending.isEmpty)
    #expect(harness.rules.load().resetReminders == false)
    #expect(harness.budget.load().amountUSD == 40)
    let puts = await transport.requests.filter { $0.httpMethod == "PUT" }
    #expect(puts.count == 2)
    #expect(budgetAmount(try settingsObject(puts[0])) == nil)
    #expect(budgetAmount(try settingsObject(puts[1])) == "40.00")
  }

  @Test func aPendingEditForAnotherAccountIsNotSent() async throws {
    let harness = SettingsSyncHarness()
    let foreign = PendingAccountSettingsEdit(
      id: 1,
      accountID: "account_01",
      edit: .setThresholds(selector: "a1b2c3d4e5f6", [30])
    )
    PendingAccountSettingsEdit.saveQueueForTests(
      items: [foreign],
      nextID: 2,
      to: harness.isolated.store
    )
    let sessions = MemoryAccountSessionStore(session: Fixtures.session(accountID: "account_02"))
    let transport = ScriptedHTTPTransport(
      [
        .init(
          status: 200,
          body: accountSettingsGETBody(revision: 1, paceAlerts: false),
          headers: ["ETag": "\"1\""]
        )
      ],
      autoAnswerAccountSettings: false
    )
    let sync = harness.makeSync(client: harness.makeClient(transport: transport, sessions: sessions))
    await sync.refresh()

    #expect(transport.requests.compactMap(\.httpMethod) == ["GET"])
    #expect(sync.pending.map(\.accountID) == ["account_01"])
    #expect(harness.rules.load().thresholds["a1b2c3d4e5f6"] == nil)
    #expect(!harness.rules.load().paceAlerts)
  }

  @Test func theOldSingleRecordPendingShapeIsMigrated() {
    let harness = SettingsSyncHarness()
    let old = try! JSONEncoder().encode(
      OldPendingRecord(accountID: "account_01", kind: "resetReminders", boolValue: false)
    )
    harness.isolated.store.set(old, forKey: AccountSettingsSync.pendingKey)
    let sync = harness.makeSync(
      transport: ScriptedHTTPTransport([], autoAnswerAccountSettings: false)
    )
    #expect(sync.pending.map(\.edit) == [.setResetReminders(false)])
    #expect(sync.pending.first?.accountID == "account_01")
    #expect(harness.isolated.store.data(forKey: AccountSettingsSync.pendingKey) == nil)
    #expect(harness.isolated.store.data(forKey: AccountSettingsSync.pendingEditsKey) != nil)
  }
}

@MainActor
private final class SettingsSyncHarness {
  let isolated = IsolatedSettingsDefaults()
  var signedIn = true
  var applied = 0

  var rules: AlertRulesStore {
    AlertCoordinator.rulesStore(defaults: isolated.store)
  }

  var budget: UsageBudgetStore {
    UsageBudgetStore(defaults: isolated.store)
  }

  func makeClient(
    transport: any HTTPTransport,
    sessions: MemoryAccountSessionStore = MemoryAccountSessionStore(session: Fixtures.session())
  ) -> AccountClient {
    AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore(),
      settingsStore: MemoryAccountSettingsStore()
    )
  }

  func makeSync(transport: ScriptedHTTPTransport) -> AccountSettingsSync {
    makeSync(client: makeClient(transport: transport))
  }

  func makeSync(client: AccountClient) -> AccountSettingsSync {
    let sync = AccountSettingsSync(
      account: client,
      rulesStore: rules,
      budgetStore: budget,
      defaults: isolated.store
    )
    sync.isSignedIn = { [weak self] in self?.signedIn ?? false }
    sync.onApplied = { [weak self] in self?.applied += 1 }
    return sync
  }
}

/// Returns once `condition` holds, woken by the observed change rather than a delay.
@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
  while !condition() {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      withObservationTracking { _ = condition() } onChange: { continuation.resume() }
    }
  }
}

private struct IsolatedSettingsDefaults {
  let name: String
  let store: UserDefaults

  init() {
    name = "QuotaTests.AccountSettingsSync.\(UUID().uuidString)"
    store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
  }
}

private func accountSettingsGETBody(
  revision: Int,
  resetReminders: Bool = true,
  paceAlerts: Bool = true,
  thresholds: [String: [Int]] = [:],
  amountUSD: String? = nil,
  history: Bool? = nil
) -> Data {
  let alerts: [String: Any] = [
    "reset_reminders": resetReminders,
    "pace_alerts": paceAlerts,
    "thresholds": thresholds,
  ]
  var budget: [String: Any] = ["alerts": true]
  if let amountUSD {
    budget["amount_usd"] = amountUSD
  } else {
    budget["amount_usd"] = NSNull()
  }
  var object: [String: Any] = [
    "protocol_version": 2,
    "revision": revision,
    "updated_at": "2026-09-21T10:00:00Z",
    "alerts": alerts,
    "budget": budget,
  ]
  if let history {
    object["history"] = ["sync": history]
  }
  return try! JSONSerialization.data(withJSONObject: object)
}

private struct OldPendingRecord: Encodable {
  var accountID: String
  var kind: String
  var boolValue: Bool
}

private func settingsObject(_ request: URLRequest?) throws -> [String: Any] {
  guard let body = request?.httpBody,
    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
  else {
    throw SettingsJSONError.missing
  }
  return object
}

private enum SettingsJSONError: Error {
  case missing
}

private func alerts(_ object: [String: Any]) -> [String: Any] {
  object["alerts"] as? [String: Any] ?? [:]
}

private func thresholds(_ object: [String: Any]) -> [String: [Int]] {
  let raw = alerts(object)["thresholds"] as? [String: Any] ?? [:]
  var result: [String: [Int]] = [:]
  for (selector, value) in raw {
    if let ints = value as? [Int] {
      result[selector] = ints
    } else if let numbers = value as? [NSNumber] {
      result[selector] = numbers.map(\.intValue)
    }
  }
  return result
}

private func budgetAmount(_ object: [String: Any]) -> String? {
  let budget = object["budget"] as? [String: Any]
  let raw = budget?["amount_usd"]
  if raw is NSNull { return nil }
  return raw as? String
}

/// Holds the first PUT until `releaseFirstPUT`, so a second edit can join the queue in flight.
actor GatedSettingsTransport: HTTPTransport {
  private var exchanges: [ScriptedHTTPTransport.Exchange]
  private var recorded: [URLRequest] = []
  private var firstPUTWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstPUTHold: CheckedContinuation<Void, Never>?
  private var putCount = 0
  private var firstPUTSeen = false
  private var firstPUTReleased = false

  init(_ exchanges: [ScriptedHTTPTransport.Exchange]) {
    self.exchanges = exchanges
  }

  var requests: [URLRequest] { recorded }

  func waitForFirstPUT() async {
    if firstPUTSeen { return }
    await withCheckedContinuation { firstPUTWaiters.append($0) }
  }

  func releaseFirstPUT() {
    firstPUTReleased = true
    let hold = firstPUTHold
    firstPUTHold = nil
    hold?.resume()
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorded.append(request)
    if request.httpMethod == "PUT" {
      putCount += 1
      if putCount == 1 {
        firstPUTSeen = true
        let waiters = firstPUTWaiters
        firstPUTWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !firstPUTReleased {
          await withCheckedContinuation { firstPUTHold = $0 }
        }
      }
    }
    guard !exchanges.isEmpty else { throw HTTPTransportError.unavailable }
    let exchange = exchanges.removeFirst()
    let url = request.url ?? URL(string: "https://quota.gotry.io")!
    let response = HTTPURLResponse(
      url: url,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: exchange.headers.isEmpty ? nil : exchange.headers
    )!
    return (exchange.body, response)
  }
}
