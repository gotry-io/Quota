import Foundation
import QuotaAccount
import QuotaAlertDelivery
import QuotaAlerts
import QuotaWire
import Testing
import UserNotifications

@testable import Quota

@MainActor
struct AlertDeliveryAppModelTests {
  @Test func successfulRefreshPostsThresholdAndBooksResetReminder() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    AlertCoordinator.rulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let resetsAt = Fixtures.date("2026-08-18T00:00:00Z")
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [
        .init(status: 200, body: try alertSummaryJSON()),
        .init(status: 200, body: try alertSummaryJSON()),
      ],
      alertRulesStore: AlertCoordinator.rulesStore(defaults: defaults.store),
      notificationCenter: center,
      now: { now }
    )

    #expect(await model.refresh())
    let thresholdPosts = center.added.filter { $0.trigger == nil }
    #expect(thresholdPosts.count == 1)
    let threshold = try #require(thresholdPosts.first)
    #expect(
      threshold.identifier
        == AlertDedupKey(
          kind: .threshold,
          selector: "ccfc96629357",
          windowID: "weekly",
          resetsAt: resetsAt,
          threshold: 20
        ).requestIdentifier
    )
    #expect(threshold.content.threadIdentifier == "ccfc96629357")
    #expect(threshold.content.title == "Codex · Weekly")
    #expect(center.pending.count == 1)
    let reminder = try #require(center.pending.first)
    #expect(
      reminder.identifier
        == AlertDedupKey(
          kind: .reset,
          selector: "ccfc96629357", windowID: "weekly", resetsAt: resetsAt, threshold: nil
        ).requestIdentifier
    )
    #expect(reminder.content.title == "Codex · Weekly")
    #expect(reminder.content.body == "Weekly quota reset")
    #expect(reminder.trigger is UNCalendarNotificationTrigger)

    #expect(await model.refresh())
    #expect(center.added.filter { $0.trigger == nil }.count == 1)
    #expect(center.pending.count == 1)
    #expect(
      center.pending.first?.identifier
        == AlertDedupKey(
          kind: .reset,
          selector: "ccfc96629357", windowID: "weekly", resetsAt: resetsAt, threshold: nil
        ).requestIdentifier
    )
  }

  @Test func aNewSummaryReplacesTheBookedResetReminder() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    AlertCoordinator.rulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let firstReset = Fixtures.date("2026-08-18T00:00:00Z")
    let secondReset = Fixtures.date("2026-08-25T00:00:00Z")
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [
        .init(status: 200, body: try alertSummaryJSON(resetsAt: "2026-08-18T00:00:00Z")),
        .init(status: 200, body: try alertSummaryJSON(resetsAt: "2026-08-25T00:00:00Z")),
      ],
      alertRulesStore: AlertCoordinator.rulesStore(defaults: defaults.store),
      notificationCenter: center,
      now: { now }
    )

    #expect(await model.refresh())
    let firstID = try #require(center.pending.first?.identifier)
    #expect(
      firstID
        == AlertDedupKey(
          kind: .reset,
          selector: "ccfc96629357", windowID: "weekly", resetsAt: firstReset, threshold: nil
        ).requestIdentifier
    )

    #expect(await model.refresh())
    #expect(center.removedAllPendingCount == 2)
    #expect(center.pending.count == 1)
    #expect(center.pending.first?.identifier != firstID)
    #expect(
      center.pending.first?.identifier
        == AlertDedupKey(
          kind: .reset,
          selector: "ccfc96629357", windowID: "weekly", resetsAt: secondReset, threshold: nil
        ).requestIdentifier
    )
  }

  @Test func logoutRemovesEveryPendingReminder() async throws {
    let defaults = isolatedAlertDefaults()
    defer { defaults.tearDown() }
    AlertCoordinator.rulesStore(defaults: defaults.store).save(
      AlertRules(enabled: true, resetReminders: true)
    )
    let center = FakeNotificationCenter()
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: try WireCodec.decode(AccountSummary.self, from: try alertSummaryJSON()),
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [
        .init(status: 200, body: try alertSummaryJSON()),
        .init(status: 204, body: Data()),
      ],
      alertRulesStore: AlertCoordinator.rulesStore(defaults: defaults.store),
      notificationCenter: center,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    #expect(await model.refresh())
    #expect(!center.pending.isEmpty)

    await model.logout()
    #expect(center.pending.isEmpty)
    #expect(center.removedAllPendingCount >= 2)
  }
}

final class FakeNotificationCenter: NotificationCentering, @unchecked Sendable {
  var authorizationStatusValue: UNAuthorizationStatus = .notDetermined
  var requestAuthorizationGranted = true
  var requestedOptions: UNAuthorizationOptions?
  var added: [UNNotificationRequest] = []
  var pending: [UNNotificationRequest] = []
  var removedAllPendingCount = 0

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    requestedOptions = options
    if requestAuthorizationGranted {
      authorizationStatusValue = .authorized
    } else {
      authorizationStatusValue = .denied
    }
    return requestAuthorizationGranted
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    authorizationStatusValue
  }

  func add(_ request: UNNotificationRequest) {
    added.append(request)
    if request.trigger != nil {
      pending.removeAll { $0.identifier == request.identifier }
      pending.append(request)
    }
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    pending.removeAll { identifiers.contains($0.identifier) }
  }

  func removeAllPendingNotificationRequests() {
    removedAllPendingCount += 1
    pending.removeAll()
  }
}
