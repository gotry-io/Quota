import Foundation
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing
import UserNotifications

@testable import QuotaBar

@MainActor
struct AccountSettingsModelTests {
  @Test
  func firstSyncSeedsARevisionZeroAccountFromNonDefaultLocalValues() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let model = settingsModel(record: record, defaults: defaults.store)
    model.setResetReminders(false)

    let settings = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 0),
      revision: 0
    )
    model.apply(signedInSettingsState(settings: settings))
    try await waitUntil { await record.calls.count == 1 }

    let call = try #require(await record.calls.first)
    #expect(call.ifMatch == "\"0\"")
    #expect(!call.document.alerts.resetReminders)
    #expect(!model.notificationRules.resetReminders)
  }

  @Test
  func aFirstSyncWriteConflictAdoptsTheOtherDevice() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let other = accountSettingsDocument(revision: 1, amountUSD: 90)
    await record.queue(.success(.conflict(other)))
    let model = settingsModel(record: record, defaults: defaults.store)
    model.setResetReminders(false)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 0),
          revision: 0
        )
      )
    )
    try await waitUntil { await record.calls.count == 1 }
    try await waitUntil { model.usage.budget.amountUSD == 90 }
    #expect(model.notificationRules.resetReminders)
  }

  @Test
  func firstSyncAdoptsAnAccountRowAndDoesNotWrite() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let model = settingsModel(record: record, defaults: defaults.store)
    let settings = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(
        revision: 1,
        resetReminders: false,
        amountUSD: 250
      ),
      revision: 1
    )
    model.apply(signedInSettingsState(settings: settings))
    await Task.yield()
    try await Task.sleep(for: .milliseconds(30))

    #expect(await record.calls.isEmpty)
    #expect(!model.notificationRules.resetReminders)
    #expect(model.usage.budget.amountUSD == 250)
  }

  @Test
  func firstSyncMergesLocalSelectorsTheAccountDoesNotNameAndWrites() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let selector = "aa1111111111"
    NotificationRules.store(defaults: defaults.store).save(
      AlertRules(thresholds: [selector: [30]])
    )
    let model = settingsModel(record: record, defaults: defaults.store)
    let settings = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(
        revision: 4,
        thresholds: ["a1b2c3d4e5f6": [20, 10]]
      ),
      revision: 4
    )
    model.apply(signedInSettingsState(settings: settings))
    try await waitUntil { await record.calls.count == 1 }

    #expect(model.notificationRules.thresholds[selector] == [30])
    #expect(model.notificationRules.thresholds["a1b2c3d4e5f6"] == [20, 10])
    let call = try #require(await record.calls.first)
    #expect(call.ifMatch == "\"4\"")
    #expect(call.document.alerts.thresholds[selector] == [30])
  }

  @Test
  func aLocalEditWritesAndKeepsTheWrittenDocument() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let written = accountSettingsDocument(revision: 2, resetReminders: false)
    await record.queue(.success(.written(written)))
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 1 }
    try await waitUntil { await record.results.isEmpty }

    #expect(!model.notificationRules.resetReminders)
    let call = try #require(await record.calls.first)
    #expect(call.ifMatch == "\"1\"")
    #expect(!call.document.alerts.resetReminders)
  }

  @Test
  func aConflictReappliesTheOneEditAndRetriesOnce() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let fresh = accountSettingsDocument(revision: 3, paceAlerts: false, amountUSD: 80)
    let written = accountSettingsDocument(
      revision: 4, resetReminders: false, paceAlerts: false, amountUSD: 80)
    await record.queue(.success(.conflict(fresh)))
    await record.queue(.success(.written(written)))
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 2 }

    #expect(!model.notificationRules.resetReminders)
    #expect(!model.notificationRules.paceAlerts)
    #expect(model.usage.budget.amountUSD == 80)
    let second = await record.calls[1]
    #expect(second.ifMatch == "\"3\"")
    #expect(!second.document.alerts.resetReminders)
    #expect(!second.document.alerts.paceAlerts)
  }

  @Test
  func aSecondConflictLeavesTheLocalValue() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let first = accountSettingsDocument(revision: 3, paceAlerts: false)
    let second = accountSettingsDocument(revision: 5, paceAlerts: true, amountUSD: 10)
    await record.queue(.success(.conflict(first)))
    await record.queue(.success(.conflict(second)))
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 2 }
    await Task.yield()

    #expect(!model.notificationRules.resetReminders)
    #expect(await record.calls.count == 2)
  }

  @Test
  func aFailedWriteIsRetriedWhenTheNextStateArrives() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    await record.queue(.failure(LocalServiceClientError.connectionClosed))
    let model = settingsModel(record: record, defaults: defaults.store)
    let settings = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 1),
      revision: 1
    )
    model.apply(signedInSettingsState(settings: settings, revision: 2))
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 1 }

    model.apply(signedInSettingsState(settings: settings, revision: 3))
    try await waitUntil { await record.calls.count == 2 }

    #expect(!model.notificationRules.resetReminders)
    let retry = await record.calls[1]
    #expect(!retry.document.alerts.resetReminders)
  }

  @Test
  func aWriteThatLandsAfterSignOutWritesNothing() async throws {
    let record = AccountSettingsWriteRecord()
    let gate = TestGate()
    await record.setGate(gate)
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 1 }

    model.apply(signedOutWithSessionEndedState())
    await gate.open()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(40))

    #expect(!model.notificationRules.resetReminders)
    #expect(await record.calls.count == 1)
  }

  @Test
  func aSecondAccountGetsItsOwnFirstSync() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1, amountUSD: 250),
          revision: 1
        )
      )
    )
    #expect(model.usage.budget.amountUSD == 250)

    model.apply(
      signedInSettingsState(
        accountID: "account_2",
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 2, amountUSD: 40),
          revision: 2
        )
      )
    )
    #expect(model.usage.budget.amountUSD == 40)
    #expect(await record.calls.isEmpty)
  }

  @Test
  func syncDoesNotWriteEnabled() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    NotificationRules.store(defaults: defaults.store).save(AlertRules(enabled: true))
    let model = settingsModel(record: record, defaults: defaults.store)
    #expect(model.notificationRules.enabled)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1, resetReminders: false),
          revision: 1
        )
      )
    )
    #expect(model.notificationRules.enabled)
    #expect(!model.notificationRules.resetReminders)
  }

  @Test
  func aRemoteChangeReevaluatesAndReschedules() async throws {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    NotificationRules.store(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let now = Date()
    let item = codexOverviewItem(
      remainingPercent: 40, now: now, resetsAt: now.addingTimeInterval(3_600))
    let first = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 1),
      revision: 1
    )
    let model = MenuBarViewModel(
      client: StubLocalService(state: signedInSettingsState(settings: first, overview: [item])),
      notificationCenter: center,
      notificationDefaults: defaults.store
    )
    model.apply(signedInSettingsState(settings: first, overview: [item]))
    #expect(!center.pending.isEmpty)

    let next = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 2, resetReminders: false),
      revision: 2
    )
    model.apply(signedInSettingsState(settings: next, overview: [item], revision: 3))
    #expect(center.pending.isEmpty)
    #expect(!model.notificationRules.resetReminders)
  }

  @Test
  func twoEditsToDifferentTargetsGoInOneWrite() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setResetReminders(false)
    model.setPaceAlerts(false)
    try await waitUntil { await record.calls.count == 1 }
    await Task.yield()
    try await Task.sleep(for: .milliseconds(30))

    #expect(await record.calls.count == 1)
    let call = try #require(await record.calls.first)
    #expect(!call.document.alerts.resetReminders)
    #expect(!call.document.alerts.paceAlerts)
  }

  @Test
  func twoEditsToOneSelectorKeepTheLaterValueOnly() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let selector = "aa1111111111"
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setNotificationFirstThreshold(15, for: selector)
    model.setNotificationFirstThreshold(25, for: selector)
    try await waitUntil { await record.calls.count == 1 }
    await Task.yield()
    try await Task.sleep(for: .milliseconds(30))

    #expect(await record.calls.count == 1)
    let call = try #require(await record.calls.first)
    #expect(call.document.alerts.thresholds[selector] == [25, 10])
  }

  @Test
  func aMovedRevisionWithPendingEditsKeepsLocalValuesAndWritesThem() async throws {
    let record = AccountSettingsWriteRecord()
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    await record.queue(.failure(LocalServiceClientError.connectionClosed))
    let model = settingsModel(record: record, defaults: defaults.store)
    let first = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 1),
      revision: 1
    )
    model.apply(signedInSettingsState(settings: first))
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 1 }

    let moved = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 2, paceAlerts: false, amountUSD: 80),
      revision: 2
    )
    model.apply(signedInSettingsState(settings: moved, revision: 3))
    try await waitUntil { await record.calls.count == 2 }

    #expect(!model.notificationRules.resetReminders)
    #expect(!model.notificationRules.paceAlerts)
    #expect(model.usage.budget.amountUSD == 80)
    let retry = await record.calls[1]
    #expect(!retry.document.alerts.resetReminders)
    #expect(!retry.document.alerts.paceAlerts)
    #expect(retry.document.budget.amountUSD == 80)
  }

  @Test
  func anEditMadeMidWriteSurvivesThatWritesSuccess() async throws {
    let record = AccountSettingsWriteRecord()
    let gate = TestGate()
    await record.setGate(gate)
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let settings = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 1),
      revision: 1
    )
    let state = signedInSettingsState(settings: settings)
    let model = settingsModel(record: record, defaults: defaults.store, state: state)
    model.apply(state)
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 1 }

    model.setPaceAlerts(false)
    await gate.open()
    try await waitUntil { await record.calls.count == 2 }

    #expect(!model.notificationRules.resetReminders)
    #expect(!model.notificationRules.paceAlerts)
    let first = await record.calls[0]
    #expect(!first.document.alerts.resetReminders)
    #expect(first.document.alerts.paceAlerts)
    let second = await record.calls[1]
    #expect(!second.document.alerts.paceAlerts)
  }

  @Test
  func anEditForOneAccountIsNotSentWhileSignedInAsAnother() async throws {
    let record = AccountSettingsWriteRecord()
    let gate = TestGate()
    await record.setGate(gate)
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let model = settingsModel(record: record, defaults: defaults.store)
    model.apply(
      signedInSettingsState(
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 1),
          revision: 1
        )
      )
    )
    model.setResetReminders(false)
    try await waitUntil { await record.calls.count == 1 }

    model.apply(signedOutWithSessionEndedState())
    await gate.open()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(40))

    model.apply(
      signedInSettingsState(
        accountID: "account_2",
        settings: LocalServiceAccountSettingsState(
          document: accountSettingsDocument(revision: 2, amountUSD: 40),
          revision: 2
        )
      )
    )
    await Task.yield()
    try await Task.sleep(for: .milliseconds(40))

    #expect(await record.calls.count == 1)
    #expect(model.usage.budget.amountUSD == 40)
  }

  @Test
  func aRelaunchDoesNotFirstSyncAgainAndWritesThePendingEdit() async throws {
    let defaults = notificationDefaultsSuite()
    defer { defaults.tearDown() }
    let firstRecord = AccountSettingsWriteRecord()
    await firstRecord.queue(.failure(LocalServiceClientError.connectionClosed))
    let first = settingsModel(record: firstRecord, defaults: defaults.store)
    let settings = LocalServiceAccountSettingsState(
      document: accountSettingsDocument(revision: 1),
      revision: 1
    )
    first.apply(signedInSettingsState(settings: settings))
    first.setResetReminders(false)
    try await waitUntil { await firstRecord.calls.count == 1 }
    #expect(
      defaults.store.stringArray(forKey: AccountSettingsModel.firstSyncKey) == ["account_1"])
    #expect(defaults.store.data(forKey: AccountSettingsModel.pendingKey) != nil)
    first.accountSettings.shutdown()

    let secondRecord = AccountSettingsWriteRecord()
    let second = settingsModel(record: secondRecord, defaults: defaults.store)
    second.apply(signedInSettingsState(settings: settings))
    try await waitUntil { await secondRecord.calls.count == 1 }

    #expect(!second.notificationRules.resetReminders)
    let call = try #require(await secondRecord.calls.first)
    #expect(!call.document.alerts.resetReminders)
    #expect(call.ifMatch == "\"1\"")
    #expect(await secondRecord.calls.count == 1)
  }
}

@MainActor
private func settingsModel(
  record: AccountSettingsWriteRecord,
  defaults: UserDefaults,
  state: LocalServiceState = loggingInState()
) -> MenuBarViewModel {
  MenuBarViewModel(
    client: StubLocalService(
      state: state,
      accountSettingsWriteRecord: record
    ),
    notificationDefaults: defaults
  )
}

@MainActor
private func waitUntil(
  _ condition: @escaping @MainActor () async -> Bool,
  seconds: Double = 5
) async throws {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while await !condition() {
    if ContinuousClock.now >= deadline {
      Issue.record("timed out waiting for condition")
      return
    }
    await Task.yield()
    try await Task.sleep(for: .milliseconds(10))
  }
}


